import
  polyworld/pathing,
  ../examples/gods_of_the_arena/[content, maps, replays, sim]

proc arena(team = RedTeam, tier = OuterTower): Game =
  ## Isolates one tower and an enemy hero for deterministic combat checks.
  result = newGame(generateMap(54), 100_000, 10, false,
    ReplayData(), drafting = false)
  let world = result.world
  world.tick = 100
  world.camps.setLen(0)
  world.footmen.setLen(0)
  for hero in world.heroes:
    hero.hp = 0
    hero.state = Dying
    hero.deathTicks = -100_000
  world.buildings = @[
    Building(id: 10, kind: TowerBuilding, team: team, tier: tier,
      hp: 1000, maxHp: 1000, position: WorldPoint())
  ]
  for cells in world.teamVisible.mitems:
    for cell in cells.mitems:
      cell = 255
  let hero = world.heroes[(1 - team.ord) * 5]
  hero.hp = 1000
  hero.state = Marching
  hero.place(WorldPoint(x: 5 * WorldScale))

proc advance(world: World, ticks = 1) =
  ## Advances tower reload and projectile travel without moving the test actors.
  for i in 0 ..< ticks:
    inc world.tick
    for tower in world.buildings.mitems:
      world.updateTower(tower)
    world.advanceTowerShots()

proc impact(world: World) =
  ## Waits for the first launched shot to arrive, failing on a stuck projectile.
  let limit = world.tick + 200
  while world.towerShots.len > 0 and world.towerShots[0].impact == 0:
    inc world.tick
    world.advanceTowerShots()
    doAssert world.tick < limit

echo "Testing tower range covers the longest hero attack plus its footprint"
block:
  let game = newGame(generateMap(54), 100_000, 0, false, ReplayData())
  var longest = 0'i32
  for class in HeroClass:
    longest = max(longest, class.heroAttackRange())
  for tower in game.world.buildings:
    if tower.kind != TowerBuilding:
      continue
    for tile in tower.footprint:
      let point = pathPoint(tile.layer.int, tile.x.int, tile.z.int)
      for dx in [-WorldScale div 2, WorldScale div 2]:
        for dz in [-WorldScale div 2, WorldScale div 2]:
          let corner = WorldPoint(
            x: point.x * (WorldScale div PathUnitsPerTile) + dx,
            z: point.z * (WorldScale div PathUnitsPerTile) + dz
          )
          doAssert within(tower.position, corner,
            TowerAttackRanges[tower.tier] - longest - WorldScale div 4)

echo "Testing exact range boundaries and delayed damage for both teams"
for team in Team:
  for tier in TowerTier:
    let
      game = arena(team, tier)
      world = game.world
      hero = world.heroes[(1 - team.ord) * 5]
      direction = if team == RedTeam: 1'i32 else: -1'i32
    hero.place(WorldPoint(x: direction * (TowerAttackRanges[tier] + 1)))
    world.advance(TowerAttackTicks.int)
    doAssert world.towerShots.len == 0
    hero.place(WorldPoint(x: direction * TowerAttackRanges[tier]))
    world.advance()
    doAssert world.towerShots.len == 1
    doAssert hero.hp == 1000, "damage must wait for projectile arrival"
    world.impact()
    doAssert hero.hp == 1000 - TowerDamages[tier]

echo "Testing dipping out of range and changing targets do not reset reload"
block:
  let
    game = arena()
    world = game.world
    hero = world.heroes[5]
    replacement = world.heroes[6]
  world.advance(10)
  doAssert world.buildings[0].attackTicks == 10
  hero.place(WorldPoint(x: 20 * WorldScale))
  world.advance(10)
  doAssert world.buildings[0].targetId == 0
  doAssert world.buildings[0].attackTicks == 20
  replacement.hp = 1000
  replacement.state = Marching
  replacement.place(WorldPoint(x: 5 * WorldScale))
  world.advance(4)
  doAssert world.towerShots.len == 1
  doAssert world.towerShots[0].targetId == replacement.id
  replacement.place(WorldPoint(x: 20 * WorldScale))
  world.advance(TowerAttackTicks.int)
  doAssert world.buildings[0].attackTicks == TowerAttackTicks
  hero.place(WorldPoint(x: 5 * WorldScale))
  world.advance()
  doAssert world.towerShots[^1].targetId == hero.id
  doAssert world.towerShots[^1].started == world.tick

echo "Testing a fired shot follows a hidden escaping target after its tower dies"
for team in Team:
  let
    game = arena(team)
    world = game.world
    hero = world.heroes[(1 - team.ord) * 5]
  world.advance(TowerAttackTicks.int)
  doAssert world.towerShots.len == 1
  let origin = world.towerShots[0].position
  hero.place(WorldPoint(x: -25 * WorldScale, z: 8 * WorldScale))
  world.buildings[0].hp = 0
  for cell in world.teamVisible[team.ord].mitems:
    cell = 0
  world.advance()
  doAssert world.towerShots[0].position.x < origin.x
  doAssert world.towerShots[0].position.z > origin.z
  doAssert hero.hp == 1000
  world.impact()
  doAssert hero.hp == 1000 - TowerDamages[OuterTower]
  for i in 0 ..< TowerImpactTicks:
    inc world.tick
    world.advanceTowerShots()
  doAssert world.towerShots.len == 0
  doAssert hero.hp == 1000 - TowerDamages[OuterTower]

echo "Testing dead targets cancel shots instead of hitting a replacement or respawn"
block:
  let
    game = arena()
    world = game.world
    hero = world.heroes[5]
  world.advance(TowerAttackTicks.int)
  hero.hp = 0
  hero.state = Dying
  inc world.tick
  world.advanceTowerShots()
  doAssert world.towerShots.len == 0
  hero.hp = 1000
  hero.state = Marching
  inc world.tick
  world.advanceTowerShots()
  doAssert hero.hp == 1000

echo "Testing projectile snapshots and hashes restore mid-flight and impact state"
block:
  let
    game = arena()
    world = game.world
  world.advance(TowerAttackTicks.int + 2)
  let
    snapshot = world.clone()
    saved = game.stateHash()
  inc world.towerShots[0].damage
  doAssert game.stateHash() != saved
  world.restore(snapshot)
  doAssert game.stateHash() == saved
  world.impact()
  let expected = game.stateHash()
  doAssert snapshot.towerShots[0].impact == 0
  world.restore(snapshot)
  world.impact()
  doAssert game.stateHash() == expected

echo "test_gota_towers: all checks passed"
