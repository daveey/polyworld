"""Package an Andre PufferNet checkpoint and a BASIC METTA_DECISION policy."""
import argparse
import math
from pathlib import Path
import re
import struct
import zipfile

MAGIC = b"ANDRENN1"
MAX_BYTES = 16 * 1024 * 1024


def count_parameters(hidden, layers):
    """Match the evaluator's eight-float alignment between tensors."""
    if hidden not in range(4, 4097, 4) or not 1 <= layers <= 16:
        raise ValueError("Expected width 4..4096, multiple of four, 1..16 layers")
    align = lambda value: (value + 7) & ~7
    decoder = align(45 * hidden)
    recurrent = align(decoder + 12 * hidden)
    return recurrent + layers * align(3 * hidden * hidden)


def model_bytes(weights, hidden=None, layers=None):
    """Add an unambiguous shape header without changing checkpoint payload."""
    if not weights or len(weights) % 4 or len(weights) > MAX_BYTES - 16:
        raise ValueError("Expected a bounded file of little-endian FP32 weights")
    count = len(weights) // 4
    widths = [hidden] if hidden is not None else range(4, 4097, 4)
    depths = [layers] if layers is not None else range(1, 17)
    shapes = [(width, depth) for width in widths for depth in depths
              if 0 <= count_parameters(width, depth) - count <= 7]
    if len(shapes) != 1:
        raise ValueError("Weight shape is missing or ambiguous; set --hidden and --layers")
    if any(not math.isfinite(value) for (value,) in struct.iter_unpack("<f", weights)):
        raise ValueError("Nonfinite PufferNet weight")
    return MAGIC + struct.pack("<2I", *shapes[0]) + weights


def convert(source, weights, hidden=None, layers=None, action_ticks=24,
            temperature=1.0):
    """Keep the integer hero policy and replace only its trainer bridge."""
    marker = "' METTA_DECISION"
    if source.count(marker) != 1:
        raise ValueError("Expected exactly one METTA_DECISION marker")
    if not re.search(r"(?im)^\s*dim f\(40\)\s*$", source):
        raise ValueError("Expected the 40-feature f() policy array")
    if re.search(r"\bandre\w*", source, re.I):
        raise ValueError("Policy already uses the reserved andre prefix")
    if not isinstance(action_ticks, int) or not 1 <= action_ticks <= 32767:
        raise ValueError("Action ticks must be 1..32767")
    if not math.isfinite(temperature) or not 0 <= temperature <= 10:
        raise ValueError("Temperature must be zero (argmax) or 0.01..10")
    if 0 < temperature < 0.01:
        raise ValueError("Positive temperature must be at least 0.01")
    # The source was trained with integer-only BASIC; retain that arithmetic.
    for line in source.splitlines():
        code = line.split("'", 1)[0]
        if "/" in code or re.search(r"\d+\.\d+", code):
            raise ValueError("Expected integer-only hero arithmetic")
    library = (Path(__file__).parent.parent / "neural/policies/andre.bas").read_text()
    library = library.split("' Example policy.")[0]
    library = library.replace("andrePeriod = 24", f"andrePeriod = {action_ticks}")
    library = library.replace("andreTemperature = 1.0",
                              f"andreTemperature = {temperature:.10f}")
    source = source.replace(marker, "andreCapture()\ndecision = andreAction")
    output = library + "andreAdvance()\n" + source
    if len(output.encode()) > 64 * 1024:
        raise ValueError("Converted BASIC exceeds GOTA's 64 KiB source limit")
    model = model_bytes(weights, hidden, layers)
    if len(model) + len(output.encode()) > MAX_BYTES:
        raise ValueError("Converted package exceeds 16 MiB expanded")
    return output, model


def main():
    """Write BASIC and model resources for the ordinary local or Coworld loader."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("weights", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--hidden", type=int)
    parser.add_argument("--layers", type=int)
    parser.add_argument("--action-ticks", type=int, default=24)
    parser.add_argument("--temperature", type=float, default=1.0)
    parser.add_argument("--tensors", action="store_true",
                        help="Write a BASIC-defined packed tensor architecture")
    args = parser.parse_args()
    if args.source.stat().st_size > 64 * 1024 or args.weights.stat().st_size > MAX_BYTES:
        parser.error("Input policy or model exceeds the package limits")
    source, model = convert(args.source.read_text(), args.weights.read_bytes(),
                            args.hidden, args.layers, args.action_ticks,
                            args.temperature)
    resources = {"weights.bin": model}
    if args.tensors:
        from tensor_packages import tensorize
        source, resources = tensorize(source, resources)
    with zipfile.ZipFile(args.destination, "w", zipfile.ZIP_DEFLATED) as package:
        package.writestr("policy.bas", source)
        for name, data in resources.items():
            package.writestr(name, data)


if __name__ == "__main__":
    main()
