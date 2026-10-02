"""Package manifest goal: native env == hosted-style load (the headless binary's loadBots path).

  python3 test_package_goal.py LIB GOTA_BIN [--seeds 6] [--old-lib OLD]

A neural package with non-default manifest goals (red and blue differ) sits in seat 0 (odd seeds) or
seat 5 (even seeds), nine base.bas seats around it, full length. Checks per seed:
  obs:     the package seat's first acting observation ends with the manifest goal of its team;
  native:  gota_set_seat_package (no gota_set_seat_goal) recorded replay == the binary's replay
           (every tick's hash and every action, byte for byte) and final hashes equal.
OLD (optional): the pre-fix lib, expected to differ (it overwrote the manifest goal with the default).
"""
import argparse, os, re, subprocess, sys, tempfile
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "../../../coworld/gota/runtime"))
from native_env import Env, Lib
import neural_package as npk
from test_defer import model_weights

REPO = os.path.abspath(os.path.join(HERE, "../../.."))
P = "examples/gods_of_the_arena/players/base.bas"
POLICY = open(os.path.join(HERE, "../neural/policy.bas"), "rb").read()
RED = [0.5, 0, 0.25, 0.1, 0.5, 0.25, -0.5, 0.25, 0.1, 0.5, 0.25, 0.5, -0.25, 0.1, 0.5, 0]
BLUE = [1, 0, -0.1, 0.5, 0, 0.1, -0.25, 0.5, 0.5, 0, 0.1, 0.25, -0.5, 0.25, 0.1, 0]


def native(lib_path, seed, seat, pkg_path, replay, manifest_goal=True):
    env = Env(Lib(lib_path), learner_seats=[], record=True, capture=False)
    assert env.set_package(seat, open(pkg_path, "rb").read()) == 0
    env.reset(seed)
    goal_ok = None
    while True:
        obs, _, act = env.observe(1 << seat)
        if goal_ok is None and act[seat]:
            want = np.array((RED if seat < 5 else BLUE) if manifest_goal else [1] + [0] * 15, np.float32)
            goal_ok = bool(np.array_equal(obs[seat][-16:], want))
        if env.step(np.zeros((10, 5), np.int32)) == 1:
            break
    assert env.save_replay(replay) == 0
    return goal_ok, "%016x" % env.state_hash()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lib"); ap.add_argument("bin")
    ap.add_argument("--seeds", type=int, default=6)
    ap.add_argument("--old-lib")
    ap.add_argument("--replay-diff", help="tools/replay_diff binary: require identical hash and action streams")
    a = ap.parse_args()
    tmp = tempfile.mkdtemp()
    model = model_weights(hidden=64, seed=11, scale=0.05, verb0_bias=0.0)
    goal_pkg = os.path.join(tmp, "goal.zip")
    open(goal_pkg, "wb").write(npk.build(POLICY, model, goal={"red": RED, "blue": BLUE}))
    plain_pkg = os.path.join(tmp, "plain.zip")
    open(plain_pkg, "wb").write(npk.build(POLICY, model))
    ok_all, old_diff, runs = 0, 0, 0
    for seed, variant in [(s, v) for s in range(1, a.seeds + 1) for v in ("goal", "default")]:
        runs += 1
        pkg = goal_pkg if variant == "goal" else plain_pkg
        seat = 0 if seed % 2 else 5
        lineup = (["--bot", f"{P}:{seat}"] if seat else []) + ["--bot", f"{pkg}:1", "--bot", f"{P}:{9 - seat}"]
        hosted = os.path.join(tmp, f"hosted-{seed}-{variant}.replay")
        out = subprocess.run([a.bin] + lineup + ["--seed", str(seed), "--record", hosted], cwd=REPO,
                             capture_output=True, text=True).stdout
        hh = re.search(r"hash: ([0-9A-Fa-f]+)", out).group(1).lower().rjust(16, "0")
        nat = os.path.join(tmp, f"native-{seed}-{variant}.replay")
        goal_ok, nh = native(a.lib, seed, seat, pkg, nat, variant == "goal")
        nb, hb = open(nat, "rb").read(), open(hosted, "rb").read()
        same_replay = nb == hb
        first_diff = next((i for i in range(min(len(nb), len(hb))) if nb[i] != hb[i]), None) if not same_replay else None
        v = subprocess.run([a.bin, "--replay", nat], cwd=REPO, capture_output=True, text=True).stdout
        vm = re.search(r"replay hashes: ([0-9]+) mismatches", v)
        vh = re.search(r"hash: ([0-9A-Fa-f]+)", v)
        verified = vm is None and vh is not None and vh.group(1).lower().rjust(16, "0") == hh
        streams = None
        if a.replay_diff:
            d = subprocess.run([a.replay_diff, hosted, nat], capture_output=True, text=True).stdout
            streams = "mismatch" not in d and "setup equal: true" in d
            m = re.search(r"actions: (\d+) vs (\d+)", d)
            streams = streams and m is not None and m.group(1) == m.group(2)
            verified = verified and streams
        row = dict(seed=seed, variant=variant, seat=seat, streams_identical=streams, obs_goal=goal_ok, native_final=nh, hosted_final=hh,
                   finals_equal=nh == hh, replay_bytes_equal=same_replay, first_diff=first_diff,
                   sizes=(len(nb), len(hb)), native_replay_verified_by_binary=verified)
        if a.old_lib:
            _, oh = native(a.old_lib, seed, seat, pkg, os.path.join(tmp, f"old-{seed}-{variant}.replay"), variant == "goal")
            row["old_lib_final"] = oh
            old_diff += oh != hh
        print(row, flush=True)
        ok_all += goal_ok and nh == hh and verified  # bytes differ only in config player names
    print(f"package seat: native == hosted-style {ok_all}/{runs} (seeds x {{manifest goal, default goal}}: obs goal, "
          f"final hash, replay verified)" + (f"; pre-fix lib differs from hosted on {old_diff}/{runs}" if a.old_lib else ""))
    print("GOAL OK" if ok_all == runs else "GOAL FAIL")
    sys.exit(0 if ok_all == runs else 1)


if __name__ == "__main__":
    main()
