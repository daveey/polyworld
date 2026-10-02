## Wall-clock region timers for the native env (perf lane). Compiled out
## unless -d:gotaPerfRegions; then `perfRegion` accumulates rdtsc cycles and
## call counts per region in thread-local counters (gota_perf_regions).

type PerfRegionId* = enum
  PrSpawn, PrVision, PrKnown, PrFreeze, PrDecisions, PrScriptObjects,
  PrBasicRun, PrNeuralPrelude, PrCamps, PrFootmen, PrTowers, PrHeroes,
  PrSpells, PrShots, PrCombat, PrSeparate, PrApplyBody, PrFinishTick,
  PrObserve, PrStep

when defined(gotaPerfRegions):
  proc perfRdtsc(): uint64 {.importc: "__rdtsc", header: "<x86intrin.h>".}
  var
    perfCycles* {.threadvar.}: array[PerfRegionId, uint64]
    perfCalls* {.threadvar.}: array[PerfRegionId, uint64]

  template perfRegion*(id: PerfRegionId, body: untyped) =
    let perfStart = perfRdtsc()
    try:
      body
    finally:
      perfCycles[id] += perfRdtsc() - perfStart
      inc perfCalls[id]
else:
  template perfRegion*(id: PerfRegionId, body: untyped) =
    body
