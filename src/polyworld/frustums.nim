import
  gltf, vmath

proc emptyBounds*(): AABounds =
  ## Creates an empty box for accumulating geometry bounds.
  AABounds(min: vec3(float32.high), max: vec3(-float32.high))

proc extend*(bounds: var AABounds, point: Vec3) =
  ## Includes a point in an axis-aligned box.
  bounds.min = min(bounds.min, point)
  bounds.max = max(bounds.max, point)

proc extend*(bounds: var AABounds, other: AABounds) =
  ## Includes a nonempty box in another box.
  if other.min.x <= other.max.x:
    bounds.extend(other.min)
    bounds.extend(other.max)

proc corner(bounds: AABounds, index: int): Vec3 =
  ## Selects one of a box's eight corners.
  vec3(
    if (index and 1) == 0: bounds.min.x else: bounds.max.x,
    if (index and 2) == 0: bounds.min.y else: bounds.max.y,
    if (index and 4) == 0: bounds.min.z else: bounds.max.z
  )

proc transformed*(bounds: AABounds, transform: Mat4): AABounds =
  ## Conservatively bounds an affine transform of a nonempty box.
  result = emptyBounds()
  if bounds.min.x > bounds.max.x:
    return
  for i in 0 ..< 8:
    result.extend(transform * bounds.corner(i))

proc inFrustum*(bounds: AABounds, viewProjection: Mat4): bool =
  ## Rejects a box only when all corners lie outside one clip plane.
  if bounds.min.x > bounds.max.x:
    return false
  var outside = 63
  for i in 0 ..< 8:
    let point = viewProjection * vec4(bounds.corner(i), 1)
    var planes = 0
    if point.x < -point.w:
      planes = planes or 1
    if point.x > point.w:
      planes = planes or 2
    if point.y < -point.w:
      planes = planes or 4
    if point.y > point.w:
      planes = planes or 8
    if point.z < -point.w:
      planes = planes or 16
    if point.z > point.w:
      planes = planes or 32
    outside = outside and planes
    if outside == 0:
      return true
  false
