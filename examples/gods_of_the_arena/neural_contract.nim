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
  content, maps, motions, observations, scores, sim, terrains

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
    "wave_timer", "own_levels/50", "visible_enemy_levels/50", "glory/5000",
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
  result = "gota-neural-basic/2 observation v2 float32[" & $ObservationSize &
    "] team-frame (blue rotated 180); canonical = upstream #83 david.bas: " &
    "every cell is a Q16.16 value (raw/65536), slots of creeps/neutrals/" &
    "structures ordered by the Q16.16 key (dx/16)^2+(dy/16)^2 with ties to " &
    "the smaller id, object facing normalized in fixed point after tile " &
    "scaling, targets_ally_hero includes the seat itself, glory/5000 is " &
    "Emmett's Glory (0 until a win), observed after the seat's " &
    "learn/shop glue of the same tick with frame-start host data;\nself:" &
    SelfFeatureNames.join(",") &
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

proc heroAlive(hero: Hero): bool = hero.hp > 0 and hero.state != Dying

type
  HeroSnapshot* = object
    ## The frame-start values BASIC receives as host data (`selfHp`,
    ## `selfGold`, `selfAttackDamage`, ...): they do not follow the hero's own
    ## learn/shop orders inside the tick, unlike the live `selfInfo`/`ability*`
    ## /`item*` getters (spec upstream83.md D6).
    captured*: bool
    tick*, hp*, maxHp*, mana*, maxMana*, gold*, level*, layer*, klass*: int32
    attackDamage*, target*, attackCooldown*, portalCooldown*: int32
    channelTicks*, stunTicks*, rootTicks*, silenceTicks*, deaths*: int32
    respawnTicks*: int32

proc captureSnapshot*(world: World, hero: Hero): HeroSnapshot =
  ## What runHeroVm hands the seat's program at the top of its decision.
  HeroSnapshot(captured: true, tick: world.tick, hp: max(hero.hp, 0'i32),
    maxHp: hero.maxHp, mana: hero.mana, maxMana: hero.maxMana,
    gold: int32(hero.gold), level: int32(hero.level), layer: hero.navLayer,
    klass: world.draftedClass(hero.id),
    attackDamage: hero.heroAttackDamage(), target: hero.attackObjectId,
    attackCooldown: world.heroAttackCooldown(hero),
    portalCooldown: max(0'i32, hero.portalCooldownEnds - world.tick),
    channelTicks: max(0'i32, hero.portalEnds - world.tick),
    stunTicks: max(0'i32, hero.controls[StunControl].ends - world.tick),
    rootTicks: max(0'i32, hero.controls[RootControl].ends - world.tick),
    silenceTicks: max(0'i32, hero.controls[SilenceControl].ends - world.tick),
    deaths: hero.deaths, respawnTicks: hero.respawnTicks())

# Q16.16 helpers with the exact semantics of the BASIC operators david.bas
# uses (fixxy.nim: `*` and `/` round to nearest, halves up; int operands of
# `/` are converted to Fixed first).

proc fx(value: int32): Fixed {.inline.} = fixed(value)
proc fbool(value: bool): Fixed {.inline.} = (if value: FixedOne else: FixedZero)
proc fdiv(a, b: int32): Fixed {.inline.} =
  ## BASIC `a / b` on two integers (0 for a zero divisor, where BASIC halts).
  if b == 0: FixedZero else: fixed(a) / fixed(b)
proc fdiv(a: Fixed, b: int32): Fixed {.inline.} = a / fixed(b)
proc fdiv(a: int32, b: Fixed): Fixed {.inline.} = fixed(a) / b
proc clampfx(value: Fixed, low, high: int32): Fixed {.inline.} =
  if value < fixed(low): fixed(low)
  elif value > fixed(high): fixed(high)
  else: value

proc nnRatio(numerator, denominator: int32): Fixed =
  ## david.bas nnRatio: an exact 16-bit fraction of two counters.
  let d = if denominator <= 0: 1'i32 else: denominator
  let n = if numerator < 0: 0'i32 else: numerator
  var
    remainder = n mod d
    fraction = 0'i32
  for i in 0 ..< 16:
    if remainder >= d - remainder:
      remainder = remainder - (d - remainder)
      fraction += 32768'i32 shr i
    else:
      remainder = remainder * 2
  if remainder >= d - remainder:
    fraction += 1
  fixed(n div d) + Fixed(fraction)

proc terrainWalkableAt(world: World, team: Team, x, y, layer: int32): bool =
  ## The `terrainWalkableAt` host call (known walkability under fog).
  if terrainValue(x, y, layer, TerrainWalkableField) == 0:
    return false
  let floor = layers[int(layer)]
  world.knownWalkable(team, int(layer), int(x) + mapOrigin() - floor.originX,
    int(y) + mapOrigin() - floor.originZ)

proc buildObservation*(world: World, heroIndex: int, goal: openArray[float32],
    maxTicks: int32, stats: CombatStats, o: var openArray[float32],
    frame: var DecisionFrame, snap: HeroSnapshot = HeroSnapshot()) =
  ## Writes observation v2 for one hero: `david.bas` (`nnObserve`, upstream #83)
  ## reproduced in Q16.16, cell for cell. `snap` is the frame-start data
  ## (`captureSnapshot` before the seat's glue ran); default = the live state.
  doAssert o.len == ObservationSize and goal.len == GoalSize
  frame = DecisionFrame(tick: world.tick, heroIndex: heroIndex)
  let
    hero = world.heroes[heroIndex]
    team = hero.team
    snapshot = if snap.captured: snap else: captureSnapshot(world, hero)
    side = int32(team.side)
    selfTeam = int32(team.ord)
    selfId = hero.id
    selfX = worldToTiles(hero.position.x, WorldScale)
    selfY = worldToTiles(hero.position.z, WorldScale)
    attackRange = worldToTiles(hero.class.heroAttackRange(), WorldScale)
    d16 = fixed(16)
  frame.team = team
  frame.alive = hero.heroAlive
  frame.selfPos = hero.position
  var f {.noinit.}: array[ObservationSize, Fixed]
  for i in 0 ..< ObservationSize:
    f[i] = FixedZero
  template clampAt(index: int, value: Fixed, low, high: int32) =
    f[index] = clampfx(value, low, high)
  # Self.
  var p = ObsSelfOffset
  f[p+0] = fbool(snapshot.hp > 0)
  clampAt(p+1, fdiv(snapshot.hp, snapshot.maxHp), 0, 1)
  clampAt(p+2, fdiv(snapshot.mana, snapshot.maxMana), 0, 1)
  f[p+3] = fdiv(snapshot.maxHp, fixed(2000))
  f[p+4] = fdiv(snapshot.maxMana, fixed(1000))
  f[p+5] = nnRatio(snapshot.gold, 1000)
  f[p+6] = fdiv(snapshot.level, fixed(20))
  clampAt(p+7, fdiv(int32(hero.xp), int32(xpForNextLevel(hero.level))), 0, 1)
  f[p+8] = nnRatio(int32(hero.totalXp), 20000)
  f[p+9] = (selfX * side) / fixed(64)
  f[p+10] = (selfY * side) / fixed(64)
  f[p+11] = fx(selfTeam)
  clampAt(p+12, nnRatio(world.battleTick(), maxTicks), 0, 1)
  clampAt(p+13, fdiv(snapshot.attackCooldown, fixed(48)), 0, 2)
  f[p+14] = attackRange / fixed(10)
  f[p+15] = fdiv(snapshot.attackDamage, fixed(200))
  f[p+16] = (worldToTiles(hero.heroMoveSpeed(), WorldScale) * int32(TickRate)) /
    fixed(5)
  f[p+17] = fbool(snapshot.target != 0)
  clampAt(p+18, fdiv(snapshot.stunTicks, fixed(72)), 0, 2)
  clampAt(p+19, fdiv(snapshot.rootTicks, fixed(72)), 0, 2)
  clampAt(p+20, fdiv(snapshot.silenceTicks, fixed(72)), 0, 2)
  clampAt(p+21, fdiv(snapshot.channelTicks, fixed(72)), 0, 2)
  clampAt(p+22, fdiv(snapshot.portalCooldown, fixed(1440)), 0, 2)
  clampAt(p+23, fdiv(snapshot.respawnTicks, fixed(1440)), 0, 2)
  f[p+24] = fdiv(hero.abilityPoints(), fixed(4))
  f[p+25] = fbool(hero.inOwnSpawn)
  f[p+26] = fbool(world.phase != Drafting and hero.canShop)
  f[p+27] = fdiv(snapshot.deaths, fixed(10))
  f[p+28] = fbool(hero.lastActionError != NoActionError)
  let price = world.buybackPrice(hero.id)
  f[p+29] = fbool(price > 0 and snapshot.gold >= price)
  if snapshot.klass in 0'i32 .. 9'i32:
    f[p+30 + int(snapshot.klass)] = FixedOne
  f[p+40 + hero.class.heroRole.ord] = FixedOne
  clampAt(p+45, (worldToTiles(hero.velocity.x, WorldScale) * side) * fixed(10),
    -4, 4)
  clampAt(p+46, (worldToTiles(hero.velocity.z, WorldScale) * side) * fixed(10),
    -4, 4)
  f[p+47] = fbool(hero.hasMoveTarget)
  # Abilities.
  for slot in HeroAbilitySlot:
    let
      b = ObsAbilityOffset + slot.ord * ObsAbilityFeatures
      rank = hero.abilityLevels[slot]
      spec = heroAbility(hero.class, slot).abilitySpec(rank)
      cooldown = hero.cooldowns[slot]
      charges = hero.charges[slot]
    f[b+0] = fdiv(rank, slot.abilityMaxLevel)
    f[b+1] = fbool(rank > 0)
    clampAt(b+2, fdiv(cooldown, fixed(240)), 0, 2)
    f[b+3] = fdiv(charges, fixed(3))
    clampAt(b+4, fdiv(hero.recharges[slot], fixed(240)), 0, 2)
    f[b+5] = fdiv(spec.manaCost, fixed(200))
    f[b+6] = fbool(snapshot.hp > 0 and rank > 0 and cooldown == 0 and
      charges > 0 and snapshot.mana >= spec.manaCost and
      snapshot.silenceTicks == 0)
    f[b+7] = fdiv(spec.damage, fixed(300))
    f[b+8] = fdiv(spec.heal, fixed(300))
    f[b+9] = fdiv(spec.restore, fixed(200))
    f[b+10] = worldToTiles(spec.range, WorldScale) / fixed(10)
    f[b+11 + spec.casting.ord] = FixedOne
    f[b+15] = worldToTiles(spec.area.radius, WorldScale) / fixed(3)
  # Items.
  for slot in 0 ..< InventorySlots:
    let b = ObsItemOffset + slot * ObsItemFeatures
    f[b + hero.inventory[slot].ord] = FixedOne
    f[b + 23] = fdiv(hero.itemCounts[slot], fixed(4))
    clampAt(b + 24, fdiv(hero.itemCooldown(slot, world.tick), fixed(240)), 0, 2)
  # Objects: david.bas's slot assignment over the hero's visible list.
  var
    slotObj: array[ObjectSlots, int]
    slotId: array[ObjectSlots, int32]
    slotKey: array[ObjectSlots, Fixed]
    visibleIds: array[512, int32]
    ownAlive, enemyVisible, ownLevels, enemyLevels = 0'i32
  for s in 0 ..< ObjectSlots:
    slotObj[s] = -1
    slotKey[s] = fixed(32767)
  var value: WorldObject
  let count = min(world.worldObjectCount(hero.id), visibleIds.len)
  for i in 0 ..< count:
    if world.worldObjectAt(hero.id, i, value):
      visibleIds[i] = value.id
  for i in 0 ..< count:
    if not world.worldObjectAt(hero.id, i, value):
      continue
    let
      kind = value.kind
      faction = value.faction
      id = value.id
      alive = value.alive
      x = worldToTiles(value.position.x, WorldScale)
      y = worldToTiles(value.position.z, WorldScale)
    var
      dx = (x - selfX) / d16
      dy = (y - selfY) / d16
      key = dx * dx + dy * dy
      slot = -1
      start = -1
      last = -1
    if kind == 1:
      slot = 17
      if faction != selfTeam:
        slot = 18
    elif kind == 2:
      let roster = id - 100
      if faction == selfTeam:
        ownLevels += value.level
        if alive:
          inc ownAlive
          slot = int(roster mod 5) + 1
          if roster mod 5 > (selfId - 100) mod 5:
            dec slot
          if id == selfId:
            slot = 0
      else:
        inc enemyVisible
        enemyLevels += value.level
        slot = 5 + int(roster mod 5)
    elif kind == 3 and alive:
      start = 10
      last = 16
    elif kind == 6 and alive:
      start = 21
      last = 24
    elif (kind == 4 or kind == 5) and max(value.hp, 0'i32) > 0:
      if faction != selfTeam:
        start = 20
        last = 20
      elif kind == 4:
        dx = (x - worldToTiles(world.forts[1 - team.ord].center.x,
          WorldScale)) / d16
        dy = (y - worldToTiles(world.forts[1 - team.ord].center.z,
          WorldScale)) / d16
        key = dx * dx + dy * dy
        start = 19
        last = 19
    if start >= 0:
      for s in start .. last:
        if key < slotKey[s] or (key == slotKey[s] and id < slotId[s]):
          for j in countdown(last, s + 1):
            slotObj[j] = slotObj[j - 1]
            slotId[j] = slotId[j - 1]
            slotKey[j] = slotKey[j - 1]
          slot = s
          break
    if slot >= 0:
      slotObj[slot] = i
      slotId[slot] = id
      slotKey[slot] = key
  var allyIds: array[10, int32]
  var allyCount = 0
  for other in world.heroes:
    if other.team == team and allyCount < allyIds.len:
      allyIds[allyCount] = other.id
      inc allyCount
  for s in 0 ..< ObjectSlots:
    let index = slotObj[s]
    if index < 0:
      continue
    if not world.worldObjectAt(hero.id, index, value):
      continue
    let
      b = ObsObjectOffset + s * ObjectFeatures
      kind = value.kind
      xs = worldToTiles(value.position.x, WorldScale)
      ys = worldToTiles(value.position.z, WorldScale)
      dx = ((xs - selfX) * side) / d16
      dy = ((ys - selfY) * side) / d16
      distance = fixxy.sqrt(dx * dx + dy * dy)
      hp = max(value.hp, 0'i32)
    var target = value.targetId
    if target != 0:
      var seen = false
      for i in 0 ..< count:
        if visibleIds[i] == target:
          seen = true
          break
      if not seen:
        target = 0
    f[b+0] = FixedOne
    clampAt(b+1, dx, -4, 4)
    clampAt(b+2, dy, -4, 4)
    clampAt(b+3, distance, 0, 8)
    clampAt(b+4, fdiv(hp, value.maxHp), 0, 1)
    f[b+5] = fdiv(hp, fixed(2000))
    f[b+13] = fbool(value.alive)
    f[b+14] = fdiv(value.level, fixed(20))
    f[b+15] = fdiv(value.mana, fixed(1000))
    f[b+16] = fbool(target != 0 and target == selfId)
    f[b+17] = fbool(value.id != 0 and value.id == snapshot.target)
    clampAt(b+19, fdiv(value.controlTicks[StunControl], fixed(72)), 0, 2)
    clampAt(b+20, fdiv(value.controlTicks[RootControl], fixed(72)), 0, 2)
    clampAt(b+21, fdiv(value.controlTicks[SilenceControl], fixed(72)), 0, 2)
    clampAt(b+22, (worldToTiles(value.velocity.x, WorldScale) * side) *
      fixed(10), -4, 4)
    clampAt(b+23, (worldToTiles(value.velocity.z, WorldScale) * side) *
      fixed(10), -4, 4)
    let facing = motions.normalized(fixedVec2(
      worldToTiles(value.facing.x, WorldScale),
      worldToTiles(value.facing.z, WorldScale)))
    f[b+24] = facing.x * side
    f[b+25] = facing.y * side
    f[b+26] = fbool(distance <= attackRange / d16)
    f[b+27] = fbool(hp > 0 and hp <= snapshot.attackDamage)
    f[b+28] = fbool(value.returning)
    if kind in 1'i32 .. 6'i32:
      f[b+6+int(kind)] = FixedOne
    if value.faction != 2:
      f[b+6] = fixed(-1)
      if value.faction == selfTeam:
        f[b+6] = FixedOne
    for a in 0 ..< allyCount:
      if target != 0 and target == allyIds[a]:
        f[b+18] = FixedOne
    if kind == 3:
      f[b+29] = fx(value.class)
    elif kind == 6:
      f[b+29] = fdiv(value.class, fixed(3))
    elif kind == 2 and value.class in 0'i32 .. 9'i32:
      f[b+30+int(value.class)] = FixedOne
    frame.ids[s] = value.id
    frame.positions[s] = value.position
  # Spell warnings: (impact tick, distance key) insertion order.
  var
    warnIndex: array[SpellSlots, int]
    warnTick: array[SpellSlots, int32]
    warnDist: array[SpellSlots, Fixed]
    warnSpell: array[SpellSlots, SpellCast]
  for s in 0 ..< SpellSlots:
    warnIndex[s] = -1
    warnTick[s] = high(int32)
    warnDist[s] = fixed(32767)
  var spell: SpellCast
  let spellCount = world.visibleSpellCount(hero.id)
  for i in 0 ..< spellCount:
    if not world.visibleSpellAt(hero.id, i, spell):
      continue
    let
      dx = (worldToTiles(spell.position.x, WorldScale) - selfX) / d16
      dy = (worldToTiles(spell.position.z, WorldScale) - selfY) / d16
      distance = dx * dx + dy * dy
    for s in 0 ..< SpellSlots:
      if spell.impact < warnTick[s] or
          (spell.impact == warnTick[s] and distance < warnDist[s]):
        for j in countdown(SpellSlots - 1, s + 1):
          warnIndex[j] = warnIndex[j - 1]
          warnTick[j] = warnTick[j - 1]
          warnDist[j] = warnDist[j - 1]
          warnSpell[j] = warnSpell[j - 1]
        warnIndex[s] = i
        warnTick[s] = spell.impact
        warnDist[s] = distance
        warnSpell[s] = spell
        break
  for s in 0 ..< SpellSlots:
    if warnIndex[s] < 0:
      continue
    let
      b = ObsSpellOffset + s * SpellFeatures
      w = warnSpell[s]
      caster = world.heroIndex(w.heroId)
    f[b+0] = FixedOne
    clampAt(b+1, ((worldToTiles(w.position.x, WorldScale) - selfX) * side) /
      d16, -4, 4)
    clampAt(b+2, ((worldToTiles(w.position.z, WorldScale) - selfY) * side) /
      d16, -4, 4)
    clampAt(b+3, fixxy.sqrt(warnDist[s]), 0, 8)
    clampAt(b+4, fdiv(warnTick[s] - snapshot.tick, fixed(72)), 0, 4)
    f[b+5] = fbool(caster < 0 or world.heroes[caster].team != team)
    f[b+6] = fbool(w.ability.abilitySpec.kind != Strike)
    f[b+7] = fdiv(int32(w.ability.ord), fixed(40))
  # Summary.
  p = ObsSummaryOffset
  f[p+0] = f[ObsObjectOffset + 17 * ObjectFeatures + 4]
  f[p+1] = f[ObsObjectOffset + 17 * ObjectFeatures + 13]
  for k in 0 ..< 4:
    let
      enemy = k >= 2
      barracks = (k mod 2) == 1
    var known, total = 0'i32
    for building in world.buildings:
      if (building.team != team) == enemy and
          (building.kind == BarracksBuilding) == barracks:
        inc total
        if (if enemy: building.knownAlive[team] else: building.hp > 0):
          inc known
    if total > 0:
      f[p+2+k] = fdiv(known, total)
  f[p+6] = fixed(-1)
  if slotId[18] != 0:
    f[p+6] = f[ObsObjectOffset + 18 * ObjectFeatures + 4]
  f[p+7] = fdiv(ownAlive, fixed(5))
  f[p+8] = fdiv(enemyVisible, fixed(5))
  f[p+9] = fdiv(world.spawnTimerTicks, world.spawnIntervalTicks)
  f[p+10] = fdiv(ownLevels, fixed(50))
  f[p+11] = fdiv(enemyLevels, fixed(50))
  let glory = score(int(hero.totalXp), int(world.tick),
    world.gameOver and not world.draw and hero.team == world.winner)
  f[p+12] = nnRatio(int32(glory), 5000)
  if stats != nil and heroIndex < stats.values.len:
    f[p+13] = fdiv(int32(stats.values[heroIndex][KillsMetric]), fixed(10))
    f[p+14] = fdiv(int32(stats.values[heroIndex][AssistsMetric]), fixed(10))
  # Terrain: 9x9 known-walkable patch, stride 2 tiles, team frame, row-major.
  let
    origin = int32(mapTiles() div 2)
    centerX = int32((int64(int32(selfX)) + int64(origin) * FixedScale) shr 16)
    centerY = int32((int64(int32(selfY)) + int64(origin) * FixedScale) shr 16)
  var t = ObsTerrainOffset
  var terrainY = centerY - 8 * side
  for row in 0 ..< TerrainSide:
    var terrainX = centerX - 8 * side
    for col in 0 ..< TerrainSide:
      f[t] = fbool(world.terrainWalkableAt(team, terrainX, terrainY,
        snapshot.layer))
      terrainX += 2 * side
      inc t
    terrainY += 2 * side
  # Q16.16 -> float32 exactly as the #83 native kernel reads them; the goal
  # is training-time conditioning and stays as the trainer set it.
  for i in 0 ..< ObsGoalOffset:
    o[i] = f[i].toFloat32
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
