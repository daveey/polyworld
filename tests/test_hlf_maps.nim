## Heartleaf map generation: determinism, connectivity, and a playable
## village on every seed the generator claims to support.

import
  std/[sets, strformat, strutils],
  vmath,
  polyworld/pathing,
  ../examples/heartleaf/content,
  ../examples/heartleaf/[maps, layouts]

const SeedsUnderTest = 30

echo "Testing map determinism"
block sameSeedSameMap:
  let
    first = generateMap(DefaultSeed)
    second = generateMap(DefaultSeed)
  doAssert first.hash == second.hash, "the same seed produced two maps"
  doAssert first.passable == second.passable
  doAssert first.kinds == second.kinds
  doAssert first.houses == second.houses
  doAssert first.gardenTiles == second.gardenTiles
  doAssert first.hash != 0, "the map fingerprint is empty"

block differentSeedsDifferentMaps:
  var seen: HashSet[uint64]
  for seed in 1'i32 .. 20'i32:
    let map = generateMap(seed)
    doAssert map.hash notin seen, &"seed {seed} collided with another map"
    seen.incl map.hash

echo "Testing connectivity and playability"
block everySeedValidates:
  for seed in 1'i32 .. SeedsUnderTest:
    let map = generateMap(seed)
    map.validateMap()

block doorsHaveContinuousRoads:
  for seed in 1'i32 .. SeedsUnderTest:
    let map = generateMap(seed)
    var reached = newSeq[bool](GridCells)
    var frontier = @[map.houses[0].door]
    reached[tileIndex(frontier[0])] = true
    while frontier.len > 0:
      let tile = frontier.pop()
      for (dx, dy) in StepOffsets:
        let next = tile2(int32(tile.x) + dx, int32(tile.y) + dy)
        if not inGrid(next):
          continue
        let index = tileIndex(next)
        if not reached[index] and map.passable[index] != 0 and
          map.canStep(tile, next) and
          (townRoad(next.x.int32 - 64, next.y.int32 - 64) or
          map.kinds[index] == uint8(StoneTile)):
          reached[index] = true
          frontier.add next
    for house in map.houses:
      doAssert reached[tileIndex(house.door)],
        &"seed {seed}: reaching a house requires leaving the road"

block townLandmarksAreSeparate:
  let map = generateMap(DefaultSeed)
  doAssert map.passable[tileIndex(64, 64)] == 0,
    "the central tree trunk must block movement"
  doAssert map.passable[tileIndex(64 + TownWell.x.int32,
    64 + TownWell.y.int32)] == 0,
    "the southern well must block movement"
  doAssert map.passable[tileIndex(68, 64)] == 1,
    "the paving around the central tree must remain accessible"
  for slot, house in map.houses:
    let offset = houseOffset(slot, 0, 2)
    doAssert house.door == tile2(house.center.x.int32 + offset.x,
      house.center.y.int32 + offset.z)
    doAssert houseYaw(slot) != 0,
      "each cottage must face at a slight angle"
    doAssert map.passable[tileIndex(house.center)] == 0
    let rear = houseOffset(slot, 0, -4)
    doAssert map.passable[tileIndex(
      house.center.x.int32 + rear.x,
      house.center.y.int32 + rear.z)] == 0,
      "The restored round mound must block its rear footprint"
    let shoulder = houseOffset(slot, 0, -6)
    doAssert map.terrain[tileIndex(
      house.center.x.int32 + shoulder.x,
      house.center.y.int32 + shoulder.z)] == 0,
      "the enlarged grassy bank must have a matching solid footprint"

block orchardAndWellHaveThreeLanes:
  let map = generateMap(DefaultSeed)
  for x in [-13'i32, -3'i32, 7'i32]:
    doAssert townRoad(x, 16),
      "the orchard and well need three separate winding corridors"
    doAssert map.passable[tileIndex(64 + x, 80)] == 1
  doAssert not townRoad(-7, 16), "the orchard island must remain planted"
  doAssert not townRoad(2, 16), "the well island must remain planted"
  var
    roads = 0
    asymmetric = 0
  for z in TownMinZ .. TownMaxZ:
    for x in 1'i32 .. TownMaxX:
      let
        left = townRoad(-x, z)
        right = townRoad(x, z)
      if left or right:
        inc roads
      if left != right:
        inc asymmetric
  doAssert asymmetric * 2 > roads,
    "the lane network must not revert to mirrored loops"

echo "Testing sparse tree placement"
block treesAreScattered:
  for seed in 1'i32 .. SeedsUnderTest:
    let trees = borderTrees(seed)
    doAssert trees.len in 16 .. BorderTreeCount, $trees.len
    doAssert trees == borderTrees(seed)
    var variants: HashSet[int]
    for i, tree in trees:
      doAssert abs(tree.x) < 32 and tree.z in -42 .. 50,
        "cropped forest trunks must stay beside the town"
      doAssert not townRoad(tree.x, tree.z)
      doAssert tree.z <= 26 or tree.z >= 40 or abs(tree.x) >= 18,
        "foreground crowns must leave the southern junction visible"
      variants.incl tree.variant
      for j in 0 ..< i:
        let
          dx = tree.x - trees[j].x
          dz = tree.z - trees[j].z
        doAssert dx * dx + dz * dz >= 30
    doAssert variants.len >= 6,
      "the border should vary in crown shape as well as position"

echo "Testing village invariants"
block gridsAreWellFormed:
  let map = generateMap(DefaultSeed)
  doAssert map.passable.len == GridCells
  doAssert map.kinds.len == GridCells
  doAssert map.heights.len == GridCells
  var
    walkable = 0
    forest = 0
    gardens = 0
  for index in 0 ..< GridCells:
    if map.passable[index] == 1:
      inc walkable
    if map.kinds[index] == uint8(TreeTile):
      inc forest
      doAssert map.passable[index] == 0, "a forest tile is walkable"
    if map.kinds[index] == uint8(GardenTileKind):
      inc gardens
  doAssert walkable > 1500,
    &"only {walkable} of {GridCells} tiles are walkable"
  doAssert forest == borderTrees(DefaultSeed).len,
    &"the sparse tree art and collisions disagree: {forest}"
  var existing = 0
  for y in 0'i32 ..< GridSide:
    for x in 0'i32 ..< GridSide:
      let index = tileIndex(x, y)
      if layers[0].tiles[index].exists:
        inc existing
      if not insideTown(x - GridSide div 2, y - GridSide div 2):
        doAssert not layers[0].tiles[index].exists
        doAssert map.passable[index] == 0
  doAssert existing in 4000 .. 4150,
    "the town dimensions must match the calibrated layer footprint"
  doAssert gardens == GardenCount,
    &"the grid holds {gardens} garden tiles, wanted {GardenCount}"

block housesSurroundThePlaza:
  let map = generateMap(DefaultSeed)
  for slot, house in map.houses:
    let ring = chebyshev(house.center, tile2(GridSide div 2, GridSide div 2))
    doAssert ring >= 12 and ring <= 32,
      &"house {slot} sits {ring} tiles from the plaza"
    doAssert chebyshev(house.center, house.door) == HouseFootprint div 2 + 1,
      &"house {slot} has a detached door"
    for other in 0 ..< slot:
      doAssert chebyshev(house.center, map.houses[other].center) > 6,
        &"houses {other} and {slot} overlap"

block gardensBelongToHouses:
  ## Each block of three gardens sits within gathering reach of its house.
  let map = generateMap(DefaultSeed)
  for slot in 0 ..< VillagerCount:
    for i in 0 ..< GardensPerHouse:
      let garden = map.gardenTiles[slot * GardensPerHouse + i]
      doAssert chebyshev(garden, map.houses[slot].center) <= 8,
        &"garden {i} strayed from house {slot}"

echo "Testing that a broken map is actually caught"
block validationRejectsABlockedDoor:
  var map = generateMap(DefaultSeed)
  map.passable[tileIndex(map.houses[0].door)] = 0
  var caught = false
  try:
    map.validateMap()
  except AssertionDefect:
    caught = true
  doAssert caught, "a blocked door passed validation"

block validationRejectsAPavedGarden:
  var map = generateMap(DefaultSeed)
  map.kinds[tileIndex(map.gardenTiles[0])] = 1'u8  # RoadTile
  var caught = false
  try:
    map.validateMap()
  except AssertionDefect:
    caught = true
  doAssert caught, "a paved-over garden passed validation"

echo "test_hlf_maps: all checks passed"
let sample = generateMap(DefaultSeed)
echo "  seed ", DefaultSeed, " mapHash = ", toHex(sample.hash)
