## Restricted FP32 MinGRU actor for GotA neural packages (model.bin GOTANET1).
##
## The layout and equations are paintbot-pw's PWNET001 (PufferLib's MinGRU
## policy: linear encoder, one MinGRU layer with a highway to the encoder
## output, linear decoder), with the magic changed to GOTANET1. The hosted
## seat and the native training library run this same code, so a trainer can
## check its own actor against it bit for bit. See neural_basic.md.
import std/math

type
  Actor* = ref object
    inputSize*, hiddenSize*, outputSize*: int
    headSizes*: seq[int]
    observationContract*, actionContract*: string
    encoder, recurrent, decoder: seq[float32]

const
  ActorMagic* = "GOTANET1"
  MaxActorParameters* = 2_000_000
  MaxActorInputs* = 4096
  ActorWidths* = [64, 128, 256]
  NeuralOpBudget* = 4_000_000
    ## Operations one seat may spend per tick on inference, separate from the
    ## BASIC instruction budget.

proc finite(x: float32): bool = classify(x) notin {fcNan, fcInf, fcNegInf}

proc readU32(data: string, pos: var int): uint32 =
  if pos + 4 > data.len:
    raise newException(ValueError, "truncated neural actor")
  for i in 0..3:
    result = result or (uint32(ord(data[pos+i])) shl (8*i))
  pos += 4

proc headerSize*(heads: int): int = 8 + 24 + 128 + 4 * heads

proc loadActor*(data: string): Actor =
  ## Validates and loads a GOTANET1 model; raises ValueError on any defect.
  if data.len < 8 or data[0..<8] != ActorMagic:
    raise newException(ValueError, "invalid neural actor magic (want GOTANET1)")
  var p = 8
  let
    version = readU32(data, p)
    inputs = int(readU32(data, p))
    hidden = int(readU32(data, p))
    outputs = int(readU32(data, p))
    heads = int(readU32(data, p))
    parameters = int(readU32(data, p))
  if version != 1 or inputs notin 1..MaxActorInputs or hidden notin ActorWidths or
      outputs notin 2..1024 or heads notin 1..32:
    raise newException(ValueError, "unsupported neural actor dimensions/version")
  let expected = inputs*hidden + 3*hidden*hidden + outputs*hidden
  if parameters != expected or expected > MaxActorParameters or
      data.len != headerSize(heads) + expected*4:
    raise newException(ValueError, "invalid neural actor length/parameter count")
  new(result)
  result.inputSize = inputs
  result.hiddenSize = hidden
  result.outputSize = outputs
  result.observationContract = data[p..<p+64]; p += 64
  result.actionContract = data[p..<p+64]; p += 64
  for hash in [result.observationContract, result.actionContract]:
    for c in hash:
      if c notin {'0'..'9', 'a'..'f'}:
        raise newException(ValueError, "invalid neural contract hash")
  var total = 0
  for i in 0..<heads:
    let size = int(readU32(data, p))
    if size notin 2..1024:
      raise newException(ValueError, "invalid categorical head")
    result.headSizes.add(size)
    total += size
  if total != outputs:
    raise newException(ValueError, "head/output mismatch")
  for which in 0..2:
    let n =
      case which
      of 0: inputs*hidden
      of 1: 3*hidden*hidden
      else: outputs*hidden
    var dest = newSeq[float32](n)
    for i in 0..<n:
      let x = cast[float32](readU32(data, p))
      if not finite(x):
        raise newException(ValueError, "nonfinite neural weight")
      dest[i] = x
    case which
    of 0: result.encoder = dest
    of 1: result.recurrent = dest
    else: result.decoder = dest
  let ops = 2*(result.encoder.len + result.recurrent.len + result.decoder.len) +
    32*hidden
  if ops > NeuralOpBudget:
    raise newException(ValueError, "neural actor needs " & $ops &
      " operations per inference, over the " & $NeuralOpBudget & " budget")

proc operationCount*(actor: Actor): int =
  ## Published cost: 2 per multiply-accumulate plus 32 per MinGRU unit.
  2*(actor.encoder.len + actor.recurrent.len + actor.decoder.len) +
    32*actor.hiddenSize

proc parameterCount*(actor: Actor): int =
  actor.encoder.len + actor.recurrent.len + actor.decoder.len

proc sigmoid(x: float32): float32 =
  ## Same stable branches as PufferLib's GPU sigmoid.
  let z = exp(-abs(x))
  if x >= 0: 1'f32 / (1'f32 + z) else: z / (1'f32 + z)

proc interpolate(a, b, weight: float32): float32 =
  ## Same branches as PufferLib's lerp kernel.
  let delta = b - a
  if abs(weight) < 0.5'f32: a + weight*delta
  else: b - delta*(1'f32 - weight)

proc infer*(actor: Actor, obs: openArray[float32], state: var openArray[float32],
    logits: var openArray[float32]) =
  ## One recurrent step. The state (hiddenSize floats) is updated in place;
  ## on error (shape or nonfinite) neither state nor logits change.
  if obs.len != actor.inputSize or state.len != actor.hiddenSize or
      logits.len != actor.outputSize:
    raise newException(ValueError, "neural buffer shape mismatch")
  for x in obs:
    if not finite(x):
      raise newException(ValueError, "nonfinite neural input")
  for x in state:
    if not finite(x):
      raise newException(ValueError, "nonfinite neural state")
  var
    x, next, y: array[256, float32]
    combined: array[768, float32]
    output: array[1024, float32]
  let h = actor.hiddenSize
  for o in 0..<h:
    var sum = 0'f32
    for i in 0..<obs.len:
      sum += obs[i]*actor.encoder[o*obs.len+i]
    x[o] = sum
  for o in 0..<3*h:
    var sum = 0'f32
    for i in 0..<h:
      sum += x[i]*actor.recurrent[o*h+i]
    combined[o] = sum
  for i in 0..<h:
    let
      candidate =
        if combined[i] >= 0: combined[i] + 0.5'f32 else: sigmoid(combined[i])
      gate = sigmoid(combined[h+i])
    next[i] = interpolate(state[i], candidate, gate)
    let highway = sigmoid(combined[2*h+i])
    y[i] = highway*next[i] + (1'f32 - highway)*x[i]
    if not finite(next[i]) or not finite(y[i]):
      raise newException(ValueError, "nonfinite neural intermediate")
  for o in 0..<actor.outputSize:
    var sum = 0'f32
    for i in 0..<h:
      sum += y[i]*actor.decoder[o*h+i]
    if not finite(sum):
      raise newException(ValueError, "nonfinite neural output")
    output[o] = sum
  for i in 0..<h:
    state[i] = next[i]
  for i in 0..<actor.outputSize:
    logits[i] = output[i]

proc encodeActor*(inputs, hidden: int, headSizes: openArray[int],
    obsContract, actionContract: string,
    weights: openArray[float32]): string =
  ## Serializes a GOTANET1 model (tests and random-weight canaries).
  proc u32(s: var string, v: uint32) =
    for i in 0..3:
      s.add char((v shr (8*i)) and 0xff)
  var outputs = 0
  for size in headSizes:
    outputs += size
  let expected = inputs*hidden + 3*hidden*hidden + outputs*hidden
  doAssert weights.len == expected
  result = ActorMagic
  for v in [1, inputs, hidden, outputs, headSizes.len, expected]:
    result.u32(uint32(v))
  doAssert obsContract.len == 64 and actionContract.len == 64
  result.add obsContract
  result.add actionContract
  for size in headSizes:
    result.u32(uint32(size))
  for w in weights:
    result.u32(cast[uint32](w))
