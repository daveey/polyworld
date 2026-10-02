## BASIC VM bot integration for AWM, following the Polyworld convention.
## Bots are .bas scripts compiled once and executed each decision point.
## Each invocation plays at most one card; the game loop calls repeatedly
## until the bot ends its turn.
import bassy
import polyworld/neural
import awmsim

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
    failed*: bool
    lastError*: string
    played: bool

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
  actionPlayed: bool
  playedHandIndex: int
  playedChoice: Choice

proc stepChoices(handIndex, step: int): seq[Choice] =
  ## Legal choices for a hand card's `step`th target. Targets don't depend on
  ## earlier picks, so placeholders stand in for them.
  activeGame[].availableChoices(handIndex, newSeq[Choice](max(0, step)))

proc botLimits(): Limits =
  result = defaultLimits()
  result.maxSourceBytes = 256 * 1024
  result.maxInstructions = 500_000
  result.maxWorkUnits = 500_000

proc buildBotHost(playerId: int32): Host =
  result = initHost()
  result.addNeuralFunctions()
  for name in DataSlotNames:
    discard result.addData(name)

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
    let enemy = (activePlayer + 1) mod PlayerCount
    let board = activeGame[].players[enemy].board
    let i = args[0].int
    if i < 0 or i >= board.len: return 0
    board[i].power.int32
  discard result.addFunction("enemyBoardPower", 1, enemyBoardPowerProc, 3)

  let enemyBoardHpProc: HostProc = proc(args: openArray[int32]): int32 =
    let enemy = (activePlayer + 1) mod PlayerCount
    let board = activeGame[].players[enemy].board
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
    playedChoice = NoTarget
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
    playedChoice = choices[ci]
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
    playedChoice = picks[0]
    1
  discard result.addFunction("playCardChoices", 3, playCardChoicesProc, 100)

var dataIds: array[BotDataSlot, int32]

proc bindDataIds(program: Program) =
  for slot, name in DataSlotNames:
    dataIds[slot] = program.hostDataIndex(name)

proc loadBot*(source: string, player: int32): BotVm =
  let limits = botLimits()
  let schema = buildBotHost(0)
  let program = compile(source, schema, limits)
  bindDataIds(program)
  BotVm(runtime: initRuntime(program, buildBotHost(player), limits))

proc loadBots*(sources: array[PlayerCount, string]): array[PlayerCount, BotVm] =
  var bound = false
  for player in 0'i32 ..< PlayerCount:
    if sources[player].len == 0:
      continue
    let limits = botLimits()
    let schema = buildBotHost(0)
    let program = compile(source = sources[player], host = schema, limits = limits)
    if not bound:
      bindDataIds(program)
      bound = true
    result[player] = BotVm(
      runtime: initRuntime(program, buildBotHost(player), limits))

type
  BotDecision* = enum
    BotPlayedCard, BotEndedTurn, BotFailed

proc runDecision*(vm: BotVm, game: var GameState): BotDecision =
  if vm.failed:
    return BotFailed
  let player = game.currentPlayer.int32
  let enemy = ((player + 1) mod PlayerCount).int32
  activeGame = addr game
  activePlayer = player
  actionPlayed = false
  playedHandIndex = -1
  playedChoice = Canceled

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
    discard vm.runtime.run()
  except BasicError as error:
    vm.failed = true
    vm.lastError = error.msg
    activeGame = nil
    return BotFailed

  activeGame = nil
  if actionPlayed: BotPlayedCard else: BotEndedTurn
