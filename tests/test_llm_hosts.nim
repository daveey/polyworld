import
  std/[os, strutils, tempfiles],
  bassy,
  polyworld/cli

import ../examples/call_to_adventure/bots as ctaBots
import ../examples/call_to_adventure/content as ctaContent
import ../examples/call_to_adventure/sim as ctaSim
import ../examples/light_vs_dark/bots as lvdBots
import ../examples/light_vs_dark/content as lvdContent
import ../examples/light_vs_dark/maps as lvdMaps
import ../examples/light_vs_dark/sim as lvdSim
import ../examples/gods_of_the_arena/bots as gotaBots
import ../examples/gods_of_the_arena/maps as gotaMaps
import ../examples/gods_of_the_arena/replays as gotaReplays
import ../examples/gods_of_the_arena/sim as gotaSim

const Program = """
remoteAvailable = llmAvailable()
quoted$ = jsonQuote$("hello")
text$ = jsonGet$(quoted$, "")
sent = sendChat(-2, "global hello")
message$ = pullMailbox$()
from = mailboxId()
while mailboxCount() > 0
  ignored$ = pullMailbox$()
wend
"""

template testHost(kind: static[string]) =
  ## Checks LLM and mailbox bindings through one game's actual host.
  echo "Testing LLM and mailbox host: ", kind
  block:
    let
      directory = createTempDir("polyworld-llm-hosts-", "")
      path = directory / "player.bas"
      hadSetting = existsEnv("COGAME_LLM")
      setting = getEnv("COGAME_LLM")
    putEnv("COGAME_LLM", "off")
    defer:
      removeDir(directory)
      if hadSetting:
        putEnv("COGAME_LLM", setting)
      else:
        delEnv("COGAME_LLM")
    writeFile(path, Program)
    when kind == "cta":
      let game = ctaSim.newGame(2026)
    elif kind == "lvd":
      let game = lvdSim.newGame(lvdMaps.generateMap(lvdContent.DefaultSeed), 240)
    else:
      let game = gotaSim.newGame(gotaMaps.generateMap(54), 240, 10, false,
        gotaReplays.ReplayData(),
        drafting = false)

    when kind == "lvd":
      game.loadBots([Program, Program])
    elif kind == "cta":
      game.loadBots([BotGroup(path: path, count: ctaContent.PartySize)])
    else:
      game.loadBots([BotGroup(path: path, count: 10)])
    for tick in 1 .. 2:
      game.world.tick = int32(tick)
      when kind == "cta":
        for slot in 0'i32 ..< ctaContent.PartySize:
          game.runBotDecisions(slot)
      else:
        game.runBotDecisions()
      when kind == "lvd":
        let vms = game.brains
      else:
        let vms = game.heroVms
      for vm in vms:
        doAssert vm != nil and not vm.failed, vm.lastError
        doAssert vm.runtime.getGlobal("remoteAvailable") == 0
        doAssert vm.runtime.getGlobal("sent") == vms.len
        doAssert vm.runtime.getGlobal("from") == -2
        doAssert vm.runtime.getString(vm.runtime.getGlobalValue("message$")) ==
          "global hello"
        doAssert vm.runtime.getString(vm.runtime.getGlobalValue("text$")) == "hello"
        doAssert vm.pollRequests != nil and not vm.pollRequests()
        let large = vm.runtime.putString(repeat('x', 64 * 1024))
        doAssert vm.runtime.getString(large).len == 64 * 1024

when defined(llmCta):
  testHost("cta")
elif defined(llmLvd):
  testHost("lvd")
else:
  testHost("gota")
  testHost("cta")
  testHost("lvd")
