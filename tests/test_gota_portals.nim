import
  std/[os, tempfiles],
  bassy,
  polyworld/[cli, pathing, tapes],
  ../examples/gods_of_the_arena/[bots, content, maps, replays, sim]

proc portalGame(team = RedTeam, size = 116): Game =
  ## Creates a quiet match with one living hero and allied tower anchors.
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
    if building.team != team:
      building.hp = 0
  let hero = result.world.heroes[team.ord * 5]
  hero.state = Marching
  hero.hp = hero.maxHp
  hero.inventory[0] = PortalScroll
  hero.itemCounts[0] = 2
  result.tickWorld(nil)

proc step(game: Game, ticks: int32) =
  ## Advances real simulation ticks without bot commands.
  for i in 0 ..< ticks:
    game.tickWorld(nil)

echo "Testing scroll stacks, channel timing, landing and shared cooldown"
for size in [64, 116, 256]:
  for team in Team:
    let
      game = portalGame(team, size)
      world = game.world
      hero = world.heroes[team.ord * 5]
      start = hero.position
      aim = if team == RedTeam: 0'i32 else: size.int32 - 1
    hero.gold = 10_000
    doAssert world.applyBuyItem(hero.id, PortalScroll.ord.int32)
    doAssert hero.itemCounts[0] == 3
    doAssert world.applyUseItemAt(hero.id, 0, aim, aim)
    let
      destination = hero.portalDestination
      tower = world.buildingById(hero.portalTowerId)
      ends = hero.portalEnds
      casts = world.casts.len
    doAssert ends == world.tick + 3 * TickRate
    doAssert hero.itemCounts[0] == 2
    doAssert tower.team == team and tower.kind == TowerBuilding
    doAssert within(destination, tower.position,
      TowerAttackRanges[tower.tier])
    doAssert not world.applyWalkTo(hero.id, aim, aim)
    doAssert hero.lastActionError == ActionChanneling
    doAssert not world.applyAttackMove(hero.id, aim, aim)
    doAssert not world.applyAttackTarget(hero.id, 0)
    doAssert not world.applyCastTarget(hero.id, 0, hero.id)
    doAssert not world.applyUseItem(hero.id, 0)
    doAssert not world.applyUseItemAt(hero.id, 0, aim, aim)
    game.step(PortalChannelTicks - 1)
    doAssert hero.position == start
    doAssert world.casts.len == casts
    doAssert hero.portalEnds == ends
    game.step(1)
    doAssert hero.portalEnds == 0
    doAssert within(hero.position, destination, 10)
    doAssert hero.velocity == Heading()
    doAssert hero.portalCooldownEnds == world.tick + 60 * TickRate
    let layer = layers[hero.navLayer]
    doAssert navigationOpen(hero.navLayer.int,
      mapCoordinate(hero.position.x).int + mapOrigin() - layer.originX,
      mapCoordinate(hero.position.z).int + mapOrigin() - layer.originZ)
    hero.inventory[1] = PortalScroll
    hero.itemCounts[1] = 1
    world.tick = hero.portalCooldownEnds - 1
    doAssert not world.applyUseItemAt(hero.id, 1, aim, aim)
    doAssert hero.lastActionError == ActionCooldown
    doAssert hero.itemCounts[1] == 1
    inc world.tick
    doAssert world.applyUseItemAt(hero.id, 1, aim, aim)
    doAssert hero.inventory[1] == NoItem

echo "Testing fractional landings and invalid scroll requests"
block:
  let
    game = portalGame()
    world = game.world
    hero = world.heroes[0]
  doAssert not world.applyUseItemAt(hero.id, -1, 10, 10)
  doAssert hero.lastActionError == ActionInvalidSlot
  doAssert not world.applyUseItemAt(hero.id, 1, 10, 10)
  doAssert hero.lastActionError == ActionEmptySlot
  doAssert not world.applyUseItemAt(hero.id, 0, -1, 10)
  doAssert hero.lastActionError == ActionInvalidPoint
  doAssert not world.applyUseItem(hero.id, 0)
  doAssert hero.itemCounts[0] == 2
  var
    point: WorldPoint
    tower: int32
  doAssert world.portalLanding(hero.team, hero.position, point, tower)
  doAssert world.applyUseItemAt(hero.id, 0,
    mapCoordinate(point.x), mapCoordinate(point.z),
    fixedVec2(0.125'fx, 0.125'fx))
  doAssert hero.portalDestination.x mod WorldScale ==
    WorldScale div 2 + WorldScale div 8 or
    hero.portalDestination.x mod WorldScale ==
      -(WorldScale div 2 - WorldScale div 8)

echo "Testing stun and root interrupt and cannot bypass the shared cooldown"
for stun in [true, false]:
  let
    game = portalGame()
    world = game.world
    hero = world.heroes[0]
    start = hero.position
  doAssert world.applyUseItemAt(hero.id, 0, 0, 0)
  game.step(10)
  if stun:
    world.applyControl(hero.id, StunControl, 4 * TickRate)
  else:
    world.applyControl(hero.id, RootControl, 4 * TickRate)
  doAssert hero.portalEnds == 0
  doAssert hero.portalCooldownEnds == world.tick + PortalCooldownTicks
  doAssert hero.itemCounts[0] == 1
  doAssert not world.applyWalkTo(hero.id, 50, 50)
  doAssert hero.lastActionError == (if stun: ActionStunned else: ActionRooted)
  doAssert not world.applyUseItemAt(hero.id, 0, 0, 0)
  game.step(PortalChannelTicks)
  doAssert hero.position == start

echo "Testing a channel remains vulnerable to damage and lethal attacks"
for lethal in [false, true]:
  let
    game = portalGame()
    world = game.world
    hero = world.heroes[0]
    enemy = world.heroes[5]
  enemy.state = Marching
  enemy.hp = enemy.maxHp
  enemy.place(hero.position)
  enemy.attackObjectId = hero.id
  enemy.inventory[0] = PoisonPotion
  enemy.itemCounts[0] = 1
  hero.hp = if lethal: 1 else: hero.maxHp
  let health = hero.hp
  for cell in world.teamVisible[enemy.team.ord].mitems:
    cell = 255
  doAssert world.applyUseItemAt(hero.id, 0, 0, 0)
  doAssert world.applyUseItem(enemy.id, 0)
  doAssert hero.hp == health - PoisonPotion.itemSpec.strike
  doAssert (hero.portalEnds == 0) == lethal
  if lethal:
    let cooldown = hero.portalCooldownEnds
    enemy.state = Dying
    enemy.hp = 0
    enemy.deathTicks = -100_000
    game.step(1)
    while hero.state == Dying:
      doAssert world.tick < cooldown
      game.step(1)
    doAssert hero.hp > 0
    doAssert hero.portalCooldownEnds == cooldown

echo "Testing destroyed anchors cancel and barracks cannot anchor a portal"
block:
  let
    game = portalGame()
    world = game.world
    hero = world.heroes[0]
    start = hero.position
  doAssert world.applyUseItemAt(hero.id, 0, 0, 0)
  for building in world.buildings.mitems:
    if building.id == hero.portalTowerId:
      building.hp = 0
  game.step(PortalChannelTicks)
  doAssert hero.portalEnds == 0
  doAssert hero.portalCooldownEnds == world.tick + PortalCooldownTicks
  doAssert hero.position == start
  for building in world.buildings.mitems:
    if building.kind == TowerBuilding:
      building.hp = 0
  world.syncBuildings()
  hero.portalCooldownEnds = 0
  doAssert not world.applyUseItemAt(hero.id, 0, 0, 0)
  doAssert hero.lastActionError == ActionTargetUnavailable
  doAssert hero.itemCounts[0] == 1

echo "Testing scroll BASIC commands, exact replay hashes and channel seeking"
block:
  let
    directory = createTempDir("gota-portal-", "")
    path = directory / "portal.bas"
    game = newGame(
      generateMap(54),
      100_000,
      10,
      false,
      ReplayData(),
      drafting = false
    )
  defer:
    removeDir(directory)
  writeFile(path, """
if started = 0 then
  bought = buyItem(21)
  accepted = useItemAt(0, 0.25, 0.25)
  started = 1
end if
remaining = selfPortalCooldown
channel = selfChannelTicks
stun = selfStunTicks
root = selfRootTicks
""")
  game.loadBots([BotGroup(path: path, count: 10)])
  game.recorder = initReplayRecorder(game.currentSetup(200), game.map.preset)
  when defined(replayEvents):
    var
      expected: seq[seq[GameEvent]]
      started, completed: int
  for tick in 1 .. 200:
    game.tickWorld(proc() = game.runBotDecisions())
    when defined(replayEvents):
      expected.add game.world.events
      for event in game.world.events:
        if event.kind == PortalStarted:
          inc started
        elif event.kind == PortalCompleted:
          inc completed
  when defined(replayEvents):
    doAssert started == 10 and completed == 10
  for vm in game.heroVms:
    doAssert not vm.failed, vm.lastError
    doAssert vm.runtime.getGlobal("bought") == 1
    doAssert vm.runtime.getGlobal("accepted") == 1
    doAssert vm.runtime.getGlobal("remaining") > 0
    doAssert vm.runtime.getGlobal("channel") == 0
  let
    data = decodeReplay(game.recorder.data.encodeReplay())
    playback = newGame(generateMap(54), 100_000, 0, true, data)
  var snapshot: World
  playback.historyPlayback = true
  playback.replayPlayer = initReplayPlayer(data)
  for tick in 1 .. 200:
    playback.tickWorld(nil)
    when defined(replayEvents):
      doAssert playback.world.events == expected[tick - 1]
    if tick == 20:
      snapshot = playback.world.clone()
      doAssert snapshot.heroes[0].portalEnds > snapshot.tick
  doAssert playback.hashCheck.mismatches == 0
  doAssert playback.stateHash() == game.stateHash()
  playback.world.restore(snapshot)
  doAssert playback.world.heroes[0].portalEnds > playback.world.tick
  doAssert playback.world.heroes[0].itemCounts[0] == 0
  for tick in 21 .. 200:
    playback.tickWorld(nil)
  doAssert playback.hashCheck.mismatches == 0
  doAssert playback.stateHash() == game.stateHash()

echo "test_gota_portals: all checks passed"
