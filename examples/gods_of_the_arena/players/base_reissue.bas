' GotA reference policy: draft, farm, push, heal, resupply, and finish the god.
' base_reissue: base.bas with the standing move re-issued every decision (4 ticks) instead of every
' 2 s (train lane Track D finding: re-issuing the standing order through the contract gains XP).
' Every GotA host function has a gameplay use here; calls remain conditional.
' Object indices last only for this decision. IDs may be remembered.
' Read the bot guide for units, LOS restrictions, and action error constants.
' Abilities and items are used only by our explicit policy commands.

dim owned(22)
dim inventorySlot(22)
dim allyIds(9)
dim seenMaxHp(9)
dim castRange(3)
dim castDelay(3)
dim castGround(3)
dim castMinimum(3)

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

sub readObject(index)
  id = objectId(index)
  kind = objectKind(index)
  team = objectTeam(index)
  hp = objectHp(index)
  if hp <= 0 then
    exit sub
  end if
  x = originX + side * objectX(index)
  y = originY + side * objectY(index)
  dx = x - myX
  dy = y - myY
  distance = dx * dx + dy * dy
  if kind = 6 then
    ' Camps never distract from lane combat or count as enemy heroes.
    if objectReturning(index) or objectAlive(index) = 0 then
      exit sub
    end if
    camp = objectCamp(index)
    tier = campTier(camp)
    campDx = originX + side * campX(camp) - myX
    campDy = originY + side * campY(camp) - myY
    if campDx * campDx + campDy * campDy > 100 then
      exit sub
    end if
    enoughHealth = selfHp * 10 >= selfMaxHp * 7
    if selfTarget = id then
      enoughHealth = selfHp * 10 >= selfMaxHp * 4
    end if
    if camp >= 0 and camp < campCount() and enoughHealth then
      if selfLevel >= 1 + (tier - 1) * 3 and distance <= 64 then
        score = 100 - distance
        if objectLeader(index) then
          score = score - 10
        end if
        if selfTarget = id then
          score = score + 100
        end if
        if score > campScore then
          campScore = score
          campIndex = index
          campId = id
          campHp = hp
          campXpos = x
          campYpos = y
          campDistance = distance
        end if
      end if
    end if
    exit sub
  end if
  if team = selfTeam then
    if kind = 1 then
      homeX = x
      homeY = y
      enemyX = mapWidth - 1 - x
      enemyY = mapHeight - 1 - y
    elseif kind = 4 then
      ' Protected allied towers still serve as portal anchors.
      dx = x - enemyX
      dy = y - enemyY
      score = dx * dx + dy * dy
      if score < forwardDistance then
        forwardDistance = score
        forwardX = x
        forwardY = y
      end if
    elseif kind = 2 then
      allyIds(allies) = id
      allies = allies + 1
      class = objectClass(index)
      if hp > seenMaxHp(class) then
        seenMaxHp(class) = hp
      end if
      if distance <= 100 then
        friendlyPower = friendlyPower + objectLevel(index) + 2
      end if
      missing = seenMaxHp(class) - hp
      if distance <= healRange * healRange and missing > healMissing then
        healMissing = missing
        healId = id
      end if
    elseif kind = 3 and distance <= 64 then
      tanks = tanks + 1
    end if
    exit sub
  end if
  if kind = 1 then
    enemyX = x
    enemyY = y
  end if
  if kind = 2 and distance <= 144 then
    enemyPower = enemyPower + objectLevel(index) + 2
    if objectMana(index) >= 25 and objectSilenceTicks(index) = 0 then
      enemyPower = enemyPower + 2
    end if
  end if
  if distance < threatDistance then
    threatDistance = distance
    threatX = x
    threatY = y
  end if
  if distance > 324 or objectAlive(index) = 0 then
    exit sub
  end if
  target = objectTarget(index)
  if kind = 4 and target = selfId then
    towerAggro = 1
  end if
  score = 1000 - distance * 2
  if kind = 1 then
    score = score + 500
  elseif kind = 2 then
    score = score + 60 - objectLevel(index) * 8
    if hp < selfAttackDamage * 4 then
      score = score + 250
    end if
  elseif kind = 3 then
    score = score + 100
    if hp <= selfAttackDamage and selfAttackCooldown <= tickRate \ 2 then
      score = score + 400
    end if
  elseif kind = 5 then
    score = score + 40
  end if
  if target = selfId then
    score = score + 40
  end if
  if id = selfTarget then
    score = score + 60
  end if
  if id = blockedId and worldTick < blockedUntil then
    exit sub
  end if
  if score > bestScore then
    bestScore = score
    bestIndex = index
    bestId = id
    bestKind = kind
    bestHp = hp
    bestX = x
    bestY = y
    bestDistance = distance
  end if
end sub

sub observe()
  campScore = -10000
  campId = 0
  bestScore = -10000
  bestId = 0
  bestDistance = 1000000
  threatDistance = 1000000
  forwardDistance = 1000000
  friendlyPower = 0
  enemyPower = 0
  allies = 0
  tanks = 0
  towerAggro = 0
  healId = selfId
  healMissing = selfMaxHp - selfHp
  seenMaxHp(selfClass) = selfMaxHp
  objects = objectCount()
  ' Buildings and heroes precede creeps. Rotate the large creep tail so a
  ' crowded battlefield cannot exhaust the per-decision VM budget.
  for scan = 0 to 95
    index = scan
    if scan >= 48 then
      index = scan + scanOffset
    end if
    if index < objects then
      readObject(index)
    end if
  next scan
  ' Retain a creep target outside this scan window only after validating
  ' its remembered index against the stable ID in the fresh observation.
  if targetIndex >= 48 and targetIndex < objects and selfTarget <> 0 then
    if targetIndex < 48 + scanOffset or targetIndex >= 96 + scanOffset then
      if objectId(targetIndex) = selfTarget then
        readObject(targetIndex)
      end if
    end if
  end if
  scanOffset = scanOffset + 48
  if scanOffset >= objects - 48 then
    scanOffset = 0
  end if
  if bestId = 0 and campId <> 0 and towerAggro = 0 and enemyPower = 0 then
    bestId = campId
    bestIndex = campIndex
    bestKind = 6
    bestHp = campHp
    bestX = campXpos
    bestY = campYpos
    bestDistance = campDistance
  end if
  if bestId = 0 then
    exit sub
  end if
  targetIndex = bestIndex
  ' Divide large integer world units before mixing them with Q16.16 values.
  velocityX = (side * objectVelX(bestIndex) \ 100) / (worldScale \ 100)
  velocityY = (side * objectVelY(bestIndex) \ 100) / (worldScale \ 100)
  ' Do not lead a unit whose control lasts through the predicted impact.
  targetHeld = objectStunTicks(bestIndex)
  targetRoot = objectRootTicks(bestIndex)
  if targetRoot > targetHeld then
    targetHeld = targetRoot
  end if
  facingX = (side * objectFacingX(bestIndex) \ 100) / (worldScale \ 100)
  facingY = (side * objectFacingY(bestIndex) \ 100) / (worldScale \ 100)
  aimedAtUs = facingX * (myX - bestX) + facingY * (myY - bestY)
  if bestKind = 2 then
    ' Visible equipment and potion stacks help judge a close duel.
    for inspectSlot = 0 to 5
      gear = objectItemId(bestIndex, inspectSlot)
      quantity = objectItemCount(bestIndex, inspectSlot)
      if quantity > 0 and bestDistance <= 144 then
        if gear >= 5 and gear <= 20 then
          enemyPower = enemyPower + 1
        elseif gear = 1 or gear = 2 then
          enemyPower = enemyPower + 2
        end if
      end if
    next inspectSlot
  end if
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

sub inventory()
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
      if itemCooldown(itemSlot) = 0 and inOwnSpawn() = 0 then
        consume = 0
        if id = 1 and selfMaxHp - selfHp >= 60 then
          consume = threatDistance > 100 and worldTick - hurtTick > tickRate
        elseif id = 2 and selfHp * 2 < selfMaxHp then
          consume = 1
        elseif id = 22 and selfMaxMana - selfMana >= 45 then
          consume = threatDistance > 100 and worldTick - hurtTick > tickRate
        elseif id = 3 and selfMana * 3 < selfMaxMana then
          consume = bestId <> 0
        elseif id = 4 and selfTarget = bestId and bestId <> 0 then
          consume = bestDistance <= attackRange * attackRange
        end if
        if consume then
          accepted = useItem(itemSlot)
          actionError = lastActionError()
          if accepted then
            owned(id) = owned(id) - 1
            if owned(id) = 0 then
              emptySlots = emptySlots + 1
              inventorySlot(id) = -1
            end if
          end if
        end if
      end if
    end if
  next itemSlot
  if canShop() = 0 then
    exit sub
  end if
  ' Reserve three slots for recovery and travel, two for useful equipment,
  ' and one for a role-specific burst consumable. Stacks top up on return.
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

sub dodgeWarnings()
  dodge = 0
  warnings = spellCount()
  ' Rotate unusually busy spell lists instead of starving later warnings.
  for warning = warningOffset to warningOffset + 11
    if warning < warnings then
      spell = spellAbility(warning)
      caster = spellCasterId(warning)
      hostile = caster <> selfId
      for ally = 0 to allies - 1
        if caster = allyIds(ally) then
          hostile = 0
        end if
      next ally
      ' Recovery effects are harmless, including those with hidden casters.
      if spell = 0 or spell = 2 or spell = 8 or spell = 12 then
        hostile = 0
      end if
      if spell = 13 or spell = 14 or spell = 16 or spell = 20 then
        hostile = 0
      end if
      if spell = 32 or spell = 36 then
        hostile = 0
      end if
      impact = spellImpactTick(warning) - worldTick
      warningX = originX + side * spellX(warning)
      warningY = originY + side * spellY(warning)
      dx = myX - warningX
      dy = myY - warningY
      if hostile and impact > 0 and impact <= tickRate * 3 then
        if dx * dx + dy * dy <= 9 then
          dodge = 1
          dodgeX = myX + 3
          dodgeY = myY + 3
          if dx < 0 then
            dodgeX = myX - 3
          end if
          if dy < 0 then
            dodgeY = myY - 3
          end if
        end if
      end if
    end if
  next warning
  warningOffset = warningOffset + 12
  if warningOffset >= warnings then
    warningOffset = 0
  end if
end sub

sub moveTo(goalX, goalY, marching)
  if selfRootTicks > 0 then
    exit sub
  end if
  if goalX = orderX and goalY = orderY and marching = orderMarch then
    if worldTick - orderTick < 4 then
      exit sub
    end if
  end if
  ' Snap the requested destination to an open nearby surface. A* in the
  ' host still owns the complete route and cliff/ramp collision checks.
  routeScore = 1000000
  routeFound = 0
  floorHeight = terrainHeight(selfX, selfY)
  for offsetY = -1 to 1
    for offsetX = -1 to 1
      tileX = goalX + offsetX
      tileY = goalY + offsetY
      worldTileX = originX + side * tileX
      worldTileY = originY + side * tileY
      if tileX >= 0 and tileX < mapWidth then
        if tileY >= 0 and tileY < mapHeight then
          open = terrainWalkable(worldTileX, worldTileY)
          ground = terrainKind(worldTileX, worldTileY)
          height = terrainHeight(worldTileX, worldTileY)
          depth = terrainWaterDepth(worldTileX, worldTileY)
          if open = 0 then
            for layer = 0 to mapLayers - 1
              worldLayer = layer
              if layer = RedFortLayer or layer = BlueFortLayer then
                worldLayer = layer + selfTeam * (RedFortLayer + BlueFortLayer - 2 * layer)
              end if
              if terrainWalkableAt(worldTileX, worldTileY, worldLayer) then
                open = 1
                ground = terrainKindAt(worldTileX, worldTileY, worldLayer)
                height = terrainHeightAt(worldTileX, worldTileY, worldLayer)
                depth = terrainWaterDepthAt(worldTileX, worldTileY, worldLayer)
                exit for
              end if
            next layer
          end if
          if open and ground <> TerrainNone then
            elevation = height - floorHeight
            if elevation < 0 then
              elevation = -elevation
            end if
            score = (offsetX * offsetX + offsetY * offsetY) * 20
            score = score + depth * 2 + elevation
            if ground = TerrainRoad then
              score = score - 5
            end if
            if score < routeScore then
              routeScore = score
              routeX = tileX
              routeY = tileY
              routeFound = 1
            end if
          end if
        end if
      end if
    next offsetX
  next offsetY
  if routeFound = 0 then
    exit sub
  end if
  if marching then
    accepted = attackMove(originX + side * routeX, originY + side * routeY)
  else
    accepted = walkTo(originX + side * routeX, originY + side * routeY)
  end if
  actionError = lastActionError()
  orderTick = worldTick
  if accepted then
    orderX = goalX
    orderY = goalY
    orderMarch = marching
  elseif actionError = ActionNoRoute then
    ' Try the lane center on the next decision rather than retrying a wall.
    crossedMiddle = 0
    blockedId = bestId
    blockedUntil = worldTick + tickRate * 3
  end if
end sub

sub spells()
  if selfSilenceTicks > 0 then
    exit sub
  end if
  for spellSlot = 0 to 3
    charges = abilityCharges(spellSlot)
    recharge = abilityRecharge(spellSlot)
    damage = abilityDamage(spellSlot)
    healing = abilityHeal(spellSlot)
    restore = abilityRestore(spellSlot)
    cost = abilityManaCost(spellSlot)
    if abilityLevel(spellSlot) > 0 and charges > 0 then
      if abilityCooldown(spellSlot) = 0 and selfMana >= cost then
        castId = 0
        if healing > 0 and healMissing >= healing \ 2 then
          if selfClass = DruidWarden and spellSlot > 0 then
            castId = healId
          elseif selfClass = VanguardKnight and spellSlot = 2 then
            ' Aegis heals around us, even when only an ally is wounded.
            castId = selfId
          elseif selfMaxHp - selfHp >= healing \ 2 then
            castId = selfId
          end if
        elseif restore > 0 and selfMaxMana - selfMana >= restore then
          castId = selfId
        elseif damage > 0 and bestId <> 0 then
          if bestDistance <= castRange(spellSlot) * castRange(spellSlot) then
            if bestDistance >= castMinimum(spellSlot) * castMinimum(spellSlot) then
              ' Save the last recharging charge for valuable targets.
              if bestKind <> 3 or charges > 1 or recharge <= tickRate then
                castId = bestId
              elseif bestHp <= damage then
                castId = bestId
              end if
            end if
          end if
        end if
        if castId <> 0 then
          if castId = bestId and castGround(spellSlot) then
            ' Area spells lead the observed movement, with a bounded lead.
            leadX = velocityX * castDelay(spellSlot)
            leadY = velocityY * castDelay(spellSlot)
            if targetHeld >= castDelay(spellSlot) then
              leadX = 0
              leadY = 0
            end if
            if leadX > 2 then
              leadX = 2
            elseif leadX < -2 then
              leadX = -2
            end if
            if leadY > 2 then
              leadY = 2
            elseif leadY < -2 then
              leadY = -2
            end if
            aimX = bestX + leadX
            aimY = bestY + leadY
            if aimX >= 0 and aimX < mapWidth - 1 then
              if aimY >= 0 and aimY < mapHeight - 1 then
                accepted = castPoint(spellSlot, originX + side * aimX, originY + side * aimY)
                actionError = lastActionError()
                if accepted then
                  exit sub
                end if
              end if
            end if
          end if
          ' Targeted projectiles track their target. Targeted ground rings
          ' offset their center so the enemy is inside the damaging band.
          ' Also fall back here if a led point is outside the map or vision.
          accepted = castTarget(spellSlot, castId)
          actionError = lastActionError()
          if accepted then
            exit sub
          end if
        end if
      end if
    end if
  next spellSlot
end sub

if drafting then
  chooseHero()
  end
end if

' Buy back immediately whenever affordable, including during a long respawn.
if selfHp <= 0 then
  price = buybackPrice()
  if price > 0 and selfGold >= price then
    accepted = buyback()
    actionError = lastActionError()
  end if
  initialized = 0
  end
end if
if selfChannelTicks > 0 or selfStunTicks > 0 then
  end
end if
if worldTick < nextThink then
  end
end if
' Use the same team-relative coordinates for every spatial decision.
side = 1 - selfTeam * 2
originX = selfTeam * (mapWidth - 1)
originY = selfTeam * (mapHeight - 1)
myX = originX + side * selfX
myY = originY + side * selfY

nextThink = worldTick + 6
role = heroRole(selfClass)
attackRange = (selfAttackRange \ 100) / (worldScale \ 100)
speed = (selfMoveSpeed \ 100) / (worldScale \ 100)

if initialized = 0 then
  initialized = 1
  spawnX = myX
  spawnY = myY
  homeX = myX
  homeY = myY
  enemyX = mapWidth - 1 - myX
  enemyY = mapHeight - 1 - myY
  previousHp = selfHp
  progressTick = worldTick
  previousX = myX
  previousY = myY
  crossedMiddle = 0
  retreating = 0
  ' The host exposes effects and costs, but not spell range or cast shape.
  ' These small tables mirror content.nim; all distances are in tiles.
  castRange(0) = 0
  castRange(1) = 1.5
  castRange(2) = 2.5
  castRange(3) = 2
  castDelay(2) = 24
  castDelay(3) = 24
  healRange = 4
  for spellSlot = 0 to 3
    castGround(spellSlot) = spellSlot >= 2
    castMinimum(spellSlot) = 0
  next spellSlot
  if selfClass = VanguardKnight then
    healRange = 7 / 3
    castRange(2) = 7 / 3
    castRange(3) = 11 / 6
    castDelay(2) = 12
    castDelay(3) = 6
  elseif selfClass = Ranger then
    castRange(0) = 7
    castRange(1) = 6
    castRange(2) = 6.5
    castRange(3) = 8
  elseif selfClass = Arcanist then
    castRange(1) = 5.5
    castRange(2) = 6
    castRange(3) = 7
    castDelay(2) = 48
    castDelay(3) = 72
  elseif selfClass = DruidWarden then
    castRange(1) = 4
    castRange(2) = 4
    castRange(3) = 10 / 3
  elseif selfClass = DemonHunter then
    castRange(2) = 2
    castRange(3) = 5
    castDelay(2) = 6
    castGround(3) = 0
  elseif selfClass = DeathKnight then
    castRange(2) = 8 / 3
    castRange(3) = 7 / 3
    castDelay(3) = 12
    castGround(3) = 0
    castMinimum(3) = 2 / 3
  elseif selfClass = Crossbowman then
    castRange(0) = 7
    castRange(1) = 20 / 3
    castRange(2) = 6
    castRange(3) = 7.5
    castDelay(2) = 12
  elseif selfClass = Lich then
    castRange(0) = 6
    castRange(1) = 20 / 3
    castRange(2) = 5
    castRange(3) = 6.5
    castGround(3) = 0
  elseif selfClass = Warlock then
    castRange(1) = 14 / 3
    castRange(2) = 4
    castRange(3) = 5
    castGround(3) = 0
  elseif selfClass = Berserker then
    castRange(3) = 13 / 6
    castDelay(2) = 12
    castDelay(3) = 48
  end if
end if

if selfHp < previousHp then
  hurtTick = worldTick
end if
previousHp = selfHp
if selfAttacksLanded <> previousHits or myX <> previousX or myY <> previousY then
  progressTick = worldTick
end if
previousHits = selfAttacksLanded
previousX = myX
previousY = myY
if worldTick - progressTick > tickRate * 6 and selfTarget <> 0 then
  blockedId = selfTarget
  blockedUntil = worldTick + tickRate * 3
  progressTick = worldTick
end if

learnAbilities()
observe()
inventory()
spells()
dodgeWarnings()

if selfHp * 4 < selfMaxHp or (bestKind = 6 and selfHp * 10 < selfMaxHp * 4) then
  retreating = 1
end if
if selfMana * 8 < selfMaxMana and bestId = 0 then
  retreating = 1
end if
if inOwnSpawn() then
  if selfHp * 10 < selfMaxHp * 9 or selfMana * 10 < selfMaxMana * 9 then
    moveTo(spawnX, spawnY, 0)
    end
  end if
  retreating = 0
end if

if dodge and selfRootTicks = 0 then
  moveTo(dodgeX, dodgeY, 0)
  end
end if
if retreating then
  ' A safe scroll saves the long return trip; damage and control can punish it.
  if owned(21) > 0 and selfPortalCooldown = 0 and selfRootTicks = 0 then
    dx = myX - homeX
    dy = myY - homeY
    if dx * dx + dy * dy > 400 and threatDistance > 144 then
      accepted = useItemAt(inventorySlot(21), originX + side * spawnX, originY + side * spawnY)
      actionError = lastActionError()
      if accepted then
        end
      end if
    end if
  end if
  moveTo(spawnX, spawnY, 0)
  end
end if

if towerAggro and selfHp * 3 < selfMaxHp * 2 and tanks = 0 then
  moveTo(homeX, homeY, 0)
  end
end if
if enemyPower > friendlyPower + 6 and threatDistance < 64 then
  if selfHp * 4 < selfMaxHp * 3 then
    moveTo(homeX, homeY, 0)
    end
  end if
end if

if bestId <> 0 then
  ' Finish a windup before kiting; never cancel every swing with movement.
  if bestKind = 2 and aimedAtUs > 0 and attackRange >= 3 then
    if bestDistance < 4 and selfAttackCooldown > tickRate \ 2 then
      if selfAttacksLanded > 0 and speed > 0 then
        kiteStep = (selfMoveSpeed * tickRate) \ worldScale
        if kiteStep < 1 then
          kiteStep = 1
        elseif kiteStep > 4 then
          kiteStep = 4
        end if
        kiteX = myX + kiteStep
        kiteY = myY + kiteStep
        if bestX >= myX then
          kiteX = myX - kiteStep
        end if
        if bestY >= myY then
          kiteY = myY - kiteStep
        end if
        moveTo(kiteX, kiteY, 0)
        end
      end if
    end if
  end if
  if selfTarget <> bestId then
    accepted = attackTarget(bestId)
    actionError = lastActionError()
    if accepted = 0 then
      blockedId = bestId
      blockedUntil = worldTick + tickRate * 3
    else
      orderTick = 0
    end if
  end if
  end
end if

' Farm separate lanes early, then converge on the enemy god to finish.
middleX = mapWidth \ 2
middleY = mapHeight \ 2
if selfLevel < 6 then
  if role = 0 or role = 2 then
    middleX = mapWidth \ 10
    middleY = mapHeight \ 10
  elseif role = 1 or role = 3 then
    middleX = mapWidth * 9 \ 10
    middleY = mapHeight * 9 \ 10
  end if
end if
dx = myX - middleX
dy = myY - middleY
if dx * dx + dy * dy <= 36 then
  crossedMiddle = 1
end if
goalX = middleX
goalY = middleY
if crossedMiddle then
  goalX = enemyX
  goalY = enemyY
end if
if canShop() and owned(21) > 0 and selfPortalCooldown = 0 then
  dx = myX - forwardX
  dy = myY - forwardY
  if forwardDistance < 1000000 and dx * dx + dy * dy > 400 then
    if threatDistance > 144 then
      accepted = useItemAt(inventorySlot(21), originX + side * forwardX, originY + side * forwardY)
      actionError = lastActionError()
      if accepted then
        end
      end if
    end if
  end if
end if
moveTo(goalX, goalY, 1)
