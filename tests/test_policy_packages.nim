import
  std/[strutils, os, tables, tempfiles],
  bassy, zippy/ziparchives,
  polyworld/policies,
  neuralfixtures

proc rejected(bytes: string): bool =
  ## Requires package failures to use the library error type.
  try:
    discard loadPolicy(bytes)
  except PolicyError:
    return true

proc changeWord(bytes: string, offset: int, value: uint32): string =
  ## Changes ZIP metadata to exercise errors reported by Zippy.
  result = bytes
  for i in 0 ..< 4:
    result[offset + i] = char((value shr (8 * i)) and 255)

echo "Testing raw BASIC and Zippy stored/deflated extensionless packages"
doAssert loadPolicy("end\n").files.len == 0
for deflated in [false, true]:
  let
    bytes = zipFixture([("nested/policy.bas", "end\n"),
      ("weights.bin", repeat("data", 1000))], deflated)
    policy = loadPolicy(bytes)
    directory = createTempDir("policy-package-", "")
    path = directory / "staged"
  defer:
    removeFile(path)
    removeDir(directory)
  writeFile(path, bytes)
  doAssert readPolicy(path).source == "end\n"
  doAssert policy.source == "end\n"
  doAssert policy.resource("weights.bin") == repeat("data", 1000)
  doAssert policy.files.len == 1
  for length in 4 ..< bytes.len:
    doAssert rejected(bytes[0 ..< length])

for files in [
  @[("weights.bin", "x")],
  @[("a.bas", "end"), ("nested/b.BAS", "end")],
  @[("a.bas", "end"), ("a.bas", "end")],
  @[("a.bas", "end"), ("../escape", "x")],
  @[("a.bas", "end"), ("/absolute", "x")],
  @[("a.bas", "end"), ("a\\b", "x")],
  @[("a.bas", "end"), ("C:relative", "x")],
  @[("a.bas", "end"), ("a/./b", "x")],
  @[("a.bas", "end"), ("a//b", "x")],
  @[("a.bas", "end"), ("a\0b", "x")]
]:
  doAssert rejected(zipFixture(files))
let
  good = zipFixture([("a.bas", "end")])
  central = good.find("PK\x01\x02")
doAssert rejected(good.changeWord(central + 10, 99))
doAssert rejected(good.changeWord(central + 16, 123))
doAssert rejected("PK\x03\x04" & repeat('x', MaxPackageBytes))
var many = @[("policy.bas", "end")]
for i in 0 ..< 256:
  many.add ($i & ".bin", "x")
doAssert rejected(zipFixture(many))

echo "Testing Zippy data descriptors and ZIP64 archives"
for deflated in [false, true]:
  let bytes = zipFixture([("a.bas", "end")], deflated, true)
  doAssert loadPolicy(bytes).source == "end"
var entries = {"policy.bas": "end", "weights.bin": "binary\0data"}.toTable
let zip64 = loadPolicy(createZipArchive(move(entries)))
doAssert zip64.source == "end"
doAssert zip64.resource("weights.bin") == "binary\0data"
let
  longPath = repeat('a', 1000)
  named = loadPolicy(zipFixture([("a.bas", "end"), (longPath, "x")]))
doAssert named.memoryBytes >= 1004

echo "Testing BASIC source size is rejected by the VM after unpacking"
let source = repeat("' oversized BASIC source\n", 4000)
for bytes in [source, zipFixture([("policy.bas", source)], true)]:
  let policy = loadPolicy(bytes)
  doAssert policy.source == source
  var limits = defaultLimits()
  limits.maxSourceBytes = 65536
  try:
    discard compile(policy.source, initHost(), limits)
    doAssert false, "Oversized source reached compilation"
  except BasicError as error:
    doAssert error.msg.contains("source exceeds"), error.msg
