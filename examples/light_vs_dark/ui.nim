## Light vs Dark Silky HUD.

import
  std/strformat,
  chroma, pixie, silky, vmath, windy,
  polyworld/[stats, metrics, actioncam, chrome, configs, gameuis, inputs, pathing, player, rtscameras,
    stackpanels],
  assets, content, sim, game, controls, layouts, symbols, maps, factions

const
  ResourceColors = [
    rgbx(232, 196, 86, 255),
    rgbx(196, 168, 120, 255),
    rgbx(160, 200, 160, 255)
  ]
  ## Icons draw at power-of-two sizes so the 128 and 256 px source art
  ## lands on exact mip levels and stays crisp.
  IconTiny = 16.0'f32
  IconSmall = 64.0'f32
  IconLarge = 128.0'f32
  WellPad = 4.0'f32
  IconTint = rgbx(245, 230, 190, 255)
  ScoreIcons = ["tower", "kills", "deaths"]
  CommandTabs = ["BUILD", "UNITS", "UPGRADES"]
  ViewIcons = ["previous_frame", "next_frame"]
  ResourceIcons = ["gold", "wood", "food"]
  CommandTabIcons = ["build", "units", "research"]
  SelectionIcon = 48.0'f32
  GridBarH = 12.0'f32
  NeutralHealthColor = rgbx(180, 185, 192, 255)
  CostFill = rgbx(12, 14, 20, 200)
  CommandTabH = 28.0'f32
  CommandTabLift = 4.0'f32

var commandTab = 0

type
  HudChrome = object
    layout: GameUiLayout
    score: GameUiPanel
    resources: GameUiPanel
    minimap: GameUiPanel
    selection: GameUiPanel
    build: GameUiPanel

var
  buildingPortraitKeys: array[FactionFiles.len, array[BuildingKind, string]]

for player in 0 ..< FactionFiles.len:
  for kind in BuildingKind:
    if kind == GoldMineBuilding:
      buildingPortraitKeys[player][kind] = "lvd_b_mine"
    else:
      buildingPortraitKeys[player][kind] =
        "lvd_b" & $player & "_" & $kind.ord

proc buildingPortraitKey*(player: int32, kind: BuildingKind): string =
  ## Returns the atlas name packed from one building's profile PNG.
  buildingPortraitKeys[max(player, 0) mod FactionFiles.len][kind]

proc drawPortrait(
    sk: Silky,
    well: GameUiPanel,
    key: string,
    iconSize: float32,
    color = rgbx(255, 255, 255, 255)
) =
  ## Draws a profile sprite at a fixed size centered in a well.
  sk.drawWellImage(well, key, color, iconSize = iconSize)

proc commandPlayer(viewMode: int32): int32 =
  ## Returns the side whose build and train locks the HUD should show.
  if options.playerSlot > 0 and not run.replayMode:
    options.playerSlot - 1
  elif viewMode > 0:
    viewMode - 1
  else:
    LightPlayer

proc canShowTrain(
    player: int32,
    buildingId: int32,
    kind: UnitKind
): bool =
  ## Returns whether this side could start training the unit right now.
  if buildingId.isBuildingId and
      run.world.buildingOwner(buildingId) == player:
    return run.world.canTrain(buildingId, kind)
  for structure in run.world.buildings:
    if structure.owner == player and
        run.world.canTrain(structure.id, kind):
      return true
  false

proc commandPortraitColor(
  ready: bool,
  tint = rgbx(255, 255, 255, 255)
): ColorRGBX =
  ## Fades portraits that cannot be built or trained yet.
  if ready:
    tint
  else:
    rgbx(tint.r div 2, tint.g div 2, tint.b div 2, 128)

proc placeChrome(layout: GameUiLayout): HudChrome =
  ## Places every textured HUD panel in one layout space.
  result.layout = layout
  result.score = layout.panel(GameUiRegion.TopLeft, PanelScore)
  result.resources = layout.panel(GameUiRegion.TopCenter, PanelResources)
  result.minimap = layout.panel(GameUiRegion.TopRight, PanelMinimap)
  result.selection = layout.panel(
    GameUiRegion.BottomLeft,
    PanelSelection
  )
  result.build = layout.panel(GameUiRegion.BottomRight, PanelBuild)

proc currentLayout*(window: Window): GameUiLayout =
  ## Returns the nine-region HUD layout in Silky layout space.
  initGameUiLayout(
    vec2(window.size.x.float32, window.size.y.float32) /
      gameUiScale(window),
    TransportHeight
  )

var statsState: StatsState

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

proc currentStats(
  teamColors: openArray[ColorRGBX] = []
): StatsTable =
  ## Adapts the actual roster and outcome to the shared table.
  run.sampleMetrics()
  result = StatsTable(kind: RtsStats, tick: run.world.tick,
    complete: run.world.over, winner: int(run.world.winner))
  for slot in 0 ..< run.world.players.len:
    result.rows.add StatsRow(
      slot: slot,
      name: run.config.players[slot].displayName(slot),
      subtitle:
        if slot mod FactionCount == 0: "LIGHT COMMANDER"
        else: "DARK COMMANDER",
      portrait: unitSymbolKey(PeonUnit),
      portraitTint:
        if slot < teamColors.len: teamColors[slot]
        else: rgbx(255, 255, 255, 255),
      team: slot,
      selected: not run.replayMode and options.playerSlot == slot + 1,
      metrics: currentMetrics(slot, result.complete)
    )

proc statsContains(window: Window, mouse: Vec2): bool =
  ## Tests the overlay before allowing input through to the existing HUD.
  if not statsState.visible(window.tabHeld):
    return false
  statsState.mouseOverStats(window, currentLayout(window),
    currentStats(), mouse)

proc hudClicked(window: Window, sk: Silky, panel: GameUiPanel): bool =
  ## Keeps covered HUD controls from receiving an overlay click.
  not window.statsContains(sk.mousePos) and chrome.clicked(window, sk, panel)

proc currentChrome(window: Window): HudChrome =
  ## Places every textured HUD panel for the current window.
  placeChrome(currentLayout(window))

proc mouseOverUi*(window: Window, mouse: Vec2): bool =
  ## Returns whether the pointer is over an anchored game UI panel.
  if window.statsContains(mouse) or mouseOverDebugMenu(mouse):
    return true
  let chrome = currentChrome(window)
  mouseOverPanels(
    mouse,
    chrome.layout,
    [
      chrome.score,
      chrome.resources,
      chrome.minimap,
      chrome.selection,
      chrome.build
    ]
  )

proc clockHour*(): float32 =
  ## The accelerated spectator clock in hours, 0 ..< 24 with a fraction:
  ## the match starts at 8:00 and a day is five minutes long.
  clockHour(run.world.tick, TickRate)

proc currentHudTime(): tuple[day, hour, minute: int] =
  ## Converts simulation ticks into the accelerated spectator clock.
  hudClock(run.world.tick, TickRate)

proc towerCount(player: int32): int =
  ## Counts standing towers for one player.
  for structure in run.world.buildings:
    if structure.owner == player and
        structure.kind == TowerBuilding and
        structure.state != BuildingDying:
      inc result

proc buildingName(kind: BuildingKind, owner = -1'i32): string =
  ## Returns a spectator-facing name for one structure.
  case kind
  of TownHallBuilding: "Town Hall"
  of FarmBuilding: "Farm"
  of BarracksBuilding: "Barracks"
  of LumberMillBuilding: "Lumber Mill"
  of TowerBuilding: "Tower"
  of StablesBuilding:
    if owner mod FactionCount == DarkPlayer: "Kennels" else: "Stables"
  of ChurchBuilding:
    if owner mod FactionCount == DarkPlayer: "Temple" else: "Church"
  of BlacksmithBuilding: "Blacksmith"
  of GoldMineBuilding: "Gold Mine"

proc unitName(kind: UnitKind): string =
  ## Uses the shared roster name for both player appearances.
  UnitNames[kind]

proc isPicked(id: int32, selectedIds: openArray[int32]): bool =
  ## Returns whether one entity belongs to the HUD selection set.
  for candidate in selectedIds:
    if candidate == id:
      return true

proc shiftHeld(window: Window): bool =
  ## Returns whether either shift key is currently down.
  window.buttonDown[KeyLeftShift] or
    window.buttonDown[KeyRightShift]

proc dropSelected(
    selectedIds: var seq[int32],
    primaryId: var int32,
    id: int32
) =
  ## Removes one entity from a multi-unit selection.
  if selectedIds.len <= 1:
    return
  for i in 0 ..< selectedIds.len:
    if selectedIds[i] == id:
      selectedIds.delete(i)
      break
  if primaryId == id:
    primaryId = selectedIds[0]

proc drawSelectionBox*(
    sk: Silky,
    window: Window,
    press: Vec2,
    active: bool
) =
  ## Draws the live box-select rectangle in layout space.
  if not active:
    return
  let current = window.mousePos.vec2
  if (current - press).length <= 6.0'f32:
    return
  let
    scale = max(sk.uiScale, 0.001'f32)
    origin = vec2(
      min(press.x, current.x),
      min(press.y, current.y)
    ) / scale
    size = vec2(
      abs(current.x - press.x),
      abs(current.y - press.y)
    ) / scale
    line = 2.0'f32
    edge = rgbx(180, 220, 255, 230)
  sk.drawRect(origin, size, rgbx(80, 160, 255, 45))
  sk.drawRect(origin, vec2(size.x, line), edge)
  sk.drawRect(
    origin + vec2(0, size.y - line),
    vec2(size.x, line),
    edge
  )
  sk.drawRect(origin, vec2(line, size.y), edge)
  sk.drawRect(
    origin + vec2(size.x - line, 0),
    vec2(line, size.y),
    edge
  )

proc shownUnit(unit: Unit, viewMode: int32): bool =
  ## Returns whether fog of war currently reveals this unit.
  if unit.state == UnitInMine:
    return false
  if viewMode == 0:
    return true
  run.world.unitVisible(viewMode - 1, unit)

proc shownBuilding(structure: Building, viewMode: int32): bool =
  ## Returns whether fog of war currently reveals this structure.
  if viewMode == 0:
    return true
  run.world.buildingVisible(viewMode - 1, structure)

proc minimapMap(panel: GameUiPanel): GameUiPanel =
  ## Returns the same stacked map rectangle used for rendering and input.
  panel.minimapPanels().map

proc minimapPoint(tile: Tile2, area: GameUiPanel): Vec2 =
  ## Converts one map tile into a point on the minimap.
  area.origin + vec2(
    float32(tile.x) / float32(run.world.map.side) * area.size.x,
    float32(tile.y) / float32(run.world.map.side) * area.size.y
  )

proc minimapCell(
    x, y, stride: int32, area: GameUiPanel
): (Vec2, Vec2) =
  ## Returns origin and size of one sampled terrain cell, spanning to the
  ## next sample so cells tessellate with no gap or overlap.
  let
    x1 = min(x + stride, run.world.map.side)
    y1 = min(y + stride, run.world.map.side)
    origin = minimapPoint(tile2(x, y), area)
    far = minimapPoint(tile2(x1, y1), area)
  (origin, far - origin)

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
      (run.world.map.side.float32 / 2)
    )
    cameraTarget.x = point.x
    cameraTarget.z = point.y
    cameraTarget.y = surfaceHeight(point.x, point.y)

proc drawMinimapCamera(
    sk: Silky,
    window: Window,
    area: GameUiPanel,
    cameraTarget: Vec3,
    cameraDistance: float32
) =
  ## Draws the fixed RTS camera's visible ground footprint.
  let aspect = window.size.x.float32 / max(window.size.y.float32, 1)
  sk.drawCameraFrame(
    minimapViewport(
      cameraTarget,
      cameraDistance,
      aspect,
      area.origin,
      area.size,
      (run.world.map.side.float32 / 2)
    )
  )

proc drawScoreRow(
    sk: Silky,
    panels: ScorePanels,
    player: int32,
    row: int,
    color: ColorRGBX
) =
  ## Draws one side's towers, kills, and deaths.
  let
    values = [
      towerCount(player),
      int(run.world.stats.values[player][KillsMetric]),
      int(run.world.players[player].unitsLost)
    ]
  sk.drawSprite(
    if player mod FactionCount == LightPlayer: "alliance" else: "hostile",
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

proc drawSlotCosts(
    sk: Silky,
    slot: GameUiPanel,
    gold,
    wood: int32
) =
  ## Draws gold and lumber costs over one hovered command portrait.
  if not sk.hovered(slot):
    return
  let inner = slot.inset(WellPad)
  sk.drawRect(inner.origin, inner.size, CostFill)
  var costs = slot.stack(BottomToTop, vec2(7, 6))
  for i, value in [wood, gold]:
    let
      row = costs.takeRow(18, 3)
      resource = 1 - i
    sk.drawSprite(
      ResourceIcons[resource],
      row.origin + vec2(0, 1),
      vec2(IconTiny)
    )
    writeInt(hudScratch, value.int)
    sk.drawLabel(
      hudScratch,
      row.origin + vec2(16, 0),
      vec2(row.size.x - 16, row.size.y),
      ResourceColors[resource],
      "Small",
      RightAlign
    )

proc drawUi*(
    sk: Silky,
    window: Window,
    transport: var player.Player,
    cameraTarget: Vec3,
    cameraDistance: float32,
    viewMode: var int32,
    primaryId: var int32,
    selectedIds: var seq[int32],
    followSelection: var bool,
    actionCam: var ActionCam,
    teamColors: openArray[ColorRGBX]
) =
  ## Draws every Silky HUD panel for the current frame.
  let table = currentStats(teamColors)
  statsState.syncDirector(actionCam, table, window.tabHeld)
  let
    chrome = currentChrome(window)
    scorePanel = sk.beginFrame(chrome.score)
    scoreSlots = scorePanel.scorePanels()
    resourcePanel = sk.beginFrame(chrome.resources)
    minimapPanel = sk.beginFrame(chrome.minimap)
    selectionPanel = sk.beginFrame(chrome.selection)
    buildPanel = sk.beginFrame(chrome.build)
    light = run.world.players[commandPlayer(viewMode)]
    resources = resourcePanel.resourcePanels()
    minimap = minimapPanel.minimapPanels()
    selection = selectionPanel.selectionPanels()
    build = buildPanel.buildPanels()

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
  let first = int(commandPlayer(viewMode))
  for row in 0 ..< min(2, run.world.players.len):
    let owner = (first + row) mod run.world.players.len
    sk.drawScoreRow(scoreSlots, int32(owner), row, teamColors[owner])
    let label = "P" & $(owner + 1) & ": " &
      run.config.players[owner].displayName(owner)
    sk.drawLabel(
      sk.fittedLabel(label, 262),
      scorePanel.origin + vec2(18, 100 + row.float32 * 22),
      vec2(262, 22),
      teamColors[owner]
    )

  let resourceRows = [
    ("GOLD", light.gold),
    ("WOOD", light.wood),
    ("FOOD", light.foodUsed)
  ]
  for i, row in resourceRows:
    let
      cell = resources[i]
    var contents = cell.stack(LeftToRight, vec2(5, 2))
    contents.gap(2)
    let
      icon = contents.take(vec2(16, 24), 9)
      caption = contents.take(vec2(33, 24))
      amount = contents.takeRest()
    sk.drawFaintFrame(cell)
    sk.drawSprite(
      ResourceIcons[i],
      icon.origin + vec2(0, 4),
      vec2(IconTiny)
    )
    sk.drawLabel(
      row[0],
      caption.origin + vec2(0, 3),
      vec2(caption.size.x, 20),
      rgbx(166, 174, 190, 255),
      "Small"
    )
    if i == 2:
      writeRatio(hudScratch, row[1].int, light.foodCap.int)
    else:
      writeAmount(hudScratch, row[1].int)
    sk.drawLabel(
      hudScratch,
      amount.origin,
      amount.size,
      ResourceColors[i],
      "Hud",
      RightAlign
    )

  let hudTime = currentHudTime()
  sk.drawSprite(
    if hudTime.hour < 6 or hudTime.hour >= 18: "night" else: "day",
    minimap.sun.origin + vec2(0, 2),
    minimap.sun.size
  )
  writeClock(hudScratch, hudTime.hour, hudTime.minute)
  sk.drawLabel(
    hudScratch,
    minimap.clock.origin + vec2(0, 6),
    vec2(80, 24),
    rgbx(247, 221, 143, 255),
    "Small"
  )
  let area = minimapPanel.minimapMap()
  const MapSampleStride = 2'i32
  let cell = area.size.x / float32(run.world.map.side)
  sk.drawFrame(area)
  for y in countup(0'i32, run.world.map.side - 1, MapSampleStride):
    for x in countup(0'i32, run.world.map.side - 1, MapSampleStride):
      let index = run.world.map.tileIndex(x, y)
      var shade =
        if run.world.map.passable[index] == 0: rgbx(42, 68, 112, 255)
        else:
          case run.world.map.kinds[index]
          of 5'u8: rgbx(32, 62, 38, 255)
          of 1'u8: rgbx(146, 128, 88, 255)
          of 3'u8: rgbx(84, 92, 66, 255)
          else: rgbx(66, 96, 58, 255)
      if viewMode != 0:
        if not run.world.explored(viewMode - 1, x, y):
          shade = rgbx(9, 11, 15, 255)
        elif not run.world.visible(viewMode - 1, x, y):
          shade = rgbx(shade.r div 2, shade.g div 2, shade.b div 2, 255)
      let (pos, size) = minimapCell(x, y, MapSampleStride, area)
      sk.drawRect(pos, size, shade)
  for structure in run.world.buildings:
    if structure.owner < 0 or not shownBuilding(structure, viewMode):
      continue
    let
      point = minimapPoint(structure.origin, area)
      size = vec2(structure.footprint.width.float32,
        structure.footprint.depth.float32) * cell
    if isPicked(structure.id, selectedIds):
      sk.drawRect(point - vec2(2), size + vec2(4), rgbx(238, 235, 205, 255))
    sk.drawRect(
      point,
      size,
      teamColors[structure.owner]
    )
  for unit in run.world.units:
    if unit.state == UnitDying or not shownUnit(unit, viewMode):
      continue
    let point = minimapPoint(unit.tile, area)
    if isPicked(unit.id, selectedIds):
      sk.drawRect(point - vec2(2), vec2(cell * 1.5 + 4), rgbx(238, 235, 205, 255))
    sk.drawRect(
      point,
      vec2(cell * 1.5, cell * 1.5),
      teamColors[unit.owner]
    )
  sk.drawMinimapCamera(window, area, cameraTarget, cameraDistance)
  let canSwitchView = options.playerSlot == 0 or run.replayMode
  for i, button in minimap.views:
    sk.drawWellImage(
      button,
      ViewIcons[i],
      if canSwitchView: IconTint else: rgbx(110, 115, 125, 160),
      selected = canSwitchView and sk.hovered(button),
      iconSize = 32
    )
    if canSwitchView and window.hudClicked(sk, button):
      let count = int32(run.world.players.len)
      if i == 0:
        viewMode = if viewMode == 0: count else: viewMode - 1
      else:
        viewMode = (viewMode + 1) mod (count + 1)

  if primaryId == NoEntity or
      (not run.world.hasUnit(primaryId) and
        not run.world.hasBuilding(primaryId)):
    primaryId = NoEntity
  # The first selection fills the main portrait; the rest fill the grid.
  var
    portraitKey = ""
    portraitHp = 0'i32
    portraitMax = 1'i32
    portraitId =
      if actionCam.enabled and actionCam.locked: actionCam.lockId
      else: primaryId
    portraitName = "NO SELECTION"
    portraitOwner = -1'i32
    portraitTint = rgbx(255, 255, 255, 255)
  if portraitId == NoEntity:
    for id in selectedIds:
      if (id.isUnitId and run.world.hasUnit(id)) or
          (id.isBuildingId and run.world.hasBuilding(id)):
        portraitId = id
        break
  if portraitId.isUnitId and run.world.hasUnit(portraitId):
    let unit = run.world.units[run.world.unitIndex(portraitId)]
    portraitKey = unitSymbolKey(unit.kind)
    portraitTint = teamColors[unit.owner]
    portraitHp = unit.hp
    portraitMax = unitOf(unit.owner, unit.kind).hp
    portraitName = unit.kind.unitName()
    portraitOwner = unit.owner
  elif portraitId != NoEntity and run.world.hasBuilding(portraitId):
    let structure = run.world.buildings[
      run.world.buildingIndex(portraitId)
    ]
    portraitKey = buildingPortraitKey(
      max(structure.owner, 0),
      structure.kind
    )
    portraitHp = structure.hp
    portraitMax = max(structure.maxHp, 1)
    portraitName = structure.kind.buildingName(structure.owner)
    portraitOwner = structure.owner
  let players = run.config.players
  if portraitOwner >= 0 and portraitOwner < players.len:
    portraitName = players[portraitOwner].displayName(portraitOwner) &
      "'s " & portraitName
  let
    selectPortrait = selection.portrait
    selectBar = selection.hp
    selectName = selection.name
    healthColor =
      if portraitOwner >= 0 and portraitOwner < run.world.players.len:
        teamColors[portraitOwner]
      else:
        NeutralHealthColor
  sk.drawPortrait(selectPortrait, portraitKey, IconLarge, portraitTint)
  writeRatio(hudScratch, portraitHp.int, portraitMax.int)
  sk.drawValueBar(
    selectBar.origin,
    selectBar.size,
    portraitHp.float32,
    portraitMax.float32,
    healthColor,
    hudScratch
  )
  sk.drawLabel(
    sk.fittedLabel(portraitName, selectName.size.x, "Small"),
    selectName.origin,
    selectName.size,
    rgbx(226, 230, 239, 255),
    "Small"
  )
  var
    shown = 0
    clickedId = NoEntity
  for id in selectedIds:
    if shown >= selection.units.len:
      break
    if id == portraitId or not id.isUnitId or not run.world.hasUnit(id):
      continue
    let
      unit = run.world.units[run.world.unitIndex(id)]
      slot = selection.units[shown]
    sk.drawPortrait(
      slot,
      unitSymbolKey(unit.kind),
      SelectionIcon,
      teamColors[unit.owner]
    )
    sk.drawBar(
      slot.origin + vec2(WellPad, slot.size.y - GridBarH),
      vec2(SelectionIcon, GridBarH),
      unit.hp.float32,
      unitOf(unit.owner, unit.kind).hp.float32,
      teamColors[unit.owner]
    )
    if window.hudClicked(sk, slot):
      clickedId = id
    inc shown
  if clickedId != NoEntity:
    actionCam.takeManual()
    if shiftHeld(window):
      dropSelected(selectedIds, primaryId, clickedId)
    else:
      selectedIds.setLen(0)
      selectedIds.add clickedId
      primaryId = clickedId
  if shown == 0 and
      portraitId.isBuildingId and
      run.world.hasBuilding(portraitId):
    let structure = run.world.buildings[
      run.world.buildingIndex(portraitId)
    ]
    if structure.kind == GoldMineBuilding:
      let details = selection.details
      sk.drawSprite("gold", details.origin + vec2(0, 4), vec2(IconTiny))
      sk.drawLabel(
        "GOLD LEFT",
        details.origin + vec2(IconTiny + 8, 0),
        vec2(details.size.x - IconTiny - 8, 24),
        rgbx(166, 174, 190, 255),
        "Small"
      )
      writeAmount(hudScratch, structure.goldLeft.int)
      sk.drawLabel(
        hudScratch,
        details.origin + vec2(0, 28),
        vec2(details.size.x, 28),
        ResourceColors[0],
        "Hud"
      )
    else:
      for slot in 0 ..< min(QueueSlots, selection.units.len):
        let
          well = selection.units[slot]
          filled = slot < structure.queueLength
        if filled:
          let kind = UnitKind(structure.queue[slot] - 1)
          sk.drawPortrait(
            well,
            unitSymbolKey(kind),
            SelectionIcon,
            teamColors[max(structure.owner, 0)]
          )
        if filled and slot == 0:
          sk.drawRect(
            well.origin,
            vec2(well.size.x, 3),
            rgbx(238, 216, 120, 255)
          )

  for i, label in CommandTabs:
    let
      selected = commandTab == i
      lift = if selected: CommandTabLift else: 0.0'f
      tab = GameUiPanel(
        origin: build.tabs[i].origin - vec2(0, lift),
        size: build.tabs[i].size + vec2(0, lift)
      )
      over = sk.hovered(tab)
      tint =
        if selected: rgbx(235, 216, 154, 255)
        elif over: rgbx(210, 214, 224, 255)
        else: rgbx(150, 158, 172, 255)
    sk.drawTab(tab, selected, over)
    sk.drawSprite(
      CommandTabIcons[i],
      tab.origin + vec2(5, tab.size.y - CommandTabH + 6),
      vec2(IconTiny),
      tint
    )
    sk.drawLabel(
      label,
      tab.origin + vec2(22, 0),
      tab.size - vec2(24, 0),
      tint,
      "Hud",
      CenterAlign
    )
    if window.hudClicked(sk, tab):
      commandTab = i
  if commandTab == 0:
    for index in 0 ..< build.slots.len:
      let slot = build.slots[index]
      if index <= BuildableHigh.ord:
        let
          kind = BuildingKind(index)
          stats = BuildingTable[kind]
          player = commandPlayer(viewMode)
        sk.drawPortrait(
          slot,
          buildingPortraitKey(player, kind),
          IconSmall,
          commandPortraitColor(run.world.canBuild(player, kind))
        )
        sk.drawSlotCosts(slot, stats.gold, stats.wood)
        if options.playerSlot > 0 and
            not run.replayMode and
            window.hudClicked(sk, slot):
          pendingBuild = int32(kind.ord)
  elif commandTab == 1:
    for kind in UnitKind:
      let
        slot = build.slots[kind.ord]
        player = commandPlayer(viewMode)
        stats = unitOf(player, kind)
      sk.drawPortrait(
        slot,
        unitSymbolKey(kind),
        IconSmall,
        commandPortraitColor(
          canShowTrain(player, primaryId, kind),
          teamColors[player]
        )
      )
      sk.drawSlotCosts(slot, stats.gold, stats.wood)
      if options.playerSlot > 0 and
          not run.replayMode and
          window.hudClicked(sk, slot):
        let player = options.playerSlot - 1
        if primaryId.isBuildingId and
            run.world.buildingOwner(primaryId) == player:
          queueTrain(player, primaryId, int32(kind.ord))
  else:
    sk.drawLabel(
      "No upgrades",
      build.contents.origin,
      vec2(build.contents.size.x, 28),
      rgbx(150, 160, 178, 255),
      "Small",
      CenterAlign
    )

  transport.drawTransport(
    sk,
    window,
    chrome.layout.transportPanel,
    actionCam,
    followSelection,
    addr statsState.toggled
  )

  if run.world.over:
    sk.drawLabel(
      describeResult(),
      vec2(0, chrome.layout.gameAreaSize.y * 0.5'f32 - 40),
      vec2(chrome.layout.size.x, 40),
      rgbx(240, 226, 180, 255),
      "H1",
      CenterAlign
    )

  if run.hashCheck.mismatches > 0:
    sk.drawError(
      chrome.layout.size,
      &"REPLAY DIVERGED - {run.hashCheck.mismatches} mismatches, " &
        &"first at tick {run.hashCheck.firstTick}"
    )
  sk.drawDebugMenu(window)
  statsState.syncDirector(actionCam, table, window.tabHeld)

proc drawStatsOverlay*(
  sk: Silky,
  window: Window,
  teamColors: openArray[ColorRGBX]
) =
  ## Presents readable statistics above the HUD at every window width.
  sk.drawStatsOverlay(
    window,
    currentLayout(window),
    statsState,
    currentStats(teamColors),
    run.history
  )
