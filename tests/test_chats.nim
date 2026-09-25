import
  std/[os, strutils, tempfiles],
  bassy,
  polyworld/[cli, mailboxes]
import ../examples/call_to_adventure/bots as ctaBots
import ../examples/call_to_adventure/content as ctaContent
import ../examples/call_to_adventure/sim as ctaSim
import ../examples/gods_of_the_arena/bots as gotaBots
import ../examples/gods_of_the_arena/maps as gotaMaps
import ../examples/gods_of_the_arena/replays as gotaReplays
import ../examples/gods_of_the_arena/sim as gotaSim
import ../examples/light_vs_dark/bots as lvdBots
import ../examples/light_vs_dark/content as lvdContent
import ../examples/light_vs_dark/maps as lvdMaps
import ../examples/light_vs_dark/sim as lvdSim

const Program = """
sent = sendChat(mailboxSelf(), "private hello")
message$ = pullMailbox$()
from = mailboxId()
"""

const CtaProgram = """
rejectedTeam = sendChat(-1, "team")
rejectedDm = sendChat(mailboxSelf(), "direct")
sent = sendChat(-2, "nearby hello")
message$ = pullMailbox$()
from = mailboxId()
while mailboxCount() > 0
  ignored$ = pullMailbox$()
wend
"""

proc checkMailboxes[T](game: T) =
  ## Checks each game's chat routing and repeated reads through BASIC.
  template send(sender, target, text: untyped): untyped =
    ## Uses the game's own routing implementation.
    when T is ctaSim.Game:
      ctaBots.sendChat(game, sender, target, text)
    elif T is gotaSim.Game:
      gotaBots.sendChat(game, sender, target, text)
    else:
      lvdBots.sendChat(game, sender, target, text)
  when T is gotaSim.Game:
    doAssert send(0, -1, "team") == 5
    for slot, inbox in game.inboxes:
      let teammate = game.world.heroes[slot].team == game.world.heroes[0].team
      doAssert inbox.count == int(teammate)
      if teammate:
        doAssert inbox.messages[inbox.first] == "team"
        doAssert inbox.pop() == -1
  else:
    doAssert send(0, -1, "team") == 0
    for inbox in game.inboxes:
      doAssert inbox.count == 0
  doAssert send(0, -2, "global") == game.inboxes.len
  for inbox in game.inboxes:
    doAssert inbox.messages[inbox.first] == "global"
    doAssert inbox.pop() == -2
  when T is ctaSim.Game:
    for target in 0 ..< game.inboxes.len:
      doAssert send(0, target, "direct") == 0
    for inbox in game.inboxes:
      doAssert inbox.count == 0
  else:
    doAssert send(0, 1, "direct") == 1
    for slot, inbox in game.inboxes:
      doAssert inbox.count == int(slot == 1)
    doAssert game.inboxes[1].messages[game.inboxes[1].first] == "direct"
    doAssert game.inboxes[1].pop() == 0
  doAssert send(-1, -2, "invalid") == 0
  doAssert send(game.inboxes.len, -2, "invalid") == 0
  doAssert send(0, -3, "invalid") == 0
  doAssert send(0, game.inboxes.len, "invalid") == 0
  for i in 0 ..< MaxMailboxMessages:
    doAssert game.inboxes[0].push(-2, "full")
  doAssert send(0, -2, "partial") == game.inboxes.len - 1
  doAssert game.inboxes[0].count == MaxMailboxMessages
  for inbox in game.inboxes:
    while inbox.count > 0:
      discard inbox.pop()
  for tick in 1 .. 300:
    game.world.tick = int32(tick)
    when T is ctaSim.Game:
      for slot in 0'i32 ..< ctaContent.PartySize:
        ctaBots.runBotDecisions(game, slot)
    elif T is gotaSim.Game:
      gotaBots.runBotDecisions(game)
    else:
      lvdBots.runBotDecisions(game)
    when T is lvdSim.Game:
      let vms = game.brains
    else:
      let vms = game.heroVms
    for index, vm in vms:
      doAssert vm != nil and not vm.failed, vm.lastError
      when T is ctaSim.Game:
        doAssert vm.runtime.getGlobal("rejectedTeam") == 0
        doAssert vm.runtime.getGlobal("rejectedDm") == 0
        doAssert vm.runtime.getGlobal("sent") == ctaContent.PartySize
        doAssert vm.runtime.getGlobal("from") == -2
        doAssert vm.runtime.getString(vm.runtime.getGlobalValue("message$")) ==
          "nearby hello"
      else:
        doAssert vm.runtime.getGlobal("sent") == 1
        doAssert vm.runtime.getGlobal("from") == index
        doAssert vm.runtime.getString(vm.runtime.getGlobalValue("message$")) ==
          "private hello"
      let large = vm.runtime.putString(repeat('x', 1024))
      doAssert vm.runtime.getString(large).len == 1024
  when defined(nimAllocStats) and T is gotaSim.Game:
    # The GotA decision runner leaves its active game bound for host calls.
    # Isolate mailbox callbacks and restart from unrelated world preparation.
    let before = getAllocStats()
    for decision in 0 ..< 1000:
      for vm in game.heroVms:
        vm.runtime.restart()
        discard vm.runtime.run()
    let after = getAllocStats()
    doAssert after == before, $(after - before)

proc checkRange(game: ctaSim.Game) =
  ## Checks inclusive tile range, level isolation, and routing at send time.
  for inbox in game.inboxes:
    while inbox.count > 0:
      discard inbox.pop()
  for slot in 0 ..< ctaContent.PartySize:
    game.world.actors[slot].home.level = 0
    game.world.actors[slot].home.x = 20
    game.world.actors[slot].home.z = 20
  game.world.actors[1].home.x = 36
  game.world.actors[2].home.x = 37
  game.world.actors[3].home.level = 1
  doAssert ctaBots.sendChat(game, 0, -2, "boundary") == 2
  doAssert game.inboxes[0].pop() == -2
  doAssert game.inboxes[2].count == 0
  doAssert game.inboxes[3].count == 0
  game.world.actors[1].home.level = 1
  doAssert game.inboxes[1].messages[game.inboxes[1].first] == "boundary"
  doAssert game.inboxes[1].pop() == -2
  doAssert ctaBots.sendChat(game, 0, -2, "different level") == 1
  doAssert game.inboxes[0].pop() == -2
  doAssert game.inboxes[1].count == 0
  game.world.actors[1].home.level = 0
  game.world.actors[1].home.z = 36
  doAssert ctaBots.sendChat(game, 0, -2, "diagonal") == 2
  doAssert game.inboxes[0].pop() == -2
  doAssert game.inboxes[1].pop() == -2
  game.world.actors[1].home.z = 37
  doAssert ctaBots.sendChat(game, 0, -2, "outside") == 1
  doAssert game.inboxes[0].pop() == -2
  doAssert game.inboxes[1].count == 0

echo "Testing default mailboxes through all three games' BASIC hosts"
block:
  let
    directory = createTempDir("polyworld-mailboxes-", "")
    path = directory / "player.bas"
  defer:
    removeDir(directory)
  writeFile(path, Program)

  let gota = gotaSim.newGame(
    gotaMaps.generateMap(54),
    240,
    10,
    false,
    gotaReplays.ReplayData(),
    drafting = false
  )
  gotaBots.loadBots(gota, [BotGroup(path: path, count: 10)])
  echo "Checking GotA"
  gota.checkMailboxes()
  echo "GotA passed"

  let cta = ctaSim.newGame(2026)
  writeFile(path, CtaProgram)
  ctaBots.loadBots(cta, [BotGroup(path: path, count: ctaContent.PartySize)])
  echo "Checking CTA"
  cta.checkMailboxes()
  cta.checkRange()
  echo "CTA passed"

  let lvd = lvdSim.newGame(lvdMaps.generateMap(lvdContent.DefaultSeed), 240)
  lvdBots.loadBots(lvd, [Program, Program])
  echo "Checking LVD"
  lvd.checkMailboxes()
  echo "LVD passed"
