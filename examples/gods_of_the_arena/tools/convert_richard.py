"""Convert Richard's inline combat and optional residual MLP into a ZIP.

Only the affine/ReLU blocks are replaced. Selection, masks, observations,
drafting and actions remain in BASIC. No policy or weights are distributed.
"""
import argparse
from decimal import Decimal
from pathlib import Path
import re
import struct
import zipfile


def word(literal, fixed):
    """Encode an exact integer or Q16.16 BASIC coefficient."""
    value = Decimal(literal) * (65536 if fixed else 1)
    if value != int(value) or not -(2**31) <= value < 2**31:
        raise ValueError(f"Coefficient is not exactly representable: {literal}")
    return struct.pack("<i", int(value))


def layer(lines, variable, inputs, fixed, normalized=False):
    """Parse ordered affine terms, preserving omitted zero coefficients."""
    output = b""
    for expression in lines:
        bias, _, terms = expression.partition(" + ")
        output += word(bias, fixed)
        row = ["0"] * inputs
        pattern = (rf"{variable}\((\d+)\)" +
                   (r" / 100\.0" if normalized else "") +
                   r" \* \((-?[\d.]+)\)")
        previous = -1
        for term in terms.split(" + ") if terms else []:
            match = re.fullmatch(pattern, term)
            if not match:
                raise ValueError(f"Unsupported affine term: {term}")
            index = int(match[1])
            if not previous < index < inputs:
                raise ValueError("Affine terms must be ordered and unique")
            previous = index
            row[index] = match[2]
        output += b"".join(word(value, fixed) for value in row)
    return output


def convert(source):
    """Extract only recognized MLP shapes and keep their selection code."""
    resources = {}
    for fixed, inputs, hidden, outputs, score, filename in [
        (False, 25, 16, 18, "score", "combat.bin"),
        (True, 31, 8, 19, "residualScore", "residual.bin"),
    ]:
        number = r"-?[\d.]+" if fixed else r"-?\d+"
        rows = list(re.finditer(rf"^h\((\d+)\) = ({number}.*)$", source, re.M))
        rows = [m for m in rows if (" / 100.0 " in m[2]) == fixed]
        if not rows and fixed:
            continue
        if [int(m[1]) for m in rows] != list(range(hidden)):
            raise ValueError("Unrecognized Richard hidden layer")
        decoder = list(re.finditer(rf"^{score} = ({number}.*)$", source, re.M))
        if len(decoder) != outputs:
            raise ValueError("Unrecognized Richard output layer")
        zero = "0.0" if fixed else "0"
        expected = "".join(
            f"h({i}) = {match[2]}\nif h({i}) < {zero} then\n"
            f"  h({i}) = {zero}\nend if\n"
            for i, match in enumerate(rows)
        )
        start = rows[0].start()
        if source[start:start + len(expected)] != expected:
            raise ValueError("Unrecognized Richard affine/ReLU block")
        resources[filename] = (b"RICHNN01" + struct.pack("<I", int(fixed)) +
            layer([m[2] for m in rows], "f", inputs, fixed, fixed) +
            layer([m[1] for m in decoder], "h", hidden, fixed))
        for i, match in reversed(list(enumerate(decoder))):
            source = source[:match.start()] + f"{score} = nnScores({i})" + source[match.end():]
        start = rows[0].start()
        last = rows[-1]
        end = source.index("end if\n", last.end()) + len("end if\n")
        # Separate blobs enforce the model association even for stateless calls.
        state = "nnResidualState" if fixed else "nnCombatState"
        data = "nnResidualData" if fixed else "nnCombatData"
        call = (f"for nnIndex = 0 to {inputs - 1}\n"
                f"  {data}(nnIndex) = f(nnIndex)\nnext nnIndex\n")
        call += f'nnScores = nn_richard("{filename}", {state}, {data})\n'
        source = source[:start] + call + source[end:]
    source = source.replace("bestScore = -2147483647", "bestScore = -32767.9999847412109375")
    header = """dim nnCombatData(24)
dim nnResidualData(30)
if nnInitialized = 0 then
  nnCombatState = blobCreate()
  nnResidualState = blobCreate()
  nnInitialized = 1
end if
"""
    return header + source, resources


def main():
    """Write one BASIC file and architecture-owned binaries to a ZIP."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--tensors", action="store_true",
                        help="Write a BASIC-defined packed tensor architecture")
    args = parser.parse_args()
    source, resources = convert(args.source.read_text())
    if args.tensors:
        from tensor_packages import tensorize
        source, resources = tensorize(source, resources)
    with zipfile.ZipFile(args.destination, "w", zipfile.ZIP_DEFLATED) as package:
        package.writestr("policy.bas", source)
        for name, data in resources.items():
            package.writestr(name, data)


if __name__ == "__main__":
    main()
