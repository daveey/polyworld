import
  vmath,
  layouts

const
  ObstacleUnits* = 1000'i32
  VillagerClearance* = 220'i32
  NavigationClearance* = VillagerClearance + 2

type
  ObstacleKind* = enum
    TreeObstacle, BushObstacle, FenceObstacle
  Obstacle* = object
    kind*: ObstacleKind
    ax*, az*, bx*, bz*, radius*: int32

proc villageObstacles*(seed: int32): seq[Obstacle] =
  ## Shares ground plants and fence geometry in fixed thousandths of a tile.
  for plant in groundPlants(seed):
    result.add Obstacle(
      kind:
        if plant.variant in 3 .. 5: BushObstacle
        else: TreeObstacle,
      ax: plant.x, az: plant.z, bx: plant.x, bz: plant.z,
      radius: plant.radius
    )
  for fence in GardenFences:
    result.add Obstacle(
      kind: FenceObstacle,
      ax: fence.ax, az: fence.az, bx: fence.bx, bz: fence.bz,
      radius: fence.radius
    )
  # The extracted yard rails retain their original curved centerlines.
  const FencePoints = [
    (2560, 45), (2640, 820), (2260, 1610), (1550, 2130), (720, 2360)
  ]
  for slot, house in TownHouses:
    let anchor = houseAnchor(slot)
    proc transform(x, z: int): tuple[x, z: int32] =
      ## Applies the cottage mesh scale, offset, and signed yaw to its rails.
      let
        scale = int(HouseMeshScale * 1000)
        front = max(0, z - 220)
        spread = 1000 + 150 * min(front, 580) div 580
        px = x * spread div 1000 * scale div 1000
        pz = (z + front * 4 div 10) * scale div 1000 +
          int(HouseMeshOffset.z * 1000)
        rotated = yardPoint(slot, px.int32, pz.int32)
      (
        anchor.x + rotated.x,
        anchor.z + rotated.z
      )
    for side in [-1, 1]:
      var points: seq[tuple[x, z: int32]]
      for i in 0 ..< FencePoints.len - 1:
        let
          a = FencePoints[i]
          b = FencePoints[i + 1]
          previous = FencePoints[max(0, i - 1)]
          following = FencePoints[min(FencePoints.high, i + 2)]
          mx = (-previous[0] + 9 * a[0] + 9 * b[0] - following[0]) div 16
          mz = (-previous[1] + 9 * a[1] + 9 * b[1] - following[1]) div 16
        points.add transform(side * a[0], a[1])
        points.add transform(side * mx, mz)
      points.add transform(side * FencePoints[^1][0], FencePoints[^1][1])
      for i in 1 ..< points.len:
        result.add Obstacle(
          kind: FenceObstacle,
          ax: points[i - 1].x, az: points[i - 1].z,
          bx: points[i].x, bz: points[i].z,
          radius: int32(150 * HouseMeshScale)
        )

proc nearSegment(
  x, z, ax, az, bx, bz: int64, radius: int32
): bool =
  ## Tests capsule clearance exactly, including points beside short segments.
  let
    dx = bx - ax
    dz = bz - az
    span = dx * dx + dz * dz
    along = (x - ax) * dx + (z - az) * dz
    radiusSquared = radius.int64 * radius
  if along <= 0:
    return (x - ax) * (x - ax) + (z - az) * (z - az) <= radiusSquared
  if along >= span:
    return (x - bx) * (x - bx) + (z - bz) * (z - bz) <= radiusSquared
  let cross = abs((x - ax) * dz - (z - az) * dx)
  if cross > radius.int64 * (abs(dx) + abs(dz)):
    return false
  cross * cross <= radiusSquared * span

proc obstacleClear*(
  obstacle: Obstacle, ax, az, bx, bz: int32,
  clearance = VillagerClearance
): bool =
  ## Checks a swept circle against one trunk, crown, or fence capsule.
  let radius = obstacle.radius + clearance
  if max(ax, bx) < min(obstacle.ax, obstacle.bx) - radius or
    min(ax, bx) > max(obstacle.ax, obstacle.bx) + radius or
    max(az, bz) < min(obstacle.az, obstacle.bz) - radius or
    min(az, bz) > max(obstacle.az, obstacle.bz) + radius:
      return true
  if nearSegment(ax, az, obstacle.ax, obstacle.az,
      obstacle.bx, obstacle.bz, radius) or
    nearSegment(bx, bz, obstacle.ax, obstacle.az,
      obstacle.bx, obstacle.bz, radius) or
    nearSegment(obstacle.ax, obstacle.az, ax, az, bx, bz, radius) or
    nearSegment(obstacle.bx, obstacle.bz, ax, az, bx, bz, radius):
      return false
  proc side(x, z, px, pz, qx, qz: int32): int64 =
    ## Returns the signed side of an integer line.
    (qx.int64 - px) * (z.int64 - pz) -
      (qz.int64 - pz) * (x.int64 - px)
  let
    first = cmp(side(ax, az, obstacle.ax, obstacle.az,
      obstacle.bx, obstacle.bz), 0)
    last = cmp(side(bx, bz, obstacle.ax, obstacle.az,
      obstacle.bx, obstacle.bz), 0)
    left = cmp(side(obstacle.ax, obstacle.az, ax, az, bx, bz), 0)
    right = cmp(side(obstacle.bx, obstacle.bz, ax, az, bx, bz), 0)
  not (first * last < 0 and left * right < 0)

proc obstaclesClear*(
  obstacles: openArray[Obstacle], ax, az, bx, bz: int32,
  clearance = VillagerClearance
): bool =
  ## Requires every solid prop to clear the entire movement segment.
  for obstacle in obstacles:
    if not obstacle.obstacleClear(ax, az, bx, bz, clearance):
      return false
  true
