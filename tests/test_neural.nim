import
  std/strutils,
  bassy,
  polyworld/neural

proc host(): Host =
  ## Creates the same native array function set used by game hosts.
  result = initHost()
  result.addNeuralFunctions()

proc rejects(action: proc() {.closure.}, message: string) =
  ## Requires an explicit BASIC error instead of a defect or silent failure.
  var caught = false
  try:
    action()
  except BasicError as error:
    caught = true
    doAssert message in error.msg, error.msg
  doAssert caught, "expected BASIC error: " & message

echo "Testing linear preserves scalar integer wrapping and fixed rounding"
for representation in ["int32", "fixed32"]:
  let
    weights =
      if representation == "int32":
        "2147483647, -25000, 13, -2147483648, 7654, -99"
      else:
        "0.15625, -0.46875, 0.3125, 1.125, -0.000031, 0.75"
    biases =
      if representation == "int32": "400000001, 12000007"
      else: "-0.375, 0.625"
    source = "data weights as " & representation & " = " & weights &
      "\ndata biases as " & representation & " = " & biases & "\n" & """
dim features(2)
dim actual(1)
dim expected(1)
for trial = 0 to 63
  features(0) = trial - 32
  features(1) = trial * 3 - 57
  features(2) = 77 - trial
  for row = 0 to 1
    expected(row) = biases(row)
    for column = 0 to 2
      expected(row) = expected(row) + features(column) * weights(row * 3 + column)
    next column
  next row
  linear(features, weights, biases, actual, 3, 2)
  for row = 0 to 1
    if actual(row) <> expected(row) then mismatches = mismatches + 1
  next row
next trial
"""
    schema = host()
  var runtime = initRuntime(compile(source, schema), schema)
  discard runtime.run()
  doAssert runtime.getGlobal("mismatches") == 0

echo "Testing generic arithmetic, ReLU, masks, and first-index ties"
block:
  let
    schema = host()
    program = compile("""
data x = -2, 3, 3, 500
data y = 4, 5, -7, 500
data mask = 0, 0, 1, 1
data emptyMask = 0, 0, 0
dim sums(3)
dim products(3)
dim copied(3)
dataAdd(x, y, sums, 3)
dataMultiply(x, y, products, 3)
dataCopy(x, copied, 3)
relu(copied, 3)
best = argmax(copied, 3)
allowed = argmaxMasked(x, mask, 3)
empty = argmaxMasked(x, emptyMask, 3)
dot = dataDot(x, y, 3)
dataFill(products, 17, 2)
dataAdd(sums, sums, sums, 3)
""", schema)
  var runtime = initRuntime(program, schema)
  discard runtime.run()
  doAssert runtime.getArray("sums", 0) == 4
  doAssert runtime.getArray("sums", 1) == 16
  doAssert runtime.getArray("sums", 2) == -8
  doAssert runtime.getArray("products", 0) == 17
  doAssert runtime.getArray("products", 2) == -21
  doAssert runtime.getArray("copied", 0) == 0
  doAssert runtime.getArray("copied", 3) == 0
  doAssert runtime.getGlobal("best") == 1
  doAssert runtime.getGlobal("allowed") == 2
  doAssert runtime.getGlobal("empty") == -1
  doAssert runtime.getGlobal("dot") == -14

echo "Testing shape, mutability, and alias validation before mutation"
for call in [
  "linear(x, weights, biases, output, 0, 2)",
  "linear(x, weights, biases, output, -1, 2)",
  "linear(x, weights, biases, output, 2147483647, 2147483647)",
  "linear(x, weights, biases, output, 2, 3)",
  "linear(x, weights, biases, output, 1.5, 2)",
  "linear(x, weights, biases, weights, 2, 2)",
  "linear(output, weights, biases, output, 2, 2)",
  "relu(weights, 4)",
  "dataFill(weights, 1, 4)",
  "dataFill(output, \"bad\", 2)",
  "dataAdd(x, x, output, 3)",
  "argmax(x, 0)",
  "argmaxMasked(x, biases, 3)",
  "relu(-1, 2)",
  "argmax(texts, 1)"
]:
  let
    schema = host()
    source = """
data x = 2, 3
data weights = 1, 2, 3, 4
data biases = 5, 6
dim output(1)
dim texts$(0)
""" & call.replace("texts,", "texts$,")
  var runtime = initRuntime(compile(source, schema), schema)
  rejects(proc() = discard runtime.run(), "")
  doAssert runtime.getArray("output", 0) == 0
  doAssert runtime.getArray("output", 1) == 0

echo "Testing native operations count against both shared budgets"
block:
  let
    schema = host()
    program = compile("""
data x = 2, 3
data weights = 1, 2, 3, 4
data biases = 5, 6
dim output(1)
linear(x, weights, biases, output, 2, 2)
""", schema)
  var full = initRuntime(program, schema)
  let stats = full.run()
  doAssert stats.instructions >= 12
  doAssert stats.workUnits >= 12
  for instructions in [true, false]:
    var limits = defaultLimits()
    if instructions:
      limits.maxInstructions = stats.instructions - 12
    else:
      limits.maxWorkUnits = stats.workUnits - 12
    var blocked = initRuntime(program, schema, limits)
    rejects(proc() = discard blocked.run(), "limit exceeded")
    doAssert blocked.getArray("output", 0) == 0
    doAssert blocked.getArray("output", 1) == 0
    if instructions:
      limits.maxInstructions = stats.instructions
    else:
      limits.maxWorkUnits = stats.workUnits
    var exact = initRuntime(program, schema, limits)
    discard exact.run()
    doAssert exact.getArray("output", 0) == 13
    doAssert exact.getArray("output", 1) == 24
  let bytes = full.memoryBytes
  for iteration in 0 ..< 100:
    full.restart()
    discard full.run()
    doAssert full.memoryBytes == bytes

echo "test_neural: all checks passed"
