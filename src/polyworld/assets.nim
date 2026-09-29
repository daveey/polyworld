import
  std/[os, strutils],
  common, terrainsurfaces

type
  AssetError* = object of CatchableError
  AssetKind* = enum
    FileAsset, ImageAsset, ImageDirectory, ModelAsset, TerrainAsset
  Asset* = object
    kind*: AssetKind
    source*, output*, manifest*: string
    nodes*, clips*, presets*: seq[string]
    size*: int
    compressed*: bool
  TreeStyle* = enum
    MixedTrees, EvergreenTrees, DenseTrees, NoTrees
  TerrainStyle* = enum
    CartoonTerrain, GeneratedTerrain
  RockStyle* = enum
    LowPolyRocks, PaintedRocks, NoRocks
  TerrainAssets* = object
    grass*, water*, splitProps*, compressed*: bool
    size*: int
    materials*: seq[string]

const
  DefaultFontPath* = DataRoot & "/fonts/Rubik-Regular.ttf"
  BoldFontPath* = DataRoot & "/fonts/Rubik-Bold.ttf"
  MonoFontPath* = DataRoot & "/fonts/OverpassMono-Regular.ttf"
  MainThemeDir* = DataRoot & "/themes/main/"
  UiDir* = DataRoot & "/ui/"
  IconDir* = DataRoot & "/icons/"
  CartoonMaterials* = @[
    "grass", "sand", "cliff", "marsh", "stone", "dirt", "volcanic",
    "underwater"
  ]
  TreeTextures* = @[
    "fir", "birch_simple_01", "birch_simple_02", "birch_simple_03",
    "birch_simple_04", "oak_simple_01", "oak_simple_02",
    "birch_double_01", "birch_double_02", "birch_double_03",
    "birch_double_04", "oak_double_01", "oak_double_02"
  ]
  DenseTreeModels* = ["tree_fir_01", "tree_fir_02"]
  WaterNormalTextures* = ["water_1_normal", "water_2_normal"]
  GrassPath* = DataRoot & "/terrain/low_poly_grass.glb"
  PaintedRockPath* = DataRoot & "/terrain/toon_enchanted_meadow/rocks.glb"
  PaintedRockNames* = ["rock_large_02a", "rock_medium_01a"]
  GeneratorTextureSize* = 512
  TreegenTextures* = [
    DataRoot & "/terrain/treegen/tree-foliage-atlas.png",
    DataRoot & "/terrain/treegen/bark.png",
    DataRoot & "/terrain/treegen/stump-rings.png"
  ]
  RockgenTexture* = DataRoot & "/terrain/rockgen/rock-trim-atlas.png"
  TreegenFlowerTexture* = DataRoot & "/terrain/treegen/flower-atlas.png"
  DefaultTerrainAssets* = TerrainAssets(
    grass: true, water: true, size: 1024, materials: CartoonMaterials
  )
  WebTerrainAssets* = TerrainAssets(
    grass: true, water: true, splitProps: true, size: 256
  )

proc assetName*(path: string): string =
  ## Returns a path relative to the source asset directory.
  if path.startsWith(DataRoot & "/"):
    path[DataRoot.len + 1 .. ^1]
  else:
    path

proc fileAsset*(path: string): Asset =
  ## Declares one unmodified asset path.
  Asset(kind: FileAsset, source: path.assetName, output: path.assetName)

proc imageAsset*(path: string, size: int): Asset =
  ## Declares a browser image capped at the given maximum dimension.
  doAssert size > 0
  Asset(
    kind: ImageAsset, source: path.assetName, output: path.assetName, size: size
  )

proc modelAsset*(
  path: string,
  nodes: seq[string] = @[],
  clips: seq[string] = @[],
  manifest = "",
  presets: seq[string] = @[],
  textureSize = 0
): Asset =
  ## Declares a model and the named content retained in its browser copy.
  Asset(
    kind: ModelAsset, source: path.assetName, output: path.assetName,
    nodes: nodes, clips: clips, manifest: manifest.assetName, presets: presets,
    size: textureSize
  )

proc propPath*(pack, name: string): string =
  ## Returns the generated path for one named prop.
  pack.changeFileExt("") & "/" & name & ".glb"

proc propPaths*(pack: string, names: openArray[string]): seq[string] =
  ## Uses split props in browser builds and the original pack natively.
  when defined(emscripten):
    for name in names:
      result.add propPath(pack, name)
  else:
    result.add pack

proc propAssets*(
    pack: string, names: openArray[string], textureSize = 0
): seq[Asset] =
  ## Declares independently reusable files for selected static props.
  for name in names:
    var asset = modelAsset(pack, @[name], textureSize = textureSize)
    asset.output = propPath(pack.assetName, name)
    result.add asset

proc treeTextures*(style: TreeStyle): seq[string] =
  ## Selects texture layers without changing existing mixed-tree indices.
  case style
  of NoTrees:
    discard
  of DenseTrees:
    result = @[TreeTextures[0]]
  of MixedTrees, EvergreenTrees:
    result = TreeTextures

proc hudAssets*(logo: string): seq[Asset] =
  ## Declares the files consumed by the shared HUD atlas builder.
  for path in [DefaultFontPath, BoldFontPath, MonoFontPath, logo]:
    result.add fileAsset(path)
  for path in [MainThemeDir, UiDir, IconDir]:
    result.add Asset(kind: ImageDirectory, source: path.assetName)

proc terrainAssets*(
  trees: TreeStyle,
  terrain: TerrainStyle,
  rocks: RockStyle,
  settings: TerrainAssets,
  extraTiles: openArray[string] = []
): seq[Asset] =
  ## Declares terrain files from the same settings used by the renderer.
  for name in treeTextures(trees):
    result.add fileAsset("terrain/handpainted_trees/" & name & ".png")
  if trees != NoTrees:
    for name in DenseTreeModels:
      result.add modelAsset("terrain/handpainted_trees/" & name & ".glb")
    if trees in {MixedTrees, EvergreenTrees}:
      result.add modelAsset("terrain/handpainted_trees/tree_leafy_simple.glb")
    if trees == MixedTrees:
      for name in ["tree_fir_03", "tree_leafy_double"]:
        result.add modelAsset("terrain/handpainted_trees/" & name & ".glb")
  if settings.grass:
    result.add modelAsset(GrassPath)
  if settings.water:
    for name in WaterNormalTextures:
      result.add fileAsset("terrain/water_normals/" & name & ".jpg")
  case rocks
  of NoRocks:
    discard
  of LowPolyRocks:
    result.add modelAsset("terrain/low_poly_rocks.glb")
  of PaintedRocks:
    result.add propAssets(
      PaintedRockPath, PaintedRockNames, textureSize = settings.size)
  case terrain
  of CartoonTerrain:
    for name in settings.materials:
      result.add Asset(
        kind: TerrainAsset, source: "terrain/cartoon_textures/" & name,
        size: settings.size, compressed: settings.compressed
      )
  of GeneratedTerrain:
    for name in SurfaceNames:
      for folder in ["tiles", "stamps"]:
        for channel in ["rgb", "height"]:
          result.add fileAsset(
            "terrain/" & folder & "/" & name & "." & channel & ".png"
          )
    for name in extraTiles:
      for channel in ["rgb", "height"]:
        result.add fileAsset("terrain/tiles/" & name & "." & channel & ".png")
