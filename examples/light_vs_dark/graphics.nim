## Light vs Dark spectator viewer.
##
## Reads the simulation and never writes it. The renderer interpolates body
## poses between ticks and samples terrain height for the vertical. None of
## that can flow back into `World`.
##
## Fog is presentation too. All three view modes read the same world; only
## what gets drawn changes.

import
  std/[math, os, strformat, strutils, tables, times, unicode],
  chroma, fixxy, opengl, pixie, vmath, windy, silky,
  polyworld/[actioncam, assets, characters, chargen, chrome, clickmarks, common,
    inputs, lighting, particles, particleshaders, pathing, player, profiles,
    quadterrain, rtscameras, selectionoutlines, shapes, shadows, tapes, toon,
    viewers, visions, worldbars, worldtexts],
  appearances, assets, buildings, content, factions, groves, symbols,
  sim, maps,
  game,
  replays,
  ui,
  controls

const
  DefaultCameraDistance = 17.0'f
  WindowTitle = "Light vs Dark"
  AtlasPath = TmpRoot & "/lvd.atlas.png"
  SeekCheckpointTicks = TickRate * 10
    ## One saved world every ten seconds, so a seek re-simulates at most
    ## that much.
  RebakeFrameGap = 30
    ## Batches nearby harvest and construction changes into one scene update.
  SelectionDragPixels = 6.0'f32
    ## Pointer travel that turns a click into a box select.

type
  GraphicsError = object of CatchableError
  SeekCheckpoint = object
    world: World
    actionIndex: int
    hashCheck: ReplayHashCheck
  SelectionTarget = object
    found: bool
    position: Vec3

var
  window*: Window
  sk*: Silky
  cameraDistance* = DefaultCameraDistance
  cameraTarget* = vec3(0, 0, 0)
  cameraEye = vec3(0, 0, 0)
  panning = false
  minimapPanning* = false
  viewMode* =
    if options.playerSlot > 0: options.playerSlot
    else: options.viewMode
  primaryId* = NoEntity
  selectedIds*: seq[int32]
  followSelection* = false
  selectionPressPosition = vec2(0)
  selectionStarted = false
  selectionAdditive = false
  groupCameraScale = 1.0'f32
  seekCheckpoints: seq[SeekCheckpoint]
  transport* = initPlayer(
    live = not run.replayMode,
    durationTicks = run.maximumTicks,
    playing = not options.pauseOnStart,
    speed = options.speed,
    repeating = true
  )
  placedEditCount = 0
  placedBuildingKey = ""
  sceneDirty = false
  edgesDirty = false
  framesSinceRebake = 0
  frameAlpha = 0.0'f32
  previousUnitPositions: Table[int32, Vec3]
  previousUnitFacings: Table[int32, float32]
  unitPoses: seq[CharacterPose]
  terrainVisionTick = int32.low
  terrainVisionMode = int32.low

## Presentation helpers

proc mapHalf(): float32 =
  ## Returns the map's world-space radius for drawing and camera bounds.
  run.world.map.side.float32 / 2

proc addHudIcons(builder: AtlasBuilder, factions: openArray[Faction]) =
  ## Packs grayscale unit symbols, building portraits, and the theme logo.
  builder.addThemeLogo(LogoPath)
  let badges = loadUnitSymbols()
  for kind in UnitKind:
    if not builder.addImage(unitSymbolKey(kind), badges[kind]):
      raise newException(
        GraphicsError,
        "The UI atlas is too small for unit symbols."
      )
  for player in 0'i32 ..< int32(min(run.world.players.len, FactionFiles.len)):
    for kind in BuildingKind:
      if kind == GoldMineBuilding and player != LightPlayer:
        continue
      if not builder.addImage(
          buildingPortraitKey(player, kind),
          readImage(buildingPortraitPath(factions[player], kind))
        ):
        raise newException(
          GraphicsError,
          "the UI atlas is too small for building portraits"
        )

proc tileCentreXZ(tile: Tile2): Vec2 =
  ## Converts a tile coordinate to the world-space centre of that tile.
  vec2(float32(tile.x) - mapHalf() + 0.5'f32,
       float32(tile.y) - mapHalf() + 0.5'f32)

proc unitWorldPoint(unit: Unit): Vec3 =
  ## Converts a tile-space body into a render position.
  let
    x = toFloat32(unit.body.pos.x) - mapHalf()
    z = toFloat32(unit.body.pos.y) - mapHalf()
  vec3(x, surfaceHeight(x, z), z)

proc unitYaw(unit: Unit): float32 =
  ## Turns body facing into the renderer's yaw convention.
  let dir = direction(unit.body.facing)
  arctan2(toFloat32(dir.x), toFloat32(dir.y))

proc renderPoint(unit: Unit): Vec3 =
  ## Interpolates one unit between the latest simulation snapshots.
  let current = unitWorldPoint(unit)
  if not interpolateVisuals:
    return current
  mix(
    previousUnitPositions.getOrDefault(unit.id, current),
    current,
    frameAlpha
  )

proc renderFacing(unit: Unit): float32 =
  ## Interpolates yaw the short way so a +pi / -pi flip is not a spin.
  if not interpolateVisuals:
    return unitYaw(unit)
  let
    current = unitYaw(unit)
    previous = previousUnitFacings.getOrDefault(unit.id, current)
  previous + shortestTurn(previous, current) * frameAlpha

proc captureUnitPoses() =
  ## Remembers mobile poses before one authoritative tick.
  previousUnitPositions.clear()
  previousUnitFacings.clear()
  for unit in run.world.units:
    previousUnitPositions[unit.id] = unitWorldPoint(unit)
    previousUnitFacings[unit.id] = unitYaw(unit)

proc renderTime(ticks: int32): float32 =
  ## Converts animation ticks into seconds for the clip sampler.
  (float32(ticks) + frameAlpha) / float32(TickRate)

proc buildingCentre(structure: Building): Vec3 =
  ## Returns the world centre of a structure's footprint.
  let
    x = structure.origin.x.float32 +
      structure.footprint.width.float32 * 0.5'f - mapHalf()
    z = structure.origin.y.float32 +
      structure.footprint.depth.float32 * 0.5'f - mapHalf()
  vec3(x, surfaceHeight(x, z), z)

proc isSelected*(id: int32): bool =
  ## Returns whether one entity belongs to the RTS selection set.
  for candidate in selectedIds:
    if candidate == id:
      return true

proc shownUnit*(unit: Unit): bool =
  ## Returns whether fog of war currently reveals this unit.
  if unit.state == UnitInMine:
    return false
  if viewMode == 0:
    return true
  run.world.unitVisible(viewMode - 1, unit)

proc shownBuilding*(structure: Building): bool =
  ## Returns whether fog of war currently reveals this structure.
  if viewMode == 0:
    return true
  run.world.buildingVisible(viewMode - 1, structure)

proc runGraphics*() =
  ## Runs the native or Emscripten spectator.
  startGameProfile()
  let order = factionOrder(run.mapSeed.int64)
  var playerFactions = newSeq[Faction](run.world.players.len)
  for player in 0 ..< run.world.players.len:
    playerFactions[player] = order[Faction(player mod FactionFiles.len)]
  profileBlock "atlas":
    let builder = newHudAtlas(4096)
    addHudIcons(builder, playerFactions)
    builder.addDefaultFonts()
    builder.addFont(DefaultFontPath, "WorldName", 32.0)
    builder.write(AtlasPath)
  profileBlock "window":
    (window, sk) = initGameWindow(
      WindowTitle,
      AtlasPath,
      gameWindowSize(options.windowWidth, options.windowHeight),
      options.vsync,
      msaa = msaa4x
    )
  if options.playerSlot > 0 and not run.replayMode:
    let player = options.playerSlot - 1
    for unit in run.world.units:
      if unit.owner == player and unit.state != UnitDying:
        selectedIds.add unit.id
        primaryId = unit.id
        followSelection = false
        break
  let splash = startSplash(sk, window)
  profileBlock "terrain":
    seed = run.mapSeed
    initTerrain(
      NoTrees, GeneratedTerrain, NoRocks, LvdTerrainTiles,
      settings = LvdTerrainAssets
    )
    setTileMaterial(
      RockTile.int,
      LvdRockSurface,
      LvdRockSurface,
      vec3(1),
      vec3(0.85),
      4
    )
    setTileMaterial(
      StoneTile.int,
      LvdStoneSurface,
      LvdRockSurface,
      vec3(1),
      vec3(0.85),
      6
    )

  ## Both players share the approved CharGen equipment and CC0 animations.
  var
    unitModels = newSeq[array[UnitKind, CharacterModel]](run.world.players.len)
    unitClips = newSeq[array[UnitKind, array[AnimationSlot, int]]](
      run.world.players.len
    )
    teamColors = newSeq[ColorRGBX](run.world.players.len)
    unitModelCache: UnitModelCache
  profileBlock "models":
    let
      manifest = readManifest(ChargenLibrary)
      roster = readCharacterRoster(playerFactions)
    for player in 0 ..< run.world.players.len:
      # The orange elemental's UI still identifies its owning faction.
      teamColors[player] = FactionColors[roster.factions[player]]
      if player >= FactionFiles.len:
        unitModels[player] = unitModels[player mod FactionFiles.len]
        unitClips[player] = unitClips[player mod FactionFiles.len]
        continue
      for kind in UnitKind:
        let model = unitModelCache.loadUnitModel(
          manifest, roster.players[player][kind.ord], kind
        )
        unitModels[player][kind] = model
        for slot in AnimationSlot:
          unitClips[player][kind][slot] = model.clipIndex(kind.unitClip(slot))
  drawSplash(sk, window, splash.name)

  let scene = newCharacterScene(window)
  scene.useToonShading()
  setEnvironmentPalette(scene.toon)
  var
    particles = initParticleSystem()
    clickMarks = initClickMarks()
    worldShapes = initShapeRenderer()
    worldBarRenderer = initWorldBarRenderer()
    playerLabels = layoutNames(
      sk.atlas.fonts["WorldName"],
      sk.atlas.size,
      run.config.players
    )
    damageTrails: DamageTrailTracker
    selectionOutline = initSelectionOutline()

  var
    grove: Grove
    buildingArt: BuildingArt
  let scenery = grovePlacements(
    run.world.treeWood, run.mapSeed, run.world.map.forestRocks
  )
  profileBlock "props":
    profileBlock "grove models":
      grove = generateGrove(run.mapSeed, {LightTree, LightRock})
    profileBlock "building models":
      buildingArt = loadBuildingArt(grove, factions = playerFactions)

  proc buildingKey(): string =
    ## Detects changes to displayed construction stages and building lifetimes.
    result = $run.world.terrainEdits.len
    for structure in run.world.buildings:
      result.add &"|{structure.id}:{structure.state.ord}"
      if structure.state == BuildingUnderConstruction:
        result.add &":{structure.constructionStage().ord}"

  proc placeSceneProps() {.measure.} =
    ## Submits desired placements while the renderer retains unchanged groups.
    clearProps()
    grove.plantGrove(scenery, run.world.treeWood)
    for structure in run.world.buildings:
      for part in buildingArt.buildingParts(
        structure, buildingCentre(structure)
      ):
        # Baked props use the opposite yaw to the standalone outline pass.
        part.pack.placeProp(
          part.name,
          part.position,
          -part.rotation,
          part.scale,
          group = structure.id
        )

  proc applyTerrainEdits(): bool {.measure.} =
    ## Reports actual ground changes, including trees restored by replay seeks.
    for placement in scenery:
      if placement.kind == LightTree:
        let kind =
          if placement.visible(run.world.treeWood):
            TreeTile
          else:
            GrassTile
        if layers[0].tiles[placement.tile].kind != kind:
          layers[0].tiles[placement.tile].kind = kind
          result = true

  proc rebakeScene(initial = false) =
    ## Refreshes changed props and rebuilds ground only for terrain edits.
    let groundChanged = applyTerrainEdits()
    placeSceneProps()
    if initial or groundChanged:
      # Rendering never recomputes authoritative movement walkability.
      bakeTerrain(
        rebuildWalkability = false,
        blockers = [run.world.blocker]
      )
      edgesDirty = false
    else:
      bakeProps()
      edgesDirty = true
    placedEditCount = run.world.terrainEdits.len
    placedBuildingKey = buildingKey()
    sceneDirty = false
    framesSinceRebake = 0

  profileBlock "bake":
    rebakeScene(initial = true)

  proc liveWalkable(layer, x, z: int): bool {.nimcall.} =
    ## Supplies current blockers when the optional movement grid is visible.
    layer == 0 and run.world.tileOpen(int32(x), int32(z))
  cameraTarget = vec3(0, 0, 0)
  var
    viewingDt = 0.0'f
    viewingSeeking = false
    actionCam = initActionCam(
      subjectMode = true,
      defaultDistance = DefaultCameraDistance,
      minDistance = 40,
      maxDistance = 240,
      tight = 0.4,
      followRate = 1.0,
      zoomRate = 0.7,
      holdSeconds = 2.8,
      mapSpan = mapHalf() * 2,
      closeScale = 0.5
    )

  ## Replay scaffolding

  seekCheckpoints.add SeekCheckpoint(
    world: run.world.clone(),
    actionIndex: 0,
    hashCheck: run.hashCheck
  )

  proc captureCheckpoint() =
    if run.world.tick div SeekCheckpointTicks < seekCheckpoints.len:
      return
    seekCheckpoints.add SeekCheckpoint(
      world: run.world.clone(),
      actionIndex: run.replayPlayer.actionIndex,
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
    previousUnitPositions.clear()
    previousUnitFacings.clear()
    sceneDirty = true
    particles.clearParticles()
    while run.world.tick < wanted:
      advanceGame()
      captureCheckpoint()

  ## Camera and input

  proc selectionTarget(id: int32): SelectionTarget =
    ## Returns the current render position of a selectable entity.
    if id.isUnitId and run.world.hasUnit(id):
      let unit = run.world.units[run.world.unitIndex(id)]
      if unit.state notin {UnitDying, UnitInMine}:
        return SelectionTarget(found: true, position: renderPoint(unit))
    elif id.isBuildingId and run.world.hasBuilding(id):
      let structure = run.world.buildings[run.world.buildingIndex(id)]
      if structure.state != BuildingDying:
        return SelectionTarget(
          found: true,
          position: buildingCentre(structure)
        )

  proc selectedCount(): int =
    ## Returns the number of valid selected entities.
    for id in selectedIds:
      if selectionTarget(id).found:
        inc result

  proc playerMode(): bool =
    ## Returns whether this client issues orders for one side.
    options.playerSlot > 0 and not run.replayMode

  if playerMode():
    actionCam.takeManual()

  proc selectEntity(id: int32, additive = false) =
    ## Selects or toggles one entity. Spectator mode follows the selection.
    if not selectionTarget(id).found:
      return
    if not additive:
      selectedIds.setLen(0)
    elif isSelected(id) and selectedIds.len > 1:
      for i in 0 ..< selectedIds.len:
        if selectedIds[i] == id:
          selectedIds.delete(i)
          break
      primaryId = selectedIds[0]
      if not playerMode():
        followSelection = true
      actionCam.takeManual()
      return
    if not isSelected(id):
      selectedIds.add id
    primaryId = id
    if not playerMode():
      followSelection = true
    actionCam.takeManual()
    if selectedIds.len > 1:
      groupCameraScale = 1.0'f32

  proc clearSelection() =
    ## Clears the selection and leaves the camera free-floating.
    let hadSelection =
      selectedIds.len > 0 or
      primaryId != NoEntity or
      followSelection
    selectedIds.setLen(0)
    primaryId = NoEntity
    followSelection = false
    if hadSelection:
      actionCam.takeManual()

  proc selectAllUnits() =
    ## Selects all living mobile units for group following.
    selectedIds.setLen(0)
    let owner =
      if options.playerSlot > 0 and not run.replayMode:
        options.playerSlot - 1
      else:
        -1'i32
    for unit in run.world.units:
      if unit.state notin {UnitDying, UnitInMine}:
        if owner >= 0 and unit.owner != owner:
          continue
        selectedIds.add unit.id
    if selectedIds.len > 0:
      primaryId = selectedIds[0]
      if not playerMode():
        followSelection = true
      actionCam.takeManual()
      groupCameraScale = 1.0'f32

  proc pruneSelection() =
    ## Removes entities that have died or left the selectable world.
    var i = selectedIds.high
    while i >= 0:
      if not selectionTarget(selectedIds[i]).found:
        selectedIds.delete(i)
      dec i
    if selectedIds.len == 0:
      primaryId = NoEntity
      followSelection = false
    elif not isSelected(primaryId):
      primaryId = selectedIds[0]

  proc selectedCenter(): Vec3 =
    ## Returns the midpoint of all valid selected entities.
    var count = 0
    for id in selectedIds:
      let target = selectionTarget(id)
      if target.found:
        result += target.position
        inc count
    if count > 0:
      result = result / count.float32

  proc selectedRadius(center: Vec3): float32 =
    ## Returns the largest planar distance from the selection midpoint.
    for id in selectedIds:
      let target = selectionTarget(id)
      if not target.found:
        continue
      let
        x = target.position.x - center.x
        z = target.position.z - center.z
      result = max(result, sqrt(x * x + z * z))

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

  proc addPlayerNames() =
    ## Labels each visible living town hall with its owner's name.
    for structure in run.world.buildings:
      if structure.kind != TownHallBuilding or structure.hp <= 0 or
        structure.owner < 0 or structure.owner >= run.config.players.len or
        not shownBuilding(structure):
          continue
      let anchor = buildingCentre(structure) +
        vec3(0, buildingArt.heights[TownHallBuilding] + 0.4'f, 0)
      worldBarRenderer.addText(
        playerLabels[structure.owner],
        anchor
      )

  proc pickEntity(viewProjection: Mat4): int32 =
    ## Finds the nearest visible unit or structure under the pointer.
    var bestDistance = 28.0'f32
    template consider(id: int32, position: Vec3, height: float32) =
      block:
        let distance = (
          screenPosition(position + vec3(0, height, 0), viewProjection) -
          window.mousePos.vec2
        ).length
        if distance < bestDistance:
          bestDistance = distance
          result = id
    for unit in run.world.units:
      if unit.state in {UnitDying, UnitInMine} or
          (viewMode != 0 and not run.world.unitVisible(viewMode - 1, unit)):
        continue
      consider(unit.id, renderPoint(unit), UnitHeights[unit.kind] * 0.5'f32)
    if result == NoEntity:
      let (origin, direction) = mouseRay(
        window.mousePos.vec2, window.size.vec2, viewProjection
      )
      var nearest = float32.high
      for structure in run.world.buildings:
        if structure.state == BuildingDying or not shownBuilding(structure):
          continue
        for part in buildingArt.buildingParts(
          structure, buildingCentre(structure)
        ):
          let distance = part.pack.pickProp(
            part.name, origin, direction, part.position,
            part.rotation, part.scale
          )
          if distance > 0 and distance < nearest:
            nearest = distance
            result = structure.id
      if result != NoEntity:
        return
    for structure in run.world.buildings:
      if structure.state == BuildingDying or
          (viewMode != 0 and
            not run.world.buildingVisible(viewMode - 1, structure)):
        continue
      consider(structure.id, buildingCentre(structure), 1.4'f32)
      for y in 0'i32 ..< structure.footprint.depth:
        for x in 0'i32 ..< structure.footprint.width:
          let
            tileX = int32(structure.origin.x) + x
            tileY = int32(structure.origin.y) + y
            world = tileCentreXZ(tile2(tileX, tileY))
          consider(
            structure.id,
            vec3(world.x, surfaceHeight(world.x, world.y), world.y),
            0.6'f32
          )

  proc structureAtTile(x, y: int32): int32 =
    ## Standing structure whose footprint contains this tile.
    result = NoEntity
    if not run.world.map.inGrid(x, y):
      return
    for structure in run.world.buildings:
      if structure.state == BuildingDying or
          not shownBuilding(structure):
        continue
      if covers(structure.origin, structure.footprint, x, y):
        return structure.id

  proc insideBox(point, origin, size: Vec2): bool =
    ## Returns whether a screen point lies inside a drag rectangle.
    point.x >= origin.x and
      point.y >= origin.y and
      point.x <= origin.x + size.x and
      point.y <= origin.y + size.y

  proc boxedUnits(viewProjection: Mat4): seq[int32] =
    ## Returns visible units whose screens fall inside the drag box.
    let
      press = selectionPressPosition
      current = window.mousePos.vec2
      origin = vec2(min(press.x, current.x), min(press.y, current.y))
      size = vec2(abs(current.x - press.x), abs(current.y - press.y))
      ownerFilter =
        if viewMode == 0: -1'i32
        else: viewMode - 1
    for unit in run.world.units:
      if unit.state in {UnitDying, UnitInMine}:
        continue
      if ownerFilter >= 0 and unit.owner != ownerFilter:
        continue
      if viewMode != 0 and
          not run.world.unitVisible(viewMode - 1, unit):
        continue
      let point = screenPosition(
        renderPoint(unit) +
          vec3(0, UnitHeights[unit.kind] * 0.5'f32, 0),
        viewProjection
      )
      if insideBox(point, origin, size):
        result.add unit.id

  proc selectBox(ids: seq[int32], additive: bool) =
    ## Replaces or extends the selection with boxed units.
    if ids.len == 0:
      if not additive:
        clearSelection()
      return
    if not additive:
      selectedIds.setLen(0)
    for id in ids:
      if not isSelected(id):
        selectedIds.add id
    primaryId = ids[0]
    if not playerMode():
      followSelection = true
    actionCam.takeManual()
    if selectedIds.len > 1:
      groupCameraScale = 1.0'f32

  proc feedLvdActions(observeTick = false) =
    ## Refreshes real subjects and observes every simulated tick.
    if not actionCam.enabled:
      return
    var subjects: seq[Subject]
    for unit in run.world.units:
      subjects.add Subject(
        id: unit.id, owner: unit.owner, position: renderPoint(unit),
        height: 0.9, radius: 1.5, visible: shownUnit(unit) and unit.state != UnitInMine,
        alive: unit.hp > 0 and unit.state != UnitDying,
        hp: unit.hp, maxHp: unitOf(unit.owner, unit.kind).hp,
        complete: true, participant: unit.targetId,
        fighting: unit.state == UnitAttacking, activity: unit.cooldown,
        progress: int32(unit.state), gold: unit.carryGold + unit.carryWood,
        idleScore: (if unit.state == UnitIdle: 8.0'f else: 22.0'f),
        combatScore: 90
      )
    for building in run.world.buildings:
      subjects.add Subject(
        id: building.id, owner: building.owner,
        position: buildingCentre(building), height: 2,
        radius: float32(max(building.footprint.width,
          building.footprint.depth)) * 0.7'f, visible: shownBuilding(building),
        alive: building.hp > 0 and building.state != BuildingDying,
        hp: building.hp, maxHp: building.maxHp,
        complete: building.state == BuildingComplete,
        progress: building.queueLength,
        idleScore: (if building.state == BuildingUnderConstruction: 24.0'f
          else: 4.0'f),
        combatScore: (if building.kind == TownHallBuilding: 165.0'f
          else: 105.0'f)
      )
    if observeTick and not viewingSeeking:
      actionCam.director.observe(subjects)
    actionCam.director.refresh(subjects)

  proc updateCamera(dt: float32) =
    ## Applies fixed-north RTS pan, zoom, and selection following.
    pruneSelection()
    updateMinimapCamera(
      window,
      sk.mousePos,
      cameraTarget,
      minimapPanning,
      followSelection
    )
    if minimapPanning:
      actionCam.takeManual()
    let overUi = mouseOverUi(window, sk.mousePos)
    if window.buttonPressed[KeyA] and
        (window.buttonDown[KeyLeftControl] or
          window.buttonDown[KeyRightControl]):
      selectAllUnits()
    elif window.mousePressed(MouseLeft) and not overUi:
      selectionPressPosition = window.mousePos.vec2
      selectionStarted = true
      selectionAdditive =
        window.buttonDown[KeyLeftShift] or
        window.buttonDown[KeyRightShift]
    if window.mousePressed(MouseMiddle) and
        (not overUi or window.buttonPressed[MouseMiddleKey]):
      panning = true
    if not window.mouseDown(MouseMiddle):
      panning = false
    let delta = window.mouseDelta.vec2
    if panning:
      followSelection = false
      actionCam.takeManual()
      let
        speed = cameraDistance * 0.0015
      cameraTarget.x -= delta.x * speed
      cameraTarget.z -= delta.y * speed
      cameraTarget.x = clamp(cameraTarget.x, -mapHalf(), mapHalf())
      cameraTarget.z = clamp(cameraTarget.z, -mapHalf(), mapHalf())
    if not minimapPanning and
        applyRtsPan(
          cameraTarget,
          rtsPanDir(window),
          dt,
          cameraDistance,
          mapHalf()
        ):
      followSelection = false
      actionCam.takeManual()
    if not overUi and window.scrollDelta.y != 0:
      actionCam.takeManual()
      if followSelection and selectedCount() > 1:
        groupCameraScale = clamp(
          groupCameraScale * pow(
            0.92'f32,
            window.scrollDelta.y / 3.0'f32
          ),
          0.75'f32,
          3.0'f32
        )
      else:
        cameraDistance = clamp(
          cameraDistance * pow(
            0.92'f32,
            window.scrollDelta.y / 3.0'f32
          ),
          8.0'f32,
          400.0'f32
        )
    if actionCam.enabled:
      return
    let count = selectedCount()
    if followSelection and count == 1:
      let focus = selectionTarget(selectedIds[0]).position
      cameraTarget = mix(
        cameraTarget,
        focus,
        damping(5.0'f32, dt)
      )
    elif followSelection and count > 1:
      let
        center = selectedCenter()
        distance = clamp(
          14.0'f32 + selectedRadius(center) * 2.8'f32,
          24.0'f32,
          400.0'f32
        ) * groupCameraScale
      cameraTarget = mix(
        cameraTarget,
        center,
        damping(4.0'f32, dt)
      )
      cameraDistance = mix(
        cameraDistance,
        distance,
        damping(2.0'f32, dt)
      )
    elif followSelection:
      clearSelection()

  proc updateWorldSelection(viewProjection: Mat4) =
    ## Applies click, shift-click, or box selection on left release.
    if not window.mouseReleased(MouseLeft):
      return
    if not selectionStarted:
      return
    let
      drag = (
        window.mousePos.vec2 - selectionPressPosition
      ).length
      overUi = mouseOverUi(window, sk.mousePos)
    if drag > SelectionDragPixels:
      selectBox(
        boxedUnits(viewProjection),
        selectionAdditive
      )
    elif not overUi:
      if not (playerMode() and pendingBuild >= 0):
        let picked = pickEntity(viewProjection)
        if picked != NoEntity:
          selectEntity(picked, selectionAdditive)
        elif not selectionAdditive:
          clearSelection()
    selectionStarted = false

  proc buildGhostOrigin(viewProjection: Mat4): (int32, int32) =
    ## Snaps the pending footprint so the cursor sits on its centre tile.
    let
      kind = BuildingKind(pendingBuild)
      size = BuildingTable[kind].footprint
      ground = pickGroundPoint(
        window.mousePos.vec2,
        window.size.vec2,
        viewProjection,
        cameraTarget.y
      )
      tile = groundTile(ground, mapHalf(), run.world.map.side)
    (tile[0] - size.width div 2, tile[1] - size.depth div 2)

  proc queuePendingBuild(x, y: int32) =
    ## Sends the first selected peon to raise the pending structure.
    let player = options.playerSlot - 1
    for id in selectedIds:
      if id.isUnitId and run.world.hasUnit(id):
        let unit = run.world.units[run.world.unitIndex(id)]
        if unit.owner == player and unit.kind == PeonUnit:
          queueBuild(player, id, pendingBuild, x, y)
          pendingBuild = -1
          return

  proc clickTilePoint(x, y: int32): Vec3 =
    ## Returns the render centre of one map tile.
    let xz = tileCentreXZ(tile2(x, y))
    vec3(xz.x, surfaceHeight(xz.x, xz.y), xz.y)

  proc issueSelectedMove(player, x, y: int32): bool =
    ## Moves every selected owned unit, or rallies a selected building.
    if not run.world.map.inGrid(x, y) or not run.world.terrainOpen(x, y):
      return false
    for id in selectedIds:
      if id.isUnitId and run.world.unitOwner(id) == player:
        if run.world.hasUnit(id):
          let unit = run.world.units[run.world.unitIndex(id)]
          if unit.state == UnitInMine:
            continue
        if attackMoveArmed:
          queueAttackMove(player, id, x, y)
        else:
          queueMove(player, id, x, y)
        result = true
    if not result:
      for id in selectedIds:
        if id.isBuildingId and run.world.buildingOwner(id) == player:
          queueSetRally(player, id, x, y)

  proc updatePlayerOrder(viewProjection: Mat4) =
    ## Turns a right-click into move, attack, harvest, or rally.
    if not playerMode():
      return
    if not window.mousePressed(MouseRight):
      return
    if mouseOverUi(window, sk.mousePos):
      return
    if pendingBuild >= 0:
      let origin = buildGhostOrigin(viewProjection)
      if run.world.canPlace(
          BuildingKind(pendingBuild),
          origin[0],
          origin[1]
      ):
        queuePendingBuild(origin[0], origin[1])
        clickMarks.emitClickMark(clickTilePoint(origin[0], origin[1]))
      return
    let
      player = options.playerSlot - 1
      picked = pickEntity(viewProjection)
      ground = pickGroundPoint(
        window.mousePos.vec2,
        window.size.vec2,
        viewProjection,
        cameraTarget.y
      )
      tile = groundTile(ground, mapHalf(), run.world.map.side)
      tree = run.world.map.tileIndex(tile[0], tile[1])
      under = structureAtTile(tile[0], tile[1])
      target =
        if under != NoEntity:
          under
        else:
          picked
    if target != NoEntity:
      if run.world.hasBuilding(target):
        let structure = run.world.buildings[run.world.buildingIndex(target)]
        if structure.kind == GoldMineBuilding:
          var harvested = false
          for id in selectedIds:
            if id.isUnitId and run.world.hasUnit(id):
              let unit = run.world.units[run.world.unitIndex(id)]
              if unit.owner == player and unit.kind == PeonUnit:
                queueHarvest(player, id, target, 0)
                harvested = true
          if harvested:
            clickMarks.emitClickMark(buildingCentre(structure))
          attackMoveArmed = false
          return
        if structure.owner != player:
          for id in selectedIds:
            if id.isUnitId and run.world.unitOwner(id) == player:
              queueAttack(player, id, target)
          attackMoveArmed = false
          return
      elif run.world.hasUnit(target) and
          run.world.unitOwner(target) != player:
        for id in selectedIds:
          if id.isUnitId and run.world.unitOwner(id) == player:
            queueAttack(player, id, target)
        attackMoveArmed = false
        return
    if run.world.treeWood[tree] > 0:
      var harvested = false
      for id in selectedIds:
        if id.isUnitId and run.world.hasUnit(id):
          let unit = run.world.units[run.world.unitIndex(id)]
          if unit.owner == player and unit.kind == PeonUnit:
            queueHarvest(player, id, tree, 1)
            harvested = true
      if harvested:
        clickMarks.emitClickMark(clickTilePoint(tile[0], tile[1]))
        attackMoveArmed = false
        return
    if issueSelectedMove(player, tile[0], tile[1]):
      clickMarks.emitClickMark(clickTilePoint(tile[0], tile[1]))
    attackMoveArmed = false

  proc cameraView(): Mat4 =
    ## Returns the shared fixed-north RTS view matrix.
    cameraEye = rtsCameraEye(cameraTarget, cameraDistance)
    lookAt(cameraEye, cameraTarget, vec3(0, 1, 0))

  proc drawBuildingOutline(
      structure: Building,
      viewProjection: Mat4
  ) =
    ## Draws one structure's props into the current selection mask.
    for part in buildingArt.buildingParts(
      structure, buildingCentre(structure)
    ):
      part.pack.drawProp(
        part.name,
        part.position,
        part.rotation,
        part.scale,
        viewProjection
      )

  proc drawSelectedOutline(
      view,
      projection,
      viewProjection: Mat4
  ) =
    ## Draws selected units and buildings into one yellow silhouette.
    var
      anyUnit = false
      anyBuilding = false
    for id in selectedIds:
      if id.isUnitId and run.world.hasUnit(id):
        let unit = run.world.units[run.world.unitIndex(id)]
        if shownUnit(unit) and unit.state != UnitDying:
          anyUnit = true
      elif id.isBuildingId and run.world.hasBuilding(id):
        let structure = run.world.buildings[run.world.buildingIndex(id)]
        if shownBuilding(structure) and
            structure.state != BuildingDying:
          anyBuilding = true
    if not anyUnit and not anyBuilding:
      return
    selectionOutline.beginMask(window.size)
    if anyUnit:
      beginCharacters(scene, window, view, projection, cameraEye)
      for id in selectedIds:
        if not id.isUnitId or not run.world.hasUnit(id):
          continue
        let unit = run.world.units[run.world.unitIndex(id)]
        if not shownUnit(unit) or unit.state == UnitDying:
          continue
        let
          model = unitModels[unit.owner][unit.kind]
          clip = unitClips[unit.owner][unit.kind][unit.animation]
        var animTime = renderTime(unit.animationTicks)
        if unit.animation == DeathAnimation or
            unit.animation == VictoryAnimation:
          animTime = min(animTime, clipDuration(model, clip))
        drawCharacter(
          scene,
          model,
          renderPoint(unit),
          renderFacing(unit),
          clip,
          animTime
        )
      finishCharacters(scene)
    if anyBuilding:
      for id in selectedIds:
        if not id.isBuildingId or not run.world.hasBuilding(id):
          continue
        let structure = run.world.buildings[run.world.buildingIndex(id)]
        if not shownBuilding(structure) or
            structure.state == BuildingDying:
          continue
        drawBuildingOutline(structure, viewProjection)
    selectionOutline.drawOutline()

  proc drawBuildGhost(viewProjection: Mat4) =
    ## Follows the pointer with a transparent building while placing.
    if not playerMode() or pendingBuild < 0:
      return
    let
      kind = BuildingKind(pendingBuild)
      size = BuildingTable[kind].footprint
      origin = buildGhostOrigin(viewProjection)
      valid = run.world.canPlace(kind, origin[0], origin[1])
      x = float32(origin[0]) + float32(size.width) * 0.5'f32 - mapHalf()
      z = float32(origin[1]) + float32(size.depth) * 0.5'f32 - mapHalf()
      centre = vec3(x, surfaceHeight(x, z), z)
      name = BuildingProps[kind]
      tint =
        if valid:
          vec4(0.55, 0.95, 0.65, 0.42)
        else:
          vec4(0.95, 0.28, 0.22, 0.42)
    buildingArt.buildingPack(options.playerSlot - 1).drawProp(
      name,
      centre,
      0.0'f32,
      BuildingScale,
      viewProjection,
      tint
    )

  proc updateTerrainVision() {.measure.} =
    ## Uploads the selected team's softened visible and explored terrain.
    if terrainVisionMode == viewMode and
      (viewMode == 0 or terrainVisionTick == run.world.tick):
        return
    terrainVisionTick = run.world.tick
    terrainVisionMode = viewMode
    var values = newSeq[uint8](run.world.map.side * run.world.map.side)
    if viewMode == 0:
      for value in values.mitems:
        value = 255
      uploadTerrainVisibility(values, int(run.world.map.side))
    else:
      let player = viewMode - 1
      for y in 0 ..< run.world.map.side:
        for x in 0 ..< run.world.map.side:
          let index = run.world.map.tileIndex(x, y)
          values[index] =
            if run.world.visible(player, x, y): 255
            elif run.world.explored(player, x, y): 48
            else: 0
      uploadTerrainVisibility(
        blurVisibility(values, run.world.map.side, run.world.map.side),
        int(run.world.map.side)
      )

  proc drawWorldBars(
      viewProjection: Mat4,
      cameraRight,
      cameraUp: Vec3,
      dt: float32
  ) =
    ## Always draws owner-colored health bars above visible living units.
    damageTrails.beginFrame()
    worldBarRenderer.clear()
    for unit in run.world.units:
      if not shownUnit(unit) or unit.state == UnitDying or unit.hp <= 0:
        continue
      let
        maximum = max(unitOf(unit.owner, unit.kind).hp, 1'i32).float32
        health = unit.hp.float32
        delayed = damageTrails.delayedValue(
          unit.id,
          health,
          maximum,
          dt
        )
        anchor = renderPoint(unit) +
          vec3(0, UnitHeights[unit.kind] + 0.32'f32, 0)
        width = 0.82'f32 + UnitHeights[unit.kind] * 0.18'f32
        bars = [WorldResourceBar(
          value: health,
          maximum: maximum,
          delayedValue: delayed,
          height: 0.1'f32,
          color: teamColors[unit.owner],
          showDamageTrail: true
        )]
      worldBarRenderer.addResourceBars(anchor, width, bars)
    damageTrails.finishFrame()
    addPlayerNames()
    worldBarRenderer.draw(
      viewProjection,
      cameraRight,
      cameraUp,
      sk.atlasTextureId()
    )

  proc particleTargetPosition(id: int32): tuple[
      found: bool,
      position: Vec3
  ] =
    ## Returns the visible presentation center of one combat target.
    if id.isUnitId:
      let index = run.world.unitIndex(id)
      if index >= 0 and shownUnit(run.world.units[index]):
        let unit = run.world.units[index]
        return (
          true,
          renderPoint(unit) +
            vec3(0, UnitHeights[unit.kind] * 0.55'f32, 0)
        )
    elif id.isBuildingId:
      let index = run.world.buildingIndex(id)
      if index >= 0 and shownBuilding(run.world.buildings[index]):
        return (
          true,
          buildingCentre(run.world.buildings[index]) + vec3(0, 0.8'f32, 0)
        )

  proc expectedTowerTargets(): Table[int32, int32] =
    ## Predicts this tick's tower choices from the pre-tick simulation state.
    let nextTick = run.world.tick + 1
    for structure in run.world.buildings:
      let stats = BuildingTable[structure.kind]
      if stats.damage <= 0 or structure.state != BuildingComplete or
          structure.cooldown > 0 or
          (nextTick + structure.id) mod TowerStagger != 0:
        continue
      var
        target = NoEntity
        best = int32.high
      for unit in run.world.units:
        if not run.world.atWar(structure.owner, unit.owner) or
            unit.state == UnitDying or
            unit.state == UnitInMine:
          continue
        var distance = int32.high
        for y in int32(structure.origin.y) ..<
            int32(structure.origin.y) + structure.footprint.depth:
          for x in int32(structure.origin.x) ..<
              int32(structure.origin.x) + structure.footprint.width:
            distance = min(
              distance,
              tileDistance(unit.tile, tile2(x, y))
            )
        if distance > stats.rangeTiles:
          continue
        if distance < best or
            (distance == best and unit.id < target):
          best = distance
          target = unit.id
      if target != NoEntity:
        result[structure.id] = target

  proc emitTickParticles(
      oldUnitCooldowns: Table[int32, int32],
      towerTargets: Table[int32, int32]
  ) =
    ## Emits each unit and tower attack exactly once after its simulation tick.
    for unit in run.world.units:
      if not shownUnit(unit) or unit.state != UnitAttacking:
        continue
      let stats = unitOf(unit.owner, unit.kind)
      if unit.cooldown != stats.cooldownTicks or
          oldUnitCooldowns.getOrDefault(unit.id, -1) == unit.cooldown:
        continue
      let target = particleTargetPosition(unit.targetId)
      if not target.found:
        continue
      let origin = renderPoint(unit) +
        vec3(0, UnitHeights[unit.kind] * 0.62'f32, 0)
      case unit.kind
      of ArcherUnit:
        particles.emitParticleProjectile(
          ArrowWake,
          CombatSparks,
          origin,
          target.position,
          clamp(
            (target.position - origin).length / 17.0'f32,
            0.08'f32,
            0.42'f32
          )
        )
      of MageUnit, ClericUnit:
        particles.emitParticleProjectile(
          MagicBolt,
          MagicBurst,
          origin,
          target.position,
          clamp(
            (target.position - origin).length / 12.0'f32,
            0.12'f32,
            0.5'f32
          )
        )
      of CatapultUnit, SummonUnit:
        particles.emitParticleProjectile(
          Fireball,
          FireBurst,
          origin,
          target.position,
          clamp(
            (target.position - origin).length / 13.0'f32,
            0.14'f32,
            0.52'f32
          )
        )
      of PeonUnit, SoldierUnit, KnightUnit:
        particles.emitParticleBurst(CombatSparks, target.position)
    for structure in run.world.buildings:
      if not shownBuilding(structure) or structure.id notin towerTargets:
        continue
      let stats = BuildingTable[structure.kind]
      if structure.cooldown != stats.cooldownTicks:
        continue
      let target = particleTargetPosition(towerTargets[structure.id])
      if not target.found:
        continue
      let origin = buildingCentre(structure) +
        vec3(0, buildingArt.heights[structure.kind] * 0.7'f32, 0)
      particles.emitParticleProjectile(
        Fireball,
        FireBurst,
        origin,
        target.position,
        clamp(
          (target.position - origin).length / 13.0'f32,
          0.14'f32,
          0.52'f32
        )
      )

  ## Frame

  var
    lastFrameTime = epochTime()
  const Step = 1.0'f32 / float32(TickRate)

  proc advanceRenderedMatch() =
    ## Advances one tick and converts its combat transitions into particles.
    var oldUnitCooldowns: Table[int32, int32]
    for unit in run.world.units:
      oldUnitCooldowns[unit.id] = unit.cooldown
    let towerTargets = expectedTowerTargets()
    captureUnitPoses()
    advanceGame()
    feedLvdActions(observeTick = true)
    emitTickParticles(oldUnitCooldowns, towerTargets)
    captureCheckpoint()

  when defined(takeScreenshot):
    applyScreenshotCamera(cameraDistance)
    if existsEnv("CAM_X"):
      cameraTarget.x = getEnv("CAM_X").parseFloat.float32 - mapHalf()
    if existsEnv("CAM_Z"):
      cameraTarget.z = getEnv("CAM_Z").parseFloat.float32 - mapHalf()
    if existsEnv("VIEW_MODE"):
      viewMode = int32(getEnv("VIEW_MODE").parseInt)
    if existsEnv("SHOW_TILES"):
      showTiles = getEnv("SHOW_TILES").parseBool
    if existsEnv("SIM_SECONDS"):
      let wanted = int32(getEnv("SIM_SECONDS").parseFloat * TickRate.float64)
      while run.world.tick < wanted and
          run.world.tick < run.maximumTicks and not run.world.over:
        advanceGame()
      sceneDirty = true
    if primaryId == NoEntity:
      for structure in run.world.buildings:
        if structure.owner == LightPlayer and
            structure.kind == TownHallBuilding and
            structure.state != BuildingDying:
          primaryId = structure.id
          break
      selectedIds.setLen(0)
      if primaryId != NoEntity:
        selectedIds.add primaryId
      for unit in run.world.units:
        if selectedIds.len >= 10:
          break
        if unit.owner == LightPlayer and
            unit.state notin {UnitDying, UnitInMine}:
          selectedIds.add unit.id
    var screenshotFrame = 0

  var
    viewingClock: ViewingClock
    cameraSeekSerial = -1

  holdSplash(sk, window, splash)
  window.onFrame = proc() =
    profileBlock "frame":
      let dt = frameDelta(lastFrameTime, Step)
      viewingDt = viewingClock.viewingDelta(window)
      viewingSeeking = transport.targetTick >= 0 or transport.restoreTick >= 0
      if not transport.playing or viewingSeeking:
        viewingDt = 0
      if cameraSeekSerial != transport.seekSerial:
        actionCam.resetDirector(transport.automaticSeek)
        cameraSeekSerial = transport.seekSerial
      sk.uiScale = gameUiScale(window)
      sk.mousePos = window.mousePos.vec2 / sk.uiScale
      profileBlock "camera":
        updateCamera(dt)
      let recorded =
        if run.recorder != nil: int32(run.recorder.data.hashes.len)
        else: int32(run.replayPlayer.data.hashes.len)
      transport.sync(run.world.tick, recorded, run.world.over)
      let restoreTick = transport.takeRestore()
      if restoreTick >= 0:
        restoreTo(restoreTick)
        transport.sync(run.world.tick, recorded, run.world.over)
      feedLvdActions(observeTick = true)
      transport.startFrame(dt, TickRate)
      let frameStart = epochTime()
      run.historyPlayback = transport.inHistory
      profileBlock "simulate":
        while transport.shouldTick(frameStart):
          if atLiveTickCap(run.world.tick, run.maximumTicks, transport.live):
            break
          run.historyPlayback = transport.inHistory
          advanceRenderedMatch()
          let recordedNow =
            if run.recorder != nil: int32(run.recorder.data.hashes.len)
            else: int32(run.replayPlayer.data.hashes.len)
          transport.sync(run.world.tick, recordedNow, run.world.over)
      let active = simulationActive(transport)
      frameAlpha =
        if active:
          clamp(transport.accumulator / Step, 0.0'f32, 1.0'f32)
        else:
          0.0'f32
      if active:
        particles.advanceParticles(dt)
        clickMarks.advanceClickMarks(dt)
      inc framesSinceRebake
      if run.world.terrainEdits.len != placedEditCount or
          buildingKey() != placedBuildingKey:
        sceneDirty = true
      if sceneDirty and
        (showTiles or framesSinceRebake >= RebakeFrameGap):
          profileBlock "rebake":
            rebakeScene()
      if showTiles and edgesDirty:
        updateTerrainEdges(liveWalkable)
        edgesDirty = false
      feedLvdActions()
      actionCam.direct(
        cameraTarget, cameraDistance, viewingDt,
        run.world.over or transport.tick >= transport.timelineEnd,
        transport.repeating,
        window.size.x.float32 / max(window.size.y.float32, 1),
        RtsFollowLift
      )
      let
        aspect = window.size.x.float32 / max(window.size.y.float32, 1)
        view = cameraView()
        projection = perspective(45.0'f32, aspect, 0.1'f32, 1000.0'f32)
        viewProjection = projection * view
        cameraForward = normalize(cameraTarget - cameraEye)
        barCameraRight = normalize(cross(cameraForward, vec3(0, 1, 0)))
        barCameraUp = normalize(cross(barCameraRight, cameraForward))
      updateWorldSelection(viewProjection)
      updatePlayerOrder(viewProjection)
      profileBlock "drawWorld":
        # Match GotA's short palette fades and fixed light direction.
        scene.toon.setArenaHour(
          clockHour(float32(run.world.tick) + frameAlpha, TickRate))
        setEnvironmentPalette(scene.toon)

        profileBlock "prepare unit poses":
          var count = 0
          for unit in run.world.units:
            if not shownUnit(unit):
              continue
            let
              model = unitModels[unit.owner][unit.kind]
              clip = unitClips[unit.owner][unit.kind][unit.animation]
            var animTime = renderTime(unit.animationTicks)
            # Hold one-shot clips at their final pose instead of looping.
            if unit.animation == DeathAnimation or
                unit.animation == VictoryAnimation:
              animTime = min(animTime, clipDuration(model, clip))
            if count == unitPoses.len:
              unitPoses.add CharacterPose()
            scene.prepareCharacter(
              unitPoses[count],
              model,
              renderPoint(unit),
              renderFacing(unit),
              clip,
              animTime
            )
            inc count
          unitPoses.setLen(count)

        proc drawWorldUnits() {.measure.} =
          ## Reuses each unit's pose for both shadow maps and the main view.
          for pose in unitPoses.mitems:
            scene.drawCharacter(pose)

        sunDepthPasses(window.size):
          drawTerrainSunDepth()
          scene.sunDepthPass = true
          drawWorldUnits()
          scene.sunDepthPass = false
        when not defined(emscripten):
          glEnable(GL_MULTISAMPLE)
        glClearColor(0.05, 0.06, 0.09, 1.0)
        glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
        scene.toon.drawBackground()
        updateTerrainVision()
        drawTerrain(viewProjection, showTiles)
        beginCharacters(scene, window, view, projection, cameraEye)
        drawWorldUnits()
        finishCharacters(scene)
        drawSelectedOutline(view, projection, viewProjection)
        drawBuildGhost(viewProjection)
        drawWater(
          viewProjection,
          cameraEye,
          opacity = 0.5'f,
          highlightOpacity = 0.0'f
        )
        particles.drawParticles(
          viewProjection,
          barCameraRight,
          barCameraUp,
          cameraForward
        )
        clickMarks.drawClickMarks(viewProjection)
        if showPaths:
          worldShapes.clear()
          for unit in run.world.units:
            if unit.id == 0 or unit.state == UnitDying:
              continue
            if unit.pathIndex >= int32(unit.path.len):
              continue
            let color = teamColors[unit.owner]
            var points: seq[Vec3]
            let now = renderPoint(unit)
            points.add vec3(now.x, now.y + 0.2'f32, now.z)
            for i in int(unit.pathIndex) ..< unit.path.len:
              let tile = unit.path[i]
              let xz = tileCentreXZ(tile)
              points.add vec3(
                xz.x,
                surfaceHeight(xz.x, xz.y) + 0.2'f32,
                xz.y
              )
            if points.len >= 2:
              worldShapes.addPolyline(points, color)
          worldShapes.draw(viewProjection)
        drawWorldBars(
          viewProjection,
          barCameraRight,
          barCameraUp,
          dt
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
          viewMode,
          primaryId,
          selectedIds,
          followSelection,
          actionCam,
          teamColors
        )
        drawSelectionBox(
          sk,
          window,
          selectionPressPosition,
          selectionStarted
        )
        sk.endUi()
        drawStatsOverlay(sk, window, teamColors)
      when defined(takeScreenshot):
        captureScreenshot(
          window,
          screenshotFrame,
          3,
          "light_vs_dark.png"
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

  window.onButtonPress = proc(button: Button) =
    case button
    of KeySpace: transport.handleKey(button)
    of KeyC: actionCam.toggle(followSelection)
    of KeyT: scene.toggleShading()
    of KeyE: showTiles = not showTiles
    of KeyF1, KeyF2:
      discard handleChromeKey(button)
    of KeyV:
      if not playerMode():
        viewMode = (viewMode + 1) mod int32(run.world.players.len + 1)
    of KeyX:
      if playerMode():
        let player = options.playerSlot - 1
        for id in selectedIds:
          if run.world.unitOwner(id) == player or
              run.world.buildingOwner(id) == player:
            queueCancel(player, id)
        pendingBuild = -1
        attackMoveArmed = false
    of KeyEscape:
      if playerMode() and pendingBuild >= 0:
        pendingBuild = -1
      else:
        when not defined(emscripten):
          window.closeRequested = true
    else: discard

  while not window.closeRequested:
    pollEvents()
    waitForDisplay()
  saveRecording()
  clickMarks.closeClickMarks()
  worldShapes.closeShapeRenderer()
  worldBarRenderer.closeWorldBarRenderer()
  selectionOutline.closeSelectionOutline()
  particles.closeParticles()
  finishGameProfile()
