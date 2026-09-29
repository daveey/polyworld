"""Glory reward mode acceptance (config "reward": "glory" / GOTA_REWARD=glory). Run on a build host, not a laptop.

  python3 test_reward_glory.py LIB [--old-lib OLD] [--seeds 1 2 3 4 5 6] [--jobs 6]

For full ten-scripted-seat episodes (base.bas, capture off) and for short timeout episodes:
 a glory-on == glory-off in everything but stats[0] and rewards: same per-step state hash, same observations (bit for bit);
 b glory-on stats[0] is 0 and rewards are 0 on every step before the end; at the end stats[0] equals Emmett's Glory
   (winner: lifetime XP * 1440 // world tick, whole points; losers, draws and timeouts 0) recomputed here from the
   ABI's own xp stat, winner and world tick; the summed rewards * 1000 equal it (one terminal delta);
 c glory-off stats[0] follows the pre-Glory formula at the end (xp - 200/min, floored) and rewards are its deltas / 1000;
 d with --old-lib (the build before the flag, e.g. 19bc841) glory-off is bit-identical to it: per-step state hash,
   observations, rewards and stats[0] streams.
At least one winner, one loser with XP and one timeout must be seen (a draw is reported if it occurs).
"""
import argparse, hashlib, multiprocessing as mp, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from native_env import Env, Lib

BASE = open(os.path.join(HERE, "../players/base.bas")).read()
TPM = 1440  # ticks per minute (24 tps)


def play(args):
    libpath, seed, max_ticks, reward = args
    lib = Lib(libpath)
    cfg = dict(seed=seed, max_ticks=max_ticks, learner_seats=[], capture=False)
    if reward:
        cfg["reward"] = reward
    env = Env(lib, **cfg)
    env.reset(seed)
    hashes, obs, rew, st0 = hashlib.sha256(), hashlib.sha256(), hashlib.sha256(), hashlib.sha256()
    first_nonzero_stat, first_nonzero_reward, total_reward, steps = None, None, 0.0, 0
    while True:
        o, _, _ = env.observe(); obs.update(o.tobytes())
        r = env.step(np.zeros((10, 5), np.int32)); steps += 1
        hashes.update(int(env.state_hash()).to_bytes(8, "little"))
        rew.update(env.rewards.tobytes())
        s0 = np.array([env.stats(i)[0] for i in range(10)], np.int64); st0.update(s0.tobytes())
        total_reward += env.rewards.astype(np.float64)
        if r == 1:
            break
        if s0.any() and first_nonzero_stat is None: first_nonzero_stat = steps
        if env.rewards.any() and first_nonzero_reward is None: first_nonzero_reward = steps
    res = env.results()
    final = [env.stats(i) for i in range(10)]
    return dict(seed=seed, max_ticks=max_ticks, reward=reward, steps=steps, hash=hashes.hexdigest(), obs=obs.hexdigest(),
                rew=rew.hexdigest(), st0=st0.hexdigest(), results=res.tolist(), stats0=[int(f[0]) for f in final],
                xp=[int(f[2]) for f in final], outcome=[int(f[1]) for f in final], team=[int(f[17]) for f in final],
                early_stat=first_nonzero_stat, early_reward=first_nonzero_reward, total_reward=[float(x) for x in total_reward],
                battle_tick=int(res[4]), world_tick=int(res[7]))


def expected_glory(r, i):
    won = r["results"][1] == r["team"][i] and not r["results"][2]
    xp, tick = r["xp"][i], r["world_tick"]
    return xp * TPM // tick if won and xp > 0 and tick > 0 else 0


def expected_legacy(r, i):
    scaled = r["xp"][i] * TPM - 200 * r["battle_tick"]
    return max(0, scaled) // TPM


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("lib"); ap.add_argument("--old-lib")
    ap.add_argument("--seeds", type=int, nargs="+", default=[1, 2, 3, 4, 5, 6]); ap.add_argument("--jobs", type=int, default=6)
    a = ap.parse_args(); fails = []
    def check(name, ok, detail=""):
        print(("PASS " if ok else "FAIL ") + name + (" " + detail if detail else "")); 
        if not ok: fails.append(name)
    jobs = []
    for s in a.seeds:
        jobs += [(a.lib, s, 28800, "glory"), (a.lib, s, 28800, None)]
        if a.old_lib: jobs.append((a.old_lib, s, 28800, None))
    for s in a.seeds[:2]:
        jobs += [(a.lib, s, 1500, "glory"), (a.lib, s, 1500, None)]
        if a.old_lib: jobs.append((a.old_lib, s, 1500, None))
    with mp.get_context("spawn").Pool(a.jobs) as pool:
        out = pool.map(play, jobs)
    by = {(r["seed"], r["max_ticks"], r["reward"], os.path.basename(j[0])): r for r, j in zip(out, jobs)}
    seen = dict(win=0, loser_xp=0, timeout=0, draw=0)
    for s, mt in [(s, 28800) for s in a.seeds] + [(s, 1500) for s in a.seeds[:2]]:
        g, x = by[(s, mt, "glory", os.path.basename(a.lib))], by[(s, mt, None, os.path.basename(a.lib))]
        tag = f"seed {s} max_ticks {mt}"
        check(f"{tag}: glory-on plays the same world (hashes) and sees the same observations", g["hash"] == x["hash"] and g["obs"] == x["obs"])
        gl = [expected_glory(g, i) for i in range(10)]
        check(f"{tag}: glory-on stats[0] == Glory at the end", g["stats0"] == gl, f"{g['stats0']} winner={g['results'][1]} draw={g['results'][2]} tick={g['world_tick']}")
        check(f"{tag}: glory-on is 0 (stats and rewards) before the end, one terminal reward delta",
              g["early_stat"] is None and g["early_reward"] is None and all(abs(t * 1000 - v) < 1.0 for t, v in zip(g["total_reward"], g["stats0"])))
        lg = [expected_legacy(x, i) for i in range(10)]
        check(f"{tag}: glory-off stats[0] is the pre-Glory score", x["stats0"] == lg)
        finished = g["results"][3] == 0
        if g["results"][3]: seen["timeout"] += 1
        elif g["results"][2]: seen["draw"] += 1
        elif any(gl): seen["win"] += 1
        if not g["results"][2] and any(g["xp"][i] > 0 and gl[i] == 0 for i in range(10)): seen["loser_xp"] += 1
        if a.old_lib:
            o = by[(s, mt, None, os.path.basename(a.old_lib))]
            check(f"{tag}: glory-off == old lib (hashes, observations, rewards, stats[0])",
                  all(o[k] == x[k] for k in ("hash", "obs", "rew", "st0")) and o["stats0"] == x["stats0"])
    print("coverage", seen)
    check("saw a winner, a loser with XP, and a timeout", seen["win"] > 0 and seen["loser_xp"] > 0 and seen["timeout"] > 0)
    print("REWARD ALL PASS" if not fails else "REWARD FAIL " + ",".join(fails)); sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
