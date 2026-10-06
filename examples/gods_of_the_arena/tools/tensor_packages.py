"""Export named four-byte tensors and BASIC-defined forward passes."""
import argparse
import json
import math
from pathlib import Path
import re
import struct
import zipfile

LIBRARIES = Path(__file__).parent.parent / "neural/tensors"


def tensorize(source, resources):
    """Replace reviewed runner calls while preserving policy control flow."""
    entries = []
    payload = bytearray()
    libraries = []

    def add(name, dtype, shape, data):
        """Append one portable named tensor without duplicating resources."""
        count = math.prod(shape)
        if len(data) != 4 * count:
            raise ValueError(f"Tensor byte length mismatch: {name}")
        entries.append(dict(name=name, dtype=dtype, shape=shape,
                            resource="tensors.bin", offset=len(payload)))
        payload.extend(data)

    def extract(name, dtype, shape, model, offset):
        """Copy a row-major range from a validated author checkpoint."""
        count = math.prod(shape)
        add(name, dtype, shape, model[offset:offset + count * 4])
        return offset + count * 4

    for filename, model in resources.items():
        if model.startswith(b"RICHNN01"):
            kind, = struct.unpack_from("<I", model, 8)
            if kind not in (0, 1):
                raise ValueError("Unsupported Richard kind")
            inputs, hidden, outputs = (25, 16, 18) if kind == 0 else (31, 8, 19)
            dtype = "int32" if kind == 0 else "fixed"
            prefix = Path(filename).stem
            cursor = 12
            for layer, width, rows in [("encoder", inputs, hidden),
                                       ("decoder", hidden, outputs)]:
                bias = bytearray()
                weights = bytearray()
                for _ in range(rows):
                    bias.extend(model[cursor:cursor + 4])
                    cursor += 4
                    weights.extend(model[cursor:cursor + width * 4])
                    cursor += width * 4
                add(prefix + "." + layer, dtype, [rows, width], weights)
                add(prefix + "." + layer + "Bias", dtype, [rows], bias)
            if cursor != len(model):
                raise ValueError("Richard model byte length mismatch")
            # Each Richard network has independent globals and reusable scratch.
            tag = "tr" + re.sub(r"\W", "", prefix.title())
            lib = (LIBRARIES / "richard.bas").read_text()
            lib = re.sub(r"\btr(?=[A-Z])", tag, lib)
            lib = lib.replace("tensorRichard", "tensorRichard" + prefix.title())
            libraries.append(lib)
            pattern = (r'(\w+)\s*=\s*nn_richard\("' + re.escape(filename) +
                       r'",\s*(\w+),\s*(\w+)\)')
            def replacement(match):
                """Retain the original call's destination and input array."""
                return (f"if {tag}Ready = 0 then\n"
                        f'  {tag}Prefix$ = "{prefix}"\n'
                        f"  tensorRichard{prefix.title()}Initialize()\n"
                        f"  {tag}Ready = 1\nend if\n"
                        f"{tag}Data = {match[3]}\n"
                        f"tensorRichard{prefix.title()}Step()\n"
                        f"{match[1]} = {tag}Result")
            source, count = re.subn(pattern, replacement, source, flags=re.I)
            if count < 1:
                raise ValueError("No Richard runner call found")
        elif model.startswith(b"GOTANET1"):
            version, inputs, width, outputs, heads, count = struct.unpack_from("<6I", model, 8)
            if version != 1 or count != width * (inputs + 3 * width + outputs):
                raise ValueError("Invalid David layout")
            cursor = 160 + heads * 4
            for name, shape in [("encoder", [width, inputs]),
                                ("recurrent", [3 * width, width]),
                                ("decoder", [outputs, width])]:
                cursor = extract(name, "float32", shape, model, cursor)
            if cursor != len(model):
                raise ValueError("David model byte length mismatch")
            libraries.append((LIBRARIES / "david.bas").read_text())
            source = source.replace("nnState = blobCreate()", "tensorDavidInitialize()")
            source = source.replace("blobClear(nnState)", "tensorDavidReset()")
            source = source.replace('nnResult = nn_david("model.bin", nnState, nnData)',
                'tdData = nnData\n  tensorDavidStep()\n  nnResult = tdResult')
        elif model.startswith(b"ANDRENN1"):
            width, layers = struct.unpack_from("<2I", model, 8)
            align = lambda value: (value + 7) & ~7
            decoder = align(45 * width)
            recurrent = align(decoder + 12 * width)
            stride = align(3 * width * width)
            expected = recurrent + layers * stride
            if (len(model) - 16) // 4 > expected or expected - (len(model) - 16) // 4 > 7:
                raise ValueError("Andre model byte length mismatch")
            model += bytes((expected - (len(model) - 16) // 4) * 4)
            extract("encoder", "float32", [width, 45], model, 16)
            extract("decoder", "float32", [12, width], model, 16 + decoder * 4)
            for layer in range(layers):
                extract(f"recurrent.{layer}", "float32", [3 * width, width],
                        model, 16 + (recurrent + layer * stride) * 4)
            add("layers", "int32", [1], struct.pack("<i", layers))
            libraries.append((LIBRARIES / "andre.bas").read_text())
            source = source.replace("andreState = blobCreate()", "tensorAndreInitialize()")
            source = source.replace("blobClear(andreState)", "tensorAndreReset()")
            source = source.replace('andreResult = andre_nn("weights.bin", andreState, andreData)',
                'taData = andreData\n  tensorAndreStep()\n  andreResult = taResult')
        elif model.startswith(b"FLYNN1\0\0"):
            neurons, edges, inputs, driven, read, steps = struct.unpack_from("<6I", model, 8)
            cursor = 36
            for name, dtype, shape in [
                ("offsets", "int32", [neurons + 1]),
                ("sources", "int32", [edges]), ("weights", "float32", [edges]),
                ("bias", "float32", [neurons]),
                ("driveNeurons", "int32", [driven]),
                ("drive", "float32", [driven, inputs]),
                ("readNeurons", "int32", [read]),
                ("readout", "float32", [12, read]),
                ("readoutBias", "float32", [12]),
            ]:
                cursor = extract(name, dtype, shape, model, cursor)
            if cursor != len(model):
                raise ValueError("Fly model byte length mismatch")
            add("leak", "float32", [1], model[32:36])
            add("steps", "int32", [1], struct.pack("<i", steps))
            libraries.append((LIBRARIES / "fly.bas").read_text())
            source = source.replace("flyState = blobCreate()", "tensorFlyInitialize()")
            source = source.replace("blobClear(flyState)", "tensorFlyReset()")
            source = source.replace('flyResult = fly_nn("fly.bin", flyState, flyData)',
                'tfData = flyData\n  tensorFlyStep()\n  flyResult = tfResult')
        else:
            raise ValueError(f"Unknown neural resource: {filename}")
    if not entries or re.search(r'\b(nn_richard|nn_david|andre_nn|fly_nn)\s*\(', source):
        raise ValueError("Policy still contains a native runner call")
    # DIM declarations are unique even when two Richard networks are present.
    library = "\n".join(libraries)
    library = library.replace("dim tensorShape(0)\n", "")
    source = "dim tensorShape(0)\n" + library + "\n" + source
    if len(source.encode()) > 64 * 1024:
        raise ValueError("BASIC source with tensor architecture exceeds 64 KiB")
    return (source,
            {"tensors.json": json.dumps({"tensors": entries}, separators=(",", ":")),
             "tensors.bin": bytes(payload)})


def main():
    """Convert an existing runner ZIP without changing its policy settings."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    if args.source.stat().st_size > 16 * 1024 * 1024:
        parser.error("Policy exceeds 16 MiB")
    with zipfile.ZipFile(args.source) as package:
        entries = package.infolist()
        if len(entries) > 256 or sum(entry.file_size for entry in entries) > 32 * 1024 * 1024:
            parser.error("Package expanded limits exceeded")
        sources = [entry.filename for entry in entries if entry.filename.endswith(".bas")]
        if len(sources) != 1:
            parser.error("Package needs exactly one BASIC entry")
        source = package.read(sources[0]).decode()
        resources = {entry.filename: package.read(entry.filename)
                     for entry in entries if entry.filename not in sources}
    source, resources = tensorize(source, resources)
    with zipfile.ZipFile(args.destination, "w", zipfile.ZIP_DEFLATED) as package:
        package.writestr("policy.bas", source)
        for name, data in resources.items():
            package.writestr(name, data)


if __name__ == "__main__":
    main()
