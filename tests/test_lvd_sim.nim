## Light vs Dark simulation invariants: determinism, the one-unit-per-tile
## promise, the blocked-movement escalation, the harvest round trip, and the
## economy's accounting.

import
  std/strformat,
  bassy,
  polyworld/[bodies, metrics, tapes],
  ../examples/light_vs_dark/bots,
  ../examples/light_vs_dark/content,
  ../examples/light_vs_dark/maps,
  ../examples/light_vs_dark/replays,
  ../examples/light_vs_dark/sim

let map = generateMap(DefaultSeed)
map.validateMap()

const MatchTicks = DefaultSeconds * TickRate

proc arenaTile(x: int32, y = 0'i32): Tile2 =
  ## Names a position in the generated central combat clearing.
  tile2(map.side div 2 + x, map.side div 2 + y)

proc stateHash(w: World): uint64 =
  ## Wraps a world in a session so tests can use the public hasher.
  var game = Game()
  game.world = w
  result = game.stateHash()
  wasMoved(game.world)

proc noDecisions(w: World) = discard

proc run(w: World, ticks: int32) =
  for _ in 0 ..< ticks:
    w.tickWorld(noDecisions)

proc wartime(w: World) =
  ## Sets combat fixtures at war; separate diplomacy tests cover transitions.
  w.diplomacy.pairs[w.diplomacy.pairIndex(LightPlayer, DarkPlayer)].state = AtWar

proc checkOccupancy(w: World, label: string) =
  ## Every living unit's tile matches its body and stands on open terrain.
  for unit in w.units:
    if unit.state == UnitDying or unit.state == UnitInMine:
      continue
    let (x, z) = cell(unit.body.pos)
    doAssert unit.tile == tile2(x, z),
      &"{label}: unit {unit.id} tile ({unit.tile.x},{unit.tile.y}) " &
      &"does not match body cell ({x},{z}) at tick {w.tick}"
    doAssert w.tileOpen(unit.tile),
      &"{label}: unit {unit.id} stands on a blocked tile at tick {w.tick}"

echo "Testing the opening position"
block openingIsSane:
  var w = newWorld(map, MatchTicks)
  doAssert w.units.len == int(StartingPeons) * DefaultPlayerCount
  doAssert w.buildings.len == map.mines.len + DefaultPlayerCount
  for player in 0'i32 ..< DefaultPlayerCount:
    doAssert w.players[player].gold == StartingGold
    doAssert w.players[player].wood == StartingWood
    doAssert w.players[player].foodUsed == StartingPeons
    doAssert w.players[player].foodCap ==
      BuildingTable[TownHallBuilding].foodProvided
    doAssert w.buildingCount(player) == 1
    doAssert w.peonCount(player) == StartingPeons
  w.checkOccupancy("opening")
  ## Neither side can see the other at the start, or scouting would be free.
  let darkHall = map.hallOrigin[DarkPlayer]
  doAssert not w.visible(LightPlayer, darkHall)
  doAssert w.visible(LightPlayer, map.hallOrigin[LightPlayer])
  doAssert w.exploredCount[LightPlayer] > 0
  doAssert w.exploredCount[DarkPlayer] > 0

echo "Testing rectangular construction reserves and releases its base"
block rectangularConstruction:
  var w = newWorld(map, MatchTicks)
  w.players[LightPlayer].gold = 5000
  w.players[LightPlayer].wood = 5000
  var site = NoTile
  for y in 5'i32 .. 28'i32:
    for x in 5'i32 .. 28'i32:
      if w.canPlace(TownHallBuilding, x, y):
        site = tile2(x, y)
        break
    if map.inGrid(site):
      break
  doAssert map.inGrid(site)
  let
    size = BuildingTable[TownHallBuilding].footprint
    x = int32(site.x)
    y = int32(site.y)
  doAssert size.width > size.depth
  doAssert not w.canPlace(TownHallBuilding, map.side - size.width + 1, y)
  doAssert not w.canPlace(TownHallBuilding, x, map.side - size.depth + 1)
  doAssert w.applyBuild(
    LightPlayer, w.units[0].id, TownHallBuilding.ord.int32, x, y
  )
  let id = w.buildings[^1].id
  var occupied = 0
  for blocker in w.blocker:
    if blocker == id:
      inc occupied
  doAssert occupied == size.width * size.depth
  let corner = map.tileIndex(x + size.width - 1, y + size.depth - 1)
  doAssert w.blocker[corner] == id
  doAssert w.blocker[map.tileIndex(x, y + size.depth)] != id
  doAssert not w.canPlace(FarmBuilding, x + size.width - 1, y)
  doAssert w.applyCancel(LightPlayer, id)
  doAssert w.canPlace(TownHallBuilding, x, y)
  for blocker in w.blocker:
    doAssert blocker != id

echo "Testing starting building bases never overlap or block their approaches"
block startingFootprints:
  for seed in [1'i32, DefaultSeed, 42'i32, 73'i32]:
    let
      startingMap = generateMap(seed)
      w = newWorld(startingMap, MatchTicks)
    for structure in w.buildings:
      for y in int32(structure.origin.y) ..<
        int32(structure.origin.y) + structure.footprint.depth:
          for x in int32(structure.origin.x) ..<
            int32(structure.origin.x) + structure.footprint.width:
              let tile = startingMap.tileIndex(x, y)
              doAssert startingMap.passable[tile] == 1
              doAssert w.blocker[tile] == structure.id
      doAssert startingMap.inGrid(
        w.freeTileAround(structure.origin, structure.footprint)
      )

echo "Testing determinism across identical runs"
block twoRunsAgree:
  var first = newWorld(map, MatchTicks)
  var second = newWorld(map, MatchTicks)
  doAssert first.stateHash() == second.stateHash(), "openings differ"
  for tick in 1 .. TickRate * 20:
    first.tickWorld(noDecisions)
    second.tickWorld(noDecisions)
    doAssert first.stateHash() == second.stateHash(),
      &"two identical runs diverged at tick {tick}"

echo "Testing that the hash actually responds to state"
block hashNoticesChange:
  var w = newWorld(map, MatchTicks)
  let before = w.stateHash()
  w.players[LightPlayer].gold += 1
  doAssert w.stateHash() != before, "the hash ignores a resource change"
  w.players[LightPlayer].gold -= 1
  doAssert w.stateHash() == before, "the hash is not a pure function"
  w.units[0].hp -= 1
  doAssert w.stateHash() != before, "the hash ignores unit health"

block hashIgnoresDerivedState:
  var w = newWorld(map, MatchTicks)
  let before = w.stateHash()
  ## Vision is a pure function of positions, so rebuilding it must not move
  ## the hash even though `explored` accumulates.
  w.rebuildVision()
  doAssert w.stateHash() == before, "the hash depends on derived vision"

echo "Testing movement, occupancy, and arrival"
block unitsWalkAndNeverOverlap:
  var w = newWorld(map, MatchTicks)
  ## March every Light peon into the central clearing.
  let rally = tile2(map.side div 2, map.side div 2)
  var ordered = 0
  for index in 0 ..< w.units.len:
    if w.units[index].owner != LightPlayer:
      continue
    if w.applyMove(
      LightPlayer, w.units[index].id, int32(rally.x), int32(rally.y)
    ):
      inc ordered
  doAssert ordered == StartingPeons, &"only {ordered} peons accepted a move"
  for tick in 1 .. TickRate * 50:
    w.tickWorld(noDecisions)
    if tick mod TickRate == 0:
      w.checkOccupancy("march")
  var arrived = 0
  for unit in w.units:
    if unit.owner == LightPlayer and
        tileDistance(unit.tile, rally) <= 3:
      inc arrived
  doAssert arrived >= StartingPeons - 1,
    &"only {arrived} of {StartingPeons} peons reached the rally tile"

echo "Testing paths go around other units"
block pathsGoAroundOtherUnits:
  var w = newWorld(map, MatchTicks)
  let
    walkerId = w.units[0].id
    blockerId = w.units[1].id
  doAssert w.units[0].owner == LightPlayer
  doAssert w.units[1].owner == LightPlayer
  var start, mid, goal = NoTile
  block found:
    for y in 0'i32 ..< map.side:
      for x in 0'i32 ..< map.side - 4:
        var open = true
        for ox in 0'i32 .. 4:
          if not w.tileFree(x + ox, y) or
              not w.tileOpen(x + ox, y - 1) or
              not w.tileOpen(x + ox, y + 1):
            open = false
            break
        if open:
          start = tile2(x, y)
          mid = tile2(x + 2, y)
          goal = tile2(x + 4, y)
          break found
  doAssert map.inGrid(start), "no open five-tile corridor on the map"
  for (id, tile) in [(walkerId, start), (blockerId, mid)]:
    let index = w.unitIndex(id)
    w.place(w.units[index], tile)
  doAssert w.applyMove(
    LightPlayer, walkerId, int32(goal.x), int32(goal.y)
  )
  for _ in 1 .. TickRate * 8:
    w.tickWorld(noDecisions)
    let walker = w.units[w.unitIndex(walkerId)]
    doAssert walker.tile != mid,
      "the walker stepped onto a standing peon instead of going around"
  let walker = w.units[w.unitIndex(walkerId)]
  doAssert tileDistance(walker.tile, goal) <= 1,
    &"the walker stopped at ({walker.tile.x},{walker.tile.y}) short of the goal"

echo "Testing mine approach tiles spread across peons"
block harvestSpotsSpread:
  var w = newWorld(map, MatchTicks)
  var mineId = NoEntity
  var best = int32.high
  for mine in map.mines:
    let distance = tileDistance(map.hallOrigin[LightPlayer], mine.origin)
    if distance < best:
      best = distance
      mineId = mine.id
  doAssert mineId != NoEntity
  let
    first = w.units[0].id
    second = w.units[1].id
  doAssert w.applyHarvest(LightPlayer, first, mineId, 0)
  doAssert w.applyHarvest(LightPlayer, second, mineId, 0)
  let
    firstGoal = w.units[w.unitIndex(first)].goal
    secondGoal = w.units[w.unitIndex(second)].goal
  doAssert firstGoal != secondGoal,
    "two peons queued on the same mine ring tile"

block movesToBlockedGroundAreRejected:
  var w = newWorld(map, MatchTicks)
  let peon = w.units[0].id
  ## The middle of the river is not standable terrain.
  var wet = tile2(-1, -1)
  for index in 0 ..< (map.side * map.side):
    if map.passable[index] == 0:
      wet = tile2(int32(index) mod map.side, int32(index) div map.side)
      break
  doAssert map.inGrid(wet)
  doAssert not w.applyMove(LightPlayer, peon, int32(wet.x), int32(wet.y)),
    "a move onto impassable terrain was accepted"

block ownershipIsEnforced:
  var w = newWorld(map, MatchTicks)
  var darkPeon = NoEntity
  for unit in w.units:
    if unit.owner == DarkPlayer:
      darkPeon = unit.id
      break
  doAssert darkPeon != NoEntity
  let centre = map.side div 2
  doAssert not w.applyMove(LightPlayer, darkPeon, centre, centre),
    "Light commanded a Dark unit"
  doAssert not w.applyCancel(LightPlayer, darkPeon),
    "Light cancelled a Dark unit's order"
  doAssert w.applyMove(DarkPlayer, darkPeon, centre, centre),
    "Dark could not command its own unit"

echo "Testing only accepted RTS commands contribute to APM"
block:
  let
    game = newGame(map, MatchTicks)
    centre = map.side div 2
  var darkPeon = NoEntity
  for unit in game.world.units:
    if unit.owner == DarkPlayer:
      darkPeon = unit.id
      break
  doAssert not game.applyMove(LightPlayer, darkPeon, centre, centre)
  doAssert not game.applyCancel(LightPlayer, darkPeon)
  doAssert game.metrics.read(LightPlayer, 0).commands == 0
  doAssert game.applyMove(DarkPlayer, darkPeon, centre, centre)
  doAssert game.metrics.read(DarkPlayer, 0).commands == 1

echo "Testing failure queries are read-only"
block:
  let
    game = newGame(map, MatchTicks)
    unit = game.world.units[0]
    enemy = game.world.units[int(StartingPeons)]
    source = "print orderFailed(" & $unit.id & ")\n" &
      "print orderFailed(" & $unit.id & ")\n" &
      "print orderFailed(" & $enemy.id & ")\n" &
      "print orderFailed(-1)\n"
  loadBots(game, [source, ""])
  var values: seq[int32]
  game.brains[LightPlayer].output = proc(event: PrintEvent) =
    ## Captures the actual BASIC query results.
    if event.kind == ValuePrint:
      values.add event.value
  unit.orderFailed = true
  enemy.orderFailed = true
  let before = game.stateHash()
  runBotDecisions(game)
  doAssert not game.brains[LightPlayer].failed
  doAssert values == @[1'i32, 1, 0, 0]
  doAssert game.stateHash() == before
  doAssert game.world.applyCancel(LightPlayer, unit.id)
  values.setLen(0)
  runBotDecisions(game)
  doAssert values == @[0'i32, 0, 0, 0]
  doAssert enemy.orderFailed

echo "Testing rejected orders preserve the complete world"
block:
  let
    game = newGame(map, MatchTicks)
    unit = game.world.units[0]
  game.world.tick = DecisionTicks
  game.recorder = initReplayRecorder(Setup(
    players: @[ReplayPlayerSetup(id: 0), ReplayPlayerSetup(id: 1)]
  ))
  unit.orderFailed = true
  let before = game.stateHash()
  doAssert not game.applyMove(LightPlayer, unit.id, -1, -1)
  doAssert not game.applyAttackMove(LightPlayer, unit.id, -1, -1)
  doAssert not game.applyAttack(LightPlayer, unit.id, unit.id)
  doAssert not game.applyHarvest(LightPlayer, unit.id, -1, 1)
  doAssert not game.applyBuild(
    LightPlayer,
    unit.id,
    int32(FarmBuilding.ord),
    -1,
    -1
  )
  doAssert not game.applyTrain(LightPlayer, unit.id, int32(PeonUnit.ord))
  doAssert not game.applySetRally(LightPlayer, unit.id, -1, -1)
  doAssert not game.applyCancel(DarkPlayer, unit.id)
  doAssert game.stateHash() == before
  doAssert game.recorder.data.actions.len == 0
  doAssert game.metrics.read(LightPlayer, DecisionTicks).commands == 0

echo "Testing accepted unit orders clear previous failures"
block:
  let
    w = newWorld(map, MatchTicks)
    unit = w.units[0]
    x = int32(unit.tile.x)
    y = int32(unit.tile.y)
    tree = w.nearestTree(unit.tile)
    mine = map.mines[0].id
  doAssert tree >= 0
  unit.orderFailed = true
  doAssert w.applyMove(LightPlayer, unit.id, x, y)
  doAssert not unit.orderFailed
  unit.orderFailed = true
  doAssert w.applyAttackMove(LightPlayer, unit.id, x, y)
  doAssert not unit.orderFailed
  for resource in [0'i32, 1]:
    for carrying in [false, true]:
      unit.orderFailed = true
      unit.carryGold = if carrying and resource == 0: GoldPerTrip else: 0
      unit.carryWood = if carrying and resource == 1: WoodPerTrip else: 0
      doAssert w.applyHarvest(
        LightPlayer,
        unit.id,
        if resource == 0: mine else: tree,
        resource
      )
      doAssert not unit.orderFailed
  unit.orderFailed = true
  doAssert w.applyCancel(LightPlayer, unit.id)
  doAssert not unit.orderFailed

echo "Testing accepted orders can report a new failure"
block:
  let
    w = newWorld(map, MatchTicks)
    unit = w.units[0]
    tree = w.nearestTree(unit.tile)
  unit.carryWood = WoodPerTrip
  for building in w.buildings.mitems:
    if building.owner == LightPlayer:
      building.state = BuildingDying
  doAssert w.applyHarvest(LightPlayer, unit.id, tree, 1)
  doAssert unit.orderFailed, "missing drop-off must report a new failure"
  doAssert unit.carryWood == WoodPerTrip

echo "Testing live history seek does not skip recorded actions"
block liveHistorySeek:
  ## The graphical scrubber restores a live checkpoint whose stored cursor
  ## is still 0, then catches up through recorded overlord commands.
  const Ticks = TickRate * 8
  let setup = Setup(
    mapSeed: DefaultSeed,
    tickRate: uint16(TickRate),
    gridTiles: uint16(map.side),
    decisionTicks: uint16(DecisionTicks),
    maximumTicks: uint32(Ticks),
    mapHash: map.hash,
    contentHash: contentHash(),
    players: @[
      ReplayPlayerSetup(
        id: 0,
        startX: int32(map.hallOrigin[LightPlayer].x),
        startY: int32(map.hallOrigin[LightPlayer].y)
      ),
      ReplayPlayerSetup(
        id: 1,
        startX: int32(map.hallOrigin[DarkPlayer].x),
        startY: int32(map.hallOrigin[DarkPlayer].y)
      )
    ]
  )
  let recorder = initReplayRecorder(setup)
  var liveGame = newGame(map, Ticks)
  liveGame.recorder = recorder
  let player = ReplayPlayer(data: recorder.data)

  proc liveOrders(w: World) =
    ## Issues one accepted move per decision so the live tape is not empty.
    let playerId = (w.tick div DecisionTicks) mod DefaultPlayerCount
    for index in 0 ..< w.units.len:
      if w.units[index].owner != playerId or
          w.units[index].state != UnitIdle:
        continue
      discard liveGame.applyMove(
        playerId,
        w.units[index].id,
        40 + playerId * 40,
        40
      )
      break

  const SnapAfter = Ticks div 2
  var snapshot: World
  for i in 1 .. Ticks:
    liveGame.world.tickWorld(liveOrders)
    if i == SnapAfter:
      snapshot = liveGame.world.clone()
  doAssert recorder.data.actions.len > 0,
    "overlords issued no commands during the live window"
  doAssert player.actionIndex == 0,
    "live recording must not advance the playback cursor"
  let
    frontierTick = liveGame.world.tick
    frontierHash = liveGame.stateHash()
  liveGame.world.restore(snapshot)
  player.data = recorder.data
  player.syncCursor(uint32(liveGame.world.tick))

  proc drain(w: World) =
    ## Replays every recorded command for this tick.
    var action: ReplayAction
    while player.takeActionAt(uint32(w.tick), action):
      w.applyReplayAction(action)

  while liveGame.world.tick < frontierTick:
    liveGame.world.tickWorld(drain)
  doAssert liveGame.world.tick == frontierTick
  doAssert liveGame.stateHash() == frontierHash,
    "catching up from a live seek diverged from the recorded frontier"

echo "Testing the gold round trip"
block goldFlows:
  var w = newWorld(map, MatchTicks)
  var mineId = NoEntity
  var best = int32.high
  for mine in map.mines:
    let distance = tileDistance(map.hallOrigin[LightPlayer], mine.origin)
    if distance < best:
      best = distance
      mineId = mine.id
  doAssert mineId != NoEntity
  var sent = 0
  for index in 0 ..< w.units.len:
    if w.units[index].owner != LightPlayer:
      continue
    if w.applyHarvest(LightPlayer, w.units[index].id, mineId, 0):
      inc sent
  doAssert sent == StartingPeons, &"only {sent} peons accepted a mine order"

  let startingGold = w.players[LightPlayer].gold
  w.run(TickRate * 60)
  w.checkOccupancy("mining")
  let gained = w.players[LightPlayer].gold - startingGold
  doAssert gained > 0, "sixty seconds of mining produced no gold"
  doAssert gained mod GoldPerTrip == 0,
    &"gold arrived in a partial load: {gained}"
  doAssert w.players[LightPlayer].goldGathered == int64(gained),
    "the gathered total disagrees with the stockpile"
  ## Gold is conserved: what the mine lost is either banked or still being
  ## carried. Nothing may appear from nowhere or evaporate in transit.
  let mine = w.buildingIndex(mineId)
  var inFlight = 0'i32
  for unit in w.units:
    inFlight += unit.carryGold
  doAssert w.buildings[mine].goldLeft + gained + inFlight == MainMineGold,
    &"gold is not conserved: mine has {w.buildings[mine].goldLeft}, " &
    &"player banked {gained}, peons carry {inFlight}"
  doAssert w.buildings[mine].minersInside <= MinersPerMine,
    "more peons fit inside the mine than the rules allow"
  ## Five peons on an eight-tile trip should be worth roughly 12 gold each
  ## per second; allow a wide band, this is a sanity check not a balance one.
  doAssert gained >= 1500, &"income was implausibly low: {gained} in 60s"
  echo &"  five peons gathered {gained} gold in 60 seconds"

echo "Testing the wood round trip and tree depletion"
block woodFlowsAndTreesFall:
  var w = newWorld(map, MatchTicks)
  var treeIndex = -1'i32
  var best = int32.high
  for index in 0 ..< (map.side * map.side):
    if w.treeWood[index] <= 0:
      continue
    let tile = tile2(int32(index) mod map.side, int32(index) div map.side)
    let distance = tileDistance(map.hallOrigin[LightPlayer], tile)
    if distance < best:
      best = distance
      treeIndex = int32(index)
  doAssert treeIndex >= 0
  let peon = w.units[0].id
  doAssert w.units[0].owner == LightPlayer
  doAssert w.applyHarvest(LightPlayer, peon, treeIndex, 1),
    "a peon would not chop a tree"

  let edits = w.terrainEdits.len
  w.run(TickRate * 100)
  doAssert w.players[LightPlayer].wood > StartingWood,
    "one hundred seconds of chopping produced no wood"
  let gained = w.players[LightPlayer].wood - StartingWood
  doAssert gained mod WoodPerTrip == 0, "wood arrived in a partial load"
  doAssert w.treeWood[treeIndex] == 0,
    "a tree survived four full trips"
  doAssert w.terrainEdits.len >= edits + 1,
    "felling a tree did not log a terrain edit"
  var felledAssigned = false
  for edit in w.terrainEdits:
    if edit.index == treeIndex:
      felledAssigned = true
  doAssert felledAssigned, "the assigned tree was never felled"
  doAssert w.tileOpen(tile2(treeIndex mod map.side, treeIndex div map.side)),
    "the felled tree still blocks its tile"
  doAssert gained >= int32(WoodPerTree),
    &"a tree yielded {gained} wood instead of at least {WoodPerTree}"
  ## The grove still has trees, so the peon should keep chopping nearby.
  let index = w.unitIndex(peon)
  doAssert not w.units[index].orderFailed,
    "an exhausted tree idled instead of taking the next tree"
  doAssert w.units[index].state in {
    UnitToTree, UnitChopping, UnitToDropWood, UnitDepositWood
  } or w.units[index].carryWood > 0,
    "after felling one tree the peon was not assigned another"

echo "Testing wood drop-off uses the closer hall or mill"
block woodGoesToCloserDrop:
  var w = newWorld(map, MatchTicks)
  let
    peon = w.units[0].id
    hall = map.hallOrigin[LightPlayer]
  var site = NoTile
  for radius in 6'i32 .. 16'i32:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        let
          x = int32(hall.x) + dx
          y = int32(hall.y) + dy
        if w.canPlace(LumberMillBuilding, x, y):
          site = tile2(x, y)
          break
      if map.inGrid(site):
        break
    if map.inGrid(site):
      break
  doAssert map.inGrid(site), "no mill site near the hall"
  doAssert w.applyBuild(
    LightPlayer,
    peon,
    int32(LumberMillBuilding.ord),
    int32(site.x),
    int32(site.y)
  )
  var millId = NoEntity
  for structure in w.buildings.mitems:
    if structure.kind == LumberMillBuilding and
        structure.owner == LightPlayer:
      structure.state = BuildingComplete
      structure.hp = structure.maxHp
      millId = structure.id
  doAssert millId != NoEntity
  var hallId = NoEntity
  for structure in w.buildings:
    if structure.kind == TownHallBuilding and
        structure.owner == LightPlayer:
      hallId = structure.id
  doAssert hallId != NoEntity
  doAssert w.nearestDropOff(LightPlayer, hall, true) == hallId,
    "wood from the hall should drop at the hall"
  doAssert w.nearestDropOff(LightPlayer, site, true) == millId,
    "wood from the mill should drop at the mill"
  let goldDrop = w.nearestDropOff(LightPlayer, site, false)
  doAssert goldDrop == hallId,
    "gold must only drop at a town hall"

echo "Testing construction, training, food, and cancellation"
block basesGrow:
  var w = newWorld(map, MatchTicks)
  let
    peon = w.units[0].id
    hall = map.hallOrigin[LightPlayer]
  doAssert w.units[0].owner == LightPlayer
  ## Find a legal farm site near home.
  var site = NoTile
  for radius in 4'i32 .. 10'i32:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        let
          x = int32(hall.x) + dx
          y = int32(hall.y) + dy
        if map.inGrid(x, y) and w.canPlace(FarmBuilding, x, y):
          site = tile2(x, y)
          break
      if map.inGrid(site): break
    if map.inGrid(site): break
  doAssert map.inGrid(site), "nowhere to put a farm near the opening base"

  let
    goldBefore = w.players[LightPlayer].gold
    stats = BuildingTable[FarmBuilding]
  w.units[0].orderFailed = true
  doAssert w.applyBuild(LightPlayer, peon, int32(FarmBuilding.ord),
    int32(site.x), int32(site.y)), "a farm order was rejected"
  doAssert not w.units[0].orderFailed
  doAssert w.players[LightPlayer].gold == goldBefore - stats.gold,
    "the farm was not paid for when the order was accepted"
  doAssert not w.canPlace(FarmBuilding, int32(site.x), int32(site.y)),
    "the site is still advertised as free after being claimed"

  let capBefore = w.players[LightPlayer].foodCap
  w.run(TickRate * 40)
  w.checkOccupancy("building")
  var farmId = NoEntity
  for structure in w.buildings:
    if structure.owner == LightPlayer and structure.kind == FarmBuilding:
      farmId = structure.id
  doAssert farmId != NoEntity, "the farm vanished"
  let farm = w.buildingIndex(farmId)
  doAssert w.buildings[farm].state == BuildingComplete,
    "forty seconds was not enough to raise a farm"
  doAssert w.buildings[farm].hp == stats.hp
  doAssert w.players[LightPlayer].foodCap == capBefore + stats.foodProvided,
    "the finished farm did not raise the food cap"
  ## The builder is released, not consumed.
  doAssert w.hasUnit(peon), "the builder was eaten by its own farm"
  doAssert w.units[w.unitIndex(peon)].state == UnitIdle,
    "the builder was not released when its farm finished"

block trainingSpendsAndRespectsFood:
  var w = newWorld(map, MatchTicks)
  var hallId = NoEntity
  for structure in w.buildings:
    if structure.owner == LightPlayer and structure.kind == TownHallBuilding:
      hallId = structure.id
  doAssert hallId != NoEntity

  ## The opening cap is five food and five peons already use it all.
  doAssert not w.canTrain(hallId, PeonUnit),
    "a full food cap still allowed training"
  doAssert not w.applyTrain(LightPlayer, hallId, int32(PeonUnit.ord))

  ## Free a slot and it should work.
  w.players[LightPlayer].foodCap += 4
  let
    goldBefore = w.players[LightPlayer].gold
    foodBefore = w.players[LightPlayer].foodUsed
    stats = UnitTable[LightPlayer][PeonUnit]
  doAssert w.applyTrain(LightPlayer, hallId, int32(PeonUnit.ord)),
    "training was rejected with food to spare"
  doAssert w.players[LightPlayer].gold == goldBefore - stats.gold
  doAssert w.players[LightPlayer].foodUsed == foodBefore + stats.food,
    "queued training did not reserve its food"

  ## A soldier cannot come out of a town hall.
  doAssert not w.applyTrain(LightPlayer, hallId, int32(SoldierUnit.ord)),
    "a town hall trained a soldier"

  let unitsBefore = w.units.len
  w.run(stats.trainTicks + TickRate)
  doAssert w.units.len == unitsBefore + 1, "the peon never appeared"
  doAssert w.players[LightPlayer].unitsTrained == 1
  doAssert w.players[LightPlayer].foodUsed == foodBefore + stats.food,
    "food was charged twice for one unit"

block cancellingRefunds:
  var w = newWorld(map, MatchTicks)
  var hallId = NoEntity
  for structure in w.buildings:
    if structure.owner == LightPlayer and structure.kind == TownHallBuilding:
      hallId = structure.id
  w.players[LightPlayer].foodCap += 4
  let
    goldBefore = w.players[LightPlayer].gold
    foodBefore = w.players[LightPlayer].foodUsed
  doAssert w.applyTrain(LightPlayer, hallId, int32(PeonUnit.ord))
  doAssert w.applyCancel(LightPlayer, hallId)
  doAssert w.players[LightPlayer].gold == goldBefore,
    "cancelling a queued unit did not refund its gold"
  doAssert w.players[LightPlayer].foodUsed == foodBefore,
    "cancelling a queued unit did not release its food"

echo "Testing the reference overlord starts building"
block openingBuild:
  ## The BASIC script harvests every idle peon and then issues a build to
  ## one of them. That second order must replace the queued harvest path,
  ## or the builder stands on spawn forever and the farm never rises.
  let source = readFile("examples/light_vs_dark/players/base.bas")
  var game = newGame(map, TickRate * 45)
  loadBots(game, [source, source])
  proc decide(w: World) =
    runBotDecisions(game)
  for _ in 1 .. TickRate * 30:
    game.world.tickWorld(decide)
  for player in 0'i32 ..< DefaultPlayerCount:
    doAssert game.brains[player] != nil and game.brains[player].ready,
      "player " & $player & " did not load the reference overlord"
    doAssert not game.brains[player].failed,
      "player " & $player & " BASIC error: " & game.brains[player].lastError
  var raised = 0
  for structure in game.world.buildings:
    if structure.kind == FarmBuilding and
        structure.state == BuildingComplete:
      inc raised
  doAssert raised >= 1,
    "the opening overlords never finished a farm in 30s"
  echo "  " & $raised & " farm(s) finished in the opening 30s"

echo "Testing combat and defeat"
block unitsFightAndDie:
  var w = newWorld(map, MatchTicks)
  w.wartime()
  let
    attacker = w.units[0].id
    defender = w.units[int(StartingPeons)].id
  doAssert w.units[0].owner == LightPlayer
  doAssert w.unitOwner(defender) == DarkPlayer
  ## Stand them next to each other in open ground and let them brawl.
  let arena = arenaTile(-4)
  doAssert w.tileFree(int32(arena.x), int32(arena.y))
  doAssert w.tileFree(int32(arena.x) + 1, int32(arena.y))
  for (id, tile) in [(attacker, arena), (defender, arenaTile(-3))]:
    let index = w.unitIndex(id)
    w.place(w.units[index], tile)
  w.rebuildVision()
  w.units[w.unitIndex(attacker)].orderFailed = true
  doAssert w.applyAttack(LightPlayer, attacker, defender)
  doAssert not w.units[w.unitIndex(attacker)].orderFailed
  doAssert not w.applyAttack(LightPlayer, attacker, w.units[1].id),
    "a unit was ordered to attack its own side"

  let hpBefore = w.units[w.unitIndex(defender)].hp
  w.run(TickRate * 10 div 3)
  doAssert not w.hasUnit(defender) or
    w.units[w.unitIndex(defender)].hp < hpBefore,
    "two hundred ticks of combat did no damage"
  w.run(TickRate * 80)
  doAssert not w.hasUnit(defender), "the defender never died"
  doAssert w.players[DarkPlayer].unitsLost == 1
  w.checkOccupancy("after combat")

block losingEverythingLosesTheMatch:
  var w = newWorld(map, MatchTicks)
  ## Raze everything Dark owns and kill every Dark peon.
  for index in 0 ..< w.buildings.len:
    if w.buildings[index].owner == DarkPlayer:
      w.damageEntity(w.buildings[index].id, w.buildings[index].hp)
  for index in 0 ..< w.units.len:
    if w.units[index].owner == DarkPlayer:
      w.damageEntity(w.units[index].id, w.units[index].hp)
  w.run(1)
  doAssert w.over, "a player with nothing left did not lose"
  doAssert w.winner == LightPlayer, &"the wrong player won: {w.winner}"

block reachingTheCapDecidesOnScore:
  var w = newWorld(map, TickRate * 4)
  w.players[LightPlayer].goldGathered = 50_000
  w.run(TickRate * 4)
  doAssert w.over, "the match did not end at its tick limit"
  doAssert w.winner == LightPlayer,
    "the richer player did not win on score"

echo "Testing attack-move engages enemies that a move walks past"
block attackMoveFightsOnTheWay:
  var w = newWorld(map, MatchTicks)
  w.wartime()
  let
    walker = w.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-4))
    foe = w.spawnUnit(DarkPlayer, SoldierUnit, arenaTile(-1))
  w.rebuildVision()
  doAssert w.applyAttackMove(
    LightPlayer, walker, map.side div 2 + 6, map.side div 2
  )
  let hpBefore = w.units[w.unitIndex(foe)].hp
  w.run(TickRate * 8)
  doAssert not w.hasUnit(foe) or
    w.units[w.unitIndex(foe)].hp < hpBefore,
    "an attack-move walked past a visible enemy without fighting"

block plainMoveIgnoresEnemies:
  var w = newWorld(map, MatchTicks)
  w.wartime()
  let
    walker = w.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-4))
    foe = w.spawnUnit(DarkPlayer, SoldierUnit, arenaTile(-1))
  w.rebuildVision()
  doAssert w.applyMove(LightPlayer, walker, map.side div 2 + 6, map.side div 2)
  let hpBefore = w.units[w.unitIndex(foe)].hp
  w.run(TickRate * 2)
  doAssert w.hasUnit(foe)
  doAssert w.units[w.unitIndex(foe)].hp == hpBefore,
    "a plain move stopped to fight instead of walking through"
  doAssert w.units[w.unitIndex(walker)].state == UnitMoving,
    "the walker finished or abandoned the plain move too soon"

block attackMoveStopsAtRange:
  var w = newWorld(map, MatchTicks)
  w.wartime()
  let
    archer = w.spawnUnit(LightPlayer, ArcherUnit, arenaTile(-4))
    foe = w.spawnUnit(DarkPlayer, PeonUnit, arenaTile(2))
  w.rebuildVision()
  doAssert w.applyAttackMove(
    LightPlayer, archer, map.side div 2 + 6, map.side div 2
  )
  let hpBefore = w.units[w.unitIndex(foe)].hp
  w.run(TickRate * 8)
  doAssert w.hasUnit(foe)
  doAssert w.units[w.unitIndex(foe)].hp < hpBefore,
    "the archer never shot during the attack-move"
  doAssert tileDistance(
    w.units[w.unitIndex(archer)].tile,
    w.units[w.unitIndex(foe)].tile
  ) >= 2,
    "the archer closed to melee instead of shooting at range"

proc placeSquad(w: World, player: int32, anchor: Tile2,
    count: int): seq[int32] =
  ## Drops a block of soldiers around a tile and returns their identifiers.
  for _ in 0 ..< count:
    var spawn = NoTile
    block search:
      for radius in 0'i32 .. 10'i32:
        for dy in -radius .. radius:
          for dx in -radius .. radius:
            let tile = tile2(int32(anchor.x) + dx, int32(anchor.y) + dy)
            if map.inGrid(tile) and w.tileFree(int32(tile.x), int32(tile.y)):
              spawn = tile
              break search
    if not map.inGrid(spawn):
      return
    result.add w.spawnUnit(player, SoldierUnit, spawn)
    w.players[player].foodUsed += UnitTable[player][SoldierUnit].food

echo "Testing the chokepoint does not deadlock"
block fordsClear:
  ## Forty units of ONE side pushed both ways through the middle ford. Using
  ## a single player keeps combat out of it, so this measures only whether
  ## two-way traffic through a narrow gap resolves. Strict one-unit-per-tile
  ## is at its worst here, and the shove, swap, and abandon escalation exists
  ## precisely for this case.
  var w = newWorld(map, 200_000)
  let
    west = tile2(map.side div 2 - 10, map.side div 2 - 8)
    east = tile2(map.side div 2 + 10, map.side div 2 + 8)
    eastward = w.placeSquad(LightPlayer, west, 20)
    westward = w.placeSquad(LightPlayer, east, 20)
  doAssert eastward.len == 20 and westward.len == 20,
    &"could not place the squads: {eastward.len} and {westward.len}"

  for id in eastward:
    doAssert w.applyMove(LightPlayer, id, int32(east.x), int32(east.y))
  for id in westward:
    doAssert w.applyMove(LightPlayer, id, int32(west.x), int32(west.y))

  for tick in 1 .. TickRate * 150:
    w.tickWorld(noDecisions)
    if tick mod 50 == 0:
      w.checkOccupancy("ford")

  var
    crossed = 0
    jammed = 0
  for unit in w.units:
    if unit.kind != SoldierUnit:
      continue
    let goal = if unit.id in eastward: east else: west
    if tileDistance(unit.tile, goal) <= 10:
      inc crossed
    if unit.blockedTicks >= AbandonAfterTicks:
      inc jammed
  doAssert jammed == 0, &"{jammed} units are still grinding at the ford"
  doAssert crossed == 40, &"only {crossed} of 40 units crossed the ford"
  echo &"  all {crossed} units crossed the ford in both directions"

echo "Testing that an army can cross the whole map"
block armiesReachTheEnemy:
  ## Base to base is about 120 tiles through a ford. If A* cannot produce a
  ## complete route that far, units stall on the near bank and the game has
  ## no late phase at all, so this is a gameplay requirement and not just a
  ## pathing detail.
  var w = newWorld(map, 200_000)
  let
    target = map.hallOrigin[DarkPlayer]
    squad = w.placeSquad(LightPlayer, tile2(30, 30), 20)
  doAssert squad.len == 20
  for id in squad:
    doAssert w.applyMove(LightPlayer, id, int32(target.x), int32(target.y))

  for tick in 1 .. TickRate * 200:
    w.tickWorld(noDecisions)
    if tick mod 200 == 0:
      w.checkOccupancy("march")

  var
    arrived = 0
    gaveUp = 0
  for unit in w.units:
    if unit.kind != SoldierUnit:
      continue
    if tileDistance(unit.tile, target) <= 12:
      inc arrived
    if unit.orderFailed:
      inc gaveUp
  echo "  ", arrived, "/20 reached the enemy base, ", gaveUp, " gave up"
  doAssert arrived >= 15,
    "only " & $arrived & " of 20 units reached the enemy base"

echo "Testing that a recorded match replays tick for tick"
block replayReproducesTheMatch:
  ## The whole point of recording only accepted commands is that re-running
  ## them through the same validators rebuilds the match exactly. A command
  ## that mutates the world and then reports refusal would never be written
  ## down, and this is what catches it.
  const Ticks = TickRate * 200 div 3
  let setup = Setup(
    mapSeed: DefaultSeed,
    tickRate: uint16(TickRate),
    gridTiles: uint16(map.side),
    decisionTicks: uint16(DecisionTicks),
    maximumTicks: uint32(Ticks),
    mapHash: map.hash,
    contentHash: contentHash(),
    players: @[
      ReplayPlayerSetup(id: 0,
        startX: int32(map.hallOrigin[LightPlayer].x),
        startY: int32(map.hallOrigin[LightPlayer].y)),
      ReplayPlayerSetup(id: 1,
        startX: int32(map.hallOrigin[DarkPlayer].x),
        startY: int32(map.hallOrigin[DarkPlayer].y))
    ]
  )
  let recorder = initReplayRecorder(setup)
  var liveGame = newGame(map, Ticks)
  liveGame.recorder = recorder
  const Queries = """
i = 0
while i < obsCount
  if obsKind(i) = 2 and obsOwner(i) = selfPlayer then
    id = obsId(i)
    first = orderFailed(id)
    second = orderFailed(id)
  end if
  i = i + 1
wend
"""
  loadBots(liveGame, [Queries, Queries])
  var
    failureQueries = 0
    blockedTree = -1'i32
  for index in 0 ..< (map.side * map.side):
    if liveGame.world.treeWood[index] == 0:
      continue
    var enclosed = true
    for dy in -1'i32 .. 1'i32:
      for dx in -1'i32 .. 1'i32:
        if liveGame.world.tileOpen(
          int32(index) mod map.side + dx,
          int32(index) div map.side + dy
        ):
          enclosed = false
    if enclosed:
      blockedTree = int32(index)
      break
  doAssert blockedTree >= 0, "the map needs an unreachable tree"

  proc scripted(w: World) =
    ## A deterministic stand-in for an overlord, exercising every command
    ## kind including ones that will be refused or will fail to arrive.
    for unit in w.units:
      if unit.orderFailed:
        inc failureQueries
    let before = liveGame.stateHash()
    runBotDecisions(liveGame)
    doAssert liveGame.stateHash() == before,
      "BASIC failure queries must not change replay state"
    let player = (w.tick div DecisionTicks) mod DefaultPlayerCount
    var
      hall = NoEntity
      mine = NoEntity
    for structure in w.buildings:
      if structure.owner == player and structure.kind == TownHallBuilding:
        hall = structure.id
      if structure.owner < 0 and mine == NoEntity:
        mine = structure.id
    for index in 0 ..< w.units.len:
      if w.units[index].owner != player or w.units[index].state != UnitIdle:
        continue
      let id = w.units[index].id
      case int(id + w.tick) mod 4
      of 0: discard liveGame.applyHarvest(player, id, mine, 0)
      of 1:
        let tree = w.nearestTree(w.units[index].tile)
        if tree >= 0:
          discard liveGame.applyHarvest(player, id, tree, 1)
      of 2:
        discard liveGame.applyAttackMove(
          player, id, 40 + player * 40, 40
        )
      else:
        ## Deliberately hopeless: aimed into the river, and at a tile the
        ## unit may well never reach.
        discard liveGame.applyMove(player, id, 64, 63)
    if hall != NoEntity and w.tick mod (TickRate * 10) == 0:
      discard liveGame.applyTrain(player, hall, int32(PeonUnit.ord))
      discard liveGame.applySetRally(player, hall, 30 + player * 60, 30)
    if w.tick mod (TickRate * 20) == 0:
      for index in 0 ..< w.units.len:
        if w.units[index].owner == player and
            w.units[index].kind == PeonUnit:
          discard liveGame.applyBuild(player, w.units[index].id,
            int32(FarmBuilding.ord), 26 + player * 60, 26)
          discard liveGame.applyCancel(player, w.units[index].id)
          break
    if w.tick == DecisionTicks:
      doAssert liveGame.applyHarvest(
        LightPlayer,
        w.units[0].id,
        blockedTree,
        1
      )
      doAssert w.units[0].orderFailed

  var liveHashes: seq[uint64]
  for _ in 1 .. Ticks:
    liveGame.world.tickWorld(scripted)
    let hash = liveGame.stateHash()
    liveHashes.add hash
    liveGame.recorder.recordHash(hash)
  doAssert recorder.data.actions.len > 20,
    "the scripted overlord issued only " & $recorder.data.actions.len &
    " commands, so this proves little"
  doAssert failureQueries > 0, "the overlords never queried a failed order"
  for brain in liveGame.brains:
    doAssert not brain.failed, brain.lastError

  ## Round trip through the real codec, not the in-memory object.
  let data = decodeReplay(recorder.data.encodeReplay())
  let cursor = initReplayPlayer(data)

  proc drain(w: World) =
    var action: ReplayAction
    while cursor.takeActionAt(uint32(w.tick), action):
      w.applyReplayAction(action)

  var replayed = newWorld(map, Ticks)
  for tick in 1 .. Ticks:
    replayed.tickWorld(drain)
    doAssert replayed.stateHash() == liveHashes[tick - 1],
      &"replay diverged from the recorded match at tick {tick}"
  doAssert cursor.finished, "the replay had commands left over"
  doAssert replayed.players == liveGame.world.players
  doAssert replayed.units.len == liveGame.world.units.len
  echo "  " & $data.actions.len & " commands replayed over " & $Ticks &
    " ticks with no divergence"

echo "test_lvd_sim: all checks passed"

echo "Testing the simulation winner determines standings"
block:
  let world = newWorld(map, MatchTicks)
  world.winner = -1
  doAssert world.scores() == @[0, 0]
  world.winner = LightPlayer
  doAssert world.scores() == @[1, 0]
  world.winner = DarkPlayer
  doAssert world.scores() == @[0, 1]

echo "Testing credited kills and deterministic statistics checkpoints"
block:
  let game = newGame(map, MatchTicks)
  game.world.wartime()
  let initial = game.stateHash()
  game.world.stats.add(0, KillsMetric)
  doAssert game.stateHash() != initial
  let snapshot = game.world.clone()
  var victim = NoEntity
  for unit in game.world.units:
    if unit.owner == DarkPlayer:
      victim = unit.id
      break
  game.world.damageEntity(victim, 100_000, LightPlayer)
  game.world.damageEntity(victim, 100_000, LightPlayer)
  game.sampleMetrics()
  doAssert game.metrics.read(0, 0).values[KillsMetric] == 2
  doAssert game.metrics.read(1, 0).values[LossesMetric] == 1
  doAssert snapshot.stats.values[0][KillsMetric] == 1
  game.world.restore(snapshot)
  game.sampleMetrics()
  doAssert game.metrics.read(0, 0).values[KillsMetric] == 1
  for building in game.world.buildings:
    if building.owner == DarkPlayer:
      game.world.damageEntity(building.id, 100_000, LightPlayer)
      break
  doAssert game.world.stats.values[0][StructuresMetric] == 1

echo "Testing LVD decimal move orders and replay payloads"
block:
  let
    game = newGame(map, MatchTicks)
    unit = game.world.units[0]
    origin = unit.body.pos
    offset = fixedVec2(0.25'fx, -0.25'fx)
  loadBots(game, ["accepted = moveUnit(" & $unit.id & ", " &
    $unit.tile.x & " + 0.25, " & $unit.tile.y & " - 0.25)\n", ""])
  game.world.tick = DecisionTicks
  game.recorder = initReplayRecorder(Setup(
    players: @[ReplayPlayerSetup(id: 0), ReplayPlayerSetup(id: 1)]
  ))
  runBotDecisions(game)
  doAssert not game.brains[0].failed
  doAssert unit.goalOffset == offset
  doAssert game.recorder.data.actions.len == 1
  let action = game.recorder.data.actions[0]
  doAssert action.offset == offset
  let snapshot = game.world.clone()
  for pass in 0 .. 1:
    if pass == 1:
      game.world.restore(snapshot)
      doAssert game.world.applyReplayAction(action)
    game.world.run(60)
    doAssert game.world.units[0].state == UnitIdle
    doAssert length(game.world.units[0].body.pos - origin - offset) <=
      fixed(1, 1000)
