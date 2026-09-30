' Fly connectome helpers. BASIC owns observations, timing and sampling.
' Reusable glue and a synthetic example written for this API.
' This is not a submitted player policy and contains no learned coefficients.
dim flyData(44)
dim flyChances(10)
sub flyChoose()
  ' Select an action from the scores returned by the native runner.
  flyAction = 0
  for flyI = 1 to 10
    if flyResult(flyI) > flyResult(flyAction) then
      flyAction = flyI
    end if
  next flyI
  if flyTemperature <= 0 then
    exit sub
  end if
  flyTop = flyResult(flyAction)
  flyTotal = 0.0
  for flyI = 0 to 10
    flyHalf = flyResult(flyI) / 2.0 - flyTop / 2.0
    flyValue = 0.0
    if flyHalf >= -8.0 * flyTemperature then
      flyValue = exp(flyHalf * 2.0 / flyTemperature)
    end if
    flyChances(flyI) = flyValue
    flyTotal = flyTotal + flyValue
  next flyI
  flySeed = flySeed * 1664525 + 1013904223
  flyDraw = (flySeed and 32767) / 16384.0 / 2.0 * flyTotal
  flyCumulative = 0.0
  for flyI = 0 to 10
    flyCumulative = flyCumulative + flyChances(flyI)
    if flyDraw < flyCumulative then
      flyAction = flyI
      exit sub
    end if
  next flyI
end sub

sub flyAdvance()
  ' Advance from the previous captured features before the hero thinks.
  if drafting then
    exit sub
  end if
  if flyInitialized = 0 then
    flyState = blobCreate()
    flyPeriod = 24
    flyTemperature = 1.0
    flySeed = matchInfo(2) + selfId * 7919
    for flyI = 0 to draftPlayerCount() - 1
      if draftPlayerId(flyI) = selfId then
        flyData(40 + flyI mod 5) = 1.0
      end if
    next flyI
    flyInitialized = 1
  end if
  if worldTick < flyNextTick then
    exit sub
  end if
  flyNextTick = worldTick + flyPeriod
  flyResult = fly_nn("fly.bin", flyState, flyData)
  flyChoose()
end sub

sub flyCapture()
  ' The lockstep bridge stores features even when the held action is unchanged.
  for flyI = 0 to 39
    flyFeature = f(flyI)
    if flyFeature > 100 then
      flyFeature = 100
    end if
    if flyFeature < -100 then
      flyFeature = -100
    end if
    flyData(flyI) = flyFeature / 100.0
  next flyI
end sub

' Example policy.
dim f(40)
flyAdvance()
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
flyCapture()
decision = flyAction
' The real converted hero keeps all eleven macro behaviours in its BASIC.
if decision = 1 then
  walkTo(selfX, selfY)
else
  attackMove(selfX, selfY)
end if
