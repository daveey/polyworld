## Match setup, local controls, fixed ticks, and headless play.

import
  std/[os, strutils],
  sim, maps, bots, replays

type
  Options* = object
    seed*, players*, ticks*, player*: int
    speed*: float32
    role*, name*, record*, replay*, screenshot*: string
    width*, height*, captureTicks*: int
  Game* = ref object
    world*: SimServer
    ship*: ShipMap
    bots*: seq[Bot]
    nav: Navigator
    previous*: seq[InputState]
    input*: InputState
    choice*: int
    chat*: string
    recording*: ReplayData
    playback*: bool
    frame*: int

proc usage() =
  ## Prints the controls and native or headless launch options.
  echo "Crewrift in Polyworld"
  echo "  WASD: move or select vote. E / Space: use, kill, vote."
  echo "  Arrows / middle / right drag: pan. Wheel: zoom. C: action camera."
  echo "  Click / shift-click / box select: follow crew. Ctrl+A: select all."
  echo "  Q: vent. Enter: meeting chat. Tab: map. R: new match."
  echo "  --player:N        Control slot N (1-16, default 1)."
  echo "  --name:NAME       Human player's name in the roster and replay."
  echo "  --spectate        Let local bots play every slot."
  echo "  --role:crew|imp   Choose your role, or omit for random roles."
  echo "  --players:N       Roster size (8-16, default 8)."
  echo "  --seed:N          Match seed (default 2026)."
  echo "  --ticks:N         Maximum active ticks (default 10000)."
  echo "  --speed:N         Simulation speed (default 1)."
  echo "  --record:PATH     Save an input replay with tick fingerprints."
  echo "  --replay:PATH     Play and verify a saved input replay."
  echo "  --windowSize:WxH  Window size (default 1440x900)."
  echo "  --screenshot:PATH Save a frame and exit."
  echo "Compile with -d:headless to run and verify without graphics."

proc parseOptions*(): Options =
  ## Parses the shared native and headless command surface.
  result = Options(
    seed: 2026, players: MinPlayers, ticks: MaxTicks,
    player: 0, speed: 1, width: 1440, height: 900,
    captureTicks: RoleRevealTicks + 12
  )
  when defined(headless):
    result.player = -1
  for argument in commandLineParams():
    let
      parts = argument.split(':', 1)
      flag = parts[0]
      value = if parts.len > 1: parts[1] else: ""
    try:
      case flag
      of "--seed": result.seed = parseInt(value)
      of "--players": result.players = parseInt(value)
      of "--ticks": result.ticks = parseInt(value)
      of "--player": result.player = parseInt(value) - 1
      of "--name": result.name = value.strip()
      of "--spectate": result.player = -1
      of "--speed": result.speed = parseFloat(value).float32
      of "--role": result.role = value
      of "--record": result.record = value
      of "--replay": result.replay = value
      of "--screenshot": result.screenshot = value
      of "--capture-ticks": result.captureTicks = parseInt(value)
      of "--windowSize":
        let size = value.toLowerAscii().split('x')
        if size.len != 2:
          raise newException(CrewriftError, "Expected --windowSize:WxH.")
        result.width = parseInt(size[0])
        result.height = parseInt(size[1])
      of "--help", "-h":
        usage()
        quit(0)
      else:
        raise newException(CrewriftError, "Unknown argument: " & argument)
    except ValueError as error:
      raise newException(CrewriftError, "Invalid option: " & error.msg)
  if result.seed < RandomSeedSentinel or
    result.players < MinPlayers or result.players > MaxPlayers or
    result.player < -1 or result.player >= result.players or
    result.ticks < 1 or result.ticks > 1_000_000 or
    result.captureTicks < 0 or result.captureTicks > 1_000_000 or
    not (result.speed > 0 and result.speed <= 16) or
    result.width < 800 or result.height < 600:
      raise newException(CrewriftError, "Invalid roster, time, or window size.")
  if result.role notin ["", "crew", "imp"]:
    raise newException(CrewriftError, "Role must be crew or imp.")
  if result.record.len > 0 and result.replay.len > 0:
    raise newException(CrewriftError, "Choose recording or replay playback.")
  if result.name.len > 128 or result.name != cleanChatMessage(result.name):
    raise newException(CrewriftError, "Player name must be printable text.")

proc rewind*(game: Game) =
  ## Restores the resolved match setup while retaining the input tape.
  var config = game.recording.config
  config.minPlayers = game.recording.players
  game.world = initSimServer(config)
  game.world.fitStations()
  game.world.gameEventLoggingEnabled = false
  for i in 0 ..< config.minPlayers:
    discard game.world.addPlayer("crew " & $(i + 1))
  game.world.startGame()
  game.ship = game.world.buildShipMap()
  game.nav = Navigator(layer: game.ship.layer)
  game.bots = newSeq[Bot](config.minPlayers)
  for bot in game.bots.mitems:
    bot.task = -1
    bot.vote = -1
  game.previous = newSeq[InputState](config.minPlayers)
  game.input = InputState()
  game.choice = -1
  game.chat.setLen(0)
  game.frame = 0

proc newGame*(options: Options): Game =
  ## Creates one full roster and starts the original role reveal.
  result = Game(choice: -1)
  var config = defaultGameConfig()
  config.seed = options.seed
  config.minPlayers = options.players
  config.maxTicks = options.ticks
  if options.role.len > 0 and options.player >= 0:
    config.slots.setLen(options.players)
    config.slots[options.player].hasRole = true
    config.slots[options.player].role =
      if options.role == "imp": Imposter else: Crewmate
  if options.replay.len > 0:
    result.recording = loadReplay(options.replay)
    result.playback = true
  else:
    result.recording = ReplayData(
      version: ReplayVersion, config: config,
      players: config.minPlayers
    )
    for i in 0 ..< config.minPlayers:
      result.recording.playerNames.add(
        if i == options.player:
          if options.name.len > 0: options.name else: "You"
        else: "bots.nim"
      )
  result.rewind()
  result.recording.config = result.world.config

proc rosterName*(game: Game, slot: int): string =
  ## Labels each crew color with its recorded human or policy identity.
  let
    order = game.world.players[slot].joinOrder
    identity =
      if order < game.recording.playerNames.len:
        game.recording.playerNames[order]
      else: "Unknown"
  playerColorText(game.world.players[slot].color).capitalizeAscii() &
    " (" & identity & ")"

proc finished*(game: Game): bool =
  ## Returns whether the match or the complete replay has ended.
  if game.playback:
    game.frame >= game.recording.frames.len
  else:
    game.world.phase == GameOver

proc playerKills*(world: SimServer, slot: int): int =
  ## Reads the current match kill count from the crew member's reward account.
  for account in world.rewardAccounts:
    if account.slotIndex == world.players[slot].joinOrder:
      return account.kills

proc advance*(game: Game, player = -1, record = false) =
  ## Applies all player and bot commands before one authoritative tick.
  if game.finished():
    return
  var
    inputs = newSeq[InputState](game.world.players.len)
    frame = ReplayFrame(choices: newSeq[int](inputs.len))
  let history = game.frame < game.recording.frames.len
  for choice in frame.choices.mitems:
    choice = -1
  if not game.playback:
    for i in 0 ..< inputs.len:
      if i == player:
        inputs[i] = game.input
      else:
        inputs[i] = game.bots[i].decideBot(
          game.nav, game.world, i, game.previous[i]
        )
        if game.bots[i].chat.len > 0:
          frame.chats.add ReplayChat(slot: i, text: game.bots[i].chat)
          game.bots[i].chat.setLen(0)
    if player >= 0 and not history:
      if game.choice >= 0 and game.world.phase == Voting:
        frame.choices[player] = game.choice
        inputs[player].attack = not game.previous[player].attack
        if inputs[player].attack:
          game.choice = -1
      if game.chat.len > 0:
        frame.chats.add ReplayChat(slot: player, text: game.chat)
        game.chat.setLen(0)
    for input in inputs:
      frame.masks.add input.inputMask()
  if history:
    frame = game.recording.frames[game.frame]
    for i, mask in frame.masks:
      inputs[i] = readInput(mask)
  for i, choice in frame.choices:
    if choice >= 0 and game.world.phase == Voting:
      game.world.voteState.cursor[i] = choice
  for chat in frame.chats:
    game.world.addVotingChat(chat.slot, chat.text)
  game.world.step(inputs, game.previous)
  game.previous = inputs
  if history:
    game.world.verifyFrame(frame)
  elif record:
    frame.hash = game.world.gameHash().toHex(16)
    game.recording.frames.add frame
  inc game.frame

proc runHeadless*(options: Options) =
  ## Runs local policies or verifies all recorded simulation ticks.
  let game = newGame(options)
  while not game.finished():
    game.advance(record = options.record.len > 0)
  saveReplay(options.record, game.recording)
  let outcome =
    if game.world.phase != GameOver: "partial replay"
    elif game.world.timeLimitReached: "time limit"
    elif game.world.winner == Crewmate: "crew win"
    else: "imposter win"
  echo "Crewrift: ", outcome, ", tick ", game.world.tickCount,
    ", tasks left ", game.world.totalTasksRemaining()
  echo "Hash: ", game.world.gameHash().toHex(16)
  if game.playback:
    echo "Replay verified: ", game.frame, " ticks matched."
