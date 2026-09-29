## Heartleaf ground art: the cobble sheet tiles and carries per-stone
## heights, and the ground mask puts stone on the plaza, dirt on the roads,
## with no extra soil beneath garden pots.

import
  std/strformat,
  pixie,
  polyworld/[common, pathing],
  ../examples/heartleaf/[content, maps, ground]

const Seed = 1988'i32

echo "Testing the cobble sheet"
block sheetShape:
  let sheet = buildCobbleSheet(Seed)
  doAssert sheet.color.width == SheetSize and sheet.color.height == SheetSize
  doAssert sheet.height.width == SheetSize and sheet.height.height == SheetSize
  doAssert sheet.cells.len == SheetSize * SheetSize

block sheetHasStonesAndMortar:
  let sheet = buildCobbleSheet(Seed)
  var
    mortar = 0
    lowStone = 0
  for i, cell in sheet.cells:
    if cell < 0:
      mortar += 1
      doAssert sheet.height.data[i].r == 0, "mortar must have zero height"
    else:
      doAssert sheet.height.data[i].r >= 80,
        &"stone texel {i} is too low to outlast mortar"
      if sheet.height.data[i].r < 120:
        lowStone += 1
  let fraction = mortar.float / sheet.cells.len.float
  doAssert fraction > 0.10 and fraction < 0.35,
    &"mortar covers {fraction * 100:.0f}% of the sheet"
  doAssert lowStone > 0, "no stone landed near the height floor"

block sheetWraps:
  let sheet = buildCobbleSheet(Seed)
  var same = 0
  for y in 0 ..< SheetSize:
    if sheet.cells[y * SheetSize] == sheet.cells[y * SheetSize + SheetSize - 1]:
      same += 1
  for x in 0 ..< SheetSize:
    if sheet.cells[x] == sheet.cells[(SheetSize - 1) * SheetSize + x]:
      same += 1
  let fraction = same.float / (2 * SheetSize).float
  doAssert fraction > 0.7,
    &"only {fraction * 100:.0f}% of the seam texels share a stone"

block curbSheet:
  let sheet = buildCurbSheet(Seed)
  var
    mortar = 0
    highest = -1'i32
  for i, cell in sheet.cells:
    if cell < 0:
      mortar += 1
    else:
      highest = max(highest, cell)
      doAssert sheet.height.data[i].r >= 110,
        &"curb stone texel {i} sits below the curb height floor"
  doAssert highest == CurbStyle.cells * CurbStyle.cells - 1,
    &"curb sheet has {highest + 1} stones"
  let fraction = mortar.float / sheet.cells.len.float
  doAssert fraction > 0.05 and fraction < 0.35,
    &"curb mortar covers {fraction * 100:.0f}% of the sheet"
  doAssert CurbStones mod CurbStyle.cells == 0,
    "the curb stone count must be a multiple of the sheet's cells"

echo "Testing the ground mask"
block maskCoverage:
  let
    map = generateMap(Seed)
    mask = buildGroundMask(map, Seed)
    middle = GridSide div 2
  doAssert mask.len == MaskSize * MaskSize * MaskChannels

  proc texelAt(x, y: int): (uint8, uint8) =
    let index = (y * MaskSize + x) * MaskChannels
    (mask[index], mask[index + 1])

  proc tileTexel(tile: Tile2): (uint8, uint8) =
    texelAt(
      int(tile.x) * MaskTexelsPerTile + MaskTexelsPerTile div 2,
      int(tile.y) * MaskTexelsPerTile + MaskTexelsPerTile div 2)

  let (plazaStone, plazaDirt) = tileTexel(tile2(int32(middle), int32(middle)))
  doAssert plazaStone == 255, &"plaza centre stone coverage is {plazaStone}"
  doAssert plazaDirt == 255, "dirt must underlie the plaza"

  let (farStone, farDirt) = tileTexel(tile2(int32(middle + 40), int32(middle)))
  doAssert farStone == 0 and farDirt == 0,
    &"open meadow carries coverage {farStone}/{farDirt}"

  var roadFound = false
  for y in 0 ..< GridSide:
    for x in 0 ..< GridSide:
      let tile = tile2(int32(x), int32(y))
      if map.kinds[tileIndex(tile)] == uint8(RoadTile) and
          chebyshev(tile, tile2(int32(middle), int32(middle))) > 12:
        let (stone, dirt) = tileTexel(tile)
        doAssert dirt == 255, &"road tile {x},{y} has dirt coverage {dirt}"
        doAssert stone > 0, &"road tile {x},{y} has no cobbles"
        roadFound = true
  doAssert roadFound, "no road tile away from the plaza"

  for house in map.houses:
    let (stone, dirt) = tileTexel(house.center)
    doAssert stone == 255 and dirt == 255,
      &"house {house.center.x},{house.center.y} carries coverage {stone}/{dirt}"
    var feathered = false
    let
      centerX = int(house.center.x) * MaskTexelsPerTile +
        MaskTexelsPerTile div 2
      centerY = int(house.center.y) * MaskTexelsPerTile +
        MaskTexelsPerTile div 2
      reach = 4 * MaskTexelsPerTile
    for y in max(centerY - reach, 0) .. min(centerY + reach, MaskSize - 1):
      for x in max(centerX - reach, 0) .. min(centerX + reach, MaskSize - 1):
        let (coverage, _) = texelAt(x, y)
        if coverage > 0 and coverage < 255:
          feathered = true
    doAssert feathered,
      &"house {house.center.x},{house.center.y} has a hard cobble edge"


block gardensDoNotPaintTerrain:
  var map = generateMap(Seed)
  let original = buildGroundMask(map, Seed)
  for garden in map.gardenTiles:
    map.kinds[tileIndex(garden)] = uint8(GrassTile)
  doAssert buildGroundMask(map, Seed) == original


echo "Testing the reference town's ground mask"
block townCoverage:
  let mask = buildTownGroundMask(Seed)
  doAssert mask.len == MaskSize * MaskSize * MaskChannels

  proc at(x, z: int): (uint8, uint8) =
    ## Samples a world-space tile center in the reference mask.
    let
      tx = (x + GridSide.int div 2) * MaskTexelsPerTile +
        MaskTexelsPerTile div 2
      tz = (z + GridSide.int div 2) * MaskTexelsPerTile +
        MaskTexelsPerTile div 2
      index = (tz * MaskSize + tx) * MaskChannels
    (mask[index], mask[index + 1])

  doAssert at(0, 0) == (0'u8, 0'u8), "The tree bed must remain grassy"
  doAssert at(5, 0) == (255'u8, 255'u8), "The plaza needs cream paving"
  doAssert at(0, -20) == (0'u8, 255'u8), "Lanes must be dirt, not cobble"
  doAssert at(2, 15) == (0'u8, 0'u8), "The well belongs in a garden"
  doAssert at(40, 30) == (0'u8, 0'u8), "Woodland must stay grassy"
  var feathered = 0
  for i in 0 ..< MaskSize * MaskSize:
    if mask[i * MaskChannels + 1] in 1'u8 .. 254'u8:
      inc feathered
  doAssert feathered > 1000, "The golden paths lost their soft edges"

echo "test_hlf_ground: all checks passed"

block referenceLayerRegistration:
  let
    reference = readImage(DataRoot &
      "/terrain/heartleaf/layers/01-grass-and-paths.png")
    mask = buildReferenceGroundMask(reference)
  proc coverage(px, py: int): tuple[stone, dirt: uint8] =
    ## Samples registered reference pixels in the runtime material mask.
    let
      x = int(((px - 560).float32 * 0.044'f + HalfGrid) *
        MaskTexelsPerTile.float32)
      y = int(((py - 650).float32 * 0.057'f + HalfGrid) *
        MaskTexelsPerTile.float32)
      index = (y * MaskSize + x) * MaskChannels
    (mask[index], mask[index + 1])
  doAssert coverage(555, 314).dirt > 180
  doAssert coverage(600, 400).dirt < 30
  doAssert coverage(549, 553).stone > 120
  doAssert coverage(549, 650).stone < 30
  doAssert coverage(549, 650).dirt < 30
  echo "Reference layer paths, plaza and planted islands register correctly."
