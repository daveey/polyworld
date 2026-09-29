' Heartleaf reference villager.
'
' You are one villager in a nine-house village. Every decision runs from the
' top of this file with a fresh instruction budget, once per game minute.
' Globals and arrays survive between decisions; registers do not.
'
' THE WEEK. Days run 9:00 to 21:00. Every morning each of the 27 gardens
' grows one vegetable. At exactly 18:00 every house holds its dinner tally:
' if the owner is inside with at least one visitor, the owner banks
' (items carried) x (visitor count), then the pantry feeds everyone present
' for three bite rounds - a vegetable you have never tasted is worth 3,
' a repeat 1. Hosting empties your bag. Anyone alone, or outside, scores
' nothing that night. Be inside your own house by 21:00 or lose 3 points.
' Highest total after the last day wins.
'
' READ-ONLY VALUES
'   selfSlot worldTick day dayCount minuteOfDay dinnerDone
'   myX myY inHouse carried hosting acceptedHost orderKind orderTarget
'   score villagerTotal gardenTotal decisionPeriod
' minuteOfDay counts minutes since midnight: 540 is 9:00, 1080 is 18:00.
' inHouse is the house you are inside, or -1 outdoors.
' orderKind: 0 idle, 1 walking, 2 gathering, 3 heading home, 4 talking.
'
' QUERIES
'   invOf(v) eatenOf(v)                    your bag and your palate
'   gardenX(i) gardenY(i) gardenVeggie(i)  gardenVeggie is -1 when bare
'   nearestStockedGarden() nearestWinnableGarden()  garden id or -1
'   gardenOutpaced(i)                      another gatherer leads by 3+ tiles
'   villagerX(s) villagerY(s) villagerInHouse(s) villagerHosting(s)
'   villagerCarried(s) villagerScore(s) inviteFrom(s)
'   talkingTo(s) socialAvailable(s) socialGroupSize(s) inMyConversation(s) sameConversation(a, b)
'   doorX(h) doorY(h) occupants(h)
'   distTo(x, y) distance(x1, y1, x2, y2) tilePassable(x, y)
'
' COMMANDS, all return 1 when accepted and 0 when refused.
'   walkTo(x, y)   gather(gardenId)  invite(s)   accept(s)   decline(s)
'   enterHouse(h)  exitHouse()       cancel()    orderFailed()
'   talk(s)        offer or join a nearby conversation, up to four gnomes
' invite needs both of you outdoors within 3 tiles, and declares you a host.
' Entering a house hides you from the map until you exitHouse().
'
' THE PLAYBOOK. Gather all day; three villagers are due to host each night
' by rotation; guests walk to the nearest due host; never be alone at six.

dim invitedMark(8)
dim avoidUntil(8)

' A small counter generator of our own, seeded by slot, so each villager
' wanders and pauses on their own rhythm. call rnd(n) leaves the next
' draw, 0..n-1, in rndOut.
if rngState = 0 then
  rngState = selfSlot * 7919 + 17
end if
sub rnd(n)
  rngState = (rngState * 75 + 74) mod 65537
  rndOut = rngState mod n
end sub

' Count outdoor company without treating hidden house occupants as a crowd.
sub company(x, y)
  neighbors = 0
  other = 0
  while other < villagerTotal
    if other <> selfSlot and villagerInHouse(other) < 0 then
      if distance(x, y, villagerX(other), villagerY(other)) <= 4 then
        neighbors = neighbors + 1
      end if
    end if
    other = other + 1
  wend
end sub

sub canMeet(candidate)
  meetAllowed = 1
  member = 0
  while member < villagerTotal
    if member <> selfSlot and worldTick < avoidUntil(member) then
      if sameConversation(candidate, member) = 1 then
        meetAllowed = 0
      end if
    end if
    member = member + 1
  wend
end sub

sub beginChat(peer)
  call canMeet(peer)
  r = 0
  if meetAllowed = 1 then
    r = talk(peer)
  end if
  if r = 1 then
    call rnd(289)
    chatUntil = worldTick + 288 + rndOut
    social = -1
    wandering = 0
    engaged = 1
    aloneSince = worldTick
  end if
end sub

sub leaveGroup()
  tries = 0
  while tries < 12
    call rnd(21)
    x = leaveX + rndOut - 10
    call rnd(21)
    y = leaveY + rndOut - 10
    d = distance(x, y, leaveX, leaveY)
    call company(x, y)
    if d >= 8 and d <= 10 and tilePassable(x, y) = 1 and neighbors <= 1 then
      r = walkTo(x, y)
      if r = 1 then
        tries = 12
      end if
    end if
    tries = tries + 1
  wend
end sub

sub leisure()
  f = orderFailed()
  engaged = 0
  g = nearestWinnableGarden()
  if orderKind = 2 then
    if worldTick >= harvestCheck then
      harvestCheck = worldTick + 48
      if gardenOutpaced(orderTarget) = 1 then
        r = cancel()
      end if
    end if
  else
    if g >= 0 then
      r = gather(g)
      wandering = 0
      leisureReady = 0
      social = -1
      leaving = 0
    else
      if orderKind = 4 then
        peer = 0
        while peer < villagerTotal
          if inMyConversation(peer) = 1 then
            avoidUntil(peer) = worldTick + 1080
          end if
          peer = peer + 1
        wend
        if worldTick >= chatUntil then
          call rnd(721)
          reunionAfter = worldTick + 1080 + rndOut
          peer = 0
          while peer < villagerTotal
            if inMyConversation(peer) = 1 then
              avoidUntil(peer) = reunionAfter
            end if
            peer = peer + 1
          wend
          r = cancel()
          socialAfter = worldTick + 240
          aloneSince = worldTick
          leisureReady = 0
          social = -1
          leaving = 1
          leaveX = myX
          leaveY = myY
          call leaveGroup()
        end if
      else
        if leaving = 1 then
          if distTo(leaveX, leaveY) >= 7 then
            leaving = 0
            leisureReady = 0
          else
            if orderKind = 0 then
              call leaveGroup()
            end if
          end if
          engaged = 1
        end if
        ' Acknowledge a neighbor who has stopped to talk to us.
        if engaged = 0 and worldTick >= socialAfter then
          peer = 0
          while peer < villagerTotal and engaged = 0
            if peer <> selfSlot and talkingTo(peer) = selfSlot and worldTick >= avoidUntil(peer) then
              if distTo(villagerX(peer), villagerY(peer)) <= 4 then
                call beginChat(peer)
              end if
            end if
            peer = peer + 1
          wend
        end if
        if engaged = 0 and social >= 0 then
          if socialAvailable(social) = 0 or socialGroupSize(social) >= 4 then
            r = cancel()
            social = -1
            wandering = 0
          else
            if distTo(villagerX(social), villagerY(social)) <= 3 then
              call beginChat(social)
            else
              if distance(ax, ay, villagerX(social), villagerY(social)) > 3 then
                r = cancel()
                social = -1
                wandering = 0
              end if
            end if
          end if
        end if
        if engaged = 0 and orderKind = 0 then
          if leisureReady = 0 then
            leisureReady = 1
            leisureX = myX
            leisureY = myY
            previousStop = 0
            call rnd(121)
            pauseUntil = worldTick + 120 + rndOut
          end if
          if wandering = 1 then
            wandering = 0
            call rnd(121)
            pauseUntil = worldTick + 120 + rndOut
          end if

          ' Seek a neighbor or a small gathering, favoring nearby company.
          social = -1
          if worldTick >= socialAfter then
            best = 100000
            peer = 0
            while peer < villagerTotal
              if peer <> selfSlot and worldTick >= avoidUntil(peer) and socialAvailable(peer) = 1 then
                d = distTo(villagerX(peer), villagerY(peer))
                reach = 14
                if worldTick - aloneSince >= 480 then
                  reach = 64
                end if
                call canMeet(peer)
                call company(villagerX(peer), villagerY(peer))
                if neighbors >= 3 then
                  meetAllowed = 0
                end if
                if meetAllowed = 1 and d <= reach and socialGroupSize(peer) < 4 then
                  if d < best then
                    best = d
                    social = peer
                  end if
                end if
              end if
              peer = peer + 1
            wend
          end if
          if social >= 0 then
            if best <= 3 then
              call beginChat(social)
            end if
          end if
          if engaged = 0 then
            call company(myX, myY)
            if neighbors >= 4 then
              pauseUntil = worldTick
            end if
            if social >= 0 or worldTick >= pauseUntil then
              ax = myX
              ay = myY
              if social >= 0 then
                ax = villagerX(social)
                ay = villagerY(social)
              end if
              tries = 0
              while tries < 6
                call rnd(7)
                dx = rndOut - 3
                call rnd(7)
                dy = rndOut - 3
                x = ax + dx
                y = ay + dy
                nearby = distTo(x, y)
                backtracking = previousStop = 1 and distance(x, y, previousX, previousY) <= 2
                limit = 6
                if social >= 0 then
                  limit = 67
                end if
                if nearby >= 2 and nearby <= limit and backtracking = 0 then
                  if tilePassable(x, y) = 1 and (social >= 0 or distance(x, y, leisureX, leisureY) <= 8) then
                    call company(x, y)
                    if neighbors <= 2 then
                      r = walkTo(x, y)
                      if r = 1 then
                        wandering = 1
                        previousStop = 1
                        previousX = myX
                        previousY = myY
                        tries = 6
                      end if
                    end if
                  end if
                end if
                tries = tries + 1
              wend
              if wandering = 0 then
                pauseUntil = worldTick + 72
              end if
            end if
          end if
        end if
      end if
    end if
  end if
end sub

' New-day reset.
if dayMark <> day then
  dayMark = day
  returningHome = 0
  harvestCheck = 0
  houseCheck = 0
  houseTarget = -1
  wandering = 0
  leisureReady = 0
  social = -1
  pauseUntil = 0
  socialAfter = worldTick + selfSlot * 12
  aloneSince = worldTick
  leaving = 0
  chatUntil = 0
  s = 0
  while s < villagerTotal
    invitedMark(s) = 0
    avoidUntil(s) = 0
    s = s + 1
  wend
end if

' Retry an approach if it has made no tile progress for two seconds.
if worldTick >= houseCheck then
  houseCheck = worldTick + 48
  if orderKind = 1 then
    if moveChecking = 1 and distTo(moveX, moveY) <= 1 then
      r = cancel()
      social = -1
      wandering = 0
    end if
    moveChecking = 1
    moveX = myX
    moveY = myY
  else
    moveChecking = 0
  end if
  if orderKind = 3 then
    if houseTarget = orderTarget and distTo(houseX, houseY) <= 1 then
      r = enterHouse(orderTarget)
    end if
    houseTarget = orderTarget
    houseX = myX
    houseY = myY
  else
    houseTarget = -1
  end if
end if

' Am I due to host tonight? Rotation puts three hosts on every night.
hostTonight = 0
if (day + selfSlot) mod 3 = 0 then
  hostTonight = 1
end if

if dinnerDone = 1 then
  ' Allow for detours through gates and around planted gardens on the way home.
  homeMinutes = distTo(doorX(selfSlot), doorY(selfSlot)) * 4 + 60
  if 1260 - minuteOfDay <= homeMinutes or minuteOfDay >= 1200 then
    returningHome = 1
  end if
  if returningHome = 1 then
    if inHouse >= 0 then
      if inHouse <> selfSlot then
        r = exitHouse()
        leisureReady = 0
      end if
    else
      if orderKind <> 3 or orderTarget <> selfSlot then
        r = enterHouse(selfSlot)
      end if
    end if
  else
    if inHouse >= 0 then
      r = exitHouse()
      leisureReady = 0
    else
      call leisure()
    end if
  end if
else
  ' Accept the first standing invitation.
  if acceptedHost < 0 then
    s = 0
    while s < villagerTotal
      if inviteFrom(s) = 1 then
        r = accept(s)
        s = villagerTotal
      end if
      s = s + 1
    wend
  end if

  ' Where is dinner tonight? Hosts stay home. Guests follow an accepted
  ' invitation, or walk to the nearest villager whose rotation night it is.
  target = selfSlot
  if hostTonight = 0 then
    if acceptedHost >= 0 then
      target = acceptedHost
    else
      bestDist = 100000
      s = 0
      while s < villagerTotal
        if s <> selfSlot then
          if (day + s) mod 3 = 0 then
            d = distTo(doorX(s), doorY(s))
            if d < bestDist then
              bestDist = d
              target = s
            end if
          end if
        end if
        s = s + 1
      wend
    end if
  end if

  ' Budget extra time for fences and shrubs, plus a half-hour for door crowds.
  ' Five o'clock is the hard deadline for starting the walk to dinner.
  minutesLeft = 1080 - minuteOfDay
  walkMinutes = distTo(doorX(target), doorY(target)) * 4
  going = 0
  if minutesLeft <= walkMinutes + 30 then
    going = 1
  end if
  if minuteOfDay >= 1020 then
    going = 1
  end if

  if going = 1 then
    if inHouse < 0 then
      alreadyHeading = 0
      if orderKind = 3 and orderTarget = target then
        alreadyHeading = 1
      end if
      if alreadyHeading = 0 then
        r = enterHouse(target)
      end if
    end if
  else
    ' Daytime. Hosts wave invitations at anyone passing close by.
    if hostTonight = 1 then
      s = 0
      while s < villagerTotal
        if s <> selfSlot then
          if invitedMark(s) = 0 then
            if villagerInHouse(s) < 0 then
              d = distTo(villagerX(s), villagerY(s))
              if d <= 3 then
                r = invite(s)
                if r = 1 then
                  invitedMark(s) = 1
                end if
              end if
            end if
          end if
        end if
        s = s + 1
      wend
    end if

    call leisure()
  end if
end if
