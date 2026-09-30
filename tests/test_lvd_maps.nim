import
  polyworld/pathing,
  ../examples/light_vs_dark/[content, maps]

proc checkMap(map: MapData, players: int, expansions: int32) =
  ## Checks connected roads and starts, balanced resources, and dimensions.
  map.validateMap()
  doAssert map.hallOrigin.len == players
  doAssert map.nodes.len == players * (expansions + 1)
  doAssert map.mines.len == map.nodes.len
  doAssert map.passable.len == map.side * map.side
  doAssert map.heights.len == map.passable.len
  doAssert layers[0].width == map.side
  doAssert layers[0].originX == GridTiles div 2 - map.side div 2
  var
    spawns = newSeq[int](players)
    nearby = newSeq[int](players)
  for node in map.nodes:
    doAssert map.inGrid(node.centre)
    case node.kind
    of SpawnNode:
      inc spawns[node.player]
      doAssert node.parent == -1
      for other in map.nodes:
        if other.kind != SpawnNode or node.player == other.player:
          continue
        let
          dx = int64(node.centre.x) - int64(other.centre.x)
          dy = int64(node.centre.y) - int64(other.centre.y)
          minimum = int64(map.settings.minDistance)
        doAssert dx * dx + dy * dy >= minimum * minimum
    of ExpansionNode:
      inc nearby[node.player]
      let parent = map.nodes[node.parent]
      doAssert parent.kind == SpawnNode
      doAssert parent.player == node.player
      doAssert chebyshev(parent.centre, node.centre) <=
        max(26'i32, expansions * 3) + 1
  for player in 0 ..< players:
    doAssert spawns[player] == 1
    doAssert nearby[player] == expansions
  for i, mine in map.mines:
    doAssert mine.id == FirstMineId + int32(i)
    doAssert mine.id.isMineId
    doAssert mine.gold ==
      (if map.nodes[i].kind == SpawnNode: MainMineGold else: ExpansionMineGold)
  let hub = tile2(map.side div 2, map.side div 2)
  var
    reached = newSeq[bool](map.passable.len)
    frontier = @[hub]
  reached[map.tileIndex(hub)] = true
  while frontier.len > 0:
    let tile = frontier.pop()
    for i in [0, 2, 4, 6]:
      let
        (dx, dy) = StepOffsets[i]
        x = int32(tile.x) + dx
        y = int32(tile.y) + dy
      if not map.inGrid(x, y):
        continue
      let index = map.tileIndex(x, y)
      if not reached[index] and map.kinds[index] == uint8(RoadTile):
        reached[index] = true
        frontier.add tile2(x, y)
  for y in 0 ..< map.side:
    for x in 0 ..< map.side:
      doAssert map.passable[map.tileIndex(x, y)] == uint8(isWalkable(0, x, y))
      if map.kinds[map.tileIndex(x, y)] == uint8(RoadTile):
        doAssert reached[map.tileIndex(x, y)], "Road has a disconnected gap."

echo "Testing node layouts across seeds, rosters, and expansion counts"
for layout in MapLayout:
  for players in [1, 2, 3, 5, 9, 16]:
    for expansions in [0'i32, 2'i32, 5'i32]:
      for seed in [1'i32, 42'i32, DefaultSeed]:
        let
          settings = MapSettings(layout: layout, expansions: expansions)
          map = generateMap(seed, players, settings)
          repeated = generateMap(seed, players, settings)
        map.checkMap(players, expansions)
        doAssert map.hash == repeated.hash
        doAssert map.nodes == repeated.nodes
        doAssert map.hallOrigin == repeated.hallOrigin
        doAssert map.passable == repeated.passable
        doAssert map.kinds == repeated.kinds
        doAssert map.heights == repeated.heights
        doAssert map.treeWood == repeated.treeWood
        doAssert map.mines == repeated.mines

echo "Testing seeded variation in spokes and expansion angles"
for layout in MapLayout:
  var
    previousSpawns, previousExpansions: seq[Tile2]
    unevenLengths, unevenAngles, unevenExpansions: bool
  for seed in 1'i32 .. 8'i32:
    let map = generateMap(seed, 4, MapSettings(layout: layout))
    map.checkMap(4, 2)
    var
      spawns, expansions: seq[Tile2]
      shortest = high(int64)
      longest = 0'i64
    for i, node in map.nodes:
      if node.kind == SpawnNode:
        let
          dx = int64(node.centre.x) - map.side div 2
          dy = int64(node.centre.y) - map.side div 2
          squared = dx * dx + dy * dy
        shortest = min(shortest, squared)
        longest = max(longest, squared)
        spawns.add tile2(int32(dx), int32(dy))
      else:
        let parent = map.nodes[node.parent].centre
        expansions.add tile2(
          int32(node.centre.x) - int32(parent.x),
          int32(node.centre.y) - int32(parent.y)
        )
        if map.nodes[i - 1].kind == ExpansionNode:
          let
            first = expansions[^2]
            second = expansions[^1]
            cross = int64(first.x) * int64(second.y) -
              int64(first.y) * int64(second.x)
          unevenExpansions = unevenExpansions or abs(cross) > 100
    unevenLengths = unevenLengths or longest * 100 > shortest * 110
    let dot = int64(spawns[0].x) * int64(spawns[1].x) +
      int64(spawns[0].y) * int64(spawns[1].y)
    unevenAngles = unevenAngles or abs(dot) * 10 > longest
    if seed > 1:
      doAssert spawns != previousSpawns
      doAssert expansions != previousExpansions
    previousSpawns = spawns
    previousExpansions = expansions
  if layout == SpokeLayout:
    doAssert unevenLengths, "Spokes should vary in length."
    doAssert unevenAngles, "Spokes should vary in angle."
  doAssert unevenExpansions, "Expansions should not stay opposite each other."

echo "Testing map size and spacing settings"
for layout in MapLayout:
  let
    small = generateMap(42, 2, MapSettings(layout: layout))
    largerRoster = generateMap(42, 8, MapSettings(layout: layout))
    largerSize = generateMap(42, 2, MapSettings(layout: layout, size: 320))
    distant = generateMap(42, 5,
      MapSettings(layout: layout, size: 32, minDistance: 180))
  doAssert largerRoster.side > small.side
  doAssert largerSize.side > small.side
  distant.checkMap(5, 2)

block compactEdges:
  let map = generateMap(DefaultSeed, 8)
  map.checkMap(8, 2)
  doAssert map.side <= 200, "Eight players should fit a compact map."
  var edgeStart = false
  for node in map.nodes:
    if node.kind != SpawnNode:
      continue
    let border = min(
      min(int32(node.centre.x), int32(node.centre.y)),
      min(map.side - 1 - int32(node.centre.x),
        map.side - 1 - int32(node.centre.y))
    )
    edgeStart = edgeStart or border <= 20
  doAssert edgeStart, "Expansions should not force every base away from edges."

block manyMines:
  let map = generateMap(73, 40, MapSettings(layout: RandomLayout))
  map.checkMap(40, 2)
  doAssert map.mines.len > 90
  doAssert map.side > 255

block manyExpansions:
  let map = generateMap(19, 3, MapSettings(expansions: 12))
  map.checkMap(3, 12)

echo "Testing invalid settings and damaged maps"
for settings in [MapSettings(size: 0), MapSettings(expansions: -1),
  MapSettings(minDistance: 0), MapSettings(size: MaximumMapSide + 1)]:
    var caught = false
    try:
      discard generateMap(1, 2, settings)
    except LvdError:
      caught = true
    doAssert caught
block noPlayers:
  var caught = false
  try:
    discard generateMap(1, 0)
  except LvdError:
    caught = true
  doAssert caught
block blockedHall:
  var map = generateMap(DefaultSeed, 3)
  map.passable[map.tileIndex(map.hallOrigin[2])] = 0
  var caught = false
  try:
    map.validateMap()
  except LvdError:
    caught = true
  doAssert caught

echo "LvD node maps passed"
