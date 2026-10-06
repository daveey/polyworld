## BASIC VM bot integration for AWM, following the Polyworld convention.
## Bots are .bas scripts compiled once and executed each decision point.
## Each invocation selects one action, using the same rules as human play.
import
  std/[options, random],
  bassy, polyworld/[policyhosts, mailboxes],
  sim, replays
export bassy

type
  BotDataSlot = enum
    DataSelfPlayer
    DataEnemyPlayer
    DataTurnNumber
    DataSelfLife
    DataEnemyLife
    DataEnergy
    DataTotalEnergy
    DataHandSize
    DataSelfBoardSize
    DataEnemyBoardSize
    DataSelfDeckSize
    DataEnemyDeckSize
    DataPlayerCount
    DataCurrentPlayer
    DataTossCount
    DataTriggerTargets
    DataSelectingClass
    DataSelfClass
    DataEnemyClass

  BotVm* = ref object
    runtime*: Runtime
    failed*: bool  ## Compilation or presentation failure stops this script.
    lastError*: string  ## Why the last decision (or the compile) failed.
    output*: PrintProc  ## Where the script's PRINT goes (nil: nowhere).
    player*: int  ## The seat that owns this VM.
    rng: Rand
    rngInitialized: bool
    selectingClass: bool
    selectedClass: int
    action*: ReplayAction  ## The action explicitly selected this decision.
    playedHand*: int  ## The hand card the last decision played, or -1.
    playedChoices*: seq[Choice]  ## Its targets, one per step, in order.

const
  DataSlotNames: array[BotDataSlot, string] = [
    "selfPlayer", "enemyPlayer", "turnNumber",
    "selfLife", "enemyLife",
    "energy", "totalEnergy",
    "handSize",
    "selfBoardSize", "enemyBoardSize",
    "selfDeckSize", "enemyDeckSize",
    "playerCount", "currentPlayer", "tossCount", "triggerTargets",
    "selectingClass", "selfClass", "enemyClass"
  ]

var
  activeGame: ptr GameState
  activePlayer: int32
  activeEnemy: int32  ## The next living player: the bot's one enemy.
  activeVm: BotVm
  inboxes*: seq[Mailbox]
    ## One inbox per seat, replaced when bots are loaded for a match.

proc cardChoices(handIndex: int, picked: seq[Choice] = @[]): seq[Choice] =
  ## Previews a permanent's placement so scripts can target it like humans.
  if activeGame[].waitingChoice or
    activePlayer.int != activeGame[].currentPlayer:
      return @[]
  let hand = activeGame[].players[activePlayer].hand
  if handIndex notin 0 ..< hand.len:
    return @[]
  let card = hand[handIndex]
  if card.kind == Spell:
    return activeGame[].availableChoices(handIndex, picked)
  var preview = activeGame[].copyGameState()
  preview.players[activePlayer].energy = max(
    preview.players[activePlayer].energy, card.energyCost)
  discard preview.playMinion(handIndex)
  preview.availableChoices(card, picked)

proc stepChoices(handIndex, step: int): seq[Choice] =
  ## Lists a target step without a prefix; use nextChoices for dependencies.
  let hand = activeGame[].players[activePlayer].hand
  if handIndex notin 0 ..< hand.len or
    step notin 0 ..< hand[handIndex].targetCount():
      return @[]
  cardChoices(handIndex, newSeq[Choice](step))

proc triggerStepChoices(step: int): seq[Choice] =
  ## Returns a bounded target step from the waiting trigger.
  if step notin 0 ..< activeGame[].waitingTriggerRules().rules.targetCount():
    return @[]
  activeGame[].triggerChoices(newSeq[Choice](step))

proc sendChat*(sender, target: int, text: openArray[char]): int32 =
  ## Routes global broadcasts (-2) and direct messages (a seat) between
  ## players. AWM has no teams. Returns the inboxes that took a copy.
  if sender notin 0 ..< inboxes.len or
      target < -2 or target == -1 or target >= inboxes.len:
    return 0
  let id = int32(if target < 0: target else: sender)
  for recipient in 0 ..< inboxes.len:
    if target >= 0 and recipient != target:
      continue
    if inboxes[recipient].push(id, text):
      inc result

proc botLimits*(): Limits =
  ## Returns AWM's BASIC bot resource budgets.
  result = defaultLimits()
  result.maxSourceBytes = 256 * 1024
  result.maxInstructions = 5_000_000
  result.maxWorkUnits = 5_000_000

proc submitAction(action: ReplayAction): int32 =
  ## Validates one explicit action without committing it during VM execution.
  if activeVm.selectingClass or activeVm.action.kind != 0 or
    activePlayer.int != activeGame[].actingPlayer():
      return 0
  var trial = activeGame[].copyGameState()
  if not trial.applyAction(action):
    return 0
  activeVm.action = action
  activeVm.action.playerId = activePlayer
  1

proc arrayIndices(value: Value, count: int): seq[int32] =
  ## Reads exact integer picks from the first count cells of a BASIC array.
  let name = activeVm.runtime.getString(value)
  for i in 0 ..< count:
    result.add activeVm.runtime.getArray(name, i.int32)

proc cardPicks(handIndex: int, indices: openArray[int32]): seq[Choice] =
  ## Resolves choice indexes in order, including dependent later targets.
  for index in indices:
    let choices = cardChoices(handIndex, result)
    if index.int notin 0 ..< choices.len:
      return @[]
    result.add choices[index]

proc nextChoices(handIndex: int, arrayName: Value, count: int): seq[Choice] =
  ## Offers the next target after the array's explicit prefix of choices.
  var targets: int
  if handIndex == -1:
    if activeGame[].waitingToss:
      return @[]
    targets = activeGame[].waitingTriggerRules().rules.targetCount()
  else:
    let hand = activeGame[].players[activePlayer].hand
    if handIndex notin 0 ..< hand.len:
      return @[]
    targets = hand[handIndex].targetCount()
  if count notin 0 ..< targets:
    return @[]
  var picks: seq[Choice]
  for index in arrayIndices(arrayName, count):
    let choices =
      if handIndex == -1: activeGame[].triggerChoices(picks)
      else: cardChoices(handIndex, picks)
    if index.int notin 0 ..< choices.len:
      return @[]
    picks.add choices[index]
  if handIndex == -1: activeGame[].triggerChoices(picks)
  else: cardChoices(handIndex, picks)

proc visibleCard(id: string): Card =
  ## Looks up a card by printed name or stable replay ID.
  for card in baseCards:
    if card.name == id or card.cardId() == id:
      return card
  for card in activeGame[].players[activePlayer].hand:
    if card.name == id:
      return card
  for player in activeGame[].players:
    for minion in player.board:
      if minion.card.name == id:
        return minion.card

proc seedBot*(vm: BotVm, seed: int64) =
  ## Seeds private policy randomness without advancing simulation randomness.
  if vm != nil:
    vm.rng = initRand(seed xor (vm.player.int64 + 1))
    vm.rngInitialized = true

proc ensureSeed*(vm: BotVm, seed: int64) =
  ## Seeds a new runtime while preserving randomness consumed during setup.
  if vm != nil and not vm.rngInitialized:
    vm.seedBot(seed)

proc buildBotHost(playerId: int32, policySlot = -1): Host =
  ## Builds explicit actions and public observations for one seat.
  result = initPolicyHost(policySlot)
  for name in DataSlotNames:
    discard result.addData(name)

  # Mailboxes, as in the other Polyworld games.
  let sendChatProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Sends one explicit message from the owning seat.
    activeVm.runtime.withString(args[1], text):
      result = sendChat(int(playerId), int(args[0].asInt), text)
  let pullMailboxProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Pops the next message from the owning seat inbox.
    let inbox = inboxes[int(playerId)]
    if inbox.count == 0:
      result = activeVm.runtime.putString("")
    else:
      result = activeVm.runtime.putString(inbox.messages[inbox.first])
    discard inbox.pop()
  let mailboxIdProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the sender of the last popped message.
    inboxes[int(playerId)].lastId
  let mailboxCountProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the number of waiting messages.
    int32(inboxes[int(playerId)].count)
  let mailboxSelfProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the mailbox owner seat.
    playerId
  let mailboxPlayersProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the number of player mailboxes.
    int32(inboxes.len)
  discard result.addFunction("sendChat", 2, sendChatProc, 256)
  discard result.addFunction("pullMailbox$", 0, pullMailboxProc, 256)
  discard result.addFunction("mailboxId", 0, mailboxIdProc, 4)
  discard result.addFunction("mailboxCount", 0, mailboxCountProc, 4)
  discard result.addFunction("mailboxSelf", 0, mailboxSelfProc, 4)
  discard result.addFunction("mailboxPlayers", 0, mailboxPlayersProc, 4)

  let randomProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a seeded policy integer in zero up to the exclusive bound.
    if args[0] > 0:
      result = activeVm.rng.rand(args[0].int - 1).int32
  discard result.addFunction("random", 1, randomProc, 3)

  let pickClassProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Selects one class before the match is dealt.
    if activeVm.selectingClass and activeVm.selectedClass == -1 and
      args[0] in HeroClass.low.ord.int32 .. HeroClass.high.ord.int32:
        activeVm.selectedClass = args[0].int
        result = 1
  discard result.addFunction("pickClass", 1, pickClassProc, 3)

  let playerClassProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a public player value for any seat.
    result = -1
    if args[0].int in 0 ..< activeGame[].playerCount:
      let state = activeGame[].players[args[0]]
      result = if activeVm.selectingClass: -1 else: state.heroClass.ord.int32
  discard result.addFunction("playerClass", 1, playerClassProc, 3)

  let playerLifeProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a public player value for any seat.
    result = 0
    if args[0].int in 0 ..< activeGame[].playerCount:
      let state = activeGame[].players[args[0]]
      result = state.life.int32
  discard result.addFunction("playerLife", 1, playerLifeProc, 3)

  let playerEnergyProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a public player value for any seat.
    result = 0
    if args[0].int in 0 ..< activeGame[].playerCount:
      let state = activeGame[].players[args[0]]
      result = state.energy.int32
  discard result.addFunction("playerEnergy", 1, playerEnergyProc, 3)

  let playerTotalEnergyProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a public player value for any seat.
    result = 0
    if args[0].int in 0 ..< activeGame[].playerCount:
      let state = activeGame[].players[args[0]]
      result = state.totalEnergy.int32
  discard result.addFunction("playerTotalEnergy", 1, playerTotalEnergyProc, 3)

  let playerHandSizeProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a public player value for any seat.
    result = 0
    if args[0].int in 0 ..< activeGame[].playerCount:
      let state = activeGame[].players[args[0]]
      result = state.hand.len.int32
  discard result.addFunction("playerHandSize", 1, playerHandSizeProc, 3)

  let playerDeckSizeProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a public player value for any seat.
    result = 0
    if args[0].int in 0 ..< activeGame[].playerCount:
      let state = activeGame[].players[args[0]]
      result = state.deck.len.int32
  discard result.addFunction("playerDeckSize", 1, playerDeckSizeProc, 3)

  let playerDeadProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a public player value for any seat.
    result = 0
    if args[0].int in 0 ..< activeGame[].playerCount:
      let state = activeGame[].players[args[0]]
      result = state.dead.int32
  discard result.addFunction("playerDead", 1, playerDeadProc, 3)

  let handIdProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Returns a unique printed name as the hand card's string identity.
    let
      hand = activeGame[].players[activePlayer].hand
      i = args[0].asInt.int
    result = activeVm.runtime.putString(
      if i in 0 ..< hand.len: hand[i].name else: "")
  discard result.addFunction("handId$", 1, handIdProc, 8)

  let boardCardProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Returns a visible board card's string identity by seat and slot.
    var name: string
    let
      player = args[0].asInt.int
      i = args[1].asInt.int
    if player in 0 ..< activeGame[].playerCount:
      let board = activeGame[].players[player].board
      if i in 0 ..< board.len:
        name = board[i].card.name
    result = activeVm.runtime.putString(name)
  discard result.addFunction("boardCard$", 2, boardCardProc, 8)

  let boardPowerProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a public live value from any board slot.
    result = 0
    let
      player = args[0].int
      i = args[1].int
    if player in 0 ..< activeGame[].playerCount:
      let board = activeGame[].players[player].board
      if i in 0 ..< board.len:
        let minion = board[i]
        result = minion.power().int32
  discard result.addFunction("boardPower", 2, boardPowerProc, 3)

  let boardHpProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a public live value from any board slot.
    result = 0
    let
      player = args[0].int
      i = args[1].int
    if player in 0 ..< activeGame[].playerCount:
      let board = activeGame[].players[player].board
      if i in 0 ..< board.len:
        let minion = board[i]
        result = minion.currentToughness.int32
  discard result.addFunction("boardHp", 2, boardHpProc, 3)

  let boardReadyProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a public live value from any board slot.
    result = 0
    let
      player = args[0].int
      i = args[1].int
    if player in 0 ..< activeGame[].playerCount:
      let board = activeGame[].players[player].board
      if i in 0 ..< board.len:
        let minion = board[i]
        result = (minion.card.kind == Minion and minion.canAttack and not minion.hasAttacked).int32
  discard result.addFunction("boardReady", 2, boardReadyProc, 3)

  let boardAttackedProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a public live value from any board slot.
    result = 0
    let
      player = args[0].int
      i = args[1].int
    if player in 0 ..< activeGame[].playerCount:
      let board = activeGame[].players[player].board
      if i in 0 ..< board.len:
        let minion = board[i]
        result = minion.hasAttacked.int32
  discard result.addFunction("boardAttacked", 2, boardAttackedProc, 3)

  let boardKindProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a public live value from any board slot.
    result = -1
    let
      player = args[0].int
      i = args[1].int
    if player in 0 ..< activeGame[].playerCount:
      let board = activeGame[].players[player].board
      if i in 0 ..< board.len:
        let minion = board[i]
        result = minion.card.kind.ord.int32
  discard result.addFunction("boardKind", 2, boardKindProc, 3)

  let boardKeywordProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns whether a visible minion currently has a keyword.
    let
      player = args[0].int
      i = args[1].int
      keyword = args[2].int
    if player in 0 ..< activeGame[].playerCount and
      keyword in Keyword.low.ord .. Keyword.high.ord:
        let board = activeGame[].players[player].board
        if i in 0 ..< board.len:
          result = (Keyword(keyword) in board[i].keywords()).int32
  discard result.addFunction("boardHasKeyword", 3, boardKeywordProc, 3)

  let cardNameProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Returns the public printed text for a string card identity.
    let card = visibleCard(activeVm.runtime.getString(args[0]))
    result = activeVm.runtime.putString(
      if card.name.len > 0: card.name else: "")
  discard result.addFunction("cardName$", 1, cardNameProc, 20)

  let cardRulesProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Returns the public printed text for a string card identity.
    let card = visibleCard(activeVm.runtime.getString(args[0]))
    result = activeVm.runtime.putString(
      if card.name.len > 0: card.ruleText() else: "")
  discard result.addFunction("cardRules$", 1, cardRulesProc, 20)

  let cardKindProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Returns a printed card value for a string identity.
    let card = visibleCard(activeVm.runtime.getString(args[0]))
    if card.name.len == 0:
      return toValue(-1)
    result = toValue(card.kind.ord.int32)
  discard result.addFunction("cardKind", 1, cardKindProc, 8)

  let cardClassProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Returns a printed card value for a string identity.
    let card = visibleCard(activeVm.runtime.getString(args[0]))
    if card.name.len == 0:
      return toValue(-1)
    result = toValue(if card.class.isSome: card.class.get.ord.int32 else: -1)
  discard result.addFunction("cardClass", 1, cardClassProc, 8)

  let cardCostProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Returns a printed card value for a string identity.
    let card = visibleCard(activeVm.runtime.getString(args[0]))
    if card.name.len == 0:
      return toValue(-1)
    result = toValue(card.energyCost.int32)
  discard result.addFunction("cardCost", 1, cardCostProc, 8)

  let cardPowerProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Returns a printed card value for a string identity.
    let card = visibleCard(activeVm.runtime.getString(args[0]))
    if card.name.len == 0:
      return toValue(-1)
    result = toValue(if card.kind == Minion: card.power.int32 else: 0)
  discard result.addFunction("cardPower", 1, cardPowerProc, 8)

  let cardToughnessProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Returns a printed card value for a string identity.
    let card = visibleCard(activeVm.runtime.getString(args[0]))
    if card.name.len == 0:
      return toValue(-1)
    result = toValue(if card.kind == Minion: card.toughness.int32 else: 0)
  discard result.addFunction("cardToughness", 1, cardToughnessProc, 8)

  let cardKeywordProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Returns whether a printed card has the requested keyword.
    let
      card = visibleCard(activeVm.runtime.getString(args[0]))
      keyword = args[1].asInt.int
    result = toValue(0)
    if keyword in Keyword.low.ord .. Keyword.high.ord:
      result = toValue((Keyword(keyword) in card.keywords()).int32)
  discard result.addFunction("cardHasKeyword", 2, cardKeywordProc, 8)

  let handCostProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the printed cost of a hand card.
    let
      i = args[0].int
      hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len: return -1
    hand[i].energyCost.int32
  discard result.addFunction("handCost", 1, handCostProc, 3)

  let handKindProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the kind of a hand card.
    let
      i = args[0].int
      hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len: return -1
    ord(hand[i].kind).int32
  discard result.addFunction("handKind", 1, handKindProc, 3)

  let handPowerProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the printed power of a hand minion.
    let
      i = args[0].int
      hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len: return 0
    if hand[i].kind == Minion: hand[i].power.int32 else: 0
  discard result.addFunction("handPower", 1, handPowerProc, 3)

  let handToughnessProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the printed toughness of a hand minion.
    let
      i = args[0].int
      hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len: return 0
    if hand[i].kind == Minion: hand[i].toughness.int32 else: 0
  discard result.addFunction("handToughness", 1, handToughnessProc, 3)

  let canPlayProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns whether the current player can afford the card.
    if activeGame[].canPlay(args[0].int): 1 else: 0
  discard result.addFunction("canPlay", 1, canPlayProc, 3)

  let needsChoiceProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns whether the hand card requires a choice.
    let
      i = args[0].int
      hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len: return 0
    if hand[i].needsChoice(): 1 else: 0
  discard result.addFunction("needsChoice", 1, needsChoiceProc, 3)

  let choiceCountProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Lists the first target of the chosen hand card.
    cardChoices(args[0].int).len.int32
  discard result.addFunction("choiceCount", 1, choiceCountProc, 8)

  # 0=canceled, 1=noTarget, 2=hero, 3=creature
  let choiceKindProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the kind of a first-target choice.
    let
      choices = cardChoices(args[0].int)
      ci = args[1].int
    if ci < 0 or ci >= choices.len: return 0
    ord(choices[ci].kind).int32
  discard result.addFunction("choiceKind", 2, choiceKindProc, 3)

  let choiceOwnerProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the owner of a first-target choice.
    let
      choices = cardChoices(args[0].int)
      ci = args[1].int
    if ci < 0 or ci >= choices.len: return -1
    choices[ci].owner.int32
  discard result.addFunction("choiceOwner", 2, choiceOwnerProc, 3)

  let choiceIdProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the stable minion ID of a card's first target choice.
    let choices = cardChoices(args[0].int)
    if args[1].int in 0 ..< choices.len and
      choices[args[1]].kind == CreatureChoice:
        result = choices[args[1]].creatureId.int32
  discard result.addFunction("choiceId", 2, choiceIdProc, 8)

  let targetCountProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the target count of a hand card.
    let
      i = args[0].int
      hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len: return 0
    hand[i].targetCount().int32
  discard result.addFunction("targetCount", 1, targetCountProc, 3)

  let helpsTargetProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns whether a target step helps its target.
    let
      i = args[0].int
      hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len: return 0
    if hand[i].helpsTarget(args[1].int): 1 else: 0
  discard result.addFunction("helpsTarget", 2, helpsTargetProc, 3)

  let targetChoiceCountProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns choices for a target step without a prefix.
    stepChoices(args[0].int, args[1].int).len.int32
  discard result.addFunction("targetChoiceCount", 2, targetChoiceCountProc, 8)

  let targetChoiceKindProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the kind of a target-step choice.
    let
      choices = stepChoices(args[0].int, args[1].int)
      ci = args[2].int
    if ci < 0 or ci >= choices.len: return 0
    ord(choices[ci].kind).int32
  discard result.addFunction("targetChoiceKind", 3, targetChoiceKindProc, 8)

  let targetChoiceOwnerProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the owner of a target-step choice.
    let
      choices = stepChoices(args[0].int, args[1].int)
      ci = args[2].int
    if ci < 0 or ci >= choices.len: return -1
    choices[ci].owner.int32
  discard result.addFunction("targetChoiceOwner", 3, targetChoiceOwnerProc, 8)

  # Board queries — own minions
  let selfBoardPowerProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a friendly minion live power.
    let
      board = activeGame[].players[activePlayer].board
      i = args[0].int
    if i < 0 or i >= board.len: return 0
    board[i].power.int32
  discard result.addFunction("selfBoardPower", 1, selfBoardPowerProc, 3)

  let selfBoardHpProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a friendly permanent remaining toughness.
    let
      board = activeGame[].players[activePlayer].board
      i = args[0].int
    if i < 0 or i >= board.len: return 0
    board[i].currentToughness.int32
  discard result.addFunction("selfBoardHp", 1, selfBoardHpProc, 3)

  # Board queries — enemy minions
  let enemyBoardPowerProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the next living enemy minion live power.
    let
      board = activeGame[].players[activeEnemy].board
      i = args[0].int
    if i < 0 or i >= board.len: return 0
    board[i].power.int32
  discard result.addFunction("enemyBoardPower", 1, enemyBoardPowerProc, 3)

  let enemyBoardHpProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the next living enemy remaining toughness.
    let
      board = activeGame[].players[activeEnemy].board
      i = args[0].int
    if i < 0 or i >= board.len: return 0
    board[i].currentToughness.int32
  discard result.addFunction("enemyBoardHp", 1, enemyBoardHpProc, 3)

  let handNameProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Returns the printed name of a card in the acting player's hand.
    let
      i = args[0].asInt.int
      hand = activeGame[].players[activePlayer].hand
    result = activeVm.runtime.putString(
      if i in 0 ..< hand.len: hand[i].name else: "")
  discard result.addFunction("handName$", 1, handNameProc, 8)

  let boardCountProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a visible player's board size.
    let player = args[0].int
    if player in 0 ..< activeGame[].playerCount:
      result = activeGame[].players[player].board.len.int32
  discard result.addFunction("boardCount", 1, boardCountProc, 3)

  let boardIdProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a stable permanent instance ID from a visible board slot.
    let
      player = args[0].int
      i = args[1].int
    if player in 0 ..< activeGame[].playerCount:
      let board = activeGame[].players[player].board
      if i in 0 ..< board.len:
        result = board[i].id.int32
  discard result.addFunction("boardId", 2, boardIdProc, 3)

  let boardNameProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Returns the printed name of a visible board card.
    let
      player = args[0].asInt.int
      i = args[1].asInt.int
    var name: string
    if player in 0 ..< activeGame[].playerCount:
      let board = activeGame[].players[player].board
      if i in 0 ..< board.len:
        name = board[i].card.name
    result = activeVm.runtime.putString(name)
  discard result.addFunction("boardName$", 2, boardNameProc, 8)

  let attackCountProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the attacker's currently legal target count.
    activeGame[].attackTargets(args[0].int).len.int32
  discard result.addFunction("attackChoiceCount", 1, attackCountProc, 8)

  let attackKindProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the kind of one legal attack target.
    let choices = activeGame[].attackTargets(args[0].int)
    if args[1].int in 0 ..< choices.len:
      result = choices[args[1]].kind.ord.int32
  discard result.addFunction("attackChoiceKind", 2, attackKindProc, 8)

  let attackOwnerProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the owner of one legal attack target.
    let choices = activeGame[].attackTargets(args[0].int)
    result = -1
    if args[1].int in 0 ..< choices.len:
      result = choices[args[1]].owner.int32
  discard result.addFunction("attackChoiceOwner", 2, attackOwnerProc, 8)

  let attackIdProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns the stable minion ID of one legal attack target.
    let choices = activeGame[].attackTargets(args[0].int)
    if args[1].int in 0 ..< choices.len and
      choices[args[1]].kind == CreatureChoice:
        result = choices[args[1]].creatureId.int32
  discard result.addFunction("attackChoiceId", 2, attackIdProc, 8)

  let attackProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Selects one attack with an explicit attacker and target.
    let choices = activeGame[].attackTargets(args[0].int)
    if args[1].int notin 0 ..< choices.len:
      return 0
    submitAction(ReplayAction(kind: ActionAttack, attacker: args[0],
      choices: @[choices[args[1]].toReplay]))
  discard result.addFunction("attack", 2, attackProc, 100)

  let endTurnProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Selects a turn end without making any attacks.
    submitAction(ReplayAction(kind: ActionEndTurn))
  discard result.addFunction("endTurn", 0, endTurnProc, 100)

  let playCardProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Selects a card with no targets required by its rules.
    let i = args[0].int
    if not activeGame[].canPlay(i):
      return 0
    if activeGame[].players[activePlayer].hand[i].needsChoice():
      return 0
    submitAction(ReplayAction(kind: ActionPlayCard, handIndex: args[0],
      choices: @[NoTarget.toReplay]))
  discard result.addFunction("playCard", 1, playCardProc, 100)

  let playCardChoiceProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Selects a card with one explicitly chosen target.
    let i = args[0].int
    if not activeGame[].canPlay(i):
      return 0
    let picks = cardPicks(i, @[args[1]])
    if picks.len != 1:
      return 0
    submitAction(ReplayAction(kind: ActionPlayCard, handIndex: args[0],
      choices: picks.toReplay))
  discard result.addFunction("playCardChoice", 2, playCardChoiceProc, 100)

  let playCardChoicesProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Selects a two-target card, resolving its targets in order.
    let i = args[0].int
    if not activeGame[].canPlay(i) or
      activeGame[].players[activePlayer].hand[i].targetCount() != 2:
        return 0
    let picks = cardPicks(i, @[args[1], args[2]])
    if picks.len != 2:
      return 0
    submitAction(ReplayAction(kind: ActionPlayCard, handIndex: args[0],
      choices: picks.toReplay))
  discard result.addFunction("playCardChoices", 3, playCardChoicesProc, 100)

  let playCardTargetsProc: NumericHostProc =
      proc(args: openArray[Value]): Value =
    ## Selects all targets of a card using the named BASIC index array.
    let i = args[0].asInt.int
    if not activeGame[].canPlay(i):
      return toValue(0)
    let
      count = activeGame[].players[activePlayer].hand[i].targetCount()
      picks = cardPicks(i, arrayIndices(args[1], count))
    if picks.len != count:
      return toValue(0)
    toValue(submitAction(ReplayAction(kind: ActionPlayCard,
      handIndex: i.int32, choices: picks.toReplay)))
  discard result.addFunction("playCardTargets", 2, playCardTargetsProc, 100)

  let nextCountProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Returns targets after the chosen prefix; hand index -1 is a trigger.
    toValue(nextChoices(args[0].asInt.int, args[1], args[2].asInt.int).len)
  discard result.addFunction("nextChoiceCount", 3, nextCountProc, 8)

  let nextKindProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Returns a target kind after the explicit prefix of earlier picks.
    let
      choices = nextChoices(args[0].asInt.int, args[1], args[2].asInt.int)
      i = args[3].asInt.int
    toValue(if i in 0 ..< choices.len: choices[i].kind.ord else: 0)
  discard result.addFunction("nextChoiceKind", 4, nextKindProc, 8)

  let nextOwnerProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Returns a target owner after the explicit prefix of earlier picks.
    let
      choices = nextChoices(args[0].asInt.int, args[1], args[2].asInt.int)
      i = args[3].asInt.int
    toValue(if i in 0 ..< choices.len: choices[i].owner else: -1)
  discard result.addFunction("nextChoiceOwner", 4, nextOwnerProc, 8)

  let nextIdProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Returns a minion ID after the explicit prefix of earlier picks.
    let
      choices = nextChoices(args[0].asInt.int, args[1], args[2].asInt.int)
      i = args[3].asInt.int
    var id = 0
    if i in 0 ..< choices.len and choices[i].kind == CreatureChoice:
      id = choices[i].creatureId
    toValue(id)
  discard result.addFunction("nextChoiceId", 4, nextIdProc, 8)

  let triggerCountProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns legal targets for a waiting trigger's requested step.
    triggerStepChoices(args[0].int).len.int32
  discard result.addFunction("triggerChoiceCount", 1, triggerCountProc, 8)

  let triggerKindProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a waiting trigger target's kind.
    let choices = triggerStepChoices(args[0].int)
    if args[1].int in 0 ..< choices.len:
      result = choices[args[1]].kind.ord.int32
  discard result.addFunction("triggerChoiceKind", 2, triggerKindProc, 8)

  let triggerOwnerProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a waiting trigger target's owner.
    let choices = triggerStepChoices(args[0].int)
    result = -1
    if args[1].int in 0 ..< choices.len:
      result = choices[args[1]].owner.int32
  discard result.addFunction("triggerChoiceOwner", 2, triggerOwnerProc, 8)

  let triggerIdProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns a waiting trigger target's stable minion ID.
    let choices = triggerStepChoices(args[0].int)
    if args[1].int in 0 ..< choices.len and
      choices[args[1]].kind == CreatureChoice:
        result = choices[args[1]].creatureId.int32
  discard result.addFunction("triggerChoiceId", 2, triggerIdProc, 8)

  let triggerHelpsProc: HostProc = proc(args: openArray[int32]): int32 =
    ## Returns whether the trigger's requested target should be friendly.
    if activeGame[].waitingTriggerRules().rules.helpsTarget(args[0].int):
      result = 1
  discard result.addFunction("triggerHelpsTarget", 1, triggerHelpsProc, 3)

  let resolveTriggerProc: NumericHostProc =
      proc(args: openArray[Value]): Value =
    ## Selects the waiting trigger's targets from a BASIC index array.
    if not activeGame[].waitingTrigger or activeGame[].waitingToss:
      return toValue(0)
    let
      count = activeGame[].waitingTriggerRules().rules.targetCount()
      indices = arrayIndices(args[0], count)
    var picks: seq[Choice]
    for index in indices:
      let choices = activeGame[].triggerChoices(picks)
      if index.int notin 0 ..< choices.len:
        return toValue(0)
      picks.add choices[index]
    toValue(submitAction(ReplayAction(kind: ActionResolveTrigger,
      choices: picks.toReplay)))
  discard result.addFunction("resolveTrigger", 1, resolveTriggerProc, 100)

  let discardCardsProc: NumericHostProc =
      proc(args: openArray[Value]): Value =
    ## Selects exactly the required discard cards from a BASIC index array.
    if not activeGame[].waitingToss:
      return toValue(0)
    toValue(submitAction(ReplayAction(kind: ActionToss,
      indices: arrayIndices(args[0], activeGame[].pendingToss.count))))
  discard result.addFunction("discardCards", 1, discardCardsProc, 100)

var dataIds: array[BotDataSlot, int32]

proc bindDataIds(program: Program) =
  ## Binds the stable host data schema to a compiled program.
  for slot, name in DataSlotNames:
    dataIds[slot] = program.hostDataIndex(name)

proc botSchema*(): Host =
  ## The host a script is compiled against; every seat's matches it.
  buildBotHost(0)

proc resetInboxes*(seats: int) =
  ## Fresh, empty mailboxes for a match with `seats` players.
  inboxes.setLen(0)
  for _ in 0 ..< seats:
    inboxes.add newMailbox()

proc newBotVm*(program: Program, player: int32,
    output: PrintProc = nil): BotVm =
  ## A seat's bot from a script compiled against `botSchema`.
  bindDataIds(program)
  BotVm(
    runtime: initRuntime(program, buildBotHost(player, int(player)), botLimits()),
    player: player.int, output: output, playedHand: -1)

proc loadBot*(source: string, player: int32): BotVm =
  ## Compiles a script and initializes its seat-owned runtime.
  newBotVm(compile(source, botSchema(), botLimits()), player)

proc loadBots*(sources: openArray[string]): seq[BotVm] =
  ## One bot per seat; an empty source leaves that seat without one.
  result.setLen(sources.len)
  resetInboxes(sources.len)
  var bound = false
  for player in 0'i32 ..< sources.len.int32:
    if sources[player].len == 0:
      continue
    let
      limits = botLimits()
      schema = buildBotHost(0)
    try:
      let program = compile(source = sources[player], host = schema,
        limits = limits)
      if not bound:
        bindDataIds(program)
        bound = true
      result[player] = BotVm(
        player: player.int, runtime: initRuntime(program, buildBotHost(player, int(player)), limits))
    except BasicError as error:
      # A script that does not compile keeps its seat and reports failure.
      result[player] = BotVm(player: player.int, failed: true, lastError: error.msg)

type
  BotDecision* = enum
    BotPlayedCard, BotAttacked, BotResolvedTrigger, BotTossed,
    BotEndedTurn, BotFailed

proc runDecision*(vm: BotVm, game: var GameState,
    apply = true): BotDecision =
  ## Selects one action, optionally leaving its application to presentation.
  vm.action = ReplayAction()
  if not vm.rngInitialized:
    vm.seedBot(0)
  if vm.failed:
    return BotFailed
  let player = game.actingPlayer().int32
  if vm.player != player.int:
    vm.lastError = "BASIC VM does not own the acting seat"
    return BotFailed
  # With more than two players, the script's "enemy" is the next living one.
  let enemy = game.nextPlayer(player).int32
  activeGame = addr game
  activePlayer = player
  activeEnemy = enemy
  activeVm = vm
  vm.playedHand = -1
  vm.playedChoices.setLen(0)

  vm.lastError.setLen(0)
  try:
    vm.runtime.restart()
    let ids = dataIds
    vm.runtime.setData(ids[DataSelectingClass], 0)
    vm.runtime.setData(ids[DataSelfClass], game.players[player].heroClass.ord.int32)
    vm.runtime.setData(ids[DataEnemyClass], game.players[enemy].heroClass.ord.int32)
    vm.runtime.setData(ids[DataSelfPlayer], player)
    vm.runtime.setData(ids[DataEnemyPlayer], enemy)
    vm.runtime.setData(ids[DataTurnNumber], game.turnNumber.int32)
    vm.runtime.setData(ids[DataSelfLife], game.players[player].life.int32)
    vm.runtime.setData(ids[DataEnemyLife], game.players[enemy].life.int32)
    vm.runtime.setData(ids[DataEnergy], game.players[player].energy.int32)
    vm.runtime.setData(ids[DataTotalEnergy], game.players[player].totalEnergy.int32)
    vm.runtime.setData(ids[DataHandSize], game.players[player].hand.len.int32)
    vm.runtime.setData(ids[DataSelfBoardSize], game.players[player].board.len.int32)
    vm.runtime.setData(ids[DataEnemyBoardSize], game.players[enemy].board.len.int32)
    vm.runtime.setData(ids[DataSelfDeckSize], game.players[player].deck.len.int32)
    vm.runtime.setData(ids[DataEnemyDeckSize], game.players[enemy].deck.len.int32)
    vm.runtime.setData(ids[DataPlayerCount], game.playerCount.int32)
    vm.runtime.setData(ids[DataCurrentPlayer], game.currentPlayer.int32)
    vm.runtime.setData(ids[DataTossCount], game.pendingToss.count.int32)
    vm.runtime.setData(ids[DataTriggerTargets],
      game.waitingTriggerRules().rules.targetCount().int32)

    discard vm.runtime.run(vm.output)
  except BasicError as error:
    # The caller decides whether to stop or report the failed decision.
    vm.lastError = error.msg
    vm.action = ReplayAction()
    return BotFailed
  finally:
    activeGame = nil
    activeVm = nil
  if vm.action.kind == 0:
    vm.lastError = "BASIC decision selected no action; call endTurn() " &
      "or answer the pending choice"
    return BotFailed
  if apply and not game.applyAction(vm.action):
    vm.lastError = "BASIC selected action is no longer legal"
    vm.action = ReplayAction()
    return BotFailed
  case vm.action.kind
  of ActionPlayCard:
    vm.playedHand = vm.action.handIndex.int
    vm.playedChoices = vm.action.choices.toChoices
    BotPlayedCard
  of ActionAttack: BotAttacked
  of ActionResolveTrigger: BotResolvedTrigger
  of ActionToss: BotTossed
  of ActionEndTurn: BotEndedTurn
  else: BotFailed

proc chooseClass*(vm: BotVm, seats: int, seed = 0'i64): HeroClass =
  ## Runs the script's pre-match phase before cards are dealt.
  if vm == nil or vm.failed:
    raise newException(BasicError,
      if vm == nil: "Cannot select class for a missing bot"
      else: vm.lastError)
  assert seats >= 2 and vm.player in 0 ..< seats
  var setup = GameState(players: newSeq[PlayerState](seats), winner: -1)
  vm.runtime.reset()
  vm.seedBot(seed)
  vm.selectingClass = true
  vm.selectedClass = -1
  vm.action = ReplayAction()
  activeGame = addr setup
  activePlayer = vm.player.int32
  activeEnemy = ((vm.player + 1) mod seats).int32
  activeVm = vm
  let ids = dataIds
  for slot in BotDataSlot:
    vm.runtime.setData(ids[slot], 0)
  vm.runtime.setData(ids[DataSelectingClass], 1)
  vm.runtime.setData(ids[DataSelfClass], -1)
  vm.runtime.setData(ids[DataEnemyClass], -1)
  vm.runtime.setData(ids[DataSelfPlayer], activePlayer)
  vm.runtime.setData(ids[DataEnemyPlayer], activeEnemy)
  vm.runtime.setData(ids[DataPlayerCount], seats.int32)
  vm.runtime.setData(ids[DataCurrentPlayer], -1)
  try:
    discard vm.runtime.run(vm.output)
    if vm.selectedClass == -1:
      raise newException(BasicError,
        "BASIC setup selected no class; call pickClass(0, 1 or 2)")
    result = HeroClass(vm.selectedClass)
  except BasicError as error:
    vm.lastError = error.msg
    raise
  finally:
    vm.selectingClass = false
    activeGame = nil
    activeVm = nil

proc chooseBotClasses*(bots: openArray[BotVm],
    seed = 0'i64): seq[HeroClass] =
  ## Collects each script's explicit class before starting a bot match.
  for bot in bots:
    result.add bot.chooseClass(bots.len, seed)
