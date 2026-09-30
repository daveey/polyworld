import
  std/[math, os, sets, strutils, tables],
  gltf, vmath,
  polyworld/[assets, characters, chargen, common],
  ../examples/light_vs_dark/[appearances, assets, content, factions],
  ../tools/posedbounds

proc selected(preset: Preset, category: string): string =
  ## Returns a selected part so missing equipment is checked explicitly.
  for part in preset.parts:
    if part.category == category:
      return part.item
  "None"

proc checkModel(manifest: Manifest, entry: UnitPreset, kind: UnitKind) =
  ## Verifies grounding, relative body size and every game animation slot.
  let
    model = loadUnitModel(manifest, entry, kind)
    inventory = manifest.presetManifest(entry.preset)
    nodes = partNodes(model.file.root)
  var
    bodies: HashSet[string]
    visibility: Table[string, bool]
  for category in inventory.categories:
    if category.key in ["Body", "Face"]:
      for item in category.items:
        for name in item.nodes:
          bodies.incl name
  for name, node in nodes:
    visibility[name] = node.visible
    node.visible = name in bodies
  model.file.root.updateTransforms(model.baseTransform)
  let bodyBounds = posedBounds(model.file.root, visibleOnly = true)
  doAssert abs(bodyBounds.min.y) < 0.001, entry.preset.name
  doAssert abs(bodyBounds.max.y - UnitHeights[kind]) < 0.001
  for name, node in nodes:
    node.visible = visibility[name]
  for slot in AnimationSlot:
    let
      clip = model.clipIndex(kind.unitClip(slot))
      duration = model.clipDuration(clip)
    doAssert duration > 0
    for time in [0'f, duration / 2, duration]:
      model.file.root.activeClips = @[clip]
      model.file.root.animTime = time
      model.file.root.updateAnimation(0)
      model.file.root.updateTransforms(model.baseTransform)
      let bounds = posedBounds(model.file.root, visibleOnly = true)
      for axis in 0 ..< 3:
        doAssert classify(bounds.min[axis]) notin {fcNan, fcInf, fcNegInf}
        doAssert classify(bounds.max[axis]) notin {fcNan, fcInf, fcNegInf}
        doAssert bounds.max[axis] > bounds.min[axis]
  for name in inventory.skinNodes:
    for primitive in nodes[name].mesh.primitives:
      let tint = primitive.material.baseColorFactor
      doAssert abs(tint.r - entry.skinRgb[0]) < 0.00001
      doAssert abs(tint.g - entry.skinRgb[1]) < 0.00001
      doAssert abs(tint.b - entry.skinRgb[2]) < 0.00001

let
  manifest = readManifest(ChargenLibrary)
  roster = readCharacterRoster([Emerald, WetAsphalt])

for player in 0 ..< FactionCount:
  for kind in UnitKind:
    let entry = roster.players[player][kind.ord]
    doAssert entry.preset.selected("Hair") == "None"
    if kind != SummonUnit:
      doAssert entry.skinRgb == roster.factions[player].skinRgb()
    if kind == KnightUnit:
      doAssert entry.preset.selected("Headgear") == "Vanguard Knight helmet"
    checkModel(manifest, entry, kind)
    doAssert fileExists(unitPortraitPath(player.int32, kind))
    if kind == PeonUnit:
      doAssert entry.preset.selected("Right hand") == "None"
      doAssert entry.preset.selected("Left hand") == "None"
    if kind == CatapultUnit:
      doAssert entry.preset.selected("Right hand") == "Medieval crossbow"
      doAssert UnitTable[player][kind].splash > 0
    if kind == SummonUnit:
      doAssert entry.skinRgb == [1'f, 0.36'f, 0.02'f]
      for part in entry.preset.parts:
        if part.category notin ["Body", "Face"]:
          doAssert part.item == "None", "Elemental has " & part.category
    echo player, " ", kind, ": model, scale and animations passed."

for kind in UnitKind:
  for part in roster.players[0][kind.ord].preset.parts:
    if part.category notin ["Eyes", "Ears", "Mouth"]:
      doAssert roster.players[1][kind.ord].preset.selected(part.category) ==
        part.item

for clip in manifest.clips:
  if clip.name in CharacterClips:
    doAssert clip.kind == "universal", "Legacy animation selected."

for asset in browserAssets():
  doAssert "mini_legion" notin asset.source
  doAssert "rpg_monsters" notin asset.source
  if asset.kind in {FileAsset, ModelAsset, ImageAsset}:
    doAssert fileExists(DataRoot / asset.source), asset.source
  if asset.kind in {ModelAsset, ImageAsset}:
    for name in ["original2", "neutral", "happy", "angry"]:
      doAssert "/eyes/" & name & "." notin asset.source

echo "LvD CharGen integration passed."
