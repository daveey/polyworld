import
  std/[os, sets, strutils],
  bassy,
  polyworld/[cli, pathing, tapes],
  ../examples/gods_of_the_arena/[bots, content, maps, replays, sim]

const
  Root = currentSourcePath().parentDir.parentDir
  Policy = Root / "examples/gods_of_the_arena/players/base.bas"

proc policyGame(team = RedTeam, size = 116): Game =
  ## Creates one real policy VM with controllable opponents and allied towers.
  var preset = defaultConfig()
  preset.mapSize = size
  result = newGame(
    generateMap(54, preset), 100_000, 10, false, ReplayData(), drafting = false
  )
  result.loadBots([BotGroup(path: Policy, count: 10)])
  result.recorder = initReplayRecorder(result.currentSetup(1000), preset)
  for i, hero in result.world.heroes:
    hero.abilityLevels[PassiveAbility] = 1
    hero.spellsReady = true
    hero.gold = 0
    if i != team.ord * 5:
      result.heroVms[i] = nil
      hero.hp = 0
      hero.state = Dying
  for building in result.world.buildings.mitems:
    if building.team != team:
      building.hp = 0
  result.world.syncBuildings()
  for cells in result.world.teamVisible.mitems:
    for cell in cells.mitems:
      cell = 255

proc decide(game: Game): seq[ReplayAction] =
  ## Runs a bounded policy decision and returns only its submitted commands.
  game.world.tick += 6
  let before = game.recorder.data.actions.len
  game.runBotDecisions()
  for vm in game.heroVms:
    if vm != nil:
      doAssert not vm.failed, vm.lastError
      doAssert vm.lastInstructions <= vm.limits.maxInstructions
      doAssert vm.lastWork <= vm.limits.maxWorkUnits
  game.recorder.data.actions[before ..< game.recorder.data.actions.len]

proc hasAction(actions: seq[ReplayAction], kind: uint8): bool =
  ## Checks for an actual host submission from the reference policy.
  for action in actions:
    if action.kind == kind:
      return true

proc middle(game: Game): WorldPoint =
  ## Selects the generated middle lane instead of assuming map coordinates.
  let point = lanePathPoints[1][lanePathPoints[1].len div 2]
  const Unit = WorldScale div PathUnitsPerTile
  WorldPoint(x: point.x * Unit, y: point.y * Unit, z: point.z * Unit)

echo "Testing base policy calls cover the current GotA host API"
block:
  doAssert readFile(Policy) == readFile(Root / "coworld/gota/players/base.bas")
  let host = readFile(Root / "examples/gods_of_the_arena/bots.nim")
  var
    names: HashSet[string]
    source: string
  for line in readFile(Policy).splitLines():
    if not line.strip().startsWith("'"):
      source.add line & "\n"
  for line in host.splitLines():
    let
      text = line.strip()
      field = text.startsWith("(Object") or text.startsWith("(Spell") or
        text.startsWith("(Ability") or text.startsWith("(Terrain")
    if "addFunction(\"" in line or (field and ", \"" in line):
        let name = line.split('"')[1]
        names.incl(name)
        if name.startsWith("terrain"):
          names.incl(name & "At")
  doAssert names.len >= 68
  for name in names:
    # Chat is exercised by the mailbox example instead of the combat policy.
    if name in ["sendChat", "pullMailbox$", "mailboxId", "mailboxCount",
      "mailboxSelf", "mailboxPlayers"]:
        continue
    doAssert name & "(" in source, "Base policy omits host call " & name

echo "Testing base spends ability points in R, W, E, Q order at legal levels"
for class in HeroClass:
  let
    game = policyGame()
    hero = game.world.heroes[0]
  hero.class = class
  hero.abilityLevels = [0'i32, 0, 0, 0]
  var expected: array[HeroAbilitySlot, int32]
  for level in 1 .. HeroMaxLevel:
    hero.level = level
    hero.refreshHeroStats()
    hero.hp = hero.maxHp
    hero.mana = hero.maxMana
    var points = level.int32
    for rank in expected:
      points -= rank
    for slot in [UltimateAbility, PrimaryAbility, SecondaryAbility,
      PassiveAbility]:
        while points > 0 and expected[slot] < slot.abilityMaxLevel and
          level >= slot.abilityRequiredLevel(expected[slot] + 1):
            inc expected[slot]
            dec points
    let actions = game.decide()
    doAssert hero.abilityLevels == expected, $class & " level " & $level
    for action in actions:
      if action.kind == ActionLevelAbility:
        let slot = HeroAbilitySlot(action.slot)
        doAssert level >= slot.abilityRequiredLevel(expected[slot])
  doAssert hero.abilityLevels == [4'i32, 4, 4, 3]

echo "Testing all forty abilities are explicitly cast at suitable targets"
for team in Team:
  for class in HeroClass:
    let
      game = policyGame(team)
      hero = game.world.heroes[team.ord * 5]
      enemy = game.world.heroes[(1 - team.ord) * 5]
      point = game.middle()
    hero.class = class
    hero.level = 18
    hero.abilityLevels = [4'i32, 4, 4, 3]
    hero.refreshHeroStats()
    hero.maxMana = 1000
    hero.place(point)
    enemy.place(WorldPoint(
      x: point.x + WorldScale, y: point.y, z: point.z
    ))
    enemy.hp = enemy.maxHp
    enemy.state = Marching
    for slot in HeroAbilitySlot:
      let
        ability = class.heroAbility(slot)
        spec = ability.abilitySpec(hero.abilityLevels[slot])
      hero.hp = hero.maxHp
      hero.mana = hero.maxMana
      if spec.kind == Heal:
        hero.hp = hero.maxHp div 2
      elif spec.kind == Restore:
        hero.mana -= spec.restore
      hero.cooldowns = [0'i32, 0, 0, 0]
      hero.charges = [0'i32, 0, 0, 0]
      hero.charges[slot] = spec.charges
      game.world.casts.setLen(0)
      let actions = game.decide()
      doAssert game.world.casts.len == 1, $team & " " & $ability
      let spell = game.world.casts[0]
      doAssert spell.ability == ability
      doAssert actions.hasAction(ActionCastTarget) or
        actions.hasAction(ActionCastPoint)
      doAssert hero.charges[slot] == spec.charges - 1
      if spec.casting == AreaCast:
        let target = if spec.kind == Heal: hero.position else: enemy.position
        doAssert spell.spellContains(spec.area, target), $team & " " & $ability
      else:
        let target = if spec.kind == Strike: enemy.id else: hero.id
        doAssert spell.targetId == target, $team & " " & $ability

echo "Testing base shopping, safe portals, channels, and shared cooldowns"
for team in Team:
  let
    game = policyGame(team)
    hero = game.world.heroes[team.ord * 5]
  hero.gold = 2000
  hero.hp = hero.maxHp div 2
  doAssert hero.inOwnSpawn()
  doAssert game.decide().hasAction(ActionBuyItem)
  discard game.decide()
  var scrollSlot = -1
  for i, item in hero.inventory:
    if item == HealthPotion:
      doAssert hero.itemCounts[i] == 2
    if item == PortalScroll:
      scrollSlot = i
      doAssert hero.itemCounts[i] == 2
  doAssert scrollSlot >= 0
  hero.hp = hero.maxHp
  doAssert game.decide().hasAction(ActionUseItemAt)
  doAssert hero.portalEnds > game.world.tick
  let count = hero.itemCounts[scrollSlot]
  doAssert game.decide().len == 0
  doAssert hero.itemCounts[scrollSlot] == count
  hero.portalEnds = 0
  hero.portalCooldownEnds = game.world.tick + PortalCooldownTicks
  doAssert not game.decide().hasAction(ActionUseItemAt)

echo "Testing base prioritizes last hits and ignores hidden enemies"
block:
  let
    game = policyGame()
    hero = game.world.heroes[0]
    point = game.middle()
  hero.place(point)
  game.world.footmen = @[
    Footman(id: 1000, team: BlueTeam, hp: 1, position: point,
      state: Marching),
    Footman(id: 1001, team: BlueTeam, hp: FootmanHp, position: point,
      state: Marching)
  ]
  let actions = game.decide()
  doAssert actions.hasAction(ActionAttackTarget)
  doAssert hero.attackObjectId == 1000
  for cell in game.world.teamVisible[RedTeam.ord].mitems:
    cell = 0
  hero.attackObjectId = 0
  doAssert not game.decide().hasAction(ActionAttackTarget)

echo "Testing explicit allied healing and led area casts"
for class in [VanguardKnight, DruidWarden]:
  for distance in [1'i32, 4'i32, 5'i32]:
    let
      game = policyGame()
      hero = game.world.heroes[0]
      ally = game.world.heroes[1]
      point = game.middle()
    hero.class = class
    hero.refreshHeroStats()
    hero.hp = hero.maxHp
    hero.mana = hero.maxMana
    hero.abilityLevels = [0'i32, 0, 1, 0]
    hero.place(point)
    ally.place(WorldPoint(
      x: point.x + distance * WorldScale, y: point.y, z: point.z
    ))
    ally.hp = ally.maxHp
    ally.state = Marching
    discard game.decide()
    ally.hp -= 100
    hero.charges[SecondaryAbility] = 1
    let
      actions = game.decide()
      inRange = distance == 1 or (class == DruidWarden and distance == 4)
    doAssert actions.hasAction(ActionCastTarget) == inRange
    if inRange:
      let spell = game.world.casts[^1]
      doAssert spell.ability == class.heroAbility(SecondaryAbility)
      doAssert spell.spellContains(spell.ability.abilitySpec.area, ally.position)

block:
  let
    game = policyGame()
    hero = game.world.heroes[0]
    ally = game.world.heroes[1]
    point = game.middle()
  hero.class = DruidWarden
  hero.refreshHeroStats()
  hero.hp = hero.maxHp
  hero.mana = hero.maxMana
  hero.place(point)
  ally.place(point)
  ally.hp = ally.maxHp
  ally.state = Marching
  discard game.decide()
  ally.hp -= 80
  hero.abilityLevels[PrimaryAbility] = 1
  hero.charges[PrimaryAbility] = 1
  hero.spellsReady = true
  let actions = game.decide()
  doAssert actions.hasAction(ActionCastTarget)
  doAssert game.world.casts[^1].ability == HealingBloom
  doAssert game.world.casts[^1].position == ally.position

block:
  let
    game = policyGame()
    hero = game.world.heroes[0]
    enemy = game.world.heroes[5]
    point = game.middle()
  hero.class = Arcanist
  hero.refreshHeroStats()
  hero.hp = hero.maxHp
  hero.mana = hero.maxMana
  hero.place(point)
  hero.abilityLevels[SecondaryAbility] = 1
  hero.charges[SecondaryAbility] = 1
  hero.spellsReady = true
  enemy.place(point)
  enemy.hp = enemy.maxHp
  enemy.state = Marching
  enemy.velocity = heading(WorldScale div 32, 0)
  let actions = game.decide()
  doAssert actions.hasAction(ActionCastPoint)
  doAssert game.world.casts[^1].ability == MeteorStrike
  doAssert game.world.casts[^1].position.x > enemy.position.x
  for action in actions:
    if action.kind == ActionCastPoint:
      doAssert action.offset != FixedVec2Zero

echo "Testing base skips unavailable and out-of-range spells"
for reason in [ActionNoCharges, ActionCooldown, ActionInsufficientMana,
  ActionOutOfRange]:
    let
      game = policyGame()
      hero = game.world.heroes[0]
      enemy = game.world.heroes[5]
      point = game.middle()
    hero.class = Arcanist
    hero.refreshHeroStats()
    hero.hp = hero.maxHp
    hero.mana = hero.maxMana
    hero.abilityLevels = [0'i32, 1, 0, 0]
    hero.charges[PrimaryAbility] = 1
    hero.place(point)
    enemy.place(point)
    enemy.hp = enemy.maxHp
    enemy.state = Marching
    case reason
    of ActionNoCharges:
      hero.charges[PrimaryAbility] = 0
    of ActionCooldown:
      hero.cooldowns[PrimaryAbility] = 1
    of ActionInsufficientMana:
      hero.mana = 0
    of ActionOutOfRange:
      enemy.place(WorldPoint(
        x: point.x + 7 * WorldScale, y: point.y, z: point.z
      ))
    else:
      doAssert false
    let actions = game.decide()
    doAssert not actions.hasAction(ActionCastTarget)
    doAssert not actions.hasAction(ActionCastPoint)
    doAssert game.world.casts.len == 0

echo "Testing Death Knight keeps enemies outside the ring's empty center"
block:
  let
    game = policyGame()
    hero = game.world.heroes[0]
    enemy = game.world.heroes[5]
    point = game.middle()
  hero.class = DeathKnight
  hero.refreshHeroStats()
  hero.hp = hero.maxHp
  hero.mana = hero.maxMana
  hero.abilityLevels = [0'i32, 0, 0, 1]
  hero.charges[UltimateAbility] = 1
  hero.place(point)
  enemy.place(point)
  enemy.hp = enemy.maxHp
  enemy.state = Marching
  discard game.decide()
  doAssert game.world.casts.len == 0
  enemy.place(WorldPoint(x: point.x + WorldScale, y: point.y, z: point.z))
  discard game.decide()
  doAssert game.world.casts.len == 1
  doAssert game.world.casts[0].ability == DarkEclipse

echo "Testing safe gradual recovery and emergency burst consumables"
for item in [HealthPotion, ManaPotion, VitalityElixir, ManaElixir]:
  let
    game = policyGame()
    hero = game.world.heroes[0]
  hero.place(game.middle())
  hero.inventory[0] = item
  hero.itemCounts[0] = 2
  hero.hp = hero.maxHp div 3
  hero.mana = 0
  game.world.tick = 100
  if item == ManaElixir:
    game.world.footmen = @[
      Footman(id: 1000, team: BlueTeam, hp: FootmanHp,
        position: hero.position, state: Marching)
    ]
  doAssert game.decide().hasAction(ActionUseItem)
  doAssert hero.itemCounts[0] == 1
  doAssert not game.decide().hasAction(ActionUseItem)

echo "Testing hostile warnings and maximum-size crowded maps stay bounded"
for size in [64, 116, 256]:
  let
    game = policyGame(size = size)
    world = game.world
    hero = world.heroes[0]
    enemy = world.heroes[5]
    point = game.middle()
  hero.place(point)
  enemy.place(point)
  enemy.hp = enemy.maxHp
  enemy.state = Marching
  for i in 0 ..< 480:
    world.footmen.add Footman(
      id: 1000 + i.int32, team: Team(i mod 2), hp: FootmanHp,
      position: point, state: Marching
    )
  for i in 0 ..< 512:
    world.casts.add SpellCast(
      heroId: enemy.id, ability: MeteorStrike, level: 1,
      origin: point, position: point, impact: 72, ends: 84
    )
  let actions = game.decide()
  doAssert game.heroVms[0].runtime.getGlobal("dodge") != 0
  doAssert actions.hasAction(ActionWalkTo)
  for i in 0 ..< 8:
    discard game.decide()
  echo "  ", size, " tiles: ", game.heroVms[0].lastInstructions,
    " instructions, ", game.heroVms[0].lastWork, " work units"

echo "GotA base policy checks passed"
