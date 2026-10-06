# BASIC-defined neural architectures

GotA policies can describe their forward pass in BASIC using packed tensors.
Weights, intermediate results and recurrent state remain inside each player's VM.
The existing Richard, David, Andre and Fly runners still work.

BASIC scalar arithmetic remains integer and deterministic Q16.16. Float32 is
available only inside tensor operations, including one-element scalar tensors.
Neither this API nor the named runners automatically issues game actions.
The policy chooses when to run inference, sample outputs and issue commands.

## Package layout

A ZIP contains exactly one BASIC entry, `tensors.json` and binary resources.
Resource paths are relative to the ZIP root. For example:

```json
{"tensors":[
  {"name":"encoder", "dtype":"float32", "shape":[64,45],
   "resource":"weights.bin", "offset":0}
]}
```

Each entry names a dtype (`int32`, `fixed` or `float32`), shape, resource and byte
offset. All elements are four-byte little-endian words. Fixed values store raw
Q16.16 bits. Float32 uses IEEE-754 binary32. Matrices are row-major. Shapes have
one to eight nonnegative dimensions, at most 4,194,304 elements. Empty sparse
arrays are allowed. Loaded tensors are immutable. Copy them into mutable scratch
tensors when necessary. Names must be unique, and nonfinite weights are rejected.

```basic
dim shape(0)
dim observations(44)
if initialized = 0 then
  encoder = tensorLoad("encoder")
  shape(0) = 45
  input = tensorCreate("float32", shape)
  shape(0) = tensorDim(encoder, 0)
  hidden = tensorCreate("float32", shape)
  initialized = 1
end if
tensorImport(input, observations)
tensorDense(input, encoder, 0, hidden)
tensorRelu(hidden, hidden)
```

Keep handles in BASIC globals or DIM arrays while they are needed. Unreferenced
buffers are collected between native calls. Restarting a decision retains state;
resetting a VM invalidates its old handles. Handles cannot cross player VMs.

## Operations

Computational operations take reusable destinations and return that destination.
All shapes, dtypes and indices are checked before publishing a result. A failed
operation leaves its destination unchanged. Exact in-place elementwise operations
are supported. Dense and CSR outputs cannot alias their inputs. Slices copy data;
there are no pointer views visible to BASIC. Binary arithmetic requires matching
shapes, except that either operand may be a one-element scalar of the same dtype.

| Function | Behavior |
| --- | --- |
| `tensorLoad(name$)` | Loads a named immutable tensor from the policy ZIP. |
| `tensorCreate(dtype$, shape)` | Creates zero-filled mutable storage using a BASIC shape array. |
| `tensorScalar(dtype$, decimal$)` | Creates a one-element tensor without quantizing float32 constants through BASIC. |
| `tensorSize(t)`, `tensorDim(t, axis)` | Returns element count or a zero-based dimension. |
| `tensorDtype(t)` | Returns int32=0, fixed=1, float32=2. |
| `tensorImport(dst, array)` | Converts an exact-length BASIC numeric array into the destination dtype. |
| `tensorExport(t)` | Returns a BASIC numeric array, converting float32 to Q16.16. |
| `tensorCopy(src, dst)` | Copies equal counts without converting dtype. |
| `tensorConvert(src, dst)` | Explicitly converts equal element counts. Integer conversion requires integral values in range. |
| `tensorReinterpret(src, dst)` | Preserves raw bits, for formats such as Richard's integer logits. |
| `tensorFill(dst, scalar)` | Fills mutable storage with a same-dtype scalar tensor. |
| `tensorDense(input, weights, bias, dst)` | Ordered matrix-vector multiplication, starting each sum with bias. Pass integer `0` for no bias. |
| `tensorCsr(input, offsets, sources, weights, dst)` | Ordered target-row CSR multiplication with int32 index tensors. |
| `tensorAdd(a,b,dst)`, `tensorSubtract(a,b,dst)` | Elementwise arithmetic with scalar broadcasting. |
| `tensorMultiply(a,b,dst)`, `tensorDivide(a,b,dst)` | Elementwise arithmetic with scalar broadcasting. Division by zero fails. |
| `tensorRelu(src,dst)`, `tensorAbs(src,dst)` | ReLU or absolute value. |
| `tensorExp(src,dst)`, `tensorTanh(src,dst)` | Exponential or hyperbolic tangent, for fixed and float32 tensors. |
| `tensorSigmoid(src,dst)` | Stable sigmoid using branches on the input sign. |
| `tensorSigmoidDirect(src,dst)` | Direct sigmoid `1/(1+exp(-x))`, preserving existing FP32 evaluator order. |
| `tensorCompare(a,b,operation$,dst)` | int32 mask using `lt`, `le`, `eq`, `ne`, `ge` or `gt`. |
| `tensorSelect(mask,a,b,dst)` | Selects `a` where the int32 mask is nonzero, otherwise `b`. |
| `tensorLerp(a,b,weight,dst)` | Stable interpolation with a branch at `abs(weight) < 0.5`. |
| `tensorSlice(src,start,count,dst)` | Copies a flat range into an exact-length vector. |
| `tensorCopySlice(src,start,dst,offset,count)` | Copies a flat range and preserves other destination values. |
| `tensorReshape(src,shape,dst)` | Copies equal counts into a destination with the declared shape. |
| `tensorGather(src,indices,dst)` | Gathers a vector using int32 indices. |
| `tensorScatterAdd(src,indices,dst)` | Adds into the existing destination, preserving order for repeated indices. |
| `tensorArgmax(t)`, `tensorArgmaxMasked(t,mask)` | Returns the first greatest index; returns -1 when empty or fully masked. |

Float32 operations preserve intermediate precision and ordered products/sums,
with fused multiply-add disabled in the kernels. Nonfinite results fail before
commit. Cross-platform bitwise identity is not promised. Output conversion rounds
ties away from zero and rejects values outside Q16.16.

Integer arithmetic wraps at 32 bits. Fixed multiplication and division follow
Fixxy's rules, including its negative rounding behavior. Fixed nonlinear functions
use integer range reduction and twelve Taylor terms, with sigmoid/tanh derived
from a stable exponential. Fixed exp accepts -12..10, underflows below -12 and
rejects larger inputs. Sigmoid clamps its magnitude to 12; tanh saturates beyond
+/-6. On the tested -5..5 eighth-step range, maximum errors were 0.000008
for exp, 0.000022 for sigmoid and 0.000043 for tanh. These are approximations.

## Resource limits

GotA retains its 32 MiB native memory allowance. Package storage, parsed manifest,
packed tensors and transactional scratch space are accounted for. The VM permits
256 native buffers independently of its 32 ordinary BASIC arrays. Tensor operations
charge one additional work unit per 256 scalar operations before executing.
Nonlinear functions charge 32 scalar operations per element. This supplements the
ordinary host-call and BASIC instruction charges. Size validation remains enabled
in release builds; proven bounded packed reads do not repeat integer overflow
checks in every multiply.

The reference David 1407/512/92 network consumes about 12,551 work units per step.
The 40,619-neuron, 1.06-million-edge, four-step Fly benchmark consumes about 80,249.
Both fit GotA's 250,000-work-unit decision budget, including initial loading.

## Converting current policies

The three existing converters accept `--tensors`. Their default output remains a
named-runner ZIP. To convert an existing Richard, David, Andre or Fly runner ZIP:

```sh
python examples/gods_of_the_arena/tools/tensor_packages.py input.zip output.zip
```

This retains observations, inference cadence, reset behavior, sampling and action
code. The forward passes live in `examples/gods_of_the_arena/neural/tensors/`:
Richard is affine/ReLU/affine; David and Andre compose recurrent gates and highway
mixtures; Fly composes sparse updates, gather and readout. No native MinGRU,
PufferNet or Fly-specific operator is required for these tensor implementations.
New architectures using this operator set need only a different BASIC policy and
ZIP tensors. Convolution, attention and training are outside this operator set.

Synthetic runnable packages are `neural/examples/tensor-{author}.zip`. For example:

```sh
nim r examples/gods_of_the_arena/gota.nim \
  --bot examples/gods_of_the_arena/neural/examples/tensor-fly.zip:10
```

## Validation

`tests/test_tensors.nim` compares mixed-sign weights, recurrent steps and resets,
checks package failures and sandbox limits, and reports floating differences.
Integer and fixed Richard outputs match exactly. Andre and Fly states matched
exactly in the reference fixtures. David's largest measured state difference was
5.96e-8, with at most one raw Q16.16 output unit of difference. Differences are
reported and bounded, not replaced with updated reference outputs.

`tests/test_tensor_matches.nim` runs ten-player matches for all four public
synthetic policies, compares every action and simulation hash against the named
runners, and verifies recorded replay playback. Replays retain recorded commands;
playback does not rerun inference or suppress mismatches.

Run `tests/bench_tensors.nim` for load, memory, work and warmed inference timings.
Performance depends on architecture: bulk dense kernels can improve throughput,
while small models pay additional host-call overhead. The specialized runners
remain available when that overhead matters.

### Example native timings

Apple Silicon release build with compiled BASIC, October 5, 2026. These are
synthetic model inference timings, separate from loading and observation code.
Small runner timings include enough iterations to measure microsecond costs.

| Network | Named runner | BASIC tensors | Tensor/native |
| --- | ---: | ---: | ---: |
| Richard integer 25/16/18 | 0.32 us | 2.23 us | 6.9x |
| Richard fixed 31/8/19 | 0.36 us | 2.72 us | 7.6x |
| David 1407/512/92 | 974 us | 687 us | 0.71x |
| Andre 45/12/12, one layer | 0.99 us | 12.28 us | 12.4x |
| Andre 45/64/12, three layers | 23.83 us | 52.90 us | 2.2x |
| Fly 40,619 neurons, four steps | 7.41 ms | 11.49 ms | 1.55x |

All reference models stayed within the existing work and memory budgets. Loading
plus BASIC compilation took 0.15..0.46 ms for the small models, 4.22 ms for David
and 17.53 ms for Fly. The ten-player, 2,400-battle-tick synthetic matches had
identical command sequences and simulation hashes for every author. Whole replay
file hashes differ because policy source and names are part of the replay header.
