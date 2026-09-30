## Where a camera or a hand sits, shared by the duel and the multiplayer
## preview. This module deliberately has no graphics or game dependency.
import std/[math, strutils]
import vmath

type
  Placement* = object
    ## Measured from the seat the camera sits behind: `lateral` grows to the
    ## viewer's right, `height` upward, and `distance` toward the viewer.
    ## `pitch` is radians below the horizon for a camera, or a tilt added to
    ## a hand's camera-facing angle; `yaw` turns to the viewer's right.
    lateral*, height*, distance*, pitch*, yaw*: float32

proc turnRight*(value: Vec3, yaw: float32): Vec3 =
  ## Same rotation convention as the cards, the seats and the characters.
  vec3(value.x * cos(yaw) - value.z * sin(yaw), value.y,
    value.x * sin(yaw) + value.z * cos(yaw))

proc eye*(camera: Placement): Vec3 =
  vec3(camera.lateral, camera.height, camera.distance)

proc forward*(camera: Placement): Vec3 =
  ## The direction a camera looks: pitched below the horizon, then yawed.
  turnRight(vec3(0, -sin(camera.pitch), -cos(camera.pitch)), camera.yaw)

proc target*(camera: Placement): Vec3 =
  camera.eye + camera.forward

proc seatEye*(camera: Placement, side: float32): Vec3 =
  ## The camera's eye as seen from the seat on `side` (1 or -1 along Z).
  let eye = camera.eye
  vec3(eye.x * side, eye.y, eye.z * side)

proc seatTarget*(camera: Placement, side: float32): Vec3 =
  ## What that camera looks at, so a flipped seat keeps its own left, right
  ## and forward.
  let ahead = camera.forward
  camera.seatEye(side) + vec3(ahead.x * side, ahead.y, ahead.z * side)

proc mirrored*(placement: Placement, side: float32): Placement =
  ## The same placement seen from the seat on `side` (1 or -1 along Z), so
  ## a flipped camera keeps its own left and right.
  result = placement
  result.lateral = placement.lateral * side
  result.distance = placement.distance * side

proc literal*(placement: Placement, indent = "      "): string =
  ## A `Placement(...)` literal, ready to paste back as a default.
  proc f(value: float32, digits: int): string =
    formatFloat(value, ffDecimal, digits)
  # The angles are noted on the pitch line: a comment on the closing line
  # would swallow the comma that follows it in a table.
  "Placement(lateral: " & f(placement.lateral, 2) & ", height: " &
    f(placement.height, 2) & ", distance: " & f(placement.distance, 2) &
    ",\n" & indent & "pitch: " & f(placement.pitch, 4) & ", # " &
    f(radToDeg(placement.pitch), 1) & " deg down, yaw " &
    f(radToDeg(placement.yaw), 1) & " deg\n" & indent & "yaw: " &
    f(placement.yaw, 4) & ")"
