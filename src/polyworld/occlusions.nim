import
  std/math,
  vmath

const OcclusionHeights* = [0'f, 1'f, 3'f, 7'f]

type
  OcclusionField* = object
    size*: int
    origin*, span*: Vec2
    heights*: seq[float32]

proc initOcclusionField*(size: int, origin, span: Vec2): OcclusionField =
  ## Creates a static height field for short-range ambient sky visibility.
  assert size > 0 and span.x > 0 and span.y > 0
  OcclusionField(size: size, origin: origin, span: span,
    heights: newSeq[float32](size * size))

proc addOccluder*(field: var OcclusionField, center, radius: Vec3) =
  ## Rasterizes an ellipsoid's upper surface into the static horizon field.
  assert radius.x > 0 and radius.y > 0 and radius.z > 0
  let
    low = (vec2(center.x - radius.x, center.z - radius.z) - field.origin) /
      field.span * field.size.float32
    high = (vec2(center.x + radius.x, center.z + radius.z) - field.origin) /
      field.span * field.size.float32
  for z in max(0, int(floor(low.y))) .. min(field.size - 1, int(ceil(high.y))):
    let firstX = max(0, int(floor(low.x)))
    let lastX = min(field.size - 1, int(ceil(high.x)))
    for x in firstX .. lastX:
      let
        point = field.origin + (vec2(x.float32, z.float32) + vec2(0.5)) /
          field.size.float32 * field.span
        dx = (point.x - center.x) / radius.x
        dz = (point.y - center.z) / radius.z
        inside = 1 - dx * dx - dz * dz
      if inside > 0:
        let index = z * field.size + x
        field.heights[index] = max(field.heights[index],
          center.y + sqrt(inside) * radius.y)

proc heightAt(field: OcclusionField, point: Vec2): float32 =
  ## Samples a horizon blocker, treating the area outside the field as open.
  let
    uv = (point - field.origin) / field.span * field.size.float32
    x = int(floor(uv.x))
    z = int(floor(uv.y))
  if x < 0 or z < 0 or x >= field.size or z >= field.size:
    return 0
  field.heights[z * field.size + x]

proc addOccluder*(field: var OcclusionField, triangle: array[3, Vec3]) =
  ## Rasterizes actual roof triangles so cut facades leave their gardens open.
  let
    first = vec2(triangle[0].x, triangle[0].z)
    second = vec2(triangle[1].x, triangle[1].z)
    third = vec2(triangle[2].x, triangle[2].z)
    divisor = (second.y - third.y) * (first.x - third.x) +
      (third.x - second.x) * (first.y - third.y)
    low = (min(first, min(second, third)) - field.origin) /
      field.span * field.size.float32
    high = (max(first, max(second, third)) - field.origin) /
      field.span * field.size.float32
  if abs(divisor) < 0.000001'f:
    return
  for z in max(0, int(floor(low.y))) .. min(field.size - 1, int(ceil(high.y))):
    let firstX = max(0, int(floor(low.x)))
    let lastX = min(field.size - 1, int(ceil(high.x)))
    for x in firstX .. lastX:
      let
        point = field.origin + (vec2(x.float32, z.float32) + vec2(0.5)) /
          field.size.float32 * field.span
        a = ((second.y - third.y) * (point.x - third.x) +
          (third.x - second.x) * (point.y - third.y)) / divisor
        b = ((third.y - first.y) * (point.x - third.x) +
          (first.x - third.x) * (point.y - third.y)) / divisor
        c = 1 - a - b
      if min(a, min(b, c)) >= 0:
        let index = z * field.size + x
        field.heights[index] = max(field.heights[index],
          a * triangle[0].y + b * triangle[1].y + c * triangle[2].y)

proc ambientVisibility*(field: OcclusionField, point: Vec3): float32 =
  ## Integrates eight local horizons over a cosine-weighted sky hemisphere.
  const
    Directions = [vec2(1, 0), vec2(0.7071, 0.7071), vec2(0, 1),
      vec2(-0.7071, 0.7071), vec2(-1, 0), vec2(-0.7071, -0.7071),
      vec2(0, -1), vec2(0.7071, -0.7071)]
    Distances = [0.30'f, 0.65'f, 1.25'f, 2.25'f, 3.5'f]
  var blocked = 0'f
  for direction in Directions:
    var horizon = 0'f
    for distance in Distances:
      let
        samplePoint = vec2(point.x, point.z) + direction * distance
        rise = max(0'f, field.heightAt(samplePoint) - point.y - 0.08'f)
        projected = rise * rise / (rise * rise + distance * distance)
        attenuation = 1 - smoothstep(1.0'f, 4.0'f, distance)
      horizon = max(horizon, projected * attenuation)
    blocked += horizon
  1 - blocked / Directions.len.float32

proc bakeOcclusion*(field: OcclusionField, strength = 0.48'f): seq[uint8] =
  ## Packs four receiver heights into a linearly filtered RGBA visibility map.
  assert strength >= 0 and strength <= 1
  result = newSeq[uint8](field.size * field.size * OcclusionHeights.len)
  for z in 0 ..< field.size:
    for x in 0 ..< field.size:
      let point = field.origin + (vec2(x.float32, z.float32) + vec2(0.5)) /
        field.size.float32 * field.span
      for channel, height in OcclusionHeights:
        let visibility = field.ambientVisibility(vec3(point.x, height, point.y))
        result[(z * field.size + x) * 4 + channel] =
          uint8(round((1 - strength + strength * visibility) * 255))
