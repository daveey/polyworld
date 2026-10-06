import
  std/[math, strutils],
  bassy, fixxy, jsony,
  policies

when defined(vcc):
  {.localPassC: "/fp:strict".}
else:
  {.localPassC: "-ffp-contract=off".}

const
  TensorMagic = "PWTENS01"
  TensorRanks = 8
  TensorElements = 4 * 1024 * 1024
  WorkScale = 256'i64

type
  TensorError* = object of BasicError
  TensorDtype* = enum
    Int32Tensor, FixedTensor, Float32Tensor
  Tensor* = object
    dtype*: TensorDtype
    shape*: array[TensorRanks, int]
    rank*, count*: int
    immutable*: bool
    data: ptr UncheckedArray[byte]
  TensorEntry = object
    name, dtype, resource: string
    shape: seq[int]
    offset: int64
  TensorManifest = object
    tensors: seq[TensorEntry]
  TensorContext = ref object
    policy: Policy
    entries: seq[TensorEntry]
    loaded, charged: bool
  BinaryOperation = enum
    AddOperation, SubtractOperation, MultiplyOperation, DivideOperation
  UnaryOperation = enum
    ReluOperation, SigmoidOperation, SigmoidDirectOperation, ExpOperation,
    TanhOperation, AbsOperation

proc fail(message: string) {.noreturn, raises: [TensorError].} =
  ## Reports tensor failures through the ordinary BASIC boundary.
  raise newException(TensorError, "Tensor: " & message)

proc dtype(name: string): TensorDtype =
  ## Resolves an explicit four-byte element representation.
  case name
  of "int32":
    Int32Tensor
  of "fixed":
    FixedTensor
  of "float32":
    Float32Tensor
  else:
    fail("dtype must be int32, fixed or float32")

proc finite(value: float32): bool {.inline.} =
  ## Rejects nonfinite values at every floating tensor write boundary.
  classify(value) notin {fcNan, fcInf, fcNegInf}

{.push overflowChecks: off.}

proc word(data: ptr UncheckedArray[byte], i: int): int32 {.inline, raises: [].} =
  ## Reads a little-endian word without assuming pointer alignment.
  var raw: uint32
  copyMem(addr raw, addr data[i * 4], 4)
  when cpuEndian == bigEndian:
    raw = (raw shr 24) or ((raw shr 8) and 0xff00) or
      ((raw shl 8) and 0xff0000) or (raw shl 24)
  cast[int32](raw)

{.pop.}

proc number(tensor: Tensor, i: int): int32 {.inline, raises: [].} =
  ## Reads one previously validated packed element.
  word(tensor.data, i)

proc floating(tensor: Tensor, i: int): float32 {.inline, raises: [].} =
  ## Reads one floating element without converting it through BASIC.
  cast[float32](tensor.number(i))

{.push overflowChecks: off.}

proc writeWord(bytes: var string, offset: int, raw: int32)
    {.inline, raises: [].} =
  ## Writes a portable word without native object serialization.
  let value = cast[uint32](raw)
  for i in 0 ..< 4:
    bytes[offset + i] = char((value shr (8 * i)) and 255)

{.pop.}

proc dimensions(kind: TensorDtype, shape: openArray[int]): Tensor =
  ## Bounds rank and element products before allocating any payload.
  if shape.len < 1 or shape.len > TensorRanks:
    fail("rank must be between 1 and 8")
  result.dtype = kind
  result.rank = shape.len
  result.count = 1
  for i, size in shape:
    if size < 0 or size > TensorElements or
      (result.count > 0 and size > TensorElements div result.count):
        fail("shape must contain nonnegative dimensions within 4194304 elements")
    result.shape[i] = size
    result.count *= size

proc tensorView*(runtime: Runtime, value: Value): Tensor =
  ## Borrows a checked tensor only until the next buffer mutation.
  let view = runtime.borrowBlob(value)
  if view.len < 16:
    fail("invalid tensor handle")
  for i, c in TensorMagic:
    if view.data[i] != byte(c):
      fail("invalid tensor header")
  if view.data[8] > byte(ord(high(TensorDtype))) or
    view.data[9] < 1 or view.data[9] > TensorRanks or
    view.data[10] > 1 or view.data[11] != 0:
      fail("invalid tensor metadata")
  let
    rank = int(view.data[9])
    header = 12 + rank * 4
  if view.len < header:
    fail("truncated tensor shape")
  var shape: array[TensorRanks, int]
  for i in 0 ..< rank:
    shape[i] = int(word(view.data, 3 + i))
  result = dimensions(TensorDtype(view.data[8]), shape.toOpenArray(0, rank - 1))
  if view.len != header + result.count * 4:
    fail("tensor byte length does not match its shape")
  result.immutable = view.data[10] == 1
  result.data = cast[ptr UncheckedArray[byte]](addr view.data[header])

proc writable(tensor: Tensor) =
  ## Prevents loaded weights from becoming operation destinations.
  if tensor.immutable:
    fail("loaded weights are immutable; copy them into a scratch tensor")

proc sameCount(a, b: Tensor) =
  ## Requires two tensors to contain the same number of elements.
  if a.count != b.count:
    fail("element count mismatch")

proc sameType(a, b: Tensor) =
  ## Prevents implicit conversions between arithmetic representations.
  if a.dtype != b.dtype:
    fail("dtype mismatch; use tensorConvert explicitly")

proc sameShape(a, b: Tensor) =
  ## Requires matching dtype and complete shape for elementwise operations.
  sameType(a, b)
  if a.rank != b.rank or a.shape != b.shape:
    fail("shape mismatch")

proc broadcast(tensor, output: Tensor) =
  ## Supports a one-element scalar or an exactly matching tensor.
  sameType(tensor, output)
  if tensor.count != 1:
    sameShape(tensor, output)

proc meter(runtime: Runtime, operations: int64) =
  ## Charges bulk arithmetic separately from BASIC instruction execution.
  runtime.chargeWork((operations + WorkScale - 1) div WorkScale)

proc payload(runtime: Runtime, tensor: Tensor): string =
  ## Reserves transactional scratch space before allocating an output.
  runtime.checkNativeMemory(int64(12 + tensor.rank * 4 + tensor.count * 4))
  result = newString(12 + tensor.rank * 4 + tensor.count * 4)
  for i, c in TensorMagic:
    result[i] = c
  result[8] = char(ord(tensor.dtype))
  result[9] = char(tensor.rank)
  result[10] = char(ord(tensor.immutable))
  for i in 0 ..< tensor.rank:
    result.writeWord(12 + i * 4, int32(tensor.shape[i]))

{.push overflowChecks: off.}

proc store(bytes: var string, tensor: Tensor, i: int, raw: int32)
    {.inline, raises: [].} =
  ## Writes one element into unpublished transactional scratch storage.
  bytes.writeWord(12 + tensor.rank * 4 + i * 4, raw)

{.pop.}

proc storeFloat(bytes: var string, tensor: Tensor, i: int, value: float32)
    {.inline.} =
  ## Rejects a nonfinite intermediate before publishing any destination.
  if not value.finite:
    fail("nonfinite float32 result")
  bytes.store(tensor, i, cast[int32](value))

proc create(runtime: Runtime, tensor: Tensor, bytes: string): Value =
  ## Creates a new owned tensor after checking its buffer bookkeeping.
  runtime.checkNativeMemory(int64(bytes.len) + 128)
  result = runtime.createBlob()
  runtime.putBlob(result, bytes, "tensor")

proc shapeValues(runtime: Runtime, value: Value): seq[int] =
  ## Reads a small BASIC shape array with exact integral dimensions.
  let view = runtime.arrayView(value)
  if view.len < 1 or view.len > TensorRanks:
    fail("shape array needs 1..8 dimensions")
  for i in 0 ..< view.len:
    if view[i].kind != IntegerValue:
      fail("shape dimensions must be integers")
    result.add int(view[i].asInt)

proc tensorCreate(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Allocates a zero-filled mutable tensor with an explicit shape.
  let tensor = dimensions(
    dtype(runtime.getString(arguments[0])),
    shapeValues(runtime, arguments[1])
  )
  runtime.meter(int64(tensor.count))
  let bytes = runtime.payload(tensor)
  runtime.create(tensor, bytes)

proc toFixed(value: float32): int32 =
  ## Rounds floating exports to Q16.16 with ties away from zero.
  if not value.finite:
    fail("nonfinite float32 conversion")
  let rounded = round(float64(value) * 65536.0)
  if rounded < float64(low(int32)) or rounded > float64(high(int32)):
    fail("value is outside Q16.16")
  int32(rounded)

proc scalarRaw(kind: TensorDtype, text: string): int32 =
  ## Parses constants without routing float32 through fixed BASIC literals.
  try:
    case kind
    of Int32Tensor:
      let value = parseBiggestInt(text)
      if value < int64(low(int32)) or value > int64(high(int32)):
        fail("scalar is outside int32")
      int32(value)
    of FixedTensor:
      int32(parseFixed(text))
    of Float32Tensor:
      let value = float32(parseFloat(text))
      if not value.finite:
        fail("nonfinite float32 scalar")
      cast[int32](value)
  except ValueError as error:
    fail("invalid scalar: " & error.msg)

proc tensorScalar(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Allocates one precisely represented constant from decimal text.
  let tensor = dimensions(dtype(runtime.getString(arguments[0])), [1])
  let raw = scalarRaw(tensor.dtype, runtime.getString(arguments[1]))
  var bytes = runtime.payload(tensor)
  bytes.store(tensor, 0, raw)
  runtime.create(tensor, bytes)

proc loadManifest(context: TensorContext, runtime: Runtime) =
  ## Validates the complete package tensor directory once per policy VM.
  if context.loaded:
    return
  if context.policy == nil:
    fail("tensorLoad requires a ZIP policy")
  try:
    let bytes = context.policy.resource("tensors.json")
    if bytes.len > 64 * 1024:
      fail("tensors.json exceeds 64 KiB")
    runtime.meter(int64(bytes.len) + int64(context.policy.files.len * 256))
    let manifest = bytes.fromJson(TensorManifest)
    if manifest.tensors.len < 1 or manifest.tensors.len > 256:
      fail("manifest needs 1..256 named tensors")
    var names: seq[string]
    for entry in manifest.tensors:
      if entry.name.len < 1 or entry.name.len > 128 or entry.name in names:
        fail("tensor names must be nonempty and unique")
      names.add entry.name
      let
        tensor = dimensions(dtype(entry.dtype), entry.shape)
        resource = context.policy.resource(entry.resource)
      if entry.offset < 0 or entry.offset > int64(resource.len) or
        int64(tensor.count) * 4 > int64(resource.len) - entry.offset:
          fail("tensor resource range is outside " & entry.resource)
    runtime.checkNativeMemory(int64(bytes.len * 4 + 4096))
    if not context.charged:
      runtime.reserveNativeMemory(
        context.policy.memoryBytes + int64(bytes.len * 4 + 4096)
      )
      context.charged = true
    context.entries = manifest.tensors
    context.loaded = true
  except PolicyError, JsonError:
    fail("invalid tensors.json: " & getCurrentExceptionMsg())

proc loadTensor(context: TensorContext): ContextHostProc =
  ## Binds immutable named tensor loading to one policy package.
  result = proc(runtime: Runtime, arguments: openArray[Value]): Value =
    ## Copies a validated resource slice into VM-owned packed storage.
    context.loadManifest(runtime)
    let name = runtime.getString(arguments[0])
    for entry in context.entries:
      if entry.name == name:
        var tensor = dimensions(dtype(entry.dtype), entry.shape)
        tensor.immutable = true
        runtime.meter(int64(tensor.count))
        var bytes = runtime.payload(tensor)
        let resource = context.policy.resource(entry.resource)
        if tensor.count > 0:
          copyMem(
            addr bytes[12 + tensor.rank * 4],
            unsafeAddr resource[int(entry.offset)],
            tensor.count * 4
          )
        if tensor.dtype == Float32Tensor:
          let data = cast[ptr UncheckedArray[byte]](
            addr bytes[12 + tensor.rank * 4]
          )
          for i in 0 ..< tensor.count:
            if not cast[float32](word(data, i)).finite:
              fail("nonfinite loaded weight: " & name)
        return runtime.create(tensor, bytes)
    fail("missing named tensor: " & name)

proc converted(raw: int32, source, destination: TensorDtype): int32 =
  ## Performs an explicit checked conversion between element dtypes.
  if source == destination:
    return raw
  case destination
  of Float32Tensor:
    let value =
      if source == FixedTensor:
        float32(raw) / 65536.0'f
      else:
        float32(raw)
    cast[int32](value)
  of FixedTensor:
    if source == Float32Tensor:
      return toFixed(cast[float32](raw))
    if raw < -32768 or raw > 32767:
      fail("int32 conversion is outside Q16.16")
    raw *% 65536'i32
  of Int32Tensor:
    if source == FixedTensor:
      if (raw and 65535) != 0:
        fail("int32 conversion requires integral values")
      return raw div 65536
    let value = cast[float32](raw)
    if not value.finite or float64(value) < float64(low(int32)) or
      float64(value) > float64(high(int32)) or trunc(value) != value:
        fail("int32 conversion requires integral values in range")
    int32(value)

proc tensorImport(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Copies observations from an exact BASIC numeric array shape.
  let
    output = runtime.tensorView(arguments[0])
    input = runtime.arrayView(arguments[1])
  output.writable()
  if input.len != output.count:
    fail("array import count mismatch")
  runtime.meter(int64(output.count))
  var bytes = runtime.payload(output)
  for i in 0 ..< output.count:
    let value = input[i]
    if value.kind notin {IntegerValue, FixedValue}:
      fail("tensor imports require numeric BASIC values")
    let
      source = if value.kind == IntegerValue: Int32Tensor else: FixedTensor
      raw = if value.kind == IntegerValue: value.asInt else: int32(value.asFixed)
    bytes.store(output, i, converted(raw, source, output.dtype))
  runtime.putBlob(arguments[0], bytes, "tensor")
  arguments[0]

proc tensorExport(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Converts only final outputs into ordinary BASIC numeric values.
  let input = runtime.tensorView(arguments[0])
  runtime.meter(int64(input.count))
  runtime.checkNativeMemory(int64(input.count) * 32 + 128)
  var values = newSeq[Value](input.count)
  for i in 0 ..< input.count:
    let raw = input.number(i)
    values[i] =
      case input.dtype
      of Int32Tensor:
        toValue(raw)
      of FixedTensor:
        toValue(Fixed(raw))
      of Float32Tensor:
        toValue(Fixed(toFixed(cast[float32](raw))))
  runtime.putArray(values)

proc copyTensor(runtime: Runtime, arguments: openArray[Value],
    convert, reinterpret: bool): Value =
  ## Copies or explicitly converts a full tensor into a reusable output.
  let
    input = runtime.tensorView(arguments[0])
    output = runtime.tensorView(arguments[1])
  output.writable()
  sameCount(input, output)
  if not convert and not reinterpret:
    sameType(input, output)
  runtime.meter(int64(input.count))
  var bytes = runtime.payload(output)
  for i in 0 ..< input.count:
    let raw =
      if convert:
        converted(input.number(i), input.dtype, output.dtype)
      else:
        input.number(i)
    if output.dtype == Float32Tensor and not cast[float32](raw).finite:
      fail("nonfinite reinterpretation")
    bytes.store(output, i, raw)
  runtime.putBlob(arguments[1], bytes, "tensor")
  arguments[1]

proc fillTensor(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Fills mutable storage with one scalar of its own dtype.
  let
    output = runtime.tensorView(arguments[0])
    scalar = runtime.tensorView(arguments[1])
  output.writable()
  sameType(output, scalar)
  if scalar.count != 1:
    fail("fill needs a one-element tensor")
  runtime.meter(int64(output.count))
  var bytes = runtime.payload(output)
  for i in 0 ..< output.count:
    bytes.store(output, i, scalar.number(0))
  runtime.putBlob(arguments[0], bytes, "tensor")
  arguments[0]

proc integerOperation(a, b: int32, kind: TensorDtype,
    operation: BinaryOperation): int32 {.inline.} =
  ## Preserves wrapping integer and Fixxy arithmetic rules.
  case operation
  of AddOperation:
    a +% b
  of SubtractOperation:
    a -% b
  of MultiplyOperation:
    if kind == FixedTensor:
      int32(Fixed(a) * Fixed(b))
    else:
      a *% b
  of DivideOperation:
    if b == 0:
      fail("division by zero")
    if kind == FixedTensor:
      int32(Fixed(a) / Fixed(b))
    else:
      cast[int32](uint32((int64(a) div int64(b)) and 0xffffffff'i64))

proc binaryTensor(operation: BinaryOperation): ContextHostProc =
  ## Builds one explicitly selected elementwise arithmetic callback.
  result = proc(runtime: Runtime, arguments: openArray[Value]): Value =
    ## Executes scalar broadcasting after validating all operand shapes.
    let
      a = runtime.tensorView(arguments[0])
      b = runtime.tensorView(arguments[1])
      output = runtime.tensorView(arguments[2])
    output.writable()
    broadcast(a, output)
    broadcast(b, output)
    runtime.meter(int64(output.count))
    var bytes = runtime.payload(output)
    for i in 0 ..< output.count:
      let
        ai = if a.count == 1: 0 else: i
        bi = if b.count == 1: 0 else: i
      if output.dtype == Float32Tensor:
        let
          av = a.floating(ai)
          bv = b.floating(bi)
        var value: float32
        case operation
        of AddOperation:
          value = av + bv
        of SubtractOperation:
          value = av - bv
        of MultiplyOperation:
          value = av * bv
        of DivideOperation:
          if bv == 0:
            fail("division by zero")
          value = av / bv
        bytes.storeFloat(output, i, value)
      else:
        bytes.store(output, i,
          integerOperation(a.number(ai), b.number(bi), output.dtype, operation))
    runtime.putBlob(arguments[2], bytes, "tensor")
    arguments[2]

proc fixedExp(raw: int32): int32 =
  ## Approximates exp with integer range reduction and twelve Taylor terms.
  if raw < -12 * 65536:
    return 0
  if raw > 10 * 65536:
    fail("fixed exp result exceeds Q16.16")
  # The Q30 residual lies within half of ln(2).
  const Ln2 = 744261118'i64
  let
    x = int64(raw) * 16384
    exponent = (x + (if x >= 0: Ln2 div 2 else: -Ln2 div 2)) div Ln2
    residual = x - exponent * Ln2
  var
    term = 1'i64 shl 30
    sum = term
  for i in 1 .. 12:
    term = ((term * residual) div (1'i64 shl 30)) div int64(i)
    sum += term
  if exponent >= 0:
    sum = sum shl int(exponent)
  else:
    sum = sum shr int(-exponent)
  let value = (sum + 8192) shr 14
  if value > int64(high(int32)):
    fail("fixed exp result exceeds Q16.16")
  int32(value)

proc fixedSigmoid(raw: int32): int32 =
  ## Evaluates a stable integer sigmoid without floating point arithmetic.
  let magnitude = min(abs(int64(raw)), 12'i64 * 65536)
  let exponential = int64(fixedExp(-int32(magnitude)))
  let positive = (65536'i64 * 65536) div (65536 + exponential)
  int32(if raw >= 0: positive else: 65536 - positive)

{.push floatChecks: off.}

proc floatingUnary(value: float32, operation: UnaryOperation): float32 =
  ## Keeps nonlinear computation in float32 without fixed scalar conversion.
  case operation
  of ReluOperation:
    max(0.0'f, value)
  of AbsOperation:
    abs(value)
  of ExpOperation:
    exp(value)
  of SigmoidOperation:
    let e = exp(-abs(value))
    if value >= 0: 1.0'f / (1.0'f + e) else: e / (1.0'f + e)
  of SigmoidDirectOperation:
    1.0'f / (1.0'f + exp(-value))
  of TanhOperation:
    # This formula matches the existing rate network for nonnegative inputs.
    let magnitude = abs(value)
    let rate = 1.0'f - 2.0'f / (exp(2.0'f * magnitude) + 1.0'f)
    if value >= 0: rate else: -rate

{.pop.}

proc unaryTensor(operation: UnaryOperation): ContextHostProc =
  ## Selects one generic activation or absolute-value kernel.
  result = proc(runtime: Runtime, arguments: openArray[Value]): Value =
    ## Applies an activation transactionally with exact matching shapes.
    let
      input = runtime.tensorView(arguments[0])
      output = runtime.tensorView(arguments[1])
    output.writable()
    sameShape(input, output)
    if input.dtype == Int32Tensor and operation notin {ReluOperation, AbsOperation}:
        fail("nonlinear functions require fixed or float32 tensors")
    runtime.meter(int64(input.count) * (if operation in {ReluOperation,
        AbsOperation}: 1 else: 32))
    var bytes = runtime.payload(output)
    for i in 0 ..< input.count:
      if input.dtype == Float32Tensor:
        bytes.storeFloat(output, i, floatingUnary(input.floating(i), operation))
      else:
        let raw = input.number(i)
        var value: int32
        case operation
        of ReluOperation:
          value = max(0'i32, raw)
        of AbsOperation:
          if raw == low(int32):
            fail("absolute value exceeds int32")
          value = abs(raw)
        of ExpOperation:
          value = fixedExp(raw)
        of SigmoidOperation, SigmoidDirectOperation:
          value = fixedSigmoid(raw)
        of TanhOperation:
          if raw >= 6 * 65536:
            value = 65536
          elif raw <= -6 * 65536:
            value = -65536
          else:
            value = 2 * fixedSigmoid(raw * 2) - 65536
        bytes.store(output, i, value)
    runtime.putBlob(arguments[1], bytes, "tensor")
    arguments[1]

proc sameHandle(a, b: Value): bool =
  ## Compares buffer identities without BASIC numeric equality coercion.
  a.kind == b.kind and a.bufferOwner == b.bufferOwner and
    a.bufferSlot == b.bufferSlot

{.push overflowChecks: off.}

proc tensorDense(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Computes ordered row-major affine products with optional bias first.
  let
    input = runtime.tensorView(arguments[0])
    weights = runtime.tensorView(arguments[1])
    output = runtime.tensorView(arguments[3])
    biased = arguments[2].kind == BlobValue
  output.writable()
  sameType(input, weights)
  sameType(input, output)
  if input.rank != 1 or weights.rank != 2 or output.rank != 1 or
    weights.shape[1] != input.count or weights.shape[0] != output.count:
      fail("dense needs vector input, [outputs,inputs] weights and vector output")
  if sameHandle(arguments[0], arguments[3]) or
    sameHandle(arguments[1], arguments[3]):
      fail("dense output must not alias input or weights")
  var bias: Tensor
  if biased:
    bias = runtime.tensorView(arguments[2])
    sameShape(bias, output)
  elif arguments[2].kind != IntegerValue or arguments[2].asInt != 0:
    fail("dense bias must be a tensor or integer zero")
  runtime.meter(int64(weights.count) * 2 + int64(output.count))
  var bytes = runtime.payload(output)
  for row in 0 ..< output.count:
    if output.dtype == Float32Tensor:
      var sum = if biased: bias.floating(row) else: 0.0'f
      for i in 0 ..< input.count:
        let product = input.floating(i) * weights.floating(row * input.count + i)
        sum = sum + product
      bytes.storeFloat(output, row, sum)
    else:
      var sum = if biased: bias.number(row) else: 0'i32
      for i in 0 ..< input.count:
        let product = integerOperation(input.number(i), weights.number(row *
            input.count + i), output.dtype, MultiplyOperation)
        sum = sum +% product
      bytes.store(output, row, sum)
  runtime.putBlob(arguments[3], bytes, "tensor")
  arguments[3]

{.pop.}

{.push overflowChecks: off.}

proc tensorCsr(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Computes ordered target-row sparse matrix-vector products.
  let
    input = runtime.tensorView(arguments[0])
    offsets = runtime.tensorView(arguments[1])
    sources = runtime.tensorView(arguments[2])
    weights = runtime.tensorView(arguments[3])
    output = runtime.tensorView(arguments[4])
  output.writable()
  sameType(input, weights)
  sameType(input, output)
  if input.rank != 1 or output.rank != 1 or offsets.rank != 1 or
    sources.rank != 1 or weights.rank != 1 or
    offsets.dtype != Int32Tensor or sources.dtype != Int32Tensor or
    offsets.count != output.count + 1 or sources.count != weights.count:
      fail("invalid CSR tensor shapes or index dtype")
  for i in 0 ..< 4:
    if sameHandle(arguments[i], arguments[4]):
      fail("CSR output must not alias an input")
  runtime.meter(int64(weights.count) * 3 + int64(offsets.count))
  var previous = 0'i32
  for i in 0 ..< offsets.count:
    let offset = offsets.number(i)
    if offset < previous or offset > int32(weights.count):
      fail("CSR offsets must be ordered and bounded")
    previous = offset
  if offsets.number(0) != 0 or previous != weights.count:
    fail("CSR offsets must cover all weights")
  for i in 0 ..< sources.count:
    if sources.number(i) < 0 or sources.number(i) >= input.count:
      fail("CSR source index out of bounds")
  var bytes = runtime.payload(output)
  for row in 0 ..< output.count:
    if output.dtype == Float32Tensor:
      var sum = 0.0'f
      for edge in int(offsets.number(row)) ..< int(offsets.number(row + 1)):
        let product = input.floating(int(sources.number(edge))) *
            weights.floating(edge)
        sum = sum + product
      bytes.storeFloat(output, row, sum)
    else:
      var sum = 0'i32
      for edge in int(offsets.number(row)) ..< int(offsets.number(row + 1)):
        let product = integerOperation(input.number(int(sources.number(edge))),
            weights.number(edge), output.dtype, MultiplyOperation)
        sum = sum +% product
      bytes.store(output, row, sum)
  runtime.putBlob(arguments[4], bytes, "tensor")
  arguments[4]

{.pop.}

proc tensorCompare(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Produces integer masks from explicitly selected element comparisons.
  let
    a = runtime.tensorView(arguments[0])
    b = runtime.tensorView(arguments[1])
    operation = runtime.getString(arguments[2])
    output = runtime.tensorView(arguments[3])
  output.writable()
  sameType(a, b)
  if output.dtype != Int32Tensor:
    fail("comparison output must be int32")
  if operation notin ["lt", "le", "eq", "ne", "ge", "gt"]:
    fail("comparison must be lt, le, eq, ne, ge or gt")
  for operand in [a, b]:
    if operand.count != 1 and
      (operand.rank != output.rank or operand.shape != output.shape):
        fail("comparison broadcast shape mismatch")
  runtime.meter(int64(output.count))
  var bytes = runtime.payload(output)
  for i in 0 ..< output.count:
    let
      ai = if a.count == 1: 0 else: i
      bi = if b.count == 1: 0 else: i
      order =
        if a.dtype == Float32Tensor:
          cmp(a.floating(ai), b.floating(bi))
        else:
          cmp(a.number(ai), b.number(bi))
    let matches =
      case operation
      of "lt":
        order < 0
      of "le":
        order <= 0
      of "eq":
        order == 0
      of "ne":
        order != 0
      of "ge":
        order >= 0
      else:
        order > 0
    bytes.store(output, i, int32(matches))
  runtime.putBlob(arguments[3], bytes, "tensor")
  arguments[3]

proc tensorSelect(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Selects values from an integer mask without leaking scalar floats.
  let
    mask = runtime.tensorView(arguments[0])
    a = runtime.tensorView(arguments[1])
    b = runtime.tensorView(arguments[2])
    output = runtime.tensorView(arguments[3])
  output.writable()
  broadcast(a, output)
  broadcast(b, output)
  if mask.dtype != Int32Tensor or mask.rank != output.rank or mask.shape != output.shape:
    fail("selection needs an int32 mask matching the output shape")
  runtime.meter(int64(output.count))
  var bytes = runtime.payload(output)
  for i in 0 ..< output.count:
    let source = if mask.number(i) != 0: a else: b
    bytes.store(output, i, source.number(if source.count == 1: 0 else: i))
  runtime.putBlob(arguments[3], bytes, "tensor")
  arguments[3]

proc tensorLerp(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Uses a stable two-branch interpolation for generic recurrent updates.
  let
    a = runtime.tensorView(arguments[0])
    b = runtime.tensorView(arguments[1])
    weight = runtime.tensorView(arguments[2])
    output = runtime.tensorView(arguments[3])
  output.writable()
  sameShape(a, output)
  sameShape(b, output)
  broadcast(weight, output)
  runtime.meter(int64(output.count) * 5)
  var bytes = runtime.payload(output)
  for i in 0 ..< output.count:
    let wi = if weight.count == 1: 0 else: i
    if output.dtype == Float32Tensor:
      let
        av = a.floating(i)
        bv = b.floating(i)
        w = weight.floating(wi)
        delta = bv - av
        value = if abs(w) < 0.5'f: av + w * delta else: bv - delta * (1.0'f - w)
      bytes.storeFloat(output, i, value)
    else:
      let
        av = a.number(i)
        bv = b.number(i)
        w = weight.number(wi)
        delta = bv -% av
        one = if output.dtype == FixedTensor: 65536'i32 else: 1'i32
        value = if abs(int64(w)) * 2 < one:
          av +% integerOperation(w, delta, output.dtype, MultiplyOperation)
        else:
          bv -% integerOperation(delta, one -% w, output.dtype, MultiplyOperation)
      bytes.store(output, i, value)
  runtime.putBlob(arguments[3], bytes, "tensor")
  arguments[3]

proc copySlice(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Copies a flat range while preserving every other destination element.
  let
    input = runtime.tensorView(arguments[0])
    start = int(arguments[1].asInt)
    output = runtime.tensorView(arguments[2])
    offset = int(arguments[3].asInt)
    count = int(arguments[4].asInt)
  output.writable()
  sameType(input, output)
  if start < 0 or offset < 0 or count < 0 or start > input.count - count or
      offset > output.count - count:
      fail("slice range out of bounds")
  runtime.meter(int64(output.count + count))
  var bytes = runtime.payload(output)
  for i in 0 ..< output.count:
    bytes.store(output, i, output.number(i))
  for i in 0 ..< count:
    bytes.store(output, offset + i, input.number(start + i))
  runtime.putBlob(arguments[2], bytes, "tensor")
  arguments[2]

proc tensorSlice(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Copies a flat slice into an exact reusable vector destination.
  let output = runtime.tensorView(arguments[3])
  if output.rank != 1 or output.count != int(arguments[2].asInt):
    fail("slice destination shape mismatch")
  runtime.copySlice([arguments[0], arguments[1], arguments[3], toValue(0),
      arguments[2]])

proc tensorReshape(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Copies values with explicit new dimensions and unchanged dtype.
  let
    input = runtime.tensorView(arguments[0])
    output = runtime.tensorView(arguments[2])
    shape = dimensions(input.dtype, runtime.shapeValues(arguments[1]))
  sameShape(shape, output)
  runtime.copyTensor([arguments[0], arguments[2]], false, false)

proc indexedTensor(scatter: bool): ContextHostProc =
  ## Selects gather or ordered scatter-add with checked integer indices.
  result = proc(runtime: Runtime, arguments: openArray[Value]): Value =
    ## Validates all indices before committing any gathered or scattered value.
    let
      input = runtime.tensorView(arguments[0])
      indices = runtime.tensorView(arguments[1])
      output = runtime.tensorView(arguments[2])
    output.writable()
    sameType(input, output)
    if indices.dtype != Int32Tensor or indices.rank != 1 or input.rank != 1 or
        output.rank != 1:
        fail("gather/scatter requires vectors and int32 indices")
    if indices.count != (if scatter: input.count else: output.count):
      fail("index count mismatch")
    runtime.meter(int64(indices.count * 2 + output.count))
    for i in 0 ..< indices.count:
      let index = indices.number(i)
      if index < 0 or index >= (if scatter: output.count else: input.count):
        fail("gather/scatter index out of bounds")
    var bytes = runtime.payload(output)
    if scatter:
      for i in 0 ..< output.count:
        bytes.store(output, i, output.number(i))
      let data = cast[ptr UncheckedArray[byte]](addr bytes[12 + output.rank * 4])
      for i in 0 ..< input.count:
        let
          index = int(indices.number(i))
          previous = word(data, index)
        if output.dtype == Float32Tensor:
          bytes.storeFloat(output, index, cast[float32](previous) +
              input.floating(i))
        else:
          bytes.store(output, index, previous +% input.number(i))
    else:
      for i in 0 ..< output.count:
        bytes.store(output, i, input.number(int(indices.number(i))))
    runtime.putBlob(arguments[2], bytes, "tensor")
    arguments[2]

proc argmaxTensor(masked: bool): ContextHostProc =
  ## Selects the first greatest element and returns minus one for an empty mask.
  result = proc(runtime: Runtime, arguments: openArray[Value]): Value =
    ## Scans native tensor values without first quantizing float32 logits.
    let input = runtime.tensorView(arguments[0])
    var mask: Tensor
    if masked:
      mask = runtime.tensorView(arguments[1])
      sameCount(input, mask)
      if mask.dtype != Int32Tensor:
        fail("argmax mask must be int32")
    runtime.meter(int64(input.count))
    var best = -1
    for i in 0 ..< input.count:
      if masked and mask.number(i) == 0:
        continue
      if best < 0 or (if input.dtype == Float32Tensor: input.floating(i) >
          input.floating(best) else: input.number(i) > input.number(best)):
          best = i
    toValue(best)

proc tensorCopy(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Copies packed data into explicitly owned mutable storage.
  runtime.copyTensor(arguments, false, false)

proc tensorConvert(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Converts numeric values between packed representations.
  runtime.copyTensor(arguments, true, false)

proc tensorReinterpret(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Explicitly preserves raw bits for integer logit formats.
  runtime.copyTensor(arguments, false, true)

proc tensorSize(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Reads a tensor element count without exposing its bytes.
  toValue(runtime.tensorView(arguments[0]).count)

proc tensorDim(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Reads one checked axis size.
  let
    tensor = runtime.tensorView(arguments[0])
    axis = int(arguments[1].asInt)
  if axis < 0 or axis >= tensor.rank:
    fail("dimension axis out of bounds")
  toValue(tensor.shape[axis])

proc tensorDtype(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Returns int32=0, fixed=1 or float32=2.
  toValue(ord(runtime.tensorView(arguments[0]).dtype))

proc addTensorFunctions*(host: var Host, policy: Policy = nil) =
  ## Registers architecture-independent tensor math for one policy VM.
  let context = TensorContext(policy: policy)
  discard host.addFunction("tensorCreate", 2, tensorCreate, 1)
  discard host.addFunction("tensorScalar", 2, tensorScalar, 1)
  discard host.addFunction("tensorLoad", 1, loadTensor(context), 1)
  discard host.addFunction("tensorImport", 2, tensorImport, 1)
  discard host.addFunction("tensorExport", 1, tensorExport, 1)
  discard host.addFunction("tensorFill", 2, fillTensor, 1)
  discard host.addFunction("tensorCopy", 2, tensorCopy, 1)
  discard host.addFunction("tensorConvert", 2, tensorConvert, 1)
  discard host.addFunction("tensorReinterpret", 2, tensorReinterpret, 1)
  for (name, operation) in [("tensorAdd", AddOperation),
    ("tensorSubtract", SubtractOperation), ("tensorMultiply",
        MultiplyOperation),
    ("tensorDivide", DivideOperation)]:
      discard host.addFunction(name, 3, binaryTensor(operation), 1)
  for (name, operation) in [("tensorRelu", ReluOperation),
    ("tensorSigmoid", SigmoidOperation),
    ("tensorSigmoidDirect", SigmoidDirectOperation), ("tensorExp",
        ExpOperation),
    ("tensorTanh", TanhOperation), ("tensorAbs", AbsOperation)]:
      discard host.addFunction(name, 2, unaryTensor(operation), 1)
  discard host.addFunction("tensorDense", 4, tensorDense, 1)
  discard host.addFunction("tensorCsr", 5, tensorCsr, 1)
  discard host.addFunction("tensorCompare", 4, tensorCompare, 1)
  discard host.addFunction("tensorSelect", 4, tensorSelect, 1)
  discard host.addFunction("tensorLerp", 4, tensorLerp, 1)
  discard host.addFunction("tensorSlice", 4, tensorSlice, 1)
  discard host.addFunction("tensorCopySlice", 5, copySlice, 1)
  discard host.addFunction("tensorReshape", 3, tensorReshape, 1)
  discard host.addFunction("tensorGather", 3, indexedTensor(false), 1)
  discard host.addFunction("tensorScatterAdd", 3, indexedTensor(true), 1)
  discard host.addFunction("tensorArgmax", 1, argmaxTensor(false), 1)
  discard host.addFunction("tensorArgmaxMasked", 2, argmaxTensor(true), 1)
  discard host.addFunction("tensorSize", 1, tensorSize, 1)
  discard host.addFunction("tensorDim", 2, tensorDim, 1)
  discard host.addFunction("tensorDtype", 1, tensorDtype, 1)
