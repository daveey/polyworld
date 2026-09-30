## Requires desktop OpenGL and terrain assets for buffer lifecycle checks.

include test_prop_batches
import windy

proc readBuffer(buffer: GLuint): seq[float32] =
  ## Reads actual uploaded vertices for comparison with an unchanged batch.
  glBindBuffer(GL_ARRAY_BUFFER, buffer)
  var size: GLint
  glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_SIZE, size.addr)
  result.setLen(size.int div sizeof(float32))
  if result.len > 0:
    glGetBufferSubData(GL_ARRAY_BUFFER, 0, size.int, result[0].addr)

proc groupIndex(group: int32): int =
  ## Finds a group after empty-batch compaction changes the storage order.
  for i, batch in texturedBatches:
    if batch.group == group:
      return i
  -1

block gpuUpdates:
  let window = newWindow(
    "Prop batch verification", ivec2(128, 128), visible = false, vsync = false
  )
  defer:
    window.close()
  window.makeContextCurrent()
  loadExtensions()
  texturedBatches.setLen(0)
  propPlacements.setLen(0)
  initTerrain(
    treeStyle = NoTrees,
    terrainStyle = GeneratedTerrain,
    rockStyle = NoRocks,
    settings = TerrainAssets(size: 1024)
  )
  var layer = QuadLayer(
    originX: GridTiles div 2, originZ: GridTiles div 2,
    width: 2, depth: 2, tiles: newSeq[Tile](4)
  )
  for tile in layer.tiles.mitems:
    tile.flags = TileExists or TileConnectedEast or TileConnectedSouth
    tile.kind = GrassTile
  installImmutableLayers(@[layer])
  let
    texture = buildTextureArray(@[@[newImage(1, 1)]], GL_CLAMP_TO_EDGE.GLint)
    tree = fixturePlacement(fixtureModel(texture), -1)
    house = fixturePlacement(fixtureModel(texture), 10)
    taller = fixturePlacement(fixtureModel(texture, 2), 10)
  propPlacements = @[tree, house]
  bakeTerrain()
  let
    ground = mesh
    groundUpload = readBuffer(vertexBuffer)
    forestBuffer = texturedBatches[groupIndex(-1)].vertexBuffer
    forestVao = texturedBatches[groupIndex(-1)].vertexArray
    forestDepth = texturedBatches[groupIndex(-1)].depthVertexArray
    forestUpload = readBuffer(forestBuffer)
    houseBuffer = texturedBatches[groupIndex(10)].vertexBuffer
    houseUpload = readBuffer(houseBuffer)
  doAssert forestUpload.len > 0

  echo "Testing building updates retain ground and unchanged GPU batches"
  propPlacements = @[tree, taller]
  bakeProps()
  doAssert texturedBatches[groupIndex(-1)].vertexBuffer == forestBuffer
  doAssert readBuffer(forestBuffer) == forestUpload
  doAssert texturedBatches[groupIndex(10)].vertexBuffer == houseBuffer
  doAssert readBuffer(houseBuffer) != houseUpload
  doAssert mesh == ground
  doAssert readBuffer(vertexBuffer) == groundUpload

  echo "Testing removal releases buffers and replay restoration recreates them"
  propPlacements = @[taller]
  bakeProps()
  doAssert texturedBatches.len == 1
  doAssert glIsBuffer(forestBuffer) == GL_FALSE
  doAssert glIsVertexArray(forestVao) == GL_FALSE
  doAssert glIsVertexArray(forestDepth) == GL_FALSE
  propPlacements = @[tree, house]
  bakeProps()
  doAssert texturedBatches.len == 2
  let
    restoredForest = texturedBatches[groupIndex(-1)].vertexBuffer
    restoredHouse = texturedBatches[groupIndex(10)].vertexBuffer
  doAssert readBuffer(restoredForest) == forestUpload
  doAssert readBuffer(restoredHouse) == houseUpload
  propPlacements = @[fixturePlacement(PropModel(textureArray: texture), 10)]
  bakeProps()
  doAssert texturedBatches.len == 1
  doAssert texturedBatches[0].mesh.len == 0
  for i in 0 ..< 4:
    propPlacements.setLen(0)
    bakeProps()
    doAssert texturedBatches.len == 0
    propPlacements = @[tree, house]
    bakeProps()
    doAssert texturedBatches.len == 2
  doAssert readBuffer(vertexBuffer) == groundUpload
  doAssert glGetError() == GL_NO_ERROR
  propPlacements.setLen(0)
  bakeProps()
  glDeleteTextures(1, unsafeAddr texture)

echo "GPU prop batch updates passed"
