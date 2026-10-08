## Toon (cel) shading for gltf node trees, in the classic console style:
##
## 1. Per-vertex Lambert from exactly one light: `max(dot(N, L), 0)`, no
##    shadow maps, no ambient occlusion, no other lights. One light means one
##    lit region and one shadow region, so the silhouette stays readable.
## 2. That intensity is used as a texture coordinate into a 256 wide ramp:
##    black up to about 47%, white from about 53%, and a short gradient
##    between. The tiny gradient gives the slightly soft terminator most cel
##    shaders miss; the ramp is data, so it can be reshaped.
## 3. White maps to a hand-picked highlight colour, black to a shadow colour,
##    and the result multiplies the albedo. Palettes are per world state
##    (time of day x weather); a set of twelve lives in `ToonPalettes`.
##
## An optional rim light is available through `rimColor`; its alpha is the
## strength.
## Contexts can also select smooth diffuse light, unlit albedo, or world
## normals, and opt into per-pixel Lambert evaluation or neutral gray materials.
##
## Unlit materials and node names in `unlitNodes` preserve their albedo,
## without palette coloration, shadows, or rim lighting.
##
## The shaders are written with Shady and draw the same GPU buffers the gltf
## PBR renderer uploads, so a scene can switch between the two per frame.

import
  std/[math, sets, tables],
  opengl, vmath, chroma, pixie, shady,
  gltf,
  frustums, shadowmeshes, shadows

## Shaders

var
  toonModel: Uniform[Mat4]
  toonNormalMatrix: Uniform[Mat3]
  toonView: Uniform[Mat4]
  toonProj: Uniform[Mat4]
  toonUseSkinning: Uniform[bool]
  toonJointMatrices: Uniform[array[128, Mat4]]
  toonLightDirection: Uniform[Vec3]   # direction the light travels
  toonCameraPosition: Uniform[Vec3]
  toonBaseColorTexture: Uniform[Sampler2d]
  toonBaseColorFactor: Uniform[Vec4]
  toonEmissiveTexture: Uniform[Sampler2d]
  toonEmissiveFactor: Uniform[Vec3]
  toonAlphaCutoff: Uniform[float32]
  toonRamp: Uniform[Sampler2d]
  toonHighlightColor: Uniform[Vec4]
  toonShadowColor: Uniform[Vec4]
  toonRimColor: Uniform[Vec4]
  toonUnlit: Uniform[bool]           # always in the highlight band
  toonTint: Uniform[Vec4]
  toonLightingMode: Uniform[int32]
  toonPerPixelLighting: Uniform[bool]
  toonNeutralMaterial: Uniform[bool]
  # Sun shadow map sampling, fed from polyworld/shadows each frame. Two
  # maps at neighbouring quantized sun steps, cross-faded by toonShadowStep
  # so shadows dissolve toward the next sun position instead of shimmering.
  toonShadowMvp0: Uniform[Mat4]
  toonShadowMvp1: Uniform[Mat4]
  toonShadowMap0: Uniform[Sampler2dShadow]
  toonShadowMap1: Uniform[Sampler2dShadow]
  toonShadowStep: Uniform[float32]
  toonShadowsOn: Uniform[float32]
  toonShadowStrength: Uniform[float32]
  toonShadowBias: Uniform[float32]
  toonShadowTexel: Uniform[float32]
  toonShadowSoftness: Uniform[float32]
  toonShadingStrength: Uniform[float32]
  toonLightLevel: Uniform[float32]

proc toonLitFraction0(worldPos: Vec3): float32 =
  ## Raw lit fraction from the first shadow step, 0 shadowed .. 1 clear: a
  ## 3x3 grid of hardware-PCF taps, each itself bilinearly filtered by the
  ## comparison sampler. Positions outside the map count as lit.
  result = 1.0'f
  let
    shadowCoord: Vec4 = toonShadowMvp0 * vec4(worldPos, 1.0'f)
    su = shadowCoord.x * 0.5'f + 0.5'f
    sv = shadowCoord.y * 0.5'f + 0.5'f
    sd = shadowCoord.z * 0.5'f + 0.5'f - toonShadowBias
  if su > 0.0'f and su < 1.0'f and sv > 0.0'f and sv < 1.0'f and sd < 1.0'f:
    let spread = toonShadowTexel * toonShadowSoftness
    var lit = 0.0'f32
    lit = lit + texture(toonShadowMap0, vec3(su - spread, sv - spread, sd))
    lit = lit + texture(toonShadowMap0, vec3(su, sv - spread, sd))
    lit = lit + texture(toonShadowMap0, vec3(su + spread, sv - spread, sd))
    lit = lit + texture(toonShadowMap0, vec3(su - spread, sv, sd))
    lit = lit + texture(toonShadowMap0, vec3(su, sv, sd))
    lit = lit + texture(toonShadowMap0, vec3(su + spread, sv, sd))
    lit = lit + texture(toonShadowMap0, vec3(su - spread, sv + spread, sd))
    lit = lit + texture(toonShadowMap0, vec3(su, sv + spread, sd))
    lit = lit + texture(toonShadowMap0, vec3(su + spread, sv + spread, sd))
    result = lit / 9.0'f

proc toonLitFraction1(worldPos: Vec3): float32 =
  ## The same for the second shadow step.
  result = 1.0'f
  let
    shadowCoord: Vec4 = toonShadowMvp1 * vec4(worldPos, 1.0'f)
    su = shadowCoord.x * 0.5'f + 0.5'f
    sv = shadowCoord.y * 0.5'f + 0.5'f
    sd = shadowCoord.z * 0.5'f + 0.5'f - toonShadowBias
  if su > 0.0'f and su < 1.0'f and sv > 0.0'f and sv < 1.0'f and sd < 1.0'f:
    let spread = toonShadowTexel * toonShadowSoftness
    var lit = 0.0'f32
    lit = lit + texture(toonShadowMap1, vec3(su - spread, sv - spread, sd))
    lit = lit + texture(toonShadowMap1, vec3(su, sv - spread, sd))
    lit = lit + texture(toonShadowMap1, vec3(su + spread, sv - spread, sd))
    lit = lit + texture(toonShadowMap1, vec3(su - spread, sv, sd))
    lit = lit + texture(toonShadowMap1, vec3(su, sv, sd))
    lit = lit + texture(toonShadowMap1, vec3(su + spread, sv, sd))
    lit = lit + texture(toonShadowMap1, vec3(su - spread, sv + spread, sd))
    lit = lit + texture(toonShadowMap1, vec3(su, sv + spread, sd))
    lit = lit + texture(toonShadowMap1, vec3(su + spread, sv + spread, sd))
    result = lit / 9.0'f

proc sunShadowFactor(worldPos: Vec3): float32 =
  ## How lit by the sun a fragment is, cross-fading between the two
  ## quantized sun steps. The result already folds in the shadow strength.
  result = 1.0'f
  if toonShadowsOn > 0.5'f:
    var lit = toonLitFraction0(worldPos)
    if toonShadowStep > 0:
      lit = mix(lit, toonLitFraction1(worldPos), toonShadowStep)
    result = 1.0'f - (1.0'f - lit) * toonShadowStrength

proc toonVert(
  vertexPosition: Vec3,
  vertexColor: Vec4,
  vertexNormal: Vec3,
  vertexUV: Vec2,
  vertexTangent: Vec4,
  vertexJoints: UVec4,
  vertexWeights: Vec4,
  vertexUV1: Vec2,
  gl_Position: var Vec4,
  worldPos: var Vec3,
  color: var Vec4,
  normal: var Vec3,
  uv: var Vec2,
  lightIntensity: var float32
) =
  var skin = mat4(1.0'f)
  if toonUseSkinning:
    skin =
      vertexWeights.x * toonJointMatrices[vertexJoints.x.int] +
      vertexWeights.y * toonJointMatrices[vertexJoints.y.int] +
      vertexWeights.z * toonJointMatrices[vertexJoints.z.int] +
      vertexWeights.w * toonJointMatrices[vertexJoints.w.int]
  let
    skinnedPosition = skin * vec4(vertexPosition, 1.0'f)
    skinnedNormal = (skin * vec4(vertexNormal, 0.0'f)).xyz
  worldPos = (toonModel * skinnedPosition).xyz
  color = vertexColor
  uv = vertexUV
  normal = normalize(toonNormalMatrix * skinnedNormal)
  # Step 1: Lambert from the one light, computed per vertex like the
  # GameCube did and interpolated across the triangle.
  let toLight: Vec3 = normalize(-toonLightDirection)
  lightIntensity = max(dot(normal, toLight), 0.0'f)
  gl_Position = toonProj * toonView * vec4(worldPos, 1.0'f)

proc toonFrag(
  worldPos: Vec3,
  color: Vec4,
  normal: Vec3,
  uv: Vec2,
  lightIntensity: float32,
  fragColor: var Vec4
) =
  var albedo: Vec4 = texture(toonBaseColorTexture, uv) * toonBaseColorFactor * color
  if albedo.a < toonAlphaCutoff:
    discardFragment()
  var n: Vec3 = normalize(normal)
  if not gl_FrontFacing:
    n = -n
  if toonLightingMode == 3:
    fragColor = vec4(n * 0.5'f + vec3(0.5'f), albedo.a) * toonTint
    return
  if toonNeutralMaterial:
    albedo = vec4(0.8'f, 0.8'f, 0.8'f, albedo.a)
  if toonUnlit or toonLightingMode == 2:
    fragColor = albedo * toonTint
    return
  var lambert = lightIntensity
  if toonPerPixelLighting or toonLightingMode == 1:
    lambert = max(dot(n, normalize(-toonLightDirection)), 0.0'f)
  # Step 2: the intensity — scaled by the sun shadow test, flattened by the
  # shading strength when the sky is dark — is a texture coordinate into
  # the ramp.
  let
    sunFactor = sunShadowFactor(worldPos)
    intensity =
      (1.0'f - toonShadingStrength +
        lambert * sunFactor * toonShadingStrength) * toonLightLevel
  var band = texture(toonRamp, vec2(intensity, 0.5'f)).r
  if toonLightingMode == 1:
    band = clamp(intensity, 0.0'f, 1.0'f)
  # Step 3: two hand-picked colours, then the albedo on top.
  var lit: Vec3 = mix(toonShadowColor.rgb, toonHighlightColor.rgb, band)
  let
    eye: Vec3 = normalize(toonCameraPosition - worldPos)
    facing = 1.0'f - abs(dot(eye, n))
    rim = facing * facing * facing * facing
  lit = mix(lit, toonRimColor.rgb, rim * toonRimColor.a)
  var emissive: Vec3 = texture(toonEmissiveTexture, uv).rgb * toonEmissiveFactor
  if toonNeutralMaterial:
    emissive = vec3(0.0'f)
  fragColor = vec4(lit * albedo.rgb + emissive, albedo.a) * toonTint

## Sun depth pass: the same skinned vertex path projected by the sun's
## light matrix instead of the camera, with the base color's alpha cutout
## kept, so characters cast correct shadows into the shared sun map
## (polyworld/shadows). Attribute names match the gltf convention, so the
## primitives' existing vertex arrays bind unchanged.

var toonDepthLightMvp: Uniform[Mat4]

proc toonDepthVert(
  vertexPosition: Vec3,
  vertexUV: Vec2,
  vertexJoints: UVec4,
  vertexWeights: Vec4,
  gl_Position: var Vec4,
  uv: var Vec2
) =
  var skin = mat4(1.0'f)
  if toonUseSkinning:
    skin =
      vertexWeights.x * toonJointMatrices[vertexJoints.x.int] +
      vertexWeights.y * toonJointMatrices[vertexJoints.y.int] +
      vertexWeights.z * toonJointMatrices[vertexJoints.z.int] +
      vertexWeights.w * toonJointMatrices[vertexJoints.w.int]
  gl_Position =
    toonDepthLightMvp * toonModel * (skin * vec4(vertexPosition, 1.0'f))
  uv = vertexUV

proc toonDepthFrag(uv: Vec2, fragColor: var Vec4) =
  let albedo: Vec4 = texture(toonBaseColorTexture, uv) * toonBaseColorFactor
  if albedo.a < toonAlphaCutoff:
    discardFragment()
  fragColor = vec4(1.0'f, 1.0'f, 1.0'f, 1.0'f)

## Background: a full-screen sky-to-ground gradient in the palette's
## colours, so the character is not floating in a void of another palette.

var
  toonSkyColor: Uniform[Vec4]       # top of the screen
  toonHorizonColor: Uniform[Vec4]   # at horizonHeight
  toonGroundColor: Uniform[Vec4]    # bottom of the screen
  toonHorizonHeight: Uniform[float32]  # 0 bottom .. 1 top

proc toonBackgroundVert(
  vertexPosition: Vec3,
  gl_Position: var Vec4,
  screenY: var float32
) =
  screenY = vertexPosition.y * 0.5'f + 0.5'f
  gl_Position = vec4(vertexPosition.x, vertexPosition.y, 1.0'f, 1.0'f)

proc toonBackgroundFrag(screenY: float32, fragColor: var Vec4) =
  let horizon = clamp(toonHorizonHeight, 0.01'f, 0.99'f)
  if screenY > horizon:
    let t = (screenY - horizon) / (1.0'f - horizon)
    fragColor = mix(toonHorizonColor, toonSkyColor, t)
  else:
    let t = screenY / horizon
    fragColor = mix(toonGroundColor, toonHorizonColor, t)

const
  ToonShaderTarget =
    when defined(emscripten):
      glsl3WebGL
    else:
      glsl4Desktop
  ToonVertSrc* = toShader(toonVert, ToonShaderTarget, shaderVertex)
  ToonFragSrc* = toShader(toonFrag, ToonShaderTarget, shaderFragment)
  ToonDepthVertSrc* = toShader(toonDepthVert, ToonShaderTarget, shaderVertex)
  ToonDepthFragSrc* = toShader(toonDepthFrag, ToonShaderTarget, shaderFragment)
  ToonBackgroundVertSrc* =
    toShader(toonBackgroundVert, ToonShaderTarget, shaderVertex)
  ToonBackgroundFragSrc* =
    toShader(toonBackgroundFrag, ToonShaderTarget, shaderFragment)

## Light

# The toon light travels this way: from the upper front-left at a low angle
# (about 25 degrees), so it rakes across characters and terrain. A light
# from nearly overhead puts every surface a top-down camera can see in the
# lit band, which reads as flat.
const ToonLightDirection* = normalize(vec3(0.7, -0.4, -0.6))

## Palettes

type ToonPalette* = object
  name*: string
  highlight*: Color
  shadow*: Color

proc palette(name, highlight, shadow: string): ToonPalette =
  ToonPalette(
    name: name,
    highlight: parseHtmlColor("#" & highlight),
    shadow: parseHtmlColor("#" & shadow)
  )

# Highlight/shadow pairs per time of day and weather.
const ToonPalettes* = [
  palette("Day", "FFFFFF", "A39892"),
  palette("Morning", "F0EAE3", "BCB7CB"),
  palette("Afternoon", "D8C37F", "B09070"),
  palette("Evening", "8D8C9A", "7E7885"),
  palette("Dusk", "A19AA3", "746676"),
  palette("Night", "879EB5", "5D6E99"),
  palette("Day rainy", "ADBBB7", "8E978D"),
  palette("Morning rainy", "B8BDB8", "9AA494"),
  palette("Afternoon rainy", "999187", "888177"),
  palette("Evening rainy", "8E877D", "7A7368"),
  palette("Dusk rainy", "90887A", "746676"),
  palette("Night rainy", "4B6690", "4C595A"),
]

proc mix*(a, b: ToonPalette, t: float32): ToonPalette =
  ToonPalette(
    name: (if t < 0.5: a.name else: b.name),
    highlight: mix(a.highlight, b.highlight, t),
    shadow: mix(a.shadow, b.shadow, t)
  )

# The sunny palettes laid along a 24 hour day: hour -> index into
# ToonPalettes. Dusk doubles as dawn.
const DayCycle = [
  (0.0'f32, 5), (4.0'f32, 5), (6.0'f32, 4), (8.0'f32, 1), (11.0'f32, 0),
  (15.0'f32, 0), (17.0'f32, 2), (19.0'f32, 3), (20.5'f32, 4), (22.0'f32, 5),
  (24.0'f32, 5),
]

proc paletteAtHour*(hour: float32): ToonPalette =
  ## The palette for a time of day, blending between the sunny palettes:
  ## night until 4, dawn at 6, morning at 8, full day 11 to 15, afternoon at
  ## 17, evening at 19, dusk at 20:30, night from 22. Hours wrap.
  let h = ((hour mod 24) + 24) mod 24
  for i in 0 ..< DayCycle.len - 1:
    let (h0, p0) = DayCycle[i]
    let (h1, p1) = DayCycle[i + 1]
    if h <= h1:
      let t = if h1 > h0: (h - h0) / (h1 - h0) else: 0'f32
      return mix(ToonPalettes[p0], ToonPalettes[p1], t)
  ToonPalettes[DayCycle[^1][1]]

## Ramp

const RampWidth = 256

proc rampImage*(shadowEnd = 0.47'f32, highlightStart = 0.53'f32): Image =
  ## The shading ramp: black, a short linear rise, white. Both edges are
  ## fractions of the full intensity range.
  result = newImage(RampWidth, 1)
  for x in 0 ..< RampWidth:
    let
      t = x.float32 / (RampWidth - 1).float32
      v = clamp((t - shadowEnd) / max(highlightStart - shadowEnd, 0.001'f32), 0, 1)
      byte = (v * 255).round.uint8
    result.data[x] = rgbx(byte, byte, byte, 255)

## Context

type
  ToonLighting* = enum
    BandedLighting, SmoothLighting, UnlitLighting, NormalLighting

  ToonUniforms = object
    model, normalMatrix, view, proj: GLint
    useSkinning, jointMatrices: GLint
    lightDirection, cameraPosition: GLint
    baseColorTexture, baseColorFactor: GLint
    emissiveTexture, emissiveFactor: GLint
    alphaCutoff, ramp: GLint
    highlightColor, shadowColor, rimColor, unlit, tint: GLint
    lightingMode, perPixelLighting, neutralMaterial: GLint
    shadowMvp0, shadowMvp1, shadowMap0, shadowMap1, shadowStep: GLint
    shadowsOn, shadowStrength: GLint
    shadowBias, shadowTexel, shadowSoftness, shadingStrength, lightLevel: GLint

  ToonDepthUniforms = object
    model, lightMvp, useSkinning, jointMatrices: GLint
    baseColorTexture, baseColorFactor, alphaCutoff: GLint

  BackgroundUniforms = object
    sky, horizon, ground, horizonHeight: GLint

  ToonMeshPose* = object
    node*: Node
    unlit*: bool
    transform*: Mat4
    normal*: Mat3
    joints*: seq[Mat4]
    boundsNode: Node
    boundsMesh: Mesh
    boundsPrimitives: seq[Primitive]
    geometryVersions: seq[uint64]
    bindBounds: seq[AABounds]
    boundsJointCount: int
    boundsValid: bool
    weightScale: float32
    weightMinimum: float32

  ToonPose* = object
    meshes*: seq[ToonMeshPose]
    meshCount*: int
    bounds*: AABounds
    boundsValid*: bool

  ShadowSource = object
    primitive: Primitive
    version: uint64
    alpha: AlphaMode

  ShadowGeometry = object
    sources: seq[ShadowSource]
    primitives: seq[Primitive]

  ToonBlend = object
    node: Node
    primitive: Primitive
    pose: ptr ToonMeshPose

  ToonContext* = ref object
    shader: GLuint
    uniforms: ToonUniforms
    depthShader: GLuint
    depthUniforms: ToonDepthUniforms
    backgroundShader: GLuint
    backgroundUniforms: BackgroundUniforms
    backgroundVao, backgroundVbo: GLuint
    rampTexture: GLuint
    jointMatrices: seq[Mat4]
    blended: seq[ToonBlend]
    shadowGeometry: Table[pointer, ShadowGeometry]
    transform*: Mat4             ## model transform applied above the root
    view*, proj*: Mat4
    cameraPosition*: Vec3
    tint*: Color                 ## multiplies the final colour
    lightDirection*: Vec3        ## direction the light travels
    highlightColor*: Color
    shadowColor*: Color
    rimColor*: Color             ## alpha is the rim strength
    lighting*: ToonLighting      ## Selects bands, smooth light, or inspection.
    perPixelLighting*: bool      ## Evaluates Lambert after normal interpolation.
    neutralMaterial*: bool       ## Uses gray albedo while retaining cutouts.
    unlitNodes*: HashSet[string] ## mesh nodes drawn always full-bright
    skyColor*, horizonColor*, groundColor*: Color  ## background gradient
    horizonHeight*: float32      ## where the horizon sits, 0 bottom .. 1 top

var blackTexture: GLuint

proc ensureBlackTexture(): GLuint =
  ## A 1x1 black texel for materials that have no emissive map.
  if blackTexture == 0:
    glGenTextures(1, blackTexture.addr)
    glBindTexture(GL_TEXTURE_2D, blackTexture)
    var pixel = [0'u8, 0, 0, 255]
    glTexImage2D(
      GL_TEXTURE_2D, 0, GL_RGBA.GLint, 1, 1, 0,
      GL_RGBA, GL_UNSIGNED_BYTE, pixel[0].addr
    )
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
    glBindTexture(GL_TEXTURE_2D, 0)
  blackTexture

proc uploadRamp(ctx: ToonContext, image: Image) =
  if ctx.rampTexture == 0:
    glGenTextures(1, ctx.rampTexture.addr)
  glBindTexture(GL_TEXTURE_2D, ctx.rampTexture)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_RGBA.GLint, image.width.GLint, image.height.GLint,
    0, GL_RGBA, GL_UNSIGNED_BYTE, image.data[0].addr
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)

proc setRamp*(ctx: ToonContext, image: Image) =
  ## Replaces the ramp with any width x 1 image (red channel is read).
  ctx.uploadRamp(image)

proc setPalette*(ctx: ToonContext, palette: ToonPalette) =
  ## Sets the character colours and derives a background from them: the
  ## horizon glows with the highlight, the sky above cools toward the shadow
  ## colour, the ground below is the shadow colour darkened a little.
  ctx.highlightColor = palette.highlight
  ctx.shadowColor = palette.shadow
  ctx.horizonColor = mix(palette.highlight, palette.shadow, 0.25)
  ctx.skyColor = mix(palette.highlight, palette.shadow, 0.8)
  ctx.groundColor = palette.shadow * 0.8
  ctx.groundColor.a = 1
  ctx.horizonHeight = 0.42

proc newToonContext*(): ToonContext =
  result = ToonContext(
    transform: mat4(),
    lightDirection: ToonLightDirection,
    tint: color(1, 1, 1, 1),
    rimColor: color(1, 1, 1, 0),
  )
  result.setPalette(ToonPalettes[0])
  result.shader = compileShaderFiles(ToonVertSrc, ToonFragSrc)
  template loc(field: untyped, name: string) =
    result.uniforms.field = glGetUniformLocation(result.shader, name)
  loc(model, "toonModel")
  loc(normalMatrix, "toonNormalMatrix")
  loc(view, "toonView")
  loc(proj, "toonProj")
  loc(useSkinning, "toonUseSkinning")
  loc(jointMatrices, "toonJointMatrices")
  loc(lightDirection, "toonLightDirection")
  loc(cameraPosition, "toonCameraPosition")
  loc(baseColorTexture, "toonBaseColorTexture")
  loc(baseColorFactor, "toonBaseColorFactor")
  loc(emissiveTexture, "toonEmissiveTexture")
  loc(emissiveFactor, "toonEmissiveFactor")
  loc(alphaCutoff, "toonAlphaCutoff")
  loc(ramp, "toonRamp")
  loc(highlightColor, "toonHighlightColor")
  loc(shadowColor, "toonShadowColor")
  loc(rimColor, "toonRimColor")
  loc(unlit, "toonUnlit")
  loc(tint, "toonTint")
  loc(lightingMode, "toonLightingMode")
  loc(perPixelLighting, "toonPerPixelLighting")
  loc(neutralMaterial, "toonNeutralMaterial")
  loc(shadowMvp0, "toonShadowMvp0")
  loc(shadowMvp1, "toonShadowMvp1")
  loc(shadowMap0, "toonShadowMap0")
  loc(shadowMap1, "toonShadowMap1")
  loc(shadowStep, "toonShadowStep")
  loc(shadowsOn, "toonShadowsOn")
  loc(shadowStrength, "toonShadowStrength")
  loc(shadowBias, "toonShadowBias")
  loc(shadowTexel, "toonShadowTexel")
  loc(shadowSoftness, "toonShadowSoftness")
  loc(shadingStrength, "toonShadingStrength")
  loc(lightLevel, "toonLightLevel")
  result.uploadRamp(rampImage())

  result.depthShader = compileShaderFiles(ToonDepthVertSrc, ToonDepthFragSrc)
  template dloc(field: untyped, name: string) =
    result.depthUniforms.field =
      glGetUniformLocation(result.depthShader, name)
  dloc(model, "toonModel")
  dloc(lightMvp, "toonDepthLightMvp")
  dloc(useSkinning, "toonUseSkinning")
  dloc(jointMatrices, "toonJointMatrices")
  dloc(baseColorTexture, "toonBaseColorTexture")
  dloc(baseColorFactor, "toonBaseColorFactor")
  dloc(alphaCutoff, "toonAlphaCutoff")

  result.backgroundShader =
    compileShaderFiles(ToonBackgroundVertSrc, ToonBackgroundFragSrc)
  template bloc(field: untyped, name: string) =
    result.backgroundUniforms.field =
      glGetUniformLocation(result.backgroundShader, name)
  bloc(sky, "toonSkyColor")
  bloc(horizon, "toonHorizonColor")
  bloc(ground, "toonGroundColor")
  bloc(horizonHeight, "toonHorizonHeight")
  # One triangle covering clip space; the vertex shader reads only xy.
  var corners = [
    vec3(-1, -1, 0), vec3(3, -1, 0), vec3(-1, 3, 0)
  ]
  glGenVertexArrays(1, result.backgroundVao.addr)
  glBindVertexArray(result.backgroundVao)
  glGenBuffers(1, result.backgroundVbo.addr)
  glBindBuffer(GL_ARRAY_BUFFER, result.backgroundVbo)
  glBufferData(
    GL_ARRAY_BUFFER, corners.len * sizeof(Vec3), corners[0].addr,
    GL_STATIC_DRAW)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(0, 3, cGL_FLOAT, GL_FALSE, 0, nil)
  glBindVertexArray(0)

proc drawBackground*(ctx: ToonContext) =
  ## Fills the screen with the palette gradient. Draw it first; it writes
  ## no depth, so the scene lands on top.
  glUseProgram(ctx.backgroundShader)
  let u = ctx.backgroundUniforms
  glUniform4f(u.sky, ctx.skyColor.r, ctx.skyColor.g, ctx.skyColor.b, 1)
  glUniform4f(
    u.horizon, ctx.horizonColor.r, ctx.horizonColor.g, ctx.horizonColor.b, 1)
  glUniform4f(
    u.ground, ctx.groundColor.r, ctx.groundColor.g, ctx.groundColor.b, 1)
  glUniform1f(u.horizonHeight, ctx.horizonHeight)
  glDisable(GL_DEPTH_TEST)
  glDepthMask(GL_FALSE)
  glDisable(GL_BLEND)
  glDisable(GL_CULL_FACE)
  glBindVertexArray(ctx.backgroundVao)
  glDrawArrays(GL_TRIANGLES, 0, 3)
  glBindVertexArray(0)
  glDepthMask(GL_TRUE)
  glEnable(GL_DEPTH_TEST)
  glEnable(GL_CULL_FACE)
  glUseProgram(0)

proc prepareBindBounds(mesh: var ToonMeshPose, node: Node) =
  ## Caches geometry boxes per joint, including only its weighted vertices.
  var changed = mesh.boundsNode != node or mesh.boundsMesh != node.mesh or
    mesh.geometryVersions.len != node.mesh.primitives.len or
    mesh.boundsJointCount != mesh.joints.len
  if not changed:
    for i, primitive in node.mesh.primitives:
      if mesh.boundsPrimitives[i] != primitive or
        mesh.geometryVersions[i] != primitive.geometryVersion:
        changed = true
        break
  if not changed:
    return
  mesh.boundsNode = node
  mesh.boundsMesh = node.mesh
  mesh.boundsJointCount = mesh.joints.len
  mesh.geometryVersions.setLen(node.mesh.primitives.len)
  mesh.boundsPrimitives.setLen(node.mesh.primitives.len)
  for i, primitive in node.mesh.primitives:
    mesh.geometryVersions[i] = primitive.geometryVersion
    mesh.boundsPrimitives[i] = primitive
  mesh.bindBounds.setLen(max(mesh.joints.len, 1))
  for bounds in mesh.bindBounds.mitems:
    bounds = emptyBounds()
  mesh.boundsValid = true
  mesh.weightScale = 1
  mesh.weightMinimum = 1
  for primitive in node.mesh.primitives:
    if mesh.joints.len > 0 and
      (primitive.jointIds.len != primitive.points.len or
      primitive.jointWeights.len != primitive.points.len):
        mesh.boundsValid = false
        return
    for i, point in primitive.points:
      for axis in 0 ..< 3:
        if classify(point[axis]) in {fcNan, fcInf, fcNegInf}:
          mesh.boundsValid = false
          return
      if mesh.joints.len == 0:
        mesh.bindBounds[0].extend(point)
        continue
      var sum = 0.0'f
      for j in 0 ..< 4:
        let
          weight = primitive.jointWeights[i][j]
          joint = primitive.jointIds[i][j].int
        if weight < 0 or classify(weight) in {fcNan, fcInf, fcNegInf}:
          mesh.boundsValid = false
          return
        sum += weight
        if weight == 0:
          continue
        if joint >= mesh.joints.len:
          mesh.boundsValid = false
          return
        mesh.bindBounds[joint].extend(point)
      mesh.weightScale = max(mesh.weightScale, sum)
      mesh.weightMinimum = min(mesh.weightMinimum, sum)

proc posedBounds(mesh: var ToonMeshPose, node: Node): AABounds =
  ## Bounds the convex combination of joint-transformed vertex positions.
  mesh.prepareBindBounds(node)
  result = emptyBounds()
  if not mesh.boundsValid:
    return
  var local = emptyBounds()
  if mesh.joints.len == 0:
    local = mesh.bindBounds[0]
  else:
    for i, bounds in mesh.bindBounds:
      local.extend(bounds.transformed(mesh.joints[i]))
    # Include zero and expand for weights whose sum is not exactly one.
    local.extend(vec3(0))
    local.min *= mesh.weightScale
    local.max *= mesh.weightScale
  result = local.transformed(mesh.transform)
  if mesh.joints.len > 0:
    # Skin weights scale model translation as well as local positions.
    let
      lower = mesh.transform.pos * (mesh.weightMinimum - 1)
      upper = mesh.transform.pos * (mesh.weightScale - 1)
    result.min += min(lower, upper)
    result.max += max(lower, upper)
  # Leave room for floating-point roundoff at the clipping planes.
  result.min -= vec3(0.001'f)
  result.max += vec3(0.001'f)

proc prepareMeshPoses(
  node, root: Node,
  pose: var ToonPose,
  unlitParts: openArray[string]
) =
  ## Reuses mesh slots even when visibility temporarily hides some nodes.
  if not node.visible:
    return
  if node.mesh != nil:
    if pose.meshCount == pose.meshes.len:
      pose.meshes.add ToonMeshPose()
    let index = pose.meshCount
    inc pose.meshCount
    let mesh = addr pose.meshes[index]
    mesh.node = node
    mesh.unlit = node.name in unlitParts
    mesh.transform = node.mat
    mesh.normal = node.mat.normalMatrix
    root.skinMatricesInto(node, mesh.joints)
    pose.bounds.extend(mesh[].posedBounds(node))
    pose.boundsValid = pose.boundsValid and mesh.boundsValid
  for child in node.nodes:
    prepareMeshPoses(child, root, pose, unlitParts)

proc prepareToonPose*(
  pose: var ToonPose,
  root: Node,
  transform: Mat4,
  unlitParts: openArray[string] = []
) =
  ## Captures active meshes in retained storage for all drawing passes.
  root.updateTransforms(transform)
  pose.bounds = emptyBounds()
  pose.boundsValid = true
  pose.meshCount = 0
  prepareMeshPoses(root, root, pose, unlitParts)

proc uploadPose(
  useSkinning, jointMatrices: GLint,
  joints: openArray[Mat4]
) =
  ## Sends a prepared palette to the currently active drawing program.
  glUniform1i(useSkinning, (joints.len > 0).ord.GLint)
  if joints.len > 0:
    glUniformMatrix4fv(
      jointMatrices, joints.len.GLsizei, GL_FALSE,
      cast[ptr float32](unsafeAddr joints[0])
    )

proc drawPrimitive(
  ctx: ToonContext, root, owner: Node, primitive: Primitive,
  pose: ptr ToonMeshPose = nil
) =
  let u = ctx.uniforms
  var
    modelMat = if pose == nil: owner.mat else: pose.transform
    normalMat = if pose == nil: owner.mat.normalMatrix else: pose.normal
  glUniformMatrix4fv(u.model, 1, GL_FALSE, cast[ptr float32](modelMat.addr))
  glUniformMatrix3fv(
    u.normalMatrix, 1, GL_FALSE, cast[ptr float32](normalMat.addr))

  if pose == nil:
    root.skinMatricesInto(owner, ctx.jointMatrices)
    uploadPose(u.useSkinning, u.jointMatrices, ctx.jointMatrices)
  else:
    uploadPose(u.useSkinning, u.jointMatrices, pose.joints)
  glUniform1i(
    u.unlit,
    (primitive.material.unlit or
      (pose != nil and pose.unlit) or
      owner.name in ctx.unlitNodes).ord.GLint
  )

  primitive.uploadToGpu()
  glBindVertexArray(primitive.data.vertexArrayId)

  let material = primitive.material
  glActiveTexture(GL_TEXTURE0)
  glUniform1i(u.baseColorTexture, 0)
  glBindTexture(GL_TEXTURE_2D, material.data.baseColorId)
  glUniform4f(
    u.baseColorFactor, material.baseColorFactor.r, material.baseColorFactor.g,
    material.baseColorFactor.b, material.baseColorFactor.a)
  glActiveTexture(GL_TEXTURE1)
  glUniform1i(u.emissiveTexture, 1)
  let emissiveId =
    if material.data.emissiveId != 0:
      material.data.emissiveId
    else:
      ensureBlackTexture()
  glBindTexture(GL_TEXTURE_2D, emissiveId)
  glUniform3f(
    u.emissiveFactor, material.emissiveFactor.r, material.emissiveFactor.g,
    material.emissiveFactor.b)
  glActiveTexture(GL_TEXTURE2)
  glUniform1i(u.ramp, 2)
  glBindTexture(GL_TEXTURE_2D, ctx.rampTexture)

  case material.alphaMode
  of MaskAlphaMode:
    glUniform1f(u.alphaCutoff, material.alphaCutoff)
    glDisable(GL_BLEND)
    glDepthMask(GL_TRUE)
  of BlendAlphaMode:
    glUniform1f(u.alphaCutoff, -1)
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    glDepthMask(GL_FALSE)
  of OpaqueAlphaMode:
    glUniform1f(u.alphaCutoff, -1)
    glDisable(GL_BLEND)
    glDepthMask(GL_TRUE)
  if material.doubleSided:
    glDisable(GL_CULL_FACE)
  else:
    glEnable(GL_CULL_FACE)

  if primitive.indices16.len > 0:
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitive.data.indicesId)
    glDrawElements(
      GL_TRIANGLES, primitive.indices16.len.GLint, GL_UNSIGNED_SHORT, nil)
  elif primitive.indices32.len > 0:
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitive.data.indicesId)
    glDrawElements(
      GL_TRIANGLES, primitive.indices32.len.GLint, GL_UNSIGNED_INT, nil)
  else:
    glDrawArrays(GL_TRIANGLES, 0, primitive.points.len.cint)

proc drawToonMesh(
  ctx: ToonContext, root, node: Node, pose: ptr ToonMeshPose = nil
) =
  ## Retains transparent draws in the context's reusable queue.
  for primitive in node.mesh.primitives:
    if primitive.material.alphaMode == BlendAlphaMode:
      ctx.blended.add ToonBlend(node: node, primitive: primitive, pose: pose)
    else:
      ctx.drawPrimitive(root, node, primitive, pose)

proc drawToonNodes(ctx: ToonContext, root, node: Node) =
  ## Walks visible nodes without allocating a recursive closure.
  if not node.visible:
    return
  if node.mesh != nil:
    ctx.drawToonMesh(root, node)
  for child in node.nodes:
    ctx.drawToonNodes(root, child)

proc draw*(
  ctx: ToonContext,
  root: Node,
  pose: ptr ToonPose = nil
) =
  ## Draws every visible mesh under root with toon shading. Blended
  ## materials go last so they see the opaque depth.
  if pose != nil and pose.boundsValid and
    not pose.bounds.inFrustum(ctx.proj * ctx.view):
      return
  if pose == nil:
    root.updateTransforms(ctx.transform)
  glUseProgram(ctx.shader)
  let u = ctx.uniforms
  var
    viewMat = ctx.view
    projMat = ctx.proj
  glUniformMatrix4fv(u.view, 1, GL_FALSE, cast[ptr float32](viewMat.addr))
  glUniformMatrix4fv(u.proj, 1, GL_FALSE, cast[ptr float32](projMat.addr))
  glUniform3f(
    u.lightDirection, ctx.lightDirection.x, ctx.lightDirection.y,
    ctx.lightDirection.z)
  glUniform3f(
    u.cameraPosition, ctx.cameraPosition.x, ctx.cameraPosition.y,
    ctx.cameraPosition.z)
  glUniform4f(
    u.highlightColor, ctx.highlightColor.r, ctx.highlightColor.g,
    ctx.highlightColor.b, ctx.highlightColor.a)
  glUniform4f(
    u.shadowColor, ctx.shadowColor.r, ctx.shadowColor.g,
    ctx.shadowColor.b, ctx.shadowColor.a)
  glUniform4f(
    u.rimColor, ctx.rimColor.r, ctx.rimColor.g, ctx.rimColor.b,
    ctx.rimColor.a)
  glUniform4f(u.tint, ctx.tint.r, ctx.tint.g, ctx.tint.b, ctx.tint.a)
  glUniform1i(u.lightingMode, ctx.lighting.ord.GLint)
  glUniform1i(u.perPixelLighting, ctx.perPixelLighting.ord.GLint)
  glUniform1i(u.neutralMaterial, ctx.neutralMaterial.ord.GLint)

  # Sun shadow map state (polyworld/shadows): characters darken where the
  # sun cannot see them and flatten with the shared shading strength.
  var
    lightMatrix0 = sunLightMvp0
    lightMatrix1 = sunLightMvp1
  glUniformMatrix4fv(
    u.shadowMvp0, 1, GL_FALSE, cast[ptr float32](lightMatrix0.addr))
  glUniformMatrix4fv(
    u.shadowMvp1, 1, GL_FALSE, cast[ptr float32](lightMatrix1.addr))
  glUniform1f(u.shadowStep, sunShadowBlend)
  glUniform1f(u.shadowsOn, if sunShadowsActive(): 1.0 else: 0.0)
  glUniform1f(u.shadowStrength, sunShadowStrength * lightLevel)
  glUniform1f(u.shadowBias, sunShadowBias)
  glUniform1f(u.shadowTexel, SunShadowTexel)
  glUniform1f(u.shadowSoftness, sunShadowSoftness)
  glUniform1f(u.shadingStrength, sunShadingStrength)
  glUniform1f(u.lightLevel, lightLevel)
  glActiveTexture(GL_TEXTURE3)
  glBindTexture(GL_TEXTURE_2D, sunShadowTextures[0])
  glUniform1i(u.shadowMap0, 3)
  glActiveTexture(GL_TEXTURE4)
  glBindTexture(GL_TEXTURE_2D, sunShadowTextures[1])
  glUniform1i(u.shadowMap1, 4)
  glActiveTexture(GL_TEXTURE0)

  glEnable(GL_DEPTH_TEST)
  glDepthFunc(GL_LEQUAL)
  glFrontFace(GL_CCW)

  ctx.blended.setLen(0)
  if pose == nil:
    ctx.drawToonNodes(root, root)
  else:
    for i in 0 ..< pose.meshCount:
      let mesh = addr pose.meshes[i]
      ctx.drawToonMesh(root, mesh.node, mesh)
  for entry in ctx.blended:
    ctx.drawPrimitive(root, entry.node, entry.primitive, entry.pose)
  ctx.blended.setLen(0)

  glDisable(GL_BLEND)
  glDepthMask(GL_TRUE)
  glEnable(GL_CULL_FACE)
  glBindVertexArray(0)
  glUseProgram(0)

proc drawSunDepthPrimitive(
  ctx: ToonContext, root, owner: Node, primitive: Primitive,
  pose: ptr ToonMeshPose = nil
) =
  let u = ctx.depthUniforms
  var modelMat = if pose == nil: owner.mat else: pose.transform
  glUniformMatrix4fv(u.model, 1, GL_FALSE, cast[ptr float32](modelMat.addr))
  if pose == nil:
    root.skinMatricesInto(owner, ctx.jointMatrices)
    uploadPose(u.useSkinning, u.jointMatrices, ctx.jointMatrices)
  else:
    uploadPose(u.useSkinning, u.jointMatrices, pose.joints)

  primitive.uploadToGpu()
  glBindVertexArray(primitive.data.vertexArrayId)

  let material = primitive.material
  glActiveTexture(GL_TEXTURE0)
  glUniform1i(u.baseColorTexture, 0)
  glBindTexture(GL_TEXTURE_2D, material.data.baseColorId)
  glUniform4f(
    u.baseColorFactor, material.baseColorFactor.r, material.baseColorFactor.g,
    material.baseColorFactor.b, material.baseColorFactor.a)
  if material.alphaMode == MaskAlphaMode:
    glUniform1f(u.alphaCutoff, material.alphaCutoff)
  else:
    glUniform1f(u.alphaCutoff, -1)

  if primitive.indices16.len > 0:
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitive.data.indicesId)
    glDrawElements(
      GL_TRIANGLES, primitive.indices16.len.GLint, GL_UNSIGNED_SHORT, nil)
  elif primitive.indices32.len > 0:
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitive.data.indicesId)
    glDrawElements(
      GL_TRIANGLES, primitive.indices32.len.GLint, GL_UNSIGNED_INT, nil)
  else:
    glDrawArrays(GL_TRIANGLES, 0, primitive.points.len.cint)

proc prepareShadowGeometry(ctx: ToonContext, mesh: Mesh) =
  ## Retains batched shadow buffers until source geometry or cutouts change.
  let key = cast[pointer](mesh)
  let geometry = addr ctx.shadowGeometry.mgetOrPut(key, ShadowGeometry())
  var changed = geometry.sources.len != mesh.primitives.len
  if not changed:
    for i, primitive in mesh.primitives:
      let source = geometry.sources[i]
      if source.primitive != primitive or
        source.version != primitive.geometryVersion or
        source.alpha != primitive.material.alphaMode:
          changed = true
          break
  if not changed:
    return
  for primitive in geometry.primitives:
    var owned = true
    for source in geometry.sources:
      if primitive == source.primitive:
        owned = false
        break
    if owned:
      primitive.clearFromGpu()
  geometry.sources.setLen(mesh.primitives.len)
  for i, primitive in mesh.primitives:
    geometry.sources[i] = ShadowSource(
      primitive: primitive,
      version: primitive.geometryVersion,
      alpha: primitive.material.alphaMode
    )
  geometry.primitives = mesh.shadowPrimitives()

proc drawDepthMesh(
  ctx: ToonContext, root, node: Node, pose: ptr ToonMeshPose = nil
) =
  ## Borrows cached shadow primitives without copying their sequence.
  ctx.prepareShadowGeometry(node.mesh)
  let geometry = addr ctx.shadowGeometry[cast[pointer](node.mesh)]
  for primitive in geometry.primitives:
    ctx.drawSunDepthPrimitive(root, node, primitive, pose)

proc drawDepthNodes(ctx: ToonContext, root, node: Node) =
  ## Walks visible shadow casters without allocating a recursive closure.
  if not node.visible:
    return
  if node.mesh != nil:
    ctx.drawDepthMesh(root, node)
  for child in node.nodes:
    ctx.drawDepthNodes(root, child)

proc drawSunDepth*(
  ctx: ToonContext,
  root: Node,
  pose: ptr ToonPose = nil
) =
  ## Renders every visible opaque mesh under root into the sun's depth map
  ## (polyworld/shadows), skinning included, so characters cast shadows.
  ## Call between beginSunDepthPass and endSunDepthPass with ctx.transform
  ## already posed; blended materials never cast.
  if pose != nil and pose.boundsValid and
    not pose.bounds.inFrustum(sunDepthPassMvp()):
      return
  if pose == nil:
    root.updateTransforms(ctx.transform)
  glUseProgram(ctx.depthShader)
  var lightMatrix = sunDepthPassMvp()
  glUniformMatrix4fv(
    ctx.depthUniforms.lightMvp, 1, GL_FALSE,
    cast[ptr float32](lightMatrix.addr))
  glDisable(GL_CULL_FACE)
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_TRUE)

  if pose == nil:
    ctx.drawDepthNodes(root, root)
  else:
    for i in 0 ..< pose.meshCount:
      let mesh = addr pose.meshes[i]
      ctx.drawDepthMesh(root, mesh.node, mesh)
  glBindVertexArray(0)
