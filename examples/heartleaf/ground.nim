## Heartleaf ground art: a procedural cobble sheet and the ground mask that
## decides, texel by texel, where the plaza's stones and the roads' dirt lie.
## Pure CPU work with no GL, so headless tests can check every byte.
##
## Stones are discrete objects. Every stone carries one height, which is
## also its dropout order: the mask's stone coverage falls off across the
## plaza rim, and the shader keeps a stone only where coverage still beats
## its height. The last row is therefore ragged whole stones with dirt in
## the gaps.

import
  std/math,
  pixie,
  polyworld/[noises, pathing, rngs],
  content,
  maps, layouts

type
  StoneStyle* = object
    ## How one sheet of stones is cut.
    cells*: int
      ## Stones per sheet side. One sheet spans ten tiles.
    jitter*: float32
      ## Seed offset from the cell centre, as a fraction of a cell.
    squareness*: float32
      ## 1 is pure Chebyshev (square cells); lower rounds the corners.
    mortar*: float32
      ## Gap between stones in texels.
    bevel*: float32
      ## Stone edge softening in texels.
    stone*: Vec3
    mortarColor*: Vec3
    heightFloor*: float32
      ## Lowest stone height, so mortar (height 0) always yields first.
    salt*: uint64

const
  SheetSize* = 1024
    ## Terrain material sheets are square at this size.
  GrainAmount = 0.03'f32
  CobbleStyle* = StoneStyle(
    cells: 20, jitter: 0.3, squareness: 0.7, mortar: 5.0, bevel: 6.0,
    stone: vec3(0.42, 0.38, 0.40), mortarColor: vec3(0.30, 0.26, 0.25),
    heightFloor: 0.35, salt: 0xC0BB1E'u64)
    ## Plaza cobbles: a stone every half tile, a little irregular.
  CurbStyle* = StoneStyle(
    cells: 8, jitter: 0.0, squareness: 1.0, mortar: 10.0, bevel: 10.0,
    stone: vec3(0.56, 0.51, 0.50), mortarColor: vec3(0.32, 0.28, 0.26),
    heightFloor: 0.5, salt: 0xC04B'u64)
    ## The cut-stone curb around the plaza: a clean square grid, lighter,
    ## sampled around the ring rather than across the world.
  CurbInner* = float32(PlazaStoneRadius)
    ## Tiles from the plaza centre where the curb starts.
  CurbWidth* = 0.8'f32
    ## Radial width of the curb in tiles; one stone row spans it.
  CurbStones* = 64
    ## Stones around the ring. A multiple of the curb style's cells, so the
    ## sheet seam lands on a mortar line.
  CurbFade* = 0.4'f32
    ## Tiles past the curb's outer edge over which its stones drop out.
  StoneInset = 0.3'f32
    ## The cobbles reach this far past the plaza radius, under the curb.
  RoadStoneReach = 0.6'f32
    ## Tiles from a road tile's centre line that are cobbled, before
    ## rounding. Two-wide roads get a band a little over two tiles wide,
    ## the one-wide ring path a little over one.
  RoadRoundTexels = 6
    ## Box blur radius applied to the road cobble field before it is
    ## thresholded, which fillets every corner inside and out.
  RoadStoneEdge = 0.3'f32
  RoadStoneBand = 0.4'f32
    ## Where the blurred field crosses RoadStoneEdge the cobbles start to
    ## drop out, and they are gone RoadStoneBand later.
  RoadStoneWobbleStream = 0x5A17E5'u64
  HouseStoneReach = float32(HouseFootprint) * 0.5'f32 + 0.3'f32
  HouseStoneBand = 0.8'f32
  HouseStoneSquareness = 0.75'f32

  MaskTexelsPerTile* = 8
  MaskSize* = GridTiles * MaskTexelsPerTile
  MaskChannels* = 2
    ## R is stone coverage, G is dirt coverage.
  StoneBand = 0.1'f32
    ## Tiles over which cobble coverage falls from full to none. The curb is
    ## the plaza's hard edge, so this is a step hidden underneath it; the
    ## ragged dropout is for roads.
  DirtReach = 0.3'f32
    ## Tiles past a road or plaza tile that stay fully dirt.
  DirtBand = 0.9'f32
    ## Tiles over which dirt then fades into grass.
  WobbleTiles = 0.6'f32
    ## Low-frequency wander added to the dirt distance so road edges are not
    ## ruler lines. It fades in over the first stretch beyond a road so road
    ## tiles themselves stay fully dirt. The plaza stays a true circle; the
    ## curb is its edge.
  WobbleSpacing = 3 * MaskTexelsPerTile
  DirtWobbleStream = 0xD1A7'u64

type
  CobbleSheet* = object
    color*: Image
    height*: Image
    cells*: seq[int32]
      ## Which stone each texel belongs to, -1 for mortar. Exposed so tests
      ## can prove the sheet wraps.

  CobbleSeed = object
    pos: Vec2
    height: float32
    brightness: float32
    tint: Vec3

proc stoneMetric(dx, dy, squareness: float32): float32 =
  ## Chebyshev blended with Euclid, so cells read as squares with corners
  ## rounded by however much squareness gives away.
  squareness * max(abs(dx), abs(dy)) +
    (1.0'f32 - squareness) * sqrt(dx * dx + dy * dy)

proc grain(x, y: int): float32 =
  ## Deterministic per-texel noise in -1 .. 1.
  var rng = Rng(state: uint64(x) * 0x9E3779B97F4A7C15'u64 xor
    uint64(y) * 0xC2B2AE3D27D4EB4F'u64)
  float32((rng.next() shr 40) and 0xffff) / 32767.5'f32 - 1.0'f32

proc toByte(value: float32): uint8 =
  ## Clamps a 0 .. 1 value into a texel byte.
  uint8(clamp(value * 255.0'f32 + 0.5'f32, 0.0'f32, 255.0'f32))

proc loadGroundSheet*(path: string): tuple[color, height: Image] =
  ## Loads a loose ground texture as a terrain material. The toon packs ship
  ## no height maps, so height is the colour's contrast-stretched luminance,
  ## the same stand-in the engine uses for its handpainted grass.
  var color = readImage(path)
  if color.width != SheetSize or color.height != SheetSize:
    color = color.resize(SheetSize, SheetSize)
  var
    darkest = 255.0'f32
    brightest = 0.0'f32
  for px in color.data:
    let l = 0.30'f32 * px.r.float32 + 0.59'f32 * px.g.float32 +
      0.11'f32 * px.b.float32
    darkest = min(darkest, l)
    brightest = max(brightest, l)
  let span = max(brightest - darkest, 1.0'f32)
  var height = newImage(SheetSize, SheetSize)
  for i, px in color.data:
    let
      l = 0.30'f32 * px.r.float32 + 0.59'f32 * px.g.float32 +
        0.11'f32 * px.b.float32
      value = toByte((l - darkest) / span)
    height.data[i] = rgbx(value, value, value, 255)
  (color: color, height: height)

proc buildStoneSheet*(seed: int32, style: StoneStyle): CobbleSheet =
  ## Generates a tiling sheet of stones in one style: colour in RGB, stone
  ## height in the height image, one fixed height per stone.
  let cellSize = SheetSize.float32 / style.cells.float32
  var
    rng = initRng(seed, style.salt)
    seeds = newSeq[CobbleSeed](style.cells * style.cells)
  for cy in 0 ..< style.cells:
    for cx in 0 ..< style.cells:
      let
        jitterX = (float32(rng.below(2001)) / 1000.0'f32 - 1.0'f32) *
          style.jitter
        jitterY = (float32(rng.below(2001)) / 1000.0'f32 - 1.0'f32) *
          style.jitter
        height = style.heightFloor +
          (1.0'f32 - style.heightFloor) * float32(rng.below(1001)) / 1000.0'f32
        brightness = 0.9'f32 + 0.2'f32 * float32(rng.below(1001)) / 1000.0'f32
        tint = vec3(
          (float32(rng.below(1001)) / 1000.0'f32 - 0.5'f32) * 0.04'f32,
          (float32(rng.below(1001)) / 1000.0'f32 - 0.5'f32) * 0.04'f32,
          (float32(rng.below(1001)) / 1000.0'f32 - 0.5'f32) * 0.04'f32
        )
      seeds[cy * style.cells + cx] = CobbleSeed(
        pos: vec2(
          (float32(cx) + 0.5'f32 + jitterX) * cellSize,
          (float32(cy) + 0.5'f32 + jitterY) * cellSize),
        height: height,
        brightness: brightness,
        tint: tint
      )
  result.color = newImage(SheetSize, SheetSize)
  result.height = newImage(SheetSize, SheetSize)
  result.cells = newSeq[int32](SheetSize * SheetSize)
  for y in 0 ..< SheetSize:
    for x in 0 ..< SheetSize:
      let
        px = float32(x) + 0.5'f32
        py = float32(y) + 0.5'f32
        cellX = int(px / cellSize)
        cellY = int(py / cellSize)
      var
        best = float32.high
        second = float32.high
        bestSeed = -1
      for dy in -1 .. 1:
        for dx in -1 .. 1:
          let
            nx = cellX + dx
            ny = cellY + dy
            wrappedX = (nx + style.cells) mod style.cells
            wrappedY = (ny + style.cells) mod style.cells
            index = wrappedY * style.cells + wrappedX
            shiftX = float32(nx - wrappedX) * cellSize
            shiftY = float32(ny - wrappedY) * cellSize
            candidate = seeds[index].pos + vec2(shiftX, shiftY)
            distance = stoneMetric(
              px - candidate.x, py - candidate.y, style.squareness)
          if distance < best:
            second = best
            best = distance
            bestSeed = index
          elif distance < second:
            second = distance
      let
        gap = second - best
        texel = y * SheetSize + x
        noise = grain(x, y) * GrainAmount
      if gap < style.mortar:
        result.cells[texel] = -1
        result.color.data[texel] = rgbx(
          toByte(style.mortarColor.x + noise),
          toByte(style.mortarColor.y + noise),
          toByte(style.mortarColor.z + noise),
          255)
        result.height.data[texel] = rgbx(0, 0, 0, 255)
      else:
        let
          stone = seeds[bestSeed]
          bevel = clamp((gap - style.mortar) / style.bevel, 0.0'f32, 1.0'f32)
          shade = stone.brightness * (0.85'f32 + 0.15'f32 * bevel) + noise
          height = stone.height * (0.92'f32 + 0.08'f32 * bevel)
        result.cells[texel] = int32(bestSeed)
        result.color.data[texel] = rgbx(
          toByte((style.stone.x + stone.tint.x) * shade),
          toByte((style.stone.y + stone.tint.y) * shade),
          toByte((style.stone.z + stone.tint.z) * shade),
          255)
        let h = toByte(height)
        result.height.data[texel] = rgbx(h, h, h, 255)

proc buildCobbleSheet*(seed: int32): CobbleSheet =
  ## The plaza cobbles.
  buildStoneSheet(seed, CobbleStyle)

proc buildCurbSheet*(seed: int32): CobbleSheet =
  ## The cut stones that ring the plaza.
  buildStoneSheet(seed, CurbStyle)

proc distanceTransform1d(f: var seq[float32], d: var seq[float32],
    v: var seq[int], z: var seq[float32]) =
  ## Felzenszwalb's lower-envelope squared distance transform of one line.
  let n = f.len
  var k = 0
  v[0] = 0
  z[0] = -Inf
  z[1] = Inf
  for q in 1 ..< n:
    var s = ((f[q] + float32(q * q)) - (f[v[k]] + float32(v[k] * v[k]))) /
      float32(2 * q - 2 * v[k])
    while s <= z[k]:
      dec k
      s = ((f[q] + float32(q * q)) - (f[v[k]] + float32(v[k] * v[k]))) /
        float32(2 * q - 2 * v[k])
    inc k
    v[k] = q
    z[k] = s
    z[k + 1] = Inf
  k = 0
  for q in 0 ..< n:
    while z[k + 1] < float32(q):
      inc k
    d[q] = float32((q - v[k]) * (q - v[k])) + f[v[k]]

proc distanceTransform(sources: seq[bool], size: int): seq[float32] =
  ## Euclidean distance in texels from every texel to the nearest source.
  const Far = 1.0e12'f32
  var grid = newSeq[float32](size * size)
  for i, source in sources:
    grid[i] = if source: 0.0'f32 else: Far
  var
    f = newSeq[float32](size)
    d = newSeq[float32](size)
    v = newSeq[int](size)
    z = newSeq[float32](size + 1)
  for x in 0 ..< size:
    for y in 0 ..< size:
      f[y] = grid[y * size + x]
    distanceTransform1d(f, d, v, z)
    for y in 0 ..< size:
      grid[y * size + x] = d[y]
  for y in 0 ..< size:
    for x in 0 ..< size:
      f[x] = grid[y * size + x]
    distanceTransform1d(f, d, v, z)
    for x in 0 ..< size:
      grid[y * size + x] = sqrt(d[x])
  grid

proc boxBlur(field: var seq[float32], size, radius: int) =
  ## Separable box blur with clamped edges, in place.
  var line = newSeq[float32](size)
  let window = float32(2 * radius + 1)
  for y in 0 ..< size:
    for x in 0 ..< size:
      line[x] = field[y * size + x]
    var total = 0.0'f32
    for x in -radius .. radius:
      total += line[clamp(x, 0, size - 1)]
    for x in 0 ..< size:
      field[y * size + x] = total / window
      total += line[clamp(x + radius + 1, 0, size - 1)] -
        line[clamp(x - radius, 0, size - 1)]
  for x in 0 ..< size:
    for y in 0 ..< size:
      line[y] = field[y * size + x]
    var total = 0.0'f32
    for y in -radius .. radius:
      total += line[clamp(y, 0, size - 1)]
    for y in 0 ..< size:
      field[y * size + x] = total / window
      total += line[clamp(y + radius + 1, 0, size - 1)] -
        line[clamp(y - radius, 0, size - 1)]

proc wobble(seed: int32, stream: uint64, x, y: int): float32 =
  ## Smooth wander in tiles for one mask texel.
  float32(valueNoise(seed, stream, x, y, WobbleSpacing)) /
    float32(MapBlendScale) * WobbleTiles

proc buildGroundMask*(map: MapData, seed: int32): seq[uint8] =
  ## Bakes stone and dirt coverage for the whole map at MaskTexelsPerTile.
  ## Texel (tx, ty) covers tile coordinate tx / MaskTexelsPerTile, the same
  ## convention the terrain shader uses for its per-tile textures.
  let
    center = float32(GridSide div 2) + 0.5'f32
    texelsPerTile = float32(MaskTexelsPerTile)
  var
    sources = newSeq[bool](MaskSize * MaskSize)
    centres = newSeq[bool](MaskSize * MaskSize)
  for ty in 0 ..< MaskSize:
    for tx in 0 ..< MaskSize:
      let kind = map.kinds[tileIndex(
        int32(tx div MaskTexelsPerTile), int32(ty div MaskTexelsPerTile))]
      sources[ty * MaskSize + tx] =
        kind == uint8(RoadTile) or kind == uint8(StoneTile) or
        kind == uint8(HouseTileKind)
      centres[ty * MaskSize + tx] = kind == uint8(RoadTile) and
        tx mod MaskTexelsPerTile == MaskTexelsPerTile div 2 and
        ty mod MaskTexelsPerTile == MaskTexelsPerTile div 2
  let
    dirtDistance = distanceTransform(sources, MaskSize)
    centreDistance = distanceTransform(centres, MaskSize)
  ## Road cobbles: everything within reach of a road centre line, blurred
  ## so the corners of the tile doglegs round off, then thresholded with a
  ## band for the stone-by-stone dropout.
  var roadStone = newSeq[float32](MaskSize * MaskSize)
  for i, distance in centreDistance:
    roadStone[i] =
      if distance / texelsPerTile <= RoadStoneReach: 1.0'f32 else: 0.0'f32
  boxBlur(roadStone, MaskSize, RoadRoundTexels)
  boxBlur(roadStone, MaskSize, RoadRoundTexels)
  result = newSeq[uint8](MaskSize * MaskSize * MaskChannels)
  for ty in 0 ..< MaskSize:
    for tx in 0 ..< MaskSize:
      let
        texel = (ty * MaskSize + tx) * MaskChannels
        x = (float32(tx) + 0.5'f32) / texelsPerTile
        y = (float32(ty) + 0.5'f32) / texelsPerTile
        plazaDistance = sqrt((x - center) * (x - center) +
          (y - center) * (y - center))
        plazaStone = clamp(
          (float32(PlazaStoneRadius) + StoneInset - plazaDistance) / StoneBand,
          0.0'f32, 1.0'f32)
        roadEdge = RoadStoneEdge +
          wobble(seed, RoadStoneWobbleStream, tx, ty) * 0.25'f32
        roadCoverage = clamp(
          (roadStone[ty * MaskSize + tx] - roadEdge) / RoadStoneBand,
          0.0'f32, 1.0'f32)
        roadClearance = dirtDistance[ty * MaskSize + tx] / texelsPerTile
        roadDistance = roadClearance +
          wobble(seed, DirtWobbleStream, tx, ty) *
          min(roadClearance / DirtReach, 1.0'f32)
        dirt = clamp(
          1.0'f32 - (roadDistance - DirtReach) / DirtBand, 0.0'f32, 1.0'f32)
      var houseCoverage = 0.0'f32
      for house in map.houses:
        let distance = stoneMetric(
          abs(x - (float32(house.center.x) + 0.5'f32)),
          abs(y - (float32(house.center.y) + 0.5'f32)),
          HouseStoneSquareness)
        houseCoverage = max(houseCoverage, clamp(
          (HouseStoneReach - distance) / HouseStoneBand,
          0.0'f32, 1.0'f32))
      let stone = max(plazaStone, max(roadCoverage, houseCoverage))
      result[texel] = toByte(stone)
      result[texel + 1] = if stone > 0.0'f32: 255'u8 else: toByte(dirt)

proc buildTownGroundMask*(seed: int32): seq[uint8] =
  ## Paints cream plaza paving and golden lanes with soft grassy edges.
  result = newSeq[uint8](MaskSize * MaskSize * MaskChannels)
  for ty in 0 ..< MaskSize:
    for tx in 0 ..< MaskSize:
      let
        x = (tx.float32 + 0.5'f) / MaskTexelsPerTile.float32 -
          HalfGrid - 0.5'f
        z = (ty.float32 + 0.5'f) / MaskTexelsPerTile.float32 -
          HalfGrid - 0.5'f
      if x < TownMinX.float32 - 1 or x > TownMaxX.float32 + 1 or
        z < TownMinZ.float32 - 1 or z > TownMaxZ.float32 + 1:
          continue
      let
        distance = roadClearance(x, z)
        edge = wobble(seed, DirtWobbleStream, tx, ty) * 0.4'f +
          wobble(seed, RoadStoneWobbleStream, tx * 3, ty * 3) * 0.18'f
        dirt = smoothstep(-0.48'f, 0.28'f, -distance + edge)
        radius = length(vec2(x, z) - TownPlaza)
        stone = clamp((TownPlazaRadius - radius) / 0.35'f, 0'f, 1'f) *
          clamp((radius - 1.8'f) / 0.25'f, 0'f, 1'f)
        index = (ty * MaskSize + tx) * MaskChannels
      result[index] = toByte(stone)
      result[index + 1] = toByte(max(stone, dirt))

proc buildReferenceGroundMask*(reference: Image): seq[uint8] =
  ## Registers material coverage from the supplied grass and paths layer.
  result = newSeq[uint8](MaskSize * MaskSize * MaskChannels)
  for ty in 0 ..< MaskSize:
    for tx in 0 ..< MaskSize:
      let
        x = (tx.float32 + 0.5'f) / MaskTexelsPerTile.float32 - HalfGrid
        z = (ty.float32 + 0.5'f) / MaskTexelsPerTile.float32 - HalfGrid
        px = int(round(x / 0.044'f + 560))
        py = int(round(z / 0.057'f + 650))
      if px < 1 or py < 1 or
        px >= reference.width - 1 or py >= reference.height - 1:
          continue
      var dirt, stone: float32
      for dy in -1 .. 1:
        for dx in -1 .. 1:
          let
            pixel = reference[px + dx, py + dy]
            warm = pixel.r.float32 - pixel.g.float32
            coverage = smoothstep(5'f, 20'f, warm)
            paving = smoothstep(0.66'f, 0.78'f,
              pixel.b.float32 / max(1'f, pixel.g.float32))
          dirt += coverage
          stone += coverage * paving
      let index = (ty * MaskSize + tx) * MaskChannels
      result[index] = toByte(stone / 9)
      result[index + 1] = toByte(dirt / 9)
