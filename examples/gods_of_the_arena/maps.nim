## Gods of the Arena map generation.
##
## New matches use the editor's saved preset, packed into integer terrain.
## The simulation reads the resulting terrain without modifying it.

import
  polyworld/[hashes, pathing, profiles],
  arenas

export arenas

const
  GroundLayer* = 0
  RedFortLayer* = 1
  BlueFortLayer* = 2
  WaterLayer* = 3
  RedFortKind* = ArenaWallKinds[0]
  BlueFortKind* = ArenaWallKinds[1]

type MapData* = object
  seed*: int32
  resolution*: int = GridTiles
  hash*: uint64
  preset*: MapConfig
  layout*: ArenaLayout
  minimap*: seq[uint32]
  mainRoads*: seq[bool]

var activeMapResolution = GridTiles

proc mapTiles*(): int {.raises: [].} =
  ## Reads the active map size.
  activeMapResolution

proc mapHalfSize*(): float32 {.raises: [].} =
  ## Returns the world extent of the centered active map.
  mapTiles().float32 / 2

proc mapOrigin*(): int {.raises: [].} =
  ## Locates the centered map inside the engine's shared coordinate grid.
  (GridTiles - mapTiles()) div 2

proc mapFingerprint(): uint64 =
  ## Hashes the packed map and its derived walkability in stable sequence order.
  var hash = HashySeed
  hash.addHashy(layers.len)
  for layerIndex in 0 ..< layers.len:
    let layer {.cursor.} = layers[layerIndex]
    hash.addHashy(layer.originX)
    hash.addHashy(layer.originZ)
    hash.addHashy(layer.width)
    hash.addHashy(layer.depth)
    hash.addHashy(layer.slab)
    hash.addHashy(layer.water)
    for tileIndex, tile in layer.tiles:
      hash.addHashy(uint32(tile.flags))
      hash.addHashy(uint32(tile.kind))
      for value in tile.tops:
        hash.addHashy(value)
      for value in tile.bottoms:
        hash.addHashy(value)
      hash.addHashy(layerWalkable[layerIndex][tileIndex])
  uint64(hash)

var
  battleMapHash*: uint64
  savedArena: ArenaData
  savedPreset: MapConfig
  arenaReady: bool

proc baseArea*(x, z: int): BaseArea {.raises: [].} =
  ## Reads the generated keep or spawn room at an unclamped map coordinate.
  if not arenaReady or x < 0 or z < 0 or
    x >= mapTiles() or z >= mapTiles():
      return OutsideBase
  savedArena.baseAreas[z * mapTiles() + x]

proc generateMap*(
    seed: int32, preset = defaultConfig()
): MapData {.measure.} =
  ## Generates configured terrain with a bounded cache and separate match seed.
  if not arenaReady or savedPreset != preset:
    savedArena = buildArena(preset)
    savedPreset = preset
    arenaReady = true
  installImmutableLayers(savedArena.layers)
  activeMapResolution = savedArena.layers[0].width
  var hash = uint32(mapFingerprint())
  for area in savedArena.baseAreas:
    hash.addHashy(area.ord)
  for points in [savedArena.layout.forts, savedArena.layout.spawns]:
    for point in points:
      hash.addHashy(point.x)
      hash.addHashy(point.z)
  for point in savedArena.layout.camps:
    hash.addHashy(point.x)
    hash.addHashy(point.z)
  for lane in savedArena.layout.towers:
    for team in lane:
      for site in team:
        hash.addHashy(site.position.x)
        hash.addHashy(site.position.z)
        hash.addHashy(site.facing.x)
        hash.addHashy(site.facing.z)
  for site in savedArena.layout.barracks:
    hash.addHashy(site.position.x)
    hash.addHashy(site.position.z)
    hash.addHashy(site.spawn.x)
    hash.addHashy(site.spawn.z)
    hash.addHashy(site.lane)
    hash.addHashy(site.team)
  for team in savedArena.layout.guards:
    for site in team:
      hash.addHashy(site.position.x)
      hash.addHashy(site.position.z)
      hash.addHashy(site.facing.x)
      hash.addHashy(site.facing.z)
  for lane in savedArena.layout.lanes:
    for point in lane:
      hash.addHashy(point.x)
      hash.addHashy(point.z)
  result = MapData(
    seed: seed,
    resolution: savedArena.layers[0].width,
    preset: preset,
    hash: uint64(hash),
    layout: savedArena.layout,
    minimap: savedArena.minimap,
    mainRoads: savedArena.mainRoads
  )
  battleMapHash = result.hash
