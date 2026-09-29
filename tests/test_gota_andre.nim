import
  std/[os, strutils, tempfiles],
  bassy,
  polyworld/cli,
  ../examples/gods_of_the_arena/neural/[common, richard, david, andre],
  ../examples/gods_of_the_arena/[bots, content, maps, replays, sim],
  neuralfixtures

const Root = currentSourcePath().parentDir.parentDir

proc rejected(action: proc() {.closure.}): bool =
  ## Requires malformed inputs to fail through the library boundary.
  try:
    action()
  except BasicError:
    return true

proc replaceWord(bytes: var string, offset: int, value: uint32) =
  ## Changes one header, weight or state word in a synthetic fixture.
  for i in 0 ..< 4:
    bytes[offset + i] = char((value shr (8 * i)) and 255)

echo "Testing Andre aligned checkpoints and stacked recurrent inference"
block:
  let
    wrapped = andreFixture()
    raw = andreFixture(wrapped = false)
    model = loadAndre(wrapped)
    inputs = newSeq[Fixed](45)
    first = inferAndre(model, "", inputs)
    second = inferAndre(model, first.state, inputs)
  doAssert model.hidden == 12 and model.layers == 1
  doAssert first.outputs.len == 12 and first.state.len == 48
  doAssert first.outputs[0] == 0.125'fx
  doAssert first.outputs[11] == first.outputs[0]
  doAssert second.outputs[0] == 0.1875'fx
  var reader = ModelReader(bytes: first.state)
  doAssert cast[float32](reader.readWord()) == 0.25'f
  for omitted in 0 .. 7:
    let padded = loadAndre(raw[0 ..< raw.len - omitted * 4])
    doAssert inferAndre(padded, "", inputs) == first
  let stacked = inferAndre(loadAndre(andreFixture(12, 2)), "", inputs)
  doAssert stacked.state.len == 96
  doAssert stacked.outputs[0] == 0.21875'fx
  reader = ModelReader(bytes: stacked.state, position: 48)
  doAssert cast[float32](reader.readWord()) == 0.3125'f
  doAssert rejected(proc() = discard loadAndre("bad"))
  doAssert rejected(proc() = discard loadAndre(raw[0 ..< raw.len - 32]))
  doAssert rejected(proc() = discard loadAndre(wrapped & "\0\0\0\0"))
  doAssert rejected(proc() = discard loadAndre(andreFixture(12, 13, false)))
  doAssert loadAndre(andreFixture(12, 13)).layers == 13
  for (offset, value) in [(8, 3'u32), (8, 4097'u32), (12, 0'u32),
      (12, 17'u32), (16, 0x7fc00000'u32), (16, 0x7f800000'u32)]:
    var corrupt = wrapped
    corrupt.replaceWord(offset, value)
    doAssert rejected(proc() = discard loadAndre(corrupt))
  doAssert rejected(proc() = discard inferAndre(model, "", inputs[0 .. 43]))
  doAssert rejected(proc() = discard inferAndre(model, "bad", inputs))
  var corruptState = first.state
  corruptState.replaceWord(0, 0x7fc00000)
  doAssert rejected(proc() = discard inferAndre(model, corruptState, inputs))

echo "Testing Andre dense negative activations against PufferNet reference"
block:
  # These golden values use synthetic weights and the scalar CPU evaluator.
  const
    States = [1062011892'u32, 1055123134, 1065957138, 1063376079,
      1056477110, 1058888577, 1059568463, 1054422888]
    Outputs = [-12090, 23265, -14258, 21097, 1659, -4003,
      -508, 8847, 15408, -22114, 13241, -6198]
  var bytes = andreFixture(4, 2)
  for i in 0 ..< (bytes.len - 16) div 4:
    let value = float32((i * 37 + 17) mod 65 - 32) / 64.0'f
    bytes.replaceWord(16 + i * 4, cast[uint32](value))
  let model = loadAndre(bytes)
  var
    inputs: array[45, Fixed]
    next: tuple[outputs: seq[Fixed], state: string]
  for step in 0 ..< 20:
    for i in 0 ..< inputs.len:
      inputs[i] = Fixed(int32((step * 11731 + i * 973) mod 131072 - 65536))
    next = inferAndre(model, next.state, inputs)
  var reader = ModelReader(bytes: next.state)
  for expected in States:
    # Allow platform libm rounding while catching recurrence/order errors.
    doAssert abs(cast[float32](reader.readWord()) -
      cast[float32](expected)) < 0.000001'f
  for i, expected in Outputs:
    doAssert abs(int32(next.outputs[i]) - int32(expected)) <= 1

echo "Testing Andre binding, failed-call atomicity, isolation and memory"
block:
  var huge = andreFixture()
  # A finite decoder weight overflows the Q16.16 output range.
  huge.replaceWord(16 + 544 * 4, cast[uint32](1_000_000.0'f))
  let
    policy = loadPolicy(zipFixture([
      ("policy.bas", "end"), ("a.bin", andreFixture()),
      ("b.bin", andreFixture()), ("huge.bin", huge)
    ]))
    context = NeuralContext(policy: policy)
  var host = initHost()
  host.addNeuralFunctions(
    richardRunner(context), davidRunner(context), andreRunner(context)
  )
  var limits = defaultLimits()
  limits.maxNativeMemoryBytes = NativeMemoryBytes
  let program = compile("""
dim data(44)
if initialized = 0 then
  state = blobCreate()
  alias = state
  initialized = 1
end if
res = andre_nn(path$, alias, data)
answer = res(0)
""", host, limits)
  var vm = initRuntime(program, host, limits)
  vm.setGlobal("path$", "a.bin")
  discard vm.run()
  let
    state = vm.getGlobalValue("state")
    before = vm.getBlob(state)
    memory = vm.nativeMemoryBytes
  doAssert vm.getGlobalValue("answer").asFixed == 0.125'fx
  for i in 0 ..< 1000:
    vm.restart()
    discard vm.run()
  doAssert vm.nativeMemoryBytes <= memory + 4096
  for path in ["missing.bin", "../a.bin", "b.bin", "huge.bin"]:
    vm.putBlob(state, before, "andre:" & path)
    vm.setGlobal("path$", path)
    vm.restart()
    doAssert rejected(proc() = discard vm.run()) == (path != "b.bin")
    if path != "b.bin":
      doAssert vm.getBlob(state) == before
  for binding in ["andre:b.bin", "david:a.bin", "richard:a.bin"]:
    vm.putBlob(state, before, binding)
    vm.setGlobal("path$", "a.bin")
    vm.restart()
    doAssert rejected(proc() = discard vm.run())
    doAssert vm.getBlob(state) == before
  let other = initRuntime(program, host, limits)
  doAssert rejected(proc() = discard other.getBlob(state))
  vm.reset()
  doAssert rejected(proc() = discard vm.getBlob(state))
  vm.setGlobal("path$", "a.bin")
  discard vm.run()
  doAssert vm.getBlob(vm.getGlobalValue("state")) == before

echo "Testing Andre latched observations, seat IDs and cadence through death"
block:
  let
    directory = createTempDir("gota-andre-", "")
    path = directory / "extensionless"
    library = readFile(Root /
      "examples/gods_of_the_arena/neural/policies/andre.bas").split(
        "' Example policy.")[0]
    source = library & """
dim f(40)
andreAdvance()
if selfHp <= 0 or selfStunTicks > 0 then
  end
end if
f(0) = 100
andreCapture()
decision = andreAction
"""
  defer:
    removeFile(path)
    removeDir(directory)
  writeFile(path, zipFixture([("nested/policy.bas", source),
    ("weights.bin", andreFixture())], true))
  let game = newGame(generateMap(7), 600, 10, false,
    ReplayData(), drafting = false)
  game.recorder = initReplayRecorder(game.currentSetup(1000))
  game.loadBots([BotGroup(path: path, count: 10)])
  game.world.tick = 1
  game.runBotDecisions()
  for i, vm in game.heroVms:
    doAssert not vm.failed, vm.lastError
    doAssert vm.lastInstructions < vm.limits.maxInstructions
    doAssert vm.runtime.getArrayValue("andreData", 0).asFixed == 1.0'fx
    for seat in 0 ..< 5:
      let value = vm.runtime.getArrayValue("andreData", int32(40 + seat))
      doAssert value.asFixed ==
        fixed(int32(seat == i mod 5))
    doAssert vm.runtime.inputValues(
      vm.runtime.getGlobalValue("andreResult"), 12)[0] == 0.125'fx
  let
    vm = game.heroVms[0]
    state = vm.runtime.getGlobalValue("andreState")
    first = vm.runtime.getBlob(state)
  game.world.tick = 24
  game.runBotDecisions()
  doAssert vm.runtime.getBlob(state) == first
  game.world.heroes[0].hp = 0
  game.world.tick = 25
  game.runBotDecisions()
  var inputs = newSeq[Fixed](45)
  for i in 0 ..< inputs.len:
    inputs[i] = vm.runtime.getArrayValue("andreData", int32(i)).asFixed
  let expected = inferAndre(loadAndre(andreFixture()), first, inputs)
  doAssert vm.runtime.getBlob(state) == expected.state
  game.world.tick = 49
  game.runBotDecisions()
  doAssert vm.runtime.getBlob(state) != expected.state
  let deadState = vm.runtime.getBlob(state)
  game.world.heroes[0].hp = game.world.heroes[0].maxHp
  game.world.heroes[0].controls[StunControl].ends = 100
  game.world.tick = 73
  game.runBotDecisions()
  doAssert vm.runtime.getBlob(state) != deadState
  game.loadBots([BotGroup(path: Root /
    "examples/gods_of_the_arena/neural/examples/synthetic-andre.zip",
    count: 10)])
  game.world.heroes[0].hp = game.world.heroes[0].maxHp
  game.runBotDecisions()
  for vm in game.heroVms:
    doAssert not vm.failed, vm.lastError
    doAssert vm.runtime.nativeMemoryBytes < NativeMemoryBytes

  echo "Testing Andre deterministic sampling and first-index argmax ties"
  writeFile(path, library & """
dim f(40)
andreTemperature = temperature
andreChoose()
""")
  game.loadBots([BotGroup(path: path, count: 10)])
  var outputs = newSeq[Value](12)
  for value in outputs.mitems:
    value = toValue(FixedZero)
  # The value estimate is not a categorical action logit.
  outputs[11] = toValue(100.0'fx)
  for vm in game.heroVms:
    vm.runtime.setGlobal("andreResult", vm.runtime.putArray(outputs))
  game.runBotDecisions()
  let sampler = game.heroVms[0]
  doAssert not sampler.failed, sampler.lastError
  doAssert sampler.runtime.getGlobal("andreAction") == 0
  var choices: seq[int32]
  for pass in 0 ..< 2:
    sampler.runtime.setGlobal("temperature", toValue(1.0'fx))
    sampler.runtime.setGlobal("andreSeed", 1234567)
    for step in 0 ..< 100:
      sampler.runtime.restart()
      discard sampler.runtime.run()
      let chosen = sampler.runtime.getGlobal("andreAction")
      doAssert chosen in 0 .. 10
      if pass == 0:
        choices.add chosen
      else:
        doAssert choices[step] == chosen
  doAssert choices.contains(0) and choices.contains(10)
