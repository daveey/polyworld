import
  jsony,
  polyworld/configs,
  generation/configs

export configs

type
  GotaConfigError* = object of CatchableError
  DraftMode* = enum
    UniqueDraft = "unique"
    TeamDraft = "team"
    OpenDraft = "open"
  GotaConfig* = MatchConfig[MapConfig, DraftMode]

proc draftName*(mode: DraftMode): string =
  ## Returns the player-facing name of the hero selection rules.
  case mode
  of UniqueDraft: "Unique Draft"
  of TeamDraft: "Team Draft"
  of OpenDraft: "Open Draft"

proc parseDraftMode*(value: string): DraftMode =
  ## Reads a stable configuration value for the hero selection rules.
  case value
  of "unique": UniqueDraft
  of "team": TeamDraft
  of "open": OpenDraft
  else:
    raise newException(GotaConfigError,
      "draftMode must be unique, team, or open")

proc withMapPreset*(
    config: GameConfig, preset: MapConfig, draftMode: DraftMode
): GotaConfig =
  ## Adds GotA map and draft settings to the shared match configuration.
  GotaConfig(
    players: config.players,
    seed: config.seed,
    maxTicks: config.maxTicks,
    spawnIntervalTicks: config.spawnIntervalTicks,
    playerSlot: config.playerSlot,
    dayCount: config.dayCount,
    headlessTickRate: config.headlessTickRate,
    waitForLlm: config.waitForLlm,
    mapPreset: preset,
    draftMode: draftMode
  )

proc newHook*(config: var GotaConfig) =
  ## Initializes omitted JSON fields with the same settings as a local match.
  config = GotaConfig(seed: 54, mapPreset: defaultConfig())

proc parseConfig*(bytes: string): GotaConfig =
  ## Reads match settings and map controls, keeping omitted map defaults.
  try:
    result = bytes.fromJson(GotaConfig)
    result.mapPreset.validate()
    if result.maxTicks <= 0 or result.spawnIntervalTicks <= 0 or
      result.playerSlot notin 0 .. 10 or result.dayCount < 0:
        raise newException(GotaConfigError,
          "GotA config has invalid duration, spawn interval, or player slot")
    if result.players.len notin [0, 10]:
      raise newException(GotaConfigError,
        "GotA config must provide all ten player names or omit players")
  except JsonError, MapgenError:
    raise newException(GotaConfigError,
      "Invalid GotA config: " & getCurrentExceptionMsg())

proc loadConfig*(path: string): GotaConfig =
  ## Loads one JSON match configuration with its complete map preset.
  try:
    result = parseConfig(readFile(path))
  except IOError, OSError:
    raise newException(GotaConfigError,
      "Cannot read GotA config: " & getCurrentExceptionMsg())
