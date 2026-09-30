## Current-frame HUD rectangles, composed from fixed rows and columns.

import
  vmath,
  polyworld/[gameuis, stackpanels]

const
  PanelScore* = vec2(298, 156)
  PanelResources* = vec2(432, 56)
  PanelMinimap* = vec2(282, 320)
  PanelSelection* = vec2(364, 225)
  PanelBuild* = vec2(358, 226)

type
  MinimapPanels* = object
    map*, sun*, clock*: GameUiPanel
    views*: array[2, GameUiPanel]

  SelectionPanels* = object
    portrait*, hp*, name*, details*: GameUiPanel
    units*: array[9, GameUiPanel]

  BuildPanels* = object
    tabs*: array[3, GameUiPanel]
    contents*: GameUiPanel
    slots*: array[8, GameUiPanel]

proc resourcePanels*(panel: GameUiPanel): array[3, GameUiPanel] =
  ## Places three equal resource cells across the top ribbon.
  var row = panel.stack(LeftToRight, vec2(12, 14))
  for cell in result.mitems:
    cell = row.take(vec2(130, 28), 9)

proc minimapPanels*(panel: GameUiPanel): MinimapPanels =
  ## Stacks the map above the clock and previous/next view controls.
  var rows = panel.stack(TopToBottom, vec2(13, 12))
  result.map = rows.take(vec2(256), 6)
  var footer = rows.takeRow(32).stack(LeftToRight)
  result.sun = footer.take(vec2(32), 15)
  result.clock = footer.take(vec2(80, 32))
  var buttons = footer.takeRest().stack(RightToLeft)
  for i in countdown(result.views.high, 0):
    result.views[i] = buttons.take(vec2(32), 11)

proc selectionPanels*(panel: GameUiPanel): SelectionPanels =
  ## Separates the main selection column from the three-by-three unit grid.
  var columns = panel.stack(LeftToRight, vec2(14))
  var portrait = columns.takeColumn(136, 12).stack(TopToBottom)
  result.portrait = portrait.takeRow(136, 9)
  portrait.indent = 4
  result.hp = portrait.take(vec2(128, 23), 3)
  result.name = portrait.take(vec2(128, 22))
  result.details = columns.takeRest()
  stackGrid(result.details, vec2(56), 3, vec2(10, 8), result.units)

proc buildPanels*(panel: GameUiPanel): BuildPanels =
  ## Stacks command tabs over two rows of four build or train buttons.
  var rows = panel.stack(TopToBottom, vec2(20, 12))
  var tabs = rows.takeRow(28, 14).stack(LeftToRight)
  for tab in result.tabs.mitems:
    tab = tabs.take(vec2(102, 28), 4)
  result.contents = rows.takeRest()
  stackGrid(
    result.contents, vec2(72), 4, vec2(10), result.slots
  )
