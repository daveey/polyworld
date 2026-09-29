import
  std/strutils,
  zippy, zippy/crc,
  ../examples/gods_of_the_arena/neural/common

proc word16(bytes: var string, value: int) =
  ## Writes a synthetic ZIP header field.
  bytes.add char(value and 255)
  bytes.add char((value shr 8) and 255)

proc zipFixture*(
    files: openArray[(string, string)],
    deflated = false,
    descriptor = false
): string =
  ## Builds small ordinary ZIPs without depending on a ZIP64 writer.
  var directory: string
  for (name, contents) in files:
    let
      start = result.len
      packed = if deflated: compress(contents, dataFormat = dfDeflate)
        else: contents
      methodId = if deflated: 8 else: 0
      checksum = crc32(contents)
      flags = if descriptor: 8 else: 0
    result.addWord(0x04034b50)
    for value in [20, flags, methodId, 0, 0]:
      result.word16(value)
    result.addWord(if descriptor: 0'u32 else: checksum)
    result.addWord(if descriptor: 0'u32 else: uint32(packed.len))
    result.addWord(if descriptor: 0'u32 else: uint32(contents.len))
    result.word16(name.len)
    result.word16(0)
    result.add name
    result.add packed
    if descriptor:
      result.addWord(0x08074b50)
      result.addWord(checksum)
      result.addWord(uint32(packed.len))
      result.addWord(uint32(contents.len))
    directory.addWord(0x02014b50)
    for value in [20, 20, flags, methodId, 0, 0]:
      directory.word16(value)
    directory.addWord(checksum)
    directory.addWord(uint32(packed.len))
    directory.addWord(uint32(contents.len))
    for value in [name.len, 0, 0, 0, 0]:
      directory.word16(value)
    directory.addWord(0)
    directory.addWord(uint32(start))
    directory.add name
  let start = result.len
  result.add directory
  result.addWord(0x06054b50)
  for value in [0, 0, files.len, files.len]:
    result.word16(value)
  result.addWord(uint32(directory.len))
  result.addWord(uint32(start))
  result.word16(0)

proc richardFixture*(residual = false): string =
  ## Gives each Richard architecture a synthetic sparse, nonzero network.
  result = "RICHNN01"
  result.addWord(uint32(residual))
  let
    inputs = if residual: 31 else: 25
    hidden = if residual: 8 else: 16
    outputs = if residual: 19 else: 18
  for row in 0 ..< hidden:
    result.addWord(0)
    for column in 0 ..< inputs:
      result.addWord(if column == row: (if residual: 65536'u32 else: 1) else: 0)
  for row in 0 ..< outputs:
    result.addWord(uint32(row))
    for column in 0 ..< hidden:
      result.addWord(if column == row: (if residual: 65536'u32 else: 1) else: 0)

proc davidFixture*(inputs = 1407, hidden = 64): string =
  ## Encodes public synthetic weights with one active recurrent channel.
  const Outputs = 92
  result = "GOTANET1"
  for value in [1, inputs, hidden, Outputs, 5,
      hidden * (inputs + 3 * hidden + Outputs)]:
    result.addWord(uint32(value))
  result.add repeat('0', 128)
  for size in [8, 25, 49, 4, 6]:
    result.addWord(uint32(size))
  for i in 0 ..< hidden * (inputs + 3 * hidden + Outputs):
    let active = i == 0 or i == hidden * inputs or
      i == hidden * (inputs + 3 * hidden)
    result.addWord(cast[uint32](if active: 1.0'f else: 0.0'f))

proc andreFixture*(hidden = 12, layers = 1, wrapped = true): string =
  ## Builds an aligned PufferNet with one active channel in each layer.
  let
    decoder = (45 * hidden + 7) and not 7
    recurrent = (decoder + 12 * hidden + 7) and not 7
    stride = (3 * hidden * hidden + 7) and not 7
    count = recurrent + layers * stride
  if wrapped:
    result = "ANDRENN1"
    result.addWord(uint32(hidden))
    result.addWord(uint32(layers))
  for i in 0 ..< count:
    let active = i == 0 or i == decoder or
      i == decoder + 11 * hidden or
      (i >= recurrent and (i - recurrent) mod stride == 0)
    result.addWord(cast[uint32](if active: 1.0'f else: 0.0'f))
