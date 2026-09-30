# Polyworld Coworld integration

`-d:coworld` selects a native headless server. The wrapper is imported only by
Coworld builds. Desktop, ordinary headless, and WASM builds do not import Mummy.
`-d:emscripten -d:replayViewer` selects the static replay bootstrap and enables
looping. Each game retains its simulation, BASIC resource limits and early endings.

The packages are `coworld/gota`, `coworld/lvd`, and `coworld/cta`. Each contains a
manifest template, Compose definition, unchanged BASIC baseline, game guide and
executable viewer build hook. Generated packages and test outputs are ignored.

## Build

Use Nim 2.2.10, Emscripten, Docker, Python 3, and Coworld tooling from Metta commit
`9b99c8e18a763850bc6e04f331db98caf7fd645d` or a compatible later revision. That
revision includes James Boggs's merged game-hosted file-player workflow. Use a
separate Metta checkout so an existing development checkout stays intact.

```sh
nim r coworld/tools/sync_dependencies.nim
export POLYWORLD_DEPS="$PWD/tmp/coworld/deps"
coworld build --project coworld/gota --version 2026.9.9.3
coworld build --project coworld/lvd --version 2026.9.9.3
coworld build --project coworld/cta --version 2026.9.9.3
```

`nimby.lock` pins ordinary dependencies. `coworld/dependencies.lock` pins the same
revisions plus optional Mummy. Run
`nim r coworld/tools/sync_dependencies.nim --latest` to resolve upstream HEADs and
update both locks. Ordinary builds never update revisions implicitly.
The build hook validates the asset commit in `coworld/assets.json`. `POLYWORLD_ART`
can point at a checkout of that revision. Each game's `assets.nim` declarations
select its browser models, textures, and UI files. Emscripten builds automatically
run that game's native packer and preload its clean staging directory. Generated
manifests and byte reports live in `tmp/webassets/<game>-ktx2/`. See
[browser assets](../docs/browser_assets.md) for the formats and validation commands.

## Runtime

The runner supplies local `file://` URIs through `COGAME_CONFIG_URI`,
`COGAME_PLAYER_SEATS_URI`, `COGAME_RESULTS_URI`, `COGAME_SAVE_REPLAY_URI`, and
`COGAME_PLAYER_FAILURE_URI`. Configurations require matching tokens and players
arrays. GotA has ten seats, CTA has four, and LvD supports variable rosters with
six-player FFA in Competition. Staged policy filenames may have no extension.
Raw BASIC source is read with bounded reads and compiled with the game limits.

Every seat log is created before compilation. PRINT and BASIC diagnostics stay in
that seat's log, bounded to 10 MiB including the truncation marker. A runtime error
disables that VM. A compilation error closes the logs and publishes a sanitized
player failure marker. Successful episodes finish the replay, close all logs, write
optional player status, and atomically rename the results file last. The HTTP server
runs on a separate thread and stays available until the runner terminates it.

The legacy `/global` WebSocket exists only for current platform contract probes: one
status message and exact Ping/Pong. Gameplay uses files. `/healthz` is live;
`/client/global` and other legacy clients show a static page. Unimplemented routes
return HTTP 501. No player artifact ZIP is produced.

## Verification

`nim r coworld/tools/verify_native.nim` checks all desktop, headless and Coworld
entrypoints, recording regression tests, and full replay verification. First record
full matches into `tmp/coworld/{gota,lvd,cta}.replay` with the headless binaries and
`--record PATH`. Run `nim r coworld/tools/test_runtime.nim` from the repository root.
It uses the binaries in `tmp/coworld` to check
extensionless and empty sources, slot-specific print output, compilation failure,
disabled VMs, health/Ping/Pong, completion ordering and the 10 MiB log bound.

`nim r coworld/tools/test_tools.nim` checks concurrent build subprocesses,
working-directory restoration, and failure logs.

Serve the repository over HTTP to run
`python3 coworld/tools/test_browser_with_playwright.py`. It checks actual WASM
rendering and full replay hashes, seeking, speed, iframe resizing, readiness,
and visible errors. It supports a host Chrome executable or container Chromium for
ARM and x86 coverage. `tools/replay_probe.html` captures the Softmax iframe protocol.

CTA stores authoritative per-hero banked gold and return flags.
They are cloned, restored and hashed with the world. Surviving returned heroes tied
for the most banked gold receive 1; every other hero receives 0. Light vs Dark
also emits binary scores. GotA emits Emmett's Glory: lifetime XP per elapsed
minute for the winning team, rounded down to integers, and zero for losses,
draws, or timeouts, in zero-based platform slot order.
GotA uses random pairings and averages scores within each round, then updates
standings with 15% of the new round average and 85% of the previous standing.
Its league scheduler must preserve `strategy: "team_n"`, `team_count: 2`,
`team_layout: "blocks"`, `matchmaking: "random"`, and
`distinct_teammates: true`. With ten eligible policies, each controls one hero
in a mixed five-versus-five match. Omitting `distinct_teammates` instead clones
one policy across each team's five seats. Keep this league setting intact
when publishing releases or changing scoring.

## Release acceptance

Certify locally and against the local Softmax stack before publishing. Upload with
`--wait-certification` and require hosted certification and smoke to succeed. Create
leagues only after their releases become canonical. Declare one visible Competition
division, configure separate baseline filler versions, submit the baseline entrant,
and then enable scheduling with a 30-minute round interval. Fillers must never be
submitted as ranked entrants.

Record canonical Coworld IDs, league/division/policy IDs, certification evidence,
experience requests, three successful league rounds including an automatic cycle,
and game/player log plus browser replay evidence in the release handoff.

The published release receipt is [9 September 2026](releases/2026-09-09.md).
