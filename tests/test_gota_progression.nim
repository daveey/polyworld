import
  std/[os, tempfiles],
  bassy,
  polyworld/[cli, tapes],
  ../examples/gods_of_the_arena/[bots, content, controls, maps, replays, sim]

proc quietGame(class = VanguardKnight): Game =
  ## Creates a quiet arena with one living hero and no automatic casts.
  result = newGame(
    generateMap(54),
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
    hero.hp = 0
    hero.deathTicks = -100_000
  for building in result.world.buildings.mitems:
    building.hp = 0
  let hero = result.world.heroes[0]
  hero.class = class
  hero.refreshHeroStats()
  hero.state = Marching
  hero.hp = hero.maxHp
  hero.mana = 10_000
  hero.maxMana = 10_000
  hero.place(result.world.forts[0].center)

proc step(game: Game, ticks = 1) =
  ## Advances spell impacts and respawns without unrelated basic attacks.
  for i in 0 ..< ticks:
    for hero in game.world.heroes:
      hero.hasMoveTarget = true
      hero.attackObjectId = 0
    game.tickWorld(nil)

proc reject(world: World, slot: int32, error: ActionError) =
  ## Checks an invalid upgrade preserves points, ranks and spell resources.
  let
    hero = world.heroes[0]
    ranks = hero.abilityLevels
    points = hero.abilityPoints
    charges = hero.charges
    cooldowns = hero.cooldowns
    recharges = hero.recharges
    mana = hero.mana
  doAssert not world.applyLevelAbility(hero.id, slot)
  doAssert hero.lastActionError == error
  doAssert hero.abilityLevels == ranks and hero.abilityPoints == points
  doAssert hero.charges == charges and hero.cooldowns == cooldowns
  doAssert hero.recharges == recharges and hero.mana == mana

echo "Testing locked starts, explicit unlocks and atomic upgrade failures"
block:
  let
    game = quietGame()
    world = game.world
    hero = world.heroes[0]
  hero.hp -= 50
  game.step(50)
  doAssert hero.abilityPoints == 1
  doAssert hero.abilityLevels == [0'i32, 0, 0, 0]
  doAssert hero.charges == [0'i32, 0, 0, 0]
  doAssert world.casts.len == 0
  let mana = hero.mana
  doAssert not world.applyCastTarget(hero.id, 0, hero.id)
  doAssert hero.lastActionError == ActionAbilityLocked
  doAssert hero.mana == mana and hero.abilityPoints == 1
  world.reject(-1, ActionInvalidSlot)
  world.reject(int32.high, ActionInvalidSlot)
  world.reject(3, ActionHeroLevelRequired)
  doAssert not world.applyLevelAbility(-1, 0)
  doAssert world.applyLevelAbility(hero.id, 1)
  doAssert hero.abilityLevels[PrimaryAbility] == 1
  doAssert hero.charges[PrimaryAbility] == 3
  doAssert hero.abilityPoints == 0
  when defined(replayEvents):
    let event = world.events[^1]
    doAssert event.kind == AbilityLeveled
    doAssert event.actor.id == hero.id and event.detail == FirebrandSword.ord
    doAssert event.before == 0 and event.after == 1 and event.amount == 1
  world.reject(0, ActionNoAbilityPoints)
  hero.level = 2
  world.reject(1, ActionHeroLevelRequired)
  hero.state = Dying
  world.reject(0, ActionNotAlive)
  hero.state = Marching
  hero.hp = 0
  world.reject(0, ActionNotAlive)

echo "Testing rank gates and maximums across all hero levels"
block:
  let
    game = quietGame()
    world = game.world
    hero = world.heroes[0]
  for level in 1 .. HeroMaxLevel:
    hero.level = level
    let before = hero.abilityLevels
    game.step()
    doAssert hero.abilityLevels == before
    for slot in [UltimateAbility, PrimaryAbility, SecondaryAbility,
      PassiveAbility]:
        while hero.abilityLevelError(slot) == NoActionError:
          doAssert level >= slot.abilityRequiredLevel(
            hero.abilityLevels[slot] + 1
          )
          doAssert world.applyLevelAbility(hero.id, slot.ord.int32)
        doAssert hero.abilityLevels[slot] <= slot.abilityMaxLevel
  doAssert hero.abilityLevels == [4'i32, 4, 4, 3]
  doAssert hero.abilityPoints == HeroMaxLevel - 15
  for slot in HeroAbilitySlot:
    world.reject(slot.ord.int32, ActionAbilityMaxLevel)

echo "Testing ultimate gates at levels six, twelve and eighteen"
block:
  let
    game = quietGame()
    hero = game.world.heroes[0]
  for rank in 1'i32 .. 3'i32:
    hero.level = int(rank * 6 - 1)
    game.world.reject(3, ActionHeroLevelRequired)
    inc hero.level
    doAssert game.world.applyLevelAbility(hero.id, 3)
    doAssert hero.abilityLevels[UltimateAbility] == rank

echo "Testing XP banks points and basic damage keeps scaling for every class"
for class in HeroClass:
  let
    game = quietGame(class)
    world = game.world
    hero = world.heroes[0]
    enemy = world.heroes[5]
    damage = hero.heroAttackDamage
  hero.inventory[0] = PoisonPotion
  hero.itemCounts[0] = 1
  hero.xp = 1000
  enemy.place(hero.position)
  enemy.hp = 1
  enemy.state = Marching
  for cell in world.teamVisible[hero.team.ord].mitems:
    cell = 255
  hero.attackObjectId = enemy.id
  doAssert world.applyUseItem(hero.id, 0)
  doAssert hero.level > 1
  doAssert hero.abilityPoints == hero.level
  doAssert hero.abilityLevels == [0'i32, 0, 0, 0]
  doAssert hero.heroAttackDamage == damage +
    int32(hero.level - 1) * class.heroSpec.damagePerLevel

echo "Testing ranked effects for every ability and rank"
for class in HeroClass:
  for slot in HeroAbilitySlot:
    let ability = heroAbility(class, slot)
    for rank in 1'i32 .. slot.abilityMaxLevel:
      let
        game = quietGame(class)
        world = game.world
        hero = world.heroes[0]
        target = world.heroes[5]
        spec = ability.abilitySpec(rank)
        base = ability.abilitySpec
      hero.level = 18
      for i in 1'i32 .. rank:
        doAssert world.applyLevelAbility(hero.id, slot.ord.int32)
      hero.hp = 1
      hero.mana = 1000
      target.team = if spec.kind == Strike: BlueTeam else: hero.team
      target.hp = 10_000
      target.maxHp = 20_000
      target.state = Marching
      target.place(hero.position)
      if spec.area.innerRadius > 0:
        var point = target.position
        point.z += (spec.area.innerRadius + spec.area.radius) div 2
        target.place(point)
      game.step()
      let
        hp = hero.hp
        targetHp = target.hp
        mana = hero.mana
        targetId = if spec.casting == SelfCast: hero.id else: target.id
      doAssert world.applyCastTarget(hero.id, slot.ord.int32, targetId),
        $ability & " rank " & $rank
      doAssert world.casts[^1].level == rank
      game.step(100)
      case spec.kind
      of Strike:
        doAssert target.hp == targetHp - spec.damage, $ability
        if base.damageRanks[0] == 0:
          doAssert spec.damage == base.damage * (rank + 1) div 2
        doAssert spec.damage > ability.abilitySpec(rank - 1).damage
      of Heal:
        if spec.casting == SelfCast:
          doAssert hero.hp == min(hero.maxHp, hp + spec.heal), $ability
        else:
          doAssert target.hp == targetHp + spec.heal, $ability
        doAssert spec.heal == base.heal * (rank + 1) div 2
      of Restore:
        doAssert hero.mana >= mana + spec.restore, $ability
        doAssert spec.restore == base.restore * (rank + 1) div 2

echo "Testing pending casts keep their rank and upgrades preserve cooldowns"
block:
  let
    game = quietGame(Arcanist)
    world = game.world
    hero = world.heroes[0]
    enemy = world.heroes[5]
  hero.level = 3
  enemy.place(hero.position)
  enemy.hp = 10_000
  enemy.maxHp = 10_000
  enemy.state = Marching
  doAssert world.applyLevelAbility(hero.id, 2)
  game.step()
  doAssert world.applyCastTarget(hero.id, 2, enemy.id)
  let
    charges = hero.charges
    cooldowns = hero.cooldowns
    recharges = hero.recharges
  doAssert world.applyLevelAbility(hero.id, 2)
  doAssert hero.charges == charges and hero.cooldowns == cooldowns
  doAssert hero.recharges == recharges
  doAssert world.casts[0].level == 1
  let hash = game.stateHash()
  world.casts[0].level = 2
  doAssert game.stateHash() != hash
  world.casts[0].level = 1
  game.step(int(MeteorStrike.abilitySpec.castTicks))
  doAssert enemy.hp == 10_000 - MeteorStrike.abilitySpec.damage

echo "Testing ranks survive respawn, clone and restore and affect hashes"
block:
  let
    game = quietGame()
    hero = game.world.heroes[0]
    initial = game.stateHash()
  queueLevelAbility(hero.id, 1)
  game.flushPlayerCommands()
  doAssert hero.abilityLevels[PrimaryAbility] == 1
  doAssert game.stateHash() != initial
  let
    snapshot = game.world.clone()
    learned = game.stateHash()
  hero.abilityLevels[SecondaryAbility] = 1
  doAssert game.stateHash() != learned
  game.world.restore(snapshot)
  doAssert game.stateHash() == learned
  let restored = game.world.heroes[0]
  restored.charges[PrimaryAbility] = 0
  restored.state = Dying
  restored.hp = 0
  restored.deathTicks = 24 + 8 * TickRate - 1
  game.step(2)
  doAssert restored.hp > 0 and restored.abilityPoints == 0
  doAssert restored.abilityLevels == [0'i32, 1, 0, 0]
  doAssert restored.charges == [0'i32, 3, 0, 0]

echo "Testing live BASIC progression observations and deterministic replays"
block:
  let
    directory = createTempDir("gota-progression-", "")
    path = directory / "progression.bas"
    game = newGame(
      generateMap(54),
      240,
      10,
      false,
      ReplayData(),
      drafting = false
    )
  defer:
    removeDir(directory)
  writeFile(path, """
if initialized = 0 then
  pointsBefore = abilityPoints()
  locked = abilityLevel(1)
  lockedDamage = abilityDamage(1)
  rejected = levelAbility(3)
  gateError = lastActionError() = ActionHeroLevelRequired
  accepted = levelAbility(1)
  cleared = lastActionError() = NoActionError
  rank = abilityLevel(1)
  pointsAfter = abilityPoints()
  required = abilityRequiredLevel(1)
  maximum = abilityMaxLevel(1)
  ultimateMaximum = abilityMaxLevel(3)
  ultimateRequired = abilityRequiredLevel(3)
  canUpgrade = canLevelAbility(1)
  damage = abilityDamage(1)
  healing = abilityHeal(1)
  restore = abilityRestore(1)
  cost = abilityManaCost(1)
  invalid = abilityLevel(-1) + abilityLevel(4) + abilityLevel(2147483647)
  invalid = invalid + canLevelAbility(-1) + abilityMaxLevel(4)
  invalid = invalid + abilityRequiredLevel(-1) + abilityDamage(4)
  invalid = invalid + abilityHeal(-1) + abilityRestore(4)
  invalid = invalid + abilityManaCost(-1)
  failed = levelAbility(-7)
  invalidError = lastActionError() = ActionInvalidSlot
  boughtScroll = buyItem(21)
  startedPortal = useItemAt(0, selfX, selfY)
  initialized = 1
end if
""")
  game.loadBots([BotGroup(path: path, count: 10)])
  game.recorder = initReplayRecorder(game.currentSetup(120), game.map.preset)
  for tick in 0 ..< 120:
    game.tickWorld(proc() = game.runBotDecisions())
  for i, vm in game.heroVms:
    let spec = heroAbility(
      game.world.heroes[i].class,
      PrimaryAbility
    ).abilitySpec
    doAssert not vm.failed, vm.lastError
    doAssert vm.runtime.getGlobal("pointsBefore") == 1
    doAssert vm.runtime.getGlobal("locked") == 0
    doAssert vm.runtime.getGlobal("lockedDamage") == 0
    doAssert vm.runtime.getGlobal("rejected") == 0
    doAssert vm.runtime.getGlobal("gateError") != 0
    doAssert vm.runtime.getGlobal("accepted") == 1
    doAssert vm.runtime.getGlobal("cleared") != 0
    doAssert vm.runtime.getGlobal("rank") == 1
    doAssert vm.runtime.getGlobal("pointsAfter") == 0
    doAssert vm.runtime.getGlobal("required") == 3
    doAssert vm.runtime.getGlobal("maximum") == 4
    doAssert vm.runtime.getGlobal("ultimateMaximum") == 3
    doAssert vm.runtime.getGlobal("ultimateRequired") == 6
    doAssert vm.runtime.getGlobal("canUpgrade") == 0
    doAssert vm.runtime.getGlobal("damage") == spec.damage
    doAssert vm.runtime.getGlobal("healing") == spec.heal
    doAssert vm.runtime.getGlobal("restore") == spec.restore
    doAssert vm.runtime.getGlobal("cost") == spec.manaCost
    doAssert vm.runtime.getGlobal("invalid") == 0
    doAssert vm.runtime.getGlobal("failed") == 0
    doAssert vm.runtime.getGlobal("invalidError") != 0
    doAssert vm.runtime.getGlobal("boughtScroll") == 1
    doAssert vm.runtime.getGlobal("startedPortal") == 1
  let
    replay = decodeReplay(game.recorder.data.encodeReplay())
    playback = newGame(
      generateMap(replay.config.seed, replay.config.mapPreset),
      replay.config.spawnIntervalTicks, 0, true, replay
    )
  playback.historyPlayback = true
  playback.replayPlayer = initReplayPlayer(replay)
  var upgrades, purchases, portals: int
  for action in replay.actions:
    case action.kind
    of ActionLevelAbility:
      inc upgrades
    of ActionBuyItem:
      inc purchases
    of ActionUseItemAt:
      inc portals
    else:
      doAssert false, "Unexpected progression replay action"
  doAssert upgrades == 30 and purchases == 10 and portals == 10
  for tick in 0 ..< replay.hashes.len:
    playback.tickWorld(nil)
    doAssert playback.hashCheck.mismatches == 0
  doAssert game.stateHash() == playback.stateHash()
  doAssert playback.replayPlayer.finished

echo "GOTA progression tests passed"
