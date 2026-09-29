import std/[monotimes, os, times]

type
  TimingError* = object of CatchableError
  RequestPoll* = proc(): bool {.closure.}
  TickPacer* = object
    period: Duration
    deadline: MonoTime
    enabled: bool

proc initTickPacer*(rate: int32): TickPacer =
  ## Selects unlimited speed at zero or a wall-clock tick frequency.
  if rate < 0 or rate > 10000:
    raise newException(TimingError, "Headless tick rate must be 0 .. 10000")
  if rate > 0:
    result.enabled = true
    result.period = initDuration(nanoseconds = 1_000_000_000 div int64(rate))
    result.deadline = getMonoTime() + result.period

proc pace*(pacer: var TickPacer) =
  ## Limits tick speed without changing simulation time or catching up bursts.
  if not pacer.enabled:
    return
  var now = getMonoTime()
  while now < pacer.deadline:
    let remaining = (pacer.deadline - now).inMilliseconds
    sleep(int(clamp(remaining, 1'i64, 50'i64)))
    now = getMonoTime()
  pacer.deadline = max(pacer.deadline + pacer.period, now + pacer.period)

proc waitForRequests*(pollers: openArray[RequestPoll]) =
  ## Polls every seat together until the whole tick's request batch settles.
  while true:
    var pending = false
    for poll in pollers:
      if poll != nil and poll():
        pending = true
    if not pending:
      return
    sleep(1)
