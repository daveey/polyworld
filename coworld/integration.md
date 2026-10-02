# Polyworld Coworld integration

`-d:coworld` selects a native headless server. The wrapper is imported only by
Coworld builds. Desktop, ordinary headless, and WASM builds do not import Mummy.
`-d:emscripten -d:replayViewer` selects the static replay bootstrap and enables
looping. Each game retains its simulation, BASIC resource limits and early endings.

The packages are `coworld/gota`, `coworld/lvd`, `coworld/cta`, and `coworld/awm`.
Each contains a manifest template, Compose definition, unchanged BASIC baseline,
game guide and executable viewer build hook. Generated packages and test outputs are ignored.

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
coworld build --project coworld/awm --version VERSION
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
six-player FFA in Competition. AWM takes two to seven seats: two play a duel,
more a free-for-all; its turn-based tick is one game action. Staged policy filenames may have no extension.
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

## Policy annotations

All Polyworld policy hosts register the same annotation API through
`polyworld/policyhosts.initPolicyHost`. Game builders add their game-specific
functions to that host. Schema hosts omit the seat; live hosts supply their policy
slot. Annotation registration is independent of the LLM client and Bassy is unchanged.

```basic
status = ANNOTATE(123, "intent", "selectTarget", "{""target"":7}")
if status <> 0 then print ANNOTATE_ERROR$()
```

`time` is an integer in the game's replay time convention. `kind` describes the
purpose, `function` names the operation, and `args` must encode a JSON object.
The policy cannot select a seat or filesystem path. Coworld binds its optional
`annotations_uri` to each seat. Desktop and WASM hosts expose the same functions
and return disabled when there is no destination; they do not save files yet.
This includes GoTA, Light vs Dark, Call to Adventure, AWM and Heartleaf hosts.
Heartleaf does not yet have a Coworld output integration.

`ANNOTATE` returns a status instead of raising a BASIC error.
`ANNOTATE_ERROR$()` explains the most recent call:

| Code | Meaning |
| --- | --- |
| 0 | Written to the buffered file (not yet guaranteed durable) |
| 1 | No destination; disabled |
| 2 | Invalid arguments or JSON object |
| 3 | Event exceeds 2 KiB |
| 4 | Seat exceeds 1000 annotations or 2 MiB per episode |
| 5 | Output write failed |

Limits include serialized JSON and the trailing newline. Kind and function are
limited to 128 and 256 bytes; JSON nesting is limited to 64 levels and numbers must
be finite. These errors reject the event without disabling the VM. Calls still
consume the VM's normal instruction/work budget, like other host functions.

Each seat has one lazily opened, buffered file handle, like PRINT. Calls append
records synchronously and in order. There is no background worker or shared queue,
so one seat cannot exhaust queue capacity for another seat.

Existing player-output cleanup flushes and closes the files before the completion
marker. Write errors return a status; cleanup errors are summarized in the policy
log. Buffer flushes can block on storage, just as PRINT can. Accepted records are
not guaranteed durable before flushing; abrupt termination can lose buffered data.
No new platform finalization phase is introduced.

No calls means no file. Accepted events produce UTF-8 JSON Lines:

```json
{"schema_version":1,"time":123,"kind":"intent","function":"selectTarget","args":{"target":7}}
```

The platform validates each file before upload and reports rejection in the policy
log. Annotations never enter PRINT logs or the replay. Existing output collection
uploads the files after the episode.

## Verification

`nim r tests/test_annotations.nim` checks the portable API, seat isolation, limits,
nonfatal input and storage errors, and ordered output from multi-seat bursts.
The same test with `-d:coworld` covers hosted registration; file output also runs
under Emscripten without threads. It is included in the normal CI suite.

`nim r coworld/tools/verify_native.nim` checks all desktop, headless and Coworld
entrypoints, recording regression tests, and full replay verification. First record
full matches into `tmp/coworld/{gota,lvd,cta}.replay` with the headless binaries and
`--record PATH`. Run `nim r coworld/tools/test_runtime.nim` from the repository root.
Pass a game name, such as `awm`, to check only that game.
It uses the binaries in `tmp/coworld` to check
extensionless and empty sources, slot-specific print and annotation output, optional
annotation destinations, compilation failure,
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
GotA standings use team win/loss Elo MMR, starting at 1,500 with K=32 and
no score-margin scaling. Emmett's Glory remains in game results for analysis.
Its league scheduler must preserve `strategy: "team_n"`, `team_count: 2`,
`team_layout: "blocks"`, `matchmaking: "elo_softmax"`,
`matchmaking_temperature: 100`, and
`distinct_teammates: true`. With ten eligible policies, each controls one hero
in a mixed five-versus-five match. Omitting `distinct_teammates` instead clones
one policy across each team's five seats. Keep this league setting intact
when publishing releases or changing scoring. The Competition variant uses
`draft_mode: "open"`, allowing any hero to be picked multiple times.

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
