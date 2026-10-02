## The duel: two players across the courtyard. A client of the core that
## presents its match with the shared app, table and HUD.
import std/[math, options, os, random, strformat, tables, times]
when defined(takeScreenshot):
  import std/strutils
import chroma, opengl, pixie, silky, vmath, windy
import ../core/sim, ../core/sessions, ../core/bots
import ../app, ../ui/hud, ../scene/table, ../play, ../ui/cardfaces,
  ../scene/cardrenderer, ../vfx/vfxrenderer, ../scene/post, ../ui/postpanel,
  ../scene/courtyard, ../scene/heroes, ../net/web, ../scene/placement,
  ../ui/tuning, ../replayer
import polyworld/[assets, characters, chrome, common, viewers]

const
  BoardWidth = 18.0'f32
  BoardDepth = 11.0'f32
  DuelCamera = Placement(lateral: 0.00, height: 12.05, distance: 13.08,
    pitch: 0.7659, yaw: 0.0000) # pitch 43.9 deg, yaw 0.0 deg
  HeroTargetRadius = 0.95'f32 ## Matches the ring drawn around a hero.
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

type
  AppPhase = enum
    ChooseClasses
    PlayGame

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

proc runDuel*(app: App) =
  bindApp(app)
  var
    phase = ChooseClasses
    game: GameState
    # Captures can replay a cast from its visual seed.
    play = when defined(takeScreenshot):
      initTablePlay(parseBiggestInt(getEnv("AWM_VFX_SEED", "20260909")))
    else:
      initTablePlay()
    animationTime = 0.0'f32
    hudTime = 0.0'f
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
  if app.replay != nil:
    # A recorded match: its classes and deal, played back on the table.
    game = app.replay.newReplayGame()
    phase = PlayGame
    play.addOpeningHands(game, duelLayout)
    play.statusMessage =
      app.replay.playerName(game.currentPlayer) & " begins."
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
    var dt = frameDelta(lastFrameTime)
    hudTime += dt
    if app.replay != nil:
      dt *= app.replay.timeScale
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
    if phase == ChooseClasses and not sessionOptions.human:
      botClassWait -= dt
      if botClassWait <= 0:
        let
          playerClass = play.visualRng.rand(HeroClass)
          opponentClass = play.visualRng.rand(HeroClass)
        game = newGame(playerClass, opponentClass, gameSeed())
        play.resetTable()
        phase = PlayGame
        play.addOpeningHands(game, duelLayout)
        botClock.wait = 1.2'f32
        botClock.plays = 0
        play.statusMessage = "Watching bot match..."

    sk.uiScale = if phase == ChooseClasses: classSelectionScale()
      else: hudScale(window)
    sk.mousePos = window.mousePos.vec2 / sk.uiScale
    when PostPanelControls:
      uiCapturesMouse = mouseOverPostPanel(sk.mousePos)

    if phase == PlayGame:
      if app.replay != nil:
        discard app.replay.update(play, game, duelLayout, dt)
      else:
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
          classChoiceEye(aspect)
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
      classHover = if phase == ChooseClasses and sessionOptions.human and
          not uiCapturesMouse: classSelectionHover(viewProjection)
        else: none(HeroClass)

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
    if phase == PlayGame:
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
    else:
      selectionStage.draw(viewProjection, cameraEye, environmentTime, 1)
      selectionStage.drawSky(viewProjection, cameraEye, environmentTime,
        brightness = 0.22)
    solid.draw(viewProjection)
    cardSurfaces.draw(sk, viewProjection)

    beginCharacters(scene, window, view, projection, cameraEye)
    scene.lightLikeCourtyard(currentSide)
    glEnable(GL_STENCIL_TEST)
    glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE)
    glStencilFunc(GL_ALWAYS, 0, 0xff)
    if phase == ChooseClasses:
      drawClassHeroes(classHover, animationTime, cameraEye)
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
    if post.beginMaterialNormals():
      if phase == PlayGame:
        courtyard.draw(viewProjection, cameraEye, environmentTime, currentSide,
          normalsOnly = true, normalView = view)
      else:
        selectionStage.draw(viewProjection, cameraEye, environmentTime, 1,
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
    elif classHover.isSome:
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
      let picked = classSelection(viewProjection, sessionOptions.human, not uiCapturesMouse)
      if picked.isSome:
        let heroClass = picked.get
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
      drawPlayerPanel(sk, window, game, 0, sessionOptions.human, hudTime)
      drawPlayerPanel(sk, window, game, 1, sessionOptions.human, hudTime)
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
      sk.drawPileTooltip(window, hoveredPile(window, viewProjection, game,
        play, duelLayout), viewProjection,
        avoid = cardReadingRect(window), avoiding = inspectingCard)
      if app.replay == nil:
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
      let role =
        if app.replay != nil: "Replay"
        elif sessionOptions.human: "Human player"
        else: "Bot match"
      var summary = role & ". " & play.statusMessage
      if phase == PlayGame:
        summary.add &" Turn {game.turnNumber}. Active player {game.currentPlayer + 1}."
        for owner, player in game.players:
          summary.add &" Player {owner + 1} {player.heroClass.className()}: life {player.life}, energy {player.energy}/{player.totalEnergy}, hand {player.hand.len}, board {player.board.len}, deck {player.deck.len}, discard {player.discardPile.len}."
        if humanTurn() and not play.pendingTargeting and
            play.presentationIdle(game):
          summary.add " Ready for your action."
      publishStatus(summary.cstring)

    if app.replay != nil and phase == PlayGame:
      app.replay.drawTransport(sk, window)
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
    if app.replay != nil:
      app.replay.reportFrame()

  while not window.closeRequested:
    pollEvents()
    waitForDisplay()
