## Call to Adventure hero scripting: the BASIC surface one hero has
## on the simulation.
##
## One VM per hero. Commands go through `applyHeroAction`, so a script
## cannot write world fields directly.

import
  polyworld/neural,
  bassy,
  polyworld/[mailboxes, bodies, metrics, cli, controllers,
    pathing, profiles],
  content,
  sim,
  replays

when defined(coworld):
  import polyworld/coworld

type
  HeroDataSlot = enum
    DataSelfId,
    DataSelfClass,
    DataWorldTick,
    DataCurrentLevel,
    DataX,
    DataY,
    DataHp,
    DataMaxHp,
    DataMana,
    DataMaxMana,
    DataObjectiveLevel,
    DataObjectiveX,
    DataObjectiveY

const
  HeroDataNames: array[HeroDataSlot, string] = [
    "selfId",
    "selfClass",
    "worldTick",
    "currentLevel",
    "x",
    "y",
    "hp",
    "maxHp",
    "mana",
    "maxMana",
    "objectiveLevel",
    "objectiveX",
    "objectiveY"
  ]

var
  activeGame: Game
  activeHeroSlot = -1'i32
  heroDataIds: array[HeroDataSlot, int32]

proc bindHeroData(program: Program) =
  ## Resolves host data slots once so think ticks do not allocate names.
  for slot, name in HeroDataNames:
    heroDataIds[slot] = program.hostDataIndex(name)
    doAssert heroDataIds[slot] >= 0, "missing host data " & name

proc validReplayPayload(action: ReplayAction): bool =
  ## Checks whether one bot attempt can be represented by the replay schema.
  case action.kind
  of ActionWalkTo:
    action.first >= 0 and action.first < LevelCount and
      action.second >= 0 and action.second < GridTiles and
      action.third >= 0 and action.third < GridTiles
  of ActionAttackTarget, ActionPickupTarget, ActionHealTarget:
    action.first > 0
  of ActionUseItem, ActionDropItem:
    action.first >= 0 and action.first < InventorySlots
  else:
    false

proc issueHeroAction(action: ReplayAction): int32 =
  ## Records and applies one well-formed VM command attempt.
  if activeGame == nil or activeHeroSlot < 0:
    return 0
  if not action.validReplayPayload():
    return 0
  if activeGame.recorder != nil:
    activeGame.recorder.recordAction(
      action.tick,
      action.heroId,
      action.kind,
      action.first,
      action.second,
      action.third,
      action.offset
    )
  int32(activeGame.applyHeroAction(activeHeroSlot, action))

proc heroLimits(): Limits =
  ## Defines one isolated hero VM's source, memory, and decision budgets.
  result = defaultLimits()
  result.maxStringBytes = 256 * 1024
  result.maxSourceBytes = 128 * 1024
  result.maxCodeInstructions = 50_000
  result.maxArrays = 32
  result.maxArrayElements = 16_384
  result.maxGlobals = 512
  result.maxHostData = 32
  result.maxHostFunctions = 64
  result.maxRoutines = 64
  result.maxParameters = 16
  result.maxRegisters = 256
  result.maxSyntaxDepth = 32
  result.maxCallDepth = 24
  result.maxMemoryBytes = 4 * 1024 * 1024
  result.maxInstructions = 100_000
  result.maxWorkUnits = 200_000
  result.maxPrintBytes = 4 * 1024
  result.maxPrintEvents = 256

proc sendChat*(
  game: Game, sender, target: int, text: openArray[char]
): int32 =
  ## Broadcasts to players within 16 tiles on the sender's level.
  if sender notin 0 ..< game.inboxes.len or target != -2:
    return 0
  let origin = game.world.actors[sender].home
  for recipient in 0 ..< game.inboxes.len:
    let distance = tileDistance(origin, game.world.actors[recipient].home)
    if distance in 0 .. 16 and game.inboxes[recipient].push(-2, text):
      inc result

proc buildHeroHost(heroId: int32): Host =
  ## Builds the world-query and high-level action API for one hero.
  result = initHost()
  result.addNeuralFunctions()
  let sendChatProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Sends script text through the game's routing rules.
    let player = int(heroId - 100)
    activeGame.heroVms[player].runtime.withString(args[1], text):
      result = activeGame.sendChat(player, int(args[0].asInt), text)
  let pullMailboxProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Copies the oldest message into BASIC and consumes it on success.
    let
      player = int(heroId - 100)
      inbox = activeGame.inboxes[player]
    var runtime = activeGame.heroVms[player].runtime
    if inbox.count == 0:
      result = runtime.putString("")
    else:
      result = runtime.putString(inbox.messages[inbox.first])
    discard inbox.pop()
  let mailboxIdProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the channel or DM sender of the last pulled message.
    activeGame.inboxes[int(heroId - 100)].lastId
  let mailboxCountProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Counts this player's unread messages.
    int32(activeGame.inboxes[int(heroId - 100)].count)
  let mailboxSelfProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns this player's zero-based mailbox address.
    int32(int(heroId - 100))
  let mailboxPlayersProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the number of player mailboxes in this game.
    int32(activeGame.inboxes.len)
  discard result.addFunction("sendChat", 2, sendChatProc, 256)
  discard result.addFunction("pullMailbox$", 0, pullMailboxProc, 256)
  discard result.addFunction("mailboxId", 0, mailboxIdProc, 4)
  discard result.addFunction("mailboxCount", 0, mailboxCountProc, 4)
  discard result.addFunction("mailboxSelf", 0, mailboxSelfProc, 4)
  discard result.addFunction("mailboxPlayers", 0, mailboxPlayersProc, 4)
  for name in HeroDataNames:
    discard result.addData(name)

  let nearestEnemyProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    discard arguments
    var target = activeGame.nearestEnemy(activeHeroSlot, HeroAggroTiles)
    if target < 0 and activeGame.world.phase == DescendingPhase:
      let anchor = activeGame.partyAnchor()
      target =
        if anchor >= 0:
          activeGame.nearestEnemy(anchor, int32(GridTiles * 2))
        else:
          activeGame.nearestEnemy(activeHeroSlot, int32(GridTiles * 2))
    if target >= 0:
      activeGame.world.actors[target].id
    else:
      0
  discard result.addFunction("nearestEnemy", 0, nearestEnemyProc, 30)

  let nearestLootProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    discard arguments
    let itemIndex = activeGame.nearestLoot(activeHeroSlot)
    if itemIndex < 0:
      return 0
    activeGame.world.items[itemIndex].id
  discard result.addFunction("nearestLoot", 0, nearestLootProc, 20)

  let woundedAllyProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    discard arguments
    let actor = activeGame.world.actors[activeHeroSlot]
    if actor.heroClass != ClericClass or
        actor.cooldowns[int(HealingBloom)] != 0 or
        actor.mana < Abilities[HealingBloom].manaCost:
      return 0
    var worstFraction = 70'i32
    for slot in 0 ..< PartySize:
      let target = activeGame.world.actors[slot]
      if not target.alive or target.home.level != actor.home.level or
          tileDistance(actor.home, target.home) >
            int32(Abilities[HealingBloom].rangeTiles):
        continue
      let fraction =
        int32(target.hp) * 100 div int32(target.maxHp)
      if fraction < worstFraction:
        worstFraction = fraction
        result = target.id
  discard result.addFunction("woundedAlly", 0, woundedAllyProc, 12)

  let walkToProc: NumericHostProc = proc(arguments: openArray[Value]): Value =
    let (x, z, offset) = splitTilePoint(fixedVec2(
      arguments[1].asFixed, arguments[2].asFixed))
    issueHeroAction(ReplayAction(
      tick: uint32(activeGame.world.tick),
      heroId: heroId,
      kind: ActionWalkTo,
      first: arguments[0].asInt,
      second: x,
      third: z,
      offset: offset
    ))
  discard result.addFunction("walkTo", 3, walkToProc, 300)

  template targetAction(functionName: string, actionKind: uint8) =
    let callback: HostProc = proc(arguments: openArray[int32]): int32 =
      issueHeroAction(ReplayAction(
        tick: uint32(activeGame.world.tick),
        heroId: heroId,
        kind: actionKind,
        first: arguments[0]
      ))
    discard result.addFunction(functionName, 1, callback, 120)

  targetAction("attackTarget", ActionAttackTarget)
  targetAction("pickupTarget", ActionPickupTarget)
  targetAction("healTarget", ActionHealTarget)

  let useItemProc: HostProc = proc(arguments: openArray[int32]): int32 =
    issueHeroAction(ReplayAction(
      tick: uint32(activeGame.world.tick),
      heroId: heroId,
      kind: ActionUseItem,
      first: arguments[0]
    ))
  discard result.addFunction("useItem", 1, useItemProc, 40)

  let dropItemProc: HostProc = proc(arguments: openArray[int32]): int32 =
    issueHeroAction(ReplayAction(
      tick: uint32(activeGame.world.tick),
      heroId: heroId,
      kind: ActionDropItem,
      first: arguments[0]
    ))
  discard result.addFunction("dropItem", 1, dropItemProc, 40)

proc loadBots*(
    game: Game,
    groups: openArray[BotGroup],
    playerSlot = 0'i32
) =
  ## Compiles bot files into every party slot except the optional human slot.
  let
    limits = heroLimits()
    schema = buildHeroHost(100)
    kinds = controllerKinds(PartySize, playerSlot)
    sources = groups.expandBotSources(kinds)
  for inbox in game.inboxes.mitems:
    inbox = newMailbox()
  var bound = false
  for slot in 0 ..< PartySize:
    if kinds[slot] == PlayerController:
      continue
    let source = sources[slot]
    let program =
      when defined(coworld):
        compilePlayer(source, schema, limits, int(slot))
      else:
        compile(source, schema, limits)
    if not bound:
      bindHeroData(program)
      bound = true
    game.heroVms[slot] = HeroVm(
      runtime: initRuntime(
        program,
        buildHeroHost(int32(100 + slot)),
        limits
      ),
      ready: true,
    )
    when defined(coworld):
      game.heroVms[slot].output = playerPrinter(int(slot))

proc runBotDecisions*(game: Game, slot: int32) {.measure.} =
  ## Runs one live hero VM decision.
  let actor = game.world.actors[slot]
  if not actor.alive or actor.busy:
    return
  if game.heroVms[slot] == nil or
      not game.heroVms[slot].ready or
      game.heroVms[slot].failed:
    return
  activeGame = game
  activeHeroSlot = slot
  let objective = game.objectiveTile(slot)
  try:
    game.heroVms[slot].runtime.restart()
    game.heroVms[slot].runtime.setData(heroDataIds[DataSelfId], actor.id)
    game.heroVms[slot].runtime.setData(
      heroDataIds[DataSelfClass],
      int32(actor.class)
    )
    game.heroVms[slot].runtime.setData(
      heroDataIds[DataWorldTick],
      game.world.tick
    )
    game.heroVms[slot].runtime.setData(
      heroDataIds[DataCurrentLevel],
      int32(actor.home.level)
    )
    game.heroVms[slot].runtime.setData(
      heroDataIds[DataX],
      int32(actor.home.x)
    )
    game.heroVms[slot].runtime.setData(
      heroDataIds[DataY],
      int32(actor.home.z)
    )
    game.heroVms[slot].runtime.setData(
      heroDataIds[DataHp],
      int32(actor.hp)
    )
    game.heroVms[slot].runtime.setData(
      heroDataIds[DataMaxHp],
      int32(actor.maxHp)
    )
    game.heroVms[slot].runtime.setData(
      heroDataIds[DataMana],
      int32(actor.mana)
    )
    game.heroVms[slot].runtime.setData(
      heroDataIds[DataMaxMana],
      int32(actor.maxMana)
    )
    game.heroVms[slot].runtime.setData(
      heroDataIds[DataObjectiveLevel],
      int32(objective.level)
    )
    game.heroVms[slot].runtime.setData(
      heroDataIds[DataObjectiveX],
      int32(objective.x)
    )
    game.heroVms[slot].runtime.setData(
      heroDataIds[DataObjectiveY],
      int32(objective.z)
    )
    discard game.heroVms[slot].runtime.run(game.heroVms[slot].output)
    inc game.heroVms[slot].decisions
  except BasicError as error:
    game.heroVms[slot].failed = true
    game.heroVms[slot].lastError = error.msg
    when defined(coworld):
      playerError(int(slot), error.msg)
    else:
      echo "hero ", actor.id, " BASIC error: ", error.msg
  game.heroVms[slot].lastWork = game.heroVms[slot].runtime.workUsed
  game.heroVms[slot].lastInstructions =
    game.heroVms[slot].runtime.instructionsUsed
  game.metrics.decision(
    int(slot), game.world.tick, game.heroVms[slot].lastInstructions,
    heroLimits().maxInstructions
  )
  activeGame = nil
  activeHeroSlot = -1
