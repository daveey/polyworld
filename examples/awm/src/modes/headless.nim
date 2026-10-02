## Matches with no window: the headless recorder and checker, and the
## Coworld server, which plays the platform's staged BASIC players and
## publishes their results and replay like the other Polyworld games.
import std/[os, random, strutils]
import polyworld/cli
import ../core/[sim, sessions, bots, match, replays]

when defined(coworld):
  import jsony
  import polyworld/coworld

proc seatClasses*(names: openArray[string], seats: int,
    seed: int32): seq[HeroClass] =
  ## The named classes, one per seat, or seeded random ones without names.
  if names.len == 0:
    var rng = initRand(seed.int64)
    for _ in 0 ..< seats:
      result.add rng.rand(HeroClass)
  elif names.len != seats:
    raise newException(ValueError, "classes must name one class per player")
  else:
    for name in names:
      result.add parseHeroClass(name)

proc matchSetup*(classes: openArray[HeroClass], seed: int32,
    maxTicks: int32): Setup =
  result = Setup(seed: seed, maximumTicks: maxTicks.uint32)
  for heroClass in classes:
    result.classes.add heroClass.ord.uint8

proc checkReplay*(path: string) =
  ## Plays a replay back with no window and requires every hash to match.
  let data = loadReplay(path)
  var
    game = newGame(data.header.setup.heroClasses,
      data.header.setup.seed.int64)
    check: ReplayHashCheck
    tick = 0'u32
  for action in data.actions:
    if not game.applyAction(action):
      raise newException(ReplayError,
        "replay action at tick " & $action.tick & " was refused")
    discard game.takeVisualEvents()
    tick = action.tick
    data.hashes.checkReplayHash(tick, game.stateHash, check)
  check.requireReplayComplete(tick, data.hashes.len)
  echo "Replay verified: ", data.hashes.len, " ticks, ",
    data.header.setup.classes.len, " players."

proc runHeadless*() =
  ## `--bot PATH[:COUNT]` once per seat (2 to 7 seats), `--seed`,
  ## `--ticks`, `--classes archer,mage,...` and `--record PATH`; or
  ## `--replay PATH` to verify a recording.
  var
    options = GameOptions(seed: DefaultSessionSeed.int32,
      maximumTicks: DefaultDurationTicks)
    classNames: seq[string]
    arguments = commandLineParams()
    index = 0
  while index < arguments.len:
    let argument = arguments[index]
    if options.takeCommonFlag(arguments, index, argument):
      discard
    elif argument == "--classes":
      classNames = arguments.argumentValue(index, argument).split(',')
    elif argument.startsWith("--classes="):
      classNames = argument["--classes=".len .. ^1].split(',')
    else:
      fail("unknown argument: " & argument)
    inc index
  if options.replayPath.len > 0:
    options.validateGameOptions(0, "")
    checkReplay(options.replayPath)
    return
  let seats = options.botGroups.botCount
  if seats notin 2 .. MaxPlayers:
    fail("supply 2 to " & $MaxPlayers & " bots with --bot PATH[:COUNT]")
  var
    sources: seq[string]
    players: seq[PlayerConfig]
  for group in options.botGroups:
    for _ in 0 ..< group.count:
      sources.add readFile(group.path)
      players.add PlayerConfig(name: group.path.extractFilename)
  let
    classes = seatClasses(classNames, seats, options.seed)
    recorder = initReplayRecorder(
      matchSetup(classes, options.seed, options.maximumTicks),
      GameConfig(players: players, seed: options.seed,
        maxTicks: options.maximumTicks))
  var played = initBotMatch(classes, options.seed.int64, loadBots(sources),
    options.maximumTicks.uint32, recorder)
  played.scriptError = proc(player: int, message: string) =
    echo "player ", player, " BASIC error: ", message
  played.run()
  if options.recordPath.len > 0:
    saveReplay(options.recordPath, recorder.data)
  echo "Match ", played.outcomeLabel, " after ", played.tick, " ticks, ",
    played.game.turnNumber, " turns. Scores: ", played.scores

when defined(coworld):
  type CoworldClasses = object
    classes: seq[string]

  proc runCoworld*() =
    ## One Coworld episode: every staged player is a BASIC script.
    let
      options = coworldOptions(0)
      seats = coworld.config.players.len
    if seats notin 2 .. MaxPlayers:
      raise newException(CoworldError,
        "AWM plays 2 to " & $MaxPlayers & " players")
    let
      names =
        try:
          readLocal(getEnv("COGAME_CONFIG_URI")).fromJson(CoworldClasses).classes
        except JsonError as error:
          raise newException(CoworldError,
            "Invalid Coworld configuration: " & error.msg)
      classes =
        try: seatClasses(names, seats, options.seed)
        except ValueError as error:
          raise newException(CoworldError, error.msg)
    resetInboxes(seats)
    var vms: seq[BotVm]
    for slot, group in options.botGroups:
      let
        policy = loadPlayerPolicy(readPlayerSource(group.path), slot)
        program = compilePlayer(policy.source, botSchema(), botLimits(), slot)
      vms.add newBotVm(program, slot.int32, playerPrinter(slot))
    let recorder = initReplayRecorder(
      matchSetup(classes, options.seed, options.maximumTicks), coworld.config)
    var played = initBotMatch(classes, options.seed.int64, vms,
      options.maximumTicks.uint32, recorder)
    played.scriptError = proc(player: int, message: string) =
      # A runtime error disables that script; its seat passes every turn.
      vms[player].failed = true
      playerError(player, message)
    played.run()
    saveReplay(options.recordPath, recorder.data)
    finishCoworld(CoworldResults(
      scores: played.scores,
      ticks: played.tick.int32,
      seed: options.seed,
      outcome: played.outcomeLabel
    ))
