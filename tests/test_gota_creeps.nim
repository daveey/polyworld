import
  polyworld/[metrics, pathing],
  ../examples/gods_of_the_arena/[content, maps, replays, sim]

proc creepGame(): Game =
  ## Isolates creep combat in a broad, open section of the upper lane.
  var preset = defaultConfig()
  preset.mapSize = 128
  preset.roadWidth = 62
  result = newGame(
    generateMap(2026, preset),
    100_000,
    10,
    false,
    ReplayData(),
    drafting = false
  )
  result.world.spawnTimerTicks = 100_000
  result.world.heroTurnTicks = 100_000
  for hero in result.world.heroes:
    hero.hp = 0
    hero.state = Dying
    hero.deathTicks = -100_000
  for building in result.world.buildings.mitems:
    building.hp = 0
  result.world.syncBuildings()

proc lanePoint(offset = 0'i32): WorldPoint =
  ## Returns a measured test position on the arena floor.
  let tile = layers[GroundLayer].tiles[18 * GridTiles + 56]
  result = WorldPoint(
    x: (56 - GridTiles div 2) * WorldScale + WorldScale div 2 + offset,
    z: (18 - GridTiles div 2) * WorldScale + WorldScale div 2
  )
  for height in tile.tops:
    result.y += height.int32 * WorldScale div 32

proc addCreep(
    game: Game, kind = MeleeCreep, team = BlueTeam,
    offset = 0'i32, hp = FootmanHp
) =
  ## Places one creep with a stable ID on the shared combat line.
  var creep = Footman(
    id: 1000 + game.world.footmen.len.int32,
    kind: kind, team: team, lane: 0, hp: hp, swingTicks: -1
  )
  creep.place(lanePoint(offset))
  game.world.footmen.add creep

proc revive(game: Game, index: int, offset = 0'i32): Hero =
  ## Places a living hero without changing its assigned starting lane.
  result = game.world.heroes[index]
  result.hp = result.maxHp
  result.state = Marching
  result.place(lanePoint(offset))

proc reveal(world: World) =
  ## Makes direct command tests independent of stale visibility caches.
  for team in Team:
    for cell in world.teamVisible[team.ord].mitems:
      cell = 255

proc lastHit(game: Game, hero: Hero) =
  ## Kills the first creep through the public item damage path.
  hero.inventory[0] = PoisonPotion
  hero.itemCounts[0] = 1
  hero.attackObjectId = game.world.footmen[0].id
  game.world.reveal()
  doAssert game.world.applyUseItem(hero.id, 0)
  doAssert game.world.footmen[0].hp <= 0

echo "Testing doubled tower health and damage at every tier"
block:
  let game = newGame(generateMap(2026), 100_000, 0, false, ReplayData())
  for building in game.world.buildings:
    if building.kind == BarracksBuilding:
      doAssert building.hp == 950
    else:
      doAssert building.hp == [1900'i32, 2600, 3900][building.tier.ord]
      doAssert building.maxHp == building.hp
  for tier in TowerTier:
    game.world.footmen = @[
      Footman(id: 1000, team: BlueTeam, hp: 1000)
    ]
    var tower = Building(
      id: 99, team: RedTeam, tier: tier, hp: 1,
      targetId: 1000, attackTicks: TowerAttackTicks - 1
    )
    game.world.reveal()
    game.world.updateTower(tower)
    inc game.world.tick
    game.world.advanceTowerShots()
    doAssert game.world.footmen[0].hp ==
      1000 - [36'i32, 48, 60][tier.ord]

echo "Testing staff creeps attack from range while sword creeps must close"
for kind in CreepKind:
  let game = creepGame()
  game.addCreep(kind, RedTeam)
  game.addCreep(MeleeCreep, BlueTeam, 3 * WorldScale, 1000)
  let start = game.world.footmen[0].position
  for tick in 0 ..< footmanHitTicks(attackClips[0]):
    game.tickWorld(nil)
  if kind == RangedCreep:
    doAssert game.world.footmen[1].hp == 1000 - FootmanDamage
    doAssert within(start, game.world.footmen[0].position, 10)
  else:
    doAssert game.world.footmen[1].hp == 1000
    doAssert not within(start, game.world.footmen[0].position, 10)

echo "Testing nearby XP boundaries, last-hit bonuses, and no allied rewards"
block:
  let
    game = creepGame()
    killer = game.revive(0)
    nearby = game.revive(2, CreepXpRange)
    distant = game.revive(3, CreepXpRange + 1)
    otherFloor = game.revive(4)
    enemy = game.revive(5)
    gold = killer.gold
  otherFloor.navLayer = GroundLayer + 1
  game.world.heroes[1].place(lanePoint())
  game.addCreep(hp = 1)
  doAssert nearby.lane != game.world.footmen[0].lane
  game.lastHit(killer)
  doAssert killer.totalXp == 8
  doAssert killer.gold == gold + 15
  doAssert nearby.totalXp == 6
  doAssert nearby.gold == gold
  doAssert distant.totalXp == 0
  doAssert otherFloor.totalXp == 0
  doAssert enemy.totalXp == 0
  doAssert game.world.heroes[1].totalXp == 0
  doAssert game.world.stats.values[0][GoldMetric] == 15
  doAssert game.world.stats.values[2][GoldMetric] == 0
  doAssert not game.world.applyUseItem(killer.id, 0)
  doAssert killer.totalXp == 8

echo "Testing the shared XP pool and fractional last-hit shares"
for count in 1 .. 5:
  let game = creepGame()
  for i in 0 ..< count:
    discard game.revive(i)
  for kill in 0 ..< 80:
    game.world.footmen.setLen(0)
    game.addCreep(hp = 1)
    inc game.world.tick
    game.lastHit(game.world.heroes[0])
    if count == 3 and kill == 0:
      doAssert game.world.heroes[0].totalXp == 6
      doAssert game.world.heroes[1].totalXp == 4
      doAssert game.world.heroes[2].totalXp == 4
  let
    pool = 80 * CreepNearbyXp
    bonus = pool * 15 div 100
    share = (pool - bonus) div count
  var total = 0
  for i in 0 ..< count:
    let hero = game.world.heroes[i]
    doAssert hero.totalXp == share + (if i == 0: bonus else: 0)
    doAssert hero.creepXpRemainder == 0
    total += hero.totalXp
  doAssert total == pool

echo "Testing tower kills grant nearby XP once without last-hit gold"
block:
  let
    game = creepGame()
    hero = game.revive(0)
    gold = hero.gold
  hero.xp = xpForNextLevel(hero.level) - CreepNearbyXp
  game.addCreep(hp = 1)
  var tower = Building(
    id: 99, team: RedTeam, hp: 1, position: lanePoint(),
    targetId: 1000, attackTicks: TowerAttackTicks - 1
  )
  game.world.reveal()
  game.world.updateTower(tower)
  inc game.world.tick
  game.world.advanceTowerShots()
  doAssert hero.totalXp == CreepNearbyXp and hero.level == 2
  doAssert hero.gold == gold
  game.world.updateTower(tower)
  inc game.world.tick
  game.world.advanceTowerShots()
  doAssert hero.totalXp == CreepNearbyXp

echo "Testing basic attacks award the creep bounty exactly once"
block:
  let
    game = creepGame()
    hero = game.revive(0)
    gold = hero.gold
  hero.class = Ranger
  hero.refreshHeroStats()
  game.addCreep(offset = WorldScale, hp = 1)
  game.world.reveal()
  doAssert game.world.applyAttackTarget(hero.id, game.world.footmen[0].id)
  for tick in 0 ..< 64:
    game.tickWorld(nil)
    if game.world.footmen[0].hp <= 0:
      break
  doAssert game.world.footmen[0].hp <= 0
  doAssert hero.totalXp == CreepNearbyXp
  doAssert hero.gold == gold + 15
  doAssert game.world.stats.values[0][GoldMetric] == 15

echo "Testing ranged identity is visible only through the object filter"
block:
  let
    game = creepGame()
    hero = game.revive(0)
  game.addCreep(RangedCreep)
  game.world.reveal()
  var found = false
  for i in 0 ..< game.world.worldObjectCount(hero.id):
    var value: WorldObject
    doAssert game.world.worldObjectAt(hero.id, i, value)
    if value.id == game.world.footmen[0].id:
      doAssert value.kind == 3
      doAssert value.class == RangedCreep.ord
      found = true
  doAssert found
  for cell in game.world.teamVisible[hero.team.ord].mitems:
    cell = 0
  inc game.world.tick
  for i in 0 ..< game.world.worldObjectCount(hero.id):
    var value: WorldObject
    doAssert game.world.worldObjectAt(hero.id, i, value)
    doAssert value.id != game.world.footmen[0].id

echo "Testing creep kills grant nearby XP without last-hit gold"
block:
  let
    game = creepGame()
    hero = game.revive(0, -2 * WorldScale)
    gold = hero.gold
  game.addCreep(RangedCreep, RedTeam)
  game.addCreep(MeleeCreep, BlueTeam, WorldScale, 1)
  game.world.footmen[0].swingTicks = footmanHitTicks(attackClips[0]) - 1
  game.tickWorld(nil)
  doAssert game.world.footmen[1].hp <= 0
  doAssert hero.totalXp == CreepNearbyXp
  doAssert hero.gold == gold

echo "Testing ranged identity survives snapshots and affects replay hashes"
block:
  let game = creepGame()
  game.addCreep(RangedCreep)
  let
    snapshot = game.world.clone()
    before = game.stateHash()
  game.world.footmen[0].kind = MeleeCreep
  doAssert game.stateHash() != before
  game.world.restore(snapshot)
  doAssert game.world.footmen[0].kind == RangedCreep
  doAssert game.stateHash() == before

echo "Testing fractional XP survives snapshots and affects replay hashes"
block:
  let game = creepGame()
  discard game.revive(0)
  discard game.revive(1)
  discard game.revive(2)
  game.addCreep(hp = 1)
  game.lastHit(game.world.heroes[0])
  let
    snapshot = game.world.clone()
    before = game.stateHash()
    remainder = game.world.heroes[0].creepXpRemainder
  doAssert remainder > 0
  game.world.heroes[0].creepXpRemainder = 0
  doAssert game.stateHash() != before
  game.world.restore(snapshot)
  doAssert game.world.heroes[0].creepXpRemainder == remainder
  doAssert game.stateHash() == before

echo "Gota creep combat tests passed"
