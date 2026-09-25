"""Staging validator and builder for GotA neural packages (gota-neural-basic/1).

A package is a ZIP holding exactly manifest.json, policy.bas and model.bin. This module
mirrors examples/gods_of_the_arena/neural_package.nim rule for rule, so a submission the
staging step accepts is one the game accepts (and the reverse). Plain .bas submissions are not
packages and are untouched.

  python3 neural_package.py validate PACKAGE.zip [--obs-hash H --action-hash H]
  python3 neural_package.py build OUT.zip --policy policy.bas --model model.bin
      [--period 4] [--decoder argmax|sample --temperature T] [--goal-red 16 floats] [--goal-blue ...]
"""
import argparse, hashlib, io, json, math, struct, sys, zipfile

SCHEMA = "gota-neural-basic/1"
FILES = ("manifest.json", "policy.bas", "model.bin")
MAX_PACKAGE = 16 * 1024 * 1024
MAX_POLICY = 256 * 1024
HEADS = [8, 25, 49, 4, 6]
OBS_SIZE = 1407
WIDTHS = (64, 128, 256)
MAGIC = b"GOTANET1"
OP_BUDGET = 4_000_000
MAX_PARAMS = 2_000_000
# Contract v1 hashes (examples/gods_of_the_arena/neural_contract.nim; gota_*_contract_hash).
OBS_HASH = "ae4046e83cc02e861f9c8cc32550c6cc4d6f9c161c9225a9b34a314d310ea991"
ACTION_HASH = "ecc7d53c11a9db0912467c66ecb3e65b60b3e71ef14dad1442ba3b4f6ac14697"
TOP_KEYS = {"schema", "observation_contract", "action_contract", "decision_period", "files", "model", "goal", "decoder"}
REQUIRED = ("schema", "observation_contract", "action_contract", "decision_period", "files", "model")


class PackageError(ValueError):
    pass


def is_package(data: bytes) -> bool:
    return data[:4] == b"PK\x03\x04"


def _keys(node, allowed, where):
    if not isinstance(node, dict):
        raise PackageError(f"{where} must be an object")
    for key in node:
        if key not in allowed:
            raise PackageError(f"unknown manifest key {where}.{key}")


def _goal(node, where):
    if not isinstance(node, list) or len(node) != 16 or not all(
            isinstance(v, (int, float)) and not isinstance(v, bool) for v in node):
        raise PackageError(f"{where} must be 16 numbers")
    if any(v < -1 or v > 1 for v in node):
        raise PackageError(f"{where} values must be in [-1, 1]")
    if node[15] != 0:
        raise PackageError(f"{where} w_reserved must be 0")


def check_model(data: bytes, obs_hash=OBS_HASH, action_hash=ACTION_HASH):
    """Validates a GOTANET1 model.bin; returns (hidden, operations)."""
    if data[:8] != MAGIC:
        raise PackageError("invalid neural actor magic (want GOTANET1)")
    if len(data) < 32:
        raise PackageError("truncated neural actor")
    version, inputs, hidden, outputs, heads, params = struct.unpack_from("<6I", data, 8)
    if version != 1 or not 1 <= inputs <= 4096 or hidden not in WIDTHS or not 2 <= outputs <= 1024 or not 1 <= heads <= 32:
        raise PackageError("unsupported neural actor dimensions/version")
    expected = inputs * hidden + 3 * hidden * hidden + outputs * hidden
    if params != expected or expected > MAX_PARAMS or len(data) != 32 + 128 + 4 * heads + 4 * expected:
        raise PackageError("invalid neural actor length/parameter count")
    ohash, ahash = data[32:96].decode("ascii", "replace"), data[96:160].decode("ascii", "replace")
    for h in (ohash, ahash):
        if any(c not in "0123456789abcdef" for c in h):
            raise PackageError("invalid neural contract hash")
    sizes = list(struct.unpack_from(f"<{heads}I", data, 160))
    if any(not 2 <= s <= 1024 for s in sizes) or sum(sizes) != outputs:
        raise PackageError("head/output mismatch")
    weights = memoryview(data)[160 + 4 * heads:].cast("f")
    if not all(math.isfinite(w) for w in weights):
        raise PackageError("nonfinite neural weight")
    ops = 2 * expected + 32 * hidden
    if ops > OP_BUDGET:
        raise PackageError(f"neural actor needs {ops} operations per inference, over the {OP_BUDGET} budget")
    if ohash != obs_hash or ahash != action_hash:
        raise PackageError("model.bin contract hashes do not match the manifest")
    if inputs != OBS_SIZE or sizes != HEADS:
        raise PackageError("model inputs/heads do not match contract v1")
    return hidden, ops


def validate(data: bytes, obs_hash=OBS_HASH, action_hash=ACTION_HASH) -> dict:
    """Raises PackageError with the reason; returns the manifest on success."""
    if len(data) > MAX_PACKAGE:
        raise PackageError("package exceeds 16 MiB")
    try:
        z = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as e:
        raise PackageError(f"not a zip: {e}")
    infos = z.infolist()
    names = [i.filename for i in infos]
    if len(infos) != 3 or sorted(names) != sorted(FILES):
        raise PackageError("package must contain exactly manifest.json, policy.bas and model.bin")
    for i in infos:
        if i.flag_bits & 1:
            raise PackageError("encrypted zip entry")
        if i.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            raise PackageError(f"unsupported zip compression {i.compress_type}")
    files = {n: z.read(n) for n in FILES}
    try:
        m = json.loads(files["manifest.json"])
    except ValueError as e:
        raise PackageError(f"manifest.json is not JSON: {e}")
    _keys(m, TOP_KEYS, "manifest")
    for key in REQUIRED:
        if key not in m:
            raise PackageError(f"manifest is missing {key}")
    if m["schema"] != SCHEMA:
        raise PackageError(f"manifest schema must be {SCHEMA}")
    if m["observation_contract"] != obs_hash:
        raise PackageError("observation contract mismatch")
    if m["action_contract"] != action_hash:
        raise PackageError("action contract mismatch")
    p = m["decision_period"]
    if not isinstance(p, int) or isinstance(p, bool) or not 1 <= p <= 24:
        raise PackageError("decision_period must be an integer 1..24")
    _keys(m["files"], {"policy.bas", "model.bin"}, "files")
    if set(m["files"]) != {"policy.bas", "model.bin"}:
        raise PackageError("files must list policy.bas and model.bin")
    for n in ("policy.bas", "model.bin"):
        if m["files"][n] != hashlib.sha256(files[n]).hexdigest():
            raise PackageError(f"{n} sha256 mismatch")
    if len(files["policy.bas"]) > MAX_POLICY:
        raise PackageError("policy.bas exceeds 256 KiB")
    model = m["model"]
    _keys(model, {"format", "inputs", "hidden", "heads"}, "model")
    for key in ("format", "inputs", "hidden", "heads"):
        if key not in model:
            raise PackageError(f"model is missing {key}")
    if model["format"] != "GOTANET1":
        raise PackageError("model.format must be GOTANET1")
    hidden, _ = check_model(files["model.bin"], obs_hash, action_hash)
    if model["inputs"] != OBS_SIZE:
        raise PackageError(f"model.inputs must be {OBS_SIZE}")
    if model["hidden"] != hidden:
        raise PackageError("model.hidden does not match model.bin")
    if model["heads"] != HEADS:
        raise PackageError("model.heads must be [8,25,49,4,6]")
    if "goal" in m:
        _keys(m["goal"], {"red", "blue"}, "goal")
        if set(m["goal"]) != {"red", "blue"}:
            raise PackageError("goal needs red and blue")
        _goal(m["goal"]["red"], "goal.red")
        _goal(m["goal"]["blue"], "goal.blue")
    if "decoder" in m:
        d = m["decoder"]
        _keys(d, {"mode", "temperature"}, "decoder")
        mode = d.get("mode", "argmax")
        if mode == "argmax":
            if "temperature" in d:
                raise PackageError("decoder.temperature needs mode sample")
        elif mode == "sample":
            t = d.get("temperature", 1.0)
            if not isinstance(t, (int, float)) or not 0.01 <= t <= 10:
                raise PackageError("decoder.temperature must be 0.01..10")
        else:
            raise PackageError("decoder.mode must be argmax or sample")
    return m


def encode_model(weights, hidden, obs_hash=OBS_HASH, action_hash=ACTION_HASH, inputs=OBS_SIZE, heads=HEADS):
    """GOTANET1 bytes from a flat float32 list: W_enc[H][I], W_rec[3H][H], W_dec[O][H]."""
    outputs = sum(heads)
    expected = inputs * hidden + 3 * hidden * hidden + outputs * hidden
    assert len(weights) == expected
    return (MAGIC + struct.pack("<6I", 1, inputs, hidden, outputs, len(heads), expected) +
            obs_hash.encode() + action_hash.encode() + struct.pack(f"<{len(heads)}I", *heads) +
            struct.pack(f"<{expected}f", *weights))


def build(policy: bytes, model: bytes, period=4, decoder=None, goal=None) -> bytes:
    hidden = struct.unpack_from("<I", model, 16)[0]
    m = {"schema": SCHEMA, "observation_contract": OBS_HASH, "action_contract": ACTION_HASH,
         "decision_period": period,
         "files": {"policy.bas": hashlib.sha256(policy).hexdigest(), "model.bin": hashlib.sha256(model).hexdigest()},
         "model": {"format": "GOTANET1", "inputs": OBS_SIZE, "hidden": hidden, "heads": HEADS}}
    if goal:
        m["goal"] = goal
    if decoder:
        m["decoder"] = decoder
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps(m, indent=1))
        z.writestr("policy.bas", policy)
        z.writestr("model.bin", model)
    data = out.getvalue()
    validate(data)
    return data


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("validate")
    v.add_argument("package")
    v.add_argument("--obs-hash", default=OBS_HASH)
    v.add_argument("--action-hash", default=ACTION_HASH)
    b = sub.add_parser("build")
    b.add_argument("out")
    b.add_argument("--policy", required=True)
    b.add_argument("--model", required=True)
    b.add_argument("--period", type=int, default=4)
    b.add_argument("--decoder", choices=["argmax", "sample"])
    b.add_argument("--temperature", type=float)
    b.add_argument("--goal-red", type=float, nargs=16)
    b.add_argument("--goal-blue", type=float, nargs=16)
    a = ap.parse_args()
    if a.cmd == "validate":
        data = open(a.package, "rb").read()
        if not is_package(data):
            print("plain BASIC submission (not a package): unchanged")
            return
        try:
            m = validate(data, a.obs_hash, a.action_hash)
        except PackageError as e:
            print(f"REJECTED: {e}")
            sys.exit(1)
        print(f"OK {SCHEMA} hidden={m['model']['hidden']} period={m['decision_period']}")
    else:
        decoder = None
        if a.decoder:
            decoder = {"mode": a.decoder}
            if a.temperature is not None:
                decoder["temperature"] = a.temperature
        goal = {"red": a.goal_red, "blue": a.goal_blue} if a.goal_red and a.goal_blue else None
        data = build(open(a.policy, "rb").read(), open(a.model, "rb").read(), a.period, decoder, goal)
        open(a.out, "wb").write(data)
        print(f"wrote {a.out} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
