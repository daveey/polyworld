# Author-written GOTA neural runners

Reviewed Nim code defines an architecture. Players upload BASIC and model data.
Uploaded files are never compiled, linked, or loaded as native code. BASIC builds
observations, invokes the model, reads its output and issues ordinary commands.
The runner cannot inspect the game world or issue commands.

```basic
dim data(1406)
if initialized = 0 then
  state = blobCreate()
  initialized = 1
end if
if selfHp <= 0 then
  blobClear(state)
  end
end if
' Scan observations and fill data here.
res = nn_david("weights.bin", state, data)
' Read res(0) through res(91) and issue ordinary game commands.
```

`nn_richard(resource$, state, data)`, `andre_nn(resource$, state, data)` and
`fly_nn(resource$, state, data)` have the same three arguments. Inputs and outputs cross the boundary as Q16.16
arrays. Integral BASIC values are converted
with range checking. A runner can use FP32, integers or another representation
internally. Outputs round to the nearest Q16.16 value, with ties away from zero.
Nonfinite and unrepresentable outputs fail the policy with a descriptive error.

State is an explicit VM-owned mutable blob. Empty state starts a new network.
Subsequent successful calls update it in place, including through aliases.
Initialized state is bound to its architecture and resource identity; clear it
before changing either. Stateless runners keep its byte payload empty but still
bind it to the model. Inference and conversion finish before state is committed.
A failed call leaves the previous state intact. BASIC decision restarts preserve
state. Full VM reset invalidates all buffers. BASIC controls death and respawn
resets; the supplied David glue clears state on death.

Models are parsed on first use and cached as immutable flat data in each policy
VM, keyed by architecture and package resource path. Policy unload releases the
VM, its callback closures, model cache, buffers and scratch storage. Returned
arrays are collected when unreachable from VM values. Assigning `copy = res`
creates an alias, and `copy(i) = value` changes the shared array. A result that is
needed later must remain in a BASIC variable or array. BASIC cannot read blob
bytes. The Bassy host interface is documented in its `docs/native-buffers.md`.

GOTA allows **100,000 instructions and 250,000 work units per decision** so the
BASIC observation and action glue can run. Existing BASIC storage and source
limits remain in force. Each neural invocation costs one host work unit. There
is no inference frequency or multiply/add budget. Package bytes, parsed models,
state, returned arrays and reserved scratch share a separate **32 MiB logical
native allowance per hero**. This is not a process RSS cap. Cache reservations
survive full VM reset because immutable model caches remain alive.

## Policy packages

Both local `--bot` and Coworld staged files accept raw BASIC or ZIP contents.
Detection uses file contents, including when the filename has no extension.
A raw BASIC file has no resources. ZIPs require exactly one `.bas` entry,
case-insensitively, at any path:

```text
player.zip
  scripts/policy.bas
  weights.bin
  auxiliary.bin
```

Resource paths are relative to the ZIP root, so the example policy uses
`"weights.bin"`. Paths are case-sensitive and never resolve on the host filesystem.
No common neural manifest is required. Architectures define their own binary
formats, and unused auxiliary files remain read-only resources.

Zippy reads the archive and returns the BASIC entry and binary resources as
strings. Uploads are limited to 16 MiB and packages to 256 files. The loader
requires one BASIC file and canonical resource paths. ZIP decoding, compression
support and checksum checks belong to Zippy, including stored, deflated and
ZIP64 archives. Polyworld does not implement ZIP parsing or decompression.

After unpacking, the VM compiler applies its existing BASIC source limit.
Native model and buffer limits apply when the neural runner is used. There is
no separate expanded-size limit in the ZIP decoder. The current Zippy reader
requires a filename, so byte uploads temporarily stage the compressed archive;
entry contents stay in memory, and the temporary ZIP is removed after reading.
Errors use `PolicyError`, `BasicError` or `NeuralError` and reach the existing
per-player failure reporting.

Runnable synthetic ZIPs are included under
`examples/gods_of_the_arena/neural/examples/` as `synthetic-richard.zip`,
`synthetic-david.zip`, `synthetic-andre.zip` and `synthetic-fly.zip`. Their names identify the runner
being tested. Their weights are deterministic test matrices, mostly zeros with
a few hand-set coefficients. They contain no trained weights or submitted
player policies. Regenerate copies locally:

```sh
nim r tools/gen_neural_examples.nim
nim c -d:headless -o:tmp/gota examples/gods_of_the_arena/gota.nim
tmp/gota --bot tmp/neural-examples/synthetic-richard.zip:5 \
  --bot tmp/neural-examples/synthetic-david.zip:5 --ticks 240
```

The readable BASIC examples are under
`examples/gods_of_the_arena/neural/policies/`. These are reusable BASIC glue
and examples written for this API. Downloaded and converted player policies
and trained weights stay in ignored `tmp/` for local validation.

## Richard

`neural/richard.nim` implements two row-major affine/ReLU/affine architectures:

| Kind | Input / hidden / output | Arithmetic | Output |
| --- | --- | --- | --- |
| IntegerCombat (0) | 25 / 16 / 18 | Ordered int32 wrapping | Integer combat scores divided by 65,536 |
| FixedResidual (1) | 31 / 8 / 19 | Ordered Q16.16, each input divided by 100 before multiplication | Q16.16 residual scores |

The scaled combat scores preserve every original int32 bit and therefore their
ordering. Use strict `>` when selecting a maximum to keep the first tied action.
Both networks are stateless. BASIC retains feature construction, drafting,
decision cadence, residual masks and action interpretation.

The binary format begins with the eight bytes `RICHNN01`, followed by a
little-endian uint32 kind. Encoder rows then decoder rows each contain an int32
bias followed by all input weights. There is no padding or trailing data.
Residual weights and biases store raw Q16.16 bits. Combat inputs must be integral
and representable at the Q16.16 boundary. Unsupported dimensions or extra bytes
fail loading.

The converter recognizes the reviewed integer and residual inference blocks,
exports only their coefficients and replaces those blocks with host calls:

```sh
python3 examples/gods_of_the_arena/tools/convert_richard.py \
  private-policy.bas private-policy.zip
```

It keeps combat and residual state handles separate and adjusts the scaled
combat score sentinel. Unrecognized source patterns fail instead of silently
changing unrelated BASIC. Keep converted private policies in ignored `tmp/`.

## David

`neural/david.nim` preserves the GOTANET1 FP32 encoder, MinGRU, highway and decoder
from [David's reference implementation](https://github.com/daveey/polyworld/blob/7863481e3c6b203602538517d4cfa9d7d7201e2a/src/polyworld/neural_actor.nim).
The reviewed tournament model has 1,407 inputs, 512 recurrent values, and 92
outputs in heads `[8, 25, 49, 4, 6]`. Its `model.bin` is used unchanged.

The loader accepts versions 1 and 2, 1 through 4,096 inputs, widths 64/128/256/384/512,
2 through 1,024 outputs, up to 32 heads and two million parameters. It validates
parameter counts, finite weights and exact byte length. Header contract hashes
are metadata owned by the architecture; the GOTA converter checks the exact
observation and action contracts before selecting this BASIC glue. State stores
one little-endian FP32 value per hidden unit. Outputs are unscaled Q16.16 logits.
The loader does not infer observations or decode actions.

### Optional auxiliary heads

Version 2 adds K optional auxiliary linear heads that read the same feature as
the action decoder (the highway output after the MinGRU). They let BASIC ask the
network for decisions the five action heads do not cover, such as draft, shop
or level choices. They read nothing but the existing trunk, so they add no
observation. A model without auxiliary heads is always version 1: its bytes,
parameters, outputs, state and memory accounting are unchanged. Layout:

| Bytes | Contents |
| --- | --- |
| 0..159 | Version 1 header with version 2; the parameter count includes auxiliary rows |
| 160.. | Head sizes, as in version 1 |
| next 4 | K, 1 through 16 |
| next 4K | Auxiliary head sizes, 2 through 1,024 each, 1,024 in total |
| rest | Encoder, recurrent and decoder weights as in version 1, then auxiliary rows `[A][H]` |

`nn_david` still returns only the action outputs, so existing glue reads the same
array. Each auxiliary logit is computed like a decoder output, with the same FP32
order and Q16.16 rounding. After a successful `nn_david` call these host functions
read its auxiliary logits in the same policy VM. Each costs one work unit:

| Function | Result |
| --- | --- |
| `nn_aux_count()` | K of the most recent successful call; 0 for a version 1 model or before any call |
| `nn_aux_size(k)` | Logits in head `k` |
| `nn_aux(k, i)` | Q16.16 logit `i` of head `k` |
| `nn_aux_argmax(k)` | First index of the largest logit of head `k` |

Heads and indices outside the most recent model fail the policy. A failed call
keeps the previous logits, like its recurrent state. BASIC owns masks and
sampling for auxiliary heads, as it does for the action heads:

```basic
nnStep()
if nn_aux_count() > 0 and abilityPoints() > 0 then
  levelAbility(nn_aux_argmax(2))
end if
```

Auxiliary heads cost A times H multiply-adds per call; three heads of 10, 23 and
4 logits at width 512 add 18,944 to the 1,553,920 of the tournament model (1.2%).
They also reserve 48 bytes of scratch and 8 bytes of retained cache per logit.
The converter accepts version 2 models with the same five action heads and emits
the same BASIC glue as for version 1.

`neural/policies/david.bas` builds observations, calls the native network and
interprets the five action heads. BASIC owns static target masks, seeded
sampling, argmax with first-index ties and ordinary action dispatch. Observation
distances use the ordinary `sqrt()` host function; sampling uses `exp()`. There
are no network layers, neural weights or exponential lookup tables in BASIC.
Nonnegative int32 counters are normalized before converting to Q16.16. Layout:

| Range | Contents |
| --- | --- |
| 0..47 | Self |
| 48..111 | Four abilities, 16 values each |
| 112..261 | Six inventory slots, 25 values each |
| 262..1261 | 25 object slots, 40 values each |
| 1262..1293 | Four warnings, eight values each |
| 1294..1309 | Match summary |
| 1310..1390 | Team-oriented 9 by 9 terrain sample |
| 1391..1406 | 16 goal weights |

Object slots are self, four allies, five enemies, seven creeps, four structures
and four neutrals. Visibility-filtered objects determine enemy features. Allied
roster IDs are public even when dead. Objects are ordered by the documented BASIC
distance and ID comparisons. Warning selection uses impact tick then distance.
The five action heads select verb, target, point, ability and inventory slot.
Masks and decoding are BASIC code and can be customized.

The supplied sampler uses a wrapping int32 LCG seeded by the match seed and hero
ID, with a 15-bit draw. It is deterministic but differs from the reference host's
SplitMix64 sampler. Q16.16 observations, logits and sampling probabilities also
affect decisions. Supporting this architecture does **not** imply identical
FP32-host trajectories. Native recurrent inference is compared separately using
identical Q16.16-rounded inputs. Recordings replay the dispatched actions without
rerunning neural inference.

Convert the legacy package by translating its cadence, goal and decoder settings
into BASIC, preserving the original BASIC draft/shop logic and unchanged model:

```sh
python3 examples/gods_of_the_arena/tools/convert_david.py \
  private-legacy.zip private-policy.zip
```

The converter supports argmax or sampling with static or disabled masks,
temperature 0.01 through 10, and decision periods 1 through 32,767. It validates
legacy file digests and contracts. Conditional masking, deferred scripts and
unrecognized glue require an explicit manual conversion. There is no automatic
`gota_act()` execution path in the game.

## Andre

`andre_nn("weights.bin", state, data)` implements the PufferNet encoder,
stacked MinGRU, highway and decoder used by
[Andre's evaluator](https://github.com/treeform/andre_von_puffer/blob/51a0d652c1bfb048bc5448261c32ac50d2db0fbf/tools/puffernet.nim)
and [GOTA trainer](https://github.com/treeform/andre_von_puffer/tree/51a0d652c1bfb048bc5448261c32ac50d2db0fbf/games/gota/train).
Those reference links require access to the private repository. The runner
receives 45 Q16.16 values and returns 12 Q16.16 values:

| Range | Contents |
| --- | --- |
| Inputs 0..39 | Hero BASIC features, clamped to -100..100 and divided by 100 |
| Inputs 40..44 | One-hot player seat within the team |
| Outputs 0..10 | Eleven macroaction logits |
| Output 11 | Value estimate, excluded from action selection |

Macroactions are mid push, retreat to spawn, defend own god, push enemy god,
side A, side B, regroup, hunt a hero, siege, hold and fight, and farm creeps.
The original hero BASIC still constructs all 40 features, drafts, shops, casts
spells and interprets these actions. The public example uses simple synthetic
features and weights; it is not a copy of the private trained policy.

The loader accepts raw little-endian FP32 checkpoints when the shape is
unambiguous, or an eight-byte `ANDRENN1` header followed by uint32 hidden width
and layer count, then the unchanged checkpoint bytes. Widths are multiples of
four from 4 through 4,096, with 1 through 16 layers and at most four million
parameters. All weights must be finite. There are no biases. With `H` hidden
values and `L` layers, tensor order and dimensions are:

1. Encoder: `H * 45` floats.
2. Decoder: `12 * H` floats, including the value row.
3. Recurrent projections: `L` tensors of `3 * H * H` floats.

Round the cursor up to eight floats after each tensor. The existing PufferNet
evaluator accepts up to seven missing final floats and supplies zeros. This
loader preserves that convention, including the reviewed width-12, one-layer
checkpoint with 1,116 stored floats and 1,120 aligned floats. Ambiguous raw
shapes need the explicit header. This is compatibility with the working CPU
evaluator, not a claim of identical GPU trainer arithmetic.

Each layer computes `next = old + sigmoid(gate) * (candidate - old)` and its
highway blend in ordered FP32 arithmetic without fused multiply/add. Its state
is `H * L` little-endian FP32 values in layer order. The loader and runner reject
invalid shapes, nonfinite state and unrepresentable outputs. The value estimate
uses the same unscaled Q16.16 conversion as the logits.

Convert a private hero policy and checkpoint with:

```sh
python3 examples/gods_of_the_arena/tools/convert_andre.py \
  private-hero.bas private-weights.bin tmp/andre.zip
```

Use `--hidden` and `--layers` when the checkpoint length is ambiguous.
`--action-ticks` defaults to 24; `--temperature` defaults to 1 and accepts zero
for first-index argmax or 0.01 through 10 for sampling. The converter recognizes
the 40-feature integer BASIC policy and its single `METTA_DECISION` marker. It
adds the shape header without modifying any checkpoint payload bytes.

The reusable `neural/policies/andre.bas` helpers preserve the evaluator's timing:
the network advances before the hero script, using the most recently captured
features. Initial features are zero except for the seat one-hot. The marker
captures new features and reads the held action. Inference continues on cadence
through death and stun with stale features; recurrent state resets at the next
match, not on death. No game-specific automatic neural execution path is added.

As with David, Q16.16 observations/logits and the BASIC LCG sampler can change
decisions relative to FP32 and SplitMix64 sampling. BASIC calls the ordinary
`exp()` host function to calculate action chances from the returned logits.
Native inference is checked separately against PufferNet
with identical rounded inputs. The training speedups in PR #75 are not required
by this deployment interface.

## Fly

`fly_nn("fly.bin", state, data)` runs a connectome-constrained rate network:
a fixed sparse wiring diagram, such as a cut of the FlyWire fruit fly
connectome, with trained connection strengths, input projection and readout.
It uses the same 45 inputs and 12 outputs as Andre, so a fly model can replace
an Andre model behind the same hero BASIC. `neural/policies/fly.bas` shows how
to run it: the Andre helpers with `fly` names, calling
`fly_nn("fly.bin", flyState, flyData)` every 24 ticks and choosing the action
from the returned logits. Package it with `fly.bin` next to the `.bas` file.

Each call adds a fixed drive to the recurrent potentials, then runs `steps`
updates. Every update computes all rates first, `rate = tanh(max(x, 0))`
written as `1 - 2 / (exp(2x) + 1)`, then for each neuron
`x += leak * (sum(weight * rate[source]) + bias + drive - x)`. The drive is
`bias` plus, for driven neurons, a dot product of the 45 inputs. Outputs are
`readout * rate[read neurons] + readoutBias`. All sums run in stored order in
FP32 without fused multiply/add. State is one FP32 potential per neuron.

The binary format is little-endian:

1. Magic `FLYNN1\0\0`.
2. uint32 neurons, edges, inputs (45), driven, read, steps; FP32 leak.
3. uint32 `offsets[neurons + 1]`: edges grouped by target neuron.
4. uint32 `sources[edges]`, then FP32 `weights[edges]`.
5. FP32 `bias[neurons]`.
6. uint32 `driveNeurons[driven]`, FP32 `drive[driven * 45]`, row per neuron.
7. uint32 `readNeurons[read]`, FP32 `readout[12 * read]`, row per output.
8. FP32 `readoutBias[12]`.

The loader accepts up to 200,000 neurons, 1.5 million edges and 16 steps, a
leak in (0, 1], ordered offsets, in-range neuron indices, finite values and an
exact byte length. At the limit the file is about 12 MB, and the package bytes
plus the parsed copy stay inside the 32 MiB native allowance. The FlyWire v783
brain without vision, keeping connections of at least five synapses, is 40,619
neurons and 1.06 million edges: a 9.2 MB file.

## Ordinary observation getters

These functions are available to every BASIC policy. Unknown fields or invalid
indices return zero. Object and spell indices use the existing visibility-filtered
snapshot. World positions, ranges and velocities below use world tiles, with
velocities measured per simulation tick. Numeric boolean getters return BASIC
true (-1) or false (0); `matchInfo` is an integer getter returning 1 or 0.

| Function | Fields |
| --- | --- |
| `selfInfo(field)` | 0 x, 1 z, 2 level XP, 3 XP needed, 4 total XP, 5 has move target, 6 class role, 7 in own spawn, 8 can shop, 9 ability points, 10 Emmett's Glory (zero until a win), 11 kills, 12 assists, 13 velocity x, 14 velocity z, 15 attack range, 16 move speed, 17 enemy fort center x, 18 enemy fort center z |
| `objectInfo(index, field)` | 0 x, 1 z, 2 max HP, 3 alive, 4 facing x, 5 facing z, 6 velocity x, 7 velocity z |
| `abilityInfo(slot, field)` | 0 range, 1 casting enum, 2 radius, 3 kind enum (Strike 0, Heal 1, Restore 2) |
| `spellInfo(index, field)` | 0 x, 1 z, 2 hostile, 3 non-Strike |
| `matchInfo(field)` | 0 battle tick, 1 configured max ticks, 2 seed int32 bits, 3 wave countdown, 4 wave interval, 5 half map size, 6 map size, 7 game over, 8/9 own towers alive/total, 10/11 own barracks alive/total, 12/13 remembered enemy towers alive/total, 14/15 remembered enemy barracks alive/total |
| `floor(value)` | Greatest integer not exceeding an integer or Q16.16 value |
| `sqrt(value)` | Fixxy square root rounded down to Q16.16; negative input returns zero |
| `exp(value)` | Native exponential rounded to Q16.16, ties away from zero; an unrepresentable result raises `BasicError` |

The enemy fort center and roster IDs are public static information. Enemy HP and
living structure counts retain normal visibility and team-memory rules.
The math functions are available to ordinary policies as well. `sqrt` and `exp`
accept Q16.16 values or integers within that range and each cost one work unit.

## Adding an architecture

1. Submit an approved Nim patch under `examples/gods_of_the_arena/neural/`.
   Use a flat model object, an explicit byte parser and free inference procedures.
2. Keep package loading in `src/polyworld/policies.nim`. Resolve resources through
   `NeuralContext.modelBytes`; never open arbitrary paths inside a runner.
3. Bind a per-VM cache callback in `bots.nim` and register the named function
   through `common.nim` with cost one. Individual bytecodes are unnecessary.
4. Validate input shape and state binding, reserve model/scratch storage, run
   inference without world access, and use the checked output/commit helpers.
5. Document binary layout, inputs, outputs, scaling, recurrent state and resets.
6. Add synthetic fixtures, malformed-model and atomicity tests, and an inference
   benchmark. Keep private policies and trained weights out of the patch.

## Validation

Run `nim check tests/tests.nim`, `nim r tests/tests.nim`, and
`nim r tests/bench_gota_neural.nim`. Converter fixtures run with
`python tests/test_neural_converters.py`. Coworld integration tests are in
`coworld/tools/test_runtime.nim` and require the native game binaries in
`tmp/coworld/`. For local development with an uninstalled companion Bassy checkout,
set `BASSY_PATH=/absolute/path/to/bassy/src`.

Tests cover raw and extensionless ZIP policies, mixed rosters, downstream BASIC
source limits, malformed packages/models, arrays and blobs, native memory churn,
input/output conversion, failed-call atomicity, visibility, BASIC cadence, masks, sampling and
resets. Private reference comparisons are separate from the published fixtures.
Native benchmark results depend on the machine and compiler: on the development
machine David's 1407/512/92 synthetic model took approximately 1.2 ms per step
(auxiliary heads of 10, 23 and 4 logits added about 1.5%);
each small Richard network was below one microsecond. Andre's width-12,
one-layer model took about one microsecond; width 64 with three layers took
approximately 25 microseconds. A fly model the size of the FlyWire cut
(40,619 neurons, 1.06 million edges, four steps) took about 5 ms per call.
