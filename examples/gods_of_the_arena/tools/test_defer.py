"""Residual-track (defer script) proofs, Amendment 3. Run on a build host, not a laptop.

  python3 test_defer.py LIB [--seeds N] [--ticks T] [--jobs J] [--old-lib OLD] [--only a,b,c]

a  always-defer: a net whose verb-0 logit dominates, in a learner seat with gota_set_seat_defer_script(base.bas)
   (ABI) and in a hosted package seat (decoder.defer_script, policy.bas = base.bas verbatim), plays
   byte-identical to plain base.bas in that seat: every step's state hash and the recorded replay bytes.
b  ABI == package on a net that mixes defer and override: per-step hashes, defer/override counts.
c  seats without the option (learners, shadow, capture, override, plain package) are byte-identical to
   OLD (the lib built from the branch head before the defer change): per-step hashes and replay bytes.
"""
import argparse, ctypes, hashlib, os, sys, tempfile
from concurrent.futures import ProcessPoolExecutor
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "../../../coworld/gota/runtime"))
from native_env import Env, Lib, random_actions, HEAD_SIZES
import neural_package as npk

ROOT = os.path.join(HERE, "..")
BASE = open(os.path.join(ROOT, "players/base.bas"), "rb").read()
POLICY = open(os.path.join(ROOT, "neural/policy.bas"), "rb").read()
F32 = ctypes.POINTER(ctypes.c_float)


def model_weights(hidden, seed, scale, verb0_bias):
    """Encoder/recurrent ~ N(0, scale); decoder row 0 (verb 0) gets +verb0_bias on every unit.
    scale 0 + bias 1: x = 0, y > 0 for every unit, so logit 0 = bias * sum(y) > 0 = every other logit."""
    rng = np.random.default_rng(seed)
    n_enc, n_rec, n_dec = 1407 * hidden, 3 * hidden * hidden, 92 * hidden
    w = (rng.standard_normal(n_enc + n_rec + n_dec) * scale).astype(np.float32)
    w[n_enc + n_rec: n_enc + n_rec + hidden] += verb0_bias
    return npk.encode_model(w.tolist(), hidden)


ALWAYS = dict(hidden=64, seed=0, scale=0.0, verb0_bias=1.0)
MIXED = dict(hidden=128, seed=7, scale=0.05, verb0_bias=0.02)


def argmax_heads(logits):
    out, o = [], 0
    for s in HEAD_SIZES:
        out.append(int(np.argmax(logits[o:o + s]))); o += s
    return out


class Driver:
    """Drives one learner seat through gota_net_infer (the trainer's view)."""
    def __init__(self, lib, model, seat):
        err = ctypes.create_string_buffer(512)
        self.lib, self.seat = lib, seat
        self.net = lib.L.gota_net_load(model, len(model), err, 512)
        assert self.net, err.value
        info = np.zeros(8, np.int64)
        lib.L.gota_net_info(self.net, info.ctypes.data_as(ctypes.POINTER(ctypes.c_int64)))
        self.state = np.zeros(int(info[5]), np.float32)
        self.logits = np.zeros(92, np.float32)

    def act(self, env, actions):
        obs, res, act = env.observe(1 << self.seat)
        if act[self.seat]:
            if res[self.seat]:
                self.state[:] = 0
            o = np.ascontiguousarray(obs[self.seat])
            assert self.lib.L.gota_net_infer(self.net, o.ctypes.data_as(F32), self.state.ctypes.data_as(F32),
                                             self.logits.ctypes.data_as(F32)) == 0
            actions[self.seat] = argmax_heads(self.logits)


def play(env, seed, driver=None, rng=None, watch=None):
    """Full episode: per-step hashes. watch = seat whose BASIC instructions (last tick of each step) are
    sampled into env.peak_instr."""
    env.reset(seed)
    hashes = []
    env.peak_instr = 0
    while True:
        actions = np.zeros((10, 5), np.int32)
        if rng is not None:
            env.observe()
            actions = random_actions(rng)
        if driver is not None:
            driver.act(env, actions)
        r = env.step(actions)
        hashes.append(env.state_hash())
        if watch is not None:
            env.peak_instr = max(env.peak_instr, int(env.stats(watch)[22]))
        if r == 1:
            return hashes


def replay_bytes(env):
    fd, path = tempfile.mkstemp(suffix=".replay"); os.close(fd)
    assert env.save_replay(path) == 0
    data = open(path, "rb").read(); os.unlink(path)
    return data


def job_a(lib_path, seed, ticks):
    lib = Lib(lib_path)
    seat = seed % 10
    cfg = dict(max_ticks=ticks, record=True, capture=False)
    model = model_weights(**ALWAYS)
    ref = Env(lib, learner_seats=[], **cfg)
    h_ref = play(ref, seed, watch=seat); r_ref = replay_bytes(ref)
    instr = ref.peak_instr
    abi = Env(lib, learner_seats=[seat], **cfg)
    assert abi.set_defer_script(seat, "players/base.bas") == 0
    drv = Driver(lib, model, seat)
    h_abi = play(abi, seed, drv); r_abi = replay_bytes(abi)
    st_abi = abi.defer_stats(seat).tolist()
    pkg = Env(lib, learner_seats=[], **cfg)
    assert pkg.set_package(seat, npk.build(BASE, model, decoder={"defer_script": True})) == 0
    h_pkg = play(pkg, seed); r_pkg = replay_bytes(pkg)
    st_pkg = pkg.defer_stats(seat).tolist()
    return dict(seed=seed, seat=seat, steps=len(h_ref), ticks=int(ref.results()[4]),
                final=f"{h_ref[-1]:016x}",
                abi_hashes=h_abi == h_ref, abi_replay=r_abi == r_ref,
                pkg_hashes=h_pkg == h_ref, pkg_replay=r_pkg == r_ref,
                abi_defer=st_abi, pkg_defer=st_pkg, ref_seat_peak_instr_sampled=int(instr),
                replay_sha=hashlib.sha256(r_ref).hexdigest()[:12])


def job_b(lib_path, seed, ticks):
    lib = Lib(lib_path)
    seat = (seed * 3) % 10
    cfg = dict(max_ticks=ticks, capture=False)
    model = model_weights(**MIXED)
    abi = Env(lib, learner_seats=[seat], **cfg)
    assert abi.set_defer_script(seat, "players/base.bas") == 0
    h_abi = play(abi, seed, Driver(lib, model, seat))
    pkg = Env(lib, learner_seats=[], **cfg)
    assert pkg.set_package(seat, npk.build(BASE, model, decoder={"defer_script": True})) == 0
    h_pkg = play(pkg, seed)
    ref = Env(lib, learner_seats=[], **cfg)
    h_ref = play(ref, seed)
    sa, sp = abi.defer_stats(seat).tolist(), pkg.defer_stats(seat).tolist()
    return dict(seed=seed, seat=seat, steps=len(h_abi), same=h_abi == h_pkg, abi_defer=sa, pkg_defer=sp,
                counts_same=sa == sp, invalid=[int(abi.stats(seat)[21]), int(pkg.stats(seat)[21])],
                diverges_from_plain=h_abi != h_ref,
                xp=[int(abi.stats(seat)[2]), int(ref.stats(seat)[2])])


def lineup_c(lib, seed, ticks, package=True):
    """Every non-defer feature at once: 2 learners (random actions, one with a shadow), a plain package
    seat (random net, no defer_script), an override seat, capture on, puller/rusher scripts."""
    env = Env(lib, learner_seats=[1, 6], max_ticks=ticks, record=True, capture=True)
    assert env.set_script(2, open(os.path.join(ROOT, "players/puller.bas")).read()) == 0
    assert env.set_script(8, open(os.path.join(ROOT, "players/rusher.bas")).read()) == 0
    assert env.set_override(5, 1) == 0
    b = BASE
    assert env.L.gota_set_seat_shadow(env.h, 6, b, len(b)) == 0
    if package:
        assert env.set_package(3, npk.build(POLICY, model_weights(hidden=64, seed=seed, scale=0.05, verb0_bias=0))) == 0
    h = play(env, seed, rng=np.random.default_rng(seed))
    orders = [env.orders(s).tolist() for s in range(10)]
    return h, replay_bytes(env), orders


def job_c(lib_path, old_path, seed, ticks, package=True):
    h_new, r_new, o_new = lineup_c(Lib(lib_path), seed, ticks, package)
    h_old, r_old, o_old = lineup_c(Lib(old_path), seed, ticks, package)
    # plain all-script lineup (no neural seats, capture off) too
    p_new = play(Env(Lib(lib_path), learner_seats=[], max_ticks=ticks, capture=False), seed)
    p_old = play(Env(Lib(old_path), learner_seats=[], max_ticks=ticks, capture=False), seed)
    return dict(seed=seed, steps=len(h_new), hashes=h_new == h_old, replay=r_new == r_old,
                orders=o_new == o_old, plain=p_new == p_old, final=f"{h_new[-1]:016x}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lib")
    ap.add_argument("--old-lib")
    ap.add_argument("--seeds", type=int, default=20)
    ap.add_argument("--ticks", type=int, default=28800)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--only", default="a,b,c")
    ap.add_argument("--c-no-package", action="store_true",
                    help="c without the package seat (when the reference lib predates a package-seat fix)")
    a = ap.parse_args()
    fails = []
    with ProcessPoolExecutor(a.jobs) as ex:
        if "a" in a.only:
            rows = list(ex.map(job_a, [a.lib] * a.seeds, range(1, a.seeds + 1), [a.ticks] * a.seeds))
            for r in rows: print("a", r, flush=True)
            ok = sum(r["abi_hashes"] and r["abi_replay"] and r["pkg_hashes"] and r["pkg_replay"]
                     and r["abi_defer"][1] == 0 and r["pkg_defer"][1] == 0 for r in rows)
            print(f"A always-defer == plain base.bas (ABI+package, hashes+replay): {ok}/{len(rows)}; "
                  f"peak plain-seat BASIC instr/tick (sampled last tick of every step) {max(r['ref_seat_peak_instr_sampled'] for r in rows)}", flush=True)
            if ok != len(rows): fails.append("a")
        if "b" in a.only:
            n = max(8, a.seeds // 2)
            rows = list(ex.map(job_b, [a.lib] * n, range(1, n + 1), [a.ticks] * n))
            for r in rows: print("b", r, flush=True)
            ok = sum(r["same"] and r["counts_same"] for r in rows)
            d = sum(r["abi_defer"][0] for r in rows); o = sum(r["abi_defer"][1] for r in rows)
            print(f"B ABI == package on mixed net: {ok}/{n}; defer {d} override {o} "
                  f"(override share {o / max(1, d + o):.3f}); diverged from plain {sum(r['diverges_from_plain'] for r in rows)}/{n}",
                  flush=True)
            if ok != n or o == 0 or d == 0: fails.append("b")
        if "c" in a.only and a.old_lib:
            n = max(8, a.seeds // 2)
            rows = list(ex.map(job_c, [a.lib] * n, [a.old_lib] * n, range(1, n + 1), [a.ticks] * n,
                               [not a.c_no_package] * n))
            for r in rows: print("c", r, flush=True)
            ok = sum(r["hashes"] and r["replay"] and r["orders"] and r["plain"] for r in rows)
            print(f"C no-option seats == pre-change lib (hashes+replay+orders, plus plain lineup): {ok}/{n}", flush=True)
            if ok != n: fails.append("c")
    print("ALL PASS" if not fails else f"FAILURES: {fails}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
