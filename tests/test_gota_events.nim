## Typed combat events and command diagnostics, including replay resimulation.

import
  std/[os, tempfiles],
  bassy,
  polyworld/[cli, metrics, pathing, tapes],
  ../examples/gods_of_the_arena/[bots, content, maps, replays, sim]

proc arena(): World =
  ## Creates visible opponents for exact damage and validation checks.
  result = World(
    stats: newCombatStats(3),
    heroes: @[
      Hero(id: 100, team: RedTeam, class: Ranger, level: 1, gold: 500),
      Hero(id: 105, team: BlueTeam, class: DruidWarden, level: 1),
      Hero(id: 101, team: RedTeam, class: DruidWarden, level: 1)
    ],
    footmen: @[Footman(id: 1000, team: BlueTeam, hp: 60)],
    buildings: @[
      Building(id: 10, team: BlueTeam, tier: OuterTower, hp: 950),
      Building(id: 11, team: BlueTeam, tier: InnerTower, hp: 1300),
      Building(id: 12, team: BlueTeam, guardsGod: true, hp: 1950)
    ],
    forts: [Fort(id: 1, team: RedTeam, hp: FortHp),
      Fort(id: 2, team: BlueTeam, hp: FortHp)]
  )
  for i, hero in result.heroes:
    hero.refreshHeroStats()
    hero.abilityLevels = [1'i32, 1, 1, 1]
    result.stats.teams[i] = hero.team.ord
    hero.inventory[0] = PoisonPotion
    hero.itemCounts[0] = 3
    hero.inventory[1] = VitalityElixir
    hero.itemCounts[1] = 3
  for team in Team:
    result.teamVisible[team.ord] = newSeq[uint8](mapTiles() * mapTiles())
    for cell in result.teamVisible[team.ord].mitems:
      cell = 255

proc count(world: World, kind: EventKind): int =
  ## Counts one event category without accumulating a full match history.
  for event in world.events:
    if event.kind == kind:
      inc result

proc last(world: World, kind: EventKind): GameEvent =
  ## Returns the latest expected record or fails the test.
  for i in countdown(world.events.high, 0):
    if world.events[i].kind == kind:
      return world.events[i]
  doAssert false, "Missing event " & $kind

proc error(world: World, expected: ActionError) =
  ## Checks the public diagnostic and the corresponding raw rejection record.
  doAssert world.heroes[0].lastActionError == expected,
    "Expected " & $expected & ", got " & $world.heroes[0].lastActionError
  let event = world.last(ActionRejected)
  doAssert event.error == expected and event.actor.id == 100

echo "Testing exact multiple hits, healing, overkill, assists and reward links"
block:
  let
    world = arena()
    hero = world.heroes[0]
    victim = world.heroes[1]
    ally = world.heroes[2]
    strike = PoisonPotion.itemSpec.strike
  hero.attackObjectId = victim.id
  ally.attackObjectId = victim.id
  victim.hp = strike * 3
  doAssert world.applyUseItem(hero.id, 0)
  doAssert world.applyUseItem(ally.id, 0)
  doAssert world.applyUseItem(victim.id, 1)
  doAssert world.count(Damage) == 2 and world.count(Healing) == 1
  let heal = world.last(Healing)
  doAssert heal.amount > 0 and heal.target.id == victim.id
  victim.hp = 1
  hero.xp = 1000
  doAssert world.applyUseItem(hero.id, 0)
  let
    damage = world.last(Damage)
    death = world.last(Death)
    reward = world.last(XpGained)
  doAssert damage.requested == strike and damage.amount == 1
  doAssert damage.before == 1 and damage.after == 1 - strike
  doAssert death.actor.id == hero.id and death.target.id == victim.id
  doAssert world.events[death.related].kind == Damage
  doAssert world.events[reward.related].kind == Death
  doAssert reward.actor.id == victim.id and reward.target.id == hero.id
  doAssert reward.amount == 150 and world.last(GoldGained).amount == 100
  doAssert world.count(LevelChanged) > 1
  doAssert world.count(HealthAdjusted) == world.count(LevelChanged)
  doAssert world.count(Death) == 1 and world.count(Assist) == 1
  doAssert world.last(Assist).actor.id == ally.id
  doAssert not world.applyUseItem(hero.id, 0)
  doAssert world.count(Death) == 1

echo "Testing doubled building XP for every structure kind and tower tier"
for kind in BuildingKind:
  for tier in TowerTier:
    let
      world = arena()
      hero = world.heroes[0]
      gold = hero.gold
    world.buildings.setLen(1)
    world.buildings[0].kind = kind
    world.buildings[0].tier = tier
    world.buildings[0].hp = 1
    hero.attackObjectId = world.buildings[0].id
    doAssert world.applyUseItem(hero.id, 0)
    doAssert hero.totalXp == 200
    doAssert hero.gold == gold + 75
    doAssert world.heroes[1].totalXp == 0
    doAssert world.heroes[2].totalXp == 0
    doAssert world.count(XpGained) == 1
    doAssert world.last(XpGained).amount == 200
    doAssert world.last(XpGained).target.id == hero.id
    doAssert not world.applyUseItem(hero.id, 0)
    doAssert hero.totalXp == 200 and world.count(XpGained) == 1

echo "Testing invulnerable structures, tower kills and corpse metadata"
block:
  let world = arena()
  let hero = world.heroes[0]
  for id in [11'i32, 2'i32]:
    hero.attackObjectId = id
    doAssert not world.applyUseItem(hero.id, 0)
    doAssert world.count(Damage) == 0
  hero.attackObjectId = 10
  world.buildings[0].hp = 1
  doAssert world.applyUseItem(hero.id, 0)
  doAssert world.last(Death).target.kind == 4
  doAssert world.last(EntityRemoved).target.id == 10
  var tower = Building(id: 20, team: RedTeam, hp: 950, tier: OuterTower,
    targetId: 1000, attackTicks: TowerAttackTicks - 1)
  world.buildings.add tower
  world.footmen[0].hp = 1
  world.updateTower(world.buildings[^1])
  inc world.tick
  world.advanceTowerShots()
  doAssert world.last(Death).actor.id == 20
  doAssert world.last(Death).actor.kind == 4
  doAssert world.last(Death).target.kind == 3
  doAssert world.count(XpGained) == 3
  doAssert world.last(XpGained).cause == NearbyKill
  doAssert world.last(XpGained).amount == CreepNearbyXp div 2
  doAssert world.events[world.last(XpGained).related].kind == Death
  doAssert world.count(GoldGained) == 1

echo "Testing command validation order, raw arguments and hidden target privacy"
block:
  let world = arena()
  let hero = world.heroes[0]
  doAssert not world.applyCastTarget(hero.id, -200, 105)
  world.error(ActionInvalidSlot)
  doAssert world.last(ActionRejected).slot == -200
  doAssert not world.applyCastPoint(hero.id, 1, -1, 0)
  world.error(ActionInvalidPoint)
  doAssert not world.applyBuyItem(hero.id, -1)
  world.error(ActionUnknownItem)
  let
    shopGame = newGame(
      generateMap(54),
      100_000,
      10,
      false,
      ReplayData(),
      drafting = false
    )
    originalPosition = hero.position
  for team in Team:
    world.teamVisible[team.ord].setLen(mapTiles() * mapTiles())
  hero.place(shopGame.world.heroes[0].spawnPosition)
  hero.gold = 0
  doAssert not world.applyBuyItem(hero.id, VitalityElixir.ord.int32)
  world.error(ActionInsufficientGold)
  hero.gold = 1000
  doAssert world.applyBuyItem(hero.id, RangerBoots.ord.int32)
  doAssert hero.lastActionError == NoActionError
  doAssert world.last(GoldSpent).amount == -RangerBoots.itemSpec.cost
  doAssert not world.applyBuyItem(hero.id, RangerBoots.ord.int32)
  world.error(ActionAlreadyEquipped)
  doAssert not world.applyUseItem(hero.id, 2)
  world.error(ActionNotConsumable)
  doAssert not world.applyUseItem(hero.id, 99)
  world.error(ActionInvalidSlot)
  doAssert not world.applyUseItem(hero.id, 5)
  world.error(ActionEmptySlot)
  doAssert not world.applyUseItem(hero.id, 1)
  world.error(ActionFullHealth)
  hero.inventory[3] = ManaElixir
  hero.itemCounts[3] = 1
  doAssert not world.applyUseItem(hero.id, 3)
  world.error(ActionFullMana)
  hero.itemCounts[1] = MaxItemStack
  doAssert not world.applyBuyItem(hero.id, VitalityElixir.ord.int32)
  world.error(ActionStackFull)
  for slot in 0 ..< InventorySlots:
    hero.inventory[slot] = HealthPotion
    hero.itemCounts[slot] = 1
  doAssert not world.applyBuyItem(hero.id, ManaElixir.ord.int32)
  world.error(ActionInventoryFull)
  hero.place(originalPosition)
  hero.spellsReady = true
  hero.cooldowns[PrimaryAbility] = 1
  hero.charges[PrimaryAbility] = 0
  hero.mana = 0
  doAssert not world.applyCastTarget(hero.id, 1, 105)
  world.error(ActionCooldown)
  hero.cooldowns[PrimaryAbility] = 0
  doAssert not world.applyCastTarget(hero.id, 1, 105)
  world.error(ActionNoCharges)
  hero.charges[PrimaryAbility] = 1
  doAssert not world.applyCastTarget(hero.id, 1, 105)
  world.error(ActionInsufficientMana)
  hero.mana = 1000
  world.casts.setLen(512)
  doAssert not world.applyCastTarget(hero.id, 1, 105)
  world.error(ActionSpellLimit)
  world.casts.setLen(0)
  for cell in world.teamVisible[RedTeam.ord].mitems:
    cell = 0
  doAssert not world.applyCastTarget(hero.id, 1, 105)
  world.error(ActionTargetUnavailable)
  doAssert not world.applyCastTarget(hero.id, 1, 99999)
  world.error(ActionTargetUnavailable)
  for cell in world.teamVisible[RedTeam.ord].mitems:
    cell = 255
  world.heroes[1].position.x =
    heroAbility(hero.class, PrimaryAbility).abilitySpec.range + 1
  doAssert not world.applyCastTarget(hero.id, 1, 105)
  world.error(ActionOutOfRange)
  hero.state = Dying
  doAssert not world.applyAttackTarget(hero.id, 0)
  world.error(ActionNotAlive)
  hero.state = Marching
  doAssert world.applyAttackTarget(hero.id, 0)
  doAssert hero.lastActionError == NoActionError

proc quietGame(class: HeroClass): Game =
  ## Keeps only explicit test combat active on a real generated map.
  result = newGame(
    generateMap(54),
    240,
    10,
    false,
    ReplayData(),
    drafting = false
  )
  result.world.camps.setLen(0)
  result.world.spawnTimerTicks = 100_000
  result.world.heroTurnTicks = 100_000
  for hero in result.world.heroes:
    hero.hp = 0
    hero.state = Dying
    hero.deathTicks = -100_000
  for building in result.world.buildings.mitems:
    building.hp = 0
  let hero = result.world.heroes[0]
  hero.class = class
  hero.refreshHeroStats()
  hero.hp = hero.maxHp
  hero.mana = 10_000
  hero.maxMana = 10_000
  hero.place(result.world.forts[0].center)
  hero.state = Marching
  hero.spellsReady = false
  hero.abilityLevels = [1'i32, 1, 1, 1]

proc quietStep(game: Game) =
  ## Suppresses unrelated idle attacks while allowing spell impacts and regen.
  for hero in game.world.heroes:
    hero.hasMoveTarget = true
    hero.attackObjectId = 0
  game.tickWorld(nil)

echo "Testing delayed and area damage, regeneration and command errors"
for class in [Arcanist, Ranger]:
  let
    game = quietGame(class)
    world = game.world
    hero = world.heroes[0]
    slot = if class == Arcanist: SecondaryAbility else: PrimaryAbility
    ability = heroAbility(class, slot)
  for index in [5, 6]:
    let target = world.heroes[index]
    target.hp = 10_000
    target.maxHp = 10_000
    target.state = Marching
    var point = hero.position
    point.z += 90_000 + int32(index - 5) * 30_000
    target.place(point)
  game.quietStep()
  doAssert world.applyCastTarget(hero.id, slot.ord.int32, world.heroes[5].id)
  doAssert world.last(SpellReleased).detail == ability.ord
  doAssert world.count(Damage) == 0
  doAssert world.last(ManaChanged).cause == AbilityEffect
  var hits = 0
  for tick in 0 ..< 80:
    game.quietStep()
    for event in world.events:
      if event.kind == Damage:
        doAssert event.cause == AbilityEffect
        doAssert event.detail == ability.ord and event.actor.id == hero.id
        doAssert event.amount == ability.abilitySpec.damage
        inc hits
  doAssert hits == (if class == Arcanist: 2 else: 1)
  hero.mana = 0
  doAssert not world.applyCastTarget(hero.id, -7, hero.id)
  var regenerated = 0
  for tick in 0 ..< 6:
    game.quietStep()
    for event in world.events:
      if event.kind == ManaChanged and event.cause == Regeneration and
        event.target.id == hero.id:
          regenerated += event.amount.int
    doAssert world.count(ActionRejected) == 0
    doAssert hero.lastActionError == ActionInvalidSlot
  doAssert regenerated == 1 and hero.mana >= 1
  let savedPosition = hero.position
  hero.position.x = int32.high div 2
  doAssert not world.applyWalkTo(hero.id, 0, 0)
  world.error(ActionNoRoute)
  hero.position = savedPosition

echo "Testing creep last hits, death versus removal and repeated hero lives"
block:
  let
    game = quietGame(Ranger)
    world = game.world
    hero = world.heroes[0]
  hero.hp = 1
  var creep = Footman(id: 9000, team: BlueTeam, lane: 0, hp: 60,
    swingTicks: 13)
  creep.place(hero.position)
  world.footmen.add creep
  game.tickWorld(nil)
  doAssert world.last(Death).actor.id == creep.id
  doAssert world.last(Death).target.id == hero.id
  doAssert world.count(XpGained) == 0
  world.footmen[0].state = Dying
  world.footmen[0].hp = 0
  world.footmen[0].deathTicks = 83
  game.tickWorld(nil)
  doAssert world.last(EntityRemoved).target.id == creep.id
  doAssert world.last(EntityRemoved).target.team == BlueTeam.ord
  doAssert world.count(Death) == 0 and world.footmen.len == 0
  for life in 0 .. 1:
    hero.state = Dying
    hero.hp = 0
    hero.deathTicks = 24 + 8 * TickRate - 1
    game.tickWorld(nil)
    doAssert world.count(EntityRespawned) == 1
    doAssert world.last(EntityRespawned).target.id == hero.id
    doAssert hero.hp == hero.maxHp
    doAssert world.count(Healing) == 0
    game.quietStep()
    doAssert world.count(EntityRespawned) == 0

echo "Testing buyback spending, respawn, and duplicate rejection events"
block:
  let
    game = quietGame(Ranger)
    world = game.world
    hero = world.heroes[0]
  hero.hp = 0
  game.tickWorld(nil)
  doAssert hero.deaths == 1
  hero.gold = 100
  doAssert world.applyBuyback(hero.id)
  doAssert world.count(GoldSpent) == 1
  doAssert world.last(GoldSpent).cause == Buyback
  doAssert world.last(GoldSpent).amount == -100
  doAssert world.last(GoldSpent).before == 100
  doAssert world.last(GoldSpent).after == 0
  doAssert world.count(EntityRespawned) == 1
  doAssert world.last(EntityRespawned).target.id == hero.id
  doAssert not world.applyBuyback(hero.id)
  world.error(ActionNotDead)
  doAssert world.last(ActionRejected).action == ActionBuyback
  doAssert world.count(GoldSpent) == 1

echo "Testing initialization, tick boundaries, host queries and replay events"
block:
  let
    directory = createTempDir("gota-events-", "")
    path = directory / "diagnostics.bas"
    game = newGame(
      generateMap(54),
      240,
      10,
      false,
      ReplayData(),
      drafting = false
    )
    world = game.world
  defer:
    removeDir(directory)
  const Policy = """
rejected = castPoint(-7, selfX + 0.25, selfY - 0.25)
reason = lastActionError()
query = objectCount()
unchanged = lastActionError() = reason and reason = ActionInvalidSlot
accepted = attackMove(mapWidth / 2, mapHeight / 2)
cleared = lastActionError() = NoActionError
if selfHp = 0 then
  cleared = lastActionError() = ActionNotAlive
end if
"""
  writeFile(path, Policy)
  game.loadBots([BotGroup(path: path, count: 10)])
  game.recorder = initReplayRecorder(game.currentSetup(900), game.map.preset)
  let initial = world.clone()
  doAssert initial.events.len == 0
  doAssert world.events.len == 46
  for event in world.events:
    doAssert event.kind == EntitySpawned and event.tick == 0
  var
    expected: seq[seq[GameEvent]]
    peak = 0
  for tick in 1 .. 900:
    game.tickWorld(proc() = game.runBotDecisions())
    for event in world.events:
      doAssert event.tick == tick
      if event.kind == ActionRejected:
        if event.action == ActionCastPoint:
          doAssert event.slot == -7 and event.error == ActionInvalidSlot
          doAssert event.offsetX == 16384 and event.offsetY == -16384
        else:
          doAssert event.action == ActionAttackMove
          doAssert event.error == ActionNotAlive
          doAssert world.heroById(event.actor.id).hp <= 0
    peak = max(peak, world.events.len)
    expected.add world.events
  doAssert peak < 1000
  doAssert world.events.len < 1000
  doAssert game.recorder.data.actions[0].slot == -7
  for vm in game.heroVms:
    doAssert not vm.failed, vm.lastError
    doAssert vm.runtime.getGlobal("unchanged") != 0
    doAssert vm.runtime.getGlobal("cleared") != 0
  let replay = decodeReplay(encodeReplay(game.recorder.data))
  let playback = newGame(
    generateMap(replay.config.seed, replay.config.mapPreset),
    replay.config.spawnIntervalTicks, 0, true, replay
  )
  playback.historyPlayback = true
  playback.replayPlayer = initReplayPlayer(replay)
  for tick in 0 ..< replay.hashes.len:
    playback.tickWorld(nil)
    doAssert playback.hashCheck.mismatches == 0
    doAssert playback.world.events == expected[tick], "Events at " & $tick
  doAssert playback.replayPlayer.finished
  playback.world.restore(initial)
  doAssert playback.world.events.len == 0
  let hero = playback.world.heroes[0]
  doAssert not playback.world.applyCastTarget(hero.id, -1, hero.id)
  let snapshot = playback.world.clone()
  doAssert snapshot.events.len == 0
  doAssert snapshot.heroes[0].lastActionError == ActionInvalidSlot
  doAssert playback.world.applyAttackTarget(hero.id, 0)
  playback.world.restore(snapshot)
  doAssert playback.world.heroes[0].lastActionError == ActionInvalidSlot
  doAssert playback.world.events.len == 0
  createDir("tmp")
  saveReplay("tmp/events-example.replay", replay)

echo "test_gota_events: all checks passed"
