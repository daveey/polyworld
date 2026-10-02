#!/usr/bin/env bash
# Builds the AWM Coworld image and plays one episode in it, the way the
# runner does: config, seats and players are staged as local files and
# passed as COGAME_* file URIs. Prints the results; the replay, results and
# every player's private log stay in OUTPUT.
#
#   coworld/awm/tools/run_local.sh [PLAYERS] [OUTPUT] [BOT.bas]
#
# PLAYERS defaults to 4 (2 plays a duel), OUTPUT to tmp/coworld/awm-episode,
# and every seat runs BOT (the bundled baseline by default).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
players="${1:-4}"
output="${2:-$root/tmp/coworld/awm-episode}"
bot="${3:-$root/coworld/awm/players/base.bas}"
image="polyworld-awm-coworld:latest"
if (( players < 2 || players > 7 )); then
  echo "AWM plays 2 to 7 players" >&2
  exit 1
fi

docker compose -f "$root/coworld/awm/compose.yaml" build

mkdir -p "$output"
output="$(cd "$output" && pwd)"
rm -f "$output"/results.json "$output"/failure.json "$output"/status.json \
  "$output"/replay "$output"/player-*
python3 - "$output" "$players" "$bot" <<'EOF'
import hashlib, json, shutil, sys
output, players, bot = sys.argv[1], int(sys.argv[2]), sys.argv[3]
inside = "/episode"
config = {"tokens": [], "players": [], "seed": 2026, "max_ticks": 28800}
seats = []
for slot in range(players):
    shutil.copyfile(bot, f"{output}/player-{slot}")
    source = open(bot, "rb").read()
    config["tokens"].append(f"token-{slot}")
    config["players"].append({"name": f"Baseline {slot}"})
    seats.append({
        "slot": slot,
        "file_uri": f"file://{inside}/player-{slot}",
        "content_hash": "sha256:" + hashlib.sha256(source).hexdigest(),
        "size_bytes": len(source),
        "log_uri": f"file://{inside}/player-{slot}.log",
        "artifact_uri": f"file://{inside}/player-{slot}.zip",
    })
json.dump(config, open(f"{output}/config.json", "w"))
json.dump({"schema": "coworld-player-seats/1", "seats": seats,
           "player_status_uri": f"file://{inside}/status.json"},
          open(f"{output}/seats.json", "w"))
EOF

container="$(docker run -d --platform linux/amd64 -p 8080:8080 \
  -v "$output:/episode" \
  -e COGAME_CONFIG_URI=file:///episode/config.json \
  -e COGAME_PLAYER_SEATS_URI=file:///episode/seats.json \
  -e COGAME_RESULTS_URI=file:///episode/results.json \
  -e COGAME_SAVE_REPLAY_URI=file:///episode/replay \
  -e COGAME_PLAYER_FAILURE_URI=file:///episode/failure.json \
  "$image")"
trap 'docker stop "$container" >/dev/null; docker rm "$container" >/dev/null' EXIT

echo "Playing $players players in $container (health: http://127.0.0.1:8080/healthz)"
until [[ -f "$output/results.json" || -f "$output/failure.json" ]]; do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$container")" != true ]]; then
    docker logs "$container" >&2
    exit 1
  fi
  sleep 1
done
docker logs "$container"
if [[ -f "$output/failure.json" ]]; then
  cat "$output/failure.json" >&2
  exit 1
fi
cat "$output/results.json"
echo
echo "Replay, results and player logs: $output"
