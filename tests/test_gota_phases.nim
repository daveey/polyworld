import
  std/algorithm,
  polyworld/[metrics, pathing, rngs],
  ../examples/gods_of_the_arena/[content, events, maps, replays, sim]

proc arena(): Game =
  ## Creates a quiet open lane for simultaneous impact tests.
  result = newGame(generateMap(2026), 100000, 10, false,
    ReplayData(), drafting = false)
  result.world.spawnTimerTicks = 100000
  result.world.camps.setLen(0)
  for building in result.world.buildings.mitems:
    building.hp = 0
  result.world.syncBuildings()
  for hero in result.world.heroes:
    hero.hp = 0
    hero.state = Dying
    hero.deathTicks = -100000

proc middle(): WorldPoint =
  ## Reads a valid middle-lane cell on the generated arena.
  let point = lanePathPoints[1][lanePathPoints[1].len div 2]
  WorldPoint(x: point.x * (WorldScale div PathUnitsPerTile),
    y: point.y * (WorldScale div PathUnitsPerTile),
    z: point.z * (WorldScale div PathUnitsPerTile))

proc fighter(game: Game, index: int, class = VanguardKnight): Hero =
  ## Arms a living hero to land its next basic attack on this tick.
  result = game.world.heroes[index]
  result.class = class
  result.state = Fighting
  result.hp = 1
  result.refreshHeroStats()
  result.hp = 1
  result.place(middle())
  result.swingClip = heroAttackClips[0]
  result.swingTicks = game.world.heroHitTicks(result) - 1
  result.damageLanded = false

proc deaths(world: World, target: int32): int =
  ## Counts death events to detect duplicate attribution after overkill.
  for event in world.events:
    if event.kind == Death and event.target.id == target:
      inc result

proc lastHit(team: Team, seed: int32, reversed: bool): bool =
  ## Measures mirrored hero-versus-creep credit with different real identities.
  let
    game = arena()
    hero = game.fighter(if team == RedTeam: 0 else: 8)
    direction = if team == RedTeam: 1'i32 else: -1'i32
    center = middle()
    point = WorldPoint(x: direction * center.x, y: center.y,
      z: direction * center.z)
    victimId = if team == RedTeam: 1001'i32 else: 1009'i32
    allyId = if team == RedTeam: 2001'i32 else: 2999'i32
  game.world.matchSeed = seed
  hero.hp = hero.maxHp
  hero.place(point)
  hero.attackObjectId = victimId
  var
    ally = Footman(id: allyId, team: team, hp: FootmanHp,
      state: Fighting, lane: 1, swingClip: attackClips[0],
      swingTicks: footmanHitTicks(attackClips[0]) - 1, targetId: victimId)
    victim = Footman(id: victimId, team: Team(1 - team.ord), hp: 1,
      state: Fighting, lane: 1, swingTicks: -1)
  ally.place(point)
  victim.place(point)
  game.world.footmen = @[ally, victim]
  if reversed:
    game.world.footmen.reverse()
  game.tickWorld(nil)
  doAssert game.world.deaths(victimId) == 1
  for event in game.world.events:
    if event.kind == Death and event.target.id == victimId:
      doAssert event.actor.id in [hero.id, allyId]
      return event.actor.id == hero.id
  doAssert false, "The creep must have a credited last hit."

echo "Testing seeded last hits ignore faction IDs and submission order"
var creditedTypes: set[bool]
for seed in 0'i32 .. 63'i32:
  let expected = lastHit(RedTeam, seed, false)
  creditedTypes.incl(expected)
  for team in Team:
    for reversed in [false, true]:
      doAssert lastHit(team, seed, reversed) == expected
doAssert creditedTypes == {false, true}, "The match seed must affect ties."

echo "Testing every hero trades lethal hits in either storage order"
for class in HeroClass:
  for reverse in [false, true]:
    let
      game = arena()
      red = game.fighter(0, class)
      blue = game.fighter(5, class)
    red.attackObjectId = blue.id
    blue.attackObjectId = red.id
    red.xp = xpForNextLevel(1) - 1
    blue.xp = xpForNextLevel(1) - 1
    if reverse:
      game.world.heroes.reverse()
      for i, hero in game.world.heroes:
        game.world.stats.teams[i] = hero.team.ord
    game.tickWorld(nil)
    for hero in [red, blue]:
      doAssert hero.hp <= 0, $class
      doAssert hero.state == Dying and hero.deaths == 1
      doAssert hero.level > 1, "The lethal exchange must grant kill XP."
      doAssert hero.gold == 150 + 100
      doAssert game.world.deaths(hero.id) == 1
      let index = game.world.heroIndex(hero.id)
      doAssert game.world.stats.values[index][KillsMetric] == 1
      doAssert game.world.stats.values[index][LossesMetric] == 1
    doAssert game.world.teamHeroKills == [1, 1]
    game.tickWorld(nil)
    doAssert red.deaths == 1 and blue.deaths == 1

echo "Testing creeps trade lethal hits in either storage order"
for first in Team:
  let game = arena()
  for team in [first, Team(1 - first.ord)]:
    var creep = Footman(id: 1000 + team.ord.int32, team: team,
      hp: FootmanDamage, state: Fighting, lane: 1,
      swingClip: attackClips[0],
      swingTicks: footmanHitTicks(attackClips[0]) - 1,
      targetId: 1000 + (1 - team.ord).int32)
    creep.place(middle())
    game.world.footmen.add creep
  game.tickWorld(nil)
  for creep in game.world.footmen:
    doAssert creep.hp <= 0 and creep.state == Dying
    doAssert game.world.deaths(creep.id) == 1

echo "Testing an in-flight tower shot and hero both land their final attacks"
for team in Team:
  let
    game = arena()
    hero = game.fighter(team.ord * 5)
    enemy = Team(1 - team.ord)
  game.world.buildings = @[
    Building(id: 10, kind: TowerBuilding, team: enemy, lane: 1,
      tier: OuterTower, position: middle(), hp: 1, maxHp: 1,
      targetId: hero.id, attackTicks: TowerAttackTicks - 1)
  ]
  game.world.towerShots.add TowerShot(
    sourceId: 10, targetId: hero.id, team: enemy,
    damage: TowerDamages[OuterTower], position: hero.position,
    previous: hero.position, started: game.world.tick
  )
  hero.attackObjectId = 10
  game.tickWorld(nil)
  doAssert hero.hp <= 0 and hero.state == Dying
  doAssert game.world.buildings[0].hp <= 0
  doAssert hero.gold == 150 + 75

echo "Testing command damage joins the same combat phase"
for first in [0, 5]:
  let
    game = arena()
    red = game.fighter(0)
    blue = game.fighter(5)
  for hero in [red, blue]:
    hero.swingTicks = -1
    hero.inventory[0] = PoisonPotion
    hero.itemCounts[0] = 1
  red.attackObjectId = blue.id
  blue.attackObjectId = red.id
  game.tickWorld(proc() =
    ## Submits both poison commands before either lethal hit resolves.
    doAssert game.world.applyUseItem(game.world.heroes[first].id, 0)
    doAssert game.world.applyUseItem(game.world.heroes[5 - first].id, 0)
    doAssert red.hp > 0 and blue.hp > 0
  )
  doAssert red.hp <= 0 and blue.hp <= 0

echo "Testing simultaneous overkill awards one kill and all assists"
var credited = -1'i32
var creditedSlots: set[0 .. 1]
for first in [0, 1]:
  let
    game = arena()
    red = game.fighter(0)
    ally = game.fighter(1)
    blue = game.fighter(5)
  blue.swingTicks = -1
  for hero in [red, ally]:
    hero.swingTicks = -1
    hero.attackObjectId = blue.id
    hero.inventory[0] = PoisonPotion
    hero.itemCounts[0] = 1
  game.tickWorld(proc() =
    ## Reverses the same-tick submission order without changing the hits.
    doAssert game.world.applyUseItem(game.world.heroes[first].id, 0)
    doAssert game.world.applyUseItem(game.world.heroes[1 - first].id, 0)
  )
  doAssert game.world.deaths(blue.id) == 1
  doAssert red.gold + ally.gold == 400
  var kills, assists: int64
  for i in 0 .. 1:
    kills += game.world.stats.values[i][KillsMetric]
    assists += game.world.stats.values[i][AssistsMetric]
  doAssert kills == 1 and assists == 1
  for event in game.world.events:
    if event.kind == Death and event.target.id == blue.id:
      if credited < 0:
        credited = event.actor.id
      doAssert event.actor.id == credited

for tick in 0 .. 31:
  let
    game = arena()
    red = game.fighter(0)
    ally = game.fighter(1)
    blue = game.fighter(5)
  game.world.tick = tick.int32
  blue.swingTicks = -1
  for hero in [red, ally]:
    hero.swingTicks = -1
    hero.attackObjectId = blue.id
    hero.inventory[0] = PoisonPotion
    hero.itemCounts[0] = 1
  game.tickWorld(proc() =
    ## Samples exact hit ties across ticks rather than favoring a fixed ID.
    doAssert game.world.applyUseItem(red.id, 0)
    doAssert game.world.applyUseItem(ally.id, 0)
  )
  for i in 0 .. 1:
    if game.world.stats.values[i][KillsMetric] == 1:
      creditedSlots.incl(i)
doAssert creditedSlots == {0, 1}

echo "Testing a hero and creep trade, retaining nearby XP without revival"
block:
  let
    game = arena()
    hero = game.fighter(0)
  hero.xp = xpForNextLevel(1) - 1
  var creep = Footman(id: 1000, team: BlueTeam, hp: 1,
    state: Fighting, lane: 1, targetHeroId: hero.id,
    swingClip: attackClips[0],
    swingTicks: footmanHitTicks(attackClips[0]) - 1)
  creep.place(middle())
  game.world.footmen = @[creep]
  hero.attackObjectId = creep.id
  game.tickWorld(nil)
  doAssert hero.hp <= 0 and hero.state == Dying and hero.level == 2
  doAssert hero.totalXp == CreepNearbyXp and hero.gold == 165
  doAssert game.world.footmen[0].hp <= 0

echo "Testing two destroyed keeps end as a draw"
block:
  let
    game = arena()
    red = game.fighter(0)
    blue = game.fighter(5)
  for hero in [red, blue]:
    let enemy = 1 - hero.team.ord
    game.world.forts[enemy].center = middle()
    game.world.forts[enemy].hp = 1
    hero.attackObjectId = game.world.forts[enemy].id
  game.tickWorld(nil)
  doAssert game.world.forts[0].hp == 0 and game.world.forts[1].hp == 0
  doAssert game.finished() and game.world.gameOver and game.world.draw
  doAssert game.world.outcome() == "draw"
  for score in game.world.scores():
    doAssert score == 0
  var endings = 0
  for event in game.world.events:
    if event.kind == MatchEnded:
      inc endings
      doAssert event.amount == -1 and event.cause == GodDestroyed
  doAssert endings == 1

echo "Testing hero attack starts rotate with the simulation tick"
for tick in 0 .. 10:
  let game = arena()
  game.world.tick = tick.int32
  game.world.rng = initRng(1234)
  for i in 0 ..< game.world.heroes.len:
    let hero = game.fighter(i)
    hero.hp = hero.maxHp
    hero.swingTicks = -1
    hero.attackObjectId = game.world.heroes[(i + 5) mod 10].id
  var expected = game.world.rng
  game.tickWorld(nil)
  for offset in 0 ..< game.world.heroes.len:
    let index = (tick + 1 + offset) mod game.world.heroes.len
    doAssert game.world.heroes[index].swingClip ==
      heroAttackClips[expected.below(2)]

echo "Testing creep attack starts rotate with the simulation tick"
for tick in 0 .. 5:
  let game = arena()
  game.world.tick = tick.int32
  game.world.rng = initRng(1234)
  game.world.forts[BlueTeam.ord].center = middle()
  for i in 0 .. 2:
    var creep = Footman(id: 1000 + i.int32, team: RedTeam,
      hp: FootmanHp, lane: 1, swingTicks: -1)
    creep.place(middle())
    game.world.footmen.add creep
  var expected = game.world.rng
  game.tickWorld(nil)
  for offset in 0 .. 2:
    let index = (tick + 1 + offset) mod 3
    doAssert game.world.footmen[index].swingClip ==
      attackClips[expected.below(2)]

echo "GotA simultaneous combat checks passed"
