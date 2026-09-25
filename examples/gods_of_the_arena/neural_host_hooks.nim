## Neural seats: the hosted package seat, the native trainer's learner seat,
## and the scripted seats whose commands are captured (BC labels) or routed
## through the contract (mapping ceiling). Included by bots.nim.
##
## A seat without a NeuralSeat is untouched by everything here, so plain
## BASIC matches stay byte-identical.

type
  NeuralMode* = enum
    NeuralLearner ## native trainer supplies the heads
    NeuralPackage ## hosted neural package, network inside
    NeuralOverride ## scripted seat, contract commands re-routed (ceiling)
    NeuralCapture ## scripted seat, contract commands captured as labels
  NeuralSeat* = ref object of RootObj
    mode*: NeuralMode
    period*: int32
    goal*: array[GoalSize, float32]
    maxTicks*: int32
    obs*: seq[float32]
    frame*: DecisionFrame
    frameTick*: int32
    acting*, resetState*: bool
    started, sawDeath: bool
    heads*: Heads
    headsReady*: bool
    command*: NeuralCommand
    issuedTick*: int32
    captured*: seq[NeuralCommand]
    label*: array[16, int32]
    lastLabel*: array[16, int32]
      ## The label of the previous decision window (what gota_seat_orders reports).
    labelInstant: bool
    actor*: Actor
    state*, logits*: seq[float32]
    sampling*: bool
    temperature*: float32
    rng*: uint64
    inferences*, peakOps*: int
    decisions*, invalid*: int
    telemetry*: bool
    lastTelemetry: int
    shadow*: HeroVm
      ## Learner seats only: an expert script run on the same frame whose
      ## commands become labels and are never executed (DAgger).

var shadowRunning {.threadvar.}: bool
  ## True while a shadow expert script runs: its host calls change nothing.

var neuralTelemetryEnabled* = true

proc neuralSeat*(game: Game, index: int): NeuralSeat =
  if index >= 0 and index < game.heroVms.len and game.heroVms[index] != nil and
      game.heroVms[index].neural != nil:
    result = NeuralSeat(game.heroVms[index].neural)

proc newNeuralSeat*(mode: NeuralMode, period: int32, maxTicks: int32): NeuralSeat =
  result = NeuralSeat(mode: mode, period: period, maxTicks: maxTicks,
    frameTick: -1, issuedTick: -1, temperature: 1)
  result.goal[0] = 1
  result.obs = newSeq[float32](ObservationSize)

proc isDecisionTick*(world: World, period: int32): bool =
  ## Battle ticks 1, 1 + period, ... (the heroes' turn of that tick).
  world.phase == Playing and period > 0 and
    (world.battleTick() - 1) mod period == 0

proc seatLog(game: Game, index: int, text: string) =
  when defined(coworld):
    playerLog(index, text & "\n")
  else:
    if neuralTelemetryEnabled:
      echo "seat ", index, " ", text

proc splitmix(state: var uint64): uint64 =
  state += 0x9E3779B97F4A7C15'u64
  var z = state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc sampleHeads*(logits: openArray[float32], temperature: float32,
    state: var uint64): Heads =
  ## One categorical draw per head, in head order, from softmax(logits / T),
  ## using 53 random bits per draw (neural_basic.md, "Sampling").
  var offset = 0
  for h in 0 ..< ActionHeads:
    let n = HeadSizes[h]
    var top = logits[offset]
    for i in 1 ..< n:
      top = max(top, logits[offset + i])
    var weights: array[64, float64]
    var total = 0.0
    for i in 0 ..< n:
      weights[i] = exp(float64(logits[offset + i] - top) / float64(temperature))
      total += weights[i]
    let u = float64(splitmix(state) shr 11) / 9007199254740992.0 * total
    var acc = 0.0
    var choice = n - 1
    for i in 0 ..< n:
      acc += weights[i]
      if u < acc:
        choice = i
        break
    result[h] = int32(choice)
    offset += n

proc resetEpisode*(seat: NeuralSeat, matchSeed: int32, index: int) =
  ## Clears per-match state (a new match or a native reset).
  seat.frameTick = -1
  seat.issuedTick = -1
  seat.started = false
  seat.sawDeath = false
  seat.headsReady = false
  seat.captured.setLen(0)
  seat.label = default(typeof(seat.label))
  seat.lastLabel = default(typeof(seat.lastLabel))
  seat.command = NeuralCommand()
  seat.decisions = 0
  seat.invalid = 0
  seat.inferences = 0
  seat.lastTelemetry = 0
  seat.rng = uint64(uint32(matchSeed)) * 1_000_003'u64 + uint64(index) + 1
  if seat.actor != nil:
    seat.state = newSeq[float32](seat.actor.hiddenSize)
    seat.logits = newSeq[float32](seat.actor.outputSize)

proc beginDecision*(game: Game, index: int, seat: NeuralSeat) =
  ## Captures the decision frame (observation, slots, resets) once per tick.
  let world = game.world
  if seat.frameTick == world.tick:
    return
  seat.frameTick = world.tick
  buildObservation(world, index, seat.goal, seat.maxTicks, world.stats,
    seat.obs, seat.frame)
  seat.acting = seat.frame.alive and not world.gameOver
  if not seat.started:
    seat.started = true
    seat.resetState = true
    if not seat.acting:
      seat.sawDeath = true
  elif not seat.acting:
    seat.sawDeath = true
    seat.resetState = false
  elif seat.sawDeath:
    seat.resetState = true
  else:
    seat.resetState = false
  if seat.acting and seat.resetState:
    seat.sawDeath = false
  seat.headsReady = false
  seat.command = NeuralCommand(tick: world.tick)
  case seat.mode
  of NeuralPackage:
    if seat.acting:
      if seat.resetState:
        for x in seat.state.mitems: x = 0
      try:
        seat.actor.infer(seat.obs, seat.state, seat.logits)
      except ValueError as error:
        raise newException(BasicError, "neural inference failed: " & error.msg)
      inc seat.inferences
      seat.peakOps = max(seat.peakOps, seat.actor.operationCount)
      seat.heads =
        if seat.sampling: sampleHeads(seat.logits, seat.temperature, seat.rng)
        else: argmaxHeads(seat.logits)
      seat.headsReady = true
      seat.command = decodeAction(seat.frame, seat.heads)
      if seat.telemetry and (seat.inferences == 1 or
          seat.inferences - seat.lastTelemetry >= 1800 or
          world.battleTick() + seat.period > seat.maxTicks):
        seat.lastTelemetry = seat.inferences
        game.seatLog(index, "neural: peak_ops=" & $seat.peakOps & " budget=" &
          $NeuralOpBudget & " model=w" & $seat.actor.hiddenSize & " ticks=" &
          $world.battleTick() & " inferences=" & $seat.inferences)
  of NeuralCapture, NeuralOverride:
    seat.lastLabel = seat.label
    seat.label = default(typeof(seat.label))
    seat.labelInstant = false
    if seat.mode == NeuralCapture:
      seat.captured.setLen(0)
  of NeuralLearner:
    if seat.shadow != nil:
      seat.lastLabel = seat.label
      seat.label = default(typeof(seat.label))
      seat.labelInstant = false

proc setLearnerHeads*(seat: NeuralSeat, heads: Heads) =
  ## The native trainer's action for the paused decision.
  seat.heads = heads
  seat.headsReady = true
  seat.command = if seat.acting: decodeAction(seat.frame, heads)
    else: NeuralCommand(tick: seat.frameTick)

proc writeLabel(seat: NeuralSeat, world: World, command: NeuralCommand) =
  ## Folds one script command into the window's label (first instant wins,
  ## otherwise the last movement/attack order).
  let instant = command.kind in {CastTargetCommand, CastPointCommand,
    UseItemCommand, UseItemAtCommand}
  if seat.labelInstant:
    inc seat.label[13]
    return
  let encoded = encodeCommand(seat.frame, world, command)
  let count = seat.label[13] + 1
  seat.label = default(typeof(seat.label))
  seat.label[13] = count
  seat.labelInstant = instant
  seat.label[0] = int32(encoded.represented and encoded.heads[0] != 0)
  if encoded.represented:
    for h in 0 ..< ActionHeads:
      seat.label[1 + h] = encoded.heads[h]
  seat.label[6] = int32(encoded.exact)
  seat.label[7] = int32(command.kind.ord)
  seat.label[8] = command.objectId
  seat.label[9] = command.ability
  seat.label[10] = command.item
  let
    wp = worldPointOf(command.point)
    s = (if seat.frame.team == RedTeam: 1'i64 else: -1'i64)
  if command.kind in {WalkCommand, AttackMoveCommand, CastPointCommand, UseItemAtCommand}:
    seat.label[11] = int32(s * int64(wp.x) * 1000 div WorldScale)
    seat.label[12] = int32(s * int64(wp.z) * 1000 div WorldScale)
  seat.label[14] = encoded.errorMilli
  seat.label[15] = command.tick

proc interceptCommand*(game: Game, heroId: int32, command: NeuralCommand): bool =
  ## Called by every contract host function before it applies an order.
  ## True = the order was absorbed (override mode) and must not run.
  if game.heroVms.len == 0:
    return false
  let index = game.world.heroIndex(heroId)
  let seat = game.neuralSeat(index)
  if seat == nil:
    return false
  var tagged = command
  tagged.tick = game.world.tick
  if shadowRunning:
    if seat.frameTick >= 0:
      seat.writeLabel(game.world, tagged)
    return true
  case seat.mode
  of NeuralOverride:
    seat.captured.add tagged
    true
  of NeuralCapture:
    if seat.frameTick >= 0:
      seat.writeLabel(game.world, tagged)
    false
  else:
    false

proc issueDecoded*(game: Game, heroId: int32, command: NeuralCommand): bool =
  ## Executes a decoded contract command through the recorded host path.
  let (x, y, offset) = splitTilePoint(command.point)
  case command.kind
  of NoCommand: false
  of WalkCommand: game.issueWalkTo(heroId, x, y, offset)
  of AttackMoveCommand: game.issueAttackMove(heroId, x, y, offset)
  of AttackTargetCommand: game.issueAttackTarget(heroId, command.objectId)
  of CastTargetCommand: game.issueCastTarget(heroId, command.ability, command.objectId)
  of CastPointCommand: game.issueCastPoint(heroId, command.ability, x, y, offset)
  of UseItemCommand: game.issueUseItem(heroId, command.item)
  of UseItemAtCommand: game.issueUseItemAt(heroId, command.item, x, y, offset)

proc actNow*(game: Game, index: int): int32 =
  ## gota_act: issues the seat's decoded command once, on its decision tick.
  let seat = game.neuralSeat(index)
  if seat == nil or seat.mode notin {NeuralLearner, NeuralPackage}:
    return 0
  let world = game.world
  if seat.frameTick != world.tick or seat.issuedTick == world.tick or
      not seat.acting or not seat.headsReady:
    return 0
  seat.issuedTick = world.tick
  inc seat.decisions
  if isInvalid(seat.frame, seat.heads):
    inc seat.invalid
  int32(game.issueDecoded(world.heroes[index].id, seat.command))

proc runOverride*(game: Game, index: int, seat: NeuralSeat) =
  ## Mapping ceiling: route the script's queued orders through the contract.
  let world = game.world
  if seat.frameTick != world.tick:
    return
  if seat.captured.len == 0 or not seat.acting:
    seat.captured.setLen(0)
    return
  for command in seat.captured:
    seat.writeLabel(world, command)
  seat.captured.setLen(0)
  if seat.label[0] == 0:
    return
  var heads: Heads
  for h in 0 ..< ActionHeads:
    heads[h] = seat.label[1 + h]
  seat.heads = heads
  let decoded = decodeAction(seat.frame, heads)
  inc seat.decisions
  discard game.issueDecoded(world.heroes[index].id, decoded)

proc neuralPrelude*(game: Game) =
  ## Start of the heroes' turn: every neural seat observes the same frame.
  let world = game.world
  for index in 0 ..< game.heroVms.len:
    let seat = game.neuralSeat(index)
    if seat != nil and world.isDecisionTick(seat.period):
      let vm = game.heroVms[index]
      if vm.failed:
        continue
      try:
        game.beginDecision(index, seat)
      except BasicError as error:
        vm.failed = true
        vm.lastError = error.msg
        when defined(coworld):
          playerError(index, error.msg)
        else:
          echo "hero ", world.heroes[index].id, " neural error: ", error.msg

proc addNeuralSeatFunctions*(host: var Host, heroId: int32) =
  ## The policy.bas surface of a neural seat (package or learner).
  proc seatOf(): NeuralSeat =
    activeGame.neuralSeat(activeGame.world.heroIndex(heroId))
  let actProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Issues the network's decoded command on a decision tick.
    activeGame.actNow(activeGame.world.heroIndex(heroId))
  let runProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## 1 when this tick has a fresh decision (inference or trainer action).
    let seat = seatOf()
    int32(seat != nil and seat.frameTick == activeGame.world.tick and
      seat.headsReady)
  let observationProc: NumericHostProc = proc(arguments: openArray[Value]): Value =
    ## Reads observation float i of the current decision (Q16.16).
    let seat = seatOf()
    let i = int(arguments[0].asInt)
    if seat == nil or i < 0 or i >= ObservationSize:
      return toValue(0'i32)
    toValue(toFixed(clamp(seat.obs[i], -30000'f32, 30000'f32)))
  let logitsProc: NumericHostProc = proc(arguments: openArray[Value]): Value =
    ## Reads logit i of the last inference (Q16.16); 0 for learner seats.
    let seat = seatOf()
    let i = int(arguments[0].asInt)
    if seat == nil or seat.logits.len == 0 or i < 0 or i >= seat.logits.len:
      return toValue(0'i32)
    toValue(toFixed(clamp(seat.logits[i], -30000'f32, 30000'f32)))
  let stateProc: NumericHostProc = proc(arguments: openArray[Value]): Value =
    ## Reads recurrent state float i (Q16.16).
    let seat = seatOf()
    let i = int(arguments[0].asInt)
    if seat == nil or seat.state.len == 0 or i < 0 or i >= seat.state.len:
      return toValue(0'i32)
    toValue(toFixed(clamp(seat.state[i], -30000'f32, 30000'f32)))
  let modelProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## 0 hidden width, 1 inputs, 2 outputs, 3 decision period, 4 head of the
    ## last decision (arguments 5..9 = heads 0..4).
    let seat = seatOf()
    if seat == nil:
      return 0
    case arguments[0]
    of 0: (if seat.actor != nil: int32(seat.actor.hiddenSize) else: 0)
    of 1: int32(ObservationSize)
    of 2: int32(ActionOutputs)
    of 3: seat.period
    of 5 .. 9: seat.heads[arguments[0] - 5]
    else: 0
  discard host.addFunction("gota_act", 0, actProc, 800)
  discard host.addFunction("run_neural_net", 0, runProc, 4)
  discard host.addFunction("neuralObservation", 1, observationProc, 4)
  discard host.addFunction("neuralLogits", 1, logitsProc, 4)
  discard host.addFunction("neuralState", 1, stateProc, 4)
  discard host.addFunction("neuralModel", 1, modelProc, 4)

proc neuralVmLimits*(): Limits =
  ## Neural-package seats: the hero limits with room for the policy glue and
  ## the neural host functions (plain .bas seats keep heroVmLimits).
  result = heroVmLimits()
  result.maxHostFunctions = 160
  result.maxInstructions = 40_000
  result.maxWorkUnits = 100_000
