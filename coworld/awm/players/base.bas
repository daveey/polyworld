' AWM reference bot.
'
' Each decision selects one explicit action, then runs again for the next.
' The engine never attacks, chooses targets, discards, or ends turns for you.
' Globals and arrays survive between decisions.
' random(n) returns a seeded integer in 0 to n - 1.
' The script chooses its own class, card order, attacks, targets and discards.
'
' READ-ONLY VALUES
'   selfPlayer enemyPlayer turnNumber
'   selfLife enemyLife energy totalEnergy
'   handSize selfBoardSize enemyBoardSize selfDeckSize enemyDeckSize
'   playerCount currentPlayer tossCount triggerTargets
'   selectingClass selfClass enemyClass
'   Setup: call pickClass(0=Archer, 1=Warrior, 2=Mage), then END.
'   playerClass(p) returns any seat's class.
'
' HAND QUERIES (index 0 to handSize - 1)
'   handCost(i)       energy cost
'   handKind(i)       0 = minion, 1 = spell, 2 = trinket
'   handPower(i)      attack (minions only)
'   handToughness(i)  toughness (minions only)
'   canPlay(i)        1 if affordable
'   needsChoice(i)    1 if the card needs a target
'
' CHOICE QUERIES
'   choiceCount(handIndex)              number of valid targets
'   choiceKind(handIndex, choiceIndex)  0=canceled 1=noTarget 2=hero 3=creature
'   choiceOwner(handIndex, choiceIndex) player who owns the target (-1 if n/a)
'   choiceId(handIndex, choiceIndex)    stable minion ID (0 for a hero)
'   (these cover a card's first target; for cards with several targets:)
'   targetCount(handIndex)                         targets the card asks for
'   helpsTarget(handIndex, step)                   1 if that target should be yours
'   targetChoiceCount(handIndex, step)             valid choices for that target
'   targetChoiceKind(handIndex, step, choiceIndex)
'   targetChoiceOwner(handIndex, step, choiceIndex)
'
' BOARD QUERIES (index 0 to selfBoardSize/enemyBoardSize - 1)
'   selfBoardPower(i)  selfBoardHp(i)
'   enemyBoardPower(i) enemyBoardHp(i)
'
' COMMANDS (at most one per decision)
'   playCard(handIndex)                    play without a target, returns 1 on success
'   playCardChoice(handIndex, choiceIndex) play with a specific target
'   playCardChoices(handIndex, first, second) play a two-target card

' EXPLICIT ACTIONS AND VISIBLE BOARD QUERIES
'   handName$(i), boardCount(player), boardId(player, index)
'   boardName$(player, index), boardCard$(player, index)
'   handId$(i) returns the unique printed card name.
'   cardName$(id$), cardRules$(id$), cardKind(id$), cardClass(id$)
'   cardCost(id$), cardPower(id$), cardToughness(id$)
'   cardHasKeyword(id$, k), boardHasKeyword(p, i, k): k=0 is Ranged.
'   boardPower(p, i), boardHp(p, i), boardKind(p, i)
'   boardReady(p, i), boardAttacked(p, i)
'   playerLife(p), playerEnergy(p), playerTotalEnergy(p)
'   playerHandSize(p), playerDeckSize(p), playerDead(p)
'   attackChoiceCount(id), attackChoiceKind(id, choice)
'   attackChoiceOwner(id, choice), attackChoiceId(id, choice)
'   attack(id, choice)                 attack one chosen hero or minion
'   endTurn()                         finish without any automatic attacks
'   discardCards("picks")              discard tossCount indexes in picks()
'   resolveTrigger("picks")            answer triggerTargets in picks()
'   triggerChoiceCount(step), triggerChoiceKind(step, choice)
'   triggerChoiceOwner(step, choice), triggerChoiceId(step, choice)
'   triggerHelpsTarget(step)
'   playCardTargets(handIndex, "picks") choose any number of card targets
'   nextChoiceCount(handIndex, "picks", pickedCount)
'   nextChoiceKind(handIndex, "picks", pickedCount, choice)
'   nextChoiceOwner(handIndex, "picks", pickedCount, choice)
'   nextChoiceId(handIndex, "picks", pickedCount, choice)
' Use handIndex = -1 for trigger queries. Prefix queries include earlier picks.
' Successful commands return 1; refused commands return 0 and do nothing.
' Exactly one successful command is allowed per decision. END alone is not
' an action. A decision with no action stops the match with a player error.

IF selectingClass THEN
  pickClass(random(3))
  END
END IF

DIM picks(1023)
IF tossCount > 0 THEN
  ' Shuffle the hand indexes, then explicitly discard the first required ones.
  i = 0
  WHILE i < handSize
    picks(i) = i
    i = i + 1
  WEND
  i = 0
  WHILE i < tossCount
    j = i + random(handSize - i)
    swap = picks(i)
    picks(i) = picks(j)
    picks(j) = swap
    i = i + 1
  WEND
  discardCards("picks")
  END
END IF
IF triggerTargets > 0 THEN
  ' Every legal trigger target is eligible, including declining the target.
  s = 0
  WHILE s < triggerTargets
    n = nextChoiceCount(-1, "picks", s)
    IF n = 0 THEN STOP
    picks(s) = random(n)
    s = s + 1
  WEND
  resolveTrigger("picks")
  END
END IF

' Try attacks before cards on some decisions and after cards on others.
' This allows attacking a Primordial before bouncing and replaying it.
IF random(2) THEN GOSUB attacks

' Visit every card from a random starting position, choosing its targets
' sequentially. This covers all cards, multiple targets and self-bounces.
IF handSize > 0 THEN
  start = random(handSize)
  offset = 0
  WHILE offset < handSize
    i = (start + offset) MOD handSize
    IF canPlay(i) THEN
      count = targetCount(i)
      IF count = 0 THEN
        IF playCard(i) THEN END
      ELSE
        valid = 1
        s = 0
        WHILE s < count AND valid
          n = nextChoiceCount(i, "picks", s)
          IF n = 0 THEN
            valid = 0
          ELSE
            GOSUB aim
          END IF
          s = s + 1
        WEND
        IF valid THEN
          IF playCardTargets(i, "picks") THEN END
        END IF
      END IF
    END IF
    offset = offset + 1
  WEND
END IF

GOSUB attacks
endTurn()
END

aim:
' Choose the s'th target of hand card i. A target that helps goes to one of
' your own cards, any other to the next living opponent's, picked at random
' among that side: Duel buffs your minion and duels theirs, not itself. With
' nothing on the wanted side every choice stays eligible, so a lone minion
' still bounces itself and hero-only cards keep their random pick.
mine = helpsTarget(i, s)
want = enemyPlayer
IF mine THEN want = selfPlayer
GOSUB tally
IF wanted = 0 AND mine = 0 THEN
  ' The designated enemy has nothing to aim at: any opponent will do.
  want = -1
  GOSUB tally
END IF
IF wanted = 0 THEN
  picks(s) = random(n)
  RETURN
END IF
k = random(wanted)
c = 0
WHILE c < n
  o = nextChoiceOwner(i, "picks", s, c)
  GOSUB wants
  IF hit THEN
    IF k = 0 THEN
      picks(s) = c
      c = n
    END IF
    k = k - 1
  END IF
  c = c + 1
WEND
RETURN

tally:
' How many of the target's choices are on the wanted side.
wanted = 0
c = 0
WHILE c < n
  o = nextChoiceOwner(i, "picks", s, c)
  GOSUB wants
  IF hit THEN wanted = wanted + 1
  c = c + 1
WEND
RETURN

wants:
' hit = 1 when owner o is the wanted player, or any opponent when want is
' -1. Choices with no owner, like declining the target, never match.
hit = 0
IF o < 0 THEN RETURN
IF want >= 0 THEN
  IF o = want THEN hit = 1
ELSE
  IF o <> selfPlayer THEN hit = 1
END IF
RETURN

attacks:
' Visit every permanent. Every legal hero and minion target can be picked,
' across all opponents. Trinkets and unready minions have no attack choices.
IF boardCount(selfPlayer) > 0 THEN
  start = random(boardCount(selfPlayer))
  offset = 0
  WHILE offset < boardCount(selfPlayer)
    i = (start + offset) MOD boardCount(selfPlayer)
    id = boardId(selfPlayer, i)
    n = attackChoiceCount(id)
    IF n > 0 THEN
      IF attack(id, random(n)) THEN END
    END IF
    offset = offset + 1
  WEND
END IF
RETURN
