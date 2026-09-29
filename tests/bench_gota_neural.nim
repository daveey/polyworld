import
  bassy, benchy,
  ../examples/gods_of_the_arena/neural/[richard, david, andre],
  neuralfixtures

let
  combat = loadRichard(richardFixture())
  residual = loadRichard(richardFixture(true))
  davidModel = loadDavid(davidFixture(1407, 512))
  andreModel = loadAndre(andreFixture())
  andreStacked = loadAndre(andreFixture(64, 3))
var
  combatData = newSeq[Fixed](25)
  residualData = newSeq[Fixed](31)
  davidData = newSeq[Fixed](1407)
  state: string
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

timeIt "Andre recurrent 45/12/12, one layer":
  let next = inferAndre(andreModel, andreState, andreData)
  andreState = next.state
  keep next.outputs
timeIt "Andre recurrent 45/64/12, three layers":
  let next = inferAndre(andreStacked, stackedState, andreData)
  stackedState = next.state
  keep next.outputs
