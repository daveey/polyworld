## Light vs Dark match setup, command line, and the headless runner.
##
## Owns the one live world and decides where each tick's commands come from:
## BASIC overlords in a live match, or recorded commands when replaying.
## Everything else about a tick is identical between the two,
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
  import jsony, polyworld/coworld

  type HostedMapOptions = object
    mapLayout: string = "spoke"
    mapSize: int32 = DefaultMapSize
    expansions: int32 = 2
    minDistance: int32 = DefaultSpawnDistance
    warGraceSeconds: int32 = 10
    diplomacyOfferSeconds: int32 = 60

  proc renameHook(value: var HostedMapOptions, fieldName: var string) =
    ## Accepts the hosted contract's snake case map parameters.
    fieldName = fieldName.replace("_", "").toLowerAscii()
    case fieldName
    of "maplayout": fieldName = "mapLayout"
    of "mapsize": fieldName = "mapSize"
    of "mindistance": fieldName = "minDistance"
    of "wargraceseconds": fieldName = "warGraceSeconds"
    of "diplomacyofferseconds": fieldName = "diplomacyOfferSeconds"
    else: discard

  proc hostedMapSettings(diplomacy: var DiplomacySettings): MapSettings =
    ## Reads hosted map settings without changing the shared game config.
    var options: HostedMapOptions
    try:
      let bytes = readLocal(getEnv("COGAME_CONFIG_URI"))
      options = bytes.fromJson(HostedMapOptions)
    except JsonError, ValueError:
      raise newException(LvdError,
        "Invalid LvD map configuration: " & getCurrentExceptionMsg())
    case options.mapLayout.toLowerAscii()
    of "spoke", "spokes": result.layout = SpokeLayout
    of "random": result.layout = RandomLayout
    else:
      raise newException(LvdError, "map_layout must be spoke or random.")
    result.size = options.mapSize
    result.expansions = options.expansions
    result.minDistance = options.minDistance
    diplomacy = DiplomacySettings(
      warGraceSeconds: options.warGraceSeconds,
      offerSeconds: options.diplomacyOfferSeconds
    )
    diplomacy.validate()

proc usage() =
  ## Prints the command-line and compile-time configuration surface.
  echo """
Light vs Dark, a small real-time strategy match between any number of BASIC overlords.

  --bot PATH[:N]   Add N players using one BASIC program (default N=1).
  --player         Add a human player in slot 1.
  --player:N       Insert a human in slot N (one-based).
  --replay PATH    Play a recorded match instead of running bots.
  --record PATH    Record this match to a replay file.
  --seconds N      Duration in seconds (default 1200).
  --minutes N      Duration in minutes (default 20).
  --ticks N        Duration in ticks (default 28800).
  --seed N         Map seed (default 2026).
  --map-layout MODE  spoke or random (default spoke).
  --map-size N     Baseline map side for two players (default 90 tiles).
  --expansions N   Nearby expansions per player (default 2).
  --min-distance N Minimum spawn separation in tiles (default 45).
  --war-grace-seconds N  War warning; alliance withdrawal takes 2N (default 10).
  --diplomacy-offer-seconds N  Peace/alliance offer lifetime (default 60).
  --view MODE      Spectator fog: all or player number (light/dark aliases).
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

proc parseGameOptions(
  settings: var MapSettings, diplomacy: var DiplomacySettings
): GameOptions =
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
      of "--war-grace-seconds":
        diplomacy.warGraceSeconds = parsePositiveInt32(
          arguments.argumentValue(index, argument), argument
        )
      of "--diplomacy-offer-seconds":
        diplomacy.offerSeconds = parsePositiveInt32(
          arguments.argumentValue(index, argument), argument
        )
      of "--map-layout":
        case arguments.argumentValue(index, argument).toLowerAscii
        of "spoke", "spokes": settings.layout = SpokeLayout
        of "random": settings.layout = RandomLayout
        else: fail("--map-layout must be spoke or random")
      of "--map-size":
        settings.size = parsePositiveInt32(
          arguments.argumentValue(index, argument), argument
        )
      of "--expansions":
        settings.expansions = parseInt32(
          arguments.argumentValue(index, argument), argument
        )
      of "--min-distance":
        settings.minDistance = parsePositiveInt32(
          arguments.argumentValue(index, argument), argument
        )
      of "--view":
        let view = arguments.argumentValue(index, "--view").toLowerAscii
        case view
        of "all": result.viewMode = 0
        of "light": result.viewMode = 1
        of "dark": result.viewMode = 2
        else:
          result.viewMode = parsePositiveInt32(view, "--view")
      of "--help", "-h":
        usage()
        quit(0)
      else:
        fail("unknown argument: " & argument)
    inc index
  let count = result.botGroups.botCount + int(result.playerSlot > 0)
  result.validateGameOptions(count, "supply at least one --bot or --player")
  if result.replayPath.len == 0:
    settings.validate(count)
    diplomacy.validate()
    if result.viewMode > count:
      fail("--view names a player outside the roster")

var diplomacySettings* = DiplomacySettings()

var mapSettings* =
  when defined(coworld): hostedMapSettings(diplomacySettings)
  else: MapSettings()

var options* =
  when defined(coworld):
    coworldOptions(0)
  else:
    parseGameOptions(mapSettings, diplomacySettings)

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
      gameMap = generateMap(
        mapSeed,
        replayData.header.setup.players.len,
        replayData.header.setup.mapSettings
      )
    gameMap.validateMap()
    let setup = replayData.header.setup
    if int32(setup.gridTiles) != gameMap.side:
      raise newException(
        ReplayError, "Replay map size does not match its setup."
      )
    for i, player in setup.players:
      if tile2(player.startX, player.startY) != gameMap.hallOrigin[i]:
        raise newException(ReplayError, "Replay spawn does not match its map.")
    if setup.mapHash != gameMap.hash:
      raise newException(ReplayError,
        "this replay was recorded on a different map generator")
    if replayData.header.setup.contentHash != contentHash():
      raise newException(ReplayError,
        "this replay was recorded against different game tuning")
    if options.viewMode > gameMap.hallOrigin.len:
      fail("--view names a player outside the replay roster")
    run = newGame(gameMap, maximumTicks, setup.diplomacySettings)
    run.maximumTicks = int32(replayData.hashes.len)
    run.replayMode = true
    run.replayData = replayData
    run.replayPlayer = initReplayPlayer(replayData)
    run.historyPlayback = true
  else:
    let playerCount = options.botGroups.botCount + int(options.playerSlot > 0)
    var gameMap: MapData
    profileBlock "map":
      gameMap = generateMap(mapSeed, playerCount, mapSettings)
    gameMap.validateMap()
    run = newGame(gameMap, maximumTicks, diplomacySettings)
    let
      kinds = controllerKinds(playerCount, options.playerSlot)
      expanded = options.botGroups.expandBotSources(kinds)
    loadBots(run, expanded)
    var players: seq[ReplayPlayerSetup]
    for i, origin in gameMap.hallOrigin:
      players.add ReplayPlayerSetup(
        id: int32(i), startX: int32(origin.x), startY: int32(origin.y)
      )
    run.recorder = initReplayRecorder(Setup(
      mapSeed: mapSeed,
      tickRate: uint16(TickRate),
      gridTiles: uint16(gameMap.side),
      decisionTicks: uint16(DecisionTicks),
      maximumTicks: uint32(maximumTicks),
      mapHash: gameMap.hash,
      contentHash: contentHash(),
      players: players,
      mapSettings: mapSettings,
      diplomacySettings: diplomacySettings
    ))
    run.recorder.data.config =
      when defined(coworld):
        coworld.config
      else:
        localGameConfig(options, playerCount)
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
  if run.world.winner < 0:
    return "draw"
  let winner = int(run.world.winner)
  run.config.players[winner].displayName(winner) & " wins (score " &
    $run.world.score(int32(winner)) & ")"

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
  for player in 0'i32 ..< int32(run.world.players.len):
    let side = run.config.players[player].displayName(int(player))
    echo &"  {side}  gold {run.world.players[player].gold:>6}  " &
      &"wood {run.world.players[player].wood:>6}  " &
      &"food {run.world.players[player].foodUsed:>3}/" &
      &"{run.world.players[player].foodCap:<3}  " &
      &"units {run.world.unitCount(player):>3}  " &
      &"buildings {run.world.buildingCount(player):>2}  " &
      &"gathered {run.world.players[player].goldGathered + run.world.players[player].woodGathered:>7}"
  if not run.replayMode:
    for player in 0'i32 ..< int32(run.world.players.len):
      let brain = run.brains[player]
      if brain == nil:
        continue
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
