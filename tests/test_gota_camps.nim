import
  std/[os, sets, tempfiles],
  bassy,
  polyworld/[cli, pathing],
  ../examples/gods_of_the_arena/[bots, content, maps, replays, sim]

proc campGame(size = 116): Game =
  ## Creates camps without lane waves, bots, or incidental tower attacks.
  var preset = defaultConfig()
  preset.mapSize = size
  result = newGame(generateMap(54, preset), 100_000, 10, false,
    ReplayData(), drafting = false)
  result.world.spawnTimerTicks = 100_000
  result.world.heroTurnTicks = 100_000
  for building in result.world.buildings.mitems:
    building.hp = 0
  for hero in result.world.heroes:
    hero.hp = 0
    hero.state = Dying
    hero.deathTicks = -100_000
  result.world.syncBuildings()
  result.tickWorld(nil)

proc member(world: World, camp: int, leader = false): int =
  ## Finds a living member without depending on unit storage order.
  for i, unit in world.footmen:
    if unit.camp == camp + 1 and unit.hp > 0 and unit.leader == leader:
      return i
  -1

proc awaken(game: Game, index: int, point: WorldPoint): Hero =
  ## Places a living hero without starting an automatic basic attack.
  result = game.world.heroes[index]
  result.state = Marching
  result.maxHp = 10_000
  result.hp = 10_000
  result.hasMoveTarget = true
  result.place(point)

proc poison(game: Game, hero: Hero, index: int) =
  ## Damages a visible neutral through the real consumable command path.
  let world = game.world
  hero.inventory[0] = PoisonPotion
  hero.itemCounts[0] = 1
  hero.attackObjectId = world.footmen[index].id
  world.rebuildVision()
  doAssert world.applyUseItem(hero.id, 0), $hero.lastActionError
  hero.attackObjectId = 0
  hero.hasMoveTarget = true

echo "Testing seeded camp tiers, mirror groups, and valid spawn tiles"
for size in [64, 116, 256]:
  let
    game = campGame(size)
    world = game.world
  doAssert world.camps.len == 14
  var
    tiers: array[3, int]
    ids: HashSet[int32]
  for index, camp in world.camps:
    doAssert camp.started, "Camp did not fit: " & $size & " " & $index
    inc tiers[camp.tier - 1]
    doAssert camp.count in camp.tier .. (if camp.tier == 3: 5 else: camp.tier + 1)
    let pair = world.camps[index xor 1]
    doAssert camp.tier == pair.tier and camp.count == pair.count
    doAssert camp.appearance == pair.appearance
    doAssert camp.center.x == -pair.center.x
    doAssert camp.center.z == -pair.center.z
    var count, leaders: int
    for unit in world.footmen:
      if unit.camp != index + 1:
        continue
      inc count
      if unit.leader:
        inc leaders
      doAssert unit.faction == 2
      doAssert unit.hp == unit.unitMaxHp
      doAssert unit.id notin ids
      ids.incl unit.id
      doAssert navigationOpen(unit.navLayer.int,
        mapCoordinate(unit.position.x, unit.team).int,
        mapCoordinate(unit.position.z, unit.team).int)
      var mirrored = false
      for other in world.footmen:
        if other.camp == (index xor 1) + 1 and
          other.home.x == -unit.home.x and other.home.z == -unit.home.z:
            doAssert other.leader == unit.leader
            mirrored = true
      doAssert mirrored, "Asymmetric spawn: " & $size & " " & $index
    doAssert count == camp.count
    doAssert leaders == (if count > 1: 1 else: 0)
  doAssert tiers == [6, 4, 4]

echo "Testing explicit attacks, group aggro, and both teams"
for team in Team:
  let
    game = campGame()
    world = game.world
    index = world.member(0)
    unit = world.footmen[index]
    hero = game.awaken(team.ord * 5, unit.position)
  doAssert world.camps[0].state == RestingCamp
  doAssert hero.hp == hero.maxHp
  game.poison(hero, index)
  doAssert world.camps[0].state == FightingCamp
  doAssert world.footmen[index].hp < unit.hp
  for tick in 0 ..< 2 * TickRate:
    game.tickWorld(nil)
  doAssert hero.hp < hero.maxHp
  doAssert world.footmen[index].targetHeroId == hero.id

  let before = world.footmen[index].hp
  world.applyControl(unit.id, RootControl, 100)
  doAssert world.footmen[index].controls[RootControl].ends > world.tick
  hero.place(world.forts[hero.team.ord].center)
  game.tickWorld(nil)
  doAssert world.camps[0].state in {ReturningCamp, RestingCamp}
  if world.camps[0].state == ReturningCamp:
    world.applyControl(unit.id, StunControl, 100)
    doAssert world.footmen[index].controls[StunControl].ends == 0
  for tick in 0 ..< 10 * TickRate:
    game.tickWorld(nil)
  doAssert world.camps[0].state == RestingCamp
  doAssert world.footmen[index].hp == unit.unitMaxHp
  doAssert before < world.footmen[index].hp

echo "Testing proximity wakes camps for heroes and creeps on either team"
for team in Team:
  for creep in [false, true]:
    let
      game = campGame()
      world = game.world
      index = world.member(0)
      mob = world.footmen[index]
    world.camps.setLen(1)
    world.footmen = @[mob]
    world.footmen[0].controls[StunControl] =
      ControlTimer(started: world.tick, ends: world.tick + 100)
    var point = mob.position
    point.x += NeutralAggroTiles * WorldScale + 1
    var targetId: int32
    if creep:
      var unit = Footman(id: world.nextFootmanId, team: team,
        hp: 10_000, kind: MeleeCreep, swingTicks: -1)
      unit.place(point)
      unit.controls[StunControl] =
        ControlTimer(started: world.tick, ends: world.tick + 100)
      world.footmen.add unit
      targetId = unit.id
      inc world.nextFootmanId
    else:
      let hero = game.awaken(team.ord * 5, point)
      hero.controls[StunControl] =
        ControlTimer(started: world.tick, ends: world.tick + 100)
      targetId = hero.id
    game.tickWorld(nil)
    doAssert world.camps[0].state == RestingCamp
    dec point.x
    if creep:
      world.footmen[1].place(point)
    else:
      world.heroes[team.ord * 5].place(point)
    game.tickWorld(nil)
    doAssert world.camps[0].state == FightingCamp
    doAssert world.camps[0].targetId == targetId
    when defined(replayEvents):
      var engaged = 0
      for event in world.events:
        if event.kind == CampEngaged:
          inc engaged
          doAssert event.actor.id == targetId
          doAssert event.target.id == mob.id
          doAssert event.cause == Proximity
      doAssert engaged == 1

echo "Testing a nearby hidden hero does not provoke a camp"
block:
  let
    game = campGame()
    world = game.world
    mob = world.footmen[world.member(0)]
  world.camps.setLen(1)
  world.footmen = @[mob]
  world.footmen[0].controls[StunControl] =
    ControlTimer(started: world.tick, ends: world.tick + 100)
  var point = mob.position
  point.x += 2 * WorldScale
  let hero = game.awaken(0, point)
  hero.controls[StunControl] =
    ControlTimer(started: world.tick, ends: world.tick + 100)
  point.x -= WorldScale
  world.buildings.add Building(id: 777, kind: BarracksBuilding,
    team: RedTeam, hp: 100, position: point)
  game.tickWorld(nil)
  doAssert world.camps[0].state == RestingCamp
  world.buildings[^1].hp = 0
  game.tickWorld(nil)
  doAssert world.camps[0].state == FightingCamp

echo "Testing the exact twelve-tile leash boundary"
block:
  let
    game = campGame()
    world = game.world
    index = world.member(0)
    center = world.camps[0].center
    hero = game.awaken(0, center)
  world.camps[0].state = FightingCamp
  world.camps[0].targetId = hero.id
  world.camps[0].lastSeenTick = world.tick
  var point = center
  point.x += NeutralLeash
  world.footmen[index].place(point)
  world.footmen[index].controls[StunControl] =
    ControlTimer(started: world.tick, ends: world.tick + 100)
  game.tickWorld(nil)
  doAssert world.camps[0].state == FightingCamp
  point.x += 1
  world.footmen[index].place(point)
  game.tickWorld(nil)
  doAssert world.camps[0].state == ReturningCamp
  doAssert world.footmen[index].controls[StunControl].ends == 0

echo "Testing contested neutral rewards reserve 15 percent for the last hit"
block:
  let
    game = campGame()
    world = game.world
    index = world.member(0)
    unit = world.footmen[index]
  for i in [0, 1, 2, 5]:
    discard game.awaken(i, unit.position)
  world.footmen[index].hp = 1
  let killer = world.heroes[0]
  let gold = killer.gold
  game.poison(killer, index)
  let pool = NeutralXp[unit.campTier - 1] * 6000
  for i in 0 .. 2:
    let hero = world.heroes[i]
    let expected = pool * 85 div 100 div 3 +
      (if i == 0: pool * 15 div 100 else: 0)
    doAssert hero.totalXp * 6000 + hero.creepXpRemainder == expected
  doAssert world.heroes[5].totalXp == 0
  doAssert killer.gold - gold == NeutralGold[unit.campTier - 1]

echo "Testing full-clear cooldown, exact hero blocking radius, and fresh IDs"
block:
  let
    game = campGame()
    world = game.world
    center = world.camps[0].center
    hero = game.awaken(0, WorldPoint(x: center.x + CampRespawnRadius, y: center.y, z: center.z))
    lastId = world.nextFootmanId
  for unit in world.footmen.mitems:
    if unit.camp == 1:
      unit.hp = 0
  game.tickWorld(nil)
  let deadline = world.camps[0].respawnTick
  doAssert deadline == world.tick + CampRespawnTicks
  for tick in 0 ..< CampRespawnTicks:
    game.tickWorld(nil)
  doAssert world.tick == deadline
  doAssert world.camps[0].state == EmptyCamp
  hero.place(WorldPoint(x: center.x + CampRespawnRadius + WorldScale, y: center.y, z: center.z))
  game.tickWorld(nil)
  doAssert world.camps[0].state == RestingCamp
  for unit in world.footmen:
    if unit.camp == 1:
      doAssert unit.hp > 0 and unit.id >= lastId

  let snapshot = world.clone()
  let hash = game.stateHash()
  world.camps[0].respawnTick += 1
  doAssert game.stateHash() != hash
  world.restore(snapshot)
  doAssert game.stateHash() == hash

echo "Testing neutral observations never inherit navigation-side vision"
block:
  let
    game = campGame()
    world = game.world
    index = world.member(0)
    unit = world.footmen[index]
  for cells in world.teamVisible.mitems:
    for cell in cells.mitems:
      cell = 0
  var value: WorldObject
  for hero in world.heroes:
    doAssert not world.worldObjectById(hero.id, unit.id, value)
  discard game.awaken(0, unit.position)
  world.rebuildVision()
  world.tick += 1
  doAssert world.worldObjectById(world.heroes[0].id, unit.id, value)
  doAssert value.kind == 6 and value.faction == 2
  doAssert value.camp == 1
  doAssert value.class == world.camps[0].tier

echo "Testing leaders pay double and partial clears never refill"
block:
  let
    game = campGame()
    world = game.world
  var index = -1
  for i, unit in world.footmen:
    if unit.leader:
      index = i
      break
  doAssert index >= 0
  let
    unit = world.footmen[index]
    hero = game.awaken(0, unit.position)
    gold = hero.gold
  world.footmen[index].hp = 1
  game.poison(hero, index)
  doAssert hero.totalXp == 2 * NeutralXp[unit.campTier - 1]
  doAssert hero.gold - gold == 2 * NeutralGold[unit.campTier - 1]
  hero.place(world.forts[hero.team.ord].center)
  for tick in 0 ..< CampRespawnTicks + TickRate:
    game.tickWorld(nil)
  var survivors = 0
  for other in world.footmen:
    if other.camp == unit.camp:
      inc survivors
      doAssert other.hp == other.unitMaxHp and not other.leader
  doAssert survivors == world.camps[unit.camp - 1].count - 1

echo "Testing returning immunity and tower last hits share XP without gold"
block:
  let
    game = campGame()
    world = game.world
    index = world.member(0)
    unit = world.footmen[index]
    hero = game.awaken(0, unit.position)
    ally = game.awaken(1, unit.position)
    outsider = game.awaken(5, unit.position)
    gold = hero.gold
  game.poison(hero, index)
  world.camps[0].state = ReturningCamp
  hero.attackObjectId = unit.id
  hero.inventory[0] = PoisonPotion
  hero.itemCounts[0] = 1
  let hp = world.footmen[index].hp
  doAssert not world.applyUseItem(hero.id, 0)
  doAssert world.footmen[index].hp == hp
  world.applyControl(unit.id, StunControl, 100)
  doAssert world.footmen[index].controls[StunControl].ends == 0
  world.camps[0].state = FightingCamp
  world.footmen[index].hp = 1
  var tower = Building(id: 777, team: RedTeam, tier: OuterTower,
    kind: TowerBuilding, hp: 100, position: unit.position,
    targetId: unit.id, attackTicks: TowerAttackTicks - 1)
  world.buildings.add tower
  world.updateTower(tower)
  inc world.tick
  world.advanceTowerShots()
  doAssert world.footmen[index].hp <= 0
  doAssert hero.totalXp == NeutralXp[unit.campTier - 1] div 2
  doAssert ally.totalXp == hero.totalXp
  doAssert outsider.totalXp == 0 and hero.gold == gold

echo "Testing lane creeps pull resting camps and both sides deal damage"
for team in Team:
  let
    game = campGame()
    world = game.world
    index = world.member(0)
    unit = world.footmen[index]
  var laneCreep = Footman(id: world.nextFootmanId, team: team,
    hp: 10_000, kind: MeleeCreep, swingTicks: -1)
  inc world.nextFootmanId
  laneCreep.place(unit.position)
  world.footmen.add laneCreep
  let id = laneCreep.id
  game.tickWorld(nil)
  doAssert world.camps[0].state == FightingCamp
  doAssert world.camps[0].targetId == id
  doAssert world.footmanById(id).targetId != 0
  for tick in 0 ..< 2 * TickRate:
    game.tickWorld(nil)
  doAssert world.footmanById(id).hp < 10_000
  var wounded = false
  for mob in world.footmen:
    if mob.camp == 1 and mob.hp < mob.unitMaxHp:
      wounded = true
  doAssert wounded

echo "Testing all neutral BASIC queries through an actual policy VM"
block:
  let
    game = campGame()
    world = game.world
    index = world.member(0)
    unit = world.footmen[index]
    hero = game.awaken(0, unit.position)
    directory = createTempDir("gota-camps-", "")
    path = directory / "camps.bas"
  writeFile(path, """
camps = campCount()
x = campX(0)
y = campY(0)
tier = campTier(0)
invalid = objectCamp(-1)
found = 0
for i = 0 to objectCount() - 1
  if objectKind(i) = 6 then
    found = found + 1
    team = objectTeam(i)
    membership = objectCamp(i)
    class = objectClass(i)
    leader = objectLeader(i)
    returning = objectReturning(i)
  end if
next i
""")
  game.loadBots([BotGroup(path: path, count: 10)])
  for i in 1 ..< game.heroVms.len:
    game.heroVms[i] = nil
  world.rebuildVision()
  game.runBotDecisions()
  let vm = game.heroVms[0]
  doAssert not vm.failed, vm.lastError
  doAssert vm.runtime.getGlobal("camps") == 14
  doAssert vm.runtime.getGlobal("tier") == world.camps[0].tier
  doAssert vm.runtime.getGlobal("x") ==
    mapCoordinate(world.camps[0].center.x, hero.team)
  doAssert vm.runtime.getGlobal("invalid") == -1
  doAssert vm.runtime.getGlobal("found") > 0
  doAssert vm.runtime.getGlobal("team") == 2
  removeFile(path)
  removeDir(directory)

echo "Neutral camp tests passed"
