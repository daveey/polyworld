## Plays a recorded match back on the table, for the browser replay viewer
## and `--replay PATH`. It takes the place of the bots: each recorded action
## is presented the way a bot's would be, one at a time once the table is
## still. Seeks rebuild the match from its setup and apply actions with no
## animation. Every tick's state is checked against the recorded hash.
import std/[strformat, times]
import silky, vmath, windy
import core/[sim, match, replays], play, scene/table, ui/hud
import polyworld/[actioncam, chrome, gameuis, player, viewers]

const
  ReplayStepSeconds = 1.2'f32  ## Between actions at 1x, like a bot.
  ReplayBarHeight* = TransportHeight  ## The transport bar, in HUD units.

type
  Replayer* = ref object
    data*: ReplayData
    transport*: Player
    tick*: int32  ## Actions applied to the presented game.
    check*: ReplayHashCheck
    wait: float32
    attackTick: int32  ## A presented attack's tick, checked when it lands.
    actionCam: ActionCam  ## The transport's camera button; AWM's is fixed.
    follow: bool

proc newReplayer*(data: ReplayData): Replayer =
  ## Creates a viewer that plays one recorded game without looping.
  result = Replayer(data: data,
    transport: initPlayer(live = false, durationTicks = data.hashes.len.int32),
    actionCam: initActionCam(), attackTick: -1)
  result.transport.repeating = false

proc timeScale*(replayer: Replayer): float32 =
  ## How fast the table runs: the selected speed, cards and lunges included.
  replayer.transport.speed.float32

proc classes*(replayer: Replayer): seq[HeroClass] =
  replayer.data.header.setup.heroClasses

proc newReplayGame*(replayer: Replayer): GameState =
  ## The recorded match before its first action.
  newGame(replayer.classes, replayer.data.header.setup.seed.int64)

proc playerName*(replayer: Replayer, player: int): string =
  if player < replayer.data.config.players.len:
    replayer.data.config.players[player].displayName(player)
  else:
    "Player " & $(player + 1)

proc checkTick(replayer: Replayer, game: GameState, tick: int32) =
  replayer.data.hashes.checkReplayHash(tick.uint32, game.stateHash,
    replayer.check)

proc applyInstantly(replayer: Replayer, game: var GameState) =
  let action = replayer.data.actions[replayer.tick]
  discard game.applyAction(action)
  discard game.takeVisualEvents()
  inc replayer.tick
  replayer.checkTick(game, replayer.tick)

proc present(replayer: Replayer, play: var TablePlay, game: var GameState,
    layout: TableLayout) =
  ## Applies the next action with the animations a bot's would get.
  let
    action = replayer.data.actions[replayer.tick]
    name = replayer.playerName(action.playerId.int)
  inc replayer.tick
  discard game.takeVisualEvents()
  let before = game.copyGameState()
  case action.kind
  of ActionAttack:
    # The damage lands with the lunge; its hash is checked then.
    play.startAttack(game, layout, @[action.attacker.int],
      action.choices[0].toChoice)
    play.statusMessage = name & " is attacking..."
    replayer.attackTick = replayer.tick
    return
  of ActionToss:
    discard game.applyAction(action)
    play.statusMessage = name & " discards."
  of ActionEndTurn:
    discard game.applyAction(action)
    play.animateTransition(layout, before, game)
    play.statusMessage =
      if game.gameOver: ""
      else: replayer.playerName(game.currentPlayer) & " is thinking..."
  of ActionPlayCard:
    discard game.applyAction(action)
    play.animateTransition(layout, before, game)
    play.statusMessage = name & " is playing..."
  else:
    discard game.applyAction(action)
    play.animateTransition(layout, before, game)
    play.statusMessage = "A trigger resolves."
  replayer.checkTick(game, replayer.tick)

proc update*(replayer: Replayer, play: var TablePlay, game: var GameState,
    layout: TableLayout, dt: float32): bool =
  ## Advances playback by one frame of `dt` table time (already scaled by
  ## `timeScale`). True when the table was rebuilt (a seek or a loop), so
  ## the caller can re-aim anything it keeps.
  let total = replayer.data.actions.len.int32
  template transport: untyped = replayer.transport
  let restore = transport.takeRestore()
  if restore >= 0 or
    (transport.targetTick >= 0 and replayer.attackTick >= 0):
      # An unfinished lunge has not applied its recorded damage yet.
      # Rebuild it from the tape before seeking in either direction.
      game = replayer.newReplayGame()
      replayer.tick = 0
      replayer.check = ReplayHashCheck()
  if transport.targetTick >= 0 or restore >= 0:
    # Restore before syncing: the old tick can otherwise clear the target.
    play.resetTable()
    replayer.attackTick = -1
    let frameStart = epochTime()
    while transport.targetTick >= 0 and replayer.tick < total and
        replayer.tick < transport.targetTick and
        epochTime() - frameStart < CatchUpSeconds:
      replayer.applyInstantly(game)
    transport.sync(replayer.tick, total, over = replayer.tick >= total)
    play.statusMessage =
      if game.gameOver: ""
      else: replayer.playerName(game.currentPlayer) & "'s turn."
    replayer.wait = ReplayStepSeconds
    return true
  if play.advanceAttack(game, dt) and replayer.attackTick >= 0:
    replayer.checkTick(game, replayer.attackTick)
    replayer.attackTick = -1
  transport.sync(replayer.tick, total, over = replayer.tick >= total)
  if not transport.playing:
    return
  if replayer.tick >= total:
    if transport.repeating and play.presentationIdle(game) and
        not play.attackActive:
      transport.seekTo(0, automatic = true)
    elif not transport.repeating:
      transport.playing = false
    return
  if play.presentationIdle(game) and not play.attackActive:
    replayer.wait -= dt
    if replayer.wait <= 0:
      replayer.present(play, game, layout)
      replayer.wait = ReplayStepSeconds

proc drawTransport*(replayer: Replayer, sk: Silky, window: Window) =
  ## The shared play/replay bar along the bottom of the screen.
  let size = hudSize(window)
  replayer.transport.drawTransport(sk, window,
    GameUiPanel(origin: vec2(0, size.y - TransportHeight),
      size: vec2(size.x, TransportHeight)),
    replayer.actionCam, replayer.follow)
  if window.buttonPressed[KeySpace]:
    replayer.transport.handleKey(KeySpace)
  if replayer.check.mismatches > 0:
    sk.drawError(size,
      &"REPLAY DIVERGED - {replayer.check.mismatches} mismatches, " &
        &"first at tick {replayer.check.firstTick}")

proc reportFrame*(replayer: Replayer) =
  ## Tells the replay page the first frame is up, or that it diverged.
  reportReplayFrame(replayer.tick, replayer.check.mismatches)
