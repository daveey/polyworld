## Window, terrain rendering, characters, camera, and HUD for the arena.

import
  std/[math, tables, times],
  bumpy, chroma, opengl, pixie, silky, vmath,
  assets, brushes, content, groves, landscapes, sim, game, maps, replays, ui, walls,
  cameras, controls, faces, lighting, spelleffects,
  polyworld/actioncam, polyworld/assets, polyworld/characters,
  polyworld/clickmarks,
  polyworld/chargen, polyworld/common, polyworld/pathing,
  polyworld/tapes, polyworld/toon,
  polyworld/particles, polyworld/particleshaders, polyworld/player,
  polyworld/profiles,
  polyworld/quadterrain,
  polyworld/shadows,
  polyworld/terrainsurfaces,
  polyworld/[chrome, inputs, rtscameras, selectionoutlines, shapes, viewers,
    visions, worldbars, worldtexts]

when defined(takeScreenshot):
  import std/[os, strutils]

const
  DefaultCameraDistance = 17.0'f / 1.2'f
  AtlasPath = TmpRoot & "/gota.atlas.png"
  MossyStoneSurface = SurfaceNames.len
  CourtyardSurface = MossyStoneSurface + 1
  CryptRockSurface = SurfaceNames.len + FortTextures.len
  CryptRubbleSurface = CryptRockSurface + 1
  CryptFortSurface = CryptRockSurface + 2
  CryptRoadSurface = CryptRockSurface + 3
  CryptSpawnSurface = CryptRockSurface + 4

type
  GraphicsError = object of CatchableError
  GodAnimation = enum
    GodIdle, GodDeath, GodVictory

proc renderPoint(position: WorldPoint): Vec3 =
  ## Converts authoritative integer coordinates at the rendering boundary.
  result = vec3(
    position.x.float32 / WorldScale.float32,
    position.y.float32 / WorldScale.float32,
    position.z.float32 / WorldScale.float32
  )
  result.y += groundOffset(result.x, result.z)

proc renderFacing(value: Heading): float32 =
  ## Converts an integer heading to the renderer's angular convention.
  arctan2(value.x.float32, value.z.float32)

proc addAbilityIcons(builder: AtlasBuilder) =
  ## Packs every hero ability art file used by the action bar.
  const AbilityDir = DataRoot & "/abilities/"
  var packed: set[Ability]
  for class in HeroClass:
    for slot in HeroAbilitySlot:
      let ability = heroAbility(class, slot)
      if ability in packed:
        continue
      packed.incl ability
      let icon = readImage(
        AbilityDir & ability.abilitySpec.icon & ".png"
      ).resize(128, 128)
      if not builder.addImage(abilityIconKey(ability), icon):
        raise newException(
          GraphicsError,
          "the UI atlas is too small for ability icons"
        )

proc addItemIcons(builder: AtlasBuilder) =
  ## Packs every shop item art file used by the inventory.
  const ItemDir = DataRoot & "/items/"
  for item in Item:
    if item == NoItem:
      continue
    let icon = readImage(
      ItemDir & item.itemSpec.icon & ".png"
    ).resize(128, 128)
    if not builder.addImage(itemIconKey(item), icon):
      raise newException(
        GraphicsError,
        "the UI atlas is too small for item icons"
      )

proc addHudIcons(builder: AtlasBuilder) =
  ## Packs the theme logo into the atlas.
  builder.addThemeLogo(LogoPath)

var
  window: Window
  sk: Silky

proc runGraphics*() =
  ## Runs the native or Emscripten graphical spectator.
  startGameProfile()
  profileBlock "atlas":
    let builder = newHudAtlas(4096)
    for class in HeroClass:
      let
        portrait = readImage(HeroPortraitPaths[class])
        drafted = portrait.copy()
      for pixel in drafted.data.mitems:
        let gray = uint8((pixel.r.int * 54 + pixel.g.int * 183 +
          pixel.b.int * 19) shr 8)
        pixel.r = gray
        pixel.g = gray
        pixel.b = gray
      if not builder.addImage(HeroPortraitKeys[class], portrait) or
        not builder.addImage(class.draftedPortraitKey(), drafted):
          raise newException(
            GraphicsError,
            "the UI atlas is too small for hero portraits"
          )
    addHudIcons(builder)
    addAbilityIcons(builder)
    addItemIcons(builder)
    builder.addDefaultFonts()
    builder.addFont(DefaultFontPath, "HeroVersus", 24.0)
    builder.addFont(DefaultFontPath, "WorldName", 32.0)
    builder.write(AtlasPath)
  profileBlock "window":
    (window, sk) = initGameWindow(
      "Gods of the Arena",
      AtlasPath,
      gameWindowSize(options.windowWidth, options.windowHeight),
      options.vsync,
      msaa = msaa4x
    )
  let splash = startSplash(sk, window)
  profileBlock "terrain":
    amplitude = 2.8'f
    seed = ArenaSeed
    initTerrain(
      GotaTreeStyle, GeneratedTerrain, NoRocks, ArenaTextures,
      settings = GotaTerrainAssets
    )
    terrainUnboostedMaterial = CourtyardSurface.float32
    let landscape = buildLandscape(
      layers[GroundLayer],
      run.map.mainRoads,
      run.map.preset.seed,
      CryptRoadSurface,
      CryptRoadSurface
    )
    groundRelief = landscape.relief
    groundMaterialOverrides = landscape.materials
    # Blend road materials at sub-tile resolution without changing pathing.
    setTileMaterial(
      RoadTile.int,
      GrassSurface.float32,
      DirtSurface.float32,
      vec3(1),
      vec3(0.78'f32, 0.74'f32, 0.62'f32),
      1
    )
    for i, kind in ArenaWallKinds:
      let material =
        if i == 0:
          CryptRockSurface.float32
        else:
          GrassSurface.float32
      setTileMaterial(
        kind.int,
        material,
        material,
        vec3(1),
        vec3(0.8'f),
        2
      )
    terrainBlendDepth = 0.65'f
    terrainHeightBlend = 1.0'f
    for side in 0 .. 1:
      let surfaces = [
        [GrassSurface, OliveSurface, CourtyardSurface, CourtyardSurface,
          MossyStoneSurface, DirtSurface, DirtSurface, GravelSurface],
        [CryptRockSurface, CryptRubbleSurface, CryptFortSurface,
          CryptFortSurface, CryptSpawnSurface, CryptRoadSurface,
          CryptRoadSurface, CryptRoadSurface]
      ]
      for i, surface in surfaces[side]:
        setTileMaterial(
          int(ArenaKindBase) + side * int(ArenaKindStride) + i,
          surface.float32,
          (if side == 0: GravelSurface else: CryptRockSurface).float32,
          vec3(1),
          vec3(0.8'f),
          (if i >= 5: 5'i32 else: 2'i32)
        )
    setTileMaterial(
      ArenaRockKind.int,
      CryptRockSurface.float32,
      CryptRockSurface.float32,
      vec3(1),
      vec3(0.8'f),
      2
    )
  let scene = newCharacterScene(window)
  scene.useToonShading()
  var
    neutralModels: array[6, CharacterModel]
    neutralClips: array[6, array[6, int]]
    neutralEyes: array[6, DeathEyes]
    footmanModels: array[Team, array[CreepKind, CharacterModel]]
    footmanRenderClips: array[Team, array[CreepKind, array[6, int]]]
    godModels: array[Team, CharacterModel]
    godRenderClips: array[Team, array[GodAnimation, int]]
    heroModels: array[HeroClass, CharacterModel]
    heroRenderClips: array[HeroClass, array[5, int]]
    heroCastClips: array[HeroClass, int]
    heroPortalClips: array[HeroClass, int]
    footmanEyes: array[Team, array[CreepKind, DeathEyes]]
    godEyes: array[Team, DeathEyes]
    heroEyes: array[HeroClass, DeathEyes]
  profileBlock "models":
    let
      characterLibrary = readManifest(ChargenLibrary)
      deadEyes = characterLibrary.deathEyesPart()

    proc loadPresetModel(
      preset: Preset,
      clips: openArray[string],
      height: float32,
      eyes: var DeathEyes
    ): CharacterModel =
      ## Loads one generated character with its authored face materials.
      let inventory = characterLibrary.presetManifest(preset)
      result = loadCharacterModel(
        readPresetCharacter(ChargenLibrary, characterLibrary, preset, clips),
        height
      )
      for category in inventory.categories:
        if category.key in ["Eyes", "Mouth", "Brow"]:
          for item in category.items:
            result.unlitParts.add item.nodes
      eyes = initDeathEyes(result, ChargenLibrary, inventory, deadEyes)

    for i, recipe in neutralRecipes():
      let
        model = loadPresetModel(
          recipe.preset, CreepClips, NeutralTargetHeight, neutralEyes[i])
        rgb = recipe.skinRgb
      model.fitCharacterHeight(NeutralTargetHeight, model.clipIndex("Sword_Idle"))
      partNodes(model.file.root).applySkin(
        characterLibrary.presetManifest(recipe.preset),
        color(rgb[0], rgb[1], rgb[2], 1))
      neutralModels[i] = model
      for clip, name in MeleeCreep.creepAnimationNames():
        neutralClips[i][clip] = model.clipIndex(name)
    for team in Team:
      for kind in CreepKind:
        let model = loadPresetModel(
          characterLibrary.creepPreset(team.ord, kind),
          CreepClips,
          CreepTargetHeight,
          footmanEyes[team][kind]
        )
        footmanModels[team][kind] = model
        for i, name in kind.creepAnimationNames():
          footmanRenderClips[team][kind][i] = model.clipIndex(name)
      let god = loadPresetModel(
        characterLibrary.namedPreset(GodPresets[ord(team)]),
        GodClips,
        GodTargetHeight,
        godEyes[team]
      )
      god.fitCharacterHeight(GodTargetHeight, god.clipIndex("Idle_Loop"))
      godModels[team] = god
      godRenderClips[team] = [
        god.clipIndex("Idle_Loop"),
        god.clipIndex("Death01"),
        god.clipIndex("Dance_Loop")
      ]
    for class in HeroClass:
      let model = loadPresetModel(
        characterLibrary.namedPreset(HeroPresets[class]),
        HeroClips,
        HeroTargetHeight,
        heroEyes[class]
      )
      model.fitCharacterHeight(HeroTargetHeight, model.clipIndex("Idle_Loop"))
      heroModels[class] = model
      for i, name in class.heroAnimationNames():
        heroRenderClips[class][i] = model.clipIndex(name)
      heroCastClips[class] = model.clipIndex("Spell_Simple_Shoot")
      heroPortalClips[class] = model.clipIndex("Spell_Simple_Idle_Loop")
  var
    particles = initParticleSystem()
    spellEffects = initSpellRenderer()
    clickMarks = initClickMarks()
    worldShapes = initShapeRenderer()
    waypointShapes = initShapeRenderer()
    waypointText = initWorldBarRenderer()
    waypointLabels: seq[WorldText]
    selectionOutline = initSelectionOutline()
    occlusionOutline = initSelectionOutline(OccludedOutline)
    showOccludedCharacters = true
    worldBarRenderer = initWorldBarRenderer()
    playerLabels = layoutNames(
      sk.atlas.fonts["WorldName"],
      sk.atlas.size,
      run.config.players
    )
    portalLabels = [
      layoutText(sk.atlas.fonts["WorldName"], sk.atlas.size, "Teleporting 1s"),
      layoutText(sk.atlas.fonts["WorldName"], sk.atlas.size, "Teleporting 2s"),
      layoutText(sk.atlas.fonts["WorldName"], sk.atlas.size, "Teleporting 3s")
    ]
    damageTrails: DamageTrailTracker

  const
    SmallTowerScale = 3.5'f
    TallTowerScale = 4.5'f
    GateTowerScale = 6.0'f
    BarracksScale = 1.65'f

  proc towerPropName(tier: TowerTier): string =
    ## Returns the matching fort model for one tower tier.
    case tier
    of OuterTower:
      "tower_level1"
    of InnerTower:
      "tower_level2"
    of GateTower:
      "tower_level3"

  proc towerScale(tier: TowerTier): float32 =
    ## Returns the world scale for one tower tier.
    case tier
    of OuterTower:
      SmallTowerScale
    of InnerTower:
      TallTowerScale
    of GateTower:
      GateTowerScale

  proc buildingPropName(building: Building): string =
    ## Selects the living structure model from its simulation kind.
    if building.kind == BarracksBuilding: "barracks"
    else: towerPropName(building.tier)

  proc buildingScale(building: Building): float32 =
    ## Uses the same structure height for drawing, picking, and health bars.
    if building.kind == BarracksBuilding: BarracksScale
    else: towerScale(building.tier)

  proc wallHeight(placement: WallPlacement, width: float32): float32 =
    ## Embeds an upright wall model at the lowest ground under its footprint.
    let
      direction = vec2(cos(placement.rotation), sin(placement.rotation))
      across = vec2(-direction.y, direction.x)
      length =
        if placement.part == WallPanel: placement.length
        else: width
      steps = max(1, ceil(length / 0.25'f).int)
      edge = mapHalfSize() - 0.001'f
    result = float32.high
    for i in 0 .. steps:
      for j in -1 .. 1:
        let point = clamp(
          placement.position +
            direction * (length * (i.float32 / steps.float32 - 0.5'f)) +
            across * (width / 2 * j.float32),
          vec2(-edge),
          vec2(edge)
        )
        result = min(result,
          groundHeight(point.x, point.y) + groundOffset(point.x, point.y))
    result -= 0.05'f

  proc placeStaticStructures(packs: array[Team, PropPack]) =
    ## Places joined wall models on natural ground.
    for placement in buildWalls(run.map.layout.walls):
      let
        pack = packs[Team(placement.team)]
        name = if placement.part == WallPillar: "pillar" else: "wall"
        size = pack.propSize(name)
        modelScale =
          if placement.part == WallPillar:
            WallPillarWidth / size.x
          else:
            WallSectionLength / size.x
        stretch =
          if placement.part == WallPanel:
            vec3(placement.length / WallSectionLength, 1, 1)
          else:
            vec3(1)
      pack.placeProp(
        name,
        vec3(
          placement.position.x,
          wallHeight(placement, size.z * modelScale),
          placement.position.y
        ),
        placement.rotation,
        modelScale,
        stretch = stretch
      )
  var
    towerPacks: array[Team, PropPack]
    grove: Grove
  let brush = mixBrush(layers[GroundLayer], run.map.preset.seed)
  profileBlock "props":
    for team in Team:
      towerPacks[team] = loadPropPack(
        fortModelPaths(team.ord),
        textured = true,
        textureSize = FortTextureSize,
        mergeNodes = true
      )
      for name in FortModelNames:
        doAssert towerPacks[team].hasProp(name), "Missing fort model: " & name
    towerPacks.placeStaticStructures()
    grove = generateGrove(run.map.preset.seed)
    grove.plantGrove(brush, run.map.preset.seed)
  profileBlock "bake":
    bakeTerrain(rebuildWalkability = false)
    for i, color in run.map.minimap.mpairs:
      var tint = terrainTileColor(GroundLayer, i) * 1.25'f
      if layers[WaterLayer].tiles[i].exists:
        tint = vec3(69, 135, 161) / 255'f
      elif grove.colors[i] != vec3(0):
        tint = grove.colors[i]
      color = uint32(clamp(tint.x * 255, 0'f, 255'f)) shl 16 or
        uint32(clamp(tint.y * 255, 0'f, 255'f)) shl 8 or
        uint32(clamp(tint.z * 255, 0'f, 255'f))
  drawSplash(sk, window, splash.name)

  type God = object
    team: Team
    position: Vec3
    facing: float32
    animTime: float32

  var gods = [God(team: RedTeam), God(team: BlueTeam)]
  for i, god in gods.mpairs:
    god.position = renderPoint(run.world.forts[i].center)
    god.facing = arctan2(-god.position.x, -god.position.z)

  proc godClip(god: God): GodAnimation =
    ## Selects the god animation for the current game state.
    if not run.world.gameOver:
      GodIdle
    elif not run.world.draw and god.team == run.world.winner:
      GodVictory
    else:
      GodDeath

  proc heroSizeFactor(hero: Hero): float32 =
    ## Returns the small visual scale increase earned through hero levels.
    1.0'f32 + min(hero.level - 1, 10).float32 * 0.025'f32

  const
    SeekCheckpointTicks = TickRate * 10
    HeroWorldBarScale = 0.75'f
    HeroWorldBarWidth = 1.75'f * HeroWorldBarScale
    TowerWorldBarWidth = 2.4'f32
    FootmanWorldBarWidth = 0.95'f32

  type
    SeekCheckpoint = object
      tick: int
      world: World
      replayActionIndex: int
      hashCheck: ReplayHashCheck

    SelectionTarget = object
      found: bool
      position: Vec3
      focusHeight: float32

  var
    replayCheckpoints: seq[SeekCheckpoint]
    previousUnitPositions: Table[int32, Vec3]
    previousUnitFacings: Table[int32, float32]
    renderAlpha = 1.0'f32
    animationAlpha = 0.0'f32
    viewMode =
      if options.playerSlot > 0:
        int32(run.world.heroes[options.playerSlot - 1].team.ord) + 1
      else:
        0'i32
    terrainVisionTick = int32.low
    terrainVisionMode = int32.low
    terrainEdgeWorld: World
    terrainEdgeRevision = -1'i32

  proc captureUnitPositions() =
    ## Remembers all mobile poses before one authoritative tick.
    previousUnitPositions.clear()
    previousUnitFacings.clear()
    for hero in run.world.heroes:
      previousUnitPositions[hero.id] = renderPoint(hero.position)
      previousUnitFacings[hero.id] = renderFacing(hero.facing)
    for footman in run.world.footmen:
      previousUnitPositions[footman.id] = renderPoint(footman.position)
      previousUnitFacings[footman.id] = renderFacing(footman.facing)

  proc unitRenderPoint(id: int32, position: WorldPoint): Vec3 =
    ## Interpolates one mobile unit between the latest simulation snapshots.
    let current = renderPoint(position)
    if not interpolateVisuals:
      return current
    mix(
      previousUnitPositions.getOrDefault(id, current),
      current,
      renderAlpha
    )

  proc unitRenderFacing(id: int32, facing: Heading): float32 =
    ## Interpolates yaw the short way so a +pi / -pi flip is not a spin.
    if not interpolateVisuals:
      return renderFacing(facing)
    let
      current = renderFacing(facing)
      previous = previousUnitFacings.getOrDefault(id, current)
    previous + shortestTurn(previous, current) * renderAlpha

  proc unitRenderTime(ticks: int32): float32 =
    ## Samples authoritative animation state continuously between ticks.
    (ticks.float32 + animationAlpha) / TickRate.float32

  proc heroRenderPose(hero: Hero): tuple[clip: int, time: float32] =
    ## Shares one pose across rendering, shadows, picking, and outlines.
    let model = heroModels[hero.class]
    result.clip = heroRenderClips[hero.class][hero.animClip]
    let duration = model.clipDuration(result.clip)
    if hero.state == Dying:
      result.time = min(hero.animTicks.float32 / HeroDeathTicks.float32, 1) *
        duration
      return
    if hero.portalEnds > run.world.tick:
      result.clip = heroPortalClips[hero.class]
      result.time = unitRenderTime(hero.animTicks)
      return
    for spell in run.world.casts:
      let age = run.world.tick - spell.started
      if spell.heroId == hero.id and age >= 0 and age < 12:
        result.clip = heroCastClips[hero.class]
        result.time = min((age.float32 + animationAlpha) / 12, 1) *
          model.clipDuration(result.clip)
        return
    if hero.animClip in heroAttackClips:
      let
        strike = hero.class.heroStrikeTime()
        tick = hero.animTicks.float32 + animationAlpha
        hit = run.world.heroHitTicks(hero).float32
        finish = run.world.heroAttackTicks(hero).float32
      result.time =
        if tick <= hit:
          tick / hit * strike
        else:
          strike + min((tick - hit) / (finish - hit), 1) * (duration - strike)
    else:
      result.time = unitRenderTime(hero.animTicks)

  proc creepModel(unit: Footman): CharacterModel =
    ## Uses one shared chargen model per camp appearance or team creep.
    if unit.camp > 0:
      neutralModels[unit.appearance]
    else:
      footmanModels[unit.team][unit.kind]

  proc creepClip(unit: Footman): int =
    ## Maps the shared simulation animation slots to the correct model.
    if unit.camp > 0:
      neutralClips[unit.appearance][unit.animClip]
    else:
      footmanRenderClips[unit.team][unit.kind][unit.animClip]

  proc creepSize(unit: Footman): float32 =
    ## Makes the leader visibly larger without duplicating model assets.
    if unit.leader:
      1.35'f
    else:
      1'f

  proc creepEyes(unit: Footman, dead: bool) =
    ## Switches every mob's face for living and corpse draws.
    if unit.camp > 0:
      neutralEyes[unit.appearance].setDead(dead)
    else:
      footmanEyes[unit.team][unit.kind].setDead(dead)

  proc creepRenderTime(footman: Footman): float32 =
    ## Fits authored attack impacts and death poses to simulation timing.
    let
      model = creepModel(footman)
      clip = creepClip(footman)
      duration = model.clipDuration(clip)
    if footman.state == Dying:
      return min(footman.deathTicks.float32 / FootmanDeathTicks.float32, 1) *
        duration
    if footman.animClip in attackClips:
      let
        strike = footman.kind.creepStrikeTime()
        tick = footman.animTicks.float32 + animationAlpha
        hit = footmanHitTicks(footman.animClip).float32
        finish = footmanAttackTicks(footman.animClip).float32
      if tick <= hit:
        return tick / hit * strike
      return strike + min((tick - hit) / (finish - hit), 1) *
        (duration - strike)
    unitRenderTime(footman.animTicks)

  proc visibleInView(team: Team, position: WorldPoint): bool =
    ## Applies the current omniscient or team visibility spectator mode.
    if viewMode == 0:
      return true
    let viewingTeam = Team(viewMode - 1)
    team == viewingTeam or visible(run.world, viewingTeam, position)

  proc visibleInView(unit: Footman): bool =
    ## Neutral units are only visible through the selected team's actual LOS.
    if unit.camp == 0:
      return visibleInView(unit.team, unit.position)
    viewMode == 0 or visible(run.world, Team(viewMode - 1), unit.position)

  proc updateTerrainVision() =
    ## Uploads softened terrain vision for the selected spectator team.
    if terrainVisionTick == run.world.tick and terrainVisionMode == viewMode:
      return
    terrainVisionTick = run.world.tick
    terrainVisionMode = viewMode
    var values = newSeq[uint8](mapTiles() * mapTiles())
    if viewMode == 0:
      for value in values.mitems:
        value = 255
    else:
      let team = int(viewMode - 1)
      for i in 0 ..< values.len:
        values[i] =
          if run.world.teamVisible[team][i] != 0: 255
          elif run.world.teamExplored[team][i] != 0: 48
          else: 0
    uploadTerrainVisibility(
      blurVisibility(values, mapTiles().int32, mapTiles().int32), mapTiles()
    )

  proc screenPosition(position: Vec3, viewProjection: Mat4): Vec2 =
    ## Projects a world position into window pixel coordinates.
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
    ## Labels living visible heroes using their bot execution slot.
    for slot, hero in run.world.heroes:
      if slot >= run.config.players.len or hero.state == Dying or hero.hp <= 0 or
        not visibleInView(hero.team, hero.position):
          continue
      let anchor = unitRenderPoint(hero.id, hero.position) + vec3(0, 2.4'f, 0)
      worldBarRenderer.addText(
        playerLabels[slot],
        anchor
      )

  proc addControlIcons(
      renderer: var WorldBarRenderer,
      anchor: Vec3,
      controls: array[ControlEffect, ControlTimer]
  ) =
    ## Shows simultaneous effects above visible units with remaining-time rings.
    const
      Size = 0.52'f
      Spacing = 0.64'f
      Colors = [rgbx(0, 0, 0, 0), rgbx(255, 206, 83, 255),
        rgbx(194, 144, 255, 255), rgbx(136, 218, 111, 255)]
    var count = 0
    for effect in StunControl .. RootControl:
      if controls[effect].ends > run.world.tick:
        inc count
    var index = 0
    for effect in StunControl .. RootControl:
      let timer = controls[effect]
      if timer.ends <= run.world.tick:
        continue
      let
        entry = sk.atlas.entries[ControlIconNames[effect]]
        offset = vec2((index.float32 - (count - 1).float32 / 2) * Spacing, 0)
        fraction = (timer.ends - run.world.tick).float32 /
          max(1'i32, timer.ends - timer.started).float32
      renderer.addBillboardQuad(
        anchor, offset - vec2(Size / 2), vec2(Size),
        rgbx(255, 255, 255, 255),
        vec2(entry.x.float32, entry.y.float32) / sk.atlas.size.float32,
        vec2(entry.width.float32, entry.height.float32) / sk.atlas.size.float32,
        textureMode = ColorTexture
      )
      renderer.addBillboardRing(
        anchor, offset, 0.31'f, 0.04'f, 1, rgbx(30, 32, 38, 255))
      renderer.addBillboardRing(
        anchor, offset, 0.31'f, 0.04'f, fraction, Colors[effect.ord])
      inc index

  proc drawWorldUnitBars(
      renderer: var WorldBarRenderer,
      viewProjection: Mat4,
      cameraRight,
      cameraUp: Vec3,
      dt: float32
  ) =
    ## Builds and draws attached hero, tower, and footman resource bars.
    damageTrails.beginFrame()
    renderer.clear()
    for hero in run.world.heroes:
      if hero.state == Dying or hero.hp <= 0 or
          not visibleInView(hero.team, hero.position):
        continue
      let
        health = max(hero.hp, 0'i32).float32
        maximumHealth = max(hero.maxHp, 1'i32).float32
        delayedHealth = damageTrails.delayedValue(
          hero.id,
          health,
          maximumHealth,
          dt
        )
        anchor = unitRenderPoint(hero.id, hero.position) +
          vec3(0, 2.2'f32, 0)
        bars = [
          WorldResourceBar(
            value: health,
            maximum: maximumHealth,
            delayedValue: delayedHealth,
            height: 0.16'f * HeroWorldBarScale,
            color: teamHudColor(hero.team),
            showDamageTrail: true
          ),
          WorldResourceBar(
            value: max(hero.mana, 0'i32).float32,
            maximum: max(hero.maxMana, 1'i32).float32,
            delayedValue: max(hero.mana, 0'i32).float32,
            height: 0.1'f * HeroWorldBarScale,
            color: ManaColor
          )
        ]
      renderer.addResourceBars(
        anchor,
        HeroWorldBarWidth,
        bars,
        gap = DefaultGap * HeroWorldBarScale,
        border = DefaultBorder * HeroWorldBarScale
      )
      renderer.addControlIcons(anchor + vec3(0, 0.85'f, 0), hero.controls)
      if hero.portalEnds > run.world.tick:
        renderer.addText(
          portalLabels[clamp((hero.portalEnds - run.world.tick - 1) div
            TickRate, 0, 2)],
          anchor + vec3(0, 0.5'f, 0)
        )
        renderer.addResourceBars(
          anchor - vec3(0, 0.4'f, 0), HeroWorldBarWidth,
          [WorldResourceBar(
            value: (PortalChannelTicks - hero.portalEnds +
              run.world.tick).float32,
            maximum: PortalChannelTicks.float32,
            height: 0.12'f * HeroWorldBarScale,
            color: rgbx(167, 128, 255, 255)
          )]
        )
    for tower in run.world.buildings:
      if tower.hp <= 0 or not visibleInView(tower.team, tower.position):
        continue
      let
        health = tower.hp.float32
        maximumHealth = tower.maxHp.float32
        delayedHealth = damageTrails.delayedValue(
          tower.id,
          health,
          maximumHealth,
          dt
        )
        anchor = renderPoint(tower.position) +
          vec3(0, buildingScale(tower) + 0.45'f32, 0)
        bars = [WorldResourceBar(
          value: health,
          maximum: maximumHealth,
          delayedValue: delayedHealth,
          height: 0.14'f32,
          color: teamHudColor(tower.team),
          showDamageTrail: true
        )]
      renderer.addResourceBars(anchor, TowerWorldBarWidth, bars)
    for i, fort in run.world.forts:
      if fort.hp <= 0 or not visibleInView(fort.team, fort.center):
        continue
      let
        health = fort.hp.float32
        maximum = FortHp.float32
        delayed = damageTrails.delayedValue(fort.id, health, maximum, dt)
        anchor = gods[i].position + vec3(0, GodTargetHeight + 0.45'f, 0)
        bars = [WorldResourceBar(
          value: health,
          maximum: maximum,
          delayedValue: delayed,
          height: 0.16'f,
          color: teamHudColor(fort.team),
          showDamageTrail: true
        )]
      renderer.addResourceBars(anchor, TowerWorldBarWidth, bars)
    for footman in run.world.footmen:
      if footman.state == Dying or footman.hp <= 0 or
          not visibleInView(footman):
        continue
      let
        health = footman.hp.float32
        maximumHealth = footman.unitMaxHp.float32
        delayedHealth = damageTrails.delayedValue(
          footman.id,
          health,
          maximumHealth,
          dt
        )
      renderer.addControlIcons(
        unitRenderPoint(footman.id, footman.position) +
          vec3(0, (if footman.camp > 0:
            NeutralTargetHeight * creepSize(footman) + 0.8'f
            else: 2.15'f), 0),
        footman.controls
      )
      if footman.camp > 0 or footman.hp < footman.unitMaxHp:
        let
          anchor = unitRenderPoint(footman.id, footman.position) +
            vec3(0, (if footman.camp > 0:
              NeutralTargetHeight * creepSize(footman) + 0.2'f
              else: 1.38'f), 0)
          bars = [WorldResourceBar(
            value: health,
            maximum: maximumHealth,
            delayedValue: delayedHealth,
            height: 0.1'f32,
            color: (if footman.camp > 0: rgbx(180, 180, 180, 255)
              else: teamHudColor(footman.team)),
            showDamageTrail: true
          )]
        renderer.addResourceBars(anchor, FootmanWorldBarWidth, bars)
    damageTrails.finishFrame()
    addPlayerNames()
    renderer.draw(
      viewProjection,
      cameraRight,
      cameraUp,
      sk.atlasTextureId()
    )

  proc pickEntity(viewProjection: Mat4): int32 =
    ## Finds the closest visible mesh under the pointer by triangle hit.
    let
      (origin, dir) = mouseRay(
        window.mousePos.vec2,
        window.size.vec2,
        viewProjection
      )
    var bestDistance = -1.0'f32
    template consider(candidateId: int32, distance: float32) =
      if distance > 0 and (bestDistance < 0 or distance < bestDistance):
        bestDistance = distance
        result = candidateId
    for hero in run.world.heroes:
      if hero.state == Dying or not visibleInView(hero.team, hero.position):
        continue
      let
        model = heroModels[hero.class]
        pose = heroRenderPose(hero)
      heroEyes[hero.class].setDead(false)
      consider(
        hero.id,
        pickCharacter(
          model,
          origin,
          dir,
          unitRenderPoint(hero.id, hero.position),
          unitRenderFacing(hero.id, hero.facing),
          pose.clip,
          pose.time,
          hero.heroSizeFactor()
        )
      )
    for footman in run.world.footmen:
      if footman.state == Dying or
          not visibleInView(footman):
        continue
      let
        model = creepModel(footman)
        clip = creepClip(footman)
      creepEyes(footman, false)
      consider(
        footman.id,
        pickCharacter(
          model,
          origin,
          dir,
          unitRenderPoint(footman.id, footman.position),
          unitRenderFacing(footman.id, footman.facing),
          clip,
          creepRenderTime(footman),
          sizeFactor = creepSize(footman)
        )
      )
    for tower in run.world.buildings:
      if tower.hp <= 0 or not visibleInView(tower.team, tower.position):
        continue
      consider(
        tower.id,
        pickProp(
          towerPacks[tower.team],
          buildingPropName(tower),
          origin,
          dir,
          renderPoint(tower.position),
          renderFacing(tower.facing),
          buildingScale(tower)
        )
      )
    for i, god in gods:
      if not visibleInView(god.team, run.world.forts[i].center):
        continue
      let
        model = godModels[god.team]
        clip = godRenderClips[god.team][god.godClip]
      var animTime = god.animTime
      if run.world.gameOver and
        (run.world.draw or god.team != run.world.winner):
          animTime = min(animTime, clipDuration(model, clip))
      consider(
        run.world.forts[i].id,
        pickCharacter(
          model,
          origin,
          dir,
          god.position,
          god.facing,
          clip,
          animTime
        )
      )

  proc captureCheckpoint(): SeekCheckpoint =
    ## Captures simulation state for an exact seek restore.
    SeekCheckpoint(
      tick: int(run.world.tick),
      world: run.world.clone(),
      replayActionIndex:
        if run.replayPlayer != nil: run.replayPlayer.actionIndex else: 0,
      hashCheck: run.hashCheck
    )

  var
    cameraDistance = DefaultCameraDistance
    cameraTarget = vec3(0, 0, 0)
    panning = false
    minimapPanning = false
    cameraEye = vec3(0, 0, 0)
    primaryId = 0'i32
    selectedIds: seq[int32]
    selectionPressPosition = vec2(0)
    rightPressPosition = vec2(0)
    rightOrderStarted = false
    selectionStarted = false
    selectionAdditive = false
    attackMoveArmed = false
    followSelection = false
    cameraEase: CameraEase
    focusPlayerHero = false
    groupCameraScale = 1.0'f32
    viewingDt = 0.0'f
    viewingSeeking = false
    actionCam = initActionCam(
      subjectMode = true,
      defaultDistance = DefaultCameraDistance,
      minDistance = 22,
      maxDistance = 150,
      tight = 0.72,
      followRate = 1.0,
      zoomRate = 0.7,
      holdSeconds = 2.8,
      mapSpan = mapHalfSize() * 2
    )
    transport = initPlayer(
      live = not run.replayMode,
      durationTicks = run.durationTicks(),
      playing = not options.pauseOnStart,
      speed = options.speed,
      repeating = true
    )

  window.onButtonPress = proc(button: Button) =
    if options.playerSlot > 0 and not run.replayMode and
      run.world.phase != Drafting:
        if button == KeyB:
          shopOpen = not shopOpen
          armedAbility = -1
          armedItem = -1
          return
        if button == KeyEscape:
          shopOpen = false
          armedAbility = -1
          armedItem = -1
          attackMoveArmed = false
          return
        if shopOpen and button != KeySpace:
          return
    if handleChromeKey(button):
      return
    if button == KeySpace:
      transport.handleKey(button)
    elif button == KeyC:
      actionCam.toggle(followSelection)
    elif button == KeyT:
      scene.toggleShading()
    elif button == KeyO:
      showOccludedCharacters = not showOccludedCharacters
    elif (button == KeyF or button == KeyG) and
        options.playerSlot > 0 and
        not run.replayMode:
      activatePlayerItem(
        run.world,
        run.world.heroes[options.playerSlot - 1].id,
        int32(if button == KeyF: 0 else: 1)
      )

  proc objectTeam(id: int32): int32 =
    ## Returns red, blue, or neutral ownership, or zero for an unknown ID.
    let hero = heroById(run.world, id)
    if hero.id != 0:
      return int32(hero.team.ord + 1)
    let footman = footmanById(run.world, id)
    if footman.id != 0:
      return footman.faction + 1
    for tower in run.world.buildings:
      if tower.id == id:
        return int32(tower.team.ord + 1)
    for fort in run.world.forts:
      if fort.id == id:
        return int32(fort.team.ord + 1)
    0

  proc drawCreepWaypoints(viewProjection: Mat4, right, up: Vec3) =
    ## Draws selected creep progress and the actual path without changing play.
    if not showCreepWaypoints:
      return
    let creep = footmanById(run.world, primaryId)
    if creep.id == 0 or creep.camp > 0 or not visibleInView(creep):
      return
    let goals = creep.creepWaypoints()
    while waypointLabels.len < goals.len:
      waypointLabels.add layoutText(
        sk.atlas.fonts["WorldName"], sk.atlas.size,
        $(waypointLabels.len + 1), height = 0.65'f)
    waypointShapes.clear()
    waypointText.clear()
    var remaining: seq[Vec3]
    for i, goal in goals:
      let
        point = renderPoint(goal) + vec3(0, 0.3'f, 0)
        color =
          if i < creep.waypointIndex: rgbx(104, 111, 114, 130)
          elif i == creep.waypointIndex: rgbx(255, 222, 92, 255)
          else: teamHudColor(creep.team)
      waypointShapes.addCircle(point, 0.45'f, color)
      waypointText.addText(waypointLabels[i], point + vec3(0, 0.6'f, 0), color)
      if i >= creep.waypointIndex:
        remaining.add point
      if i == creep.waypointIndex:
        var ring: seq[Vec3]
        for step in 0 .. 64:
          let
            angle = step.float32 * (2.0'f * PI.float32 / 64.0'f)
            radius = WaypointRadius.float32 / WorldScale.float32
            x = point.x + cos(angle) * radius
            z = point.z + sin(angle) * radius
          ring.add vec3(x, groundHeight(x, z) + groundOffset(x, z) + 0.3'f, z)
        waypointShapes.addPolyline(ring, color, 0.06'f)
    waypointShapes.addPolyline(remaining, teamHudColor(creep.team), 0.04'f)
    var route = @[unitRenderPoint(creep.id, creep.position) + vec3(0, 0.35'f, 0)]
    for i in creep.movePathIndex ..< creep.movePath.len:
      let tile = creep.movePath[i]
      route.add tileCenter(int(tile.layer), int(tile.x), int(tile.z)) +
        vec3(0, 0.35'f, 0)
    waypointShapes.addPolyline(route, rgbx(116, 242, 226, 255), 0.09'f)
    waypointShapes.draw(viewProjection)
    waypointText.draw(viewProjection, right, up, sk.atlasTextureId())

  proc playerMode(): bool =
    ## Returns whether this client issues orders for one hero.
    options.playerSlot > 0 and not run.replayMode

  proc playerHeroId(): int32 =
    ## Returns the human hero identifier.
    run.world.heroes[options.playerSlot - 1].id

  if playerMode():
    actionCam.takeManual()
    primaryId = playerHeroId()
    selectedIds.add primaryId
    followSelection = false

  proc syncViewMode() =
    ## Shows one team's fog when the selection is one-sided.
    if playerMode():
      viewMode =
        int32(run.world.heroes[options.playerSlot - 1].team.ord) + 1
      return
    var mode = 0'i32
    for id in selectedIds:
      let team = objectTeam(id)
      if team notin [1'i32, 2'i32]:
        continue
      if mode == 0:
        mode = team
      elif mode != team:
        viewMode = 0
        return
    viewMode = mode

  proc isSelected(id: int32): bool =
    ## Returns whether an object belongs to the current selection set.
    for selectedId in selectedIds:
      if selectedId == id:
        return true

  proc selectionTarget(id: int32): SelectionTarget =
    ## Returns current rendering and camera data for one selectable object.
    let hero = heroById(run.world, id)
    if hero.id != 0 and visibleInView(hero.team, hero.position):
      return SelectionTarget(
        found: true,
        position: unitRenderPoint(hero.id, hero.position),
        focusHeight: 0.9'f32
      )
    let footman = footmanById(run.world, id)
    if footman.id != 0 and visibleInView(footman):
      return SelectionTarget(
        found: true,
        position: unitRenderPoint(footman.id, footman.position),
        focusHeight: 0.6'f32
      )
    for tower in run.world.buildings:
      if tower.id == id and tower.hp > 0 and
          visibleInView(tower.team, tower.position):
        return SelectionTarget(
          found: true,
          position: renderPoint(tower.position),
          focusHeight: 2.5'f32
        )
    for i, god in gods:
      if run.world.forts[i].id == id and
          visibleInView(god.team, run.world.forts[i].center):
        return SelectionTarget(
          found: true,
          position: god.position,
          focusHeight: GodTargetHeight / 2
        )

  proc selectedTargetCount(): int =
    ## Returns the number of selected objects still present in the run.world.
    for id in selectedIds:
      if selectionTarget(id).found:
        inc result

  proc selectEntity(id: int32, additive = false) =
    ## Selects or toggles one object and activates selection following.
    if not selectionTarget(id).found:
      return
    if not additive:
      selectedIds.setLen(0)
    elif isSelected(id) and selectedIds.len > 1:
      for i in 0 ..< selectedIds.len:
        if selectedIds[i] == id:
          selectedIds.delete(i)
          break
      if primaryId == id:
        primaryId = selectedIds[0]
      followSelection = selectedTargetCount() > 0
      actionCam.takeManual()
      return
    if not isSelected(id):
      selectedIds.add id
    primaryId = id
    followSelection = true
    actionCam.takeManual()
    if selectedIds.len > 1:
      groupCameraScale = 1.0'f32

  proc selectAllHeroes() =
    ## Selects every hero and activates the group-follow camera.
    selectedIds.setLen(0)
    for hero in run.world.heroes:
      selectedIds.add hero.id
    if selectedIds.len > 0:
      if not isSelected(primaryId):
        primaryId = selectedIds[0]
      followSelection = true
      actionCam.takeManual()
      groupCameraScale = 1.0'f32

  proc pruneSelection() =
    ## Removes objects which no longer exist without changing valid choices.
    var i = selectedIds.high
    while i >= 0:
      if not selectionTarget(selectedIds[i]).found:
        selectedIds.delete(i)
      dec i
    if selectedIds.len == 0:
      followSelection = false
      primaryId = 0
    if selectedIds.len > 0 and not isSelected(primaryId):
      primaryId = selectedIds[0]

  proc clearSelection() =
    ## Clears the selection and leaves the camera free-floating.
    selectedIds.setLen(0)
    primaryId = 0
    followSelection = false
    actionCam.takeManual()

  proc selectedCenter(): Vec3 =
    ## Returns the midpoint of all currently selected world objects.
    var count = 0
    for id in selectedIds:
      let target = selectionTarget(id)
      if target.found:
        result += target.position + vec3(0, target.focusHeight, 0)
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
        dx = target.position.x - center.x
        dz = target.position.z - center.z
      result = max(result, sqrt(dx * dx + dz * dz))

  proc drawOutlinedObject(
      id: int32,
      view,
      projection,
      viewProjection: Mat4
  ) =
    ## Draws one object's silhouette into the current outline mask.
    for hero in run.world.heroes:
      if hero.id != id:
        continue
      let pose = heroRenderPose(hero)
      heroEyes[hero.class].setDead(hero.hp <= 0 or hero.state == Dying)
      beginCharacters(scene, window, view, projection, cameraEye)
      drawCharacter(
        scene,
        heroModels[hero.class],
        unitRenderPoint(hero.id, hero.position),
        unitRenderFacing(hero.id, hero.facing),
        pose.clip,
        pose.time,
        sizeFactor = hero.heroSizeFactor()
      )
      finishCharacters(scene)
      return
    for footman in run.world.footmen:
      if footman.id != id:
        continue
      creepEyes(footman,
        footman.hp <= 0 or footman.state == Dying
      )
      beginCharacters(scene, window, view, projection, cameraEye)
      drawCharacter(
        scene,
        creepModel(footman),
        unitRenderPoint(footman.id, footman.position),
        unitRenderFacing(footman.id, footman.facing),
        creepClip(footman),
        creepRenderTime(footman),
        sizeFactor = creepSize(footman)
      )
      finishCharacters(scene)
      return
    for i, god in gods:
      if run.world.forts[i].id != id:
        continue
      godEyes[god.team].setDead(run.world.forts[i].hp <= 0)
      beginCharacters(scene, window, view, projection, cameraEye)
      drawCharacter(
        scene,
        godModels[god.team],
        god.position,
        god.facing,
        godRenderClips[god.team][god.godClip],
        god.animTime
      )
      finishCharacters(scene)
      return
    for tower in run.world.buildings:
      if tower.hp <= 0 or tower.id != id:
        continue
      towerPacks[tower.team].drawProp(
        buildingPropName(tower),
        renderPoint(tower.position),
        renderFacing(tower.facing),
        buildingScale(tower),
        viewProjection
      )
      return

  proc drawIdOutlines(
      ids: openArray[int32],
      color: Vec3,
      view,
      projection,
      viewProjection: Mat4
  ) =
    ## Composites one outline color around every id that still exists.
    var any = false
    for id in ids:
      if selectionTarget(id).found:
        any = true
        break
    if not any:
      return
    selectionOutline.beginMask(window.size)
    for id in ids:
      if selectionTarget(id).found:
        drawOutlinedObject(id, view, projection, viewProjection)
    selectionOutline.drawOutline(color)

  proc drawSelectedOutline(
      view,
      projection,
      viewProjection: Mat4
  ) =
    ## Draws the yellow selection outline and the red attack-target outline.
    if selectedIds.len > 0:
      drawIdOutlines(
        selectedIds,
        SelectionOutlineColor,
        view,
        projection,
        viewProjection
      )
    if playerMode():
      let targetId = heroById(run.world, playerHeroId()).attackObjectId
      if targetId != 0:
        drawIdOutlines(
          [targetId],
          AttackOutlineColor,
          view,
          projection,
          viewProjection
        )

  proc feedGotaActions(observeTick = false) =
    ## Refreshes real subjects and observes every simulated tick.
    if not actionCam.enabled:
      return
    var subjects: seq[Subject]
    for hero in run.world.heroes:
      subjects.add Subject(
        id: hero.id, owner: int32(hero.slot),
        position: unitRenderPoint(hero.id, hero.position),
        height: 0.9, radius: 1.2, visible: visibleInView(hero.team, hero.position),
        alive: hero.hp > 0 and hero.state != Dying,
        hp: hero.hp, maxHp: hero.maxHp, complete: true,
        participant: max(hero.targetHeroId, hero.targetBuildingId),
        fighting: hero.state == Fighting, activity: hero.swingTicks,
        combatScore: 100
      )
    let livingHeroes = prioritizeHeroes(run.world, subjects)
    for footman in run.world.footmen:
      subjects.add Subject(
        id: footman.id, owner: footman.faction,
        position: unitRenderPoint(footman.id, footman.position),
        height: 0.8, radius: 1, visible: visibleInView(footman),
        alive: footman.hp > 0 and footman.state != Dying,
        hp: footman.hp, maxHp: footman.unitMaxHp, complete: true,
        participant: max(footman.targetHeroId, footman.targetBuildingId),
        fighting: footman.state == Fighting, activity: footman.swingTicks,
        idleScore: (if footman.state == Marching: 22.0'f else: 8.0'f),
        combatScore: 70, combatOnly: livingHeroes
      )
    for tower in run.world.buildings:
      subjects.add Subject(
        id: tower.id, owner: int32(tower.team),
        position: renderPoint(tower.position), height: 2.5, radius: 3,
        visible: visibleInView(tower.team, tower.position), alive: tower.hp > 0,
        hp: tower.hp, maxHp: tower.maxHp, complete: true,
        participant: tower.targetId, fighting: tower.targetId != 0,
        activity: tower.attackTicks, idleScore: 4, combatScore: 110,
        combatOnly: true
      )
    for i, fort in run.world.forts:
      subjects.add Subject(
        id: fort.id, owner: int32(fort.team), position: gods[i].position,
        height: GodTargetHeight, radius: 4,
        visible: visibleInView(fort.team, fort.center),
        alive: fort.hp > 0, hp: fort.hp, maxHp: FortHp, complete: true,
        damageOnly: true, combatScore: 165
      )
    if observeTick and not viewingSeeking:
      actionCam.director.observe(subjects)
    actionCam.director.refresh(subjects)

  proc playerHeroFrame(): Vec3 =
    ## Returns the look-at that frames the human hero over the HUD.
    let hero = heroById(run.world, playerHeroId())
    if hero.id == 0:
      return cameraTarget
    rtsFollowFrame(
      unitRenderPoint(hero.id, hero.position) + vec3(0, 0.9'f32, 0),
      cameraDistance,
      RtsGotaFollowLift
    )

  if playerMode():
    cameraTarget = playerHeroFrame()

  proc updateCamera(dt: float32) =
    ## Applies fixed-north RTS pan, zoom, and selection following.
    pruneSelection()
    syncViewMode()
    if shopOpen or run.world.phase == Drafting:
      selectionStarted = false
      rightOrderStarted = false
      minimapPanning = false
      return
    if focusPlayerHero:
      focusPlayerHero = false
      startCameraEase(cameraEase, cameraTarget)
    updateMinimapCamera(
      window,
      sk.mousePos,
      cameraTarget,
      minimapPanning,
      followSelection
    )
    if minimapPanning:
      actionCam.takeManual()
      cancelCameraEase(cameraEase)
    let overUi = mouseOverUi(window, sk.mousePos, primaryId)
    if window.buttonPressed[KeyA] and
        (window.buttonDown[KeyLeftControl] or
          window.buttonDown[KeyRightControl]):
      selectAllHeroes()
    elif window.mousePressed(MouseLeft) and not overUi:
      selectionPressPosition = window.mousePos.vec2
      selectionStarted = true
      selectionAdditive =
        window.buttonDown[KeyLeftShift] or
        window.buttonDown[KeyRightShift]
    var minimapPoint: Vec2
    if window.mousePressed(MouseRight) and (not overUi or
      (armedItem >= 0 and window.minimapAim(sk.mousePos, minimapPoint))):
      rightPressPosition = window.mousePos.vec2
      rightOrderStarted = true
    if window.mousePressed(MouseMiddle) and
        (not overUi or window.buttonPressed[MouseMiddleKey]):
      if not playerMode():
        followSelection = false
        actionCam.takeManual()
      cancelCameraEase(cameraEase)
    panning =
      window.mouseDown(MouseMiddle) and
        (not overUi or window.buttonDown[MouseMiddleKey]) or
      (not playerMode() and not overUi and window.mouseDown(MouseRight))

    let delta = window.mouseDelta.vec2
    if playerMode():
      if not overUi and window.scrollDelta.y != 0:
        cancelCameraEase(cameraEase)
        cameraDistance = clamp(
          cameraDistance * pow(
            0.92'f32,
            window.scrollDelta.y / 3.0'f32
          ),
          5.0'f32,
          400.0'f32
        )
      if panning:
        cancelCameraEase(cameraEase)
        let panSpeed = cameraDistance * 0.0015
        cameraTarget.x -= delta.x * panSpeed
        cameraTarget.z -= delta.y * panSpeed
        cameraTarget.x = clamp(cameraTarget.x, -mapHalfSize(), mapHalfSize())
        cameraTarget.z = clamp(cameraTarget.z, -mapHalfSize(), mapHalfSize())
      elif applyRtsPan(
          cameraTarget,
          rtsPanDir(window),
          dt,
          cameraDistance,
          mapHalfSize()
        ):
        cancelCameraEase(cameraEase)
      else:
        discard advanceCameraEase(
          cameraEase,
          cameraTarget,
          playerHeroFrame(),
          dt
        )
      return
    if panning:
      followSelection = false
      actionCam.takeManual()
      let
        panSpeed = cameraDistance * 0.0015
      cameraTarget.x -= delta.x * panSpeed
      cameraTarget.z -= delta.y * panSpeed
      cameraTarget.x = clamp(cameraTarget.x, -mapHalfSize(), mapHalfSize())
      cameraTarget.z = clamp(cameraTarget.z, -mapHalfSize(), mapHalfSize())
    if not minimapPanning and
        applyRtsPan(
          cameraTarget,
          rtsPanDir(window),
          dt,
          cameraDistance,
          mapHalfSize()
        ):
      followSelection = false
      actionCam.takeManual()
    if not overUi and window.scrollDelta.y != 0:
      actionCam.takeManual()
      if followSelection and selectedTargetCount() > 1:
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
          5.0'f32,
          400.0'f32
        )

    if actionCam.enabled:
      return
    let targetCount = selectedTargetCount()
    if followSelection and targetCount == 1:
      let target = selectionTarget(selectedIds[0])
      cameraTarget = mix(
        cameraTarget,
        target.position + vec3(0, target.focusHeight, 0),
        damping(5.0'f32, dt)
      )
    elif followSelection and targetCount > 1:
      let
        groupCenter = selectedCenter()
        groupDistance = clamp(
          12.0'f32 + selectedRadius(groupCenter) * 2.8'f32,
          20.0'f32,
          400.0'f32
        ) * groupCameraScale
      cameraTarget = mix(
        cameraTarget,
        groupCenter,
        damping(4.0'f32, dt)
      )
      cameraDistance = mix(
        cameraDistance,
        groupDistance,
        damping(2.0'f32, dt)
      )
    elif followSelection:
      followSelection = false

  proc issueGroundOrder(viewProjection: Mat4, attackMove: bool) =
    ## Walks or attack-moves the human hero onto the tile under the pointer.
    let heroId = playerHeroId()
    let hero = heroById(run.world, heroId)
    if hero.id == 0 or hero.state == Dying:
      return
    let
      (origin, dir) = mouseRay(
        window.mousePos.vec2,
        window.size.vec2,
        viewProjection
      )
      walk = pickWalkableTile(origin, dir)
    if not walk.hit:
      return
    let
      mapX = int32(layers[walk.layer].originX + walk.x - mapOrigin())
      mapY = int32(layers[walk.layer].originZ + walk.z - mapOrigin())
    if attackMove:
      queueAttackMove(heroId, mapX, mapY)
    else:
      queueWalkTo(heroId, mapX, mapY)
    selectEntity(heroId)
    clickMarks.emitClickMark(tileCenter(walk.layer, walk.x, walk.z))

  proc updatePlayerSpells(viewProjection: Mat4) =
    ## Casts quick actions and current targets, or selects an aimed ability.
    if not playerMode() or shopOpen or run.world.phase == Drafting:
      return
    for slot, key in [KeyQ, KeyW, KeyE, KeyR]:
      if window.buttonPressed[key]:
        let hero = heroById(run.world, playerHeroId())
        if window.buttonDown[KeyLeftShift] or window.buttonDown[KeyRightShift]:
          queueLevelAbility(hero.id, slot.int32)
          armedAbility = -1
          armedItem = -1
          attackMoveArmed = false
          continue
        var
          aimX = mapCoordinate(hero.position.x + hero.facing.x)
          aimY = mapCoordinate(hero.position.z + hero.facing.z)
        if not mouseOverUi(window, sk.mousePos, primaryId):
          let
            (origin, direction) = mouseRay(
              window.mousePos.vec2, window.size.vec2, viewProjection
            )
            ground = pickWalkableTile(origin, direction)
          if ground.hit:
            aimX = int32(layers[ground.layer].originX + ground.x - mapOrigin())
            aimY = int32(layers[ground.layer].originZ + ground.z - mapOrigin())
        attackMoveArmed = false
        if not activatePlayerAbility(
          run.world, hero.id, slot.int32, primaryId, aimX, aimY
        ):
          selectEntity(hero.id)

  proc updateWorldSelection(viewProjection: Mat4) =
    ## Selects a clicked world unit, or attacks it in player mode.
    if not window.mouseReleased(MouseLeft):
      return
    if selectionStarted and
        (window.mousePos.vec2 - selectionPressPosition).length <=
          6.0'f32 and
        not mouseOverUi(window, sk.mousePos, primaryId):
      let picked = pickEntity(viewProjection)
      if playerMode() and attackMoveArmed:
        let heroId = playerHeroId()
        if picked != 0 and objectTeam(picked) != objectTeam(heroId):
          queueAttackTarget(heroId, picked)
        else:
          issueGroundOrder(viewProjection, true)
        attackMoveArmed = false
      elif picked != 0:
        selectEntity(picked, selectionAdditive)
        if playerMode() and objectTeam(picked) != objectTeam(playerHeroId()):
          queueAttackTarget(playerHeroId(), picked)
      elif not selectionAdditive:
        clearSelection()
    selectionStarted = false

  proc updatePlayerOrder(viewProjection: Mat4) =
    ## Turns a right-click into a walk, attack-move, or chase attack.
    if not playerMode():
      return
    if not window.mouseReleased(MouseRight):
      return
    if not rightOrderStarted:
      return
    rightOrderStarted = false
    var minimapPoint: Vec2
    if armedItem >= 0 and window.minimapAim(sk.mousePos, minimapPoint):
      queueUseItemAt(
        playerHeroId(), armedItem,
        mapCoordinate(int32(minimapPoint.x * WorldScale.float32)),
        mapCoordinate(int32(minimapPoint.y * WorldScale.float32))
      )
      armedItem = -1
      attackMoveArmed = false
      return
    if mouseOverUi(window, sk.mousePos, primaryId):
      return
    if (window.mousePos.vec2 - rightPressPosition).length > 6.0'f32:
      return
    let
      heroId = playerHeroId()
      picked = pickEntity(viewProjection)
    if armedItem >= 0:
      let
        (origin, direction) = mouseRay(
          window.mousePos.vec2, window.size.vec2, viewProjection
        )
        ground = pickTile(origin, direction)
      if not ground.hit:
        return
      queueUseItemAt(
        heroId, armedItem,
        int32(layers[ground.layer].originX + ground.x - mapOrigin()),
        int32(layers[ground.layer].originZ + ground.z - mapOrigin())
      )
      armedItem = -1
      attackMoveArmed = false
      selectEntity(heroId)
      return
    if armedAbility >= 0:
      let
        hero = heroById(run.world, heroId)
        slot = HeroAbilitySlot(armedAbility)
        spec = heroAbility(hero.class, slot).abilitySpec
      if hero.hp <= 0 or hero.state == Dying or hero.charges[slot] <= 0 or
        hero.cooldowns[slot] > 0 or hero.mana < spec.manaCost:
          return
      if spec.casting == SelfCast:
        queueCastTarget(heroId, armedAbility, heroId)
      elif picked != 0 and
        ((spec.kind == Strike and objectTeam(picked) != objectTeam(heroId)) or
        (spec.kind != Strike and objectTeam(picked) == objectTeam(heroId))):
          queueCastTarget(heroId, armedAbility, picked)
      else:
        let
          (origin, direction) = mouseRay(
            window.mousePos.vec2, window.size.vec2, viewProjection
          )
          ground = pickWalkableTile(origin, direction)
        if not ground.hit:
          return
        queueCastPoint(
          heroId, armedAbility,
          int32(layers[ground.layer].originX + ground.x - mapOrigin()),
          int32(layers[ground.layer].originZ + ground.z - mapOrigin())
        )
      armedAbility = -1
      attackMoveArmed = false
      selectEntity(heroId)
      return
    if picked != 0 and objectTeam(picked) != objectTeam(heroId):
      queueAttackTarget(heroId, picked)
      attackMoveArmed = false
      return
    issueGroundOrder(viewProjection, attackMoveArmed)
    attackMoveArmed = false

  proc cameraView(): Mat4 =
    ## Updates the camera eye and returns its view matrix.
    cameraEye = rtsCameraEye(cameraTarget, cameraDistance)
    lookAt(cameraEye, cameraTarget, vec3(0, 1, 0))

  ## Frame

  const SimulationStep = 1.0'f32 / TickRate.float32

  var lastFrameTime = epochTime()

  proc particleTargetPosition(id: int32): tuple[
      found: bool,
      position: Vec3
  ] =
    ## Returns the presentation-space center of one combat target.
    let hero = heroById(run.world, id)
    if hero.id != 0:
      return (
        true,
        renderPoint(hero.position) + vec3(0, 0.85'f32, 0)
      )
    let footman = footmanById(run.world, id)
    if footman.id != 0:
      return (
        true,
        renderPoint(footman.position) + vec3(0, 0.65'f32, 0)
      )
    let tower = buildingById(run.world, id)
    if tower.id != 0:
      return (
        true,
        renderPoint(tower.position) +
          vec3(0, buildingScale(tower) * 0.55'f32, 0)
      )
    for i, fort in run.world.forts:
      if fort.id == id:
        return (true, gods[i].position + vec3(0, 1.0'f32, 0))

  proc emitAttackParticles(
      style: HeroAttackStyle,
      origin,
      target: Vec3
  ) =
    ## Converts one landed hero attack into its presentation effect.
    case style
    of MeleeAttack:
      particles.emitParticleBurst(CombatSparks, target)
    of RangedAttack:
      particles.emitParticleProjectile(
        ArrowWake,
        CombatSparks,
        origin,
        target,
        clamp(
          (target - origin).length / 18.0'f32,
          0.08'f32,
          0.38'f32
        )
      )
    of MagicAttack:
      particles.emitParticleProjectile(
        MagicBolt,
        MagicBurst,
        origin,
        target,
        clamp(
          (target - origin).length / 13.0'f32,
          0.12'f32,
          0.48'f32
        )
      )

  proc emitTickParticles(
      oldHeroLanded: seq[bool],
      oldFootmanLanded: Table[int32, bool]
  ) =
    ## Emits each authoritative attack transition exactly once.
    for i, hero in run.world.heroes:
      if i >= oldHeroLanded.len or oldHeroLanded[i] or
          not hero.damageLanded:
        continue
      let target = particleTargetPosition(hero.attackObjectId)
      if not target.found:
        continue
      let origin = renderPoint(hero.position) + vec3(0, 0.9'f32, 0)
      emitAttackParticles(
        hero.class.heroSpec.attackStyle,
        origin,
        target.position
      )
    for footman in run.world.footmen:
      if oldFootmanLanded.getOrDefault(footman.id, false) or
          not footman.damageLanded:
        continue
      let targetId =
        if footman.targetId != 0:
          footman.targetId
        elif footman.targetHeroId != 0:
          footman.targetHeroId
        elif footman.targetBuildingId != 0:
          footman.targetBuildingId
        elif footman.team == RedTeam:
          run.world.forts[1].id
        else:
          run.world.forts[0].id
      let target = particleTargetPosition(targetId)
      if target.found:
        let style =
          if footman.kind == RangedCreep: MagicAttack
          else: MeleeAttack
        emitAttackParticles(
          style,
          renderPoint(footman.position) + vec3(0, 1.4'f, 0),
          target.position
        )

  proc advanceRenderedSimulation() =
    ## Advances one simulation tick and starts any new god animation.
    let wasGameOver = run.world.gameOver
    var
      oldHeroLanded = newSeq[bool](run.world.heroes.len)
      oldPortalEnds = newSeq[int32](run.world.heroes.len)
      oldFootmanLanded: Table[int32, bool]
    for i, hero in run.world.heroes:
      oldHeroLanded[i] = hero.damageLanded
      oldPortalEnds[i] = hero.portalEnds
    for footman in run.world.footmen:
      oldFootmanLanded[footman.id] = footman.damageLanded
    captureUnitPositions()
    advanceGame()
    for i, hero in run.world.heroes:
      if oldPortalEnds[i] > 0 and hero.portalEnds == 0:
        previousUnitPositions[hero.id] = renderPoint(hero.position)
    feedGotaActions(observeTick = true)
    emitTickParticles(
      oldHeroLanded,
      oldFootmanLanded
    )
    if int(run.world.tick) mod SeekCheckpointTicks == 0 or
        int32(run.world.tick) == transport.timelineEnd:
      if replayCheckpoints.len == 0 or
          replayCheckpoints[^1].tick < int(run.world.tick):
        replayCheckpoints.add captureCheckpoint()
    if run.world.gameOver and not wasGameOver:
      for god in gods.mitems:
        god.animTime = 0

  proc restoreTo(targetTick: int32) =
    ## Reloads the last checkpoint at or before a tick, then resimulates.
    var checkpointIndex = 0
    for i, checkpoint in replayCheckpoints:
      if checkpoint.tick > targetTick:
        break
      checkpointIndex = i
    let checkpoint = replayCheckpoints[checkpointIndex]
    run.world.restore(checkpoint.world)
    if run.recorder != nil and run.replayPlayer != nil:
      run.replayPlayer.data = run.recorder.data
    run.replayPlayer.syncCursor(uint32(run.world.tick))
    run.hashCheck = checkpoint.hashCheck
    run.historyPlayback = true
    previousUnitPositions.clear()
    previousUnitFacings.clear()
    particles.clearParticles()
    renderAlpha = 1
    animationAlpha = 0
    for god in gods.mitems:
      god.animTime = 0
    while int32(run.world.tick) < targetTick:
      advanceGame()
      if int(run.world.tick) mod SeekCheckpointTicks == 0 or
          int32(run.world.tick) == transport.timelineEnd:
        if replayCheckpoints.len == 0 or
            replayCheckpoints[^1].tick < int(run.world.tick):
          replayCheckpoints.add captureCheckpoint()

  if not run.replayMode:
    startReplayRecording(uint32(options.maximumTicks))
  replayCheckpoints = @[captureCheckpoint()]

  let cleanScreenshot =
    when defined(takeScreenshot): existsEnv("CLEAN_SCREENSHOT")
    else: false
  when defined(takeScreenshot):
    var screenshotFrame = 0
    let screenshotPath =
      if existsEnv("SCREENSHOT_PATH"):
        getEnv("SCREENSHOT_PATH")
      else:
        "examples/gods_of_the_arena/gota_shot.png"
    applyScreenshotCamera(cameraDistance)
    if existsEnv("CAM_X"): cameraTarget.x = getEnv("CAM_X").parseFloat.float32
    if existsEnv("CAM_Z"): cameraTarget.z = getEnv("CAM_Z").parseFloat.float32
    if existsEnv("SHOW_EDGES"): showTiles = getEnv("SHOW_EDGES") != "0"
    if run.replayMode and existsEnv("REPLAY_TICK"):
      transport.seekTo(int32(getEnv("REPLAY_TICK").parseInt))
    if existsEnv("SIM_SECONDS"):
      # Fast-forward the battle deterministically before the first frame.
      let simSeconds = getEnv("SIM_SECONDS").parseFloat
      for i in 0 ..< int(simSeconds * TickRate.float64):
        advanceGame()
    if existsEnv("PARTICLE_DEMO"):
      let
        origin = cameraTarget + vec3(-2.5'f32, 4.0'f32, 0)
        target = cameraTarget + vec3(2.5'f32, 4.0'f32, 0)
      particles.emitParticleProjectile(
        Fireball,
        FireBurst,
        origin,
        target,
        0.42'f32
      )
      particles.emitParticleBurst(
        HealingAura,
        cameraTarget + vec3(0, 3.5'f32, 0)
      )
    if not playerMode():
      for hero in run.world.heroes:
        if hero.class == Arcanist and hero.state != Dying:
          primaryId = hero.id
          selectedIds = @[hero.id]
          followSelection = true
          break
      if primaryId == 0:
        for hero in run.world.heroes:
          if hero.state != Dying:
            primaryId = hero.id
            selectedIds = @[hero.id]
            followSelection = true
            break
    else:
      primaryId = playerHeroId()
      selectedIds = @[primaryId]
      followSelection = false
      cameraTarget = playerHeroFrame()

    if existsEnv("SELECT_ID"):
      selectEntity(getEnv("SELECT_ID").parseInt.int32)
    if existsEnv("SELECT_ALL"):
      selectAllHeroes()
    if cleanScreenshot:
      primaryId = 0
      selectedIds.setLen(0)
      followSelection = false
      viewMode = 0
    if existsEnv("CAM_X") or existsEnv("CAM_Z"):
      followSelection = false
      actionCam.takeManual()

  var
    viewingClock: ViewingClock
    cameraSeekSerial = -1

  holdSplash(sk, window, splash)
  window.onFrame = proc() =
    profileBlock "frame":
      let dt = frameDelta(lastFrameTime)
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
      transport.durationTicks = run.durationTicks()
      transport.sync(int32(run.world.tick), recorded, run.finished())
      let restoreTick = transport.takeRestore()
      if restoreTick >= 0:
        restoreTo(restoreTick)
        transport.durationTicks = run.durationTicks()
        transport.sync(int32(run.world.tick), recorded, run.finished())
      feedGotaActions(observeTick = true)
      transport.startFrame(dt, TickRate)
      let frameStart = epochTime()
      run.historyPlayback = transport.inHistory
      profileBlock "simulate":
        while transport.shouldTick(frameStart):
          if atLiveTickCap(
              int32(run.world.tick),
              transport.durationTicks,
              transport.live
          ):
            break
          run.historyPlayback = transport.inHistory
          advanceRenderedSimulation()
          let recordedNow =
            if run.recorder != nil: int32(run.recorder.data.hashes.len)
            else: int32(run.replayPlayer.data.hashes.len)
          transport.durationTicks = run.durationTicks()
          transport.sync(int32(run.world.tick), recordedNow, run.finished())
      let active = simulationActive(transport)
      if active:
        renderAlpha = clamp(
          transport.accumulator / SimulationStep,
          0.0'f32,
          1.0'f32
        )
        animationAlpha = renderAlpha
      else:
        renderAlpha = 1
        animationAlpha = 0
      if active:
        particles.advanceParticles(dt)
        clickMarks.advanceClickMarks(dt)
        for god in gods.mitems:
          god.animTime += dt
          if run.world.gameOver and
            (run.world.draw or god.team != run.world.winner):
              god.animTime = min(
                god.animTime,
                clipDuration(
                  godModels[god.team], godRenderClips[god.team][GodDeath])
              )

      feedGotaActions()
      actionCam.direct(
        cameraTarget, cameraDistance, viewingDt,
        run.world.gameOver or transport.tick >= transport.timelineEnd,
        transport.repeating,
        window.size.x.float32 / max(window.size.y.float32, 1),
        RtsGotaFollowLift
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
      updatePlayerSpells(viewProjection)
      updatePlayerOrder(viewProjection)

      profileBlock "drawWorld":
        # The clock changes palettes while the light stays fixed for
        # readable silhouettes and shadows on both sides of the map.
        scene.toon.setArenaHour(
          clockHour(float32(run.world.battleTick()) + renderAlpha, TickRate))
        setEnvironmentPalette(scene.toon)

        proc drawWorldCharacters(livingOnly = false) =
          ## Uses identical poses for shadows, occlusion masks, and the camera.
          for footman in run.world.footmen:
            if not visibleInView(footman):
              continue
            if livingOnly and (footman.hp <= 0 or footman.state == Dying):
              continue
            let
              model = creepModel(footman)
              clip =
                creepClip(footman)
            creepEyes(footman,
              footman.hp <= 0 or footman.state == Dying
            )
            drawCharacter(
              scene, model, unitRenderPoint(footman.id, footman.position),
              unitRenderFacing(footman.id, footman.facing),
              clip,
              creepRenderTime(footman),
              sizeFactor = creepSize(footman)
            )
          for hero in run.world.heroes:
            if not visibleInView(hero.team, hero.position):
              continue
            if livingOnly and (hero.hp <= 0 or hero.state == Dying):
              continue
            let pose = heroRenderPose(hero)
            heroEyes[hero.class].setDead(hero.hp <= 0 or hero.state == Dying)
            drawCharacter(
              scene,
              heroModels[hero.class],
              unitRenderPoint(hero.id, hero.position),
              unitRenderFacing(hero.id, hero.facing),
              pose.clip,
              pose.time,
              sizeFactor = hero.heroSizeFactor()
            )
          for god in gods:
            if not visibleInView(
                god.team, run.world.forts[god.team.ord].center):
              continue
            if livingOnly and run.world.forts[god.team.ord].hp <= 0:
              continue
            let
              model = godModels[god.team]
              clip = godRenderClips[god.team][god.godClip]
            godEyes[god.team].setDead(run.world.forts[god.team.ord].hp <= 0)
            var animTime = god.animTime
            if run.world.gameOver and
              (run.world.draw or god.team != run.world.winner):
                animTime = min(animTime, clipDuration(model, clip))
            drawCharacter(
              scene, model, god.position, god.facing,
              clip, animTime)

        sunDepthPasses(window.size):
          drawTerrainSunDepth()
          for tower in run.world.buildings:
            if tower.hp <= 0:
              continue
            towerPacks[tower.team].drawPropSunDepth(
              buildingPropName(tower),
              renderPoint(tower.position),
              renderFacing(tower.facing),
              buildingScale(tower)
            )
          scene.sunDepthPass = true
          drawWorldCharacters()
          scene.sunDepthPass = false
        when not defined(emscripten):
          glEnable(GL_MULTISAMPLE)
        glClearColor(0.05, 0.06, 0.09, 1.0)
        glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
        scene.toon.drawBackground()
        updateTerrainVision()
        if showTiles and (terrainEdgeWorld != run.world or
            terrainEdgeRevision != run.world.navigationRevision):
          updateTerrainEdges(navigationOpen)
          terrainEdgeWorld = run.world
          terrainEdgeRevision = run.world.navigationRevision
        drawTerrain(viewProjection, showTiles)
        for tower in run.world.buildings:
          if tower.hp <= 0 or not visibleInView(tower.team, tower.position):
            continue
          towerPacks[tower.team].drawProp(
            buildingPropName(tower),
            renderPoint(tower.position),
            renderFacing(tower.facing),
            buildingScale(tower),
            viewProjection
          )

        if showOccludedCharacters:
          occlusionOutline.beginMask(window.size)
          beginCharacters(scene, window, view, projection, cameraEye)
          drawWorldCharacters(livingOnly = true)
          finishCharacters(scene)
          # Only opaque scenery is in the window depth buffer at this point.
          occlusionOutline.drawOutline(OccludedOutlineColor)

        beginCharacters(scene, window, view, projection, cameraEye)
        drawWorldCharacters()
        finishCharacters(scene)

        let waterTime =
          (run.world.tick.float32 + renderAlpha) / TickRate.float32
        drawWater(
          viewProjection,
          cameraEye,
          offset = vec2(waterTime * 0.25'f, 0),
          opacity = 0.5'f,
          highlightOpacity = 0.0'f
        )
        particles.drawParticles(
          viewProjection,
          barCameraRight,
          barCameraUp,
          cameraForward
        )
        spellEffects.drawSpells(
          run.world, viewProjection, animationAlpha, viewMode
        )
        clickMarks.drawClickMarks(viewProjection)
        worldShapes.clear()
        for hero in run.world.heroes:
          if hero.portalEnds <= run.world.tick or hero.hp <= 0:
            continue
          for point in [hero.position, hero.portalDestination]:
            if not visibleInView(hero.team, point):
              continue
            var ring: array[49, Vec3]
            let
              center = renderPoint(point)
              radius = 0.5'f + (hero.portalEnds - run.world.tick).float32 /
                PortalChannelTicks.float32
            for i in 0 .. ring.high:
              let angle = i.float32 * 2 * PI.float32 / ring.high.float32
              ring[i] = center + vec3(cos(angle) * radius, 0.12'f,
                sin(angle) * radius)
            worldShapes.addPolyline(ring, rgbx(167, 128, 255, 255), 0.06'f)
        if playerMode() and armedItem >= 0:
          let hero = run.world.heroById(playerHeroId())
          for tower in run.world.buildings:
            if tower.kind != TowerBuilding or tower.hp <= 0 or
              tower.team != hero.team:
                continue
            var ring: array[65, Vec3]
            let
              center = renderPoint(tower.position)
              radius = TowerAttackRanges[tower.tier].float32 / WorldScale.float32
            for i in 0 .. ring.high:
              let angle = i.float32 * 2 * PI.float32 / ring.high.float32
              ring[i] = center + vec3(cos(angle) * radius, 0,
                sin(angle) * radius)
              ring[i].y = groundHeight(ring[i].x, ring[i].z) +
                groundOffset(ring[i].x, ring[i].z) + 0.12'f
            worldShapes.addPolyline(ring, rgbx(167, 128, 255, 255), 0.04'f)
        if showPaths:
          for hero in run.world.heroes:
            if hero.state == Dying or hero.hp <= 0:
              continue
            if hero.movePathIndex >= hero.movePath.len:
              continue
            let color =
              if hero.team == RedTeam:
                rgbx(210, 72, 64, 255)
              else:
                rgbx(64, 120, 220, 255)
            var points: seq[Vec3]
            let now = unitRenderPoint(hero.id, hero.position)
            points.add vec3(now.x, now.y + 0.2'f32, now.z)
            for i in hero.movePathIndex ..< hero.movePath.len:
              let p = renderPoint(hero.movePath[i])
              points.add vec3(p.x, p.y + 0.2'f32, p.z)
            if points.len >= 2:
              worldShapes.addPolyline(points, color)
        worldShapes.draw(viewProjection)
        if not cleanScreenshot:
          drawWorldUnitBars(
            worldBarRenderer,
            viewProjection,
            barCameraRight,
            barCameraUp,
            dt
          )
          drawSelectedOutline(view, projection, viewProjection)
          drawCreepWaypoints(viewProjection, barCameraRight, barCameraUp)

      profileBlock "ui":
        if not cleanScreenshot:
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
            focusPlayerHero
          )
          sk.endUi()
          drawStatsOverlay(sk, window)
      when defined(takeScreenshot):
        captureScreenshot(
          window,
          screenshotFrame,
          30,
          screenshotPath
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

  if not run.replayMode:
    saveRecording()
  clickMarks.closeClickMarks()
  worldShapes.closeShapeRenderer()
  worldBarRenderer.closeWorldBarRenderer()
  particles.closeParticles()
  spellEffects.closeSpellRenderer()
  selectionOutline.closeSelectionOutline()
  occlusionOutline.closeSelectionOutline()
  finishGameProfile()
