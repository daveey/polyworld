## Builds the AWM heroes from the CC0 CharGen presets in polyworld_art.
## Each seat uses its own Light vs Dark look, so mirrored classes differ.

import
  std/[algorithm, os, sets, tables],
  jsony,
  polyworld/[characters, chargen],
  ../core/core

const
  HeroRoster = ChargenLibrary & "/lvd.json"
  HeroHeight* = 1.95'f32
  HeroSeats* = 2
  HeroKinds: array[HeroClass, string] = ["ArcherUnit", "SoldierUnit", "MageUnit"]
  HeroIdleClips*: array[HeroClass, string] = [
    "Idle_Loop", "Sword_Idle", "Spell_Simple_Idle_Loop"
  ]
  FitClip = "Idle_Loop" ## Neutral pose used to measure every hero's body.
  HeroDeathClip* = "Death01" ## Played once when a hero dies; holds its end.

type
  RosterEntry = object
    kind: string
    preset: Preset

  Roster = object
    players: seq[seq[RosterEntry]]

  HeroPresets* = array[HeroSeats, array[HeroClass, Preset]]

proc readHeroPresets*(): HeroPresets =
  ## Picks the archer, swordsman and mage looks for both seats.
  let roster =
    try:
      readFile(HeroRoster).fromJson(Roster)
    except IOError, JsonError, ValueError:
      raise newException(
        ChargenError, "Cannot read hero roster: " & getCurrentExceptionMsg()
      )
  if roster.players.len < HeroSeats:
    raise newException(ChargenError, "Hero roster needs two player looks.")
  for seat in 0 ..< HeroSeats:
    for heroClass in HeroClass:
      var found = false
      for entry in roster.players[seat]:
        if entry.kind == HeroKinds[heroClass]:
          result[seat][heroClass] = entry.preset
          found = true
          break
      if not found:
        raise newException(ChargenError,
          "Hero roster is missing " & HeroKinds[heroClass])

proc heroClips(heroClass: HeroClass): seq[string] =
  result.add FitClip
  if HeroIdleClips[heroClass] != FitClip:
    result.add HeroIdleClips[heroClass]
  result.add HeroDeathClip

proc loadHeroModel*(
  manifest: Manifest,
  preset: Preset,
  heroClass: HeroClass
): CharacterModel =
  ## Sizes the body alone so hats, hair and staffs do not shrink a hero.
  let inventory = manifest.presetManifest(preset)
  result = loadCharacterModel(
    readPresetCharacter(ChargenLibrary, manifest, preset, heroClips(heroClass)),
    HeroHeight
  )
  let nodes = partNodes(result.file.root)
  var
    visibility: Table[string, bool]
    bodyNodes: HashSet[string]
  for category in inventory.categories:
    if category.key in ["Body", "Face"]:
      for item in category.items:
        for name in item.nodes:
          bodyNodes.incl name
  for name, node in nodes:
    visibility[name] = node.visible
    node.visible = name in bodyNodes
    node.baseVisible = node.visible
  result.fitCharacterHeight(HeroHeight, result.clipIndex(FitClip))
  for name, node in nodes:
    node.visible = visibility[name]
    node.baseVisible = node.visible

proc heroAssetFiles*(): seq[string] =
  ## Lists the CharGen files the heroes load, relative to ChargenLibrary.
  let
    manifest = readManifest(ChargenLibrary)
    presets = readHeroPresets()
  var files: HashSet[string]
  for path in ["lvd.json", "manifest.json", manifest.skinPalette,
      manifest.hairPalette, manifest.pupilPalette, manifest.hatPalette,
      manifest.rig]:
    files.incl path
  for category in manifest.categories:
    for path in walkFiles(ChargenLibrary / category.directory / "*.json"):
      files.incl path.relativePath(ChargenLibrary)
  for seat in presets:
    for heroClass, preset in seat:
      for category in manifest.presetManifest(preset).categories:
        for item in category.items:
          for path in item.files:
            files.incl path
          for path in [item.texture, item.pupilMask]:
            if path.len > 0:
              files.incl path
      for name in heroClips(heroClass):
        for clip in manifest.clips:
          if clip.name == name:
            files.incl clip.file
  for path in files:
    result.add path
  result.sort()
