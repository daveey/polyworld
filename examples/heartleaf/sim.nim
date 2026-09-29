## Heartleaf simulation.
##
## Nine villagers on Q16.16 tile-space bodies walk a fixed village: gather
## the morning vegetables, invite each other around, and be inside the right
## house when the 18:00 tally fires. This module must not import anything
## that returns a float.

import
  bassy, fixxy,
  polyworld/[bodies, hashes, pathing, profiles, rngs, tapes],
  content,
  maps,
  obstacles,
  replays

const
  NoTile* = Tile2(x: -1, y: -1)
  NoHouse* = -1'i32
  NoVillager* = -1'i32
  EmptyGarden* = -1'i8
  VillagerBodyRadius = 0.22'fx
  BodyTurnRate = 0.35'fx
  PathArrive = 0.35'fx
  PathTurn = 0.001'fx
  TalkCircleRadius = 1.5'fx
  TalkCircleRotations = 8
  TalkApproachSamples = 16
  GestureTicks = TickRate
    ## How long a gather or wave pose is held before idling again.

type
  OrderKind* = enum
    NoOrder, MoveOrder, GatherOrder, EnterOrder, TalkOrder

  Villager* = ref object
    slot*: int32
    body*: Body                       # HASH: include
    tile*: Tile2                      # HASH: include, derived cell of body
    fromTile*: Tile2                  # HASH: include, for the renderer
    inHouse*: int32                   # HASH: include, house id or -1 outdoors
    order*: OrderKind                 # HASH: include
    orderTarget*: int32               # HASH: include, garden or house id
    talkCircle*: bool                 # HASH: include
    talkCenter*, talkPosition*: FixedVec2 # HASH: include
    goal*: Tile2                      # HASH: include
    goalOffset*: FixedVec2
    hasGoal*: bool                    # HASH: include
    path*: seq[Tile2]                 # HASH: include
    pathIndex*: int32                 # HASH: include
    pathGoal*: Tile2                  # HASH: include
    blockedTicks*: int32              # HASH: include
    repathCooldown*: int32            # HASH: include
    orderFailed*: bool                # HASH: excluded, an agent mailbox: bots
                                      # read and clear it and the simulation
                                      # never branches on it, so live and
                                      # replay worlds may legitimately differ
    inventory*: array[VeggieKinds, int16]   # HASH: include, survives days
    eaten*: array[VeggieKinds, bool]        # HASH: include, survives all game
    score*: int32                     # HASH: include, cumulative
    hostingTonight*: bool             # HASH: include
    acceptedHost*: int32              # HASH: include, slot or -1
    inviteFrom*: array[VillagerCount, bool]  # HASH: include
    curfewMissed*: bool              # HASH: include, cleared each morning
    lastGained*: int32                # HASH: include, points from last tally
    animation*: AnimationSlot         # HASH: include, viewer parity
    animationTicks*: int32            # HASH: include

  DinnerReport* = object
    ## One house's result from the last 18:00 tally.
    valid*: bool
    visitors*: int32
    pantry*: int32
      ## Items on the table before anyone ate.
    hostPoints*: int32

  DinnerBite* = object
    veggie*, points*: int32

  DailyReport* = object
    startingScore*, dinnerHost*, hostingPoints*, penalty*: int32
    bites*: array[int(BiteRounds), DinnerBite]
    biteCount*: int

  PathRequest* = object
    slot*: int32
    goal*: Tile2

  World* = ref object
    ## One game. A ref so `a = b` aliases and a second world is `clone()`.
    tick*: int32                      # HASH: include
    rng*: Rng                         # HASH: include
    over*: bool                       # HASH: include
    day*: int32                       # HASH: include, 1-based
    dayCount*: int32                  # HASH: include
    maximumTicks*: int32              # HASH: include
    phase*: DayPhase                  # HASH: include
    phaseTicks*: int32                # HASH: include, score screen countdown
    dayTick*: int32                   # HASH: include, ticks into the day
    villagers*: array[VillagerCount, Villager]  # HASH: include; refs
    gardens*: array[GardenCount, int8]  # HASH: include, veggie kind or -1
    pathQueue*: seq[PathRequest]      # HASH: include
    dailyReports*: array[VillagerCount, DailyReport] # HASH: excluded, derived presentation data.
    lastTally*: array[VillagerCount, DinnerReport]  # HASH: include
    map*: MapData                     # HASH: derived, fixed at generation

  VillagerVm* = ref object
    ## One compiled BASIC program for a villager. Not simulation state.
    runtime*: Runtime
    ready*: bool
    failed*: bool
    lastError*: string
    decisions*: int
    lastWork*, lastInstructions*: int64

  Game* = ref object
    ## One game session. World is the hashable sim; everything else is tape
    ## and agents. The generated map lives on `world.map`.
    world*: World
    recorder*: ReplayRecorder
    replayData*: ReplayData
    replayPlayer*: ReplayPlayer
    hashCheck*: ReplayHashCheck
    historyPlayback*: bool
    replayMode*: bool
    brains*: array[VillagerCount, VillagerVm]
    mapSeed*: int32
    maximumTicks*: int32
    dayCount*: int32

## Clock

proc minuteOfDay*(w: World): int32 =
  ## Wall-clock minute of the current day, 9:00 at dawn.
  minuteOfDayAt(w.dayTick)

proc dinnerDone*(w: World): bool =
  ## Whether today's 18:00 tally has already fired.
  w.phase != DaytimePhase

## Queries

proc validSlot*(slot: int32): bool =
  slot >= 0 and slot < VillagerCount

proc validGarden*(garden: int32): bool =
  garden >= 0 and garden < GardenCount

proc carriedTotal*(v: Villager): int32 =
  ## Total items in one villager's bag.
  for count in v.inventory:
    result += int32(count)

proc doorOf*(w: World, house: int32): Tile2 =
  ## The doorstep tile of one house.
  w.map.houses[house].door

proc terrainOpen*(w: World, x, y: int32): bool =
  ## Returns whether a villager may stand on a tile. Walkability is fixed at
  ## generation; nothing in the simulation ever changes it.
  inGrid(x, y) and w.map.passable[tileIndex(x, y)] == 1

proc tileCenter(tile: Tile2): FixedVec2 =
  ## Returns the tile-space centre of one cell.
  fixedVec2(
    fixed(int32(tile.x)) + 0.5'fx,
    fixed(int32(tile.y)) + 0.5'fx
  )

## Pathfinding
##
## Terrain walkability is a callback into the fixed map. Garden plots stay
## walkable but pay extra so idle traffic goes around the beds.

var
  pathSearches*, pathExpansions*: int
    ## Diagnostics only. Never hashed, never read by the simulation.
  pathWorld: World
  walkWorld: World
  pathTiles: seq[PathTile]

proc hlfPathWalkable(layer, x, z: int): bool {.nimcall.} =
  ## Reads the generated map without depending on renderer terrain state.
  layer == 0 and pathWorld.terrainOpen(int32(x), int32(z))

proc hlfPathClearance(first, last: PathTile): bool {.nimcall.} =
  ## Keeps both A* edges and pulled paths clear of thin fence rails.
  if first.layer != 0 or last.layer != 0:
    return false
  let
    a = tile2(first.x, first.z)
    b = tile2(last.x, last.z)
  if chebyshev(a, b) == 1:
    pathWorld.map.canStep(a, b)
  else:
    pathWorld.map.propsClear(a, b)

proc hlfPathTerrain(layer, x, z: int): bool {.nimcall.} =
  ## Leaves sub-tile obstacles to the precise clearance test during smoothing.
  layer == 0 and inGrid(x.int32, z.int32) and
    pathWorld.map.terrain[tileIndex(x.int32, z.int32)] != 0

proc hlfPathEnterCost(layer, x, z: int): int32 {.nimcall.} =
  if layer != 0 or not inGrid(int32(x), int32(z)):
    return 0
  if pathWorld.map.kinds[tileIndex(int32(x), int32(z))] ==
      uint8(GardenTileKind):
    GardenEnterCost
  else:
    0

proc townPoint(pos: FixedVec2): tuple[x, z: int32] =
  ## Converts body coordinates to the obstacle map's integer town origin.
  (
    int32(int64(int32(pos.x)) * ObstacleUnits div FixedScale) -
      (GridSide div 2 * ObstacleUnits + ObstacleUnits div 2),
    int32(int64(int32(pos.y)) * ObstacleUnits div FixedScale) -
      (GridSide div 2 * ObstacleUnits + ObstacleUnits div 2)
  )

proc positionOpen*(w: World, pos: FixedVec2): bool =
  ## Checks terrain and the villager's radius against solid village props.
  let (x, z) = cell(pos)
  if not inGrid(x, z) or w.map.terrain[tileIndex(x, z)] == 0:
    return false
  let point = townPoint(pos)
  w.map.obstacles.obstaclesClear(point.x, point.z, point.x, point.z)

proc travelClear*(
  w: World, first, last: FixedVec2, clearance = VillagerClearance
): bool =
  ## Sweeps the whole move so narrow rails cannot be crossed within a tile.
  let
    a = townPoint(first)
    b = townPoint(last)
  if not w.map.obstacles.obstaclesClear(a.x, a.z, b.x, b.z, clearance):
    return false
  proc terrain(x, z: int32): bool =
    ## Reads only floor and house tiles during exact grid traversal.
    inGrid(x, z) and w.map.terrain[tileIndex(x, z)] != 0
  let
    start = cell(first)
    finish = cell(last)
    dx = int64(int32(last.x)) - int32(first.x)
    dz = int64(int32(last.y)) - int32(first.y)
    sx = cmp(dx, 0).int32
    sz = cmp(dz, 0).int32
  if not terrain(start.x, start.z) or not terrain(finish.x, finish.z):
    return false
  var
    x = start.x
    z = start.z
    nextX =
      if sx > 0: int64(x + 1) * FixedScale - int32(first.x)
      else: int64(int32(first.x)) - int64(x) * FixedScale
    nextZ =
      if sz > 0: int64(z + 1) * FixedScale - int32(first.y)
      else: int64(int32(first.y)) - int64(z) * FixedScale
  while x != finish.x or z != finish.z:
    let
      crossX = nextX * abs(dz)
      crossZ = nextZ * abs(dx)
      takeX = sx != 0 and (sz == 0 or crossX <= crossZ)
      takeZ = sz != 0 and (sx == 0 or crossZ <= crossX)
    if takeX and takeZ and
      (not terrain(x + sx, z) or not terrain(x, z + sz)):
        return false
    if takeX:
      x += sx
      nextX += FixedScale
    if takeZ:
      z += sz
      nextZ += FixedScale
    if not terrain(x, z):
      return false
  true

proc hlfTilesWalkable(pos: FixedVec2): bool {.nimcall.} =
  ## Keeps ordinary movement and villager separation outside solid scenery.
  walkWorld != nil and walkWorld.positionOpen(pos)

proc findPath(
    w: World, position: FixedVec2, goal: Tile2, path: var seq[Tile2]
): bool {.measure.} =
  ## Asks the library for a route and stores string-pulled waypoints in walk
  ## order. Returns whether the goal was reached; on failure `path` holds
  ## the best partial route, still worth walking.
  path.setLen(0)
  let origin = cell(position)
  if not inGrid(origin.x, origin.z) or not inGrid(goal):
    return false
  var
    start = NoTile
    bestDistance = int64.high
  for dz in -2'i32 .. 2'i32:
    for dx in -2'i32 .. 2'i32:
      let tile = tile2(origin.x + dx, origin.z + dz)
      if not w.terrainOpen(tile.x.int32, tile.y.int32):
        continue
      let distance = lengthSquared(tileCenter(tile) - position)
      if distance < bestDistance and w.travelClear(position, tileCenter(tile)):
        start = tile
        bestDistance = distance
  if start == NoTile:
    return false
  if start == goal:
    path.add goal
    return true
  inc pathSearches
  pathWorld = w
  let found = fillTilePath(PathQuery(
    startLayer: 0,
    startX: int(start.x),
    startZ: int(start.y),
    finishLayer: 0,
    finishX: int(goal.x),
    finishZ: int(goal.y),
    neighbors: EightNeighbors,
    walkable: hlfPathWalkable,
    enterCost: hlfPathEnterCost,
    clearance: hlfPathClearance,
    cutCorners: true,
    maxExpansions: MaxPathExpansions,
    orthogonalCost: OrthogonalCost,
    diagonalCost: DiagonalCost,
    partial: true
  ), pathTiles)
  pathExpansions += found.expansions
  let pulled = smoothPathTiles(pathTiles, hlfPathTerrain, hlfPathClearance)
  path.setLen(pulled.len)
  for i, tile in pulled:
    path[i] = tile2(int32(tile.x), int32(tile.z))
  found.complete

## Order bookkeeping

proc clearPath(v: Villager) =
  v.path.setLen(0)
  v.pathIndex = 0
  v.pathGoal = NoTile

proc clearOrder(v: Villager, failed: bool) =
  ## Drops whatever the villager was doing and returns to idle.
  v.order = NoOrder
  v.orderTarget = 0
  v.talkCircle = false
  v.talkCenter = FixedVec2Zero
  v.talkPosition = FixedVec2Zero
  v.hasGoal = false
  v.goalOffset = FixedVec2Zero
  v.blockedTicks = 0
  v.clearPath()
  if v.animation == WalkAnimation:
    v.animation = IdleAnimation
  if failed:
    v.orderFailed = true

proc requestPath(w: World, slot: int32) =
  ## Queues one path search. An existing request for this villager keeps its
  ## place and updates the goal.
  let v = w.villagers[slot]
  if v.repathCooldown > 0 or not v.hasGoal:
    return
  for i in 0 ..< w.pathQueue.len:
    if w.pathQueue[i].slot == slot:
      w.pathQueue[i].goal = v.goal
      return
  if w.pathQueue.len >= MaxPathRequests:
    let dropped = w.pathQueue[0].slot
    w.pathQueue.delete(0)
    w.villagers[dropped].orderFailed = true
  w.pathQueue.add PathRequest(slot: slot, goal: v.goal)

proc setGoal(w: World, slot: int32, goal: Tile2,
    offset = FixedVec2Zero) =
  ## Points a villager at a destination tile and asks for a route.
  let v = w.villagers[slot]
  v.goal = goal
  v.goalOffset = offset
  v.hasGoal = true
  v.blockedTicks = 0
  v.repathCooldown = 0
  v.clearPath()
  w.requestPath(slot)

proc servePathQueue(w: World) {.measure.} =
  ## Runs a bounded number of searches per tick, oldest request first.
  var served = 0
  while served < PathBudgetPerTick and w.pathQueue.len > 0:
    let request = w.pathQueue[0]
    w.pathQueue.delete(0)
    inc served
    let v = w.villagers[request.slot]
    if not v.hasGoal or v.goal != request.goal or v.inHouse >= 0:
      continue
    let complete = w.findPath(v.body.pos, v.goal, v.path)
    v.pathGoal = v.goal
    v.pathIndex = 0
    if not complete and v.path.len == 0:
      ## Genuinely nowhere to go. An empty path with `complete` set just
      ## means the villager already stands on its goal, which is success.
      v.clearOrder(true)
    elif not complete:
      v.repathCooldown = ShortPathCooldownTicks

## Movement

proc applyBody(v: Villager) =
  ## Writes the body plane back onto the integer tile.
  let (x, z) = cell(v.body.pos)
  v.fromTile = v.tile
  v.tile = tile2(int32(x), int32(z))

proc place(w: World, v: Villager, at: Tile2) =
  ## Teleports a villager and keeps its body on the same cell.
  v.tile = at
  v.fromTile = at
  if v.body.radius == FixedZero:
    v.body.radius = VillagerBodyRadius
  v.body.pos = tileCenter(at)

proc moveSpeed(): Fixed =
  ## Tiles walked in one tick.
  FixedOne / fixed(StepTicks)

proc waypointPosition(v: Villager, tile: Tile2): FixedVec2 =
  ## Uses the exact destination for the last tile of a route.
  result = tileCenter(tile)
  if v.hasGoal and tile == v.goal:
    result += v.goalOffset

proc arrivedAt(v: Villager, tile: Tile2): bool =
  ## Keeps narrow turns precise and leaves room for others at shared goals.
  let radius =
    if v.hasGoal and tile == v.goal and
        v.goalOffset != FixedVec2Zero:
      fixed(1, 1000)
    elif v.hasGoal and tile == v.goal:
      PathArrive
    else:
      PathTurn
  length(v.waypointPosition(tile) - v.body.pos) <= radius

proc steerVillager(w: World, slot: int32, toward: FixedVec2) =
  ## Turns and slides one villager, then syncs its tile.
  walkWorld = w
  let v = w.villagers[slot]
  let before = v.body.pos
  steer(v.body, toward, moveSpeed(), BodyTurnRate, hlfTilesWalkable)
  if not w.travelClear(before, v.body.pos):
    v.body.pos = before
  v.applyBody()
  if v.body.pos == before:
    inc v.blockedTicks
    if v.blockedTicks >= AbandonAfterTicks:
      v.clearOrder(true)
  else:
    v.blockedTicks = 0
    v.animation = WalkAnimation

proc advanceMovement(w: World, slot: int32) =
  ## Steers toward the next pulled waypoint.
  let v = w.villagers[slot]
  if not v.hasGoal:
    return
  if v.arrivedAt(v.goal):
    return
  if v.tile == v.goal and
    w.travelClear(v.body.pos, v.waypointPosition(v.goal)):
      w.steerVillager(
        slot, v.waypointPosition(v.goal) - v.body.pos)
      return
  if v.path.len == 0:
    w.requestPath(slot)
    return
  while v.pathIndex < int32(v.path.len):
    if v.pathIndex + 1 < int32(v.path.len) and
      length(v.waypointPosition(v.path[v.pathIndex]) - v.body.pos) < FixedOne and
      w.travelClear(v.body.pos,
        v.waypointPosition(v.path[v.pathIndex + 1]), NavigationClearance):
        inc v.pathIndex
        continue
    let waypoint = v.path[v.pathIndex]
    if v.arrivedAt(waypoint):
      inc v.pathIndex
      continue
    w.steerVillager(slot, v.waypointPosition(waypoint) - v.body.pos)
    if v.blockedTicks >= RepathAfterTicks:
      v.blockedTicks = 0
      v.clearPath()
      w.requestPath(slot)
      v.repathCooldown = RepathCooldownTicks
    return
  v.clearPath()
  w.requestPath(slot)
  v.repathCooldown = ShortPathCooldownTicks

## Houses

proc stepInside(w: World, slot, house: int32) =
  ## Puts a villager inside a house. The body parks on the doorstep so an
  ## exit comes back out exactly where the entry happened.
  let v = w.villagers[slot]
  v.clearOrder(false)
  v.inHouse = house
  w.place(v, w.doorOf(house))
  v.animation = IdleAnimation

proc occupants*(w: World, house: int32): int32 =
  ## Counts everyone inside a house, the owner included.
  for v in w.villagers:
    if v.inHouse == house:
      inc result

## Villager tick

proc advanceVillager(w: World, slot: int32) =
  ## Runs one villager for one tick.
  let v = w.villagers[slot]
  inc v.animationTicks
  if v.repathCooldown > 0:
    dec v.repathCooldown
  if v.animation in {GatherAnimation, WaveAnimation} and
      v.animationTicks >= GestureTicks:
    v.animation = IdleAnimation
  if v.inHouse >= 0:
    return

  case v.order
  of NoOrder:
    if v.animation == WalkAnimation:
      v.animation = IdleAnimation
    return
  of MoveOrder:
    if v.arrivedAt(v.goal):
      v.clearOrder(false)
      return
  of GatherOrder:
    let garden = v.orderTarget
    if w.gardens[garden] < 0:
      ## Someone else got here first.
      v.clearOrder(true)
      return
    if chebyshev(v.tile, w.map.gardenTiles[garden]) <= GatherRadius:
      let veggie = int32(w.gardens[garden])
      inc v.inventory[veggie]
      w.gardens[garden] = EmptyGarden
      v.clearOrder(false)
      v.animation = GatherAnimation
      v.animationTicks = 0
      return
  of TalkOrder:
    let other = w.villagers[v.orderTarget]
    if other.inHouse >= 0 or chebyshev(v.tile, other.tile) > TalkRadius or
        other.order in {GatherOrder, EnterOrder} or
        (other.order != TalkOrder and v.animationTicks >= TalkReplyTicks):
      v.clearOrder(false)
    else:
      if v.talkCircle and length(v.talkPosition - v.body.pos) > PathArrive:
        w.steerVillager(slot, v.talkPosition - v.body.pos)
      else:
        if v.animation == WalkAnimation:
          v.animation = IdleAnimation
        let toward = (if v.talkCircle: v.talkCenter else: other.body.pos) - v.body.pos
        if toward != FixedVec2Zero:
          turnToward(v.body.facing, angle(toward), BodyTurnRate)
    return
  of EnterOrder:
    let house = v.orderTarget
    if chebyshev(v.tile, w.doorOf(house)) <= DoorRadius:
      w.stepInside(slot, house)
      return

  w.advanceMovement(slot)

## The dinner tally
##
## At 18:00 every house is judged at once: a party is valid when the owner is
## home with at least one visitor. The host banks pantry-times-visitors, then
## the pantry feeds host and visitors alike for three bite rounds. A first
## taste of a vegetable scores triple. Hosting empties the pantry.

proc chooseBite*(pantry: array[VeggieKinds, int16],
    eaten: array[VeggieKinds, bool], rng: var Rng): int32 =
  ## Chooses uniformly among untasted types, otherwise among remaining items.
  var
    wanted: array[VeggieKinds, int32]
    wantedCount = 0'i32
    total = 0'i32
  for veggie in 0 ..< VeggieKinds:
    total += int32(pantry[veggie])
    if pantry[veggie] > 0 and not eaten[veggie]:
      wanted[wantedCount] = int32(veggie)
      inc wantedCount
  if wantedCount > 0:
    return wanted[rng.below(wantedCount)]
  if total <= 0:
    return -1
  var pick = rng.below(total)
  for veggie in 0 ..< VeggieKinds:
    if pick < int32(pantry[veggie]):
      return int32(veggie)
    pick -= int32(pantry[veggie])
  -1

proc runDinnerTally*(w: World) {.measure.} =
  ## Scores every house at 18:00.
  for slot, v in w.villagers:
    v.lastGained = 0
    w.dailyReports[slot] = DailyReport(
      startingScore: v.score, dinnerHost: NoHouse)
  for house in 0 ..< VillagerCount:
    var report = DinnerReport()
    let host = w.villagers[house]
    var diners: seq[int32]
    for slot in 0 ..< VillagerCount:
      if w.villagers[slot].inHouse == int32(house):
        diners.add int32(slot)
    let hostHome = host.inHouse == int32(house)
    if hostHome and diners.len >= 2:
      report.valid = true
      report.visitors = int32(diners.len - 1)
      report.pantry = host.carriedTotal()
      report.hostPoints = report.pantry * report.visitors
      w.dailyReports[house].hostingPoints = report.hostPoints
      for diner in diners:
        w.dailyReports[diner].dinnerHost = int32(house)
      host.score += report.hostPoints
      host.lastGained += report.hostPoints

      ## One shuffled seating order, reused for every bite round.
      for i in countdown(diners.len - 1, 1):
        let j = w.rng.below(int32(i + 1))
        swap(diners[i], diners[int(j)])
      block feeding:
        for round in 0 ..< BiteRounds:
          for diner in diners:
            let eater = w.villagers[diner]
            let veggie = chooseBite(host.inventory, eater.eaten, w.rng)
            if veggie < 0:
              break feeding
            dec host.inventory[veggie]
            let points =
              if eater.eaten[veggie]: RepeatVeggiePoints
              else: NewVeggiePoints
            let daily = addr w.dailyReports[diner]
            daily.bites[daily.biteCount] = DinnerBite(
              veggie: veggie, points: points)
            inc daily.biteCount
            eater.eaten[veggie] = true
            eater.score += points
            eater.lastGained += points
      for veggie in 0 ..< VeggieKinds:
        host.inventory[veggie] = 0
    w.lastTally[house] = report

## Days

proc startDay(w: World) =
  ## Begins the next morning, or ends the game after the last one.
  inc w.day
  if w.day > w.dayCount:
    w.phase = GameOverPhase
    w.over = true
    return
  w.phase = DaytimePhase
  w.dayTick = 0
  for garden in 0 ..< GardenCount:
    w.gardens[garden] = int8(w.rng.below(int32(VeggieKinds)))
  for slot in 0 ..< VillagerCount:
    let v = w.villagers[slot]
    v.inHouse = NoHouse
    v.curfewMissed = false
    w.dailyReports[slot] = DailyReport(
      startingScore: v.score, dinnerHost: NoHouse)
    v.hostingTonight = false
    v.acceptedHost = NoVillager
    for other in 0 ..< VillagerCount:
      v.inviteFrom[other] = false
    v.orderFailed = false
    v.clearOrder(false)
    v.animation = IdleAnimation
    v.animationTicks = 0
    w.place(v, w.doorOf(int32(slot)))
  w.pathQueue.setLen(0)

proc startScoreScreen(w: World) =
  ## Applies curfew before sending everyone home for the standings screen.
  for slot in 0 ..< VillagerCount:
    let v = w.villagers[slot]
    v.curfewMissed = v.inHouse != int32(slot)
    if v.curfewMissed:
      v.score -= CurfewPenalty
      w.dailyReports[slot].penalty = CurfewPenalty
    w.stepInside(int32(slot), int32(slot))
  w.pathQueue.setLen(0)
  w.phase = ScorePhase
  w.phaseTicks = ScoreScreenTicks

## Commands
##
## Each of these is the single validator for one command kind, and every one
## decides completely before touching anything, so a refusal is a genuine
## no-op that needs no replay entry.

proc commandsOpen(w: World): bool =
  ## Whether villagers may act at all right now.
  not w.over and w.phase in {DaytimePhase, EveningPhase}

proc applyMove*(w: World, player, x, y: int32,
    offset = FixedVec2Zero): bool =
  ## Walks a villager to a tile.
  if not w.commandsOpen or not validSlot(player) or
      not offset.validTileOffset:
    return false
  let v = w.villagers[player]
  if v.inHouse >= 0 or not w.terrainOpen(x, y):
    return false
  if not w.positionOpen(tileCenter(tile2(x, y)) + offset):
    return false
  if not w.travelClear(tileCenter(tile2(x, y)),
    tileCenter(tile2(x, y)) + offset):
      return false
  v.clearOrder(false)
  v.order = MoveOrder
  w.setGoal(player, tile2(x, y), offset)
  true

proc applyGather*(w: World, player, garden: int32): bool =
  ## Sends a villager to collect one stocked garden plot.
  if not w.commandsOpen or not validSlot(player) or
      not validGarden(garden):
    return false
  let v = w.villagers[player]
  if v.inHouse >= 0 or w.gardens[garden] < 0:
    return false
  v.clearOrder(false)
  v.order = GatherOrder
  v.orderTarget = garden
  w.setGoal(player, w.map.gardenTiles[garden])
  true

proc socialGroup*(w: World, slot: int32): set[0 .. VillagerCount - 1] =
  ## Includes everyone connected by an active conversation, in either direction.
  result.incl int(slot)
  var changed = true
  while changed:
    changed = false
    for v in w.villagers:
      if v.order != TalkOrder:
        continue
      let
        member = int(v.slot)
        partner = int(v.orderTarget)
      if member in result or partner in result:
        let before = result.card
        result.incl member
        result.incl partner
        changed = changed or result.card != before

proc arrangeConversation(w: World, group: set[0 .. VillagerCount - 1]) =
  ## Gives consenting participants stable, nearby places around a shared center.
  var
    members: seq[int32]
    center = FixedVec2Zero
  for slot in group:
    let v = w.villagers[slot]
    if v.order == TalkOrder:
      members.add int32(slot)
      center += v.body.pos
  if members.len < 3:
    return
  center = center / fixed(int32(members.len))
  var
    bestCost = int64.high
    bestCenter: FixedVec2
    best, chosen, points: array[int(TalkGroupLimit), FixedVec2]
  proc clearApproach(start, finish: FixedVec2): bool =
    ## Checks body clearance along the short move into the circle.
    for step in 0 .. TalkApproachSamples:
      let pos = start + (finish - start) * fixed(int32(step)) / fixed(TalkApproachSamples)
      if not w.positionOpen(pos):
        return false
      for dx in [-VillagerBodyRadius, VillagerBodyRadius]:
        for dy in [-VillagerBodyRadius, VillagerBodyRadius]:
          let (x, y) = cell(pos + fixedVec2(dx, dy))
          if not w.terrainOpen(x, y):
            return false
    true
  proc assign(index, used: int, cost: int64) =
    ## Chooses the seating permutation with the least total movement.
    if cost >= bestCost:
      return
    if index == members.len:
      bestCost = cost
      best = chosen
      return
    for seat in 0 ..< members.len:
      if (used and (1 shl seat)) != 0:
        continue
      let start = w.villagers[members[index]].body.pos
      if not clearApproach(start, points[seat]):
        continue
      chosen[index] = points[seat]
      assign(index + 1, used or (1 shl seat),
        cost + lengthSquared(points[seat] - start))
  for (dx, dy) in [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)]:
    let candidateCenter = center + fixedVec2(fixed(int32(dx)), fixed(int32(dy)))
    for rotation in 0 ..< TalkCircleRotations:
      for seat in 0 ..< members.len:
        let heading = FixedTau * fixed(int32(seat)) / fixed(int32(members.len)) +
          FixedTau * fixed(int32(rotation)) / fixed(TalkCircleRotations)
        points[seat] = candidateCenter + direction(heading) * TalkCircleRadius
      let before = bestCost
      assign(0, 0, 0)
      if bestCost < before:
        bestCenter = candidateCenter
  if bestCost == int64.high:
    return
  for index, slot in members:
    let v = w.villagers[slot]
    v.talkCircle = true
    v.talkCenter = bestCenter
    v.talkPosition = best[index]

proc applyTalk*(w: World, player, target: int32): bool =
  ## Offers or joins a small conversation without controlling the other villager.
  if not w.commandsOpen or not validSlot(player) or not validSlot(target) or
      player == target:
    return false
  let
    v = w.villagers[player]
    other = w.villagers[target]
  if v.inHouse >= 0 or other.inHouse >= 0 or
      other.order in {GatherOrder, EnterOrder} or
      chebyshev(v.tile, other.tile) > TalkRadius or
      (w.socialGroup(player) + w.socialGroup(target)).card > TalkGroupLimit:
    return false
  v.clearOrder(false)
  v.order = TalkOrder
  v.orderTarget = target
  w.arrangeConversation(w.socialGroup(player))
  v.animation = WaveAnimation
  v.animationTicks = 0
  true

proc applyInvite*(w: World, player, target: int32): bool =
  ## Invites another villager to tonight's party, declaring the caller a
  ## host. Both must be outdoors and close enough to talk, and the tally
  ## must not have fired yet.
  if w.over or w.phase != DaytimePhase:
    return false
  if not validSlot(player) or not validSlot(target) or player == target:
    return false
  let
    caller = w.villagers[player]
    invited = w.villagers[target]
  if caller.inHouse >= 0 or invited.inHouse >= 0:
    return false
  if chebyshev(caller.tile, invited.tile) > InviteRadius:
    return false
  caller.hostingTonight = true
  invited.inviteFrom[player] = true
  caller.animation = WaveAnimation
  caller.animationTicks = 0
  true

proc applyAccept*(w: World, player, host: int32): bool =
  ## Accepts a standing invitation. A later acceptance replaces an earlier
  ## one; nothing binds a villager to actually show up.
  if w.over or w.phase != DaytimePhase:
    return false
  if not validSlot(player) or not validSlot(host) or player == host:
    return false
  let v = w.villagers[player]
  if not v.inviteFrom[host]:
    return false
  v.acceptedHost = host
  true

proc applyDecline*(w: World, player, host: int32): bool =
  ## Declines a standing invitation.
  if w.over or w.phase != DaytimePhase:
    return false
  if not validSlot(player) or not validSlot(host) or player == host:
    return false
  let v = w.villagers[player]
  if not v.inviteFrom[host]:
    return false
  v.inviteFrom[host] = false
  if v.acceptedHost == host:
    v.acceptedHost = NoVillager
  true

proc applyEnterHouse*(w: World, player, house: int32): bool =
  ## Walks a villager to a house door and inside. Anyone may enter any
  ## house; entering is what dinner attendance is made of.
  if not w.commandsOpen or not validSlot(player) or not validSlot(house):
    return false
  let v = w.villagers[player]
  if v.inHouse >= 0:
    return false
  if chebyshev(v.tile, w.doorOf(house)) <= DoorRadius:
    w.stepInside(player, house)
    return true
  v.clearOrder(false)
  v.order = EnterOrder
  v.orderTarget = house
  w.setGoal(player, w.doorOf(house))
  true

proc applyExitHouse*(w: World, player: int32): bool =
  ## Steps a villager back out onto the doorstep.
  if not w.commandsOpen or not validSlot(player):
    return false
  let v = w.villagers[player]
  if v.inHouse < 0:
    return false
  let door = w.doorOf(v.inHouse)
  v.inHouse = NoHouse
  w.place(v, door)
  true

proc applyStop*(w: World, player: int32): bool =
  ## Drops the current order.
  if not w.commandsOpen or not validSlot(player):
    return false
  let v = w.villagers[player]
  if v.inHouse >= 0:
    return false
  v.clearOrder(false)
  true

proc applyReplayAction*(w: World, action: ReplayAction) =
  ## Re-executes one recorded command through the same validators.
  let player = int32(action.playerId)
  case action.kind
  of ActionMove:
    discard w.applyMove(player, action.first, action.second, action.offset)
  of ActionGather:
    discard w.applyGather(player, action.first)
  of ActionInvite:
    discard w.applyInvite(player, action.first)
  of ActionAccept:
    discard w.applyAccept(player, action.first)
  of ActionDecline:
    discard w.applyDecline(player, action.first)
  of ActionEnterHouse:
    discard w.applyEnterHouse(player, action.first)
  of ActionExitHouse:
    discard w.applyExitHouse(player)
  of ActionStop:
    discard w.applyStop(player)
  of ActionTalk:
    discard w.applyTalk(player, action.first)
  else:
    raise newException(ReplayError, "replay action kind is invalid")

proc record(game: Game, kind: uint8, player: int32,
    first = 0'i32, second = 0'i32, offset = FixedVec2Zero) =
  ## Writes one accepted command. Skips when the tape is already past this
  ## tick.
  if game.recorder == nil or
      game.recorder.data.hashes.len >= game.world.tick:
    return
  game.recorder.recordAction(
    uint32(game.world.tick), player, kind, first, second, offset)

proc applyMove*(game: Game, player, x, y: int32,
    offset = FixedVec2Zero): bool =
  ## Walks a villager and records the command when accepted.
  result = game.world.applyMove(player, x, y, offset)
  if result:
    game.record(ActionMove, player, x, y, offset)

proc applyGather*(game: Game, player, garden: int32): bool =
  ## Gathers a garden and records the command when accepted.
  result = game.world.applyGather(player, garden)
  if result:
    game.record(ActionGather, player, garden)

proc applyTalk*(game: Game, player, target: int32): bool =
  ## Records an accepted conversation offer or response.
  result = game.world.applyTalk(player, target)
  if result:
    game.record(ActionTalk, player, target)

proc applyInvite*(game: Game, player, target: int32): bool =
  ## Invites a villager and records the command when accepted.
  result = game.world.applyInvite(player, target)
  if result:
    game.record(ActionInvite, player, target)

proc applyAccept*(game: Game, player, host: int32): bool =
  ## Accepts an invitation and records the command when accepted.
  result = game.world.applyAccept(player, host)
  if result:
    game.record(ActionAccept, player, host)

proc applyDecline*(game: Game, player, host: int32): bool =
  ## Declines an invitation and records the command when accepted.
  result = game.world.applyDecline(player, host)
  if result:
    game.record(ActionDecline, player, host)

proc applyEnterHouse*(game: Game, player, house: int32): bool =
  ## Enters a house and records the command when accepted.
  result = game.world.applyEnterHouse(player, house)
  if result:
    game.record(ActionEnterHouse, player, house)

proc applyExitHouse*(game: Game, player: int32): bool =
  ## Exits a house and records the command when accepted.
  result = game.world.applyExitHouse(player)
  if result:
    game.record(ActionExitHouse, player)

proc applyStop*(game: Game, player: int32): bool =
  ## Stops a villager and records the command when accepted.
  result = game.world.applyStop(player)
  if result:
    game.record(ActionStop, player)

## Canonical state hash
##
## Everything that can influence a later tick is mixed in, in exactly this
## order. Anything derivable is left out and named in the `World` comments,
## so adding a field and forgetting it here is a one-file review.

proc mixTile(hash: var uint32, tile: Tile2) =
  hash.addHashy(tile.x)
  hash.addHashy(tile.y)

proc hashWorld(w: World): uint64 =
  ## Hashes all authoritative state that can affect later simulation ticks.
  var hash = HashySeed
  hash.addHashy(w.tick)
  hash.addHashy(w.rng)
  hash.addHashy(w.over)
  hash.addHashy(w.day)
  hash.addHashy(w.dayCount)
  hash.addHashy(w.maximumTicks)
  hash.addHashy(int32(w.phase.ord))
  hash.addHashy(w.phaseTicks)
  hash.addHashy(w.dayTick)
  for garden in w.gardens:
    hash.addHashy(garden)
  for v in w.villagers:
    hash.addHashy(v.slot)
    hash.addHashy(int32(v.body.pos.x))
    hash.addHashy(int32(v.body.pos.y))
    hash.addHashy(int32(v.body.facing))
    hash.mixTile(v.tile)
    hash.mixTile(v.fromTile)
    hash.addHashy(v.inHouse)
    hash.addHashy(int32(v.order.ord))
    hash.addHashy(v.orderTarget)
    hash.addHashy(v.talkCircle)
    hash.addHashy(int32(v.talkCenter.x))
    hash.addHashy(int32(v.talkCenter.y))
    hash.addHashy(int32(v.talkPosition.x))
    hash.addHashy(int32(v.talkPosition.y))
    hash.mixTile(v.goal)
    hash.addHashy(int32(v.goalOffset.x))
    hash.addHashy(int32(v.goalOffset.y))
    hash.addHashy(v.hasGoal)
    hash.addHashy(v.path.len)
    for step in v.path:
      hash.mixTile(step)
    hash.addHashy(v.pathIndex)
    hash.mixTile(v.pathGoal)
    hash.addHashy(v.blockedTicks)
    hash.addHashy(v.repathCooldown)
    for count in v.inventory:
      hash.addHashy(count)
    for tasted in v.eaten:
      hash.addHashy(tasted)
    hash.addHashy(v.score)
    hash.addHashy(v.hostingTonight)
    hash.addHashy(v.acceptedHost)
    for invited in v.inviteFrom:
      hash.addHashy(invited)
    hash.addHashy(v.curfewMissed)
    hash.addHashy(v.lastGained)
    hash.addHashy(int32(v.animation.ord))
    hash.addHashy(v.animationTicks)
  for report in w.lastTally:
    hash.addHashy(report.valid)
    hash.addHashy(report.visitors)
    hash.addHashy(report.pantry)
    hash.addHashy(report.hostPoints)
  hash.addHashy(w.pathQueue.len)
  for request in w.pathQueue:
    hash.addHashy(request.slot)
    hash.mixTile(request.goal)
  uint64(hash)

proc stateHash*(game: Game): uint64 =
  ## Hashes all authoritative state that can affect later simulation ticks.
  hashWorld(game.world)

## The tick
##
## Phase order is fixed and is the reason a replay resynchronises: commands
## land on decision ticks, then paths are served, then movement, then the
## clock fires the tally or the score screen.

proc tickWorld*(w: World, decide: proc(w: World) {.closure.}) {.measure.} =
  ## Advances the simulation by exactly one tick.
  if w.over:
    return
  inc w.tick

  if w.phase == ScorePhase:
    dec w.phaseTicks
    if w.phaseTicks <= 0:
      w.startDay()
    return

  inc w.dayTick
  if w.tick mod DecisionTicks == 0 and decide != nil:
    profileBlock "decisions":
      decide(w)

  profileBlock "searchPath":
    w.servePathQueue()
  profileBlock "villagers":
    for slot in 0 ..< VillagerCount:
      w.advanceVillager(int32(slot))
  profileBlock "separate":
    walkWorld = w
    for i in 0 ..< VillagerCount:
      if w.villagers[i].inHouse >= 0:
        continue
      for j in i + 1 ..< VillagerCount:
        if w.villagers[j].inHouse >= 0:
          continue
        let
          beforeA = w.villagers[i].body.pos
          beforeB = w.villagers[j].body.pos
        separatePair(
          w.villagers[i].body,
          w.villagers[j].body,
          hlfTilesWalkable
        )
        if not w.travelClear(beforeA, w.villagers[i].body.pos):
          w.villagers[i].body.pos = beforeA
        if not w.travelClear(beforeB, w.villagers[j].body.pos):
          w.villagers[j].body.pos = beforeB
    for v in w.villagers:
      if v.inHouse < 0:
        v.applyBody()

  if w.phase == DaytimePhase and w.minuteOfDay >= DinnerMinute:
    profileBlock "dinner":
      w.runDinnerTally()
    w.phase = EveningPhase
  if w.dayTick >= DayTicks:
    w.startScoreScreen()

## Setup

proc cloneVillagers(
    villagers: array[VillagerCount, Villager]
): array[VillagerCount, Villager] =
  ## Copies each villager so two worlds never share a path seq.
  for i, v in villagers:
    result[i] = Villager()
    result[i][] = v[]

proc clone*(world: World): World =
  ## Deep copy. Villagers are refs and must be cloned one by one.
  result = World()
  result[] = world[]
  result.villagers = cloneVillagers(world.villagers)

proc restore*(world: World, snapshot: World) =
  ## Overwrites in place, keeping the caller's ref identity.
  world[] = snapshot[]
  world.villagers = cloneVillagers(snapshot.villagers)

proc newWorld*(map: MapData, dayCount: int32): World =
  ## Builds the opening morning for one game.
  result = World(
    tick: 0,
    day: 0,
    dayCount: dayCount,
    maximumTicks: gameLengthTicks(dayCount),
    map: map,
    rng: initRng(map.seed)
  )
  for slot in 0 ..< VillagerCount:
    result.villagers[slot] = Villager(
      slot: int32(slot),
      inHouse: NoHouse,
      acceptedHost: NoVillager,
      goal: NoTile,
      pathGoal: NoTile,
      body: Body(radius: VillagerBodyRadius)
    )
    result.place(result.villagers[slot], map.houses[slot].door)
  result.startDay()

proc newGame*(map: MapData, dayCount: int32): Game =
  ## Builds one game session around a fresh world.
  result = Game(
    world: newWorld(map, dayCount),
    mapSeed: map.seed,
    dayCount: dayCount,
    maximumTicks: gameLengthTicks(dayCount)
  )
