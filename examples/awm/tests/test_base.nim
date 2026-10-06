import
  std/[options, sequtils],
  ../src/core/[bots, match, replays, sim]

const BaseBot = staticRead("../players/base.bas")

proc fixture(seed: int64): BotMatch =
  ## Gives the reference script a deterministic four-seat test match.
  result = initBotMatch(@[Mage, Mage, Mage, Mage], seed,
    loadBots(newSeqWith(4, BaseBot)), 28_800)
  result.game.currentPlayer = 0
  result.game.players[0].hand.setLen(0)
  result.game.players[0].energy = 9
  result.game.players[0].totalEnergy = 9

proc ready(owner, id: int, name: string): MinionState =
  ## Creates a ready permanent with its printed stats.
  let card = baseCardNamed(name)
  MinionState(owner: owner, id: id, card: card,
    currentToughness: (if card.kind == Minion: card.toughness else: 0),
    canAttack: true)

echo "The reference script randomly selects all three classes reproducibly"
block:
  var selected: set[HeroClass]
  for seed in 0 ..< 32:
    let
      first = loadBots(newSeqWith(4, BaseBot)).chooseBotClasses(seed)
      second = loadBots(newSeqWith(4, BaseBot)).chooseBotClasses(seed)
    doAssert first == second
    for heroClass in first:
      selected.incl heroClass
  doAssert selected == {Archer, Warrior, Mage}

echo "The reference script targets heroes and minions across all opponents"
block:
  var
    kinds: set[ChoiceKind]
    owners: set[range[1 .. 3]]
  for seed in 0 ..< 48:
    var played = fixture(seed)
    played.game.players[0].board = @[ready(0, 1, "Primordial")]
    for player in 1 .. 3:
      played.game.players[player].board = @[ready(player, player + 1, "Bear")]
    played.game.nextMinionId = 5
    doAssert played.step()
    let action = played.bots[0].action
    doAssert action.kind == ActionAttack
    let target = action.choices[0].toChoice
    kinds.incl target.kind
    owners.incl target.owner
  doAssert kinds == {HeroChoice, CreatureChoice}
  doAssert owners == {1, 2, 3}

echo "The reference script plays cards, chooses targets, and ends explicitly"
block:
  var played = fixture(1)
  played.game.players[0].hand = @[baseCardNamed("Ooze")]
  doAssert played.step()
  doAssert played.bots[0].action.kind == ActionPlayCard
  doAssert played.step()
  doAssert played.bots[0].action.kind == ActionEndTurn
block:
  var bouncedSelf = false
  for seed in 0 ..< 16:
    var played = fixture(seed)
    played.game.players[0].hand = @[baseCardNamed("Bouncer")]
    doAssert played.step()
    doAssert played.bots[0].action.kind == ActionPlayCard
    bouncedSelf = bouncedSelf or played.game.players[0].board.len == 0
  doAssert bouncedSelf
block:
  var played = fixture(3)
  played.game.players[0].hand = @[baseCardNamed("Duel")]
  played.game.players[0].board = @[ready(0, 1, "Bear")]
  played.game.players[0].board[0].canAttack = false
  played.game.players[2].board = @[ready(2, 2, "Bear")]
  played.game.nextMinionId = 3
  doAssert played.step()
  doAssert played.bots[0].action.kind == ActionPlayCard
  doAssert played.bots[0].action.choices.len == 2

echo "The reference script chooses discards and off-turn trigger targets"
block:
  var played = fixture(6)
  played.game.players[2].hand = @[
    baseCardNamed("Bouncer"), baseCardNamed("Ooze"), baseCardNamed("Primordial")]
  played.game.pendingToss = PendingToss(player: 2, count: 2)
  doAssert played.step()
  doAssert played.bots[2].action.kind == ActionToss
  doAssert played.bots[2].action.indices.len == 2
  doAssert played.bots[2].action.indices[0] != played.bots[2].action.indices[1]
block:
  var played = fixture(9)
  let snare = Card(name: "Snare", kind: Trinket, class: some(Mage),
    rules: rules(on(nextTurn(You), damage(1, target({TargetKind.Minion})))))
  played.game.players[2].board = @[
    MinionState(id: 1, owner: 2, card: snare)]
  played.game.players[0].board = @[ready(0, 2, "Bear")]
  played.game.pendingTriggers = @[
    PendingTrigger(owner: 2, sourceId: 1, trigger: 0)]
  played.game.nextMinionId = 3
  doAssert played.step()
  doAssert played.bots[2].action.kind == ActionResolveTrigger
  doAssert not played.game.waitingTrigger

echo "Reference policy action coverage passed"
