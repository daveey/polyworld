import
  std/math,
  bassy,
  polyworld/policies

export policies

const NativeMemoryBytes* = 32'i64 * 1024 * 1024

type
  NeuralError* = object of BasicError
  NeuralContext* = ref object
    policy*: Policy
    charged: bool
  ModelReader* = object
    bytes*: string
    position*: int

proc fail*(message: string) {.noreturn, raises: [NeuralError].} =
  ## Reports a model failure through the ordinary per-player BASIC boundary.
  raise newException(NeuralError, message)

proc readWord*(reader: var ModelReader): uint32 =
  ## Reads a portable little-endian word with explicit bounds checking.
  if reader.position < 0 or reader.position > reader.bytes.len - 4:
    fail("Truncated neural model or state")
  for i in 0 ..< 4:
    result = result or
      (uint32(ord(reader.bytes[reader.position + i])) shl (i * 8))
  reader.position += 4

proc readCount*(reader: var ModelReader, maximum: uint32): int =
  ## Checks model sizes before narrowing to portable native integers.
  let value = reader.readWord()
  if value > maximum:
    fail("Neural model dimension exceeds its limit")
  int(value)

proc addWord*(bytes: var string, value: uint32) =
  ## Appends a portable word without serializing native object layouts.
  for i in 0 ..< 4:
    bytes.add char((value shr (i * 8)) and 255)

proc finite*(value: float32): bool =
  ## Excludes nonfinite model weights, intermediates and returned values.
  classify(value) notin {fcNan, fcInf, fcNegInf}

proc outputFixed*(value: float32): Fixed =
  ## Rounds ties away from zero and rejects values outside Q16.16.
  if not value.finite:
    fail("Nonfinite neural output")
  let rounded = round(float64(value) * 65536.0)
  if rounded < float64(low(int32)) or rounded > float64(high(int32)):
    fail("Neural output is outside Q16.16; scale it inside the architecture")
  Fixed(int32(rounded))

proc inputValues*(runtime: Runtime, value: Value, count: int): seq[Fixed] =
  ## Copies an exact numeric input shape through the Q16.16 boundary.
  let view = runtime.arrayView(value)
  if view.len != count:
    fail("Neural input needs " & $count & " values, got " & $view.len)
  result = newSeq[Fixed](count)
  for i in 0 ..< count:
    result[i] = view[i].asFixed

proc modelBytes*(
    context: NeuralContext,
    runtime: Runtime,
    path: string
): string =
  ## Resolves package bytes and accounts for retained package storage once.
  if context == nil or context.policy == nil:
    fail("Neural weights require a policy ZIP package")
  try:
    result = context.policy.resource(path)
  except PolicyError as error:
    fail(error.msg)
  if not context.charged:
    runtime.reserveNativeMemory(context.policy.memoryBytes)
    context.charged = true

proc checkState*(runtime: Runtime, state: Value, binding: string): string =
  ## Requires explicit reset before reusing state with a different model.
  result = runtime.getBlob(state)
  let current = runtime.blobBinding(state)
  if current.len > 0 and current != binding:
    fail("Neural state belongs to another model; call blobClear first")

proc commit*(
    runtime: Runtime,
    state: Value,
    binding, next: string,
    outputs: openArray[Fixed]
): Value =
  ## Publishes numeric results and state only after their storage fits.
  runtime.checkNativeMemory(
    int64(next.len + binding.len) + int64(outputs.len) * 32 + 256
  )
  var values = newSeq[Value](outputs.len)
  for i in 0 ..< outputs.len:
    values[i] = toValue(outputs[i])
  result = runtime.putArray(values)
  runtime.putBlob(state, next, binding)

proc addNeuralFunctions*(
    host: var Host,
    richard, david, andre: ContextHostProc
) =
  ## Registers reviewed architectures through ordinary host-call bytecode.
  host.addBufferFunctions()
  discard host.addFunction("nn_richard", 3, richard, 1)
  discard host.addFunction("nn_david", 3, david, 1)
  discard host.addFunction("andre_nn", 3, andre, 1)
