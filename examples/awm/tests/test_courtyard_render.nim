## Native GPU regression: normal/depth integration, SSAO/bloom, and sky motion.
## nim r --out:build/test_courtyard_render tests/test_courtyard_render.nim
import std/[math, os]
import opengl, pixie, vmath, windy
# `post` names the post-processor below, so the module goes by another name.
import ../src/scene/courtyard, ../src/scene/post as postfx, ../src/paths

const Width = 640
const Height = 400
let window = newWindow("AWM material verification", ivec2(Width, Height))
window.makeContextCurrent()
loadExtensions()
let
  eye = vec3(0, 12.05, 13.08)
  view = lookAt(eye, eye + vec3(0, -sin(0.7659'f32), -cos(0.7659'f32)), vec3(0, 1, 0))
  projection = perspective(42.0'f32, Width.float32 / Height, 0.1'f32, 100.0'f32)
  vp = projection * view
var post = initPostFx()
post.settings.enabled = true
post.settings.occlusion = true
post.settings.bloom = true
putEnv("AWM_STONE_NORMALS", "1")
let detailed = initCourtyardRenderer()
putEnv("AWM_STONE_NORMALS", "0")
let flat = initCourtyardRenderer()
delEnv("AWM_STONE_NORMALS")

proc readColor(): Image =
  result = newImage(Width, Height)
  glReadPixels(0, 0, Width, Height, GL_RGBA, GL_UNSIGNED_BYTE, result.data[0].addr)

proc normals(renderer: CourtyardRenderer, occluder = false): Image =
  post.beginScene(ivec2(Width, Height), 0.1, 100)
  glDepthMask(GL_TRUE)
  glClearColor(0, 0, 0, 1)
  glClearDepth(1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT or GL_STENCIL_BUFFER_BIT)
  renderer.draw(vp, eye, 0, 1)
  if occluder:
    # A nearer opaque object must mask out the floor's material normals.
    glEnable(GL_SCISSOR_TEST)
    glScissor(Width div 2 - 20, Height div 2 - 20, 40, 40)
    glClearDepth(0.5)
    glClear(GL_DEPTH_BUFFER_BIT)
    glClearDepth(1)
    glDisable(GL_SCISSOR_TEST)
  doAssert post.beginMaterialNormals()
  renderer.draw(vp, eye, 0, 1, normalsOnly = true, normalView = view)
  result = readColor()
  post.endMaterialNormals()
  post.applyOcclusion(projection)
  post.present(ivec2(Width, Height))
  doAssert glGetError() == GL_NO_ERROR, "Normal/SSAO/bloom pass produced a GL error"

let
  withDetail = normals(detailed)
  withoutDetail = normals(flat)
  masked = normals(detailed, true)
var changed = 0
var valid = 0
var sky = 0
for i, pixel in withDetail.data:
  if pixel.a > 0:
    inc valid
    let other = withoutDetail.data[i]
    if abs(int(pixel.r) - int(other.r)) + abs(int(pixel.g) - int(other.g)) +
        abs(int(pixel.b) - int(other.b)) > 5: inc changed
  else: inc sky
doAssert valid > Width * Height div 2
doAssert changed > valid div 8, "Normal maps must visibly perturb the rendered surface"
doAssert sky > Width * Height div 30, "Sky must stay outside the normal pass"
for y in Height div 2 - 18 ..< Height div 2 + 18:
  for x in Width div 2 - 18 ..< Width div 2 + 18:
    doAssert masked[x, y].a == 0, "Occluded floor normals leaked through foreground depth"

proc skyFrame(time: float32): Image =
  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  glViewport(0, 0, Width, Height)
  glDepthMask(GL_TRUE)
  glClearDepth(1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  detailed.drawSky(vp, eye, time)
  result = readColor()
  var depth: float32
  glReadPixels(Width div 2, Height div 2, 1, 1, GL_DEPTH_COMPONENT, cGL_FLOAT, depth.addr)
  doAssert abs(depth - 1) < 0.000001, "Sky must not write near depth"
  doAssert glGetError() == GL_NO_ERROR

let first = skyFrame(0)
let later = skyFrame(18)
var animated = 0
var stars = 0
for i, p in first.data:
  let q = later.data[i]
  if abs(int(p.r) - int(q.r)) + abs(int(p.g) - int(q.g)) +
      abs(int(p.b) - int(q.b)) > 8: inc animated
  if max(p.r, max(p.g, p.b)) > 90: inc stars
doAssert animated > 250, "Layered sky must drift and twinkle over time"
doAssert stars > 150, "Night sky must contain a dense visible starfield"

for name in ["stone-slab-normal.png"]:
  let texture = readImage(artworkRoot() / "battlefield/textures" / name)
  doAssert texture.width == 512 and texture.height == 512
  var error = 0.0'f32
  for p in texture.data:
    let n = vec3(p.r.float32, p.g.float32, p.b.float32) / 127.5'f32 - vec3(1)
    error = max(error, abs(length(n) - 1))
    doAssert p.a == 255, "Normal vector RGB must not be premultiplied"
  doAssert error < 0.012, "Normal maps must encode unit vectors"
echo "PASS: mapped normals (", changed, " pixels), foreground masking, SSAO/bloom, ",
  stars, " star pixels, ", animated, " animated sky pixels, linear unit-vector textures."
