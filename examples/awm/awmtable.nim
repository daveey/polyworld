## The 3D table every game mode builds on: card sizes and poses, the solid
## renderer for slabs and boxes, and the cards, piles and fanned hands made
## from them. It knows nothing about seats, cameras or turns.
import std/[math, options]
import opengl, shady, silky, vmath, windy
import awmsim, cardrenderer

const
  CardWidth* = 1.45'f32
  CardDepth* = 2.05'f32
  CardHeight* = 0.06'f32
  BoardSurfaceY* = 0.015'f32 ## Top of the courtyard stone and brass seams.
  PadSurfaceY* = 0.155'f32   ## Top of the deck and discard pads' trim.
  CardPlaneY* = BoardSurfaceY + CardHeight * 0.5'f32
  PileCardY* = PadSurfaceY + CardHeight * 0.5'f32
  StackStep* = 0.03'f32      ## Height between cards in a pile.
  # The art's opaque silhouette: 590 x 840 of 600 x 850, 31 px corners.
  CardBodyWidth* = CardWidth * 590.0'f32 / 600.0'f32
  CardBodyDepth* = CardDepth * 840.0'f32 / 850.0'f32
  CardCornerRadius* = CardWidth * 31.0'f32 / 600.0'f32
  CardCornerSegments* = 6
  CardBackSteel* = vec4(0.212, 0.263, 0.29, 1) ## back.svg's lightest steel.
  HandFanAngle* = 0.24'f32
  CardMoveDuration* = 0.46'f32
  DrawMoveDuration* = 0.72'f32
  DrawStagger* = 0.16'f32
    ## Cards drawn together leave the deck one after another, so their
    ## flights overlap instead of moving as one block.
  DeathDiscardSeconds* = 2.0'f32
    ## How long a dead player's whole hand takes to reach the discard pile,
    ## however many cards it holds: each card flies for its share.
  OpeningDealSeconds* = 1.9'f32
    ## How long the deal at the start of a game may take to send off its
    ## last card. A big table deals faster rather than longer.
  ShaderTarget* =
    when defined(emscripten):
      glsl3WebGL
    else:
      glsl4Desktop

type
  CardPose* = object
    position*: Vec3
    yaw*: float32
    pitch*: float32
    roll*: float32
    frameYaw*: float32 ## Optional balcony frame, applied after the local tilt.

  CardAnimation* = object
    ## A card flying between two poses, drawn instead of the card in the
    ## hand slot, board slot or discard pile it is heading for.
    card*: Card
    heroClass*: HeroClass
    fromPose*: CardPose
    toPose*: CardPose
    elapsed*: float32
    duration*: float32
    arcHeight*: float32
    suppressBoardId*: int
    suppressHandOwner*: int
    suppressHandIndex*: int
    suppressDiscardOwner*: int
    suppressCastSpell*: bool
      ## Heading for the spot a played spell floats in: the held spell is
      ## drawn only once the flight has landed.
    hidden*: bool
    trackingTarget*: Choice

  SolidRenderer* = object
    program: GLuint
    vertexArray: GLuint
    vertexBuffer: GLuint
    vertices: seq[float32]

var
  solidViewProjection: Uniform[Mat4]
  solidLightDirection: Uniform[Vec3]

proc solidVertex(
    gl_Position: var Vec4,
    fragmentNormal: var Vec3,
    fragmentColor: var Vec4,
    position: Vec3,
    normal: Vec3,
    color: Vec4
) =
  gl_Position = solidViewProjection * vec4(position, 1)
  fragmentNormal = normal
  fragmentColor = color

proc solidFragment(
    outputColor: var Vec4,
    fragmentNormal: Vec3,
    fragmentColor: Vec4
) =
  let light =
    0.55'f32 +
    0.45'f32 * max(
      dot(normalize(fragmentNormal), normalize(solidLightDirection)),
      0.0'f32
    )
  outputColor = vec4(fragmentColor.xyz * light, fragmentColor.w)

proc compileStage(
    kind: GLenum,
    source,
    label: string
): GLuint =
  result = glCreateShader(kind)
  let sources = allocCStringArray([source])
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
    raise newException(
      CatchableError,
      label & " shader failed:\n" & log & "\n" & source
    )

proc compileSolidProgram(): GLuint =
  let
    vertexShader = compileStage(
      GL_VERTEX_SHADER,
      toShader(solidVertex, ShaderTarget, shaderVertex),
      "AWM solid vertex"
    )
    fragmentShader = compileStage(
      GL_FRAGMENT_SHADER,
      toShader(solidFragment, ShaderTarget, shaderFragment),
      "AWM solid fragment"
    )
  result = glCreateProgram()
  glAttachShader(result, vertexShader)
  glAttachShader(result, fragmentShader)
  glLinkProgram(result)
  glDeleteShader(vertexShader)
  glDeleteShader(fragmentShader)
  var status: GLint
  glGetProgramiv(result, GL_LINK_STATUS, status.addr)
  if status == 0:
    var length: GLint
    glGetProgramiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetProgramInfoLog(result, length, nil, log.cstring)
    raise newException(
      CatchableError,
      "AWM solid program failed:\n" & log
    )

proc initSolidRenderer*(): SolidRenderer =
  result.program = compileSolidProgram()
  glGenVertexArrays(1, result.vertexArray.addr)
  glBindVertexArray(result.vertexArray)
  glGenBuffers(1, result.vertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, result.vertexBuffer)
  const stride = (10 * sizeof(float32)).GLsizei
  for attribute in [
    (name: "position", count: 3, offset: 0),
    (name: "normal", count: 3, offset: 3 * sizeof(float32)),
    (name: "color", count: 4, offset: 6 * sizeof(float32))
  ]:
    let location = glGetAttribLocation(
      result.program,
      attribute.name.cstring
    )
    doAssert location >= 0
    glEnableVertexAttribArray(location.GLuint)
    glVertexAttribPointer(
      location.GLuint,
      attribute.count.GLint,
      cGL_FLOAT,
      GL_FALSE,
      stride,
      cast[pointer](attribute.offset)
    )
  glBindVertexArray(0)

proc clear*(renderer: var SolidRenderer) =
  renderer.vertices.setLen(0)

proc addVertex(
    renderer: var SolidRenderer,
    position,
    normal: Vec3,
    color: Vec4
) =
  renderer.vertices.add position.x
  renderer.vertices.add position.y
  renderer.vertices.add position.z
  renderer.vertices.add normal.x
  renderer.vertices.add normal.y
  renderer.vertices.add normal.z
  renderer.vertices.add color.x
  renderer.vertices.add color.y
  renderer.vertices.add color.z
  renderer.vertices.add color.w

proc addQuad(
    renderer: var SolidRenderer,
    a,
    b,
    c,
    d,
    normal: Vec3,
    color: Vec4
) =
  renderer.addVertex(a, normal, color)
  renderer.addVertex(b, normal, color)
  renderer.addVertex(c, normal, color)
  renderer.addVertex(a, normal, color)
  renderer.addVertex(c, normal, color)
  renderer.addVertex(d, normal, color)

proc rotateAroundY*(value: Vec3, angle: float32): Vec3 =
  let
    cosine = cos(angle)
    sine = sin(angle)
  vec3(
    value.x * cosine - value.z * sine,
    value.y,
    value.x * sine + value.z * cosine
  )

proc rotateAroundX*(value: Vec3, angle: float32): Vec3 =
  let
    cosine = cos(angle)
    sine = sin(angle)
  vec3(
    value.x,
    value.y * cosine - value.z * sine,
    value.y * sine + value.z * cosine
  )

proc rotateAroundZ*(value: Vec3, angle: float32): Vec3 =
  let
    cosine = cos(angle)
    sine = sin(angle)
  vec3(
    value.x * cosine - value.y * sine,
    value.x * sine + value.y * cosine,
    value.z
  )

proc transformCardVector*(
    pose: CardPose,
    value: Vec3
): Vec3 =
  ## Roll turns the card about its long axis, then yaw and pitch place it.
  rotateAroundY(
    rotateAroundX(rotateAroundY(rotateAroundZ(value, pose.roll), pose.yaw),
      pose.pitch), pose.frameYaw)

proc inverseCardVector*(
    pose: CardPose,
    value: Vec3
): Vec3 =
  rotateAroundZ(rotateAroundY(rotateAroundX(
    rotateAroundY(value, -pose.frameYaw), -pose.pitch), -pose.yaw), -pose.roll)

proc cardNormal*(pose: CardPose): Vec3 =
  pose.transformCardVector(vec3(0, 1, 0))

proc darker*(color: Vec4, factor: float32): Vec4 =
  vec4(
    color.x * factor,
    color.y * factor,
    color.z * factor,
    color.w
  )

proc addBox*(
    renderer: var SolidRenderer,
    center,
    size: Vec3,
    topColor: Vec4,
    yaw = 0.0'f32,
    sideFactor = 0.62'f32,
    pitch = 0.0'f32,
    roll = 0.0'f32
) =
  let
    h = size * 0.5'f32
    localCorners = [
      vec3(-h.x, -h.y, -h.z),
      vec3(h.x, -h.y, -h.z),
      vec3(h.x, -h.y, h.z),
      vec3(-h.x, -h.y, h.z),
      vec3(-h.x, h.y, -h.z),
      vec3(h.x, h.y, -h.z),
      vec3(h.x, h.y, h.z),
      vec3(-h.x, h.y, h.z)
    ]
  let pose = CardPose(yaw: yaw, pitch: pitch, roll: roll)
  var corners: array[8, Vec3]
  for i, corner in localCorners:
    corners[i] = center + pose.transformCardVector(corner)
  let
    sideColor = topColor.darker(sideFactor)
    bottomColor = topColor.darker(sideFactor * 0.72'f32)
    up = pose.transformCardVector(vec3(0, 1, 0))
    down = pose.transformCardVector(vec3(0, -1, 0))
    north = pose.transformCardVector(vec3(0, 0, -1))
    south = pose.transformCardVector(vec3(0, 0, 1))
    west = pose.transformCardVector(vec3(-1, 0, 0))
    east = pose.transformCardVector(vec3(1, 0, 0))
  renderer.addQuad(
    corners[4], corners[7], corners[6], corners[5], up, topColor)
  renderer.addQuad(
    corners[0], corners[1], corners[2], corners[3], down, bottomColor)
  renderer.addQuad(
    corners[0], corners[4], corners[5], corners[1], north, sideColor)
  renderer.addQuad(
    corners[3], corners[2], corners[6], corners[7], south, sideColor)
  renderer.addQuad(
    corners[0], corners[3], corners[7], corners[4], west, sideColor)
  renderer.addQuad(
    corners[1], corners[5], corners[6], corners[2], east, sideColor)

proc addRoundedSlab*(
    renderer: var SolidRenderer,
    center,
    size: Vec3,
    radius: float32,
    topColor: Vec4,
    yaw = 0.0'f32,
    sideFactor = 0.62'f32,
    pitch = 0.0'f32,
    roll = 0.0'f32,
    frameYaw = 0.0'f32
) =
  ## A box with rounded vertical edges: a rounded-rectangle outline
  ## extruded along the pose's up axis. Side normals follow the curve.
  let
    h = size * 0.5'f32
    r = clamp(radius, 0.0'f32, min(h.x, h.z))
    pose = CardPose(yaw: yaw, pitch: pitch, roll: roll, frameYaw: frameYaw)
    sideColor = topColor.darker(sideFactor)
    bottomColor = topColor.darker(sideFactor * 0.72'f32)
    up = pose.transformCardVector(vec3(0, 1, 0))
    top = center + up * h.y
    bottom = center - up * h.y
  # Corner arcs counterclockwise from +x, +z, as seen from above.
  var outline, normals: seq[Vec3]
  for (cx, cz, start) in [(1.0'f32, 1.0'f32, 0.0'f32),
      (-1.0'f32, 1.0'f32, 0.5'f32), (-1.0'f32, -1.0'f32, 1.0'f32),
      (1.0'f32, -1.0'f32, 1.5'f32)]:
    for step in 0 .. CardCornerSegments:
      let
        angle = (start + 0.5'f32 * step.float32 /
          CardCornerSegments.float32) * PI.float32
        direction = vec3(cos(angle), 0, sin(angle))
        corner = vec3(cx * (h.x - r), 0, cz * (h.z - r))
      outline.add pose.transformCardVector(corner + direction * r)
      normals.add pose.transformCardVector(direction)
  for i in 0 ..< outline.len:
    let
      j = (i + 1) mod outline.len
      a = outline[i]
      b = outline[j]
    renderer.addVertex(top, up, topColor)
    renderer.addVertex(top + a, up, topColor)
    renderer.addVertex(top + b, up, topColor)
    renderer.addVertex(bottom, -up, bottomColor)
    renderer.addVertex(bottom + b, -up, bottomColor)
    renderer.addVertex(bottom + a, -up, bottomColor)
    renderer.addVertex(bottom + a, normals[i], sideColor)
    renderer.addVertex(top + a, normals[i], sideColor)
    renderer.addVertex(top + b, normals[j], sideColor)
    renderer.addVertex(bottom + a, normals[i], sideColor)
    renderer.addVertex(top + b, normals[j], sideColor)
    renderer.addVertex(bottom + b, normals[j], sideColor)

proc draw*(
    renderer: var SolidRenderer,
    viewProjection: Mat4
) =
  if renderer.vertices.len == 0:
    return
  glBindBuffer(GL_ARRAY_BUFFER, renderer.vertexBuffer)
  glBufferData(
    GL_ARRAY_BUFFER,
    renderer.vertices.len * sizeof(float32),
    renderer.vertices[0].addr,
    GL_DYNAMIC_DRAW
  )
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_TRUE)
  glDisable(GL_BLEND)
  glDisable(GL_CULL_FACE)
  glUseProgram(renderer.program)
  solidViewProjection = viewProjection
  solidLightDirection = normalize(vec3(-0.5, 1.0, 0.65))
  glUniformMatrix4fv(
    glGetUniformLocation(renderer.program, "solidViewProjection"),
    1,
    GL_FALSE,
    cast[ptr float32](solidViewProjection.addr)
  )
  glUniform3f(
    glGetUniformLocation(renderer.program, "solidLightDirection"),
    solidLightDirection.x,
    solidLightDirection.y,
    solidLightDirection.z
  )
  glBindVertexArray(renderer.vertexArray)
  glDrawArrays(
    GL_TRIANGLES,
    0,
    (renderer.vertices.len div 10).GLsizei
  )
  glBindVertexArray(0)


proc classColor*(heroClass: HeroClass): Vec4 =
  case heroClass
  of Archer:
    vec4(0.17, 0.68, 0.31, 1)
  of Warrior:
    vec4(0.78, 0.18, 0.14, 1)
  of Mage:
    vec4(0.18, 0.38, 0.86, 1)


proc stackTopPose*(pose: CardPose, count: int): CardPose =
  result = pose
  result.position.y +=
    max(0, min(count, 7) - 1).float32 * StackStep

proc addCard*(
    renderer: var SolidRenderer,
    faces: var CardRenderer,
    sk: Silky,
    pose: CardPose,
    heroClass: HeroClass,
    hidden,
    enabled,
    hovered: bool,
    targetable = false,
    card = Card(),
    currentPower = -1,
    currentToughness = -1,
    damageFlash = 0.0'f32,
    lostKeywords: set[Keyword] = {}
) =
  ## A minion on the battlefield passes its live stats (currentToughness
  ## >= 0); they are drawn over a stat-less face.
  var raised = pose.position
  if targetable:
    raised.y += 0.08'f32
  if hovered:
    raised.y += 0.16'f32
  let
    edgeColor =
      if targetable: vec4(0.9, 0.04, 0.07, 1)
      elif hovered: vec4(0.92, 0.78, 0.48, 1)
      else: CardBackSteel
    rim = if hovered or targetable: 0.09'f32 else: 0.0'f32
  # The body ends where the art's opaque silhouette does, corners included.
  renderer.addRoundedSlab(
    raised,
    vec3(CardBodyWidth + rim, CardHeight, CardBodyDepth + rim),
    CardCornerRadius + rim * 0.5'f32,
    edgeColor,
    pose.yaw,
    0.85,
    pose.pitch,
    pose.roll,
    pose.frameYaw
  )
  let
    halfWidth = CardWidth * 0.5'f32
    halfDepth = CardDepth * 0.5'f32
    surfaceY = CardHeight * 0.5'f32 + 0.004'f32
    local = [
      vec3(-halfWidth, surfaceY, -halfDepth),
      vec3(-halfWidth, surfaceY, halfDepth),
      vec3(halfWidth, surfaceY, halfDepth),
      vec3(halfWidth, surfaceY, -halfDepth)
    ]
    liveStats = not hidden and card.name.len > 0 and
      card.kind == Minion and currentToughness >= 0
    imageKey =
      if hidden or card.name.len == 0: CardBackKey
      else: sk.bakedCardImage(card)
    brightness = if hidden or enabled: 1.0'f32 else: 0.68'f32
  var corners: array[4, Vec3]
  for i in 0 ..< corners.len:
    corners[i] = raised + pose.transformCardVector(local[i])
  faces.addSurface(sk, corners, imageKey, brightness, damageFlash)
  if liveStats:
    faces.addMinionOverlays(sk, corners, card,
      if currentPower >= 0: currentPower else: card.power,
      currentToughness, lostKeywords, brightness, damageFlash)


proc addCardStack*(
    renderer: var SolidRenderer,
    faces: var CardRenderer,
    sk: Silky,
    pose: CardPose,
    count: int,
    heroClass: HeroClass,
    hidden = true,
    card = Card()
) =
  for i in 0 ..< min(count, 7):
    var cardPose = pose
    cardPose.position.y += i.float32 * StackStep
    renderer.addCard(
      faces, sk, cardPose, heroClass, hidden, true, false, card = card
    )

proc fanPoses*(count: int, center: Vec3, pitch, facing, yaw,
    roll: float32, spread = 7.8'f32): seq[CardPose] =
  ## A hand of `count` cards fanned around `center` and tilted by `pitch`
  ## toward a viewer on the `facing` side (1 or -1 along Z). `yaw` turns
  ## every card toward that viewer; `spread` caps the fan's width.
  if count <= 0:
    return
  let
    spacing =
      if count == 1:
        0.0'f32
      else:
        min(1.08'f32, spread / (count - 1).float32)
    middle = (count - 1).float32 * 0.5'f32
    fanRadius =
      if middle > 0:
        spacing * middle / sin(HandFanAngle)
      else:
        0.0'f32
  result.setLen(count)
  for i in 0 ..< count:
    let
      offset = i.float32 - middle
      normalized =
        if middle > 0:
          offset / middle
        else:
          0.0'f32
      angle = normalized * HandFanAngle
      fanOffset = rotateAroundX(
        vec3(
          sin(angle) * fanRadius,
          0,
          facing * (1.0'f32 - cos(angle)) * fanRadius
        ),
        pitch
      )
    result[i] = CardPose(
      # A tiny separation keeps overlapping illustrated faces from sharing
      # exactly the same depth, and matches the hand's back-to-front order.
      position: center + fanOffset +
        rotateAroundX(vec3(0, i.float32 * 0.003'f32, 0), pitch),
      # Keep the card's width tangent to the fan circle.
      yaw: yaw + facing * angle,
      pitch: pitch,
      roll: roll
    )

proc newCardAnimation*(
    card: Card,
    heroClass: HeroClass,
    fromPose,
    toPose: CardPose,
    arcHeight = 1.4'f32,
    suppressBoardId = -1,
    suppressHandOwner = -1,
    suppressHandIndex = -1,
    suppressDiscardOwner = -1,
    suppressCastSpell = false,
    hidden = false,
    duration = CardMoveDuration,
    trackingTarget = Canceled
): CardAnimation =
  CardAnimation(
    card: card,
    heroClass:
      if card.class.isSome:
        card.class.get()
      else:
        heroClass,
    fromPose: fromPose,
    toPose: toPose,
    duration: duration,
    arcHeight: arcHeight,
    suppressBoardId: suppressBoardId,
    suppressHandOwner: suppressHandOwner,
    suppressHandIndex: suppressHandIndex,
    suppressDiscardOwner: suppressDiscardOwner,
    suppressCastSpell: suppressCastSpell,
    hidden: hidden,
    trackingTarget: trackingTarget
  )

proc animationPose*(animation: CardAnimation): CardPose =
  let
    raw =
      if animation.duration > 0:
        clamp(animation.elapsed / animation.duration, 0.0'f32, 1.0'f32)
      else:
        1.0'f32
    eased = raw * raw * (3.0'f32 - 2.0'f32 * raw)
    angleDifference = arctan2(
      sin(animation.toPose.yaw - animation.fromPose.yaw),
      cos(animation.toPose.yaw - animation.fromPose.yaw)
    )
  result.position =
    animation.fromPose.position +
    (animation.toPose.position - animation.fromPose.position) * eased
  result.position.y += sin(PI.float32 * raw) * animation.arcHeight
  result.yaw = animation.fromPose.yaw + angleDifference * eased
  result.pitch =
    animation.fromPose.pitch +
    (animation.toPose.pitch - animation.fromPose.pitch) * eased
  result.roll =
    animation.fromPose.roll +
    (animation.toPose.roll - animation.fromPose.roll) * eased
  # A card flies within one balcony's frame; the duel has none.
  result.frameYaw = animation.toPose.frameYaw

proc advanceAnimations*(
    animations: var seq[CardAnimation],
    deltaTime: float32
) =
  if animations.len == 0:
    return
  for animation in animations.mitems:
    animation.elapsed += deltaTime
  for i in countdown(animations.high, 0):
    if animations[i].elapsed >= animations[i].duration:
      animations.delete(i)

proc boardCardSuppressed*(
    animations: openArray[CardAnimation],
    minionId: int
): bool =
  for animation in animations:
    if animation.suppressBoardId == minionId:
      return true

proc handCardSuppressed*(
    animations: openArray[CardAnimation],
    playerIndex,
    cardIndex: int
): bool =
  for animation in animations:
    if animation.suppressHandOwner == playerIndex and
        animation.suppressHandIndex == cardIndex:
      return true

proc discardCardsSuppressed*(
    animations: openArray[CardAnimation],
    playerIndex: int
): int =
  for animation in animations:
    if animation.suppressDiscardOwner == playerIndex:
      inc result

proc castSpellSuppressed*(animations: openArray[CardAnimation]): bool =
  ## A played spell is still on its way to the spot it floats in.
  for animation in animations:
    if animation.suppressCastSpell:
      return true

proc newDrawAnimation*(card: Card, heroClass: HeroClass,
    deckTop, handPose: CardPose, owner, handIndex: int,
    hidden: bool): CardAnimation =
  ## A card drawn from the top of a deck into its hand slot, which stays
  ## empty until the card lands. Every game mode draws with this.
  newCardAnimation(card, heroClass, deckTop, handPose,
    arcHeight = 1.0'f32,
    suppressHandOwner = owner,
    suppressHandIndex = handIndex,
    hidden = hidden,
    duration = DrawMoveDuration
  )

proc addFlyingCards*(renderer: var SolidRenderer, faces: var CardRenderer,
    sk: Silky, animations: openArray[CardAnimation]) =
  for animation in animations:
    renderer.addCard(
      faces, sk,
      animation.animationPose(),
      animation.heroClass,
      animation.hidden,
      true,
      false,
      card = animation.card
    )

proc screenPosition*(
    window: Window,
    position: Vec3,
    viewProjection: Mat4
): Vec2 =
  let clip = viewProjection * vec4(position, 1)
  if clip.w <= 0:
    return vec2(-10000)
  let normalized = vec2(clip.x / clip.w, clip.y / clip.w)
  vec2(
    (normalized.x * 0.5'f32 + 0.5'f32) * window.size.x.float32,
    (0.5'f32 - normalized.y * 0.5'f32) * window.size.y.float32
  )

proc mouseRay*(
    window: Window,
    viewProjection: Mat4
): tuple[origin, direction: Vec3] =
  let
    width = max(window.size.x.float32, 1)
    height = max(window.size.y.float32, 1)
    ndcX = 2.0'f32 * window.mousePos.vec2.x / width - 1.0'f32
    ndcY = 1.0'f32 - 2.0'f32 * window.mousePos.vec2.y / height
    inverseViewProjection = inverse(viewProjection)
  var
    nearPoint = inverseViewProjection * vec4(ndcX, ndcY, -1, 1)
    farPoint = inverseViewProjection * vec4(ndcX, ndcY, 1, 1)
  result.origin = nearPoint.xyz / nearPoint.w
  let farPosition = farPoint.xyz / farPoint.w
  result.direction = normalize(farPosition - result.origin)


proc mouseCardOffset*(
    window: Window,
    viewProjection: Mat4,
    pose: CardPose
): float32 =
  ## How far the mouse's point on the card is from the card's centre, or
  ## -1 when the mouse isn't over the card. Crowded boards overlap, so the
  ## closest card is the one under the mouse.
  result = -1
  let
    ray = mouseRay(window, viewProjection)
    normal = pose.cardNormal()
    denominator = dot(ray.direction, normal)
  if abs(denominator) < 1e-5'f32:
    return
  let distance = dot(pose.position - ray.origin, normal) / denominator
  if distance <= 0:
    return
  let local = pose.inverseCardVector(
    ray.origin + ray.direction * distance - pose.position
  )
  if abs(local.x) <= CardWidth * 0.5'f32 and
      abs(local.z) <= CardDepth * 0.5'f32:
    result = sqrt(local.x * local.x + local.z * local.z)

proc mouseHitsCard*(
    window: Window,
    viewProjection: Mat4,
    pose: CardPose
): bool =
  mouseCardOffset(window, viewProjection, pose) >= 0
