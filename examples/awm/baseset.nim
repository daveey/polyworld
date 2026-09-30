## AWM base set: coded cards and the class decks built from them.

import
  std/[options, strutils],
  awmcore

const
  DeckSize* = 40

let archer = [
  Card(
    name: "Bolt", energyCost: 1,
    class: some(Archer), kind: Spell,
    rules: rules(damage(2, target({Hero}, vfx = LightningVfx)))
  ),
  Card(
    name: "Sniper", energyCost: 2,
    class: some(Archer), kind: Minion,
    rules: rules(ranged()),
    power: 2, toughness: 1
  ),
  Card(
    name: "Sharpshooter", energyCost: 3,
    class: some(Archer), kind: Minion,
    rules: rules(
      ranged(),
      damage(1, target({Minion, Hero}, vfx = ArrowVfx))
    ),
    power: 3, toughness: 1
  ),
  Card(
    name: "Hail of Arrows", energyCost: 3,
    class: some(Archer), kind: Spell,
    rules: rules(
      damage(
        1,
        game.board.choose(kind: Minion, owner: AllOpponents),
        vfx = ManyArrowsVfx
      )
    )
  )
]

let warrior = [
  Card(
    name: "Bear", energyCost: 2,
    class: some(Warrior), kind: Minion,
    rules: rules(),
    power: 3, toughness: 2
  ),
  Card(
    name: "Swords", energyCost: 2,
    class: some(Warrior), kind: Spell,
    rules: rules(
      addPowerToughness(
        1, 0,
        game.board.choose(kind: Minion, owner: You),
        vfx = SwordsIntoTheWindVfx
      )
    )
  ),
  Card(
    name: "Shields", energyCost: 1,
    class: some(Warrior), kind: Spell,
    rules: rules(
      addPowerToughness(
        0, 1,
        game.board.choose(kind: Minion, owner: You),
        vfx = MightyShieldsVfx
      )
    )
  ),
  Card(
    name: "Duel", energyCost: 2,
    class: some(Warrior), kind: Spell,
    rules: rules(
      addPowerToughness(1, 1, target({Minion}, vfx = SwordAndShieldVfx)),
      lose(ranged(), target({Minion}, vfx = MeleeVfx)),
      fight(getTarget(0), getTarget(1), vfx = SwordClashVfx)
    )
  ),
  Card(
    name: "Tactician", energyCost: 2,
    class: some(Warrior), kind: Minion,
    rules: rules(
      removePowerToughness(1, 0, target({Minion}, vfx = SwordBreakVfx)),
    ),
    power: 1, toughness: 2
  ),
  Card(
    name: "Footsoldier", energyCost: 1,
    class: some(Warrior), kind: Minion,
    rules: rules(),
    power: 1, toughness: 2
  ),
  Card(
    name: "Commander", energyCost: 5,
    class: some(Warrior), kind: Minion,
    rules: rules(summon(2, "Footsoldier")),
    power: 2, toughness: 3
  ),
  Card(
    name: "Rally", energyCost: 5,
    class: some(Warrior), kind: Spell,
    rules: rules(
      summon(2, "Footsoldier"),
      addPowerToughness(
        1, 0,
        game.board.choose(kind: Minion, owner: You),
        vfx = SwordsIntoTheWindVfx
      )
    )
  )
]

let mage = [
  Card(
    name: "Ooze", energyCost: 0,
    class: some(Mage), kind: Minion,
    rules: rules(),
    power: 0, toughness: 1
  ),
  Card(
    name: "Bouncer", energyCost: 1,
    class: some(Mage), kind: Minion,
    rules: rules(bounce(target({Minion}, vfx = BubbleVfx))),
    power: 1, toughness: 1
  ),
  Card(
    name: "Plan", energyCost: 3,
    class: some(Mage), kind: Trinket,
    rules: rules(
      draw(1),
      on(nextTurn(You),
        draw(1),
        destroy(self())
      )
    )
  ),
  Card(
    name: "Study", energyCost: 2,
    class: some(Mage), kind: Spell,
    rules: rules(draw(2), toss(1))
  ),
  Card(
    name: "Primordial", energyCost: 8,
    class: some(Mage), kind: Minion,
    rules: rules(
      bounce(game.board.choose({ self: false }), vfx = BubbleVfx)
    ),
    power: 10, toughness: 10
  ),
  Card(
    name: "Bubble", energyCost: 0,
    class: some(Mage), kind: Trinket,
    rules: rules(
      on(attacked(You),
        bounce(getAttacker(), vfx = BubbleVfx),
        destroy(self())
      )
    )
  ),
  Card(
    name: "Bubble Shield", energyCost: 2,
    class: some(Mage), kind: Spell,
    rules: rules(summon(2, "Bubble"))
  ),
  Card(
    name: "Oozification", energyCost: 4,
    class: some(Mage), kind: Spell,
    rules: rules(
      destroy(target({Minion}, vfx = OozeSplatVfx)),
      summon(getTarget().toughness, "Ooze", getTarget().owner)
    )
  )
]

let baseCards* = archer & warrior & mage

## The card lists are never mutated after module init, so the lookups below
## cast to gcsafe: async server handlers deal decks and encode snapshots.

proc named(cards: openArray[Card], name: string): Card =
  for card in cards:
    if card.name == name:
      return card
  raise newException(ValueError, "No base-set card named '" & name & "'")

proc classCard*(heroClass: HeroClass): Card =
  ## Each class's signature card, found by name so list order doesn't matter.
  {.cast(gcsafe).}:
    case heroClass
    of Archer: archer.named("Bolt")
    of Warrior: warrior.named("Bear")
    of Mage: mage.named("Bouncer")

proc cardId*(card: Card): string =
  ## Stable wire ID. Name plus cost keeps same-named printings apart.
  card.name.toLowerAscii().replace(" ", "-") & "-" & $card.energyCost

proc baseCard*(id: string): Card =
  {.cast(gcsafe).}:
    for card in baseCards:
      if card.cardId() == id:
        return card
  raise newException(ValueError, "Unknown base-set card '" & id & "'")

proc baseCardNamed*(name: string): Card {.nimcall, gcsafe.} =
  ## The base-set card printed with this name, for `summon`.
  {.cast(gcsafe).}:
    for card in baseCards:
      if card.name == name:
        return card
  raise newException(ValueError, "Unknown base-set card named '" & name & "'")

# A misspelled summon fails at startup rather than mid-game.
for card in baseCards:
  card.checkCardNames(baseCardNamed)

proc deck(cards: openArray[Card],
    counts: openArray[(string, int)]): seq[Card] =
  {.cast(gcsafe).}:
    for (name, count) in counts:
      let card = cards.named(name)
      for _ in 0 ..< count:
        result.add card

proc baseDeck*(heroClass: HeroClass): seq[Card] =
  ## Ooze isn't dealt: only Oozification summons it.
  {.cast(gcsafe).}:
    result =
      case heroClass
      of Archer:
        archer.deck([("Bolt", 10), ("Sniper", 14), ("Sharpshooter", 10),
          ("Hail of Arrows", 6)])
      of Warrior:
        warrior.deck([("Bear", 8), ("Swords", 5), ("Shields", 4), ("Duel", 5),
          ("Tactician", 5), ("Footsoldier", 6), ("Commander", 4),
          ("Rally", 3)])
      of Mage:
        mage.deck([("Bouncer", 16), ("Oozification", 4), ("Plan", 7),
          ("Study", 7), ("Primordial", 2), ("Bubble Shield", 4)])
  doAssert result.len == DeckSize
