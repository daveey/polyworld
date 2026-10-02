## Provisional layout controls, built only with -d:awmLayoutTuning: move the
## camera, either hand or the played spell around with the keyboard, then
## print the values to paste back as defaults. Shared by every game mode.
import windy
import ../scene/placement
export placement

type
  TuningTarget* = object
    ## One thing the movement keys can move.
    name*: string
    placement*: ptr Placement

  LayoutTuner* = object
    index*: int  ## Which of the mode's targets the keys move.

const
  TuneMoveSpeed = 3.0'f32    ## Units per second held.
  TuneTurnSpeed = 0.35'f32   ## Radians per second held.

proc tuningTarget*(name: string, placement: var Placement): TuningTarget =
  TuningTarget(name: name, placement: addr placement)

proc announce*(tuner: LayoutTuner, targets: openArray[TuningTarget]) =
  if targets.len > 0:
    echo "Moving: ", targets[tuner.index mod targets.len].name

proc tune*(tuner: var LayoutTuner, window: Window, dt: float32,
    targets: openArray[TuningTarget]) =
  ## Z/X pick what to move, WASD/QE move it, T/G pitch it and F/H yaw it.
  if targets.len == 0:
    return
  if window.buttonPressed[KeyZ] or window.buttonPressed[KeyX]:
    let step = if window.buttonPressed[KeyX]: 1 else: targets.len - 1
    tuner.index = (tuner.index + step) mod targets.len
    tuner.announce(targets)
  let
    placement = targets[tuner.index mod targets.len].placement
    down = window.buttonDown
    move = TuneMoveSpeed * dt
    turn = TuneTurnSpeed * dt
  # Forward is away from the viewer, so it shortens the distance to the seat.
  if down[KeyW]: placement.distance -= move
  if down[KeyS]: placement.distance += move
  if down[KeyA]: placement.lateral -= move
  if down[KeyD]: placement.lateral += move
  if down[KeyQ]: placement.height += move
  if down[KeyE]: placement.height -= move
  if down[KeyT]: placement.pitch += turn
  if down[KeyG]: placement.pitch -= turn
  if down[KeyF]: placement.yaw -= turn
  if down[KeyH]: placement.yaw += turn
