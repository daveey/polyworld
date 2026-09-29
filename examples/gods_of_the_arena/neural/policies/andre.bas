' Andre PufferNet helpers. BASIC owns observations, timing and sampling.
' Reusable glue and a synthetic example written for this API.
' This is not a submitted player policy and contains no learned coefficients.
dim andreData(44)
dim andreChances(10)
sub andreChoose()
  ' Select an action from the scores returned by the native runner.
  andreAction = 0
  for andreI = 1 to 10
    if andreResult(andreI) > andreResult(andreAction) then
      andreAction = andreI
    end if
  next andreI
  if andreTemperature <= 0 then
    exit sub
  end if
  andreTop = andreResult(andreAction)
  andreTotal = 0.0
  for andreI = 0 to 10
    andreHalf = andreResult(andreI) / 2.0 - andreTop / 2.0
    andreValue = 0.0
    if andreHalf >= -8.0 * andreTemperature then
      andreValue = exp(andreHalf * 2.0 / andreTemperature)
    end if
    andreChances(andreI) = andreValue
    andreTotal = andreTotal + andreValue
  next andreI
  andreSeed = andreSeed * 1664525 + 1013904223
  andreDraw = (andreSeed and 32767) / 16384.0 / 2.0 * andreTotal
  andreCumulative = 0.0
  for andreI = 0 to 10
    andreCumulative = andreCumulative + andreChances(andreI)
    if andreDraw < andreCumulative then
      andreAction = andreI
      exit sub
    end if
  next andreI
end sub

sub andreAdvance()
  ' Advance from the previous captured features before the hero thinks.
  if drafting then
    exit sub
  end if
  if andreInitialized = 0 then
    andreState = blobCreate()
    andrePeriod = 24
    andreTemperature = 1.0
    andreSeed = matchInfo(2) + selfId * 7919
    for andreI = 0 to draftPlayerCount() - 1
      if draftPlayerId(andreI) = selfId then
        andreData(40 + andreI mod 5) = 1.0
      end if
    next andreI
    andreInitialized = 1
  end if
  if worldTick < andreNextTick then
    exit sub
  end if
  andreNextTick = worldTick + andrePeriod
  andreResult = andre_nn("weights.bin", andreState, andreData)
  andreChoose()
end sub

sub andreCapture()
  ' The lockstep bridge stores features even when the held action is unchanged.
  for andreI = 0 to 39
    andreFeature = f(andreI)
    if andreFeature > 100 then
      andreFeature = 100
    end if
    if andreFeature < -100 then
      andreFeature = -100
    end if
    andreData(andreI) = andreFeature / 100.0
  next andreI
end sub

' Example policy.
dim f(40)
andreAdvance()
if drafting then
  for candidate = 0 to 9
    if heroAvailable(candidate) then
      draftHero(candidate)
      end
    end if
  next candidate
  end
end if
if selfHp <= 0 then
  end
end if
f(0) = selfHp * 100 \ selfMaxHp
f(39) = decision * 9
andreCapture()
decision = andreAction
' The real converted hero keeps all eleven macro behaviours in its BASIC.
if decision = 1 then
  walkTo(selfX, selfY)
else
  attackMove(selfX, selfY)
end if
