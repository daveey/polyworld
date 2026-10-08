## Crewrift geometry, original rules, local policies, and replay checks.

import
  std/[os, strutils],
  jsony, vmath,
  polyworld/pathing,
  ../examples/crewrift/[bots, game, maps, replays, sim]

const AuditJson = staticRead("../examples/crewrift/data/map1-audit.json")

type
  AuditTile = object
    x, y: int
    status: string
    blockers: seq[string]
  AuditLink = object
    start, `end`: array[2, int]
  TileAudit = object
    candidateTiles: int
    tiles: seq[AuditTile]
    blockedLinks: seq[AuditLink]

proc testOptions(seed = 2026): Options =
  ## Builds a deterministic eight-player local match for rule checks.
  Options(seed: seed, players: 8, ticks: 10000, player: -1, speed: 1)

proc enterPlaying(game: Game) =
  ## Completes the original role reveal without advancing bot decisions.
  for i in 0 ..< RoleRevealTicks:
    game.world.step([], [])
  doAssert game.world.phase == Playing

echo "Testing authored floor, markers, and Polyworld navigation"
block:
  let game = newGame(testOptions())
  doAssert game.world.rooms.len == 13
  doAssert game.world.gameMap.path == "map1"
  doAssert game.world.tasks.len == 51
  doAssert game.world.vents.len == 11
  doAssert game.world.rooms[0].name == "Bridge"
  doAssert PixelsPerTile == 8
  doAssert MapColumns == 155 and MapRows == 83
  doAssert worldPoint(8, 0) - worldPoint(0, 0) == vec3(1, 0, 0)
  doAssert worldPoint(0, 8) - worldPoint(0, 0) == vec3(0, 0, 1)
  doAssert worldPoint(MapWidth, MapHeight) - worldPoint(0, 0) ==
    vec3(MapWidth.float32 / 8, 0, MapHeight.float32 / 8)
  var imposters = 0
  for player in game.world.players:
    doAssert game.world.canOccupy(player.x, player.y),
      "Every player must spawn on walkable floor."
    if player.role == Imposter:
      inc imposters
    else:
      doAssert player.assignedTasks.len == TasksPerPlayer
  doAssert imposters == 2
  var floors = 0
  installImmutableLayers(@[game.ship.layer])
  for i, tile in game.ship.layer.tiles:
    doAssert tile.exists == (game.ship.tiles[i] == FloorTile)
    doAssert game.ship.tiles[i] != WallTile
    if tile.exists:
      inc floors
  doAssert floors == 2301
  let audit = AuditJson.fromJson(TileAudit)
  doAssert audit.candidateTiles == 3254
  doAssert audit.tiles.len == audit.candidateTiles
  for tile in audit.tiles:
    doAssert (game.ship.tiles[tileIndex(tile.x, tile.y)] == FloorTile) ==
      (tile.status == "kept")
    if tile.status == "kept":
      doAssert tile.blockers.len == 0
    if tile.status == "collision":
      doAssert tile.blockers.len > 0
  doAssert audit.blockedLinks.len == 5
  for link in audit.blockedLinks:
    let
      x = link.start[0]
      y = link.start[1]
      nx = link.`end`[0]
      ny = link.`end`[1]
      index = tileIndex(x, y)
    doAssert not game.world.connectedTiles(x, y, nx, ny)
    doAssert not game.world.connectedTiles(nx, ny, x, y)
    if x != nx:
      doAssert not game.ship.layer.tiles[index].connectedEast
      doAssert not game.world.canStep(
        (x + 1) * PixelsPerTile - 1, y * PixelsPerTile + 4,
        (x + 1) * PixelsPerTile, y * PixelsPerTile + 4
      )
    else:
      doAssert not game.ship.layer.tiles[index].connectedSouth
      doAssert not game.world.canStep(
        x * PixelsPerTile + 4, (y + 1) * PixelsPerTile - 1,
        x * PixelsPerTile + 4, (y + 1) * PixelsPerTile
      )
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      if game.world.isWalkable(x, y):
        doAssert game.ship.tiles[
          tileIndex(x div PixelsPerTile, y div PixelsPerTile)
        ] == FloorTile
  var nav: Navigator
  let spawn = game.world.players[0]
  for i in 0 ..< game.world.tasks.len:
    let target = game.world.taskPoint(i)
    doAssert target.x >= 0, "Task " & $i & " needs a usable interaction pixel."
    let path = nav.findPath(
      game.world, MapPoint(x: spawn.x, y: spawn.y), target
    )
    doAssert path.len > 0, "Task " & $i & " must be reachable from the Bridge."
    for point in path:
      doAssert game.world.isWalkable(point.x, point.y)
    for j in 1 ..< path.len:
      doAssert game.world.connectedTiles(
        path[j - 1].x div PixelsPerTile,
        path[j - 1].y div PixelsPerTile,
        path[j].x div PixelsPerTile,
        path[j].y div PixelsPerTile
      )
  for vent in game.world.vents:
    doAssert game.world.isWalkable(
      vent.x + vent.w div 2, vent.y + vent.h div 2
    )

echo "Testing legacy Croatoan geometry"
block:
  var config = defaultGameConfig()
  config.mapPath = "croatoan"
  let original = initSimServer(config)
  doAssert original.tasks.len == 41
  doAssert original.gameMap.path == "croatoan"

echo "Testing large rosters and resolved random seeds"
block:
  var options = testOptions(-1)
  options.players = 16
  let game = newGame(options)
  doAssert game.world.config.seed >= 0
  doAssert game.recording.config.seed == game.world.config.seed
  doAssert game.world.players.len == 16
  for player in game.world.players:
    doAssert game.world.canOccupy(player.x, player.y)

echo "Testing roster identities, replay metadata, and legacy recordings"
block:
  var options = testOptions(17)
  options.player = 3
  options.name = "Andre von Houck"
  let
    named = newGame(options)
    baseline = newGame(testOptions(17))
    path = "tmp/test-crewrift-identities.json"
  doAssert named.rosterName(3) == "Pink (Andre von Houck)"
  doAssert named.rosterName(0) == "Red (bots.nim)"
  doAssert named.world.gameHash() == baseline.world.gameHash()
  named.rewind()
  doAssert named.rosterName(3) == "Pink (Andre von Houck)"
  saveReplay(path, named.recording)
  options.replay = path
  let replay = newGame(options)
  doAssert replay.rosterName(3) == "Pink (Andre von Houck)"
  doAssert replay.world.gameHash() == named.world.gameHash()
  var tape = named.recording
  tape.playerNames[3] = "base.bass"
  saveReplay(path, tape)
  doAssert newGame(options).rosterName(3) == "Pink (base.bass)"
  tape.playerNames.setLen(0)
  saveReplay(path, tape)
  doAssert newGame(options).rosterName(3) == "Pink (Unknown)"
  tape.playerNames = @["Incomplete roster"]
  saveReplay(path, tape)
  var rejected = false
  try:
    discard loadReplay(path)
  except CrewriftError:
    rejected = true
  doAssert rejected
  removeFile(path)

echo "Testing original collision sliding"
block:
  var world = initSimServer(defaultGameConfig())
  let slot = world.addPlayer("slider")
  for pixel in world.walkMask.mitems:
    pixel = false
  world.players[slot].x = 20
  world.players[slot].y = 20
  world.players[slot].velX = world.config.motionScale - world.config.accel
  for point in [(20, 20), (20, 21), (21, 21)]:
    world.walkMask[mapIndex(point[0], point[1])] = true
  world.applyInput(slot, InputState(right: true, down: true), InputState(), 0)
  doAssert world.players[slot].x == 21 and world.players[slot].y == 21

echo "Testing three-second tasks, kills, ghosts, reports, and votes"
block:
  let game = newGame(testOptions())
  game.enterPlaying()
  var
    crew = -1
    imposter = -1
  for i, player in game.world.players:
    if player.role == Crewmate:
      crew = i
    else:
      imposter = i
  let
    task = game.world.players[crew].assignedTasks[0]
    point = game.world.taskPoint(task)
  game.world.players[crew].x = point.x
  game.world.players[crew].y = point.y
  for i in 0 ..< TaskCompleteTicks - 1:
    game.world.applyInput(crew, InputState(attack: true), InputState(), 0)
  doAssert not game.world.tasks[task].completed[crew]
  game.world.applyInput(crew, InputState(attack: true), InputState(), 0)
  doAssert game.world.tasks[task].completed[crew]
  doAssert game.world.players[crew].reward == TaskReward
  game.world.players[imposter].x = point.x
  game.world.players[imposter].y = point.y
  game.world.players[imposter].killCooldown = 1
  game.world.tryKill(imposter)
  doAssert game.world.players[crew].alive
  game.world.players[imposter].killCooldown = 0
  game.world.tryKill(imposter)
  doAssert not game.world.players[crew].alive
  doAssert game.world.bodies.len == 1
  doAssert game.world.playerKills(imposter) == 1
  doAssert game.world.playerKills(crew) == 0
  doAssert game.world.players[imposter].reward == KillReward
  doAssert game.world.players[imposter].killCooldown == KillCooldownTicks
  game.world.applyGhostMovement(crew, InputState(right: true))
  doAssert game.world.players[crew].velX > 0
  game.world.tryReport(imposter, game.world.bodies.len)
  doAssert game.world.phase == MeetingCall
  for i in 0 ..< MeetingCallTicks:
    game.world.step([], [])
  doAssert game.world.phase == Voting
  game.world.addVotingChat(imposter, "A report from the task station.")
  doAssert game.world.chatMessages.len == 1
  game.world.addVotingChat(imposter, "Too soon.")
  doAssert game.world.chatMessages.len == 1
  for i, player in game.world.players:
    if player.alive:
      game.world.voteState.votes[i] = imposter
  game.world.tallyVotes()
  doAssert game.world.voteState.ejectedPlayer == imposter
  game.world.applyVoteResult()
  doAssert not game.world.players[imposter].alive
  doAssert game.world.phase == Playing

echo "Testing original vent groups and cooldowns"
block:
  let game = newGame(testOptions())
  game.enterPlaying()
  var slot = -1
  for i, player in game.world.players:
    if player.role == Imposter:
      slot = i
  let vent = game.world.vents[0]
  game.world.players[slot].x = vent.x + vent.w div 2
  game.world.players[slot].y = vent.y + vent.h div 2
  game.world.tryVent(slot)
  doAssert game.world.players[slot].x != vent.x + vent.w div 2 or
    game.world.players[slot].y != vent.y + vent.h div 2
  doAssert game.world.players[slot].ventCooldown > 0
  let
    x = game.world.players[slot].x
    y = game.world.players[slot].y
  game.world.tryVent(slot)
  doAssert game.world.players[slot].x == x and game.world.players[slot].y == y

echo "Testing staggered accusations, defenses, and dead-player silence"
block:
  let game = newGame(testOptions(17))
  game.enterPlaying()
  var
    killer = -1
    witness = -1
    victim = -1
  for i, player in game.world.players:
    if player.role == Imposter:
      killer = i
    elif witness < 0:
      witness = i
    else:
      victim = i
  let point = game.world.taskPoint(
    game.world.players[victim].assignedTasks[0]
  )
  for slot in [killer, victim]:
    game.world.players[slot].x = point.x
    game.world.players[slot].y = point.y
  game.world.players[killer].killCooldown = 0
  game.world.tryKill(killer)
  doAssert not game.world.players[victim].alive
  game.world.players[witness].x = point.x
  game.world.players[witness].y = point.y
  var nav: Navigator
  discard game.bots[witness].decideBot(
    nav,
    game.world,
    witness,
    InputState()
  )
  doAssert game.bots[witness].suspects[killer] >= 3
  game.world.startVote(
    VoteCalledBody,
    witness,
    game.world.players[victim].color,
    game.world.players[victim].joinOrder
  )
  for player in game.world.players:
    if player.alive:
      doAssert player.x == player.homeX and player.y == player.homeY
      doAssert player.velX == 0 and player.velY == 0
      doAssert player.activeTask == -1
  while game.world.phase == MeetingCall:
    game.advance(record = true)
  for player in game.world.players:
    if player.alive:
      doAssert player.x == player.homeX and player.y == player.homeY
  var
    counts: array[MaxPlayers, int]
    previousChats: array[MaxPlayers, int]
    accusation = false
    defense = false
    report = false
  for i in 0 ..< game.world.config.voteTimerTicks:
    if game.world.phase != Voting:
      break
    game.advance(record = true)
    for player in game.world.players:
      if player.alive:
        doAssert player.x == player.homeX and player.y == player.homeY
    let chats = game.recording.frames[^1].chats
    doAssert chats.len <= 1, "Bots should take turns rather than flood chat."
    for chat in chats:
      if counts[chat.slot] > 0:
        doAssert game.world.tickCount - previousChats[chat.slot] >=
          game.world.config.messageCooldownTicks
      previousChats[chat.slot] = game.world.tickCount
      inc counts[chat.slot]
      accusation = accusation or chat.text.contains("I suspect ")
      defense = defense or chat.text.contains("that wasn't me")
      report = report or chat.text.contains("I found ")
      doAssert counts[chat.slot] <= 3
  doAssert accusation and defense and report
  doAssert counts[victim] == 0
  for i, player in game.world.players:
    if i != victim:
      doAssert counts[i] == 3, "Each living bot should join the discussion."
  doAssert game.world.phase == VoteResult
  doAssert game.world.chatMessages.len == VoteChatVisibleMessages

echo "Testing local policies and complete replay determinism"
block:
  let game = newGame(testOptions(17))
  for i in 0 ..< 2500:
    if game.finished():
      break
    game.advance(record = true)
  doAssert game.world.totalTasksRemaining() < 48,
    "Local crew policies must reach and finish tasks."
  let path = "tmp/test-crewrift-replay.json"
  saveReplay(path, game.recording)
  var options = testOptions()
  options.replay = path
  let replay = newGame(options)
  while not replay.finished():
    replay.advance()
  doAssert replay.world.gameHash() == game.world.gameHash()
  doAssert replay.world.players == game.world.players
  doAssert replay.world.chatMessages == game.world.chatMessages
  var tampered = replay.recording.frames[^1]
  tampered.hash = "invalid"
  var rejected = false
  try:
    replay.world.verifyFrame(tampered)
  except CrewriftError:
    rejected = true
  doAssert rejected
  removeFile(path)

echo "Testing backward seeking and resuming a live tape"
block:
  let game = newGame(testOptions(17))
  for i in 0 ..< 2500:
    game.advance(record = true)
  let
    expectedHash = game.world.gameHash()
    expectedPlayers = game.world.players
    expectedChats = game.world.chatMessages
    expectedBots = game.bots
    expectedRng = game.world.rng
  game.rewind()
  doAssert game.frame == 0
  doAssert game.recording.frames.len == 2500
  for i in 0 ..< 2500:
    game.advance(record = true)
  doAssert game.world.gameHash() == expectedHash
  doAssert game.world.players == expectedPlayers
  doAssert game.world.chatMessages == expectedChats
  doAssert game.bots == expectedBots
  doAssert game.world.rng == expectedRng
  doAssert game.recording.frames.len == 2500
  let baseline = newGame(testOptions(17))
  for i in 0 ..< 2600:
    baseline.advance(record = true)
  for i in 0 ..< 100:
    game.advance(record = true)
  doAssert game.frame == 2600
  doAssert game.recording.frames == baseline.recording.frames
  doAssert game.world.players == baseline.world.players

echo "Testing human input history and rewinding a completed replay"
block:
  let game = newGame(testOptions())
  for i in 0 ..< 1500:
    game.input = InputState(right: i mod 200 < 100, attack: true)
    game.advance(player = 0, record = true)
  let
    expectedHash = game.world.gameHash()
    expectedPlayers = game.world.players
    expectedBots = game.bots
    expectedRng = game.world.rng
  game.rewind()
  for i in 0 ..< 1500:
    game.input = InputState(left: true)
    game.advance(player = 0, record = true)
  doAssert game.world.gameHash() == expectedHash
  doAssert game.world.players == expectedPlayers
  doAssert game.bots == expectedBots
  doAssert game.world.rng == expectedRng
  let completed = newGame(testOptions(17))
  while not completed.finished():
    completed.advance(record = true)
  let path = "tmp/test-crewrift-seek.json"
  saveReplay(path, completed.recording)
  var options = testOptions()
  options.replay = path
  let replay = newGame(options)
  while not replay.finished():
    replay.advance()
  doAssert replay.world.phase == GameOver
  replay.rewind()
  doAssert not replay.finished()
  for i in 0 ..< 900:
    replay.advance()
  doAssert replay.frame == 900
  while not replay.finished():
    replay.advance()
  doAssert replay.world.gameHash() == completed.world.gameHash()
  doAssert replay.world.players == completed.world.players
  removeFile(path)

echo "Crewrift checks passed"
