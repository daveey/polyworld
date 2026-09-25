import
  std/[math, random],
  vmath,
  polyworld/[groves, pathing, quadterrain],
  brushes, maps

export groves

proc plantGrove*(grove: var Grove, brush: BrushMix, seed: int) =
  ## Reuses seeded models on blocked brush tiles without changing navigation.
  let ground {.cursor.} = layers[GroundLayer]
  grove.colors = newSeq[Vec3](ground.tiles.len)
  for index, tile in ground.tiles:
    if not tile.exists or not tile.impassable:
      continue
    var kind: BrushKind
    if brush.trees[index] > 0:
      kind = LightTree
    elif brush.darkTrees[index]:
      kind = DarkTree
    elif brush.lightRocks[index]:
      kind = LightRock
    elif brush.darkRocks[index]:
      kind = DarkRock
    else:
      continue
    let
      x = index mod ground.width
      z = index div ground.width
    var rng = initRand(
      x.int64 * 73_856_093 + z.int64 * 19_349_663 +
        seed.int64 * 83_492_791 + 1
    )
    let
      roll = rng.rand(99)
      variant =
        if kind != LightTree: rng.rand(BrushVariants - 1)
        elif roll < 75: rng.rand(6)
        elif roll < 95: rng.rand(7 .. 8)
        else: 9
      worldX = (ground.originX + x).float32 - HalfGrid + 0.5'f
      worldZ = (ground.originZ + z).float32 - HalfGrid + 0.5'f
      size =
        if kind in {LightTree, DarkTree}: 0.85'f + rng.rand(0.45).float32
        else: 0.5'f + rng.rand(1.0).float32
      pack = if kind in {LightTree, DarkTree}: grove.trees else: grove.rocks
    var base = groundHeight(worldX, worldZ) + groundOffset(worldX, worldZ)
    if kind in {LightRock, DarkRock}:
      # Tuck the open cut beneath the lowest local ground instead of floating.
      for dx in [-0.45'f, 0.45'f]:
        for dz in [-0.45'f, 0.45'f]:
          base = min(base, groundHeight(worldX + dx, worldZ + dz) +
            groundOffset(worldX + dx, worldZ + dz))
    base -= 0.04'f
    pack.placeProp(
      modelName(kind, variant),
      vec3(worldX, base, worldZ),
      rotation = rng.rand(2 * PI).float32,
      scale = size
    )
    grove.colors[index] =
      case kind
      of LightTree: LeafColors[variant] * 0.58'f
      of DarkTree: vec3(0.18, 0.14, 0.17)
      of LightRock: LightRockColor * 0.5'f
      of DarkRock: DarkRockColor * 0.5'f
