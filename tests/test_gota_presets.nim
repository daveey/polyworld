import
  std/os,
  jsony,
  polyworld/tapes,
  ../examples/gods_of_the_arena/[maps, presets, replays, sim]

echo "Testing JSON match settings and saved map controls."
let
  saved = loadConfig(currentSourcePath().parentDir.parentDir /
    "examples/gods_of_the_arena/presets/saved.json")
  custom = parseConfig("""{
    "seed": 1988,
    "draft_mode": "team",
    "max_ticks": 100,
    "map_preset": {
      "seed": 55,
      "map_size": 128,
      "jungle_roads": 24,
      "camp_radius": 34,
      "camps_touch_roads": false
    }
  }""")
doAssert saved.mapPreset == defaultConfig()
doAssert saved.seed == 54
doAssert saved.draftMode == UniqueDraft
doAssert custom.draftMode == TeamDraft
for mode in DraftMode:
  doAssert parseDraftMode($mode) == mode
  let config = parseConfig("{\"draftMode\": \"" & $mode & "\"}")
  doAssert config.draftMode == mode
  doAssert parseConfig(config.toJson()) == config
doAssert saved.mapPreset.mapSize == 116
doAssert custom.seed == 1988
doAssert custom.maxTicks == 100
doAssert custom.mapPreset.seed == 55
doAssert custom.mapPreset.mapSize == 128
doAssert custom.mapPreset.jungleRoads == 24
doAssert custom.mapPreset.campRadius == 34
doAssert not custom.mapPreset.campsTouchRoads
doAssert custom.mapPreset.roadWidth == defaultConfig().roadWidth
doAssert parseConfig(custom.toJson()) == custom
for bytes in [
  "{\"draftMode\": \"invalid\"}",
  "{", "{\"mapPreset\": {\"mapSize\": 0}}",
  "{\"mapPreset\": {\"mapSize\": 97}}",
  "{\"mapPreset\": {\"mapSize\": 258}}",
  "{\"mapPreset\": {\"jungleRoads\": 999999}}",
  "{\"mapPreset\": {\"lakeCrossings\": 3}}",
  "{\"mapPreset\": {\"roadWidth\": -1}}"
]:
  try:
    discard parseConfig(bytes)
    doAssert false, "Invalid map controls must be rejected."
  except GotaConfigError:
    discard

echo "Testing replays restore a custom map independently of current defaults."
let
  defaultMap = generateMap(saved.seed, saved.mapPreset)
  customMap = generateMap(custom.seed, custom.mapPreset)
doAssert customMap.hash != defaultMap.hash
let game = newGame(
  customMap, 240, 10, false, ReplayData(),
  drafting = false, draftMode = custom.draftMode
)
game.world.heroTurnTicks = 100_000
game.recorder = initReplayRecorder(game.currentSetup(100), customMap.preset)
for tick in 0 ..< 100:
  game.tickWorld(nil)
let
  data = decodeReplay(game.recorder.data.encodeReplay())
  expected = game.stateHash()
doAssert data.config.mapPreset == custom.mapPreset
doAssert data.config.seed == custom.seed
doAssert data.config.draftMode == custom.draftMode
doAssert data.header.gameVersion == ReplayGameVersion
doAssert generateMap(saved.seed, saved.mapPreset).hash == defaultMap.hash,
  "The cache must not reuse a different preset."
let
  restored = generateMap(data.config.seed, data.config.mapPreset)
  replay = newGame(restored, 240, 10, true, data)
doAssert restored.hash == customMap.hash
replay.world.heroTurnTicks = 100_000
replay.historyPlayback = true
replay.replayPlayer = initReplayPlayer(data)
for tick in 0 ..< data.hashes.len:
  replay.tickWorld(nil)
doAssert replay.hashCheck.mismatches == 0, replay.hashCheck.error
doAssert replay.stateHash() == expected
var invalid = data
invalid.config.mapPreset.lakeWidth = 1000
try:
  discard invalid.encodeReplay()
  doAssert false, "Invalid replay map controls must be rejected."
except ReplayError:
  discard
discard generateMap(saved.seed, saved.mapPreset)
echo "test_gota_presets: all checks passed"
