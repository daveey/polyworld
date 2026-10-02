# Browser loading artwork

The loading screen uses lightweight, static SVG illustrations that are available
before the WebAssembly game asset pack downloads. It does not initialize a 3D
scene or a second canvas.

- `courtyard-night.svg` is a flat geometric interpretation of the Old Crossroads
  battlefield: a starry blue sky, faceted mountains, slate stone arches and slabs,
  hanging class banners, cypress trees, and warm brass lanterns. The bow and staff
  motifs echo the existing AWM class crests.
- `awm-logo.svg` is an emblazoned shield with green, red, and blue class fields,
  brass trim, and an outlined AWM wordmark. The letter shapes come from the
  project's existing Grenze SemiBold font. It renders immediately without
  waiting for the webfont. The full name is accessible live text in the shell.

The two SVGs total approximately 36 KB and scale cleanly to Retina displays.
`tools/build_web.sh` copies them into the browser output's `loading/` directory,
with the existing Grenze font and its OFL license.

The page keeps its existing download progress, indeterminate preparation state,
first-frame reveal, and recoverable error handling. The empty `loading-note`
element is hidden during loading and reserved for error recovery guidance.
