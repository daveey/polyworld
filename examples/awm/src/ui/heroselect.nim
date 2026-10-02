## Screen-space labels and picking for the animated 3D hero selection terrace.
import std/[options, strutils]
import chroma, pixie, silky, vmath, windy
import ../core/core, ../scene/heroes, ../scene/heroselectstage, ../scene/table, hud
import polyworld/chrome

const
  SelectionHeroScale* = 1.5'f32
  HeroRole: array[HeroClass, string] = [
    "PRECISION & RANGE", "STRENGTH & STEEL", "SPELLS & STRATEGY"]
  ShortRole: array[HeroClass, string] = ["Ranged", "Might", "Arcane"]
  HeroKeys: array[HeroClass, Button] = [Key1, Key2, Key3]

proc heroSelectScale*(window: Window): float32 =
  let
    size = window.size.vec2
    portrait = size.x < size.y * 0.9'f32
    density = when defined(emscripten): window.contentScale else: 1'f32
    reference = if portrait: vec2(1000, 1500) else: vec2(2400, 1500)
  max(0.01'f32, min(density, min(size.x / reference.x, size.y / reference.y)))

proc heroCharacterRect*(window: Window, viewProjection: Mat4,
    heroClass: HeroClass): UiRect =
  ## Project a generous body-and-equipment silhouette; it follows the camera,
  ## viewport and display density, rather than a fixed screen-space column.
  let
    scale = heroSelectScale(window)
    feet = HeroSelectPositions[heroClass.ord]
    bottom = screenPosition(window, feet, viewProjection) / scale
    head = screenPosition(window,
      feet + vec3(0, HeroHeight * SelectionHeroScale * 1.30'f32, 0),
      viewProjection) / scale
    side = screenPosition(window, feet + vec3(1.35, 0, 0),
      viewProjection) / scale
    radius = max(32'f32, abs(side.x - bottom.x))
  UiRect(origin: vec2(bottom.x - radius, head.y),
    size: vec2(radius * 2, bottom.y - head.y + 12))

proc heroChoiceRect*(window: Window, viewProjection: Mat4,
    heroClass: HeroClass): UiRect =
  let
    scale = heroSelectScale(window)
    size = window.size.vec2 / scale
    portrait = size.x < size.y * 0.9'f32
    feet = screenPosition(window, HeroSelectPositions[heroClass.ord],
      viewProjection) / scale
    width = min(540'f32, (size.x - 112) / 3)
    height = if portrait: 300'f32 else: 258'f32
    center = if portrait: size.x * (heroClass.ord.float32 + 0.5'f32) / 3
      else: feet.x
  UiRect(origin: vec2(clamp(center - width * 0.5'f32, 20, size.x - width - 20),
    min(feet.y + 56, size.y - height - 104)), size: vec2(width, height))

proc heroButtonRect*(panel: UiRect, portrait: bool): UiRect =
  UiRect(origin: panel.origin + vec2(18, panel.size.y - (if portrait: 114'f32 else: 104'f32)),
    size: vec2(panel.size.x - 36, if portrait: 96'f32 else: 84'f32))

proc hoveredSelectionHero*(window: Window, mouse: Vec2,
    viewProjection: Mat4): Option[HeroClass] =
  let size = window.size.vec2 / heroSelectScale(window)
  for heroClass in HeroClass:
    if heroCharacterRect(window, viewProjection, heroClass).contains(mouse) or
        heroButtonRect(heroChoiceRect(window, viewProjection, heroClass),
          size.x < size.y * 0.9'f32).contains(mouse):
      return some(heroClass)

proc drawHeroSelect*(sk: Silky, window: Window, viewProjection: Mat4,
    human: bool, inputEnabled = true): Option[HeroClass] =
  let
    size = window.size.vec2 / sk.uiScale
    portrait = size.x < size.y * 0.9'f32
    hovered = if human and inputEnabled:
        hoveredSelectionHero(window, sk.mousePos, viewProjection)
      else: none(HeroClass)
    headingWidth = min(1000'f32, size.x - 48)
    heading = vec2((size.x - headingWidth) * 0.5'f32, 26)
  sk.hudSprite("turn-plaque", heading, vec2(headingWidth, 200))
  sk.drawLabel(if human: "Choose your hero" else: "The battle awaits",
    heading + vec2(36, 8), vec2(headingWidth - 72, 82), HudIvory,
    "H1", CenterAlign)
  sk.drawLabel("ARCHERS   /   WARRIORS   /   MAGES",
    heading + vec2(36, 90), vec2(headingWidth - 72, 36), HudGold,
    "Small", CenterAlign)
  sk.drawLabel(if human: "Choose a champion. Lead them to victory."
    else: "The bots are choosing their heroes...",
    vec2(0, 212), vec2(size.x, 48), HudIvory, "Small", CenterAlign)

  for heroClass in HeroClass:
    let
      panel = heroChoiceRect(window, viewProjection, heroClass)
      active = hovered == some(heroClass)
      button = heroButtonRect(panel, portrait)
    sk.hudSprite("notice", panel.origin, panel.size,
      if active: rgbx(255, 255, 255, 255) else: rgbx(225, 225, 225, 255))
    if portrait:
      sk.hudSprite(HudClassIcon[heroClass],
        panel.origin + vec2(panel.size.x * 0.5'f32 - 20, -24), vec2(40, 55))
      sk.drawLabel(heroClass.className(), panel.origin + vec2(12, 34),
        vec2(panel.size.x - 24, 78), HudIvory, "TurnState", CenterAlign)
      sk.drawLabel(ShortRole[heroClass], panel.origin + vec2(12, 112),
        vec2(panel.size.x - 24, 42), HudClassInk[heroClass], "Hud", CenterAlign)
    else:
      sk.hudSprite(HudClassIcon[heroClass], panel.origin + vec2(26, 18),
        vec2(72, 99))
      sk.drawLabel(heroClass.className(), panel.origin + vec2(116, 16),
        vec2(panel.size.x - 140, 82), HudIvory, "H1")
      sk.drawLabel(HeroRole[heroClass], panel.origin + vec2(116, 94),
        vec2(panel.size.x - 132, 42), HudClassInk[heroClass], "Small")
    sk.hudSprite(if not human: "button-disabled"
      elif active: "button-hover" else: "button", button.origin, button.size)
    sk.drawLabel(if not human: "CHOOSING..."
      elif portrait: "CHOOSE"
      else: "CHOOSE " & heroClass.className().toUpperAscii(),
      button.origin + vec2(12, 0), button.size - vec2(24, 0),
      if human: HudIvory else: HudMuted, "Heading", CenterAlign)
    if human and inputEnabled and
        ((active and window.buttonPressed[MouseLeft]) or
          window.buttonPressed[HeroKeys[heroClass]]):
      result = some(heroClass)

  sk.drawLabel(if human: "Click a hero or their button to begin.  /  Keys 1, 2, 3"
    else: "The arena is ready. Your match begins shortly.",
    vec2(0, size.y - 80), vec2(size.x, 42), HudMuted, "Small", CenterAlign)
