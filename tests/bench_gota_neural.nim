import
  bassy, benchy,
  ../examples/gods_of_the_arena/neural/[common, richard, david, andre, fly],
  neuralfixtures

let
  combat = loadRichard(richardFixture())
  residual = loadRichard(richardFixture(true))
  davidModel = loadDavid(davidFixture(1407, 512))
  davidAux = loadDavid(davidAuxFixture([10, 23, 4], 1407, 512))
  andreModel = loadAndre(andreFixture())
  andreStacked = loadAndre(andreFixture(64, 3))
var
  combatData = newSeq[Fixed](25)
  residualData = newSeq[Fixed](31)
  davidData = newSeq[Fixed](1407)
  state, auxState: string
  andreData: array[45, Fixed]
  andreState, stackedState: string
for value in combatData.mitems:
  value = fixed(100)
for value in residualData.mitems:
  value = fixed(100)
for value in davidData.mitems:
  value = 0.5'fx

timeIt "Richard combat 25/16/18":
  keep inferRichard(combat, combatData)
timeIt "Richard residual 31/8/19":
  keep inferRichard(residual, residualData)
timeIt "David recurrent 1407/512/92":
  let next = inferDavid(davidModel, state, davidData)
  state = next.state
  keep next.outputs
timeIt "David recurrent 1407/512/92 with auxiliary heads 10/23/4":
  let next = inferDavid(davidAux, auxState, davidData)
  auxState = next.state
  keep next.aux

timeIt "Andre recurrent 45/12/12, one layer":
  let next = inferAndre(andreModel, andreState, andreData)
  andreState = next.state
  keep next.outputs
timeIt "Andre recurrent 45/64/12, three layers":
  let next = inferAndre(andreStacked, stackedState, andreData)
  stackedState = next.state
  keep next.outputs

block:
  # A synthetic sub-brain the size of the FlyWire v783 cut without vision:
  # 40,619 neurons, 26 incoming edges each, 1,627 driven, 1,276 read.
  const
    Neurons = 40_619
    PerNeuron = 26
    Driven = 1_627
    Read = 1_276
  var bytes = FlyMagic
  for value in [uint32(Neurons), uint32(Neurons * PerNeuron), 45,
      uint32(Driven), uint32(Read), 4]:
    bytes.addWord(value)
  bytes.addWord(cast[uint32](0.5'f))
  for i in 0 .. Neurons:
    bytes.addWord(uint32(i * PerNeuron))
  for i in 0 ..< Neurons * PerNeuron:
    bytes.addWord(uint32((i * 7919) mod Neurons))
  for i in 0 ..< Neurons * PerNeuron:
    bytes.addWord(cast[uint32](if i mod 5 < 3: 0.05'f else: -0.05'f))
  for i in 0 ..< Neurons:
    bytes.addWord(cast[uint32](0.01'f))
  for i in 0 ..< Driven:
    bytes.addWord(uint32(i))
  for i in 0 ..< Driven * 45:
    bytes.addWord(cast[uint32](0.02'f))
  for i in 0 ..< Read:
    bytes.addWord(uint32(Neurons - Read + i))
  for i in 0 ..< Read * 12:
    bytes.addWord(cast[uint32](0.01'f))
  for i in 0 ..< 12:
    bytes.addWord(0)
  let flyModel = loadFly(bytes)
  var
    flyData: array[45, Fixed]
    flyState: string
  for value in flyData.mitems:
    value = 0.5'fx
  timeIt "Fly connectome 40,619 neurons, 1.06M edges, 4 steps":
    let next = inferFly(flyModel, flyState, flyData)
    flyState = next.state
    keep next.outputs
