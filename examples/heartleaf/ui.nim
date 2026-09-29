## Heartleaf Silky HUD.
##
## Plain chrome panels: a villager roster, the day clock, a minimap, the
## replay transport, and the standings screen between days.

import
  std/[algorithm, strformat],
  chroma, pixie, silky, vmath, windy,
  polyworld/[actioncam, chrome, gameuis, inputs, pathing, player, quadterrain,
    rtscameras],
  content, sim, game, controls, scorecard, layouts

const
  PanelRoster = vec2(292, 392)
  PanelClock = vec2(430, 64)
  PanelMinimap = vec2(252, 296)
  HudClearance = 24.0'f32
  RosterRowHeight = 36.0'f32

  VillagerColors*: array[VillagerCount, ColorRGBX] = [
    rgbx(226, 108, 92, 255),   # Ivan
    rgbx(96, 178, 92, 255),    # Anton
    rgbx(228, 196, 88, 255),   # Yura
    rgbx(166, 124, 82, 255),   # Sasha
    rgbx(120, 108, 190, 255),  # Maxim
    rgbx(126, 190, 168, 255),  # Nikita
    rgbx(72, 138, 90, 255),    # Vova
    rgbx(92, 148, 214, 255),   # Dima
    rgbx(196, 132, 190, 255)   # Egor
  ]

var scorePresentation*: ScorePresentation

var villagerPortraitKeys: array[VillagerCount, string]
for slot in 0 ..< VillagerCount:
  villagerPortraitKeys[slot] = "hlf_p" & $slot

proc villagerPortraitKey*(slot: int32): string =
  ## Returns the atlas name packed from one villager's profile PNG.
  villagerPortraitKeys[slot]

type
  HudChrome = object
    layout: GameUiLayout
    roster: GameUiPanel
    clock: GameUiPanel
    minimap: GameUiPanel

proc placeChrome(layout: GameUiLayout): HudChrome =
  ## Places every HUD panel in one layout space.
  result.layout = layout
  result.roster = layout.panel(GameUiRegion.TopLeft, PanelRoster)
  result.clock = layout.panel(GameUiRegion.TopCenter, PanelClock)
  result.minimap = layout.panel(GameUiRegion.TopRight, PanelMinimap)

proc hudLayoutFits(layoutSize: Vec2): bool =
  ## Returns whether the HUD panels fit this layout without overlap.
  let
    layout = initGameUiLayout(layoutSize, TransportHeight)
    chrome = placeChrome(layout)
  layoutFits(
    layout,
    [chrome.roster, chrome.clock, chrome.minimap],
    HudClearance
  )

proc hudUiScale*(windowSize: Vec2): float32 =
  ## Returns the stepped Silky scale that keeps HUD panels from overlapping.
  if run.world.phase in {ScorePhase, GameOverPhase}:
    fitUiScale(windowSize, scoreLayoutFits, ScoreUiScales)
  else:
    fitUiScale(windowSize, hudLayoutFits, UiCrispSteps)

proc hudUiScale*(window: Window): float32 =
  ## Returns the stepped Silky scale that fits the HUD on this window.
  hudUiScale(vec2(window.size.x.float32, window.size.y.float32))

proc currentLayout*(window: Window): GameUiLayout =
  ## Returns the nine-region HUD layout in Silky layout space.
  initGameUiLayout(
    vec2(window.size.x.float32, window.size.y.float32) /
      hudUiScale(window),
    TransportHeight
  )

proc currentChrome(window: Window): HudChrome =
  ## Places every HUD panel for the current window.
  placeChrome(currentLayout(window))

proc mouseOverUi*(window: Window, mouse: Vec2): bool =
  ## Returns whether the pointer is over an anchored game UI panel.
  if run.world.phase in {ScorePhase, GameOverPhase}:
    return true
  if mouseOverDebugMenu(mouse):
    return true
  let chrome = currentChrome(window)
  mouseOverPanels(
    mouse,
    chrome.layout,
    [chrome.roster, chrome.clock, chrome.minimap]
  )

## Clock

proc simClockMinute*(frameAlpha: float32): float32 =
  ## The village clock in minutes since midnight, gliding between ticks.
  let dayTick =
    if run.world.phase in {ScorePhase, GameOverPhase}:
      float32(DayTicks)
    else:
      min(float32(run.world.dayTick) + frameAlpha, float32(DayTicks))
  float32(DayStartMinute) + dayTick / float32(TicksPerGameMinute)

proc simClockHour*(frameAlpha: float32): float32 =
  ## The same clock in hours, which is what the sun rig wants.
  simClockMinute(frameAlpha) / 60.0'f32

proc addHudClock(s: var string, minuteOfDay: int) =
  ## Appends the wall clock as h:mm AM/PM.
  let
    hour = minuteOfDay div 60
    minute = minuteOfDay mod 60
    hour12 =
      if hour mod 12 == 0: 12
      else: hour mod 12
  s.addHudInt(hour12)
  s.add ':'
  if minute < 10:
    s.add '0'
  s.addHudInt(minute)
  s.add ' '
  if hour < 12:
    s.add "AM"
  else:
    s.add "PM"

## Minimap

proc minimapMap(panel: GameUiPanel): GameUiPanel =
  ## Returns the square map centered in the minimap panel.
  let side = min(panel.size.x, panel.size.y) - 24
  result.size = vec2(side)
  result.origin = panel.origin + (panel.size - result.size) * 0.5'f32

proc minimapPoint(tile: Tile2, area: GameUiPanel): Vec2 =
  ## Converts one map tile into a point on the minimap.
  area.origin + vec2(
    float32(tile.x) / float32(GridSide) * area.size.x,
    float32(tile.y) / float32(GridSide) * area.size.y
  )

proc updateMinimapCamera*(
    window: Window,
    mouse: Vec2,
    cameraTarget: var Vec3,
    minimapPanning: var bool
) =
  ## Moves the free camera while the primary button drags on the minimap.
  if run.world.phase in {ScorePhase, GameOverPhase}:
    minimapPanning = false
    return
  let
    chrome = currentChrome(window)
    area = chrome.minimap.minimapMap()
  if window.mousePressed(MouseLeft) and area.contains(mouse):
    minimapPanning = true
  if not window.mouseDown(MouseLeft):
    minimapPanning = false
  if minimapPanning:
    let point = minimapWorldPoint(
      mouse,
      area.origin,
      area.size,
      HalfGrid
    )
    cameraTarget.x = point.x
    cameraTarget.z = point.y
    cameraTarget.y = surfaceHeight(point.x, point.y)

## The standings table, shared by the score screen and the game-over card.

proc standingsOrder(): array[VillagerCount, int32] =
  ## Villager slots sorted by score, best first, ties by slot.
  var slots: array[VillagerCount, int32]
  for slot in 0 ..< VillagerCount:
    slots[slot] = int32(slot)
  sort(slots, proc(a, b: int32): int =
    let delta = run.world.villagers[b].score - run.world.villagers[a].score
    if delta != 0: int(delta) else: int(a - b))
  slots

proc describeResultForStandings(world: World): string =
  let slots = standingsOrder()
  let best = world.villagers[slots[0]].score
  for slot in slots:
    if world.villagers[slot].score != best:
      break
    if result.len > 0:
      result.add " & "
    result.add VillagerNames[slot]
  result.add " - " & $best & " points"

proc drawStandings(sk: Silky, layout: GameUiLayout, title: string) =
  let
    panel = layout.panel(GameUiRegion.Center,
      vec2(ScorecardWidth, ScorecardHeight))
    inner = sk.beginPanel(panel)
    ink = rgbx(240, 226, 180, 255)
  sk.drawLabel(title, inner.origin, vec2(inner.size.x, 34), ink,
    "H1", CenterAlign)
  const headings = ["GNOME", "DINNER", "EATING", "CURFEW", "TODAY", "TOTAL"]
  for column, heading in headings:
    sk.drawLabel(heading, inner.origin + vec2(ScoreColumns[column], 62),
      vec2(ScoreColumnWidths[column], 24), ink, "Small")
  for rank, slot in standingsOrder():
    let
      v = run.world.villagers[slot]
      report = run.world.dailyReports[slot]
      y = ScoreRowsTop + float32(rank) * ScoreRowHeight
      color = VillagerColors[slot]
    sk.drawSprite(villagerPortraitKey(slot), inner.origin + vec2(0, y), vec2(32))
    sk.drawLabel(VillagerNames[slot], inner.origin + vec2(40, y + 4),
      vec2(120, 24), color)
    let values = ["", dinnerRoleText(run.world, slot), eatingText(report),
      (if report.penalty > 0: signedPoints(-report.penalty) else: "-"),
      signedPoints(dailyGain(run.world, slot)), $v.score]
    for column in 1 .. 5:
      if scorePresentation.shown(column):
        sk.drawLabel(values[column],
          inner.origin + vec2(ScoreColumns[column], y + 4),
          vec2(ScoreColumnWidths[column], 24),
          (if column == 3 and report.penalty > 0: rgbx(230, 120, 100, 255)
           else: ink), "Hud")
    if scorePresentation.shown(1) and report.dinnerHost == slot:
      sk.drawLabel(hostingCalculation(run.world, slot),
        inner.origin + vec2(ScoreColumns[1], y + 25),
        vec2(ScoreColumnWidths[1], 18),
        rgbx(180, 190, 200, 255), "Small")
  sk.drawLabel("Hosting = stocked vegetables x guests    First taste this match = 3    Repeat = 1    Missed curfew = -3",
    inner.origin + vec2(0, 540), vec2(inner.size.x, 24), ink, "Small")

proc drawUi*(
    sk: Silky,
    window: Window,
    transport: var player.Player,
    cameraTarget: Vec3,
    cameraDistance: float32,
    viewProjection: Mat4,
    followSlot: var int32,
    actionCam: var ActionCam,
    preserveFollowOnAuto = false
): bool =
  ## Draws the HUD and reports clicks on any playback-speed button.
  let
    chrome = currentChrome(window)
    world = run.world
  if world.phase notin {ScorePhase, GameOverPhase}:
    let
      roster = sk.beginPanel(chrome.roster)
      clock = sk.beginPanel(chrome.clock)
      minimapPanel = sk.beginPanel(chrome.minimap)
    ## Roster: one row per villager. Clicking a row follows that villager.
    sk.drawLabel(
      "THE VILLAGE",
      roster.origin,
      vec2(roster.size.x, 22),
      rgbx(200, 205, 216, 255),
      "Small"
    )
    for slot in 0 ..< VillagerCount:
      let
        v = world.villagers[slot]
        y = 26.0'f32 + float32(slot) * RosterRowHeight
        row = GameUiPanel(
          origin: roster.origin + vec2(0, y),
          size: vec2(roster.size.x, RosterRowHeight - 4)
        )
      if int32(slot) == followSlot:
        sk.drawSlot(
          GameUiPanel(
            origin: row.origin - vec2(4, 2),
            size: row.size + vec2(8, 0)
          ),
          selected = true
        )
      sk.drawSprite(
        villagerPortraitKey(int32(slot)),
        row.origin,
        vec2(30)
      )
      sk.drawRect(
        row.origin + vec2(0, 30),
        vec2(30, 3),
        VillagerColors[slot]
      )
      sk.drawLabel(
        VillagerNames[slot],
        row.origin + vec2(38, 5),
        vec2(92, 22),
        rgbx(226, 230, 239, 255)
      )
      writeInt(hudScratch, v.score.int)
      sk.drawLabel(
        hudScratch,
        row.origin + vec2(134, 5),
        vec2(48, 22),
        rgbx(240, 226, 180, 255)
      )
      sk.drawSprite("gather", row.origin + vec2(188, 7), vec2(16))
      writeInt(hudScratch, v.carriedTotal().int)
      sk.drawLabel(
        hudScratch,
        row.origin + vec2(208, 5),
        vec2(34, 22),
        rgbx(166, 200, 150, 255),
        "Small"
      )
      if v.inHouse == v.slot:
        sk.drawSprite("home", row.origin + vec2(246, 7), vec2(16))
      elif v.inHouse >= 0:
        sk.drawSprite("housing", row.origin + vec2(246, 7), vec2(16))
      elif v.hostingTonight:
        sk.drawSprite("wave", row.origin + vec2(246, 7), vec2(16))
      if window.clicked(sk, row):
        followSlot =
          if followSlot == int32(slot): -1'i32
          else: int32(slot)
        actionCam.takeManual()

    ## Clock strip.
    let minuteNow = int(simClockMinute(0))
    sk.drawSprite(
      if world.phase in {ScorePhase, GameOverPhase}: "night"
      elif minuteNow >= 18 * 60: "night"
      else: "day",
      clock.origin + vec2(8, 10),
      vec2(20)
    )
    hudScratch.setLen(0)
    hudScratch.add "DAY "
    hudScratch.addHudInt(min(world.day, world.dayCount).int)
    hudScratch.add " / "
    hudScratch.addHudInt(world.dayCount.int)
    sk.drawLabel(
      hudScratch,
      clock.origin + vec2(36, 8),
      vec2(110, 24),
      rgbx(226, 230, 239, 255)
    )
    hudScratch.setLen(0)
    hudScratch.addHudClock(minuteNow)
    sk.drawLabel(
      hudScratch,
      clock.origin + vec2(152, 8),
      vec2(96, 24),
      rgbx(247, 221, 143, 255)
    )
    if world.phase == DaytimePhase:
      hudScratch.setLen(0)
      let left = DinnerMinute - minuteNow
      if left <= 60:
        hudScratch.add "DINNER IN "
        hudScratch.addHudInt(left)
        hudScratch.add 'M'
      else:
        hudScratch.add "DINNER AT 6 PM"
      sk.drawLabel(
        hudScratch,
        clock.origin + vec2(252, 8),
        vec2(150, 24),
        if left <= 60: rgbx(226, 120, 92, 255)
        else: rgbx(166, 174, 190, 255),
        "Small"
      )
    elif world.phase == EveningPhase:
      sk.drawLabel(
        "AFTER DINNER",
        clock.origin + vec2(252, 8),
        vec2(150, 24),
        rgbx(166, 174, 190, 255),
        "Small"
      )

    ## Minimap.
    let area = minimapPanel.minimapMap()
    sk.drawFrame(area)
    const MapSampleStride = 2'i32
    let cell = area.size.x / float32(GridSide)
    for y in countup(0'i32, GridSide - 1, MapSampleStride):
      for x in countup(0'i32, GridSide - 1, MapSampleStride):
        if not insideTown(x - GridSide div 2, y - GridSide div 2):
          continue
        let
          index = tileIndex(x, y)
          shade =
            case world.map.kinds[index]
            of 1'u8: rgbx(150, 132, 92, 255)                 # road
            of 4'u8: rgbx(128, 128, 132, 255)                # plaza stone
            of 5'u8: rgbx(30, 52, 32, 255)                   # forest
            of uint8(GardenTileKind): rgbx(112, 88, 52, 255)
            of uint8(HouseTileKind): rgbx(96, 74, 58, 255)
            else: rgbx(62, 96, 56, 255)                      # meadow
          origin = minimapPoint(tile2(x, y), area)
          far = minimapPoint(
            tile2(min(x + MapSampleStride, GridSide),
                  min(y + MapSampleStride, GridSide)),
            area
          )
        sk.drawRect(origin, far - origin, shade)
    for garden in 0 ..< GardenCount:
      if world.gardens[garden] < 0:
        continue
      sk.drawRect(
        minimapPoint(world.map.gardenTiles[garden], area) - vec2(1),
        vec2(cell * 1.5'f32 + 2),
        rgbx(140, 220, 110, 255)
      )
    for slot in 0 ..< VillagerCount:
      let house = world.map.houses[slot]
      sk.drawRect(
        minimapPoint(house.center, area) - vec2(cell),
        vec2(cell * 3),
        VillagerColors[slot]
      )
    for slot in 0 ..< VillagerCount:
      let v = world.villagers[slot]
      if v.inHouse >= 0:
        continue
      sk.drawRect(
        minimapPoint(v.tile, area) - vec2(2),
        vec2(cell * 1.5'f32 + 3),
        rgbx(20, 22, 26, 255)
      )
      sk.drawRect(
        minimapPoint(v.tile, area) - vec2(1),
        vec2(cell * 1.5'f32 + 1),
        VillagerColors[slot]
      )
    let aspect = window.size.x.float32 / max(window.size.y.float32, 1)
    let
      bounds = townCameraBounds(cameraTarget, cameraDistance, aspect)
      minimum = clamp((bounds.minimum + vec2(HalfGrid)) / (HalfGrid * 2),
        vec2(0), vec2(1))
      maximum = clamp((bounds.maximum + vec2(HalfGrid)) / (HalfGrid * 2),
        vec2(0), vec2(1))
    sk.drawCameraFrame(MinimapViewRect(
      origin: area.origin + minimum * area.size,
      size: (maximum - minimum) * area.size
    ))

  else:
    let finalNight = world.over or world.day == world.dayCount
    let title =
      if finalNight: "FINAL RESULTS"
      else: "DAY " & $world.day & " - TONIGHT'S SCORES"
    sk.drawStandings(chrome.layout, title)
    if finalNight:
      let panel = chrome.layout.panel(GameUiRegion.Center,
        vec2(ScorecardWidth, ScorecardHeight))
      sk.drawLabel(describeResultForStandings(world),
        panel.origin + vec2(20, 43), vec2(ScorecardWidth - 40, 24),
        rgbx(240, 226, 180, 255), "Hud", CenterAlign)
    if world.phase == ScorePhase:
      let
        panel = chrome.layout.panel(GameUiRegion.Center,
          vec2(ScorecardWidth, ScorecardHeight))
        button = GameUiPanel(origin: panel.origin + vec2(440, 580),
          size: vec2(340, 28))
      sk.drawRect(button.origin, button.size, rgbx(55, 66, 55, 255))
      sk.drawLabel((if finalNight: "Finish match" else: "Next morning"),
        button.origin, button.size, rgbx(240, 226, 180, 255), "Small", CenterAlign)
      if window.clicked(sk, button):
        transport.seekTo(world.tick + world.phaseTicks, play = false)

  var following = followSlot >= 0
  transport.drawTransport(
    sk,
    window,
    chrome.layout.transportPanel,
    actionCam,
    following
  )
  for button in chrome.layout.transportPanel.transportPanels().speeds:
    if window.clicked(sk, button):
      result = true
  if not following and not (preserveFollowOnAuto and actionCam.enabled):
    followSlot = -1

  if run.hashCheck.mismatches > 0:
    sk.drawError(
      chrome.layout.size,
      &"REPLAY DIVERGED - {run.hashCheck.mismatches} mismatches, " &
        &"first at tick {run.hashCheck.firstTick}"
    )
  sk.drawDebugMenu(window)
