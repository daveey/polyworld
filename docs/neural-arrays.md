# BASIC data and native array arithmetic

Polyworld policies can define their own networks in an ordinary `.bas` file.
`DATA` stores read-only numeric arrays, `DIM` reserves mutable arrays, and
native functions perform the expensive loops. There is no model manifest or
fixed neural architecture. ZIP packages and external weight files are deferred.

```basic
DATA encoder AS int32 = _
  2, -1, 3, _
  4,  0, 1
DATA bias = 5, -2

DIM features(2)
DIM hidden(1)
features(0) = 10
features(1) = 20
features(2) = 30

linear(features, encoder, bias, hidden, 3, 2)
relu(hidden, 2)
choice = argmax(hidden, 2)
```

This computes two rows, each with three inputs. `DIM features(2)` has three
elements because BASIC bounds are inclusive. Counts passed to native functions
are lengths, not upper bounds. Operations can use a prefix of a larger array.

## Data declarations

`DATA name = value, ...` accepts numeric literals and optional `+` or `-` signs.
An underscore at the end of a line continues the declaration. Declarations
must be at the top level. A DATA array must contain at least one element.

Without `AS`, integer literals remain signed int32 and decimal literals use
Bassy's deterministic Q16.16 fixed-point representation. `AS int32` requires
exact integers; `AS fixed32` converts every literal to Q16.16. Here `fixed32`
means a signed 32-bit fixed-point value with 16 fractional bits. Numeric
execution uses only int32 and Q16.16. Decimal literals are parsed directly into
fixed-point values, and the language has no floating-point type or conversion
API. The native neural operations preserve ordinary BASIC's int32 wraparound
and fixed-point rounding.

`weights(0)` reads an element. A bare `weights`, or `weights()`, supplies a
program-local array handle to a host function. Handles are checked against the
current VM; they never refer to host files, pointers, or another player's data.
String arrays cannot be passed to numeric operations.

DATA values initialize when the VM is created and are restored by `reset`.
Per-decision `restart` retains them along with ordinary arrays and globals.
Writes to DATA fail in BASIC and through native destination arguments.

## Operations and charging

| Function | Meaning | Native operations charged |
| --- | --- | --- |
| `linear(x, weights, bias, output, inputs, outputs)` | Bias plus the ordered dot product for each row | `2 * inputs * outputs + 2 * outputs` |
| `relu(values, count)` | Replace negatives with zero in place | `2 * count` |
| `argmax(values, count)` | Index of the greatest value; first index wins ties | `count` |
| `argmaxMasked(values, mask, count)` | Greatest eligible value, or `-1` when every mask entry is zero | `2 * count` |
| `dataAdd(left, right, output, count)` | Elementwise sum | `count` |
| `dataMultiply(left, right, output, count)` | Elementwise product | `count` |
| `dataCopy(source, output, count)` | Copy a numeric prefix | `count` |
| `dataFill(output, value, count)` | Fill a numeric prefix | `count` |
| `dataDot(left, right, count)` | Ordered dot product starting at zero | `2 * count` |

Each call also pays the existing VM instruction and host-entry work charges.
Native costs are deducted from **both** remaining instructions and work units,
once before the kernel executes. Size calculations use checked bounds and
int64 arithmetic. Invalid dimensions, too-short arrays, read-only destinations,
or an insufficient budget raise `BasicError` before any kernel output changes.
A later error elsewhere in BASIC does not roll back earlier completed calls.
The counts are deterministic work units, not elapsed CPU time.

Weights are row-major: `weights(row * inputs + column)`. `linear` starts with
the bias and adds products from left to right. It does not fuse, reorder,
parallelize, or convert arithmetic to floats. Its output must be a separate
array from its inputs, weights, and biases. Elementwise operations support
in-place use of the same array.

Arrays allocate when the runtime is constructed. Native kernels allocate no
tensor buffers or scratch arrays. DATA shares the existing array count and
element limits; its stored initializer and live VM copy both count toward the
logical memory allowance. Cells use Bassy's tagged numeric representation,
budgeted at 16 bytes per cell, rather than packed four-byte weight storage.
Source bytes and compiled instruction counts retain their separate limits.

GotA's existing limits remain 64 KiB of source, 32 arrays, 4,096 total array
elements, 2 MiB of logical runtime memory, 20,000 instructions and 50,000 work
units per decision.

## Implementation and dependency

Bassy implements DATA parsing, initialization, checked array views, and
`ContextHostProc` callbacks. Polyworld's `src/polyworld/neural.nim` implements
the arithmetic and registers it in all five BASIC game hosts. Game observations
and commands keep their existing APIs.

The required Bassy revision is pinned in both `nimby.lock` and
`coworld/dependencies.lock`. Install the locked dependencies before building.
For development against a sibling Bassy checkout, the optional `BASSY_PATH`
override selects its source directory:

```sh
export BASSY_PATH=../bassy-nn/src
nim check tests/tests.nim
nim r tests/tests.nim
```

The examples and test fixtures use hand-written synthetic values.
