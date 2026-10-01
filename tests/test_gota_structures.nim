import
  std/[os, tempfiles],
  bassy,
  polyworld/cli,
  ../examples/gods_of_the_arena/[bots, content, maps, replays, sim,
    structures]

const Probe = """' @gota-structures
sameSelf = self.id = selfId and self.hp = selfHp
sameSelf = sameSelf and self.team = selfTeam and self.mana = selfMana
sameSelf = sameSelf and self.position.x = selfInfo(0) + map.origin - .5
sameSelf = sameSelf and self.position.y = selfInfo(1) + map.origin - .5
sameSelf = sameSelf and self.moveSpeed = selfInfo(16)
sameSelf = sameSelf and self.attackRange = selfInfo(15)
sameSelf = sameSelf and self.abilityPoints = abilityPoints()
sameBuildings = match.enemyTowers = matchInfo(12)
sameBuildings = sameBuildings and match.enemyBarracks = matchInfo(14)
sameBuildings = sameBuildings and match.allyTowers = matchInfo(8)
sameObjects = match.objectCount = objectCount()
for i = 0 to match.objectCount - 1
  sameObjects = sameObjects and objects(i).id = objectId(i)
  sameObjects = sameObjects and objects(i).team = objectTeam(i)
  sameObjects = sameObjects and objects(i).hp = objectHp(i)
  sameObjects = sameObjects and objects(i).maxHp = objectInfo(i, 2)
  sameObjects = sameObjects and objects(i).alive = objectAlive(i)
  sameObjects = sameObjects and objects(i).targetId = objectTarget(i)
  sameObjects = sameObjects and objects(i).position.x = objectInfo(i, 0) + map.origin - .5
  for slot = 0 to 5
    sameObjects = sameObjects and objectItems(i * 6 + slot).id = objectItemId(i, slot)
    sameObjects = sameObjects and objectItems(i * 6 + slot).count = objectItemCount(i, slot)
  next slot
next i
sameSpells = match.spellCount = spellCount()
for i = 0 to match.spellCount - 1
  sameSpells = sameSpells and spells(i).abilityId = spellAbility(i)
  sameSpells = sameSpells and spells(i).casterId = spellCasterId(i)
  sameSpells = sameSpells and spells(i).impactTick = spellImpactTick(i)
  sameSpells = sameSpells and spells(i).position.x = spellInfo(i, 0) + map.origin - .5
next i
sameAbilities = 1
for slot = 0 to 3
  sameAbilities = sameAbilities and abilities(slot).level = abilityLevel(slot)
  sameAbilities = sameAbilities and abilities(slot).range = abilityInfo(slot, 0)
  sameAbilities = sameAbilities and abilities(slot).charges = abilityCharges(slot)
next slot
readTile(floor(self.position.x + .5), floor(self.position.y + .5), self.layer)
sameTile = tile.walkable = terrainWalkableAt(tile.x, tile.y, tile.layer)
sameTile = sameTile and tile.kind = terrainKindAt(tile.x, tile.y, tile.layer)
readTile(-1, -1, -1)
invalidTile = tile.walkable = 0 and tile.kind = 0
if stage = 1 then
  before = self.abilityPoints
  accepted = levelAbility(1)
  refreshed = accepted and lastAction.accepted and lastAction.error = 0
  refreshed = refreshed and abilities(1).level = abilityLevel(1)
  refreshed = refreshed and self.abilityPoints = before - 1
  accepted = levelAbility(-1)
  rejected = accepted = 0 and lastAction.accepted = 0
  rejected = rejected and lastAction.error = lastActionError()
  rejected = rejected and lastAction.error <> 0
  ownHpBefore = self.hp
  self.hp = 1
elseif stage = 2 then
  before = self.hp
  accepted = useItem(0)
  usedItem = accepted and lastAction.accepted and lastAction.error = 0
  usedItem = usedItem and self.hp > before and items(0).count = 1
  usedItem = usedItem and items(0).cooldownTicks = itemCooldown(0)
end if
"""

echo "Testing structured observations preserve the legacy API and visibility"
block:
  let
    directory = createTempDir("gota-structures-", "")
    path = directory / "structured.bas"
    legacy = directory / "legacy.bas"
    game = newGame(generateMap(54), 240, 10, false,
      ReplayData(), drafting = false)
  defer:
    removeDir(directory)
  writeFile(path, Probe)
  writeFile(legacy, "hp = selfHp\ncount = objectCount()\n")
  game.loadBots([BotGroup(path: path, count: 1),
    BotGroup(path: legacy, count: 9)])
  let
    world = game.world
    hero = world.heroes[0]
    enemy = world.heroes[5]
    vm = game.heroVms[0]
  doAssert vm.structured
  doAssert vm.legacyHeroData
  doAssert not game.heroVms[1].structured
  doAssert vm.limits.maxArrays > game.heroVms[1].limits.maxArrays
  hero.level = 6
  hero.abilityLevels = [0'i32, 0, 0, 0]
  hero.refreshHeroStats()
  hero.hp = hero.maxHp
  hero.inventory[0] = VitalityElixir
  hero.itemCounts[0] = 2
  hero.attackObjectId = enemy.id
  world.casts = @[
    SpellCast(
      heroId: enemy.id,
      ability: MeteorStrike,
      position: hero.position,
      started: 0,
      impact: 30,
      ends: 42
    ),
    SpellCast(
      heroId: enemy.id,
      ability: MeteorStrike,
      position: enemy.position,
      started: 0,
      impact: 30,
      ends: 42
    )
  ]
  for cells in world.teamVisible.mitems:
    for cell in cells.mitems:
      cell = 255
  game.runBotDecisions()
  doAssert not vm.failed, vm.lastError
  for name in ["sameSelf", "sameBuildings", "sameObjects", "sameSpells", "sameAbilities", "sameTile",
    "invalidTile"]:
      doAssert vm.runtime.getGlobal(name) != 0, name
  let oldCount = int(vm.runtime.getGlobal("match.objectCount"))
  doAssert oldCount > 0
  doAssert vm.runtime.getGlobal("match.spellCount") == 2
  doAssert game.heroVms[1].runtime.getGlobal("hp") == world.heroes[1].hp
  vm.runtime.setGlobal("stage", 1)
  inc world.tick
  game.runBotDecisions()
  doAssert not vm.failed, vm.lastError
  doAssert vm.runtime.getGlobal("refreshed") != 0
  doAssert vm.runtime.getGlobal("rejected") != 0
  doAssert hero.hp == vm.runtime.getGlobal("ownHpBefore")
  vm.runtime.setGlobal("stage", 2)
  hero.hp = hero.maxHp - 50
  inc world.tick
  game.runBotDecisions()
  doAssert not vm.failed, vm.lastError
  doAssert vm.runtime.getGlobal("usedItem") != 0
  vm.runtime.setGlobal("stage", 0)
  for cells in world.teamVisible.mitems:
    for cell in cells.mitems:
      cell = 0
  let tile = mapCoordinate(hero.position.z) * mapTiles().int32 +
    mapCoordinate(hero.position.x)
  world.teamVisible[hero.team.ord][tile] = 255
  inc world.tick
  game.runBotDecisions()
  doAssert not vm.failed, vm.lastError
  doAssert vm.runtime.getGlobal("sameSpells") != 0
  doAssert vm.runtime.getGlobal("match.spellCount") == 1
  doAssert vm.runtime.getArray("spells.casterId", 0) == 0
  doAssert vm.runtime.getArray("spells.abilityId", 1) == 0
  doAssert vm.runtime.getGlobal("self.hp") == hero.hp
  let count = int(vm.runtime.getGlobal("match.objectCount"))
  doAssert count < oldCount
  for i in 0 ..< count:
    doAssert vm.runtime.getArray("objects.id", i.int32) != enemy.id
    doAssert vm.runtime.getArray("objects.targetId", i.int32) != enemy.id
  for i in count ..< oldCount:
    doAssert vm.runtime.getArray("objects.id", i.int32) == 0
    doAssert vm.runtime.getArray("objects.alive", i.int32) == 0
    doAssert vm.runtime.getArray("objectItems.count", int32(i * 6)) == 0
  world.casts.setLen(0)
  inc world.tick
  game.runBotDecisions()
  doAssert not vm.failed, vm.lastError
  doAssert vm.runtime.getGlobal("match.spellCount") == 0
  doAssert vm.runtime.getArray("spells.abilityId", 0) == 0
  doAssert usesStructures("  \n' @gota-structures\nend")
  doAssert not usesStructures("")
  doAssert not usesStructures("' ordinary policy\nend")

echo "Testing lazy world columns stay frozen after commands"
block:
  let
    directory = createTempDir("gota-lazy-", "")
    path = directory / "structured.bas"
    legacy = directory / "legacy.bas"
    game = newGame(generateMap(54), 240, 10, false,
      ReplayData(), drafting = false)
  defer:
    removeDir(directory)
  writeFile(path, """' @gota-structures
beforeHp = self.hp
beforeCount = items(0).count
accepted = useItem(0)
afterHp = self.hp
afterCount = items(0).count
for i = 0 to match.objectCount - 1
  if objects(i).id = self.id then
    observedHp = objects(i).hp
    observedCount = objectItems(i * 6).count
    objects(i).hp = 1
    localHp = objects(i).hp
  end if
next i
""")
  writeFile(legacy, "end\n")
  game.loadBots([BotGroup(path: path, count: 1),
    BotGroup(path: legacy, count: 9)])
  let
    hero = game.world.heroes[0]
    vm = game.heroVms[0]
  doAssert not vm.legacyHeroData
  hero.hp = hero.maxHp - 50
  hero.inventory[0] = VitalityElixir
  hero.itemCounts[0] = 2
  game.runBotDecisions()
  doAssert not vm.failed, vm.lastError
  doAssert vm.runtime.getGlobal("accepted") != 0
  doAssert vm.runtime.getGlobal("afterHp") >
    vm.runtime.getGlobal("beforeHp")
  doAssert vm.runtime.getGlobal("afterCount") == 1
  doAssert vm.runtime.getGlobal("observedHp") ==
    vm.runtime.getGlobal("beforeHp")
  doAssert vm.runtime.getGlobal("observedCount") == 2
  doAssert vm.runtime.getGlobal("localHp") == 1
  doAssert hero.hp == vm.runtime.getGlobal("afterHp")

echo "Testing fused legacy scalar reads remain available in record policies"
block:
  let
    directory = createTempDir("gota-mixed-scalars-", "")
    path = directory / "structured.bas"
    game = newGame(generateMap(54), 240, 10, false,
      ReplayData(), drafting = false)
  defer:
    removeDir(directory)
  writeFile(path, "' @gota-structures\nsum = sum + selfHp\n")
  game.loadBots([BotGroup(path: path, count: 10)])
  game.runBotDecisions()
  for i, vm in game.heroVms:
    doAssert vm.legacyHeroData
    doAssert not vm.failed, vm.lastError
    doAssert vm.runtime.getGlobal("sum") == game.world.heroes[i].hp

echo "Structured GotA observation checks passed"
