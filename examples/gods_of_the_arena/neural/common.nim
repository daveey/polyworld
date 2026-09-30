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
    auxSizes: seq[int]
    auxLogits: seq[Fixed]
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

proc publishAux*(
    context: NeuralContext,
    sizes: openArray[int],
    logits: openArray[Fixed]
) =
  ## Replaces the auxiliary logits of the most recent committed call.
  context.auxSizes = @sizes
  context.auxLogits = @logits

proc auxHead(
    context: NeuralContext,
    runtime: Runtime,
    head: Value
): tuple[offset, size: int] =
  ## Locates one auxiliary head of the most recent committed call.
  let index = int(head.asInt)
  if index < 0 or index >= context.auxSizes.len:
    fail("Auxiliary head " & $index & " is not in the most recent model, " &
      "which has " & $context.auxSizes.len)
  for i in 0 ..< index:
    result.offset += context.auxSizes[i]
  result.size = context.auxSizes[index]

proc addAuxFunctions*(host: var Host, context: NeuralContext) =
  ## Reads optional auxiliary heads of the most recent committed neural call.
  let
    count = proc(runtime: Runtime, arguments: openArray[Value]): Value =
      ## Returns the number of auxiliary heads; zero without any.
      toValue(int32(context.auxSizes.len))
    size = proc(runtime: Runtime, arguments: openArray[Value]): Value =
      ## Returns the number of logits in one auxiliary head.
      toValue(int32(context.auxHead(runtime, arguments[0]).size))
    logit = proc(runtime: Runtime, arguments: openArray[Value]): Value =
      ## Returns one Q16.16 auxiliary logit.
      let
        head = context.auxHead(runtime, arguments[0])
        index = int(arguments[1].asInt)
      if index < 0 or index >= head.size:
        fail("Auxiliary logit " & $index & " is outside a head of " &
          $head.size)
      toValue(context.auxLogits[head.offset + index])
    argmax = proc(runtime: Runtime, arguments: openArray[Value]): Value =
      ## Returns the first index of the largest Q16.16 auxiliary logit.
      let head = context.auxHead(runtime, arguments[0])
      var best = 0
      for i in 1 ..< head.size:
        if context.auxLogits[head.offset + i] >
          context.auxLogits[head.offset + best]:
            best = i
      toValue(int32(best))
  discard host.addFunction("nn_aux_count", 0, count, 1)
  discard host.addFunction("nn_aux_size", 1, size, 1)
  discard host.addFunction("nn_aux", 2, logit, 1)
  discard host.addFunction("nn_aux_argmax", 1, argmax, 1)

proc addNeuralFunctions*(
    host: var Host,
    richard, david, andre, fly: ContextHostProc,
    context: NeuralContext = nil
) =
  ## Registers reviewed architectures through ordinary host-call bytecode.
  ## With a context, also registers the auxiliary head readers.
  host.addBufferFunctions()
  discard host.addFunction("nn_richard", 3, richard, 1)
  discard host.addFunction("nn_david", 3, david, 1)
  discard host.addFunction("andre_nn", 3, andre, 1)
  discard host.addFunction("fly_nn", 3, fly, 1)
  if context != nil:
    host.addAuxFunctions(context)
