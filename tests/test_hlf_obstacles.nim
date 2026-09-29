import
  std/strformat,
  fixxy,
  ../examples/heartleaf/[content, layouts, maps, obstacles, sim]

proc bodyPoint(x, z: int32): FixedVec2 =
  ## Converts town thousandths to the simulation's tile coordinates.
  fixedVec2(
    fixed(GridSide div 2) + 0.5'fx +
      Fixed(int32(x.int64 * FixedScale div 1000)),
    fixed(GridSide div 2) + 0.5'fx +
      Fixed(int32(z.int64 * FixedScale div 1000))
  )

proc center(tile: Tile2): FixedVec2 =
  ## Returns the exact center used by movement orders.
  fixedVec2(fixed(tile.x.int32) + 0.5'fx, fixed(tile.y.int32) + 0.5'fx)

let map = generateMap(DefaultSeed)

echo "Testing all rendered ground plants and fences are solid"
block:
  let world = newWorld(map, 1)
  for plant in groundPlants(map.seed):
    doAssert not world.positionOpen(bodyPoint(plant.x, plant.z))
  var kinds: set[ObstacleKind]
  for obstacle in map.obstacles:
    kinds.incl obstacle.kind
    doAssert not world.positionOpen(bodyPoint(
      (obstacle.ax + obstacle.bx) div 2,
      (obstacle.az + obstacle.bz) div 2
    ))
  doAssert kinds == {TreeObstacle, BushObstacle, FenceObstacle}

echo "Testing narrow rails, endpoint clearance, and angled crossings"
block:
  let rail = Obstacle(
    kind: FenceObstacle, ax: -900, az: -700,
    bx: 900, bz: 700, radius: 90
  )
  doAssert not rail.obstacleClear(-1000, 1000, 1000, -1000)
  doAssert not rail.obstacleClear(-900, -700, -900, -700)
  doAssert not rail.obstacleClear(1050, 700, 1050, 700)
  doAssert rail.obstacleClear(1300, 1000, 2000, 1000)
  doAssert rail.obstacleClear(-2000, -1600, -2000, 1600)

echo "Testing the southern plaza gate follows the stepping-stone path"
block:
  let world = newWorld(map, 1)
  doAssert world.travelClear(bodyPoint(-1500, 6200), bodyPoint(-1500, 9000)),
    "The central tree fence or planting crosses its entrance path"

echo "Testing the right-hand gates clear their painted stone approaches"
block:
  let world = newWorld(map, 1)
  for path in [(797, 350, 758, 386), (837, 904, 793, 938)]:
    let
      first = bodyPoint(int32((path[0] - 560) * 44 - 500),
        int32((path[1] - 650) * 57 - 500))
      last = bodyPoint(int32((path[2] - 560) * 44 - 500),
        int32((path[3] - 650) * 57 - 500))
    doAssert world.travelClear(first, last),
      "A right-hand garden blocks its painted stepping-stone approach"

echo "Testing every house and garden remains reachable without collisions"
var destinations: seq[Tile2]
for house in map.houses:
  destinations.add house.door
for garden in map.gardenTiles:
  destinations.add garden
for destination in destinations:
  let
    world = newWorld(map, 1)
    villager = world.villagers[0]
    start = tile2(68, 64)
  for i in 1 ..< VillagerCount:
    world.villagers[i].inHouse = i.int32
  villager.tile = start
  villager.fromTile = start
  villager.body.pos = center(start)
  doAssert world.applyMove(0, destination.x.int32, destination.y.int32)
  for tick in 0 ..< 2000:
    let previous = villager.body.pos
    world.tickWorld(nil)
    doAssert world.positionOpen(villager.body.pos),
      &"Entered a prop while walking to {destination} at {villager.body.pos}"
    doAssert world.travelClear(previous, villager.body.pos),
      &"Crossed a fence while walking to {destination}"
    if villager.order == NoOrder:
      break
  doAssert length(villager.body.pos - center(destination)) <= 0.36'fx,
    &"Could not reach {destination}; stopped at {villager.body.pos}"

echo "Testing a new route starts on the correct side of a fence"
block:
  let
    world = newWorld(generateMap(1), 1)
    villager = world.villagers[0]
  for i in 1 ..< VillagerCount:
    world.villagers[i].inHouse = i.int32
  villager.tile = tile2(69, 57)
  villager.body.pos = fixedVec2(69.51443'fx, 57.16029'fx)
  let destination = world.map.houses[2].door
  doAssert world.positionOpen(villager.body.pos)
  doAssert world.applyMove(0, destination.x.int32, destination.y.int32)
  for tick in 0 ..< 1000:
    let previous = villager.body.pos
    world.tickWorld(nil)
    doAssert world.travelClear(previous, villager.body.pos)
    if villager.order == NoOrder:
      break
  doAssert length(villager.body.pos - center(destination)) <= 0.36'fx

echo "test_hlf_obstacles: all checks passed"
