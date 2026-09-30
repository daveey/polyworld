## Requires the LvD CharGen library to compare cached and fresh variants.

import
  std/[sets, tables],
  gltf,
  polyworld/[characters, chargen],
  ../examples/light_vs_dark/[appearances, assets, content, factions]

let
  manifest = readManifest(ChargenLibrary)
  roster = readCharacterRoster([Emerald, WetAsphalt])
var cache: UnitModelCache
for kind in UnitKind:
  let original = roster.players[0][kind.ord]
  var recolored = original
  recolored.skinRgb = [0.2'f, 0.4'f, 0.7'f]
  let
    first = cache.loadUnitModel(manifest, original, kind)
    second = cache.loadUnitModel(manifest, recolored, kind)
    fresh = loadUnitModel(manifest, recolored, kind)
    firstParts = partNodes(first.file.root)
    secondParts = partNodes(second.file.root)
    freshParts = partNodes(fresh.file.root)
  doAssert first != second
  doAssert first.file.root != second.file.root
  doAssert first.baseTransform == second.baseTransform
  doAssert second.baseTransform == fresh.baseTransform
  doAssert cache.loadUnitModel(manifest, original, kind) == first
  doAssert cache.loadUnitModel(manifest, recolored, kind) == second
  for name, node in secondParts:
    let
      firstNode = firstParts[name]
      freshNode = freshParts[name]
    doAssert node != firstNode
    doAssert node.visible == freshNode.visible
    for i, primitive in node.mesh.primitives:
      let
        firstPrimitive = firstNode.mesh.primitives[i]
        freshPrimitive = freshNode.mesh.primitives[i]
      doAssert primitive != firstPrimitive
      doAssert primitive.data == firstPrimitive.data
      doAssert primitive.data != nil
      doAssert primitive.material != firstPrimitive.material
      doAssert primitive.material.baseColorFactor ==
        freshPrimitive.material.baseColorFactor
      doAssert primitive.points == freshPrimitive.points
      doAssert primitive.normals == freshPrimitive.normals
      doAssert primitive.jointWeights == freshPrimitive.jointWeights
  let inventory = manifest.presetManifest(original.preset)
  for name in inventory.skinNodes:
    let tint = firstParts[name].mesh.primitives[0].material.baseColorFactor
    doAssert tint.r == original.skinRgb[0]
    doAssert tint.g == original.skinRgb[1]
    doAssert tint.b == original.skinRgb[2]
  var ownNodes: HashSet[pointer]
  for node in second.file.root.walkNodes:
    ownNodes.incl cast[pointer](node)
  for node in second.file.root.walkNodes:
    if node.skin != nil:
      for joint in node.skin.joints:
        doAssert cast[pointer](joint) in ownNodes
    for clip in node.animations:
      for channel in clip.channels:
        if channel.target != nil:
          doAssert cast[pointer](channel.target) in ownNodes
  for slot in AnimationSlot:
    let clip = second.clipIndex(kind.unitClip(slot))
    for model in [second, fresh]:
      model.file.root.activeClips = @[clip]
      model.file.root.animTime = model.clipDuration(clip) * 0.3'f
      model.file.root.updateAnimation(0)
      model.file.root.updateTransforms(model.baseTransform)
    for name, node in secondParts:
      doAssert node.mat == freshParts[name].mat
      doAssert second.file.root.skinMatrices(node) ==
        fresh.file.root.skinMatrices(freshParts[name])
  echo kind, ": cached colors, geometry, and animations match fresh loading"
