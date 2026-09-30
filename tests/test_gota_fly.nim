import
  std/[math, os],
  bassy,
  polyworld/cli,
  ../examples/gods_of_the_arena/neural/[common, richard, david, andre, fly],
  ../examples/gods_of_the_arena/[bots, maps, replays, sim],
  neuralfixtures

const Root = currentSourcePath().parentDir.parentDir

proc rejected(action: proc() {.closure.}): bool =
  ## Requires malformed inputs to fail through the library boundary.
  try:
    action()
  except BasicError:
    return true

proc near(value: Fixed, expected: float): bool =
  ## Q16.16 outputs match a float reference to rounding.
  abs(float(value.toFloat32) - expected) < 1.0 / 32768.0

echo "Testing fly connectome loading and recurrent inference"
block:
  let model = loadFly(flyFixture())
  doAssert model.neurons == 2 and model.steps == 1
  var inputs = newSeq[Fixed](45)
  inputs[0] = 0.5'fx
  let
    first = inferFly(model, "", inputs)
    second = inferFly(model, first.state, inputs)
  doAssert first.outputs.len == 12 and first.state.len == 8
  # Step one only reaches neuron 0; the readout neuron is still silent.
  doAssert first.outputs[0] == 0'fx and first.outputs[11] == 0.25'fx
  # Step two: neuron 1 = 2 tanh(0.5), read out through tanh.
  doAssert second.outputs[0].near(tanh(2.0 * tanh(0.5)))
  doAssert second.outputs[11].near(tanh(2.0 * tanh(0.5)) + 0.25)
  doAssert inferFly(model, first.state, inputs) == second
  doAssert rejected(proc() = discard loadFly("bad"))
  doAssert rejected(proc() = discard loadFly(flyFixture()[0 ..< 100]))
  doAssert rejected(proc() = discard loadFly(flyFixture() & "\0\0\0\0"))
  doAssert rejected(proc() = discard loadFly(flyFixture(leak = 0)))
  doAssert rejected(proc() = discard loadFly(flyFixture(leak = 1.5)))
  doAssert rejected(proc() = discard loadFly(flyFixture(source = 2)))
  doAssert rejected(proc() = discard loadFly(
    flyFixture(offsets = [0'u32, 1, 0])))
  doAssert rejected(proc() = discard loadFly(
    flyFixture(offsets = [0'u32, 0, 0])))
  doAssert rejected(proc() = discard inferFly(model, "", inputs[0 .. 43]))
  doAssert rejected(proc() = discard inferFly(model, "bad", inputs))

echo "Testing fly_nn binding, failed-call atomicity and blob state"
block:
  let
    policy = loadPolicy(zipFixture([
      ("policy.bas", "end"), ("fly.bin", flyFixture()),
      ("other.bin", flyFixture()),
      # A finite readout bias overflows the Q16.16 output range.
      ("huge.bin", flyFixture(valueBias = 1_000_000.0'f))
    ]))
    context = NeuralContext(policy: policy)
  var host = initHost()
  host.addNeuralFunctions(
    richardRunner(context), davidRunner(context), andreRunner(context),
    flyRunner(context)
  )
  var limits = defaultLimits()
  limits.maxNativeMemoryBytes = NativeMemoryBytes
  let program = compile("""
dim data(44)
data(0) = 0.5
if initialized = 0 then
  state = blobCreate()
  initialized = 1
end if
res = fly_nn(path$, state, data)
answer = res(0)
""", host, limits)
  var vm = initRuntime(program, host, limits)
  vm.setGlobal("path$", "fly.bin")
  discard vm.run()
  doAssert vm.getGlobalValue("answer").asFixed == 0'fx
  vm.restart()
  discard vm.run()
  doAssert vm.getGlobalValue("answer").asFixed.near(tanh(2.0 * tanh(0.5)))
  let
    state = vm.getGlobalValue("state")
    before = vm.getBlob(state)
  doAssert before.len == 8
  for path in ["missing.bin", "../fly.bin", "other.bin", "huge.bin"]:
    vm.putBlob(state, before, "fly:" & path)
    vm.setGlobal("path$", path)
    vm.restart()
    doAssert rejected(proc() = discard vm.run()) == (path != "other.bin")
    if path != "other.bin":
      doAssert vm.getBlob(state) == before
  for binding in ["fly:other.bin", "andre:fly.bin"]:
    vm.putBlob(state, before, binding)
    vm.setGlobal("path$", "fly.bin")
    vm.restart()
    doAssert rejected(proc() = discard vm.run())
    doAssert vm.getBlob(state) == before

echo "Testing the fly.bas example package in every hero seat"
block:
  let game = newGame(generateMap(7), 600, 10, false,
    ReplayData(), drafting = false)
  game.recorder = initReplayRecorder(game.currentSetup(1000))
  game.loadBots([BotGroup(path: Root /
    "examples/gods_of_the_arena/neural/examples/synthetic-fly.zip",
    count: 10)])
  game.world.tick = 1
  game.runBotDecisions()
  for i, vm in game.heroVms:
    doAssert not vm.failed, vm.lastError
    doAssert vm.runtime.nativeMemoryBytes < NativeMemoryBytes
    for seat in 0 ..< 5:
      let value = vm.runtime.getArrayValue("flyData", int32(40 + seat))
      doAssert value.asFixed == fixed(int32(seat == i mod 5))
    let state = vm.runtime.getGlobalValue("flyState")
    doAssert vm.runtime.getBlob(state).len == 8
    doAssert vm.runtime.inputValues(
      vm.runtime.getGlobalValue("flyResult"), 12)[11] == 0.25'fx
