## Read-only integer terrain queries for hero scripts.

import
  polyworld/[noises, pathing],
  maps

type
  TerrainKind* = enum
    TerrainNone, TerrainGrass, TerrainRoad, TerrainRock,
    TerrainTrees, TerrainMarsh, TerrainWall, TerrainWater

  TerrainField* = enum
    TerrainKindField, TerrainWalkableField,
    TerrainHeightField, TerrainWaterDepthField

proc readTile(layerIndex, mapX, mapY: int32, tile: var Tile): bool =
  ## Reads an existing tile using map coordinates on one exact layer.
  if mapX < 0 or mapX >= mapTiles() or mapY < 0 or mapY >= mapTiles() or
    layerIndex < 0 or layerIndex >= layers.len:
      return false
  let
    layer {.cursor.} = layers[int(layerIndex)]
    x = int(mapX) + mapOrigin() - layer.originX
    y = int(mapY) + mapOrigin() - layer.originZ
  if x < 0 or x >= layer.width or y < 0 or y >= layer.depth:
    return false
  tile = layer.tiles[y * layer.width + x]
  tile.exists

proc heightSum(tile: Tile): int32 =
  ## Keeps the tile-center height exact in quarter height steps.
  for height in tile.tops:
    result += height.int32

proc kindAt(layerIndex, mapX, mapY: int32, tile: Tile): TerrainKind =
  ## Maps visual materials and blocked construction to stable terrain kinds.
  if layers[int(layerIndex)].water:
    return TerrainWater
  let kind = arenaKind(tile.kind)
  case kind
  of TreeTile:
    return TerrainTrees
  of RedFortKind, BlueFortKind:
    return TerrainWall
  of StoneTile:
    if layers[int(layerIndex)].slab:
      return TerrainWall
  else:
    discard
  if tile.impassable:
    # Ground beneath a solid fort is blocked, but an open arch stays a road.
    for i in 0 ..< layers.len:
      let layer {.cursor.} = layers[i]
      if i == int(layerIndex) or not layer.slab or layer.water:
        continue
      var cover: Tile
      if readTile(i.int32, mapX, mapY, cover):
        return TerrainWall
  case kind
  of GrassTile:
    TerrainGrass
  of RoadTile, StoneTile:
    TerrainRoad
  of RockTile:
    TerrainRock
  of MarshTile:
    TerrainMarsh
  else:
    TerrainNone

proc waterDepth(layerIndex, mapX, mapY: int32, tile: Tile): int32 =
  ## Measures center submergence above this surface, rounding positive depth up.
  let surface = tile.heightSum()
  for i in 0 ..< layers.len:
    let layer {.cursor.} = layers[i]
    if not layer.water:
      continue
    var water: Tile
    if not readTile(i.int32, mapX, mapY, water):
      continue
    let waterHeight = water.heightSum()
    var floorHeight = surface
    if layers[int(layerIndex)].water:
      # A water-layer query measures the column above its highest solid bed.
      floorHeight = int32.low
      for j in 0 ..< layers.len:
        let bed {.cursor.} = layers[j]
        if bed.water:
          continue
        var floor: Tile
        if readTile(j.int32, mapX, mapY, floor):
          let height = floor.heightSum()
          if height <= waterHeight:
            floorHeight = max(floorHeight, height)
      if floorHeight == int32.low:
        continue
    let depth = max(waterHeight - floorHeight, 0'i32)
    result = max(result, (depth + 3) div 4)

proc terrainValue*(
    mapX, mapY, layerIndex: int32,
    field: TerrainField
): int32 =
  ## Reads static terrain without fog filtering, path searches, or mutations.
  var tile: Tile
  if not readTile(layerIndex, mapX, mapY, tile):
    return 0
  case field
  of TerrainKindField:
    int32(kindAt(layerIndex, mapX, mapY, tile).ord)
  of TerrainWalkableField:
    let layer {.cursor.} = layers[int(layerIndex)]
    int32(isWalkable(
      int(layerIndex),
      int(mapX) + mapOrigin() - layer.originX,
      int(mapY) + mapOrigin() - layer.originZ
    ))
  of TerrainHeightField:
    int32(roundDivision(tile.heightSum().int64, 4))
  of TerrainWaterDepthField:
    waterDepth(layerIndex, mapX, mapY, tile)
