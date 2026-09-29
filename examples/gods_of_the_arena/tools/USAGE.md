# GotA tournaments

The runner, scoring, persistence, report generation, and tests are Nim. The small
browser component is also written in Nim and compiled to JavaScript. HTML embeds
that generated script, Rubik fonts, the GotA logo, and the original ladder icons.

Install the repository's Nim dependencies, including `curly` and `yaml`, and use
an existing `softmax login`. The runner reads `~/.softmax/credentials.yaml`
directly and calls the Softmax API through Curly. No Python process is used.

Build from the Polyworld repository root:

```sh
nim r -o:tmp/gota/tools/build_tournament examples/gods_of_the_arena/tools/build_tournament.nim
```

Start a run, then repeat its name to resume:

```sh
tmp/gota/tools/tournament --run comparison --games 1000
tmp/gota/tools/tournament --run comparison
```

The first command freezes the Competition division's top ten active entrants,
policy versions, game release, configuration, and seeded schedule. It schedules
500 mixed and 500 mono games. All output goes to
`tmp/gota/tournaments/comparison/`. Open `report.html` during the run; it becomes
the final report. Refresh the page manually to see new results. The page works
offline and can be moved to another folder.
Assets come from the sibling `polyworld_art` checkout, or `POLYWORLD_ART`.

The report uses the same header and stylesheet as the published GotA standings.
When the sibling `polyworld-buff` checkout exists, every report update also writes
`polyworld-buff/GOTA/standings/index.html` and copies its fonts and icons into
`GOTA/assets/`. This includes results, pauses, failures, restarts, and completion.
The existing `GOTA/site.css` supplies the exact current site styling and is
embedded in the local HTML so that file still works offline.

Use `--site PATH` for another checkout, or `--no-site` for local output only.
These are operational options and may change on resume. Without a site checkout,
the local report uses the bundled copy of the same stylesheet.

Refresh the existing run and the public checkout without running more games:

```sh
tmp/gota/tools/tournament --run top10-100-20260914 --report-only
```

Commit and push the generated changes in `polyworld-buff` to publish them through
GitHub Pages. The runner updates local files; it does not commit or push them.

Press Ctrl+C to pause. The current response and file replacement finish, then the
runner writes the paused report. Already submitted games continue remotely.
Restarting reconciles their results before scheduling new games. Keep one runner
per run directory. There is no local lock or database.

`run.json` and `games/*.json` are authoritative. Each game stores submission
attempts, pinned payloads, idempotency keys, remote IDs/status, and original result
artifacts. Atomic sibling-file replacements flush the file and its directory.
Abandoned `.tmp` files are ignored. Summaries, CSV exports, and HTML can be rebuilt:

```sh
tmp/gota/tools/tournament --run comparison --report-only
```

`--retry-failed` records a replacement attempt for the same scheduled game. Failed
games remain visible and unscored. Completed games count once. Explicit changes
to frozen settings fail on resume; operational `--concurrency` may change.

Options include `--top`, `--format mixed|mono|both`, `--league`, `--division`,
`--seed`, `--check-every`, `--concurrency`, and `--server`. Defaults are top 10,
both formats, 10 games per stability checkpoint, and four remote requests.
`--games` is the total across formats; mixed receives an odd remainder.

## Submission recovery

GotA release `2026.9.14.2` publishes the original ten-seat `total_xp` result array
while retaining binary victory scores. The runner submits direct XP requests
through the existing API and persists their returned IDs before collecting
results. Every attempt includes a unique request key in its purpose note.

If a POST response is lost, restart searches the current requester's history for
that exact note and verifies the frozen game configuration before attaching the
original request. It never repeats an uncertain POST. If no matching request is
visible, it pauses; another restart checks again. An interrupted attempt that
never reached the server needs manual reconciliation before retrying. This
conservative recovery works without a backend deployment, but fully automatic
recovery in that last ambiguous case still requires server-side deduplication.

## Scoring and stability

The player statistics table combines both formats, with one appearance per
policy per completed game. Mono games average all five heroes before being
combined with mixed games. Wins, losses and timeouts are separate counts.
XP is lifetime earned XP before division by elapsed minutes, including the
1,000 XP per hero awarded when the enemy god dies. Towers and barracks grant
200 XP to the hero landing the finishing blow. Gold is earned gold,
excluding starting gold; unspent gold is the final balance. Levels, kills,
deaths, assists, tower kills and footman last hits are per-appearance averages.
KDA is the sum of hero-averaged kills and assists divided by
`max(1, sum of hero-averaged deaths)` over games with verified replay stats.

The build also creates `tmp/gota/tools/inspect_players`. After each completed
game, the runner downloads its replay and verifies every replay hash before
saving per-seat statistics in the game record. `replays/` caches the source
replays, episode metadata and derived counters. Incomplete collection is visible
through each player's Stats games count. Missing data shows a dash, not zero.
The same table is exported to `exports/players.csv`.

Collect missing statistics for a saved run without scheduling games:

```sh
tmp/gota/tools/tournament --run comparison --report-only --collect-stats
```

The inspector must be compiled against the game source matching the replay's
release. Use `--stats-worker PATH` for a preserved older build. A mismatched
inspector reports an error and leaves the game result intact. Plain
`--report-only` is offline and rebuilds from the saved counters.

The inspector counts finishing blows from each verified tick's death events.
Tower kills include barracks; footman last hits exclude neutral camps, whose
kills are saved separately. Shared XP and god bonuses do not affect these
counters. Result validation allows battle time plus all ten draft deadlines.

Win/loss is average binary team victory, with no MMR adjustment. XP / minute
is lifetime XP divided by elapsed simulated minutes, including fractional
minutes and drafting, rounded down to whole points per hero before averaging.
Emmett's Glory awards that value to winners and zero to everyone else. Losses,
draws, timeouts, and zero-duration games therefore earn zero Glory. Mono
policies average their five heroes. The XP / minute comparison panel includes
all outcomes, while Emmett's Glory requires a win. There is no fixed time
penalty. New tournament runs use schema 2 and do not resume old scoring runs.

The hosted GotA ladder uses Emmett's Glory. It averages each player's scores
within a round, then updates their standing with 15% of that round's
average and 85% of their previous standing. The first scored round establishes
the initial standing. Pairings are random and higher standings rank first.
The tournament reports themselves show cumulative arithmetic averages.

Each format shares its games across all three ladders. Every checkpoint compares
cumulative displayed ranks. `stabilityScore` counts policies whose ranks changed;
a two-policy swap counts as two. `stabilityRun` counts consecutive unchanged
comparisons. The first checkpoint establishes a baseline. Partial final batches
update standings without advancing stability. Ties are marked and ordered by
frozen policy-version ID; unsampled policies have no rank. Stability never ends
the requested game count.

Out-of-order results are saved immediately. Standings advance through each
format's completed schedule prefix so interruptions cannot change checkpoints.
The report distinguishes completed games from those included in standings.

## Checks

Build first, then run the Nim checks and fixture tests:

```sh
nim check examples/gods_of_the_arena/tools/test_tournament.nim
nim r -o:tmp/gota/tools/test_tournament examples/gods_of_the_arena/tools/test_tournament.nim
```

The tests include scoring, balanced sampling, ties, stability resets, failed-game
retries, atomic replacement failures, and subprocess SIGINT/SIGKILL recovery after
remote acceptance. Fixture requests are persisted to JSON and never sent to
Softmax. Test output is under `tmp/gota/tournament-tests/`.
