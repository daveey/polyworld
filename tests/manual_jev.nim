import
  std/[os, strutils],
  bassy,
  polyworld/[llms, timings]

const JevRequest = staticRead("fixtures/jev_request.bas")

echo "Manual paid test: one BASIC request directly to OpenRouter JEV"
block:
  let key = getEnv("OPENROUTER_API_KEY")
  doAssert key.len > 0, "Set OPENROUTER_API_KEY before running this test"
  let scriptClient = newLlmClient(0, LlmConfig(
    baseUrl: "https://openrouter.ai/api",
    key: key,
    oracleModel: DefaultOracleModel,
    interval: 1,
    timeoutMs: 30_000
  ))
  defer:
    scriptClient.close()
  var host = initHost()
  scriptClient.addFunctions(host)
  let program = compile(JevRequest, host)
  var runtime = initRuntime(program, host)
  scriptClient.bindRuntime(runtime)
  scriptClient.beginTick(0)
  discard runtime.run()
  let id = runtime.getGlobal("request")
  doAssert id > 0, "BASIC did not submit its JEV request"
  waitForRequests([scriptClient.requestPoller()])
  let body = scriptClient.response(id)
  echo "HTTP status: ", scriptClient.status(id)
  doAssert scriptClient.status(id) == 200, scriptClient.error(id) & " " & body
  doAssert scriptClient.error(id).len == 0, scriptClient.error(id)
  runtime.restart()
  scriptClient.beginTick(1)
  discard runtime.run()
  let
    strategy = runtime.getGlobal("strategy")
    lane = runtime.getGlobal("lane")
    model = runtime.getString(runtime.getGlobalValue("model$"))
  doAssert runtime.getGlobal("answers") == 2, body
  doAssert strategy in 0 .. 4 and lane in 0 .. 2, body
  doAssert model.startsWith("typesafe/jev-"), body
  echo "BASIC strategy index: ", strategy, ", lane index: ", lane
  echo "OpenRouter response: ", body
