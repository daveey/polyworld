import
  bassy,
  common

const RichardMagic* = "RICHNN01"

type
  RichardKind* = enum
    IntegerCombat, FixedResidual
  RichardModel* = object
    kind*: RichardKind
    inputs*, hidden*, outputs*: int
    weights: seq[int32]
  CachedModel = object
    path: string
    model: RichardModel

proc loadRichard*(bytes: string): RichardModel =
  ## Loads row-major affine layers in Richard's architecture-owned format.
  if bytes.len < 12 or bytes[0 ..< 8] != RichardMagic:
    fail("Richard model needs RICHNN01 magic")
  var reader = ModelReader(bytes: bytes, position: 8)
  case reader.readWord()
  of 0:
    result.kind = IntegerCombat
    result.inputs = 25
    result.hidden = 16
    result.outputs = 18
  of 1:
    result.kind = FixedResidual
    result.inputs = 31
    result.hidden = 8
    result.outputs = 19
  else:
    fail("Unsupported Richard model version")
  let count = (result.inputs + 1) * result.hidden +
    (result.hidden + 1) * result.outputs
  if bytes.len != 12 + count * 4:
    fail("Invalid Richard model byte length")
  result.weights = newSeq[int32](count)
  for value in result.weights.mitems:
    value = cast[int32](reader.readWord())

proc inferRichard*(model: RichardModel, data: openArray[Fixed]): seq[Fixed] =
  ## Preserves BASIC arithmetic order, wrapping, ReLU and output score bits.
  if data.len != model.inputs:
    fail("Richard input shape mismatch")
  var
    position = 0
    hidden = newSeq[int32](model.hidden)
  result = newSeq[Fixed](model.outputs)
  case model.kind
  of IntegerCombat:
    var inputs = newSeq[int32](data.len)
    for i, value in data:
      if (int32(value) and 65535) != 0:
        fail("Richard combat inputs must be integers")
      inputs[i] = int32(value) div 65536
    for row in 0 ..< model.hidden:
      var sum = model.weights[position]
      inc position
      for value in inputs:
        sum = sum +% (value *% model.weights[position])
        inc position
      hidden[row] = max(0'i32, sum)
    for row in 0 ..< model.outputs:
      var sum = model.weights[position]
      inc position
      for value in hidden:
        sum = sum +% (value *% model.weights[position])
        inc position
      result[row] = Fixed(sum)
  of FixedResidual:
    try:
      for row in 0 ..< model.hidden:
        var sum = Fixed(model.weights[position])
        inc position
        for value in data:
          sum = sum + value / fixed(100) * Fixed(model.weights[position])
          inc position
        hidden[row] = int32(max(FixedZero, sum))
      for row in 0 ..< model.outputs:
        var sum = Fixed(model.weights[position])
        inc position
        for value in hidden:
          sum = sum + Fixed(value) * Fixed(model.weights[position])
          inc position
        result[row] = sum
    except AssertionDefect as error:
      fail("Richard fixed-point overflow: " & error.msg)

proc richardRunner*(context: NeuralContext): ContextHostProc =
  ## Binds immutable Richard models to one policy VM without hidden state.
  var models: seq[CachedModel]
  result = proc(runtime: Runtime, arguments: openArray[Value]): Value =
    ## Implements nn_richard with the shared three-argument boundary.
    let path = runtime.getString(arguments[0])
    var index = -1
    for i, cached in models:
      if cached.path == path:
        index = i
        break
    if index < 0:
      let
        bytes = context.modelBytes(runtime, path)
        retained = int64(bytes.len + path.len) + 256
      runtime.reserveNativeMemory(retained)
      try:
        models.add CachedModel(path: path, model: loadRichard(bytes))
      except NeuralError:
        runtime.releaseNativeMemory(retained)
        raise
      index = models.high
    let
      model = addr models[index].model
      binding = "richard:" & path
      previous = runtime.checkState(arguments[1], binding)
    if previous.len != 0:
      fail("Richard networks require empty state")
    runtime.reserveNativeMemory(4096)
    defer:
      runtime.releaseNativeMemory(4096)
    let outputs = inferRichard(
      model[], runtime.inputValues(arguments[2], model.inputs)
    )
    runtime.commit(arguments[1], binding, "", outputs)
