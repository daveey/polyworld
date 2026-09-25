## Gods of the Arena native training environment (native_env.h, ABI v1).
##
## Build (shared library, training counters on, handles usable from any
## thread):
##   nim c --app:lib -d:release -d:headless -d:gotaTrainingStats \
##     --mm:atomicArc --threads:on -d:useMalloc -u:nimTypeNames \
##     -o:libgota_env.so examples/gods_of_the_arena/native_env.nim
## (--mm:orc instead of atomicArc is ~10% faster single-threaded but then
## every handle of the process must stay on one thread.)
## One handle = one ten-seat match. See native_env.h and neural_basic.md.

import std/[json, locks, os], jsony, scores, polyworld/visions
include bots

const
  GotaEnvVersion = 1
  StatCount = 24
  OrderSize = 16
  DataRoot = currentSourcePath().parentDir

type
  SeatSource = enum SourceDefault, SourceScript, SourcePackage
  SeatStatus = object
    code: int ## 0 learner, 1 running, 2 compile failed, 3 runtime disabled
    message: string
  Env = ref object
    config: GotaConfig
    maxTicks, period: int32
    learners: uint32
    record, capture: bool
    standing: int32
    defaultScript, policyScript: string
    sources: array[10, SeatSource]
    scripts: array[10, string]
    packages: array[10, string]
    overrides: array[10, bool]
    shadows: array[10, string]
    goals: array[10, array[GoalSize, float32]]
    status: array[10, SeatStatus]
    game: Game
    seeds: int64
    paused, over, started: bool
    prevScore: array[10, int64]
    pushDepth: array[10, int64]
    scratch: seq[float32]

var
  presetKey: string
  lastError {.threadvar.}: string
  processLock: Lock
    ## Serializes create/reset: the shared map, navigation graph and lane
    ## globals are built once under it; stepping never writes them.
  mapTemplate: MapData
  mapReady: bool
initLock(processLock)

proc copyText(text: string, buffer: ptr char, capacity: int32) =
  if buffer == nil or capacity <= 0:
    return
  let n = min(text.len, int(capacity) - 1)
  let dest = cast[ptr UncheckedArray[char]](buffer)
  for i in 0 ..< n:
    dest[i] = text[i]
  dest[n] = '\0'

proc seatScore(game: Game, index: int): int64 =
  int64(score(game.world.heroes[index].totalXp,
    int(max(0'i32, game.world.battleTick()))))

proc compileSeat(env: Env, game: Game, index: int, source: string,
    neural: bool): bool =
  ## Compiles one seat's program; a failure leaves the seat idle.
  let heroId = game.world.heroes[index].id
  let limits = if neural: neuralVmLimits() else: heroVmLimits()
  var schema = initHeroHost(0)
  var host = initHeroHost(heroId)
  if neural:
    schema.addNeuralSeatFunctions(0)
    host.addNeuralSeatFunctions(heroId)
  try:
    let program = compile(source, schema, limits)
    bindHeroData(program)
    game.heroVms[index] = HeroVm(runtime: initRuntime(program, host, limits),
      limits: limits, ready: true)
    result = true
  except BasicError as error:
    env.status[index] = SeatStatus(code: 2, message: error.msg)
    game.heroVms[index] = nil

proc updatePush(env: Env) =
  ## Deepest advance past the centre line along own god -> enemy god.
  let world = env.game.world
  for i, hero in world.heroes:
    if hero.hp <= 0 or hero.state == Dying:
      continue
    let
      own = world.forts[hero.team.ord].center
      enemy = world.forts[1 - hero.team.ord].center
      ax = float64(enemy.x - own.x)
      az = float64(enemy.z - own.z)
      length = sqrt(ax*ax + az*az)
      mx = float64(own.x + enemy.x) / 2
      mz = float64(own.z + enemy.z) / 2
    if length <= 0:
      continue
    let depth = ((float64(hero.position.x) - mx) * ax +
      (float64(hero.position.z) - mz) * az) / length
    let milli = int64(depth * 1000 / float64(WorldScale))
    env.pushDepth[i] = max(env.pushDepth[i], milli)

proc tickDone(env: Env) =
  ## Per-tick replay telemetry, exactly as the headless runner samples it.
  if env.record:
    let game = env.game
    game.sampleMetrics(game.finished())
    game.metrics.finishTick(game.world.tick)

proc pauseOrFinish(env: Env) =
  ## Runs ticks until the next decision tick's heroes' turn (paused, with the
  ## observation frame frozen) or the end of the match.
  let game = env.game
  activeGame = game
  env.paused = false
  while true:
    if game.finished():
      env.over = true
      return
    let stage = game.tickWorldBegin(proc() = runBotDecisions(game))
    case stage
    of TickSkipped:
      env.over = true
      return
    of TickDone:
      env.tickDone()
    of TickNoTurn:
      game.tickWorldFinish()
      env.tickDone()
    of TickHeroTurn:
      if game.world.isDecisionTick(env.period):
        game.neuralPrelude()
        env.paused = true
        env.updatePush()
        return
      runBotDecisions(game)
      game.tickWorldFinish()
      env.tickDone()

proc resetEnv(env: Env, seed: int64): int =
  activeGame = nil
  neuralTelemetryEnabled = false
  var gameMap: MapData
  var game: Game
  withLock processLock:
    if not mapReady:
      mapTemplate = generateMap(int32(seed), env.config.mapPreset)
      warmEdgeLinks()
      initVisionKernel()
      mapReady = true
    gameMap = mapTemplate
    gameMap.seed = int32(seed)
    game = newGame(gameMap, env.config.spawnIntervalTicks, 10, false,
      ReplayData(), true)
  game.replayData = initReplayData(currentSetup(game, uint32(env.maxTicks)),
    gameMap.preset)
  if env.record:
    game.recorder = initReplayRecorder(currentSetup(game, uint32(env.maxTicks)),
      gameMap.preset)
    game.recorder.data.config = game.replayData.config
  activeGame = game
  env.game = game
  game.heroVms.setLen(game.world.heroes.len)
  game.inboxes.setLen(game.world.heroes.len)
  for inbox in game.inboxes.mitems:
    inbox = newMailbox()
  result = 0
  for i in 0 ..< 10:
    env.status[i] = SeatStatus(code: 1)
    env.prevScore[i] = 0
    env.pushDepth[i] = 0
    let learner = (env.learners and (1'u32 shl i)) != 0
    if env.sources[i] == SourcePackage:
      try:
        game.installPackageSeat(i, env.packages[i])
        let seat = game.neuralSeat(i)
        seat.telemetry = false
        seat.goal = env.goals[i]
      except BasicError as error:
        env.status[i] = SeatStatus(code: 2, message: error.msg)
        game.heroVms[i] = nil
        result = -2
      continue
    if learner:
      env.status[i] = SeatStatus(code: 0)
      if env.compileSeat(game, i, env.policyScript, true):
        let seat = newNeuralSeat(NeuralLearner, env.period, env.maxTicks)
        seat.goal = env.goals[i]
        seat.standingMode = env.standing
        seat.resetEpisode(int32(seed), i)
        game.heroVms[i].neural = seat
        if env.shadows[i].len > 0:
          let heroId = game.world.heroes[i].id
          try:
            let program = compile(env.shadows[i], initHeroHost(0), heroVmLimits())
            seat.shadow = HeroVm(runtime: initRuntime(program,
              initHeroHost(heroId), heroVmLimits()), limits: heroVmLimits(),
              ready: true)
          except BasicError as error:
            env.status[i] = SeatStatus(code: 2, message: "shadow: " & error.msg)
            result = -2
      else:
        result = -2
      continue
    let source =
      if env.sources[i] == SourceScript: env.scripts[i] else: env.defaultScript
    if env.compileSeat(game, i, source, false):
      if env.overrides[i] or env.capture:
        let seat = newNeuralSeat(
          if env.overrides[i]: NeuralOverride else: NeuralCapture,
          env.period, env.maxTicks)
        seat.goal = env.goals[i]
        seat.standingMode = env.standing
        seat.resetEpisode(int32(seed), i)
        game.heroVms[i].neural = seat
    else:
      result = -2
  env.over = false
  env.started = true
  # Draft (BASIC picks), then the first battle decision.
  while game.world.phase == Drafting and not game.finished():
    tickWorld(game, proc() = runBotDecisions(game))
    env.tickDone()
  env.pauseOrFinish()

proc toEnv(handle: pointer): Env =
  if handle == nil:
    return nil
  result = cast[Env](handle)
  if result.game != nil:
    activeGame = result.game

# ---------------------------------------------------------------------------
# C ABI

proc gota_env_version(): cint {.exportc, dynlib, cdecl.} = GotaEnvVersion
proc gota_observation_size(): cint {.exportc, dynlib, cdecl.} = ObservationSize
proc gota_goal_size(): cint {.exportc, dynlib, cdecl.} = GoalSize
proc gota_stat_count(): cint {.exportc, dynlib, cdecl.} = StatCount

proc gota_action_heads(sizes: ptr UncheckedArray[int32]): cint {.exportc, dynlib, cdecl.} =
  if sizes != nil:
    for i, size in HeadSizes:
      sizes[i] = int32(size)
  ActionHeads

proc gota_observation_contract_hash(output: ptr char, capacity: int32): cint {.exportc, dynlib, cdecl.} =
  if output == nil or capacity < 65: return -1
  copyText(ObservationContractHash, output, capacity)

proc gota_action_contract_hash(output: ptr char, capacity: int32): cint {.exportc, dynlib, cdecl.} =
  if output == nil or capacity < 65: return -1
  copyText(ActionContractHash, output, capacity)

proc resolve(root, path: string): string =
  if path.isAbsolute: path else: root / path

proc gota_create(configJson: cstring, error: ptr char, capacity: int32): pointer {.exportc, dynlib, cdecl.} =
  try:
    let node = if configJson == nil or configJson[0] == '\0': newJObject()
      else: parseJson($configJson)
    for key in node.keys:
      if key notin ["config_path", "seed", "max_ticks", "decision_period",
          "learner_seats", "script_path", "policy_path", "data_root",
          "record", "capture", "standing_labels"]:
        raise newException(ValueError, "unknown config key " & key)
    let root = if node.hasKey("data_root"): node["data_root"].getStr else: DataRoot
    let env = Env(period: DefaultDecisionPeriod, capture: true)
    env.config =
      if node.hasKey("config_path"): loadConfig(resolve(root, node["config_path"].getStr))
      else: parseConfig("{}")
    env.maxTicks = int32(if node.hasKey("max_ticks"): node["max_ticks"].getInt
      else: 28_800)
    if env.maxTicks notin 1'i32 .. 28_800'i32:
      raise newException(ValueError, "max_ticks must be 1..28800")
    if node.hasKey("decision_period"):
      env.period = int32(node["decision_period"].getInt)
    if env.period notin 1'i32 .. 24'i32:
      raise newException(ValueError, "decision_period must be 1..24")
    env.learners = 1
    if node.hasKey("learner_seats"):
      env.learners = 0
      for seat in node["learner_seats"]:
        let s = seat.getInt
        if s notin 0..9:
          raise newException(ValueError, "learner seat out of range")
        env.learners = env.learners or (1'u32 shl s)
    env.record = node.hasKey("record") and node["record"].getBool
    if node.hasKey("capture"):
      env.capture = node["capture"].getBool
    if node.hasKey("standing_labels"):
      env.standing = int32(node["standing_labels"].getInt)
      if env.standing notin 0'i32 .. 2'i32:
        raise newException(ValueError, "standing_labels must be 0..2")
    env.defaultScript = readFile(resolve(root,
      if node.hasKey("script_path"): node["script_path"].getStr else: "players/base.bas"))
    env.policyScript = readFile(resolve(root,
      if node.hasKey("policy_path"): node["policy_path"].getStr else: "neural/policy.bas"))
    env.seeds = if node.hasKey("seed"): node["seed"].getInt else: 0
    for i in 0 ..< 10:
      env.goals[i] = defaultGoal()
    let key = env.config.mapPreset.toJson()
    if presetKey.len > 0 and presetKey != key:
      raise newException(ValueError, "every handle in a process must use the same map preset")
    presetKey = key
    GC_ref(env)
    result = cast[pointer](env)
  except CatchableError as e:
    copyText(e.msg, error, capacity)
    result = nil

proc gota_destroy(handle: pointer) {.exportc, dynlib, cdecl.} =
  if handle == nil: return
  let env = cast[Env](handle)
  if activeGame == env.game:
    activeGame = nil
  env.game = nil
  GC_unref(env)

proc gota_reset(handle: pointer, seed: int64): cint {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil: return -1
  try:
    env.seeds = seed
    cint(env.resetEnv(seed))
  except CatchableError as e:
    lastError = e.msg
    -3

proc gota_set_learner_seats(handle: pointer, mask: uint32): cint {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil or mask >= 1024: return -1
  env.learners = mask
  for i in 0 ..< 10:
    if (mask and (1'u32 shl i)) != 0 and env.sources[i] != SourceDefault:
      env.sources[i] = SourceDefault
  0

proc gota_learner_seats(handle: pointer): uint32 {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil: 0'u32 else: env.learners

proc gota_seat_team(handle: pointer, seat: cint): cint {.exportc, dynlib, cdecl.} =
  if seat notin 0..9: return -1
  if seat < 5: 0 else: 1

proc gota_seat_class(handle: pointer, seat: cint): cint {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil or env.game == nil or seat notin 0..9: return -1
  env.game.world.draftedClass(env.game.world.heroes[seat].id)

proc gota_decision_period(handle: pointer): cint {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil: -1 else: env.period

proc gota_battle_tick(handle: pointer): int32 {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil or env.game == nil: -1 else: env.game.world.battleTick()

proc gota_observe_seats(handle: pointer, seats: uint32,
    obs, resets, acting: ptr UncheckedArray[float32]): cint {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil or env.game == nil or obs == nil: return -1
  let game = env.game
  for i in 0 ..< 10:
    if (seats and (1'u32 shl i)) == 0:
      continue
    let row = cast[ptr UncheckedArray[float32]](addr obs[i * ObservationSize])
    let seat = game.neuralSeat(i)
    if seat != nil and env.paused and seat.frameTick == game.world.tick:
      for k in 0 ..< ObservationSize:
        row[k] = seat.obs[k]
      if resets != nil: resets[i] = float32(seat.resetState and seat.acting)
      if acting != nil:
        acting[i] = float32(seat.acting and not env.over)
    else:
      if env.scratch.len != ObservationSize:
        env.scratch = newSeq[float32](ObservationSize)
      var frame: DecisionFrame
      buildObservation(game.world, i, env.goals[i], env.maxTicks,
        game.world.stats, env.scratch, frame)
      for k in 0 ..< ObservationSize:
        row[k] = env.scratch[k]
      if resets != nil: resets[i] = 0
      if acting != nil: acting[i] = 0
  0

proc gota_step(handle: pointer, actions: ptr UncheckedArray[int32],
    rewards, terminals: ptr UncheckedArray[float32]): cint {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil or env.game == nil: return -1
  if env.over: return -2
  if not env.paused: return -1
  let game = env.game
  try:
    for i in 0 ..< 10:
      env.prevScore[i] = game.seatScore(i)
      let seat = game.neuralSeat(i)
      if seat != nil and seat.mode == NeuralLearner:
        var heads: Heads
        if actions != nil:
          for h in 0 ..< ActionHeads:
            heads[h] = actions[i * ActionHeads + h]
        seat.setLearnerHeads(heads)
    runBotDecisions(game)
    game.tickWorldFinish()
    env.tickDone()
    env.pauseOrFinish()
  except CatchableError as e:
    lastError = e.msg
    return -3
  for i in 0 ..< 10:
    let now = game.seatScore(i)
    if rewards != nil:
      rewards[i] = float32(now - env.prevScore[i]) / 1000
    if terminals != nil:
      terminals[i] = float32(env.over)
  if env.over: 1 else: 0

proc gota_results(handle: pointer, eight: ptr UncheckedArray[float32]): cint {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil or env.game == nil or eight == nil: return -1
  let world = env.game.world
  eight[0] = float32(env.over)
  eight[1] = if world.gameOver and not world.draw: float32(world.winner.ord) else: -1
  eight[2] = float32(world.draw)
  eight[3] = float32(env.over and not world.gameOver)
  eight[4] = float32(world.battleTick())
  eight[5] = float32(max(world.forts[0].hp, 0))
  eight[6] = float32(max(world.forts[1].hp, 0))
  eight[7] = float32(world.tick)
  0

proc gota_state_hash(handle: pointer): uint64 {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil or env.game == nil: 0'u64 else: env.game.stateHash()

proc gota_seat_stats(handle: pointer, seat: cint, output: ptr UncheckedArray[int64]): cint {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil or env.game == nil or seat notin 0..9 or output == nil: return -1
  let
    game = env.game
    world = game.world
    hero = world.heroes[seat]
    values = world.stats.values[seat]
  for i in 0 ..< StatCount:
    output[i] = 0
  output[0] = game.seatScore(seat)
  if world.gameOver and not world.draw:
    output[1] = if world.winner == hero.team: 1 else: -1
  output[2] = int64(hero.totalXp)
  output[4] = values[KillsMetric]
  output[5] = values[AssistsMetric]
  output[6] = int64(hero.deaths)
  when defined(gotaTrainingStats):
    if world.training.len > seat:
      let t = world.training[seat]
      output[3] = t[TrainGold]
      output[7] = t[TrainLastHits]
      output[8] = t[TrainNeutralKills]
      output[9] = t[TrainTowerDamage]
      output[10] = t[TrainStructureKills]
      output[11] = t[TrainHeroDamage]
      output[12] = t[TrainDamageTaken]
      output[14] = t[TrainGodDamage]
  else:
    output[3] = values[GoldMetric]
  output[13] = env.pushDepth[seat]
  output[15] = int64(hero.level)
  output[16] = int64(hero.gold)
  output[17] = int64(hero.team.ord)
  output[18] = int64(world.draftedClass(hero.id))
  output[19] = int64(hero.hp > 0 and hero.state != Dying)
  let s = game.neuralSeat(seat)
  if s != nil:
    output[20] = int64(s.decisions)
    output[21] = int64(s.invalid)
  let vm = game.heroVms[seat]
  if vm != nil:
    output[22] = vm.lastInstructions
  0

proc gota_set_seat_goal(handle: pointer, seat: cint, w: ptr UncheckedArray[float32]): cint {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil or seat notin 0..9 or w == nil: return -1
  for i in 0 ..< GoalSize:
    if not (w[i] >= -1 and w[i] <= 1): return -3
  if w[GoalSize - 1] != 0: return -3
  for i in 0 ..< GoalSize:
    env.goals[seat][i] = w[i]
  if env.game != nil:
    let s = env.game.neuralSeat(seat)
    if s != nil:
      s.goal = env.goals[seat]
      for i in 0 ..< GoalSize:
        s.obs[ObsGoalOffset + i] = w[i]
  0

proc checkCompile(source: string, neural: bool): (bool, string) =
  var schema = initHeroHost(0)
  if neural:
    schema.addNeuralSeatFunctions(0)
  try:
    discard compile(source, schema, if neural: neuralVmLimits() else: heroVmLimits())
    (true, "")
  except BasicError as error:
    (false, error.msg)

proc gota_set_seat_script(handle: pointer, seat: cint, source: cstring, length: int32): cint {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil or seat notin 0..9 or length < 0 or (length > 0 and source == nil): return -1
  env.learners = env.learners and not (1'u32 shl seat)
  if length == 0:
    env.sources[seat] = SourceDefault
    return 0
  var text = newString(length)
  copyMem(addr text[0], source, length)
  env.scripts[seat] = text
  env.sources[seat] = SourceScript
  let (ok, message) = checkCompile(text, false)
  env.status[seat] = SeatStatus(code: (if ok: 1 else: 2), message: message)
  if ok: 0 else: 1

proc gota_set_policy_script(handle: pointer, source: cstring, length: int32): cint {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil or length < 0 or (length > 0 and source == nil): return -1
  if length == 0:
    env.policyScript = readFile(DataRoot / "neural/policy.bas")
    return 0
  var text = newString(length)
  copyMem(addr text[0], source, length)
  let (ok, _) = checkCompile(text, true)
  if not ok: return 1
  env.policyScript = text
  0

proc gota_seat_script_status(handle: pointer, seat: cint, message: ptr char, capacity: int32): cint {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil or seat notin 0..9: return -1
  var status = env.status[seat]
  if env.game != nil:
    let vm = env.game.heroVms[seat]
    if vm != nil and vm.failed:
      status = SeatStatus(code: 3, message: vm.lastError)
    elif (env.learners and (1'u32 shl seat)) != 0 and status.code != 2:
      status.code = 0
  copyText(status.message, message, capacity)
  cint(status.code)

proc gota_seat_orders(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil or env.game == nil or seat notin 0..9 or output == nil: return -1
  for i in 0 ..< OrderSize:
    output[i] = 0
  let s = env.game.neuralSeat(seat)
  if s == nil:
    return 0
  case s.mode
  of NeuralCapture, NeuralOverride:
    for i in 0 ..< OrderSize:
      output[i] = s.lastLabel[i]
  of NeuralLearner, NeuralPackage:
    if s.shadow != nil:
      for i in 0 ..< OrderSize:
        output[i] = s.lastLabel[i]
      return 0
    output[0] = int32(s.headsReady and s.acting and s.heads[0] != 0)
    for h in 0 ..< ActionHeads:
      output[1 + h] = s.heads[h]
    output[6] = 1
    output[7] = int32(s.command.kind.ord)
    output[8] = s.command.objectId
    output[9] = s.command.ability
    output[10] = s.command.item
    output[15] = s.frameTick
  0

proc gota_set_seat_shadow(handle: pointer, seat: cint, source: cstring, length: int32): cint {.exportc, dynlib, cdecl.} =
  ## DAgger: on a learner seat, runs `source` on the same frames without
  ## executing anything; gota_seat_orders then reports its labels.
  let env = toEnv(handle)
  if env == nil or seat notin 0..9 or length < 0 or (length > 0 and source == nil): return -1
  if length == 0:
    env.shadows[seat] = ""
    return 0
  var text = newString(length)
  copyMem(addr text[0], source, length)
  let (ok, _) = checkCompile(text, false)
  if not ok: return 1
  env.shadows[seat] = text
  0

proc gota_set_seat_override(handle: pointer, seat: cint, enabled: int32): cint {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil or seat notin 0..9 or enabled notin 0'i32..1'i32: return -1
  env.overrides[seat] = enabled == 1
  0

proc gota_set_seat_package(handle: pointer, seat: cint, zip: pointer, length: int64): cint {.exportc, dynlib, cdecl.} =
  let env = toEnv(handle)
  if env == nil or seat notin 0..9 or zip == nil or length <= 0 or
      length > MaxPackageBytes: return -1
  var bytes = newString(length)
  copyMem(addr bytes[0], zip, length)
  try:
    let package = parsePackage(bytes)
    let (ok, message) = checkCompile(package.policy, true)
    if not ok:
      env.status[seat] = SeatStatus(code: 2, message: message)
      return 1
  except CatchableError as e:
    env.status[seat] = SeatStatus(code: 2, message: "neural package rejected: " & e.msg)
    return 2
  env.packages[seat] = bytes
  env.sources[seat] = SourcePackage
  env.learners = env.learners and not (1'u32 shl seat)
  0

proc gota_last_error(output: ptr char, capacity: int32): cint {.exportc, dynlib, cdecl.} =
  copyText(lastError, output, capacity)
  0

proc gota_save_replay(handle: pointer, path: cstring): cint {.exportc, dynlib, cdecl.} =
  ## Writes the recorded replay (config "record": true). 0 ok, -1 not recording.
  let env = toEnv(handle)
  if env == nil or env.game == nil or env.game.recorder == nil or path == nil: return -1
  try:
    if env.game.world.tick == env.game.recorder.data.hashes.len:
      env.game.sampleMetrics(true)
    env.game.recorder.data.metrics = env.game.history.replayMetrics()
    saveReplay($path, env.game.recorder.data)
    0
  except CatchableError as e:
    lastError = e.msg
    -3

# Neural actor.

proc gota_net_load(data: pointer, length: int64, error: ptr char, capacity: int32): pointer {.exportc, dynlib, cdecl.} =
  if data == nil or length <= 0:
    copyText("empty model", error, capacity)
    return nil
  var bytes = newString(length)
  copyMem(addr bytes[0], data, length)
  try:
    let actor = loadActor(bytes)
    GC_ref(actor)
    cast[pointer](actor)
  except CatchableError as e:
    copyText(e.msg, error, capacity)
    nil

proc gota_net_destroy(net: pointer) {.exportc, dynlib, cdecl.} =
  if net != nil:
    GC_unref(cast[Actor](net))

proc gota_net_info(net: pointer, eight: ptr UncheckedArray[int64]): cint {.exportc, dynlib, cdecl.} =
  if net == nil or eight == nil: return -1
  let actor = cast[Actor](net)
  eight[0] = 1
  eight[1] = actor.inputSize
  eight[2] = actor.hiddenSize
  eight[3] = actor.outputSize
  eight[4] = actor.headSizes.len
  eight[5] = actor.hiddenSize
  eight[6] = actor.parameterCount
  eight[7] = actor.operationCount
  0

proc gota_net_infer(net: pointer, observation, state, logits: ptr UncheckedArray[float32]): cint {.exportc, dynlib, cdecl.} =
  if net == nil or observation == nil or state == nil or logits == nil: return -1
  let actor = cast[Actor](net)
  try:
    var nextState = newSeq[float32](actor.hiddenSize)
    var output = newSeq[float32](actor.outputSize)
    for i in 0 ..< actor.hiddenSize: nextState[i] = state[i]
    actor.infer(observation.toOpenArray(0, actor.inputSize - 1), nextState, output)
    for i in 0 ..< actor.hiddenSize: state[i] = nextState[i]
    for i in 0 ..< actor.outputSize: logits[i] = output[i]
    0
  except CatchableError:
    -2
