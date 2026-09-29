import
  std/math,
  vmath,
  polyworld/rngs

const
  TownHouses* = [
    (0, -26), (-13, -22), (13, -20), (-16, -7), (14, -5),
    (-18, 10), (15, 12), (-10, 31), (9, 30)
  ]
  HousePixels* = [
    (562, 196), (271, 278), (864, 315), (202, 533), (892, 568),
    (153, 830), (912, 861), (347, 1200), (771, 1184)
  ]
  HouseScale* = 0.85'f
  HouseMeshScale* = 1.95'f * HouseScale
  HouseMeshOffset* = vec3(0, 0.06, 0) * HouseMeshScale
  HouseHillRadius* = 3.88'f * HouseMeshScale
  HouseHillCenterZ* = -1.4'f * HouseMeshScale
  HouseTurns* = [
    (996, -87), (883, -469), (883, 469), (848, -530), (829, 559),
    (788, -616), (788, 616), (819, -574), (875, 485)
  ]
  YardTurns* = [
    (996, -87), (829, -559), (629, 777), (777, -629), (829, 559),
    (515, -857), (616, 788), (819, -574), (875, 485)
  ]
  HouseGardenOffsets* = [
    (-3'i32, 2'i32), (3'i32, 2'i32), (-2'i32, 4'i32)
  ]
  TownMinX* = -24'i32
  TownMaxX* = 24'i32
  TownMinZ* = -39'i32
  TownMaxZ* = 44'i32
  BorderTreeCount* = 24
  BorderTreeVariants* = [0, 1, 2, 7, 8, 9, 10, 11, 12]
  TownPlaza* = vec2(0, 0)
  TownWell* = vec2(1.26, 14.83)
  TownIsland* = vec2(1.35, -15.1)
  TownOrchard* = vec2(-8.1, 13.4)
  TownPlazaRadius* = 6.0'f
  TownLayoutScale* = 0.75'f
  TownOverviewDistance* = 94.0'f
  TownCameraTarget* = vec3(0.044, 0, 2.907)
  TownCameraPitch* = 0.88'f
  TownCameraScale* = 0.41421356'f

type
  RoadPoint* = object
    x*, z*, width*: int32
  BorderTree* = object
    x*, z*: int32
    variant*: int
    yaw*, size*, height*: float32
  MeadowSpot* = object
    x*, z*: int32
    key*: int
  GroundPlant* = object
    x*, z*, radius*: int32
    variant*: int
    yaw*, size*, height*: float32
  GardenFence* = object
    x*, z*, ax*, az*, bx*, bz*, radius*: int32
    yaw*, size*: float32

proc referenceRoad(x, y, width: int32): RoadPoint =
  ## Converts traced reference pixels to fixed thousandths of a town tile.
  RoadPoint(x: (x - 560) * 44, z: (y - 650) * 57,
    width: width * 87 div 100)

const
  TownPaths* = [
    @[referenceRoad(348, 135, 600), referenceRoad(344, 157, 700),
      referenceRoad(373, 204, 680), referenceRoad(390, 245, 730),
      referenceRoad(422, 278, 800), referenceRoad(470, 303, 760),
      referenceRoad(512, 312, 850), referenceRoad(554, 298, 780)],
    @[referenceRoad(554, 298, 780), referenceRoad(540, 329, 920),
      referenceRoad(517, 354, 820), referenceRoad(503, 384, 960),
      referenceRoad(475, 413, 1050), referenceRoad(433, 435, 1100)],
    @[referenceRoad(709, 216, 650), referenceRoad(722, 251, 730),
      referenceRoad(705, 281, 810), referenceRoad(680, 317, 700),
      referenceRoad(674, 350, 780), referenceRoad(687, 389, 830),
      referenceRoad(681, 420, 950), referenceRoad(657, 458, 1150)],
    @[referenceRoad(433, 435, 1100), referenceRoad(474, 448, 1200),
      referenceRoad(514, 470, 1050), referenceRoad(555, 485, 900),
      referenceRoad(604, 476, 950), referenceRoad(657, 458, 1150)],
    @[referenceRoad(326, 342, 700), referenceRoad(350, 376, 830),
      referenceRoad(384, 396, 700), referenceRoad(405, 417, 900),
      referenceRoad(433, 435, 1100)],
    @[referenceRoad(657, 458, 1150), referenceRoad(697, 429, 850),
      referenceRoad(730, 399, 740), referenceRoad(767, 379, 650)],
    @[referenceRoad(433, 435, 1100), referenceRoad(410, 463, 1030),
      referenceRoad(394, 498, 850), referenceRoad(366, 540, 950),
      referenceRoad(351, 579, 900), referenceRoad(337, 622, 780),
      referenceRoad(344, 668, 900), referenceRoad(349, 703, 750),
      referenceRoad(365, 739, 880), referenceRoad(384, 780, 1100)],
    @[referenceRoad(657, 458, 1150), referenceRoad(702, 490, 900),
      referenceRoad(729, 528, 800), referenceRoad(746, 561, 900),
      referenceRoad(742, 603, 820), referenceRoad(758, 643, 1100),
      referenceRoad(749, 685, 900), referenceRoad(733, 719, 780),
      referenceRoad(722, 758, 950), referenceRoad(701, 790, 1000)],
    @[referenceRoad(287, 590, 700), referenceRoad(312, 610, 830),
      referenceRoad(337, 622, 780)],
    @[referenceRoad(841, 628, 700), referenceRoad(802, 652, 820),
      referenceRoad(758, 643, 1100)],
    @[referenceRoad(384, 780, 1100), referenceRoad(423, 801, 880),
      referenceRoad(465, 814, 930), referenceRoad(502, 810, 850),
      referenceRoad(552, 824, 1100), referenceRoad(597, 815, 920),
      referenceRoad(649, 811, 780), referenceRoad(701, 790, 1000)],
    @[referenceRoad(384, 780, 1100), referenceRoad(355, 819, 950),
      referenceRoad(327, 851, 730), referenceRoad(301, 895, 900),
      referenceRoad(278, 930, 800), referenceRoad(267, 969, 750),
      referenceRoad(284, 1008, 920), referenceRoad(330, 1039, 1050),
      referenceRoad(376, 1046, 800), referenceRoad(420, 1038, 920),
      referenceRoad(473, 1047, 1050), referenceRoad(536, 1029, 1100)],
    @[referenceRoad(552, 824, 1100), referenceRoad(527, 850, 900),
      referenceRoad(513, 892, 780), referenceRoad(501, 925, 900),
      referenceRoad(504, 967, 770), referenceRoad(521, 1001, 950),
      referenceRoad(536, 1029, 1100)],
    @[referenceRoad(701, 790, 1000), referenceRoad(692, 829, 950),
      referenceRoad(703, 873, 780), referenceRoad(699, 906, 850),
      referenceRoad(721, 946, 1050), referenceRoad(715, 980, 780),
      referenceRoad(681, 1015, 870), referenceRoad(631, 1037, 940),
      referenceRoad(587, 1044, 1020), referenceRoad(536, 1029, 1100)],
    @[referenceRoad(243, 909, 670), referenceRoad(269, 921, 760),
      referenceRoad(301, 895, 900)],
    @[referenceRoad(825, 960, 690), referenceRoad(790, 970, 850),
      referenceRoad(757, 954, 720), referenceRoad(721, 946, 1050)],
    @[referenceRoad(536, 1029, 1100), referenceRoad(557, 1064, 900),
      referenceRoad(574, 1095, 780), referenceRoad(577, 1129, 850),
      referenceRoad(562, 1168, 1050), referenceRoad(555, 1209, 820),
      referenceRoad(539, 1248, 950), referenceRoad(517, 1281, 1150),
      referenceRoad(483, 1316, 900), referenceRoad(439, 1341, 760),
      referenceRoad(422, 1378, 900), referenceRoad(411, 1405, 750)],
    @[referenceRoad(412, 1262, 670), referenceRoad(450, 1282, 800),
      referenceRoad(482, 1285, 850), referenceRoad(517, 1281, 1150)],
    @[referenceRoad(723, 1275, 680), referenceRoad(690, 1301, 850),
      referenceRoad(650, 1308, 780), referenceRoad(611, 1297, 900),
      referenceRoad(576, 1276, 800), referenceRoad(539, 1248, 950)]
  ]
  HouseApproaches = [
    referenceRoad(554, 298, 780), referenceRoad(326, 342, 700),
    referenceRoad(767, 379, 650), referenceRoad(287, 590, 700),
    referenceRoad(841, 628, 700), referenceRoad(243, 909, 670),
    referenceRoad(825, 960, 690), referenceRoad(412, 1262, 670),
    referenceRoad(723, 1275, 680)
  ]

proc insideTown*(x, z: int32): bool =
  ## Clips the playable meadow to a rounded rectangle around the town.
  let
    cornerX = max(0'i32, abs(x) - 18)
    cornerZ = max(0'i32, abs(z - 3) - 36)
  x >= TownMinX and x <= TownMaxX and
    z >= TownMinZ and z <= TownMaxZ and
    cornerX * cornerX + cornerZ * cornerZ <= 36

proc houseAnchor*(slot: int): tuple[x, z: int32] =
  ## Registers each doorway base against the supplied buildings layer.
  let pixel = HousePixels[slot]
  (int32((pixel[0] - 560) * 44 - 500),
    int32((pixel[1] - 650) * 57 - 500))

proc houseYaw*(slot: int): float32 =
  ## Turns each cottage facade inward by its reference image angle.
  arctan2(HouseTurns[slot][1].float32, HouseTurns[slot][0].float32)

proc yardTurn*(slot: int, z: int32): tuple[cosine, sine: int32] =
  ## Bends the garden toward its path while keeping its roots at the facade.
  let
    along = clamp(z, 0'i32, 5000'i32)
    house = HouseTurns[slot]
    yard = YardTurns[slot]
  (
    int32(house[0] + (yard[0] - house[0]) * along div 5000),
    int32(house[1] + (yard[1] - house[1]) * along div 5000)
  )

proc yardPoint*(slot: int, x, z: int32): tuple[x, z: int32] =
  ## Shares the garden's bent centerlines between geometry and collision.
  let turn = yardTurn(slot, z)
  ((turn.cosine * x - turn.sine * z) div 1000,
    (turn.sine * x + turn.cosine * z) div 1000)

proc houseOffset*(slot: int, x, z: int32): tuple[x, z: int32] =
  ## Rotates tile offsets with fixed point arithmetic for portable replays.
  let
    turn = HouseTurns[slot]
    px = turn[0].int32 * x - turn[1].int32 * z
    pz = turn[1].int32 * x + turn[0].int32 * z
  proc rounded(value: int32): int32 =
    ## Rounds signed thousandths to the closest tile.
    if value < 0:
      -((-value + 500) div 1000)
    else:
      (value + 500) div 1000
  (rounded(px), rounded(pz))

proc gardenOffset*(slot: int, x, z: int32): tuple[x, z: int32] =
  ## Keeps planter tiles beside the bent yard's central approach.
  let
    side = if slot in [2, 6] and x == -2 and z == 4: 2'i32 else: x
    point = yardPoint(slot, side * 1000, z * 1000)
  proc rounded(value: int32): int32 =
    ## Rounds signed thousandths to the nearest simulation tile.
    if value < 0:
      -((-value + 500) div 1000)
    else:
      (value + 500) div 1000
  (rounded(point.x), rounded(point.z))

iterator roadSegments(): tuple[a, b: RoadPoint] =
  ## Shares independently traced lanes and oblique cottage approaches.
  for path in TownPaths:
    for i in 1 ..< path.len:
      let
        first = path[max(0, i - 2)]
        a = path[i - 1]
        b = path[i]
        last = path[min(path.high, i + 1)]
      var previous = a
      for step in 1 .. 4:
        proc curve(p, q, r, t: int32): int32 =
          ## Samples a Catmull-Rom arc with integer arithmetic for replays.
          let k = step.int64
          int32((2 * q.int64 * 64 + (-p + r).int64 * k * 16 +
            (2 * p - 5 * q + 4 * r - t).int64 * k * k * 4 +
            (-p + 3 * q - 3 * r + t).int64 * k * k * k) div 128)
        let current = RoadPoint(
          x: curve(first.x, a.x, b.x, last.x),
          z: curve(first.z, a.z, b.z, last.z),
          width: a.width + (b.width - a.width) * step.int32 div 4
        )
        yield (previous, current)
        previous = current
  for slot, house in TownHouses:
    let
      offset = houseOffset(slot, 0, 2)
      anchor = houseAnchor(slot)
      entrance = yardPoint(slot, 0, 6000)
      gate = RoadPoint(
        x: anchor.x + entrance.x,
        z: anchor.z + entrance.z,
        width: 850
      )
    yield (RoadPoint(
      x: (house[0].int32 + offset.x) * 1000,
      z: (house[1].int32 + offset.z) * 1000,
      width: 850
    ), gate)
    yield (gate, HouseApproaches[slot])

proc roadClearance*(x, z: float32): float32 =
  ## Measures signed distance from the varying width of the traced lanes.
  result = float32.high
  let point = vec2(x, z)
  for (first, last) in roadSegments():
    let
      a = vec2(first.x.float32, first.z.float32) / 1000
      b = vec2(last.x.float32, last.z.float32) / 1000
      line = b - a
      along = clamp(dot(point - a, line) / dot(line, line), 0'f, 1'f)
      width = (first.width.float32 * (1 - along) +
        last.width.float32 * along) / 1000
    result = min(result, length(point - (a + line * along)) - width)

proc roadContains(x, z, padding: int32): bool =
  ## Tests a point in thousandths against the lanes with extra clearance.
  for (first, last) in roadSegments():
    let
      dx = (last.x - first.x).int64
      dz = (last.z - first.z).int64
      px = x.int64 - first.x
      pz = z.int64 - first.z
      span = dx * dx + dz * dz
      along = clamp(px * dx + pz * dz, 0'i64, span)
      width = first.width.int64 +
        (last.width - first.width).int64 * along div span + padding
      radiusSquared = width * width
    if along == 0:
      if px * px + pz * pz <= radiusSquared:
        return true
    elif along == span:
      let
        ex = px - dx
        ez = pz - dz
      if ex * ex + ez * ez <= radiusSquared:
        return true
    else:
      let cross = px * dz - pz * dx
      if cross * cross <= radiusSquared * span:
        return true

proc townRoad*(x, z: int32): bool =
  ## Rasterizes the same lanes with fixed point math for portable replays.
  roadContains(x * 1000, z * 1000, 450)

proc meadowSpots*(seed: int32): seq[MeadowSpot] =
  ## Shares deterministic ground planting between art and collision geometry.
  for iz in -22 .. 24:
    for ix in -16 .. 16:
      let
        key = abs(ix * 2999 + iz * 7919 + seed.int)
        x = int64(ix * 2000 + key mod 1001 - 500)
        z = int64(iz * 2000 + (key div 7) mod 1001 - 500)
      if not insideTown(int32(x div 1000), int32(z div 1000)) or
        roadContains(x.int32, z.int32, 1000) or
        x * x + z * z < 49_000_000 or
        (x - 2000) * (x - 2000) +
          (z - 15000) * (z - 15000) < 12_250_000 or
        (x - 2000) * (x - 2000) +
          (z + 13000) * (z + 13000) < 9_000_000:
          continue
      var nearHouse = false
      for slot, house in TownHouses:
        let
          turn = HouseTurns[slot]
          dx = x.int64 - house[0] * 1000
          dz = z.int64 - house[1] * 1000
          localX = (dx * turn[0] + dz * turn[1]) div 1000
          localZ = (-dx * turn[1] + dz * turn[0]) div 1000
          rear = localZ - int64(HouseHillCenterZ * 1000)
        if localX * localX + rear * rear < 49_000_000 or
          (abs(localX) < 5000 and localZ > 0 and localZ < 5700):
          nearHouse = true
        for local in HouseGardenOffsets:
          let
            offset = gardenOffset(slot, local[0], local[1])
            gx = x - (house[0] + offset.x) * 1000
            gz = z - (house[1] + offset.z) * 1000
          if gx * gx + gz * gz < 2_560_000:
            nearHouse = true
      if not nearHouse:
        result.add MeadowSpot(x: x.int32, z: z.int32, key: key)

proc referencePoint*(x, y: float32): Vec2 =
  ## Maps reference pixels to town coordinates before the tile-center offset.
  vec2((x - 560) * 0.044'f - 0.5'f, (y - 650) * 0.057'f - 0.5'f)

proc borderTrees*(seed: int32): seq[BorderTree] =
  ## Follows the reference's irregular cropped forest groups with varied crowns.
  const Anchors = [
    (70, 130), (214, 94), (337, 18), (772, 54), (889, 119), (1016, 166),
    (-16, 260), (25, 416), (-28, 706), (22, 1133), (4, 1303), (146, 1395),
    (257, 1452), (1120, 443), (1105, 696), (1070, 995), (1102, 1232),
    (1030, 1400), (80, -30), (1054, -25), (-30, 945), (1105, 860),
    (25, 1490), (1137, 1460)
  ]
  var rng = initRng(seed, 0xD1B54A32D192ED03'u64)
  for i, anchor in Anchors:
    let position = referencePoint(anchor[0].float32, anchor[1].float32)
    result.add BorderTree(
      x: int32(round(position.x)), z: int32(round(position.y)),
      variant: BorderTreeVariants[i mod BorderTreeVariants.len],
      yaw: rng.below(6284).float32 / 1000,
      size: rng.between(100, 135).float32 / 100,
      height: rng.between(85, 118).float32 / 100
    )

proc groundPlants*(seed: int32): seq[GroundPlant] =
  ## Places trunks and low crowns once for both rendering and navigation.
  var plants: seq[GroundPlant]
  proc plantAt(x, y: float32, variant: int, size, height: float32,
      radius: int32, yaw = 0'f) =
    ## Stores a traced plant once for both collision and presentation.
    let position = referencePoint(x, y)
    plants.add GroundPlant(
      x: int32(round(position.x * 1000)),
      z: int32(round(position.y * 1000)), radius: radius,
      variant: variant, yaw: yaw, size: size, height: height
    )
  plantAt(548, 651, 6, 1.12'f, 1.05'f, 1500)
  plantAt(411, 366, 1, 0.53'f, 1, 400)
  plantAt(397, 891, 0, 0.58'f, 1, 400)
  plantAt(345, 954, 2, 0.52'f, 1, 400)
  plantAt(211, 1048, 1, 0.60'f, 1, 450)
  plantAt(806, 762, 0, 0.48'f, 1, 380)
  for tree in borderTrees(seed):
    plants.add GroundPlant(
      x: tree.x * 1000, z: tree.z * 1000, radius: 500,
      variant: tree.variant, yaw: tree.yaw,
      size: tree.size, height: tree.height
    )
  const Borders = [
    @[(130, 220), (110, 278), (147, 321), (176, 348)],
    @[(320, 175), (373, 245), (387, 278)],
    @[(507, 31), (546, 39)],
    @[(634, 58), (685, 89), (725, 146), (708, 182), (645, 229), (621, 272)],
    @[(926, 207), (966, 261), (989, 312)],
    @[(729, 321), (758, 354)],
    @[(1002, 357), (948, 401)],
    @[(510, 222), (526, 263)],
    @[(506, 321), (499, 350)],
    @[(594, 353), (569, 411), (616, 427), (649, 414)],
    @[(285, 395), (341, 435), (365, 454)],
    @[(298, 471), (304, 513), (335, 548)],
    @[(433, 494), (437, 520)],
    @[(811, 435), (739, 480), (789, 524), (826, 567)],
    @[(45, 527), (51, 579), (113, 613), (203, 625)],
    @[(941, 613), (996, 606), (1029, 582)],
    @[(390, 613), (385, 656), (394, 692)],
    @[(699, 608), (715, 672), (697, 721), (656, 753), (603, 780)],
    @[(433, 750), (466, 764), (503, 782)],
    @[(231, 682), (280, 723), (287, 758), (325, 796)],
    @[(788, 737), (766, 786), (741, 823)],
    @[(19, 818), (59, 859), (90, 911), (137, 935)],
    @[(684, 907), (645, 949), (608, 977)],
    @[(871, 932), (911, 969)],
    @[(306, 944), (311, 977)],
    @[(399, 1008), (457, 994)],
    @[(788, 1000), (771, 1031), (682, 1076)],
    @[(432, 1061), (477, 1098), (515, 1131)],
    @[(872, 1064), (904, 1109), (935, 1155)],
    @[(265, 1054), (217, 1107), (182, 1170), (193, 1248), (245, 1296), (370, 1314)],
    @[(621, 1180), (629, 1232), (654, 1271)],
    @[(925, 1220), (897, 1288), (830, 1311), (758, 1310)],
    @[(489, 1354), (545, 1374), (628, 1393)],
    @[(91, 1341), (166, 1386), (239, 1400)],
    @[(751, 1393), (849, 1392), (964, 1399)]
  ]
  for key, chain in Borders:
    for i in 1 ..< chain.len:
      let
        first = vec2(chain[i - 1][0].float32, chain[i - 1][1].float32)
        last = vec2(chain[i][0].float32, chain[i][1].float32)
        count = max(1, int(ceil(length(last - first) / 23)))
      for j in 0 ..< count:
        let
          position = mix(first, last, j.float32 / count.float32)
          variation = (key * 13 + i * 7 + j * 3) mod 9
          size = 0.93'f + variation.float32 * 0.035'f
        plantAt(position.x, position.y, 3 + (key + j) mod 3,
          size, 0.83'f + variation.float32 * 0.025'f,
          int32(size * 850), key.float32 + j.float32 * 2.4'f)
  for i in 0 ..< 10:
    let
      angle = i.float32 * 2.399963'f
      radius = sqrt((i.float32 + 0.5'f) / 10) * 37
    plantAt(602 + cos(angle) * radius, 403 + sin(angle) * radius,
      3 + i mod 3, 1.05'f, 0.9'f, 890, angle)
  result = plants
  var kept = 0
  for plant in result:
    var clear = true
    for slot, house in TownHouses:
      let
        anchor = houseAnchor(slot)
        dx = plant.x.int64 - anchor.x
        dz = plant.z.int64 - anchor.z
        turn = HouseTurns[slot]
        localX = (dx * turn[0] + dz * turn[1]) div 1000
        localZ = (-dx * turn[1] + dz * turn[0]) div 1000
      if abs(localX) < plant.radius + 1000 and
        localZ > 0 and localZ < 7400:
          clear = false
      for local in HouseGardenOffsets:
        let
          offset = gardenOffset(slot, local[0], local[1])
          gx = dx - offset.x * 1000
          gz = dz - offset.z * 1000
          radius = plant.radius.int64 + 800
        if gx * gx + gz * gz < radius * radius:
          clear = false
    if clear:
      result[kept] = plant
      inc kept
  result.setLen(kept)

proc makeGardenFences(): seq[GardenFence] =
  ## Builds the same tangent rails as the mesh, leaving both gate openings.
  for ring in [(TownWell.x, TownWell.y, 3'f, 12), (0'f, 0'f, 7.5'f, 28)]:
    for i in 0 ..< ring[3]:
      let baseAngle = i.float32 * 2'f * PI.float32 / ring[3].float32
      if abs(cos(baseAngle)) < 0.22'f:
        continue
      let
        angle = baseAngle + (if ring[3] == 28: 0.20'f else: 0'f)
        x = ring[0] + cos(angle) * ring[2]
        z = ring[1] + sin(angle) * ring[2]
        half = ring[2] * PI.float32 / ring[3].float32
        dx = -sin(angle) * half
        dz = cos(angle) * half
      result.add GardenFence(
        x: int32(round(x * 1000)), z: int32(round(z * 1000)),
        ax: int32(round((x - dx) * 1000)),
        az: int32(round((z - dz) * 1000)),
        bx: int32(round((x + dx) * 1000)),
        bz: int32(round((z + dz) * 1000)),
        radius: int32(round(half / 0.9'f * 145)),
        yaw: angle + PI.float32 / 2, size: half / 0.9'f
      )

const GardenFences* = makeGardenFences()

proc townCameraBounds*(
  target: Vec3, distance, aspect: float32
): tuple[minimum, maximum: Vec2] =
  ## Computes the orthographic camera footprint on level village ground.
  let
    extent = vec2(
      distance * TownCameraScale * aspect,
      distance * TownCameraScale / sin(TownCameraPitch)
    )
    center = vec2(target.x, target.z - target.y / tan(TownCameraPitch))
  (center - extent, center + extent)
