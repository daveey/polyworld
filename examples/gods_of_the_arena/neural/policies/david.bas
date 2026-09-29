' David GOTANET1 observation and action glue using ordinary BASIC queries.
' Reusable glue and a synthetic example written for this API.
' This is not a submitted player policy and contains no learned coefficients.
' Coordinates and math cross the Q16.16 boundary explicitly.
dim nnData(1406)
dim nnObjects(24)
dim nnPopulated(24)
dim nnIds(24)
dim nnXs(24)
dim nnYs(24)
dim nnDistances(24)
dim nnWarnings(3)
dim nnWarningTicks(3)
dim nnWarningDistances(3)
dim nnAllowed(91)
dim nnChances(48)
dim nnHeads(4)
dim nnGoals(15)
dim nnAllies(9)
' Action head ranges and movement geometry, not model coefficients.
DATA nnOffsets AS int32 = 0, 8, 33, 82, 86
DATA nnSizes AS int32 = 8, 25, 49, 4, 6
DATA nnDirectionsX AS fixed32 = _
  1.0, 0.9238739013671875, 0.7071075439453125, 0.3826904296875, _
  0.0, -0.3826904296875, -0.7071075439453125, -0.9238739013671875, _
  -1.0, -0.9238739013671875, -0.7071075439453125, -0.3826904296875, _
  0.0, 0.3826904296875, 0.7071075439453125, 0.9238739013671875
DATA nnDirectionsY AS fixed32 = _
  0.0, 0.3826904296875, 0.7071075439453125, 0.9238739013671875, _
  1.0, 0.9238739013671875, 0.7071075439453125, 0.3826904296875, _
  0.0, -0.3826904296875, -0.7071075439453125, -0.9238739013671875, _
  -1.0, -0.9238739013671875, -0.7071075439453125, -0.3826904296875
DATA nnWalkRings AS fixed32 = 2.0, 5.0, 12.0
DATA nnCastRings AS fixed32 = 0.5, 1.25, 2.5

sub nnClamp(low, high)
  if nnValue < low then
    nnValue = low
  elseif nnValue > high then
    nnValue = high
  end if
end sub

sub nnRatio(nnNumerator, nnDenominator)
  ' Normalize nonnegative int32 counters before crossing into Q16.16.
  if nnDenominator <= 0 then
    nnDenominator = 1
  end if
  if nnNumerator < 0 then
    nnNumerator = 0
  end if
  nnWhole = nnNumerator \ nnDenominator
  nnRemainder = nnNumerator mod nnDenominator
  nnFraction = 0.0
  nnBit = 0.5
  for nnRatioI = 1 to 16
    if nnRemainder >= nnDenominator - nnRemainder then
      nnRemainder = nnRemainder - (nnDenominator - nnRemainder)
      nnFraction = nnFraction + nnBit
    else
      nnRemainder = nnRemainder * 2
    end if
    nnBit = nnBit / 2.0
  next nnRatioI
  if nnRemainder >= nnDenominator - nnRemainder then
    nnFraction = nnFraction + 0.0000152587890625
  end if
  nnValue = nnWhole + nnFraction
end sub

sub nnInitialize()
  if nnInitialized then
    exit sub
  end if
  nnAllyCount = 0
  for nnA = 0 to draftPlayerCount() - 1
    if draftPlayerTeam(nnA) = selfTeam then
      nnAllies(nnAllyCount) = draftPlayerId(nnA)
      nnAllyCount = nnAllyCount + 1
    end if
  next nnA
  nnState = blobCreate()
  nnSeed = matchInfo(2) + selfId * 7919
  nnPeriod = 4
  nnSampling = 1
  nnMask = 1
  nnTemperature = 1.0
  nnGoals(0) = 1.0
  nnInitialized = 1
end sub

sub nnObserve()
  nnData(30) = 0.0
  nnData(31) = 0.0
  nnData(32) = 0.0
  nnData(33) = 0.0
  nnData(34) = 0.0
  nnData(35) = 0.0
  nnData(36) = 0.0
  nnData(37) = 0.0
  nnData(38) = 0.0
  nnData(39) = 0.0
  nnData(40) = 0.0
  nnData(41) = 0.0
  nnData(42) = 0.0
  nnData(43) = 0.0
  nnData(44) = 0.0
  nnSelfX = selfInfo(0)
  nnSelfY = selfInfo(1)
  nnSide = 1 - selfTeam * 2
  nnOrigin = matchInfo(5)
  nnAttackRange = selfInfo(15)
  nnData(0) = -(selfHp > 0)
  nnValue = selfHp / selfMaxHp
  nnClamp(0, 1)
  nnData(1) = nnValue
  nnValue = selfMana / selfMaxMana
  nnClamp(0, 1)
  nnData(2) = nnValue
  nnData(3) = selfMaxHp / 2000.0
  nnData(4) = selfMaxMana / 1000.0
  nnRatio(selfGold, 1000)
  nnData(5) = nnValue
  nnData(6) = selfLevel / 20.0
  nnValue = selfInfo(2) / selfInfo(3)
  nnClamp(0, 1)
  nnData(7) = nnValue
  nnRatio(selfInfo(4), 20000)
  nnData(8) = nnValue
  nnData(9) = nnSelfX * nnSide / 64.0
  nnData(10) = nnSelfY * nnSide / 64.0
  nnData(11) = selfTeam
  nnRatio(matchInfo(0), matchInfo(1))
  nnClamp(0, 1)
  nnData(12) = nnValue
  nnValue = selfAttackCooldown / 48.0
  nnClamp(0, 2)
  nnData(13) = nnValue
  nnData(14) = nnAttackRange / 10.0
  nnData(15) = selfAttackDamage / 200.0
  nnData(16) = selfInfo(16) * tickRate / 5.0
  nnData(17) = -(selfTarget <> 0)
  nnValue = selfStunTicks / 72.0
  nnClamp(0, 2)
  nnData(18) = nnValue
  nnValue = selfRootTicks / 72.0
  nnClamp(0, 2)
  nnData(19) = nnValue
  nnValue = selfSilenceTicks / 72.0
  nnClamp(0, 2)
  nnData(20) = nnValue
  nnValue = selfChannelTicks / 72.0
  nnClamp(0, 2)
  nnData(21) = nnValue
  nnValue = selfPortalCooldown / 1440.0
  nnClamp(0, 2)
  nnData(22) = nnValue
  nnValue = selfRespawnTicks / 1440.0
  nnClamp(0, 2)
  nnData(23) = nnValue
  nnData(24) = selfInfo(9) / 4.0
  nnData(25) = -selfInfo(7)
  nnData(26) = -selfInfo(8)
  nnData(27) = selfDeaths / 10.0
  nnData(28) = -(lastActionError() <> 0)
  nnData(29) = -(buybackPrice() > 0 and selfGold >= buybackPrice())
  nnData(30 + selfClass) = 1.0
  nnData(40 + selfInfo(6)) = 1.0
  nnValue = selfInfo(13) * nnSide * 10.0
  nnClamp(-4, 4)
  nnData(45) = nnValue
  nnValue = selfInfo(14) * nnSide * 10.0
  nnClamp(-4, 4)
  nnData(46) = nnValue
  nnData(47) = -selfInfo(5)
  for nnA = 0 to 3
    nnBase = 48 + nnA * 16
    nnData(nnBase + 11) = 0.0
    nnData(nnBase + 12) = 0.0
    nnData(nnBase + 13) = 0.0
    nnData(nnBase + 14) = 0.0
    nnData(nnBase + 0) = abilityLevel(nnA) / abilityMaxLevel(nnA)
    nnData(nnBase + 1) = -(abilityLevel(nnA) > 0)
    nnValue = abilityCooldown(nnA) / 240.0
    nnClamp(0, 2)
    nnData(nnBase + 2) = nnValue
    nnData(nnBase + 3) = abilityCharges(nnA) / 3.0
    nnValue = abilityRecharge(nnA) / 240.0
    nnClamp(0, 2)
    nnData(nnBase + 4) = nnValue
    nnData(nnBase + 5) = abilityManaCost(nnA) / 200.0
    nnData(nnBase + 6) = -(selfHp > 0 and abilityLevel(nnA) > 0 and abilityCooldown(nnA) = 0 and abilityCharges(nnA) > 0 and selfMana >= abilityManaCost(nnA) and selfSilenceTicks = 0)
    nnData(nnBase + 7) = abilityDamage(nnA) / 300.0
    nnData(nnBase + 8) = abilityHeal(nnA) / 300.0
    nnData(nnBase + 9) = abilityRestore(nnA) / 200.0
    nnData(nnBase + 10) = abilityInfo(nnA, 0) / 10.0
    nnData(nnBase + 11 + abilityInfo(nnA, 1)) = 1.0
    nnData(nnBase + 15) = abilityInfo(nnA, 2) / 3.0
  next nnA
  for nnI = 0 to 5
    nnBase = 112 + nnI * 25
    nnData(nnBase + 0) = 0.0
    nnData(nnBase + 1) = 0.0
    nnData(nnBase + 2) = 0.0
    nnData(nnBase + 3) = 0.0
    nnData(nnBase + 4) = 0.0
    nnData(nnBase + 5) = 0.0
    nnData(nnBase + 6) = 0.0
    nnData(nnBase + 7) = 0.0
    nnData(nnBase + 8) = 0.0
    nnData(nnBase + 9) = 0.0
    nnData(nnBase + 10) = 0.0
    nnData(nnBase + 11) = 0.0
    nnData(nnBase + 12) = 0.0
    nnData(nnBase + 13) = 0.0
    nnData(nnBase + 14) = 0.0
    nnData(nnBase + 15) = 0.0
    nnData(nnBase + 16) = 0.0
    nnData(nnBase + 17) = 0.0
    nnData(nnBase + 18) = 0.0
    nnData(nnBase + 19) = 0.0
    nnData(nnBase + 20) = 0.0
    nnData(nnBase + 21) = 0.0
    nnData(nnBase + 22) = 0.0
    nnData(nnBase + itemId(nnI)) = 1.0
    nnData(nnBase + 23) = itemCount(nnI) / 4.0
    nnValue = itemCooldown(nnI) / 240.0
    nnClamp(0, 2)
    nnData(nnBase + 24) = nnValue
  next nnI
  for nnS = 0 to 24
    nnObjects(nnS) = -1
    nnIds(nnS) = 0
    nnDistances(nnS) = 32767.0
  next nnS
  nnOwnAlive = 0
  nnEnemyVisible = 0
  nnOwnLevels = 0
  nnEnemyLevels = 0
  for nnI = 0 to objectCount() - 1
    nnId = objectId(nnI)
    nnKind = objectKind(nnI)
    nnTeam = objectTeam(nnI)
    nnAlive = objectInfo(nnI, 3)
    nnX = objectInfo(nnI, 0)
    nnY = objectInfo(nnI, 1)
    nnDx = (nnX - nnSelfX) / 16.0
    nnDy = (nnY - nnSelfY) / 16.0
    nnDistance = nnDx * nnDx + nnDy * nnDy
    nnSlot = -1
    nnStart = -1
    nnLast = -1
    if nnKind = 1 then
      nnSlot = 17
      if nnTeam <> selfTeam then
        nnSlot = 18
      end if
    elseif nnKind = 2 then
      nnRoster = nnId - 100
      if nnTeam = selfTeam then
        nnOwnLevels = nnOwnLevels + objectLevel(nnI)
        if nnAlive then
          nnOwnAlive = nnOwnAlive + 1
          nnSlot = nnRoster mod 5 + 1
          if nnRoster mod 5 > (selfId - 100) mod 5 then
            nnSlot = nnSlot - 1
          end if
          if nnId = selfId then
            nnSlot = 0
          end if
        end if
      else
        nnEnemyVisible = nnEnemyVisible + 1
        nnEnemyLevels = nnEnemyLevels + objectLevel(nnI)
        nnSlot = 5 + nnRoster mod 5
      end if
    elseif nnKind = 3 and nnAlive then
      nnStart = 10
      nnLast = 16
    elseif nnKind = 6 and nnAlive then
      nnStart = 21
      nnLast = 24
    elseif (nnKind = 4 or nnKind = 5) and objectHp(nnI) > 0 then
      if nnTeam <> selfTeam then
        nnStart = 20
        nnLast = 20
      elseif nnKind = 4 then
        nnDx = (nnX - selfInfo(17)) / 16.0
        nnDy = (nnY - selfInfo(18)) / 16.0
        nnDistance = nnDx * nnDx + nnDy * nnDy
        nnStart = 19
        nnLast = 19
      end if
    end if
    if nnStart >= 0 then
      for nnS = nnStart to nnLast
        if nnDistance < nnDistances(nnS) or (nnDistance = nnDistances(nnS) and nnId < nnIds(nnS)) then
          for nnJ = nnLast to nnS + 1 step -1
            nnObjects(nnJ) = nnObjects(nnJ - 1)
            nnIds(nnJ) = nnIds(nnJ - 1)
            nnDistances(nnJ) = nnDistances(nnJ - 1)
          next nnJ
          nnSlot = nnS
          exit for
        end if
      next nnS
    end if
    if nnSlot >= 0 then
      nnObjects(nnSlot) = nnI
      nnIds(nnSlot) = nnId
      nnDistances(nnSlot) = nnDistance
    end if
  next nnI
  for nnS = 0 to 24
    nnI = nnObjects(nnS)
    nnBase = 262 + nnS * 40
    if nnI < 0 and nnPopulated(nnS) then
      nnData(nnBase + 0) = 0.0
      nnData(nnBase + 1) = 0.0
      nnData(nnBase + 2) = 0.0
      nnData(nnBase + 3) = 0.0
      nnData(nnBase + 4) = 0.0
      nnData(nnBase + 5) = 0.0
      nnData(nnBase + 6) = 0.0
      nnData(nnBase + 7) = 0.0
      nnData(nnBase + 8) = 0.0
      nnData(nnBase + 9) = 0.0
      nnData(nnBase + 10) = 0.0
      nnData(nnBase + 11) = 0.0
      nnData(nnBase + 12) = 0.0
      nnData(nnBase + 13) = 0.0
      nnData(nnBase + 14) = 0.0
      nnData(nnBase + 15) = 0.0
      nnData(nnBase + 16) = 0.0
      nnData(nnBase + 17) = 0.0
      nnData(nnBase + 18) = 0.0
      nnData(nnBase + 19) = 0.0
      nnData(nnBase + 20) = 0.0
      nnData(nnBase + 21) = 0.0
      nnData(nnBase + 22) = 0.0
      nnData(nnBase + 23) = 0.0
      nnData(nnBase + 24) = 0.0
      nnData(nnBase + 25) = 0.0
      nnData(nnBase + 26) = 0.0
      nnData(nnBase + 27) = 0.0
      nnData(nnBase + 28) = 0.0
      nnData(nnBase + 29) = 0.0
      nnData(nnBase + 30) = 0.0
      nnData(nnBase + 31) = 0.0
      nnData(nnBase + 32) = 0.0
      nnData(nnBase + 33) = 0.0
      nnData(nnBase + 34) = 0.0
      nnData(nnBase + 35) = 0.0
      nnData(nnBase + 36) = 0.0
      nnData(nnBase + 37) = 0.0
      nnData(nnBase + 38) = 0.0
      nnData(nnBase + 39) = 0.0
      nnPopulated(nnS) = 0
    end if
    if nnI >= 0 then
      nnPopulated(nnS) = 1
      nnData(nnBase + 7) = 0.0
      nnData(nnBase + 8) = 0.0
      nnData(nnBase + 9) = 0.0
      nnData(nnBase + 10) = 0.0
      nnData(nnBase + 11) = 0.0
      nnData(nnBase + 12) = 0.0
      nnData(nnBase + 29) = 0.0
      nnData(nnBase + 30) = 0.0
      nnData(nnBase + 31) = 0.0
      nnData(nnBase + 32) = 0.0
      nnData(nnBase + 33) = 0.0
      nnData(nnBase + 34) = 0.0
      nnData(nnBase + 35) = 0.0
      nnData(nnBase + 36) = 0.0
      nnData(nnBase + 37) = 0.0
      nnData(nnBase + 38) = 0.0
      nnData(nnBase + 39) = 0.0
      nnXs(nnS) = objectInfo(nnI, 0)
      nnYs(nnS) = objectInfo(nnI, 1)
      nnDx = (nnXs(nnS) - nnSelfX) * nnSide / 16.0
      nnDy = (nnYs(nnS) - nnSelfY) * nnSide / 16.0
      nnValue = sqrt(nnDx * nnDx + nnDy * nnDy)
      nnDistance = nnValue
      nnHp = objectHp(nnI)
      if nnHp < 0 then
        nnHp = 0
      end if
      nnMaxHp = objectInfo(nnI, 2)
      nnTarget = objectTarget(nnI)
      nnKind = objectKind(nnI)
      nnTeam = objectTeam(nnI)
      nnData(nnBase + 0) = 1.0
      nnValue = nnDx
      nnClamp(-4, 4)
      nnData(nnBase + 1) = nnValue
      nnValue = nnDy
      nnClamp(-4, 4)
      nnData(nnBase + 2) = nnValue
      nnValue = nnDistance
      nnClamp(0, 8)
      nnData(nnBase + 3) = nnValue
      nnValue = nnHp / nnMaxHp
      nnClamp(0, 1)
      nnData(nnBase + 4) = nnValue
      nnData(nnBase + 5) = nnHp / 2000.0
      nnData(nnBase + 6) = 0.0
      nnData(nnBase + 13) = -objectInfo(nnI, 3)
      nnData(nnBase + 14) = objectLevel(nnI) / 20.0
      nnData(nnBase + 15) = objectMana(nnI) / 1000.0
      nnData(nnBase + 16) = -(nnTarget <> 0 and nnTarget = selfId)
      nnData(nnBase + 17) = -(objectId(nnI) <> 0 and objectId(nnI) = selfTarget)
      nnData(nnBase + 18) = 0.0
      nnValue = objectStunTicks(nnI) / 72.0
      nnClamp(0, 2)
      nnData(nnBase + 19) = nnValue
      nnValue = objectRootTicks(nnI) / 72.0
      nnClamp(0, 2)
      nnData(nnBase + 20) = nnValue
      nnValue = objectSilenceTicks(nnI) / 72.0
      nnClamp(0, 2)
      nnData(nnBase + 21) = nnValue
      nnValue = objectInfo(nnI, 6) * nnSide * 10.0
      nnClamp(-4, 4)
      nnData(nnBase + 22) = nnValue
      nnValue = objectInfo(nnI, 7) * nnSide * 10.0
      nnClamp(-4, 4)
      nnData(nnBase + 23) = nnValue
      nnData(nnBase + 24) = objectInfo(nnI, 4) * nnSide
      nnData(nnBase + 25) = objectInfo(nnI, 5) * nnSide
      nnData(nnBase + 26) = -(nnDistance <= nnAttackRange / 16.0)
      nnData(nnBase + 27) = -(nnHp > 0 and nnHp <= selfAttackDamage)
      nnData(nnBase + 28) = objectReturning(nnI)
      nnData(nnBase + 6 + nnKind) = 1.0
      if nnTeam <> 2 then
        nnData(nnBase + 6) = -1.0
        if nnTeam = selfTeam then
          nnData(nnBase + 6) = 1.0
        end if
      end if
      for nnA = 0 to nnAllyCount - 1
        if nnTarget <> 0 and nnTarget = nnAllies(nnA) then
          nnData(nnBase + 18) = 1.0
        end if
      next nnA
      if nnKind = 3 then
        nnData(nnBase + 29) = objectClass(nnI)
      elseif nnKind = 6 then
        nnData(nnBase + 29) = objectClass(nnI) / 3.0
      elseif nnKind = 2 then
        nnData(nnBase + 30 + objectClass(nnI)) = 1.0
      end if
    end if
  next nnS
  for nnS = 0 to 3
    nnWarnings(nnS) = -1
    nnWarningTicks(nnS) = 2147483647
    nnWarningDistances(nnS) = 32767.0
  next nnS
  for nnI = 0 to spellCount() - 1
    nnImpact = spellImpactTick(nnI)
    nnDx = (spellInfo(nnI, 0) - nnSelfX) / 16.0
    nnDy = (spellInfo(nnI, 1) - nnSelfY) / 16.0
    nnDistance = nnDx * nnDx + nnDy * nnDy
    for nnS = 0 to 3
      if nnImpact < nnWarningTicks(nnS) or (nnImpact = nnWarningTicks(nnS) and nnDistance < nnWarningDistances(nnS)) then
        for nnJ = 3 to nnS + 1 step -1
          nnWarnings(nnJ) = nnWarnings(nnJ - 1)
          nnWarningTicks(nnJ) = nnWarningTicks(nnJ - 1)
          nnWarningDistances(nnJ) = nnWarningDistances(nnJ - 1)
        next nnJ
        nnWarnings(nnS) = nnI
        nnWarningTicks(nnS) = nnImpact
        nnWarningDistances(nnS) = nnDistance
        exit for
      end if
    next nnS
  next nnI
  for nnS = 0 to 3
    nnI = nnWarnings(nnS)
    nnBase = 1262 + nnS * 8
    nnData(nnBase + 0) = 0.0
    nnData(nnBase + 1) = 0.0
    nnData(nnBase + 2) = 0.0
    nnData(nnBase + 3) = 0.0
    nnData(nnBase + 4) = 0.0
    nnData(nnBase + 5) = 0.0
    nnData(nnBase + 6) = 0.0
    nnData(nnBase + 7) = 0.0
    if nnI >= 0 then
      nnData(nnBase) = 1.0
      nnValue = (spellInfo(nnI, 0) - nnSelfX) * nnSide / 16.0
      nnClamp(-4, 4)
      nnData(nnBase + 1) = nnValue
      nnValue = (spellInfo(nnI, 1) - nnSelfY) * nnSide / 16.0
      nnClamp(-4, 4)
      nnData(nnBase + 2) = nnValue
      nnValue = sqrt(nnWarningDistances(nnS))
      nnClamp(0, 8)
      nnData(nnBase + 3) = nnValue
      nnValue = (nnWarningTicks(nnS) - worldTick) / 72.0
      nnClamp(0, 4)
      nnData(nnBase + 4) = nnValue
      nnData(nnBase + 5) = -spellInfo(nnI, 2)
      nnData(nnBase + 6) = -spellInfo(nnI, 3)
      nnData(nnBase + 7) = spellAbility(nnI) / 40.0
    end if
  next nnS
  nnData(1294) = nnData(946)
  nnData(1295) = nnData(955)
  for nnS = 0 to 3
    nnTotal = matchInfo(9 + nnS * 2)
    if nnTotal > 0 then
      nnData(1296 + nnS) = matchInfo(8 + nnS * 2) / nnTotal
    end if
  next nnS
  nnData(1300) = -1.0
  if nnIds(18) <> 0 then
    nnData(1300) = nnData(986)
  end if
  nnData(1301) = nnOwnAlive / 5.0
  nnData(1302) = nnEnemyVisible / 5.0
  nnData(1303) = matchInfo(3) / matchInfo(4)
  nnData(1304) = nnOwnLevels / 50.0
  nnData(1305) = nnEnemyLevels / 50.0
  nnRatio(selfInfo(10), 5000)
  nnData(1306) = nnValue
  nnData(1307) = selfInfo(11) / 10.0
  nnData(1308) = selfInfo(12) / 10.0
  nnInteger = floor(nnSelfX + nnOrigin)
  nnCenterX = nnInteger
  nnInteger = floor(nnSelfY + nnOrigin)
  nnCenterY = nnInteger
  nnBase = 1310
  nnTerrainY = nnCenterY - 8 * nnSide
  for nnRow = 0 to 8
    nnTerrainX = nnCenterX - 8 * nnSide
    for nnCol = 0 to 8
      nnData(nnBase) = terrainWalkableAt(nnTerrainX, nnTerrainY, selfLayer)
      nnTerrainX = nnTerrainX + 2 * nnSide
      nnBase = nnBase + 1
    next nnCol
    nnTerrainY = nnTerrainY + 2 * nnSide
  next nnRow
  for nnI = 0 to 15
    nnData(1391 + nnI) = nnGoals(nnI)
  next nnI
end sub

sub nnChoose()
  ' Select an action from the scores returned by the native runner.
  for nnI = 0 to 91
    nnAllowed(nnI) = 1
  next nnI
  if nnMask then
    nnAllowed(3) = 0
    nnAllowed(4) = 0
    for nnA = 0 to 3
      if abilityInfo(nnA, 1) = 0 or abilityInfo(nnA, 3) <> 0 then
        nnAllowed(4) = 1
      end if
    next nnA
    for nnS = 0 to 24
      nnAllowed(8 + nnS) = -(nnIds(nnS) <> 0)
      if nnIds(nnS) <> 0 then
        nnBase = 262 + nnS * 40
        if nnS <> 0 and nnData(nnBase + 6) <> 1.0 and nnData(nnBase + 28) = 0 then
          nnAttackable = nnData(nnBase + 13)
          if nnData(nnBase + 7) or nnData(nnBase + 10) or nnData(nnBase + 11) then
            nnAttackable = nnData(nnBase + 5) > 0
          end if
          if nnAttackable then
            nnAllowed(3) = 1
          end if
          if nnData(nnBase + 13) then
            nnAllowed(4) = 1
          end if
        end if
      end if
    next nnS
  end if
  for nnH = 0 to 4
    nnBase = nnOffsets(nnH)
    nnCount = nnSizes(nnH)
    nnBest = -1
    for nnI = 0 to nnCount - 1
      if nnAllowed(nnBase + nnI) then
        if nnBest < 0 then
          nnBest = nnI
        elseif nnResult(nnBase + nnI) > nnResult(nnBase + nnBest) then
          nnBest = nnI
        end if
      end if
    next nnI
    if nnBest < 0 then
      nnBest = 0
    end if
    if nnSampling then
      nnTop = nnResult(nnBase + nnBest)
      nnTotal = 0.0
      for nnI = 0 to nnCount - 1
        nnChances(nnI) = 0.0
        if nnAllowed(nnBase + nnI) then
          nnDelta = nnResult(nnBase + nnI) / 2.0 - nnTop / 2.0
          nnValue = 0.0
          if nnDelta > -8.0 * nnTemperature then
            nnValue = exp(nnDelta * 2.0 / nnTemperature)
          end if
          nnChances(nnI) = nnValue
          nnTotal = nnTotal + nnValue
        end if
      next nnI
      nnSeed = nnSeed * 1664525 + 1013904223
      nnDraw = (nnSeed and 32767) / 16384.0 / 2.0 * nnTotal
      nnSum = 0.0
      for nnI = 0 to nnCount - 1
        nnSum = nnSum + nnChances(nnI)
        if nnDraw < nnSum then
          nnBest = nnI
          exit for
        end if
      next nnI
    end if
    nnHeads(nnH) = nnBest
  next nnH
end sub

sub nnDispatch()
  nnVerb = nnHeads(0)
  nnTarget = nnHeads(1)
  nnPoint = nnHeads(2)
  nnX = nnSelfX
  nnY = nnSelfY
  if nnVerb = 5 or nnVerb = 7 then
    if nnIds(nnTarget) = 0 then
      exit sub
    end if
    nnX = nnXs(nnTarget)
    nnY = nnYs(nnTarget)
  end if
  if nnPoint > 0 then
    nnRing = (nnPoint - 1) \ 16
    nnDirection = (nnPoint - 1) mod 16
    nnRadius = nnWalkRings(nnRing)
    if nnVerb = 5 or nnVerb = 7 then
      nnRadius = nnCastRings(nnRing)
    end if
    nnX = nnX + nnDirectionsX(nnDirection) * nnRadius * nnSide
    nnY = nnY + nnDirectionsY(nnDirection) * nnRadius * nnSide
  end if
  nnValue = nnX + nnOrigin - 0.5
  nnClamp(0, matchInfo(6) - 1)
  nnX = nnValue
  nnValue = nnY + nnOrigin - 0.5
  nnClamp(0, matchInfo(6) - 1)
  nnY = nnValue
  if nnVerb = 1 or nnVerb = 2 then
    nnInteger = floor(nnX + 0.5)
    nnX = nnInteger
    nnInteger = floor(nnY + 0.5)
    nnY = nnInteger
    if nnVerb = 1 then
      walkTo(nnX, nnY)
    else
      attackMove(nnX, nnY)
    end if
  elseif nnVerb = 3 then
    if nnTarget <> 0 and nnIds(nnTarget) <> 0 then
      attackTarget(nnIds(nnTarget))
    end if
  elseif nnVerb = 4 then
    if nnIds(nnTarget) <> 0 then
      castTarget(nnHeads(3), nnIds(nnTarget))
    end if
  elseif nnVerb = 5 then
    castPoint(nnHeads(3), nnX, nnY)
  elseif nnVerb = 6 then
    useItem(nnHeads(4))
  elseif nnVerb = 7 then
    useItemAt(nnHeads(4), nnX, nnY)
  end if
end sub

sub nnStep()
  nnInitialize()
  if selfHp <= 0 then
    blobClear(nnState)
    nnNextTick = 0
    exit sub
  end if
  if worldTick < nnNextTick then
    exit sub
  end if
  nnNextTick = worldTick + nnPeriod
  nnObserve()
  nnResult = nn_david("model.bin", nnState, nnData)
  nnChoose()
  nnDispatch()
end sub

' Example policy.
if drafting then
  for nnI = 0 to 9
    if heroAvailable(nnI) then
      draftHero(nnI)
      end
    end if
  next nnI
  end
end if
nnStep()
