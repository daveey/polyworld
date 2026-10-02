## Light vs Dark overlord scripting: the whole surface a BASIC program has
## on the simulation.
##
## One VM per player, not per unit. Every command carries an entity
## identifier and is refused unless the calling player owns that entity, so
## the captured `playerId` in the host closures is the entire authorisation
## boundary.
##
## Observations come from a snapshot taken once per decision rather than from
## live state. That keeps indices stable while a script issues commands that
## kill things, and it is where fog of war is applied.

import
  polyworld/neural,
  bassy,
  polyworld/[mailboxes, bodies, metrics, profiles],
  content,
  sim

when defined(coworld):
  import polyworld/coworld

const
  ObservedBuilding* = 1'i32
  ObservedUnit* = 2'i32
  ObservedMine* = 3'i32
  ObservedTree* = 4'i32

  FlagIdle* = 1'i32
    ## The unit is taking no orders, or the structure is finished.
  FlagUnderConstruction* = 2'i32
  FlagOrderFailed* = 4'i32
    ## The unit's last order was abandoned. Own units only.
  FlagDropOff* = 8'i32
  FlagCarrying* = 16'i32

  MaxObservedTrees* = 64
    ## A forested map has thousands of tree tiles. Reporting them all would
    ## swamp both the snapshot and the script's instruction budget, so only
    ## the closest few are listed and `nearestTree` covers the rest.

type
  Observed* = object
    id*: int32
      ## Entity identifier, or the flat tile index for a tree.
    kind*: int32
      ## 1 structure, 2 unit, 3 gold mine, 4 tree.
    owner*: int32
      ## 0 Light, 1 Dark, -1 neutral.
    sub*: int32
      ## `UnitKind.ord` or `BuildingKind.ord`.
    x*, y*: int32
    hp*, maxHp*: int32
    state*: int32
    flags*: int32
    resource*: int32
      ## Gold left in a mine, or wood left on a tree.
  OverlordDataSlot = enum
    DataSelfPlayer,
    DataEnemyPlayer,
    DataWorldTick,
    DataGold,
    DataWood,
    DataFoodUsed,
    DataFoodCap,
    DataObsCount,
    DataOwnUnits,
    DataOwnBuildings,
    DataHomeX,
    DataHomeY,
    DataMapSize,
    DataDecisionPeriod

const
  OverlordDataNames: array[OverlordDataSlot, string] = [
    "selfPlayer",
    "enemyPlayer",
    "worldTick",
    "gold",
    "wood",
    "foodUsed",
    "foodCap",
    "obsCount",
    "ownUnits",
    "ownBuildings",
    "homeX",
    "homeY",
    "mapSize",
    "decisionPeriod"
  ]

var
  activeGame: Game
  activePlayer: int32
  snapshot: seq[Observed]
  ownUnitCount, ownBuildingCount: int32
  overlordDataIds: array[OverlordDataSlot, int32]

proc bindOverlordData(program: Program) =
  ## Resolves host data slots once so think ticks do not allocate names.
  for slot, name in OverlordDataNames:
    overlordDataIds[slot] = program.hostDataIndex(name)
    doAssert overlordDataIds[slot] >= 0, "missing host data " & name

template game(): World = activeGame.world

## Snapshot

proc unitFlags(unit: Unit, own: bool): int32 =
  ## Packs idle, failed-order, and carrying bits for one snapshot unit.
  if unit.state == UnitIdle:
    result = result or FlagIdle
  if own and unit.orderFailed:
    result = result or FlagOrderFailed
  if unit.carryGold > 0 or unit.carryWood > 0:
    result = result or FlagCarrying

proc buildingFlags(structure: Building): int32 =
  if structure.state == BuildingComplete:
    result = result or FlagIdle
  if structure.state == BuildingUnderConstruction:
    result = result or FlagUnderConstruction
  let stats = BuildingTable[structure.kind]
  if stats.dropOffGold or stats.dropOffWood:
    result = result or FlagDropOff

proc observeUnit(w: World, index: int, own: bool): Observed =
  ## Copies one unit into the decision snapshot without cloning its path.
  let unit = w.units[index]
  Observed(
    id: unit.id,
    kind: ObservedUnit,
    owner: unit.owner,
    sub: int32(unit.kind.ord),
    x: int32(unit.tile.x),
    y: int32(unit.tile.y),
    hp: unit.hp,
    maxHp: UnitTable[unit.owner][unit.kind].hp,
    state: int32(unit.state.ord),
    flags: unitFlags(unit, own),
    resource: unit.carryGold + unit.carryWood
  )

proc observeBuilding(structure: Building): Observed =
  Observed(
    id: structure.id,
    kind: if structure.owner < 0: ObservedMine else: ObservedBuilding,
    owner: structure.owner,
    sub: int32(structure.kind.ord),
    x: int32(structure.origin.x),
    y: int32(structure.origin.y),
    hp: structure.hp,
    maxHp: structure.maxHp,
    state: int32(structure.state.ord),
    flags: buildingFlags(structure),
    resource: structure.goldLeft
  )

proc buildSnapshot(w: World, player: int32) =
  ## Rebuilds this decision's view of the world in a canonical order: own
  ## structures, own units, then whatever of the enemy's is visible, then
  ## neutral mines and the nearest trees. Everything is identifier-ascending
  ## within its group, so the same world always produces the same snapshot.
  snapshot.setLen(0)
  ownBuildingCount = 0
  ownUnitCount = 0

  for structure in w.buildings:
    if structure.owner == player and structure.state != BuildingDying:
      snapshot.add observeBuilding(structure)
      inc ownBuildingCount
  for i in 0 ..< w.units.len:
    let unit = w.units[i]
    if unit.owner == player and unit.state != UnitDying:
      snapshot.add w.observeUnit(i, true)
      inc ownUnitCount

  let enemy = 1 - player
  for structure in w.buildings:
    if structure.owner == enemy and structure.state != BuildingDying and
        w.buildingVisible(player, structure):
      snapshot.add observeBuilding(structure)
  for i in 0 ..< w.units.len:
    let unit = w.units[i]
    if unit.owner == enemy and w.unitVisible(player, i):
      snapshot.add w.observeUnit(i, false)

  ## Neutral gold mines and trees are terrain, not intelligence, so they are
  ## always listed. Fog hides what the enemy is doing, not what the map is;
  ## making a player scout for its own forest would be tedious rather than
  ## interesting, and `nearestTree` agrees with this rule.
  for structure in w.buildings:
    if structure.owner < 0:
      snapshot.add observeBuilding(structure)

  ## Nearest trees to the player's home, capped. Ties break on tile index so
  ## two identical worlds always list the same ones.
  var home = tile2(GridSide div 2, GridSide div 2)
  for structure in w.buildings:
    if structure.owner == player and structure.kind == TownHallBuilding:
      home = structure.origin
      break
  var
    treeIndices: array[MaxObservedTrees, int32]
    treeRanges: array[MaxObservedTrees, int32]
    treeCount = 0
  for index in 0 ..< GridCells:
    if w.treeWood[index] <= 0:
      continue
    let
      tile = tile2(int32(index) mod GridSide, int32(index) div GridSide)
      distance = chebyshev(tile, home)
    if treeCount == MaxObservedTrees and
        distance >= treeRanges[MaxObservedTrees - 1]:
      continue
    var slot = min(treeCount, MaxObservedTrees - 1)
    while slot > 0 and treeRanges[slot - 1] > distance:
      treeRanges[slot] = treeRanges[slot - 1]
      treeIndices[slot] = treeIndices[slot - 1]
      dec slot
    treeRanges[slot] = distance
    treeIndices[slot] = int32(index)
    if treeCount < MaxObservedTrees:
      inc treeCount
  for slot in 0 ..< treeCount:
    let index = treeIndices[slot]
    snapshot.add Observed(
      id: index,
      kind: ObservedTree,
      owner: -1,
      x: index mod GridSide,
      y: index div GridSide,
      resource: int32(w.treeWood[index])
    )

## Host surface

proc overlordLimits*(): Limits =
  ## Budgets one decision.
  ##
  ## Sized so both players fit inside one simulation tick with room to spare,
  ## keeping headless runs far above real time. The ceiling is
  ## deliberately reachable: a naive scan of every unit against every other
  ## unit will exceed it and fail the script, which is the pressure that
  ## pushes authors onto `nearestEnemy` and friends.
  result = defaultLimits()
  result.maxStringBytes = 256 * 1024
  result.maxSourceBytes = 256 * 1024
  result.maxCodeInstructions = 100_000
  result.maxArrays = 64
  result.maxArrayElements = 65_536
  result.maxGlobals = 1_024
  result.maxHostData = 64
  result.maxHostFunctions = 128
  result.maxRoutines = 128
  result.maxParameters = 16
  result.maxRegisters = 512
  result.maxSyntaxDepth = 32
  result.maxCallDepth = 24
  result.maxMemoryBytes = 8 * 1024 * 1024
  result.maxInstructions = 300_000
  result.maxWorkUnits = 400_000
  result.maxPrintBytes = 8 * 1024
  result.maxPrintEvents = 512

proc observedAt(index: int32): Observed =
  ## Reads one snapshot entry, or a zeroed entry when out of range.
  if index < 0 or index >= snapshot.len:
    return Observed(owner: -1)
  snapshot[index]

proc sendChat*(
  game: Game, sender, target: int, text: openArray[char]
): int32 =
  ## Routes global broadcasts and direct messages between players.
  if sender notin 0 ..< game.inboxes.len or
    target < -2 or target == -1 or target >= game.inboxes.len:
      return 0
  let id = int32(if target < 0: target else: sender)
  for recipient in 0 ..< game.inboxes.len:
    case target
    of -2:
      discard
    else:
      if recipient != target:
        continue
    if game.inboxes[recipient].push(id, text):
      inc result

proc buildOverlordHost*(playerId: int32): Host =
  ## Builds the complete world-query and command interface for one player.
  ##
  ## The same builder makes both the compile-time schema and each player's
  ## live instance, because `initRuntime` validates every binding's arity and
  ## work cost against what the program was compiled with. Any drift between
  ## the two would fail at startup with an opaque binding error.
  ##
  ## Work costs are roughly proportional to what each call makes the host do,
  ## then rounded to something memorable. Commands that queue a path search
  ## cost far more than their own cycles, so a script's budget prices its
  ## demand on the simulation rather than only its own arithmetic.
  result = initHost()
  result.addNeuralFunctions()
  let sendChatProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Sends script text through the game's routing rules.
    let player = int(playerId)
    activeGame.brains[player].runtime.withString(args[1], text):
      result = activeGame.sendChat(player, int(args[0].asInt), text)
  let pullMailboxProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Copies the oldest message into BASIC and consumes it on success.
    let
      player = int(playerId)
      inbox = activeGame.inboxes[player]
    var runtime = activeGame.brains[player].runtime
    if inbox.count == 0:
      result = runtime.putString("")
    else:
      result = runtime.putString(inbox.messages[inbox.first])
    discard inbox.pop()
  let mailboxIdProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the channel or DM sender of the last pulled message.
    activeGame.inboxes[int(playerId)].lastId
  let mailboxCountProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Counts this player's unread messages.
    int32(activeGame.inboxes[int(playerId)].count)
  let mailboxSelfProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns this player's zero-based mailbox address.
    int32(int(playerId))
  let mailboxPlayersProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the number of player mailboxes in this game.
    int32(activeGame.inboxes.len)
  discard result.addFunction("sendChat", 2, sendChatProc, 256)
  discard result.addFunction("pullMailbox$", 0, pullMailboxProc, 256)
  discard result.addFunction("mailboxId", 0, mailboxIdProc, 4)
  discard result.addFunction("mailboxCount", 0, mailboxCountProc, 4)
  discard result.addFunction("mailboxSelf", 0, mailboxSelfProc, 4)
  discard result.addFunction("mailboxPlayers", 0, mailboxPlayersProc, 4)
  for name in OverlordDataNames:
    discard result.addData(name)

  ## Observation readers: one bounds-checked array read each.
  template reader(readerName: string, field: untyped) =
    let callback: HostProc = proc(arguments: openArray[int32]): int32 =
      observedAt(arguments[0]).field
    discard result.addFunction(readerName, 1, callback, 3)

  reader("obsId", id)
  reader("obsKind", kind)
  reader("obsOwner", owner)
  reader("obsSub", sub)
  reader("obsX", x)
  reader("obsY", y)
  reader("obsHp", hp)
  reader("obsMaxHp", maxHp)
  reader("obsState", state)
  reader("obsResource", resource)

  ## Exposes each observed condition as an integer 1 or 0.
  template flagReader(readerName: string, bit: int32) =
    let callback: HostProc = proc(arguments: openArray[int32]): int32 =
      int32((observedAt(arguments[0]).flags and bit) != 0)
    discard result.addFunction(readerName, 1, callback, 3)

  flagReader("obsIdle", FlagIdle)
  flagReader("obsUnderConstruction", FlagUnderConstruction)
  flagReader("obsFailed", FlagOrderFailed)
  flagReader("obsDropOff", FlagDropOff)
  flagReader("obsCarrying", FlagCarrying)

  let obsIndexOfProc: HostProc = proc(arguments: openArray[int32]): int32 =
    result = -1
    for index, entry in snapshot:
      if entry.id == arguments[0] and entry.kind != ObservedTree:
        return int32(index)
  discard result.addFunction("obsIndexOf", 1, obsIndexOfProc, 4)

  ## Derived queries. The host absorbs the scanning so a script does not have
  ## to spend its instruction budget on nested loops.
  let distanceProc: HostProc = proc(arguments: openArray[int32]): int32 =
    max(abs(arguments[0] - arguments[2]), abs(arguments[1] - arguments[3]))
  discard result.addFunction("distance", 4, distanceProc, 2)

  let nearestEnemyProc: HostProc = proc(
      arguments: openArray[int32]): int32 =
    let index = game.unitIndex(arguments[0])
    if index < 0:
      return NoEntity
    let unit = game.units[index]
    if unit.owner != playerId:
      return NoEntity
    let origin = unit.tile
    var best = int32.high
    for entry in snapshot:
      if entry.owner != 1 - playerId:
        continue
      let distance = max(abs(entry.x - int32(origin.x)),
        abs(entry.y - int32(origin.y)))
      if distance < best or (distance == best and entry.id < result):
        best = distance
        result = entry.id
  discard result.addFunction("nearestEnemy", 1, nearestEnemyProc, 120)

  let nearestOwnIdleProc: HostProc = proc(
      arguments: openArray[int32]): int32 =
    var best = int32.high
    for entry in snapshot:
      if entry.kind != ObservedUnit or entry.owner != playerId:
        continue
      if (entry.flags and FlagIdle) == 0:
        continue
      if arguments[0] >= 0 and entry.sub != arguments[0]:
        continue
      let distance = max(abs(entry.x - arguments[1]),
        abs(entry.y - arguments[2]))
      if distance < best or (distance == best and entry.id < result):
        best = distance
        result = entry.id
  discard result.addFunction("nearestOwnIdle", 3, nearestOwnIdleProc, 120)

  let nearestMineProc: HostProc = proc(arguments: openArray[int32]): int32 =
    var best = int32.high
    for entry in snapshot:
      if entry.kind != ObservedMine or entry.resource <= 0:
        continue
      let distance = max(abs(entry.x - arguments[0]),
        abs(entry.y - arguments[1]))
      if distance < best or (distance == best and entry.id < result):
        best = distance
        result = entry.id
  discard result.addFunction("nearestMine", 2, nearestMineProc, 40)

  let nearestTreeProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Trees are terrain rather than intelligence, so they are not fogged.
    ## Returns a flat tile index, which is what `harvest` wants for wood.
    ## Rings are scanned outward and ties inside a ring go to the lowest
    ## index, so the same question always gets the same answer.
    result = -1
    for radius in 0'i32 ..< GridSide:
      for dy in -radius .. radius:
        for dx in -radius .. radius:
          if max(abs(dx), abs(dy)) != radius:
            continue
          let
            x = arguments[0] + dx
            y = arguments[1] + dy
          if not inGrid(x, y):
            continue
          let index = tileIndex(x, y)
          if game.treeWood[index] > 0 and (result < 0 or index < result):
            result = index
      if result >= 0:
        return
  discard result.addFunction("nearestTree", 2, nearestTreeProc, 160)

  let nearestDropOffProc: HostProc = proc(
      arguments: openArray[int32]): int32 =
    game.nearestDropOff(playerId, tile2(arguments[0], arguments[1]),
      arguments[2] != 0)
  discard result.addFunction("nearestDropOff", 3, nearestDropOffProc, 40)

  let tilePassableProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(game.tileOpen(arguments[0], arguments[1]))
  discard result.addFunction("tilePassable", 2, tilePassableProc, 3)

  let tileVisibleProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(game.visible(playerId, arguments[0], arguments[1]))
  discard result.addFunction("tileVisible", 2, tileVisibleProc, 3)

  let tileExploredProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(game.explored(playerId, arguments[0], arguments[1]))
  discard result.addFunction("tileExplored", 2, tileExploredProc, 3)

  let canPlaceProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if arguments[0] < 0 or arguments[0] > int32(BuildableHigh.ord):
      return 0
    let size = BuildingTable[BuildingKind(arguments[0])].footprint
    if not inGrid(arguments[1], arguments[2]) or
        not inGrid(arguments[1] + size.width - 1,
          arguments[2] + size.depth - 1):
      return 0
    int32(game.canPlace(BuildingKind(arguments[0]), arguments[1],
      arguments[2]))
  discard result.addFunction("canPlace", 3, canPlaceProc, 20)

  ## Static tables, exposed as calls rather than documented constants, so a
  ## balance change is one edit to `content` and old scripts keep working.
  template unitStat(statName: string, field: untyped) =
    let callback: HostProc = proc(arguments: openArray[int32]): int32 =
      if arguments[0] < 0 or arguments[0] > int32(UnitKind.high.ord): 0
      else: UnitTable[playerId][UnitKind(arguments[0])].field
    discard result.addFunction(statName, 1, callback, 2)

  template buildingStat(statName: string, field: untyped) =
    let callback: HostProc = proc(arguments: openArray[int32]): int32 =
      if arguments[0] < 0 or arguments[0] > int32(BuildingKind.high.ord): 0
      else: BuildingTable[BuildingKind(arguments[0])].field
    discard result.addFunction(statName, 1, callback, 2)

  unitStat("unitCostGold", gold)
  unitStat("unitCostWood", wood)
  unitStat("unitFood", food)
  unitStat("unitTrainTicks", trainTicks)
  unitStat("unitRange", rangeTiles)
  unitStat("unitHp", hp)
  buildingStat("buildCostGold", gold)
  buildingStat("buildCostWood", wood)
  buildingStat("buildTicks", buildTicks)
  let buildWidthProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if arguments[0] < 0 or arguments[0] > int32(BuildingKind.high.ord):
      return 0
    BuildingTable[BuildingKind(arguments[0])].footprint.width
  discard result.addFunction("buildWidth", 1, buildWidthProc, 2)
  let buildDepthProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if arguments[0] < 0 or arguments[0] > int32(BuildingKind.high.ord):
      return 0
    BuildingTable[BuildingKind(arguments[0])].footprint.depth
  discard result.addFunction("buildDepth", 1, buildDepthProc, 2)
  let buildFootprintProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if arguments[0] < 0 or arguments[0] > int32(BuildingKind.high.ord):
      return 0
    let size = BuildingTable[BuildingKind(arguments[0])].footprint
    max(size.width, size.depth)
  discard result.addFunction("buildFootprint", 1, buildFootprintProc, 2)
  buildingStat("buildFood", foodProvided)

  let canBuildProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if arguments[0] < 0 or arguments[0] > int32(BuildableHigh.ord):
      return 0
    int32(game.canBuild(playerId, BuildingKind(arguments[0])))
  discard result.addFunction("canBuild", 1, canBuildProc, 8)

  let canTrainProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if arguments[1] < 0 or arguments[1] > int32(UnitKind.high.ord):
      return 0
    if game.buildingOwner(arguments[0]) != playerId:
      return 0
    int32(game.canTrain(arguments[0], UnitKind(arguments[1])))
  discard result.addFunction("canTrain", 2, canTrainProc, 8)

  ## Commands. One per replay action kind, one per validator, each returning
  ## one on acceptance and zero on refusal, and each refusing outright if the
  ## named entity is not this player's.
  let moveUnitProc: NumericHostProc = proc(
      arguments: openArray[Value]
  ): Value =
    let (x, y, offset) = splitTilePoint(fixedVec2(
      arguments[1].asFixed, arguments[2].asFixed))
    int32(activeGame.applyMove(playerId, arguments[0].asInt, x, y, offset))
  discard result.addFunction("moveUnit", 3, moveUnitProc, 400)

  let attackMoveProc: NumericHostProc = proc(
      arguments: openArray[Value]
  ): Value =
    let (x, y, offset) = splitTilePoint(fixedVec2(
      arguments[1].asFixed, arguments[2].asFixed))
    int32(activeGame.applyAttackMove(playerId, arguments[0].asInt, x, y, offset))
  discard result.addFunction("attackMove", 3, attackMoveProc, 400)

  let attackUnitProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(activeGame.applyAttack(playerId, arguments[0], arguments[1]))
  discard result.addFunction("attackUnit", 2, attackUnitProc, 120)

  let harvestProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(activeGame.applyHarvest(playerId, arguments[0], arguments[1],
      arguments[2]))
  discard result.addFunction("harvest", 3, harvestProc, 60)

  let buildProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(activeGame.applyBuild(playerId, arguments[0], arguments[1],
      arguments[2], arguments[3]))
  discard result.addFunction("build", 4, buildProc, 300)

  let trainProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(activeGame.applyTrain(playerId, arguments[0], arguments[1]))
  discard result.addFunction("train", 2, trainProc, 60)

  let setRallyProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(activeGame.applySetRally(playerId, arguments[0], arguments[1],
      arguments[2]))
  discard result.addFunction("setRally", 3, setRallyProc, 20)

  let cancelProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(activeGame.applyCancel(playerId, arguments[0]))
  discard result.addFunction("cancel", 1, cancelProc, 40)

  let orderFailedProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reads the failure flag without changing the recorded world state.
    let index = game.unitIndex(arguments[0])
    if index < 0:
      return 0
    let unit = game.units[index]
    if unit.owner != playerId:
      return 0
    int32(unit.orderFailed)
  discard result.addFunction("orderFailed", 1, orderFailedProc, 4)

## Lifecycle

proc loadBots*(
  game: Game, sources: array[PlayerCount, string]
) =
  ## Compiles one script per player and gives each its own runtime.
  let limits = overlordLimits()
  let schema = buildOverlordHost(0)
  for inbox in game.inboxes.mitems:
    inbox = newMailbox()
  var bound = false
  for player in 0'i32 ..< PlayerCount:
    when not defined(coworld):
      if sources[player].len == 0:
        continue
    let source = sources[player]
    let program =
      when defined(coworld):
        compilePlayer(source, schema, limits, int(player))
      else:
        compile(source, schema, limits)
    game.brains[player] = OverlordVm(
      runtime: initRuntime(program, buildOverlordHost(player), limits),
      ready: true,
    )
    if not bound:
      bindOverlordData(program)
      bound = true
    when defined(coworld):
      game.brains[player].output = playerPrinter(int(player))

proc runDecision(game: Game, player: int32) =
  ## Runs one player's script for one decision.
  if game.brains[player] == nil or
      not game.brains[player].ready or
      game.brains[player].failed:
    return
  if game.world.players[player].defeated:
    return
  buildSnapshot(game.world, player)
  activePlayer = player

  var home = tile2(GridSide div 2, GridSide div 2)
  for structure in game.world.buildings:
    if structure.owner == player and structure.kind == TownHallBuilding:
      home = structure.origin
      break

  try:
    game.brains[player].runtime.restart()
    let
      economy = addr game.world.players[player]
      ids = overlordDataIds
    game.brains[player].runtime.setData(ids[DataSelfPlayer], player)
    game.brains[player].runtime.setData(ids[DataEnemyPlayer], 1 - player)
    game.brains[player].runtime.setData(ids[DataWorldTick], game.world.tick)
    game.brains[player].runtime.setData(ids[DataGold], economy.gold)
    game.brains[player].runtime.setData(ids[DataWood], economy.wood)
    game.brains[player].runtime.setData(ids[DataFoodUsed], economy.foodUsed)
    game.brains[player].runtime.setData(ids[DataFoodCap], economy.foodCap)
    game.brains[player].runtime.setData(ids[DataObsCount], int32(snapshot.len))
    game.brains[player].runtime.setData(ids[DataOwnUnits], ownUnitCount)
    game.brains[player].runtime.setData(
      ids[DataOwnBuildings],
      ownBuildingCount
    )
    game.brains[player].runtime.setData(ids[DataHomeX], int32(home.x))
    game.brains[player].runtime.setData(ids[DataHomeY], int32(home.y))
    game.brains[player].runtime.setData(ids[DataMapSize], GridSide)
    game.brains[player].runtime.setData(
      ids[DataDecisionPeriod],
      DecisionTicks
    )
    discard game.brains[player].runtime.run(game.brains[player].output)
    inc game.brains[player].decisions
  except BasicError as error:
    game.brains[player].failed = true
    game.brains[player].lastError = error.msg
    when defined(coworld):
      playerError(int(player), error.msg)
    else:
      echo "player ", player, " BASIC error: ", error.msg
  game.brains[player].lastWork = game.brains[player].runtime.workUsed
  game.brains[player].lastInstructions =
    game.brains[player].runtime.instructionsUsed
  game.metrics.decision(
    int(player), game.world.tick, game.brains[player].lastInstructions,
    overlordLimits().maxInstructions
  )

proc runBotDecisions*(game: Game) {.measure.} =
  ## Runs every player's script for this decision tick.
  ##
  ## The starting player alternates, so neither side permanently acts first
  ## and gets to react to a world the other has not yet touched.
  activeGame = game
  let first = (game.world.tick div DecisionTicks) mod PlayerCount
  for offset in 0'i32 ..< PlayerCount:
    game.runDecision((first + offset) mod PlayerCount)
  activeGame = nil
