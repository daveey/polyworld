import
  std/[os, strutils],
  tooling

const
  WorkerCount = 8
  LockExclusive = 2

type
  Dependency = object
    name, version, url, revision: string
  SyncJob = object
    index: int
    dependency: Dependency
    cache: string
    latest: bool
  SyncResult = object
    index: int
    entry, error: string

var completed: Channel[SyncResult]

when defined(posix):
  proc flock(fd: cint, operation: cint): cint
      {.importc, header: "<sys/file.h>".}
    ## Locks the dependency cache across independent build processes.

proc sync(job: SyncJob): string =
  ## Resolves one dependency and preserves its detached pinned checkout.
  var dependency = job.dependency
  let
    path = job.cache / dependency.name
    created = not dirExists(path / ".git")
  if created:
    createDir(path.parentDir)
    discard command([
      "git", "clone", "--filter=blob:none", "--no-checkout",
      dependency.url, path
    ])
  else:
    require(
      command([
        "git", "-C", path, "status", "--porcelain", "--untracked-files=no"
      ]).len == 0,
      "Dependency has local modifications: " & path
    )
  if not job.latest and not created and
    command(["git", "-C", path, "rev-parse", "HEAD"]) == dependency.revision:
      return [dependency.name, dependency.version, dependency.url,
        dependency.revision].join(" ")
  if job.latest:
    let fields = command([
      "git", "ls-remote", dependency.url, "HEAD"
    ]).splitWhitespace()
    require(fields.len >= 2, "Unable to resolve HEAD: " & dependency.url)
    dependency.revision = fields[0]
  discard command([
    "git", "-C", path, "fetch", "--depth=1", "origin", dependency.revision
  ])
  discard command([
    "git", "-C", path, "checkout", "--detach", dependency.revision
  ])
  if job.latest:
    for manifest in walkFiles(path / "*.nimble"):
      for line in readFile(manifest).splitLines():
        let assignment = line.split('=', maxsplit = 1)
        if assignment.len == 2 and assignment[0].strip() == "version":
          dependency.version = between(assignment[1], "\"", "\"")
          break
      break
  [dependency.name, dependency.version, dependency.url,
    dependency.revision].join(" ")

proc worker(job: SyncJob) {.thread.} =
  ## Sends one dependency result back without losing worker failures.
  var outcome = SyncResult(index: job.index)
  try:
    outcome.entry = sync(job)
  except CatchableError as error:
    outcome.error = job.dependency.name & ": " & error.msg
  completed.send(outcome)

proc syncDependencies*(latest = false) =
  ## Synchronizes pinned dependencies and optionally updates both lock files.
  let cache = absolutePath(getEnv("POLYWORLD_DEPS", Root / "tmp/coworld/deps"))
  createDir(cache)
  when defined(posix):
    let lock = open(cache / ".sync.lock", fmWrite)
    defer:
      lock.close()
    require(flock(lock.getFileHandle(), LockExclusive) == 0,
      "Unable to lock dependency cache: " & cache)
  else:
    {.error: "Dependency cache locking currently requires POSIX.".}
  var dependencies: seq[Dependency]
  for line in readFile(Root / "coworld/dependencies.lock").splitLines():
    if line.strip().len == 0:
      continue
    let fields = line.splitWhitespace()
    require(fields.len == 4, "Invalid dependency lock entry: " & line)
    require(fields[0].extractFilename() == fields[0] and
      fields[0] notin [".", ".."], "Invalid dependency name: " & fields[0])
    dependencies.add Dependency(
      name: fields[0], version: fields[1], url: fields[2], revision: fields[3]
    )
  var resolved = newSeq[string](dependencies.len)
  completed.open(WorkerCount)
  defer:
    completed.close()
  for start in countup(0, dependencies.high, WorkerCount):
    let count = min(WorkerCount, dependencies.len - start)
    var
      threads: array[WorkerCount, Thread[SyncJob]]
      started = 0
      errors: seq[string]
    try:
      for i in 0 ..< count:
        createThread(threads[i], worker, SyncJob(
          index: start + i, dependency: dependencies[start + i],
          cache: cache, latest: latest
        ))
        inc started
    finally:
      for i in 0 ..< started:
        threads[i].joinThread()
    for i in 0 ..< started:
      let outcome = completed.recv()
      if outcome.error.len > 0:
        errors.add outcome.error
      else:
        resolved[outcome.index] = outcome.entry
        let fields = outcome.entry.splitWhitespace()
        echo fields[0], ": ", fields[3]
    require(errors.len == 0, errors.join("\n"))
  if latest:
    writeFile(Root / "coworld/dependencies.lock", resolved.join("\n") & "\n")
    writeFile(Root / "nimby.lock", resolved.join("\n") & "\n")
  echo "Dependencies ready in ", cache

when isMainModule:
  proc main() =
    ## Parses the dependency update switch for standalone use.
    let args = commandLineParams()
    require(args.len == 0 or args == @["--latest"],
      "Usage: nim r coworld/tools/sync_dependencies.nim [--latest]")
    syncDependencies(args.len == 1)

  runTool(main)
