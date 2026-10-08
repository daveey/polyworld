## Authored floor geometry mapped into Polyworld's navigation tiles.

import
  vmath,
  polyworld/pathing,
  sim

const
  MapColumns* = (MapWidth + PixelsPerTile - 1) div PixelsPerTile
  MapRows* = (MapHeight + PixelsPerTile - 1) div PixelsPerTile
  MapHalfWidth* = MapWidth.float32 / PixelsPerTile.float32 / 2
  MapHalfDepth* = MapHeight.float32 / PixelsPerTile.float32 / 2

type
  TileKind* = enum
    VoidTile, FloorTile, WallTile
  ShipMap* = object
    tiles*: seq[TileKind]
    layer*: QuadLayer

proc tileIndex*(x, y: int): int =
  ## Returns the flat tile index for one map coordinate.
  y * MapColumns + x

proc worldPoint*(x, y: int, height = 0.0'f): Vec3 =
  ## Converts original pixels into centered Polyworld tile coordinates.
  vec3(
    x.float32 / PixelsPerTile.float32 - MapHalfWidth,
    height,
    y.float32 / PixelsPerTile.float32 - MapHalfDepth
  )

proc buildShipMap*(sim: SimServer): ShipMap =
  ## Builds only usable floor tiles with explicit cardinal navigation links.
  result.tiles = newSeq[TileKind](MapColumns * MapRows)
  result.layer = QuadLayer(
    originX: GridTiles div 2 - MapColumns div 2,
    originZ: GridTiles div 2 - MapRows div 2,
    width: MapColumns, depth: MapRows, slab: true,
    tiles: newSeq[Tile](MapColumns * MapRows)
  )
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      if sim.isWalkable(x, y):
        result.tiles[tileIndex(x div PixelsPerTile, y div PixelsPerTile)] =
          FloorTile
  for y in 0 ..< MapRows:
    for x in 0 ..< MapColumns:
      let index = tileIndex(x, y)
      if result.tiles[index] != FloorTile:
        continue
      result.layer.tiles[index] = Tile(
        tops: [0'i16, 0, 0, 0], bottoms: [-2'i16, -2, -2, -2],
        flags: TileExists, kind: StoneTile
      )
      result.layer.tiles[index].connectedEast =
        x + 1 < MapColumns and result.tiles[index + 1] == FloorTile and
        sim.connectedTiles(x, y, x + 1, y)
      result.layer.tiles[index].connectedSouth =
        y + 1 < MapRows and result.tiles[index + MapColumns] == FloorTile and
        sim.connectedTiles(x, y, x, y + 1)

proc visibleFrom*(sim: SimServer, slot, x, y: int): bool =
  ## Restricts living players to the original nearby view and open corridors.
  if slot < 0:
    return true
  let player = sim.players[slot]
  if not player.alive:
    return true
  let
    dx = x - player.x
    dy = y - player.y
    steps = max(abs(dx), abs(dy))
  if abs(dx) > ScreenWidth div 2 or abs(dy) > ScreenHeight div 2:
    return false
  for i in 1 ..< steps:
    if not sim.isWalkable(player.x + dx * i div steps,
        player.y + dy * i div steps):
        return false
  true

proc taskPoint*(sim: SimServer, task: int): MapPoint =
  ## Finds a reachable pixel inside the original task interaction rectangle.
  let station = sim.tasks[task]
  var best = high(int)
  result = MapPoint(x: -1, y: -1)
  for y in station.y ..< station.y + station.h:
    for x in station.x ..< station.x + station.w:
      if sim.isWalkable(x, y):
        let distance = distSq(
          x, y, station.x + station.w div 2, station.y + station.h div 2
        )
        if distance < best:
          best = distance
          result = MapPoint(x: x, y: y)

proc fitStations*(sim: var SimServer) =
  ## Moves fully blocked station markers to the nearest usable floor pixel.
  for i in 0 ..< sim.tasks.len:
    if sim.taskPoint(i).x >= 0:
      continue
    let
      centerX = sim.tasks[i].x + sim.tasks[i].w div 2
      centerY = sim.tasks[i].y + sim.tasks[i].h div 2
    var found = false
    for radius in 1 .. 32:
      var
        best = high(int)
        target = MapPoint(x: -1, y: -1)
      for dy in -radius .. radius:
        for dx in -radius .. radius:
          if abs(dx) != radius and abs(dy) != radius:
            continue
          if sim.isWalkable(centerX + dx, centerY + dy):
            let distance = dx * dx + dy * dy
            if distance < best:
              best = distance
              target = MapPoint(x: centerX + dx, y: centerY + dy)
      if target.x >= 0:
        sim.tasks[i].x = target.x - sim.tasks[i].w div 2
        sim.tasks[i].y = target.y - sim.tasks[i].h div 2
        found = true
        break
    if not found:
      raise newException(CrewriftError, "No reachable floor near task " & $i)
