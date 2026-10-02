import
  std/os,
  tooling

proc main() =
  ## Checks native entrypoints, recording regressions, and complete replays.
  require(paramCount() == 0, "Usage: nim r coworld/tools/verify_native.nim")
  putEnv("POLYWORLD_DEPS", Root / "tmp/coworld/deps")
  let logs = Root / "tmp/coworld/checks"
  createDir(logs)
  for game in Games:
    let source = "examples" / game.directory / (game.name & ".nim")
    for mode in ["desktop", "headless", "coworld"]:
      var args = @["nim", "check", "--hints:on"]
      if mode != "desktop":
        args.add "-d:" & mode
      args.add source
      run(args, logs / (game.name & "-" & mode & ".log"))
    run(
      ["nim", "check", "-d:headless", "-d:" & game.recording,
        "tests/test_recordings.nim"],
      logs / (game.name & "-recording-check.log")
    )
    run(
      ["nim", "r", "-d:headless", "-d:" & game.recording,
        "tests/test_recordings.nim",
        "--bot:examples/" & game.directory & "/players/base.bas:" &
          $game.seats],
      logs / (game.name & "-recording.log")
    )
    run(
      [Root / "tmp/coworld" / (game.name & "-native"), "--replay",
        "tmp/coworld" / (game.name & ".replay")],
      logs / (game.name & "-full-replay.log")
    )
    run(
      ["nim", "c", "-d:coworld", "-o:tmp/coworld/" & game.name, source],
      logs / (game.name & "-build.log")
    )
    echo game.name,
      ": desktop, headless, Coworld, recordings and full replay passed"
  run(["nim", "check", "tests/tests.nim"], logs / "tests-check.log")
  run(["nim", "r", "-d:coworld", "tests/test_annotations.nim"],
    logs / "annotations.log")
  run(["nim", "r", "tests/tests.nim"], logs / "tests.log")

runTool(main)
