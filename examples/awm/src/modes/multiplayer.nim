## The multiplayer game mode: three or more seats around the ring, playing
## the core's game. Every seat but the human's is played by a bot script.
import std/math
import ../core/sim, ../core/bots, ../scene/ring
export ring

const
  HandSpread = 5.0'f32
    ## How wide a hand may fan: it stays between the deck and discard pads.
  BoardSpread = 6.0'f32
    ## How wide a board row may spread across its balcony.
  BoardSpacing = 1.65'f32
    ## The widest gap between neighbouring cards on a board row.

type
  MultiplayerMatch* = object
    game*: GameState
    humanSeat*: int  ## -1 when every seat is a bot and we spectate.
    bots*: seq[BotVm]  ## One per seat; nil for the human's.

template seats*(match: MultiplayerMatch): untyped =
  ## One PlayerState per seat, in seat order.
  match.game.players

proc current*(match: MultiplayerMatch): int =
  match.game.currentPlayer

proc turnNumber*(match: MultiplayerMatch): int =
  match.game.turnNumber

proc newMultiplayerMatch*(classes: openArray[HeroClass], humanSeat: int,
    seed: int64, botSources: openArray[string] = [],
    pickClasses = false): MultiplayerMatch =
  ## One seat per class, dealt by the core. The last seat standing wins.
  ## Every seat but the human's runs a bot script, taken from `botSources`
  ## in turn (repeating); with none, those seats don't act.
  result.humanSeat = humanSeat
  var sources = newSeq[string](classes.len)
  if botSources.len > 0:
    var next = 0
    for seat in 0 ..< classes.len:
      if seat != humanSeat:
        sources[seat] = botSources[next mod botSources.len]
        inc next
  result.bots = loadBots(sources)
  var selected = @classes
  if pickClasses:
    for seat in 0 ..< selected.len:
      if seat != humanSeat:
        selected[seat] = result.bots[seat].chooseClass(selected.len, seed)
  for bot in result.bots:
    bot.ensureSeed(seed)
  result.game = newGame(selected, seed)

proc humanTurn*(match: MultiplayerMatch): bool =
  ## The living human's turn: the dead can't act.
  match.humanSeat in 0 ..< match.game.playerCount and
    match.current == match.humanSeat and not match.game.gameOver and
    not match.game.dead(match.humanSeat)

proc humanActs*(match: MultiplayerMatch): bool =
  ## The human must act now: on their turn, or answering their own discard
  ## or trigger.
  match.humanSeat in 0 ..< match.game.playerCount and
    match.game.actingPlayer() == match.humanSeat and
    not match.game.gameOver and not match.game.dead(match.humanSeat)

proc viewedSeat*(match: MultiplayerMatch): int =
  ## The balcony in front of the camera: the human's, or whoever's turn it
  ## is when we spectate.
  if match.humanSeat >= 0: match.humanSeat else: match.current

proc turnLabel*(match: MultiplayerMatch,
    names: openArray[string] = []): string =
  ## Whose turn it is, in the duel's words.
  if match.game.gameOver: "MATCH COMPLETE"
  elif match.current in 0 ..< names.len:
    match.game.playerName(match.current, names) & "'s turn"
  elif match.humanTurn: "YOUR TURN"
  else: "PLAYER " & $(match.current + 1) & "'S TURN"

proc turnStatus*(match: MultiplayerMatch,
    names: openArray[string] = []): string =
  ## Describes the current turn or winner with the public seat name.
  if match.game.gameOver:
    if match.game.winner == match.humanSeat: "You are the last one standing."
    else: match.game.playerName(match.game.winner, names) &
      " is the last one standing."
  elif match.humanSeat in 0 ..< match.game.playerCount and
      match.game.dead(match.humanSeat):
    "You are dead. Watching the match..."
  elif match.humanSeat < 0: "Watching bot match..."
  elif match.humanTurn: "Your turn. Select a card to play."
  else: match.game.playerName(match.current, names) & " is thinking..."

proc endTurn*(match: var MultiplayerMatch): bool =
  ## The core's turn change: the next seat gains energy, draws, and its
  ## start-of-turn triggers fire. False when the turn can't end yet.
  let before = match.game.turnNumber
  match.game.finishTurn()
  match.game.turnNumber != before

proc skipDeadTurn*(match: var MultiplayerMatch): bool =
  ## Ends the turn of a player who died during it. True when it passed.
  if match.game.gameOver or not match.game.dead(match.current):
    return false
  match.endTurn()

when not defined(headless):
  import std/[options, os, random, strformat, times]
  when defined(takeScreenshot):
    import std/strutils
  import chroma, opengl, silky, vmath, windy
  import ../app, ../ui/hud, ../scene/table, ../play, ../scene/cardrenderer,
    ../vfx/vfxrenderer, ../scene/post, ../ui/postpanel, ../scene/courtyard,
    ../scene/heroes, ../net/web, ../ui/tuning
  import polyworld/[characters, chrome, viewers]
  import ../replayer

  proc place(balcony: PlayerBalcony, local: CardPose): CardPose =
    ## A pose on a balcony, given in its local frame.
    result = local
    result.position = balcony.toWorld(local.position)
    result.frameYaw = balcony.yaw

  proc deckPose(balcony: PlayerBalcony): CardPose =
    balcony.place(CardPose(position: balcony.deckZone +
      vec3(0, CardHeight * 0.5'f32, 0)))

  proc discardPose(balcony: PlayerBalcony): CardPose =
    balcony.place(CardPose(position: balcony.discardZone +
      vec3(0, CardHeight * 0.5'f32, 0)))

  proc boardPoses(balcony: PlayerBalcony, count: int): seq[CardPose] =
    ## A row across the balcony's board zone, facing its owner.
    if count <= 0:
      return
    let
      spacing =
        if count == 1: 0.0'f32
        else: min(BoardSpacing, BoardSpread / (count - 1).float32)
      start = -spacing * (count - 1).float32 * 0.5'f32
    for i in 0 ..< count:
      result.add balcony.place(CardPose(position: balcony.boardZone +
        vec3(start + spacing * i.float32, CardHeight * 0.5'f32, 0)))

  proc handPoses(layout: MultiplayerLayout, view: MultiplayerView,
      viewedSeat, seat, count: int): seq[CardPose] =
    ## The viewed balcony is turned to P1's place, so its near hand faces
    ## the camera from there. The others keep their tuned place, flipped
    ## over so the table sees only their backs.
    let
      balcony = layout.balconies[seat]
      camera = layout.balconies[0].toLocal(view.camera.eye)
      near = seat == viewedSeat
      hand = if near: view.nearHand else: view.farHand
      pitch =
        if near: arctan2(camera.z - hand.distance, camera.y - hand.height) +
          hand.pitch
        else: MultiplayerHandPitch + hand.pitch
    for fanned in fanPoses(count, vec3(hand.lateral, hand.height,
        hand.distance), pitch, 1, hand.yaw, view.handRoll, HandSpread):
      var pose = fanned
      if not near:
        # Same place, other side up, so the table sees only backs. Written
        # as a half turn flat on the table plus the tilt, not as a roll, so
        # a card flying in from the deck turns around without flipping over.
        pose.pitch = fanned.pitch - PI.float32
        pose.yaw = -fanned.yaw - PI.float32
      result.add balcony.place(pose)

  proc seatTable*(layout: MultiplayerLayout, view: MultiplayerView,
      viewedSeat, humanSeat: int): TableLayout =
    ## Where the shared table puts every seat's cards and hero: on its own
    ## balcony, in the ring's frame, each card facing its owner. Draw and
    ## hit-test it through stageRotation, like the balconies. Only the
    ## viewed hand is face up, and only the human's draws fly face up.
    TableLayout(
      handPoses: proc(player, count: int): seq[CardPose] =
        handPoses(layout, view, viewedSeat, player, count),
      boardPoses: proc(player, count: int): seq[CardPose] =
        layout.balconies[player].boardPoses(count),
      deckPose: proc(player: int): CardPose =
        layout.balconies[player].deckPose,
      discardPose: proc(player: int): CardPose =
        layout.balconies[player].discardPose,
      spellPose: proc(player: int): CardPose =
        ## Floating over the balcony, just past its board row.
        layout.balconies[player].place(CardPose(
          position: layout.balconies[player].boardZone +
            vec3(0, 1.6'f32, -0.9'f32))),
      heroPosition: proc(player: int): Vec3 =
        layout.balconies[player].toWorld(layout.balconies[player].heroZone),
      handVisible: proc(player: int): bool =
        player == viewedSeat,
      drawVisible: proc(player: int): bool =
        player == humanSeat,
      overBoard: proc(point: Vec3): bool =
        length(vec2(point.x, point.z)) <= layout.outerRadius)

  proc runMultiplayer*(app: App) =
    ## Presents a match through the shared table, like the duel. The camera
    ## never moves. With --human P1 plays and nothing turns; otherwise we
    ## spectate and the balconies turn around the static center to bring
    ## whoever's turn it is in front of the camera.
    bindApp(app)
    let
      layout = buildMultiplayerLayout(sessionOptions.playerCount)
      names = if app.replay != nil: app.replay.playerNames() else: @[]
    var
      previewTime = 0.0'f32
      hudTime = 0.0'f
      previewLastFrame = epochTime()
      seatRng =
        if sessionOptions.seedGiven or defined(takeScreenshot):
          initRand(sessionOptions.seed)
        else: initRand()
      match: MultiplayerMatch
      play = initTablePlay()
      choosingClasses = true
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
      if humanClass.isSome:
        classes[0] = humanClass.get
      choosingClasses = false
      match = newMultiplayerMatch(classes,
        humanSeat = if humanClass.isSome: 0 else: -1,
        seed = seatRng.rand(high(int)).int64, botSources = botSources,
        pickClasses = true)
      botClock = initBotClock()
      orbit = initSeatOrbit(layout.balconies[match.viewedSeat].yaw)
      play.resetTable()
      play.animations.setLen(0)
      play.statusMessage = match.turnStatus(names)
      # As in the duel, every seat's hand is dealt card by card.
      openingDraw = true
    proc turnPassed() =
      orbit.aimAt(layout.balconies[match.viewedSeat].yaw)
      play.statusMessage = match.turnStatus(names)
    for path in sessionOptions.botPaths:
      botSources.add readFile(path)
    if botSources.len == 0 and fileExists(appDir / "players" / "base.bas"):
      botSources.add readFile(appDir / "players" / "base.bas")
    if getEnv("AWM_AUTOSTART") == "1":
      startMatch(if sessionOptions.human: some(sessionOptions.playerClass)
        else: none(HeroClass))
    if app.replay != nil:
      # A recorded match: its classes and deal, played back on the ring.
      choosingClasses = false
      match = MultiplayerMatch(game: app.replay.newReplayGame(),
        humanSeat: -1)
      orbit = initSeatOrbit(layout.balconies[match.viewedSeat].yaw)
      play.resetTable()
      play.statusMessage =
        app.replay.playerName(match.current) & " begins."
      openingDraw = true
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
      var previewDt = frameDelta(previewLastFrame)
      hudTime += previewDt
      if app.replay != nil:
        previewDt *= app.replay.timeScale
      previewTime += previewDt
      play.animations.advanceAnimations(previewDt)
      play.discardFlights.advanceAnimations(previewDt)
      play.activeVfx.advance(previewDt)
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
      sk.uiScale = if choosingClasses: classSelectionScale()
        else: hudScale(window)
      sk.mousePos = window.mousePos.vec2 / max(sk.uiScale, 0.01'f32)
      when PostPanelControls:
        uiCapturesMouse = mouseOverPostPanel(sk.mousePos)
      let table = seatTable(layout, previewView, match.viewedSeat,
        match.humanSeat)
      if not choosingClasses and app.replay != nil:
        # The recording plays every seat; the ring turns to whoever acts.
        let viewed = match.viewedSeat
        if app.replay.update(play, match.game, table, previewDt) or
            match.viewedSeat != viewed:
          orbit.aimAt(layout.balconies[match.viewedSeat].yaw)
        orbit.advance(previewDt)
      elif not choosingClasses:
        # The bots play their seats, the same way they play the duel.
        if play.updateBots(match.game, table, match.bots, botClock,
            proc(): bool = match.humanActs, previewDt,
            proc(player: int): string = match.game.playerName(player, names)):
          # The status shows whose turn it is now, unless a script just
          # failed: its error line stays up.
          let message = play.statusMessage
          turnPassed()
          if botClock.scriptFailed:
            play.statusMessage = message
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
          if choosingClasses: classChoiceEye(aspect)
          else: camera.eye
        target =
          if choosingClasses: classChoiceTarget
          else: camera.target
        view = lookAt(eye, target, vec3(0, 1, 0))
        farPlane = max(CameraFar, length(eye) * 3)
        projection = perspective(42.0'f32, aspect, CameraNear, farPlane)
        vp = projection * view
        classHover = if choosingClasses and sessionOptions.human and
            not uiCapturesMouse: classSelectionHover(vp)
          else: none(HeroClass)
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
        selectionStage.draw(vp, eye, environmentTime, 1)
        selectionStage.drawSky(vp, eye, environmentTime, brightness = 0.22)
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
        drawClassHeroes(classHover, previewTime, eye)
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
      if post.beginMaterialNormals():
        if choosingClasses:
          selectionStage.draw(vp, eye, environmentTime, 1,
            normalsOnly = true, normalView = view)
        else:
          courtyard.draw(vp, eye, environmentTime, 1,
            normalsOnly = true, normalView = view, stageYaw = stageYaw)
        post.endMaterialNormals()
      post.applyOcclusion(projection)
      let panelsBottom =
        if match.humanSeat >= 0: finishRect(window).origin.y - 18
        elif app.replay != nil: hudSize(window).y - ReplayBarHeight - 18
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
            match.seats.len, match.current, panelsBottom), hudTime)
          vfx.draw(hudHaloProjection(window.size.vec2), depthTest = false)
      elif classHover.isSome:
        vfx.draw(vp)
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
        let picked = classSelection(vp, sessionOptions.human, not uiCapturesMouse)
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
            match.humanSeat, panelsBottom, hudTime, names)
        # The turn header and prompts center on the space left of the
        # panels.
        let
          columnX = playerPanelColumnX(window)
          centerX = columnX * 0.5'f32
        sk.drawTurnHeader(
          centerX,
          min(920'f32, columnX - 104),
          match.turnNumber,
          match.turnLabel(names),
          match.humanTurn,
          if match.game.gameOver:
            match.turnStatus(names)
          else:
            play.statusMessage
        )
        sk.drawTossPrompt(window, play, match.game, centerX)
        sk.drawTargetPrompt(window, play, match.game, centerX)
        sk.drawCombatPrompt(window, play, match.game, centerX)
        sk.drawPileTooltip(window, hoveredPile(window, stageVp, match.game,
          play, table), stageVp)
        if not play.attackActive:
          sk.drawMatchResult(window, play, match.game, match.humanSeat,
            centerX, names)
        if app.replay == nil:
          sk.drawLabel(play.playHelp(match.humanSeat >= 0),
            vec2(32, hudSize(window).y - 66), vec2(820, 42), HudMuted,
            "Small")
      if not choosingClasses and match.humanSeat >= 0:
        let
          yourTurn = match.humanTurn
          canFinish = yourTurn and not match.game.waitingChoice and
            not play.pendingTargeting and not play.attackActive and
            not match.game.gameOver and play.presentationIdle(match.game) and
            not openingDraw
        if drawEndTurnButton(sk, window,
            (if match.game.gameOver: "MATCH ENDED"
             elif yourTurn: "END TURN" else: "WAITING"), canFinish):
          play.stopTargeting()
          play.selectedAttacker = 0
          if match.endTurn():
            turnPassed()
      when defined(emscripten):
        # The same summary as the duel's, one line per seat.
        var summary = &"Multiplayer match: {layout.playerCount} players. " &
          (if app.replay != nil: "Replay. "
           elif (if choosingClasses: sessionOptions.human
                 else: match.humanSeat >= 0): "Human player. "
           else: "Bot match. ") &
          (if choosingClasses:
            (if sessionOptions.human: "Choose your class."
             else: "Bots are choosing classes...")
           else: play.statusMessage)
        if not choosingClasses:
          template game: untyped = match.game
          summary.add &" Turn {match.turnNumber}. " &
            (if names.len > 0:
              "Active " & game.playerName(match.current, names)
            else:
              "Active player " & $(match.current + 1)) & "."
          for seat, player in game.players:
            summary.add " " & game.playerName(seat, names) &
              " " & player.heroClass.className() &
              (if game.dead(seat): ": dead." else:
                &": life {player.life}, energy {player.energy}/{player.totalEnergy}, hand {player.hand.len}, board {player.board.len}, deck {player.deck.len}, discard {player.discardPile.len}.")
          if match.humanTurn and not play.pendingTargeting and
              play.presentationIdle(game):
            summary.add " Ready for your action."
        publishStatus(summary.cstring)
      if app.replay != nil and not choosingClasses:
        app.replay.drawTransport(sk, window)
      when PostPanelControls:
        drawPostPanel(sk, window, post, courtyard)
      sk.endUi()
      when defined(takeScreenshot):
        captureScreenshot(window, previewScreenshotFrame,
          max(1, parseInt(getEnv("AWM_CAPTURE_FRAME", "20"))),
          appDir / &"awm_multiplayer_{layout.playerCount}.png")
      window.swapBuffers()
      if app.replay != nil:
        app.replay.reportFrame()
    while not window.closeRequested:
      pollEvents()
      waitForDisplay()
    return
