## A match between bot scripts with no window, one action per tick, as the
## Coworld server and the headless recorder play it. The browser replays
## the recorded actions through `applyAction`.
##
## Each seat's script decides on its turn, playing at most one card per
## decision. A decision that plays nothing ends the turn: first every ready
## minion attacks the next living player's hero, one attack per tick, then
## the turn passes. Discards and triggers are answered by the built-in bot
## for whoever must choose, as in the live game.
import sim, sessions, bots, replays

const
  MaxPlaysPerTurn* = 30
    ## A turn ends after this many cards, so a script can't stall a match.

type
  MatchOutcome* = enum
    MatchRunning, MatchWon, MatchDrawn, MatchTimedOut

  BotMatch* = object
    game*: GameState
    bots*: seq[BotVm]  ## One per seat; nil seats pass every turn.
    tick*: uint32  ## Actions taken so far.
    maxTicks*: uint32
    recorder*: ReplayRecorder
    scriptError*: proc(player: int, message: string)
      ## Called when a seat's script fails a decision; the turn passes.
    attackers: seq[int]  ## The acting seat's attacks still to make.
    attackTarget: Choice
    plays: int  ## Cards the acting seat played this turn.

proc applyAction*(game: var GameState, action: ReplayAction): bool =
  ## Applies one recorded action. False when the game refuses it.
  case action.kind
  of ActionPlayCard:
    game.playCard(action.handIndex.int, action.choices.toChoices)
  of ActionAttack:
    action.choices.len == 1 and
      game.attack(action.attacker.int, action.choices[0].toChoice)
  of ActionEndTurn:
    if game.waitingChoice or game.gameOver:
      false
    else:
      game.finishTurn()
      true
  of ActionResolveTrigger:
    game.resolvePendingTrigger(action.choices.toChoices)
  of ActionToss:
    var indices: seq[int]
    for index in action.indices:
      indices.add index.int
    game.resolvePendingToss(indices)
  else:
    false

proc answerAction*(game: GameState): ReplayAction =
  ## The built-in answer to a waiting discard or trigger. If the bot's pick
  ## is refused, it discards its first cards, or declines the trigger's
  ## targets, or takes the first legal ones.
  let player = game.actingPlayer().int32
  var candidates: seq[ReplayAction]
  let preferred = game.nextBotAction()
  case preferred.kind
  of TossAction:
    var indices: seq[int32]
    for index in preferred.tossIndices:
      indices.add index.int32
    candidates.add ReplayAction(kind: ActionToss, indices: indices)
  of ResolveTriggerAction:
    candidates.add ReplayAction(kind: ActionResolveTrigger,
      choices: preferred.choices.toReplay)
  else: discard
  if game.waitingToss:
    var first: seq[int32]
    for index in 0 ..< game.pendingToss.count:
      first.add index.int32
    candidates.add ReplayAction(kind: ActionToss, indices: first)
  if game.waitingTrigger:
    let count = game.waitingTriggerRules().rules.targetCount()
    candidates.add ReplayAction(kind: ActionResolveTrigger,
      choices: newSeq[Choice](count).toReplay)
    for pick in candidates[^1].choices.mitems:
      pick = NoTarget.toReplay
    var picks: seq[Choice]
    for _ in 0 ..< count:
      let choices = game.triggerChoices(picks)
      picks.add(if choices.len > 0: choices[0] else: NoTarget)
    candidates.add ReplayAction(kind: ActionResolveTrigger,
      choices: picks.toReplay)
  for candidate in candidates:
    var trial = game.copyGameState()
    if trial.applyAction(candidate):
      result = candidate
      result.playerId = player
      return
  result = candidates[^1]
  result.playerId = player

proc initBotMatch*(classes: openArray[HeroClass], seed: int64,
    bots: seq[BotVm], maxTicks: uint32,
    recorder: ReplayRecorder = nil): BotMatch =
  BotMatch(game: newGame(classes, seed), bots: bots, maxTicks: maxTicks,
    recorder: recorder)

proc outcome*(match: BotMatch): MatchOutcome =
  if match.game.gameOver:
    if match.game.winner >= 0: MatchWon else: MatchDrawn
  elif match.maxTicks > 0 and match.tick >= match.maxTicks: MatchTimedOut
  else: MatchRunning

proc nextAction(match: var BotMatch): ReplayAction =
  ## Decides and applies the next accepted action.
  template game: untyped = match.game
  while true:
    if game.waitingChoice:
      result = game.answerAction()
      discard game.applyAction(result)
      return
    let current = game.currentPlayer
    if match.attackers.len > 0:
      let attacker = match.attackers[0]
      match.attackers.delete(0)
      result = ReplayAction(kind: ActionAttack, playerId: current.int32,
        attacker: attacker.int32, choices: @[match.attackTarget.toReplay])
      if game.applyAction(result):
        return
      continue  # The attacker or its target is gone: no tick.
    let vm = if current < match.bots.len: match.bots[current] else: nil
    if vm != nil and not vm.failed and match.plays < MaxPlaysPerTurn:
      case vm.runDecision(game)
      of BotPlayedCard:
        # The script played the card itself; record what it did.
        inc match.plays
        return ReplayAction(kind: ActionPlayCard, playerId: current.int32,
          handIndex: vm.playedHand.int32,
          choices: vm.playedChoices.toReplay)
      of BotEndedTurn:
        match.attackers = game.eligibleAttackers()
        match.attackTarget = heroChoice(game.nextPlayer(current))
        match.plays = MaxPlaysPerTurn  # Attack, then end the turn.
        if match.attackers.len > 0:
          continue
      of BotFailed:
        if match.scriptError != nil:
          match.scriptError(current, vm.lastError)
    result = ReplayAction(kind: ActionEndTurn, playerId: current.int32)
    discard game.applyAction(result)
    match.attackers.setLen(0)
    match.plays = 0
    return

proc step*(match: var BotMatch): bool =
  ## Plays one tick. False once the match is over.
  if match.outcome != MatchRunning:
    return false
  var action = match.nextAction()
  discard match.game.takeVisualEvents()
  inc match.tick
  action.tick = match.tick
  match.recorder.record(action)
  match.recorder.recordHash(match.game.stateHash)
  true

proc run*(match: var BotMatch) =
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
