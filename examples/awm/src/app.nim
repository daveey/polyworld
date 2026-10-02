## What every game mode shares: the window, the renderers, the heroes and
## the class choice. A mode is a client of the core that presents its match
## with these.
import std/[math, options, os]
import chroma, opengl, pixie, silky, vmath, windy
import core/sim, core/sessions, ui/cardfaces, scene/cardrenderer,
  vfx/vfxrenderer, scene/post, scene/table, scene/courtyard, scene/heroes,
  ui/hud, ui/heroselect, scene/heroselectstage, paths, replayer
import polyworld/[assets, characters, chargen, chrome, common, viewers]

const
  WindowTitle = "AWM — Archers Warriors Mages"
  CameraNear* = 0.1'f32
  CameraFar* = 100.0'f32
  ClassChoiceTarget* = HeroSelectCameraTarget

when PostLayerControls:
  const PostLayerKeys*: array[PostLayer, Button] =
    [Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8, Key9, Key0]


type
  App* = ref object
    options*: SessionOptions
    appDir*: string  ## The project folder: players/, the atlas, screenshots.
    window*: Window
    sk*: Silky
    solid*: SolidRenderer
    cards*: CardRenderer
    vfx*: VfxRenderer
    post*: PostFx
    courtyard*: CourtyardRenderer
    selectionStage*: HeroSelectStage
    scene*: CharacterScene
    models*: array[HeroSeats, array[HeroClass, CharacterModel]]
    idleClips*: array[HeroSeats, array[HeroClass, int]]
    deathClips*: array[HeroSeats, array[HeroClass, int]]
    replay*: Replayer  ## Set when watching a recorded match.

proc polyworldRoot(): string =
  var candidates: seq[string]
  let configured = getEnv("POLYWORLD_REPO")
  if configured.len > 0:
    candidates.add configured
  let appDir = getAppDir()
  for base in [appDir, getCurrentDir()]:
    candidates.add base / ".." / ".."
  candidates.add getCurrentDir()
  for candidate in candidates:
    let root = absolutePath(candidate)
    if fileExists(root / "src" / "polyworld" / "common.nim") and
        dirExists(root / ".." / "polyworld_art"):
      return root

proc lightLikeCourtyard*(scene: CharacterScene, cameraSide: float32) =
  ## Gives the heroes the courtyard's lighting: a cool hemisphere ambient,
  ## the same warm key from the same direction, and a moonlit rim that
  ## keeps a dark silhouette readable against dark stone. Call after
  ## beginCharacters, which sets the shared defaults.
  let
    context = scene.context
    # Heroes have no mapped relief, so they take less fill and a stronger
    # key than the stone: shape has to come from the light alone.
    ambient = (CourtyardAmbientGround + CourtyardAmbientSky) * 0.30'f32
    key = CourtyardKeyColor * 1.15'f32
    keyDirection = courtyardKeyDirection(cameraSide)
  context.ambientLightColor =
    color(ambient.x, ambient.y, ambient.z, 1.0)
  # The PBR shader negates the light vectors.
  context.sunLightDirection = -keyDirection
  context.sunLightColor = color(key.x, key.y, key.z, 1.0)
  context.rimLightDirection =
    normalize(vec3(-keyDirection.x, 0.35, -keyDirection.z))
  context.rimLightColor = color(0.55, 0.62, 0.78, 0.30)
  # A daylight probe would wash out a night courtyard, and a hot specular
  # on a hero's head would feed the bloom.
  context.environmentMapStrength = 0.25
  context.exposure = 0.9

proc initApp*(sessionOptions: SessionOptions): App =
  ## Opens the window and loads everything the modes draw with.
  when defined(emscripten):
    let appDir = "/"
    setCurrentDir("/")
  else:
    # The project folder (with players/), one up from src/.
    const sourceDir = currentSourcePath().parentDir.parentDir
    let
      appDir =
        if dirExists(getAppDir() / "players"): getAppDir()
        elif dirExists(sourceDir / "players"): sourceDir
        else: getAppDir()
      root = polyworldRoot()
    if root.len == 0:
      raise newException(IOError,
        "Could not find Polyworld. Set POLYWORLD_REPO to its repository root.")
    setCurrentDir(root)

  let
    cardAssets = artworkRoot() / "cards"
    atlasPath = appDir / "awm.atlas.png"
    atlasBuilder = newHudAtlas(4096)
  initCardAssets(cardAssets)
  atlasBuilder.addBaseCardImages()
  atlasBuilder.addAwmHudAssets(cardAssets)
  when PostPanelControls:
    # Silky's widget images, for the screen-effects tuning window.
    const EditorTheme = DataRoot & "/themes/editor/"
    atlasBuilder.addDir(EditorTheme, EditorTheme)
  atlasBuilder.addFont(cardAssets / "fonts/Grenze-SemiBold.ttf", "H1", 60.0)
  atlasBuilder.addFont(DefaultFontPath, "Default", 34.5)
  atlasBuilder.addFont(DefaultFontPath, "Hud", 28.5)
  atlasBuilder.addFont(DefaultFontPath, "Small", 22.5)
  atlasBuilder.write(atlasPath)

  var window: Window
  var sk: Silky
  (window, sk) = initGameWindow(
    WindowTitle,
    atlasPath,
    ivec2(3200, 2000),
    vsync = true
  )

  var
    solid = initSolidRenderer()
    cardSurfaces = initCardRenderer()
    vfx = initVfxRenderer(cardAssets.parentDir / "vfx" / "textures")
    post = initPostFx()
  var courtyard = initCourtyardRenderer(sessionOptions.playerCount)
  let selectionStage = initHeroSelectStage()
  let scene = newCharacterScene(window)
  # AWM lights heroes with the courtyard's own night rig, not the shared
  # toon ramp: see lightLikeCourtyard.
  scene.shading = PbrCharacters
  var
    models: array[HeroSeats, array[HeroClass, CharacterModel]]
    idleClips: array[HeroSeats, array[HeroClass, int]]
    deathClips: array[HeroSeats, array[HeroClass, int]]
  let
    heroManifest = readManifest(ChargenLibrary)
    heroPresets = readHeroPresets()
  for seat in 0 ..< HeroSeats:
    for heroClass in HeroClass:
      models[seat][heroClass] = heroManifest.loadHeroModel(
        heroPresets[seat][heroClass], heroClass)
      idleClips[seat][heroClass] =
        models[seat][heroClass].clipIndex(HeroIdleClips[heroClass])
      deathClips[seat][heroClass] =
        models[seat][heroClass].clipIndex(HeroDeathClip)
  App(options: sessionOptions, appDir: appDir, window: window, sk: sk,
    solid: solid, cards: cardSurfaces, vfx: vfx, post: post,
    courtyard: courtyard, selectionStage: selectionStage, scene: scene, models: models,
    idleClips: idleClips, deathClips: deathClips)

proc heroClip*(app: App, model: int, heroClass: HeroClass,
    dying, idleTime: float32): tuple[clip: int, time: float32] =
  ## Idle while alive; once dying, the death clip, held on its last
  ## frame.
  if dying < 0:
    (app.idleClips[model][heroClass], idleTime)
  else:
    let clip = app.deathClips[model][heroClass]
    (clip, min(dying,
      app.models[model][heroClass].clipDuration(clip) - 0.001'f32))

proc selectionCamera*(aspect: float32): Vec3 =
  HeroSelectCameraTarget + (HeroSelectCameraEye - HeroSelectCameraTarget) *
    max(1'f32, 1.35'f32 / max(0.1'f32, aspect))

proc drawSelectionHeroes*(app: App, hovered: Option[HeroClass],
    time: float32, cameraEye: Vec3) =
  for heroClass in HeroClass:
    let active = hovered == some(heroClass)
    drawCharacter(app.scene, app.models[0][heroClass],
      HeroSelectPositions[heroClass.ord], 0,
      app.idleClips[0][heroClass], time,
      tint = if active: color(1.18, 1.14, 1.05, 1) else: color(1.05, 1.05, 1.05, 1),
      sizeFactor = SelectionHeroScale * (if active: 1.025'f32 else: 1'f32))
    if active:
      app.vfx.addTargetRing(HeroSelectPositions[heroClass.ord] + vec3(0, 0.03, 0),
        cameraEye, 1.5, 0.8)

template bindApp*(app: App) {.dirty.} =
  ## Names a mode's loop uses for the shared app, so it reads like the rest
  ## of its code: `window`, `sk`, `solid`, `vfx`, `post`...
  bind heroSelectScale, drawHeroSelect, hoveredSelectionHero, selectionCamera
  let
    window = app.window
    sk = app.sk
    scene = app.scene
    sessionOptions = app.options
    appDir = app.appDir
  template solid: untyped = app.solid
  template cardSurfaces: untyped = app.cards
  template vfx: untyped = app.vfx
  template post: untyped = app.post
  template courtyard: untyped = app.courtyard
  template selectionStage: untyped = app.selectionStage
  template models: untyped = app.models
  const
    classChoiceTarget = ClassChoiceTarget
  proc classChoiceEye(aspect: float32): Vec3 = selectionCamera(aspect)
  proc heroClip(model: int, heroClass: HeroClass,
      dying, idleTime: float32): tuple[clip: int, time: float32] =
    app.heroClip(model, heroClass, dying, idleTime)
  proc classSelectionScale(): float32 = heroSelectScale(window)
  proc classSelectionHover(vp: Mat4): Option[HeroClass] =
    hoveredSelectionHero(window, sk.mousePos, vp)
  proc drawClassHeroes(hovered: Option[HeroClass], time: float32, eye: Vec3) =
    app.drawSelectionHeroes(hovered, time, eye)
  proc classSelection(vp: Mat4, human: bool, inputEnabled = true): Option[HeroClass] =
    drawHeroSelect(sk, window, vp, human, inputEnabled)
