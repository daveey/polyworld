## Shared geometry and seat coordinates for the multiplayer scene preview.
## This module deliberately has no game state, graphics or random dependency.
import std/[math, strutils]
import vmath
import placement
export placement

type
  MultiplayerCamera* = Placement
    ## An absolute camera on P1's side (+Z), like the duel's.
  MultiplayerView* = object
    ## Camera and hands. P1's hand is near; every other balcony's is far.
    ## The hands are balcony-local, and their pitch is added to the tilt that
    ## faces the camera.
    camera*: MultiplayerCamera
    nearHand*, farHand*: Placement
    handRoll*: float32
  PlayerBalcony* = object
    playerIndex*: int
    center*: Vec3
    yaw*: float32
    ## Every zone is a balcony-local anchor. Pile and board Y values are the
    ## top of their supporting surface, before adding the thickness of a card.
    heroZone*, deckZone*, discardZone*, handZone*, boardZone*: Vec3
  MultiplayerLayout* = object
    playerCount*: int
    centerRadius*, innerRadius*, outerRadius*, balconyHalfAngle*: float32
    balconies*: seq[PlayerBalcony]

const
  MultiplayerFovY* = 42.0'f32  ## Degrees, matching vmath.perspective.
  BalconyDepth* = 6.5'f32
  BalconyLampHeight* = 1.25'f32
  MultiplayerHandHeight* = 1.25'f32
  MultiplayerHandDistance* = 1.95'f32
    ## Balcony-local Z of the hand; larger moves it out, away from the center.
  MultiplayerHandPitch* = 0.55'f32
  Tau = 2.0'f32 * PI.float32

proc rotateSeat*(point: Vec3, yaw: float32): Vec3 =
  ## Same rotation convention as AWM's cards and characters.
  vec3(point.x * cos(yaw) - point.z * sin(yaw), point.y,
    point.x * sin(yaw) + point.z * cos(yaw))

proc toWorld*(balcony: PlayerBalcony, local: Vec3): Vec3 =
  balcony.center + rotateSeat(local, balcony.yaw)

proc toLocal*(balcony: PlayerBalcony, world: Vec3): Vec3 =
  rotateSeat(world - balcony.center, -balcony.yaw)

proc buildMultiplayerLayout*(playerCount: int): MultiplayerLayout =
  if playerCount < 3:
    raise newException(ValueError, "A multiplayer battlefield needs at least 3 players")
  result.playerCount = playerCount
  result.centerRadius = 3.0
  # Leave actual sky between the separate islands. Once the angular slice
  # narrows, add radial courses instead of squeezing the hero or card zones.
  result.balconyHalfAngle = min(0.68'f32, PI.float32 / playerCount.float32 * 0.86'f32)
  let tangent = tan(result.balconyHalfAngle)
  result.innerRadius = max(5.0'f32,
    max(3.40'f32 / tangent - 0.40'f32, 4.90'f32 / tangent - 2.20'f32))
  result.outerRadius = result.innerRadius + BalconyDepth
  let centerDistance = result.innerRadius + BalconyDepth * 0.5'f32
  for playerIndex in 0 ..< playerCount:
    let yaw = Tau * playerIndex.float32 / playerCount.float32
    result.balconies.add PlayerBalcony(
      playerIndex: playerIndex,
      center: rotateSeat(vec3(0, 0, centerDistance), yaw), yaw: yaw,
      heroZone: vec3(0, 0.015, 0.45),
      deckZone: vec3(-3.75, 0.155, 0.55),
      discardZone: vec3(3.75, 0.155, 0.55),
      handZone: vec3(0, MultiplayerHandHeight, MultiplayerHandDistance),
      boardZone: vec3(0, 0.015, -1.8))

proc lampRadius*(layout: MultiplayerLayout): float32 =
  layout.outerRadius - 0.52'f32

proc lampHalfAngle*(layout: MultiplayerLayout): float32 =
  layout.balconyHalfAngle * 0.89'f32

proc lampPosition*(layout: MultiplayerLayout, playerIndex: int,
    side: float32): Vec3 =
  let angle = side * layout.lampHalfAngle
  rotateSeat(vec3(sin(angle) * layout.lampRadius, BalconyLampHeight,
    cos(angle) * layout.lampRadius), layout.balconies[playerIndex].yaw)

proc cameraTarget*(layout: MultiplayerLayout): Vec3 = vec3(0, 0, 0)

proc cameraEye*(layout: MultiplayerLayout, aspect: float32,
    verticalFov = MultiplayerFovY): Vec3 =
  ## Fit the entire scene's bounding sphere in the narrower field of view.
  ## This remains safe when a window becomes portrait, or the seat count
  ## requires a larger ring. The steep view keeps every player's zones visible.
  let
    halfVertical = clamp(verticalFov, 10.0'f32, 100.0'f32) * PI.float32 / 360
    halfHorizontal = arctan(tan(halfVertical) * max(0.001'f32, aspect))
    halfFov = min(halfVertical, halfHorizontal)
    radius = sqrt((layout.outerRadius + 0.9'f32) ^ 2 + 3.0'f32 ^ 2)
    distance = radius / sin(halfFov) * 1.08'f32
  layout.cameraTarget + normalize(vec3(0, 1.9, 1)) * distance

proc fittedCamera*(layout: MultiplayerLayout, aspect: float32,
    verticalFov = MultiplayerFovY): MultiplayerCamera =
  ## The auto-fitted view as absolute values, a starting point for tuning.
  let eye = layout.cameraEye(aspect, verticalFov)
  let toTarget = layout.cameraTarget - eye
  MultiplayerCamera(lateral: eye.x, height: eye.y, distance: eye.z,
    pitch: arctan2(-toTarget.y, -toTarget.z))

const TunedViews: array[3 .. 7, MultiplayerView] = [
  # Hand-tuned for 3 and 7 seats in a 16:10 window; 4-6 interpolate them.
  3: MultiplayerView(
    camera: Placement(lateral: 4.00, height: 25.72, distance: 18.56,
      pitch: 0.9638, # 55.2 deg down, yaw 0.0 deg
      yaw: 0.0000),
    nearHand: Placement(lateral: 1.10, height: 9.61, distance: 5.30),
    farHand: Placement(lateral: 0.00, height: 1.66, distance: 3.36,
      pitch: 1.7693, # 101.4 deg down, yaw 1.1 deg
      yaw: 0.0199),
    handRoll: 0.0000),
  4: MultiplayerView(
    camera: Placement(lateral: 4.35, height: 27.28, distance: 21.21,
      pitch: 0.9318, # 53.4 deg down, yaw 0.0 deg
      yaw: 0.0000),
    nearHand: Placement(lateral: 1.39, height: 10.79, distance: 6.10),
    farHand: Placement(lateral: 0.00, height: 1.66, distance: 3.36,
      pitch: 1.7693, # 101.4 deg down, yaw 1.1 deg
      yaw: 0.0199),
    handRoll: 0.0000),
  5: MultiplayerView(
    camera: Placement(lateral: 4.70, height: 28.84, distance: 23.85,
      pitch: 0.8999, # 51.6 deg down, yaw 0.0 deg
      yaw: 0.0000),
    nearHand: Placement(lateral: 1.68, height: 11.96, distance: 6.91),
    farHand: Placement(lateral: 0.00, height: 1.66, distance: 3.36,
      pitch: 1.7693, # 101.4 deg down, yaw 1.1 deg
      yaw: 0.0199),
    handRoll: 0.0000),
  6: MultiplayerView(
    camera: Placement(lateral: 5.04, height: 30.39, distance: 26.50,
      pitch: 0.8679, # 49.7 deg down, yaw 0.0 deg
      yaw: 0.0000),
    nearHand: Placement(lateral: 1.96, height: 13.14, distance: 7.71),
    farHand: Placement(lateral: 0.00, height: 1.66, distance: 3.36,
      pitch: 1.7693, # 101.4 deg down, yaw 1.1 deg
      yaw: 0.0199),
    handRoll: 0.0000),
  7: MultiplayerView(
    camera: Placement(lateral: 5.39, height: 31.95, distance: 29.15,
      pitch: 0.8360, # 47.9 deg down, yaw 0.0 deg
      yaw: 0.0000),
    nearHand: Placement(lateral: 2.25, height: 14.32, distance: 8.52),
    farHand: Placement(lateral: 0.00, height: 1.66, distance: 3.36,
      pitch: 1.7693, # 101.4 deg down, yaw 1.1 deg
      yaw: 0.0199),
    handRoll: 0.0000)]

proc multiplayerView*(layout: MultiplayerLayout, aspect: float32): MultiplayerView =
  ## The tuned view for 3-7 seats. Larger rings keep the 7-seat hands and
  ## fit the camera to the window, since no tuned camera covers them.
  if layout.playerCount <= TunedViews.high:
    return TunedViews[layout.playerCount]
  result = TunedViews[TunedViews.high]
  result.camera = layout.fittedCamera(aspect)

proc tunedRow*(view: MultiplayerView, playerCount: int): string =
  ## One TunedViews row, ready to paste back into the table.
  "  " & $playerCount & ": MultiplayerView(\n" &
    "    camera: " & view.camera.literal() & ",\n" &
    "    nearHand: " & view.nearHand.literal() & ",\n" &
    "    farHand: " & view.farHand.literal() & ",\n" &
    "    handRoll: " & formatFloat(view.handRoll, ffDecimal, 4) & "),"

const
  SeatSwitchSeconds* = 0.9'f32
    ## How long the ring takes to turn the next balcony to the camera.

type
  SeatOrbit* = object
    ## The yaw of the balcony in front of the camera, eased toward the
    ## watched one. The ring turns by -yaw (see stageRotation).
    yaw*: float32
    fromYaw, toYaw, elapsed: float32

proc initSeatOrbit*(yaw: float32): SeatOrbit =
  SeatOrbit(yaw: yaw, fromYaw: yaw, toYaw: yaw, elapsed: SeatSwitchSeconds)

proc aimAt*(orbit: var SeatOrbit, yaw: float32) =
  ## Turn from wherever the ring is now, the short way around.
  orbit.fromYaw = orbit.yaw
  orbit.toYaw = orbit.yaw +
    floorMod(yaw - orbit.yaw + PI.float32, Tau) - PI.float32
  orbit.elapsed = 0

proc advance*(orbit: var SeatOrbit, dt: float32) =
  orbit.elapsed = min(orbit.elapsed + dt, SeatSwitchSeconds)
  let
    t = orbit.elapsed / SeatSwitchSeconds
    eased = t * t * (3 - 2 * t)
  orbit.yaw = orbit.fromYaw + (orbit.toYaw - orbit.fromYaw) * eased

proc stageRotation*(yaw: float32): Mat4 =
  ## Turns the whole ring so the balcony at this yaw sits where P1's does,
  ## in front of a fixed camera: the same as rotateSeat(point, -yaw).
  let (s, c) = (sin(yaw), cos(yaw))
  mat4(
    c, 0, -s, 0,
    0, 1, 0, 0,
    s, 0, c, 0,
    0, 0, 0, 1)
