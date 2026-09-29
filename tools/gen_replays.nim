## Generates and verifies fresh demo replays under the ignored tmp directory.

import std/[os, osproc, strutils]

const
  Root = currentSourcePath().parentDir.parentDir
  Games = [
    (name: "gota", directory: "gods_of_the_arena", seats: 10),
    (name: "cta", directory: "call_to_adventure", seats: 4),
    (name: "lvd", directory: "light_vs_dark", seats: 2),
    (name: "heartleaf", directory: "heartleaf", seats: 9)
  ]

type PolyworldToolsError = object of CatchableError

proc execute(arguments: openArray[string]) =
  ## Runs a build or game process and fails on any unsuccessful exit.
  let command = quoteShellCommand(arguments)
  echo command
  if execCmd(command) != 0:
    raise newException(PolyworldToolsError, "Command failed: " & command)

proc generate(name, directory: string, seats, ticks: int) =
  ## Checks two independent recordings and verifies every playback tick.
  let
    output = Root / "tmp/replays"
    source = "examples" / directory
    binary = output / (name & ExeExt)
    replay = output / (name & ".replay")
    repeated = output / (name & "-repeat.replay")
    duration =
      # Heartleaf's seek mode records a prefix of its day-based match.
      if ticks > 0 and name == "heartleaf": @["--seek-tick", $ticks]
      elif ticks > 0: @["--ticks", $ticks]
      elif name == "heartleaf": @["--days", "7"]
      else: @["--ticks", "28800"]
    arguments = @[
      binary, "--seed", "2026", "--bot",
      source / "players/base.bas" & ":" & $seats
    ] & duration
  createDir(output)
  execute([
    "nim", "c", "-d:headless", "--nimcache:" & output / "nimcache" / name,
    "-o:" & binary,
    source / (name & ".nim")
  ])
  execute(arguments & @["--record", replay])
  execute(arguments & @["--record", repeated])
  if readFile(replay) != readFile(repeated):
    raise newException(
      PolyworldToolsError,
      name & ": the same seed and players produced different replay bytes"
    )
  removeFile(repeated)
  execute([binary, "--replay", replay])
  echo name, ": identical recordings and verified playback"

setCurrentDir(Root)
var
  selected: seq[string]
  ticks = 0
for argument in commandLineParams():
  if argument.startsWith("--ticks="):
    try:
      ticks = parseInt(argument[8 .. ^1])
    except ValueError:
      raise newException(PolyworldToolsError, "Invalid replay tick count")
    if ticks <= 0 or ticks > int32.high:
      raise newException(PolyworldToolsError, "Replay ticks must fit positive int32")
  else:
    selected.add argument
if selected.len == 0:
  selected = @["gota", "cta", "lvd"]
for name in selected:
  var found = false
  for game in Games:
    if game.name == name:
      found = true
  if not found:
    raise newException(
      PolyworldToolsError,
      "Unknown game: " & name & ". Choose gota, cta, lvd, or heartleaf."
    )
for name in selected:
  for game in Games:
    if game.name == name:
      generate(game.name, game.directory, game.seats, ticks)
