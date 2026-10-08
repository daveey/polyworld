import gltf, vmath
import polyworld/[animblend, characters, frustums, shadowmeshes]

proc node(name = "", pos = vec3(0)): Node =
  ## Creates a visible node with an explicit rest transform.
  Node(name: name, visible: true, baseVisible: true,
    pos: pos, basePos: pos, scale: vec3(1), baseScale: vec3(1),
    rot: quat(), baseRot: quat())

echo "Character sockets use the player's owned animated pose"
block:
  let
    root = node()
    hand = node("hand_r", vec3(1, 2, 3))
  root.nodes = @[hand]
  root.animations = @[AnimationClip(name: "move", duration: 1,
    channels: @[AnimationChannel(target: hand, path: AnimTranslation,
      interpolation: aiLinear, times: @[0'f32, 1],
      valuesVec3: @[vec3(1, 2, 3), vec3(4, 6, 8)])])]
  let
    model = CharacterModel(file: GltfFile(root: root), baseTransform: mat4())
    player = newClipPlayer(root)
  player.play(0, fade = 0)
  player.seek(1)

  let other = newClipPlayer(root)
  other.play(0, fade = 0)
  other.seek(0)
  let transform = model.handTransform(
    player, "hand_r", vec3(5, 0, 0), facing = 0)
  doAssert length(transform.pos - vec3(9, 6, 8)) < 1e-6

  let gearRoot = node("sword")
  doAssert model.attachGear(gearRoot, "hand_r").root == gearRoot

echo "Prepared poses survive other instances sharing the model"
block:
  let
    root = node()
    joint = node("joint")
    body = node("body")
    scene = CharacterScene(shading: ToonCharacters)
  root.nodes = @[joint, body]
  body.mesh = Mesh()
  body.skin = Skin(joints: @[joint], inverseBindMatrices: @[mat4()])
  root.animations = @[
    AnimationClip(
      name: "move",
      duration: 1,
      channels: @[
        AnimationChannel(
          target: joint,
          path: AnimTranslation,
          interpolation: aiLinear,
          times: @[0.0'f, 1],
          valuesVec3: @[vec3(0), vec3(0, 2, 0)]
        )
      ]
    )
  ]
  let model = CharacterModel(file: GltfFile(root: root), baseTransform: mat4())
  var first, second: CharacterPose
  scene.prepareCharacter(first, model, vec3(10, 0, 0), 0.3, 0, 0.25)
  let
    firstTransform = first.toon.meshes[0].transform
    firstJoints = first.toon.meshes[0].joints
    storage = unsafeAddr first.toon.meshes[0].joints[0]
  doAssert firstTransform == body.mat
  doAssert firstJoints == root.skinMatrices(body)
  scene.prepareCharacter(second, model, vec3(-10, 0, 0), 0.8, 0, 0.75)
  doAssert second.toon.meshes[0].transform == body.mat
  doAssert second.toon.meshes[0].joints == root.skinMatrices(body)
  doAssert first.toon.meshes[0].transform == firstTransform
  doAssert first.toon.meshes[0].joints == firstJoints
  doAssert firstJoints != second.toon.meshes[0].joints
  scene.prepareCharacter(first, model, vec3(10, 0, 0), 0.3, 0, 0.25)
  doAssert unsafeAddr(first.toon.meshes[0].joints[0]) == storage
  doAssert first.toon.meshes[0].joints == firstJoints
  body.baseVisible = false
  scene.prepareCharacter(first, model, vec3(0), 0, 0, 0)
  doAssert first.toon.meshCount == 0
  doAssert first.toon.meshes.len == 1
  body.baseVisible = true
  scene.prepareCharacter(first, model, vec3(0), 0, 0, 0)
  doAssert first.toon.meshCount == 1
  doAssert unsafeAddr(first.toon.meshes[0].joints[0]) == storage
  doAssert first.toon.meshes[0].joints == root.skinMatrices(body)
  when defined(nimTypeNames):
    let before = getMemCounters()
    for i in 0 ..< 100:
      body.baseVisible = i mod 2 == 0
      scene.prepareCharacter(first, model, vec3(0), 0, 0, i.float32 / 100)
      doAssert first.toon.meshCount == (i mod 2 == 0).ord
    let after = getMemCounters()
    doAssert after[0] == before[0], "Prepared pose storage must be reused."

echo "Prepared poses retain each instance's visible eyes"
block:
  let
    root = node()
    livingEyes = node("living eyes")
    deadEyes = node("dead eyes")
    model = CharacterModel(
      file: GltfFile(root: root),
      baseTransform: mat4(),
      unlitParts: @["living eyes", "dead eyes"]
    )
    scene = CharacterScene(shading: ToonCharacters)
  root.nodes = @[livingEyes, deadEyes]
  livingEyes.mesh = Mesh()
  deadEyes.mesh = Mesh()
  deadEyes.baseVisible = false
  var living, dead: CharacterPose
  scene.prepareCharacter(living, model, vec3(0), 0, 0, 0)
  livingEyes.baseVisible = false
  deadEyes.baseVisible = true
  scene.prepareCharacter(dead, model, vec3(2, 0, 0), 1, 0, 0)
  doAssert living.toon.meshCount == 1
  doAssert living.toon.meshes[0].unlit
  doAssert living.toon.meshes[0].node == livingEyes
  doAssert dead.toon.meshCount == 1
  doAssert dead.toon.meshes[0].unlit
  doAssert dead.toon.meshes[0].node == deadEyes
  # A subsequent instance must not erase either earlier drawing snapshot.
  livingEyes.baseVisible = true
  deadEyes.baseVisible = false
  var next: CharacterPose
  scene.prepareCharacter(next, model, vec3(4, 0, 0), 2, 0, 0)
  doAssert not deadEyes.visible
  doAssert dead.toon.meshes[0].node == deadEyes
  doAssert dead.toon.meshes[0].transform != next.toon.meshes[0].transform

echo "Animated bounds contain skinned vertices and refreshed geometry"
block:
  let
    root = node()
    first = node("first", vec3(-3, 0, 0))
    second = node("second", vec3(5, 2, 0))
    body = node("body", vec3(1, 0, 0))
    primitive = Primitive(
      points: @[vec3(2, 1, 0), vec3(-1, 2, 3)],
      jointIds: @[[0'u16, 1, 0, 0], [1'u16, 0, 0, 0]],
      jointWeights: @[vec4(0.4, 0.9, 0, 0), vec4(0.8, 0, 0, 0)]
    )
    model = CharacterModel(file: GltfFile(root: root), baseTransform: mat4())
    scene = CharacterScene(shading: ToonCharacters)
  root.nodes = @[first, second, body]
  body.mesh = Mesh(primitives: @[primitive])
  body.skin = Skin(
    joints: @[first, second], inverseBindMatrices: @[mat4(), mat4()])
  root.animations = @[
    AnimationClip(name: "move", duration: 1, channels: @[
      AnimationChannel(target: second, path: AnimTranslation,
        interpolation: aiLinear, times: @[0.0'f, 1],
        valuesVec3: @[vec3(5, 2, 0), vec3(-5, 8, 2)])
    ])
  ]
  var pose: CharacterPose
  for time in [0.0'f, 0.25, 0.5, 1.0]:
    scene.prepareCharacter(pose, model, vec3(120, 30, 20), 0.7, 0, time)
    doAssert pose.toon.boundsValid
    let mesh = pose.toon.meshes[0]
    for i, point in primitive.points:
      var skinned = vec4(0)
      for j in 0 ..< 4:
        skinned +=
          (mesh.joints[primitive.jointIds[i][j].int] * vec4(point, 1)) *
          primitive.jointWeights[i][j]
      let world = (mesh.transform * skinned).xyz
      for axis in 0 ..< 3:
        doAssert world[axis] >= pose.toon.bounds.min[axis]
        doAssert world[axis] <= pose.toon.bounds.max[axis]
  let previous = pose.toon.bounds
  primitive.points[0] = vec3(100, 0, 0)
  inc primitive.geometryVersion
  scene.prepareCharacter(pose, model, vec3(120, 30, 20), 0.7, 0, 1)
  doAssert pose.toon.bounds.max.x > previous.max.x
  primitive.jointWeights[0].x = -1
  inc primitive.geometryVersion
  scene.prepareCharacter(pose, model, vec3(0), 0, 0, 0)
  doAssert not pose.toon.boundsValid

echo "Frustum rejection retains intersecting boxes and rejects hidden boxes"
block:
  let
    projection = perspective(45.0'f, 1.6, 0.1, 100)
    front = AABounds(min: vec3(-1, -1, -10), max: vec3(1, 1, -8))
    behind = AABounds(min: vec3(-1, -1, 2), max: vec3(1, 1, 4))
    side = AABounds(min: vec3(100, -1, -10), max: vec3(101, 1, -8))
    crossing = AABounds(min: vec3(-100, -1, -10), max: vec3(100, 1, 1))
  doAssert front.inFrustum(projection)
  doAssert not behind.inFrustum(projection)
  doAssert not side.inFrustum(projection)
  doAssert crossing.inFrustum(projection)
  doAssert not emptyBounds().inFrustum(projection)
  doAssert front.inFrustum(mat4()) == false
  doAssert front.transformed(translate(vec3(0, 0, 9))).inFrustum(mat4())

echo "Shadow batching retains skinning, cutouts, and triangle indices"
block:
  let
    material = Material(alphaMode: OpaqueAlphaMode)
    first = Primitive(
      mode: TrianglesMode, material: material,
      points: @[vec3(0), vec3(1, 0, 0), vec3(0, 1, 0)],
      indices16: @[0'u16, 1, 2],
      jointIds: @[[0'u16, 0, 0, 0], [0'u16, 0, 0, 0], [0'u16, 0, 0, 0]],
      jointWeights: @[vec4(1, 0, 0, 0), vec4(1, 0, 0, 0), vec4(1, 0, 0, 0)]
    )
    second = Primitive(
      mode: TrianglesMode, material: Material(alphaMode: OpaqueAlphaMode),
      points: @[vec3(2, 0, 0), vec3(3, 0, 0), vec3(2, 1, 0)],
      indices32: @[0'u32, 2, 1],
      jointIds: first.jointIds,
      jointWeights: first.jointWeights
    )
    cutout = Primitive(material: Material(alphaMode: MaskAlphaMode))
    blended = Primitive(material: Material(alphaMode: BlendAlphaMode))
    mesh = Mesh(primitives: @[first, cutout, second, blended])
    shadows = mesh.shadowPrimitives()
  doAssert shadows.len == 2
  doAssert shadows[0].material != material
  doAssert shadows[1] == cutout
  doAssert shadows[0].points == first.points & second.points
  doAssert shadows[0].jointIds == first.jointIds & second.jointIds
  doAssert shadows[0].jointWeights == first.jointWeights & second.jointWeights
  doAssert shadows[0].indices16 == @[0'u16, 1, 2, 3, 5, 4]
  doAssert mesh.primitives == @[first, cutout, second, blended]
  let unskinned = Primitive(mode: TrianglesMode, material: material,
    points: second.points, indices32: second.indices32)
  let mixed = Mesh(primitives: @[first, unskinned, cutout])
  doAssert mixed.shadowPrimitives() == mixed.primitives
  let
    large = Primitive(mode: TrianglesMode, material: material,
      points: newSeq[Vec3](65_536), indices16: @[0'u16, 1, 2])
    small = Primitive(mode: TrianglesMode, material: material,
      points: @[vec3(0), vec3(1), vec3(2)])
    combined = Mesh(primitives: @[large, small]).shadowPrimitives()[0]
  doAssert combined.indices16.len == 0
  doAssert combined.indices32 == @[0'u32, 1, 2, 65_536, 65_537, 65_538]

echo "Character tests passed"
