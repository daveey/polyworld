# Crewrift

Run from the Polyworld repository root, with the usual dependencies and sibling
`polyworld_art` checkout:

```sh
nim r examples/crewrift/crewrift.nim
```

The default match has eight players, with one human and seven local bots. Roles
are random. To choose a role or watch the bots:

```sh
nim r examples/crewrift/crewrift.nim --role:imp
nim r examples/crewrift/crewrift.nim --role:crew
nim r examples/crewrift/crewrift.nim --spectate --seed:17
```

| Control | Action |
| --- | --- |
| WASD | Move, or select a vote target |
| Arrows | Pan the camera, or select a vote target during voting |
| E or Space | Hold to do a task, press to report, call a meeting, kill, or vote |
| Q | Use a nearby vent as an imposter |
| Enter | Open meeting chat, then send the typed message |
| Mouse click | Select and follow crew, or vote during a meeting |
| Shift-click or left drag | Add crew to selection, or select a group |
| Ctrl+A | Select all visible crew and follow the group |
| Middle or right drag | Pan the camera |
| S or D while spectating | Hold to pan with the pointer |
| Minimap click or drag | Pan to that area of the ship |
| Mouse wheel | Zoom the camera or selected group |
| C | Toggle the action camera |
| F1 | Open the tile and path debug panel |
| Tab | Show the full ship, or return to the human crew follow view |
| P | Pause or resume |
| Plus or minus | Change simulation speed |
| R | Start a new match with the next seed |
| Escape | Cancel text entry, or close the window |

The bottom ribbon uses Polyworld's shared replay controls. Drag the timeline
to seek, jump to either end, step one tick in either direction, pause, loop,
or select 1x, 2x, 4x, or 16x. Live matches retain their input history so you can
rewind and return to the current match. The camera button follows crew activity.
Saved replays start with the director camera and looping enabled. The director
follows crew activity, task completions, and kills. Space also pauses saved
replays and spectator matches.
The camera uses the same fixed north view, pan speeds, wheel zoom curve, and
group following as GOTA and LVD. Fullscreen also enables edge panning.
The left roster shows compact rows with a portrait, color and player identity,
and remaining task count, imposter kill count, or dead status. Scroll to see more
crew. Click a visible living crew member's portrait to follow them.
The top-left **Room names** button shows or hides the large white room labels.
Room labels start visible and retain their setting while seeking or looping.
Use `--name:"Andre von Houck"` to name your human-controlled slot. Local bots
are labeled `bots.nim`. New replays retain the names for each slot. Older
recordings without identities show `Unknown`.
Meetings put discussion in the main column with vote choices alongside it.
Bots take turns reporting bodies, sharing sightings, accusing suspects,
questioning alibis, and defending themselves before voting. Crewmates rely on
visible evidence, while imposters can bluff and accuse crew. Press Enter or
click the chat input to join the discussion as a living player.

Crewmates finish assigned tasks or eject every imposter to win. Imposters win
when their living count equals or exceeds the living crew. Dead crewmates can
move through walls and keep doing their tasks. Living players see nearby actors
through open corridors. Meeting chat is limited to living players, retains six
messages, and uses the original message cooldown.

The simulation runs at 24 ticks per second. Movement acceleration, friction,
collision sliding, eight task assignments, three-second task interactions,
kill range and cooldown, vent groups, reports, emergency meetings, votes,
ejections, and rewards come from Crewrift's original rule implementation.

The default ship renders `polyworld_art/crewrift/crewRift-map1-textured.glb`.
Its skin retains the model's baked lighting and textures. The hidden navigation
floor starts from `Plane002` in `crewRift-map1.blend`. Every candidate tile is
then audited against the actual textured GLB mesh, leaving 2,301 connected,
flat Polyworld tiles. The audit rejects 945 overlapping tiles and 8 isolated
clear tiles. There are no wall tiles or geometry outside the walkable floor.
Standing box probes have a 15% inset on each horizontal edge (0.7 tile wide),
extend to crew height (1.8 world units), and start 0.08 units above the floor.
Exact triangle/box intersection and solid containment checks include consoles,
walls, and overhangs. Swept boxes also reject 5 connections across thin walls;
both player movement and Polyworld pathfinding honor those barriers.
Eight original pixels equal one tile. The ship skin and gameplay coordinates
are twice the scale of the previous textured-map preview.
The 51 authored task lights supply station positions. Vent groups and 13 room
names retain the original game layout, fitted to the new floor. Stations,
vents, and spawn positions sit on reachable floor tiles.

Living player collision and bot A* paths use the same tile floor. Press F1 to
open Polyworld's standard debug window. **Show tiles** overlays green outlines
of the navigation tiles on the ship floor, keeping the complete ship visible.
The overlay has no ground texture, fill, or red boundary lines.
Use `SHOW_TILES=true` to start with the grid enabled.
**Show paths** draws bots' remaining routes in their player colors. Both start
off. Living crew teleport to their home positions around the meeting button
as soon as a report or emergency meeting is called, and remain there throughout
discussion and voting. Saved recordings with `mapPath: "croatoan"` retain the
original pixel collision and bot routing for deterministic playback.

To regenerate the floor and markers after editing the Blender source, run:

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --disable-autoexec ../crewRift-map1.blend --python tools/import_crewrift.py
```

This copies the supplied model into the sibling art checkout and writes the
extracted triangles and source marker positions to `crewrift/navigation.json`.
The generated map metadata, tile mask, and blocked connections are embedded
at compilation. `examples/crewrift/data/map1-audit.json` records the model hash,
probe dimensions, every candidate tile's result, and blocking mesh names.
Append `-- --probes=tmp/crewrift-tile-audit.blend` to the import command to save
a Blender scene with a wire box for every tested tile. Green boxes are kept,
red boxes intersect geometry, and amber boxes are isolated from the main floor.
The collision tool also runs synthetic checks for crossing triangles, touching
faces, and boxes fully enclosed by solid meshes before auditing the ship.

Input recordings can be viewed graphically or verified without graphics:

```sh
nim r examples/crewrift/crewrift.nim --record:tmp/crewrift.json
nim r examples/crewrift/crewrift.nim --replay:tmp/crewrift.json
nim r -d:headless examples/crewrift/crewrift.nim --record:tmp/crewrift.json
nim r -d:headless examples/crewrift/crewrift.nim --replay:tmp/crewrift.json
nim r -d:headless tests/test_crewrift.nim
```

`--players:8` through `--players:16` set the roster. `--ticks:N` bounds active
simulation ticks. `--windowSize:1440x900` changes the window. `--screenshot:PATH`
captures a frame and exits. `--capture-ticks:N` selects the simulation tick to
capture. Replays store input buttons, votes, and chat with a fingerprint for
every tick. Playback reports the first mismatch.

This example is a local playable port. The original Bitworld websocket server,
league clients, pixel renderer, and `.bitreplay` format are not connected to it.
The bundled local policies navigate Polyworld tiles, finish tasks, kill, report,
and vote using nearby evidence. They run without an API key or external service.

The rule code, task assignment code, and Croatoan metadata and masks were ported
from the local `coworld-crewrift` checkout. Its MIT license is preserved in
`examples/crewrift/LICENSE`. The masks and metadata are embedded at compilation,
so running this example does not require the original Crewrift checkout.
