import
  std/[math, os],
  gltf, vmath,
  polyworld/[assets, treegen],
  ../views, crossings

const
  AtlasPath = TreegenTextures[0]
  StumpPath = TreegenTextures[2]

proc checkMesh(mesh: TreeMesh, atlas = false) =
  ## Checks finite geometry, unit normals, valid triangles, and UVs.
  doAssert mesh.indices.len mod 3 == 0
  for index in mesh.indices:
    doAssert index.int < mesh.vertices.len
  for vertex in mesh.vertices:
    for i in 0 ..< 3:
      doAssert classify(vertex.position[i]) notin {fcNan, fcInf, fcNegInf}
    doAssert abs(length(vertex.normal) - 1) < 0.001
    for i in 0 ..< 2:
      doAssert classify(vertex.uv[i]) notin {fcNan, fcInf, fcNegInf}
      if atlas:
        doAssert vertex.uv[i] >= 0 and vertex.uv[i] <= 1
  for i in countup(0, mesh.indices.high, 3):
    let
      a = mesh.vertices[mesh.indices[i]].position
      b = mesh.vertices[mesh.indices[i + 1]].position
      c = mesh.vertices[mesh.indices[i + 2]].position
    doAssert length(cross(b - a, c - a)) > 0.00000001'f

proc testRecipes() =
  ## Exercises every preset, reproducible variation, and UV region choice.
  for i in 0 .. 9:
    for seed in [0, 42, 999, 1_000_000_000]:
      let
        settings = preset(i, seed)
        geometry = generateGeometry(settings)
      geometry.bark.checkMesh()
      geometry.foliage.checkMesh(atlas = true)
      geometry.cut.checkMesh(atlas = true)
      doAssert geometry == generateGeometry(settings)
      if settings.kind != Stump:
        doAssert geometry.cut.vertices.len == 0
      if settings.kind in {Leafless, Stump}:
        doAssert geometry.cards == 0
        doAssert geometry.foliage.vertices.len == 0
      else:
        doAssert geometry.cards > 0
        for j, vertex in geometry.foliage.vertices:
          if j >= geometry.foliage.vertices.len - CapSlices - 1:
            doAssert vertex.uv.y > 0 and vertex.uv.y < 0.25
            if settings.kind == Evergreen:
              doAssert vertex.uv.x > 0 and vertex.uv.x < 0.25
            else:
              doAssert vertex.uv.x > 0.25 and vertex.uv.x < 1
          elif settings.kind == Evergreen:
            doAssert vertex.uv.y > 0.75
          else:
            doAssert vertex.uv.y > 0.25 and vertex.uv.y < 0.75
    doAssert generateGeometry(preset(i, 42)) != generateGeometry(preset(i, 43))

proc testNodes() =
  ## Checks the game-facing generator returns directly renderable nodes.
  for i in 0 .. 9:
    let
      settings = preset(i)
      node = generate(settings)
      geometry = generateGeometry(settings)
      bark = node.mesh.primitives[0]
    doAssert node.visible and node.scale == vec3(1)
    doAssert bark.points.len == geometry.bark.vertices.len
    doAssert bark.indices32 == geometry.bark.indices
    doAssert abs(bark.material.baseColorFactor.r -
      settings.barkColor.x) < 0.001
    doAssert node.mesh.primitives.len ==
      (if settings.kind == Leafless: 1 else: 2)
    for primitive in node.mesh.primitives:
      doAssert primitive.mode == TrianglesMode
      doAssert primitive.normals.len == primitive.points.len
      doAssert primitive.uvs.len == primitive.points.len
      doAssert primitive.material.baseColor.width == 512
      doAssert primitive.material.baseColor.height == 512
    if settings.kind in {Evergreen, Broadleaf}:
      let foliage = node.mesh.primitives[1]
      doAssert foliage.indices32 == geometry.foliage.indices
      doAssert foliage.material.alphaMode == MaskAlphaMode
      doAssert abs(foliage.material.baseColorFactor.g -
        settings.leafColor.y) < 0.001
    elif settings.kind == Stump:
      doAssert node.mesh.primitives[1].indices32 == geometry.cut.indices

proc testControls() =
  ## Checks independent color, density, and branch controls at boundaries.
  var settings = preset(0)
  settings.separateLeaves = false
  let original = generateGeometry(settings)
  settings.leafColor = vec3(1, 0, 1)
  settings.barkColor = vec3(0, 0, 1)
  doAssert original == generateGeometry(settings)
  settings.rings *= 2
  let denser = generateGeometry(settings)
  doAssert original.bark == denser.bark
  doAssert denser.cards > original.cards * 3 div 2
  settings.density = 0
  doAssert generateGeometry(settings).foliage.vertices.len == 0
  settings = preset(6)
  settings.branches = 0
  settings.roots = 0
  doAssert generateGeometry(settings).limbs == 0
  for kind in BranchKind:
    settings.branchKind = kind
    settings.branches = 24
    settings.forks = 3
    settings.branchSegments = 8
    let geometry = generateGeometry(settings)
    geometry.bark.checkMesh()
    doAssert geometry.limbs > 0 and geometry.limbs <= 24 * 15
  settings = preset(3)
  settings.rings = 24
  settings.cardsPerRing = 32
  settings.shells = 3
  settings.density = 2
  let maximum = generateGeometry(settings)
  doAssert maximum.cards + maximum.omittedCards == 23 * 96 * 3
  maximum.foliage.checkMesh(atlas = true)
  settings.height = NaN.float32
  var rejected = false
  try:
    discard generateGeometry(settings)
  except TreegenError:
    rejected = true
  doAssert rejected

proc testBroadleaves() =
  ## Checks that truncation removes bottom rings and preserves the upper mesh.
  for index in 0 .. 2:
    for seed in [0, 42, 999]:
      var settings = preset(index, seed)
      settings.separateLeaves = false
      settings.irregularity = 0
      settings.leafJitter = 0
      settings.crownCoverage = 1
      let complete = generateGeometry(settings)
      for coverage in [0.5'f, 0.75'f]:
        settings.crownCoverage = coverage
        let
          clipped = generateGeometry(settings)
          cutoff = settings.crownBase +
            settings.crownHeight * (1.0'f - coverage)
        var removed = 0
        while removed < complete.cards and
          complete.foliage.vertices[removed * LeafVertices].position.y < cutoff:
            inc removed
        doAssert removed > 0
        doAssert clipped.cards == complete.cards - removed
        doAssert clipped.bark == complete.bark
        doAssert clipped.foliage.vertices ==
          complete.foliage.vertices[removed * LeafVertices .. ^1]
        for i, vertex in clipped.foliage.indices:
          doAssert vertex == complete.foliage.indices[removed * LeafIndices + i] -
            (removed * LeafVertices).uint32
  var settings = preset(3)
  let evergreen = generateGeometry(settings)
  settings.crownCoverage = 0.5'f
  doAssert generateGeometry(settings) == evergreen

proc testEvergreens() =
  ## Measures uniform card sizes and increased counts on wider lower rings.
  for index in 3 .. 5:
    for seed in [0, 42, 999]:
      var settings = preset(index, seed)
      settings.separateLeaves = false
      settings.bend = 0
      settings.irregularity = 0
      settings.leafJitter = 0
      var originalCount = 0
      for spread in [1.0'f, 1.4'f]:
        settings.crownRadius = preset(index).crownRadius * spread
        let geometry = generateGeometry(settings)
        var
          heights: seq[float32]
          counts: seq[int]
          cardLength: float32
        for card in 0 ..< geometry.cards:
          let
            start = card * LeafVertices
            left = geometry.foliage.vertices[start].position
            right = geometry.foliage.vertices[start + 2].position
            origin = geometry.foliage.vertices[start + 1].position
            tip = geometry.foliage.vertices[start + 4].position
            reach = length(tip - origin)
          if card == 0:
            cardLength = reach
          doAssert abs(reach - cardLength) < 0.0001'f
          doAssert length(origin - left) + length(right - origin) <=
            settings.leafSize * settings.leafWidth + 0.0001'f
          for vertex in start ..< start + LeafVertices:
            let
              position = geometry.foliage.vertices[vertex].position
              depth = (settings.crownBase + settings.crownHeight -
                position.y) / settings.crownHeight
              expected = settings.crownRadius * pow(depth, settings.crownShape)
              actual = length(vec2(position.x, position.z))
            doAssert abs(actual - expected) < 0.0001'f
          if heights.len == 0 or abs(origin.y - heights[^1]) > 0.0001'f:
            heights.add origin.y
            counts.add 0
          inc counts[^1]
        doAssert counts.len > 1
        doAssert counts[0] > counts[^1]
        if spread == 1:
          originalCount = geometry.cards
        else:
          doAssert geometry.cards > originalCount

proc testBark() =
  ## Measures texture density on trunks, roots, branches, forks, and caps.
  for index in [0, 3, 7]:
    for sides in [3, 8, 12]:
      var settings = preset(index)
      settings.radialSides = sides
      settings.branchMinimum = 0.001'f
      let
        original = generateGeometry(settings)
        mesh = original.bark
        density = settings.barkDensity
        stride = sides + 1
      var start = 0
      for tube in 0 .. settings.roots + original.limbs:
        let rings =
          if tube == 0:
            settings.trunkSegments + 1
          elif tube <= settings.roots:
            4
          else:
            settings.branchSegments + 1
        for ring in 0 ..< rings:
          for j in 0 ..< sides:
            let
              a = mesh.vertices[start + ring * stride + j]
              b = mesh.vertices[start + ring * stride + j + 1]
              across = length(b.position - a.position)
            doAssert abs((b.uv.x - a.uv.x) / across - density) < 0.0002'f
            if ring > 0:
              let
                below = mesh.vertices[start + (ring - 1) * stride + j]
                along = length(a.position - below.position)
              doAssert abs((below.uv.y - a.uv.y) / along - density) <
                0.0002'f
        for edge in 0 .. 1:
          let
            cap = start + (rings + edge) * stride
            center = mesh.vertices[cap]
          for j in 0 ..< sides:
            let
              vertex = mesh.vertices[cap + 1 + j]
              distance = length(vertex.position - center.position)
            doAssert abs(length(vertex.uv - center.uv) / distance -
              density) < 0.0002'f
            doAssert vertex.normal == center.normal
        start += (rings + 2) * stride
      doAssert start == mesh.vertices.len
      settings.barkDensity *= 2
      let doubled = generateGeometry(settings)
      doAssert doubled.foliage == original.foliage
      doAssert doubled.bark.indices == mesh.indices
      doAssert doubled.bark.vertices.len == mesh.vertices.len
      for i, vertex in doubled.bark.vertices:
        doAssert vertex.position == mesh.vertices[i].position
        doAssert vertex.normal == mesh.vertices[i].normal
        doAssert length(vertex.uv - mesh.vertices[i].uv * 2.0'f) < 0.0001'f
  for density in [0.0'f, -1.0'f, 3.1'f, NaN.float32, Inf.float32]:
    var
      settings = preset(0)
      rejected = false
    settings.barkDensity = density
    try:
      discard generateGeometry(settings)
    except TreegenError:
      rejected = true
    doAssert rejected

proc ringRadius(mesh: TreeMesh, start, sides: int): float32 =
  ## Measures a generated ring independently of the radius formula.
  var center = vec3(0)
  for i in 0 ..< sides:
    center += mesh.vertices[start + i].position
  center /= sides.float32
  for i in 0 ..< sides:
    result = max(result, length(mesh.vertices[start + i].position - center))

proc testForks() =
  ## Prevents child forks from bulging beyond their parent attachment ring.
  for taper in [0.5'f, 1.25'f, 2.5'f]:
    for segments in [3, 5, 8]:
      var settings = preset(6)
      settings.roots = 0
      settings.branches = 1
      settings.forks = 1
      settings.branchMinimum = 0.001'f
      settings.branchSegments = segments
      settings.taper = taper
      let
        geometry = generateGeometry(settings)
        sides = settings.radialSides
        trunkVertices = (settings.trunkSegments + 3) * (sides + 1)
        limbVertices = (segments + 3) * (sides + 1)
        attachment = trunkVertices + (segments - 1) * (sides + 1)
        parentRadius = geometry.bark.ringRadius(attachment, sides)
      doAssert geometry.limbs == 3
      for fork in 1 .. 2:
        let childRadius = geometry.bark.ringRadius(
          trunkVertices + limbVertices * fork, sides)
        doAssert childRadius < parentRadius * 0.7'f
  var settings = preset(7)
  settings.branchMinimum = 0.001'f
  let thin = generateGeometry(settings)
  settings.branchMinimum = 0.1'f
  let pruned = generateGeometry(settings)
  doAssert pruned.limbs < thin.limbs

proc testClearance() =
  ## Keeps complete foliage cards above the stem even with extreme droop.
  for index in [0, 3, 4, 5]:
    var settings = preset(index)
    settings.crownBase = 0.3'f
    settings.stemClearance = 0.8'f
    settings.droop = 1.5'f
    settings.curl = 0.8'f
    settings.leafJitter = 0.6'f
    let geometry = generateGeometry(settings)
    for vertex in geometry.foliage.vertices:
      doAssert vertex.position.y >= settings.stemClearance - 0.0001'f
  var settings = preset(6)
  settings.roots = 0
  settings.branchKind = Drooping
  settings.branchStart = 0.1'f
  settings.branchLength = 5.0'f
  settings.stemClearance = 1.0'f
  let
    geometry = generateGeometry(settings)
    trunkVertices = (settings.trunkSegments + 3) *
      (settings.radialSides + 1)
  for i in trunkVertices ..< geometry.bark.vertices.len:
    doAssert geometry.bark.vertices[i].position.y >= 0.9999'f

proc testRoots() =
  ## Measures downward claw slopes from the generated root ring centers.
  let
    settings = preset(6)
    geometry = generateGeometry(settings)
    sides = settings.radialSides
    trunkVertices = (settings.trunkSegments + 3) * (sides + 1)
    rootVertices = 6 * (sides + 1)
  for root in 0 ..< settings.roots:
    var knee, tip: Vec3
    for i in 0 ..< sides:
      let start = trunkVertices + root * rootVertices
      knee += geometry.bark.vertices[start + 2 * (sides + 1) + i].position
      tip += geometry.bark.vertices[start + 3 * (sides + 1) + i].position
    knee /= sides.float32
    tip /= sides.float32
    let
      delta = tip - knee
      horizontal = length(vec2(delta.x, delta.z))
      slope = arctan2(-delta.y, horizontal) * 180.0'f / PI.float32
    doAssert abs(slope - 30.0'f) < 0.001'f
    doAssert tip.y < -0.04'f

proc hitsLeaf(mesh: TreeMesh, material: Material, start: int,
    origin, direction: Vec3): bool =
  ## Tests ray coverage using the actual atlas alpha at triangle hits.
  for i in countup(start, mesh.indices.high, 3):
    let
      a = mesh.vertices[mesh.indices[i]]
      b = mesh.vertices[mesh.indices[i + 1]]
      c = mesh.vertices[mesh.indices[i + 2]]
      edge = b.position - a.position
      side = c.position - a.position
      perpendicular = cross(direction, side)
      determinant = dot(edge, perpendicular)
    if abs(determinant) < 0.000001'f:
      continue
    let
      relative = origin - a.position
      u = dot(relative, perpendicular) / determinant
      across = cross(relative, edge)
      v = dot(direction, across) / determinant
      distance = dot(side, across) / determinant
    if u < 0 or v < 0 or u + v > 1 or distance <= 0:
      continue
    let
      uv = a.uv * (1.0'f - u - v) + b.uv * u + c.uv * v
      image = material.baseColor
      x = clamp((uv.x * image.width.float32).int, 0, image.width - 1)
      y = clamp((uv.y * image.height.float32).int, 0, image.height - 1)
    if image.data[y * image.width + x].a.float32 / 255.0'f >=
      material.alphaCutoff:
        return true

proc testCaps() =
  ## Checks cap topology, continuous UVs, raised centers, and alpha coverage.
  let material = loadMaterials(1).foliage
  for index in [0, 1, 2, 3, 4, 5]:
    for seed in [0, 42, 999]:
      var settings = preset(index, seed)
      settings.separateLeaves = false
      settings.shells = 1
      settings.irregularity = 0.65'f
      let
        geometry = generateGeometry(settings)
        mesh = geometry.foliage
        firstVertex = mesh.vertices.len - CapSlices - 1
        firstIndex = mesh.indices.len - CapSlices * 3
        center = mesh.vertices[firstVertex]
        rim = mesh.vertices[firstVertex + 1]
        rise = center.position.y - rim.position.y
        radius = length(vec2(rim.position.x - center.position.x,
          rim.position.z - center.position.z))
        slope = arctan2(rise, radius) * 180.0'f / PI.float32
        column = (center.uv.x * 4).int
      doAssert firstVertex == geometry.cards * LeafVertices
      doAssert firstIndex == geometry.cards * LeafIndices
      doAssert rise > 0
      if settings.kind == Broadleaf:
        doAssert abs(slope - settings.capSlope) < 0.0001'f
      else:
        let expectedRise = settings.crownHeight *
          pow(radius / settings.crownRadius, 1.0'f / settings.crownShape)
        doAssert abs(rise - expectedRise) < 0.0001'f
      if settings.kind == Evergreen:
        var highestLeaf = -Inf.float32
        for i in 0 ..< firstVertex:
          highestLeaf = max(highestLeaf, mesh.vertices[i].position.y)
        doAssert highestLeaf > center.position.y - settings.leafSize * 0.25'f
        doAssert highestLeaf < center.position.y
      doAssert center.uv == vec2((column.float32 + 0.5'f) * 0.25'f, 0.125'f)
      for i in 0 ..< CapSlices:
        let
          a = mesh.vertices[mesh.indices[firstIndex + i * 3]]
          b = mesh.vertices[mesh.indices[firstIndex + i * 3 + 1]]
          c = mesh.vertices[mesh.indices[firstIndex + i * 3 + 2]]
          uvEdge = b.uv - a.uv
          uvSide = c.uv - a.uv
        doAssert mesh.indices[firstIndex + i * 3].int == firstVertex
        doAssert dot(cross(b.position - a.position,
          c.position - a.position), vec3(0, 1, 0)) > 0
        doAssert uvEdge.x * uvSide.y - uvEdge.y * uvSide.x < 0
        doAssert abs(length(b.uv - center.uv) - 0.1225'f) < 0.00001'f
        doAssert abs(b.position.y - rim.position.y) < 0.00001'f
        doAssert (b.uv.x * 4).int == column
        doAssert b.uv.y > 0 and b.uv.y < 0.25
      for pitch in [0.2'f, 0.65'f, 1.5'f]:
        for angle in 0 ..< 8:
          let
            yaw = angle.float32 * PI.float32 / 4.0'f
            direction = vec3(cos(yaw) * cos(pitch), sin(pitch),
              sin(yaw) * cos(pitch))
          for x in -1 .. 1:
            for z in -1 .. 1:
              let target = center.position - vec3(0, rise * 0.08'f, 0) +
                vec3(x.float32, 0, z.float32) * radius * 0.025'f
              doAssert mesh.hitsLeaf(
                material,
                firstIndex,
                target + direction * radius * 3.0'f,
                -direction
              ), "Uncovered cap: " & $index & " seed " & $seed
      settings.capSize = 1.5'f
      settings.capSlope = 35.0'f
      let adjusted = generateGeometry(settings)
      doAssert adjusted.bark == geometry.bark
      doAssert adjusted.cards == geometry.cards
      for i in 0 ..< firstVertex:
        doAssert adjusted.foliage.vertices[i] == mesh.vertices[i]
      for i in firstVertex ..< mesh.vertices.len:
        doAssert adjusted.foliage.vertices[i].uv == mesh.vertices[i].uv
  var columns: set[0 .. 3]
  for seed in 0 .. 31:
    let
      geometry = generateGeometry(preset(0, seed))
      center = geometry.foliage.vertices[^(CapSlices + 1)]
    columns.incl (center.uv.x * 4).int
  doAssert columns == {1, 2, 3}
  let cell = material.baseColor.width div 4
  for column in 0 .. 3:
    for y in 0 ..< cell:
      for x in 0 ..< cell:
        let pixel = material.baseColor.data[
          y * material.baseColor.width + column * cell + x]
        if pixel.a.float32 / 255.0'f >= material.alphaCutoff:
          # All visible texels fit inside the fan, including between corners.
          let offset = vec2(x.float32 + 0.5'f, y.float32 + 0.5'f) -
            vec2(cell.float32 * 0.5'f)
          doAssert length(offset) <
            cell.float32 * 0.49'f * cos(PI.float32 / CapSlices.float32)

proc testStumps() =
  ## Checks closed level cuts, exact rim joins, and roots below the cut plane.
  for seed in [0, 42, 999]:
    for height in [0.3'f, 0.95'f, 3.0'f]:
      for sides in [3, 8, 12]:
        var settings = preset(9, seed)
        settings.height = height
        settings.radialSides = sides
        settings.trunkRadius = 1.4
        settings.rootThickness = 1.5
        settings.bend = 0.8
        settings.branches = 24
        settings.forks = 3
        let
          geometry = generateGeometry(settings)
          cap = geometry.cut
          rim = settings.trunkSegments * (sides + 1)
        geometry.bark.checkMesh()
        cap.checkMesh(atlas = true)
        doAssert geometry.limbs == 0 and geometry.cards == 0
        doAssert geometry.foliage.vertices.len == 0
        doAssert cap.vertices.len == sides + 1
        doAssert cap.indices.len == sides * 3
        doAssert abs(geometry.maximum.y - height) < 0.00001'f
        for j, vertex in cap.vertices:
          doAssert abs(vertex.position.y - height) < 0.00001'f
          doAssert vertex.normal == vec3(0, 1, 0)
          doAssert length(vertex.uv - vec2(0.5)) <= 0.43001'f
          if j > 0:
            doAssert vertex.position ==
              geometry.bark.vertices[rim + j - 1].position
        for j in 0 ..< sides:
          let
            a = cap.vertices[cap.indices[j * 3]]
            b = cap.vertices[cap.indices[j * 3 + 1]]
            c = cap.vertices[cap.indices[j * 3 + 2]]
          doAssert cross(b.position - a.position, c.position - a.position).y > 0
          doAssert length(b.position - a.position) >
            settings.trunkRadius * 0.4'f
  let rings = loadStraightAlphaImage(StumpPath)
  for y in 0 ..< rings.height:
    for x in 0 ..< rings.width:
      let uv = vec2(x.float32, y.float32) / rings.width.float32
      if length(uv - vec2(0.5)) <= 0.432'f:
        doAssert rings.data[y * rings.width + x].a == 255

proc testFiles() =
  ## Checks recipe round trips, alpha preservation, and portable GLB output.
  let
    directory = getTempDir() / "polyworld-treegen-tests"
    settings = preset(3, 2718)
    materials = loadMaterials(settings.barkTexture)
  createDir(directory)
  settings.saveSettings(directory / "tree.json")
  doAssert loadSettings(directory / "tree.json") == settings
  doAssert materials.foliage.alphaMode == MaskAlphaMode
  doAssert materials.foliage.doubleSided
  doAssert materials.foliage.baseColor.width == 512
  doAssert materials.foliage.baseColor.height == 512
  doAssert materials.foliage.baseColor.data[128 * 512].a == 0
  doAssert materials.foliage.baseColor.data ==
    loadStraightAlphaImage(AtlasPath).data
  doAssert materials.foliage.baseColorSampler.wrapS == ClampToEdgeWrap
  doAssert materials.foliage.baseColorSampler.wrapT == ClampToEdgeWrap
  doAssert materials.bark.baseColor.width == 512
  doAssert materials.bark.baseColor.height == 512
  doAssert materials.cut.baseColor.width == 512
  doAssert materials.cut.baseColor.height == 512
  doAssert materials.cut.baseColor.data ==
    loadStraightAlphaImage(StumpPath).data
  doAssert materials.bark.baseColorSampler.wrapS == RepeatWrap
  doAssert materials.bark.baseColorSampler.wrapT == RepeatWrap
  for pixel in materials.bark.baseColor.data:
    doAssert pixel.r == pixel.g and pixel.g == pixel.b
    doAssert pixel.a == 255
  for pixel in loadMaterials(0).bark.baseColor.data:
    doAssert pixel.r == 255 and pixel.g == 255 and pixel.b == 255
  settings.exportTree(directory / "tree.glb")
  doAssert readFile(directory / "tree.glb")[0 .. 3] == "glTF"
  let exported = loadModel(directory / "tree.glb")
  var
    materialsFound = 0
    foliageFound = false
    barkFound = false
  for node in exported.walkNodes():
    if node.mesh != nil:
      for primitive in node.mesh.primitives:
        inc materialsFound
        doAssert primitive.points.len > 0
        if primitive.material.alphaMode == MaskAlphaMode:
          foliageFound = true
          doAssert primitive.material.doubleSided
          doAssert primitive.material.baseColor.width == 512
          doAssert abs(primitive.material.baseColorFactor.g -
            settings.leafColor.y) < 0.001
          doAssert primitive.uvs ==
            treeNode(generateGeometry(settings), materials).mesh.primitives[1].uvs
        else:
          barkFound = true
          doAssert primitive.material.baseColor.width == 512
          doAssert primitive.material.baseColor.height == 512
          doAssert primitive.material.baseColorSampler.wrapS == RepeatWrap
          doAssert primitive.material.baseColorSampler.wrapT == RepeatWrap
          doAssert primitive.uvs ==
            treeNode(generateGeometry(settings), materials).mesh.primitives[0].uvs
  doAssert materialsFound == 2 and foliageFound and barkFound
  let stump = preset(9, 123)
  stump.saveSettings(directory / "stump.json")
  doAssert loadSettings(directory / "stump.json") == stump
  stump.exportTree(directory / "stump.glb")
  let exportedStump = loadModel(directory / "stump.glb")
  var cutsFound = 0
  for node in exportedStump.walkNodes():
    if node.mesh != nil:
      doAssert node.mesh.primitives.len == 2
      for i, primitive in node.mesh.primitives:
        doAssert primitive.material.alphaMode == OpaqueAlphaMode
        if i == 1:
          inc cutsFound
          doAssert primitive.material.baseColor.width == 512
          doAssert primitive.material.baseColor.height == 512
          doAssert primitive.material.baseColor.data[256 * 512 + 256] ==
            materials.cut.baseColor.data[256 * 512 + 256]
          doAssert primitive.uvs ==
            treeNode(generateGeometry(stump), materials).mesh.primitives[1].uvs
  doAssert cutsFound == 1
  writeFile(directory / "bad.json", "{broken")
  var rejected = false
  try:
    discard loadSettings(directory / "bad.json")
  except TreegenError:
    rejected = true
  doAssert rejected
  writeFile(directory / "older.json", "{\"seed\":7}")
  let older = loadSettings(directory / "older.json")
  doAssert older.seed == 7 and older.packing > 0
  doAssert older.stemClearance > 0 and older.branchMinimum > 0
  doAssert older.barkDensity == preset(0).barkDensity
  doAssert older.separateLeaves
  doAssert older.crownCoverage == 0.75'f
  doAssert older.capSize == 1 and older.capSlope == 20
  removeDir(directory)

proc testPlants() =
  ## Checks plant silhouettes, texture isolation, seeds, and portable exports.
  for i in 10 .. PresetNames.high:
    for seed in [0, 42, 999]:
      let
        settings = preset(i, seed)
        geometry = generateGeometry(settings)
      for mesh in [geometry.bark, geometry.foliage, geometry.cut,
          geometry.flowers, geometry.stems, geometry.crown]:
        mesh.checkMesh()
        for vertex in mesh.vertices:
          for axis in 0 ..< 3:
            doAssert vertex.position[axis] >= geometry.minimum[axis]
            doAssert vertex.position[axis] <= geometry.maximum[axis]
      doAssert geometry == generateGeometry(settings)
      doAssert geometry.foliage.indices.len > 0
      doAssert geometry.foliage.indices.len < 60_000
      if settings.kind in {Bush, Hedge, FlowerPatch}:
        doAssert geometry.minimum.y >= -0.05
      if settings.flowerKind != NoFlowers:
        doAssert geometry.blooms > 0 and geometry.flowers.indices.len > 0
        let node = generate(settings)
        doAssert node.mesh.primitives.len >= 3
        var found = false
        for primitive in node.mesh.primitives:
          if primitive.material.name == "Colored flowers":
            found = true
            doAssert primitive.material.baseColorFactor.r == 1
            doAssert primitive.material.alphaMode == MaskAlphaMode
            doAssert primitive.material.doubleSided
            doAssert primitive.material.baseColor.width == 512
        doAssert found
      if settings.kind != FlowerPatch:
        var bare = settings
        bare.flowerKind = NoFlowers
        let leaves = generateGeometry(bare)
        doAssert leaves.foliage == geometry.foliage
        doAssert leaves.bark == geometry.bark
    doAssert generateGeometry(preset(i, 42)) != generateGeometry(preset(i, 43))
  var previous = 0.0'f
  for size in BushSize:
    var settings = preset(12)
    settings.setBushSize(size)
    let geometry = generateGeometry(settings)
    doAssert geometry.maximum.y > previous
    previous = geometry.maximum.y
  var hedge = preset(14)
  hedge.plantWidth = 8
  let shape = generateGeometry(hedge)
  doAssert shape.maximum.x - shape.minimum.x >
    (shape.maximum.z - shape.minimum.z) * 3
  let
    directory = getTempDir() / "polyworld-flower-tests"
    path = directory / "flowers.glb"
  preset(20).exportTree(path)
  let imported = loadModel(path)
  var primitives = 0
  for node in imported.walkNodes():
    if node.mesh != nil:
      primitives += node.mesh.primitives.len
      for primitive in node.mesh.primitives:
        doAssert primitive.material.baseColor.width == 512
  doAssert primitives == 5
  preset(21).saveSettings(directory / "hedge.json")
  doAssert loadSettings(directory / "hedge.json") == preset(21)
  removeDir(directory)

echo "Testing bushes, hedges, and flower layers"
testPlants()
echo "Testing tree recipes and deterministic seeds"
testRecipes()
echo "Testing game-facing renderable tree nodes"
testNodes()
echo "Testing tree parameter boundaries"
testControls()
echo "Testing broadleaf sphere coverage and removal of hidden rings"
testBroadleaves()
echo "Testing uniform evergreen cards and circumference-based counts"
testEvergreens()
echo "Testing visible foliage intersections against the atlas alpha"
testCrossings()
echo "Testing consistent bark density and independent UV scaling"
testBark()
echo "Testing fork attachment thickness and stem clearance"
testForks()
testClearance()
echo "Testing downward root claws"
testRoots()
echo "Testing cap topology, UVs, and alpha coverage from all sides"
testCaps()
echo "Testing stump cuts, growth-ring UVs, and root clearance"
testStumps()
echo "Testing atlas, presets, and GLB export"
testFiles()
echo "Treegen tests passed"
