# GotA neural seats (`gota-neural-basic/1`)

This document covers the GotA neural package tier and the native training environment that shares its
code. PR #72 added metered `linear/relu/argmax` and `DATA` arrays to BASIC but deferred external
weights. That leaves a pure-BASIC network at about 4k parameters (the 4,096 array elements) and about 9k
multiply-accumulates per decision. A neural package lifts both limits for one seat. It adds a native FP32
actor, a separate per-seat operation budget, and hash-pinned observation and action contracts. The seat
still plays through the same BASIC host and the same recorded commands, so replays and the simulation do
not change. Plain `.bas` submissions are untouched: without a neural seat, a match is byte-identical to
upstream (see "Evidence").

Code map (all in `examples/gods_of_the_arena/`):

| file | role |
|---|---|
| `neural_contract.nim` | observation v1 builder, action v1 decoder, demonstration encoder, contract texts + SHA-256 |
| `neural_actor.nim` | GOTANET1 loader and FP32 MinGRU inference |
| `neural_package.nim` | strict ZIP/manifest parser |
| `neural_host_hooks.nim` (included by `bots.nim`) | neural seats: frames, inference, `gota_act`, label capture, override, shadow |
| `neural/policy.bas` | default glue: draft, shopping, ability leveling, buyback (base.bas routines) + `gota_act()` |
| `native_env.nim` / `native_env.h` | the training C ABI |
| `tools/native_env.py` | ctypes binding |
| `tools/test_native_env.py`, `tools/test_native_concurrency.py`, `tools/mapping_ceiling.py`, `tools/parity_upstream.sh`, `tools/canary.py` | acceptance tools |
| `../../coworld/gota/runtime/neural_package.py` | staging validator + builder (mirrors the Nim parser) |

## Package

A package is a ZIP containing exactly three files: `manifest.json`, `policy.bas` and `model.bin`. Stored
and deflate entries are allowed; encrypted entries are not. The whole package is at most 16 MiB, and
`policy.bas` at most 256 KiB. The runtime recognises a package by its `PK\x03\x04` prefix. Anything else
is plain BASIC, and plain BASIC follows exactly the old path, including its 256 KiB bounded read.

```json
{
  "schema": "gota-neural-basic/1",
  "observation_contract": "ae4046e83cc02e861f9c8cc32550c6cc4d6f9c161c9225a9b34a314d310ea991",
  "action_contract": "ecc7d53c11a9db0912467c66ecb3e65b60b3e71ef14dad1442ba3b4f6ac14697",
  "decision_period": 4,
  "files": {"policy.bas": "<sha256 hex>", "model.bin": "<sha256 hex>"},
  "model": {"format": "GOTANET1", "inputs": 1407, "hidden": 128, "heads": [8, 25, 49, 4, 6]},
  "goal": {"red": [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "blue": [ ...16... ]},
  "decoder": {"mode": "argmax"}
}
```

Every key at every level is checked, and an unknown key rejects the package. `goal` and `decoder` are
optional. The default goal is e_score, and the default decoder is argmax.
`decoder.mode = "sample"` takes an optional `temperature` in 0.01..10; `temperature` without `sample` is
rejected. Each goal vector has 16 values in [-1, 1], and w_reserved (index 15) must be 0. The host
appends the vector of the seat's own team to that seat's observation. Both contract hashes must match
the game and the hashes stored inside `model.bin`. `decision_period` (1..24) must equal the period the
network was trained with; the native env's `decision_period` config key is the same number.

Build and validate with `python3 coworld/gota/runtime/neural_package.py build|validate`. The validator
accepts exactly the packages the game accepts. `tools/test_native_env.py` checks that they agree on eight
corruptions, including an unknown decoder key, a bad goal, a hash mismatch and extra or missing files.

## Residual seats: `decoder.defer_script` (Amendment 3)

`"decoder": {"defer_script": true}` (a boolean; combines with `mode`/`temperature`) turns verb 0 into
DEFER. `policy.bas` is then the script to defer to, for example `players/base.bas` verbatim, with no glue:
it is the seat's real program. It runs every tick on the true world state, and it drafts, shops, levels
abilities and buys back itself; those non-contract calls always execute. It needs no `gota_act`, and if it
calls one, the call does nothing. The network runs on each decision tick as usual. Before the script's BASIC
turn on that tick, the host consults the decoded heads once:

- **verb 0, defer.** Every contract command (walkTo, attackMove, attackTarget, castTarget, castPoint,
  useItem, useItemAt) the script issues in this decision window executes live, on the tick it is issued.
  The window is the decision tick plus the next `decision_period - 1` ticks.
- **Any other verb, override.** The decoded command is issued on the decision tick; an invalid choice
  issues nothing and counts as invalid. For the rest of the window, the script's contract commands are
  absorbed: they are not executed, the call returns 1, and `lastActionError` is unchanged.

The script is never paused or re-run, and it keeps its persistent variables. After an override it sees the
hero where the network's command put it, but its variables may still assume that its absorbed orders ran.
base.bas re-issues an order only when it changes (or on its periodic refresh), so after an override the
network's order stays held until the script issues a new one. A seat that is dead at the decision frame
defers.

An always-defer network is byte-identical to a plain seat running the script (state hash every tick and the
replay bytes; `tools/test_defer.py` a). The VM keeps the neural-seat structure limits (160 host functions)
but the plain-seat budget of 20k instructions and 50k work units per tick. The network consult is host-side
and costs no BASIC instructions, so the script runs out of budget exactly where a plain seat would. Seats
without the key keep verb 0 = noop.

The native equivalent is `gota_set_seat_defer_script(h, seat, path)` on a learner seat (see native_env.h).
It uses the same code path, `deferConsult` in neural_host_hooks.nim, at the same point in the tick. The
native call adds `gota_seat_orders` labels of the script's commands, issued or absorbed.
`gota_seat_defer_stats` gives the {defer, override} decision counts for both kinds of seat. Build a
package with `neural_package.py build --defer-script --policy players/base.bas --model model.bin`.

## model.bin (GOTANET1)

The layout is paintbot-pw's PWNET001 with the magic changed to `GOTANET1`:
`magic[8] | u32 version=1, inputs I, hidden H, outputs O, heads n, parameters P | obs sha256 hex[64] |
action sha256 hex[64] | u32 head sizes[n] | f32 LE weights`. The weights come in this order: `W_enc[H][I]`
(x = W_enc·obs, no bias, no activation), `W_rec[3H][H]`, then `W_dec[O][H]`. H must be 64, 128 or 256, and
P must equal `I·H + 3H² + O·H` ≤ 2,000,000.

One MinGRU step, the same as PufferLib's `mingru_gate`:

```
c = W_rec · x            (split into hidden, gate, proj, H each)
h~ = hidden >= 0 ? hidden + 0.5 : sigmoid(hidden)
state' = lerp(state, h~, sigmoid(gate))        (PufferLib's two-branch lerp)
y = sigmoid(proj) * state' + (1 - sigmoid(proj)) * x
logits = W_dec · y
```

The published cost is `2·P + 32·H` operations per inference: 218,496 for w64, 486,144 for w128 and
1,168,896 for w256. A seat runs at most one inference per tick, against its own **4,000,000
operations per tick** budget. A model over budget is rejected at load. This budget is separate from
BASIC's instruction budget. Nonfinite weights, inputs, state or outputs are errors. An inference error
disables the seat the same way a BASIC runtime error does.

## Decisions, state and telemetry

Decision ticks are battle ticks 1, 1 + p, 1 + 2p, … where p is `decision_period`. At the start of the
heroes' turn on a decision tick, before any seat's BASIC runs, every neural seat freezes its **decision
frame**. The frame is the observation plus the 25 object slots, taken from the same frozen object frame
BASIC reads. If the seat is alive, the host then runs the network (package seat) or takes the trainer's
heads (native learner seat) and decodes one command. `policy.bas` issues that command by calling
`gota_act()` during the seat's normal turn. The command goes through the same recorded host path as
`walkTo`/`castTarget`/…, so replays contain ordinary actions and re-simulate without the network. Between
decisions nothing is issued. The engine keeps executing the last order (its path or attack target); that
is the "held command". A decoded noop issues nothing.

The recurrent state is zeroed before the first decision of a match, and before the first alive decision
after a death (death, respawn and buyback included). No inference runs while the seat is dead. The
native env's `resets[]` flag marks exactly these points.

Sampling (`decoder.mode = "sample"`) keeps one SplitMix64 stream per seat, seeded with
`uint32(match seed) * 1000003 + seat + 1`. Each head takes one 53-bit draw in head order from
softmax(logits / T), computed in float64.

Package seats write to their private seat log:
`neural: peak_ops=<ops> budget=4000000 model=w<H> ticks=<battle tick> inferences=<n>`. The line is written
at the first inference, then every 1,800 inferences, then at the last decision of a full-length match.

BASIC surface for `policy.bas`, registered only for neural seats:
- `gota_act()`: issues the decoded command. It returns 1 if the command was accepted and 0 otherwise,
  and does nothing on non-decision ticks or a second call in the same tick.
- `run_neural_net()`: 1 when this tick has a fresh decision.
- `neuralObservation(i)`, `neuralLogits(i)`, `neuralState(i)`: Q16.16 reads.
- `neuralModel(k)`: k = 0 width, 1 inputs, 2 outputs, 3 period, 5..9 the chosen heads.

Package seats get `neuralVmLimits`: the hero limits with 160 host functions, 40,000 instructions and
100,000 work units per decision. These were raised for neural seats only, as Amendment 1 allows.
The shipped `policy.bas` peaks at 1,065 instructions per tick (10 learner seats, a full match), so the headroom is for richer glue scripts. Plain seats keep
`heroVmLimits` (20,000 / 50,000 / 128).

## Observation contract v1 (1407 float32)

The observation is ego-centric in the **team frame**. Blue seats see the map rotated 180°: x_t = −x and
y_t = −z. Both teams therefore read the same geometry. Distances are in tiles (1 tile = 60,000 world
units), and time is in ticks (24 per second). Only information a BASIC script of that seat can read is
used: fog-gated objects, team vision and known building state.

| offset | size | block |
|---|---|---|
| 0 | 48 | self |
| 48 | 4×16 | abilities (HeroAbilitySlot order: passive, primary, secondary, ultimate) |
| 112 | 6×25 | inventory slots |
| 262 | 25×40 | object slots |
| 1262 | 4×8 | spell warnings |
| 1294 | 16 | summary |
| 1310 | 81 | terrain |
| 1391 | 16 | goal w |

**Self (48):**
- 0 alive, 1 hp/maxHp, 2 mana/maxMana, 3 maxHp/2000, 4 maxMana/1000, 5 gold/1000, 6 level/20,
  7 xp/xpForNextLevel, 8 totalXp/20000, 9-10 position/64 (team frame), 11 team.
- 12 battleTick/max_ticks, 13 attack cooldown/48, 14 attack range tiles/10, 15 attack damage/200,
  16 move tiles per second/5, 17 has attack target.
- 18-21 stun/root/silence/channel ticks/72, 22 portal cooldown/1440, 23 respawn/1440.
- 24 ability points/4, 25 in own spawn, 26 can shop, 27 deaths/10, 28 last action error, 29 buyback
  affordable, 30-39 class one-hot, 40-44 role one-hot, 45-46 velocity ×10, 47 has move target.

Time features are clipped to 2.

**Ability (16):** rank/max, learned, cooldown/240, charges/3, recharge/240, mana cost/200, castable now,
damage/300, heal/300, restore/200, range tiles/10, cast kind one-hot (self, melee, projectile, area),
area radius/3.

**Item slot (25):** one-hot of the 23 items (NoItem … ManaPotion), count/4, cooldown/240.

**Object slots (25).** These are also the action's target slots:
- 0: self.
- 1-4: allies in seat order (present while alive).
- 5-9: enemy heroes in seat order (present while visible).
- 10-16: the 7 nearest visible living lane creeps of either team.
- 17: own god.
- 18: enemy god (visible).
- 19: own forward tower (the living allied tower nearest the enemy god).
- 20: nearest visible enemy tower or barracks.
- 21-24: the 4 nearest visible living neutrals.

Ties sort by id. Self is a slot so that `castTarget(self)` exists. Structures are role-named rather than
"nearest 4" so a portal scroll always has its two anchors, home and the front.

**Object features (40):**
- 0 present, 1-2 d/16 (±4), 3 dist/16 (≤8), 4 hp fraction, 5 hp/2000, 6 team (+1 ally, −1 enemy,
  0 neutral), 7-12 kind one-hot (god, hero, creep, tower, barracks, neutral), 13 alive/attackable,
  14 level/20, 15 mana/1000.
- 16 targets me, 17 is my target, 18 targets an allied hero, 19-21 stun/root/silence/72, 22-23 velocity
  ×10, 24-25 facing (unit, team frame), 26 inside my attack range, 27 hp ≤ my attack damage,
  28 returning, 29 creep kind or neutral tier/3, 30-39 hero class one-hot.

**Spell warnings (4 × 8):** the visible unresolved casts sorted by impact tick, then distance. Features:
present, d/16, dist/16, ticks to impact/72, hostile, harmless (heal/restore), ability/40.

**Summary (16):**
- 0 own god hp, 1 own god exposed, 2-3 own towers and barracks alive fraction, 4-5 enemy towers and
  barracks known alive, 6 enemy god hp if visible else −1, 7 own heroes alive/5, 8 visible enemy
  heroes/5, 9 wave timer fraction.
- 10-11 own and visible-enemy level sums/50, 12 my league score/5000, 13-14 my kills and assists/10,
  15 zero.

**Terrain (81):** a 9×9 known-walkable patch at a 2-tile stride centred on the hero's tile, in the team
frame and row-major. Offset (−8, −8) comes first.

**Goal (16), Amendment 1 order:**
- w_score, w_win, w_xp, w_gold, w_hero_kill, w_assist, w_death, w_last_hit, w_neutral_kill,
- w_tower_damage, w_structure_kill, w_hero_damage, w_damage_taken, w_push_depth, w_god_damage,
  w_reserved.

## Action contract v1: heads {verb 8, target 25, point 49, ability 4, item 6}

| verb | command |
|---|---|
| 0 noop | nothing (hold) |
| 1 walk / 2 attackMove | to self + point (walk rings 2, 5, 12 tiles), rounded to the tile centre; point 0 = own tile (stop) |
| 3 attackTarget | the target slot's object (not self) |
| 4 castTarget | ability head on the target slot's object (self allowed) |
| 5 castPoint | ability head at target object + point (cast rings 0.5, 1.25, 2.5 tiles, fractional) |
| 6 useItem | item head's inventory slot |
| 7 useItemAt | item head's slot at target object + point (cast rings) |

The point is `0` for the centre, or `1 + ring·16 + dir`, where dir k is at k·22.5° counter-clockwise from
team-frame +x. The direction table is integer Q16, so decoding is identical on every platform. An empty
target slot, an out-of-range head, or a dead seat decodes to noop and is counted in
`invalid_actions`. Draft, shopping, ability leveling and buyback stay in BASIC (`policy.bas`).

**Demonstration encoder** (BC labels, the mapping ceiling, DAgger):
- walk/attackMove follow the route the order would take (`planRoute` on a copy of the hero). The ring is
  chosen by route length (<1 centre, <3.5 ring 0, <8.5 ring 1, else ring 2), and the direction is the
  one nearest the route point at that ring's radius.
- attackTarget and castTarget look up the slot of the object id. An attack target outside the slots
  becomes an attackMove toward it (`exact = 0`).
- castPoint and useItemAt take the best (anchor slot, point) pair of the 25 × 49.

In one decision window, the first cast or item use wins; otherwise the last movement/attack order is
the label.

## Native training environment

See `native_env.h`. The build is:

```
POLYWORLD_DEPS=<deps per coworld/dependencies.lock> nim c --app:lib -d:release -d:headless \
  -d:gotaTrainingStats --mm:atomicArc --threads:on -d:useMalloc -u:nimTypeNames \
  -o:libgota_env.so examples/gods_of_the_arena/native_env.nim
```

A handle is one ten-seat match. Any mix of learner seats (which run `policy.bas` exactly as a package
seat does, with the caller's heads) and scripted seats is allowed on either team. Handles may be
stepped concurrently from different threads, and a handle may migrate between threads.
`-d:gotaTrainingStats` compiles the per-seat goal counters (gold earned, last hits, neutral kills, tower
and structure damage/kills, hero damage dealt/taken, god damage) into the library only. Live games never
compile them, and they are never hashed.

The trainer, the hosted seat and the mapping ceiling share one code path:
- A scripted seat in **capture** mode (default) has its commands encoded into `gota_seat_orders` labels.
- In **override** mode (`gota_set_seat_override`) the script's commands are intercepted, encoded, decoded
  and executed exactly as a learner's would be. This is the mapping ceiling.
- A learner in **shadow** mode (`gota_set_seat_shadow`) runs an expert script whose calls change
  nothing. Its commands become labels (DAgger).

## Evidence (branch `daveey/gota-neural`)

- **No-neural parity with upstream** (`tools/parity_upstream.sh`, 20 seeds, full 28,800 ticks, mixed
  base/puller/rusher lineup): the fork's headless binary writes replays byte-identical to
  upstream/main's. The native library (capture on, no neural seats) ends on upstream's final hash, and
  upstream's binary re-simulates its replay with zero mismatches.
- **Mapping ceiling** (`tools/mapping_ceiling.py`, 100 seeds, full length): base.bas routed through the
  contract loses nothing against plain base.bas.
  - Red paired XP delta: +187 ± 70.
  - Blue paired XP delta: +45 ± 77.
  - Score: 260 vs 129 and 211 vs 99.
  - Wins: 2–3% vs 0%.
- **Package vs ABI parity** (`tools/test_native_env.py`, full length): a package-hosted seat and a
  learner seat driven through `gota_net_infer` with the same weights produce identical worlds at w64,
  w128 and w256.
- **Concurrency** (`tools/test_native_concurrency.py`): N threads × M handles give the serial per-step
  hashes.
- **Hosted canary** (`tools/canary.py`): the `-d:coworld` server runs 5 random-weight packages and 5
  base.bas seats for a full match. Every seat exits 0, the telemetry lines are present, and the replay
  re-simulates.
