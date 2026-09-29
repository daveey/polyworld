## Heartleaf simulation: determinism, dinner scoring to the exact point,
## command validation, the 17:59 door crush, and a whole bot-driven week.

import
  std/strformat,
  fixxy,
  polyworld/[rngs],
  ../examples/heartleaf/content,
  ../examples/heartleaf/maps,
  ../examples/heartleaf/sim,
  ../examples/heartleaf/bots

let gameMap = generateMap(DefaultSeed)
gameMap.validateMap()

proc gatherAndParty(w: World) =
  ## A deterministic scripted decision: gather the nearest stocked garden,
  ## and from 16:30 walk into Ivan's house.
  for slot in 0'i32 ..< int32(VillagerCount):
    let v = w.villagers[slot]
    if w.minuteOfDay >= 16 * 60 + 30 and not w.dinnerDone:
      if v.inHouse < 0 and v.order != EnterOrder:
        discard w.applyEnterHouse(slot, 0)
      continue
    if v.order != NoOrder or v.inHouse >= 0:
      continue
    var
      best = -1'i32
      bestDist = int32.high
    for garden in 0'i32 ..< int32(GardenCount):
      if w.gardens[garden] < 0:
        continue
      let dist = chebyshev(v.tile, w.map.gardenTiles[garden])
      if dist < bestDist:
        bestDist = dist
        best = garden
    if best >= 0:
      discard w.applyGather(slot, best)

echo "Testing determinism: two identical games, one hash stream"
block twinWorlds:
  let
    first = newGame(gameMap, 2)
    second = newGame(gameMap, 2)
  while not first.world.over:
    first.world.tickWorld(gatherAndParty)
    second.world.tickWorld(gatherAndParty)
    if first.world.tick mod 100 == 0:
      doAssert first.stateHash() == second.stateHash(),
        &"twin worlds diverged at tick {first.world.tick}"
  doAssert second.world.over
  doAssert first.stateHash() == second.stateHash()

echo "Testing the dinner tally to the exact point"
block exactScoring:
  var w = newWorld(gameMap, 7)
  ## Hand-build the 18:00 moment: Ivan hosts Anton and Yura with five
  ## carrots on the table. Everyone else stays outside.
  w.villagers[0].inventory[0] = 5  # carrots
  w.villagers[0].inHouse = 0
  w.villagers[1].inHouse = 0
  w.villagers[2].inHouse = 0
  ## Yura has already tasted carrot this week.
  w.villagers[2].eaten[0] = true
  w.runDinnerTally()

  ## Host multiplier: five items times two visitors.
  doAssert w.lastTally[0].valid
  doAssert w.lastTally[0].visitors == 2
  doAssert w.lastTally[0].pantry == 5
  doAssert w.lastTally[0].hostPoints == 10

  ## Everyone takes a first bite, then two repeat bites finish the pantry.
  var eatingPoints = 0'i32
  for slot in 0 ..< VillagerCount:
    eatingPoints += w.villagers[slot].score
  eatingPoints -= w.lastTally[0].hostPoints
  doAssert eatingPoints == 9,
    &"expected 9 eating points, got {eatingPoints}"

  ## Hosting empties the pantry.
  doAssert w.villagers[0].carriedTotal() == 0
  ## Nobody outside a valid party scored.
  for slot in 3 ..< VillagerCount:
    doAssert w.villagers[slot].score == 0

block dinnerSelectionProbabilities:
  var
    pantry: array[VeggieKinds, int16]
    eaten: array[VeggieKinds, bool]
    newCarrots = 0
    repeatCarrots = 0
  pantry[0] = 1
  pantry[1] = 9
  for seed in 0'i32 ..< 5000:
    var rng = initRng(seed)
    if chooseBite(pantry, eaten, rng) == 0:
      inc newCarrots
  doAssert newCarrots in 2300 .. 2700
  for veggie in 0 ..< VeggieKinds:
    eaten[veggie] = true
  for seed in 0'i32 ..< 5000:
    var rng = initRng(seed)
    if chooseBite(pantry, eaten, rng) == 0:
      inc repeatCarrots
  doAssert repeatCarrots in 400 .. 600
  eaten[1] = false
  var rng = initRng(2026)
  for bite in 0 ..< 100:
    doAssert chooseBite(pantry, eaten, rng) == 1
  pantry[0] = 0
  pantry[1] = 0
  doAssert chooseBite(pantry, eaten, rng) == -1

block curfewBoundaryAndReset:
  let w = newWorld(gameMap, 2)
  for slot in 0 ..< VillagerCount:
    w.villagers[slot].inHouse = int32(slot)
  w.villagers[1].inHouse = 0
  w.villagers[2].inHouse = NoHouse
  w.villagers[2].inventory[0] = 3
  w.villagers[2].eaten[0] = true
  w.phase = EveningPhase
  w.dayTick = DayTicks - 2
  w.tickWorld(nil)
  doAssert w.phase == EveningPhase
  doAssert w.villagers[1].score == 0
  w.tickWorld(nil)
  doAssert w.phase == ScorePhase
  for slot in 0 ..< VillagerCount:
    let missed = slot in [1, 2]
    doAssert w.villagers[slot].curfewMissed == missed
    doAssert w.villagers[slot].score == (if missed: -3 else: 0)
    doAssert w.villagers[slot].inHouse == int32(slot)
  while w.phase == ScorePhase:
    w.tickWorld(nil)
  doAssert w.day == 2
  doAssert w.villagers[1].score == -3
  doAssert not w.villagers[1].curfewMissed
  doAssert w.villagers[2].inventory[0] == 3 and w.villagers[2].eaten[0]

block finalNightCurfew:
  let w = newWorld(gameMap, 1)
  w.phase = EveningPhase
  w.dayTick = DayTicks - 1
  while not w.over:
    w.tickWorld(nil)
  for v in w.villagers:
    doAssert v.score == -3 and v.curfewMissed

block aloneScoresNothing:
  var w = newWorld(gameMap, 7)
  w.villagers[0].inventory[0] = 9
  w.villagers[0].inHouse = 0
  w.runDinnerTally()
  doAssert not w.lastTally[0].valid
  doAssert w.villagers[0].score == 0
  doAssert w.villagers[0].carriedTotal() == 9,
    "an invalid party should not clear the pantry"

block visitorsWithoutTheHostScoreNothing:
  var w = newWorld(gameMap, 7)
  w.villagers[1].inHouse = 0
  w.villagers[2].inHouse = 0
  w.runDinnerTally()
  doAssert not w.lastTally[0].valid
  doAssert w.villagers[1].score == 0 and w.villagers[2].score == 0

echo "Testing command validation"
block inviteRules:
  var w = newWorld(gameMap, 7)
  ## Villagers start on their own doorsteps, a ring apart.
  doAssert not w.applyInvite(0, 0), "self-invitation was accepted"
  doAssert not w.applyInvite(0, 1), "a cross-village shout was accepted"
  ## Walk them together: teleport via the door of one house.
  doAssert w.applyEnterHouse(0, 0)
  doAssert not w.applyInvite(0, 1), "an indoor host invited someone"
  doAssert w.applyExitHouse(0)
  ## Stand villager one next to villager zero by entering and leaving the
  ## same house, which parks both on the same doorstep.
  doAssert w.applyEnterHouse(1, 0) # walks; not there yet, so still refused
  doAssert not w.applyInvite(0, 1)
  ## Accepting an invitation that was never made is refused.
  doAssert not w.applyAccept(1, 0)
  ## And declining one too.
  doAssert not w.applyDecline(1, 0)

block gatherRace:
  var w = newWorld(gameMap, 7)
  ## Two villagers race for one plot. Whoever arrives first empties it and
  ## the loser's order fails.
  let garden = 0'i32
  doAssert w.applyGather(0, garden)
  doAssert w.applyGather(1, garden)
  var guard = 0
  while (w.villagers[0].order == GatherOrder or
      w.villagers[1].order == GatherOrder) and guard < DayTicks:
    w.tickWorld(nil)
    inc guard
  let taken = w.villagers[0].carriedTotal() + w.villagers[1].carriedTotal()
  doAssert taken == 1, &"one plot yielded {taken} items"
  doAssert w.villagers[0].orderFailed or w.villagers[1].orderFailed,
    "the losing gatherer was never told"
  doAssert w.gardens[garden] < 0, "the plot still holds food"

block conversationsAreVoluntaryAndBounded:
  let w = newWorld(gameMap, 7)
  for slot in 0 .. 4:
    let v = w.villagers[slot]
    v.tile = tile2(62 + int32(slot mod 2) * 2, 84 + int32(slot div 2))
    v.body.pos = fixedVec2(fixed(int32(v.tile.x)) + 0.5'fx,
      fixed(int32(v.tile.y)) + 0.5'fx)
    doAssert w.positionOpen(v.body.pos)
  w.villagers[0].body.facing = FixedPi
  doAssert not w.applyTalk(0, 0)
  doAssert not w.applyTalk(0, -1)
  doAssert w.applyTalk(0, 1)
  doAssert w.villagers[1].order == NoOrder,
    "talking commandeered the other villager"
  doAssert w.applyTalk(1, 0)
  let before = w.villagers[0].body.pos
  w.tickWorld(nil)
  doAssert abs(w.villagers[0].body.facing) < FixedPi
  doAssert w.villagers[0].body.pos == before, "a pair moved unnecessarily"
  doAssert w.applyTalk(2, 0)
  doAssert w.applyTalk(3, 0)
  doAssert w.socialGroup(0).card == 4
  doAssert not w.applyTalk(4, 0), "a fifth gnome joined the conversation"
  for tick in 0 ..< 5 * TickRate:
    w.tickWorld(nil)
  for slot in 0 .. 3:
    let v = w.villagers[slot]
    doAssert v.talkCircle and v.order == TalkOrder
    doAssert length(v.body.pos - v.talkPosition) <= 0.4'fx,
      "a conversation member did not reach their circle position"
    doAssert abs(length(v.body.pos - v.talkCenter) - 1.5'fx) <= 0.4'fx,
      "the group did not stand around a shared center"
  for v in w.villagers:
    doAssert not v.hostingTonight and v.score == 0,
      "socializing changed dinner commitments or points"
  doAssert w.applyGather(0, 0)
  w.tickWorld(nil)
  doAssert w.villagers[1].order == NoOrder,
    "the listener kept talking after their partner left to harvest"
  doAssert not w.applyTalk(4, 0), "a busy gatherer was available to chat"

block threeSpeakersLeaveTheLine:
  let w = newWorld(gameMap, 7)
  for slot in 0 .. 2:
    let v = w.villagers[slot]
    v.tile = tile2(62 + int32(slot) * 2, 84)
    v.body.pos = fixedVec2(fixed(int32(v.tile.x)) + 0.5'fx, 84.5'fx)
  doAssert w.applyTalk(0, 1)
  doAssert w.applyTalk(1, 0)
  doAssert w.applyTalk(2, 1)
  let center = w.villagers[0].talkCenter
  for tick in 0 ..< 5 * TickRate:
    w.tickWorld(nil)
  let
    a = w.villagers[1].body.pos - w.villagers[0].body.pos
    b = w.villagers[2].body.pos - w.villagers[0].body.pos
  doAssert abs(a.x * b.y - a.y * b.x) > 1'fx,
    "three speakers remained in a line"
  for slot in 0 .. 2:
    let v = w.villagers[slot]
    doAssert v.order == TalkOrder and v.talkCenter == center,
      "the conversation center drifted while the group settled"
    doAssert length(v.body.pos - v.talkPosition) <= 0.4'fx

block scriptedConversationEnds:
  let game = newGame(gameMap, 7)
  var sources = newSeq[string](VillagerCount)
  for slot in 0 ..< VillagerCount:
    sources[slot] = if slot < 2: readFile("examples/heartleaf/players/base.bas")
      else: "r = 0"
    if slot >= 2:
      game.world.villagers[slot].inHouse = int32(slot)
  loadBots(game, sources)
  for garden in 0 ..< GardenCount:
    game.world.gardens[garden] = EmptyGarden
  for slot in 0 .. 1:
    let v = game.world.villagers[slot]
    v.tile = tile2(62 + int32(slot) * 2, 84)
    v.body.pos = fixedVec2(fixed(int32(v.tile.x)) + 0.5'fx, 84.5'fx)
  var answered, departed, walkedAway = false
  var departureOrigin: Tile2
  for tick in 0 ..< 30 * TickRate:
    game.world.tickWorld(proc(w: World) = runBotDecisions(game))
    let mutual = game.world.villagers[0].order == TalkOrder and
      game.world.villagers[1].order == TalkOrder
    if mutual:
      answered = true
    elif answered:
      if not departed:
        departureOrigin = game.world.villagers[0].tile
      departed = true
    if departed and chebyshev(game.world.villagers[0].tile, departureOrigin) >= 7:
      walkedAway = true
    if departed:
      doAssert not mutual, "the same pair immediately restarted its conversation"
  doAssert answered, "nearby scripted gnomes never answered each other"
  doAssert departed, "a scripted conversation never ended"
  doAssert walkedAway, "the departing villager stayed beside the same group"

block isolatedVillagerSeeksDistantCompany:
  let game = newGame(gameMap, 7)
  var sources = newSeq[string](VillagerCount)
  for slot in 0 ..< VillagerCount:
    sources[slot] = if slot == 0: readFile("examples/heartleaf/players/base.bas")
      else: "r = 0"
    if slot >= 2:
      game.world.villagers[slot].inHouse = int32(slot)
  loadBots(game, sources)
  for garden in 0 ..< GardenCount:
    game.world.gardens[garden] = EmptyGarden
  for slot in 0 .. 1:
    let v = game.world.villagers[slot]
    v.tile = gameMap.houses[if slot == 0: 5 else: 2].door
    v.body.pos = fixedVec2(fixed(v.tile.x.int32) + 0.5'fx,
      fixed(v.tile.y.int32) + 0.5'fx)
    doAssert game.world.positionOpen(v.body.pos)
  var soughtCompany = false
  for tick in 0 ..< 40 * TickRate:
    game.world.tickWorld(proc(w: World) = runBotDecisions(game))
    let v = game.world.villagers[0]
    if v.order == MoveOrder and
        chebyshev(v.goal, game.world.villagers[1].tile) <= 3:
      soughtCompany = true
  doAssert not game.brains[0].failed
  doAssert soughtCompany, "an isolated villager never sought distant company"

block competitiveHarvesting:
  let w = newWorld(gameMap, 7)
  for garden in 0 ..< GardenCount:
    w.gardens[garden] = EmptyGarden
  w.map.gardenTiles[0] = tile2(64, 64)
  w.map.gardenTiles[1] = tile2(64, 80)
  w.gardens[0] = 0
  w.gardens[1] = 1
  let
    me = w.villagers[0]
    rival = w.villagers[1]
  me.tile = tile2(64, 58)
  rival.tile = tile2(64, 62)
  rival.order = GatherOrder
  rival.orderTarget = 0
  doAssert w.gardenOutpaced(0, 0)
  doAssert w.nearestWinnableGarden(0) == 1,
    "a clearly losing gatherer ignored an uncontested crop"
  me.tile = tile2(64, 63)
  doAssert not w.gardenOutpaced(0, 0)
  doAssert w.nearestWinnableGarden(0) == 0,
    "the closer gatherer yielded a winning race"
  me.tile = rival.tile
  doAssert w.nearestWinnableGarden(0) == 0, "a tied race was abandoned"
  me.tile = tile2(64, 60)
  doAssert not w.gardenOutpaced(0, 0), "a close race was abandoned"
  me.tile = tile2(64, 58)
  rival.order = MoveOrder
  doAssert w.nearestWinnableGarden(0) == 0,
    "an unrelated passerby deterred harvesting"
  rival.order = GatherOrder
  rival.orderTarget = 1
  doAssert w.nearestWinnableGarden(0) == 0
  rival.orderTarget = 0
  rival.inHouse = 1
  doAssert w.nearestWinnableGarden(0) == 0
  rival.inHouse = NoHouse
  w.gardens[1] = EmptyGarden
  doAssert w.nearestWinnableGarden(0) == -1,
    "a losing gatherer chased the last contested crop"
  rival.order = NoOrder
  doAssert w.nearestWinnableGarden(0) == 0,
    "an abandoned crop did not become an opportunity again"
  w.gardens[0] = EmptyGarden
  doAssert w.nearestWinnableGarden(0) == -1

block botAbandonsClearLoss:
  let game = newGame(gameMap, 7)
  var sources = newSeq[string](VillagerCount)
  for source in sources.mitems:
    source = "r = 0"
  sources[0] = readFile("examples/heartleaf/players/base.bas")
  loadBots(game, sources)
  let w = game.world
  for garden in 0 ..< GardenCount:
    w.gardens[garden] = EmptyGarden
  w.map.gardenTiles[0] = tile2(64, 64)
  w.gardens[0] = 0
  w.villagers[0].tile = tile2(64, 56)
  w.villagers[1].tile = tile2(64, 62)
  for slot in 0 .. 1:
    w.villagers[slot].order = GatherOrder
    w.villagers[slot].orderTarget = 0
  runBotDecisions(game)
  doAssert not game.brains[0].failed
  doAssert w.villagers[0].order == NoOrder,
    "the script kept following a clearly losing gather order"
  w.villagers[1].order = NoOrder
  w.tick += DecisionTicks
  runBotDecisions(game)
  doAssert w.villagers[0].order == GatherOrder,
    "the script failed to resume harvesting when its rival gave up"

block freeTimeStartsWithARest:
  let game = newGame(gameMap, 7)
  var sources = newSeq[string](VillagerCount)
  for source in sources.mitems:
    source = "r = 0"
  sources[0] = readFile("examples/heartleaf/players/base.bas")
  loadBots(game, sources)
  for garden in 0 ..< GardenCount:
    game.world.gardens[garden] = EmptyGarden
  for slot in 1 ..< VillagerCount:
    game.world.villagers[slot].inHouse = int32(slot)
  runBotDecisions(game)
  doAssert game.world.villagers[0].order == NoOrder,
    "the bot walked away immediately when harvesting ended"
  for tick in 1 ..< 5 * TickRate:
    game.world.tickWorld(proc(w: World) = runBotDecisions(game))
    doAssert game.world.villagers[0].order == NoOrder,
      "the bot did not finish its initial rest"
  doAssert not game.brains[0].failed

block houseRules:
  var w = newWorld(gameMap, 7)
  doAssert not w.applyExitHouse(0), "exited a house while outdoors"
  doAssert w.applyEnterHouse(0, 0), "the owner could not head home"
  doAssert w.villagers[0].inHouse == 0,
    "standing on the doorstep should enter immediately"
  doAssert not w.applyEnterHouse(0, 1), "entered a house from inside one"
  doAssert w.applyExitHouse(0)
  doAssert w.villagers[0].inHouse == -1

echo "Testing the door crush: nine villagers, one doorstep, one bell"
block doorCrush:
  var w = newWorld(gameMap, 7)
  ## Everyone converges on Ivan's house from their own doorstep with a
  ## quarter of the day to spare, arriving in a shoving crowd.
  for slot in 0'i32 ..< int32(VillagerCount):
    doAssert w.applyEnterHouse(slot, 0)
  while w.phase == DaytimePhase:
    w.tickWorld(nil)
  doAssert w.lastTally[0].valid, "the crowd never made it inside"
  doAssert w.lastTally[0].visitors == int32(VillagerCount) - 1,
    &"only {w.lastTally[0].visitors} of eight visitors got in"

echo "Testing a whole bot-driven week"
for seed in [1'i32, 7, 1988, DefaultSeed]:
  let game = newGame(generateMap(seed), int32(DefaultDayCount))
  var sources: seq[string]
  let source = readFile("examples/heartleaf/players/base.bas")
  for slot in 0 ..< VillagerCount:
    sources.add source
  loadBots(game, sources)
  var
    lastTalkTick: array[VillagerCount, int32]
    lastTalkPosition: array[VillagerCount, Tile2]
  proc decide(w: World) =
    var
      orders: array[VillagerCount, OrderKind]
      goals, positions: array[VillagerCount, Tile2]
      outdoors: array[VillagerCount, bool]
    for slot, v in w.villagers:
      orders[slot] = v.order
      goals[slot] = v.goal
      positions[slot] = v.tile
      outdoors[slot] = v.inHouse < 0
      if v.order == TalkOrder:
        lastTalkTick[slot] = w.tick
        lastTalkPosition[slot] = v.tile
    runBotDecisions(game)
    for slot, v in w.villagers:
      if v.order == MoveOrder and
          (orders[slot] != MoveOrder or goals[slot] != v.goal):
        var visiting = false
        for other in w.villagers:
          if other.slot != v.slot and outdoors[other.slot] and
              (orders[other.slot] in {NoOrder, MoveOrder, TalkOrder} or
                other.order in {NoOrder, MoveOrder, TalkOrder}) and
              chebyshev(positions[other.slot], v.goal) <= 3:
            visiting = true
        doAssert chebyshev(v.tile, v.goal) <= 6 or
            (visiting and chebyshev(v.tile, v.goal) <= 67) or
            (lastTalkTick[slot] > 0 and w.tick - lastTalkTick[slot] <= 20 * TickRate and
              chebyshev(lastTalkPosition[slot], v.goal) <= 10),
          &"seed {seed}: villager {slot} started a long aimless walk at {w.tick}, {v.tile} to {v.goal}, last talk {lastTalkTick[slot]} at {lastTalkPosition[slot]}, peers {positions}, orders {orders}"
  var samples, outsidePlaza, crowded, restingPairs: int
  while not game.world.over:
    let previousPhase = game.world.phase
    game.world.tickWorld(decide)
    let w = game.world
    if previousPhase == DaytimePhase and w.phase == EveningPhase:
      for veggie in w.gardens:
        doAssert veggie == EmptyGarden,
          &"seed {seed}: competitive harvesting left crops on day {w.day}"
    if w.phase == DaytimePhase and w.tick mod (2 * TickRate) == 0 and
        w.minuteOfDay >= 12 * 60 and w.minuteOfDay < 16 * 60:
      inc samples
      for v in w.villagers:
        if chebyshev(v.tile, tile2(GridSide div 2, GridSide div 2)) > 7:
          inc outsidePlaza
        var nearby = 0
        for other in w.villagers:
          if other.slot != v.slot and other.inHouse < 0 and
              chebyshev(v.tile, other.tile) <= 4:
            inc nearby
        if nearby >= 4:
          inc crowded
        if nearby >= 1 and v.order == TalkOrder:
          inc restingPairs
    if game.world.phase == ScorePhase and previousPhase != ScorePhase:
      var validParty = false
      for report in w.lastTally:
        validParty = validParty or report.valid
      doAssert validParty, &"seed {seed} had no dinner on day {w.day}"
      for v in game.world.villagers:
        doAssert not v.curfewMissed,
          &"seed {seed}: {VillagerNames[v.slot]} missed curfew on day {game.world.day}"
  doAssert samples > 0
  doAssert outsidePlaza > samples * VillagerCount div 2,
    &"seed {seed}: villagers spent most of the afternoon in the plaza"
  doAssert crowded < samples * VillagerCount div 10,
    &"seed {seed}: villagers spent too much time in groups of five or more: {crowded}/{samples * VillagerCount}"
  doAssert restingPairs > 0,
    &"seed {seed}: villagers never joined a conversation"
  for slot in 0 ..< VillagerCount:
    doAssert not game.brains[slot].failed,
      &"villager {slot} script failed: {game.brains[slot].lastError}"
    doAssert game.world.villagers[slot].score > 0,
      &"{VillagerNames[slot]} ended the week with nothing"
  ## Every night at least one party must have been valid; check the last.
  var anyParty = false
  for report in game.world.lastTally:
    if report.valid:
      anyParty = true
  doAssert anyParty, "the final night had no valid party at all"

echo "test_hlf_sim: all checks passed"

echo "Testing Heartleaf bot decimals reach precise same-cell destinations"
block:
  let
    game = newGame(gameMap, 1)
    villager = game.world.villagers[0]
    origin = villager.body.pos
  var sources = newSeq[string](VillagerCount)
  sources[0] = "accepted = walkTo(myX + 0.25, myY - 0.25)\n"
  loadBots(game, sources)
  runBotDecisions(game)
  doAssert not game.brains[0].failed
  doAssert villager.goalOffset == fixedVec2(0.25'fx, -0.25'fx)
  for tick in 0 ..< 60:
    game.world.tickWorld(proc(w: World) = discard)
  doAssert villager.order == NoOrder
  doAssert length(villager.body.pos - origin -
    fixedVec2(0.25'fx, -0.25'fx)) <= fixed(1, 1000)
