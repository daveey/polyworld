## Archers Warriors Mages — Polyworld native and browser client.
import awmsim
export awmsim

when not defined(headless):
  import std/[math, options, os, random, strformat, tables, times]
  when defined(takeScreenshot):
    import std/strutils

when not defined(headless):
  import
    chroma, opengl, pixie, shady, silky, vmath, windy,
    cardfaces, cardrenderer, vfxrenderer, awmsessions, awmweb, awmbots, awmpost,
    awmtable, awmplay,
    awmpostpanel,
    awmcourtyard, awmheroes, awmmultiplayermode, paths,
    awmplacement,
    awmtuning,
    polyworld/[assets, characters, chargen, chrome, common, viewers]

  const
    WindowTitle = "AWM — Archers Warriors Mages"
    BoardWidth = 18.0'f32
    BoardDepth = 11.0'f32
    DuelCamera = Placement(lateral: 0.00, height: 12.05, distance: 13.08,
      pitch: 0.7659, yaw: 0.0000) # pitch 43.9 deg, yaw 0.0 deg
    HeroTargetRadius = 0.95'f32 ## Matches the ring drawn around a hero.
    CameraNear = 0.1'f32
    CameraFar = 100.0'f32
    DuelPlayerHand = Placement(lateral: 0.00, height: 1.25, distance: 5.86,
      pitch: 0.0000, yaw: 0.0000) # pitch 0.0 deg, yaw 0.0 deg
    DuelOpponentHand = Placement(lateral: 0.00, height: 1.52, distance: 3.60,
      pitch: 0.0000, yaw: 0.0000) # pitch 0.0 deg, yaw 0.0 deg
    DuelSpell = Placement(lateral: 0.00, height: 1.60, distance: 0.35,
      pitch: 0.0000, # 0.0 deg down, yaw 0.0 deg
      yaw: 0.0000)
      ## Where a played spell floats: above the board, just past its
      ## caster's creature line.
    HandCardRoll = -0.0684'f32 # About 4 degrees.
    PlayerPanelWidth = 680.0'f32
    PlayerPanelHeight = 140.0'f32

  type
    AppPhase = enum
      ChooseClasses
      PlayGame

    UiRect = object
      origin: Vec2
      size: Vec2

  when PostLayerControls:
    const PostLayerKeys: array[PostLayer, Button] =
      [Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8, Key9, Key0]

  proc contains(rect: UiRect, point: Vec2): bool =
    point.x >= rect.origin.x and
      point.y >= rect.origin.y and
      point.x <= rect.origin.x + rect.size.x and
      point.y <= rect.origin.y + rect.size.y

  proc classUiColor(heroClass: HeroClass): ColorRGBX =
    case heroClass
    of Archer:
      rgbx(70, 205, 102, 255)
    of Warrior:
      rgbx(226, 74, 61, 255)
    of Mage:
      rgbx(76, 121, 236, 255)

  var activeCameraPlayer: proc(): int = proc(): int = 0
    ## The player the camera sits behind, read live: bots and turn changes
    ## flip it mid-frame, and a cached value would build poses facing the
    ## old camera (a drawn card flew in upside down).

  when defined(awmLayoutTuning):
    # Build with -d:awmLayoutTuning to tune the layout live: Z/X pick what to
    # move, WASD/QE move it, T/G pitch it, F/H yaw it, Enter prints it.
    var
      duelCamera = DuelCamera
      duelPlayerHand = DuelPlayerHand
      duelOpponentHand = DuelOpponentHand
      duelSpell = DuelSpell
      tuner = LayoutTuner()
    proc duelTuningTargets(): seq[TuningTarget] =
      @[tuningTarget("player's hand", duelPlayerHand),
        tuningTarget("opponent's hand", duelOpponentHand),
        tuningTarget("camera", duelCamera),
        tuningTarget("played spell", duelSpell)]
  else:
    const
      duelCamera = DuelCamera
      duelPlayerHand = DuelPlayerHand
      duelOpponentHand = DuelOpponentHand
      duelSpell = DuelSpell

  proc seatSide(playerIndex: int): float32 =
    if playerIndex == 0: 1.0'f32 else: -1.0'f32

  proc cardYaw(playerIndex: int): float32 =
    if activeCameraPlayer() == 0: 0.0'f32 else: PI.float32

  proc avatarPosition(playerIndex: int): Vec3 =
    vec3(
      if playerIndex == 0: -7.0'f32 else: 7.0'f32,
      0.02'f32,
      playerIndex.seatSide() * 1.65'f32
    )

  proc handPoses(
      playerIndex,
      count: int,
      cameraSide: float32
  ): seq[CardPose] =
    let
      side = playerIndex.seatSide()
      hand = (
        if side == cameraSide: duelPlayerHand else: duelOpponentHand
      ).mirrored(side)
      camera = duelCamera.mirrored(cameraSide)
      # The near and far hands need different pitches to face the same camera.
      pitch = arctan2(
        camera.distance - hand.distance,
        camera.height - hand.height
      ) + hand.pitch
    fanPoses(count, vec3(hand.lateral, hand.height, hand.distance), pitch,
      cameraSide, playerIndex.cardYaw() + cameraSide * hand.yaw, HandCardRoll)

  proc ownerYaw(playerIndex: int): float32 =
    ## A card on a player's side reads the right way up from their seat.
    if playerIndex == 0: 0.0'f32 else: PI.float32

  proc boardPoses(playerIndex, count: int): seq[CardPose] =
    ## Each player's minions face their owner.
    if count <= 0:
      return
    let
      spacing =
        if count == 1:
          0.0'f32
        else:
          min(1.75'f32, 9.0'f32 / (count - 1).float32)
      start = -spacing * (count - 1).float32 * 0.5'f32
      z = playerIndex.seatSide() * 1.25'f32
    result.setLen(count)
    for i in 0 ..< count:
      result[i] = CardPose(
        position: vec3(start + spacing * i.float32, CardPlaneY, z),
        yaw: playerIndex.ownerYaw()
      )

  proc spellPose(playerIndex: int): CardPose =
    ## A played spell floats over its caster's half, facing its owner.
    let
      side = playerIndex.seatSide()
      spell = duelSpell.mirrored(side)
    CardPose(
      position: vec3(spell.lateral, spell.height, spell.distance),
      yaw: playerIndex.ownerYaw() + side * duelSpell.yaw,
      pitch: duelSpell.pitch
    )

  proc deckPose(playerIndex: int): CardPose =
    CardPose(
      position: vec3(
        -7.25,
        PileCardY,
        playerIndex.seatSide() * 3.7'f32
      ),
      yaw: playerIndex.cardYaw()
    )

  proc discardPose(playerIndex: int): CardPose =
    CardPose(
      position: vec3(
        7.25,
        PileCardY,
        playerIndex.seatSide() * 3.7'f32
      ),
      yaw: playerIndex.cardYaw()
    )

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

  proc lightLikeCourtyard(scene: CharacterScene, cameraSide: float32) =
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

  proc hudScale(window: Window): float32 =
    let density = when defined(emscripten): window.contentScale else: 1.0'f32
    min(density, min(window.size.x.float32 / 2400.0'f32,
      window.size.y.float32 / 1500.0'f32))

  proc hudSize(window: Window): Vec2 =
    window.size.vec2 / max(hudScale(window), 0.01'f32)

  include awmhud

  proc addHudHalo(renderer: var VfxRenderer, window: Window, rect: UiRect,
      time: float32) =
    ## The hovered card's glow (addCardGlow) around a HUD rectangle. Draw it
    ## before post.present, so it blooms the same.
    const HudPixelsPerUnit = 75'f32
      ## The glow reaches as far around a panel as around a card in hand.
    let
      scale = hudScale(window)
      pulse = 0.88'f32 + 0.12'f32 * sin(time * 5)
    renderer.addHudHalo(rect.origin * scale, rect.size * scale,
      HudPixelsPerUnit * scale, HoverGold, pulse * 0.2875'f32)

  proc drawCardReadingView(
      sk: Silky,
      window: Window,
      game: GameState,
      viewProjection: Mat4,
      play: TablePlay,
      layout: TableLayout,
      hoverIndex: int,
      hidden: bool,
      handOwner = -1
  ): bool =
    ## The large preview of the hovered card: in hand, on the board, or on
    ## top of a discard pile.
    if hidden:
      return
    var inspected = inspectedCard(window, viewProjection, game, play, layout,
      hoverIndex, handOwner)
    when defined(takeScreenshot):
      let player = game.players[
        if handOwner >= 0: handOwner else: game.currentPlayer]
      if getEnv("AWM_DEMO_CARD_HOVER") == "1" and player.hand.len > 0:
        inspected.card = player.hand[0]
        inspected.found = true
    if not inspected.found:
      return
    sk.drawCardReading(window, inspected.card, inspected.power,
      inspected.toughness, inspected.lost)

  proc drawDeckLabels(
      sk: Silky,
      window: Window,
      game: GameState,
      viewProjection: Mat4,
      inspectingCard: bool
  ) =
    for playerIndex in 0 ..< PlayerCount:
      for discarded in [false, true]:
        let
          pose = if discarded: discardPose(playerIndex) else: deckPose(playerIndex)
          screen = screenPosition(window,
            pose.position + vec3(0, 0.28'f32, 0), viewProjection) / hudScale(window)
          count = if discarded: game.players[playerIndex].discardPile.len
            else: game.players[playerIndex].deck.len
          origin = screen + vec2(-77, -22)
          inspector = cardReadingRect(window)
        # Hide a whole label when the inspector covers it, rather than
        # leaving a cropped fragment beside the card.
        if inspectingCard and origin.x < inspector.origin.x + inspector.size.x and
            origin.x + 154 > inspector.origin.x and
            origin.y < inspector.origin.y + inspector.size.y and
            origin.y + 44 > inspector.origin.y:
          continue
        sk.hudSprite("pile-label", origin, vec2(154, 44))
        sk.drawLabel((if discarded: "DISCARD " else: "DECK ") & $count,
          origin + vec2(5, 0), vec2(144, 44), HudIvory, "Small", CenterAlign)

  static:
    # Lists the compile-time (-d:) flags while this build compiles.
    proc onOff(on: bool): string = (if on: "ON" else: "OFF")
    const Rule = "-------------------------"
    echo Rule
    echo "Flags"
    echo Rule
    echo " awmPostPanel = ", onOff(PostPanelControls)
    echo " awmPostLayers = ", onOff(PostLayerControls)
    echo " awmLayoutTuning = ", onOff(defined(awmLayoutTuning))
    echo " takeScreenshot = ", onOff(defined(takeScreenshot))
    echo Rule

  proc printHelp() =
    echo "AWM — Archers Warriors Mages\n" &
      "Options (--key value or --key=value):\n" &
      "  --players N      Player count (2). 2 plays the usual game; above 2\n" &
      "                   starts a multiplayer match (turns are mocked).\n" &
      "  --seed INTEGER   Match seed (random when omitted)\n" &
      "  --class CLASS    Your hero class: archer, warrior or mage (archer)\n" &
      "  --opponent CLASS Opponent hero class: archer, warrior or mage (mage)\n" &
      "  --bot PATH       Bot program (.bas), repeatable up to " & $PlayerCount &
        " times. One bot plays\n" &
      "                   both seats; with --human it plays the opponent.\n" &
      "                   Defaults to players/base.bas.\n" &
      "  --human          Play seat 0 yourself instead of watching bots\n" &
      "  -h, --help       Show this help and exit"

  proc runAwm*() =
    if "--help" in commandLineParams() or "-h" in commandLineParams():
      printHelp()
      return
    let sessionOptions = parseSessionOptions(commandLineParams())
    when defined(emscripten):
      let appDir = "/"
      setCurrentDir("/")
    else:
      const sourceDir = currentSourcePath().parentDir
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

    proc heroClip(model: int, heroClass: HeroClass,
        dying, idleTime: float32): tuple[clip: int, time: float32] =
      ## Idle while alive; once dying, the death clip, held on its last
      ## frame.
      if dying < 0:
        (idleClips[model][heroClass], idleTime)
      else:
        let clip = deathClips[model][heroClass]
        (clip, min(dying,
          models[model][heroClass].clipDuration(clip) - 0.001'f32))

    # The class choice, shared by the duel and multiplayer matches.
    let
      classChoiceEye = vec3(0, 6.2, 13.5)
      classChoiceTarget = vec3(0, 1.0, 0)

    proc addClassStage() =
      solid.addBox(
        vec3(0, -0.3, 0),
        vec3(15, 0.55, 7),
        vec4(0.20, 0.24, 0.30, 1),
        sideFactor = 0.5
      )
      for heroClass in HeroClass:
        let x = (heroClass.ord.float32 - 1.0'f32) * 4.2'f32
        solid.addBox(
          vec3(x, 0.05, 0),
          vec3(3.0, 0.18, 3.0),
          heroClass.classColor().darker(0.72),
          sideFactor = 0.55
        )

    proc drawClassHeroes(selected: HeroClass, time: float32) =
      for heroClass in HeroClass:
        let
          x = (heroClass.ord.float32 - 1.0'f32) * 4.2'f32
          chosen = selected == heroClass
        drawCharacter(
          scene,
          models[0][heroClass],
          vec3(x, 0.15, 0),
          0,
          idleClips[0][heroClass],
          time,
          tint =
            if chosen:
              color(1.08, 1.08, 1.08, 1)
            else:
              color(1, 1, 1, 1),
          sizeFactor = if chosen: 1.06'f32 else: 1.0'f32
        )

    proc drawClassHeader(human: bool) =
      sk.drawRect(
        vec2(0),
        vec2(hudSize(window).x, 180),
        rgbx(14, 17, 24, 238)
      )
      sk.drawLabel(
        "ARCHERS | WARRIORS | MAGES",
        vec2(0, 15),
        vec2(hudSize(window).x, 78),
        rgbx(243, 218, 153, 255),
        "H1",
        CenterAlign
      )
      sk.drawLabel(
        (if human: "CHOOSE YOUR CLASS"
         else: "BOTS ARE CHOOSING CLASSES..."),
        vec2(0, 104),
        vec2(hudSize(window).x, 48),
        rgbx(221, 225, 233, 255),
        "Default",
        CenterAlign
      )

    proc classButtons(): Option[HeroClass] =
      ## The human's class buttons; returns the class clicked this frame.
      for heroClass in HeroClass:
        let
          x = hudSize(window).x * 0.5'f32 +
            (heroClass.ord.float32 - 1.0'f32) * 400.0'f32
          rect = UiRect(
            origin: vec2(x - 140, hudSize(window).y - 180),
            size: vec2(280, 84)
          )
        if drawButton(
            sk,
            window,
            rect,
            heroClass.className()
        ):
          result = some(heroClass)

    if sessionOptions.playerCount > PlayerCount:
      # The multiplayer mode (awmmultiplayermode) runs the match on the core;
      # this loop presents it through the shared table (awmplay), like the
      # duel. The camera never moves. With --human P1 plays and nothing
      # turns; otherwise we spectate and the balconies turn around the
      # static center to bring whoever's turn it is in front of the camera.
      let layout = buildMultiplayerLayout(sessionOptions.playerCount)
      var
        previewTime = 0.0'f32
        previewLastFrame = epochTime()
        seatRng =
          if sessionOptions.seedGiven or defined(takeScreenshot):
            initRand(sessionOptions.seed)
          else: initRand()
        match: MultiplayerMatch
        play = initTablePlay()
        choosingClasses = true
        chosenClass = sessionOptions.playerClass
        botClassWait = 1.5'f32
        orbit = initSeatOrbit(layout.balconies[0].yaw)
        openingDraw = false  ## Every seat's opening hand should fly in.
        botClock = initBotClock()
        botSources: seq[string]
          ## The bot scripts for the seats that aren't the human's, taken in
          ## turn: the --bot scripts, else the reference bot.
        uiCapturesMouse = false  ## The pointer is over a tuning window.
      when defined(takeScreenshot):
        var playDemoDone = false
      template gamePressed(button: Button): bool =
        ## A press the table should react to (not one meant for a window).
        window.buttonPressed[button] and not uiCapturesMouse
      proc startMatch(humanClass: Option[HeroClass]) =
        var classes = newSeq[HeroClass](layout.playerCount)
        for seat in 0 ..< layout.playerCount:
          classes[seat] = seatRng.rand(HeroClass)
        if humanClass.isSome:
          classes[0] = humanClass.get
        chosenClass = classes[0]
        choosingClasses = false
        match = newMultiplayerMatch(classes,
          humanSeat = if humanClass.isSome: 0 else: -1,
          seed = seatRng.rand(high(int)).int64, botSources = botSources)
        botClock = initBotClock()
        orbit = initSeatOrbit(layout.balconies[match.viewedSeat].yaw)
        play.resetTable()
        play.animations.setLen(0)
        play.statusMessage = match.turnStatus
        # As in the duel, every seat's hand is dealt card by card.
        openingDraw = true
      proc turnPassed() =
        orbit.aimAt(layout.balconies[match.viewedSeat].yaw)
        play.statusMessage = match.turnStatus
      for path in sessionOptions.botPaths:
        botSources.add readFile(path)
      if botSources.len == 0 and fileExists(appDir / "players" / "base.bas"):
        botSources.add readFile(appDir / "players" / "base.bas")
      if getEnv("AWM_AUTOSTART") == "1":
        startMatch(if sessionOptions.human: some(sessionOptions.playerClass)
          else: none(HeroClass))
      when defined(takeScreenshot):
        var previewScreenshotFrame = 0
      when defined(awmLayoutTuning):
        # The duel's layout keys: the viewed seat's hand is the player's one
        # and every other balcony's is an opponent's. Enter prints a row.
        var
          tuner = LayoutTuner()
          previewView = layout.multiplayerView(
            window.size.x.float32 / max(window.size.y.float32, 1))
        tuner.announce([tuningTarget("player's hand", previewView.nearHand),
          tuningTarget("opponent's hand", previewView.farHand),
          tuningTarget("camera", previewView.camera)])
      window.onFrame = proc() =
        let previewDt = frameDelta(previewLastFrame)
        previewTime += previewDt
        play.animations.advanceAnimations(previewDt)
        play.discardFlights.advanceAnimations(previewDt)
        play.activeVfx.advance(previewDt)
        sk.uiScale = hudScale(window)
        sk.mousePos = window.mousePos.vec2 / max(sk.uiScale, 0.01'f32)
        when PostPanelControls:
          uiCapturesMouse = mouseOverPostPanel(sk.mousePos)
        let aspect = window.size.x.float32 / max(window.size.y.float32, 1)
        when defined(awmLayoutTuning):
          tuner.tune(window, previewDt,
            [tuningTarget("player's hand", previewView.nearHand),
             tuningTarget("opponent's hand", previewView.farHand),
             tuningTarget("camera", previewView.camera)])
          if window.buttonPressed[KeyEnter]:
            echo previewView.tunedRow(layout.playerCount)
        else:
          let previewView = layout.multiplayerView(aspect)
        if choosingClasses:
          if not sessionOptions.human:
            botClassWait -= previewDt
            if botClassWait <= 0:
              startMatch(none(HeroClass))
        let table = seatTable(layout, previewView, match.viewedSeat,
          match.humanSeat)
        if not choosingClasses:
          # The bots play their seats, the same way they play the duel.
          if play.updateBots(match.game, table, match.bots, botClock,
              proc(): bool = match.humanActs, previewDt):
            turnPassed()
          if play.presentationIdle(match.game) and not play.attackActive and
              match.skipDeadTurn():
            turnPassed()
          orbit.advance(previewDt)
        if not choosingClasses and openingDraw:
          play.addOpeningHands(match.game, table)
          openingDraw = false
        when defined(takeScreenshot):
          # AWM_DEMO_MP_PLAY=target|bolt|sharpshooter|select|attack|fight: on
          # the human's turn, a Bear enters the board, then the named card is
          # played the way a click plays it (target: Bolt waits for a hero),
          # or a ready Bear is selected to attack (attack: seat 3's hero;
          # fight: seat 4's Footsoldier).
          let demo = getEnv("AWM_DEMO_MP_PLAY")
          if demo.len > 0 and not choosingClasses and not playDemoDone and
              match.humanSeat >= 0:
            playDemoDone = true
            template game: untyped = match.game
            while not match.humanTurn:
              discard match.endTurn()
            discard game.takeVisualEvents()
            play.animations.setLen(0)
            game.players[0].energy = 10
            game.players[0].totalEnergy = 10
            game.players[0].hand = @[baseCardNamed("Bear"),
              baseCardNamed("Bolt"), baseCardNamed("Sharpshooter")]
            game.players[2].board = @[MinionState(id: game.nextMinionId,
              owner: 2, card: baseCardNamed("Sniper"), currentToughness: 1)]
            inc game.nextMinionId
            discard play.playHandCard(game, table, 0)
            case demo
            of "target":
              discard play.playHandCard(game, table, 0)
            of "bolt":
              play.pendingCard = game.players[0].hand[0]
              play.pendingCardIndex = 0
              play.pendingChoices = game.availableChoices(0)
              play.pendingTargeting = true
              play.animations.setLen(0)
              discard game.playCard(0, heroChoice(2))
              play.stopTargeting()
            of "sharpshooter":
              discard play.playHandCard(game, table, 1)
            of "death", "win":
              # Bolts at players at 2 life: one death, or every opponent.
              play.animations.setLen(0)
              let victims = if demo == "death": @[2] else: @[1, 2, 3]
              for seat in victims:
                game.players[seat].life = 2
                game.players[0].hand.add baseCardNamed("Bolt")
                discard game.playCard(game.players[0].hand.high,
                  heroChoice(seat))
            of "select", "attack", "fight":
              # A second Bear, ready since last turn, and a Footsoldier on
              # the balcony to the right.
              let ready = game.nextMinionId
              game.players[0].board.add MinionState(id: ready, owner: 0,
                card: baseCardNamed("Bear"), currentToughness: 2,
                canAttack: true)
              let footsoldier = ready + 1
              game.players[3].board.add MinionState(id: footsoldier,
                owner: 3, card: baseCardNamed("Footsoldier"),
                currentToughness: 2)
              game.nextMinionId = ready + 2
              play.animations.setLen(0)
              play.selectedAttacker = ready
              if demo == "attack":
                play.startAttack(game, table, @[ready], heroChoice(2))
              elif demo == "fight":
                play.startAttack(game, table, @[ready],
                  creatureChoice(3, footsoldier))
            else: discard
        let
          camera = previewView.camera
          eye =
            if choosingClasses: classChoiceEye
            else: camera.eye
          target =
            if choosingClasses: classChoiceTarget
            else: camera.target
          view = lookAt(eye, target, vec3(0, 1, 0))
          farPlane = max(CameraFar, length(eye) * 3)
          projection = perspective(42.0'f32, aspect, CameraNear, farPlane)
          vp = projection * view
          # The balconies, their cards and heroes render through the stage
          # turn; the center island and the sky stay put.
          stageYaw = if choosingClasses: 0'f32 else: orbit.yaw
          stage = stageRotation(stageYaw)
          stageView = view * stage
          stageVp = projection * stageView
          stageEye = (stage.inverse * vec4(eye.x, eye.y, eye.z, 1)).xyz
          environmentTime =
            when defined(takeScreenshot):
              parseFloat(getEnv("AWM_SCENE_TIME", $previewTime)).float32
            else: previewTime
        var
          hoverIndex = -1
          hoveredTarget = Canceled
          hoveredBoard = Canceled
        if not choosingClasses:
          template game: untyped = match.game
          if play.tossPicking:
            hoverIndex = hoveredCard(window, stageVp, game, table,
              handOwner = game.pendingToss.player)
          elif match.current == match.viewedSeat:
            hoverIndex = hoveredCard(window, stageVp, game, table,
              handOwner = match.viewedSeat)
          if hoverIndex < 0:
            var boardChoices: seq[Choice]
            for owner in 0 ..< game.playerCount:
              for minion in game.players[owner].board:
                if not play.animations.boardCardSuppressed(minion.id) and
                    not play.queuedEvents.queuedSummon(minion.id):
                  boardChoices.add creatureChoice(owner, minion.id)
            hoveredBoard = hoveredCreatureTarget(window, stageVp, game, play,
              table, boardChoices)
          let pick = gamePressed(MouseLeft) and
            not (match.humanSeat >= 0 and
              finishRect(window).contains(sk.mousePos))
          let cancel = window.buttonPressed[KeyEscape] or
            gamePressed(MouseRight)
          if play.tossPicking and match.humanActs and
              play.presentationIdle(game) and not game.gameOver:
            play.updateTossPicking(game, hoverIndex,
              pick = gamePressed(MouseLeft), clear = cancel)
          elif match.humanTurn and play.presentationIdle(game) and
              not play.pendingTargeting and not play.attackActive and
              not game.gameOver:
            if hoverIndex >= 0 and pick:
              if play.playHandCard(game, table, hoverIndex):
                hoverIndex = -1
            else:
              # Pick one of your minions, then any opponent's minion or hero.
              play.updateAttack(game, table, window, stageVp, hoveredBoard,
                pick, cancel)
          elif match.humanActs and play.pendingTargeting and
              play.presentationIdle(game) and not game.gameOver:
            hoveredTarget = play.updateTargeting(game, table, window,
              stageVp, hoverIndex, pick, cancel)
          when defined(takeScreenshot):
            if getEnv("AWM_CAPTURE_NO_HOVER") == "1":
              hoverIndex = -1
              hoveredBoard = Canceled
              hoveredTarget = Canceled
            elif getEnv("AWM_DEMO_CARD_HOVER") == "1" and
                match.current == match.viewedSeat and
                game.players[match.viewedSeat].hand.len > 0:
              hoverIndex = 0
          play.presentVisualEvents(game, table, previewTime)
        var attackHoverTarget = Canceled
        let attackChoices =
          if choosingClasses: newSeq[Choice]()
          else: play.attackChoices(match.game)
        if match.humanTurn and attackChoices.len > 0 and
            not play.pendingTargeting and play.presentationIdle(match.game):
          attackHoverTarget = hoveredWorldTarget(window, stageVp, match.game,
            play, table, attackChoices)
        let inspected =
          if choosingClasses: (found: false, card: Card(), power: -1,
            toughness: -1, lost: set[Keyword]({}))
          else: inspectedCard(window, stageVp, match.game, play, table,
            hoverIndex,
            if play.tossPicking: match.game.pendingToss.player
            else: match.viewedSeat)
        if window.buttonPressed[KeyF8]:
          post.settings.enabled = not post.settings.enabled
        when PostLayerControls:
          for layer in PostLayer:
            if window.buttonPressed[PostLayerKeys[layer]]:
              post.layer = layer
              post.settings.enabled = true
        post.beginScene(window.size, CameraNear, farPlane)
        glClearColor(0.035, 0.045, 0.065, 1)
        glStencilMask(0xff)
        glClearStencil(0)
        glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT or GL_STENCIL_BUFFER_BIT)
        solid.clear()
        cardSurfaces.clear()
        vfx.clear()
        if choosingClasses:
          addClassStage()
          solid.draw(vp)
        else:
          courtyard.draw(vp, eye, environmentTime, 1, stageYaw = stageYaw)
          courtyard.drawSky(vp, eye, environmentTime)
          addTableCards(solid, cardSurfaces, vfx, sk, play, match.game, table,
            previewTime, match.viewedSeat, hoverIndex, hoveredBoard,
            match.humanTurn, attackChoices, play.selectedAttacker,
            play.lungingMinion())
          addAttackCard(solid, cardSurfaces, vfx, sk, play, match.game, table,
            previewTime)
          solid.draw(stageVp)
          cardSurfaces.draw(sk, stageVp)
        beginCharacters(scene, window, stageView, projection, stageEye)
        scene.lightLikeCourtyard(1)
        if choosingClasses:
          drawClassHeroes(chosenClass, previewTime)
        else:
          glEnable(GL_STENCIL_TEST)
          glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE)
          for balcony in layout.balconies:
            let
              seat = balcony.playerIndex
              heroClass = match.seats[seat].heroClass
              model = seat mod HeroSeats
              look = play.heroLook(match.game, seat, hoveredTarget,
                attackChoices, attackHoverTarget)
            glStencilFunc(GL_ALWAYS, (seat + 1).GLint, 0xff)
            if look.targetable:
              vfx.addTargetRing(table.heroPosition(seat) + vec3(0, 0.04, 0),
                stageEye, 0.95, if look.hovered: 1.1'f32 else: 0.28'f32)
            let pose = heroClip(model, heroClass,
              play.deathClock(match.game, seat, previewTime), environmentTime)
            drawCharacter(scene, models[model][heroClass],
              table.heroPosition(seat), PI.float32 - balcony.yaw,
              pose.clip, pose.time,
              tint = look.tint, sizeFactor = look.sizeFactor)
        finishCharacters(scene)
        glDisable(GL_STENCIL_TEST)
        if not choosingClasses and post.beginMaterialNormals():
          courtyard.draw(vp, eye, environmentTime, 1,
            normalsOnly = true, normalView = view, stageYaw = stageYaw)
          post.endMaterialNormals()
        post.applyOcclusion(projection)
        let panelsBottom =
          if match.humanSeat >= 0: finishRect(window).origin.y - 18
          else: hudSize(window).y - 18
        if not choosingClasses:
          for seat in 0 ..< match.seats.len:
            vfx.drawCharacterFlash(seat + 1,
              play.activeVfx.flashStrength(heroChoice(seat)))
          vfx.addAttackRing(play, stageEye)
          vfx.addEffects(play.activeVfx, stageEye)
          vfx.draw(stageVp)
          if not inspected.found:
            # The current player's panel glows like a hovered card. The
            # panels and their glow hide while the inspector is open.
            vfx.clear()
            vfx.addHudHalo(window, playerPanelColumnRect(window,
              match.seats.len, match.current, panelsBottom), previewTime)
            vfx.draw(hudHaloProjection(window.size.vec2), depthTest = false)
        post.present(window.size)

        glDisable(GL_DEPTH_TEST)
        glDisable(GL_CULL_FACE)
        glDisable(GL_BLEND)
        when not defined(emscripten):
          glDisable(GL_MULTISAMPLE)
        glActiveTexture(GL_TEXTURE0)
        glBindTexture(GL_TEXTURE_2D, sk.atlasTextureId())
        sk.beginUi(window, window.size)
        if choosingClasses:
          drawClassHeader(sessionOptions.human)
          if sessionOptions.human:
            let picked = classButtons()
            if picked.isSome:
              startMatch(picked)
        else:
          # The inspector takes the panels' place while it is open.
          if inspected.found:
            discard sk.drawCardReading(
              cardReadingColumnRect(window, panelsBottom), inspected.card,
              inspected.power, inspected.toughness, inspected.lost)
          else:
            sk.drawPlayerPanelColumn(window, match.seats, match.current,
              match.humanSeat, panelsBottom, previewTime)
          # The turn header and prompts center on the space left of the
          # panels.
          let
            columnX = playerPanelColumnX(window)
            centerX = columnX * 0.5'f32
          sk.drawTurnHeader(centerX, min(920'f32, columnX - 104),
            match.turnNumber, match.turnLabel, match.humanTurn,
            if match.game.gameOver: match.turnStatus else: play.statusMessage)
          sk.drawTossPrompt(window, play, match.game, centerX)
          sk.drawTargetPrompt(window, play, match.game, centerX)
          sk.drawCombatPrompt(window, play, match.game, centerX)
          if not play.attackActive:
            sk.drawMatchResult(window, play, match.game, match.humanSeat,
              centerX)
          sk.drawLabel(play.playHelp(match.humanSeat >= 0),
            vec2(32, hudSize(window).y - 66), vec2(820, 42), HudMuted, "Small")
        if not choosingClasses and match.humanSeat >= 0:
          let
            yourTurn = match.humanTurn
            canFinish = yourTurn and not match.game.waitingChoice and
              not play.pendingTargeting and not play.attackActive and
              not match.game.gameOver and play.presentationIdle(match.game) and
              not openingDraw
          if drawEndTurnButton(sk, window,
              (if match.game.gameOver: "MATCH ENDED"
               elif yourTurn: "END TURN" else: "OPPONENT"), canFinish):
            play.stopTargeting()
            play.selectedAttacker = 0
            if match.endTurn():
              turnPassed()
        when defined(emscripten):
          publishStatus((&"Multiplayer match: {layout.playerCount} players. " &
            play.statusMessage).cstring)
        when PostPanelControls:
          drawPostPanel(sk, window, post, courtyard)
        sk.endUi()
        when defined(takeScreenshot):
          captureScreenshot(window, previewScreenshotFrame,
            max(1, parseInt(getEnv("AWM_CAPTURE_FRAME", "20"))),
            appDir / &"awm_multiplayer_{layout.playerCount}.png")
        window.swapBuffers()
      while not window.closeRequested:
        pollEvents()
      return

    var
      phase = ChooseClasses
      selectedClass: HeroClass
      game: GameState
      # Captures can replay a cast from its visual seed.
      play = when defined(takeScreenshot):
        initTablePlay(parseBiggestInt(getEnv("AWM_VFX_SEED", "20260909")))
      else:
        initTablePlay()
      animationTime = 0.0'f32
      lastFrameTime = epochTime()
      botClock = initBotClock()
      botClassWait = 1.5'f32
    var
      botVms: seq[BotVm]
      seedRng = initRand()
      uiCapturesMouse = false  ## The pointer is over a tuning window.

    template gamePressed(button: Button): bool =
      ## A press the board should react to (not one meant for a window).
      window.buttonPressed[button] and not uiCapturesMouse

    proc gameSeed(): int64 =
      ## --seed replays one deal; otherwise every game gets a fresh one.
      when defined(takeScreenshot):
        return sessionOptions.seed
      if sessionOptions.seedGiven:
        return sessionOptions.seed
      result = seedRng.rand(high(int)).int64
      echo "AWM seed ", result, " (replay with --seed ", result, ")"

    proc cameraPlayer(): int =
      if sessionOptions.human or phase == ChooseClasses: 0
      else: game.currentPlayer

    activeCameraPlayer = cameraPlayer

    proc handVisible(owner: int): bool =
      owner == cameraPlayer()

    let duelLayout = TableLayout(
      handPoses: proc(player, count: int): seq[CardPose] =
        handPoses(player, count, cameraPlayer().seatSide()),
      boardPoses: boardPoses,
      deckPose: deckPose,
      discardPose: discardPose,
      spellPose: spellPose,
      heroPosition: avatarPosition,
      handVisible: handVisible,
      overBoard: proc(point: Vec3): bool =
        abs(point.x) <= BoardWidth * 0.5'f32 and
          abs(point.z) <= BoardDepth * 0.5'f32,
      heroLungePoint: proc(fromPose: CardPose, hero: Vec3): Vec3 =
        # Toward the middle of the hero's side, clear of the other cards.
        vec3(fromPose.position.x * 0.3, CardPlaneY + 0.3, hero.z * 0.7))

    proc humanTurn(): bool =
      sessionOptions.human and botVms[game.currentPlayer] == nil

    proc humanActs(): bool =
      ## The human must act now: on their turn, or answering their trigger.
      sessionOptions.human and botVms[game.actingPlayer()] == nil

    block:
      var sources: array[PlayerCount, string]
      if sessionOptions.botPaths.len > 0:
        if sessionOptions.human:
          for i in 0 ..< min(sessionOptions.botPaths.len, PlayerCount - 1):
            sources[i + 1] = readFile(sessionOptions.botPaths[i])
        elif sessionOptions.botPaths.len == 1:
          let src = readFile(sessionOptions.botPaths[0])
          sources[0] = src
          sources[1] = src
        else:
          for i in 0 ..< min(sessionOptions.botPaths.len, PlayerCount):
            sources[i] = readFile(sessionOptions.botPaths[i])
      else:
        let defaultBot = appDir / "players" / "base.bas"
        if fileExists(defaultBot):
          let src = readFile(defaultBot)
          if not sessionOptions.human:
            sources = [src, src]
          else:
            sources[1] = src
      botVms = loadBots(sources)

    if sessionOptions.human:
      phase = ChooseClasses
      play.statusMessage = "Choose your class."
    else:
      phase = ChooseClasses
      play.statusMessage = "Bots are choosing classes..."

    when defined(takeScreenshot):
      var screenshotFrame = 0
    if getEnv("AWM_AUTOSTART") == "1":
      game = newGame(Archer, Mage, 20260904)
      phase = PlayGame
      play.addOpeningHands(game, duelLayout)
      play.statusMessage =
        &"Player {game.currentPlayer + 1} begins."
    when defined(takeScreenshot):
      if getEnv("AWM_DEMO_BOARD") == "1":
        play.animations.setLen(0)
        let creatureTargetDemo =
          getEnv("AWM_DEMO_CREATURE_TARGET") == "1"
        game.currentPlayer = 0
        if creatureTargetDemo:
          game.players[0].heroClass = Mage
          game.players[1].heroClass = Warrior
        game.players[0].energy = 1
        game.players[0].totalEnergy = 1
        game.players[0].hand = @[
          if creatureTargetDemo:
            Mage.classCard()
          else:
            Archer.classCard()
        ]
        game.players[0].board = @[
          MinionState(
            id: 1,
            owner: 0,
            card: Mage.classCard(),
            currentToughness: 1
          )
        ]
        game.players[1].board = @[
          MinionState(
            id: 2,
            owner: 1,
            card: Warrior.classCard(),
            currentToughness: 2
          )
        ]
        game.nextMinionId = 3
        # AWM_DEMO_ENEMY_BOARD: that many enemy cards, alternating Snipers
        # (which die to 1 damage) and Bears.
        let enemyCards = parseInt(getEnv("AWM_DEMO_ENEMY_BOARD", "0"))
        if enemyCards > 0:
          game.players[1].board.setLen(0)
          for i in 0 ..< enemyCards:
            let card =
              if i mod 2 == 0: baseCard("sniper-2") else: Warrior.classCard()
            game.players[1].board.add MinionState(id: 10 + i, owner: 1,
              card: card, currentToughness: card.toughness)
          game.nextMinionId = 10 + enemyCards
        play.statusMessage =
          if creatureTargetDemo:
            "Demo board: Bouncer can target any minion, including itself."
          else:
            "Demo board: Bolt can target either hero."
        if getEnv("AWM_DEMO_TARGET") == "1":
          play.pendingCard = game.players[0].hand[0]
          play.pendingTargeting = true
          if creatureTargetDemo:
            let
              sourcePose = handPoses(0, 1, 1.0'f32)[0]
              minionId = game.playMinion(0)
              destinationPose =
                boardPoses(0, game.players[0].board.len)[^1]
            play.animations.add newCardAnimation(
              play.pendingCard,
              game.players[0].heroClass,
              sourcePose,
              destinationPose,
              suppressBoardId = minionId
            )
            play.pendingCardIndex = -1
            play.pendingChoices = game.availableChoices(play.pendingCard)
          else:
            play.pendingCardIndex = 0
            play.pendingChoices = game.availableChoices(0)
        elif getEnv("AWM_DEMO_DISCARD_ANIMATION") == "1":
          let
            card = game.players[0].hand[0]
            sourcePose = handPoses(0, 1, 1.0'f32)[0]
          if game.playCard(0, heroChoice(1)):
            play.animations.add newCardAnimation(
              card,
              game.players[0].heroClass,
              sourcePose,
              stackTopPose(
                discardPose(0),
                game.players[0].discardPile.len
              ),
              suppressDiscardOwner = 0
            )
            play.statusMessage = "Demo animation: Bolt moves to discard."
        elif getEnv("AWM_DEMO_BOUNCE_ANIMATION") == "1":
          if game.runMinionRules(
              Mage.classCard(),
              creatureChoice(1, 2)
          ):
            play.statusMessage = "Demo animation: Bear returns to hand."

        if getEnv("AWM_DEMO_CARD_SET") == "1":
          play.animations.setLen(0)
          game.players[0].hand = @[
            Archer.classCard(), Warrior.classCard(), Mage.classCard()
          ]
          game.players[0].energy = 3
          game.players[0].totalEnergy = 3
          play.statusMessage = "Hover a card to inspect its artwork and rules."
        if getEnv("AWM_DEMO_PLAYER_TWO") == "1":
          play.animations.setLen(0)
          game.currentPlayer = 1
        if getEnv("AWM_DEMO_SWORDS") == "1":
          # One Bear already buffed, one damaged: Swords raises both.
          play.animations.setLen(0)
          game.players[0].heroClass = Warrior
          game.players[0].board = @[
            MinionState(id: 1, owner: 0, card: Warrior.classCard(),
              currentToughness: 2, bonusPower: 1),
            MinionState(id: 3, owner: 0, card: Warrior.classCard(),
              currentToughness: 1)
          ]
          game.nextMinionId = 4
          # AWM_DEMO_SPELL picks another board-wide spell, e.g. shields-1.
          game.players[0].hand =
            @[baseCard(getEnv("AWM_DEMO_SPELL", "swords-2"))]
          game.players[0].energy = 5
          game.players[0].totalEnergy = 5
          let spell = game.players[0].hand[0]
          if game.playCard(0):
            play.statusMessage = &"Demo: {spell.name} resolves."
        if getEnv("AWM_DEMO_DUEL") == "1":
          # A Bear duels a sturdy Sniper that loses Ranged and survives.
          play.animations.setLen(0)
          game.players[0].heroClass = Warrior
          game.players[1].heroClass = Archer
          game.players[0].board = @[MinionState(id: 1, owner: 0,
            card: Warrior.classCard(), currentToughness: 2)]
          game.players[1].board = @[MinionState(id: 2, owner: 1,
            card: baseCard("sniper-2"), currentToughness: 5)]
          game.nextMinionId = 3
          game.players[0].hand = @[baseCard("duel-2")]
          game.players[0].energy = 2
          game.players[0].totalEnergy = 2
          if game.playCard(0, @[creatureChoice(0, 1), creatureChoice(1, 2)]):
            play.statusMessage = "Demo: Duel."
        if getEnv("AWM_DEMO_TACTICIAN") == "1":
          # Tactician enters and weakens the enemy Bear.
          play.animations.setLen(0)
          game.players[0].heroClass = Warrior
          game.players[0].hand = @[baseCard("tactician-2")]
          game.players[0].energy = 2
          game.players[0].totalEnergy = 2
          if game.playCard(0, creatureChoice(1, 2)):
            play.statusMessage = "Demo: Tactician."
        if getEnv("AWM_DEMO_OOZIFICATION") == "1":
          # Oozification destroys the enemy Bear (toughness 2): its owner
          # gets two Oozes.
          # AWM_DEMO_OOZE_TARGET picks which enemy card (see
          # AWM_DEMO_ENEMY_BOARD).
          play.animations.setLen(0)
          let targetIndex = parseInt(getEnv("AWM_DEMO_OOZE_TARGET", "0"))
          game.players[0].hand = @[baseCard("oozification-4")]
          game.players[0].energy = 4
          game.players[0].totalEnergy = 4
          let targetId = game.players[1].board[targetIndex].id
          if game.playCard(0, creatureChoice(1, targetId)):
            play.statusMessage = "Demo: Oozification."
        if getEnv("AWM_DEMO_PLAN") == "1":
          # Plan enters the board as a trinket and draws a card.
          play.animations.setLen(0)
          game.players[0].heroClass = Mage
          game.players[0].hand = @[baseCard("plan-3")]
          game.players[0].energy = 3
          game.players[0].totalEnergy = 3
          if game.playCard(0):
            play.statusMessage = "Demo: Plan."
        if getEnv("AWM_DEMO_STUDY") == "1":
          # Study draws two, then player 1 chooses a card to discard.
          play.animations.setLen(0)
          game.players[0].heroClass = Mage
          game.players[0].hand = @[baseCard("study-2"), baseCard("bouncer-1"),
            baseCard("plan-3")]
          game.players[0].energy = 2
          game.players[0].totalEnergy = 2
          if game.playCard(0):
            play.statusMessage = "Demo: Study."
        if getEnv("AWM_DEMO_BUBBLE") == "1":
          # Player 2's Bear attacks player 1's hero, guarded by two Bubbles.
          play.animations.setLen(0)
          game.players[0].heroClass = Mage
          for id in [5, 6]:
            game.players[0].board.add MinionState(id: id, owner: 0,
              card: baseCard("bubble-0"), enteredTurn: game.turnNumber)
          game.nextMinionId = 7
          game.players[1].board = @[MinionState(id: 2, owner: 1,
            card: Warrior.classCard(), currentToughness: 2, canAttack: true)]
          game.players[1].hand.setLen(0)
          game.currentPlayer = 1
          play.statusMessage = "Demo: Bubble."
        if getEnv("AWM_DEMO_PRIMORDIAL") == "1":
          # Primordial returns every other card, Plan included, to its
          # owner's hand (see AWM_DEMO_ENEMY_BOARD for the other side).
          play.animations.setLen(0)
          game.players[0].heroClass = Mage
          game.players[0].board.add MinionState(id: 5, owner: 0,
            card: baseCard("plan-3"), enteredTurn: game.turnNumber)
          game.nextMinionId = max(game.nextMinionId, 6)
          game.players[0].hand = @[baseCard("primordial-8")]
          game.players[0].energy = 10
          game.players[0].totalEnergy = 10
          if game.playCard(0):
            play.statusMessage = "Demo: Primordial."
        if getEnv("AWM_DEMO_SHARPSHOOTER_TARGET").len > 0:
          # Sharpshooter enters and shoots that enemy card.
          play.animations.setLen(0)
          let index = parseInt(getEnv("AWM_DEMO_SHARPSHOOTER_TARGET"))
          game.players[0].hand = @[baseCard("sharpshooter-3")]
          game.players[0].energy = 3
          game.players[0].totalEnergy = 3
          if game.playCard(0,
              creatureChoice(1, game.players[1].board[index].id)):
            play.statusMessage = "Demo: Sharpshooter."
        if getEnv("AWM_DEMO_PLAN_TRIGGER") == "1":
          # Plan fires at the start of player 1's next turn: the turn draw,
          # Plan's draw 0.25 s later, then Plan is destroyed.
          play.animations.setLen(0)
          game.players[0].heroClass = Mage
          game.players[0].board.add MinionState(id: 3, owner: 0,
            card: baseCard("plan-3"), enteredTurn: game.turnNumber)
          game.nextMinionId = 4
          game.finishTurn()
          discard game.takeVisualEvents()
          game.finishTurn()
          play.statusMessage = "Demo: Plan's trigger."
        if getEnv("AWM_DEMO_TRIGGER_TARGET") == "1":
          # A trinket's trigger waits for player 1 to pick its target.
          play.animations.setLen(0)
          let snare = Card(name: "Snare", energyCost: 0, kind: Trinket,
            class: some(Mage),
            rules: rules(on(nextTurn(You), damage(1, target({TargetKind.Minion})))))
          game.players[0].board.add MinionState(id: 3, owner: 0, card: snare,
            enteredTurn: game.turnNumber - 2)
          game.nextMinionId = 4
          game.pendingTriggers = @[PendingTrigger(owner: 0, sourceId: 3,
            trigger: 0)]

    when defined(awmLayoutTuning):
      tuner.announce(duelTuningTargets())

    window.onFrame = proc() =
      let dt = frameDelta(lastFrameTime)
      when defined(awmLayoutTuning):
        # Provisional controls for dialing in the camera and the hands.
        tuner.tune(window, dt, duelTuningTargets())
        if window.buttonPressed[KeyEnter]:
          echo &"""
    DuelCamera = {duelCamera.literal()}
    DuelPlayerHand = {duelPlayerHand.literal()}
    DuelOpponentHand = {duelOpponentHand.literal()}
    DuelSpell = {duelSpell.literal()}"""
      animationTime += dt
      play.animations.advanceAnimations(dt)
      play.discardFlights.advanceAnimations(dt)
      play.activeVfx.advance(dt)
      sk.uiScale = hudScale(window)
      sk.mousePos = window.mousePos.vec2 / sk.uiScale
      when PostPanelControls:
        uiCapturesMouse = mouseOverPostPanel(sk.mousePos)

      if phase == ChooseClasses and not sessionOptions.human:
        botClassWait -= dt
        if botClassWait <= 0:
          let
            playerClass = play.visualRng.rand(HeroClass)
            opponentClass = play.visualRng.rand(HeroClass)
          selectedClass = playerClass
          game = newGame(playerClass, opponentClass, gameSeed())
          play.resetTable()
          phase = PlayGame
          play.addOpeningHands(game, duelLayout)
          botClock.wait = 1.2'f32
          botClock.plays = 0
          play.statusMessage = "Watching bot match..."

      if phase == PlayGame:
        discard play.updateBots(game, duelLayout, botVms, botClock, humanActs,
          dt)

      let
        aspect = window.size.x.float32 / max(window.size.y.float32, 1)
        currentSide =
          if phase == PlayGame:
            cameraPlayer().seatSide()
          else:
            1.0'f32
        cameraEye =
          if phase == ChooseClasses:
            classChoiceEye
          else:
            duelCamera.seatEye(currentSide)
        cameraTarget =
          if phase == ChooseClasses:
            classChoiceTarget
          else:
            duelCamera.seatTarget(currentSide)
        view = lookAt(cameraEye, cameraTarget, vec3(0, 1, 0))
        projection = perspective(42.0'f32, aspect, CameraNear, CameraFar)
        viewProjection = projection * view

      var
        hoverIndex = -1
        hoveredTarget = Canceled
        hoveredBoard = Canceled
      if phase == PlayGame:
        if play.tossPicking:
          hoverIndex = hoveredCard(window, viewProjection, game, duelLayout,
            handOwner = game.pendingToss.player)
        elif humanTurn() or (botVms[0] != nil and botVms[1] != nil):
          hoverIndex = hoveredCard(window, viewProjection, game, duelLayout)
        if hoverIndex < 0:
          var boardChoices: seq[Choice]
          for owner in 0 ..< PlayerCount:
            for minion in game.players[owner].board:
              if not play.animations.boardCardSuppressed(minion.id) and
                  not play.queuedEvents.queuedSummon(minion.id):
                boardChoices.add creatureChoice(owner, minion.id)
          hoveredBoard = hoveredCreatureTarget(window, viewProjection,
            game, play, duelLayout, boardChoices)
        if play.tossPicking and humanActs() and play.presentationIdle(game) and
            not game.gameOver:
          play.updateTossPicking(game, hoverIndex,
            pick = gamePressed(MouseLeft),
            clear = window.buttonPressed[KeyEscape] or gamePressed(MouseRight))
        elif humanTurn() and play.presentationIdle(game) and
            not play.pendingTargeting and not play.attackActive and not game.gameOver:
          if hoverIndex >= 0 and
              gamePressed(MouseLeft) and
              not finishRect(window).contains(sk.mousePos):
            if play.playHandCard(game, duelLayout, hoverIndex):
              hoverIndex = -1
          else:
            play.updateAttack(game, duelLayout, window, viewProjection,
              hoveredBoard,
              pick = gamePressed(MouseLeft) and
                not finishRect(window).contains(sk.mousePos),
              cancel = gamePressed(MouseRight) or
                window.buttonPressed[KeyEscape])
        elif humanActs() and play.pendingTargeting and play.presentationIdle(game) and
            not game.gameOver:
          hoveredTarget = play.updateTargeting(game, duelLayout, window,
            viewProjection, hoverIndex,
            pick = gamePressed(MouseLeft) and
              not finishRect(window).contains(sk.mousePos),
            cancel = window.buttonPressed[KeyEscape] or gamePressed(MouseRight))

      when defined(takeScreenshot):
        if getEnv("AWM_CAPTURE_NO_HOVER") == "1":
          hoverIndex = -1
          hoveredBoard = Canceled
          hoveredTarget = Canceled
        if getEnv("AWM_DEMO_HALO") == "1":
          if play.pendingTargeting:
            for choice in play.pendingChoices:
              if choice.kind == CreatureChoice:
                hoveredBoard = choice
                hoveredTarget = choice
                break
              elif choice.kind == HeroChoice:
                hoveredTarget = choice
                break
          else:
            hoverIndex = 0

      var attackHoverTarget = Canceled
      let attackChoices = play.attackChoices(game)
      if humanTurn() and attackChoices.len > 0 and
          not play.pendingTargeting and play.presentationIdle(game):
        attackHoverTarget = hoveredWorldTarget(window, viewProjection, game, play,
          duelLayout, attackChoices)

      if phase == PlayGame:
        play.presentVisualEvents(game, duelLayout, animationTime)

      solid.clear()
      cardSurfaces.clear()
      vfx.clear()
      if phase == ChooseClasses:
        addClassStage()
      else:
        addTableCards(solid, cardSurfaces, vfx, sk, play, game, duelLayout,
          animationTime, cameraPlayer(), hoverIndex, hoveredBoard,
          humanTurn(), attackChoices, play.selectedAttacker,
          play.lungingMinion())
        addAttackCard(solid, cardSurfaces, vfx, sk, play, game, duelLayout,
          animationTime)

      if window.buttonPressed[KeyF8]:
        post.settings.enabled = not post.settings.enabled
      when PostLayerControls:
        for layer in PostLayer:
          if window.buttonPressed[PostLayerKeys[layer]]:
            post.layer = layer
            post.settings.enabled = true
      post.beginScene(window.size, CameraNear, CameraFar)
      glClearColor(0.035, 0.045, 0.065, 1)
      glStencilMask(0xff)
      glClearStencil(0)
      glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT or GL_STENCIL_BUFFER_BIT)
      let environmentTime =
        when defined(takeScreenshot):
          parseFloat(getEnv("AWM_SCENE_TIME", $animationTime)).float32
        else: animationTime
      if phase == PlayGame:
        courtyard.draw(viewProjection, cameraEye, environmentTime, currentSide)
        courtyard.drawSky(viewProjection, cameraEye, environmentTime)
      solid.draw(viewProjection)
      cardSurfaces.draw(sk, viewProjection)

      beginCharacters(scene, window, view, projection, cameraEye)
      scene.lightLikeCourtyard(currentSide)
      glEnable(GL_STENCIL_TEST)
      glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE)
      glStencilFunc(GL_ALWAYS, 0, 0xff)
      if phase == ChooseClasses:
        drawClassHeroes(selectedClass, animationTime)
      else:
        for playerIndex in 0 ..< PlayerCount:
          let
            player = game.players[playerIndex]
            look = play.heroLook(game, playerIndex, hoveredTarget,
              attackChoices, attackHoverTarget)
          glStencilFunc(GL_ALWAYS, (playerIndex + 1).GLint, 0xff)
          if look.targetable:
            vfx.addTargetRing(avatarPosition(playerIndex) + vec3(0, 0.04, 0),
              cameraEye, 0.95, if look.hovered: 1.1'f32 else: 0.28'f32)
          let pose = heroClip(playerIndex, player.heroClass,
            play.deathClock(game, playerIndex, animationTime), animationTime)
          drawCharacter(
            scene,
            models[playerIndex][player.heroClass],
            avatarPosition(playerIndex),
            if playerIndex == 0: PI.float32 else: 0,
            pose.clip,
            pose.time,
            tint = look.tint,
            sizeFactor = look.sizeFactor
          )
      finishCharacters(scene)
      glDisable(GL_STENCIL_TEST)
      if phase == PlayGame and post.beginMaterialNormals():
        courtyard.draw(viewProjection, cameraEye, environmentTime, currentSide,
          normalsOnly = true, normalView = view)
        post.endMaterialNormals()
      post.applyOcclusion(projection)
      if phase == PlayGame:
        for playerIndex in 0 ..< PlayerCount:
          vfx.drawCharacterFlash(playerIndex + 1,
            play.activeVfx.flashStrength(heroChoice(playerIndex)))
        vfx.addAttackRing(play, cameraEye)
        vfx.addEffects(play.activeVfx, cameraEye)
        vfx.draw(viewProjection)
      post.present(window.size)

      glDisable(GL_DEPTH_TEST)
      glDisable(GL_CULL_FACE)
      glDisable(GL_BLEND)
      when not defined(emscripten):
        glDisable(GL_MULTISAMPLE)
      glActiveTexture(GL_TEXTURE0)
      glBindTexture(GL_TEXTURE_2D, sk.atlasTextureId())
      sk.beginUi(window, window.size)
      sk.mousePos = window.mousePos.vec2 / sk.uiScale
      when PostLayerControls:
        if post.settings.enabled and post.layer != FinalLayer:
          sk.drawLabel(
            &"Layer {(post.layer.ord + 1) mod 10}: {post.layer}" &
              (if post.layerAvailable(): "" else: " (effect off)") &
              ". Press 1 for the final image.",
            vec2(32, hudSize(window).y - 110), vec2(1200, 42),
            HudIvory, "Small")

      if phase == ChooseClasses:
        drawClassHeader(sessionOptions.human)
        if sessionOptions.human:
          let picked = classButtons()
          if picked.isSome:
            let heroClass = picked.get
            selectedClass = heroClass
            game = newGame(
              heroClass,
              sessionOptions.opponentClass,
              gameSeed()
            )
            play.resetTable()
            phase = PlayGame
            play.addOpeningHands(game, duelLayout)
            botClock.wait = 1.2'f32
            botClock.plays = 0
            if game.currentPlayer == 0:
              play.statusMessage = "Your turn. Select a card to play."
            else:
              play.statusMessage = "Your opponent is thinking..."
      else:
        drawPlayerPanel(sk, window, game, 0, sessionOptions.human, animationTime)
        drawPlayerPanel(sk, window, game, 1, sessionOptions.human, animationTime)
        drawTurnHeader(sk, window, game, sessionOptions.human, play.statusMessage)
        let inspectingCard = drawCardReadingView(
          sk,
          window,
          game,
          viewProjection,
          play,
          duelLayout,
          hoverIndex,
          false,
          handOwner = if play.tossPicking: game.pendingToss.player else: -1
        )
        drawDeckLabels(sk, window, game, viewProjection, inspectingCard)
        sk.drawLabel(
          play.playHelp(sessionOptions.human),
          vec2(32, hudSize(window).y - 66),
          vec2(820, 42),
          HudMuted,
          "Small"
        )
        let canFinish = humanTurn() and not game.waitingChoice and
          not play.pendingTargeting and not play.attackActive and not game.gameOver and
          play.presentationIdle(game)
        if drawEndTurnButton(sk, window,
            (if game.gameOver: "MATCH ENDED"
             elif not humanTurn(): "OPPONENT"
             else: "END TURN"), canFinish):
          play.selectedAttacker = 0
          game.finishTurn()
          botClock.wait = 1.2'f32
          botClock.plays = 0
          play.statusMessage = "Your opponent is thinking..."
          play.pendingTargeting = false
          play.pendingCardIndex = -1
          play.pendingChoices.setLen(0)

        sk.drawTossPrompt(window, play, game)
        sk.drawTargetPrompt(window, play, game)

        sk.drawCombatPrompt(window, play, game)

        if not play.attackActive:
          sk.drawMatchResult(window, play, game,
            if sessionOptions.human: 0 else: -1)

      when defined(emscripten):
        let role = if sessionOptions.human: "Human player" else: "Bot match"
        var summary = role & ". " & play.statusMessage
        if phase == PlayGame:
          summary.add &" Turn {game.turnNumber}. Active player {game.currentPlayer + 1}."
          for owner, player in game.players:
            summary.add &" Player {owner + 1} {player.heroClass.className()}: life {player.life}, energy {player.energy}/{player.totalEnergy}, hand {player.hand.len}, board {player.board.len}, deck {player.deck.len}, discard {player.discardPile.len}."
          if humanTurn() and not play.pendingTargeting and
              play.presentationIdle(game):
            summary.add " Ready for your action."
        publishStatus(summary.cstring)

      when PostPanelControls:
        drawPostPanel(sk, window, post, courtyard)
      sk.endUi()
      when defined(takeScreenshot):
        if existsEnv("AWM_CAPTURE_SEQUENCE"):
          inc screenshotFrame
          if screenshotFrame mod 2 == 0:
            let
              outputDir = getEnv("AWM_CAPTURE_SEQUENCE")
              frameImage = newImage(window.size.x, window.size.y)
            createDir(outputDir)
            glReadPixels(0, 0, window.size.x.GLsizei, window.size.y.GLsizei,
              GL_RGBA, GL_UNSIGNED_BYTE, frameImage.data[0].addr)
            frameImage.flipVertical()
            frameImage.writeFile(outputDir / &"frame-{screenshotFrame div 2:04}.png")
          if screenshotFrame >= max(2, parseInt(getEnv("AWM_CAPTURE_FRAME", "120"))):
            quit(0)
        else:
          captureScreenshot(
            window,
            screenshotFrame,
            (if existsEnv("AWM_CAPTURE_FRAME"): max(1, parseInt(getEnv("AWM_CAPTURE_FRAME")))
              elif getEnv("AWM_CAPTURE_SETTLED") == "1": 80 else: 20),
            appDir / "awm_shot.png"
          )
      window.swapBuffers()

    while not window.closeRequested:
      pollEvents()

  when isMainModule:
    runAwm()

when defined(headless):
  when isMainModule:
    echo "AWM headless module loaded."
