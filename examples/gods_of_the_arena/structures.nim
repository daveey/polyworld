import
  std/[sets, strutils],
  bassy, fixxy,
  polyworld/[bodies, metrics, pathing],
  content, maps, motions, observations, scores, sim

const
  StructureSource* = staticRead("structures.bas")
  ObjectCapacity = 4096
  SpellCapacity = 2048
  CampCapacity = 64
  GlobalNames = [
    "self.id",
    "self.team",
    "self.class",
    "self.role",
    "self.hp",
    "self.maxHp",
    "self.mana",
    "self.maxMana",
    "self.gold",
    "self.level",
    "self.xp",
    "self.nextLevelXp",
    "self.totalXp",
    "self.kills",
    "self.deaths",
    "self.assists",
    "self.layer",
    "self.alive",
    "self.hasMoveTarget",
    "self.attackDamage",
    "self.targetId",
    "self.attackCooldownTicks",
    "self.attacksLanded",
    "self.respawnTicks",
    "self.abilityPoints",
    "self.portalCooldownTicks",
    "self.channelTicks",
    "self.canShop",
    "self.inOwnSpawn",
    "self.buybackPrice",
    "self.position.x",
    "self.position.y",
    "self.velocity.x",
    "self.velocity.y",
    "self.moveSpeed",
    "self.attackRange",
    "self.score",
    "self.controls.stunTicks",
    "self.controls.rootTicks",
    "self.controls.silenceTicks",
    "match.tick",
    "match.battleTick",
    "match.maxTicks",
    "match.tickRate",
    "match.seed",
    "match.waveTicks",
    "match.waveIntervalTicks",
    "match.gameOver",
    "match.objectCount",
    "match.spellCount",
    "match.campCount",
    "match.allyTowers",
    "match.allyTowersTotal",
    "match.allyBarracks",
    "match.allyBarracksTotal",
    "match.enemyTowers",
    "match.enemyTowersTotal",
    "match.enemyBarracks",
    "match.enemyBarracksTotal",
    "map.width",
    "map.height",
    "map.layers",
    "map.origin",
    "map.enemyGod.x",
    "map.enemyGod.y",
    "draft.active",
    "draft.mode",
    "draft.turnId",
    "draft.playerCount",
    "lastAction.accepted",
    "lastAction.error",
    "tile.x",
    "tile.y",
    "tile.layer",
    "tile.kind",
    "tile.walkable",
    "tile.height",
    "tile.waterDepth"
  ]
  ArrayNames = [
    "objects.id",
    "objects.kind",
    "objects.team",
    "objects.class",
    "objects.hp",
    "objects.maxHp",
    "objects.alive",
    "objects.level",
    "objects.mana",
    "objects.targetId",
    "objects.campId",
    "objects.leader",
    "objects.returning",
    "objects.position.x",
    "objects.position.y",
    "objects.facing.x",
    "objects.facing.y",
    "objects.velocity.x",
    "objects.velocity.y",
    "objects.controls.stunTicks",
    "objects.controls.rootTicks",
    "objects.controls.silenceTicks",
    "abilities.level",
    "abilities.maxLevel",
    "abilities.requiredLevel",
    "abilities.canLevel",
    "abilities.damage",
    "abilities.heal",
    "abilities.restore",
    "abilities.manaCost",
    "abilities.charges",
    "abilities.cooldownTicks",
    "abilities.rechargeTicks",
    "abilities.casting",
    "abilities.effectKind",
    "abilities.range",
    "abilities.radius",
    "items.id",
    "items.count",
    "items.cooldownTicks",
    "objectItems.id",
    "objectItems.count",
    "spells.abilityId",
    "spells.casterId",
    "spells.impactTick",
    "spells.hostile",
    "spells.support",
    "spells.position.x",
    "spells.position.y",
    "camps.tier",
    "camps.position.x",
    "camps.position.y",
    "players.id",
    "players.team",
    "players.class",
    "heroChoices.role",
    "heroChoices.available"
  ]

type
  StructureLoader = ref object
    world: World
    heroId: int32
    previous: array[ArrayNames.len, int]
    specClass: int32
    specRanks: array[HeroAbilitySlot, int32]
    specs: array[HeroAbilitySlot, AbilitySpec]

proc usesStructures*(source: string): bool =
  ## Enables the additional API only with an explicit first-line marker.
  let text = source.strip()
  text.len > 0 and text.splitLines()[0].toLowerAscii() == "' @gota-structures"

proc structureLimits*(limits: Limits): Limits =
  ## Bounds storage for the additional host snapshots and policy variables.
  result = limits
  result.maxGlobals = 512
  result.maxArrays = 128
  result.maxArrayElements = 262144
  result.maxMemoryBytes = 8 * 1024 * 1024
  result.maxSourceBytes += StructureSource.len

func fieldIndex(names: openArray[string], name: string): int {.compileTime.} =
  ## Resolves schema fields at compilation instead of in every decision.
  for i, field in names:
    if field == name:
      return i
  raise newException(ValueError, "Unknown structured field: " & name)

template structureGlobal*(vm: HeroVm, name: static[string]): GlobalView =
  ## Selects a scalar binding by its compile-time schema index.
  vm.structureGlobals[static(fieldIndex(GlobalNames, name))]

template arrayField(name: static[string]): int =
  ## Embeds a field ID without generating a runtime name lookup.
  block:
    const Slot = fieldIndex(ArrayNames, name)
    Slot

proc scalar(value: bool): Value {.inline.} =
  ## Represents an observation flag with BASIC integer truth values.
  toValue(int32(value))

proc scalar(value: int): Value {.inline.} =
  ## Converts bounded host counts into BASIC integers.
  toValue(int32(value))

proc scalar(value: int32): Value {.inline.} =
  ## Preserves an integer observation without fixed-point coercion.
  toValue(value)

proc scalar(value: Fixed): Value {.inline.} =
  ## Preserves a fractional observation in tile units.
  toValue(value)

proc coordinate(value: int32): Fixed {.inline.} =
  ## Uses the same map-coordinate frame as movement and casting commands.
  worldToTiles(value, WorldScale) + fixed(int32(mapTiles() div 2)) - FixedHalf

proc loadObjects(view: ArrayView, state: StructureLoader, field: int) =
  ## Chooses one column operation outside the visible-object loop.
  var
    count = 0
    visibleIds: HashSet[int32]
  if field == arrayField("objects.targetId"):
    for value in state.world.scriptObjects(state.heroId):
      visibleIds.incl(value.id)
  template fill(observation: untyped) =
    ## Applies the selected conversion once per borrowed observation.
    for value {.inject.} in state.world.scriptObjects(state.heroId):
      const present {.inject, used.} = true
      view[count] = scalar(observation)
      inc count
    block:
      let value {.inject.} = WorldObject()
      const present {.inject, used.} = false
      for i in count ..< state.previous[field]:
        view[i] = scalar(observation)
  case field
  of arrayField("objects.id"):
    fill(value.id)
  of arrayField("objects.kind"):
    fill(value.kind)
  of arrayField("objects.team"):
    fill(value.faction)
  of arrayField("objects.class"):
    fill(value.class)
  of arrayField("objects.hp"):
    fill(max(0'i32, value.hp))
  of arrayField("objects.maxHp"):
    fill(value.maxHp)
  of arrayField("objects.alive"):
    fill(value.alive)
  of arrayField("objects.level"):
    fill(value.level)
  of arrayField("objects.mana"):
    fill(value.mana)
  of arrayField("objects.position.x"):
    fill((if present: coordinate(value.position.x) else: FixedZero))
  of arrayField("objects.position.y"):
    fill((if present: coordinate(value.position.z) else: FixedZero))
  of arrayField("objects.velocity.x"):
    fill(worldToTiles(value.velocity.x, WorldScale))
  of arrayField("objects.velocity.y"):
    fill(worldToTiles(value.velocity.z, WorldScale))
  of arrayField("objects.controls.stunTicks"):
    fill(value.controlTicks[StunControl])
  of arrayField("objects.controls.rootTicks"):
    fill(value.controlTicks[RootControl])
  of arrayField("objects.controls.silenceTicks"):
    fill(value.controlTicks[SilenceControl])
  of arrayField("objects.campId"):
    fill(value.camp - 1)
  of arrayField("objects.leader"):
    fill(value.leader)
  of arrayField("objects.returning"):
    fill(value.returning)
  of arrayField("objects.facing.x"):
    fill(motions.normalized(fixedVec2(
      worldToTiles(value.facing.x, WorldScale),
      worldToTiles(value.facing.z, WorldScale)
    )).x)
  of arrayField("objects.facing.y"):
    fill(motions.normalized(fixedVec2(
      worldToTiles(value.facing.x, WorldScale),
      worldToTiles(value.facing.z, WorldScale)
    )).y)
  of arrayField("objects.targetId"):
    fill(if value.targetId in visibleIds: value.targetId else: 0'i32)
  else:
    raise newException(BasicError, "Unknown structured object field")
  state.previous[field] = count

proc loadItems(view: ArrayView, state: StructureLoader, field: int) =
  ## Loads visible inventory stacks without copying other object fields.
  var count = 0
  for value in state.world.scriptObjects(state.heroId):
    for slot in 0 ..< InventorySlots:
      view[count] =
        if field == arrayField("objectItems.id"):
          scalar(value.inventory[slot].ord)
        else:
          scalar(value.itemCounts[slot])
      inc count
  for i in count ..< state.previous[field]:
    view[i] = scalar(0)
  state.previous[field] = count

proc loadSpells(view: ArrayView, state: StructureLoader, field: int) =
  ## Loads one visible warning column and erases vacated rows.
  let
    world = state.world
    team = world.heroById(state.heroId).team
  var
    count = 0
    spell: SpellCast
  while world.visibleSpellAt(state.heroId, count, spell):
    view[count] = case field
      of arrayField("spells.abilityId"):
        scalar(spell.ability.ord)
      of arrayField("spells.casterId"):
        scalar(world.visibleSpellCasterId(state.heroId, spell))
      of arrayField("spells.impactTick"):
        scalar(spell.impact)
      of arrayField("spells.position.x"):
        scalar(coordinate(spell.position.x))
      of arrayField("spells.position.y"):
        scalar(coordinate(spell.position.z))
      of arrayField("spells.hostile"):
        scalar(world.heroById(spell.heroId).team != team)
      of arrayField("spells.support"):
        scalar(spell.ability.abilitySpec.kind != Strike)
      else:
        raise newException(BasicError, "Unknown structured spell field")
    inc count
  for i in count ..< state.previous[field]:
    view[i] = scalar(0)
  state.previous[field] = count

proc ownSpec(state: StructureLoader, hero: Hero,
    slot: HeroAbilitySlot): lent AbilitySpec =
  ## Reuses immutable ability metadata until its class or rank changes.
  if state.specClass != hero.class.ord:
    state.specClass = hero.class.ord.int32
    for rank in state.specRanks.mitems:
      rank = -1
  if state.specRanks[slot] != hero.abilityLevels[slot]:
    state.specs[slot] =
      heroAbility(hero.class, slot).abilitySpec(hero.abilityLevels[slot])
    state.specRanks[slot] = hero.abilityLevels[slot]
  state.specs[slot]

proc loadOwn(view: ArrayView, state: StructureLoader, field: int) =
  ## Reads one own-state column after the latest accepted or rejected action.
  let
    world = state.world
    hero = world.heroById(state.heroId)
  case field
  of arrayField("players.id") .. arrayField("players.class"):
    for i, player in world.heroes:
      view[i] = case field
        of arrayField("players.id"): scalar(player.id)
        of arrayField("players.team"): scalar(player.team.ord)
        else: scalar(world.draftedClass(player.id))
  of arrayField("heroChoices.role") .. arrayField("heroChoices.available"):
    for class in HeroClass:
      view[class.ord] =
        if field == arrayField("heroChoices.role"):
          scalar(class.heroRole.ord)
        else:
          scalar(world.heroAvailable(class.ord.int32, hero.id))
  of arrayField("items.id") .. arrayField("items.cooldownTicks"):
    for slot in 0 ..< InventorySlots:
      view[slot] = case field
        of arrayField("items.id"): scalar(hero.inventory[slot].ord)
        of arrayField("items.count"): scalar(hero.itemCounts[slot])
        else: scalar(hero.itemCooldown(slot, world.tick))
  else:
    for slot in HeroAbilitySlot:
      let rank = hero.abilityLevels[slot]
      view[slot.ord] = case field
        of arrayField("abilities.level"): scalar(rank)
        of arrayField("abilities.maxLevel"): scalar(slot.abilityMaxLevel)
        of arrayField("abilities.requiredLevel"):
          scalar(slot.abilityRequiredLevel(rank + 1))
        of arrayField("abilities.canLevel"):
          scalar(world.phase != Drafting and
            hero.abilityLevelError(slot) == NoActionError)
        of arrayField("abilities.charges"): scalar(hero.charges[slot])
        of arrayField("abilities.cooldownTicks"): scalar(hero.cooldowns[slot])
        of arrayField("abilities.rechargeTicks"): scalar(hero.recharges[slot])
        else:
          let spec {.cursor.} = state.ownSpec(hero, slot)
          case field
          of arrayField("abilities.damage"): scalar(spec.damage)
          of arrayField("abilities.heal"): scalar(spec.heal)
          of arrayField("abilities.restore"): scalar(spec.restore)
          of arrayField("abilities.manaCost"): scalar(spec.manaCost)
          of arrayField("abilities.range"):
            scalar(worldToTiles(spec.range, WorldScale))
          of arrayField("abilities.radius"):
            scalar(worldToTiles(spec.area.radius, WorldScale))
          of arrayField("abilities.casting"): scalar(spec.casting.ord)
          of arrayField("abilities.effectKind"): scalar(spec.kind.ord)
          else:
            raise newException(BasicError, "Unknown structured ability field")

proc loadCamps(view: ArrayView, state: StructureLoader, field: int) =
  ## Reads public camp geometry without exposing population or respawns.
  for i, camp in state.world.camps:
    view[i] = case field
      of arrayField("camps.tier"): scalar(camp.tier)
      of arrayField("camps.position.x"): scalar(coordinate(camp.center.x))
      else: scalar(coordinate(camp.center.z))

proc arrayLoader(state: StructureLoader, field: int): ArrayLoader =
  ## Captures a fixed field binding without retaining the VM or game.
  let name = ArrayNames[field]
  if name.startsWith("objects."):
    result = proc(view: ArrayView) =
      ## Publishes the requested visible object column.
      view.loadObjects(state, field)
  elif name.startsWith("objectItems."):
    result = proc(view: ArrayView) =
      ## Publishes the requested visible inventory column.
      view.loadItems(state, field)
  elif name.startsWith("spells."):
    result = proc(view: ArrayView) =
      ## Publishes the requested warning column.
      view.loadSpells(state, field)
  elif name.startsWith("camps."):
    result = proc(view: ArrayView) =
      ## Publishes the requested camp column.
      view.loadCamps(state, field)
  else:
    result = proc(view: ArrayView) =
      ## Publishes the requested own-state column.
      view.loadOwn(state, field)

proc bindStructures*(vm: HeroVm, program: Program, world: World,
    heroId: int32) =
  ## Resolves checked views and lazy observation columns for this runtime.
  if not vm.structured:
    return
  for name in GlobalNames:
    vm.structureGlobals.add vm.runtime.globalView(name)
    vm.structureFields.add program.referencesGlobal(name)
  let state = StructureLoader(world: world, heroId: heroId, specClass: -1)
  for field, name in ArrayNames:
    vm.structureArrays.add vm.runtime.arrayView(name, writable = true)
    vm.runtime.setArrayLoader(name, arrayLoader(state, field))
  when defined(bassyNative) or defined(bassyNativeStrict):
    let compiled = vm.runtime.compileNative()
    when defined(bassyNativeStrict):
      if jitSupported():
        doAssert compiled > 0, "Native compilation refused structured arrays"
    else:
      discard compiled

const OwnArrays = block:
  var fields: seq[int]
  for field, name in ArrayNames:
    if name.startsWith("players.") or name.startsWith("heroChoices.") or
      name.startsWith("abilities.") or name.startsWith("items."):
        fields.add field
  fields

proc refreshOwnStructures*(game: Game, index: int) =
  ## Refreshes live own state after a command without changing old host data.
  let
    vm {.cursor.} = game.heroVms[index]
    world {.cursor.} = game.world
    hero {.cursor.} = world.heroes[index]
  if vm == nil or not vm.structured:
    return
  template put(name: static[string], observation: untyped) =
    ## Writes one typed scalar field.
    if vm.structureFields[static(fieldIndex(GlobalNames, name))]:
      vm.structureGlobal(name).value = scalar(observation)
  template own(name: static[string], observation: untyped) =
    ## Writes one own-hero field.
    put("self." & name, observation)
  own("id", hero.id)
  own("team", hero.team.ord)
  own("class", world.draftedClass(hero.id))
  own("role", hero.class.heroRole.ord)
  own("hp", max(0'i32, hero.hp))
  own("maxHp", hero.maxHp)
  own("mana", hero.mana)
  own("maxMana", hero.maxMana)
  own("gold", hero.gold)
  own("level", hero.level)
  own("xp", hero.xp)
  own("nextLevelXp", xpForNextLevel(hero.level))
  own("totalXp", hero.totalXp)
  own("deaths", hero.deaths)
  own("layer", hero.navLayer)
  own("alive", hero.hp > 0)
  own("hasMoveTarget", hero.hasMoveTarget)
  own("attackDamage", hero.heroAttackDamage())
  own("attackRange", worldToTiles(hero.class.heroAttackRange(), WorldScale))
  own("moveSpeed", worldToTiles(hero.heroMoveSpeed(), WorldScale))
  own("targetId", hero.attackObjectId)
  own("attackCooldownTicks", world.heroAttackCooldown(hero))
  own("attacksLanded", hero.attacksLanded)
  own("respawnTicks", hero.respawnTicks())
  own("abilityPoints", hero.abilityPoints())
  own("portalCooldownTicks", max(0'i32, hero.portalCooldownEnds - world.tick))
  own("channelTicks", max(0'i32, hero.portalEnds - world.tick))
  own("canShop", world.phase != Drafting and hero.canShop)
  own("inOwnSpawn", hero.inOwnSpawn)
  own("buybackPrice", world.buybackPrice(hero.id))
  own("position.x", coordinate(hero.position.x))
  own("position.y", coordinate(hero.position.z))
  own("velocity.x", worldToTiles(hero.velocity.x, WorldScale))
  own("velocity.y", worldToTiles(hero.velocity.z, WorldScale))
  own(
    "controls.stunTicks",
    max(0'i32, hero.controls[StunControl].ends - world.tick)
  )
  own(
    "controls.rootTicks",
    max(0'i32, hero.controls[RootControl].ends - world.tick)
  )
  own(
    "controls.silenceTicks",
    max(0'i32, hero.controls[SilenceControl].ends - world.tick)
  )
  own("score", score(
    hero.totalXp,
    int(world.tick),
    world.gameOver and not world.draw and hero.team == world.winner
  ))
  own(
    "kills",
    if world.stats == nil: 0 else: int(world.stats.values[index][KillsMetric])
  )
  own(
    "assists",
    if world.stats == nil: 0 else: int(world.stats.values[index][AssistsMetric])
  )
  put("lastAction.error", hero.lastActionError.ord)
  put("draft.active", world.phase == Drafting)
  put("draft.mode", world.draftMode.ord)
  put("draft.turnId", world.draftHeroId())
  put("draft.playerCount", world.heroes.len)
  for field in OwnArrays:
    vm.structureArrays[field].invalidate()

proc refreshStructureCounts*(game: Game) =
  ## Counts team-known buildings once for the common decision frame.
  game.structureCounts = default(typeof(game.structureCounts))
  for building in game.world.buildings:
    for team in Team:
      let first = (if building.team == team: 0 else: 4) +
        (if building.kind == BarracksBuilding: 2 else: 0)
      inc game.structureCounts[team][first + 1]
      if (if building.team == team: building.hp > 0
          else: building.knownAlive[team]):
        inc game.structureCounts[team][first]

proc refreshStructures*(game: Game, index: int) =
  ## Publishes a bounded, visibility-filtered decision snapshot.
  let
    vm {.cursor.} = game.heroVms[index]
    world {.cursor.} = game.world
    hero {.cursor.} = world.heroes[index]
  if vm == nil or not vm.structured:
    return
  vm.runtime.invalidateArrays()
  game.refreshOwnStructures(index)
  template put(name: static[string], observation: untyped) =
    ## Writes one typed scalar field.
    if vm.structureFields[static(fieldIndex(GlobalNames, name))]:
      vm.structureGlobal(name).value = scalar(observation)
  let count = world.worldObjectCount(hero.id)
  if count > ObjectCapacity or world.camps.len > CampCapacity:
    raise newException(BasicError, "GotA structured observation capacity exceeded")
  put("match.tick", world.tick)
  put("match.battleTick", world.battleTick())
  put("match.maxTicks", game.config.maxTicks)
  put("match.tickRate", TickRate)
  put("match.seed", cast[int32](game.config.seed))
  put("match.waveTicks", world.spawnTimerTicks)
  put("match.waveIntervalTicks", world.spawnIntervalTicks)
  put("match.gameOver", world.gameOver)
  put("match.objectCount", count)
  put("match.campCount", world.camps.len)
  put("map.width", mapTiles())
  put("map.height", mapTiles())
  put("map.layers", layers.len)
  put("map.origin", mapTiles() div 2)
  put("map.enemyGod.x", coordinate(world.forts[1 - hero.team.ord].center.x))
  put("map.enemyGod.y", coordinate(world.forts[1 - hero.team.ord].center.z))
  let counts = game.structureCounts[hero.team]
  put("match.allyTowers", counts[0])
  put("match.allyTowersTotal", counts[1])
  put("match.allyBarracks", counts[2])
  put("match.allyBarracksTotal", counts[3])
  put("match.enemyTowers", counts[4])
  put("match.enemyTowersTotal", counts[5])
  put("match.enemyBarracks", counts[6])
  put("match.enemyBarracksTotal", counts[7])
  let spells = world.visibleSpellCount(hero.id)
  if spells > SpellCapacity:
    raise newException(BasicError, "GotA structured spell capacity exceeded")
  put("match.spellCount", spells)
