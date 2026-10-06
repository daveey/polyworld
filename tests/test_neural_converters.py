"""Exercise public converters using generated coefficients and model bytes."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] /
                       "examples/gods_of_the_arena/tools"))
import convert_david
import convert_richard
import convert_andre
import tensor_packages


def rejected(call):
    """Require converters to reject unsupported or inconsistent input."""
    try:
        call()
    except ValueError:
        return True
    return False


def layer(hidden, outputs, fixed=False):
    """Generate ordered synthetic affine/ReLU blocks without trained weights."""
    zero = "0.0" if fixed else "0"
    coefficient = "0.5" if fixed else "2"
    normalized = " / 100.0" if fixed else ""
    result = ""
    for i in range(hidden):
        result += (f"h({i}) = {zero} + f(0){normalized} * ({coefficient})\n"
                   f"if h({i}) < {zero} then\n  h({i}) = {zero}\nend if\n")
    score = "residualScore" if fixed else "score"
    for i in range(outputs):
        result += f"{score} = {zero} + h(0) * ({coefficient})\n"
        result += f"if {score} > bestScore then\n  bestScore = {score}\nend if\n"
    return result


source = "bestScore = -2147483647\n" + layer(16, 18) + layer(8, 19, True)
converted, resources = convert_richard.convert(source)
richard_source = converted
assert converted.count("nn_richard(") == 2
assert "bestScore = -32767.9999847412109375" in converted
assert "nnCombatData(nnIndex) = f(nnIndex)" in converted
assert "nnResidualData(nnIndex) = f(nnIndex)" in converted
assert len(resources["combat.bin"]) == 12 + 4 * (26 * 16 + 17 * 18)
assert len(resources["residual.bin"]) == 12 + 4 * (32 * 8 + 9 * 19)
assert struct.unpack_from("<i", resources["combat.bin"], 16)[0] == 2
assert struct.unpack_from("<i", resources["residual.bin"], 16)[0] == 32768
assert rejected(lambda: convert_richard.convert(source.replace("h(0) < 0 then", "h(0) < 1 then", 1)))
assert rejected(lambda: convert_richard.convert(source.replace("f(0) * (2)", "f(0) * (2) + f(0) * (1)", 1)))
assert rejected(lambda: convert_richard.word("0.1", True))

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "legacy.zip"
    params = 64 * (1407 + 3 * 64 + 92)
    model = (b"GOTANET1" + struct.pack("<6I", 1, 1407, 64, 92, 5, params) +
             "".join(convert_david.CONTRACTS.values()).encode() +
             struct.pack("<5I", 8, 25, 49, 4, 6) + bytes(params * 4))
    basic = b"if selfHp <= 0 then\nend\nend if\nacted = gota_act()\n"
    manifest = {
        "schema": "gota-neural-basic/1",
        "files": {"policy.bas": hashlib.sha256(basic).hexdigest(),
                  "model.bin": hashlib.sha256(model).hexdigest()},
        **convert_david.CONTRACTS,
        "decision_period": 7,
        "goal": {"w_score": 0.5, "w_win": 1},
        "decoder": {"mode": "sample", "mask_empty_targets": True,
                    "mask_mode": "static", "temperature": 0.75},
    }

    def write_package():
        """Write the current synthetic legacy configuration."""
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("manifest.json", json.dumps(manifest))
            archive.writestr("policy.bas", basic)
            archive.writestr("model.bin", model)

    write_package()
    output, weights = convert_david.convert(path)
    assert weights == model
    assert "gota_act" not in output
    assert "nnPeriod = 7" in output and "nnTemperature = 0.7500000000" in output
    assert "nnGoals(0) = 0.5000000000" in output
    assert "nnGoals(1) = 1.0000000000" in output
    assert "blobClear(nnState)" in output
    manifest["decoder"]["mask_mode"] = "conditional"
    write_package()
    assert rejected(lambda: convert_david.convert(path))
    manifest["decoder"]["mask_mode"] = "static"
    manifest["defer_script"] = True
    write_package()
    assert rejected(lambda: convert_david.convert(path))
    manifest["defer_script"] = False
    manifest["files"]["model.bin"] = "bad"
    write_package()
    assert rejected(lambda: convert_david.convert(path))

source = "dim f(40)\nif selfHp <= 0 then\nend\nend if\n' METTA_DECISION\n"
weights = bytes(4 * (convert_andre.count_parameters(12, 1) - 4))
converted, model = convert_andre.convert(source, weights)
assert model[:16] == b"ANDRENN1" + struct.pack("<2I", 12, 1)
assert model[16:] == weights
assert "andreAdvance()\ndim f(40)" in converted
assert "andreCapture()\ndecision = andreAction" in converted
assert "blobClear" not in converted
assert "andrePeriod = 24" in converted
assert "andreTemperature = 1.0000000000" in converted
custom, _ = convert_andre.convert(source, weights, action_ticks=6, temperature=0)
assert "andrePeriod = 6" in custom and "andreTemperature = 0.0000000000" in custom
for hidden, layers in [(4, 1), (12, 3), (64, 3)]:
    values = bytes(4 * convert_andre.count_parameters(hidden, layers))
    assert convert_andre.model_bytes(values)[:16] == (
        b"ANDRENN1" + struct.pack("<2I", hidden, layers))
ambiguous = bytes(4 * convert_andre.count_parameters(12, 13))
assert rejected(lambda: convert_andre.model_bytes(ambiguous))
assert convert_andre.model_bytes(ambiguous, 12, 13)[16:] == ambiguous
for values in [b"", b"bad", weights[:-16], weights + struct.pack("<f", float("nan"))]:
    assert rejected(lambda: convert_andre.model_bytes(values))
for basic in ["end", source * 2, source + "andreState = 1\n",
              source.replace("f(40)", "f(39)"), source + "a = 1 / 2\n"]:
    assert rejected(lambda: convert_andre.convert(basic, weights))
for options in [{"hidden": 3}, {"layers": 0}, {"action_ticks": 0},
                {"action_ticks": 32768}, {"temperature": -1},
                {"temperature": 0.001}, {"temperature": float("inf")}]:
    assert rejected(lambda: convert_andre.convert(source, weights, **options))

print("Synthetic Richard, David and Andre converters passed")

# Tensor export retains policy decisions and extracts both Richard variants.
tensor_source, tensor_resources = tensor_packages.tensorize(richard_source, resources)
assert "nn_richard(" not in tensor_source
assert "tensorRichardCombatStep()" in tensor_source
assert "tensorRichardResidualStep()" in tensor_source
manifest = json.loads(tensor_resources["tensors.json"])
assert len(manifest["tensors"]) == 8
assert len({entry["name"] for entry in manifest["tensors"]}) == 8
for entry in manifest["tensors"]:
    assert entry["resource"] == "tensors.bin"
    assert entry["offset"] % 4 == 0
    assert entry["dtype"] in ("int32", "fixed")
assert tensor_source.count("dim tensorShape(0)") == 1
assert rejected(lambda: tensor_packages.tensorize("end", {"bad.bin": b"bad"}))
assert rejected(lambda: tensor_packages.tensorize("end", {}))
print("Packed tensor export and independent Richard networks passed")
