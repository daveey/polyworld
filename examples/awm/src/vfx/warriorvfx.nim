## Forged steel, oxblood leather and bronze: a compact heavy-metal battlefield
## vocabulary. Included by vfxrenderer so solid materials and fire share its
## world-space mesh while retaining their separate blend modes.

proc facing(center, eye: Vec3): tuple[right, up: Vec3] =
  ## Axes of a camera-facing plane at `center`.
  let
    forward = normalize(eye - center)
    right = normalize(cross(vec3(0, 1, 0), forward))
  (right, normalize(cross(forward, right)))

proc addWarriorPolygon(renderer: var VfxRenderer, origin, right, up: Vec3,
    points: openArray[Vec2], ink: Vec4) =
  ## Ear clipping preserves the notches of horns, bevels and broken steel.
  ## A repeated corner encodes a single triangle in the quad vertex stream.
  if points.len < 3 or ink.w <= 0.002'f32: return
  doAssert points.len <= 16
  proc turn(a, b, c: Vec2): float32 =
    (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
  var
    indices: array[16, int]
    area = 0.0'f32
    count = points.len
  for i in 0 ..< points.len:
    indices[i] = i
    let b = points[(i + 1) mod points.len]
    area += points[i].x * b.y - b.x * points[i].y
  let winding = if area < 0: -1.0'f32 else: 1.0'f32
  while count > 2:
    var found = false
    for i in 0 ..< count:
      let
        ai = indices[(i + count - 1) mod count]
        bi = indices[i]
        ci = indices[(i + 1) mod count]
        a = points[ai]
        b = points[bi]
        c = points[ci]
      if turn(a, b, c) * winding <= 0.000001'f32: continue
      var occupied = false
      for j in 0 ..< count:
        let index = indices[j]
        if index == ai or index == bi or index == ci: continue
        let p = points[index]
        if turn(a, b, p) * winding >= -0.000001'f32 and
            turn(b, c, p) * winding >= -0.000001'f32 and
            turn(c, a, p) * winding >= -0.000001'f32:
          occupied = true
          break
      if occupied: continue
      let
        pa = origin + right * a.x + up * a.y
        pb = origin + right * b.x + up * b.y
        pc = origin + right * c.x + up * c.y
      renderer.addMaterialQuad([pa, pb, pc, pc],
        [vec2(0, 0), vec2(0, 1), vec2(1, 1), vec2(1, 1)], ink, 0)
      for j in i ..< count - 1:
        indices[j] = indices[j + 1]
      dec count
      found = true
      break
    if not found: break # Degenerate, fully collinear remainder has no area.

proc addSwordHilt(renderer: var VfxRenderer, hilt, along, across: Vec3,
    alpha: float32) =
  let
    bronze = vec4(0.58, 0.31, 0.105, alpha)
    gold = vec4(0.96, 0.69, 0.29, alpha)
  # A leather-wrapped grip, bound in brass, and a heavy diamond pommel.
  renderer.addWarriorPolygon(hilt, across, along,
    [vec2(-0.073, -0.035), vec2(-0.063, -0.32),
      vec2(0.063, -0.32), vec2(0.073, -0.035)],
    vec4(0.18, 0.035, 0.028, alpha))
  for i in 0 ..< 5:
    let y = -0.085'f32 - i.float32 * 0.045'f32
    renderer.addWarriorPolygon(hilt, across, along,
      [vec2(-0.066, y), vec2(-0.066, y - 0.016'f32),
        vec2(0.066, y + 0.008'f32), vec2(0.066, y + 0.023'f32)], bronze)
  renderer.addWarriorPolygon(hilt, across, along,
    [vec2(0, -0.43), vec2(-0.112, -0.35), vec2(0, -0.28),
      vec2(0.112, -0.35)], bronze)
  renderer.addWarriorPolygon(hilt, across, along,
    [vec2(0, -0.414), vec2(-0.077, -0.35), vec2(0, -0.304)], gold)
  # Swept, horn-shaped quillons give the silhouette weight at board scale.
  renderer.addWarriorPolygon(hilt, across, along,
    [vec2(-0.34, -0.012), vec2(-0.30, -0.087),
      vec2(0.30, -0.087), vec2(0.34, -0.012),
      vec2(0.23, 0.052), vec2(-0.23, 0.052)], bronze)
  for sign in [-1.0'f32, 1.0'f32]:
    renderer.addWarriorPolygon(hilt, across * sign, along,
      [vec2(0.23, -0.045), vec2(0.37, -0.005),
        vec2(0.43, 0.17), vec2(0.305, 0.067)], bronze)
    renderer.addWarriorPolygon(hilt, across * sign, along,
      [vec2(0.26, 0.016), vec2(0.345, 0.028), vec2(0.43, 0.17),
        vec2(0.305, 0.067)], gold)
  renderer.addWarriorPolygon(hilt, across, along,
    [vec2(-0.265, 0.008), vec2(-0.245, 0.044),
      vec2(0.245, 0.044), vec2(0.265, 0.008)], gold)
  renderer.addWarriorPolygon(hilt, across, along,
    [vec2(0, -0.09), vec2(-0.085, -0.015), vec2(0, 0.075),
      vec2(0.085, -0.015)], vec4(0.40, 0.015, 0.025, alpha))

proc addSword(renderer: var VfxRenderer, hilt, direction, eye: Vec3,
    alpha: float32, size = 1.0'f32) =
  ## A broad, bevelled steel blade with a dark fuller and etched red runes.
  let normal = cross(direction, eye - hilt)
  if alpha <= 0.002'f32 or length(normal) < 0.00001'f32: return
  let
    along = normalize(direction) * size
    across = normalize(normal) * size
  renderer.addWarriorPolygon(hilt, across, along,
    [vec2(-0.158, 0.045), vec2(-0.135, 1.07), vec2(0, 1.39),
      vec2(0.135, 1.07), vec2(0.158, 0.045)],
    vec4(0.115, 0.15, 0.18, alpha))
  renderer.addWarriorPolygon(hilt, across, along,
    [vec2(-0.139, 0.06), vec2(-0.117, 1.05), vec2(0, 1.37),
      vec2(0, 0.065)], vec4(0.81, 0.84, 0.84, alpha))
  renderer.addWarriorPolygon(hilt, across, along,
    [vec2(0, 0.065), vec2(0, 1.37), vec2(0.117, 1.05),
      vec2(0.139, 0.06)], vec4(0.36, 0.43, 0.47, alpha))
  renderer.addWarriorPolygon(hilt, across, along,
    [vec2(-0.139, 0.06), vec2(-0.117, 1.05), vec2(0, 1.37),
      vec2(-0.083, 1.026), vec2(-0.105, 0.06)],
    vec4(0.98, 0.965, 0.85, alpha))
  renderer.addWarriorPolygon(hilt, across, along,
    [vec2(0.105, 0.06), vec2(0.083, 1.026), vec2(0, 1.37),
      vec2(0.117, 1.05), vec2(0.139, 0.06)],
    vec4(0.64, 0.71, 0.73, alpha))
  renderer.addWarriorPolygon(hilt, across, along,
    [vec2(-0.021, 0.14), vec2(-0.016, 1.035), vec2(0, 1.14),
      vec2(0.016, 1.035), vec2(0.021, 0.14)],
    vec4(0.11, 0.15, 0.17, alpha))
  for i in 0 ..< 4:
    let y = 0.29'f32 + i.float32 * 0.16'f32
    renderer.addWarriorPolygon(hilt, across, along,
      [vec2(0, y + 0.055'f32), vec2(-0.021, y),
        vec2(0, y - 0.035'f32), vec2(0.021, y)],
      vec4(0.74, 0.055, 0.025, alpha))
  renderer.addSwordHilt(hilt, along, across, alpha)

proc addWarriorImpact(renderer: var VfxRenderer, center, eye: Vec3,
    age: float32, seed: int, force = 1.0'f32) =
  ## Molten, ballistic metal chips: white-hot at contact, copper as they cool.
  if age < 0: return
  renderer.addBillboard(center, 1.1'f32 * force, eye,
    vec4(0.8, 0.045, 0.018, exp(-age * 12) * 0.75'f32), 4)
  renderer.addBillboard(center, 0.55'f32 * force, eye,
    vec4(1.0, 0.80, 0.43, exp(-age * 24) * 1.7'f32), 4)
  for i in 0 ..< 45:
    let
      elapsed = age - particleNoise(i, 120, seed) * 0.035'f32
      lifetime = 0.24'f32 + particleNoise(i, 121, seed) * 0.42'f32
    if elapsed < 0 or elapsed >= lifetime: continue
    let
      angle = particleNoise(i, 122, seed) * 2 * PI.float32
      speed = (1.2'f32 + particleNoise(i, 123, seed) * 3.6'f32) * force
      velocity = normalize(vec3(cos(angle),
        particleNoise(i, 124, seed) * 1.8'f32 + 0.12'f32, sin(angle))) * speed
      tailAge = max(0.0'f32, elapsed - 0.018'f32 -
        particleNoise(i, 125, seed) * 0.028'f32)
      head = center + velocity * elapsed - vec3(0, 4.6'f32 * elapsed * elapsed, 0)
      tail = center + velocity * tailAge - vec3(0, 4.6'f32 * tailAge * tailAge, 0)
      fade = clamp((lifetime - elapsed) / 0.18'f32, 0.0'f32, 1.0'f32)
      heat = exp(-elapsed * 5)
      ink = mix(vec3(0.95, 0.09, 0.012), vec3(1.0, 0.83, 0.39), heat)
    renderer.addGlowLine(tail, head, eye,
      0.008'f32 + particleNoise(i, 126, seed) * 0.013'f32,
      vec4(ink, fade))

proc addBladeArc(renderer: var VfxRenderer, pivot, right, up, eye: Vec3,
    startAngle, endAngle, radius, alpha: float32) =
  ## A tapered crimson slash follows the actual blade-tip sweep.
  if alpha <= 0.002'f32 or abs(endAngle - startAngle) < 0.001'f32: return
  for i in 0 ..< 14:
    let
      t0 = i.float32 / 14
      t1 = (i + 1).float32 / 14
      a = mix(startAngle, endAngle, t0)
      b = mix(startAngle, endAngle, t1)
      radialA = right * sin(a) + up * cos(a)
      radialB = right * sin(b) + up * cos(b)
      width = 0.025'f32 + t1 * 0.105'f32
    renderer.addQuad([pivot + radialA * (radius - width),
      pivot + radialB * (radius - width),
      pivot + radialB * (radius + width),
      pivot + radialA * (radius + width)],
      [vec2(0, -1), vec2(1, -1), vec2(1, 1), vec2(0, 1)],
      vec4(0.95, 0.035, 0.025, alpha * t1 * 0.55'f32), 1)
    renderer.addLine(pivot + radialA * radius, pivot + radialB * radius,
      eye, 0.015, vec4(1.0, 0.49, 0.21, alpha * t1 * 0.7'f32))

proc addSwordsIntoTheWind(renderer: var VfxRenderer, effect: ActiveVfx,
    eye: Vec3) =
  ## Three raised broadswords form a battle salute, with torn crimson gusts.
  let
    age = effect.elapsed
    axes = facing(effect.position, eye)
    fade = clamp((effect.duration - age) / 0.38'f32, 0.0'f32, 1.0'f32)
  renderer.addBillboard(effect.position + vec3(0, 0.3, 0), 1.25, eye,
    vec4(0.82, 0.10, 0.018, exp(-age * 5) * 0.7'f32), 4)
  # The rear blades rise first; the central hero blade overlaps their hilts.
  for i in [0, 2, 1]:
    let
      localAge = age - (if i == 1: 0.15'f32 else: 0.03'f32)
      rally = clamp(localAge / 0.38'f32, 0.0'f32, 1.0'f32)
      ease = 1 - pow(1 - rally, 3.0'f32)
      side = (i - 1).float32
      angle = side * (0.49'f32 + (1 - ease) * 0.3'f32)
      blade = axes.up * cos(angle) + axes.right * sin(angle)
      lift = ease * 0.38'f32 + max(0.0'f32, localAge - 0.72'f32) * 0.5'f32
      hilt = effect.position + axes.right * (side * 0.42'f32) +
        vec3(0, 0.22'f32 + lift, 0) - axes.up * ((1 - ease) * 0.3'f32)
      size = if i == 1: 1.0'f32 else: 0.83'f32
    if localAge < 0: continue
    renderer.addSword(hilt, blade, eye,
      min(1.0'f32, localAge / 0.09'f32) * fade, size)
    renderer.addBillboard(hilt + blade * (1.35'f32 * size), 0.16, eye,
      vec4(1.0, 0.8, 0.4, exp(-pow((localAge - 0.38'f32) / 0.11'f32, 2.0'f32))), 4)
  # Dense, tapering red streamers stay close to the buffed fighter.
  for i in 0 ..< 5:
    let
      localAge = age - i.float32 * 0.075'f32
      t = localAge / 0.93'f32
    if t <= 0 or t >= 1: continue
    let alpha = sin(t * PI.float32) * fade * 0.42'f32
    var previous: Vec3
    for step in 0 .. 16:
      let
        k = step.float32 / 16
        angle = i.float32 * 1.25'f32 + t * 5 + k * 1.7'f32
        radius = (0.9'f32 - t * 0.15'f32) * (1 - k * 0.12'f32)
        point = effect.position +
          vec3(cos(angle) * radius, 0.2'f32 + t * 1.1'f32 + k * 0.5'f32,
            sin(angle) * radius)
      if step > 0:
        renderer.addLine(previous, point, eye, 0.012'f32 + k * 0.035'f32,
          vec4(0.9, 0.055, 0.018, alpha * k))
      previous = point
  renderer.addWarriorImpact(effect.position + vec3(0, 0.2, 0), eye,
    age - 0.21'f32, effect.seed, 0.5)

proc addShield(renderer: var VfxRenderer, center, eye: Vec3, size: float32,
    ink: Vec4) =
  ## Mighty Shields retains its compact blue ward treatment.
  let
    axes = facing(center, eye)
    outline = [vec2(-0.85, 0.75), vec2(0, 1), vec2(0.85, 0.75),
      vec2(0.8, -0.15), vec2(0, -1), vec2(-0.8, -0.15)]
  proc at(point: Vec2): Vec3 =
    center + axes.right * (point.x * size) + axes.up * (point.y * size)
  for i in 0 ..< outline.len:
    renderer.addGlowLine(at(outline[i]), at(outline[(i + 1) mod outline.len]),
      eye, 0.03'f32 * size, ink)
  renderer.addBillboard(center + axes.up * (0.1'f32 * size), 0.2'f32 * size,
    eye, vec4(ink.xyz, ink.w * 0.9'f32), 4)

proc addMightyShields(renderer: var VfxRenderer, effect: ActiveVfx,
    eye: Vec3) =
  let
    age = effect.elapsed
    t = age / effect.duration
    settle = min(1.0'f32, age / 0.35'f32)
    ease = 1 - (1 - settle) * (1 - settle)
    fade = clamp((1 - t) / 0.35'f32, 0.0'f32, 1.0'f32)
    center = effect.position + vec3(0, 0.9'f32 - 0.45'f32 * ease, 0)
    flare = exp(-max(0.0'f32, age - 0.35'f32) * 7) * settle
  renderer.addShield(center, eye, 0.3'f32 + 0.12'f32 * ease,
    vec4(0.45, 0.75, 1.0, fade))
  renderer.addBillboard(center, 0.8, eye, vec4(0.3, 0.6, 1.0, flare * 0.7'f32), 4)
  let ringAge = age - 0.3'f32
  if ringAge > 0:
    let
      radius = 0.6'f32 + ringAge * 2.2'f32
      alpha = clamp(1 - ringAge / 0.6'f32, 0.0'f32, 1.0'f32) * 0.8'f32
    for i in 0 ..< 48:
      let
        a = i.float32 * 2 * PI.float32 / 48
        b = (i + 1).float32 * 2 * PI.float32 / 48
      renderer.addGlowLine(
        effect.position + vec3(cos(a), 0, sin(a)) * radius,
        effect.position + vec3(cos(b), 0, sin(b)) * radius,
        eye, 0.02, vec4(0.4, 0.7, 1.0, alpha))

proc addWarShield(renderer: var VfxRenderer, center, eye: Vec3,
    size, alpha: float32) =
  let
    axes = facing(center, eye)
    right = axes.right * size
    up = axes.up * size
    outline = [vec2(-0.83, 0.7), vec2(0, 1), vec2(0.83, 0.7),
      vec2(0.69, -0.33), vec2(0, -1), vec2(-0.69, -0.33)]
  renderer.addWarriorPolygon(center, right, up, outline,
    vec4(0.085, 0.08, 0.075, alpha))
  renderer.addWarriorPolygon(center, right * 0.94'f32, up * 0.94'f32,
    outline, vec4(0.69, 0.44, 0.19, alpha))
  renderer.addWarriorPolygon(center, right * 0.84'f32, up * 0.84'f32,
    outline, vec4(0.26, 0.028, 0.028, alpha))
  renderer.addWarriorPolygon(center, right, up,
    [vec2(-0.68, 0.56), vec2(0, 0.81), vec2(0, -0.81),
      vec2(-0.57, -0.27)], vec4(0.43, 0.054, 0.036, alpha))
  # Embossed horned-helmet heraldry: bone steel on oxblood enamel.
  for sign in [-1.0'f32, 1.0'f32]:
    renderer.addWarriorPolygon(center, right * sign, up,
      [vec2(0.16, 0.13), vec2(0.36, 0.28), vec2(0.50, 0.59),
        vec2(0.37, 0.38), vec2(0.18, 0.33)],
      vec4(0.82, 0.78, 0.60, alpha))
  renderer.addWarriorPolygon(center, right, up,
    [vec2(-0.24, 0.21), vec2(-0.17, 0.39), vec2(0, 0.5),
      vec2(0.17, 0.39), vec2(0.24, 0.21), vec2(0.19, -0.19),
      vec2(0, -0.4), vec2(-0.19, -0.19)],
    vec4(0.70, 0.69, 0.61, alpha))
  renderer.addWarriorPolygon(center, right, up,
    [vec2(0, 0.47), vec2(-0.17, 0.34), vec2(-0.19, -0.16),
      vec2(0, -0.35)], vec4(0.91, 0.86, 0.68, alpha))
  for sign in [-1.0'f32, 1.0'f32]:
    renderer.addWarriorPolygon(center, right * sign, up,
      [vec2(0.025, 0.115), vec2(0.19, 0.19), vec2(0.16, -0.015),
        vec2(0.045, -0.02)], vec4(0.055, 0.045, 0.038, alpha))
  renderer.addWarriorPolygon(center, right, up,
    [vec2(-0.024, 0.3), vec2(-0.024, -0.25), vec2(0, -0.35),
      vec2(0.024, -0.25), vec2(0.024, 0.3)],
    vec4(0.97, 0.84, 0.55, alpha))
  for i in 0 ..< outline.len:
    let p = outline[i] * 0.89'f32
    renderer.addWarriorPolygon(center + right * p.x + up * p.y, right, up,
      [vec2(-0.037, 0), vec2(0, 0.045), vec2(0.037, 0), vec2(0, -0.045)],
      vec4(0.97, 0.76, 0.39, alpha))

proc addSwordAndShield(renderer: var VfxRenderer, effect: ActiveVfx,
    eye: Vec3) =
  ## A broadsword locks behind a riveted war shield, then holds its crest.
  let
    age = effect.elapsed
    enter = clamp(age / 0.28'f32, 0.0'f32, 1.0'f32)
    ease = 1 - pow(1 - enter, 3.0'f32)
    alpha = min(1.0'f32, age / 0.07'f32) *
      clamp((effect.duration - age) / 0.35'f32, 0.0'f32, 1.0'f32)
    center = effect.position + vec3(0, 0.53'f32 + ease * 0.17'f32, 0)
    axes = facing(center, eye)
    angle = 0.60'f32 + (1 - ease) * 0.62'f32
    blade = axes.up * cos(angle) + axes.right * sin(angle)
    hilt = center - blade * 0.49'f32 + axes.right * ((1 - ease) * 0.4'f32)
    shieldCenter = center - axes.right * ((1 - ease) * 0.6'f32) - axes.up * 0.1'f32
  renderer.addSword(hilt, blade, eye, alpha, 1.12)
  renderer.addWarShield(shieldCenter, eye,
    0.57'f32 + sin(enter * PI.float32) * 0.04'f32, alpha)
  renderer.addWarriorImpact(center, eye, age - 0.26'f32, effect.seed, 0.6)

proc addBrokenArrow(renderer: var VfxRenderer, center, eye: Vec3,
    age, alpha: float32) =
  let axes = facing(center, eye)
  for sign in [-1.0'f32, 1.0'f32]:
    let
      angle = age * (2.2'f32 + sign * 0.4'f32)
      along = axes.right * (sign * cos(angle)) - axes.up * sin(angle)
      across = axes.up * cos(angle) + axes.right * (sign * sin(angle))
      pivot = center + axes.right * (sign * age * 1.3'f32) -
        axes.up * (2.7'f32 * age * age)
    renderer.addWarriorPolygon(pivot, across, along,
      [vec2(-0.026, 0), vec2(-0.026, 0.8), vec2(0.026, 0.8), vec2(0.026, 0)],
      vec4(0.40, 0.22, 0.09, alpha))
    renderer.addWarriorPolygon(pivot, across, along,
      [vec2(-0.026, 0), vec2(-0.026, 0.8), vec2(-0.005, 0.8), vec2(-0.005, 0)],
      vec4(0.82, 0.59, 0.28, alpha))
    if sign > 0:
      renderer.addWarriorPolygon(pivot, across, along,
        [vec2(-0.105, 0.64), vec2(0, 0.98), vec2(0.105, 0.64)],
        vec4(0.64, 0.67, 0.64, alpha))
    else:
      for feather in [-1.0'f32, 1.0'f32]:
        renderer.addWarriorPolygon(pivot, across * feather, along,
          [vec2(0.018, 0.58), vec2(0.13, 0.73),
            vec2(0.13, 0.9), vec2(0.018, 0.79)],
          vec4(0.58, 0.052, 0.028, alpha))

proc addMelee(renderer: var VfxRenderer, effect: ActiveVfx, eye: Vec3) =
  ## A heavy slash breaks a ranged arrow; the sword remains as the new crest.
  const strike = 0.34'f32
  let
    age = effect.elapsed
    center = effect.position + vec3(0, 0.62, 0)
    axes = facing(center, eye)
    swing = clamp(age / strike, 0.0'f32, 1.0'f32)
    ease = swing * swing * swing
    impact = max(0.0'f32, age - strike)
    recoil = sin(impact * 22) * exp(-impact * 10) * 0.055'f32
    angle = mix(1.28'f32, -0.72'f32, ease) + recoil
    pivot = center + axes.right * 0.43'f32 - axes.up * 0.48'f32
    blade = axes.up * cos(angle) + axes.right * sin(angle)
    fade = clamp((effect.duration - age) / 0.3'f32, 0.0'f32, 1.0'f32)
    appear = min(1.0'f32, age / 0.07'f32)
  renderer.addBrokenArrow(center, eye, impact,
    appear * fade * clamp(1 - impact / 0.55'f32, 0.0'f32, 1.0'f32))
  renderer.addSword(pivot, blade, eye, fade * appear, 1.1)
  let
    trailSwing = clamp((age - 0.105'f32) / strike, 0.0'f32, 1.0'f32)
    trailAngle = mix(1.28'f32, -0.72'f32, trailSwing * trailSwing * trailSwing)
  renderer.addBladeArc(pivot, axes.right, axes.up, eye,
    trailAngle, angle, 1.44, appear * exp(-impact * 14))
  renderer.addWarriorImpact(center, eye, age - strike, effect.seed, 0.8)

proc addSwordClash(renderer: var VfxRenderer, effect: ActiveVfx, eye: Vec3) =
  ## Opposing blades accelerate into a real crossing, recoil, then hold.
  const strike = 0.29'f32
  let
    age = effect.elapsed
    center = effect.position + vec3(0, 0.77, 0)
    axes = facing(center, eye)
    swing = clamp(age / strike, 0.0'f32, 1.0'f32)
    ease = swing * swing * swing
    impact = max(0.0'f32, age - strike)
    recoil = sin(impact * 26) * exp(-impact * 8) * 0.11'f32
    fade = min(1.0'f32, age / 0.06'f32) *
      clamp((effect.duration - age) / 0.30'f32, 0.0'f32, 1.0'f32)
  for sign in [-1.0'f32, 1.0'f32]:
    let
      angle = sign * mix(-0.44'f32, 0.70'f32, ease) - sign * recoil
      pivot = center - axes.right * (sign * 0.52'f32) - axes.up * 0.57'f32
      direction = axes.up * cos(angle) + axes.right * sin(angle)
      trailSwing = clamp((age - 0.09'f32) / strike, 0.0'f32, 1.0'f32)
      trailAngle = sign * mix(-0.44'f32, 0.70'f32,
        trailSwing * trailSwing * trailSwing)
    renderer.addSword(pivot, direction, eye, fade, 1.04)
    renderer.addBladeArc(pivot, axes.right, axes.up, eye,
      trailAngle, angle, 1.42, fade * exp(-impact * 12))
  renderer.addWarriorImpact(center + axes.up * 0.045'f32,
    eye, age - strike, effect.seed, 1.0)

proc addSwordBreak(renderer: var VfxRenderer, effect: ActiveVfx, eye: Vec3) =
  ## A glowing fracture tears forged steel into jagged, tumbling pieces.
  const snapAt = 0.43'f32
  let
    age = effect.elapsed
    center = effect.position + vec3(0, 0.72, 0)
    axes = facing(center, eye)
    alpha = min(1.0'f32, age / 0.10'f32) *
      clamp((effect.duration - age) / 0.32'f32, 0.0'f32, 1.0'f32)
    fall = max(0.0'f32, age - snapAt)
    strain = clamp(age / snapAt, 0.0'f32, 1.0'f32)
    tremble = if age < snapAt: sin(age * 83) * 0.028'f32 * strain * strain
      else: 0.0'f32
  if age < snapAt:
    renderer.addSword(center + axes.up * 0.56'f32 + axes.right * tremble,
      -axes.up, eye, alpha, 1.0)
  else:
    # Separate fracture faces keep the broken ends visibly jagged.
    for sign in [-1.0'f32, 1.0'f32]:
      let
        tilt = fall * sign * 2.6'f32
        along = axes.up * cos(tilt) + axes.right * sin(tilt)
        across = axes.right * cos(tilt) - axes.up * sin(tilt)
        pivot = center + axes.right * (sign * fall * 0.95'f32) +
          axes.up * (fall * 0.35'f32 - 2.9'f32 * fall * fall)
      if sign > 0:
        renderer.addWarriorPolygon(pivot, across, along,
          [vec2(-0.14, 0.04), vec2(-0.08, -0.025), vec2(0, 0.06),
            vec2(0.07, -0.035), vec2(0.14, 0.01),
            vec2(0.157, 0.53), vec2(-0.157, 0.53)],
          vec4(0.45, 0.53, 0.56, alpha))
        renderer.addWarriorPolygon(pivot, across, along,
          [vec2(-0.14, 0.04), vec2(-0.08, -0.025), vec2(0, 0.06),
            vec2(0, 0.53), vec2(-0.157, 0.53)],
          vec4(0.9, 0.88, 0.76, alpha))
        renderer.addSwordHilt(pivot + along * 0.56'f32, -along, across, alpha)
      else:
        renderer.addWarriorPolygon(pivot, across, along,
          [vec2(-0.14, 0.04), vec2(-0.08, -0.025), vec2(0, 0.06),
            vec2(0.07, -0.035), vec2(0.14, 0.01),
            vec2(0.115, -0.53), vec2(0, -0.83), vec2(-0.115, -0.53)],
          vec4(0.39, 0.46, 0.50, alpha))
        renderer.addWarriorPolygon(pivot, across, along,
          [vec2(-0.14, 0.04), vec2(-0.08, -0.025), vec2(0, 0.06),
            vec2(0, -0.83), vec2(-0.115, -0.53)],
          vec4(0.88, 0.88, 0.81, alpha))
  if age > 0.12'f32 and age < snapAt:
    let
      glow = pow(strain, 3.0'f32)
      crackCenter = center + axes.right * tremble
      cracks = [vec2(-0.15, 0.04), vec2(-0.08, -0.025), vec2(0, 0.06),
        vec2(0.07, -0.035), vec2(0.15, 0.01)]
    for i in 0 ..< cracks.high:
      renderer.addGlowLine(crackCenter + axes.right * cracks[i].x + axes.up * cracks[i].y,
        crackCenter + axes.right * cracks[i + 1].x + axes.up * cracks[i + 1].y,
        eye, 0.01, vec4(1.0, 0.13, 0.025, glow))
  renderer.addWarriorImpact(center, eye, age - snapAt, effect.seed, 0.75)
  if age >= snapAt:
    for i in 0 ..< 9:
      let
        localAge = age - snapAt
        angle = particleNoise(i, 140, effect.seed) * 2 * PI.float32
        velocity = axes.right * (cos(angle) * 1.9'f32) +
          axes.up * (sin(angle) * 1.7'f32 + 0.4'f32)
        position = center + velocity * localAge -
          vec3(0, 4.1'f32 * localAge * localAge, 0)
        spin = angle + localAge * 8
        right = (axes.right * cos(spin) + axes.up * sin(spin)) *
          (0.045'f32 + particleNoise(i, 141, effect.seed) * 0.035'f32)
        up = (axes.up * cos(spin) - axes.right * sin(spin)) * 0.12'f32
      renderer.addWarriorPolygon(position, right, up,
        [vec2(-1, 0.4), vec2(0.25, 1), vec2(1, -0.5), vec2(-0.1, -1)],
        vec4(0.69, 0.73, 0.69, alpha *
          clamp(1 - localAge / 0.60'f32, 0.0'f32, 1.0'f32)))
