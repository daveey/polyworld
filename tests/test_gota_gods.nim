import
  polyworld/pathing,
  ../examples/gods_of_the_arena/[content, maps, replays, scores, sim]

proc quietGame(size = 116): Game =
  ## Creates a match without automatic heroes or recurring creep waves.
  var preset = defaultConfig()
  preset.mapSize = size
  result = newGame(
    generateMap(54, preset),
    100_000,
    10,
    false,
    ReplayData(),
    drafting = false
  )
  result.world.spawnTimerTicks = 100_000
  result.world.heroTurnTicks = 100_000
  for hero in result.world.heroes:
    hero.state = Dying
    hero.deathTicks = -100_000
    hero.hp = 0
  for building in result.world.buildings.mitems:
    building.attackTicks = 100_000

echo "Testing mirrored god guards occupy open ground on supported maps"
for size in [64, 116, 256]:
  let game = quietGame(size)
  var guards: array[Team, seq[Building]]
  for building in game.world.buildings:
    if not building.guardsGod:
      continue
    guards[building.team].add building
    doAssert building.kind == TowerBuilding
    doAssert building.tier == GateTower
    doAssert building.hp == TowerHitPoints[GateTower]
    doAssert not game.world.buildingExposed(building)
    doAssert building.footprint.len > 0
    for tile in building.footprint:
      doAssert isWalkable(int(tile.layer), int(tile.x), int(tile.z))
      doAssert not navigationOpen(int(tile.layer), int(tile.x), int(tile.z))
  for team in Team:
    doAssert guards[team].len == 2
    doAssert not game.world.fortExposed(team)
  for i in 0 ..< 2:
    doAssert guards[RedTeam][i].position.x == -guards[BlueTeam][i].position.x
    doAssert guards[RedTeam][i].position.z == -guards[BlueTeam][i].position.z

echo "Testing gods resist basic attacks and ground spells until both guards fall"
for defender in Team:
  for survivors in 0 .. 2:
    let
      game = quietGame()
      world = game.world
      fort = world.forts[defender.ord]
      hero = world.heroes[if defender == BlueTeam: 0 else: 5]
    var remaining = survivors
    for building in world.buildings.mitems:
      if building.guardsGod and building.team == defender and remaining > 0:
        dec remaining
      else:
        building.hp = 0
    world.syncBuildings()
    doAssert world.fortExposed(defender) == (survivors == 0)
    for building in world.buildings:
      if building.guardsGod and building.team == defender and building.hp > 0:
        doAssert world.buildingExposed(building)
    hero.class = Arcanist
    hero.refreshHeroStats()
    hero.state = Marching
    hero.maxHp = 100_000
    hero.hp = hero.maxHp
    hero.level = 2
    doAssert world.applyLevelAbility(hero.id, PrimaryAbility.ord.int32)
    doAssert world.applyLevelAbility(hero.id, SecondaryAbility.ord.int32)
    hero.mana = 10_000
    hero.maxMana = 10_000
    hero.place(fort.center)
    hero.hasMoveTarget = true
    game.tickWorld(nil)
    doAssert world.applyCastPoint(
      hero.id, int32(SecondaryAbility),
      mapCoordinate(fort.center.x), mapCoordinate(fort.center.z)
    )
    for tick in 0 ..< int(MeteorStrike.abilitySpec.castTicks) + 2:
      hero.hasMoveTarget = true
      game.tickWorld(nil)
    if survivors > 0:
      doAssert world.forts[defender.ord].hp == FortHp
      doAssert not world.applyCastTarget(
        hero.id, int32(PrimaryAbility), fort.id
      )
    else:
      doAssert world.forts[defender.ord].hp < FortHp
    let hp = world.forts[defender.ord].hp
    doAssert world.applyAttackTarget(hero.id, fort.id)
    for tick in 0 ..< TickRate * 2:
      game.tickWorld(nil)
    if survivors > 0:
      doAssert world.forts[defender.ord].hp == hp
    else:
      doAssert world.forts[defender.ord].hp < hp

echo "Testing creeps attack surviving guards before the god"
for size in [64, 116, 256]:
  for defender in Team:
    let
      game = quietGame(size)
      world = game.world
      fort = world.forts[defender.ord]
      enemy = if defender == RedTeam: BlueTeam else: RedTeam
    for building in world.buildings.mitems:
      if not building.guardsGod or building.team != defender:
        building.hp = 0
    world.syncBuildings()
    var creep = Footman(id: 50_000, team: enemy, lane: 1, hp: 100_000)
    creep.place(fort.center)
    creep.waypointIndex = creep.creepWaypoints().len
    world.footmen.add creep
    for tick in 0 ..< TickRate * 8:
      game.tickWorld(nil)
    doAssert world.forts[defender.ord].hp == FortHp
    var damaged = false
    for building in world.buildings:
      if building.guardsGod and building.team == defender:
        if building.hp < building.maxHp:
          damaged = true
    doAssert damaged
    for building in world.buildings.mitems:
      if building.guardsGod and building.team == defender:
        building.hp = 0
    world.syncBuildings()
    for tick in 0 ..< TickRate * 20:
      game.tickWorld(nil)
    doAssert world.forts[defender.ord].hp < FortHp

echo "Testing god kills reward every teammate once, including dead heroes"
for attacker in Team:
  for creepLastHit in [false, true]:
    let
      game = quietGame()
      world = game.world
      defender = Team(1 - attacker.ord)
      fort = world.forts[defender.ord]
      killer = world.heroes[attacker.ord * 5]
      distant = world.heroes[attacker.ord * 5 + 1]
      capped = world.heroes[attacker.ord * 5 + 2]
    for building in world.buildings.mitems:
      building.hp = 0
    world.syncBuildings()
    world.tick = 5 * 60 * TickRate - 1
    world.forts[defender.ord].hp = 1
    for hero in world.heroes:
      hero.totalXp = 2000
    capped.level = HeroMaxLevel
    distant.state = Marching
    distant.hp = distant.maxHp
    if creepLastHit:
      var creep = Footman(
        id: 50_000, team: attacker, lane: 1, hp: FootmanHp,
        state: Fighting, swingClip: attackClips[0],
        swingTicks: footmanHitTicks(attackClips[0]) - 1,
        targetId: fort.id, attackingFort: true
      )
      creep.place(fort.center)
      creep.waypointIndex = creep.creepWaypoints().len
      world.footmen.add creep
    else:
      killer.state = Fighting
      killer.hp = killer.maxHp
      killer.place(fort.center)
      killer.attackObjectId = fort.id
      killer.swingClip = heroAttackClips[0]
      killer.swingTicks = world.heroHitTicks(killer) - 1
    let before = world.clone()
    game.tickWorld(nil)
    doAssert world.gameOver and not world.draw
    doAssert world.winner == attacker
    doAssert world.forts[defender.ord].hp == 0
    let finalScores = scores(world.totalXp(), world.tick.int, world.scores())
    for i, hero in world.heroes:
      let reward = if hero.team == attacker: 1000 else: 0
      doAssert hero.totalXp == 2000 + reward
      doAssert finalScores[i] == (if hero.team == attacker: 600 else: 0)
      doAssert hero.gold == before.heroes[i].gold
      if before.heroes[i].state == Dying:
        doAssert hero.state == Dying and hero.hp == 0
    doAssert capped.level == HeroMaxLevel and capped.xp == 1000
    when defined(replayEvents):
      var rewards = 0
      for event in world.events:
        if event.kind == XpGained:
          inc rewards
          doAssert event.cause == GodDestroyed
          doAssert event.actor.id == fort.id
          doAssert event.target.team == attacker.ord
          doAssert event.amount == 1000
          doAssert event.before == 2000 and event.after == 3000
          doAssert event.related >= 0
          doAssert world.events[event.related].kind == Death
          doAssert world.events[event.related].target.id == fort.id
      doAssert rewards == 5
      doAssert world.events[^1].kind == MatchEnded
    let finalHash = game.stateHash()
    game.tickWorld(nil)
    doAssert game.stateHash() == finalHash
    world.restore(before)
    game.tickWorld(nil)
    doAssert game.stateHash() == finalHash

echo "Testing timeouts grant no god XP and simultaneous god deaths pay both teams"
for draw in [false, true]:
  let
    game = quietGame()
    world = game.world
  if draw:
    for fort in world.forts.mitems:
      fort.hp = 0
  else:
    world.tick = game.config.maxTicks - 1
  game.tickWorld(nil)
  doAssert game.finished()
  doAssert world.draw == draw
  for hero in world.heroes:
    doAssert hero.totalXp == (if draw: 1000 else: 0)

echo "God guards and rewards passed"
