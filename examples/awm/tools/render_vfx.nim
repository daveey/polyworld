## Reproducible native VFX gallery, using the same renderer as the game.
## nim c -r --out:build/render-vfx tools/render_vfx.nim [--sequence]
import std/[os, strformat]
import opengl, pixie, vmath, windy
import ../src/core/core, ../src/paths, ../src/vfx/vfxrenderer

const
  Width = 1536
  Height = 1024
  CellWidth = Width div 3
  CellHeight = Height div 2
  Kinds = [SwordsIntoTheWindVfx, SwordAndShieldVfx, MeleeVfx,
    SwordClashVfx, SwordBreakVfx, OozeSplatVfx]
  Names = ["SWORDS INTO THE WIND", "SWORD AND SHIELD", "MELEE",
    "SWORD CLASH", "SWORD BREAK", "OOZE SPLAT"]
  KeyAges = [0.55'f32, 0.48'f32, 0.38'f32, 0.35'f32, 0.54'f32, 0.72'f32]

let
  root = currentSourcePath().parentDir.parentDir
  artwork = artworkRoot()
  output = artwork / "vfx/previews"
  frames = root / "build/vfx-gallery"
  sequence = "--sequence" in commandLineParams()
  window = newWindow("AWM — VFX review", ivec2(Width, Height))
window.makeContextCurrent()
loadExtensions()
var renderer = initVfxRenderer(artwork / "vfx/textures")
let
  eye = vec3(0, 4.2, 6.8)
  viewProjection = ortho(-2.65'f32, 2.65'f32, -2.45'f32, 2.45'f32,
    0.1'f32, 30.0'f32) * lookAt(eye, vec3(0, 0.62, 0), vec3(0, 1, 0))
  font = readFont(artwork / "cards/fonts/Grenze-SemiBold.ttf")
font.size = 29
font.paint.color = parseHtmlColor("#e9c99b")
createDir(output)
if sequence: createDir(frames)

for frame in 0 .. (if sequence: 74 else: 0):
  pollEvents()
  if window.closeRequested: break
  glEnable(GL_SCISSOR_TEST)
  for i, kind in Kinds:
    let
      x = (i mod 3) * CellWidth
      y = Height - ((i div 3) + 1) * CellHeight
    glViewport(x.GLint, y.GLint, CellWidth.GLsizei, CellHeight.GLsizei)
    glScissor((x + 2).GLint, (y + 2).GLint,
      (CellWidth - 4).GLsizei, (CellHeight - 4).GLsizei)
    glClearColor(0.046, 0.059, 0.066, 1)
    glDepthMask(GL_TRUE)
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
    var effect = newVfx(kind, creatureChoice(0, 1), vec3(0), 20260916 + i * 7919)
    effect.elapsed = if sequence: frame.float32 / 30 else: KeyAges[i]
    renderer.clear()
    if effect.elapsed < effect.duration:
      renderer.addEffects([effect], eye)
    renderer.draw(viewProjection)
  glDisable(GL_SCISSOR_TEST)
  let shot = newImage(Width, Height)
  glReadPixels(0, 0, Width, Height, GL_RGBA, GL_UNSIGNED_BYTE, shot.data[0].addr)
  shot.flipVertical()
  for i, name in Names:
    let
      x = (i mod 3) * CellWidth + 22
      y = (i div 3) * CellHeight + 25
    shot.fillText(font, name, translate(vec2(x.float32, y.float32)))
  shot.writeFile(if sequence: frames / &"frame-{frame:04}.png"
    else: output / "warrior-and-ooze.png")
  window.swapBuffers()
echo "VFX gallery: ", (if sequence: frames else: output / "warrior-and-ooze.png")
