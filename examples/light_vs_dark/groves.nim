import
  std/[math, random],
  vmath,
  polyworld/[groves, pathing, quadterrain]

export groves

const
  DecorativeRocks = 80
  SceneryChunkSize = 32

type GrovePlacement* = object
  kind*: BrushKind
  variant*, tile*: int
  position*: Vec3
  rotation*, scale*: float32

proc placement(kind: BrushKind, tile, seed: int): GrovePlacement =
  ## Seeds a stable variant and anchors it to the local ground surface.
  let
    ground = layers[0]
    x = tile mod ground.width
    z = tile div ground.width
    worldX = (ground.originX + x).float32 - HalfGrid + 0.5'f
    worldZ = (ground.originZ + z).float32 - HalfGrid + 0.5'f
  var rng = initRand(
    x.int64 * 73_856_093 + z.int64 * 19_349_663 +
      seed.int64 * 83_492_791 + 1
  )
  let roll = rng.rand(99)
  result.kind = kind
  result.tile = tile
  result.variant =
    if kind == LightRock:
      rng.rand(BrushVariants - 1)
    elif roll < 75:
      rng.rand(6)
    elif roll < 95:
      rng.rand(7 .. 8)
    else:
      9
  result.scale =
    if kind == LightTree:
      0.85'f + rng.rand(0.45).float32
    else:
      0.5'f + rng.rand(1.0).float32
  var base = groundHeight(worldX, worldZ) + groundOffset(worldX, worldZ)
  if kind == LightRock:
    # Keep the open underside beneath the lowest nearby ground corner.
    for dx in [-0.45'f, 0.45'f]:
      for dz in [-0.45'f, 0.45'f]:
        base = min(
          base,
          groundHeight(worldX + dx, worldZ + dz) +
            groundOffset(worldX + dx, worldZ + dz)
        )
  result.position = vec3(worldX, base - 0.04'f, worldZ)
  result.rotation = rng.rand(2 * PI).float32

proc grovePlacements*(
  treeWood: openArray[int16],
  seed: int,
  forestRocks: openArray[int32] = []
): seq[GrovePlacement] =
  ## Records harvestable trees and decorative rocks without changing tiles.
  let ground = layers[0]
  doAssert treeWood.len == ground.tiles.len
  var candidates: seq[int]
  for index, tile in ground.tiles:
    if not tile.exists:
      continue
    if treeWood[index] > 0:
      result.add placement(LightTree, index, seed)
    elif tile.kind == RockTile and not tile.impassable:
      candidates.add index
  var rng = initRand(seed.int64 * 104_729 + 3)
  rng.shuffle(candidates)
  for index in 0 ..< min(DecorativeRocks, candidates.len):
    result.add placement(LightRock, candidates[index], seed)
  for index in forestRocks:
    var rock = placement(LightRock, index.int, seed)
    # These rocks block one tile, so keep their mesh inside that footprint.
    rock.scale = 0.45'f + (rock.variant mod 3).float32 * 0.05'f
    result.add rock

proc visible*(placement: GrovePlacement, treeWood: openArray[int16]): bool =
  ## Follows authoritative wood state for harvesting and replay restoration.
  placement.kind == LightRock or treeWood[placement.tile] > 0

proc sceneryGroup*(tile, width: int): int32 =
  ## Uses negative chunk IDs so scenery never shares a building's batch.
  let columns = (width + SceneryChunkSize - 1) div SceneryChunkSize
  -1'i32 - int32(
    (tile div width div SceneryChunkSize) * columns +
    tile mod width div SceneryChunkSize
  )

proc plantGrove*(
  grove: Grove,
  placements: openArray[GrovePlacement],
  treeWood: openArray[int16]
) =
  ## Groups generated scenery by location for independent cached updates.
  for placement in placements:
    if not placement.visible(treeWood):
      continue
    let pack =
      if placement.kind == LightTree:
        grove.trees
      else:
        grove.rocks
    pack.placeProp(
      modelName(placement.kind, placement.variant),
      placement.position,
      placement.rotation,
      placement.scale,
      group = sceneryGroup(placement.tile, layers[0].width)
    )
