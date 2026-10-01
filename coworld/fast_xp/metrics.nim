import
  std/[json, locks, math, monotimes, os, posix, strutils, times]

type
  Histogram = array[96, uint64]
  Bucket = object
    minute: int64
    singles, batches, queue, worker, preparation, zip: Histogram
    games, failedGames, timeouts, requests, failedRequests, rejected, hits, misses, bytes: uint64
  RecentGame = object
    id: array[64, char]
    index, seed, ticks, status, active: int
    timestamp, queueMs, workerMs: int64
  Sample = object
    elapsed, timestamp: int64
    cpu: float
    memory, temporaryFree, cacheFree: int64
    running, queued, admitted: int
  MetricsState = object
    buckets: array[1440, Bucket]
    samples: array[17280, Sample]
    recent: array[100, RecentGame]
    sampleCount, recentCount: int
    running, queued, admitted, capacity: int
    oldest: int64
    instanceType: array[64, char]

var
  metricsLock: Lock
  state: MetricsState
let
  started = getMonoTime()
  epoch = getTime().toUnix()
initLock(metricsLock)

proc elapsedSeconds(): int64 =
  (getMonoTime() - started).inSeconds

proc currentBucket(): ptr Bucket =
  let minute = elapsedSeconds() div 60
  result = addr state.buckets[minute mod 1440]
  if result[].minute != minute:
    result[] = Bucket(minute: minute)

proc observe(hist: var Histogram, ms: int64) =
  let index = if ms <= 0: 0 else: min(95, 1 + int(ceil(ln(float(ms)) / ln(1.25))))
  inc hist[index]

proc histogramJson(hist: Histogram): JsonNode =
  var count: uint64
  for n in hist: count += n
  result = %*{"count": count, "median_ms": newJNull(), "p95_ms": newJNull()}
  if count == 0: return
  for item in [("median_ms", 0.5), ("p95_ms", 0.95)]:
    var accumulated: uint64
    for i, n in hist:
      accumulated += n
      if float(accumulated) >= ceil(float(count) * item[1]):
        result[item[0]] = %(if i == 0: 0.0 else: pow(1.25, float(i - 1)))
        break

proc setCapacity*(capacity: int) =
  var instanceType: array[64, char]
  try:
    if readFile("/sys/devices/virtual/dmi/id/sys_vendor").strip() == "Amazon EC2":
      let name = readFile("/sys/devices/virtual/dmi/id/product_name").strip()
      for i in 0 ..< min(name.len, instanceType.len): instanceType[i] = name[i]
  except CatchableError: discard
  withLock metricsLock:
    state.capacity = capacity
    state.instanceType = instanceType

proc admissionChanged*(delta: int) =
  withLock metricsLock: state.admitted += delta

proc schedulerChanged*(running, queued: int, oldest: MonoTime) =
  withLock metricsLock:
    state.running = running
    state.queued = queued
    state.oldest = if queued == 0: 0 else: oldest.ticks

proc cacheLookup*(hit: bool) =
  withLock metricsLock:
    let bucket = currentBucket()
    if hit: inc bucket.hits
    else: inc bucket.misses

proc requestCompleted*(status, episodes: int, totalMs, preparationMs, zipMs, bytes: int64) =
  withLock metricsLock:
    let bucket = currentBucket()
    inc bucket.requests
    if status != 200: inc bucket.failedRequests
    if status == 429: inc bucket.rejected
    if status == 200:
      if episodes == 1: bucket.singles.observe(totalMs)
      else: bucket.batches.observe(totalMs)
      bucket.preparation.observe(preparationMs)
      bucket.zip.observe(zipMs)
      bucket.bytes += uint64(bytes)

proc gameCompleted*(id: string, index, seed, ticks, status, active: int, queueMs, workerMs: int64) =
  var record = RecentGame(index: index, seed: seed, ticks: ticks, status: status,
    active: active, timestamp: epoch + elapsedSeconds(), queueMs: queueMs, workerMs: workerMs)
  for i in 0 ..< min(id.len, record.id.len): record.id[i] = id[i]
  withLock metricsLock:
    let bucket = currentBucket()
    if status == 200:
      inc bucket.games
      bucket.queue.observe(queueMs)
      bucket.worker.observe(workerMs)
    else:
      inc bucket.failedGames
      if status == 504: inc bucket.timeouts
    state.recent[state.recentCount mod 100] = record
    inc state.recentCount

proc freeBytes(path: string): int64 =
  var info: Statvfs
  if statvfs(path.cstring, info) == 0:
    return int64(info.f_bavail) * int64(info.f_frsize)
  -1

proc serviceMemory(): int64 =
  try:
    for line in readFile("/proc/self/cgroup").splitLines():
      if line.startsWith("0::"):
        # The root cgroup can describe the entire host, not this service.
        let relative = line[3 .. ^1].strip(chars = {'/'})
        if relative.len > 0 and ".." notin relative.split('/'):
          return parseBiggestInt(readFile("/sys/fs/cgroup" / relative / "memory.current").strip())
  except CatchableError: discard
  -1

proc sampleHost*(previousTotal, previousIdle: var int64) =
  var sample = Sample(elapsed: elapsedSeconds(), timestamp: epoch + elapsedSeconds(),
    cpu: -1, memory: serviceMemory(), temporaryFree: freeBytes(getTempDir()),
    cacheFree: freeBytes(getEnv("FAST_XP_CACHE_DIR", getCacheDir() / "polyworld-fast-xp" / "policies")))
  try:
    let fields = readFile("/proc/stat").splitLines()[0].splitWhitespace()
    var total: int64
    for i in 1 .. 8: total += parseBiggestInt(fields[i])
    let idle = parseBiggestInt(fields[4]) + parseBiggestInt(fields[5])
    if previousTotal > 0 and total > previousTotal:
      sample.cpu = clamp(100.0 * (1.0 - float(idle - previousIdle) / float(total - previousTotal)), 0.0, 100.0)
    previousTotal = total
    previousIdle = idle
  except CatchableError: discard
  withLock metricsLock:
    sample.running = state.running
    sample.queued = state.queued
    sample.admitted = state.admitted
    state.samples[state.sampleCount mod state.samples.len] = sample
    inc state.sampleCount

proc nullable(value: int64): JsonNode =
  if value < 0: newJNull() else: %value

proc snapshotAt(windowMinutes: int, now: int64): JsonNode =
  let minutes = clamp(windowMinutes, 1, 1440)
  var
    buckets: seq[Bucket]
    samples: seq[Sample]
    recent: seq[RecentGame]
    running, queued, admitted, capacity: int
    oldest: int64
    instanceType: array[64, char]
  withLock metricsLock:
    running = state.running
    queued = state.queued
    admitted = state.admitted
    capacity = state.capacity
    oldest = state.oldest
    instanceType = state.instanceType
    for bucket in state.buckets:
      if bucket.minute >= max(0'i64, now div 60 - minutes + 1): buckets.add bucket
    for i in max(0, state.sampleCount - state.samples.len) ..< state.sampleCount:
      let sample = state.samples[i mod state.samples.len]
      if sample.elapsed >= now - int64(minutes * 60): samples.add sample
    for i in countdown(state.recentCount - 1, max(0, state.recentCount - 100)):
      if state.recent[i mod 100].timestamp >= epoch + now - 86400:
        recent.add state.recent[i mod 100]
  var aggregate: Bucket
  var timeline = newJArray()
  # Minute buckets are fixed-size and may be visited in ring order.
  for bucket in buckets:
    for i in 0 ..< 96:
      aggregate.singles[i] += bucket.singles[i]
      aggregate.batches[i] += bucket.batches[i]
      aggregate.queue[i] += bucket.queue[i]
      aggregate.worker[i] += bucket.worker[i]
      aggregate.preparation[i] += bucket.preparation[i]
      aggregate.zip[i] += bucket.zip[i]
    aggregate.games += bucket.games
    aggregate.failedGames += bucket.failedGames
    aggregate.timeouts += bucket.timeouts
    aggregate.requests += bucket.requests
    aggregate.failedRequests += bucket.failedRequests
    aggregate.rejected += bucket.rejected
    aggregate.hits += bucket.hits
    aggregate.misses += bucket.misses
    aggregate.bytes += bucket.bytes
    if bucket.games + bucket.failedGames + bucket.requests > 0:
      timeline.add %*{"timestamp": epoch + bucket.minute * 60,
        "games": bucket.games, "failed_games": bucket.failedGames,
        "queue": histogramJson(bucket.queue), "worker": histogramJson(bucket.worker)}
  var instanceName = ""
  for ch in instanceType:
    if ch == '\0': break
    instanceName.add ch
  result = %*{"instance_type": (if instanceName.len == 0: newJNull() else: %instanceName),
    "timestamp": epoch + now, "uptime_seconds": now, "window_minutes": minutes,
    "running": running, "queued": queued, "admitted_requests": admitted,
    "worker_limit": capacity, "request_limit": 16,
    "oldest_queue_ms": (if queued == 0: 0'i64 else: max(0'i64, (getMonoTime().ticks - oldest) div 1_000_000)),
    "successful_games": aggregate.games, "failed_games": aggregate.failedGames,
    "timeouts": aggregate.timeouts, "requests": aggregate.requests,
    "failed_requests": aggregate.failedRequests, "rejected_requests": aggregate.rejected,
    "games_per_minute": float(aggregate.games) / max(1.0 / 60, float(min(now + 1, int64(minutes * 60))) / 60),
    "cache_hits": aggregate.hits, "cache_misses": aggregate.misses, "response_bytes": aggregate.bytes,
    "single_request": histogramJson(aggregate.singles), "batch_request": histogramJson(aggregate.batches),
    "queue": histogramJson(aggregate.queue), "worker": histogramJson(aggregate.worker),
    "preparation": histogramJson(aggregate.preparation), "zip": histogramJson(aggregate.zip),
    "timeline": timeline, "samples": [], "recent_games": []}
  let stride = max(1, (samples.len + 1439) div 1440)
  for i, sample in samples:
    if i mod stride != 0 and i != samples.high: continue
    result["samples"].add %*{"timestamp": sample.timestamp,
      "cpu_percent": (if sample.cpu < 0: newJNull() else: %sample.cpu),
      "service_memory_bytes": nullable(sample.memory),
      "temporary_free_bytes": nullable(sample.temporaryFree), "cache_free_bytes": nullable(sample.cacheFree),
      "running": sample.running, "queued": sample.queued, "admitted_requests": sample.admitted}
  for game in recent:
    var id = ""
    for ch in game.id:
      if ch == '\0': break
      id.add ch
    result["recent_games"].add %*{"request_id": id, "index": game.index, "seed": game.seed,
      "max_ticks": game.ticks, "status": game.status, "active_bots": game.active,
      "timestamp": game.timestamp, "queue_ms": game.queueMs, "worker_ms": game.workerMs}

proc snapshot*(windowMinutes: int): JsonNode =
  snapshotAt(windowMinutes, elapsedSeconds())
