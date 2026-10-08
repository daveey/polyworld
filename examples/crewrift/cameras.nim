## Fixed north, pan, zoom, minimap, and selection controls for the ship viewer.

import
  std/math,
  vmath, windy,
  polyworld/[actioncam, gameuis, rtscameras, viewers],
  maps, sim

const
  OverviewDistance* = 110.0'f
  SelectionDragPixels = 6.0'f

type
  CameraState* = object
    target*: Vec3
    distance*: float32
    overview*, following*: bool
    selected*: seq[int]
    panning, minimapPanning, selectionStarted, additive: bool
    selectionStart: Vec2
    groupScale: float32

proc initCamera*(slot: int): CameraState =
  ## Starts on the human crew member or a complete spectator ship view.
  result.distance = if slot >= 0: 22.0'f else: OverviewDistance
  result.overview = slot < 0
  result.groupScale = 1
  if slot >= 0:
    result.selected = @[slot]
    result.following = true

proc minimapPanel*(size: Vec2): GameUiPanel =
  ## Returns the ship minimap rectangle in window pixel coordinates.
  GameUiPanel(origin: vec2(size.x - 308, 54), size: vec2(278, 164))

proc minimapSize*(panel: GameUiPanel): Vec2 =
  ## Returns the occupied map footprint inside its padded HUD rectangle.
  let scale = min(
    panel.size.x / MapColumns.float32,
    panel.size.y / MapRows.float32
  )
  vec2(MapColumns.float32, MapRows.float32) * scale

proc constrain(camera: var CameraState) =
  ## Keeps the manual look target within the rectangular ship extent.
  camera.target.x = clamp(camera.target.x, -MapHalfWidth, MapHalfWidth)
  camera.target.z = clamp(camera.target.z, -MapHalfDepth, MapHalfDepth)

proc canSelect(world: SimServer, slot, index: int): bool =
  ## Selects only drawn crew, including the human player's own ghost.
  let crew = world.players[index]
  (crew.alive or index == slot) and
    world.visibleFrom(slot, crew.x, crew.y)

proc selectCrew*(camera: var CameraState, indices: openArray[int],
    additive = false) =
  ## Follows one crew member or the center of an explicitly selected group.
  if not additive:
    camera.selected.setLen(0)
  for index in indices:
    if index notin camera.selected:
      camera.selected.add index
  camera.following = camera.selected.len > 0
  camera.overview = false
  camera.groupScale = 1

proc showShip*(camera: var CameraState, slot: int) =
  ## Toggles between the complete ship and the human crew follow view.
  if camera.overview and slot >= 0:
    camera.selectCrew([slot])
    camera.distance = 22
  else:
    camera.overview = true
    camera.following = false
    camera.target = worldPoint(MapWidth div 2 - 48, MapHeight div 2)
    camera.distance = OverviewDistance

proc selectionBox*(camera: CameraState, pointer: Vec2): GameUiPanel =
  ## Returns the current box selection in window pixel coordinates.
  result.origin = min(camera.selectionStart, pointer)
  result.size = abs(pointer - camera.selectionStart)

proc selecting*(camera: CameraState, pointer: Vec2): bool =
  ## Returns whether a held left gesture has become a box selection.
  camera.selectionStarted and
    length(pointer - camera.selectionStart) > SelectionDragPixels

proc updateCamera*(
  camera: var CameraState,
  window: Window,
  world: SimServer,
  slot: int,
  dt: float32,
  overUi: bool,
  actionCam: var ActionCam
) =
  ## Applies the GOTA and LVD pan, zoom, minimap, and selection gestures.
  var selected: seq[int]
  for index in camera.selected:
    if world.canSelect(slot, index):
      selected.add index
  camera.selected = selected
  if selected.len == 0:
    camera.following = false
  let
    pointer = window.mousePos.vec2
    panel = minimapPanel(window.size.vec2)
    content = GameUiPanel(origin: panel.origin, size: panel.minimapSize())
    middlePressed = window.buttonPressed[MouseMiddle] or
      (slot < 0 and window.buttonPressed[KeyS])
    middleDown = window.buttonDown[MouseMiddle] or
      (slot < 0 and window.buttonDown[KeyS])
    rightDown = window.buttonDown[MouseRight] or
      (slot < 0 and window.buttonDown[KeyD])
  if window.buttonPressed[MouseLeft]:
    if content.contains(pointer):
      camera.minimapPanning = true
    elif not overUi:
      camera.selectionStarted = true
      camera.selectionStart = pointer
      camera.additive = window.buttonDown[KeyLeftShift] or
        window.buttonDown[KeyRightShift]
  if not window.buttonDown[MouseLeft]:
    camera.minimapPanning = false
  if middlePressed and not overUi:
    camera.panning = true
  if not middleDown:
    camera.panning = false
  if window.buttonPressed[KeyA] and
    (window.buttonDown[KeyLeftControl] or
      window.buttonDown[KeyRightControl]):
        selected.setLen(0)
        for i in 0 ..< world.players.len:
          if world.canSelect(slot, i):
            selected.add i
        camera.selectCrew(selected)
        actionCam.takeManual()
  if camera.minimapPanning:
    let ratio = clamp(
      (pointer - content.origin) / content.size,
      vec2(0),
      vec2(1)
    )
    camera.target = vec3(
      ratio.x * MapColumns.float32 - MapHalfWidth,
      0,
      ratio.y * MapRows.float32 - MapHalfDepth
    )
    camera.following = false
    camera.overview = false
    actionCam.takeManual()
  elif camera.panning or (rightDown and not overUi):
    let delta = window.mouseDelta.vec2 * camera.distance * 0.0015'f
    camera.target.x -= delta.x
    camera.target.z -= delta.y
    camera.following = false
    camera.overview = false
    actionCam.takeManual()
  if not camera.minimapPanning and
    not (slot >= 0 and world.phase == Voting) and
    applyRtsPan(
      camera.target,
      rtsPanDir(window),
      dt,
      camera.distance,
      MapHalfWidth
    ):
      camera.following = false
      camera.overview = false
      actionCam.takeManual()
  camera.constrain()
  if not overUi and window.scrollDelta.y != 0:
    actionCam.takeManual()
    let factor = pow(0.92'f, window.scrollDelta.y / 3.0'f)
    if camera.following and camera.selected.len > 1:
      camera.groupScale = clamp(camera.groupScale * factor, 0.75'f, 3.0'f)
    else:
      camera.distance = clamp(camera.distance * factor, 5.0'f, 400.0'f)
  if actionCam.enabled or not camera.following:
    return
  var center = vec3(0)
  for index in camera.selected:
    let crew = world.players[index]
    center += worldPoint(crew.x, crew.y, 0.9)
  center /= camera.selected.len.float32
  var radius = 0.0'f
  for index in camera.selected:
    let crew = world.players[index]
    radius = max(radius, length(worldPoint(crew.x, crew.y, 0.9) - center))
  let target =
    if camera.selected.len == 1:
      rtsFollowFrame(center, camera.distance)
    else:
      center
  camera.target = mix(camera.target, target, damping(5, dt))
  if camera.selected.len > 1:
    let distance = clamp(12.0'f + radius * 2.8'f, 20.0'f, 400.0'f) *
      camera.groupScale
    camera.distance = mix(camera.distance, distance, damping(2, dt))

proc screenPoint(point: Vec3, projection: Mat4, size: Vec2): Vec2 =
  ## Projects one world position into top-left window pixel coordinates.
  let clip = projection * vec4(point, 1)
  if clip.w <= 0:
    return vec2(-10000)
  vec2(clip.x / clip.w + 1, 1 - clip.y / clip.w) * size / 2

proc updateSelection*(
  camera: var CameraState,
  window: Window,
  world: SimServer,
  slot: int,
  projection: Mat4,
  actionCam: var ActionCam,
  blocked = false
) =
  ## Applies left click, shift click, and box selection on release.
  if not window.buttonReleased[MouseLeft] or not camera.selectionStarted:
    return
  if blocked:
    camera.selectionStarted = false
    return
  let
    pointer = window.mousePos.vec2
    box = camera.selectionBox(pointer)
    dragging = camera.selecting(pointer)
  camera.selectionStarted = false
  var
    selected: seq[int]
    nearest = -1
    best = high(float32)
  for i, crew in world.players:
    if not world.canSelect(slot, i):
      continue
    let
      center = screenPoint(worldPoint(crew.x, crew.y, 0.9),
        projection, window.size.vec2)
      feet = screenPoint(worldPoint(crew.x, crew.y),
        projection, window.size.vec2)
      head = screenPoint(worldPoint(crew.x, crew.y, 1.8),
        projection, window.size.vec2)
      hit = GameUiPanel(
        origin: vec2(center.x - 12, min(head.y, feet.y) - 6),
        size: vec2(24, abs(head.y - feet.y) + 12)
      )
    if dragging:
      if box.contains(center):
        selected.add i
    elif hit.contains(pointer) and length(center - pointer) < best:
      nearest = i
      best = length(center - pointer)
  if not dragging and nearest >= 0:
    selected.add nearest
  camera.selectCrew(selected, camera.additive)
  actionCam.takeManual()
