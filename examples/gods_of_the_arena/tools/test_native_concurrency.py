"""Concurrency acceptance: N threads x M handles == serial, bit for bit.

Every handle gets a fixed seed, learner mask and seeded random actions. The serial pass steps
handles one at a time on the main thread; the threaded pass steps them from a thread pool in
which a handle may move to a different thread on every step (one thread at a time per handle,
as the Puffer native trainer does), then destroys every handle from the main thread. The
per-step state hash, reward, observation checksum and BC-label sequences must be identical.
Usage: python3 test_native_concurrency.py LIB [HANDLES] [THREADS] [STEPS]
"""
import hashlib, os, sys, threading
from concurrent.futures import ThreadPoolExecutor
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from native_env import Env, Lib, random_actions


def make(lib, i):
    env = Env(lib, learner_seats=[i % 10, (i * 3 + 5) % 10], max_ticks=28800)
    env.reset(1000 + i)
    return env


def advance(env, rng, trace):
    obs, res, act = env.observe()
    r = env.step(random_actions(rng))
    labels = np.stack([env.orders(s) for s in range(10)])
    h = hashlib.sha256(obs.tobytes() + res.tobytes() + act.tobytes() + env.rewards.tobytes() + labels.tobytes()).hexdigest()[:16]
    trace.append((env.state_hash(), h))
    if r == 1:
        env.reset(99999)


def main():
    lib = Lib(sys.argv[1])
    handles = int(sys.argv[2]) if len(sys.argv) > 2 else 12
    threads = int(sys.argv[3]) if len(sys.argv) > 3 else 6
    steps = int(sys.argv[4]) if len(sys.argv) > 4 else 300
    serial = []
    for i in range(handles):
        env, rng, trace = make(lib, i), np.random.default_rng(i), []
        for _ in range(steps):
            advance(env, rng, trace)
        serial.append(trace)
        env.close()
    envs = [make(lib, i) for i in range(handles)]
    rngs = [np.random.default_rng(i) for i in range(handles)]
    traces = [[] for _ in range(handles)]
    seen_threads = [set() for _ in range(handles)]

    def one(i):
        seen_threads[i].add(threading.get_ident())
        advance(envs[i], rngs[i], traces[i])

    with ThreadPoolExecutor(threads) as pool:
        for _ in range(steps):
            list(pool.map(one, range(handles)))  # every handle once per round, any thread
    for env in envs:
        env.close()  # destroy from the main thread after foreign-thread stepping
    bad = [i for i in range(handles) if traces[i] != serial[i]]
    migrated = sum(len(s) > 1 for s in seen_threads)
    print(f"handles={handles} threads={threads} steps={steps} migrated_handles={migrated} mismatched={bad}")
    if bad:
        i = bad[0]
        k = next(k for k in range(steps) if traces[i][k] != serial[i][k])
        print("first mismatch handle", i, "step", k, traces[i][k], serial[i][k])
        sys.exit(1)
    print("CONCURRENCY OK")


if __name__ == "__main__":
    main()
