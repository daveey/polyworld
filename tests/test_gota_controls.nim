import
  std/[os, tempfiles],
  bassy,
  polyworld/[cli, tapes],
  ../examples/gods_of_the_arena/[bots, content, maps, replays, sim]

proc controlGame(class = VanguardKnight, team = RedTeam): Game =
  ## Creates a quiet arena for explicit casts and movement restrictions.
  result = newGame(generateMap(54), 100_000, 10, false, ReplayData(),
    drafting = false)
  let world = result.world
  world.spawnTimerTicks = 100_000
  world.heroTurnTicks = 100_000
  for hero in world.heroes:
    hero.hp = 0
    hero.state = Dying
    hero.deathTicks = -100_000
  for building in world.buildings.mitems:
    building.hp = 0
  let hero = world.heroes[0]
  hero.class = class
  hero.team = team
  hero.abilityLevels = [1'i32, 1, 1, 1]
  hero.spellsReady = false
  hero.refreshHeroStats()
  hero.hp = hero.maxHp
  hero.mana = 10_000
  hero.maxMana = 10_000
  hero.state = Marching
  hero.place(world.forts[team.ord].center)
  for cells in world.teamVisible.mitems:
    for cell in cells.mitems:
      cell = 255

proc step(game: Game, ticks = 1'i32) =
  ## Holds heroes in place while running the real spell and combat phases.
  for i in 0 ..< ticks:
    for hero in game.world.heroes:
      hero.hasMoveTarget = true
      hero.attackObjectId = 0
    game.tickWorld(nil)
echo "Testing crowd control damage, fixed durations, and hostile impacts"
for team in Team:
  for (class, slot, effect, duration, damage) in [
    (VanguardKnight, PrimaryAbility, StunControl, TickRate div 2, 37'i32),
    (VanguardKnight, UltimateAbility, StunControl, TickRate, 204'i32),
    (DeathKnight, PrimaryAbility, RootControl, TickRate div 2, 37'i32),
    (DemonHunter, SecondaryAbility, RootControl, TickRate div 2, 60'i32),
    (Berserker, SecondaryAbility, RootControl, TickRate * 3 div 4, 35'i32),
    (Warlock, SecondaryAbility, SilenceControl, 2 * TickRate, 84'i32),
    (DruidWarden, UltimateAbility, RootControl, 2 * TickRate, 49'i32),
    (Lich, SecondaryAbility, RootControl, TickRate * 3 div 2, 49'i32)
  ]:
    let
      game = controlGame(class, team)
      world = game.world
      caster = world.heroes[0]
      enemy = world.heroes[5]
      ally = world.heroes[1]
      ability = heroAbility(class, slot)
      spec = ability.abilitySpec
    for rank in 1 .. slot.abilityMaxLevel:
      doAssert ability.abilitySpec(rank).controlTicks == duration
      doAssert ability.abilitySpec(rank).damage == damage * (rank + 1) div 2
    doAssert ability.abilitySpec(0).controlTicks == 0
    for hero in [enemy, ally]:
      hero.team = if hero == enemy: Team(1 - team.ord) else: team
      hero.hp = 10_000
      hero.maxHp = 10_000
      hero.state = Marching
      var point = caster.position
      point.z += WorldScale
      hero.place(point)
    game.step()
    doAssert world.applyCastTarget(caster.id, slot.ord.int32, enemy.id),
      $class & " " & $team & " " & $caster.lastActionError &
      " " & $caster.position & " " & $enemy.position
    game.step(max(spec.castTicks, world.casts[^1].impact - world.tick))
    doAssert enemy.hp == 10_000 - damage
    doAssert ally.hp == 10_000
    doAssert enemy.controls[effect].ends == world.tick + duration
    doAssert ally.controls == default(typeof(ally.controls))
    doAssert caster.controls == default(typeof(caster.controls))
    when defined(replayEvents):
      var found = false
      for event in world.events:
        if event.kind in {Stunned, Silenced, Rooted}:
          doAssert event.actor.id == caster.id
          doAssert event.target.id == enemy.id
          doAssert event.detail == ability.ord
          doAssert event.amount == duration
          found = true
      doAssert found

echo "Testing spell impacts also control creeps"
for (class, slot) in [(VanguardKnight, PrimaryAbility),
    (VanguardKnight, UltimateAbility), (DeathKnight, PrimaryAbility),
    (DemonHunter, SecondaryAbility), (Berserker, SecondaryAbility),
    (Warlock, SecondaryAbility), (DruidWarden, UltimateAbility),
    (Lich, SecondaryAbility)]:
  let
    game = controlGame(class)
    world = game.world
    caster = world.heroes[0]
    spec = heroAbility(class, slot).abilitySpec
  caster.hp = 10_000
  caster.maxHp = 10_000
  var
    creep = Footman(id: 1000, team: BlueTeam, kind: RangedCreep,
      hp: 10_000, lane: 1, swingTicks: -1)
    point = caster.position
  point.z += WorldScale
  creep.place(point)
  world.footmen.add creep
  game.step()
  doAssert world.applyCastTarget(caster.id, slot.ord.int32, creep.id)
  game.step(max(spec.castTicks, world.casts[^1].impact - world.tick))
  doAssert world.footmen[0].hp == 10_000 - spec.damage
  doAssert world.footmen[0].controls[spec.control].ends ==
    world.tick + spec.controlTicks
  if spec.control in {RootControl, StunControl}:
    let held = world.footmen[0].position
    game.step(spec.controlTicks - 1)
    doAssert world.footmen[0].position == held

echo "Testing independent timers, refresh, expiration, and cast rejection"
for effect in StunControl .. RootControl:
  let
    game = controlGame()
    world = game.world
    hero = world.heroes[0]
    x = mapCoordinate(hero.position.x)
    y = mapCoordinate(hero.position.z)
  hero.hp -= 20
  hero.inventory[0] = VitalityElixir
  hero.itemCounts[0] = 2
  hero.portalEnds = world.tick + PortalChannelTicks
  hero.swingTicks = 3
  world.applyControl(hero.id, effect, TickRate)
  let first = hero.controls[effect]
  world.applyControl(hero.id, effect, TickRate div 2)
  doAssert hero.controls[effect] == first
  doAssert (hero.portalEnds == 0) == (effect != SilenceControl)
  doAssert (hero.swingTicks == -1) == (effect == StunControl)
  hero.portalEnds = 0
  let
    mana = hero.mana
    charges = hero.charges
  let accepted = world.applyCastTarget(hero.id, PassiveAbility.ord.int32, hero.id)
  doAssert accepted == (effect == RootControl)
  if not accepted:
    doAssert hero.lastActionError ==
      (if effect == StunControl: ActionStunned else: ActionSilenced)
    doAssert hero.mana == mana and hero.charges == charges
  doAssert world.applyWalkTo(hero.id, x, y) == (effect == SilenceControl)
  doAssert world.applyAttackTarget(hero.id, 0) == (effect != StunControl)
  hero.hp = hero.maxHp - 30
  doAssert world.applyUseItem(hero.id, 0) == (effect != StunControl)
  world.tick = first.ends - 1
  doAssert hero.controls[effect].ends > world.tick
  world.applyControl(hero.id, effect, TickRate)
  doAssert hero.controls[effect].ends == world.tick + TickRate
  world.tick = hero.controls[effect].ends
  doAssert world.applyWalkTo(hero.id, x, y)
  hero.cooldowns[PassiveAbility] = 0
  hero.charges[PassiveAbility] = 1
  hero.hp = hero.maxHp - 40
  doAssert world.applyCastTarget(hero.id, 0, hero.id)

echo "Testing unit control, building immunity, death, and hash coverage"
block:
  let
    game = controlGame()
    world = game.world
    hero = world.heroes[0]
  world.footmen.add Footman(id: 1000, team: BlueTeam, hp: 100)
  let initial = game.stateHash()
  for effect in StunControl .. RootControl:
    world.applyControl(hero.id, effect, TickRate)
    world.applyControl(1000, effect, TickRate)
    world.applyControl(world.buildings[0].id, effect, TickRate)
    world.applyControl(world.forts[0].id, effect, TickRate)
    doAssert hero.controls[effect].ends == TickRate
    doAssert world.footmen[0].controls[effect].ends == TickRate
  doAssert game.stateHash() != initial
  hero.hp = 0
  game.step()
  doAssert hero.controls == default(typeof(hero.controls))
  world.applyControl(hero.id, RootControl, 10 * TickRate)
  doAssert hero.controls == default(typeof(hero.controls))

echo "Testing roots hold paths and stuns cancel attacks without disabling attacks"
for effect in [StunControl, RootControl, SilenceControl]:
  let
    game = controlGame(Ranger)
    world = game.world
    hero = world.heroes[0]
    enemy = world.heroes[5]
  game.step()
  let start = hero.position
  doAssert world.applyWalkTo(hero.id, mapCoordinate(start.x),
    mapCoordinate(start.z) + 4)
  world.applyControl(hero.id, effect, 2 * TickRate)
  for i in 1 ..< 2 * TickRate:
    game.tickWorld(nil)
  doAssert (hero.position == start) == (effect != SilenceControl)
  # Allow normal turning toward the saved destination after expiry.
  for i in 0 ..< TickRate div 2:
    game.tickWorld(nil)
  doAssert hero.position != start, $effect & " " & $hero.hasMoveTarget &
    " " & $hero.movePath & " " & $world.tick & " " & $hero.controls
  hero.place(start)
  hero.hasMoveTarget = false
  enemy.hp = 10_000
  enemy.maxHp = 10_000
  enemy.state = Marching
  var point = start
  point.z += 2 * WorldScale
  enemy.place(point)
  world.applyControl(hero.id, effect, 4 * TickRate)
  hero.swingTicks = -1
  let attacks = hero.attacksLanded
  for i in 0 ..< 3 * TickRate:
    enemy.hasMoveTarget = true
    game.tickWorld(nil)
  doAssert (hero.attacksLanded > attacks) == (effect != StunControl)
  if effect == StunControl:
    for i in 0 ..< 3 * TickRate:
      enemy.hasMoveTarget = true
      game.tickWorld(nil)
    doAssert hero.attacksLanded > attacks

echo "Testing BASIC status observations and fog filtering"
block:
  let
    directory = createTempDir("gota-controls-", "")
    path = directory / "controls.bas"
    game = controlGame()
    world = game.world
    hero = world.heroes[0]
    enemy = world.heroes[5]
  defer:
    removeDir(directory)
  writeFile(path, """
mySilence = selfSilenceTicks
myStun = selfStunTicks
myRoot = selfRootTicks
seen = 0
for i = 0 to objectCount() - 1
  if objectId(i) = 105 then
    seen = 1
    silence = objectSilenceTicks(i)
    stun = objectStunTicks(i)
    root = objectRootTicks(i)
  end if
next i
invalid = objectSilenceTicks(-1) + objectStunTicks(99999) + objectRootTicks(-1)
""")
  game.loadBots([BotGroup(path: path, count: 10)])
  enemy.hp = enemy.maxHp
  enemy.state = Marching
  enemy.place(hero.position)
  for unit in [hero, enemy]:
    world.applyControl(unit.id, StunControl, 12)
    world.applyControl(unit.id, SilenceControl, 24)
    world.applyControl(unit.id, RootControl, 36)
  doAssert world.freezeObservations()
  enemy.controls[SilenceControl].ends = 80
  game.runBotDecisions()
  world.thawObservations()
  let vm = game.heroVms[0]
  doAssert not vm.failed, vm.lastError
  for name in ["myStun", "stun"]:
    doAssert vm.runtime.getGlobal(name) == 12
  for name in ["mySilence", "silence"]:
    doAssert vm.runtime.getGlobal(name) == 24
  for name in ["myRoot", "root"]:
    doAssert vm.runtime.getGlobal(name) == 36
  doAssert vm.runtime.getGlobal("invalid") == 0
  for cell in world.teamVisible[RedTeam.ord].mitems:
    cell = 0
  game.runBotDecisions()
  doAssert vm.runtime.getGlobal("seen") == 0

echo "Testing replay seeking restores active control and exact expiration"
block:
  let
    game = controlGame(Lich)
    world = game.world
    caster = world.heroes[0]
    enemy = world.heroes[5]
  enemy.hp = 10_000
  enemy.maxHp = 10_000
  enemy.state = Marching
  var point = caster.position
  point.z += WorldScale
  enemy.place(point)
  world.heroTurnTicks = 1
  game.recorder = initReplayRecorder(game.currentSetup(100), game.map.preset)
  let initial = world.clone()
  var activeHash: uint64
  for tick in 1 .. 60:
    game.tickWorld(proc() =
      ## Records the same explicit cast that a policy would submit.
      if world.tick == 1:
        game.recorder.recordCast(1, caster.id, SecondaryAbility.ord.int32,
          enemy.id, 0, false)
        doAssert world.applyCastTarget(caster.id, SecondaryAbility.ord.int32,
          enemy.id)
      world.heroTurnStart = (world.heroTurnStart + 1) mod world.heroes.len
    )
    if tick == 30:
      doAssert enemy.controls[RootControl].ends > world.tick
      activeHash = game.stateHash()
  let
    data = decodeReplay(encodeReplay(game.recorder.data))
    playback = newGame(game.map, 100_000, 0, true, data)
  playback.historyPlayback = true
  playback.replayPlayer = initReplayPlayer(data)
  for pass in 0 .. 1:
    playback.world.restore(initial)
    playback.replayPlayer.syncCursor(0)
    for tick in 1 .. 60:
      playback.tickWorld(nil)
      if tick == 30:
        doAssert playback.stateHash() == activeHash
    doAssert playback.hashCheck.mismatches == 0, playback.hashCheck.error
    doAssert playback.stateHash() == game.stateHash()
