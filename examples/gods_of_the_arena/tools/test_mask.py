"""Action-mask proofs (gota_action_mask / decoder.mask_empty_targets). Run on a build host, not a laptop.

  python3 test_mask.py LIB [--seeds N] [--ticks T] [--jobs J]

2  ABI mask == host mask: a package seat (random w128 net, mask_empty_targets) and a learner seat driven by
   gota_net_infer + the documented masked argmax over gota_action_mask give the same mask bytes, the same heads
   and the same per-step state hash every decision (conditional mode; static mode on odd seeds).
3  0 invalid: with the conditional mask the random net makes 0 invalid actions (stats[21]) in both seats;
   the same net unmasked and in static mode are reported for comparison.
(Option-absent parity is test_defer.py c against the pre-mask lib.)
"""
import argparse, ctypes, os, sys
from concurrent.futures import ProcessPoolExecutor
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "../../../coworld/gota/runtime"))
from native_env import Env, Lib, masked_argmax, static_masks, mask_target_row
import neural_package as npk
from test_defer import Driver, model_weights, argmax_heads

POLICY = open(os.path.join(HERE, "../neural/policy.bas"), "rb").read()
F32 = ctypes.POINTER(ctypes.c_float)


def job(lib_path, seed, ticks):
    lib = Lib(lib_path)
    seat = (seed * 7) % 10
    static = seed % 2 == 1
    model = model_weights(hidden=128, seed=100 + seed, scale=0.05, verb0_bias=0.0)
    decoder = {"mask_empty_targets": True, "mask_mode": "static" if static else "conditional"}
    cfg = dict(max_ticks=ticks, capture=False)
    pkg = Env(lib, learner_seats=[], **cfg)
    assert pkg.set_package(seat, npk.build(POLICY, model, decoder=decoder)) == 0
    abi = Env(lib, learner_seats=[seat], **cfg)
    raw = Env(lib, learner_seats=[], **cfg)  # same net, no mask (comparison only)
    assert raw.set_package(seat, npk.build(POLICY, model)) == 0
    drv = Driver(lib, model, seat)
    pkg.reset(seed); abi.reset(seed)
    same_mask = same_heads = same_hash = True
    decisions = 0
    rows_all_valid = True  # every allowed attackTarget slot is occupied and not self
    while True:
        obs, res, act = abi.observe(1 << seat)
        pkg.observe(1 << seat)
        actions = np.zeros((10, 5), np.int32)
        if act[seat]:
            if res[seat]:
                drv.state[:] = 0
            o = np.ascontiguousarray(obs[seat])
            assert lib.L.gota_net_infer(drv.net, o.ctypes.data_as(F32), drv.state.ctypes.data_as(F32),
                                        drv.logits.ctypes.data_as(F32)) == 0
            ma, mp = abi.action_mask(seat), pkg.action_mask(seat)
            same_mask &= bool(np.array_equal(ma, mp))
            actions[seat] = masked_argmax(drv.logits, ma, static)
            same_heads &= list(pkg.orders(seat)[1:6]) == list(actions[seat])
            decisions += 1
        r1 = abi.step(actions); r2 = pkg.step(actions)
        same_hash &= abi.state_hash() == pkg.state_hash()
        if r1 == 1 or r2 == 1:
            break
    raw.reset(seed)
    while raw.step(np.zeros((10, 5), np.int32)) == 0:
        pass
    return dict(seed=seed, seat=seat, mode="static" if static else "conditional", decisions=decisions,
                mask=same_mask, heads=same_heads, hashes=same_hash,
                invalid_abi=int(abi.stats(seat)[21]), invalid_pkg=int(pkg.stats(seat)[21]),
                invalid_unmasked=int(raw.stats(seat)[21]), unmasked_decisions=int(raw.stats(seat)[20]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lib")
    ap.add_argument("--seeds", type=int, default=12)
    ap.add_argument("--ticks", type=int, default=28800)
    ap.add_argument("--jobs", type=int, default=12)
    a = ap.parse_args()
    with ProcessPoolExecutor(a.jobs) as ex:
        rows = list(ex.map(job, [a.lib] * a.seeds, range(1, a.seeds + 1), [a.ticks] * a.seeds))
    for r in rows:
        print("m", r, flush=True)
    parity = sum(r["mask"] and r["heads"] and r["hashes"] for r in rows)
    cond = [r for r in rows if r["mode"] == "conditional"]
    stat = [r for r in rows if r["mode"] == "static"]
    zero = sum(r["invalid_abi"] == 0 and r["invalid_pkg"] == 0 for r in cond)
    print(f"2 ABI mask == host mask (mask bytes, heads, hashes every decision): {parity}/{len(rows)} "
          f"({sum(r['decisions'] for r in rows)} decisions)")
    print(f"3 conditional mask: 0 invalid in {zero}/{len(cond)} seeds; invalid per game: conditional "
          f"{sum(r['invalid_pkg'] for r in cond)}/{len(cond)}, static {sum(r['invalid_pkg'] for r in stat)}/{len(stat)}, "
          f"unmasked {sum(r['invalid_unmasked'] for r in rows)}/{len(rows)} games")
    ok = parity == len(rows) and zero == len(cond) and len(cond) >= 10 - len(stat) // 2
    print("ALL PASS" if parity == len(rows) and zero == len(cond) else "FAILURES")
    sys.exit(0 if parity == len(rows) and zero == len(cond) else 1)


if __name__ == "__main__":
    main()
