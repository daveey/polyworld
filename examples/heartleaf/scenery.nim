import
  std/[math, os],
  chroma, gltf, jsony, pixie, vmath,
  polyworld/[common, groves, pathing, quadterrain, treegen],
  content, maps, layouts

const
  VillageRoot* = DataRoot & "/terrain/blender_village/models/"
  VillageModels* = [
    "hobbit_house", "well", "hobbit_barrel_planter", "hobbit_box_planter",
    "hobbit_chimney"
  ]
  DetailsPath* = DataRoot & "/terrain/heartleaf/models/village_details.glb"
  CottagePath* = DataRoot & "/terrain/heartleaf/models/cottage.glb"
  GardenPartsPath* = DataRoot & "/terrain/heartleaf/models/garden_parts.glb"
  GardenLayoutPath* = DataRoot & "/terrain/heartleaf/models/garden-parts.json"
  GardenCropLift* = 1.55'f * HouseScale

type
  VillageLayer* = enum
    AllLayer, GroundLayer, BuildingsLayer, VegetationLayer, PropsLayer
  GardenPart* = object
    name*, kind*: string
    position*: array[3, float32]
  RoofTriangle* = array[3, Vec3]
  VillageArt* = object
    props*: array[VillageModels.len, PropPack]
    names*: array[VillageModels.len, string]
    placeholders*: PropPack
    grove*: Grove
    houses*, trees*, details*, forestFloor*: PropPack
    roof*: seq[RoofTriangle]
    yard*: PropPack
    yardParts*: seq[GardenPart]

proc placeholderNode*(): Node =
  ## Builds a unit box for missing props and unmodeled vegetables.
  const
    Points = [
      vec3(-0.5, 0, -0.5), vec3(0.5, 0, -0.5),
      vec3(0.5, 1, -0.5), vec3(-0.5, 1, -0.5),
      vec3(-0.5, 0, 0.5), vec3(0.5, 0, 0.5),
      vec3(0.5, 1, 0.5), vec3(-0.5, 1, 0.5)
    ]
    Faces = [
      [0, 3, 2, 1], [4, 5, 6, 7], [0, 4, 7, 3],
      [1, 2, 6, 5], [3, 7, 6, 2], [0, 1, 5, 4]
    ]
  let primitive = Primitive(
    mode: TrianglesMode,
    material: Material(baseColorFactor: color(1, 1, 1, 1))
  )
  for face in Faces:
    let normal = normalize(cross(
      Points[face[1]] - Points[face[0]],
      Points[face[2]] - Points[face[0]]
    ))
    for corner in [0, 1, 2, 0, 2, 3]:
      primitive.indices32.add primitive.points.len.uint32
      primitive.points.add Points[face[corner]]
      primitive.normals.add normal
  Node(
    name: "placeholder", visible: true, scale: vec3(1),
    rot: quat(0, 0, 0, 1), mesh: Mesh(primitives: @[primitive])
  )

proc tintedMaterial(source: Material, tint: Vec3): Material =
  ## Shares image pixels while keeping each prop's material tint separate.
  new(result)
  result[] = source[]
  result.baseColorFactor = color(tint.x, tint.y, tint.z, 1)

proc gradeTexture(image: Image, gain, lift: Vec3) =
  ## Adjusts a Heartleaf material without changing the shared source pixels.
  for pixel in image.data.mitems:
    pixel.r = uint8(clamp(pixel.r.float32 * gain.x + lift.x, 0, 255))
    pixel.g = uint8(clamp(pixel.g.float32 * gain.y + lift.y, 0, 255))
    pixel.b = uint8(clamp(pixel.b.float32 * gain.z + lift.z, 0, 255))

proc meadowTexture*(tint = vec3(1), roof = false): Image =
  ## Matches meadow greens and the reference's brighter sunlit cottage turf.
  result = readImage(DataRoot & "/terrain/tiles/heartleaf-layer-grass-1.rgb.png")
  if roof:
    result.gradeTexture(vec3(1.2, 1.02, 0.95) * tint, vec3(14, 14, 17))
  else:
    result.gradeTexture(vec3(0.98, 0.96, 0.92) * tint, vec3(6, 6, 10))

proc pathTexture*(): Image =
  ## Shifts the lemon-colored path toward the reference's warm sandy ochre.
  result = readImage(DataRoot & "/terrain/tiles/heartleaf-layer-path-2.rgb.png")
  result.gradeTexture(vec3(0.98, 0.90, 1.08), vec3(2, 0, 8))

proc houseNodes*(): seq[Node] =
  ## Reuses the reviewed cottage mesh with nine independently stained doors.
  const DoorColors = [
    vec3(0.24, 0.53, 0.17), vec3(0.84, 0.54, 0.20),
    vec3(0.47, 0.26, 0.08), vec3(0.16, 0.35, 0.77),
    vec3(0.92, 0.65, 0.27), vec3(0.46, 0.19, 0.70),
    vec3(0.85, 0.57, 0.24), vec3(0.24, 0.49, 0.43),
    vec3(0.12, 0.44, 0.44)
  ]
  if not fileExists(CottagePath):
    for i in 0 ..< VillagerCount:
      let node = placeholderNode()
      node.name = "home" & $i
      node.scale = vec3(10, 4, 7) * HouseScale
      result.add node
    return
  let
    file = readGltfFile(CottagePath)
    grass = meadowTexture(roof = true)
  for source in file.root.walkNodes:
    if source.mesh == nil:
      continue
    for i, tint in DoorColors:
      let node = Node(
        name: "home" & $i, visible: true,
        pos: HouseMeshOffset, scale: vec3(HouseMeshScale),
        rot: quat(0, 0, 0, 1), mesh: Mesh()
      )
      doAssert source.mesh.primitives.len == 3
      for materialIndex, sourcePrimitive in source.mesh.primitives:
        let primitive = Primitive()
        primitive[] = sourcePrimitive[]
        primitive.material = tintedMaterial(sourcePrimitive.material, vec3(1))
        if materialIndex == 0:
          primitive.material = tintedMaterial(primitive.material,
            vec3(1.07, 1.03, 0.94))
        elif materialIndex == 1:
          primitive.material = tintedMaterial(primitive.material, tint)
        elif materialIndex == 2:
          primitive.material.baseColor = grass
        node.mesh.primitives.add primitive
      result.add node

proc houseRoof*(node: Node): seq[RoofTriangle] =
  ## Extracts the transformed grass shell for precise decoration placement.
  if node.mesh.primitives.len < 3:
    return
  let
    shell = Node(mesh: Mesh(primitives: @[node.mesh.primitives[2]]))
    transform = node.trs
  for (a, b, c) in shell.triangles:
    result.add [transform * a, transform * b, transform * c]

proc yardNodes(parts: openArray[GardenPart]): seq[Node] =
  ## Fits reusable rails to each gate without overrotating the cottage facade.
  let file = readGltfFile(GardenPartsPath)
  for slot in 0 ..< VillagerCount:
    let yard = Node(
      name: "yard" & $slot, visible: true, scale: vec3(1),
      rot: quat(0, 0, 0, 1), mesh: Mesh()
    )
    for source in file.root.walkNodes:
      if source.mesh == nil:
        continue
      for part in parts:
        if part.kind != "fence" or part.name != source.name:
          continue
        let pivot = vec3(part.position[0], part.position[1], part.position[2])
        for original in source.mesh.primitives:
          let primitive = Primitive()
          primitive[] = original[]
          primitive.points = @[]
          primitive.normals = @[]
          for i, vertex in original.points:
            let
              local = (source.trs * vertex + pivot) * HouseMeshScale +
                HouseMeshOffset
              x = int32(round(local.x * 1000))
              z = int32(round(local.z * 1000))
              rotated = yardPoint(slot, x, z)
              turn = yardTurn(slot, z)
              normal = original.normals[i]
            primitive.points.add vec3(rotated.x.float32 / 1000,
              local.y, rotated.z.float32 / 1000)
            primitive.normals.add normalize(vec3(
              turn.cosine.float32 * normal.x - turn.sine.float32 * normal.z,
              normal.y * 1000,
              turn.sine.float32 * normal.x + turn.cosine.float32 * normal.z
            ))
          yard.mesh.primitives.add primitive
    result.add yard

proc roofHeight*(roof: openArray[RoofTriangle], x, z: float32): float32 =
  ## Samples the upper grass surface directly from its exported triangles.
  result = 0
  for triangle in roof:
    let
      a = triangle[0]
      b = triangle[1]
      c = triangle[2]
      divisor = (b.z - c.z) * (a.x - c.x) +
        (c.x - b.x) * (a.z - c.z)
    if abs(divisor) < 0.000001'f:
      continue
    let
      first = ((b.z - c.z) * (x - c.x) +
        (c.x - b.x) * (z - c.z)) / divisor
      second = ((c.z - a.z) * (x - c.x) +
        (a.x - c.x) * (z - c.z)) / divisor
      third = 1 - first - second
    if first >= -0.0001'f and second >= -0.0001'f and third >= -0.0001'f:
      result = max(result, first * a.y + second * b.y + third * c.y)

proc broadleafNodes(seed: int32): seq[Node] =
  ## Builds a small cached bank of round spring crowns and low shrubs.
  let materials = treegen.loadMaterials(1)
  for i in 0 ..< 13:
    var settings = treegen.preset(0, seed.int + i * 997)
    settings.crownRadius = 3.0'f + (i mod 3).float32 * 0.22'f
    settings.crownHeight = 3.0'f
    settings.crownShape = 0.35'f
    settings.crownBase = 3.0'f
    settings.height = 5.8'f
    settings.branches = 7
    settings.forks = 0
    settings.rings = 7
    settings.cardsPerRing = 12
    settings.density = 1.15'f
    settings.packing = 1.05'f
    settings.crownCoverage = 0.9'f
    settings.leafSize = 1.25'f
    settings.leafWidth = 1.4'f
    settings.leafTile = MixedLeaves
    settings.colorVariation = 0.14'f
    settings.leafColor = [
      vec3(0.40, 0.59, 0.16), vec3(0.53, 0.66, 0.22),
      vec3(0.31, 0.49, 0.16)
    ][i mod 3]
    if i >= 7:
      settings.crownRadius = 2.4'f + (i mod 4).float32 * 0.35'f
      settings.crownHeight = 2.5'f + (i mod 3).float32 * 0.55'f
      settings.crownBase = 2.2'f + (i mod 4).float32 * 0.35'f
      settings.crownShape = 0.3'f + (i mod 3).float32 * 0.2'f
      settings.height = settings.crownBase + settings.crownHeight
      settings.branches = 4 + i mod 5
      settings.trunkRadius = 0.22'f + (i mod 3).float32 * 0.07'f
    if i in 3 .. 5:
      settings.height = 1.0'f
      settings.crownBase = 0.3'f
      settings.crownHeight = 0.95'f
      settings.crownRadius = 1.1'f
      settings.trunkRadius = 0.08'f
      settings.roots = 0
      settings.branches = 0
      settings.stemClearance = 0.1'f
      settings.crownCoverage = 1
      settings.crownShape = 0.5'f
      settings.droop = 0.25'f
      settings.rings = 7
      settings.shells = 3
      settings.density = 1.5'f
      settings.leafSize = 0.55'f
    if i == 6:
      settings.height = 6.4'f
      settings.crownBase = 4.6'f
      settings.crownHeight = 2.6'f
      settings.crownRadius = 3.7'f
      settings.crownShape = 0.28'f
      settings.crownCoverage = 0.86'f
      settings.droop = 0.25'f
      settings.shells = 3
      settings.density = 1.4'f
      settings.leafSize = 0.95'f
      settings.cardsPerRing = 16
      settings.trunkRadius = 0.8'f
      settings.branchStart = 0.44'f
      settings.branchLength = 1.65'f
      settings.rootSpread = 1.9'f
      settings.rootThickness = 0.9'f
    let node = treegen.treeNode(
      treegen.generateGeometry(settings),
      TreeMaterials(
        bark: tintedMaterial(materials.bark, vec3(0.82, 0.58, 0.32)),
        foliage: tintedMaterial(materials.foliage, settings.leafColor),
        cut: materials.cut
      )
    )
    node.name = "leaf" & $i
    result.add node

proc forestFloorNode(): Node =
  ## Feathers the meadow into woodland soil beneath the irregular forest edge.
  let
    paint = meadowTexture(vec3(1))
    primitive = Primitive(mode: TrianglesMode)
  primitive.material = Material(baseColor: paint,
    baseColorFactor: color(1, 1, 1, 1))
  const Side = 49
  for iz in 0 ..< Side:
    for ix in 0 ..< Side:
      let
        x = (ix - 24).float32 * 4
        z = (iz - 24).float32 * 4
        outside = length(vec2(max(0'f, abs(x) - 24),
          max(0'f, abs(z - 3) - 42'f)))
        fade = smoothstep(0'f, 7'f, outside)
        tint = mix(vec3(1), vec3(0.29, 0.36, 0.27), fade)
      primitive.points.add vec3(x, -0.03, z)
      primitive.normals.add vec3(0, 1, 0)
      primitive.uvs.add vec2(x, z) * terrainTextureScale
      primitive.colors.add rgbx(uint8(tint.x * 255),
        uint8(tint.y * 255), uint8(tint.z * 255), 255)
      if ix < Side - 1 and iz < Side - 1:
        let index = uint32(iz * Side + ix)
        primitive.indices32.add [index, index + Side, index + 1,
          index + 1, index + Side, index + Side + 1]
  Node(name: "forestFloor", visible: true, scale: vec3(1),
    rot: quat(0, 0, 0, 1), mesh: Mesh(primitives: @[primitive]))

proc loadVillageArt*(seed: int32): VillageArt =
  ## Loads only reviewed CC0 props and caches generated foliage once.
  result.forestFloor = createPropPack([forestFloorNode()],
    repeatTexture = true)
  result.placeholders = createPropPack([placeholderNode()])
  result.grove = generateGrove(seed.int, {LightRock})
  result.trees = createPropPack(broadleafNodes(seed), repeatTexture = true)
  let houses = houseNodes()
  result.houses = createPropPack(houses, repeatTexture = true)
  result.roof = houseRoof(houses[0])
  result.yardParts = readFile(GardenLayoutPath).fromJson(seq[GardenPart])
  result.yard = createPropPack(yardNodes(result.yardParts), repeatTexture = true)
  if fileExists(DetailsPath):
    result.details = loadPropPack(
      DetailsPath,
      repeatTexture = true,
      unitHeight = false,
      textured = true,
      materialColors = true,
      textureSize = 512
    )
  else:
    result.details = result.placeholders
  for i, name in VillageModels:
    let path = VillageRoot & name & ".glb"
    if fileExists(path):
      result.props[i] = loadPropPack(
        path,
        textured = true,
        materialColors = true,
        mergeNodes = true,
        repeatTexture = true,
        textureSize = 512
      )
      result.names[i] = name
    else:
      result.props[i] = result.placeholders
      result.names[i] = "placeholder"

proc villagePoint*(tile: Tile2): Vec3 =
  ## Places art at a simulation tile's ground center.
  let
    x = tile.x.float32 - HalfGrid + 0.5'f
    z = tile.y.float32 - HalfGrid + 0.5'f
  vec3(x, surfaceHeight(x, z), z)

proc placeVillage*(art: VillageArt, map: MapData, seed: int32,
    layer = AllLayer) =
  ## Assembles the reference's nine cottages, tree square and garden lanes.
  clearProps()
  var placementLayer = GroundLayer

  proc placeLayerProp(pack: PropPack, name: string, position: Vec3,
      rotation = 0'f, scale = 1'f, tint = vec3(1), stretch = vec3(1)) =
    ## Selects actual 3D meshes for a layer without changing their transforms.
    if layer == AllLayer or layer == placementLayer:
      pack.placeProp(name, position, rotation, scale, tint, stretch)

  art.forestFloor.placeLayerProp("forestFloor", vec3(0))

  proc point(x, z: float32): Vec3 =
    ## Samples the terrain under a decorative village location.
    vec3(x + 0.5'f, surfaceHeight(x + 0.5'f, z + 0.5'f), z + 0.5'f)

  proc detail(name: string, x, z: float32, yaw = 0'f, size = 1'f,
      height = 0'f, tint = vec3(1)) =
    ## Queues one of the reusable painted village details.
    if art.details.hasProp(name):
      art.details.placeLayerProp(name, point(x, z) + vec3(0, height, 0),
        yaw, size, tint)
    else:
      art.placeholders.placeLayerProp("placeholder",
        point(x, z) + vec3(0, height, 0), yaw, size)

  proc flowers(x, z: float32, variant: int, size = 1'f,
      height = 0'f) =
    ## Mixes daisies, cornflowers, purple blooms and golden flowers.
    const Names = [
      "flowers_white", "flowers_white", "flowers_blue",
      "flowers_white", "flowers_purple", "flowers_gold"
    ]
    detail(Names[abs(variant) mod Names.len], x, z, variant.float32, size, height)

  placementLayer = VegetationLayer
  for plant in groundPlants(seed):
    art.trees.placeLayerProp(
      "leaf" & $plant.variant,
      point(plant.x.float32 / 1000, plant.z.float32 / 1000),
      plant.yaw, plant.size, stretch = vec3(1, plant.height, 1)
    )
  placementLayer = PropsLayer
  for i, fence in GardenFences:
    let
      x = fence.x.float32 / 1000
      z = fence.z.float32 / 1000
    detail("fence", x, z, fence.yaw, fence.size)
    for j in 0 ..< 1:
      let angle = j.float32 * 2.4'f + i.float32
      flowers(x + cos(angle) * 0.35'f,
        z + sin(angle) * 0.35'f, i + j div 2, 0.65'f)

  art.props[1].placeLayerProp(art.names[1], point(TownWell.x, TownWell.y),
    scale = 4.5'f)
  for i in 0 ..< 12:
    let angle = i.float32 * 2'f * PI.float32 / 12'f
    flowers(TownWell.x + cos(angle) * 2.2'f,
      TownWell.y + sin(angle) * 2.2'f, i, 0.85'f)

  detail("tree_curb", -1.028, -0.557, size = 1.16'f)
  placementLayer = GroundLayer
  detail("plaza_paving", -1.028, -0.73, size = 0.82'f)
  placementLayer = PropsLayer
  for angle in [0.82'f, 2.32'f]:
    # The seat fronts point along local +Z, away from the trunk.
    detail("bench", -1.028'f + cos(angle) * 4.0'f,
      -0.557'f + sin(angle) * 4.0'f,
      angle - PI.float32 / 2, 1.0'f, tint = vec3(1.65, 1.44, 1.17))
  for i in 0 ..< 14:
    let angle = i.float32 * 2'f * PI.float32 / 14'f
    flowers(-1.028'f + cos(angle) * 2.4'f,
      -0.557'f + sin(angle) * 2.4'f, i, 0.65'f)
  detail("market", -5.91, -7.40, -0.72'f, 1.1'f)
  detail("lantern", -3.25'f, -8.85'f, size = 1.5'f)
  detail("lantern", 6.8'f, 2, size = 1.5'f)
  detail("sign", -5.47, -15.32, -0.2'f, 2'f)
  detail("sign", -1.78, 25.32, 0.2'f, 2'f)
  let hive = referencePoint(330, 1013)
  detail("beehive", hive.x, hive.y, 0.18'f, 1.1'f)
  for pixel in [vec2(129, 395), vec2(358, 451), vec2(943, 209),
      vec2(904, 973)]:
    let position = referencePoint(pixel.x, pixel.y)
    detail("lantern", position.x, position.y, size = 1.38'f)
  for pixel in [vec2(756, 494), vec2(431, 973)]:
    let position = referencePoint(pixel.x, pixel.y)
    detail("birdhouse", position.x, position.y, size = 2.0'f)
  for pixel in [vec2(264, 823), vec2(863, 1240)]:
    let position = referencePoint(pixel.x, pixel.y)
    detail("laundry", position.x, position.y, 0.52'f, 0.98'f)
  placementLayer = VegetationLayer
  detail("lupins", TownIsland.x, TownIsland.y + 1, size = 1.8'f)
  for pixel in [vec2(404, 147), vec2(390, 176), vec2(380, 262),
      vec2(1027, 618)]:
    let position = referencePoint(pixel.x, pixel.y)
    detail("sunflowers", position.x, position.y, size = 1.5'f)

  for i, house in map.houses:
    let
      anchor = houseAnchor(i)
      center = point(anchor.x.float32 / 1000, anchor.z.float32 / 1000)
      yaw = houseYaw(i)
      turnCos = cos(yaw)
      turnSin = sin(yaw)

    proc localPoint(x, z: float32, height = 0'f): Vec3 =
      ## Keeps roof planting and facade props attached to the scaled cottage.
      let
        px = center.x - 0.5'f + (turnCos * x - turnSin * z) * HouseScale
        pz = center.z - 0.5'f + (turnSin * x + turnCos * z) * HouseScale
      point(px, pz) + vec3(0, height * HouseScale, 0)

    placementLayer = BuildingsLayer
    art.houses.placeLayerProp("home" & $i, center, yaw)
    placementLayer = PropsLayer
    art.yard.placeLayerProp("yard" & $i, center,
      tint = vec3(1.08, 1.01, 0.92))
    for side in [-1'f, 1'f]:
      let position = localPoint(side * 3.1'f, 0.9'f)
      art.details.placeLayerProp(
        "bucket_planter", position, yaw, 1.45'f * HouseScale,
        tint = vec3(1.16, 1.08, 0.97)
      )
      art.details.placeLayerProp(
        if side < 0: "flowers_white" else: "flowers_purple",
        position + vec3(0, 0.64'f * 1.45'f * HouseScale, 0),
        yaw, 0.50'f
      )
    placementLayer = BuildingsLayer
    if i in [0, 8]:
      let pixel = if i == 0: vec2(437, 119) else: vec2(902, 1131)
      var position = point(referencePoint(pixel.x, pixel.y).x,
        referencePoint(pixel.x, pixel.y).y)
      for iteration in 0 ..< 6:
        let
          dx = position.x - center.x
          dz = position.z - center.z
          px = turnCos * dx + turnSin * dz
          pz = -turnSin * dx + turnCos * dz
          height = roofHeight(art.roof, px, pz)
        position.y = height
        position.z = (pixel.y - 650) * 0.057'f +
          height / tan(TownCameraPitch)
      art.props[4].placeLayerProp(art.names[4], position, yaw, 3.7'f)
    for bed, offset in [vec2(-2.8, -1.2), vec2(2.7, -2.2),
        vec2(-0.8, -4.1), vec2(0.8, -0.4)]:
      for j in 0 ..< 7:
        let
          angle = j.float32 * 2.399963'f + i.float32 * 0.37'f
          radius = sqrt((j.float32 + 0.5'f) / 7'f) * 1.45'f
          px = offset.x + cos(angle) * radius
          pz = offset.y + sin(angle) * radius
          height = roofHeight(art.roof, px, pz)
        if pz > HouseMeshOffset.z - 0.25'f or height < 0.5'f:
          continue
        let position = localPoint(
          px / HouseScale, pz / HouseScale, height / HouseScale)
        if art.details.hasProp("flowers_white") and j mod 3 != 0:
          art.details.placeLayerProp(
            if bed == 1 and j mod 4 == 0: "flowers_blue"
            else: "flowers_white",
            position + vec3(0, 0.12, 0), yaw + j.float32,
            0.55'f, stretch = vec3(1, 0.32, 1)
          )
    for tuft in 0 ..< 25:
      let
        px = -5.2'f + tuft.float32 * 0.435'f
        pz = -0.54'f - 0.05'f * sin(tuft.float32 * 2.4'f)
        height = roofHeight(art.roof, px, pz)
      if height < 0.9'f:
        continue
      let position = localPoint(
        px / HouseScale, pz / HouseScale, height / HouseScale)
      art.details.placeLayerProp(
        "eave_clover", position - vec3(0, 0.05, 0), yaw,
        1.20'f + (tuft mod 3).float32 * 0.08'f
      )
  placementLayer = PropsLayer
  for i, tile in map.gardenTiles:
    let yaw = houseYaw(i div GardensPerHouse)
    art.props[3].placeLayerProp(art.names[3], villagePoint(tile),
      yaw, 1.55'f * HouseScale, tint = vec3(1.08, 1.03, 0.95))
    if art.details.hasProp("flowers_white"):
      for side in [-0.35'f, 0.35'f]:
        art.details.placeLayerProp(
          if i mod 3 == 0: "flowers_blue" else: "flowers_white",
          villagePoint(tile) +
            vec3(cos(yaw) * side, GardenCropLift, sin(yaw) * side),
          yaw, 0.75'f
        )

  const StoneBorders = [
    @[(28, 260), (62, 220), (102, 165), (151, 124), (208, 97)],
    @[(866, 107), (925, 139), (1019, 196), (1076, 254)],
    @[(0, 488), (40, 434), (65, 406)],
    @[(1070, 423), (1105, 461), (1131, 498)],
    @[(28, 708)], @[(1079, 711), (1096, 741)],
    @[(1067, 1031), (1043, 1080), (1011, 1130)],
    @[(143, 1036), (127, 1061)],
    @[(113, 1158), (81, 1179)],
    @[(92, 1320)], @[(1011, 1278)],
    @[(710, 1395), (757, 1377), (811, 1357), (852, 1351)]
  ]
  for key, chain in StoneBorders:
    for i in 0 ..< chain.len:
      let
        pixel = chain[i]
        position = referencePoint(pixel[0].float32, pixel[1].float32)
        next = chain[min(i + 1, chain.high)]
        finish = referencePoint(next[0].float32, next[1].float32)
        count = max(1, int(ceil(length(finish - position) / 0.95'f)))
      for j in 0 ..< count:
        let at = mix(position, finish, j.float32 / count.float32)
        art.grove.rocks.placeLayerProp(
          modelName(LightRock, (key + i + j) mod BrushVariants),
          point(at.x, at.y), (i + j).float32 * 1.3'f,
          1.0'f + ((key + i + j) mod 3).float32 * 0.15'f,
          tint = vec3(1.75, 1.72, 1.62)
        )
  placementLayer = VegetationLayer
  for plant in groundPlants(seed):
    if plant.variant notin 3 .. 5:
      continue
    placementLayer = VegetationLayer
    let
      x = plant.x.float32 / 1000
      z = plant.z.float32 / 1000
      key = abs(plant.x * 7 + plant.z * 11)
    for j in 0 ..< 3:
      let angle = j.float32 * 2.4'f + plant.yaw
      flowers(x + cos(angle) * plant.size * 0.75'f,
        z + sin(angle) * plant.size * 0.75'f, key div 2300, 0.9'f,
        height = plant.size * plant.height * 0.55'f)
    if key mod 7 == 0:
      detail("lupins", x - 0.35'f, z, size = 1.35'f,
        height = plant.size * 0.3'f)
  bakeTerrain(rebuildWalkability = false)

proc drawCrop*(
  art: VillageArt, tile: Tile2, kind: int, matrix: Mat4
) =
  ## Shows stocked gardens with colored boxes until crop models exist.
  const Colors = [
    vec3(0.9, 0.4, 0.1), vec3(0.8, 0.15, 0.1),
    vec3(0.3, 0.7, 0.2), vec3(0.6, 0.4, 0.2),
    vec3(0.9, 0.55, 0.1), vec3(0.7, 0.2, 0.5)
  ]
  let tint = Colors[kind mod Colors.len]
  art.placeholders.drawProp(
    "placeholder",
    villagePoint(tile) + vec3(0, GardenCropLift, 0),
    0,
    0.35'f * HouseScale,
    matrix,
    vec4(tint.x, tint.y, tint.z, 1)
  )
