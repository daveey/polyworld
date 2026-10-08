## Crewrift's original fixed-tick rules, adapted for Polyworld presentation.

import
  std/[json, math, random, strutils, times],
  chroma, jsony, pixie,
  tasks as taskAssignments

const
  MapJson = staticRead("data/croatoan.json")
  Map1Json = staticRead("data/map1.json")
  Map1Tiles = staticRead("data/map1-tiles.txt")
  Map1Links = staticRead("data/map1-links.txt")
  WalkPng = staticRead("data/croatoan-walk.png")
  WallsPng = staticRead("data/croatoan-walls.png")
  ScreenWidth* = 128
  ScreenHeight* = 128
  DefaultMapPath* = "map1"
  PixelsPerTile* = 8
  MapWidth* = 1235
  MapHeight* = 659
  CollisionW* = 1
  CollisionH* = 1
  MotionScale* = 256
  Accel* = 76
  FrictionNum* = 144
  FrictionDen* = 256
  MaxSpeed* = 704
  StopThreshold* = 8
  MovementSlideMaxScan = 3
  TargetFps* = 24
  StuckPenaltyTicks* = TargetFps * 20
  ConnectTimeoutTicks* = TargetFps * 120
  DisconnectTimeoutTicks* = TargetFps * 30
  TintColor* = 3'u8
  ShadeTintColor* = 9'u8
  KillRange* = 20
  KillCooldownTicks* = 800
  ButtonResetsKillCooldowns* = false
  GameInfoTicks* = 3 * TargetFps
  RoleRevealTicks* = 120
  TaskCompleteTicks* = 72
  VentRange* = 16
  ReportRange* = 20
  VoteResultTicks* = 72
  VoteFinalizeTicks* = TargetFps * 2
  MaxPlayers* = 16
  MinPlayers* = 8
  ImposterCount* = 2
  AutoImposterCount* = true
  StartWaitTicks* = 5 * TargetFps
  VoteTimerTicks* = TargetFps * 50
  MeetingCallTicks* = TargetFps * 3
  MessageCooldownTicks* = 100
  GameOverTicks* = 360
  MaxTicks* = 10_000  ## 0 = no limit.
  MaxGames* = 0  ## 0 = no limit.
  TasksPerPlayer* = 8
  ShowTaskArrows* = true
  ButtonCalls* = 1
  VoteChatVisibleMessages* = 6
  VoteChatCharsPerLine* = 32
  VoteChatLineCount* = 10
  VoteChatMaxChars* = VoteChatCharsPerLine * VoteChatLineCount
  RandomSeedSentinel* = -1
  RandomSeedMod = int(high(int32))
  TaskReward* = 1
  KillReward* = 10
  WinReward* = 100
  VoteTimeoutPenalty* = -10
  StuckPenalty* = -1
  ConnectionTimeoutPenalty* = -100
  PlayerColors* = [
    3'u8,
    14,
    10,
    4,
    7,
    8,
    13,
    15,
    11,
    6,
    2,
    12,
    5,
    1,
    9,
    0
  ]
  PlayerColorNames* = [
    "red",
    "blue",
    "green",
    "pink",
    "orange",
    "yellow",
    "purple",
    "cyan",
    "lime",
    "brown",
    "beige",
    "navy",
    "teal",
    "rose",
    "maroon",
    "gray"
  ]
  PlayerColorPalette* = [
    parseHtmlColor("#c51111").rgba,
    parseHtmlColor("#132ed1").rgba,
    parseHtmlColor("#117f2d").rgba,
    parseHtmlColor("#ed54ba").rgba,
    parseHtmlColor("#ef7d0d").rgba,
    parseHtmlColor("#f5f557").rgba,
    parseHtmlColor("#6b2fbb").rgba,
    parseHtmlColor("#38fedc").rgba,
    parseHtmlColor("#50ef39").rgba,
    parseHtmlColor("#71491e").rgba,
    parseHtmlColor("#f0d7b7").rgba,
    parseHtmlColor("#1b2148").rgba,
    parseHtmlColor("#38a9a5").rgba,
    parseHtmlColor("#f4a6c8").rgba,
    parseHtmlColor("#6b2b3a").rgba,
    parseHtmlColor("#282a30").rgba
  ]
  ShadowMap* = [
    0'u8,  #  0 black       -> black
    12,    #  1 gray         -> dark navy
    9,     #  2 white        -> dark teal
    5,     #  3 red          -> dark brown
    5,     #  4 pink         -> dark brown
    0,     #  5 dark brown   -> black
    5,     #  6 brown        -> dark brown
    5,     #  7 orange       -> dark brown
    5,     #  8 yellow       -> dark brown
    12,    #  9 dark teal    -> dark navy
    9,     # 10 green        -> dark teal
    9,     # 11 lime         -> dark teal
    0,     # 12 dark navy    -> black
    12,    # 13 blue         -> dark navy
    12,    # 14 light blue   -> dark navy
    9,     # 15 pale blue    -> dark teal
  ]

type
  InputState* = object
    up*, down*, left*, right*, select*, attack*, b*: bool

  PlayerRole* = enum
    Crewmate
    Imposter

  CrewriftError* = object of ValueError

  GamePhase* = enum
    Lobby
    Playing
    Voting
    VoteResult
    GameOver
    RoleReveal
    GameInfo
    MeetingCall

  VoteCallKind* = enum
    VoteCalledUnknown
    VoteCalledButton
    VoteCalledBody

  VoteState* = object
    callKind*: VoteCallKind
    callerIndex*: int
    bodyColor*: uint8
    bodySlotId*: int
    callTimer*: int
    votes*: seq[int]
    cursor*: seq[int]
    resultTimer*: int
    voteTimer*: int
    finalizeTimer*: int
    ejectedPlayer*: int

  TaskStation* = object
    name*: string
    resourceName*: string
    x*, y*, w*, h*: int
    completed*: seq[bool]

  Vent* = object
    resourceName*: string
    x*, y*, w*, h*: int
    group*: char
    groupIndex*: int

  Room* = object
    name*: string
    x*, y*, w*, h*: int

  MapRect* = object
    x*, y*, w*, h*: int

  MapPoint* = object
    x*, y*: int

  CrewriftMap* = object
    name*: string
    path*: string
    asepritePath*: string
    width*, height*: int
    mapLayer*, walkLayer*, wallLayer*: int
    button*: MapRect
    home*: MapPoint
    tasks*: seq[TaskStation]
    vents*: seq[Vent]
    rooms*: seq[Room]

  Body* = object
    x*, y*: int
    color*: uint8
    slotId*: int
    killerSlot*: int
    killTick*: int

  ChatMessage* = object
    slotId*: int
    color*: uint8
    text*: string

  RewardAccount* = object
    address*: string
    slotIndex*: int
    role*: PlayerRole
    hasRole*: bool
    won*: bool
    abandoned*: bool
    connectTimeout*: int
    disconnectTimeout*: int
    reward*: int
    winsImposter*: int
    winsCrewmate*: int
    gamesImposter*: int
    gamesCrewmate*: int
    kills*: int
    tasks*: int
    votePlayers*: int
    voteSkip*: int
    voteTimeout*: int

  PlayerSlotConfig* = object
    name*: string
    token*: string
    role*: PlayerRole
    color*: uint8
    hasRole*: bool
    hasColor*: bool

  GameConfig* = object
    motionScale*: int
    accel*: int
    frictionNum*: int
    frictionDen*: int
    maxSpeed*: int
    stopThreshold*: int
    seed*: int
    speed*: int
    fastMode*: bool
    killRange*: int
    killCooldownTicks*: int
    buttonResetsKillCooldowns*: bool
    gameInfoTicks*: int
    roleRevealTicks*: int
    taskCompleteTicks*: int
    ventRange*: int
    reportRange*: int
    voteResultTicks*: int
    connectTimeoutTicks*: int
    disconnectTimeoutTicks*: int
    minPlayers*: int
    imposterCount*: int
    autoImposterCount*: bool
    startWaitTicks*: int
    voteTimerTicks*: int
    messageCooldownTicks*: int
    gameOverTicks*: int
    maxTicks*: int
    maxGames*: int
    tasksPerPlayer*: int
    showTaskArrows*: bool
    showTaskBubbles*: bool
    showPlayerLabels*: bool
    buttonCalls*: int
    mapPath*: string
    closedRoster*: bool
    slots*: seq[PlayerSlotConfig]

  Player* = object
    x*, y*: int
    homeX*, homeY*: int
    velX*, velY*: int
    carryX*, carryY*: int
    lastMoveTick*: int
    flipH*: bool
    role*: PlayerRole
    alive*: bool
    connected*: bool
    disconnectTick*: int
    killCooldown*: int
    joinOrder*: int
    address*: string
    color*: uint8
    taskProgress*: int
    activeTask*: int
    tasksRewarded*: int
    ventCooldown*: int
    buttonCallsUsed*: int
    lastChatTick*: int
    assignedTasks*: seq[int]
    reward*: int

  SimServer* = object
    config*: GameConfig
    players*: seq[Player]
    chatMessages*: seq[ChatMessage]
    rewardAccounts*: seq[RewardAccount]
    bodies*: seq[Body]
    gameMap*: CrewriftMap
    tasks*: seq[TaskStation]
    vents*: seq[Vent]
    rooms*: seq[Room]
    walkMask*: seq[bool]
    blockedEdges*: seq[uint8]
    wallMask*: seq[bool]
    rng*: Rand
    nextJoinOrder*: int
    tickCount*: int
    gameStartTick*: int
    gameTickCount*: int
    startWaitTimer*: int
    phase*: GamePhase
    voteState*: VoteState
    winner*: PlayerRole
    gameOverTimer*: int
    gameInfoTimer*: int
    roleRevealTimer*: int
    timeLimitReached*: bool
    needsReregister*: bool
    gameEventLoggingEnabled*: bool
    lastLobbyPlayersLogged*: int
    lastLobbyNeededLogged*: int
    lastLobbySecondsLogged*: int

proc clampMapX(x: int): int =
  ## Returns an x coordinate inside the map bounds.
  clamp(x, 0, MapWidth - 1)

proc clampMapY(y: int): int =
  ## Returns a y coordinate inside the map bounds.
  clamp(y, 0, MapHeight - 1)

proc roomDistanceSquared*(room: Room, x, y: int): int =
  ## Returns the squared distance from a point to a room edge.
  let
    px = clampMapX(x)
    py = clampMapY(y)
    dx =
      if px < room.x:
        room.x - px
      elif px >= room.x + room.w:
        px - (room.x + room.w - 1)
      else:
        0
    dy =
      if py < room.y:
        room.y - py
      elif py >= room.y + room.h:
        py - (room.y + room.h - 1)
      else:
        0
  dx * dx + dy * dy

proc nearestRoomAt*(
  rooms: openArray[Room],
  x, y: int
): tuple[found: bool, inside: bool, name: string] =
  ## Returns the containing or nearest room for one map point.
  var bestDistance = high(int)
  for room in rooms:
    let distance = room.roomDistanceSquared(x, y)
    if distance == 0:
      return (true, true, room.name)
    if distance < bestDistance:
      bestDistance = distance
      result = (true, false, room.name)

proc cleanChatMessage*(message: string): string =
  ## Returns a printable, bounded chat message.
  let trimmed = message.strip()
  for ch in trimmed:
    if result.len >= VoteChatMaxChars:
      return
    if ch >= ' ' and ch <= '~':
      result.add(ch)

proc defaultGameConfig*(): GameConfig =
  ## Returns the default Crewrift gameplay config.
  GameConfig(
    motionScale: MotionScale,
    accel: Accel,
    frictionNum: FrictionNum,
    frictionDen: FrictionDen,
    maxSpeed: MaxSpeed,
    stopThreshold: StopThreshold,
    seed: RandomSeedSentinel,
    speed: 1,
    fastMode: true,
    killRange: KillRange,
    killCooldownTicks: KillCooldownTicks,
    buttonResetsKillCooldowns: ButtonResetsKillCooldowns,
    gameInfoTicks: GameInfoTicks,
    roleRevealTicks: RoleRevealTicks,
    taskCompleteTicks: TaskCompleteTicks,
    ventRange: VentRange,
    reportRange: ReportRange,
    voteResultTicks: VoteResultTicks,
    connectTimeoutTicks: ConnectTimeoutTicks,
    disconnectTimeoutTicks: DisconnectTimeoutTicks,
    minPlayers: MinPlayers,
    imposterCount: ImposterCount,
    autoImposterCount: AutoImposterCount,
    startWaitTicks: StartWaitTicks,
    voteTimerTicks: VoteTimerTicks,
    messageCooldownTicks: MessageCooldownTicks,
    gameOverTicks: GameOverTicks,
    maxTicks: MaxTicks,
    maxGames: MaxGames,
    tasksPerPlayer: TasksPerPlayer,
    showTaskArrows: ShowTaskArrows,
    showTaskBubbles: true,
    showPlayerLabels: true,
    buttonCalls: ButtonCalls,
    mapPath: DefaultMapPath,
    closedRoster: false,
    slots: @[]
  )

proc readConfigInt(node: JsonNode, name: string, value: var int) =
  ## Reads one optional integer config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JInt:
    raise newException(
      CrewriftError,
      "Config field " & name & " must be an integer."
    )
  value = item.getInt()

proc readConfigBool(node: JsonNode, name: string, value: var bool) =
  ## Reads one optional boolean config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JBool:
    raise newException(
      CrewriftError,
      "Config field " & name & " must be a boolean."
    )
  value = item.getBool()

proc readConfigString(node: JsonNode, name: string, value: var string) =
  ## Reads one optional string config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JString:
    raise newException(
      CrewriftError,
      "Config field " & name & " must be a string."
    )
  value = item.getStr()

proc readSlotRole(text: string, slotIndex: int): PlayerRole =
  ## Reads one slot role string.
  case text.strip().toLowerAscii()
  of "crew":
    Crewmate
  of "imp", "imposter", "impostor":
    Imposter
  else:
    raise newException(
      CrewriftError,
      "Config field slots[" & $slotIndex & "].role must be crew or imposter."
    )

proc normalizedSlotColor(text: string): string =
  ## Returns a normalized slot color name.
  result = text.strip().toLowerAscii()
  result = result.replace("_", " ")
  result = result.replace("-", " ")
  result = result.replace(" ", "")

proc playerColorIndex*(color: uint8): int =
  ## Returns the player color list index for one color id.
  for i in 0 ..< PlayerColors.len:
    if PlayerColors[i] == color:
      return i
  -1

proc playerColorText*(color: uint8): string =
  ## Returns the readable player color name.
  let index = playerColorIndex(color)
  if index >= 0:
    return PlayerColorNames[index]
  "unknown"

proc shadeRgba(color: ColorRGBA): ColorRGBA =
  ## Returns a darkened copy of one true-color pixel.
  rgba(
    uint8((int(color.r) * 48) div 100),
    uint8((int(color.g) * 48) div 100),
    uint8((int(color.b) * 48) div 100),
    color.a
  )

proc playerColorRgba*(color: uint8): ColorRGBA =
  ## Returns the true-color RGBA value for one player color id.
  let index = playerColorIndex(color)
  if index >= 0:
    return PlayerColorPalette[index]
  rgba(128, 128, 128, 255)

proc playerShadeRgba*(color: uint8): ColorRGBA =
  ## Returns the true-color shaded RGBA value for one player color id.
  playerColorRgba(color).shadeRgba()

proc readSlotColor(text: string, slotIndex: int): uint8 =
  ## Reads one slot color string.
  case text.normalizedSlotColor()
  of "red":
    PlayerColors[0]
  of "blue":
    PlayerColors[1]
  of "green":
    PlayerColors[2]
  of "pink":
    PlayerColors[3]
  of "orange":
    PlayerColors[4]
  of "yellow":
    PlayerColors[5]
  of "purple":
    PlayerColors[6]
  of "cyan", "lightblue", "paleblue":
    PlayerColors[7]
  of "lime":
    PlayerColors[8]
  of "brown", "darkbrown":
    PlayerColors[9]
  of "beige", "tan", "white":
    PlayerColors[10]
  of "navy", "darknavy":
    PlayerColors[11]
  of "darkteal", "teal":
    PlayerColors[12]
  of "rose":
    PlayerColors[13]
  of "maroon":
    PlayerColors[14]
  of "gray", "grey", "black":
    PlayerColors[15]
  else:
    raise newException(
      CrewriftError,
      "Config field slots[" & $slotIndex & "].color is unknown."
    )

proc readConfigSlots(node: JsonNode, slots: var seq[PlayerSlotConfig]) =
  ## Reads optional fixed player slot config entries.
  if not node.hasKey("slots"):
    return
  let items = node["slots"]
  if items.kind != JArray:
    raise newException(CrewriftError, "Config field slots must be an array.")
  slots.setLen(0)
  for i, item in items.elems:
    if item.kind != JObject:
      raise newException(
        CrewriftError,
        "Config field slots[" & $i & "] must be an object."
      )
    if item.hasKey("name"):
      raise newException(
        CrewriftError,
        "Config field slots[" & $i & "].name is not supported; use players[" &
          $i & "].name instead."
      )
    var slot: PlayerSlotConfig
    item.readConfigString("token", slot.token)
    if item.hasKey("role"):
      let role = item["role"]
      if role.kind != JString:
        raise newException(
          CrewriftError,
          "Config field slots[" & $i & "].role must be a string."
        )
      slot.role = readSlotRole(role.getStr(), i)
      slot.hasRole = true
    if item.hasKey("color"):
      let color = item["color"]
      if color.kind != JString:
        raise newException(
          CrewriftError,
          "Config field slots[" & $i & "].color must be a string."
        )
      slot.color = readSlotColor(color.getStr(), i)
      slot.hasColor = true
    slots.add(slot)

proc readConfigPlayers(node: JsonNode, slots: var seq[PlayerSlotConfig]) =
  ## Reads optional fixed player display names by slot index.
  if node.hasKey("player_names"):
    raise newException(
      CrewriftError,
      "Config field player_names is not supported; use players[].name instead."
    )
  if not node.hasKey("players"):
    return
  let items = node["players"]
  if items.kind != JArray:
    raise newException(CrewriftError, "Config field players must be an array.")
  if items.len > MaxPlayers:
    raise newException(
      CrewriftError,
      "Config field players cannot have more than " & $MaxPlayers & " entries."
    )
  if slots.len < items.len:
    slots.setLen(items.len)
  for i, item in items.elems:
    if item.kind != JObject:
      raise newException(
        CrewriftError,
        "Config field players[" & $i & "] must be an object."
      )
    if not item.hasKey("name"):
      raise newException(
        CrewriftError,
        "Config field players[" & $i & "].name is required."
      )
    let nameNode = item["name"]
    if nameNode.kind != JString:
      raise newException(
        CrewriftError,
        "Config field players[" & $i & "].name must be a string."
      )
    let name = nameNode.getStr()
    if name.len == 0:
      raise newException(
        CrewriftError,
        "Config field players[" & $i & "].name must not be empty."
      )
    slots[i].name = name

proc defaultSlotName(slotIndex: int): string =
  ## Returns the canonical name for one generated tournament slot.
  "Player" & $(slotIndex + 1)

proc readConfigTokens(
  node: JsonNode,
  slots: var seq[PlayerSlotConfig],
  closedRoster: bool
) =
  ## Reads optional fixed player slot tokens.
  if not node.hasKey("tokens"):
    return
  let items = node["tokens"]
  if items.kind != JArray:
    raise newException(CrewriftError, "Config field tokens must be an array.")
  if items.len > MaxPlayers:
    raise newException(
      CrewriftError,
      "Config field tokens cannot have more than " & $MaxPlayers & " entries."
    )
  if slots.len < items.len:
    slots.setLen(items.len)
  for i, item in items.elems:
    if item.kind != JString:
      raise newException(
        CrewriftError,
        "Config field tokens[" & $i & "] must be a string."
      )
    let token = item.getStr()
    if slots[i].token.len > 0 and slots[i].token != token:
      raise newException(
        CrewriftError,
        "Config field tokens[" & $i & "] conflicts with slots[" & $i &
          "].token."
      )
    slots[i].token = token
    if closedRoster and slots[i].name.len == 0:
      slots[i].name = defaultSlotName(i)

proc validate(config: GameConfig) =
  ## Raises if a gameplay config has invalid values.
  if config.motionScale <= 0:
    raise newException(
      CrewriftError,
      "Config field motionScale must be positive."
    )
  if config.frictionDen <= 0:
    raise newException(
      CrewriftError,
      "Config field frictionDen must be positive."
    )
  if config.seed < RandomSeedSentinel:
    raise newException(
      CrewriftError,
      "Config field seed must be -1 or greater."
    )
  if config.minPlayers < 1:
    raise newException(
      CrewriftError,
      "Config field minPlayers must be at least 1."
    )
  if config.minPlayers > MaxPlayers:
    raise newException(
      CrewriftError,
      "can't do more than " & $MaxPlayers & " players."
    )
  if config.imposterCount < 0:
    raise newException(
      CrewriftError,
      "Config field imposterCount must be non-negative."
    )
  if config.speed notin [1, 2, 3, 4, 8, 16]:
    raise newException(
      CrewriftError,
      "Config field speed must be 1, 2, 3, 4, 8, or 16."
    )
  if config.startWaitTicks < 0:
    raise newException(
      CrewriftError,
      "Config field startWaitTicks must be non-negative."
    )
  if config.tasksPerPlayer < 0:
    raise newException(
      CrewriftError,
      "Config field tasksPerPlayer must be non-negative."
    )
  if config.buttonCalls < 0:
    raise newException(
      CrewriftError,
      "Config field buttonCalls must be non-negative."
    )
  if config.roleRevealTicks < 0:
    raise newException(
      CrewriftError,
      "Config field roleRevealTicks must be non-negative."
    )
  if config.gameInfoTicks < 0:
    raise newException(
      CrewriftError,
      "Config field gameInfoTicks must be non-negative."
    )
  if config.voteTimerTicks <= 0:
    raise newException(
      CrewriftError,
      "Config field voteTimerTicks must be positive."
    )
  if config.connectTimeoutTicks < 0:
    raise newException(
      CrewriftError,
      "Config field connectTimeoutTicks must be non-negative."
    )
  if config.disconnectTimeoutTicks < 0:
    raise newException(
      CrewriftError,
      "Config field disconnectTimeoutTicks must be non-negative."
    )
  if config.messageCooldownTicks < 0:
    raise newException(
      CrewriftError,
      "Config field messageCooldownTicks must be non-negative."
    )
  if config.killCooldownTicks < 0 or config.gameOverTicks < 0 or
      config.voteResultTicks < 0 or config.maxTicks < 0 or
      config.maxGames < 0:
      raise newException(
        CrewriftError,
        "Timer config fields must not be negative."
      )
  if config.slots.len > MaxPlayers:
    raise newException(
      CrewriftError,
      "Config field slots cannot have more than " & $MaxPlayers & " entries."
    )
  if config.closedRoster and config.slots.len < config.minPlayers:
    raise newException(
      CrewriftError,
      "Config field closedRoster requires at least minPlayers configured slots."
    )
  if config.closedRoster:
    for i, slot in config.slots:
      if slot.name.len == 0:
        raise newException(
          CrewriftError,
          "Config field closedRoster requires players[" & $i & "].name."
        )
      if slot.token.len == 0:
        raise newException(
          CrewriftError,
          "Config field closedRoster requires slots[" & $i & "].token."
        )
  for i in 0 ..< config.slots.len:
    for j in i + 1 ..< config.slots.len:
      if config.slots[i].name.len > 0 and
          config.slots[i].name == config.slots[j].name:
          raise newException(
            CrewriftError,
            "Config field players has duplicate name " & config.slots[i].name & "."
          )
      if config.slots[i].token.len > 0 and
          config.slots[i].token == config.slots[j].token:
          raise newException(
            CrewriftError,
            "Config field slots has duplicate token."
          )

proc update*(config: var GameConfig, jsonText: string) =
  ## Updates a gameplay config from a JSON object.
  if jsonText.len == 0:
    return
  var node: JsonNode
  try:
    node = fromJson(jsonText)
  except jsony.JsonError as e:
    raise newException(CrewriftError, "Could not parse config JSON: " & e.msg)
  if node.kind != JObject:
    raise newException(CrewriftError, "Config must be a JSON object.")
  node.readConfigInt("motionScale", config.motionScale)
  node.readConfigInt("accel", config.accel)
  node.readConfigInt("frictionNum", config.frictionNum)
  node.readConfigInt("frictionDen", config.frictionDen)
  node.readConfigInt("maxSpeed", config.maxSpeed)
  node.readConfigInt("stopThreshold", config.stopThreshold)
  node.readConfigInt("seed", config.seed)
  node.readConfigInt("speed", config.speed)
  node.readConfigBool("fastMode", config.fastMode)
  node.readConfigInt("killRange", config.killRange)
  node.readConfigInt("killCooldownTicks", config.killCooldownTicks)
  node.readConfigBool(
    "buttonResetsKillCooldowns",
    config.buttonResetsKillCooldowns
  )
  node.readConfigInt("gameInfoTicks", config.gameInfoTicks)
  node.readConfigInt("roleRevealTicks", config.roleRevealTicks)
  node.readConfigInt("taskCompleteTicks", config.taskCompleteTicks)
  node.readConfigInt("ventRange", config.ventRange)
  node.readConfigInt("reportRange", config.reportRange)
  node.readConfigInt("voteResultTicks", config.voteResultTicks)
  node.readConfigInt("connectTimeoutTicks", config.connectTimeoutTicks)
  node.readConfigInt("disconnectTimeoutTicks", config.disconnectTimeoutTicks)
  node.readConfigInt("minPlayers", config.minPlayers)
  let
    hasImposterCount = node.hasKey("imposterCount")
    hasAutoImposterCount =
      node.hasKey("autoImposterCount") or node.hasKey("imposterRatio")
  node.readConfigInt("imposterCount", config.imposterCount)
  node.readConfigBool("autoImposterCount", config.autoImposterCount)
  node.readConfigBool("imposterRatio", config.autoImposterCount)
  if hasImposterCount and not hasAutoImposterCount:
    config.autoImposterCount = false
  node.readConfigInt("startWaitTicks", config.startWaitTicks)
  node.readConfigInt("gameStartWaitTicks", config.startWaitTicks)
  node.readConfigInt("voteTimerTicks", config.voteTimerTicks)
  node.readConfigInt("messageCooldownTicks", config.messageCooldownTicks)
  node.readConfigInt("gameOverTicks", config.gameOverTicks)
  node.readConfigInt("maxTicks", config.maxTicks)
  node.readConfigInt("maxGameTicks", config.maxTicks)
  node.readConfigInt("maxGames", config.maxGames)
  node.readConfigInt("tasksPerPlayer", config.tasksPerPlayer)
  node.readConfigInt("buttonCalls", config.buttonCalls)
  node.readConfigInt("numberOfButtonCalls", config.buttonCalls)
  node.readConfigBool("showTaskArrows", config.showTaskArrows)
  node.readConfigBool("showTaskBubbles", config.showTaskBubbles)
  node.readConfigBool("showPlayerLabels", config.showPlayerLabels)
  node.readConfigString("map", config.mapPath)
  node.readConfigString("mapPath", config.mapPath)
  node.readConfigSlots(config.slots)
  node.readConfigBool("closedRoster", config.closedRoster)
  node.readConfigTokens(config.slots, config.closedRoster)
  node.readConfigPlayers(config.slots)
  config.validate()

proc timeGameSeed*(): int =
  ## Returns a positive game seed derived from wall-clock time.
  result = int(epochTime() * 1000) mod RandomSeedMod
  if result < 0:
    result += RandomSeedMod

proc resolveRandomSeed*(config: var GameConfig) =
  ## Replaces the random seed sentinel with a concrete seed.
  if config.seed == RandomSeedSentinel:
    config.seed = timeGameSeed()

proc slotRoleText(slot: PlayerSlotConfig): string =
  ## Returns a JSON role string for one slot.
  if not slot.hasRole:
    return ""
  case slot.role
  of Crewmate:
    "crew"
  of Imposter:
    "imposter"

proc slotColorText(slot: PlayerSlotConfig): string =
  ## Returns a JSON color string for one slot.
  if not slot.hasColor:
    return ""
  playerColorText(slot.color)

proc configJson*(config: GameConfig): string =
  ## Returns the complete replay JSON for a gameplay config.
  var
    players = newJArray()
    slots = newJArray()
    tokens = newJArray()
    includePlayers = false
  for slot in config.slots:
    var item = newJObject()
    if slot.name.len > 0:
      includePlayers = true
    tokens.add(%slot.token)
    players.add(%*{"name": slot.name})
    if slot.hasRole:
      item["role"] = %slot.slotRoleText()
    if slot.hasColor:
      item["color"] = %slot.slotColorText()
    slots.add(item)
  var node = %*{
    "motionScale": config.motionScale,
    "accel": config.accel,
    "frictionNum": config.frictionNum,
    "frictionDen": config.frictionDen,
    "maxSpeed": config.maxSpeed,
    "stopThreshold": config.stopThreshold,
    "seed": config.seed,
    "speed": config.speed,
    "fastMode": config.fastMode,
    "killRange": config.killRange,
    "killCooldownTicks": config.killCooldownTicks,
    "buttonResetsKillCooldowns": config.buttonResetsKillCooldowns,
    "gameInfoTicks": config.gameInfoTicks,
    "roleRevealTicks": config.roleRevealTicks,
    "taskCompleteTicks": config.taskCompleteTicks,
    "ventRange": config.ventRange,
    "reportRange": config.reportRange,
    "voteResultTicks": config.voteResultTicks,
    "connectTimeoutTicks": config.connectTimeoutTicks,
    "disconnectTimeoutTicks": config.disconnectTimeoutTicks,
    "minPlayers": config.minPlayers,
    "imposterCount": config.imposterCount,
    "autoImposterCount": config.autoImposterCount,
    "startWaitTicks": config.startWaitTicks,
    "voteTimerTicks": config.voteTimerTicks,
    "messageCooldownTicks": config.messageCooldownTicks,
    "gameOverTicks": config.gameOverTicks,
    "maxTicks": config.maxTicks,
    "maxGameTicks": config.maxTicks,
    "maxGames": config.maxGames,
    "tasksPerPlayer": config.tasksPerPlayer,
    "buttonCalls": config.buttonCalls,
    "mapPath": config.mapPath,
    "closedRoster": config.closedRoster,
    "showTaskArrows": config.showTaskArrows,
    "showTaskBubbles": config.showTaskBubbles,
    "showPlayerLabels": config.showPlayerLabels,
    "tokens": tokens,
    "slots": slots
  }
  if includePlayers:
    node["players"] = players
  $node

proc ratioImposterCount*(playerCount: int): int =
  ## Returns the default impostor count for a player count.
  if playerCount < 5:
    return 0
  (playerCount - 3) div 2

proc effectiveImposterCount*(config: GameConfig, playerCount: int): int =
  ## Returns the active impostor count for a config and player count.
  let desired =
    if config.autoImposterCount:
      ratioImposterCount(playerCount)
    else:
      config.imposterCount
  min(desired, max(0, playerCount - 1))

proc lobbyIsStarting*(sim: SimServer): bool =
  ## Returns whether the lobby is in the start countdown.
  sim.players.len >= sim.config.minPlayers

proc lobbyStartTicksRemaining*(sim: SimServer): int =
  ## Returns ticks left before the lobby starts the game.
  if not sim.lobbyIsStarting() or sim.config.startWaitTicks <= 0:
    return 0
  if sim.startWaitTimer > 0:
    sim.startWaitTimer
  else:
    sim.config.startWaitTicks

proc lobbyStartSecondsRemaining*(sim: SimServer): int =
  ## Returns visible seconds left before the lobby starts the game.
  let ticks = sim.lobbyStartTicksRemaining()
  if ticks <= 0:
    return 0
  max(1, (ticks + TargetFps - 1) div TargetFps)

proc roleText(role: PlayerRole): string =
  ## Returns the readable role name.
  case role
  of Crewmate:
    "crew"
  of Imposter:
    "imposter"

proc playerText(sim: SimServer, playerIndex: int): string =
  ## Returns the readable player color for one player index.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return "unknown"
  playerColorText(sim.players[playerIndex].color)

proc meetingCallCallerIndex*(sim: SimServer): int =
  ## Returns the current meeting caller index if that player still exists.
  let index = sim.voteState.callerIndex
  if index >= 0 and index < sim.players.len:
    return index
  -1

proc meetingCallBodyIndex*(sim: SimServer): int =
  ## Returns the player index for the reported body if it still exists.
  for i in 0 ..< sim.players.len:
    if sim.players[i].joinOrder == sim.voteState.bodySlotId:
      return i
  if sim.voteState.bodyColor == 255'u8:
    return -1
  for i in 0 ..< sim.players.len:
    if sim.players[i].color == sim.voteState.bodyColor:
      return i
  -1

proc taskIdsText(tasks: openArray[int]): string =
  ## Returns a compact comma-separated task id list.
  for i, task in tasks:
    if i > 0:
      result.add ","
    result.add $task

proc requiredLobbyPlayers(sim: SimServer): int =
  ## Returns the player count required before the lobby can start.
  if sim.config.closedRoster and sim.config.slots.len > 0:
    return sim.config.slots.len
  sim.config.minPlayers

proc logGameEvent(sim: SimServer, text: string) =
  ## Writes one game event to stdout for Docker logs.
  if sim.gameEventLoggingEnabled:
    echo text

proc logTaskAssignments(
  sim: SimServer,
  crew: openArray[int],
  assignments: openArray[taskAssignments.TaskAssignment]
) =
  ## Logs a compact table of crewmate tasks and route distances.
  if crew.len == 0:
    return
  sim.logGameEvent("crewmate tasks:")
  sim.logGameEvent("slot  color       path  tasks")
  sim.logGameEvent("----  ----------  ----  ----------------")
  for i, playerIndex in crew:
    let assignment = assignments[i]
    sim.logGameEvent(
      align($sim.players[playerIndex].joinOrder, 4) & "  " &
      align(sim.playerText(playerIndex), 10) & "  " &
      align($assignment.routeCost, 4) & "  " &
      assignment.taskIds.taskIdsText()
    )

proc voteTargetText(sim: SimServer, vote: int): string =
  ## Returns a readable vote target.
  if vote == -2:
    return "skip"
  if vote >= 0 and vote < sim.players.len:
    return sim.playerText(vote)
  "unknown"

proc logVoteResults(
  sim: SimServer,
  counts: openArray[int],
  skipVotes,
  timeoutVotes: int
) =
  ## Logs authoritative vote tallies before resolving the vote.
  sim.logGameEvent("vote results:")
  sim.logGameEvent("target      votes")
  sim.logGameEvent("----------  -----")
  for i, count in counts:
    sim.logGameEvent(
      align(sim.playerText(i), 10) & "  " & align($count, 5)
    )
  sim.logGameEvent(
    align("skip", 10) & "  " & align($skipVotes, 5)
  )
  sim.logGameEvent(
    align("timeout", 10) & "  " & align($timeoutVotes, 5)
  )
  sim.logGameEvent(
    align("skip total", 10) & "  " & align($(skipVotes + timeoutVotes), 5)
  )

proc logLobbyWaiting(sim: var SimServer) =
  ## Logs waiting-for-player state when it changes.
  let
    required = sim.requiredLobbyPlayers()
    needed = max(0, required - sim.players.len)
    players = sim.players.len
  if players == sim.lastLobbyPlayersLogged and
      needed == sim.lastLobbyNeededLogged:
      return
  sim.lastLobbyPlayersLogged = players
  sim.lastLobbyNeededLogged = needed
  sim.lastLobbySecondsLogged = -1
  sim.logGameEvent(
    "waiting for players: " & $players & "/" &
      $required & ", need " & $needed & " more"
  )

proc logLobbyCountdown(sim: var SimServer) =
  ## Logs the lobby countdown once per visible second.
  let seconds = sim.lobbyStartSecondsRemaining()
  if seconds <= 0 or seconds == sim.lastLobbySecondsLogged:
    return
  sim.lastLobbySecondsLogged = seconds
  sim.logGameEvent("game starting in " & $seconds)

proc lobbyIconStartY*(sim: SimServer): int =
  ## Returns the lobby icon row y coordinate.
  if sim.lobbyIsStarting(): 32 else: 26

proc mapIndex*(x, y: int): int {.inline.} =
  ## Implements the original map Index rule.
  y * MapWidth + x

proc mixHash(hash: var uint64, value: uint64) =
  ## Mixes one integer into a deterministic FNV-1a hash.
  hash = hash xor value
  hash *= 1099511628211'u64

proc mixHashInt(hash: var uint64, value: int) =
  ## Mixes one signed integer into a deterministic hash.
  hash.mixHash(cast[uint64](int64(value)))

proc mixHashBool(hash: var uint64, value: bool) =
  ## Mixes one boolean into a deterministic hash.
  hash.mixHashInt(ord(value))

proc gameHash*(sim: SimServer): uint64 =
  ## Returns a deterministic hash of gameplay state.
  result = 14695981039346656037'u64
  result.mixHashInt(sim.tickCount)
  result.mixHashInt(ord(sim.phase))
  result.mixHashInt(ord(sim.winner))
  result.mixHashInt(sim.gameOverTimer)
  result.mixHashInt(sim.roleRevealTimer)
  result.mixHashInt(sim.gameStartTick)
  result.mixHashInt(sim.startWaitTimer)
  result.mixHashBool(sim.timeLimitReached)
  result.mixHashBool(sim.needsReregister)
  result.mixHashInt(sim.nextJoinOrder)
  result.mixHashInt(sim.players.len)
  for player in sim.players:
    result.mixHashInt(player.x)
    result.mixHashInt(player.y)
    result.mixHashInt(player.homeX)
    result.mixHashInt(player.homeY)
    result.mixHashInt(player.velX)
    result.mixHashInt(player.velY)
    result.mixHashInt(player.carryX)
    result.mixHashInt(player.carryY)
    result.mixHashInt(player.lastMoveTick)
    result.mixHashBool(player.flipH)
    result.mixHashInt(ord(player.role))
    result.mixHashBool(player.alive)
    result.mixHashBool(player.connected)
    result.mixHashInt(player.disconnectTick)
    result.mixHashInt(player.killCooldown)
    result.mixHashInt(player.joinOrder)
    result.mixHashInt(int(player.color))
    result.mixHashInt(player.taskProgress)
    result.mixHashInt(player.activeTask)
    result.mixHashInt(player.tasksRewarded)
    result.mixHashInt(player.ventCooldown)
    result.mixHashInt(player.buttonCallsUsed)
    result.mixHashInt(player.lastChatTick)
    result.mixHashInt(player.reward)
    result.mixHashInt(player.assignedTasks.len)
    for task in player.assignedTasks:
      result.mixHashInt(task)
  result.mixHashInt(sim.bodies.len)
  for body in sim.bodies:
    result.mixHashInt(body.x)
    result.mixHashInt(body.y)
    result.mixHashInt(int(body.color))
    result.mixHashInt(body.slotId)
  result.mixHashInt(sim.tasks.len)
  for task in sim.tasks:
    result.mixHashInt(task.completed.len)
    for done in task.completed:
      result.mixHashBool(done)
  result.mixHashInt(sim.voteState.votes.len)
  for vote in sim.voteState.votes:
    result.mixHashInt(vote)
  result.mixHashInt(sim.voteState.cursor.len)
  for cursor in sim.voteState.cursor:
    result.mixHashInt(cursor)
  result.mixHashInt(sim.voteState.resultTimer)
  result.mixHashInt(sim.voteState.voteTimer)
  result.mixHashInt(sim.voteState.ejectedPlayer)

proc isWalkable*(sim: SimServer, x, y: int): bool =
  ## Checks a simulation position against the selected navigation floor.
  if x < 0 or y < 0 or x >= MapWidth or y >= MapHeight:
    return false
  sim.walkMask[mapIndex(x, y)]

proc canOccupy*(sim: SimServer, x, y: int): bool =
  ## Checks the player footprint against the selected navigation floor.
  for dy in 0 ..< CollisionH:
    for dx in 0 ..< CollisionW:
      if not sim.isWalkable(x + dx, y + dy):
        return false
  true

proc connectedTiles*(sim: SimServer, x, y, nx, ny: int): bool =
  ## Checks the audited connection between two cardinal navigation tiles.
  if sim.blockedEdges.len == 0:
    return true
  const
    Columns = (MapWidth + PixelsPerTile - 1) div PixelsPerTile
    Rows = (MapHeight + PixelsPerTile - 1) div PixelsPerTile
  if x < 0 or y < 0 or nx < 0 or ny < 0 or
    x >= Columns or nx >= Columns or y >= Rows or ny >= Rows:
      return false
  if x == nx and y == ny:
    return true
  if abs(nx - x) + abs(ny - y) != 1:
    return false
  if y == ny:
    return (sim.blockedEdges[y * Columns + min(x, nx)] and 1) == 0
  (sim.blockedEdges[min(y, ny) * Columns + x] and 2) == 0

proc canStep*(sim: SimServer, x, y, nx, ny: int): bool =
  ## Checks floor occupancy and prevents crossing an audited mesh barrier.
  sim.canOccupy(nx, ny) and sim.connectedTiles(
    x div PixelsPerTile,
    y div PixelsPerTile,
    nx div PixelsPerTile,
    ny div PixelsPerTile
  )

proc homePosition*(sim: SimServer, index, total: int): tuple[x, y: int] =
  ## Returns one deterministic home position around the meeting button.
  let
    homeX = sim.gameMap.home.x
    homeY = sim.gameMap.home.y
    spawnRadius = 28
    n = max(1, total)
    angle = float(index) * 2.0 * 3.14159265 / float(n)
    px = homeX + int(float(spawnRadius) * cos(angle))
    py = homeY + int(float(spawnRadius) * sin(angle))
  if sim.canOccupy(px, py):
    return (px, py)
  for radius in 1 .. 32:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        if abs(dx) != radius and abs(dy) != radius:
          continue
        if sim.canOccupy(px + dx, py + dy):
          return (px + dx, py + dy)
  raise newException(CrewriftError, "No walkable Bridge spawn position.")

proc resetPlayerToHome*(sim: var SimServer, playerIndex: int) =
  ## Moves one player back to its saved meeting home position.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  sim.players[playerIndex].x = sim.players[playerIndex].homeX
  sim.players[playerIndex].y = sim.players[playerIndex].homeY
  sim.players[playerIndex].velX = 0
  sim.players[playerIndex].velY = 0
  sim.players[playerIndex].carryX = 0
  sim.players[playerIndex].carryY = 0
  sim.players[playerIndex].lastMoveTick = sim.tickCount
  sim.players[playerIndex].activeTask = -1
  sim.players[playerIndex].taskProgress = 0

proc arrangeHomePositions*(sim: var SimServer) =
  ## Saves and applies evenly spaced home positions for all players.
  var total = sim.players.len
  for player in sim.players:
    total = max(total, player.joinOrder + 1)
  for i in 0 ..< sim.players.len:
    let slot = sim.players[i].joinOrder
    let home = sim.homePosition(slot, total)
    sim.players[i].homeX = home.x
    sim.players[i].homeY = home.y
    sim.resetPlayerToHome(i)

proc findSpawn*(sim: SimServer): tuple[x, y: int] =
  ## Returns the next lobby spawn position.
  sim.homePosition(sim.players.len, sim.players.len + 1)

proc playerSlotLimit(config: GameConfig): int =
  ## Returns the number of slots players may occupy.
  if config.closedRoster: config.slots.len else: MaxPlayers

proc canAddPlayer*(sim: SimServer): bool =
  ## Returns whether the game has room for another player.
  sim.players.len < sim.config.playerSlotLimit()

proc playerLimitError(config: GameConfig): string =
  ## Returns a user-facing message for the current player cap.
  if config.closedRoster:
      let limit = config.playerSlotLimit()
      return "Configured roster is full (" & $limit &
        (if limit == 1: " player)." else: " players).")
  "can't do more than " & $MaxPlayers & " players."

proc slotConfig(config: GameConfig, slotIndex: int): PlayerSlotConfig =
  ## Returns one slot config or an empty config for missing entries.
  if slotIndex >= 0 and slotIndex < config.slots.len:
    config.slots[slotIndex]
  else:
    PlayerSlotConfig()

proc slotRestricted(config: GameConfig, slotIndex: int): bool =
  ## Returns true when a slot has identity restrictions.
  let slot = config.slotConfig(slotIndex)
  slot.name.len > 0 or slot.token.len > 0

proc slotAuthMatches(
  config: GameConfig,
  slotIndex: int,
  address,
  token: string
): bool =
  ## Returns true when a player satisfies one configured slot.
  let slot = config.slotConfig(slotIndex)
  if slot.name.len > 0 and address != slot.name:
    return false
  if slot.token.len > 0 and token != slot.token:
    return false
  true

proc hasConfiguredToken(config: GameConfig, token: string): bool =
  ## Returns true when a token matches any configured slot.
  for slot in config.slots:
    if slot.token.len > 0 and slot.token == token:
      return true
  false

proc hasConfiguredTokens(config: GameConfig): bool =
  ## Returns true when any slot has an auth token.
  for slot in config.slots:
    if slot.token.len > 0:
      return true
  false

proc validatePlayerSlot(
  config: GameConfig,
  slotIndex: int,
  address,
  token: string
) =
  ## Raises when a player does not satisfy one configured slot.
  let slot = config.slotConfig(slotIndex)
  if slot.name.len > 0 and address != slot.name:
    raise newException(
      CrewriftError,
      "Player name does not match configured slot " & $slotIndex & "."
    )
  if slot.token.len > 0 and token != slot.token:
    raise newException(
      CrewriftError,
      "Player token does not match configured slot " & $slotIndex & "."
    )

proc configuredPlayerName*(
  config: GameConfig,
  requestedSlot: int,
  token: string
): string =
  ## Returns the configured identity for a tokenized slot request.
  if token.len == 0:
    return ""
  if requestedSlot >= 0 and requestedSlot < config.slots.len:
    let slot = config.slots[requestedSlot]
    if slot.name.len > 0 and slot.token.len > 0 and slot.token == token:
      return slot.name
    return ""
  for slot in config.slots:
    if slot.name.len > 0 and slot.token.len > 0 and slot.token == token:
      return slot.name
  ""

proc playerJoinAllowed*(
  config: GameConfig,
  address: string,
  requestedSlot: int,
  token: string
): bool =
  ## Returns whether a player websocket request can pass configured slot auth.
  if requestedSlot >= config.playerSlotLimit():
    return false
  if token.len > 0 and config.hasConfiguredTokens() and
      not config.hasConfiguredToken(token):
      return false
  if requestedSlot >= 0:
    return config.slotAuthMatches(requestedSlot, address, token)
  for i in 0 ..< config.slots.len:
    let slot = config.slots[i]
    let matchedName = slot.name.len > 0 and slot.name == address
    let matchedToken =
      slot.token.len > 0 and token.len > 0 and slot.token == token
    if matchedName or matchedToken:
      return config.slotAuthMatches(i, address, token)
  not config.closedRoster

proc slotOccupied(sim: SimServer, slotIndex: int): bool =
  ## Returns true when a player already owns a slot.
  for player in sim.players:
    if player.joinOrder == slotIndex:
      return true
  false

proc matchingConfiguredSlot(
  sim: SimServer,
  address,
  token: string
): int =
  ## Returns a matching configured slot for a player or -1.
  for i in 0 ..< sim.config.slots.len:
    if sim.slotOccupied(i):
      continue
    let slot = sim.config.slots[i]
    let couldMatchName = slot.name.len > 0 and slot.name == address
    let couldMatchToken = slot.token.len > 0 and slot.token == token
    if (couldMatchName or couldMatchToken) and
        sim.config.slotAuthMatches(i, address, token):
        return i
  -1

proc conflictingConfiguredSlot(
  sim: SimServer,
  address,
  token: string
): int =
  ## Returns a configured slot matched by name or token but not both.
  for i in 0 ..< sim.config.slots.len:
    if sim.slotOccupied(i):
      continue
    let slot = sim.config.slots[i]
    let matchedName = slot.name.len > 0 and slot.name == address
    let matchedToken =
      slot.token.len > 0 and token.len > 0 and slot.token == token
    if (matchedName or matchedToken) and
        not sim.config.slotAuthMatches(i, address, token):
        return i
  -1

proc namedConfiguredSlot(sim: SimServer, address: string): int =
  ## Returns an open configured slot with a matching name.
  for i in 0 ..< sim.config.slots.len:
    if sim.slotOccupied(i):
      continue
    let slot = sim.config.slots[i]
    if slot.name.len > 0 and slot.name == address:
      return i
  -1

proc nextAutoSlot(sim: SimServer, address, token: string): int =
  ## Returns the next open unrestricted or matching slot.
  let slotLimit = sim.config.playerSlotLimit()
  for i in sim.nextJoinOrder ..< slotLimit:
    if sim.slotOccupied(i):
      continue
    if not sim.config.slotRestricted(i) or
        sim.config.slotAuthMatches(i, address, token):
        return i
  for i in 0 ..< sim.nextJoinOrder:
    if i >= slotLimit:
      break
    if sim.slotOccupied(i):
      continue
    if not sim.config.slotRestricted(i) or
        sim.config.slotAuthMatches(i, address, token):
        return i
  -1

proc advanceJoinOrder(sim: var SimServer) =
  ## Moves the auto-slot cursor to the next open slot.
  while sim.nextJoinOrder < MaxPlayers and
      sim.slotOccupied(sim.nextJoinOrder):
      inc sim.nextJoinOrder

proc resolvePlayerSlot*(
  sim: SimServer,
  address,
  token: string,
  requestedSlot: int
): int =
  ## Returns the slot a player should use or raises on rejection.
  if requestedSlot >= MaxPlayers:
    raise newException(
      CrewriftError,
      "Player slot must be between 0 and 15."
    )
  if token.len > 0 and sim.config.hasConfiguredTokens() and
      not sim.config.hasConfiguredToken(token):
      raise newException(CrewriftError, "Player token is not configured.")
  if requestedSlot >= 0:
    if requestedSlot >= sim.config.playerSlotLimit():
      raise newException(
        CrewriftError,
        "Player slot is outside configured roster."
      )
    if sim.slotOccupied(requestedSlot):
      raise newException(
        CrewriftError,
        "Player slot " & $requestedSlot & " is already occupied."
      )
    sim.config.validatePlayerSlot(requestedSlot, address, token)
    return requestedSlot
  result = sim.matchingConfiguredSlot(address, token)
  if result >= 0:
    return result
  let conflict = sim.conflictingConfiguredSlot(address, token)
  if conflict >= 0:
    raise newException(
      CrewriftError,
      "Player credentials do not match configured slot " & $conflict & "."
    )
  result = sim.nextAutoSlot(address, token)
  if result < 0:
    raise newException(CrewriftError, "No available player slot.")

proc nextPlayerSlot*(sim: SimServer): int =
  ## Returns the slot required for the next live player index.
  sim.players.len

proc resolveTrustedPlayerSlot(
  sim: SimServer,
  address: string,
  requestedSlot: int
): int =
  ## Returns a trusted replay slot without requiring the original token.
  if requestedSlot >= MaxPlayers:
    raise newException(
      CrewriftError,
      "Player slot must be between 0 and 15."
    )
  if requestedSlot >= 0:
    if requestedSlot >= sim.config.playerSlotLimit():
      raise newException(
        CrewriftError,
        "Player slot is outside configured roster."
      )
    if sim.slotOccupied(requestedSlot):
      raise newException(
        CrewriftError,
        "Player slot " & $requestedSlot & " is already occupied."
      )
    return requestedSlot
  result = sim.namedConfiguredSlot(address)
  if result >= 0:
    return result
  result = sim.nextAutoSlot(address, "")
  if result < 0:
    raise newException(CrewriftError, "No available player slot.")

proc rewardAccountIndex(sim: SimServer, address: string): int =
  ## Returns the reward account index for an address.
  for i in 0 ..< sim.rewardAccounts.len:
    if sim.rewardAccounts[i].address == address:
      return i
  -1

proc ensureRewardAccount(sim: var SimServer, address: string): int =
  ## Returns the reward account index, creating the account if needed.
  result = sim.rewardAccountIndex(address)
  if result < 0:
    sim.rewardAccounts.add RewardAccount(
      address: address,
      slotIndex: -1,
      reward: 0
    )
    result = sim.rewardAccounts.high

proc bindRewardAccountSlot(
  sim: var SimServer,
  accountIndex,
  slotIndex: int
) =
  ## Binds a reward account to the stable player slot for this match.
  if accountIndex < 0 or accountIndex >= sim.rewardAccounts.len:
    return
  for i in 0 ..< sim.rewardAccounts.len:
    if i != accountIndex and sim.rewardAccounts[i].slotIndex == slotIndex:
      sim.rewardAccounts[i].slotIndex = -1
  sim.rewardAccounts[accountIndex].slotIndex = slotIndex

proc rewardAccountIndexForSlot(sim: SimServer, slotIndex: int): int =
  ## Returns the newest reward account index for a player slot.
  if slotIndex < 0 or sim.rewardAccounts.len == 0:
    return -1
  for i in countdown(sim.rewardAccounts.high, 0):
    if sim.rewardAccounts[i].slotIndex == slotIndex:
      return i
  -1

proc playerIndexForSlot*(sim: SimServer, slotIndex: int): int =
  ## Returns the live player index for a player slot.
  for i in 0 ..< sim.players.len:
    if sim.players[i].joinOrder == slotIndex:
      return i
  -1

proc resultSlotName(sim: SimServer, slotIndex: int): string =
  ## Returns the stable result name for one player slot.
  let slot = sim.config.slotConfig(slotIndex)
  if slot.name.len > 0:
    return slot.name
  "player-" & $slotIndex

proc ensureRewardAccountForSlot(
  sim: var SimServer,
  slotIndex: int
): int =
  ## Returns the reward account index for one result slot.
  result = sim.rewardAccountIndexForSlot(slotIndex)
  if result >= 0:
    return
  result = sim.ensureRewardAccount(sim.resultSlotName(slotIndex))
  sim.bindRewardAccountSlot(result, slotIndex)

proc playerResultSlotCount(sim: SimServer): int =
  ## Returns the number of player slots represented in final results.
  result = sim.config.slots.len
  if sim.config.closedRoster:
    return
  for player in sim.players:
    result = max(result, player.joinOrder + 1)
  for account in sim.rewardAccounts:
    if account.slotIndex >= 0:
      result = max(result, account.slotIndex + 1)

proc playerAddressOccupied*(sim: SimServer, address: string): bool =
  ## Returns true when a player identity is already connected.
  for player in sim.players:
    if player.address == address:
      return true
  false

proc removePlayerAt*(sim: var SimServer, playerIndex: int) =
  ## Removes one live player and keeps index-keyed state aligned.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  sim.players.delete(playerIndex)
  for task in sim.tasks.mitems:
    if playerIndex < task.completed.len:
      task.completed.delete(playerIndex)
  if sim.phase in {MeetingCall, Voting, VoteResult}:
    if sim.voteState.callerIndex == playerIndex:
      sim.voteState.callerIndex = -1
    elif sim.voteState.callerIndex > playerIndex:
      dec sim.voteState.callerIndex
  if sim.phase in {Voting, VoteResult}:
    if playerIndex < sim.voteState.votes.len:
      sim.voteState.votes.delete(playerIndex)
    if playerIndex < sim.voteState.cursor.len:
      sim.voteState.cursor.delete(playerIndex)
    let skipIndex = sim.players.len
    for vote in sim.voteState.votes.mitems:
      if vote > playerIndex:
        dec vote
      if vote > skipIndex:
        vote = -2
    for cursor in sim.voteState.cursor.mitems:
      if cursor > playerIndex:
        dec cursor
      if cursor > skipIndex:
        cursor = skipIndex

proc addPlayer*(
  sim: var SimServer,
  address: string,
  requestedSlot = -1,
  token = "",
  trusted = false
): int =
  ## Adds one player, optionally validating and using a requested slot.
  if not sim.canAddPlayer():
    raise newException(CrewriftError, sim.config.playerLimitError())
  if sim.playerAddressOccupied(address):
    raise newException(
      CrewriftError,
      "Player name is already connected."
    )
  let
    order =
      if trusted:
        sim.resolveTrustedPlayerSlot(address, requestedSlot)
      else:
        sim.resolvePlayerSlot(address, token, requestedSlot)
    nextSlot = sim.nextPlayerSlot()
  if not trusted and order != nextSlot:
    raise newException(
      CrewriftError,
      "Player slot " & $order & " cannot join before slot " &
        $nextSlot & "."
    )
  let
    slot = sim.config.slotConfig(order)
    spawn = sim.homePosition(order, max(sim.players.len + 1, order + 1))
    color =
      if slot.hasColor:
        slot.color
      else:
        PlayerColors[order mod PlayerColors.len]
    accountIndex = sim.ensureRewardAccount(address)
  sim.bindRewardAccountSlot(accountIndex, order)
  sim.rewardAccounts[accountIndex].hasRole = false
  sim.rewardAccounts[accountIndex].won = false
  sim.rewardAccounts[accountIndex].abandoned = false
  sim.players.add Player(
    x: spawn.x,
    y: spawn.y,
    homeX: spawn.x,
    homeY: spawn.y,
    role: Crewmate,
    alive: true,
    connected: true,
    disconnectTick: -1,
    killCooldown: sim.config.killCooldownTicks,
    joinOrder: order,
    address: address,
    color: color,
    lastChatTick: sim.tickCount - sim.config.messageCooldownTicks,
    lastMoveTick: sim.tickCount,
    activeTask: -1,
    reward: sim.rewardAccounts[accountIndex].reward
  )
  sim.advanceJoinOrder()
  sim.arrangeHomePositions()
  for task in sim.tasks.mitems:
    task.completed.add(false)
  sim.players.high

proc hasTask*(player: Player, taskIdx: int): bool =
  ## Implements the original has Task rule.
  for t in player.assignedTasks:
    if t == taskIdx:
      return true
  false

proc addReward*(sim: var SimServer, playerIndex, amount: int) =
  ## Adds accumulated reward to a player and its address account.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let address = sim.players[playerIndex].address
  let index = sim.ensureRewardAccount(address)
  sim.bindRewardAccountSlot(index, sim.players[playerIndex].joinOrder)
  sim.rewardAccounts[index].reward += amount
  sim.players[playerIndex].reward = sim.rewardAccounts[index].reward

proc rewardAccountForPlayer(
  sim: var SimServer,
  playerIndex: int
): int =
  ## Returns the reward account index for a player, creating it if missing.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return -1
  let address = sim.players[playerIndex].address
  result = sim.ensureRewardAccount(address)
  sim.bindRewardAccountSlot(result, sim.players[playerIndex].joinOrder)

proc recordGameRoleAssigned*(
  sim: var SimServer,
  playerIndex: int
) =
  ## Increments the lifetime role-assignment counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  sim.rewardAccounts[index].role = sim.players[playerIndex].role
  sim.rewardAccounts[index].hasRole = true
  sim.rewardAccounts[index].won = false
  sim.rewardAccounts[index].abandoned = false
  if sim.players[playerIndex].role == Imposter:
    inc sim.rewardAccounts[index].gamesImposter
  else:
    inc sim.rewardAccounts[index].gamesCrewmate

proc recordGameAbandon*(sim: var SimServer, playerIndex: int) =
  ## Marks a player as abandoned for the current game.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  sim.rewardAccounts[index].abandoned = true

proc recordGameWin*(sim: var SimServer, playerIndex: int) =
  ## Increments the lifetime per-role win counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  sim.rewardAccounts[index].won = true
  if sim.players[playerIndex].role == Imposter:
    inc sim.rewardAccounts[index].winsImposter
  else:
    inc sim.rewardAccounts[index].winsCrewmate

proc recordKill*(sim: var SimServer, playerIndex: int) =
  ## Increments the lifetime kill counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  inc sim.rewardAccounts[index].kills

proc recordTask*(sim: var SimServer, playerIndex: int) =
  ## Increments the lifetime task-completion counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  inc sim.rewardAccounts[index].tasks

proc recordVotePlayer*(sim: var SimServer, playerIndex: int) =
  ## Increments the lifetime player-vote counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  inc sim.rewardAccounts[index].votePlayers

proc recordVoteSkip*(sim: var SimServer, playerIndex: int) =
  ## Increments the lifetime explicit skip-vote counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  inc sim.rewardAccounts[index].voteSkip

proc recordVoteTimeout*(sim: var SimServer, playerIndex: int) =
  ## Increments the lifetime vote-timeout counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  inc sim.rewardAccounts[index].voteTimeout

proc recordConnectTimeout*(sim: var SimServer, slotIndex: int) =
  ## Marks one slot as missing the initial connection deadline.
  if slotIndex < 0 or slotIndex >= sim.config.playerSlotLimit():
    return
  let index = sim.ensureRewardAccountForSlot(slotIndex)
  if index < 0:
    return
  inc sim.rewardAccounts[index].connectTimeout
  sim.rewardAccounts[index].reward = ConnectionTimeoutPenalty
  sim.rewardAccounts[index].won = false

proc recordDisconnectTimeout*(sim: var SimServer, playerIndex: int) =
  ## Marks one player as missing the reconnect deadline.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  inc sim.rewardAccounts[index].disconnectTimeout
  sim.rewardAccounts[index].reward = ConnectionTimeoutPenalty
  sim.rewardAccounts[index].won = false
  sim.players[playerIndex].reward = ConnectionTimeoutPenalty

proc canGraceDisconnect*(sim: SimServer, playerIndex: int): bool =
  ## Returns true when one socket close should start reconnect grace.
  playerIndex >= 0 and playerIndex < sim.players.len and
    sim.phase in {GameInfo, RoleReveal, Playing, MeetingCall, Voting,
      VoteResult} and
    sim.config.disconnectTimeoutTicks > 0

proc markPlayerDisconnected*(sim: var SimServer, playerIndex: int) =
  ## Starts the reconnect grace timer for one live player.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if not sim.players[playerIndex].connected:
    return
  sim.players[playerIndex].connected = false
  sim.players[playerIndex].disconnectTick = sim.tickCount
  sim.recordGameAbandon(playerIndex)
  sim.logGameEvent("disconnected: " & sim.playerText(playerIndex))

proc markPlayerConnected*(sim: var SimServer, playerIndex: int) =
  ## Clears the reconnect grace timer for one live player.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  sim.players[playerIndex].connected = true
  sim.players[playerIndex].disconnectTick = -1
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index >= 0:
    sim.rewardAccounts[index].abandoned = false
  sim.logGameEvent("reconnected: " & sim.playerText(playerIndex))

proc reconnectPlayerIndex*(
  sim: SimServer,
  address,
  token: string,
  requestedSlot: int
): int =
  ## Returns the disconnected player index matching one reconnect request.
  for i, player in sim.players:
    if player.connected:
      continue
    if requestedSlot >= 0 and requestedSlot != player.joinOrder:
      continue
    if requestedSlot < 0 and player.address != address:
      continue
    if not sim.config.slotAuthMatches(player.joinOrder, address, token):
      continue
    return i
  -1

proc playerResultsJson*(sim: SimServer): string =
  ## Returns final player rewards and win states as JSON.
  var
    resultSlots: seq[int] = @[]
    names = newJArray()
    scores = newJArray()
    win = newJArray()
    tasksList = newJArray()
    killsList = newJArray()
    imposterList = newJArray()
    crewList = newJArray()
    votePlayersList = newJArray()
    voteSkipList = newJArray()
    voteTimeoutList = newJArray()
    connectTimeoutList = newJArray()
    disconnectTimeoutList = newJArray()
    results = newJObject()
  for slotIndex in 0 ..< sim.playerResultSlotCount():
    resultSlots.add(slotIndex)
  for slotIndex in resultSlots:
    let
      playerIndex = sim.playerIndexForSlot(slotIndex)
      accountIndex =
        if playerIndex >= 0:
          sim.rewardAccountIndex(sim.players[playerIndex].address)
        else:
          sim.rewardAccountIndexForSlot(slotIndex)
      slotConfig = sim.config.slotConfig(slotIndex)
    var
      name =
        if slotConfig.name.len > 0:
          slotConfig.name
        else:
          "player-" & $slotIndex
      reward = 0
      playerRole = Crewmate
      hasRole = false
      playerWon = false
      tasks = 0
      kills = 0
      votePlayers = 0
      voteSkip = 0
      voteTimeout = 0
      connectTimeout = 0
      disconnectTimeout = 0
    if accountIndex >= 0:
      let account = sim.rewardAccounts[accountIndex]
      name = account.address
      reward = account.reward
      playerRole = account.role
      hasRole = account.hasRole
      playerWon = account.won
      tasks = account.tasks
      kills = account.kills
      votePlayers = account.votePlayers
      voteSkip = account.voteSkip
      voteTimeout = account.voteTimeout
      connectTimeout = account.connectTimeout
      disconnectTimeout = account.disconnectTimeout
    if playerIndex >= 0:
      let player = sim.players[playerIndex]
      name = player.address
      if accountIndex < 0:
        reward = player.reward
      playerRole = player.role
      hasRole = true
      playerWon = not sim.timeLimitReached and player.role == sim.winner
    if not hasRole and slotConfig.hasRole:
      playerRole = slotConfig.role
      hasRole = true
    names.add(%name)
    scores.add(%reward)
    win.add(%playerWon)
    tasksList.add(%tasks)
    killsList.add(%kills)
    imposterList.add(%(if hasRole and playerRole == Imposter: 1 else: 0))
    crewList.add(%(if hasRole and playerRole == Crewmate: 1 else: 0))
    votePlayersList.add(%votePlayers)
    voteSkipList.add(%voteSkip)
    voteTimeoutList.add(%voteTimeout)
    connectTimeoutList.add(%connectTimeout)
    disconnectTimeoutList.add(%disconnectTimeout)
  results["names"] = names
  results["scores"] = scores
  results["win"] = win
  results["tasks"] = tasksList
  results["kills"] = killsList
  results["imposter"] = imposterList
  results["crew"] = crewList
  results["vote_players"] = votePlayersList
  results["vote_skip"] = voteSkipList
  results["vote_timeout"] = voteTimeoutList
  results["connect_timeout"] = connectTimeoutList
  results["disconnect_timeout"] = disconnectTimeoutList
  $results

proc completeTask*(sim: var SimServer, playerIndex, taskIndex: int) =
  ## Marks one player task complete and awards task reward.
  if taskIndex < 0 or taskIndex >= sim.tasks.len:
    return
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if playerIndex >= sim.tasks[taskIndex].completed.len:
    return
  if playerIndex < sim.tasks[taskIndex].completed.len and
      sim.tasks[taskIndex].completed[playerIndex]:
      return
  sim.tasks[taskIndex].completed[playerIndex] = true
  sim.addReward(playerIndex, TaskReward)
  sim.recordTask(playerIndex)
  inc sim.players[playerIndex].tasksRewarded
  sim.players[playerIndex].lastMoveTick = sim.tickCount

proc completedTaskCount(sim: SimServer, playerIndex: int): int =
  ## Returns completed assigned tasks for one current player.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return 0
  for taskIndex in sim.players[playerIndex].assignedTasks:
    if taskIndex < 0 or taskIndex >= sim.tasks.len:
      continue
    if playerIndex >= sim.tasks[taskIndex].completed.len:
      continue
    if sim.tasks[taskIndex].completed[playerIndex]:
      inc result

proc settleCompletedTaskRewards(sim: var SimServer, playerIndex: int) =
  ## Awards any completed task flags that have not yet paid out.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let completed = sim.completedTaskCount(playerIndex)
  while sim.players[playerIndex].tasksRewarded < completed:
    sim.addReward(playerIndex, TaskReward)
    sim.recordTask(playerIndex)
    inc sim.players[playerIndex].tasksRewarded

proc settleAllCompletedTaskRewards(sim: var SimServer) =
  ## Settles task rewards before the match result is awarded.
  for i in 0 ..< sim.players.len:
    sim.settleCompletedTaskRewards(i)

proc enterPlaying(sim: var SimServer) =
  ## Starts active gameplay timing and movement accounting.
  sim.phase = Playing
  sim.gameStartTick = sim.tickCount
  for player in sim.players.mitems:
    player.lastMoveTick = sim.tickCount

proc enterRoleRevealOrPlaying(sim: var SimServer) =
  ## Enters role reveal, or active play when reveal is disabled.
  sim.gameInfoTimer = 0
  sim.roleRevealTimer = sim.config.roleRevealTicks
  if sim.roleRevealTimer > 0:
    sim.phase = RoleReveal
    sim.gameStartTick = -1
  else:
    sim.enterPlaying()

proc startGame*(sim: var SimServer, showInfo = false) =
  ## Assigns roles and tasks, then enters the first game phase.
  sim.logGameEvent(
    "game started: players=" & $sim.players.len &
      ", imposters=" & $sim.config.effectiveImposterCount(sim.players.len)
  )
  sim.arrangeHomePositions()
  let imposterCount = sim.config.effectiveImposterCount(sim.players.len)
  for player in sim.players.mitems:
    player.role = Crewmate
    player.assignedTasks = @[]
    player.tasksRewarded = 0
  var
    candidates: seq[int] = @[]
    fixedImposters = 0
  for i in 0 ..< sim.players.len:
    let slot = sim.config.slotConfig(sim.players[i].joinOrder)
    if slot.hasRole:
      sim.players[i].role = slot.role
      if slot.role == Imposter:
        inc fixedImposters
    else:
      candidates.add(i)
  for j in countdown(candidates.high, 1):
    let k = sim.rng.rand(j)
    swap(candidates[j], candidates[k])
  let randomImposters = min(
    max(0, imposterCount - fixedImposters),
    candidates.len
  )
  for i in 0 ..< randomImposters:
    sim.players[candidates[i]].role = Imposter
  for i in 0 ..< sim.players.len:
    sim.recordGameRoleAssigned(i)
  var
    crew: seq[int] = @[]
    taskRects: seq[taskAssignments.TaskRect] = @[]
  for i in 0 ..< sim.players.len:
    if sim.players[i].role == Crewmate:
      crew.add(i)
  for task in sim.tasks:
    taskRects.add taskAssignments.TaskRect(
      x: task.x,
      y: task.y,
      w: task.w,
      h: task.h
    )
  let taskDetails = taskAssignments.assignTaskDetails(
    taskRects,
    sim.walkMask,
    MapWidth,
    MapHeight,
    sim.gameMap.home.x,
    sim.gameMap.home.y,
    crew.len,
    sim.config.tasksPerPlayer,
    sim.rng
  )
  for i, playerIndex in crew:
    sim.players[playerIndex].assignedTasks = taskDetails[i].taskIds
  sim.logTaskAssignments(crew, taskDetails)
  for player in sim.players.mitems:
    player.lastMoveTick = sim.tickCount
  sim.gameTickCount = 0
  if showInfo and sim.config.gameInfoTicks > 0:
    sim.phase = GameInfo
    sim.gameInfoTimer = sim.config.gameInfoTicks
    sim.roleRevealTimer = 0
    sim.gameStartTick = -1
  else:
    sim.enterRoleRevealOrPlaying()
  sim.timeLimitReached = false
  sim.lastLobbyPlayersLogged = -1
  sim.lastLobbyNeededLogged = -1
  sim.lastLobbySecondsLogged = -1

proc signOf(value: int): int {.inline.} =
  ## Returns the sign of one integer.
  if value < 0:
    return -1
  if value > 0:
    return 1
  0

proc slideScanRadius(sim: SimServer, carry, velocity: int): int =
  ## Returns the perpendicular scan radius for blocked movement.
  let
    pending = abs(carry) div sim.config.motionScale
    speed = (
      abs(velocity) + sim.config.motionScale - 1
    ) div sim.config.motionScale
  clamp(max(1, max(pending, speed)), 1, MovementSlideMaxScan)

proc canSlideHorizontal(
  sim: SimServer,
  x, y, step, offset: int
): bool =
  ## Returns true when a horizontal step can slide by one offset.
  if offset == 0:
    return false
  let slideStep = signOf(offset)
  for i in 1 .. abs(offset):
    if not sim.canStep(
      x, y + slideStep * (i - 1), x, y + slideStep * i
    ):
      return false
  sim.canStep(x, y + offset, x + step, y + offset)

proc canSlideVertical(
  sim: SimServer,
  x, y, step, offset: int
): bool =
  ## Returns true when a vertical step can slide by one offset.
  if offset == 0:
    return false
  let slideStep = signOf(offset)
  for i in 1 .. abs(offset):
    if not sim.canStep(
      x + slideStep * (i - 1), y, x + slideStep * i, y
    ):
      return false
  sim.canStep(x + offset, y, x + offset, y + step)

proc trySlideOffset(
  sim: SimServer,
  player: var Player,
  step, offset: int,
  horizontal: bool
): bool =
  ## Tries one candidate slide offset for a blocked movement step.
  if horizontal:
    if not sim.canSlideHorizontal(player.x, player.y, step, offset):
      return false
    player.x += step
    player.y += offset
  else:
    if not sim.canSlideVertical(player.x, player.y, step, offset):
      return false
    player.x += offset
    player.y += step
  true

proc trySlideMove(
  sim: SimServer,
  player: var Player,
  step, radius, preferredSlide: int,
  horizontal: bool
): bool =
  ## Tries nearby slide offsets for one blocked movement step.
  if radius <= 0:
    return false
  let preferred = signOf(preferredSlide)
  for distance in 1 .. radius:
    if preferred != 0:
      if sim.trySlideOffset(
        player,
        step,
        preferred * distance,
        horizontal
      ):
          return true
      if sim.trySlideOffset(
        player,
        step,
        -preferred * distance,
        horizontal
      ):
          return true
    else:
      if sim.trySlideOffset(player, step, -distance, horizontal):
        return true
      if sim.trySlideOffset(player, step, distance, horizontal):
        return true
  false

proc applyMomentumAxis(
  sim: SimServer,
  player: var Player,
  carry: var int,
  velocity, preferredSlide: int,
  horizontal: bool
) =
  ## Applies one fixed-point movement axis with collision sliding.
  carry += velocity
  while abs(carry) >= sim.config.motionScale:
    let step = if carry < 0: -1 else: 1
    let
      nx = if horizontal: player.x + step else: player.x
      ny = if horizontal: player.y else: player.y + step
    if sim.canStep(player.x, player.y, nx, ny):
      if horizontal:
        player.x = nx
      else:
        player.y = ny
      carry -= step * sim.config.motionScale
    else:
      let radius = sim.slideScanRadius(carry, velocity)
      if sim.trySlideMove(
        player,
        step,
        radius,
        preferredSlide,
        horizontal
      ):
          carry -= step * sim.config.motionScale
      else:
        carry = 0
        break

proc distSq*(ax, ay, bx, by: int): int =
  ## Returns the squared pixel distance between two points.
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc actorColor*(colorIndex, tint: uint8): uint8 =
  ## Returns the final color for actor wildcard pixels.
  if colorIndex == TintColor:
    return tint
  if colorIndex == ShadeTintColor:
    return ShadowMap[tint and 0x0f]
  colorIndex

proc tryKill*(sim: var SimServer, killerIndex: int) =
  ## Kills the nearest eligible crewmate in range.
  let killer = sim.players[killerIndex]
  if killer.role != Imposter or not killer.alive:
    return
  if killer.killCooldown > 0:
    return
  let
    kx = killer.x + CollisionW div 2
    ky = killer.y + CollisionH div 2
    rangeSq = sim.config.killRange * sim.config.killRange
  var
    bestDist = high(int)
    bestTarget = -1
  for i in 0 ..< sim.players.len:
    if i == killerIndex or not sim.players[i].alive:
      continue
    if sim.players[i].role == Imposter:
      continue
    let
      tx = sim.players[i].x + CollisionW div 2
      ty = sim.players[i].y + CollisionH div 2
      d = distSq(kx, ky, tx, ty)
    if d <= rangeSq and d < bestDist:
      bestDist = d
      bestTarget = i
  if bestTarget >= 0:
    sim.logGameEvent(
      playerColorText(sim.players[bestTarget].color) &
        " killed by " & playerColorText(killer.color) & " (imposter)"
    )
    sim.players[bestTarget].alive = false
    sim.bodies.add Body(
      x: sim.players[bestTarget].x,
      y: sim.players[bestTarget].y,
      color: sim.players[bestTarget].color,
      slotId: sim.players[bestTarget].joinOrder,
      killerSlot: sim.players[killerIndex].joinOrder,
      killTick: sim.tickCount
    )
    sim.addReward(killerIndex, KillReward)
    sim.recordKill(killerIndex)
    sim.players[killerIndex].killCooldown = sim.config.killCooldownTicks

proc tryVent*(sim: var SimServer, playerIndex: int) =
  ## Teleport an imposter to the next vent in the same group.
  let p = sim.players[playerIndex]
  if p.role != Imposter or not p.alive:
    return
  if p.ventCooldown > 0:
    return
  let
    px = p.x + CollisionW div 2
    py = p.y + CollisionH div 2
    rangeSq = sim.config.ventRange * sim.config.ventRange
  for i in 0 ..< sim.vents.len:
    let v = sim.vents[i]
    let
      vx = v.x + v.w div 2
      vy = v.y + v.h div 2
    if distSq(px, py, vx, vy) <= rangeSq:
      var nextIdx = -1
      for j in 0 ..< sim.vents.len:
        if j == i:
          continue
        if sim.vents[j].group == v.group:
          if sim.vents[j].groupIndex == v.groupIndex + 1:
            nextIdx = j
            break
      if nextIdx < 0:
        for j in 0 ..< sim.vents.len:
          if sim.vents[j].group == v.group and
              sim.vents[j].groupIndex == 1:
              nextIdx = j
              break
      if nextIdx >= 0:
        let dest = sim.vents[nextIdx]
        sim.players[playerIndex].x =
          dest.x + dest.w div 2 - CollisionW div 2
        sim.players[playerIndex].y =
          dest.y + dest.h div 2 - CollisionH div 2
        sim.players[playerIndex].velX = 0
        sim.players[playerIndex].velY = 0
        sim.players[playerIndex].carryX = 0
        sim.players[playerIndex].carryY = 0
        sim.players[playerIndex].ventCooldown = 30
      return

proc startVoting(sim: var SimServer) =
  ## Opens the voting phase and initializes per-player vote state.
  sim.phase = Voting
  sim.voteState.callTimer = 0
  sim.chatMessages.setLen(0)
  let n = sim.players.len
  sim.voteState.votes = newSeq[int](n)
  sim.voteState.cursor = newSeq[int](n)
  sim.voteState.voteTimer = sim.config.voteTimerTicks
  sim.voteState.finalizeTimer = 0
  for i in 0 ..< n:
    sim.voteState.votes[i] = -1
    sim.players[i].lastChatTick =
      sim.tickCount - sim.config.messageCooldownTicks
    var firstAlive = 0
    for j in 0 ..< n:
      if sim.players[j].alive:
        firstAlive = j
        break
    sim.voteState.cursor[i] = firstAlive

proc startVote*(
  sim: var SimServer,
  kind = VoteCalledUnknown,
  callerIndex = -1,
  bodyColor = 255'u8,
  bodySlotId = -1
) =
  ## Starts a meeting-call interstitial and logs its cause.
  sim.voteState.callKind = kind
  sim.voteState.callerIndex = callerIndex
  sim.voteState.bodyColor = bodyColor
  sim.voteState.bodySlotId = bodySlotId
  sim.voteState.callTimer = MeetingCallTicks
  sim.voteState.resultTimer = 0
  sim.voteState.voteTimer = 0
  sim.voteState.finalizeTimer = 0
  sim.voteState.ejectedPlayer = -1
  sim.voteState.votes.setLen(0)
  sim.voteState.cursor.setLen(0)
  sim.chatMessages.setLen(0)
  case kind
  of VoteCalledBody:
    sim.logGameEvent(
      "vote called: " & sim.playerText(callerIndex) &
        " called body (" & playerColorText(bodyColor) & ")"
    )
  of VoteCalledButton:
    sim.logGameEvent(
      "vote called: " & sim.playerText(callerIndex) &
        " called emergency button"
    )
  of VoteCalledUnknown:
    sim.logGameEvent("vote called")
  sim.phase = MeetingCall
  if sim.gameMap.path == "map1":
    for i, player in sim.players:
      if player.alive:
        sim.resetPlayerToHome(i)

proc addVotingChat*(sim: var SimServer, playerIndex: int, message: string) =
  ## Adds one visible chat message while voting.
  if sim.phase != Voting:
    return
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if not sim.players[playerIndex].alive:
    return
  let cooldown = sim.config.messageCooldownTicks
  if cooldown > 0:
    let elapsed = sim.tickCount - sim.players[playerIndex].lastChatTick
    if elapsed < cooldown:
      return
  let text = cleanChatMessage(message)
  if text.len == 0:
    return
  sim.players[playerIndex].lastChatTick = sim.tickCount
  while sim.chatMessages.len >= VoteChatVisibleMessages:
    sim.chatMessages.delete(0)
  sim.chatMessages.add ChatMessage(
    slotId: sim.players[playerIndex].joinOrder,
    color: sim.players[playerIndex].color,
    text: text
  )
  sim.logGameEvent(
    "vote chat: " & sim.playerText(playerIndex) & ": " & text
  )

proc tryReport*(sim: var SimServer, reporterIndex: int, bodyLimit: int) =
  ## Starts a vote when a living player reports a nearby body.
  if sim.phase != Playing:
    return
  let p = sim.players[reporterIndex]
  if not p.alive:
    return
  let
    px = p.x + CollisionW div 2
    py = p.y + CollisionH div 2
    rangeSq = sim.config.reportRange * sim.config.reportRange
  for bi in 0 ..< bodyLimit:
    let body = sim.bodies[bi]
    let
      bx = body.x + CollisionW div 2
      by = body.y + CollisionH div 2
    if distSq(px, py, bx, by) <= rangeSq:
      sim.startVote(VoteCalledBody, reporterIndex, body.color, body.slotId)
      return

proc tryCallButton*(sim: var SimServer, callerIndex: int) =
  ## Starts a vote when a living player presses the meeting button.
  if sim.phase != Playing:
    return
  let p = sim.players[callerIndex]
  if not p.alive:
    return
  if p.buttonCallsUsed >= sim.config.buttonCalls:
    return
  let
    px = p.x + CollisionW div 2
    py = p.y + CollisionH div 2
    button = sim.gameMap.button
  if px >= button.x and px < button.x + button.w and
      py >= button.y and py < button.y + button.h:
      inc sim.players[callerIndex].buttonCallsUsed
      sim.startVote(VoteCalledButton, callerIndex)

proc containGhost(player: var Player) =
  ## Keeps ghost movement inside the map rectangle.
  let
    maxX = MapWidth - CollisionW
    maxY = MapHeight - CollisionH
  if player.x < 0:
    player.x = 0
    player.velX = max(player.velX, 0)
    player.carryX = 0
  elif player.x > maxX:
    player.x = maxX
    player.velX = min(player.velX, 0)
    player.carryX = 0
  if player.y < 0:
    player.y = 0
    player.velY = max(player.velY, 0)
    player.carryY = 0
  elif player.y > maxY:
    player.y = maxY
    player.velY = min(player.velY, 0)
    player.carryY = 0

proc applyGhostMovement*(
  sim: var SimServer,
  playerIndex: int,
  input: InputState
) =
  ## Implements the original apply Ghost Movement rule.
  template player: untyped = sim.players[playerIndex]
  var inputX = 0
  var inputY = 0
  if input.left: inputX -= 1
  if input.right: inputX += 1
  if input.up: inputY -= 1
  if input.down: inputY += 1

  if inputX != 0:
      player.velX = clamp(
        player.velX + inputX * sim.config.accel,
        -sim.config.maxSpeed,
        sim.config.maxSpeed
      )
  else:
    player.velX =
      (player.velX * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velX) < sim.config.stopThreshold:
      player.velX = 0

  if inputY != 0:
    player.velY = clamp(
      player.velY + inputY * sim.config.accel,
      -sim.config.maxSpeed,
      sim.config.maxSpeed
    )
  else:
    player.velY =
      (player.velY * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velY) < sim.config.stopThreshold:
      player.velY = 0

  if inputX < 0: player.flipH = true
  elif inputX > 0: player.flipH = false

  player.carryX += player.velX
  while abs(player.carryX) >= sim.config.motionScale:
    let step = if player.carryX < 0: -1 else: 1
    player.x += step
    player.carryX -= step * sim.config.motionScale
  player.carryY += player.velY
  while abs(player.carryY) >= sim.config.motionScale:
    let step = if player.carryY < 0: -1 else: 1
    player.y += step
    player.carryY -= step * sim.config.motionScale
  player.containGhost()

  if player.role == Crewmate and input.attack:
    let
      px = player.x + CollisionW div 2
      py = player.y + CollisionH div 2
    var inTask = -1
    for t in 0 ..< sim.tasks.len:
      if not player.hasTask(t): continue
      let task = sim.tasks[t]
      if playerIndex < task.completed.len and task.completed[playerIndex]:
        continue
      if px >= task.x and px < task.x + task.w and
          py >= task.y and py < task.y + task.h:
          inTask = t
          break
    if inTask >= 0 and inputX == 0 and inputY == 0:
      if player.activeTask != inTask:
        player.activeTask = inTask
        player.taskProgress = 0
      inc player.taskProgress
      if player.taskProgress >= sim.config.taskCompleteTicks:
        sim.completeTask(playerIndex, inTask)
        player.activeTask = -1
        player.taskProgress = 0
    else:
      player.activeTask = -1
      player.taskProgress = 0
  else:
    player.activeTask = -1
    player.taskProgress = 0

proc applyInput*(
  sim: var SimServer,
  playerIndex: int,
  input: InputState,
  prevInput: InputState,
  bodiesBeforeTick: int
) =
  ## Implements the original apply Input rule.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if not sim.players[playerIndex].alive:
    sim.applyGhostMovement(playerIndex, input)
    return
  template player: untyped = sim.players[playerIndex]

  var
    inputX = 0
    inputY = 0
  if input.left:
    inputX -= 1
  if input.right:
    inputX += 1
  if input.up:
    inputY -= 1
  if input.down:
    inputY += 1

  if inputX != 0:
    player.velX = clamp(
      player.velX + inputX * sim.config.accel,
      -sim.config.maxSpeed,
      sim.config.maxSpeed
    )
  else:
    player.velX =
      (player.velX * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velX) < sim.config.stopThreshold:
      player.velX = 0

  if inputY != 0:
    player.velY = clamp(
      player.velY + inputY * sim.config.accel,
      -sim.config.maxSpeed,
      sim.config.maxSpeed
    )
  else:
    player.velY =
      (player.velY * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velY) < sim.config.stopThreshold:
      player.velY = 0

  if inputX < 0:
    player.flipH = true
  elif inputX > 0:
    player.flipH = false

  let
    preferredSlideY =
      if inputY != 0:
        inputY
      else:
        signOf(player.velY)
    preferredSlideX =
      if inputX != 0:
        inputX
      else:
        signOf(player.velX)
  sim.applyMomentumAxis(
    player,
    player.carryX,
    player.velX,
    preferredSlideY,
    true
  )
  sim.applyMomentumAxis(
    player,
    player.carryY,
    player.velY,
    preferredSlideX,
    false
  )

  let freshB = input.b and not prevInput.b
  if freshB:
    if player.role == Imposter:
      sim.tryVent(playerIndex)

  if input.attack:
    let freshA = input.attack and not prevInput.attack
    if freshA:
      sim.tryReport(playerIndex, bodiesBeforeTick)
      if sim.phase != Playing:
        return
      sim.tryCallButton(playerIndex)
      if sim.phase != Playing:
        return
    if player.role == Imposter:
      if freshA:
        sim.tryKill(playerIndex)
    elif player.role == Crewmate:
      let
        px = player.x + CollisionW div 2
        py = player.y + CollisionH div 2
      var inTask = -1
      for t in 0 ..< sim.tasks.len:
        if not player.hasTask(t):
          continue
        let task = sim.tasks[t]
        if playerIndex < task.completed.len and task.completed[playerIndex]:
          continue
        if px >= task.x and px < task.x + task.w and
            py >= task.y and py < task.y + task.h:
            inTask = t
            break
      if inTask >= 0 and inputX == 0 and inputY == 0:
        if player.activeTask != inTask:
          player.activeTask = inTask
          player.taskProgress = 0
        inc player.taskProgress
        if player.taskProgress >= sim.config.taskCompleteTicks:
          sim.completeTask(playerIndex, inTask)
          player.activeTask = -1
          player.taskProgress = 0
      else:
        player.activeTask = -1
        player.taskProgress = 0
  else:
    player.activeTask = -1
    player.taskProgress = 0

proc allVotesCast*(sim: SimServer): bool =
  ## Implements the original all Votes Cast rule.
  for i in 0 ..< sim.players.len:
    if sim.players[i].alive and sim.voteState.votes[i] == -1:
      return false
  true

proc startVoteFinalizeTimer(sim: var SimServer) =
  ## Starts the short delay that keeps final vote dots visible.
  if sim.voteState.finalizeTimer <= 0:
    sim.voteState.finalizeTimer = VoteFinalizeTicks

proc tallyVotes*(sim: var SimServer, timedOut = false) =
  ## Counts the votes and moves to the vote-result phase.
  var counts = newSeq[int](sim.players.len)
  var
    skipVotes = 0
    timeoutVotes = 0
  for i in 0 ..< sim.players.len:
    if sim.players[i].alive:
      let v = sim.voteState.votes[i]
      if v >= 0 and v < counts.len:
        inc counts[v]
        sim.recordVotePlayer(i)
      elif v == -2:
        inc skipVotes
        sim.recordVoteSkip(i)
      elif v == -1:
        inc timeoutVotes
        sim.recordVoteTimeout(i)
        if timedOut:
          sim.addReward(i, VoteTimeoutPenalty)
  sim.logVoteResults(counts, skipVotes, timeoutVotes)
  var maxVotes = skipVotes + timeoutVotes
  var maxPlayer = -1
  var tied = false
  for i in 0 ..< counts.len:
    if counts[i] > maxVotes:
      maxVotes = counts[i]
      maxPlayer = i
      tied = false
    elif counts[i] == maxVotes and counts[i] > 0:
      tied = true
  if tied or maxVotes == 0 or maxPlayer < 0:
    sim.voteState.ejectedPlayer = -1
    sim.logGameEvent("vote ended: no one killed by vote")
  else:
    sim.voteState.ejectedPlayer = maxPlayer
    sim.logGameEvent(
      "vote ended: " & sim.playerText(maxPlayer) & " killed by vote"
    )
  sim.phase = VoteResult
  sim.voteState.finalizeTimer = 0
  sim.voteState.resultTimer = sim.config.voteResultTicks

proc voteResultResetsKillCooldowns(sim: SimServer): bool =
  ## Returns whether this vote result resets impostor kill cooldowns.
  case sim.voteState.callKind
  of VoteCalledButton:
    sim.config.buttonResetsKillCooldowns
  of VoteCalledBody, VoteCalledUnknown:
    true

proc applyVoteResult*(sim: var SimServer) =
  ## Applies one completed vote result to player and game state.
  let ej = sim.voteState.ejectedPlayer
  if ej >= 0 and ej < sim.players.len:
    sim.players[ej].alive = false
  sim.bodies.setLen(0)
  sim.chatMessages.setLen(0)
  sim.voteState.callTimer = 0
  let resetKillCooldowns = sim.voteResultResetsKillCooldowns()
  for i in 0 ..< sim.players.len:
    sim.resetPlayerToHome(i)
    if resetKillCooldowns and
        sim.players[i].alive and
        sim.players[i].role == Imposter:
        sim.players[i].killCooldown = sim.config.killCooldownTicks
  sim.phase = Playing

proc moveCursor*(sim: var SimServer, playerIndex: int, delta: int) =
  ## Implements the original move Cursor rule.
  let n = sim.players.len
  if n == 0:
    return
  let total = n + 1
  var cur = sim.voteState.cursor[playerIndex]
  for step in 1 .. total:
    cur = (cur + delta + total) mod total
    if cur == n or sim.players[cur].alive:
      break
  sim.voteState.cursor[playerIndex] = cur

proc hasUnfinishedTasks*(sim: SimServer, playerIndex: int): bool =
  ## Returns true when one player still has assigned tasks to finish.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if sim.players[playerIndex].role != Crewmate:
    return false
  for t in sim.players[playerIndex].assignedTasks:
    if t >= 0 and t < sim.tasks.len and
        playerIndex < sim.tasks[t].completed.len and
        not sim.tasks[t].completed[playerIndex]:
        return true
  false

proc applyStuckPenalty(sim: var SimServer, playerIndex: int) =
  ## Penalizes players who stop moving while tasks remain.
  if sim.phase != Playing:
    return
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.players[playerIndex].activeTask >= 0:
    return
  if not sim.hasUnfinishedTasks(playerIndex):
    return
  if sim.tickCount - sim.players[playerIndex].lastMoveTick < StuckPenaltyTicks:
    return
  sim.addReward(playerIndex, StuckPenalty)
  sim.players[playerIndex].lastMoveTick = sim.tickCount
  sim.logGameEvent("stuck penalty: " & sim.playerText(playerIndex))

proc trackMovementAndStuckPenalty(
  sim: var SimServer,
  playerIndex,
  oldX,
  oldY: int
) =
  ## Updates movement timers and applies idle task penalties.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.players[playerIndex].x != oldX or sim.players[playerIndex].y != oldY:
    sim.players[playerIndex].lastMoveTick = sim.tickCount
    return
  sim.applyStuckPenalty(playerIndex)

proc totalTasksRemaining*(sim: SimServer): int =
  ## Counts the unfinished assignments for all crewmates.
  for i in 0 ..< sim.players.len:
    if sim.players[i].role != Crewmate:
      continue
    for t in sim.players[i].assignedTasks:
      if t < sim.tasks.len and i < sim.tasks[t].completed.len and
          not sim.tasks[t].completed[i]:
          inc result

proc allTasksDone*(sim: SimServer): bool =
  ## Returns whether every crewmate assignment has been completed.
  sim.totalTasksRemaining() == 0

proc finishGame*(
  sim: var SimServer,
  winner: PlayerRole,
  timeLimitReached = false
) =
  ## Moves to game over and awards all winning players.
  if sim.phase == GameOver:
    return
  sim.settleAllCompletedTaskRewards()
  if timeLimitReached:
    sim.logGameEvent("draw: time limit reached")
  else:
    sim.logGameEvent(roleText(winner) & " win")
  sim.phase = GameOver
  sim.winner = winner
  sim.gameOverTimer = sim.config.gameOverTicks
  sim.timeLimitReached = timeLimitReached
  if timeLimitReached:
    return
  var awardedAccounts = newSeq[bool](sim.rewardAccounts.len)
  for i in 0 ..< sim.players.len:
    if sim.players[i].role == winner:
      let accountIndex = sim.rewardAccountForPlayer(i)
      if awardedAccounts.len < sim.rewardAccounts.len:
        awardedAccounts.setLen(sim.rewardAccounts.len)
      if accountIndex >= 0 and accountIndex < awardedAccounts.len:
        awardedAccounts[accountIndex] = true
      sim.addReward(i, WinReward)
      sim.recordGameWin(i)
  for i in 0 ..< sim.rewardAccounts.len:
    if i < awardedAccounts.len and awardedAccounts[i]:
      continue
    if not sim.rewardAccounts[i].hasRole or
      sim.rewardAccounts[i].role != winner:
        continue
    sim.rewardAccounts[i].reward += WinReward
    sim.rewardAccounts[i].won = true
    if winner == Imposter:
      inc sim.rewardAccounts[i].winsImposter
    else:
      inc sim.rewardAccounts[i].winsCrewmate

proc gameTicksElapsed*(sim: SimServer): int =
  ## Returns task-phase ticks elapsed in the current game.
  sim.gameTickCount

proc maxTicksReached(sim: SimServer): bool =
  ## Implements the original max Ticks Reached rule.
  sim.config.maxTicks > 0 and
    sim.phase in {Playing, MeetingCall, Voting, VoteResult} and
    sim.gameTicksElapsed() >= sim.config.maxTicks

proc checkMaxTicks(sim: var SimServer) =
  ## Implements the original check Max Ticks rule.
  if sim.maxTicksReached():
    sim.finishGame(Crewmate, timeLimitReached = true)

proc shouldAbortFiniteMatch*(sim: SimServer): bool =
  ## Returns true when a finite match cannot continue after roster loss.
  if sim.config.maxGames <= 0:
    return false
  if sim.phase == Lobby:
    if sim.config.closedRoster and sim.config.connectTimeoutTicks > 0:
      return false
    return sim.startWaitTimer > 0 and sim.players.len < sim.config.minPlayers
  sim.phase in {GameInfo, RoleReveal, Playing, MeetingCall, Voting,
    VoteResult} and
    sim.players.len == 0

proc checkWinCondition*(sim: var SimServer) =
  ## Implements the original check Win Condition rule.
  var
    hasImposters = false
    aliveCrewmates = 0
    aliveImposters = 0
  for p in sim.players:
    if p.role == Imposter:
      hasImposters = true
    if p.alive:
      if p.role == Crewmate:
        inc aliveCrewmates
      else:
        inc aliveImposters
  if hasImposters and aliveImposters == 0 and sim.players.len > 0:
    sim.finishGame(Crewmate)
  elif hasImposters and aliveImposters >= aliveCrewmates and
      sim.players.len > 0:
      sim.finishGame(Imposter)
  elif sim.allTasksDone() and sim.players.len > 0:
    sim.finishGame(Crewmate)

proc loadCrewriftMap*(path = ""): CrewriftMap =
  ## Loads authored markers or the original layout for older recordings.
  if path notin ["", "croatoan", "map1"]:
    raise newException(CrewriftError, "Unknown Crewrift map: " & path)
  try:
    result = (if path == "croatoan": MapJson else: Map1Json).
      fromJson(CrewriftMap)
    result.path = if path == "croatoan": "croatoan" else: "map1"
  except ValueError as error:
    raise newException(CrewriftError, "Invalid map metadata: " & error.msg)

proc initSimServer*(config: GameConfig): SimServer =
  ## Creates fixed-tick rules with collision derived from the selected floor.
  config.validate()
  var resolvedConfig = config
  resolvedConfig.resolveRandomSeed()
  result.config = resolvedConfig
  result.rng = initRand(resolvedConfig.seed)
  result.gameMap = loadCrewriftMap(config.mapPath)
  result.tasks = result.gameMap.tasks
  result.vents = result.gameMap.vents
  result.rooms = result.gameMap.rooms
  if result.gameMap.path == "map1":
    let
      rows = Map1Tiles.strip().splitLines()
      links = Map1Links.strip().splitLines()
      columns = (MapWidth + PixelsPerTile - 1) div PixelsPerTile
      depth = (MapHeight + PixelsPerTile - 1) div PixelsPerTile
    if rows.len != depth or links.len != depth:
      raise newException(CrewriftError, "Invalid map1 navigation height.")
    result.blockedEdges = newSeq[uint8](columns * depth)
    for y in 0 ..< depth:
      if rows[y].len != columns or links[y].len != columns:
        raise newException(CrewriftError, "Invalid map1 navigation width.")
      for x in 0 ..< columns:
        if links[y][x] notin {'0' .. '3'}:
          raise newException(CrewriftError, "Invalid map1 navigation link.")
        result.blockedEdges[y * columns + x] =
          uint8(ord(links[y][x]) - ord('0'))
    result.walkMask = newSeq[bool](MapWidth * MapHeight)
    result.wallMask = newSeq[bool](MapWidth * MapHeight)
    for y in 0 ..< MapHeight:
      for x in 0 ..< MapWidth:
        let index = mapIndex(x, y)
        result.walkMask[index] =
          rows[y div PixelsPerTile][x div PixelsPerTile] == '#'
        result.wallMask[index] = not result.walkMask[index]
  else:
    try:
      let
        walk = decodeImage(WalkPng)
        walls = decodeImage(WallsPng)
      if walk.width != MapWidth or walk.height != MapHeight or
        walls.width != MapWidth or walls.height != MapHeight:
          raise newException(CrewriftError, "Invalid Croatoan mask dimensions.")
      result.walkMask = newSeq[bool](MapWidth * MapHeight)
      result.wallMask = newSeq[bool](MapWidth * MapHeight)
      for i in 0 ..< result.walkMask.len:
        result.walkMask[i] = walk.data[i].r >= 128
        result.wallMask[i] = walls.data[i].r >= 128
    except PixieError as error:
      raise newException(CrewriftError, "Invalid Croatoan masks: " & error.msg)
  result.gameStartTick = -1
  result.gameEventLoggingEnabled = true
  result.voteState.callerIndex = -1
  result.voteState.bodyColor = 255
  result.voteState.bodySlotId = -1
  result.lastLobbyPlayersLogged = -1
  result.lastLobbyNeededLogged = -1
  result.lastLobbySecondsLogged = -1

proc resetToLobby*(sim: var SimServer) =
  ## Implements the original reset To Lobby rule.
  sim.phase = Lobby
  sim.bodies = @[]
  sim.chatMessages = @[]
  sim.players = @[]
  sim.nextJoinOrder = 0
  sim.tickCount = 0
  sim.gameStartTick = -1
  sim.gameTickCount = 0
  sim.startWaitTimer = 0
  sim.gameInfoTimer = 0
  sim.roleRevealTimer = 0
  sim.timeLimitReached = false
  sim.needsReregister = true
  sim.voteState.callKind = VoteCalledUnknown
  sim.voteState.callerIndex = -1
  sim.voteState.bodyColor = 255'u8
  sim.voteState.bodySlotId = -1
  sim.voteState.callTimer = 0
  sim.voteState.finalizeTimer = 0
  sim.lastLobbyPlayersLogged = -1
  sim.lastLobbyNeededLogged = -1
  sim.lastLobbySecondsLogged = -1
  for task in sim.tasks.mitems:
    task.completed = @[]
  for account in sim.rewardAccounts.mitems:
    account.hasRole = false
    account.won = false
    account.abandoned = false

proc connectTimeoutSlots(sim: SimServer): seq[int] =
  ## Returns closed-roster slots that missed the initial connect deadline.
  if not sim.config.closedRoster:
    return
  for slotIndex in 0 ..< sim.config.slots.len:
    let playerIndex = sim.playerIndexForSlot(slotIndex)
    if playerIndex < 0 or not sim.players[playerIndex].connected:
      result.add(slotIndex)

proc checkConnectTimeout(sim: var SimServer): bool =
  ## Ends the match as a draw if required slots do not connect in time.
  if sim.phase != Lobby or sim.config.connectTimeoutTicks <= 0:
    return false
  if sim.tickCount < sim.config.connectTimeoutTicks:
    return false
  let slots = sim.connectTimeoutSlots()
  if slots.len == 0:
    return false
  for slotIndex in slots:
    sim.recordConnectTimeout(slotIndex)
  sim.logGameEvent("connect timeout: slots " & slots.taskIdsText())
  sim.finishGame(Crewmate, timeLimitReached = true)
  true

proc checkDisconnectTimeout(sim: var SimServer): bool =
  ## Ends the match as a draw if disconnected players miss reconnect grace.
  if sim.phase notin {GameInfo, RoleReveal, Playing, MeetingCall, Voting,
      VoteResult} or
      sim.config.disconnectTimeoutTicks <= 0:
      return false
  var playerIndices: seq[int]
  for i, player in sim.players:
    if player.connected or player.disconnectTick < 0:
      continue
    if sim.tickCount - player.disconnectTick >=
        sim.config.disconnectTimeoutTicks:
        playerIndices.add(i)
  if playerIndices.len == 0:
    return false
  for playerIndex in playerIndices:
    sim.recordDisconnectTimeout(playerIndex)
  sim.logGameEvent("disconnect timeout: players " & playerIndices.taskIdsText())
  sim.finishGame(Crewmate, timeLimitReached = true)
  true

proc stepLobby(sim: var SimServer) =
  ## Advances the lobby start countdown.
  let required = sim.requiredLobbyPlayers()
  if sim.players.len < required:
    sim.startWaitTimer = 0
    sim.logLobbyWaiting()
    return
  if sim.config.startWaitTicks <= 0:
    sim.startGame()
    return
  if sim.startWaitTimer <= 0:
    sim.startWaitTimer = sim.config.startWaitTicks
  dec sim.startWaitTimer
  if sim.startWaitTimer <= 0:
    sim.startGame(showInfo = true)
  else:
    sim.logLobbyCountdown()

proc step*(
  sim: var SimServer,
  inputs: openArray[InputState],
  prevInputs: openArray[InputState]
) =
  ## Implements the original step rule.
  inc sim.tickCount

  if sim.phase == Lobby:
    if sim.checkConnectTimeout():
      return
    sim.stepLobby()
    return

  if sim.checkDisconnectTimeout():
    return

  if sim.phase == GameInfo:
    dec sim.gameInfoTimer
    if sim.gameInfoTimer <= 0:
      sim.enterRoleRevealOrPlaying()
    return

  if sim.phase == RoleReveal:
    dec sim.roleRevealTimer
    if sim.roleRevealTimer <= 0:
      sim.enterPlaying()
    return

  if sim.phase == GameOver:
    dec sim.gameOverTimer
    if sim.gameOverTimer <= 0:
      sim.resetToLobby()
    return

  if sim.phase == MeetingCall:
    dec sim.voteState.callTimer
    if sim.voteState.callTimer <= 0:
      sim.startVoting()
    sim.checkMaxTicks()
    return

  if sim.phase == VoteResult:
    dec sim.voteState.resultTimer
    if sim.voteState.resultTimer <= 0:
      sim.applyVoteResult()
      sim.checkWinCondition()
    sim.checkMaxTicks()
    return

  if sim.phase == Voting:
    if sim.voteState.finalizeTimer > 0:
      dec sim.voteState.finalizeTimer
      if sim.voteState.finalizeTimer <= 0:
        sim.tallyVotes()
      sim.checkMaxTicks()
      return
    dec sim.voteState.voteTimer
    if sim.voteState.voteTimer <= 0:
      sim.tallyVotes(timedOut = true)
      return
    for i in 0 ..< sim.players.len:
      if not sim.players[i].alive:
        continue
      let input =
        if i < inputs.len: inputs[i]
        else: InputState()
      let prev =
        if i < prevInputs.len: prevInputs[i]
        else: InputState()
      if sim.voteState.votes[i] != -1:
        continue
      let
        backward =
          (input.up and not prev.up) or
          (input.left and not prev.left)
        forward =
          (input.down and not prev.down) or
          (input.right and not prev.right)
      if backward != forward:
        sim.moveCursor(
          i,
          if backward:
            -1
          else:
            1
        )
      if input.attack and not prev.attack:
        let cur = sim.voteState.cursor[i]
        if cur == sim.players.len:
          sim.voteState.votes[i] = -2
        else:
          sim.voteState.votes[i] = cur
        sim.logGameEvent(
          "vote cast: " & sim.playerText(i) & " voted " &
            sim.voteTargetText(sim.voteState.votes[i])
        )
        if sim.allVotesCast():
          sim.startVoteFinalizeTimer()
    sim.checkMaxTicks()
    return

  inc sim.gameTickCount
  let bodiesBeforeTick = sim.bodies.len
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].alive and
        sim.players[playerIndex].role == Imposter:
        if sim.players[playerIndex].killCooldown > 0:
          dec sim.players[playerIndex].killCooldown
        if sim.players[playerIndex].ventCooldown > 0:
          dec sim.players[playerIndex].ventCooldown
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: InputState()
    let prev =
      if playerIndex < prevInputs.len: prevInputs[playerIndex]
      else: InputState()
    let
      oldX = sim.players[playerIndex].x
      oldY = sim.players[playerIndex].y
    sim.applyInput(playerIndex, input, prev, bodiesBeforeTick)
    if sim.phase != Playing:
      return
    sim.trackMovementAndStuckPenalty(playerIndex, oldX, oldY)

  sim.checkWinCondition()
  sim.checkMaxTicks()
