' Set COGAME_LLM_MODEL on the host or supply a model ID to llmAsk.
if request > 0 then
  status = llmPoll(request)
  if status = 1 then
    answer$ = llmText$(request)
    print answer$
    request = 0
  elseif status = -1 then
    print llmError$(request)
    request = 0
  end if
end if
if llmReady() = 0 then
  request = llmAsk("", "Give one short tactical suggestion.")
end if
