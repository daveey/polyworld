## Light vs Dark content table checks: balance sanity and tech shape.

import
  std/[sets, strformat, strutils],
  polyworld/hashes,
  ../examples/light_vs_dark/[content, factions]

## Every stat that would break the simulation if it were zero or negative.

block positiveUnitStats:
  for player in 0 ..< FactionCount:
    for kind in UnitKind:
      let stats = UnitTable[player][kind]
      doAssert stats.gold > 0, &"{player} {kind} costs no gold"
      doAssert stats.wood >= 0, &"{player} {kind} has a negative wood cost"
      doAssert stats.trainTicks > 0, &"{player} {kind} trains instantly"
      doAssert stats.hp > 0, &"{player} {kind} spawns dead"
      doAssert stats.armor >= 0, &"{player} {kind} has negative armor"
      doAssert stats.piercing + stats.basic > 0,
        &"{player} {kind} cannot hurt anything"
      doAssert stats.splash >= 0, &"{player} {kind} has negative splash"
      doAssert stats.missPercent >= 0 and stats.missPercent < 100,
        &"{player} {kind} has a broken miss chance"
      doAssert stats.cooldownTicks > 0, &"{player} {kind} attacks every tick"
      doAssert stats.rangeTiles > 0, &"{player} {kind} cannot reach anything"
      doAssert stats.sightTiles > 0, &"{player} {kind} is blind"
      doAssert stats.stepTicks > 0, &"{player} {kind} teleports"
      doAssert stats.food > 0, &"{player} {kind} is free to supply"

block positiveBuildingStats:
  for kind in BuildingKind:
    let stats = BuildingTable[kind]
    doAssert stats.hp > 0, &"{kind} spawns destroyed"
    doAssert stats.footprint.width > 0 and stats.footprint.depth > 0,
      &"{kind} occupies no tiles"
    doAssert stats.footprint.width <= 8 and stats.footprint.depth <= 8,
      &"{kind} has an unreasonable footprint"
    doAssert stats.sightTiles >= 0, &"{kind} has negative sight"
    doAssert stats.foodProvided >= 0, &"{kind} removes food"
    if kind <= BuildableHigh:
      doAssert stats.gold > 0, &"{kind} costs no gold"
      doAssert stats.wood > 0, &"{kind} costs no wood"
      doAssert stats.buildTicks > 0, &"{kind} builds instantly"

## A tower is the only thing with a weapon, and it needs a complete weapon.

block towerIsTheOnlyArmedBuilding:
  for kind in BuildingKind:
    let stats = BuildingTable[kind]
    if kind == TowerBuilding:
      doAssert stats.damage > 0 and stats.cooldownTicks > 0 and
        stats.rangeTiles > 0, "the tower has an incomplete weapon"
    else:
      doAssert stats.damage == 0 and stats.cooldownTicks == 0 and
        stats.rangeTiles == 0, &"{kind} is unexpectedly armed"

## The opening position has to be playable: enough food for the starting
## peons, and enough gold to afford the first thing a bot would want.

block openingIsPlayable:
  let
    startingFood = BuildingTable[TownHallBuilding].foodProvided
    peonFood = UnitTable[LightPlayer][PeonUnit].food * StartingPeons
  doAssert startingFood >= peonFood,
    &"the town hall supplies {startingFood} food but {StartingPeons} peons " &
    &"need {peonFood}"
  doAssert StartingGold >= BuildingTable[FarmBuilding].gold,
    "a player cannot afford a first farm"
  doAssert StartingWood >= BuildingTable[FarmBuilding].wood,
    "a player cannot afford a first farm"
  doAssert FoodCapMax <= UnitsPerPlayer,
    "the food ceiling lets a player exceed the unit cap"

## A peon must be able to reach the food ceiling: without a buildable food
## source the game would stall at the town hall's supply.

block foodEconomyCloses:
  var buildableFood = 0'i32
  for kind in BuildingKind:
    if kind <= BuildableHigh:
      buildableFood += BuildingTable[kind].foodProvided
  doAssert buildableFood > 0, "no buildable structure provides food"

## Somebody must be able to gather each resource and drop it off somewhere.

block resourcesCanBeGatheredAndStored:
  var goldDropOffs, woodDropOffs = 0
  for kind in BuildingKind:
    if BuildingTable[kind].dropOffGold:
      inc goldDropOffs
    if BuildingTable[kind].dropOffWood:
      inc woodDropOffs
  doAssert goldDropOffs > 0, "gold can never be deposited"
  doAssert woodDropOffs > 0, "wood can never be deposited"
  doAssert BuildingTable[TownHallBuilding].dropOffGold,
    "the town hall must accept gold or the opening cannot function"
  doAssert BuildingTable[TownHallBuilding].dropOffWood,
    "the town hall must accept wood when it is closer than a mill"
  doAssert BuildingTable[LumberMillBuilding].dropOffWood,
    "the lumber mill must accept wood"
  doAssert GoldPerTrip > 0 and MineTicks > 0 and MinersPerMine > 0
  doAssert WoodPerTrip > 0 and ChopTicks > 0
  doAssert WoodPerTree > 0 and WoodPerTree.int32 mod WoodPerTrip == 0,
    "a tree must yield a whole number of trips"

## Tech prerequisites must terminate. Buildings may only require buildings,
## and following the requirement edges must never revisit a kind.

block techIsAcyclic:
  proc resolve(kind: BuildingKind, seen: var HashSet[BuildingKind]) =
    doAssert kind notin seen, &"building tech cycles through {kind}"
    seen.incl kind
    for required in BuildingTable[kind].requires:
      doAssert required <= BuildableHigh,
        &"{kind} requires the unbuildable {required}"
      var branch = seen
      resolve(required, branch)

  for kind in BuildingKind:
    var seen: HashSet[BuildingKind]
    resolve(kind, seen)

block unitTechIsReachable:
  for player in 0 ..< FactionCount:
    for kind in UnitKind:
      let stats = UnitTable[player][kind]
      doAssert stats.trainedAt <= BuildableHigh,
        &"{player} {kind} trains at the unbuildable {stats.trainedAt}"
      for required in stats.requires:
        doAssert required <= BuildableHigh,
          &"{player} {kind} requires the unbuildable {required}"
  doAssert UnitTable[LightPlayer][PeonUnit].trainedAt ==
    TownHallBuilding and
    UnitTable[LightPlayer][PeonUnit].requires.card == 0,
    "the opening peon must need no tech"

block wc1TrainSites:
  let stats = UnitTable[LightPlayer]
  doAssert stats[SoldierUnit].trainedAt == BarracksBuilding
  doAssert stats[ArcherUnit].trainedAt == BarracksBuilding
  doAssert LumberMillBuilding in stats[ArcherUnit].requires
  doAssert stats[KnightUnit].trainedAt == BarracksBuilding
  doAssert StablesBuilding in stats[KnightUnit].requires
  doAssert BlacksmithBuilding in stats[KnightUnit].requires
  doAssert stats[CatapultUnit].trainedAt == BarracksBuilding
  doAssert BlacksmithBuilding in stats[CatapultUnit].requires
  doAssert LumberMillBuilding in stats[CatapultUnit].requires
  doAssert stats[ClericUnit].trainedAt == ChurchBuilding
  doAssert stats[MageUnit].trainedAt == TowerBuilding
  doAssert stats[SummonUnit].trainedAt == TowerBuilding
  doAssert BuildingTable[StablesBuilding].requires == {BarracksBuilding}
  doAssert BuildingTable[ChurchBuilding].requires == {BarracksBuilding}
  doAssert BuildingTable[BlacksmithBuilding].requires == {BarracksBuilding}

block wc1SideDifferences:
  doAssert UnitTable[LightPlayer][ArcherUnit].rangeTiles == 5
  doAssert UnitTable[DarkPlayer][ArcherUnit].rangeTiles == 4
  doAssert UnitTable[LightPlayer][ArcherUnit].piercing == 4
  doAssert UnitTable[DarkPlayer][ArcherUnit].piercing == 5
  doAssert UnitTable[LightPlayer][ClericUnit].rangeTiles == 1
  doAssert UnitTable[DarkPlayer][ClericUnit].rangeTiles == 2
  doAssert UnitTable[LightPlayer][MageUnit].rangeTiles == 3
  doAssert UnitTable[DarkPlayer][MageUnit].rangeTiles == 2
  doAssert UnitTable[LightPlayer][SummonUnit].hp == 250
  doAssert UnitTable[DarkPlayer][SummonUnit].hp == 300
  doAssert UnitTable[LightPlayer][SummonUnit].rangeTiles == 3
  doAssert UnitTable[DarkPlayer][SummonUnit].rangeTiles == 1
  doAssert UnitTable[LightPlayer][CatapultUnit].splash == 63
  doAssert UnitTable[LightPlayer][CatapultUnit].missPercent == 0
  doAssert attackDamage(UnitTable[LightPlayer][SoldierUnit], 2) == 8
  doAssert attackDamage(UnitTable[DarkPlayer][SummonUnit], 0) == 65

## Diagonal steps must cost more than orthogonal ones but less than two.

block diagonalCostIsSane:
  for player in 0 ..< FactionCount:
    for kind in UnitKind:
      let
        straight = UnitTable[player][kind].stepTicks
        diagonal = diagonalStepTicks(straight)
      doAssert diagonal > straight, &"{player} {kind} moves diagonally for free"
      doAssert diagonal < straight * 2,
        &"{player} {kind} pays too much for a diagonal"

## The fingerprint must be stable within a build and must actually respond to
## the tables, otherwise it cannot guard a replay.

block contentHashIsStable:
  let first = contentHash()
  doAssert first == contentHash(), "contentHash is not deterministic"
  doAssert first != 0, "contentHash is empty"
  doAssert first != uint64(HashySeed), "contentHash mixed nothing in"

block addHashyDistinguishesValues:
  var a, b = HashySeed
  a.addHashy(1'i32)
  b.addHashy(2'i32)
  doAssert a != b, "addHashy collides on adjacent integers"
  var ordered, swapped = HashySeed
  ordered.addHashy(1'i32)
  ordered.addHashy(2'i32)
  swapped.addHashy(2'i32)
  swapped.addHashy(1'i32)
  doAssert ordered != swapped, "addHashy ignores ordering"

block factionAssignments:
  echo "Checking distinct and repeatable faction assignments"
  var seen: set[Faction]
  for seed in 1'i64 .. 100:
    let order = factionOrder(seed)
    doAssert order == factionOrder(seed)
    var assigned: set[Faction]
    for faction in order:
      doAssert faction notin assigned
      assigned.incl faction
    doAssert assigned == {Faction.low .. Faction.high}
    seen.incl order[PeterRiver]
  doAssert seen == {Faction.low .. Faction.high}

echo "test_lvd_content: all checks passed"
echo "  contentHash = ", toHex(contentHash())
