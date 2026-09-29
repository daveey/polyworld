import
  std/[os, strformat],
  bassy,
  polyworld/[bodies, cli],
  ../examples/gods_of_the_arena/[bots, content, maps, replays, sim]

const
  Policies = currentSourcePath().parentDir.parentDir /
    "examples/gods_of_the_arena/players"
  IdlePolicy = currentSourcePath().parentDir / "policies/idle.bas"

type
  Scenario = enum
    Farming, Converging, Regrouping, Retreating, Dodging, Fighting,
    Kiting, Casting, EqualTargets, Pulling, Luring, PullHandoff
  Decision = object
    actions: seq[ReplayAction]
    instructions, work: int64
    pullStage: int32

proc oriented(point: WorldPoint, team: Team): WorldPoint =
  ## Maps the canonical red-side scenario to either team's world coordinates.
  result = point
  if team == BlueTeam:
    result.x = -point.x
    result.z = -point.z

proc decision(policy: string, team: Team, class: HeroClass,
    scenario: Scenario, boundary = false,
    reverseEnemies = false): Decision =
  ## Runs the actual policy in a mirrored scenario with stable actor identities.
  let game = newGame(generateMap(7), 100_000, 10, false,
    ReplayData(), drafting = false)
  game.loadBots([
    BotGroup(path: Policies / policy, count: 1),
    BotGroup(path: IdlePolicy, count: 9)
  ])
  game.recorder = initReplayRecorder(game.currentSetup(1000))
  let
    origin =
      if boundary: WorldPoint(x: -10 * WorldScale, z: 10 * WorldScale)
      else: WorldPoint(x: -570_000, z: 630_000)
    hero = game.world.heroes[0]
    ally = game.world.heroes[1]
    enemy = game.world.heroes[5]
  for i, unit in game.world.heroes:
    unit.team = if i < 5: team else: Team(1 - team.ord)
    unit.class = class
    unit.refreshHeroStats()
    unit.place(origin.oriented(team))
    if i != 0:
      game.heroVms[i] = nil
      unit.hp = 0
      unit.state = Dying
    else:
      unit.hp = unit.maxHp
      unit.mana = unit.maxMana
  for building in game.world.buildings.mitems:
    building.hp = 0
  case scenario
  of Farming:
    discard
  of Converging:
    hero.level = 6
    hero.refreshHeroStats()
  of Regrouping:
    ally.hp = ally.maxHp
    ally.state = Marching
    ally.place(WorldPoint(x: origin.x + 11 * WorldScale,
      z: origin.z + WorldScale).oriented(team))
  of Retreating:
    hero.hp = hero.maxHp div 5
  of Dodging:
    game.world.casts.add SpellCast(
      heroId: enemy.id, ability: MeteorStrike, level: 1,
      origin: origin.oriented(team), position: origin.oriented(team),
      started: 0, impact: 48, ends: 60
    )
  of Fighting, Kiting, Casting, EqualTargets:
    enemy.hp = enemy.maxHp
    enemy.state = Marching
    enemy.place(WorldPoint(x: origin.x + WorldScale,
      z: origin.z).oriented(team))
    let sign = if team == RedTeam: 1'i32 else: -1'i32
    enemy.facing = Heading(x: -WorldScale * sign)
    enemy.velocity = Heading(x: (WorldScale div 32) * sign)
    if scenario == Kiting:
      hero.swingTicks = 0
      hero.attacksLanded = 1
    if scenario == Casting:
      hero.abilityLevels[SecondaryAbility] = 1
      hero.charges[SecondaryAbility] = 1
      hero.spellsReady = true
    if scenario == EqualTargets:
      let other = game.world.heroes[6]
      other.hp = other.maxHp
      other.state = Marching
      other.place(WorldPoint(x: origin.x,
        z: origin.z + WorldScale).oriented(team))
  of Pulling, Luring, PullHandoff:
    let campPoint = WorldPoint(x: origin.x + 3 * WorldScale,
      z: origin.z).oriented(team)
    game.world.camps[0].center = campPoint
    game.world.camps[0].tier = 1
    game.world.footmen = @[
      Footman(id: 1000, team: team, camp: 1, campTier: 1, hp: 100,
        position: campPoint, state: Marching, swingTicks: -1),
      Footman(id: 1001, team: team, hp: FootmanHp, state: Marching,
        position: WorldPoint(x: origin.x - 3 * WorldScale,
          z: origin.z).oriented(team), swingTicks: -1)
    ]
    if policy == "puller.bas" and scenario != Pulling:
      let vm = game.heroVms[0]
      vm.runtime.setGlobal("pullStage", 1)
      vm.runtime.setGlobal("pullCamp", 0)
      vm.runtime.setGlobal("pullUntil", 1000)
      vm.runtime.setGlobal("pullSeenTick", 6)
      game.world.camps[0].state = FightingCamp
      game.world.footmen[0].targetHeroId = hero.id
      if scenario == PullHandoff:
        game.world.footmen[0].targetHeroId = 0
        game.world.footmen[0].targetId = 1001
        game.world.footmen[1].targetId = 1000
  if reverseEnemies:
    swap(game.world.heroes[5], game.world.heroes[6])
  game.world.syncBuildings()
  for cells in game.world.teamVisible.mitems:
    for cell in cells.mitems:
      cell = 255
  game.world.tick = 6
  game.runBotDecisions()
  let vm = game.heroVms[0]
  doAssert not vm.failed, vm.lastError
  result.instructions = vm.lastInstructions
  result.work = vm.lastWork
  if policy == "puller.bas":
    result.pullStage = vm.runtime.getGlobal("pullStage")
    case scenario
    of Pulling:
      doAssert result.pullStage == 1
    of Luring:
      doAssert result.pullStage == 2
    of PullHandoff:
      doAssert result.pullStage == 0
    else:
      discard
  for action in game.recorder.data.actions:
    var canonical = action
    if team == BlueTeam and action.kind in [ActionWalkTo, ActionAttackMove,
      ActionCastPoint, ActionUseItemAt]:
        let (x, y, offset) = splitTilePoint(fixedVec2(
          fixed(mapTiles().int32 - 1 - action.first) - action.offset.x,
          fixed(mapTiles().int32 - 1 - action.second) - action.offset.y
        ))
        canonical.first = x
        canonical.second = y
        canonical.offset = offset
    result.actions.add canonical

echo "Testing mirrored reference-policy actions and VM budgets"
block:
  var checked = 0
  for policy in ["base.bas", "rusher.bas", "puller.bas"]:
    for class in HeroClass:
      for scenario in Scenario:
        for boundary in [false, true]:
          let
            red = decision(policy, RedTeam, class, scenario, boundary)
            blue = decision(policy, BlueTeam, class, scenario, boundary,
              reverseEnemies = scenario == EqualTargets)
            label = &"{policy}, {class}, {scenario}, boundary={boundary}"
          doAssert red.actions == blue.actions,
            label & "\nred: " & $red.actions & "\nblue: " & $blue.actions
          doAssert red.instructions == blue.instructions, label
          doAssert red.work == blue.work, label
          inc checked
  echo "Mirrored policy scenarios checked: ", checked

echo "Testing pullers walk into camp aggro without casting or attacking"
for team in Team:
  for scenario in [Pulling, Luring]:
    let result = decision("puller.bas", team, Ranger, scenario)
    var walked = false
    for action in result.actions:
      doAssert action.kind notin [ActionAttackTarget, ActionAttackMove,
        ActionCastTarget, ActionCastPoint, ActionUseItem]
      if action.kind == ActionWalkTo:
        walked = true
    doAssert walked

echo "Testing script cell boundaries reflect exactly"
for tile in -mapTiles() .. mapTiles():
  for offset in [-1'i32, 0, 1, WorldScale div 2, WorldScale - 1]:
    let position = tile.int32 * WorldScale + offset
    doAssert mapCoordinate(position, RedTeam) +
      mapCoordinate(-position, BlueTeam) == mapTiles() - 1
