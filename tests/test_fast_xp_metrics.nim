include ../coworld/fast_xp/metrics

doAssert sizeof(MetricsState) < 10 * 1024 * 1024

let empty = snapshot(60)
doAssert empty["single_request"]["median_ms"].kind == JNull
doAssert empty["recent_games"].len == 0
setCapacity(6)
admissionChanged(1)
schedulerChanged(2, 8, getMonoTime())
requestCompleted(200, 1, 1000, 10, 2, 100)
requestCompleted(200, 10, 2000, 10, 2, 1000)
requestCompleted(429, 0, 1, 0, 0, 0)
cacheLookup(true)
cacheLookup(false)
for i in 0 ..< 110:
  gameCompleted("test", i, i, 28800, 200, 10, 100, 500)
gameCompleted("failed", 0, 202, 28800, 422, -1, 20, 5)
gameCompleted("timeout", 0, 999, 28800, 504, -1, 30, 120000)
gameCompleted("cancelled", 0, 700, 28800, 503, -1, 40, 0)
let full = snapshot(60)
doAssert full["running"].getInt == 2 and full["queued"].getInt == 8
doAssert full["admitted_requests"].getInt == 1
doAssert full["successful_games"].getInt == 110
doAssert full["failed_games"].getInt == 3
doAssert full["timeouts"].getInt == 1
doAssert full["rejected_requests"].getInt == 1
doAssert full["single_request"]["count"].getInt == 1
doAssert full["batch_request"]["count"].getInt == 1
doAssert full["queue"]["count"].getInt == 110
doAssert full["cache_hits"].getInt == full["cache_misses"].getInt
let median = full["single_request"]["median_ms"].getFloat
doAssert median >= 1000 and median < 1250
doAssert full["recent_games"].len == 100
doAssert full["recent_games"][0]["request_id"].getStr == "cancelled"
let expired = snapshotAt(1440, 86460)
doAssert expired["successful_games"].getInt == 0
doAssert expired["recent_games"].len == 0
for i in 0 ..< 20000:
  state.samples[i mod state.samples.len] = Sample(elapsed: i * 5, timestamp: epoch + i * 5,
    cpu: -1, memory: -1, temporaryFree: -1, cacheFree: -1)
  inc state.sampleCount
let bounded = snapshotAt(1440, 99995)
doAssert bounded["samples"].len <= 1441
doAssert bounded["samples"][0]["cpu_percent"].kind == JNull
doAssert bounded["samples"][0]["service_memory_bytes"].kind == JNull
