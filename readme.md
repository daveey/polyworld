# Polyworld

Polyworld is a low-poly 3D game engine written in Nim for AI research. It
provides deterministic simulation, procedural maps, pathfinding, rendering,
and shared UI, with native and browser clients.

## Games

Three games are built on the engine:

- **[Gods of the Arena (GotA)](https://metta-ai.github.io/polyworld-buff/GOTA/)**:
  `MOBA`: Two teams of five heroes fight through lanes and jungle camps to destroy
  the enemy fort. Heroes gain levels, buy equipment, and use abilities.
- **[Light vs Dark](https://metta-ai.github.io/polyworld-buff/LvD/)**:
  `RTS`: Two opposing commanders gather resources, build armies, and battle for
  control of the map.
- **[Call to Adventure](https://metta-ai.github.io/polyworld-buff/CTA/)**:
  `ARPG`: Four heroes explore a dungeon, fight monsters, and collect treasure.
  Surviving heroes compete to return with the most gold.

## AI research

AI agents control players through BASIC scripts using each game's observations
and commands. Headless matches run without graphics for fast evaluation.
Seeded maps, saved configurations, and action replays make runs reproducible.
Native and browser replay viewers let you inspect decisions, pause playback,
and compare strategies.

Game integrations start hosts with [`initPolicyHost`](src/polyworld/policyhosts.nim),
then register game observations and actions. Schema hosts omit the seat; runtime
hosts pass their policy slot. This keeps [optional annotations](coworld/integration.md#policy-annotations)
and future shared policy capabilities consistent across native and browser games.

## Run locally

Use Nim 2.2.10 or newer with the dependencies in
[polyworld.nimble](polyworld.nimble). Clone the art library beside this
repository:

```sh
git lfs install
git clone --depth 1 git@github.com:Metta-AI/polyworld_art.git ../polyworld_art
git -C ../polyworld_art lfs pull
```

This downloads the current art checkout with shallow Git history. LFS fetches
the files for that checkout, rather than every historical version. Omit
`--depth 1` if you want the full commit history for contributing to the art.

The `polyworld_art` repository contains mostly CC0 AI-generated artwork, along
with openly licensed third-party assets and their notices.
See its README and per-file license inventory for reuse and contribution terms.
Git LFS is required for models, images, fonts and editable art sources.
Heartleaf and AWM assets are not part of this migration.

From the repository root, launch a game with its bundled baseline agents:

```sh
nim r examples/gods_of_the_arena/gota.nim --bot examples/gods_of_the_arena/players/base.bas:10
nim r examples/light_vs_dark/lvd.nim --bot examples/light_vs_dark/players/base.bas:2
nim r examples/call_to_adventure/cta.nim --bot examples/call_to_adventure/players/base.bas:4
```

Use `-d:headless` to run without a window, `--record PATH` to save a match,
and `--replay PATH` to watch it. Build a browser client with `-d:emscripten`.
