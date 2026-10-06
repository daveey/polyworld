## Animated replay completion, looping, and seeks during attacks.
import
  std/sequtils,
  polyworld/player,
  ../src/[replayer, play],
  ../src/core/[bots, match, replays, sim],
  ../src/modes/multiplayer,
  ../src/scene/table,
  ../src/vfx/vfxrenderer

const BaseBot = staticRead("../players/base.bas")

proc recordedGame(): ReplayData =
  ## Records a deterministic five seat match with real bot actions.
  let
    classes = @[Warrior, Mage, Archer, Mage, Warrior]
    setup = Setup(seed: 44, maximumTicks: 28_800,
      classes: classes.mapIt(it.ord.uint8))
    recorder = initReplayRecorder(setup,
      GameConfig(seed: setup.seed, maxTicks: setup.maximumTicks.int32,
        players: unnamedPlayers(classes.len)))
  var match = initBotMatch(classes, setup.seed,
    loadBots(newSeqWith(classes.len, BaseBot)), setup.maximumTicks, recorder)
  match.run()
  doAssert match.outcome == MatchWon
  recorder.data

proc advance(replay: Replayer, play: var TablePlay, game: var GameState,
    layout: MultiplayerLayout, view: MultiplayerView, time: var float32,
    seconds: float32) =
  ## Runs the same animation and event phases as the multiplayer viewer.
  let dt = seconds * replay.timeScale
  time += dt
  play.animations.advanceAnimations(dt)
  play.discardFlights.advanceAnimations(dt)
  play.activeVfx.advance(dt)
  let table = layout.seatTable(view, game.currentPlayer, -1)
  discard replay.update(play, game, table, dt)
  play.presentVisualEvents(game, table, time)
  doAssert replay.check.mismatches == 0

proc seek(replay: Replayer, play: var TablePlay, game: var GameState,
    layout: MultiplayerLayout, view: MultiplayerView, time: var float32,
    target: int32) =
  ## Lands exactly on a requested tick and checks the recorded state.
  replay.transport.seekTo(target, play = false)
  replay.transport.playing = false
  for i in 0 ..< 100:
    replay.advance(play, game, layout, view, time, 0.0'f)
    if replay.transport.targetTick < 0:
      break
  doAssert replay.tick == target
  doAssert not play.attackActive
  doAssert play.animations.len == 0
  doAssert play.activeVfx.len == 0
  if target > 0:
    doAssert game.stateHash == replay.data.hashes[target - 1]
  else:
    doAssert game.stateHash == replay.newReplayGame().stateHash

let
  data = recordedGame()
  layout = buildMultiplayerLayout(data.header.setup.classes.len)
  view = layout.multiplayerView(16.0'f / 9)

echo "Recorded names and unnamed seats share the same labels"
block:
  var namedData = data
  namedData.config.players = @[
    PlayerConfig(name: "Andrew B"), PlayerConfig(name: "")]
  let
    replay = newReplayer(namedData)
    names = replay.playerNames()
    game = replay.newReplayGame()
  doAssert names == @["Andrew B", "Player 2", "Player 3", "Player 4",
    "Player 5"]
  doAssert game.playerName(0, names) == "Andrew B"
  doAssert game.playerName(1, @["Andrew B", ""]) == "Player 2"
  doAssert game.playerName(2) == "Player 3"
  doAssert game.choiceLabel(heroChoice(0), names) == "Andrew B Warrior hero"
  doAssert game.choiceLabel(heroChoice(1), names) == "Player 2 Mage hero"

for seconds in [1.0'f / 60, 1.0'f / 30, 0.1'f, 0.25'f]:
  echo "Default looping at 16x, frame seconds ", seconds
  let replay = newReplayer(data)
  doAssert replay.transport.repeating
  replay.transport.setSpeed(3)
  var
    game = replay.newReplayGame()
    play = initTablePlay(1)
    time = 0.0'f
    finished = false
  play.addOpeningHands(game, layout.seatTable(view, game.currentPlayer, -1))
  for i in 0 ..< 20_000:
    replay.advance(play, game, layout, view, time, seconds)
    if game.gameOver:
      finished = true
    if finished and replay.tick == 0:
      break
  doAssert finished
  doAssert replay.tick == 0
  doAssert replay.transport.playing
  doAssert not game.gameOver
  doAssert not play.attackActive
  doAssert play.heroDeaths.len == 0
  for seat in 0 ..< game.playerCount:
    doAssert not game.dead(seat)
    doAssert play.deathClock(game, seat, time) == -1

  echo "Disabling looping plays once and stops"
  replay.transport.repeating = false
  finished = false
  for i in 0 ..< 20_000:
    replay.advance(play, game, layout, view, time, seconds)
    if not replay.transport.playing and play.presentationIdle(game) and
      not play.attackActive:
        finished = true
        break
  doAssert finished
  doAssert game.gameOver
  doAssert replay.tick == data.actions.len.int32
  doAssert play.heroDeaths.anyIt(it >= 0)
  for i in 0 ..< 120:
    replay.advance(play, game, layout, view, time, seconds)
  doAssert replay.tick == data.actions.len.int32

  echo "Restored living heroes ignore death times from the previous game"
  let restored = replay.newReplayGame()
  for seat in 0 ..< restored.playerCount:
    doAssert play.deathClock(restored, seat, time) == -1

  echo "Explicit looping resets all presentation state"
  doAssert play.heroDeaths.anyIt(it >= 0)
  replay.transport.repeating = true
  replay.transport.playing = true
  for i in 0 ..< 100:
    replay.advance(play, game, layout, view, time, seconds)
    if replay.tick == 0:
      break
  doAssert replay.tick == 0
  doAssert play.heroDeaths.len == 0
  doAssert not play.attackActive
  doAssert not game.gameOver
  for seat in 0 ..< game.playerCount:
    doAssert not game.dead(seat)
    doAssert play.deathClock(game, seat, time) == -1

  echo "Backward seek keeps its destination and clears dead heroes"
  replay.transport.repeating = false
  replay.seek(play, game, layout, view, time, data.actions.len.int32)
  replay.seek(play, game, layout, view, time, 5)
  doAssert play.heroDeaths.len == 0
  replay.seek(play, game, layout, view, time, 0)
  doAssert play.heroDeaths.len == 0

for forward in [false, true]:
  echo "Seeking during a lunge, forward = ", forward
  let replay = newReplayer(data)
  replay.transport.repeating = false
  replay.transport.setSpeed(3)
  var
    game = replay.newReplayGame()
    play = initTablePlay(1)
    time = 0.0'f
  for i in 0 ..< 20_000:
    replay.advance(play, game, layout, view, time, 1.0'f / 60)
    if play.attackActive:
      break
  doAssert play.attackActive
  let target = if forward: replay.tick + 7 else: replay.tick - 2
  replay.seek(play, game, layout, view, time, target)
  replay.seek(play, game, layout, view, time, 0)
  replay.transport.playing = true
  for i in 0 ..< 20_000:
    replay.advance(play, game, layout, view, time, 1.0'f / 60)
    if not replay.transport.playing:
      break
  doAssert replay.tick == data.actions.len.int32
  doAssert game.gameOver

echo "Replay playback passed"

echo "Live bot attack animation never ends a turn automatically"
block:
  var game = newGame(@[Mage, Warrior], 44)
  let
    player = game.currentPlayer
    enemy = game.nextPlayer(player)
    table = layout.seatTable(view, player, -1)
    card = baseCardNamed("Primordial")
    bots = loadBots(newSeqWith(2, """
id = boardId(selfPlayer, 0)
i = 0
while i < attackChoiceCount(id)
  if attackChoiceKind(id, i) = 2 then
    if attack(id, i) then end
  end if
  i = i + 1
wend
endTurn()
"""))
  game.players[player].board = @[
    MinionState(id: 1, owner: player, card: card,
      currentToughness: card.toughness, canAttack: true)]
  game.nextMinionId = 2
  discard game.takeVisualEvents()
  var
    play = initTablePlay(1)
    clock = initBotClock()
  clock.wait = 0
  doAssert not play.updateBots(game, table, bots, clock,
    proc(): bool = false, 0.0'f)
  doAssert play.attackActive
  doAssert game.players[enemy].life == StartingLife
  for i in 0 ..< 60:
    discard play.advanceAttack(game, 1.0'f / 60)
  doAssert not play.attackActive
  doAssert game.players[enemy].life == StartingLife - 10
  doAssert game.currentPlayer == player
  doAssert game.players[player].board[0].hasAttacked
