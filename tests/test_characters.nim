import gltf, vmath
import polyworld/[animblend, characters]

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
  doAssert first.toon.meshes.len == 0
  body.baseVisible = true
  scene.prepareCharacter(first, model, vec3(0), 0, 0, 0)
  doAssert first.toon.meshes.len == 1
  doAssert first.toon.meshes[0].joints == root.skinMatrices(body)

echo "Character tests passed"
