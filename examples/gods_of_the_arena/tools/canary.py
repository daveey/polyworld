"""Local hosted canary (item 5c): the -d:coworld GotA server plays a full match with five
neural-package seats (random GOTANET1 weights) and five base.bas seats through the platform's
file handoff (COGAME_* URIs), then the recorded replay is re-simulated by the headless binary.
Pass = results.json written, every seat's player status exit_code 0, every neural seat log has
the `neural: peak_ops=... budget=... model=w... ticks=...` telemetry line, and the replay
re-simulates with zero hash mismatches.
Usage: python3 canary.py COWORLD_BIN HEADLESS_BIN WORKDIR [HIDDEN] [MAX_TICKS]
"""
import hashlib, json, os, socket, subprocess, sys, time, urllib.parse
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "../../.."))
sys.path.insert(0, os.path.join(ROOT, "coworld/gota/runtime"))
import neural_package as npk


def uri(path):
    return "file://" + urllib.parse.quote(path)


def main():
    coworld, headless, work = sys.argv[1:4]
    hidden = int(sys.argv[4]) if len(sys.argv) > 4 else 128
    max_ticks = int(sys.argv[5]) if len(sys.argv) > 5 else 28800
    os.makedirs(work, exist_ok=True)
    rng = np.random.default_rng(7)
    n = 1407 * hidden + 3 * hidden * hidden + 92 * hidden
    model = npk.encode_model((rng.standard_normal(n) * 0.05).astype(np.float32).tolist(), hidden)
    policy = open(os.path.join(ROOT, "examples/gods_of_the_arena/neural/policy.bas"), "rb").read()
    pkg = npk.build(policy, model)
    base = open(os.path.join(ROOT, "examples/gods_of_the_arena/players/base.bas"), "rb").read()
    sources = [pkg if slot in (0, 2, 4, 6, 8) else base for slot in range(10)]  # 5 neural, both teams
    config = {"tokens": [], "players": [], "seed": 2026, "max_ticks": max_ticks}
    seats = []
    for slot, src in enumerate(sources):
        path = os.path.join(work, f"player-{slot}")
        open(path, "wb").write(src)
        config["tokens"].append(f"token-{slot}")
        config["players"].append({"name": f"CANARY-{slot}"})
        seats.append({"slot": slot, "file_uri": uri(path), "content_hash": "sha256:" + hashlib.sha256(src).hexdigest(),
                      "size_bytes": len(src), "log_uri": uri(os.path.join(work, f"player-{slot}.log")),
                      "artifact_uri": uri(os.path.join(work, f"player-{slot}.zip"))})
    doc = {"schema": "coworld-player-seats/1", "seats": seats, "player_status_uri": uri(os.path.join(work, "status.json"))}
    env = dict(os.environ)
    s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
    env.update(COGAME_HOST="127.0.0.1", COGAME_PORT=str(port))
    for key, value in (("CONFIG", config), ("PLAYER_SEATS", doc)):
        p = os.path.join(work, key + ".json"); json.dump(value, open(p, "w")); env[f"COGAME_{key}_URI"] = uri(p)
    for key, name in (("RESULTS", "results.json"), ("SAVE_REPLAY", "replay"), ("PLAYER_FAILURE", "failure.json")):
        env[f"COGAME_{key}_URI"] = uri(os.path.join(work, name))
    for f in ("results.json", "failure.json", "status.json", "replay"):
        if os.path.exists(os.path.join(work, f)):
            os.remove(os.path.join(work, f))
    t = time.time()
    proc = subprocess.Popen([coworld], cwd=ROOT, env=env, stdout=open(os.path.join(work, "game.log"), "w"), stderr=subprocess.STDOUT)
    ok = True
    try:
        while not os.path.exists(os.path.join(work, "results.json")):
            if os.path.exists(os.path.join(work, "failure.json")) or proc.poll() is not None:
                print("FAIL game ended without results:", open(os.path.join(work, "game.log")).read()[-2000:])
                sys.exit(1)
            if time.time() - t > 3600:
                print("FAIL timeout"); sys.exit(1)
            time.sleep(0.5)
        elapsed = time.time() - t
        results = json.load(open(os.path.join(work, "results.json")))
        status = json.load(open(os.path.join(work, "status.json")))
    finally:
        proc.terminate(); proc.wait(10)
    codes = [p["exit_code"] for p in status["players"]]
    print("results", json.dumps({k: results[k] for k in results if k != "total_xp"}), "total_xp", results.get("total_xp"))
    print("player exit codes", codes, f"match seconds {elapsed:.0f}")
    ok &= all(c == 0 for c in codes) and len(codes) == 10
    for slot in (0, 2, 4, 6, 8):
        log = open(os.path.join(work, f"player-{slot}.log")).read()
        lines = [l for l in log.splitlines() if l.startswith("neural: ")]
        print(f"seat {slot} telemetry:", lines[-1] if lines else "MISSING")
        ok &= bool(lines) and "BASIC error" not in log
    out = subprocess.run([headless, "--replay", os.path.join(work, "replay")], cwd=ROOT, capture_output=True, text=True)
    tail = [l for l in out.stdout.splitlines() if l.startswith(("hash:", "replay", "result"))]
    print("replay re-simulation:", tail, "rc", out.returncode)
    ok &= out.returncode == 0 and not any("mismatches" in l for l in tail)
    print("CANARY PASS" if ok else "CANARY FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
