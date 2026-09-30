import
  polyworld/tapes,
  ../examples/light_vs_dark/[bots, content, diplomacies, maps, replays, sim]

const
  FastDiplomacy = DiplomacySettings(warGraceSeconds: 1, offerSeconds: 4)
  BasePolicy = staticRead("../examples/light_vs_dark/players/base.bas")

proc step(game: Game, ticks = 1) =
  ## Runs real simulation decisions and checks every loaded bot.
  proc decide(w: World) =
    ## Supplies the normal BASIC decision loop.
    game.runBotDecisions()
  for i in 0 ..< ticks:
    game.world.tickWorld(decide)
    for brain in game.brains:
      if brain != nil:
        doAssert not brain.failed, brain.lastError

proc accept(game: Game, sender, recipient: int32) =
  ## Accepts the exact current offer through the recording wrapper.
  let pair = game.world.diplomacy.relation(sender, recipient)
  doAssert pair.offer != NoOffer
  doAssert game.applyDiplomacy(recipient, sender, AcceptOffer, pair.offerId)

proc defeat(game: Game, player: int32) =
  ## Removes a player through the existing defeat condition.
  for unit in game.world.units:
    if unit.owner == player:
      game.world.damageEntity(unit.id, unit.hp)
  for building in game.world.buildings:
    if building.owner == player:
      game.world.damageEntity(building.id, building.hp)

echo "Testing neutral starts, bilateral deadlines, and offer validation"
block transitions:
  var diplomacy = initDiplomacy(4, FastDiplomacy)
  doAssert diplomacy.pairs.len == 6
  doAssert diplomacy.pairIndex(0, 3) == diplomacy.pairIndex(3, 0)
  doAssert diplomacy.relation(0, 1).state == Neutral
  doAssert not diplomacy.apply(0, 0, 1, DeclareWar)
  doAssert not diplomacy.apply(0, 4, 1, DeclareWar)
  doAssert diplomacy.apply(0, 1, 1, DeclareWar)
  doAssert not diplomacy.apply(1, 0, 2, DeclareWar)
  diplomacy.advance(TickRate)
  doAssert not diplomacy.atWar(0, 1)
  diplomacy.advance(TickRate + 1)
  doAssert diplomacy.atWar(0, 1) and diplomacy.atWar(1, 0)
  doAssert not diplomacy.atWar(0, 2)
  doAssert diplomacy.apply(1, 0, 30, OfferPeace)
  let offer = diplomacy.relation(0, 1).offerId
  doAssert not diplomacy.apply(1, 0, 30, AcceptOffer, offer)
  doAssert not diplomacy.apply(0, 1, 30, AcceptOffer, offer + 1)
  doAssert diplomacy.atWar(0, 1)
  doAssert diplomacy.apply(0, 1, 30, AcceptOffer, offer)
  doAssert diplomacy.relation(0, 1).state == Neutral
  doAssert diplomacy.apply(0, 1, 31, OfferAlliance)
  doAssert diplomacy.apply(1, 0, 31, OfferAlliance)
  doAssert diplomacy.sharesVision(0, 1)
  doAssert diplomacy.apply(1, 0, 32, EndAlliance)
  doAssert not diplomacy.apply(0, 1, 33, EndAlliance)
  doAssert not diplomacy.apply(0, 1, 33, DeclareWar)
  diplomacy.advance(32 + TickRate * 2 - 1)
  doAssert diplomacy.sharesVision(0, 1)
  diplomacy.advance(32 + TickRate * 2)
  doAssert not diplomacy.sharesVision(0, 1)
  doAssert diplomacy.apply(0, 1, 32 + TickRate * 2, DeclareWar)
  diplomacy.advance(32 + TickRate * 3 - 1)
  doAssert not diplomacy.atWar(0, 1)
  diplomacy.advance(32 + TickRate * 3)
  doAssert diplomacy.atWar(0, 1)

block offers:
  var diplomacy = initDiplomacy(3, FastDiplomacy)
  doAssert diplomacy.apply(0, 1, 1, OfferAlliance)
  let first = diplomacy.relation(0, 1).offerId
  doAssert not diplomacy.apply(0, 1, 2, OfferAlliance)
  doAssert diplomacy.apply(1, 0, 2, DeclineOffer, first)
  doAssert not diplomacy.apply(0, 1, 3, OfferAlliance)
  doAssert diplomacy.apply(0, 1, 2 + TickRate, OfferAlliance)
  doAssert not diplomacy.apply(1, 0, 2 + TickRate, AcceptOffer, first)
  diplomacy.advance(2 + TickRate + FastDiplomacy.offerSeconds * TickRate)
  doAssert diplomacy.relation(0, 1).offer == NoOffer
  doAssert diplomacy.apply(0, 2, 200, DeclareWar)
  doAssert diplomacy.apply(0, 2, 201, WithdrawWar)
  doAssert not diplomacy.apply(0, 2, 202, DeclareWar)
  doAssert diplomacy.apply(0, 2, 201 + TickRate, DeclareWar)
  diplomacy.eliminate(2)
  doAssert diplomacy.relation(0, 2).state == Neutral

echo "Testing combat permissions, shared vision, and independent snapshots"
block combatAndVision:
  let
    game = newGame(generateMap(42, 3), 1000, FastDiplomacy)
    world = game.world
    centre = world.map.side div 2
    attacker = world.spawnUnit(0, SoldierUnit, tile2(centre, centre))
    target = world.spawnUnit(1, PeonUnit, tile2(centre + 1, centre))
  world.rebuildVision()
  let hp = world.units[world.unitIndex(target)].hp
  doAssert not world.applyAttack(0, attacker, target)
  world.damageEntity(target, 1000, 0)
  doAssert world.units[world.unitIndex(target)].hp == hp
  doAssert world.applyDiplomacy(0, 1, DeclareWar)
  for tick in 1 ..< TickRate:
    world.tickWorld(nil)
    doAssert world.units[world.unitIndex(target)].hp == hp
  world.tickWorld(nil)
  doAssert world.atWar(0, 1)
  doAssert world.applyAttack(0, attacker, target)
  doAssert world.applyDiplomacy(0, 1, OfferPeace)
  game.accept(0, 1)
  let peacefulHp = world.units[world.unitIndex(target)].hp
  for tick in 1 .. TickRate * 2:
    world.tickWorld(nil)
  doAssert world.units[world.unitIndex(target)].hp == peacefulHp
  doAssert world.applyDiplomacy(0, 1, OfferAlliance)
  game.accept(0, 1)
  doAssert world.applyDiplomacy(1, 2, OfferAlliance)
  game.accept(1, 2)
  let
    home1 = world.map.hallOrigin[1]
    home2 = world.map.hallOrigin[2]
  doAssert world.visible(0, home1)
  doAssert world.visible(1, home2)
  doAssert not world.visible(0, home2), "Vision leaked through an ally."
  let snapshot = world.clone()
  doAssert world.applyDiplomacy(0, 1, EndAlliance)
  doAssert snapshot.diplomacy.relation(0, 1).state == Allied
  for tick in 1 .. TickRate * 2:
    world.tickWorld(nil)
  doAssert not world.visible(0, home1)
  doAssert world.explored(0, int32(home1.x), int32(home1.y))
  doAssert snapshot.diplomacy.relation(0, 1).state == Allied

echo "Testing base policy ranking, peace after elimination, and final betrayal"
block policy:
  let game = newGame(generateMap(73, 7), 2000, FastDiplomacy)
  var sources = newSeq[string](7)
  sources[0] = BasePolicy
  game.loadBots(sources)
  let ranked = game.world.rankedNeighbors(0)
  game.step()
  for rank, other in ranked:
    let pair = game.world.diplomacy.relation(0, other)
    if rank < 2:
      doAssert pair.offer == AllianceOffer
      game.accept(0, other)
    else:
      doAssert pair.state == WarPending
  game.step(int(TickRate))
  for rank in 2 ..< ranked.len:
    doAssert game.world.atWar(0, ranked[rank])

  game.defeat(ranked[0])
  game.step(2)
  let newNeighbor = ranked[2]
  doAssert game.world.players[ranked[0]].defeated
  doAssert game.world.diplomacy.relation(0, newNeighbor).offer == PeaceOffer
  game.accept(0, newNeighbor)
  doAssert not game.world.atWar(0, newNeighbor)
  game.step(int(TickRate))
  doAssert game.world.diplomacy.relation(0, newNeighbor).offer == AllianceOffer
  game.accept(0, newNeighbor)
  for other in ranked:
    if other != newNeighbor and not game.world.players[other].defeated:
      game.defeat(other)
  game.step(2)
  let ending = game.world.diplomacy.relation(0, newNeighbor)
  doAssert ending.state == AllianceEnding
  let earliestWar = ending.deadline + TickRate
  while game.world.tick < earliestWar:
    doAssert not game.world.atWar(0, newNeighbor)
    game.step()
  game.step(int(TickRate))
  doAssert game.world.atWar(0, newNeighbor)
  game.defeat(newNeighbor)
  game.step()
  doAssert game.world.over and game.world.winner == 0

echo "Testing diplomacy settings and policy commands replay tick for tick"
block replay:
  let
    map = generateMap(19, 5)
    game = newGame(map, 120, FastDiplomacy)
  var setup = Setup(
    mapSeed: map.seed,
    tickRate: uint16(TickRate),
    gridTiles: uint16(map.side),
    decisionTicks: uint16(DecisionTicks),
    maximumTicks: 120,
    mapHash: map.hash,
    contentHash: contentHash(),
    mapSettings: map.settings,
    diplomacySettings: FastDiplomacy
  )
  var sources = newSeq[string](5)
  for player, tile in map.hallOrigin:
    sources[player] = BasePolicy
    setup.players.add ReplayPlayerSetup(
      id: int32(player), startX: int32(tile.x), startY: int32(tile.y)
    )
  game.recorder = initReplayRecorder(setup)
  game.loadBots(sources)
  for tick in 1 .. 120:
    game.step()
    game.recorder.recordHash(game.stateHash())
  let
    data = decodeReplay(encodeReplay(game.recorder.data))
    playback = newGame(map, 120, data.header.setup.diplomacySettings)
    cursor = initReplayPlayer(data)
  doAssert data.header.setup.diplomacySettings == FastDiplomacy
  var diplomacyActions = 0
  for action in data.actions:
    if action.kind == ActionDiplomacy:
      inc diplomacyActions
  doAssert diplomacyActions > 0
  proc decide(w: World) =
    ## Replays every accepted diplomacy and economic command.
    var action: ReplayAction
    while cursor.takeActionAt(uint32(w.tick), action):
      doAssert w.applyReplayAction(action)
  for tick in 1 .. 120:
    playback.world.tickWorld(decide)
    doAssert playback.stateHash() == data.hashes[tick - 1]
  doAssert cursor.finished

doAssert readFile("coworld/lvd/players/base.bas") == BasePolicy
echo "LvD diplomacy and base policy passed"
