## Heartleaf villager scripting: the whole surface a BASIC program has on
## the simulation.
##
## One VM per villager. Every command acts as the calling villager, so the
## captured `slot` in the host closures is the entire authorisation
## boundary. There are only nine villagers and twenty-seven gardens, so
## observations are per-index accessor calls rather than a snapshot list;
## nothing a villager can see changes while its decision runs, because
## commands only queue orders.

import
  polyworld/neural,
  bassy,
  polyworld/[bodies, profiles],
  content,
  sim

type
  VillagerDataSlot = enum
    DataSelfSlot,
    DataWorldTick,
    DataDay,
    DataDayCount,
    DataMinuteOfDay,
    DataDinnerDone,
    DataMyX,
    DataMyY,
    DataInHouse,
    DataCarried,
    DataHosting,
    DataAcceptedHost,
    DataOrderKind,
    DataOrderTarget,
    DataScore,
    DataVillagerTotal,
    DataGardenTotal,
    DataDecisionPeriod

const
  VillagerDataNames: array[VillagerDataSlot, string] = [
    "selfSlot",
    "worldTick",
    "day",
    "dayCount",
    "minuteOfDay",
    "dinnerDone",
    "myX",
    "myY",
    "inHouse",
    "carried",
    "hosting",
    "acceptedHost",
    "orderKind",
    "orderTarget",
    "score",
    "villagerTotal",
    "gardenTotal",
    "decisionPeriod"
  ]

const HarvestLeadTiles = 3'i32
  ## A smaller distance difference is still a competitive race.

var
  activeGame: Game
  villagerDataIds: array[VillagerDataSlot, int32]

proc bindVillagerData(program: Program) =
  ## Resolves host data slots once so think ticks do not allocate names.
  for slot, name in VillagerDataNames:
    villagerDataIds[slot] = program.hostDataIndex(name)
    doAssert villagerDataIds[slot] >= 0, "missing host data " & name

template game(): World = activeGame.world

## Host surface

proc villagerLimits*(): Limits =
  ## Budgets one decision.
  ##
  ## Sized so nine villagers fit inside one simulation tick with room to
  ## spare. The ceiling is deliberately reachable: a scan of every garden
  ## nested inside a scan of every garden will exceed it, which is the
  ## pressure that pushes authors onto `nearestStockedGarden`.
  result = defaultLimits()
  result.maxSourceBytes = 256 * 1024
  result.maxCodeInstructions = 100_000
  result.maxArrays = 16
  result.maxArrayElements = 4_096
  result.maxGlobals = 512
  result.maxHostData = 32
  result.maxHostFunctions = 64
  result.maxRoutines = 64
  result.maxParameters = 8
  result.maxRegisters = 256
  result.maxSyntaxDepth = 32
  result.maxCallDepth = 16
  result.maxMemoryBytes = 1024 * 1024
  result.maxInstructions = 100_000
  result.maxWorkUnits = 150_000
  result.maxPrintBytes = 8 * 1024
  result.maxPrintEvents = 128

proc clampVeggie(value: int32): int32 =
  ## Folds any argument into the vegetable range so a bad index reads as
  ## zeroes instead of crashing the host.
  if value < 0 or value >= VeggieKinds: -1 else: value

proc gardenOutpaced*(w: World, slot, garden: int32): bool =
  ## Estimates losing races from grid distance and an opponent's gather order.
  if garden < 0 or garden >= int32(GardenCount) or w.gardens[garden] < 0:
    return false
  let
    goal = w.map.gardenTiles[garden]
    distance = chebyshev(w.villagers[slot].tile, goal)
  for other in w.villagers:
    if other.slot != slot and other.inHouse < 0 and
        other.order == GatherOrder and other.orderTarget == garden and
        chebyshev(other.tile, goal) + HarvestLeadTiles <= distance:
      return true

proc nearestWinnableGarden*(w: World, slot: int32): int32 =
  ## Finds the nearest stocked plot without a clearly leading competitor.
  result = -1
  var best = int32.high
  for garden in 0'i32 ..< int32(GardenCount):
    if w.gardens[garden] < 0:
      continue
    let distance = chebyshev(w.villagers[slot].tile, w.map.gardenTiles[garden])
    if distance < best and not w.gardenOutpaced(slot, garden):
      best = distance
      result = garden

proc buildVillagerHost*(slot: int32): Host =
  ## Builds the complete world-query and command interface for one villager.
  ##
  ## The same builder makes both the compile-time schema and each villager's
  ## live instance, because `initRuntime` validates every binding's arity
  ## and work cost against what the program was compiled with.
  result = initHost()
  result.addNeuralFunctions()
  for name in VillagerDataNames:
    discard result.addData(name)

  template me(): Villager = game.villagers[slot]

  ## Own bag and palate.
  let invOfProc: HostProc = proc(arguments: openArray[int32]): int32 =
    let veggie = clampVeggie(arguments[0])
    if veggie < 0: 0 else: int32(me.inventory[veggie])
  discard result.addFunction("invOf", 1, invOfProc, 3)

  let eatenOfProc: HostProc = proc(arguments: openArray[int32]): int32 =
    let veggie = clampVeggie(arguments[0])
    if veggie < 0: 0 else: int32(me.eaten[veggie])
  discard result.addFunction("eatenOf", 1, eatenOfProc, 3)

  ## Gardens. Positions are fixed; contents empty as the day is gathered.
  let gardenXProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if not validGarden(arguments[0]): -1
    else: int32(game.map.gardenTiles[arguments[0]].x)
  discard result.addFunction("gardenX", 1, gardenXProc, 3)

  let gardenYProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if not validGarden(arguments[0]): -1
    else: int32(game.map.gardenTiles[arguments[0]].y)
  discard result.addFunction("gardenY", 1, gardenYProc, 3)

  let gardenVeggieProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if not validGarden(arguments[0]): -1
    else: int32(game.gardens[arguments[0]])
  discard result.addFunction("gardenVeggie", 1, gardenVeggieProc, 3)

  let nearestStockedProc: HostProc = proc(
      arguments: openArray[int32]): int32 =
    ## The closest garden that still holds food, from where the caller
    ## stands. Ties go to the lowest garden id, so two villagers asking
    ## from the same tile always get the same answer.
    result = -1
    var best = int32.high
    for garden in 0'i32 ..< int32(GardenCount):
      if game.gardens[garden] < 0:
        continue
      let distance = chebyshev(me.tile, game.map.gardenTiles[garden])
      if distance < best:
        best = distance
        result = garden
  discard result.addFunction("nearestStockedGarden", 0, nearestStockedProc, 40)

  let nearestWinnableProc: HostProc = proc(
      arguments: openArray[int32]): int32 =
    game.nearestWinnableGarden(slot)
  discard result.addFunction("nearestWinnableGarden", 0, nearestWinnableProc, 400)

  let gardenOutpacedProc: HostProc = proc(
      arguments: openArray[int32]): int32 =
    int32(game.gardenOutpaced(slot, arguments[0]))
  discard result.addFunction("gardenOutpaced", 1, gardenOutpacedProc, 20)

  ## The other villagers. A villager inside a house reads as standing on
  ## that house's doorstep.
  let villagerXProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if not validSlot(arguments[0]): -1
    else: int32(game.villagers[arguments[0]].tile.x)
  discard result.addFunction("villagerX", 1, villagerXProc, 3)

  let villagerYProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if not validSlot(arguments[0]): -1
    else: int32(game.villagers[arguments[0]].tile.y)
  discard result.addFunction("villagerY", 1, villagerYProc, 3)

  let villagerInHouseProc: HostProc = proc(
      arguments: openArray[int32]): int32 =
    if not validSlot(arguments[0]): -1
    else: game.villagers[arguments[0]].inHouse
  discard result.addFunction("villagerInHouse", 1, villagerInHouseProc, 3)

  let villagerHostingProc: HostProc = proc(
      arguments: openArray[int32]): int32 =
    if not validSlot(arguments[0]): 0
    else: int32(game.villagers[arguments[0]].hostingTonight)
  discard result.addFunction("villagerHosting", 1, villagerHostingProc, 3)

  let villagerCarriedProc: HostProc = proc(
      arguments: openArray[int32]): int32 =
    if not validSlot(arguments[0]): 0
    else: game.villagers[arguments[0]].carriedTotal()
  discard result.addFunction("villagerCarried", 1, villagerCarriedProc, 6)

  let villagerScoreProc: HostProc = proc(
      arguments: openArray[int32]): int32 =
    if not validSlot(arguments[0]): 0
    else: game.villagers[arguments[0]].score
  discard result.addFunction("villagerScore", 1, villagerScoreProc, 3)

  let inviteFromProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if not validSlot(arguments[0]): 0
    else: int32(me.inviteFrom[arguments[0]])
  discard result.addFunction("inviteFrom", 1, inviteFromProc, 3)

  ## Houses.
  let doorXProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if not validSlot(arguments[0]): -1
    else: int32(game.doorOf(arguments[0]).x)
  discard result.addFunction("doorX", 1, doorXProc, 3)

  let doorYProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if not validSlot(arguments[0]): -1
    else: int32(game.doorOf(arguments[0]).y)
  discard result.addFunction("doorY", 1, doorYProc, 3)

  let occupantsProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if not validSlot(arguments[0]): 0
    else: game.occupants(arguments[0])
  discard result.addFunction("occupants", 1, occupantsProc, 6)

  let talkingToProc: HostProc = proc(arguments: openArray[int32]): int32 =
    let other = arguments[0]
    if not validSlot(other) or game.villagers[other].order != TalkOrder: -1
    else: game.villagers[other].orderTarget
  discard result.addFunction("talkingTo", 1, talkingToProc, 3)

  let availableProc: HostProc = proc(arguments: openArray[int32]): int32 =
    let other = arguments[0]
    int32(validSlot(other) and game.villagers[other].inHouse < 0 and
      game.villagers[other].order in {NoOrder, MoveOrder, TalkOrder})
  discard result.addFunction("socialAvailable", 1, availableProc, 3)

  let inConversationProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(validSlot(arguments[0]) and int(arguments[0]) in game.socialGroup(slot))
  discard result.addFunction("inMyConversation", 1, inConversationProc, 100)

  let sameConversationProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(validSlot(arguments[0]) and validSlot(arguments[1]) and
      int(arguments[1]) in game.socialGroup(arguments[0]))
  discard result.addFunction("sameConversation", 2, sameConversationProc, 100)

  let groupSizeProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if not validSlot(arguments[0]): 0
    else: int32(game.socialGroup(arguments[0]).card)
  discard result.addFunction("socialGroupSize", 1, groupSizeProc, 100)

  ## Geometry.
  let distToProc: HostProc = proc(arguments: openArray[int32]): int32 =
    max(abs(arguments[0] - int32(me.tile.x)),
      abs(arguments[1] - int32(me.tile.y)))
  discard result.addFunction("distTo", 2, distToProc, 2)

  let distanceProc: HostProc = proc(arguments: openArray[int32]): int32 =
    max(abs(arguments[0] - arguments[2]), abs(arguments[1] - arguments[3]))
  discard result.addFunction("distance", 4, distanceProc, 2)

  let tilePassableProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(game.terrainOpen(arguments[0], arguments[1]))
  discard result.addFunction("tilePassable", 2, tilePassableProc, 3)

  ## Commands. One per replay action kind, one per validator, each returning
  ## one on acceptance and zero on refusal.
  let walkToProc: NumericHostProc = proc(arguments: openArray[Value]): Value =
    let (x, y, offset) = splitTilePoint(fixedVec2(
      arguments[0].asFixed, arguments[1].asFixed))
    int32(activeGame.applyMove(slot, x, y, offset))
  discard result.addFunction("walkTo", 2, walkToProc, 400)

  let gatherProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(activeGame.applyGather(slot, arguments[0]))
  discard result.addFunction("gather", 1, gatherProc, 400)

  let talkProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(activeGame.applyTalk(slot, arguments[0]))
  discard result.addFunction("talk", 1, talkProc, 200)

  let inviteProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(activeGame.applyInvite(slot, arguments[0]))
  discard result.addFunction("invite", 1, inviteProc, 60)

  let acceptProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(activeGame.applyAccept(slot, arguments[0]))
  discard result.addFunction("accept", 1, acceptProc, 20)

  let declineProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(activeGame.applyDecline(slot, arguments[0]))
  discard result.addFunction("decline", 1, declineProc, 20)

  let enterHouseProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(activeGame.applyEnterHouse(slot, arguments[0]))
  discard result.addFunction("enterHouse", 1, enterHouseProc, 400)

  let exitHouseProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(activeGame.applyExitHouse(slot))
  discard result.addFunction("exitHouse", 0, exitHouseProc, 60)

  let cancelProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(activeGame.applyStop(slot))
  discard result.addFunction("cancel", 0, cancelProc, 20)

  let orderFailedProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reads and clears the flag, so one failure is reported exactly once.
    result = int32(me.orderFailed)
    me.orderFailed = false
  discard result.addFunction("orderFailed", 0, orderFailedProc, 4)

## Lifecycle

proc loadBots*(game: Game, sources: openArray[string]) =
  ## Compiles one script per villager and gives each its own runtime.
  let limits = villagerLimits()
  let schema = buildVillagerHost(0)
  var bound = false
  for slot in 0'i32 ..< int32(VillagerCount):
    if sources[slot].len == 0:
      continue
    let program = compile(sources[slot], schema, limits)
    game.brains[slot] = VillagerVm(
      runtime: initRuntime(program, buildVillagerHost(slot), limits),
      ready: true
    )
    if not bound:
      bindVillagerData(program)
      bound = true

proc runDecision(game: Game, slot: int32) =
  ## Runs one villager's script for one decision.
  if game.brains[slot] == nil or
      not game.brains[slot].ready or
      game.brains[slot].failed:
    return
  let v = game.world.villagers[slot]
  game.brains[slot].runtime.restart()
  try:
    let ids = villagerDataIds
    game.brains[slot].runtime.setData(ids[DataSelfSlot], slot)
    game.brains[slot].runtime.setData(ids[DataWorldTick], game.world.tick)
    game.brains[slot].runtime.setData(ids[DataDay], game.world.day)
    game.brains[slot].runtime.setData(ids[DataDayCount], game.world.dayCount)
    game.brains[slot].runtime.setData(
      ids[DataMinuteOfDay], game.world.minuteOfDay)
    game.brains[slot].runtime.setData(
      ids[DataDinnerDone], int32(game.world.dinnerDone))
    game.brains[slot].runtime.setData(ids[DataMyX], int32(v.tile.x))
    game.brains[slot].runtime.setData(ids[DataMyY], int32(v.tile.y))
    game.brains[slot].runtime.setData(ids[DataInHouse], v.inHouse)
    game.brains[slot].runtime.setData(ids[DataCarried], v.carriedTotal())
    game.brains[slot].runtime.setData(
      ids[DataHosting], int32(v.hostingTonight))
    game.brains[slot].runtime.setData(ids[DataAcceptedHost], v.acceptedHost)
    game.brains[slot].runtime.setData(
      ids[DataOrderKind], int32(v.order.ord))
    game.brains[slot].runtime.setData(ids[DataOrderTarget], v.orderTarget)
    game.brains[slot].runtime.setData(ids[DataScore], v.score)
    game.brains[slot].runtime.setData(
      ids[DataVillagerTotal], int32(VillagerCount))
    game.brains[slot].runtime.setData(
      ids[DataGardenTotal], int32(GardenCount))
    game.brains[slot].runtime.setData(
      ids[DataDecisionPeriod], DecisionTicks)
    discard game.brains[slot].runtime.run()
    inc game.brains[slot].decisions
  except BasicError as error:
    game.brains[slot].failed = true
    game.brains[slot].lastError = error.msg
    echo "villager ", slot, " BASIC error: ", error.msg
  game.brains[slot].lastWork = game.brains[slot].runtime.workUsed
  game.brains[slot].lastInstructions =
    game.brains[slot].runtime.instructionsUsed

proc runBotDecisions*(game: Game) {.measure.} =
  ## Runs every villager's script for this decision tick.
  ##
  ## The starting villager rotates, so nobody permanently acts first and
  ## snatches every contested garden.
  activeGame = game
  let first = (game.world.tick div DecisionTicks) mod int32(VillagerCount)
  for offset in 0'i32 ..< int32(VillagerCount):
    game.runDecision((first + offset) mod int32(VillagerCount))
  activeGame = nil
