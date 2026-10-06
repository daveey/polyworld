dim tensorShape(0)
sub tensorRichardInitialize()
  trEncoder = tensorLoad(trPrefix$ + ".encoder")
  trEncoderBias = tensorLoad(trPrefix$ + ".encoderBias")
  trDecoder = tensorLoad(trPrefix$ + ".decoder")
  trDecoderBias = tensorLoad(trPrefix$ + ".decoderBias")
  trInputs = tensorDim(trEncoder, 1)
  trHidden = tensorDim(trEncoder, 0)
  trOutputs = tensorDim(trDecoder, 0)
  trKind = tensorDtype(trEncoder)
  trType$ = "int32"
  if trKind = 1 then
    trType$ = "fixed"
  end if
  tensorShape(0) = trInputs
  trInput = tensorCreate(trType$, tensorShape)
  tensorShape(0) = trHidden
  trActivation = tensorCreate(trType$, tensorShape)
  tensorShape(0) = trOutputs
  trLogits = tensorCreate(trType$, tensorShape)
  tensorShape(0) = trOutputs
  trFixedScores = tensorCreate("fixed", tensorShape)
  trHundred = tensorScalar("fixed", "100")
end sub

sub tensorRichardStep()
  tensorImport(trInput, trData)
  if trKind = 1 then
    tensorDivide(trInput, trHundred, trInput)
  end if
  tensorDense(trInput, trEncoder, trEncoderBias, trActivation)
  tensorRelu(trActivation, trActivation)
  tensorDense(trActivation, trDecoder, trDecoderBias, trLogits)
  if trKind = 0 then
    tensorReinterpret(trLogits, trFixedScores)
  else
    tensorCopy(trLogits, trFixedScores)
  end if
  trResult = tensorExport(trFixedScores)
end sub
