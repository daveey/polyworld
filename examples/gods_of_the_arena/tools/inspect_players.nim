import std/[json, os]
import herostats, tournaments

proc main() =
  ## Extracts verified player counters using the replay's matching game build.
  require(paramCount() == 3,
    "Usage: inspect_players REPLAY METADATA OUTPUT_JSON")
  let stats = inspectReplay(paramStr(1), readStats(paramStr(2)))
  for hero in stats["heroes"]:
    require(hero.hasKey("tower_kills") and hero.hasKey("last_hits"),
      "The inspector must be compiled with replayEvents")
  saveJson(paramStr(3), stats)

try:
  main()
except CatchableError as error:
  stderr.writeLine("Player statistics error: " & error.msg)
  quit(1)
