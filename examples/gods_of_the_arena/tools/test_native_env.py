"""Native env acceptance tests (run on a build host, not a laptop).

  python3 test_native_env.py LIB [quick]

1 labels: ten scripted base.bas seats, 500 decisions: labeled rows > 50% of acting rows.
2 capture/ceiling-off identity: capture on vs off give identical per-step state hashes.
3 shadow: a learner with a base.bas shadow plays exactly as without one (hashes), and gets labels.
4 goals: a goal set before reset is the last 16 floats of the first observation.
5 rewards: rewards[s] == delta(stats[s][0]) / 1000 every step.
6 package parity (5b): a seat hosting a neural package and a learner seat driven through
  gota_net_infer with the same weights produce identical worlds (w64/w128/w256).
7 package validation: the Nim loader and neural_package.py reject the same corrupted packages.
8 ops per tick (5d): gota_net_info operations for w64/w128/w256 against the 4,000,000 budget.
"""
import os, sys, json, zipfile, io, hashlib
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "../../../coworld/gota/runtime"))
from native_env import Env, Lib, random_actions, HEAD_SIZES
import neural_package as npk
import ctypes

POLICY = open(os.path.join(HERE, "../neural/policy.bas"), "rb").read()
BASE = open(os.path.join(HERE, "../players/base.bas")).read()
failures = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (" " + detail if detail else ""))
    if not ok:
        failures.append(name)


def run_hashes(env, steps, seed, rng_seed=0, learners=()):
    env.reset(seed)
    rng = np.random.default_rng(rng_seed)
    out = []
    for _ in range(steps):
        env.observe()
        r = env.step(random_actions(rng))
        out.append(env.state_hash())
        if r == 1:
            break
    return out


def test_labels(lib, steps):
    # base.bas thinks every 6 ticks and re-issues a standing order only when it
    # changes (or every 2 s), so most 4-tick windows are genuinely "noop, hold".
    # Required: every window in which the script issued a contract command is
    # labeled (represented in the contract) >= 95% of the time, and labels are
    # not rare (>= 10% of acting rows).
    env = Env(lib, learner_seats=[])
    env.reset(3)
    acting = labeled = issued = issued_labeled = 0
    for _ in range(steps):
        _, _, act = env.observe()
        a = act.copy()
        env.step(np.zeros((10, 5), np.int32))
        for s in range(10):
            if a[s]:
                o = env.orders(s)
                acting += 1
                labeled += int(o[0])
                if o[13] > 0:
                    issued += 1
                    issued_labeled += int(o[0])
    check("labels cover command windows >=95%", issued_labeled >= 0.95 * issued, f"{issued_labeled}/{issued}")
    check("labels >=10% of acting rows", labeled >= 0.10 * acting, f"{labeled}/{acting}={labeled / max(1, acting):.2f}")
    env.close()


def test_capture_identity(lib, steps):
    a = run_hashes(Env(lib, learner_seats=[], capture=True), steps, 5)
    b = run_hashes(Env(lib, learner_seats=[], capture=False), steps, 5)
    check("capture on == off (hashes)", a == b, f"{len(a)} steps")


def test_shadow(lib, steps):
    plain = Env(lib, learner_seats=[2])
    shadow = Env(lib, learner_seats=[2])
    code = lib.L.gota_set_seat_shadow(shadow.h, 2, BASE.encode(), len(BASE.encode()))
    a = run_hashes(plain, steps, 7, 1)
    shadow.reset(7)
    rng = np.random.default_rng(1)
    b, labeled, acting = [], 0, 0
    for _ in range(steps):
        _, _, act = shadow.observe()
        alive = act[2]
        shadow.step(random_actions(rng))
        b.append(shadow.state_hash())
        if alive:
            acting += 1
            labeled += int(shadow.orders(2)[0])
    check("shadow executes nothing (hashes)", code == 0 and a == b)
    check("shadow labels present", labeled > 0.05 * acting, f"{labeled}/{acting}")


def test_goal(lib):
    env = Env(lib, learner_seats=[0, 6])
    w = np.linspace(-0.9, 0.9, 16).astype(np.float32)
    w[15] = 0
    check("goal setter ok", env.set_goal(6, w) == 0)
    bad = w.copy(); bad[15] = 0.5
    check("goal w_reserved != 0 rejected", env.set_goal(6, bad) == -3)
    env.reset(11)
    obs, _, _ = env.observe()
    check("goal is last 16 obs floats of first obs", np.array_equal(obs[6, -16:], w) and obs[0, -16] == 1.0)


def test_rewards(lib, steps):
    env = Env(lib, learner_seats=[0, 5])
    env.reset(13)
    rng = np.random.default_rng(2)
    prev = np.array([env.stats(s)[0] for s in range(10)])
    ok = True
    for _ in range(steps):
        env.observe()
        env.step(random_actions(rng))
        now = np.array([env.stats(s)[0] for s in range(10)])
        ok &= np.array_equal(env.rewards, ((now - prev) / 1000).astype(np.float32))
        prev = now
    check("rewards == delta score / 1000", bool(ok))


def random_model(hidden, seed):
    rng = np.random.default_rng(seed)
    n = 1407 * hidden + 3 * hidden * hidden + 92 * hidden
    w = (rng.standard_normal(n) * 0.05).astype(np.float32)
    return npk.encode_model(w.tolist(), hidden)


def argmax_heads(logits):
    out, o = [], 0
    for s in HEAD_SIZES:
        out.append(int(np.argmax(logits[o:o + s]))); o += s
    return out


def test_package_parity(lib, steps, widths):
    for hidden in widths:
        model = random_model(hidden, hidden)
        pkg = npk.build(POLICY, model)
        err = ctypes.create_string_buffer(512)
        net = lib.L.gota_net_load(model, len(model), err, 512)
        info = np.zeros(8, np.int64)
        lib.L.gota_net_info(net, info.ctypes.data_as(ctypes.POINTER(ctypes.c_int64)))
        hosted = Env(lib, learner_seats=[])
        rc = hosted.set_package(4, pkg)
        driven = Env(lib, learner_seats=[4])
        hosted.reset(21); driven.reset(21)
        state = np.zeros(hidden, np.float32)
        logits = np.zeros(92, np.float32)
        same, hosted_heads_ok = True, True
        for _ in range(steps):
            obs, res, act = driven.observe()
            hobs, _, _ = hosted.observe()
            same &= np.array_equal(obs[4], hobs[4])
            actions = np.zeros((10, 5), np.int32)
            if act[4]:
                if res[4]:
                    state[:] = 0
                o = np.ascontiguousarray(obs[4])
                lib.L.gota_net_infer(net, o.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),
                                     state.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),
                                     logits.ctypes.data_as(ctypes.POINTER(ctypes.c_float)))
                actions[4] = argmax_heads(logits)
            if act[4]:  # the hosted seat has already inferred on this paused frame
                hosted_heads_ok &= list(hosted.orders(4)[1:6]) == list(actions[4])
            r1 = driven.step(actions); r2 = hosted.step(actions)
            same &= driven.state_hash() == hosted.state_hash()
            if r1 == 1 or r2 == 1:
                break
        check(f"package seat == ABI-driven seat w{hidden}", rc == 0 and bool(same) and bool(hosted_heads_ok),
              f"ops/inference={info[7]} params={info[6]}")
        lib.L.gota_net_destroy(net)


def corrupt(pkg, fn):
    z = zipfile.ZipFile(io.BytesIO(pkg))
    files = {n: z.read(n) for n in z.namelist()}
    fn(files)
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as w:
        for n, d in files.items():
            w.writestr(n, d)
    return out.getvalue()


def test_validation(lib):
    model = random_model(64, 1)
    good = npk.build(POLICY, model)
    def edit_manifest(key, value):
        def f(files):
            m = json.loads(files["manifest.json"]); m[key] = value
            files["manifest.json"] = json.dumps(m).encode()
        return f
    cases = {
        "unknown decoder key": edit_manifest("decoder", {"mode": "argmax", "fire_hold": 1}),
        "unknown top key": edit_manifest("extra", 1),
        "bad period": edit_manifest("decision_period", 0),
        "bad goal reserved": edit_manifest("goal", {"red": [1] + [0] * 15, "blue": [0] * 15 + [0.5]}),
        "policy hash mismatch": lambda f: f.__setitem__("policy.bas", f["policy.bas"] + b"\n' x\n"),
        "extra file": lambda f: f.__setitem__("notes.txt", b"hi"),
        "missing model": lambda f: f.pop("model.bin"),
    }
    env = Env(lib, learner_seats=[])
    check("good package accepted by both", env.set_package(1, good) == 0)
    for name, fn in cases.items():
        bad = corrupt(good, fn)
        try:
            npk.validate(bad); py = "accepted"
        except npk.PackageError as e:
            py = "rejected"
        nim = env.set_package(1, bad)
        check(f"reject {name}", py == "rejected" and nim == 2, f"py={py} nim={nim} {env.status(1)[1][:70]}")


def main():
    lib = Lib(sys.argv[1])
    quick = len(sys.argv) > 2 and sys.argv[2] == "quick"
    steps = 200 if quick else 700
    test_labels(lib, 500)
    test_capture_identity(lib, steps)
    test_shadow(lib, steps)
    test_goal(lib)
    test_rewards(lib, steps)
    test_validation(lib)
    test_package_parity(lib, steps if quick else 7200, [64, 128, 256])
    print("ALL PASS" if not failures else f"FAILURES: {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
