## Material sprites and forged weapons, with additive light and particles.
## World-space effects respect scene depth and never write into it.
import std/[math, os]
import opengl, pixie, shady, vmath
import awmcore

type
  ActiveVfx* = object
    kind*: VfxKind
    target*: Choice
    position*: Vec3
    elapsed*, duration*: float32
    seed*: int

  VfxRenderer* = object
    program, vertexArray, vertexBuffer: GLuint
    lightningTexture, oozeTexture, oozeDropletTexture: GLuint
    lightningAspect: float32
    vertices, materialVertices: seq[float32]

const
  HoverGold* = vec4(1.0, 0.82, 0.42, 1.0)
  TargetRed* = vec4(1.0, 0.035, 0.065, 1.0)

var
  vfxViewProjection: Uniform[Mat4]
  vfxLightningSampler: Uniform[Sampler2D]
  vfxOozeSampler, vfxOozeDropletSampler: Uniform[Sampler2D]

proc vfxVertex(position: Vec3, uv: Vec2, ink: Vec4, style: float32,
    dimensions: Vec2, gl_Position: var Vec4, fragmentUv: var Vec2,
    fragmentInk: var Vec4, fragmentStyle: var float32,
    fragmentDimensions: var Vec2) =
  gl_Position = vfxViewProjection * vec4(position, 1)
  fragmentUv = uv
  fragmentInk = ink
  fragmentStyle = style
  fragmentDimensions = dimensions

proc vfxFragment(fragmentUv: Vec2, fragmentInk: Vec4,
    fragmentStyle: float32, fragmentDimensions: Vec2,
    outputColor: var Vec4) =
  var
    alpha = fragmentInk.a
    light = fragmentInk.rgb
  if fragmentStyle > 5.5'f32:
    # Animate the jelly inside its transparent margin. Pixels loaded by Pixie
    # are premultiplied, so recover straight color for SRC_ALPHA blending.
    var uv = fragmentUv
    let edge = sin(uv.y * 3.14159265'f32)
    uv.x += sin(uv.y * 11.0'f32 + fragmentDimensions.x) *
      fragmentDimensions.y * edge
    uv.y += sin(uv.x * 9.0'f32 - fragmentDimensions.x * 1.3'f32) *
      fragmentDimensions.y * 0.5'f32 * sin(uv.x * 3.14159265'f32)
    var slime = texture(vfxOozeSampler, uv)
    if fragmentStyle > 6.5'f32:
      slime = texture(vfxOozeDropletSampler, uv)
    light *= slime.rgb / max(slime.a, 0.001'f32)
    alpha *= slime.a
    if alpha < 0.003'f32: discardFragment()
  elif fragmentStyle > 4.5'f32:
    # The mesh supplies the random path. Small ripples and changing branch
    # brightness animate the texture's fine detail without moving its terminals.
    var uv = fragmentUv
    let along = clamp((uv.y - 0.05'f32) / 0.9'f32, 0.0'f32, 1.0'f32)
    uv.x += sin(uv.y * 43.0'f32 + fragmentDimensions.x) *
      sin(along * 3.14159265'f32) * 0.006'f32
    let
      band = floor(uv.y * 10.0'f32)
      bandMix = fract(uv.y * 10.0'f32)
      branchSeed = fragmentDimensions.y + floor(uv.x + 0.5'f32) * 17.0'f32
      lower = fract(sin(band * 127.1'f32 + branchSeed * 311.7'f32) * 43758.5453'f32)
      upper = fract(sin((band + 1.0'f32) * 127.1'f32 + branchSeed * 311.7'f32) * 43758.5453'f32)
      branchLight = mix(lower, upper, bandMix * bandMix * (3.0'f32 - 2.0'f32 * bandMix))
      branches = smoothstep(0.08'f32, 0.24'f32, abs(uv.x - 0.5'f32))
    let bolt = texture(vfxLightningSampler, uv)
    # Pixie pixels are premultiplied; SRC_ALPHA additive blending needs this
    # conversion exactly once. Keep the core bright while forks vary softly.
    light *= bolt.rgb / max(bolt.a, 0.001'f32)
    alpha *= bolt.a * mix(1.0'f32, 0.3'f32 + branchLight, branches)
  elif fragmentStyle > 3.5'f32:
    let r = length(fragmentUv)
    alpha *= exp(-r * r * 8.0'f32) * max(0.0'f32, 1.0'f32 - r)
  elif fragmentStyle > 2.5'f32:
    let r2 = dot(fragmentUv, fragmentUv)
    if r2 >= 1.0'f32: discardFragment()
    let
      depth = sqrt(max(0.0'f32, 1.0'f32 - r2))
      rim = pow(1.0'f32 - depth, 3.0'f32)
      specular = exp(-dot(fragmentUv - vec2(-0.34, -0.42),
        fragmentUv - vec2(-0.34, -0.42)) * 95.0'f32)
      edge = exp(-pow(sqrt(r2) - 0.965'f32, 2.0'f32) * 4200.0'f32)
    light = mix(vec3(0.15, 0.73, 1.0), vec3(0.77, 0.38, 1.0),
      clamp(fragmentUv.x * 0.6'f32 + 0.5'f32, 0.0'f32, 1.0'f32))
    light += vec3(specular * 1.6'f32 + edge * 0.6'f32)
    alpha *= 0.025'f32 + rim * 0.6'f32 + edge * 0.75'f32 + specular
  elif fragmentStyle > 1.5'f32:
    let
      q = abs(fragmentUv) - (fragmentDimensions - vec2(0.08))
      distance = length(max(q, vec2(0))) +
        min(max(q.x, q.y), 0.0'f32) - 0.08'f32
    if distance < -0.045'f32: discardFragment()
    let
      haze = exp(-abs(distance) * 11.0'f32)
      core = exp(-distance * distance * 2300.0'f32)
    alpha *= haze * 0.65'f32 + core * 0.85'f32
    light += vec3(core * 0.32'f32)
  elif fragmentStyle > 0.5'f32:
    alpha *= exp(-fragmentUv.y * fragmentUv.y * 4.5'f32)
  outputColor = vec4(light, alpha)

proc compileStage(kind: GLenum, source: string): GLuint =
  result = glCreateShader(kind)
  let sources = allocCStringArray([source])
  defer: deallocCStringArray(sources)
  glShaderSource(result, 1, sources, nil)
  glCompileShader(result)
  var status: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, status.addr)
  if status == 0:
    var length: GLint
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetShaderInfoLog(result, length, nil, log.cstring)
    raise newException(CatchableError, "VFX shader failed: " & log)

proc initVfxRenderer*(textureRoot: string): VfxRenderer =
  const target = when defined(emscripten): glsl3WebGL else: glsl4Desktop
  let
    vertex = compileStage(GL_VERTEX_SHADER,
      toShader(vfxVertex, target, shaderVertex))
    fragment = compileStage(GL_FRAGMENT_SHADER,
      toShader(vfxFragment, target, shaderFragment))
  result.program = glCreateProgram()
  glAttachShader(result.program, vertex)
  glAttachShader(result.program, fragment)
  glLinkProgram(result.program)
  glDeleteShader(vertex)
  glDeleteShader(fragment)
  var status: GLint
  glGetProgramiv(result.program, GL_LINK_STATUS, status.addr)
  if status == 0:
    var length: GLint
    glGetProgramiv(result.program, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetProgramInfoLog(result.program, length, nil, log.cstring)
    raise newException(CatchableError, "VFX shader link failed: " & log)
  glGenVertexArrays(1, result.vertexArray.addr)
  glBindVertexArray(result.vertexArray)
  glGenBuffers(1, result.vertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, result.vertexBuffer)
  for attribute in [
    (name: "position", count: 3, offset: 0),
    (name: "uv", count: 2, offset: 3),
    (name: "ink", count: 4, offset: 5),
    (name: "style", count: 1, offset: 9),
    (name: "dimensions", count: 2, offset: 10)
  ]:
    let location = glGetAttribLocation(result.program, attribute.name.cstring)
    doAssert location >= 0
    glEnableVertexAttribArray(location.GLuint)
    glVertexAttribPointer(location.GLuint, attribute.count.GLint, cGL_FLOAT,
      GL_FALSE, (12 * sizeof(float32)).GLsizei,
      cast[pointer](attribute.offset * sizeof(float32)))
  glBindVertexArray(0)

  proc loadTexture(name: string, handle: var GLuint): Image =
    result = readImage(textureRoot / name)
    glGenTextures(1, handle.addr)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, handle)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA.GLint, result.width.GLsizei,
      result.height.GLsizei, 0, GL_RGBA, GL_UNSIGNED_BYTE, result.data[0].addr)
    glGenerateMipmap(GL_TEXTURE_2D)
  let lightning = loadTexture("lightning-strike.png", result.lightningTexture)
  result.lightningAspect = lightning.width.float32 / lightning.height.float32
  discard loadTexture("ooze-splat.png", result.oozeTexture)
  discard loadTexture("ooze-droplet.png", result.oozeDropletTexture)

proc clear*(renderer: var VfxRenderer) =
  renderer.vertices.setLen(0)
  renderer.materialVertices.setLen(0)

proc addQuad(renderer: var VfxRenderer, corners: array[4, Vec3],
    uvs: array[4, Vec2], ink: Vec4, style: float32, dimensions = vec2(1)) =
  for i in [0, 1, 2, 0, 2, 3]:
    let p = corners[i]
    renderer.vertices.add [p.x, p.y, p.z, uvs[i].x, uvs[i].y,
      ink.x, ink.y, ink.z, ink.w, style, dimensions.x, dimensions.y]

proc addMaterialQuad(renderer: var VfxRenderer, corners: array[4, Vec3],
    uvs: array[4, Vec2], ink: Vec4, style: float32, dimensions = vec2(1)) =
  for i in [0, 1, 2, 0, 2, 3]:
    let p = corners[i]
    renderer.materialVertices.add [p.x, p.y, p.z, uvs[i].x, uvs[i].y,
      ink.x, ink.y, ink.z, ink.w, style, dimensions.x, dimensions.y]

proc addCardHalo*(renderer: var VfxRenderer, center, right, down: Vec3,
    size: Vec2, ink: Vec4, strength = 1.0'f32) =
  let
    half = size * 0.5'f32
    extent = half + vec2(0.4)
    x = right * extent.x
    y = down * extent.y
  renderer.addQuad([center - x - y, center - x + y,
    center + x + y, center + x - y],
    [vec2(-extent.x, -extent.y), vec2(-extent.x, extent.y),
      extent, vec2(extent.x, -extent.y)],
    vec4(ink.xyz, ink.w * strength), 2, half)

proc addHudHalo*(renderer: var VfxRenderer, origin, size: Vec2,
    pixelsPerUnit: float32, ink: Vec4, strength = 1.0'f32) =
  ## addCardHalo around a screen rectangle given in pixels, y down. Draw it
  ## with hudHaloProjection. `pixelsPerUnit` scales the world-sized glow to
  ## the screen, which sets how far beyond the rectangle it reaches.
  let center = origin + size * 0.5'f32
  renderer.addCardHalo(vec3(center.x, center.y, 0),
    vec3(pixelsPerUnit, 0, 0), vec3(0, pixelsPerUnit, 0),
    size / pixelsPerUnit, ink, strength)

proc hudHaloProjection*(windowSize: Vec2): Mat4 =
  ## Window pixels, y down, for addHudHalo.
  ortho(0'f32, windowSize.x, windowSize.y, 0'f32, -1'f32, 1'f32)

proc addLine(renderer: var VfxRenderer, a, b, eye: Vec3,
    width: float32, ink: Vec4) =
  let normal = cross(b - a, eye - (a + b) * 0.5'f32)
  if length(normal) < 0.00001'f32: return
  let side = normalize(normal) * width
  renderer.addQuad([a - side, b - side, b + side, a + side],
    [vec2(0, -1), vec2(1, -1), vec2(1, 1), vec2(0, 1)], ink, 1)

proc addGlowLine(renderer: var VfxRenderer, a, b, eye: Vec3,
    width: float32, ink: Vec4) =
  renderer.addLine(a, b, eye, width * 4, vec4(ink.xyz, ink.w * 0.24))
  renderer.addLine(a, b, eye, width * 1.8, vec4(ink.xyz, ink.w * 0.55))
  renderer.addLine(a, b, eye, width * 0.45,
    vec4(mix(ink.xyz, vec3(1), 0.72'f32), ink.w))

proc addBillboard(renderer: var VfxRenderer, center: Vec3, radius: float32,
    eye: Vec3, ink: Vec4, style: float32) =
  let
    forward = normalize(eye - center)
    right = normalize(cross(vec3(0, 1, 0), forward)) * radius
    up = normalize(cross(forward, right)) * radius
  renderer.addQuad([center - right + up, center - right - up,
    center + right - up, center + right + up],
    [vec2(-1, -1), vec2(-1, 1), vec2(1, 1), vec2(1, -1)], ink, style)

proc addTargetRing*(renderer: var VfxRenderer, center, eye: Vec3,
    radius: float32, strength: float32) =
  for i in 0 ..< 64:
    let
      a = i.float32 * 2 * PI.float32 / 64
      b = (i + 1).float32 * 2 * PI.float32 / 64
    renderer.addGlowLine(center + vec3(cos(a), 0, sin(a)) * radius,
      center + vec3(cos(b), 0, sin(b)) * radius, eye, 0.025,
      vec4(TargetRed.xyz, strength))

proc newVfx*(kind: VfxKind, target: Choice, position: Vec3, seed: int): ActiveVfx =
  ActiveVfx(kind: kind, target: target, position: position, seed: seed,
    duration: case kind
      of LightningVfx: 0.95'f32
      of BubbleVfx: 1.05'f32
      of DamageFlashVfx: 0.55'f32
      of ArrowVfx: 0.75'f32
      of ManyArrowsVfx: 1.1'f32
      of SwordsIntoTheWindVfx: 1.55'f32
      of MightyShieldsVfx: 1.1'f32
      of SwordAndShieldVfx: 1.4'f32
      of MeleeVfx: 1.35'f32
      of SwordClashVfx: 1.25'f32
      of SwordBreakVfx: 1.4'f32
      of OozeSplatVfx: 1.8'f32
      of NoVfx, DeathVfx, DrawVfx, SummonVfx, BounceVfx, TossVfx,
          HeroDeathVfx: 0.0'f32)

proc advance*(effects: var seq[ActiveVfx], dt: float32) =
  for effect in effects.mitems:
    effect.elapsed += dt
  for i in countdown(effects.high, 0):
    if effects[i].elapsed >= effects[i].duration:
      effects.delete(i)

proc flashStrength*(effects: openArray[ActiveVfx], target: Choice): float32 =
  for effect in effects:
    if effect.kind == DamageFlashVfx and effect.target == target:
      # Hold the impact long enough to read, then smoothly restore the model.
      let fade = clamp((effect.duration - effect.elapsed) / 0.35'f32,
        0.0'f32, 1.0'f32)
      result = max(result, fade * fade * (3 - 2 * fade))

proc particleNoise(index, salt, seed: int): float32 =
  ## A stable hash keeps each particle's trajectory continuous across frames.
  ## Only a new cast gets a new seed; drawing never consumes a random stream.
  var bits = uint32(seed) xor (uint32(index + 1) * 0x9e3779b9'u32) xor
    (uint32(salt) * 0x85ebca6b'u32)
  bits = (bits xor (bits shr 16)) * 0x7feb352d'u32
  bits = (bits xor (bits shr 15)) * 0x846ca68b'u32
  bits = bits xor (bits shr 16)
  (bits shr 8).float32 / 16777216.0'f32

proc addLightningTexture(renderer: var VfxRenderer, start, finish, eye: Vec3,
    age, strength: float32, seed, discharge: int) =
  if strength <= 0.002'f32: return
  let
    axis = finish - start
    normal = cross(axis, eye - (start + finish) * 0.5'f32)
  if length(normal) < 0.00001'f32: return
  let
    side = normalize(normal)
    packet = discharge * 64
    mirrored = particleNoise(packet, 20, seed) > 0.5'f32
    leftU = if mirrored: 1.0'f32 else: 0.0'f32
    rightU = 1.0'f32 - leftU
    halfWidth = length(axis) / 0.9'f32 * renderer.lightningAspect * 0.5'f32 *
      (0.78'f32 + particleNoise(packet, 21, seed) * 0.32'f32)
  # Midpoint displacement creates large bends with progressively smaller kinks.
  # Both endpoints stay at zero, anchoring every discharge to the same target.
  var offsets: array[17, float32]
  var
    step = 16
    spread = length(axis) * 0.16'f32
  while step > 1:
    let half = step div 2
    for left in countup(0, 16 - step, step):
      let middle = left + half
      offsets[middle] = (offsets[left] + offsets[left + step]) * 0.5'f32 +
        (particleNoise(packet + middle, step + 22, seed) * 2 - 1) * spread
    step = half
    spread *= 0.52'f32
  var
    centers: array[35, Vec3]
    widths: array[35, Vec3]
    rows: array[35, float32]
  for row in 0 ..< 35:
    # Include the transparent caps and exact 5%/95% texture terminals.
    let
      t = if row == 0: -0.05'f32 / 0.9'f32
        elif row == 34: 1 + 0.05'f32 / 0.9'f32
        else: (row - 1).float32 / 32
      along = clamp(t, 0.0'f32, 1.0'f32) * 16
      knot = min(15, int(along))
      offset = mix(offsets[knot], offsets[knot + 1], along - knot.float32)
    centers[row] = start + axis * t + side * offset
    widths[row] = side * halfWidth
    rows[row] = 0.05'f32 + t * 0.9'f32
  for row in 0 ..< 34:
    renderer.addQuad([centers[row] - widths[row], centers[row + 1] - widths[row + 1],
      centers[row + 1] + widths[row + 1], centers[row] + widths[row]],
      [vec2(leftU, rows[row]), vec2(leftU, rows[row + 1]),
        vec2(rightU, rows[row + 1]), vec2(rightU, rows[row])],
      vec4(1.15, 1.2, 1.3, strength), 5,
      vec2(age * 45, (seed mod 4096 + discharge * 37).float32))

proc addLightning(renderer: var VfxRenderer, effect: ActiveVfx, eye: Vec3) =
  let
    age = effect.elapsed
    seed = effect.seed
    cameraRight = normalize(cross(vec3(0, 1, 0), normalize(eye - effect.position)))
    inward = if dot(effect.position, cameraRight) > 0: -1.0'f32 else: 1.0'f32
    start = effect.position + cameraRight * inward * (1.25'f32 + particleNoise(0, 30, seed) * 1.75'f32) +
      vec3(0, 4.6'f32 + particleNoise(0, 31, seed) * 0.55'f32, 0)
    interval = 0.055'f32 + particleNoise(0, 32, seed) * 0.025'f32
    discharge = int(age / interval)
    phase = age / interval - discharge.float32
    strikeFade = clamp(1 - age / 0.43'f32, 0.0'f32, 1.0'f32)
    flicker = 0.72'f32 + 0.28'f32 * exp(-phase * 5)
    restrikeTime = 0.11'f32 + particleNoise(0, 33, seed) * 0.07'f32
    restrike = exp(-pow((age - restrikeTime) / 0.04'f32, 2.0'f32))
    pulse = strikeFade * flicker + restrike * 0.35'f32
  renderer.addLightningTexture(start, effect.position, eye, age, pulse, seed, discharge)
  # Shapes snap on a time-based cadence, leaving only a short, faint afterimage.
  if discharge > 0:
    renderer.addLightningTexture(start, effect.position, eye, age,
      strikeFade * 0.18'f32 * exp(-phase * 8), seed, discharge - 1)
  renderer.addBillboard(effect.position, 1.55, eye,
    vec4(0.25, 0.63, 1.0, pulse * 1.15'f32), 4)
  renderer.addBillboard(effect.position, 0.46, eye,
    vec4(0.8, 0.93, 1.0, pulse * 1.7'f32), 4)

  # 88 ballistic sparks: varied launch times, directions, speeds, lengths,
  # and lifetimes give the impact a dense, irregular shower of white/cyan fire.
  for i in 0 ..< 88:
    let
      delay = particleNoise(i, 1, seed) * 0.07'f32
      elapsed = age - delay
      lifetime = 0.28'f32 + particleNoise(i, 2, seed) * 0.48'f32
    if elapsed < 0 or elapsed >= lifetime: continue
    let
      angle = particleNoise(i, 3, seed) * 2 * PI.float32
      elevation = particleNoise(i, 4, seed) * 1.7'f32 - 0.3'f32
      speed = 2.3'f32 + particleNoise(i, 5, seed) * 4.8'f32
      velocity = normalize(vec3(cos(angle), elevation, sin(angle))) * speed
      tailTime = max(0.0'f32, elapsed - 0.018'f32 - particleNoise(i, 6, seed) * 0.024'f32)
      head = effect.position + velocity * elapsed + vec3(0, -2.3'f32 * elapsed * elapsed, 0)
      tail = effect.position + velocity * tailTime + vec3(0, -2.3'f32 * tailTime * tailTime, 0)
      fade = clamp((lifetime - elapsed) / 0.2'f32, 0.0'f32, 1.0'f32)
      width = 0.009'f32 + particleNoise(i, 7, seed) * 0.016'f32
      ink = mix(vec3(0.09, 0.43, 1.0), vec3(0.5, 0.94, 1.0), particleNoise(i, 8, seed))
    renderer.addGlowLine(tail, head, eye, width, vec4(ink, fade * 0.92'f32))
    if i mod 3 == 0:
      renderer.addBillboard(head, width * 5, eye, vec4(0.7, 0.9, 1, fade), 4)

  # 40 slower ions hang around the impact after the trunk has burned away.
  for i in 0 ..< 40:
    let
      delay = particleNoise(i, 11, seed) * 0.13'f32
      elapsed = age - delay
      lifetime = 0.45'f32 + particleNoise(i, 12, seed) * 0.36'f32
    if elapsed < 0 or elapsed >= lifetime: continue
    let
      angle = particleNoise(i, 13, seed) * 2 * PI.float32
      velocity = vec3(cos(angle), particleNoise(i, 14, seed) * 1.3'f32, sin(angle)) *
        (0.8'f32 + particleNoise(i, 15, seed) * 1.7'f32)
      position = effect.position + velocity * elapsed + vec3(0, elapsed * 0.3'f32, 0)
      fade = pow(max(0.0'f32, 1 - elapsed / lifetime), 0.7'f32)
      shimmer = 0.6'f32 + 0.4'f32 * abs(sin(elapsed * 29 + i.float32))
    renderer.addBillboard(position, 0.035'f32 + particleNoise(i, 16, seed) * 0.07'f32,
      eye, vec4(0.16, 0.65, 1.0, fade * shimmer), 4)

proc addBubble(renderer: var VfxRenderer, effect: ActiveVfx, eye: Vec3) =
  let
    t = effect.elapsed / effect.duration
    appear = min(1.0'f32, effect.elapsed / 0.12'f32)
    pop = clamp((t - 0.8'f32) / 0.2'f32, 0.0'f32, 1.0'f32)
    radius = (1.27'f32 + sin(t * 10) * 0.035'f32 + pop * 0.55'f32) *
      (0.45'f32 + appear * 0.55'f32)
  renderer.addBillboard(effect.position, radius, eye,
    vec4(1, 1, 1, appear * (1 - pop)), 3)
  for i in 0 ..< 9:
    let
      angle = i.float32 * 2 * PI.float32 / 9 + t * 0.9'f32
      offset = vec3(cos(angle), sin(angle) * 0.65'f32 + 0.15'f32,
        sin(angle) * 0.5'f32) * (radius + pop * 0.7'f32)
    renderer.addBillboard(effect.position + offset, 0.07'f32 + pop * 0.045'f32,
      eye, vec4(0.5, 0.8, 1, appear * (1 - pop)), 3)

proc addArrowShot(renderer: var VfxRenderer, target, start: Vec3,
    age: float32, seed: int, eye: Vec3, lift = 1.1'f32, glow = 1.0'f32) =
  ## One fletched arrow flies from `start`, sticks in `target`, then splinters.
  const flight = 0.22'f32
  let
    t = min(1.0'f32, age / flight)
    tip = mix(start, target, t) + vec3(0, lift * 4 * t * (1 - t), 0)
    direction = normalize(target - start +
      vec3(0, lift * 4 * (1 - 2 * t), 0))
    impactAge = age - flight
    fade = if impactAge < 0: 1.0'f32
      else: clamp(1 - impactAge / 0.4'f32, 0.0'f32, 1.0'f32)
    normal = cross(direction, eye - tip)
  if fade > 0.002'f32 and length(normal) > 0.00001'f32:
    let
      side = normalize(normal)
      tail = tip - direction * 1.05'f32
      barb = tip - direction * 0.22'f32
      ink = vec4(1.0, 0.72, 0.32, fade)
    if impactAge < 0:
      # A short streak behind the arrow sells its speed during flight.
      let
        t0 = max(0.0'f32, t - 0.45'f32)
        trail = mix(start, target, t0) +
          vec3(0, lift * 4 * t0 * (1 - t0), 0)
      renderer.addLine(trail, tail, eye, 0.035, vec4(1.0, 0.85, 0.55, 0.22))
    renderer.addGlowLine(tail, tip, eye, 0.016, ink)
    renderer.addGlowLine(barb + side * 0.11'f32, tip, eye, 0.013, ink)
    renderer.addGlowLine(barb - side * 0.11'f32, tip, eye, 0.013, ink)
    for offset in [-0.1'f32, 0.1'f32]:
      renderer.addGlowLine(tail + direction * 0.2'f32, tail + side * offset,
        eye, 0.011, vec4(1.0, 0.9, 0.7, fade * 0.8'f32))
  if impactAge < 0: return

  renderer.addBillboard(target, 0.95, eye,
    vec4(1.0, 0.62, 0.22, exp(-impactAge * 9) * 1.1'f32 * glow), 4)
  # Splinters kick back toward the shooter, falling under a light gravity.
  for i in 0 ..< 36:
    let
      delay = particleNoise(i, 42, seed) * 0.04'f32
      elapsed = impactAge - delay
      lifetime = 0.2'f32 + particleNoise(i, 43, seed) * 0.3'f32
    if elapsed < 0 or elapsed >= lifetime: continue
    let
      angle = particleNoise(i, 44, seed) * 2 * PI.float32
      scatter = vec3(cos(angle), particleNoise(i, 45, seed) * 1.4'f32, sin(angle))
      speed = 1.8'f32 + particleNoise(i, 46, seed) * 3.2'f32
      velocity = normalize(scatter - direction * 1.2'f32) * speed
      tailTime = max(0.0'f32, elapsed - 0.02'f32)
      head = target + velocity * elapsed +
        vec3(0, -3.0'f32 * elapsed * elapsed, 0)
      back = target + velocity * tailTime +
        vec3(0, -3.0'f32 * tailTime * tailTime, 0)
      sparkFade = clamp((lifetime - elapsed) / 0.15'f32, 0.0'f32, 1.0'f32)
      ink = mix(vec3(0.95, 0.42, 0.12), vec3(1.0, 0.86, 0.5),
        particleNoise(i, 47, seed))
    renderer.addGlowLine(back, head, eye,
      0.008'f32 + particleNoise(i, 48, seed) * 0.012'f32,
      vec4(ink, sparkFade * 0.9'f32))

proc addArrow(renderer: var VfxRenderer, effect: ActiveVfx, eye: Vec3) =
  ## A fletched arrow arcs in from the table side, sticks, then splinters.
  let
    seed = effect.seed
    cameraRight = normalize(cross(vec3(0, 1, 0), normalize(eye - effect.position)))
    inward = if dot(effect.position, cameraRight) > 0: -1.0'f32 else: 1.0'f32
    start = effect.position +
      cameraRight * inward * (4.5'f32 + particleNoise(0, 40, seed)) +
      vec3(0, 1.4'f32 + particleNoise(0, 41, seed) * 0.6'f32, 0)
  renderer.addArrowShot(effect.position, start, effect.elapsed, seed, eye)

proc addArrowVolley(renderer: var VfxRenderer, effect: ActiveVfx, eye: Vec3) =
  ## A staggered volley drops steeply around the target from overhead.
  const volley = 5
  for i in 0 ..< volley:
    let
      delay = i.float32 * 0.07'f32 + particleNoise(i, 50, effect.seed) * 0.05'f32
      age = effect.elapsed - delay
    if age < 0: continue
    let
      angle = particleNoise(i, 51, effect.seed) * 2 * PI.float32
      around = vec3(cos(angle), 0, sin(angle))
      target = effect.position +
        around * (0.2'f32 + particleNoise(i, 52, effect.seed) * 0.45'f32)
      start = target + around * 1.1'f32 +
        vec3(0, 5.0'f32 + particleNoise(i, 53, effect.seed), 0)
    renderer.addArrowShot(target, start, age, effect.seed + i * 7919, eye,
      lift = 0.25'f32, glow = 0.55'f32)

include warriorvfx

include oozevfx

proc addEffects*(renderer: var VfxRenderer, effects: openArray[ActiveVfx],
    eye: Vec3) =
  for effect in effects:
    case effect.kind
    of LightningVfx: renderer.addLightning(effect, eye)
    of BubbleVfx: renderer.addBubble(effect, eye)
    of ArrowVfx: renderer.addArrow(effect, eye)
    of ManyArrowsVfx: renderer.addArrowVolley(effect, eye)
    of SwordsIntoTheWindVfx: renderer.addSwordsIntoTheWind(effect, eye)
    of MightyShieldsVfx: renderer.addMightyShields(effect, eye)
    of SwordAndShieldVfx: renderer.addSwordAndShield(effect, eye)
    of MeleeVfx: renderer.addMelee(effect, eye)
    of SwordClashVfx: renderer.addSwordClash(effect, eye)
    of SwordBreakVfx: renderer.addSwordBreak(effect, eye)
    of OozeSplatVfx: renderer.addOozeSplat(effect, eye)
    of DamageFlashVfx:
      let t = effect.elapsed / effect.duration
      renderer.addBillboard(effect.position, 1.2'f32 + t * 0.8'f32, eye,
        vec4(1, 0.025, 0.05, (1 - t) * 0.38'f32), 4)
    of NoVfx, DeathVfx, DrawVfx, SummonVfx, BounceVfx, TossVfx,
        HeroDeathVfx: discard

proc draw*(renderer: var VfxRenderer, viewProjection: Mat4,
    additive = true, depthTest = true) =
  if renderer.vertices.len == 0 and renderer.materialVertices.len == 0: return
  glBindBuffer(GL_ARRAY_BUFFER, renderer.vertexBuffer)
  if depthTest: glEnable(GL_DEPTH_TEST)
  else: glDisable(GL_DEPTH_TEST)
  glDepthMask(GL_FALSE)
  glDisable(GL_CULL_FACE)
  glEnable(GL_BLEND)
  glUseProgram(renderer.program)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, renderer.lightningTexture)
  glUniform1i(glGetUniformLocation(renderer.program, "vfxLightningSampler"), 0)
  var previousOozeUnit, previousDropletUnit: GLint
  glActiveTexture(GL_TEXTURE1)
  glGetIntegerv(GL_TEXTURE_BINDING_2D, previousOozeUnit.addr)
  glBindTexture(GL_TEXTURE_2D, renderer.oozeTexture)
  glUniform1i(glGetUniformLocation(renderer.program, "vfxOozeSampler"), 1)
  glActiveTexture(GL_TEXTURE2)
  glGetIntegerv(GL_TEXTURE_BINDING_2D, previousDropletUnit.addr)
  glBindTexture(GL_TEXTURE_2D, renderer.oozeDropletTexture)
  glUniform1i(glGetUniformLocation(renderer.program, "vfxOozeDropletSampler"), 2)
  vfxViewProjection = viewProjection
  glUniformMatrix4fv(glGetUniformLocation(renderer.program, "vfxViewProjection"),
    1, GL_FALSE, cast[ptr float32](vfxViewProjection.addr))
  glBindVertexArray(renderer.vertexArray)
  # Steel, leather, and jelly retain their shadows and alpha; light is laid
  # over those surfaces in a second pass, using the existing additive blend.
  if renderer.materialVertices.len > 0:
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    glBufferData(GL_ARRAY_BUFFER, renderer.materialVertices.len * sizeof(float32),
      renderer.materialVertices[0].addr, GL_DYNAMIC_DRAW)
    glDrawArrays(GL_TRIANGLES, 0, (renderer.materialVertices.len div 12).GLsizei)
  if renderer.vertices.len > 0:
    glBlendFunc(GL_SRC_ALPHA, if additive: GL_ONE else: GL_ONE_MINUS_SRC_ALPHA)
    glBufferData(GL_ARRAY_BUFFER, renderer.vertices.len * sizeof(float32),
      renderer.vertices[0].addr, GL_DYNAMIC_DRAW)
    glDrawArrays(GL_TRIANGLES, 0, (renderer.vertices.len div 12).GLsizei)
  glBindVertexArray(0)
  # The scene keeps its shadow maps on these units between frames.
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, previousOozeUnit.GLuint)
  glActiveTexture(GL_TEXTURE2)
  glBindTexture(GL_TEXTURE_2D, previousDropletUnit.GLuint)
  glActiveTexture(GL_TEXTURE0)
  glDepthMask(GL_TRUE)

proc drawCharacterFlash*(renderer: var VfxRenderer, stencilRef: int,
    strength: float32) =
  ## Stencil retains the visible character silhouette, including skinning and
  ## cutout materials. A red overlay stays bright even on blue/dark clothing.
  if strength <= 0: return
  var savedVertices = move(renderer.vertices)
  var savedMaterials = move(renderer.materialVertices)
  renderer.addQuad([vec3(-1, 1, 0), vec3(-1, -1, 0),
    vec3(1, -1, 0), vec3(1, 1, 0)],
    [vec2(0), vec2(0), vec2(0), vec2(0)],
    vec4(1, 0.025, 0.045, strength * 0.88'f32), 0)
  glEnable(GL_STENCIL_TEST)
  glStencilMask(0)
  glStencilFunc(GL_EQUAL, stencilRef.GLint, 0xff)
  glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP)
  renderer.draw(mat4(), additive = false, depthTest = false)
  glDisable(GL_STENCIL_TEST)
  glStencilMask(0xff)
  renderer.vertices = move(savedVertices)
  renderer.materialVertices = move(savedMaterials)
