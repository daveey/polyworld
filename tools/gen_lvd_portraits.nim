import
  std/os,
  chroma, gltf, opengl, pixie, vmath, windy,
  polyworld/[characters, chargen, shadows],
  ../examples/light_vs_dark/[appearances, assets, content]

const RenderSize = 512

proc renderPortrait(
  window: Window,
  scene: CharacterScene,
  model: CharacterModel,
  height: float32
): Image =
  ## Captures the approved character's upper body with the game's shader.
  let
    target = vec3(0, height * 0.82'f, 0)
    eye = target + vec3(0, 0.5'f, -10)
    view = lookAt(eye, target, vec3(0, 1, 0))
    extent = height * 0.39'f
    projection = ortho(-extent, extent, -extent, extent, 0.02'f, 50'f)
    clip = model.clipIndex("Idle_Loop")
    facing = PI.float32 + 0.25'f
  for frame in 0 ..< 4:
    sunDepthPasses(window.size):
      scene.sunDepthPass = true
      scene.drawCharacter(model, vec3(0), facing, clip, 0.35'f)
    scene.sunDepthPass = false
    scene.beginCharacters(window, view, projection, eye)
    scene.renderer.clearScreen(color(0.10, 0.12, 0.16, 1))
    glEnable(GL_MULTISAMPLE)
    scene.drawCharacter(model, vec3(0), facing, clip, 0.35'f)
    scene.finishCharacters()
    if frame == 3:
      result = newImage(RenderSize, RenderSize)
      glReadPixels(
        0,
        0,
        RenderSize.GLsizei,
        RenderSize.GLsizei,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        result.data[0].addr
      )
      result.flipVertical()
    window.swapBuffers()
    pollEvents()

proc main() =
  ## Writes all LvD HUD portraits from the actual game roster and loader.
  let
    manifest = readManifest(ChargenLibrary)
    roster = readCharacterRoster()
    window = newWindow(
      "LvD portraits",
      ivec2(RenderSize, RenderSize),
      visible = false,
      vsync = false,
      msaa = msaa4x
    )
  makeContextCurrent(window)
  loadExtensions()
  initSunShadows(lightRadius = 4, lightDistance = 10)
  let scene = newCharacterScene(window)
  scene.useToonShading()
  scene.setToonHour(12)
  for player in 0'i32 ..< FactionCount:
    for kind in UnitKind:
      let
        model = loadUnitModel(manifest, roster.players[player][kind.ord], kind)
        portrait = renderPortrait(window, scene, model, UnitHeights[kind])
        output = unitPortraitPath(player, kind)
      createDir(output.parentDir)
      portrait.resize(256, 256).writeFile(output)
      echo output
  window.close()

main()
