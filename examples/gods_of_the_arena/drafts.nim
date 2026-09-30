import
  pixie, silky, vmath, windy,
  polyworld/[chrome, configs, gameuis],
  assets, content, controls, game, layouts, presets, sim

const
  Gold = rgbx(248, 199, 85, 255)
  Muted = rgbx(163, 175, 192, 255)
  White = rgbx(241, 244, 250, 255)
  CardFill = rgbx(24, 36, 49, 255)
  CardHover = rgbx(35, 49, 64, 255)
  DraftClasses = [
    VanguardKnight, DeathKnight, Ranger, Crossbowman, Arcanist,
    Lich, DruidWarden, Warlock, DemonHunter, Berserker
  ]

var selectedClass = -1'i32

proc playerName(index: int): string =
  ## Uses the match roster's display name for every draft participant.
  run.config.players[index].displayName(index)

proc teamColor(team: Team): ColorRGBX =
  ## Shares the arena's warm red and cool blue team accents.
  if team == RedTeam: rgbx(231, 104, 95, 255)
  else: rgbx(110, 174, 247, 255)

proc drawDraft*(sk: Silky, window: Window, size: Vec2, playing: bool) =
  ## Presents portrait choices and locks in the active human player's hero.
  let
    scale = draftScale(size)
    draftSize = size / scale
    mousePos = sk.mousePos
    layer = sk.drawer.currentLayer
    firstVertex = sk.vertexMark()
  sk.mousePos /= scale
  defer:
    sk.mousePos = mousePos
    # Scale the picker, its text, and its clips together before drawing the HUD.
    for i in firstVertex ..< sk.drawer.layers[layer].len:
      sk.drawer.layers[layer][i].pos *= scale
      sk.drawer.layers[layer][i].clipPos *= scale
      sk.drawer.layers[layer][i].clipSize *= scale
  let
    world = run.world
    layout = draftPanels(draftSize)
    activeId = world.draftHeroId()
    activeIndex = world.heroIndex(activeId)
    active = world.heroes[activeIndex]
    playerIndex = options.playerSlot.int - 1
    canPick = playerIndex == activeIndex and not run.replayMode and
      not run.historyPlayback
    accent = teamColor(active.team)
    secondsLeft = (world.draftTicksLeft() + TickRate - 1) div TickRate
    name = sk.fittedLabel(playerName(activeIndex), 280, "Bold")
    status =
      (if canPick: "Your turn" else: name & " is picking") & "  /  " &
      (if active.team == RedTeam: "Red team" else: "Blue team") &
      "  /  Pick " & $(world.draftTurn + 1) & " of " & $world.heroes.len &
      "  /  " & $secondsLeft & "s left"
  sk.drawRect(vec2(0), draftSize, rgbx(12, 21, 30, 255))
  sk.drawLabel(
    world.draftMode.draftName() & " / Choose your hero",
    layout.title.origin,
    layout.title.size,
    White,
    "H1",
    CenterAlign
  )
  sk.drawLabel(status, layout.status.origin, layout.status.size,
    accent, "Bold", CenterAlign)
  sk.drawSprite(
    WhiteTileKey,
    layout.deadline.origin,
    layout.deadline.size,
    CardHover,
    radius = 4
  )
  sk.drawSprite(
    WhiteTileKey,
    layout.deadline.origin,
    vec2(layout.deadline.size.x * world.draftTicksLeft().float32 /
      DraftPickTicks.float32, layout.deadline.size.y),
    if secondsLeft <= 3: Gold else: accent,
    radius = 4
  )
  if selectedClass >= 0 and not world.heroAvailable(selectedClass):
    selectedClass = -1
  for i, class in DraftClasses:
    let
      card = layout.heroes[i]
      available = world.heroAvailable(class.ord.int32)
      hovered = sk.hovered(card)
      selected = class.ord == selectedClass
      fill =
        if not available: rgbx(25, 30, 36, 255)
        elif hovered and canPick: CardHover
        else: CardFill
      portraitSize = min(card.size.x - 8, card.size.y - 32)
      portraitOrigin = card.origin + vec2(
        (card.size.x - portraitSize) / 2, card.size.y - 32 - portraitSize
      )
      label = GameUiPanel(
        origin: card.origin + vec2(4, card.size.y - 32),
        size: vec2(card.size.x - 8, 28)
      )
    if selected:
      sk.drawSprite(WhiteTileKey, card.origin - vec2(3),
        card.size + vec2(6), Gold, radius = 9)
    sk.drawSprite(WhiteTileKey, card.origin, card.size, fill, radius = 6)
    sk.drawSprite(
      if available: HeroPortraitKeys[class] else: class.draftedPortraitKey(),
      portraitOrigin,
      vec2(portraitSize),
      if available: White else: rgbx(125, 125, 125, 255)
    )
    sk.drawLabel(class.heroSpec.name, label.origin, label.size,
      if available: White else: Muted, "Bold", CenterAlign)
    if not available:
      for index, hero in world.heroes:
        if hero.drafted and hero.class == class and
          (world.draftMode == UniqueDraft or hero.team == active.team):
            let
              badge = GameUiPanel(
                origin: card.origin + vec2(6), size: vec2(card.size.x - 12, 24)
              )
              pickedBy =
                (if hero.team == RedTeam: "Red " else: "Blue ") &
                $(hero.slot + 1) & ": " & playerName(index)
            sk.drawSprite(WhiteTileKey, badge.origin, badge.size,
              rgbx(12, 18, 25, 230), radius = 4)
            sk.drawLabel(sk.fittedLabel(pickedBy, badge.size.x - 8, "Small"),
              badge.origin, badge.size, Muted, "Small", CenterAlign)
            break
    if canPick and available and hovered and window.buttonPressed[MouseLeft]:
      selectedClass = class.ord.int32
  let
    enabled = canPick and selectedClass >= 0 and playing
    title =
      if selectedClass >= 0: HeroClass(selectedClass).heroSpec.name
      elif canPick: "Select a hero"
      else: name & " is picking"
    detail =
      if not playing: "Paused. Press Space to resume."
      elif selectedClass >= 0: HeroClass(selectedClass).heroSpec.role
      else: "A random available hero is picked when time runs out."
    button = layout.confirm
  sk.drawLabel(title, layout.selection.origin, layout.selection.size,
    White, "Bold")
  sk.drawLabel(detail, layout.role.origin, layout.role.size, Muted, "Small")
  sk.drawSprite(
    WhiteTileKey,
    button.origin,
    button.size,
    if enabled: Gold else: CardFill,
    radius = 6
  )
  sk.drawLabel(if canPick: "LOCK IN HERO" else: "WAITING FOR PICK",
    button.origin, button.size,
    if enabled: rgbx(22, 24, 28, 255) else: Muted, "Bold", CenterAlign)
  if enabled and sk.hovered(button) and window.buttonPressed[MouseLeft]:
    queueDraft(activeId, selectedClass)
    selectedClass = -1
