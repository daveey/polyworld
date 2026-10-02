## BASIC VM bot integration for AWM, following the Polyworld convention.
## Bots are .bas scripts compiled once and executed each decision point.
## Each invocation plays at most one card; the game loop calls repeatedly
## until the bot ends its turn.
import bassy
import polyworld/policyhosts
import polyworld/mailboxes
import sim
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

  BotVm* = ref object
    runtime*: Runtime
    failed*: bool  ## The script didn't compile: every decision fails.
    lastError*: string  ## Why the last decision (or the compile) failed.
    output*: PrintProc  ## Where the script's PRINT goes (nil: nowhere).
    playedHand*: int  ## The hand card the last decision played, or -1.
    playedChoices*: seq[Choice]  ## Its targets, one per step, in order.

const
  DataSlotNames: array[BotDataSlot, string] = [
    "selfPlayer", "enemyPlayer", "turnNumber",
    "selfLife", "enemyLife",
    "energy", "totalEnergy",
    "handSize",
    "selfBoardSize", "enemyBoardSize",
    "selfDeckSize", "enemyDeckSize"
  ]

var
  activeGame: ptr GameState
  activePlayer: int32
  activeEnemy: int32  ## The next living player: the bot's one enemy.
  activeVm: BotVm
  actionPlayed: bool
  playedHandIndex: int
  playedChoices: seq[Choice]
  inboxes*: seq[Mailbox]
    ## One inbox per seat, replaced when bots are loaded for a match.

proc stepChoices(handIndex, step: int): seq[Choice] =
  ## Legal choices for a hand card's `step`th target. Targets don't depend on
  ## earlier picks, so placeholders stand in for them.
  activeGame[].availableChoices(handIndex, newSeq[Choice](max(0, step)))

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

proc buildBotHost(playerId: int32, policySlot = -1): Host =
  result = initPolicyHost(policySlot)
  for name in DataSlotNames:
    discard result.addData(name)

  # Mailboxes, as in the other Polyworld games.
  let sendChatProc: NumericHostProc = proc(args: openArray[Value]): Value =
    activeVm.runtime.withString(args[1], text):
      result = sendChat(int(playerId), int(args[0].asInt), text)
  let pullMailboxProc: NumericHostProc = proc(args: openArray[Value]): Value =
    let inbox = inboxes[int(playerId)]
    if inbox.count == 0:
      result = activeVm.runtime.putString("")
    else:
      result = activeVm.runtime.putString(inbox.messages[inbox.first])
    discard inbox.pop()
  let mailboxIdProc: HostProc = proc(args: openArray[int32]): int32 =
    inboxes[int(playerId)].lastId
  let mailboxCountProc: HostProc = proc(args: openArray[int32]): int32 =
    int32(inboxes[int(playerId)].count)
  let mailboxSelfProc: HostProc = proc(args: openArray[int32]): int32 =
    playerId
  let mailboxPlayersProc: HostProc = proc(args: openArray[int32]): int32 =
    int32(inboxes.len)
  discard result.addFunction("sendChat", 2, sendChatProc, 256)
  discard result.addFunction("pullMailbox$", 0, pullMailboxProc, 256)
  discard result.addFunction("mailboxId", 0, mailboxIdProc, 4)
  discard result.addFunction("mailboxCount", 0, mailboxCountProc, 4)
  discard result.addFunction("mailboxSelf", 0, mailboxSelfProc, 4)
  discard result.addFunction("mailboxPlayers", 0, mailboxPlayersProc, 4)

  # Hand card queries
  let handCostProc: HostProc = proc(args: openArray[int32]): int32 =
    let i = args[0].int
    let hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len: return -1
    hand[i].energyCost.int32
  discard result.addFunction("handCost", 1, handCostProc, 3)

  let handKindProc: HostProc = proc(args: openArray[int32]): int32 =
    let i = args[0].int
    let hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len: return -1
    ord(hand[i].kind).int32
  discard result.addFunction("handKind", 1, handKindProc, 3)

  let handPowerProc: HostProc = proc(args: openArray[int32]): int32 =
    let i = args[0].int
    let hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len: return 0
    if hand[i].kind == Minion: hand[i].power.int32 else: 0
  discard result.addFunction("handPower", 1, handPowerProc, 3)

  let handToughnessProc: HostProc = proc(args: openArray[int32]): int32 =
    let i = args[0].int
    let hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len: return 0
    if hand[i].kind == Minion: hand[i].toughness.int32 else: 0
  discard result.addFunction("handToughness", 1, handToughnessProc, 3)

  let canPlayProc: HostProc = proc(args: openArray[int32]): int32 =
    if activeGame[].canPlay(args[0].int): 1 else: 0
  discard result.addFunction("canPlay", 1, canPlayProc, 3)

  let needsChoiceProc: HostProc = proc(args: openArray[int32]): int32 =
    let i = args[0].int
    let hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len: return 0
    if hand[i].needsChoice(): 1 else: 0
  discard result.addFunction("needsChoice", 1, needsChoiceProc, 3)

  # Choice queries
  let choiceCountProc: HostProc = proc(args: openArray[int32]): int32 =
    activeGame[].availableChoices(args[0].int).len.int32
  discard result.addFunction("choiceCount", 1, choiceCountProc, 8)

  # 0=canceled, 1=noTarget, 2=hero, 3=creature
  let choiceKindProc: HostProc = proc(args: openArray[int32]): int32 =
    let choices = activeGame[].availableChoices(args[0].int)
    let ci = args[1].int
    if ci < 0 or ci >= choices.len: return 0
    ord(choices[ci].kind).int32
  discard result.addFunction("choiceKind", 2, choiceKindProc, 3)

  let choiceOwnerProc: HostProc = proc(args: openArray[int32]): int32 =
    let choices = activeGame[].availableChoices(args[0].int)
    let ci = args[1].int
    if ci < 0 or ci >= choices.len: return -1
    choices[ci].owner.int32
  discard result.addFunction("choiceOwner", 2, choiceOwnerProc, 3)

  # Multi-target queries. The choice queries above cover the first target.
  let targetCountProc: HostProc = proc(args: openArray[int32]): int32 =
    let i = args[0].int
    let hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len: return 0
    hand[i].targetCount().int32
  discard result.addFunction("targetCount", 1, targetCountProc, 3)

  let helpsTargetProc: HostProc = proc(args: openArray[int32]): int32 =
    let i = args[0].int
    let hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len: return 0
    if hand[i].helpsTarget(args[1].int): 1 else: 0
  discard result.addFunction("helpsTarget", 2, helpsTargetProc, 3)

  let targetChoiceCountProc: HostProc = proc(args: openArray[int32]): int32 =
    stepChoices(args[0].int, args[1].int).len.int32
  discard result.addFunction("targetChoiceCount", 2, targetChoiceCountProc, 8)

  let targetChoiceKindProc: HostProc = proc(args: openArray[int32]): int32 =
    let choices = stepChoices(args[0].int, args[1].int)
    let ci = args[2].int
    if ci < 0 or ci >= choices.len: return 0
    ord(choices[ci].kind).int32
  discard result.addFunction("targetChoiceKind", 3, targetChoiceKindProc, 8)

  let targetChoiceOwnerProc: HostProc = proc(args: openArray[int32]): int32 =
    let choices = stepChoices(args[0].int, args[1].int)
    let ci = args[2].int
    if ci < 0 or ci >= choices.len: return -1
    choices[ci].owner.int32
  discard result.addFunction("targetChoiceOwner", 3, targetChoiceOwnerProc, 8)

  # Board queries — own minions
  let selfBoardPowerProc: HostProc = proc(args: openArray[int32]): int32 =
    let board = activeGame[].players[activePlayer].board
    let i = args[0].int
    if i < 0 or i >= board.len: return 0
    board[i].power.int32
  discard result.addFunction("selfBoardPower", 1, selfBoardPowerProc, 3)

  let selfBoardHpProc: HostProc = proc(args: openArray[int32]): int32 =
    let board = activeGame[].players[activePlayer].board
    let i = args[0].int
    if i < 0 or i >= board.len: return 0
    board[i].currentToughness.int32
  discard result.addFunction("selfBoardHp", 1, selfBoardHpProc, 3)

  # Board queries — enemy minions
  let enemyBoardPowerProc: HostProc = proc(args: openArray[int32]): int32 =
    let board = activeGame[].players[activeEnemy].board
    let i = args[0].int
    if i < 0 or i >= board.len: return 0
    board[i].power.int32
  discard result.addFunction("enemyBoardPower", 1, enemyBoardPowerProc, 3)

  let enemyBoardHpProc: HostProc = proc(args: openArray[int32]): int32 =
    let board = activeGame[].players[activeEnemy].board
    let i = args[0].int
    if i < 0 or i >= board.len: return 0
    board[i].currentToughness.int32
  discard result.addFunction("enemyBoardHp", 1, enemyBoardHpProc, 3)

  # Commands — play a card (at most once per invocation)
  let playCardProc: HostProc = proc(args: openArray[int32]): int32 =
    if actionPlayed: return 0
    let i = args[0].int
    if not activeGame[].canPlay(i): return 0
    let hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len: return 0
    if hand[i].needsChoice(): return 0
    if not activeGame[].playCard(i, NoTarget): return 0
    actionPlayed = true
    playedHandIndex = i
    playedChoices = @[NoTarget]
    1
  discard result.addFunction("playCard", 1, playCardProc, 100)

  let playCardChoiceProc: HostProc = proc(args: openArray[int32]): int32 =
    if actionPlayed: return 0
    let i = args[0].int
    if not activeGame[].canPlay(i): return 0
    let hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len: return 0
    let choices = activeGame[].availableChoices(i)
    let ci = args[1].int
    if ci < 0 or ci >= choices.len: return 0
    if not activeGame[].playCard(i, choices[ci]): return 0
    actionPlayed = true
    playedHandIndex = i
    playedChoices = @[choices[ci]]
    1
  discard result.addFunction("playCardChoice", 2, playCardChoiceProc, 100)

  # Two-target cards (Duel): a choice index for each target, in order.
  let playCardChoicesProc: HostProc = proc(args: openArray[int32]): int32 =
    if actionPlayed: return 0
    let i = args[0].int
    if not activeGame[].canPlay(i): return 0
    let hand = activeGame[].players[activePlayer].hand
    if i < 0 or i >= hand.len or hand[i].targetCount() != 2: return 0
    var picks: seq[Choice]
    for step in 0 .. 1:
      let choices = stepChoices(i, step)
      let ci = args[step + 1].int
      if ci < 0 or ci >= choices.len: return 0
      picks.add choices[ci]
    if not activeGame[].playCard(i, picks): return 0
    actionPlayed = true
    playedHandIndex = i
    playedChoices = picks
    1
  discard result.addFunction("playCardChoices", 3, playCardChoicesProc, 100)

var dataIds: array[BotDataSlot, int32]

proc bindDataIds(program: Program) =
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
  BotVm(runtime: initRuntime(program, buildBotHost(player, int(player)), botLimits()),
    output: output, playedHand: -1)

proc loadBot*(source: string, player: int32): BotVm =
  newBotVm(compile(source, botSchema(), botLimits()), player)

proc loadBots*(sources: openArray[string]): seq[BotVm] =
  ## One bot per seat; an empty source leaves that seat without one.
  result.setLen(sources.len)
  resetInboxes(sources.len)
  var bound = false
  for player in 0'i32 ..< sources.len.int32:
    if sources[player].len == 0:
      continue
    let limits = botLimits()
    let schema = buildBotHost(0)
    try:
      let program = compile(source = sources[player], host = schema,
        limits = limits)
      if not bound:
        bindDataIds(program)
        bound = true
      result[player] = BotVm(
        runtime: initRuntime(program, buildBotHost(player, int(player)), limits))
    except BasicError as error:
      # A script that doesn't compile still holds its seat: it passes every
      # turn instead of stopping the match.
      result[player] = BotVm(failed: true, lastError: error.msg)

type
  BotDecision* = enum
    BotPlayedCard, BotEndedTurn, BotFailed

proc runDecision*(vm: BotVm, game: var GameState): BotDecision =
  if vm.failed:
    return BotFailed
  let player = game.currentPlayer.int32
  # With more than two players, the script's "enemy" is the next living one.
  let enemy = game.nextPlayer(player).int32
  activeGame = addr game
  activePlayer = player
  activeEnemy = enemy
  activeVm = vm
  actionPlayed = false
  playedHandIndex = -1
  playedChoices.setLen(0)
  vm.playedHand = -1
  vm.playedChoices.setLen(0)

  vm.runtime.restart()
  let ids = dataIds
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

  try:
    discard vm.runtime.run(vm.output)
  except BasicError as error:
    # One bad decision doesn't retire the script: it runs again next time.
    vm.lastError = error.msg
    activeGame = nil
    activeVm = nil
    return BotFailed

  activeGame = nil
  activeVm = nil
  if actionPlayed:
    vm.playedHand = playedHandIndex
    vm.playedChoices = playedChoices
    BotPlayedCard
  else: BotEndedTurn
