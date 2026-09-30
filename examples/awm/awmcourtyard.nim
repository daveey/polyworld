## The Old Crossroads: deterministic, class-neutral 3D scenery.
## Geometry uses its own RNG; building the arena never changes a card deal.
## The floor stays below the cards. Tall scenery is drawn behind the current
## seat only, so the spectator's reverse camera never looks through a wall.
import std/[math, random]
import vmath
import awmmultiplayer

type
  CourtyardVertex* = object
    position*, normal*: Vec3
    color*: Vec3
    material*: float32
    uv*: Vec2
  CourtyardMesh* = object
    vertices*: seq[CourtyardVertex]
    commonCount*, backdropCount*, pavingCount*: int
    centerCount*: int
      ## Multiplayer: the static center island, at the start of the common
      ## range; the balconies after it can turn (see stageRotation).

const
  Stone = 0.0'f32
  Metal = 1.0'f32
  Leaf = 2.0'f32
  Cloth = 3.0'f32
  Flame = 4.0'f32
  Earth = 5.0'f32
  PavingHalfWidth* = 10.15'f32
  PavingHalfDepth* = 7.30'f32
  Tau = 2.0'f32 * PI.float32
  Sandstone = vec3(0.43, 0.395, 0.33)
  Brass = vec3(0.43, 0.31, 0.13)

const
  # The courtyard's own night lighting. courtyard.frag uses the same values;
  # awm.nim lights the heroes with them so they belong to the scene.
  CourtyardKeyColor* = vec3(0.67, 0.53, 0.36)
  CourtyardAmbientGround* = vec3(0.33, 0.35, 0.39)
  CourtyardAmbientSky* = vec3(0.62, 0.64, 0.68)
  CourtyardLampColor* = vec3(1.0, 0.45, 0.115)

proc courtyardKeyDirection*(cameraSide: float32): Vec3 =
  ## Toward the key light, for the seat the camera sits at.
  normalize(vec3(-0.48'f32 * cameraSide, 0.85, 0.35'f32 * cameraSide))

proc triangle(m: var CourtyardMesh, a, b, c: Vec3, color: Vec3,
    material = Stone, ua = vec2(0), ub = vec2(0), uc = vec2(0)) =
  let n = cross(b - a, c - a)
  if length(n) < 0.000001'f32: return
  let normal = normalize(n)
  for (p, uv) in [(a, ua), (b, ub), (c, uc)]:
    m.vertices.add CourtyardVertex(position: p, normal: normal,
      color: color, material: material, uv: uv)

proc quad(m: var CourtyardMesh, a, b, c, d: Vec3, color: Vec3,
    material = Stone) =
  m.triangle(a, b, c, color, material)
  m.triangle(a, c, d, color, material)

proc turn(p: Vec3, yaw: float32): Vec3 =
  vec3(p.x * cos(yaw) - p.z * sin(yaw), p.y,
    p.x * sin(yaw) + p.z * cos(yaw))

proc stoneSlab(m: var CourtyardMesh, footprint: openArray[Vec2],
    bottom, top: float32, color: Vec3, bevel = 0.045'f32,
    material = Stone) =
  ## Chamfered polygon prism, with a real bevel catching the evening light.
  var center = vec2(0)
  for p in footprint: center += p
  center /= footprint.len.float32
  for i in 0 ..< footprint.len:
    let
      j = (i + 1) mod footprint.len
      a = footprint[i]
      b = footprint[j]
      ia = a + normalize(center - a) * bevel
      ib = b + normalize(center - b) * bevel
      a0 = vec3(a.x, bottom, a.y)
      b0 = vec3(b.x, bottom, b.y)
      a1 = vec3(a.x, top - bevel * 0.65'f32, a.y)
      b1 = vec3(b.x, top - bevel * 0.65'f32, b.y)
      a2 = vec3(ia.x, top, ia.y)
      b2 = vec3(ib.x, top, ib.y)
    m.quad(a0, a1, b1, b0, color * 0.85'f32, material)
    m.quad(a1, a2, b2, b1, color * 1.08'f32, material)
    m.triangle(vec3(center.x, top, center.y), b2, a2, color, material)

proc addBlock(m: var CourtyardMesh, center, size, color: Vec3,
    yaw = 0.0'f32, bevel = 0.06'f32, material = Stone) =
  let
    h = size * 0.5'f32
    cut = min(min(h.x, h.z) * 0.28'f32, 0.11'f32)
  var footprint: seq[Vec2]
  for p in [vec3(-h.x + cut, 0, -h.z), vec3(h.x - cut, 0, -h.z),
      vec3(h.x, 0, -h.z + cut), vec3(h.x, 0, h.z - cut),
      vec3(h.x - cut, 0, h.z), vec3(-h.x + cut, 0, h.z),
      vec3(-h.x, 0, h.z - cut), vec3(-h.x, 0, -h.z + cut)]:
    let q = center + turn(p, yaw)
    footprint.add vec2(q.x, q.z)
  m.stoneSlab(footprint, center.y - h.y, center.y + h.y,
    color, bevel, material)

proc beam(m: var CourtyardMesh, a, b: Vec3, width: float32,
    color: Vec3, material = Metal) =
  let
    direction = normalize(b - a)
    reference = if abs(direction.y) > 0.9'f32: vec3(1, 0, 0)
      else: vec3(0, 1, 0)
    u = normalize(cross(direction, reference)) * width * 0.5'f32
    v = normalize(cross(direction, u)) * width * 0.5'f32
    points = [u + v, -u + v, -u - v, u - v]
  for i in 0 .. 3:
    let j = (i + 1) mod 4
    m.quad(a + points[i], b + points[i], b + points[j], a + points[j],
      color, material)
  m.quad(b + points[3], b + points[2], b + points[1], b + points[0],
    color, material)

proc ring(m: var CourtyardMesh, inner, outer, y: float32,
    color: Vec3, segments = 120, material = Metal) =
  for i in 0 ..< segments:
    let
      a = Tau * i.float32 / segments.float32
      b = Tau * (i + 1).float32 / segments.float32
    m.quad(vec3(cos(a) * inner, y, sin(a) * inner),
      vec3(cos(b) * inner, y, sin(b) * inner),
      vec3(cos(b) * outer, y, sin(b) * outer),
      vec3(cos(a) * outer, y, sin(a) * outer), color, material)

proc leaf(m: var CourtyardMesh, center, along, across: Vec3, color: Vec3) =
  let ridge = center + vec3(0, 0.025, 0.025)
  m.triangle(center - along, center - across, ridge, color * 0.85'f32, Leaf)
  m.triangle(center - across, center + along, ridge, color, Leaf)
  m.triangle(center + along, center + across, ridge, color * 1.10'f32, Leaf)
  m.triangle(center + across, center - along, ridge, color, Leaf)

proc ivy(m: var CourtyardMesh, rng: var Rand, base: Vec3, height: float32) =
  let steps = max(2, int(height / 0.16'f32))
  var previous = base
  for j in 0 .. steps:
    let
      t = j.float32 / steps.float32
      p = base + vec3(sin(t * 10 + base.x) * 0.17'f32,
        t * height, sin(t * 8) * 0.035'f32)
    if j > 0: m.beam(previous, p, 0.021, vec3(0.18, 0.16, 0.08), Leaf)
    previous = p
    for sign in [-1.0'f32, 1.0'f32]:
      let
        span = rng.rand(0.09 .. 0.19).float32
        c = p + vec3(sign * span * 0.9'f32, 0.035, 0.045)
        color = vec3(0.22, 0.255, 0.095) * rng.rand(0.65 .. 1.25).float32
      m.leaf(c, vec3(sign * span, span * 0.45'f32, 0.035),
        vec3(-sign * span * 0.34'f32, span * 0.56'f32, 0.02), color)

proc grass(m: var CourtyardMesh, rng: var Rand, base: Vec3, scale: float32) =
  for i in 0 ..< 9:
    let
      angle = rng.rand(Tau)
      height = rng.rand(0.22 .. 0.52).float32 * scale
      lean = vec3(cos(angle), 0, sin(angle))
      side = vec3(-sin(angle), 0, cos(angle)) * 0.024'f32 * scale
      foot = base + lean * rng.rand(0.0 .. 0.07).float32
      middle = foot + vec3(0, height * 0.62'f32, 0) + lean * height * 0.2'f32
      tip = foot + vec3(0, height, 0) + lean * height * 0.55'f32
      color = vec3(0.40, 0.31, 0.13) * rng.rand(0.65 .. 1.20).float32
    m.quad(foot - side, middle - side * 0.6'f32,
      middle + side * 0.6'f32, foot + side, color, Leaf)
    m.triangle(middle - side * 0.6'f32, tip, middle + side * 0.6'f32,
      color * 1.12'f32, Leaf)

proc arch(m: var CourtyardMesh, rng: var Rand, origin: Vec3,
    radius, spring, thickness: float32) =
  ## Individual voussoirs, including front bevels and the soffit of the arch.
  let outer = radius + thickness
  for side in [-1.0'f32, 1.0'f32]:
    for row in 0 ..< int(ceil(spring / 0.48'f32)):
      m.addBlock(origin + vec3(side * (radius + thickness / 2),
        row.float32 * 0.48'f32 + 0.22'f32, 0),
        vec3(thickness + 0.07, 0.45, 0.86),
        Sandstone * rng.rand(0.85 .. 1.12).float32)
    m.addBlock(origin + vec3(side * (radius + thickness / 2), 0.15, 0),
      vec3(thickness + 0.32, 0.30, 1.08), Sandstone)
    m.addBlock(origin + vec3(side * (radius + thickness / 2), spring - 0.05, 0),
      vec3(thickness + 0.22, 0.21, 1.04), Sandstone * 1.08'f32)
  const segments = 17
  for i in 0 ..< segments:
    let
      a = PI.float32 * i.float32 / segments.float32 + 0.005'f32
      b = PI.float32 * (i + 1).float32 / segments.float32 - 0.005'f32
      points = [vec2(cos(a) * radius, sin(a) * radius + spring),
        vec2(cos(a) * outer, sin(a) * outer + spring),
        vec2(cos(b) * outer, sin(b) * outer + spring),
        vec2(cos(b) * radius, sin(b) * radius + spring)]
      color = Sandstone * rng.rand(0.87 .. 1.14).float32
    var center = vec2(0)
    for p in points: center += p * 0.25'f32
    for j in 0 .. 3:
      let
        k = (j + 1) mod 4
        p = points[j]
        q = points[k]
        ip = p + normalize(center - p) * 0.045'f32
        iq = q + normalize(center - q) * 0.045'f32
        frontP = origin + vec3(ip.x, ip.y, 0.46)
        frontQ = origin + vec3(iq.x, iq.y, 0.46)
        edgeP = origin + vec3(p.x, p.y, 0.39)
        edgeQ = origin + vec3(q.x, q.y, 0.39)
        backP = origin + vec3(p.x, p.y, -0.43)
        backQ = origin + vec3(q.x, q.y, -0.43)
      m.triangle(origin + vec3(center.x, center.y, 0.46),
        frontP, frontQ, color)
      m.quad(frontP, edgeP, edgeQ, frontQ, color * 1.04'f32)
      m.quad(edgeP, backP, backQ, edgeQ, color * 0.86'f32)
      m.triangle(origin + vec3(center.x, center.y, -0.43),
        backQ, backP, color * 0.8'f32)

proc banner(m: var CourtyardMesh, center: Vec3) =
  ## A subdivided cloth surface, animated on the GPU. UVs also describe the
  ## woven fabric, stitched border and neutral four-point crossroads crest.
  let iron = vec3(0.20, 0.16, 0.105)
  m.beam(center + vec3(-0.84, 0.06, 0), center + vec3(0.84, 0.06, 0),
    0.075, iron)
  for x in [-0.83'f32, 0.83'f32]:
    m.addBlock(center + vec3(x, 0.06, 0), vec3(0.13), Brass, bevel = 0.02,
      material = Metal)
  const nx = 16
  const ny = 22
  proc at(u, v: float32): Vec3 =
    center + vec3((u - 0.5'f32) * 1.48'f32,
      -v * (1.93'f32 + 0.32'f32 * (1 - abs(u - 0.5'f32) * 2)),
      sin(u * 15) * 0.075'f32 * v + 0.05'f32)
  for y in 0 ..< ny:
    for x in 0 ..< nx:
      let
        u = x.float32 / nx.float32
        v = y.float32 / ny.float32
        u1 = (x + 1).float32 / nx.float32
        v1 = (y + 1).float32 / ny.float32
        a = at(u, v)
        b = at(u1, v)
        c = at(u1, v1)
        d = at(u, v1)
        color = vec3(0.105, 0.17, 0.23)
      m.triangle(a, d, c, color, Cloth, vec2(u, v), vec2(u, v1), vec2(u1, v1))
      m.triangle(a, c, b, color, Cloth, vec2(u, v), vec2(u1, v1), vec2(u1, v))

proc lantern(m: var CourtyardMesh, center: Vec3) =
  let iron = vec3(0.16, 0.115, 0.06)
  m.addBlock(center + vec3(0, -0.51, 0), vec3(0.80, 0.16, 0.65), Sandstone)
  m.addBlock(center + vec3(0, -0.33, 0), vec3(0.43, 0.10, 0.37), iron,
    bevel = 0.025, material = Metal)
  m.addBlock(center, vec3(0.29, 0.60, 0.24), vec3(1.0, 0.52, 0.10),
    bevel = 0.02, material = Flame)
  for x in [-0.19'f32, 0.19'f32]:
    for z in [-0.15'f32, 0.15'f32]:
      m.beam(center + vec3(x, -0.30, z), center + vec3(x, 0.34, z),
        0.055, iron)
  m.addBlock(center + vec3(0, 0.35, 0), vec3(0.46, 0.08, 0.39), iron,
    bevel = 0.02, material = Metal)
  let peak = center + vec3(0, 0.62, 0)
  for i in 0 .. 3:
    let corners = [vec3(-0.27, 0.38, -0.23), vec3(0.27, 0.38, -0.23),
      vec3(0.27, 0.38, 0.23), vec3(-0.27, 0.38, 0.23)]
    m.triangle(center + corners[i], peak, center + corners[(i + 1) mod 4],
      iron, Metal)
  m.beam(center + vec3(0, 0.60, 0), center + vec3(0, 0.79, 0), 0.055, Brass)

proc buildBackdrop(m: var CourtyardMesh, rng: var Rand) =
  m.arch(rng, vec3(0, -0.04, -7.05), 2.05, 2.2, 0.66)
  # Low ruined enclosure, with an open route through the central arch.
  for side in [-1.0'f32, 1.0'f32]:
    for column in 0 ..< 7:
      let
        x = side * (3.4'f32 + column.float32 * 1.10'f32)
        rows = if column in [2, 5, 6]: 4 else: 3
      for row in 0 ..< rows:
        m.addBlock(vec3(x + (row mod 2).float32 * 0.19'f32,
          0.24'f32 + row.float32 * 0.49'f32, -7.05),
          vec3(1.04, 0.46, rng.rand(0.70 .. 0.90).float32),
          Sandstone * rng.rand(0.80 .. 1.13).float32,
          rng.rand(-0.03 .. 0.03).float32)
    # Banner piers are outside both the hand and piles.
    let x = side * 8.6'f32
    for row in 0 ..< 7:
      m.addBlock(vec3(x, row.float32 * 0.46'f32 + 0.21'f32, -7.15),
        vec3(1.55, 0.43, 1.0), Sandstone * rng.rand(0.85 .. 1.08).float32,
        rng.rand(-0.02 .. 0.02).float32)
    m.addBlock(vec3(x, 3.25, -7.15), vec3(1.84, 0.23, 1.22), Sandstone)
    m.banner(vec3(x, 3.07, -6.55))
    m.lantern(vec3(side * 6.75'f32, 1.25, -6.32))
    for i in 0 ..< 12:
      m.ivy(rng, vec3(side * rng.rand(3.0 .. 9.9).float32,
        0.03, -6.52), rng.rand(0.45 .. 1.95).float32)
    for i in 0 ..< 32:
      let p = vec3(side * rng.rand(3.0 .. 9.5).float32,
        0.035, rng.rand(-6.5 .. -5.9).float32)
      if i mod 3 == 0:
        m.addBlock(p + vec3(0, 0.08, 0),
          vec3(rng.rand(0.25 .. 0.65).float32, rng.rand(0.16 .. 0.35).float32,
            rng.rand(0.23 .. 0.51).float32),
          Sandstone * rng.rand(0.73 .. 1.0).float32, rng.rand(Tau))
      else: m.grass(rng, p, rng.rand(0.7 .. 1.3).float32)

proc buildCourtyardMesh*(): CourtyardMesh =
  var rng = initRand(20260921)
  # Clip the paving to the wall footprint, including the end of odd rows.
  # The ground beyond the enclosure is intentionally open to the night sky.
  for row in -6 .. 6:
    for col in -8 .. 8:
      let
        x = col.float32 * 1.30'f32 + (row mod 2).float32 * 0.65'f32
        z = row.float32 * 1.17'f32
        left = max(-PavingHalfWidth, x - 0.63'f32)
        right = min(PavingHalfWidth, x + 0.63'f32)
        near = max(-PavingHalfDepth, z - 0.565'f32)
        far = min(PavingHalfDepth, z + 0.565'f32)
      if right - left < 0.09 or far - near < 0.09: continue
      if x * x + z * z < 4.7'f32 * 4.7'f32: continue
      result.addBlock(vec3((left + right) * 0.5'f32, -0.09,
          (near + far) * 0.5'f32),
        vec3(right - left, 0.15, far - near),
        Sandstone * rng.rand(0.87 .. 1.10).float32,
        bevel = 0.025)
  result.pavingCount = result.vertices.len
  result.addBlock(vec3(0, -0.42, 0), vec3(21.1, 0.56, 15.6),
    vec3(0.19, 0.18, 0.145), bevel = 0.05, material = Earth)
  # Five concentric courses of hand-cut stone, each piece a separate mesh.
  for course in 0 ..< 6:
    let
      inner = course.float32 * 0.88'f32
      outer = inner + 0.855'f32
      segments = max(8, int((inner + outer) * PI.float32 / 1.10'f32))
      stagger = (course mod 2).float32 * 0.5'f32
    for segment in 0 ..< segments:
      let
        a = Tau * (segment.float32 + stagger) / segments.float32 + 0.002'f32
        b = Tau * (segment.float32 + stagger + 1) / segments.float32 - 0.002'f32
      var points: seq[Vec2]
      for step in 0 .. 3:
        let t = a + (b - a) * step.float32 / 3
        points.add vec2(cos(t), sin(t)) * max(0.07'f32, inner + 0.018'f32)
      for step in countdown(3, 0):
        let t = a + (b - a) * step.float32 / 3
        points.add vec2(cos(t), sin(t)) * outer
      # Reverse to the same winding as the rectangular slabs.
      var ordered: seq[Vec2]
      for i in countdown(points.high, 0): ordered.add points[i]
      result.stoneSlab(ordered, -0.16, 0.006,
        Sandstone * rng.rand(0.87 .. 1.07).float32, bevel = 0.014)
  result.ring(4.37, 4.402, 0.012, Brass * 0.87'f32)
  result.ring(5.28, 5.325, 0.012, Brass)
  # Brass seams retain the board's visual center without a painted stripe.
  result.addBlock(vec3(0, 0.007, 0), vec3(0.065, 0.014, 13.0), Brass,
    bevel = 0.005, material = Metal)
  for side in [-1.0'f32, 1.0'f32]:
    result.addBlock(vec3(side * 4.86'f32, 0.009, 0), vec3(0.76, 0.012, 0.05),
      Brass, bevel = 0.003, material = Metal)
    # Both seats use the existing pile coordinates and card heights.
    for x in [-7.25'f32, 7.25'f32]:
      let p = vec3(x, -0.075, side * 3.7'f32)
      result.addBlock(p, vec3(2.04, 0.28, 2.65), Sandstone * 0.96'f32,
        bevel = 0.075)
      result.addBlock(p + vec3(0, 0.142, 0), vec3(1.72, 0.012, 2.32),
        vec3(0.20, 0.215, 0.205), bevel = 0.025)
      for sign in [-1.0'f32, 1.0'f32]:
        result.addBlock(p + vec3(sign * 0.91'f32, 0.146, 0),
          vec3(0.028, 0.013, 2.35), Brass, bevel = 0.003, material = Metal)
    # The long sides are low enough to frame rather than cover the heroes.
    for row in 0 .. 2:
      for column in -5 .. 5:
        if row == 2 and column mod 3 == 0: continue
        result.addBlock(vec3(side * 10.05'f32,
          row.float32 * 0.42'f32 + 0.18'f32,
          column.float32 * 1.16'f32 + (row mod 2).float32 * 0.33'f32),
          vec3(rng.rand(0.72 .. 0.93).float32, 0.39, 1.10),
          Sandstone * rng.rand(0.80 .. 1.12).float32,
          rng.rand(-0.028 .. 0.028).float32)
    for i in 0 ..< 95:
      let
        x = side * rng.rand(9.1 .. 10.15).float32
        z = rng.rand(-6.1 .. 6.1).float32
      if i mod 4 == 0:
        result.addBlock(vec3(x, 0.07, z),
          vec3(rng.rand(0.21 .. 0.67).float32, rng.rand(0.12 .. 0.28).float32,
            rng.rand(0.22 .. 0.62).float32),
          Sandstone * rng.rand(0.7 .. 1.0).float32, rng.rand(Tau))
      else:
        result.grass(rng, vec3(x, 0.005, z), rng.rand(0.55 .. 1.1).float32)
    for i in 0 ..< 24:
      result.ivy(rng, vec3(side * rng.rand(9.58 .. 10.05).float32,
        0.03, rng.rand(-6.0 .. 6.0).float32), rng.rand(0.35 .. 1.15).float32)
  result.commonCount = result.vertices.len
  result.buildBackdrop(rng)
  result.backdropCount = result.vertices.len - result.commonCount
  # An exact 180-degree counterpart for the other seat, with equal counts.
  for i in result.commonCount ..< result.commonCount + result.backdropCount:
    var vertex = result.vertices[i]
    vertex.position.x = -vertex.position.x
    vertex.position.z = -vertex.position.z
    vertex.normal.x = -vertex.normal.x
    vertex.normal.z = -vertex.normal.z
    result.vertices.add vertex

proc arcSlab(m: var CourtyardMesh, inner, outer, startAngle, endAngle,
    bottom, top: float32, color: Vec3, bevel = 0.025'f32,
    material = Stone) =
  ## One reusable curved masonry module, centered on the arena's origin.
  var footprint: seq[Vec2]
  for step in 0 .. 3:
    let angle = startAngle + (endAngle - startAngle) * step.float32 / 3
    footprint.add vec2(sin(angle), cos(angle)) * inner
  for step in countdown(3, 0):
    let angle = startAngle + (endAngle - startAngle) * step.float32 / 3
    footprint.add vec2(sin(angle), cos(angle)) * outer
  m.stoneSlab(footprint, bottom, top, color, bevel, material)

proc arcCourse(m: var CourtyardMesh, rng: var Rand, inner, outer,
    halfAngle, bottom, top: float32, color: Vec3,
    stagger = 0.0'f32, width = 1.15'f32, bevel = 0.025'f32) =
  let
    segments = max(2, int(ceil(halfAngle * (inner + outer) / width)))
    step = halfAngle * 2 / segments.float32
    seam = 0.014'f32 / max(inner, 1.0'f32)
  for index in -1 .. segments:
    let
      a = max(-halfAngle, -halfAngle + (index.float32 + stagger) * step) + seam
      b = min(halfAngle, -halfAngle + (index.float32 + stagger + 1) * step) - seam
    if b - a < seam: continue
    m.arcSlab(inner, outer, a, b, bottom, top,
      color * rng.rand(0.87 .. 1.09).float32, bevel)

proc appendTurned(m: var CourtyardMesh, piece: CourtyardMesh, yaw: float32) =
  for source in piece.vertices:
    var vertex = source
    vertex.position = turn(vertex.position, yaw)
    vertex.normal = turn(vertex.normal, yaw)
    m.vertices.add vertex

proc buildMultiplayerCourtyardMesh*(layout: MultiplayerLayout): CourtyardMesh =
  ## Floating stone islands share the existing sandstone, brass, cloth, ivy
  ## and lantern primitives. No walls span the gaps between player balconies.
  var rng = initRand(20260923)
  let
    centerRadius = layout.centerRadius
    inner = layout.innerRadius
    outer = layout.outerRadius
    halfAngle = layout.balconyHalfAngle
    middle = (inner + outer) * 0.5'f32

  # Small circular dais: separate concentric paving courses and a worn compass.
  for course in 0 ..< 4:
    let
      r0 = max(0.045'f32, course.float32 * centerRadius / 4)
      r1 = (course + 1).float32 * centerRadius / 4 - 0.025'f32
      segments = max(8, int(ceil((r0 + r1) * PI.float32 / 0.92'f32)))
    for index in 0 ..< segments:
      let
        offset = (course mod 2).float32 * 0.5'f32
        a = Tau * (index.float32 + offset) / segments.float32 + 0.004'f32
        b = Tau * (index.float32 + offset + 1) / segments.float32 - 0.004'f32
      result.arcSlab(r0, r1, a, b, -0.20, 0.006,
        Sandstone * rng.rand(0.87 .. 1.10).float32, bevel = 0.016)
  for course in 0 ..< 3:
    for index in 0 ..< 24:
      let
        stagger = (course mod 2).float32 * 0.5'f32
        a = Tau * (index.float32 + stagger) / 24 + 0.004'f32
        b = Tau * (index.float32 + stagger + 1) / 24 - 0.004'f32
      result.arcSlab(centerRadius - 0.40'f32, centerRadius + 0.05'f32,
        a, b, -1.36'f32 + course.float32 * 0.41'f32,
        -0.98'f32 + course.float32 * 0.41'f32,
        Sandstone * rng.rand(0.78 .. 1.0).float32, bevel = 0.035)
  for index in 0 ..< 28:
    let
      a = Tau * index.float32 / 28 + 0.003'f32
      b = Tau * (index + 1).float32 / 28 - 0.003'f32
    result.arcSlab(centerRadius - 0.17'f32, centerRadius + 0.12'f32,
      a, b, -0.21, 0.055, Sandstone * 1.08'f32, bevel = 0.035)
  result.ring(2.18, 2.208, 0.013, Brass * 0.83'f32)
  result.ring(2.78, 2.815, 0.015, Brass)
  result.ring(0.77, 0.803, 0.014, Brass * 0.8'f32)
  for ray in 0 ..< 8:
    let
      angle = Tau * ray.float32 / 8
      direction = vec3(sin(angle), 0, cos(angle))
      across = vec3(cos(angle), 0, -sin(angle))
      reach = if ray mod 2 == 0: 1.55'f32 else: 0.94'f32
      center = vec3(0, 0.016, 0)
    result.triangle(center - across * 0.16'f32,
      center + direction * reach, center, Brass * 0.82'f32, Metal)
    result.triangle(center, center + direction * reach,
      center + across * 0.16'f32, Brass * 1.08'f32, Metal)
  result.centerCount = result.vertices.len

  for balcony in layout.balconies:
    var piece: CourtyardMesh
    # Five independently tessellated floor courses expand with the ring.
    # Staggered joints continue over the fascia below the playable surface.
    for course in 0 ..< 5:
      let
        r0 = inner + course.float32 * BalconyDepth / 5
        r1 = inner + (course + 1).float32 * BalconyDepth / 5 - 0.025'f32
      piece.arcCourse(rng, r0, r1, halfAngle, -0.20, 0.006,
        Sandstone, stagger = (course mod 2).float32 * 0.5'f32,
        bevel = 0.016)
    for row in 0 ..< 4:
      let
        bottom = -1.86'f32 + row.float32 * 0.43'f32
        top = bottom + 0.405'f32
        stepIn = if row == 0: 0.13'f32 else: 0.0'f32
        stagger = (row mod 2).float32 * 0.5'f32
      piece.arcCourse(rng, inner + stepIn, inner + 0.62'f32,
        halfAngle, bottom, top, Sandstone * 0.91'f32, stagger)
      piece.arcCourse(rng, outer - 0.64'f32, outer - stepIn,
        halfAngle, bottom, top, Sandstone * 0.86'f32, stagger)
      for side in [-1.0'f32, 1.0'f32]:
        for course in 0 ..< 6:
          let
            radial = inner + 0.55'f32 + course.float32 * 1.07'f32
            angle = side * (halfAngle - 0.025'f32)
            p = vec3(sin(angle) * radial, (bottom + top) * 0.5'f32,
              cos(angle) * radial)
          piece.addBlock(p, vec3(0.42, top - bottom, 1.04),
            Sandstone * rng.rand(0.8 .. 1.04).float32, -angle, bevel = 0.04)
    # Quiet brass front seam and proud edging frame the exposed island edge.
    for index in 0 ..< 30:
      let
        a = -halfAngle + 2 * halfAngle * index.float32 / 30
        b = -halfAngle + 2 * halfAngle * (index + 1).float32 / 30
      piece.arcSlab(inner + 0.16'f32, inner + 0.19'f32,
        a, b, 0.008, 0.014, Brass * 0.8'f32, bevel = 0.002, material = Metal)
    piece.arcCourse(rng, inner - 0.08'f32, inner + 0.16'f32,
      halfAngle, -0.22, 0.06, Sandstone * 1.06'f32, width = 1.4,
      bevel = 0.035)

    # A low rear parapet leaves heroes and the elevated hand visible from
    # every seat. Its cap is one more reusable course of curved masonry.
    for row in 0 .. 1:
      piece.arcCourse(rng, outer - 0.34'f32, outer + 0.01'f32,
        halfAngle, row.float32 * 0.27'f32,
        row.float32 * 0.27'f32 + 0.25'f32,
        Sandstone, stagger = (row mod 2).float32 * 0.5'f32)
    piece.arcCourse(rng, outer - 0.42'f32, outer + 0.10'f32,
      halfAngle, 0.52, 0.68, Sandstone * 1.06'f32,
      width = 1.4, bevel = 0.04)

    # The pile pads are part of the balcony; their top matches zone.y.
    for anchor in [balcony.deckZone, balcony.discardZone]:
      let p = vec3(anchor.x, 0.025, middle + anchor.z)
      piece.addBlock(p, vec3(1.99, 0.25, 2.57),
        Sandstone * 0.96'f32, bevel = 0.07)
      piece.addBlock(p + vec3(0, 0.125, 0), vec3(1.71, 0.01, 2.30),
        vec3(0.20, 0.215, 0.205), bevel = 0.02)
      for side in [-1.0'f32, 1.0'f32]:
        piece.addBlock(p + vec3(side * 0.90'f32, 0.130, 0),
          vec3(0.025, 0.01, 2.30), Brass, bevel = 0.003, material = Metal)

    # Small lantern towers mark each outside end, clear of all card zones.
    for side in [-1.0'f32, 1.0'f32]:
      let
        angle = side * layout.lampHalfAngle
        lamp = vec3(sin(angle) * layout.lampRadius, BalconyLampHeight,
          cos(angle) * layout.lampRadius)
      for row in 0 .. 1:
        piece.addBlock(vec3(lamp.x, 0.16'f32 + row.float32 * 0.32'f32, lamp.z),
          vec3(0.88, 0.30, 0.79),
          Sandstone * rng.rand(0.88 .. 1.06).float32, -angle)
      piece.lantern(lamp)
      # Ivy trails over the low railing and down the outer masonry face.
      for strand in 0 ..< 5:
        let
          ivyAngle = angle + (strand.float32 - 2) * 0.017'f32
          radial = outer + 0.10'f32 + rng.rand(0.0 .. 0.07).float32
        var vine: CourtyardMesh
        vine.ivy(rng, vec3(0, -1.3'f32 + rng.rand(-0.22 .. 0.18).float32,
          radial), rng.rand(1.40 .. 1.95).float32)
        piece.appendTurned(vine, -ivyAngle)
      # A few shoots crawl over the cap, so the same ivy remains visible
      # from the high overview instead of disappearing behind the fascia.
      var previous = vec3(0)
      for shoot in 0 .. 10:
        let
          t = shoot.float32 / 10
          vineAngle = clamp(angle + (t - 0.5'f32) * 1.45'f32 / outer,
            -halfAngle * 0.96'f32, halfAngle * 0.96'f32)
          radial = outer - 0.19'f32 + sin(t * 9) * 0.06'f32
          outward = vec3(sin(vineAngle), 0, cos(vineAngle))
          tangent = vec3(cos(vineAngle), 0, -sin(vineAngle))
          p = outward * radial + vec3(0, 0.71'f32 + sin(t * PI.float32) * 0.035'f32, 0)
        if shoot > 0:
          piece.beam(previous, p, 0.025, vec3(0.18, 0.16, 0.08), Leaf)
        previous = p
        for direction in [-1.0'f32, 1.0'f32]:
          let
            span = rng.rand(0.13 .. 0.23).float32
            leafCenter = p + outward * direction * span * 0.55'f32
            color = vec3(0.22, 0.255, 0.095) * rng.rand(0.85 .. 1.25).float32
          piece.leaf(leafCenter, outward * direction * span,
            tangent * span * 0.66'f32, color)
    # Hanging cloth is outside and below the floor, never across a play zone.
    for angle in [-halfAngle * 0.40'f32, halfAngle * 0.40'f32]:
      var cloth: CourtyardMesh
      cloth.banner(vec3(0, -0.24, outer + 0.13'f32))
      piece.appendTurned(cloth, -angle)
    # Inward-facing cloth reads clearly across the central gap. Its rail and
    # fabric are below the playing surface, leaving the front card row clear.
    var innerBanner: CourtyardMesh
    innerBanner.banner(vec3(0, -0.15, -inner + 0.17'f32))
    piece.appendTurned(innerBanner, PI.float32)
    result.appendTurned(piece, balcony.yaw)
  result.pavingCount = 0
  result.commonCount = result.vertices.len
  result.backdropCount = 0

proc buildMultiplayerCourtyardMesh*(playerCount: int): CourtyardMesh =
  buildMultiplayerCourtyardMesh(buildMultiplayerLayout(playerCount))

when not defined(headless):
  import std/os
  import opengl, pixie
  import paths

  type
    CourtyardMaterial* = object
      ## Live stone material controls (the tuning panel edits these).
      normalStrength*: float32  ## 0 leaves the flat geometric normals.
      lampIntensity*: float32   ## Brightness of the courtyard lanterns.
      slopeBroad*: float32      ## Weight of the fractured rock-face map.
      scaleBroad*: float32      ## World units one tile covers.

    CourtyardRenderer* = object
      material*: CourtyardMaterial
      program, vao, vbo: GLuint
      normalMap: GLuint
      skyProgram: GLuint
      skyViewLocation, skyEyeLocation, skyTimeLocation: GLint
      shadows: array[2, GLuint]
      lightMatrices: array[2, Mat4]
      commonCount, backdropCount, centerCount: int
      playerCount: int
      arenaRadius, balconyLampRadius, balconyLampHalfAngle: float32
      viewLocation, lightLocation, eyeLocation, timeLocation, sideLocation,
        shadowLocation, normalLocation,
        normalStrengthLocation, normalsOnlyLocation, normalViewLocation,
        slopeBroadLocation, scaleBroadLocation, lampLocation,
        playerCountLocation, arenaRadiusLocation, lampRadiusLocation,
        lampAngleLocation, stageYawLocation: GLint

  const
    ShadowSize = 2048
    VertexSource = staticRead("shaders/courtyard.vert")
    FragmentSource = staticRead("shaders/courtyard.frag")
    SkyVertexSource = staticRead("shaders/night-sky.vert")
    SkyFragmentSource = staticRead("shaders/night-sky.frag")
    ShaderHeader = when defined(emscripten):
      "#version 300 es\nprecision highp float;\nprecision highp int;\n"
    else: "#version 330 core\n"

  proc compile(kind: GLenum, source: string): GLuint =
    result = glCreateShader(kind)
    let sources = allocCStringArray([ShaderHeader & source])
    defer: deallocCStringArray(sources)
    glShaderSource(result, 1, sources, nil)
    glCompileShader(result)
    var ok: GLint
    glGetShaderiv(result, GL_COMPILE_STATUS, ok.addr)
    if ok == 0:
      var size: GLint
      glGetShaderiv(result, GL_INFO_LOG_LENGTH, size.addr)
      var log = newString(size)
      glGetShaderInfoLog(result, size, nil, log.cstring)
      raise newException(CatchableError, "Courtyard shader: " & log)

  proc program(vertex, fragment: string): GLuint =
    let v = compile(GL_VERTEX_SHADER, vertex)
    let f = compile(GL_FRAGMENT_SHADER, fragment)
    defer:
      glDeleteShader(v)
      glDeleteShader(f)
    result = glCreateProgram()
    glAttachShader(result, v)
    glAttachShader(result, f)
    glLinkProgram(result)
    var ok: GLint
    glGetProgramiv(result, GL_LINK_STATUS, ok.addr)
    if ok == 0:
      var size: GLint
      glGetProgramiv(result, GL_INFO_LOG_LENGTH, size.addr)
      var log = newString(size)
      glGetProgramInfoLog(result, size, nil, log.cstring)
      raise newException(CatchableError, "Courtyard shader link: " & log)

  proc matrix(location: GLint, value: Mat4) =
    var data = value
    glUniformMatrix4fv(location, 1, GL_FALSE, cast[ptr float32](data.addr))

  proc loadNormalTexture(path: string): GLuint =
    let image = readImage(path)
    glGenTextures(1, result.addr)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, result)
    # RGBA8, not SRGB: all normal channels are linear vector components.
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint,
      image.width.GLsizei, image.height.GLsizei, 0,
      GL_RGBA, GL_UNSIGNED_BYTE, image.data[0].addr)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT.GLint)
    glGenerateMipmap(GL_TEXTURE_2D)
    glBindTexture(GL_TEXTURE_2D, 0)

  proc defaultCourtyardMaterial*(): CourtyardMaterial =
    ## AWM_STONE_NORMALS=0 flattens the stone for comparison.
    CourtyardMaterial(
      normalStrength: if getEnv("AWM_STONE_NORMALS") == "0": 0 else: 0.7,
      lampIntensity: 4.5,
      slopeBroad: 1.25,
      scaleBroad: 6.0
    )

  proc initCourtyardRenderer*(playerCount = 2): CourtyardRenderer =
    var mesh: CourtyardMesh
    result.playerCount = playerCount
    if playerCount > 2:
      let layout = buildMultiplayerLayout(playerCount)
      mesh = buildMultiplayerCourtyardMesh(layout)
      result.arenaRadius = layout.outerRadius
      result.balconyLampRadius = layout.lampRadius
      result.balconyLampHalfAngle = layout.lampHalfAngle
    else:
      mesh = buildCourtyardMesh()
    result.commonCount = mesh.commonCount
    result.backdropCount = mesh.backdropCount
    result.centerCount = mesh.centerCount
    result.program = program(VertexSource, FragmentSource)
    let textureRoot = artworkRoot() / "battlefield/textures"
    result.normalMap = loadNormalTexture(textureRoot / "stone-slab-normal.png")
    result.material = defaultCourtyardMaterial()
    result.skyProgram = program(SkyVertexSource, SkyFragmentSource)
    result.skyViewLocation = glGetUniformLocation(result.skyProgram, "inverseViewProjection")
    result.skyEyeLocation = glGetUniformLocation(result.skyProgram, "cameraEye")
    result.skyTimeLocation = glGetUniformLocation(result.skyProgram, "time")
    glGenVertexArrays(1, result.vao.addr)
    glBindVertexArray(result.vao)
    glGenBuffers(1, result.vbo.addr)
    glBindBuffer(GL_ARRAY_BUFFER, result.vbo)
    var data = newSeqOfCap[float32](mesh.vertices.len * 12)
    for v in mesh.vertices:
      data.add [v.position.x, v.position.y, v.position.z,
        v.normal.x, v.normal.y, v.normal.z, v.color.x, v.color.y, v.color.z,
        v.material, v.uv.x, v.uv.y]
    glBufferData(GL_ARRAY_BUFFER, data.len * sizeof(float32), data[0].addr,
      GL_STATIC_DRAW)
    for attribute in [(0, 3, 0), (1, 3, 3), (2, 3, 6), (3, 1, 9), (4, 2, 10)]:
      glEnableVertexAttribArray(attribute[0].GLuint)
      glVertexAttribPointer(attribute[0].GLuint, attribute[1].GLint,
        cGL_FLOAT, GL_FALSE, (12 * sizeof(float32)).GLsizei,
        cast[pointer](attribute[2] * sizeof(float32)))
    for (name, destination) in [
        ("viewProjection", result.viewLocation.addr),
        ("lightMatrix", result.lightLocation.addr),
        ("cameraEye", result.eyeLocation.addr),
        ("time", result.timeLocation.addr),
        ("cameraSide", result.sideLocation.addr),
        ("shadowMap", result.shadowLocation.addr),
        ("stoneNormalMap", result.normalLocation.addr),
        ("normalStrength", result.normalStrengthLocation.addr),
        ("lampIntensity", result.lampLocation.addr),
        ("playerCount", result.playerCountLocation.addr),
        ("arenaRadius", result.arenaRadiusLocation.addr),
        ("balconyLampRadius", result.lampRadiusLocation.addr),
        ("balconyLampHalfAngle", result.lampAngleLocation.addr),
        ("slopeBroad", result.slopeBroadLocation.addr),
        ("scaleBroad", result.scaleBroadLocation.addr),
        ("normalsOnly", result.normalsOnlyLocation.addr),
        ("normalView", result.normalViewLocation.addr),
        ("stageYaw", result.stageYawLocation.addr)]:
      destination[] = glGetUniformLocation(result.program, name.cstring)

    # Bake the static sun shadows for both camera directions once. No scene
    # geometry is rebuilt or uploaded on a normal frame, including cloth.
    let depthProgram = program("""
layout(location=0) in vec3 position;
uniform mat4 lightMatrix;
void main() { gl_Position = lightMatrix * vec4(position, 1.0); }
""", """
void main() {}
""")
    let lightLocation = glGetUniformLocation(depthProgram, "lightMatrix")
    var viewport: array[4, GLint]
    var oldFramebuffer: GLint
    glGetIntegerv(GL_VIEWPORT, viewport[0].addr)
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, oldFramebuffer.addr)
    glEnable(GL_DEPTH_TEST)
    glDepthMask(GL_TRUE)
    glDisable(GL_BLEND)
    glDisable(GL_CULL_FACE)
    glUseProgram(depthProgram)
    glViewport(0, 0, ShadowSize, ShadowSize)
    for seat in 0 .. 1:
      let side = if seat == 0: 1.0'f32 else: -1.0'f32
      let light = normalize(vec3(-0.48'f32 * side, 0.85, 0.35'f32 * side))
      let
        extent = max(18.0'f32, result.arenaRadius + 3.0'f32)
        distance = if playerCount > 2: extent * 2 else: 35.0'f32
        farPlane = if playerCount > 2: max(70.0'f32, extent * 4) else: 70.0'f32
      result.lightMatrices[seat] = ortho(-extent, extent, -extent,
        extent, 1.0'f32, farPlane) *
        lookAt(light * distance, vec3(0), vec3(0, 1, 0))
      glGenTextures(1, result.shadows[seat].addr)
      glBindTexture(GL_TEXTURE_2D, result.shadows[seat])
      glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT24.GLint,
        ShadowSize, ShadowSize, 0, GL_DEPTH_COMPONENT, GL_UNSIGNED_INT, nil)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE,
        GL_COMPARE_REF_TO_TEXTURE.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_FUNC, GL_LEQUAL.GLint)
      var framebuffer: GLuint
      glGenFramebuffers(1, framebuffer.addr)
      glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
        GL_TEXTURE_2D, result.shadows[seat], 0)
      var targets = [GL_NONE]
      glDrawBuffers(1, cast[ptr GLenum](targets.addr))
      glReadBuffer(GL_NONE)
      if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
        raise newException(CatchableError, "Courtyard shadow framebuffer is incomplete")
      glClear(GL_DEPTH_BUFFER_BIT)
      matrix(lightLocation, result.lightMatrices[seat])
      glDrawArrays(GL_TRIANGLES, 0, result.commonCount.GLsizei)
      glDrawArrays(GL_TRIANGLES,
        (result.commonCount + seat * result.backdropCount).GLint,
        result.backdropCount.GLsizei)
      glDeleteFramebuffers(1, framebuffer.addr)
    glBindFramebuffer(GL_FRAMEBUFFER, oldFramebuffer.GLuint)
    glViewport(viewport[0], viewport[1], viewport[2], viewport[3])
    glBindTexture(GL_TEXTURE_2D, 0)
    glBindVertexArray(0)
    glDeleteProgram(depthProgram)

  proc drawSky*(renderer: CourtyardRenderer, viewProjection: Mat4,
      cameraEye: Vec3, time: float32) =
    # The sky never writes depth: SSAO sees the clear depth of 1.0, and all
    # opaque objects and VFX can occlude it without treating it as a wall.
    glEnable(GL_DEPTH_TEST)
    glDepthFunc(GL_LEQUAL)
    glDepthMask(GL_FALSE)
    glDisable(GL_STENCIL_TEST)
    glDisable(GL_BLEND)
    glDisable(GL_CULL_FACE)
    glUseProgram(renderer.skyProgram)
    matrix(renderer.skyViewLocation, viewProjection.inverse)
    glUniform3f(renderer.skyEyeLocation, cameraEye.x, cameraEye.y, cameraEye.z)
    glUniform1f(renderer.skyTimeLocation, time)
    glBindVertexArray(renderer.vao)
    glDrawArrays(GL_TRIANGLES, 0, 3)
    glBindVertexArray(0)
    glEnable(GL_DEPTH_TEST)
    glDepthMask(GL_TRUE)
    glDepthFunc(GL_LESS)

  proc draw*(renderer: CourtyardRenderer, viewProjection: Mat4,
      cameraEye: Vec3, time, cameraSide: float32,
      normalsOnly = false, normalView = mat4(), stageYaw = 0'f32) =
    ## stageYaw turns the multiplayer balconies (see stageRotation) while
    ## the center island stays put. Lighting and baked shadows live in the
    ## balconies' own frame, so their lamps and key light turn with them.
    let seat = if cameraSide > 0: 0 else: 1
    glEnable(GL_DEPTH_TEST)
    glDepthMask(if normalsOnly: GL_FALSE else: GL_TRUE)
    glDepthFunc(if normalsOnly: GL_EQUAL else: GL_LESS)
    glDisable(GL_BLEND)
    glDisable(GL_CULL_FACE)
    glUseProgram(renderer.program)
    matrix(renderer.viewLocation, viewProjection)
    matrix(renderer.lightLocation, renderer.lightMatrices[seat])
    glUniform3f(renderer.eyeLocation, cameraEye.x, cameraEye.y, cameraEye.z)
    glUniform1f(renderer.timeLocation, time)
    glUniform1f(renderer.sideLocation, cameraSide)
    glUniform1f(renderer.normalStrengthLocation,
      renderer.material.normalStrength)
    glUniform1f(renderer.lampLocation, renderer.material.lampIntensity)
    glUniform1i(renderer.playerCountLocation, renderer.playerCount.GLint)
    glUniform1f(renderer.arenaRadiusLocation, renderer.arenaRadius)
    glUniform1f(renderer.lampRadiusLocation, renderer.balconyLampRadius)
    glUniform1f(renderer.lampAngleLocation, renderer.balconyLampHalfAngle)
    glUniform1f(renderer.slopeBroadLocation, renderer.material.slopeBroad)
    glUniform1f(renderer.scaleBroadLocation, renderer.material.scaleBroad)
    glUniform1i(renderer.normalsOnlyLocation, if normalsOnly: 1 else: 0)
    matrix(renderer.normalViewLocation, normalView)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, renderer.shadows[seat])
    glUniform1i(renderer.shadowLocation, 0)
    glActiveTexture(GL_TEXTURE1)
    glBindTexture(GL_TEXTURE_2D, renderer.normalMap)
    glUniform1i(renderer.normalLocation, 1)
    glBindVertexArray(renderer.vao)
    # The center island, in the world frame: its lamp light comes from the
    # turned balconies.
    glUniform1f(renderer.stageYawLocation, stageYaw)
    glDrawArrays(GL_TRIANGLES, 0, renderer.centerCount.GLsizei)
    # Everything else, drawn through the stage turn in its own frame.
    let
      stage = stageRotation(stageYaw)
      stageEye = (stage.inverse * vec4(cameraEye.x, cameraEye.y,
        cameraEye.z, 1)).xyz
    matrix(renderer.viewLocation, viewProjection * stage)
    matrix(renderer.normalViewLocation, normalView * stage)
    glUniform3f(renderer.eyeLocation, stageEye.x, stageEye.y, stageEye.z)
    glUniform1f(renderer.stageYawLocation, 0)
    glDrawArrays(GL_TRIANGLES, renderer.centerCount.GLint,
      (renderer.commonCount - renderer.centerCount).GLsizei)
    glDrawArrays(GL_TRIANGLES,
      (renderer.commonCount + seat * renderer.backdropCount).GLint,
      renderer.backdropCount.GLsizei)
    glBindVertexArray(0)
    for unit in [GL_TEXTURE3, GL_TEXTURE2, GL_TEXTURE1, GL_TEXTURE0]:
      glActiveTexture(unit)
      glBindTexture(GL_TEXTURE_2D, 0)
    glDepthMask(GL_TRUE)
    glDepthFunc(GL_LESS)
