## Gods of the Arena match setup, command line, and the headless runner.
##
## Owns the one live match and decides where each tick's hero commands
## come from: ten BASIC programs, or the recorded action stream when
## replaying.

import
  std/[math, os, strformat, strutils, times],
  polyworld/[cli, controllers, metrics, profiles, tapes, timings],
  content,
  maps,
  sim,
  bots,
  controls,
  replays

when defined(coworld):
  import polyworld/coworld

var matchConfig = GotaConfig(seed: ArenaSeed)

proc usage() =
  ## Prints the command-line and compile-time configuration surface.
  echo "Gods of the Arena"
  echo "  --bot:PATH              Fill one of the 10 hero slots."
  echo "  --bot:PATH:N            Fill N of the 10 slots with that file."
  echo "  --bot PATH[:N]          The equivalent two-argument form."
  echo "  --player                Control the first hero; supply 9 bots."
  echo "  --player:N              Control hero N (1-10); supply 9 bots."
  echo "  --replay PATH           Play an action replay instead of bots."
  echo "  --record PATH           Record bot actions to a replay."
  echo "  --seconds NUMBER        Battle seconds (default 1200)."
  echo "  --minutes NUMBER        Battle minutes (default 20)."
  echo "  --ticks NUMBER          Battle ticks (default 28800)."
  echo "Drafting allows 10 seconds per pick, separate from battle time."
  echo "  --seed NUMBER           Match seed for draft order, bot turn order,"
  echo "                          and combat randomness; the arena stays fixed."
  echo "  --map-seed NUMBER       Regenerate the arena from another seed (the"
  echo "                          league always plays the preset's own seed)."
  echo "  --config PATH           JSON match settings, including mapPreset."
  echo "  --headless-tick-rate N   Wall-clock ticks per second, 0 is unlimited."
  echo "  --llm-mode:async|barrier Wait for all requests between headless ticks."
  echo "  --spawn-interval NUMBER Seconds between waves."
  echo "  --play=false            Start the graphical transport paused."
  echo "  --speed NUMBER          Graphical start speed: 1, 2, 4, or 16."
  echo "  --windowSize WxH        Graphical window, such as 1024x576."
  echo "  --vsync:off             Unlock the frame rate (default on)."
  echo "Compile with -d:headless for command-line simulation."
  echo "Compile with -d:emscripten for the web backend."

proc parseGameOptions(): GameOptions =
  ## Parses runtime game, bot, replay, and simulation configuration.
  let arguments = commandLineParams()
  var index = 0
  while index < arguments.len:
    if arguments[index] == "--config":
      matchConfig = loadConfig(arguments.argumentValue(index, "--config"))
    inc index
  result = GameOptions(
    seed: matchConfig.seed,
    seconds: matchConfig.maxTicks div TickRate,
    maximumTicks: matchConfig.maxTicks,
    spawnIntervalTicks: matchConfig.spawnIntervalTicks,
    playerSlot: matchConfig.playerSlot,
    headlessTickRate: matchConfig.headlessTickRate,
    waitForLlm: matchConfig.waitForLlm,
    speed: 1
  )
  index = 0
  while index < arguments.len:
    let argument = arguments[index]
    if result.takeCommonFlag(arguments, index, argument):
      discard
    else:
      case argument
      of "--config":
        discard arguments.argumentValue(index, "--config")
      of "--map-seed":
        matchConfig.mapPreset.seed = parseInt32(
          arguments.argumentValue(index, "--map-seed"),
          "--map-seed"
        )
      of "--spawn-interval":
        var seconds: float64
        try:
          seconds = parseFloat(
            arguments.argumentValue(index, "--spawn-interval")
          )
        except ValueError:
          fail("--spawn-interval must be a number")
        if seconds <= 0:
          fail("--spawn-interval must be positive")
        if seconds > int32.high.float64 / TickRate.float64:
          fail("--spawn-interval is too large")
        result.spawnIntervalTicks = int32(round(
          seconds * TickRate.float64
        ))
        if result.spawnIntervalTicks <= 0:
          fail("--spawn-interval must be positive")
      of "--help", "-h":
        usage()
        quit(0)
      else:
        fail("unknown argument: " & argument)
    inc index
  result.validateGameOptions(
    HeroClassCount,
    "live games require exactly 10 bots"
  )

var options* =
  when defined(coworld):
    block:
      let hosted = coworldOptions(10)
      matchConfig = parseConfig(readLocal(getEnv("COGAME_CONFIG_URI")))
      hosted
  else:
    parseGameOptions()

var run*: Game

block:
  startGameProfile()
  var
    replayMode = options.replayPath.len > 0
    mapSeed = options.seed
    replayData: ReplayData
  if replayMode:
    profileBlock "replay":
      replayData = loadReplay(options.replayPath)
    mapSeed = replayData.config.seed
    options.maximumTicks = int32(replayData.hashes.len)
  var gameMap: MapData
  profileBlock "map":
    gameMap =
      if replayMode:
        generateMap(mapSeed, replayData.config.mapPreset)
      else:
        generateMap(mapSeed, matchConfig.mapPreset)
  run = newGame(
    gameMap,
    if replayMode:
      replayData.config.spawnIntervalTicks
    else:
      options.spawnIntervalTicks,
    if replayMode: 0 else: HeroClassCount,
    replayMode,
    replayData
  )
  if replayMode:
    run.replayPlayer = initReplayPlayer(replayData)
    run.historyPlayback = true
  else:
    loadBots(run, options.botGroups, options.playerSlot)
    run.recorder = initReplayRecorder(
      currentSetup(run, uint32(options.maximumTicks)), gameMap.preset
    )
    run.recorder.data.config =
      when defined(coworld):
        coworld.config.withMapPreset(gameMap.preset)
      else:
        block:
          var config = localGameConfig(options, HeroClassCount)
          if matchConfig.players.len > 0:
            config.players = matchConfig.players
          config.withMapPreset(gameMap.preset)
    run.recorder.data.config.validateConfig(HeroClassCount)
    run.replayPlayer = ReplayPlayer(data: run.recorder.data)

proc advanceGame*() =
  ## Advances one tick, including live BASIC decisions.
  tickWorld(run, proc() =
    let draftTurn = run.world.draftHeroId()
    flushPlayerCommands(run)
    if draftTurn == 0 or draftTurn == run.world.draftHeroId():
      runBotDecisions(run)
  )

  run.sampleMetrics(run.finished() or
    (run.replayMode and run.world.tick == run.replayData.hashes.len))
  run.metrics.finishTick(run.world.tick)

## Headless reporting and replay recording.

proc teamHeroLevels(team: Team): string =
  ## Formats the current hero levels for one team.
  for hero in run.world.heroes:
    if hero.team != team:
      continue
    if result.len > 0:
      result.add " "
    result.add "L" & $hero.level

proc teamHeroXp(team: Team): int =
  ## Returns all lifetime XP earned by one team's heroes.
  for hero in run.world.heroes:
    if hero.team == team:
      result += hero.totalXp

proc teamHeroXps(team: Team): string =
  ## Formats each hero's lifetime XP for one team, in slot order.
  for hero in run.world.heroes:
    if hero.team != team:
      continue
    if result.len > 0:
      result.add " "
    result.add $hero.totalXp

proc teamHeroGold(team: Team): int =
  ## Returns all unspent gold earned by one team's heroes.
  for hero in run.world.heroes:
    if hero.team == team:
      result += hero.gold

proc teamTowerCount(team: Team): int =
  ## Returns the number of standing towers owned by one team.
  for tower in run.world.buildings:
    if tower.kind == TowerBuilding and tower.team == team and tower.hp > 0:
      inc result

proc heroVmStatus*(): tuple[active, decisions: int] =
  ## Reports live VM decisions or consumed replay actions.
  if run.replayMode:
    result.active = run.world.heroes.len
    result.decisions = run.replayPlayer.actionIndex
  else:
    for vm in run.heroVms:
      if vm != nil and not vm.failed:
        inc result.active
      if vm != nil:
        result.decisions += vm.decisions

proc startReplayRecording*(maximumTicks: uint32) =
  ## Starts the in-memory action tape for a live match.
  var config = run.config
  config.maxTicks = int32(maximumTicks)
  run.recorder = initReplayRecorder(
    currentSetup(run, maximumTicks), config.mapPreset
  )
  run.recorder.data.config = config
  run.replayPlayer = ReplayPlayer(data: run.recorder.data)

proc saveRecording*(path = options.recordPath) =
  ## Finalizes and saves a requested action replay.
  if run.recorder == nil or path.len == 0:
    return
  if run.world.tick == run.recorder.data.hashes.len:
    run.sampleMetrics(true)
  run.recorder.data.metrics = run.history.replayMetrics()
  saveReplay(path, run.recorder.data)
  echo &"replay saved: {path} " &
    &"({run.recorder.data.actions.len} actions)"

when defined(headless):
  const HeadlessTickRate = TickRate

  proc printHeadlessSummary(steps: int, started: float64) =
    ## Prints the deterministic result and measured execution speed.
    let
      elapsed = max(epochTime() - started, 0.000001)
      simulated = steps.float64 / HeadlessTickRate.float64
      draftSeconds = run.world.draftTicks.float64 / HeadlessTickRate.float64
      battleSeconds = run.world.battleTick().float64 / HeadlessTickRate.float64
      speedup = simulated / elapsed
      vmStatus = heroVmStatus()
      redFortHp = max(run.world.forts[0].hp, 0'i32)
      blueFortHp = max(run.world.forts[1].hp, 0'i32)
      outcome =
        if run.world.draw:
          "draw"
        elif run.world.gameOver:
          if run.world.winner == RedTeam: "red won" else: "blue won"
        elif run.world.phase == Drafting:
          "draft incomplete"
        else:
          "time limit"
    echo &"result: {outcome}"
    echo &"seeds: match {run.map.seed}, map {run.map.preset.seed}"
    echo &"simulated: {simulated:.2f} s in {elapsed:.4f} s " &
      &"({speedup:.1f}x real time)"
    echo &"draft: {draftSeconds:.2f} s, battle: {battleSeconds:.2f} s"
    echo &"gods: red {redFortHp} hp, blue {blueFortHp} hp"
    echo &"towers: red {teamTowerCount(RedTeam)}, " &
      &"blue {teamTowerCount(BlueTeam)}"
    echo &"hash: {run.stateHash().toHex(16)} map " &
      &"{run.map.hash.toHex(16)}"
    echo &"heroes: red {teamHeroLevels(RedTeam)}, " &
      &"blue {teamHeroLevels(BlueTeam)}"
    echo &"economy: red {teamHeroXp(RedTeam)} XP / " &
      &"{teamHeroGold(RedTeam)} gold, blue {teamHeroXp(BlueTeam)} XP / " &
      &"{teamHeroGold(BlueTeam)} gold"
    echo &"xp: red {teamHeroXps(RedTeam)}, blue {teamHeroXps(BlueTeam)}"
    if run.replayMode:
      echo &"replay: {vmStatus.decisions}/" &
        &"{run.replayData.actions.len} actions"
      if run.hashCheck.mismatches > 0:
        echo &"replay hashes: {run.hashCheck.mismatches} mismatches"
    else:
      echo &"scripts: {vmStatus.active}/{run.world.heroes.len} active, " &
        &"{vmStatus.decisions} decisions"

  proc runHeadless*() =
    ## Runs fixed simulation ticks with optional pacing and request barriers.
    let started = epochTime()
    if not run.replayMode:
      startReplayRecording(uint32(options.maximumTicks))
    startGameProfile()
    defer:
      finishGameProfile()
    var
      steps = 0
      pacer = initTickPacer(options.headlessTickRate)
      pollers: seq[RequestPoll]
    if options.waitForLlm and not run.replayMode:
      for vm in run.heroVms:
        if vm != nil:
          pollers.add vm.pollRequests
    while (if run.replayMode: steps < run.replayData.hashes.len
        else: not run.finished()) and
        run.recordingError.len == 0:
      advanceGame()
      waitForRequests(pollers)
      pacer.pace()
      inc steps
      if profileShouldDump(steps):
        finishGameProfile()
    if run.recordingError.len > 0:
      raise newException(ReplayError, run.recordingError)
    if run.replayMode:
      run.hashCheck.requireReplayComplete(
        uint32(run.world.tick),
        run.replayData.hashes.len
      )
      if not run.replayPlayer.finished:
        raise newException(
          ReplayError,
          "replay simulation did not consume every action"
        )
    else:
      saveRecording()
    printHeadlessSummary(steps, started)
