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
    flyRunner(context), context
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

echo "Testing optional David auxiliary heads"
block:
  const AuxSizes = [10, 23, 4]
  let
    plain = davidAuxFixture(newSeq[int]())
    extended = davidAuxFixture(AuxSizes)
    plainModel = loadDavid(plain)
    auxModel = loadDavid(extended)
  doAssert plainModel.auxHeads.len == 0 and plainModel.auxOutputs == 0
  doAssert auxModel.auxHeads == @AuxSizes and auxModel.auxOutputs == 37
  doAssert extended.len == plain.len + 4 * (1 + AuxSizes.len) +
    4 * 64 * auxModel.auxOutputs
  var
    data = newSeq[Fixed](1407)
    plainState, auxState: string
  for step in 0 ..< 6:
    for i in 0 ..< data.len:
      data[i] = Fixed(int32(((i * 37 + step * 11) mod 131) - 65) * 1024)
    let
      a = inferDavid(plainModel, plainState, data)
      b = inferDavid(auxModel, auxState, data)
    # Auxiliary heads never change the action logits or recurrent state.
    doAssert a.outputs == b.outputs and a.state == b.state
    doAssert a.aux.len == 0 and b.aux.len == 37
    for row in 0 ..< b.aux.len:
      doAssert b.aux[row] == b.outputs[row mod 92]
    plainState = a.state
    auxState = b.state

  proc patched(bytes: string, offset: int, value: uint32): string =
    ## Replaces one little-endian header or weight word.
    result = bytes
    for i in 0 ..< 4:
      result[offset + i] = char((value shr (8 * i)) and 255)
  const AuxHeader = 160 + 4 * 5
  doAssert rejected(proc() = discard loadDavid(patched(extended, 8, 3)))
  doAssert rejected(proc() = discard loadDavid(patched(plain, 8, 2)))
  doAssert rejected(proc() = discard loadDavid(patched(extended, AuxHeader, 0)))
  doAssert rejected(proc() = discard loadDavid(patched(extended, AuxHeader, 17)))
  doAssert rejected(proc() = discard loadDavid(
    patched(extended, AuxHeader + 4, 1)))
  doAssert rejected(proc() = discard loadDavid(extended[0 ..< ^4]))
  doAssert rejected(proc() = discard loadDavid(extended & "\0\0\0\0"))
  doAssert rejected(proc() = discard loadDavid(
    patched(extended, extended.len - 4, 0x7fc00000'u32)))
  doAssert rejected(proc() = discard loadDavid(davidAuxFixture([1024, 2])))
  doAssert loadDavid(davidAuxFixture([1022, 2])).auxOutputs == 1024

  let policy = loadPolicy(zipFixture([
    ("policy.bas", "end"), ("aux.bin", extended), ("plain.bin", plain)
  ]))
  let host = hostFor(policy)
  var limits = defaultLimits()
  limits.maxNativeMemoryBytes = NativeMemoryBytes
  let program = compile("""
dim data(1406)
dim logits(36)
dim best(2)
dim sizes(2)
if initialized = 0 then
  state = blobCreate()
  initialized = 1
end if
for i = 0 to 1406
  data(i) = ((i * 37) mod 131 - 65) / 64
next i
before = nn_aux_count()
if probe = 1 then
  value = nn_aux(0, 0)
end if
res = nn_david(path$, state, data)
count = nn_aux_count()
position = 0
for k = 0 to count - 1
  sizes(k) = nn_aux_size(k)
  best(k) = nn_aux_argmax(k)
  for i = 0 to sizes(k) - 1
    logits(position) = nn_aux(k, i)
    position = position + 1
  next i
next k
if probe = 2 then
  value = nn_aux(count, 0)
end if
if probe = 3 then
  value = nn_aux(0, sizes(0))
end if
if probe = 4 then
  value = nn_aux_argmax(-1)
end if
""", host, limits)
  var runtime = initRuntime(program, host, limits)
  runtime.setGlobal("path$", "aux.bin")
  runtime.setGlobal("probe", 1)
  doAssert rejected(proc() = discard runtime.run())
  runtime.setGlobal("probe", 0)
  runtime.restart()
  discard runtime.run()
  var expected = newSeq[Fixed](1407)
  for i in 0 ..< expected.len:
    expected[i] = Fixed(int32((i * 37) mod 131 - 65) * 1024)
  let direct = inferDavid(auxModel, "", expected)
  doAssert runtime.getGlobal("before") == 0
  doAssert runtime.getGlobal("count") == 3
  var offset = 0
  for k, size in AuxSizes:
    doAssert runtime.getArray("sizes", int32(k)) == int32(size)
    var top = 0
    for i in 0 ..< size:
      doAssert runtime.getArrayValue("logits", int32(offset + i)).asFixed ==
        direct.aux[offset + i]
      if direct.aux[offset + i] > direct.aux[offset + top]:
        top = i
    doAssert runtime.getArray("best", int32(k)) == int32(top)
    offset += size
  for probe in 2 .. 4:
    runtime.setGlobal("probe", probe)
    runtime.restart()
    doAssert rejected(proc() = discard runtime.run())
  # A failed call keeps the previous auxiliary logits, like its state.
  runtime.setGlobal("probe", 0)
  runtime.setGlobal("path$", "plain.bin")
  runtime.restart()
  doAssert rejected(proc() = discard runtime.run())
  doAssert runtime.getGlobal("before") == 3
  runtime.putBlob(runtime.getGlobalValue("state"), "")
  runtime.restart()
  discard runtime.run()
  doAssert runtime.getGlobal("before") == 3
  doAssert runtime.getGlobal("count") == 0
  runtime.setGlobal("probe", 1)
  runtime.restart()
  doAssert rejected(proc() = discard runtime.run())

  # Ties choose the first index, as the BASIC action decoder does.
  var tied = extended
  let tail = tied.len - 4 * 64 * 4
  for i in tail ..< tied.len:
    tied[i] = '\0'
  let tiedPolicy = loadPolicy(zipFixture([("policy.bas", "end"),
    ("aux.bin", tied)]))
  let tiedHost = hostFor(tiedPolicy)
  var tiedRuntime = initRuntime(compile("""
dim data(1406)
state = blobCreate()
res = nn_david("aux.bin", state, data)
best = nn_aux_argmax(2)
zero = nn_aux(2, 3)
""", tiedHost, limits), tiedHost, limits)
  discard tiedRuntime.run()
  doAssert tiedRuntime.getGlobal("best") == 0
  doAssert tiedRuntime.getGlobalValue("zero").asFixed == FixedZero

echo "Testing auxiliary heads leave David glue decisions unchanged in GOTA"
block:
  const Library = currentSourcePath().parentDir.parentDir /
    "examples/gods_of_the_arena/neural/policies/david.bas"
  let
    directory = createTempDir("gota-neural-aux-", "")
    library = readFile(Library).split("' Example policy.")[0]
    glue = library & "nnStep()\nif nn_aux_count() > 0 then\n" &
      "  draftChoice = nn_aux_argmax(0)\n  shopChoice = nn_aux_argmax(1)\n" &
      "  levelChoice = nn_aux_argmax(2)\nend if\n"
  defer:
    removeDir(directory)
  var runs: seq[seq[string]]
  for model in [davidAuxFixture(newSeq[int]()), davidAuxFixture([10, 23, 4])]:
    let path = directory / ("policy" & $runs.len)
    writeFile(path, zipFixture([("policy.bas", glue), ("model.bin", model)],
      true))
    let game = newGame(generateMap(7), 600, 10, false,
      ReplayData(), drafting = false)
    game.recorder = initReplayRecorder(game.currentSetup(1000))
    game.loadBots([BotGroup(path: path, count: 10)])
    var trace: seq[string]
    for tick in 1 .. 40:
      game.world.tick = int32(tick)
      game.runBotDecisions()
      for vm in game.heroVms:
        doAssert not vm.failed, vm.lastError
        doAssert vm.lastInstructions < vm.limits.maxInstructions
        let state = vm.runtime.getGlobalValue("nnState")
        var line = vm.runtime.getBlob(state)
        for head in 0 ..< 5:
          line.add " " & $vm.runtime.getArray("nnHeads", int32(head))
        trace.add line
    if runs.len == 1:
      let vm = game.heroVms[0]
      doAssert vm.runtime.getGlobal("shopChoice") in 0'i32 ..< 23'i32
      doAssert vm.runtime.getGlobal("levelChoice") in 0'i32 ..< 4'i32
    runs.add trace
  doAssert runs[0] == runs[1]
