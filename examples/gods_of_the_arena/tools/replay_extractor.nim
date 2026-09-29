## Pass a generated replay path and edit the loops below to explore a match.

import
  std/os,
  polyworld/tapes,
  ../[maps, replays, sim]

if paramCount() notin 1 .. 2 or
  (paramCount() == 2 and paramStr(2) != "--quiet"):
    quit("Usage: replay_extractor path.replay [--quiet]", 1)

let
  quiet = paramCount() == 2
  replay = loadReplay(paramStr(1))
  game = newGame(
    generateMap(replay.config.seed, replay.config.mapPreset),
    replay.config.spawnIntervalTicks,
    0,
    true,
    replay
  )

game.replayPlayer = initReplayPlayer(replay)
game.historyPlayback = true

if not quiet:
  echo "Config: ", replay.config
for tick in 0 .. replay.hashes.len:
  if tick > 0:
    game.tickWorld(nil)
    game.hashCheck.requireReplayComplete(uint32(game.world.tick), tick)

  if not quiet:
    echo "Tick: ", game.world.tick
    for god in game.world.forts:
      echo "God: ", god
    for building in game.world.buildings:
      echo "Building: ", building
    for hero in game.world.heroes:
      echo "Hero: ", hero[]
    for creep in game.world.footmen:
      echo "Creep: ", creep
    for spell in game.world.casts:
      echo "Spell: ", spell
    for index, event in game.world.events:
      echo "Event ", index, ": ", event

if not game.replayPlayer.finished:
  raise newException(ReplayError, "Replay has unconsumed actions")

if quiet:
  echo "Verified ", replay.hashes.len, " ticks and ", replay.actions.len,
    " actions"
