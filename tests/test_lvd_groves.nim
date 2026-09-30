import
  std/sets,
  polyworld/pathing,
  ../examples/light_vs_dark/[assets, groves, maps]

echo "Checking generated scenery placement, harvesting, and restoration"
doAssert sceneryGroup(0, 100) == sceneryGroup(31, 100)
doAssert sceneryGroup(0, 100) != sceneryGroup(32, 100)
doAssert sceneryGroup(0, 100) != sceneryGroup(32 * 100, 100)
doAssert sceneryGroup(99 * 100 + 99, 100) < 0
for seed in [2026, 42, 73]:
  let
    map = generateMap(seed.int32)
    tiles = layers[0].tiles
    placements = grovePlacements(map.treeWood, seed, map.forestRocks)
  doAssert placements == grovePlacements(map.treeWood, seed, map.forestRocks)
  doAssert layers[0].tiles == tiles
  var
    treeTiles, rockTiles: HashSet[int]
    wood = newSeq[int16](map.treeWood.len)
  for index, amount in map.treeWood:
    wood[index] = amount
  for placement in placements:
    doAssert placement.variant in 0 ..< BrushVariants
    doAssert placement.scale > 0
    doAssert placement.visible(wood)
    if placement.kind == LightTree:
      doAssert placement.tile notin treeTiles
      treeTiles.incl placement.tile
      let amount = wood[placement.tile]
      wood[placement.tile] = 0
      doAssert not placement.visible(wood)
      wood[placement.tile] = amount
      doAssert placement.visible(wood)
    else:
      doAssert placement.kind == LightRock
      doAssert placement.tile notin rockTiles
      rockTiles.incl placement.tile
      doAssert tiles[placement.tile].kind == RockTile
      doAssert tiles[placement.tile].impassable ==
        (placement.tile.int32 in map.forestRocks)
      doAssert map.treeWood[placement.tile] == 0
  for index, amount in map.treeWood:
    doAssert (index in treeTiles) == (amount > 0)
  doAssert treeTiles.len > 0
  doAssert rockTiles.len > map.forestRocks.len
  doAssert rockTiles.len <= map.forestRocks.len + 80
  doAssert map.forestRocks.len ==
    (treeTiles.len + map.forestRocks.len) div 10
  doAssert wood == map.treeWood
  echo seed, ": ", treeTiles.len, " trees, ", rockTiles.len, " rocks"

echo "Checking the native and browser ground use only generated assets"
doAssert not LvdTerrainAssets.grass and not LvdTerrainAssets.water
doAssert not LvdWebTerrainAssets.grass and not LvdWebTerrainAssets.water

echo "LvD generated scenery passed"
