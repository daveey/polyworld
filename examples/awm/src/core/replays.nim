## AWM's action-only replay format, on Polyworld's shared tape.
##
## A replay holds the match setup (seed and classes), the public match
## config, every accepted game action, and one canonical state hash per
## tick. A tick is one action: a card played, an attack, a discard or
## trigger answered, or a turn ended. It never stores bot source or the
## players' private output.

import std/json
import polyworld/tapes
import sim, sessions

export tapes

const
  ReplayGame* = "awm"
  ReplayFormatVersion* = 1'u16
  ## This client supports only this gameplay version. Bump it when rules
  ## change. Older replays use their archived client.
  ReplayGameVersion* = 1'u16

  MaxReplayActions* = 1_000_000
  MaxReplayHashes* = 1_000_000
  MaxPlayers* = 7

  ActionPlayCard* = 1'u8
  ActionAttack* = 2'u8
  ActionEndTurn* = 3'u8
  ActionResolveTrigger* = 4'u8
  ActionToss* = 5'u8
  ActionKindHigh* = ActionToss

type
  ReplayChoice* = object
    ## A Choice in a flat, portable form.
    kind*: uint8  ## ChoiceKind's ordinal.
    owner*, creatureId*: int32

  Setup* = object
    seed*: int32
    classes*: seq[uint8]  ## One HeroClass ordinal per seat, in seat order.
    maximumTicks*: uint32

  ReplayAction* = object
    tick*: uint32  ## The tick this action completes, from 1.
    playerId*: int32  ## The seat that acted.
    kind*: uint8
    handIndex*: int32  ## PlayCard: the hand card.
    attacker*: int32  ## Attack: the minion's id.
    choices*: seq[ReplayChoice]
      ## PlayCard and ResolveTrigger: one per target. Attack: the target.
    indices*: seq[int32]  ## Toss: the hand cards discarded.

  ReplayHeader* = TapeHeader[Setup]
  ReplayData* = ActionTape[Setup, ReplayAction]
  ReplayRecorder* = TapeRecorder[Setup, ReplayAction]

proc fail(message: string) {.noreturn.} =
  raise newException(ReplayError, message)

proc toReplay*(choice: Choice): ReplayChoice =
  result = ReplayChoice(kind: choice.kind.ord.uint8, owner: choice.owner.int32)
  if choice.kind == CreatureChoice:
    result.creatureId = choice.creatureId.int32

proc toChoice*(choice: ReplayChoice): Choice =
  if choice.kind > ChoiceKind.high.ord.uint8:
    fail("replay choice kind is invalid")
  case ChoiceKind(choice.kind)
  of CanceledChoice: Canceled
  of NoTargetChoice: NoTarget
  of HeroChoice: heroChoice(choice.owner.int)
  of CreatureChoice: creatureChoice(choice.owner.int, choice.creatureId.int)

proc toReplay*(choices: openArray[Choice]): seq[ReplayChoice] =
  for choice in choices:
    result.add choice.toReplay

proc toChoices*(choices: openArray[ReplayChoice]): seq[Choice] =
  for choice in choices:
    result.add choice.toChoice

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

proc heroClasses*(setup: Setup): seq[HeroClass] =
  for value in setup.classes:
    if value > HeroClass.high.ord.uint8:
      fail("replay setup names an unknown class")
    result.add HeroClass(value)

proc initReplayRecorder*(setup: Setup, config: GameConfig): ReplayRecorder =
  ## An in-memory recorder for one match; `config` is its public record.
  result = initTapeRecorder[Setup, ReplayAction](setup,
    ReplayFormatVersion, ReplayGameVersion)
  result.data.config = config

proc record*(recorder: ReplayRecorder, action: ReplayAction) =
  ## Appends one accepted action and checks it names a real seat.
  if recorder == nil:
    return
  if action.kind == 0 or action.kind > ActionKindHigh:
    fail("replay action kind is invalid")
  if action.playerId < 0 or
      action.playerId.int >= recorder.data.header.setup.classes.len:
    fail("replay action names an unknown player")
  recorder.data.actions.appendAction(action, MaxReplayActions)

proc recordHash*(recorder: ReplayRecorder, hash: uint64) =
  recordHash(recorder, hash, MaxReplayHashes)

proc validate*(data: ReplayData) =
  ## Rejects a replay this build can't play back exactly.
  data.header.requireTapeVersion(ReplayFormatVersion, ReplayGameVersion)
  let setup = data.header.setup
  if setup.classes.len notin 2 .. MaxPlayers:
    fail("replay setup has an unsupported player count")
  discard setup.heroClasses()
  data.config.validateConfig(setup.classes.len)
  if data.hashes.len > MaxReplayHashes or data.actions.len > MaxReplayActions:
    fail("replay is too long")
  if setup.maximumTicks > 0 and data.hashes.len.uint64 > setup.maximumTicks:
    fail("replay is longer than its tick limit")
  var tick = 0'u32
  for action in data.actions:
    if action.kind == 0 or action.kind > ActionKindHigh:
      fail("replay action kind is invalid")
    if action.playerId < 0 or action.playerId.int >= setup.classes.len:
      fail("replay action names an unknown player")
    if action.tick != tick + 1:
      fail("replay actions are not one per tick")
    tick = action.tick
  if data.actions.len != data.hashes.len:
    fail("replay actions and hashes do not match")

proc saveReplay*(path: string, data: ReplayData) =
  saveReplayFile(path, ReplayGame, ReplayGameVersion, data,
    DefaultMaxReplayBytes)

proc loadReplay*(path: string): ReplayData =
  result = loadReplayFile(path, ReplayGame, ReplayGameVersion, ReplayData,
    DefaultMaxReplayBytes)
  result.validate()

proc stateHash*(game: GameState): uint64 =
  ## FNV-1a over the game's canonical JSON, without the pending visual
  ## events (only a presentation drains those). The same on every
  ## platform, so a browser replay can check the native recording.
  var node = gameToJson(game)
  node.delete("visualEvents")
  result = 0xcbf29ce484222325'u64
  for character in $node:
    result = (result xor character.ord.uint64) * 0x100000001b3'u64
