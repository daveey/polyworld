## A match between bot scripts with no window, one action per tick, as the
## Coworld server and the headless recorder play it. The browser replays
## the recorded actions through `applyAction`.
##
## Scripts select every voluntary action, including required choices and
## turn ends. A missing or failed decision stops the match without a fallback.
import sim, bots, replays
export replays.applyAction

type
  MatchOutcome* = enum
    MatchRunning, MatchWon, MatchDrawn, MatchTimedOut, MatchFailed

  BotMatch* = object
    game*: GameState
    bots*: seq[BotVm]  ## One per seat; A missing acting seat stops the match.
    tick*: uint32  ## Actions taken so far.
    maxTicks*: uint32
    recorder*: ReplayRecorder
    scriptError*: proc(player: int, message: string)
      ## Called when a seat fails to supply a legal action.
    failed*: bool  ## No valid explicit action was supplied.

proc initBotMatch*(classes: openArray[HeroClass], seed: int64,
    bots: seq[BotVm], maxTicks: uint32,
    recorder: ReplayRecorder = nil): BotMatch =
  ## Starts a deterministic match with explicit seat-owned policies.
  result = BotMatch(game: newGame(classes, seed), bots: bots, maxTicks: maxTicks,
    recorder: recorder)
  for bot in result.bots:
    bot.ensureSeed(seed)

proc outcome*(match: BotMatch): MatchOutcome =
  if match.failed:
    MatchFailed
  elif match.game.gameOver:
    if match.game.winner >= 0: MatchWon else: MatchDrawn
  elif match.maxTicks > 0 and match.tick >= match.maxTicks: MatchTimedOut
  else: MatchRunning

proc nextAction(match: var BotMatch): ReplayAction =
  ## Runs only the acting seat's script and returns its accepted action.
  let player = match.game.actingPlayer()
  let vm = if player < match.bots.len: match.bots[player] else: nil
  if vm != nil and vm.runDecision(match.game) != BotFailed:
    return vm.action
  match.failed = true
  let message =
    if vm == nil: "No BASIC script for acting player " & $player
    else: vm.lastError
  if match.scriptError != nil:
    match.scriptError(player, message)

proc step*(match: var BotMatch): bool =
  ## Plays one tick. False once the match is over.
  if match.outcome != MatchRunning:
    return false
  var action = match.nextAction()
  if action.kind == 0:
    return false
  discard match.game.takeVisualEvents()
  inc match.tick
  action.tick = match.tick
  if match.recorder != nil:
    match.recorder.record(action)
    match.recorder.recordHash(match.game.stateHash)
  true

proc run*(match: var BotMatch) =
  ## Runs explicit decisions until completion, timeout, or player failure.
  while match.step():
    discard

proc scores*(match: BotMatch): seq[int] =
  ## 1 for the last player standing, 0 for everyone else.
  result = newSeq[int](match.game.playerCount)
  if match.outcome == MatchWon:
    result[match.game.winner] = 1

proc outcomeLabel*(match: BotMatch): string =
  case match.outcome
  of MatchWon: "winner_" & $match.game.winner
  of MatchDrawn: "draw"
  of MatchTimedOut: "timeout"
  of MatchRunning: "running"
  of MatchFailed: "player_failure"
