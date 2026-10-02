## Shared browser/server session options, deterministic bots and snapshot codec.
## Card programs stay in the base set; the wire format contains stable card IDs.
import std/[algorithm, json, sets, strutils]
import sim
export sim

const
  DefaultSessionSeed* = 20260910'i64
  SnapshotSchemaVersion* = 10

type
  SessionOptions* = object
    seed*: int64
    seedGiven*: bool  ## --seed was passed; otherwise games may pick their own.
    playerClass*, opponentClass*: HeroClass
    playerCount*: int  ## Above two selects the multiplayer scene preview.
    human*: bool
    botPaths*: seq[string]
    replayPath*: string  ## A recorded match to watch instead of playing.

  BotActionKind* = enum
    PlayCardAction, EndTurnAction, ResolveTriggerAction, TossAction

  BotAction* = object
    kind*: BotActionKind
    handIndex*: int
    choices*: seq[Choice]  ## One per target of the card or trigger, in order.
    tossIndices*: seq[int]  ## Hand positions to discard, for TossAction.

  Snapshot* = object
    matchId*: string
    revision*: int
    game*: GameState

proc parseHeroClass*(value: string): HeroClass =
  case value.toLowerAscii()
  of "archer": Archer
  of "warrior": Warrior
  of "mage": Mage
  else:
    raise newException(ValueError, "Unknown class '" & value &
      "'; expected archer, warrior, or mage")

proc classId(heroClass: HeroClass): string =
  heroClass.className().toLowerAscii()

proc parseSessionOptions*(args: openArray[string]): SessionOptions =
  ## Accept both --key=value and --key value, including negative numeric seeds.
  ## --human is a flag: --human, --human=true, --human true all work.
  result = SessionOptions(seed: DefaultSessionSeed,
    playerClass: Archer, opponentClass: Mage, playerCount: PlayerCount,
    human: false)
  var index = 0
  while index < args.len:
    let separator = args[index].find('=')
    let key = if separator >= 0: args[index][0 ..< separator] else: args[index]
    if key notin ["--seed", "--class", "--opponent", "--players", "--bot",
        "--human", "--replay"]:
      raise newException(ValueError, "Unknown session option: " & key)
    if key == "--human":
      if separator >= 0:
        let value = args[index][separator + 1 .. ^1]
        result.human = value.toLowerAscii() in ["true", "1", "yes", ""]
      elif index + 1 < args.len and not args[index + 1].startsWith("--"):
        inc index
        result.human = args[index].toLowerAscii() in ["true", "1", "yes"]
      else:
        result.human = true
      inc index
      continue
    var value: string
    if separator >= 0:
      value = args[index][separator + 1 .. ^1]
    else:
      inc index
      if index >= args.len or args[index].startsWith("--"):
        raise newException(ValueError, "Missing value for " & key)
      value = args[index]
    if value.len == 0:
      raise newException(ValueError, "Missing value for " & key)
    case key
    of "--seed":
      try:
        result.seed = parseBiggestInt(value).int64
      except ValueError:
        raise newException(ValueError, "Invalid integer seed: " & value)
      result.seedGiven = true
    of "--class": result.playerClass = parseHeroClass(value)
    of "--opponent": result.opponentClass = parseHeroClass(value)
    of "--players":
      try:
        result.playerCount = parseInt(value)
      except ValueError:
        raise newException(ValueError, "Invalid integer player count: " & value)
      if result.playerCount < PlayerCount:
        raise newException(ValueError, "Player count must be at least " &
          $PlayerCount)
    of "--bot":
      if result.botPaths.len >= PlayerCount:
        raise newException(ValueError, "Too many --bot arguments (max " &
          $PlayerCount & ")")
      result.botPaths.add value
    of "--replay": result.replayPath = value
    else: discard
    inc index

proc botPick(game: GameState, choices: seq[Choice], player: int,
    helps: bool): Choice =
  ## A rule that helps its target goes on the bot's own minion. Others
  ## prefer the enemy hero, then the first enemy minion; the enemy is the
  ## next living player. Either falls back to no target, else nothing
  ## (Canceled).
  let enemy = game.nextPlayer(player)
  if helps:
    for choice in choices:
      if choice.kind == CreatureChoice and choice.owner == player:
        return choice
  else:
    for choice in choices:
      if choice.kind == HeroChoice and choice.owner == enemy:
        return choice
    for choice in choices:
      if choice.kind == CreatureChoice and choice.owner == enemy:
        return choice
  for choice in choices:
    if choice.isNoTarget:
      return choice
  Canceled

proc nextBotAction*(game: GameState, playsThisTurn = 0,
    maxPlaysPerTurn = 3): BotAction =
  ## The fixed hand order and target preferences make bots deterministic.
  ## An explicit budget also bounds future free cards and bouncing strategies.
  result = BotAction(kind: EndTurnAction, handIndex: -1, choices: @[NoTarget])
  if game.waitingToss:
    # Discard the most expensive cards; among equals, the last in hand.
    let hand = game.players[game.pendingToss.player].hand
    var order: seq[int]
    for index in 0 ..< hand.len:
      order.add index
    order.sort(proc(a, b: int): int =
      cmp((hand[b].energyCost, b), (hand[a].energyCost, a)))
    return BotAction(kind: TossAction, handIndex: -1,
      tossIndices: order[0 ..< game.pendingToss.count])
  if game.waitingTrigger:
    # Answer the waiting trigger for its owner, target by target.
    let owner = game.actingPlayer()
    let rules = game.waitingTriggerRules().rules
    var picks: seq[Choice]
    for step in 0 ..< rules.targetCount():
      var pick = game.botPick(game.triggerChoices(picks), owner,
        rules.helpsTarget(step))
      if pick.isCanceled:
        pick = NoTarget
      picks.add pick
    return BotAction(kind: ResolveTriggerAction, handIndex: -1, choices: picks)
  if playsThisTurn >= maxPlaysPerTurn:
    return
  for handIndex, card in game.players[game.currentPlayer].hand:
    if not game.canPlay(handIndex):
      continue
    var picks = @[NoTarget]
    if card.needsChoice():
      picks.setLen(0)
      for step in 0 ..< card.targetCount():
        let pick = game.botPick(game.availableChoices(handIndex, picks),
          game.currentPlayer, card.helpsTarget(step))
        if pick.isCanceled:
          break
        picks.add pick
      if picks.len < card.targetCount():
        continue
    return BotAction(kind: PlayCardAction, handIndex: handIndex,
      choices: picks)

proc applyBotAction*(game: var GameState, action: BotAction): bool =
  case action.kind
  of PlayCardAction:
    game.playCard(action.handIndex, action.choices)
  of EndTurnAction:
    if game.waitingChoice:
      return false
    game.finishTurn()
    true
  of ResolveTriggerAction:
    game.resolvePendingTrigger(action.choices)
  of TossAction:
    game.resolvePendingToss(action.tossIndices)

proc requireKind(node: JsonNode, kind: JsonNodeKind, label: string) =
  if node.isNil or node.kind != kind:
    raise newException(ValueError, "Invalid snapshot " & label)

proc field(node: JsonNode, name: string): JsonNode =
  node.requireKind(JObject, "object")
  if not node.hasKey(name):
    raise newException(ValueError, "Missing snapshot field: " & name)
  node[name]

proc integer(node: JsonNode, label: string,
    minimum = low(int), maximum = high(int)): int =
  node.requireKind(JInt, label)
  let value = node.getBiggestInt()
  if value < minimum.BiggestInt or value > maximum.BiggestInt:
    raise newException(ValueError, "Out-of-range snapshot " & label)
  value.int

proc stringValue(node: JsonNode, label: string): string =
  node.requireKind(JString, label)
  node.getStr()

proc cardToJson(card: Card): JsonNode =
  let id = card.cardId()
  if card != baseCard(id):
    raise newException(ValueError, "Snapshot card is not a base-set card")
  %id

proc cardFromJson(node: JsonNode): Card =
  baseCard(node.stringValue("card ID"))

proc cardsToJson(cards: seq[Card]): JsonNode =
  result = newJArray()
  for card in cards:
    result.add cardToJson(card)

proc cardsFromJson(node: JsonNode): seq[Card] =
  node.requireKind(JArray, "card zone")
  for card in node:
    result.add cardFromJson(card)

proc choiceToJson*(choice: Choice): JsonNode =
  result = %*{"kind": ord(choice.kind), "owner": choice.owner}
  if choice.kind == CreatureChoice:
    result["creatureId"] = %choice.creatureId

proc choiceFromJson*(node: JsonNode): Choice =
  let kind = ChoiceKind(node.field("kind").integer("choice kind",
    ord(low(ChoiceKind)), ord(high(ChoiceKind))))
  let owner = node.field("owner").integer("choice owner", -1, PlayerCount - 1)
  case kind
  of CanceledChoice, NoTargetChoice:
    if owner != -1:
      raise newException(ValueError, "Invalid snapshot no-target owner")
    if kind == CanceledChoice: Canceled else: NoTarget
  of HeroChoice:
    if owner < 0:
      raise newException(ValueError, "Invalid snapshot hero owner")
    heroChoice(owner)
  of CreatureChoice:
    if owner < 0:
      raise newException(ValueError, "Invalid snapshot creature owner")
    creatureChoice(owner, node.field("creatureId").integer("creature ID", 1))

proc keywordsToJson(keywords: set[Keyword]): JsonNode =
  result = newJArray()
  for keyword in keywords:
    result.add %($keyword)

proc keywordsFromJson(node: JsonNode): set[Keyword] =
  node.requireKind(JArray, "keywords")
  for entry in node:
    result.incl parseEnum[Keyword](entry.stringValue("keyword"))

proc firedToJson(fired: set[uint8]): JsonNode =
  result = newJArray()
  for index in fired:
    result.add %index.int

proc firedFromJson(node: JsonNode): set[uint8] =
  node.requireKind(JArray, "fired triggers")
  for entry in node:
    result.incl entry.integer("fired trigger", 0, 255).uint8

proc effectToJson(effect: Effect): JsonNode =
  result = %*{"kind": $effect.kind, "beat": effect.beat}
  case effect.kind
  of DamageHeroEffect:
    result["heroPlayer"] = %effect.heroPlayer
    result["heroDamage"] = %effect.heroDamage
  of DamageCreatureEffect:
    result["damagedCreatureId"] = %effect.damagedCreatureId
    result["creatureDamage"] = %effect.creatureDamage
  of BounceCreatureEffect:
    result["bouncedCreatureId"] = %effect.bouncedCreatureId
  of ModifyStatsEffect:
    result["modifiedCreatureId"] = %effect.modifiedCreatureId
    result["powerChange"] = %effect.powerChange
    result["toughnessChange"] = %effect.toughnessChange
  of LoseKeywordEffect:
    result["keywordLoserId"] = %effect.keywordLoserId
    result["lostKeyword"] = %($effect.lostKeyword)
  of FightEffect:
    result["fighterId"] = %effect.fighterId
    result["opponentId"] = %effect.opponentId
  of SummonEffect:
    result["summonedId"] = %effect.summonedId
    result["summonedOwner"] = %effect.summonedOwner
    result["summonedCard"] = cardToJson(effect.summonedCard)
  of DestroyEffect:
    result["destroyedId"] = %effect.destroyedId
  of DrawEffect:
    result["drawPlayer"] = %effect.drawPlayer
    result["drawCount"] = %effect.drawCount
  of TossEffect:
    result["tossPlayer"] = %effect.tossPlayer
    result["tossCount"] = %effect.tossCount
    result["tossSource"] = %effect.tossSource
    result["tossText"] = %effect.tossText
  of TargetVfxEffect:
    result["targetVfx"] = %ord(effect.targetVfx)
    result["visualTarget"] = choiceToJson(effect.visualTarget)

proc effectFromJson(node: JsonNode): Effect =
  let kind = parseEnum[EffectKind](node.field("kind").stringValue("effect kind"))
  proc int(name: string, minimum = low(int)): int =
    node.field(name).integer("effect " & name, minimum)
  proc player(name: string): int =
    node.field(name).integer("effect " & name, 0, PlayerCount - 1)
  result =
    case kind
    of DamageHeroEffect:
      Effect(kind: kind, heroPlayer: player("heroPlayer"),
        heroDamage: int("heroDamage"))
    of DamageCreatureEffect:
      Effect(kind: kind, damagedCreatureId: int("damagedCreatureId", 1),
        creatureDamage: int("creatureDamage"))
    of BounceCreatureEffect:
      Effect(kind: kind, bouncedCreatureId: int("bouncedCreatureId", 1))
    of ModifyStatsEffect:
      Effect(kind: kind, modifiedCreatureId: int("modifiedCreatureId", 1),
        powerChange: int("powerChange"),
        toughnessChange: int("toughnessChange"))
    of LoseKeywordEffect:
      Effect(kind: kind, keywordLoserId: int("keywordLoserId", 1),
        lostKeyword: parseEnum[Keyword](
          node.field("lostKeyword").stringValue("lost keyword")))
    of FightEffect:
      Effect(kind: kind, fighterId: int("fighterId", 1),
        opponentId: int("opponentId", 1))
    of SummonEffect:
      Effect(kind: kind, summonedId: int("summonedId", 1),
        summonedOwner: player("summonedOwner"),
        summonedCard: cardFromJson(node.field("summonedCard")))
    of DestroyEffect:
      Effect(kind: kind, destroyedId: int("destroyedId", 1))
    of DrawEffect:
      Effect(kind: kind, drawPlayer: player("drawPlayer"),
        drawCount: int("drawCount", 0))
    of TossEffect:
      Effect(kind: kind, tossPlayer: player("tossPlayer"),
        tossCount: int("tossCount", 0),
        tossSource: node.field("tossSource").stringValue("toss source"),
        tossText: node.field("tossText").stringValue("toss text"))
    of TargetVfxEffect:
      Effect(kind: kind, targetVfx: VfxKind(node.field("targetVfx").integer(
          "effect VFX", ord(low(VfxKind)), ord(high(VfxKind)))),
        visualTarget: choiceFromJson(node.field("visualTarget")))
  result.beat = int("beat")

proc gameToJson*(game: GameState): JsonNode =
  var players = newJArray()
  for player in game.players:
    var board = newJArray()
    for minion in player.board:
      board.add %*{"id": minion.id, "owner": minion.owner,
        "card": cardToJson(minion.card),
        "currentToughness": minion.currentToughness,
        "bonusPower": minion.bonusPower,
        "lostKeywords": keywordsToJson(minion.lostKeywords),
        "enteredTurn": minion.enteredTurn,
        "firedTurnTriggers": firedToJson(minion.firedTurnTriggers),
        "canAttack": minion.canAttack,
        "hasAttacked": minion.hasAttacked}
    players.add %*{"heroClass": player.heroClass.classId(),
      "life": player.life, "totalEnergy": player.totalEnergy,
      "energy": player.energy, "deck": cardsToJson(player.deck),
      "hand": cardsToJson(player.hand),
      "discardPile": cardsToJson(player.discardPile), "board": board,
      "dead": player.dead}
  var visualEvents = newJArray()
  for event in game.visualEvents:
    var entry = %*{"kind": ord(event.kind),
      "target": choiceToJson(event.target), "boardIndex": event.boardIndex,
      "boardCount": event.boardCount, "beat": event.beat}
    if event.kind == DeathVfx:
      entry["card"] = cardToJson(event.card)
      entry["power"] = %event.power
    if event.kind in {BounceVfx, TossVfx}:
      entry["card"] = cardToJson(event.card)
      entry["handIndex"] = %event.handIndex
    visualEvents.add entry
  var pendingToss = newJNull()
  if game.waitingToss:
    var remaining = newJArray()
    for effect in game.pendingToss.remaining:
      remaining.add effectToJson(effect)
    pendingToss = %*{"player": game.pendingToss.player,
      "count": game.pendingToss.count, "source": game.pendingToss.source,
      "text": game.pendingToss.text, "remaining": remaining}
  var pendingTriggers = newJArray()
  for pending in game.pendingTriggers:
    pendingTriggers.add %*{"owner": pending.owner,
      "sourceId": pending.sourceId, "trigger": pending.trigger,
      "attacker": choiceToJson(pending.attacker)}
  %*{"players": players, "currentPlayer": game.currentPlayer,
    "turnNumber": game.turnNumber, "nextMinionId": game.nextMinionId,
    "visualEvents": visualEvents, "visualBeat": game.visualBeat,
    "pendingToss": pendingToss,
    "pendingTriggers": pendingTriggers,
    "gameOver": game.gameOver, "winner": game.winner}

proc gameFromJson*(node: JsonNode): GameState =
  ## Current rules consume no RNG after dealing. Full deck order is preserved,
  ## so restoring this state produces the same subsequent turns and bot plays.
  let players = node.field("players")
  players.requireKind(JArray, "players")
  if players.len != PlayerCount:
    raise newException(ValueError, "Snapshot must contain two players")
  result.currentPlayer = node.field("currentPlayer").integer(
    "current player", 0, PlayerCount - 1)
  result.turnNumber = node.field("turnNumber").integer("turn number", 1)
  result.nextMinionId = node.field("nextMinionId").integer("next minion ID", 1)
  var minionIds = initHashSet[int]()
  result.players.setLen(PlayerCount)
  for owner in 0 ..< PlayerCount:
    let source = players[owner]
    var player = PlayerState(
      heroClass: parseHeroClass(source.field("heroClass").stringValue("class")),
      life: source.field("life").integer("life", 0),
      totalEnergy: source.field("totalEnergy").integer("total energy", 0),
      energy: source.field("energy").integer("energy", 0),
      deck: cardsFromJson(source.field("deck")),
      hand: cardsFromJson(source.field("hand")),
      discardPile: cardsFromJson(source.field("discardPile")),
      dead: if source.hasKey("dead"): source["dead"].getBool(false)
        else: false)
    if player.energy > player.totalEnergy:
      raise newException(ValueError, "Snapshot energy exceeds total energy")
    let board = source.field("board")
    board.requireKind(JArray, "board")
    for entry in board:
      let minion = MinionState(
        id: entry.field("id").integer("minion ID", 1),
        owner: entry.field("owner").integer("minion owner", 0, PlayerCount - 1),
        card: cardFromJson(entry.field("card")),
        currentToughness: entry.field("currentToughness").integer("toughness", 0),
        enteredTurn: if entry.hasKey("enteredTurn"):
          entry["enteredTurn"].integer("entered turn", 0) else: 0,
        firedTurnTriggers: if entry.hasKey("firedTurnTriggers"):
          firedFromJson(entry["firedTurnTriggers"]) else: {},
        bonusPower: if entry.hasKey("bonusPower"):
          entry["bonusPower"].integer("power bonus") else: 0,
        lostKeywords: if entry.hasKey("lostKeywords"):
          keywordsFromJson(entry["lostKeywords"]) else: {},
        canAttack: if entry.hasKey("canAttack"): entry["canAttack"].getBool(true) else: true,
        hasAttacked: if entry.hasKey("hasAttacked"): entry["hasAttacked"].getBool(false) else: false)
      # Trinkets have no toughness; minions always have some.
      if minion.owner != owner or minion.card.kind == Spell or
          (minion.card.kind == Minion and minion.currentToughness < 1) or
          minion.id >= result.nextMinionId or minion.id in minionIds:
        raise newException(ValueError, "Invalid snapshot board minion")
      minionIds.incl minion.id
      player.board.add minion
    result.players[owner] = move(player)
  let visualEvents = node.field("visualEvents")
  visualEvents.requireKind(JArray, "visual events")
  for entry in visualEvents:
    let kind = VfxKind(entry.field("kind").integer("visual event kind",
      ord(LightningVfx), ord(high(VfxKind))))
    let event = VisualEvent(
      kind: kind,
      target: choiceFromJson(entry.field("target")),
      boardIndex: entry.field("boardIndex").integer("visual board index", 0),
      boardCount: entry.field("boardCount").integer("visual board count", 0),
      beat: if entry.hasKey("beat"): entry["beat"].integer("visual beat", 0)
        else: 0,
      card: if kind in {DeathVfx, BounceVfx, TossVfx}:
        cardFromJson(entry.field("card"))
        else: Card(),
      handIndex: if kind in {BounceVfx, TossVfx}:
        entry.field("handIndex").integer("bounce hand index", 0) else: 0,
      power: if kind == DeathVfx and entry.hasKey("power"):
        entry["power"].integer("visual power", 0) else: 0)
    # Removed minions legitimately remain in VFX snapshots after a bounce.
    if event.target.kind notin {HeroChoice, CreatureChoice} or
        (event.target.kind == CreatureChoice and
          event.boardIndex >= event.boardCount) or
        (kind == DeathVfx and (event.target.kind != CreatureChoice or
          event.card.kind == Spell)):
      raise newException(ValueError, "Invalid snapshot visual event target")
    result.visualEvents.add event
  if node.hasKey("pendingToss") and node["pendingToss"].kind != JNull:
    let entry = node["pendingToss"]
    var pending = PendingToss(
      player: entry.field("player").integer("toss player", 0, PlayerCount - 1),
      count: entry.field("count").integer("toss count", 1),
      source: entry.field("source").stringValue("toss source"),
      text: entry.field("text").stringValue("toss text"))
    if pending.count > result.players[pending.player].hand.len:
      raise newException(ValueError, "Invalid snapshot pending toss")
    let remaining = entry.field("remaining")
    remaining.requireKind(JArray, "toss effects")
    for effect in remaining:
      pending.remaining.add effectFromJson(effect)
    result.pendingToss = pending
  result.visualBeat = if node.hasKey("visualBeat"):
    node["visualBeat"].integer("visual beat", 0) else: 0
  if node.hasKey("pendingTriggers"):
    let pendingTriggers = node["pendingTriggers"]
    pendingTriggers.requireKind(JArray, "pending triggers")
    for entry in pendingTriggers:
      let pending = PendingTrigger(
        owner: entry.field("owner").integer("trigger owner", 0, PlayerCount - 1),
        sourceId: entry.field("sourceId").integer("trigger source", 1),
        trigger: entry.field("trigger").integer("trigger index", 0),
        attacker: if entry.hasKey("attacker"):
          choiceFromJson(entry["attacker"]) else: Canceled)
      let location = result.minionLocation(pending.sourceId)
      if not location.found or location.player != pending.owner or
          pending.trigger >= result.players[location.player].board[
            location.index].card.triggers().len:
        raise newException(ValueError, "Invalid snapshot pending trigger")
      result.pendingTriggers.add pending
  result.gameOver = if node.hasKey("gameOver"): node["gameOver"].getBool(false) else: false
  result.winner = if node.hasKey("winner"): node["winner"].getInt(-1) else: -1

proc snapshotToJson*(snapshot: Snapshot): JsonNode =
  %*{"schemaVersion": SnapshotSchemaVersion, "matchId": snapshot.matchId,
    "revision": snapshot.revision, "game": gameToJson(snapshot.game)}

proc snapshotFromJson*(node: JsonNode): Snapshot =
  discard node.field("schemaVersion").integer("schema version",
    SnapshotSchemaVersion, SnapshotSchemaVersion)
  result.matchId = node.field("matchId").stringValue("match ID")
  if result.matchId.len == 0:
    raise newException(ValueError, "Snapshot match ID is empty")
  result.revision = node.field("revision").integer("revision", 0)
  result.game = gameFromJson(node.field("game"))

proc snapshotFromJson*(text: string): Snapshot =
  try:
    result = snapshotFromJson(parseJson(text))
  except JsonParsingError as error:
    raise newException(ValueError, "Malformed snapshot JSON: " & error.msg)
