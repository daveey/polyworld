import polyworld/visions

echo "Testing fractional vision circles, source offsets and cached occlusion"
block:
  const Size = 31'i32
  var
    cache: VisionCache
    reference, cached: seq[uint8]
    terrain = newSeq[int16](Size * Size)
    blockers = newSeq[int16](Size * Size)
  for offset in [-2500'i32, 0'i32, 2500'i32]:
    let source = VisionSource(x: 15, z: 15, radius: 11, eyeHeight: 24,
      units: 10_000, range: 95_000, offsetX: offset)
    revealVision(reference, Size, Size, terrain, blockers, [source])
    revealVisionCached(cache, cached, Size, Size, terrain, blockers, [source])
    doAssert cached == reference
    doAssert cached[15 * Size + 24] == 255
    doAssert cached[15 * Size + 26] == 0
    doAssert (cached[15 * Size + 25] != 0) == (offset >= 0)
    doAssert (cached[15 * Size + 5] != 0) == (offset <= 0)
  blockers[15 * Size + 18] = 40
  let source = VisionSource(x: 15, z: 15, radius: 11, eyeHeight: 24,
    units: 10_000, range: 95_000)
  revealVision(reference, Size, Size, terrain, blockers, [source])
  revealVisionCached(cache, cached, Size, Size, terrain, blockers, [source])
  doAssert cached == reference
  doAssert cached[15 * Size + 24] == 0

echo "Testing cached vision against full rebuilds across world changes"
block:
  var
    cache: VisionCache
    reference, cached: seq[uint8]
    terrain = newSeq[int16](17 * 17)
    blockers = newSeq[int16](17 * 17)
  for frame in 0 ..< 128:
    if frame mod 7 == 0:
      blockers[(frame * 13) mod blockers.len] = int16(frame mod 32)
    if frame mod 11 == 0:
      terrain[(frame * 19) mod terrain.len] = int16(frame mod 41 - 20)
    var sources = @[
      VisionSource(x: 8, z: 8, radius: 8, eyeHeight: 14),
      VisionSource(x: int32(frame mod 17), z: 5, radius: 6, eyeHeight: 12)
    ]
    if frame mod 3 == 0:
      sources.add sources[0]
    if frame mod 5 == 0:
      sources.delete(0)
    if frame mod 17 == 0:
      sources.setLen(0)
    revealVision(reference, 17, 17, terrain, blockers, sources)
    revealVisionCached(cache, cached, 17, 17, terrain, blockers, sources)
    doAssert cached == reference, "cached vision diverged at frame " & $frame

const
  Width = 9'i32
  Height = 7'i32

var
  terrain = newSeq[int16](int(Width * Height))
  blockers = newSeq[int16](int(Width * Height))

echo "Testing integer line of sight range"
doAssert lineVisible(
  Width,
  Height,
  terrain,
  blockers,
  1,
  3,
  5,
  3,
  4
)
doAssert not lineVisible(
  Width,
  Height,
  terrain,
  blockers,
  1,
  3,
  6,
  3,
  4
)

echo "Testing tree and terrain occlusion"
blockers[3 * Width + 3] = 24
doAssert not lineVisible(
  Width,
  Height,
  terrain,
  blockers,
  1,
  3,
  5,
  3,
  8
)
blockers[3 * Width + 3] = 0
terrain[3 * Width + 3] = 20
doAssert not lineVisible(
  Width,
  Height,
  terrain,
  blockers,
  1,
  3,
  5,
  3,
  8
)

echo "Testing deterministic visibility maps"
terrain[3 * Width + 3] = 0
blockers[3 * Width + 3] = 24
var visible: seq[uint8]
revealVision(
  visible,
  Width,
  Height,
  terrain,
  blockers,
  [VisionSource(x: 1, z: 3, radius: 6, eyeHeight: 14)]
)
doAssert visible[3 * Width + 2] == 255
doAssert visible[3 * Width + 5] == 0
let softened = blurVisibility(visible, Width, Height)
doAssert softened.len == visible.len
doAssert softened[3 * Width + 2] > softened[3 * Width + 5]

echo "Testing the ray kernel matches live rounding"
block:
  proc roundAway(numerator, denominator: int64): int64 =
    ## Same half-away-from-zero rounding the kernel is built with.
    if numerator >= 0:
      (numerator + denominator div 2) div denominator
    else:
      -((-numerator + denominator div 2) div denominator)
  proc liveVisible(
      terrain, occluders: seq[int16], dx, dz: int32, eyeHeight: int16
  ): bool =
    ## Walks one ray with the original step formula.
    let steps = max(abs(dx), abs(dz))
    if steps <= 1:
      return true
    let
      sourceY = int64(terrain[8 * 17 + 8]) + int64(eyeHeight)
      targetY = int64(terrain[(8 + dz) * 17 + 8 + dx]) + 3
    for step in 1'i32 ..< steps:
      let
        x = 8'i32 + int32(roundAway(int64(dx) * int64(step), int64(steps)))
        z = 8'i32 + int32(roundAway(int64(dz) * int64(step), int64(steps)))
        rayHeight = sourceY + roundAway(
          (targetY - sourceY) * int64(step),
          int64(steps)
        )
        obstacle = int64(terrain[z * 17 + x]) + int64(occluders[z * 17 + x])
      if obstacle >= rayHeight:
        return false
    true
  var
    wideTerrain = newSeq[int16](17 * 17)
    wideBlockers = newSeq[int16](17 * 17)
  for fixture in 0 ..< 64:
    for index in 0 ..< wideTerrain.len:
      wideTerrain[index] = int16((index * 17 + fixture * 31) mod 65 - 32)
      wideBlockers[index] = int16((index * 7 + fixture * 11) mod 25)
    for eyeHeight in [-32'i16, -1, 0, 1, 14, 32]:
      for dz in -8'i32 .. 8'i32:
        for dx in -8'i32 .. 8'i32:
          if dx * dx + dz * dz > 64:
            continue
          let kernel = lineVisible(
            17, 17, wideTerrain, wideBlockers,
            8, 8, 8 + dx, 8 + dz, 8, eyeHeight
          )
          doAssert kernel == liveVisible(wideTerrain, wideBlockers, dx, dz, eyeHeight),
            "kernel ray " & $dx & "," & $dz & " diverged"

echo "Testing half-turn symmetry of kernel and long-range vision"
block:
  const
    Columns = 41
    Rows = 37
  var
    terrain = newSeq[int16](Columns * Rows)
    blockers = newSeq[int16](Columns * Rows)
    oppositeTerrain = newSeq[int16](Columns * Rows)
    oppositeBlockers = newSeq[int16](Columns * Rows)
    rays = 0
  for i in 0 ..< terrain.len:
    terrain[i] = int16((i * 17 + i div Columns) mod 31 - 15)
    blockers[i] = if i mod 13 == 0: 24 else: 0
    oppositeTerrain[terrain.high - i] = terrain[i]
    oppositeBlockers[terrain.high - i] = blockers[i]
  for sourceZ in countup(0, Rows - 1, 7):
    for sourceX in countup(0, Columns - 1, 7):
      for targetZ in 0 ..< Rows:
        for targetX in 0 ..< Columns:
          for eyeHeight in [3'i16, 14'i16, 28'i16]:
            let
              first = lineVisible(
                Columns, Rows, terrain, blockers,
                sourceX.int32, sourceZ.int32,
                targetX.int32, targetZ.int32, 50, eyeHeight
              )
              second = lineVisible(
                Columns, Rows, oppositeTerrain, oppositeBlockers,
                (Columns - 1 - sourceX).int32,
                (Rows - 1 - sourceZ).int32,
                (Columns - 1 - targetX).int32,
                (Rows - 1 - targetZ).int32, 50, eyeHeight
              )
            doAssert first == second
            inc rays
  echo "Mirrored visibility rays checked: ", rays
