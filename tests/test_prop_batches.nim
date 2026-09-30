include ../src/polyworld/quadterrain

proc fixtureModel(texture: GLuint, height = 1.0'f): PropModel =
  ## Builds a tiny textured triangle without requiring a graphics context.
  PropModel(
    name: "triangle",
    textureArray: texture,
    materialColors: true,
    vertices: @[
      0.0'f, 0, 0, 1, 0.5, 0.25, 0, 1, 0,
      1.0'f, 0, 0, 1, 0.5, 0.25, 0, 1, 0,
      0.0'f, height, 0, 1, 0.5, 0.25, 0, 1, 0
    ],
    uvs: @[0.0'f, 0, 0, 1, 0, 0, 0, 1, 0]
  )

proc fixturePlacement(
  model: PropModel,
  group: int32,
  x = 0.0'f
): PropPlacement =
  ## Supplies a stable building or scenery placement for cache updates.
  PropPlacement(
    model: model, group: group, position: vec3(x, 0, 0),
    scale: 1, stretch: vec3(1), tint: vec3(1)
  )

proc changedGroups(): seq[int32] =
  ## Reads dirty groups while comparing cached geometry with a fresh bake.
  for batch in texturedBatches:
    if batch.dirty:
      result.add batch.group
    var fresh: seq[float32]
    for placement in batch.placements:
      bakeTexturedInstance(
        placement.model,
        placement.position,
        placement.rotation,
        placement.scale,
        placement.tint,
        placement.stretch,
        fresh
      )
    doAssert batch.mesh == fresh, "Cached geometry differs from a fresh bake."

echo "Testing independent building and scenery batches"
block updates:
  let
    tree = fixtureModel(1)
    foundation = fixtureModel(2)
    walls = fixtureModel(2, 2)
    firstTree = fixturePlacement(tree, -1)
    secondTree = fixturePlacement(tree, -2, 32)
    house = fixturePlacement(foundation, 100, 10)
    farm = fixturePlacement(foundation, 101, 20)
  propPlacements = @[firstTree, secondTree, house]
  prepareTexturedBatches()
  doAssert changedGroups() == @[-1'i32, -2, 100]
  let
    forestBuffer = unsafeAddr texturedBatches[0].mesh[0]
    forestMesh = texturedBatches[0].mesh
  prepareTexturedBatches()
  doAssert changedGroups().len == 0
  doAssert unsafeAddr(texturedBatches[0].mesh[0]) == forestBuffer

  propPlacements[2].model = walls
  prepareTexturedBatches()
  doAssert changedGroups() == @[100'i32]
  doAssert texturedBatches[0].mesh == forestMesh
  doAssert unsafeAddr(texturedBatches[0].mesh[0]) == forestBuffer
  propPlacements.add farm
  prepareTexturedBatches()
  doAssert changedGroups() == @[101'i32]

  # Felling a tree and removing a building must clear their old geometry.
  propPlacements = @[secondTree, house]
  prepareTexturedBatches()
  doAssert changedGroups() == @[-1'i32, 100, 101]
  doAssert texturedBatches[0].mesh.len == 0
  doAssert texturedBatches[3].mesh.len == 0

  # A replay seek restores old placements, including harvested trees.
  propPlacements = @[firstTree, secondTree, house]
  prepareTexturedBatches()
  doAssert changedGroups() == @[-1'i32]
  doAssert texturedBatches[0].mesh == forestMesh
  prepareTexturedBatches()
  doAssert changedGroups().len == 0

echo "Testing all transform and material changes invalidate their own group"
block transforms:
  texturedBatches.setLen(0)
  let original = fixturePlacement(fixtureModel(7), 11)
  propPlacements = @[original]
  prepareTexturedBatches()
  for field in 0 ..< 6:
    var changed = original
    case field
    of 0: changed.position = vec3(2, 3, 4)
    of 1: changed.rotation = 0.4'f
    of 2: changed.scale = 1.5'f
    of 3: changed.stretch = vec3(1, 2, 3)
    of 4: changed.tint = vec3(0.2, 0.4, 0.6)
    else: changed.model = fixtureModel(7, 4)
    propPlacements = @[changed]
    prepareTexturedBatches()
    doAssert changedGroups() == @[11'i32]
    prepareTexturedBatches()
    doAssert changedGroups().len == 0
    propPlacements = @[original]
    prepareTexturedBatches()
    doAssert changedGroups() == @[11'i32]
  propPlacements[0].model = fixtureModel(8)
  prepareTexturedBatches()
  doAssert texturedBatches.len == 2
  doAssert texturedBatches[0].mesh.len == 0
  doAssert texturedBatches[1].mesh.len > 0
  doAssert changedGroups() == @[11'i32, 11]

echo "Textured prop batch cache passed"
