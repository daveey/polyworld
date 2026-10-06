import
  std/[options, strutils, unittest],
  ../src/awm

suite "AWM base set":
  test "the Mage deck is Bouncers and Oozifications, without Oozes":
    check DeckSize == 40
    let deck = Mage.baseDeck()
    check deck.len == DeckSize
    var bouncers, oozifications, plans, studies, summons, shields: int
    for card in deck:
      check card.class == some(Mage)
      if card == baseCard("bouncer-1"): inc bouncers
      elif card == baseCard("oozification-4"): inc oozifications
      elif card == baseCard("plan-3"): inc plans
      elif card == baseCard("study-2"): inc studies
      elif card == baseCard("summon-primordial-8"): inc summons
      elif card == baseCard("bubble-shield-2"): inc shields
      # Summoned-only cards never sit in the deck.
      check card != baseCard("bubble-0")
      check card != baseCard("primordial-8")
      check card != baseCard("ooze-0")
    check (bouncers, oozifications, plans, studies, summons, shields) ==
      (16, 4, 7, 7, 2, 4)

  test "the Warrior deck is forty cards of every Warrior card":
    let deck = Warrior.baseDeck()
    check deck.len == DeckSize
    var counts: seq[int]
    for id in ["bear-2", "swords-2", "shields-1", "duel-2", "tactician-2",
        "footsoldier-1", "commander-5", "rally-5"]:
      var count = 0
      for card in deck:
        if card == baseCard(id): inc count
      counts.add count
    for card in deck:
      check card.class == some(Warrior)
    check counts == @[8, 5, 4, 5, 5, 6, 4, 3]

  test "the Archer deck is forty cards of every Archer card":
    let deck = Archer.baseDeck()
    check deck.len == DeckSize
    var bolts, snipers, sharpshooters, hails: int
    for card in deck:
      check card.class == some(Archer)
      if card == baseCard("bolt-1"): inc bolts
      elif card == baseCard("sniper-2"): inc snipers
      elif card == baseCard("sharpshooter-3"): inc sharpshooters
      elif card == baseCard("hail-of-arrows-3"): inc hails
    check (bolts, snipers, sharpshooters, hails) == (10, 14, 10, 6)

  test "Bolt is a targeted two-damage spell":
    let bolt = Archer.classCard()
    check bolt.name == "Bolt"
    check bolt.energyCost == 1
    check bolt.class == some(Archer)
    check bolt.kind == Spell
    check bolt.needsChoice()
    check bolt.ruleText() == "Deal 2 damage to a hero."

  test "Bear is an unruled three-two minion":
    let bear = Warrior.classCard()
    check bear.name == "Bear"
    check bear.energyCost == 2
    check bear.class == some(Warrior)
    check bear.kind == Minion
    check bear.power == 3
    check bear.toughness == 2
    check not bear.needsChoice()
    check bear.ruleText().len == 0

  test "Bouncer is a one-one minion with a bounce rule":
    let bouncer = Mage.classCard()
    check bouncer.name == "Bouncer"
    check bouncer.energyCost == 1
    check bouncer.class == some(Mage)
    check bouncer.kind == Minion
    check bouncer.power == 1
    check bouncer.toughness == 1
    check bouncer.needsChoice()
    check bouncer.ruleText() ==
      "Return a minion to its owner's hand."

suite "AWM turns":
  test "players start at twenty life with five cards before the first turn":
    let game = newGame(Archer, Warrior, 7)
    for playerIndex in 0 ..< PlayerCount:
      let player = game.players[playerIndex]
      check player.life == StartingLife
      check player.board.len == 0
      if playerIndex == game.currentPlayer:
        check player.hand.len == StartingHandSize
        check player.deck.len == DeckSize - StartingHandSize
        check player.totalEnergy == 1
        check player.energy == 1
      else:
        check player.hand.len == StartingHandSize
        check player.deck.len == DeckSize - StartingHandSize
        check player.totalEnergy == 0
        check player.energy == 0

  test "finishing passes the turn, gains energy, replenishes, and draws":
    var game = newGame(Archer, Mage, 17)
    let
      first = game.currentPlayer
      second = (first + 1) mod PlayerCount
      secondHand = game.players[second].hand.len
    game.finishTurn()
    check game.currentPlayer == second
    check game.turnNumber == 2
    check game.players[second].totalEnergy == 1
    check game.players[second].energy == 1
    check game.players[second].hand.len == secondHand + 1

  test "energy grows on each of a player's turns and fully replenishes":
    var game = newGame(Archer, Mage, 43)
    let first = game.currentPlayer
    game.players[first].energy = 0
    game.finishTurn()
    game.finishTurn()
    check game.currentPlayer == first
    check game.players[first].totalEnergy == 2
    check game.players[first].energy == 2

suite "AWM card execution":
  test "Bolt offers both heroes and deals two damage":
    var game = newGame(Archer, Warrior, 23)
    let
      caster = game.currentPlayer
      enemy = (caster + 1) mod PlayerCount
      bolt = Archer.classCard()
    game.players[caster].hand = @[bolt]
    game.players[caster].energy = 1
    check game.availableChoices(0) == @[
      heroChoice(0),
      heroChoice(1)
    ]
    check game.playCard(0, heroChoice(enemy))
    check game.players[enemy].life == StartingLife - 2
    check game.players[caster].energy == 0
    check game.players[caster].hand.len == 0
    check game.players[caster].board.len == 0
    check game.players[caster].discardPile == @[bolt]

  test "Bolt can target its own hero":
    var game = newGame(Archer, Warrior, 27)
    let
      caster = game.currentPlayer
      bolt = Archer.classCard()
    game.players[caster].hand = @[bolt]
    game.players[caster].energy = 1
    check game.playCard(0, heroChoice(caster))
    check game.players[caster].life == StartingLife - 2
    check game.players[caster].discardPile == @[bolt]

  test "canceling or supplying an invalid target cancels the play":
    var game = newGame(Archer, Warrior, 29)
    let
      caster = game.currentPlayer
      bolt = Archer.classCard()
    game.players[caster].hand = @[bolt]
    game.players[caster].energy = 1
    check not game.playCard(0)
    check not game.playCard(0, heroChoice(PlayerCount))
    check game.players[caster].energy == 1
    check game.players[caster].hand == @[bolt]
    check game.players[caster].discardPile.len == 0

  test "Bear remains on the board as a three-two minion":
    var game = newGame(Warrior, Mage, 31)
    let
      player = game.currentPlayer
      bear = Warrior.classCard()
    game.players[player].hand = @[bear]
    game.players[player].energy = 2
    check game.playCard(0)
    check game.players[player].energy == 0
    check game.players[player].hand.len == 0
    check game.players[player].discardPile.len == 0
    check game.players[player].board.len == 1
    check game.players[player].board[0].card == bear
    check game.players[player].board[0].card.power == 3
    check game.players[player].board[0].currentToughness == 2

  test "Bouncer returns the selected minion and remains on the board":
    var game = newGame(Mage, Warrior, 37)
    let
      magePlayer = game.currentPlayer
      otherPlayer = (magePlayer + 1) mod PlayerCount
      bear = Warrior.classCard()
      bouncer = Mage.classCard()
      bearId = 77
    game.players[otherPlayer].board = @[
      MinionState(
        id: bearId,
        owner: otherPlayer,
        card: bear,
        currentToughness: bear.toughness
      )
    ]
    game.nextMinionId = 78
    game.players[magePlayer].hand = @[bouncer]
    game.players[magePlayer].energy = 1
    check game.availableChoices(0) == @[
      creatureChoice(otherPlayer, bearId),
      NoTarget
    ]
    check game.playCard(0, creatureChoice(otherPlayer, bearId))
    check game.players[otherPlayer].board.len == 0
    check game.players[otherPlayer].hand[^1] == bear
    check game.players[magePlayer].board.len == 1
    check game.players[magePlayer].board[0].card == bouncer
    check game.players[magePlayer].discardPile.len == 0

  test "Bouncer enters play before its target is chosen":
    var game = newGame(Mage, Archer, 39)
    let
      player = game.currentPlayer
      bouncer = Mage.classCard()
    game.players[player].hand = @[bouncer]
    game.players[player].energy = 1
    let bouncerId = game.playMinion(0)
    check bouncerId != 0
    check game.players[player].energy == 0
    check game.players[player].hand.len == 0
    check game.players[player].board.len == 1
    check game.availableChoices(bouncer) == @[
      creatureChoice(player, bouncerId),
      NoTarget
    ]
    check game.runMinionRules(
      bouncer,
      creatureChoice(player, bouncerId)
    )
    check game.players[player].board.len == 0
    check game.players[player].hand == @[bouncer]

  test "Bouncer can be played without a minion target":
    var game = newGame(Mage, Archer, 41)
    let
      player = game.currentPlayer
      bouncer = Mage.classCard()
    game.players[player].hand = @[bouncer]
    game.players[player].energy = 1
    check game.availableChoices(0) == @[NoTarget]
    check game.playMinion(0) != 0
    check game.runMinionRules(bouncer, NoTarget)
    check game.players[player].energy == 0
    check game.players[player].hand.len == 0
    check game.players[player].board.len == 1
    check game.players[player].board[0].card == bouncer

  test "Bouncer may decline a target even when a minion is available":
    var game = newGame(Mage, Warrior, 43)
    let
      player = game.currentPlayer
      otherPlayer = (player + 1) mod PlayerCount
      bear = Warrior.classCard()
      bouncer = Mage.classCard()
    game.players[otherPlayer].board = @[
      MinionState(
        id: 91,
        owner: otherPlayer,
        card: bear,
        currentToughness: bear.toughness
      )
    ]
    game.nextMinionId = 92
    game.players[player].hand = @[bouncer]
    game.players[player].energy = 1
    check game.playCard(0, NoTarget)
    check game.players[otherPlayer].board.len == 1
    check game.players[player].board.len == 1
    check game.players[player].board[0].card == bouncer

  test "No target cannot be used to cast a spell":
    var game = newGame(Archer, Mage, 47)
    let
      player = game.currentPlayer
      bolt = Archer.classCard()
    game.players[player].hand = @[bolt]
    game.players[player].energy = 1
    check not game.playCard(0, NoTarget)
    check game.players[player].energy == 1
    check game.players[player].hand == @[bolt]

suite "AWM target visual effects":
  test "target effects are optional and obey relation restrictions":
    check target({Hero}).vfx == NoVfx
    check target({Minion}).vfx == NoVfx
    var context = RuleContext(sourcePlayer: 0,
      heroes: @[heroChoice(0), heroChoice(1)])
    context.selector = proc(prompt: string, choices: seq[Choice]): Choice =
      heroChoice(0)
    let heroTarget = target({Hero}, Enemy, vfx = LightningVfx)
    check heroTarget.choose(context).isCanceled
    check context.effects.len == 0
    context.selector = proc(prompt: string, choices: seq[Choice]): Choice =
      heroChoice(1)
    check heroTarget.choose(context) == heroChoice(1)
    check context.effects.len == 1
    check context.effects[0].kind == TargetVfxEffect
    check context.effects[0].targetVfx == LightningVfx
    check context.effects[0].visualTarget == heroChoice(1)

  test "Bolt emits lightning and damage flash on the chosen hero exactly once":
    var game = newGame(Archer, Mage, 101)
    let target = heroChoice((game.currentPlayer + 1) mod PlayerCount)
    game.players[game.currentPlayer].hand = @[Archer.classCard()]
    game.players[game.currentPlayer].energy = 1
    check game.playCard(0, target)
    let events = game.takeVisualEvents()
    check events.len == 2
    check events[0].kind == LightningVfx
    check events[1].kind == DamageFlashVfx
    for event in events: check event.target == target
    check game.takeVisualEvents().len == 0

  test "invalid, canceled, unaffordable, and no-target spells emit no VFX":
    var game = newGame(Archer, Mage, 103)
    game.players[game.currentPlayer].hand = @[Archer.classCard()]
    game.players[game.currentPlayer].energy = 1
    for choice in [Canceled, NoTarget, heroChoice(99), creatureChoice(1, 23)]:
      check not game.playCard(0, choice)
      check game.visualEvents.len == 0
    game.players[game.currentPlayer].energy = 0
    check not game.playCard(0, heroChoice(0))
    check game.visualEvents.len == 0

  test "Bouncer snapshots a removed target for its bubble":
    var game = newGame(Mage, Warrior, 107)
    let
      caster = game.currentPlayer
      owner = (caster + 1) mod PlayerCount
      target = creatureChoice(owner, 75)
    game.players[owner].board = @[
      MinionState(id: 74, owner: owner, card: Warrior.classCard(), currentToughness: 2),
      MinionState(id: 75, owner: owner, card: Warrior.classCard(), currentToughness: 2)
    ]
    game.nextMinionId = 76
    game.players[caster].hand = @[Mage.classCard()]
    game.players[caster].energy = 1
    check game.playCard(0, target)
    check not game.minionLocation(75).found
    check game.visualEvents.len == 2
    let event = game.visualEvents[0]
    check event.kind == BubbleVfx
    check event.target == target
    check event.boardIndex == 1
    check event.boardCount == 2
    # The bounce itself follows in the same beat, so its bubble rides along.
    let bounce = game.visualEvents[1]
    check bounce.kind == BounceVfx
    check bounce.beat == event.beat
    check bounce.target == target
    check (bounce.boardIndex, bounce.boardCount) == (1, 2)
    check bounce.card == Warrior.classCard()
    check bounce.handIndex == game.players[owner].hand.high

  test "declining Bouncer's target produces no bubble":
    var game = newGame(Mage, Archer, 109)
    game.players[game.currentPlayer].hand = @[Mage.classCard()]
    game.players[game.currentPlayer].energy = 1
    check game.playCard(0, NoTarget)
    check game.visualEvents.len == 0

  test "damage flashes without a custom VFX and keeps a lethal target snapshot":
    var game = newGame(Archer, Warrior, 113)
    let owner = (game.currentPlayer + 1) mod PlayerCount
    let strike = Card(name: "Strike", energyCost: 1, kind: Spell,
      rules: rules(damage(2, target({Minion}))))
    game.players[owner].board = @[
      MinionState(id: 88, owner: owner, card: Warrior.classCard(), currentToughness: 2)
    ]
    game.players[game.currentPlayer].hand = @[strike]
    game.players[game.currentPlayer].energy = 1
    check game.playCard(0, creatureChoice(owner, 88))
    check game.players[owner].board.len == 0
    check game.visualEvents.len == 2
    check game.visualEvents[0].kind == DamageFlashVfx
    check game.visualEvents[1].kind == DeathVfx
    check game.visualEvents[1].card == Warrior.classCard()
    for event in game.visualEvents:
      check event.target == creatureChoice(owner, 88)
      check event.boardIndex == 0
      check event.boardCount == 1

  test "later canceled rules roll back earlier damage and visual effects":
    let combo = Card(name: "Combo", energyCost: 1, kind: Spell,
      rules: rules(
        damage(1, target({Hero}, vfx = LightningVfx)),
        bounce(target({Minion}, vfx = BubbleVfx))))
    var context = RuleContext(sourcePlayer: 0, heroes: @[heroChoice(1)])
    context.selector = proc(prompt: string, choices: seq[Choice]): Choice =
      heroChoice(1)
    check not combo.runRules(context)
    check context.effects.len == 0

  test "zero damage produces no damage flash":
    var game = newGame(Archer, Mage, 127)
    let harmless = Card(name: "Harmless", energyCost: 0, kind: Spell,
      rules: rules(damage(0, target({Hero}))))
    game.players[game.currentPlayer].hand = @[harmless]
    check game.playCard(0, heroChoice(0))
    check game.visualEvents.len == 0

proc readyMinion(owner, id: int, card: Card): MinionState =
  MinionState(id: id, owner: owner, card: card,
    currentToughness: card.toughness, canAttack: true)

suite "AWM combat":
  test "attack targets are the enemy hero, then enemy minions":
    var game = newGame(Warrior, Warrior, 301)
    let
      me = game.currentPlayer
      enemy = 1 - me
      bear = Warrior.classCard()
    game.players[me].board = @[readyMinion(me, 1, bear), readyMinion(me, 2, bear)]
    game.players[enemy].board = @[readyMinion(enemy, 3, bear)]
    game.nextMinionId = 4
    check game.attackTargets(1) ==
      @[heroChoice(enemy), creatureChoice(enemy, 3)]
    check game.attackTargets(3).len == 0
    game.players[me].board[1].canAttack = false
    check game.attackTargets(2).len == 0

  test "a freshly played minion cannot attack":
    var game = newGame(Warrior, Mage, 303)
    let me = game.currentPlayer
    game.players[me].hand = @[Warrior.classCard()]
    game.players[me].energy = 2
    let id = game.playMinion(0)
    check id != 0
    check game.attackTargets(id).len == 0
    check not game.attack(id, heroChoice(1 - me))

  test "minions deal their power to each other and both can die":
    var game = newGame(Warrior, Warrior, 307)
    let
      me = game.currentPlayer
      enemy = 1 - me
      bear = Warrior.classCard()
    game.players[me].board = @[readyMinion(me, 1, bear)]
    game.players[enemy].board = @[readyMinion(enemy, 2, bear)]
    game.nextMinionId = 3
    check game.attack(1, creatureChoice(enemy, 2))
    check game.players[me].board.len == 0
    check game.players[enemy].board.len == 0
    check game.players[me].discardPile == @[bear]
    check game.players[enemy].discardPile == @[bear]
    check game.players[enemy].life == StartingLife
    let
      events = game.takeVisualEvents()
      expected = [
        (DamageFlashVfx, creatureChoice(enemy, 2)),
        (DeathVfx, creatureChoice(enemy, 2)),
        (DamageFlashVfx, creatureChoice(me, 1)),
        (DeathVfx, creatureChoice(me, 1))]
    check events.len == expected.len
    for i, want in expected:
      check (events[i].kind, events[i].target) == want
    check events[1].card == bear
    check events[3].card == bear

  test "damage stays on a surviving minion and each minion attacks once":
    var game = newGame(Warrior, Mage, 311)
    let
      me = game.currentPlayer
      enemy = 1 - me
      bear = Warrior.classCard()
      bouncer = Mage.classCard()
    game.players[me].board = @[readyMinion(me, 1, bear)]
    game.players[enemy].board =
      @[readyMinion(enemy, 2, bouncer), readyMinion(enemy, 3, bouncer)]
    game.nextMinionId = 4
    check game.attackMinion(1, 2)
    check not game.minionLocation(2).found
    check game.players[enemy].discardPile == @[bouncer]
    check game.players[me].board[0].currentToughness == 1
    check not game.attack(1, creatureChoice(enemy, 3))
    check not game.attack(1, heroChoice(enemy))
    game.finishTurn()
    game.finishTurn()
    check game.players[me].board[0].currentToughness == 1
    check game.attack(1, creatureChoice(enemy, 3))
    check not game.minionLocation(1).found
    check not game.minionLocation(3).found

  test "attacking the enemy hero damages it; illegal targets are rejected":
    var game = newGame(Warrior, Warrior, 313)
    let
      me = game.currentPlayer
      enemy = 1 - me
      bear = Warrior.classCard()
    game.players[me].board = @[readyMinion(me, 1, bear), readyMinion(me, 2, bear)]
    game.players[enemy].board = @[readyMinion(enemy, 3, bear)]
    game.nextMinionId = 4
    for illegal in [heroChoice(me), creatureChoice(me, 2),
        creatureChoice(enemy, 99), NoTarget, Canceled]:
      check not game.attack(1, illegal)
    check not game.attackMinion(1, 2)
    check not game.attackMinion(3, 1)
    check game.players[me].board[0].currentToughness == bear.toughness
    check game.attack(1, heroChoice(enemy))
    check game.players[enemy].life == StartingLife - bear.power
    check game.players[enemy].board[0].currentToughness == bear.toughness

proc baseCard(name: string, energyCost: int): Card =
  for card in baseCards:
    if card.name == name and card.energyCost == energyCost:
      return card
  doAssert false, "missing base card " & name

suite "AWM target kinds":
  test "kinds and relations read as rules text":
    check target({Hero}).text() == "a hero"
    check target({Hero}, Enemy).text() == "an enemy hero"
    check target({Minion}).text() == "a minion"
    check target({Minion}, Friendly).text() == "a friendly minion"
    check target({Minion, Hero}).text() == "any target"
    check target({Minion, Hero}, Enemy).text() == "an enemy target"
    check target({Minion, Hero}, Friendly).text() == "a friendly target"

  test "a minion-or-hero target offers heroes, then minions":
    let context = RuleContext(sourcePlayer: 0,
      heroes: @[heroChoice(0), heroChoice(1)],
      creatures: @[creatureChoice(0, 5), creatureChoice(1, 6)])
    check target({Minion, Hero}).candidates(context) == @[
      heroChoice(0), heroChoice(1), creatureChoice(0, 5), creatureChoice(1, 6)]
    check target({Minion, Hero}, Enemy).candidates(context) ==
      @[heroChoice(1), creatureChoice(1, 6)]
    check target({Hero}, Friendly).candidates(context) == @[heroChoice(0)]
    check target({Minion}, Friendly).candidates(context) ==
      @[creatureChoice(0, 5)]

suite "AWM Sharpshooter":
  test "Sniper and Sharpshooter carry their printed data":
    let
      small = baseCard("Sniper", 2)
      large = baseCard("Sharpshooter", 3)
    check small.class == some(Archer)
    check small.kind == Minion
    check small.power == 2
    check small.toughness == 1
    check not small.needsChoice()
    check small.keywords() == {Ranged}
    check small.ruleText() == "Ranged"
    check large.class == some(Archer)
    check large.kind == Minion
    check large.power == 3
    check large.toughness == 1
    check large.needsChoice()
    check large.keywords() == {Ranged}
    check large.ruleText() == "Ranged\nDeal 1 damage to any target."
    check Warrior.classCard().keywords() == {}

  test "Sharpshooter may target either hero, any minion, or nothing":
    var game = newGame(Archer, Warrior, 211)
    let
      caster = game.currentPlayer
      enemy = (caster + 1) mod PlayerCount
      bear = Warrior.classCard()
    game.players[enemy].board = @[
      MinionState(id: 50, owner: enemy, card: bear,
        currentToughness: bear.toughness)
    ]
    game.nextMinionId = 51
    game.players[caster].hand = @[baseCard("Sharpshooter", 3)]
    game.players[caster].energy = 3
    check game.availableChoices(0) == @[
      heroChoice(0), heroChoice(1), creatureChoice(enemy, 50), NoTarget]

  test "Sharpshooter shoots the enemy hero with an arrow":
    var game = newGame(Archer, Warrior, 223)
    let
      caster = game.currentPlayer
      enemy = (caster + 1) mod PlayerCount
      sharpshooter = baseCard("Sharpshooter", 3)
    game.players[caster].hand = @[sharpshooter]
    game.players[caster].energy = 3
    check game.playCard(0, heroChoice(enemy))
    check game.players[enemy].life == StartingLife - 1
    check game.players[caster].energy == 0
    check game.players[caster].board.len == 1
    check game.players[caster].board[0].card == sharpshooter
    let events = game.takeVisualEvents()
    check events.len == 2
    check events[0].kind == ArrowVfx
    check events[1].kind == DamageFlashVfx
    for event in events: check event.target == heroChoice(enemy)

  test "Sharpshooter damages and destroys minions":
    var game = newGame(Archer, Mage, 227)
    let
      caster = game.currentPlayer
      enemy = (caster + 1) mod PlayerCount
      bear = Warrior.classCard()
      bouncer = Mage.classCard()
      sharpshooter = baseCard("Sharpshooter", 3)
    game.players[enemy].board = @[
      MinionState(id: 60, owner: enemy, card: bear,
        currentToughness: bear.toughness),
      MinionState(id: 61, owner: enemy, card: bouncer,
        currentToughness: bouncer.toughness)
    ]
    game.nextMinionId = 62
    game.players[caster].hand = @[sharpshooter, sharpshooter]
    game.players[caster].energy = 6
    check game.playCard(0, creatureChoice(enemy, 60))
    check game.players[enemy].board[0].currentToughness == 1
    check game.playCard(0, creatureChoice(enemy, 61))
    check not game.minionLocation(61).found
    check game.players[enemy].discardPile == @[bouncer]
    check game.players[enemy].life == StartingLife
    check game.players[caster].board.len == 2

  test "Sharpshooter can enter play without shooting":
    var game = newGame(Archer, Warrior, 229)
    let caster = game.currentPlayer
    game.players[caster].hand = @[baseCard("Sharpshooter", 3)]
    game.players[caster].energy = 3
    check game.playCard(0, NoTarget)
    check game.players[caster].board.len == 1
    for playerIndex in 0 ..< PlayerCount:
      check game.players[playerIndex].life == StartingLife
    check game.visualEvents.len == 0

suite "AWM ranged":
  test "a ranged attacker takes no damage from a non-ranged defender":
    var game = newGame(Archer, Warrior, 401)
    let
      me = game.currentPlayer
      enemy = 1 - me
      sniper = baseCard("Sniper", 2)
      bear = Warrior.classCard()
    game.players[me].board = @[readyMinion(me, 1, sniper)]
    game.players[enemy].board = @[readyMinion(enemy, 2, bear)]
    game.nextMinionId = 3
    check game.attack(1, creatureChoice(enemy, 2))
    check not game.minionLocation(2).found
    check game.players[me].board[0].currentToughness == sniper.toughness
    var flashes: seq[Choice]
    for event in game.takeVisualEvents():
      if event.kind == DamageFlashVfx: flashes.add event.target
    check flashes == @[creatureChoice(enemy, 2)]

  test "a non-ranged attacker deals no damage to a ranged defender":
    var game = newGame(Warrior, Archer, 409)
    let
      me = game.currentPlayer
      enemy = 1 - me
      sniper = baseCard("Sniper", 2)
      bear = Warrior.classCard()
    game.players[me].board = @[readyMinion(me, 1, bear)]
    game.players[enemy].board = @[readyMinion(enemy, 2, sniper)]
    game.nextMinionId = 3
    check game.attack(1, creatureChoice(enemy, 2))
    check not game.minionLocation(1).found
    check game.players[me].discardPile == @[bear]
    check game.players[enemy].board[0].currentToughness == sniper.toughness
    var flashes: seq[Choice]
    for event in game.takeVisualEvents():
      if event.kind == DamageFlashVfx: flashes.add event.target
    check flashes == @[creatureChoice(me, 1)]

  test "ranged minions fight each other normally":
    var game = newGame(Archer, Archer, 419)
    let
      me = game.currentPlayer
      enemy = 1 - me
      sniper = baseCard("Sniper", 2)
      sharpshooter = baseCard("Sharpshooter", 3)
    game.players[me].board = @[readyMinion(me, 1, sniper)]
    game.players[enemy].board = @[readyMinion(enemy, 2, sharpshooter)]
    game.nextMinionId = 3
    check game.attack(1, creatureChoice(enemy, 2))
    check game.players[me].board.len == 0
    check game.players[enemy].board.len == 0

  test "on-play damage still hits ranged minions":
    var game = newGame(Archer, Archer, 421)
    let
      caster = game.currentPlayer
      enemy = 1 - caster
      sniper = baseCard("Sniper", 2)
    game.players[enemy].board = @[readyMinion(enemy, 70, sniper)]
    game.nextMinionId = 71
    game.players[caster].hand = @[baseCard("Sharpshooter", 3)]
    game.players[caster].energy = 3
    check game.playCard(0, creatureChoice(enemy, 70))
    check not game.minionLocation(70).found
    check game.players[enemy].discardPile == @[sniper]

suite "AWM card identity":
  test "copies share rules; look-alikes with their own rules differ":
    let
      sniper = baseCard("Sniper", 2)
      copy = sniper
      lookalike = Card(name: "Sniper", energyCost: 2, class: some(Archer),
        kind: Minion, rules: rules(ranged()), power: 2, toughness: 1)
    check copy == sniper
    check lookalike.ruleText() == sniper.ruleText()
    check lookalike != sniper

suite "AWM Hail of Arrows":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  test "Hail of Arrows prints its query and needs no target":
    let hail = baseCard("Hail of Arrows", 3)
    check hail.class == some(Archer)
    check hail.kind == Spell
    check not hail.needsChoice()
    check hail.ruleText() == "Deal 1 damage to all enemy minions."

  test "zone queries read as rules text":
    check printed(rules(damage(1, game.board.choose(kind: Minion)))) ==
      "Deal 1 damage to all minions."
    check printed(rules(damage(2,
      game.board.choose(kind: Minion, owner: You)))) ==
      "Deal 2 damage to all friendly minions."
    check printed(rules(damage(1, game.board.choose()))) ==
      "Deal 1 damage to all cards."
    check not compiles(rules(damage(1, game.board.choose(color: Minion))))

  test "Hail of Arrows hits every enemy minion and nothing else":
    var game = newGame(Archer, Warrior, 431)
    let
      caster = game.currentPlayer
      enemy = 1 - caster
      hail = baseCard("Hail of Arrows", 3)
      bear = Warrior.classCard()
      sniper = baseCard("Sniper", 2)
    game.players[caster].board = @[readyMinion(caster, 1, bear)]
    game.players[enemy].board =
      @[readyMinion(enemy, 2, sniper), readyMinion(enemy, 3, bear)]
    game.nextMinionId = 4
    game.players[caster].hand = @[hail]
    game.players[caster].energy = 3
    check game.availableChoices(0).len == 0
    check game.playCard(0)
    check game.players[caster].energy == 0
    check game.players[caster].discardPile == @[hail]
    # Spells hit ranged minions: only combat damage respects Ranged.
    check not game.minionLocation(2).found
    check game.players[enemy].discardPile == @[sniper]
    check game.players[enemy].board[0].currentToughness == bear.toughness - 1
    check game.players[caster].board[0].currentToughness == bear.toughness
    check game.players[enemy].life == StartingLife
    check game.players[caster].life == StartingLife
    let events = game.takeVisualEvents()
    check events.len >= 2
    # The volley lands on every target before any of them is removed.
    check events[0].kind == ManyArrowsVfx
    check events[0].target == creatureChoice(enemy, 2)
    check events[1].kind == ManyArrowsVfx
    check events[1].target == creatureChoice(enemy, 3)
    check (events[1].boardIndex, events[1].boardCount) == (1, 2)

  test "Hail of Arrows into an empty enemy board still resolves":
    var game = newGame(Archer, Warrior, 433)
    let
      caster = game.currentPlayer
      bear = Warrior.classCard()
      hail = baseCard("Hail of Arrows", 3)
    game.players[caster].board = @[readyMinion(caster, 1, bear)]
    game.nextMinionId = 2
    game.players[caster].hand = @[hail]
    game.players[caster].energy = 3
    check game.playCard(0)
    check game.players[caster].energy == 0
    check game.players[caster].discardPile == @[hail]
    check game.players[caster].board[0].currentToughness == bear.toughness
    check game.visualEvents.len == 0

  test "several minions on one board can die together":
    var game = newGame(Archer, Archer, 437)
    let
      caster = game.currentPlayer
      enemy = 1 - caster
      sniper = baseCard("Sniper", 2)
    game.players[enemy].board =
      @[readyMinion(enemy, 2, sniper), readyMinion(enemy, 3, sniper)]
    game.nextMinionId = 4
    game.players[caster].hand = @[baseCard("Hail of Arrows", 3)]
    game.players[caster].energy = 3
    check game.playCard(0)
    check game.players[enemy].board.len == 0
    check game.players[enemy].discardPile == @[sniper, sniper]
    var deaths: seq[Choice]
    for event in game.takeVisualEvents():
      if event.kind == DeathVfx: deaths.add event.target
    check deaths == @[creatureChoice(enemy, 2), creatureChoice(enemy, 3)]

suite "AWM Swords":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  proc swordsGame(seed: int64): (GameState, int, int) =
    ## The caster has two Bears and one Swords with energy to spare; the
    ## enemy has one Bear.
    var game = newGame(Warrior, Warrior, seed)
    let
      caster = game.currentPlayer
      enemy = 1 - caster
      bear = Warrior.classCard()
    game.players[caster].board =
      @[readyMinion(caster, 1, bear), readyMinion(caster, 2, bear)]
    game.players[enemy].board = @[readyMinion(enemy, 3, bear)]
    game.nextMinionId = 4
    game.players[caster].hand = @[baseCard("Swords", 2)]
    game.players[caster].energy = 5
    (game, caster, enemy)

  test "Swords is a no-target Warrior spell that gives +1/+0":
    let swords = baseCard("Swords", 2)
    check swords.class == some(Warrior)
    check swords.kind == Spell
    check not swords.needsChoice()
    check swords.ruleText() == "Give all friendly minions +1/+0."

  test "stat changes read as rules text":
    check printed(rules(addPowerToughness(0, 2,
      game.board.choose(kind: Minion)))) == "Give all minions +0/+2."
    check printed(rules(addPowerToughness(-1, 0,
      game.board.choose(kind: Minion, owner: AllOpponents)))) ==
      "Give all enemy minions -1/+0."

  test "Swords buffs every friendly minion and nothing else":
    var (game, caster, enemy) = swordsGame(503)
    let swords = baseCard("Swords", 2)
    check game.availableChoices(0).len == 0
    check game.playCard(0)
    check game.players[caster].energy == 3
    check game.players[caster].discardPile == @[swords]
    for minion in game.players[caster].board:
      check minion.power == 4
      check minion.currentToughness == 2
      # Buffs never touch the printed card, so it still serializes.
      check minion.card == Warrior.classCard()
    check game.players[enemy].board[0].power == 3
    check game.choiceLabel(creatureChoice(caster, 1)).endsWith("(4/2)")
    let events = game.takeVisualEvents()
    check events.len == 2
    check events[0].kind == SwordsIntoTheWindVfx
    check events[0].target == creatureChoice(caster, 1)
    check events[1].kind == SwordsIntoTheWindVfx
    check events[1].target == creatureChoice(caster, 2)

  test "Swords stacks and lasts across turns":
    var (game, caster, _) = swordsGame(509)
    game.players[caster].hand.add baseCard("Swords", 2)
    game.players[caster].energy = 4
    check game.playCard(0)
    check game.playCard(0)
    check game.players[caster].board[0].power == 5
    game.finishTurn()
    game.finishTurn()
    check game.players[caster].board[0].power == 5

  test "a buffed minion hits harder in combat and against heroes":
    var (game, caster, enemy) = swordsGame(521)
    check game.playCard(0)
    check game.attack(1, heroChoice(enemy))
    check game.players[enemy].life == StartingLife - 4
    # 4 damage kills the enemy Bear; it hits back for its own 3.
    check game.attack(2, creatureChoice(enemy, 3))
    check not game.minionLocation(3).found
    check not game.minionLocation(2).found

  test "a slain minion's death event carries its live power":
    var (game, caster, enemy) = swordsGame(523)
    check game.playCard(0)
    discard game.takeVisualEvents()
    game.finishTurn()
    check game.attack(3, creatureChoice(caster, 1))
    var deaths: seq[VisualEvent]
    for event in game.takeVisualEvents():
      if event.kind == DeathVfx: deaths.add event
    check deaths.len == 2
    for death in deaths:
      check death.power == (if death.target.owner == caster: 4 else: 3)
    check enemy == game.currentPlayer

  test "a bounced minion loses its buffs":
    var (game, caster, _) = swordsGame(541)
    check game.playCard(0)
    game.players[caster].hand = @[Mage.classCard()]
    game.players[caster].energy = 1
    check game.playCard(0, creatureChoice(caster, 1))
    check game.players[caster].hand == @[Warrior.classCard()]
    game.players[caster].energy = 2
    check game.playCard(0)
    let replayed = game.players[caster].board[^1]
    check replayed.card == Warrior.classCard()
    check replayed.power == 3

  test "Swords with no friendly minions still resolves":
    var game = newGame(Warrior, Warrior, 547)
    let caster = game.currentPlayer
    game.players[caster].hand = @[baseCard("Swords", 2)]
    game.players[caster].energy = 2
    check game.playCard(0)
    check game.players[caster].energy == 0
    check game.visualEvents.len == 0

  test "lowered toughness kills and power never drops below zero":
    var game = newGame(Warrior, Warrior, 557)
    let
      caster = game.currentPlayer
      enemy = 1 - caster
      bear = Warrior.classCard()
      wither = Card(name: "Wither", energyCost: 0, kind: Spell,
        rules: rules(addPowerToughness(-5, -2,
          game.board.choose(kind: Minion, owner: AllOpponents))))
    game.players[enemy].board = @[readyMinion(enemy, 1, bear)]
    game.nextMinionId = 2
    var sturdy = readyMinion(enemy, 2, bear)
    sturdy.currentToughness = 5
    game.players[enemy].board.add sturdy
    game.nextMinionId = 3
    game.players[caster].hand = @[wither]
    check game.playCard(0)
    check not game.minionLocation(1).found
    check game.players[enemy].discardPile == @[bear]
    check game.players[enemy].board[0].power == 0
    check game.players[enemy].board[0].currentToughness == 3

suite "AWM Duel and Shields":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  proc duelGame(seed: int64, mine, theirs: Card): (GameState, int, int) =
    ## Duel in hand; minion 1 on our side, minion 2 on theirs.
    var game = newGame(Warrior, Archer, seed)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[me].board = @[readyMinion(me, 1, mine)]
    game.players[enemy].board = @[readyMinion(enemy, 2, theirs)]
    game.nextMinionId = 3
    game.players[me].hand = @[baseCard("Duel", 2)]
    game.players[me].energy = 2
    (game, me, enemy)

  test "Duel and Shields print their rules":
    let duel = baseCard("Duel", 2)
    check duel.class == some(Warrior)
    check duel.kind == Spell
    check duel.needsChoice()
    check duel.targetCount() == 2
    check duel.helpsTarget(0)
    check not duel.helpsTarget(1)
    check duel.ruleText() == "Give a minion +1/+1.\n" &
      "A minion loses Ranged.\nThe first target fights the second target."
    let shields = baseCard("Shields", 1)
    check shields.class == some(Warrior)
    check not shields.needsChoice()
    check shields.ruleText() == "Give all friendly minions +0/+1."
    check printed(rules(fight(getTarget(1), getTarget(0)))) ==
      "The second target fights the first target."

  test "each Duel target offers every minion":
    let (game, me, enemy) =
      duelGame(601, Warrior.classCard(), baseCard("Sniper", 2))
    for picked in [newSeq[Choice](), @[creatureChoice(me, 1)]]:
      let choices = game.availableChoices(0, picked)
      check choices.len == 2
      check creatureChoice(me, 1) in choices
      check creatureChoice(enemy, 2) in choices

  test "Duel buffs, removes Ranged, then fights":
    var (game, me, enemy) =
      duelGame(607, Warrior.classCard(), baseCard("Sniper", 2))
    check game.playCard(0, @[creatureChoice(me, 1), creatureChoice(enemy, 2)])
    check game.players[me].energy == 0
    check game.players[me].discardPile == @[baseCard("Duel", 2)]
    # The Sniper lost Ranged first, so the buffed Bear's 4 killed it.
    check not game.minionLocation(2).found
    check game.players[enemy].discardPile == @[baseCard("Sniper", 2)]
    let bear = game.players[me].board[0]
    check bear.power == 4
    check bear.currentToughness == 1
    # A fight is not an attack.
    check not bear.hasAttacked
    var kinds: seq[VfxKind]
    for event in game.takeVisualEvents():
      kinds.add event.kind
    check kinds[0 .. 2] == @[SwordAndShieldVfx, MeleeVfx, SwordClashVfx]
    check DeathVfx in kinds

  test "fights respect Ranged":
    # The buffed Sniper keeps Ranged; the Sharpshooter loses it.
    var (game, me, enemy) =
      duelGame(613, baseCard("Sniper", 2), baseCard("Sharpshooter", 3))
    check game.playCard(0, @[creatureChoice(me, 1), creatureChoice(enemy, 2)])
    check not game.minionLocation(2).found
    check game.players[me].board[0].currentToughness == 2

  test "a minion can duel itself":
    var (game, me, _) =
      duelGame(617, Warrior.classCard(), baseCard("Sniper", 2))
    check game.playCard(0, @[creatureChoice(me, 1), creatureChoice(me, 1)])
    # 4/3 after the buff, then hit once by its own 4.
    check not game.minionLocation(1).found
    check Warrior.classCard() in game.players[me].discardPile

  test "Duel with one target chosen is canceled":
    var (game, me, _) =
      duelGame(619, Warrior.classCard(), baseCard("Sniper", 2))
    check not game.playCard(0, @[creatureChoice(me, 1)])
    check not game.playCard(0, creatureChoice(me, 1))
    check game.players[me].energy == 2
    check game.players[me].hand == @[baseCard("Duel", 2)]
    check game.players[me].board[0].power == 3
    check game.visualEvents.len == 0

  test "Duel needs a minion on the board":
    var game = newGame(Warrior, Warrior, 623)
    let me = game.currentPlayer
    game.players[me].hand = @[baseCard("Duel", 2)]
    game.players[me].energy = 2
    check game.availableChoices(0).len == 0
    check not game.playCard(0, @[NoTarget, NoTarget])
    check game.players[me].energy == 2

  test "a lost keyword lasts and shows in the target label":
    var (game, me, enemy) =
      duelGame(629, Warrior.classCard(), baseCard("Sniper", 2))
    game.players[enemy].board[0].currentToughness = 9
    check game.playCard(0, @[creatureChoice(me, 1), creatureChoice(enemy, 2)])
    let sniper = game.players[enemy].board[0]
    check sniper.lostKeywords == {Ranged}
    check not sniper.hasKeyword(Ranged)
    check sniper.card == baseCard("Sniper", 2)
    check game.choiceLabel(creatureChoice(enemy, 2)).endsWith(
      "(2/5, lost Ranged)")

  test "Shields raises every friendly minion's toughness":
    var game = newGame(Warrior, Warrior, 631)
    let
      me = game.currentPlayer
      enemy = 1 - me
      bear = Warrior.classCard()
    game.players[me].board = @[readyMinion(me, 1, bear)]
    game.players[me].board[0].currentToughness = 1
    game.players[enemy].board = @[readyMinion(enemy, 2, bear)]
    game.nextMinionId = 3
    game.players[me].hand = @[baseCard("Shields", 1)]
    game.players[me].energy = 1
    check game.playCard(0)
    check game.players[me].board[0].currentToughness == 2
    check game.players[enemy].board[0].currentToughness == 2
    let events = game.takeVisualEvents()
    check events.len == 1
    check events[0].kind == MightyShieldsVfx

suite "AWM Tactician, Footsoldier, Commander and Rally":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  test "the new Warrior cards print their rules":
    let
      tactician = baseCard("Tactician", 2)
      footsoldier = baseCard("Footsoldier", 1)
      commander = baseCard("Commander", 5)
      rally = baseCard("Rally", 5)
    check tactician.kind == Minion
    check tactician.power == 1
    check tactician.toughness == 2
    check tactician.needsChoice()
    check not tactician.helpsTarget(0)
    check tactician.ruleText() == "Give a minion -1/-0."
    check footsoldier.kind == Minion
    check footsoldier.power == 1
    check footsoldier.toughness == 2
    check footsoldier.ruleText().len == 0
    check commander.kind == Minion
    check commander.power == 2
    check commander.toughness == 3
    check not commander.needsChoice()
    check commander.ruleText() == "Summon 2 Footsoldiers."
    check rally.kind == Spell
    check not rally.needsChoice()
    check rally.ruleText() ==
      "Summon 2 Footsoldiers.\nGive all friendly minions +1/+0."
    check printed(rules(summon(1, "Footsoldier", AllOpponents))) ==
      "Summon a Footsoldier for each opponent."
    check baseCardNamed("Footsoldier") == footsoldier
    expect ValueError:
      discard baseCardNamed("Nobody")

  test "Tactician lowers a minion's power for good":
    var game = newGame(Warrior, Warrior, 701)
    let
      me = game.currentPlayer
      enemy = 1 - me
      bear = Warrior.classCard()
    game.players[enemy].board = @[readyMinion(enemy, 1, bear)]
    game.nextMinionId = 2
    game.players[me].hand = @[baseCard("Tactician", 2)]
    game.players[me].energy = 2
    check game.availableChoices(0) == @[creatureChoice(enemy, 1), NoTarget]
    check game.playCard(0, creatureChoice(enemy, 1))
    check game.players[enemy].board[0].power == 2
    check game.players[enemy].board[0].card == bear
    check game.players[me].board.len == 1
    let events = game.takeVisualEvents()
    check events.len == 1
    check events[0].kind == SwordBreakVfx
    game.finishTurn()
    game.finishTurn()
    check game.players[enemy].board[0].power == 2

  test "Tactician can weaken nothing or a friendly minion":
    var game = newGame(Warrior, Warrior, 709)
    let me = game.currentPlayer
    game.players[me].hand =
      @[baseCard("Tactician", 2), baseCard("Tactician", 2)]
    game.players[me].energy = 4
    check game.playCard(0, NoTarget)
    check game.players[me].board[0].power == 1
    let first = game.players[me].board[0].id
    check game.playCard(0, creatureChoice(me, first))
    check game.players[me].board[0].power == 0
    check game.players[me].board[1].power == 1

  test "Commander enters with two Footsoldiers that can't attack yet":
    var game = newGame(Warrior, Warrior, 719)
    let me = game.currentPlayer
    game.players[me].board = @[readyMinion(me, 1, Warrior.classCard())]
    game.nextMinionId = 2
    game.players[me].hand = @[baseCard("Commander", 5)]
    game.players[me].energy = 5
    check game.availableChoices(0).len == 0
    check game.playCard(0)
    check game.players[me].energy == 0
    let board = game.players[me].board
    check board.len == 4
    check board[1].card == baseCard("Commander", 5)
    check board[1].id == 2
    for index in 2 .. 3:
      check board[index].card == baseCard("Footsoldier", 1)
      check board[index].id == index + 1
      check board[index].owner == me
      check board[index].currentToughness == 2
      check not board[index].canAttack
    check game.nextMinionId == 5
    check game.eligibleAttackers() == @[1]
    game.finishTurn()
    game.finishTurn()
    check game.eligibleAttackers() == @[1, 2, 3, 4]

  test "Rally summons first, so its buff reaches the Footsoldiers":
    var game = newGame(Warrior, Warrior, 727)
    let
      me = game.currentPlayer
      enemy = 1 - me
      bear = Warrior.classCard()
      rally = baseCard("Rally", 5)
    game.players[me].board = @[readyMinion(me, 1, bear)]
    game.players[enemy].board = @[readyMinion(enemy, 2, bear)]
    game.nextMinionId = 3
    game.players[me].hand = @[rally]
    game.players[me].energy = 5
    check game.playCard(0)
    check game.players[me].discardPile == @[rally]
    check game.players[me].board.len == 3
    check game.players[me].board[0].power == 4
    for minion in game.players[me].board[1 .. 2]:
      check minion.card == baseCard("Footsoldier", 1)
      check minion.power == 2
    check game.players[enemy].board[0].power == 3
    check game.nextMinionId == 5
    var buffed: seq[Choice]
    for event in game.takeVisualEvents():
      if event.kind == SwordsIntoTheWindVfx:
        buffed.add event.target
    check buffed == @[creatureChoice(me, 1), creatureChoice(me, 3),
      creatureChoice(me, 4)]

  test "summons can enter under the opponent's control":
    var game = newGame(Warrior, Warrior, 733)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.nextMinionId = 7
    game.players[me].hand = @[Card(name: "Gift", energyCost: 0, kind: Spell,
      rules: rules(summon(1, "Footsoldier", AllOpponents)))]
    check game.playCard(0)
    check game.players[me].board.len == 0
    check game.players[enemy].board.len == 1
    check game.players[enemy].board[0].id == 7
    check game.players[enemy].board[0].owner == enemy
    check game.nextMinionId == 8

suite "AWM Oozification":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  proc oozeGame(seed: int64, toughness: int): (GameState, int, int) =
    ## Oozification in hand; an enemy Bear (id 1) at `toughness`.
    var game = newGame(Mage, Warrior, seed)
    let
      me = game.currentPlayer
      enemy = 1 - me
    var bear = readyMinion(enemy, 1, Warrior.classCard())
    bear.currentToughness = toughness
    game.players[enemy].board = @[bear]
    game.nextMinionId = 2
    game.players[me].hand = @[baseCard("Oozification", 4)]
    game.players[me].energy = 4
    (game, me, enemy)

  test "Ooze and Oozification print their rules":
    let
      ooze = baseCard("Ooze", 0)
      oozification = baseCard("Oozification", 4)
    check ooze.kind == Minion
    check ooze.energyCost == 0
    check ooze.power == 0
    check ooze.toughness == 1
    check ooze.ruleText().len == 0
    check oozification.class == some(Mage)
    check oozification.kind == Spell
    check oozification.needsChoice()
    check oozification.targetCount() == 1
    check oozification.ruleText() == "Destroy a minion.\n" &
      "Summon Oozes equal to the target's toughness for the target's owner."
    check printed(rules(summon(1, "Ooze", AllOpponents))) ==
      "Summon an Ooze for each opponent."
    check printed(rules(summon(2, "Ooze", You))) == "Summon 2 Oozes."
    # With several targets, getTarget says which one.
    check printed(rules(destroy(target({Minion})), destroy(target({Minion})),
      summon(getTarget(1).toughness, "Ooze"))) ==
      "Destroy a minion.\nDestroy a minion.\n" &
      "Summon Oozes equal to the second target's toughness."
    check printed(rules(summon(2, "Ooze"))) == "Summon 2 Oozes."

  test "Oozification destroys a minion and summons Oozes for its toughness":
    var (game, me, enemy) = oozeGame(801, 3)
    check game.availableChoices(0) == @[creatureChoice(enemy, 1)]
    check game.playCard(0, creatureChoice(enemy, 1))
    check game.players[me].energy == 0
    check game.players[me].discardPile == @[baseCard("Oozification", 4)]
    check not game.minionLocation(1).found
    check game.players[enemy].discardPile == @[Warrior.classCard()]
    # The Oozes go to the destroyed minion's owner.
    check game.players[me].board.len == 0
    check game.players[enemy].board.len == 3
    for index, ooze in game.players[enemy].board:
      check ooze.card == baseCard("Ooze", 0)
      check ooze.owner == enemy
      check ooze.id == index + 2
      check not ooze.canAttack
    check game.nextMinionId == 5
    let events = game.takeVisualEvents()
    check events[0].kind == OozeSplatVfx
    check events[0].target == creatureChoice(enemy, 1)
    check events[1].kind == DeathVfx

  test "Oozification counts current toughness, not printed":
    var (game, me, enemy) = oozeGame(809, 1)
    check game.playCard(0, creatureChoice(enemy, 1))
    check game.players[enemy].board.len == 1
    check game.players[enemy].board[0].card == baseCard("Ooze", 0)
    check game.players[me].board.len == 0

  test "Oozification on your own minion gives you the Oozes":
    var (game, me, enemy) = oozeGame(811, 2)
    game.players[me].board = @[readyMinion(me, 2, Warrior.classCard())]
    game.nextMinionId = 3
    check game.playCard(0, creatureChoice(me, 2))
    check game.players[me].discardPile.len == 2
    check game.players[me].board.len == 2
    check game.players[me].board[0].card == baseCard("Ooze", 0)
    check game.players[enemy].board.len == 1

  test "Oozification without a target is canceled":
    var game = newGame(Mage, Warrior, 821)
    let me = game.currentPlayer
    game.players[me].hand = @[baseCard("Oozification", 4)]
    game.players[me].energy = 4
    check game.availableChoices(0).len == 0
    check not game.playCard(0)
    check game.players[me].energy == 4
    check game.players[me].hand.len == 1
    check game.visualEvents.len == 0

  test "computed numbers print and resolve wherever a number is taken":
    let
      toll = Card(name: "Toll", energyCost: 0, kind: Spell, rules: rules(
        destroy(target({Minion})),
        damage(getTarget().toughness, target({Hero}))))
      grow = Card(name: "Grow", energyCost: 0, kind: Spell, rules: rules(
        addPowerToughness(getTarget().toughness, 0, target({Minion}))))
    check toll.ruleText() == "Destroy a minion.\n" &
      "Deal the first target's toughness damage to a hero."
    check grow.ruleText() ==
      "Give a minion +X/+0, where X is the target's toughness."
    check printed(rules(removePowerToughness(getTarget().toughness, 1,
      target({Minion})))) ==
      "Give a minion -X/-1, where X is the target's toughness."
    var (game, me, enemy) = oozeGame(823, 3)
    game.players[me].board = @[readyMinion(me, 2, Warrior.classCard())]
    game.nextMinionId = 3
    game.players[me].hand = @[toll, grow]
    # The Bear's toughness is read as it was before Toll destroyed it.
    check game.playCard(0, @[creatureChoice(enemy, 1), heroChoice(enemy)])
    check game.players[enemy].life == StartingLife - 3
    check game.players[enemy].board.len == 0
    check game.playCard(0, creatureChoice(me, 2))
    check game.players[me].board[0].power == 5

  test "getTarget can be both the number and the victim":
    let volley = Card(name: "Volley", energyCost: 0, kind: Spell, rules: rules(
      damage(1, target({Minion})),
      damage(1, target({Minion})),
      damage(getTarget(0).toughness, getTarget(1))))
    check volley.targetCount() == 2
    check volley.needsChoice()
    check volley.ruleText() == "Deal 1 damage to a minion.\n" &
      "Deal 1 damage to a minion.\n" &
      "Deal the first target's toughness damage to the second target."
    var game = newGame(Mage, Warrior, 827)
    let
      me = game.currentPlayer
      enemy = 1 - me
      bear = Warrior.classCard()
    game.players[enemy].board =
      @[readyMinion(enemy, 1, bear), readyMinion(enemy, 2, bear)]
    game.nextMinionId = 3
    game.players[me].hand = @[volley]
    # The first Bear's toughness (2) is read before any damage lands.
    check game.playCard(0, @[creatureChoice(enemy, 1), creatureChoice(enemy, 2)])
    check game.players[enemy].board.len == 1
    check game.players[enemy].board[0].id == 1
    check game.players[enemy].board[0].currentToughness == 1

suite "AWM computed query owners and card names":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  test "a board query can follow a target's owner":
    let purge = Card(name: "Purge", energyCost: 0, kind: Spell, rules: rules(
      destroy(target({Minion})),
      damage(1, game.board.choose(kind: Minion, owner: getTarget().owner))))
    check purge.ruleText() == "Destroy a minion.\n" &
      "Deal 1 damage to all minions the target's owner controls."
    check printed(rules(damage(1,
      game.board.choose(kind: Minion, owner: You)))) ==
      "Deal 1 damage to all friendly minions."
    var game = newGame(Mage, Warrior, 901)
    let
      me = game.currentPlayer
      enemy = 1 - me
      bear = Warrior.classCard()
    game.players[me].board = @[readyMinion(me, 1, bear)]
    game.players[enemy].board =
      @[readyMinion(enemy, 2, bear), readyMinion(enemy, 3, bear)]
    game.nextMinionId = 4
    game.players[me].hand = @[purge]
    check game.playCard(0, creatureChoice(enemy, 2))
    check not game.minionLocation(2).found
    check game.players[enemy].board[0].currentToughness == 1
    check game.players[me].board[0].currentToughness == 2

  test "summon names resolve on play; a misspelling fails the startup check":
    for card in baseCards:
      card.checkCardNames(baseCardNamed)
    let typo = Card(name: "Typo", energyCost: 0, kind: Spell,
      rules: rules(summon(1, "Footsodlier")))
    check typo.ruleText() == "Summon a Footsodlier."
    expect ValueError:
      typo.checkCardNames(baseCardNamed)

suite "AWM rule values":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  test "rule values are data a reader can inspect":
    let oozification = baseCard("Oozification", 4)
    let summon = SummonRule(oozification.rules[1])
    check summon.count.kind == ToughnessOf
    check summon.card.kind == CardNamed
    check summon.card.name == "Ooze"
    check summon.owner.kind == OwnerOf
    check PickedTarget(summon.owner.target).index == 0

  test "fixed numbers fold and computed ones combine":
    let folded = toRuleValue(2) + 3
    check folded.kind == FixedValue
    check folded.fixed == 5
    let grown = getTarget().toughness + 1
    check grown.kind == Sum
    check printed(rules(destroy(target({Minion})),
      summon(getTarget().toughness + 1, "Ooze"))) ==
      "Destroy a minion.\nSummon Oozes equal to the target's toughness plus 1."
    check printed(rules(damage(1, target({Minion})), damage(1, target({Minion})),
      damage(getTarget(0).power - 1, getTarget(1)))) ==
      "Deal 1 damage to a minion.\nDeal 1 damage to a minion.\n" &
      "Deal the first target's power minus 1 damage to the second target."

  test "a count reads how many cards a query matches":
    let rallyCry = Card(name: "Rally Cry", energyCost: 0, kind: Spell,
      rules: rules(damage(
        game.board.choose(kind: Minion, owner: You).count, target({Hero}))))
    check rallyCry.ruleText() ==
      "Deal the number of friendly minions damage to a hero."
    var game = newGame(Warrior, Mage, 911)
    let
      me = game.currentPlayer
      enemy = 1 - me
      bear = Warrior.classCard()
    game.players[me].board =
      @[readyMinion(me, 1, bear), readyMinion(me, 2, bear)]
    game.players[enemy].board = @[readyMinion(enemy, 3, bear)]
    game.nextMinionId = 4
    game.players[me].hand = @[rallyCry]
    check game.playCard(0, heroChoice(enemy))
    check game.players[enemy].life == StartingLife - 2

  test "power and sums resolve against live stats":
    let hunt = Card(name: "Hunt", energyCost: 0, kind: Spell, rules: rules(
      addPowerToughness(2, 0, target({Minion})),
      damage(getTarget().power + 1, target({Hero}))))
    var game = newGame(Warrior, Mage, 919)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[me].board = @[readyMinion(me, 1, Warrior.classCard())]
    game.nextMinionId = 2
    game.players[me].hand = @[hunt]
    # The buff hasn't applied when the damage is worked out: 3 + 1.
    check game.playCard(0, @[creatureChoice(me, 1), heroChoice(enemy)])
    check game.players[enemy].life == StartingLife - 4
    check game.players[me].board[0].power == 5

suite "AWM Plan, draws and triggers":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  proc planGame(seed: int64): (GameState, int, int) =
    ## Plan alone in hand, with energy for it.
    var game = newGame(Mage, Warrior, seed)
    let me = game.currentPlayer
    game.players[me].hand = @[baseCard("Plan", 3)]
    game.players[me].energy = 3
    (game, me, 1 - me)

  test "Plan is a trinket that prints its trigger as one sentence":
    let plan = baseCard("Plan", 3)
    check plan.kind == Trinket
    check plan.class == some(Mage)
    check not plan.needsChoice()
    check plan.targetCount() == 0
    check plan.ruleText() == "Draw 1 card.\n" &
      "At the start of your next turn, draw 1 card and destroy this card."
    check Mage.classCard() == baseCard("Bouncer", 1)

  test "draw and on read naturally":
    check printed(rules(draw(2))) == "Draw 2 cards."
    check printed(rules(draw(1, AllOpponents))) == "Each opponent draws 1 card."
    check printed(rules(destroy(target({Minion})),
      draw(getTarget().toughness, getTarget().owner))) ==
      "Destroy a minion.\n" &
      "The target's owner draws cards equal to the target's toughness."
    check printed(rules(on(nextTurn(AnyOpponent),
      draw(1), draw(2), destroy(self())))) ==
      "At the start of an opponent's next turn, " &
      "draw 1 card, draw 2 cards and destroy this card."

  test "Plan draws now, stays in play, and draws again next turn":
    var (game, me, enemy) = planGame(1001)
    let deck = game.players[me].deck.len
    check game.playCard(0)
    check game.players[me].energy == 0
    check game.players[me].hand.len == 1
    check game.players[me].deck.len == deck - 1
    check game.players[me].board.len == 1
    check game.players[me].board[0].card == baseCard("Plan", 3)
    check game.players[me].board[0].power == 0
    check game.eligibleAttackers().len == 0
    game.finishTurn()
    # The opponent's turn: Plan waits, and can't be attacked.
    check game.players[me].board.len == 1
    check game.players[me].hand.len == 1
    game.players[enemy].board = @[readyMinion(enemy, 50, Warrior.classCard())]
    game.nextMinionId = 51
    check game.attackTargets(50) == @[heroChoice(me)]
    game.finishTurn()
    # My next turn: the normal draw, then Plan's, then Plan is gone.
    check game.players[me].hand.len == 3
    check game.players[me].deck.len == deck - 3
    check game.players[me].board.len == 0
    check game.players[me].discardPile == @[baseCard("Plan", 3)]
    game.finishTurn()
    game.finishTurn()
    check game.players[me].hand.len == 4

  test "minion targets and minion effects ignore trinkets":
    var (game, me, enemy) = planGame(1003)
    check game.playCard(0)
    game.finishTurn()
    game.players[enemy].hand =
      @[Mage.classCard(), baseCard("Hail of Arrows", 3)]
    game.players[enemy].energy = 4
    check game.availableChoices(0) == @[NoTarget]
    check game.playCard(1)
    check game.players[me].board.len == 1

  test "a trinket that left play doesn't fire":
    var (game, me, _) = planGame(1005)
    check game.playCard(0)
    game.players[me].board.setLen(0)
    game.finishTurn()
    game.finishTurn()
    check game.players[me].hand.len == 2

  test "drawing from an empty deck loses the game":
    var (game, me, enemy) = planGame(1007)
    game.players[me].deck.setLen(0)
    check game.playCard(0)
    check game.gameOver
    check game.winner == enemy

  test "a trigger on the opponent's next turn fires one turn later, once":
    let omen = Card(name: "Omen", energyCost: 0, kind: Trinket,
      rules: rules(on(nextTurn(AnyOpponent), draw(1, AllOpponents))))
    var game = newGame(Mage, Warrior, 1009)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[me].hand = @[omen]
    check game.playCard(0)
    let enemyHand = game.players[enemy].hand.len
    game.finishTurn()
    check game.players[enemy].hand.len == enemyHand + 2
    game.finishTurn()
    game.finishTurn()
    check game.players[enemy].hand.len == enemyHand + 3
    check game.players[me].board.len == 1

  test "self() is the copy whose rules are running":
    let fleeting = Card(name: "Fleeting", energyCost: 0, kind: Minion,
      rules: rules(destroy(self())), power: 1, toughness: 1)
    check fleeting.ruleText() == "Destroy this card."
    var game = newGame(Mage, Warrior, 1011)
    let me = game.currentPlayer
    game.players[me].board = @[readyMinion(me, 1, fleeting)]
    game.nextMinionId = 2
    game.players[me].hand = @[fleeting]
    check game.playCard(0)
    check game.players[me].board.len == 1
    check game.players[me].board[0].id == 1

  test "every draw records its hand slot, turn draws and effects alike":
    var (game, me, _) = planGame(1015)
    proc draws(game: var GameState): seq[VisualEvent] =
      for event in game.takeVisualEvents():
        if event.kind == DrawVfx:
          result.add event
    check game.playCard(0)
    let played = game.draws()
    check played.len == 1
    check played[0].target == heroChoice(me)
    check (played[0].boardIndex, played[0].boardCount) == (0, 1)
    game.finishTurn()
    discard game.takeVisualEvents()
    game.finishTurn()
    # The turn draw, then Plan's, each into its own slot.
    let nextTurn = game.draws()
    check nextTurn.len == 2
    check (nextTurn[0].boardIndex, nextTurn[1].boardIndex) == (1, 2)
    check nextTurn[1].boardCount == 3

suite "AWM triggers that choose targets":
  let snare = Card(name: "Snare", energyCost: 0, kind: Trinket,
    rules: rules(on(nextTurn(You), damage(1, target({Minion})))))

  proc snareGame(seed: int64): (GameState, int, int) =
    ## Snare in play for `me`, an enemy Bear on the board, and the game
    ## advanced to the start of my next turn.
    var game = newGame(Mage, Warrior, seed)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[me].hand = @[snare]
    check game.playCard(0)
    game.players[enemy].board = @[readyMinion(enemy, 90, Warrior.classCard())]
    game.nextMinionId = 91
    game.finishTurn()
    game.finishTurn()
    (game, me, enemy)

  test "a trigger with a target waits for its owner, who sees a prompt":
    var (game, me, enemy) = snareGame(1101)
    check game.waitingTrigger
    check game.actingPlayer() == me
    check game.triggerChoices() == @[creatureChoice(enemy, 90), NoTarget]
    let waiting = game.waitingTriggerRules()
    check waiting.card.name == "Snare"
    check waiting.rules.targetPrompt(waiting.card, 0) ==
      ("Deal 1 damage to a minion.", "Choose a minion.")
    # Nothing else happens until it's answered.
    game.players[me].hand = @[Mage.classCard()]
    game.players[me].energy = 1
    check not game.canPlay(0)
    let turn = game.turnNumber
    game.finishTurn()
    check game.turnNumber == turn
    check game.resolvePendingTrigger(@[creatureChoice(enemy, 90)])
    check not game.waitingTrigger
    check game.players[enemy].board[0].currentToughness == 1
    check game.canPlay(0)

  test "an illegal pick is refused and no target is allowed":
    var (game, me, enemy) = snareGame(1103)
    check not game.resolvePendingTrigger(@[heroChoice(enemy)])
    check game.waitingTrigger
    check game.resolvePendingTrigger(@[NoTarget])
    check not game.waitingTrigger
    check game.players[enemy].board[0].currentToughness == 2
    check game.actingPlayer() == me

  test "with nothing legal to target, a trigger resolves by itself":
    var game = newGame(Mage, Warrior, 1105)
    let me = game.currentPlayer
    game.players[me].hand = @[snare]
    check game.playCard(0)
    game.finishTurn()
    game.finishTurn()
    check not game.waitingTrigger
    check game.currentPlayer == me

  test "a trigger on the opponent's turn waits for its owner, not them":
    let trap = Card(name: "Trap", energyCost: 0, kind: Trinket,
      rules: rules(on(nextTurn(AnyOpponent), damage(1, target({Minion})))))
    var game = newGame(Mage, Warrior, 1107)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[me].hand = @[trap]
    check game.playCard(0)
    game.players[enemy].board = @[readyMinion(enemy, 92, Warrior.classCard())]
    game.nextMinionId = 93
    game.finishTurn()
    check game.currentPlayer == enemy
    check game.actingPlayer() == me
    check game.eligibleAttackers().len == 0

suite "AWM presentation beats":
  test "Oozification's Oozes come a beat after its splat and destroy":
    var game = newGame(Mage, Warrior, 1201)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[enemy].board = @[readyMinion(enemy, 1, Warrior.classCard())]
    game.nextMinionId = 2
    game.players[me].hand = @[baseCard("Oozification", 4)]
    game.players[me].energy = 4
    check game.playCard(0, creatureChoice(enemy, 1))
    var
      splat = -1
      death = -1
      summons: seq[int]
    for event in game.takeVisualEvents():
      case event.kind
      of OozeSplatVfx: splat = event.beat
      of DeathVfx: death = event.beat
      of SummonVfx: summons.add event.beat
      else: discard
    check splat >= 0
    check death == splat
    check summons.len == 2
    check summons[0] == summons[1]
    check summons[0] > splat

  test "Plan's turn draw, its draw and its destroy are beats in that order":
    var game = newGame(Mage, Warrior, 1203)
    let me = game.currentPlayer
    game.players[me].hand = @[baseCard("Plan", 3)]
    game.players[me].energy = 3
    check game.playCard(0)
    game.finishTurn()
    discard game.takeVisualEvents()
    game.finishTurn()
    var kinds: seq[VfxKind]
    var beats: seq[int]
    for event in game.takeVisualEvents():
      if event.kind in {DrawVfx, DeathVfx}:
        kinds.add event.kind
        beats.add event.beat
    check kinds == @[DrawVfx, DrawVfx, DeathVfx]
    check beats[0] < beats[1]
    check beats[1] < beats[2]

  test "each card of a multi-card draw is its own beat":
    var game = newGame(Mage, Warrior, 1205)
    let me = game.currentPlayer
    game.players[me].hand = @[Card(name: "Study", energyCost: 0, kind: Spell,
      rules: rules(draw(2)))]
    check game.playCard(0)
    var beats: seq[int]
    for event in game.takeVisualEvents():
      if event.kind == DrawVfx:
        beats.add event.beat
    check beats.len == 2
    check beats[0] < beats[1]

suite "AWM Study and discards":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  proc studyGame(seed: int64): (GameState, int, int) =
    ## Study plus two cards in hand, energy for Study.
    var game = newGame(Mage, Warrior, seed)
    let me = game.currentPlayer
    game.players[me].hand =
      @[baseCard("Study", 2), baseCard("Bouncer", 1), baseCard("Plan", 3)]
    game.players[me].energy = 2
    (game, me, 1 - me)

  test "Study and toss print their rules":
    let study = baseCard("Study", 2)
    check study.kind == Spell
    check study.class == some(Mage)
    check not study.needsChoice()
    check study.ruleText() == "Draw 2 cards.\nDiscard 1 card."
    check printed(rules(toss(2, AllOpponents))) == "Each opponent discards 2 cards."
    check printed(rules(destroy(target({Minion})),
      toss(getTarget().toughness, getTarget().owner))) ==
      "Destroy a minion.\n" &
      "The target's owner discards cards equal to the target's toughness."

  test "Study draws, then waits for its player to pick a discard":
    var (game, me, _) = studyGame(1301)
    let deck = game.players[me].deck.len
    check game.playCard(0)
    check game.players[me].energy == 0
    check game.players[me].hand.len == 4
    check game.players[me].deck.len == deck - 2
    check game.players[me].discardPile == @[baseCard("Study", 2)]
    check game.waitingToss
    check game.waitingChoice
    check game.actingPlayer() == me
    check game.pendingToss.count == 1
    check game.pendingToss.source == "Study"
    check game.pendingToss.text == "Discard 1 card."
    check not game.canPlay(0)
    let turn = game.turnNumber
    game.finishTurn()
    check game.turnNumber == turn
    discard game.takeVisualEvents()
    let tossed = game.players[me].hand[1]
    check game.resolvePendingToss(@[1])
    check not game.waitingToss
    check game.players[me].hand.len == 3
    check game.players[me].discardPile == @[baseCard("Study", 2), tossed]
    var tosses: seq[VisualEvent]
    for event in game.takeVisualEvents():
      if event.kind == TossVfx:
        tosses.add event
    check tosses.len == 1
    check tosses[0].card == tossed
    check (tosses[0].handIndex, tosses[0].boardCount) == (1, 4)

  test "bad discard picks are refused and it keeps waiting":
    var (game, me, _) = studyGame(1303)
    check game.playCard(0)
    check not game.resolvePendingToss(@[])
    check not game.resolvePendingToss(@[0, 1])
    check not game.resolvePendingToss(@[9])
    check not game.resolvePendingToss(@[-1])
    check game.waitingToss
    check game.players[me].hand.len == 4

  test "a discard takes at most the hand, and none from an empty hand":
    var game = newGame(Mage, Warrior, 1305)
    let me = game.currentPlayer
    game.players[me].hand = @[
      Card(name: "Purge", energyCost: 0, kind: Spell, rules: rules(toss(3))),
      baseCard("Bouncer", 1)]
    check game.playCard(0)
    check game.pendingToss.count == 1
    check game.resolvePendingToss(@[0])
    check game.players[me].hand.len == 0
    game.players[me].hand = @[
      Card(name: "Purge", energyCost: 0, kind: Spell, rules: rules(toss(1)))]
    check game.playCard(0)
    check not game.waitingToss

  test "rules after a discard wait until it's chosen":
    var game = newGame(Mage, Warrior, 1307)
    let
      me = game.currentPlayer
      deck = game.players[me].deck.len
    game.players[me].hand = @[
      Card(name: "Swap", energyCost: 0, kind: Spell,
        rules: rules(toss(1), draw(1))),
      baseCard("Bouncer", 1)]
    check game.playCard(0)
    check game.waitingToss
    check game.pendingToss.remaining.len == 1
    check game.players[me].deck.len == deck
    check game.resolvePendingToss(@[0])
    # The draw came after the discard, so the drawn card stays in hand.
    check game.players[me].deck.len == deck - 1
    check game.players[me].hand.len == 1
    check game.players[me].hand[0] != baseCard("Bouncer", 1)

  test "an opponent's discard waits for the opponent":
    var game = newGame(Mage, Warrior, 1309)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[me].hand = @[Card(name: "Rot", energyCost: 0, kind: Spell,
      rules: rules(toss(1, AllOpponents)))]
    check game.playCard(0)
    check game.waitingToss
    check game.currentPlayer == me
    check game.actingPlayer() == enemy
    check game.resolvePendingToss(@[0])
    check game.players[enemy].discardPile.len == 1

  test "a discard inside a trigger holds the trigger queue":
    let grind = Card(name: "Grind", energyCost: 0, kind: Trinket,
      rules: rules(on(nextTurn(You), toss(1), draw(1))))
    var game = newGame(Mage, Warrior, 1311)
    let me = game.currentPlayer
    game.players[me].hand = @[grind]
    check game.playCard(0)
    game.finishTurn()
    game.finishTurn()
    check game.waitingToss
    check game.actingPlayer() == me
    let hand = game.players[me].hand.len
    check game.resolvePendingToss(@[0])
    check not game.waitingChoice
    check game.players[me].hand.len == hand

suite "AWM selections and Primordial":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  test "targets and queries are interchangeable; text follows the form":
    check printed(rules(bounce(target({Minion})))) ==
      "Return a minion to its owner's hand."
    check printed(rules(bounce(
      game.board.choose(kind: Minion, owner: AllOpponents)))) ==
      "Return all enemy minions to their owners' hands."
    check printed(rules(destroy(game.board.choose(kind: Minion)))) ==
      "Destroy all minions."
    check printed(rules(lose(ranged(),
      game.board.choose(kind: Minion, owner: AllOpponents)))) ==
      "All enemy minions lose Ranged."
    check printed(rules(removePowerToughness(1, 0,
      game.board.choose(kind: Minion, owner: AllOpponents)))) ==
      "Give all enemy minions -1/-0."
    check printed(rules(addPowerToughness(1, 1, target({Minion})))) ==
      "Give a minion +1/+1."

  test "choose filters in braces, self: false and no filter at all":
    check printed(rules(damage(1, game.board.choose({})))) ==
      "Deal 1 damage to all cards."
    check printed(rules(damage(1,
      game.board.choose({self: false, kind: Minion})))) ==
      "Deal 1 damage to all other minions."
    check printed(rules(damage(game.board.choose({self: false, owner: You}).count,
      target({Hero})))) ==
      "Deal the number of other friendly cards damage to a hero."
    check not compiles(rules(damage(1, game.board.choose({color: Minion}))))

  test "a query's owner filter is a pick, and reads as the hero itself":
    check printed(rules(bounce(game.board.choose({owner: target({Hero})})))) ==
      "Return all cards a hero controls to their owner's hand."
    check printed(rules(destroy(
      game.board.choose({kind: Minion, owner: target({Opponent})})))) ==
      "Destroy all minions an opponent controls."
    # One owner keeps the possessive singular; several keep it plural.
    check printed(rules(bounce(game.board.choose({kind: Minion, owner: You})))) ==
      "Return all friendly minions to their owner's hand."
    check printed(rules(bounce(game.board.choose({self: false})))) ==
      "Return all other cards to their owners' hands."
    # A picked card still names its owner; only players speak for themselves.
    check printed(rules(bounce(target({Minion})),
      damage(1, game.board.choose({owner: getTarget().owner})))) ==
      "Return a minion to its owner's hand.\n" &
      "Deal 1 damage to all cards the target's owner controls."

  test "Summon Primordial asks for a hero, clears its board and summons":
    let spell = baseCard("summon-primordial-8")
    check spell.kind == Spell
    check spell.class == some(Mage)
    check spell.ruleText() ==
      "Return all cards a hero controls to their owner's hand.\n" &
      "Summon a Primordial."
    check spell.needsChoice()
    check spell.targetCount() == 1
    check spell.targetPrompt(0).choose == "Choose a hero."
    var game = newGame(Mage, Warrior, 1401)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[me].board = @[readyMinion(me, 1, Mage.classCard())]
    game.players[enemy].board = @[readyMinion(enemy, 2, baseCard("Sniper", 2)),
      MinionState(id: 3, owner: enemy, card: Warrior.classCard(),
        currentToughness: 2, enteredTurn: game.turnNumber)]
    game.nextMinionId = 4
    game.players[me].hand = @[spell]
    game.players[me].energy = 8
    let aimed = game.availableChoices(0)
    check aimed.len == 2
    check heroChoice(me) in aimed
    check heroChoice(enemy) in aimed
    let enemyHand = game.players[enemy].hand.len
    check game.playCard(0, heroChoice(enemy))
    # The enemy board goes home; mine keeps its minion and gains Primordial.
    check game.players[enemy].board.len == 0
    check game.players[enemy].hand.len == enemyHand + 2
    check game.players[enemy].hand[^2 .. ^1] ==
      @[baseCard("Sniper", 2), Warrior.classCard()]
    check game.players[me].board.len == 2
    check game.players[me].board[0].card == Mage.classCard()
    let primordial = game.players[me].board[1]
    check primordial.card == baseCard("primordial-8")
    check primordial.power == 10
    check primordial.currentToughness == 10
    check not primordial.canAttack
    var bubbles, bounces, summons: int
    for event in game.takeVisualEvents():
      case event.kind
      of BubbleVfx: inc bubbles
      of BounceVfx: inc bounces
      of SummonVfx: inc summons
      else: discard
    check (bubbles, bounces, summons) == (2, 2, 1)

  test "Summon Primordial aimed at your own hero clears your side first":
    let spell = baseCard("summon-primordial-8")
    var game = newGame(Mage, Warrior, 1402)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[me].board = @[readyMinion(me, 1, Mage.classCard()),
      MinionState(id: 2, owner: me, card: baseCard("Plan", 3),
        enteredTurn: game.turnNumber)]
    game.players[enemy].board = @[readyMinion(enemy, 3, Warrior.classCard())]
    game.nextMinionId = 4
    game.players[me].hand = @[spell]
    game.players[me].energy = 8
    check game.playCard(0, heroChoice(me))
    check game.players[me].hand ==
      @[Mage.classCard(), baseCard("Plan", 3)]
    check game.players[me].board.len == 1
    check game.players[me].board[0].card == baseCard("primordial-8")
    check game.players[enemy].board.len == 1

  test "canceling the hero pick pays nothing and summons nothing":
    var game = newGame(Mage, Warrior, 1403)
    let me = game.currentPlayer
    game.players[me].hand = @[baseCard("summon-primordial-8")]
    game.players[me].energy = 8
    check not game.playCard(0, Canceled)
    check game.players[me].energy == 8
    check game.players[me].hand.len == 1
    check game.players[me].board.len == 0
    check game.takeVisualEvents().len == 0

  test "Primordial itself is a vanilla 10/10 that only Summon Primordial makes":
    let primordial = baseCard("primordial-8")
    check primordial.kind == Minion
    check primordial.class == some(Mage)
    check (primordial.power, primordial.toughness) == (10, 10)
    check primordial.rules.len == 0
    check primordial.ruleText() == ""
    check not primordial.needsChoice()

  test "query forms act on every match, and a spell has no self to skip":
    let sweep = Card(name: "Sweep", energyCost: 0, kind: Spell, rules: rules(
      lose(ranged(), game.board.choose(kind: Minion, owner: AllOpponents)),
      removePowerToughness(1, 0,
        game.board.choose(kind: Minion, owner: AllOpponents)),
      destroy(game.board.choose({self: false, owner: You}))))
    var game = newGame(Mage, Archer, 1403)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[me].board = @[readyMinion(me, 1, Warrior.classCard())]
    game.players[enemy].board = @[readyMinion(enemy, 2, baseCard("Sniper", 2)),
      readyMinion(enemy, 3, baseCard("Sharpshooter", 3))]
    game.nextMinionId = 4
    game.players[me].hand = @[sweep]
    check game.playCard(0)
    check game.players[me].board.len == 0
    for minion in game.players[enemy].board:
      check minion.lostKeywords == {Ranged}
    check game.players[enemy].board[0].power == 1
    check game.players[enemy].board[1].power == 2

suite "AWM attack triggers and Bubble Shield":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  proc shieldGame(seed: int64): (GameState, int, int) =
    ## My Bubble Shield resolved, then the enemy's turn with two ready Bears.
    var game = newGame(Mage, Warrior, seed)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[me].hand = @[baseCard("Bubble Shield", 2)]
    game.players[me].energy = 2
    check game.playCard(0)
    game.finishTurn()
    game.players[enemy].board = @[readyMinion(enemy, 50, Warrior.classCard()),
      readyMinion(enemy, 51, Warrior.classCard())]
    game.nextMinionId = 52
    (game, me, enemy)

  test "Bubble, Bubble Shield and attacked triggers print their rules":
    let
      bubble = baseCard("Bubble", 0)
      shield = baseCard("Bubble Shield", 2)
    check bubble.kind == Trinket
    check bubble.targetCount() == 0
    check not bubble.needsChoice()
    check bubble.ruleText() == "When your hero is attacked, " &
      "return the attacker to its owner's hand and destroy this card."
    check shield.kind == Spell
    check shield.ruleText() == "Summon 2 Bubbles."
    check printed(rules(on(attacked(AnyOpponent), draw(1)))) ==
      "When an opponent's hero is attacked, draw 1 card."
    check printed(rules(on(attacked(self()), damage(1, getAttacker())))) ==
      "When this card is attacked, deal 1 damage to the attacker."

  test "Bubble Shield summons two Trinkets":
    var game = newGame(Mage, Warrior, 1501)
    let me = game.currentPlayer
    game.players[me].hand = @[baseCard("Bubble Shield", 2)]
    game.players[me].energy = 2
    check game.playCard(0)
    check game.players[me].board.len == 2
    for bubble in game.players[me].board:
      check bubble.card == baseCard("Bubble", 0)
      check bubble.currentToughness == 0
      check bubble.power == 0
    check game.eligibleAttackers().len == 0
    var summons = 0
    for event in game.takeVisualEvents():
      if event.kind == SummonVfx:
        inc summons
    check summons == 2

  test "each attack on your hero pops one Bubble, after the damage":
    var (game, me, enemy) = shieldGame(1503)
    let first = game.players[me].board[0].id
    let second = game.players[me].board[1].id
    check game.attack(50, heroChoice(me))
    check game.players[me].life == StartingLife - 3
    check not game.minionLocation(50).found
    check game.players[enemy].hand[^1] == Warrior.classCard()
    check game.players[me].board.len == 1
    check game.players[me].board[0].id == second
    check not game.minionLocation(first).found
    check game.players[me].discardPile[^1] == baseCard("Bubble", 0)
    check game.attack(51, heroChoice(me))
    check game.players[me].life == StartingLife - 6
    check game.players[me].board.len == 0
    check game.players[enemy].board.len == 0

  test "attacks on your minions don't fire Bubbles":
    var (game, me, _) = shieldGame(1505)
    game.players[me].board.add readyMinion(me, 60, Mage.classCard())
    check game.attack(50, creatureChoice(me, 60))
    check game.players[me].board.len == 2
    check game.minionLocation(50).found

  test "a card's own attacked trigger punishes its attacker":
    let thorns = Card(name: "Thorns", energyCost: 0, kind: Minion,
      rules: rules(on(attacked(self()), damage(1, getAttacker()))),
      power: 1, toughness: 5)
    var game = newGame(Mage, Warrior, 1507)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[me].board = @[readyMinion(me, 1, thorns)]
    game.nextMinionId = 2
    game.finishTurn()
    game.players[enemy].board = @[readyMinion(enemy, 50, Warrior.classCard())]
    game.nextMinionId = 51
    check game.attack(50, creatureChoice(me, 1))
    # 1 from combat, then 1 from Thorns: the Bear (toughness 2) dies.
    check not game.minionLocation(50).found
    check game.players[me].board[0].currentToughness == 2

  test "a trigger whose attacker died in combat fizzles entirely":
    let spite = Card(name: "Spite", energyCost: 0, kind: Minion,
      rules: rules(on(attacked(self()), damage(1, getAttacker()), draw(1))),
      power: 5, toughness: 5)
    var game = newGame(Mage, Warrior, 1509)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[me].board = @[readyMinion(me, 1, spite)]
    game.nextMinionId = 2
    game.finishTurn()
    game.players[enemy].board = @[readyMinion(enemy, 50, Warrior.classCard())]
    game.nextMinionId = 51
    let hand = game.players[me].hand.len
    check game.attack(50, creatureChoice(me, 1))
    check not game.minionLocation(50).found
    # The attacker is gone, so the whole trigger fizzles: no draw either.
    check game.players[me].hand.len == hand
