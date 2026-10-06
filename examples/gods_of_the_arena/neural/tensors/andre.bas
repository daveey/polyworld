dim tensorShape(0)
dim taRecurrences(15)
dim taStates(15)
sub tensorAndreInitialize()
  taEncoder = tensorLoad("encoder")
  taDecoder = tensorLoad("decoder")
  taWidth = tensorDim(taEncoder, 0)
  taInputs = tensorDim(taEncoder, 1)
  taOutputs = tensorDim(taDecoder, 0)
  taLayerCountTensor = tensorLoad("layers")
  taCounts = tensorExport(taLayerCountTensor)
  taLayers = taCounts(0)
  for taLayer = 0 to taLayers - 1
    taRecurrences(taLayer) = tensorLoad("recurrent." + trim$(str$(taLayer)))
    tensorShape(0) = taWidth
    taStates(taLayer) = tensorCreate("float32", tensorShape)
  next taLayer
  tensorShape(0) = taInputs
  taInput = tensorCreate("float32", tensorShape)
  tensorShape(0) = taWidth
  taEncoded = tensorCreate("float32", tensorShape)
  tensorShape(0) = taWidth
  taState = tensorCreate("float32", tensorShape)
  tensorShape(0) = taWidth * 3
  taProjection = tensorCreate("float32", tensorShape)
  tensorShape(0) = taWidth
  taCandidate = tensorCreate("float32", tensorShape)
  tensorShape(0) = taWidth
  taPositive = tensorCreate("float32", tensorShape)
  tensorShape(0) = taWidth
  taGate = tensorCreate("float32", tensorShape)
  tensorShape(0) = taWidth
  taHighway = tensorCreate("float32", tensorShape)
  tensorShape(0) = taWidth
  taNext = tensorCreate("float32", tensorShape)
  tensorShape(0) = taWidth
  taMixed = tensorCreate("float32", tensorShape)
  tensorShape(0) = taWidth
  taScratch = tensorCreate("float32", tensorShape)
  tensorShape(0) = taWidth
  taOther = tensorCreate("float32", tensorShape)
  tensorShape(0) = taWidth
  taMask = tensorCreate("int32", tensorShape)
  tensorShape(0) = taOutputs
  taLogits = tensorCreate("float32", tensorShape)
  taZero = tensorScalar("float32", "0")
  taHalf = tensorScalar("float32", "0.5")
  taOne = tensorScalar("float32", "1")
end sub

sub tensorAndreReset()
  for taLayer = 0 to taLayers - 1
    tensorFill(taStates(taLayer), taZero)
  next taLayer
end sub

sub tensorAndreStep()
  tensorImport(taInput, taData)
  tensorDense(taInput, taEncoder, 0, taEncoded)
  for taLayer = 0 to taLayers - 1
    tensorCopy(taStates(taLayer), taState)
    tensorDense(taEncoded, taRecurrences(taLayer), 0, taProjection)
    tensorSlice(taProjection, 0, taWidth, taCandidate)
    tensorSlice(taProjection, taWidth, taWidth, taGate)
    tensorSlice(taProjection, taWidth * 2, taWidth, taHighway)
    tensorCompare(taCandidate, taZero, "ge", taMask)
    tensorAdd(taCandidate, taHalf, taPositive)
    tensorSigmoidDirect(taCandidate, taCandidate)
    tensorSelect(taMask, taPositive, taCandidate, taCandidate)
    tensorSigmoidDirect(taGate, taGate)
    tensorSubtract(taCandidate, taState, taScratch)
    tensorMultiply(taGate, taScratch, taScratch)
    tensorAdd(taState, taScratch, taNext)
    tensorSigmoidDirect(taHighway, taHighway)
    tensorMultiply(taHighway, taNext, taScratch)
    tensorSubtract(taOne, taHighway, taOther)
    tensorMultiply(taOther, taEncoded, taOther)
    tensorAdd(taScratch, taOther, taMixed)
    tensorCopy(taNext, taStates(taLayer))
    tensorCopy(taMixed, taEncoded)
  next taLayer
  tensorDense(taMixed, taDecoder, 0, taLogits)
  taResult = tensorExport(taLogits)
end sub
