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


def native(lib_path, seed, seat, pkg_path, replay):
    env = Env(Lib(lib_path), learner_seats=[], record=True, capture=False)
    assert env.set_package(seat, open(pkg_path, "rb").read()) == 0
    env.reset(seed)
    goal_ok = None
    while True:
        obs, _, act = env.observe(1 << seat)
        if goal_ok is None and act[seat]:
            want = np.array(RED if seat < 5 else BLUE, np.float32)
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
    a = ap.parse_args()
    tmp = tempfile.mkdtemp()
    model = model_weights(hidden=64, seed=11, scale=0.05, verb0_bias=0.0)
    pkg = os.path.join(tmp, "goal.zip")
    open(pkg, "wb").write(npk.build(POLICY, model, goal={"red": RED, "blue": BLUE}))
    ok_all, old_diff = 0, 0
    for seed in range(1, a.seeds + 1):
        seat = 0 if seed % 2 else 5
        lineup = (["--bot", f"{P}:{seat}"] if seat else []) + ["--bot", f"{pkg}:1", "--bot", f"{P}:{9 - seat}"]
        hosted = os.path.join(tmp, f"hosted-{seed}.replay")
        out = subprocess.run([a.bin] + lineup + ["--seed", str(seed), "--record", hosted], cwd=REPO,
                             capture_output=True, text=True).stdout
        hh = re.search(r"hash: ([0-9A-Fa-f]+)", out).group(1).lower().rjust(16, "0")
        nat = os.path.join(tmp, f"native-{seed}.replay")
        goal_ok, nh = native(a.lib, seed, seat, pkg, nat)
        nb, hb = open(nat, "rb").read(), open(hosted, "rb").read()
        same_replay = nb == hb
        first_diff = next((i for i in range(min(len(nb), len(hb))) if nb[i] != hb[i]), None) if not same_replay else None
        v = subprocess.run([a.bin, "--replay", nat], cwd=REPO, capture_output=True, text=True).stdout
        vm = re.search(r"replay hashes: ([0-9]+) mismatches", v)
        vh = re.search(r"hash: ([0-9A-Fa-f]+)", v)
        verified = vm is None and vh is not None and vh.group(1).lower().rjust(16, "0") == hh
        row = dict(seed=seed, seat=seat, obs_goal=goal_ok, native_final=nh, hosted_final=hh,
                   finals_equal=nh == hh, replay_bytes_equal=same_replay, first_diff=first_diff,
                   sizes=(len(nb), len(hb)), native_replay_verified_by_binary=verified)
        if a.old_lib:
            _, oh = native(a.old_lib, seed, seat, pkg, os.path.join(tmp, f"old-{seed}.replay"))
            row["old_lib_final"] = oh
            old_diff += oh != hh
        print(row, flush=True)
        ok_all += goal_ok and nh == hh and same_replay and verified
    print(f"package goal: native == hosted-style {ok_all}/{a.seeds} (obs goal, final hash, replay bytes)"
          + (f"; pre-fix lib differs from hosted on {old_diff}/{a.seeds}" if a.old_lib else ""))
    print("GOAL OK" if ok_all == a.seeds else "GOAL FAIL")
    sys.exit(0 if ok_all == a.seeds else 1)


if __name__ == "__main__":
    main()
