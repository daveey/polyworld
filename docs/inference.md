# OpenRouter, JEV, and headless time

Gods of the Arena, Light vs Dark, and Call to Adventure share the OpenRouter
host in `src/polyworld/llms.nim`. The game runtime is Nim.
No Python program or subprocess is used for LLM calls.

Each player has one `LlmClient` that owns HTTP requests, BASIC bindings, and
structured oracle state. `oracles.nim` builds JEV payloads and interprets
answers; it has no HTTP client or BASIC runtime dependency. Normal text and
JEV requests use the same client and pending-request limit.

## Time controls

| Control | Default | Behavior |
| --- | --- | --- |
| `--headless-tick-rate N` | `0` | Zero runs freely. Positive values limit wall-clock simulation ticks per second. |
| `--llm-mode async` | `async` | Continue simulation while LLM requests are pending. |
| `--llm-mode barrier` | | Run all due BASIC decisions, then wait for every submitted request to finish or fail before the next tick. |

The rate and barrier controls compose. Barrier mode starts each seat's request
without waiting for earlier seats, then polls all seats together. It waits for
the slowest outstanding request, not the sum of their latencies. A seat that
does not submit a request contributes no wait. Timeouts and HTTP errors settle
the barrier too. The default request timeout is 30 seconds.

On tick T, scripts consume previous replies and submit new requests. The tick
finishes, and the barrier waits while the world remains fixed. Replies are
available at the next scheduled BASIC decision after tick T. BASIC restarts
at its first line each decision with persistent variables. There is no suspended
statement or immediate rerun inside tick T.

These controls affect headless wall-clock scheduling. Physics still uses the
game's fixed 24 Hz simulation clock. A tick rate of 24 approximates real time;
1 allows one simulation tick per wall-clock second. A slow LLM can make a
barrier run slower than that rate. The pacer never runs catch-up bursts.
Graphical playback keeps its existing controls. Replay playback uses recorded
actions and never calls an LLM. Live ranked play permits nondeterministic LLM
replies and completion timing. A repeated live run is not promised to reproduce
the same actions. Replays preserve actions, not the LLM exchanges.

The hosted JSON config uses `headless_tick_rate` and `wait_for_llm`.
Local GotA `--config` accepts the same fields. They are stored in replay
metadata, defaulting to zero and false for older configs.

```json
{
  "headless_tick_rate": 24,
  "wait_for_llm": true
}
```

For a local run, set `COGAME_LLM_MODEL` to an available OpenRouter model and
configure either the sidecar or a local API key. Then, from the repository:

```sh
nim r -d:headless examples/light_vs_dark/lvd.nim \
  --bot:examples/inference/chat.bas:2 --ticks=100 \
  --llm-mode:barrier --headless-tick-rate:24
```

## HTTP transport and normal LLMs

`llms.nim` calls Curly's `startRequest` and `pollForResponse` directly.
Each active player gets a Curly worker on their first request. Submission and
polling do not wait for HTTP responses. Polling happens at decision boundaries
or inside the headless barrier. Curly owns the HTTP handles and buffers.
The host prioritizes `COWORLD_LLM_ENDPOINT`, the existing container
sidecar root, and sends `X-Coworld-Player-Slot` with the zero-based seat index.
It does not send an API key to the sidecar. The sidecar remains responsible for
provider authentication, model availability, spend limits, and accounting.

Without a sidecar, local runs can use `COGAME_LLM_KEY` or
`OPENROUTER_API_KEY`. The default direct root is `https://openrouter.ai/api`;
`COGAME_LLM_BASE_URL` may select that exact HTTPS host and `/api` root
(on the default port or 443), or a local HTTP/HTTPS endpoint. The local host
allowlist is `localhost`, `127.0.0.1`, and `[::1]`, with an optional port.
The same allowlist applies to the sidecar URL. Other hosts, embedded credentials,
query strings, fragments, and encoded hostnames are rejected before a request
can send credentials. Credentials and endpoints come from the host environment,
never from BASIC.

| BASIC call | Result |
| --- | --- |
| `llmAvailable()` | 1 when a native endpoint is configured, otherwise 0. |
| `llmReady()` | 0 when ready, positive remaining spacing ticks, -1 when disabled or pending. |
| `llmAsk(model$, prompt$)` | Request ID for a simple chat message. Empty model uses `COGAME_LLM_MODEL`. |
| `llmRequest(method$, path$, body$)` | Request ID for raw API access under `/v1/`. |
| `llmPoll(id)` | 0 pending, 1 successful, -1 failed or expired. |
| `llmText$(id)` | Ordinary text from completed Chat Completions, Responses, or SSE replies. |
| `llmResponse$(id)` | Complete raw body, or empty while pending. |
| `llmRead$(id, offset, count)` | A zero-based byte slice of the raw body. |
| `llmStatus(id)` | Completed HTTP status, or 0 without one. |
| `llmError$(id)` | Failure message, or empty string for a successful retained reply. |
| `jsonQuote$(value$)` | JSON-escaped string including quotes. |
| `jsonGet$(json$, pointer$)` | Value at an RFC 6901 pointer, text for strings and JSON for other values. |

The raw request body is forwarded unchanged. This lets scripts use model IDs,
message history, tool calls, structured output, provider routing, reasoning,
multimodal JSON content, generation parameters, and other JSON fields without
waiting for a new Nim wrapper. GET, POST, PUT, PATCH, DELETE, and HEAD are
supported. The sidecar must expose the requested route. Tool calls are returned
as JSON for the script to interpret, not executed automatically. Setting
`stream: true` preserves SSE events. Curly's polling API returns the complete
response, so `llmText$` and `llmResponse$` become available after the stream
finishes. Barrier mode also waits until it finishes.

This is bounded JSON/SSE access, not an unbounded file upload API. Multipart
uploads and arbitrary custom headers are not exposed. Requests are limited to
64 KiB. Completed replies exceeding 256 KiB of body or 16 KiB of parsed headers
are rejected before being retained for BASIC. Curly buffers the download before
these checks; these are not transport memory limits. BASIC strings can
hold 64 KiB each, with 1024 string slots and a 256 KiB total string budget per
VM. Temporary strings are reclaimed between decisions. Use `llmRead$` for
larger responses. JSON extraction allows up to 64 nesting levels. Oversized
responses fail with an error instead of silently truncating successful results.

Each seat has one pending request shared by normal LLM and JEV calls, and
retains only its latest completed response. Older request IDs expire when a
new response replaces it. JEV likewise retains only its latest answer set.
Request functions return 0 when busy,
rate-limited, or the body exceeds the request limit. A host deadline settles
the BASIC request and barrier; the seat stays busy until Curly's outstanding
transfer finishes, and its late reply is discarded. Curly's transport timeout
is rounded up to whole seconds. Closing a client waits for that bounded
outstanding transfer before freeing its worker. Host environment controls:

| Variable | Default | Purpose |
| --- | --- | --- |
| `COGAME_LLM` | enabled when configured | `off` disables remote calls. |
| `COGAME_LLM_MODEL` | empty | Default model for `llmAsk`. |
| `COGAME_LLM_INTERVAL` | `1` | Minimum simulation ticks between submissions, 1 through 100000. |
| `COGAME_LLM_TIMEOUT_MS` | `30000` | Whole-request deadline, 1 through 120000 milliseconds. |
| `COGAME_ORACLE` | enabled | `off` disables JEV helpers independently. |
| `COGAME_ORACLE_MODEL` | `typesafe/jev-1.13` | Model for `/v1/systemone`. |

`examples/inference/chat.bas` and `request.bas` demonstrate text and raw JSON.
Native installations need libcurl with asynchronous DNS support. The hosted
Docker image installs libcurl and CA certificates. Browser builds expose the
same function names but remote inference reports unavailable.

## Platform spend and rate limits

The platform documents [spend limits][spend] and [request ceilings][rates].
The league setting `episode_player_pod_llm_spend_limit_usd` is enforced by the
sidecar. An experience request can also impose a per-player budget; the lower
applicable limit wins. Polyworld sends `X-Coworld-Player-Slot` on every sidecar
request, so delegated calls use that seat's accounting and cap. HTTP 429 settles
our request as failed, and BASIC can read the status and original error body.

The platform passes `BEDROCK_SIDECAR_SPEND_LIMIT_USD` to its worker and sidecar.
It is not part of the game application's injected endpoint environment.
Polyworld therefore relies on the sidecar's meter instead of inventing a game
spend variable or duplicating provider-cost accounting. Direct local OpenRouter
calls are outside these hosted caps.

The documented defaults are 30 chat calls per minute per player slot and a
separate 120 System One calls per minute per slot. These are configurable
ceilings, not a universal 30-rpm bucket. The sidecar's `GET /spend`, with the
same `X-Coworld-Player-Slot` header, reports effective limits and spend. This is
a host-side diagnostic; BASIC's raw API access remains confined to `/v1/`.
A spend cutoff lasts for the episode; a rate ceiling clears over time. Keep a
valid fallback action when a call fails. Simulation-tick spacing alone does
not enforce a wall-clock request rate in an unrestricted-speed match.

[spend]: https://github.com/Metta-AI/metta/blob/main/packages/coworld/src/coworld/docs/HOSTED_LLM.md#track-your-spend-and-spend-limit
[rates]: https://github.com/Metta-AI/metta/blob/main/packages/coworld/src/coworld/docs/HOSTED_LLM.md#stay-under-the-request-ceiling
[systemone]: https://github.com/Metta-AI/metta/blob/main/packages/coworld/src/coworld/docs/HOSTED_LLM.md#system-one-models-jev

## JEV structured judgments

`oracles.nim` constructs SystemOne requests directly in Nim. The BASIC draft
API is `oracleState(key$, integer)`, `oracleStateText(key$, text$)`,
`oracleNote(text$)`, `oracleQuestion(key$, kind, instructions$)`,
`oracleCriterion(question$, label$, text$)`, and
`oracleCriterionField(question$, label$, field$, text$)`. State paths support
dotted objects and bounded indices, for example `candidates[0].hp`.

`oracleAsk()` submits the draft to `/v1/systemone` and returns a request ID.
Drafts are cleared after submission and at the next decision. `oracleReady()`
and `oracleAvailable()` mirror the normal LLM helpers. `oraclePoll(id)` returns
zero while pending, the number of usable answers on success, or -1 on failure.
A completed reply with no usable answers fails immediately, including missing,
empty, or invalid `answers`. It does not stay pending. JEV uses the same
`COGAME_LLM_TIMEOUT_MS` deadline as chat, including in barrier mode.

| Question kind | Meaning of `oracleAnswer(id, key$)` |
| --- | --- |
| `0`, noul | Probability of true multiplied by 1000. |
| `1`, score | Score multiplied by 1000. |
| `2`, choice | Zero-based criterion index. |

`oracleConfidence(id, key$)` and
`oracleProbability(id, key$, label$)` return thousandths. Missing values are
-1. Use `llmResponse$` to inspect the original response. There are at most
64 questions, 16 criteria per question, 256 state writes, 4096 state nodes,
16 notes, and 32 KiB of serialized draft JSON. `examples/inference/jev.bas`
demonstrates noul and choice questions.

The current platform [System One contract][systemone] includes `/v1/systemone`
and per-seat attribution with `X-Coworld-Player-Slot`. Legacy-lane episodes
can return HTTP 503 when OpenRouter is unavailable. A particular league's
deployed sidecar still needs to support the route and allow the selected model.

A cassette test replays a saved real HTTP response through the local test
server. Our existing cassette came from direct OpenRouter, so it checks JEV
parsing and BASIC readback through the sidecar-shaped route without paid calls.
It is not a recording from a deployed league sidecar. The tests also verify
that the request uses `/v1/systemone`, includes the player slot, and omits the
API key. They do not certify a deployed sidecar's routing or credentials.

## Manual live JEV test

With `OPENROUTER_API_KEY` set in your shell, run:

```sh
nim r tests/manual_jev.nim
```

This submits exactly one paid request from BASIC directly to OpenRouter's
`/v1/systemone` endpoint, using `typesafe/jev-1.13`. It bypasses sidecar
configuration, asks for a GotA strategy and lane, and checks BASIC's readback
of both choices and the returned model. It prints the original response,
including the request ID, provider, token usage, and reported cost.
There are no retries or fallback answers. This test is never run by CI.

The ordinary test suite uses a local mock, including a captured live JEV
response to verify the same BASIC script without additional paid requests.

## GotA strategy bot

`examples/gods_of_the_arena/players/jev.bas` is a playable strategy example.
Every 15 simulation seconds, each hero sends JEV a text situation report:
the estimated early/mid/late game stage, elapsed time, class and role, health,
mana, level, gold, deaths, position, current plan, god health, home threats,
and observed heroes, creeps, and towers in each lane. The summary uses only
the script's permitted observations. Lane sectors are approximate, and the
creep scan is bounded; missing enemies are not treated as known absences.

Two choice questions ask for a strategy (`farm`, `gank`, `push`, `defend`,
or `regroup`) and a lane (`top`, `mid`, or `bottom`). The bot stores both
answers and follows them between calls. Farming favors lane creeps and last
hits; ganking prioritizes visible heroes; pushing advances toward structures
and the enemy god; defending returns home; regrouping joins allied heroes.
Top and bottom refer to the low-coordinate and high-coordinate outer routes
respectively, for both teams.

Local BASIC handles drafting, ability upgrades, basic attacks, and movement.
It retreats to its spawn room when badly hurt, regardless of JEV's advice.
It starts with a farming plan, continues playing while requests are pending,
keeps its last plan for incomplete replies, and retries failures after five
simulation seconds. This is a macro-strategy example, not the full reference
policy's item, spell, or combat tactics.

With a sidecar exposing `/v1/systemone`, or configured direct access:

```sh
nim r -d:headless examples/gods_of_the_arena/gota.nim \
  --bot:examples/gods_of_the_arena/players/jev.bas:1 \
  --bot:examples/gods_of_the_arena/players/base.bas:9 \
  --ticks=1440 --llm-mode=barrier --headless-tick-rate=24
```

`COGAME_ORACLE_MODEL` selects the JEV model. Each JEV-controlled hero has its
own request and refresh interval. Successful updates print the selected
strategy and lane to that player's log.

## Using LLM responses in chat

The [mailbox API](mailboxes.md) provides communication with routing defined
by each game. GotA supports global, team, and DM chat; LvD supports global
and DM chat; CTA supports global chat within 16 tiles on the same level.
For GotA and LvD, `examples/inference/mailbox_llm.bas` reads a DM, asks an
LLM for a text reply, and sends that reply to the original sender. The
player's unread messages stay queued while its LLM request is pending.
