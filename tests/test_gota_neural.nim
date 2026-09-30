import
  std/[os, strutils, tempfiles],
  bassy,
  polyworld/cli,
  ../examples/gods_of_the_arena/neural/[common, richard, david, andre, fly],
  ../examples/gods_of_the_arena/[bots, maps, replays, sim],
  neuralfixtures

proc rejected(action: proc() {.closure.}): bool =
  ## Recognizes controlled BASIC and architecture boundary failures.
  try:
    action()
  except BasicError:
    return true

proc hostFor(policy: Policy): Host =
  ## Creates the same direct callback registry without a game world.
  result = initHost()
  let context = NeuralContext(policy: policy)
  result.addNeuralFunctions(
    richardRunner(context), davidRunner(context), andreRunner(context),
    flyRunner(context)
  )

echo "Testing exact Richard integer wrapping and residual fixed-point scores"
for residual in [false, true]:
  let model = loadRichard(richardFixture(residual))
  var data = newSeq[Fixed](model.inputs)
  data[0] = fixed(100)
  let output = inferRichard(model, data)
  doAssert int32(output[0]) == (if residual: 65536 else: 100)
  doAssert int32(output[^1]) == int32(model.outputs - 1)
  data[0] = fixed(-100)
  doAssert int32(inferRichard(model, data)[0]) == 0
var overflow = richardFixture()
# The first encoder coefficient times 100 wraps to -100 in int32.
for i in 0 ..< 4:
  overflow[16 + i] = char((0x7fffffff'u32 shr (8 * i)) and 255)
var combatInput = newSeq[Fixed](25)
combatInput[0] = fixed(100)
doAssert int32(inferRichard(loadRichard(overflow), combatInput)[0]) == 0

echo "Testing synthetic MinGRU state and Q16.16 conversion"
let model = loadDavid(davidFixture(1))
let first = inferDavid(model, "", [FixedZero])
doAssert first.outputs[0] == 0.125'fx
var reader = ModelReader(bytes: first.state)
doAssert cast[float32](reader.readWord()) == 0.25'f
let second = inferDavid(model, first.state, [FixedZero])
doAssert second.outputs[0] == 0.1875'fx
doAssert outputFixed(0.5'f / 65536.0'f) == Fixed(1)
doAssert outputFixed(-0.5'f / 65536.0'f) == Fixed(-1)
doAssert outputFixed(-32768.0'f) == Fixed(low(int32))
for value in [float32(Inf), float32(NaN), 32768.0'f, -32769.0'f]:
  doAssert rejected(proc() = discard outputFixed(value))
doAssert rejected(proc() = discard loadDavid("bad"))
doAssert rejected(proc() = discard loadRichard("bad"))
doAssert rejected(proc() = discard inferDavid(model, "bad", [FixedZero]))
doAssert rejected(proc() = discard inferDavid(model, "", []))

echo "Testing model binding, aliasing, restart, reset and failed-call atomicity"
let policy = loadPolicy(zipFixture([
  ("policy.bas", "end"), ("a.bin", davidFixture(1)),
  ("b.bin", davidFixture(1)), ("bad.bin", "corrupt")
]))
let host = hostFor(policy)
var limits = defaultLimits()
limits.maxNativeMemoryBytes = NativeMemoryBytes
let program = compile("""
dim data(0)
if initialized = 0 then
  state = blobCreate()
  alias = state
  initialized = 1
end if
res = nn_david(path$, alias, data)
score = res(0)
""", host, limits)
var runtime = initRuntime(program, host, limits)
runtime.setGlobal("path$", "a.bin")
discard runtime.run()
let state = runtime.getGlobalValue("state")
doAssert runtime.getGlobalValue("score").asFixed == 0.125'fx
let before = runtime.getBlob(state)
for path in ["b.bin", "bad.bin", "missing.bin", "../a.bin"]:
  runtime.setGlobal("path$", path)
  runtime.restart()
  doAssert rejected(proc() = discard runtime.run())
  doAssert runtime.getBlob(state) == before
runtime.putBlob(state, "")
runtime.setGlobal("path$", "b.bin")
runtime.restart()
discard runtime.run()
doAssert runtime.getGlobalValue("score").asFixed == 0.125'fx
let memory = runtime.nativeMemoryBytes
for i in 0 ..< 1000:
  runtime.restart()
  discard runtime.run()
doAssert runtime.nativeMemoryBytes <= memory + 4096
runtime.reset()
doAssert rejected(proc() = discard runtime.getBlob(state))
runtime.setGlobal("path$", "a.bin")
discard runtime.run()
doAssert runtime.getGlobalValue("score").asFixed == 0.125'fx

echo "Testing synthetic ZIP and raw BASIC together in GOTA"
block:
  let
    directory = createTempDir("gota-neural-", "")
    packed = directory / "staged"
    raw = directory / "plain.bas"
    source = """
dim data(24)
if initialized = 0 then
  state = blobCreate()
  initialized = 1
end if
data(0) = 100
res = nn_richard("weights.bin", state, data)
answer = res(0)
"""
  defer:
    removeFile(packed)
    removeFile(raw)
    removeDir(directory)
  writeFile(packed, zipFixture([("deep/policy.bas", source),
    ("weights.bin", richardFixture())], true))
  writeFile(raw, "answer = 100\n")
  let game = newGame(generateMap(7), 600, 10, false,
    ReplayData(), drafting = false)
  game.loadBots([BotGroup(path: packed, count: 5),
    BotGroup(path: raw, count: 5)])
  game.runBotDecisions()
  for i, vm in game.heroVms:
    doAssert not vm.failed, vm.lastError
    if i < 5:
      doAssert int32(vm.runtime.getGlobalValue("answer").asFixed) == 100
    else:
      doAssert vm.runtime.getGlobal("answer") == 100

echo "Testing BASIC observations, cadence, state reset and hidden enemies"
block:
  const Library = currentSourcePath().parentDir.parentDir /
    "examples/gods_of_the_arena/neural/policies/david.bas"
  let
    directory = createTempDir("gota-neural-basic-", "")
    path = directory / "policy"
    library = readFile(Library).split("' Example policy.")[0]
  defer:
    removeFile(path)
    removeDir(directory)
  writeFile(path, zipFixture([("policy.bas", library & "nnStep()\n"),
    ("model.bin", davidFixture())], true))
  let game = newGame(generateMap(7), 600, 10, false,
    ReplayData(), drafting = false)
  game.recorder = initReplayRecorder(game.currentSetup(1000))
  game.loadBots([BotGroup(path: path, count: 10)])
  game.world.tick = 1
  game.runBotDecisions()
  for vm in game.heroVms:
    doAssert not vm.failed, vm.lastError
    doAssert vm.lastInstructions < vm.limits.maxInstructions
    doAssert vm.lastWork < vm.limits.maxWorkUnits
  let
    vm = game.heroVms[0]
    state = vm.runtime.getGlobalValue("nnState")
    first = vm.runtime.getBlob(state)
  doAssert first.len == 256
  game.world.tick = 2
  game.runBotDecisions()
  doAssert vm.runtime.getBlob(state) == first
  game.world.tick = 5
  game.runBotDecisions()
  doAssert vm.runtime.getBlob(state) != first
  game.world.heroes[0].hp = 0
  game.world.tick = 6
  game.runBotDecisions()
  doAssert vm.runtime.getBlob(state).len == 0
  doAssert vm.runtime.blobBinding(state).len == 0
  game.world.heroes[0].hp = game.world.heroes[0].maxHp
  game.world.tick = 7
  game.runBotDecisions()
  doAssert vm.runtime.getBlob(state) == first
  writeFile(path, library & "nnInitialize()\nnnObserve()\n")
  game.loadBots([BotGroup(path: path, count: 10)])
  for cells in game.world.teamVisible.mitems:
    for cell in cells.mitems:
      cell = 0
  game.runBotDecisions()
  var before = newSeq[Value](1407)
  for i in 0 ..< before.len:
    before[i] = game.heroVms[0].runtime.getArrayValue("nnData", int32(i))
  let enemy = game.world.heroes[5]
  enemy.hp = 123
  enemy.mana = 456
  enemy.totalXp = 9999
  enemy.position.x += 500_000
  game.runBotDecisions()
  doAssert not game.heroVms[0].failed, game.heroVms[0].lastError
  for i, value in before:
    doAssert game.heroVms[0].runtime.getArrayValue("nnData", int32(i)) == value,
      "Hidden enemy changed feature " & $i

echo "Testing failed inference preserves initialized recurrent state"
block:
  var huge = davidFixture(1)
  # Huge finite encoder/decoder weights overflow intermediate FP32 products.
  for offset in [180, 180 + 4 * 64 * (1 + 3 * 64)]:
    for i in 0 ..< 4:
      huge[offset + i] = char((0x7f7fffff'u32 shr (8 * i)) and 255)
  let policy = loadPolicy(zipFixture([
    ("a.bas", "end"), ("huge.bin", huge)
  ]))
  let host = hostFor(policy)
  var vm = initRuntime(compile("""
dim data(0)
if initialized = 0 then
  state = blobCreate()
  initialized = 1
end if
data(0) = input
result = nn_david("huge.bin", state, data)
""", host), host)
  # Zero input still causes an unrepresentable decoder output.
  let state = vm.createBlob()
  vm.putBlob(state, first.state, "david:huge.bin")
  vm.setGlobal("state", state)
  vm.setGlobal("initialized", 1)
  vm.setGlobal("input", 1)
  doAssert rejected(proc() = discard vm.run())
  doAssert vm.getBlob(state) == first.state
  var corrupt = davidFixture(1)
  for i in 0 ..< 4:
    corrupt[180 + i] = char((0x7fc00000'u32 shr (8 * i)) and 255)
  doAssert rejected(proc() = discard loadDavid(corrupt))

echo "Testing BASIC math, static masks, tie selection and seeded sampling"
block:
  const Library = currentSourcePath().parentDir.parentDir /
    "examples/gods_of_the_arena/neural/policies/david.bas"
  let
    directory = createTempDir("gota-neural-sampling-", "")
    path = directory / "policy.bas"
    library = readFile(Library).split("' Example policy.")[0]
  defer:
    removeFile(path)
    removeDir(directory)
  writeFile(path, library & """
nnInitialize()
nnObserve()
nnSampling = sampling
nnChoose()
nnRatio(2147483647, 2147483647)
largeRatio = nnValue
nnRatio(100000, 20000)
largeCounter = nnValue
exponential = exp(-1.0)
root = sqrt(2.0)
emptyRoot = sqrt(-1.0)
unitWeight = exp(0.0)
smallWeight = exp(-16.0)
probeWeight = exp(probe)
""")
  let game = newGame(generateMap(7), 600, 10, false,
    ReplayData(), drafting = false)
  game.recorder = initReplayRecorder(game.currentSetup(100000))
  game.loadBots([BotGroup(path: path, count: 10)])
  for vm in game.heroVms:
    vm.runtime.setGlobal("nnResult", vm.runtime.putArray(newSeq[Value](92)))
  game.runBotDecisions()
  let vm = game.heroVms[0]
  doAssert not vm.failed, vm.lastError
  doAssert vm.runtime.getGlobalValue("largeRatio").asFixed == 1.0'fx
  doAssert vm.runtime.getGlobalValue("largeCounter").asFixed == 5.0'fx
  doAssert abs(vm.runtime.getGlobalValue("exponential").asFixed.toFloat32 -
    0.36787945'f) < 0.00002'f
  doAssert int32(vm.runtime.getGlobalValue("root").asFixed) == 92681
  doAssert vm.runtime.getGlobalValue("emptyRoot").asFixed == FixedZero
  doAssert vm.runtime.getGlobalValue("unitWeight").asFixed == FixedOne
  doAssert vm.runtime.getGlobalValue("smallWeight").asFixed == FixedZero
  for head in 0 ..< 5:
    doAssert vm.runtime.getArray("nnHeads", int32(head)) == 0
  doAssert vm.runtime.getArray("nnAllowed", 8) == 1
  for slot in 0 ..< 25:
    doAssert vm.runtime.getArray("nnAllowed", int32(8 + slot)) ==
      int32(vm.runtime.getArray("nnIds", int32(slot)) != 0)
  var sequence: seq[int32]
  for pass in 0 ..< 2:
    vm.runtime.setGlobal("sampling", 1)
    vm.runtime.setGlobal("nnSeed", 1234567)
    for step in 0 ..< 100:
      vm.runtime.restart()
      discard vm.runtime.run()
      for head, count in [8, 25, 49, 4, 6]:
        let chosen = vm.runtime.getArray("nnHeads", int32(head))
        doAssert chosen >= 0 and chosen < count
        const Offsets = [0, 8, 33, 82, 86]
        doAssert vm.runtime.getArray("nnAllowed", int32(Offsets[head]) +
          chosen) == 1
        if pass == 0:
          sequence.add chosen
        else:
          doAssert sequence[step * 5 + head] == chosen
  doAssert sequence.contains(0) and sequence.contains(1)
  for probe in [10.4'fx, 11.0'fx, 32767.0'fx]:
    vm.runtime.setGlobal("probe", toValue(probe))
    vm.runtime.restart()
    doAssert rejected(proc() = discard vm.runtime.run())

echo "Testing complete public BASIC and ZIP examples"
block:
  const Examples = currentSourcePath().parentDir.parentDir /
    "examples/gods_of_the_arena/neural/examples"
  let game = newGame(generateMap(7), 600, 10, false,
    ReplayData(), drafting = false)
  game.recorder = initReplayRecorder(game.currentSetup(1000))
  game.loadBots([
    BotGroup(path: Examples / "synthetic-richard.zip", count: 5),
    BotGroup(path: Examples / "synthetic-david.zip", count: 5)
  ])
  game.runBotDecisions()
  for vm in game.heroVms:
    doAssert not vm.failed, vm.lastError
    doAssert vm.runtime.nativeMemoryBytes < NativeMemoryBytes
