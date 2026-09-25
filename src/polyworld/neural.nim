## Deterministic native neural operations for every Polyworld BASIC host.

import bassy

proc count(value: Value): int =
  ## Accepts a positive, exact element count without narrowing first.
  let size = value.asInt
  if size <= 0:
    raise newException(BasicError, "array count must be positive")
  int(size)

proc requireLength(values: ArrayView, size: int) =
  ## Checks a prefix before any kernel runs or output changes.
  if size > values.len:
    raise newException(BasicError, "array is smaller than the requested shape")

proc linear(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Evaluates bias-first, row-major affine rows in BASIC arithmetic order.
  let
    inputs = runtime.arrayView(arguments[0])
    weights = runtime.arrayView(arguments[1])
    biases = runtime.arrayView(arguments[2])
    outputs = runtime.arrayView(arguments[3], writable = true)
    width = count(arguments[4])
    height = count(arguments[5])
    cells = int64(width) * int64(height)
  inputs.requireLength(width)
  biases.requireLength(height)
  outputs.requireLength(height)
  if cells > int64(weights.len):
    raise newException(BasicError, "linear weights do not fit the shape")
  if outputs.overlaps(inputs) or outputs.overlaps(weights) or
    outputs.overlaps(biases):
      raise newException(BasicError, "linear output must use separate storage")
  runtime.chargeOperations(2 * cells + 2 * int64(height))
  for row in 0 ..< height:
    var total = biases[row]
    for column in 0 ..< width:
      total = total + inputs[column] * weights[row * width + column]
    outputs[row] = total
  toValue(0)

proc relu(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Replaces negative values in a mutable prefix with integer zero.
  let
    values = runtime.arrayView(arguments[0], writable = true)
    size = count(arguments[1])
  values.requireLength(size)
  runtime.chargeOperations(2 * int64(size))
  for i in 0 ..< size:
    if values[i] < toValue(0):
      values[i] = toValue(0)
  toValue(0)

proc argmax(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Returns the first index with the greatest value in a numeric prefix.
  let
    values = runtime.arrayView(arguments[0])
    size = count(arguments[1])
  values.requireLength(size)
  runtime.chargeOperations(int64(size))
  var best = 0
  for i in 1 ..< size:
    if values[best] < values[i]:
      best = i
  toValue(best)

proc argmaxMasked(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Returns the first greatest eligible index, or -1 for an empty mask.
  let
    values = runtime.arrayView(arguments[0])
    mask = runtime.arrayView(arguments[1])
    size = count(arguments[2])
  values.requireLength(size)
  mask.requireLength(size)
  runtime.chargeOperations(2 * int64(size))
  var best = -1
  for i in 0 ..< size:
    if not mask[i].asBool:
      continue
    if best < 0 or values[best] < values[i]:
      best = i
  toValue(best)

proc dataAdd(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Adds two numeric prefixes after reserving their work.
  let
    size = count(arguments[3])
    left = runtime.arrayView(arguments[0])
    right = runtime.arrayView(arguments[1])
    outputs = runtime.arrayView(arguments[2], writable = true)
  left.requireLength(size)
  right.requireLength(size)
  outputs.requireLength(size)
  runtime.chargeOperations(int64(size))
  for i in 0 ..< size:
    outputs[i] = left[i] + right[i]
  toValue(0)

proc dataMultiply(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Multiplies two numeric prefixes after reserving their work.
  let
    size = count(arguments[3])
    left = runtime.arrayView(arguments[0])
    right = runtime.arrayView(arguments[1])
    outputs = runtime.arrayView(arguments[2], writable = true)
  left.requireLength(size)
  right.requireLength(size)
  outputs.requireLength(size)
  runtime.chargeOperations(int64(size))
  for i in 0 ..< size:
    outputs[i] = left[i] * right[i]
  toValue(0)

proc dataCopy(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Copies a numeric prefix after reserving its work.
  let
    size = count(arguments[2])
    source = runtime.arrayView(arguments[0])
    outputs = runtime.arrayView(arguments[1], writable = true)
  source.requireLength(size)
  outputs.requireLength(size)
  runtime.chargeOperations(int64(size))
  for i in 0 ..< size:
    outputs[i] = source[i]
  toValue(0)

proc dataFill(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Fills a mutable numeric prefix after reserving its work.
  let
    size = count(arguments[2])
    outputs = runtime.arrayView(arguments[0], writable = true)
    value = arguments[1]
  outputs.requireLength(size)
  if value.kind == StringValue:
    raise newException(BasicError, "dataFill requires a number")
  runtime.chargeOperations(int64(size))
  for i in 0 ..< size:
    outputs[i] = value
  toValue(0)

proc dataDot(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Computes an ordered dot product after reserving its work.
  let
    size = count(arguments[2])
    left = runtime.arrayView(arguments[0])
    right = runtime.arrayView(arguments[1])
  left.requireLength(size)
  right.requireLength(size)
  runtime.chargeOperations(2 * int64(size))
  var total = toValue(0)
  for i in 0 ..< size:
    total = total + left[i] * right[i]
  total

proc addNeuralFunctions*(host: var Host) =
  ## Registers generic numeric operations without prescribing a network.
  discard host.addFunction("linear", 6, linear)
  discard host.addFunction("relu", 2, relu)
  discard host.addFunction("argmax", 2, argmax)
  discard host.addFunction("argmaxMasked", 3, argmaxMasked)
  discard host.addFunction("dataAdd", 4, dataAdd)
  discard host.addFunction("dataMultiply", 4, dataMultiply)
  discard host.addFunction("dataCopy", 3, dataCopy)
  discard host.addFunction("dataFill", 3, dataFill)
  discard host.addFunction("dataDot", 3, dataDot)
