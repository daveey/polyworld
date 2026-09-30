import
  content, maps

type
  RelationState* = enum
    Neutral, WarPending, AtWar, Allied, AllianceEnding
  OfferKind* = enum
    NoOffer, PeaceOffer, AllianceOffer
  DiplomacyCommand* = enum
    DeclareWar, WithdrawWar, OfferPeace, OfferAlliance,
    AcceptOffer, DeclineOffer, WithdrawOffer, EndAlliance
  DiplomacySettings* = object
    warGraceSeconds*: int32 = 10
    offerSeconds*: int32 = 60
  Relation* = object
    state*: RelationState
    initiator*, deadline*: int32
    offer*: OfferKind
    sender*, offerId*, offerDeadline*: int32
    offerAfter*, warAfter*: array[2, int32]
  Diplomacy* = object
    settings*: DiplomacySettings
    players*, nextOfferId*: int32
    pairs*: seq[Relation]

proc validate*(settings: DiplomacySettings) =
  ## Rejects invalid timings before converting seconds to ticks.
  if settings.warGraceSeconds notin 1'i32 .. 3600'i32 or
    settings.offerSeconds notin 1'i32 .. 3600'i32:
      raise newException(LvdError, "Diplomacy delays must be 1 .. 3600 seconds.")

proc initDiplomacy*(players: int, settings = DiplomacySettings()): Diplomacy =
  ## Starts one neutral relationship per unordered player pair.
  settings.validate()
  let count = int64(players) * int64(players - 1) div 2
  if players < 1 or count > int64(high(int)):
    raise newException(LvdError, "Invalid diplomacy roster size.")
  result = Diplomacy(
    settings: settings,
    players: int32(players),
    nextOfferId: 1,
    pairs: newSeq[Relation](int(count))
  )

proc pairIndex*(diplomacy: Diplomacy, first, second: int32): int =
  ## Finds the unique pair record, or -1 for self and invalid players.
  if first < 0 or second < 0 or first == second or
    first >= diplomacy.players or second >= diplomacy.players:
      return -1
  let
    low = min(first, second)
    high = max(first, second)
  int(int64(low) * (int64(diplomacy.players) * 2 - low - 1) div 2 +
    high - low - 1)

proc relation*(diplomacy: Diplomacy, first, second: int32): Relation =
  ## Returns pair state, with neutral fallthrough for invalid pairs.
  let index = diplomacy.pairIndex(first, second)
  if index >= 0:
    diplomacy.pairs[index]
  else:
    Relation()

proc atWar*(diplomacy: Diplomacy, first, second: int32): bool =
  ## Only completed war declarations permit combat.
  diplomacy.relation(first, second).state == AtWar

proc sharesVision*(diplomacy: Diplomacy, first, second: int32): bool =
  ## Alliance withdrawal keeps vision until its deadline.
  diplomacy.relation(first, second).state in {Allied, AllianceEnding}

proc clearOffer(pair: var Relation) =
  ## Removes an offer without changing its resend cooldowns.
  pair.offer = NoOffer
  pair.sender = 0
  pair.offerId = 0
  pair.offerDeadline = 0

proc setState(pair: var Relation, state: RelationState) =
  ## Completes a transition and discards obsolete deadlines and offers.
  pair.state = state
  pair.initiator = 0
  pair.deadline = 0
  pair.clearOffer()

proc advance*(diplomacy: var Diplomacy, tick: int32) =
  ## Resolves deadlines before decisions and combat at this tick.
  for pair in diplomacy.pairs.mitems:
    if pair.offer != NoOffer and tick >= pair.offerDeadline:
      pair.clearOffer()
    if pair.deadline > 0 and tick >= pair.deadline:
      case pair.state
      of WarPending:
        # A peace offer remains valid when the war warning finishes.
        pair.state = AtWar
        pair.deadline = 0
        pair.initiator = 0
      of AllianceEnding:
        pair.setState(Neutral)
      else:
        discard

proc eliminate*(diplomacy: var Diplomacy, player: int32) =
  ## Clears all relationships and offers belonging to a defeated player.
  for other in 0'i32 ..< diplomacy.players:
    let index = diplomacy.pairIndex(player, other)
    if index >= 0:
      diplomacy.pairs[index] = Relation()

proc apply*(
  diplomacy: var Diplomacy,
  player, other, tick: int32,
  command: DiplomacyCommand,
  offerId = 0'i32
): bool =
  ## Validates one explicit command without changing rejected state.
  let index = diplomacy.pairIndex(player, other)
  if index < 0:
    return false
  let
    side = int(player > other)
    grace = diplomacy.settings.warGraceSeconds * TickRate
    duration = diplomacy.settings.offerSeconds * TickRate
  var pair = diplomacy.pairs[index]
  case command
  of DeclareWar:
    if pair.state != Neutral or tick < pair.warAfter[side]:
      return false
    pair.setState(WarPending)
    pair.initiator = player
    pair.deadline = tick + grace
  of WithdrawWar:
    if pair.state != WarPending or pair.initiator != player:
      return false
    pair.setState(Neutral)
    pair.warAfter[side] = tick + grace
  of EndAlliance:
    if pair.state != Allied:
      return false
    pair.setState(AllianceEnding)
    pair.initiator = player
    pair.deadline = tick + grace * 2
  of OfferPeace, OfferAlliance:
    let kind = if command == OfferPeace: PeaceOffer else: AllianceOffer
    if (kind == PeaceOffer and pair.state notin {AtWar, WarPending}) or
      (kind == AllianceOffer and pair.state != Neutral):
        return false
    if pair.offer == kind and pair.sender == other:
      pair.setState(if kind == PeaceOffer: Neutral else: Allied)
    else:
      if pair.offer != NoOffer or tick < pair.offerAfter[side] or
        diplomacy.nextOfferId == high(int32):
          return false
      pair.offer = kind
      pair.sender = player
      pair.offerId = diplomacy.nextOfferId
      pair.offerDeadline = tick + duration
      pair.offerAfter[side] = pair.offerDeadline + grace
      inc diplomacy.nextOfferId
  of AcceptOffer, DeclineOffer, WithdrawOffer:
    if pair.offer == NoOffer or pair.offerId != offerId or
      tick >= pair.offerDeadline:
        return false
    if command == WithdrawOffer:
      if pair.sender != player:
        return false
    elif pair.sender == player:
      return false
    let senderSide = int(pair.sender == max(player, other))
    pair.offerAfter[senderSide] = tick + grace
    if command == AcceptOffer:
      pair.setState(if pair.offer == PeaceOffer: Neutral else: Allied)
    else:
      pair.clearOffer()
  diplomacy.pairs[index] = pair
  true
