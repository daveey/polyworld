## Deterministic AWM simulation shared by native, browser and server builds.
import std/[algorithm, random]
import core, baseset
export core, baseset

const
  PlayerCount* = 2
  StartingLife* = 20
  StartingHandSize* = 5

type
  MinionState* = object
    id*: int
    owner*: int
    card*: Card
    currentToughness*: int
    bonusPower*: int  ## Permanent power change on top of the printed power.
    lostKeywords*: set[Keyword]  ## Keywords lost while on the board.
    enteredTurn*: int  ## The turn it entered play, for next-turn triggers.
    firedTurnTriggers*: set[uint8]
      ## Its next-turn triggers (by index) that already fired: each fires
      ## once.
    canAttack*: bool
    hasAttacked*: bool

  PlayerState* = object
    heroClass*: HeroClass
    life*: int
    totalEnergy*: int
    energy*: int
    deck*: seq[Card]
    hand*: seq[Card]
    discardPile*: seq[Card]
    board*: seq[MinionState]
    dead*: bool
      ## Out of the match: no actions, no turns; cards in play stay.
    drewFromEmpty*: bool
      ## Tried to draw from an empty deck; dies when deaths are settled.

  VisualEvent* = object
    ## Snapshot the target before damage/bounce can remove or rearrange it.
    kind*: VfxKind
    target*: Choice
    boardIndex*, boardCount*: int
      ## A minion's board slot and board size; for DrawVfx, the hand slot
      ## drawn into and the hand size after the draw.
    card*: Card  ## The slain or bounced minion's card, for DeathVfx/BounceVfx.
    handIndex*: int  ## Where a bounced card lands in its hand, for BounceVfx.
    power*: int  ## The slain minion's live power, for DeathVfx.
    beat*: int
      ## Events of one beat present together; each beat waits for the one
      ## before it (draw beats only wait a moment, so draws overlap).

  PendingTrigger* = object
    ## A fired `on(...)` trigger, queued until it resolves. One that asks for
    ## targets waits for its owner to choose them.
    owner*: int     ## Who chooses, and who the rules resolve for.
    sourceId*: int  ## The card in play whose trigger fired.
    trigger*: int   ## Which of that card's `on(...)` rules.
    attacker*: Choice  ## The attacker, when an attack fired it.

  PendingToss* = object
    ## A discard waiting for its player to choose cards from hand. Whatever
    ## else the resolution does waits with it. Nothing waits when count is 0.
    player*: int
    count*: int  ## Already capped at the hand size.
    source*, text*: string  ## The asking card and its rule, for prompts.
    remaining*: seq[Effect]  ## The resolution's later effects, in order.

  GameState* = object
    players*: seq[PlayerState]
      ## One per seat: PlayerCount in a duel, more in a multiplayer match.
    pendingToss*: PendingToss
    visualBeat*: int  ## The beat new visual events belong to.
    pendingTriggers*: seq[PendingTrigger]
      ## While not empty, the first one's owner must act before anyone else.
    currentPlayer*: int
    turnNumber*: int
    nextMinionId*: int
    visualEvents*: seq[VisualEvent]
    gameOver*: bool
    winner*: int
    rng: Rand

proc copyGameState*(game: GameState): GameState {.noinline.} =
  ## Own the sequences before another subsystem mutates the live state.
  ## A borrowed local alias can otherwise outlive a reallocated board in ARC.
  result = game

proc power*(minion: MinionState): int =
  ## Live power: printed power plus permanent changes, never below 0.
  if minion.card.kind != Minion: 0
  else: max(0, minion.card.power + minion.bonusPower)

proc keywords*(minion: MinionState): set[Keyword] =
  ## Live keywords: the printed ones minus any the minion lost.
  minion.card.keywords() - minion.lostKeywords

proc hasKeyword*(minion: MinionState, keyword: Keyword): bool =
  keyword in minion.keywords()

proc combatDamage(source, target: MinionState): int =
  ## Ranged minions take no combat damage from non-ranged minions.
  if target.hasKeyword(Ranged) and not source.hasKeyword(Ranged):
    0
  else:
    source.power

proc refillEnergy*(player: var PlayerState) =
  ## At the start of a player's turn: one more energy, and all of it back.
  inc player.totalEnergy
  player.energy = player.totalEnergy

proc drawCard*(player: var PlayerState): bool =
  if player.deck.len == 0:
    return false
  player.hand.add player.deck.pop()
  true

proc initPlayer(
    heroClass: HeroClass,
    rng: var Rand
): PlayerState =
  result.heroClass = heroClass
  result.life = StartingLife
  result.deck = heroClass.baseDeck()
  rng.shuffle(result.deck)
  for _ in 0 ..< StartingHandSize:
    discard result.drawCard()

proc playerCount*(game: GameState): int =
  game.players.len

proc dead*(game: GameState, player: int): bool =
  game.players[player].dead

proc nextPlayer*(game: GameState, player: int): int =
  ## The living player after `player`: dead players' turns are skipped.
  result = (player + 1) mod game.playerCount
  for step in 1 .. game.playerCount:
    let candidate = (player + step) mod game.playerCount
    if not game.dead(candidate):
      return candidate

proc resolveTriggers(game: var GameState) {.gcsafe.}
proc drawVisibly(game: var GameState, player: int): bool {.gcsafe.}
proc applyEffects(game: var GameState, effects: openArray[Effect]) {.gcsafe.}

proc checkWinCondition*(game: var GameState) =
  ## Settles deaths. Every player at 0 life or below, or who drew from an
  ## empty deck, dies at once: their hand is discarded one card at a time
  ## while their hero falls, and their cards in play stay. When one player
  ## is left standing they win; when nobody is, the current player does.
  if game.gameOver: return
  var dying: seq[int]
  for player in 0 ..< game.playerCount:
    let state = game.players[player]
    if not state.dead and (state.life <= 0 or state.drewFromEmpty):
      dying.add player
  if dying.len == 0: return
  inc game.visualBeat
  for player in dying:
    game.players[player].dead = true
    game.visualEvents.add VisualEvent(kind: HeroDeathVfx,
      target: heroChoice(player), beat: game.visualBeat)
  for player in dying:
    # One beat per card, last card first, so each leaves from its own slot.
    while game.players[player].hand.len > 0:
      inc game.visualBeat
      let
        index = game.players[player].hand.high
        card = game.players[player].hand[index]
      game.visualEvents.add VisualEvent(kind: TossVfx,
        target: heroChoice(player), card: card, handIndex: index,
        boardCount: game.players[player].hand.len, beat: game.visualBeat)
      game.players[player].hand.delete(index)
      game.players[player].discardPile.add card
  var living: seq[int]
  for player in 0 ..< game.playerCount:
    if not game.dead(player):
      living.add player
  if living.len <= 1:
    game.gameOver = true
    game.winner = if living.len == 1: living[0] else: game.currentPlayer
    game.pendingTriggers.setLen(0)
    game.pendingToss = PendingToss()
    return
  if game.pendingToss.count > 0 and game.dead(game.pendingToss.player):
    # A dead player's discard is moot: their hand is gone. The rest of its
    # resolution goes on.
    let remaining = game.pendingToss.remaining
    game.pendingToss = PendingToss()
    game.applyEffects(remaining)

proc beginTurn*(game: var GameState) =
  if game.gameOver: return
  let playerIndex = game.currentPlayer
  game.players[playerIndex].refillEnergy()
  if game.turnNumber > 1:
    inc game.visualBeat
    if not game.drawVisibly(playerIndex):
      game.players[playerIndex].drewFromEmpty = true
      game.checkWinCondition()
  if game.gameOver or game.dead(playerIndex): return
  for minion in game.players[playerIndex].board.mitems:
    minion.canAttack = true
    minion.hasAttacked = false
  game.resolveTriggers()

proc newGame*(
    classes: openArray[HeroClass],
    seed: int64
): GameState =
  ## One seat per class, dealt in order; a random seat goes first.
  result.rng = initRand(seed)
  for heroClass in classes:
    result.players.add initPlayer(heroClass, result.rng)
  result.currentPlayer = result.rng.rand(classes.len - 1)
  result.turnNumber = 1
  result.nextMinionId = 1
  result.winner = -1
  result.beginTurn()

proc newGame*(
    firstClass,
    secondClass: HeroClass,
    seed: int64
): GameState =
  newGame([firstClass, secondClass], seed)

proc waitingTrigger*(game: GameState): bool =
  ## A fired trigger is waiting for its owner to choose targets.
  game.pendingTriggers.len > 0

proc waitingToss*(game: GameState): bool =
  ## A discard is waiting for its player to choose cards.
  game.pendingToss.count > 0

proc waitingChoice*(game: GameState): bool =
  ## Someone must choose before play goes on: a discard, or a trigger.
  game.waitingToss or game.waitingTrigger

proc actingPlayer*(game: GameState): int =
  ## Who must act next: a waiting discard's player, then a waiting trigger's
  ## owner, else the current player.
  if game.waitingToss: game.pendingToss.player
  elif game.waitingTrigger: game.pendingTriggers[0].owner
  else: game.currentPlayer

proc canPlay*(game: GameState, cardIndex: int): bool =
  let player = game.players[game.currentPlayer]
  not game.waitingChoice and not player.dead and not game.gameOver and
    cardIndex >= 0 and
    cardIndex < player.hand.len and
    player.hand[cardIndex].energyCost <= player.energy

proc minionLocation*(
    game: GameState,
    minionId: int
): tuple[found: bool, player, index: int] =
  for playerIndex in 0 ..< game.playerCount:
    for minionIndex, minion in game.players[playerIndex].board:
      if minion.id == minionId:
        return (true, playerIndex, minionIndex)

proc ruleContext(
    game: GameState,
    picks: seq[Choice] = @[],
    allowNoTarget = false,
    sourcePlayer = -1,
    sourceId = 0
): RuleContext =
  ## `picks` answers the card's targets in order; a missing one cancels.
  ## Rules run for the current player unless `sourcePlayer` says otherwise.
  result.sourcePlayer =
    if sourcePlayer >= 0: sourcePlayer else: game.currentPlayer
  result.sourceId = sourceId
  result.allowNoTarget = allowNoTarget
  result.picks = picks
  result.cardNamed = baseCardNamed
  result.game.nextMinionId = game.nextMinionId
  result.seats = game.playerCount
  for playerIndex in 0 ..< game.playerCount:
    if not game.dead(playerIndex):
      result.heroes.add heroChoice(playerIndex)
    for minion in game.players[playerIndex].board:
      # Trinkets are on the board but aren't minions to target.
      if minion.card.kind == Minion:
        result.creatures.add creatureChoice(playerIndex, minion.id)
      result.game.board.add BoardCard(
        choice: creatureChoice(playerIndex, minion.id), card: minion.card,
        power: minion.power, toughness: minion.currentToughness)

proc availableChoices*(
    game: GameState,
    card: Card,
    picked: seq[Choice] = @[]
): seq[Choice] =
  ## Legal choices for the card's next target, after the `picked` ones.
  var context = game.ruleContext()
  context.targets = picked
  result = card.choices(context, picked.len)
  if card.kind != Spell and card.needsChoice():
    result.add NoTarget

proc availableChoices*(
    game: GameState,
    cardIndex: int,
    picked: seq[Choice] = @[]
): seq[Choice] =
  if cardIndex < 0 or
      cardIndex >= game.players[game.currentPlayer].hand.len:
    return
  game.availableChoices(
    game.players[game.currentPlayer].hand[cardIndex], picked
  )

proc playerName*(game: GameState, player: int,
    names: openArray[string] = []): string =
  ## Uses the public seat name, falling back to numbered local players.
  if player in 0 ..< names.len and names[player].len > 0:
    names[player]
  else:
    "Player " & $(player + 1)

proc choiceLabel*(game: GameState, choice: Choice,
    names: openArray[string] = []): string =
  ## Labels a target using the same public names as the match HUD.
  case choice.kind
  of CanceledChoice:
    "Cancel"
  of NoTargetChoice:
    "No target"
  of HeroChoice:
    game.playerName(choice.owner, names) & " " &
      game.players[choice.owner].heroClass.className() & " hero"
  of CreatureChoice:
    let location = game.minionLocation(choice.creatureId)
    if not location.found:
      return "Missing minion"
    let minion = game.players[location.player].board[location.index]
    var stats = $minion.power & "/" & $minion.currentToughness
    for keyword in minion.lostKeywords:
      stats.add ", lost " & $keyword
    game.playerName(location.player, names) & "'s " & minion.card.name &
      " (" & stats & ")"

proc recordVisual(game: var GameState, kind: VfxKind, target: Choice,
    card = Card(), power = 0) =
  if kind == NoVfx: return
  var event = VisualEvent(kind: kind, target: target, card: card, power: power,
    beat: game.visualBeat)
  case target.kind
  of HeroChoice:
    if target.owner < 0 or target.owner >= game.playerCount: return
  of CreatureChoice:
    let location = game.minionLocation(target.creatureId)
    if not location.found or location.player != target.owner: return
    event.boardIndex = location.index
    event.boardCount = game.players[location.player].board.len
  else:
    return
  game.visualEvents.add event

proc drawVisibly(game: var GameState, player: int): bool {.gcsafe.} =
  ## Draws a card and records where it landed, so every draw (turn or
  ## effect) animates the same way. The dead draw nothing.
  if game.dead(player):
    return true
  if not game.players[player].drawCard():
    return false
  game.visualEvents.add VisualEvent(kind: DrawVfx, target: heroChoice(player),
    beat: game.visualBeat,
    boardIndex: game.players[player].hand.high,
    boardCount: game.players[player].hand.len)
  true

proc takeVisualEvents*(game: var GameState): seq[VisualEvent] =
  ## Presentation consumes each event once; it never delays or changes rules.
  result = move(game.visualEvents)

proc destroyMinion(game: var GameState, player, index: int) =
  ## Sends a minion to its owner's discard pile.
  let minion = game.players[player].board[index]
  game.recordVisual(DeathVfx, creatureChoice(player, minion.id),
    minion.card, minion.power)
  game.players[player].board.delete(index)
  game.players[player].discardPile.add minion.card

proc destroyIfSlain(game: var GameState, player, index: int) =
  ## A minion at 0 toughness dies.
  if game.players[player].board[index].currentToughness <= 0:
    game.destroyMinion(player, index)

proc damageMinion(game: var GameState, minionId, amount: int) =
  let location = game.minionLocation(minionId)
  if not location.found:
    return
  if amount > 0:
    game.recordVisual(DamageFlashVfx, creatureChoice(location.player, minionId))
  game.players[location.player].board[location.index].currentToughness -=
    amount
  game.destroyIfSlain(location.player, location.index)

proc applyEffects(game: var GameState, effects: openArray[Effect]) {.gcsafe.} =
  ## Each resolution starts a new beat, and so does each rule within it.
  ## A discard stops here until its player chooses; the effects after it
  ## wait in `pendingToss`.
  var beat = low(int)
  for index, effect in effects:
    if effect.beat != beat:
      beat = effect.beat
      inc game.visualBeat
    case effect.kind
    of TargetVfxEffect:
      game.recordVisual(effect.targetVfx, effect.visualTarget)
    of DamageHeroEffect:
      if effect.heroDamage > 0 and game.players[effect.heroPlayer].life > 0:
        game.recordVisual(DamageFlashVfx, heroChoice(effect.heroPlayer))
      game.players[effect.heroPlayer].life = max(
        0,
        game.players[effect.heroPlayer].life - effect.heroDamage
      )
    of DamageCreatureEffect:
      game.damageMinion(effect.damagedCreatureId, effect.creatureDamage)
    of LoseKeywordEffect:
      let location = game.minionLocation(effect.keywordLoserId)
      if location.found:
        game.players[location.player].board[location.index].lostKeywords.incl(
          effect.lostKeyword)
    of FightEffect:
      let
        fighter = game.minionLocation(effect.fighterId)
        opponent = game.minionLocation(effect.opponentId)
      if not fighter.found or not opponent.found:
        continue
      let
        a = game.players[fighter.player].board[fighter.index]
        b = game.players[opponent.player].board[opponent.index]
      if a.id == b.id:
        # A minion fighting itself is hit once, by its own power.
        game.damageMinion(a.id, combatDamage(a, a))
      else:
        # Both hits land at once, from the stats before either one.
        let
          toOpponent = combatDamage(a, b)
          toFighter = combatDamage(b, a)
        game.damageMinion(b.id, toOpponent)
        game.damageMinion(a.id, toFighter)
    of ModifyStatsEffect:
      let location = game.minionLocation(effect.modifiedCreatureId)
      if not location.found:
        continue
      game.players[location.player].board[location.index].bonusPower +=
        effect.powerChange
      game.players[location.player].board[location.index].currentToughness +=
        effect.toughnessChange
      game.destroyIfSlain(location.player, location.index)
    of SummonEffect:
      game.players[effect.summonedOwner].board.add MinionState(
        id: effect.summonedId, owner: effect.summonedOwner,
        card: effect.summonedCard,
        currentToughness:
          if effect.summonedCard.kind == Minion: effect.summonedCard.toughness
          else: 0,
        enteredTurn: game.turnNumber)
      game.recordVisual(SummonVfx,
        creatureChoice(effect.summonedOwner, effect.summonedId))
      game.nextMinionId = max(game.nextMinionId, effect.summonedId + 1)
    of DrawEffect:
      for drawn in 0 ..< effect.drawCount:
        if drawn > 0:
          inc game.visualBeat  # Each card is its own draw.
        if not game.drawVisibly(effect.drawPlayer):
          game.players[effect.drawPlayer].drewFromEmpty = true
          break
    of TossEffect:
      let count = min(effect.tossCount,
        game.players[effect.tossPlayer].hand.len)
      if count > 0:
        game.pendingToss = PendingToss(player: effect.tossPlayer,
          count: count, source: effect.tossSource, text: effect.tossText,
          remaining: @(effects.toOpenArray(index + 1, effects.high)))
        game.checkWinCondition()
        return
    of DestroyEffect:
      let location = game.minionLocation(effect.destroyedId)
      if location.found:
        game.destroyMinion(location.player, location.index)
    of BounceCreatureEffect:
      let location = game.minionLocation(effect.bouncedCreatureId)
      if not location.found:
        continue
      let bounced = game.players[location.player].board[location.index].card
      # Recorded while it's still on the board, so its slot is known.
      game.recordVisual(BounceVfx,
        creatureChoice(location.player, effect.bouncedCreatureId), bounced)
      game.players[location.player].board.delete(location.index)
      game.players[location.player].hand.add bounced
      game.visualEvents[^1].handIndex = game.players[location.player].hand.high
  game.checkWinCondition()

proc triggerSource(game: GameState,
    pending: PendingTrigger): tuple[found: bool, card: Card, rules: Rules] =
  let location = game.minionLocation(pending.sourceId)
  if location.found:
    let card = game.players[location.player].board[location.index].card
    let triggers = card.triggers()
    if pending.trigger in 0 ..< triggers.len:
      return (true, card, triggers[pending.trigger].rules)

proc triggerContext(game: GameState, pending: PendingTrigger,
    picks: seq[Choice] = @[]): RuleContext =
  result = game.ruleContext(picks, allowNoTarget = true,
    sourcePlayer = pending.owner, sourceId = pending.sourceId)
  result.attacker = pending.attacker

proc triggerChoices*(game: GameState, picked: seq[Choice] = @[]): seq[Choice] =
  ## Legal choices for the waiting trigger's next target, after `picked`.
  ## Like a minion's own rule, it may also take no target.
  if not game.waitingTrigger:
    return
  let pending = game.pendingTriggers[0]
  let source = game.triggerSource(pending)
  if not source.found:
    return
  var context = game.triggerContext(pending)
  context.targets = picked
  result = source.rules.choices(context, picked.len)
  result.add NoTarget

proc waitingTriggerRules*(game: GameState): tuple[card: Card, rules: Rules] =
  ## The waiting trigger's card and the rules it will resolve.
  if game.waitingTrigger:
    let source = game.triggerSource(game.pendingTriggers[0])
    if source.found:
      return (source.card, source.rules)

proc advanceTriggers(game: var GameState) =
  ## Resolves queued triggers in order until one needs its owner to choose
  ## a target (and has something legal to choose), or the queue is empty.
  while game.pendingTriggers.len > 0:
    if game.waitingToss:
      return
    if game.gameOver:
      game.pendingTriggers.setLen(0)
      return
    let pending = game.pendingTriggers[0]
    let source = game.triggerSource(pending)
    if not source.found:
      game.pendingTriggers.delete(0)
      continue
    if source.rules.targetCount() > 0:
      var context = game.triggerContext(pending)
      if source.rules.choices(context).len > 0:
        if not game.dead(pending.owner):
          return
        # The dead can't choose: the trigger resolves without targets.
        var picks = newSeq[Choice](source.rules.targetCount())
        for pick in picks.mitems:
          pick = NoTarget
        var answered = game.triggerContext(pending, picks)
        game.pendingTriggers.delete(0)
        if source.card.runRules(source.rules, answered):
          game.applyEffects(answered.effects)
        continue
    var context = game.triggerContext(pending)
    game.pendingTriggers.delete(0)
    if source.card.runRules(source.rules, context):
      game.applyEffects(context.effects)

proc resolvePendingTrigger*(game: var GameState, choices: seq[Choice]): bool =
  ## The waiting trigger's owner answers its targets in order. A canceled
  ## pick means no target; an illegal one is refused and it keeps waiting.
  if game.waitingToss or not game.waitingTrigger:
    return false
  let pending = game.pendingTriggers[0]
  let source = game.triggerSource(pending)
  if not source.found:
    game.pendingTriggers.delete(0)
    game.advanceTriggers()
    return true
  var picks: seq[Choice]
  for choice in choices:
    picks.add(if choice.isCanceled: NoTarget else: choice)
  var context = game.triggerContext(pending, picks)
  if not source.card.runRules(source.rules, context):
    return false
  game.pendingTriggers.delete(0)
  game.applyEffects(context.effects)
  game.advanceTriggers()
  true

proc resolvePendingToss*(game: var GameState, handIndices: seq[int]): bool =
  ## The discarding player's picks: exactly the waiting count of distinct
  ## hand positions. Those cards go to their discard pile, then the rest of
  ## the resolution (and any waiting triggers) goes on. Bad picks are
  ## refused and it keeps waiting.
  if not game.waitingToss:
    return false
  let
    pending = game.pendingToss
    player = pending.player
  if handIndices.len != pending.count:
    return false
  for i, index in handIndices:
    if index notin 0 ..< game.players[player].hand.len or
        index in handIndices[0 ..< i]:
      return false
  inc game.visualBeat
  # Highest positions first, so each event's slot is right when it leaves.
  for index in handIndices.sorted(Descending):
    let card = game.players[player].hand[index]
    game.visualEvents.add VisualEvent(kind: TossVfx,
      target: heroChoice(player), card: card, handIndex: index,
      boardCount: game.players[player].hand.len, beat: game.visualBeat)
    game.players[player].hand.delete(index)
    game.players[player].discardPile.add card
  game.pendingToss = PendingToss()
  game.applyEffects(pending.remaining)
  game.advanceTriggers()
  true

proc resolveTriggers(game: var GameState) {.gcsafe.} =
  ## Queues the next-turn triggers of cards in play that fire now, the
  ## current player's cards first, then resolves the queue in order.
  for offset in 0 ..< game.playerCount:
    let owner = (game.currentPlayer + offset) mod game.playerCount
    for slot in 0 ..< game.players[owner].board.len:
      let permanent = game.players[owner].board[slot]
      for index, trigger in permanent.card.triggers():
        if index.uint8 in permanent.firedTurnTriggers:
          continue
        var context = game.ruleContext(allowNoTarget = true,
          sourcePlayer = owner, sourceId = permanent.id)
        if trigger.trigger.firesAtTurnStart(context, game.currentPlayer,
            game.turnNumber, permanent.enteredTurn):
          game.players[owner].board[slot].firedTurnTriggers.incl index.uint8
          game.pendingTriggers.add PendingTrigger(owner: owner,
            sourceId: permanent.id, trigger: index)
  game.advanceTriggers()

proc playMinion*(
    game: var GameState,
    cardIndex: int
): int =
  ## Pays for a minion or trinket and puts it onto the board before any of
  ## its rules run.
  if not game.canPlay(cardIndex):
    return
  let
    playerIndex = game.currentPlayer
    card = game.players[playerIndex].hand[cardIndex]
  if card.kind == Spell:
    return
  result = game.nextMinionId
  game.players[playerIndex].energy -= card.energyCost
  game.players[playerIndex].hand.delete(cardIndex)
  game.players[playerIndex].board.add MinionState(
    id: result,
    owner: playerIndex,
    card: card,
    currentToughness: if card.kind == Minion: card.toughness else: 0,
    enteredTurn: game.turnNumber
  )
  inc game.nextMinionId

proc runMinionRules*(
    game: var GameState,
    card: Card,
    choices: seq[Choice],
    sourceId = 0
): bool =
  ## Resolves a minion's or trinket's on-play program once it's on the
  ## board (`sourceId`, for `self()`). A canceled pick means no target: the
  ## card is already in play.
  if card.kind == Spell:
    return false
  var picks: seq[Choice]
  for choice in choices:
    picks.add(if choice.isCanceled: NoTarget else: choice)
  var context = game.ruleContext(
    picks,
    allowNoTarget = true,
    sourceId = sourceId
  )
  if not card.runRules(context):
    return false
  game.applyEffects(context.effects)
  true

proc runMinionRules*(
    game: var GameState,
    card: Card,
    choice = NoTarget,
    sourceId = 0
): bool =
  game.runMinionRules(card, @[choice], sourceId)

proc playCard*(
    game: var GameState,
    cardIndex: int,
    choices: seq[Choice]
): bool =
  ## `choices` answers the card's targets in order (Duel takes two).
  if not game.canPlay(cardIndex):
    return false
  let
    playerIndex = game.currentPlayer
    card = game.players[playerIndex].hand[cardIndex]
  case card.kind
  of Spell:
    var context = game.ruleContext(choices)
    if not card.runRules(context):
      return false
    game.players[playerIndex].energy -= card.energyCost
    game.players[playerIndex].hand.delete(cardIndex)
    game.applyEffects(context.effects)
    game.players[playerIndex].discardPile.add card
  of Minion, Trinket:
    var played = game.copyGameState()
    let id = played.playMinion(cardIndex)
    if id == 0 or not played.runMinionRules(card, choices, id):
      return false
    game = played
  true

proc playCard*(
    game: var GameState,
    cardIndex: int,
    choice = Canceled
): bool =
  game.playCard(cardIndex, @[choice])

proc queueAttackTriggers(game: var GameState, attacker, victim: Choice) =
  ## After an attack's damage: queues the attacked triggers of cards in
  ## play, the current player's first, then resolves the queue in order.
  if game.gameOver:
    return
  for offset in 0 ..< game.playerCount:
    let owner = (game.currentPlayer + offset) mod game.playerCount
    for permanent in game.players[owner].board:
      for index, trigger in permanent.card.triggers():
        var context = game.ruleContext(allowNoTarget = true,
          sourcePlayer = owner, sourceId = permanent.id)
        if trigger.trigger.firesOnAttack(context, victim):
          game.pendingTriggers.add PendingTrigger(owner: owner,
            sourceId: permanent.id, trigger: index, attacker: attacker)
  game.advanceTriggers()

proc attackTargets*(game: GameState, attackerId: int): seq[Choice] =
  ## Legal targets for a ready attacker: each opponent's hero, then that
  ## opponent's minions, in seat order after the attacker's. Defeated
  ## opponents that are skipped can't be attacked.
  let location = game.minionLocation(attackerId)
  if not location.found or location.player != game.currentPlayer:
    return
  let attacker = game.players[location.player].board[location.index]
  if game.waitingChoice or game.gameOver or game.dead(location.player) or
      attacker.card.kind != Minion or
      not attacker.canAttack or
      attacker.hasAttacked:
    return
  for offset in 1 ..< game.playerCount:
    let enemy = (game.currentPlayer + offset) mod game.playerCount
    # A dead player's hero is gone, but their minions stay in play.
    if not game.dead(enemy):
      result.add heroChoice(enemy)
    for minion in game.players[enemy].board:
      if minion.card.kind == Minion:
        result.add creatureChoice(enemy, minion.id)

proc attackHero*(game: var GameState, minionId: int,
    targetPlayer = -1): bool =
  ## The attacker hits `targetPlayer`'s hero (default: the next player's)
  ## for its power.
  let targetPlayer =
    if targetPlayer >= 0: targetPlayer
    else: game.nextPlayer(game.currentPlayer)
  if heroChoice(targetPlayer) notin game.attackTargets(minionId):
    return false
  let location = game.minionLocation(minionId)
  let minion = game.players[location.player].board[location.index]
  inc game.visualBeat
  if minion.power > 0:
    game.recordVisual(DamageFlashVfx, heroChoice(targetPlayer))
  game.players[targetPlayer].life = max(0,
    game.players[targetPlayer].life - minion.power)
  game.players[location.player].board[location.index].hasAttacked = true
  game.checkWinCondition()
  game.queueAttackTriggers(creatureChoice(location.player, minionId),
    heroChoice(targetPlayer))
  true

proc attackMinion*(game: var GameState, attackerId, targetId: int): bool =
  ## The attacker fights its target. Damage stays, and minions reduced to 0
  ## toughness go to their owner's discard pile.
  let target = game.minionLocation(targetId)
  if not target.found or
      creatureChoice(target.player, targetId) notin
        game.attackTargets(attackerId):
    return false
  let attackerLocation = game.minionLocation(attackerId)
  game.players[attackerLocation.player].board[
    attackerLocation.index].hasAttacked = true
  game.applyEffects([
    Effect(kind: FightEffect, fighterId: attackerId, opponentId: targetId)])
  game.queueAttackTriggers(creatureChoice(attackerLocation.player, attackerId),
    creatureChoice(target.player, targetId))
  true

proc attack*(game: var GameState, attackerId: int, target: Choice): bool =
  if target notin game.attackTargets(attackerId):
    return false
  case target.kind
  of HeroChoice: game.attackHero(attackerId, target.owner)
  of CreatureChoice: game.attackMinion(attackerId, target.creatureId)
  of CanceledChoice, NoTargetChoice: false

proc eligibleAttackers*(game: GameState): seq[int] =
  if game.waitingChoice or game.gameOver or game.dead(game.currentPlayer):
    return
  for minion in game.players[game.currentPlayer].board:
    if minion.card.kind == Minion and minion.canAttack and
        not minion.hasAttacked:
      result.add minion.id

proc finishTurn*(game: var GameState) =
  ## The next living player's turn. One who dies drawing for it at an empty
  ## deck loses the turn too.
  if game.gameOver or game.waitingChoice: return
  while true:
    game.currentPlayer = game.nextPlayer(game.currentPlayer)
    inc game.turnNumber
    game.beginTurn()
    if game.gameOver or not game.dead(game.currentPlayer):
      break
