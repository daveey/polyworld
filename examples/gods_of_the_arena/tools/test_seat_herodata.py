"""Shadow and package seats see their hero's self data (selfId, drafting, selfClass, ...), as bots.nim seats do.

  python3 test_seat_herodata.py LIB [--old-lib OLD] [--seeds 3] [--max-ticks 3000]

shadow:    learner seats 0 and 5 run a shadow expert "attackTarget <own id>"; gota_seat_orders must label an
           AttackTarget at a non-zero id, distinct per seat. Three experts: plain (selfId), structured reading
           selfId, structured reading self.id (the structured one must also pass reset, not fail "shadow: ...").
package:   a probe package in seat 0 drafts class K only when drafting, draftTurnId = selfId and selfId > 0;
           gota_seat_class(0) must be K.
glue:      the real neural/policy.bas package in seat 0: it learns abilities and shops only with self data,
           so gold spent (start gold + gold earned - gold now, start from an idle seat 1) must be > 0 by the end.
OLD (optional): the pre-fix lib, reported alongside (expected: zero ids, no probe draft, nothing spent).
"""
import argparse, ctypes, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "../../../coworld/gota/runtime"))
from native_env import Env, Lib
import neural_package as npk
from test_defer import model_weights

ATTACK_TARGET = 3
GLUE = open(os.path.join(HERE, "../neural/policy.bas"), "rb").read()
SHADOWS = {
    "plain": "attackTarget(selfId)\n",
    "structured-selfId": "' @gota-structures\nattackTarget(selfId)\n",
    "structured-self.id": "' @gota-structures\nattackTarget(self.id)\n",
}
PROBE = """if drafting then
  if selfId > 0 and draftTurnId = selfId then
    accepted = draftHero(%d)
  end if
  end
end if
acted = gota_act()
"""


def shadow_ids(lib, seed, source, max_ticks):
    """Label object ids of seats 0 and 5 at the first battle decision their shadow labelled, or the reset error."""
    env = Env(lib, learner_seats=[0, 5], max_ticks=max_ticks)
    b = source.encode()
    for seat in (0, 5):
        if env.L.gota_set_seat_shadow(env.h, seat, b, len(b)) != 0:
            return "setter rejected"
    if env.reset(seed) != 0:
        return "reset: " + "; ".join(env.status(s)[1] for s in (0, 5))
    ids = {}
    for _ in range(400):
        env.observe(0x21)
        for seat in (0, 5):
            o = env.orders(seat)
            if seat not in ids and o[7] == ATTACK_TARGET:
                ids[seat] = int(o[8])
        if len(ids) == 2 or env.step(np.zeros((10, 5), np.int32)) == 1:
            break
    env.close()
    return [ids.get(0, 0), ids.get(5, 0)]


def package_run(lib, seed, package, max_ticks):
    """(drafted class, gold spent) of a package in seat 0 after max_ticks; seat 1 idles to give the start gold."""
    env = Env(lib, learner_seats=[], max_ticks=max_ticks)
    assert env.set_package(0, package) == 0 and env.set_script(1, "idle = 0\n") == 0
    assert env.reset(seed) == 0, env.status(0)
    klass = env.L.gota_seat_class(env.h, 0)
    start = None
    while True:
        env.observe(1)
        if start is None:
            start = int(env.stats(1)[16])
        if env.step(np.zeros((10, 5), np.int32)) == 1:
            break
    s = env.stats(0)
    env.close()
    return klass, int(start + s[3] - s[16])


def run(lib_path, seeds, max_ticks, model):
    lib = Lib(lib_path)
    lib.L.gota_seat_class.argtypes = [ctypes.c_void_p, ctypes.c_int]
    out, ok = [], True
    for name, src in SHADOWS.items():
        got = [shadow_ids(lib, seed, src, max_ticks) for seed in range(1, seeds + 1)]
        good = all(isinstance(g, list) and g[0] > 0 and g[1] > 0 and g[0] != g[1] for g in got)
        ok &= good
        out.append("shadow %-19s %s ids=%s" % (name, "PASS" if good else "FAIL", got))
    for k in (9, 3):
        probe = npk.build((PROBE % k).encode(), model)
        got = [package_run(lib, seed, probe, 200)[0] for seed in range(1, seeds + 1)]
        good = all(c == k for c in got)
        ok &= good
        out.append("package probe K=%d       %s classes=%s" % (k, "PASS" if good else "FAIL", got))
    glue = npk.build(GLUE, model)
    got = [package_run(lib, seed, glue, max_ticks) for seed in range(1, seeds + 1)]
    good = all(spent > 0 for _, spent in got)
    ok &= good
    out.append("package glue              %s (class, gold spent)=%s" % ("PASS" if good else "FAIL", got))
    return ok, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lib")
    ap.add_argument("--old-lib")
    ap.add_argument("--seeds", type=int, default=3)
    ap.add_argument("--max-ticks", type=int, default=3000)
    a = ap.parse_args()
    model = model_weights(hidden=64, seed=11, scale=0.05, verb0_bias=0.0)
    ok, lines = run(a.lib, a.seeds, a.max_ticks, model)
    print("\n".join("new: " + l for l in lines))
    if a.old_lib:
        _, lines = run(a.old_lib, a.seeds, a.max_ticks, model)
        print("\n".join("old: " + l for l in lines))
    print("SUMMARY seat_herodata %s" % ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
