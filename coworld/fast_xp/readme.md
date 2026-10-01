# Fast XP server

A synchronous Mummy API for Gota. Send `player.source` for BASIC text, `player.package_base64` for a ZIP upload,
and `player.policy_ref` for submitted opponents (exact `name:vN` or version UUID).
The native worker returns a replay and logs only for uploaded seats.

## Run locally

From the Polyworld repository, with pinned dependencies present:

```sh
nix develop .. --command nim c coworld/fast_xp/gota_worker.nim
nix develop .. --command nim c coworld/fast_xp/server.nim
nix develop .. --command ./coworld/fast_xp/server
```

The server binds to localhost by default. To fetch submitted policies, supply
`FAST_XP_OBSERVATORY_TOKEN` in the server environment. Personal team tokens also
need `FAST_XP_OBSERVATORY_ELEVATED=1`; scoped machine credentials do not. Uploaded
bots and the dashboard work without an Observatory credential. The server does
not automatically load the Softmax CLI's saved credentials.
The Nix development shell must include OpenSSL development libraries
(`openssl` in its packages) for the server's HTTPS client.

Open `/docs/llms.txt` for the agent documentation entry point, or read the
[run guide](docs/run.md). `GET /healthz` returns `ok`.

## Configuration

- `FAST_XP_HOST`: bind address, default `127.0.0.1`.
- `FAST_XP_PORT`: port, default `8080`.
- `FAST_XP_WORKERS`: simultaneous game processes, default `2`, range 1–256; the hosted VM uses six. Up to 16 requests may be admitted, using 24 HTTP threads.
- `FAST_XP_TOKEN`: bearer token for callers of this server; required for non-loopback binding.
- `FAST_XP_GOTA_WORKER`: executable path, default `gota_worker` beside server.
- `FAST_XP_OBSERVATORY_URL`: API root, default `https://softmax.com/api/observatory`.
- `FAST_XP_OBSERVATORY_TOKEN`: server-side credential for policy downloads, separate from `FAST_XP_TOKEN`.
- `FAST_XP_OBSERVATORY_ELEVATED`: `1` for personal team tokens, unset for scoped machine credentials.
- `FAST_XP_CACHE_DIR`: private artifact cache, default `$XDG_CACHE_HOME/polyworld-fast-xp/policies` (normally `~/.cache/...`).

The hosted service binds to loopback behind Tailscale Serve and leaves
`FAST_XP_TOKEN` unset; Tailscale controls access. Use a trusted TLS proxy for remote access. The shared fast-XP token does not
identify Observatory users. Policy-reference seats never expose source or logs,
even when the caller owns the policy. The worker inherits only runtime paths,
not the server's credentials.

Each request resolves each distinct selected policy reference once through
Observatory, including on warm-cache requests. Verified artifact bytes are cached
by SHA-256; no credentials, signed URLs or reference-to-source mappings are
persisted. Cache hits are checked against the expected size and hash; corrupt
entries are fetched again. Concurrent requests for the same content share a
download within this server process. Cache directories/files are private to the
local user. Remove the cache directory while the server is stopped to reclaim
space or force cold downloads; there is no automatic eviction yet.

The adapter accepts raw BASIC and production ZIP policy packages up to the
game's 16 MiB package limit. The production loader reads exactly one `.bas` file
and its bundled resources; Gota still limits BASIC source to 64 KiB. Native neural
runners consume the model files without a player container. HTTP fetches have a 10-second socket timeout and do not follow
redirects. Artifact downloads never carry the Observatory authorization headers.

## Dashboard

Open `/` for the dark performance dashboard. `GET /v1/metrics?minutes=60`
returns its JSON data; supported windows are 15, 60 and 1440 minutes. The hosted
service uses Tailscale access, with no additional caller token.

Counters and latency histograms use fixed one-minute buckets, and host samples
are collected every five seconds. Both retain 24 hours in memory, resetting on
restart; the latest 100 game outcomes are retained for at most 24 hours. Chart
responses return at most 1441 host samples. Percentiles are approximate upper
bounds from 25%-wide histogram buckets. Successful single-request, batch-request,
and game durations are separate; failures and timeouts have their own counters.
A batch returning HTTP 200 can still contain failed games.
The latency chart marks each minute with completed games; dashed lines connect
idle gaps for readability. They are not latency measurements during idle time.

Request time excludes client upload/download. Preparation includes policy lookup,
artifact fetching and staging. Game execution includes subprocess startup and
artifact generation, not just simulation ticks. Memory is the service's cgroup
usage, including child workers; CPU is host utilization. Unsupported host counters
appear as unavailable. The EC2 instance type is read from DMI at startup, so it
updates after an instance resize/restart without a hardcoded deployment label.
It is unavailable on local machines or when DMI cannot be read. The dashboard does not alter worker counts or save metrics
to disk. It exposes no policy names, bot contents, logs, credentials or artifact URLs.

## Checks

```sh
nix develop .. --command nim check coworld/fast_xp/server.nim
nix develop .. --command nim r tests/test_fast_xp_metrics.nim
nix develop .. --command nim r tests/test_fast_xp_api.nim
nix develop .. --command nim r tests/test_fast_xp_queue.nim
```

Build both executables first. The Nim API tests run a local mock Observatory/artifact
service, so they need neither a real token nor external network access. The queue
tests use a Nim worker fixture and exercise the real 120-second execution deadline.

For a real full-match cold/warm benchmark, run
`nim r tests/bench_fast_xp.nim --output:/path/to/new-results` inside the Nix
shell, with the same credential environment variables as the server. It runs
three cold/warm pairs and checks repeated replay bytes. Options include
`--repetitions:3`, `--cpu:0`, and `--expected-replay-sha256:HASH` to compare against
a reference from the same game revision; older Gota versions have different replays.

The worker imports the production Gota executable entry point; it shares package
loading, neural runners and scoring rather than maintaining a separate game path.
Build with the committed dependency versions. For an isolated build, set
`POLYWORLD_DEPS` to a dedicated directory and run
`nim r coworld/tools/sync_dependencies.nim` in the workspace Nix shell first.

## Batches, queue and logs

`num_episodes` accepts 1–10 (default 1). Each game increments the seed and rotates
unpinned roster entries; see `/docs/llms.txt` for response layout and partial failures.
One dispatcher assigns games round-robin across ready requests to the fixed worker
pool. Mummy handlers retain request ownership while waiting; game processes never
run on HTTP threads. Shutdown stops admission, cancels queued games, and drains
running games, then gives queued responses five seconds to leave before closing
connections. Drain before planned deploys; allow 180 seconds for service stop.

Structured JSON logs contain request acceptance, game outcomes, and request
completion/errors, correlated by `X-Request-ID`. They include queue, fetch, worker,
ZIP, and total server times. Worker chatter and private contents are not logged.
Player logs keep the production game's existing size limit and are deleted with
temporary match files after the response is built.

The hosted service uses `LogNamespace=fast-xp`, with journald limits of 100 MiB
persistent, 25 MiB runtime and seven days retention. Inspect it with:

```sh
journalctl --namespace=fast-xp -u fast-xp -o cat
journalctl --namespace=fast-xp -u fast-xp -o cat | rg 'REQUEST-ID'
```

Keep these limits in `/etc/systemd/journald@fast-xp.conf.d/limits.conf`; do not
change the host-wide journal configuration. Temporary results are not an archive.
