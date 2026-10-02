## Native, screen-space HUD review at several sizes and resource states.
## nim c -r --out:build/render-hud tools/render_hud.nim
import std/[math, os, strformat, tables]
import chroma, opengl, pixie, silky, vmath, windy
import ../src/core/sim, ../src/paths, ../src/ui/hud
import polyworld/[assets, chrome, viewers]


let
  root = currentSourcePath().parentDir.parentDir
  output = root / "build/ui-review"
setCurrentDir(root.parentDir.parentDir)
let builder = newHudAtlas(2048)
createDir(output)
builder.addAwmHudAssets(artworkRoot() / "cards")
builder.addFont(DefaultFontPath, "Small", 22.5)
builder.write(output / "hud.atlas.png")
let (window, sk) = initGameWindow("AWM HUD review", output / "hud.atlas.png",
  ivec2(2400, 1500))
doAssert sk.getTextSize("Heading", "OPPONENT").x <= 176
doAssert sk.getTextSize("Number", "100").x <= 94
doAssert sk.getTextSize("Action", "MATCH ENDED").x <= 424

for capture in 0 ..< 6:
  # The final pair holds the UI still at the glow's bright and dim phases.
  let scenario = if capture >= 4: 0 else: capture
  let time = if capture == 4: 1'f32 elif capture == 5: 3'f32 else: scenario.float32
  window.size = if scenario == 0: ivec2(3200, 2000)
    elif scenario == 1: ivec2(1280, 800)
    elif scenario == 2: ivec2(1920, 1080) else: ivec2(1024, 768)
  pollEvents()
  var game = newGame(HeroClass(scenario mod 3), HeroClass((scenario + 1) mod 3), 42)
  game.currentPlayer = scenario mod 2
  game.turnNumber = scenario + 7
  game.players[0].life = 15
  game.players[1].life = 20
  game.players[0].totalEnergy = if scenario == 2: 12 else: 10
  game.players[0].energy = if scenario == 0: 1 elif scenario == 2: 11 else: 10
  game.players[1].totalEnergy = 10
  game.players[1].energy = 0
  sk.uiScale = hudScale(window)
  glViewport(0, 0, window.size.x, window.size.y)
  glClearColor(0.032, 0.043, 0.052, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  sk.beginUi(window, window.size)
  sk.mousePos = vec2(-100)
  drawPlayerPanel(sk, window, game, 0, scenario != 3, time)
  drawPlayerPanel(sk, window, game, 1, scenario != 3, time)
  drawTurnHeader(sk, window, game, scenario != 3,
    "A long status message is safely fitted between both player panels, with no text overlap.")
  let notice = UiRect(origin: vec2(hudSize(window).x * 0.5'f32 - 430, HudHelperY),
    size: vec2(860, 112))
  sk.drawHudNotice(notice)
  sk.drawLabel("Choose a hero.", notice.origin + vec2(22, 10), vec2(816, 30),
    HudClassInk[game.players[0].heroClass], "Prompt", CenterAlign)
  sk.drawLabel("Bolt: Deal 2 damage to a hero.", notice.origin + vec2(22, 46),
    vec2(816, 28), HudIvory, "Small", CenterAlign)
  sk.drawLabel("Right-click cancels.", notice.origin + vec2(22, 76),
    vec2(816, 28), HudMuted, "Small", CenterAlign)
  let finish = finishRect(window)
  discard drawButton(sk, window, finish, if scenario mod 2 == 0: "END TURN" else: "OPPONENT",
    enabled = scenario mod 2 == 0)
  if scenario mod 2 == 0:
    sk.drawLabel("Press Enter", finish.origin + vec2(0, finish.size.y + 6),
      vec2(finish.size.x, 32), HudMuted, "Small", CenterAlign)
  sk.endUi()
  let shot = newImage(window.size.x, window.size.y)
  glReadPixels(0, 0, window.size.x, window.size.y, GL_RGBA, GL_UNSIGNED_BYTE,
    shot.data[0].addr)
  shot.flipVertical()
  shot.writeFile(output / &"hud-{capture}-{window.size.x}x{window.size.y}.png")
  window.swapBuffers()
echo "HUD review: ", output
