# Local hero balance experiments

Build the Nim runner from the Polyworld root:

```sh
nim c -o:tmp/gota/tools/balance examples/gods_of_the_arena/tools/balance.nim
```

Use one frozen BASIC policy in all ten seats and a saved Competition game config:

```sh
POLYWORLD_DEPS="$PWD/tmp/coworld/deps" tmp/gota/tools/balance \
  --run khors-experiment \
  --policy /absolute/path/policy.bas \
  --policy-label 'khors v180' \
  --config /absolute/path/config.json \
  --games 100 --rounds 10 --jobs 14 --step 5 --seed 20260923
```

The macOS/Linux scheduler uses `std/osproc` to maintain up to 14 concurrent native
processes.
Each process runs one complete match. Processes isolate the simulation's global
state and BASIC runtimes. Every round finishes before its successor is compiled.
Failed or timed-out games stop the experiment rather than becoming losses.
Repeat the same command to resume completed game records.
Ctrl+C stops active workers, and the next invocation collects already completed
results. A filesystem lock prevents two schedulers from writing the same run.

Output is under `tmp/gota/balance/NAME/`, outside the asset repositories. The tool
archives the current Git commit, copies the supplied policy and config, records
the policy SHA-256, and compiles workers in that private source snapshot. It
requires a clean tracked engine and the pinned dependency checkout specified by
`POLYWORLD_DEPS`. Untracked tool files are copied into the snapshot as well.

The caller selects the policy. To reproduce a league champion, resolve its exact
policy-version ID from the current Competition leaderboard and verify the file's
SHA-256 against the submitted version. Keep that lookup receipt next to the run.
The runner does not modify, upload, or retrain the policy between rounds.

Each 100-game round uses 50 random rosters, each played with both side assignments
and mirrored spawn slots. All ten heroes appear exactly once per game and exactly
50 times per side per round. Paired games share a seed. Rounds use fresh seeds.
The policy controls combat; the experiment assigns the draft. This prevents a
deterministic draft from always grouping the same heroes together.

Win rate is wins divided by wins plus losses. Draws are reported separately.
An all-draw batch has no measured win rate and makes no adjustments. The report's
95% confidence margins for win rate, level, XP, and gold cluster paired games
together. The 45-55%
band is an adjustment rule, not a statistical significance test. One hundred
games can cross that band through randomness, and self-play with one policy
does not establish balance across the entire league.

The rules in `balances.nim` increase a distinctive strength below 45% and deepen
an existing weakness above 55%. Exactly 45% or 55% receives no adjustment.
Integer steps round to the nearest point, with a minimum change of one.
Every lever stays between half and twice its starting value. Strength and
weakness levers are separate; the tool does not homogenize hero attributes.

| Hero | Buff below 45% | Nerf above 55% |
| --- | --- | --- |
| Vanguard Knight | HP per level | Slower movement |
| Ranger | Faster movement | Less HP per level |
| Arcanist | Arcane Meteor damage | Less HP per level |
| Druid Warden | Thorn Bloom healing | Less basic damage |
| Demon Hunter | Gale Slash damage | Less base HP |
| Death Knight | Sanguine Chalice healing | Slower movement |
| Crossbowman | Basic damage | Slower reload |
| Lich | Bone Marionette root duration | Less HP per level |
| Warlock | Dread Pact healing | Less basic damage |
| Berserker | Basic damage | Less base mana |

`report.html` is a static report, updated after every batch. `results.json`
contains the same measurements. While running, the open page reloads every 20
seconds. `report-data.json` supplies the report's derived confidence intervals.
Each round retains its worker, exact tuning,
scheduled jobs, all game results, and a sample replay. Experimental replays must
be played with their round's exact tuning and archived source. The runner builds
`balance_verify.nim` against that source and verifies every sample replay tick
before choosing the next tuning. Repeating a completed run regenerates the
report from saved individual game results without playing additional games.
The standalone `balance_report.nim RUN_DIRECTORY [--watch]` command can refresh
the report while an older runner is still working.

Ten rounds mean ten tested configurations and nine applied adjustment steps.
`final-content.nim` and `final.patch` describe round ten's tested configuration.
`suggested-content.nim` contains the additional adjustments suggested by round
ten, which have not been tested. No production stats, published reports, or
hosted releases change automatically.

Check the runner and its schedule, scoring, and adjustment tests:

```sh
nim check examples/gods_of_the_arena/tools/balance.nim
nim check -d:headless examples/gods_of_the_arena/tools/balance_worker.nim
nim check examples/gods_of_the_arena/tools/test_balances.nim
nim r -o:tmp/gota/tools/test_balances examples/gods_of_the_arena/tools/test_balances.nim
```

## Sequential confidence search

Use `--method sequential --seed 1988 --step 50` to change one hero per batch.
The same 100 lineups are used in each batch. Game indices 0 through 99 use seeds
1988 through 2087, including a different seed for each mirrored game. Confidence
intervals still cluster the two games with the same roster together.

A hero passes when its unrounded 95% win-rate interval includes 50%, including
an endpoint exactly equal to 50%. For example, 37% plus or minus 13 percentage
points passes. All-draw results have no measured win rate and do not pass.
The search prioritizes Crossbowman, Ranger, and Demon Hunter, then checks the
remaining heroes. It keeps tuning the selected hero until that hero passes.
All heroes are measured again after every change because their outcomes interact.

The first change strengthens a distinctive strength or deepens a weakness.
An overshoot reverses that same attribute, testing the integer midpoint between
observed settings on opposite sides of the target. Only observations where every
other tuning value matches are used to form that bracket. Expansion uses `--step`
percent. Values are bounded between 1 and eight times this run's starting value.
If Ranger still fails above 50% at one HP per level, the search continues by
reducing her base HP. Overshoots then walk back base HP, leaving growth unchanged.
The run stops when all heroes pass, the batch limit is reached, or no integer
step remains for the selected hero. `completion.json` records the actual reason.

Use `--initial-content FILE` to continue from a previous experiment's tested
`final-content.nim`. Otherwise, the initial tuning comes from the archived Git
commit. The HTML distinguishes the experiment's initial tuning from later tested
changes. `final.patch` includes all differences from the archived production
source, including inherited experimental changes. Nothing is applied to production.

```sh
POLYWORLD_DEPS="$PWD/tmp/coworld/deps" tmp/gota/tools/balance \
  --run khors180-sequential-1988 \
  --policy tmp/gota/balance/khors180-10x100/policy.bas \
  --policy-label 'khors v180 (Andre von Auto)' \
  --config tmp/gota/balance/khors180-10x100/config.json \
  --initial-content tmp/gota/balance/khors180-10x100/final-content.nim \
  --method sequential --games 100 --rounds 10 --jobs 14 --step 50 --seed 1988
```

Reusing fixtures makes changes easier to compare, but the displayed intervals
are exploratory. Passing this stopping rule does not demonstrate equivalence to
50% or validate balance on fresh games or other policies.

## Farthest hero with complete teams

Use `--method farthest --draft roles --rounds 10` for a maximum of ten batches,
including the baseline. Requests for more than ten batches are rejected before
any games start. Each batch changes just the measured hero farthest from 50%
whose 95% interval still excludes 50%. Delta is that absolute distance in
percentage points. The search stops early if every hero passes.

Role drafting replaces only `chooseHero()` in the supplied BASIC policy.
The original is retained as `original-policy.bas`, and combat code is unchanged.
The revised policy rejects roles already covered by its team and uses no old
hero strength scores. Without experiment preferences, it rotates eligible picks.
For experiments, the worker supplies seeded tie-break preferences to the policy's
globals. The policy makes the real draft commands and still enforces role coverage.
Every finished match is checked against the planned roster and role coverage.

Each team gets one hero from every pair:

| Role | Heroes |
| --- | --- |
| Frontline | Vanguard Knight, Death Knight |
| Carry | Ranger, Crossbowman |
| Mage | Arcanist, Lich |
| Support | Druid Warden, Warlock |
| Fighter | Demon Hunter, Berserker |

The schedule shuffles choices independently across roles. All 32 possible team
compositions appear three or four times per side in 100 games. Mirrored pairs
give each hero exactly 50 appearances on each side. Spawn slots are shuffled too.
The same compositions and seeds 1988 through 2087 repeat in every batch.
The two heroes in each role necessarily oppose one another, so their decisive
win rates sum to 100%; interpret them as comparisons within that role.

```sh
POLYWORLD_DEPS="$PWD/tmp/coworld/deps" tmp/gota/tools/balance \
  --run khors180-roles-farthest-1988 \
  --policy tmp/gota/balance/khors180-10x100/policy.bas \
  --policy-label 'khors v180, complete role draft' \
  --config tmp/gota/balance/khors180-10x100/config.json \
  --initial-content tmp/gota/balance/khors180-sequential-1988/priority-content.nim \
  --method farthest --draft roles --games 100 --rounds 10 \
  --jobs 14 --step 50 --seed 1988
```

`test_balance_drafts.nim POLICY CONFIG` checks actual BASIC drafting on all 100
seeds, with and without supplied preferences. It ends at draft completion and
does not play any combat matches.

## Reviewed role pairs

`--method paired --draft roles --rounds 10 --games 100` runs exactly one pending
batch per invocation, then returns for replay review. All games retain replays
and tick-event diagnostics for casts, effective damage, overkill, incoming damage,
healing, survival time, low mana, and rejected casts. Diagnostics do not change
simulation state. `balance_verify REPLAY OUTPUT.json` reconstructs those counters
and the hero death timeline while verifying every replay tick.

Before resuming, write `round-NN/decision.json` with `base_batch`, `role` (0–4),
`diagnosis`, and `changes`. The base selects an already tested configuration.
Each change specifies `hero_id`, `hero`, `anchor`, `field`, `before`, `after`,
`kind`, `reason`, and `method`. Exactly both heroes in the selected role must
change, or the change list must be empty to hold a configuration. A rejected
candidate can return to a better tested base; the report records that choice.
The review must explain the observed gameplay evidence and the next hypothesis.

Batches 1–8 use the same seeds and complete-role fixtures. After batch 8, select
one tested configuration without further edits. Batches 9–10 validate identical
stats on fresh seeds 11988–12087 and 21988–22087 when the initial seed is 1988.
These games are included in the ten-batch limit. A review may set `validation`
to true to freeze a tested configuration earlier after the target passes. All
remaining batches then use successive fresh seed blocks, and the final report
pools their confidence intervals. No tuning is allowed after that freeze. Run
data remains in the temporary experiment directory.

The final `validation-summary.json` pools only frozen, fresh-seed games. Training
batches do not contribute to that estimate. Completion reports whether this
pooled validation meets the confidence criterion, even if training passed sooner.

## Support policy repairs and frozen checks

The downloaded khors policy omits restoration spells and only considers healing
itself while fighting. `balance_policy.nim` writes a corrected copy. Mana Crystal
and other restoration spells can trigger without an enemy nearby. Druid selects
a wounded, visible ally within healing range even at full health, before retreat
and movement decisions. It checks skill rank, charges, cooldown, mana, and silence.
Other heroes retain their previous offensive and healing decisions.

```sh
POLYWORLD_DEPS="$PWD/tmp/coworld/deps" nim r -d:headless \
  -o:tmp/gota/tools/balance_policy \
  examples/gods_of_the_arena/tools/balance_policy.nim \
  /absolute/path/original-policy.bas /absolute/path/content.nim \
  /absolute/path/corrected-policy.bas
```

The patch requires the known khors layout and rejects duplicate application.
It computes ally maximum health from public hero, level, and equipped-item stats
instead of waiting to observe that ally at full health. Those constants come
from the supplied content file; regenerate the policy if health or item stats
change. The Druid range check follows the current four-tile spell range with a
tenth-tile margin. Original policies and previous runs remain unchanged.

Use `--method evaluate --draft roles --rounds 1` for one frozen evaluation batch.
It retains diagnostics and every replay, verifies a sample, and makes no stat
adjustments or next-step suggestions. Use two different run names with the same
policy, seed, and game count to compare a single content change. Jobs still run
through the bounded Nim `osproc` scheduler. Evaluation is separate from the
ten-batch tuning sweep and does not extend a completed sweep.

Use `--games 200` for 200-game tests. All 32 complete-role compositions appear
six or seven times per side, with each hero appearing 100 times on each side.
Keep the same seed for comparisons, and use fresh seeds for validation.

`--snapshot working` explicitly freezes tracked local source edits on top of
the archived commit. The run stores their complete `source.patch` and SHA-256,
copies modified files, and checks that the patch did not change during copying.
Resuming rejects a different working patch. This allows testing uncommitted
gameplay changes without silently testing the old committed rules. Unrelated
untracked files are excluded; the named balance tools are copied as before.

`test_balance_policies.nim ORIGINAL_POLICY TEMP_OUTPUT_POLICY` checks both sides,
actual mana restoration, actual ally healing, equipment, and invalid conditions
without playing full matches. Diagnostics distinguish spell healing, healing
other heroes, effective restored mana, and casts targeting allies. The full-HP
counter measures casts in ticks that end with the caster at full health.
