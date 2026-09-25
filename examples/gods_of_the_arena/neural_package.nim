## GotA neural package (gota-neural-basic/1): a ZIP of exactly manifest.json,
## policy.bas and model.bin. Parsing is strict: any unknown key, missing
## file, hash mismatch or contract mismatch rejects the package. The Python
## staging validator (coworld/gota/runtime/neural_package.py) mirrors these
## rules. See neural_basic.md.

import
  std/[json, strutils],
  crunchy, zippy,
  neural_actor, neural_contract

const
  PackageSchema* = "gota-neural-basic/1"
  PackageFiles* = ["manifest.json", "policy.bas", "model.bin"]
  MaxPackageBytes* = 16 * 1024 * 1024
  MaxPolicyBytes* = 256 * 1024
  ZipMagic* = "PK\x03\x04"

type
  DecoderMode* = enum ArgmaxDecoder, SampleDecoder
  NeuralPackage* = object
    decisionPeriod*: int32
    policy*: string
    model*: string
    actor*: Actor
    goals*: array[2, array[GoalSize, float32]] ## red, blue
    decoder*: DecoderMode
    temperature*: float32
    manifest*: string

proc isPackage*(bytes: string): bool = bytes.startsWith(ZipMagic)

proc sha256Hex*(data: string): string =
  for value in sha256(cast[pointer](data.cstring), data.len):
    result.add value.toHex(2).toLowerAscii()

proc u16(s: string, p: int): int =
  if p + 2 > s.len: raise newException(ValueError, "truncated zip")
  ord(s[p]) or (ord(s[p+1]) shl 8)

proc u32(s: string, p: int): int =
  if p + 4 > s.len: raise newException(ValueError, "truncated zip")
  ord(s[p]) or (ord(s[p+1]) shl 8) or (ord(s[p+2]) shl 16) or (ord(s[p+3]) shl 24)

proc readZip*(bytes: string): seq[(string, string)] =
  ## Reads every entry of a small, unencrypted, single-disk ZIP (stored or
  ## deflate) through its central directory.
  if bytes.len > MaxPackageBytes:
    raise newException(ValueError, "package exceeds 16 MiB")
  var eocd = -1
  for p in countdown(bytes.len - 22, max(0, bytes.len - 22 - 65535)):
    if bytes[p] == 'P' and bytes[p+1] == 'K' and bytes[p+2] == '\x05' and bytes[p+3] == '\x06':
      eocd = p
      break
  if eocd < 0: raise newException(ValueError, "zip end record not found")
  let
    entries = u16(bytes, eocd + 10)
    cdOffset = u32(bytes, eocd + 16)
  if entries > 16: raise newException(ValueError, "too many zip entries")
  var p = cdOffset
  for _ in 0 ..< entries:
    if u32(bytes, p) != 0x02014b50: raise newException(ValueError, "bad zip directory")
    let
      flags = u16(bytes, p + 8)
      methodId = u16(bytes, p + 10)
      compressed = u32(bytes, p + 20)
      size = u32(bytes, p + 24)
      nameLen = u16(bytes, p + 28)
      extraLen = u16(bytes, p + 30)
      commentLen = u16(bytes, p + 32)
      local = u32(bytes, p + 42)
    if p + 46 + nameLen > bytes.len: raise newException(ValueError, "truncated zip")
    let name = bytes[p + 46 ..< p + 46 + nameLen]
    if (flags and 1) != 0: raise newException(ValueError, "encrypted zip entry")
    if u32(bytes, local) != 0x04034b50: raise newException(ValueError, "bad zip entry")
    let
      dataStart = local + 30 + u16(bytes, local + 26) + u16(bytes, local + 28)
    if dataStart + compressed > bytes.len: raise newException(ValueError, "truncated zip data")
    let raw = bytes[dataStart ..< dataStart + compressed]
    var data: string
    case methodId
    of 0: data = raw
    of 8: data = uncompress(raw, dfDeflate)
    else: raise newException(ValueError, "unsupported zip compression " & $methodId)
    if data.len != size: raise newException(ValueError, "zip size mismatch for " & name)
    result.add((name, data))
    p += 46 + nameLen + extraLen + commentLen

proc requireKeys(node: JsonNode, allowed: openArray[string], where: string) =
  if node.kind != JObject:
    raise newException(ValueError, where & " must be an object")
  for key in node.keys:
    if key notin allowed:
      raise newException(ValueError, "unknown manifest key " & where & "." & key)

proc goalVector(node: JsonNode, where: string): array[GoalSize, float32] =
  if node.kind != JArray or node.len != GoalSize:
    raise newException(ValueError, where & " must be 16 numbers")
  for i in 0 ..< GoalSize:
    if node[i].kind notin {JInt, JFloat}:
      raise newException(ValueError, where & " must be 16 numbers")
    let v = node[i].getFloat
    if v < -1 or v > 1:
      raise newException(ValueError, where & " values must be in [-1, 1]")
    result[i] = float32(v)
  if result[GoalSize - 1] != 0:
    raise newException(ValueError, where & " w_reserved must be 0")

proc defaultGoal*(): array[GoalSize, float32] =
  result[0] = 1

proc parsePackage*(bytes: string): NeuralPackage =
  ## Validates a package completely; raises ValueError with the reason.
  let entries = readZip(bytes)
  if entries.len != 3:
    raise newException(ValueError, "package must contain exactly manifest.json, policy.bas and model.bin")
  var files: array[3, string]
  var seen: array[3, bool]
  for (name, data) in entries:
    let index = PackageFiles.find(name)
    if index < 0 or seen[index]:
      raise newException(ValueError, "unexpected package entry " & name)
    seen[index] = true
    files[index] = data
  let manifest = parseJson(files[0])
  manifest.requireKeys(["schema", "observation_contract", "action_contract",
    "decision_period", "files", "model", "goal", "decoder"], "manifest")
  for key in ["schema", "observation_contract", "action_contract",
      "decision_period", "files", "model"]:
    if not manifest.hasKey(key):
      raise newException(ValueError, "manifest is missing " & key)
  if manifest["schema"].getStr != PackageSchema:
    raise newException(ValueError, "manifest schema must be " & PackageSchema)
  if manifest["observation_contract"].getStr != ObservationContractHash:
    raise newException(ValueError, "observation contract mismatch")
  if manifest["action_contract"].getStr != ActionContractHash:
    raise newException(ValueError, "action contract mismatch")
  let period = manifest["decision_period"]
  if period.kind != JInt or period.getInt notin 1..24:
    raise newException(ValueError, "decision_period must be an integer 1..24")
  result.decisionPeriod = int32(period.getInt)
  let fileHashes = manifest["files"]
  fileHashes.requireKeys(["policy.bas", "model.bin"], "files")
  if not fileHashes.hasKey("policy.bas") or not fileHashes.hasKey("model.bin"):
    raise newException(ValueError, "files must list policy.bas and model.bin")
  if fileHashes["policy.bas"].getStr != sha256Hex(files[1]):
    raise newException(ValueError, "policy.bas sha256 mismatch")
  if fileHashes["model.bin"].getStr != sha256Hex(files[2]):
    raise newException(ValueError, "model.bin sha256 mismatch")
  if files[1].len > MaxPolicyBytes:
    raise newException(ValueError, "policy.bas exceeds 256 KiB")
  let model = manifest["model"]
  model.requireKeys(["format", "inputs", "hidden", "heads"], "model")
  for key in ["format", "inputs", "hidden", "heads"]:
    if not model.hasKey(key):
      raise newException(ValueError, "model is missing " & key)
  if model["format"].getStr != "GOTANET1":
    raise newException(ValueError, "model.format must be GOTANET1")
  let actor = loadActor(files[2])
  if actor.observationContract != ObservationContractHash or
      actor.actionContract != ActionContractHash:
    raise newException(ValueError, "model.bin contract hashes do not match the manifest")
  if model["inputs"].getInt != actor.inputSize or actor.inputSize != ObservationSize:
    raise newException(ValueError, "model.inputs must be " & $ObservationSize)
  if model["hidden"].getInt != actor.hiddenSize:
    raise newException(ValueError, "model.hidden does not match model.bin")
  var heads: seq[int]
  for h in model["heads"]:
    heads.add h.getInt
  if heads != @HeadSizes or actor.headSizes != @HeadSizes:
    raise newException(ValueError, "model.heads must be [8,25,49,4,6]")
  result.actor = actor
  result.goals = [defaultGoal(), defaultGoal()]
  if manifest.hasKey("goal"):
    let goal = manifest["goal"]
    goal.requireKeys(["red", "blue"], "goal")
    if not goal.hasKey("red") or not goal.hasKey("blue"):
      raise newException(ValueError, "goal needs red and blue")
    result.goals[0] = goalVector(goal["red"], "goal.red")
    result.goals[1] = goalVector(goal["blue"], "goal.blue")
  result.decoder = ArgmaxDecoder
  result.temperature = 1
  if manifest.hasKey("decoder"):
    let decoder = manifest["decoder"]
    decoder.requireKeys(["mode", "temperature"], "decoder")
    let mode = if decoder.hasKey("mode"): decoder["mode"].getStr else: "argmax"
    case mode
    of "argmax":
      if decoder.hasKey("temperature"):
        raise newException(ValueError, "decoder.temperature needs mode sample")
    of "sample":
      result.decoder = SampleDecoder
      if decoder.hasKey("temperature"):
        let t = decoder["temperature"].getFloat
        if t < 0.01 or t > 10:
          raise newException(ValueError, "decoder.temperature must be 0.01..10")
        result.temperature = float32(t)
    else:
      raise newException(ValueError, "decoder.mode must be argmax or sample")
  result.policy = files[1]
  result.model = files[2]
  result.manifest = files[0]
