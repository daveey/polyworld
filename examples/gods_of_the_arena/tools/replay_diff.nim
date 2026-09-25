## Compares two GotA replays: setup, config, first differing tick hash and
## first differing action.  nim r tools/replay_diff.nim A.replay B.replay
import std/[os, strutils], jsony, ../replays

let a = loadReplay(paramStr(1))
let b = loadReplay(paramStr(2))
echo "setup equal: ", a.header.setup == b.header.setup
if a.header.setup != b.header.setup:
  echo "  A setup: ", a.header.setup.toJson()
  echo "  B setup: ", b.header.setup.toJson()
echo "config equal: ", a.config.toJson() == b.config.toJson()
if a.config.toJson() != b.config.toJson():
  echo "  A config: ", a.config.toJson()
  echo "  B config: ", b.config.toJson()
echo "hashes: ", a.hashes.len, " vs ", b.hashes.len
for i in 0 ..< min(a.hashes.len, b.hashes.len):
  if a.hashes[i] != b.hashes[i]:
    echo "first hash mismatch at tick ", i
    break
echo "actions: ", a.actions.len, " vs ", b.actions.len
for i in 0 ..< min(a.actions.len, b.actions.len):
  if a.actions[i] != b.actions[i]:
    echo "first action mismatch #", i
    for j in max(0, i - 3) .. min(i + 3, min(a.actions.len, b.actions.len) - 1):
      echo "  A ", a.actions[j].toJson()
      echo "  B ", b.actions[j].toJson()
    break
