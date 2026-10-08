## Crewrift executable using Polyworld graphics and original gameplay rules.

import game

when not defined(headless):
  import graphics

proc main() =
  ## Starts a local graphical match or a headless simulation.
  let options = parseOptions()
  when defined(headless):
    runHeadless(options)
  else:
    runGraphics(options)

main()
