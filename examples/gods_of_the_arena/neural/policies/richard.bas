' Synthetic test example written for this API, not a submitted player policy.
' Pair it with the generated weights.bin fixture; no trained weights are used.
dim data(24)
if drafting then
  for i = 0 to 9
    if heroAvailable(i) then
      draftHero(i)
      end
    end if
  next i
  end
end if
if initialized = 0 then
  state = blobCreate()
  initialized = 1
end if
if selfHp <= 0 then
  blobClear(state)
  end
end if
data(0) = selfHp * 100 \ selfMaxHp
res = nn_richard("weights.bin", state, data)
best = 0
for i = 1 to 17
  if res(i) > res(best) then
    best = i
  end if
next i
' Interpret the chosen score using ordinary game commands.
if best = 0 then
  walkTo(selfX, selfY)
end if
