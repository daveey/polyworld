## Watching an expedition. The camera follows the party down, and the world
## is drawn as a cutaway: the uppermost selected hero's floor, plus everything
## below it, so you can see the levels they have yet to reach through the
## shafts while the ceilings above them are simply not drawn.
##
## Nothing in this file is authoritative. It reads the simulation and turns
## body poses into smooth float positions; no value computed here is ever
## written back.

import
  std/[math, tables, times],
  chroma, fixxy, opengl, pixie, silky, vmath, windy,
  polyworld/[actioncam, assets, characters, chargen, clickmarks, common, inputs,
    particles, particleshaders, chrome, pathing, player, profiles,
    quadterrain, rtscameras, selectionoutlines, shadows, shapes, tapes,
    terrainsurfaces, viewers, visions, worldbars, worldtexts],
  assets, content, maps, sim, game, replays, ui, controls

when defined(takeScreenshot):
  import std/[os, strutils]

const
  DefaultCameraDistance = 13.0'f
  AtlasPath = TmpRoot & "/cta.atlas.png"
  SimulationStep = 1.0'f32 / TickRate.float32
  SeekCheckpointTicks = TickRate * 10
  PathLift = 0.2'f32
  PathHalfWidth = 0.12'f32
  FacingHeight = 0.85'f32
  FacingOffset = 0.4'f32
  FacingLength = 0.45'f32
  FacingHalfWidth = 0.18'f32

type
  HeroVisual = object
    ## Holds client-only animation smoothing for one actor slot.
    angle: float32
    animTime: float32
    clip: int

  SeekCheckpoint = object
    ## Captures all authoritative state needed for an exact replay seek.
    tick: int32
    world: World
    log: seq[string]
    actionIndex: int
    hashCheck: ReplayHashCheck

var sk: Silky

proc registerTileColors() =
  ## Maps every dungeon kind to the generated texture array after loading.
  setTileMaterial(
    int(GrassTile), GrassSurface.float32, DirtSurface.float32,
    vec3(1), vec3(0.85'f), 1
  )
  setTileMaterial(
    int(RoadTile), DirtSurface.float32, DirtSurface.float32,
    vec3(1), vec3(0.85'f), 5
  )
  setTileMaterial(
    int(RockTile), CryptRockSurface, CryptRockSurface,
    vec3(1), vec3(0.8'f), 4
  )
  setTileMaterial(
    int(MarshTile), MarshSurface.float32, DirtSurface.float32,
    vec3(1), vec3(0.8'f), 2
  )
  setTileMaterial(
    int(StoneTile), CryptStoneSurface, CryptStoneSurface,
    vec3(1), vec3(0.85'f), 6
  )
  setTileMaterial(
    int(TreeTile), ForestSurface.float32, DirtSurface.float32,
    vec3(1), vec3(0.85'f), 0
  )
  setTileMaterial(
    int(FloorTile), CryptFloorSurface, CryptStoneSurface,
    vec3(1), vec3(0.8'f), 10
  )
  setTileMaterial(
    int(RubbleTile), CryptRubbleSurface, CryptRockSurface,
    vec3(1), vec3(0.8'f), 11
  )
  setTileMaterial(
    int(LavaTile), CryptLavaSurface, CryptLavaSurface,
    vec3(1), vec3(0.85'f), 16
  )
  setTileMaterial(
    int(ObsidianTile), CryptCrustSurface, CryptRockSurface,
    vec3(0.72'f), vec3(0.65'f), 15
  )
  setTileMaterial(
    int(GoldTile), VaultSurface, CryptStoneSurface,
    vec3(1, 0.9'f, 0.65'f), vec3(0.8'f), 17
  )
  setTileMaterial(
    int(MossTile), MarshSurface.float32, CryptRockSurface,
    vec3(1), vec3(0.8'f), 12
  )
  setTileMaterial(
    int(RampTile), CryptFloorSurface, CryptRockSurface,
    vec3(1.1'f), vec3(0.8'f), 13
  )

proc renderPosition(actor: Actor): Vec3 =
  ## Converts a tile-space body into a render position on the actor's floor.
  let
    base = tileCenter(
      int(actor.home.level), int(actor.home.x), int(actor.home.z))
    x = toFloat32(actor.body.pos.x) - HalfGrid
    z = toFloat32(actor.body.pos.y) - HalfGrid
  vec3(x, base.y, z)

proc actorYaw(actor: Actor): float32 =
  ## Renderer yaw from body facing: `arctan2(dx, dz)`. East is +pi/2,
  ## south is 0, west is -pi/2, north is pi.
  let dir = direction(actor.body.facing)
  arctan2(toFloat32(dir.x), toFloat32(dir.y))

proc travelYaw(fromPos, toPos: Vec3, fallback: float32): float32 =
  ## Renderer yaw of a world-space step, or fallback when the step is tiny.
  let
    dx = toPos.x - fromPos.x
    dz = toPos.z - fromPos.z
  if dx * dx + dz * dz < 1e-8'f32:
    fallback
  else:
    arctan2(dx, dz)

proc actorPathColor(actor: Actor): ColorRGBX =
  ## Returns a stable debug color for one actor's followed path.
  if actor.kind == HeroActor:
    case actor.heroClass
    of FighterClass: rgbx(194, 125, 62, 255)
    of WizardClass: rgbx(126, 89, 210, 255)
    of RogueClass: rgbx(57, 153, 181, 255)
    of ClericClass: rgbx(213, 177, 73, 255)
  else:
    rgbx(235, 72, 56, 255)

proc liftedPathPoint(position: Vec3): Vec3 =
  ## Raises a path point so the line sits above the floor.
  vec3(position.x, position.y + PathLift, position.z)

proc addFacingTriangle(
    renderer: var ShapeRenderer,
    actor: Actor,
    color: ColorRGBX
) =
  ## Draws the heading the simulation currently stores on this body.
  let
    dir = direction(actor.body.facing)
    fx = toFloat32(dir.x)
    fz = toFloat32(dir.y)
  if fx * fx + fz * fz < 1e-8'f32:
    return
  let
    forward = normalize(vec3(fx, 0, fz))
    right = vec3(-forward.z, 0, forward.x)
    origin =
      renderPosition(actor) +
      forward * FacingOffset +
      vec3(0, FacingHeight, 0)
    tip = origin + forward * FacingLength
    left = origin + right * FacingHalfWidth
    rightPt = origin - right * FacingHalfWidth
  renderer.addTriangle(tip, left, rightPt, color)

proc addActorPaths(
    renderer: var ShapeRenderer,
    world: World,
    visibleFrom: int
) =
  ## Adds remaining path ribbons and a facing triangle for each living actor.
  for actor in world.actors:
    if actor.id == 0 or not actor.alive:
      continue
    if int(actor.home.level) < visibleFrom:
      continue
    if actor.kind == MonsterActor and not selectedVisible(actor.home):
      continue
    let color = actorPathColor(actor)
    renderer.addFacingTriangle(actor, color)
    if actor.path.len == 0 or actor.pathIndex >= int32(actor.path.len):
      continue
    var points: seq[Vec3]
    points.add liftedPathPoint(renderPosition(actor))
    for i in int(actor.pathIndex) ..< actor.path.len:
      let tile = actor.path[i].tile
      if int(tile.level) < visibleFrom:
        if points.len >= 2:
          renderer.addPolyline(points, color, PathHalfWidth)
        points.setLen(0)
        continue
      points.add liftedPathPoint(
        tileCenter(int(tile.level), int(tile.x), int(tile.z))
      )
    if points.len >= 2:
      renderer.addPolyline(points, color, PathHalfWidth)

proc makeCircleIcon(size: int, fill: ColorRGBA): Image =
  ## Builds a filled circle sprite for compact HUD chrome.
  result = newImage(size, size)
  let ctx = newContext(result)
  ctx.fillStyle = fill
  ctx.fillCircle(
    circle(vec2(size.float32 * 0.5'f32), size.float32 * 0.46'f32)
  )

proc addHudIcons(builder: AtlasBuilder) =
  ## Packs the theme logo and compact HUD glyphs.
  builder.addThemeLogo(LogoPath)
  if not builder.addImage(
      "cta_badge",
      makeCircleIcon(22, rgba(18, 20, 28, 255))
    ):
    raise newException(
      ValueError,
      "the UI atlas is too small for HUD glyphs"
    )

proc addAbilityIcons(builder: AtlasBuilder) =
  ## Packs every ability art file used by the action bar.
  const AbilityDir = DataRoot & "/abilities/"
  for _, name in AbilityIconFiles:
    if name.len == 0:
      continue
    let icon = readImage(AbilityDir & name & ".png").resize(128, 128)
    if not builder.addImage("ability_" & name, icon):
      raise newException(
        ValueError,
        "the UI atlas is too small for ability icons"
      )

proc runGraphics*() =
  ## Runs the native or Emscripten graphical expedition viewer.
  startGameProfile()
  profileBlock "atlas":
    let builder = newHudAtlas(4096)
    for class in HeroClass:
      let portrait = readImage(HeroPortraitPaths[class])
      if not builder.addImage(HeroPortraitKeys[class], portrait):
        raise newException(
          ValueError,
          "Failed to allocate hero portrait: " & HeroPortraitPaths[class]
        )
    addHudIcons(builder)
    addAbilityIcons(builder)
    builder.addDefaultFonts()
    builder.addFont(DefaultFontPath, "WorldName", 32.0)
    builder.write(AtlasPath)
  var window: Window
  profileBlock "window":
    (window, sk) = initGameWindow(
      "Call to Adventure",
      AtlasPath,
      gameWindowSize(options.windowWidth, options.windowHeight),
      options.vsync,
      msaa = msaa4x
    )
  let splash = startSplash(sk, window)
  # The stack spans about 45 tiles top to bottom; the shading uses amplitude
  # as its height scale, so a value near the whole span keeps every level
  # readable instead of clipping the deep ones to black.
  profileBlock "terrain":
    amplitude = 48.0
    seed = run.world.setup.seed.int
    initTerrain(
      NoTrees, GeneratedTerrain, NoRocks, CtaTerrainTiles,
      settings = CtaTerrainAssets
    )
    registerTileColors()
    bakeTerrain(rebuildWalkability = false)

  let scene = newCharacterScene(window)
  scene.useToonShading()
  var
    particles = initParticleSystem()
    clickMarks = initClickMarks()
    worldBarRenderer = initWorldBarRenderer()
    playerLabels = layoutNames(
      sk.atlas.fonts["WorldName"],
      sk.atlas.size,
      run.config.players
    )
    worldShapes = initShapeRenderer()
    damageTrails: DamageTrailTracker
    selectionOutline = initSelectionOutline()
  var heroModels: array[HeroClass, CharacterModel]
  var monsterModels: array[Species, CharacterModel]
  profileBlock "models":
    let
      library = readManifest(ChargenLibrary)
      roster = readCharacterRoster()

    proc loadPresetModel(preset: Preset, height: float32): CharacterModel =
      ## Assembles existing equipment and preserves the authored face colors.
      result = loadCharacterModel(
        readPresetCharacter(ChargenLibrary, library, preset, CharacterClips),
        height
      )
      result.fitCharacterHeight(height, result.clipIndex("Idle_Loop"))
      for category in library.presetManifest(preset).categories:
        if category.key in ["Eyes", "Mouth", "Brow"]:
          for item in category.items:
            result.unlitParts.add item.nodes

    for class in HeroClass:
      heroModels[class] = loadPresetModel(
        library.namedPreset(HeroPresets[class]), HeroTargetHeight
      )
    for species in Species:
      let
        entry = roster.mobs[species.ord]
        model = loadPresetModel(
          entry.preset, HeroTargetHeight * RankScales[species.monsterRank]
        )
        rgb = entry.skinRgb
      partNodes(model.file.root).applySkin(
        library.presetManifest(entry.preset), color(rgb[0], rgb[1], rgb[2], 1)
      )
      monsterModels[species] = model
  drawSplash(sk, window, splash.name)

  var
    heroIdle, heroRun, heroAttack: array[HeroClass, int]
    monsterIdle, monsterRun, monsterAttack: array[Species, int]
  for class in HeroClass:
    let
      model = heroModels[class]
      clips = class.heroClips()
    heroIdle[class] = model.clipIndex(clips[0])
    heroRun[class] = model.clipIndex(clips[1])
    heroAttack[class] = model.clipIndex(clips[2])
  for species in Species:
    let
      model = monsterModels[species]
      clips = speciesClips(species)
    monsterIdle[species] = model.clipIndex(clips[0])
    monsterRun[species] = model.clipIndex(clips[1])
    monsterAttack[species] = model.clipIndex(clips[2])

  var
    visuals: seq[HeroVisual]
    previousActorPositions: Table[int32, Vec3]
    previousActorFacings: Table[int32, float32]
    renderAlpha = 1.0'f32

  proc captureActorPositions() =
    ## Remembers the visual pose before one authoritative tick.
    var
      nextPositions: Table[int32, Vec3]
      nextFacings: Table[int32, float32]
    for actor in run.world.actors:
      if actor.id == 0:
        continue
      let pos = renderPosition(actor)
      nextPositions[actor.id] = pos
      nextFacings[actor.id] = travelYaw(
        previousActorPositions.getOrDefault(actor.id, pos),
        pos,
        actorYaw(actor)
      )
    previousActorPositions = nextPositions
    previousActorFacings = nextFacings

  proc actorRenderPosition(actor: Actor): Vec3 =
    ## Interpolates one actor between the two latest simulation snapshots.
    let current = renderPosition(actor)
    if not interpolateVisuals:
      return current
    mix(
      previousActorPositions.getOrDefault(actor.id, current),
      current,
      renderAlpha
    )

  proc actorRenderFacing(actor: Actor): float32 =
    ## Interpolates the last walked heading the short way. Travel yaw is
    ## taken from the tick's displacement so a ±pi wrap in body facing
    ## cannot spin the model.
    if not interpolateVisuals:
      return actorYaw(actor)
    let
      currentPos = renderPosition(actor)
      current = travelYaw(
        previousActorPositions.getOrDefault(actor.id, currentPos),
        currentPos,
        actorYaw(actor)
      )
      previous = previousActorFacings.getOrDefault(actor.id, current)
    previous + shortestTurn(previous, current) * renderAlpha

  type
    ActorParticleState = object
      id: int32
      kind: ActorKind
      class: uint8
      hp: int16
      action: Ability
      actionTicks: int16
      origin: Vec3
      targetFound: bool
      targetPosition: Vec3
  proc captureParticleActors(): seq[ActorParticleState] =
    ## Captures flat pre-tick combat data without retaining simulation refs.
    for actor in run.world.actors:
      if not actor.alive:
        continue
      var state = ActorParticleState(
        id: actor.id,
        kind: actor.kind,
        class: actor.class,
        hp: actor.hp,
        action: actor.action,
        actionTicks: actor.actionTicks,
        origin: renderPosition(actor) + vec3(0, 0.82'f32, 0)
      )
      let targetSlot = run.world.actorSlot(actor.target)
      if targetSlot >= 0 and run.world.actors[targetSlot].alive:
        state.targetFound = true
        state.targetPosition = renderPosition(
          run.world.actors[targetSlot]
        ) + vec3(0, 0.72'f32, 0)
      result.add state

  proc emitActorAttack(state: ActorParticleState) =
    ## Converts one CTA ability impact into its matching game effect.
    if not state.targetFound:
      return
    let travel = clamp(
      (state.targetPosition - state.origin).length / 13.0'f32,
      0.1'f32,
      0.5'f32
    )
    if state.kind == MonsterActor:
      if Species(state.class).monsterRank == CasterRank:
        particles.emitParticleProjectile(
          MagicBolt,
          MagicBurst,
          state.origin,
          state.targetPosition,
          travel
        )
      else:
        particles.emitParticleBurst(
          CombatSparks,
          state.targetPosition
        )
      return
    case state.action
    of MeteorStrike:
      particles.emitParticleProjectile(
        Fireball,
        FireBurst,
        state.origin,
        state.targetPosition,
        travel
      )
    of FrostLance, SunOrb:
      particles.emitParticleProjectile(
        MagicBolt,
        MagicBurst,
        state.origin,
        state.targetPosition,
        travel
      )
    of VerdantArrow:
      particles.emitParticleProjectile(
        ArrowWake,
        CombatSparks,
        state.origin,
        state.targetPosition,
        travel
      )
    of FirebrandSword, MoltenFist, VenomDagger, SolarHammer,
        IronFlail, BlazingBlade, VoidBlade, GaleSlash:
      particles.emitParticleBurst(
        CombatSparks,
        state.targetPosition
      )
    of LightningStorm, ArcaneMeteor, ShadowComet, CosmicFlare:
      particles.emitParticleProjectile(
        MagicBolt,
        MagicBurst,
        state.origin,
        state.targetPosition,
        travel
      )
    of FirePhoenix:
      particles.emitParticleProjectile(
        Fireball,
        FireBurst,
        state.origin,
        state.targetPosition,
        travel
      )
    else:
      discard

  proc emitTickParticles(oldActors: seq[ActorParticleState]) =
    ## Emits action impacts and all actual hit-point restoration once.
    for old in oldActors:
      let slot = run.world.actorSlot(old.id)
      if slot >= 0 and
          run.world.actors[slot].hp > old.hp:
        particles.emitParticleBurst(
          HealingAura,
          renderPosition(run.world.actors[slot])
        )
      if old.action == NoAbility:
        continue
      let spec = Abilities[old.action]
      if old.actionTicks + 1 != spec.windupTicks or
          spec.damage <= 0:
        continue
      emitActorAttack(old)

  var
    cameraDistance = DefaultCameraDistance
    cameraTarget = vec3(0, 0, 0)
    panning = false
    minimapPanning = false
    lastMouse = ivec2(0, 0)
    lastFrameTime = epochTime()
    followSelection = false
    cameraEase: CameraEase
    focusPlayerHero = false
    viewingDt = 0.0'f
    viewingSeeking = false
    actionCam = initActionCam(
      subjectMode = true,
      defaultDistance = DefaultCameraDistance,
      minDistance = 12,
      maxDistance = 36,
      tight = 0.35,
      followRate = 3.5,
      zoomRate = 2.5,
      holdSeconds = 0.7,
      mapSpan = 28
    )
    primaryId = 0
    selectedIds: array[PartySize, bool]
    playerSlot = options.playerSlot - 1
    attackTargetId = 0'i32
    selectionPressPosition = vec2(0)
    rightPressPosition = vec2(0)
    selectionStarted = false
    selectionAdditive = false
    groupCameraScale = 1.0'f32
    terrainVisionTick = int32.low
    terrainVisionLevel = int32.low
    replayCheckpoints: seq[SeekCheckpoint]
    transport = initPlayer(
      live = not run.replayMode,
      durationTicks = options.maximumTicks,
      playing = not options.pauseOnStart,
      speed = options.speed,
      repeating = true
    )

  proc copyLog(): seq[string] =
    ## Copies the presentation log into an independent checkpoint value.
    for line in run.log:
      result.add line

  proc captureCheckpoint(): SeekCheckpoint =
    ## Captures the exact simulation and replay cursor at the current tick.
    SeekCheckpoint(
      tick: run.world.tick,
      world: run.world.clone(),
      log: copyLog(),
      actionIndex: run.replayPlayer.actionIndex,
      hashCheck: run.hashCheck
    )

  proc restoreCheckpoint(checkpoint: SeekCheckpoint) =
    ## Restores one simulation checkpoint without rebinding the game object.
    run.world.restore(checkpoint.world)
    run.log = checkpoint.log
    if run.recorder != nil:
      run.replayPlayer.data = run.recorder.data
    run.replayPlayer.syncCursor(uint32(run.world.tick))
    run.hashCheck = checkpoint.hashCheck

  proc cacheSeekCheckpoint() =
    ## Extends the seek cache as playback reaches new territory.
    let finalTick = transport.timelineEnd
    if run.world.tick mod SeekCheckpointTicks != 0 and
        run.world.tick != finalTick:
      return
    if replayCheckpoints.len == 0 or
        replayCheckpoints[^1].tick < run.world.tick:
      replayCheckpoints.add captureCheckpoint()

  proc restoreTo(target: int32) =
    ## Reloads the last checkpoint at or before a tick, then resimulates.
    var checkpointIndex = 0
    for i, checkpoint in replayCheckpoints:
      if checkpoint.tick > target:
        break
      checkpointIndex = i
    restoreCheckpoint(replayCheckpoints[checkpointIndex])
    run.historyPlayback = true
    transport.accumulator = 0
    previousActorPositions.clear()
    previousActorFacings.clear()
    particles.clearParticles()
    renderAlpha = 1
    while run.world.tick < target:
      advanceGame()
      cacheSeekCheckpoint()

  replayCheckpoints = @[captureCheckpoint()]

  proc playerMode(): bool =
    ## Returns whether this client issues orders for one party hero.
    options.playerSlot > 0 and not run.replayMode

  proc partyCenter(): Vec3 =
    ## Returns the average interpolated position of the living party.
    var
      total = vec3(0, 0, 0)
      count = 0
    for slot in 0 ..< PartySize:
      if run.world.actors[slot].alive:
        total = total + actorRenderPosition(run.world.actors[slot])
        inc count
    if count == 0: cameraTarget else: total / count.float32

  cameraTarget = partyCenter()

  proc selectedAlive(): bool =
    ## Returns whether the selected party slot contains a living hero.
    primaryId >= 0 and
      primaryId < min(PartySize, run.world.actors.len) and
      run.world.actors[primaryId].alive

  proc selectedCount(): int =
    ## Returns the number of selected party slots.
    for selected in selectedIds:
      if selected:
        inc result

  proc selectedLivingCount(): int =
    ## Returns the number of selected heroes currently alive.
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      if selectedIds[slot] and run.world.actors[slot].alive:
        inc result

  proc selectedLivingHero(): int =
    ## Returns the first selected living hero slot, or minus one.
    result = -1
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      if selectedIds[slot] and run.world.actors[slot].alive:
        return slot

  proc selectedViewLevel(): int =
    ## Returns the uppermost floor a selected living hero stands on.
    if playerMode() and
        playerSlot >= 0 and
        playerSlot < run.world.actors.len:
      return int(run.world.actors[playerSlot].home.level)
    if actionCam.enabled and actionCam.locked:
      return int(actionCam.director.subject.floor)
    int(run.viewLevel(selectedIds))

  proc updateSelectionCamera() =
    ## Activates the camera mode appropriate for the current selection.
    let livingCount = selectedLivingCount()
    followSelection = livingCount > 0
    if livingCount > 1:
      groupCameraScale = 1.0'f32

  proc selectEntity(slot: int, additive = false) =
    ## Selects one party slot and updates the shared camera selection.
    if slot < 0 or slot >= min(PartySize, run.world.actors.len):
      return
    if not additive:
      for i in 0 ..< PartySize:
        selectedIds[i] = false
    elif selectedIds[slot] and selectedCount() > 1:
      selectedIds[slot] = false
      if slot == primaryId:
        for i in 0 ..< PartySize:
          if selectedIds[i]:
            primaryId = i
            break
      updateSelectionCamera()
      actionCam.takeManual()
      return
    selectedIds[slot] = true
    primaryId = slot
    actionCam.takeManual()
    updateSelectionCamera()

  proc selectAllHeroes() =
    ## Selects every party hero and activates the group camera.
    for slot in 0 ..< PartySize:
      selectedIds[slot] = true
    if not selectedAlive():
      for slot in 0 ..< min(PartySize, run.world.actors.len):
        if run.world.actors[slot].alive:
          primaryId = slot
          break
    actionCam.takeManual()
    updateSelectionCamera()

  proc clearSelection() =
    ## Clears the party selection and leaves the camera free-floating.
    for slot in 0 ..< PartySize:
      selectedIds[slot] = false
    followSelection = false
    actionCam.takeManual()

  if playerMode():
    selectedIds[playerSlot] = true
    primaryId = playerSlot
    followSelection = false
    actionCam.enabled = false
    if playerSlot >= 0 and playerSlot < run.world.actors.len:
      cameraTarget =
        actorRenderPosition(run.world.actors[playerSlot]) +
          vec3(0, 0.85'f32, 0)
  else:
    selectAllHeroes()
    actionCam.enabled = true
    followSelection = false

  proc selectedCenter(): Vec3 =
    ## Returns the midpoint of all selected living heroes.
    var count = 0
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      let actor = run.world.actors[slot]
      if selectedIds[slot] and actor.alive:
        result = result + actorRenderPosition(actor)
        inc count
    if count > 0:
      result = result / count.float32

  proc selectedRadius(center: Vec3): float32 =
    ## Returns the largest planar distance from the selection midpoint.
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      let actor = run.world.actors[slot]
      if not selectedIds[slot] or not actor.alive:
        continue
      let
        position = actorRenderPosition(actor)
        dx = position.x - center.x
        dz = position.z - center.z
      result = max(result, sqrt(dx * dx + dz * dz))

  proc feedCtaActions(observeTick = false) =
    ## Refreshes real subjects and observes every simulated tick.
    if not actionCam.enabled:
      return
    var subjects: seq[Subject]
    for slot, actor in run.world.actors:
      if actor.id == 0:
        continue
      let hero = actor.kind == HeroActor
      subjects.add Subject(
        id: actor.id, owner: (if hero: int32(slot) else: -1),
        floor: int32(actor.home.level), position: actorRenderPosition(actor),
        height: 0.85, radius: 0.8,
        visible: hero or selectedVisible(actor.home), alive: actor.alive,
        hp: int32(actor.hp), maxHp: int32(actor.maxHp), complete: true,
        participant: actor.target,
        fighting: actor.action != NoAbility and Abilities[actor.action].damage > 0,
        activity: int32(actor.actionTicks), gold: actor.carriedValue,
        returned: hero and run.world.returned[slot],
        idleScore: (if hero and actor.path.len > 0: 24.0'f else: 12.0'f),
        combatScore: (if hero: 125.0'f else: 85.0'f)
      )
    if observeTick and not viewingSeeking:
      actionCam.director.observe(subjects)
    var heroes: seq[Subject]
    for subject in subjects:
      if subject.owner >= 0:
        heroes.add subject
    actionCam.director.refresh(heroes)

  proc updateTerrainVision(level: int32) =
    ## Uploads softened party vision and explored memory for one floor.
    if terrainVisionTick == run.world.tick and
        terrainVisionLevel == level:
      return
    terrainVisionTick = run.world.tick
    terrainVisionLevel = level
    var values = newSeq[uint8](TilesPerLevel)
    for z in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        let
          tile = TileRef(level: int8(level), x: uint8(x), z: uint8(z))
          index = z * GridTiles + x
        values[index] =
          if selectedVisible(tile): 255
          elif run.world.explored(tile): 48
          else: 0
    uploadTerrainVisibility(blurVisibility(values, GridTiles, GridTiles))

  proc screenPosition(position: Vec3, viewProjection: Mat4): Vec2 =
    ## Projects one world position into window pixel coordinates.
    let clip = viewProjection * vec4(
      position.x,
      position.y,
      position.z,
      1
    )
    if clip.w <= 0:
      return vec2(-10000)
    let normalized = vec2(clip.x / clip.w, clip.y / clip.w)
    vec2(
      (normalized.x * 0.5'f32 + 0.5'f32) * window.size.x.float32,
      (0.5'f32 - normalized.y * 0.5'f32) * window.size.y.float32
    )

  proc addPlayerNames(visibleFrom: int) =
    ## Labels party slots on the visible dungeon floors.
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      let actor = run.world.actors[slot]
      if slot >= run.config.players.len or not actor.alive or
        int(actor.home.level) < visibleFrom:
          continue
      let anchor = actorRenderPosition(actor) + vec3(0, 2.22'f, 0)
      worldBarRenderer.addText(
        playerLabels[slot],
        anchor
      )

  proc pickLoot(viewProjection: Mat4): int32 =
    ## Finds loose treasure under the pointer on the visible floor.
    result = 0
    var bestDistance = 28.0'f32
    let visibleFrom = selectedViewLevel()
    for item in run.world.items:
      if item.carrier != 0 or int(item.tile.level) < visibleFrom:
        continue
      let
        point = screenPosition(
          tileCenter(
            int(item.tile.level), int(item.tile.x), int(item.tile.z)
          ) + vec3(0, 0.4'f32, 0),
          viewProjection
        )
        distance = (point - window.mousePos.vec2).length
      if distance < bestDistance:
        bestDistance = distance
        result = item.id

  proc pickMonster(viewProjection: Mat4): int32 =
    ## Finds a living monster under the pointer on the visible floor.
    result = 0
    var bestDistance = 32.0'f32
    let visibleFrom = selectedViewLevel()
    for slot in PartySize ..< run.world.actors.len:
      let actor = run.world.actors[slot]
      if not actor.alive or actor.kind != MonsterActor or
          int(actor.home.level) < visibleFrom:
        continue
      let
        point = screenPosition(
          actorRenderPosition(actor) + vec3(0, 0.9'f32, 0),
          viewProjection
        )
        distance = (point - window.mousePos.vec2).length
      if distance < bestDistance:
        bestDistance = distance
        result = actor.id

  proc pickEntity(viewProjection: Mat4): int =
    ## Finds the nearest visible living hero under the pointer.
    result = -1
    var bestDistance = 32.0'f32
    let visibleFrom = selectedViewLevel()
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      let actor = run.world.actors[slot]
      if not actor.alive or int(actor.home.level) < visibleFrom:
        continue
      let
        point = screenPosition(
          actorRenderPosition(actor) + vec3(0, 0.9'f32, 0),
          viewProjection
        )
        delta = point - window.mousePos.vec2
        distance = sqrt(delta.x * delta.x + delta.y * delta.y)
      if distance < bestDistance:
        bestDistance = distance
        result = slot

  proc updateWorldSelection(viewProjection: Mat4) =
    ## Left-click selects in spectator mode, or attacks, loots, and heals
    ## for the human hero.
    if not window.mouseReleased(MouseLeft):
      return
    let
      delta = window.mousePos.vec2 - selectionPressPosition
      dragDistance = sqrt(delta.x * delta.x + delta.y * delta.y)
    if selectionStarted and dragDistance <= 6.0'f32 and
        not mouseOverUi(window, sk.mousePos):
      if playerMode():
        let
          slot = playerSlot
          monster = pickMonster(viewProjection)
          loot = pickLoot(viewProjection)
          ally = pickEntity(viewProjection)
        if monster != 0:
          attackTargetId = monster
          queueAttackTarget(slot, monster)
        elif loot != 0:
          attackTargetId = 0
          queuePickupTarget(slot, loot)
        elif ally == slot:
          selectEntity(slot)
        elif ally >= 0:
          attackTargetId = 0
          queueHealTarget(slot, run.world.actors[ally].id)
        elif not selectionAdditive:
          clearSelection()
      else:
        let picked = pickEntity(viewProjection)
        if picked >= 0:
          selectEntity(picked, selectionAdditive)
        elif not selectionAdditive:
          for slot in 0 ..< PartySize:
            selectedIds[slot] = false
          followSelection = false
          actionCam.takeManual()
    selectionStarted = false

  proc updatePlayerWalk(viewProjection: Mat4) =
    ## Right-click walks the human hero onto the tile under the pointer.
    if not playerMode():
      return
    if not window.mouseReleased(MouseRight):
      return
    if mouseOverUi(window, sk.mousePos):
      return
    if (window.mousePos.vec2 - rightPressPosition).length > 6.0'f32:
      return
    let
      (origin, dir) = mouseRay(
        window.mousePos.vec2,
        window.size.vec2,
        viewProjection
      )
      picked = pickWalkableTile(
        origin,
        dir,
        selectedViewLevel()
      )
    if playerSlot < 0 or
        playerSlot >= run.world.actors.len or
        not run.world.actors[playerSlot].alive:
      return
    let
      monster = pickMonster(viewProjection)
      loot = pickLoot(viewProjection)
    if monster != 0:
      attackTargetId = monster
      queueAttackTarget(int32(playerSlot), monster)
      return
    if loot != 0:
      attackTargetId = 0
      queuePickupTarget(int32(playerSlot), loot)
      return
    if picked.hit:
      attackTargetId = 0
      queueWalkTo(
        int32(playerSlot),
        int32(picked.layer),
        int32(picked.x),
        int32(picked.z)
      )
      selectEntity(playerSlot)
      clickMarks.emitClickMark(
        tileCenter(picked.layer, picked.x, picked.z)
      )

  proc playerHeroFrame(): Vec3 =
    ## Returns the look-at that frames the human hero over the HUD.
    if playerSlot < 0 or playerSlot >= run.world.actors.len:
      return cameraTarget
    let actor = run.world.actors[playerSlot]
    if not actor.alive:
      return cameraTarget
    rtsFollowFrame(
      actorRenderPosition(actor) + vec3(0, 0.85'f32, 0),
      cameraDistance
    )

  proc addLootIcons(visibleFrom: int) =
    ## Draws existing loot icons in place of the former footman placeholder.
    for item in run.world.items:
      if item.carrier != 0 or int(item.tile.level) < visibleFrom or
        not selectedVisible(item.tile):
          continue
      let
        ability = LootAbilities[item.kind]
        key =
          if ability != NoAbility:
            "ability_" & AbilityIconFiles[ability]
          else:
            case item.kind
            of GoldPile: "gold"
            of Gemstone: "crystal"
            of Chalice: "chalice"
            of Idol: "idol"
            of Crown: "crown"
            else: "bounty"
        tint =
          case item.kind
          of Chalice: rgbx(217, 209, 140, 255)
          of Idol: rgbx(158, 122, 82, 255)
          of Crown: rgbx(255, 199, 71, 255)
          else: rgbx(255, 255, 255, 255)
        entry = sk.atlas.entries[key]
        anchor = tileCenter(
          int(item.tile.level), int(item.tile.x), int(item.tile.z)
        ) + vec3(0, 0.4'f, 0)
      worldBarRenderer.addBillboardQuad(
        anchor,
        vec2(-0.36'f),
        vec2(0.72'f),
        tint,
        vec2(entry.x.float32, entry.y.float32) / sk.atlas.size.float32,
        vec2(entry.width.float32, entry.height.float32) /
          sk.atlas.size.float32,
        textureMode = ColorTexture
      )

  proc drawWorldBars(
      viewProjection: Mat4,
      cameraRight,
      cameraUp: Vec3,
      visibleFrom: int,
      dt: float32
  ) =
    ## Draws hero resources and damage-gated monster health in the world.
    damageTrails.beginFrame()
    worldBarRenderer.clear()
    addLootIcons(visibleFrom)
    for actor in run.world.actors:
      if actor.id == 0 or not actor.alive or
          int(actor.home.level) < visibleFrom:
        continue
      let
        health = max(actor.hp, 0'i16).float32
        maximumHealth = max(actor.maxHp, 1'i16).float32
        delayedHealth = damageTrails.delayedValue(
          actor.id,
          health,
          maximumHealth,
          dt
        )
      if actor.kind == HeroActor:
        var bars = @[WorldResourceBar(
          value: health,
          maximum: maximumHealth,
          delayedValue: delayedHealth,
          height: 0.15'f32,
          color: healthColor(health, maximumHealth),
          showDamageTrail: true
        )]
        if actor.maxMana > 0:
          bars.add WorldResourceBar(
            value: max(actor.mana, 0'i16).float32,
            maximum: actor.maxMana.float32,
            delayedValue: max(actor.mana, 0'i16).float32,
            height: 0.09'f32,
            color: rgbx(60, 125, 231, 255)
          )
        let anchor = actorRenderPosition(actor) + vec3(0, 2.02'f32, 0)
        worldBarRenderer.addResourceBars(anchor, 1.55'f32, bars)
      elif actor.hp < actor.maxHp:
        let
          height = HeroTargetHeight * RankScales[actor.species.monsterRank]
          anchor = actorRenderPosition(actor) + vec3(0, height + 0.2'f, 0)
          bars = [WorldResourceBar(
            value: health,
            maximum: maximumHealth,
            delayedValue: delayedHealth,
            height: 0.1'f32,
            color: healthColor(health, maximumHealth),
            showDamageTrail: true
          )]
        worldBarRenderer.addResourceBars(anchor, 1.0'f32, bars)
    damageTrails.finishFrame()
    addPlayerNames(visibleFrom)
    worldBarRenderer.draw(
      viewProjection,
      cameraRight,
      cameraUp,
      sk.atlasTextureId()
    )

  proc attackTargetSlot(visibleFrom: int): int32 =
    ## Returns the living attack-target slot, or minus one.
    if attackTargetId == 0:
      return -1
    let slot = run.world.actorSlot(attackTargetId)
    if slot < 0:
      attackTargetId = 0
      return -1
    let actor = run.world.actors[slot]
    if not actor.alive or actor.kind != MonsterActor:
      attackTargetId = 0
      return -1
    if int(actor.home.level) < visibleFrom or
        not selectedVisible(actor.home):
      return -1
    slot

  proc drawActorOutline(
      slot: int32,
      view,
      projection: Mat4,
      cameraEye: Vec3,
      outlineColor: Vec3
  ) =
    ## Draws one actor silhouette and composites it in `outlineColor`.
    if slot < 0 or slot >= run.world.actors.len or slot >= visuals.len:
      return
    let actor = run.world.actors[slot]
    if actor.id == 0:
      return
    let model =
      if actor.kind == HeroActor:
        heroModels[actor.heroClass]
      else:
        monsterModels[actor.species]
    selectionOutline.beginMask(window.size)
    beginCharacters(scene, window, view, projection, cameraEye)
    drawCharacter(
      scene,
      model,
      actorRenderPosition(actor),
      visuals[slot].angle,
      visuals[slot].clip,
      visuals[slot].animTime,
      color(1, 1, 1, 1)
    )
    finishCharacters(scene)
    selectionOutline.drawOutline(outlineColor)

  proc drawSelectedOutline(
      view,
      projection: Mat4,
      cameraEye: Vec3,
      visibleFrom: int
  ) =
    ## Draws the yellow party outline and the red attack-target outline.
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      let actor = run.world.actors[slot]
      if not selectedIds[slot] or not actor.alive or
          int(actor.home.level) < visibleFrom:
        continue
      drawActorOutline(
        int32(slot),
        view,
        projection,
        cameraEye,
        SelectionOutlineColor
      )
    if playerMode():
      let target = attackTargetSlot(visibleFrom)
      if target >= 0:
        drawActorOutline(
          target,
          view,
          projection,
          cameraEye,
          AttackOutlineColor
        )

  window.onButtonPress = proc(button: Button) =
    sk.uiScale = gameUiScale(window)
    sk.mousePos = window.mousePos.vec2 / sk.uiScale
    case button
    of MouseLeft, MouseLeftKey:
      if window.buttonDown[KeyLeftControl] or
          window.buttonDown[KeyRightControl]:
        if not playerMode():
          selectAllHeroes()
      elif not mouseOverUi(window, sk.mousePos):
        selectionPressPosition = window.mousePos.vec2
        selectionStarted = true
        selectionAdditive =
          window.buttonDown[KeyLeftShift] or
          window.buttonDown[KeyRightShift]
    of MouseRight, MouseRightKey:
      if not mouseOverUi(window, sk.mousePos):
        rightPressPosition = window.mousePos.vec2
        lastMouse = window.mousePos
    of MouseMiddle, MouseMiddleKey:
      if not mouseOverUi(window, sk.mousePos):
        lastMouse = window.mousePos
    of KeySpace:
      transport.handleKey(button)
    of KeyC:
      if not playerMode():
        actionCam.toggle(followSelection)
    of KeyT:
      scene.toggleShading()
    of KeyF, KeyG:
      if playerMode() and
          playerSlot >= 0 and
          playerSlot < run.world.actors.len:
        let bag = int32(if button == KeyF: 0 else: 1)
        if window.buttonDown[KeyLeftShift] or
            window.buttonDown[KeyRightShift]:
          queueDropItem(int32(playerSlot), bag)
        else:
          queueUseItem(int32(playerSlot), bag)
      elif button == KeyF and
          not playerMode() and
          selectedLivingCount() > 0:
        followSelection = not followSelection
        if followSelection:
          actionCam.takeManual()
    of KeyF1, KeyF2:
      discard handleChromeKey(button)
    of KeyEscape:
      when not defined(emscripten):
        window.closeRequested = true
    else:
      discard

  window.onScroll = proc() =
    sk.uiScale = gameUiScale(window)
    sk.mousePos = window.mousePos.vec2 / sk.uiScale
    if not mouseOverUi(window, sk.mousePos):
      cancelCameraEase(cameraEase)
      if not playerMode():
        actionCam.takeManual()
      if not playerMode() and
          followSelection and selectedLivingCount() > 1:
        groupCameraScale = clamp(
          groupCameraScale *
            (1.0'f32 - window.scrollDelta.y * 0.1'f32 / 3.0'f32),
          0.75,
          3.0
        )
      else:
        cameraDistance = clamp(
          cameraDistance *
            (1.0'f32 - window.scrollDelta.y * 0.1'f32 / 3.0'f32),
          8,
          160
        )

  when defined(takeScreenshot):
    var screenshotFrame = 0
    applyScreenshotCamera(cameraDistance)
    if existsEnv("PBR"):
      scene.shading = PbrCharacters
    if existsEnv("SIM_TICKS"):
      for _ in 0 ..< getEnv("SIM_TICKS").parseInt:
        if run.world.phase in {EscapedPhase, WipedPhase}:
          break
        advanceGame()
      # Snap rather than ease: a capture renders a handful of frames, which
      # is nowhere near enough for a smoothed camera to travel from the
      # entrance to wherever the party actually got to.
      cameraTarget = partyCenter()
    if run.replayMode and existsEnv("REPLAY_TICK"):
      transport.seekTo(int32(getEnv("REPLAY_TICK").parseInt))
      cameraTarget = partyCenter()
    if existsEnv("SELECT_ALL"):
      selectAllHeroes()

  var
    viewingClock: ViewingClock
    cameraSeekSerial = -1

  holdSplash(sk, window, splash)
  window.onFrame = proc() =
    profileBlock "frame":
      let dt = frameDelta(lastFrameTime, SimulationStep)
      viewingDt = viewingClock.viewingDelta(window)
      viewingSeeking = transport.targetTick >= 0 or transport.restoreTick >= 0
      if not transport.playing or viewingSeeking:
        viewingDt = 0
      if cameraSeekSerial != transport.seekSerial:
        actionCam.resetDirector(transport.automaticSeek)
        cameraSeekSerial = transport.seekSerial
      sk.uiScale = gameUiScale(window)
      sk.mousePos = window.mousePos.vec2 / sk.uiScale
      let recorded =
        if run.recorder != nil: int32(run.recorder.data.hashes.len)
        elif run.replayMode: int32(run.replayPlayer.data.hashes.len)
        else: run.world.tick
      transport.sync(
        run.world.tick,
        recorded,
        run.world.phase in {EscapedPhase, WipedPhase}
      )
      let restoreTick = transport.takeRestore()
      if restoreTick >= 0:
        restoreTo(restoreTick)
        transport.sync(
          run.world.tick,
          recorded,
          run.world.phase in {EscapedPhase, WipedPhase}
        )
      feedCtaActions(observeTick = true)
      transport.startFrame(dt, TickRate)
      let
        frameStart = epochTime()
        active = simulationActive(transport)
      run.historyPlayback = transport.inHistory
      profileBlock "simulate":
        while transport.shouldTick(frameStart):
          if atLiveTickCap(run.world.tick, options.maximumTicks, transport.live):
            break
          captureActorPositions()
          let oldActors = captureParticleActors()
          run.historyPlayback = transport.inHistory
          advanceGame()
          feedCtaActions(observeTick = true)
          emitTickParticles(oldActors)
          cacheSeekCheckpoint()
          let recordedNow =
            if run.recorder != nil: int32(run.recorder.data.hashes.len)
            elif run.replayMode: int32(run.replayPlayer.data.hashes.len)
            else: run.world.tick
          transport.sync(
            run.world.tick,
            recordedNow,
            run.world.phase in {EscapedPhase, WipedPhase}
          )
      renderAlpha =
        if active:
          clamp(transport.accumulator / SimulationStep, 0.0'f32, 1.0'f32)
        else:
          1.0'f32
      if active:
        particles.advanceParticles(dt * transport.speed.float32)
        clickMarks.advanceClickMarks(dt * transport.speed.float32)

      # Camera
      profileBlock "camera":
        let overUi = mouseOverUi(window, sk.mousePos)
        if focusPlayerHero:
          focusPlayerHero = false
          startCameraEase(cameraEase, cameraTarget)
        if window.mousePressed(MouseMiddle) and
            (not overUi or window.buttonPressed[MouseMiddleKey]):
          if not playerMode():
            followSelection = false
            actionCam.takeManual()
          cancelCameraEase(cameraEase)
          lastMouse = window.mousePos
        let wantPan =
          window.mouseDown(MouseMiddle) and
            (not overUi or window.buttonDown[MouseMiddleKey]) or
          (not playerMode() and not overUi and window.mouseDown(MouseRight))
        if wantPan and not panning:
          lastMouse = window.mousePos
        panning = wantPan
        updateMinimapCamera(
          window,
          sk.mousePos,
          cameraTarget,
          minimapPanning,
          followSelection,
          selectedViewLevel()
        )
        if minimapPanning:
          actionCam.takeManual()
          cancelCameraEase(cameraEase)
        if playerMode():
          if panning:
            let delta = window.mousePos - lastMouse
            lastMouse = window.mousePos
            cancelCameraEase(cameraEase)
            cameraTarget.x -= delta.x.float32 * 0.05'f32
            cameraTarget.z -= delta.y.float32 * 0.05'f32
            cameraTarget.x = clamp(cameraTarget.x, -HalfGrid, HalfGrid)
            cameraTarget.z = clamp(cameraTarget.z, -HalfGrid, HalfGrid)
          elif not minimapPanning and
              applyRtsPan(
                cameraTarget,
                rtsPanDir(window),
                dt,
                cameraDistance,
                HalfGrid
              ):
            cancelCameraEase(cameraEase)
          else:
            discard advanceCameraEase(
              cameraEase,
              cameraTarget,
              playerHeroFrame(),
              dt
            )
        else:
          if panning:
            let delta = window.mousePos - lastMouse
            lastMouse = window.mousePos
            followSelection = false
            actionCam.takeManual()
            cameraTarget.x -= delta.x.float32 * 0.05'f32
            cameraTarget.z -= delta.y.float32 * 0.05'f32
            cameraTarget.x = clamp(cameraTarget.x, -HalfGrid, HalfGrid)
            cameraTarget.z = clamp(cameraTarget.z, -HalfGrid, HalfGrid)
          if not minimapPanning and
              applyRtsPan(
                cameraTarget,
                rtsPanDir(window),
                dt,
                cameraDistance,
                HalfGrid
              ):
            followSelection = false
            actionCam.takeManual()
          if actionCam.enabled:
            feedCtaActions()
            actionCam.direct(
              cameraTarget, cameraDistance, viewingDt,
              run.world.phase in {EscapedPhase, WipedPhase} or
                transport.tick >= transport.timelineEnd,
              transport.repeating,
              window.size.x.float32 / max(window.size.y.float32, 1)
            )
          else:
            let livingSelection = selectedLivingCount()
            if followSelection and livingSelection == 1:
              let
                cameraHero = selectedLivingHero()
                actor = run.world.actors[cameraHero]
                targetPosition =
                  actorRenderPosition(actor) + vec3(0, 0.85'f32, 0)
              cameraTarget = mix(
                cameraTarget,
                targetPosition,
                damping(5.0'f32, dt)
              )
            elif followSelection and livingSelection > 1:
              let
                groupCenter = selectedCenter()
                groupDistance = clamp(
                  10.0'f32 + selectedRadius(groupCenter) * 2.8'f32,
                  16.0'f32,
                  80.0'f32
                ) * groupCameraScale
              cameraTarget = mix(
                cameraTarget,
                groupCenter + vec3(0, 0.45'f32, 0),
                damping(4.0'f32, dt)
              )
              cameraDistance = mix(
                cameraDistance,
                groupDistance,
                damping(2.0'f32, dt)
              )
            elif followSelection:
              followSelection = false

      let
        eye = rtsCameraEye(cameraTarget, cameraDistance)
        view = lookAt(eye, cameraTarget, vec3(0, 1, 0))
        projection = perspective(
          45.0'f32,
          window.size.x.float32 / window.size.y.float32,
          0.1,
          400.0
        )
        viewProjection = projection * view
        cameraForward = normalize(cameraTarget - eye)
        barCameraRight = normalize(cross(cameraForward, vec3(0, 1, 0)))
        barCameraUp = normalize(cross(barCameraRight, cameraForward))

      updateWorldSelection(viewProjection)
      updatePlayerWalk(viewProjection)

      profileBlock "drawWorld":
        # One clock for the whole frame: the palette, the sun's position,
        # and its shadow map all follow the expedition hour. The fractional
        # tick keeps the sun gliding between simulation steps instead of
        # visibly stepping shadow positions once a second.
        scene.setToonHour(
          smoothClockHour(float32(run.world.tick) + renderAlpha))
        setEnvironmentPalette(scene.toon)

        # The cutaway. Levels are baked in order from the surface down, so
        # "this floor and everything under it" is one contiguous vertex range and
        # costs a single draw call with an offset. The sun depth pass draws
        # the same range, so hidden floors above never cast down into view.
        let visibleFrom = selectedViewLevel()

        # One loop for both passes: actors render into
        # the sun's depth map first, then for the camera. The turn smoothing
        # and clip time advance exactly once per frame, in whichever pass
        # runs first.
        proc drawWorldActors(advanceVisuals: bool) =
          if visuals.len < run.world.actors.len:
            visuals.setLen(run.world.actors.len)
          for slot in 0 ..< run.world.actors.len:
            let actor = run.world.actors[slot]
            if actor.id == 0 or not actor.alive:
              continue
            if int(actor.home.level) < visibleFrom:
              continue     # above the cut, so not drawn
            if actor.kind == MonsterActor and not selectedVisible(actor.home):
              continue
            let
              position = actorRenderPosition(actor)
              hero = actor.kind == HeroActor
              model =
                if hero: heroModels[actor.heroClass]
                else: monsterModels[actor.species]
            if advanceVisuals:
              visuals[slot].angle = actorRenderFacing(actor)
              let wantedClip =
                if actor.busy:
                  if hero: heroAttack[actor.heroClass]
                  else: monsterAttack[actor.species]
                elif actor.moving:
                  if hero: heroRun[actor.heroClass]
                  else: monsterRun[actor.species]
                else:
                  if hero: heroIdle[actor.heroClass]
                  else: monsterIdle[actor.species]
              if visuals[slot].clip != wantedClip:
                visuals[slot].clip = wantedClip
                visuals[slot].animTime = 0
              if active:
                visuals[slot].animTime += dt * transport.speed.float32
            drawCharacter(
              scene, model, position, visuals[slot].angle,
              visuals[slot].clip, visuals[slot].animTime)

        let shadowPassRan =
          sunShadowsActive() and layerVertexRanges.len > visibleFrom
        if shadowPassRan:
          sunDepthPasses(window.size):
            drawTerrainSunDepth(
              layerVertexRanges[visibleFrom].a,
              layerVertexRanges[^1].b - layerVertexRanges[visibleFrom].a + 1
            )
            scene.sunDepthPass = true
            # The turn smoothing and clip times advance in the first pass
            # only, so both maps and the camera see the same frame.
            drawWorldActors(advanceVisuals = sunPassIndex == 0)
            scene.sunDepthPass = false

        glViewport(0, 0, window.size.x.GLsizei, window.size.y.GLsizei)
        when not defined(emscripten):
          glEnable(GL_MULTISAMPLE)
        glClearColor(0, 0, 0, 1)
        glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

        if layerVertexRanges.len > visibleFrom:
          let
            first = layerVertexRanges[visibleFrom].a
            last = layerVertexRanges[^1].b
          updateTerrainVision(int32(visibleFrom))
          drawTerrainRange(
            viewProjection,
            first,
            last - first + 1,
            showTiles
          )

        beginCharacters(scene, window, view, projection, eye)
        drawWorldActors(advanceVisuals = not shadowPassRan)
        finishCharacters(scene)
        particles.drawParticles(
          viewProjection,
          barCameraRight,
          barCameraUp,
          cameraForward
        )
        clickMarks.drawClickMarks(viewProjection)
        if showPaths:
          worldShapes.clear()
          worldShapes.addActorPaths(run.world, visibleFrom)
          worldShapes.draw(viewProjection)
        drawWorldBars(
          viewProjection,
          barCameraRight,
          barCameraUp,
          visibleFrom,
          dt
        )
        drawSelectedOutline(
          view,
          projection,
          eye,
          visibleFrom
        )

      profileBlock "ui":
        glDisable(GL_DEPTH_TEST)
        glDisable(GL_CULL_FACE)
        glDisable(GL_BLEND)
        when not defined(emscripten):
          glDisable(GL_MULTISAMPLE)
        glActiveTexture(GL_TEXTURE0)
        glBindTexture(GL_TEXTURE_2D, sk.atlasTextureId())
        sk.beginUi(window, window.size)
        drawUi(
          sk,
          window,
          transport,
          cameraTarget,
          cameraDistance,
          primaryId,
          selectedIds,
          followSelection,
          actionCam,
          focusPlayerHero
        )
        sk.endUi()
        drawStatsOverlay(sk, window)
      when defined(takeScreenshot):
        captureScreenshot(
          window,
          screenshotFrame,
          8,
          "examples/call_to_adventure/shot.png"
        )
      profileBlock "present":
        window.presentFrame(framePaceHz)
        reportDirectorFrame(
          actionCam, transport, cameraDistance, int32(run.hashCheck.mismatches)
        )
        reportReplayFrame(run.world.tick, int32(run.hashCheck.mismatches))
    if noteProfileFrame():
      when not defined(emscripten):
        window.closeRequested = true

  while not window.closeRequested:
    pollEvents()
    waitForDisplay()

  if not run.replayMode:
    saveRecording()
  clickMarks.closeClickMarks()
  worldShapes.closeShapeRenderer()
  worldBarRenderer.closeWorldBarRenderer()
  selectionOutline.closeSelectionOutline()
  particles.closeParticles()
  finishGameProfile()
  echo "run ended: ", run.world.phase, " with ", run.world.banked, " gold banked"
