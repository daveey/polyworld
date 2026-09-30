## Compares fresh-process recordings and verifies every replayed state hash.

import
  std/[os, osproc, tempfiles],
  polyworld/[cli, tapes]
import ../examples/gods_of_the_arena/bots as gotaBots
import ../examples/gods_of_the_arena/maps as gotaMaps
import ../examples/gods_of_the_arena/replays as gotaReplays
import ../examples/gods_of_the_arena/sim as gotaSim
import ../examples/call_to_adventure/bots as ctaBots
import ../examples/call_to_adventure/content as ctaContent
import ../examples/call_to_adventure/replays as ctaReplays
import ../examples/call_to_adventure/sim as ctaSim
import ../examples/light_vs_dark/bots as lvdBots
import ../examples/light_vs_dark/content as lvdContent
import ../examples/light_vs_dark/maps as lvdMaps
import ../examples/light_vs_dark/replays as lvdReplays
import ../examples/light_vs_dark/sim as lvdSim
import ../examples/heartleaf/bots as hlfBots
import ../examples/heartleaf/content as hlfContent
import ../examples/heartleaf/maps as hlfMaps
import ../examples/heartleaf/replays as hlfReplays
import ../examples/heartleaf/sim as hlfSim

const
  Root = currentSourcePath().parentDir.parentDir
  Seed = 2026'i32
  GotaTicks = 1200
  SmokeTicks = 48
  Games = ["gota", "cta", "lvd", "heartleaf"]

proc recordGota(): string =
  ## Records drafting and fifty seconds of battle with ten real BASIC bots.
  let game = gotaSim.newGame(
    gotaMaps.generateMap(Seed), 600, 10, false, gotaReplays.ReplayData()
  )
  gotaBots.loadBots(game, [BotGroup(
    path: Root / "examples/gods_of_the_arena/players/base.bas", count: 10
  )])
  game.recorder = gotaReplays.initReplayRecorder(
    gotaSim.currentSetup(game, GotaTicks)
  )
  for tick in 0 ..< GotaTicks + 1024:
    if gotaSim.battleTick(game.world) >= GotaTicks:
      break
    gotaSim.tickWorld(game, proc() =
      ## Issues commands through the ordinary BASIC host.
      gotaBots.runBotDecisions(game))
  doAssert gotaSim.battleTick(game.world) == GotaTicks
  for vm in game.heroVms:
    doAssert not vm.failed, vm.lastError
  doAssert game.recorder.data.actions.len > 0
  gotaReplays.encodeReplay(game.recorder.data)

proc recordCta(): string =
  ## Records a short live expedition through the normal hero decision slots.
  let game = ctaSim.newGame(Seed, SmokeTicks)
  ctaBots.loadBots(game, [BotGroup(
    path: Root / "examples/call_to_adventure/players/base.bas", count: 4
  )])
  game.recorder = ctaReplays.initReplayRecorder(game.world.setup)
  for tick in 0 ..< SmokeTicks:
    ctaSim.tickWorld(game, proc(game: ctaSim.Game, slot: int32) =
      ## Runs only heroes that can act on this decision tick.
      let actor = game.world.actors[slot]
      if ctaContent.alive(actor) and not ctaContent.busy(actor):
        ctaBots.runBotDecisions(game, slot))
    game.recorder.recordHash(ctaSim.stateHash(game))
  for vm in game.heroVms:
    doAssert not vm.failed, vm.lastError
  doAssert game.recorder.data.actions.len > 0
  ctaReplays.encodeReplay(game.recorder.data)

proc recordLvd(): string =
  ## Records two overlords for two seconds using the production world loop.
  let
    map = lvdMaps.generateMap(Seed)
    game = lvdSim.newGame(map, SmokeTicks)
    source = readFile(Root / "examples/light_vs_dark/players/base.bas")
  lvdBots.loadBots(game, [source, source])
  game.recorder = lvdReplays.initReplayRecorder(lvdReplays.Setup(
    mapSeed: Seed,
    tickRate: uint16(lvdContent.TickRate),
    gridTiles: uint16(map.side),
    decisionTicks: uint16(lvdContent.DecisionTicks),
    maximumTicks: SmokeTicks,
    mapHash: map.hash,
    contentHash: lvdContent.contentHash(),
    players: @[
      lvdReplays.ReplayPlayerSetup(
        id: 0, startX: int32(map.hallOrigin[0].x),
        startY: int32(map.hallOrigin[0].y)
      ),
      lvdReplays.ReplayPlayerSetup(
        id: 1, startX: int32(map.hallOrigin[1].x),
        startY: int32(map.hallOrigin[1].y)
      )
    ]
  ))
  for tick in 0 ..< SmokeTicks:
    lvdSim.tickWorld(game.world, proc(world: lvdSim.World) =
      ## Runs both overlords at the world's decision cadence.
      lvdBots.runBotDecisions(game))
    game.recorder.recordHash(lvdSim.stateHash(game))
  for vm in game.brains:
    doAssert not vm.failed, vm.lastError
  doAssert game.recorder.data.actions.len > 0
  lvdReplays.encodeReplay(game.recorder.data)

proc recordHeartleaf(): string =
  ## Records a short prefix while retaining the original day-based setup.
  let
    map = hlfMaps.generateMap(Seed)
    game = hlfSim.newGame(map, 1)
    source = readFile(Root / "examples/heartleaf/players/base.bas")
  var sources: array[hlfContent.VillagerCount, string]
  for entry in sources.mitems:
    entry = source
  hlfBots.loadBots(game, sources)
  game.recorder = hlfReplays.initReplayRecorder(hlfReplays.Setup(
    mapSeed: Seed,
    tickRate: uint16(hlfContent.TickRate),
    gridTiles: uint16(hlfContent.GridSide),
    decisionTicks: uint16(hlfContent.DecisionTicks),
    dayCount: 1,
    maximumTicks: uint32(hlfContent.gameLengthTicks(1)),
    mapHash: map.hash,
    contentHash: hlfContent.contentHash()
  ))
  for tick in 0 ..< SmokeTicks:
    hlfSim.tickWorld(game.world, proc(world: hlfSim.World) =
      ## Runs the villagers at the world's decision cadence.
      hlfBots.runBotDecisions(game))
    game.recorder.recordHash(hlfSim.stateHash(game))
  for vm in game.brains:
    doAssert not vm.failed, vm.lastError
  doAssert game.recorder.data.actions.len > 0
  hlfReplays.encodeReplay(game.recorder.data)

proc verifyGota(bytes: string) =
  ## Verifies the longer GOTA replay through its normal playback path.
  let
    data = gotaReplays.decodeReplay(bytes)
    game = gotaSim.newGame(
      gotaMaps.generateMap(data.config.seed, data.config.mapPreset),
      data.config.spawnIntervalTicks, 10, true, data
    )
  game.replayPlayer = gotaReplays.initReplayPlayer(data)
  game.historyPlayback = true
  for tick in 0 ..< data.hashes.len:
    gotaSim.tickWorld(game, nil)
  game.hashCheck.requireReplayComplete(uint32(game.world.tick), data.hashes.len)
  doAssert game.replayPlayer.finished
  doAssert gotaSim.battleTick(game.world) == GotaTicks
  echo "GOTA: two identical recordings, verified ", data.hashes.len, " ticks"

proc verifyCta(bytes: string) =
  ## Consumes hero commands at their original decision slots and checks hashes.
  let
    data = ctaReplays.decodeReplay(bytes)
    game = ctaSim.newGame(data.config.seed, data.config.maxTicks)
    player = ctaReplays.initReplayPlayer(data)
  doAssert data.hashes.len == SmokeTicks
  for expected in data.hashes:
    ctaSim.tickWorld(game, proc(game: ctaSim.Game, slot: int32) =
      ## Replays commands only when the corresponding hero can act.
      let actor = game.world.actors[slot]
      if not ctaContent.alive(actor) or ctaContent.busy(actor):
        return
      var action: ctaReplays.ReplayAction
      while player.takeActionAt(uint32(game.world.tick), actor.id, action):
        discard ctaSim.applyHeroAction(game, slot, action))
    doAssert ctaSim.stateHash(game) == expected, "CTA replay hash mismatch"
  doAssert player.finished
  echo "CTA: two identical recordings, verified ", data.hashes.len, " ticks"

proc verifyLvd(bytes: string) =
  ## Replays a short match and checks every world fingerprint.
  let
    data = lvdReplays.decodeReplay(bytes)
    game = lvdSim.newGame(lvdMaps.generateMap(data.config.seed), SmokeTicks)
    player = lvdReplays.initReplayPlayer(data)
  doAssert data.hashes.len == SmokeTicks
  for expected in data.hashes:
    lvdSim.tickWorld(game.world, proc(world: lvdSim.World) =
      ## Drains this decision tick's recorded overlord commands.
      var action: lvdReplays.ReplayAction
      while player.takeActionAt(uint32(world.tick), action):
        discard lvdSim.applyReplayAction(world, action))
    doAssert lvdSim.stateHash(game) == expected, "LVD replay hash mismatch"
  doAssert player.finished
  echo "LVD: two identical recordings, verified ", data.hashes.len, " ticks"

proc verifyHeartleaf(bytes: string) =
  ## Replays a short village prefix without simulating an entire week.
  let
    data = hlfReplays.decodeReplay(bytes)
    game = hlfSim.newGame(hlfMaps.generateMap(data.config.seed), 1)
    player = hlfReplays.initReplayPlayer(data)
  doAssert data.hashes.len == SmokeTicks
  for expected in data.hashes:
    hlfSim.tickWorld(game.world, proc(world: hlfSim.World) =
      ## Drains this decision tick's recorded villager commands.
      var action: hlfReplays.ReplayAction
      while player.takeActionAt(uint32(world.tick), action):
        hlfSim.applyReplayAction(world, action))
    doAssert hlfSim.stateHash(game) == expected, "Heartleaf replay hash mismatch"
  doAssert player.finished
  echo "Heartleaf: two identical recordings, verified ", data.hashes.len, " ticks"

proc checkDeterminism() =
  ## Uses the same compiled executable in two fresh recording processes.
  let directory = createTempDir("polyworld-determinism-", "")
  defer:
    removeDir(directory)
  for pass in ["first", "second"]:
    let path = directory / pass
    createDir(path)
    let (output, code) = execCmdEx(quoteShellCommand([
      getAppFilename(), "--record-determinism", path
    ]))
    doAssert code == 0, output
  for game in Games:
    let bytes = readFile(directory / "first" / (game & ".replay"))
    doAssert bytes == readFile(directory / "second" / (game & ".replay")),
      game & ": independent processes produced different recordings"
    case game
    of "gota": verifyGota(bytes)
    of "cta": verifyCta(bytes)
    of "lvd": verifyLvd(bytes)
    of "heartleaf": verifyHeartleaf(bytes)
    else: doAssert false

if paramCount() == 2 and paramStr(1) == "--record-determinism":
  let directory = paramStr(2)
  writeFile(directory / "gota.replay", recordGota())
  writeFile(directory / "cta.replay", recordCta())
  writeFile(directory / "lvd.replay", recordLvd())
  writeFile(directory / "heartleaf.replay", recordHeartleaf())
  quit(0)

checkDeterminism()
