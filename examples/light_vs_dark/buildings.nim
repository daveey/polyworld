import
  jsony, pixie, vmath,
  polyworld/[assets, groves, quadterrain],
  assets, content, factions, sim

type
  ConstructionModel = object
    name: string
    offset: array[3, float32]
  ConstructionManifest = object
    models: seq[ConstructionModel]
  BuildingArt* = object
    pack*, rocks*: PropPack
    factions*: seq[Faction]
    factionPacks*: array[Faction, PropPack]
    heights*: array[BuildingKind, float32]
    offsets*: array[BuildingKind, array[ConstructionStage, Vec3]]
  BuildingPart* = object
    pack*: PropPack
    name*: string
    position*: Vec3
    rotation*, scale*: float32

proc renameHook(model: var ConstructionModel, fieldName: var string) =
  ## Reads the exporter alignment field into its local offset.
  if fieldName == "placement_offset_after_polyworld_centering":
    fieldName = "offset"

proc loadBuildingArt*(
  grove: Grove,
  textured = true,
  factions: openArray[Faction] = []
): BuildingArt =
  ## Preserves the authored scale and alignment of every building stage.
  var manifest: ConstructionManifest
  try:
    manifest = readFile(ConstructionManifestPath).fromJson(ConstructionManifest)
  except IOError, JsonError, ValueError:
    raise newException(
      AssetError, "Cannot read LvD construction models: " & getCurrentExceptionMsg()
    )
  for kind in TownHallBuilding .. BuildableHigh:
    for stage in ConstructionStage:
      let name = constructionProp(kind, stage)
      var found = false
      for model in manifest.models:
        if model.name == name:
          result.offsets[kind][stage] = vec3(
            model.offset[0], model.offset[1], model.offset[2]
          )
          found = true
          break
      if not found:
        raise newException(AssetError, "Missing LvD construction model: " & name)
  result.pack = loadPropPack(
    buildingModelPaths(),
    unitHeight = false,
    textured = textured,
    textureSize = 512,
    mergeNodes = true,
    materialColors = true
  )
  result.factions = @factions
  for faction in factions:
    if result.factionPacks[faction] == nil:
      result.factionPacks[faction] =
        if textured:
          result.pack.retexturePropPack(
            readImage(factionTexturePath(faction)),
            whiteLayer = 0
          )
        else:
          result.pack
  result.rocks = grove.rocks
  for kind in BuildingKind:
    result.heights[kind] =
      result.pack.propSize(BuildingProps[kind]).y * BuildingScale

proc buildingPack*(art: BuildingArt, owner: int32): PropPack =
  ## Uses the owner's trim while neutral structures keep their original art.
  if owner >= 0 and owner < art.factions.len:
    art.factionPacks[art.factions[owner]]
  else:
    art.pack

proc constructionStage*(structure: Building): ConstructionStage =
  ## Switches from foundations to walls halfway through actual build work.
  if structure.buildTotal > 0 and
    structure.buildTicks <= structure.buildTotal div 2:
      WallsStage
  else:
    FoundationStage

proc buildingParts*(
  art: BuildingArt,
  kind: BuildingKind,
  centre: Vec3,
  state = BuildingComplete,
  stage = FoundationStage,
  owner = -1'i32
): seq[BuildingPart] =
  ## Shares the same assembly between terrain, selection, and UI portraits.
  var parts: seq[BuildingPart]
  proc addRock(variant: int, offset: Vec3, height: float32) =
    ## Places one grounded RockGen boulder at an explicit assembly offset.
    let name = modelName(LightRock, variant)
    parts.add BuildingPart(
      pack: art.rocks,
      name: name,
      position: centre + offset - vec3(0, 0.03'f * BuildingScale, 0),
      rotation: variant.float32 * 0.7'f,
      scale: height / art.rocks.propSize(name).y
    )
  if state == BuildingDying:
    addRock(1, vec3(-0.45'f, 0, 0) * BuildingScale, 0.35'f * BuildingScale)
    addRock(4, vec3(0.1'f, 0, -0.2'f) * BuildingScale, 0.5'f * BuildingScale)
    addRock(7, vec3(0.55'f, 0, 0.3'f) * BuildingScale, 0.3'f * BuildingScale)
    return parts
  if kind == GoldMineBuilding:
    let rockScale = art.heights[kind] / 1.4'f
    proc addMineRock(variant: int, offset: Vec3, height: float32) =
      ## Fits the generated rock pile around the scaled mine entrance.
      addRock(variant, offset * rockScale, height * rockScale)
    addMineRock(0, vec3(0, 0, -1.0'f), 1.65'f)
    addMineRock(3, vec3(-0.8'f, 0, -0.6'f), 1.3'f)
    addMineRock(7, vec3(0.8'f, 0, -0.65'f), 1.25'f)
    addMineRock(4, vec3(0, 1.15'f, -0.7'f), 0.9'f)
    addMineRock(2, vec3(-0.95'f, 0, 0.1'f), 0.38'f)
    addMineRock(5, vec3(0.95'f, 0, 0.05'f), 0.3'f)
    parts.add BuildingPart(
      pack: art.pack,
      name: BuildingProps[kind],
      position: centre + vec3(0, 0, rockScale),
      scale: BuildingScale
    )
    return parts
  if state == BuildingUnderConstruction:
    parts.add BuildingPart(
      pack: art.buildingPack(owner),
      name: constructionProp(kind, stage),
      position: centre + art.offsets[kind][stage] * BuildingScale,
      scale: BuildingScale
    )
    return parts
  parts.add BuildingPart(
    pack: art.buildingPack(owner),
    name: BuildingProps[kind],
    position: centre,
    scale: BuildingScale
  )
  parts

proc buildingParts*(
  art: BuildingArt,
  structure: Building,
  centre: Vec3
): seq[BuildingPart] =
  ## Uses the same progress stage for terrain, picking, and selection masks.
  art.buildingParts(
    structure.kind, centre, structure.state, structure.constructionStage(),
    structure.owner
  )
