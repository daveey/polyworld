## Deterministic Gods of the Arena hero classes and their integer tuning.
## Graphics attach models and portraits to these identities separately.

import polyworld/[cli, fxshapes]

export fxshapes

const
  InventorySlots* = 6
  HeroMaxLevel* = 20
  MeleeCreepsPerBarracks* = 3
  CreepsPerBarracks* = MeleeCreepsPerBarracks + 1
  ## Normalized accelerating health growth avoids runtime floating point.
  CarryHealthGrowth: array[HeroMaxLevel, int32] = [
    0, 90, 273, 522, 827, 1181, 1581, 2024, 2506, 3025,
    3581, 4171, 4794, 5449, 6135, 6851, 7596, 8370, 9171, 10000
  ]
  TickRate* = SharedTickRate
    ## Simulation ticks per second.
  DraftPickTicks* = 10 * TickRate
    ## Each human or bot gets ten simulation seconds to choose a hero.

type
  CreepKind* = enum MeleeCreep, RangedCreep

  HeroClass* = enum
    VanguardKnight,
    Ranger,
    Arcanist,
    DruidWarden,
    DemonHunter,
    DeathKnight,
    Crossbowman,
    Lich,
    Warlock,
    Berserker
  HeroAttackStyle* = enum
    MeleeAttack,
    RangedAttack,
    MagicAttack
  HeroRole* = enum
    Frontline, Carry, Mage, Support, Fighter
  HeroAbilitySlot* = enum
    PassiveAbility,
    PrimaryAbility,
    SecondaryAbility,
    UltimateAbility
  Ability* = enum
    LionGuard, FirebrandSword, InfernoAegis, BlazingBlade,
    DragonSight, VerdantArrow, RicochetDisc, StormEagle,
    ManaCrystal, FrostLance, MeteorStrike, ArcaneMeteor,
    NatureTalisman, HealingBloom, KindredWisps, GolemSeed,
    ShadowCloak, VoidBlade, GaleSlash, ShadowComet,
    SanguineChalice, AfterlightSickle, WitheringIdol, DarkEclipse,
    FinalMeasure, SiegeScarab, LodestoneSurge, ClockworkCharge,
    FrostSigil, IceSpear, BoneMarionette, BoundVoid,
    AetherSiphon, MothHex, DreadTotem, VoidPortal,
    RageCrucible, MoltenFist, WingedBoot, VolcanicEruption
  AbilityKind* = enum
    Strike, Heal, Restore
  ControlEffect* = enum
    NoControl, StunControl, SilenceControl, RootControl
  ControlTimer* = object
    started*, ends*: int32
  CastKind* = enum
    SelfCast, MeleeCast, ProjectileCast, AreaCast
  HealthGrowth* = enum
    SteadyGrowth, DelayedGrowth
  HeroSpec* = object
    name*: string
    role*: string
    attackStyle*: HeroAttackStyle
    baseHitPoints*: int32
    hitPointsPerLevel*: int32
      ## Average HP gain, distributed according to the selected growth curve.
    healthGrowth*: HealthGrowth
    baseMana*: int32
    maxLevelMana*: int32
    baseDamage*: int32
    damagePerLevel*: int32
    baseMovePerTick*: int32
    movePerLevel*: int32
    attackRange*: int32
    attackTicks*: int32
    abilities*: array[HeroAbilitySlot, Ability]
  AbilitySpec* = object
    slot*: HeroAbilitySlot
    name*: string
    icon*: string
    kind*: AbilityKind
    casting*: CastKind
    area*: FxArea
    effect*: FxShape
    fromCaster*: bool
    charges*: int32
    rechargeTicks*: int32
    castTicks*: int32
    projectileSpeed*: int32
    cooldownTicks*: int32
    manaCost*: int32
    range*: int32
    damage*: int32
    damageRanks*: array[4, int32]
    heal*: int32
    restore*: int32
    control*: ControlEffect
    controlTicks*: int32
  Item* = enum
    NoItem,
    HealthPotion,
    VitalityElixir,
    ManaElixir,
    PoisonPotion,
    SteelHelmet,
    SteelBuckler,
    LeatherGauntlets,
    RangerBoots,
    RubyAmulet,
    SapphireRing,
    CrimsonDagger,
    AmethystWand,
    SunsteelLongsword,
    RangerBow,
    IronbarkPauldrons,
    KnightArmor,
    ThornwoodStaff,
    BattleAxe,
    RuneCrossbow,
    ArcaneSpellbook,
    PortalScroll,
    ManaPotion
  ItemKind* = enum
    Consumable, Equipment
  RecoveryKind* = enum
    HealthRecovery, ManaRecovery
  ItemSpec* = object
    name*: string
    icon*: string
    kind*: ItemKind
    cost*: int32
    maxHp*: int32
    maxMana*: int32
    damage*: int32
    movePerTick*: int32
    heal*: int32
    restore*: int32
    strike*: int32
    channelTicks*, cooldownTicks*, recoveryTicks*: int32

const
  MaxItemStack* = 8
  PotionCooldownTicks* = 10 * TickRate
  PotionRecoveryTicks* = 10 * TickRate
  SpawnRecoverySeconds* = 5
  PortalChannelTicks* = 3 * TickRate
  PortalCooldownTicks* = 60 * TickRate
  HeroClassCount* = HeroClass.high.ord + 1
  HeroClassesPerTeam* = 5
  RedHeroClasses*: array[HeroClassesPerTeam, HeroClass] = [
    DeathKnight,
    Crossbowman,
    Lich,
    Warlock,
    Berserker
  ]
  BlueHeroClasses*: array[HeroClassesPerTeam, HeroClass] = [
    VanguardKnight,
    Ranger,
    Arcanist,
    DruidWarden,
    DemonHunter
  ]
  HeroSpecs*: array[HeroClass, HeroSpec] = [
    HeroSpec(
      name: "Vanguard Knight",
      role: "Frontline protector",
      attackStyle: MeleeAttack,
      baseHitPoints: 451,
      hitPointsPerLevel: 113,
      baseMana: 107,
      maxLevelMana: 254,
      baseDamage: 33,
      damagePerLevel: 6,
      baseMovePerTick: 5_665,
      movePerLevel: 40,
      attackRange: 70_000,
      attackTicks: 27,
      abilities: [
        LionGuard, FirebrandSword, InfernoAegis, BlazingBlade
      ]
    ),
    HeroSpec(
      name: "Ranger",
      role: "Mobile ranged carry",
      attackStyle: RangedAttack,
      baseHitPoints: 218,
      hitPointsPerLevel: 90,
      healthGrowth: DelayedGrowth,
      baseMana: 52,
      maxLevelMana: 361,
      baseDamage: 21,
      damagePerLevel: 12,
      baseMovePerTick: 5_610,
      movePerLevel: 174,
      attackRange: 360_000,
      attackTicks: 30,
      abilities: [
        DragonSight, VerdantArrow, RicochetDisc, StormEagle
      ]
    ),
    HeroSpec(
      name: "Arcanist",
      role: "Burst mage",
      attackStyle: MagicAttack,
      baseHitPoints: 288,
      hitPointsPerLevel: 19,
      baseMana: 185,
      maxLevelMana: 479,
      baseDamage: 26,
      damagePerLevel: 5,
      baseMovePerTick: 6_324,
      movePerLevel: 71,
      attackRange: 300_000,
      attackTicks: 30,
      abilities: [
        ManaCrystal, FrostLance, MeteorStrike, ArcaneMeteor
      ]
    ),
    HeroSpec(
      name: "Druid Warden",
      role: "Durable support",
      attackStyle: MagicAttack,
      baseHitPoints: 350,
      hitPointsPerLevel: 20,
      baseMana: 167,
      maxLevelMana: 427,
      baseDamage: 24,
      damagePerLevel: 2,
      baseMovePerTick: 6_592,
      movePerLevel: 72,
      attackRange: 240_000,
      attackTicks: 30,
      abilities: [
        NatureTalisman, HealingBloom, KindredWisps, GolemSeed
      ]
    ),
    HeroSpec(
      name: "Demon Hunter",
      role: "Melee assassin",
      attackStyle: MeleeAttack,
      baseHitPoints: 335,
      hitPointsPerLevel: 67,
      baseMana: 93,
      maxLevelMana: 230,
      baseDamage: 29,
      damagePerLevel: 5,
      baseMovePerTick: 6_125,
      movePerLevel: 168,
      attackRange: 75_000,
      attackTicks: 15,
      abilities: [
        ShadowCloak, VoidBlade, GaleSlash, ShadowComet
      ]
    ),
    HeroSpec(
      name: "Death Knight",
      role: "Sustaining bruiser",
      attackStyle: MeleeAttack,
      baseHitPoints: 425,
      hitPointsPerLevel: 105,
      baseMana: 93,
      maxLevelMana: 249,
      baseDamage: 36,
      damagePerLevel: 6,
      baseMovePerTick: 5_335,
      movePerLevel: 38,
      attackRange: 76_000,
      attackTicks: 28,
      abilities: [
        SanguineChalice, AfterlightSickle, WitheringIdol, DarkEclipse
      ]
    ),
    HeroSpec(
      name: "Crossbowman",
      role: "Heavy ranged carry",
      attackStyle: RangedAttack,
      baseHitPoints: 225,
      hitPointsPerLevel: 96,
      healthGrowth: DelayedGrowth,
      baseMana: 49,
      maxLevelMana: 340,
      baseDamage: 19,
      damagePerLevel: 12,
      baseMovePerTick: 5_390,
      movePerLevel: 168,
      attackRange: 360_000,
      attackTicks: 30,
      abilities: [
        FinalMeasure, SiegeScarab, LodestoneSurge, ClockworkCharge
      ]
    ),
    HeroSpec(
      name: "Lich",
      role: "Control mage",
      attackStyle: MagicAttack,
      baseHitPoints: 312,
      hitPointsPerLevel: 21,
      baseMana: 204,
      maxLevelMana: 517,
      baseDamage: 24,
      damagePerLevel: 5,
      baseMovePerTick: 5_880,
      movePerLevel: 59,
      attackRange: 330_000,
      attackTicks: 30,
      abilities: [
        FrostSigil, IceSpear, BoneMarionette, BoundVoid
      ]
    ),
    HeroSpec(
      name: "Warlock",
      role: "Utility summoner",
      attackStyle: MagicAttack,
      baseHitPoints: 338,
      hitPointsPerLevel: 20,
      baseMana: 194,
      maxLevelMana: 504,
      baseDamage: 26,
      damagePerLevel: 2,
      baseMovePerTick: 6_014,
      movePerLevel: 68,
      attackRange: 270_000,
      attackTicks: 30,
      abilities: [
        AetherSiphon, MothHex, DreadTotem, VoidPortal
      ]
    ),
    HeroSpec(
      name: "Berserker",
      role: "Aggressive melee carry",
      attackStyle: MeleeAttack,
      baseHitPoints: 315,
      hitPointsPerLevel: 63,
      baseMana: 87,
      maxLevelMana: 216,
      baseDamage: 41,
      damagePerLevel: 7,
      baseMovePerTick: 6_375,
      movePerLevel: 174,
      attackRange: 80_000,
      attackTicks: 20,
      abilities: [
        RageCrucible, MoltenFist, WingedBoot, VolcanicEruption
      ]
    )
  ]
  BaseAbilitySpecs*: array[Ability, AbilitySpec] = [
    LionGuard: AbilitySpec(
      slot: PassiveAbility,
      name: "Lion Guard", icon: "lion_guard",
      kind: Heal, cooldownTicks: 192, heal: 28
    ),
    FirebrandSword: AbilitySpec(
      slot: PrimaryAbility,
      name: "Firebrand Sword", icon: "firebrand_sword",
      kind: Strike, cooldownTicks: 96, manaCost: 20,
      range: 120_000, damage: 37,
      control: StunControl, controlTicks: TickRate div 2
    ),
    InfernoAegis: AbilitySpec(
      slot: SecondaryAbility,
      name: "Inferno Aegis", icon: "inferno_aegis",
      kind: Heal, cooldownTicks: 240, manaCost: 35, heal: 50
    ),
    BlazingBlade: AbilitySpec(
      slot: UltimateAbility,
      name: "Blazing Blade", icon: "blazing_blade",
      kind: Strike, cooldownTicks: 480, manaCost: 70,
      range: 180_000, damage: 204,
      control: StunControl, controlTicks: TickRate
    ),
    DragonSight: AbilitySpec(
      slot: PassiveAbility,
      name: "Dragon Sight", icon: "dragon_sight",
      kind: Strike, cooldownTicks: 216,
      range: 420_000, damage: 10,
      damageRanks: [10, 19, 33, 47]
    ),
    VerdantArrow: AbilitySpec(
      slot: PrimaryAbility,
      name: "Verdant Arrow", icon: "verdant_arrow",
      kind: Strike, cooldownTicks: 72, manaCost: 18,
      range: 360_000, damage: 25,
      damageRanks: [25, 49, 85, 122]
    ),
    RicochetDisc: AbilitySpec(
      slot: SecondaryAbility,
      name: "Ricochet Disc", icon: "ricochet_disc",
      kind: Strike, cooldownTicks: 192, manaCost: 32,
      range: 390_000, damage: 35,
      damageRanks: [35, 66, 115, 165]
    ),
    StormEagle: AbilitySpec(
      slot: UltimateAbility,
      name: "Storm Eagle", icon: "storm_eagle",
      kind: Strike, cooldownTicks: 576, manaCost: 80,
      range: 480_000, damage: 110,
      damageRanks: [110, 250, 442, 0]
    ),
    ManaCrystal: AbilitySpec(
      slot: PassiveAbility,
      name: "Mana Crystal", icon: "mana_crystal",
      kind: Restore, cooldownTicks: 144, restore: 28
    ),
    FrostLance: AbilitySpec(
      slot: PrimaryAbility,
      name: "Frost Lance", icon: "frost_lance",
      kind: Strike, cooldownTicks: 96, manaCost: 28,
      range: 330_000, damage: 41
    ),
    MeteorStrike: AbilitySpec(
      slot: SecondaryAbility,
      name: "Meteor Strike", icon: "meteor_strike",
      kind: Strike, cooldownTicks: 216, manaCost: 53,
      range: 360_000, damage: 69
    ),
    ArcaneMeteor: AbilitySpec(
      slot: UltimateAbility,
      name: "Arcane Meteor", icon: "arcane_meteor",
      kind: Strike, cooldownTicks: 600, manaCost: 100,
      range: 420_000, damage: 255
    ),
    NatureTalisman: AbilitySpec(
      slot: PassiveAbility,
      name: "Nature Talisman", icon: "nature_talisman",
      kind: Heal, cooldownTicks: 192, heal: 22
    ),
    HealingBloom: AbilitySpec(
      slot: PrimaryAbility,
      name: "Thorn Bloom", icon: "healing_bloom",
      kind: Heal, cooldownTicks: 168, manaCost: 30, heal: 150, damage: 37
    ),
    KindredWisps: AbilitySpec(
      slot: SecondaryAbility,
      name: "Kindred Renewal", icon: "kindred_wisps",
      kind: Heal, cooldownTicks: 288, manaCost: 45, heal: 160, damage: 88
    ),
    GolemSeed: AbilitySpec(
      slot: UltimateAbility,
      name: "Golem Seed", icon: "golem_seed",
      kind: Strike, cooldownTicks: 528, manaCost: 75,
      range: 200_000, damage: 49,
      control: RootControl, controlTicks: 2 * TickRate
    ),
    ShadowCloak: AbilitySpec(
      slot: PassiveAbility,
      name: "Shadow Cloak", icon: "shadow_cloak",
      kind: Heal, cooldownTicks: 240, heal: 18
    ),
    VoidBlade: AbilitySpec(
      slot: PrimaryAbility,
      name: "Void Blade", icon: "void_blade",
      kind: Strike, cooldownTicks: 80, manaCost: 16,
      range: 90_000, damage: 39
    ),
    GaleSlash: AbilitySpec(
      slot: SecondaryAbility,
      name: "Gale Slash", icon: "gale_slash",
      kind: Strike, cooldownTicks: 168, manaCost: 28,
      range: 180_000, damage: 60,
      control: RootControl, controlTicks: TickRate div 2
    ),
    ShadowComet: AbilitySpec(
      slot: UltimateAbility,
      name: "Shadow Comet", icon: "shadow_comet",
      kind: Strike, cooldownTicks: 504, manaCost: 65,
      range: 300_000, damage: 177
    ),
    SanguineChalice: AbilitySpec(
      slot: PassiveAbility,
      name: "Sanguine Chalice", icon: "sanguine_chalice",
      kind: Heal, cooldownTicks: 192, heal: 83
    ),
    AfterlightSickle: AbilitySpec(
      slot: PrimaryAbility,
      name: "Afterlight Sickle", icon: "afterlight_sickle",
      kind: Strike, cooldownTicks: 108, manaCost: 18,
      range: 120_000, damage: 37,
      control: RootControl, controlTicks: TickRate div 2
    ),
    WitheringIdol: AbilitySpec(
      slot: SecondaryAbility,
      name: "Withering Idol", icon: "withering_idol",
      kind: Strike, cooldownTicks: 216, manaCost: 36,
      range: 160_000, damage: 59
    ),
    DarkEclipse: AbilitySpec(
      slot: UltimateAbility,
      name: "Dark Eclipse", icon: "dark_eclipse",
      kind: Strike, cooldownTicks: 624, manaCost: 80,
      range: 140_000, damage: 121
    ),
    FinalMeasure: AbilitySpec(
      slot: PassiveAbility,
      name: "Final Measure", icon: "final_measure",
      kind: Strike, cooldownTicks: 216,
      range: 420_000, damage: 9,
      damageRanks: [9, 19, 36, 52]
    ),
    SiegeScarab: AbilitySpec(
      slot: PrimaryAbility,
      name: "Siege Scarab", icon: "siege_scarab",
      kind: Strike, cooldownTicks: 120, manaCost: 22,
      range: 400_000, damage: 23,
      damageRanks: [23, 47, 91, 130]
    ),
    LodestoneSurge: AbilitySpec(
      slot: SecondaryAbility,
      name: "Lodestone Surge", icon: "lodestone_surge",
      kind: Strike, cooldownTicks: 240, manaCost: 40,
      range: 360_000, damage: 31,
      damageRanks: [31, 63, 122, 175]
    ),
    ClockworkCharge: AbilitySpec(
      slot: UltimateAbility,
      name: "Clockwork Charge", icon: "clockwork_charge",
      kind: Strike, cooldownTicks: 552, manaCost: 70,
      range: 450_000, damage: 106,
      damageRanks: [106, 240, 470, 0]
    ),
    FrostSigil: AbilitySpec(
      slot: PassiveAbility,
      name: "Frost Sigil", icon: "frost_sigil",
      kind: Strike, cooldownTicks: 192,
      range: 360_000, damage: 14
    ),
    IceSpear: AbilitySpec(
      slot: PrimaryAbility,
      name: "Ice Spear", icon: "ice_spear",
      kind: Strike, cooldownTicks: 96, manaCost: 30,
      range: 400_000, damage: 49
    ),
    BoneMarionette: AbilitySpec(
      slot: SecondaryAbility,
      name: "Bone Marionette", icon: "bone_marionette",
      kind: Strike, cooldownTicks: 216, manaCost: 48,
      range: 300_000, damage: 49,
      control: RootControl, controlTicks: 36
    ),
    BoundVoid: AbilitySpec(
      slot: UltimateAbility,
      name: "Bound Void", icon: "bound_void",
      kind: Strike, cooldownTicks: 648, manaCost: 110,
      range: 390_000, damage: 262
    ),
    AetherSiphon: AbilitySpec(
      slot: PassiveAbility,
      name: "Aether Siphon", icon: "aether_siphon",
      kind: Restore, cooldownTicks: 168, restore: 30
    ),
    MothHex: AbilitySpec(
      slot: PrimaryAbility,
      name: "Mending Hex", icon: "moth_hex",
      kind: Heal, cooldownTicks: 96, manaCost: 24,
      range: 360_000, damage: 35, heal: 220
    ),
    DreadTotem: AbilitySpec(
      slot: SecondaryAbility,
      name: "Dread Pact", icon: "dread_totem",
      kind: Heal, cooldownTicks: 216, manaCost: 42,
      range: 360_000, damage: 84, heal: 240,
      control: SilenceControl, controlTicks: 2 * TickRate
    ),
    VoidPortal: AbilitySpec(
      slot: UltimateAbility,
      name: "Void Portal", icon: "void_portal",
      kind: Strike, cooldownTicks: 576, manaCost: 90,
      range: 300_000, damage: 47
    ),
    RageCrucible: AbilitySpec(
      slot: PassiveAbility,
      name: "Rage Crucible", icon: "rage_crucible",
      kind: Heal, cooldownTicks: 192, heal: 20
    ),
    MoltenFist: AbilitySpec(
      slot: PrimaryAbility,
      name: "Molten Fist", icon: "molten_fist",
      kind: Strike, cooldownTicks: 84, manaCost: 8,
      range: 90_000, damage: 44
    ),
    WingedBoot: AbilitySpec(
      slot: SecondaryAbility,
      name: "Winged Boot", icon: "winged_boot",
      kind: Strike, cooldownTicks: 192, manaCost: 12,
      range: 210_000, damage: 35,
      control: RootControl, controlTicks: TickRate * 3 div 4
    ),
    VolcanicEruption: AbilitySpec(
      slot: UltimateAbility,
      name: "Volcanic Eruption", icon: "volcanic_eruption",
      kind: Strike, cooldownTicks: 480, manaCost: 24,
      range: 130_000, damage: 188
    )
  ]
  ItemSpecs*: array[Item, ItemSpec] = [
    ItemSpec(),
    ItemSpec(
      name: "Health Potion", icon: "health_leaf",
      kind: Consumable, cost: 30, heal: 120,
      recoveryTicks: PotionRecoveryTicks, cooldownTicks: PotionCooldownTicks
    ),
    ItemSpec(
      name: "Vitality Elixir", icon: "vitality_elixir",
      kind: Consumable, cost: 75, heal: 90,
      cooldownTicks: PotionCooldownTicks
    ),
    ItemSpec(
      name: "Mana Elixir", icon: "mana_potion",
      kind: Consumable, cost: 90, restore: 60,
      cooldownTicks: PotionCooldownTicks
    ),
    ItemSpec(
      name: "Poison Potion", icon: "poison_potion",
      kind: Consumable, cost: 40, strike: 35
    ),
    ItemSpec(
      name: "Steel Helmet", icon: "steel_helmet",
      kind: Equipment, cost: 80, maxHp: 50
    ),
    ItemSpec(
      name: "Steel Buckler", icon: "steel_buckler",
      kind: Equipment, cost: 90, maxHp: 60
    ),
    ItemSpec(
      name: "Leather Gauntlets", icon: "leather_gauntlets",
      kind: Equipment, cost: 70, damage: 4
    ),
    ItemSpec(
      name: "Ranger Boots", icon: "ranger_boots",
      kind: Equipment, cost: 100, movePerTick: 800
    ),
    ItemSpec(
      name: "Ruby Amulet", icon: "ruby_amulet",
      kind: Equipment, cost: 120, maxHp: 70
    ),
    ItemSpec(
      name: "Sapphire Ring", icon: "sapphire_ring",
      kind: Equipment, cost: 120, maxMana: 40
    ),
    ItemSpec(
      name: "Crimson Dagger", icon: "crimson_dagger",
      kind: Equipment, cost: 110, damage: 8
    ),
    ItemSpec(
      name: "Amethyst Wand", icon: "amethyst_wand",
      kind: Equipment, cost: 140, damage: 9
    ),
    ItemSpec(
      name: "Sunsteel Longsword", icon: "sunsteel_longsword",
      kind: Equipment, cost: 150, damage: 10
    ),
    ItemSpec(
      name: "Ranger Bow", icon: "ranger_bow",
      kind: Equipment, cost: 150, damage: 10
    ),
    ItemSpec(
      name: "Ironbark Pauldrons", icon: "ironbark_pauldrons",
      kind: Equipment, cost: 140, maxHp: 80
    ),
    ItemSpec(
      name: "Knight Armor", icon: "knight_armor",
      kind: Equipment, cost: 160, maxHp: 120
    ),
    ItemSpec(
      name: "Thornwood Staff", icon: "thornwood_staff",
      kind: Equipment, cost: 170, maxHp: 40, damage: 6
    ),
    ItemSpec(
      name: "Battle Axe", icon: "battle_axe",
      kind: Equipment, cost: 180, damage: 14
    ),
    ItemSpec(
      name: "Rune Crossbow", icon: "rune_crossbow",
      kind: Equipment, cost: 180, damage: 14
    ),
    ItemSpec(
      name: "Arcane Spellbook", icon: "arcane_spellbook",
      kind: Equipment, cost: 190, maxMana: 30, damage: 12
    ),
    ItemSpec(
      name: "Portal Scroll", icon: "waystone_scroll",
      kind: Consumable, cost: 100,
      channelTicks: PortalChannelTicks, cooldownTicks: PortalCooldownTicks
    ),
    ItemSpec(
      name: "Mana Potion", icon: "mana_flower",
      kind: Consumable, cost: 45, restore: 90,
      recoveryTicks: PotionRecoveryTicks, cooldownTicks: PotionCooldownTicks
    )
  ]

const ShopItems* = [
  HealthPotion, VitalityElixir, ManaPotion, ManaElixir, PoisonPotion,
  PortalScroll, SteelHelmet, SteelBuckler, LeatherGauntlets, RangerBoots,
  RubyAmulet, SapphireRing, CrimsonDagger, AmethystWand, SunsteelLongsword,
  RangerBow, IronbarkPauldrons, KnightArmor, ThornwoodStaff, BattleAxe,
  RuneCrossbow, ArcaneSpellbook
]

proc heroClassForTeam*(team, slot: int): HeroClass =
  ## Assigns one of five stable class identities to a team's local slot.
  if team == 0:
    RedHeroClasses[slot mod HeroClassesPerTeam]
  else:
    BlueHeroClasses[slot mod HeroClassesPerTeam]

proc heroSpec*(class: HeroClass): HeroSpec =
  ## Returns the immutable integer tuning for one hero class.
  HeroSpecs[class]

proc heroRole*(class: HeroClass): HeroRole {.raises: [].} =
  ## Groups heroes into the five complementary draft roles.
  case class
  of VanguardKnight, DeathKnight: Frontline
  of Ranger, Crossbowman: Carry
  of Arcanist, Lich: Mage
  of DruidWarden, Warlock: Support
  of DemonHunter, Berserker: Fighter

proc abilitySpec*(ability: Ability): AbilitySpec =
  ## Returns casting, charge, effect and shape tuning for one ability.
  result = BaseAbilitySpecs[ability]
  result.charges = 1
  result.rechargeTicks = result.cooldownTicks
  result.area = FxArea(
    shape: CircleFootprint, radius: 90_000, width: 60_000,
    length: result.range, height: 120_000, angle: 90
  )
  result.effect = AoeCircleShape
  if result.kind != Strike:
    result.casting = SelfCast
  elif result.range <= 110_000:
    result.casting = MeleeCast
  else:
    result.casting = ProjectileCast
    result.projectileSpeed = 45_000
  case ability
  of FirebrandSword, VerdantArrow, FrostLance, VoidBlade,
    AfterlightSickle, SiegeScarab, IceSpear, MothHex, MoltenFist:
      result.charges = 3
      result.cooldownTicks = 2 * TickRate
      result.rechargeTicks = 12 * TickRate
  else:
    discard
  case ability
  of FirebrandSword, AfterlightSickle:
    result.casting = MeleeCast
    result.projectileSpeed = 0
  of MothHex, DreadTotem:
    result.casting = ProjectileCast
    result.projectileSpeed = 45_000
    if ability == DreadTotem:
      result.castTicks = 18
  of BlazingBlade, GaleSlash:
    result.casting = AreaCast
    result.fromCaster = true
    result.effect = if ability == GaleSlash: AoeConeShape else: ArcShape
    result.area.shape = SectorFootprint
    result.area.radius = result.range
    result.area.angle = 120
    result.castTicks = 6
  of StormEagle, ClockworkCharge:
    result.casting = AreaCast
    result.fromCaster = true
    result.effect =
      if ability == StormEagle: AoeLineShape else: AoeCapsuleShape
    result.area.shape =
      if ability == StormEagle: LineFootprint else: CapsuleFootprint
    result.area.width = 90_000
    result.castTicks = 24
  of LodestoneSurge, WingedBoot:
    result.casting = AreaCast
    result.fromCaster = true
    result.effect = AoeConeShape
    result.area.shape = SectorFootprint
    result.area.radius = result.range
    result.castTicks = 12
  of InfernoAegis, DarkEclipse:
    result.casting = AreaCast
    result.fromCaster = true
    result.effect = RingShape
    result.area.shape = RingFootprint
    result.area.radius = 140_000
    result.area.innerRadius = 40_000
    if ability == InfernoAegis:
      result.effect = AoeCircleShape
      result.area.shape = CircleFootprint
      result.area.innerRadius = 0
    result.castTicks = 12
  of MeteorStrike, ArcaneMeteor, VolcanicEruption:
    result.casting = AreaCast
    result.area.radius = if ability == ArcaneMeteor: 180_000 else: 120_000
    result.castTicks =
      case ability
      of ArcaneMeteor: 36
      of MeteorStrike: 24
      else: 24
  of HealingBloom, KindredWisps:
    result.casting = AreaCast
    result.range = 360_000
    result.area.radius = if ability == HealingBloom: 120_000 else: 150_000
    result.effect =
      if ability == HealingBloom:
        AoeCircleShape
      else:
        SphereShape
    result.castTicks = 12
  of RicochetDisc, GolemSeed, WitheringIdol, BoneMarionette,
    BoundVoid, VoidPortal:
      result.casting = AreaCast
      result.area.radius = 120_000
      result.castTicks = 24
      case ability
      of RicochetDisc:
        result.effect = DiscShape
      of GolemSeed:
        result.effect = CylinderShape
      of WitheringIdol:
        result.effect = AoeCircleShape
      of BoneMarionette:
        result.effect = HemisphereShape
      of BoundVoid:
        result.effect = TorusShape
        result.area.shape = RingFootprint
        result.area.innerRadius = 40_000
      of VoidPortal:
        result.effect = HelixShape
        result.area.shape = RingFootprint
        result.area.innerRadius = 40_000
      else:
        discard
  else:
    discard
  if ability == MoltenFist:
    result.manaCost = 0
  if result.casting == AreaCast:
    result.projectileSpeed = 0
    if result.range == 0:
      result.range = if result.fromCaster: result.area.radius else: 240_000

proc heroAbility*(class: HeroClass, slot: HeroAbilitySlot): Ability =
  ## Returns the ability bound to one class slot.
  class.heroSpec.abilities[slot]

proc canTarget*(spec: AbilitySpec, allied: bool): bool {.raises: [].} =
  ## Returns whether a spell can affect an ally or an enemy.
  if allied:
    spec.heal > 0 or spec.restore > 0
  else:
    spec.damage > 0

proc abilityMaxLevel*(slot: HeroAbilitySlot): int32 =
  ## Returns the number of learnable ranks for an ability slot.
  if slot == UltimateAbility: 3 else: 4

proc abilityRequiredLevel*(slot: HeroAbilitySlot, rank: int32): int32 =
  ## Returns the hero level needed to learn a rank, or zero for invalid ranks.
  if rank < 1 or rank > slot.abilityMaxLevel:
    return 0
  if slot == UltimateAbility: rank * 6 else: rank * 2 - 1

proc abilitySpec*(ability: Ability, rank: int32): AbilitySpec =
  ## Scales effects by rank while retaining the ability's timing and geometry.
  result = ability.abilitySpec
  let
    level = clamp(rank, 0'i32, result.slot.abilityMaxLevel)
    scale = if level == 0: 0'i32 else: level + 1
  if result.damageRanks[0] > 0:
    result.damage =
      if level == 0:
        0
      else:
        result.damageRanks[level - 1]
  else:
    result.damage = result.damage * scale div 2
  result.heal = result.heal * scale div 2
  result.restore = result.restore * scale div 2
  if level == 0:
    result.charges = 0
    result.controlTicks = 0

const AbilityIconKeys = block:
  var keys: array[Ability, string]
  for ability in Ability:
    keys[ability] = "ability_" & ability.abilitySpec.icon
  keys

proc abilityIconKey*(ability: Ability): string =
  ## Returns the atlas name without constructing it during drawing.
  AbilityIconKeys[ability]

proc itemSpec*(item: Item): ItemSpec =
  ## Returns the immutable shop tuning for one item.
  ItemSpecs[item]

proc itemFromId*(id: int32): Item =
  ## Maps a BASIC item id onto the shop catalog.
  if id <= 0 or id > int32(Item.high.ord):
    NoItem
  else:
    Item(id)

const ItemIconKeys = block:
  var keys: array[Item, string]
  for item in Item:
    if item != NoItem:
      keys[item] = "item_" & $item
  keys

proc itemIconKey*(item: Item): string =
  ## Returns the atlas name without constructing it during drawing.
  ItemIconKeys[item]

proc heroMaxHp*(class: HeroClass, level: int): int32 =
  ## Returns class hit points using its declared deterministic growth curve.
  let
    spec = class.heroSpec
    level = clamp(level, 1, HeroMaxLevel)
  case spec.healthGrowth
  of SteadyGrowth:
    spec.baseHitPoints + int32(level - 1) * spec.hitPointsPerLevel
  of DelayedGrowth:
    spec.baseHitPoints + int32(HeroMaxLevel - 1) *
      spec.hitPointsPerLevel * CarryHealthGrowth[level - 1] div 10_000

proc heroMaxMana*(class: HeroClass, level: int): int32 =
  ## Interpolates maximum mana between the first and final hero levels.
  let spec = class.heroSpec
  spec.baseMana + int32(level - 1) *
    (spec.maxLevelMana - spec.baseMana) div int32(HeroMaxLevel - 1)

proc heroDamage*(class: HeroClass, level: int): int32 =
  ## Returns class basic-attack damage at one level.
  let spec = class.heroSpec
  spec.baseDamage + int32(level - 1) * spec.damagePerLevel

proc heroMovePerTick*(class: HeroClass, level: int): int32 =
  ## Returns class movement distance for one authoritative tick.
  let spec = class.heroSpec
  spec.baseMovePerTick + int32(level - 1) * spec.movePerLevel

proc heroAttackCasting*(class: HeroClass): CastKind =
  ## Classifies basic attacks as melee or ranged, including magic bolts.
  if class.heroSpec.attackStyle == MeleeAttack:
    MeleeCast
  else:
    ProjectileCast

proc heroAttackRange*(class: HeroClass): int32 =
  ## Returns class basic-attack range in integer world units.
  class.heroSpec.attackRange

proc heroAttackTicks*(class: HeroClass): int32 =
  ## Returns the class basic-attack period in simulation ticks.
  class.heroSpec.attackTicks
