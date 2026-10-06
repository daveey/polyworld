# GotA tournament runbook

Run a hosted Gods of the Arena tournament using the current Competition
division's top ten active players. The runner freezes their policy versions,
the game release, configuration, and shuffled schedule when it creates the run.
It collects results into live HTML standings and CSV exports on your computer.

This guide describes the runner as of October 2, 2026. Current scoring is
win/loss, XP per minute, and winner-only Emmett's Glory. Older reports that used
XP minus a fixed time penalty used different scoring.

## Repositories and access

| Repository | Purpose | Required? |
| --- | --- | --- |
| [Metta-AI/polyworld](https://github.com/Metta-AI/polyworld) | Nim runner and game source | Yes |
| [Metta-AI/polyworld_art](https://github.com/Metta-AI/polyworld_art) | Report fonts, logo, icons, and game assets | Yes |
| [Metta-AI/polyworld-buff](https://github.com/Metta-AI/polyworld-buff) | Published GotA standings | Only for publishing |

Use a GitHub account that can clone these repositories and a Softmax account
that can read the GotA league and submit experience requests. Hosted games use
that Softmax account's credits. Publishing also requires push access to
`polyworld-buff`.

The runner, scoring, persistence, report generation, and tests are Nim. The small
browser component is also written in Nim and compiled to JavaScript. HTML embeds
that generated script, Rubik fonts, the GotA logo, and the original ladder icons.

## 1. Install tools

The commands below use a macOS or Linux shell. You need Git, Git LFS, a C
compiler, libcurl, Nim 2.2.10 or newer, Nimby, and uv. The runner uses libcurl
through Curly. uv installs the separate Softmax login helper.

On macOS with Homebrew installed:

```sh
xcode-select --install
brew install git git-lfs nim uv
```

Skip `xcode-select --install` if the command-line developer tools are already
installed. On Ubuntu, install the native prerequisites with:

```sh
sudo apt-get update
sudo apt-get install -y build-essential git git-lfs libcurl4-openssl-dev \
  libx11-6 libxext6 libxcursor1 libgl1
```

On Linux, also install [Nim](https://nim-lang.org/install_unix.html) and
[uv](https://docs.astral.sh/uv/getting-started/installation/) using their official
installation instructions. Then install [Nimby](https://github.com/treeform/nimby)
and select the compiler version used for this guide:

```sh
nimble install -y nimby
export PATH="$HOME/.nimble/bin:$HOME/.local/bin:$PATH"
nimby use 2.2.10
export PATH="$HOME/.nimby/nim/bin:$PATH"
nim --version
git lfs version
uv --version
```

Keep these PATH entries in your shell configuration for later sessions.

## 2. Clone and install dependencies

Keep the repositories and Nim dependencies together in a dedicated workspace.
Run this block from the directory where you want that workspace:

```sh
mkdir gota-workspace
cd gota-workspace
git lfs install
git clone https://github.com/Metta-AI/polyworld.git
git clone https://github.com/Metta-AI/polyworld_art.git
git -C polyworld_art lfs pull
nimby create
nimby install polyworld/polyworld.nimble
nimby sync polyworld/nimby.lock
cd polyworld
```

The install step includes dependencies such as `yaml` that are declared in the
Nimble file; the sync step then applies the repository's dependency lock file.
Run both steps from `gota-workspace`, not from inside the `polyworld` checkout.
Assets now live in `polyworld_art`, not the older `polyworld_data` repository.
For assets stored elsewhere, set `POLYWORLD_ART` to that checkout's absolute path.

All remaining commands run from the `polyworld` repository root unless noted.

## 3. Log in to Softmax

```sh
uv tool install softmax-cli
export PATH="$HOME/.local/bin:$PATH"
softmax login
softmax status
```

Complete the browser login with the account that will run the tournament.
The [Softmax CLI](https://github.com/Metta-AI/metta/tree/main/packages/softmax-cli)
stores credentials in `~/.softmax/credentials.yaml`. The Nim runner reads that
file directly; it does not invoke Python or the CLI to run games. Each operator
should log in themselves rather than copy someone else's credential file.

## 4. Build and check

Build the browser script, runner, and replay statistics inspector together:

```sh
nim r -o:tmp/gota/tools/build_tournament examples/gods_of_the_arena/tools/build_tournament.nim
tmp/gota/tools/tournament --help
```

The build writes `report.js`, `tournament`, and `inspect_players` under
`tmp/gota/tools/`. It also runs `nim check` on the runner and inspector. Building
and `--help` do not submit games. The offline fixture checks below provide a
further check before spending credits.

The inspector needs the game source corresponding to the hosted release. Keep
the built inspector when preserving an older tournament; see replay collection
below. Record `git rev-parse HEAD` with your operating notes before starting.

## 5. Start a tournament

Choose a new run name for each tournament. This example starts 1,000 games:

```sh
GOTA_RUN="gota-top10-1000-$(date +%Y%m%d-%H%M%S)"
GOTA_SEED="$(date +%s)"
echo "$GOTA_RUN"
tmp/gota/tools/tournament \
  --run "$GOTA_RUN" \
  --games 1000 \
  --top 10 \
  --format both \
  --seed "$GOTA_SEED" \
  --check-every 10 \
  --concurrency 4 \
  --no-site
```

This command submits real hosted games. Use `--games 100` for a preview or
`--games 2000` for a larger tournament, with a new run name. The game count is
the total across both formats, not the count per leaderboard.

- Mixed: 500 games with ten distinct policies, one hero per policy in 5v5 teams.
- Mono: 500 games with two policies, each controlling five heroes.
- Players are shuffled through teams and hero slots using a seeded, balanced
  schedule. That schedule stays unchanged on resume.
- Each format produces win/loss, XP per minute, and Glory standings from the
  same games. There are six leaderboards, but only 1,000 actual games.
- Stability is reported every ten games within each format. It does not stop
  the tournament early.

The runner sends separate experience requests. It does not edit the Competition
division's configuration or matchmaking rules. Keep the runner's terminal open
and the machine awake so it can continue submitting and collecting games. Run
time depends on the hosted queue, game duration, and concurrency.

## 6. View the report

The runner prints the report's absolute path when it starts. All output goes
under `tmp/gota/tournaments/<run-name>/` in the checkout used to build the runner:

| Path | Contents |
| --- | --- |
| `report.html` | Live and final standings, player statistics, stability |
| `run.json` | Frozen roster, settings, release, and schedule |
| `games/` | Authoritative request attempts and results |
| `summary.json` | Derived progress, standings, and stability history |
| `exports/` | CSV exports, including player statistics |
| `replays/` | Cached replays and verified player counters |

In a second terminal, from the same repository root, set `GOTA_RUN` to the
actual saved name printed earlier. Then open the report. On macOS:

```sh
GOTA_RUN="paste-your-saved-run-name-here"
open "tmp/gota/tournaments/$GOTA_RUN/report.html"
```

On Linux, use `xdg-open` instead of `open`. Refresh manually as games finish.
The report uses the same layout during and after the run and embeds its assets
for offline viewing. You can send `report.html` by itself to someone else;
external replay links still need network access and any required Softmax
permissions.

## 7. Pause, resume, or retry

Press Ctrl+C once to pause. The current response and file replacement finish,
then the runner writes the paused report. Already submitted games continue
remotely. Wait for the runner to exit before starting it again.

Resume with the saved name. In a new terminal, first set `GOTA_RUN` to that
name as shown above:

```sh
tmp/gota/tools/tournament --run "$GOTA_RUN" --concurrency 4 --no-site
```

The runner reconciles submitted requests before scheduling remaining games.
Do not generate a new run name when resuming, and do not add a different
`--games`, roster size, seed, or format. These settings are frozen. Operational
options such as concurrency can change; repeat `--no-site` on each invocation
if you want local output only.

Keep one runner per run directory. There is no local lock or database. Run
folders are resumable JSON state, so preserve the entire folder when backing
up or transferring a run. Rebuild the tools at the destination checkout rather
than copying binaries, which contain their original checkout path. Continuing
someone else's run also requires access to its original Softmax requests;
uncertain-submission recovery searches the original requester's history.

If a game fails, inspect the report and saved game record first. To submit
replacement attempts for failed scheduled games:

```sh
tmp/gota/tools/tournament --run "$GOTA_RUN" --retry-failed --no-site
```

Retries can consume additional hosted credits. Failed games remain visible and
unscored until replaced, and completed games count only once. Ctrl+C normally
returns exit code 130; a failed game returns 1; successful completion returns 0.

Rebuild the saved HTML and exports without submitting or fetching games:

```sh
tmp/gota/tools/tournament --run "$GOTA_RUN" --report-only --no-site
```

`run.json` and `games/*.json` are authoritative. Each game stores submission
attempts, pinned payloads, request keys, remote IDs/status, and original result
artifacts. Atomic sibling-file replacements flush the file and its directory.
Abandoned `.tmp` files are ignored. Summaries, CSV exports, and HTML are derived.

## 8. Publish to Polyworld Buff (optional)

Clone the site beside the other repositories, from the `polyworld` root:

```sh
git clone https://github.com/Metta-AI/polyworld-buff.git ../polyworld-buff
```

If that checkout already exists, use it instead of cloning again. Before
generating a publication, start with a clean site checkout and update it:

```sh
git -C ../polyworld-buff pull --ff-only
tmp/gota/tools/tournament \
  --run "$GOTA_RUN" \
  --report-only \
  --site ../polyworld-buff
git -C ../polyworld-buff status --short
git -C ../polyworld-buff diff --check
git -C ../polyworld-buff add GOTA/standings/index.html GOTA/assets
git -C ../polyworld-buff commit -m "Update GotA tournament standings"
git -C ../polyworld-buff push
```

Review the generated changes before committing. GitHub Pages publishes the
latest report at [GotA standings](https://metta-ai.github.io/polyworld-buff/GOTA/standings/).
This replaces the site's latest standings; the run folder preserves the local
tournament. The runner updates local files and does not commit or push them.

The report uses the same header and stylesheet as the published GotA standings.
Without `--no-site`, when the sibling `polyworld-buff` checkout exists, every
report update also writes `polyworld-buff/GOTA/standings/index.html` and copies its fonts and icons into
`GOTA/assets/`. This includes results, pauses, failures, restarts, and completion.
The existing `GOTA/site.css` supplies the exact current site styling and is
embedded in the local HTML so that file still works offline.

Use `--site PATH` for another checkout, or `--no-site` for local output only.
These are operational options and may change on resume. Without a site checkout,
the local report uses the bundled copy of the same stylesheet.

## Options

Options include `--top`, `--format mixed|mono|both`, `--league`, `--division`,
`--seed`, `--check-every`, `--concurrency`, and `--server`. Defaults are top 10,
both formats, 10 games per stability checkpoint, and four remote requests.
`--games` is the total across formats; mixed receives an odd remainder.
The default seed is 2026 if omitted. `--league` and `--division` take API IDs,
not display names or dashboard URLs. The default API is `https://softmax.com/api`,
unless overridden by `COGAMES_API_URL` or `--server`; resume uses the saved server.

## Submission recovery

GotA release `2026.9.14.2` introduced the original ten-seat `total_xp` result array.
The selected hosted release must emit this field. The runner submits direct XP
requests through the existing API and persists their returned IDs before
collecting results. Every attempt includes a unique request key in its purpose
note.

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
tmp/gota/tools/tournament --run "$GOTA_RUN" --report-only --collect-stats --no-site
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

## Troubleshooting

| Symptom | Action |
| --- | --- |
| Git reports repository not found or permission denied | Sign in to GitHub with repository access, or clone with your configured SSH key. |
| `nim`, `nimby`, or `softmax` is not found | Restore the PATH entries from setup and check the tool installation. |
| A Nim module such as `yaml/tojson` is missing | From the workspace parent, rerun both the Nimby install and sync commands, then rebuild. |
| Report assets are missing or look like Git LFS pointers | Run `git -C ../polyworld_art lfs pull` and check `POLYWORLD_ART`. |
| Softmax login is missing or API access fails | Run `softmax login` and `softmax status`; verify the API server and your account's league/request permissions. |
| The hosted release must emit `total_xp` | The league-selected release lacks required per-seat XP. Have its maintainer supply a compatible release before running. |
| Not enough eligible policies | Mixed games require ten distinct eligible policies. Check the selected league and Competition division. |
| Replay hash mismatch or fewer Stats games | Use a release-matching `--stats-worker`, then rerun with `--report-only --collect-stats`. Saved match results remain intact. |
| Cannot change a saved setting | Resume using the original settings, or create a new run name for a different tournament. |
| Unsupported saved run schema | Use the original compatible runner for that run. Do not rewrite its schema number to force a resume. |
| Submission outcome is uncertain | Follow submission recovery above. Preserve the attempt and reconcile its remote request before retrying. |
| Site file is missing | Point `--site` at a complete `polyworld-buff` checkout, or pass `--no-site`. |

For a handoff, share this guide, the source revision, the saved run name, and
the whole run directory if someone needs to continue or audit it. For readers
who only need the results, share `report.html` and the CSV exports.
