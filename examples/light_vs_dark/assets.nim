import
  std/os,
  jsony,
  polyworld/[assets, chargen, common, terrainsurfaces],
  content, factions

const
  LogoPath* = DataRoot & "/themes/lvd/lvd_logo.png"
  UnitSymbolsPath* = DataRoot & "/themes/lvd/unit-symbols.png"
  LvdTerrainTiles* = ["crypt-rock-1", "courtyard-stone-1"]
  LvdRockSurface* = SurfaceNames.len.float32
  LvdStoneSurface* = LvdRockSurface + 1
  LvdWebTerrainAssets* = TerrainAssets(splitProps: true, size: 256)
  LvdTerrainAssets* =
    when defined(emscripten): LvdWebTerrainAssets
    else: TerrainAssets(size: 1024)
  RosterPath* = ChargenLibrary & "/lvd.json"
  CharacterClips* = [
    "Idle_Loop", "Jog_Fwd_Loop", "Death01", "Dance_Loop", "Interact",
    "Sword_Idle", "Sword_Attack", "Pistol_Idle_Loop", "Pistol_Shoot",
    "Spell_Simple_Idle_Loop", "Spell_Simple_Shoot"
  ]
  UnitHeights* = [
    PeonUnit: 1.20'f,
    SoldierUnit: 1.20'f,
    ArcherUnit: 1.20'f,
    MageUnit: 1.20'f,
    KnightUnit: 1.50'f,
    CatapultUnit: 1.20'f,
    ClericUnit: 1.20'f,
    SummonUnit: 1.56'f
  ]
  UnitNames*: array[UnitKind, string] = [
    "Peon", "Swordsman", "Archer", "Mage", "Armored knight", "Bomber",
    "Cleric", "Fire elemental"
  ]
  BuildingModelRoot* = DataRoot & "/terrain/lvd_buildings/models"
  FactionTextureRoot* = DataRoot & "/terrain/lvd_buildings/textures/factions"
  ConstructionManifestPath* =
    DataRoot & "/terrain/lvd_buildings/construction-manifest.json"
  ConstructionNames* = ["foundation", "walls"]
  BuildingScale* = 0.5'f
  BuildingProps*: array[BuildingKind, string] = [
    "town_hall", "farm", "barracks", "lumber_mill", "tower",
    "stables", "church", "blacksmith", "gold_mine"
  ]

type
  ConstructionStage* = enum
    FoundationStage, WallsStage
  UnitPreset* = object
    kind*: string
    preset*: Preset
    skinRgb*: array[3, float32]
  CharacterRoster* = object
    factions*: seq[Faction]
    players*: seq[seq[UnitPreset]]

proc readCharacterRoster*(
  factions: openArray[Faction] = []
): CharacterRoster =
  ## Loads approved looks in the stable player and simulation role order.
  try:
    result = readFile(RosterPath).fromJson(CharacterRoster)
  except IOError, JsonError, ValueError:
    raise newException(
      ChargenError, "Cannot read LvD roster: " & getCurrentExceptionMsg()
    )
  if result.players.len != FactionCount:
    raise newException(ChargenError, "LvD roster needs two player looks.")
  if result.factions.len != FactionCount:
    raise newException(ChargenError, "LvD roster needs a faction per player.")
  if factions.len > 0:
    let looks = result.players
    result.players = newSeq[seq[UnitPreset]](factions.len)
    for player in 0 ..< factions.len:
      result.players[player] = looks[player mod FactionCount]
    result.factions = @factions
  for player, units in result.players.mpairs:
    if units.len != UnitKind.high.ord + 1:
      raise newException(ChargenError, "LvD roster needs all eight roles.")
    for kind in UnitKind:
      if kind != SummonUnit:
        units[kind.ord].skinRgb = result.factions[player].skinRgb()
      let entry = units[kind.ord]
      if entry.kind != $kind:
        raise newException(ChargenError, "LvD roster is missing " & $kind)
      for channel in entry.skinRgb:
        if not (channel >= 0 and channel <= 1):
          raise newException(ChargenError, "Invalid LvD skin color.")

proc unitPortraitPath*(player: int32, kind: UnitKind): string =
  ## Returns a runtime-rendered portrait of the approved player and role.
  DataRoot / "characters/chargen/portraits/lvd" /
    ($player & "_" & $kind.ord & ".png")

proc constructionProp*(
  kind: BuildingKind,
  stage: ConstructionStage
): string =
  ## Names one authored construction stage for a buildable structure.
  BuildingProps[kind] & "_" & ConstructionNames[stage.ord]

proc buildingModelPaths*(): seq[string] =
  ## Lists completed buildings and both stages of each buildable structure.
  for name in BuildingProps:
    result.add BuildingModelRoot / (name & ".glb")
  for kind in TownHallBuilding .. BuildableHigh:
    for stage in ConstructionStage:
      result.add BuildingModelRoot / "construction" /
        ConstructionNames[stage.ord] / (constructionProp(kind, stage) & ".glb")

proc buildingPortraitPath*(player: int32, kind: BuildingKind): string =
  ## Returns the shared portrait rendered from the game's CC0 assembly.
  DataRoot / "terrain/lvd_buildings/portraits" / (BuildingProps[kind] & ".png")

proc factionTexturePath*(faction: Faction): string =
  ## Returns the CC0 trim atlas matching a faction's color and architecture.
  FactionTextureRoot / (FactionFiles[faction] & ".png")

proc buildingPortraitPath*(faction: Faction, kind: BuildingKind): string =
  ## Returns a portrait rendered with the owning faction's actual trim.
  if kind == GoldMineBuilding:
    buildingPortraitPath(-1, kind)
  else:
    DataRoot / "terrain/lvd_buildings/portraits" / FactionFiles[faction] /
      (BuildingProps[kind] & ".png")

proc generatedCharacterAssets*(): seq[Asset] =
  ## Packs approved parts and CC0 clips without the former unit models.
  let
    directory = DataRoot / "characters/chargen"
    manifest = readManifest(directory)
    roster = readCharacterRoster()
  result.add fileAsset("characters/chargen/lvd.json")
  for path in ["manifest.json", manifest.skinPalette, manifest.hairPalette,
      manifest.pupilPalette, manifest.hatPalette]:
    result.add fileAsset(directory / path)
  for category in manifest.categories:
    for path in walkFiles(directory / category.directory / "*.json"):
      result.add fileAsset(path)
  result.add modelAsset(directory / manifest.rig)
  for units in roster.players:
    for entry in units:
      let inventory = manifest.presetManifest(entry.preset)
      for category in inventory.categories:
        for item in category.items:
          for path in item.files:
            result.add modelAsset(directory / path, textureSize = 512)
          for path in [item.texture, item.pupilMask]:
            if path.len > 0:
              result.add imageAsset(directory / path, 512)
  for name in CharacterClips:
    var found = false
    for clip in manifest.clips:
      if clip.name == name:
        if clip.kind != "universal":
          raise newException(ChargenError, "Non-CC0 LvD clip: " & name)
        result.add modelAsset(directory / clip.file)
        found = true
    if not found:
      raise newException(ChargenError, "Missing LvD clip: " & name)

proc browserAssets*(): seq[Asset] =
  ## Declares every presentation asset reachable by either faction.
  result = hudAssets(LogoPath)
  for path in ["LICENSE", "licenses/lvd.md",
      "terrain/lvd_buildings/license.md",
      "fonts/OFL-Rubik.txt", "fonts/OFL-OverpassMono.txt",
      "animations/quaternius/universal_standard/README.txt"]:
    result.add fileAsset(path)
  result.add terrainAssets(
    NoTrees, GeneratedTerrain, NoRocks, LvdWebTerrainAssets, LvdTerrainTiles
  )
  for path in TreegenTextures:
    result.add imageAsset(path, GeneratorTextureSize)
  result.add imageAsset(RockgenTexture, GeneratorTextureSize)
  for path in buildingModelPaths():
    result.add modelAsset(path, textureSize = 512)
  result.add fileAsset(ConstructionManifestPath)
  result.add fileAsset(FactionTextureRoot / "manifest.json")
  for faction in Faction:
    result.add imageAsset(factionTexturePath(faction), 512)
    for kind in TownHallBuilding .. BuildableHigh:
      result.add fileAsset(buildingPortraitPath(faction, kind))
  result.add generatedCharacterAssets()
  result.add fileAsset(UnitSymbolsPath)
  for kind in BuildingKind:
    result.add fileAsset(buildingPortraitPath(0, kind))
