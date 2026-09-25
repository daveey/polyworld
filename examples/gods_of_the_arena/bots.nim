## Gods of the Arena hero scripting: the BASIC surface one hero has
## on the simulation.

import
  polyworld/neural,
  bassy, fixxy,
  polyworld/[mailboxes, metrics, bodies, cli, controllers,
    pathing, profiles, tapes],
  content,
  maps,
  motions,
  observations,
  sim,
  replays,
  terrains

when defined(coworld):
  import polyworld/coworld

type
  HeroDataSlot = enum
    DataSelfId,
    DataSelfTeam,
    DataSelfClass,
    DataSelfX,
    DataSelfY,
    DataSelfHp,
    DataSelfMaxHp,
    DataSelfMana,
    DataSelfMaxMana,
    DataSelfGold,
    DataSelfLevel,
    DataWorldTick,
    DataSelfLayer,
    DataSelfMoveSpeed,
    DataSelfAttackRange,
    DataSelfAttackDamage,
    DataSelfTarget,
    DataSelfAttackCooldown,
    DataSelfAttacksLanded,
    DataSelfPortalCooldown,
    DataSelfChannelTicks,
    DataSelfStunTicks,
    DataSelfRootTicks,
    DataSelfSilenceTicks,
    DataSelfDeaths,
    DataSelfRespawnTicks,
    DataDrafting,
    DataDraftTurnId
  ObjectField = enum
    ObjectLevel, ObjectMana, ObjectItemId, ObjectItemCount,
    ObjectFacingX, ObjectFacingY, ObjectTarget, ObjectVelX, ObjectVelY,
    ObjectStunTicks, ObjectSilenceTicks, ObjectRootTicks,
    ObjectCamp, ObjectLeader, ObjectReturning
  CampField = enum CampX, CampY, CampTier
  SpellField = enum
    SpellAbility, SpellCasterId, SpellX, SpellY, SpellImpactTick
  AbilityField = enum
    AbilityLevel, AbilityMaximum, AbilityRequirement, AbilityCanLevel,
    AbilityDamage, AbilityHeal, AbilityRestore, AbilityManaCost

const
  HeroDataNames: array[HeroDataSlot, string] = [
    "selfId",
    "selfTeam",
    "selfClass",
    "selfX",
    "selfY",
    "selfHp",
    "selfMaxHp",
    "selfMana",
    "selfMaxMana",
    "selfGold",
    "selfLevel",
    "worldTick",
    "selfLayer",
    "selfMoveSpeed",
    "selfAttackRange",
    "selfAttackDamage",
    "selfTarget",
    "selfAttackCooldown",
    "selfAttacksLanded",
    "selfPortalCooldown",
    "selfChannelTicks",
    "selfStunTicks",
    "selfRootTicks",
    "selfSilenceTicks",
    "selfDeaths",
    "selfRespawnTicks",
    "drafting",
    "draftTurnId"
  ]

var
  activeGame: Game
  heroDataIds: array[HeroDataSlot, int32]

proc bindHeroData(program: Program) =
  ## Resolves host data slots once so think ticks do not allocate names.
  for slot, name in HeroDataNames:
    heroDataIds[slot] = program.hostDataIndex(name)
    doAssert heroDataIds[slot] >= 0, "missing host data " & name

proc heroVmLimits(): Limits =
  ## Returns independent structural and per-decision limits for a hero VM.
  result = defaultLimits()
  result.maxStringBytes = 256 * 1024
  result.maxSourceBytes = 64 * 1024
  result.maxCodeInstructions = 20_000
  result.maxArrays = 32
  result.maxArrayElements = 4096
  result.maxGlobals = 256
  result.maxHostData = 128
  result.maxHostFunctions = 128
  result.maxRoutines = 64
  result.maxParameters = 16
  result.maxRegisters = 256
  result.maxSyntaxDepth = 32
  result.maxCallDepth = 16
  result.maxMemoryBytes = 2 * 1024 * 1024
  result.maxInstructions = 20_000
  result.maxWorkUnits = 50_000
  result.maxPrintBytes = 1024
  result.maxPrintEvents = 128

proc terrainProc(
    heroId: int32,
    field: TerrainField,
    explicitLayer: bool
): HostProc =
  ## Binds one terrain field to either the hero's layer or an explicit layer.
  result = proc(arguments: openArray[int32]): int32 =
    ## Reads the requested static field without changing the active hero.
    let layer =
      if explicitLayer:
        arguments[2]
      else:
        let index = heroIndex(activeGame.world, heroId)
        if index < 0:
          return 0
        activeGame.world.heroes[index].navLayer
    let value = terrainValue(arguments[0], arguments[1], layer, field)
    if field != TerrainWalkableField or value == 0:
      return value
    let index = heroIndex(activeGame.world, heroId)
    if index < 0:
      return 0
    let floor = layers[int(layer)]
    int32(activeGame.world.knownWalkable(
      activeGame.world.heroes[index].team,
      int(layer),
      int(arguments[0]) + mapOrigin() - floor.originX,
      int(arguments[1]) + mapOrigin() - floor.originZ
    ))

proc campProc(heroId: int32, field: CampField): HostProc =
  ## Exposes only static camp geometry, never hidden life or respawn state.
  result = proc(arguments: openArray[int32]): int32 =
    let world = activeGame.world
    let index = int(arguments[0])
    if index < 0 or index >= world.camps.len:
      return 0
    let camp = world.camps[index]
    case field
    of CampTier: int32(camp.tier)
    of CampX:
      mapCoordinate(camp.center.x, world.heroById(heroId).team)
    of CampY:
      mapCoordinate(camp.center.z, world.heroById(heroId).team)

proc objectProc(heroId: int32, field: ObjectField): HostProc =
  ## Binds one field to the hero's visibility-filtered object snapshot.
  result = proc(arguments: openArray[int32]): int32 =
    ## Reads a visible object's field without exposing hidden targets.
    let world = activeGame.world
    var value: WorldObject
    if not world.worldObjectAt(heroId, int(arguments[0]), value):
      return (if field == ObjectCamp: -1 else: 0)
    case field
    of ObjectCamp: int32(value.camp - 1)
    of ObjectLeader: int32(value.leader)
    of ObjectReturning: int32(value.returning)
    of ObjectLevel:
      value.level
    of ObjectMana:
      value.mana
    of ObjectStunTicks: value.controlTicks[StunControl]
    of ObjectSilenceTicks: value.controlTicks[SilenceControl]
    of ObjectRootTicks: value.controlTicks[RootControl]
    of ObjectItemId, ObjectItemCount:
      let slot = int(arguments[1])
      if slot < 0 or slot >= InventorySlots:
        return 0
      if field == ObjectItemId:
        int32(value.inventory[slot].ord)
      else:
        value.itemCounts[slot]
    of ObjectFacingX, ObjectFacingY:
      let direction = motions.normalized(fixedVec2(
        worldToTiles(value.facing.x, WorldScale),
        worldToTiles(value.facing.z, WorldScale)
      ))
      tilesToWorld(
        if field == ObjectFacingX: direction.x else: direction.y,
        WorldScale
      )
    of ObjectTarget:
      if value.targetId == 0:
        return 0
      var target: WorldObject
      for i in 0 ..< world.worldObjectCount(heroId):
        if world.worldObjectAt(heroId, i, target) and
          target.id == value.targetId:
            return target.id
      0
    of ObjectVelX:
      value.velocity.x
    of ObjectVelY:
      value.velocity.z

proc spellProc(heroId: int32, field: SpellField): HostProc =
  ## Binds one field to pending spells visible to the hero's team.
  result = proc(arguments: openArray[int32]): int32 =
    ## Reads an impact warning without revealing a hidden caster.
    let world = activeGame.world
    var value: SpellCast
    if not world.visibleSpellAt(heroId, int(arguments[0]), value):
      return if field == SpellAbility: -1 else: 0
    case field
    of SpellAbility:
      int32(value.ability.ord)
    of SpellCasterId:
      world.visibleSpellCasterId(heroId, value)
    of SpellX:
      mapCoordinate(value.position.x, world.heroById(heroId).team)
    of SpellY:
      mapCoordinate(value.position.z, world.heroById(heroId).team)
    of SpellImpactTick:
      value.impact

proc abilityProc(heroId: int32, field: AbilityField): HostProc =
  ## Binds live rank and effect observations to this hero's ability slots.
  result = proc(arguments: openArray[int32]): int32 =
    ## Returns zero for invalid slots without changing command feedback.
    let index = activeGame.world.heroIndex(heroId)
    if index < 0 or arguments[0] < 0 or arguments[0] > HeroAbilitySlot.high.ord:
      return 0
    let
      hero = activeGame.world.heroes[index]
      slot = HeroAbilitySlot(arguments[0])
      rank = hero.abilityLevels[slot]
      spec = heroAbility(hero.class, slot).abilitySpec(rank)
    case field
    of AbilityLevel: rank
    of AbilityMaximum: slot.abilityMaxLevel
    of AbilityRequirement: slot.abilityRequiredLevel(rank + 1)
    of AbilityCanLevel:
      int32(activeGame.world.phase != Drafting and
        hero.abilityLevelError(slot) == NoActionError)
    of AbilityDamage: spec.damage
    of AbilityHeal: spec.heal
    of AbilityRestore: spec.restore
    of AbilityManaCost: spec.manaCost

proc sendChat*(
  game: Game, sender, target: int, text: openArray[char]
): int32 =
  ## Routes chat according to this game's player and team rules.
  if sender notin 0 ..< game.inboxes.len or
    target < -2 or target >= game.inboxes.len:
      return 0
  let id = int32(if target < 0: target else: sender)
  for recipient in 0 ..< game.inboxes.len:
    case target
    of -2:
      discard
    of -1:
      if game.world.heroes[recipient].team != game.world.heroes[sender].team:
        continue
    else:
      if recipient != target:
        continue
    if game.inboxes[recipient].push(id, text):
      inc result

proc initHeroHost(heroId: int32): Host =
  ## Builds the bounded world-query and action interface for one hero.
  result = initHost()
  result.addNeuralFunctions()
  let sendChatProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Sends script text through the game's routing rules.
    let player = activeGame.world.heroIndex(heroId)
    activeGame.heroVms[player].runtime.withString(args[1], text):
      result = activeGame.sendChat(player, int(args[0].asInt), text)
  let pullMailboxProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Copies the oldest message into BASIC and consumes it on success.
    let
      player = activeGame.world.heroIndex(heroId)
      inbox = activeGame.inboxes[player]
    var runtime = activeGame.heroVms[player].runtime
    if inbox.count == 0:
      result = runtime.putString("")
    else:
      result = runtime.putString(inbox.messages[inbox.first])
    discard inbox.pop()
  let mailboxIdProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the channel or DM sender of the last pulled message.
    activeGame.inboxes[activeGame.world.heroIndex(heroId)].lastId
  let mailboxCountProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Counts this player's unread messages.
    int32(activeGame.inboxes[activeGame.world.heroIndex(heroId)].count)
  let mailboxSelfProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns this player's zero-based mailbox address.
    int32(activeGame.world.heroIndex(heroId))
  let mailboxPlayersProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the number of player mailboxes in this game.
    int32(activeGame.inboxes.len)
  discard result.addFunction("sendChat", 2, sendChatProc, 256)
  discard result.addFunction("pullMailbox$", 0, pullMailboxProc, 256)
  discard result.addFunction("mailboxId", 0, mailboxIdProc, 4)
  discard result.addFunction("mailboxCount", 0, mailboxCountProc, 4)
  discard result.addFunction("mailboxSelf", 0, mailboxSelfProc, 4)
  discard result.addFunction("mailboxPlayers", 0, mailboxPlayersProc, 4)
  for error in ActionError:
    discard result.addData($error, error.ord.int32)
  for class in HeroClass:
    discard result.addData($class, class.ord.int32)
  for name in HeroDataNames:
    discard result.addData(name)
  discard result.addData("mapWidth", mapTiles().int32)
  discard result.addData("mapHeight", mapTiles().int32)
  discard result.addData("mapLayers", layers.len.int32)
  discard result.addData("worldScale", WorldScale)
  discard result.addData("tickRate", TickRate)
  for kind in TerrainKind:
    discard result.addData($kind, kind.ord.int32)
  for (name, layer) in [
    ("GroundLayer", GroundLayer),
    ("RedFortLayer", RedFortLayer),
    ("BlueFortLayer", BlueFortLayer),
    ("WaterLayer", WaterLayer)
  ]:
    discard result.addData(name, layer.int32)

  let draftHeroProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Records and validates the active player's hero choice.
    try:
      activeGame.recorder.record ReplayAction(
        tick: uint32(activeGame.world.tick), heroId: heroId,
        kind: ActionDraft, first: arguments[0]
      )
    except ReplayError as error:
      activeGame.recordingError = error.msg
      raise newException(BasicError, "replay recording failed: " & error.msg)
    let accepted = activeGame.world.applyDraft(heroId, arguments[0])
    if accepted:
      activeGame.metrics.command(
        activeGame.world.heroIndex(heroId), activeGame.world.tick
      )
    int32(accepted)
  let draftedClassProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reads any player's public selection, including the opposing team.
    activeGame.world.draftedClass(arguments[0])
  let heroAvailableProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reports whether a valid class remains in the shared draft pool.
    int32(activeGame.world.heroAvailable(arguments[0]))
  let heroRoleProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reads the class role, or minus one for an invalid class.
    if arguments[0] < 0 or arguments[0] > HeroClass.high.ord:
      return -1
    HeroClass(arguments[0]).heroRole.ord.int32
  let draftPlayerCountProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    ## Counts the public player roster in spawn order.
    activeGame.world.heroes.len.int32
  let draftPlayerIdProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reads a player ID by spawn index, or zero outside the roster.
    let index = arguments[0]
    if index < 0 or index >= activeGame.world.heroes.len:
      return 0
    activeGame.world.heroes[index].id
  let draftPlayerTeamProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    ## Reads a player's team by spawn index, or minus one when invalid.
    let index = arguments[0]
    if index < 0 or index >= activeGame.world.heroes.len:
      return -1
    activeGame.world.heroes[index].team.ord.int32
  discard result.addFunction("draftHero", 1, draftHeroProc, 20)
  discard result.addFunction("draftedClass", 1, draftedClassProc, 16)
  discard result.addFunction("heroAvailable", 1, heroAvailableProc, 16)
  discard result.addFunction("heroRole", 1, heroRoleProc, 4)
  discard result.addFunction("draftPlayerCount", 0, draftPlayerCountProc, 4)
  discard result.addFunction("draftPlayerId", 1, draftPlayerIdProc, 4)
  discard result.addFunction("draftPlayerTeam", 1, draftPlayerTeamProc, 4)

  let objectCountProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    int32(worldObjectCount(activeGame.world, heroId))
  let objectIdProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(activeGame.world, heroId, int(arguments[0]), value):
      value.id
    else:
      0
  let objectKindProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(activeGame.world, heroId, int(arguments[0]), value):
      value.kind
    else:
      0
  let objectTeamProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(activeGame.world, heroId, int(arguments[0]), value):
      value.faction
    else:
      0
  let objectClassProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(activeGame.world, heroId, int(arguments[0]), value):
      value.class
    else:
      -1
  let objectXProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(activeGame.world, heroId, int(arguments[0]), value):
      mapCoordinate(value.position.x, activeGame.world.heroById(heroId).team)
    else:
      0
  let objectYProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(activeGame.world, heroId, int(arguments[0]), value):
      mapCoordinate(value.position.z, activeGame.world.heroById(heroId).team)
    else:
      0
  let objectHpProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(activeGame.world, heroId, int(arguments[0]), value):
      max(value.hp, 0'i32)
    else:
      0
  let objectAliveProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    int32(
      worldObjectAt(activeGame.world, heroId, int(arguments[0]), value) and
        value.alive
    )
  let walkToProc: NumericHostProc = proc(
      arguments: openArray[Value]
  ): Value =
    let (x, y, offset) = splitTilePoint(fixedVec2(
      arguments[0].asFixed, arguments[1].asFixed))
    try:
      if activeGame.recorder != nil:
        activeGame.recorder.recordWalkTo(
          uint32(activeGame.world.tick),
          heroId,
          x,
          y,
          offset
        )
    except ReplayError as error:
      activeGame.recordingError = error.msg
      raise newException(
        BasicError,
        "replay recording failed: " & error.msg
      )
    let accepted = applyWalkTo(
      activeGame.world, heroId, x, y, offset
    )
    if accepted:
      activeGame.metrics.command(
        heroIndex(activeGame.world, heroId), activeGame.world.tick
      )
    int32(accepted)
  let attackMoveProc: NumericHostProc = proc(
      arguments: openArray[Value]
  ): Value =
    ## Records and applies the same attack-move order used by human players.
    let (x, y, offset) = splitTilePoint(fixedVec2(
      arguments[0].asFixed, arguments[1].asFixed))
    try:
      if activeGame.recorder != nil:
        activeGame.recorder.record ReplayAction(
          tick: uint32(activeGame.world.tick),
          heroId: heroId,
          kind: ActionAttackMove,
          first: x,
          second: y,
          offset: offset
        )
    except ReplayError as error:
      activeGame.recordingError = error.msg
      raise newException(BasicError, "replay recording failed: " & error.msg)
    let accepted = activeGame.world.applyAttackMove(
      heroId, x, y, offset
    )
    if accepted:
      activeGame.metrics.command(
        heroIndex(activeGame.world, heroId), activeGame.world.tick
      )
    int32(accepted)
  let attackTargetProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    try:
      if activeGame.recorder != nil:
        activeGame.recorder.recordAttackTarget(
          uint32(activeGame.world.tick),
          heroId,
          arguments[0]
        )
    except ReplayError as error:
      activeGame.recordingError = error.msg
      raise newException(
        BasicError,
        "replay recording failed: " & error.msg
      )
    let accepted = applyAttackTarget(
      activeGame.world, heroId, arguments[0]
    )
    if accepted:
      activeGame.metrics.command(
        heroIndex(activeGame.world, heroId), activeGame.world.tick
      )
    int32(accepted)
  let itemIdProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    let index = heroIndex(activeGame.world, heroId)
    let slot = int(arguments[0])
    if index < 0 or slot < 0 or slot >= InventorySlots:
      return 0
    int32(activeGame.world.heroes[index].inventory[slot].ord)
  let itemCountProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    let index = heroIndex(activeGame.world, heroId)
    let slot = int(arguments[0])
    if index < 0 or slot < 0 or slot >= InventorySlots:
      return 0
    activeGame.world.heroes[index].itemCounts[slot]
  let itemCooldownProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    ## Returns live remaining ticks for this inventory slot.
    let hero = activeGame.world.heroById(heroId)
    hero.itemCooldown(int(arguments[0]), activeGame.world.tick)
  let canShopProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reports whether the hero may purchase items here.
    int32(activeGame.world.phase != Drafting and
      activeGame.world.heroById(heroId).canShop)
  let inOwnSpawnProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reports whether the hero is receiving spawn-room recovery.
    int32(activeGame.world.heroById(heroId).inOwnSpawn)
  let buyItemProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    try:
      if activeGame.recorder != nil:
        activeGame.recorder.recordBuyItem(
          uint32(activeGame.world.tick),
          heroId,
          arguments[0]
        )
    except ReplayError as error:
      activeGame.recordingError = error.msg
      raise newException(
        BasicError,
        "replay recording failed: " & error.msg
      )
    let accepted = applyBuyItem(
      activeGame.world, heroId, arguments[0]
    )
    if accepted:
      activeGame.metrics.command(
        heroIndex(activeGame.world, heroId), activeGame.world.tick
      )
    int32(accepted)
  let buybackPriceProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reads this hero's current buyback price from the shared rules.
    activeGame.world.buybackPrice(heroId)
  let buybackProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Records and attempts a buyback using only this hero's gold.
    try:
      activeGame.recorder.recordBuyback(
        uint32(activeGame.world.tick), heroId
      )
    except ReplayError as error:
      activeGame.recordingError = error.msg
      raise newException(BasicError, "replay recording failed: " & error.msg)
    let accepted = activeGame.world.applyBuyback(heroId)
    if accepted:
      activeGame.metrics.command(
        heroIndex(activeGame.world, heroId), activeGame.world.tick
      )
    int32(accepted)
  let useItemProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    try:
      if activeGame.recorder != nil:
        activeGame.recorder.recordUseItem(
          uint32(activeGame.world.tick),
          heroId,
          arguments[0]
        )
    except ReplayError as error:
      activeGame.recordingError = error.msg
      raise newException(
        BasicError,
        "replay recording failed: " & error.msg
      )
    let accepted = applyUseItem(
      activeGame.world, heroId, arguments[0]
    )
    if accepted:
      activeGame.metrics.command(
        heroIndex(activeGame.world, heroId), activeGame.world.tick
      )
    int32(accepted)

  let useItemAtProc: NumericHostProc = proc(arguments: openArray[Value]): Value =
    ## Records and attempts a scroll channel at fractional map coordinates.
    let
      (x, y, offset) = splitTilePoint(fixedVec2(
        arguments[1].asFixed, arguments[2].asFixed))
      slot = arguments[0].asInt
    try:
      activeGame.recorder.recordUseItemAt(
        uint32(activeGame.world.tick), heroId, slot, x, y, offset
      )
    except ReplayError as error:
      activeGame.recordingError = error.msg
      raise newException(BasicError, "replay recording failed: " & error.msg)
    let accepted = activeGame.world.applyUseItemAt(heroId, slot, x, y, offset)
    if accepted:
      activeGame.metrics.command(
        heroIndex(activeGame.world, heroId), activeGame.world.tick
      )
    int32(accepted)

  let levelAbilityProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Records and spends a point through the shared upgrade validator.
    try:
      activeGame.recorder.recordLevelAbility(
        uint32(activeGame.world.tick), heroId, arguments[0]
      )
    except ReplayError as error:
      activeGame.recordingError = error.msg
      raise newException(BasicError, "replay recording failed: " & error.msg)
    let accepted = activeGame.world.applyLevelAbility(heroId, arguments[0])
    if accepted:
      activeGame.metrics.command(
        heroIndex(activeGame.world, heroId), activeGame.world.tick
      )
    int32(accepted)
  let abilityPointsProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reads unspent points immediately, including after an upgrade.
    let index = activeGame.world.heroIndex(heroId)
    if index < 0:
      return 0
    activeGame.world.heroes[index].abilityPoints
  discard result.addFunction("levelAbility", 1, levelAbilityProc, 20)
  discard result.addFunction("abilityPoints", 0, abilityPointsProc, 4)
  for (field, name) in [
    (AbilityLevel, "abilityLevel"),
    (AbilityMaximum, "abilityMaxLevel"),
    (AbilityRequirement, "abilityRequiredLevel"),
    (AbilityCanLevel, "canLevelAbility"),
    (AbilityDamage, "abilityDamage"),
    (AbilityHeal, "abilityHeal"),
    (AbilityRestore, "abilityRestore"),
    (AbilityManaCost, "abilityManaCost")
  ]:
    discard result.addFunction(name, 1, abilityProc(heroId, field), 4)

  let castTargetProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Records and attempts an explicit object-targeted spell.
    let slot = arguments[0]
    try:
      activeGame.recorder.recordCast(
        uint32(activeGame.world.tick), heroId, slot, arguments[1], 0, false
      )
    except ReplayError as error:
      activeGame.recordingError = error.msg
      raise newException(BasicError, "replay recording failed: " & error.msg)
    let accepted = activeGame.world.applyCastTarget(heroId, slot, arguments[1])
    if accepted:
      activeGame.metrics.command(
        heroIndex(activeGame.world, heroId), activeGame.world.tick
      )
    int32(accepted)
  let castPointProc: NumericHostProc = proc(arguments: openArray[Value]): Value =
    ## Records and attempts a ground-aimed spell.
    let (x, y, offset) = splitTilePoint(fixedVec2(
      arguments[1].asFixed, arguments[2].asFixed))
    let slot = arguments[0].asInt
    try:
      activeGame.recorder.recordCast(
        uint32(activeGame.world.tick),
        heroId,
        slot,
        x,
        y,
        true,
        offset
      )
    except ReplayError as error:
      activeGame.recordingError = error.msg
      raise newException(BasicError, "replay recording failed: " & error.msg)
    let accepted = activeGame.world.applyCastPoint(
      heroId, slot, x, y, offset
    )
    if accepted:
      activeGame.metrics.command(
        heroIndex(activeGame.world, heroId), activeGame.world.tick
      )
    int32(accepted)
  let abilityChargesProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reads remaining charges for one of this hero's four ability slots.
    let index = heroIndex(activeGame.world, heroId)
    if index < 0 or arguments[0] < 0 or arguments[0] > HeroAbilitySlot.high.ord:
      return 0
    activeGame.world.heroes[index].charges[HeroAbilitySlot(arguments[0])]
  let abilityCooldownProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reads the ticks before this slot may cast again.
    let index = heroIndex(activeGame.world, heroId)
    if index < 0 or arguments[0] < 0 or arguments[0] > HeroAbilitySlot.high.ord:
      return 0
    activeGame.world.heroes[index].cooldowns[HeroAbilitySlot(arguments[0])]
  let abilityRechargeProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reads ticks until this slot restores its next charge.
    let index = heroIndex(activeGame.world, heroId)
    if index < 0 or arguments[0] < 0 or arguments[0] > HeroAbilitySlot.high.ord:
      return 0
    activeGame.world.heroes[index].recharges[HeroAbilitySlot(arguments[0])]
  let lastActionErrorProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reads only this hero's last submitted command error.
    let index = activeGame.world.heroIndex(heroId)
    if index >= 0:
      activeGame.world.heroes[index].lastActionError.ord.int32
    else:
      0'i32
  discard result.addFunction("lastActionError", 0, lastActionErrorProc, 4)
  discard result.addFunction("castTarget", 2, castTargetProc, 80)
  discard result.addFunction("castPoint", 3, castPointProc, 80)
  discard result.addFunction("abilityCharges", 1, abilityChargesProc, 4)
  discard result.addFunction("abilityCooldown", 1, abilityCooldownProc, 4)
  discard result.addFunction("abilityRecharge", 1, abilityRechargeProc, 4)

  for (field, name) in [
    (ObjectCamp, "objectCamp"),
    (ObjectLeader, "objectLeader"),
    (ObjectReturning, "objectReturning"),
    (ObjectLevel, "objectLevel"),
    (ObjectMana, "objectMana"),
    (ObjectStunTicks, "objectStunTicks"),
    (ObjectSilenceTicks, "objectSilenceTicks"),
    (ObjectRootTicks, "objectRootTicks"),
    (ObjectItemId, "objectItemId"),
    (ObjectItemCount, "objectItemCount"),
    (ObjectFacingX, "objectFacingX"),
    (ObjectFacingY, "objectFacingY"),
    (ObjectTarget, "objectTarget"),
    (ObjectVelX, "objectVelX"),
    (ObjectVelY, "objectVelY")
  ]:
    let arity =
      if field in {ObjectItemId, ObjectItemCount}: 2 else: 1
    discard result.addFunction(name, arity, objectProc(heroId, field), 16)
  let spellCountProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Counts warnings and projectiles visible to this hero's team.
    int32(activeGame.world.visibleSpellCount(heroId))
  discard result.addFunction("spellCount", 0, spellCountProc, 16)
  for (field, name) in [
    (SpellAbility, "spellAbility"),
    (SpellCasterId, "spellCasterId"),
    (SpellX, "spellX"),
    (SpellY, "spellY"),
    (SpellImpactTick, "spellImpactTick")
  ]:
    discard result.addFunction(name, 1, spellProc(heroId, field), 16)

  discard result.addFunction("objectCount", 0, objectCountProc, 2)
  discard result.addFunction("objectId", 1, objectIdProc, 4)
  let campCountProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Counts generated camp clearings regardless of fog or spawn state.
    int32(activeGame.world.camps.len)
  discard result.addFunction("campCount", 0, campCountProc, 4)
  for (field, name) in [(CampX, "campX"), (CampY, "campY"),
    (CampTier, "campTier")]:
      discard result.addFunction(name, 1, campProc(heroId, field), 4)
  discard result.addFunction("objectKind", 1, objectKindProc, 4)
  discard result.addFunction("objectTeam", 1, objectTeamProc, 4)
  discard result.addFunction("objectClass", 1, objectClassProc, 4)
  discard result.addFunction("objectX", 1, objectXProc, 4)
  discard result.addFunction("objectY", 1, objectYProc, 4)
  discard result.addFunction("objectHp", 1, objectHpProc, 4)
  discard result.addFunction("objectAlive", 1, objectAliveProc, 4)
  discard result.addFunction("walkTo", 2, walkToProc, 800)
  discard result.addFunction("attackMove", 2, attackMoveProc, 800)
  discard result.addFunction("attackTarget", 1, attackTargetProc, 20)
  discard result.addFunction("itemId", 1, itemIdProc, 4)
  discard result.addFunction("itemCount", 1, itemCountProc, 4)
  discard result.addFunction("itemCooldown", 1, itemCooldownProc, 4)
  discard result.addFunction("canShop", 0, canShopProc, 4)
  discard result.addFunction("inOwnSpawn", 0, inOwnSpawnProc, 4)
  discard result.addFunction("buyItem", 1, buyItemProc, 20)
  discard result.addFunction("buybackPrice", 0, buybackPriceProc, 4)
  discard result.addFunction("buyback", 0, buybackProc, 20)
  discard result.addFunction("useItem", 1, useItemProc, 20)
  discard result.addFunction("useItemAt", 3, useItemAtProc, 800)
  for (field, name) in [
    (TerrainKindField, "terrainKind"),
    (TerrainWalkableField, "terrainWalkable"),
    (TerrainHeightField, "terrainHeight"),
    (TerrainWaterDepthField, "terrainWaterDepth")
  ]:
    discard result.addFunction(name, 2, terrainProc(heroId, field, false), 32)
    discard result.addFunction(
      name & "At",
      3,
      terrainProc(heroId, field, true),
      32
    )

proc loadBots*(
    game: Game,
    groups: openArray[BotGroup],
    playerSlot = 0'i32
) =
  ## Loads bot files into every hero slot except the optional human slot.
  activeGame = game
  let
    limits = heroVmLimits()
    schema = initHeroHost(0)
    kinds = controllerKinds(game.world.heroes.len, playerSlot)
    sources = groups.expandBotSources(kinds)
  game.heroVms.setLen(game.world.heroes.len)
  game.inboxes.setLen(game.world.heroes.len)
  for inbox in game.inboxes.mitems:
    inbox = newMailbox()
  var bound = false
  for i in 0 ..< game.world.heroes.len:
    if kinds[i] == PlayerController:
      continue
    let source = sources[i]
    let program =
      when defined(coworld):
        compilePlayer(source, schema, limits, int(i))
      else:
        compile(source, schema, limits)
    if not bound:
      bindHeroData(program)
      bound = true
    game.heroVms[i] = HeroVm(
      runtime: initRuntime(
        program,
        initHeroHost(game.world.heroes[i].id),
        limits
      ),
      limits: limits,
      ready: true
    )
    when defined(coworld):
      game.heroVms[i].output = playerPrinter(int(i))

proc runHeroScript(game: Game, index: int) =
  ## Runs one bounded BASIC decision, including while awaiting respawn.
  if index < 0 or index >= game.heroVms.len:
    return
  let
    hero = game.world.heroes[index]
    vm = game.heroVms[index]
  if vm == nil or vm.failed:
    return
  try:
    vm.runtime.restart()
    discard game.world.worldObjectCount(hero.id)
    vm.runtime.setData(heroDataIds[DataSelfId], hero.id)
    vm.runtime.setData(heroDataIds[DataSelfTeam], int32(hero.team.ord))
    vm.runtime.setData(
      heroDataIds[DataSelfClass], game.world.draftedClass(hero.id)
    )
    vm.runtime.setData(
      heroDataIds[DataDrafting], int32(game.world.phase == Drafting)
    )
    vm.runtime.setData(
      heroDataIds[DataDraftTurnId], game.world.draftHeroId()
    )
    vm.runtime.setData(
      heroDataIds[DataSelfX],
      mapCoordinate(hero.position.x, hero.team)
    )
    vm.runtime.setData(
      heroDataIds[DataSelfY],
      mapCoordinate(hero.position.z, hero.team)
    )
    vm.runtime.setData(heroDataIds[DataSelfHp], max(hero.hp, 0'i32))
    vm.runtime.setData(heroDataIds[DataSelfMaxHp], hero.maxHp)
    vm.runtime.setData(heroDataIds[DataSelfMana], hero.mana)
    vm.runtime.setData(heroDataIds[DataSelfMaxMana], hero.maxMana)
    vm.runtime.setData(heroDataIds[DataSelfGold], int32(hero.gold))
    vm.runtime.setData(heroDataIds[DataSelfLevel], int32(hero.level))
    vm.runtime.setData(heroDataIds[DataWorldTick], game.world.tick)
    vm.runtime.setData(heroDataIds[DataSelfLayer], hero.navLayer)
    vm.runtime.setData(heroDataIds[DataSelfMoveSpeed], hero.heroMoveSpeed())
    vm.runtime.setData(
      heroDataIds[DataSelfAttackRange], hero.class.heroAttackRange()
    )
    vm.runtime.setData(
      heroDataIds[DataSelfAttackDamage], hero.heroAttackDamage()
    )
    vm.runtime.setData(heroDataIds[DataSelfTarget], hero.attackObjectId)
    vm.runtime.setData(
      heroDataIds[DataSelfAttackCooldown],
      game.world.heroAttackCooldown(hero)
    )
    vm.runtime.setData(heroDataIds[DataSelfAttacksLanded], hero.attacksLanded)
    vm.runtime.setData(heroDataIds[DataSelfPortalCooldown],
      max(0'i32, hero.portalCooldownEnds - game.world.tick))
    vm.runtime.setData(heroDataIds[DataSelfChannelTicks],
      max(0'i32, hero.portalEnds - game.world.tick))
    vm.runtime.setData(heroDataIds[DataSelfStunTicks],
      max(0'i32, hero.controls[StunControl].ends - game.world.tick))
    vm.runtime.setData(heroDataIds[DataSelfSilenceTicks],
      max(0'i32, hero.controls[SilenceControl].ends - game.world.tick))
    vm.runtime.setData(heroDataIds[DataSelfRootTicks],
      max(0'i32, hero.controls[RootControl].ends - game.world.tick))
    vm.runtime.setData(heroDataIds[DataSelfDeaths], hero.deaths)
    vm.runtime.setData(heroDataIds[DataSelfRespawnTicks], hero.respawnTicks())
    discard vm.runtime.run(vm.output)
    inc vm.decisions
  except BasicError as error:
    vm.failed = true
    vm.lastError = error.msg
    when defined(coworld):
      playerError(index, error.msg)
    else:
      echo "hero ", hero.id, " BASIC error: ", error.msg
  vm.lastWork = vm.runtime.workUsed
  vm.lastInstructions = vm.runtime.instructionsUsed
  game.metrics.decision(
    index, game.world.tick, vm.lastInstructions,
    heroVmLimits().maxInstructions
  )

proc runBotDecisions*(game: Game) {.measure.} =
  ## Runs every VM in seeded cyclic order and advances the first slot.
  activeGame = game
  if game.world.phase == Drafting:
    runHeroScript(game, game.world.heroIndex(game.world.draftHeroId()))
    return
  let ownsFrame = game.world.freezeObservations()
  defer:
    if ownsFrame:
      game.world.thawObservations()
  for offset in 0 ..< game.world.heroes.len:
    let index = (game.world.heroTurnStart + offset) mod game.world.heroes.len
    runHeroScript(game, index)
  game.world.heroTurnStart =
    (game.world.heroTurnStart + 1) mod game.world.heroes.len
