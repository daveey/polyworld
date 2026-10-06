## The screen-space HUD every game mode draws with: panels, the turn header,
## prompts, buttons, the card inspector and the pile tooltip. No world or
## camera state.
import std/[math, os, strformat, tables]
import chroma, pixie, silky, vmath, windy
import ../core/sim, cardfaces, ../scene/cardrenderer, ../play, ../scene/table,
  ../vfx/vfxrenderer
import polyworld/[assets, chrome, viewers]

const
  PlayerPanelWidth* = 680.0'f32
  PlayerPanelHeight* = 140.0'f32

type
  UiRect* = object
    origin*: Vec2
    size*: Vec2

proc contains*(rect: UiRect, point: Vec2): bool =
  point.x >= rect.origin.x and
    point.y >= rect.origin.y and
    point.x <= rect.origin.x + rect.size.x and
    point.y <= rect.origin.y + rect.size.y

proc classUiColor*(heroClass: HeroClass): ColorRGBX =
  case heroClass
  of Archer:
    rgbx(70, 205, 102, 255)
  of Warrior:
    rgbx(226, 74, 61, 255)
  of Mage:
    rgbx(76, 121, 236, 255)

proc hudScale*(window: Window): float32 =
  let density = when defined(emscripten): window.contentScale else: 1.0'f32
  min(density, min(window.size.x.float32 / 2400.0'f32,
    window.size.y.float32 / 1500.0'f32))

proc hudSize*(window: Window): Vec2 =
  window.size.vec2 / max(hudScale(window), 0.01'f32)

const
  HudIvory* = rgbx(244, 228, 192, 255)
  HudMuted* = rgbx(178, 177, 161, 255)
  HudGold* = rgbx(215, 181, 112, 255)
  HudHelperY* = 324'f32
  HudClassInk*: array[HeroClass, ColorRGBX] = [
    rgbx(142, 199, 146, 255), rgbx(227, 127, 104, 255),
    rgbx(156, 175, 234, 255)]
  HudClassIcon*: array[HeroClass, string] = [
    "class-archer", "class-warrior", "class-mage"]

proc addAwmHudAssets*(builder: AtlasBuilder, cardRoot: string) =
  let hudRoot = cardRoot.parentDir / "ui/hud"
  for name in ["player-panel", "class-archer", "class-warrior", "class-mage",
      "life-heart", "energy-gem", "energy-glow", "energy-ready", "energy-spent", "energy-locked",
      "turn-plaque", "turn-active", "turn-waiting", "button", "button-hover",
      "button-disabled", "pile-label", "notice", "status-line"]:
    if not builder.addImage("hud/" & name, readImage(hudRoot / (name & ".svg"))):
      raise newException(IOError, "AWM HUD does not fit the UI atlas")
  let heading = cardRoot / "fonts/Grenze-SemiBold.ttf"
  builder.addFont(heading, "Display", 94)
  builder.addFont(heading, "TurnState", 45)
  builder.addFont(heading, "Prompt", 32)
  builder.addFont(heading, "Heading", 36)
  builder.addFont(heading, "Class", 32)
  builder.addFont(heading, "Number", 48)
  builder.addFont(heading, "Action", 48)

proc hudSprite*(sk: Silky, name: string, origin, size: Vec2,
    tint = rgbx(255, 255, 255, 255), flipX = false) =
  let entry = sk.atlas.entries["hud/" & name]
  let
    uvX = if flipX: entry.x + entry.width else: entry.x
    uvWidth = if flipX: -entry.width else: entry.width
  sk.drawQuad(origin, size, vec2(uvX.float32, entry.y.float32),
    vec2(uvWidth.float32, entry.height.float32), tint)

proc finishRect*(window: Window): UiRect =
  UiRect(origin: vec2(hudSize(window).x - 496, hudSize(window).y - 194),
    size: vec2(460, 126))

proc drawButton*(sk: Silky, window: Window, rect: UiRect, label: string,
    enabled = true): bool =
  let hovered = rect.contains(sk.mousePos)
  sk.hudSprite(if not enabled: "button-disabled"
    elif hovered: "button-hover" else: "button", rect.origin, rect.size)
  sk.drawLabel(label, rect.origin + vec2(18, 0), rect.size - vec2(36, 0),
    if enabled: HudIvory else: HudMuted, "Action", CenterAlign)
  enabled and hovered and window.buttonPressed[MouseLeft]

proc drawEndTurnButton*(sk: Silky, window: Window, label: string,
    enabled: bool): bool =
  ## The end-turn button, with Enter as its shortcut while it is enabled.
  ## True when the turn should end this frame.
  let
    finish = finishRect(window)
    clicked = drawButton(sk, window, finish, label, enabled = enabled)
    shortcut = when defined(awmLayoutTuning): false
      else: window.buttonPressed[KeyEnter]
  sk.drawLabel(if enabled: "Press Enter" else: "",
    finish.origin + vec2(0, finish.size.y + 6), vec2(finish.size.x, 32),
    HudMuted, "Small", CenterAlign)
  clicked or (enabled and shortcut)

proc cardReadingRect*(window: Window): UiRect =
  let height = max(120'f32, min(850'f32, hudSize(window).y - 360))
  UiRect(origin: vec2(28, 198),
    size: vec2(height * CardFaceWidth.float32 / CardFaceHeight.float32, height))

proc drawCardReading*(sk: Silky, rect: UiRect, card: Card, power = -1,
    toughness = -1, lost: set[Keyword] = {}): bool =
  ## The large preview of the inspected card, in `rect`. A minion in play
  ## passes its live stats (toughness >= 0). True when the preview is shown.
  when defined(takeScreenshot):
    if getEnv("AWM_CAPTURE_NO_HOVER") == "1":
      return false
  sk.drawCardImage(sk.bakedCardImage(card), rect.origin, rect.size)
  if toughness >= 0:
    sk.drawMinionOverlays(card, power, toughness, lost, rect.origin, rect.size)
  true

proc drawCardReading*(sk: Silky, window: Window, card: Card, power = -1,
    toughness = -1, lost: set[Keyword] = {}): bool =
  ## The duel's preview, on the left of the screen.
  sk.drawCardReading(cardReadingRect(window), card, power, toughness, lost)

proc drawHudNotice*(sk: Silky, rect: UiRect) =
  sk.hudSprite("notice", rect.origin, rect.size)

proc drawPlayerPanel*(sk: Silky, origin: Vec2, player: PlayerState,
    name: string, active, mirrored: bool, time: float32) =
  ## One player's class, life and energy. The mirrored version reads from
  ## the right edge of the screen.
  let
    alignment = if mirrored: RightAlign else: LeftAlign
    # A four-second breath; only opacity changes, so the gems stay steady.
    glow = rgbx(255, 255, 255, uint8(135 + 65 * sin(time * PI.float32 / 2)))
    energyX = if mirrored: 30'f32 else: 438'f32
  template panelX(x, width: float32): float32 =
    (if mirrored: PlayerPanelWidth - x - width else: x)
  # A dead player's panel is dimmed, and says so where the class was.
  let shade =
    if player.dead: rgbx(165, 165, 172, 255) else: rgbx(255, 255, 255, 255)
  sk.hudSprite("player-panel", origin, vec2(PlayerPanelWidth, PlayerPanelHeight),
    tint = shade, flipX = mirrored)
  sk.hudSprite(HudClassIcon[player.heroClass], origin + vec2(panelX(14, 90), 4),
    vec2(90, 124), tint = shade)
  let nameFont =
    if sk.getTextSize("Heading", name).x <= 176: "Heading"
    else: "Small"
  sk.drawLabel(sk.fittedLabel(name, 176, nameFont),
    origin + vec2(panelX(124, 176), 19), vec2(176, 43),
    if player.dead: HudMuted else: HudIvory, nameFont, alignment)
  if player.dead:
    sk.drawLabel("Dead", origin + vec2(panelX(124, 176), 66),
      vec2(176, 42), HudMuted, "Class", alignment)
    return
  sk.drawLabel(player.heroClass.className(), origin + vec2(panelX(124, 176), 66),
    vec2(176, 42), HudClassInk[player.heroClass], "Class", alignment)
  if active:
    sk.drawRect(origin + vec2(panelX(124, 156), 118), vec2(156, 1), rgbx(207, 167, 93, 160))
  sk.hudSprite("life-heart", origin + vec2(panelX(306, 104), 16), vec2(104))
  sk.drawLabel($player.life, origin + vec2(panelX(311, 94), 24), vec2(94, 65),
    HudIvory, "Number", CenterAlign)
  sk.hudSprite("energy-glow", origin + vec2(energyX - 24, 5), vec2(81), glow)
  sk.hudSprite("energy-gem", origin + vec2(energyX, 29), vec2(33))
  sk.drawLabel($player.energy & " / " & $player.totalEnergy,
    origin + vec2(energyX + 47, 21), vec2(158, 50), HudIvory, "Heading")
  # Reserve all ten slots. Earned but spent gems are visibly different from
  # future capacity; totals above ten retain the exact numeric meter.
  if player.totalEnergy <= 10:
    for i in 0 ..< 10:
      let sprite = if i < player.energy: "energy-ready"
        elif i < player.totalEnergy: "energy-spent" else: "energy-locked"
      let dot = origin + vec2(energyX + 2 + i.float32 * 21, 88)
      if i < player.energy:
        sk.hudSprite("energy-glow", dot - vec2(11), vec2(40), glow)
      sk.hudSprite(sprite, dot, vec2(18))

proc drawPlayerPanel*(sk: Silky, window: Window, game: GameState,
    playerIndex: int, human: bool, time: float32,
    names: openArray[string] = []) =
  ## The duel's two panels, in the top corners.
  sk.drawPlayerPanel(
    vec2(if playerIndex == 0: 24'f32
      else: hudSize(window).x - PlayerPanelWidth - 24, 18),
    game.players[playerIndex],
    if playerIndex in 0 ..< names.len and names[playerIndex].len > 0:
        names[playerIndex]
      elif human: (if playerIndex == 0: "YOU" else: "OPPONENT")
      else: "PLAYER " & $(playerIndex + 1),
    playerIndex == game.currentPlayer, playerIndex == 1, time)

proc playerPanelColumnX*(window: Window): float32 =
  ## The left edge of the right-hand column of player panels.
  hudSize(window).x - PlayerPanelWidth - 24

proc playerPanelColumnRect*(window: Window, count, index: int,
    bottom: float32): UiRect =
  ## Panel `index` of `count`, down the right edge of the screen: a fixed
  ## gap apart, the column centered between the top and `bottom`.
  const
    Margin = 18'f32
    Gap = 24'f32
  let
    height = count.float32 * PlayerPanelHeight + (count - 1).float32 * Gap
    top = Margin + (bottom - Margin - height) * 0.5'f32
  UiRect(
    origin: vec2(playerPanelColumnX(window),
      top + index.float32 * (PlayerPanelHeight + Gap)),
    size: vec2(PlayerPanelWidth, PlayerPanelHeight))

proc cardReadingColumnRect*(window: Window, bottom: float32): UiRect =
  ## The preview over the right-hand column of player panels: the same size
  ## as the duel's, flush with the panels' right edge and centered on the
  ## column's space between the top and `bottom`.
  const Margin = 18'f32
  let size = cardReadingRect(window).size
  UiRect(
    origin: vec2(playerPanelColumnX(window) + PlayerPanelWidth - size.x,
      max(Margin, Margin + (bottom - Margin - size.y) * 0.5'f32)),
    size: size)

proc drawPlayerPanelColumn*(sk: Silky, window: Window,
    players: openArray[PlayerState], current, human: int, bottom: float32,
    time: float32, names: openArray[string] = []) =
  ## Any number of players, in the right-hand version of the panel, down the
  ## right edge of the screen. `human` is the seat labeled YOU, or -1.
  for i, player in players:
    sk.drawPlayerPanel(
      playerPanelColumnRect(window, players.len, i, bottom).origin, player,
      if i in 0 ..< names.len and names[i].len > 0: names[i]
        elif i == human: "YOU" else: "PLAYER " & $(i + 1),
      i == current, true, time)

proc drawTurnHeader*(sk: Silky, centerX, statusWidth: float32,
    turnNumber: int, label: string, active: bool, status: string) =
  ## The turn plaque and status line, centered on `centerX`. `active`
  ## lights the plaque for the human's own turn.
  let origin = vec2(centerX - 364, 12)
  sk.hudSprite("turn-plaque", origin, vec2(728, 224))
  sk.drawLabel("TURN " & $turnNumber, origin + vec2(52, 16),
    vec2(624, 114), HudIvory, "Display", CenterAlign)
  sk.hudSprite(if active: "turn-active" else: "turn-waiting",
    origin + vec2(72, 144), vec2(584, 86))
  let labelFont =
    if sk.getTextSize("TurnState", label).x <= 528: "TurnState"
    else: "Prompt"
  sk.drawLabel(sk.fittedLabel(label, 528, labelFont),
    origin + vec2(100, 144), vec2(528, 86),
    if active: rgbx(42, 32, 18, 255) else: HudGold,
    labelFont, CenterAlign)
  if status.len > 0:
    sk.hudSprite("status-line",
      vec2(centerX - statusWidth * 0.5'f32 - 16, 258),
      vec2(statusWidth + 32, 50))
  sk.drawLabel(sk.fittedLabel(status, statusWidth, "Small"),
    vec2(centerX - statusWidth * 0.5'f32, 266),
    vec2(statusWidth, 34), HudIvory, "Small", CenterAlign)

proc drawTurnHeader*(sk: Silky, window: Window, game: GameState,
    human: bool, status: string, names: openArray[string] = []) =
  ## The duel's header, centered between its two corner panels.
  let yourTurn = human and game.currentPlayer == 0
  sk.drawTurnHeader(hudSize(window).x * 0.5'f32,
    min(920'f32, hudSize(window).x - (PlayerPanelWidth + 52) * 2),
    game.turnNumber,
    if game.gameOver: "MATCH COMPLETE"
      elif game.currentPlayer in 0 ..< names.len:
        game.playerName(game.currentPlayer, names) & "'s turn"
      elif human: (if yourTurn: "YOUR TURN" else: "OPPONENT'S TURN")
      else: "PLAYER " & $(game.currentPlayer + 1) & "'S TURN",
    yourTurn and not game.gameOver, status)

proc drawTossPrompt*(sk: Silky, window: Window, play: TablePlay,
    game: GameState, centerX = hudSize(window).x * 0.5'f32) =
  ## What to discard, while the human is choosing.
  if not play.tossPicking:
    return
  let
    pending = game.pendingToss
    accent = HudClassInk[game.players[pending.player].heroClass]
    ask =
      if pending.count == 1: "Choose a card to discard."
      else: &"Choose {pending.count} cards to discard " &
        &"({play.tossPicks.len} of {pending.count} chosen)."
    banner = UiRect(
      origin: vec2(centerX - 430, HudHelperY),
      size: vec2(860, 112)
    )
  sk.drawHudNotice(banner)
  sk.drawLabel(ask, banner.origin + vec2(22, 10),
    vec2(banner.size.x - 44, 30), accent, "Prompt", CenterAlign)
  sk.drawLabel(&"{pending.source}: {pending.text}",
    banner.origin + vec2(22, 46), vec2(banner.size.x - 44, 28),
    HudIvory, "Small", CenterAlign)
  sk.drawLabel("Click cards in your hand. Right-click clears your picks.",
    banner.origin + vec2(22, 76), vec2(banner.size.x - 44, 28),
    HudMuted, "Small", CenterAlign)

proc drawTargetPrompt*(sk: Silky, window: Window, play: TablePlay,
    game: GameState, centerX = hudSize(window).x * 0.5'f32) =
  ## What to target, while the human is choosing: the rule's own words.
  if not play.pendingTargeting:
    return
  let
    card = play.pendingCard
    rules =
      if play.pendingTrigger: game.waitingTriggerRules().rules
      else: card.rules
    step = play.pendingPicks.len
    count = rules.targetCount()
    # The rules' own text: "Choose a minion." for "Deal 1 damage to
    # a minion."
    prompt = rules.targetPrompt(card, step)
    accent =
      HudClassInk[game.players[game.actingPlayer()].heroClass]
    progress = if count > 1: &" ({step + 1} of {count})" else: ""
    source = if play.pendingTrigger: &"{card.name}'s trigger" else: card.name
    hint =
      if play.pendingTrigger:
        "Click the empty board for no target."
      elif card.kind != Spell:
        "Right-click or the empty board: no target."
      else:
        "Right-click cancels."
    banner = UiRect(
      origin: vec2(
        centerX - 430,
        HudHelperY
      ),
      size: vec2(860, 112)
    )
  sk.drawHudNotice(banner)
  sk.drawLabel(
    prompt.choose & progress,
    banner.origin + vec2(22, 10),
    vec2(banner.size.x - 44, 30),
    accent,
    "Prompt",
    CenterAlign
  )
  sk.drawLabel(
    &"{source}: {prompt.rule}",
    banner.origin + vec2(22, 46),
    vec2(banner.size.x - 44, 28),
    HudIvory,
    "Small",
    CenterAlign
  )
  sk.drawLabel(
    hint,
    banner.origin + vec2(22, 76),
    vec2(banner.size.x - 44, 28),
    HudMuted,
    "Small",
    CenterAlign
  )

proc drawCombatPrompt*(sk: Silky, window: Window, play: TablePlay,
    game: GameState, centerX = hudSize(window).x * 0.5'f32) =
  ## What to attack, while the human's attacker is selected.
  if play.selectedAttacker == 0 or play.pendingTargeting:
    return
  let
    accent =
      HudClassInk[game.players[game.currentPlayer].heroClass]
    instruction =
      if play.attackActive: "Attacking!"
      else: "Click an enemy minion or hero. Right-click cancels."
    banner = UiRect(
      origin: vec2(
        centerX - 430,
        HudHelperY
      ),
      size: vec2(860, 84)
    )
  sk.drawHudNotice(banner)
  sk.drawLabel(
    "COMBAT",
    banner.origin + vec2(22, 10),
    vec2(banner.size.x - 44, 30),
    accent,
    "Prompt",
    CenterAlign
  )
  sk.drawLabel(
    instruction,
    banner.origin + vec2(22, 46),
    vec2(banner.size.x - 44, 28),
    HudIvory,
    "Small",
    CenterAlign
  )

proc drawMatchResult*(sk: Silky, window: Window, play: TablePlay,
    game: GameState, humanSeat: int,
    centerX = hudSize(window).x * 0.5'f32,
    names: openArray[string] = []) =
  ## Who won, once the match is over and the table has settled. `humanSeat`
  ## is the player reading it as "you", or -1.
  if not game.gameOver or not play.presentationIdle(game):
    return
  let
    winnerAccent =
      game.players[game.winner].heroClass.classUiColor()
    winnerText =
      if game.winner in 0 ..< names.len:
        game.playerName(game.winner, names) & " WINS!"
      elif humanSeat >= 0:
        (if game.winner == humanSeat: "YOU WIN!" else: "YOU LOSE!")
      else:
        &"PLAYER {game.winner + 1} WINS!"
    winnerDetail =
      &"Turn {game.turnNumber}: " &
      (if game.winner in 0 ..< names.len:
        game.playerName(game.winner, names) & " is victorious."
      else:
        game.players[game.winner].heroClass.className() & " is victorious.")
    overlay = UiRect(
      origin: vec2(
        centerX - 380,
        hudSize(window).y * 0.5'f32 - 80),
      size: vec2(760, 160))
  let winnerFont =
    if sk.getTextSize("H1", winnerText).x <= overlay.size.x: "H1"
    else: "Heading"
  sk.drawHudNotice(overlay)
  sk.drawLabel(
    sk.fittedLabel(winnerText, overlay.size.x, winnerFont),
    overlay.origin + vec2(0, 18),
    vec2(overlay.size.x, 70),
    winnerAccent,
    winnerFont,
    CenterAlign
  )
  sk.drawLabel(
    sk.fittedLabel(winnerDetail, overlay.size.x, "Default"),
    overlay.origin + vec2(0, 100),
    vec2(overlay.size.x, 40),
    rgbx(205, 209, 219, 255),
    "Default",
    CenterAlign
  )

proc drawPileTooltip*(sk: Silky, window: Window,
    pile: tuple[found: bool, player: int, discarded: bool, count: int,
      anchor: Vec3],
    viewProjection: Mat4, avoid = UiRect(), avoiding = false) =
  ## How many cards the hovered deck or discard pile holds, above the pile.
  ## Nothing is drawn where it would lie across `avoid` (the inspector),
  ## rather than leaving a cropped fragment beside the card.
  if not pile.found:
    return
  let origin = screenPosition(window, pile.anchor, viewProjection) /
    hudScale(window) + vec2(-77, -22)
  if avoiding and origin.x < avoid.origin.x + avoid.size.x and
      origin.x + 154 > avoid.origin.x and
      origin.y < avoid.origin.y + avoid.size.y and
      origin.y + 44 > avoid.origin.y:
    return
  sk.hudSprite("pile-label", origin, vec2(154, 44))
  sk.drawLabel((if pile.discarded: "DISCARD " else: "DECK ") & $pile.count,
    origin + vec2(5, 0), vec2(144, 44), HudIvory, "Small", CenterAlign)

proc addHudHalo*(renderer: var VfxRenderer, window: Window, rect: UiRect,
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
