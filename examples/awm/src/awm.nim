## Archers Warriors Mages — Polyworld native and browser client.
## Reads the command line and starts a game mode.
import core/sim
export sim

when not defined(headless):
  import std/os
  import core/[sessions, replays], app, replayer, scene/post, modes/duel,
    modes/multiplayer

  static:
    # Lists the compile-time (-d:) flags while this build compiles.
    proc onOff(on: bool): string = (if on: "ON" else: "OFF")
    const Rule = "-------------------------"
    echo Rule
    echo "Flags"
    echo Rule
    echo " awmPostPanel = ", onOff(PostPanelControls)
    echo " awmPostLayers = ", onOff(PostLayerControls)
    echo " awmLayoutTuning = ", onOff(defined(awmLayoutTuning))
    echo " takeScreenshot = ", onOff(defined(takeScreenshot))
    echo Rule

  proc printHelp() =
    echo "AWM — Archers Warriors Mages\n" &
      "Options (--key value or --key=value):\n" &
      "  --players N      Player count (2). 2 plays a duel; 3 to 7 play a\n" &
      "                   multiplayer match: the last player alive wins.\n" &
      "  --seed INTEGER   Match seed (random when omitted)\n" &
      "  --class CLASS    Your hero class: archer, warrior or mage (archer).\n" &
      "                   Duel only: in multiplayer you pick it on screen.\n" &
      "  --opponent CLASS Opponent hero class: archer, warrior or mage (mage).\n" &
      "                   Duel only: multiplayer opponents get random classes.\n" &
      "  --bot PATH       Bot program (.bas), repeatable up to " & $PlayerCount &
        " times.\n" &
      "                   Duel: one bot plays both seats; with --human it\n" &
      "                   plays the opponent. Multiplayer: the bots take\n" &
      "                   every seat but yours, in turn.\n" &
      "                   Defaults to players/base.bas.\n" &
      "  --human          Play seat 0 yourself instead of watching bots\n" &
      "  --replay PATH    Watch a recorded match (see --record in the\n" &
      "                   headless build)\n" &
      "  -h, --help       Show this help and exit"

  proc runAwm*() =
    if "--help" in commandLineParams() or "-h" in commandLineParams():
      printHelp()
      return
    var options = parseSessionOptions(commandLineParams())
    var replay: Replayer
    if options.replayPath.len > 0:
      # Before initApp, which moves to the Polyworld folder.
      replay = newReplayer(loadReplay(options.replayPath))
      options.playerCount = replay.classes.len
      options.human = false
    let app = initApp(options)
    app.replay = replay
    if app.options.playerCount > PlayerCount:
      app.runMultiplayer()
    else:
      app.runDuel()

  when isMainModule:
    runAwm()

when defined(headless):
  import modes/headless
  when isMainModule:
    when defined(coworld):
      runCoworld()
    else:
      runHeadless()
