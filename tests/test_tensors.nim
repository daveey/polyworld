import
  std/math,
  bassy,
  polyworld/[policies, tensors],
  ../examples/gods_of_the_arena/neural/[common, richard, david, andre, fly],
  neuralfixtures, tensorfixtures

proc rejected(action: proc() {.closure.}): bool =
  ## Recognizes controlled tensor and BASIC sandbox failures.
  try:
    action()
  except BasicError:
    return true

proc makeVm(source: string, policy: Policy = nil,
    limits = defaultLimits()): Runtime =
  ## Creates the same tensor host used by GotA without simulation bindings.
  var host = initHost()
  host.addBufferFunctions()
  host.addTensorFunctions(policy)
  initRuntime(compile(source, host, limits), host, limits)

proc values(runtime: Runtime, name = "answer"): seq[Fixed] =
  ## Reads exported final outputs without changing their representations.
  let view = runtime.arrayView(runtime.getGlobalValue(name))
  for i in 0 ..< view.len:
    result.add view[i].asFixed

proc stateBytes(runtime: Runtime, name: string): string =
  ## Extracts packed state for comparison with an existing native runner.
  let bytes = runtime.getBlob(runtime.getGlobalValue(name))
  bytes[12 + ord(bytes[9]) * 4 .. ^1]

proc stateDifference(actual, expected: string): float =
  ## Measures floating differences rather than silently replacing references.
  doAssert actual.len == expected.len
  var
    a = ModelReader(bytes: actual)
    b = ModelReader(bytes: expected)
  while a.position < actual.len:
    let
      av = cast[float32](a.readWord())
      bv = cast[float32](b.readWord())
    doAssert av.finite and bv.finite
    result = max(result, abs(float(av) - float(bv)))

echo "Testing tensor arithmetic, broadcasting, slices and float32 boundary"
block:
  var vm = makeVm("""
dim shape(0)
dim data(2)
shape(0) = 3
a = tensorCreate("float32", shape)
b = tensorCreate("float32", shape)
data(0) = 1.5
data(1) = -2.0
data(2) = 0.25
tensorImport(a, data)
one = tensorScalar("float32", "1")
tensorMultiply(a, one, b)
tensorAdd(b, one, b)
answer = tensorExport(b)
best = tensorArgmax(b)
shape(0) = 1
small = tensorCreate("float32", shape)
tensorSlice(b, 1, 1, small)
tensorCopySlice(small, 0, b, 2, 1)
copy = tensorExport(b)
precise = tensorScalar("float32", "0.10000000149011612")
""")
  discard vm.run()
  doAssert vm.values() == @[2.5'fx, -1.0'fx, 1.25'fx]
  doAssert vm.values("copy") == @[2.5'fx, -1.0'fx, -1.0'fx]
  doAssert vm.getGlobal("best") == 0
  var reader = ModelReader(bytes: vm.stateBytes("precise"))
  doAssert reader.readWord() == cast[uint32](0.1'f)

for residual in [false, true]:
  echo "Testing exact Richard BASIC tensor outputs, residual=", residual
  let
    original = mixedWeights(richardFixture(residual), 12,
      if residual: FixedTensor else: Int32Tensor)
    model = loadRichard(original)
  var vm = makeVm(tensorSource("richard", model.inputs),
    tensorPolicy("richard", original))
  for step in 0 ..< 30:
    var data = newSeq[Fixed](model.inputs)
    for i in 0 ..< data.len:
      data[i] = fixed(int32((i * 37 + step * 13) mod 201 - 100))
      vm.setArray("data", int32(i), toValue(data[i]))
    vm.restart()
    discard vm.run()
    doAssert vm.values() == inferRichard(model, data)

for author in ["david", "andre", "fly"]:
  echo "Testing recurrent BASIC tensor states and logits: ", author
  for layers in 1 .. (if author == "andre": 3 else: 1):
    let
      original = case author
        of "david":
          mixedWeights(davidFixture(45), 180, Float32Tensor)
        of "andre":
          mixedWeights(andreFixture(12, layers), 16, Float32Tensor)
        else:
          flyFixture(leak = 0.7'f)
      policy = tensorPolicy(author, original)
    var
      vm = makeVm(tensorSource(author, 45), policy)
      previous: string
      difference: float
      outputDifference: int64
    for step in 0 ..< 30:
      var data: array[45, Fixed]
      for i in 0 ..< data.len:
        data[i] = Fixed(int32((i * 7919 + step * 1123) mod 131072 - 65536))
        vm.setArray("data", int32(i), toValue(data[i]))
      vm.restart()
      discard vm.run()
      let
        reference = case author
          of "david":
            inferDavid(loadDavid(original), previous, data)
          of "andre":
            inferAndre(loadAndre(original), previous, data)
          else:
            inferFly(loadFly(original), previous, data)
        name = case author
          of "david":
            "tdState"
          of "andre":
            "taState"
          else:
            "tfState"
      let actualOutputs = vm.values()
      for i in 0 ..< actualOutputs.len:
        outputDifference = max(outputDifference,
          abs(int64(int32(actualOutputs[i])) - int64(int32(reference.outputs[i]))))
      if author == "andre":
        var actual: string
        for layer in 0 ..< layers:
          let handle = vm.getArrayValue("taStates", int32(layer))
          let bytes = vm.getBlob(handle)
          actual.add bytes[16 .. ^1]
        difference = max(difference, stateDifference(actual, reference.state))
      else:
        difference = max(difference,
          stateDifference(vm.stateBytes(name), reference.state))
      previous = reference.state
    echo "  layers=", layers, " maximum FP32 state difference=", difference
    echo "  maximum exported Q16.16 difference=", outputDifference, " raw units"
    doAssert difference < 0.000002
    doAssert outputDifference <= 1
    vm.reset()
    previous = ""
    discard vm.run()
    let reference = case author
      of "david":
        inferDavid(loadDavid(original), previous, newSeq[Fixed](45))
      of "andre":
        inferAndre(loadAndre(original), previous, newSeq[Fixed](45))
      else:
        inferFly(loadFly(original), previous, newSeq[Fixed](45))
    doAssert vm.values() == reference.outputs

echo "Testing failed kernels leave destinations unchanged"
block:
  var vm = makeVm("""
dim shape(0)
shape(0) = 3
if initialized = 0 then
  destination = tensorCreate("fixed", shape)
  input = tensorCreate("fixed", shape)
  one = tensorScalar("fixed", "1")
  zero = tensorScalar("fixed", "0")
  tensorFill(destination, one)
  initialized = 1
end if
if bad then
  tensorDivide(input, zero, destination)
end if
""")
  discard vm.run()
  let
    handle = vm.getGlobalValue("destination")
    before = vm.getBlob(handle)
  vm.setGlobal("bad", 1)
  vm.restart()
  doAssert rejected(proc() = discard vm.run())
  doAssert vm.getBlob(handle) == before
  var other = makeVm("x = 0")
  doAssert rejected(proc() = discard other.tensorView(handle))
  vm.reset()
  doAssert rejected(proc() = discard vm.tensorView(handle))

for manifest in ["not json", "{}", "{\"tensors\":[{\"name\":\"w\",\"dtype\":\"float32\",\"shape\":[3],\"resource\":\"x\",\"offset\":0}]}"]:
  let policy = Policy(files: @[PolicyFile(name: "tensors.json",
      bytes: manifest)])
  var vm = makeVm("w = tensorLoad(\"w\")", policy)
  doAssert rejected(proc() = discard vm.run())

for value in ["nan", "inf", "bad", "1e100"]:
  var vm = makeVm("x = tensorScalar(\"float32\", \"" & value & "\")")
  doAssert rejected(proc() = discard vm.run())

echo "Testing native buffer limits independently of DIM arrays"
block:
  var limits = defaultLimits()
  limits.maxArrays = 1
  limits.maxNativeBuffers = 4
  let source = """
dim shape(0)
shape(0) = 1
a = tensorCreate("fixed", shape)
b = tensorCreate("fixed", shape)
c = tensorCreate("fixed", shape)
d = tensorCreate("fixed", shape)
"""
  var vm = makeVm(source, limits = limits)
  discard vm.run()
  limits.maxNativeBuffers = 3
  var blocked = makeVm(source, limits = limits)
  doAssert rejected(proc() = discard blocked.run())


echo "Testing masks, ordered duplicate scatter, gather, reshape and CSR"
block:
  var vm = makeVm("""
dim shape(0)
dim matrix(1)
dim data(2)
shape(0) = 3
x = tensorCreate("float32", shape)
y = tensorCreate("float32", shape)
mask = tensorCreate("int32", shape)
ids = tensorCreate("int32", shape)
data(0) = 1
data(1) = 2
data(2) = 3
tensorImport(x, data)
data(0) = 0
data(1) = 0
data(2) = 1
tensorImport(ids, data)
tensorScatterAdd(x, ids, y)
scatter = tensorExport(y)
tensorGather(y, ids, x)
gather = tensorExport(x)
one = tensorScalar("float32", "1")
zero = tensorScalar("float32", "0")
tensorCompare(x, one, "gt", mask)
tensorSelect(mask, x, zero, y)
answer = tensorExport(y)
best = tensorArgmaxMasked(y, mask)
izero = tensorScalar("int32", "0")
tensorFill(mask, izero)
none = tensorArgmaxMasked(y, mask)
matrix(0) = 1
matrix(1) = 3
reshaped = tensorCreate("float32", matrix)
tensorReshape(x, matrix, reshaped)
shape(0) = 4
offsets = tensorCreate("int32", shape)
dim edges(3)
edges(0) = 0
edges(1) = 2
edges(2) = 3
edges(3) = 3
tensorImport(offsets, edges)
tensorCsr(x, offsets, ids, one, y)
""")
  # The deliberately invalid CSR weight count fails after successful indexing.
  doAssert rejected(proc() = discard vm.run())
  doAssert vm.values("scatter") == @[3'fx, 3'fx, 0'fx]
  doAssert vm.values("gather") == @[3'fx, 3'fx, 3'fx]
  doAssert vm.values() == @[3'fx, 3'fx, 3'fx]
  doAssert vm.getGlobal("best") == 0 and vm.getGlobal("none") == -1
  let before = vm.getBlob(vm.getGlobalValue("y"))
  doAssert before.len == 28

echo "Testing empty sparse tensors and invalid shapes"
block:
  var vm = makeVm("""
dim shape(0)
shape(0) = 0
empty = tensorCreate("float32", shape)
noBest = tensorArgmax(empty)
""")
  discard vm.run()
  doAssert vm.getGlobal("noBest") == -1
for source in [
  "dim s(0)\ns(0) = -1\nx = tensorCreate(\"fixed\", s)",
  "dim s(0)\ns(0) = 4194305\nx = tensorCreate(\"fixed\", s)",
  "x = tensorScalar(\"int32\", \"2147483648\")",
  "x = tensorScalar(\"unknown\", \"1\")"
]:
  var vm = makeVm(source)
  doAssert rejected(proc() = discard vm.run())

echo "Testing immutable loaded weights and checked destination indices"
block:
  let policy = tensorPolicy("richard", richardFixture())
  var vm = makeVm("""
w = tensorLoad("weights.encoder")
one = tensorScalar("int32", "1")
tensorFill(w, one)
""", policy)
  doAssert rejected(proc() = discard vm.run())
  doAssert vm.tensorView(vm.getGlobalValue("w")).immutable

for call in [
  "tensorGather(x, indices, y)",
  "tensorScatterAdd(x, indices, y)",
  "tensorCopySlice(x, -1, y, 0, 1)",
  "tensorSlice(x, 0, 2, y)"
]:
  var vm = makeVm("""
dim shape(0)
dim data(0)
shape(0) = 1
x = tensorCreate("fixed", shape)
y = tensorCreate("fixed", shape)
indices = tensorCreate("int32", shape)
data(0) = 999
tensorImport(indices, data)
""" & call)
  doAssert rejected(proc() = discard vm.run())
  doAssert vm.stateBytes("y") == "\0\0\0\0"

echo "Testing size-based work and bounded temporary memory"
block:
  var limits = defaultLimits()
  limits.maxWorkUnits = 20
  var vm = makeVm("""
dim shape(0)
shape(0) = 10000
x = tensorCreate("float32", shape)
""", limits = limits)
  doAssert rejected(proc() = discard vm.run())
  limits = defaultLimits()
  limits.maxNativeMemoryBytes = 200
  var constrained = makeVm("""
dim shape(0)
shape(0) = 1000
x = tensorCreate("float32", shape)
""", limits = limits)
  doAssert rejected(proc() = discard constrained.run())

echo "Testing deterministic fixed nonlinear accuracy"
block:
  var vm = makeVm("""
dim shape(0)
dim data(0)
shape(0) = 1
if initialized = 0 then
  x = tensorCreate("fixed", shape)
  y = tensorCreate("fixed", shape)
  initialized = 1
end if
tensorImport(x, data)
tensorSigmoid(x, y)
sigmoid = tensorExport(y)
tensorTanh(x, y)
hyperbolic = tensorExport(y)
tensorExp(x, y)
exponential = tensorExport(y)
""")
  var maximumExpError, maximumSigmoidError, maximumTanhError: float
  for i in -40 .. 40:
    let input = float(i) / 8
    vm.setArray("data", 0, toValue(Fixed(int32(i * 8192))))
    vm.restart()
    discard vm.run()
    maximumExpError = max(maximumExpError,
      abs(float(vm.values("exponential")[0].toFloat32) - exp(input)))
    maximumSigmoidError = max(maximumSigmoidError,
      abs(float(vm.values("sigmoid")[0].toFloat32) - 1 / (1 + exp(-input))))
    maximumTanhError = max(maximumTanhError,
      abs(float(vm.values("hyperbolic")[0].toFloat32) - tanh(input)))
  echo "  fixed exp/sigmoid/tanh maximum errors=", maximumExpError,
    "/", maximumSigmoidError, "/", maximumTanhError
  doAssert maximumExpError < 0.0001
  doAssert maximumSigmoidError < 0.00004
  doAssert maximumTanhError < 0.00008


echo "Testing empty CSR rows and nonfinite package weights"
block:
  var vm = makeVm("""
dim shape(0)
shape(0) = 2
input = tensorCreate("float32", shape)
output = tensorCreate("float32", shape)
shape(0) = 3
offsets = tensorCreate("int32", shape)
shape(0) = 0
sources = tensorCreate("int32", shape)
weights = tensorCreate("float32", shape)
tensorCsr(input, offsets, sources, weights, output)
answer = tensorExport(output)
""")
  discard vm.run()
  doAssert vm.values() == @[0'fx, 0'fx]
block:
  let package = tensorPolicy("david", davidFixture(45))
  for file in package.files.mitems:
    if file.name == "tensors.bin":
      file.bytes[0 .. 3] = "\0\0\x80\x7f"
  var vm = makeVm("weight = tensorLoad(\"encoder\")", package)
  doAssert rejected(proc() = discard vm.run())

echo "Tensor tests passed"
