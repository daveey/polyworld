' AWM reference bot.
'
' Each decision runs from the top of this file. The bot plays at most one
' card per invocation; the game calls it repeatedly until no card is played,
' then ends the turn. Globals and arrays survive between decisions.
'
' READ-ONLY VALUES
'   selfPlayer enemyPlayer turnNumber
'   selfLife enemyLife energy totalEnergy
'   handSize selfBoardSize enemyBoardSize selfDeckSize enemyDeckSize
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

i = 0
WHILE i < handSize
  IF canPlay(i) THEN
    IF targetCount(i) = 2 THEN
      ' Two targets (Duel): each goes on one of our minions if its rule
      ' helps the target, else on an enemy minion.
      pick0 = -1
      pick1 = -1
      s = 0
      WHILE s < 2
        want = enemyPlayer
        IF helpsTarget(i, s) = 1 THEN
          want = selfPlayer
        END IF
        found = -1
        nChoices = targetChoiceCount(i, s)
        j = 0
        WHILE j < nChoices
          IF found < 0 AND targetChoiceKind(i, s, j) = 3 AND targetChoiceOwner(i, s, j) = want THEN
            found = j
          END IF
          j = j + 1
        WEND
        IF s = 0 THEN
          pick0 = found
        ELSE
          pick1 = found
        END IF
        s = s + 1
      WEND
      IF pick0 >= 0 AND pick1 >= 0 THEN
        playCardChoices(i, pick0, pick1)
        END
      END IF
    ELSE
    IF needsChoice(i) THEN
      nChoices = choiceCount(i)
      best = -1

      ' Prefer the enemy hero.
      j = 0
      WHILE j < nChoices
        IF choiceKind(i, j) = 2 AND choiceOwner(i, j) = enemyPlayer THEN
          best = j
        END IF
        j = j + 1
      WEND

      ' Then an enemy minion.
      IF best < 0 THEN
        j = 0
        WHILE j < nChoices
          IF choiceKind(i, j) = 3 AND choiceOwner(i, j) = enemyPlayer THEN
            best = j
          END IF
          j = j + 1
        WEND
      END IF

      ' Then no-target if allowed.
      IF best < 0 THEN
        j = 0
        WHILE j < nChoices
          IF choiceKind(i, j) = 1 THEN
            best = j
          END IF
          j = j + 1
        WEND
      END IF

      IF best >= 0 THEN
        playCardChoice(i, best)
        END
      END IF
    ELSE
      playCard(i)
      END
    END IF
    END IF
  END IF
  i = i + 1
WEND
