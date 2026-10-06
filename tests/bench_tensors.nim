import
  std/[monotimes, times],
  bassy,
  polyworld/tensors,
  ../examples/gods_of_the_arena/neural/[common, richard, david, andre, fly],
  neuralfixtures, tensorfixtures

proc measure(name: string, iterations: int,
    action: proc() {.closure.}): float =
  ## Measures warmed inference separately from compilation and package load.
  let start = getMonoTime()
  for _ in 0 ..< iterations:
    action()
  result = float((getMonoTime() - start).inNanoseconds) /
    float(iterations) / 1000
  echo name, ": ", result, " us"

for (author, original, inputs, iterations) in [
  ("richard", richardFixture(), 25, 2000),
  ("richard", richardFixture(true), 31, 2000),
  ("david", davidFixture(1407, 512), 1407, 100),
  ("andre", andreFixture(12, 1), 45, 2000),
  ("andre", andreFixture(64, 3), 45, 1000),
  ("fly", largeFlyFixture(), 45, 30)
]:
  let
    package = tensorPolicy(author, original)
    source = tensorSource(author, inputs)
    label = author & " " & $original.len & " bytes"
  var
    host = initHost()
    limits = defaultLimits()
  host.addTensorFunctions(package)
  limits.maxNativeMemoryBytes = NativeMemoryBytes
  limits.maxInstructions = 100_000
  limits.maxWorkUnits = 250_000
  let start = getMonoTime()
  var vm = initRuntime(compile(source, host, limits), host, limits)
  for i in 0 ..< inputs:
    vm.setArray("data", int32(i), toValue(fixed(1)))
  let initial = vm.run()
  echo label, " load+compile: ",
    float((getMonoTime() - start).inNanoseconds) / 1_000_000, " ms"
  echo "  native memory: ", vm.nativeMemoryBytes, " bytes"
  echo "  initial work: ", initial.workUnits
  vm.restart()
  let warm = vm.run()
  echo "  inference work: ", warm.workUnits
  let basicTime = measure(label & " BASIC", iterations, proc() =
    ## Reuses tensors and recurrent state for each measured inference.
    vm.restart()
    discard vm.run()
  )
  var
    state: string
    data = newSeq[Fixed](inputs)
    outputs: seq[Fixed]
  for value in data.mitems:
    value = fixed(1)
  var nativeTime: float
  case author
  of "richard":
    let model = loadRichard(original)
    nativeTime = measure(label & " native", iterations, proc() =
      ## Measures the existing integer or fixed-point runner.
      outputs = inferRichard(model, data)
    )
  of "david":
    let model = loadDavid(original)
    nativeTime = measure(label & " native", iterations, proc() =
      ## Measures the existing dense recurrent runner.
      let next = inferDavid(model, state, data)
      outputs = next.outputs
      state = next.state
    )
  of "andre":
    let model = loadAndre(original)
    nativeTime = measure(label & " native", iterations, proc() =
      ## Measures the existing stacked recurrent runner.
      let next = inferAndre(model, state, data)
      outputs = next.outputs
      state = next.state
    )
  else:
    let model = loadFly(original)
    nativeTime = measure(label & " native", iterations, proc() =
      ## Measures the existing sparse connectome runner.
      let next = inferFly(model, state, data)
      outputs = next.outputs
      state = next.state
    )
  doAssert outputs.len > 0
  echo "  BASIC/native ratio: ", basicTime / nativeTime
