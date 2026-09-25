import
  std/strutils,
  polyworld/mailboxes,
  test_chats

when not defined(nimAllocStats):
  {.error: "Run this test with -d:nimAllocStats to measure allocations.".}

echo "Testing inbox storage is reused without heap allocations"
block:
  let
    inbox = newMailbox()
    payload = repeat('x', MaxChatBytes)
    before = getAllocStats()
  for round in 0 ..< 1000:
    for i in 0 ..< MaxMailboxMessages:
      doAssert inbox.push(int32(i), payload)
    doAssert not inbox.push(0, "overflow")
    for i in 0 ..< MaxMailboxMessages:
      doAssert inbox.messages[inbox.first] == payload
      doAssert inbox.pop() == int32(i)
    doAssert inbox.pop() == NoMailboxId
  let after = getAllocStats()
  doAssert after == before, $(after - before)
