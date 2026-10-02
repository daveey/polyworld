## Included by vfxrenderer: authored, alpha-blended jelly with ballistic drops.

proc addOozeSprite(renderer: var VfxRenderer, center, right, up: Vec3,
    width, height, phase, wobble, alpha: float32, droplet = false) =
  if alpha <= 0.003'f32: return
  let
    x = right * width
    y = up * height
  renderer.addMaterialQuad([center - x + y, center - x - y,
    center + x - y, center + x + y],
    [vec2(0, 0), vec2(0, 1), vec2(1, 1), vec2(1, 0)],
    vec4(1, 1, 1, alpha), if droplet: 7 else: 6, vec2(phase, wobble))

proc addOozeSplat(renderer: var VfxRenderer, effect: ActiveVfx, eye: Vec3) =
  ## A weighty falling glob compresses, rebounds, and settles into a wet pool.
  ## Every small glob follows p = origin + velocity*t - gravity*t*t; at
  ## its exact landing time it flattens into a little splat and fades.
  const impact = 0.32'f32
  let
    age = effect.elapsed
    seed = effect.seed
    floor = effect.position + vec3(0, 0.045, 0)
    axes = facing(floor, eye)
    forward = normalize(eye - floor)
    castPhase = particleNoise(0, 110, seed) * 2 * PI.float32
  if age < impact:
    let
      t = age / impact
      stretch = 1 + 0.45'f32 * t * t
      center = floor + vec3(0, 2.6'f32 * (1 - t * t) + 0.38'f32, 0)
    renderer.addOozeSprite(center, axes.right, axes.up,
      0.54'f32 / sqrt(stretch), 0.54'f32 * stretch, age * 18 + castPhase,
      0.018, min(1.0'f32, age / 0.07'f32), droplet = true)
    return
  let
    splat = age - impact
    fadeT = clamp((effect.duration - age) / 0.42'f32, 0.0'f32, 1.0'f32)
    fade = fadeT * fadeT * (3 - 2 * fadeT)
    spread = 1 - exp(-splat * 12)
    wobble = sin(splat * 23) * exp(-splat * 3.8'f32)
    width = 0.63'f32 + spread * 0.32'f32 + wobble * 0.15'f32
    height = 0.39'f32 + exp(-splat * 4) * 0.14'f32 - wobble * 0.10'f32
    groundRight = vec3(cos(castPhase), 0, sin(castPhase))
    groundUp = vec3(-sin(castPhase), 0, cos(castPhase))
  renderer.addOozeSprite(floor, groundRight, groundUp,
    0.67'f32 + spread * 0.52'f32, 0.67'f32 + spread * 0.45'f32,
    splat * 12 + castPhase, 0.018'f32 * exp(-splat * 2), fade * 0.87'f32)

  # The two groups keep distant droplets behind the central body, and nearby
  # droplets in front, without changing the layering of forged weapon faces.
  for front in [false, true]:
    if front:
      renderer.addOozeSprite(floor + axes.up * (height * 0.65'f32),
        axes.right, axes.up, width, height, splat * 16 + castPhase,
        0.028'f32 * exp(-splat * 2.2'f32), fade)
    for i in 0 ..< 26:
      let
        delay = particleNoise(i, 100, seed) * 0.075'f32
        t = splat - delay
        angle = particleNoise(i, 101, seed) * 2 * PI.float32
        speed = 0.85'f32 + particleNoise(i, 102, seed) * 1.75'f32
        vertical = 1.8'f32 + particleNoise(i, 103, seed) * 2.0'f32
        velocity = vec3(cos(angle) * speed, vertical, sin(angle) * speed)
        flight = vertical / 4.8'f32
        size = 0.10'f32 + particleNoise(i, 104, seed) * 0.13'f32
        phase = particleNoise(i, 105, seed) * 2 * PI.float32
        inFront = dot(vec3(velocity.x, 0, velocity.z), forward) >= 0
      if t < 0 or front != inFront: continue
      if t >= flight:
        let
          landed = t - flight
          alpha = clamp(1 - landed / 0.48'f32, 0.0'f32, 1.0'f32) * fade
          center = floor + vec3(velocity.x, 0.003'f32, velocity.z) * flight
          squash = 1 + 0.6'f32 * (1 - exp(-landed * 25))
        renderer.addOozeSprite(center, groundRight, groundUp,
          size * squash, size * squash, phase + landed * 20,
          0.025'f32 * exp(-landed * 7), alpha * 0.86'f32)
      else:
        let
          center = floor + velocity * t + vec3(0, -4.8'f32 * t * t, 0)
          spin = phase + t * (particleNoise(i, 106, seed) - 0.5'f32) * 5
          right = axes.right * cos(spin) + axes.up * sin(spin)
          up = axes.up * cos(spin) - axes.right * sin(spin)
          stretch = 1 + abs(vertical - 9.6'f32 * t) * 0.10'f32
        renderer.addOozeSprite(center, right, up, size / sqrt(stretch),
          size * stretch, phase + t * 18, 0.014, fade, droplet = true)
