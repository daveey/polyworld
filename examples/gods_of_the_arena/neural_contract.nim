## GotA neural observation and action contract v1 (hash-pinned).
##
## One module owns the fixed-size ego-centric observation, the five-head
## action decoder and the demonstration encoder, so the hosted neural seat,
## the native training library and the mapping-ceiling tool can never drift
## apart. Layout, normalizers and rationale: neural_basic.md. Any change to a
## feature list, a normalizer or a decode rule must change the contract text
## below (and therefore its SHA-256).
##
## Decoding is integer-only (a Q16 direction table) so a decoded command is
## the same on every platform; the observation is FP32.

import
  std/[algorithm, math, strutils],
  crunchy, fixxy,
  polyworld/[bodies, metrics, pathing],
  content, maps, observations, scores, sim, terrains

const
  ObsSelf* = 48
  ObsAbilityFeatures* = 16
  ObsAbilities* = 4 * ObsAbilityFeatures
  ObsItemFeatures* = 25
  ObsItems* = InventorySlots * ObsItemFeatures
  ObjectSlots* = 25
  ObjectFeatures* = 40
  ObsObjects* = ObjectSlots * ObjectFeatures
  SpellSlots* = 4
  SpellFeatures* = 8
  ObsSpells* = SpellSlots * SpellFeatures
  ObsSummary* = 16
  TerrainSide* = 9
  TerrainStride* = 2
  ObsTerrain* = TerrainSide * TerrainSide
  GoalSize* = 16
  ObsSelfOffset* = 0
  ObsAbilityOffset* = ObsSelfOffset + ObsSelf
  ObsItemOffset* = ObsAbilityOffset + ObsAbilities
  ObsObjectOffset* = ObsItemOffset + ObsItems
  ObsSpellOffset* = ObsObjectOffset + ObsObjects
  ObsSummaryOffset* = ObsSpellOffset + ObsSpells
  ObsTerrainOffset* = ObsSummaryOffset + ObsSummary
  ObsGoalOffset* = ObsTerrainOffset + ObsTerrain
  ObservationSize* = ObsGoalOffset + GoalSize

  HeadSizes* = [8, 25, 49, 4, 6]
  ActionHeads* = HeadSizes.len
  ActionOutputs* = 8 + 25 + 49 + 4 + 6

  SlotSelf* = 0
  SlotAllies* = 1  ## four
  SlotEnemies* = 5 ## five
  SlotCreeps* = 10 ## seven
  SlotStructures* = 17 ## own god, enemy god, own forward tower, enemy structure
  SlotNeutrals* = 21 ## four
  CreepSlots = 7
  NeutralSlots = 4

  WalkRings*: array[3, int32] = [2 * WorldScale, 5 * WorldScale, 12 * WorldScale]
  CastRings*: array[3, int32] = [WorldScale div 2, WorldScale * 5 div 4,
    WorldScale * 5 div 2]
  Directions*: array[16, (int32, int32)] = [
    (65536'i32, 0'i32), (60547'i32, 25080'i32), (46341'i32, 46341'i32),
    (25080'i32, 60547'i32), (0'i32, 65536'i32), (-25080'i32, 60547'i32),
    (-46341'i32, 46341'i32), (-60547'i32, 25080'i32), (-65536'i32, 0'i32),
    (-60547'i32, -25080'i32), (-46341'i32, -46341'i32), (-25080'i32, -60547'i32),
    (0'i32, -65536'i32), (25080'i32, -60547'i32), (46341'i32, -46341'i32),
    (60547'i32, -25080'i32)]

  DefaultDecisionPeriod* = 4
  GoalNames* = ["w_score", "w_win", "w_xp", "w_gold", "w_hero_kill",
    "w_assist", "w_death", "w_last_hit", "w_neutral_kill", "w_tower_damage",
    "w_structure_kill", "w_hero_damage", "w_damage_taken", "w_push_depth",
    "w_god_damage", "w_reserved"]

  SelfFeatureNames = ["alive", "hp_frac", "mana_frac", "max_hp/2000",
    "max_mana/1000", "gold/1000", "level/20", "xp_to_next_frac",
    "total_xp/20000", "x/64(team)", "y/64(team)", "team", "battle_frac",
    "attack_cooldown/48", "attack_range_tiles/10", "attack_damage/200",
    "move_tiles_per_s/5", "has_target", "stun/72", "root/72", "silence/72",
    "channel/72", "portal_cd/1440", "respawn/1440", "ability_points/4",
    "in_own_spawn", "can_shop", "deaths/10", "last_action_error",
    "buyback_affordable", "class0", "class1", "class2", "class3", "class4",
    "class5", "class6", "class7", "class8", "class9", "role0", "role1",
    "role2", "role3", "role4", "vel_x*10", "vel_y*10", "has_move_target"]
  AbilityFeatureNames = ["level/max", "learned", "cooldown/240",
    "charges/3", "recharge/240", "mana_cost/200", "castable", "damage/300",
    "heal/300", "restore/200", "range_tiles/10", "cast_self", "cast_melee",
    "cast_projectile", "cast_area", "area_radius_tiles/3"]
  ObjectFeatureNames = ["present", "dx/16(clip4)", "dy/16(clip4)",
    "dist/16(clip8)", "hp_frac", "hp/2000", "team(+1 ally,-1 enemy)",
    "kind_god", "kind_hero", "kind_creep", "kind_tower", "kind_barracks",
    "kind_neutral", "alive", "level/20", "mana/1000", "targets_me",
    "is_my_target", "targets_ally_hero", "stun/72", "root/72", "silence/72",
    "vel_x*10", "vel_y*10", "facing_x", "facing_y", "in_my_range",
    "last_hittable", "returning", "subclass", "class0", "class1", "class2",
    "class3", "class4", "class5", "class6", "class7", "class8", "class9"]
  SpellFeatureNames = ["present", "dx/16", "dy/16", "dist/16",
    "impact/72", "hostile", "harmless", "ability/40"]
  SummaryNames = ["own_god_hp", "own_god_exposed", "own_towers",
    "own_barracks", "enemy_towers_known", "enemy_barracks_known",
    "enemy_god_hp_visible_or_-1", "own_heroes_alive", "enemy_heroes_visible",
    "wave_timer", "own_levels/50", "visible_enemy_levels/50", "score/5000",
    "kills/10", "assists/10", "zero"]

static:
  doAssert SelfFeatureNames.len == ObsSelf
  doAssert AbilityFeatureNames.len == ObsAbilityFeatures
  doAssert ObjectFeatureNames.len == ObjectFeatures
  doAssert SpellFeatureNames.len == SpellFeatures
  doAssert SummaryNames.len == ObsSummary
  doAssert ObservationSize == 1407

proc observationContractText*(): string =
  ## The canonical text the observation hash pins.
  result = "gota-neural-basic/1 observation v1 float32[" & $ObservationSize &
    "] team-frame (blue rotated 180);\nself:" & SelfFeatureNames.join(",") &
    "\nability x4:" & AbilityFeatureNames.join(",") &
    "\nitem x6: onehot23(NoItem..ManaPotion),count/4,cooldown/240" &
    "\nobject slots 25 (0 self,1-4 allies seat order,5-9 enemies seat order " &
    "visible,10-16 nearest visible lane creeps,17 own god,18 enemy god " &
    "visible,19 own forward tower,20 nearest visible enemy tower/barracks," &
    "21-24 nearest visible neutrals):" & ObjectFeatureNames.join(",") &
    "\nspells x4 (visible, unresolved, sorted impact,dist):" &
    SpellFeatureNames.join(",") &
    "\nsummary:" & SummaryNames.join(",") &
    "\nterrain 9x9 stride 2 tiles known-walkable, row-major team-frame" &
    "\ngoal:" & GoalNames.join(",")

proc actionContractText*(): string =
  ## The canonical text the action hash pins.
  "gota-neural-basic/1 action v1 heads verb8,target25,point49,ability4,item6;" &
    "verbs noop,walk,attackMove,attackTarget,castTarget,castPoint,useItem," &
    "useItemAt; point 0=centre, 1+ring*16+dir, dir k at k*22.5deg ccw team " &
    "frame (Q16 table), walk rings 2,5,12 tiles about self rounded to tile " &
    "centre, cast rings 0.5,1.25,2.5 tiles about target object exact; " &
    "invalid->noop; issued once on the decision tick; slots as observation v1"

proc hexHash(text: string): string =
  for value in sha256(cast[pointer](text.cstring), text.len):
    result.add value.toHex(2).toLowerAscii()

let
  ObservationContractHash* = hexHash(observationContractText())
  ActionContractHash* = hexHash(actionContractText())

type
  CommandKind* = enum
    NoCommand, WalkCommand, AttackMoveCommand, AttackTargetCommand,
    CastTargetCommand, CastPointCommand, UseItemCommand, UseItemAtCommand
  NeuralCommand* = object
    ## A concrete hero order, in the host's own argument space.
    kind*: CommandKind
    objectId*: int32
    ability*, item*: int32
    point*: FixedVec2 ## map tile-centre coordinates (as BASIC passes them)
    tick*: int32
  DecisionFrame* = object
    ## What the slots named on one decision tick.
    tick*: int32
    heroIndex*: int
    team*: Team
    alive*: bool
    selfPos*: WorldPoint
    ids*: array[ObjectSlots, int32]
    positions*: array[ObjectSlots, WorldPoint]
  Heads* = array[ActionHeads, int32]

template side(team: Team): int32 = (if team == RedTeam: 1'i32 else: -1'i32)

proc clampf(x, lo, hi: float32): float32 {.inline.} = max(lo, min(hi, x))

proc tiles(value: int32): float32 {.inline.} = float32(value) / float32(WorldScale)

proc mapPoint*(p: WorldPoint): FixedVec2 =
  ## World position to BASIC map coordinates (tile centres at integers).
  let half = int64(mapTiles() div 2)
  proc one(v: int32): Fixed =
    Fixed(int32((int64(v) * FixedScale) div int64(WorldScale) +
      (half * FixedScale) - FixedScale div 2))
  fixedVec2(one(p.x), one(p.z))

proc worldPointOf*(point: FixedVec2): WorldPoint =
  ## BASIC map coordinates to a world position (inverse of `mapPoint`).
  let half = int64(mapTiles() div 2)
  proc one(v: Fixed): int32 =
    int32(((int64(int32(v)) - half * FixedScale + FixedScale div 2) *
      int64(WorldScale)) div FixedScale)
  WorldPoint(x: one(point.x), z: one(point.y))

proc clampToMap(p: WorldPoint): WorldPoint =
  let edge = int32(mapTiles() div 2) * WorldScale - WorldScale div 2
  WorldPoint(x: clamp(p.x, -edge, edge - 1), y: p.y, z: clamp(p.z, -edge, edge - 1))

proc pointCandidate*(anchor: WorldPoint, team: Team, index: int,
    rings: array[3, int32]): WorldPoint =
  ## The world point a point-head index names about an anchor.
  if index <= 0 or index >= 49:
    return anchor
  let
    ring = (index - 1) div 16
    (cx, cy) = Directions[(index - 1) mod 16]
    r = int64(rings[ring])
    s = int64(team.side)
  clampToMap(WorldPoint(
    x: anchor.x + int32((s * int64(cx) * r) div 65536),
    y: anchor.y,
    z: anchor.z + int32((s * int64(cy) * r) div 65536)))

# ---------------------------------------------------------------------------
# Observation

proc objectKindIndex(kind: int32): int =
  ## Object kinds 1..6 (god, hero, creep, tower, barracks, neutral) -> 0..5.
  clamp(int(kind) - 1, 0, 5)

proc heroAlive(hero: Hero): bool = hero.hp > 0 and hero.state != Dying

proc terrainOpen(world: World, team: Team, layer: int32, mx, my: int): bool =
  ## Known walkability at one map tile, as terrainWalkable reports it.
  if mx < 0 or my < 0 or mx >= mapTiles() or my >= mapTiles():
    return false
  if terrainValue(int32(mx), int32(my), layer, TerrainWalkableField) == 0:
    return false
  let floor = layers[int(layer)]
  world.knownWalkable(team, int(layer), mx + mapOrigin() - floor.originX,
    my + mapOrigin() - floor.originZ)

proc writeObject(o: var openArray[float32], base: int, world: World,
    hero: Hero, value: WorldObject, damage: int32, rangeUnits: int32,
    alliedHeroIds: openArray[int32]) =
  let
    s = float32(hero.team.side)
    dx = tiles(value.position.x - hero.position.x) * s
    dy = tiles(value.position.z - hero.position.z) * s
    dist = sqrt(dx*dx + dy*dy)
  o[base + 0] = 1
  o[base + 1] = clampf(dx / 16, -4, 4)
  o[base + 2] = clampf(dy / 16, -4, 4)
  o[base + 3] = clampf(dist / 16, 0, 8)
  o[base + 4] = if value.maxHp > 0: clampf(float32(max(value.hp, 0)) / float32(value.maxHp), 0, 1) else: 0
  o[base + 5] = float32(max(value.hp, 0)) / 2000
  let faction = value.faction
  o[base + 6] = if faction == 2: 0'f32 elif faction == hero.team.ord.int32: 1 else: -1
  o[base + 7 + objectKindIndex(value.kind)] = 1
  o[base + 13] = float32(value.alive)
  o[base + 14] = float32(value.level) / 20
  o[base + 15] = float32(value.mana) / 1000
  o[base + 16] = float32(value.targetId != 0 and value.targetId == hero.id)
  o[base + 17] = float32(value.id != 0 and value.id == hero.attackObjectId)
  var targetsAlly = false
  if value.targetId != 0 and value.targetId != hero.id:
    for id in alliedHeroIds:
      if id == value.targetId:
        targetsAlly = true
  o[base + 18] = float32(targetsAlly)
  o[base + 19] = clampf(float32(value.controlTicks[StunControl]) / 72, 0, 2)
  o[base + 20] = clampf(float32(value.controlTicks[RootControl]) / 72, 0, 2)
  o[base + 21] = clampf(float32(value.controlTicks[SilenceControl]) / 72, 0, 2)
  o[base + 22] = clampf(tiles(value.velocity.x) * s * 10, -4, 4)
  o[base + 23] = clampf(tiles(value.velocity.z) * s * 10, -4, 4)
  let flen = sqrt(float32(value.facing.x)*float32(value.facing.x) +
    float32(value.facing.z)*float32(value.facing.z))
  if flen > 0:
    o[base + 24] = float32(value.facing.x) / flen * s
    o[base + 25] = float32(value.facing.z) / flen * s
  o[base + 26] = float32(dist * float32(WorldScale) <= float32(rangeUnits))
  o[base + 27] = float32(value.hp > 0 and value.hp <= damage)
  o[base + 28] = float32(value.returning)
  if value.kind == 3:
    o[base + 29] = float32(value.class)
  elif value.kind == 6:
    o[base + 29] = float32(value.class) / 3
  if value.kind == 2 and value.class in 0'i32 .. 9'i32:
    o[base + 30 + int(value.class)] = 1

proc heroSelfObject(world: World, hero: Hero): WorldObject =
  ## The seat's own hero in WorldObject form (it is always in its own frame).
  result = WorldObject(id: hero.id, kind: 2, class: int32(hero.class.ord),
    team: hero.team, position: hero.position, hp: hero.hp, maxHp: hero.maxHp,
    alive: hero.heroAlive, level: int32(hero.level), mana: hero.mana,
    facing: hero.facing, velocity: hero.velocity,
    targetId: (if hero.heroAlive: hero.attackObjectId else: 0))
  if result.alive:
    for effect in ControlEffect:
      result.controlTicks[effect] = max(0'i32, hero.controls[effect].ends - world.tick)

proc buildObservation*(world: World, heroIndex: int, goal: openArray[float32],
    maxTicks: int32, stats: CombatStats, o: var openArray[float32],
    frame: var DecisionFrame) =
  ## Writes observation v1 for one hero from the current decision frame.
  doAssert o.len == ObservationSize and goal.len == GoalSize
  for i in 0 ..< o.len:
    o[i] = 0
  frame = DecisionFrame(tick: world.tick, heroIndex: heroIndex)
  let
    hero = world.heroes[heroIndex]
    team = hero.team
    s = float32(team.side)
    alive = hero.heroAlive
  frame.team = team
  frame.alive = alive
  frame.selfPos = hero.position
  # Self.
  var p = ObsSelfOffset
  o[p+0] = float32(alive)
  o[p+1] = if hero.maxHp > 0: clampf(float32(max(hero.hp, 0)) / float32(hero.maxHp), 0, 1) else: 0
  o[p+2] = if hero.maxMana > 0: clampf(float32(hero.mana) / float32(hero.maxMana), 0, 1) else: 0
  o[p+3] = float32(hero.maxHp) / 2000
  o[p+4] = float32(hero.maxMana) / 1000
  o[p+5] = float32(hero.gold) / 1000
  o[p+6] = float32(hero.level) / 20
  o[p+7] = clampf(float32(hero.xp) / float32(max(1, xpForNextLevel(hero.level))), 0, 1)
  o[p+8] = float32(hero.totalXp) / 20000
  o[p+9] = tiles(hero.position.x) * s / 64
  o[p+10] = tiles(hero.position.z) * s / 64
  o[p+11] = float32(team.ord)
  o[p+12] = clampf(float32(world.battleTick()) / float32(max(1'i32, maxTicks)), 0, 1)
  o[p+13] = clampf(float32(world.heroAttackCooldown(hero)) / 48, 0, 2)
  o[p+14] = tiles(hero.class.heroAttackRange()) / 10
  o[p+15] = float32(hero.heroAttackDamage()) / 200
  o[p+16] = tiles(hero.heroMoveSpeed()) * float32(TickRate) / 5
  o[p+17] = float32(hero.attackObjectId != 0)
  o[p+18] = clampf(float32(max(0'i32, hero.controls[StunControl].ends - world.tick)) / 72, 0, 2)
  o[p+19] = clampf(float32(max(0'i32, hero.controls[RootControl].ends - world.tick)) / 72, 0, 2)
  o[p+20] = clampf(float32(max(0'i32, hero.controls[SilenceControl].ends - world.tick)) / 72, 0, 2)
  o[p+21] = clampf(float32(max(0'i32, hero.portalEnds - world.tick)) / 72, 0, 2)
  o[p+22] = clampf(float32(max(0'i32, hero.portalCooldownEnds - world.tick)) / 1440, 0, 2)
  o[p+23] = clampf(float32(hero.respawnTicks()) / 1440, 0, 2)
  o[p+24] = float32(hero.abilityPoints()) / 4
  o[p+25] = float32(hero.inOwnSpawn)
  o[p+26] = float32(world.phase != Drafting and hero.canShop)
  o[p+27] = float32(hero.deaths) / 10
  o[p+28] = float32(hero.lastActionError != NoActionError)
  let price = world.buybackPrice(hero.id)
  o[p+29] = float32(price > 0 and hero.gold >= price)
  o[p+30 + hero.class.ord] = 1
  o[p+40 + hero.class.heroRole.ord] = 1
  o[p+45] = clampf(tiles(hero.velocity.x) * s * 10, -4, 4)
  o[p+46] = clampf(tiles(hero.velocity.z) * s * 10, -4, 4)
  o[p+47] = float32(hero.hasMoveTarget)
  # Abilities.
  for slot in HeroAbilitySlot:
    let
      b = ObsAbilityOffset + slot.ord * ObsAbilityFeatures
      rank = hero.abilityLevels[slot]
      spec = heroAbility(hero.class, slot).abilitySpec(rank)
      cooldown = hero.cooldowns[slot]
      charges = hero.charges[slot]
    o[b+0] = float32(rank) / float32(slot.abilityMaxLevel)
    o[b+1] = float32(rank > 0)
    o[b+2] = clampf(float32(cooldown) / 240, 0, 2)
    o[b+3] = float32(charges) / 3
    o[b+4] = clampf(float32(hero.recharges[slot]) / 240, 0, 2)
    o[b+5] = float32(spec.manaCost) / 200
    o[b+6] = float32(alive and rank > 0 and cooldown == 0 and charges > 0 and
      hero.mana >= spec.manaCost and
      hero.controls[SilenceControl].ends <= world.tick)
    o[b+7] = float32(spec.damage) / 300
    o[b+8] = float32(spec.heal) / 300
    o[b+9] = float32(spec.restore) / 200
    o[b+10] = tiles(spec.range) / 10
    o[b+11 + spec.casting.ord] = 1
    o[b+15] = tiles(spec.area.radius) / 3
  # Items.
  for slot in 0 ..< InventorySlots:
    let b = ObsItemOffset + slot * ObsItemFeatures
    o[b + hero.inventory[slot].ord] = 1
    o[b + 23] = float32(hero.itemCounts[slot]) / 4
    o[b + 24] = clampf(float32(hero.itemCooldown(slot, world.tick)) / 240, 0, 2)
  # Objects.
  var alliedHeroIds: seq[int32]
  for other in world.heroes:
    if other.team == team:
      alliedHeroIds.add other.id
  let
    damage = hero.heroAttackDamage()
    rangeUnits = hero.class.heroAttackRange()
  var
    creeps, neutrals, enemyStructures: seq[(int64, WorldObject)]
    enemyGod, ownGod: WorldObject
    haveEnemyGod, haveOwnGod = false
  proc distance2(value: WorldObject): int64 =
    let
      dx = int64(value.position.x - hero.position.x)
      dz = int64(value.position.z - hero.position.z)
    dx*dx + dz*dz
  var value: WorldObject
  let count = world.worldObjectCount(hero.id)
  var enemySeen: array[10, bool]
  var enemyValues: array[10, WorldObject]
  for i in 0 ..< count:
    if not world.worldObjectAt(hero.id, i, value):
      continue
    case value.kind
    of 1:
      if value.team == team:
        ownGod = value
        haveOwnGod = true
      else:
        enemyGod = value
        haveEnemyGod = true
    of 2:
      if value.team != team:
        let index = world.heroIndex(value.id)
        if index in 0 ..< 10:
          enemySeen[index] = true
          enemyValues[index] = value
    of 3:
      if value.alive:
        creeps.add((value.distance2, value))
    of 4, 5:
      if value.team != team and value.hp > 0:
        enemyStructures.add((value.distance2, value))
    of 6:
      if value.alive:
        neutrals.add((value.distance2, value))
    else:
      discard
  proc place(o: var openArray[float32], frame: var DecisionFrame, slot: int,
      value: WorldObject) =
    writeObject(o, ObsObjectOffset + slot * ObjectFeatures, world, hero,
      value, damage, rangeUnits, alliedHeroIds)
    frame.ids[slot] = value.id
    frame.positions[slot] = value.position
  place(o, frame, SlotSelf, heroSelfObject(world, hero))
  var slot = SlotAllies
  for i, other in world.heroes:
    if other.team == team and i != heroIndex:
      if other.heroAlive:
        place(o, frame, slot, heroSelfObject(world, other))
      inc slot
  slot = SlotEnemies
  for i, other in world.heroes:
    if other.team != team:
      if enemySeen[i]:
        place(o, frame, slot, enemyValues[i])
      inc slot
  proc byDistance(a, b: (int64, WorldObject)): int =
    result = cmp(a[0], b[0])
    if result == 0:
      result = cmp(a[1].id, b[1].id)
  creeps.sort(byDistance)
  neutrals.sort(byDistance)
  enemyStructures.sort(byDistance)
  for i in 0 ..< min(CreepSlots, creeps.len):
    place(o, frame, SlotCreeps + i, creeps[i][1])
  if haveOwnGod:
    place(o, frame, SlotStructures, ownGod)
  if haveEnemyGod:
    place(o, frame, SlotStructures + 1, enemyGod)
  # Own forward tower: the living allied tower nearest the enemy god.
  block:
    let enemyCenter = world.forts[1 - team.ord].center
    var best = int64.high
    var bestIndex = -1
    for i, building in world.buildings:
      if building.kind == TowerBuilding and building.team == team and building.hp > 0:
        let
          dx = int64(building.position.x - enemyCenter.x)
          dz = int64(building.position.z - enemyCenter.z)
          d = dx*dx + dz*dz
        if d < best:
          best = d
          bestIndex = i
    if bestIndex >= 0:
      let building = world.buildings[bestIndex]
      place(o, frame, SlotStructures + 2, WorldObject(id: building.id, kind: 4,
        class: -1, team: building.team, position: building.position,
        hp: building.hp, maxHp: building.maxHp,
        alive: world.buildingExposed(building), facing: building.facing,
        targetId: building.targetId))
  if enemyStructures.len > 0:
    place(o, frame, SlotStructures + 3, enemyStructures[0][1])
  for i in 0 ..< min(NeutralSlots, neutrals.len):
    place(o, frame, SlotNeutrals + i, neutrals[i][1])
  # Spell warnings.
  var warnings: seq[(int32, int64, SpellCast)]
  let spellCount = world.visibleSpellCount(hero.id)
  var spell: SpellCast
  for i in 0 ..< spellCount:
    if world.visibleSpellAt(hero.id, i, spell) and spell.impact >= world.tick:
      let
        dx = int64(spell.position.x - hero.position.x)
        dz = int64(spell.position.z - hero.position.z)
      warnings.add((spell.impact, dx*dx + dz*dz, spell))
  warnings.sort(proc(a, b: (int32, int64, SpellCast)): int =
    result = cmp(a[0], b[0])
    if result == 0: result = cmp(a[1], b[1]))
  for i in 0 ..< min(SpellSlots, warnings.len):
    let
      b = ObsSpellOffset + i * SpellFeatures
      w = warnings[i][2]
      dx = tiles(w.position.x - hero.position.x) * s
      dy = tiles(w.position.z - hero.position.z) * s
      caster = world.heroIndex(w.heroId)
      allied = caster >= 0 and world.heroes[caster].team == team
      spec = w.ability.abilitySpec
    o[b+0] = 1
    o[b+1] = clampf(dx / 16, -4, 4)
    o[b+2] = clampf(dy / 16, -4, 4)
    o[b+3] = clampf(sqrt(dx*dx + dy*dy) / 16, 0, 8)
    o[b+4] = clampf(float32(w.impact - world.tick) / 72, 0, 4)
    o[b+5] = float32(not allied)
    o[b+6] = float32(spec.kind != Strike)
    o[b+7] = float32(w.ability.ord) / 40
  # Summary.
  p = ObsSummaryOffset
  let
    ownFort = world.forts[team.ord]
    enemyFort = world.forts[1 - team.ord]
  o[p+0] = float32(max(ownFort.hp, 0)) / float32(FortHp)
  o[p+1] = float32(world.fortExposed(team))
  var ownT, ownTAll, ownB, ownBAll, enT, enTAll, enB, enBAll = 0
  for building in world.buildings:
    let mine = building.team == team
    if building.kind == TowerBuilding:
      if mine:
        inc ownTAll
        if building.hp > 0: inc ownT
      else:
        inc enTAll
        if building.knownAlive[team]: inc enT
    else:
      if mine:
        inc ownBAll
        if building.hp > 0: inc ownB
      else:
        inc enBAll
        if building.knownAlive[team]: inc enB
  o[p+2] = float32(ownT) / float32(max(1, ownTAll))
  o[p+3] = float32(ownB) / float32(max(1, ownBAll))
  o[p+4] = float32(enT) / float32(max(1, enTAll))
  o[p+5] = float32(enB) / float32(max(1, enBAll))
  o[p+6] = if haveEnemyGod: float32(max(enemyFort.hp, 0)) / float32(FortHp) else: -1
  var ownAlive, enemyVisible, ownLevels, enemyLevels = 0
  for i, other in world.heroes:
    if other.team == team:
      ownLevels += other.level
      if other.heroAlive: inc ownAlive
    elif enemySeen[i]:
      inc enemyVisible
      enemyLevels += int(enemyValues[i].level)
  o[p+7] = float32(ownAlive) / 5
  o[p+8] = float32(enemyVisible) / 5
  o[p+9] = clampf(float32(world.spawnTimerTicks) / float32(max(1'i32, world.spawnIntervalTicks)), 0, 1)
  o[p+10] = float32(ownLevels) / 50
  o[p+11] = float32(enemyLevels) / 50
  o[p+12] = float32(score(hero.totalXp, int(max(0'i32, world.battleTick())))) / 5000
  if stats != nil and heroIndex < stats.values.len:
    o[p+13] = float32(stats.values[heroIndex][KillsMetric]) / 10
    o[p+14] = float32(stats.values[heroIndex][AssistsMetric]) / 10
  # Terrain: 9x9 known-walkable patch, stride 2 tiles, team frame, row-major.
  let
    center = mapPoint(hero.position)
    cx = int((int64(int32(center.x)) + FixedScale div 2) shr 16)
    cy = int((int64(int32(center.y)) + FixedScale div 2) shr 16)
    layer = hero.navLayer
  var t = ObsTerrainOffset
  for row in 0 ..< TerrainSide:
    for col in 0 ..< TerrainSide:
      let
        ox = (col - TerrainSide div 2) * TerrainStride * int(team.side)
        oy = (row - TerrainSide div 2) * TerrainStride * int(team.side)
      o[t] = float32(world.terrainOpen(team, layer, cx + ox, cy + oy))
      inc t
  # Goal.
  for i in 0 ..< GoalSize:
    o[ObsGoalOffset + i] = goal[i]

# ---------------------------------------------------------------------------
# Decoder

proc decodeAction*(frame: DecisionFrame, heads: Heads): NeuralCommand =
  ## Maps five head indices to a concrete order; invalid choices -> noop.
  result = NeuralCommand(kind: NoCommand, tick: frame.tick)
  if not frame.alive:
    return
  for h in 0 ..< ActionHeads:
    if heads[h] < 0 or heads[h] >= HeadSizes[h]:
      return
  let
    verb = heads[0]
    target = int(heads[1])
    point = int(heads[2])
    ability = heads[3]
    item = heads[4]
  case verb
  of 1, 2:
    let
      dest = pointCandidate(frame.selfPos, frame.team, point, WalkRings)
      mp = mapPoint(dest)
      (x, y, _) = splitTilePoint(mp)
    result.kind = if verb == 1: WalkCommand else: AttackMoveCommand
    result.point = fixedVec2(fixed(x), fixed(y))
  of 3:
    if frame.ids[target] == 0 or target == SlotSelf:
      return
    result.kind = AttackTargetCommand
    result.objectId = frame.ids[target]
  of 4:
    if frame.ids[target] == 0:
      return
    result.kind = CastTargetCommand
    result.objectId = frame.ids[target]
    result.ability = ability
  of 5, 7:
    if frame.ids[target] == 0:
      return
    let dest = pointCandidate(frame.positions[target], frame.team, point, CastRings)
    result.kind = if verb == 5: CastPointCommand else: UseItemAtCommand
    result.point = mapPoint(dest)
    result.ability = ability
    result.item = item
  of 6:
    result.kind = UseItemCommand
    result.item = item
  else:
    discard

# ---------------------------------------------------------------------------
# Action validity mask (native_env.h gota_action_mask; manifest
# decoder.mask_empty_targets). Optional decoder aid: not part of the contract
# text, the decode rules above are unchanged.

const
  MaskVerb* = 0
  MaskAbility* = 8
  MaskTarget* = 12
  MaskTargetRows* = 7
  MaskSize* = MaskTarget + MaskTargetRows * ObjectSlots

type ActionMask* = array[MaskSize, uint8]

proc maskTargetRow*(verb, ability: int32): int =
  ## Target row of (verb, ability); -1 = the verb ignores the target head.
  case verb
  of 3: 0
  of 4: (if ability in 0'i32 .. 3'i32: 1 + int(ability) else: -1)
  of 5: 5
  of 7: 6
  else: -1

proc actionMask*(world: World, heroIndex: int, frame: DecisionFrame): ActionMask =
  ## Which choices decode to a real order on this frame (native_env.h).
  result[MaskVerb] = 1
  if not frame.alive or world.gameOver:
    return
  let hero = world.heroes[heroIndex]
  var specs: array[4, AbilitySpec]
  for a in 0 ..< 4:
    specs[a] = heroAbility(hero.class, HeroAbilitySlot(a)).abilitySpec()
  for s in 0 ..< ObjectSlots:
    let id = frame.ids[s]
    if id == 0:
      continue
    result[MaskTarget + 5 * ObjectSlots + s] = 1
    result[MaskTarget + 6 * ObjectSlots + s] = 1
    if s != SlotSelf and world.isEnemyTarget(hero, id):
      result[MaskTarget + s] = 1
    var target: WorldObject
    let usable = world.spellTarget(id, target) and target.alive and
      world.visible(hero.team, target.position)
    for a in 0 ..< 4:
      let ok = specs[a].casting == SelfCast or (usable and
        (if specs[a].kind == Strike: target.faction != hero.team.ord.int32
         else: target.faction == hero.team.ord.int32))
      if ok:
        result[MaskTarget + (1 + a) * ObjectSlots + s] = 1
  for v in [1, 2, 6]:
    result[MaskVerb + v] = 1
  proc anyRow(mask: ActionMask, row: int): bool =
    for s in 0 ..< ObjectSlots:
      if mask[MaskTarget + row * ObjectSlots + s] != 0:
        return true
  for a in 0 ..< 4:
    result[MaskAbility + a] = uint8(result.anyRow(1 + a))
  result[MaskVerb + 3] = uint8(result.anyRow(0))
  result[MaskVerb + 4] = uint8(result[MaskAbility] != 0 or
    result[MaskAbility + 1] != 0 or result[MaskAbility + 2] != 0 or
    result[MaskAbility + 3] != 0)
  result[MaskVerb + 5] = uint8(result.anyRow(5))
  result[MaskVerb + 7] = uint8(result.anyRow(6))

proc isInvalid*(frame: DecisionFrame, heads: Heads): bool =
  ## A non-noop verb that decoded to noop.
  frame.alive and heads[0] != 0 and decodeAction(frame, heads).kind == NoCommand

# ---------------------------------------------------------------------------
# Demonstration encoder (BC labels and the mapping ceiling)

type Encoded* = object
  heads*: Heads
  exact*: bool
  errorMilli*: int32
  represented*: bool

proc slotOf(frame: DecisionFrame, id: int32): int =
  if id == 0:
    return -1
  for i in 0 ..< ObjectSlots:
    if frame.ids[i] == id:
      return i
  -1

proc pathPointAt(start: WorldPoint, path: openArray[WorldPoint],
    arc: float64): (WorldPoint, float64) =
  ## The point `arc` world units along the route (or its end) and the route length.
  var
    prev = start
    walked = 0.0
  for p in path:
    let
      dx = float64(p.x - prev.x)
      dz = float64(p.z - prev.z)
      seg = sqrt(dx*dx + dz*dz)
    if walked + seg >= arc and seg > 0:
      let f = (arc - walked) / seg
      return (WorldPoint(x: prev.x + int32(dx*f), z: prev.z + int32(dz*f)), -1.0)
    walked += seg
    prev = p
  (prev, walked)

proc encodeMove(frame: DecisionFrame, world: World, verb: int32,
    goal: FixedVec2): Encoded =
  ## Walk/attack-move: follow the route the order produces, not the chord.
  let hero = world.heroes[frame.heroIndex]
  let (gx, gy, goff) = splitTilePoint(goal)
  let route = world.planRoute(hero, gx, gy, goff)
  var target = worldPointOf(goal)
  var length: float64
  if route.len > 0:
    let (_, total) = pathPointAt(frame.selfPos, route, 1e18)
    length = total
  else:
    let
      dx = float64(target.x - frame.selfPos.x)
      dz = float64(target.z - frame.selfPos.z)
    length = sqrt(dx*dx + dz*dz)
  let ws = float64(WorldScale)
  var ring = -1
  if length >= 1.0 * ws:
    ring = (if length < 3.5 * ws: 0 elif length < 8.5 * ws: 1 else: 2)
  var aim = target
  if ring >= 0 and route.len > 0:
    let (point, _) = pathPointAt(frame.selfPos, route, float64(WalkRings[ring]))
    aim = point
  var best = (int64.high, 0)
  var candidates: seq[int]
  if ring < 0:
    candidates.add 0
  else:
    for d in 0 ..< 16:
      candidates.add 1 + ring*16 + d
  for index in candidates:
    let
      c = pointCandidate(frame.selfPos, frame.team, index, WalkRings)
      dx = int64(c.x - aim.x)
      dz = int64(c.z - aim.z)
      e = dx*dx + dz*dz
    if e < best[0]:
      best = (e, index)
  result.heads = [verb, 0, int32(best[1]), 0, 0]
  result.represented = true
  let decoded = decodeAction(frame, result.heads)
  result.exact = decoded.point == fixedVec2(fixed(gx), fixed(gy)) and goff == FixedVec2Zero
  result.errorMilli = int32(sqrt(float64(best[0])) * 1000 / ws)

proc encodeAnchored(frame: DecisionFrame, verb, ability, item: int32,
    goal: FixedVec2): Encoded =
  ## castPoint/useItemAt: best (anchor slot, offset) pair for the aim point.
  let target = worldPointOf(goal)
  var best = (int64.high, 0, 0)
  for slot in 0 ..< ObjectSlots:
    if frame.ids[slot] == 0:
      continue
    for index in 0 ..< 49:
      let
        c = pointCandidate(frame.positions[slot], frame.team, index, CastRings)
        dx = int64(c.x - target.x)
        dz = int64(c.z - target.z)
        e = dx*dx + dz*dz
      if e < best[0]:
        best = (e, slot, index)
  if best[0] == int64.high:
    return
  result.heads = [verb, int32(best[1]), int32(best[2]), ability, item]
  result.represented = true
  result.errorMilli = int32(sqrt(float64(best[0])) * 1000 / float64(WorldScale))
  result.exact = decodeAction(frame, result.heads).point == goal

proc encodeCommand*(frame: DecisionFrame, world: World, command: NeuralCommand): Encoded =
  ## Nearest action-contract encoding of a script's command on this frame.
  case command.kind
  of NoCommand:
    result.represented = true
    result.exact = true
  of WalkCommand:
    result = encodeMove(frame, world, 1, command.point)
  of AttackMoveCommand:
    result = encodeMove(frame, world, 2, command.point)
  of AttackTargetCommand:
    let slot = frame.slotOf(command.objectId)
    if slot > 0:
      result.heads = [3'i32, int32(slot), 0, 0, 0]
      result.represented = true
      result.exact = true
    else:
      # Not in the slots: approach it with an attack-move instead.
      var value: WorldObject
      let hero = world.heroes[frame.heroIndex]
      if world.worldObjectById(hero.id, command.objectId, value):
        result = encodeMove(frame, world, 2, mapPoint(value.position))
        result.exact = false
  of CastTargetCommand:
    let slot = frame.slotOf(command.objectId)
    if slot >= 0:
      result.heads = [4'i32, int32(slot), 0, clamp(command.ability, 0, 3), 0]
      result.represented = true
      result.exact = command.ability in 0'i32 .. 3'i32
  of CastPointCommand:
    result = encodeAnchored(frame, 5, clamp(command.ability, 0, 3), 0, command.point)
  of UseItemCommand:
    result.heads = [6'i32, 0, 0, 0, clamp(command.item, 0, 5)]
    result.represented = true
    result.exact = command.item in 0'i32 .. 5'i32
  of UseItemAtCommand:
    result = encodeAnchored(frame, 7, 0, clamp(command.item, 0, 5), command.point)

proc argmaxHeads*(logits: openArray[float32]): Heads =
  ## Deterministic argmax per head (first maximum wins).
  var offset = 0
  for h in 0 ..< ActionHeads:
    var best = 0
    for i in 1 ..< HeadSizes[h]:
      if logits[offset + i] > logits[offset + best]:
        best = i
    result[h] = int32(best)
    offset += HeadSizes[h]
