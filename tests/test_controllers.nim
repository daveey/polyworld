import
  std/os,
  jsony,
  polyworld/[cli, controllers]

echo "Testing --player:2 marks the second slot"
block:
  let kinds = controllerKinds(4, 2)
  doAssert kinds.len == 4
  doAssert kinds[0] == BotController
  doAssert kinds[1] == PlayerController
  doAssert kinds[2] == BotController
  doAssert kinds[3] == BotController
  doAssert isPlayerIndex(2, 1)
  doAssert not isPlayerIndex(2, 0)
  doAssert not isPlayerIndex(0, 0)

echo "Testing bots expand around the human slot"
block:
  let
    path = getTempDir() / "polyworld_controller_bot.bas"
    kinds = controllerKinds(4, 2)
  writeFile(path, "PRINT 1\n")
  var groups: seq[BotGroup]
  groups.addBotSpec(path & ":3")
  let sources = groups.expandBotSources(kinds)
  doAssert sources.len == 4
  doAssert sources[0] == "PRINT 1\n"
  doAssert sources[1].len == 0
  doAssert sources[2] == "PRINT 1\n"
  doAssert sources[3] == "PRINT 1\n"
  removeFile(path)

echo "Testing local bot filenames supply names without loading their source"
block:
  var options = GameOptions(seed: 42, maximumTicks: 480, spawnIntervalTicks: 72)
  options.botGroups.addBotSpec("bots/dragon.bas:2")
  options.botGroups.addBotSpec("C:\\bots\\ice.dragon.BAS")
  options.botGroups.addBotSpec("bots/Dragonfly.bas.backup")
  let config = options.localGameConfig(4)
  doAssert config.seed == 42
  doAssert config.maxTicks == 480
  doAssert config.spawnIntervalTicks == 72
  doAssert config.players == @[
    PlayerConfig(name: "dragon"),
    PlayerConfig(name: "dragon"),
    PlayerConfig(name: "ice.dragon"),
    PlayerConfig(name: "Dragonfly.bas.backup")
  ]

echo "Testing names follow bot slots around a human controller"
block:
  var options = GameOptions(playerSlot: 2)
  options.botGroups.addBotSpec("bots/dragon.bas:2")
  options.botGroups.addBotSpec("bots/turtle.bas")
  let config = options.localGameConfig(4)
  doAssert config.playerSlot == 2
  doAssert config.players == @[
    PlayerConfig(name: "dragon"),
    PlayerConfig(name: "Player 2"),
    PlayerConfig(name: "dragon"),
    PlayerConfig(name: "turtle")
  ]

echo "Testing local names cannot be supplied through CLI options"
block:
  static:
    doAssert not compiles(GameOptions(playerNames: @["Override"]))
  for flag in ["--name", "--player-name", "--playerName", "--player-names"]:
    var
      options: GameOptions
      index = 0
    doAssert not options.takeCommonFlag(@[flag, "Override"], index, flag)

echo "Testing labels leave recorded player names unchanged"
block:
  let player = PlayerConfig(name: " Submitted.BAS ")
  doAssert player.displayName(0) == "Submitted"
  doAssert player.name == " Submitted.BAS "
  doAssert PlayerConfig(name: "雪.bas (2)").displayName(0) == "雪.bas (2)"
  doAssert PlayerConfig(name: "\t").displayName(1) == "Player 2"

echo "Testing the hosted game config preserves match settings and names"
block:
  let config = """{
    "players": [{"name": "Submitted.BAS"}, {"name": ""}],
    "seed": 13,
    "max_ticks": 480,
    "spawn_interval_ticks": 48,
    "tokens": ["private-token-0", "private-token-1"]
  }""".fromJson(GameConfig)
  doAssert config.seed == 13
  doAssert config.maxTicks == 480
  doAssert config.spawnIntervalTicks == 48
  doAssert config.players[0].name == "Submitted.BAS"
  doAssert config.players[0].displayName(0) == "Submitted"
  doAssert config.players[1].displayName(1) == "Player 2"

echo "Controller tests passed"

echo "Testing hosted and replay inference settings round trip"
block:
  let config = """{
    "headless_tick_rate": 12, "wait_for_llm": true
  }""".fromJson(GameConfig)
  doAssert config.waitForLlm
  doAssert config.headlessTickRate == 12
  let restored = config.toJson().fromJson(GameConfig)
  doAssert restored == config
  let defaults = "{}".fromJson(GameConfig)
  doAssert not defaults.waitForLlm
  doAssert defaults.headlessTickRate == 0
  let options = GameOptions(
    headlessTickRate: 12, waitForLlm: true
  )
  let local = options.localGameConfig(0)
  doAssert local.waitForLlm
  doAssert local.headlessTickRate == 12
