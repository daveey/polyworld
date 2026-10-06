dim tensorShape(0)
sub tensorDavidInitialize()
  tdEncoder = tensorLoad("encoder")
  tdDecoder = tensorLoad("decoder")
  tdWidth = tensorDim(tdEncoder, 0)
  tdInputs = tensorDim(tdEncoder, 1)
  tdOutputs = tensorDim(tdDecoder, 0)
  tdRecurrent = tensorLoad("recurrent")
  tensorShape(0) = tdInputs
  tdInput = tensorCreate("float32", tensorShape)
  tensorShape(0) = tdWidth
  tdEncoded = tensorCreate("float32", tensorShape)
  tensorShape(0) = tdWidth
  tdState = tensorCreate("float32", tensorShape)
  tensorShape(0) = tdWidth * 3
  tdProjection = tensorCreate("float32", tensorShape)
  tensorShape(0) = tdWidth
  tdCandidate = tensorCreate("float32", tensorShape)
  tensorShape(0) = tdWidth
  tdPositive = tensorCreate("float32", tensorShape)
  tensorShape(0) = tdWidth
  tdGate = tensorCreate("float32", tensorShape)
  tensorShape(0) = tdWidth
  tdHighway = tensorCreate("float32", tensorShape)
  tensorShape(0) = tdWidth
  tdNext = tensorCreate("float32", tensorShape)
  tensorShape(0) = tdWidth
  tdMixed = tensorCreate("float32", tensorShape)
  tensorShape(0) = tdWidth
  tdScratch = tensorCreate("float32", tensorShape)
  tensorShape(0) = tdWidth
  tdOther = tensorCreate("float32", tensorShape)
  tensorShape(0) = tdWidth
  tdMask = tensorCreate("int32", tensorShape)
  tensorShape(0) = tdOutputs
  tdLogits = tensorCreate("float32", tensorShape)
  tdZero = tensorScalar("float32", "0")
  tdHalf = tensorScalar("float32", "0.5")
  tdOne = tensorScalar("float32", "1")
end sub

sub tensorDavidReset()
  tensorFill(tdState, tdZero)
end sub

sub tensorDavidStep()
  tensorImport(tdInput, tdData)
  tensorDense(tdInput, tdEncoder, 0, tdEncoded)
  tensorDense(tdEncoded, tdRecurrent, 0, tdProjection)
  tensorSlice(tdProjection, 0, tdWidth, tdCandidate)
  tensorSlice(tdProjection, tdWidth, tdWidth, tdGate)
  tensorSlice(tdProjection, tdWidth * 2, tdWidth, tdHighway)
  tensorCompare(tdCandidate, tdZero, "ge", tdMask)
  tensorAdd(tdCandidate, tdHalf, tdPositive)
  tensorSigmoid(tdCandidate, tdCandidate)
  tensorSelect(tdMask, tdPositive, tdCandidate, tdCandidate)
  tensorSigmoid(tdGate, tdGate)
  tensorLerp(tdState, tdCandidate, tdGate, tdNext)
  tensorSigmoid(tdHighway, tdHighway)
  tensorMultiply(tdHighway, tdNext, tdScratch)
  tensorSubtract(tdOne, tdHighway, tdOther)
  tensorMultiply(tdOther, tdEncoded, tdOther)
  tensorAdd(tdScratch, tdOther, tdMixed)
  tensorCopy(tdNext, tdState)
  tensorDense(tdMixed, tdDecoder, 0, tdLogits)
  tdResult = tensorExport(tdLogits)
end sub
