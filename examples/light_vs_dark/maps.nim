import
  std/strformat,
  fixxy,
  polyworld/[hashes, noises, pathing, rngs],
  content

const
  MaximumMapSide* = 4096'i32
  StepOffsets* = [
    (0'i32, -1'i32), (1'i32, -1'i32), (1'i32, 0'i32), (1'i32, 1'i32),
    (0'i32, 1'i32), (-1'i32, 1'i32), (-1'i32, 0'i32), (-1'i32, -1'i32)
  ]
  HallFootprint = BuildingTable[TownHallBuilding].footprint
  MineFootprint = BuildingTable[GoldMineBuilding].footprint

type
  LvdError* = object of CatchableError
  MapLayout* = enum
    SpokeLayout, RandomLayout
  MapSettings* = object
    layout*: MapLayout = SpokeLayout
    size*: int32 = DefaultMapSize
      ## Baseline side length for two players, grown to preserve spacing.
    expansions*: int32 = 2
    minDistance*: int32 = DefaultSpawnDistance
  NodeKind* = enum
    SpawnNode, ExpansionNode
  MapNode* = object
    kind*: NodeKind
    player*: int32
    centre*: Tile2
    parent*: int32
      ## Spawn node index for expansions, or -1 for spawns.
  MineSpot* = object
    id*: int32
    origin*: Tile2
    gold*: int32
  MapData* = object
    seed*, side*: int32
    settings*: MapSettings
    nodes*: seq[MapNode]
    terrain*: seq[QuadLayer]
      ## Terrain geometry used by pathing and the renderer.
    passable*, kinds*: seq[uint8]
    heights*, treeWood*: seq[int16]
    forestRocks*: seq[int32]
    mines*: seq[MineSpot]
    hallOrigin*: seq[Tile2]
    hash*: uint64

proc validate*(settings: MapSettings, players: int) =
  ## Rejects invalid settings before sizing or allocating terrain.
  if players < 1:
    raise newException(LvdError, "A match needs at least one player.")
  if settings.size < 32 or settings.size > MaximumMapSide:
    raise newException(LvdError, "Map size must be between 32 and 4096.")
  if settings.expansions < 0 or
    int64(players) * (int64(settings.expansions) + 1) >
      LastMineId - FirstMineId + 1:
      raise newException(LvdError, "Invalid expansion count for this roster.")
  if settings.minDistance < 1 or settings.minDistance > MaximumMapSide:
    raise newException(LvdError, "Minimum spawn distance must be 1 .. 4096.")

proc inGrid*(map: MapData, x, y: int32): bool =
  ## Checks coordinates against this map's actual dimensions.
  x >= 0 and y >= 0 and x < map.side and y < map.side

proc inGrid*(map: MapData, tile: Tile2): bool =
  ## Checks a tile against this map's actual dimensions.
  map.inGrid(int32(tile.x), int32(tile.y))

proc tileIndex*(map: MapData, x, y: int32): int32 =
  ## Returns a row-major index using this map's stride.
  y * map.side + x

proc tileIndex*(map: MapData, tile: Tile2): int32 =
  ## Returns a row-major index for a tile on this map.
  map.tileIndex(int32(tile.x), int32(tile.y))

proc distanceSquared(first, second: Tile2): int64 =
  ## Measures separation without floating point or square roots.
  let
    dx = int64(first.x) - int64(second.x)
    dy = int64(first.y) - int64(second.y)
  dx * dx + dy * dy

proc ringPoint(centre: Tile2, radius: int32, angle: Fixed): Tile2 =
  ## Places one point on a deterministic fixed-point ring.
  let offset = direction(angle) * fixed(radius)
  tile2(int32(centre.x) + toInt(round(offset.x)),
    int32(centre.y) + toInt(round(offset.y)))

proc placeNodes(seed: int32, players: int, settings: MapSettings): MapData =
  ## Places spawn clusters with bounded random retries and automatic growth.
  settings.validate(players)
  let
    expansionRadius = max(18'i32, settings.expansions * 3)
    margin = 12'i32
    spacing = max(settings.minDistance, margin * 2 + 2)
    scaledArea = int64(settings.size) * settings.size * max(players, 2) div 2
  var side = int32(integerSqrt(scaledArea))
  if int64(side) * side < scaledArea:
    inc side
  side = max(side, margin * 2 + 1)
  if side > MaximumMapSide:
    raise newException(LvdError, "Roster requires more than 4096 tiles.")
  if settings.layout == SpokeLayout and players > 1:
    let
      angle = Fixed(int32(int64(int32(FixedPi)) div players))
      sine = int64(int32(sin(angle)))
      radius = (int64(spacing + 2) * 65536 + sine * 2 - 1) div
        (sine * 2)
    side = max(side, int32(radius * 2 + margin * 2 + 2))
  side += side mod 2
  var rng = initRng(seed, 0x9E3779B97F4A7C15'u64)
  for attempt in 0 ..< 16:
    if side > MaximumMapSide:
      raise newException(LvdError,
        "Roster and spacing require a map larger than 4096 tiles.")
    var spawns: seq[Tile2]
    let
      centre = tile2(side div 2, side div 2)
      radius = side div 2 - margin
      rotation = rng.below(int32(FixedTau))
      spokeJitter = int32(FixedTau) div int32(players) div 6
    for player in 0 ..< players:
      for trial in 0 ..< 512:
        let candidate =
          case settings.layout
          of SpokeLayout:
            if players == 1:
              centre
            else:
              let angle = rotation +
                int32(int64(int32(FixedTau)) * player div players) +
                rng.between(-spokeJitter, spokeJitter)
              ringPoint(
                centre,
                rng.between(radius * 4 div 5, radius),
                Fixed(angle)
              )
          of RandomLayout:
            tile2(
              rng.between(margin, side - margin - 1),
              rng.between(margin, side - margin - 1)
            )
        var separated = true
        for other in spawns:
          if distanceSquared(candidate, other) < int64(spacing) * spacing:
            separated = false
            break
        if separated:
          spawns.add candidate
          break
      if spawns.len != player + 1:
        break
    if spawns.len == players:
      result = MapData(seed: seed, side: side, settings: settings)
      proc expansionFits(candidate: Tile2, nodes: seq[MapNode]): bool =
        ## Keeps mines inside the map and clear of every starting structure.
        let
          x = int32(candidate.x)
          y = int32(candidate.y)
          origin = tile2(x - 1, y - 1)
        if x < 6 or y < 6 or x >= side - 6 or y >= side - 6:
          return false
        proc overlaps(other: Tile2, footprint: Footprint): bool =
          ## Leaves two walkable tiles between neighboring footprints.
          int32(origin.x) < int32(other.x) + footprint.width + 2 and
            int32(origin.x) + MineFootprint.width + 2 > int32(other.x) and
            int32(origin.y) < int32(other.y) + footprint.depth + 2 and
            int32(origin.y) + MineFootprint.depth + 2 > int32(other.y)
        for spawn in spawns:
          if distanceSquared(candidate, spawn) < 14 * 14:
            return false
          if overlaps(
            tile2(
              int32(spawn.x) - HallFootprint.width div 2,
              int32(spawn.y) - HallFootprint.depth div 2
            ),
            HallFootprint
          ) or overlaps(
            tile2(int32(spawn.x) + 7, int32(spawn.y) - 1),
            MineFootprint
          ):
            return false
        for node in nodes:
          if node.kind == ExpansionNode and overlaps(
            tile2(int32(node.centre.x) - 1, int32(node.centre.y) - 1),
            MineFootprint
          ):
            return false
        true
      var placed = true
      for player, centre in spawns:
        let parent = int32(result.nodes.len)
        result.nodes.add MapNode(
          kind: SpawnNode, player: int32(player), centre: centre, parent: -1
        )
        result.hallOrigin.add tile2(
          int32(centre.x) - HallFootprint.width div 2,
          int32(centre.y) - HallFootprint.depth div 2
        )
        for i in 0 ..< settings.expansions:
          placed = false
          for trial in 0 ..< 512:
            let candidate = ringPoint(
              centre,
              rng.between(14, expansionRadius),
              Fixed(rng.below(int32(FixedTau)))
            )
            if expansionFits(candidate, result.nodes):
              result.nodes.add MapNode(
                kind: ExpansionNode,
                player: int32(player),
                centre: candidate,
                parent: parent
              )
              placed = true
              break
          if not placed:
            break
        if not placed:
          break
      if placed:
        return
    side += max(16'i32, side div 4)
    side += side mod 2
  raise newException(LvdError, "Could not place separated spawn zones.")

proc mapProblem*(map: MapData): string =
  ## Checks footprints, opening space, resources, and connected approaches.
  if map.side < 1 or map.side > MaximumMapSide or map.hallOrigin.len == 0:
    return "Invalid map dimensions or roster."
  let cells = int(map.side * map.side)
  if map.passable.len != cells or map.kinds.len != cells or
    map.heights.len != cells or map.treeWood.len != cells:
      return "Map grids do not match its dimensions."
  if map.nodes.len != map.hallOrigin.len * (map.settings.expansions + 1) or
    map.mines.len != map.nodes.len:
      return "Map must have one main mine and N expansions per player."
  var occupied = newSeq[bool](cells)
  proc reserve(origin: Tile2, size: Footprint): bool =
    ## Checks and reserves an open, nonoverlapping structure footprint.
    for y in int32(origin.y) ..< int32(origin.y) + size.depth:
      for x in int32(origin.x) ..< int32(origin.x) + size.width:
        if not map.inGrid(x, y):
          return false
        let index = map.tileIndex(x, y)
        if occupied[index] or map.passable[index] == 0 or
          map.treeWood[index] > 0:
            return false
        occupied[index] = true
    true
  for hall in map.hallOrigin:
    if not reserve(hall, HallFootprint):
      return "Town hall overlaps blocked terrain or another structure."
  for i, mine in map.mines:
    if mine.id != FirstMineId + int32(i) or mine.gold <= 0 or
      not reserve(mine.origin, MineFootprint):
        return "Invalid or obstructed gold mine."
  proc open(x, y: int32): bool =
    ## Includes terrain, forests, and starting structures in connectivity.
    if not map.inGrid(x, y):
      return false
    let index = map.tileIndex(x, y)
    map.passable[index] == 1 and map.treeWood[index] == 0 and
      not occupied[index]
  proc approach(origin: Tile2, size: Footprint): Tile2 =
    ## Finds a free tile touching a structure.
    for y in int32(origin.y) - 1 .. int32(origin.y) + size.depth:
      for x in int32(origin.x) - 1 .. int32(origin.x) + size.width:
        if open(x, y):
          return tile2(x, y)
    tile2(-1, -1)
  let start = approach(map.hallOrigin[0], HallFootprint)
  if not map.inGrid(start):
    return "Starting town is blocked."
  var
    reached = newSeq[bool](cells)
    frontier = @[start]
  reached[map.tileIndex(start)] = true
  while frontier.len > 0:
    let tile = frontier.pop()
    for (dx, dy) in [(1'i32, 0'i32), (-1'i32, 0'i32),
      (0'i32, 1'i32), (0'i32, -1'i32)]:
        let
          x = int32(tile.x) + dx
          y = int32(tile.y) + dy
        if open(x, y) and not reached[map.tileIndex(x, y)]:
          reached[map.tileIndex(x, y)] = true
          frontier.add tile2(x, y)
  for player, hall in map.hallOrigin:
    let tile = approach(hall, HallFootprint)
    if not map.inGrid(tile) or not reached[map.tileIndex(tile)]:
      return &"Player {player} cannot reach the other towns."
    var
      free = 0
      wood = 0
    for y in int32(hall.y) - 22 .. int32(hall.y) + 22:
      for x in int32(hall.x) - 22 .. int32(hall.x) + 22:
        if not map.inGrid(x, y):
          continue
        if map.treeWood[map.tileIndex(x, y)] > 0:
          inc wood
        if x >= int32(hall.x) - 2 and
          x < int32(hall.x) + HallFootprint.width + 2 and
          y >= int32(hall.y) - 2 and
          y < int32(hall.y) + HallFootprint.depth + 2 and open(x, y):
            inc free
    if free < StartingPeons or wood < 40:
      return &"Player {player} lacks opening space or nearby wood."
  for mine in map.mines:
    let tile = approach(mine.origin, MineFootprint)
    if not map.inGrid(tile) or not reached[map.tileIndex(tile)]:
      return "Expansion mine is unreachable."
  var spawns: seq[Tile2]
  for node in map.nodes:
    if node.kind == SpawnNode:
      for other in spawns:
        if distanceSquared(node.centre, other) <
          int64(map.settings.minDistance) * map.settings.minDistance:
            return "Spawn zones violate the minimum distance."
      spawns.add node.centre

proc validateMap*(map: MapData) =
  ## Reports an invalid map even when assertions are disabled.
  let problem = map.mapProblem()
  if problem.len > 0:
    raise newException(LvdError, &"Seed {map.seed}: {problem}")

proc generateMap*(
  seed: int32, players = DefaultPlayerCount, settings = MapSettings()
): MapData =
  ## Builds terrain around a connected graph of spawn and expansion nodes.
  var map = placeNodes(seed, players, settings)
  let
    side = map.side
    cells = int(side * side)
  var
    clear = newSeq[bool](cells)
    roadRng = initRng(seed, 0xC6BC279692B5CC83'u64)
  proc clearing(centre: Tile2, radius: int32) =
    ## Reserves a square clearing for a zone or corridor.
    for y in max(1'i32, int32(centre.y) - radius) ..
      min(side - 2, int32(centre.y) + radius):
        for x in max(1'i32, int32(centre.x) - radius) ..
          min(side - 2, int32(centre.x) + radius):
            clear[map.tileIndex(x, y)] = true
  proc connect(first, second: Tile2) =
    ## Carves a gently winding road that meets both nodes without a kink.
    if first == second:
      return
    let
      dx = int32(second.x) - int32(first.x)
      dy = int32(second.y) - int32(first.y)
      steps = chebyshev(first, second)
      length = int32(integerSqrt(distanceSquared(first, second)))
      amplitude = clamp(length div 8, 3'i32, 8'i32)
      wavelength = roadRng.between(32, 56)
      stream = roadRng.next()
      taper = max(1'i32, min(16'i32, steps div 2))
      divisor = int64(length) * MapBlendScale * MapBlendScale
    for i in 0 .. steps:
      let
        envelope = smoothstep(min(i, steps - i) * MapBlendScale div taper)
        bend = int64(valueNoise(seed, stream, int(i), 0, int(wavelength))) *
          amplitude * envelope
        x = int32(first.x) + int32(roundDivision(int64(dx) * i, steps)) -
          int32(roundDivision(int64(dy) * bend, divisor))
        y = int32(first.y) + int32(roundDivision(int64(dy) * i, steps)) +
          int32(roundDivision(int64(dx) * bend, divisor))
      clearing(tile2(x, y), 3)
  let centre = tile2(side div 2, side div 2)
  clearing(centre, 14)
  for node in map.nodes:
    clearing(node.centre, if node.kind == SpawnNode: 11 else: 5)
    connect(node.centre,
      if node.parent < 0: centre else: map.nodes[node.parent].centre)
    let origin =
      if node.kind == SpawnNode:
        tile2(int32(node.centre.x) + 7, int32(node.centre.y) - 1)
      else:
        tile2(int32(node.centre.x) - 1, int32(node.centre.y) - 1)
    map.mines.add MineSpot(
      id: FirstMineId + int32(map.mines.len),
      origin: origin,
      gold: if node.kind == SpawnNode: MainMineGold else: ExpansionMineGold
    )
  var groves = newSeq[bool](cells)
  for node in map.nodes:
    if node.kind != SpawnNode:
      continue
    for y in max(1'i32, int32(node.centre.y) - 19) ..
      min(side - 2, int32(node.centre.y) + 19):
        for x in max(1'i32, int32(node.centre.x) - 19) ..
          min(side - 2, int32(node.centre.x) + 19):
            if chebyshev(tile2(x, y), node.centre) >= 14:
              groves[map.tileIndex(x, y)] = true
  var corners = newSeq[int16](int((side + 1) * (side + 1)))
  for y in 0 .. side:
    for x in 0 .. side:
      corners[y * (side + 1) + x] = int16(
        valueNoise(seed, 0xA0761D6478BD642F'u64, int(x), int(y), 16) *
          4 div MapBlendScale
      )
  var ground = QuadLayer(
    originX: GridTiles div 2 - int(side) div 2,
    originZ: GridTiles div 2 - int(side) div 2,
    width: side, depth: side, tiles: newSeq[Tile](cells)
  )
  map.passable = newSeq[uint8](cells)
  map.kinds = newSeq[uint8](cells)
  map.heights = newSeq[int16](cells)
  map.treeWood = newSeq[int16](cells)
  for y in 0 ..< side:
    for x in 0 ..< side:
      let
        index = map.tileIndex(x, y)
        corner = y * (side + 1) + x
        tops = [corners[corner], corners[corner + 1],
          corners[corner + side + 1], corners[corner + side + 2]]
        edge = x == 0 or y == 0 or x == side - 1 or y == side - 1
      ground.tiles[index] = Tile(
        flags: TileExists or TileConnectedEast or TileConnectedSouth,
        kind: GrassTile,
        tops: tops
      )
      ground.tiles[index].impassable = edge
      map.passable[index] = uint8(not edge)
      map.heights[index] = int16(
        (int32(tops[0]) + tops[1] + tops[2] + tops[3]) div 4
      )
      let wooded = groves[index] or valueNoise(
        seed, 0xD1B54A32D192ED03'u64, int(x), int(y), 7
      ) > 160
      if clear[index]:
        ground.tiles[index].kind = RoadTile
      elif wooded and not edge:
        map.treeWood[index] = WoodPerTree
        ground.tiles[index].kind = TreeTile
      map.kinds[index] = uint8(ground.tiles[index].kind)
  var forestTiles = 0
  for index in 0 ..< cells:
    if map.treeWood[index] > 0:
      inc forestTiles
      if forestTiles mod 10 == 0:
        map.treeWood[index] = 0
        map.passable[index] = 0
        map.forestRocks.add int32(index)
        ground.tiles[index].kind = RockTile
        ground.tiles[index].impassable = true
    elif not clear[index] and map.passable[index] == 1:
      ground.tiles[index].kind = RockTile
    map.kinds[index] = uint8(ground.tiles[index].kind)
  map.terrain = @[ground]
  installImmutableLayers(map.terrain)
  var hash = HashySeed
  hash.addHashy(seed)
  hash.addHashy(side)
  hash.addHashy(settings.layout.ord)
  hash.addHashy(settings.size)
  hash.addHashy(settings.expansions)
  hash.addHashy(settings.minDistance)
  for node in map.nodes:
    hash.addHashy(node.kind.ord)
    hash.addHashy(node.player)
    hash.addHashy(node.centre.x)
    hash.addHashy(node.centre.y)
  for i in 0 ..< cells:
    hash.addHashy(map.passable[i])
    hash.addHashy(map.kinds[i])
    hash.addHashy(map.heights[i])
    hash.addHashy(map.treeWood[i])
  for mine in map.mines:
    hash.addHashy(mine.id)
    hash.addHashy(mine.origin.x)
    hash.addHashy(mine.origin.y)
    hash.addHashy(mine.gold)
  map.hash = uint64(hash)
  map.validateMap()
  map
