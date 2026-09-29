import
  std/math,
  bassy,
  common

const
  ModelMagic* = "GOTANET1"
  MaxParameters = 2_000_000
  Widths = [64, 128, 256, 384, 512]

type
  DavidModel* = object
    inputs*, hidden*, outputs*: int
    heads*: seq[int]
    weights: seq[float32]
  CachedModel = object
    path: string
    model: DavidModel

proc loadDavid*(bytes: string): DavidModel =
  ## Loads David's unchanged GOTANET1 encoder, MinGRU and decoder weights.
  if bytes.len < 160 or bytes[0 ..< 8] != ModelMagic:
    fail("David model needs GOTANET1 magic")
  var reader = ModelReader(bytes: bytes, position: 8)
  let version = reader.readWord()
  result.inputs = reader.readCount(4096)
  result.hidden = reader.readCount(512)
  result.outputs = reader.readCount(1024)
  let
    heads = reader.readCount(32)
    parameters = reader.readCount(MaxParameters)
  if version != 1 or result.inputs notin 1 .. 4096 or
    result.hidden notin Widths or result.outputs notin 2 .. 1024 or
    heads notin 1 .. 32:
      fail("Unsupported David model dimensions or version")
  let expected = result.hidden *
    (result.inputs + 3 * result.hidden + result.outputs)
  if parameters != expected or expected > MaxParameters or
    bytes.len != 160 + 4 * heads + 4 * expected:
      fail("Invalid David model parameter count or byte length")
  for i in 32 ..< 160:
    if bytes[i] notin {'0' .. '9', 'a' .. 'f'}:
      fail("Invalid David model contract hash")
  reader.position = 160
  var total = 0
  for _ in 0 ..< heads:
    let size = reader.readCount(1024)
    if size notin 2 .. 1024:
      fail("Invalid David model output head")
    result.heads.add size
    total += size
  if total != result.outputs:
    fail("David model head sizes do not match outputs")
  result.weights = newSeq[float32](expected)
  for weight in result.weights.mitems:
    weight = cast[float32](reader.readWord())
    if not weight.finite:
      fail("Nonfinite David model weight")

proc sigmoid(value: float32): float32 =
  ## Uses the same stable branches as David's FP32 actor.
  let exponential = exp(-abs(value))
  if value >= 0:
    1.0'f / (1.0'f + exponential)
  else:
    exponential / (1.0'f + exponential)

proc interpolate(a, b, weight: float32): float32 =
  ## Preserves the reference actor's two FP32 interpolation branches.
  let delta = b - a
  if abs(weight) < 0.5'f:
    a + weight * delta
  else:
    b - delta * (1.0'f - weight)

proc inferDavid*(
    model: DavidModel,
    state: string,
    data: openArray[Fixed]
): tuple[outputs: seq[Fixed], state: string] =
  ## Runs one FP32 recurrent step without quantizing the retained state.
  try:
    if data.len != model.inputs:
      fail("David input shape mismatch")
    if state.len != 0 and state.len != model.hidden * 4:
      fail("David state shape mismatch")
    var
      previous = newSeq[float32](model.hidden)
      reader = ModelReader(bytes: state)
    if state.len > 0:
      for value in previous.mitems:
        value = cast[float32](reader.readWord())
        if not value.finite:
          fail("Nonfinite David recurrent state")
    var
      inputs = newSeq[float32](model.inputs)
      encoded = newSeq[float32](model.hidden)
      combined = newSeq[float32](model.hidden * 3)
      mixed = newSeq[float32](model.hidden)
      position = 0
    for i in 0 ..< data.len:
      inputs[i] = data[i].toFloat32
    for row in 0 ..< model.hidden:
      var sum = 0.0'f
      for value in inputs:
        sum += value * model.weights[position]
        inc position
      encoded[row] = sum
    for row in 0 ..< combined.len:
      var sum = 0.0'f
      for value in encoded:
        sum += value * model.weights[position]
        inc position
      combined[row] = sum
    for i in 0 ..< model.hidden:
      let
        candidate =
          if combined[i] >= 0:
            combined[i] + 0.5'f
          else:
            sigmoid(combined[i])
        gate = sigmoid(combined[model.hidden + i])
        next = interpolate(previous[i], candidate, gate)
        highway = sigmoid(combined[2 * model.hidden + i])
      mixed[i] = highway * next + (1.0'f - highway) * encoded[i]
      if not next.finite or not mixed[i].finite:
        fail("Nonfinite David intermediate")
      result.state.addWord(cast[uint32](next))
    result.outputs = newSeq[Fixed](model.outputs)
    for row in 0 ..< model.outputs:
      var sum = 0.0'f
      for value in mixed:
        sum += value * model.weights[position]
        inc position
      result.outputs[row] = outputFixed(sum)
  except FloatingPointDefect as error:
    fail("Nonfinite David intermediate: " & error.msg)

proc davidRunner*(context: NeuralContext): ContextHostProc =
  ## Binds a private immutable-model cache to one policy VM.
  var models: seq[CachedModel]
  result = proc(runtime: Runtime, arguments: openArray[Value]): Value =
    ## Implements nn_david with a single ordinary host-call charge.
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
        models.add CachedModel(path: path, model: loadDavid(bytes))
      except NeuralError:
        runtime.releaseNativeMemory(retained)
        raise
      index = models.high
    let
      model = addr models[index].model
      binding = "david:" & path
      previous = runtime.checkState(arguments[1], binding)
      scratch = int64(model.inputs * 8 + model.hidden * 40 +
        model.outputs * 48 + previous.len + 1024)
    runtime.reserveNativeMemory(scratch)
    defer:
      runtime.releaseNativeMemory(scratch)
    let
      data = runtime.inputValues(arguments[2], model.inputs)
      next = inferDavid(model[], previous, data)
    runtime.commit(arguments[1], binding, next.state, next.outputs)
