import
  std/os,
  chroma, gltf, jsony, pixie, vmath,
  polyworld/treegen

const
  ExperimentDirectory* = currentSourcePath().parentDir
  CustomPath* = ExperimentDirectory / "presets/custom.json"

proc groundNode*(): Node =
  ## Creates a neutral ground plane for the shared toon shadow pass.
  let
    white = newImage(1, 1)
    material = Material(name: "Ground", baseColor: white,
      baseColorSampler: defaultTextureSampler(),
      baseColorFactor: color(0.72, 0.74, 0.67, 1), roughnessFactor: 1)
  white.fill(color(1, 1, 1, 1))
  result = Node(name: "Ground", visible: true, scale: vec3(1),
    rot: quat(0, 0, 0, 1), mesh: Mesh(primitives: @[
      Primitive(
        mode: TrianglesMode, material: material,
        points: @[vec3(-100, -0.04, -100), vec3(-100, -0.04, 100),
          vec3(100, -0.04, 100), vec3(100, -0.04, -100)],
        normals: @[vec3(0, 1, 0), vec3(0, 1, 0),
          vec3(0, 1, 0), vec3(0, 1, 0)],
        indices32: @[0'u32, 1, 2, 0, 2, 3])]))

proc saveSettings*(settings: TreeSettings, path: string) =
  ## Saves a validated recipe with library-specific file errors.
  settings.validate()
  try:
    createDir(path.parentDir)
    writeFile(path, settings.toJson())
  except IOError, OSError:
    raise newException(TreegenError, "Cannot save tree preset: " &
      getCurrentExceptionMsg())

proc newHook(settings: var TreeSettings) =
  ## Supplies newly added controls when loading an older saved recipe.
  settings = preset(0)

proc loadSettings*(path: string): TreeSettings =
  ## Parses and validates a saved recipe before applying it to the editor.
  try:
    result = readFile(path).fromJson(TreeSettings)
  except IOError, JsonError, ValueError:
    raise newException(TreegenError, "Cannot load tree preset: " &
      getCurrentExceptionMsg())
  result.validate()

proc exportTree*(settings: TreeSettings, path: string) =
  ## Exports a portable GLB with the tree's textures embedded.
  let
    geometry = generateGeometry(settings)
    materials = loadMaterials(settings.barkTexture,
      withFlowers = settings.flowerKind != NoFlowers)
  materials.tint(settings)
  try:
    createDir(path.parentDir)
    treeNode(geometry, materials).writeGLB(path)
  except IOError, OSError, GltfError:
    raise newException(TreegenError, "Cannot export tree: " &
      getCurrentExceptionMsg())
