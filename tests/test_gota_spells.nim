import
  polyworld/[fxshapes, pathing],
  ../examples/gods_of_the_arena/[content, controls, maps, replays, sim]

proc spellGame(class: HeroClass): Game =
  ## Creates a quiet arena where only explicit test casts can deal damage.
  result = newGame(
    generateMap(2026),
    240,
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
  for tower in result.world.buildings.mitems:
    tower.hp = 0
  let hero = result.world.heroes[0]
  hero.class = class
  hero.abilityLevels = [1'i32, 1, 1, 1]
  hero.spellsReady = false
  hero.refreshHeroStats()
  hero.state = Marching
  hero.hp = hero.maxHp
  hero.mana = 10_000
  hero.maxMana = 10_000
  hero.place(result.world.forts[0].center)

proc step(game: Game, ticks = 1) =
  ## Advances real ticks while suppressing unrelated idle basic attacks.
  for i in 0 ..< ticks:
    for hero in game.world.heroes:
      hero.hasMoveTarget = true
      hero.attackObjectId = 0
    game.tickWorld(nil)

proc target(game: Game, index: int, offset: int32, ally = false): Hero =
  ## Places a stationary target in sight of the caster.
  result = game.world.heroes[index]
  result.class = Ranger
  result.state = Marching
  result.hp = 10_000
  result.maxHp = 20_000
  result.team = if ally: game.world.heroes[0].team else: BlueTeam
  var point = game.world.heroes[0].position
  point.z += offset
  result.place(point)

proc ground(game: Game, slot: HeroAbilitySlot, tiles = 0'i32): bool =
  ## Aims a spell at the caster's tile or farther along positive Z.
  let hero = game.world.heroes[0]
  game.world.applyCastPoint(
    hero.id, int32(slot),
    mapCoordinate(hero.position.x),
    mapCoordinate(hero.position.z) + tiles
  )

echo "Testing self and melee keys cast without a confirmation click"
block:
  let
    game = spellGame(VanguardKnight)
    hero = game.world.heroes[0]
    x = mapCoordinate(hero.position.x)
    y = mapCoordinate(hero.position.z) + 2
  game.step()
  hero.hp -= 50
  let hp = hero.hp
  doAssert activatePlayerAbility(
    game.world, hero.id, int32(PassiveAbility), hero.id, x, y
  )
  doAssert hero.hp == hp
  flushPlayerCommands(game)
  doAssert hero.hp > hp
  doAssert game.world.casts[^1].targetId == hero.id
  doAssert activatePlayerAbility(
    game.world, hero.id, int32(PrimaryAbility), hero.id, x, y
  )
  flushPlayerCommands(game)
  doAssert game.world.casts.len == 2
  doAssert game.world.casts[^1].ability == FirebrandSword
  doAssert game.world.casts[^1].targetId == 0
  doAssert hero.charges[PrimaryAbility] == 2
  doAssert armedAbility == -1

echo "Testing melee keys strike nearby targets and swing at distant targets"
for distance in [60_000'i32, 180_000'i32]:
  let
    game = spellGame(VanguardKnight)
    hero = game.world.heroes[0]
    enemy = game.target(5, distance)
  game.step()
  hero.attackObjectId = enemy.id
  doAssert activatePlayerAbility(
    game.world, hero.id, int32(PrimaryAbility), hero.id, 0, 0
  )
  flushPlayerCommands(game)
  doAssert game.world.casts.len == 1
  if distance < FirebrandSword.abilitySpec.range:
    doAssert game.world.casts[0].targetId == enemy.id
    doAssert enemy.hp == 10_000 - FirebrandSword.abilitySpec.damage
  else:
    doAssert game.world.casts[0].targetId == 0
    doAssert enemy.hp == 10_000

echo "Testing every Ranger key uses the same existing combat target"
block:
  let
    game = spellGame(Ranger)
    hero = game.world.heroes[0]
    enemy = game.target(5, 60_000)
  game.step()
  hero.attackObjectId = enemy.id
  for slot in HeroAbilitySlot:
    doAssert activatePlayerAbility(
      game.world, hero.id, int32(slot), hero.id, 0, 0
    )
    doAssert armedAbility == -1
  doAssert game.world.casts.len == 0
  flushPlayerCommands(game)
  doAssert game.world.casts.len == 4
  doAssert hero.attackObjectId == enemy.id
  for spell in game.world.casts:
    if spell.ability.abilitySpec.casting == ProjectileCast:
      doAssert spell.targetId == enemy.id
    else:
      doAssert spell.spellContains(spell.ability.abilitySpec.area, enemy.position)

echo "Testing selected allies receive healing despite an enemy combat target"
block:
  let
    game = spellGame(DruidWarden)
    hero = game.world.heroes[0]
    ally = game.target(1, 60_000, true)
    enemy = game.target(5, 90_000)
  game.step()
  hero.attackObjectId = enemy.id
  doAssert activatePlayerAbility(
    game.world, hero.id, int32(PrimaryAbility), ally.id, 0, 0
  )
  flushPlayerCommands(game)
  doAssert game.world.casts.len == 1
  doAssert game.world.casts[0].position == ally.position

echo "Testing missing or dead targets leave ranged abilities armed"
block:
  let
    game = spellGame(Ranger)
    hero = game.world.heroes[0]
    enemy = game.target(5, 60_000)
  game.step()
  let mana = hero.mana
  doAssert not activatePlayerAbility(
    game.world, hero.id, int32(PrimaryAbility), hero.id, 0, 0
  )
  doAssert armedAbility == int32(PrimaryAbility)
  enemy.state = Dying
  hero.attackObjectId = enemy.id
  doAssert not activatePlayerAbility(
    game.world, hero.id, int32(UltimateAbility), enemy.id, 0, 0
  )
  doAssert armedAbility == int32(UltimateAbility)
  flushPlayerCommands(game)
  doAssert game.world.casts.len == 0
  doAssert hero.mana == mana
  doAssert hero.charges[PrimaryAbility] == 3
  armedAbility = -1

echo "Testing the six gameplay footprints independently of visual effects"
for shape in FootprintShape:
  let area = FxArea(
    shape: shape, radius: 100, innerRadius: 25, width: 60,
    length: 100, height: 100, angle: 90
  )
  doAssert area.contains(0, 50, 0), $shape
  doAssert not area.contains(500, 500, 0), $shape
  doAssert not area.contains(0, 50, 60), $shape
  if shape in {
    RingFootprint, SectorFootprint
  }:
    doAssert not area.contains(0, 0, 0), $shape
  if shape == SectorFootprint:
    doAssert not area.contains(0, -50, 0), $shape

block:
  let area = FxArea(shape: SectorFootprint, radius: 100, height: 100, angle: 90)
  doAssert area.contains(50, 50, 0)
  doAssert not area.contains(51, 49, 0)

echo "Testing arc and cone effects share a sector footprint"
block:
  let
    arc = BlazingBlade.abilitySpec
    cone = GaleSlash.abilitySpec
  doAssert arc.effect == ArcShape
  doAssert cone.effect == AoeConeShape
  doAssert arc.area.shape == SectorFootprint
  doAssert cone.area.shape == SectorFootprint
  var footprint = arc.area
  footprint.radius = cone.area.radius
  footprint.length = cone.area.length
  doAssert footprint == cone.area

echo "Testing three charges, two-second cooldown, serial twelve-second recharge"
block:
  let
    game = spellGame(VanguardKnight)
    hero = game.world.heroes[0]
    slot = PrimaryAbility
  doAssert game.ground(slot)
  doAssert hero.charges[slot] == 2
  doAssert hero.cooldowns[slot] == 48 and hero.recharges[slot] == 288
  let mana = hero.mana
  doAssert not game.ground(slot)
  doAssert hero.mana == mana
  game.step(47)
  doAssert not game.ground(slot)
  game.step()
  doAssert game.ground(slot)
  doAssert hero.charges[slot] == 1 and hero.recharges[slot] == 240
  game.step(48)
  doAssert game.ground(slot)
  doAssert hero.charges[slot] == 0 and hero.recharges[slot] == 192
  game.step(48)
  doAssert not game.ground(slot)
  game.step(143)
  doAssert hero.charges[slot] == 0
  game.step()
  doAssert hero.charges[slot] == 1 and hero.recharges[slot] == 288
  game.step(288)
  doAssert hero.charges[slot] == 2 and hero.recharges[slot] == 288
  game.step(288)
  doAssert hero.charges[slot] == 3 and hero.recharges[slot] == 0

block:
  let
    game = spellGame(Ranger)
    hero = game.world.heroes[0]
  doAssert game.ground(PrimaryAbility)
  game.step(288)
  doAssert hero.charges[PrimaryAbility] == 3
  doAssert game.ground(PrimaryAbility)
  doAssert hero.recharges[PrimaryAbility] == 288

echo "Testing a delayed circle hits occupants at impact, not at cast time"
block:
  let
    game = spellGame(Arcanist)
    hero = game.world.heroes[0]
    first = game.target(5, 90_000)
    second = game.target(6, 120_000)
    escaped = game.target(7, 150_000)
    spec = MeteorStrike.abilitySpec
  game.step()
  doAssert game.world.applyCastTarget(hero.id, int32(SecondaryAbility), first.id)
  doAssert game.world.casts.len == 1 and not game.world.casts[0].resolved
  doAssert first.hp == 10_000 and second.hp == 10_000
  var away = escaped.position
  away.x += 300_000
  escaped.place(away)
  game.step(int(spec.castTicks) - 1)
  doAssert first.hp == 10_000
  game.step()
  doAssert first.hp == 10_000 - spec.damage
  doAssert second.hp == 10_000 - spec.damage
  doAssert escaped.hp == 10_000
  game.step(12)
  doAssert game.world.casts.len == 0
  doAssert first.hp == 10_000 - spec.damage

echo "Testing targeted projectiles only hit their selected object"
block:
  let
    game = spellGame(Ranger)
    hero = game.world.heroes[0]
    first = game.target(5, 90_000)
    second = game.target(6, 120_000)
  game.step()
  doAssert game.world.applyCastTarget(hero.id, int32(PrimaryAbility), first.id)
  doAssert first.hp == 10_000
  game.step(12)
  doAssert first.hp == 10_000 - VerdantArrow.abilitySpec.damage
  doAssert second.hp == 10_000

echo "Testing empty-ground melee and projectile casts produce effects"
for class in [VanguardKnight, Ranger]:
  let game = spellGame(class)
  doAssert game.ground(PrimaryAbility)
  doAssert game.world.casts.len == 1
  doAssert game.world.casts[0].targetId == 0
  doAssert game.world.heroes[0].charges[PrimaryAbility] == 2

echo "Testing ground projectiles stop at the first enemy during travel"
block:
  let
    game = spellGame(Ranger)
    near = game.target(5, 75_000)
    far = game.target(6, 210_000)
  game.step()
  doAssert game.ground(PrimaryAbility, 5)
  game.step(2)
  doAssert near.hp == 10_000 - VerdantArrow.abilitySpec.damage
  doAssert far.hp == 10_000
  doAssert game.world.casts[0].resolved
  game.step(10)
  doAssert far.hp == 10_000

echo "Testing a projectile cannot hit an already traversed part of its path"
block:
  let game = spellGame(Ranger)
  doAssert game.ground(PrimaryAbility, 5)
  game.step(4)
  let behind = game.target(5, 60_000)
  game.step(8)
  doAssert behind.hp == 10_000

echo "Testing lines and cones hit multiple enemies and exclude their sides"
for (class, slot) in [
  (DemonHunter, SecondaryAbility), (Ranger, UltimateAbility)
]:
  let
    game = spellGame(class)
    hero = game.world.heroes[0]
    spec = heroAbility(class, slot).abilitySpec
    first = game.target(5, 45_000)
    second = game.target(6, 100_000)
    side = game.target(7, 60_000)
  var outside = side.position
  outside.x += 400_000
  side.place(outside)
  game.step()
  doAssert game.world.applyCastTarget(hero.id, int32(slot), first.id)
  game.step(int(spec.castTicks))
  doAssert first.hp == 10_000 - spec.damage
  doAssert second.hp == 10_000 - spec.damage
  doAssert side.hp == 10_000

echo "Testing targeted rings place the selected enemy inside their band"
block:
  let
    game = spellGame(Lich)
    hero = game.world.heroes[0]
    other = game.target(5, 150_000)
    spec = BoundVoid.abilitySpec
  game.step()
  doAssert game.world.applyCastTarget(hero.id, int32(UltimateAbility), other.id)
  doAssert game.world.casts[0].spellContains(spec.area, other.position)
  game.step(int(spec.castTicks))
  doAssert other.hp == 10_000 - spec.damage

echo "Testing ground areas respect protected towers"
block:
  let
    game = spellGame(Arcanist)
    hero = game.world.heroes[0]
  var inner = -1
  for i, tower in game.world.buildings.mpairs:
    if tower.team == BlueTeam and tower.lane == 0:
      tower.hp = tower.maxHp
      tower.attackTicks = 10000
      if tower.tier == InnerTower:
        inner = i
  doAssert inner >= 0
  hero.place(game.world.buildings[inner].position)
  game.step()
  let hp = game.world.buildings[inner].hp
  doAssert game.ground(SecondaryAbility)
  game.step(int(MeteorStrike.abilitySpec.castTicks))
  doAssert game.world.buildings[inner].hp == hp

echo "Testing area healing affects living allies and includes the caster"
block:
  let
    game = spellGame(VanguardKnight)
    hero = game.world.heroes[0]
    ally = game.target(1, 80_000, true)
    enemy = game.target(5, 110_000)
    corpse = game.world.heroes[2]
  hero.hp -= 100
  corpse.place(hero.position)
  let before = hero.hp
  game.step()
  doAssert game.ground(SecondaryAbility)
  game.step(int(InfernoAegis.abilitySpec.castTicks))
  doAssert hero.hp == before + InfernoAegis.abilitySpec.heal
  doAssert ally.hp == 10_000 + InfernoAegis.abilitySpec.heal
  doAssert enemy.hp == 10_000
  doAssert corpse.hp == 0 and corpse.state == Dying

echo "Testing Druid spells heal allies and damage enemies in one area"
for slot in [PrimaryAbility, SecondaryAbility]:
  for rank in [1'i32, 4'i32]:
    for aim in 0 .. 2:
      let
        game = spellGame(DruidWarden)
        hero = game.world.heroes[0]
        ally = game.target(1, WorldScale, true)
        enemy = game.target(5, WorldScale)
        outside = game.target(6, 5 * WorldScale)
        spec = heroAbility(DruidWarden, slot).abilitySpec(rank)
      hero.abilityLevels[slot] = rank
      hero.hp -= 100
      var creep = Footman(id: 1000, team: enemy.team, hp: 1000)
      creep.controls[StunControl].ends = 100_000
      creep.place(enemy.position)
      game.world.footmen.add creep
      game.step()
      let
        hp = hero.hp
        allyHp = ally.hp
        enemyHp = enemy.hp
        mana = hero.mana
      if aim == 0:
        doAssert activatePlayerAbility(
          game.world, hero.id, slot.ord.int32, enemy.id, 0, 0
        )
        flushPlayerCommands(game)
      elif aim == 1:
        doAssert game.world.applyCastTarget(hero.id, slot.ord.int32, ally.id)
      else:
        doAssert game.ground(slot, 1)
      doAssert hero.mana == mana - spec.manaCost
      game.step(spec.castTicks.int)
      doAssert hero.hp == min(hero.maxHp, hp + spec.heal)
      doAssert ally.hp == allyHp + spec.heal
      doAssert enemy.hp == enemyHp - spec.damage
      doAssert game.world.footmen[0].hp == 1000 - spec.damage
      doAssert outside.hp == 10_000
      game.step()
      doAssert enemy.hp == enemyHp - spec.damage
      doAssert ally.hp == allyHp + spec.heal

echo "Testing explicit target commands release delayed map casts"
block:
  let
    game = spellGame(Arcanist)
    hero = game.world.heroes[0]
    other = game.target(5, 90_000)
  hero.attackObjectId = other.id
  doAssert game.world.applyCastTarget(
    hero.id, UltimateAbility.ord.int32, other.id
  )
  game.tickWorld(nil)
  var pending = false
  for spell in game.world.casts:
    if spell.ability.abilitySpec.casting == AreaCast:
      doAssert spell.targetId == 0
      doAssert spell.impact > game.world.tick and not spell.resolved
      pending = true
  doAssert pending

echo "Testing explicit healing while walking without a combat target"
for (class, slot) in [
  (DruidWarden, PrimaryAbility),
  (DruidWarden, SecondaryAbility),
  (VanguardKnight, SecondaryAbility)
]:
  for healAlly in [false, true]:
    let
      game = spellGame(class)
      hero = game.world.heroes[0]
      patient = if healAlly: game.target(1, 60_000, true) else: hero
      ability = heroAbility(class, slot)
      spec = ability.abilitySpec
    game.step()
    patient.hp = patient.maxHp - 100
    for other in HeroAbilitySlot:
      hero.cooldowns[other] = 100_000
    hero.cooldowns[slot] = 0
    doAssert game.world.applyWalkTo(
      hero.id, mapCoordinate(hero.position.x) + 3,
      mapCoordinate(hero.position.z)
    )
    let
      hp = patient.hp
      mana = hero.mana
    doAssert game.world.applyCastTarget(hero.id, slot.ord.int32, patient.id)
    game.tickWorld(nil)
    doAssert hero.hasMoveTarget and hero.attackObjectId == 0
    doAssert game.world.casts.len == 1, $ability
    doAssert game.world.casts[0].ability == ability
    doAssert hero.charges[slot] == spec.charges - 1
    doAssert hero.mana == mana - spec.manaCost
    doAssert patient.hp == hp
    for tick in 0 ..< int(spec.castTicks):
      game.tickWorld(nil)
    doAssert patient.hp == hp + spec.heal, $ability

echo "Testing heroes never use abilities or items without an explicit command"
for class in HeroClass:
  for walking in [false, true]:
    let
      game = spellGame(class)
      hero = game.world.heroes[0]
      enemy = game.target(5, 60_000)
    discard game.target(1, 80_000, true)
    game.step()
    hero.hp = hero.maxHp div 2
    hero.mana = hero.maxMana div 2
    hero.inventory = [HealthPotion, VitalityElixir, ManaPotion,
      ManaElixir, PoisonPotion, PortalScroll]
    hero.itemCounts = [3'i32, 3, 3, 3, 3, 3]
    if walking:
      doAssert game.world.applyWalkTo(
        hero.id, mapCoordinate(hero.position.x) + 3,
        mapCoordinate(hero.position.z)
      )
    else:
      doAssert game.world.applyAttackTarget(hero.id, enemy.id)
    let
      charges = hero.charges
      items = hero.itemCounts
      mana = hero.mana
    for tick in 0 ..< TickRate:
      game.tickWorld(nil)
      doAssert game.world.casts.len == 0, $class
      doAssert hero.charges == charges, $class
      doAssert hero.cooldowns == default(array[HeroAbilitySlot, int32])
      doAssert hero.itemCounts == items, $class
      doAssert hero.recoveryItems == [NoItem, NoItem]
      doAssert hero.portalEnds == 0
      doAssert hero.mana >= mana, $class

echo "Testing zero-mana melee and rejected casts preserve resources"
block:
  let
    game = spellGame(Berserker)
    hero = game.world.heroes[0]
  hero.mana = 0
  doAssert game.ground(PrimaryAbility)
  doAssert hero.mana == 0
  let charges = hero.charges
  doAssert not game.ground(UltimateAbility)
  doAssert not game.world.applyCastTarget(hero.id, -1, hero.id)
  doAssert hero.mana == 0 and hero.charges == charges

echo "Testing every current ability consumes its declared resources"
for class in HeroClass:
  for slot in HeroAbilitySlot:
    let
      game = spellGame(class)
      hero = game.world.heroes[0]
      spec = heroAbility(class, slot).abilitySpec
      other = game.target(5, 60_000, spec.kind != Strike)
    hero.hp = max(1'i32, hero.hp - 50)
    hero.mana = 1000
    game.step()
    let mana = hero.mana
    let targetId = if spec.casting == SelfCast: hero.id else: other.id
    doAssert game.world.applyCastTarget(hero.id, int32(slot), targetId),
      $class & " " & $slot
    doAssert hero.charges[slot] == spec.charges - 1
    doAssert hero.cooldowns[slot] == spec.cooldownTicks
    doAssert hero.recharges[slot] == spec.rechargeTicks
    if spec.kind != Restore:
      doAssert hero.mana == mana - spec.manaCost
    else:
      doAssert hero.mana == min(hero.maxMana, mana + spec.restore)
    doAssert game.world.casts.len == 1

echo "Testing pending spells and charges survive cloning and affect hashes"
block:
  let
    game = spellGame(Arcanist)
    hero = game.world.heroes[0]
    other = game.target(5, 60_000)
  game.step()
  doAssert game.world.applyCastTarget(hero.id, int32(SecondaryAbility), other.id)
  let
    original = game.stateHash()
    snapshot = game.world.clone()
  game.step(10)
  doAssert game.stateHash() != original
  game.world.restore(snapshot)
  doAssert game.stateHash() == original
  inc hero.charges[PrimaryAbility]
  doAssert snapshot.heroes[0].charges != hero.charges

echo "GOTA spell tests passed"
