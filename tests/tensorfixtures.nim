import
  std/[os, strutils],
  jsony,
  polyworld/[policies, tensors],
  ../examples/gods_of_the_arena/neural/common

const TensorLibraries* = currentSourcePath().parentDir.parentDir /
  "examples/gods_of_the_arena/neural/tensors"

type
  Entry = object
    name, dtype, resource: string
    shape: seq[int]
    offset: int
  Manifest = object
    tensors: seq[Entry]

proc tensorPolicy*(author, model: string): Policy =
  ## Splits synthetic model bytes into the documented generic tensor layout.
  var
    manifest: Manifest
    bytes: string
  proc add(name, kind: string, shape: seq[int], payload: string) =
    ## Adds one named tensor to the synthetic package directory.
    manifest.tensors.add Entry(name: name, dtype: kind, shape: shape,
      resource: "tensors.bin", offset: bytes.len)
    bytes.add payload
  proc extract(name, kind: string, shape: seq[int], offset: int) =
    ## Extracts a checked row-major tensor from a synthetic author fixture.
    var count = 1
    for size in shape:
      count *= size
    doAssert offset >= 0 and offset + count * 4 <= model.len
    add(name, kind, shape, model[offset ..< offset + count * 4])
  var reader = ModelReader(bytes: model, position: 8)
  case author
  of "richard":
    let
      residual = reader.readWord() == 1
      inputs = if residual: 31 else: 25
      hidden = if residual: 8 else: 16
      outputs = if residual: 19 else: 18
      kind = if residual: "fixed" else: "int32"
    for (name, columns, rows) in [("encoder", inputs, hidden),
        ("decoder", hidden, outputs)]:
      var bias, weights: string
      for _ in 0 ..< rows:
        bias.addWord(reader.readWord())
        for _ in 0 ..< columns:
          weights.addWord(reader.readWord())
      add("weights." & name, kind, @[rows, columns], weights)
      add("weights." & name & "Bias", kind, @[rows], bias)
  of "david":
    discard reader.readWord()
    let
      inputs = int(reader.readWord())
      width = int(reader.readWord())
      outputs = int(reader.readWord())
      heads = int(reader.readWord())
    var offset = 160 + heads * 4
    for (name, rows, columns) in [("encoder", width, inputs),
        ("recurrent", width * 3, width), ("decoder", outputs, width)]:
      extract(name, "float32", @[rows, columns], offset)
      offset += rows * columns * 4
  of "andre":
    let
      width = int(reader.readWord())
      layers = int(reader.readWord())
      decoder = (width * 45 + 7) and not 7
      recurrence = (decoder + width * 12 + 7) and not 7
      stride = (width * width * 3 + 7) and not 7
    extract("encoder", "float32", @[width, 45], 16)
    extract("decoder", "float32", @[12, width], 16 + decoder * 4)
    for layer in 0 ..< layers:
      extract("recurrent." & $layer, "float32", @[width * 3, width],
        16 + (recurrence + stride * layer) * 4)
    var count: string
    count.addWord(uint32(layers))
    add("layers", "int32", @[1], count)
  of "fly":
    let
      neurons = int(reader.readWord())
      edges = int(reader.readWord())
      inputs = int(reader.readWord())
      driven = int(reader.readWord())
      read = int(reader.readWord())
      steps = reader.readWord()
      leak = reader.readWord()
    var offset = 36
    for (name, kind, shape) in [
      ("offsets", "int32", @[neurons + 1]),
      ("sources", "int32", @[edges]),
      ("weights", "float32", @[edges]),
      ("bias", "float32", @[neurons]),
      ("driveNeurons", "int32", @[driven]),
      ("drive", "float32", @[driven, inputs]),
      ("readNeurons", "int32", @[read]),
      ("readout", "float32", @[12, read]),
      ("readoutBias", "float32", @[12])]:
        extract(name, kind, shape, offset)
        var count = 1
        for size in shape:
          count *= size
        offset += count * 4
    var stepBytes, leakBytes: string
    stepBytes.addWord(steps)
    leakBytes.addWord(leak)
    add("steps", "int32", @[1], stepBytes)
    add("leak", "float32", @[1], leakBytes)
  else:
    raise newException(TensorError, "Unknown test architecture")
  result = Policy(files: @[
    PolicyFile(name: "tensors.json", bytes: manifest.toJson()),
    PolicyFile(name: "tensors.bin", bytes: bytes)
  ], memoryBytes: int64(bytes.len + manifest.toJson.len + 1024))

proc tensorSource*(author: string, inputs: int): string =
  ## Wraps a standalone forward pass with reusable input and result globals.
  let
    prefix = case author
      of "richard":
        "tr"
      of "david":
        "td"
      of "andre":
        "ta"
      else:
        "tf"
    title = author.capitalizeAscii
  result = readFile(TensorLibraries / (author & ".bas")) &
    "\ndim data(" & $(inputs - 1) & ")\n" &
    "if initialized = 0 then\n"
  if author == "richard":
    result.add "  trPrefix$ = \"weights\"\n"
  result.add "  tensor" & title & "Initialize()\n" &
    "  initialized = 1\nend if\n" &
    prefix & "Data = data\n" &
    "tensor" & title & "Step()\nanswer = " & prefix & "Result\n"

proc mixedWeights*(model: string, start: int, kind: TensorDtype): string =
  ## Adds reproducible mixed signs to exercise every dense and recurrent row.
  result = model
  var seed = 7919'u32
  for offset in countup(start, model.len - 4, 4):
    seed = seed * 1664525'u32 + 1013904223'u32
    let raw =
      case kind
      of Int32Tensor:
        cast[uint32](int32(seed mod 17) - 8)
      of FixedTensor:
        cast[uint32](int32(seed mod 131073) - 65536)
      of Float32Tensor:
        cast[uint32](float32(int32(seed mod 2001) - 1000) / 32768.0'f)
    for i in 0 ..< 4:
      result[offset + i] = char((raw shr (i * 8)) and 255)

proc largeFlyFixture*(): string =
  ## Generates the existing benchmark's connectome size without learned data.
  const
    Neurons = 40_619
    PerNeuron = 26
    Driven = 1627
    Read = 1276
  result = "FLYNN1\0\0"
  for value in [Neurons, Neurons * PerNeuron, 45, Driven, Read, 4]:
    result.addWord(uint32(value))
  result.addWord(cast[uint32](0.5'f))
  for i in 0 .. Neurons:
    result.addWord(uint32(i * PerNeuron))
  for i in 0 ..< Neurons * PerNeuron:
    result.addWord(uint32((i * 7919) mod Neurons))
  for i in 0 ..< Neurons * PerNeuron:
    result.addWord(cast[uint32](if i mod 5 < 3: 0.05'f else: -0.05'f))
  for _ in 0 ..< Neurons:
    result.addWord(cast[uint32](0.01'f))
  for i in 0 ..< Driven:
    result.addWord(uint32((i * 23) mod Neurons))
  for _ in 0 ..< Driven * 45:
    result.addWord(cast[uint32](0.001'f))
  for i in 0 ..< Read:
    result.addWord(uint32((i * 31) mod Neurons))
  for _ in 0 ..< 12 * Read:
    result.addWord(cast[uint32](0.001'f))
  for _ in 0 ..< 12:
    result.addWord(0)
