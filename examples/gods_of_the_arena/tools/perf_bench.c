/* GotA native-env perf + parity harness (perf lane). Loads libgota via dlopen so one
 * binary drives a baseline and a candidate library identically.
 *
 *   cc -O2 -o perf_bench perf_bench.c -ldl -lpthread
 *
 *   perf_bench digest LIB MODE SEED0 NSEEDS [MAX_TICKS]
 *       Plays NSEEDS full matches (seeds SEED0..) and prints one line per seed:
 *       "seed S ticks T steps N final=HASH digest=D". D folds, every step, the
 *       tick state hash (gota_state_hash), every seat's observation row (1407
 *       floats, bit patterns), resets/acting, rewards/terminals, seat stats and
 *       seat orders (BC labels). Two libraries are byte-identical for a mode iff
 *       every line matches.
 *   perf_bench run LIB MODE SEED STEPS   one world, STEPS decisions (profiling)
 *   perf_bench bench LIB MODE WORKERS WORLDS SECONDS {threads|procs}
 *       Trainer layout: WORKERS threads (or forked processes), each owning WORLDS
 *       handles, observe(learner rows) + step with seeded random actions for
 *       SECONDS. Prints aggregate world-steps/s (one step = decision_period ticks).
 *
 * MODE: scripted (no learner seats, 10 x base.bas), learner1 (seat 0 learner with
 * random actions, 9 x base.bas), learner10 (10 learner seats), defer1 (seat 0
 * learner deferring to players/base.bas, random actions).
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define SEATS 10
#define OBS 1407
#define HEADS 5
#define STATS 24
#define ORDERS 16

typedef void *(*create_f)(const char *, char *, int32_t);
typedef void (*destroy_f)(void *);
typedef int (*reset_f)(void *, int64_t);
typedef int (*observe_f)(void *, uint32_t, float *, float *, float *);
typedef int (*step_f)(void *, const int32_t *, float *, float *);
typedef uint64_t (*hash_f)(void *);
typedef int32_t (*tick_f)(void *);
typedef int (*stats_f)(void *, int, int64_t *);
typedef int (*orders_f)(void *, int, int32_t *);
typedef int (*defer_f)(void *, int, const char *);
typedef int (*regions_f)(uint64_t *, uint64_t *, int);

static create_f g_create; static destroy_f g_destroy; static reset_f g_reset;
static observe_f g_observe; static step_f g_step; static hash_f g_hash;
static tick_f g_tick; static stats_f g_stats; static orders_f g_orders; static defer_f g_defer;
static regions_f g_regions;
static const int head_sizes[HEADS] = {8, 25, 49, 4, 6};

static void load(const char *path) {
  void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); exit(2); }
#define SYM(v, n) v = dlsym(h, n); if (!v) { fprintf(stderr, "missing %s\n", n); exit(2); }
  SYM(g_create, "gota_create"); SYM(g_destroy, "gota_destroy"); SYM(g_reset, "gota_reset");
  SYM(g_observe, "gota_observe_seats"); SYM(g_step, "gota_step"); SYM(g_hash, "gota_state_hash");
  SYM(g_tick, "gota_battle_tick"); SYM(g_stats, "gota_seat_stats"); SYM(g_orders, "gota_seat_orders");
  g_defer = dlsym(h, "gota_set_seat_defer_script");
  g_regions = dlsym(h, "gota_perf_regions");
  if (g_regions) { uint64_t a[64], b[64]; if (g_regions(a, b, 64) == 0) g_regions = NULL; }
}

static uint32_t mode_mask(const char *mode) {
  if (!strcmp(mode, "scripted")) return 0;
  if (!strcmp(mode, "learner1") || !strcmp(mode, "defer1")) return 1;
  if (!strcmp(mode, "learner10")) return 0x3ff;
  fprintf(stderr, "bad mode %s\n", mode); exit(2);
}

static void *make_world(const char *mode, int64_t seed, int max_ticks, int capture) {
  uint32_t mask = mode_mask(mode);
  char cfg[512], seats[128] = "[";
  for (int s = 0; s < SEATS; s++) if (mask & (1u << s)) {
    char b[8]; snprintf(b, sizeof b, "%s%d", seats[1] ? "," : "", s); strcat(seats, b);
  }
  strcat(seats, "]");
  snprintf(cfg, sizeof cfg, "{\"seed\":%lld,\"max_ticks\":%d,\"learner_seats\":%s,\"capture\":%s}",
           (long long)seed, max_ticks, seats, capture ? "true" : "false");
  char err[512] = {0};
  void *w = g_create(cfg, err, sizeof err);
  if (!w) { fprintf(stderr, "create failed: %s\n", err); exit(3); }
  if (!strcmp(mode, "defer1")) {
    if (!g_defer || g_defer(w, 0, "players/base.bas") != 0) { fprintf(stderr, "defer setup failed\n"); exit(3); }
  }
  return w;
}

static inline uint64_t splitmix(uint64_t *s) {
  uint64_t z = (*s += 0x9E3779B97F4A7C15ull);
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
  return z ^ (z >> 31);
}

static inline uint64_t fold(uint64_t h, const void *p, size_t n) { /* FNV-1a 64 */
  const unsigned char *b = p;
  for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 0x100000001b3ull; }
  return h;
}

static void random_actions(uint32_t mask, uint64_t *rng, int32_t *acts) {
  memset(acts, 0, sizeof(int32_t) * SEATS * HEADS);
  for (int s = 0; s < SEATS; s++) if (mask & (1u << s))
    for (int h = 0; h < HEADS; h++) acts[s * HEADS + h] = (int32_t)(splitmix(rng) % head_sizes[h]);
}

static int digest(const char *mode, int64_t seed0, int nseeds, int max_ticks) {
  uint32_t mask = mode_mask(mode);
  float *obs = malloc(sizeof(float) * SEATS * OBS);
  float resets[SEATS], acting[SEATS], rewards[SEATS], terms[SEATS];
  int32_t acts[SEATS * HEADS], orders[ORDERS]; int64_t stats[STATS];
  for (int k = 0; k < nseeds; k++) {
    int64_t seed = seed0 + k;
    void *w = make_world(mode, seed, max_ticks, 1);
    if (g_reset(w, seed) != 0) { fprintf(stderr, "reset failed seed %lld\n", (long long)seed); return 3; }
    uint64_t rng = 0x5eed0000ull + (uint64_t)seed, d = 0xcbf29ce484222325ull, hs;
    long steps = 0; int rc = 0;
    while (1) {
      memset(obs, 0, sizeof(float) * SEATS * OBS);
      g_observe(w, 0x3ff, obs, resets, acting);
      d = fold(d, obs, sizeof(float) * SEATS * OBS);
      d = fold(d, resets, sizeof resets); d = fold(d, acting, sizeof acting);
      hs = g_hash(w); d = fold(d, &hs, 8);
      if (rc == 1) break;
      random_actions(mask, &rng, acts);
      rc = g_step(w, acts, rewards, terms);
      if (rc < 0) { fprintf(stderr, "step rc %d seed %lld\n", rc, (long long)seed); return 4; }
      steps++;
      d = fold(d, rewards, sizeof rewards); d = fold(d, terms, sizeof terms);
      for (int s = 0; s < SEATS; s++) {
        g_stats(w, s, stats); d = fold(d, stats, sizeof stats);
        g_orders(w, s, orders); d = fold(d, orders, sizeof orders);
      }
    }
    printf("%s seed %lld ticks %d steps %ld final=%016llx digest=%016llx\n", mode, (long long)seed,
           g_tick(w), steps, (unsigned long long)g_hash(w), (unsigned long long)d);
    fflush(stdout);
    g_destroy(w);
  }
  free(obs);
  return 0;
}

typedef struct { const char *mode; int worlds; double seconds; int id; long steps; double elapsed; } job_t;

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }

static void *bench_worker(void *arg) {
  job_t *j = arg;
  uint32_t mask = mode_mask(j->mode);
  void **ws = malloc(sizeof(void *) * j->worlds);
  int64_t next_seed = 1000 + 100000ll * j->id;
  for (int k = 0; k < j->worlds; k++) {
    ws[k] = make_world(j->mode, next_seed, 28800, 0);
    g_reset(ws[k], next_seed++);
  }
  float *obs = malloc(sizeof(float) * SEATS * OBS);
  float resets[SEATS], acting[SEATS], rewards[SEATS], terms[SEATS];
  int32_t acts[SEATS * HEADS];
  uint64_t rng = 99 + j->id;
  long steps = 0; double t0 = now(), t;
  do {
    for (int k = 0; k < j->worlds; k++) {
      if (mask) g_observe(ws[k], mask, obs, resets, acting);
      random_actions(mask, &rng, acts);
      if (g_step(ws[k], acts, rewards, terms) == 1) g_reset(ws[k], next_seed++);
      steps++;
    }
    t = now();
  } while (t - t0 < j->seconds);
  j->steps = steps; j->elapsed = t - t0;
  for (int k = 0; k < j->worlds; k++) g_destroy(ws[k]);
  free(ws); free(obs);
  return NULL;
}

static int bench(const char *mode, int workers, int worlds, double seconds, const char *kind) {
  long total = 0; double el = 0;
  if (!strcmp(kind, "threads")) {
    pthread_t th[256]; job_t jobs[256];
    for (int i = 0; i < workers; i++) {
      jobs[i] = (job_t){mode, worlds, seconds, i, 0, 0};
      pthread_create(&th[i], NULL, bench_worker, &jobs[i]);
    }
    for (int i = 0; i < workers; i++) { pthread_join(th[i], NULL); total += jobs[i].steps; el += jobs[i].elapsed; }
  } else {
    int fds[256][2]; pid_t pids[256];
    for (int i = 0; i < workers; i++) {
      if (pipe(fds[i])) return 5;
      pids[i] = fork();
      if (pids[i] == 0) {
        job_t j = {mode, worlds, seconds, i, 0, 0};
        bench_worker(&j);
        if (write(fds[i][1], &j, sizeof j) != sizeof j) _exit(1);
        _exit(0);
      }
    }
    for (int i = 0; i < workers; i++) {
      job_t j; if (read(fds[i][0], &j, sizeof j) != sizeof j) return 6;
      waitpid(pids[i], NULL, 0); total += j.steps; el += j.elapsed;
    }
  }
  double rate = total / (el / workers);
  printf("bench mode=%s kind=%s workers=%d worlds=%d seconds=%.1f steps=%ld world_steps_per_s=%.1f per_worker=%.1f\n",
         mode, kind, workers, worlds, el / workers, total, rate, rate / workers);
  return 0;
}

static int run_steps(const char *mode, int64_t seed, long nsteps) {
  /* one world, nsteps decisions (resets on episode end); for profilers */
  uint32_t mask = mode_mask(mode);
  void *w = make_world(mode, seed, 28800, 0);
  g_reset(w, seed);
  float *obs = malloc(sizeof(float) * SEATS * OBS);
  float resets[SEATS], acting[SEATS], rewards[SEATS], terms[SEATS];
  int32_t acts[SEATS * HEADS]; uint64_t rng = 7;
  double t0 = now();
  for (long i = 0; i < nsteps; i++) {
    if (mask) g_observe(w, mask, obs, resets, acting);
    random_actions(mask, &rng, acts);
    if (g_step(w, acts, rewards, terms) == 1) g_reset(w, ++seed);
  }
  double el = now() - t0;
  printf("run mode=%s steps=%ld seconds=%.2f tick=%d\n", mode, nsteps, el, g_tick(w));
  if (g_regions) {
    static const char *names[] = {"spawn", "vision(incl known)", "known_buildings", "freeze_obs", "decisions(all bots)",
      "script_objects(rebuild)", "basic_run", "neural_prelude(obs)", "camps", "footmen", "towers", "heroes", "spells",
      "tower_shots", "combat", "separate", "apply_body", "finish_tick", "observe(api)", "step(api, all ticks)"};
    uint64_t cyc[64], calls[64];
    int n = g_regions(cyc, calls, 64);
    double total = (double)cyc[19];
    for (int i = 0; i < n && i < 20; i++)
      printf("region %-26s %6.2f%% of step  %9.1f us/step  calls/step %9.1f\n", names[i], 100.0 * cyc[i] / total,
             el * 1e6 / nsteps * cyc[i] / total, (double)calls[i] / nsteps);
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 4) { fprintf(stderr, "usage: see header\n"); return 2; }
  load(argv[2]);
  if (!strcmp(argv[1], "digest") && argc >= 6)
    return digest(argv[3], atoll(argv[4]), atoi(argv[5]), argc > 6 ? atoi(argv[6]) : 28800);
  if (!strcmp(argv[1], "run") && argc >= 6)
    return run_steps(argv[3], atoll(argv[4]), atol(argv[5]));
  if (!strcmp(argv[1], "bench") && argc >= 8)
    return bench(argv[3], atoi(argv[4]), atoi(argv[5]), atof(argv[6]), argv[7]);
  fprintf(stderr, "bad args\n");
  return 2;
}
