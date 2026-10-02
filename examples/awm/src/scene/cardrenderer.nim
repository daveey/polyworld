## Card surfaces share the UI atlas so the same face is used in the world and
## in the reading view. Source art, frames, icons and fonts stay independent.

import std/[options, tables]
import chroma, opengl, pixie, shady, silky, vmath
import ../core/core, ../core/baseset, ../ui/cardfaces

type CardRenderer* = object
  program, vertexArray, vertexBuffer: GLuint
  vertices: seq[float32]

var
  cardViewProjection: Uniform[Mat4]
  cardAtlasSize: Uniform[Vec2]
  cardAtlasSampler: Uniform[Sampler2D]

proc cardVertex(position: Vec3, uv: Vec2, tint: Vec4,
    gl_Position: var Vec4, fragmentUv: var Vec2, fragmentTint: var Vec4) =
  gl_Position = cardViewProjection * vec4(position, 1)
  fragmentUv = uv / cardAtlasSize
  fragmentTint = tint

proc cardFragment(fragmentUv: Vec2, fragmentTint: Vec4,
    outputColor: var Vec4) =
  let surface = texture(cardAtlasSampler, fragmentUv)
  if surface.a < 0.01'f32:
    discardFragment()
  outputColor = vec4(mix(surface.rgb * fragmentTint.rgb,
    vec3(1.0, 0.025, 0.045) * surface.a, fragmentTint.w * 0.88'f32), surface.a)

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
    raise newException(CatchableError, "Card shader failed: " & log)

proc initCardRenderer*(): CardRenderer =
  const target = when defined(emscripten): glsl3WebGL else: glsl4Desktop
  let
    vertex = compileStage(GL_VERTEX_SHADER,
      toShader(cardVertex, target, shaderVertex))
    fragment = compileStage(GL_FRAGMENT_SHADER,
      toShader(cardFragment, target, shaderFragment))
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
    raise newException(CatchableError, "Card shader link failed: " & log)
  glGenVertexArrays(1, result.vertexArray.addr)
  glBindVertexArray(result.vertexArray)
  glGenBuffers(1, result.vertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, result.vertexBuffer)
  for attribute in [
    (name: "position", count: 3, offset: 0),
    (name: "uv", count: 2, offset: 3 * sizeof(float32)),
    (name: "tint", count: 4, offset: 5 * sizeof(float32))
  ]:
    let location = glGetAttribLocation(result.program, attribute.name.cstring)
    doAssert location >= 0
    glEnableVertexAttribArray(location.GLuint)
    glVertexAttribPointer(location.GLuint, attribute.count.GLint, cGL_FLOAT,
      GL_FALSE, (9 * sizeof(float32)).GLsizei, cast[pointer](attribute.offset))
  glBindVertexArray(0)

proc cardImageKey*(card: Card): string =
  # Include every visible value, so rule/stat changes cannot reuse stale faces.
  result = "card/" & $card.kind & "/" & $card.class & "/" & card.name &
    "/" & $card.energyCost & "/" & card.ruleText()
  if card.kind == Minion:
    result.add "/" & $card.power & "/" & $card.toughness

const
  CardBackKey* = "card/back"
  MaxBakedStat* = 40  ## Larger live stats show as this value.

proc statImageKey*(value: int, ink: StatInk, slot: StatSlot): string =
  "stat/" & $slot & "/" & $ink & "/" & $clamp(value, 0, MaxBakedStat)

proc lostKeywordsKey*(lost: set[Keyword]): string =
  "lost/" & $lost

iterator keywordSets(): set[Keyword] =
  ## Every non-empty set of keywords.
  for bits in 1 ..< (1 shl (ord(high(Keyword)) + 1)):
    var keywords: set[Keyword]
    for keyword in Keyword:
      if (bits and (1 shl ord(keyword))) != 0:
        keywords.incl keyword
    yield keywords

proc addBaseCardImages*(builder: AtlasBuilder) =
  ## Bakes every face and stat number play can show, so the live atlas never
  ## grows mid-game: silky's live builder can pack a new image over an
  ## existing one (a damaged minion replaced the card back).
  proc add(builder: AtlasBuilder, key: string, image: Image) =
    if not builder.addImage(key, image):
      raise newException(IOError, "Card images do not fit the UI atlas")
  for card in baseCards:
    builder.add(card.cardImageKey(), card.renderCardFace())
  # Pack the large back before small overlays fragment the remaining space.
  builder.add(CardBackKey, renderCardBack())
  for slot in StatSlot:
    for ink in StatInk:
      for value in 0 .. MaxBakedStat:
        builder.add(statImageKey(value, ink, slot),
          renderStat(value, ink, slot))
  for lost in keywordSets():
    builder.add(lostKeywordsKey(lost), renderLostKeywords(lost))

proc bakedCardImage*(sk: Silky, card: Card): string =
  ## Never packs at runtime (see addBaseCardImages). A face that was not baked
  ## falls back to the card back.
  result = card.cardImageKey()
  if result notin sk.atlas.entries:
    result = CardBackKey

iterator overlayImages(card: Card, power, toughness: int,
    lost: set[Keyword]): (Rect, string) =
  ## Each live overlay's atlas image and where it goes on the face, in
  ## pixels: both stats, and the type line when keywords were lost.
  for (slot, value, printed) in [(PowerSlot, power, card.power),
      (ToughnessSlot, toughness, card.toughness)]:
    let box = slot.box()
    yield (Rect(x: box.x - StatMargin, y: box.y - StatMargin,
      w: box.w + StatMargin * 2, h: box.h + StatMargin * 2),
      statImageKey(value, statInk(value, printed), slot))
  if lost.len > 0:
    yield (TypeLine, lostKeywordsKey(lost))

proc clear*(renderer: var CardRenderer) =
  renderer.vertices.setLen(0)

proc addSurface*(renderer: var CardRenderer, sk: Silky,
    corners: array[4, Vec3], imageKey: string, brightness = 1.0'f32,
    damageFlash = 0.0'f32) =
  ## Corners are top-left, bottom-left, bottom-right, top-right in card space.
  let
    entry = sk.atlas.entries[imageKey]
    left = entry.x.float32 + 0.5'f32
    top = entry.y.float32 + 0.5'f32
    right = (entry.x + entry.width).float32 - 0.5'f32
    bottom = (entry.y + entry.height).float32 - 0.5'f32
    uvs = [vec2(left, top), vec2(left, bottom),
      vec2(right, bottom), vec2(right, top)]
  for i in [0, 1, 2, 0, 2, 3]:
    let p = corners[i]
    renderer.vertices.add [p.x, p.y, p.z, uvs[i].x, uvs[i].y,
      brightness, brightness, brightness, damageFlash]

proc addMinionOverlays*(renderer: var CardRenderer, sk: Silky,
    corners: array[4, Vec3], card: Card, power, toughness: int,
    lost: set[Keyword] = {}, brightness = 1.0'f32, damageFlash = 0.0'f32) =
  ## Draws live power, toughness and lost keywords over a printed face
  ## with these corners, lifted just off it so they win the depth test.
  ## Only minions have stats; anything else draws nothing.
  if card.kind != Minion:
    return
  let
    across = corners[3] - corners[0]
    down = corners[1] - corners[0]
    lift = normalize(cross(down, across)) * 0.003'f32
  proc at(x, y: float32): Vec3 =
    corners[0] + across * (x / CardFaceWidth.float32) +
      down * (y / CardFaceHeight.float32) + lift
  for (area, key) in overlayImages(card, power, toughness, lost):
    if key notin sk.atlas.entries: continue
    renderer.addSurface(sk, [at(area.x, area.y), at(area.x, area.y + area.h),
      at(area.x + area.w, area.y + area.h), at(area.x + area.w, area.y)],
      key, brightness, damageFlash)

proc draw*(renderer: var CardRenderer, sk: Silky, viewProjection: Mat4) =
  if renderer.vertices.len == 0: return
  glBindBuffer(GL_ARRAY_BUFFER, renderer.vertexBuffer)
  glBufferData(GL_ARRAY_BUFFER, renderer.vertices.len * sizeof(float32),
    renderer.vertices[0].addr, GL_DYNAMIC_DRAW)
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_TRUE)
  glDisable(GL_CULL_FACE)
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
  glUseProgram(renderer.program)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, sk.atlasTextureId())
  cardViewProjection = viewProjection
  glUniformMatrix4fv(glGetUniformLocation(renderer.program, "cardViewProjection"),
    1, GL_FALSE, cast[ptr float32](cardViewProjection.addr))
  let atlasSize = sk.atlasImageSize()
  glUniform2f(glGetUniformLocation(renderer.program, "cardAtlasSize"),
    atlasSize.x.float32, atlasSize.y.float32)
  glUniform1i(glGetUniformLocation(renderer.program, "cardAtlasSampler"), 0)
  glBindVertexArray(renderer.vertexArray)
  glDrawArrays(GL_TRIANGLES, 0, (renderer.vertices.len div 9).GLsizei)
  glBindVertexArray(0)

proc drawCardImage*(sk: Silky, imageKey: string, origin, size: Vec2) =
  let entry = sk.atlas.entries[imageKey]
  sk.drawQuad(origin, size, vec2(entry.x.float32, entry.y.float32),
    vec2(entry.width.float32, entry.height.float32), rgbx(255, 255, 255, 255))

proc drawMinionOverlays*(sk: Silky, card: Card, power, toughness: int,
    lost: set[Keyword], origin, size: Vec2) =
  ## The 2D counterpart of addMinionOverlays, over a face at origin/size.
  if card.kind != Minion:
    return
  let scaleFactor = size / vec2(CardFaceWidth.float32, CardFaceHeight.float32)
  for (area, key) in overlayImages(card, power, toughness, lost):
    if key notin sk.atlas.entries: continue
    sk.drawCardImage(key, origin + vec2(area.x, area.y) * scaleFactor,
      vec2(area.w, area.h) * scaleFactor)
