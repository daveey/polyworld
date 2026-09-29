' Supply any model and Chat Completions fields in the JSON body.
' Replace the model ID with one enabled by your sidecar.
if request > 0 then
  status = llmPoll(request)
  if status = 1 then
    response$ = llmResponse$(request)
    answer$ = jsonGet$(response$, "/choices/0/message/content")
    print answer$
    request = 0
  elseif status = -1 then
    print llmStatus(request), llmError$(request)
    request = 0
  end if
end if
if llmReady() = 0 then
  model$ = "your-provider/your-model"
  prompt$ = "Return a JSON object with a tactical suggestion."
  body$ = "{""model"":" + jsonQuote$(model$)
  body$ = body$ + ",""messages"":[{""role"":""user"",""content"":"
  body$ = body$ + jsonQuote$(prompt$) + "}],""response_format"":{""type"":""json_object""}}"
  request = llmRequest("POST", "/v1/chat/completions", body$)
end if
