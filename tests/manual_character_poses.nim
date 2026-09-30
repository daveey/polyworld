## Requires desktop OpenGL and LvD character assets for pixel comparisons.

import
  opengl, pixie, vmath, windy,
  polyworld/[characters, chargen, shadows, toon],
  ../examples/light_vs_dark/[appearances, assets, content, factions]

proc clearFrame(size: IVec2) =
  ## Restores the main framebuffer before comparing color passes.
  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  glViewport(0, 0, size.x, size.y)
  glDepthMask(GL_TRUE)
  glClearColor(0, 0, 0, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

proc readColors(size: IVec2): Image =
  ## Reads pixels directly without presentation or resizing.
  result = newImage(size.x, size.y)
  glReadPixels(
    0, 0, size.x, size.y, GL_RGBA, GL_UNSIGNED_BYTE, result.data[0].addr
  )

proc readDepth(): seq[float32] =
  ## Reads the active shadow map, including its cleared background.
  var viewport: array[4, GLint]
  glGetIntegerv(GL_VIEWPORT, viewport[0].addr)
  result.setLen(viewport[2].int * viewport[3].int)
  glReadPixels(
    0, 0, viewport[2], viewport[3], GL_DEPTH_COMPONENT, cGL_FLOAT,
    result[0].addr
  )

block:
  let window = newWindow(
    "Character pose verification",
    ivec2(256, 256),
    vsync = false
  )
  defer:
    window.close()
  window.makeContextCurrent()
  loadExtensions()
  pollEvents()
  initSunShadows()
  var cache: UnitModelCache
  let
    scene = CharacterScene(toon: newToonContext(), shading: ToonCharacters)
    manifest = readManifest(ChargenLibrary)
    roster = readCharacterRoster([Emerald, WetAsphalt])
    model = cache.loadUnitModel(
      manifest, roster.players[0][PeonUnit.ord], PeonUnit
    )
    clip = model.clipIndex(unitClip(PeonUnit, RunAnimation))
  var variant = roster.players[0][PeonUnit.ord]
  variant.skinRgb = [0.2'f, 0.4'f, 0.7'f]
  let
    secondModel = cache.loadUnitModel(manifest, variant, PeonUnit)
    freshModel = loadUnitModel(manifest, variant, PeonUnit)
  scene.toon.view = lookAt(vec3(2, 2, 4), vec3(0, 0.6, 0), vec3(0, 1, 0))
  scene.toon.proj = ortho(-1.2'f, 1.2'f, -1.2'f, 1.2'f, 0.1'f, 100'f)
  scene.toon.cameraPosition = vec3(2, 2, 4)
  var first, second: CharacterPose
  scene.prepareCharacter(first, model, vec3(-0.4, 0, 0), 0.3, clip, 0.25)
  scene.prepareCharacter(second, secondModel, vec3(0.4, 0, 0), -0.5, clip, 0.75)
  sunShadowsEnabled = false
  clearFrame(window.size)
  scene.drawCharacter(model, vec3(-0.4, 0, 0), 0.3, clip, 0.25)
  scene.drawCharacter(freshModel, vec3(0.4, 0, 0), -0.5, clip, 0.75)
  let reference = readColors(window.size)
  clearFrame(window.size)
  scene.drawCharacter(first)
  scene.drawCharacter(second)
  doAssert readColors(window.size).data == reference.data
  var visible = 0
  for pixel in reference.data:
    if pixel.r > 0 or pixel.g > 0 or pixel.b > 0:
      inc visible
  doAssert visible > 100, "Characters must cover visible pixels."
  echo "Prepared and immediate character color passes match"

  sunShadowsEnabled = true
  scene.sunDepthPass = true
  for step in 0 .. 1:
    beginSunDepthPass(step)
    scene.drawCharacter(model, vec3(-0.4, 0, 0), 0.3, clip, 0.25)
    scene.drawCharacter(freshModel, vec3(0.4, 0, 0), -0.5, clip, 0.75)
    let referenceDepth = readDepth()
    endSunDepthPass(window.size)
    beginSunDepthPass(step)
    scene.drawCharacter(first)
    scene.drawCharacter(second)
    doAssert readDepth() == referenceDepth
    endSunDepthPass(window.size)
    var covered = false
    for depth in referenceDepth:
      if depth < 1:
        covered = true
    doAssert covered, "Characters must cast shadows."
  doAssert glGetError() == GL_NO_ERROR
  echo "Prepared and immediate character shadow passes match"
