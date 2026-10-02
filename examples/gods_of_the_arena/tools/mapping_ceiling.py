"""Mapping ceiling: play base.bas through the action contract and compare with plain base.bas.

For every seed three matches run to max_ticks: A = ten plain base.bas seats; R = red seats 0-4
under gota_set_seat_override (their contract commands are encoded to the 5 heads, decoded and
executed exactly as a learner seat's would be); B = blue seats 5-9 under override. The ceiling
holds when override teams keep plain base.bas's results: win rate and per-seat XP/score within
noise of A. Usage: python3 mapping_ceiling.py LIB SEEDS [MAX_TICKS] [PROCS] [OUT.json]
"""
import json, os, sys, time
from multiprocessing import Pool
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from native_env import Env, Lib

LIB = None


def play(job):
    seed, mode, max_ticks = job
    lib = Lib(LIB)
    env = Env(lib, learner_seats=[], max_ticks=max_ticks)
    seats = {"A": [], "R": range(0, 5), "B": range(5, 10)}[mode]
    for s in seats:
        env.set_override(s, True)
    env.reset(seed)
    kinds, exact, errs, labeled = np.zeros(8, np.int64), np.zeros(8, np.int64), [], 0
    noop = np.zeros((10, 5), np.int32)
    while True:
        r = env.step(noop)
        for s in seats:
            o = env.orders(s)
            if o[13] > 0:
                labeled += int(o[0])
                kinds[o[7]] += 1
                exact[o[7]] += int(o[6])
                if o[7] in (1, 2, 5, 7):
                    errs.append(int(o[14]))
        if r == 1:
            break
    res = env.results()
    stats = [env.stats(s) for s in range(10)]
    env.close()
    return dict(seed=seed, mode=mode, winner=int(res[1]), ticks=int(res[4]),
                xp=[int(x[2]) for x in stats], score=[int(x[0]) for x in stats],
                kills=[int(x[4]) for x in stats], deaths=[int(x[6]) for x in stats],
                kinds=kinds.tolist(), exact=exact.tolist(), labeled=labeled,
                err_median=float(np.median(errs)) if errs else 0.0,
                err_p90=float(np.percentile(errs, 90)) if errs else 0.0)


def init(lib):
    global LIB
    LIB = lib


def ci(x):
    x = np.asarray(x, float)
    return float(x.mean()), float(1.96 * x.std(ddof=1) / np.sqrt(len(x))) if len(x) > 1 else 0.0


def main():
    lib, nseeds = sys.argv[1], int(sys.argv[2])
    max_ticks = int(sys.argv[3]) if len(sys.argv) > 3 else 28800
    procs = int(sys.argv[4]) if len(sys.argv) > 4 else os.cpu_count()
    out = sys.argv[5] if len(sys.argv) > 5 else None
    jobs = [(seed, m, max_ticks) for seed in range(1, nseeds + 1) for m in "ARB"]
    t = time.time()
    with Pool(procs, initializer=init, initargs=(lib,)) as pool:
        rows = pool.map(play, jobs, chunksize=1)
    by = {m: [r for r in rows if r["mode"] == m] for m in "ARB"}
    def team(r, t):
        return sum(r["xp"][5 * t:5 * t + 5]) / 5.0
    def tscore(r, t):
        return sum(r["score"][5 * t:5 * t + 5]) / 5.0
    summary = {"seeds": nseeds, "max_ticks": max_ticks, "seconds": round(time.time() - t, 1)}
    # Red-side comparison: A red vs R red; blue-side: A blue vs B blue.
    for label, mode, t_ in (("red", "R", 0), ("blue", "B", 1)):
        base, over = by["A"], by[mode]
        summary[label] = {
            "plain_win": ci([r["winner"] == t_ for r in base]),
            "override_win": ci([r["winner"] == t_ for r in over]),
            "plain_xp": ci([team(r, t_) for r in base]),
            "override_xp": ci([team(r, t_) for r in over]),
            "plain_score": ci([tscore(r, t_) for r in base]),
            "override_score": ci([tscore(r, t_) for r in over]),
            "paired_xp_delta": ci([team(o, t_) - team(b, t_) for o, b in zip(over, base)]),
        }
    k = np.sum([r["kinds"] for r in by["R"] + by["B"]], 0)
    e = np.sum([r["exact"] for r in by["R"] + by["B"]], 0)
    names = ["none", "walk", "attackMove", "attackTarget", "castTarget", "castPoint", "useItem", "useItemAt"]
    summary["commands"] = {names[i]: {"n": int(k[i]), "exact": round(float(e[i]) / max(1, k[i]), 3)} for i in range(8)}
    summary["point_err_median_milli"] = float(np.median([r["err_median"] for r in by["R"] + by["B"]]))
    summary["point_err_p90_milli"] = float(np.median([r["err_p90"] for r in by["R"] + by["B"]]))
    print(json.dumps(summary, indent=1))
    if out:
        json.dump({"summary": summary, "rows": rows}, open(out, "w"))


if __name__ == "__main__":
    main()
