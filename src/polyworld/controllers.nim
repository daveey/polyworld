## Shared human-or-bot slot occupancy for Polyworld games.
##
## `--player:N` marks one 1-based slot as human. Bot files expand into the
## remaining slots in order.

import
  std/strutils,
  cli, configs, policies

when defined(coworld):
  import coworld

type
  ControllerKind* = enum
    BotController
    PlayerController

proc controllerKinds*(
    slotCount: int,
    playerSlot: int32
): seq[ControllerKind] =
  ## Builds one slot map. Slot `playerSlot` is human when it is set.
  result = newSeq[ControllerKind](slotCount)
  if playerSlot == 0:
    return
  if playerSlot < 1 or playerSlot > slotCount:
    fail("--player must be between 1 and " & $slotCount)
  result[playerSlot - 1] = PlayerController

proc isPlayerIndex*(playerSlot: int32, index: int): bool =
  ## Returns whether this 0-based index is the human slot.
  playerSlot > 0 and index == playerSlot - 1

proc localGameConfig*(options: GameOptions, slotCount: int): GameConfig =
  ## Builds the match config with names derived only from local bot files.
  let kinds = controllerKinds(slotCount, options.playerSlot)
  result = GameConfig(
    seed: options.seed,
    maxTicks: options.maximumTicks,
    spawnIntervalTicks: options.spawnIntervalTicks,
    playerSlot: options.playerSlot,
    headlessTickRate: options.headlessTickRate,
    waitForLlm: options.waitForLlm,
    players: unnamedPlayers(slotCount)
  )
  var next = 0
  for group in options.botGroups:
    let name = group.path[group.path.rfind({'/', '\\'}) + 1 .. ^1]
    for _ in 0 ..< group.count:
      while next < kinds.len and kinds[next] == PlayerController:
        inc next
      if next >= kinds.len:
        fail("too many bots to expand")
      result.players[next].name = PlayerConfig(name: name).displayName(next)
      inc next

proc expandBotSources*(
    groups: openArray[BotGroup],
    kinds: openArray[ControllerKind]
): seq[string] =
  ## Loads bot files into bot slots and leaves the human slot empty.
  result.setLen(kinds.len)
  var next = 0
  for group in groups:
    let source =
      when defined(coworld):
        readPlayerSource(group.path)
      else:
        readPolicyBytes(group.path)
    for _ in 0 ..< group.count:
      while next < kinds.len and kinds[next] == PlayerController:
        inc next
      if next >= kinds.len:
        fail("too many bots to expand")
      result[next] = source
      inc next
  when not defined(coworld):
    for i, kind in kinds:
      if kind == BotController and result[i].len == 0:
        fail("bot files do not fill every slot")
