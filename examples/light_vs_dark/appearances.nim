import
  std/[sets, tables],
  chroma, gltf,
  polyworld/[characters, chargen, profiles],
  assets, content

type
  UnitAppearance = object
    preset: Preset
    kind: UnitKind
    skin: array[3, float32]
    model: CharacterModel
  UnitModelCache* = object
    ## Owns variants for one roster and manifest during scene loading.
    appearances: seq[UnitAppearance]

proc unitClip*(kind: UnitKind, slot: AnimationSlot): string =
  ## Selects an existing CC0 clip, including explicit ranged placeholders.
  case slot
  of RunAnimation:
    "Jog_Fwd_Loop"
  of DeathAnimation:
    "Death01"
  of VictoryAnimation:
    "Dance_Loop"
  of IdleAnimation:
    case kind
    of SoldierUnit, KnightUnit:
      "Sword_Idle"
    of MageUnit:
      "Spell_Simple_Idle_Loop"
    of CatapultUnit:
      "Pistol_Idle_Loop"
    else:
      "Idle_Loop"
  of AttackAnimation, AttackAlternateAnimation:
    case kind
    of PeonUnit:
      "Interact"
    of SoldierUnit, KnightUnit:
      "Sword_Attack"
    of ArcherUnit, CatapultUnit:
      "Pistol_Shoot"
    of MageUnit, ClericUnit, SummonUnit:
      "Spell_Simple_Shoot"

proc loadUnitModel*(
  manifest: Manifest,
  entry: UnitPreset,
  kind: UnitKind
): CharacterModel =
  ## Loads the approved outfit and sizes its body independently of gear.
  let
    inventory = manifest.presetManifest(entry.preset)
    height = UnitHeights[kind]
    rgb = entry.skinRgb
  result = loadCharacterModel(
    readPresetCharacter(ChargenLibrary, manifest, entry.preset, CharacterClips),
    height
  )
  let nodes = partNodes(result.file.root)
  nodes.applySkin(inventory, color(rgb[0], rgb[1], rgb[2], 1))
  var
    visibility: Table[string, bool]
    bodyNodes: HashSet[string]
  for category in inventory.categories:
    for item in category.items:
      if category.key in ["Eyes", "Mouth", "Brow"]:
        result.unlitParts.add item.nodes
      if category.key in ["Body", "Face"]:
        for name in item.nodes:
          bodyNodes.incl name
  for name, node in nodes:
    visibility[name] = node.visible
    node.visible = name in bodyNodes
    node.baseVisible = node.visible
  result.fitCharacterHeight(height, result.clipIndex("Idle_Loop"))
  for name, node in nodes:
    node.visible = visibility[name]
    node.baseVisible = node.visible

proc copyUnitModel(source: CharacterModel): CharacterModel =
  ## Copies mutable rigs and materials while retaining immutable GPU geometry.
  var
    nodes: Table[pointer, Node]
    materials: Table[pointer, Material]
  proc copyNode(node: Node): Node =
    ## Builds the new hierarchy before rebinding skins and animation targets.
    result = Node()
    result[] = node[]
    nodes[cast[pointer](node)] = result
    result.nodes.setLen(0)
    for child in node.nodes:
      result.nodes.add copyNode(child)
    if node.mesh != nil:
      result.mesh = Mesh(name: node.mesh.name)
      for primitive in node.mesh.primitives:
        if primitive.morphTargets.len > 0:
          raise newException(
            ChargenError, "LvD variants require immutable skinned geometry."
          )
        if primitive.data == nil:
          new(primitive.data)
        let variant = Primitive()
        variant[] = primitive[]
        let material = primitive.material
        if cast[pointer](material) notin materials:
          if material.data == nil:
            new(material.data)
          let copy = Material()
          copy[] = material[]
          materials[cast[pointer](material)] = copy
        variant.material = materials[cast[pointer](material)]
        result.mesh.primitives.add variant
  result = CharacterModel(
    file: GltfFile(root: copyNode(source.file.root)),
    clips: source.clips,
    baseTransform: source.baseTransform,
    unlitParts: source.unlitParts
  )
  for original in source.file.root.walkNodes:
    let node = nodes[cast[pointer](original)]
    if original.skin != nil:
      node.skin = gltf.Skin(
        name: original.skin.name,
        inverseBindMatrices: original.skin.inverseBindMatrices
      )
      for joint in original.skin.joints:
        node.skin.joints.add nodes[cast[pointer](joint)]
      if original.skin.skeleton != nil:
        node.skin.skeleton = nodes[cast[pointer](original.skin.skeleton)]
      result.file.skins.add node.skin
    node.animations.setLen(0)
    for originalClip in original.animations:
      let clip = AnimationClip(
        name: originalClip.name, duration: originalClip.duration
      )
      for originalChannel in originalClip.channels:
        let channel = AnimationChannel()
        channel[] = originalChannel[]
        if originalChannel.target != nil:
          channel.target = nodes[cast[pointer](originalChannel.target)]
        channel.materialTargets.setLen(0)
        for material in originalChannel.materialTargets:
          channel.materialTargets.add materials[cast[pointer](material)]
        clip.channels.add channel
      node.animations.add clip

proc loadUnitModel*(
  cache: var UnitModelCache,
  manifest: Manifest,
  entry: UnitPreset,
  kind: UnitKind
): CharacterModel =
  ## Reuses an assembled outfit while keeping variant colors and rigs separate.
  var
    preset = entry.preset
    templateModel: CharacterModel
  preset.name = ""
  for appearance in cache.appearances:
    if appearance.kind != kind or appearance.preset != preset:
      continue
    if appearance.skin == entry.skinRgb:
      return appearance.model
    templateModel = appearance.model
  if templateModel == nil:
    profileBlock "unit outfit":
      result = loadUnitModel(manifest, entry, kind)
  else:
    result = copyUnitModel(templateModel)
    let
      rgb = entry.skinRgb
      inventory = manifest.presetManifest(entry.preset)
    partNodes(result.file.root).applySkin(
      inventory, color(rgb[0], rgb[1], rgb[2], 1)
    )
  cache.appearances.add UnitAppearance(
    preset: preset, kind: kind, skin: entry.skinRgb, model: result
  )
