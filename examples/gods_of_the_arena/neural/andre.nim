import
  std/math,
  bassy,
  common

when defined(vcc):
  {.localPassC: "/fp:strict".}
else:
  {.localPassC: "-ffp-contract=off".}

const
  AndreMagic* = "ANDRENN1"
  AndreInputs* = 45
  AndreActions* = 11
  AndreOutputs* = AndreActions + 1
  MaxParameters = 4 * 1024 * 1024

type
  AndreModel* = object
    hidden*, layers*: int
    decoder, recurrent, stride, count: int
    weights: seq[float32]
  CachedModel = object
    path: string
    model: AndreModel

proc aligned(count: int): int =
  ## Matches PufferLib's eight-float tensor cursor alignment.
  (count + 7) and not 7

proc layout(hidden, layers: int): AndreModel =
  ## Bounds dimensions before calculating or allocating tensor storage.
  if hidden < 4 or hidden > 4096 or hidden mod 4 != 0 or
    layers < 1 or layers > 16:
      fail("Andre model needs width 4..4096 in multiples of four, 1..16 layers")
  result.hidden = hidden
  result.layers = layers
  result.decoder = aligned(AndreInputs * hidden)
  result.recurrent = aligned(result.decoder + AndreOutputs * hidden)
  result.stride = aligned(3 * hidden * hidden)
  result.count = result.recurrent + layers * result.stride

proc loadAndre*(bytes: string): AndreModel =
  ## Loads raw PufferNet checkpoints or a header selecting an explicit shape.
  var
    start = 0
    explicit = false
    reader = ModelReader(bytes: bytes)
  if bytes.len >= 8 and bytes[0 ..< 8] == AndreMagic:
    reader.position = 8
    let
      hidden = reader.readCount(4096)
      layers = reader.readCount(16)
    result = layout(hidden, layers)
    start = 16
    explicit = true
  if bytes.len <= start or (bytes.len - start) mod 4 != 0:
    fail("Andre weights must contain little-endian FP32 words")
  let count = (bytes.len - start) div 4
  if count > MaxParameters:
    fail("Andre model exceeds its parameter limit")
  if not explicit:
    var found = false
    for hidden in countup(4, 4096, 4):
      for layers in 1 .. 16:
        let candidate = layout(hidden, layers)
        if candidate.count >= count and candidate.count - count <= 7:
          if found:
            fail("Ambiguous Andre shape; use an ANDRENN1 header")
          result = candidate
          found = true
    if not found:
      fail("No Andre hidden width and layer count matches these weights")
  if result.count > MaxParameters or count > result.count or
    result.count - count > 7:
      fail("Andre model byte length does not match its shape")
  # The existing evaluator zero-pads up to seven missing final floats.
  result.weights = newSeq[float32](result.count)
  reader.position = start
  for i in 0 ..< count:
    let value = cast[float32](reader.readWord())
    if not value.finite:
      fail("Nonfinite Andre model weight")
    result.weights[i] = value

{.push floatChecks: off.}

proc sigmoid(value: float32): float32 =
  ## Uses the evaluator's FP32 sigmoid including its negative saturation.
  1.0'f / (1.0'f + exp(-value))

{.pop.}

proc linear(
    model: AndreModel,
    inputs: openArray[float32],
    offset: int,
    outputs: var openArray[float32]
) =
  ## Preserves ordered, separately rounded FP32 products and sums.
  for row in 0 ..< outputs.len:
    var sum = 0.0'f
    let start = offset + row * inputs.len
    for i in 0 ..< inputs.len:
      let product = inputs[i] * model.weights[start + i]
      sum = sum + product
    outputs[row] = sum

proc inferAndre*(
    model: AndreModel,
    state: string,
    data: openArray[Fixed]
): tuple[outputs: seq[Fixed], state: string] =
  ## Runs stacked MinGRU layers and returns eleven logits plus the value.
  if data.len != AndreInputs:
    fail("Andre input needs exactly 45 values")
  let stateCount = model.hidden * model.layers
  if state.len != 0 and state.len != stateCount * 4:
    fail("Andre state shape mismatch")
  var
    previous = newSeq[float32](stateCount)
    reader = ModelReader(bytes: state)
  if state.len > 0:
    for value in previous.mitems:
      value = cast[float32](reader.readWord())
      if not value.finite:
        fail("Nonfinite Andre recurrent state")
  try:
    var
      inputs: array[AndreInputs, float32]
      encoded = newSeq[float32](model.hidden)
      projection = newSeq[float32](3 * model.hidden)
      mixed = newSeq[float32](model.hidden)
      logits: array[AndreOutputs, float32]
    for i, value in data:
      inputs[i] = value.toFloat32
    model.linear(inputs, 0, encoded)
    for layer in 0 ..< model.layers:
      model.linear(encoded, model.recurrent + layer * model.stride,
        projection)
      for i in 0 ..< model.hidden:
        let
          hidden = projection[i]
          gate = sigmoid(projection[model.hidden + i])
          highway = sigmoid(projection[2 * model.hidden + i])
          old = previous[layer * model.hidden + i]
          candidate =
            if hidden >= 0:
              hidden + 0.5'f
            else:
              sigmoid(hidden)
          next = old + gate * (candidate - old)
        mixed[i] = highway * next + (1.0'f - highway) * encoded[i]
        if not next.finite or not mixed[i].finite:
          fail("Nonfinite Andre intermediate")
        result.state.addWord(cast[uint32](next))
      if layer + 1 < model.layers:
        for i in 0 ..< model.hidden:
          encoded[i] = mixed[i]
    model.linear(mixed, model.decoder, logits)
    result.outputs = newSeq[Fixed](AndreOutputs)
    for i, value in logits:
      result.outputs[i] = outputFixed(value)
  except FloatingPointDefect as error:
    fail("Nonfinite Andre intermediate: " & error.msg)

proc andreRunner*(context: NeuralContext): ContextHostProc =
  ## Keeps parsed PufferNet weights private to one policy VM.
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
      let
        bytes = context.modelBytes(runtime, path)
        retained = int64(bytes.len + path.len) + 1024
      runtime.reserveNativeMemory(retained)
      try:
        models.add CachedModel(path: path, model: loadAndre(bytes))
      except NeuralError:
        runtime.releaseNativeMemory(retained)
        raise
      index = models.high
    let
      model = addr models[index].model
      binding = "andre:" & path
      previous = runtime.checkState(arguments[1], binding)
      scratch = int64(model.hidden * (32 + 8 * model.layers) + 4096)
    runtime.reserveNativeMemory(scratch)
    defer:
      runtime.releaseNativeMemory(scratch)
    let
      data = runtime.inputValues(arguments[2], AndreInputs)
      next = inferAndre(model[], previous, data)
    runtime.commit(arguments[1], binding, next.state, next.outputs)
