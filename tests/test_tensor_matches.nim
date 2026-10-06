import
  std/os,
  polyworld/[cli, tapes],
  ../examples/gods_of_the_arena/[bots, maps, replays, sim]

const
  Examples = currentSourcePath().parentDir.parentDir /
    "examples/gods_of_the_arena/neural/examples"
  MatchTicks = 240

proc record(path: string): ReplayData =
  ## Records ten isolated policy VMs through the production decision pipeline.
  let game = newGame(generateMap(2026), 600, 10, false, ReplayData(),
    drafting = false)
  game.loadBots([BotGroup(path: path, count: 10)])
  game.recorder = initReplayRecorder(game.currentSetup(MatchTicks))
  for _ in 0 ..< MatchTicks:
    game.tickWorld(proc() =
      ## Issues ordinary commands without replacing simulation behavior.
      game.runBotDecisions()
    )
  for vm in game.heroVms:
    doAssert not vm.failed, vm.lastError
  result = decodeReplay(encodeReplay(game.recorder.data))
  doAssert result.actions.len > 0 and result.hashes.len == MatchTicks

proc verify(data: ReplayData) =
  ## Replays recorded commands and requires every simulation hash to match.
  let game = newGame(
    generateMap(data.config.seed, data.config.mapPreset),
    data.config.spawnIntervalTicks, 10, true, data
  )
  game.replayPlayer = initReplayPlayer(data)
  game.historyPlayback = true
  for _ in 0 ..< data.hashes.len:
    game.tickWorld(nil)
  game.hashCheck.requireReplayComplete(uint32(game.world.tick), data.hashes.len)
  doAssert game.replayPlayer.finished

for author in ["richard", "david", "andre", "fly"]:
  let
    native = record(Examples / ("synthetic-" & author & ".zip"))
    generic = record(Examples / ("tensor-" & author & ".zip"))
  doAssert native.actions == generic.actions
  doAssert native.hashes == generic.hashes
  verify(generic)
  echo author, ": ten-player tensor match actions and hashes match"
