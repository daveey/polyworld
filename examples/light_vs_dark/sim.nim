## Light vs Dark simulation.
##
## Planar unit motion uses Q16.16 tile-space bodies. Combat ranges, harvest
## rings, and replay integers stay on tiles derived from `cell(body.pos)`.
## This module must not import anything that returns a float.

import
  bassy, fixxy,
  polyworld/[bodies, hashes, metrics, pathing, profiles, rngs, tapes,
    visions, mailboxes],
  content,
  maps,
  replays

const
  QueueSlots* = 5
  TreeBlocker* = -1'i32
  NoTile* = Tile2(x: -1, y: -1)
  UnitBodyRadius = 0.22'fx
  BodyTurnRate = 0.35'fx
  PathArrive = 0.35'fx

type
  UnitState* = enum
    UnitIdle, UnitMoving, UnitChasing, UnitAttacking,
    UnitToMine, UnitInMine, UnitToDropGold, UnitDepositGold,
    UnitToTree, UnitChopping, UnitToDropWood, UnitDepositWood,
    UnitToBuild, UnitBuilding, UnitDying

  Unit* = ref object
    id*, owner*: int32
    kind*: UnitKind
    tile*: Tile2
      ## Derived from `body.pos`. Occupancy is a hint, not exclusive.
    fromTile*: Tile2
      ## Previous cell, for the renderer when a body snapshot is missing.
    body*: Body
    stepTicks*, stepTotal*: int32
      ## Kept for replay hashing. Movement no longer counts these down.
    facingX*, facingY*: int8
    hp*: int32
    state*: UnitState
    stateTicks*: int32
      ## Countdown shared by mining, chopping, building, and depositing.
    cooldown*: int32
    targetId*: int32
      ## Whatever the unit is currently walking to or swinging at.
    sourceId*: int32
      ## The gold mine a peon is working, kept across the whole round trip so
      ## delivering a load does not lose track of where the load came from.
    targetTile*: Tile2
      ## Tree being chopped, when the resource is terrain rather than an
      ## entity. Also survives the round trip.
    goal*: Tile2
    goalOffset*: FixedVec2
    hasGoal*: bool
    attackMove*: bool
      ## True while walking a destination that should stop to fight.
    attackMoveGoal*: Tile2
    attackMoveOffset*: FixedVec2
      ## The destination to resume after a fight, or off-map when unset.
    path*: seq[Tile2]
      ## String-pulled waypoints in walk order.
    pathIndex*: int32
    pathGoal*: Tile2
    blockedTicks*, repathCooldown*: int32
    carryGold*, carryWood*: int32
    orderFailed*: bool
      ## Set when an order fails. Cleared by the next accepted unit order.
    animation*: AnimationSlot
    animationTicks*: int32
    deathTicks*: int32

  BuildingState* = enum
    BuildingUnderConstruction, BuildingComplete, BuildingDying

  Building* = object
    id*, owner*: int32
      ## Owner is -1 for a neutral gold mine.
    kind*: BuildingKind
    origin*: Tile2
    footprint*: Footprint
    hp*, maxHp*: int32
    state*: BuildingState
    buildTicks*, buildTotal*, builderId*: int32
    queue*: array[QueueSlots, uint8]
      ## `UnitKind.ord + 1`, or zero for an empty slot.
    queueLength*, trainTicks*: int32
    rally*: Tile2
    hasRally*: bool
    cooldown*: int32
    goldLeft*, minersInside*: int32
    deathTicks*: int32

  Player* = object
    gold*, wood*, foodUsed*, foodCap*: int32
    goldGathered*, woodGathered*: int64
    unitsTrained*, unitsLost*: int32
    buildingsBuilt*, buildingsLost*: int32
    defeated*: bool

  PathRequest* = object
    unitId*: int32
    goal*: Tile2

  TileEdit* = object
    tick*: int32
    index*: int32

  World* = ref object
    stats*: CombatStats
    ## One match. A ref so `a = b` aliases and a second world is `clone()`.
    tick*: int32
    rng*: Rng
    over*: bool
    winner*: int32                        # HASH: include, -1 is undecided
    maximumTicks*: int32                  # HASH: include
    players*: array[PlayerCount, Player]  # HASH: include
    units*: seq[Unit]                     # HASH: include, id ascending; refs
    buildings*: seq[Building]             # HASH: include, id ascending
    nextUnitId*, nextBuildingId*: int32   # HASH: include
    pathQueue*: seq[PathRequest]          # HASH: include
    terrainEdits*: seq[TileEdit]          # HASH: include
    exploredCount*: array[PlayerCount, int32]  # HASH: include
    map*: MapData                         # HASH: derived, fixed at generation
    blocker*: seq[int32]                  # HASH: derived from buildings/edits
    treeWood*: seq[int16]                 # HASH: derived from edits
    occupancy*: seq[int32]                # HASH: derived from unit tiles
    unitSlot*: seq[int32]                 # HASH: derived index
    buildingSlot*: seq[int32]             # HASH: derived index
    visibleStamp*: array[PlayerCount, seq[uint32]]   # HASH: derived
    visionGeneration*: array[PlayerCount, uint32]    # HASH: derived
    explored*: array[PlayerCount, seq[uint8]]        # HASH: derived
  OverlordVm* = ref object
    output*: PrintProc
    ## One compiled BASIC program for a player. Not simulation state.
    runtime*: Runtime
    ready*: bool
    failed*: bool
    lastError*: string
    decisions*: int
    lastWork*, lastInstructions*: int64
  Game* = ref object
    ## One match session. World is the hashable sim; everything else is
    ## tape and agents. The generated map lives on `world.map`.
    world*: World
    metrics*: MatchMetrics
    history*: MetricHistory
    recorder*: ReplayRecorder
    replayData*: ReplayData
    replayPlayer*: ReplayPlayer
    hashCheck*: ReplayHashCheck
    historyPlayback*: bool
    replayMode*: bool
    brains*: array[PlayerCount, OverlordVm]
    inboxes*: array[PlayerCount, Mailbox]
    mapSeed*: int32
    maximumTicks*: int32

## Entity lookup
##
## Identifier ranges make the kind checkable before any array is touched, and
## the slot tables turn a valid identifier into an index in constant time.

proc config*(game: Game): GameConfig =
  ## Reads the match configuration owned by the live or loaded replay.
  if game.recorder != nil:
    game.recorder.data.config
  else:
    game.replayData.config

proc unitIndex*(w: World, id: int32): int32 =
  ## Returns the index of a living unit, or -1.
  if not id.isUnitId:
    return -1
  let slot = id - FirstUnitId
  if slot < 0 or slot >= w.unitSlot.len:
    return -1
  w.unitSlot[slot]

proc buildingIndex*(w: World, id: int32): int32 =
  ## Returns the index of a standing structure, or -1.
  if not id.isBuildingId:
    return -1
  let slot = id - FirstMineId
  if slot < 0 or slot >= w.buildingSlot.len:
    return -1
  w.buildingSlot[slot]

proc hasUnit*(w: World, id: int32): bool =
  w.unitIndex(id) >= 0

proc hasBuilding*(w: World, id: int32): bool =
  w.buildingIndex(id) >= 0

proc unitOwner*(w: World, id: int32): int32 =
  ## Returns the owning player of a living unit, or -1.
  let index = w.unitIndex(id)
  if index < 0: -1 else: w.units[index].owner

proc buildingOwner*(w: World, id: int32): int32 =
  ## Returns the owning player of a standing structure, or -1 when neutral.
  let index = w.buildingIndex(id)
  if index < 0: -1 else: w.buildings[index].owner

## Tiles

proc terrainOpen*(w: World, x, y: int32): bool =
  ## Returns whether terrain alone permits standing on a tile.
  inGrid(x, y) and w.map.passable[tileIndex(x, y)] == 1

proc tileOpen*(w: World, x, y: int32): bool =
  ## Returns whether a tile is free of terrain blocks, trees, and structures.
  w.terrainOpen(x, y) and w.blocker[tileIndex(x, y)] == 0

proc tileOpen*(w: World, tile: Tile2): bool =
  w.tileOpen(int32(tile.x), int32(tile.y))

proc tileFree*(w: World, x, y: int32): bool =
  ## Returns whether a tile is open and unoccupied by any unit.
  w.tileOpen(x, y) and w.occupancy[tileIndex(x, y)] == 0

proc goalClaimed(w: World, tile: Tile2, ignoreId: int32): bool =
  ## Returns whether another living unit is already walking to this tile.
  for unit in w.units:
    if unit.id == ignoreId or unit.state == UnitDying:
      continue
    if unit.hasGoal and unit.goal == tile:
      return true
  false

proc covers*(origin: Tile2, size: Footprint, x, y: int32): bool =
  ## Returns whether a rectangular footprint contains a tile.
  x >= int32(origin.x) and x < int32(origin.x) + size.width and
    y >= int32(origin.y) and y < int32(origin.y) + size.depth

proc adjacentToFootprint*(origin: Tile2, size: Footprint, x, y: int32): bool =
  ## Returns whether a tile touches a footprint's outer ring.
  x >= int32(origin.x) - 1 and x < int32(origin.x) + size.width + 1 and
    y >= int32(origin.y) - 1 and y < int32(origin.y) + size.depth + 1 and
    not covers(origin, size, x, y)

proc freeTileAround*(w: World, origin: Tile2, size: Footprint): Tile2 =
  ## Returns the first free tile in the ring around a footprint, scanning
  ## row-major so the choice is reproducible. Off-map when the ring is full.
  for y in int32(origin.y) - 1 .. int32(origin.y) + size.depth:
    for x in int32(origin.x) - 1 .. int32(origin.x) + size.width:
      if not covers(origin, size, x, y) and w.tileFree(x, y):
        return tile2(x, y)
  NoTile

proc approachTile*(
    w: World, origin: Tile2, size: Footprint, fromTile: Tile2,
    ignoreId: int32
): Tile2 =
  ## Returns a ring tile around a footprint. Prefers empty unclaimed
  ## ground, then empty claimed ground, then any open tile, so peons
  ## do not all queue on the same mine square. Closest to `fromTile`
  ## wins; equal distances keep the row-major scan order.
  var
    bestFree, bestClaimed, bestOpen = NoTile
    bestFreeDist, bestClaimedDist, bestOpenDist = int32.high
  for y in int32(origin.y) - 1 .. int32(origin.y) + size.depth:
    for x in int32(origin.x) - 1 .. int32(origin.x) + size.width:
      if covers(origin, size, x, y) or not w.tileOpen(x, y):
        continue
      let
        tile = tile2(x, y)
        dist =
          if inGrid(fromTile):
            chebyshev(fromTile, tile)
          else:
            0'i32
      if w.tileFree(x, y):
        if w.goalClaimed(tile, ignoreId):
          if dist < bestClaimedDist:
            bestClaimedDist = dist
            bestClaimed = tile
        elif dist < bestFreeDist:
          bestFreeDist = dist
          bestFree = tile
      elif dist < bestOpenDist:
        bestOpenDist = dist
        bestOpen = tile
  if inGrid(bestFree):
    bestFree
  elif inGrid(bestClaimed):
    bestClaimed
  else:
    bestOpen

## Vision

var
  visionBlockers: seq[int16]
  visionSkipWorld: pointer
  visionSkipKeys: seq[int32]
  visionSkipNow: seq[int32]
  splashHits: seq[int32]

proc fillVisionKeys(w: World, dest: var seq[int32]) =
  ## Records sources, building footprints, and terrain edits.
  dest.setLen(0)
  dest.add int32(w.terrainEdits.len)
  dest.add int32(w.units.len)
  for i in 0 ..< w.units.len:
    let unit = w.units[i]
    dest.add unit.id
    dest.add unit.owner
    dest.add int32(unit.kind.ord)
    dest.add int32(unit.state.ord)
    dest.add int32(unit.tile.x)
    dest.add int32(unit.tile.y)
  dest.add int32(w.buildings.len)
  for structure in w.buildings:
    dest.add structure.id
    dest.add structure.owner
    dest.add int32(structure.kind.ord)
    dest.add int32(structure.state.ord)
    dest.add int32(structure.origin.x)
    dest.add int32(structure.origin.y)
    dest.add structure.footprint.width
    dest.add structure.footprint.depth

proc paintVisible(
    w: World,
    player: int32,
    sourceX,
    sourceZ,
    radius: int32,
    eyeHeight: int16
) =
  ## Marks one observer's circle on the current generation stamps.
  if radius <= 0 or not inGrid(sourceX, sourceZ):
    return
  let
    sourceIndex = tileIndex(sourceX, sourceZ)
    sourceY = int64(w.map.heights[sourceIndex]) + int64(eyeHeight)
    generation = w.visionGeneration[player]
  for offset in visionCircleTiles(radius):
    let
      x = sourceX + int32(offset.dx)
      z = sourceZ + int32(offset.dz)
    if not inGrid(x, z):
      continue
    let index = tileIndex(x, z)
    if w.visibleStamp[player][index] == generation:
      continue
    if offsetVisible(
      GridSide,
      w.map.heights,
      visionBlockers,
      sourceX,
      sourceZ,
      sourceY,
      offset
    ):
      w.visibleStamp[player][index] = generation
      if w.explored[player][index] == 0:
        w.explored[player][index] = 1
        inc w.exploredCount[player]

proc rebuildVision*(w: World) {.measure.} =
  ## Recomputes range- and occluder-limited visibility for both teams.
  ##
  ## A full rebuild rather than an incremental update: incremental vision
  ## needs a matching decrement for every increment across movement, death,
  ## spawning, and construction, and one missed case is a silent permanent
  ## leak that only shows up as drift many ticks later.
  w.fillVisionKeys(visionSkipNow)
  if visionSkipWorld == cast[pointer](w) and
      sameVisionKeys(visionSkipNow, visionSkipKeys):
    return
  for player in 0 ..< PlayerCount:
    if w.visionGeneration[player] == uint32.high:
      w.visibleStamp[player] = newSeq[uint32](GridCells)
      w.visionGeneration[player] = 1
    else:
      inc w.visionGeneration[player]
  visionBlockers.setLen(GridCells)
  for i in 0 ..< GridCells:
    visionBlockers[i] = 0
  for index, blocker in w.blocker:
    if blocker == TreeBlocker:
      visionBlockers[index] = 24
    elif blocker != NoEntity:
      visionBlockers[index] = 28
  initVisionKernel()
  for player in 0'i32 ..< PlayerCount:
    for i in 0 ..< w.units.len:
      let unit = w.units[i]
      if unit.owner == player and
          unit.state notin {UnitDying, UnitInMine}:
        w.paintVisible(
          player,
          int32(unit.tile.x),
          int32(unit.tile.y),
          UnitTable[unit.owner][unit.kind].sightTiles,
          14
        )
    for structure in w.buildings:
      if structure.owner != player or structure.state == BuildingDying:
        continue
      let radius = BuildingTable[structure.kind].sightTiles
      for y in int32(structure.origin.y) ..<
          int32(structure.origin.y) + structure.footprint.depth:
        for x in int32(structure.origin.x) ..<
            int32(structure.origin.x) + structure.footprint.width:
          w.paintVisible(player, x, y, radius, 24)
  copyVisionKeys(visionSkipKeys, visionSkipNow)
  visionSkipWorld = cast[pointer](w)

proc visible*(w: World, player, x, y: int32): bool =
  ## Returns whether a player can currently see a tile.
  inGrid(x, y) and
    w.visibleStamp[player][tileIndex(x, y)] == w.visionGeneration[player]

proc visible*(w: World, player: int32, tile: Tile2): bool =
  w.visible(player, int32(tile.x), int32(tile.y))

proc explored*(w: World, player, x, y: int32): bool =
  ## Returns whether a player has ever seen a tile.
  inGrid(x, y) and w.explored[player][tileIndex(x, y)] == 1

proc unitVisible*(w: World, player: int32, unit: Unit): bool =
  ## Returns whether a player may observe a unit this tick.
  if unit.owner == player:
    return true
  if unit.state == UnitInMine or unit.state == UnitDying:
    return false
  w.visible(player, unit.tile)

proc unitVisible*(w: World, player: int32, index: int): bool =
  ## Returns whether a player may observe the unit at `index`.
  if index < 0 or index >= w.units.len:
    return false
  let unit = w.units[index]
  if unit.owner == player:
    return true
  if unit.state == UnitInMine or unit.state == UnitDying:
    return false
  w.visible(player, unit.tile)

proc buildingVisible*(w: World, player: int32, structure: Building): bool =
  ## Returns whether a player may observe a structure. Any visible footprint
  ## tile is enough, so a wide structure is never half hidden.
  if structure.owner == player:
    return true
  for y in int32(structure.origin.y) ..<
      int32(structure.origin.y) + structure.footprint.depth:
    for x in int32(structure.origin.x) ..<
        int32(structure.origin.x) + structure.footprint.width:
      if w.visible(player, x, y):
        return true
  false

proc entityVisible(w: World, player, id: int32): bool =
  ## Returns whether one enemy entity can be targeted by a player this tick.
  if id.isUnitId:
    let index = w.unitIndex(id)
    index >= 0 and w.unitVisible(player, index)
  elif id.isBuildingId:
    let index = w.buildingIndex(id)
    index >= 0 and w.buildingVisible(player, w.buildings[index])
  else:
    false

## Pathfinding
##
## Terrain walkability is a callback into `tileOpen`. Occupied tiles stay
## walkable so a packed ford is never a wall, but they pay
## `OccupiedTilePenalty` so harvest traffic prefers empty ground. A unit
## that is standing still is a wall, so a pulled route goes around it.

var
  pathSearches*, pathExpansions*: int
    ## Diagnostics only. Never hashed, never read by the simulation; they
    ## exist so a slow match can be explained rather than guessed at.
  pathWorld: World
  walkWorld: World
  pathIgnoreId: int32
  pathTiles: seq[PathTile]

proc standingOccupant(w: World, holder, ignoreId: int32): bool =
  ## True when another living unit is idle on this occupancy slot.
  if holder == 0 or holder == ignoreId:
    return false
  let index = w.unitIndex(holder)
  if index < 0:
    return false
  let unit = w.units[index]
  unit.state != UnitDying and
    unit.state != UnitInMine and
    not unit.hasGoal

proc tileHoldsOther(w: World, x, z, ignoreId: int32): bool =
  ## True when a standing unit occupies this cell.
  inGrid(x, z) and
    w.standingOccupant(w.occupancy[tileIndex(x, z)], ignoreId)

proc lvdPathWalkable(layer, x, z: int): bool {.nimcall.} =
  ## Terrain plus idle occupants. Moving traffic is not a wall.
  if layer != 0 or not pathWorld.tileOpen(int32(x), int32(z)):
    return false
  not pathWorld.tileHoldsOther(int32(x), int32(z), pathIgnoreId)

proc lvdPathEnterCost(layer, x, z: int): int32 {.nimcall.} =
  ## Extra cost for standing on another unit's tile.
  if layer != 0 or not inGrid(int32(x), int32(z)):
    return 0
  let holder = pathWorld.occupancy[tileIndex(int32(x), int32(z))]
  if holder == 0 or holder == pathIgnoreId:
    0
  else:
    OccupiedTilePenalty

proc octileDistance*(ax, ay, bx, by: int32): int32 =
  ## Returns the eight-neighbour distance between tiles in path cost units.
  let
    dx = abs(ax - bx)
    dy = abs(ay - by)
  DiagonalCost * min(dx, dy) + OrthogonalCost * (max(dx, dy) - min(dx, dy))

proc tileDistance*(first, second: Tile2): int32 =
  ## Returns the king-move distance in whole tiles.
  chebyshev(first, second)

proc diagonalAllowed(w: World, x, y, dx, dy: int32): bool =
  ## A diagonal step is legal only when both orthogonal neighbours are open,
  ## so units never squeeze through the corner between two structures.
  dx == 0 or dy == 0 or (w.tileOpen(x + dx, y) and w.tileOpen(x, y + dy))

proc occupancyOnSegment(
    w: World, a, b: PathTile, ignoreId: int32
): bool =
  ## True when a standing unit sits on the straight tile line from a to b.
  ## A diagonal DDA step also checks both orthogonal tiles so a corner clip
  ## of an occupied cell cannot be pulled through.
  var
    x = a.x
    z = a.z
    ix = 0
    iz = 0
  let
    dx = b.x - a.x
    dz = b.z - a.z
    stepX = cmp(dx, 0)
    stepZ = cmp(dz, 0)
    adx = abs(dx)
    adz = abs(dz)
  while x != b.x or z != b.z:
    let
      left = int64(1 + 2 * ix) * int64(adz)
      right = int64(1 + 2 * iz) * int64(adx)
      takeX = stepX != 0 and (stepZ == 0 or left <= right)
      takeZ = stepZ != 0 and (stepX == 0 or left >= right)
    if takeX and takeZ:
      if w.tileHoldsOther(x + int32(stepX), z, ignoreId) or
          w.tileHoldsOther(x, z + int32(stepZ), ignoreId):
        return true
    if takeX:
      x += int32(stepX)
      inc ix
    if takeZ:
      z += int32(stepZ)
      inc iz
    if w.tileHoldsOther(x, z, ignoreId):
      return true
  false

proc terrainBlockedOnSegment(w: World, a, b: PathTile): bool =
  ## True when the centre-to-centre line clips a blocked tile.
  var
    x = a.x
    z = a.z
    ix = 0
    iz = 0
  let
    dx = b.x - a.x
    dz = b.z - a.z
    stepX = cmp(dx, 0)
    stepZ = cmp(dz, 0)
    adx = abs(dx)
    adz = abs(dz)
  while x != b.x or z != b.z:
    let
      left = int64(1 + 2 * ix) * int64(adz)
      right = int64(1 + 2 * iz) * int64(adx)
      takeX = stepX != 0 and (stepZ == 0 or left <= right)
      takeZ = stepZ != 0 and (stepX == 0 or left >= right)
    if takeX and takeZ:
      if not w.tileOpen(x + int32(stepX), z) or
          not w.tileOpen(x, z + int32(stepZ)):
        return true
    if takeX:
      x += int32(stepX)
      inc ix
    if takeZ:
      z += int32(stepZ)
      inc iz
    if not w.tileOpen(x, z):
      return true
  false

proc lvdSmoothPath(tiles: seq[PathTile], ignoreId: int32): seq[PathTile] =
  ## String-pulls a route without skipping through units or blocked ground.
  if tiles.len <= 2:
    return tiles
  result.add tiles[0]
  var anchor = 0
  while anchor < tiles.len - 1:
    var reach = anchor + 1
    for candidate in countdown(tiles.len - 1, anchor + 2):
      if lineClear(tiles[anchor], tiles[candidate]) and
          not occupancyOnSegment(
            pathWorld, tiles[anchor], tiles[candidate], ignoreId
          ) and
          not terrainBlockedOnSegment(
            pathWorld, tiles[anchor], tiles[candidate]
          ):
        reach = candidate
        break
    result.add tiles[reach]
    anchor = reach

proc findPath(
    w: World, start, goal: Tile2, ignoreId: int32, path: var seq[Tile2]
): bool {.measure.} =
  ## Asks the library for a route and stores string-pulled waypoints in
  ## walk order. Returns whether the goal was reached; on failure `path`
  ## holds the best partial route, still worth walking. Occupied tiles
  ## cost extra so searches go around other units when a short detour
  ## exists.
  path.setLen(0)
  if not inGrid(start) or not inGrid(goal):
    return false
  if start == goal:
    return true
  inc pathSearches
  pathWorld = w
  pathIgnoreId = ignoreId
  let found = fillTilePath(PathQuery(
    startLayer: 0,
    startX: int(start.x),
    startZ: int(start.y),
    finishLayer: 0,
    finishX: int(goal.x),
    finishZ: int(goal.y),
    neighbors: EightNeighbors,
    walkable: lvdPathWalkable,
    enterCost: lvdPathEnterCost,
    maxExpansions: MaxPathExpansions,
    orthogonalCost: OrthogonalCost,
    diagonalCost: DiagonalCost,
    partial: true
  ), pathTiles)
  pathExpansions += found.expansions
  let pulled = lvdSmoothPath(pathTiles, ignoreId)
  path.setLen(pulled.len)
  for i, tile in pulled:
    path[i] = tile2(tile.x, tile.z)
  found.complete

## Order bookkeeping

proc clearPath(unit: Unit) =
  unit.path.setLen(0)
  unit.pathIndex = 0
  unit.pathGoal = NoTile

proc clearOrder(unit: Unit, failed: bool) =
  ## Drops whatever the unit was doing and returns it to idle.
  unit.state = UnitIdle
  unit.hasGoal = false
  unit.goalOffset = FixedVec2Zero
  unit.attackMove = false
  unit.attackMoveGoal = NoTile
  unit.attackMoveOffset = FixedVec2Zero
  unit.targetId = NoEntity
  unit.sourceId = NoEntity
  unit.targetTile = NoTile
  unit.blockedTicks = 0
  unit.animation = IdleAnimation
  unit.clearPath()
  if failed:
    unit.orderFailed = true

proc requestPath(w: World, index: int32) =
  ## Queues one path search. An existing request for this unit keeps its
  ## slot and updates the goal, so a later order in the same decision does
  ## not leave a stale request that servePathQueue will discard.
  if w.units[index].repathCooldown > 0 or not w.units[index].hasGoal:
    return
  let id = w.units[index].id
  for i in 0 ..< w.pathQueue.len:
    if w.pathQueue[i].unitId == id:
      w.pathQueue[i].goal = w.units[index].goal
      return
  if w.pathQueue.len >= MaxPathRequests:
    ## The oldest request loses its place rather than the newest never
    ## getting one, and the dropped unit is told so it can ask again.
    let dropped = w.pathQueue[0].unitId
    w.pathQueue.delete(0)
    let droppedIndex = w.unitIndex(dropped)
    if droppedIndex >= 0:
      w.units[droppedIndex].orderFailed = true
  w.pathQueue.add PathRequest(unitId: id, goal: w.units[index].goal)

proc setGoal(w: World, index: int32, goal: Tile2,
    offset = FixedVec2Zero) =
  ## Points a unit at a destination tile and asks for a route.
  w.units[index].goal = goal
  w.units[index].goalOffset = offset
  w.units[index].hasGoal = true
  w.units[index].blockedTicks = 0
  w.units[index].repathCooldown = 0
  w.units[index].clearPath()
  w.requestPath(index)

proc footprintGoal(w: World, index: int32, origin: Tile2,
    size: Footprint): bool =
  ## Points a unit at the ring around a footprint. Returns false, and drops
  ## the order, when nothing around it can be stood on.
  let approach = w.approachTile(
    origin, size, w.units[index].tile, w.units[index].id
  )
  if not inGrid(approach):
    w.units[index].clearOrder(true)
    return false
  w.setGoal(index, approach)
  true

## Resource queries

proc nearestDropOff*(w: World, player: int32, origin: Tile2,
    wantWood: bool): int32 =
  ## Returns the closest completed structure that accepts a resource.
  ## Wood may go to a hall or a mill. Gold only goes to a town hall.
  result = NoEntity
  var best = int32.high
  for structure in w.buildings:
    if structure.owner != player or structure.state != BuildingComplete:
      continue
    let stats = BuildingTable[structure.kind]
    if (wantWood and not stats.dropOffWood) or
        (not wantWood and not stats.dropOffGold):
      continue
    let distance = tileDistance(origin, structure.origin)
    if distance < best or (distance == best and structure.id < result):
      best = distance
      result = structure.id

proc nearestTree*(w: World, origin: Tile2): int32 =
  ## Returns the flat tile index of the closest standing tree, or -1. Rings
  ## are scanned outward and ties inside a ring go to the lowest index, so
  ## two peons asking from the same tile always get the same answer.
  result = -1
  for radius in 1'i32 ..< GridSide:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        if max(abs(dx), abs(dy)) != radius:
          continue
        let
          x = int32(origin.x) + dx
          y = int32(origin.y) + dy
        if not inGrid(x, y):
          continue
        let index = tileIndex(x, y)
        if w.treeWood[index] > 0 and (result < 0 or index < result):
          result = index
    if result >= 0:
      return

## Terrain edits

proc removeTree(w: World, index: int32) =
  ## Fells one tree: the tile opens immediately and the edit is logged so a
  ## checkpoint restore and the renderer can both replay it.
  w.treeWood[index] = 0
  if w.blocker[index] == TreeBlocker:
    w.blocker[index] = 0
  w.terrainEdits.add TileEdit(tick: w.tick, index: index)

proc occupyFootprint(w: World, origin: Tile2, size: Footprint, id: int32) =
  ## Claims every tile of a footprint for a structure.
  for y in int32(origin.y) ..< int32(origin.y) + size.depth:
    for x in int32(origin.x) ..< int32(origin.x) + size.width:
      if inGrid(x, y):
        w.blocker[tileIndex(x, y)] = id

proc releaseFootprint(w: World, origin: Tile2, size: Footprint) =
  ## Releases every tile of a footprint.
  for y in int32(origin.y) ..< int32(origin.y) + size.depth:
    for x in int32(origin.x) ..< int32(origin.x) + size.width:
      if inGrid(x, y):
        w.blocker[tileIndex(x, y)] = 0

proc tileCenter(tile: Tile2): FixedVec2 =
  ## Returns the tile-space centre of one cell.
  fixedVec2(
    fixed(int32(tile.x)) + 0.5'fx,
    fixed(int32(tile.y)) + 0.5'fx
  )

proc bindBody(tile: Tile2, facingX, facingY: int8): Body =
  ## Builds a body standing on the centre of a tile.
  result.pos = tileCenter(tile)
  result.radius = UnitBodyRadius
  if facingX != 0 or facingY != 0:
    result.facing = angle(fixedVec2(fixed(int32(facingX)), fixed(int32(facingY))))

proc applyBody(unit: Unit) =
  ## Writes the body plane back onto the integer tile and facing.
  let
    (x, z) = cell(unit.body.pos)
    dir = direction(unit.body.facing)
  unit.fromTile = unit.tile
  unit.tile = tile2(x, z)
  unit.facingX = int8(cmp(int32(dir.x), 0))
  unit.facingY = int8(cmp(int32(dir.y), 0))

proc place*(w: World, unit: Unit, at: Tile2) =
  ## Teleports a unit and keeps its body on the same cell.
  if unit.state != UnitInMine and unit.state != UnitDying and
      inGrid(unit.tile):
    let old = tileIndex(unit.tile)
    if w.occupancy[old] == unit.id:
      w.occupancy[old] = 0
  unit.tile = at
  unit.fromTile = at
  if unit.body.radius == FixedZero:
    unit.body.radius = UnitBodyRadius
  unit.body.pos = tileCenter(at)
  if inGrid(at) and unit.state != UnitInMine and unit.state != UnitDying:
    w.occupancy[tileIndex(at)] = unit.id

## Spawning

proc registerUnit(w: World, unit: Unit) =
  ## Appends a unit, keeping `units` ascending by identifier.
  let slot = unit.id - FirstUnitId
  while w.unitSlot.len <= slot:
    w.unitSlot.add(-1)
  w.unitSlot[slot] = int32(w.units.len)
  w.units.add unit
  w.occupancy[tileIndex(unit.tile)] = unit.id

proc spawnUnit*(w: World, owner: int32, kind: UnitKind,
    tile: Tile2): int32 =
  ## Creates one unit on a free tile and returns its identifier.
  ##
  ## Food is deliberately not charged here. Training reserves it when the
  ## order is queued, so a full queue cannot overshoot the cap, and the
  ## opening peons are charged by the setup code.
  result = w.nextUnitId
  inc w.nextUnitId
  w.registerUnit Unit(
    id: result,
    owner: owner,
    kind: kind,
    tile: tile,
    fromTile: tile,
    facingY: 1,
    hp: UnitTable[owner][kind].hp,
    state: UnitIdle,
    targetId: NoEntity,
    sourceId: NoEntity,
    targetTile: NoTile,
    goal: tile,
    attackMoveGoal: NoTile,
    pathGoal: NoTile,
    animation: IdleAnimation,
    body: bindBody(tile, 0, 1)
  )

proc registerBuilding(w: World, structure: Building) =
  ## Appends a structure, keeping `buildings` ascending by identifier.
  let slot = structure.id - FirstMineId
  while w.buildingSlot.len <= slot:
    w.buildingSlot.add(-1)
  w.buildingSlot[slot] = int32(w.buildings.len)
  w.buildings.add structure
  w.occupyFootprint(structure.origin, structure.footprint, structure.id)

proc recomputeFoodCap(w: World, player: int32) =
  ## Recounts supply from completed structures.
  var cap = 0'i32
  for structure in w.buildings:
    if structure.owner == player and structure.state == BuildingComplete:
      cap += BuildingTable[structure.kind].foodProvided
  w.players[player].foodCap = min(cap, FoodCapMax)

## Combat

proc entityAlive*(w: World, id: int32): bool =
  ## Returns whether a target identifier still names something attackable.
  if id.isUnitId:
    let index = w.unitIndex(id)
    return index >= 0 and w.units[index].state != UnitDying
  if id.isBuildingId:
    let index = w.buildingIndex(id)
    return index >= 0 and w.buildings[index].state != BuildingDying
  false

proc entityTile*(w: World, id: int32): Tile2 =
  ## Returns a target's reference tile for range and pathing.
  if id.isUnitId:
    let index = w.unitIndex(id)
    if index >= 0:
      return w.units[index].tile
  elif id.isBuildingId:
    let index = w.buildingIndex(id)
    if index >= 0:
      return w.buildings[index].origin
  NoTile

proc footprintDistance(w: World, tile: Tile2, structure: Building): int32 =
  ## Returns the king-move gap to the nearest tile of a footprint, so a wide
  ## structure is no harder to reach than a narrow one.
  result = int32.high
  for y in int32(structure.origin.y) ..<
      int32(structure.origin.y) + structure.footprint.depth:
    for x in int32(structure.origin.x) ..<
        int32(structure.origin.x) + structure.footprint.width:
      result = min(result, tileDistance(tile, tile2(x, y)))

proc rangeToTarget(w: World, unit: Unit, id: int32): int32 =
  ## Returns the king-move gap between a unit and its target.
  if id.isUnitId:
    let index = w.unitIndex(id)
    if index < 0:
      return int32.high
    return tileDistance(unit.tile, w.units[index].tile)
  let index = w.buildingIndex(id)
  if index < 0:
    return int32.high
  w.footprintDistance(unit.tile, w.buildings[index])

proc killUnit(w: World, index: int32) =
  ## Starts a unit's death: it stops blocking immediately and lingers only
  ## as a corpse for the renderer.
  if w.units[index].state == UnitDying:
    return
  let
    owner = w.units[index].owner
    kind = w.units[index].kind
  if w.units[index].state == UnitInMine:
    let mine = w.buildingIndex(w.units[index].sourceId)
    if mine >= 0 and w.buildings[mine].minersInside > 0:
      dec w.buildings[mine].minersInside
  else:
    let tile = tileIndex(w.units[index].tile)
    if w.occupancy[tile] == w.units[index].id:
      w.occupancy[tile] = 0
  w.units[index].state = UnitDying
  w.units[index].hasGoal = false
  w.units[index].clearPath()
  w.units[index].deathTicks = DeathTicks
  w.units[index].animation = DeathAnimation
  w.units[index].animationTicks = 0
  w.players[owner].foodUsed -= UnitTable[owner][kind].food
  inc w.players[owner].unitsLost

proc razeBuilding(w: World, index: int32) =
  ## Starts a structure's collapse and returns everything it was holding.
  let owner = w.buildings[index].owner
  w.buildings[index].state = BuildingDying
  w.buildings[index].deathTicks = RubbleTicks
  inc w.players[owner].buildingsLost
  ## Give back the food a training queue had reserved.
  for slot in 0 ..< w.buildings[index].queueLength:
    let kind = UnitKind(w.buildings[index].queue[slot] - 1)
    w.players[owner].foodUsed -= UnitTable[owner][kind].food
  w.buildings[index].queueLength = 0
  let builder = w.buildings[index].builderId
  if builder != NoEntity:
    let builderIndex = w.unitIndex(builder)
    if builderIndex >= 0 and w.units[builderIndex].state == UnitBuilding:
      w.units[builderIndex].clearOrder(true)
  w.buildings[index].builderId = NoEntity
  ## Anyone still inside a razed mine has to come back out somewhere.
  for unitIndex in 0 ..< w.units.len:
    if w.units[unitIndex].state == UnitInMine and
        w.units[unitIndex].sourceId == w.buildings[index].id:
      let exit = w.freeTileAround(w.buildings[index].origin,
        w.buildings[index].footprint)
      if inGrid(exit):
        w.place(w.units[unitIndex], exit)
        w.units[unitIndex].clearOrder(true)
  w.releaseFootprint(w.buildings[index].origin, w.buildings[index].footprint)
  w.recomputeFoodCap(owner)

proc damageEntity*(w: World, id, amount: int32, attacker = -1'i32) =
  ## Applies damage and starts a death when something runs out of health.
  if id.isUnitId:
    let index = w.unitIndex(id)
    if index < 0 or w.units[index].state == UnitDying:
      return
    w.units[index].hp -= amount
    if w.units[index].hp <= 0:
      w.units[index].hp = 0
      if attacker >= 0 and attacker != w.units[index].owner:
        w.stats.add(int(attacker), KillsMetric)
      w.killUnit(index)
    return
  let index = w.buildingIndex(id)
  if index < 0 or w.buildings[index].owner < 0 or
      w.buildings[index].state == BuildingDying:
    return
  w.buildings[index].hp -= amount
  if w.buildings[index].hp <= 0:
    w.buildings[index].hp = 0
    if attacker >= 0 and attacker != w.buildings[index].owner:
      w.stats.add(int(attacker), StructuresMetric)
    w.razeBuilding(index)

proc acquireTarget(w: World, unit: Unit): int32 =
  ## Returns the closest visible enemy within sight, preferring units and
  ## breaking ties by identifier so the choice is reproducible.
  result = NoEntity
  let
    sight = UnitTable[unit.owner][unit.kind].sightTiles
    enemy = 1 - unit.owner
  var best = int32.high
  for other in w.units:
    if other.owner != enemy or other.state == UnitDying or
        other.state == UnitInMine:
      continue
    let distance = tileDistance(unit.tile, other.tile)
    if distance > sight or not w.visible(unit.owner, other.tile):
      continue
    if distance < best or (distance == best and other.id < result):
      best = distance
      result = other.id
  if result != NoEntity:
    return
  for structure in w.buildings:
    if structure.owner != enemy or structure.state == BuildingDying:
      continue
    let distance = w.footprintDistance(unit.tile, structure)
    if distance > sight or not w.buildingVisible(unit.owner, structure):
      continue
    if distance < best or (distance == best and structure.id < result):
      best = distance
      result = structure.id

## Movement
##
## The body is the planar authority. Tiles and occupancy are derived after
## each steer so harvest, combat, and vision keep their integer queries.

proc lvdTilesWalkable(pos: FixedVec2): bool {.nimcall.} =
  ## Terrain and structures only; other units separate as circles.
  let (x, z) = cell(pos)
  walkWorld != nil and walkWorld.tileOpen(x, z)

proc moveSpeed(unit: Unit): Fixed =
  ## Tiles walked in one tick from the unit's step cost.
  let ticks = UnitTable[unit.owner][unit.kind].stepTicks
  FixedOne / fixed(max(ticks, 1))

proc waypointPosition(unit: Unit, tile: Tile2): FixedVec2 =
  ## Uses the exact destination for the last tile of a route.
  result = tileCenter(tile)
  if unit.hasGoal and tile == unit.goal:
    result += unit.goalOffset

proc arrivedAt(unit: Unit, tile: Tile2): bool =
  ## Keeps fractional destinations precise while allowing broad path turns.
  let radius =
    if unit.hasGoal and tile == unit.goal and
        unit.goalOffset != FixedVec2Zero:
      fixed(1, 1000)
    else:
      PathArrive
  length(unit.waypointPosition(tile) - unit.body.pos) <= radius

proc steerUnit(w: World, index: int32, toward: FixedVec2) =
  ## Turns and slides one unit, then syncs its tile.
  walkWorld = w
  let before = w.units[index].body.pos
  steer(
    w.units[index].body,
    toward,
    w.units[index].moveSpeed,
    BodyTurnRate,
    lvdTilesWalkable
  )
  w.units[index].applyBody()
  if w.units[index].body.pos == before:
    inc w.units[index].blockedTicks
    if w.units[index].blockedTicks >= AbandonAfterTicks:
      w.units[index].clearOrder(true)
  else:
    w.units[index].blockedTicks = 0
    w.units[index].animation = RunAnimation

proc advanceMovement(w: World, index: int32) =
  ## Steers toward the next pulled waypoint. Does not cut toward the goal
  ## when the route is still queued or has run out.
  if not w.units[index].hasGoal:
    return
  if w.units[index].arrivedAt(w.units[index].goal):
    ## Stay on the order. Clearing the goal here left harvest and build
    ## peons idle-not-idle after a shove off the ring.
    return
  if w.units[index].tile == w.units[index].goal:
    w.steerUnit(
      index, w.units[index].waypointPosition(w.units[index].goal) - w.units[index].body.pos)
    return
  if w.units[index].path.len == 0:
    w.requestPath(index)
    return
  while w.units[index].pathIndex < int32(w.units[index].path.len):
    let waypoint = w.units[index].path[w.units[index].pathIndex]
    if w.units[index].arrivedAt(waypoint):
      inc w.units[index].pathIndex
      continue
    w.steerUnit(index, w.units[index].waypointPosition(waypoint) - w.units[index].body.pos)
    if w.units[index].blockedTicks >= RepathAfterTicks:
      w.units[index].blockedTicks = 0
      w.units[index].clearPath()
      w.requestPath(index)
      w.units[index].repathCooldown = RepathCooldownTicks
    return
  w.units[index].clearPath()
  w.requestPath(index)
  w.units[index].repathCooldown = ShortPathCooldownTicks

proc servePathQueue(w: World) {.measure.} =
  ## Runs a bounded number of searches per tick, oldest request first.
  var served = 0
  while served < PathBudgetPerTick and w.pathQueue.len > 0:
    let request = w.pathQueue[0]
    w.pathQueue.delete(0)
    inc served
    let index = w.unitIndex(request.unitId)
    if index < 0 or not w.units[index].hasGoal or
        w.units[index].goal != request.goal:
      continue
    let complete = w.findPath(
      w.units[index].tile,
      w.units[index].goal,
      w.units[index].id,
      w.units[index].path
    )
    w.units[index].pathGoal = w.units[index].goal
    w.units[index].pathIndex = 0
    while w.units[index].pathIndex < int32(w.units[index].path.len) and
        w.units[index].arrivedAt(
          w.units[index].path[w.units[index].pathIndex]
        ):
      inc w.units[index].pathIndex
    if w.units[index].pathIndex < int32(w.units[index].path.len):
      let toward = w.units[index].waypointPosition(
        w.units[index].path[w.units[index].pathIndex]
      ) - w.units[index].body.pos
      if toward != FixedVec2Zero:
        w.units[index].body.facing = angle(toward)
        w.units[index].applyBody()
    if not complete:
      if w.units[index].path.len == 0:
        ## Genuinely nowhere to go. An empty path with `complete` set just
        ## means the unit is already standing on its goal, which is success.
        w.units[index].clearOrder(true)
      else:
        w.units[index].repathCooldown = ShortPathCooldownTicks

## Harvesting

proc beginMineTrip(w: World, index, mineId: int32) =
  ## Sends a peon to a gold mine, or fails the order when it cannot be used.
  let mine = w.buildingIndex(mineId)
  if mine < 0 or w.buildings[mine].goldLeft <= 0:
    w.units[index].clearOrder(true)
    return
  if not w.footprintGoal(index, w.buildings[mine].origin,
      w.buildings[mine].footprint):
    return
  w.units[index].state = UnitToMine
  w.units[index].targetId = mineId
  w.units[index].sourceId = mineId
  w.units[index].targetTile = NoTile

proc beginTreeTrip(w: World, index, treeIndex: int32) =
  ## Sends a peon to a standing tree.
  if treeIndex < 0 or treeIndex >= GridCells or w.treeWood[treeIndex] <= 0:
    w.units[index].clearOrder(true)
    return
  ## A tree fills its own tile, so the goal is the ring around it.
  let tile = tile2(treeIndex mod GridSide, treeIndex div GridSide)
  if not w.footprintGoal(index, tile, (1'i32, 1'i32)):
    return
  w.units[index].state = UnitToTree
  w.units[index].targetId = NoEntity
  w.units[index].sourceId = NoEntity
  w.units[index].targetTile = tile

proc beginDropOff(w: World, index: int32, wantWood: bool) =
  ## Sends a loaded peon to the nearest structure that accepts its cargo,
  ## keeping hold of which mine or tree it should return to afterwards.
  let
    owner = w.units[index].owner
    keepTile = w.units[index].targetTile
    keepSource = w.units[index].sourceId
    target = w.nearestDropOff(owner, w.units[index].tile, wantWood)
  if target == NoEntity:
    w.units[index].clearOrder(true)
    return
  let structure = w.buildingIndex(target)
  if not w.footprintGoal(index, w.buildings[structure].origin,
      w.buildings[structure].footprint):
    return
  w.units[index].state = if wantWood: UnitToDropWood else: UnitToDropGold
  w.units[index].targetId = target
  w.units[index].targetTile = keepTile
  w.units[index].sourceId = keepSource

proc resumeTreeWork(w: World, index: int32) =
  ## Returns a peon to its tree, or the nearest standing tree in that grove.
  let tile = w.units[index].targetTile
  if inGrid(tile) and w.treeWood[tileIndex(tile)] > 0:
    w.beginTreeTrip(index, tileIndex(tile))
    return
  let fromTile =
    if inGrid(tile):
      tile
    else:
      w.units[index].tile
  let next = w.nearestTree(fromTile)
  if next >= 0:
    w.beginTreeTrip(index, next)
    return
  w.units[index].clearOrder(true)

proc handleInMine(w: World, index: int32) =
  ## Counts down a mining shift and pushes the peon back out with its load.
  if w.units[index].stateTicks > 0:
    dec w.units[index].stateTicks
    return
  let mine = w.buildingIndex(w.units[index].sourceId)
  if mine < 0:
    return  # razeBuilding puts stranded miners back on the map
  let exit = w.freeTileAround(w.buildings[mine].origin,
    w.buildings[mine].footprint)
  if not inGrid(exit):
    return  # the ring is full; try again next tick
  let carried = min(GoldPerTrip, w.buildings[mine].goldLeft)
  w.buildings[mine].goldLeft -= carried
  dec w.buildings[mine].minersInside
  w.place(w.units[index], exit)
  w.units[index].stepTicks = 0
  w.units[index].carryGold = carried
  w.beginDropOff(index, false)

proc handleChopping(w: World, index: int32) =
  ## Counts down one chopping session and fells the tree when it runs dry.
  if w.units[index].stateTicks > 0:
    dec w.units[index].stateTicks
    w.units[index].animation = AttackAnimation
    return
  let treeIndex = tileIndex(w.units[index].targetTile)
  if w.treeWood[treeIndex] <= 0:
    w.resumeTreeWork(index)
    return
  let carried = min(WoodPerTrip, int32(w.treeWood[treeIndex]))
  w.treeWood[treeIndex] = int16(int32(w.treeWood[treeIndex]) - carried)
  if w.treeWood[treeIndex] <= 0:
    w.removeTree(treeIndex)
  w.units[index].carryWood = carried
  w.beginDropOff(index, true)

template trace(w: World, message: string) =
  ## Opt-in narration of one unit's economy decisions. Compile with
  ## `-d:lvdTrace` when a peon is doing something inexplicable.
  when defined(lvdTrace):
    echo "t", w.tick, " ", message

proc resumeHarvest(w: World, index: int32) =
  ## Sends an unloaded peon back to whichever resource it is assigned to.
  ## A mine assignment wins over a tree, and the two are mutually exclusive
  ## because each `begin*Trip` clears the other.
  if w.units[index].sourceId != NoEntity:
    w.beginMineTrip(index, w.units[index].sourceId)
    return
  w.resumeTreeWork(index)

proc handleDeposit(w: World, index: int32) =
  ## Credits a delivered load and sends the peon straight back out. Peons
  ## repeat their round trip until told otherwise, as they do in the game
  ## this borrows from.
  if w.units[index].stateTicks > 0:
    dec w.units[index].stateTicks
    return
  let owner = w.units[index].owner
  w.trace("unit " & $w.units[index].id & " deposits " &
    $w.units[index].carryGold & " gold and " & $w.units[index].carryWood &
    " wood")
  if w.units[index].carryGold > 0:
    w.players[owner].gold += w.units[index].carryGold
    w.players[owner].goldGathered += w.units[index].carryGold
    w.units[index].carryGold = 0
  else:
    w.players[owner].wood += w.units[index].carryWood
    w.players[owner].woodGathered += w.units[index].carryWood
    w.units[index].carryWood = 0
  w.resumeHarvest(index)

proc handleMineArrival(w: World, index: int32) =
  ## Puts a peon inside a mine when there is room, or leaves it queuing.
  if w.units[index].carryGold > 0 or w.units[index].carryWood > 0:
    ## Never walk a full load back into the ground.
    w.beginDropOff(index, w.units[index].carryWood > 0)
    return
  let mine = w.buildingIndex(w.units[index].sourceId)
  if mine < 0 or w.buildings[mine].goldLeft <= 0:
    w.units[index].clearOrder(true)
    return
  if w.buildings[mine].minersInside >= MinersPerMine:
    return
  w.occupancy[tileIndex(w.units[index].tile)] = 0
  inc w.buildings[mine].minersInside
  w.units[index].state = UnitInMine
  w.units[index].stateTicks = MineTicks
  w.units[index].hasGoal = false
  w.units[index].clearPath()

## Units

proc tryAcquire(w: World, index: int32): bool =
  ## Starts a chase if a visible enemy is in sight. Returns whether one was.
  ## Scans are staggered by identifier so a full army does not search every
  ## tick.
  if (w.tick + w.units[index].id) mod AcquireStagger != 0:
    return false
  let target = w.acquireTarget(w.units[index])
  if target == NoEntity:
    return false
  w.units[index].targetId = target
  w.units[index].state = UnitChasing
  true

proc autoAcquire(w: World, index: int32) =
  ## Idle soldiers defend themselves. Peons never do, so a worker told to
  ## stand somewhere does not wander off and die.
  if w.units[index].kind == PeonUnit:
    return
  discard w.tryAcquire(index)

proc finishCombat(w: World, index: int32, failed: bool) =
  ## Resumes an attack-move destination after a fight, or returns to idle.
  let
    dest = w.units[index].attackMoveGoal
    radius =
      if w.units[index].attackMoveOffset != FixedVec2Zero:
        fixed(1, 1000)
      else:
        PathArrive
  if w.units[index].attackMove and inGrid(dest) and
      length(tileCenter(dest) + w.units[index].attackMoveOffset -
        w.units[index].body.pos) > radius:
    w.units[index].targetId = NoEntity
    w.units[index].state = UnitMoving
    w.units[index].blockedTicks = 0
    w.setGoal(index, dest, w.units[index].attackMoveOffset)
    return
  w.units[index].clearOrder(failed)

proc entityArmor(w: World, id: int32): int32 =
  ## Returns the armor of a living target, or zero for structures.
  if id.isUnitId:
    let index = w.unitIndex(id)
    if index >= 0:
      let unit = w.units[index]
      return UnitTable[unit.owner][unit.kind].armor
  0

proc applySplash(w: World, origin: Tile2, amount, skipId, attacker: int32) =
  ## Deals piercing splash to every neighbour of an impact tile.
  var hits: seq[int32]
  for unit in w.units:
    if unit.id == skipId or unit.state == UnitDying or
        unit.state == UnitInMine:
      continue
    if tileDistance(unit.tile, origin) == 1:
      hits.add unit.id
  for structure in w.buildings:
    if structure.id == skipId or structure.owner < 0 or
        structure.state == BuildingDying:
      continue
    if w.footprintDistance(origin, structure) == 1:
      hits.add structure.id
  for id in hits:
    w.damageEntity(id, amount, attacker)

proc strikeTarget(w: World, index: int32, target: int32) =
  ## Rolls miss, then applies piercing plus armor-reduced basic, then splash.
  let stats = UnitTable[w.units[index].owner][w.units[index].kind]
  if stats.missPercent > 0 and w.rng.chance(stats.missPercent):
    return
  w.damageEntity(
    target, attackDamage(stats, w.entityArmor(target)), w.units[index].owner
  )
  if stats.splash > 0:
    w.applySplash(
      w.entityTile(target), stats.splash, target, w.units[index].owner
    )

proc handleCombat(w: World, index: int32) =
  ## Chases a target until it is in range, then swings on cooldown.
  let target = w.units[index].targetId
  if not w.entityAlive(target):
    w.finishCombat(index, true)
    return
  if not w.entityVisible(w.units[index].owner, target):
    w.finishCombat(index, false)
    return
  let
    stats = UnitTable[w.units[index].owner][w.units[index].kind]
    distance = w.rangeToTarget(w.units[index], target)
  if distance <= stats.rangeTiles:
    w.units[index].state = UnitAttacking
    w.units[index].hasGoal = false
    w.units[index].clearPath()
    let targetTile = w.entityTile(target)
    let toward = tileCenter(targetTile) - w.units[index].body.pos
    if toward != FixedVec2Zero:
      turnToward(w.units[index].body.facing, angle(toward), FixedPi)
      w.units[index].applyBody()
    if w.units[index].cooldown <= 0:
      w.units[index].cooldown = stats.cooldownTicks
      w.units[index].animation =
        if (w.units[index].id + w.tick) mod 2 == 0: AttackAnimation
        else: AttackAlternateAnimation
      w.units[index].animationTicks = 0
      w.strikeTarget(index, target)
    return
  w.units[index].state = UnitChasing
  if w.units[index].repathCooldown > 0:
    return
  let targetTile = w.entityTile(target)
  if not w.units[index].hasGoal or
      not inGrid(w.units[index].pathGoal) or
      tileDistance(targetTile, w.units[index].pathGoal) > 4:
    if target.isBuildingId:
      let structure = w.buildingIndex(target)
      if not w.footprintGoal(index, w.buildings[structure].origin,
          w.buildings[structure].footprint):
        return
      w.units[index].state = UnitChasing
      w.units[index].targetId = target
    else:
      w.setGoal(index, targetTile)
      w.units[index].repathCooldown = RepathCooldownTicks

proc advanceUnit(w: World, index: int32) =
  ## Runs one unit for one tick.
  if w.units[index].state == UnitDying:
    inc w.units[index].animationTicks
    dec w.units[index].deathTicks
    return

  inc w.units[index].animationTicks
  if w.units[index].cooldown > 0:
    dec w.units[index].cooldown
  if w.units[index].repathCooldown > 0:
    dec w.units[index].repathCooldown

  let tile = w.units[index].tile
  case w.units[index].state
  of UnitDying:
    return
  of UnitInMine:
    w.handleInMine(index)
    return
  of UnitChopping:
    w.handleChopping(index)
    return
  of UnitBuilding:
    let site = w.buildingIndex(w.units[index].targetId)
    if site < 0 or w.buildings[site].state != BuildingUnderConstruction:
      w.units[index].clearOrder(site < 0)
    else:
      w.units[index].animation = AttackAnimation
    return
  of UnitDepositGold, UnitDepositWood:
    w.handleDeposit(index)
    return
  of UnitIdle:
    w.units[index].animation = IdleAnimation
    w.autoAcquire(index)
    if w.units[index].state == UnitIdle:
      return
  of UnitAttacking, UnitChasing:
    w.handleCombat(index)
  of UnitMoving:
    if w.units[index].attackMove and w.tryAcquire(index):
      w.handleCombat(index)
    elif tile == w.units[index].goal:
      w.units[index].clearOrder(false)
      return
  of UnitToMine:
    let mine = w.buildingIndex(w.units[index].sourceId)
    if mine < 0:
      w.units[index].clearOrder(true)
      return
    if adjacentToFootprint(
      w.buildings[mine].origin,
      w.buildings[mine].footprint,
      int32(tile.x),
      int32(tile.y)
    ):
      w.handleMineArrival(index)
      return
  of UnitToTree:
    if tileDistance(tile, w.units[index].targetTile) <= 1:
      let treeIndex = tileIndex(w.units[index].targetTile)
      if w.treeWood[treeIndex] <= 0:
        w.units[index].clearOrder(true)
      else:
        w.units[index].state = UnitChopping
        w.units[index].stateTicks = ChopTicks
        w.units[index].hasGoal = false
        w.units[index].clearPath()
      return
  of UnitToDropGold, UnitToDropWood:
    let structure = w.buildingIndex(w.units[index].targetId)
    if structure < 0:
      ## The depot went down mid-trip; look for another one.
      w.beginDropOff(index, w.units[index].carryWood > 0)
      return
    if adjacentToFootprint(w.buildings[structure].origin,
        w.buildings[structure].footprint, int32(tile.x), int32(tile.y)):
      w.units[index].state =
        if w.units[index].carryWood > 0: UnitDepositWood else: UnitDepositGold
      w.units[index].stateTicks = DepositTicks
      w.units[index].hasGoal = false
      w.units[index].clearPath()
      return
  of UnitToBuild:
    let site = w.buildingIndex(w.units[index].targetId)
    if site < 0 or w.buildings[site].state != BuildingUnderConstruction:
      w.units[index].clearOrder(true)
      return
    if adjacentToFootprint(
      w.buildings[site].origin,
      w.buildings[site].footprint,
      int32(tile.x),
      int32(tile.y)
    ):
      w.buildings[site].builderId = w.units[index].id
      w.units[index].state = UnitBuilding
      w.units[index].hasGoal = false
      w.units[index].clearPath()
      return

  w.advanceMovement(index)

## Structures

proc advanceBuilding(w: World, index: int32) =
  ## Runs one structure for one tick: construction, training, and towers.
  if w.buildings[index].state == BuildingDying:
    dec w.buildings[index].deathTicks
    return
  if w.buildings[index].owner < 0:
    return

  if w.buildings[index].state == BuildingUnderConstruction:
    let builderIndex = w.unitIndex(w.buildings[index].builderId)
    if builderIndex < 0:
      w.buildings[index].builderId = NoEntity
      return  # paused until another peon adopts the site
    if w.units[builderIndex].state != UnitBuilding:
      return
    dec w.buildings[index].buildTicks
    let
      stats = BuildingTable[w.buildings[index].kind]
      done = w.buildings[index].buildTotal - w.buildings[index].buildTicks
    w.buildings[index].hp = max(1'i32, int32(
      int64(stats.hp) * int64(done) div int64(w.buildings[index].buildTotal)))
    if w.buildings[index].buildTicks <= 0:
      w.buildings[index].state = BuildingComplete
      w.buildings[index].hp = stats.hp
      w.buildings[index].builderId = NoEntity
      inc w.players[w.buildings[index].owner].buildingsBuilt
      w.units[builderIndex].clearOrder(false)
      w.recomputeFoodCap(w.buildings[index].owner)
    return

  if w.buildings[index].queueLength > 0:
    if w.buildings[index].trainTicks > 0:
      dec w.buildings[index].trainTicks
    if w.buildings[index].trainTicks <= 0:
      let
        kind = UnitKind(w.buildings[index].queue[0] - 1)
        spawn = w.freeTileAround(w.buildings[index].origin,
          w.buildings[index].footprint)
      if inGrid(spawn):
        let
          owner = w.buildings[index].owner
          id = w.spawnUnit(owner, kind, spawn)
        inc w.players[owner].unitsTrained
        for slot in 0 ..< w.buildings[index].queueLength - 1:
          w.buildings[index].queue[slot] = w.buildings[index].queue[slot + 1]
        dec w.buildings[index].queueLength
        w.buildings[index].queue[w.buildings[index].queueLength] = 0
        if w.buildings[index].queueLength > 0:
          w.buildings[index].trainTicks =
            UnitTable[owner][UnitKind(
              w.buildings[index].queue[0] - 1
            )].trainTicks
        if w.buildings[index].hasRally:
          let unitIndex = w.unitIndex(id)
          w.setGoal(unitIndex, w.buildings[index].rally)
          if w.units[unitIndex].hasGoal:
            w.units[unitIndex].state = UnitMoving

  let stats = BuildingTable[w.buildings[index].kind]
  if stats.damage > 0:
    if w.buildings[index].cooldown > 0:
      dec w.buildings[index].cooldown
    elif (w.tick + w.buildings[index].id) mod TowerStagger == 0:
      ## Staggered for the same reason units are: a ready tower otherwise
      ## rescans every enemy on the map on every tick it is not firing.
      let enemy = 1 - w.buildings[index].owner
      var
        target = NoEntity
        best = int32.high
      for other in w.units:
        if other.owner != enemy or other.state == UnitDying or
            other.state == UnitInMine:
          continue
        let distance = w.footprintDistance(other.tile, w.buildings[index])
        if distance > stats.rangeTiles:
          continue
        if distance < best or (distance == best and other.id < target):
          best = distance
          target = other.id
      if target != NoEntity:
        w.buildings[index].cooldown = stats.cooldownTicks
        w.damageEntity(target, stats.damage, w.buildings[index].owner)

## Tech and placement

proc unitCount*(w: World, player: int32): int32 =
  ## Counts a player's living units.
  for unit in w.units:
    if unit.owner == player and unit.state != UnitDying:
      inc result

proc techMet*(w: World, player: int32, requires: set[BuildingKind]): bool =
  ## Returns whether a player has a completed structure of every kind named.
  for required in requires:
    var found = false
    for structure in w.buildings:
      if structure.owner == player and structure.kind == required and
          structure.state == BuildingComplete:
        found = true
        break
    if not found:
      return false
  true

proc canPlace*(w: World, kind: BuildingKind, x, y: int32): bool =
  ## Returns whether a footprint would fit: on the map, on open terrain, and
  ## clear of trees, other structures, and every unit.
  let size = BuildingTable[kind].footprint
  for tileY in y ..< y + size.depth:
    for tileX in x ..< x + size.width:
      if not w.tileFree(tileX, tileY):
        return false
  true

proc canBuild*(w: World, player: int32, kind: BuildingKind): bool =
  ## Returns whether a player could afford and is teched for a structure.
  if kind > BuildableHigh:
    return false
  let stats = BuildingTable[kind]
  w.players[player].gold >= stats.gold and
    w.players[player].wood >= stats.wood and
    w.techMet(player, stats.requires)

proc canTrain*(w: World, buildingId: int32, kind: UnitKind): bool =
  ## Returns whether a structure could start training a unit right now.
  let index = w.buildingIndex(buildingId)
  if index < 0:
    return false
  let structure = w.buildings[index]
  if structure.owner < 0 or structure.state != BuildingComplete:
    return false
  let stats = UnitTable[structure.owner][kind]
  if stats.trainedAt != structure.kind:
    return false
  if structure.queueLength >= QueueSlots:
    return false
  let player = w.players[structure.owner]
  player.gold >= stats.gold and player.wood >= stats.wood and
    player.foodUsed + stats.food <= player.foodCap and
    w.techMet(structure.owner, stats.requires) and
    w.unitCount(structure.owner) < UnitsPerPlayer

## Orders
##
## Each of these is the single validator for one command kind. Recording
## lives on `Game` so a replay tape is not part of world state.

proc ownedUnit(w: World, player, unitId: int32): int32 =
  ## Returns the index of a unit the player may command, or -1.
  let index = w.unitIndex(unitId)
  if index < 0 or w.units[index].owner != player or
      w.units[index].state == UnitDying:
    return -1
  index

proc ownedBuilding(w: World, player, buildingId: int32): int32 =
  ## Returns the index of a structure the player may command, or -1.
  let index = w.buildingIndex(buildingId)
  if index < 0 or w.buildings[index].owner != player or
      w.buildings[index].state == BuildingDying:
    return -1
  index

proc applyMove*(w: World, player, unitId, x, y: int32,
    offset = FixedVec2Zero): bool =
  ## Walks a unit to a tile.
  let index = w.ownedUnit(player, unitId)
  if index < 0 or not inGrid(x, y) or not w.terrainOpen(x, y) or
      not offset.validTileOffset:
    return false
  if w.units[index].state == UnitInMine:
    return false
  w.units[index].orderFailed = false
  w.units[index].clearOrder(false)
  w.units[index].state = UnitMoving
  w.setGoal(index, tile2(x, y), offset)
  true

proc applyAttackMove*(w: World, player, unitId, x, y: int32,
    offset = FixedVec2Zero): bool =
  ## Walks a unit to a tile, stopping to fight whoever enters its sight.
  let index = w.ownedUnit(player, unitId)
  if index < 0 or not inGrid(x, y) or not w.terrainOpen(x, y) or
      not offset.validTileOffset:
    return false
  if w.units[index].state == UnitInMine:
    return false
  let dest = tile2(x, y)
  w.units[index].orderFailed = false
  w.units[index].clearOrder(false)
  w.units[index].attackMove = true
  w.units[index].attackMoveGoal = dest
  w.units[index].attackMoveOffset = offset
  w.units[index].state = UnitMoving
  w.setGoal(index, dest, offset)
  true

proc applyAttack*(w: World, player, unitId, targetId: int32): bool =
  ## Sends a unit after an enemy.
  let index = w.ownedUnit(player, unitId)
  if index < 0 or w.units[index].state == UnitInMine:
    return false
  if not w.entityAlive(targetId):
    return false
  if not w.entityVisible(player, targetId):
    return false
  let owner =
    if targetId.isUnitId: w.unitOwner(targetId)
    else: w.buildingOwner(targetId)
  if owner == player or owner < 0:
    return false
  w.units[index].orderFailed = false
  w.units[index].clearOrder(false)
  w.units[index].state = UnitChasing
  w.units[index].targetId = targetId
  true

proc applyHarvest*(w: World, player, unitId, target, isTree: int32): bool =
  ## Puts a peon on a gold mine or a tree.
  let index = w.ownedUnit(player, unitId)
  if index < 0 or w.units[index].kind != PeonUnit or
      w.units[index].state == UnitInMine:
    return false
  ## A peon holding a load delivers it first and takes up the new assignment
  ## afterwards. Reassigning a loaded peon must never throw the load away.
  let carrying = w.units[index].carryGold > 0 or w.units[index].carryWood > 0
  w.trace("harvest order to unit " & $unitId & " in state " &
    $w.units[index].state & " carrying " & $carrying & " target " & $target)

  ## Validate the resource completely before anything is written, so a
  ## refusal is genuinely a no-op and needs no replay entry.
  if isTree == 0:
    let mine = w.buildingIndex(target)
    if mine < 0 or w.buildings[mine].kind != GoldMineBuilding or
        w.buildings[mine].goldLeft <= 0:
      return false
  else:
    if target < 0 or target >= GridCells or w.treeWood[target] <= 0:
      return false

  w.units[index].orderFailed = false
  if isTree == 0:
    if carrying:
      w.units[index].sourceId = target
      w.units[index].targetTile = NoTile
      w.beginDropOff(index, w.units[index].carryWood > 0)
    else:
      w.units[index].clearOrder(false)
      w.beginMineTrip(index, target)
  else:
    if carrying:
      w.units[index].sourceId = NoEntity
      w.units[index].targetTile =
        tile2(target mod GridSide, target div GridSide)
      w.beginDropOff(index, w.units[index].carryWood > 0)
    else:
      w.units[index].clearOrder(false)
      w.beginTreeTrip(index, target)
  ## The unit may still fail to reach it, which shows up as `orderFailed`
  ## rather than as a refusal, because the command itself was accepted.
  true

proc applyBuild*(w: World, player, peonId, kindValue, x, y: int32): bool =
  ## Places a construction site and sends a peon to raise it.
  let index = w.ownedUnit(player, peonId)
  if index < 0 or w.units[index].kind != PeonUnit or
      w.units[index].state == UnitInMine:
    return false
  if kindValue < 0 or kindValue > int32(BuildableHigh.ord):
    return false
  let
    kind = BuildingKind(kindValue)
    stats = BuildingTable[kind]
    origin = tile2(x, y)
  if not inGrid(x, y) or not inGrid(x + stats.footprint.width - 1,
      y + stats.footprint.depth - 1):
    return false
  if not w.techMet(player, stats.requires):
    return false

  ## An existing site of the same kind and place is adopted rather than paid
  ## for twice, which is how a replacement builder resumes stalled work.
  var siteId = NoEntity
  for structure in w.buildings:
    if structure.owner == player and structure.kind == kind and
        structure.origin == origin and
        structure.state == BuildingUnderConstruction and
        structure.builderId == NoEntity:
      siteId = structure.id
      break

  if siteId == NoEntity:
    if not w.canPlace(kind, x, y):
      return false
    if w.players[player].gold < stats.gold or
        w.players[player].wood < stats.wood:
      return false
    w.players[player].gold -= stats.gold
    w.players[player].wood -= stats.wood
    siteId = w.nextBuildingId
    inc w.nextBuildingId
    w.registerBuilding Building(
      id: siteId,
      owner: player,
      kind: kind,
      origin: origin,
      footprint: stats.footprint,
      hp: 1,
      maxHp: stats.hp,
      state: BuildingUnderConstruction,
      buildTicks: stats.buildTicks,
      buildTotal: stats.buildTicks,
      builderId: NoEntity,
      rally: NoTile
    )

  let site = w.buildingIndex(siteId)
  w.units[index].orderFailed = false
  w.units[index].clearOrder(false)
  if w.footprintGoal(
    index,
    w.buildings[site].origin,
    w.buildings[site].footprint
  ):
    w.units[index].state = UnitToBuild
    w.units[index].targetId = siteId
  else:
    ## Nothing can reach the site. It stays as a paused shell, so the
    ## resources are recoverable with a cancel and another peon can adopt it.
    w.units[index].orderFailed = true
  true

proc applyTrain*(w: World, player, buildingId, kindValue: int32): bool =
  ## Queues one unit at a structure.
  let index = w.ownedBuilding(player, buildingId)
  if index < 0 or kindValue < 0 or kindValue > int32(UnitKind.high.ord):
    return false
  let kind = UnitKind(kindValue)
  if not w.canTrain(buildingId, kind):
    return false
  let stats = UnitTable[player][kind]
  w.players[player].gold -= stats.gold
  w.players[player].wood -= stats.wood
  w.players[player].foodUsed += stats.food
  if w.buildings[index].queueLength == 0:
    w.buildings[index].trainTicks = stats.trainTicks
  w.buildings[index].queue[w.buildings[index].queueLength] =
    uint8(kindValue + 1)
  inc w.buildings[index].queueLength
  true

proc applySetRally*(w: World, player, buildingId, x, y: int32): bool =
  ## Points newly trained units at a tile.
  let index = w.ownedBuilding(player, buildingId)
  if index < 0 or not inGrid(x, y) or not w.terrainOpen(x, y):
    return false
  w.buildings[index].rally = tile2(x, y)
  w.buildings[index].hasRally = true
  true

proc applyCancel*(w: World, player, entityId: int32): bool =
  ## Stops a unit, refunds the last queued unit, or abandons a build site.
  if entityId.isUnitId:
    let index = w.ownedUnit(player, entityId)
    if index < 0 or w.units[index].state == UnitInMine:
      return false
    w.units[index].orderFailed = false
    w.units[index].clearOrder(false)
    return true

  let index = w.ownedBuilding(player, entityId)
  if index < 0:
    return false
  if w.buildings[index].state == BuildingUnderConstruction:
    let
      stats = BuildingTable[w.buildings[index].kind]
      remaining = w.buildings[index].buildTicks
      total = w.buildings[index].buildTotal
    ## Refund in proportion to the work not yet done, rounded down.
    w.players[player].gold +=
      int32(int64(stats.gold) * int64(remaining) div int64(total))
    w.players[player].wood +=
      int32(int64(stats.wood) * int64(remaining) div int64(total))
    let builderIndex = w.unitIndex(w.buildings[index].builderId)
    if builderIndex >= 0:
      w.units[builderIndex].clearOrder(false)
    w.releaseFootprint(w.buildings[index].origin, w.buildings[index].footprint)
    w.buildings[index].state = BuildingDying
    w.buildings[index].deathTicks = 0
    return true

  if w.buildings[index].queueLength <= 0:
    return false
  let
    slot = w.buildings[index].queueLength - 1
    kind = UnitKind(w.buildings[index].queue[slot] - 1)
    stats = UnitTable[player][kind]
  w.players[player].gold += stats.gold
  w.players[player].wood += stats.wood
  w.players[player].foodUsed -= stats.food
  w.buildings[index].queue[slot] = 0
  dec w.buildings[index].queueLength
  if w.buildings[index].queueLength == 0:
    w.buildings[index].trainTicks = 0
  true

proc applyReplayAction*(w: World, action: ReplayAction): bool {.discardable.} =
  ## Re-executes one recorded command through the same validators.
  let player = int32(action.playerId)
  case action.kind
  of ActionMove:
    w.applyMove(player, action.entityId, action.first, action.second, action.offset)
  of ActionAttackMove:
    w.applyAttackMove(
      player, action.entityId, action.first, action.second, action.offset
    )
  of ActionAttack:
    w.applyAttack(player, action.entityId, action.first)
  of ActionHarvest:
    w.applyHarvest(player, action.entityId, action.first,
      action.second)
  of ActionBuild:
    w.applyBuild(player, action.entityId, action.first,
      action.second, action.third)
  of ActionTrain:
    w.applyTrain(player, action.entityId, action.first)
  of ActionSetRally:
    w.applySetRally(player, action.entityId, action.first,
      action.second)
  of ActionCancel:
    w.applyCancel(player, action.entityId)
  else:
    raise newException(ReplayError, "replay action kind is invalid")

proc record(game: Game, kind: uint8, player, entityId: int32,
    first = 0'i32, second = 0'i32, third = 0'i32,
    offset = FixedVec2Zero) =
  ## Writes one accepted command. Skips when the tape is already past this tick.
  if game.recorder == nil or game.recorder.data.hashes.len >= game.world.tick:
    return
  game.recorder.recordAction(uint32(game.world.tick), player, kind, entityId,
    first, second, third, offset)

proc applyMove*(
    game: Game, player, unitId, x, y: int32, offset = FixedVec2Zero
): bool =
  ## Walks a unit to a tile and records the command when accepted.
  result = game.world.applyMove(player, unitId, x, y, offset)
  if result:
    game.metrics.command(int(player), game.world.tick)
    game.record(ActionMove, player, unitId, x, y, offset = offset)

proc applyAttackMove*(
    game: Game, player, unitId, x, y: int32, offset = FixedVec2Zero
): bool =
  ## Attack-moves a unit and records the command when accepted.
  result = game.world.applyAttackMove(player, unitId, x, y, offset)
  if result:
    game.metrics.command(int(player), game.world.tick)
    game.record(ActionAttackMove, player, unitId, x, y, offset = offset)

proc applyAttack*(
    game: Game, player, unitId, targetId: int32
): bool =
  ## Sends a unit after an enemy and records the command when accepted.
  result = game.world.applyAttack(player, unitId, targetId)
  if result:
    game.metrics.command(int(player), game.world.tick)
    game.record(ActionAttack, player, unitId, targetId)

proc applyHarvest*(
    game: Game, player, unitId, target, isTree: int32
): bool =
  ## Puts a peon on a gold mine or a tree and records the command.
  result = game.world.applyHarvest(player, unitId, target, isTree)
  if result:
    game.metrics.command(int(player), game.world.tick)
    game.record(ActionHarvest, player, unitId, target, isTree)

proc applyBuild*(
    game: Game, player, peonId, kindValue, x, y: int32
): bool =
  ## Starts a building and records the command when accepted.
  result = game.world.applyBuild(player, peonId, kindValue, x, y)
  if result:
    game.metrics.command(int(player), game.world.tick)
    game.record(ActionBuild, player, peonId, kindValue, x, y)

proc applyTrain*(
    game: Game, player, buildingId, kindValue: int32
): bool =
  ## Queues one unit and records the command when accepted.
  result = game.world.applyTrain(player, buildingId, kindValue)
  if result:
    game.metrics.command(int(player), game.world.tick)
    game.record(ActionTrain, player, buildingId, kindValue)

proc applySetRally*(
    game: Game, player, buildingId, x, y: int32
): bool =
  ## Sets a rally point and records the command when accepted.
  result = game.world.applySetRally(player, buildingId, x, y)
  if result:
    game.metrics.command(int(player), game.world.tick)
    game.record(ActionSetRally, player, buildingId, x, y)

proc applyCancel*(
    game: Game, player, entityId: int32
): bool =
  ## Cancels an order and records the command when accepted.
  result = game.world.applyCancel(player, entityId)
  if result:
    game.metrics.command(int(player), game.world.tick)
    game.record(ActionCancel, player, entityId)

## Canonical state hash
##
## Everything that can influence a later tick is mixed in, in exactly this
## order. Anything derivable is left out and named in the `World` comments,
## so adding a field and forgetting it here is a one-file review.

proc mixTile(hash: var uint32, tile: Tile2) =
  ## Mixes one tile by its two integer axes.
  hash.addHashy(tile.x)
  hash.addHashy(tile.y)

proc hashWorld(w: World): uint64 =
  ## Hashes all authoritative state that can affect later simulation ticks.
  var hash = HashySeed
  hash.addHashy(w.tick)
  hash.addHashy(w.rng)
  hash.addHashy(w.over)
  hash.addHashy(w.winner)
  hash.addHashy(w.nextUnitId)
  hash.addHashy(w.nextBuildingId)
  for player in 0 ..< PlayerCount:
    let side = w.players[player]
    hash.addHashy(side.gold)
    hash.addHashy(side.wood)
    hash.addHashy(side.foodUsed)
    hash.addHashy(side.foodCap)
    hash.addHashy(side.goldGathered)
    hash.addHashy(side.woodGathered)
    hash.addHashy(side.unitsTrained)
    hash.addHashy(side.unitsLost)
    hash.addHashy(side.buildingsBuilt)
    hash.addHashy(side.buildingsLost)
    hash.addHashy(side.defeated)
    hash.addHashy(w.exploredCount[player])
  hash.addHashy(w.buildings.len)
  for structure in w.buildings:
    hash.addHashy(structure.id)
    hash.addHashy(structure.owner)
    hash.addHashy(int32(structure.kind.ord))
    hash.mixTile(structure.origin)
    hash.addHashy(structure.footprint.width)
    hash.addHashy(structure.footprint.depth)
    hash.addHashy(structure.hp)
    hash.addHashy(structure.maxHp)
    hash.addHashy(int32(structure.state.ord))
    hash.addHashy(structure.buildTicks)
    hash.addHashy(structure.buildTotal)
    hash.addHashy(structure.builderId)
    for slot in structure.queue:
      hash.addHashy(slot)
    hash.addHashy(structure.queueLength)
    hash.addHashy(structure.trainTicks)
    hash.mixTile(structure.rally)
    hash.addHashy(structure.hasRally)
    hash.addHashy(structure.cooldown)
    hash.addHashy(structure.goldLeft)
    hash.addHashy(structure.minersInside)
    hash.addHashy(structure.deathTicks)
  hash.addHashy(w.units.len)
  for unit in w.units:
    hash.addHashy(unit.id)
    hash.addHashy(unit.owner)
    hash.addHashy(int32(unit.kind.ord))
    hash.mixTile(unit.tile)
    hash.mixTile(unit.fromTile)
    hash.addHashy(unit.stepTicks)
    hash.addHashy(unit.stepTotal)
    hash.addHashy(unit.facingX)
    hash.addHashy(unit.facingY)
    hash.addHashy(unit.hp)
    hash.addHashy(int32(unit.state.ord))
    hash.addHashy(unit.stateTicks)
    hash.addHashy(unit.cooldown)
    hash.addHashy(unit.targetId)
    hash.addHashy(unit.sourceId)
    hash.mixTile(unit.targetTile)
    hash.addHashy(int32(unit.body.pos.x))
    hash.addHashy(int32(unit.body.pos.y))
    hash.addHashy(int32(unit.body.facing))
    hash.mixTile(unit.goal)
    hash.addHashy(int32(unit.goalOffset.x))
    hash.addHashy(int32(unit.goalOffset.y))
    hash.addHashy(unit.hasGoal)
    hash.addHashy(unit.attackMove)
    hash.mixTile(unit.attackMoveGoal)
    hash.addHashy(int32(unit.attackMoveOffset.x))
    hash.addHashy(int32(unit.attackMoveOffset.y))
    hash.addHashy(unit.path.len)
    hash.addHashy(unit.pathIndex)
    for step in unit.path:
      hash.mixTile(step)
    hash.mixTile(unit.pathGoal)
    hash.addHashy(unit.blockedTicks)
    hash.addHashy(unit.repathCooldown)
    hash.addHashy(unit.carryGold)
    hash.addHashy(unit.carryWood)
    hash.addHashy(unit.orderFailed)
    hash.addHashy(int32(unit.animation.ord))
    hash.addHashy(unit.animationTicks)
    hash.addHashy(unit.deathTicks)
  hash.addHashy(w.terrainEdits.len)
  for edit in w.terrainEdits:
    hash.addHashy(edit.tick)
    hash.addHashy(edit.index)
  hash.addHashy(w.pathQueue.len)
  for request in w.pathQueue:
    hash.addHashy(request.unitId)
    hash.mixTile(request.goal)
  hash.addHashy(w.stats)
  uint64(hash)

proc stateHash*(game: Game): uint64 =
  ## Hashes all authoritative state that can affect later simulation ticks.
  hashWorld(game.world)

## Victory

proc buildingCount*(w: World, player: int32): int32 =
  ## Counts a player's standing structures.
  for structure in w.buildings:
    if structure.owner == player and structure.state != BuildingDying:
      inc result

proc peonCount*(w: World, player: int32): int32 =
  ## Counts a player's living peons.
  for unit in w.units:
    if unit.owner == player and unit.kind == PeonUnit and
        unit.state != UnitDying:
      inc result

proc score*(w: World, player: int32): int64 =
  ## Ranks a player when a match reaches its tick limit. Standing structures
  ## dominate, then army, then everything ever gathered.
  int64(w.buildingCount(player)) * 1000 +
    int64(w.unitCount(player)) * 100 +
    (w.players[player].goldGathered + w.players[player].woodGathered) div 100

proc checkVictory(w: World) =
  ## A player is out once it has no structures and no peon left to raise one.
  for player in 0'i32 ..< PlayerCount:
    if w.players[player].defeated:
      continue
    if w.buildingCount(player) == 0 and w.peonCount(player) == 0:
      w.players[player].defeated = true
  if w.over:
    return
  let
    lightOut = w.players[LightPlayer].defeated
    darkOut = w.players[DarkPlayer].defeated
  if lightOut or darkOut:
    w.over = true
    w.winner =
      if lightOut and darkOut: -1
      elif lightOut: DarkPlayer
      else: LightPlayer
    return
  if w.tick >= w.maximumTicks:
    w.over = true
    let
      light = w.score(LightPlayer)
      dark = w.score(DarkPlayer)
    w.winner =
      if light > dark: LightPlayer
      elif dark > light: DarkPlayer
      else: -1

## The tick
##
## Phase order is fixed and is the reason a replay resynchronises: vision is
## rebuilt before decisions so no overlord ever sees stale ground, commands
## land next, then movement, then structures, then removal and the hash.

proc removeDead(w: World) =
  ## Drops corpses and rubble once their timers expire, preserving order.
  var liveUnits = false
  for unit in w.units:
    if unit.state == UnitDying and unit.deathTicks <= 0:
      liveUnits = true
      break
  if liveUnits:
    var write = 0
    for read in 0 ..< w.units.len:
      if w.units[read].state == UnitDying and
          w.units[read].deathTicks <= 0:
        continue
      if write != read:
        w.units[write] = w.units[read]
      inc write
    w.units.setLen(write)
    for slot in 0 ..< w.unitSlot.len:
      w.unitSlot[slot] = -1
    for index, unit in w.units:
      w.unitSlot[unit.id - FirstUnitId] = int32(index)

  var deadBuildings = false
  for structure in w.buildings:
    if structure.state == BuildingDying and structure.deathTicks <= 0:
      deadBuildings = true
      break
  if deadBuildings:
    var kept: seq[Building]
    for structure in w.buildings:
      if structure.state == BuildingDying and structure.deathTicks <= 0:
        continue
      kept.add structure
    w.buildings = kept
    for slot in 0 ..< w.buildingSlot.len:
      w.buildingSlot[slot] = -1
    for index, structure in w.buildings:
      w.buildingSlot[structure.id - FirstMineId] = int32(index)

proc tickWorld*(w: World, decide: proc(w: World) {.closure.}) {.measure.} =
  ## Advances the simulation by exactly one tick.
  if w.over:
    return
  inc w.tick

  if w.tick mod VisionTicks == 0:
    profileBlock "vision":
      w.rebuildVision()
  if w.tick mod DecisionTicks == 0 and decide != nil:
    profileBlock "decisions":
      decide(w)

  profileBlock "searchPath":
    w.servePathQueue()
  profileBlock "units":
    for index in 0 ..< w.units.len:
      w.advanceUnit(int32(index))
  profileBlock "separate":
    walkWorld = w
    for i in 0 ..< w.units.len:
      if w.units[i].state == UnitDying or w.units[i].state == UnitInMine:
        continue
      for j in i + 1 ..< w.units.len:
        if w.units[j].state == UnitDying or w.units[j].state == UnitInMine:
          continue
        separatePair(
          w.units[i].body,
          w.units[j].body,
          lvdTilesWalkable
        )
    for i in 0 ..< w.occupancy.len:
      w.occupancy[i] = 0
    for unit in w.units:
      if unit.state == UnitDying or unit.state == UnitInMine:
        continue
      unit.applyBody()
      if inGrid(unit.tile):
        let index = tileIndex(unit.tile)
        if w.occupancy[index] == 0:
          w.occupancy[index] = unit.id
  profileBlock "buildings":
    for index in 0 ..< w.buildings.len:
      w.advanceBuilding(int32(index))
  profileBlock "cleanup":
    w.removeDead()
    w.checkVictory()

## Setup

proc cloneUnits(units: seq[Unit]): seq[Unit] =
  ## Copies each unit so two worlds never share a path seq.
  result.setLen(units.len)
  for i, unit in units:
    result[i] = Unit()
    result[i][] = unit[]

proc clone*(world: World): World =
  ## Deep copy. Units are refs and must be cloned one by one.
  result = World()
  result[] = world[]
  result.stats = world.stats.clone()
  result.units = cloneUnits(world.units)

proc restore*(world: World, snapshot: World) =
  ## Overwrites in place, keeping the caller's ref identity.
  world[] = snapshot[]
  world.stats = snapshot.stats.clone()
  world.units = cloneUnits(snapshot.units)

proc newWorld*(map: MapData, maximumTicks: int32): World =
  ## Builds the opening position for one match.
  visionSkipWorld = nil
  result = World(
    tick: 0,
    winner: -1,
    stats: newCombatStats(PlayerCount),
    maximumTicks: maximumTicks,
    map: map,
    blocker: newSeq[int32](GridCells),
    treeWood: map.treeWood,
    occupancy: newSeq[int32](GridCells),
    nextUnitId: FirstUnitId,
    nextBuildingId: FirstBuildingId
  )
  result.rng = initRng(map.seed)
  for player in 0 ..< PlayerCount:
    result.visibleStamp[player] = newSeq[uint32](GridCells)
    result.explored[player] = newSeq[uint8](GridCells)
    result.visionGeneration[player] = 0
  for index in 0 ..< GridCells:
    if result.treeWood[index] > 0:
      result.blocker[index] = TreeBlocker

  for mine in map.mines:
    result.registerBuilding Building(
      id: mine.id,
      owner: -1,
      kind: GoldMineBuilding,
      origin: mine.origin,
      footprint: BuildingTable[GoldMineBuilding].footprint,
      hp: BuildingTable[GoldMineBuilding].hp,
      maxHp: BuildingTable[GoldMineBuilding].hp,
      state: BuildingComplete,
      builderId: NoEntity,
      rally: NoTile,
      goldLeft: mine.gold
    )

  for player in 0'i32 ..< PlayerCount:
    let stats = BuildingTable[TownHallBuilding]
    result.registerBuilding Building(
      id: result.nextBuildingId,
      owner: player,
      kind: TownHallBuilding,
      origin: map.hallOrigin[player],
      footprint: stats.footprint,
      hp: stats.hp,
      maxHp: stats.hp,
      state: BuildingComplete,
      builderId: NoEntity,
      rally: NoTile
    )
    inc result.nextBuildingId
    result.players[player].gold = StartingGold
    result.players[player].wood = StartingWood

  var lightSpawns: seq[Tile2]
  for _ in 0 ..< StartingPeons:
    let spawn = result.freeTileAround(map.hallOrigin[LightPlayer],
      BuildingTable[TownHallBuilding].footprint)
    doAssert inGrid(spawn),
      "seed " & $map.seed & ": no room to spawn the opening peons"
    lightSpawns.add spawn
    discard result.spawnUnit(LightPlayer, PeonUnit, spawn)
    result.players[LightPlayer].foodUsed +=
      UnitTable[LightPlayer][PeonUnit].food
  for spawn in lightSpawns:
    let (mx, my) = mirrorTile(int32(spawn.x), int32(spawn.y))
    doAssert result.tileFree(mx, my),
      "seed " & $map.seed & ": Dark opening tile is not free"
    discard result.spawnUnit(DarkPlayer, PeonUnit, tile2(mx, my))
    result.players[DarkPlayer].foodUsed +=
      UnitTable[DarkPlayer][PeonUnit].food
  for player in 0'i32 ..< PlayerCount:
    result.recomputeFoodCap(player)

  result.rebuildVision()

proc sampleMetrics*(game: Game, force = false) =
  ## Samples deterministic world counters and independent VM telemetry.
  if game.metrics == nil or game.world.stats == nil:
    return
  for slot, values in game.world.stats.values:
    for kind in MetricKind:
      game.metrics.set(slot, kind, values[kind])
    game.metrics.set(slot, GoldMetric, game.world.players[slot].goldGathered)
    game.metrics.set(slot, LossesMetric, game.world.players[slot].unitsLost)
    var army = 0'i64
    for unit in game.world.units:
      if unit.owner == slot and unit.kind != PeonUnit and
        unit.state != UnitDying and unit.hp > 0:
          army += UnitTable[unit.owner][unit.kind].gold
    game.metrics.set(slot, ArmyMetric, army)
  game.history.capture(game.metrics, game.world.tick, force)

proc newGame*(map: MapData, maximumTicks: int32): Game =
  ## Builds one match session around a fresh world.
  result = Game(
    metrics: newMetrics(PlayerCount, TickRate),
    world: newWorld(map, maximumTicks),
    mapSeed: map.seed,
    maximumTicks: maximumTicks
  )
  result.sampleMetrics(true)

proc scores*(world: World): seq[int] =
  ## Converts the existing winner into binary scores in platform slot order.
  result.setLen(PlayerCount)
  if world.winner >= 0:
    result[world.winner] = 1
