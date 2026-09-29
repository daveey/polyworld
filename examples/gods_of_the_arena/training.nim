## Native decision batches for external GotA trainers.
##
## Each lane owns a worker thread. The worker blocks inside the policy host
## callback until the caller supplies an action, so the BASIC runtime needs no
## resumable-execution extension. Batch operations still advance lanes in
## deterministic sequence.
import std/[locks, strutils]
include bots

const
  GotaSourceCommit {.strdefine.} = ""
  GotaFeatureCount* {.intdefine.} = 8
  GotaActionCount* {.intdefine.} = 8
  GotaOutcomeReward* = 100'f32
  GotaActionRepeat* {.intdefine.} = 4
  StopAction = -1'i32

type
  Transition* {.bycopy.} = object
    features*: array[GotaFeatureCount, float32]
    reward*: float32
    terminal*, tick*, seat*, outcome*: int32
    stateHash*: uint64
    xp*, structureHp*, heroXp*, heroGold*, heroKills*, heroDeaths*: int64
    maxWork*, maxInstructions*: int64

  LaneBridge = object
    lock: Lock
    actionReady, transitionReady: Cond
    action: int32
    transition: Transition
    hasAction, hasTransition: bool

  LaneWorkerArgs = object
    bridge: ptr LaneBridge
    configPath, bot, opponent, policy: string
    seed, maxTicks: int

  TrainingLane* = ref object
    bridge: ptr LaneBridge
    worker: Thread[LaneWorkerArgs]
    seed: int
    transition*: Transition

  TrainingBatch* = ref object
    lanes*: seq[TrainingLane]
    configPath, bot, policy: string
    opponents: seq[string]
    maxTicks: int

var simulationLock: Lock
initLock(simulationLock)

proc trainingPotential*(transition: Transition): int64 =
  transition.xp + transition.structureHp

proc trainingReward*(previous, current: int64, outcome: int32): float32 =
  float32(current - previous) / 1000'f32 +
    float32(outcome) * GotaOutcomeReward

proc sendAction(bridge: ptr LaneBridge, action: int32) =
  acquire(bridge.lock)
  doAssert not bridge.hasAction
  bridge.action = action
  bridge.hasAction = true
  signal(bridge.actionReady)
  release(bridge.lock)

proc receiveAction(bridge: ptr LaneBridge): int32 =
  acquire(bridge.lock)
  while not bridge.hasAction:
    wait(bridge.actionReady, bridge.lock)
  result = bridge.action
  bridge.hasAction = false
  release(bridge.lock)

proc sendTransition(bridge: ptr LaneBridge, transition: Transition) =
  acquire(bridge.lock)
  doAssert not bridge.hasTransition
  bridge.transition = transition
  bridge.hasTransition = true
  signal(bridge.transitionReady)
  release(bridge.lock)

proc receiveTransition(bridge: ptr LaneBridge): Transition =
  acquire(bridge.lock)
  while not bridge.hasTransition:
    wait(bridge.transitionReady, bridge.lock)
  result = bridge.transition
  bridge.hasTransition = false
  release(bridge.lock)

proc runLane(args: LaneWorkerArgs) {.thread.} =
  {.cast(gcsafe).}:
    acquire(simulationLock)
    let
      config = loadConfig(args.configPath)
      gameMap = generateMap(int32(args.seed), config.mapPreset)
      game = newGame(
        gameMap, config.spawnIntervalTicks, 10, false, ReplayData(), false
      )
      team = Team((args.seed mod 10) div 5)
      groups =
        if team == RedTeam:
          @[BotGroup(path: args.bot, count: 5),
            BotGroup(path: args.opponent, count: 5)]
        else:
          @[BotGroup(path: args.opponent, count: 5),
            BotGroup(path: args.bot, count: 5)]
    loadBots(game, groups)
    game.replayData = initReplayData(
      currentSetup(game, uint32(args.maxTicks)), gameMap.preset
    )
    var
      reportingSeat = 0
      previousScore: int64
      observed, stopped: bool

    proc snapshot(terminal: bool, features: openArray[int32] = []): Transition =
      result.tick = game.world.tick
      result.seat = int32(reportingSeat)
      result.terminal = int32(terminal)
      result.outcome =
        if game.world.gameOver and game.world.winner == team: 1
        elif game.world.gameOver or terminal: -1
        else: 0
      result.stateHash = stateHash(game)
      for index, value in features:
        doAssert index < GotaFeatureCount
        doAssert value in -100 .. 100
        result.features[index] = float32(value)
      for hero in game.world.heroes:
        result.xp += (if hero.team == team: 1 else: -1) * hero.totalXp
      for building in game.world.buildings:
        if building.kind == TowerBuilding:
          result.structureHp +=
            2 * (if building.team == team: 1 else: -1) * max(building.hp, 0)
      for fort in game.world.forts:
        result.structureHp +=
          20 * (if fort.team == team: 1 else: -1) * max(fort.hp, 0)
      let hero = game.world.heroes[reportingSeat]
      result.heroXp = hero.totalXp
      result.heroGold = game.world.stats.values[reportingSeat][GoldMetric]
      result.heroKills = game.world.stats.values[reportingSeat][KillsMetric]
      result.heroDeaths = game.world.stats.values[reportingSeat][LossesMetric]
      for vm in game.heroVms:
        if vm != nil:
          doAssert not vm.failed, vm.lastError
          result.maxWork = max(result.maxWork,
            max(vm.lastWork, vm.runtime.workUsed))
          result.maxInstructions = max(result.maxInstructions,
            max(vm.lastInstructions, vm.runtime.instructionsUsed))
      let score = result.trainingPotential()
      if observed:
        result.reward = trainingReward(previousScore, score, result.outcome)
      else:
        observed = true
      previousScore = score

    proc installPolicy(index: int) =
      let hero = game.world.heroes[index]
      var
        host = initHeroHost(hero.id)
        limits = heroVmLimits()
      limits.disableFixed = true
      limits.maxParameters = GotaFeatureCount
      discard host.addFunction("chooseAction", GotaFeatureCount,
        proc(values: openArray[int32]): int32 =
          if stopped:
            return 0
          reportingSeat = index
          args.bridge.sendTransition(snapshot(false, values))
          release(simulationLock)
          let action = args.bridge.receiveAction()
          acquire(simulationLock)
          if action == StopAction:
            stopped = true
            return 0
          doAssert action in 0 ..< GotaActionCount,
            "action outside GotaActionCount"
          # Other lanes ticked while this one waited; point the shared
          # globals back at this match before its heroes continue.
          activeGame = game
          bindNavigation(game.world)
          action,
        1)
      inc limits.maxHostFunctions
      var featureArguments: seq[string]
      for featureIndex in 0 ..< GotaFeatureCount:
        featureArguments.add "f(" & $featureIndex & ")"
      let source = args.policy.replace("' METTA_DECISION",
        "neuralActionCountdown = neuralActionCountdown - 1\n" &
        "if neuralActionCountdown <= 0 then\n" &
        "  neuralActionCountdown = " & $GotaActionRepeat & "\n" &
        "  decision = chooseAction(" & featureArguments.join(",") & ")\n" &
        "end if")
      let program = compile(source, host, limits)
      bindHeroData(program)
      game.heroVms[index] = HeroVm(
        runtime: initRuntime(program, host, limits), limits: limits, ready: true
      )

    for index, hero in game.world.heroes:
      if hero.team == team:
        installPolicy(index)
    while not stopped and not game.world.gameOver and
        game.world.tick < args.maxTicks:
      tickWorld(game, proc() = runBotDecisions(game))
      for vm in game.heroVms:
        doAssert not vm.failed, vm.lastError
    if not stopped:
      args.bridge.sendTransition(snapshot(true))
    release(simulationLock)

proc newLane(batch: TrainingBatch, seed: int): TrainingLane =
  result = TrainingLane(
    bridge: cast[ptr LaneBridge](allocShared0(sizeof(LaneBridge))),
    seed: seed
  )
  initLock(result.bridge.lock)
  initCond(result.bridge.actionReady)
  initCond(result.bridge.transitionReady)
  let opponent = batch.opponents[(seed div 10) mod batch.opponents.len]
  createThread(result.worker, runLane, LaneWorkerArgs(
    bridge: result.bridge,
    configPath: batch.configPath,
    bot: batch.bot,
    opponent: opponent,
    policy: batch.policy,
    seed: seed,
    maxTicks: batch.maxTicks
  ))
  result.transition = result.bridge.receiveTransition()

proc close*(lane: TrainingLane) =
  if lane.transition.terminal == 0:
    lane.bridge.sendAction(StopAction)
  lane.worker.joinThread()
  deinitCond(lane.bridge.transitionReady)
  deinitCond(lane.bridge.actionReady)
  deinitLock(lane.bridge.lock)
  deallocShared(lane.bridge)

proc advance*(lane: TrainingLane, action: int32) =
  doAssert lane.transition.terminal == 0
  doAssert action in 0 ..< GotaActionCount, "action outside GotaActionCount"
  lane.bridge.sendAction(action)
  lane.transition = lane.bridge.receiveTransition()

proc reset*(batch: TrainingBatch, seed: int) =
  for index in 0 ..< batch.lanes.len:
    let nextSeed =
      if seed == -1: batch.lanes[index].seed + batch.lanes.len
      else: seed * batch.lanes.len + index
    batch.lanes[index].close()
    batch.lanes[index] = batch.newLane(nextSeed)

proc newTrainingBatch*(
    configPath, bot, opponent, policy: string,
    count, maxTicks: int
): TrainingBatch =
  doAssert count > 0 and maxTicks in 1 .. 28_800
  let opponents = opponent.splitLines()
  doAssert opponents.len > 0
  for path in opponents:
    doAssert path.len > 0
  result = TrainingBatch(
    configPath: configPath,
    bot: bot,
    opponents: opponents,
    policy: policy,
    maxTicks: maxTicks
  )
  for index in 0 ..< count:
    result.lanes.add result.newLane(index)

proc step*(
    batch: TrainingBatch,
    actions: openArray[int32],
    transitions: var openArray[Transition]
) =
  doAssert actions.len == batch.lanes.len and
    transitions.len == batch.lanes.len
  for index, lane in batch.lanes:
    lane.advance(actions[index])
    transitions[index] = lane.transition
    if lane.transition.terminal != 0:
      let nextSeed = lane.seed + batch.lanes.len
      lane.close()
      batch.lanes[index] = batch.newLane(nextSeed)

proc gota_source_commit(): cstring {.cdecl, exportc, dynlib.} =
  GotaSourceCommit.cstring

proc gota_transition_size(): cint {.cdecl, exportc, dynlib.} =
  cint(sizeof(Transition))

proc gota_create(
    config, bot, opponent, policy: cstring,
    count, maxTicks: cint
): pointer {.cdecl, exportc, dynlib.} =
  let batch = newTrainingBatch(
    $config, $bot, $opponent, readFile($policy), int(count), int(maxTicks)
  )
  GC_ref(batch)
  cast[pointer](batch)

proc gota_reset(
    handle: pointer,
    seed: int64,
    observations: ptr UncheckedArray[float32],
    transitions: ptr UncheckedArray[Transition]
) {.cdecl, exportc, dynlib.} =
  let batch = cast[TrainingBatch](handle)
  batch.reset(int(seed))
  for index, lane in batch.lanes:
    copyMem(observations[index * GotaFeatureCount].addr,
      lane.transition.features[0].addr,
      GotaFeatureCount * sizeof(float32))
    transitions[index] = lane.transition

proc gota_step(
    handle: pointer,
    actions: ptr UncheckedArray[int32],
    observations, rewards: ptr UncheckedArray[float32],
    terminals: ptr UncheckedArray[uint8],
    transitions: ptr UncheckedArray[Transition]
) {.cdecl, exportc, dynlib.} =
  let
    batch = cast[TrainingBatch](handle)
    count = batch.lanes.len
  batch.step(
    actions.toOpenArray(0, count - 1),
    transitions.toOpenArray(0, count - 1)
  )
  for index, lane in batch.lanes:
    copyMem(observations[index * GotaFeatureCount].addr,
      lane.transition.features[0].addr,
      GotaFeatureCount * sizeof(float32))
    rewards[index] = transitions[index].reward
    terminals[index] = uint8(transitions[index].terminal)

proc close*(batch: TrainingBatch) =
  for lane in batch.lanes:
    lane.close()
  batch.lanes.setLen(0)

proc gota_close(handle: pointer) {.cdecl, exportc, dynlib.} =
  let batch = cast[TrainingBatch](handle)
  batch.close()
  GC_unref(batch)
