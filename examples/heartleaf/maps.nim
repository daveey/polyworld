## Heartleaf map generation.
##
## The nine homes and winding lanes follow the supplied village reference.
## Terrain detail varies deterministically with the seed. The simulation uses
## integer road coverage and keeps every home and garden connected.
##
## This module writes the shared `pathing.layers` terrain model once at
## startup and then returns a `MapData` value. The simulation reads only the
## returned value, never the layers, so the renderer's decoration can never
## change how a game plays out.

import
  std/strformat,
  vmath,
  polyworld/[hashes, noises, pathing, profiles],
  content, layouts, obstacles

static:
  doAssert GridSide.int == GridTiles,
    "content and pathing disagree about the size of the map"

const
  MapCenter = GridSide div 2
  TerrainAmplitudeSteps = 6'i32
  VillageFlatRadius = 48'i32
    ## Inside this ring the meadow is pressed almost flat.
  VillageFadeRadius = 58'i32
    ## Between flat and fade the meadow rises back to full height.
  PlazaStoneRadius* = 6'i32
    ## The plaza is a disc of paving this many tiles across from the middle.
  PlazaRoadRadius = 7'i32
    ## A one-tile road apron rings the paving.
  WellRadius* = 1'i32
    ## The tree in the middle of the plaza blocks this far around the
    ## centre tile; nobody walks through it.
  HouseFootprint* = 3'i32
  HouseRadiusSteps = int64(HouseHillRadius * 1000)
  HouseCenterSteps = int64(HouseHillCenterZ * 1000)
  HouseFacadeSteps = int64(HouseMeshOffset.z * 1000) + 750
  HousePadRadius = 2'i32
    ## Corners this close to a house centre sit exactly on the pad.
  HousePadFade = 4'i32
  ForestEdgeRadius* = 44'i32
    ## Retained for the standalone legacy decoration experiments.
  ForestWallRadius* = 58'i32
    ## Retained for the standalone legacy decoration experiments.
  GenerationAttempts = 8
  GroundNoiseStream = 0xA0761D6478BD642F'u64
  GroundDetailStream = 0xE7037ED1A0B428DB'u64
  CornerSide = GridSide + 1


type
  House* = object
    center*: Tile2
      ## Anchor tile of the cottage mound.
    door*: Tile2
      ## The walkable doorstep tile in front of the cottage mound.
    facingX*, facingY*: int8
      ## Unit direction from the footprint toward the door.
    propKind*: uint8
      ## Which house model the renderer stands on the pad.

  MapData* = object
    seed*: int32
    passable*: seq[uint8]
      ## Walkability per tile: slope, houses, and forest included. Nothing
      ## changes walkability after generation.
    terrain*: seq[uint8]
      ## Ground clearance before props, for precise movement through gates.
    kinds*: seq[uint8]
      ## Tile kind per cell, for gardens, the minimap, and debugging.
    heights*: seq[int16]
      ## Mean packed terrain height per tile.
    obstacles*: seq[Obstacle]
    steps*: seq[uint8]
      ## Eight outgoing links per tile, including clearance past thin fences.
    houses*: array[VillagerCount, House]
    gardenTiles*: array[GardenCount, Tile2]
    hash*: uint64

const StepOffsets* = [
  (0'i32, -1'i32), (1'i32, -1'i32), (1'i32, 0'i32), (1'i32, 1'i32),
  (0'i32, 1'i32), (-1'i32, 1'i32), (-1'i32, 0'i32), (-1'i32, -1'i32)
]
  ## Neighbour scan order, clockwise from north. Fixed everywhere so that
  ## tie-breaking in pathing and flood fill is reproducible.

proc centerDistance(x, y: int32): int32 =
  ## King-move distance from the middle of the map.
  max(abs(x - MapCenter), abs(y - MapCenter))

proc centerDistanceSquared(x, y: int32): int32 =
  ## Squared straight-line distance from the middle of the map.
  (x - MapCenter) * (x - MapCenter) + (y - MapCenter) * (y - MapCenter)

proc propsClear*(map: MapData, first, last: Tile2): bool =
  ## Checks continuous clearance between two tile centers in the town.
  map.obstacles.obstaclesClear(
    (first.x.int32 - MapCenter) * ObstacleUnits,
    (first.y.int32 - MapCenter) * ObstacleUnits,
    (last.x.int32 - MapCenter) * ObstacleUnits,
    (last.y.int32 - MapCenter) * ObstacleUnits,
    NavigationClearance
  )

proc canStep*(map: MapData, first, last: Tile2): bool =
  ## Reads a precomputed connection without crossing rails or blocked corners.
  if not inGrid(first) or not inGrid(last):
    return false
  let
    dx = last.x.int32 - first.x.int32
    dz = last.y.int32 - first.y.int32
  for i, offset in StepOffsets:
    if dx == offset[0] and dz == offset[1]:
      return (map.steps[tileIndex(first)] and (1'u8 shl i)) != 0
  false

## Generation

proc buildMap(seed: int32): MapData =
  ## Builds the terrain layers and village for one seed. May produce an
  ## unplayable layout on unlucky seeds; `generateMap` retries.
  var houses: array[VillagerCount, House]
  for slot, position in TownHouses:
    let
      centerX = MapCenter + position[0].int32
      centerY = MapCenter + position[1].int32
      doorway = houseOffset(slot, 0, 2)
    houses[slot] = House(
      center: tile2(centerX, centerY),
      door: tile2(centerX + doorway.x, centerY + doorway.z),
      facingX: 0,
      facingY: 1,
      propKind: slot.uint8
    )

  ## Heights. Corner height is a pure function of the corner coordinate, so
  ## tiles that share a corner always agree and the surface grows no walls.
  proc ground(cx, cz: int): int32 =
    let value =
      valueNoise(seed, GroundNoiseStream, cx, cz, 24) * 3 +
      valueNoise(seed, GroundDetailStream, cx, cz, 9)
    int32(roundDivision(
      int64(value) * TerrainAmplitudeSteps,
      int64(MapBlendScale) * 4
    ))

  proc villageFlatten(cx, cz: int32): int32 =
    ## How strongly a corner is pressed toward the flat village floor.
    let ring = centerDistance(cx, cz)
    smoothstep(
      int32(VillageFadeRadius - ring) * MapBlendScale div
        (VillageFadeRadius - VillageFlatRadius)
    )

  proc meadowCorner(cx, cz: int32): int32 =
    ## Meadow height after the village press, before house pads.
    blendHeight(ground(int(cx), int(cz)), 0, villageFlatten(cx, cz))

  var padHeights: array[VillagerCount, int32]
  for slot in 0 ..< VillagerCount:
    padHeights[slot] = meadowCorner(
      int32(houses[slot].center.x), int32(houses[slot].center.y))

  proc makeCorner(cx, cz: int32): int32 =
    result = meadowCorner(cx, cz)
    for slot in 0 ..< VillagerCount:
      let reach = max(
        abs(cx - int32(houses[slot].center.x)),
        abs(cz - int32(houses[slot].center.y)))
      if reach <= HousePadFade:
        let amount = smoothstep(
          int32(HousePadFade - reach) * MapBlendScale div
            (HousePadFade - HousePadRadius)
        )
        result = blendHeight(result, padHeights[slot], amount)

  var cornerHeights = newSeq[int16](CornerSide * CornerSide)
  for cz in 0 .. GridSide.int:
    for cx in 0 .. GridSide.int:
      cornerHeights[cz * CornerSide + cx] =
        int16(makeCorner(int32(cx), int32(cz)))
  template corner(cx, cz: int32): int32 =
    int32(cornerHeights[int(cz) * CornerSide.int + int(cx)])

  var groundLayer = QuadLayer(
    originX: 0, originZ: 0,
    width: GridSide, depth: GridSide,
    slab: false,
    tiles: newSeq[Tile](GridCells)
  )
  template groundTile(x, y: int32): var Tile =
    groundLayer.tiles[int(y) * GridSide.int + int(x)]

  for y in 0'i32 ..< GridSide:
    for x in 0'i32 ..< GridSide:
      if not insideTown(x - MapCenter, y - MapCenter):
        continue
      groundTile(x, y) = Tile(
        flags: TileExists or TileConnectedEast or TileConnectedSouth,
        kind: GrassTile,
        tops: packedHeights([
          corner(x, y), corner(x + 1, y),
          corner(x, y + 1), corner(x + 1, y + 1)])
      )

  ## Plaza: a round stone heart with a road apron.
  for y in MapCenter - PlazaRoadRadius .. MapCenter + PlazaRoadRadius:
    for x in MapCenter - PlazaRoadRadius .. MapCenter + PlazaRoadRadius:
      let distance = centerDistanceSquared(x, y)
      if distance <= PlazaStoneRadius * PlazaStoneRadius:
        groundTile(x, y).kind = StoneTile
      elif distance <= PlazaRoadRadius * PlazaRoadRadius:
        groundTile(x, y).kind = RoadTile
  ## The central tree blocks its trunk footprint.
  for y in MapCenter - WellRadius .. MapCenter + WellRadius:
    for x in MapCenter - WellRadius .. MapCenter + WellRadius:
      groundTile(x, y).impassable = true

  ## House footprints: impassable pads the houses stand on.
  for slot in 0 ..< VillagerCount:
    let
      center = houses[slot].center
      turn = HouseTurns[slot]
      anchor = houseAnchor(slot)
    for dz in -9'i32 .. 9'i32:
      for dx in -9'i32 .. 9'i32:
        let
          px = dx.int64 * 1000 + TownHouses[slot][0] * 1000 - anchor.x
          pz = dz.int64 * 1000 + TownHouses[slot][1] * 1000 - anchor.z
          localX = (turn[0].int64 * px + turn[1].int64 * pz) div 1000
          localZ = (-turn[1].int64 * px + turn[0].int64 * pz) div 1000
          depth = localZ - HouseCenterSteps
        if localZ <= HouseFacadeSteps and
          localX * localX + depth * depth <=
          HouseRadiusSteps * HouseRadiusSteps:
            let
              x = center.x.int32 + dx
              y = center.y.int32 + dz
            groundTile(x, y).kind = HouseTileKind
            groundTile(x, y).impassable = true

  ## Lanes follow the same centerlines used by the terrain material mask.
  for y in 0'i32 ..< GridSide:
    for x in 0'i32 ..< GridSide:
      if groundTile(x, y).exists and
        townRoad(x - MapCenter, y - MapCenter) and
        not groundTile(x, y).impassable and
        groundTile(x, y).kind != StoneTile:
          groundTile(x, y).kind = RoadTile

  ## The well garden is south of the central tree plaza.
  for y in MapCenter + TownWell.y.int32 - 1 ..
      MapCenter + TownWell.y.int32 + 1:
    for x in MapCenter + TownWell.x.int32 - 1 ..
        MapCenter + TownWell.x.int32 + 1:
      groundTile(x, y).impassable = true

  layers = @[groundLayer]
  computeWalkable()
  var terrain = newSeq[uint8](GridCells)
  for i in 0 ..< GridCells:
    terrain[i] = uint8(layerWalkable[0][i])
  let solidProps = villageObstacles(seed)
  for y in 0'i32 ..< GridSide:
    for x in 0'i32 ..< GridSide:
      let
        px = (x - MapCenter) * ObstacleUnits
        pz = (y - MapCenter) * ObstacleUnits
      if not solidProps.obstaclesClear(px, pz, px, pz, NavigationClearance):
        groundTile(x, y).impassable = true
  for tree in borderTrees(seed):
    groundTile(MapCenter + tree.x, MapCenter + tree.z).kind = TreeTile

  layers = @[groundLayer]
  computeWalkable()

  ## Derived grids.
  var map = MapData(
    seed: seed,
    passable: newSeq[uint8](GridCells),
    kinds: newSeq[uint8](GridCells),
    heights: newSeq[int16](GridCells),
    houses: houses,
    obstacles: solidProps,
    terrain: terrain,
    steps: newSeq[uint8](GridCells)
  )
  for y in 0'i32 ..< GridSide:
    for x in 0'i32 ..< GridSide:
      let index = tileIndex(x, y)
      map.passable[index] = uint8(isWalkable(0, int(x), int(y)))
      map.kinds[index] = uint8(groundLayer.tiles[index].kind)
      let tops = groundLayer.tiles[index].tops
      map.heights[index] = int16(
        (int32(tops[0]) + int32(tops[1]) +
          int32(tops[2]) + int32(tops[3])) div 4
      )

  ## Three accessible planter beds sit beside each home's front approach.
  var placed = 0
  for slot, house in houses:
    for local in HouseGardenOffsets:
      let
        offset = gardenOffset(slot, local[0], local[1])
        garden = tile2(
          house.center.x.int32 + offset[0],
          house.center.y.int32 + offset[1]
        )
        index = tileIndex(garden)
      map.gardenTiles[placed] = garden
      map.kinds[index] = GardenTileKind.uint8
      groundLayer.tiles[index].kind = GardenTileKind
      inc placed

  for y in 0'i32 ..< GridSide:
    for x in 0'i32 ..< GridSide:
      let first = tile2(x, y)
      if map.passable[tileIndex(first)] == 0:
        continue
      for i, (dx, dz) in StepOffsets:
        let last = tile2(x + dx, y + dz)
        if not inGrid(last) or map.passable[tileIndex(last)] == 0:
          continue
        if dx != 0 and dz != 0 and
          (map.terrain[tileIndex(x + dx, y)] == 0 or
          map.terrain[tileIndex(x, y + dz)] == 0):
            continue
        if map.propsClear(first, last):
          map.steps[tileIndex(first)] =
            map.steps[tileIndex(first)] or (1'u8 shl i)

  ## Fingerprint. Covers the packed terrain, walkability, and every village
  ## placement, so a generator change is caught at replay load rather than
  ## as a mysterious divergence later.
  var hash = HashySeed
  hash.addHashy(seed)
  hash.addHashy(layers.len)
  for layerIndex, layer in layers:
    for index, tile in layer.tiles:
      hash.addHashy(uint32(tile.flags))
      hash.addHashy(uint32(tile.kind))
      for value in tile.tops:
        hash.addHashy(value)
      hash.addHashy(layerWalkable[layerIndex][index])
  for index in 0 ..< GridCells:
    hash.addHashy(map.passable[index])
    hash.addHashy(map.kinds[index])
    hash.addHashy(map.heights[index])
    hash.addHashy(map.steps[index])
    hash.addHashy(map.terrain[index])
  for obstacle in map.obstacles:
    hash.addHashy(obstacle.kind.uint8)
    hash.addHashy(obstacle.ax)
    hash.addHashy(obstacle.az)
    hash.addHashy(obstacle.bx)
    hash.addHashy(obstacle.bz)
    hash.addHashy(obstacle.radius)
  for house in map.houses:
    hash.addHashy(house.center.x)
    hash.addHashy(house.center.y)
    hash.addHashy(house.door.x)
    hash.addHashy(house.door.y)
    hash.addHashy(house.facingX)
    hash.addHashy(house.facingY)
    hash.addHashy(house.propKind)
  hash.addHashy(placed)
  for garden in map.gardenTiles:
    hash.addHashy(garden.x)
    hash.addHashy(garden.y)
  map.hash = uint64(hash)
  map

## Checks
##
## Every one names the seed, so a bad seed is instantly reproducible.

proc floodFrom(map: MapData, start: Tile2): seq[uint8] =
  ## Eight-neighbour integer flood fill over passable tiles.
  result = newSeq[uint8](GridCells)
  if not inGrid(start) or map.passable[tileIndex(start)] == 0:
    return
  var frontier = @[start]
  result[tileIndex(start)] = 1
  while frontier.len > 0:
    let tile = frontier.pop()
    for (dx, dy) in StepOffsets:
      let
        nextX = int32(tile.x) + dx
        nextY = int32(tile.y) + dy
      if not inGrid(nextX, nextY):
        continue
      let index = tileIndex(nextX, nextY)
      if map.passable[index] == 0 or result[index] == 1:
        continue
      if not map.canStep(tile, tile2(nextX, nextY)):
        continue
      result[index] = 1
      frontier.add tile2(nextX, nextY)

const PlazaStart = tile2(MapCenter + WellRadius + 1, MapCenter)
  ## Where connectivity checks begin: the plaza paving just east of the
  ## tree, since the trunk itself is blocked.

proc mapPlayable(map: MapData): bool =
  ## Quietly checks connectivity, for the retry loop.
  let reached = map.floodFrom(PlazaStart)
  for house in map.houses:
    if not inGrid(house.door) or reached[tileIndex(house.door)] == 0:
      return false
  for garden in map.gardenTiles:
    if not inGrid(garden) or reached[tileIndex(garden)] == 0:
      return false
    if map.kinds[tileIndex(garden)] != uint8(GardenTileKind):
      return false
  true

proc generateMap*(seed: int32): MapData {.measure.} =
  ## Builds the village for one seed, retrying deterministically on layouts
  ## the flood fill rejects. Writes the shared `pathing.layers` and
  ## refreshes walkability once per attempt.
  for attempt in 0 ..< GenerationAttempts:
    result = buildMap(seed + int32(attempt) * 7919)
    if result.mapPlayable():
      return
  raise newException(ValueError,
    &"seed {seed}: no playable village in {GenerationAttempts} attempts")

proc validateMap*(map: MapData) =
  ## Asserts that a generated map is connected and playable.
  let seed = map.seed
  let reached = map.floodFrom(PlazaStart)
  doAssert reached[tileIndex(PlazaStart)] == 1,
    &"seed {seed}: the plaza itself is blocked"
  for slot, house in map.houses:
    doAssert inGrid(house.door),
      &"seed {seed}: house {slot} has an off-map door"
    doAssert map.passable[tileIndex(house.door)] == 1,
      &"seed {seed}: house {slot} has a blocked door"
    doAssert reached[tileIndex(house.door)] == 1,
      &"seed {seed}: house {slot} is unreachable from the plaza"
    doAssert house.facingX == 0 or house.facingY == 0,
      &"seed {seed}: house {slot} faces diagonally"
    doAssert map.passable[tileIndex(house.center)] == 0,
      &"seed {seed}: house {slot} footprint is walkable"
  for index, garden in map.gardenTiles:
    doAssert inGrid(garden),
      &"seed {seed}: garden {index} is off the map"
    doAssert map.kinds[tileIndex(garden)] == uint8(GardenTileKind),
      &"seed {seed}: garden {index} lost its plot"
    doAssert map.passable[tileIndex(garden)] == 1,
      &"seed {seed}: garden {index} is not walkable"
    doAssert reached[tileIndex(garden)] == 1,
      &"seed {seed}: garden {index} is unreachable from the plaza"
    for other in 0 ..< index:
      doAssert chebyshev(map.gardenTiles[other], garden) > 1,
        &"seed {seed}: gardens {other} and {index} touch"
