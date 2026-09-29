"""Convert a legacy GOTANET1 policy to explicit BASIC observations and actions."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zipfile

CONTRACTS = {
    "observation_contract": "ae4046e83cc02e861f9c8cc32550c6cc4d6f9c161c9225a9b34a314d310ea991",
    "action_contract": "ecc7d53c11a9db0912467c66ecb3e65b60b3e71ef14dad1442ba3b4f6ac14697",
}
GOALS = ["w_score", "w_win", "w_xp", "w_gold", "w_hero_kill", "w_assist",
         "w_death", "w_last_hit", "w_neutral_kill", "w_tower_damage",
         "w_structure_kill", "w_hero_damage", "w_damage_taken", "w_push_depth",
         "w_god_damage", "w_reserved"]


def convert(path):
    """Translate supported manifest settings and preserve the model bytes."""
    if path.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("Legacy package exceeds 16 MiB")
    with zipfile.ZipFile(path) as package:
        entries = package.infolist()
        names = [entry.filename for entry in entries]
        if (len(entries) > 256 or len(set(names)) != len(names) or
                sum(entry.file_size for entry in entries) > 16 * 1024 * 1024):
            raise ValueError("Legacy package exceeds entry or expanded limits")
        manifest = json.loads(package.read("manifest.json"))
        source = package.read("policy.bas").decode()
        model = package.read("model.bin")
    if manifest.get("schema") != "gota-neural-basic/1":
        raise ValueError("Expected a legacy gota-neural-basic/1 package")
    if manifest.get("defer_script", False):
        raise ValueError("Deferred legacy scripts need manual conversion")
    if model[:8] != b"GOTANET1" or len(model) < 180:
        raise ValueError("Expected GOTANET1 weights")
    version, inputs, width, outputs, heads, count = struct.unpack_from("<6I", model, 8)
    if (version, inputs, outputs, heads) != (1, 1407, 92, 5):
        raise ValueError("Expected the GOTA 1407-input, five-head contract")
    if (width not in (64, 128, 256, 384, 512) or
            count != width * (inputs + 3 * width + outputs) or
            len(model) != 180 + count * 4):
        raise ValueError("Unexpected model dimensions or byte length")
    if struct.unpack_from("<5I", model, 160) != (8, 25, 49, 4, 6):
        raise ValueError("Unexpected action head layout")
    for name, data in [("policy.bas", source.encode()), ("model.bin", model)]:
        if hashlib.sha256(data).hexdigest() != manifest["files"][name]:
            raise ValueError(f"Legacy digest mismatch: {name}")
    for name, start in [("observation_contract", 32), ("action_contract", 96)]:
        if (manifest[name] != CONTRACTS[name] or
                manifest[name] != model[start:start + 64].decode()):
            raise ValueError(f"Legacy {name} mismatch")
    decoder = manifest.get("decoder", {})
    if decoder.get("mode", "argmax") not in ("argmax", "sample"):
        raise ValueError("Unsupported decoder mode")
    mask = decoder.get("mask_empty_targets", False)
    if mask and decoder.get("mask_mode", "conditional") != "static":
        raise ValueError("This converter supports static or disabled masks")
    period = manifest.get("decision_period", 4)
    temperature = decoder.get("temperature", 1.0)
    if not isinstance(period, int) or not 1 <= period <= 32767:
        raise ValueError("Invalid decision period")
    if not isinstance(temperature, (float, int)) or not 0.01 <= temperature <= 10:
        raise ValueError("Invalid sampling temperature")
    library = (Path(__file__).parent.parent / "neural/policies/david.bas").read_text()
    library = library.split("' Example policy.")[0]
    library = library.replace("nnPeriod = 4", f"nnPeriod = {period}")
    library = library.replace("nnSampling = 1", f'nnSampling = {int(decoder.get("mode") == "sample")}')
    library = library.replace("nnMask = 1", f"nnMask = {int(mask)}")
    library = library.replace("nnTemperature = 1.0", f"nnTemperature = {float(temperature):.10f}")
    goal = manifest.get("goal", {"w_score": 1})
    if not isinstance(goal, dict) or any(key not in GOALS for key in goal):
        raise ValueError("Unsupported goal configuration")
    goal_lines = []
    for i, name in enumerate(GOALS):
        value = goal.get(name, 0)
        if not isinstance(value, (float, int)) or not -32768 <= value <= 32767:
            raise ValueError("Invalid goal weight")
        goal_lines.append(f"  nnGoals({i}) = {float(value):.10f}")
    library = library.replace("  nnGoals(0) = 1.0", "\n".join(goal_lines))
    if source.count("acted = gota_act()") != 1:
        raise ValueError("Expected one explicit legacy gota_act call")
    source = source.replace("acted = gota_act()", "nnStep()")
    reset = """nnInitialize()
if selfHp <= 0 then
  blobClear(nnState)
  nnNextTick = 0
end if
"""
    return library + reset + source, model


def main():
    """Write a single BASIC entry and the unchanged weights without a manifest."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    source, model = convert(args.source)
    with zipfile.ZipFile(args.destination, "w", zipfile.ZIP_DEFLATED) as package:
        package.writestr("policy.bas", source)
        package.writestr("model.bin", model)


if __name__ == "__main__":
    main()
