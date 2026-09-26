#ifndef GOTA_NATIVE_ENV_H
#define GOTA_NATIVE_ENV_H
/* Gods of the Arena native training environment, ABI v1.
 *
 * Built from examples/gods_of_the_arena/native_env.nim as a shared library
 * (see neural_basic.md, "Building the native library"). One handle owns one
 * ten-seat match.
 * Threads (built with --mm:atomicArc --threads:on -d:useMalloc, the documented
 * build): DIFFERENT handles may be called concurrently from different threads;
 * one handle must be used by one thread at a time, but that thread may change
 * between calls, and gota_destroy may run on any thread. Per-world scratch is
 * thread-local; the map, navigation graph and lane globals are built once
 * (first gota_reset, under a process lock) and only read afterwards.
 * Acceptance: tools/test_native_concurrency.py (N threads x M handles give the
 * serial per-step hashes), and tools/test_thread_isolation.py (several
 * worlds per thread over full matches == each world alone; concurrent
 * gota_create). gota_create is thread-safe (it runs under the process lock).
 * World state that one world's tick reads later (vision blockers included)
 * lives in the World, never in per-thread scratch. A --mm:orc build is ~10%
 * faster but single-thread.
 * All handles of a process must use the same map preset (gota_create refuses
 * a second preset).
 *
 * Seats are hero slots 0..9: seats 0..4 are red, 5..9 blue. Every seat is
 * either a LEARNER seat (the caller supplies its actions) or a SCRIPTED seat
 * (any .bas; default players/base.bas). Any mix is allowed on either team:
 * one learner + nine scripts (league-like), ten learners (self-play), or e.g.
 * two learners per team with scripted teammates. Learner seats run the policy
 * glue script (default neural/policy.bas: draft, shopping, ability leveling
 * and buyback from base.bas's routines, then gota_act) exactly as a hosted
 * neural-package seat does; only the network is replaced by the caller.
 *
 * Time. gota_reset plays the draft (BASIC picks) and pauses at the first
 * battle decision. gota_step executes the learner actions at the paused
 * decision tick, then advances decision_period ticks in total (default 4,
 * config "decision_period"; the manifest key of the same name must match) and
 * pauses at the next decision tick, after that tick's cooldowns and vision
 * are updated and its observation frame is frozen, before any seat's BASIC
 * runs (the same point where a hosted neural seat observes). The decoded
 * command is issued once, on the decision tick, when the seat's policy.bas
 * calls gota_act; the engine keeps executing it (paths, attack targets)
 * until the next decision ("held command"); noop issues nothing.
 *
 * Observation contract v1 (GOTA_OBS_SIZE floats per seat, ego-centric, team
 * frame: blue seats see the 180-degree rotated map so both teams share one
 * frame): self 48 | abilities 4x16 | items 6x25 | objects 25x40 | spell
 * warnings 4x8 | summary 16 | terrain 9x9 | goal 16. Exact layout and
 * normalizers: neural_basic.md. The LAST 16 floats are the goal vector w
 * (Amendment 1 order, below) set by gota_set_seat_goal.
 *
 * Action contract v1: five int32 heads per seat, in this order:
 *   verb    8  {0 noop, 1 walk, 2 attackMove, 3 attackTarget, 4 castTarget,
 *               5 castPoint, 6 useItem, 7 useItemAt}
 *   target 25  object slot (0 self, 1-4 allies, 5-9 enemy heroes, 10-16 lane
 *               creeps, 17-20 structures {own god, enemy god, own forward
 *               tower, nearest enemy tower/barracks}, 21-24 neutrals)
 *   point  49  0 = centre; 1 + ring*16 + dir, dir k at k*22.5 degrees
 *               counter-clockwise from team-frame +x. walk/attackMove: centre
 *               self, rings {2, 5, 12} tiles. castPoint/useItemAt: centre the
 *               target slot's object, rings {0.5, 1.25, 2.5} tiles.
 *   ability 4  ability slot (castTarget/castPoint)
 *   item    6  inventory slot (useItem/useItemAt)
 * Out-of-range indices, empty target slots and dead seats decode to noop.
 *
 * Every entry point returns >= 0 on success and -1 for bad arguments (NULL
 * handle, seat out of range, short buffer) unless stated otherwise. Worlds in
 * which nobody calls an optional setter are byte-identical (state hash and
 * replay) to plain BASIC matches with the same scripts. */
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define GOTA_ENV_VERSION 1
#define GOTA_SEATS 10
#define GOTA_OBS_SIZE 1407
#define GOTA_GOAL_SIZE 16
#define GOTA_HEADS 5
#define GOTA_ACTION_OUTPUTS 92 /* 8 + 25 + 49 + 4 + 6 logits */
#define GOTA_STAT_COUNT 24
#define GOTA_ORDER_SIZE 16
#define GOTA_DEFAULT_DECISION_PERIOD 4

/* Goal vector order (Amendment 1); w_reserved must be 0. */
enum {
  GOTA_W_SCORE = 0, GOTA_W_WIN, GOTA_W_XP, GOTA_W_GOLD, GOTA_W_HERO_KILL,
  GOTA_W_ASSIST, GOTA_W_DEATH, GOTA_W_LAST_HIT, GOTA_W_NEUTRAL_KILL,
  GOTA_W_TOWER_DAMAGE, GOTA_W_STRUCTURE_KILL, GOTA_W_HERO_DAMAGE,
  GOTA_W_DAMAGE_TAKEN, GOTA_W_PUSH_DEPTH, GOTA_W_GOD_DAMAGE, GOTA_W_RESERVED
};

/* Static contract facts, for load-time checks. */
int gota_env_version(void);                 /* GOTA_ENV_VERSION */
int gota_observation_size(void);            /* GOTA_OBS_SIZE */
int gota_goal_size(void);                   /* GOTA_GOAL_SIZE */
int gota_action_heads(int32_t *sizes);      /* writes {8,25,49,4,6}; returns 5 */
int gota_stat_count(void);                  /* GOTA_STAT_COUNT */
/* 64 lowercase hex chars + NUL (capacity >= 65). Returns 0. */
int gota_observation_contract_hash(char *out, int32_t capacity);
int gota_action_contract_hash(char *out, int32_t capacity);

/* config_json (UTF-8, NUL-terminated; every key optional):
 *   "config_path":     GotA match config JSON (map preset, spawn interval);
 *                      default = the league preset (presets/ default).
 *   "seed":            match seed of the first episode (default 0).
 *   "max_ticks":       battle ticks per episode, 1..28800 (default 28800).
 *   "decision_period": ticks per gota_step, 1..24 (default 4).
 *   "learner_seats":   array of seat indices (default [0]).
 *   "script_path":     .bas for every scripted seat (default players/base.bas).
 *   "policy_path":     glue .bas for learner seats (default neural/policy.bas).
 *   "data_root":       directory the relative defaults resolve against
 *                      (default: the examples/gods_of_the_arena directory
 *                      compiled into the library).
 *   "record":          record a replay (default false; gota_save_replay).
 *   "capture":         label scripted seats' commands (default true).
 *   "standing_labels": 0 (default, byte-identical), 1 or 2: dense BC labels.
 *                      Each window's label starts as the seat's last
 *                      walk/attackMove/attackTarget re-encoded on the new
 *                      frame (noop once arrived / target gone; 2 = an
 *                      engine-acquired attack target labels attackTarget);
 *                      a command issued in the window overwrites it.
 *                      label[13] = 0 marks a standing label. Override seats
 *                      re-issue it (the standing mapping ceiling).
 * Returns NULL on failure with the reason in error (may be NULL). The match is
 * not started: call gota_reset. */
void *gota_create(const char *config_json, char *error, int32_t capacity);
void gota_destroy(void *handle);

/* Starts a new episode with this match seed (map preset fixed; seed drives
 * draft order, turn order and combat randomness), re-instantiates every
 * seat's BASIC program (persistent variables cleared), zeroes seat stats,
 * plays the draft and pauses at battle tick 1's decision. 0, or -2 when a
 * script failed to compile (see gota_seat_script_status; that seat idles). */
int gota_reset(void *handle, int64_t seed);

/* Learner seat mask (bit s = seat s). Takes effect at the next gota_reset. */
int gota_set_learner_seats(void *handle, uint32_t mask);
uint32_t gota_learner_seats(void *handle);
int gota_seat_team(void *handle, int seat);        /* 0 red, 1 blue */
int gota_seat_class(void *handle, int seat);       /* drafted HeroClass, -1 */
int gota_decision_period(void *handle);

/* Writes the paused decision tick's observation for every seat whose bit is
 * set (learner or scripted: scripted rows are the BC inputs), at row seat of
 * obs[GOTA_SEATS][GOTA_OBS_SIZE]; unselected rows untouched. resets[seat] =
 * 1 when a recurrent actor must zero its state before this inference (first
 * decision of the episode; first alive decision after a death), else 0.
 * acting[seat] = 1 when the seat is alive at this decision frame and the
 * episode is running: for a learner the step will execute its action (0 =
 * dead/respawning, action ignored; a hosted seat does not run its net then);
 * for a scripted seat it marks a valid BC row. Read only. */
int gota_observe_seats(void *handle, uint32_t seats, float *obs, float *resets,
                       float *acting);

/* actions[GOTA_SEATS][GOTA_HEADS]; only learner rows are read. Executes one
 * decision and advances decision_period ticks (fewer when the match ends).
 * rewards[seat] = change in the seat's league score / 1000 over the step
 * (score = lifetime XP - 200 per battle minute, floored at 0, incl. the god
 * kill bonus); terminals[seat] = 1 on the step that ends the episode (god
 * destroyed or max_ticks). Both buffers are float[GOTA_SEATS] and may be NULL.
 * Returns 0 paused at the next decision, 1 episode over (call gota_reset;
 * gota_observe_seats then reports the final frame with acting = 0),
 * -2 already over, -1 bad args. */
int gota_step(void *handle, const int32_t *actions, float *rewards,
              float *terminals);

/* float[8] = {over, winner (0 red, 1 blue, -1 none), draw, time_limit,
 * battle_ticks, red_god_hp, blue_god_hp, total_ticks}. */
int gota_results(void *handle, float *eight);
uint64_t gota_state_hash(void *handle);  /* the replay hash of the current tick */
int32_t gota_battle_tick(void *handle);

/* Training-only per-seat counters, cumulative since gota_reset; reading them
 * never changes the world. int64[GOTA_STAT_COUNT] in this order:
 *  0 score (league score now)      1 outcome (+1 won, -1 lost, 0 running/draw)
 *  2 xp (lifetime XP)              3 gold (gold earned, all sources)
 *  4 hero_kills                    5 assists
 *  6 deaths                        7 last_hits (lane creep killing blows)
 *  8 neutral_kills (killing blows) 9 tower_damage (HP removed from enemy
 *                                     towers and barracks)
 * 10 structure_kills (towers + barracks destroyed, killing blow)
 * 11 hero_damage (HP removed from enemy heroes)
 * 12 damage_taken (HP lost, all sources)
 * 13 push_depth (milli-tiles: deepest team-frame advance past the map centre
 *    line while alive, max(0, .); non-decreasing)
 * 14 god_damage (HP removed from the enemy god)
 * 15 level  16 gold_now  17 team  18 class  19 alive
 * 20 decisions (acting learner decisions)  21 invalid_actions (decoded noop
 *    for an invalid choice)  22 basic_max_instructions  23 reserved (0)
 * Terms 0..14 are goal terms 0..14 (w_score..w_god_damage). */
int gota_seat_stats(void *handle, int seat, int64_t *out);

/* Goal vector w[16] in [-1, 1], w[15] must be 0; appended as the last 16 obs
 * floats of the seat from the next observation on. Kept across gota_reset.
 * Default: w_score = 1, others 0; a package seat (gota_set_seat_package)
 * keeps its manifest goal for its team unless this was called for the seat.
 * -3 = out of range. */
int gota_set_seat_goal(void *handle, int seat, const float *w);

/* Makes the seat SCRIPTED with this BASIC source (removes it from the learner
 * mask). Compiled now under the production limits and re-instantiated on
 * every gota_reset. length 0 restores the default script. Takes effect at the
 * next gota_reset. 0 ok, 1 compile failed (seat idles, as hosted).
 * gota_set_policy_script replaces the learner glue script for all learner
 * seats (length 0 = default neural/policy.bas); 0 ok, 1 compile failed. */
int gota_set_seat_script(void *handle, int seat, const char *source, int32_t length);
int gota_set_policy_script(void *handle, const char *source, int32_t length);
/* 0 learner, 1 scripted and running, 2 compile failed, 3 disabled by a runtime
 * error. Copies the error text when message/capacity given. */
int gota_seat_script_status(void *handle, int seat, char *message, int32_t capacity);

/* BC labels. For a scripted seat: the contract encoding of the commands its
 * script issued during the last gota_step's ticks (the window that started at
 * the frame gota_observe_seats reported before that step; available after the
 * step returns), int32[GOTA_ORDER_SIZE]:
 *  0 labeled (1 if a contract command was issued, else 0 = noop label)
 *  1..5 head indices {verb, target, point, ability, item} (noop: 0s)
 *  6 exact (1 when the decoder reproduces the script's command exactly: same
 *    verb, object id, ability, slot and destination tile; 0 approximate)
 *  7 raw kind (0 none, 1 walkTo, 2 attackMove, 3 attackTarget, 4 castTarget,
 *    5 castPoint, 6 useItem, 7 useItemAt)
 *  8 raw object id  9 raw ability  10 raw item slot
 *  11 raw x milli-tiles, 12 raw y milli-tiles (team frame)
 *  13 commands issued during the step (contract kinds only)
 *  14 decode error in milli-tiles (point verbs), 15 tick of the chosen command
 * Selection when several commands were issued in one step: the first cast or
 * item use (they are instantaneous), else the last movement/attack order.
 * For a learner seat: its own decoded action (labeled = verb != 0).
 * The encoding is computed against the decision frame of the step (the frame
 * gota_observe_seats reported before it). */
int gota_seat_orders(void *handle, int seat, int32_t *out);

/* Mapping ceiling (tools/mapping_ceiling.nim). With enabled = 1 a SCRIPTED
 * seat's contract commands (walkTo .. useItemAt) are not executed: they are
 * encoded as above and the DECODED command is executed on the next decision
 * tick instead, exactly as a learner seat would issue it. Non-contract calls
 * (draft, buyItem, levelAbility, buyback, chat) run normally. Intercepted
 * calls return 1 and leave lastActionError unchanged. Kept across reset.
 * 0 = off (default, byte-identical). */
int gota_set_seat_override(void *handle, int seat, int32_t enabled);

/* DAgger shadow expert. On a LEARNER seat, runs this .bas every tick on the
 * learner's own hero and frames, with every host call that would change the
 * world absorbed (contract commands, buyItem, levelAbility, buyback, draft,
 * chat, mailbox reads): nothing it does executes; the caller's action still
 * does. Its contract commands are labeled exactly as a scripted seat's and
 * gota_seat_orders(seat) then returns those labels instead of the learner's
 * own action. Compiled now (0 ok, 1 compile failed), instantiated at every
 * gota_reset; length 0 = off (default; byte-identical). */
int gota_set_seat_shadow(void *handle, int seat, const char *source, int32_t length);

/* Residual track (Amendment 3): verb 0 becomes DEFER on this LEARNER seat.
 * The seat's BASIC program becomes the script at script_path (relative paths
 * resolve against data_root; NULL or "" = off, the default, byte-identical),
 * compiled under the neural-seat structure limits with the plain-seat
 * per-tick budget (20k instructions; the consult costs none), and run every tick on the seat's
 * own hero as its real program: it observes the true world, drafts, shops,
 * levels abilities and buys back itself (these non-contract calls always
 * execute), and it keeps its own persistent variables. policy.bas glue is
 * not used on this seat.
 * Decision windows. At each decision tick, before the seat's BASIC runs, the
 * learner's action is consulted once:
 *   verb head == 0 (DEFER): every contract command (walkTo .. useItemAt) the
 *     script issues during this window (the decision tick and the following
 *     decision_period - 1 ticks) executes live, at the tick the script issues
 *     it, exactly as on a plain scripted seat. If it issues none, nothing is
 *     issued and the engine keeps the held order.
 *   verb head != 0 (OVERRIDE): the decoded learner command is issued on the
 *     decision tick (invalid choices issue nothing, counted in stats[21]) and
 *     every contract command the script issues during the window is absorbed
 *     shadow-style: not executed, returns 1, lastActionError unchanged.
 * Shadow state under overrides: the script is never paused or re-run; it
 * reads the true world every tick, so after an override window it sees the
 * hero where the learner's command put it, but its own variables may still
 * assume its absorbed orders ran (e.g. "already sent attackTarget(x)") and
 * base.bas mostly issues orders only when they change, so after an override
 * the learner's order stays held until the script issues a new one.
 * A seat that is dead / not acting at the decision frame defers (its action
 * is ignored, as always). An always-defer learner plays byte-identical (state
 * hash, replay commands) to a plain seat running the same script.
 * gota_seat_orders(seat) reports the script's contract commands of the last
 * window (issued or absorbed) as labels, like a shadow expert; setting a
 * defer script clears the seat's gota_set_seat_shadow expert and vice versa.
 * Hosted equivalent: package manifest "decoder": {"defer_script": true}, with
 * policy.bas = the script (e.g. base.bas verbatim); identical semantics, the
 * host consults the network at the same point. Seats without the option keep
 * verb 0 = noop. Takes effect at the next gota_reset. 0 ok, 1 compile failed,
 * -3 unreadable file (gota_last_error), -1 bad args. */
int gota_set_seat_defer_script(void *handle, int seat, const char *script_path);
/* int64[2] = {defer decisions, override decisions} since gota_reset (acting
 * decisions only; zeros for seats without the defer option). */
int gota_seat_defer_stats(void *handle, int seat, int64_t *out);

/* Action validity mask for the paused decision frame of any seat (learner,
 * scripted or package), uint8[GOTA_MASK_SIZE], 1 = allowed:
 *   [GOTA_MASK_VERB + v]      v in 0..7. Verb 0 always 1; 1, 2, 6 are 1 while
 *                             alive; 3, 4, 5, 7 are 1 iff their target row
 *                             (for 4: some ability row) has an allowed slot.
 *   [GOTA_MASK_ABILITY + a]   castTarget with ability a has an allowed target.
 *   [GOTA_MASK_TARGET + r*25 + slot]  target rows r:
 *     0 attackTarget: occupied, not self, a living enemy the hero may attack
 *       (the engine's attack validator: enemy hero/creep/structure/god, a
 *       fighting or resting neutral camp);
 *     1..4 castTarget with ability 0..3: occupied, and the ability is
 *       self-cast or the object is a living, visible spell target of the right
 *       faction (Strike: not own; heal/buff: own);
 *     5 castPoint, 6 useItemAt: occupied (the point anchor).
 * Verbs 0, 1, 2, 6 ignore the target head (all slots allowed). Dead / not
 * acting: only verb 0 is allowed. Range, cooldown, mana and charges are NOT
 * masked (the engine rejects those as action errors, not decode noops).
 * Conditional use (trainer and host): mask verb; then ability by
 * [GOTA_MASK_ABILITY] if verb == 4, else unmasked; then target by the row
 * of (verb, ability); point and item heads are never masked. A decision that
 * follows the mask never decodes to an invalid noop (stats[21] stays 0).
 * Static mode (for trainers that sample heads independently with one mask
 * per head): verb mask as above, ability unmasked, target mask = the union of
 * the rows of the allowed target-reading verbs (3; 4 all abilities; 5; 7).
 * It removes "no valid target at all" invalids but not cross-verb ones (a
 * slot valid for castTarget sampled with attackTarget). Package key
 * "mask_mode": "static" (default "conditional"; needs mask_empty_targets).
 * Hosted equivalent: manifest "decoder": {"mask_empty_targets": true}: the
 * host computes this mask from the same frame and applies it before argmax or
 * sampling, in the order above (sampling still draws one uniform per head in
 * head order, verb..item, so RNG use is unchanged). Default off,
 * byte-identical. For a package seat with the option this returns the mask
 * the host applied. 0 ok, -1 bad args / not paused. */
#define GOTA_MASK_VERB 0
#define GOTA_MASK_ABILITY 8
#define GOTA_MASK_TARGET 12
#define GOTA_MASK_TARGET_ROWS 7
#define GOTA_MASK_SIZE 187 /* 8 + 4 + 7 * 25 */
int gota_action_mask(void *handle, int seat, uint8_t *out);

/* Replays and diagnostics (config "record": true records every tick's hash
 * and command; "capture": false turns BC labeling of scripted seats off for
 * speed). gota_save_replay writes the replay (0, -1 not recording).
 * gota_last_error copies the calling thread's last -3 error text: the error
 * is thread-local, so call it on the thread whose call failed, before that
 * thread makes another call. */
int gota_save_replay(void *handle, const char *path);
int gota_last_error(char *message, int32_t capacity);

/* Hosted-seat parity: installs a neural package (ZIP bytes: manifest.json,
 * policy.bas, model.bin) on the seat; the seat then runs exactly as on the
 * hosted server (network inside the library, argmax or manifest sampling).
 * Makes the seat scripted from the caller's point of view (its actions are
 * ignored). 0 ok, 1 compile failed, 2 package rejected (reason via
 * gota_seat_script_status). Takes effect at the next gota_reset. */
int gota_set_seat_package(void *handle, int seat, const void *zip, int64_t length);

/* Neural actor (neural_actor.nim), bit-identical to the hosted seat, so a
 * trainer can check its FP32 actor against the deployed one (G0 parity).
 * model.bin format GOTANET1 (neural_basic.md). gota_net_load refuses models
 * over 4,000,000 operations per inference; NULL with reason on failure.
 * gota_net_info: int64[8] = {format, inputs, hidden, outputs, heads,
 * state_floats, parameters, operations}. gota_net_infer: observation[inputs],
 * state[state_floats] updated in place, logits[outputs]; 0, -2 nonfinite. */
void *gota_net_load(const void *data, int64_t length, char *error, int32_t capacity);
void gota_net_destroy(void *net);
int gota_net_info(void *net, int64_t *eight);
int gota_net_infer(void *net, const float *observation, float *state, float *logits);

/* Reset to a real state (XR-c, branch daveey/gota-xreq). Re-simulates an
 * uncompressed .replay in playback (hash-checked every tick) until `tick`
 * ticks have run (the state whose hash the replay records at index tick-1),
 * then continues LIVE: `learner_seat` becomes the episode's learner seat
 * (< 0: the configured learner seats) and every other seat runs what the
 * handle configures (package / script / default). The tape after `tick` is
 * ignored: once the learner deviates the recorded actions no longer apply,
 * so the recorded seats (ours included) cannot continue their tapes.
 * Programs start fresh at `tick` (BASIC globals, recurrent state). Not with
 * config record or replay_path. Returns 0, -2 seat compile failure, -3
 * error, -4 tape diverged/ended or tick inside the draft, -5 the replay's
 * map or max_ticks differs from this process's (gota_last_error). The
 * handle is paused at the next decision frame, as after gota_reset.
 * gota_episode_learner_seats: the current episode's learner mask.
 * gota_world_tick: ticks run so far (draft included).
 * gota_replay_hash_at: the loaded replay's recorded hash after `tick` ticks. */
int gota_reset_from_replay(void *handle, const char *replay_path, int32_t tick, int learner_seat);
uint32_t gota_episode_learner_seats(void *handle);
int32_t gota_world_tick(void *handle);
uint64_t gota_replay_hash_at(void *handle, int32_t tick);

/* Behaviour verification (XR-a). gota_decode_heads: the command the seat's
 * current decision frame decodes `heads` (5) into; int32[8] = kind, object
 * id, ability, item, point x, point y (raw fixed), frame tick, isInvalid.
 * gota_seat_commands: replay-mode capture seats, the contract commands the
 * tape issued since the current decision frame began, 7 int32 each (kind,
 * object id, ability, item, point x, point y, tick); returns the count. */
int gota_decode_heads(void *handle, int seat, const int32_t *heads, int32_t *eight);
int gota_seat_commands(void *handle, int seat, int32_t *out, int32_t capacity);

#ifdef __cplusplus
}
#endif
#endif
