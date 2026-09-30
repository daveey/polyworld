import
  bassy,
  polyworld/[metrics, tapes],
  ../examples/light_vs_dark/[bots, content, maps, replays, sim]

proc setup(map: MapData, ticks: int32): Setup =
  ## Records every map setting and player coordinate for a test match.
  result = Setup(
    mapSeed: map.seed,
    tickRate: uint16(TickRate),
    gridTiles: uint16(map.side),
    decisionTicks: uint16(DecisionTicks),
    maximumTicks: uint32(ticks),
    mapHash: map.hash,
    contentHash: contentHash(),
    mapSettings: map.settings
  )
  for player, tile in map.hallOrigin:
    result.players.add ReplayPlayerSetup(
      id: int32(player), startX: int32(tile.x), startY: int32(tile.y)
    )

proc defeat(w: World, player: int32) =
  ## Removes a player's economy and units through normal combat damage.
  for unit in w.units:
    if unit.owner == player:
      w.damageEntity(unit.id, unit.hp)
  for building in w.buildings:
    if building.owner == player:
      w.damageEntity(building.id, building.hp)

echo "Testing every supplied bot acts and records deterministic commands"
block allBots:
  const Ticks = 480'i32
  let map = generateMap(73, 9, MapSettings(layout: RandomLayout, size: 192))
  var sources = newSeq[string](map.hallOrigin.len)
  for source in sources.mitems:
    source = readFile("examples/light_vs_dark/players/base.bas")
  let game = newGame(map, Ticks)
  game.recorder = initReplayRecorder(map.setup(Ticks))
  game.loadBots(sources)
  for player in 0'i32 ..< int32(sources.len):
    doAssert game.world.peonCount(player) == StartingPeons
    doAssert game.world.buildingCount(player) == 1
  proc decide(w: World) =
    ## Supplies commands from every bot's independent VM.
    game.runBotDecisions()
  for tick in 1 .. Ticks:
    game.world.tickWorld(decide)
    game.recorder.recordHash(game.stateHash())
  for player, brain in game.brains:
    doAssert not brain.failed, brain.lastError
    doAssert brain.decisions == Ticks
    doAssert game.world.players[player].goldGathered > 0
    doAssert game.world.buildingCount(int32(player)) > 1
    doAssert game.metrics.read(player, Ticks).commands > 0
  let
    data = decodeReplay(encodeReplay(game.recorder.data))
    regenerated = generateMap(data.config.seed, data.config.players.len,
      data.header.setup.mapSettings)
    playback = newGame(regenerated, Ticks)
    cursor = initReplayPlayer(data)
  doAssert regenerated.hash == map.hash
  doAssert data.header.setup.players[^1].id == 8
  doAssert data.header.setup.gridTiles > 255
  proc replay(w: World) =
    ## Applies only accepted recorded commands to the regenerated map.
    var action: ReplayAction
    while cursor.takeActionAt(uint32(w.tick), action):
      doAssert w.applyReplayAction(action)
  for tick in 1 .. Ticks:
    playback.world.tickWorld(replay)
    doAssert playback.stateHash() == data.hashes[tick - 1]
  doAssert cursor.finished

block multipleOpponents:
  let
    map = generateMap(42, 4)
    game = newGame(map, 1000)
    centre = map.side div 2
    attacker = game.world.spawnUnit(0, SoldierUnit, tile2(centre, centre))
    enemy = game.world.spawnUnit(2, PeonUnit, tile2(centre + 1, centre))
  var output = NoEntity
  game.loadBots(["print nearestEnemy(" & $attacker & ")", "", "", ""])
  game.brains[0].output = proc(event: PrintEvent) =
    ## Captures the host query's enemy identifier.
    if event.kind == ValuePrint:
      output = event.value
  game.world.rebuildVision()
  game.runBotDecisions()
  doAssert not game.brains[0].failed
  doAssert output == NoEntity
  doAssert game.world.applyDiplomacy(0, 2, DeclareWar)
  for tick in 1 .. TickRate * 10:
    game.world.tickWorld(nil)
  game.runBotDecisions()
  doAssert output == enemy
  doAssert not game.world.applyMove(0, enemy, centre, centre + 4)
  doAssert not game.world.applyReplayAction(ReplayAction(
    playerId: 300, kind: ActionMove, entityId: attacker,
    first: centre, second: centre
  ))
  let hp = game.world.units[game.world.unitIndex(enemy)].hp
  for tick in 1 .. 48:
    game.world.tickWorld(nil)
  doAssert not game.world.hasUnit(enemy) or
    game.world.units[game.world.unitIndex(enemy)].hp < hp

block elimination:
  let
    map = generateMap(1, 5)
    w = newWorld(map, 1000)
  w.defeat(1)
  w.tickWorld(nil)
  doAssert w.players[1].defeated
  doAssert not w.over
  for player in [0'i32, 2'i32, 3'i32]:
    w.defeat(player)
  w.tickWorld(nil)
  doAssert w.over and w.winner == 4
  doAssert w.scores() == @[0, 0, 0, 0, 1]

block timeLimit:
  let
    map = generateMap(1, 4)
    tied = newWorld(map, 1)
    winner = newWorld(map, 1)
  tied.tickWorld(nil)
  doAssert tied.over and tied.winner == -1
  winner.players[3].goldGathered = 50000
  winner.tickWorld(nil)
  doAssert winner.winner == 3

block solo:
  let w = newWorld(generateMap(1, 1), 3)
  w.tickWorld(nil)
  doAssert not w.over
  w.tickWorld(nil)
  w.tickWorld(nil)
  doAssert w.over and w.winner == 0

block wideReplayRoster:
  var setup = Setup(
    mapSeed: 1, tickRate: uint16(TickRate), gridTiles: 1024,
    decisionTicks: uint16(DecisionTicks), maximumTicks: 1,
    mapHash: 1, contentHash: contentHash()
  )
  for player in 0 ..< 300:
    setup.players.add ReplayPlayerSetup(
      id: int32(player), startX: int32(player), startY: 500
    )
  let recorder = initReplayRecorder(setup)
  recorder.recordAction(1, 299, ActionMove, FirstUnitId, 900, 900)
  recorder.recordHash(1)
  let decoded = decodeReplay(encodeReplay(recorder.data))
  doAssert decoded.actions[0].playerId == 299
  doAssert decoded.header.setup.players[299].startY == 500

block independentWorlds:
  let
    small = newWorld(generateMap(1, 1), 10)
    large = newWorld(generateMap(1, 9), 10)
  doAssert small.map.side < large.map.side
  doAssert not small.terrainOpen(large.map.side - 10, 10)
  doAssert small.blocker.len == small.map.side * small.map.side
  doAssert large.blocker.len == large.map.side * large.map.side
  let snapshot = large.clone()
  large.players[8].gold = 0
  large.explored[8][0] = 1
  large.restore(snapshot)
  doAssert large.players[8].gold == StartingGold
  doAssert large.explored[8][0] == 0

echo "LvD multiplayer and replay tests passed"
