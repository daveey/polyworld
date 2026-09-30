import
  std/math,
  bassy,
  common

when defined(vcc):
  {.localPassC: "/fp:strict".}
else:
  {.localPassC: "-ffp-contract=off".}

const
  FlyMagic* = "FLYNN1\0\0"
  FlyInputs* = 45
  FlyOutputs* = 12
  MaxNeurons = 200_000
  MaxEdges = 1_500_000
  MaxSteps = 16

type
  FlyModel* = object
    ## A connectome rate network: fixed sparse wiring grouped by target.
    neurons*, steps*: int
    leak: float32
    offsets: seq[int32]
    sources: seq[int32]
    weights: seq[float32]
    bias: seq[float32]
    driveNeurons: seq[int32]
    drive: seq[float32]
    readNeurons: seq[int32]
    readout: seq[float32]
    readoutBias: seq[float32]
  CachedModel = object
    path: string
    model: FlyModel

proc readFloats(reader: var ModelReader, count: int): seq[float32] =
  ## Reads finite little-endian FP32 words.
  result = newSeq[float32](count)
  for value in result.mitems:
    value = cast[float32](reader.readWord())
    if not value.finite:
      fail("Nonfinite fly model weight")

proc readNeuronIds(
    reader: var ModelReader,
    count, neurons: int
): seq[int32] =
  ## Reads neuron indices and checks each one is inside the network.
  result = newSeq[int32](count)
  for value in result.mitems:
    let id = reader.readWord()
    if id >= uint32(neurons):
      fail("Fly model neuron index is out of range")
    value = int32(id)

proc loadFly*(bytes: string): FlyModel =
  ## Loads a FLYNN1 connectome network and validates every index.
  if bytes.len < 36 or bytes[0 ..< 8] != FlyMagic:
    fail("Fly model needs FLYNN1 magic")
  var reader = ModelReader(bytes: bytes, position: 8)
  result.neurons = reader.readCount(MaxNeurons)
  let
    edges = reader.readCount(MaxEdges)
    inputs = reader.readCount(FlyInputs)
    driven = reader.readCount(MaxNeurons)
    read = reader.readCount(MaxNeurons)
  result.steps = reader.readCount(MaxSteps)
  result.leak = cast[float32](reader.readWord())
  if result.neurons < 1 or inputs != FlyInputs or driven < 1 or
    read < 1 or result.steps < 1 or not result.leak.finite or
    result.leak <= 0 or result.leak > 1:
      fail("Unsupported fly model dimensions")
  let expected = 36 + 4 * (
    result.neurons + 1 + 2 * edges + result.neurons +
    driven * (1 + FlyInputs) + read * (1 + FlyOutputs) + FlyOutputs)
  if bytes.len != expected:
    fail("Fly model byte length does not match its shape")
  result.offsets = newSeq[int32](result.neurons + 1)
  var previous = 0'u32
  for i in 0 .. result.neurons:
    let offset = reader.readWord()
    if offset < previous or offset > uint32(edges):
      fail("Fly model edge offsets are not ordered")
    result.offsets[i] = int32(offset)
    previous = offset
  if result.offsets[0] != 0 or result.offsets[^1] != int32(edges):
    fail("Fly model edge offsets do not cover every edge")
  result.sources = reader.readNeuronIds(edges, result.neurons)
  result.weights = reader.readFloats(edges)
  result.bias = reader.readFloats(result.neurons)
  result.driveNeurons = reader.readNeuronIds(driven, result.neurons)
  result.drive = reader.readFloats(driven * FlyInputs)
  result.readNeurons = reader.readNeuronIds(read, result.neurons)
  result.readout = reader.readFloats(read * FlyOutputs)
  result.readoutBias = reader.readFloats(FlyOutputs)

proc storageBytes*(model: FlyModel): int64 =
  ## Native storage held by one parsed model.
  int64(model.offsets.len + model.sources.len + model.weights.len +
    model.bias.len + model.driveNeurons.len + model.drive.len +
    model.readNeurons.len + model.readout.len + model.readoutBias.len) * 4

{.push floatChecks: off.}

proc rate(value: float32): float32 =
  ## Firing rate tanh(relu(x)), written with exp like the other runners.
  if value <= 0:
    return 0
  1.0'f - 2.0'f / (exp(2.0'f * value) + 1.0'f)

{.pop.}

proc inferFly*(
    model: FlyModel,
    state: string,
    data: openArray[Fixed]
): tuple[outputs: seq[Fixed], state: string] =
  ## Runs the connectome for its steps and returns eleven logits and value.
  if data.len != FlyInputs:
    fail("Fly input needs exactly 45 values")
  if state.len != 0 and state.len != model.neurons * 4:
    fail("Fly state shape mismatch")
  var
    potential = newSeq[float32](model.neurons)
    rates = newSeq[float32](model.neurons)
    external = newSeq[float32](model.neurons)
    inputs: array[FlyInputs, float32]
    reader = ModelReader(bytes: state)
  if state.len > 0:
    for value in potential.mitems:
      value = cast[float32](reader.readWord())
      if not value.finite:
        fail("Nonfinite fly recurrent state")
  try:
    for i, value in data:
      inputs[i] = value.toFloat32
    for i in 0 ..< model.neurons:
      external[i] = model.bias[i]
    for row, neuron in model.driveNeurons:
      var sum = 0.0'f
      let start = row * FlyInputs
      for i in 0 ..< FlyInputs:
        sum = sum + inputs[i] * model.drive[start + i]
      external[neuron] = external[neuron] + sum
    for _ in 0 ..< model.steps:
      for i in 0 ..< model.neurons:
        rates[i] = rate(potential[i])
      for i in 0 ..< model.neurons:
        var sum = 0.0'f
        for edge in model.offsets[i] ..< model.offsets[i + 1]:
          sum = sum + rates[model.sources[edge]] * model.weights[edge]
        let total = sum + external[i]
        potential[i] = potential[i] + model.leak * (total - potential[i])
        if not potential[i].finite:
          fail("Nonfinite fly intermediate")
    var logits: array[FlyOutputs, float32]
    for output in 0 ..< FlyOutputs:
      var sum = 0.0'f
      let start = output * model.readNeurons.len
      for i, neuron in model.readNeurons:
        sum = sum + rate(potential[neuron]) * model.readout[start + i]
      logits[output] = sum + model.readoutBias[output]
    result.outputs = newSeq[Fixed](FlyOutputs)
    for i, value in logits:
      result.outputs[i] = outputFixed(value)
    for value in potential:
      result.state.addWord(cast[uint32](value))
  except FloatingPointDefect as error:
    fail("Nonfinite fly intermediate: " & error.msg)

proc flyRunner*(context: NeuralContext): ContextHostProc =
  ## Keeps parsed connectome weights private to one policy VM.
  var models: seq[CachedModel]
  result = proc(runtime: Runtime, arguments: openArray[Value]): Value =
    ## Implements the same transactional three-argument neural boundary.
    let path = runtime.getString(arguments[0])
    var index = -1
    for i, cached in models:
      if cached.path == path:
        index = i
        break
    if index < 0:
      let bytes = context.modelBytes(runtime, path)
      runtime.reserveNativeMemory(int64(bytes.len + path.len) + 1024)
      let model = loadFly(bytes)
      models.add CachedModel(path: path, model: model)
      index = models.high
    let
      model = addr models[index].model
      binding = "fly:" & path
      previous = runtime.checkState(arguments[1], binding)
      scratch = int64(model.neurons * 16 + 4096)
    runtime.reserveNativeMemory(scratch)
    defer:
      runtime.releaseNativeMemory(scratch)
    let
      data = runtime.inputValues(arguments[2], FlyInputs)
      next = inferFly(model[], previous, data)
    runtime.commit(arguments[1], binding, next.state, next.outputs)
