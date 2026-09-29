import
  std/strutils

const
  SharedTickRate* = 24'i32
    ## Simulation ticks per second used by every Polyworld game.
  DefaultMinutes* = 20'i32
    ## Default match length in minutes.
  DefaultDurationTicks* = DefaultMinutes * 60 * SharedTickRate
    ## Twenty minutes at the shared tick rate.
  DefaultSpawnIntervalTicks* = 20 * SharedTickRate
    ## Twenty seconds between GotA creep waves.

type
  PlayerConfig* = object
    name*: string

  MatchConfig*[Preset] = object
    players*: seq[PlayerConfig]
    seed*: int32 = 2026
    maxTicks*: int32 = DefaultDurationTicks
    spawnIntervalTicks*: int32 = DefaultSpawnIntervalTicks
    playerSlot*: int32
    dayCount*: int32
    headlessTickRate*: int32
    waitForLlm*: bool
    when Preset isnot void:
      mapPreset*: Preset

  GameConfig* = MatchConfig[void]

proc renameHook*[Preset](
    value: var MatchConfig[Preset], fieldName: var string
) =
  ## Maps the platform's snake case config fields to Nim field names.
  var
    name: string
    upper = false
  for character in fieldName:
    if character == '_':
      upper = true
    else:
      name.add(if upper: character.toUpperAscii else: character)
      upper = false
  fieldName = name

proc gameConfig*[Preset](config: MatchConfig[Preset]): GameConfig =
  ## Copies the shared match settings without game-specific map parameters.
  GameConfig(
    players: config.players,
    seed: config.seed,
    maxTicks: config.maxTicks,
    spawnIntervalTicks: config.spawnIntervalTicks,
    playerSlot: config.playerSlot,
    dayCount: config.dayCount,
    headlessTickRate: config.headlessTickRate,
    waitForLlm: config.waitForLlm
  )

proc withMapPreset*[Preset](
    config: GameConfig, preset: Preset
): MatchConfig[Preset] =
  ## Adds a typed map preset to the shared match settings.
  MatchConfig[Preset](
    players: config.players,
    seed: config.seed,
    maxTicks: config.maxTicks,
    spawnIntervalTicks: config.spawnIntervalTicks,
    playerSlot: config.playerSlot,
    dayCount: config.dayCount,
    headlessTickRate: config.headlessTickRate,
    waitForLlm: config.waitForLlm,
    mapPreset: preset
  )

proc displayName*(player: PlayerConfig, slot: int): string =
  ## Formats a player label without changing the recorded configuration.
  for character in player.name:
    result.add:
      if character.ord < 32 or character.ord == 127:
        ' '
      else:
        character
  result = result.strip()
  if result.toLowerAscii().endsWith(".bas"):
    result.setLen(result.len - 4)
    result = result.strip()
  if result.len == 0:
    result = "Player " & $(slot + 1)

proc unnamedPlayers*(count: int): seq[PlayerConfig] =
  ## Creates public records for slots without a bot file or hosted roster.
  for slot in 0 ..< count:
    result.add PlayerConfig(name: "Player " & $(slot + 1))
