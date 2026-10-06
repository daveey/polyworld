## Headless bot matches, their replays, and replay playback.
import std/[os, random, sequtils, unittest]
import ../src/core/[sim, bots, match, replays]

const BaseBot = staticRead("../players/base.bas")

proc classesFor(seats: int, seed: int64): seq[HeroClass] =
  var rng = initRand(seed)
  for _ in 0 ..< seats:
    result.add rng.rand(HeroClass)

proc recordMatch(seats: int, seed: int32, sources: seq[string],
    maxTicks = 28_800'u32): (BotMatch, ReplayData) =
  let classes = classesFor(seats, seed)
  var setup = Setup(seed: seed, maximumTicks: maxTicks)
  for heroClass in classes:
    setup.classes.add heroClass.ord.uint8
  let recorder = initReplayRecorder(setup,
    GameConfig(seed: seed, maxTicks: maxTicks.int32,
      players: unnamedPlayers(seats)))
  var match = initBotMatch(classes, seed, loadBots(sources), maxTicks,
    recorder)
  match.run()
  (match, recorder.data)

proc replayHashes(data: ReplayData): GameState =
  ## Plays a replay back, checking every tick's hash.
  result = newGame(data.header.setup.heroClasses,
    data.header.setup.seed.int64)
  for action in data.actions:
    check result.applyAction(action)
    discard result.takeVisualEvents()
    check result.stateHash == data.hashes[action.tick.int - 1]

suite "bot matches":
  test "every roster size finishes with one winner and replays exactly":
    for seats in 2 .. MaxPlayers:
      let (played, data) = recordMatch(seats, int32(40 + seats),
        newSeq[string](seats).mapIt(BaseBot))
      check played.outcome == MatchWon
      check played.scores.len == seats
      check played.scores[played.game.winner] == 1
      check data.actions.len == played.tick.int
      let replayed = data.replayHashes()
      check replayed.gameOver
      check replayed.winner == played.game.winner

  test "a replay survives the file round trip":
    let (_, data) = recordMatch(3, 7, @[BaseBot, BaseBot, BaseBot])
    let path = getTempDir() / "awm-test.replay"
    saveReplay(path, data)
    let loaded = loadReplay(path)
    removeFile(path)
    check loaded.actions == data.actions
    check loaded.hashes == data.hashes
    check loaded.header.setup == data.header.setup
    discard loaded.replayHashes()

  test "scripts that only end their turn still finish by decking out":
    let (played, data) = recordMatch(2, 3, @["endTurn()\n", "endTurn()\n"])
    check played.outcome == MatchWon
    discard data.replayHashes()

  test "the tick limit ends a match as a timeout":
    let (played, data) = recordMatch(4, 5, newSeq[string](4).mapIt(BaseBot),
      maxTicks = 12)
    check played.outcome == MatchTimedOut
    check played.scores == @[0, 0, 0, 0]
    check data.hashes.len == 12
