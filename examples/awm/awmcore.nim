## Core card, rule, target, choice, and effect types for AWM.
##
## Card definitions list their rules with `rules(...)`: immutable,
## polymorphic Rule objects shared by every copy of the card. Each Rule
## supplies both its displayed text and its executable program. Target objects do the same for target text and
## validated player choice.

import std/[macros, options, strutils]

type
  HeroClass* = enum
    Archer
    Warrior
    Mage

  CardKind* = enum
    Minion
    Spell
    Trinket  ## Stays in play on its owner's board, but isn't a minion.

  ChoiceKind* = enum
    CanceledChoice
    NoTargetChoice
    HeroChoice
    CreatureChoice

  Choice* = object
    ## A selected game object. `owner` is the player index for both heroes
    ## and creatures, which lets targets enforce friendly/enemy restrictions.
    owner*: int
    case kind*: ChoiceKind
    of CanceledChoice, NoTargetChoice, HeroChoice:
      discard
    of CreatureChoice:
      creatureId*: int

  TargetRelation* = enum
    Friendly
    Enemy
    Any

  TargetKind* = enum
    ## Game objects a target may select. `Minion` overloads CardKind.Minion;
    ## the expected type picks the right one, so `target({Minion, Hero})`
    ## reads like rules text.
    Hero
    Minion
    Opponent
      ## A player, not a card: `target({Opponent})` picks one living
      ## opponent, as in `draw(1, target({Opponent}))`.

  VfxKind* = enum
    NoVfx
    LightningVfx
    BubbleVfx
    DamageFlashVfx
    ArrowVfx
    # Presentation cue, not a card VFX: a minion died. The UI holds its card
    # in place until the effects aimed at it finish, then sends it to discard.
    DeathVfx
    # A volley of arrows raining onto each minion a query hits.
    ManyArrowsVfx
    # Blades rise and spin away on a gust around each minion a buff reaches.
    SwordsIntoTheWindVfx
    # A glowing shield settles over each minion a toughness buff reaches.
    MightyShieldsVfx
    # A crossed sword and shield rise over one buffed minion.
    SwordAndShieldVfx
    # An arrow snaps in half: the minion loses Ranged.
    MeleeVfx
    # Two blades cross with a burst of sparks where minions fight.
    SwordClashVfx
    # A sword cracks and falls apart over a minion losing power.
    SwordBreakVfx
    # A glob of ooze drops onto a minion and bursts.
    OozeSplatVfx
    # Presentation cue, not a card VFX: a card moved from a deck to a hand.
    # The UI plays the regular draw animation into that hand slot.
    DrawVfx
    # Presentation cue, not a card VFX: a minion was summoned onto the board.
    # The UI keeps it hidden until its beat plays.
    SummonVfx
    # Presentation cue, not a card VFX: a minion returns to its owner's hand.
    # The UI flies it from its board slot, carrying any VFX aimed at it.
    BounceVfx
    # Presentation cue, not a card VFX: a card was discarded from a hand.
    TossVfx
    # Presentation cue, not a card VFX: a hero died. The UI plays its death
    # animation while its hand is discarded, one card at a time.
    HeroDeathVfx

  Keyword* = enum
    ## Printed minion keywords. Each prints as its own line of rules text.
    Ranged

  Owner* = enum
    ## Players, relative to the one the rules run for.
    You
    AnyOpponent
      ## Any one opponent, for triggers: `on(attacked(AnyOpponent), ...)`.
      ## An effect on one chosen opponent uses `target({Opponent})`.
    AllOpponents
      ## Every opponent, everywhere else: `draw(1, AllOpponents)`,
      ## `game.board.choose(owner: AllOpponents)`.

  Zone* = enum
    ## Game zones rules can query. Hand, deck and discard will join the board.
    BoardZone

  Target* = ref object of RootObj
    ## Base target. Concrete targets control text and legal choices.
    vfx*: VfxKind

  ObjectTarget* = ref object of Target
    ## Selects one hero and/or minion, restricted by its owner's relation.
    kinds*: set[TargetKind]
    relation*: TargetRelation

  RuleValueKind* = enum
    ## The game-state reads a rule parameter can make. Each is plain data,
    ## so bots, tools and text understand a value without running it.
    FixedValue   ## Written on the card: `2`, `You`.
    CardNamed    ## Card: a base-set card by printed name, found on resolve.
    SelfCard     ## Card: the card in play these rules belong to.
    PowerOf      ## int: a minion's current power.
    ToughnessOf  ## int: a minion's current toughness.
    OwnerOf      ## Owner: who controls what a target chose.
    CountOf      ## int: how many cards a query matches.
    Sum          ## int: `a + b`.
    Difference   ## int: `a - b`.

  RuleValue*[T] = object
    ## A rule parameter, worked out when the card resolves. Plain values
    ## convert, reads come from targets and queries, and `+`/`-` combine
    ## numbers: `summon(getTarget().toughness + 1, "Ooze", getTarget().owner)`.
    ## Every `value`/`text` rejects kinds that don't produce its type; the
    ## constructors below never build those.
    case kind*: RuleValueKind
    of FixedValue:
      fixed*: T
    of CardNamed:
      name*: string
    of SelfCard:
      discard
    of PowerOf, ToughnessOf, OwnerOf:
      target*: Target
    of CountOf:
      query*: CardQuery
    of Sum, Difference:
      operands*: seq[RuleValue[T]]

  PickedTarget* = ref object of Target
    ## `getTarget(n)`: whatever the card's nth target (from 0) chose. It
    ## makes no new choice.
    index*: int

  Rule* = ref object of RootObj
    ## Base rule. Concrete rules control text and execution.

  Rules* = seq[Rule]

  Card* = object
    name*: string
    energyCost*: int
    class*: Option[HeroClass]
    rules*: Rules
    case kind*: CardKind
    of Minion:
      power*: int
      toughness*: int
    of Spell, Trinket:
      discard

  CardLookup* = proc(name: string): Card {.nimcall, gcsafe.}
    ## Finds a card by printed name, for rules that create cards.

  ChoiceSelector* = proc(
    prompt: string,
    choices: seq[Choice]
  ): Choice {.closure, gcsafe.}

  EffectKind* = enum
    DamageHeroEffect
    DamageCreatureEffect
    BounceCreatureEffect
    ModifyStatsEffect
    LoseKeywordEffect
    FightEffect
    SummonEffect
    DestroyEffect
    DrawEffect
    TossEffect
    TargetVfxEffect

  Effect* = object
    ## Rules emit effects; the authoritative game applies them.
    beat*: int
      ## Which rule of the resolution emitted it. Presentation plays each
      ## beat after the previous one finishes.
    case kind*: EffectKind
    of DamageHeroEffect:
      heroPlayer*: int
      heroDamage*: int
    of DamageCreatureEffect:
      damagedCreatureId*: int
      creatureDamage*: int
    of BounceCreatureEffect:
      bouncedCreatureId*: int
    of ModifyStatsEffect:
      ## A permanent power/toughness change. It lasts while the minion stays
      ## on the board; a minion that leaves returns to its printed stats.
      modifiedCreatureId*: int
      powerChange*: int
      toughnessChange*: int
    of LoseKeywordEffect:
      ## Permanent while the minion stays on the board, like stat changes.
      keywordLoserId*: int
      lostKeyword*: Keyword
    of FightEffect:
      ## Both minions deal their power to each other at once, as in combat.
      ## Resolved when applied, so earlier effects on the card count.
      fighterId*, opponentId*: int
    of SummonEffect:
      ## A new minion enters at the right of its owner's board. Its id was
      ## handed out while the rules ran, so later rules could reach it.
      summonedId*, summonedOwner*: int
      summonedCard*: Card
    of DestroyEffect:
      ## The card in play goes to its owner's discard pile, whatever its
      ## toughness.
      destroyedId*: int
    of DrawEffect:
      ## Drawing from an empty deck loses the game.
      drawPlayer*, drawCount*: int
    of TossEffect:
      ## The player chooses cards from hand to discard. The rest of the
      ## resolution waits until they do.
      tossPlayer*, tossCount*: int
      tossSource*: string  ## The card that asked, for the prompt.
      tossText*: string    ## Its rule text, for the prompt.
    of TargetVfxEffect:
      targetVfx*: VfxKind
      visualTarget*: Choice

  BoardCard* = object
    choice*: Choice
    card*: Card
    power*, toughness*: int  ## Live stats, counting damage and buffs.

  GameView* = object
    ## The live game as rules see it when they resolve.
    board*: seq[BoardCard]
    nextMinionId*: int  ## The id the next minion to enter play gets.

  AttackerTarget* = ref object of Target
    ## `getAttacker()`: the minion whose attack fired this trigger. It makes
    ## no choice, and if the attacker has left the board it cancels, which
    ## cancels the whole trigger.

  RuleContext* = object
    ## The rule engine sees legal game objects and emits effects, but remains
    ## independent from the concrete GameState in awm.nim.
    sourcePlayer*: int
    sourceId*: int  ## The card in play these rules belong to; 0 for a spell.
    attacker*: Choice  ## The attacker, for rules an attack triggered.
    allowNoTarget*: bool
    heroes*: seq[Choice]  ## Every living player's hero.
    seats*: int  ## Every player, living or dead.
    creatures*: seq[Choice]
    game*: GameView
    selector*: ChoiceSelector
    picks*: seq[Choice]
      ## Preselected answers, one per card target in order. When empty, the
      ## selector is asked instead.
    targets*: seq[Choice]
      ## What each target chose so far while resolving, for `getTarget`.
    cardNamed*: CardLookup
    effects*: seq[Effect]

  GameQuery* = object
    ## `game` inside `rules(...)`. Rules are built once, before any game
    ## exists, so `game.board.choose(...)` builds a query that reads the
    ## live `GameView` each time the card resolves.

  ZoneQuery* = object
    zone*: Zone

  CardQuery* = ref object
    ## Every card in `zone` matching the kinds and owner, found on resolve.
    zone*: Zone
    kinds*: set[CardKind]
    anyOwner*: bool  ## No `owner:` filter was given.
    includeSelf*: bool  ## false: leave out the card these rules belong to.
    owner*: RuleValue[Owner]

  SelectionKind* = enum
    SelectTarget  ## A player picks one: `target({Minion})`.
    SelectQuery   ## Every match, nothing to pick: `game.board.choose(...)`.

  Selection* = object
    ## What a rule acts on. Targets and queries both convert to it, so
    ## `target(...)` and `game.board.choose(...)` are interchangeable.
    case kind*: SelectionKind
    of SelectTarget:
      target*: Target
    of SelectQuery:
      query*: CardQuery

  DamageRule* = ref object of Rule
    amount*: RuleValue[int]
    what*: Selection
    vfx*: VfxKind  ## Played on each selected object.

  BounceRule* = ref object of Rule
    what*: Selection
    vfx*: VfxKind

  KeywordRule* = ref object of Rule
    ## A static ability. It has no on-play program; the engine reads it
    ## through `keywords`.
    keyword*: Keyword

  StatsRule* = ref object of Rule
    ## Permanently changes power and toughness.
    power*, toughness*: RuleValue[int]
    what*: Selection
    vfx*: VfxKind
    removes*: bool  ## Subtracts its amounts, printed "-1/-0".

  DestroyRule* = ref object of Rule
    what*: Selection
    vfx*: VfxKind

  DestroyCardRule* = ref object of Rule
    ## Destroys a card in play named by a value: `destroy(self())`.
    card*: RuleValue[Card]

  DrawRule* = ref object of Rule
    count*: RuleValue[int]
    player*: RuleValue[Owner]

  TossRule* = ref object of Rule
    ## Discard cards the player chooses from their hand.
    count*: RuleValue[int]
    player*: RuleValue[Owner]

  TriggerKind* = enum
    NextTurnStart  ## A player's next turn starts, after their draw.
    HeroAttacked   ## A player's hero is attacked, after the damage.
    CardAttacked   ## A card in play is attacked, after the damage.

  Trigger* = object
    ## When `on(...)` rules resolve instead of on play.
    case kind*: TriggerKind
    of NextTurnStart, HeroAttacked:
      player*: RuleValue[Owner]
    of CardAttacked:
      card*: RuleValue[Card]

  OnRule* = ref object of Rule
    ## Rules a card in play resolves when its trigger fires, not on play.
    trigger*: Trigger
    rules*: Rules

  SummonRule* = ref object of Rule
    ## Creates new minions from a named card. Nothing to choose.
    count*: RuleValue[int]
    card*: RuleValue[Card]
    owner*: RuleValue[Owner]

  LoseKeywordRule* = ref object of Rule
    keyword*: Keyword
    what*: Selection
    vfx*: VfxKind

  FightRule* = ref object of Rule
    ## Two minions fight each other, as in combat, without attacking.
    fighter*, opponent*: Target
    vfx*: VfxKind

const
  Canceled* = Choice(kind: CanceledChoice, owner: -1)
  NoTarget* = Choice(kind: NoTargetChoice, owner: -1)

proc className*(heroClass: HeroClass): string =
  case heroClass
  of Archer:
    "Archer"
  of Warrior:
    "Warrior"
  of Mage:
    "Mage"

proc heroChoice*(player: int): Choice =
  Choice(kind: HeroChoice, owner: player)

proc creatureChoice*(owner, creatureId: int): Choice =
  Choice(
    kind: CreatureChoice,
    owner: owner,
    creatureId: creatureId
  )

proc isCanceled*(choice: Choice): bool =
  choice.kind == CanceledChoice

proc isNoTarget*(choice: Choice): bool =
  choice.kind == NoTargetChoice

proc `==`*(a, b: Choice): bool =
  if a.kind != b.kind or a.owner != b.owner:
    return false
  case a.kind
  of CanceledChoice, NoTargetChoice, HeroChoice:
    true
  of CreatureChoice:
    a.creatureId == b.creatureId

proc relationAllows(
    relation: TargetRelation,
    sourcePlayer,
    owner: int
): bool =
  case relation
  of Friendly:
    owner == sourcePlayer
  of Enemy:
    owner != sourcePlayer
  of Any:
    true

method text*(target: Target): string {.base, gcsafe.} =
  "a target"

method candidates*(
    target: Target,
    context: RuleContext
): seq[Choice] {.base, gcsafe.} =
  discard (target, context)

method text*(target: ObjectTarget): string =
  if target.kinds == {Opponent}:
    "an opponent"
  elif target.kinds == {Hero}:
    case target.relation
    of Friendly:
      "your hero"
    of Enemy:
      "an enemy hero"
    of Any:
      "a hero"
  elif target.kinds == {TargetKind.Minion}:
    case target.relation
    of Friendly:
      "a friendly minion"
    of Enemy:
      "an enemy minion"
    of Any:
      "a minion"
  else:
    case target.relation
    of Friendly:
      "a friendly target"
    of Enemy:
      "an enemy target"
    of Any:
      "any target"

method candidates*(
    target: ObjectTarget,
    context: RuleContext
): seq[Choice] =
  if Hero in target.kinds:
    for choice in context.heroes:
      if choice.kind == HeroChoice and
          target.relation.relationAllows(context.sourcePlayer, choice.owner):
        result.add choice
  if Opponent in target.kinds:
    # A player is picked by their hero; only the living have one.
    for choice in context.heroes:
      if choice.kind == HeroChoice and choice.owner != context.sourcePlayer and
          choice notin result:
        result.add choice
  if TargetKind.Minion in target.kinds:
    for choice in context.creatures:
      if choice.kind == CreatureChoice and
          target.relation.relationAllows(context.sourcePlayer, choice.owner):
        result.add choice

proc select(
    context: RuleContext,
    prompt: string,
    choices: seq[Choice]
): Choice =
  ## The preselected pick for the next target, else the selector's answer.
  if context.picks.len > 0:
    if context.targets.len < context.picks.len:
      context.picks[context.targets.len]
    else:
      Canceled
  elif context.selector.isNil:
    Canceled
  else:
    context.selector(prompt, choices)

method choose*(target: Target, context: var RuleContext): Choice {.base, gcsafe.} =
  ## Takes the next pick (or asks the selector), then validates that it is
  ## one of this target's legal candidates. Every target that resolves is
  ## recorded, so `getTarget(n)` lines up with the card's nth target.
  let choices = target.candidates(context)
  result = Canceled
  if choices.len == 0:
    if context.allowNoTarget:
      result = NoTarget
  else:
    let selected = context.select(target.text(), choices)
    if selected.kind == NoTargetChoice and context.allowNoTarget:
      result = NoTarget
    else:
      for choice in choices:
        if choice == selected:
          if target.vfx != NoVfx:
            context.effects.add Effect(kind: TargetVfxEffect,
              targetVfx: target.vfx, visualTarget: selected)
          result = selected
          break
  if not result.isCanceled:
    context.targets.add result

proc ordinal(index: int): string =
  case index
  of 0: "first"
  of 1: "second"
  of 2: "third"
  else: $(index + 1) & "th"

method text*(target: PickedTarget): string =
  "the " & target.index.ordinal() & " target"

method choose*(target: PickedTarget, context: var RuleContext): Choice =
  if target.index < context.targets.len:
    context.targets[target.index]
  else:
    Canceled

method makesChoice*(target: Target): bool {.base, gcsafe.} =
  ## Whether a player picks this target. References to an earlier pick or
  ## to the attacker don't.
  true

method makesChoice*(target: PickedTarget): bool =
  false

method makesChoice*(target: AttackerTarget): bool =
  false

method text*(target: AttackerTarget): string =
  "the attacker"

method choose*(target: AttackerTarget, context: var RuleContext): Choice =
  ## The attacker while it's still on the board, else Canceled.
  if context.attacker.kind == CreatureChoice:
    for entry in context.game.board:
      if entry.choice == context.attacker:
        return context.attacker
  Canceled

proc getAttacker*(): Target =
  ## `bounce(getAttacker())`, inside `on(attacked(...), ...)`.
  AttackerTarget()

proc getTarget*(index = 0): Target =
  ## `fight(getTarget(0), getTarget(1))`: reuses earlier targets' choices.
  PickedTarget(index: index)

proc targetCount*(card: Card): int {.gcsafe.}

proc targetText(target: Target, card: Card): string =
  ## A `getTarget` on a card with a single target is just "the target".
  if target of PickedTarget and card.targetCount() == 1:
    "the target"
  else:
    target.text()

converter toRuleValue*(number: int): RuleValue[int] =
  RuleValue[int](kind: FixedValue, fixed: number)

converter toRuleValue*(owner: Owner): RuleValue[Owner] =
  RuleValue[Owner](kind: FixedValue, fixed: owner)

converter toRuleValue*(name: string): RuleValue[Card] =
  ## A card by printed name. It's looked up as the card resolves: when
  ## rules are written the named card may not exist yet (Rally names
  ## Footsoldier from the same card list).
  RuleValue[Card](kind: CardNamed, name: name)

proc power*(target: Target): RuleValue[int] =
  ## `getTarget().power`: a minion's current power.
  RuleValue[int](kind: PowerOf, target: target)

proc toughness*(target: Target): RuleValue[int] =
  ## `getTarget().toughness`: a minion's current toughness. Read from the
  ## rules' view of the board, so a minion an earlier rule on this card
  ## destroyed still counts with the toughness it had.
  RuleValue[int](kind: ToughnessOf, target: target)

proc owner*(target: Target): RuleValue[Owner] =
  ## `getTarget().owner`: the player who controls what the target chose
  ## (You when that is the caster). With nothing chosen, You.
  RuleValue[Owner](kind: OwnerOf, target: target)

converter toOwner*(target: Target): RuleValue[Owner] =
  ## `draw(1, target({Opponent}))`: the player the target picks.
  RuleValue[Owner](kind: OwnerOf, target: target)

proc self*(): RuleValue[Card] =
  ## `destroy(self())`: the card in play these rules belong to.
  RuleValue[Card](kind: SelfCard)

proc count*(query: CardQuery): RuleValue[int] =
  ## `game.board.choose(kind: Minion, owner: You).count`.
  RuleValue[int](kind: CountOf, query: query)

proc `+`*(a, b: RuleValue[int]): RuleValue[int] =
  ## Two fixed numbers fold into one, so they print as a single number.
  if a.kind == FixedValue and b.kind == FixedValue:
    toRuleValue(a.fixed + b.fixed)
  else:
    RuleValue[int](kind: Sum, operands: @[a, b])

proc `-`*(a, b: RuleValue[int]): RuleValue[int] =
  if a.kind == FixedValue and b.kind == FixedValue:
    toRuleValue(a.fixed - b.fixed)
  else:
    RuleValue[int](kind: Difference, operands: @[a, b])

# Reads resolve through targets and queries defined further down.
proc value*(number: RuleValue[int], context: var RuleContext): int {.gcsafe.}
proc value*(owner: RuleValue[Owner], context: var RuleContext): Owner {.gcsafe.}
proc players*(owner: RuleValue[Owner], context: var RuleContext): seq[int] {.gcsafe.}
proc value*(named: RuleValue[Card], context: var RuleContext): Card {.gcsafe.}
proc text*(number: RuleValue[int], card: Card): string {.gcsafe.}
proc text*(owner: RuleValue[Owner], card: Card): string {.gcsafe.}
proc text*(named: RuleValue[Card], card: Card): string {.gcsafe.}

proc signed(amount: int): string =
  (if amount >= 0: "+" else: "") & $amount

proc estimate(amount: RuleValue[int]): int =
  ## A fixed number, or 1 for one only known on resolve.
  if amount.kind == FixedValue: amount.fixed else: 1

proc statsText(power, toughness: RuleValue[int], removes: bool, card: Card): string =
  ## "+1/+0", "-1/-0", or "+X/+0, where X is the target's toughness".
  const names = ["X", "Y"]
  var parts, clauses: seq[string]
  for amount in [power, toughness]:
    if amount.kind == FixedValue:
      let number = amount.fixed
      parts.add(if removes: "-" & $number else: number.signed())
    else:
      let name = names[clauses.len]
      parts.add((if removes: "-" else: "+") & name)
      clauses.add name & " is " & amount.text(card)
  result = parts.join("/")
  if clauses.len > 0:
    result.add ", where " & clauses.join(" and ")

proc damageText(amount: RuleValue[int], victims: string, card: Card): string =
  ## "Deal 1 damage to a minion.", "Deal the first target's toughness
  ## damage to the second target."
  "Deal " & amount.text(card) & " damage to " & victims & "."

proc change(amount: RuleValue[int], removes: bool, context: var RuleContext): int =
  (if removes: -1 else: 1) * amount.value(context)

proc objectTarget*(
    kinds: set[TargetKind],
    relation = Any,
    vfx = NoVfx
): Target =
  ObjectTarget(kinds: kinds, relation: relation, vfx: vfx)

template target*(
    kinds: untyped,
    relation: TargetRelation = Any,
    vfx: VfxKind = NoVfx
): Target =
  ## `target({Hero})`, `target({Minion}, Enemy)`, `target({Minion, Hero})`.
  ## Set literals ignore their expected type, so `Minion` is locally bound to
  ## TargetKind.Minion instead of being ambiguous with CardKind.Minion.
  block:
    const Minion {.inject, used.} = TargetKind.Minion
    objectTarget(kinds, relation, vfx)

method text*(rule: Rule, card: Card): string {.base, gcsafe.} =
  discard card
  ""

method choices*(
    rule: Rule,
    card: Card,
    context: RuleContext
): seq[Choice] {.base, gcsafe.} =
  discard (rule, card, context)

method needsChoice*(rule: Rule): bool {.base, gcsafe.} =
  discard rule
  false

method targets*(rule: Rule): seq[Target] {.base, gcsafe.} =
  ## Targets this rule chooses, in order. `getTarget` references aren't
  ## listed: they choose nothing new.
  discard rule

method helpsTarget*(rule: Rule): bool {.base, gcsafe.} =
  ## True when the rule is good for what it targets, so players (and bots)
  ## aim it at their own minions.
  discard rule
  false

method run*(
    rule: Rule,
    card: Card,
    context: var RuleContext
): bool {.base, gcsafe.} =
  discard (rule, card, context)
  true

method text*(rule: KeywordRule, card: Card): string =
  discard card
  $rule.keyword

proc subject(query: CardQuery, card: Card): string =
  ## "minions", "friendly minions", "minions the target's owner controls".
  let
    other = if query.includeSelf: "" else: "other "
    things =
      if query.kinds == {CardKind.Minion}: "minions"
      elif query.kinds == {Spell}: "spells"
      elif query.kinds == {Trinket}: "trinkets"
      else: "cards"
  if query.anyOwner:
    other & things
  elif query.owner.kind == FixedValue:
    other & (if query.owner.fixed == You: "friendly " else: "enemy ") & things
  else:
    other & things & " " & query.owner.text(card) & " controls"

proc text*(query: CardQuery, card: Card): string =
  ## "all enemy minions".
  "all " & query.subject(card)

proc matches*(query: CardQuery, context: var RuleContext): seq[Choice] =
  ## The query's cards in the live game, in board order.
  # A dead player's cards stay in play, and stay their opponents' enemies.
  let
    fixedOpponents = not query.anyOwner and query.owner.kind == FixedValue and
      query.owner.fixed != You
    wanted =
      if query.anyOwner or fixedOpponents: newSeq[int]()
      else: query.owner.players(context)
  case query.zone
  of BoardZone:
    for entry in context.game.board:
      if not query.includeSelf and context.sourceId != 0 and
          entry.choice.kind == CreatureChoice and
          entry.choice.creatureId == context.sourceId:
        continue
      if entry.card.kind in query.kinds and
          (query.anyOwner or entry.choice.owner in wanted or
            (fixedOpponents and entry.choice.owner != context.sourcePlayer)):
        result.add entry.choice

proc chosenEntry(
    target: Target,
    context: var RuleContext
): tuple[found: bool, entry: BoardCard] =
  ## The board entry of the minion a target chose, if any.
  let choice = target.choose(context)
  if choice.kind == CreatureChoice:
    for entry in context.game.board:
      if entry.choice == choice:
        return (true, entry)

proc value*(number: RuleValue[int], context: var RuleContext): int =
  case number.kind
  of FixedValue:
    number.fixed
  of PowerOf:
    let chosen = number.target.chosenEntry(context)
    if chosen.found: max(0, chosen.entry.power) else: 0
  of ToughnessOf:
    let chosen = number.target.chosenEntry(context)
    if chosen.found: max(0, chosen.entry.toughness) else: 0
  of CountOf:
    number.query.matches(context).len
  of Sum:
    number.operands[0].value(context) + number.operands[1].value(context)
  of Difference:
    number.operands[0].value(context) - number.operands[1].value(context)
  of CardNamed, SelfCard, OwnerOf:
    raiseAssert "not a number: " & $number.kind

proc value*(owner: RuleValue[Owner], context: var RuleContext): Owner =
  case owner.kind
  of FixedValue:
    owner.fixed
  of OwnerOf:
    let choice = owner.target.choose(context)
    if choice.kind in {HeroChoice, CreatureChoice} and
        choice.owner != context.sourcePlayer:
      AllOpponents
    else:
      You
  else:
    raiseAssert "not an owner: " & $owner.kind

proc resolvePlayers(owner: RuleValue[Owner], context: var RuleContext):
    tuple[ok: bool, players: seq[int]] =
  ## The players an owner names, seen from the player the rules run for:
  ## You is that player; the opponents are every other living player (the
  ## dead take no part); a target's owner is exactly the player controlling
  ## what it chose. `ok` is false when a player had to be picked and the
  ## pick was canceled; picking nobody names no one.
  result.ok = true
  case owner.kind
  of FixedValue:
    if owner.fixed == You:
      result.players.add context.sourcePlayer
    else:
      for hero in context.heroes:
        if hero.owner != context.sourcePlayer:
          result.players.add hero.owner
  of OwnerOf:
    let choice = owner.target.choose(context)
    if choice.kind in {HeroChoice, CreatureChoice}:
      result.players.add choice.owner
    elif owner.target.makesChoice():
      result.ok = choice.kind != CanceledChoice
    else:
      # A reference to an earlier target that chose nothing: you.
      result.players.add context.sourcePlayer
  else:
    raiseAssert "not an owner: " & $owner.kind

proc players*(owner: RuleValue[Owner], context: var RuleContext): seq[int] =
  owner.resolvePlayers(context).players

proc picks(owner: RuleValue[Owner]): seq[Target] =
  ## The target a player-valued parameter asks its card to pick.
  if owner.kind == OwnerOf and owner.target.makesChoice():
    result.add owner.target

proc effectOwner(owner: RuleValue[Owner], rule: string): RuleValue[Owner] =
  ## An effect names you, a picked opponent, or all of them.
  doAssert owner.kind != FixedValue or owner.fixed != AnyOpponent,
    rule & ": use target({Opponent}) for one opponent, or AllOpponents"
  owner

proc triggerOwner(owner: RuleValue[Owner], trigger: string): RuleValue[Owner] =
  ## A trigger watches you or any one opponent.
  doAssert owner.kind != FixedValue or owner.fixed != AllOpponents,
    trigger & ": use AnyOpponent in triggers"
  owner

proc value*(named: RuleValue[Card], context: var RuleContext): Card =
  case named.kind
  of FixedValue: named.fixed
  of CardNamed: context.cardNamed(named.name)
  of SelfCard:
    for entry in context.game.board:
      if entry.choice.kind == CreatureChoice and
          entry.choice.creatureId == context.sourceId:
        return entry.card
    Card()
  else: raiseAssert "not a card: " & $named.kind

proc text*(number: RuleValue[int], card: Card): string =
  ## "2", "the target's toughness", "the number of friendly minions",
  ## "the target's power plus 1".
  case number.kind
  of FixedValue: $number.fixed
  of PowerOf: number.target.targetText(card) & "'s power"
  of ToughnessOf: number.target.targetText(card) & "'s toughness"
  of CountOf: "the number of " & number.query.subject(card)
  of Sum:
    number.operands[0].text(card) & " plus " & number.operands[1].text(card)
  of Difference:
    number.operands[0].text(card) & " minus " & number.operands[1].text(card)
  of CardNamed, SelfCard, OwnerOf: raiseAssert "not a number: " & $number.kind

proc text*(owner: RuleValue[Owner], card: Card): string =
  ## "you", "an opponent", "each opponent", "the target's owner".
  case owner.kind
  of FixedValue:
    case owner.fixed
    of You: "you"
    of AnyOpponent: "an opponent"
    of AllOpponents: "each opponent"
  of OwnerOf:
    # A picked player is named as picked; a picked card, by its owner.
    if owner.target of ObjectTarget and
        ObjectTarget(owner.target).kinds == {Opponent}:
      owner.target.targetText(card)
    else:
      owner.target.targetText(card) & "'s owner"
  else: raiseAssert "not an owner: " & $owner.kind

proc text*(named: RuleValue[Card], card: Card): string =
  ## A card's printed name.
  case named.kind
  of FixedValue: named.fixed.name
  of CardNamed: named.name
  of SelfCard: "this card"
  else: raiseAssert "not a card: " & $named.kind

method text*(rule: FightRule, card: Card): string =
  rule.fighter.targetText(card).capitalizeAscii() & " fights " &
    rule.opponent.targetText(card) & "."

method targets*(rule: FightRule): seq[Target] =
  for target in [rule.fighter, rule.opponent]:
    if target.makesChoice():
      result.add target

method needsChoice*(rule: FightRule): bool =
  rule.targets().len > 0

method run*(
    rule: FightRule,
    card: Card,
    context: var RuleContext
): bool =
  discard card
  let
    fighter = rule.fighter.choose(context)
    opponent = rule.opponent.choose(context)
  if fighter.isCanceled or opponent.isCanceled:
    return false
  # Only minions fight; a minion's on-play rule may have chosen no target.
  if fighter.kind != CreatureChoice or opponent.kind != CreatureChoice:
    return true
  if rule.vfx != NoVfx:
    context.effects.add Effect(kind: TargetVfxEffect,
      targetVfx: rule.vfx, visualTarget: opponent)
  context.effects.add Effect(kind: FightEffect,
    fighterId: fighter.creatureId, opponentId: opponent.creatureId)
  true

converter toSelection*(target: Target): Selection =
  Selection(kind: SelectTarget, target: target)

converter toSelection*(query: CardQuery): Selection =
  Selection(kind: SelectQuery, query: query)

proc plural(what: Selection): bool =
  what.kind == SelectQuery

proc text(what: Selection, card: Card): string =
  ## "a minion", "the target", "all other cards".
  case what.kind
  of SelectTarget: what.target.targetText(card)
  of SelectQuery: what.query.text(card)

proc picks(what: Selection): seq[Target] =
  if what.kind == SelectTarget and what.target.makesChoice():
    result.add what.target

proc candidates(what: Selection, context: RuleContext): seq[Choice] =
  if what.kind == SelectTarget:
    result = what.target.candidates(context)

proc resolve(
    what: Selection,
    context: var RuleContext,
    vfx: VfxKind
): tuple[ok: bool, chosen: seq[Choice]] =
  ## The objects a rule acts on: the target's pick (none when it took no
  ## target), or every card the query matches. `ok` is false when a target
  ## was canceled. Every visual is added before any effect, so each lands
  ## before its card can move.
  result.ok = true
  case what.kind
  of SelectTarget:
    let selected = what.target.choose(context)
    case selected.kind
    of CanceledChoice:
      result.ok = false
    of NoTargetChoice:
      discard
    of HeroChoice, CreatureChoice:
      result.chosen.add selected
  of SelectQuery:
    result.chosen = what.query.matches(context)
  if vfx != NoVfx:
    for choice in result.chosen:
      context.effects.add Effect(kind: TargetVfxEffect, targetVfx: vfx,
        visualTarget: choice)

method text*(rule: DamageRule, card: Card): string =
  rule.amount.damageText(rule.what.text(card), card)

method choices*(rule: DamageRule, card: Card, context: RuleContext): seq[Choice] =
  discard card
  rule.what.candidates(context)

method targets*(rule: DamageRule): seq[Target] =
  rule.what.picks()

method run*(rule: DamageRule, card: Card, context: var RuleContext): bool =
  discard card
  let selection = rule.what.resolve(context, rule.vfx)
  if not selection.ok:
    return false
  let amount = rule.amount.value(context)
  for choice in selection.chosen:
    case choice.kind
    of HeroChoice:
      context.effects.add Effect(kind: DamageHeroEffect,
        heroPlayer: choice.owner, heroDamage: amount)
    of CreatureChoice:
      context.effects.add Effect(kind: DamageCreatureEffect,
        damagedCreatureId: choice.creatureId, creatureDamage: amount)
    of CanceledChoice, NoTargetChoice:
      discard
  true

method text*(rule: StatsRule, card: Card): string =
  "Give " & rule.what.text(card) & " " &
    statsText(rule.power, rule.toughness, rule.removes, card) & "."

method choices*(rule: StatsRule, card: Card, context: RuleContext): seq[Choice] =
  discard card
  rule.what.candidates(context)

method targets*(rule: StatsRule): seq[Target] =
  rule.what.picks()

method helpsTarget*(rule: StatsRule): bool =
  let total = rule.power.estimate() + rule.toughness.estimate()
  if rule.removes: total < 0 else: total > 0

method run*(rule: StatsRule, card: Card, context: var RuleContext): bool =
  discard card
  let selection = rule.what.resolve(context, rule.vfx)
  if not selection.ok:
    return false
  for choice in selection.chosen:
    if choice.kind == CreatureChoice:
      context.effects.add Effect(kind: ModifyStatsEffect,
        modifiedCreatureId: choice.creatureId,
        powerChange: rule.power.change(rule.removes, context),
        toughnessChange: rule.toughness.change(rule.removes, context))
  true

method text*(rule: BounceRule, card: Card): string =
  ## "Return a minion to its owner's hand.", "Return all other cards to
  ## their owners' hands."
  "Return " & rule.what.text(card) &
    (if rule.what.plural: " to their owners' hands." else: " to its owner's hand.")

method choices*(rule: BounceRule, card: Card, context: RuleContext): seq[Choice] =
  discard card
  rule.what.candidates(context)

method targets*(rule: BounceRule): seq[Target] =
  rule.what.picks()

method run*(rule: BounceRule, card: Card, context: var RuleContext): bool =
  discard card
  let selection = rule.what.resolve(context, rule.vfx)
  if not selection.ok:
    return false
  for choice in selection.chosen:
    if choice.kind == CreatureChoice:
      context.effects.add Effect(kind: BounceCreatureEffect,
        bouncedCreatureId: choice.creatureId)
  true

method text*(rule: DestroyRule, card: Card): string =
  "Destroy " & rule.what.text(card) & "."

method choices*(rule: DestroyRule, card: Card, context: RuleContext): seq[Choice] =
  discard card
  rule.what.candidates(context)

method targets*(rule: DestroyRule): seq[Target] =
  rule.what.picks()

method run*(rule: DestroyRule, card: Card, context: var RuleContext): bool =
  discard card
  let selection = rule.what.resolve(context, rule.vfx)
  if not selection.ok:
    return false
  for choice in selection.chosen:
    if choice.kind == CreatureChoice:
      context.effects.add Effect(kind: DestroyEffect,
        destroyedId: choice.creatureId)
  true

method text*(rule: LoseKeywordRule, card: Card): string =
  ## "A minion loses Ranged.", "All enemy minions lose Ranged."
  rule.what.text(card).capitalizeAscii() &
    (if rule.what.plural: " lose " else: " loses ") & $rule.keyword & "."

method choices*(rule: LoseKeywordRule, card: Card,
    context: RuleContext): seq[Choice] =
  discard card
  rule.what.candidates(context)

method targets*(rule: LoseKeywordRule): seq[Target] =
  rule.what.picks()

method run*(rule: LoseKeywordRule, card: Card, context: var RuleContext): bool =
  discard card
  let selection = rule.what.resolve(context, rule.vfx)
  if not selection.ok:
    return false
  for choice in selection.chosen:
    if choice.kind == CreatureChoice:
      context.effects.add Effect(kind: LoseKeywordEffect,
        keywordLoserId: choice.creatureId, lostKeyword: rule.keyword)
  true

proc damage*(amount: RuleValue[int], what: Selection, vfx = NoVfx): Rule =
  ## `damage(1, target({Minion}))`, `damage(1, game.board.choose(...))`.
  DamageRule(amount: amount, what: what, vfx: vfx)

proc addPowerToughness*(
    power, toughness: RuleValue[int],
    what: Selection,
    vfx = NoVfx
): Rule =
  ## `addPowerToughness(1, 1, target({Minion}))`: permanent.
  StatsRule(power: power, toughness: toughness, what: what, vfx: vfx)

proc removePowerToughness*(
    power, toughness: RuleValue[int],
    what: Selection,
    vfx = NoVfx
): Rule =
  ## `removePowerToughness(1, 0, target({Minion}))`: permanent, and power
  ## never drops below 0.
  StatsRule(power: power, toughness: toughness, what: what, vfx: vfx,
    removes: true)

proc bounce*(what: Selection, vfx = NoVfx): Rule =
  ## `bounce(target({Minion}))`, `bounce(game.board.choose({self: false}))`.
  BounceRule(what: what, vfx: vfx)

proc destroy*(what: Selection, vfx = NoVfx): Rule =
  ## `destroy(target({Minion}))`: straight to the discard pile.
  DestroyRule(what: what, vfx: vfx)

proc lose*(keyword: KeywordRule, what: Selection, vfx = NoVfx): Rule =
  ## `lose(ranged(), target({Minion}))`: permanent while on the board.
  LoseKeywordRule(keyword: keyword.keyword, what: what, vfx: vfx)

method text*(rule: DestroyCardRule, card: Card): string =
  "Destroy " & rule.card.text(card) & "."

method run*(
    rule: DestroyCardRule,
    card: Card,
    context: var RuleContext
): bool =
  discard card
  case rule.card.kind
  of SelfCard:
    if context.sourceId != 0:
      context.effects.add Effect(kind: DestroyEffect,
        destroyedId: context.sourceId)
  else:
    raiseAssert "destroy needs a card in play, like self(): " &
      $rule.card.kind
  true

proc destroy*(card: RuleValue[Card]): Rule =
  ## `destroy(self())`: that card leaves play for its owner's discard pile.
  DestroyCardRule(card: card)

proc cardsText(count: RuleValue[int], card: Card): string =
  ## "1 card", "2 cards", "cards equal to the target's toughness".
  if count.kind == FixedValue:
    $count.fixed & (if count.fixed == 1: " card" else: " cards")
  else:
    "cards equal to " & count.text(card)

proc playerSentence(player: RuleValue[Owner], verb, verbs, rest: string,
    card: Card): string =
  ## "Draw 1 card.", or with a subject: "Each opponent draws 1 card."
  if player.kind == FixedValue and player.fixed == You:
    verb.capitalizeAscii() & " " & rest & "."
  else:
    player.text(card).capitalizeAscii() & " " & verbs & " " & rest & "."

method text*(rule: DrawRule, card: Card): string =
  ## "Draw 1 card.", "Draw 2 cards.", "Each opponent draws 1 card.",
  ## "An opponent draws 1 card.",
  ## "The target's owner draws cards equal to the target's toughness."
  rule.player.playerSentence("draw", "draws", rule.count.cardsText(card), card)

method targets*(rule: DrawRule): seq[Target] =
  rule.player.picks()

method run*(
    rule: DrawRule,
    card: Card,
    context: var RuleContext
): bool =
  discard card
  let
    resolved = rule.player.resolvePlayers(context)
    count = rule.count.value(context)
  if not resolved.ok:
    return false
  for player in resolved.players:
    context.effects.add Effect(kind: DrawEffect, drawPlayer: player,
      drawCount: count)
  true

proc draw*(
    count: RuleValue[int],
    player: RuleValue[Owner] = toRuleValue(You)
): Rule =
  ## `draw(1)`, `draw(2, AllOpponents)`, `draw(1, target({Opponent}))`.
  DrawRule(count: count, player: player.effectOwner("draw"))

method text*(rule: TossRule, card: Card): string =
  ## "Discard 1 card.", "Each opponent discards 2 cards.",
  ## "An opponent discards 1 card."
  rule.player.playerSentence("discard", "discards",
    rule.count.cardsText(card), card)

method targets*(rule: TossRule): seq[Target] =
  rule.player.picks()

method run*(
    rule: TossRule,
    card: Card,
    context: var RuleContext
): bool =
  let
    resolved = rule.player.resolvePlayers(context)
    count = rule.count.value(context)
  if not resolved.ok:
    return false
  for player in resolved.players:
    context.effects.add Effect(kind: TossEffect, tossPlayer: player,
      tossCount: count, tossSource: card.name, tossText: rule.text(card))
  true

proc toss*(
    count: RuleValue[int],
    player: RuleValue[Owner] = toRuleValue(You)
): Rule =
  ## `toss(1)`: that player discards cards of their choice. (`discard` is a
  ## Nim keyword.)
  TossRule(count: count, player: player.effectOwner("toss"))

proc nextTurn*(player: RuleValue[Owner]): Trigger =
  ## `on(nextTurn(You), ...)`: fires once, when that player's next turn
  ## starts, after their draw. `nextTurn(AnyOpponent)`: when the next
  ## opponent's turn starts.
  Trigger(kind: NextTurnStart, player: player.triggerOwner("nextTurn"))

proc text*(trigger: Trigger, card: Card): string =
  ## "at the start of your next turn".
  case trigger.kind
  of HeroAttacked:
    let player = trigger.player
    if player.kind == FixedValue:
      if player.fixed == You: "when your hero is attacked"
      else: "when an opponent's hero is attacked"
    else:
      "when " & player.text(card) & "'s hero is attacked"
  of CardAttacked:
    "when " & trigger.card.text(card) & " is attacked"
  of NextTurnStart:
    let player = trigger.player
    if player.kind == FixedValue:
      if player.fixed == You: "at the start of your next turn"
      else: "at the start of an opponent's next turn"
    else:
      "at the start of " & player.text(card) & "'s next turn"

proc firesAtTurnStart*(
    trigger: Trigger,
    context: var RuleContext,
    turnPlayer, turn, enteredTurn: int
): bool =
  ## Whether the trigger of a card that entered play on `enteredTurn` fires
  ## as `turnPlayer` starts `turn`: on any later turn of a player it
  ## watches. The game fires each such trigger only once, so that is their
  ## next turn, however many turns were skipped on the way.
  case trigger.kind
  of NextTurnStart:
    turnPlayer in trigger.player.players(context) and turn > enteredTurn
  of HeroAttacked, CardAttacked:
    false

proc firesOnAttack*(
    trigger: Trigger,
    context: var RuleContext,
    victim: Choice
): bool =
  ## Whether an attack on `victim` fires the trigger. It fires after the
  ## attack's damage.
  case trigger.kind
  of NextTurnStart:
    return false
  of HeroAttacked:
    return victim.kind == HeroChoice and
      victim.owner in trigger.player.players(context)
  of CardAttacked:
    if victim.kind != CreatureChoice:
      return false
    if trigger.card.kind == SelfCard:
      return victim.creatureId == context.sourceId
    let wanted = trigger.card.value(context)
    for entry in context.game.board:
      if entry.choice == victim:
        # Same printed card: name and cost, as card IDs identify it.
        return entry.card.name == wanted.name and
          entry.card.energyCost == wanted.energyCost

proc attacked*(player: RuleValue[Owner]): Trigger =
  ## `on(attacked(You), ...)`: when that player's hero is attacked;
  ## `attacked(AnyOpponent)`: when any opponent's is.
  Trigger(kind: HeroAttacked, player: player.triggerOwner("attacked"))

proc attacked*(card: RuleValue[Card]): Trigger =
  ## `on(attacked(self()), ...)`: when that card is attacked.
  Trigger(kind: CardAttacked, card: card)

method text*(rule: OnRule, card: Card): string =
  ## One sentence: "At the start of your next turn, draw 1 card and destroy
  ## this card."
  var parts: seq[string]
  for inner in rule.rules:
    var part = inner.text(card)
    if part.len == 0:
      continue
    if part.endsWith("."):
      part.setLen(part.len - 1)
    part[0] = part[0].toLowerAscii()
    parts.add part
  let joined =
    if parts.len <= 1: parts.join("")
    else: parts[0 ..< ^1].join(", ") & " and " & parts[^1]
  (rule.trigger.text(card) & ", " & joined).capitalizeAscii() & "."

proc on*(trigger: Trigger, rules: varargs[Rule]): Rule =
  ## `on(nextTurn(You), draw(1), destroy(self()))`: nothing happens on play;
  ## the rules resolve when the trigger fires, for the card's owner.
  OnRule(trigger: trigger, rules: @rules)

proc triggers*(card: Card): seq[OnRule] =
  for rule in card.rules:
    if rule of OnRule:
      result.add OnRule(rule)

method text*(rule: SummonRule, card: Card): string =
  ## "Summon 2 Footsoldiers.", "Summon a Footsoldier for your opponent.",
  ## "Summon Oozes equal to the target's toughness for the target's owner."
  let name = rule.card.text(card)
  result = "Summon "
  if rule.count.kind != FixedValue:
    result.add name & "s equal to " & rule.count.text(card)
  elif rule.count.fixed == 1:
    result.add(
      if name.len > 0 and name[0].toLowerAscii() in {'a', 'e', 'i', 'o', 'u'}:
        "an "
      else:
        "a ")
    result.add name
  else:
    result.add rule.count.text(card) & " " & name & "s"
  if rule.owner.kind != FixedValue or rule.owner.fixed != You:
    result.add " for " & rule.owner.text(card)
  result.add "."

method targets*(rule: SummonRule): seq[Target] =
  rule.owner.picks()

method run*(
    rule: SummonRule,
    card: Card,
    context: var RuleContext
): bool =
  ## The new minions join the rules' view of the board at once, so later
  ## rules on the same card (Rally's buff) reach them.
  discard card
  let summoned = rule.card.value(context)
  if summoned.name.len == 0:
    return true
  let
    resolved = rule.owner.resolvePlayers(context)
    count = rule.count.value(context)
  if not resolved.ok:
    return false
  for owner in resolved.players:
    for _ in 0 ..< count:
      let choice = creatureChoice(owner, context.game.nextMinionId)
      inc context.game.nextMinionId
      context.game.board.add BoardCard(choice: choice, card: summoned,
        power: (if summoned.kind == Minion: summoned.power else: 0),
        toughness: (if summoned.kind == Minion: summoned.toughness else: 0))
      context.creatures.add choice
      context.effects.add Effect(kind: SummonEffect,
        summonedId: choice.creatureId, summonedOwner: owner,
        summonedCard: summoned)
  true

proc summon*(
    count: RuleValue[int],
    card: RuleValue[Card],
    owner: RuleValue[Owner] = toRuleValue(You)
): Rule =
  ## `summon(2, "Footsoldier")`: new base-set minions enter under `owner`'s
  ## control. Like played minions, they attack from their owner's next
  ## turn; their own on-play rules don't run.
  SummonRule(count: count, card: card, owner: owner.effectOwner("summon"))

proc checkCardNames*(card: Card, cardNamed: CardLookup) =
  ## Looks up every card name the rules mention: a misspelled one raises,
  ## so a card set can check itself at startup.
  for rule in card.rules:
    if rule of SummonRule and SummonRule(rule).card.kind == CardNamed:
      discard cardNamed(SummonRule(rule).card.name)

proc fight*(fighter, opponent: Target, vfx = NoVfx): Rule =
  ## `fight(getTarget(0), getTarget(1))`: both deal their power at once.
  FightRule(fighter: fighter, opponent: opponent, vfx: vfx)

proc board*(game: GameQuery): ZoneQuery =
  ZoneQuery(zone: BoardZone)

macro choose*(zone: ZoneQuery, filters: varargs[untyped]): CardQuery =
  ## Selects every card in `zone` matching `kind: CardKind`, `owner:`
  ## (`You`, `AllOpponents`, or computed: `getTarget().owner`) and `self: false`
  ## (not the card these rules belong to). An omitted filter matches
  ## anything.
  let query = genSym(nskVar, "query")
  var body = newStmtList(quote do:
    var `query` = CardQuery(zone: `zone`.zone,
      kinds: {low(CardKind) .. high(CardKind)},
      anyOwner: true, includeSelf: true))
  # Filters come as `kind: Minion` or in braces: `{self: false}`. `{}` is
  # no filter at all.
  var named: seq[NimNode]
  for filter in filters:
    case filter.kind
    of nnkExprColonExpr:
      named.add filter
    of nnkTableConstr:
      for pair in filter:
        named.add pair
    of nnkCurly:
      if filter.len > 0:
        error("choose filters are written `name: value`", filter)
    else:
      error("choose filters are written `name: value`", filter)
  for filter in named:
    let value = filter[1]
    if filter[0].eqIdent("kind"):
      body.add(quote do:
        block:
          let kind: CardKind = `value`
          `query`.kinds = {kind})
    elif filter[0].eqIdent("owner"):
      body.add(quote do:
        block:
          let owner: RuleValue[Owner] = `value`
          `query`.owner = owner
          `query`.anyOwner = false)
    elif filter[0].eqIdent("self"):
      body.add(quote do:
        block:
          let includeSelf: bool = `value`
          `query`.includeSelf = includeSelf)
    else:
      error("unknown choose filter; use `kind`, `owner` or `self`", filter[0])
  body.add query
  result = newBlockStmt(body)

proc chooseCalls(node: NimNode): NimNode =
  ## `zone.choose(kind: Minion)` parses as an object constructor, which Nim
  ## would reject before `choose` saw its filters. Rewrite it into a call.
  if node.kind == nnkObjConstr and node[0].kind == nnkDotExpr and
      node[0][1].eqIdent("choose"):
    result = newCall(ident"choose", chooseCalls(node[0][0]))
    for index in 1 ..< node.len:
      result.add node[index]
  else:
    result = node
    for index in 0 ..< node.len:
      result[index] = chooseCalls(node[index])

proc ranged*(): KeywordRule =
  ## Ranged minions take no combat damage from non-ranged minions. Also
  ## names the keyword elsewhere: `lose(ranged(), target(...))`.
  KeywordRule(keyword: Ranged)

proc ruleList(items: varargs[Rule]): Rules =
  for item in items:
    result.add item

macro rules*(items: varargs[untyped]): Rules =
  ## A card's printed rules, in order: `rules: rules(ranged(), damage(...))`.
  ## Inside, `game` names the live game: `game.board.choose(...)`.
  var call = newCall(bindSym"ruleList")
  for item in items:
    call.add chooseCalls(item)
  let game = nnkPragmaExpr.newTree(ident"game",
    nnkPragma.newTree(ident"used"))
  result = newBlockStmt(newStmtList(
    newLetStmt(game, newCall(bindSym"GameQuery")), call))

proc `&`*(a, b: openArray[Card]): seq[Card] =
  ## Joins card lists, e.g. `archer & warrior & mage`.
  result = @a
  result.add b

proc ruleText*(card: Card): string =
  var lines: seq[string]
  for rule in card.rules:
    let line = rule.text(card)
    if line.len > 0:
      lines.add line
  lines.join("\n")

proc keywords*(card: Card): set[Keyword] =
  for rule in card.rules:
    if rule of KeywordRule:
      result.incl KeywordRule(rule).keyword

proc picks(rule: Rule): seq[Target] =
  ## The rule's targets that make a new choice: `getTarget` reuses one.
  for target in rule.targets():
    if target.makesChoice():
      result.add target

proc targets*(rules: Rules): seq[Target] =
  ## Every choice the rules ask for, in the order players make them.
  for rule in rules:
    result.add rule.picks()

proc targetCount*(rules: Rules): int =
  rules.targets().len

proc helpsTarget*(rules: Rules, step: int): bool =
  ## Whether the `step`th target (from 0) is one to aim at your own.
  var index = 0
  for rule in rules:
    for _ in rule.picks():
      if index == step:
        return rule.helpsTarget()
      inc index

proc choices*(rules: Rules, context: RuleContext, step = 0): seq[Choice] =
  ## Unique legal choices for the `step`th target (from 0).
  let targets = rules.targets()
  if step >= targets.len:
    return
  for choice in targets[step].candidates(context):
    if choice notin result:
      result.add choice

proc targetPrompt*(
    rules: Rules,
    card: Card,
    step: int
): tuple[rule, choose: string] =
  ## What a player sees while picking the `step`th target: the rule being
  ## aimed ("Deal 1 damage to a minion.") and the pick ("Choose a minion.").
  var index = 0
  for rule in rules:
    for target in rule.picks():
      if index == step:
        return (rule.text(card), "Choose " & target.text() & ".")
      inc index

proc targets*(card: Card): seq[Target] =
  card.rules.targets()

proc needsChoice*(card: Card): bool =
  card.targets().len > 0

proc targetCount*(card: Card): int {.gcsafe.} =
  card.rules.targetCount()

proc helpsTarget*(card: Card, step: int): bool =
  card.rules.helpsTarget(step)

proc choices*(card: Card, context: RuleContext, step = 0): seq[Choice] =
  card.rules.choices(context, step)

proc targetPrompt*(card: Card, step: int): tuple[rule, choose: string] =
  card.rules.targetPrompt(card, step)

proc runRules*(card: Card, rules: Rules, context: var RuleContext): bool =
  ## Resolves `rules` for `card`. A canceled/invalid target cancels them all.
  let effectStart = context.effects.len
  for index, rule in rules:
    let ruleStart = context.effects.len
    if not rule.run(card, context):
      # A later canceled rule must not leak damage or VFX from earlier rules.
      context.effects.setLen(effectStart)
      return false
    for effect in context.effects.toOpenArray(ruleStart,
        context.effects.high).mitems:
      effect.beat = index
  true

proc runRules*(card: Card, context: var RuleContext): bool =
  ## Resolves every on-play rule; `on(...)` rules only wait for a trigger.
  card.runRules(card.rules, context)

proc `==`*(a, b: Card): bool {.noSideEffect.} =
  ## Printed data plus the same rule objects. Copies of a card share its
  ## rules, so a look-alike built elsewhere never equals a base-set card.
  if a.name != b.name or
      a.energyCost != b.energyCost or
      a.class != b.class or
      a.kind != b.kind or
      a.rules.len != b.rules.len:
    return false
  for index in 0 ..< a.rules.len:
    if a.rules[index] != b.rules[index]:
      return false
  case a.kind
  of Minion:
    a.power == b.power and a.toughness == b.toughness
  of Spell, Trinket:
    true
