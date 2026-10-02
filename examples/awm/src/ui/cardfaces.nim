## Composes card faces from independently editable illustration, frame, icon,
## and font assets. The rendered image is only a presentation cache: game data
## and the source artwork stay separate.

import std/[os, options, strutils, tables]
import pixie
import pixie/fileformats/svg
import ../core/core, ../paths

const
  CardFaceWidth* = 600
  CardFaceHeight* = 850
  ArtX = 27
  ArtY = 113
  ArtWidth = 546
  ArtHeight = 417
  # Minion stat number boxes in face pixels. Board minions draw their live
  # stats over the printed ones, so faces needn't be baked for every value.
  PowerBox* = Rect(x: 85, y: 757, w: 54, h: 61)
  ToughnessBox* = Rect(x: 503, y: 757, w: 54, h: 61)
  StatMargin* = 10'f32  ## Room around a stat box for glyph overhang.
  # The type line ("MINION"), restated over a live minion that lost keywords.
  TypeLine* = Rect(x: 109, y: 532, w: 382, h: 32)

type
  StatSlot* = enum
    PowerSlot
    ToughnessSlot

  StatInk* = enum
    ## A live stat compared with the printed one.
    PrintedStat
    LoweredStat
    RaisedStat

var
  statBackdrop: Image  ## A minion frame with stat icons and no numbers.
  assetsRoot: string
  assetImages: Table[string, Image]
  titleTypeface, rulesTypeface: Typeface

proc assetImage(relativePath: string, width = 0, height = 0): Image =
  let key = relativePath & ":" & $width & ":" & $height
  if key notin assetImages:
    assetImages[key] = if width > 0 and relativePath.endsWith(".svg"):
      newImage(parseSvg(readFile(assetsRoot / relativePath), width, height))
    else:
      readImage(assetsRoot / relativePath)
  assetImages[key]

proc initCardAssets*(root = artworkRoot() / "cards") =
  ## Load card components from the AWM data folder or an explicit directory.
  if root == assetsRoot and not titleTypeface.isNil:
    return
  assetsRoot = root
  assetImages.clear()
  titleTypeface = readFont(assetsRoot / "fonts/Grenze-SemiBold.ttf").typeface
  rulesTypeface = readFont(assetsRoot / "fonts/Grenze-Regular.ttf").typeface

proc ensureAssets() =
  if assetsRoot.len == 0:
    initCardAssets()

proc cardFont(size: float32, ink: string, semibold = false): Font =
  result = newFont(if semibold: titleTypeface else: rulesTypeface)
  result.size = size
  result.lineHeight = size * 1.08
  result.paint.color = parseHtmlColor(ink)

proc drawText(
    image: Image, value: string, x, y, width, height, size: float32,
    ink: string, semibold = false, alignment = CenterAlign,
    minimumSize = 28'f32, wrap = false
) =
  ## Fit long names and multi-line rule text to a fixed safe area. Actual ink
  ## bounds provide optical vertical centering independent of font ascenders.
  if value.len == 0:
    return
  var font = cardFont(size, ink, semibold)
  var arrangement: Arrangement
  while true:
    arrangement = font.typeset(value, vec2(width, 0), alignment, wrap = wrap)
    let bounds = arrangement.computeBounds()
    if (bounds.w <= width and bounds.h <= height) or font.size <= minimumSize:
      break
    font.size -= 1
    font.lineHeight = font.size * 1.08
  let bounds = arrangement.computeBounds()
  image.fillText(arrangement, translate(vec2(x, y + (height - bounds.h) / 2 - bounds.y)))

proc drawArt(image: Image, card: Card) =
  let
    relativePath = "art/" & card.name.toLowerAscii().replace(" ", "-") & ".png"
    source = if fileExists(assetsRoot / relativePath):
      assetImage(relativePath)
    else:
      assetImage("art/unknown.svg")
    scaleFactor = max(ArtWidth.float32 / source.width.float32,
      ArtHeight.float32 / source.height.float32)
    crop = newImage(ArtWidth, ArtHeight)
    x = (ArtWidth.float32 - source.width.float32 * scaleFactor) / 2
    y = (ArtHeight.float32 - source.height.float32 * scaleFactor) / 2
  crop.draw(source, translate(vec2(x, y)) * scale(vec2(scaleFactor)))
  image.draw(crop, translate(vec2(ArtX, ArtY)))

proc statInk*(value, printed: int): StatInk =
  if value < printed: LoweredStat
  elif value > printed: RaisedStat
  else: PrintedStat

proc color(ink: StatInk): string =
  case ink
  of PrintedStat: "#fff0c9"
  of LoweredStat: "#ff9d87"
  of RaisedStat: "#a8f08c"

proc drawStat(image: Image, value: int, ink: StatInk, box: Rect) =
  image.drawText($value, box.x, box.y, box.w, box.h, 68, ink.color, true)

proc box*(slot: StatSlot): Rect =
  case slot
  of PowerSlot: PowerBox
  of ToughnessSlot: ToughnessBox

proc renderStat*(value: int, ink: StatInk, slot: StatSlot): Image =
  ## One stat number in its box plus `StatMargin`, on an opaque patch of the
  ## minion frame: drawn over a printed face, it hides the printed number.
  ensureAssets()
  if statBackdrop.isNil:
    statBackdrop = newImage(CardFaceWidth, CardFaceHeight)
    statBackdrop.draw(assetImage("frames/creature.svg"))
    statBackdrop.draw(assetImage("icons/power.svg"), translate(vec2(29, 745)))
    statBackdrop.draw(assetImage("icons/toughness.svg"),
      translate(vec2(447, 745)))
  let box = slot.box()
  result = statBackdrop.subImage(int(box.x - StatMargin),
    int(box.y - StatMargin), int(box.w + StatMargin * 2),
    int(box.h + StatMargin * 2))
  result.drawStat(value, ink,
    Rect(x: StatMargin, y: StatMargin, w: box.w, h: box.h))

proc renderLostKeywords*(lost: set[Keyword]): Image =
  ## The minion type line with the keywords it lost ("MINION · LOST
  ## RANGED"), cut from the frame so it covers the printed line exactly.
  ensureAssets()
  result = assetImage("frames/creature.svg").subImage(int(TypeLine.x),
    int(TypeLine.y), int(TypeLine.w), int(TypeLine.h))
  var names: seq[string]
  for keyword in lost:
    names.add ($keyword).toUpperAscii()
  result.drawText("MINION · LOST " & names.join(", "), 0, 0, TypeLine.w,
    TypeLine.h, 31, LoweredStat.color, true, minimumSize = 18)

proc renderCardFace*(card: Card, currentPower = -1, currentToughness = -1,
    showStats = true): Image =
  ensureAssets()
  result = newImage(CardFaceWidth, CardFaceHeight)
  result.drawArt(card)
  result.draw(assetImage(if card.kind == Minion:
    "frames/creature.svg" else: "frames/spell.svg"))
  result.draw(assetImage("icons/energy.svg"), translate(vec2(26, 15)))
  result.drawText($card.energyCost, 40, 33, 92, 73, 75, "#fff4d5", true)
  result.drawText(card.name, 154, 40, 390, 58, 60, "#f7e6be", true,
    minimumSize = 35)
  result.drawText(($card.kind).toUpperAscii(),
    109, 532, 382, 32, 31, "#e1c792", true)

  let rules = card.ruleText()
  if rules.len > 0:
    result.drawText(rules, 65, 605, 470, 113, 43, "#26251e",
      minimumSize = 28, wrap = true)
  else:
    # Empty rules have no invented gameplay text.
    let flourish = newPath()
    flourish.moveTo(252, 659)
    flourish.lineTo(284, 659)
    flourish.moveTo(316, 659)
    flourish.lineTo(348, 659)
    result.strokePath(flourish, parseHtmlColor("#a39169"), strokeWidth = 1.5)
    let diamond = newPath()
    diamond.moveTo(300, 650)
    diamond.lineTo(305, 659)
    diamond.lineTo(300, 668)
    diamond.lineTo(295, 659)
    diamond.closePath()
    result.fillPath(diamond, parseHtmlColor("#a39169"))

  if card.kind == Minion:
    result.draw(assetImage("icons/power.svg"), translate(vec2(29, 745)))
    result.draw(assetImage("icons/toughness.svg"), translate(vec2(447, 745)))
    if showStats:
      let
        power = if currentPower >= 0: currentPower else: card.power
        toughness =
          if currentToughness >= 0: currentToughness else: card.toughness
      result.drawStat(power, statInk(power, card.power), PowerBox)
      result.drawStat(toughness, statInk(toughness, card.toughness),
        ToughnessBox)
    if card.class.isSome:
      result.drawText(card.class.get.className.toUpperAscii(),
        171, 762, 258, 24, 26, "#c1ab7e", true)
  else:
    result.draw(assetImage("icons/arcane.svg"),
      translate(vec2(285, 791)) * scale(vec2(0.375)))
    if card.class.isSome:
      result.drawText(card.class.get.className.toUpperAscii(),
        171, 762, 258, 24, 26, "#c1ab7e", true)

proc renderCardBack*(): Image =
  ensureAssets()
  result = newImage(CardFaceWidth, CardFaceHeight)
  result.draw(assetImage("frames/back.svg"))
  result.draw(assetImage("icons/arcane.svg", 282, 282),
    translate(vec2(159, 284)))
