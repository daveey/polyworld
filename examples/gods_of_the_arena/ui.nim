## Gods of the Arena Silky HUD.

import
  std/[strformat, strutils],
  chroma, pixie, silky, vmath, windy,
  polyworld/[stats, metrics, actioncam, chrome, configs, gameuis, inputs, pathing, player, rtscameras,
    stackpanels, profiles],
  assets, content, sim, game, controls, layouts, shops, maps, events, drafts

const
  ## Icons draw at power-of-two sizes so the 128 and 256 px source art
  ## lands on exact mip levels and stays crisp.
  IconTiny = 16.0'f32
  IconSmall = 64.0'f32
  IconLarge = 128.0'f32
  BadgeSmall = 16.0'f
  BadgeLarge = 64.0'f32
  AbilityKeys = ["Q", "W", "E", "R", "F", "G"]
  ScoreIcons = ["tower", "kills", "deaths"]
  CooldownFill = rgbx(8, 10, 16, 180)
  IconTint = rgbx(245, 230, 190, 255)
  ManaColor* = rgbx(238, 202, 65, 255)

type
  HudChrome = object
    layout: GameUiLayout
    score: GameUiPanel
    heroes: GameUiPanel
    clock: GameUiPanel
    minimap: GameUiPanel
    details: GameUiPanel
    inventory: GameUiPanel
  SelectedKind = enum
    SelectedHero,
    SelectedTower,
    SelectedBarracks,
    SelectedMob,
    SelectedGod

  SelectedUnit = object
    id: int32
    kind: SelectedKind
    team: Team
    neutral: bool
    portraitKey: string
    callsign: string
    classLabel: string
    status: string
    hp: float32
    maxHp: float32
    mana: float32
    maxMana: float32
    xp: int
    nextXp: int
    gold: int
    level: int
    damage: int32
    attackCasting: CastKind
    moveSpeed: float32
    attackSpeed: float32
    attackRange: float32
    inventory: array[InventorySlots, Item]
    itemCounts: array[InventorySlots, int32]
    portalCooldown, channelTicks: int32
    itemCooldowns: array[InventorySlots, int32]
    abilities: array[HeroAbilitySlot, Ability]
    abilityLevels: array[HeroAbilitySlot, int32]
    abilityPoints: int32
    cooldowns: array[HeroAbilitySlot, int32]
    charges: array[HeroAbilitySlot, int32]
    recharges: array[HeroAbilitySlot, int32]

proc placeChrome(layout: GameUiLayout): HudChrome =
  ## Places every textured HUD panel in one layout space.
  result.layout = layout
  result.score = layout.scorePanel()
  result.heroes = layout.panel(GameUiRegion.TopCenter, PanelHeroes)
  result.clock = layout.panel(GameUiRegion.TopRight, PanelClock)
  result.minimap = layout.panel(GameUiRegion.BottomLeft, PanelMinimap)
  result.details = layout.panel(GameUiRegion.BottomCenter, PanelDetails)
  result.inventory = layout.panel(
    GameUiRegion.BottomRight,
    PanelInventory
  )

proc currentLayout*(window: Window): GameUiLayout =
  ## Returns the nine-region HUD layout in Silky layout space.
  initGameUiLayout(
    vec2(window.size.x.float32, window.size.y.float32) /
      gameUiScale(window),
    TransportHeight
  )

var
  statsState: StatsState
  statsGame: Game
  statsTable: StatsTable
  playerNames: seq[string]
  fittedNames: seq[string]
  fittedNameWidth = -1.0'f
  showCreepWaypoints* = false

proc currentMetrics(slot: int, complete: bool): MetricRow =
  ## Combines authoritative totals with live or original replay telemetry.
  result = run.metrics.read(slot, run.world.tick, complete)
  if run.historyPlayback:
    result = result.withTelemetry(
      run.history, slot, run.world.tick, complete
    )
  if run.replayMode:
    result = result.withTelemetry(
      run.replayData.metrics, slot, run.world.tick, complete
    )

proc currentStats(): lent StatsTable =
  ## Updates retained rows while keeping roster names across frames and seeks.
  run.sampleMetrics()
  let fresh = statsGame != run or statsTable.rows.len != run.world.heroes.len
  if fresh:
    statsGame = run
    playerNames.setLen(run.world.heroes.len)
    fittedNames.setLen(run.world.heroes.len)
    fittedNameWidth = -1
    statsTable.rows.setLen(run.world.heroes.len)
    for slot in 0 ..< playerNames.len:
      playerNames[slot] = run.config.players[slot].displayName(slot)
  statsTable.kind = GotaStats
  statsTable.tick = run.world.tick
  statsTable.complete = run.finished()
  statsTable.winner =
    if run.world.gameOver and not run.world.draw: run.world.winner.ord
    else: -1
  statsTable.kills = run.world.teamHeroKills
  var index = 0
  for team in [BlueTeam, RedTeam]:
    for slot, hero in run.world.heroes:
      if hero.team != team:
        continue
      let row = addr statsTable.rows[index]
      if fresh:
        row.name = playerNames[slot]
      row.slot = slot
      row.subtitle = HeroSpecs[hero.class].name
      row.portrait = HeroPortraitKeys[hero.class]
      row.team = team.ord
      row.fallen = hero.state == Dying
      row.selected = not run.replayMode and options.playerSlot == slot + 1
      row.metrics = currentMetrics(slot, statsTable.complete)
      inc index
  statsTable

proc statsContains(window: Window, mouse: Vec2): bool =
  ## Tests the overlay before allowing input through to the existing HUD.
  if not statsState.visible(window.tabHeld):
    return false
  statsState.mouseOverStats(window, currentLayout(window),
    currentStats(), mouse)

proc hudClicked(window: Window, sk: Silky, panel: GameUiPanel): bool =
  ## Keeps covered HUD controls from receiving an overlay click.
  not window.statsContains(sk.mousePos) and chrome.clicked(window, sk, panel)

proc drawBuyback(
    sk: Silky,
    window: Window,
    panel: GameUiPanel,
    hero: Hero,
    controlled, playing: bool
) =
  ## Shows the death countdown and a priced buyback in the inventory area.
  let
    price = run.world.buybackPrice(hero.id)
    reason = run.world.buybackReason(hero.id)
    enabled = controlled and reason.len == 0 and not run.historyPlayback
    seconds = (hero.respawnTicks() + TickRate - 1) div TickRate
    gold = rgbx(247, 221, 143, 255)
    muted = rgbx(163, 175, 192, 255)
  sk.drawRect(panel.origin, panel.size, rgbx(8, 12, 20, 255))
  var rows = panel.stack(TopToBottom, vec2(4))
  let
    countdown = rows.takeRow(28, 8)
    button = rows.takeRow(44, 8)
    status = rows.takeRest()
  hudScratch.setLen(0)
  hudScratch.add "Respawn in "
  hudScratch.addHudInt(seconds.int)
  hudScratch.add 's'
  sk.drawLabel(
    hudScratch,
    countdown.origin,
    countdown.size,
    gold,
    "Bold",
    CenterAlign
  )
  sk.drawTab(button, hovered = enabled and sk.hovered(button))
  hudScratch.setLen(0)
  hudScratch.add "BUYBACK  "
  hudScratch.addHudInt(price.int)
  hudScratch.add " gold"
  sk.drawLabel(
    hudScratch,
    button.origin,
    button.size,
    if enabled: gold else: muted,
    "Small",
    CenterAlign
  )
  sk.drawLabel(
    if reason.len > 0: reason
    elif not controlled or run.historyPlayback: "Awaiting respawn"
    elif not playing: "Resume to complete buyback"
    else: "Return to your spawn now",
    status.origin,
    status.size,
    muted,
    "Small",
    CenterAlign
  )
  if enabled and window.hudClicked(sk, button):
    queueBuyback(hero.id)
    armedAbility = -1
    armedItem = -1

proc currentChrome(window: Window): HudChrome =
  ## Places every textured HUD panel for the current window.
  placeChrome(currentLayout(window))

proc mouseOverUi*(
    window: Window,
    mouse: Vec2,
    primaryId = 0'i32
): bool =
  ## Returns whether the pointer is over a visible game UI panel.
  if run.world.phase == Drafting or shopOpen or
    window.statsContains(mouse) or mouseOverDebugMenu(mouse):
      return true
  let chrome = currentChrome(window)
  if primaryId == 0:
    result = mouseOverPanels(
      mouse,
      chrome.layout,
      [
        chrome.score,
        chrome.heroes,
        chrome.clock,
        chrome.minimap,
        chrome.inventory
      ]
    )
  else:
    result = mouseOverPanels(
      mouse,
      chrome.layout,
      [
        chrome.score,
        chrome.heroes,
        chrome.clock,
        chrome.minimap,
        chrome.details,
        chrome.inventory
      ]
    )

proc renderPoint(position: WorldPoint): Vec3 =
  ## Converts authoritative integer coordinates at the HUD boundary.
  vec3(
    position.x.float32 / WorldScale.float32,
    position.y.float32 / WorldScale.float32,
    position.z.float32 / WorldScale.float32
  )

proc teamHudColor*(team: Team): ColorRGBX =
  ## Returns the team's color for HUD markers and health bars.
  if team == RedTeam:
    rgbx(224, 80, 83, 255)
  else:
    rgbx(76, 128, 232, 255)

proc classLabel(style: HeroAttackStyle): string =
  ## Returns the compact class word shown under a hero name.
  case style
  of MeleeAttack:
    "MELEE"
  of RangedAttack:
    "RANGER"
  of MagicAttack:
    "MAGE"

proc callsign(name: string): string =
  ## Returns the first name word in HUD capitals.
  var word = name
  let space = name.find(' ')
  if space >= 0:
    word = name[0 ..< space]
  toUpperAscii(word)

const HeroCallsigns = block:
  var names: array[HeroClass, string]
  for class in HeroClass:
    names[class] = callsign(HeroSpecs[class].name)
  names

proc remainingTowers(team: Team): int =
  ## Counts the towers still standing for one team.
  for tower in run.world.buildings:
    if tower.kind == TowerBuilding and tower.team == team and tower.hp > 0:
      inc result

proc clockHour*(): float32 =
  ## The accelerated spectator clock in hours, 0 ..< 24 with a fraction:
  ## the match starts at 8:00 and a day is five minutes long.
  clockHour(run.world.battleTick(), TickRate)

proc currentHudTime(): tuple[day, hour, minute: int] =
  ## Converts simulation ticks into the accelerated spectator clock.
  hudClock(run.world.battleTick(), TickRate)

proc visibleInView(
    viewMode: int32,
    team: Team,
    position: WorldPoint
): bool =
  ## Applies the current omniscient or team visibility spectator mode.
  if viewMode == 0:
    return true
  let viewingTeam = Team(viewMode - 1)
  team == viewingTeam or visible(run.world, viewingTeam, position)

proc visibleInView(viewMode: int32, unit: Footman): bool =
  ## Neutral mobs never inherit allied visibility from navigation orientation.
  if unit.camp == 0:
    return visibleInView(viewMode, unit.team, unit.position)
  viewMode == 0 or visible(run.world, Team(viewMode - 1), unit.position)

proc unitHudColor(unit: Footman): ColorRGBX =
  ## Distinguishes neutral mobs from the two playable factions.
  if unit.camp > 0: rgbx(242, 184, 61, 255)
  else: teamHudColor(unit.team)

proc isPicked(id: int32, selectedIds: openArray[int32]): bool =
  ## Returns whether an object belongs to the current selection set.
  for selectedId in selectedIds:
    if selectedId == id:
      return true

proc selectedUnit(id: int32, viewMode: int32): SelectedUnit {.measure.} =
  ## Builds the current flat view of one selectable world object.
  for hero in run.world.heroes:
    if hero.id == id:
      if not visibleInView(viewMode, hero.team, hero.position):
        return SelectedUnit()
      let
        spec = hero.class.heroSpec
        moveSpeed = hero.heroMoveSpeed.float32 *
          TickRate.float32 / WorldScale.float32
        attackRange = heroAttackRange(hero.class).float32 /
          WorldScale.float32
        attackTicks = run.world.heroAttackTicks(hero).float32
      return SelectedUnit(
        id: hero.id,
        kind: SelectedHero,
        team: hero.team,
        portraitKey: HeroPortraitKeys[hero.class],
        callsign: HeroCallsigns[hero.class],
        classLabel: classLabel(spec.attackStyle),
        status:
          if hero.state == Dying: "Respawning"
          elif hero.portalEnds > run.world.tick: "Teleporting"
          elif hero.controls[StunControl].ends > run.world.tick: "Stunned"
          elif hero.controls[RootControl].ends > run.world.tick: "Rooted"
          elif hero.controls[SilenceControl].ends > run.world.tick: "Silenced"
          elif hero.inOwnSpawn: "Spawn recovery"
          elif hero.recoveryItems != default(typeof(hero.recoveryItems)):
            "Regenerating"
          else: "Ready",
        hp: max(hero.hp, 0'i32).float32,
        maxHp: hero.maxHp.float32,
        mana: hero.mana.float32,
        maxMana: hero.maxMana.float32,
        xp: hero.xp,
        nextXp:
          if hero.level < HeroMaxLevel:
            xpForNextLevel(hero.level)
          else:
            hero.xp,
        gold: hero.gold,
        level: hero.level,
        damage: hero.heroAttackDamage,
        attackCasting: hero.class.heroAttackCasting,
        moveSpeed: moveSpeed,
        attackSpeed: TickRate.float32 / max(attackTicks, 1),
        attackRange: attackRange,
        inventory: hero.inventory,
        itemCounts: hero.itemCounts,
        itemCooldowns: hero.itemCooldowns(run.world.tick),
        portalCooldown: max(0'i32, hero.portalCooldownEnds - run.world.tick),
        channelTicks: max(0'i32, hero.portalEnds - run.world.tick),
        abilities: spec.abilities,
        abilityLevels: hero.abilityLevels,
        abilityPoints: hero.abilityPoints,
        charges: hero.charges,
        recharges: hero.recharges,
        cooldowns: hero.cooldowns
      )
  for footman in run.world.footmen:
    if footman.id == id:
      if not visibleInView(viewMode, footman):
        return SelectedUnit()
      let
        moveSpeed = FootmanMovePerTick.float32 *
          TickRate.float32 / WorldScale.float32
        attackRange = footman.kind.footmanAttackRange.float32 /
          WorldScale.float32
      return SelectedUnit(
        id: footman.id,
        kind: SelectedMob,
        team: footman.team, neutral: footman.camp > 0,
        callsign: if footman.camp > 0: NeutralNames[footman.appearance]
          elif footman.kind == RangedCreep: "CASTER" else: "FOOTMAN",
        classLabel: if footman.camp > 0:
          (if footman.leader: ["LOW LEADER", "MEDIUM LEADER", "HIGH LEADER"]
            else: ["LOW CAMP", "MEDIUM CAMP", "HIGH CAMP"])[footman.campTier - 1]
          elif footman.kind == RangedCreep: "RANGED" else: "MELEE",
        status:
          if footman.state == Dying: "Dying"
          elif footman.camp > 0:
            case run.world.camps[footman.camp - 1].state
            of RestingCamp: "Resting"
            of FightingCamp: "Defending camp"
            of ReturningCamp: "Returning home"
            of EmptyCamp: "Cleared"
          elif footman.state == Fighting: "Fighting"
          else: "Marching",
        hp: max(footman.hp, 0'i32).float32,
        maxHp: footman.unitMaxHp.float32,
        level: 1,
        damage: footman.unitDamage,
        moveSpeed: moveSpeed,
        attackSpeed: TickRate.float32 / footmanAttackTicks(attackClips[0]).float32,
        attackRange: attackRange
      )
  for tower in run.world.buildings:
    if tower.id == id:
      if tower.hp <= 0:
        return SelectedUnit()
      if not visibleInView(viewMode, tower.team, tower.position):
        return SelectedUnit()
      let
        role =
          case tower.tier
          of OuterTower:
            "OUTER"
          of InnerTower:
            "INNER"
          of GateTower:
            "GATE"
        attackRange = TowerAttackRanges[tower.tier].float32 /
          WorldScale.float32
      return SelectedUnit(
        id: tower.id,
        kind: (if tower.kind == BarracksBuilding: SelectedBarracks
          else: SelectedTower),
        team: tower.team,
        callsign: (if tower.kind == BarracksBuilding: "BARRACKS"
          elif tower.guardsGod: "GOD GUARD" else: role),
        classLabel: (if tower.kind == BarracksBuilding: "BARRACKS" else: "TOWER"),
        status:
          if tower.hp <= 0:
            "Destroyed"
          elif buildingExposed(run.world, tower):
            "Exposed"
          else:
            "Protected",
        hp: max(tower.hp, 0'i32).float32,
        maxHp: tower.maxHp.float32,
        level: tower.tier.ord + 1,
        damage: (if tower.kind == TowerBuilding: TowerDamages[tower.tier] else: 0),
        attackRange: (if tower.kind == TowerBuilding: attackRange else: 0)
      )
  for fort in run.world.forts:
    if fort.id == id:
      if not visibleInView(viewMode, fort.team, fort.center):
        return SelectedUnit()
      return SelectedUnit(
        id: fort.id,
        kind: SelectedGod,
        team: fort.team,
        callsign: "GOD",
        classLabel: (if fort.team == RedTeam: "WARLOCK" else: "DRUID"),
        status:
          if fort.hp <= 0: "Fallen"
          elif fortExposed(run.world, fort.team): "Exposed"
          else: "Protected by god guards",
        hp: max(fort.hp, 0'i32).float32,
        maxHp: FortHp.float32,
        level: 1
      )

proc selectHeroCard(
    primaryId: var int32,
    selectedIds: var seq[int32],
    followSelection: var bool,
    id: int32,
    additive: bool
) =
  ## Selects or toggles one hero from a HUD portrait click.
  var found = false
  for hero in run.world.heroes:
    if hero.id == id:
      found = true
      break
  if not found:
    return
  if not additive:
    selectedIds.setLen(0)
  elif isPicked(id, selectedIds) and selectedIds.len > 1:
    for i in 0 ..< selectedIds.len:
      if selectedIds[i] == id:
        selectedIds.delete(i)
        break
    if primaryId == id:
      primaryId = selectedIds[0]
    followSelection = selectedIds.len > 0
    return
  if not isPicked(id, selectedIds):
    selectedIds.add id
  primaryId = id
  followSelection = true

proc minimapMap(panel: GameUiPanel): GameUiPanel =
  ## Returns the map rectangle inside the minimap plate's frame.
  panel.inset(8)

proc minimapAim*(window: Window, mouse: Vec2, point: var Vec2): bool =
  ## Resolves a map destination when the pointer is inside the minimap.
  let area = currentChrome(window).minimap.minimapMap()
  if window.statsContains(mouse) or not area.contains(mouse):
    return false
  point = minimapWorldPoint(mouse, area.origin, area.size, mapHalfSize())
  true

proc updateMinimapCamera*(
    window: Window,
    mouse: Vec2,
    cameraTarget: var Vec3,
    minimapPanning: var bool,
    followSelection: var bool
) =
  ## Moves the free camera while the primary button drags on the minimap.
  if window.statsContains(mouse):
    minimapPanning = false
    return
  let
    chrome = currentChrome(window)
    area = chrome.minimap.minimapMap()
  if window.mousePressed(MouseLeft) and area.contains(mouse):
    minimapPanning = true
    followSelection = false
  if not window.mouseDown(MouseLeft):
    minimapPanning = false
  if minimapPanning:
    let point = minimapWorldPoint(
      mouse,
      area.origin,
      area.size,
      mapHalfSize()
    )
    cameraTarget.x = point.x
    cameraTarget.z = point.y
    cameraTarget.y = surfaceHeight(point.x, point.y)

proc minimapPosition(position: Vec3, panel: GameUiPanel): Vec2 =
  ## Projects a world position into the minimap's inner rectangle.
  let area = panel.minimapMap()
  let
    x = clamp(
      (position.x + mapHalfSize()) / (mapHalfSize() * 2),
      0.0'f32,
      1.0'f32
    )
    y = clamp(
      (position.z + mapHalfSize()) / (mapHalfSize() * 2),
      0.0'f32,
      1.0'f32
    )
  area.origin + vec2(x * area.size.x, y * area.size.y)

proc drawMinimapIcon(
    sk: Silky,
    name: string,
    point: Vec2,
    size: float32,
    color: ColorRGBX,
    selected = false
) =
  ## Draws a team glyph with a dark outline or a selection highlight.
  let
    outline = if selected: rgbx(255, 242, 187, 255)
      else: rgbx(16, 19, 24, 255)
    outlineSize = size + (if selected: 4.0'f else: 2.0'f)
  sk.drawSprite(
    name,
    point - vec2(outlineSize / 2),
    vec2(outlineSize),
    outline
  )
  sk.drawSprite(name, point - vec2(size / 2), vec2(size), color)

proc drawMinimapHero(
    sk: Silky,
    hero: Hero,
    point: Vec2,
    selected: bool
) =
  ## Points a map marker along the heading beneath an upright hero portrait.
  const
    MarkerSize = 48.0'f
    MarkerCenter = vec2(0.5'f, 50.0'f / 128.0'f)
    Corners = [vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 1)]
  let
    entry = sk.atlas.entries["map_marker"]
    uvOrigin = vec2(entry.x.float32, entry.y.float32)
    uvSize = vec2(entry.width.float32, entry.height.float32)
    markerColor = if selected: rgbx(255, 242, 187, 255) else: IconTint
  var forward = vec2(hero.facing.x.float32, hero.facing.z.float32)
  if lengthSq(forward) > 0:
    forward = normalize(forward)
  else:
    forward = vec2(0, 1)
  let right = vec2(forward.y, -forward.x)
  var positions, uvs: array[4, Vec2]
  for i, corner in Corners:
    # The source marker points down, with its circular head above center.
    let offset = (corner - MarkerCenter) * MarkerSize
    positions[i] = point + right * offset.x + forward * offset.y
    uvs[i] = uvOrigin + corner * uvSize
  for indices in [[0, 1, 2], [0, 2, 3]]:
    sk.drawTriangle(
      [positions[indices[0]], positions[indices[1]], positions[indices[2]]],
      [uvs[indices[0]], uvs[indices[1]], uvs[indices[2]]],
      [markerColor, markerColor, markerColor]
    )
  sk.drawSprite(
    WhiteTileKey,
    point - vec2(10),
    vec2(20),
    teamHudColor(hero.team),
    radius = 10
  )
  sk.drawSprite(
    HeroPortraitKeys[hero.class],
    point - vec2(8),
    vec2(16),
    radius = 8
  )

proc drawMinimapCamera(
    sk: Silky,
    window: Window,
    panel: GameUiPanel,
    cameraTarget: Vec3,
    cameraDistance: float32
) =
  ## Draws the fixed RTS camera's visible ground footprint.
  let
    area = panel.minimapMap()
    aspect = window.size.x.float32 / max(window.size.y.float32, 1)
  sk.drawCameraFrame(
    minimapViewport(
      cameraTarget,
      cameraDistance,
      aspect,
      area.origin,
      area.size,
      mapHalfSize()
    ),
    rgbx(255, 242, 187, 255)
  )

proc drawScoreRow(
    sk: Silky,
    panels: ScorePanels,
    team: Team,
    row: int
) =
  ## Draws one team's towers, kills, and deaths on a single row.
  let
    color = teamHudColor(team)
    values = [
      remainingTowers(team),
      run.world.teamHeroKills[team.ord],
      run.world.teamHeroDeaths[team.ord]
    ]
  sk.drawSprite(
    if team == RedTeam: "hostile" else: "alliance",
    panels.sides[row].origin,
    vec2(IconTiny),
    color
  )
  for i, cell in panels.values[row]:
    writeInt(hudScratch, values[i])
    sk.drawLabel(
      hudScratch,
      cell.origin,
      cell.size,
      color,
      "Default",
      CenterAlign
    )

proc heroCardIndex(hero: Hero): int =
  ## Returns one hero's slot in the two stacked team groups.
  int(clamp(hero.slot, 0, 4)) + (if hero.team == RedTeam: 0 else: 5)

proc drawHeroPortrait(
    sk: Silky,
    window: Window,
    panel: HeroPanels,
    hero: Hero,
    primaryId: var int32,
    selectedIds: var seq[int32],
    followSelection: var bool,
    actionCam: var ActionCam,
    focusPlayerHero: var bool
) =
  ## Draws one top-bar portrait on the hero plate.
  let
    portrait = panel.portrait
    picked = isPicked(hero.id, selectedIds)
  sk.drawWellImage(
    portrait,
    HeroPortraitKeys[hero.class],
    if hero.state == Dying or hero.hp <= 0:
      rgbx(140, 140, 148, 255)
    else:
      rgbx(255, 255, 255, 255),
    selected = picked,
    iconSize = IconSmall
  )
  if window.hudClicked(sk, portrait):
    actionCam.takeManual()
    selectHeroCard(
      primaryId,
      selectedIds,
      followSelection,
      hero.id,
      window.buttonDown[KeyLeftShift] or
        window.buttonDown[KeyRightShift]
    )
    if options.playerSlot > 0 and
        not run.replayMode and
        hero.id == run.world.heroes[options.playerSlot - 1].id:
      focusPlayerHero = true

proc drawHeroMeters(
    sk: Silky,
    panel: HeroPanels,
    hero: Hero
) =
  ## Draws one hero's bars and level on the hero plate.
  let
    portrait = panel.portrait
    hpBar = panel.hp
    manaBar = panel.mana
  sk.drawBar(
    hpBar.origin,
    hpBar.size,
    hero.hp.float32,
    hero.maxHp.float32,
    teamHudColor(hero.team)
  )
  sk.drawBar(
    manaBar.origin,
    manaBar.size,
    hero.mana.float32,
    hero.maxMana.float32,
    ManaColor
  )
  writeInt(hudScratch, hero.level)
  sk.drawBadge(
    portrait.origin + vec2(-4, portrait.size.y - BadgeSmall + 3),
    vec2(BadgeSmall),
    hudScratch
  )

proc drawStat(
    sk: Silky,
    panel: GameUiPanel,
    icon: string,
    value: string
) =
  ## Draws one compact stat icon and its numeric value.
  sk.drawSprite(
    icon,
    panel.origin + vec2(0, 1),
    vec2(16),
    IconTint
  )
  sk.drawLabel(
    value,
    panel.origin + vec2(20, 0),
    vec2(56, 18),
    rgbx(236, 238, 244, 255),
    "Small"
  )

proc drawAbilityIcon(
    sk: Silky,
    slot: GameUiPanel,
    icon: string,
    tint = rgbx(255, 255, 255, 255)
) =
  ## Draws one ability glyph inside a framed art slot.
  sk.drawWellImage(slot, icon, tint, iconSize = IconSmall)

proc drawCooldownSweep(
    sk: Silky,
    slot: GameUiPanel,
    remaining, duration: int32
) =
  ## Covers the unreadied portion of one ability well from the top.
  if remaining <= 0 or duration <= 0:
    return
  let height = slot.size.y * remaining.float32 / duration.float32
  sk.drawRect(slot.origin, vec2(slot.size.x, height), CooldownFill)

proc cooldownSeconds(remaining: int32): int32 =
  ## Rounds remaining ticks up to whole seconds for the HUD.
  (remaining + TickRate - 1) div TickRate

proc drawAbilityKey(
    sk: Silky,
    slot: GameUiPanel,
    key: string
) =
  ## Draws one hotkey pip in the corner of a framed art slot.
  sk.drawKeyPip(slot, key)

proc drawUi*(
    sk: Silky,
    window: Window,
    transport: var Player,
    cameraTarget: Vec3,
    cameraDistance: float32,
    viewMode: int32,
    primaryId: var int32,
    selectedIds: var seq[int32],
    followSelection: var bool,
    actionCam: var ActionCam,
    focusPlayerHero: var bool
) {.measure.} =
  ## Draws every Silky HUD panel for the current frame.
  if run.world.phase == Drafting:
    sk.drawDraft(window, currentLayout(window).gameAreaSize, transport.playing)
    transport.drawTransport(
      sk, window, currentLayout(window).transportPanel, actionCam,
      followSelection, addr statsState.toggled
    )
    return
  if shopOpen and options.playerSlot > 0 and not run.replayMode:
    sk.drawShop(window, run.world, run.world.heroes[options.playerSlot - 1],
      currentLayout(window).size, transport.playing)
    return
  profileBlock "HUD metrics":
    statsState.syncDirector(actionCam, currentStats(), window.tabHeld)
  let
    chrome = currentChrome(window)
    scorePanel = sk.beginFrame(chrome.score)
    scoreSlots = scorePanel.scorePanels()
    heroesPanel = sk.beginFrame(chrome.heroes)
    heroes = heroesPanel.heroPanels()
    clockPanel = sk.beginFrame(chrome.clock)
    clock = clockPanel.clockPanels()
    minimapPanel = sk.beginFrame(chrome.minimap)
    inventoryPanel = sk.beginFrame(chrome.inventory)
    inventory = inventoryPanel.inventoryPanels()
    details = chrome.details.detailsPanels()
    hudTime = currentHudTime()
  let detailId =
    if actionCam.enabled and actionCam.locked: actionCam.lockId
    else: primaryId
  var selection = selectedUnit(detailId, viewMode)
  if selection.id != 0:
    discard sk.beginFrame(chrome.details)

  for i, label in ["TOWERS", "KILLS", "DEATHS"]:
    let pos = scoreSlots.headers[i].origin
    sk.drawSprite(
      ScoreIcons[i], pos + vec2(0, 1), vec2(IconTiny), IconTint
    )
    sk.drawLabel(
      label,
      pos + vec2(IconTiny + 4, 0),
      vec2(68, 20),
      rgbx(166, 174, 190, 255),
      "Hud"
    )
  sk.drawScoreRow(scoreSlots, RedTeam, 0)
  sk.drawScoreRow(scoreSlots, BlueTeam, 1)

  for hero in run.world.heroes:
    sk.drawHeroPortrait(
      window,
      heroes[hero.heroCardIndex],
      hero,
      primaryId,
      selectedIds,
      followSelection,
      actionCam,
      focusPlayerHero
    )
  let nameWidth = heroes[0].name.size.x
  if fittedNameWidth != nameWidth:
    fittedNameWidth = nameWidth
    for slot in 0 ..< playerNames.len:
      fittedNames[slot] = sk.fittedLabel(playerNames[slot], nameWidth, "Small")
  for slot, hero in run.world.heroes:
    let panel = heroes[hero.heroCardIndex]
    sk.drawLabel(
      fittedNames[slot],
      panel.name.origin,
      panel.name.size,
      rgbx(166, 174, 190, 255),
      "Small",
      CenterAlign
    )
    sk.drawHeroMeters(panel, hero)
  sk.drawLabel(
    "vs",
    heroesPanel.origin + vec2(532, 57),
    vec2(26, 28),
    rgbx(166, 174, 190, 255),
    "HeroVersus"
  )

  sk.drawSprite(
    if hudTime.hour < 6 or hudTime.hour >= 18: "night" else: "day",
    clock.icon.origin + vec2(0, 2),
    vec2(22)
  )
  sk.drawLabel(
    "TIME OF DAY",
    clock.caption.origin,
    clock.caption.size,
    rgbx(193, 198, 210, 255),
    "Small"
  )
  writeClock(hudScratch, hudTime.hour, hudTime.minute)
  sk.drawLabel(
    hudScratch,
    clock.time.origin,
    clock.time.size,
    rgbx(247, 221, 143, 255),
    "H1",
    CenterAlign
  )

  let mapArea = minimapPanel.minimapMap()
  sk.drawFrame(
    GameUiPanel(origin: mapArea.origin, size: mapArea.size)
  )
  if run.map.minimap.len == mapTiles() * mapTiles():
    let tileSize = mapArea.size / mapTiles().float32
    for y in 0 ..< mapTiles():
      var x = 0
      while x < mapTiles():
        let color = run.map.minimap[y * mapTiles() + x]
        var finish = x + 1
        while finish < mapTiles() and
          run.map.minimap[y * mapTiles() + finish] == color:
            finish.inc
        sk.drawRect(
          mapArea.origin + vec2(x.float32, y.float32) * tileSize,
          vec2((finish - x).float32, 1) * tileSize,
          rgbx(
            uint8((color shr 16) and 255),
            uint8((color shr 8) and 255),
            uint8(color and 255),
            255
          )
        )
        x = finish
  sk.drawRect(
    mapArea.origin + mapArea.size * 0.5'f32 - vec2(2),
    vec2(4),
    rgbx(91, 119, 128, 255)
  )
  sk.pushClipRect(rect(mapArea.origin, mapArea.size))
  for tower in run.world.buildings:
    if tower.hp > 0 and
        visibleInView(viewMode, tower.team, tower.position):
      sk.drawMinimapIcon(
        (if tower.kind == BarracksBuilding: "barracks" else: "tower"),
        minimapPosition(renderPoint(tower.position), minimapPanel),
        16.0'f,
        teamHudColor(tower.team),
        isPicked(tower.id, selectedIds)
      )
  for fort in run.world.forts:
    if visibleInView(viewMode, fort.team, fort.center):
      sk.drawMinimapIcon(
        WhiteTileKey,
        minimapPosition(renderPoint(fort.center), minimapPanel),
        10.0'f,
        teamHudColor(fort.team),
        isPicked(fort.id, selectedIds)
      )
  for footman in run.world.footmen:
    if footman.state != Dying and footman.hp > 0 and
        visibleInView(viewMode, footman):
      sk.drawMinimapIcon(
        "contact",
        minimapPosition(renderPoint(footman.position), minimapPanel),
        8.0'f,
        unitHudColor(footman),
        isPicked(footman.id, selectedIds)
      )
  for hero in run.world.heroes:
    if visibleInView(viewMode, hero.team, hero.position):
      sk.drawMinimapHero(
        hero,
        minimapPosition(renderPoint(hero.position), minimapPanel),
        isPicked(hero.id, selectedIds)
      )
  sk.popClipRect()
  sk.drawMinimapCamera(
    window,
    minimapPanel,
    cameraTarget,
    cameraDistance
  )

  if selection.id != 0:
    let
      teamColor = if selection.neutral: rgbx(242, 184, 61, 255)
        else: teamHudColor(selection.team)
      portrait = details.portrait
    if selection.kind == SelectedHero:
      sk.drawWellImage(
        portrait, selection.portraitKey, iconSize = IconLarge
      )
    else:
      let glyph =
        case selection.kind
        of SelectedTower:
          "tower"
        of SelectedBarracks:
          "barracks"
        of SelectedMob:
          "minion"
        of SelectedGod:
          "fort"
        of SelectedHero:
          "champion"
      sk.drawWellImage(portrait, glyph, teamColor, iconSize = IconLarge)
    if window.hudClicked(sk, portrait) and
        selection.kind == SelectedHero and
        options.playerSlot > 0 and
        not run.replayMode and
        selection.id == run.world.heroes[options.playerSlot - 1].id:
      actionCam.takeManual()
      focusPlayerHero = true
    if selection.kind == SelectedHero:
      let
        basic = GameUiPanel(
          origin: portrait.origin + vec2(0, 158), size: vec2(40)
        )
        melee = selection.attackCasting == MeleeCast
      sk.drawWellImage(
        basic, if melee: "attack" else: "bow", iconSize = 32
      )
      sk.drawLabel(
        "BASIC ATTACK",
        basic.origin + vec2(46, 2),
        vec2(108, 18),
        rgbx(247, 221, 143, 255),
        "Small"
      )
      hudScratch.setLen(0)
      hudScratch.add(if melee: "Melee: " else: "Ranged: ")
      hudScratch.addHudInt(selection.damage.int)
      sk.drawLabel(
        hudScratch,
        basic.origin + vec2(46, 20),
        vec2(108, 18),
        rgbx(236, 238, 244, 255),
        "Small"
      )
      for slot in HeroAbilitySlot:
        let
          i = slot.ord
          well = details.abilities[i]
          spec = selection.abilities[slot].abilitySpec(
            selection.abilityLevels[slot]
          )
          empty = selection.charges[slot] == 0
          remaining =
            if empty: max(selection.cooldowns[slot], selection.recharges[slot])
            else: selection.cooldowns[slot]
        sk.drawAbilityIcon(
          well,
          abilityIconKey(selection.abilities[slot]),
          if remaining > 0 or selection.abilityLevels[slot] == 0:
            rgbx(150, 150, 158, 255)
          else:
            rgbx(255, 255, 255, 255)
        )
        sk.drawCooldownSweep(
          well, remaining, if empty: spec.rechargeTicks else: spec.cooldownTicks
        )
        if options.playerSlot > 0 and not run.replayMode and
          selection.id == run.world.heroes[options.playerSlot - 1].id:
            let
              hero = run.world.heroes[options.playerSlot - 1]
              upgrade = GameUiPanel(
                origin: well.origin + vec2(well.size.x - 23, 2),
                size: vec2(21, 20)
              )
              clickedUpgrade = hero.abilityLevelError(slot) == NoActionError and
                window.hudClicked(sk, upgrade)
            if window.hudClicked(sk, well):
              armedItem = -1
              armedAbility = -1
              if clickedUpgrade or window.buttonDown[KeyLeftShift] or
                window.buttonDown[KeyRightShift]:
                  queueLevelAbility(selection.id, slot.ord.int32)
                  armedAbility = -1
              elif selection.abilityLevels[slot] > 0:
                armedAbility = slot.ord.int32
              else:
                queueCastTarget(selection.id, slot.ord.int32, selection.id)
            if armedAbility == slot.ord.int32:
              let color = rgbx(255, 223, 133, 255)
              sk.drawRect(well.origin, vec2(well.size.x, 3), color)
              sk.drawRect(well.origin, vec2(3, well.size.y), color)
              sk.drawRect(well.origin + vec2(well.size.x - 3, 0),
                vec2(3, well.size.y), color)
              sk.drawRect(well.origin + vec2(0, well.size.y - 3),
                vec2(well.size.x, 3), color)
      for i in 0 .. 1:
        let
          well = details.abilities[4 + i]
          item = selection.inventory[i]
        if item != NoItem:
          sk.drawAbilityIcon(well, itemIconKey(item))
          sk.drawCooldownSweep(well, selection.itemCooldowns[i],
            item.itemSpec.cooldownTicks)
        else:
          sk.drawWellImage(well, "")
  let playerHero =
    options.playerSlot > 0 and not run.replayMode
  let playerHeroId =
    if playerHero:
      run.world.heroes[options.playerSlot - 1].id
    else:
      0'i32
  if playerHero:
    sk.drawTab(inventory.shop, hovered = sk.hovered(inventory.shop))
    sk.drawSprite("shop", inventory.shop.origin + vec2(6, 6), vec2(16))
    sk.drawLabel("SHOP  B", inventory.shop.origin + vec2(28, 0),
      inventory.shop.size - vec2(28, 0), rgbx(247, 221, 143, 255), "Small")
    if window.hudClicked(sk, inventory.shop):
      shopOpen = true
      armedAbility = -1
      armedItem = -1
  let inventoryHero =
    if playerHero: selectedUnit(playerHeroId, viewMode)
    else: selection
  for slot in 0 ..< InventorySlots:
    let
      slotPanel = inventory.slots[slot]
      item =
        if inventoryHero.id == 0: NoItem else: inventoryHero.inventory[slot]
    if item != NoItem:
      sk.drawWellImage(slotPanel, itemIconKey(item), iconSize = IconSmall)
      sk.drawCooldownSweep(slotPanel, inventoryHero.itemCooldowns[slot],
        item.itemSpec.cooldownTicks)
    else:
      sk.drawSlot(slotPanel)
    if playerHero and inventoryHero.id != 0 and inventoryHero.hp > 0 and
      window.hudClicked(sk, slotPanel):
        activatePlayerItem(run.world, playerHeroId, int32(slot))

  if selection.id != 0:
    let
      teamColor = if selection.neutral: rgbx(242, 184, 61, 255)
        else: teamHudColor(selection.team)
      badge = GameUiPanel(
        origin: details.portrait.origin + vec2(-18, 91),
        size: vec2(BadgeLarge)
      )
      namePos = details.name.origin
      classPos = details.class.origin
      hpBar = details.hp
      healthColor = if selection.neutral: rgbx(180, 180, 180, 255)
        else: teamColor
      manaBar = details.mana
      xpBar = details.xp
    if selection.kind == SelectedHero and selection.abilityPoints > 0:
      let count = selection.abilityPoints
      writeInt(hudScratch, count)
      hudScratch.add(if count == 1: " ability point" else: " ability points")
      hudScratch.add " | Shift + Q/W/E/R to learn"
      sk.drawLabel(
        hudScratch,
        hpBar.origin - vec2(0, 26),
        vec2(hpBar.size.x, 20),
        rgbx(247, 221, 143, 255),
        "Small"
      )
    writeInt(hudScratch, selection.level)
    sk.drawBadge(badge.origin, badge.size, hudScratch, font = "Bold")
    sk.drawLabel(
      selection.callsign,
      namePos,
      details.name.size,
      rgbx(255, 255, 255, 255),
      "Default"
    )
    sk.drawLabel(
      selection.classLabel,
      classPos,
      details.class.size,
      teamColor,
      "Small"
    )
    var stats = details.stats.stack(TopToBottom)
    writeInt(hudScratch, selection.damage.int)
    sk.drawStat(stats.takeRow(18), "damage", hudScratch)
    writeInt(hudScratch, selection.maxHp.int)
    sk.drawStat(stats.takeRow(18), "health", hudScratch)
    writeInt(hudScratch, (selection.moveSpeed * 100).int)
    sk.drawStat(
      stats.takeRow(18),
      "movement",
      hudScratch
    )
    writeRatio(hudScratch, selection.hp.int, selection.maxHp.int)
    sk.drawValueBar(
      hpBar.origin,
      hpBar.size,
      selection.hp,
      selection.maxHp,
      healthColor,
      hudScratch
    )
    sk.drawSprite(
      "health",
      hpBar.origin + vec2(4, 4),
      vec2(20),
      healthColor
    )
    if selection.maxMana > 0:
      sk.drawValueBar(
        manaBar.origin,
        manaBar.size,
        selection.mana,
        selection.maxMana,
        ManaColor,
        (writeRatio(hudScratch, selection.mana.int, selection.maxMana.int); hudScratch)
      )
      sk.drawSprite(
        "mana",
        manaBar.origin + vec2(4, 4),
        vec2(20),
        ManaColor
      )
    if selection.nextXp > 0:
      sk.drawValueBar(
        xpBar.origin,
        xpBar.size,
        selection.xp.float32,
        selection.nextXp.float32,
        rgbx(152, 86, 196, 255),
        (writeRatio(hudScratch, selection.xp, selection.nextXp); hudScratch)
      )
      sk.drawSprite(
        "experience",
        xpBar.origin + vec2(4, 4),
        vec2(20)
      )
    for i in 0 .. 5:
      let well = details.abilities[i]
      if i < 4 and selection.kind == SelectedHero:
        let
          slot = HeroAbilitySlot(i)
          remaining =
            if selection.charges[slot] == 0:
              max(selection.cooldowns[slot], selection.recharges[slot])
            else:
              selection.cooldowns[slot]
        if remaining > 0:
          writeInt(hudScratch, cooldownSeconds(remaining).int)
          sk.drawLabel(
            hudScratch,
            well.origin,
            well.size,
            rgbx(247, 221, 143, 255),
            "Hud",
            CenterAlign
          )
        let
          rank = selection.abilityLevels[slot]
          spec = selection.abilities[slot].abilitySpec(rank)
          badge = well.origin + vec2(3, 2)
        sk.drawRect(badge, vec2(42, 20), rgbx(0, 0, 0, 190))
        hudScratch.setLen(0)
        hudScratch.add 'L'
        hudScratch.addHudInt(rank.int)
        hudScratch.add '/'
        hudScratch.addHudInt(slot.abilityMaxLevel.int)
        sk.drawLabel(
          hudScratch,
          badge,
          vec2(42, 20),
          rgbx(247, 221, 143, 255),
          "Small",
          CenterAlign
        )
        if rank == 0:
          let required = slot.abilityRequiredLevel(1)
          hudScratch.setLen(0)
          if selection.level < required:
            hudScratch.add "Needs L"
            hudScratch.addHudInt(required.int)
          else:
            hudScratch.add "Locked"
          sk.drawLabel(
            hudScratch,
            well.origin + vec2(0, 23),
            vec2(well.size.x, 20),
            rgbx(247, 221, 143, 255),
            "Small",
            CenterAlign
          )
        else:
          sk.drawRect(badge + vec2(0, 22), vec2(28, 20), rgbx(0, 0, 0, 190))
          writeInt(hudScratch, selection.charges[slot].int)
          hudScratch.add '/'
          hudScratch.addHudInt(spec.charges.int)
          sk.drawLabel(
            hudScratch,
            badge + vec2(0, 22),
            vec2(28, 20),
            rgbx(255, 255, 255, 255),
            "Small",
            CenterAlign
          )
        if options.playerSlot > 0 and not run.replayMode and
          selection.id == run.world.heroes[options.playerSlot - 1].id:
            let hero = run.world.heroes[options.playerSlot - 1]
            if hero.abilityLevelError(slot) == NoActionError:
              let upgrade = GameUiPanel(
                origin: well.origin + vec2(well.size.x - 23, 2),
                size: vec2(21, 20)
              )
              sk.drawRect(upgrade.origin, upgrade.size, rgbx(80, 62, 20, 255))
              sk.drawLabel(
                "+", upgrade.origin, upgrade.size,
                rgbx(255, 223, 133, 255), "Small", CenterAlign
              )
        if selection.recharges[slot] > 0:
          let progress = 1 - selection.recharges[slot].float32 /
            max(1, spec.rechargeTicks).float32
          sk.drawRect(
            well.origin + vec2(3, well.size.y - 5),
            vec2((well.size.x - 6) * progress, 3),
            rgbx(110, 190, 245, 255)
          )
      if i >= 4 and selection.kind == SelectedHero:
        let slot = i - 4
        if selection.itemCooldowns[slot] > 0:
          writeInt(hudScratch,
            cooldownSeconds(selection.itemCooldowns[slot]).int)
          hudScratch.add 's'
          sk.drawLabel(hudScratch,
            well.origin, well.size, rgbx(255, 255, 255, 255),
            "Small", CenterAlign)
        if selection.inventory[slot] != NoItem and
          selection.inventory[slot].itemSpec.kind == Consumable:
            sk.drawItemCount(well, selection.itemCounts[slot])
      sk.drawAbilityKey(well, AbilityKeys[i])

  if inventoryHero.id != 0:
    for slot in 0 ..< InventorySlots:
      let
        item = inventoryHero.inventory[slot]
        well = inventory.slots[slot]
        cooldown = inventoryHero.itemCooldowns[slot]
      if cooldown > 0:
        writeInt(hudScratch, cooldownSeconds(cooldown).int)
        hudScratch.add 's'
        sk.drawLabel(hudScratch,
          well.origin, well.size, rgbx(255, 255, 255, 255),
          "Small", CenterAlign)
      if item != NoItem and item.itemSpec.kind == Consumable:
        sk.drawItemCount(well, inventoryHero.itemCounts[slot])
  if inventoryHero.id != 0 and inventoryHero.kind == SelectedHero:
    let hero = run.world.heroById(inventoryHero.id)
    if hero.state == Dying:
      sk.drawBuyback(
        window, inventory.contents, hero, playerHero, transport.playing
      )
  hudScratch.setLen(0)
  if playerHero and armedItem >= 0:
    hudScratch.add "RIGHT-CLICK MAP"
  elif inventoryHero.id != 0 and inventoryHero.channelTicks > 0:
    hudScratch.add "TELEPORTING "
    hudScratch.addHudInt(cooldownSeconds(inventoryHero.channelTicks).int)
    hudScratch.add 's'
  elif inventoryHero.id != 0 and inventoryHero.portalCooldown > 0:
    hudScratch.add "PORTAL "
    hudScratch.addHudInt(cooldownSeconds(inventoryHero.portalCooldown).int)
    hudScratch.add 's'
  elif playerHero and
    run.world.heroById(playerHeroId).lastActionError != NoActionError:
      hudScratch.add(
        run.world.heroById(playerHeroId).lastActionError.actionErrorMessage)
  else:
    hudScratch.add "INVENTORY"
  sk.drawLabel(
    hudScratch,
    inventory.title.origin,
    inventory.title.size,
    rgbx(200, 205, 216, 255),
    "Small"
  )
  let gold = inventory.gold
  sk.drawSprite(
    "gold",
    gold.origin + vec2(0, 6),
    vec2(20)
  )
  writeAmount(hudScratch, if inventoryHero.id == 0: 0 else: inventoryHero.gold)
  sk.drawLabel(
    hudScratch,
    gold.origin + vec2(31, 0),
    vec2(gold.size.x - 31, gold.size.y),
    rgbx(232, 196, 86, 255)
  )

  if run.replayMode and run.hashCheck.error.len > 0:
    sk.drawError(
      chrome.layout.size,
      &"REPLAY DIVERGED - continuing simulation " &
        &"({run.hashCheck.mismatches} mismatches)",
      run.hashCheck.error
    )

  transport.drawTransport(
    sk,
    window,
    chrome.layout.transportPanel,
    actionCam,
    followSelection,
    addr statsState.toggled
  )
  let creep = footmanById(run.world, primaryId)
  hudScratch.setLen(0)
  if creep.id == 0:
    hudScratch.add "Select a pikeman to inspect its waypoints."
  else:
    hudScratch.addHudInt(creep.waypointIndex)
    hudScratch.add '/'
    hudScratch.addHudInt(creep.creepWaypointCount())
    hudScratch.add " cleared - "
    case creep.state
    of Fighting:
      hudScratch.add "Chasing / fighting"
    of Dying:
      hudScratch.add "Dying"
    else:
      hudScratch.add "Marching"
  sk.drawDebugMenu(window, addr showCreepWaypoints, hudScratch)
  statsState.syncDirector(actionCam, statsTable, window.tabHeld)

proc drawStatsOverlay*(sk: Silky, window: Window) {.measure.} =
  ## Presents readable statistics above the HUD at every window width.
  if shopOpen or run.world.phase == Drafting:
    return
  if not statsState.visible(window.tabHeld):
    return
  sk.drawStatsOverlay(
    window, currentLayout(window), statsState, currentStats(), run.history
  )
