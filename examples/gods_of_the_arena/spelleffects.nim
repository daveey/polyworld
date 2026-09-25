## Spell telegraphs and projectiles drawn from replay-authoritative state.

import
  std/math,
  vmath,
  polyworld/[fxmeshes, pathing, quadterrain],
  content, sim

type
  SpellMesh = tuple[vertices: seq[float32], indices: seq[uint32]]
  AreaMesh = object
    heroId, started: int32
    ability: Ability
    position: WorldPoint
    direction: Heading
    mesh: SpellMesh
  SpellRenderer* = object
    renderer: FxRenderer
    areas: seq[AreaMesh]
    meshes: array[Ability, SpellMesh]
    glow: SpellMesh
    trail: SpellMesh
    fireball: SpellMesh

proc initSpellRenderer*(): SpellRenderer =
  ## Creates the shared spell mesh shader and reusable geometry buffer.
  result.renderer = initFxRenderer()

proc spellPoint(point: WorldPoint): Vec3 =
  ## Converts simulation positions only at the rendering boundary.
  vec3(point.x.float32, point.y.float32, point.z.float32) / WorldScale.float32

proc footprintSettings*(area: FxArea): FxSettings =
  ## Builds the exact ground outline used by authoritative area hit tests.
  result = defaultFxSettings()
  result.radius = area.radius.float32 / WorldScale.float32
  result.innerRadius = area.innerRadius.float32 / WorldScale.float32
  result.width = area.width.float32 / WorldScale.float32
  result.length = area.length.float32 / WorldScale.float32
  result.height = 0.03
  result.angleOffset = 90
  result.arcDegrees = area.angle.float32
  result.pivot = CenterPivot
  result.texture = SolidTexture
  result.blendMode = AlphaBlend
  result.gradientSource = RadialGradient
  case area.shape
  of CircleFootprint:
    result.shape = AoeCircleShape
    result.innerRadius = 0
  of RingFootprint:
    result.shape = AoeCircleShape
  of SectorFootprint:
    result.shape = AoeConeShape
  of LineFootprint, CrossFootprint:
    result.shape = AoeLineShape
  of CapsuleFootprint:
    result.shape = AoeCapsuleShape
    result.length = max(0.0001'f, result.length - result.width)
  result.expandStart = 1
  result.expandEnd = 1
  result.fadeIn = 0
  result.fadeOut = 0

proc mapHeight(position: Vec3): float32 =
  ## Keeps warnings on the terrain and above shallow water.
  result = surfaceHeightNear(position.x, position.z, position.y)
  result += groundOffset(position.x, position.z)
  let (x, z) = worldToTile(position.x, position.z)
  for layer in layers:
    if not layer.water:
      continue
    let
      tx = x - layer.originX
      tz = z - layer.originZ
    if tx < 0 or tx >= layer.width or tz < 0 or tz >= layer.depth:
      continue
    let tile = layer.tiles[tz * layer.width + tx]
    if tile.exists:
      for height in tile.tops.unpack:
        result = max(result, height)

proc areaMesh(
    settings: FxSettings,
    spell: SpellCast,
    model: Mat4,
    crossed: bool
): AreaMesh =
  ## Projects a fixed footprint onto its map surface once per cast.
  result.heroId = spell.heroId
  result.started = spell.started
  result.ability = spell.ability
  result.position = spell.position
  result.direction = spell.direction
  let flat = buildFxMesh(settings)
  for arm in 0 .. (if crossed: 1 else: 0):
    let
      matrix =
        if arm == 0:
          model
        else:
          model * translate(vec3(0, 0, settings.length / 2)) *
            rotateY(PI.float32 / 2) *
            translate(vec3(0, 0, -settings.length / 2))
      base = uint32(result.mesh.vertices.len div 12)
    for index in flat.indices:
      result.mesh.indices.add(base + index)
    for vertex in 0 ..< flat.vertices.len div 12:
      let offset = vertex * 12
      var point = matrix * vec3(
        flat.vertices[offset], flat.vertices[offset + 1],
        flat.vertices[offset + 2]
      )
      point.y = mapHeight(point) + 0.08
      for field in 0 ..< 12:
        result.mesh.vertices.add(
          if field < 3: point[field] else: flat.vertices[offset + field]
        )

proc spellColor(ability: Ability): Vec3 =
  ## Gives each spell family an elemental identity independent of its team.
  case ability
  of LionGuard, FirebrandSword, InfernoAegis, BlazingBlade,
      RageCrucible, MoltenFist, VolcanicEruption, MeteorStrike:
    vec3(1.0, 0.38, 0.06)
  of ManaCrystal, FrostLance, FrostSigil, IceSpear, BoneMarionette:
    vec3(0.20, 0.75, 1.0)
  of NatureTalisman, HealingBloom, KindredWisps, GolemSeed, VerdantArrow:
    vec3(0.30, 1.0, 0.48)
  of ShadowCloak, VoidBlade, ShadowComet, AetherSiphon, MothHex,
      DreadTotem, VoidPortal, BoundVoid, ArcaneMeteor:
    vec3(0.75, 0.25, 1.0)
  of SanguineChalice, AfterlightSickle, WitheringIdol, DarkEclipse:
    vec3(1.0, 0.18, 0.47)
  of StormEagle, GaleSlash, WingedBoot:
    vec3(0.40, 0.95, 1.0)
  else:
    vec3(1.0, 0.80, 0.30)

proc effectSettings(ability: Ability): FxSettings =
  ## Authors animated local geometry separately from the exact hit footprint.
  let spec = ability.abilitySpec
  result = defaultFxSettings()
  result.shape = spec.effect
  result.pivot = CenterPivot
  result.blendMode = AdditiveBlend
  result.texture = StreakTexture
  result.gradientSource = LifeGradient
  result.uvScale = vec2(2, 3)
  result.scroll = vec2(0.25, -1.6)
  result.noiseScale = 3
  result.dissolveEdge = 0.16
  result.dissolveOut = 0.35
  result.fadeOut = 0.25
  result.expandStart = 0.65
  result.expandEnd = 1.05
  result.expandPower = 0.6
  result.radius = max(0.4'f, spec.area.radius.float32 / WorldScale.float32 / 2)
  result.innerRadius = result.radius * 0.78
  result.height = 0.65
  result.thickness = 0.10
  result.radialSegments = 48
  result.widthSegments = 12
  result.arcDegrees = 360
  result.angleOffset = 90
  case spec.casting
  of SelfCast:
    result.shape = HelixShape
    result.radius = 0.4
    result.height = 0.8
    result.turns = 2
    result.pitch = 0.3
    result.spinSpeed = 1.8
  of MeleeCast:
    result.shape = ArcShape
    result.radius = spec.range.float32 / WorldScale.float32 / 2
    result.innerRadius = result.radius * 0.5
    result.arcDegrees = 110
    result.arcCrescent = 0.9
    result.sweepSource = SweepU
    result.sweepBand = 0.6
    result.sweepSoft = 0.12
  of ProjectileCast:
    result.shape = SphereShape
    result.radius = 0.13
    result.texture = CellTexture
    result.spinSpeed = 2.2
    result.pulseAmp = 0.08
    result.pulseSpeed = 10
    result.expandStart = 1
    result.expandEnd = 1
    result.dissolveOut = 0
    result.fadeOut = 0
    if ability in {DragonSight, VerdantArrow, FinalMeasure, SiegeScarab}:
      result.shape = BoxShape
      result.size = vec3(0.05, 0.05, 0.4)
      result.spinSpeed = 0
  of AreaCast:
    case result.shape
    of AoeLineShape, AoeConeShape, AoeCapsuleShape:
      result = spec.area.footprintSettings()
    of ArcShape:
      result.arcDegrees = spec.area.angle.float32
      result.arcCrescent = 1
      result.sweepSource = SweepU
      result.sweepBand = 0.65
      result.sweepSoft = 0.08
    of AoeCircleShape:
      result.shape = RingShape
      result.texture = NoiseTexture
      result.rippleAmp = 0.12
      result.rippleFreq = 8
      result.rippleSpeed = 2
    of DiscShape:
      result.innerRadius = 0
      result.spinSpeed = 2
      result.texture = CellTexture
    of SphereShape, HemisphereShape:
      result.texture = CellTexture
      result.innerRadius = 0
      result.waveAmp = 0.05
      result.waveFreq = 5
      result.waveSpeed = 3
    of CylinderShape:
      result.height = 1.5
      result.gradientSource = AxisGradient
    of HelixShape:
      result.turns = 3
      result.pitch = 0.3
      result.spinSpeed = 2
      result.texture = CellTexture
    of TorusShape:
      result.texture = CellTexture
      result.spinSpeed = 1.5
      result.pulseAmp = 0.06
      result.pulseSpeed = 8
    of BoxShape:
      result.size = vec3(
        spec.area.width.float32 / WorldScale.float32 / 2,
        0.55,
        spec.area.length.float32 / WorldScale.float32 / 2
      )
      result.texture = NoiseTexture
    else:
      discard

proc drawGlow(effects: var SpellRenderer, viewProjection, model: Mat4,
    color: Vec3, time, opacity: float32) =
  ## Adds a soft luminous core using the same simulation clock as the spell.
  var settings = defaultFxSettings()
  settings.shape = SphereShape
  settings.radius = 0.10
  settings.radialSegments = 12
  settings.heightSegments = 6
  settings.pivot = CenterPivot
  settings.texture = SoftTexture
  settings.blendMode = AdditiveBlend
  settings.startColor = vec4(mix(color, vec3(1), 0.2), opacity * 0.25)
  settings.endColor = vec4(color, 0.0)
  if effects.glow.vertices.len == 0:
    effects.glow = buildFxMesh(settings)
  effects.renderer.uploadFxMesh(effects.glow)
  effects.renderer.drawFxMesh(settings, viewProjection, model, time, 0.2)

proc matches(area: AreaMesh, spell: SpellCast): bool =
  ## Rejects stale geometry when a seek is followed by a different cast.
  area.heroId == spell.heroId and area.started == spell.started and
    area.ability == spell.ability and area.position == spell.position and
    area.direction == spell.direction

proc drawTowerShots(
    effects: var SpellRenderer,
    world: World,
    viewProjection: Mat4,
    alpha: float32,
    viewMode: int32
) =
  ## Draws homing fireballs and impacts directly from replay simulation state.
  var settings = defaultFxSettings()
  settings.shape = SphereShape
  settings.pivot = CenterPivot
  settings.radius = 0.22
  settings.radialSegments = 16
  settings.heightSegments = 8
  settings.texture = NoiseTexture
  settings.blendMode = AdditiveBlend
  settings.startColor = vec4(1.0, 0.85, 0.25, 1.0)
  settings.endColor = vec4(1.0, 0.16, 0.02, 0.6)
  settings.scroll = vec2(0.7, -1.8)
  settings.waveAmp = 0.04
  settings.waveFreq = 5
  settings.waveSpeed = 6
  if effects.fireball.vertices.len == 0:
    effects.fireball = buildFxMesh(settings)
  for shot in world.towerShots:
    if viewMode > 0 and shot.team != Team(viewMode - 1) and
      not world.visible(Team(viewMode - 1), shot.position):
        continue
    let
      age = (world.tick.float32 + alpha - shot.started.float32) /
        TickRate.float32
      impact = shot.impact > 0
      fade =
        if impact:
          clamp(1 - (world.tick.float32 + alpha - shot.impact.float32) /
            TowerImpactTicks.float32, 0, 1)
        else:
          1.0'f
      position =
        if impact:
          shot.position.spellPoint()
        else:
          mix(shot.previous.spellPoint(), shot.position.spellPoint(), alpha)
      size = if impact: 1 + (1 - fade) * 3 else: 1.0'f
      base = translate(position)
    settings.startColor.w = fade
    settings.endColor.w = fade * 0.6
    effects.renderer.uploadFxMesh(effects.fireball)
    effects.renderer.drawFxMesh(
      settings, viewProjection, base, age, 0.2, sizeScale = size
    )
    effects.drawGlow(viewProjection, base, vec3(1.0, 0.5, 0.04), age, fade)

proc drawSpells*(
    effects: var SpellRenderer,
    world: World,
    viewProjection: Mat4,
    alpha: float32,
    viewMode: int32
) =
  ## Layers map warnings, flowing textures, and impacts for every caster.
  let
    time = world.tick.float32 + alpha
    seconds = time / TickRate.float32
  effects.drawTowerShots(world, viewProjection, alpha, viewMode)
  var write = 0
  for area in effects.areas:
    for spell in world.casts:
      if area.matches(spell):
          effects.areas[write] = area
          inc write
          break
  effects.areas.setLen(write)
  for spell in world.casts:
    let
      ability = spell.ability
      spec = ability.abilitySpec
      caster = world.heroById(spell.heroId)
    if viewMode > 0 and caster.team != Team(viewMode - 1) and
      not world.visible(Team(viewMode - 1), spell.position):
        continue
    let
      pending = not spell.resolved
      age = max(0.0'f, time - spell.started.float32) / TickRate.float32
      progress = clamp((time - spell.started.float32) /
        max((spell.impact - spell.started).float32, 1), 0, 1)
      fade = clamp((spell.ends.float32 - time) / 12, 0, 1)
      life = if pending: progress else: 1 - fade
      color = ability.spellColor
      light = mix(color, vec3(1), 0.7)
      teamColor =
        if spec.kind != Strike: vec3(0.3, 1.0, 0.5)
        elif caster.team == RedTeam: vec3(1.0, 0.3, 0.12)
        else: vec3(0.2, 0.65, 1.0)
    var
      position = spell.position.spellPoint()
      angle = arctan2(spell.direction.x.float32, spell.direction.z.float32)
    case spec.casting
    of ProjectileCast:
      var target = position
      if spell.targetId != 0:
        let hero = world.heroById(spell.targetId)
        if hero.id != 0:
          target = hero.position.spellPoint()
        else:
          let footman = world.footmanById(spell.targetId)
          if footman.id != 0:
            target = footman.position.spellPoint()
      position = mix(spell.origin.spellPoint(), target, progress)
      position.y += 0.8
    of MeleeCast:
      position = spell.origin.spellPoint() + vec3(0, 0.65, 0)
      angle += life * 0.6 - 0.3
    else:
      position.y = mapHeight(position) + 0.10
    let base = translate(position) * rotateY(angle)
    if spec.casting == AreaCast:
      var
        ground = spec.area.footprintSettings()
        offset = vec3(0.0'f)
      if spec.area.shape == CapsuleFootprint:
        offset.z = ground.width / 2
      elif spec.area.shape == CrossFootprint:
        offset.z = -ground.length / 2
      var index = -1
      for i, area in effects.areas:
        if area.matches(spell):
            index = i
            break
      if index < 0:
        index = effects.areas.len
        effects.areas.add areaMesh(
          ground, spell, base * translate(offset),
          spec.area.shape == CrossFootprint
        )
      effects.renderer.uploadFxMesh(effects.areas[index].mesh)
      # The full footprint stays visible under the moving decorative layers.
      ground.startColor = vec4(teamColor,
        if pending: 0.12'f + progress * 0.10'f else: fade * 0.20'f)
      ground.endColor = ground.startColor
      effects.renderer.drawFxMesh(
        ground, viewProjection, mat4(), seconds, life, sizeScale = 1
      )
      ground.blendMode = AdditiveBlend
      ground.texture =
        case spec.area.shape
        of LineFootprint, CapsuleFootprint, SectorFootprint: StreakTexture
        of RingFootprint: CellTexture
        else: NoiseTexture
      ground.uvScale = vec2(3, 4)
      ground.scroll = vec2(0.12, -0.75)
      ground.startColor = vec4(color,
        if pending: 0.42'f + 0.12'f * sin(age * 5) else: fade * 0.9'f)
      ground.endColor = vec4(light, ground.startColor.w * 0.5)
      ground.edgeColor = vec4(light, 1)
      effects.renderer.drawFxMesh(
        ground, viewProjection, mat4(), seconds, life, sizeScale = 1
      )
      # A bright front crosses the texture without changing the hit geometry.
      ground.sweepSource =
        if spec.area.shape in {CircleFootprint, RingFootprint, SectorFootprint}:
          SweepRadial
        else:
          SweepV
      ground.sweepBand = 0.24
      ground.sweepSoft = 0.045
      ground.startColor = vec4(light, if pending: 0.7'f else: fade)
      ground.endColor = vec4(color, ground.startColor.w * 0.5)
      let sweep =
        if pending: (age * 0.9'f) - floor(age * 0.9'f)
        else: life
      effects.renderer.drawFxMesh(
        ground, viewProjection, mat4(), seconds, sweep, sizeScale = 1
      )
      # Floating sparks trace the area while it charges and lift on impact.
      for i in 0 ..< 4:
        let phase = i.float32 / 4
        var local: Vec3
        case spec.area.shape
        of LineFootprint, CapsuleFootprint, CrossFootprint:
          local = vec3(
            (if i mod 2 == 0: -0.35'f else: 0.35'f) * ground.width,
            0,
            (phase + age * 0.4'f - floor(phase + age * 0.4'f)) *
              spec.area.length.float32 / WorldScale.float32
          )
        of SectorFootprint:
          let theta = (phase - 0.375'f) * ground.arcDegrees * PI.float32 / 180
          local = vec3(sin(theta), 0, cos(theta)) * ground.radius * 0.85
        of CircleFootprint, RingFootprint:
          let theta = phase * PI.float32 * 2 + age
          local = vec3(cos(theta), 0, sin(theta)) * ground.radius * 0.85
        var mote = base * local
        mote.y = mapHeight(mote) + 0.25 +
          (if pending: 0.10'f * sin(age * 4 + phase * 6) else: life * 1.5'f)
        effects.drawGlow(viewProjection, translate(mote), color, seconds,
          if pending: 0.55'f else: fade * 0.8'f)
      if pending:
        continue
      if spec.effect in {AoeLineShape, AoeConeShape, AoeCapsuleShape}:
        continue
    var settings = ability.effectSettings()
    let strength =
      if spec.effect in {HelixShape, TorusShape}: 0.35'f
      elif spec.casting == AreaCast: 0.75'f
      else: 1.0'f
    settings.startColor = vec4(mix(color, vec3(1), 0.2),
      strength * (if pending: 0.95'f else: fade))
    settings.endColor = vec4(color,
      strength * (if pending: 0.65'f else: fade * 0.45'f))
    settings.edgeColor = vec4(light, 1)
    if effects.meshes[ability].vertices.len == 0:
      effects.meshes[ability] = buildFxMesh(settings)
    var model = base
    if spec.casting == SelfCast:
      model = base * translate(vec3(0, 0.8, 0))
    elif spec.casting == AreaCast and spec.effect == BoxShape:
      model = base * translate(vec3(0, 0.55,
        spec.area.length.float32 / WorldScale.float32 / 2))
    effects.renderer.uploadFxMesh(effects.meshes[ability])
    effects.renderer.drawFxMesh(settings, viewProjection, model, age, life)
    if spec.casting == ProjectileCast:
      if pending:
        # The wake follows the shot; it never changes projectile collision.
        var trail = defaultFxSettings()
        trail.shape = ConeShape
        trail.pivot = StartPivot
        trail.radius = 0.09
        trail.topRadius = 0
        trail.height = 0.7
        trail.texture = StreakTexture
        trail.uvScale = vec2(2, 2)
        trail.scroll = vec2(0, -3)
        trail.blendMode = AdditiveBlend
        trail.gradientSource = AxisGradient
        trail.startColor = vec4(color, 0.8)
        trail.endColor = vec4(color, 0)
        if effects.trail.vertices.len == 0:
          effects.trail = buildFxMesh(trail)
        effects.renderer.uploadFxMesh(effects.trail)
        effects.renderer.drawFxMesh(
          trail, viewProjection, base * rotateX(-PI.float32 / 2), age, 0.2
        )
      effects.drawGlow(viewProjection, base, color, seconds, fade)
    elif spec.casting == SelfCast:
      # Small orbiting motes make healing and restoration visibly different.
      for i in 0 ..< 4:
        let
          phase = i.float32 * PI.float32 / 2 + age * 3
          offset = vec3(cos(phase) * 0.7, 0.4 + life, sin(phase) * 0.7)
        effects.drawGlow(
          viewProjection,
          base * translate(offset),
          color, seconds, fade * 0.6
        )

proc closeSpellRenderer*(effects: var SpellRenderer) =
  ## Releases the spell mesh renderer alongside the other scene effects.
  effects.renderer.closeFxRenderer()
  effects.areas.setLen(0)
  effects.meshes = default(typeof(effects.meshes))
  effects.glow = default(SpellMesh)
  effects.trail = default(SpellMesh)
  effects.fireball = default(SpellMesh)
