## Heartleaf spectator viewer.
##
## Reads the simulation and never writes it. The renderer interpolates body
## poses between ticks and samples terrain height for the vertical. None of
## that can flow back into `World`.

import
  std/[math, times],
  fixxy, opengl, pixie, vmath, windy, silky,
  polyworld/[actioncam, assets, characters, chargen, chrome, clickmarks,
    common, gameuis, inputs, occlusions, pathing, player, profiles, quadterrain, rtscameras,
    shadows, shapes, tapes, terrainsurfaces, viewers],
  content,
  maps as mapgen,
  sim,
  game,
  replays,
  ui,
  controls,
  ground,
  appearances,
  ambience,
  scenery,
  layouts,
  democamera,
  scorecard

when defined(takeScreenshot):
  import std/[os, strutils]

const
  WindowTitle = "Heartleaf"
  AtlasPath = TmpRoot & "/heartleaf.atlas.png"
  LogoPath = DataRoot & "/themes/heartleaf/heartleaf_logo.png"
  SeekCheckpointTicks = TickRate * 10
  VillagerHeight = GnomeHeight

type
  SeekCheckpoint = object
    world: World
    hashCheck: ReplayHashCheck

var
  window*: Window
  sk*: Silky
  cameraDistance* = TownOverviewDistance
  cameraTarget* = vec3(0, 0, 0)
  cameraEye = vec3(0, 0, 0)
  panning = false
  minimapPanning* = false
  followSlot* = -1'i32
  rightPressPosition = vec2(0)
  seekCheckpoints: seq[SeekCheckpoint]
  transport* = initPlayer(
    live = not run.replayMode,
    durationTicks = run.maximumTicks,
    playing = not options.pauseOnStart,
    speed = options.speed,
    repeating = run.replayMode
  )
  frameAlpha = 0.0'f32
  previousPositions: array[VillagerCount, Vec3]
  previousFacings: array[VillagerCount, float32]
  havePoses = false

## Presentation helpers

proc addHudIcons(builder: AtlasBuilder) =
  ## Packs the supplied Heartleaf logo with its original transparency.
  builder.addThemeLogo(LogoPath)

proc tileCentreXZ(tile: Tile2): Vec2 =
  ## Converts a tile coordinate to the world-space centre of that tile.
  vec2(float32(tile.x) - HalfGrid + 0.5'f32,
       float32(tile.y) - HalfGrid + 0.5'f32)

proc tileWorldPoint(tile: Tile2): Vec3 =
  ## Returns the render centre of one map tile.
  let xz = tileCentreXZ(tile)
  vec3(xz.x, surfaceHeight(xz.x, xz.y), xz.y)

proc villagerWorldPoint(v: Villager): Vec3 =
  ## Converts a tile-space body into a render position.
  let
    x = toFloat32(v.body.pos.x) - HalfGrid
    z = toFloat32(v.body.pos.y) - HalfGrid
  vec3(x, surfaceHeight(x, z), z)

proc villagerYaw(v: Villager): float32 =
  ## Turns body facing into the renderer's yaw convention.
  let dir = direction(v.body.facing)
  arctan2(toFloat32(dir.x), toFloat32(dir.y))

proc renderPoint(v: Villager): Vec3 =
  ## Interpolates one villager between the latest simulation snapshots.
  let current = villagerWorldPoint(v)
  if not interpolateVisuals or not havePoses:
    return current
  mix(previousPositions[v.slot], current, frameAlpha)

proc renderFacing(v: Villager): float32 =
  ## Interpolates yaw the short way so a +pi / -pi flip is not a spin.
  let current = villagerYaw(v)
  if not interpolateVisuals or not havePoses:
    return current
  let previous = previousFacings[v.slot]
  previous + shortestTurn(previous, current) * frameAlpha

proc captureVillagerPoses() =
  ## Remembers poses before one authoritative tick.
  for slot in 0 ..< VillagerCount:
    let v = run.world.villagers[slot]
    previousPositions[slot] = villagerWorldPoint(v)
    previousFacings[slot] = villagerYaw(v)
  havePoses = true

proc renderTime(ticks: int32): float32 =
  ## Converts animation ticks into seconds for the clip sampler.
  (float32(ticks) + frameAlpha) / float32(TickRate)

proc runGraphics*() =
  ## Runs the native or Emscripten spectator.
  startGameProfile()
  profileBlock "atlas":
    let builder = newHudAtlas(4096)
    addHudIcons(builder)
    builder.addDefaultFonts()
    builder.write(AtlasPath)
  profileBlock "window":
    (window, sk) = initGameWindow(
      WindowTitle,
      AtlasPath,
      gameWindowSize(options.windowWidth, options.windowHeight),
      options.vsync
    )
  let splash = startSplash(sk, window)
  var captureLayer = AllLayer
  when defined(takeScreenshot):
    case getEnv("HEARTLEAF_LAYER")
    of "ground": captureLayer = GroundLayer
    of "buildings": captureLayer = BuildingsLayer
    of "vegetation": captureLayer = VegetationLayer
    of "props": captureLayer = PropsLayer
    of "", "all": discard
    else: raise newException(ValueError, "Unknown Heartleaf capture layer")

  profileBlock "terrain":
    quadterrain.seed = run.world.map.seed
    initTerrain(
      treeStyle = NoTrees,
      terrainStyle = GeneratedTerrain,
      rockStyle = NoRocks,
      settings = TerrainAssets(size: 512, grass: false, water: false)
    )
    terrainSplats = false
    terrainTextureScale = 0.16'f
    for (surface, name) in [
      (GrassSurface, "heartleaf-layer-grass-1"),
      (OliveSurface, "heartleaf-layer-grass-1"),
      (MossSurface, "heartleaf-layer-grass-1"),
      (SparseSurface, "heartleaf-layer-grass-1"),
      (DirtSurface, "heartleaf-layer-path-2"),
      (CobbleSurface, "heartleaf-layer-paving-1")
    ]:
      var paint: Image
      if surface <= SparseSurface:
        let tint = [vec3(1), vec3(0.98, 1, 0.98),
          vec3(0.96, 0.99, 0.97), vec3(1)][surface]
        paint = meadowTexture(tint)
      elif surface == DirtSurface:
        paint = pathTexture()
      else:
        paint = readImage(DataRoot & "/terrain/tiles/" & name & ".rgb.png")
      setTerrainMaterial(
        surface.int,
        paint,
        readImage(DataRoot & "/terrain/tiles/" & name & ".height.png")
      )
    for kind in [RoadTile, StoneTile, GardenTileKind, HouseTileKind, TreeTile]:
      setTileMaterial(
        kind.int,
        GrassSurface.float32,
        DirtSurface.float32,
        vec3(1),
        vec3(0.85),
        1
      )
    uploadGroundMask(buildReferenceGroundMask(readImage(
      DataRoot & "/terrain/heartleaf/layers/01-grass-and-paths.png"
    )), MaskSize)
    setGroundLayers(
      CobbleSurface.float32,
      DirtSurface.float32,
      GrassSurface.float32,
      CobbleSurface.float32
    )

  var villageArt: VillageArt

  proc placeVillageProps() =
    ## Places the reference village over its matching simulation map.
    villageArt.placeVillage(run.world.map, run.world.map.seed, captureLayer)

  profileBlock "props":
    villageArt = loadVillageArt(run.world.map.seed)
    placeVillageProps()
  if captureLayer == AllLayer:
    let field = villageOcclusion(run.world.map.seed, villageArt.roof)
    uploadAmbientOcclusion(bakeOcclusion(field), field.size,
      field.origin, field.span)
  defer: clearAmbientOcclusion()

  ## Everything is always visible; there is no fog in a village.
  block:
    var values = newSeq[uint8](GridTiles * GridTiles)
    for value in values.mitems:
      value = 255
    uploadTerrainVisibility(values)

  var
    villagerModels: array[VillagerCount, CharacterModel]
    villagerClips: array[VillagerCount, array[AnimationSlot, int]]
  profileBlock "models":
    let manifest = readManifest(GnomeLibrary)
    for slot in 0 ..< VillagerCount:
      villagerModels[slot] = loadGnome(manifest, slot)
      for animation in AnimationSlot:
        villagerClips[slot][animation] =
          villagerModels[slot].clipIndex(GnomeClips[animation])

  let scene = newCharacterScene(window)
  scene.useToonShading()
  scene.setToonHour(12)
  profileBlock "portraits":
    for slot in 0 ..< VillagerCount:
      sk.addAtlasImage(
        villagerPortraitKey(int32(slot)),
        gnomePortrait(window, scene, villagerModels[slot])
      )
  setEnvironmentPalette(scene.toon)
  drawSplash(sk, window, splash.name)
  var
    clickMarks = initClickMarks()
    worldShapes = initShapeRenderer()

  cameraTarget = TownCameraTarget
  var actionCam = initActionCam(
    minDistance = 16,
    maxDistance = 120,
    tight = 0.4,
    followRate = 1.0,
    zoomRate = 0.7,
    holdSeconds = 2.8,
    mapSpan = HalfGrid * 2,
    closeScale = 0.5
  )

  let demoMode = options.playerSlot == 0 or run.replayMode
  var demoCamera = initDemoCamera(VillagerCount)
  actionCam.takeManual()

  ## Replay scaffolding

  seekCheckpoints.add SeekCheckpoint(
    world: run.world.clone(),
    hashCheck: run.hashCheck
  )

  proc captureCheckpoint() =
    if run.world.tick div SeekCheckpointTicks < seekCheckpoints.len:
      return
    seekCheckpoints.add SeekCheckpoint(
      world: run.world.clone(),
      hashCheck: run.hashCheck
    )

  proc restoreTo(target: int32) =
    ## Reloads the last checkpoint at or before a tick, then resimulates.
    let wanted = clamp(target, 0'i32, transport.timelineEnd)
    var slot = min(
      int(wanted) div SeekCheckpointTicks,
      seekCheckpoints.len - 1
    )
    while slot > 0 and seekCheckpoints[slot].world.tick > wanted:
      dec slot
    run.world.restore(seekCheckpoints[slot].world)
    if run.recorder != nil:
      run.replayPlayer.data = run.recorder.data
    run.replayPlayer.syncCursor(uint32(run.world.tick))
    run.hashCheck = seekCheckpoints[slot].hashCheck
    run.historyPlayback = true
    havePoses = false
    demoCamera.resetMotion()
    while run.world.tick < wanted:
      advanceGame()
      captureCheckpoint()

  seekStartup(captureCheckpoint)
  transport.sync(run.world.tick,
    (if run.recorder != nil: int32(run.recorder.data.hashes.len)
     else: int32(run.replayPlayer.data.hashes.len)), run.world.over)

  ## Camera and input

  proc playerMode(): bool =
    ## Returns whether this client issues orders for one villager.
    options.playerSlot > 0 and not run.replayMode

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

  proc pickVillager(viewProjection: Mat4): int32 =
    ## Finds the nearest outdoor villager under the pointer, or -1.
    result = -1
    var bestDistance = 28.0'f32
    for slot in 0 ..< VillagerCount:
      let v = run.world.villagers[slot]
      if v.inHouse >= 0:
        continue
      let distance = (
        screenPosition(
          renderPoint(v) + vec3(0, VillagerHeight * 0.5'f32, 0),
          viewProjection
        ) - window.mousePos.vec2
      ).length
      if distance < bestDistance:
        bestDistance = distance
        result = int32(slot)

  proc houseAtTile(x, y: int32): int32 =
    ## The house whose footprint or doorstep contains this tile, or -1.
    result = -1
    for slot in 0 ..< VillagerCount:
      let house = run.world.map.houses[slot]
      if chebyshev(tile2(x, y), house.center) <= 1 or
          chebyshev(tile2(x, y), house.door) <= 1:
        return int32(slot)

  proc gardenAtTile(x, y: int32): int32 =
    ## The garden plot on this tile, or -1.
    result = -1
    for garden in 0 ..< GardenCount:
      if run.world.map.gardenTiles[garden] == tile2(x, y):
        return int32(garden)

  proc feedActionCam() =
    ## Points the director camera at gathering, waving, the dinner rush,
    ## and the parties themselves.
    let tick = run.world.tick
    actionCam.beginFrame(tick)
    for slot in 0 ..< VillagerCount:
      let v = run.world.villagers[slot]
      if v.inHouse >= 0:
        continue
      let pos = renderPoint(v)
      if v.animation == GatherAnimation:
        actionCam.noteInterest(int32(slot) + 1, pos, 40, 2, tick, 24)
      elif v.animation == WaveAnimation:
        actionCam.noteInterest(int32(slot) + 1, pos, 55, 2.5, tick, 24)
      elif v.order == EnterOrder and
          run.world.minuteOfDay >= 17 * 60:
        actionCam.noteInterest(int32(slot) + 1, pos, 45, 2, tick, 24)
    if run.world.phase == EveningPhase:
      for house in 0 ..< VillagerCount:
        if run.world.lastTally[house].valid:
          actionCam.noteInterest(
            100'i32 + int32(house),
            tileWorldPoint(run.world.map.houses[house].center),
            70,
            3,
            tick,
            48
          )

  proc followPoint(v: Villager): Vec3 =
    ## Frames an outdoor gnome at body height, or their house while indoors.
    if v.inHouse >= 0:
      tileWorldPoint(run.world.map.houses[v.inHouse].center)
    else:
      renderPoint(v) + vec3(0, VillagerHeight * 0.5'f32, 0)

  proc demoSubjects(): array[VillagerCount, DemoSubject] =
    ## Supplies interpolated viewer positions without modifying the simulation.
    for slot, v in run.world.villagers:
      var conversation = 0
      if v.order == TalkOrder:
        for member in run.world.socialGroup(int32(slot)):
          conversation = member + 1
          break
      result[slot] = DemoSubject(
        conversation: conversation,
        position: followPoint(v),
        indoors: v.inHouse >= 0,
        quiet: v.animation == IdleAnimation
      )

  proc updateCamera(dt: float32) =
    ## Applies fixed-north RTS pan, zoom, and villager following.
    updateMinimapCamera(
      window,
      sk.mousePos,
      cameraTarget,
      minimapPanning
    )
    if minimapPanning:
      followSlot = -1
      actionCam.takeManual()
    let overUi = mouseOverUi(window, sk.mousePos)
    if window.mousePressed(MouseRight) and not overUi:
      rightPressPosition = window.mousePos.vec2
      panning = true
    if not window.mouseDown(MouseRight):
      panning = false
    let delta = window.mouseDelta.vec2
    if panning and delta.length > 0:
      followSlot = -1
      actionCam.takeManual()
      let speed = cameraDistance * 0.0015
      cameraTarget.x -= delta.x * speed
      cameraTarget.z -= delta.y * speed
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
      followSlot = -1
      actionCam.takeManual()
    if not overUi and window.scrollDelta.y != 0:
      actionCam.takeManual()
      cameraDistance = clamp(
        cameraDistance * pow(0.92'f32, window.scrollDelta.y / 3.0'f32),
        6.0'f32,
        220.0'f32
      )
    if demoMode:
      if actionCam.enabled:
        let subjects = demoSubjects()
        if not demoCamera.active:
          demoCamera.activate(subjects, cameraTarget, int(followSlot))
          followSlot = -1
        demoCamera.update(subjects, cameraTarget, dt, transport.playing and not run.world.over)
        return
      demoCamera.deactivate()
    if actionCam.enabled:
      feedActionCam()
      actionCam.chooseShot(dt, transport.speed)
      actionCam.follow(
        cameraTarget,
        cameraDistance,
        dt,
        transport.speed
      )
      return
    if followSlot >= 0:
      cameraTarget = followPoint(run.world.villagers[followSlot])

  proc snapFollowCamera() =
    ## Speed controls recenter only the current follow target.
    if followSlot >= 0:
      cameraTarget = followPoint(run.world.villagers[followSlot])
    elif demoMode and demoCamera.active:
      demoCamera.snapToSubject(demoSubjects(), cameraTarget)

  proc updateSelection(viewProjection: Mat4) =
    ## A left click on a villager follows them; empty ground lets go.
    if not window.mouseReleased(MouseLeft):
      return
    if mouseOverUi(window, sk.mousePos) or minimapPanning:
      return
    let picked = pickVillager(viewProjection)
    if picked >= 0:
      followSlot = picked
      actionCam.takeManual()
    else:
      followSlot = -1

  proc updatePlayerOrder(viewProjection: Mat4) =
    ## Turns a right-click into an invite, gather, enter, or walk.
    if not playerMode():
      return
    if not window.mouseReleased(MouseRight):
      return
    if mouseOverUi(window, sk.mousePos):
      return
    if (window.mousePos.vec2 - rightPressPosition).length > 6.0'f32:
      return
    let
      player = options.playerSlot - 1
      picked = pickVillager(viewProjection)
    if picked >= 0 and picked != player:
      queueInvite(player, picked)
      clickMarks.emitClickMark(
        renderPoint(run.world.villagers[picked]))
      return
    let
      ground = pickGroundPoint(
        window.mousePos.vec2,
        window.size.vec2,
        viewProjection,
        cameraTarget.y
      )
      tile = groundTile(ground, HalfGrid, GridSide)
      garden = gardenAtTile(tile[0], tile[1])
      house = houseAtTile(tile[0], tile[1])
    if garden >= 0 and run.world.gardens[garden] >= 0:
      queueGather(player, garden)
    elif house >= 0:
      queueEnterHouse(player, house)
    else:
      queueMove(player, tile[0], tile[1])
    clickMarks.emitClickMark(tileWorldPoint(tile2(tile[0], tile[1])))

  proc cameraView(): Mat4 =
    ## Returns the shared fixed-north RTS view matrix.
    cameraEye = cameraTarget + vec3(
      0, sin(TownCameraPitch), cos(TownCameraPitch)
    ) * cameraDistance
    lookAt(cameraEye, cameraTarget, vec3(0, 1, 0))

  ## Frame

  var lastFrameTime = epochTime()
  const Step = 1.0'f32 / float32(TickRate)

  proc advanceRenderedGame() =
    ## Advances one tick, remembering poses for interpolation.
    captureVillagerPoses()
    advanceGame()
    captureCheckpoint()

  when defined(takeScreenshot):
    if existsEnv("HEARTLEAF_LAYER"):
      cameraDistance = 1402'f * 0.044'f / 2 / TownCameraScale
      cameraTarget = TownCameraTarget
    applyScreenshotCamera(cameraDistance)
    if existsEnv("CAM_X"):
      cameraTarget.x = getEnv("CAM_X").parseFloat.float32 - HalfGrid
    if existsEnv("CAM_Z"):
      cameraTarget.z = getEnv("CAM_Z").parseFloat.float32 - HalfGrid
    if existsEnv("SIM_SECONDS"):
      let wanted = int32(getEnv("SIM_SECONDS").parseFloat * TickRate.float64)
      while run.world.tick < wanted and
          run.world.tick < run.maximumTicks and not run.world.over:
        advanceGame()
    var screenshotFrame = 0

  holdSplash(sk, window, splash)
  window.onFrame = proc() =
    profileBlock "frame":
      let dt = frameDelta(lastFrameTime, Step)
      let recorded =
        if run.recorder != nil: int32(run.recorder.data.hashes.len)
        else: int32(run.replayPlayer.data.hashes.len)
      transport.sync(run.world.tick, recorded, run.world.over)
      let restoreTick = transport.takeRestore()
      if restoreTick >= 0:
        restoreTo(restoreTick)
        transport.sync(run.world.tick, recorded, run.world.over)
      transport.startScoreFrame(run.world, dt)
      let frameStart = epochTime()
      run.historyPlayback = transport.inHistory
      profileBlock "simulate":
        while transport.shouldScoreTick(frameStart):
          if atLiveTickCap(run.world.tick, run.maximumTicks, transport.live):
            break
          run.historyPlayback = transport.inHistory
          let previousPhase = run.world.phase
          advanceRenderedGame()
          let recordedNow =
            if run.recorder != nil: int32(run.recorder.data.hashes.len)
            else: int32(run.replayPlayer.data.hashes.len)
          transport.sync(run.world.tick, recordedNow, run.world.over)
          if transport.stopAtScoreBoundary(previousPhase, run.world):
            break
      scorePresentation.update(run.world, dt)
      sk.uiScale = hudUiScale(window)
      sk.mousePos = window.mousePos.vec2 / sk.uiScale
      let active = simulationActive(transport)
      frameAlpha =
        if active:
          clamp(transport.accumulator / Step, 0.0'f32, 1.0'f32)
        else:
          0.0'f32
      if active:
        clickMarks.advanceClickMarks(dt)
      profileBlock "camera":
        updateCamera(dt)
      let
        aspect = window.size.x.float32 / max(window.size.y.float32, 1)
        view = cameraView()
        extent = cameraDistance * TownCameraScale
        projection = ortho(
          -extent * aspect, extent * aspect,
          -extent, extent, 0.1'f, 1000'f
        )
        viewProjection = projection * view
      updateSelection(viewProjection)
      updatePlayerOrder(viewProjection)
      profileBlock "drawWorld":
        ## One clock for the whole frame: the palette, the sun's position,
        ## and its shadow map all follow the village hour, so the dinner
        ## bell rings at golden hour and the walk home is dusk.
        scene.setToonHour(simClockHour(frameAlpha),
          azimuthOffset = 135, elevationScale = 0.72'f)
        sunShadowBias = 0.00045'f
        sunShadowSoftness = 1.8'f
        setEnvironmentPalette(scene.toon)

        proc drawCrops(matrix: Mat4) =
          ## Stocked pots show their vegetable; harvested pots stay empty.
          for garden in 0 ..< GardenCount:
            let veggie = run.world.gardens[garden]
            if veggie < 0:
              continue
            villageArt.drawCrop(
              run.world.map.gardenTiles[garden], int(veggie), matrix
            )

        proc drawWorldVillagers() =
          for slot in 0 ..< VillagerCount:
            let v = run.world.villagers[slot]
            if v.inHouse >= 0:
              continue
            let
              model = villagerModels[slot]
              clip = villagerClips[slot][v.animation]
            var animTime = renderTime(v.animationTicks)
            ## Gesture clips must be clamped: the sampler wraps with `mod`,
            ## so a wave would otherwise loop forever.
            if v.animation in {GatherAnimation, WaveAnimation}:
              animTime = min(animTime, clipDuration(model, clip))
            drawCharacter(
              scene, model, renderPoint(v), renderFacing(v), clip, animTime)

        sunDepthPasses(window.size):
          drawTerrainSunDepth()
          scene.sunDepthPass = true
          when not defined(sceneCapture):
            if captureLayer == AllLayer:
              drawWorldVillagers()
          scene.sunDepthPass = false
        if captureLayer in {BuildingsLayer, VegetationLayer, PropsLayer}:
          glClearColor(0, 0, 0, 0)
        else:
          glClearColor(0.13, 0.19, 0.12, 1)
        glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
        drawTerrain(viewProjection, showTiles,
          drawGround = captureLayer in {AllLayer, GroundLayer})
        if captureLayer == AllLayer:
          when not defined(sceneCapture):
            drawCrops(viewProjection)
            beginCharacters(scene, window, view, projection, cameraEye)
            drawWorldVillagers()
            finishCharacters(scene)
            clickMarks.drawClickMarks(viewProjection)
        if showPaths:
          worldShapes.clear()
          for slot in 0 ..< VillagerCount:
            let v = run.world.villagers[slot]
            if v.inHouse >= 0:
              continue
            if v.pathIndex >= int32(v.path.len):
              continue
            var points: seq[Vec3]
            let now = renderPoint(v)
            points.add vec3(now.x, now.y + 0.2'f32, now.z)
            for i in int(v.pathIndex) ..< v.path.len:
              let p = tileWorldPoint(v.path[i])
              points.add vec3(p.x, p.y + 0.2'f32, p.z)
            if points.len >= 2:
              worldShapes.addPolyline(points, VillagerColors[slot])
          worldShapes.draw(viewProjection)
      when not defined(sceneCapture):
        profileBlock "ui":
          glDisable(GL_DEPTH_TEST)
          glDisable(GL_CULL_FACE)
          glDisable(GL_BLEND)
          when not defined(emscripten):
            glDisable(GL_MULTISAMPLE)
          glActiveTexture(GL_TEXTURE0)
          glBindTexture(GL_TEXTURE_2D, sk.atlasTextureId())
          sk.beginUi(window, window.size)

          ## World overlays drawn in HUD space: occupant portraits float over
          ## each occupied house, and gesture icons over busy villagers.
          for house in 0 ..< VillagerCount:
            var inside: seq[int32]
            for slot in 0 ..< VillagerCount:
              if run.world.villagers[slot].inHouse == int32(house):
                inside.add int32(slot)
            if inside.len == 0:
              continue
            let anchor = screenPosition(
              tileWorldPoint(run.world.map.houses[house].center) +
                vec3(0, 3.4'f32, 0),
              viewProjection
            ) / sk.uiScale
            let width = float32(inside.len) * 22 - 2
            sk.drawSlot(
              GameUiPanel(
                origin: anchor - vec2(width * 0.5'f32 + 4, 12),
                size: vec2(width + 8, 26)
              )
            )
            for index, slot in inside:
              sk.drawSprite(
                villagerPortraitKey(slot),
                anchor + vec2(
                  float32(index) * 22 - width * 0.5'f32, -9),
                vec2(20)
              )
          for slot in 0 ..< VillagerCount:
            let v = run.world.villagers[slot]
            if v.inHouse >= 0:
              continue
            if v.order != TalkOrder and v.animation notin {GatherAnimation, WaveAnimation}:
              continue
            let anchor = screenPosition(
              renderPoint(v) + vec3(0, VillagerHeight + 0.6'f32, 0),
              viewProjection
            ) / sk.uiScale
            sk.drawSprite(
              if v.animation == GatherAnimation: "gather" else: "wave",
              anchor - vec2(10, 10),
              vec2(20)
            )

          let speedClicked = drawUi(
            sk,
            window,
            transport,
            cameraTarget,
            cameraDistance,
            viewProjection,
            followSlot,
            actionCam,
            preserveFollowOnAuto = demoMode
          )
          if speedClicked:
            snapFollowCamera()
          sk.endUi()
      when defined(takeScreenshot):
        captureScreenshot(
          window,
          screenshotFrame,
          3,
          "heartleaf.png"
        )
      profileBlock "present":
        window.presentFrame(framePaceHz)
    if noteProfileFrame():
      when not defined(emscripten):
        window.closeRequested = true

  window.onButtonPress = proc(button: Button) =
    case button
    of KeySpace: transport.handleKey(button)
    of KeyC:
      var following = followSlot >= 0
      actionCam.toggle(following)
      if not following and not (demoMode and actionCam.enabled):
        followSlot = -1
    of KeyT: scene.toggleShading()
    of KeyF1, KeyF2:
      discard handleChromeKey(button)
    of KeyE:
      if playerMode():
        queueExitHouse(options.playerSlot - 1)
    of KeyQ:
      ## Accept the first standing invitation.
      if playerMode():
        let me = run.world.villagers[options.playerSlot - 1]
        for host in 0 ..< VillagerCount:
          if me.inviteFrom[host]:
            queueAccept(options.playerSlot - 1, int32(host))
            break
    of KeyEscape:
      when not defined(emscripten):
        window.closeRequested = true
    else: discard

  while not window.closeRequested:
    pollEvents()
  saveRecording()
  finishGameProfile()
