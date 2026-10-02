import
  std/os,
  pixie,
  ../src/core/baseset, ../src/ui/cardfaces, ../src/paths

proc testAssets() =
  ## Render cards and decode VFX using data assets from another directory.
  let
    originalDir = getCurrentDir()
    artwork = artworkRoot()
  try:
    setCurrentDir(getTempDir())
    doAssert artworkRoot() == artwork
    for card in baseCards:
      let face = renderCardFace(card)
      doAssert face.width == CardFaceWidth
      doAssert face.height == CardFaceHeight
    initCardAssets(artwork / "cards")
    let back = renderCardBack()
    doAssert back.width == CardFaceWidth
    doAssert back.height == CardFaceHeight
    for name in ["lightning-strike", "ooze-droplet", "ooze-splat"]:
      let texture = readImage(artwork / "vfx/textures" / (name & ".png"))
      doAssert texture.width > 0 and texture.height > 0
    echo "Rendered ", baseCards.len, " cards and loaded AWM VFX from ", artwork
  finally:
    setCurrentDir(originalDir)

testAssets()
