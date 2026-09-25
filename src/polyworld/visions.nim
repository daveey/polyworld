## Deterministic integer line of sight over a flat tile grid.
##
## Tile steps along each ray are a precomputed kernel. Height along the
## ray still uses the same integer lerp so visibility matches the live
## formula.

import std/[hashes, tables]

const
  MaxVisionRadius* = 16
    ## Largest sight radius the kernel stores. Forts use 14.
  VisionKernelSide = MaxVisionRadius * 2 + 1
  VisionKernelCells = VisionKernelSide * VisionKernelSide

type
  VisionSource* = object
    ## Describes one observer and its circular sight range in tiles.
    x*, z*: int32
    radius*: int32
    eyeHeight*: int16
    units*, range*, offsetX*, offsetZ*: int32
      ## Optional exact circle in sub-tile units, relative to the source center.
  VisionRayStep = object
    ox, oz: int8
  VisionOffset* = object
    ## One tile in a precomputed sight circle, relative to the observer.
    dx*, dz*: int8
  VisionCache* = object
    width, height: int32
    terrain, blockers: seq[int16]
    sources: Table[VisionSource, seq[int32]]
  TalliedSource = object
    cells: seq[int32]
    frame: int64
  VisionTally* = object
    ## Incremental twin of VisionCache: per-cell counts of the distinct live
    ## sources that see each cell, so a frame only touches the cells of
    ## sources that appeared or disappeared.
    width, height: int32
    terrain, blockers: seq[int16]
    counts: seq[uint16]
    sources: Table[VisionSource, TalliedSource]
    spare: Table[VisionSource, seq[int32]]
      ## Cells of recently vanished sources (same terrain and blockers), so a
      ## unit re-entering a tile, or the next creep wave on the same lane,
      ## skips the ray walk.
    frame: int64
    changed, stale: seq[int32]
    gone: seq[VisionSource]

proc hash*(source: VisionSource): Hash =
  ## Cheap multiplicative mix of every field (the vision tables only need
  ## equal sources to hash equally; iteration order does not reach results).
  template mix(value: uint64): uint64 =
    (value xor (value shr 29)) * 0xBF58476D1CE4E5B9'u64
  let
    a = (uint64(cast[uint32](source.x)) shl 32) or uint64(cast[uint32](source.z))
    b = (uint64(cast[uint32](source.radius)) shl 32) or
      uint64(cast[uint16](source.eyeHeight))
    c = (uint64(cast[uint32](source.units)) shl 32) or
      uint64(cast[uint32](source.range))
    d = (uint64(cast[uint32](source.offsetX)) shl 32) or
      uint64(cast[uint32](source.offsetZ))
    h = mix(mix(mix(mix(a) xor b) xor c) xor d)
  cast[Hash](h xor (h shr 31))

var
  visionRayOffsets: seq[VisionRayStep]
  visionRayStart: array[VisionKernelCells, int32]
  visionRayCount: array[VisionKernelCells, int16]
  visionRaySteps: array[VisionKernelCells, int16]
  visionCircle: array[MaxVisionRadius + 1, seq[VisionOffset]]
  visionKernelReady = false

proc roundedDivision(numerator, denominator: int64): int64 =
  ## Divides signed integers with deterministic half-away-from-zero rounding.
  if numerator >= 0:
    (numerator + denominator div 2) div denominator
  else:
    -((-numerator + denominator div 2) div denominator)

proc visionKernelIndex(dx, dz: int): int =
  ## Packs a signed offset into the square kernel table.
  (dz + MaxVisionRadius) * VisionKernelSide + (dx + MaxVisionRadius)

proc initVisionKernel*() =
  ## Builds ray steps and per-radius circles once.
  if visionKernelReady:
    return
  visionRayOffsets.setLen(0)
  for dz in -MaxVisionRadius .. MaxVisionRadius:
    for dx in -MaxVisionRadius .. MaxVisionRadius:
      let
        i = visionKernelIndex(dx, dz)
        steps = max(abs(dx), abs(dz))
      visionRayStart[i] = int32(visionRayOffsets.len)
      visionRaySteps[i] = int16(steps)
      if steps <= 1:
        visionRayCount[i] = 0
        continue
      for step in 1 ..< steps:
        visionRayOffsets.add VisionRayStep(
          ox: int8(roundedDivision(
            int64(dx) * int64(step),
            int64(steps)
          )),
          oz: int8(roundedDivision(
            int64(dz) * int64(step),
            int64(steps)
          ))
        )
      visionRayCount[i] = int16(steps - 1)
  for radius in 0 .. MaxVisionRadius:
    visionCircle[radius].setLen(0)
    let limit = radius * radius
    for dz in -radius .. radius:
      for dx in -radius .. radius:
        if dx * dx + dz * dz <= limit:
          visionCircle[radius].add VisionOffset(
            dx: int8(dx),
            dz: int8(dz)
          )
  visionKernelReady = true

iterator visionCircleTiles*(radius: int32): VisionOffset =
  ## Yields every in-range offset for one sight radius.
  initVisionKernel()
  if radius >= 0 and radius <= MaxVisionRadius:
    for offset in visionCircle[radius]:
      yield offset

proc sameVisionKeys*(a, b: openArray[int32]): bool =
  ## Returns whether two skip signatures are identical.
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  true

proc copyVisionKeys*(dest: var seq[int32], src: openArray[int32]) =
  ## Copies one skip signature into a reused buffer.
  dest.setLen(src.len)
  for i, value in src:
    dest[i] = value

proc inVisionRange(source: VisionSource, x, z: int32): bool =
  ## Includes cells intersecting an exact circle when sub-tile units are supplied.
  if source.units <= 0:
    return true
  let
    dx = max(0'i64, abs(int64(x - source.x) * source.units -
      source.offsetX) - source.units div 2)
    dz = max(0'i64, abs(int64(z - source.z) * source.units -
      source.offsetZ) - source.units div 2)
  dx * dx + dz * dz <= int64(source.range) * source.range

proc rayBlocked(
    width: int32,
    terrainHeights,
    blockerHeights: openArray[int16],
    sourceX,
    sourceZ: int32,
    sourceY,
    targetY: int64,
    rayIndex: int
): bool =
  ## Returns whether a kernel ray hits an occluder before the target.
  let
    start = visionRayStart[rayIndex]
    count = int(visionRayCount[rayIndex])
    steps = int64(visionRaySteps[rayIndex])
    deltaY = targetY - sourceY
    halfSteps = steps div 2
  for i in 0 ..< count:
    let
      cell = visionRayOffsets[start + i]
      x = sourceX + int32(cell.ox)
      z = sourceZ + int32(cell.oz)
      index = z * width + x
      obstacleHeight = int64(terrainHeights[index]) +
        int64(blockerHeights[index])
      relativeHeight = obstacleHeight - sourceY
      numerator = deltaY * int64(i + 1)
    # Compare against the rounded ray height without division per ray cell.
    # Negative heights round away from zero, so their boundary is inclusive.
    if deltaY >= 0:
      if relativeHeight >= 0 and
          numerator + halfSteps < (relativeHeight + 1) * steps:
        return true
    elif relativeHeight >= 0 or
        -numerator + halfSteps >= -relativeHeight * steps:
      return true
  false

proc offsetVisible*(
    width: int32,
    terrainHeights,
    blockerHeights: openArray[int16],
    sourceX,
    sourceZ: int32,
    sourceY: int64,
    offset: VisionOffset
): bool =
  ## Tests one kernel circle offset from a known observer height.
  let
    rayIndex = visionKernelIndex(int(offset.dx), int(offset.dz))
    steps = int(visionRaySteps[rayIndex])
  if steps <= 1:
    return true
  let
    x = sourceX + int32(offset.dx)
    z = sourceZ + int32(offset.dz)
    index = z * width + x
    targetY = int64(terrainHeights[index]) + 3
  not rayBlocked(
    width,
    terrainHeights,
    blockerHeights,
    sourceX,
    sourceZ,
    sourceY,
    targetY,
    rayIndex
  )

proc liveRayBlocked(
    width: int32,
    terrainHeights,
    blockerHeights: openArray[int16],
    sourceX,
    sourceZ,
    deltaX,
    deltaZ: int32,
    sourceY,
    targetY: int64
): bool =
  ## Walks one ray with the live rounding formula. Used past the kernel.
  let steps = max(abs(deltaX), abs(deltaZ))
  if steps <= 1:
    return false
  for step in 1'i32 ..< steps:
    let
      x = sourceX + int32(roundedDivision(
        int64(deltaX) * int64(step),
        int64(steps)
      ))
      z = sourceZ + int32(roundedDivision(
        int64(deltaZ) * int64(step),
        int64(steps)
      ))
      index = z * width + x
      rayHeight = sourceY + roundedDivision(
        (targetY - sourceY) * int64(step),
        int64(steps)
      )
      obstacleHeight = int64(terrainHeights[index]) +
        int64(blockerHeights[index])
    if obstacleHeight >= rayHeight:
      return true
  false

proc lineVisible*(
    width,
    height: int32,
    terrainHeights,
    blockerHeights: openArray[int16],
    sourceX,
    sourceZ,
    targetX,
    targetZ,
    radius: int32,
    eyeHeight = 14'i16,
    targetHeight = 3'i16
): bool =
  ## Tests range and occlusion using the ray kernel when the offset fits.
  if sourceX < 0 or sourceX >= width or sourceZ < 0 or sourceZ >= height or
      targetX < 0 or targetX >= width or targetZ < 0 or targetZ >= height:
    return false
  let
    deltaX = targetX - sourceX
    deltaZ = targetZ - sourceZ
  if deltaX * deltaX + deltaZ * deltaZ > radius * radius:
    return false
  let steps = max(abs(deltaX), abs(deltaZ))
  if steps <= 1:
    return true
  let
    sourceIndex = sourceZ * width + sourceX
    targetIndex = targetZ * width + targetX
    sourceY = int64(terrainHeights[sourceIndex]) + int64(eyeHeight)
    targetY = int64(terrainHeights[targetIndex]) + int64(targetHeight)
  if abs(deltaX) <= MaxVisionRadius and abs(deltaZ) <= MaxVisionRadius:
    initVisionKernel()
    return not rayBlocked(
      width,
      terrainHeights,
      blockerHeights,
      sourceX,
      sourceZ,
      sourceY,
      targetY,
      visionKernelIndex(int(deltaX), int(deltaZ))
    )
  not liveRayBlocked(
    width,
    terrainHeights,
    blockerHeights,
    sourceX,
    sourceZ,
    deltaX,
    deltaZ,
    sourceY,
    targetY
  )

proc revealVision*(
    visible: var seq[uint8],
    width,
    height: int32,
    terrainHeights,
    blockerHeights: openArray[int16],
    sources: openArray[VisionSource]
) =
  ## Rebuilds a byte-per-tile visibility map from a set of observers.
  initVisionKernel()
  let cellCount = int(width * height)
  if visible.len != cellCount:
    visible = newSeq[uint8](cellCount)
  else:
    for value in visible.mitems:
      value = 0
  for source in sources:
    if source.radius <= 0:
      continue
    if source.radius > MaxVisionRadius:
      let
        minimumX = max(source.x - source.radius, 0)
        maximumX = min(source.x + source.radius, width - 1)
        minimumZ = max(source.z - source.radius, 0)
        maximumZ = min(source.z + source.radius, height - 1)
      for z in minimumZ .. maximumZ:
        for x in minimumX .. maximumX:
          let index = z * width + x
          if visible[index] != 0 or not source.inVisionRange(x, z):
            continue
          if lineVisible(
            width,
            height,
            terrainHeights,
            blockerHeights,
            source.x,
            source.z,
            x,
            z,
            source.radius,
            source.eyeHeight
          ):
            visible[index] = 255
      continue
    let
      sourceIndex = source.z * width + source.x
      sourceY = int64(terrainHeights[sourceIndex]) + int64(source.eyeHeight)
    for offset in visionCircle[source.radius]:
      let
        x = source.x + int32(offset.dx)
        z = source.z + int32(offset.dz)
      if x < 0 or x >= width or z < 0 or z >= height:
        continue
      if not source.inVisionRange(x, z):
        continue
      let index = z * width + x
      if visible[index] != 0:
        continue
      let
        rayIndex = visionKernelIndex(int(offset.dx), int(offset.dz))
        steps = int(visionRaySteps[rayIndex])
      if steps <= 1:
        visible[index] = 255
        continue
      let targetY = int64(terrainHeights[index]) + 3
      if not rayBlocked(
        width,
        terrainHeights,
        blockerHeights,
        source.x,
        source.z,
        sourceY,
        targetY,
        rayIndex
      ):
        visible[index] = 255

proc sameHeights(a, b: seq[int16]): bool =
  ## Compares two height grids with one memory comparison.
  a.len == b.len and (a.len == 0 or
    equalMem(a[0].unsafeAddr, b[0].unsafeAddr, a.len * sizeof(int16)))

proc revealVisionCached*(
    cache: var VisionCache,
    visible: var seq[uint8],
    width, height: int32,
    terrainHeights, blockerHeights: seq[int16],
    sources: openArray[VisionSource]
) =
  ## Retains only the previous frame's source rays. Terrain or blocker changes
  ## invalidate every entry, including height changes without moving a source.
  if cache.width != width or cache.height != height or
      not sameHeights(cache.terrain, terrainHeights) or
      not sameHeights(cache.blockers, blockerHeights):
    cache.sources.clear()
    cache.width = width
    cache.height = height
    cache.terrain = terrainHeights
    cache.blockers = blockerHeights
  visible.setLen(int(width * height))
  for value in visible.mitems:
    value = 0
  var nextSources: Table[VisionSource, seq[int32]]
  for source in sources:
    if nextSources.hasKey(source):
      continue
    if not cache.sources.hasKey(source):
      var cells: seq[int32]
      for z in max(0'i32, source.z - source.radius) .. min(height - 1, source.z + source.radius):
        for x in max(0'i32, source.x - source.radius) .. min(width - 1, source.x + source.radius):
          if source.radius > 0 and source.inVisionRange(x, z) and lineVisible(
              width, height, terrainHeights, blockerHeights,
              source.x, source.z, x, z, source.radius, source.eyeHeight):
            cells.add z * width + x
      cache.sources[source] = move(cells)
    for index in cache.sources[source]:
      visible[index] = 255
    nextSources[source] = move(cache.sources[source])
  cache.sources = move(nextSources)

proc sourceCells(width, height: int32, terrainHeights,
    blockerHeights: seq[int16], source: VisionSource): seq[int32] =
  ## The cells one source sees, exactly as revealVisionCached computes them.
  if source.radius > 0 and source.radius <= MaxVisionRadius:
    # Same cells in the same (row-major) order as the square scan below:
    # lineVisible rejects every offset outside the radius circle, so walking
    # the precomputed circle and applying lineVisible's remaining tests
    # (grid bounds, steps <= 1, kernel ray) is equivalent.
    if source.x < 0 or source.x >= width or source.z < 0 or
        source.z >= height:
      return
    initVisionKernel()
    let sourceY = int64(terrainHeights[source.z * width + source.x]) +
      int64(source.eyeHeight)
    for offset in visionCircle[source.radius]:
      let
        x = source.x + int32(offset.dx)
        z = source.z + int32(offset.dz)
      if x < 0 or x >= width or z < 0 or z >= height or
          not source.inVisionRange(x, z):
        continue
      let
        index = z * width + x
        rayIndex = visionKernelIndex(int(offset.dx), int(offset.dz))
      if int(visionRaySteps[rayIndex]) <= 1 or not rayBlocked(width,
          terrainHeights, blockerHeights, source.x, source.z, sourceY,
          int64(terrainHeights[index]) + 3, rayIndex):
        result.add index
    return
  for z in max(0'i32, source.z - source.radius) .. min(height - 1, source.z + source.radius):
    for x in max(0'i32, source.x - source.radius) .. min(width - 1, source.x + source.radius):
      if source.radius > 0 and source.inVisionRange(x, z) and lineVisible(
          width, height, terrainHeights, blockerHeights,
          source.x, source.z, x, z, source.radius, source.eyeHeight):
        result.add z * width + x

proc revealVisionTallied*(
    tally: var VisionTally,
    visible: var seq[uint8],
    width, height: int32,
    terrainHeights, blockerHeights: seq[int16],
    sources: openArray[VisionSource],
    revealed: var seq[int32]
) =
  ## Same visibility map as revealVisionCached (255 where any distinct source
  ## sees the cell, else 0), updated in place from the previous frame. Cells
  ## that turn visible this frame are appended to `revealed` (every visible
  ## cell after a reset). Terrain or blocker changes rebuild from scratch.
  let cellCount = int(width * height)
  if tally.width != width or tally.height != height or
      visible.len != cellCount or
      not sameHeights(tally.terrain, terrainHeights) or
      not sameHeights(tally.blockers, blockerHeights):
    tally.sources.clear()
    tally.spare.clear()
    tally.width = width
    tally.height = height
    tally.terrain = terrainHeights
    tally.blockers = blockerHeights
    tally.counts.setLen(cellCount)
    for count in tally.counts.mitems:
      count = 0
    visible.setLen(cellCount)
    for value in visible.mitems:
      value = 0
  inc tally.frame
  let frame = tally.frame
  tally.changed.setLen(0)
  for source in sources:
    tally.sources.withValue(source, entry):
      entry.frame = frame
    do:
      var cells: seq[int32]
      if not tally.spare.pop(source, cells):
        cells = sourceCells(width, height, terrainHeights, blockerHeights,
          source)
      for index in cells:
        if tally.counts[index] == 0:
          tally.changed.add index
        inc tally.counts[index]
      tally.sources[source] = TalliedSource(cells: cells, frame: frame)
  tally.gone.setLen(0)
  for source, entry in tally.sources.mpairs:
    if entry.frame != frame:
      tally.gone.add source
      for index in entry.cells:
        dec tally.counts[index]
        if tally.counts[index] == 0:
          tally.changed.add index
  const MaxSpareSources = 2048
  if tally.spare.len + tally.gone.len > MaxSpareSources:
    tally.spare.clear()
  for source in tally.gone:
    var entry: TalliedSource
    discard tally.sources.pop(source, entry)
    tally.spare[source] = move(entry.cells)
  for index in tally.changed:
    let now = if tally.counts[index] > 0: 255'u8 else: 0'u8
    if now != visible[index]:
      visible[index] = now
      if now != 0:
        revealed.add index

proc blurVisibility*(visible: openArray[uint8], width, height: int32): seq[uint8] =
  ## Softens only presentation edges with one deterministic box-blur pass.
  result = newSeq[uint8](visible.len)
  for z in 0 ..< height:
    for x in 0 ..< width:
      var
        total = 0'i32
        count = 0'i32
      for offsetZ in -1'i32 .. 1:
        for offsetX in -1'i32 .. 1:
          let
            sampleX = x + offsetX
            sampleZ = z + offsetZ
          if sampleX < 0 or sampleX >= width or
              sampleZ < 0 or sampleZ >= height:
            continue
          total += int32(visible[sampleZ * width + sampleX])
          inc count
      result[z * width + x] = uint8(total div max(count, 1))
