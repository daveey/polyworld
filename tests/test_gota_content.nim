## Gods of the Arena must keep ten distinct deterministic hero identities.

import ../examples/gods_of_the_arena/content

echo "Testing the GoTA roster contains every hero class once"
block:
  var seen: set[HeroClass]
  for class in RedHeroClasses:
    doAssert class notin seen, "red roster repeats " & $class
    seen.incl class
  for class in BlueHeroClasses:
    doAssert class notin seen, "blue roster repeats " & $class
    seen.incl class
  doAssert seen == {HeroClass.low .. HeroClass.high}
  doAssert HeroClassCount == 10

echo "Testing every hero class has viable and distinct tuning"
block:
  var
    tuning: seq[array[6, int32]]
    used: set[Ability]
  for class in HeroClass:
    let spec = class.heroSpec
    doAssert spec.name.len > 0
    doAssert spec.role.len > 0
    doAssert spec.baseHitPoints > 0
    doAssert spec.baseDamage > 0
    doAssert spec.baseMovePerTick > 0
    doAssert spec.attackRange > 0
    doAssert spec.attackTicks > 0
    let values = [
      spec.baseHitPoints,
      spec.baseMana,
      spec.baseDamage,
      spec.baseMovePerTick,
      spec.attackRange,
      spec.attackTicks
    ]
    doAssert values notin tuning, "two classes have identical tuning"
    tuning.add values
    for slot in HeroAbilitySlot:
      let ability = spec.abilities[slot]
      doAssert ability notin used, "ability is assigned twice"
      doAssert ability.abilitySpec.slot == slot,
        $ability & " metadata disagrees with its hero kit slot"
      used.incl ability
  doAssert used == {Ability.low .. Ability.high}

echo "Testing spell ranks clamp to the declared slot limit"
block:
  doAssert FirebrandSword.abilitySpec(4).damage == 92
  doAssert FirebrandSword.abilitySpec(int32.high) ==
    FirebrandSword.abilitySpec(4)
  doAssert BlazingBlade.abilitySpec(3).damage == 408
  doAssert BlazingBlade.abilitySpec(4) == BlazingBlade.abilitySpec(3)
  doAssert BlazingBlade.abilitySpec(int32.high) == BlazingBlade.abilitySpec(3)

echo "Testing every kit ability has a distinct usable spec"
block:
  var
    names: seq[string]
    icons: seq[string]
  for ability in Ability:
    let spec = ability.abilitySpec
    doAssert spec.name.len > 0
    doAssert spec.icon.len > 0
    doAssert spec.cooldownTicks > 0
    doAssert spec.name notin names, "ability name is assigned twice"
    doAssert spec.icon notin icons, "ability icon is assigned twice"
    names.add spec.name
    icons.add spec.icon
    case spec.kind
    of Strike:
      doAssert spec.damage > 0, $ability & " strike has no damage"
      doAssert spec.range > 0, $ability & " strike has no range"
    of Heal:
      doAssert spec.heal > 0, $ability & " heal has no heal"
    of Restore:
      doAssert spec.restore > 0, $ability & " restore has no restore"
  doAssert names.len == 40

echo "Testing class stat curves use only the selected class and level"
block:
  for class in HeroClass:
    doAssert heroMaxHp(class, 2) > heroMaxHp(class, 1)
    doAssert heroMaxMana(class, 2) >= heroMaxMana(class, 1)
    doAssert heroMaxMana(class, 1) == class.heroSpec.baseMana
    doAssert heroMaxMana(class, HeroMaxLevel) == class.heroSpec.maxLevelMana
    doAssert heroDamage(class, 2) > heroDamage(class, 1)
    doAssert heroMovePerTick(class, 2) > heroMovePerTick(class, 1)
    doAssert heroAttackRange(class) == class.heroSpec.attackRange
    doAssert heroAttackTicks(class) == class.heroSpec.attackTicks
    doAssert heroAbility(class, PrimaryAbility) ==
      class.heroSpec.abilities[PrimaryAbility]
    doAssert abilityIconKey(heroAbility(class, PassiveAbility)).len > 8

echo "Testing carries stay fragile early and retain late health"
block:
  for class in [Ranger, Crossbowman]:
    doAssert class.heroMaxHp(3) < Arcanist.heroMaxHp(3)
    doAssert class.heroMaxHp(5) < 400
    doAssert class.heroMaxHp(10) < 800
    doAssert class.heroMaxHp(20) in 1900 .. 2100
    doAssert class.heroMaxHp(0) == class.heroMaxHp(1)
    doAssert class.heroMaxHp(21) == class.heroMaxHp(20)
    var previousGain = 0'i32
    for level in 2 .. HeroMaxLevel:
      let gain = class.heroMaxHp(level) - class.heroMaxHp(level - 1)
      doAssert gain > previousGain
      previousGain = gain
  for class in [VanguardKnight, DeathKnight]:
    doAssert class.heroMaxHp(1) >= 425
    doAssert class.heroMaxHp(20) >= 2400
    for level in 1 .. HeroMaxLevel:
      doAssert class.heroMaxHp(level) > Ranger.heroMaxHp(level)
      doAssert class.heroMaxHp(level) > Crossbowman.heroMaxHp(level)

echo "Testing carry spells delay damage without losing their final power"
block:
  for (ability, finalDamage) in [
    (DragonSight, 47'i32), (VerdantArrow, 122'i32),
    (RicochetDisc, 165'i32), (StormEagle, 442'i32),
    (FinalMeasure, 52'i32), (SiegeScarab, 130'i32),
    (LodestoneSurge, 175'i32), (ClockworkCharge, 470'i32)
  ]:
    let slot = ability.abilitySpec.slot
    doAssert ability.abilitySpec(0).damage == 0
    doAssert ability.abilitySpec(1).damage == ability.abilitySpec.damage
    doAssert ability.abilitySpec(slot.abilityMaxLevel).damage == finalDamage
    doAssert ability.abilitySpec(int32.high).damage == finalDamage
    for rank in 2'i32 .. slot.abilityMaxLevel:
      doAssert ability.abilitySpec(rank).damage >
        ability.abilitySpec(rank - 1).damage
  doAssert RicochetDisc.abilitySpec(1).damage == 35
  doAssert LodestoneSurge.abilitySpec(1).damage == 31
  doAssert StormEagle.abilitySpec(1).damage < 120
  doAssert ClockworkCharge.abilitySpec(1).damage < 120

echo "Testing the shop catalog has distinct usable items"
block:
  var
    names: seq[string]
    icons: seq[string]
  doAssert ItemSpecs[NoItem].cost == 0
  for item in Item:
    if item == NoItem:
      continue
    let spec = item.itemSpec
    doAssert spec.name.len > 0
    doAssert spec.icon.len > 0
    doAssert spec.cost > 0
    doAssert spec.name notin names, "item name is assigned twice"
    doAssert item.itemIconKey notin icons, "item key is assigned twice"
    names.add spec.name
    icons.add item.itemIconKey
    case spec.kind
    of Consumable:
      doAssert spec.heal > 0 or spec.restore > 0 or spec.strike > 0 or
        spec.channelTicks > 0
    of Equipment:
      doAssert spec.maxHp > 0 or spec.maxMana > 0 or
        spec.damage > 0 or spec.movePerTick > 0
    doAssert itemIconKey(item).len > 5
  doAssert names.len == 22
  doAssert ShopItems.len == Item.high.ord
  for item in Item:
    if item != NoItem:
      doAssert item in ShopItems
  doAssert itemFromId(0) == NoItem
  doAssert itemFromId(int32(LeatherGauntlets.ord)) == LeatherGauntlets

echo "test_gota_content: all checks passed"
