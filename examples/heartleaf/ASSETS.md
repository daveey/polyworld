# Heartleaf runtime art

Run from Polyworld with the sibling `polyworld_art` checkout:

```sh
nim r examples/heartleaf/heartleaf.nim --bot examples/heartleaf/players/base.bas:9
```

The default window is 1920 by 1080, matching GotA, Light vs. Dark and Call to
Adventure. The opening overview shows all nine cottages. Screenshots run in a
hidden window and exit after writing their PNG:

```sh
SCREENSHOT_PATH=tmp/heartleaf.png nim r -d:takeScreenshot \
  examples/heartleaf/heartleaf.nim \
  --bot examples/heartleaf/players/base.bas:9 \
  --seek-tick 1500 --play=false
```

Use `--seek-event day:1:dinner` for a named event, or `--replay PATH` for a saved
run. `CAM_DIST`, `CAM_X` and `CAM_Z` override the screenshot camera. The latter
two use simulation tile coordinates. `--windowSize WIDTHxHEIGHT` overrides the
shared window dimensions.

## Reference layer captures

The four authorized inputs live in `polyworld_art/terrain/heartleaf/layers`:

| Input | Rendered content |
| --- | --- |
| `01-grass-and-paths.png` | Terrain materials, traced roads, approach stones and plaza paving |
| `02-buildings.png` | Cottage shells, roof flowers and the two reference chimneys |
| `03-trees-and-vegetation.png` | Trees, grounded hedges and flowers along the traced planting bands |
| `04-props.png` | Independent yard fences, planters, furniture, well, market, lamps and stone borders |

Run the repeatable Nim tool to render those four layers plus the assembled
town from actual game geometry:

```sh
nim r tools/capture_heartleaf_layers.nim
```

Outputs go to `tmp/heartleaf-layers`; an optional first argument changes that
folder. If ImageMagick is installed, it also writes individual side-by-side
comparisons and `layers-overview.png`. Every image uses the same 1122 by 1402 viewport, 50-degree orthographic
camera, fixed lighting time and reference registration. Buildings, vegetation
and props have transparent backgrounds. The assembled comparison excludes HUD,
gnomes and crop placeholders. Normal gameplay retains them.

To capture one layer, set `HEARTLEAF_LAYER` to `ground`, `buildings`,
`vegetation`, `props` or `all` and compile with both capture flags:

```sh
HEARTLEAF_LAYER=buildings SCREENSHOT_PATH=tmp/buildings.png \
  nim r -d:takeScreenshot -d:sceneCapture examples/heartleaf/heartleaf.nim \
  --bot examples/heartleaf/players/base.bas:9 \
  --seek-tick 1500 --play=false --windowSize 1122x1402
```

The layer selector filters mesh placements. It does not use flat reference-image
billboards. The ground image supplies material coverage for the winding lanes,
plaza and stepping stones; generated repeating grass, earth and limestone
materials supply their surface detail. The stone approach pieces extracted from
the old model remain available in the art pack, but the ground layer controls
the current narrower approaches.

## Models and placement

The cottage's original facade, door and window geometry is preserved. Its rear
bank is lower and shallower, with the facade join retained. Whole cottages use
uniform scale. Thirty yard pieces were extracted into independently placeable
rails, posts and stones with their own ground pivots. Planters and chimneys are
separate models. There is no embedded yard grass disk to cover the terrain.

Heartleaf grades its terrain materials at load time: paths use warm ochre,
roof turf uses brighter yellow-green, and timber keeps a lighter honey tone.
The original shared CC0 textures stay unchanged. Independent clover meshes
overhang the roof edges, and sunflower heads face forward with dark brown seed
centers. Benches use a brighter timber tint.

Garden rails bend gently from their cottage facades toward the
stepping-stone gates. The same fixed-point transform positions the rendered
fences and their collision centerlines. This keeps the cottage silhouettes at
gentle angles while leaving gates, planters and path approaches clear.

The detail pack includes a four-legged tiered beehive, a reusable clothesline
with purple, blue and cream cloth, and hollow wooden bucket planters with
recessed soil. Both laundry gardens share the enlarged line with the same
diagonal orientation. Buckets sit beside the cottage entrances. Signposts and
birdhouses use twice their original scale, and lamp poles use 1.5 times theirs.
The plaza fence and its attached flowers turn together to leave the southern
stepping-stone entrance clear; navigation uses those same rotated rails.

Doorway bases register to the nine building-layer anchors. Planting follows
explicit bands from the vegetation layer, with seeded crown and color variation.
Twenty-four irregular forest trees frame the map, including cropped trees just
outside its playable boundary. The playable terrain is about 49 by 84 tiles;
its world depth accounts for the calibrated camera's projection. The regular
window uses camera distance 94; the portrait capture fits the reference canvas.

Trees, bushes and fences share placement data with navigation. House footprints
follow the edited banks, and every door and harvestable planter remains
reachable. Static ambient occlusion follows the roof triangles and ground props
in the assembled scene. Isolated layers omit occlusion from other layers. Sun
shadows remain dynamic. Older recordings with a different map hash are rejected.

## Licenses and provenance

The client loads scene assets from `polyworld_art`. It does not load
`polyworld_data`, Layer Lab characters or Unity environment packs.

| Content | Source | License |
| --- | --- | --- |
| Nine gnomes | CharGen presets Gnome 01 through Gnome 09 | CC0-1.0 |
| Four animation clips | Clean CharGen Quaternius clips | CC0-1.0 |
| Logo | `themes/heartleaf/heartleaf_logo.png` | CC0-1.0 |
| Cottage shell and yard parts | `terrain/heartleaf/models` | CC0-1.0 |
| Well, planters and chimney | `terrain/blender_village/models` | CC0-1.0 |
| Layer-derived materials | `terrain/tiles/heartleaf-layer-*` | CC0-1.0 |
| Village details | `terrain/heartleaf/models/village_details.glb` | CC0-1.0 |
| TreeGen and RockGen textures | Reviewed Polyworld Art textures | CC0-1.0 |
| HUD fonts | Rubik and Overpass | OFL-1.1 |

New color and aligned height atlases were generated with built-in imagegen,
using the supplied ground layer as the style reference. The terrain skill's
Nim/Pixie tools repaired seams and exported nine 256 by 256 pairs. Masters,
prompts, input hashes and CC0 notices are preserved under
`polyworld_art/terrain/heartleaf/source/layer-tiles-*`.

Editable models, extraction scripts, input hashes and fresh-import validation
are recorded in `cottage-provenance.json` and `details-provenance.json` in that
source folder. `licenses/assets.json` records each asset's license and hash.
Models were checked from front, rear, top and oblique views, then compared as
individual in-game layers. Missing art uses procedural placeholders; harvestable
vegetables still use small colored placeholders.

`tests/test_hlf_art.nim` verifies the runtime CC0 asset closure, all nine gnomes,
yard separation, uniform house scale and opening camera. Ground, map, obstacle,
simulation and replay tests cover material registration and gameplay behavior.
