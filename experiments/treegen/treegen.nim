import
  std/[math, os, random, strutils, times],
  bumpy, chroma, gltf, pixie, silky, vmath,
  polyworld/[shadows, toon], polyworld/treegen as generator,
  views

const
  WindowSize = ivec2(1440, 940)
  PanelWidth = 372.0'f
  PanelPosition = vec2(12, 12)
  RowWidth = 330
  UiAtlas = ExperimentDirectory / "../../tmp/treegen.atlas.png"
  ThemeDirectory = ExperimentDirectory / "../../../polyworld_art/themes/main"

type
  PanelTab = enum
    Trunk, Branches, Canopy, Leaves, Flowers, Colors
  Options = object
    preset, seed, frames: int
    yaw, pitch: float32
    screenshot, exportPath, loadPath: string
    gallery: bool
  TreeApp = object
    sk: Silky
    toon: ToonContext
    settings, built: TreeSettings
    geometry: TreeGeometry
    materials: TreeMaterials
    node, ground: Node
    variants: seq[Node]
    tab: PanelTab
    presetName, status: string
    showPanel, gallery, builtGallery, wireframe, rotating: bool
    orbiting, panning: bool
    yaw, pitch, distance: float32
    target: Vec3
    frame: int
    rng: Rand

proc optionsFromArgs(): Options =
  ## Parses reproducible startup and capture options with clear errors.
  result.seed = 42
  result.yaw = 0.55'f
  result.pitch = 0.24'f
  try:
    for argument in commandLineParams():
      if argument == "--smoke":
        result.frames = 4
      elif argument == "--gallery":
        result.gallery = true
      elif argument.startsWith("--preset="):
        result.preset = argument[9 .. ^1].parseInt
      elif argument.startsWith("--seed="):
        result.seed = argument[7 .. ^1].parseInt
      elif argument.startsWith("--frames="):
        result.frames = argument[9 .. ^1].parseInt
      elif argument.startsWith("--yaw="):
        result.yaw = argument[6 .. ^1].parseFloat.float32
      elif argument.startsWith("--pitch="):
        result.pitch = argument[8 .. ^1].parseFloat.float32
      elif argument.startsWith("--screenshot="):
        result.screenshot = argument[13 .. ^1]
      elif argument.startsWith("--export="):
        result.exportPath = argument[9 .. ^1]
      elif argument.startsWith("--load="):
        result.loadPath = argument[7 .. ^1]
      else:
        raise newException(TreegenError, "Unknown argument: " & argument)
  except ValueError:
    raise newException(TreegenError, "Expected a numeric argument: " &
      getCurrentExceptionMsg())
  if result.preset notin 0 .. PresetNames.high or result.frames < 0:
    raise newException(TreegenError, "Preset or frame count is out of range")
  if not (result.yaw >= -PI.float32 * 2 and
    result.yaw <= PI.float32 * 2 and
    result.pitch >= -0.2'f and result.pitch <= 1.5'f):
      raise newException(TreegenError, "Camera angle is out of range")
  if result.screenshot.len > 0 and result.frames == 0:
    result.frames = 4

proc geometryKey(settings: TreeSettings): TreeSettings =
  ## Excludes material-only controls from the geometry rebuild decision.
  result = settings
  result.barkColor = vec3(0)
  result.leafColor = vec3(0)
  result.flowerColor = vec3(0)
  result.barkTexture = 0

proc releaseTrees(app: var TreeApp) =
  ## Releases old GPU buffers and textures before replacing a preview.
  app.node.clearFromGpu()
  for node in app.variants:
    node.clearFromGpu()
  app.variants.setLen(0)

proc rebuild(app: var TreeApp) =
  ## Regenerates the selected seed and optional two neighboring seeds.
  app.releaseTrees()
  app.materials = loadMaterials(app.settings.barkTexture,
    withFlowers = app.settings.flowerKind != NoFlowers)
  app.materials.tint(app.settings)
  app.geometry = generateGeometry(app.settings)
  app.node = treeNode(app.geometry, app.materials)
  if app.gallery:
    let spacing = (app.geometry.maximum.x - app.geometry.minimum.x) * 1.15'f
    for i in [-1, 1]:
      var settings = app.settings
      settings.seed = (settings.seed + i + 1_000_000_001) mod 1_000_000_001
      let node = treeNode(generateGeometry(settings), app.materials)
      node.pos.x = i.float32 * spacing
      app.variants.add node
  app.built = app.settings
  app.builtGallery = app.gallery

proc frameTree(app: var TreeApp) =
  ## Fits the tree or seed comparison in the unobstructed viewport.
  app.target = (app.geometry.minimum + app.geometry.maximum) * 0.5'f
  let extent = app.geometry.maximum - app.geometry.minimum
  app.distance = max(extent.y * 1.8'f, max(extent.x, extent.z) * 1.8'f)
  if app.gallery:
    app.distance *= 2.0'f

proc mouseOverUi(app: TreeApp, window: Window): bool =
  ## Prevents the panel and its floating menus from moving the camera.
  if not app.showPanel:
    return false
  for state in subWindowStates.values:
    if state.visible and window.mousePos.vec2.overlaps(
      rect(state.pos, state.size)):
        return true
  window.mousePos.x.float32 < PanelWidth + 30

proc randomizeSeed(app: var TreeApp) =
  ## Selects a fresh seed without changing the current tree recipe.
  let previous = app.settings.seed
  while app.settings.seed == previous:
    app.settings.seed = app.rng.rand(1_000_000_000)

proc selectPreset(app: var TreeApp, index: int) =
  ## Applies a preset while preserving the current seed.
  let selected = (index + PresetNames.len) mod PresetNames.len
  app.presetName = PresetNames[selected]
  app.settings = preset(selected, app.settings.seed)
  if app.settings.kind == Stump:
    app.tab = Trunk
  app.rebuild()
  app.frameTree()

proc stepPreset(app: var TreeApp, step: int) =
  ## Cycles the ordered presets in either direction, wrapping at the ends.
  var index = 0
  for i, name in PresetNames:
    if name == app.presetName:
      index = i
  app.selectPreset(index + step)

proc handleInput(app: var TreeApp, window: Window, delta: float32) =
  ## Routes panel-independent orbit, pan, zoom, and keyboard shortcuts.
  if window.buttonPressed[KeyEscape]:
    window.closeRequested = true
  if window.buttonPressed[KeyTab]:
    app.showPanel = not app.showPanel
  if app.sk.buttonPressed[KeyR]:
    app.randomizeSeed()
  if app.sk.buttonPressed[KeyF]:
    app.frameTree()
  if app.sk.buttonPressed[KeyW]:
    app.wireframe = not app.wireframe
  if app.sk.buttonPressed[KeySpace]:
    app.rotating = not app.rotating
  let overUi = app.mouseOverUi(window)
  if not overUi:
    if window.buttonPressed[MouseLeft] or window.buttonPressed[MouseRight]:
      app.orbiting = true
    if window.buttonPressed[MouseMiddle]:
      app.panning = true
  if not window.buttonDown[MouseLeft] and not window.buttonDown[MouseRight]:
    app.orbiting = false
  if not window.buttonDown[MouseMiddle]:
    app.panning = false
  if app.orbiting:
    app.yaw -= window.mouseDelta.x.float32 * 0.008'f
    app.pitch = clamp(app.pitch + window.mouseDelta.y.float32 * 0.008'f,
      -0.2'f, 1.4'f)
  if app.panning:
    let
      right = vec3(cos(app.yaw), 0, -sin(app.yaw))
      up = vec3(-sin(app.yaw) * sin(app.pitch), cos(app.pitch),
        -cos(app.yaw) * sin(app.pitch))
      speed = app.distance * 0.0015'f
    app.target -= right * window.mouseDelta.x.float32 * speed
    app.target += up * window.mouseDelta.y.float32 * speed
  if not overUi and window.scrollDelta.y != 0:
    app.distance = clamp(app.distance * pow(0.9'f, window.scrollDelta.y),
      2.0'f, 100.0'f)
  if app.rotating:
    app.yaw += delta * 0.25'f

template control(caption: string, target: untyped, low, high: untyped) =
  ## Draws a labeled scrubber using the editor's existing Silky style.
  block:
    let label = caption
    when target is float32:
      text(label & ": " & target.formatFloat(ffDecimal, 2))
    else:
      text(label & ": " & $target)
    scrubber(label, target, low, high, "")

proc trunkControls(app: var TreeApp, window: Window) =
  ## Exposes trunk proportions, polygon resolution, and the root flare.
  let sk = app.sk
  if app.settings.kind in {Bush, Hedge, FlowerPatch}:
    text("Set ground-plant dimensions in Canopy.")
    return
  if app.settings.kind == Stump:
    control("Cut height", app.settings.height, 0.3'f, 3.0'f)
  else:
    control("Height", app.settings.height, 1.0'f, 16.0'f)
  control("Trunk radius", app.settings.trunkRadius, 0.06'f, 1.4'f)
  control("Taper", app.settings.taper, 0.3'f, 3.0'f)
  control("Bend", app.settings.bend, 0.0'f, 1.5'f)
  control("Twist", app.settings.twist, 0.0'f, 3.0'f)
  control("Trunk segments", app.settings.trunkSegments, 3, 16)
  control("Radial sides", app.settings.radialSides, 3, 12)
  control("Roots", app.settings.roots, 0, 12)
  control("Root spread", app.settings.rootSpread, 0.1'f, 3.0'f)
  control("Root thickness", app.settings.rootThickness, 0.1'f, 1.5'f)
  control("Root claw length", app.settings.rootClaw, 0.1'f, 0.6'f)
  control("Root claw angle", app.settings.rootAngle, 5.0'f, 65.0'f)
  if app.settings.kind != Stump:
    control("Clear stem", app.settings.stemClearance, 0.1'f, 3.0'f)

proc branchControls(app: var TreeApp, window: Window) =
  ## Exposes branch layout, growth direction, and bounded fork depth.
  let sk = app.sk
  if app.settings.kind in {Bush, Hedge, FlowerPatch}:
    text("Ground plants use short concealed stems.")
    return
  if app.settings.kind == Stump:
    text("Stumps keep the trunk and roots.")
    text("Adjust Cut height in the Trunk tab.")
    return
  text("Branch style")
  dropDown(app.settings.branchKind, [Spreading, Angular, Drooping])
  text("Branch arrangement")
  dropDown(app.settings.branchLayout, [Spiral, Paired, Whorled])
  control("Branches", app.settings.branches, 0, 24)
  control("Fork depth", app.settings.forks, 0, 3)
  control("Branch segments", app.settings.branchSegments, 2, 8)
  control("Branch start", app.settings.branchStart, 0.1'f, 0.85'f)
  control("Branch length", app.settings.branchLength, 0.2'f, 5.0'f)
  control("Branch radius", app.settings.branchRadius, 0.15'f, 0.9'f)
  control("Branch lift", app.settings.branchLift, -0.7'f, 1.5'f)
  control("Branch randomness", app.settings.branchJitter, 0.0'f, 1.0'f)
  control("Minimum thickness", app.settings.branchMinimum, 0.001'f, 0.3'f)

proc canopyControls(app: var TreeApp, window: Window) =
  ## Exposes the cone or round envelope and its irregular radial rings.
  let sk = app.sk
  if app.settings.kind in {Leafless, Stump}:
    text("This tree type has no canopy.")
    return
  if app.settings.kind in {Bush, Hedge, FlowerPatch}:
    text("Bush size")
    let previous = app.settings.bushSize
    dropDown(app.settings.bushSize, [LowBush, SmallBush, MediumBush, LargeBush])
    if previous != app.settings.bushSize:
      app.settings.setBushSize(app.settings.bushSize)
    control("Plant width / hedge length", app.settings.plantWidth, 0.2'f, 12.0'f)
    control("Plant depth", app.settings.plantDepth, 0.2'f, 5.0'f)
    control("Plant height", app.settings.plantHeight, 0.12'f, 3.0'f)
    if app.settings.kind != FlowerPatch:
      control("Leaf density", app.settings.density, 0.0'f, 2.0'f)
      control("Leaf overlap", app.settings.packing, 0.5'f, 3.0'f)
      control("Irregularity", app.settings.irregularity, 0.0'f, 0.65'f)
    return
  control("Crown radius", app.settings.crownRadius, 0.3'f, 5.0'f)
  control("Crown height", app.settings.crownHeight, 0.5'f, 12.0'f)
  control("Crown base", app.settings.crownBase, 0.3'f, 8.0'f)
  control("Profile shape", app.settings.crownShape, 0.25'f, 2.5'f)
  if app.settings.kind == Broadleaf:
    control("Sphere coverage", app.settings.crownCoverage, 0.5'f, 1.0'f)
  control("Cap size", app.settings.capSize, 0.5'f, 2.0'f)
  if app.settings.kind == Broadleaf:
    control("Cap slope", app.settings.capSlope, 5.0'f, 55.0'f)
  control("Rings", app.settings.rings, 2, 24)
  control("Cards per ring", app.settings.cardsPerRing, 3, 32)
  control("Inner shells", app.settings.shells, 1, 3)
  control("Density", app.settings.density, 0.0'f, 2.0'f)
  control("Leaf overlap", app.settings.packing, 0.5'f, 3.0'f)
  control("Ring spacing", app.settings.ringSpacing, 0.5'f, 2.0'f)
  control("Ring rotation offset", app.settings.ringOffset, 0.0'f, 1.0'f)
  control("Ring irregularity", app.settings.irregularity, 0.0'f, 0.65'f)

proc leafControls(app: var TreeApp, window: Window) =
  ## Exposes white atlas selection and the shape of each radial card.
  let sk = app.sk
  if app.settings.kind in {Leafless, Stump}:
    text("This tree type has no foliage.")
    return
  if app.settings.kind != Evergreen:
    text("Leaf trim")
    dropDown(app.settings.leafTile,
      [MixedLeaves, SoftLeaves, LobedLeaves, PointedLeaves])
  else:
    text("Uses the four evergreen sprays.")
  control("Leaf card length", app.settings.leafSize, 0.2'f, 3.5'f)
  control("Leaf card width", app.settings.leafWidth, 0.3'f, 2.0'f)
  if app.settings.kind == Broadleaf:
    control("Droop", app.settings.droop, 0.0'f, 1.5'f)
    control("Card curl", app.settings.curl, -0.5'f, 0.8'f)
  control("Leaf randomness", app.settings.leafJitter, 0.0'f, 0.6'f)
  control("Shade variation", app.settings.colorVariation, 0.0'f, 0.5'f)
  checkBox("Prevent leaf crossings", app.settings.separateLeaves)
  if app.settings.separateLeaves and app.geometry.omittedCards > 0:
    text($app.geometry.omittedCards & " crowded cards omitted.")
  if app.settings.kind == Evergreen:
    text("Leaves and cap follow the cone slope.")
  else:
    text("Cards radiate out from each ring.")
  text("Their attachment stays at the top.")

proc flowerControls(app: var TreeApp, window: Window) =
  ## Exposes bloom artwork, amount, dimensions, and independent petal tint.
  let sk = app.sk
  text("Flower type")
  dropDown(app.settings.flowerKind, [NoFlowers, Daisies, BlueFlowers,
    PinkFlowers, GoldenFlowers, Lavender, BlueSpikes, Sunflowers,
    WhiteBlossoms, PinkBlossoms, PurpleBlossoms, GoldenBlossoms, MixedFlowers])
  control("Flower density", app.settings.flowerDensity, 0.0'f, 1.0'f)
  control("Flower size", app.settings.flowerSize, 0.08'f, 1.5'f)
  control("Petal red", app.settings.flowerColor.x, 0.0'f, 1.0'f)
  control("Petal green", app.settings.flowerColor.y, 0.0'f, 1.0'f)
  control("Petal blue", app.settings.flowerColor.z, 0.0'f, 1.0'f)
  text("White tint preserves the painted flower colors.")
  text($app.geometry.blooms & " blooms")

proc colorControls(app: var TreeApp, window: Window) =
  ## Exposes independent bark and leaf RGB factors and scene lighting.
  let sk = app.sk
  text("Bark RGB")
  control("Bark red", app.settings.barkColor.x, 0.0'f, 1.0'f)
  control("Bark green", app.settings.barkColor.y, 0.0'f, 1.0'f)
  control("Bark blue", app.settings.barkColor.z, 0.0'f, 1.0'f)
  control("Bark texture", app.settings.barkTexture, 0.0'f, 1.0'f)
  control("Bark density", app.settings.barkDensity, 0.1'f, 3.0'f)
  text("Foliage RGB")
  control("Leaf red", app.settings.leafColor.x, 0.0'f, 1.0'f)
  control("Leaf green", app.settings.leafColor.y, 0.0'f, 1.0'f)
  control("Leaf blue", app.settings.leafColor.z, 0.0'f, 1.0'f)
  group "season colors":
    box RowWidth, 32
    layout LeftToRight
    button "Green":
      app.settings.leafColor = vec3(0.5, 0.72, 0.16)
    button "Autumn":
      app.settings.leafColor = vec3(1, 0.32, 0.045)
    button "White":
      app.settings.leafColor = vec3(1)
  control("Sun azimuth", sunAzimuth, 0.0'f, 360.0'f)
  control("Sun elevation", sunElevation, 10.0'f, 85.0'f)
  checkBox("Cast shadows", sunShadowsEnabled)

proc drawUi(app: var TreeApp, window: Window) =
  ## Draws the left preset panel, parameter tabs, and preview controls.
  let sk = app.sk
  sk.beginUi(window, window.size)
  if app.showPanel:
    subWindow("Tree generator", app.showPanel, PanelPosition,
      vec2(PanelWidth, window.size.y.float32 - 24)):
        text("TREEGEN  /  procedural tree lab")
        let triangles = (app.geometry.bark.indices.len +
          app.geometry.foliage.indices.len +
          app.geometry.cut.indices.len + app.geometry.flowers.indices.len +
          app.geometry.stems.indices.len + app.geometry.crown.indices.len) div 3
        text($app.geometry.cards & " leaf cards   " &
          $triangles & " triangles")
        text("Presets")
        block:
          let previous = app.presetName
          dropDown(app.presetName, PresetNames)
          if previous != app.presetName:
            for i, name in PresetNames:
              if app.presetName == name:
                app.selectPreset(i)
        group "preset actions":
          box RowWidth, 32
          layout LeftToRight
          button "Previous Preset":
            app.stepPreset(-1)
          button "Next Preset":
            app.stepPreset(1)
        group "tree family":
          box RowWidth, 32
          layout LeftToRight
          let previous = app.settings.kind
          radioButton("Bare", app.settings.kind, Leafless)
          radioButton("Fir", app.settings.kind, Evergreen)
          radioButton("Round", app.settings.kind, Broadleaf)
          radioButton("Stump", app.settings.kind, Stump)
          if app.settings.kind != previous:
            if app.settings.kind == Stump:
              app.settings.height = min(app.settings.height, 1.0'f)
              app.tab = Trunk
            elif previous == Stump:
              app.settings.height = max(app.settings.height, 1.0'f)
        group "ground plants":
          box RowWidth, 32
          layout LeftToRight
          let previous = app.settings.kind
          radioButton("Bush", app.settings.kind, Bush)
          radioButton("Hedge", app.settings.kind, Hedge)
          radioButton("Flowers", app.settings.kind, FlowerPatch)
          if app.settings.kind != previous:
            app.settings.setBushSize(app.settings.bushSize)
            app.tab = Canopy
            if app.settings.kind == FlowerPatch and
              app.settings.flowerKind == NoFlowers:
                app.settings.flowerKind = Daisies
        text("Seed: " & $app.settings.seed)
        button "Randomize Seed":
          app.randomizeSeed()
        checkBox("Compare three seeds", app.gallery)
        group "parameter tabs":
          box RowWidth, 32
          layout LeftToRight
          radioButton("Trunk", app.tab, Trunk)
          radioButton("Branches", app.tab, Branches)
          radioButton("Canopy", app.tab, Canopy)
        group "appearance tabs":
          box RowWidth, 32
          layout LeftToRight
          radioButton("Leaves", app.tab, Leaves)
          radioButton("Flowers", app.tab, Flowers)
          radioButton("Colors", app.tab, Colors)
        frame "parameters":
            size(RowWidth, max(120.0'f, window.size.y.float32 - 707))
            case app.tab
            of Trunk:
              app.trunkControls(window)
            of Branches:
              app.branchControls(window)
            of Canopy:
              app.canopyControls(window)
            of Leaves:
              app.leafControls(window)
            of Colors:
              app.colorControls(window)
            of Flowers:
              app.flowerControls(window)
        group "file actions":
          box RowWidth, 32
          layout LeftToRight
          button "Save preset":
            try:
              app.settings.saveSettings(CustomPath)
              app.status = "Saved presets/custom.json"
            except TreegenError as error:
              app.status = error.msg
          button "Load":
            try:
              app.settings = loadSettings(CustomPath)
              app.presetName = "Custom"
              app.status = "Loaded presets/custom.json"
            except TreegenError as error:
              app.status = error.msg
          button "Export GLB":
            try:
              let path = ExperimentDirectory / "exports" /
                ("tree-" & $app.settings.seed & ".glb")
              app.settings.exportTree(path)
              app.status = "Exported tree-" & $app.settings.seed & ".glb"
            except TreegenError as error:
              app.status = error.msg
        group "preview actions":
          box RowWidth, 32
          layout LeftToRight
          checkBox("Wireframe", app.wireframe)
          checkBox("Turntable", app.rotating)
          button "Fit":
            app.frameTree()
        text("Drag orbit / middle drag pan / scroll zoom")
        text("R random seed / F fit / W wire / Tab panel")
        if app.status.len > 0:
          text(app.status)
  glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  sk.endUi()

proc drawScene(app: var TreeApp, window: Window) =
  ## Renders shared toon lighting and alpha-cutout sun shadows.
  let
    left = (if app.showPanel: PanelWidth.int32 + 28 else: 0'i32)
    width = max(1'i32, window.size.x - left)
    height = max(1'i32, window.size.y)
    eye = app.target + vec3(
      sin(app.yaw) * cos(app.pitch), sin(app.pitch),
      cos(app.yaw) * cos(app.pitch)) * app.distance
  app.toon.view = lookAt(eye, app.target, vec3(0, 1, 0))
  app.toon.proj = perspective(42.0'f, width.float32 / height.float32,
    0.05'f, 400.0'f)
  app.toon.cameraPosition = eye
  updateSunMatrix()
  app.toon.lightDirection = -sunDirection
  sunDepthPasses(window.size):
    app.toon.drawSunDepth(app.node)
    for node in app.variants:
      app.toon.drawSunDepth(node)
  glViewport(left, 0, width, height)
  glClearColor(0.76, 0.79, 0.75, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  app.toon.draw(app.ground)
  if app.wireframe:
    glPolygonMode(GL_FRONT_AND_BACK, GL_LINE)
  app.toon.draw(app.node)
  for node in app.variants:
    app.toon.draw(node)
  glPolygonMode(GL_FRONT_AND_BACK, GL_FILL)
  glViewport(0, 0, window.size.x, window.size.y)

proc screenshot(window: Window, path: string) =
  ## Saves a deterministic frame for visual inspection and smoke tests.
  let image = newImage(window.size.x, window.size.y)
  glReadPixels(0, 0, window.size.x, window.size.y, GL_RGBA,
    GL_UNSIGNED_BYTE, image.data[0].addr)
  image.flipVertical()
  image.writeFile(path)

proc main() =
  ## Runs the standalone tree editor or exports a tree without a window.
  let options = optionsFromArgs()
  var settings = preset(options.preset, options.seed)
  if options.loadPath.len > 0:
    settings = loadSettings(options.loadPath)
  settings.validate()
  if options.exportPath.len > 0:
    settings.exportTree(options.exportPath)
    echo "Exported ", options.exportPath
    return
  createDir(UiAtlas.parentDir)
  let builder = newAtlasBuilder(1024, 4)
  builder.addDir(ThemeDirectory & "/", ThemeDirectory & "/")
  builder.addFont(ThemeDirectory / "IBMPlexSans-Regular.ttf", "Default", 16)
  builder.addFont(ThemeDirectory / "IBMPlexSans-Regular.ttf", "H1", 26)
  builder.write(UiAtlas)
  let window = newWindow("Treegen", WindowSize,
    visible = options.frames == 0, vsync = true)
  makeContextCurrent(window)
  loadExtensions()
  initSunShadows(32, 65)
  sunShadowStrength = 0.5'f
  sunShadowSoftness = 2.0'f
  var app = TreeApp(
    sk: newSilky(window, UiAtlas), toon: newToonContext(),
    settings: settings, presetName: PresetNames[options.preset],
    rng: initRand(),
    ground: groundNode(), showPanel: true, gallery: options.gallery,
    yaw: options.yaw, pitch: options.pitch, tab: Canopy)
  if settings.kind == Stump:
    app.tab = Trunk
  app.toon.highlightColor = color(1, 0.97, 0.87, 1)
  app.toon.shadowColor = color(0.38, 0.5, 0.53, 1)
  app.toon.rimColor = color(0.95, 1, 0.85, 0.12)
  app.rebuild()
  app.frameTree()
  var lastTime = epochTime()
  while not window.closeRequested:
    pollEvents()
    let now = epochTime()
    app.handleInput(window, min(0.05'f, (now - lastTime).float32))
    lastTime = now
    let
      galleryChanged = app.gallery != app.builtGallery
      kindChanged = app.settings.kind != app.built.kind
    if app.settings.geometryKey() != app.built.geometryKey() or
      app.settings.barkTexture != app.built.barkTexture or galleryChanged:
        app.rebuild()
        if galleryChanged or kindChanged:
          app.frameTree()
    app.materials.tint(app.settings)
    app.drawScene(window)
    app.drawUi(window)
    inc app.frame
    if options.frames > 0 and app.frame >= options.frames:
      if options.screenshot.len > 0:
        window.screenshot(options.screenshot)
      window.closeRequested = true
    window.swapBuffers()
  app.releaseTrees()
  app.ground.clearFromGpu()
  window.close()

main()
