#!/usr/bin/env bash
# No-neural-seat parity against upstream (item 5a): for SEEDS full-length matches with a mixed
# base/puller/rusher lineup, (1) this fork's headless binary and upstream/main's headless binary
# must write byte-identical replays (every tick's state hash plus every action), and (2) the native
# training library with the same lineup and no neural seats (capture on) must record a replay that
# upstream/main's binary verifies tick for tick and that ends on the same final hash.
# Usage: parity_upstream.sh WORKDIR FORK_REV UPSTREAM_REV [SEEDS] [JOBS]   (POLYWORLD_DEPS set)
set -euo pipefail
W=$1; FORK=$2; UP=$3; SEEDS=${4:-20}; JOBS=${5:-16}
SRC=$(git rev-parse --show-toplevel)
rm -rf "$W" && mkdir -p "$W"/{fork,up,out}
git -C "$SRC" archive "$FORK" | tar -x -C "$W/fork"
git -C "$SRC" archive "$UP" | tar -x -C "$W/up"
FLAGS="--hints:off -d:release -d:headless"
(cd "$W/up" && nim c $FLAGS --nimcache:"$W/nc-up" -o:"$W/gota_up" examples/gods_of_the_arena/gota.nim) &
(cd "$W/fork" && nim c $FLAGS --nimcache:"$W/nc-fk" -o:"$W/gota_fork" examples/gods_of_the_arena/gota.nim) &
(cd "$W/fork" && nim c $FLAGS --app:lib -d:gotaTrainingStats --mm:atomicArc --threads:on -d:useMalloc -u:nimTypeNames \
   --nimcache:"$W/nc-lib" -o:"$W/libgota_env.so" examples/gods_of_the_arena/native_env.nim) &
wait
P=examples/gods_of_the_arena/players
LINEUP="--bot $P/base.bas:4 --bot $P/puller.bas:3 --bot $P/rusher.bas:3"
run() {
  s=$1
  (cd "$W/up" && "$W/gota_up" $LINEUP --seed "$s" --record "$W/out/up-$s.replay" > "$W/out/up-$s.log" 2>&1)
  (cd "$W/fork" && "$W/gota_fork" $LINEUP --seed "$s" --record "$W/out/fork-$s.replay" > "$W/out/fork-$s.log" 2>&1)
  (cd "$W/fork" && python3 - "$W" "$s" <<'PY' > "$W/out/native-$s.log" 2>&1
import sys, numpy as np
W, s = sys.argv[1], int(sys.argv[2])
sys.path.insert(0, W + "/fork/examples/gods_of_the_arena/tools")
from native_env import Env, Lib
P = W + "/fork/examples/gods_of_the_arena/players/"
env = Env(Lib(W + "/libgota_env.so"), learner_seats=[], record=True, capture=True)
for seat in range(10):
    name = "base" if seat < 4 else "puller" if seat < 7 else "rusher"
    assert env.set_script(seat, open(P + name + ".bas").read()) == 0
env.reset(s)
while env.step(np.zeros((10, 5), np.int32)) == 0:
    pass
print("final_hash %016x" % env.state_hash())
assert env.save_replay(W + "/out/native-%d.replay" % s) == 0
PY
  )
  vrc=0; (cd "$W/up" && "$W/gota_up" --replay "$W/out/native-$s.replay" > "$W/out/verify-$s.log" 2>&1) || vrc=$?
  same=$(cmp -s "$W/out/up-$s.replay" "$W/out/fork-$s.replay" && echo yes || echo no)
  uph=$(grep -o 'hash: [0-9A-Fa-f]*' "$W/out/up-$s.log" | awk '{print tolower($2)}')
  nh=$(grep -o 'final_hash [0-9a-f]*' "$W/out/native-$s.log" | awk '{print $2}')
  vh=$(grep -o 'hash: [0-9A-Fa-f]*' "$W/out/verify-$s.log" | awk '{print tolower($2)}')
  mism=$(grep -o 'replay hashes: [0-9]* mismatches' "$W/out/verify-$s.log" || true)
  ver=0; [[ $vrc -eq 0 && -z "$mism" && "$vh" == "$uph" && "$nh" == "$uph" ]] && ver=1
  echo "seed=$s fork_replay_identical=$same upstream_final=$uph native_final=$nh replayed_final=$vh native_verified_by_upstream=$ver $mism"
}
export -f run; export W LINEUP
seq 1 "$SEEDS" | xargs -P "$JOBS" -I{} bash -c 'run {}' | sort -t= -k2 -n | tee "$W/parity.txt"
echo "identical_replays=$(grep -c 'fork_replay_identical=yes' "$W/parity.txt")/$SEEDS"
echo "native_verified=$(grep -c 'native_verified_by_upstream=1' "$W/parity.txt")/$SEEDS"
