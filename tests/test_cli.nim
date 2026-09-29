import
  std/os,
  polyworld/cli

proc parseCommon(
    arguments: seq[string],
    liveBotCount = 0,
    liveBotMessage = "",
    defaults = GameOptions(seed: 2026)
): GameOptions =
  ## Parses only shared flags, the same way a game loop would.
  result = defaults
  var index = 0
  while index < arguments.len:
    let argument = arguments[index]
    if not result.takeCommonFlag(arguments, index, argument):
      doAssert false, "unexpected argument: " & argument
    inc index
  result.validateGameOptions(liveBotCount, liveBotMessage)

echo "Testing independent pacing and barrier controls"
block:
  let defaults = parseCommon(@[])
  doAssert not defaults.waitForLlm
  doAssert defaults.headlessTickRate == 0
  for flags in [
    @["--headless-tick-rate:24", "--llm-mode:barrier"],
    @["--headless-tick-rate=24", "--llm-mode=barrier"],
    @["--headless-tick-rate", "24", "--llm-mode", "barrier"]
  ]:
    let options = parseCommon(flags)
    doAssert options.waitForLlm
    doAssert options.headlessTickRate == 24
  let disabled = parseCommon(@["--llm-mode:async"])
  doAssert not disabled.waitForLlm

echo "Testing bot path and count parsing"
block:
  var groups: seq[BotGroup]
  groups.addBotSpec("bots/base.bas")
  groups.addBotSpec("bots/other.bas:3")
  doAssert groups.len == 2
  doAssert groups[0].path == "bots/base.bas"
  doAssert groups[0].count == 1
  doAssert groups[1].path == "bots/other.bas"
  doAssert groups[1].count == 3
  doAssert groups.botCount == 4

echo "Testing that a trailing colon count does not eat Windows drives"
block:
  var groups: seq[BotGroup]
  groups.addBotSpec("C:\\bots\\base.bas")
  doAssert groups[0].path == "C:\\bots\\base.bas"
  doAssert groups[0].count == 1
  groups.addBotSpec("C:\\bots\\base.bas:2")
  doAssert groups[1].path == "C:\\bots\\base.bas"
  doAssert groups[1].count == 2

echo "Testing shared flags and defaults"
block:
  let options = parseCommon(
    @["--seed", "7", "--record", "out.replay"]
  )
  doAssert options.seed == 7
  doAssert options.recordPath == "out.replay"
  doAssert options.replayPath.len == 0
  doAssert options.botGroups.len == 0

echo "Testing --bot compact and split forms"
block:
  let options = parseCommon(
    @["--bot:one.bas:2", "--bot", "two.bas"],
    liveBotCount = 3,
    liveBotMessage = "need three bots"
  )
  doAssert options.botGroups.len == 2
  doAssert options.botGroups.botCount == 3
  doAssert options.botGroups[0].path == "one.bas"
  doAssert options.botGroups[1].path == "two.bas"

echo "Testing that unknown flags stay with the game"
block:
  var
    options = GameOptions(seed: 2026)
    index = 0
  doAssert not options.takeCommonFlag(@["--view"], index, "--view")
  doAssert not options.takeCommonFlag(@["--help"], index, "--help")
  doAssert not options.takeCommonFlag(@["--verbose"], index, "--verbose")

echo "Testing extra flags in the same loop as shared ones"
block:
  var
    options = GameOptions(seed: 2026, maximumTicks: 100)
    arguments = @["--seed", "9", "--verbose"]
    index = 0
    verbose = false
  while index < arguments.len:
    let argument = arguments[index]
    if options.takeCommonFlag(arguments, index, argument):
      discard
    else:
      case argument
      of "--verbose":
        verbose = true
      else:
        doAssert false, "unexpected argument: " & argument
    inc index
  doAssert options.seed == 9
  doAssert verbose

echo "Testing duration flags write maximumTicks"
block:
  var options = parseCommon(@["--minutes", "20"])
  doAssert options.maximumTicks == DefaultDurationTicks
  doAssert options.seconds == DefaultMinutes * 60
  options = parseCommon(@["--seconds", "60"])
  doAssert options.maximumTicks == 60 * SharedTickRate
  doAssert options.seconds == 60
  options = parseCommon(@["--ticks", "28800"])
  doAssert options.maximumTicks == 28800
  options = parseCommon(@["--minutes=5"])
  doAssert options.maximumTicks == 5 * 60 * SharedTickRate
  options = parseCommon(@["--seconds=90"])
  doAssert options.maximumTicks == 90 * SharedTickRate
  options = parseCommon(@["--ticks=480"])
  doAssert options.maximumTicks == 480

echo "Testing that a leading -- is ignored"
block:
  let options = parseCommon(
    @["--", "--bot:one.bas"],
    liveBotCount = 1,
    liveBotMessage = "need one bot"
  )
  doAssert options.botGroups[0].path == "one.bas"

echo "Testing bot source expansion"
block:
  let path = getTempDir() / "polyworld_cli_bot.bas"
  writeFile(path, "PRINT 1\n")
  var groups: seq[BotGroup]
  groups.addBotSpec(path & ":2")
  let sources = groups.botSources(2)
  doAssert sources[0] == "PRINT 1\n"
  doAssert sources[1] == "PRINT 1\n"
  removeFile(path)

echo "Testing --play=false starts the transport paused"
block:
  let paused = parseCommon(@["--play=false", "--bot:one.bas"])
  doAssert paused.pauseOnStart
  let playing = parseCommon(@["--play=true", "--bot:one.bas"])
  doAssert not playing.pauseOnStart

echo "Testing --speed is a shared flag"
block:
  let options = parseCommon(@["--speed", "4", "--bot:one.bas"])
  doAssert options.speed == 4
  let compact = parseCommon(@["--speed=16", "--bot:one.bas"])
  doAssert compact.speed == 16

echo "Testing --player occupies one slot"
block:
  let options = parseCommon(
    @["--player", "--bot:one.bas:9"],
    liveBotCount = 10,
    liveBotMessage = "need ten bots"
  )
  doAssert options.playerSlot == 1
  doAssert options.botGroups.botCount == 9

echo "Testing --player:N compact and equals forms"
block:
  let compact = parseCommon(
    @["--player:2", "--bot:one.bas:3"],
    liveBotCount = 4,
    liveBotMessage = "need four bots"
  )
  doAssert compact.playerSlot == 2
  let equals = parseCommon(
    @["--player=1", "--bot:one.bas"],
    liveBotCount = 2,
    liveBotMessage = "need two bots"
  )
  doAssert equals.playerSlot == 1

echo "Testing --vsync is on by default"
block:
  let options = parseCommon(@["--bot:one.bas"])
  doAssert options.vsync
  let off = parseCommon(@["--vsync:off", "--bot:one.bas"])
  doAssert not off.vsync
  let on = parseCommon(@["--vsync=on", "--bot:one.bas"])
  doAssert on.vsync
  let split = parseCommon(@["--vsync", "off", "--bot:one.bas"])
  doAssert not split.vsync

echo "Testing --windowSize is a shared flag"
block:
  let options = parseCommon(@["--windowSize:800x400", "--bot:one.bas"])
  doAssert options.windowWidth == 800
  doAssert options.windowHeight == 400
  let split = parseCommon(@["--windowSize", "1024x576", "--bot:one.bas"])
  doAssert split.windowWidth == 1024
  doAssert split.windowHeight == 576
  let equals = parseCommon(@["--windowSize=1280x720", "--bot:one.bas"])
  doAssert equals.windowWidth == 1280
  doAssert equals.windowHeight == 720

echo "Cli tests passed"
