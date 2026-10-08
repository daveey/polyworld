## The authored ship skin, Polyworld crew, navigation debug view, and HUD.

import
  std/[math, os, strutils, times, unicode],
  chroma, gltf, opengl, pixie, silky, vmath, windy,
  polyworld/[actioncam, assets, characters, chargen, chrome, common, gameuis,
    pathing, player, quadterrain, rtscameras, shapes, toon, viewers],
  sim, maps, cameras, game, replays, skins, stars

const
  AtlasPath = TmpRoot & "/crewrift.atlas.png"
  CrewHeight = 1.8'f
  CrewLibrary = DataRoot & "/characters/chargen"
  CrewClips = ["Idle_Loop", "Walk_Loop", "Interact"]
  White = rgbx(255, 255, 255, 255)
  Ink = rgbx(233, 241, 250, 255)
  Muted = rgbx(155, 174, 194, 255)
  Panel = rgbx(17, 26, 42, 235)
  RosterRowHeight = 56.0'f
  RosterRowGap = 4.0'f
  HeaderHeight = 130.0'f
  GridColor = rgbx(26, 184, 56, 220)
  GridHeight = 0.06'f
  GridHalfWidth = 0.02'f

type
  Visual = object
    model: CharacterModel
    position: Vec3
    facing: float32
  ViewState = object
    typing: bool
    showRooms: bool
    camera: CameraState
    text: string
    rosterScroll: float32

proc loadCrew(playerColor: uint8, manifest: Manifest): CharacterModel =
  ## Dyes the authored astronaut suit to the player's actual crew color.
  var preset = manifest.namedPreset("Astronaut")
  let tint = playerColorRgba(playerColor)
  for part in preset.parts.mitems:
    if part.category in ["Headgear", "Chest", "Leg"]:
      part.rgb = @[
        tint.r.float32 / 255,
        tint.g.float32 / 255,
        tint.b.float32 / 255
      ]
  result = loadCharacterModel(
    readPresetCharacter(CrewLibrary, manifest, preset, CrewClips),
    CrewHeight
  )
  result.fitCharacterHeight(CrewHeight, result.clipIndex(CrewClips[0]))

proc crewInk(value: uint8): ColorRGBX =
  ## Keeps dark player colors readable against the HUD panels.
  let tint = playerColorRgba(value)
  rgbx(
    uint8(tint.r.float32 * 0.55 + 255 * 0.45),
    uint8(tint.g.float32 * 0.55 + 255 * 0.45),
    uint8(tint.b.float32 * 0.55 + 255 * 0.45),
    255
  )

proc portraitKey(slot: int): string =
  ## Returns the shared atlas key for one crew member's portrait.
  "crew_portrait_" & $slot

proc crewPortrait(window: Window, scene: CharacterScene,
    model: CharacterModel): Image =
  ## Captures the actual Polyworld character for the crew roster.
  const Size = 128
  let
    target = vec3(0, CrewHeight * 0.66'f, 0)
    eye = target + vec3(0, 0.2'f, -10)
    extent = CrewHeight * 0.43'f
    view = lookAt(eye, target, vec3(0, 1, 0))
    projection = ortho(-extent, extent, -extent, extent, 0.02'f, 50.0'f)
  scene.beginCharacters(window, view, projection, eye)
  var
    previousFramebuffer: GLint
    framebuffer, colorBuffer, depthBuffer: GLuint
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, previousFramebuffer.addr)
  glGenFramebuffers(1, framebuffer.addr)
  glGenRenderbuffers(1, colorBuffer.addr)
  glGenRenderbuffers(1, depthBuffer.addr)
  defer:
    glBindFramebuffer(GL_FRAMEBUFFER, previousFramebuffer.GLuint)
    glDeleteFramebuffers(1, framebuffer.addr)
    glDeleteRenderbuffers(1, colorBuffer.addr)
    glDeleteRenderbuffers(1, depthBuffer.addr)
    glViewport(0, 0, window.size.x, window.size.y)
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
  glBindRenderbuffer(GL_RENDERBUFFER, colorBuffer)
  glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, Size, Size)
  glFramebufferRenderbuffer(
    GL_FRAMEBUFFER,
    GL_COLOR_ATTACHMENT0,
    GL_RENDERBUFFER,
    colorBuffer
  )
  glBindRenderbuffer(GL_RENDERBUFFER, depthBuffer)
  glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, Size, Size)
  glFramebufferRenderbuffer(
    GL_FRAMEBUFFER,
    GL_DEPTH_ATTACHMENT,
    GL_RENDERBUFFER,
    depthBuffer
  )
  if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
    raise newException(CrewriftError, "Cannot create crew portrait framebuffer.")
  glViewport(0, 0, Size, Size)
  scene.renderer.clearScreen(color(0.10, 0.12, 0.16, 1))
  scene.drawCharacter(
    model,
    vec3(0),
    PI.float32 + 0.25'f,
    model.clipIndex(CrewClips[0]),
    0.35'f
  )
  scene.finishCharacters()
  result = newImage(Size, Size)
  glReadBuffer(GL_COLOR_ATTACHMENT0)
  glReadPixels(
    0,
    0,
    Size,
    Size,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    result.data[0].addr
  )
  result.flipVertical()

proc inside(mouse, origin, size: Vec2): bool =
  ## Tests one explicit HUD hit rectangle.
  mouse.x >= origin.x and mouse.y >= origin.y and
    mouse.x < origin.x + size.x and mouse.y < origin.y + size.y

proc label(
  sk: Silky,
  text: string,
  x, y, width: float32,
  tint = Ink,
  font = "Hud",
  height = 24.0'f
) =
  ## Draws one clipped label in window pixel coordinates.
  sk.drawLabel(text, vec2(x, y), vec2(width, height), tint, font)

proc rosterPanel(
  size: Vec2,
  transportHeight: float32,
  players: int
): GameUiPanel =
  ## Fits compact crew rows above the hint strip and replay ribbon.
  let height = 50 + players.float32 * (RosterRowHeight + RosterRowGap) -
    RosterRowGap
  GameUiPanel(
    origin: vec2(16, HeaderHeight + 28),
    size: vec2(302, min(height, max(96.0'f,
      size.y - transportHeight - HeaderHeight - 74)))
  )

proc drawRoster(
  sk: Silky,
  window: Window,
  game: Game,
  state: var ViewState,
  slot: int,
  transportHeight: float32
): bool =
  ## Shows each portrait, name, and task count, kill count, or dead status.
  let
    world = game.world
    panel = rosterPanel(
      window.size.vec2,
      transportHeight,
      world.players.len
    )
    content = GameUiPanel(
      origin: panel.origin + vec2(8, 42),
      size: panel.size - vec2(16, 50)
    )
    totalHeight = world.players.len.float32 *
      (RosterRowHeight + RosterRowGap) - RosterRowGap
  sk.drawRect(panel.origin, panel.size, Panel)
  sk.label("CREW / " & $world.players.len,
    panel.origin.x + 16, panel.origin.y + 10, 270, Ink, "Bold")
  let scrollEnd = max(0.0'f, totalHeight - content.size.y)
  if panel.contains(window.mousePos.vec2) and
    not mouseOverDebugMenu(window.mousePos.vec2):
      state.rosterScroll -= window.scrollDelta.y * 18
  state.rosterScroll = clamp(state.rosterScroll, 0.0'f, scrollEnd)
  sk.pushClipRect(rect(content.origin, content.size))
  var y = content.origin.y - state.rosterScroll
  for i, crew in world.players:
    let card = GameUiPanel(
      origin: vec2(content.origin.x, y),
      size: vec2(content.size.x - 6, RosterRowHeight)
    )
    y += RosterRowHeight + RosterRowGap
    if card.origin.y + card.size.y <= content.origin.y or
      card.origin.y >= content.origin.y + content.size.y:
        continue
    let
      selected = i in state.camera.selected
      name = game.rosterName(i)
      portrait = GameUiPanel(
        origin: card.origin + vec2(6, 6), size: vec2(44)
      )
      x = card.origin.x + 60
      width = card.size.x - 68
    sk.drawRect(card.origin, card.size,
      if selected: rgbx(40, 66, 91, 245) else: rgbx(24, 37, 56, 245))
    sk.drawWellImage(portrait, portraitKey(i),
      color = (if crew.alive: White else: rgbx(160, 172, 186, 255)),
      selected = selected, pad = 2)
    let font =
      if sk.getTextSize("Bold", name).x <= width: "Bold"
      else: "Hud"
    sk.label(sk.fittedLabel(name, width, font),
      x, card.origin.y + 6, width, crewInk(crew.color), font)
    var status: string
    if not crew.alive:
      status = "Dead"
    elif crew.role == Imposter:
      status = "Kills: " & $world.playerKills(i)
    else:
      var remaining = 0
      for task in crew.assignedTasks:
        if not world.tasks[task].completed[i]:
          inc remaining
      status = "Tasks: " & $remaining
    sk.label(status, x, card.origin.y + 29, width, Muted, "Small")
    if window.buttonPressed[MouseLeft] and
      not mouseOverDebugMenu(window.mousePos.vec2) and
      content.contains(window.mousePos.vec2) and
      portrait.contains(window.mousePos.vec2) and
      (crew.alive or i == slot) and world.visibleFrom(slot, crew.x, crew.y):
        state.camera.selectCrew([i])
        result = true
  sk.popClipRect()
  if scrollEnd > 0:
    let
      track = GameUiPanel(
        origin: vec2(panel.origin.x + panel.size.x - 5, content.origin.y),
        size: vec2(2, content.size.y)
      )
      thumbHeight = max(20.0'f, content.size.y * content.size.y / totalHeight)
      offset = state.rosterScroll / scrollEnd * (content.size.y - thumbHeight)
    sk.drawRect(track.origin, track.size, rgbx(44, 61, 77, 255))
    sk.drawRect(track.origin + vec2(0, offset), vec2(2, thumbHeight), Muted)

proc drawOutline(sk: Silky, panel: GameUiPanel, tint: ColorRGBX) =
  ## Draws a thin selection or minimap viewport frame.
  let
    origin = panel.origin
    size = panel.size
  sk.drawRect(origin, vec2(size.x, 1), tint)
  sk.drawRect(origin + vec2(0, size.y - 1), vec2(size.x, 1), tint)
  sk.drawRect(origin, vec2(1, size.y), tint)
  sk.drawRect(origin + vec2(size.x - 1, 0), vec2(1, size.y), tint)

proc drawMap(
  sk: Silky,
  game: Game,
  panel: GameUiPanel,
  slot: int,
  camera: CameraState,
  aspect: float32
) =
  ## Draws the navigation footprint and visible crew in a compact ship map.
  let
    origin = panel.origin
    size = panel.size
  sk.drawRect(origin, size, rgbx(8, 15, 27, 255))
  let scale = min(size.x / MapColumns.float32, size.y / MapRows.float32)
  for y in 0 ..< MapRows:
    for x in 0 ..< MapColumns:
      let tile = game.ship.tiles[tileIndex(x, y)]
      if tile != VoidTile:
        let tint =
          if tile == FloorTile: rgbx(152, 172, 192, 255)
          else: rgbx(69, 87, 110, 255)
        sk.drawRect(
          origin + vec2(x.float32, y.float32) * scale,
          vec2(scale), tint
        )
  for task in game.world.tasks:
    if slot >= 0 and game.world.players[slot].role == Crewmate:
      let index = game.world.tasks.find(task)
      if not game.world.players[slot].hasTask(index) or task.completed[slot]:
        continue
      sk.drawRect(
        origin + vec2(task.x.float32, task.y.float32) /
          PixelsPerTile.float32 * scale,
        vec2(4), rgbx(255, 211, 89, 255)
      )
  for i, player in game.world.players:
    if i == slot or game.world.visibleFrom(slot, player.x, player.y):
      if player.alive or i == slot:
        sk.drawRect(
          origin + vec2(player.x.float32, player.y.float32) /
            PixelsPerTile.float32 * scale,
          vec2(5), playerColorRgba(player.color).rgbx
        )
  let
    view = minimapViewport(
      camera.target,
      camera.distance,
      aspect,
      vec2(0),
      vec2(MapHalfWidth * 2),
      MapHalfWidth
    )
    offset = vec2(0, MapHalfWidth - MapHalfDepth)
    bounds = vec2(MapColumns.float32, MapRows.float32)
    low = clamp(view.origin - offset, vec2(0), bounds)
    high = clamp(view.origin + view.size - offset, low, bounds)
  sk.drawOutline(
    GameUiPanel(origin: origin + low * scale, size: (high - low) * scale),
    rgbx(225, 236, 249, 200)
  )

proc meetingPanel(
  size: Vec2,
  transportHeight: float32,
  phase: GamePhase
): GameUiPanel =
  ## Centers the discussion panel above the shared replay transport.
  let
    width = min((if phase == Voting: 960.0'f else: 580.0'f), size.x - 48)
    height = min((if phase == Voting: 650.0'f else: 610.0'f),
      size.y - transportHeight - 134)
    y = max(92.0'f, (size.y - height) / 2)
  GameUiPanel(origin: vec2((size.x - width) / 2, y),
    size: vec2(width, height))

proc drawDiscussion(
  sk: Silky,
  window: Window,
  game: Game,
  state: var ViewState,
  slot: int,
  panel: GameUiPanel
) =
  ## Gives meeting chat the main column with separate vote choices and input.
  let
    world = game.world
    origin = panel.origin
    width = panel.size.x
    height = panel.size.y
    voteWidth = min(260.0'f, (width - 64) * 0.32'f)
    chatWidth = width - voteWidth - 64
    chatOrigin = origin + vec2(24, 122)
    voteOrigin = origin + vec2(width - voteWidth - 24, 122)
    contentHeight = height - 202
    seconds = (world.voteState.voteTimer + TargetFps - 1) div TargetFps
    canInteract = slot >= 0 and not game.playback and
      game.frame >= game.recording.frames.len and world.players[slot].alive and
      not mouseOverDebugMenu(window.mousePos.vec2)
  sk.label($seconds & "s left", origin.x + width - 124,
    origin.y + 28, 100, Muted)
  let caller = world.meetingCallCallerIndex()
  let context =
    if caller < 0:
      "Share sightings and question alibis before voting."
    elif world.voteState.callKind == VoteCalledBody:
      playerColorText(world.players[caller].color) & " reported " &
        playerColorText(world.voteState.bodyColor) & "'s body."
    else:
      playerColorText(world.players[caller].color) & " called an emergency meeting."
  sk.label(context, origin.x + 24, origin.y + 66, width - 48, Muted)
  sk.label("DISCUSSION", chatOrigin.x, origin.y + 94,
    chatWidth, Ink, "Bold")
  var voted = 0
  for i, crew in world.players:
    if crew.alive and world.voteState.votes[i] != -1:
      inc voted
  sk.label("VOTE  /  " & $voted & " cast", voteOrigin.x,
    origin.y + 94, voteWidth, Ink, "Bold")
  sk.drawRect(chatOrigin, vec2(chatWidth, contentHeight),
    rgbx(10, 18, 31, 245))
  let
    visible = min(world.chatMessages.len, VoteChatVisibleMessages)
    messageHeight = min(72.0'f,
      (contentHeight - 12) / VoteChatVisibleMessages.float32)
  if visible == 0:
    sk.label("Waiting for sightings and accusations...", chatOrigin.x + 12,
      chatOrigin.y + 16, chatWidth - 24, Muted)
  for i in 0 ..< visible:
    let
      message = world.chatMessages[world.chatMessages.len - visible + i]
      at = chatOrigin + vec2(6, 6 + i.float32 * messageHeight)
      bubbleSize = vec2(chatWidth - 12, messageHeight - 5)
    sk.drawRect(at, bubbleSize, rgbx(25, 39, 58, 255))
    sk.drawRect(at, vec2(3, bubbleSize.y), crewInk(message.color))
    sk.label(playerColorText(message.color).toUpperAscii(),
      at.x + 12, at.y + 3, bubbleSize.x - 24,
      crewInk(message.color), "Bold", 23)
    discard sk.drawText(
      "Hud",
      message.text,
      at + vec2(12, 28),
      Ink,
      maxWidth = bubbleSize.x - 24,
      maxHeight = bubbleSize.y - 30,
      wordWrap = true
    )
  let rowHeight = min(42.0'f,
    contentHeight / (world.players.len + 1).float32)
  for i in 0 .. world.players.len:
    let
      at = voteOrigin + vec2(0, i.float32 * rowHeight)
      rowSize = vec2(voteWidth, rowHeight - 4)
      active = i == world.players.len or world.players[i].alive
      selected = slot >= 0 and world.voteState.cursor[slot] == i
      tint =
        if not active: Muted
        elif i < world.players.len: crewInk(world.players[i].color)
        else: Ink
      name =
        if i == world.players.len: "Skip vote"
        else:
          playerColorText(world.players[i].color) &
            (if not active: " (dead)"
             elif world.voteState.votes[i] != -1: "  voted"
             else: "")
    sk.drawRect(at, rowSize,
      if selected: rgbx(55, 83, 111, 255) else: rgbx(25, 39, 58, 255))
    sk.label(name, at.x + 10, at.y, rowSize.x - 20,
      tint, "Hud", rowSize.y)
    if active and canInteract and world.voteState.votes[slot] == -1 and
      window.buttonPressed[MouseLeft] and
      inside(window.mousePos.vec2, at, rowSize):
        game.choice = i
  let
    inputOrigin = origin + vec2(24, height - 64)
    inputSize = vec2(chatWidth, 44)
    cooldown =
      if slot >= 0:
        max(0, world.config.messageCooldownTicks -
          (world.tickCount - world.players[slot].lastChatTick))
      else: 0
    placeholder =
      if game.playback: "Recorded meeting chat"
      elif slot < 0: "Spectating the discussion"
      elif not world.players[slot].alive: "Dead players listen to the meeting"
      elif cooldown > 0:
        "Chat available in " & $((cooldown + TargetFps - 1) div TargetFps) & "s"
      else: "Enter to chat, or click here..."
  sk.drawRect(inputOrigin, inputSize,
    if state.typing: rgbx(43, 65, 88, 255) else: rgbx(25, 39, 58, 255))
  sk.label(
    if state.typing: state.text & "|" else: placeholder,
    inputOrigin.x + 12,
    inputOrigin.y,
    inputSize.x - 88,
    if state.typing: Ink else: Muted,
    "Hud",
    inputSize.y
  )
  let sendOrigin = inputOrigin + vec2(inputSize.x - 72, 5)
  sk.drawRect(sendOrigin, vec2(66, 34), rgbx(55, 83, 111, 255))
  sk.label("Send", sendOrigin.x + 10, sendOrigin.y, 46, Ink, "Hud", 34)
  if canInteract and cooldown == 0 and window.buttonPressed[MouseLeft]:
    if inside(window.mousePos.vec2, sendOrigin, vec2(66, 34)):
      if state.text.len > 0:
        game.chat = state.text
        state.text.setLen(0)
        state.typing = false
    elif inside(window.mousePos.vec2, inputOrigin, inputSize):
      state.typing = true

proc mouseOverHud(window: Window, game: Game, slot: int,
    transportHeight: float32): bool =
  ## Reserves the HUD, meeting cards, and bottom transport from camera gestures.
  let
    pointer = window.mousePos.vec2
    width = window.size.x.float32
    height = window.size.y.float32
  if mouseOverDebugMenu(pointer) or
    pointer.y >= height - transportHeight or
    inside(pointer, vec2(16), vec2(302, HeaderHeight)) or
    inside(pointer, vec2(width - 322, 16), vec2(306, 218)) or
    inside(pointer, vec2(338, 20), vec2(max(100.0'f, width - 680), 58)):
      return true
  if rosterPanel(
    window.size.vec2,
    transportHeight,
    game.world.players.len
  ).contains(pointer):
    return true
  if game.world.phase in
    {MeetingCall, Voting, VoteResult, RoleReveal, GameOver}:
    return meetingPanel(window.size.vec2, transportHeight,
      game.world.phase).contains(pointer)

proc addNavigationGrid(renderer: var ShapeRenderer, ship: ShipMap) =
  ## Outlines the actual navigation tiles once per edge above the ship floor.
  for y in 0 ..< MapRows:
    for x in 0 ..< MapColumns:
      let index = tileIndex(x, y)
      if not ship.layer.tiles[index].exists:
        continue
      let
        a = worldPoint(x * PixelsPerTile, y * PixelsPerTile, GridHeight)
        b = a + vec3(1, 0, 0)
        c = a + vec3(1, 0, 1)
        d = a + vec3(0, 0, 1)
      renderer.addLine(a, b, GridColor, GridHalfWidth)
      renderer.addLine(a, d, GridColor, GridHalfWidth)
      if x + 1 == MapColumns or not ship.layer.tiles[index + 1].exists:
        renderer.addLine(b, c, GridColor, GridHalfWidth)
      if y + 1 == MapRows or
        not ship.layer.tiles[index + MapColumns].exists:
          renderer.addLine(d, c, GridColor, GridHalfWidth)

proc drawHud(
  sk: Silky,
  window: Window,
  game: Game,
  state: var ViewState,
  slot: int,
  transportHeight: float32,
  viewProjection: Mat4
): bool =
  ## Draws roles, tasks, meeting votes, chat, and contextual controls.
  let
    width = window.size.x.float32
    height = window.size.y.float32
    world = game.world
    roomToggle = GameUiPanel(origin: vec2(32, 100), size: vec2(270, 32))
    toggleHovered = roomToggle.contains(window.mousePos.vec2) and
      not mouseOverDebugMenu(window.mousePos.vec2)
  if toggleHovered and window.buttonReleased[MouseLeft]:
    state.showRooms = not state.showRooms
  glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  if state.showRooms and (state.camera.overview or slot < 0):
    for room in world.rooms:
      let point = viewProjection * vec4(
        worldPoint(room.x + room.w div 2, room.y + room.h div 2, 0.1), 1
      )
      if point.w <= 0:
        continue
      let position = vec2(
        (point.x / point.w + 1) * width / 2,
        (1 - point.y / point.w) * height / 2
      )
      sk.drawLabel(
        room.name,
        position - vec2(160, 20) + vec2(1, 2),
        vec2(320, 40),
        rgbx(0, 0, 0, 190),
        "Room",
        CenterAlign
      )
      sk.drawLabel(
        room.name,
        position - vec2(160, 20),
        vec2(320, 40),
        White,
        "Room",
        CenterAlign
      )
  elif state.showRooms and slot >= 0:
    let player = world.players[slot]
    let room = nearestRoomAt(world.rooms, player.x, player.y)
    if room.found:
      sk.drawLabel(
        room.name.toUpperAscii(),
        vec2(width / 2 - 160, height - transportHeight - 64),
        vec2(320, 40), White, "Room", CenterAlign
      )
  sk.drawRect(vec2(16, 16), vec2(302, HeaderHeight), Panel)
  sk.label("CREWRIFT", 32, 24, 270, Ink, "H1", 36)
  let role =
    if game.playback: "REPLAY"
    elif slot < 0: "SPECTATOR"
    elif not world.players[slot].alive: "GHOST"
    else: ($world.players[slot].role).toUpperAscii()
  sk.label(role & "  /  " & $world.phase, 32, 65, 270)
  sk.drawTab(roomToggle, selected = state.showRooms, hovered = toggleHovered)
  sk.drawLabel(
    "Room names: " & (if state.showRooms: "on" else: "off"),
    roomToggle.origin,
    roomToggle.size,
    White,
    "Hud",
    CenterAlign
  )
  sk.drawRect(vec2(width - 322, 16), vec2(306, 218), Panel)
  sk.label(world.gameMap.name.toUpperAscii(),
    width - 306, 24, 270, Ink, "Bold")
  sk.drawMap(
    game,
    minimapPanel(window.size.vec2),
    slot,
    state.camera,
    width / max(height, 1)
  )
  var
    total = 0
    remaining = world.totalTasksRemaining()
  for player in world.players:
    if player.role == Crewmate:
      total += player.assignedTasks.len
  sk.drawRect(vec2(338, 20), vec2(max(100.0'f, width - 680), 58), Panel)
  sk.label("CREW TASKS  " & $(total - remaining) & " / " & $total,
    354, 25, max(100.0'f, width - 710))
  let barWidth = max(80.0'f, width - 712)
  sk.drawRect(vec2(354, 57), vec2(barWidth, 6), rgbx(44, 61, 77, 255))
  if total > 0:
    sk.drawRect(vec2(354, 57),
      vec2(barWidth * (total - remaining).float32 / total.float32, 6),
      rgbx(85, 205, 142, 255))
  result = sk.drawRoster(window, game, state, slot, transportHeight)
  if world.phase in {MeetingCall, Voting, VoteResult, RoleReveal, GameOver}:
    let
      panel = meetingPanel(window.size.vec2, transportHeight, world.phase)
      boxWidth = panel.size.x
      x = panel.origin.x
      y = panel.origin.y
      panelHeight = panel.size.y
    sk.drawRect(vec2(x, y), vec2(boxWidth, panelHeight),
      if world.phase == Voting: rgbx(17, 26, 42, 255) else: Panel)
    let title =
      case world.phase
      of MeetingCall: "MEETING CALLED"
      of Voting: "DISCUSS AND VOTE"
      of VoteResult: "VOTE RESULT"
      of GameOver:
        if world.timeLimitReached: "TIME LIMIT"
        elif world.winner == Crewmate: "CREW WINS"
        else: "IMPOSTERS WIN"
      else: "YOUR ROLE: " & role
    sk.label(title, x + 24, y + 18,
      boxWidth - (if world.phase == Voting: 160.0'f else: 48.0'f),
      Ink, "H1", 44)
    if world.phase == RoleReveal:
      let message =
        if slot >= 0 and world.players[slot].role == Imposter:
          "Kill the crew, use vents, and survive the vote."
        else:
          "Finish your tasks. Report bodies. Vote out imposters."
      sk.label(message, x + 24, y + 92, boxWidth - 48, Ink, "Default", 64)
    elif world.phase == GameOver:
      sk.label(
        if game.playback: "Press play to watch again, or seek in the timeline."
        else: "Press R to start a new match, or rewind the timeline.",
        x + 24, y + 92, boxWidth - 48, Ink, "Default")
    elif world.phase == MeetingCall:
      let caller = world.players[world.voteState.callerIndex]
      sk.label(
        playerColorText(caller.color) & " called a meeting.",
        x + 24,
        y + 92,
        boxWidth - 48
      )
    elif world.phase == VoteResult:
      let ejected = world.voteState.ejectedPlayer
      let message =
        if ejected >= 0:
          playerColorText(world.players[ejected].color) & " was ejected."
        else:
          "No one was ejected."
      sk.label(message, x + 24, y + 92, boxWidth - 48, Ink, "Default")
    else:
      sk.drawDiscussion(window, game, state, slot, panel)
  if state.camera.selecting(window.mousePos.vec2):
    let panel = state.camera.selectionBox(window.mousePos.vec2)
    sk.drawRect(panel.origin, panel.size, rgbx(87, 164, 224, 35))
    sk.drawOutline(panel, rgbx(130, 205, 255, 255))

proc drawReplayControls(
  sk: Silky,
  window: Window,
  transport: var player.Player,
  actionCam: var ActionCam,
  following: var bool,
  scale: float32
) =
  ## Scales the shared ribbon inside the single HUD input and drawing frame.
  let layout = initGameUiLayout(window.size.vec2 / scale, TransportHeight)
  var starts: array[2, int]
  for i in 0 ..< starts.len:
    starts[i] = sk.drawer.layers[i].len
  sk.popClipRect()
  sk.pushClipRect(rect(0, 0,
    window.size.x.float32 / scale, window.size.y.float32 / scale))
  sk.mousePos =
    if mouseOverDebugMenu(window.mousePos.vec2):
      vec2(-10000)
    else:
      window.mousePos.vec2 / scale
  transport.drawTransport(
    sk,
    window,
    layout.transportPanel,
    actionCam,
    following,
    keyboardAliases = false
  )
  for i in 0 ..< starts.len:
    for j in starts[i] ..< sk.drawer.layers[i].len:
      sk.drawer.layers[i][j].pos *= scale
      sk.drawer.layers[i][j].clipPos *= scale
      sk.drawer.layers[i][j].clipSize *= scale
  sk.popClipRect()
  sk.pushClipRect(rect(0, 0,
    window.size.x.float32, window.size.y.float32))
  sk.mousePos = window.mousePos.vec2

proc runGraphics*(initial: Options) =
  ## Runs the playable native or browser viewer with fixed simulation ticks.
  var
    options = initial
    game = newGame(options)
    state = ViewState(
      camera: initCamera(if game.playback: -1 else: options.player),
      showRooms: true
    )
    visuals: seq[Visual]
    transport = initPlayer(
      live = not game.playback,
      durationTicks = (game.world.config.maxTicks +
        game.world.config.roleRevealTicks).int32,
      speed = options.speed.int32,
      repeating = game.playback
    )
    actionCam = initActionCam(
      subjectMode = true,
      defaultDistance = 22,
      minDistance = 14,
      maxDistance = OverviewDistance,
      mapSpan = MapColumns.float32
    )
    clock: ViewingClock
    captureFrames = 0
  if existsEnv("SHOW_TILES"):
    try:
      showTiles = getEnv("SHOW_TILES").parseBool()
    except ValueError:
      raise newException(CrewriftError, "SHOW_TILES must be true or false.")
  if not game.playback:
    actionCam.takeManual()

  proc feedCrewActions(slot: int, observeTick = false) =
    ## Supplies visible crew, completed tasks, and deaths to the director.
    if not actionCam.enabled:
      return
    var subjects: seq[Subject]
    for i, crew in game.world.players:
      var
        completed = 0
        participant = 0'i32
      for task in crew.assignedTasks:
        if game.world.tasks[task].completed[i]:
          inc completed
      if not crew.alive:
        for body in game.world.bodies:
          if body.slotId == crew.joinOrder:
            participant = (body.killerSlot + 1).int32
      subjects.add Subject(
        id: (crew.joinOrder + 1).int32,
        owner: i.int32,
        position: worldPoint(crew.x, crew.y),
        height: CrewHeight / 2,
        radius: 0.6,
        visible: game.world.visibleFrom(slot, crew.x, crew.y),
        alive: crew.alive,
        hp: (if crew.alive: 1'i32 else: 0'i32),
        maxHp: 1,
        complete: true,
        participant: participant,
        progress: completed.int32,
        idleScore:
          if crew.activeTask >= 0: 24.0'f
          elif crew.velX != 0 or crew.velY != 0: 18.0'f
          else: 8.0'f,
        combatScore: 100
      )
    if observeTick:
      actionCam.director.observe(subjects)
    actionCam.director.refresh(subjects)

  proc syncTransport() =
    ## Publishes the tape length and reserves remaining live simulation time.
    if transport.live and game.world.phase != GameOver:
      transport.durationTicks = (game.frame + max(0,
        game.world.config.maxTicks - game.world.gameTicksElapsed()) +
        (if game.world.phase == RoleReveal: game.world.roleRevealTimer
         else: 0)).int32
    transport.sync(
      game.frame.int32,
      game.recording.frames.len.int32,
      game.finished()
    )

  syncTransport()
  let
    builder = newHudAtlas(2048)
  builder.addDefaultFonts()
  builder.addFont(BoldFontPath, "Room", 24.0'f)
  builder.write(AtlasPath)
  let (window, sk) = initGameWindow(
    "Crewrift / Polyworld",
    AtlasPath,
    ivec2(options.width.int32, options.height.int32),
    true
  )
  sk.builder = builder
  defer:
    saveReplay(options.record, game.recording)
    window.close()
  var
    terrain = loadShipSkin()
    markers = initShapeRenderer()
    starField = initStarField()
  defer:
    terrain.clearFromGpu()
    markers.closeShapeRenderer()
    starField.close()
  let
    scene = newCharacterScene(window)
    manifest = readManifest(CrewLibrary)
  scene.useToonShading()
  scene.toon.highlightColor = color(1, 1, 1, 1)
  scene.toon.shadowColor = color(0.68, 0.74, 0.84, 1)
  defer:
    for visual in visuals:
      visual.model.file.root.clearFromGpu()
    scene.context.destroy()
  for i in 0 ..< game.world.players.len:
    visuals.add Visual(model: loadCrew(game.world.players[i].color, manifest))
    sk.addAtlasImage(portraitKey(i),
      crewPortrait(window, scene, visuals[i].model))
  installImmutableLayers(@[game.ship.layer])
  if game.world.gameMap.path != "map1":
    initTerrain(
      NoTrees,
      GeneratedTerrain,
      NoRocks,
      settings = TerrainAssets(grass: false, water: false, size: 256)
    )
    bakeTerrain()
  let previousRune = window.onRune
  window.onRune = proc(rune: Rune) =
    ## Collects bounded ASCII meeting text while preserving Silky callbacks.
    if previousRune != nil:
      previousRune(rune)
    if state.typing and rune.int >= 32 and rune.int <= 126 and
      state.text.len < VoteChatMaxChars:
        state.text.add rune.toUTF8()
  while not window.closeRequested:
    pollEvents()
    let
      dt = min(clock.viewingDelta(window), 0.1'f)
      slot = if game.playback: -1 else: options.player
      uiScale = min(
        gameUiScale(window),
        window.size.x.float32 / (TransportMinWidth + 160)
      )
    for key in [KeyF1, KeyF2]:
      if window.buttonPressed[key]:
        discard handleChromeKey(key)
    if window.buttonPressed[KeyEscape]:
      if state.typing:
        state.typing = false
      else:
        break
    if not state.typing:
      if window.buttonPressed[KeyTab]:
        actionCam.takeManual()
        state.camera.showShip(slot)
      if window.buttonPressed[KeyC]:
        actionCam.toggle(state.camera.following)
      if window.buttonPressed[KeyP] or
        (slot < 0 and window.buttonPressed[KeySpace]):
          transport.togglePlay()
      if window.buttonPressed[KeyEqual]:
        transport.setSpeed(transport.speedIndex + 1)
      if window.buttonPressed[KeyMinus]:
        transport.setSpeed(transport.speedIndex - 1)
    if window.buttonPressed[KeyR] and not state.typing and not game.playback:
      saveReplay(options.record, game.recording)
      inc options.seed
      game = newGame(options)
      state.camera = initCamera(slot)
      actionCam.takeManual()
      transport = initPlayer(
        live = true,
        durationTicks = options.ticks.int32,
        speed = transport.speed,
        repeating = transport.repeating
      )
      syncTransport()
    if game.world.phase == Voting and slot >= 0 and
      game.world.players[slot].alive and not game.playback and
      game.frame >= game.recording.frames.len:
        if window.buttonPressed[KeyEnter]:
          if state.typing:
            if state.text.len == 0:
              state.typing = false
            elif game.world.tickCount - game.world.players[slot].lastChatTick >=
              game.world.config.messageCooldownTicks:
                game.chat = state.text
                state.text.setLen(0)
                state.typing = false
          else:
            state.typing = true
        if state.typing and window.buttonPressed[KeyBackspace] and
          state.text.len > 0:
            state.text.setLen(state.text.len - 1)
    else:
      state.typing = false
    game.input = InputState()
    if not state.typing and not window.buttonDown[KeyLeftControl] and
      not window.buttonDown[KeyRightControl]:
        let voting = game.world.phase == Voting
        game.input = InputState(
          up: window.buttonDown[KeyW] or
            (voting and window.buttonDown[KeyUp]),
          down: window.buttonDown[KeyS] or
            (voting and window.buttonDown[KeyDown]),
          left: window.buttonDown[KeyA] or
            (voting and window.buttonDown[KeyLeft]),
          right: window.buttonDown[KeyD] or
            (voting and window.buttonDown[KeyRight]),
          attack: window.buttonDown[KeyE] or window.buttonDown[KeySpace],
          b: window.buttonDown[KeyQ]
        )
    let restoreTick = transport.takeRestore()
    if restoreTick >= 0:
      game.rewind()
      let cameraEnabled = actionCam.enabled
      actionCam = initActionCam(
        subjectMode = true,
        defaultDistance = 22,
        minDistance = 14,
        maxDistance = OverviewDistance,
        mapSpan = MapColumns.float32
      )
      actionCam.enabled = cameraEnabled
      state.typing = false
      state.text.setLen(0)
      syncTransport()
    if options.screenshot.len > 0 and captureFrames == 0:
      for i in 0 ..< options.captureTicks:
        game.advance(slot, record = true)
      syncTransport()
    transport.startFrame(dt, TargetFps.int32)
    let
      frameStart = epochTime()
      previousPhase = game.world.phase
    while transport.shouldTick(frameStart):
      let seeking = transport.targetTick >= 0
      game.advance(slot, record = true)
      feedCrewActions(slot, observeTick = not seeking)
      syncTransport()
    if game.world.gameMap.path == "map1" and
      game.world.phase in {MeetingCall, Voting, VoteResult} and
      game.world.phase != previousPhase:
        state.camera.distance = 22
        state.camera.target = rtsFollowFrame(
          worldPoint(
            game.world.gameMap.home.x,
            game.world.gameMap.home.y,
            0.9
          ),
          state.camera.distance
        )
        state.camera.overview = false
    if captureFrames == 0:
      state.camera.target =
        if slot < 0:
          worldPoint(MapWidth div 2 - 48, MapHeight div 2)
        else:
          let crew = game.world.players[slot]
          rtsFollowFrame(worldPoint(crew.x, crew.y, 0.9), state.camera.distance)
    if not state.typing:
      state.camera.updateCamera(
        window,
        game.world,
        slot,
        dt,
        mouseOverHud(window, game, slot, TransportHeight * uiScale),
        actionCam
      )
    if actionCam.enabled and game.world.phase == Playing:
      feedCrewActions(slot)
      actionCam.direct(
        state.camera.target,
        state.camera.distance,
        (if transport.playing and transport.targetTick < 0: dt else: 0.0'f),
        game.finished(),
        transport.repeating,
        window.size.x.float32 / max(window.size.y, 1).float32
      )
      state.camera.overview = actionCam.director.overview
      if state.camera.overview:
        state.camera.target = worldPoint(MapWidth div 2 - 48, MapHeight div 2)
        state.camera.distance = OverviewDistance
    let
      eye = rtsCameraEye(state.camera.target, state.camera.distance)
      view = lookAt(eye, state.camera.target, vec3(0, 1, 0))
      projection = perspective(
        RtsFieldOfView,
        window.size.x.float32 / max(window.size.y, 1).float32,
        0.1'f, 700.0'f
      )
      vp = projection * view
    if not state.typing:
      state.camera.updateSelection(
        window,
        game.world,
        slot,
        vp,
        actionCam,
        blocked = mouseOverDebugMenu(window.mousePos.vec2)
      )
    scene.beginCharacters(window, view, projection, eye)
    scene.renderer.clearScreen(color(0.025, 0.045, 0.085, 1))
    starField.draw(
      vp,
      eye,
      (game.world.tickCount.float32 + transport.accumulator * TargetFps) /
        TargetFps.float32
    )
    scene.toon.tint = color(1, 1, 1, 1)
    scene.toon.transform = mat4()
    if game.world.gameMap.path != "map1":
      let offset = translate(vec3(
        (MapColumns div 2).float32 - MapHalfWidth,
        0,
        (MapRows div 2).float32 - MapHalfDepth
      ))
      drawTerrain(vp * offset)
    else:
      scene.toon.draw(terrain)
    markers.clear()
    if showTiles:
      markers.addNavigationGrid(game.ship)
    if showPaths:
      for i, bot in game.bots:
        if bot.waypoint >= bot.path.len:
          continue
        let crew = game.world.players[i]
        var previous = worldPoint(crew.x, crew.y, 0.08)
        for j in bot.waypoint ..< bot.path.len:
          let point = worldPoint(bot.path[j].x, bot.path[j].y, 0.08)
          markers.addLine(previous, point, crewInk(crew.color), 0.055)
          previous = point
    for i, station in game.world.tasks:
      if slot >= 0:
        let player = game.world.players[slot]
        if player.role == Crewmate and
          (not player.hasTask(i) or station.completed[slot]):
            continue
        if not game.world.visibleFrom(slot, station.x + 7, station.y + 7):
          continue
      markers.addSquare(
        worldPoint(station.x + 7, station.y + 7, 0.04),
        0.72, rgbx(255, 211, 66, 255)
      )
    for vent in game.world.vents:
      markers.addSquare(
        worldPoint(vent.x + 7, vent.y + 7, 0.045),
        0.64, rgbx(64, 94, 112, 255)
      )
    markers.addSquare(
      worldPoint(game.world.gameMap.home.x, game.world.gameMap.home.y, 0.05),
      1.2, rgbx(245, 89, 98, 255)
    )
    for body in game.world.bodies:
      if game.world.visibleFrom(slot, body.x, body.y):
        markers.addCircle(worldPoint(body.x, body.y, 0.065),
          0.65, playerColorRgba(body.color).rgbx)
    if slot >= 0:
      let player = game.world.players[slot]
      markers.addCircle(worldPoint(player.x, player.y, 0.07),
        0.52, rgbx(71, 226, 234, 180))
    for index in state.camera.selected:
      let crew = game.world.players[index]
      markers.addCircle(
        worldPoint(crew.x, crew.y, 0.08),
        0.58,
        rgbx(130, 205, 255, 180)
      )
    markers.draw(vp)
    for i, player in game.world.players:
      if not player.alive and i != slot:
        continue
      if i != slot and not game.world.visibleFrom(slot, player.x, player.y):
        continue
      let
        position = worldPoint(player.x, player.y)
        moving = player.velX != 0 or player.velY != 0
        facing =
          if moving: arctan2(player.velX.float32, player.velY.float32)
          else: visuals[i].facing
        clip =
          if player.activeTask >= 0: CrewClips[2]
          elif moving: CrewClips[1]
          else: CrewClips[0]
      visuals[i].position = mix(visuals[i].position, position, damping(20, dt))
      if captureFrames == 0 or restoreTick >= 0 or
        game.world.phase != Playing or
        length(visuals[i].position - position) > 5:
          visuals[i].position = position
      visuals[i].facing += shortestTurn(visuals[i].facing, facing) *
        damping(15, dt)
      scene.drawCharacter(
        visuals[i].model, visuals[i].position, visuals[i].facing,
        visuals[i].model.clipIndex(clip),
        (game.world.tickCount.float32 + transport.accumulator * TargetFps) /
          TargetFps.float32,
        tint = (if player.alive: color(1, 1, 1, 1)
          else: color(0.5, 0.85, 1, 0.4))
      )
    scene.finishCharacters()
    sk.uiScale = 1
    sk.beginUi(window, window.size)
    if sk.drawHud(window, game, state, slot, TransportHeight * uiScale, vp):
      actionCam.takeManual()
    sk.drawReplayControls(
      window,
      transport,
      actionCam,
      state.camera.following,
      uiScale
    )
    sk.drawDebugMenu(window)
    sk.endUi()
    inc captureFrames
    if options.screenshot.len > 0 and captureFrames >= 3:
      let screenshot = newImage(window.size.x, window.size.y)
      glReadPixels(
        0, 0, window.size.x, window.size.y, GL_RGBA, GL_UNSIGNED_BYTE,
        screenshot.data[0].addr
      )
      screenshot.flipVertical()
      screenshot.writeFile(options.screenshot)
      break
    window.swapBuffers()
    waitForDisplay()
