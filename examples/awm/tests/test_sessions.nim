import std/[json, options, unittest]
import ../src/core/sessions

suite "session options":
  test "defaults":
    let options = parseSessionOptions([])
    check options.seed == DefaultSessionSeed
    check not options.seedGiven
    check options.playerClass == Archer
    check options.opponentClass == Mage
    check options.playerCount == 2
    check options.human == false

  test "URL argument forms and negative seeds":
    let options = parseSessionOptions([
      "--seed", "-123", "--class", "warrior", "--opponent=MAGE"])
    check options.seed == -123
    check options.seedGiven
    check options.playerClass == Warrior
    check options.opponentClass == Mage

  test "human flag forms":
    check parseSessionOptions(["--human"]).human == true
    check parseSessionOptions(["--human", "true"]).human == true
    check parseSessionOptions(["--human=1"]).human == true
    check parseSessionOptions(["--human=yes"]).human == true
    check parseSessionOptions(["--human", "false"]).human == false
    check parseSessionOptions(["--human", "--seed", "1"]).human == true

  test "player count selects a scene without changing duel options":
    check parseSessionOptions(["--players=2"]).playerCount == 2
    check parseSessionOptions(["--players=3"]).playerCount == 3
    let options = parseSessionOptions([
      "--players", "6", "--human", "--class=warrior", "--seed=42"])
    check options.playerCount == 6
    check options.human
    check options.playerClass == Warrior
    check options.seed == 42
    check options.seedGiven

  test "invalid and missing player counts fail clearly":
    for args in [@["--players"], @["--players="],
        @["--players", "--seed=42"], @["--players=many"],
        @["--players=3.5"], @["--players=0"], @["--players=1"],
        @["--players=-3"], @["--players=9223372036854775808"]]:
      expect ValueError:
        discard parseSessionOptions(args)

  test "invalid and incomplete options fail clearly":
    for args in [@["--seed=none"], @["--class=rogue"],
        @["--opponent=rogue"], @["--seed"], @["--seed="],
        @["--class", "--seed=1"], @["--unknown=value"], @["local"],
        @["--seed=9223372036854775808"]]:
      expect ValueError:
        discard parseSessionOptions(args)

suite "deterministic session bots":
  test "Bolt targets the enemy hero and never an ally":
    var game = newGame(Archer, Mage, 7)
    let player = game.currentPlayer
    game.players[player].hand = @[Archer.classCard()]
    game.players[player].energy = 1
    let action = game.nextBotAction()
    check action.kind == PlayCardAction
    check action.handIndex == 0
    check action.choices == @[heroChoice(1 - player)]
    check game.applyBotAction(action)
    check game.players[player].life == StartingLife
    check game.players[1 - player].life < StartingLife

  test "Bouncer selects enemy minions and otherwise declines its target":
    var game = newGame(Mage, Warrior, 11)
    let player = game.currentPlayer
    game.players[player].hand = @[Mage.classCard()]
    game.players[player].energy = 1
    check game.nextBotAction().choices == @[NoTarget]
    game.players[1 - player].board = @[MinionState(id: 1,
      owner: 1 - player, card: Warrior.classCard(), currentToughness: 2)]
    game.nextMinionId = 2
    let action = game.nextBotAction()
    check action.choices == @[creatureChoice(1 - player, 1)]
    check game.applyBotAction(action)
    check game.players[1 - player].board.len == 0
    check game.players[player].board.len == 1

  test "budget and unavailable cards end the turn":
    var game = newGame(Archer, Mage, 17)
    check game.nextBotAction(playsThisTurn = 3).kind == EndTurnAction
    game.players[game.currentPlayer].energy = 0
    let action = game.nextBotAction()
    check action.kind == EndTurnAction
    check game.applyBotAction(action)
    check game.turnNumber == 2

  test "all class pairs progress deterministically with legal bounded actions":
    for first in HeroClass:
      for second in HeroClass:
        var left = newGame(first, second, DefaultSessionSeed)
        var right = newGame(first, second, DefaultSessionSeed)
        var playsThisTurn = 0
        for step in 0 ..< 160:
          if left.gameOver:
            break
          let leftAction = left.nextBotAction(playsThisTurn)
          let rightAction = right.nextBotAction(playsThisTurn)
          check leftAction == rightAction
          if leftAction.kind == PlayCardAction:
            check left.canPlay(leftAction.handIndex)
            inc playsThisTurn
          else:
            playsThisTurn = 0
          check left.applyBotAction(leftAction)
          check right.applyBotAction(rightAction)
          discard left.takeVisualEvents()
          discard right.takeVisualEvents()
          check gameToJson(left) == gameToJson(right)
        check left.turnNumber > 4
        check left.gameOver == right.gameOver

suite "global snapshots":
  test "every base card and game zone round trips with live rule programs":
    var game = newGame(Archer, Mage, 23)
    game.players[0].hand = @[Archer.classCard(), Warrior.classCard(), Mage.classCard()]
    game.players[0].discardPile = @[Archer.classCard()]
    game.players[1].board = @[MinionState(id: 8, owner: 1,
      card: Warrior.classCard(), currentToughness: 1, bonusPower: 2,
      lostKeywords: {Ranged})]
    game.nextMinionId = 9
    game.visualEvents = @[
      VisualEvent(kind: LightningVfx, target: heroChoice(1)),
      VisualEvent(kind: DamageFlashVfx, target: heroChoice(1)),
      VisualEvent(kind: BubbleVfx, target: creatureChoice(1, 7),
        boardIndex: 1, boardCount: 2),
      VisualEvent(kind: SwordsIntoTheWindVfx, target: creatureChoice(1, 8),
        boardIndex: 0, boardCount: 1),
      VisualEvent(kind: DeathVfx, target: creatureChoice(1, 6),
        boardIndex: 0, boardCount: 1, card: Warrior.classCard(), power: 4),
      VisualEvent(kind: DrawVfx, target: heroChoice(0),
        boardIndex: 3, boardCount: 4, beat: 7)]
    game.visualBeat = 9
    let original = Snapshot(matchId: "global-23", revision: 42, game: game)
    let encoded = snapshotToJson(original)
    let decoded = snapshotFromJson($encoded)
    check decoded.matchId == original.matchId
    check decoded.revision == original.revision
    check snapshotToJson(decoded) == encoded
    for index, heroClass in [Archer, Warrior, Mage]:
      let card = decoded.game.players[0].hand[index]
      check card == heroClass.classCard()
      check card.ruleText() == heroClass.classCard().ruleText()
      check card.needsChoice() == heroClass.classCard().needsChoice()
    check decoded.game.players[1].board[0].currentToughness == 1
    check decoded.game.players[1].board[0].power == 5
    check decoded.game.players[1].board[0].lostKeywords == {Ranged}
    var unknownKeyword = encoded["game"].copy()
    unknownKeyword["players"][1]["board"][0]["lostKeywords"] = %*["Flying"]
    expect ValueError:
      discard gameFromJson(unknownKeyword)
    check decoded.game.visualEvents == game.visualEvents
    check decoded.game.visualBeat == 9

  test "every base card has a unique ID and the Archer deck round trips":
    for card in baseCards:
      check baseCard(card.cardId()) == card
      for other in baseCards:
        if other != card:
          check other.cardId() != card.cardId()
    let game = newGame(Archer, Archer, 29)
    let decoded = gameFromJson(gameToJson(game))
    for player in 0 ..< PlayerCount:
      check decoded.players[player].deck == game.players[player].deck
      check decoded.players[player].hand == game.players[player].hand

  test "restored snapshot executes the same subsequent bot actions":
    var original = newGame(Mage, Archer, 31)
    for step in 0 ..< 8:
      check original.applyBotAction(original.nextBotAction(step mod 4))
    var restored = gameFromJson(gameToJson(original))
    for step in 0 ..< 30:
      let action = original.nextBotAction(step mod 4)
      check action == restored.nextBotAction(step mod 4)
      check original.applyBotAction(action)
      check restored.applyBotAction(action)
      check gameToJson(original) == gameToJson(restored)

  test "unknown cards and malformed metadata are rejected":
    let valid = snapshotToJson(Snapshot(matchId: "global-1", revision: 0,
      game: newGame(Archer, Mage, 1)))
    for invalid in ["not json", "[]", "{}", "null"]:
      expect ValueError:
        discard snapshotFromJson(invalid)
    for key in ["schemaVersion", "matchId", "revision", "game"]:
      var missing = valid.copy()
      missing.delete(key)
      expect ValueError:
        discard snapshotFromJson(missing)
    for version in [SnapshotSchemaVersion - 1, SnapshotSchemaVersion + 1]:
      var invalid = valid.copy()
      invalid["schemaVersion"] = %version
      expect ValueError:
        discard snapshotFromJson(invalid)
    var invalidCard = valid.copy()
    invalidCard["game"]["players"][0]["hand"].elems[0] = %"unknown"
    expect ValueError:
      discard snapshotFromJson(invalidCard)
    var negativeRevision = valid.copy()
    negativeRevision["revision"] = %(-1)
    expect ValueError:
      discard snapshotFromJson(negativeRevision)

  test "invalid state types and board identities are rejected":
    let valid = gameToJson(newGame(Warrior, Mage, 37))
    for key in ["currentPlayer", "turnNumber", "nextMinionId", "players", "visualEvents"]:
      var invalid = valid.copy()
      invalid[key] = %"invalid"
      expect ValueError:
        discard gameFromJson(invalid)
    var invalidPlayer = valid.copy()
    invalidPlayer["currentPlayer"] = %2
    expect ValueError:
      discard gameFromJson(invalidPlayer)
    var invalidMinion = valid.copy()
    invalidMinion["nextMinionId"] = %2
    invalidMinion["players"][0]["board"] = %*[
      {"id": 1, "owner": 1, "card": "bear-2", "currentToughness": 2}]
    expect ValueError:
      discard gameFromJson(invalidMinion)
    invalidMinion["players"][0]["board"][0]["owner"] = %0
    invalidMinion["players"][0]["board"][0]["card"] = %"bolt-1"
    expect ValueError:
      discard gameFromJson(invalidMinion)

  test "custom cards cannot silently serialize as a base-set card":
    var game = newGame(Archer, Mage, 43)
    game.players[0].hand = @[Card(name: "Different", class: some(Archer),
      energyCost: 1, kind: Spell)]
    expect ValueError:
      discard gameToJson(game)


suite "owned game snapshots":
  test "saved presentation state survives mutation and board reallocation":
    var game = newGame(Mage, Warrior, 7)
    game.currentPlayer = 0
    let bouncer = Mage.classCard()
    game.players[0].hand = @[bouncer, bouncer, bouncer, bouncer, bouncer]
    game.players[0].energy = 20
    game.players[0].totalEnergy = 20
    discard game.playCard(0, NoTarget)
    let saved = game.copyGameState()
    let savedJson = $gameToJson(saved)
    for _ in 0 ..< 4:
      discard game.playCard(0, NoTarget)
    game.finishTurn()
    check $gameToJson(saved) == savedJson
    check saved.players[0].board.len == 1
    check game.players[0].board.len == 5

import std/os
import ../src/core/bots

suite "bots and two-target cards":
  proc duelGame(): (GameState, int) =
    ## Duel in hand, a Bear on our side and a Sniper on theirs.
    var game = newGame(Warrior, Archer, 641)
    let me = game.currentPlayer
    game.players[me].board = @[MinionState(id: 1, owner: me,
      card: Warrior.classCard(), currentToughness: 2)]
    game.players[1 - me].board = @[MinionState(id: 2, owner: 1 - me,
      card: baseCard("sniper-2"), currentToughness: 1)]
    game.nextMinionId = 3
    game.players[me].hand = @[baseCard("duel-2")]
    game.players[me].energy = 2
    (game, me)

  test "the built-in bot buffs its own minion and duels an enemy":
    let (game, me) = duelGame()
    let action = game.nextBotAction()
    check action.kind == PlayCardAction
    check action.choices == @[creatureChoice(me, 1), creatureChoice(1 - me, 2)]

  test "the built-in bot skips Duel without an enemy minion":
    var (game, me) = duelGame()
    game.players[1 - me].board.setLen(0)
    check game.nextBotAction().kind == EndTurnAction

  test "the reference BASIC bot plays Duel with both targets":
    var (game, me) = duelGame()
    let vm = loadBot(readFile(currentSourcePath().parentDir.parentDir /
      "players" / "base.bas"), me.int32)
    check vm.runDecision(game) == BotPlayedCard
    check game.players[me].hand.len == 0
    check not game.minionLocation(2).found
    check game.players[me].board[0].power == 4

suite "summoned minions":
  test "summoned minions round trip":
    var game = newGame(Warrior, Mage, 743)
    let me = game.currentPlayer
    game.players[me].hand = @[baseCard("commander-5")]
    game.players[me].energy = 5
    check game.playCard(0)
    check game.players[me].board.len == 3
    let decoded = gameFromJson(gameToJson(game))
    check gameToJson(decoded) == gameToJson(game)
    check decoded.players[me].board.len == 3
    check decoded.players[me].board[2].card == baseCard("footsoldier-1")
    check decoded.nextMinionId == game.nextMinionId

suite "trinkets in snapshots":
  test "a trinket in play and its trigger survive a round trip":
    var game = newGame(Mage, Warrior, 1013)
    let me = game.currentPlayer
    game.players[me].hand = @[baseCard("plan-3")]
    game.players[me].energy = 3
    check game.playCard(0)
    var restored = gameFromJson(gameToJson(game))
    check gameToJson(restored) == gameToJson(game)
    check restored.players[me].board[0].card == baseCard("plan-3")
    for _ in 0 ..< 2:
      game.finishTurn()
      restored.finishTurn()
    check gameToJson(restored) == gameToJson(game)
    check restored.players[me].board.len == 0
    check restored.players[me].discardPile == @[baseCard("plan-3")]

suite "waiting triggers in snapshots":
  test "a trigger waiting for a target survives a round trip":
    var game = newGame(Mage, Warrior, 1111)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[enemy].board = @[MinionState(id: 2, owner: enemy,
      card: Warrior.classCard(), currentToughness: 2)]
    # Snapshots hold base-set cards, so Plan stands in as the trigger's card.
    game.players[me].board = @[MinionState(id: 3, owner: me,
      card: baseCard("plan-3"), enteredTurn: game.turnNumber)]
    game.nextMinionId = 4
    game.pendingTriggers = @[PendingTrigger(owner: me, sourceId: 3, trigger: 0,
      attacker: creatureChoice(enemy, 2))]
    let encoded = gameToJson(game)
    let decoded = gameFromJson(encoded)
    check decoded.pendingTriggers.len == 1
    check decoded.pendingTriggers[0].sourceId == 3
    check decoded.pendingTriggers[0].attacker == creatureChoice(enemy, 2)
    check gameToJson(decoded) == encoded
    var invalid = encoded.copy()
    invalid["pendingTriggers"][0]["sourceId"] = %2
    expect ValueError:
      discard gameFromJson(invalid)

  test "the built-in bot answers a waiting trigger for its owner":
    let snare = Card(name: "Snare", energyCost: 0, kind: Trinket,
      rules: rules(on(nextTurn(You), damage(1, target({Minion})))))
    var game = newGame(Mage, Warrior, 1109)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[me].hand = @[snare]
    check game.playCard(0)
    game.players[enemy].board = @[MinionState(id: 90, owner: enemy,
      card: Warrior.classCard(), currentToughness: 2)]
    game.nextMinionId = 91
    game.finishTurn()
    game.finishTurn()
    check game.waitingTrigger
    check game.nextBotAction().kind == ResolveTriggerAction
    # Even out of budget, a waiting trigger is answered, not skipped.
    let action = game.nextBotAction(playsThisTurn = 3)
    check action.kind == ResolveTriggerAction
    check action.choices == @[creatureChoice(enemy, 90)]
    check not game.applyBotAction(BotAction(kind: EndTurnAction))
    check game.applyBotAction(action)
    check not game.waitingTrigger
    check game.players[enemy].board[0].currentToughness == 1

suite "waiting discards":
  test "the built-in bot discards its most expensive card":
    var game = newGame(Mage, Warrior, 1313)
    let me = game.currentPlayer
    game.players[me].hand = @[baseCard("study-2"), baseCard("plan-3"),
      baseCard("oozification-4"), baseCard("bouncer-1")]
    game.players[me].energy = 2
    check game.playCard(0)
    check game.waitingToss
    let action = game.nextBotAction()
    check action.kind == TossAction
    let hand = game.players[me].hand
    var best = 0
    for index, card in hand:
      if card.energyCost >= hand[best].energyCost:
        best = index
    check action.tossIndices == @[best]
    check game.applyBotAction(action)
    check not game.waitingToss

  test "a waiting discard and its later effects survive a round trip":
    var game = newGame(Mage, Warrior, 1315)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[enemy].board = @[MinionState(id: 2, owner: enemy,
      card: Warrior.classCard(), currentToughness: 2)]
    game.nextMinionId = 3
    game.pendingToss = PendingToss(player: me, count: 1, source: "Study",
      text: "Discard 1 card.", remaining: @[
        Effect(kind: DrawEffect, beat: 1, drawPlayer: me, drawCount: 1),
        Effect(kind: DamageCreatureEffect, beat: 2, damagedCreatureId: 2,
          creatureDamage: 1),
        Effect(kind: SummonEffect, beat: 3, summonedId: 9,
          summonedOwner: enemy, summonedCard: baseCard("ooze-0")),
        Effect(kind: TargetVfxEffect, beat: 3, targetVfx: OozeSplatVfx,
          visualTarget: creatureChoice(enemy, 2)),
        Effect(kind: LoseKeywordEffect, beat: 4, keywordLoserId: 2,
          lostKeyword: Ranged)])
    let encoded = gameToJson(game)
    let decoded = gameFromJson(encoded)
    check decoded.waitingToss
    check decoded.pendingToss.count == 1
    check decoded.pendingToss.remaining.len == 5
    check gameToJson(decoded) == encoded
    var invalid = encoded.copy()
    invalid["pendingToss"]["remaining"][0]["kind"] = %"NoSuchEffect"
    expect ValueError:
      discard gameFromJson(invalid)
