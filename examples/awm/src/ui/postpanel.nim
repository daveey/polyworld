## Live tuning window for the AWM screen effects, compiled with
## -d:awmPostPanel. F9 shows or hides it. Every PostSettings value has a
## control, grouped by the layer it shapes; "Print settings" writes them as
## Nim to paste into defaultPostSettings.

import
  std/strutils,
  silky, vmath, windy,
  ../scene/courtyard, ../scene/post

when PostPanelControls:
  const
    PanelTitle = "Screen effects"
    PanelOrigin = vec2(24, 150)
    PanelSize = vec2(560, 1180)
    StoneDefaults = defaultCourtyardMaterial()

  var postPanelOpen* = true

  proc mouseOverPostPanel*(mouse: Vec2): bool =
    ## Whether the pointer is over the panel (last frame's placement), so
    ## the game can ignore clicks meant for it.
    if not postPanelOpen or PanelTitle notin subWindowStates:
      return false
    let state = subWindowStates[PanelTitle]
    if state == nil or not state.visible:
      return false
    mouse.x >= state.pos.x and mouse.x <= state.pos.x + state.size.x and
      mouse.y >= state.pos.y and mouse.y <= state.pos.y + state.size.y

  template heading(label: string) =
    text "heading:" & label:
      characters label
      font "Hud"

  proc shown(value: float32): string =
    value.formatFloat(ffDecimal, 2)

  proc nimFloat(value: float32): string =
    value.formatFloat(ffDecimal, 3)

  proc printSettings(settings: PostSettings) =
    let tint = settings.occlusionTint
    echo "    occlusionRadius: envFloat(\"AWM_SSAO_RADIUS\", " &
      nimFloat(settings.occlusionRadius) & "),"
    echo "    occlusionIntensity: envFloat(\"AWM_SSAO_INTENSITY\", " &
      nimFloat(settings.occlusionIntensity) & "),"
    echo "    occlusionBias: envFloat(\"AWM_SSAO_BIAS\", " &
      nimFloat(settings.occlusionBias) & "),"
    echo "    occlusionTint: vec3(" & nimFloat(tint.x) & ", " &
      nimFloat(tint.y) & ", " & nimFloat(tint.z) & "),"
    echo "    occlusionSharpness: " & nimFloat(settings.occlusionSharpness) & ","
    echo "    occlusionNormalDetail: " &
      nimFloat(settings.occlusionNormalDetail) & ","
    echo "    bloomThreshold: " & nimFloat(settings.bloomThreshold) & ","
    echo "    bloomVfx: " & nimFloat(settings.bloomVfx) & ","
    echo "    bloomStrength: " & nimFloat(settings.bloomStrength) & ","
    echo "    vignette: " & nimFloat(settings.vignette) & ","
    echo "    vignetteStart: " & nimFloat(settings.vignetteStart) & ","
    echo "    vignetteEnd: " & nimFloat(settings.vignetteEnd) & ","
    echo "    saturation: " & nimFloat(settings.saturation) & ","
    echo "    contrast: " & nimFloat(settings.contrast)

  proc printMaterial(material: CourtyardMaterial) =
    echo "      normalStrength: " & nimFloat(material.normalStrength) & ","
    echo "      lampIntensity: " & nimFloat(material.lampIntensity) & ","
    echo "      slopeBroad: " & nimFloat(material.slopeBroad) & ","
    echo "      scaleBroad: " & nimFloat(material.scaleBroad)

  proc drawPostPanel*(sk: Silky, window: Window, post: var PostFx,
      courtyard: var CourtyardRenderer) =
    ## Draws the tuning window when it is open. Call inside beginUi/endUi.
    if window.buttonPressed[KeyF9]:
      postPanelOpen = not postPanelOpen
    if not postPanelOpen:
      return
    let textStyle = sk.textStyle
    sk.textStyle = "Small"
    sk.beginDsl()
    try:
      subWindow(PanelTitle, postPanelOpen, PanelOrigin, PanelSize):
        scrollable()
        template settings: untyped = post.settings

        heading "Output"
        checkBox "Screen effects (F8)", settings.enabled
        when PostLayerControls:
          for layer in PostLayer:
            radioButton $((layer.ord + 1) mod 10) & "  " & $layer,
              post.layer, layer

        heading "Occlusion (layers 5, 6)"
        checkBox "Ambient occlusion", settings.occlusion
        text "Radius (world units)"
        scrubber("ssaoRadius", settings.occlusionRadius, 0.1'f32, 4.0'f32,
          shown(settings.occlusionRadius))
        text "Intensity"
        scrubber("ssaoIntensity", settings.occlusionIntensity, 0.0'f32,
          6.0'f32, shown(settings.occlusionIntensity))
        text "Bias (hides flat-surface noise)"
        scrubber("ssaoBias", settings.occlusionBias, 0.0'f32, 0.5'f32,
          shown(settings.occlusionBias))
        text "Mapped surface detail"
        scrubber("ssaoNormalDetail", settings.occlusionNormalDetail, 0.0'f32,
          1.0'f32, shown(settings.occlusionNormalDetail))
        text "Blur edge sharpness"
        scrubber("ssaoSharpness", settings.occlusionSharpness, 0.0'f32,
          120.0'f32, shown(settings.occlusionSharpness))
        var tint = settings.occlusionTint
        text "Tint red, green, blue"
        scrubber("ssaoTintR", tint.x, 0.0'f32, 1.0'f32, shown(tint.x))
        scrubber("ssaoTintG", tint.y, 0.0'f32, 1.0'f32, shown(tint.y))
        scrubber("ssaoTintB", tint.z, 0.0'f32, 1.0'f32, shown(tint.z))
        settings.occlusionTint = tint

        heading "Stone material (layer 4)"
        template stone: untyped = courtyard.material
        text "Normal strength"
        scrubber("stoneNormals", stone.normalStrength, 0.0'f32, 3.0'f32,
          shown(stone.normalStrength))
        text "Lantern intensity"
        scrubber("stoneLamps", stone.lampIntensity, 0.0'f32, 12.0'f32,
          shown(stone.lampIntensity))
        text "Rock face weight"
        scrubber("stoneBroad", stone.slopeBroad, 0.0'f32, 2.0'f32,
          shown(stone.slopeBroad))
        text "Rock face tile (world units)"
        scrubber("stoneScaleBroad", stone.scaleBroad, 0.1'f32, 12.0'f32,
          shown(stone.scaleBroad))

        heading "Bloom (layers 7 to 0)"
        checkBox "Bloom", settings.bloom
        text "Scene threshold"
        scrubber("bloomThreshold", settings.bloomThreshold, 0.5'f32, 1.0'f32,
          shown(settings.bloomThreshold))
        text "VFX light weight"
        scrubber("bloomVfx", settings.bloomVfx, 0.0'f32, 3.0'f32,
          shown(settings.bloomVfx))
        text "Strength"
        scrubber("bloomStrength", settings.bloomStrength, 0.0'f32, 3.0'f32,
          shown(settings.bloomStrength))

        heading "Final image (layer 1)"
        checkBox "FXAA", settings.fxaa
        text "Saturation"
        scrubber("saturation", settings.saturation, 0.0'f32, 2.0'f32,
          shown(settings.saturation))
        text "Contrast"
        scrubber("contrast", settings.contrast, 0.0'f32, 1.0'f32,
          shown(settings.contrast))
        text "Vignette"
        scrubber("vignette", settings.vignette, 0.0'f32, 1.0'f32,
          shown(settings.vignette))
        text "Vignette start, end"
        scrubber("vignetteStart", settings.vignetteStart, 0.0'f32, 1.5'f32,
          shown(settings.vignetteStart))
        scrubber("vignetteEnd", settings.vignetteEnd, 0.0'f32, 2.0'f32,
          shown(settings.vignetteEnd))

        button "Print settings":
          printSettings(settings)
          printMaterial(courtyard.material)
        button "Reset":
          let enabled = settings.enabled
          settings = defaultPostSettings()
          settings.enabled = enabled
          courtyard.material = StoneDefaults
    finally:
      sk.endDsl()
      sk.textStyle = textStyle
