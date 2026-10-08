import
  std/[os, random, sets, strutils, tables],
  chroma, gltf, jsony, vmath,
  polyworld/[animblend, chargen], weights, lineups

const AssetDir = ChargenLibrary

proc testRandom() =
  ## Checks tag parsing, filtered rolls, shared parts, and sparse libraries.
  doAssert "{}".fromJson(PartItem).alignment == Both
  for (value, expected) in [("both", Both), ("good", GoodOnly),
                            ("evil", EvilOnly), ("gnome", GnomeOnly)]:
    let item = ("{\"alignment\":\"" & value & "\"}").fromJson(PartItem)
    doAssert item.alignment == expected
  var failed = false
  try:
    discard "{\"alignment\":\"unknown\"}".fromJson(PartItem)
  except JsonError:
    failed = true
  doAssert failed
  let manifest = readManifest(AssetDir)
  for alignment in [Both, GoodOnly, EvilOnly]:
    var
      rng = initRand(27)
      matching = initRand(27)
      seen: HashSet[string]
      emptyOptional = false
    for roll in 0 ..< 512:
      let selection = manifest.randomSelection(rng, alignment)
      doAssert selection == manifest.randomSelection(matching, alignment)
      doAssert selection.len == manifest.categories.len
      for i, category in manifest.categories:
        let selected = selection[i]
        if category.items.len > 0 and
          category.key in ["Body", "Face", "Eyes", "Mouth"]:
            doAssert selected >= 0
        if selected < 0:
          if category.items.len > 0:
            emptyOptional = true
          continue
        let item = category.items[selected]
        case alignment
        of Both:
          discard
        of GoodOnly:
          doAssert item.alignment in {Both, GoodOnly}
        of EvilOnly:
          doAssert item.alignment in {Both, EvilOnly}
        of GnomeOnly:
          doAssert false, "Gnome rolls have separate checks."
        seen.incl item.id
    doAssert emptyOptional
    for category in manifest.categories:
      for item in category.items:
        if alignment == Both or item.alignment in {Both, alignment}:
          doAssert item.id in seen, "Unreachable random part: " & item.id
        else:
          doAssert item.id notin seen
  let sparse = Manifest(categories: @[
    Category(key: "Body", items: @[PartItem(name: "Shared")]),
    Category(key: "Eyes", items: @[
      PartItem(name: "Monster", alignment: EvilOnly)
    ]),
    Category(key: "Hair")
  ])
  var rng = initRand(1)
  doAssert sparse.randomSelection(rng, GoodOnly) == @[0, -1, -1]
  doAssert sparse.randomSelection(rng, EvilOnly) == @[0, 0, -1]
  doAssert sparse.randomSelection(rng, GnomeOnly) == @[0, -1, -1]

proc testGnomeRandom() =
  ## Checks gnome features, shared clothing, tag isolation, and reachability.
  let manifest = readManifest(AssetDir)
  var
    rng = initRand(71)
    matching = initRand(71)
    seen: HashSet[string]
  for roll in 0 ..< 1024:
    let selection = manifest.randomSelection(rng, GnomeOnly)
    doAssert selection == manifest.randomSelection(matching, GnomeOnly)
    for i, category in manifest.categories:
      let selected = selection[i]
      if category.key in ["Body", "Face", "Eyes", "Mouth", "Nose", "Ears",
                         "Headgear", "Chest", "Leg", "Foot"]:
        doAssert selected >= 0
      if selected < 0:
        continue
      let item = category.items[selected]
      doAssert item.alignment != EvilOnly
      if category.key in ["Nose", "Ears", "Eyes", "Beard", "Headgear"]:
        doAssert item.alignment == GnomeOnly
      seen.incl item.id
  for category in manifest.categories:
    var exclusive = false
    for item in category.items:
      if item.alignment == GnomeOnly:
        exclusive = true
      if item.name.startsWith("Gnome "):
        if item.id.startsWith("clothing/"):
          doAssert item.alignment == GoodOnly
        else:
          doAssert item.alignment == GnomeOnly
    for item in category.items:
      let eligible =
        if exclusive:
          item.alignment == GnomeOnly
        else:
          item.alignment in {Both, GoodOnly}
      doAssert (item.id in seen) == eligible, item.id

proc testBeardChance() =
  ## Keeps facial hair near fifty percent regardless of eligible style count.
  for count in [0, 1, 16, 64]:
    var category = Category(key: "Beard")
    for i in 0 ..< count:
      category.items.add PartItem(name: $i)
    let manifest = Manifest(categories: @[category])
    for alignment in [Both, GoodOnly, EvilOnly, GnomeOnly]:
      var
        rng = initRand(83)
        present = 0
      for roll in 0 ..< 4096:
        let selected = manifest.randomSelection(rng, alignment)[0]
        if selected >= 0:
          doAssert selected < count
          inc present
      if count == 0:
        doAssert present == 0
      else:
        doAssert present in 1843 .. 2253, $count & ": " & $present
  let filtered = Manifest(categories: @[
    Category(key: "Beard", items: @[
      PartItem(name: "Evil beard", alignment: EvilOnly)
    ])
  ])
  var rng = initRand(91)
  for roll in 0 ..< 128:
    doAssert filtered.randomSelection(rng, GoodOnly) == @[-1]

proc testParts() =
  ## Checks face and ear choices while animations reset and blend the model.
  let
    manifest = readManifest(AssetDir)
    model = readCharacter(AssetDir, manifest)
    nodes = partNodes(model.root)
    player = newClipPlayer(model.root)
  var selection = manifest.defaultSelection()
  nodes.applySelection(manifest, selection)
  doAssert nodes["Nose_Tiny"].visible
  doAssert nodes["Head"].visible
  doAssert nodes["Eyes_Atlas02"].visible
  doAssert nodes["Mouth_Atlas01"].visible
  doAssert nodes["Brow_Atlas01"].visible
  doAssert nodes["Hair_01"].visible
  doAssert not nodes["Beard_01"].visible
  let
    eyeColor = nodes["Eyes_Atlas02"].mesh.primitives[0].material.baseColorFactor
    mouthColor = nodes["Mouth_Atlas01"].mesh.primitives[0].material.baseColorFactor
    hairColor = nodes["Hair_01"].mesh.primitives[0].material.baseColorFactor
    browColor = nodes["Brow_Atlas01"].mesh.primitives[0].material.baseColorFactor
    beardColor = nodes["Beard_01"].mesh.primitives[0].material.baseColorFactor
  for skin in 0 ..< manifest.skins.len:
    nodes.applySkin(manifest, skin)
    let tint = manifest.skins[skin].color
    for name in manifest.skinNodes:
      doAssert nodes[name].mesh.primitives[0].material.baseColorFactor ==
        color(tint[0], tint[1], tint[2], tint[3])
    doAssert nodes["Eyes_Atlas02"].mesh.primitives[0].material.baseColorFactor ==
      eyeColor
    doAssert nodes["Mouth_Atlas01"].mesh.primitives[0].material.baseColorFactor ==
      mouthColor
    doAssert nodes["Hair_01"].mesh.primitives[0].material.baseColorFactor ==
      hairColor
    doAssert nodes["Brow_Atlas01"].mesh.primitives[0].material.baseColorFactor ==
      browColor
    doAssert nodes["Beard_01"].mesh.primitives[0].material.baseColorFactor ==
      beardColor
  var untouched: seq[(Material, Color)]
  for name, node in nodes:
    if name notin manifest.skinNodes:
      for primitive in node.mesh.primitives:
        let material = primitive.material
        untouched.add (material, material.baseColorFactor)
  let custom = color(0.15, 0.65, 0.8, 1)
  nodes.applySkin(manifest, custom)
  for name in manifest.skinNodes:
    for primitive in nodes[name].mesh.primitives:
      doAssert primitive.material.baseColorFactor == custom
  for (material, original) in untouched:
    doAssert material.baseColorFactor == original
  nodes.applySkin(manifest, manifest.defaultSkin)
  for name, node in nodes:
    if name in ["Ears_Round_Left", "Ears_Round_Right",
                "Ears_Elf_Left", "Ears_Elf_Right"]:
      doAssert not node.visible
  for clip in manifest.clips:
    doAssert player.clipIndex(clip.name) >= 0
    player.setRule(clip.name, ClipRule(
      loop: clip.loop, next: clip.next, hold: clip.hold
    ))
  for category in manifest.categories:
    for item in category.items:
      manifest.selectPart(selection, category.key, item.name)
      nodes.applySelection(manifest, selection)
      for clip in manifest.clips:
        player.play(clip.name, 0.2)
        player.update(0.1)
        for name in item.nodes:
          doAssert nodes[name].visible and nodes[name].baseVisible
        for other in category.items:
          if other.name != item.name:
            for name in other.nodes:
              doAssert not nodes[name].visible
  for category in manifest.categories:
    manifest.selectPart(selection, category.key, "None")
  nodes.applySelection(manifest, selection)
  player.update(0.2)
  for name, node in nodes:
    doAssert node.visible == (name in manifest.base)
  var failed = false
  try:
    manifest.selectPart(selection, "Ears", "Missing")
  except ChargenError:
    failed = true
  doAssert failed
  player.play("Walk_Loop", 0)
  player.seek(0)
  var rotations: seq[Quat]
  for node in model.root.walkNodes:
    rotations.add node.rot
  player.seek(0.3)
  var moved = false
  for i, node in model.root.walkNodes:
    if node.rot != rotations[i]:
      moved = true
  doAssert moved, "The animation must move the skeleton."
  player.play("Punch_Jab", 0.2)
  player.update(10)
  doAssert model.root.animations[player.current].name == "Walk_Loop"
  player.play("Spell_Simple_Enter", 0)
  player.update(10)
  doAssert model.root.animations[player.current].name == "Spell_Simple_Idle_Loop"
  player.play("Death01", 0)
  player.update(10)
  doAssert model.root.animations[player.current].name == "Death01"
  player.play("Jump_Start", 0)
  player.update(10)
  doAssert model.root.animations[player.current].name == "Jump_Loop"
  for preset in manifest.presets:
    manifest.applyPreset(selection, preset)
    nodes.applySelection(manifest, selection)
  manifest.selectPart(selection, "Headgear", "None")
  manifest.selectPart(selection, "Ears", "Elf")
  nodes.applySelection(manifest, selection)
  doAssert nodes["Ears_Elf_Left"].visible
  manifest.applyPreset(selection, manifest.presets[0])
  nodes.applySelection(manifest, selection)
  doAssert not nodes["Ears_Elf_Left"].visible

proc testEyes() =
  ## Checks individual textures, iris tint isolation, and head attachment.
  let
    manifest = readManifest(AssetDir)
    model = readCharacter(AssetDir, manifest)
  var textures = readEyeTextures(model.root, AssetDir, manifest)
  doAssert textures.textures.len == 32
  var
    shades: HashSet[uint8]
    protected, tinted, count = 0
  textures.applyPupilTint(manifest.pupilColors[2].rgb)
  for texture in textures.textures:
    let
      black = tintPupils(texture.art, texture.mask, manifest.pupilColors[1].rgb)
      teal = tintPupils(texture.art, texture.mask, manifest.pupilColors[2].rgb)
    doAssert texture.art.width < 512 and texture.art.height < 512
    for i, pixel in texture.art.data:
      doAssert black.data[i].a == pixel.a
      doAssert teal.data[i].a == pixel.a
      if texture.mask.data[i].r == 0:
        doAssert black.data[i] == pixel
        doAssert teal.data[i] == pixel
        inc protected
      elif texture.mask.data[i].r == 255:
        doAssert black.data[i].r == 0
        doAssert black.data[i].g == 0
        doAssert black.data[i].b == 0
        if pixel.a >= 240:
          shades.incl teal.data[i].g
          inc tinted
    for primitive in texture.primitives:
      inc count
      doAssert primitive.material.unlit
      doAssert primitive.material.alphaMode == MaskAlphaMode
      doAssert primitive.material.baseColor.data == teal.data
      for uv in primitive.uvs:
        doAssert uv.x >= -0.00001 and uv.x <= 1.00001
        doAssert uv.y >= -0.00001 and uv.y <= 1.00001
  doAssert count == 32
  doAssert protected > 100_000 and tinted > 10_000
  doAssert shades.len > 20, "Tinting must retain iris shading."
  textures.applyPupilTint(manifest.pupilColors[0].rgb)
  for texture in textures.textures:
    for primitive in texture.primitives:
      doAssert primitive.material.baseColor.data == texture.art.data
  for node in model.root.walkNodes:
    if node.mesh == nil or not node.name.startsWith("Eyes_"):
      continue
    for primitive in node.mesh.primitives:
      for i, ids in primitive.jointIds:
        for j in 0 ..< 4:
          if primitive.jointWeights[i][j] > 0:
            doAssert node.skin.joints[ids[j].int].name == "Head"

proc testMouths() =
  ## Checks separate mouth cutouts, unlit materials, and head attachment.
  let model = readCharacter(AssetDir)
  var count = 0
  for node in model.root.walkNodes:
    if node.mesh == nil or
      not (node.name.startsWith("Mouth_Atlas") or
           node.name.startsWith("Mouth_Evil")):
        continue
    inc count
    doAssert node.mesh.primitives.len == 1
    let
      primitive = node.mesh.primitives[0]
      material = primitive.material
    doAssert material.unlit
    doAssert material.alphaMode == MaskAlphaMode
    doAssert not material.baseColorPlaceholder
    doAssert material.baseColor.width < 512
    doAssert material.baseColor.height < 512
    doAssert material.baseColor.data[0].a < 128
    for uv in primitive.uvs:
      doAssert uv.x >= -0.00001
      doAssert uv.x <= 1.00001
      doAssert uv.y >= -0.00001
      doAssert uv.y <= 1.00001
    for i, ids in primitive.jointIds:
      for j in 0 ..< 4:
        if primitive.jointWeights[i][j] > 0:
          doAssert node.skin.joints[ids[j].int].name == "Head"
  doAssert count == 32

proc testBrows() =
  ## Checks separate eyebrow cutouts, isolated tint, and head weights.
  let
    model = readCharacter(AssetDir)
    nodes = partNodes(model.root)
    manifest = readManifest(AssetDir)
    brows = initBrowMaterials(model.root, manifest)
    protected = ["Head", "Eyes_Atlas02", "Mouth_Atlas01", "Hair_01"]
  var originals: seq[Color]
  for name in protected:
    originals.add nodes[name].mesh.primitives[0].material.baseColorFactor
  for tint in [WhiteBrows, manifest.hairColors[0].rgb, manifest.hairColors[22].rgb]:
    brows.applyBrowTint(tint)
    var count = 0
    for node in model.root.walkNodes:
      if node.mesh == nil or not node.name.startsWith("Brow_Atlas"):
        continue
      inc count
      doAssert node.mesh.primitives.len == 1
      let
        primitive = node.mesh.primitives[0]
        material = primitive.material
      doAssert material.unlit
      doAssert material.alphaMode == MaskAlphaMode
      doAssert material.baseColorFactor == color(tint[0], tint[1], tint[2], 1)
      doAssert not material.baseColorPlaceholder
      doAssert material.baseColor.width < 512
      doAssert material.baseColor.height < 512
      doAssert material.baseColor.data[0].a < 128
      for uv in primitive.uvs:
        doAssert uv.x >= -0.00001
        doAssert uv.x <= 1.00001
        doAssert uv.y >= -0.00001
        doAssert uv.y <= 1.00001
      for i, ids in primitive.jointIds:
        for j in 0 ..< 4:
          if primitive.jointWeights[i][j] > 0:
            doAssert node.skin.joints[ids[j].int].name == "Head"
    doAssert count == 16
    for i, name in protected:
      doAssert nodes[name].mesh.primitives[0].material.baseColorFactor ==
        originals[i]

proc testHair(prefix: string) =
  ## Checks each hair family follows the head and remains independently shaded.
  let model = readCharacter(AssetDir)
  var count = 0
  for node in model.root.walkNodes:
    if node.mesh == nil or not node.name.startsWith(prefix):
      continue
    inc count
    doAssert node.skin != nil
    for primitive in node.mesh.primitives:
      doAssert not primitive.material.unlit
      doAssert primitive.jointIds.len == primitive.jointWeights.len
      doAssert primitive.jointIds.len > 0
      for i, ids in primitive.jointIds:
        var total = 0.0'f
        for j in 0 ..< 4:
          let weight = primitive.jointWeights[i][j]
          total += weight
          if weight > 0:
            doAssert node.skin.joints[ids[j].int].name == "Head"
        doAssert abs(total - 1) < 0.00001
  doAssert count == (if prefix == "Beard_": 18 else: 16)

proc testHairColors() =
  ## Verifies tint isolation and restores custom shades after weight mode.
  let
    manifest = readManifest(AssetDir)
    model = readCharacter(AssetDir, manifest)
    nodes = partNodes(model.root)
    hair = initHairMaterials(nodes, manifest)
    head = nodes["Head"].mesh.primitives[0].material
    eyes = nodes["Eyes_Atlas02"].mesh.primitives[0].material
    mouth = nodes["Mouth_Atlas01"].mesh.primitives[0].material
    headTint = head.baseColorFactor
    eyeTint = eyes.baseColorFactor
    mouthTint = mouth.baseColorFactor
  var
    untouched: seq[Material]
    originalTints: seq[Color]
    hairNodes: HashSet[string]
  for surface in manifest.hairShades:
    hairNodes.incl surface.node
  doAssert hairNodes.len == 34
  for i in 1 .. 16:
    let suffix = align($i, 2, '0')
    doAssert "Hair_" & suffix in hairNodes
    doAssert "Beard_" & suffix in hairNodes
  for node in model.root.walkNodes:
    if node.mesh == nil or
      not (node.name.startsWith("Hair_") or node.name.startsWith("Beard_")):
        continue
    for i, primitive in node.mesh.primitives:
      var tinted = false
      for surface in manifest.hairShades:
        if surface.node == node.name and surface.primitive == i:
          tinted = true
      if not tinted:
        untouched.add primitive.material
        originalTints.add primitive.material.baseColorFactor
  doAssert untouched.len > 0
  for preset in manifest.hairColors:
    doAssert manifest.hairColors[manifest.hairColors.colorIndex(preset.name.toUpperAscii())] == preset
    hair.applyHairTint(preset.rgb)
    for surface in manifest.hairShades:
      let material = nodes[surface.node].mesh.primitives[
        surface.primitive
      ].material
      doAssert material.baseColorFactor == color(
        clamp(preset.rgb[0] * surface.shade, 0, 1),
        clamp(preset.rgb[1] * surface.shade, 0, 1),
        clamp(preset.rgb[2] * surface.shade, 0, 1),
        1
      )
    doAssert head.baseColorFactor == headTint
    doAssert eyes.baseColorFactor == eyeTint
    doAssert mouth.baseColorFactor == mouthTint
    for i, material in untouched:
      doAssert material.baseColorFactor == originalTints[i]
  var preview = initWeightPreview(model.root, AssetDir)
  let
    selected = preview.boneIndex("Head")
    custom = [0.16'f, 0.73'f, 0.42'f]
  hair.applyHairTint(custom)
  preview.updateWeights(true, selected)
  preview.updateWeights(false, selected)
  hair.applyHairTint(custom)
  for name in ["Hair_01", "Beard_01"]:
    for primitive in nodes[name].mesh.primitives:
      doAssert primitive.material.baseColorFactor ==
        color(custom[0], custom[1], custom[2], 1)
      doAssert not primitive.material.unlit

proc testOutfits() =
  ## Checks future clothing colors and replacement meshes without new assets.
  let category = Category(key: "Chest", items: @[
    PartItem(name: "Red shirt", style: 0, color: "Red"),
    PartItem(name: "Blue coat", style: 1, color: "Blue"),
    PartItem(name: "Blue shirt", style: 0, color: "Blue")
  ])
  var selected = 0
  category.cycleColor(selected)
  doAssert selected == 2
  category.cycleColor(selected)
  doAssert selected == 0
  let
    manifest = Manifest(base: @["Body"], categories: @[
      Category(key: "Chest", items: @[
        PartItem(nodes: @["Shirt"], hides: @["Body"])
      ])
    ])
    nodes = {"Body": Node(), "Shirt": Node()}.toTable
  nodes.applySelection(manifest, [0])
  doAssert not nodes["Body"].visible and nodes["Shirt"].visible
  nodes.applySelection(manifest, [-1])
  doAssert nodes["Body"].visible and not nodes["Shirt"].visible

proc testClothing() =
  ## Checks garment swaps, boot tucking, and restoration across live animation.
  let
    manifest = readManifest(AssetDir)
    model = readCharacter(AssetDir, manifest)
    nodes = partNodes(model.root)
    player = newClipPlayer(model.root)
  var selection = manifest.defaultSelection()
  for category in manifest.categories:
    var baseCount = 0
    for item in category.items:
      if "/gota_" notin item.id:
        inc baseCount
    if category.key == "Chest":
      doAssert baseCount == 10
    if category.key == "Leg":
      doAssert baseCount == 6
    if category.key == "Foot":
      doAssert baseCount == 6
  for category in manifest.categories:
    if category.key != "Leg":
      continue
    for pants in category.items:
      manifest.selectPart(selection, "Leg", pants.name)
      for slot in manifest.categories:
        if slot.key != "Foot":
          continue
        for boots in slot.items:
          manifest.selectPart(selection, "Foot", boots.name)
          nodes.applySelection(manifest, selection)
          for clip in ["Walk_Loop", "Jog_Fwd_Loop", "Crouch_Fwd_Loop"]:
            player.play(clip, 0)
            player.seek(0.3)
            for name in pants.nodes:
              doAssert nodes[name].visible == (name notin boots.hides)
            for foot in ["Foot.Left", "Foot.Right"]:
              doAssert nodes[foot].visible ==
                (foot notin boots.hides and foot notin pants.hides)
            doAssert nodes["Body"].visible
          manifest.selectPart(selection, "Foot", "None")
          nodes.applySelection(manifest, selection)
          player.seek(0.6)
          for name in pants.nodes:
            doAssert nodes[name].visible
          doAssert nodes["Foot.Left"].visible and nodes["Foot.Right"].visible

proc testBelts() =
  ## Checks independent belt swaps, recoloring, and removal during animation.
  let
    manifest = readManifest(AssetDir)
    model = readCharacter(AssetDir, manifest)
    nodes = partNodes(model.root)
    player = newClipPlayer(model.root)
  var selection = manifest.defaultSelection()
  manifest.selectPart(selection, "Chest", "03 Green tabard")
  manifest.selectPart(selection, "Leg", "09 Brown trousers")
  for name in ["Clothing_03", "Clothing_05"]:
    for primitive in nodes[name].mesh.primitives:
      doAssert primitive.material.name notin [
        "Clothing belt leather", "Clothing simple buckles"
      ]
  for (belt, visible) in [
    ("Simple leather belt", "Belt_Simple"),
    ("Gnome buckle belt", "Gnome_Belt"),
    ("None", "")
  ]:
    manifest.selectPart(selection, "Belt", belt)
    nodes.applySelection(manifest, selection)
    player.play("Walk_Loop", 0)
    player.seek(0.35)
    doAssert nodes["Body"].visible
    doAssert nodes["Clothing_03"].visible
    doAssert nodes["Clothing_09"].visible
    for name in ["Belt_Simple", "Gnome_Belt"]:
      doAssert nodes[name].visible == (name == visible)
  let
    shirtColor = nodes["Clothing_03"].mesh.primitives[0].material.baseColorFactor
    buckleColor = nodes["Belt_Simple"].mesh.primitives[1].material.baseColorFactor
  var clothes = initClothMaterials(nodes, manifest)
  for cloth in clothes.mitems:
    if cloth.category == "Belt":
      cloth.enabled = true
      cloth.tint = [0.2'f, 0.3'f, 0.4'f]
  clothes.applyClothTint()
  doAssert nodes["Belt_Simple"].mesh.primitives[0].material.baseColorFactor ==
    color(0.2, 0.3, 0.4, 1)
  doAssert nodes["Belt_Simple"].mesh.primitives[1].material.baseColorFactor ==
    buckleColor
  doAssert nodes["Clothing_03"].mesh.primitives[0].material.baseColorFactor ==
    shirtColor

proc testHats() =
  ## Checks head attachment, hair hiding, and isolated hat recoloring.
  let
    manifest = readManifest(AssetDir)
    model = readCharacter(AssetDir, manifest)
    nodes = partNodes(model.root)
    hats = initHatMaterials(nodes, manifest)
  var
    tinted: seq[Material]
    fixed: seq[(Material, Color)]
    selection = manifest.defaultSelection()
    count = 0
    whiteSpots = 0
  for surface in manifest.hatShades:
    tinted.add nodes[surface.node].mesh.primitives[surface.primitive].material
  doAssert tinted.len == 6
  for name, node in nodes:
    for primitive in node.mesh.primitives:
      if primitive.material notin tinted:
        fixed.add (primitive.material, primitive.material.baseColorFactor)
    if not name.startsWith("Hat_"):
      continue
    inc count
    for primitive in node.mesh.primitives:
      if primitive.material.unlit:
        doAssert name == "Hat_Mushroom"
        doAssert primitive.material.baseColorFactor == color(1, 1, 1, 1)
        doAssert primitive.material notin tinted
        inc whiteSpots
      for i, ids in primitive.jointIds:
        var total = 0.0'f
        for j in 0 ..< 4:
          total += primitive.jointWeights[i][j]
          if primitive.jointWeights[i][j] > 0:
            doAssert node.skin.joints[ids[j].int].name == "Head"
        doAssert abs(total - 1) < 0.00001
  doAssert count == 6
  doAssert whiteSpots == 1
  for preset in manifest.hatColors:
    hats.applyHatTint(preset.rgb)
    for material in tinted:
      doAssert material.baseColorFactor ==
        color(preset.rgb[0], preset.rgb[1], preset.rgb[2], 1)
    for (material, original) in fixed:
      doAssert material.baseColorFactor == original
  for category in manifest.categories:
    if category.key != "Headgear":
      continue
    for item in category.items:
      manifest.selectPart(selection, "Headgear", item.name)
      nodes.applySelection(manifest, selection)
      doAssert nodes[item.nodes[0]].visible
      doAssert nodes["Hair_01"].visible == ("Hair_01" notin item.hides)
  manifest.selectPart(selection, "Headgear", "None")
  nodes.applySelection(manifest, selection)
  doAssert nodes["Hair_01"].visible

proc testGarments() =
  ## Verifies garment attachment, per-slot tinting, and fixed detail colors.
  let
    manifest = readManifest(AssetDir)
    model = readCharacter(AssetDir, manifest)
    nodes = partNodes(model.root)
  var
    clothes = initClothMaterials(nodes, manifest)
    originals: seq[(Material, Color)]
    fabrics: seq[Material]
    count = 0
  for node in nodes.values:
    for primitive in node.mesh.primitives:
      originals.add (primitive.material, primitive.material.baseColorFactor)
    if node.name.startsWith("Gnome_"):
      inc count
      for primitive in node.mesh.primitives:
        doAssert not primitive.material.unlit
        for i, ids in primitive.jointIds:
          var total = 0.0'f
          for j in 0 ..< 4:
            total += primitive.jointWeights[i][j]
            if primitive.jointWeights[i][j] > 0:
              doAssert ids[j].int < node.skin.joints.len
          doAssert abs(total - 1) < 0.00001
  doAssert count == 9
  doAssert clothes.len == 7
  var preset = Preset()
  for i, cloth in clothes:
    preset.parts.add PresetPart(
      category: cloth.category,
      rgb: @[0.1'f * (i + 1).float32, 0.2'f, 0.4'f]
    )
  clothes.applyClothPreset(preset)
  for category in manifest.categories:
    for item in category.items:
      for shade in item.clothShades:
        let material = nodes[shade.node].mesh.primitives[shade.primitive].material
        fabrics.add material
        for part in preset.parts:
          if part.category == category.key:
            doAssert material.baseColorFactor == color(
              part.rgb[0] * shade.shade,
              part.rgb[1] * shade.shade,
              part.rgb[2] * shade.shade,
              1
            )
  for (material, original) in originals:
    if material notin fabrics:
      doAssert material.baseColorFactor == original
  clothes.applyClothPreset(Preset())
  for (material, original) in originals:
    doAssert material.baseColorFactor == original
  var rejected = false
  try:
    clothes.applyClothPreset(Preset(parts: @[
      PresetPart(category: "Jacket", rgb: @[0.5'f])
    ]))
  except ChargenError:
    rejected = true
  doAssert rejected

proc testAstronaut() =
  ## Checks white dye surfaces, fixed details, rigging, and helmet removal.
  let
    manifest = readManifest(AssetDir)
    model = readCharacter(AssetDir, manifest)
    nodes = partNodes(model.root)
    player = newClipPlayer(model.root)
  var
    preset: Preset
    found = false
    fabrics: seq[Material]
    fixed: seq[(Material, Color)]
    clothes = initClothMaterials(nodes, manifest)
    selection = manifest.defaultSelection()
  for candidate in manifest.presets:
    if candidate.name == "Astronaut":
      preset = candidate
      found = true
  doAssert found
  for category in manifest.categories:
    for item in category.items:
      if not item.id.contains("astronaut_"):
        continue
      for shade in item.clothShades:
        let material = nodes[shade.node].mesh.primitives[shade.primitive].material
        doAssert material.baseColorFactor == color(1, 1, 1, 1)
        fabrics.add material
      for name in item.nodes:
        let node = nodes[name]
        doAssert node.skin != nil
        for primitive in node.mesh.primitives:
          if primitive.material notin fabrics:
            fixed.add (primitive.material, primitive.material.baseColorFactor)
          for i, weights in primitive.jointWeights:
            var total = 0.0'f
            for j in 0 ..< 4:
              doAssert weights[j] >= 0
              total += weights[j]
              if weights[j] > 0 and category.key == "Headgear":
                let joint = primitive.jointIds[i][j].int
                doAssert node.skin.joints[joint].name == "Head"
            doAssert abs(total - 1) < 0.00001
  doAssert fabrics.len == 3
  manifest.applyPreset(selection, preset)
  nodes.applySelection(manifest, selection)
  doAssert not nodes["Head"].visible
  doAssert not nodes["Hand.Left"].visible
  doAssert not nodes["Foot.Left"].visible
  for tint in [[0'f, 0'f, 0'f], [1'f, 0.25'f, 0'f], [0'f, 0.4'f, 1'f]]:
    var colored = preset
    for part in colored.parts.mitems:
      if part.category in ["Headgear", "Chest", "Leg"]:
        part.rgb = @[tint[0], tint[1], tint[2]]
    clothes.applyClothPreset(colored)
    for material in fabrics:
      doAssert material.baseColorFactor == color(tint[0], tint[1], tint[2], 1)
    for (material, original) in fixed:
      doAssert material.baseColorFactor == original
  clothes.applyClothPreset(preset)
  for material in fabrics:
    doAssert material.baseColorFactor == color(1, 1, 1, 1)
  for clip in ["Idle_Loop", "Walk_Loop", "Crouch_Fwd_Loop"]:
    player.play(clip, 0)
    player.seek(0.35)
    for name, node in nodes:
      if name.startsWith("Astronaut_"):
        doAssert node.visible
  manifest.selectPart(selection, "Headgear", "None")
  nodes.applySelection(manifest, selection)
  doAssert nodes["Head"].visible
  doAssert not nodes["Astronaut_Helmet"].visible

proc testGnomes() =
  ## Checks shared features, independent colors, and exact lineup pose copying.
  let
    manifest = readManifest(AssetDir)
    model = readCharacter(AssetDir, manifest)
    player = newClipPlayer(model.root)
    actors = readLineup(AssetDir, manifest, model.root, "Gnomes")
  doAssert actors.len == 9
  var skins: HashSet[int]
  for preset in manifest.presets:
    if preset.group == "Gnomes":
      skins.incl preset.skin
  doAssert skins.len == 9
  var joints: Table[string, Node]
  for node in model.root.walkNodes:
    if node.mesh == nil:
      joints[node.name] = node
  for actor in actors:
    let nodes = partNodes(actor.root)
    doAssert nodes.len >= 19
    doAssert actor.root.animations.len == 0
    for name in ["Eyes_Gnome", "Nose_Gnome", "Ears_Gnome_Left",
                 "Ears_Gnome_Right", "Beard_Gnome",
                 "Beard_Gnome_Moustache", "Brow_Atlas01"]:
      doAssert nodes[name].visible
      for primitive in nodes[name].mesh.primitives:
        for i, ids in primitive.jointIds:
          for j in 0 ..< 4:
            if primitive.jointWeights[i][j] > 0:
              doAssert nodes[name].skin.joints[ids[j].int].name == "Head"
  let
    first = partNodes(actors[0].root)
    second = partNodes(actors[1].root)
    third = partNodes(actors[2].root)
  doAssert first["Beard_Gnome"].mesh.primitives[0].material !=
    second["Beard_Gnome"].mesh.primitives[0].material
  doAssert first["Eyes_Gnome"].mesh.primitives[0].material.baseColor.data !=
    third["Eyes_Gnome"].mesh.primitives[0].material.baseColor.data
  for clip in ["A_TPose", "Walk_Loop", "Dance_Loop", "Jump_Start"]:
    player.play(clip, 0.2)
    for time in [0.0'f, 0.1'f, 0.45'f]:
      player.update(time)
      actors.sync()
      for actor in actors:
        for node in actor.root.walkNodes:
          if node.mesh == nil:
            doAssert node.pos == joints[node.name].pos
            doAssert node.rot == joints[node.name].rot
            doAssert node.scale == joints[node.name].scale
    player.seek(0.25)
    actors.sync()
    for actor in actors:
      for node in actor.root.walkNodes:
        if node.mesh == nil:
          doAssert node.rot == joints[node.name].rot
  let original = manifest.defaultSelection()
  for preset in manifest.presets:
    if preset.group == "Gnomes":
      discard manifest.presetManifest(preset)
  doAssert manifest.defaultSelection() == original

proc testWeights() =
  ## Checks runtime bone attachments and reversible weight preview colors.
  let
    model = readCharacter(AssetDir)
    nodes = partNodes(model.root)
    player = newClipPlayer(model.root)
    hand = nodes["Hand.Left"].mesh.primitives[0]
    originalWeights = hand.jointWeights
    originalPoints = hand.points
    originalColors = hand.colors
    eye = nodes["Eyes_Atlas02"].mesh.primitives[0]
    eyeTint = eye.material.baseColorFactor
  var preview = initWeightPreview(model.root, AssetDir)
  let left = preview.boneIndex("LeftHand")
  doAssert preview.bones.len == 22 and left >= 0
  doAssert preview.boneIndex("Missing") == -1
  preview.updateWeights(true, left)
  doAssert hand.material.unlit
  var fullWeight = false
  for i, tint in hand.colors:
    let weight = nodes["Hand.Left"].influence(hand, i, "LeftHand")
    doAssert tint == weightColor(weight)
    if weight > 0.99:
      fullWeight = true
  doAssert fullWeight
  for tint in nodes["Hand.Right"].mesh.primitives[0].colors:
    doAssert tint == weightColor(0)
  model.root.updateTransforms()
  for bone in preview.bones:
    let ends = bone.endpoints()
    doAssert length(ends.head - bone.restHead) < 0.00001
    doAssert length(ends.tail - bone.restTail) < 0.00001
  for clip in model.root.animations:
    player.play(clip.name, 0)
    for fraction in [0.0'f, 0.35'f, 0.8'f]:
      player.seek(clip.duration * fraction)
      model.root.updateTransforms()
      for side in ["Left", "Right"]:
        for suffix in ["ForeArm", "Hand", "Leg", "Foot"]:
          doAssert preview.jointGap(preview.boneIndex(side & suffix)) < 0.00001
  preview.updateWeights(false, left)
  doAssert hand.jointWeights == originalWeights
  doAssert hand.points == originalPoints
  doAssert hand.colors == originalColors
  doAssert not hand.material.unlit
  doAssert eye.material.baseColorFactor == eyeTint

proc testUniversal() =
  ## Checks all imported clips, transition rules, and a free moving left hand.
  let
    manifest = readManifest(AssetDir)
    model = readCharacter(AssetDir, manifest)
    player = newClipPlayer(model.root)
  doAssert manifest.defaultAnimation == "Walk_Loop"
  var count = 0
  for clip in manifest.clips:
    player.setRule(clip.name, ClipRule(
      loop: clip.loop, next: clip.next, hold: clip.hold
    ))
    if clip.kind == "universal":
      inc count
      doAssert player.clipIndex(clip.name) >= 0
      if clip.next.len > 0:
        doAssert player.clipIndex(clip.next) >= 0
  doAssert count == 43
  doAssert manifest.clips.len == count
  var hand: Node
  for node in model.root.walkNodes:
    if node.mesh == nil and node.name == "LeftHand":
      hand = node
  doAssert hand != nil
  player.play("Walk_Loop", 0)
  player.seek(0)
  model.root.updateTransforms()
  let before = hand.mat * vec3(0)
  player.seek(0.66)
  model.root.updateTransforms()
  doAssert length(hand.mat * vec3(0) - before) > 0.1
  for (first, next) in [
    ("Jump_Start", "Jump_Loop"),
    ("Sitting_Enter", "Sitting_Idle_Loop"),
    ("Spell_Simple_Enter", "Spell_Simple_Idle_Loop")
  ]:
    player.play(first, 0)
    player.update(10)
    doAssert model.root.animations[player.current].name == next
  player.play("Walk_Loop", 0)
  player.play("Death01", 0)
  player.update(10)
  doAssert model.root.animations[player.current].name == "Death01"
  player.play("Walk_Loop", 0)
  player.play("Punch_Jab", 0)
  player.update(10)
  doAssert model.root.animations[player.current].name == "Walk_Loop"

proc testSources() =
  ## Rejects retired content before any rig, eye or clip asset is opened.
  for identity in ["eyes/original2", "eyes/neutral", "eyes/happy", "eyes/angry"]:
    let manifest = Manifest(
      rig: "missing.glb",
      categories: @[Category(items: @[PartItem(id: identity)])]
    )
    var rejected = false
    try:
      discard readCharacter("missing-library", manifest)
    except ChargenError as error:
      rejected = error.msg.startsWith("Retired character part:")
    doAssert rejected
  for kind in ["pose", "retargeted"]:
    let manifest = Manifest(
      rig: "missing.glb",
      clips: @[ClipInfo(name: "Retired", kind: kind, file: "missing.glb")]
    )
    var rejected = false
    try:
      discard readCharacter("missing-library", manifest)
    except ChargenError as error:
      rejected = error.msg.startsWith("Unsupported animation source:")
    doAssert rejected

proc testGota() =
  ## Checks hero budgets, creep presets, skin restoration, and animation.
  let
    manifest = readManifest(AssetDir)
    model = readCharacter(AssetDir, manifest)
    nodes = partNodes(model.root)
    player = newClipPlayer(model.root)
    actors = readLineup(AssetDir, manifest, model.root, "Gota")
  doAssert actors.len == 10
  var
    selection = manifest.defaultSelection()
    count = 0
  for preset in manifest.presets:
    if preset.group != "Gota" or preset.lineupHidden:
      continue
    inc count
    manifest.applyPreset(selection, preset)
    nodes.applySelection(manifest, selection)
    doAssert nodes["GotaSkinUpper"].visible
    doAssert not nodes["GotaSkinLower"].visible
    doAssert not nodes["Body"].visible
    doAssert not nodes["GotaFoot.Left"].visible
    doAssert not nodes["GotaFoot.Right"].visible
    var triangles, equipmentTriangles = 0
    for node in nodes.values:
      if node.visible:
        for primitive in node.mesh.primitives:
          let total =
            (primitive.indices16.len + primitive.indices32.len) div 3
          triangles += total
          if node.name.startsWith("GotaWeapon_"):
            equipmentTriangles += total
    let characterTriangles = triangles - equipmentTriangles
    doAssert characterTriangles > 0 and characterTriangles < 20_000,
      preset.name
    doAssert equipmentTriangles > 0 and equipmentTriangles < 5_000, preset.name
    for i, category in manifest.categories:
      if selection[i] < 0:
        continue
      let item = category.items[selection[i]]
      if item.attachmentBone.len == 0:
        continue
      doAssert category.key in ["Left hand", "Right hand", "Back"]
      for name in item.nodes:
        let node = nodes[name]
        doAssert node.visible
        for primitive in node.mesh.primitives:
          for vertex in 0 ..< primitive.points.len:
            doAssert abs(node.influence(primitive, vertex,
              item.attachmentBone) - 1) < 0.0001
    for key in ["Foot", "Leg", "Belt", "Chest", "Headgear"]:
      var present = false
      for choice in preset.parts:
        if choice.category == key:
          present = choice.item.len > 0 and choice.item != "None"
      doAssert present, preset.name & " missing " & key
    manifest.selectPart(selection, "Leg", "None")
    manifest.selectPart(selection, "Foot", "None")
    nodes.applySelection(manifest, selection)
    doAssert nodes["GotaSkinLower"].visible
    doAssert nodes["GotaFoot.Left"].visible
    doAssert nodes["GotaFoot.Right"].visible
  doAssert count == 10
  var creepCount = 0
  for preset in manifest.presets:
    if preset.group != "Gota" or
      preset.name notin ["Blue Creep", "Purple Creep"]:
        continue
    let purple = preset.name == "Purple Creep"
    inc creepCount
    doAssert preset.lineupHidden
    manifest.applyPreset(selection, preset)
    nodes.applySelection(manifest, selection)
    doAssert nodes["Body"].visible
    doAssert not nodes["GotaSkinUpper"].visible
    for name, node in nodes:
      if name.startsWith("GotaWeapon_"):
        let expected =
          if purple: "GotaWeapon_death_knight_right_hand"
          else: "GotaWeapon_vanguard_knight_right_hand"
        doAssert node.visible == (name == expected)
    doAssert preset.pose == "Sword_Idle"
    for i, category in manifest.categories:
      case category.key
      of "Body", "Face":
        doAssert category.items[selection[i]].name == "Base"
      of "Eyes":
        doAssert category.items[selection[i]].name ==
          (if purple: "02 Focused" else: "01 Bright")
      of "Mouth":
        if purple:
          doAssert category.items[selection[i]].name == "Evil 13 Vampire smirk"
        else:
          doAssert selection[i] == -1
      of "Ears":
        if purple:
          doAssert category.items[selection[i]].name == "Elf"
        else:
          doAssert selection[i] == -1
      of "Right hand":
        doAssert category.items[selection[i]].name ==
          (if purple: "Death Knight sword" else: "Vanguard sword")
      else:
        doAssert selection[i] == -1, category.key
    let rgb = if purple: [131, 16, 159] else: [59, 147, 184]
    for i, value in rgb:
      doAssert abs(manifest.skins[preset.skin].color[i] * 255 -
        value.float32) < 0.001
    if purple:
      let pupil = manifest.pupilColors.colorIndex(preset.pupilColor)
      doAssert manifest.pupilColors[pupil].rgb == [1'f, 0'f, 0'f]
  doAssert creepCount == 2
  let creeps = readLineup(AssetDir, manifest, model.root, "Creeps")
  doAssert creeps.len == 2
  doAssert creeps[0].name == "Blue Creep"
  doAssert creeps[1].name == "Purple Creep"
  for clip in ["A_TPose", "Walk_Loop", "Crouch_Fwd_Loop"]:
    player.play(clip, 0)
    player.seek(0.35)
    actors.sync()
    for actor in actors:
      doAssert actor.root.animations.len == 0
      for node in actor.root.walkNodes:
        if node.mesh == nil:
          for source in model.root.walkNodes:
            if source.mesh == nil and source.name == node.name:
              doAssert node.pos == source.pos
              doAssert node.rot == source.rot

proc testGods() =
  ## Checks both modular god presets on the shared rig and their budgets.
  let
    manifest = readManifest(AssetDir)
    model = readCharacter(AssetDir, manifest)
    nodes = partNodes(model.root)
    actors = readLineup(AssetDir, manifest, model.root, "Gota Gods")
  doAssert actors.len == 2
  doAssert actors[0].name == "Zeus" and actors[1].name == "Hades"
  var selection = manifest.defaultSelection()
  for preset in manifest.presets:
    if preset.group != "Gota Gods":
      continue
    manifest.applyPreset(selection, preset)
    nodes.applySelection(manifest, selection)
    doAssert nodes["Head"].visible
    doAssert nodes["GotaSkinUpper"].visible
    doAssert not nodes["Body"].visible
    for foot in ["GotaFoot.Left", "GotaFoot.Right"]:
      doAssert nodes[foot].visible == (preset.name == "Zeus"),
        "Open sandals must retain the existing feet."
    var total, parts = 0
    for node in nodes.values:
      if node.visible:
        for primitive in node.mesh.primitives:
          total += (primitive.indices16.len + primitive.indices32.len) div 3
    doAssert total > 0 and total < 20_000, preset.name
    for i, category in manifest.categories:
      if category.key notin ["Chest", "Belt", "Back", "Headgear", "Hair",
                             "Beard", "Leg", "Foot", "Right hand", "Left hand"]:
        continue
      doAssert selection[i] >= 0, preset.name & " missing " & category.key
      let item = category.items[selection[i]]
      doAssert item.id.contains("gota_" & preset.name.toLowerAscii() & "_")
      doAssert item.files.len == 1
      var triangles = 0
      for name in item.nodes:
        doAssert nodes[name].visible
        for primitive in nodes[name].mesh.primitives:
          triangles += (primitive.indices16.len + primitive.indices32.len) div 3
      doAssert triangles > 0 and triangles < 5_000,
        preset.name & " " & category.key
      inc parts
    doAssert parts == 10
    echo preset.name, ": ", total, " triangles, ten modular parts verified."

proc testSwordSockets() =
  ## Checks fixed grips and arm alignment at the reported attack frame.
  let manifest = readManifest(AssetDir)
  for preset in manifest.presets:
    if preset.name notin ["Blue Creep", "Purple Creep"]:
      continue
    var inventory = manifest.presetManifest(preset)
    for clip in manifest.clips:
      if clip.name == "Sword_Attack":
        inventory.clips.add clip
    let
      model = readCharacter(AssetDir, inventory)
      player = newClipPlayer(model.root)
      nodes = partNodes(model.root)
    for category in inventory.categories:
      if category.key != "Right hand":
        continue
      let
        item = category.items[0]
        original = readGltfFile(AssetDir / item.files[0])
        raw = partNodes(original.root)[item.nodes[0]]
        sword = nodes[item.nodes[0]]
        pivot = vec3(-1.13, 1.73, 0.025)
        tip = pivot + vec3(0, 1.25, 0)
      var
        socket = -1
        elbow: Node
      for node in model.root.walkNodes:
        if node.name == "RightForeArm":
          elbow = node
      doAssert elbow != nil
      for i, joint in sword.skin.joints:
        if joint.name == item.attachmentBone:
          socket = i
      doAssert socket >= 0
      player.play("Sword_Attack", 0)
      for frame in 0 .. 46:
        player.seek(frame.float32 / 30)
        model.root.updateTransforms()
        let
          hand = sword.skin.joints[socket].mat
          before = hand * raw.skin.inverseBindMatrices[socket]
          after = hand * sword.skin.inverseBindMatrices[socket]
          grip = after * pivot
        doAssert length(before * pivot - grip) < 0.0001,
          "Sword grip moved away from its hand socket."
        if frame in 14 .. 23:
          let
            arm = normalize(grip - elbow.mat * vec3(0, 0, 0))
            blade = normalize(after * tip - grip)
            alignment = dot(arm, blade)
          doAssert alignment > 0.995,
            "The blade must continue along the extended arm."
          if frame == 19:
            doAssert alignment > 0.99999,
              "Frame 19 must follow the elbow-to-grip guide."
      echo preset.name, " frame 19: arm alignment and fixed grip verified."

proc testAssembly(directory: string) =
  ## Verifies independent meshes and clips share the same live skeleton.
  let
    manifest = readManifest(directory)
    model = readCharacter(directory, manifest)
    nodes = partNodes(model.root)
    player = newClipPlayer(model.root)
  var joints: Table[string, Node]
  for node in model.root.walkNodes:
    if node.mesh == nil:
      doAssert node.name notin joints
      joints[node.name] = node
  for node in nodes.values:
    doAssert node.skin != nil
    doAssert node.skin.joints.len == node.skin.inverseBindMatrices.len
    for joint in node.skin.joints:
      doAssert joint == joints[joint.name]
  for clip in model.root.animations:
    for channel in clip.channels:
      doAssert channel.target == joints[channel.target.name]
    player.play(clip.name, 0)
    player.seek(clip.duration * 0.4)
    model.root.updateTransforms()
  var selection = manifest.defaultSelection()
  for category in manifest.categories:
    for item in category.items:
      manifest.selectPart(selection, category.key, item.name)
      nodes.applySelection(manifest, selection)
      for name in item.nodes:
        doAssert nodes[name].visible
      for name in item.hides:
        if name in nodes:
          doAssert not nodes[name].visible
  for i in 0 ..< manifest.skins.len:
    nodes.applySkin(manifest, i)
  let
    hair = initHairMaterials(nodes, manifest)
    hats = initHatMaterials(nodes, manifest)
    brows = initBrowMaterials(model.root, manifest)
  hats.applyHatTint(manifest.hatColors[0].rgb)
  var clothes = initClothMaterials(nodes, manifest)
  for preset in manifest.presets:
    clothes.applyClothPreset(preset)
  var eyes = readEyeTextures(model.root, directory, manifest)
  hair.applyHairTint(manifest.hairColors[0].rgb)
  brows.applyBrowTint(manifest.hairColors[0].rgb)
  eyes.applyPupilTint(manifest.pupilColors[0].rgb)
  var failed = false
  try:
    discard directory.assetPath("../outside.glb")
  except ChargenError:
    failed = true
  doAssert failed
  echo "Verified library: ", directory

if paramCount() > 0:
  testAssembly(paramStr(1))
else:
  echo "Testing Chargen parts and animations"
  testRandom()
  testGnomeRandom()
  testBeardChance()
  testUniversal()
  testSources()
  testAssembly(AssetDir)
  testParts()
  testEyes()
  testMouths()
  testBrows()
  testHair("Hair_")
  testHair("Beard_")
  testHairColors()
  testOutfits()
  testClothing()
  testBelts()
  testHats()
  testGarments()
  testAstronaut()
  testGnomes()
  testGota()
  testGods()
  testSwordSockets()
  testWeights()
  echo "Chargen tests passed"
