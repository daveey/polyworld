## Full-screen effects for the AWM client.
##
## The 3D scene renders into an offscreen target instead of the window:
##
## 1. Opaque pass (table, cards, characters) into `scene`.
## 2. Visible material normals are replayed against the finished depth. Other
##    surfaces retain the depth-reconstructed normal; the sky has no normal.
## 3. `applyOcclusion`: screen-space ambient occlusion from the scene depth,
##    at half resolution, blurred with a depth-aware filter and multiplied
##    into the scene. It runs before the VFX, so glows are never darkened.
## 4. The VFX draw on top. `present` extracts the light they added (plus the
##    brightest scene highlights) into a bloom chain, then writes the scene to
##    the window with FXAA, bloom, a gentle grade, vignette and dither.
##
## The HUD draws on the window afterwards and is not affected.
##
## AWM_POSTFX=0 disables everything (the old direct path). AWM_SSAO=0,
## AWM_BLOOM=0 and AWM_FXAA=0 disable one effect each. F8 toggles all of it.
##
## Build with -d:awmPostLayers to show one intermediate layer instead of the
## final image (see PostLayer; AWM_POST_LAYER=N picks one at startup).
## Build with -d:awmPostPanel for a window that tunes every setting live.

import
  std/[os, strutils, tables],
  opengl, vmath

const
  BloomLevels = 4
  PostLayerControls* {.booldefine: "awmPostLayers".} = false
    ## Compiles the layer views: the window can show any PostLayer.
  PostPanelControls* {.booldefine: "awmPostPanel".} = false
    ## Compiles the tuning window in postpanel.nim.

type
  PostLayer* = enum
    ## What the window shows. Key 1 is the final image, 2..9 then 0 the rest.
    FinalLayer = "final image"
    SceneLayer = "scene before bloom and grading"
    DepthLayer = "depth"
    NormalLayer = "surface normals"
    RawOcclusionLayer = "occlusion, unblurred"
    OcclusionLayer = "occlusion"
    BeforeVfxLayer = "scene before VFX"
    VfxLayer = "light added by VFX"
    BloomSourceLayer = "bloom source"
    BloomLayer = "bloom"

  PostPass = object
    program: GLuint
    locations: Table[string, GLint]

  RenderTarget = object
    framebuffer: GLuint
    texture: GLuint
    size: IVec2

  PostSettings* = object
    enabled*: bool
    occlusion*: bool
    bloom*: bool
    fxaa*: bool
    occlusionRadius*: float32     ## World units the AO looks around a pixel.
    occlusionIntensity*: float32
    occlusionBias*: float32       ## Cosine ignored, hides flat-surface noise.
    occlusionTint*: Vec3          ## Color occlusion fades toward.
    occlusionSharpness*: float32  ## How hard the blur stops at depth edges.
    occlusionNormalDetail*: float32 ## Mapped surface relief the AO reacts to.
    bloomThreshold*: float32      ## Scene brightness that starts to glow.
    bloomVfx*: float32            ## How much of the VFX light glows.
    bloomStrength*: float32
    vignette*: float32
    vignetteStart*: float32       ## Distance from the center it begins.
    vignetteEnd*: float32         ## Distance where it reaches full strength.
    saturation*: float32
    contrast*: float32

  PostFx* = object
    settings*: PostSettings
    size: IVec2
    sceneFramebuffer: GLuint
    sceneColor: GLuint
    sceneDepth: GLuint            ## Depth-stencil, sampled for occlusion.
    materialNormals: RenderTarget ## View-space RGB; alpha marks mapped surfaces.
    occlusion: array[2, RenderTarget]
    beforeVfx: RenderTarget       ## Half-res copy of the scene before VFX.
    bloom: array[BloomLevels, RenderTarget]
    vertexArray: GLuint
    occlusionPass, blurPass, multiplyPass: PostPass
    prefilterPass, downPass, upPass, finalPass: PostPass
    near, far: float32
    when PostLayerControls:
      layer*: PostLayer
      layerPass: PostPass
      inverseProjection: Mat4

const
  FullscreenVertex = """
out vec2 uv;
void main() {
  vec2 corner = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  uv = corner;
  gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
}
"""

  ViewFromDepth = """
uniform highp sampler2D depthTexture;
uniform sampler2D normalTexture;
uniform mat4 inverseProjection;
uniform vec2 texel;

// Snaps to the depth texel's center: the depth read is NEAREST, so the
// position must be rebuilt where that depth was written, or flat surfaces
// tilt between rows at half resolution.
vec3 viewPosition(vec2 p) {
  p = (floor(p / texel) + 0.5) * texel;
  float depth = texture(depthTexture, p).r;
  vec4 v = inverseProjection * vec4(p * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
  return v.xyz / v.w;
}

// Picks the neighbor on each axis closest in depth so silhouettes keep
// clean normals instead of smearing across the gap.
vec3 viewNormal(vec2 p, vec3 center) {
  vec3 right = viewPosition(p + vec2(texel.x, 0.0)) - center;
  vec3 left = center - viewPosition(p - vec2(texel.x, 0.0));
  vec3 up = viewPosition(p + vec2(0.0, texel.y)) - center;
  vec3 down = center - viewPosition(p - vec2(0.0, texel.y));
  vec3 dx = abs(right.z) < abs(left.z) ? right : left;
  vec3 dy = abs(up.z) < abs(down.z) ? up : down;
  return normalize(cross(dx, dy));
}

vec3 surfaceNormal(vec2 p, vec3 center, float detail) {
  vec3 geometric = viewNormal(p, center);
  vec4 surface = texture(normalTexture, p);
  if (surface.a < 0.5) return geometric;
  return normalize(mix(geometric, normalize(surface.rgb * 2.0 - 1.0), detail));
}
"""

  OcclusionFragment = ViewFromDepth & """
uniform vec2 projectionScale;
uniform float radius;
uniform float intensity;
uniform float bias;
uniform float normalDetail;
in vec2 uv;
out vec4 fragColor;

float hash(vec2 p) {
  return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void main() {
  // A half-res pixel's center sits on a full-res texel corner; pick one
  // texel explicitly so every row rounds the same way.
  vec2 base = (floor(gl_FragCoord.xy) * 2.0 + 0.5) * texel;
  float depth = texture(depthTexture, base).r;
  if (depth >= 1.0) {
    fragColor = vec4(1.0);
    return;
  }
  vec3 center = viewPosition(base);
  // Small surface relief affects the AO hemisphere without making a flat
  // slab self-occlude as heavily as a real geometric crease.
  vec3 normal = surfaceNormal(base, center, normalDetail);
  vec2 uvRadius = 0.5 * projectionScale * radius / max(-center.z, 0.1);
  float spin = hash(gl_FragCoord.xy) * 6.2831853;
  const int Taps = 16;
  float occlusion = 0.0;
  for (int i = 0; i < Taps; ++i) {
    float t = (float(i) + 0.5) / float(Taps);
    float angle = float(i) * 2.3999632 + spin;
    vec2 offset = vec2(cos(angle), sin(angle)) * t * uvRadius;
    vec3 v = viewPosition(base + offset) - center;
    float distance2 = dot(v, v);
    float falloff = max(0.0, 1.0 - distance2 / (radius * radius));
    float cosine = dot(v, normal) * inversesqrt(distance2 + 0.0001);
    occlusion += falloff * max(0.0, cosine - bias);
  }
  float ao = clamp(1.0 - intensity * occlusion / float(Taps), 0.0, 1.0);
  fragColor = vec4(ao, ao, ao, 1.0);
}
"""

  BlurFragment = """
uniform sampler2D occlusionTexture;
uniform highp sampler2D depthTexture;
uniform vec2 direction;
uniform float sharpness;
uniform float near;
uniform float far;
in vec2 uv;
out vec4 fragColor;

float linearDepth(vec2 p) {
  float ndc = texture(depthTexture, p).r * 2.0 - 1.0;
  return 2.0 * near * far / (far + near - ndc * (far - near));
}

void main() {
  float centerDepth = linearDepth(uv);
  float total = 0.0;
  float weights = 0.0;
  for (int i = -4; i <= 4; ++i) {
    vec2 p = uv + direction * float(i);
    float difference = abs(linearDepth(p) - centerDepth) / centerDepth;
    float weight = exp(-float(i * i) / 12.0) * max(0.0, 1.0 - difference * sharpness);
    total += texture(occlusionTexture, p).r * weight;
    weights += weight;
  }
  float ao = total / max(weights, 0.0001);
  fragColor = vec4(ao, ao, ao, 1.0);
}
"""

  MultiplyFragment = """
uniform sampler2D occlusionTexture;
uniform vec3 tint;
in vec2 uv;
out vec4 fragColor;

void main() {
  float ao = texture(occlusionTexture, uv).r;
  fragColor = vec4(mix(tint, vec3(1.0), ao), 1.0);
}
"""

  PrefilterFragment = """
uniform sampler2D sceneTexture;
uniform sampler2D beforeTexture;
uniform vec2 texel;
uniform float threshold;
uniform float vfxWeight;
uniform float useVfx;
in vec2 uv;
out vec4 fragColor;

vec3 bright(vec2 p) {
  vec3 scene = texture(sceneTexture, p).rgb;
  vec3 vfx = max(scene - texture(beforeTexture, p).rgb, 0.0) * useVfx;
  float peak = max(scene.r, max(scene.g, scene.b));
  float knee = clamp((peak - threshold) / max(1.0 - threshold, 0.0001), 0.0, 1.0);
  return vfx * vfxWeight + scene * knee * knee;
}

void main() {
  vec3 color = bright(uv) * 0.5;
  color += bright(uv + texel * vec2(-1.0, -1.0)) * 0.125;
  color += bright(uv + texel * vec2(1.0, -1.0)) * 0.125;
  color += bright(uv + texel * vec2(-1.0, 1.0)) * 0.125;
  color += bright(uv + texel * vec2(1.0, 1.0)) * 0.125;
  fragColor = vec4(color, 1.0);
}
"""

  DownFragment = """
uniform sampler2D sourceTexture;
uniform vec2 texel;
in vec2 uv;
out vec4 fragColor;

void main() {
  vec3 color = texture(sourceTexture, uv).rgb * 4.0;
  color += texture(sourceTexture, uv + texel * vec2(-1.0, -1.0)).rgb;
  color += texture(sourceTexture, uv + texel * vec2(1.0, -1.0)).rgb;
  color += texture(sourceTexture, uv + texel * vec2(-1.0, 1.0)).rgb;
  color += texture(sourceTexture, uv + texel * vec2(1.0, 1.0)).rgb;
  fragColor = vec4(color / 8.0, 1.0);
}
"""

  UpFragment = """
uniform sampler2D sourceTexture;
uniform vec2 texel;
in vec2 uv;
out vec4 fragColor;

void main() {
  vec3 color = texture(sourceTexture, uv + texel * vec2(-2.0, 0.0)).rgb;
  color += texture(sourceTexture, uv + texel * vec2(2.0, 0.0)).rgb;
  color += texture(sourceTexture, uv + texel * vec2(0.0, -2.0)).rgb;
  color += texture(sourceTexture, uv + texel * vec2(0.0, 2.0)).rgb;
  color += texture(sourceTexture, uv + texel * vec2(-1.0, -1.0)).rgb * 2.0;
  color += texture(sourceTexture, uv + texel * vec2(1.0, -1.0)).rgb * 2.0;
  color += texture(sourceTexture, uv + texel * vec2(-1.0, 1.0)).rgb * 2.0;
  color += texture(sourceTexture, uv + texel * vec2(1.0, 1.0)).rgb * 2.0;
  fragColor = vec4(color / 12.0, 1.0);
}
"""

  FinalFragment = """
uniform sampler2D sceneTexture;
uniform sampler2D bloomTexture;
uniform vec2 texel;
uniform float useFxaa;
uniform float bloomStrength;
uniform float vignette;
uniform float vignetteStart;
uniform float vignetteEnd;
uniform float saturation;
uniform float contrast;
in vec2 uv;
out vec4 fragColor;

const vec3 Luma = vec3(0.299, 0.587, 0.114);

vec3 sampleScene(vec2 p) {
  return texture(sceneTexture, p).rgb;
}

// FXAA 3.11 "console" variant: one directional blur along the local edge.
vec3 fxaa(vec2 p) {
  vec3 m = sampleScene(p);
  if (useFxaa < 0.5) {
    return m;
  }
  float nw = dot(sampleScene(p + vec2(-1.0, -1.0) * texel), Luma);
  float ne = dot(sampleScene(p + vec2(1.0, -1.0) * texel), Luma);
  float sw = dot(sampleScene(p + vec2(-1.0, 1.0) * texel), Luma);
  float se = dot(sampleScene(p + vec2(1.0, 1.0) * texel), Luma);
  float lm = dot(m, Luma);
  float lumaMin = min(lm, min(min(nw, ne), min(sw, se)));
  float lumaMax = max(lm, max(max(nw, ne), max(sw, se)));
  if (lumaMax - lumaMin < max(0.0312, lumaMax * 0.125)) {
    return m;
  }
  vec2 dir = vec2(-((nw + ne) - (sw + se)), (nw + sw) - (ne + se));
  float reduce = max((nw + ne + sw + se) * 0.03125, 1.0 / 128.0);
  float scale = 1.0 / (min(abs(dir.x), abs(dir.y)) + reduce);
  dir = clamp(dir * scale, vec2(-8.0), vec2(8.0)) * texel;
  vec3 a = 0.5 * (sampleScene(p + dir * (1.0 / 3.0 - 0.5)) +
    sampleScene(p + dir * (2.0 / 3.0 - 0.5)));
  vec3 b = a * 0.5 + 0.25 * (sampleScene(p - dir * 0.5) +
    sampleScene(p + dir * 0.5));
  float lb = dot(b, Luma);
  return (lb < lumaMin || lb > lumaMax) ? a : b;
}

void main() {
  vec3 color = fxaa(uv);
  color += texture(bloomTexture, uv).rgb * bloomStrength;
  float luma = dot(color, Luma);
  color = mix(vec3(luma), color, saturation);
  color = mix(color, color * color * (3.0 - 2.0 * color), contrast);
  vec2 centered = (uv - 0.5) * vec2(texel.y / texel.x, 1.0);
  float edge = smoothstep(vignetteStart, vignetteEnd, length(centered) * 1.3);
  color *= 1.0 - vignette * edge;
  float noise = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453);
  color += (noise - 0.5) / 255.0;
  fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
"""

  LayerFragment = ViewFromDepth & """
uniform sampler2D colorTexture;
uniform sampler2D otherTexture;
uniform int mode;
uniform float scale;
uniform float near;
uniform float far;
in vec2 uv;
out vec4 fragColor;

void main() {
  vec3 color = texture(colorTexture, uv).rgb * scale;
  float depth = texture(depthTexture, uv).r;
  if (mode == 1) {
    // Near is white; the far side of the table fades to dark gray.
    float ndc = depth * 2.0 - 1.0;
    float z = 2.0 * near * far / (far + near - ndc * (far - near));
    color = depth >= 1.0 ? vec3(0.0) : vec3(1.0 - 0.85 * clamp((z - 5.0) / 30.0, 0.0, 1.0));
  } else if (mode == 2) {
    vec3 center = viewPosition(uv);
    color = depth >= 1.0 ? vec3(0.0) : surfaceNormal(uv, center, 1.0) * 0.5 + 0.5;
  } else if (mode == 3) {
    color = max(color - texture(otherTexture, uv).rgb, 0.0) * 2.0;
  }
  fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
"""

proc envFlag(name: string, default = true): bool =
  let value = getEnv(name)
  if value.len == 0: default else: value notin ["0", "false", "off", "no"]

proc envFloat(name: string, default: float32): float32 =
  try: parseFloat(getEnv(name, $default)).float32
  except ValueError: default

proc defaultPostSettings*(): PostSettings =
  PostSettings(
    enabled: envFlag("AWM_POSTFX"),
    occlusion: envFlag("AWM_SSAO"),
    bloom: envFlag("AWM_BLOOM"),
    fxaa: envFlag("AWM_FXAA"),
    occlusionRadius: envFloat("AWM_SSAO_RADIUS", 1.501),
    occlusionIntensity: envFloat("AWM_SSAO_INTENSITY", 3.523),
    occlusionBias: envFloat("AWM_SSAO_BIAS", 0.08),
    occlusionTint: vec3(0.10, 0.10, 0.16),
    occlusionSharpness: 40,
    occlusionNormalDetail: 0.45,
    bloomThreshold: 0.922,
    bloomVfx: 1.0,
    bloomStrength: 0.75,
    vignette: 0.32,
    vignetteStart: 0.35,
    vignetteEnd: 1.05,
    saturation: 1.06,
    contrast: 0.12
  )

proc shaderHeader(): string =
  when defined(emscripten):
    "#version 300 es\nprecision highp float;\n"
  else:
    "#version 410 core\n"

proc compileStage(kind: GLenum, source, label: string): GLuint =
  result = glCreateShader(kind)
  let
    text = shaderHeader() & source
    sources = allocCStringArray([text])
  defer:
    deallocCStringArray(sources)
  glShaderSource(result, 1, sources, nil)
  glCompileShader(result)
  var status: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, status.addr)
  if status == 0:
    var length: GLint
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetShaderInfoLog(result, length, nil, log.cstring)
    raise newException(CatchableError,
      "AWM post " & label & " shader failed:\n" & log)

proc compilePass(fragment, label: string): PostPass =
  let
    vertexShader = compileStage(GL_VERTEX_SHADER, FullscreenVertex, label)
    fragmentShader = compileStage(GL_FRAGMENT_SHADER, fragment, label)
  result.program = glCreateProgram()
  glAttachShader(result.program, vertexShader)
  glAttachShader(result.program, fragmentShader)
  glLinkProgram(result.program)
  glDeleteShader(vertexShader)
  glDeleteShader(fragmentShader)
  var status: GLint
  glGetProgramiv(result.program, GL_LINK_STATUS, status.addr)
  if status == 0:
    var length: GLint
    glGetProgramiv(result.program, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetProgramInfoLog(result.program, length, nil, log.cstring)
    raise newException(CatchableError,
      "AWM post " & label & " program failed:\n" & log)

proc location(pass: var PostPass, name: string): GLint =
  if name notin pass.locations:
    pass.locations[name] = glGetUniformLocation(pass.program, name.cstring)
  pass.locations[name]

proc setFloat(pass: var PostPass, name: string, value: float32) =
  glUniform1f(pass.location(name), value)

proc setVec2(pass: var PostPass, name: string, value: Vec2) =
  glUniform2f(pass.location(name), value.x, value.y)

proc setVec3(pass: var PostPass, name: string, value: Vec3) =
  glUniform3f(pass.location(name), value.x, value.y, value.z)

proc setTexture(pass: var PostPass, name: string, unit: int, texture: GLuint) =
  glActiveTexture(GLenum(GL_TEXTURE0.int + unit))
  glBindTexture(GL_TEXTURE_2D, texture)
  glUniform1i(pass.location(name), unit.GLint)

proc newTexture(size: IVec2, internal: GLint, format, kind: GLenum,
    filter: GLint): GLuint =
  glGenTextures(1, result.addr)
  glBindTexture(GL_TEXTURE_2D, result)
  glTexImage2D(GL_TEXTURE_2D, 0, internal, size.x.GLsizei, size.y.GLsizei, 0,
    format, kind, nil)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)

proc release(target: var RenderTarget) =
  if target.framebuffer != 0:
    glDeleteFramebuffers(1, target.framebuffer.addr)
    glDeleteTextures(1, target.texture.addr)
  target = RenderTarget()

proc initTarget(target: var RenderTarget, size: IVec2) =
  target.release()
  target.size = ivec2(max(size.x, 1), max(size.y, 1))
  target.texture = newTexture(target.size, GL_RGBA8.GLint, GL_RGBA,
    GL_UNSIGNED_BYTE, GL_LINEAR.GLint)
  glGenFramebuffers(1, target.framebuffer.addr)
  glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffer)
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
    target.texture, 0)

proc bindTarget(target: RenderTarget) =
  glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffer)
  glViewport(0, 0, target.size.x.GLsizei, target.size.y.GLsizei)

proc texel(target: RenderTarget): Vec2 =
  vec2(1.0'f32 / target.size.x.float32, 1.0'f32 / target.size.y.float32)

proc ensureSize(post: var PostFx, size: IVec2) =
  if size == post.size:
    return
  post.size = size
  post.materialNormals.release()
  if post.sceneFramebuffer != 0:
    glDeleteFramebuffers(1, post.sceneFramebuffer.addr)
    glDeleteTextures(1, post.sceneColor.addr)
    glDeleteTextures(1, post.sceneDepth.addr)
  post.sceneColor = newTexture(size, GL_RGBA8.GLint, GL_RGBA,
    GL_UNSIGNED_BYTE, GL_LINEAR.GLint)
  post.sceneDepth = newTexture(size, GL_DEPTH24_STENCIL8.GLint,
    GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, GL_NEAREST.GLint)
  glGenFramebuffers(1, post.sceneFramebuffer.addr)
  glBindFramebuffer(GL_FRAMEBUFFER, post.sceneFramebuffer)
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
    post.sceneColor, 0)
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT,
    GL_TEXTURE_2D, post.sceneDepth, 0)
  if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
    raise newException(CatchableError, "AWM post scene target is incomplete")
  post.materialNormals.initTarget(size)
  glBindTexture(GL_TEXTURE_2D, post.materialNormals.texture)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
  # The normal replay shares the finished depth, so nearer cards and heroes
  # reject the floor's normals. No extra depth copy or float extension needed.
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT,
    GL_TEXTURE_2D, post.sceneDepth, 0)
  if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
    raise newException(CatchableError, "AWM material normal target is incomplete")
  let half = ivec2(max(size.x div 2, 1), max(size.y div 2, 1))
  for target in post.occlusion.mitems:
    target.initTarget(half)
  post.beforeVfx.initTarget(half)
  var levelSize = half
  for target in post.bloom.mitems:
    target.initTarget(levelSize)
    levelSize = ivec2(max(levelSize.x div 2, 1), max(levelSize.y div 2, 1))
  glBindFramebuffer(GL_FRAMEBUFFER, 0)

proc initPostFx*(): PostFx =
  result.settings = defaultPostSettings()
  result.near = 0.1
  result.far = 100
  glGenVertexArrays(1, result.vertexArray.addr)
  result.occlusionPass = compilePass(OcclusionFragment, "occlusion")
  result.blurPass = compilePass(BlurFragment, "occlusion blur")
  result.multiplyPass = compilePass(MultiplyFragment, "occlusion multiply")
  result.prefilterPass = compilePass(PrefilterFragment, "bloom prefilter")
  result.downPass = compilePass(DownFragment, "bloom down")
  result.upPass = compilePass(UpFragment, "bloom up")
  result.finalPass = compilePass(FinalFragment, "final")
  when PostLayerControls:
    result.layerPass = compilePass(LayerFragment, "layer view")
    let key =
      try: parseInt(getEnv("AWM_POST_LAYER", "1"))
      except ValueError: 1
    result.layer = PostLayer(((key + 9) mod 10 + 10) mod 10)

proc showing(post: PostFx, layer: PostLayer): bool =
  when PostLayerControls: post.layer == layer
  else: false

proc drawFullscreen(post: PostFx) =
  glBindVertexArray(post.vertexArray)
  glDrawArrays(GL_TRIANGLES, 0, 3)

proc prepareFullscreen() =
  glDisable(GL_DEPTH_TEST)
  glDepthMask(GL_FALSE)
  glDisable(GL_STENCIL_TEST)
  glDisable(GL_CULL_FACE)
  glDisable(GL_BLEND)

proc restoreSceneTarget(post: PostFx) =
  glBindVertexArray(0)
  glUseProgram(0)
  glActiveTexture(GL_TEXTURE0)
  glDisable(GL_BLEND)
  glDepthMask(GL_TRUE)
  glBindFramebuffer(GL_FRAMEBUFFER, post.sceneFramebuffer)
  glViewport(0, 0, post.size.x.GLsizei, post.size.y.GLsizei)

proc beginScene*(post: var PostFx, size: IVec2, near, far: float32) =
  ## Routes the 3D scene's draws to the offscreen target. near and far must
  ## match the camera projection so the occlusion blur reads real distances.
  if not post.settings.enabled:
    return
  post.ensureSize(ivec2(max(size.x, 1), max(size.y, 1)))
  post.near = near
  post.far = far
  post.materialNormals.bindTarget()
  glClearColor(0, 0, 0, 0)
  glClear(GL_COLOR_BUFFER_BIT)
  glBindFramebuffer(GL_FRAMEBUFFER, post.sceneFramebuffer)
  glViewport(0, 0, post.size.x.GLsizei, post.size.y.GLsizei)

proc beginMaterialNormals*(post: PostFx): bool =
  ## Call after opaque geometry, before SSAO. Re-render only normal-mapped
  ## objects with depth EQUAL and no depth writes; color/stencil stay intact.
  if not post.settings.enabled or
      (not post.settings.occlusion and not post.showing(NormalLayer)):
    return false
  post.materialNormals.bindTarget()
  glDisable(GL_STENCIL_TEST)
  return true

proc endMaterialNormals*(post: PostFx) =
  glDepthFunc(GL_LESS)
  post.restoreSceneTarget()

proc applyOcclusion*(post: var PostFx, projection: Mat4) =
  ## Darkens creases and contact points in everything drawn so far, then
  ## snapshots the scene so `present` can tell which light the VFX add.
  if not post.settings.enabled:
    return
  let settings = post.settings
  prepareFullscreen()
  when PostLayerControls:
    post.inverseProjection = projection.inverse
  if settings.occlusion:
    post.occlusion[0].bindTarget()
    glUseProgram(post.occlusionPass.program)
    post.occlusionPass.setTexture("depthTexture", 0, post.sceneDepth)
    post.occlusionPass.setTexture("normalTexture", 1, post.materialNormals.texture)
    var inverseProjection = projection.inverse
    glUniformMatrix4fv(post.occlusionPass.location("inverseProjection"), 1,
      GL_FALSE, cast[ptr float32](inverseProjection.addr))
    post.occlusionPass.setVec2("projectionScale",
      vec2(projection[0, 0], projection[1, 1]))
    post.occlusionPass.setVec2("texel",
      vec2(1.0'f32 / post.size.x.float32, 1.0'f32 / post.size.y.float32))
    post.occlusionPass.setFloat("radius", settings.occlusionRadius)
    post.occlusionPass.setFloat("intensity", settings.occlusionIntensity)
    post.occlusionPass.setFloat("bias", settings.occlusionBias)
    post.occlusionPass.setFloat("normalDetail", settings.occlusionNormalDetail)
    post.drawFullscreen()

    glUseProgram(post.blurPass.program)
    post.blurPass.setTexture("depthTexture", 1, post.sceneDepth)
    post.blurPass.setFloat("sharpness", settings.occlusionSharpness)
    post.blurPass.setFloat("near", post.near)
    post.blurPass.setFloat("far", post.far)
    # The unblurred layer view keeps the raw result in occlusion[0].
    let blurs =
      if post.showing(RawOcclusionLayer): 0
      else: 2
    for (source, destination, axis) in
        [(0, 1, vec2(1, 0)), (1, 0, vec2(0, 1))][0 ..< blurs]:
      post.occlusion[destination].bindTarget()
      post.blurPass.setTexture("occlusionTexture", 0,
        post.occlusion[source].texture)
      post.blurPass.setVec2("direction", axis * post.occlusion[source].texel)
      post.drawFullscreen()

    glBindFramebuffer(GL_FRAMEBUFFER, post.sceneFramebuffer)
    glViewport(0, 0, post.size.x.GLsizei, post.size.y.GLsizei)
    glEnable(GL_BLEND)
    glBlendFuncSeparate(GL_DST_COLOR, GL_ZERO, GL_ZERO, GL_ONE)
    glUseProgram(post.multiplyPass.program)
    post.multiplyPass.setTexture("occlusionTexture", 0,
      post.occlusion[0].texture)
    post.multiplyPass.setVec3("tint", settings.occlusionTint)
    post.drawFullscreen()
    glDisable(GL_BLEND)

  if settings.bloom:
    glBindFramebuffer(GL_READ_FRAMEBUFFER, post.sceneFramebuffer)
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, post.beforeVfx.framebuffer)
    glBlitFramebuffer(0, 0, post.size.x, post.size.y,
      0, 0, post.beforeVfx.size.x, post.beforeVfx.size.y,
      GL_COLOR_BUFFER_BIT, GL_LINEAR.GLenum)
  post.restoreSceneTarget()

when PostLayerControls:
  proc layerAvailable*(post: PostFx): bool =
    ## False when the effect that fills the shown layer is switched off.
    case post.layer
    of RawOcclusionLayer, OcclusionLayer: post.settings.occlusion
    of BeforeVfxLayer, VfxLayer, BloomSourceLayer, BloomLayer:
      post.settings.bloom
    else: true

  proc drawLayer(post: var PostFx) =
    ## Replaces the final image on the bound window with post.layer.
    var
      color = post.sceneColor
      other = post.sceneColor
      mode = 0
      scale = 1.0'f32
    case post.layer
    of FinalLayer, SceneLayer: discard
    of DepthLayer: mode = 1
    of NormalLayer: mode = 2
    of RawOcclusionLayer, OcclusionLayer: color = post.occlusion[0].texture
    of BeforeVfxLayer: color = post.beforeVfx.texture
    of VfxLayer:
      mode = 3
      other = post.beforeVfx.texture
    of BloomSourceLayer: color = post.bloom[0].texture
    of BloomLayer:
      color = post.bloom[0].texture
      scale = post.settings.bloomStrength
    if not post.layerAvailable():
      scale = 0
    let pass = post.layerPass.addr
    glUseProgram(pass.program)
    pass[].setTexture("colorTexture", 0, color)
    pass[].setTexture("otherTexture", 1, other)
    pass[].setTexture("depthTexture", 2, post.sceneDepth)
    pass[].setTexture("normalTexture", 3, post.materialNormals.texture)
    glUniformMatrix4fv(pass[].location("inverseProjection"), 1, GL_FALSE,
      cast[ptr float32](post.inverseProjection.addr))
    pass[].setVec2("texel",
      vec2(1.0'f32 / post.size.x.float32, 1.0'f32 / post.size.y.float32))
    glUniform1i(pass[].location("mode"), mode.GLint)
    pass[].setFloat("scale", scale)
    pass[].setFloat("near", post.near)
    pass[].setFloat("far", post.far)
    post.drawFullscreen()

proc present*(post: var PostFx, windowSize: IVec2) =
  ## Composites the finished scene onto the window. The window framebuffer is
  ## bound afterwards, ready for the HUD.
  if not post.settings.enabled:
    return
  let settings = post.settings
  prepareFullscreen()
  if settings.bloom:
    post.bloom[0].bindTarget()
    glUseProgram(post.prefilterPass.program)
    post.prefilterPass.setTexture("sceneTexture", 0, post.sceneColor)
    post.prefilterPass.setTexture("beforeTexture", 1, post.beforeVfx.texture)
    post.prefilterPass.setVec2("texel",
      vec2(1.0'f32 / post.size.x.float32, 1.0'f32 / post.size.y.float32))
    post.prefilterPass.setFloat("threshold", settings.bloomThreshold)
    post.prefilterPass.setFloat("vfxWeight", settings.bloomVfx)
    post.prefilterPass.setFloat("useVfx", 1)
    post.drawFullscreen()

    # The bloom source layer view keeps the prefiltered light in bloom[0].
    let levels =
      if post.showing(BloomSourceLayer): 1
      else: BloomLevels
    glUseProgram(post.downPass.program)
    for level in 1 ..< levels:
      post.bloom[level].bindTarget()
      post.downPass.setTexture("sourceTexture", 0, post.bloom[level - 1].texture)
      post.downPass.setVec2("texel", post.bloom[level - 1].texel)
      post.drawFullscreen()

    # Each smaller level spreads its light over the next larger one.
    glEnable(GL_BLEND)
    glBlendFunc(GL_ONE, GL_ONE)
    glUseProgram(post.upPass.program)
    for level in countdown(levels - 1, 1):
      post.bloom[level - 1].bindTarget()
      post.upPass.setTexture("sourceTexture", 0, post.bloom[level].texture)
      post.upPass.setVec2("texel", post.bloom[level].texel)
      post.drawFullscreen()
    glDisable(GL_BLEND)

  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  glViewport(0, 0, windowSize.x.GLsizei, windowSize.y.GLsizei)
  glUseProgram(post.finalPass.program)
  post.finalPass.setTexture("sceneTexture", 0, post.sceneColor)
  post.finalPass.setTexture("bloomTexture", 1, post.bloom[0].texture)
  post.finalPass.setVec2("texel",
    vec2(1.0'f32 / post.size.x.float32, 1.0'f32 / post.size.y.float32))
  post.finalPass.setFloat("useFxaa", if settings.fxaa: 1 else: 0)
  post.finalPass.setFloat("bloomStrength",
    if settings.bloom: settings.bloomStrength else: 0)
  post.finalPass.setFloat("vignette", settings.vignette)
  post.finalPass.setFloat("vignetteStart", settings.vignetteStart)
  post.finalPass.setFloat("vignetteEnd", settings.vignetteEnd)
  post.finalPass.setFloat("saturation", settings.saturation)
  post.finalPass.setFloat("contrast", settings.contrast)
  when PostLayerControls:
    if post.layer == FinalLayer: post.drawFullscreen()
    else: post.drawLayer()
  else:
    post.drawFullscreen()
  glBindVertexArray(0)
  glUseProgram(0)
  glActiveTexture(GL_TEXTURE0)
  glDepthMask(GL_TRUE)
