' Answer direct messages with a normal LLM response.
' While the LLM is busy, unread messages remain queued.
if request > 0 then
  status = llmPoll(request)
  if status = 1 then
    answer$ = llmText$(request)
    sendChat(replyTo, left$(answer$, 1024))
    request = 0
  elseif status = -1 then
    print llmError$(request)
    request = 0
  end if
end if
if llmReady() = 0 then
  while request = 0 and mailboxCount() > 0
    question$ = pullMailbox$()
    if mailboxId() >= 0 and mailboxId() <> mailboxSelf() then
      replyTo = mailboxId()
      prompt$ = "Answer briefly in plain text: " + question$
      request = llmAsk("", prompt$)
    end if
  wend
end if
