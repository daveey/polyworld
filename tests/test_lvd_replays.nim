## Light vs Dark replay codec, playback cursor, validation, and the promise
## that a replay carries commands rather than bot implementations.

import
  std/[os, strutils],
  polyworld/tapes,
  ../examples/light_vs_dark/content,
  ../examples/light_vs_dark/replays

const
  FirstDecision = uint32(DecisionTicks)
  SecondDecision = FirstDecision * 2
  ThirdDecision = FirstDecision * 3
  FourthDecision = FirstDecision * 4
  MatchTicks = FirstDecision * 5

let setup = Setup(
  mapSeed: DefaultSeed,
  tickRate: uint16(TickRate),
  gridTiles: uint16(DefaultMapSize),
  decisionTicks: uint16(DecisionTicks),
  maximumTicks: MatchTicks,
  mapHash: 0x123456789ABCDEF0'u64,
  contentHash: contentHash(),
  players: @[
    ReplayPlayerSetup(id: 0, startX: 19, startY: 19),
    ReplayPlayerSetup(
      id: 1, startX: DefaultMapSize - 22, startY: DefaultMapSize - 22
    )
  ]
)

proc filled(recorder: ReplayRecorder) =
  ## Fills every configured tick with a distinct hash.
  for tick in 1'u32 .. MatchTicks:
    recorder.recordHash(uint64(tick) xor 0x9E3779B97F4A7C15'u64)

echo "Testing Flatty action replay round trip"
let recorder = initReplayRecorder(setup)
recorder.recordAction(
  FirstDecision, LightPlayer, ActionMove, FirstUnitId, 64, 42
)
recorder.recordAction(
  FirstDecision,
  LightPlayer,
  ActionBuild,
  FirstUnitId + 1,
  int32(FarmBuilding.ord),
  24,
  24
)
recorder.recordAction(
  FirstDecision,
  DarkPlayer,
  ActionHarvest,
  FirstUnitId + 5,
  10,
  0
)
recorder.recordAction(
  SecondDecision,
  DarkPlayer,
  ActionTrain,
  FirstBuildingId,
  int32(PeonUnit.ord)
)
recorder.recordAction(
  ThirdDecision,
  LightPlayer,
  ActionAttack,
  FirstUnitId,
  FirstUnitId + 5
)
recorder.recordAction(
  FourthDecision,
  LightPlayer,
  ActionSetRally,
  FirstBuildingId + 1,
  60,
  60
)
recorder.recordAction(MatchTicks, DarkPlayer, ActionCancel, FirstUnitId + 5)
recorder.filled()

let
  encoded = recorder.data.encodeReplay()
  decoded = decodeReplay(encoded)
  fileHeader = replayFileHeader(encoded)
doAssert encoded.startsWith(ReplayMagic)
doAssert fileHeader.formatVersion == ReplayFileVersion
doAssert fileHeader.game == ReplayGame
doAssert fileHeader.gameVersion == ReplayGameVersion
doAssert decoded.header.formatVersion == ReplayFormatVersion
doAssert decoded.header.setup.mapSeed == DefaultSeed
doAssert decoded.header.setup.contentHash == contentHash()
doAssert decoded.actions.len == 7
doAssert decoded.actions[0].kind == ActionMove
doAssert decoded.actions[0].first == 64 and decoded.actions[0].second == 42
doAssert decoded.actions[1].kind == ActionBuild
doAssert decoded.actions[1].third == 24
doAssert decoded.hashes == recorder.data.hashes
doAssert decoded.hashes.len == int(decoded.header.setup.maximumTicks)

echo "Testing allocation-free exact-tick playback"
let player = initReplayPlayer(decoded)
var action: ReplayAction
doAssert not player.takeActionAt(0, action)
doAssert not player.takeActionAt(FirstDecision - 1, action)
doAssert player.takeActionAt(FirstDecision, action)
doAssert action.entityId == FirstUnitId and action.playerId == LightPlayer
doAssert player.takeActionAt(FirstDecision, action)
doAssert action.kind == ActionBuild
doAssert player.takeActionAt(FirstDecision, action)
doAssert action.playerId == DarkPlayer
doAssert not player.takeActionAt(FirstDecision, action)
doAssert player.takeActionAt(SecondDecision, action)
doAssert player.takeActionAt(ThirdDecision, action)
doAssert player.takeActionAt(FourthDecision, action)
doAssert not player.finished
doAssert player.takeActionAt(MatchTicks, action)
doAssert player.finished

echo "Testing that skipping a recorded tick is loud"
let strict = initReplayPlayer(decoded)
doAssert strict.takeActionAt(FirstDecision, action)
try:
  discard strict.takeActionAt(SecondDecision, action)
  doAssert false, "skipping past unconsumed actions should fail"
except ReplayError:
  discard

echo "Testing per-tick hash lookup"
let hashes = initReplayPlayer(decoded)
var hash: uint64
doAssert not hashes.hashAt(0, hash)
doAssert hashes.hashAt(1, hash) and hash == decoded.hashes[0]
doAssert hashes.hashAt(MatchTicks, hash) and hash == decoded.hashes[^1]
doAssert not hashes.hashAt(MatchTicks + 1, hash)

echo "Testing replay file I/O and privacy shape"
createDir("tmp")
let path = "tmp" / ("polyworld-lvd-" & $getCurrentProcessId() & ".replay")
saveReplay(path, recorder.data)
let loaded = loadReplay(path)
doAssert loaded.actions == decoded.actions
doAssert loaded.hashes == decoded.hashes
let replayBytes = readFile(path)
for marker in [
  "Light vs Dark", "overlord", "nearestEnemy", "wend", "dim ", "harvest("
]:
  doAssert replayBytes.find(marker) < 0,
    "the replay leaked bot source text: " & marker
let botPath = currentSourcePath().parentDir.parentDir /
  "examples/light_vs_dark/players/base.bas"
if fileExists(botPath):
  for line in readFile(botPath).splitLines():
    let trimmed = line.strip()
    if trimmed.len >= 12:
      doAssert replayBytes.find(trimmed) < 0,
        "the replay leaked a line of base.bas: " & trimmed
removeFile(path)

echo "Testing replay validation"

proc rejects(data: ReplayData, why: string) =
  ## Asserts that encoding a malformed replay fails rather than succeeding.
  try:
    discard data.encodeReplay()
    doAssert false, why & " should fail"
  except ReplayError:
    discard

var invalid = decoded
invalid.header.gameVersion = high(uint16)
invalid.rejects("an unsupported game version")

for version in 12'u16 ..< ReplayGameVersion:
  invalid = decoded
  invalid.header.gameVersion = version
  invalid.rejects("a replay using an outdated gameplay version")
  let old = encodeReplayFile(ReplayGame, version, invalid, MaxReplayBytes)
  try:
    discard decodeReplay(old)
    doAssert false, "old simulation versions must fail before playback"
  except ReplayError as error:
    doAssert error.msg.contains("version " & $version)
    doAssert error.msg.contains("expected " & $ReplayGameVersion)

invalid = decoded
invalid.header.setup.contentHash = 0
invalid.rejects("a missing content fingerprint")

invalid = decoded
invalid.header.setup.mapHash = 0
invalid.rejects("a missing map fingerprint")

invalid = decoded
invalid.header.setup.decisionTicks = 7
invalid.rejects("a mismatched decision interval")

invalid = decoded
invalid.header.setup.players[1] = invalid.header.setup.players[0]
invalid.rejects("both players starting on one tile")

invalid = decoded
invalid.header.setup.players[0].id = 1
invalid.rejects("players out of canonical order")

invalid = decoded
invalid.hashes.setLen(invalid.hashes.len - 1)
invalid.rejects("an action after the last recorded tick")

invalid = decoded
invalid.actions[0].tick = 13
invalid.rejects("a command off the decision grid")

invalid = decoded
invalid.actions[0].tick = MatchTicks + 12
invalid.rejects("a command past the configured duration")

invalid = decoded
invalid.actions[0].kind = ActionKindHigh + 1
invalid.rejects("an unknown command kind")

invalid = decoded
invalid.actions[0].playerId = int32(DefaultPlayerCount)
invalid.rejects("an unknown player")

invalid = decoded
invalid.actions[0].first = DefaultMapSize
invalid.rejects("a move off the map")

invalid = decoded
invalid.actions[0].entityId = FirstBuildingId
invalid.rejects("a move naming a structure instead of a unit")

invalid = decoded
invalid.actions[1].first = int32(BuildableHigh.ord) + 1
invalid.rejects("building an unbuildable structure")

invalid = decoded
invalid.actions[2].first = FirstUnitId
invalid.rejects("harvesting something that is not a gold mine")

invalid = decoded
invalid.actions[2].second = 2
invalid.rejects("an invalid harvest resource flag")

invalid = decoded
invalid.actions[3].entityId = FirstUnitId
invalid.rejects("training from a unit instead of a structure")

invalid = decoded
invalid.actions[3].first = int32(UnitKind.high.ord) + 1
invalid.rejects("training an unknown unit")

invalid = decoded
invalid.actions[6].entityId = 10
invalid.rejects("cancelling a neutral gold mine")

echo "Testing recorder ordering and limits"
let ordered = initReplayRecorder(setup)
ordered.recordAction(24, LightPlayer, ActionMove, FirstUnitId, 1, 1)
try:
  ordered.recordAction(12, LightPlayer, ActionMove, FirstUnitId, 1, 1)
  doAssert false, "recording backward in time should fail"
except ReplayError:
  discard

let overfilled = initReplayRecorder(setup)
overfilled.filled()
try:
  overfilled.recordHash(0)
  doAssert false, "recording more hashes than ticks should fail"
except ReplayError:
  discard

try:
  discard decodeReplay("NOT-A-LIGHT-VS-DARK-REPLAY")
  doAssert false, "invalid magic should fail"
except ReplayError:
  discard

echo "test_lvd_replays: all checks passed"
