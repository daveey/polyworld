import
  chroma, gltf, opengl, pixie, vmath, windy,
  polyworld/[characters, chargen, common],
  content

const
  GnomeLibrary* = DataRoot & "/characters/chargen"
  GnomeHeight* = 3.4'f
  GnomePresets*: array[VillagerCount, string] = [
    "Gnome 01", "Gnome 02", "Gnome 03", "Gnome 04", "Gnome 05",
    "Gnome 06", "Gnome 07", "Gnome 08", "Gnome 09"
  ]
  GnomeClips*: array[AnimationSlot, string] = [
    "Idle_Loop", "Walk_Loop", "PickUp_Table", "Interact"
  ]

proc loadGnome*(manifest: Manifest, slot: int): CharacterModel =
  ## Assembles one of the nine authored gnomes using only the clean library.
  let
    preset = manifest.namedPreset(GnomePresets[slot])
    inventory = manifest.presetManifest(preset)
  result = loadCharacterModel(
    readPresetCharacter(GnomeLibrary, manifest, preset, GnomeClips),
    GnomeHeight
  )
  for category in inventory.categories:
    if category.key in ["Eyes", "Mouth", "Brow"]:
      for item in category.items:
        result.unlitParts.add item.nodes

proc gnomePortrait*(
  window: Window,
  scene: CharacterScene,
  model: CharacterModel
): Image =
  ## Captures the current gnome for the HUD without legacy portrait files.
  const Size = 192
  let
    target = vec3(0, GnomeHeight * 0.66'f, 0)
    eye = target + vec3(0, 0.2'f, -10)
    extent = GnomeHeight * 0.43'f
    view = lookAt(eye, target, vec3(0, 1, 0))
    projection = ortho(-extent, extent, -extent, extent, 0.02'f, 50'f)
  scene.beginCharacters(window, view, projection, eye)
  glViewport(0, 0, Size, Size)
  scene.renderer.clearScreen(color(0.10, 0.12, 0.16, 1))
  scene.drawCharacter(
    model,
    vec3(0),
    PI.float32 + 0.25'f,
    model.clipIndex(GnomeClips[IdleAnimation]),
    0.35'f
  )
  scene.finishCharacters()
  result = newImage(Size, Size)
  glReadPixels(
    0,
    0,
    Size,
    Size,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    result.data[0].addr
  )
  result.flipVertical()
  glViewport(0, 0, window.size.x, window.size.y)
