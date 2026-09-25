' GotA neural policy glue (gota-neural-basic/1).
' BASIC keeps the draft, shopping, ability leveling and buyback, using
' base.bas's own routines verbatim; every in-battle hero command comes from
' the network through gota_act(), which issues the decoded command once on
' each decision tick (every decision_period ticks) and does nothing otherwise.

dim owned(22)
dim inventorySlot(22)

sub chooseHero()
  if draftTurnId <> selfId then
    exit sub
  end if
  bestClass = -1
  bestScore = -10000
  for candidate = 0 to 9
    if heroAvailable(candidate) then
      role = heroRole(candidate)
      score = 100
      for player = 0 to draftPlayerCount() - 1
        if draftPlayerTeam(player) = selfTeam then
          picked = draftedClass(draftPlayerId(player))
          if picked >= 0 then
            if heroRole(picked) = role then
              score = score - 100
            end if
          end if
        end if
      next player
      if score > bestScore then
        bestScore = score
        bestClass = candidate
      end if
    end if
  next candidate
  if bestClass >= 0 then
    accepted = draftHero(bestClass)
    actionError = lastActionError()
  end if
end sub

sub learnAbilities()
  ' Rank requirements and effects come from the host, not a stat table.
  for upgrade = 1 to 4
    if abilityPoints() = 0 then
      exit sub
    end if
    upgradeSlot = -1
    upgradeScore = -1
    for spellSlot = 0 to 3
      rank = abilityLevel(spellSlot)
      if rank < abilityMaxLevel(spellSlot) then
        if selfLevel >= abilityRequiredLevel(spellSlot) then
          if canLevelAbility(spellSlot) then
            ' Prefer R, W, E, Q whenever the next rank is legal.
            score = spellSlot
            if spellSlot = 1 then
              score = 2
            elseif spellSlot = 2 then
              score = 1
            end if
            if score > upgradeScore then
              upgradeScore = score
              upgradeSlot = spellSlot
            end if
          end if
        end if
      end if
    next spellSlot
    if upgradeSlot < 0 then
      exit sub
    end if
    accepted = levelAbility(upgradeSlot)
    actionError = lastActionError()
  next upgrade
end sub

sub buy(id, price, quantity)
  if owned(id) >= quantity or budget < price then
    exit sub
  end if
  if owned(id) = 0 and emptySlots = 0 then
    exit sub
  end if
  accepted = buyItem(id)
  actionError = lastActionError()
  if accepted then
    if owned(id) = 0 then
      emptySlots = emptySlots - 1
    end if
    owned(id) = owned(id) + 1
    budget = budget - price
    for boughtSlot = 0 to 5
      if itemId(boughtSlot) = id then
        inventorySlot(id) = boughtSlot
      end if
    next boughtSlot
  end if
end sub

sub shop()
  for id = 0 to 22
    owned(id) = 0
    inventorySlot(id) = -1
  next id
  emptySlots = 0
  for itemSlot = 0 to 5
    id = itemId(itemSlot)
    if id = 0 then
      emptySlots = emptySlots + 1
    else
      owned(id) = itemCount(itemSlot)
      inventorySlot(id) = itemSlot
    end if
  next itemSlot
  if canShop() = 0 then
    exit sub
  end if
  ' base.bas's purchase plan: recovery, travel, equipment, role consumable.
  budget = selfGold
  buy(8, 100, 1)
  buy(1, 30, 2)
  buy(21, 100, 2)
  buy(22, 45, 2)
  if role = 0 or role = 4 then
    buy(16, 160, 1)
    buy(2, 75, 2)
  elseif role = 1 then
    buy(19, 180, 1)
    buy(4, 40, 2)
  else
    buy(20, 190, 1)
    buy(3, 90, 2)
  end if
end sub

if drafting then
  chooseHero()
  end
end if

if selfHp <= 0 then
  price = buybackPrice()
  if price > 0 and selfGold >= price then
    accepted = buyback()
    actionError = lastActionError()
  end if
  end
end if

role = heroRole(selfClass)
learnAbilities()
if worldTick >= nextShop then
  nextShop = worldTick + 6
  shop()
end if
acted = gota_act()
