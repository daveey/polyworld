import
  std/[options, sequtils, strutils],
  ../src/core/[bots, match, replays, sim]

proc ready(owner, id: int, card: Card): MinionState =
  ## Creates an existing minion ready to attack in a regression fixture.
  MinionState(owner: owner, id: id, card: card,
    currentToughness: (if card.kind == Minion: card.toughness else: 0),
    canAttack: true)

proc scripted(source: string, seats = 2): BotMatch =
  ## Starts a match with the same script in every seat.
  initBotMatch(newSeqWith(seats, Mage), 7,
    loadBots(newSeqWith(seats, source)), 28_800)

echo "Ending a turn never selects attacks"
block:
  var played = scripted("endTurn()")
  let player = played.game.currentPlayer
  let enemy = played.game.nextPlayer(player)
  played.game.players[player].board = @[ready(player, 1,
    baseCardNamed("Primordial"))]
  played.game.nextMinionId = 2
  var human = played.game.copyGameState()
  human.finishTurn()
  doAssert played.step()
  doAssert played.game.stateHash == human.stateHash
  doAssert played.game.players[enemy].life == StartingLife

echo "An empty decision does not end the turn or choose a fallback"
block:
  var played = scripted("END")
  let before = played.game.stateHash
  doAssert not played.step()
  doAssert played.outcome == MatchFailed
  doAssert played.tick == 0
  doAssert played.game.stateHash == before
  doAssert played.bots[played.game.currentPlayer].lastError.contains("no action")

echo "The designer's attack, bounce, replay order matches human actions"
block:
  var played = scripted("""
if phase = 0 then
  primordial = boardId(selfPlayer, 0)
  j = 0
  while j < attackChoiceCount(primordial)
    if attackChoiceKind(primordial, j) = 2 then
      if attackChoiceOwner(primordial, j) = enemyPlayer then
        if attack(primordial, j) then
          phase = 1
          end
        end if
      end if
    end if
    j = j + 1
  wend
end if
if phase = 1 then
  i = 0
  while i < handSize
    if handName$(i) = "Bouncer" then
      j = 0
      while j < choiceCount(i)
        if choiceId(i, j) = primordial then
          if playCardChoice(i, j) then
            phase = 2
            end
          end if
        end if
        j = j + 1
      wend
    end if
    i = i + 1
  wend
end if
if phase = 2 then
  i = 0
  while i < handSize
    if handName$(i) = "Primordial" then
      if playCard(i) then
        phase = 3
        end
      end if
    end if
    i = i + 1
  wend
end if
endTurn()
""")
  let player = played.game.currentPlayer
  let enemy = played.game.nextPlayer(player)
  played.game.turnNumber = 17
  played.game.players[player].energy = 9
  played.game.players[player].totalEnergy = 9
  played.game.players[player].hand = @[baseCardNamed("Bouncer")]
  played.game.players[player].board = @[ready(player, 1,
    baseCardNamed("Primordial"))]
  played.game.players[enemy].board = @[ready(enemy, 2,
    baseCardNamed("Bear"))]
  played.game.nextMinionId = 3
  var human = played.game.copyGameState()
  doAssert human.attack(1, heroChoice(enemy))
  doAssert played.step()
  doAssert played.game.stateHash == human.stateHash
  doAssert played.bots[player].action.kind == ActionAttack
  doAssert human.playCard(0, creatureChoice(player, 1))
  doAssert played.step()
  doAssert played.game.stateHash == human.stateHash
  doAssert human.playCard(0)
  doAssert played.step()
  doAssert played.game.stateHash == human.stateHash
  doAssert played.game.currentPlayer == player
  doAssert played.game.players[player].energy == 0
  doAssert played.game.players[enemy].life == StartingLife - 10
  # Primordial is a vanilla 10/10 now: the Bear and the Bouncer both stay.
  doAssert played.game.players[enemy].board.len == 1
  doAssert played.game.players[player].board.len == 2
  for minion in played.game.players[player].board:
    doAssert not minion.canAttack
  human.finishTurn()
  doAssert played.step()
  doAssert played.game.stateHash == human.stateHash

echo "Scripts can attack another opponent's hero or a chosen minion"
for target in [heroChoice(2), creatureChoice(2, 2)]:
  var played = scripted("""
id = boardId(selfPlayer, 0)
j = 0
while j < attackChoiceCount(id)
  if attackChoiceOwner(id, j) = 2 then
    if attackChoiceKind(id, j) = desired then
      attack(id, j)
      end
    end if
  end if
  j = j + 1
wend
""", 3)
  played.game.currentPlayer = 0
  played.game.players[0].board = @[ready(0, 1, baseCardNamed("Bear"))]
  played.game.players[2].board = @[ready(2, 2, baseCardNamed("Bear"))]
  played.game.nextMinionId = 3
  played.bots[0].runtime.setGlobal("desired", target.kind.ord.int32)
  var human = played.game.copyGameState()
  doAssert human.attack(1, target)
  doAssert played.step()
  doAssert played.game.stateHash == human.stateHash
  doAssert played.game.currentPlayer == 0

echo "Discard choices belong to their owner, including off-turn choices"
block:
  var played = scripted("""
dim picks(1)
picks(0) = 1
picks(1) = 2
observed = selfPlayer
discardCards("picks")
""")
  let owner = played.game.nextPlayer(played.game.currentPlayer)
  played.game.players[owner].hand = @[baseCardNamed("Primordial"),
    baseCardNamed("Bouncer"), baseCardNamed("Study")]
  played.game.pendingToss = PendingToss(player: owner, count: 2)
  var human = played.game.copyGameState()
  doAssert human.resolvePendingToss(@[1, 2])
  doAssert played.step()
  doAssert played.game.stateHash == human.stateHash
  doAssert played.bots[owner].action.playerId == owner.int32
  doAssert played.bots[owner].runtime.getGlobal("observed") == owner.int32
  doAssert played.game.players[owner].hand == @[baseCardNamed("Primordial")]

echo "Scripts choose trigger targets, including off-turn triggers"
block:
  var played = scripted("""
dim picks(0)
j = 0
while j < nextChoiceCount(-1, "picks", 0)
  if nextChoiceId(-1, "picks", 0, j) = 2 then
    picks(0) = j
    resolveTrigger("picks")
    end
  end if
  j = j + 1
wend
""")
  let player = played.game.currentPlayer
  let owner = played.game.nextPlayer(player)
  let snare = Card(name: "Snare", kind: Trinket, class: some(Mage),
    rules: rules(on(nextTurn(You), damage(1, target({TargetKind.Minion})))))
  played.game.players[owner].board = @[ready(owner, 1, snare)]
  played.game.players[player].board = @[ready(player, 2, baseCardNamed("Bear"))]
  played.game.nextMinionId = 3
  played.game.pendingTriggers = @[PendingTrigger(owner: owner,
    sourceId: 1, trigger: 0)]
  var human = played.game.copyGameState()
  doAssert human.resolvePendingTrigger(@[creatureChoice(player, 2)])
  doAssert played.step()
  discard human.takeVisualEvents()
  doAssert played.game.currentPlayer == human.currentPlayer
  doAssert played.game.turnNumber == human.turnNumber
  doAssert not played.game.waitingTrigger
  doAssert played.game.players[player].board[0].currentToughness ==
    human.players[player].board[0].currentToughness
  doAssert played.bots[owner].action.playerId == owner.int32

echo "A newly played Bouncer can target itself just as in the human UI"
block:
  var played = scripted("""
j = 0
while j < choiceCount(0)
  if choiceKind(0, j) = 3 and choiceOwner(0, j) = selfPlayer then
    playCardChoice(0, j)
    end
  end if
  j = j + 1
wend
""")
  let player = played.game.currentPlayer
  played.game.players[player].hand = @[baseCardNamed("Bouncer")]
  played.game.players[player].energy = 1
  var human = played.game.copyGameState()
  let id = human.playMinion(0)
  doAssert human.runMinionRules(baseCardNamed("Bouncer"),
    creatureChoice(player, id), id)
  doAssert played.step()
  doAssert played.game.stateHash == human.stateHash
  doAssert played.game.players[player].board.len == 0

echo "Only one selected action is committed and errors are atomic"
block:
  var played = scripted("first = playCard(0)\nsecond = endTurn()")
  let player = played.game.currentPlayer
  played.game.players[player].hand = @[baseCardNamed("Primordial")]
  played.game.players[player].energy = 8
  doAssert played.step()
  doAssert played.bots[player].runtime.getGlobal("first") == 1
  doAssert played.bots[player].runtime.getGlobal("second") == 0
  doAssert played.game.currentPlayer == player
block:
  var played = scripted("playCard(0)\nx = 1 \\ 0")
  let player = played.game.currentPlayer
  played.game.players[player].hand = @[baseCardNamed("Primordial")]
  played.game.players[player].energy = 8
  let before = played.game.stateHash
  doAssert not played.step()
  doAssert played.game.stateHash == before
  doAssert played.tick == 0

echo "Invalid attacks and missing discard choices never produce fallbacks"
block:
  var played = scripted("attack(-1, 0)")
  let before = played.game.stateHash
  doAssert not played.step()
  doAssert played.game.stateHash == before
block:
  var played = scripted("endTurn()")
  played.game.pendingToss = PendingToss(player: played.game.currentPlayer,
    count: 1)
  let before = played.game.stateHash
  doAssert not played.step()
  doAssert played.game.stateHash == before
  doAssert played.game.waitingToss

echo "Host queries reject excessive target steps without allocations"
block:
  var played = scripted("""
a = targetChoiceCount(0, 2147483647)
b = triggerChoiceCount(2147483647)
endTurn()
""")
  let player = played.game.currentPlayer
  doAssert played.step()
  doAssert played.bots[player].runtime.getGlobal("a") == 0
  doAssert played.bots[player].runtime.getGlobal("b") == 0

echo "Explicit action parity passed"

echo "Scripts choose classes before dealing and can query every seat"
block:
  let sources = newSeqWith(4, """
if selectingClass then
  if selfClass <> -1 or enemyClass <> -1 then stop
  if handSize <> 0 or boardCount(selfPlayer) <> 0 then stop
  if pickClass(selfPlayer MOD 3) <> 1 then stop
  if pickClass(2) <> 0 or endTurn() <> 0 then stop
  end
end if
if selfClass <> playerClass(selfPlayer) then stop
if enemyClass <> playerClass(enemyPlayer) then stop
if playerClass(3) <> 0 then stop
endTurn()
""")
  let bots = loadBots(sources)
  let classes = bots.chooseBotClasses()
  doAssert classes == @[Archer, Warrior, Mage, Archer]
  var setup = Setup(seed: 19, maximumTicks: 4)
  for heroClass in classes:
    setup.classes.add heroClass.ord.uint8
  let recorder = initReplayRecorder(setup,
    GameConfig(seed: 19, maxTicks: 4, players: unnamedPlayers(4)))
  var played = initBotMatch(classes, 19, bots, 4, recorder)
  played.run()
  doAssert played.outcome == MatchTimedOut
  var replayed = newGame(recorder.data.header.setup.heroClasses, 19)
  for action in recorder.data.actions:
    doAssert replayed.applyAction(action)
    discard replayed.takeVisualEvents()
    doAssert replayed.stateHash == recorder.data.hashes[action.tick.int - 1]
  doAssert replayed.stateHash == played.game.stateHash
  let missing = loadBot("endTurn()", 0)
  var rejected = false
  try:
    discard missing.chooseClass(2)
  except BasicError:
    rejected = true
  doAssert rejected

echo "Printed identity and live stats cover hand and every player's board"
block:
  var played = scripted("""
if handId$(0) <> "Bouncer" then stop
if cardName$(handId$(0)) <> handName$(0) then stop
if cardClass(handId$(0)) <> 2 then stop
if cardCost(handId$(0)) <> 1 then stop
if cardRules$(handId$(0)) = "" then stop
if boardCard$(3, 0) <> "Sniper" then stop
if cardPower(boardCard$(3, 0)) <> 2 then stop
if boardPower(3, 0) <> 5 then stop
if cardToughness(boardCard$(3, 0)) <> 1 then stop
if boardHp(3, 0) <> 1 then stop
if cardHasKeyword(boardCard$(3, 0), 0) <> 1 then stop
if boardHasKeyword(3, 0, 0) <> 0 then stop
if boardReady(3, 0) <> 0 or boardAttacked(3, 0) <> 1 then stop
if boardKind(3, 1) <> 2 then stop
if selfPlayer <> 3 and playerHandSize(3) <> 5 then stop
if playerLife(3) <> 20 then stop
endTurn()
""", 4)
  let player = played.game.currentPlayer
  played.game.players[player].hand = @[baseCardNamed("Bouncer")]
  var sniper = ready(3, 1, baseCardNamed("Sniper"))
  sniper.bonusPower = 3
  sniper.lostKeywords = {Ranged}
  sniper.hasAttacked = true
  played.game.players[3].board = @[
    sniper, ready(3, 2, baseCardNamed("Bubble"))]
  played.game.nextMinionId = 3
  doAssert played.step()
  doAssert played.bots[player].action.kind == ActionEndTurn

echo "Large hands and boards have no automatic thirty-card turn cap"
block:
  var played = scripted("""
if handSize > 0 then
  if playCard(handSize - 1) then end
end if
id = boardId(selfPlayer, 0)
i = 0
while i < attackChoiceCount(id)
  if attackChoiceId(id, i) = 200 then
    if attack(id, i) then end
  end if
  i = i + 1
wend
endTurn()
""", 4)
  let player = played.game.currentPlayer
  played.game.players[player].hand = newSeqWith(64, baseCardNamed("Ooze"))
  played.game.players[player].board = @[
    ready(player, 1, baseCardNamed("Primordial"))]
  let enemy = (player + 2) mod 4
  for i in 100 .. 200:
    played.game.players[enemy].board.add ready(enemy, i, baseCardNamed("Bear"))
  played.game.nextMinionId = 201
  for i in 0 ..< 64:
    doAssert played.step()
    doAssert played.game.currentPlayer == player
    doAssert played.bots[player].action.kind == ActionPlayCard
  doAssert played.game.players[player].board.len == 65
  doAssert played.step()
  doAssert played.bots[player].action.kind == ActionAttack
  doAssert played.bots[player].action.choices[0].creatureId == 200
  doAssert played.game.currentPlayer == player

echo "Class, observation and large-board parity passed"
