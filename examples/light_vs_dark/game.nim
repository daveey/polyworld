## Light vs Dark match setup, command line, and the headless runner.
##
## Owns the one live world and decides where each tick's commands come from:
## two BASIC overlords in a live match, or the recorded action stream when
## replaying. Everything else about a tick is identical between the two,
## which is what makes a replay reproduce its match exactly.

import
  std/[os, strformat, strutils, times],
  polyworld/[cli, controllers, metrics, profiles, tapes, timings],
  content,
  maps as mapgen,
  sim,
  bots,
  controls,
  replays

when defined(coworld):
  import polyworld/coworld

proc usage() =
  ## Prints the command-line and compile-time configuration surface.
  echo """
Light vs Dark, a small real-time strategy match between two BASIC overlords.

  --bot PATH[:N]   Fill N of the two player slots with one BASIC program.
  --player         Control Light; supply one bot.
  --player:N       Control side N (1 Light, 2 Dark); supply one bot.
  --replay PATH    Play a recorded match instead of running bots.
  --record PATH    Record this match to a replay file.
  --seconds N      Duration in seconds (default 1200).
  --minutes N      Duration in minutes (default 20).
  --ticks N        Duration in ticks (default 28800).
  --seed N         Map seed (default 2026).
  --view MODE      Spectator fog: all, light, or dark (default all).
  --play=false     Start the graphical transport paused.
  --speed N        Graphical start speed: 1, 2, 4, or 16.
  --windowSize WxH Graphical window, such as 800x400.
  --vsync:off      Unlock the frame rate (default on).
  --headless-tick-rate N  Wall-clock ticks per second, 0 is unlimited.
  --llm-mode:async|barrier Wait for all requests between headless ticks.
  --help           Show this message.

Compile with -d:headless for a command-line match.
Compile with -d:emscripten for the web backend.
Compile with -d:takeScreenshot for a deterministic capture."""

proc parseGameOptions(): GameOptions =
  ## Reads the command line into a validated match description.
  result = GameOptions(
    seconds: DefaultMinutes * 60,
    maximumTicks: DefaultDurationTicks,
    seed: DefaultSeed,
    speed: 1
  )
  let arguments = commandLineParams()
  var index = 0
  while index < arguments.len:
    let argument = arguments[index]
    if result.takeCommonFlag(arguments, index, argument):
      discard
    else:
      case argument
      of "--view":
        case arguments.argumentValue(index, "--view").toLowerAscii
        of "all": result.viewMode = 0
        of "light": result.viewMode = 1
        of "dark": result.viewMode = 2
        else:
          fail("--view must be all, light, or dark")
      of "--help", "-h":
        usage()
        quit(0)
      else:
        fail("unknown argument: " & argument)
    inc index
  result.validateGameOptions(
    PlayerCount,
    "a live match requires exactly two bots"
  )

var options* =
  when defined(coworld):
    coworldOptions(2)
  else:
    parseGameOptions()

var run*: Game

block:
  startGameProfile()
  var
    mapSeed = options.seed
    maximumTicks = options.maximumTicks
  if options.replayPath.len > 0:
    var replayData: ReplayData
    profileBlock "replay":
      replayData = loadReplay(options.replayPath)
    mapSeed = replayData.config.seed
    maximumTicks = replayData.config.maxTicks
    var gameMap: MapData
    profileBlock "map":
      gameMap = generateMap(mapSeed)
    gameMap.validateMap()
    if replayData.header.setup.mapHash != gameMap.hash:
      raise newException(ReplayError,
        "this replay was recorded on a different map generator")
    if replayData.header.setup.contentHash != contentHash():
      raise newException(ReplayError,
        "this replay was recorded against different game tuning")
    run = newGame(gameMap, maximumTicks)
    run.maximumTicks = int32(replayData.hashes.len)
    run.replayMode = true
    run.replayData = replayData
    run.replayPlayer = initReplayPlayer(replayData)
    run.historyPlayback = true
  else:
    var gameMap: MapData
    profileBlock "map":
      gameMap = generateMap(mapSeed)
    gameMap.validateMap()
    run = newGame(gameMap, maximumTicks)
    let
      kinds = controllerKinds(PlayerCount, options.playerSlot)
      expanded = options.botGroups.expandBotSources(kinds)
    var sources: array[PlayerCount, string]
    for i in 0 ..< PlayerCount:
      sources[i] = expanded[i]
    loadBots(run, sources)
    run.recorder = initReplayRecorder(Setup(
      mapSeed: mapSeed,
      tickRate: uint16(TickRate),
      gridTiles: uint16(GridSide),
      decisionTicks: uint16(DecisionTicks),
      maximumTicks: uint32(maximumTicks),
      mapHash: gameMap.hash,
      contentHash: contentHash(),
      players: [
        ReplayPlayerSetup(
          id: 0,
          startX: uint8(gameMap.hallOrigin[LightPlayer].x),
          startY: uint8(gameMap.hallOrigin[LightPlayer].y)
        ),
        ReplayPlayerSetup(
          id: 1,
          startX: uint8(gameMap.hallOrigin[DarkPlayer].x),
          startY: uint8(gameMap.hallOrigin[DarkPlayer].y)
        )
      ]
    ))
    run.recorder.data.config =
      when defined(coworld):
        coworld.config
      else:
        localGameConfig(options, PlayerCount)
    run.replayPlayer = ReplayPlayer(data: run.recorder.data)

proc decide(w: World) =
  ## Supplies one decision tick's commands from whichever source owns them.
  if run.historyPlayback:
    if run.recorder != nil:
      run.replayPlayer.data = run.recorder.data
    var action: ReplayAction
    while run.replayPlayer.takeActionAt(uint32(w.tick), action):
      if w.applyReplayAction(action):
        run.metrics.command(int(action.playerId), w.tick)
  else:
    flushPlayerCommands(run)
    runBotDecisions(run)

proc verifyTick(game: Game) =
  ## Compares one tick against its recorded fingerprint.
  let hashes =
    if game.recorder != nil: game.recorder.data.hashes
    else: game.replayPlayer.data.hashes
  hashes.checkReplayHash(
    uint32(game.world.tick),
    game.stateHash(),
    game.hashCheck
  )

proc advanceGame*() =
  ## Advances the live world by one tick and verifies it when replaying.
  run.world.tickWorld(decide)
  if run.historyPlayback:
    run.verifyTick()
  elif run.recorder != nil:
    run.recorder.recordHash(run.stateHash())
  run.sampleMetrics(run.world.over or run.world.tick >= run.maximumTicks)
  run.metrics.finishTick(run.world.tick)

proc saveRecording*(path = options.recordPath) =
  ## Saves every recorded tick, keeping the original match setup.
  ## Creates the destination directory before writing the tape.
  if run.recorder == nil or path.len == 0:
    return
  let directory = path.parentDir
  if directory.len > 0:
    createDir(directory)
  if run.world.tick == run.recorder.data.hashes.len:
    run.sampleMetrics(true)
  run.recorder.data.metrics = run.history.replayMetrics()
  saveReplay(path, run.recorder.data)

proc describeResult*(): string =
  ## One line naming the outcome and the score behind it.
  if not run.world.over:
    return "match unfinished"
  let
    light = run.world.score(LightPlayer)
    dark = run.world.score(DarkPlayer)
  case run.world.winner
  of LightPlayer: &"Light wins ({light} to {dark})"
  of DarkPlayer: &"Dark wins ({dark} to {light})"
  else: &"draw ({light} to {dark})"

proc runHeadless*() =
  ## Runs fixed simulation ticks with optional pacing and request barriers.
  startGameProfile()
  defer:
    finishGameProfile()
  let started = epochTime()
  var
    pacer = initTickPacer(options.headlessTickRate)
    pollers: seq[RequestPoll]
  if options.waitForLlm and not run.replayMode:
    for vm in run.brains:
      if vm != nil:
        pollers.add vm.pollRequests
  while run.world.tick < run.maximumTicks and not run.world.over:
    advanceGame()
    waitForRequests(pollers)
    pacer.pace()
    if profileShouldDump(run.world.tick):
      finishGameProfile()
  let
    elapsed = max(epochTime() - started, 0.000001)
    simulated = run.world.tick.float64 / TickRate.float64

  echo &"seed {run.mapSeed}  ticks {run.world.tick}/{run.maximumTicks}  " &
    &"{simulated:.1f}s simulated in {elapsed:.2f}s " &
    &"({simulated / elapsed:.0f}x real time)"
  for player in 0'i32 ..< PlayerCount:
    let side = if player == LightPlayer: "Light" else: "Dark "
    echo &"  {side}  gold {run.world.players[player].gold:>6}  " &
      &"wood {run.world.players[player].wood:>6}  " &
      &"food {run.world.players[player].foodUsed:>3}/" &
      &"{run.world.players[player].foodCap:<3}  " &
      &"units {run.world.unitCount(player):>3}  " &
      &"buildings {run.world.buildingCount(player):>2}  " &
      &"gathered {run.world.players[player].goldGathered + run.world.players[player].woodGathered:>7}"
  if not run.replayMode:
    for player in 0'i32 ..< PlayerCount:
      let brain = run.brains[player]
      if brain.failed:
        when not defined(coworld):
          echo &"         script FAILED: {brain.lastError}"
      else:
        echo &"         {brain.decisions} decisions, last used " &
          &"{brain.lastInstructions} instructions and {brain.lastWork} work"
  echo "  ", describeResult()
  echo &"  {pathSearches} path searches, {pathExpansions} expansions"

  if run.replayMode:
    if not run.replayPlayer.finished:
      echo "error: the replay still had commands left to run"
      quit(1)
    run.hashCheck.requireReplayComplete(
      uint32(run.world.tick),
      run.replayData.hashes.len
    )
    echo "  replay verified: every tick matched its recorded hash"
  else:
    saveRecording()
    if options.recordPath.len > 0:
      echo &"  recorded {run.recorder.data.actions.len} commands to " &
        options.recordPath
