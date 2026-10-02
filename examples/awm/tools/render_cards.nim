## Regenerate standalone card previews without opening the game.
## Run from the AWM project root (examples/awm):
## nim c -r --out:/tmp/awm-render-cards tools/render_cards.nim
import std/[os, strutils]
import pixie
import ../src/core/core, ../src/core/baseset, ../src/ui/cardfaces, ../src/paths

let
  root = artworkRoot() / "cards"
  outputDir = root / "previews"
initCardAssets()
createDir(outputDir)

const
  Columns = 5
  PreviewWidth = 300
  PreviewHeight = 425
  Margin = 56
  ColumnGap = 28
  RowGap = 32
  HeaderHeight = 158
  FooterHeight = 72

proc artworkSlug(card: Card): string =
  ## Convert a card name to its illustration filename.
  card.name.toLowerAscii().replace(" ", "-")

# A complete contact sheet must never silently include placeholder art.
for card in baseCards:
  let artPath = root / "art" / (card.artworkSlug() & ".png")
  if not fileExists(artPath):
    raise newException(IOError, "Missing artwork for " & card.name & ": " & artPath)

let
  rows = (baseCards.len + Columns - 1) div Columns
  sheetWidth = Margin * 2 + Columns * PreviewWidth + (Columns - 1) * ColumnGap
  sheetHeight = HeaderHeight + rows * PreviewHeight +
    (rows - 1) * RowGap + FooterHeight
  sheet = newImage(sheetWidth, sheetHeight)
sheet.fill(parseHtmlColor("#111a20"))
let
  title = readFont(root / "fonts/Grenze-SemiBold.ttf")
  subtitle = readFont(root / "fonts/Grenze-Regular.ttf")
title.size = 52
title.paint.color = parseHtmlColor("#ebd9b4")
subtitle.size = 25
subtitle.paint.color = parseHtmlColor("#b7b9b1")
sheet.fillText(title, "AWM / The complete base set",
  translate(vec2(Margin.float32, 22)))
sheet.fillText(subtitle, $baseCards.len &
  " illustrated cards · Archers · Warriors · Mages",
  translate(vec2(Margin.float32 + 1, 87)))

let divider = newPath()
divider.moveTo(Margin.float32, 133)
divider.lineTo((sheetWidth - Margin).float32, 133)
sheet.strokePath(divider, parseHtmlColor("#716347"), strokeWidth = 1)

for i, card in baseCards:
  let
    face = renderCardFace(card)
    x = Margin + (i mod Columns) * (PreviewWidth + ColumnGap)
    y = HeaderHeight + (i div Columns) * (PreviewHeight + RowGap)
  face.writeFile(outputDir / (card.artworkSlug() & ".png"))
  sheet.draw(face.resize(PreviewWidth, PreviewHeight),
    translate(vec2(x.float32, y.float32)))

renderCardBack().writeFile(outputDir / "back.png")
renderCardFace(Warrior.classCard(), currentToughness = 1).writeFile(outputDir / "bear-damaged.png")
subtitle.size = 20
subtitle.paint.color = parseHtmlColor("#8f978f")
sheet.fillText(subtitle,
  "Independent illustrations · Editable frames · Live rules and stats",
  translate(vec2(Margin.float32, (sheetHeight - 44).float32)))
sheet.writeFile(outputDir / "cards.png")
echo "Rendered ", baseCards.len, " illustrated card previews: ", outputDir
