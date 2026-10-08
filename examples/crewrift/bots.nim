## Local crew and imposter policies using evidence and Polyworld paths.

import
  std/[random, strutils],
  polyworld/pathing,
  sim, maps

const DiscussionRounds = 3

type
  Bot* = object
    path*: seq[MapPoint]
    waypoint*: int
    task*: int
    stuck*: int
    previous*: MapPoint
    suspects*: array[MaxPlayers, int]
    suspectRooms*: array[MaxPlayers, string]
    location*: string
    seenBodies*: int
    meeting*: int
    vote*: int
    suspect*: int
    accuser*: int
    chatRound*: int
    chat*: string
  Navigator* = object
    layer*: QuadLayer
    parents: seq[int32]
    queue: seq[int32]

proc findPath*(
  nav: var Navigator,
  sim: SimServer,
  start, goal: MapPoint
): seq[MapPoint] =
  ## Finds Polyworld tile routes, retaining pixel paths for older recordings.
  if not sim.isWalkable(start.x, start.y) or
    not sim.isWalkable(goal.x, goal.y):
      return
  if sim.gameMap.path == "map1":
    if nav.layer == nil:
      nav.layer = sim.buildShipMap().layer
    installImmutableLayers(@[nav.layer])
    let tiles = findTilePath(
      0, start.x div PixelsPerTile, start.y div PixelsPerTile,
      0, goal.x div PixelsPerTile, goal.y div PixelsPerTile
    )
    if tiles.len == 0:
      return
    for tile in tiles:
      result.add MapPoint(
        x: tile.x.int * PixelsPerTile + PixelsPerTile div 2,
        y: tile.z.int * PixelsPerTile + PixelsPerTile div 2
      )
    result.add goal
    return
  nav.parents.setLen(MapWidth * MapHeight)
  nav.queue.setLen(MapWidth * MapHeight)
  for parent in nav.parents.mitems:
    parent = -1
  let
    first = mapIndex(start.x, start.y)
    last = mapIndex(goal.x, goal.y)
  var
    head = 0
    tail = 1
  nav.queue[0] = first.int32
  nav.parents[first] = first.int32
  while head < tail and nav.parents[last] < 0:
    let current = nav.queue[head].int
    inc head
    let
      x = current mod MapWidth
      y = current div MapWidth
    for offset in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let
        nx = x + offset[0]
        ny = y + offset[1]
      if not sim.isWalkable(nx, ny):
        continue
      let next = mapIndex(nx, ny)
      if nav.parents[next] < 0:
        nav.parents[next] = current.int32
        nav.queue[tail] = next.int32
        inc tail
  if nav.parents[last] < 0:
    return
  var
    current = last
    reversed: seq[MapPoint]
  while current != first:
    reversed.add MapPoint(x: current mod MapWidth, y: current div MapWidth)
    current = nav.parents[current].int
  for i in countdown(reversed.high, 0):
    result.add reversed[i]

proc roomName(sim: SimServer, x, y: int): string =
  ## Names the room containing a sighting or the connecting corridor.
  for room in sim.rooms:
    if x >= room.x and x < room.x + room.w and
      y >= room.y and y < room.y + room.h:
        return room.name
  "the corridor"

proc observe(bot: var Bot, sim: SimServer, slot: int) =
  ## Remembers visible body sightings and the bot's own task location.
  if sim.phase != Playing:
    return
  let own = sim.players[slot]
  bot.location = sim.roomName(own.x, own.y)
  if sim.bodies.len < bot.seenBodies:
    bot.seenBodies = 0
  for i in bot.seenBodies ..< sim.bodies.len:
    let body = sim.bodies[i]
    if not sim.visibleFrom(slot, body.x, body.y):
      continue
    for j, player in sim.players:
      if j == slot or not player.alive or
        not sim.visibleFrom(slot, player.x, player.y):
          continue
      let distance = distSq(player.x, player.y, body.x, body.y)
      if distance <= KillRange * KillRange and
        sim.tickCount - body.killTick <= 2:
          bot.suspects[j] += 3
          bot.suspectRooms[j] = sim.roomName(body.x, body.y)
      elif distance <= ReportRange * ReportRange * 4:
        bot.suspects[j] = max(bot.suspects[j], 1)
        bot.suspectRooms[j] = sim.roomName(body.x, body.y)
  bot.seenBodies = sim.bodies.len

proc beginDiscussion(bot: var Bot, sim: SimServer, slot: int) =
  ## Chooses an evidence-based suspect or an imposter's false accusation.
  bot.meeting = sim.voteState.voteTimer + sim.tickCount
  bot.vote = sim.players.len
  bot.suspect = -1
  bot.accuser = -1
  bot.chatRound = 0
  var evidence = 0
  for i, player in sim.players:
    if player.alive and i != slot and bot.suspects[i] > evidence:
      evidence = bot.suspects[i]
      bot.suspect = i
  if evidence >= 3:
    bot.vote = bot.suspect
  if sim.players[slot].role == Imposter:
    var best = high(int)
    let own = sim.players[slot]
    for i, player in sim.players:
      if not player.alive or player.role != Crewmate:
        continue
      let distance = distSq(own.x, own.y, player.x, player.y)
      if distance < best:
        best = distance
        bot.suspect = i
    if bot.suspect >= 0:
      bot.vote = bot.suspect

proc discussionMessage(bot: Bot, sim: SimServer, slot: int): string =
  ## Supplies reports, accusations, alibis, rebuttals, and voting conclusions.
  let
    caller = sim.meetingCallCallerIndex()
    own = sim.players[slot]
    location = if bot.location.len > 0: bot.location else: "the corridor"
  case bot.chatRound
  of 0:
    if slot == caller and sim.voteState.callKind == VoteCalledBody:
      var found = "the corridor"
      for body in sim.bodies:
        if body.slotId == sim.voteState.bodySlotId:
          found = sim.roomName(body.x, body.y)
      result = "I found " & playerColorText(sim.voteState.bodyColor) &
        " in " & found & "."
      if own.role == Crewmate and bot.suspect >= 0:
        result.add " I suspect " &
          playerColorText(sim.players[bot.suspect].color) &
          "; I saw them next to the body."
      else:
        result.add " Who was nearby?"
      return
    if bot.suspect >= 0:
      let name = playerColorText(sim.players[bot.suspect].color)
      if own.role == Imposter:
        return "I suspect " & name &
          ". They were hanging around instead of doing tasks."
      if bot.suspects[bot.suspect] >= 3:
        return "I saw " & name & " beside a fresh body in " &
          bot.suspectRooms[bot.suspect] & ". I suspect " & name & "."
      return "I suspect " & name & ". I saw them near the body in " &
        bot.suspectRooms[bot.suspect] & ". Did anyone else see them?"
    case slot mod 3
    of 0:
      return "I was working on tasks in " & location &
        ". Who was with the victim?"
    of 1:
      return "I was in " & location &
        " doing tasks. Did anyone see who left the body?"
    else:
      return "I came from " & location &
        ". I didn't see the kill. Where was everyone else?"
  of 1:
    if bot.accuser >= 0:
      return playerColorText(sim.players[bot.accuser].color) &
        ", that wasn't me. I was doing tasks in " & location &
        ". Being nearby doesn't prove a kill."
    if bot.suspect >= 0:
      return playerColorText(sim.players[bot.suspect].color) &
        ", where were you before the report? Can anyone confirm your story?"
    if caller >= 0 and caller != slot:
      case slot mod 3
      of 0:
        return "Being near a body isn't enough. Did anyone see a kill or a vent?"
      of 1:
        return playerColorText(sim.players[caller].color) &
          ", did you see anyone leave? I can't confirm a killer."
      else:
        return "Can someone confirm who was doing tasks? We need a witness."
    return "Please share what you actually saw. Who can confirm an alibi?"
  else:
    if bot.vote < sim.players.len:
      return "I'm voting for " &
        playerColorText(sim.players[bot.vote].color) &
        (if own.role == Imposter: ". Their story doesn't add up."
         else: ". I saw them beside the fresh body.")
    if bot.suspect >= 0:
      return "I'm suspicious of " &
        playerColorText(sim.players[bot.suspect].color) &
        ", but I didn't see a kill. Skipping without stronger evidence."
    return "I haven't seen enough evidence. I'll skip and keep doing tasks."

proc discuss(bot: var Bot, sim: SimServer, slot: int): bool =
  ## Staggers three chat rounds before allowing the bot to cast its vote.
  if bot.meeting != sim.voteState.voteTimer + sim.tickCount and
    sim.voteState.finalizeTimer == 0:
      bot.beginDiscussion(sim, slot)
  let own = sim.players[slot]
  for message in sim.chatMessages:
    if message.slotId == own.joinOrder:
      continue
    if message.text.toLowerAscii().contains(
      "i suspect " & playerColorText(own.color)
    ):
      for i, player in sim.players:
        if player.joinOrder == message.slotId:
          bot.accuser = i
  var
    living = 0
    rank = 0
  let caller = sim.meetingCallCallerIndex()
  for i, player in sim.players:
    if player.alive:
      inc living
      if i < slot and i != caller:
        inc rank
  if caller >= 0 and sim.players[caller].alive:
    if slot == caller:
      rank = 0
    else:
      inc rank
  let
    interval = max(6, min(TargetFps,
      sim.config.voteTimerTicks div (max(1, living) * 4)))
    roundTicks = max(sim.config.messageCooldownTicks + 1, living * interval)
    elapsed = sim.config.voteTimerTicks - sim.voteState.voteTimer
    scheduled = TargetFps div 2 + rank * interval +
      bot.chatRound * roundTicks
    voteAfter = min(sim.config.voteTimerTicks - TargetFps * 2,
      max(TargetFps * 18, DiscussionRounds * roundTicks + TargetFps))
  if bot.chatRound < DiscussionRounds and elapsed >= scheduled and
    sim.tickCount - own.lastChatTick >= sim.config.messageCooldownTicks:
      bot.chat = bot.discussionMessage(sim, slot)
      inc bot.chatRound
  elapsed >= voteAfter

proc chooseTask(bot: var Bot, sim: var SimServer, slot: int): int =
  ## Selects a nearby unfinished assignment or an imposter's cover station.
  let player = sim.players[slot]
  result = -1
  var best = high(int)
  if player.role == Imposter:
    return sim.rng.rand(sim.tasks.high)
  for task in player.assignedTasks:
    if sim.tasks[task].completed[slot]:
      continue
    let point = sim.taskPoint(task)
    if point.x < 0:
      continue
    let distance = distSq(player.x, player.y, point.x, point.y)
    if distance < best:
      best = distance
      result = task

proc decideBot*(
  bot: var Bot,
  nav: var Navigator,
  sim: var SimServer,
  slot: int,
  previous: InputState
): InputState =
  ## Supplies original movement and edge-triggered interaction buttons.
  bot.observe(sim, slot)
  let player = sim.players[slot]
  if sim.phase == Voting:
    if not player.alive:
      return
    if bot.discuss(sim, slot) and sim.voteState.votes[slot] == -1:
      if sim.voteState.cursor[slot] == bot.vote:
        result.attack = not previous.attack
      else:
        result.down = not previous.down
    return
  if sim.phase != Playing:
    return
  for body in sim.bodies:
    if player.alive and sim.visibleFrom(slot, body.x, body.y) and
      distSq(player.x, player.y, body.x, body.y) <= ReportRange * ReportRange:
        result.attack = not previous.attack
        return
  if player.role == Imposter and player.alive and player.killCooldown == 0:
    for target in sim.players:
      if target.alive and target.role == Crewmate and
        sim.visibleFrom(slot, target.x, target.y) and
        distSq(player.x, player.y, target.x, target.y) <= KillRange * KillRange:
          result.attack = not previous.attack
          return
  if bot.previous.x == player.x and bot.previous.y == player.y:
    inc bot.stuck
  else:
    bot.stuck = 0
  bot.previous = MapPoint(x: player.x, y: player.y)
  if bot.task < 0 or bot.path.len == 0 or bot.stuck > TargetFps * 2 or
    (player.role == Crewmate and sim.tasks[bot.task].completed[slot]):
      bot.task = bot.chooseTask(sim, slot)
      bot.path.setLen(0)
      bot.waypoint = 0
      bot.stuck = 0
      if bot.task < 0:
        return
      let point = sim.taskPoint(bot.task)
      if not player.alive:
        bot.path = @[point]
      else:
        bot.path = nav.findPath(sim, bot.previous, point)
  if bot.path.len == 0:
    return
  let station = sim.tasks[bot.task]
  if player.x >= station.x and player.x < station.x + station.w and
    player.y >= station.y and player.y < station.y + station.h:
      result.attack = true
      if player.role == Imposter:
        bot.task = -1
      return
  while bot.waypoint < bot.path.high and
    distSq(player.x, player.y, bot.path[bot.waypoint].x,
      bot.path[bot.waypoint].y) <= 9:
      inc bot.waypoint
  let target = bot.path[bot.waypoint]
  result.left = target.x < player.x - 1
  result.right = target.x > player.x + 1
  result.up = target.y < player.y - 1
  result.down = target.y > player.y + 1
