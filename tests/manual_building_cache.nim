## Requires desktop OpenGL and LvD building assets for texture comparisons.

include ../src/polyworld/quadterrain
import
  windy,
  ../examples/light_vs_dark/assets as lvdAssets,
  ../examples/light_vs_dark/factions

proc texturePixels(texture: GLuint): seq[uint8] =
  ## Reads the uploaded atlas, including the neutral material layer.
  glBindTexture(GL_TEXTURE_2D_ARRAY, texture)
  var width, height, depth: GLint
  glGetTexLevelParameteriv(GL_TEXTURE_2D_ARRAY, 0, GL_TEXTURE_WIDTH, width.addr)
  glGetTexLevelParameteriv(
    GL_TEXTURE_2D_ARRAY,
    0,
    GL_TEXTURE_HEIGHT,
    height.addr
  )
  glGetTexLevelParameteriv(GL_TEXTURE_2D_ARRAY, 0, GL_TEXTURE_DEPTH, depth.addr)
  result.setLen(width.int * height.int * depth.int * 4)
  glGetTexImage(
    GL_TEXTURE_2D_ARRAY,
    0,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    result[0].addr
  )

block:
  let window = newWindow(
    "Building cache verification", ivec2(128, 128), visible = false
  )
  defer:
    window.close()
  window.makeContextCurrent()
  loadExtensions()
  let source = loadPropPack(
    lvdAssets.buildingModelPaths(),
    unitHeight = false,
    textured = true,
    textureSize = 512,
    mergeNodes = true,
    materialColors = true
  )
  var originalUvs: seq[seq[float32]]
  for model in source.models:
    originalUvs.add model.uvs
  for faction in [Emerald, WetAsphalt]:
    let
      image = readImage(factionTexturePath(faction))
      cached = source.retexturePropPack(image, whiteLayer = 0)
      fresh = loadPropPack(
        lvdAssets.buildingModelPaths(),
        unitHeight = false,
        textured = true,
        textureSize = 512,
        mergeNodes = true,
        materialColors = true,
        textureOverride = image
      )
    doAssert cached.names == fresh.names
    doAssert cached.models.len == fresh.models.len
    for i, model in cached.models:
      doAssert model.vertices == fresh.models[i].vertices
      doAssert model.uvs == fresh.models[i].uvs
      doAssert model.height == fresh.models[i].height
      doAssert source.models[i].uvs == originalUvs[i]
    doAssert texturePixels(cached.textureArray) ==
      texturePixels(fresh.textureArray)
    echo faction, ": reused geometry and uploaded texture match fresh loading"
  doAssert glGetError() == GL_NO_ERROR
