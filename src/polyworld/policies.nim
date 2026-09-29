import
  std/[os, strutils, tempfiles],
  zippy/ziparchives

const
  MaxPackageBytes* = 16 * 1024 * 1024
  MaxPackageEntries* = 256

type
  PolicyError* = object of CatchableError
  PolicyFile* = object
    name*, bytes*: string
  Policy* = ref object
    source*: string
    files*: seq[PolicyFile]
    memoryBytes*: int64

proc fail(message: string) {.noreturn, raises: [PolicyError].} =
  ## Reports package loading failures through the library boundary.
  raise newException(PolicyError, message)

proc resourcePath*(path: string): string =
  ## Accepts canonical package-relative resource names.
  result = path
  if result.len == 0 or result[0] == '/' or
    result.contains('\\') or result.contains(':') or result.contains('\0'):
      fail("Invalid package resource path: " & path)
  for part in result.split('/'):
    if part in ["", ".", ".."]:
      fail("Invalid package resource path: " & path)

proc isPackage*(bytes: string): bool =
  ## Recognizes ZIP contents independently of the uploaded file extension.
  bytes.len >= 4 and bytes[0 .. 1] == "PK" and
    bytes[2 .. 3] in ["\x03\x04", "\x05\x06", "\x07\x08"]

proc unpackPolicy(path: string): Policy =
  ## Uses Zippy to read the BASIC entry and resource bytes without extraction.
  let archive = openZipArchive(path)
  defer:
    archive.close()
  result = Policy()
  var
    names: seq[string]
    program: string
  for entry in archive.walkFiles():
    let name = resourcePath(entry)
    if names.len >= MaxPackageEntries:
      fail("ZIP package exceeds 256 files")
    names.add name
    if name.toLowerAscii.endsWith(".bas"):
      if program.len > 0:
        fail("ZIP package must contain exactly one .bas file")
      program = name
  if program.len == 0:
    fail("ZIP package must contain exactly one .bas file")
  result.source = archive.extractFile(program)
  result.memoryBytes = int64(result.source.len)
  for name in names:
    if name != program:
      let bytes = archive.extractFile(name)
      result.files.add PolicyFile(name: name, bytes: bytes)
      result.memoryBytes += int64(name.len) + int64(bytes.len) + 128

proc loadPolicy*(bytes: string): Policy =
  ## Unpacks uploads and leaves BASIC source limits to the VM compiler.
  if bytes.len > MaxPackageBytes:
    fail("Policy upload exceeds 16 MiB")
  if not bytes.isPackage:
    return Policy(source: bytes)
  try:
    # Zippy's current reader accepts a path, so stage only the compressed ZIP.
    let (file, path) = createTempFile("polyworld-policy-", ".zip")
    defer:
      removeFile(path)
    try:
      file.write(bytes)
    finally:
      file.close()
    result = unpackPolicy(path)
  except ZippyError, IOError, OSError:
    fail("Cannot read policy ZIP: " & getCurrentExceptionMsg())

proc readPolicyBytes*(path: string): string =
  ## Bounds upload reads for raw sources and extensionless staged packages.
  try:
    let input = open(path, fmRead)
    defer:
      input.close()
    result = newString(MaxPackageBytes + 1)
    result.setLen(input.readBuffer(result[0].addr, result.len))
  except IOError, OSError:
    fail("Cannot read policy: " & getCurrentExceptionMsg())
  if result.len > MaxPackageBytes:
    fail("Policy upload exceeds 16 MiB")

proc readPolicy*(path: string): Policy =
  ## Reads a local policy using the same raw-or-ZIP content detection.
  loadPolicy(readPolicyBytes(path))

proc resource*(policy: Policy, path: string): string =
  ## Resolves an exact resource name solely inside the policy package.
  let name = resourcePath(path)
  if policy != nil:
    for file in policy.files:
      if file.name == name:
        return file.bytes
  fail("Missing package resource: " & name)
