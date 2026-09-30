import std/[locks, os, osproc, streams, strutils]

const
  Root* = currentSourcePath().parentDir.parentDir.parentDir
  Games* = [
    (name: "gota", directory: "gods_of_the_arena", seats: 10,
      recording: "recordGota"),
    (name: "lvd", directory: "light_vs_dark", seats: 6,
      recording: "recordLvd"),
    (name: "cta", directory: "call_to_adventure", seats: 4,
      recording: "recordCta")
  ]

type PolyworldToolsError* = object of CatchableError

var processLock: Lock

proc start(
    args: openArray[string],
    directory: string,
    options: set[ProcessOption]
): Process =
  ## Serializes process creation because osproc temporarily changes the cwd.
  withLock processLock:
    let previous = getCurrentDir()
    try:
      result = startProcess(
        args[0],
        workingDir = directory,
        args = args[1 .. ^1],
        options = options
      )
    finally:
      setCurrentDir(previous)

proc closeCombined(process: Process) =
  ## Closes each distinct pipe once when stderr shares stdout's descriptor.
  process.inputStream.close()
  process.outputStream.close()

proc require*(condition: bool, message: string) =
  ## Reports invalid tool inputs even in release builds.
  if not condition:
    raise newException(PolyworldToolsError, message)

proc command*(args: openArray[string], directory = Root): string =
  ## Captures a command's output and reports unsuccessful exits.
  let process = start(args, directory, {poUsePath, poStdErrToStdOut})
  defer:
    if process.running():
      process.terminate()
      discard process.waitForExit()
    process.closeCombined()
  result = process.outputStream.readAll().strip()
  require(
    process.waitForExit() == 0,
    "Command failed: " & args.join(" ") & "\n" & result
  )

proc run*(args: openArray[string], logPath = "") =
  ## Runs a command with inherited output or a streamed combined log.
  let process = start(
    args,
    Root,
    if logPath.len == 0:
      {poUsePath, poParentStreams}
    else:
      {poUsePath, poStdErrToStdOut}
  )
  defer:
    if process.running():
      process.terminate()
      discard process.waitForExit()
    if logPath.len > 0:
      process.closeCombined()
    else:
      process.close()
  if logPath.len > 0:
    let log = open(logPath, fmWrite)
    defer:
      log.close()
    var buffer: array[8192, char]
    while true:
      let count = process.outputStream.readData(addr buffer[0], buffer.len)
      if count == 0:
        break
      require(log.writeBuffer(addr buffer[0], count) == count,
        "Unable to write command log: " & logPath)
  require(
    process.waitForExit() == 0,
    "Command failed: " & args.join(" ") &
      (if logPath.len > 0: "\nSee " & logPath else: "")
  )

proc between*(source, opening, closing: string): string =
  ## Extracts a required source table or generated string value.
  let start = source.find(opening)
  require(start >= 0, "Missing source marker: " & opening)
  let
    first = start + opening.len
    last = source.find(closing, first)
  require(last >= 0, "Missing closing marker after " & opening)
  source[first ..< last]

proc runTool*(action: proc ()) =
  ## Maps command, parsing, and filesystem failures to the tool exception.
  try:
    action()
  except PolyworldToolsError:
    raise
  except CatchableError as error:
    raise newException(PolyworldToolsError, error.msg, error)

initLock(processLock)
