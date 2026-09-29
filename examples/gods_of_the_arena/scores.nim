import content

const
  ScoreName* = "Emmett's Glory"
  TicksPerMinute = int64(TickRate * 60)

proc xpPerMinute*(xp, ticks: int): int =
  ## Returns whole lifetime XP per elapsed minute, or zero before time advances.
  if xp <= 0 or ticks <= 0:
    return 0
  int(int64(xp) * TicksPerMinute div int64(ticks))

proc score*(xp, ticks: int, won: bool): int =
  ## Awards Emmett's Glory only to winners, using whole XP per elapsed minute.
  if won:
    xpPerMinute(xp, ticks)
  else:
    0

proc scores*(
    totalXp: openArray[int], ticks: int, victories: openArray[int]
): seq[int] =
  ## Returns each hero's Emmett's Glory in platform seat order.
  doAssert totalXp.len == victories.len
  for slot, xp in totalXp:
    result.add score(xp, ticks, victories[slot] == 1)
