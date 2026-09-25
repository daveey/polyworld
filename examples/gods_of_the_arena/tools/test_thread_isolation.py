"""Cross-world isolation with several worlds per thread, and concurrent gota_create.

  python3 test_thread_isolation.py LIB vision [HANDLES] [THREADS] [STEPS]
  python3 test_thread_isolation.py LIB create [THREADS] [CREATES_PER_THREAD]

vision: HANDLES full-length matches (default 16, 4 threads, so >= 4 worlds share each thread and
handles migrate every round) must give the same per-step state hashes as each match run alone. The
per-world tower damage and structure kills show that towers fell differently across worlds, which is
where a shared per-thread vision-blocker grid would leak one world's towers into another's camp sight.
create: THREADS threads create, reset, step and destroy handles concurrently. Every handle must give
the per-step hashes of the same config created serially.
"""
import os, sys, threading
from concurrent.futures import ThreadPoolExecutor
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from native_env import Env, Lib, random_actions


def make(lib, i, ticks=28800):
    env = Env(lib, learner_seats=[i % 10], max_ticks=ticks, capture=False)
    env.reset(500 + i)
    return env


def advance(env, rng, trace):
    if env.done:
        return
    env.observe()
    r = env.step(random_actions(rng))
    trace.append(env.state_hash())
    if r == 1:
        env.done = True


def towers(env):
    s = [env.stats(k) for k in range(10)]
    return dict(tower_damage=[int(sum(x[9] for x in s[:5])), int(sum(x[9] for x in s[5:]))],
                structure_kills=[int(sum(x[10] for x in s[:5])), int(sum(x[10] for x in s[5:]))],
                ticks=int(env.results()[4]))


def vision(lib, handles, threads, steps):
    serial, facts = [], []
    for i in range(handles):
        env, rng, trace = make(lib, i), np.random.default_rng(i), []
        env.done = False
        for _ in range(steps):
            advance(env, rng, trace)
        serial.append(trace); facts.append(towers(env))
        env.close()
    envs = [make(lib, i) for i in range(handles)]
    for e in envs:
        e.done = False
    rngs = [np.random.default_rng(i) for i in range(handles)]
    traces = [[] for _ in range(handles)]
    seen = [set() for _ in range(handles)]

    def one(i):
        seen[i].add(threading.get_ident())
        advance(envs[i], rngs[i], traces[i])

    with ThreadPoolExecutor(threads) as pool:
        for _ in range(steps):
            list(pool.map(one, range(handles)))
    for e in envs:
        e.close()
    bad = [i for i in range(handles) if traces[i] != serial[i]]
    for i, f in enumerate(facts):
        print("world", i, f)
    distinct = len({(tuple(f["tower_damage"]), tuple(f["structure_kills"])) for f in facts})
    kills = sum(sum(f["structure_kills"]) for f in facts)
    print(f"vision: handles={handles} threads={threads} steps={steps} migrated={sum(len(s) > 1 for s in seen)} "
          f"distinct_tower_histories={distinct}/{handles} structure_kills_total={kills} mismatched={bad}")
    if bad:
        i = bad[0]
        k = next((k for k in range(min(len(traces[i]), len(serial[i]))) if traces[i][k] != serial[i][k]), None)
        print("first mismatch world", i, "step", k)
    ok = not bad and distinct > 1 and kills > 0
    print("VISION ISOLATION OK" if ok else "VISION ISOLATION FAIL")
    return ok


def create(lib, threads, per_thread, steps=40, kinds=14):
    """Creates race each other; handle i uses config kind i % kinds (seat, capture, seed, action RNG)."""
    def run(i):
        k = i % kinds
        env = Env(lib, learner_seats=[k % 10], max_ticks=28800, capture=bool(k % 2), decision_period=4)
        env.reset(900 + k)
        env.done = False
        rng, trace = np.random.default_rng(k), []
        for _ in range(steps):
            advance(env, rng, trace)
        env.close()
        return trace
    reference = {k: run(k) for k in range(kinds)}  # serial, one at a time
    def worker(t):
        return [(t * per_thread + j, run(t * per_thread + j)) for j in range(per_thread)]
    with ThreadPoolExecutor(threads) as pool:
        results = [r for rows in pool.map(worker, range(threads)) for r in rows]
    failures = [i for i, trace in results if trace != reference[i % kinds]]
    print(f"create: threads={threads} creates={len(results)} kinds={kinds} steps_each={steps} mismatched={failures}")
    ok = not failures and len(results) == threads * per_thread
    print("CONCURRENT CREATE OK" if ok else "CONCURRENT CREATE FAIL")
    return ok


def main():
    lib = Lib(sys.argv[1])
    mode = sys.argv[2]
    a = [int(x) for x in sys.argv[3:]]
    if mode == "vision":
        ok = vision(lib, *(a + [16, 4, 7200][len(a):]))
    else:
        ok = create(lib, *(a + [16, 25][len(a):]))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
