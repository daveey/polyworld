' Jev returns typed judgments through the SystemOne endpoint.
if request > 0 then
  status = oraclePoll(request)
  if status > 0 then
    print "Hold probability in thousandths:", oracleAnswer(request, "hold")
    print "Choice index:", oracleAnswer(request, "mode")
    request = 0
  elseif status = -1 then
    print llmError$(request)
    request = 0
  end if
end if
if oracleReady() = 0 then
  oracleState("self.hp", 3)
  oracleStateText("objective", "Keep the checkpoint.")
  oracleQuestion("hold", 0, "Should we hold position?")
  oracleCriterion("hold", "true", "Staying protects our objective.")
  oracleCriterion("hold", "false", "Leaving is necessary to survive.")
  oracleQuestion("mode", 2, "Choose a tactical posture.")
  oracleCriterion("mode", "hold", "Defend the checkpoint.")
  oracleCriterion("mode", "advance", "Move toward the next checkpoint.")
  request = oracleAsk()
end if
