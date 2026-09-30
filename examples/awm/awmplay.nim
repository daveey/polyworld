## Playing the game on a table, shared by every game mode: where the mouse
## is, the card being played and its targets, cards in flight, and the
## visual beats the game's effects play in. A mode says where things sit
## with a TableLayout; the rules stay in the core.
import std/[math, options, random, strformat]
import chroma, silky, vmath, windy
import awmsim, awmtable, awmheroes, awmbots, awmsessions, cardrenderer,
  vfxrenderer

type
  TableLayout* = object
    ## Where one game mode puts each player's cards and hero, read live:
    ## the layout may follow the camera or the seat in front of it.
    handPoses*: proc(player, count: int): seq[CardPose]
    boardPoses*: proc(player, count: int): seq[CardPose]
    deckPose*: proc(player: int): CardPose
    discardPose*: proc(player: int): CardPose
    spellPose*: proc(player: int): CardPose
      ## Where a played spell floats while its effects play out.
    heroPosition*: proc(player: int): Vec3
      ## A hero's feet.
    handVisible*: proc(player: int): bool
      ## The hand is shown face up.
    drawVisible*: proc(player: int): bool
      ## The player's drawn cards fly face up. When unset, they do when
      ## their hand is shown face up.
    overBoard*: proc(point: Vec3): bool
      ## A point on the card plane is on the empty board, where a click
      ## answers "no target".
    heroLungePoint*: proc(fromPose: CardPose, hero: Vec3): Vec3
      ## Where a minion attacking the hero at `hero` lunges to. When unset,
      ## it lunges most of the way there, as it does at a minion.

  DyingMinion* = object
    ## A slain minion held where it died until the effects aimed at it end.
    ## It keeps its board slot, so neighbours don't shift until it leaves.
    target*: Choice
    card*: Card
    power*: int  ## Live power when it died.
    heroClass*: HeroClass
    boardIndex*: int  ## Live board index just before it was removed.
    atLunge*: bool  ## Slain while attacking: held at `lungePoint`.
    held*: bool  ## Its death's beat hasn't played yet: it stays put.
    bouncing*: bool
      ## Not slain: a bounced card holding its slot until its beat, when it
      ## flies to hand instead of the discard pile.
    lungePoint*: Vec3

  CastSpell* = object
    ## A played spell floating above its caster's board. It's already in the
    ## discard pile in the rules; it flies there once the table settles.
    card*: Card
    heroClass*: HeroClass
    owner*: int

  TablePlay* = object
    ## What the table shows on top of the game's state.
    pendingTargeting*: bool
    pendingCardIndex*: int
    pendingCard*: Card
    pendingChoices*: seq[Choice]
    pendingPicks*: seq[Choice]  ## Targets chosen so far for pendingCard.
    pendingTrigger*: bool  ## Targeting answers a waiting trigger.
    tossPicking*: bool  ## The human is choosing cards to discard.
    tossPicks*: seq[int]  ## Hand positions picked so far.
    animations*: seq[CardAnimation]
    discardFlights*: seq[CardAnimation]  ## Never block input or bots.
    activeVfx*: seq[ActiveVfx]
    dyingMinions*: seq[DyingMinion]
    castSpell*: Option[CastSpell]  ## Held above the board until it settles.
    queuedEvents*: seq[VisualEvent]  ## Visual events waiting for their beat.
    hiddenSummons*: seq[int]
      ## Summoned minions per player whose beat hasn't played yet. They're
      ## the last cards on that board and take no room until they appear.
    lastBeatWasDraw*: bool
    lastDrawStart*: float32
    heroDeaths*: seq[float32]
      ## When each player's hero started dying, or -1 while alive.
    deathDiscard*: seq[float32]
      ## How long one card of a dead player's hand flies to the pile. Their
      ## cards leave one after another, so the whole hand always takes
      ## DeathDiscardSeconds. 0 for a player who isn't dying.
    selectedAttacker*: int  ## The human's minion about to attack, or 0.
    attackActive*: bool  ## Minions are lunging at `attackTarget`.
    attackSteps*: seq[int]  ## The attackers, lunging one after another.
    attackIndex*: int
    attackTarget*: Choice
    attackPoint*: Vec3
      ## Where the attackers lunge. Captured when the attack starts,
      ## because a slain defender leaves the board mid-animation.
    attackForward*: bool  ## Lunging out; else coming back.
    attackElapsed*: float32
    attackDamageApplied*: bool
    attackFinishTurn*: bool  ## A bot's attacks end its turn.
    statusMessage*: string
    visualRng*: Rand
      ## Visual seeds never advance the game's RNG.

proc drawFaceUp*(layout: TableLayout, player: int): bool =
  if layout.drawVisible.isNil: layout.handVisible(player)
  else: layout.drawVisible(player)

const
  AttackLungeDuration* = 0.22'f32
  AttackReturnDuration* = 0.30'f32

proc initTablePlay*(visualSeed: int64): TablePlay =
  TablePlay(pendingCardIndex: -1, attackTarget: Canceled,
    attackForward: true, visualRng: initRand(visualSeed))

proc initTablePlay*(): TablePlay =
  TablePlay(pendingCardIndex: -1, attackTarget: Canceled,
    attackForward: true, visualRng: initRand())

proc queuedDraw*(queued: openArray[VisualEvent], owner, index: int): bool =
  ## A card still on its way to the hand (drawn or bounced) whose beat
  ## hasn't played yet stays out of the hand.
  for event in queued:
    if event.target.owner == owner and
        ((event.kind == DrawVfx and event.boardIndex == index) or
          (event.kind == BounceVfx and event.handIndex == index)):
      return true

proc queuedTosses*(play: TablePlay, owner: int): int =
  ## Cards already discarded whose beat hasn't played: still shown in hand.
  for event in play.queuedEvents:
    if event.kind == TossVfx and event.target.owner == owner:
      inc result

proc queuedSummon*(queued: openArray[VisualEvent], minionId: int): bool =
  ## A summoned minion whose beat hasn't played yet stays off the board.
  for event in queued:
    if event.kind == SummonVfx and event.target.kind == CreatureChoice and
        event.target.creatureId == minionId:
      return true

proc mousePlanePoint*(
    window: Window,
    viewProjection: Mat4,
    planeY: float32
): tuple[hit: bool, point: Vec3] =
  let
    ray = mouseRay(window, viewProjection)
  if abs(ray.direction.y) < 1e-5'f32:
    return
  let distance = (planeY - ray.origin.y) / ray.direction.y
  if distance <= 0:
    return
  (true, ray.origin + ray.direction * distance)

proc mouseOverBoard*(
    window: Window,
    viewProjection: Mat4,
    layout: TableLayout
): bool =
  let hit = mousePlanePoint(window, viewProjection, CardPlaneY)
  hit.hit and layout.overBoard(hit.point)

proc choiceIsLegal*(
    choices: openArray[Choice],
    wanted: Choice
): bool =
  for choice in choices:
    if choice == wanted:
      return true

proc selectableTargetCount*(choices: openArray[Choice]): int =
  for choice in choices:
    if not choice.isNoTarget:
      inc result

proc hoveredCard*(
    window: Window,
    viewProjection: Mat4,
    game: GameState,
    layout: TableLayout,
    handOwner = -1
): int =
  ## The hovered card in `handOwner`'s hand (default: the current player).
  result = -1
  let
    playerIndex = if handOwner >= 0: handOwner else: game.currentPlayer
    poses = layout.handPoses(
      playerIndex,
      game.players[playerIndex].hand.len
    )
  if poses.len == 0:
    return
  for i in countdown(poses.high, 0):
    if mouseHitsCard(window, viewProjection, poses[i]):
      return i

proc hoveredHeroTarget*(
    window: Window,
    viewProjection: Mat4,
    game: GameState,
    layout: TableLayout,
    choices: openArray[Choice]
): Choice =
  ## The hit area follows the hero on screen: as wide as the target ring
  ## drawn at its feet, and at least as tall as the body it covers. A
  ## fixed pixel radius would miss at another resolution, camera or size.
  const HeroTargetRadius = 0.95'f32 ## Matches the ring drawn around a hero.
  result = Canceled
  var closestRatio = 1.0'f32
  for playerIndex in 0 ..< game.playerCount:
    let wanted = heroChoice(playerIndex)
    if not choices.choiceIsLegal(wanted):
      continue
    let
      feet = layout.heroPosition(playerIndex)
      center = screenPosition(window, feet + vec3(0, HeroHeight * 0.5'f32, 0),
        viewProjection)
      head = screenPosition(window, feet + vec3(0, HeroHeight, 0),
        viewProjection)
      side = screenPosition(window, feet + vec3(HeroTargetRadius, 0, 0),
        viewProjection)
      ground = screenPosition(window, feet, viewProjection)
      radius = max(abs(side.x - ground.x), abs(center.y - head.y))
      delta = center - window.mousePos.vec2
      ratio = (delta.x * delta.x + delta.y * delta.y) /
        max(radius * radius, 1.0'f32)
    if ratio <= closestRatio:
      closestRatio = ratio
      result = wanted

proc boardSlots*(
    play: TablePlay,
    owner,
    liveCount: int
): seq[int] =
  ## Presented board order: live indices 0 ..< liveCount, with each dying
  ## minion (as -1 - its index in `dying`) back where it stood. Re-inserting
  ## the newest first undoes the removals in reverse, so every slot lands
  ## exactly where it was. Summons still waiting for their beat are left
  ## out, so the cards already shown don't shift before they appear.
  let hidden =
    if owner < play.hiddenSummons.len: play.hiddenSummons[owner] else: 0
  for i in 0 ..< max(0, liveCount - hidden):
    result.add i
  for i in countdown(play.dyingMinions.high, 0):
    if play.dyingMinions[i].target.owner == owner:
      result.insert(-1 - i, min(play.dyingMinions[i].boardIndex, result.len))

proc liveBoardPose*(
    play: TablePlay,
    layout: TableLayout,
    owner,
    liveIndex,
    liveCount: int
): CardPose =
  ## A card left out of the layout (a summon whose beat hasn't played)
  ## gets the first slot; it isn't drawn until it appears. An empty
  ## layout still has one slot to hand out.
  let
    slots = play.boardSlots(owner, liveCount)
    poses = layout.boardPoses(owner, max(1, slots.len))
  poses[clamp(slots.find(liveIndex), 0, poses.high)]

proc dyingPose*(
    play: TablePlay,
    layout: TableLayout,
    index,
    liveCount: int
): CardPose =
  let
    owner = play.dyingMinions[index].target.owner
    slots = play.boardSlots(owner, liveCount)
    poses = layout.boardPoses(owner, max(1, slots.len))
  result = poses[clamp(slots.find(-1 - index), 0, poses.high)]
  if play.dyingMinions[index].atLunge:
    result.position = play.dyingMinions[index].lungePoint

proc hoveredCreatureTarget*(
    window: Window,
    viewProjection: Mat4,
    game: GameState,
    play: TablePlay,
    layout: TableLayout,
    choices: openArray[Choice]
): Choice =
  result = Canceled
  let hit = mousePlanePoint(window, viewProjection, CardPlaneY)
  if not hit.hit:
    return
  for playerIndex in 0 ..< game.playerCount:
    let player = game.players[playerIndex]
    for minionIndex in countdown(player.board.high, 0):
      let
        minion = player.board[minionIndex]
        wanted = creatureChoice(playerIndex, minion.id)
      if not choices.choiceIsLegal(wanted):
        continue
      if mouseHitsCard(
          window,
          viewProjection,
          play.liveBoardPose(layout, playerIndex, minionIndex, player.board.len)
      ):
        return wanted

proc hoveredWorldTarget*(
    window: Window,
    viewProjection: Mat4,
    game: GameState,
    play: TablePlay,
    layout: TableLayout,
    choices: openArray[Choice]
): Choice =
  result = hoveredCreatureTarget(
    window,
    viewProjection,
    game,
    play,
    layout,
    choices
  )
  if result.isCanceled:
    result = hoveredHeroTarget(window, viewProjection, game, layout, choices)

proc addDrawAnimation*(
    play: var TablePlay,
    game: GameState,
    layout: TableLayout,
    playerIndex: int,
    hidden = true,
    handIndex = -1,
    delay = 0.0'f32
) =
  ## Flies a card from the deck to `handIndex` (default: the last slot).
  ## `delay` holds it on the deck first, so cards drawn together follow
  ## one another.
  if game.players[playerIndex].hand.len == 0:
    return
  let
    destinationIndex =
      if handIndex in 0 ..< game.players[playerIndex].hand.len: handIndex
      else: game.players[playerIndex].hand.high
    sourcePose = stackTopPose(
      layout.deckPose(playerIndex),
      game.players[playerIndex].deck.len + 1
    )
    destinationPose = layout.handPoses(
      playerIndex,
      game.players[playerIndex].hand.len
    )[destinationIndex]
  var flight = newDrawAnimation(
    game.players[playerIndex].hand[destinationIndex],
    game.players[playerIndex].heroClass,
    sourcePose, destinationPose, playerIndex, destinationIndex, hidden)
  flight.elapsed = -delay
  play.animations.add flight

proc addOpeningHands*(play: var TablePlay, game: GameState,
    layout: TableLayout) =
  ## The deal that starts a game: every card in every hand flies from its
  ## own deck, a seat at a time around the table, each leaving before the
  ## one before it lands.
  var
    dealt = 0
    widest = 0
    total = 0
  for player in game.players:
    widest = max(widest, player.hand.len)
    total += player.hand.len
  # A table of seven deals faster instead of taking half a minute.
  let stagger =
    if total > 1: min(DrawStagger, OpeningDealSeconds / (total - 1).float32)
    else: 0.0'f32
  for slot in 0 ..< widest:
    for playerIndex in 0 ..< game.playerCount:
      let player = game.players[playerIndex]
      if slot >= player.hand.len:
        continue
      # The deck stood this tall when this card left it.
      var flight = newDrawAnimation(
        player.hand[slot], player.heroClass,
        stackTopPose(layout.deckPose(playerIndex),
          player.deck.len + player.hand.len - slot),
        layout.handPoses(playerIndex, player.hand.len)[slot],
        playerIndex, slot, not layout.drawFaceUp(playerIndex))
      flight.elapsed = -stagger * dealt.float32
      play.animations.add flight
      inc dealt

proc holdCastSpell*(play: var TablePlay, layout: TableLayout, card: Card,
    heroClass: HeroClass, owner: int, sourcePose: CardPose) =
  ## A played spell flies from the hand to the spot it floats in, and waits
  ## there. Two spells never overlap, but if one somehow arrives while
  ## another floats, the older one leaves for the pile.
  if play.castSpell.isSome:
    let held = play.castSpell.get
    play.discardFlights.add newCardAnimation(held.card, held.heroClass,
      layout.spellPose(held.owner), stackTopPose(
        layout.discardPose(held.owner), 1),
      suppressDiscardOwner = held.owner)
  play.animations.add newCardAnimation(card, heroClass, sourcePose,
    layout.spellPose(owner), suppressCastSpell = true)
  play.castSpell = some(CastSpell(card: card,
    heroClass: heroClass, owner: owner))

proc animateTransition*(play: var TablePlay, layout: TableLayout,
    before, after: GameState) =
  ## The server and local bot use the same card movement as human input.
  if after.turnNumber != before.turnNumber:
    # Draws animate from their DrawVfx events.
    return
  let owner = before.currentPlayer
  let oldPlayer = before.players[owner]
  let newPlayer = after.players[owner]
  if oldPlayer.hand.len > 0:
    # The built-in bot always chooses the first affordable card. Base decks
    # contain one card type, so locating a played face is unambiguous.
    var playedIndex = 0
    for i, card in oldPlayer.hand:
      if card.energyCost <= oldPlayer.energy:
        playedIndex = i
        break
    let source = layout.handPoses(owner, oldPlayer.hand.len)[playedIndex]
    # Only the card that left the hand flies from it; minions its rules
    # summoned enter after it and appear on their own beat.
    for i, minion in newPlayer.board:
      if not before.minionLocation(minion.id).found:
        play.animations.add newCardAnimation(minion.card, newPlayer.heroClass,
          source, layout.boardPoses(owner, i + 1)[i],
          suppressBoardId = minion.id)
        break
    if newPlayer.discardPile.len > oldPlayer.discardPile.len and
        newPlayer.hand.len < oldPlayer.hand.len:
      let played = newPlayer.discardPile[^1]
      if played.kind == Spell:
        play.holdCastSpell(layout, played, newPlayer.heroClass, owner, source)
      else:
        play.animations.add newCardAnimation(played,
          newPlayer.heroClass, source,
          stackTopPose(layout.discardPose(owner), newPlayer.discardPile.len),
          suppressDiscardOwner = owner)

proc presentedCardPose*(play: TablePlay, game: GameState, layout: TableLayout,
    target: Choice, slot, count: int): CardPose =
  ## Where a targeted card is shown right now: its live slot, or the slot
  ## it's held in while its death or bounce waits for its beat. Only if
  ## it's neither does the slot it had when the event was recorded count.
  let location = game.minionLocation(target.creatureId)
  if location.found:
    return play.liveBoardPose(layout, location.player, location.index,
      game.players[location.player].board.len)
  for i, held in play.dyingMinions:
    if held.target == target:
      return play.dyingPose(layout, i,
        game.players[target.owner].board.len)
  layout.boardPoses(target.owner, max(1, count))[
    clamp(slot, 0, max(0, count - 1))]

proc countHiddenSummons*(play: var TablePlay, playerCount: int) =
  play.hiddenSummons = newSeq[int](playerCount)
  for event in play.queuedEvents:
    if event.kind == SummonVfx:
      inc play.hiddenSummons[event.target.owner]

proc presentationIdle*(play: TablePlay, game: GameState): bool =
  ## Nothing is animating and no visual beat is still waiting to play,
  ## including events the game produced that the UI hasn't taken yet.
  play.animations.len == 0 and play.activeVfx.len == 0 and
    play.queuedEvents.len == 0 and game.visualEvents.len == 0

proc spellDiscards*(play: TablePlay, owner: int): int =
  ## A played spell already in the discard pile but still shown on the board.
  if play.castSpell.isSome and play.castSpell.get.owner == owner: 1 else: 0

proc spellSettled*(play: TablePlay, game: GameState): bool =
  ## Every animation and effect is done and nothing waits on the player, so
  ## a floating spell can leave for the discard pile.
  play.presentationIdle(game) and play.dyingMinions.len == 0 and
    not play.pendingTargeting and not play.tossPicking and
    not game.waitingToss and not game.waitingTrigger

proc dyingDiscards*(play: TablePlay, owner: int): int =
  ## Slain cards already in the discard pile but still shown on the board.
  for dying in play.dyingMinions:
    if dying.target.owner == owner and not dying.bouncing:
      inc result

proc resetTable*(play: var TablePlay) =
  ## A new game: nothing from the last one is still on its way.
  play.dyingMinions.setLen(0)
  play.castSpell = none(CastSpell)
  play.queuedEvents.setLen(0)
  play.heroDeaths.setLen(0)
  play.deathDiscard.setLen(0)
  play.tossPicking = false
  play.discardFlights.setLen(0)

proc inspectedCard*(
    window: Window,
    viewProjection: Mat4,
    game: GameState,
    play: TablePlay,
    layout: TableLayout,
    hoverIndex: int,
    handOwner = -1
): tuple[found: bool, card: Card, power, toughness: int,
    lost: set[Keyword]] =
  ## The card to show large: the hovered hand card, else the closest board
  ## card under the mouse with its live stats, else the visible top of a
  ## discard pile. `handOwner` is whose hand `hoverIndex` is in (default:
  ## the current player).
  result.power = -1
  result.toughness = -1
  let
    owner = if handOwner >= 0: handOwner else: game.currentPlayer
    player = game.players[owner]
  if hoverIndex >= 0 and hoverIndex < player.hand.len and
      not play.animations.handCardSuppressed(owner, hoverIndex) and
      not play.queuedEvents.queuedDraw(owner, hoverIndex):
    result.card = player.hand[hoverIndex]
    result.found = true
    return
  # One card: the closest under the mouse. Its stats come from it alone,
  # never left over from another card the mouse also touches.
  var nearest = high(float32)
  for owner in 0 ..< game.playerCount:
    for i, minion in game.players[owner].board:
      if play.animations.boardCardSuppressed(minion.id) or
          play.queuedEvents.queuedSummon(minion.id):
        continue
      let offset = mouseCardOffset(window, viewProjection,
        play.liveBoardPose(layout, owner, i, game.players[owner].board.len))
      if offset < 0 or offset >= nearest:
        continue
      nearest = offset
      result.card = minion.card
      result.found = true
      if result.card.kind == Minion:
        result.power = minion.power
        result.toughness = minion.currentToughness
        result.lost = minion.lostKeywords
      else:
        result.power = -1
        result.toughness = -1
        result.lost = {}
  if result.found:
    return
  # The visible top of a discard pile, matching how the pile is drawn:
  # cards still flying there or still dying on the board aren't shown.
  for owner in 0 ..< game.playerCount:
    let
      pile = game.players[owner].discardPile
      hiddenCards = play.queuedTosses(owner) +
        play.animations.discardCardsSuppressed(owner) +
        play.discardFlights.discardCardsSuppressed(owner) +
        play.dyingDiscards(owner) + play.spellDiscards(owner)
      shown = pile.len - hiddenCards
    if shown > 0 and mouseHitsCard(window, viewProjection,
        stackTopPose(layout.discardPose(owner), shown)):
      result.card = pile[shown - 1]
      result.found = true

proc addCardGlow*(renderer: var VfxRenderer, pose: CardPose,
    hovered, targetable, targeting: bool, time: float32) =
  if not hovered and not targetable: return
  let
    lift = (if hovered: 0.16'f32 else: 0.0'f32) +
      (if targetable: 0.08'f32 else: 0.0'f32)
    center = pose.position + vec3(0, lift, 0) +
      pose.cardNormal() * (CardHeight * 0.5'f32 + 0.01'f32)
    pulse = 0.88'f32 + 0.12'f32 * sin(time * 5)
  renderer.addCardHalo(center,
    pose.transformCardVector(vec3(1, 0, 0)),
    pose.transformCardVector(vec3(0, 0, 1)), vec2(CardWidth, CardDepth),
    (if targeting: TargetRed else: HoverGold),
    pulse * (if hovered: 0.2875'f32 else: 0.28'f32))

proc playHandCard*(
    play: var TablePlay,
    game: var GameState,
    layout: TableLayout,
    handIndex: int
): bool =
  ## The current player clicked a card in hand: pay for it, send it to the
  ## board or the discard pile, and start choosing its targets if it has
  ## any. True when the card left the hand, so it is no longer hovered.
  let
    player = game.players[game.currentPlayer]
    card = player.hand[handIndex]
  if card.energyCost > player.energy:
    play.statusMessage =
      &"Not enough energy to play {card.name}."
  elif card.needsChoice():
    if card.kind != Spell:
      let
        sourcePose = layout.handPoses(
          game.currentPlayer,
          player.hand.len
        )[handIndex]
        minionId = game.playMinion(handIndex)
      if minionId != 0:
        # Its own slot, counting only the cards up to it: minions
        # its rules summon come after it and appear later.
        let
          playedIndex = game.minionLocation(minionId).index
          destinationPose = play.liveBoardPose(layout,
            game.currentPlayer, playedIndex, playedIndex + 1)
        play.animations.add newCardAnimation(
          card,
          player.heroClass,
          sourcePose,
          destinationPose,
          suppressBoardId = minionId
        )
        play.pendingCard = card
        play.pendingCardIndex = -1
        play.pendingPicks.setLen(0)
        play.pendingChoices = game.availableChoices(card)
        result = true
        if play.pendingChoices.selectableTargetCount() == 0:
          discard game.runMinionRules(card, NoTarget,
            sourceId = minionId)
          play.pendingChoices.setLen(0)
          play.statusMessage =
            &"{card.name} enters play without a target."
        else:
          play.pendingTargeting = true
          play.selectedAttacker = 0
          play.statusMessage =
            &"{card.name} enters play. Click a highlighted minion or the empty board."
    else:
      play.pendingCard = card
      play.pendingCardIndex = handIndex
      play.pendingPicks.setLen(0)
      play.pendingChoices = game.availableChoices(handIndex)
      if play.pendingChoices.len == 0:
        play.pendingCardIndex = -1
        play.pendingChoices.setLen(0)
        play.statusMessage =
          &"{card.name} has no valid targets."
      else:
        play.pendingTargeting = true
        play.selectedAttacker = 0
        play.statusMessage =
          &"Click the highlighted avatar for {card.name}."
  else:
    let sourcePose = layout.handPoses(
      game.currentPlayer,
      player.hand.len
    )[handIndex]
    case card.kind
    of Minion, Trinket:
      let minionId = game.playMinion(handIndex)
      if minionId != 0:
        discard game.runMinionRules(card, sourceId = minionId)
        # Its own slot, counting only the cards up to it: minions
        # its rules summon come after it and appear later.
        let
          playedIndex = game.minionLocation(minionId).index
          destinationPose = play.liveBoardPose(layout,
            game.currentPlayer, playedIndex, playedIndex + 1)
        play.animations.add newCardAnimation(
          card,
          player.heroClass,
          sourcePose,
          destinationPose,
          suppressBoardId = minionId
        )
        play.statusMessage = &"{card.name} enters the board."
        result = true
    of Spell:
      if game.playCard(handIndex):
        play.holdCastSpell(layout, card, player.heroClass,
          game.currentPlayer, sourcePose)
        play.statusMessage = &"{card.name} resolves."
        result = true

proc updateTossPicking*(
    play: var TablePlay,
    game: var GameState,
    hoverIndex: int,
    pick,
    clear: bool
) =
  ## The discarding player clicks cards in hand; the last pick discards.
  let pending = game.pendingToss
  if clear:
    play.tossPicks.setLen(0)
    play.statusMessage = "Discard picks cleared."
  elif pick and hoverIndex >= 0:
    let at = play.tossPicks.find(hoverIndex)
    if at >= 0:
      play.tossPicks.delete(at)
    else:
      play.tossPicks.add hoverIndex
    if play.tossPicks.len == pending.count:
      let picks = play.tossPicks
      play.tossPicking = false
      play.tossPicks.setLen(0)
      play.statusMessage =
        if game.resolvePendingToss(picks): &"{pending.source}: discarded."
        else: "Those cards can't be discarded."

proc updateTargeting*(
    play: var TablePlay,
    game: var GameState,
    layout: TableLayout,
    window: Window,
    viewProjection: Mat4,
    hoverIndex: int,
    pick,
    cancel: bool
): Choice =
  ## Choosing the pending card's or trigger's targets, one per click. A
  ## right-click cancels a spell, or ends a minion's rule without a
  ## target. Returns the hovered target, for highlighting.
  result = hoveredWorldTarget(window, viewProjection, game, play,
    layout, play.pendingChoices)
  let
    card = play.pendingCard
    pendingRules =
      if play.pendingTrigger: game.waitingTriggerRules().rules
      else: card.rules
  if play.pendingTrigger and cancel:
    play.statusMessage =
      &"{card.name}'s trigger can't be canceled: choose a target."
  elif cancel:
    if card.kind != Spell:
      discard game.runMinionRules(card, NoTarget)
      play.statusMessage =
        &"{card.name}'s rule finishes without a target."
    else:
      play.statusMessage = &"{card.name} canceled."
    play.pendingTargeting = false
    play.pendingCardIndex = -1
    play.pendingChoices.setLen(0)
  elif pick:
    var selectedChoice = result
    if selectedChoice.isCanceled and
        card.kind != Spell and
        hoverIndex < 0 and
        mouseOverBoard(window, viewProjection, layout) and
        play.pendingChoices.choiceIsLegal(NoTarget):
      selectedChoice = NoTarget
    if not selectedChoice.isCanceled and
        play.pendingPicks.len + 1 < pendingRules.targetCount():
      # More targets to choose (Duel): keep the pick, offer the next.
      play.pendingPicks.add selectedChoice
      play.pendingChoices =
        if play.pendingTrigger:
          game.triggerChoices(play.pendingPicks)
        elif card.kind != Spell:
          game.availableChoices(card, play.pendingPicks)
        else:
          game.availableChoices(play.pendingCardIndex, play.pendingPicks)
      play.statusMessage =
        &"Choose target {play.pendingPicks.len + 1} of " &
          &"{pendingRules.targetCount()} for {card.name}."
    elif not selectedChoice.isCanceled:
      var
        spellAnimation = false
        spellSourcePose: CardPose
        spellClass: HeroClass
      if card.kind == Spell and
          play.pendingCardIndex >= 0 and
          play.pendingCardIndex <
            game.players[game.currentPlayer].hand.len:
        spellAnimation = true
        spellClass =
          game.players[game.currentPlayer].heroClass
        spellSourcePose = layout.handPoses(
          game.currentPlayer,
          game.players[game.currentPlayer].hand.len
        )[play.pendingCardIndex]
      let resolved =
        if play.pendingTrigger:
          game.resolvePendingTrigger(play.pendingPicks & selectedChoice)
        elif card.kind != Spell:
          game.runMinionRules(card, play.pendingPicks & selectedChoice)
        else:
          game.playCard(play.pendingCardIndex, play.pendingPicks & selectedChoice)
      if resolved and spellAnimation:
        play.holdCastSpell(layout, card, spellClass, game.currentPlayer,
          spellSourcePose)
      if resolved:
        play.statusMessage =
          if play.pendingTrigger:
            &"{card.name}'s trigger resolves."
          elif card.kind != Spell:
            if selectedChoice.isNoTarget:
              &"{card.name}'s rule finishes without a target."
            else:
              &"{card.name}'s rule resolves."
          else:
            &"{card.name} resolves and is discarded."
      else:
        play.statusMessage = &"{card.name} could not resolve."
      play.pendingTargeting = false
      play.pendingTrigger = false
      play.pendingCardIndex = -1
      play.pendingChoices.setLen(0)

proc stopTargeting*(play: var TablePlay) =
  play.pendingTargeting = false
  play.pendingCardIndex = -1
  play.pendingChoices.setLen(0)

proc lungingMinion*(play: TablePlay): int =
  ## The minion whose lunge is playing now, or 0.
  if play.attackActive and play.attackIndex < play.attackSteps.len:
    play.attackSteps[play.attackIndex]
  else: 0

proc attackPointFor*(play: TablePlay, game: GameState, layout: TableLayout,
    target: Choice): Vec3 =
  ## Where an attacker lunges: the defender's slot, or the hero's feet.
  if target.kind == CreatureChoice:
    let location = game.minionLocation(target.creatureId)
    if location.found:
      return play.liveBoardPose(layout, location.player, location.index,
        game.players[location.player].board.len).position
  layout.heroPosition(target.owner)

proc attackLungePoint*(play: TablePlay, layout: TableLayout,
    fromPose: CardPose): Vec3 =
  ## Far end of the lunge: toward the hero, or just short of a defender
  ## so both cards stay visible.
  if play.attackTarget.kind == HeroChoice and
      not layout.heroLungePoint.isNil:
    layout.heroLungePoint(fromPose, play.attackPoint)
  else:
    fromPose.position + (play.attackPoint - fromPose.position) * 0.8'f32 +
      vec3(0, 0.3, 0)

proc startAttack*(play: var TablePlay, game: GameState, layout: TableLayout,
    attackers: seq[int], target: Choice, finishTurn = false) =
  ## The attackers lunge at `target` one after another; each hits when its
  ## lunge lands. A bot's attacks can end its turn.
  play.attackActive = true
  play.attackSteps = attackers
  play.attackTarget = target
  play.attackPoint = play.attackPointFor(game, layout, target)
  play.attackIndex = 0
  play.attackForward = true
  play.attackElapsed = 0
  play.attackDamageApplied = false
  play.attackFinishTurn = finishTurn

proc advanceAttack*(play: var TablePlay, game: var GameState,
    dt: float32): bool =
  ## Plays the lunges and applies each attack as it lands. True on the
  ## frame the last attacker is back in its slot.
  if not play.attackActive:
    return
  play.attackElapsed += dt
  if play.attackForward:
    if play.attackElapsed >= AttackLungeDuration:
      if not play.attackDamageApplied:
        discard game.attack(play.attackSteps[play.attackIndex],
          play.attackTarget)
        play.attackDamageApplied = true
      play.attackForward = false
      play.attackElapsed = 0
  else:
    if play.attackElapsed >= AttackReturnDuration:
      inc play.attackIndex
      if play.attackIndex >= play.attackSteps.len:
        play.attackActive = false
        play.selectedAttacker = 0
        result = true
      else:
        play.attackForward = true
        play.attackElapsed = 0
        play.attackDamageApplied = false

proc attackChoices*(play: var TablePlay, game: GameState): seq[Choice] =
  ## What the selected attacker can hit; drops it once it can't attack.
  if play.selectedAttacker != 0 and not play.attackActive:
    result = game.attackTargets(play.selectedAttacker)
    if result.len == 0:
      # The attacker left the board or can no longer attack.
      play.selectedAttacker = 0

proc updateAttack*(
    play: var TablePlay,
    game: GameState,
    layout: TableLayout,
    window: Window,
    viewProjection: Mat4,
    hoveredBoard: Choice,
    pick,
    cancel: bool
) =
  ## The human picks one of their minions, then clicks an enemy minion or
  ## hero to attack it. Clicking the attacker again, or a right-click,
  ## cancels.
  if pick:
    let
      attackable =
        if play.selectedAttacker != 0:
          game.attackTargets(play.selectedAttacker)
        else: @[]
      clicked = hoveredWorldTarget(window, viewProjection, game, play,
        layout, attackable)
    if not clicked.isCanceled:
      play.startAttack(game, layout, @[play.selectedAttacker], clicked)
      play.statusMessage = "Attacking!"
    elif hoveredBoard.kind == CreatureChoice and
        hoveredBoard.owner == game.currentPlayer:
      let minionId = hoveredBoard.creatureId
      if minionId == play.selectedAttacker:
        play.selectedAttacker = 0
        play.statusMessage = "Attack canceled."
      elif game.attackTargets(minionId).len > 0:
        play.selectedAttacker = minionId
        play.statusMessage =
          "Click an enemy minion or hero to attack. Right-click cancels."
      else:
        play.statusMessage = "That minion can't attack this turn."
  elif play.selectedAttacker != 0 and cancel:
    play.selectedAttacker = 0
    play.statusMessage = "Attack canceled."

proc presentedHand*(play: TablePlay, game: GameState, owner: int): seq[Card] =
  ## The hand as shown: discarded cards stay in their slots until their
  ## beat sends them to the pile. Putting them back newest first undoes
  ## the discards in reverse, so every card returns to its own slot.
  result = game.players[owner].hand
  for i in countdown(play.queuedEvents.high, 0):
    let event = play.queuedEvents[i]
    if event.kind == TossVfx and event.target.owner == owner:
      result.insert(event.card, clamp(event.handIndex, 0, result.len))

proc deathClock*(play: TablePlay, game: GameState, player: int,
    time: float32): float32 =
  ## How long a hero has been dying, for its death animation; -1 while it
  ## is shown alive. A death whose beat never played (a restored game)
  ## shows its end.
  if player < play.heroDeaths.len and play.heroDeaths[player] >= 0:
    return time - play.heroDeaths[player]
  result = -1
  if game.dead(player):
    for event in play.queuedEvents:
      if event.kind == HeroDeathVfx and event.target.owner == player:
        return
    result = high(float32)

proc presentVisualEvents*(
    play: var TablePlay,
    game: var GameState,
    layout: TableLayout,
    time: float32
) =
  ## Visual events play beat by beat. A beat waits until the previous
  ## beats' animations and effects finish; a draw right after a draw
  ## only waits 0.25 s, so draws overlap. Until its beat plays, a slain
  ## card holds its place and a summoned or drawn card stays hidden.
  for event in game.takeVisualEvents():
    if event.kind == DeathVfx:
      var dying = DyingMinion(target: event.target, card: event.card,
        power: event.power,
        heroClass: game.players[event.target.owner].heroClass,
        boardIndex: event.boardIndex, held: true)
      if play.lungingMinion() == event.target.creatureId:
        # A slain attacker stays where its lunge landed.
        dying.atLunge = true
        dying.lungePoint = play.attackLungePoint(layout,
          play.liveBoardPose(layout, event.target.owner, event.boardIndex,
            event.boardCount))
      play.dyingMinions.add dying
    elif event.kind == BounceVfx:
      # Keep the card in its slot until its beat sends it home.
      play.dyingMinions.add DyingMinion(target: event.target, card: event.card,
        heroClass: game.players[event.target.owner].heroClass,
        boardIndex: event.boardIndex, held: true, bouncing: true)
    play.queuedEvents.add event
  # Before any beat plays: VFX positions are fixed when they start, so
  # the layout must already leave out summons that haven't appeared.
  play.countHiddenSummons(game.playerCount)
  while play.queuedEvents.len > 0:
    let beat = play.queuedEvents[0].beat
    var
      count = 0
      drawOnly = true
    while count < play.queuedEvents.len and
        play.queuedEvents[count].beat == beat:
      if play.queuedEvents[count].kind != DrawVfx:
        drawOnly = false
      inc count
    # A slain card whose death already played is part of that beat's
    # animation until it has left the board for its discard pile.
    var slainLeaving = play.discardFlights.len > 0
    for dying in play.dyingMinions:
      if not dying.held:
        slainLeaving = true
    let ready =
      if drawOnly and play.lastBeatWasDraw:
        time - play.lastDrawStart >= 0.25'f32
      else:
        play.animations.len == 0 and play.activeVfx.len == 0 and
          not slainLeaving
    if not ready:
      break
    var drawsThisBeat = 0
    for event in play.queuedEvents[0 ..< count]:
      case event.kind
      of DrawVfx:
        let owner = event.target.owner
        play.addDrawAnimation(game, layout, owner,
          hidden = not layout.drawFaceUp(owner),
          handIndex = event.boardIndex,
          delay = DrawStagger * drawsThisBeat.float32)
        inc drawsThisBeat
      of DeathVfx:
        for dying in play.dyingMinions.mitems:
          if dying.held and dying.target == event.target:
            dying.held = false
            break
      of SummonVfx:
        discard  # Leaving the queue is what reveals the minion.
      of HeroDeathVfx:
        let owner = event.target.owner
        while play.heroDeaths.len <= owner:
          play.heroDeaths.add -1
        play.heroDeaths[owner] = time
        # The hand this death discards is queued behind it, a card per
        # beat: share the sweep's two seconds between them.
        var cards = 0
        for queued in play.queuedEvents:
          if queued.kind == TossVfx and queued.target.owner == owner:
            inc cards
        while play.deathDiscard.len <= owner:
          play.deathDiscard.add 0
        play.deathDiscard[owner] =
          if cards > 0: DeathDiscardSeconds / cards.float32 else: 0.0'f32
      of TossVfx:
        let
          owner = event.target.owner
          dying =
            owner < play.deathDiscard.len and play.deathDiscard[owner] > 0
        play.animations.add newCardAnimation(event.card,
          game.players[owner].heroClass,
          layout.handPoses(owner, max(1, event.boardCount))[
            clamp(event.handIndex, 0, max(0, event.boardCount - 1))],
          stackTopPose(layout.discardPose(owner),
            game.players[owner].discardPile.len),
          suppressDiscardOwner = owner,
          duration =
            if dying: play.deathDiscard[owner] else: CardMoveDuration)
      of BounceVfx:
        let
          owner = event.target.owner
          source = play.presentedCardPose(game, layout, event.target,
            event.boardIndex, event.boardCount)
        for i in 0 ..< play.dyingMinions.len:
          if play.dyingMinions[i].bouncing and
              play.dyingMinions[i].target == event.target:
            play.dyingMinions.delete(i)
            break
        var flight = newCardAnimation(event.card,
          game.players[owner].heroClass, source,
          layout.handPoses(owner, max(1, game.players[owner].hand.len))[
            clamp(event.handIndex, 0,
              max(0, game.players[owner].hand.len - 1))],
          arcHeight = 1.15'f32, suppressHandOwner = owner,
          suppressHandIndex = event.handIndex, duration = 0.82'f32,
          trackingTarget = event.target,
          hidden = not layout.handVisible(owner))
        # Its bubble (same beat) forms first, then rides along.
        flight.elapsed = -0.2'f32
        play.animations.add flight
      else:
        let position =
          if event.target.kind == HeroChoice:
            layout.heroPosition(event.target.owner) + vec3(0, 1.25, 0)
          else:
            play.presentedCardPose(game, layout, event.target,
              event.boardIndex, event.boardCount).position +
              vec3(0, CardHeight, 0)
        play.activeVfx.add newVfx(event.kind, event.target, position,
          play.visualRng.rand(0x7fff_ffff))
    play.queuedEvents = play.queuedEvents[count .. ^1]
    play.lastBeatWasDraw = drawOnly
    if drawOnly:
      play.lastDrawStart = time
    play.countHiddenSummons(game.playerCount)
  for effect in play.activeVfx.mitems:
    if effect.kind == BubbleVfx:
      for animation in play.animations:
        if animation.trackingTarget == effect.target:
          effect.position = animation.animationPose().position +
            vec3(0, CardHeight, 0)
  for i in countdown(play.dyingMinions.high, 0):
    let dying = play.dyingMinions[i]
    var effectsPending = false
    for effect in play.activeVfx:
      if effect.target == dying.target:
        effectsPending = true
    if not effectsPending and not dying.held:
      let owner = dying.target.owner
      play.discardFlights.add newCardAnimation(dying.card, dying.heroClass,
        play.dyingPose(layout, i, game.players[owner].board.len),
        stackTopPose(layout.discardPose(owner),
          game.players[owner].discardPile.len),
        suppressDiscardOwner = owner)
      play.dyingMinions.delete(i)
  if play.castSpell.isSome and play.spellSettled(game):
    let held = play.castSpell.get
    play.discardFlights.add newCardAnimation(held.card, held.heroClass,
      layout.spellPose(held.owner),
      stackTopPose(layout.discardPose(held.owner),
        game.players[held.owner].discardPile.len),
      suppressDiscardOwner = held.owner)
    play.castSpell = none(CastSpell)

proc addTableCards*(
    solid: var SolidRenderer,
    faces: var CardRenderer,
    vfx: var VfxRenderer,
    sk: Silky,
    play: TablePlay,
    game: GameState,
    layout: TableLayout,
    time: float32,
    viewer: int,
    hoverIndex: int,
    hoveredBoard: Choice,
    viewerActs: bool,
    attackChoices: openArray[Choice] = [],
    selectedAttacker = 0,
    lungingMinion = 0
) =
  ## Every player's deck, discard pile and board, then the viewer's hand
  ## and the others', the cards in flight and the slain ones still shown.
  ## `viewerActs` lights the viewer's playable cards; `lungingMinion` is
  ## drawn by its attack instead of on the board.
  for playerIndex in 0 ..< game.playerCount:
    let
      player = game.players[playerIndex]
      hiddenDiscardCards =
        play.queuedTosses(playerIndex) +
        play.animations.discardCardsSuppressed(playerIndex) +
        play.discardFlights.discardCardsSuppressed(playerIndex) +
        play.dyingDiscards(playerIndex) +
        play.spellDiscards(playerIndex)
    solid.addCardStack(
      faces, sk,
      layout.deckPose(playerIndex),
      player.deck.len,
      player.heroClass,
    )
    solid.addCardStack(
      faces, sk,
      layout.discardPose(playerIndex),
      max(0, player.discardPile.len - hiddenDiscardCards),
      player.heroClass,
      hidden = false,
      card =
        if player.discardPile.len > hiddenDiscardCards:
          player.discardPile[player.discardPile.high - hiddenDiscardCards]
        else:
          Card()
    )
    for minionIndex in 0 ..< player.board.len:
      let
        pose = play.liveBoardPose(layout, playerIndex, minionIndex,
          player.board.len)
        minion = player.board[minionIndex]
        minionChoice = creatureChoice(
          playerIndex,
          minion.id
        )
        targetable =
          (play.pendingTargeting and
            play.pendingChoices.choiceIsLegal(minionChoice)) or
          attackChoices.choiceIsLegal(minionChoice)
        attackerSelected =
          playerIndex == game.currentPlayer and
          minion.id == selectedAttacker
      if play.animations.boardCardSuppressed(minion.id) or
          play.queuedEvents.queuedSummon(minion.id):
        continue
      if lungingMinion != 0 and minion.id == lungingMinion:
        continue
      solid.addCard(
        faces, sk,
        pose,
        player.heroClass,
        false,
        true,
        hoveredBoard == minionChoice or attackerSelected,
        targetable or attackerSelected,
        card = minion.card,
        currentPower = minion.power,
        currentToughness = minion.currentToughness,
        damageFlash = play.activeVfx.flashStrength(minionChoice),
        lostKeywords = minion.lostKeywords
      )
      vfx.addCardGlow(pose,
          hoveredBoard == minionChoice or attackerSelected,
          targetable or attackerSelected,
          play.pendingTargeting or attackerSelected,
          time)

  let viewerHand = play.presentedHand(game, viewer)
  for i, pose in layout.handPoses(viewer, viewerHand.len):
    if play.animations.handCardSuppressed(viewer, i) or
        play.queuedEvents.queuedDraw(viewer, i):
      continue
    let
      card = viewerHand[i]
      tossingHere = play.tossPicking and viewer == game.pendingToss.player
      picked = tossingHere and i in play.tossPicks
    solid.addCard(
      faces, sk,
      pose,
      game.players[viewer].heroClass,
      not layout.handVisible(viewer),
      (viewerActs and card.energyCost <= game.players[viewer].energy) or
        tossingHere,
      (
        i == hoverIndex or
        (play.pendingTargeting and i == play.pendingCardIndex)
      ),
      targetable = picked,
      card = card
    )
    vfx.addCardGlow(pose,
        i == hoverIndex or
          (play.pendingTargeting and i == play.pendingCardIndex),
        picked, play.pendingTargeting or tossingHere, time)

  for offset in 1 ..< game.playerCount:
    let
      other = (viewer + offset) mod game.playerCount
      hand = play.presentedHand(game, other)
    for i, pose in layout.handPoses(other, hand.len):
      if play.animations.handCardSuppressed(other, i) or
          play.queuedEvents.queuedDraw(other, i):
        continue
      solid.addCard(
        faces, sk,
        pose,
        game.players[other].heroClass,
        not layout.handVisible(other),
        false,
        false,
        card = hand[i]
      )

  if play.castSpell.isSome and not play.animations.castSpellSuppressed():
    # A played spell floats above the board until its effects finish.
    let held = play.castSpell.get
    solid.addCard(
      faces, sk,
      layout.spellPose(held.owner),
      held.heroClass,
      false, true, false,
      card = held.card
    )

  solid.addFlyingCards(faces, sk, play.animations & play.discardFlights)

  for i, dying in play.dyingMinions:
    solid.addCard(
      faces, sk,
      play.dyingPose(layout, i,
        game.players[dying.target.owner].board.len),
      dying.heroClass,
      false, true, false,
      card = dying.card,
      currentPower = dying.power,
      currentToughness = 0,
      damageFlash = play.activeVfx.flashStrength(dying.target)
    )

proc heroLook*(
    play: TablePlay,
    game: GameState,
    player: int,
    hoveredTarget: Choice,
    attackChoices: openArray[Choice] = [],
    attackHoverTarget = Canceled
): tuple[targetable, hovered: bool, tint: Color, sizeFactor: float32] =
  ## How a hero is shown: lit as a target, red when the target is hovered,
  ## dimmed while another is being chosen, and larger on its own turn.
  let
    heroTarget = heroChoice(player)
    spellTargetable =
      play.pendingTargeting and
      play.pendingChoices.choiceIsLegal(heroTarget)
    attackTargetable =
      attackChoices.choiceIsLegal(heroTarget) and not play.pendingTargeting
    targetable = spellTargetable or attackTargetable
    spellTargetHovered = spellTargetable and hoveredTarget == heroTarget
    attackTargetHovered = attackTargetable and
      attackHoverTarget == heroTarget
    targetHovered = spellTargetHovered or attackTargetHovered
    damageFlash = play.activeVfx.flashStrength(heroTarget)
  result.targetable = targetable
  result.hovered = targetHovered
  result.tint =
    if damageFlash > 0:
      color(1.0, 1.0, 1.0, 1)
    elif targetHovered:
      color(1.5, 0.52, 0.52, 1)
    elif targetable:
      color(1.18, 0.85, 0.85, 1)
    elif play.pendingTargeting:
      color(0.52, 0.52, 0.58, 1)
    elif player == game.currentPlayer:
      color(1.08, 1.08, 1.08, 1)
    else:
      color(0.72, 0.72, 0.78, 1)
  result.sizeFactor =
    if targetHovered:
      1.08'f32
    elif targetable:
      1.02'f32
    elif player == game.currentPlayer:
      1.0'f32
    else:
      0.92'f32

proc startTossPicking*(play: var TablePlay, game: GameState) =
  ## A discard waits for the human: pick cards in hand.
  let pending = game.pendingToss
  play.tossPicking = true
  play.tossPicks.setLen(0)
  play.selectedAttacker = 0
  play.statusMessage = &"{pending.source}: choose cards to discard."

proc startTriggerTargeting*(play: var TablePlay, game: GameState) =
  ## A trigger of the human's waits for its targets.
  let waiting = game.waitingTriggerRules()
  play.pendingTargeting = true
  play.pendingTrigger = true
  play.pendingCard = waiting.card
  play.pendingCardIndex = -1
  play.pendingPicks.setLen(0)
  play.pendingChoices = game.triggerChoices()
  play.selectedAttacker = 0
  play.statusMessage = &"{waiting.card.name}'s trigger needs a target."

proc playHelp*(play: TablePlay, human: bool): string =
  ## The standing hint for what the mouse does now.
  if play.attackActive:
    "Minions are attacking..."
  elif play.selectedAttacker != 0:
    "Click an enemy minion or hero to attack. Right-click cancels."
  elif play.tossPicking:
    "Click cards in your hand to discard them."
  elif play.pendingTargeting and play.pendingTrigger:
    "Choose a highlighted target, or the empty board for none."
  elif play.pendingTargeting and play.pendingCard.kind != Spell:
    "Choose a highlighted target. Right-click for no target."
  elif play.pendingTargeting:
    "Choose a highlighted target. Right-click cancels."
  elif human:
    "Hover to inspect a card. Select a card to play."
  else:
    "Hover to inspect a card."

proc addAttackCard*(
    solid: var SolidRenderer,
    faces: var CardRenderer,
    vfx: var VfxRenderer,
    sk: Silky,
    play: TablePlay,
    game: GameState,
    layout: TableLayout,
    time: float32
) =
  ## The lunging attacker, out toward its target and back to its slot.
  let atkMinionId = play.lungingMinion()
  if atkMinionId == 0:
    return
  let atkLocation = game.minionLocation(atkMinionId)
  if not atkLocation.found:
    return
  let
    atkMinion = game.players[atkLocation.player].board[atkLocation.index]
    atkFromPose = play.liveBoardPose(layout, atkLocation.player,
      atkLocation.index, game.players[atkLocation.player].board.len)
    atkForwardPos = CardPose(position: play.attackLungePoint(layout,
      atkFromPose), yaw: atkFromPose.yaw)
    atkDuration = if play.attackForward: AttackLungeDuration
      else: AttackReturnDuration
    atkRaw = clamp(play.attackElapsed / atkDuration, 0.0'f32, 1.0'f32)
    atkEased = atkRaw * atkRaw * (3.0'f32 - 2.0'f32 * atkRaw)
  var atkPose: CardPose
  if play.attackForward:
    atkPose.position = atkFromPose.position +
      (atkForwardPos.position - atkFromPose.position) * atkEased
    atkPose.position.y += sin(PI.float32 * atkRaw) * 0.8'f32
  else:
    atkPose.position = atkForwardPos.position +
      (atkFromPose.position - atkForwardPos.position) * atkEased
    atkPose.position.y += sin(PI.float32 * atkRaw) * 0.4'f32
  atkPose.yaw = atkFromPose.yaw
  atkPose.frameYaw = atkFromPose.frameYaw
  solid.addCard(
    faces, sk,
    atkPose,
    game.players[atkLocation.player].heroClass,
    false, true, false,
    card = atkMinion.card,
    currentPower = atkMinion.power,
    currentToughness = atkMinion.currentToughness,
    lostKeywords = atkMinion.lostKeywords
  )
  vfx.addCardGlow(atkPose, true, true, true, time)

proc addAttackRing*(vfx: var VfxRenderer, play: TablePlay, eye: Vec3) =
  ## The ring under what the attackers are lunging at.
  if play.attackActive and not play.attackTarget.isCanceled:
    vfx.addTargetRing(
      play.attackPoint + vec3(0, 0.04, 0),
      eye, 0.95, 0.8'f32)

type
  BotClock* = object
    ## Paces bot decisions so the table can follow them.
    wait*: float32  ## Time left before the next bot decision.
    plays*: int  ## Cards the current bot played this turn.

const BotThinkSeconds* = 1.2'f32

proc initBotClock*(): BotClock =
  BotClock(wait: BotThinkSeconds)

proc botTurnStatus(bots: openArray[BotVm], player: int): string =
  if player < bots.len and bots[player] != nil: "Bot is thinking..."
  else: "Your turn. Select a card to play."

proc updateBots*(
    play: var TablePlay,
    game: var GameState,
    layout: TableLayout,
    bots: openArray[BotVm],
    clock: var BotClock,
    humanActs: proc(): bool,
    dt: float32
): bool =
  ## Plays the seats that have a bot, one decision at a time once the table
  ## is still: answers their discards and triggers, plays their cards, and
  ## at the end of their turn attacks the next living player's hero with
  ## every ready minion. A waiting discard or trigger of the human's starts
  ## their choice instead. True on the frame a bot's turn ended.
  if game.waitingToss and not play.tossPicking and
      not play.pendingTargeting and play.presentationIdle(game) and
      not play.attackActive and not game.gameOver:
    let pending = game.pendingToss
    if humanActs():
      play.startTossPicking(game)
    else:
      clock.wait -= dt
      if clock.wait <= 0:
        if game.applyBotAction(game.nextBotAction()):
          play.statusMessage = &"{pending.source}: the bot discards."
        clock.wait = BotThinkSeconds

  if game.waitingTrigger and
      not game.waitingToss and not play.pendingTargeting and
      play.presentationIdle(game) and not play.attackActive and
      not game.gameOver:
    let waiting = game.waitingTriggerRules()
    if humanActs():
      play.startTriggerTargeting(game)
    else:
      clock.wait -= dt
      if clock.wait <= 0:
        let before = game.copyGameState()
        if game.applyBotAction(game.nextBotAction()):
          play.animateTransition(layout, before, game)
          play.statusMessage = &"{waiting.card.name}'s trigger resolves."
        clock.wait = BotThinkSeconds

  if game.currentPlayer < bots.len and bots[game.currentPlayer] != nil and
      not game.waitingChoice and
      play.presentationIdle(game) and not play.attackActive and
      not game.gameOver:
    clock.wait -= dt
    if clock.wait <= 0:
      let current = game.currentPlayer
      discard game.takeVisualEvents()
      let before = game.copyGameState()
      let decision = bots[current].runDecision(game)
      case decision
      of BotPlayedCard:
        play.animateTransition(layout, before, game)
        inc clock.plays
        play.statusMessage = "Bot is playing..."
      of BotEndedTurn:
        let attackers = game.eligibleAttackers()
        if attackers.len > 0:
          play.startAttack(game, layout, attackers,
            heroChoice(game.nextPlayer(game.currentPlayer)),
            finishTurn = true)
          play.statusMessage = "Bot is attacking..."
        else:
          game.finishTurn()
          play.animateTransition(layout, before, game)
          clock.plays = 0
          play.statusMessage = bots.botTurnStatus(game.currentPlayer)
          result = true
      of BotFailed:
        play.statusMessage = "Bot error: " & bots[current].lastError
      clock.wait = BotThinkSeconds

  if play.advanceAttack(game, dt):
    if play.attackFinishTurn and not game.gameOver:
      let before = game.copyGameState()
      game.finishTurn()
      play.animateTransition(layout, before, game)
      clock.plays = 0
      clock.wait = BotThinkSeconds
      play.statusMessage = bots.botTurnStatus(game.currentPlayer)
      result = true
