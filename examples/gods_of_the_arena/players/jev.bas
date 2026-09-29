' JEV chooses the macro strategy and lane every 15 simulation seconds.
' Local BASIC handles movement, attacks, drafting, and emergency retreats.
' Decisions and pending request IDs persist across ticks.

dim laneX(2)
dim laneY(2)
dim friends(2)
dim foes(2)
dim creeps(2)
dim towers(2)
dim friendlyTowers(2)
dim strategies$(4)
dim lanes$(2)

sub chooseHero()
  if draftTurnId <> selfId then
    exit sub
  end if
  for candidate = 0 to 9
    if heroAvailable(candidate) then
      draftHero(candidate)
      exit sub
    end if
  next candidate
end sub

sub moveToGoal(marching)
  if selfRootTicks > 0 then
    exit sub
  end if
  if marching then
    accepted = attackMove(goalX, goalY)
  else
    accepted = walkTo(goalX, goalY)
  end if
  if accepted then
    exit sub
  end if
  ' Generated terrain can block an approximate lane waypoint.
  for offsetY = -2 to 2
    for offsetX = -2 to 2
      tileX = (goalX \ 1) + offsetX
      tileY = (goalY \ 1) + offsetY
      if tileX >= 0 and tileX < mapWidth and tileY >= 0 and tileY < mapHeight then
        if terrainWalkable(tileX, tileY) then
          if marching then
            accepted = attackMove(tileX, tileY)
          else
            accepted = walkTo(tileX, tileY)
          end if
          if accepted then
            exit sub
          end if
        end if
      end if
    next offsetX
  next offsetY
end sub

sub observe()
  for laneIndex = 0 to 2
    friends(laneIndex) = 0
    foes(laneIndex) = 0
    creeps(laneIndex) = 0
    towers(laneIndex) = 0
    friendlyTowers(laneIndex) = 0
  next laneIndex
  targetId = 0
  targetScore = -1000000
  allies = 0
  allyX = 0
  allyY = 0
  homeThreats = 0
  homeHp = 0
  enemyHp = 0
  objects = objectCount()
  scanned = 0
  ' Structures and heroes precede creeps. Rotate the crowded creep tail.
  for scan = 0 to 95
    index = scan
    if scan >= 48 then
      index = scan + scanOffset
    end if
    if index < objects and objectAlive(index) then
      scanned = scanned + 1
      kind = objectKind(index)
      team = objectTeam(index)
      x = objectX(index)
      y = objectY(index)
      dx = x - selfX
      dy = y - selfY
      distance = dx * dx + dy * dy
      ' Approximate lane sectors around the reference policy's waypoints.
      sector = 1
      if x + y < (mapWidth + mapHeight) * 3 / 8 then
        sector = 0
      elseif x + y > (mapWidth + mapHeight) * 5 / 8 then
        sector = 2
      end if
      if team = selfTeam then
        if kind = 1 then
          homeX = x
          homeY = y
          homeHp = objectHp(index)
        elseif kind = 2 then
          friends(sector) = friends(sector) + 1
          if objectId(index) <> selfId then
            allies = allies + 1
            allyX = allyX + x
            allyY = allyY + y
          end if
        elseif kind = 4 then
          friendlyTowers(sector) = friendlyTowers(sector) + 1
        end if
      elseif team >= 0 and kind <> 6 then
        if kind = 1 then
          enemyX = x
          enemyY = y
          enemyHp = objectHp(index)
        elseif kind = 2 then
          foes(sector) = foes(sector) + 1
        elseif kind = 3 then
          creeps(sector) = creeps(sector) + 1
        elseif kind = 4 then
          towers(sector) = towers(sector) + 1
        end if
        homeDx = x - homeX
        homeDy = y - homeY
        if kind = 2 and homeDx * homeDx + homeDy * homeDy < 225 then
          homeThreats = homeThreats + 1
        end if
        if distance < 144 then
          score = 100 - distance
          eligible = sector = chosenLane
          if strategy = 0 then
            eligible = eligible and kind = 3
            if objectHp(index) <= selfAttackDamage then
              score = score + 200
            end if
          elseif strategy = 1 then
            eligible = eligible and kind = 2
            score = score + 100 - objectHp(index) / 10
          elseif strategy = 2 then
            if kind = 4 or kind = 1 or kind = 5 then
              score = score + 150
            end if
          elseif strategy = 3 then
            eligible = homeDx * homeDx + homeDy * homeDy < 400
          else
            eligible = distance < 25
          end if
          if objectTarget(index) = selfId and distance < 16 then
            eligible = 1
          end if
          if eligible and score > targetScore then
            targetScore = score
            targetId = objectId(index)
          end if
        end if
      end if
    end if
  next scan
  scanOffset = scanOffset + 48
  if scanOffset >= objects - 48 then
    scanOffset = 0
  end if
end sub

sub askAdvice()
  if request <> 0 or worldTick < nextAdvice then
    exit sub
  end if
  if oracleReady() <> 0 then
    exit sub
  end if
  stage$ = "early laning and farming"
  if selfLevel >= 6 or worldTick >= tickRate * 180 then
    stage$ = "mid game rotations and objectives"
  end if
  if selfLevel >= 12 or worldTick >= tickRate * 600 then
    stage$ = "late game and finishing the enemy god"
  end if
  summary$ = "Stage: " + stage$ + ". Elapsed seconds:" + str$(worldTick / tickRate)
  summary$ = summary$ + ". Player:" + str$(mailboxSelf()) + ", team:" + str$(selfTeam)
  summary$ = summary$ + ", class:" + str$(selfClass) + ", role:" + str$(heroRole(selfClass))
  summary$ = summary$ + ", level:" + str$(selfLevel) + ", gold:" + str$(selfGold)
  summary$ = summary$ + ", HP:" + str$(selfHp) + "/" + str$(selfMaxHp)
  summary$ = summary$ + ", mana:" + str$(selfMana) + "/" + str$(selfMaxMana)
  summary$ = summary$ + ", deaths:" + str$(selfDeaths)
  summary$ = summary$ + ", position:(" + str$(selfX) + "," + str$(selfY) + ")."
  summary$ = summary$ + " Current strategy: " + strategies$(strategy) + ", lane: " + lanes$(chosenLane) + "."
  summary$ = summary$ + " Home god HP:" + str$(homeHp) + ", enemy god HP:" + str$(enemyHp)
  summary$ = summary$ + ", visible enemy heroes near home:" + str$(homeThreats) + "."
  oracleStateText("stage", stage$)
  oracleStateText("situation", summary$)
  for laneIndex = 0 to 2
    report$ = lanes$(laneIndex) + ": allied heroes=" + str$(friends(laneIndex))
    report$ = report$ + ", enemy heroes=" + str$(foes(laneIndex))
    report$ = report$ + ", enemy creeps=" + str$(creeps(laneIndex))
    report$ = report$ + ", allied towers=" + str$(friendlyTowers(laneIndex))
    report$ = report$ + ", enemy towers=" + str$(towers(laneIndex)) + "."
    oracleNote(report$)
  next laneIndex
  oracleNote("Win by destroying the enemy god. Roles: 0 frontline, 1 carry, 2 mage, 3 support, 4 fighter. This example uses basic attacks and movement.")
  oracleNote("All facts come from the permitted observation, not hidden enemy state. Lane counts are approximate sectors and a bounded sample; zero does not prove absence. Zero god HP can mean unavailable or protected, not destroyed.")
  oracleNote("Top is the low-X/low-Y outer route, mid crosses the center, bottom is the high-X/high-Y outer route. Choose one coherent strategy and lane for the next 15 seconds. Emergency healing overrides advice.")
  oracleQuestion("strategy", 2, "What should this hero do now, considering the stage, health, team, threats, and objectives?")
  oracleCriterion("strategy", "farm", "Farm enemy lane creeps for gold and experience; favor safe last hits.")
  oracleCriterion("strategy", "gank", "Rotate to the chosen lane and attack a visible enemy hero.")
  oracleCriterion("strategy", "push", "Advance down the chosen lane, attack structures, and pressure the enemy god.")
  oracleCriterion("strategy", "defend", "Return to our god and intercept nearby enemy attackers.")
  oracleCriterion("strategy", "regroup", "Move toward the allied heroes before taking another fight.")
  oracleQuestion("lane", 2, "Which lane best supports your selected strategy? Consider the lane reports and avoid unnecessary switching.")
  oracleCriterion("lane", "top", "Use the top outer lane.")
  oracleCriterion("lane", "mid", "Use the central lane.")
  oracleCriterion("lane", "bottom", "Use the bottom outer lane.")
  request = oracleAsk()
  if request > 0 then
    nextAdvice = worldTick + tickRate * 15
  else
    nextAdvice = worldTick + tickRate * 5
  end if
end sub

if drafting then
  chooseHero()
  end
end if

if initialized = 0 then
  initialized = 1
  strategy = 0
  chosenLane = mailboxSelf() mod 3
  strategies$(0) = "farm"
  strategies$(1) = "gank"
  strategies$(2) = "push"
  strategies$(3) = "defend"
  strategies$(4) = "regroup"
  lanes$(0) = "top"
  lanes$(1) = "mid"
  lanes$(2) = "bottom"
  for laneIndex = 0 to 2
    laneX(laneIndex) = mapWidth * (1 + laneIndex * 4) / 10
    laneY(laneIndex) = mapHeight * (1 + laneIndex * 4) / 10
  next laneIndex
  homeX = selfX
  homeY = selfY
  spawnX = selfX
  spawnY = selfY
  enemyX = mapWidth - 1 - selfX
  enemyY = mapHeight - 1 - selfY
end if

if request > 0 then
  status = oraclePoll(request)
  if status > 0 then
    advisedStrategy = oracleAnswer(request, "strategy")
    advisedLane = oracleAnswer(request, "lane")
    if advisedStrategy >= 0 and advisedStrategy <= 4 and advisedLane >= 0 and advisedLane <= 2 then
      strategy = advisedStrategy
      chosenLane = advisedLane
      crossedLane = 0
      nextAction = 0
      print "JEV strategy: ", strategies$(strategy), ", lane: ", lanes$(chosenLane)
    end if
    request = 0
  elseif status = -1 then
    print "JEV unavailable: ", llmError$(request)
    request = 0
    nextAdvice = worldTick + tickRate * 5
  end if
end if

if selfHp <= 0 then
  crossedLane = 0
  end
end if
if selfChannelTicks > 0 or selfStunTicks > 0 then
  end
end if
if worldTick < nextAction then
  end
end if
nextAction = worldTick + 6
observe()
askAdvice()

for upgrade = 1 to 4
  if canLevelAbility(3) then
    levelAbility(3)
  elseif canLevelAbility(1) then
    levelAbility(1)
  elseif canLevelAbility(2) then
    levelAbility(2)
  elseif canLevelAbility(0) then
    levelAbility(0)
  end if
next upgrade

if selfHp * 4 < selfMaxHp then
  retreating = 1
end if
if inOwnSpawn() and selfHp * 10 >= selfMaxHp * 9 then
  retreating = 0
end if
if retreating then
  goalX = spawnX
  goalY = spawnY
  moveToGoal(0)
  end
end if
if targetId <> 0 then
  if selfTarget <> targetId then
    attackTarget(targetId)
  end if
  end
end if

goalX = laneX(chosenLane)
goalY = laneY(chosenLane)
dx = selfX - goalX
dy = selfY - goalY
if dx * dx + dy * dy < 36 then
  crossedLane = 1
end if
if strategy = 2 and crossedLane then
  goalX = enemyX
  goalY = enemyY
elseif strategy = 3 then
  goalX = homeX
  goalY = homeY
elseif strategy = 4 and allies > 0 then
  goalX = allyX / allies
  goalY = allyY / allies
end if
moveToGoal(1)
