## Light vs Dark action-only replay format and playback cursor.
##
## A replay contains the match config, accepted commands, and one canonical
## simulation hash per tick. It never stores bot source or private logs.

import
  std/os,
  fixxy,
  polyworld/[bodies, tapes, metrics],
  content, maps, diplomacies

export fixxy

const
  ReplayGame* = "light_vs_dark"
  ReplayFormatVersion* = 5'u16
  ## This client supports only this gameplay version. Bump it when rules change.
  ## Older replays use their archived client; never add compatibility branches.
  ReplayGameVersion* = 23'u16

  ActionMove* = 1'u8
  ActionAttack* = 2'u8
  ActionHarvest* = 3'u8
  ActionBuild* = 4'u8
  ActionTrain* = 5'u8
  ActionSetRally* = 6'u8
  ActionCancel* = 7'u8
  ActionAttackMove* = 8'u8
  ActionDiplomacy* = 9'u8
  ActionKindHigh* = ActionDiplomacy

  MaxReplayBytes* = 64 * 1024 * 1024
  MaxReplayActions* = 4_000_000
  MaxReplayHashes* = 10_000_000
  MaxMatchTicks* = uint32(TickRate) * 60 * 60
    ## One hour, an absolute ceiling well above any configured match.

type
  ReplayPlayerSetup* = object
    id*: int32
      ## Zero-based player slot, independent of its faction.
    startX*, startY*: int32
      ## North-west corner tile of the opening town hall.

  Setup* = object
    mapSeed*: int32
    tickRate*: uint16
    gridTiles*: uint16
    decisionTicks*: uint16
    maximumTicks*: uint32
    mapHash*: uint64
      ## Fingerprint of the generated terrain, checked against a fresh
      ## generation at load so a generator change fails by name.
    contentHash*: uint64
      ## Fingerprint of every tuning table, checked the same way.
    players*: seq[ReplayPlayerSetup]
    mapSettings*: MapSettings
    diplomacySettings*: DiplomacySettings

  ReplayAction* = object
    tick*: uint32
    playerId*: int32
    kind*: uint8
    offset*: FixedVec2
      ## Movement and ground aim offsets from the named tile center.
    entityId*: int32
      ## The owned acting entity, or zero for diplomacy commands.
    first*, second*, third*: int32
      ## Payload interpreted per kind:
      ##   Move      x, y, unused
      ##   Attack    target id, unused, unused
      ##   Harvest   mine id or tile index, tree flag, unused
      ##   Build     building kind, x, y
      ##   Train     unit kind, unused, unused
      ##   SetRally  x, y, unused
      ##   Cancel    unused, unused, unused
      ##   Diplomacy target player, command kind, offer ID

  ReplayHeader* = TapeHeader[Setup]
  ReplayData* = ActionTape[Setup, ReplayAction, ReplayMetrics]
  ReplayRecorder* = TapeRecorder[Setup, ReplayAction, ReplayMetrics]
  ReplayPlayer* = TapePlayer[Setup, ReplayAction, ReplayMetrics]

proc fail(message: string) {.noreturn.} =
  ## Raises one Light vs Dark replay error.
  raise newException(ReplayError, message)

proc initReplayData*(setup: Setup): ReplayData =
  ## Creates a replay containing the match setup, config, and action tape.
  result.header = initActionTape[Setup, ReplayAction](
    setup,
    ReplayFormatVersion,
    ReplayGameVersion
  ).header
  result.config = GameConfig(
    seed: setup.mapSeed,
    maxTicks: int32(setup.maximumTicks),
    players: unnamedPlayers(setup.players.len)
  )

proc initReplayRecorder*(setup: Setup): ReplayRecorder =
  ## Creates an in-memory recorder owning the complete replay data.
  ReplayRecorder(data: initReplayData(setup))

proc record*(recorder: ReplayRecorder, action: ReplayAction) =
  ## Appends one accepted command in deterministic tick order.
  if recorder == nil:
    return
  if not action.offset.validTileOffset:
    fail("replay point offset is outside its tile")
  if action.kind == 0 or action.kind > ActionKindHigh:
    fail("replay action kind is invalid")
  if action.playerId < 0 or
    int(action.playerId) >= recorder.data.header.setup.players.len:
      fail("replay action names an unknown player")
  recorder.data.actions.appendAction(action, MaxReplayActions)

proc recordAction*(
    recorder: ReplayRecorder,
    tick: uint32,
    playerId: int32,
    kind: uint8,
    entityId: int32,
    first = 0'i32,
    second = 0'i32,
    third = 0'i32,
    offset = FixedVec2Zero
) =
  ## Records one accepted command without any bot implementation detail.
  recorder.record ReplayAction(
    tick: tick,
    playerId: playerId,
    kind: kind,
    entityId: entityId,
    first: first,
    second: second,
    third: third,
    offset: offset
  )

proc recordHash*(recorder: ReplayRecorder, hash: uint64) =
  ## Appends the canonical simulation hash for one completed tick.
  recordHash(recorder, hash, MaxReplayHashes)

proc validateSetup(setup: Setup) =
  ## Validates the immutable match description.
  if setup.tickRate != uint16(TickRate):
    fail("replay setup has an unsupported tick rate")
  if setup.gridTiles < 32 or int32(setup.gridTiles) > MaximumMapSide:
    fail("replay setup has an unsupported map size")
  if setup.decisionTicks != uint16(DecisionTicks):
    fail("replay setup has an unsupported decision interval")
  if setup.maximumTicks == 0:
    fail("replay setup has an invalid duration")
  if setup.maximumTicks > MaxMatchTicks:
    fail("replay setup duration exceeds the match limit")
  if setup.maximumTicks > uint32(MaxReplayHashes):
    fail("replay setup duration exceeds the hash limit")
  if setup.mapHash == 0:
    fail("replay setup has no deterministic map fingerprint")
  if setup.contentHash == 0:
    fail("replay setup has no deterministic content fingerprint")
  try:
    setup.mapSettings.validate(setup.players.len)
    setup.diplomacySettings.validate()
  except LvdError as error:
    fail(error.msg)
  for index, player in setup.players:
    if int(player.id) != index:
      fail("replay setup players are out of canonical order")
    if player.startX < 0 or player.startY < 0 or
      player.startX >= int32(setup.gridTiles) or
      player.startY >= int32(setup.gridTiles):
        fail("replay setup places a player outside the map")
    for other in 0 ..< index:
      if player.startX == setup.players[other].startX and
        player.startY == setup.players[other].startY:
          fail("replay setup starts multiple players on one tile")

proc validateAction(action: ReplayAction, setup: Setup) =
  ## Validates one command's kind, ownership range, and payload bounds.
  if not action.offset.validTileOffset:
    fail("replay point offset is outside its tile")
  if action.kind == 0 or action.kind > ActionKindHigh:
    fail("replay action kind is invalid")
  if action.playerId < 0 or int(action.playerId) >= setup.players.len:
    fail("replay action names an unknown player")
  if action.tick > setup.maximumTicks:
    fail("replay action exceeds the configured duration")
  if action.tick == 0 or action.tick mod uint32(setup.decisionTicks) != 0:
    fail("replay action did not land on a decision tick")

  proc requireTile(x, y: int32) =
    ## Rejects coordinates outside this replay's actual map.
    if x < 0 or x >= int32(setup.gridTiles) or
      y < 0 or y >= int32(setup.gridTiles):
        fail("replay action names a tile outside the map")

  case action.kind
  of ActionDiplomacy:
    if action.entityId != NoEntity or action.offset != FixedVec2Zero or
      action.first < 0 or action.first >= int32(setup.players.len) or
      action.first == action.playerId or
      action.second notin 0'i32 .. int32(DiplomacyCommand.high.ord) or
      action.third < 0:
        fail("replay diplomacy command is invalid")
  of ActionMove, ActionAttackMove:
    if not action.entityId.isUnitId:
      fail("replay move does not name a unit")
    requireTile(action.first, action.second)
  of ActionAttack:
    if not action.entityId.isUnitId:
      fail("replay attack does not name a unit")
    if not (action.first.isUnitId or action.first.isBuildingId):
      fail("replay attack does not name an entity")
  of ActionHarvest:
    if not action.entityId.isUnitId:
      fail("replay harvest does not name a unit")
    if action.second == 0:
      if not action.first.isMineId:
        fail("replay harvest does not name a gold mine")
    elif action.second == 1:
      let cells = int32(setup.gridTiles) * int32(setup.gridTiles)
      if action.first < 0 or action.first >= cells:
        fail("replay harvest names a tile outside the map")
    else:
      fail("replay harvest has an invalid resource flag")
  of ActionBuild:
    if not action.entityId.isUnitId:
      fail("replay build does not name a peon")
    if action.first < 0 or action.first > int32(BuildableHigh.ord):
      fail("replay build names an unbuildable structure")
    requireTile(action.second, action.third)
  of ActionTrain:
    if not action.entityId.isPlayerBuildingId:
      fail("replay train does not name a structure")
    if action.first < 0 or action.first > int32(UnitKind.high.ord):
      fail("replay train names an unknown unit")
  of ActionSetRally:
    if not action.entityId.isPlayerBuildingId:
      fail("replay rally does not name a structure")
    requireTile(action.first, action.second)
  of ActionCancel:
    if not (action.entityId.isUnitId or action.entityId.isPlayerBuildingId):
      fail("replay cancel does not name an owned entity")
  else:
    fail("replay action kind is invalid")

proc validate*(data: ReplayData) =
  ## Validates versions, setup bounds, command payloads, and hash coverage.
  data.config.validateConfig(data.header.setup.players.len)
  if data.config.seed != data.header.setup.mapSeed or
    data.config.maxTicks != int32(data.header.setup.maximumTicks):
      fail("replay configuration does not match its simulation setup")
  data.header.requireTapeVersion(
    ReplayFormatVersion,
    ReplayGameVersion
  )
  let setup = data.header.setup
  setup.validateSetup()
  if data.actions.len > MaxReplayActions:
    fail("replay action limit exceeded")
  if data.hashes.len > MaxReplayHashes:
    fail("replay hash limit exceeded")
  if data.hashes.len > int(setup.maximumTicks):
    fail("replay hashes exceed the configured duration")
  var lastTick = 0'u32
  for index, action in data.actions:
    if action.tick > uint32(data.hashes.len):
      fail("replay action exceeds the recorded duration")
    if index > 0 and action.tick < lastTick:
      fail("replay actions move backward in time")
    action.validateAction(setup)
    lastTick = action.tick
  try:
    data.metrics.validate(
      data.config.players.len,
      int32(data.header.setup.tickRate),
      data.hashes.len
    )
  except MetricsError as error:
    fail(error.msg)

proc encodeReplay*(data: ReplayData): string =
  ## Encodes the action tape and its CPU telemetry in one payload.
  data.validate()
  encodeReplayFile(ReplayGame, ReplayGameVersion, data, MaxReplayBytes)

proc decodeReplay*(bytes: string): ReplayData =
  ## Returns the complete replay, including its original CPU telemetry.
  result = decodeReplayFile(
    ReplayGame,
    ReplayGameVersion,
    bytes,
    ReplayData,
    MaxReplayBytes
  )
  result.validate()

proc saveReplay*(path: string, data: ReplayData) =
  ## Creates the parent directory and saves the complete recording.
  if path.len == 0:
    fail("replay output path is empty")
  let bytes = encodeReplay(data)
  try:
    let directory = path.parentDir
    if directory.len > 0:
      createDir(directory)
    writeFile(path, bytes)
  except IOError, OSError:
    fail("cannot save replay: " & getCurrentExceptionMsg())

proc loadReplay*(path: string): ReplayData =
  ## Loads one recording with its complete match configuration and metrics.
  try:
    result = decodeReplay(readFile(path))
  except IOError, OSError:
    fail("cannot load replay: " & getCurrentExceptionMsg())

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  ## Creates a playback cursor over validated command data.
  data.validate()
  initTapePlayer(data)
