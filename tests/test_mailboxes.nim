import
  std/strutils,
  polyworld/mailboxes

echo "Testing bounded inbox IDs, strings, overflow, and wraparound"
block:
  let inbox = newMailbox()
  doAssert inbox.pop() == NoMailboxId
  doAssert not inbox.push(1, "")
  doAssert not inbox.push(1, repeat('x', MaxChatBytes + 1))
  for i in 0 ..< MaxMailboxMessages:
    doAssert inbox.push(int32(i), $i)
  doAssert not inbox.push(999, "overflow")
  for i in 0 ..< 10:
    doAssert inbox.messages[inbox.first] == $i
    doAssert inbox.pop() == int32(i)
    doAssert inbox.push(int32(i + MaxMailboxMessages), $(i + MaxMailboxMessages))
  for i in 10 ..< MaxMailboxMessages + 10:
    doAssert inbox.messages[inbox.first] == $i
    doAssert inbox.pop() == int32(i)
  doAssert inbox.pop() == NoMailboxId
  doAssert inbox.count == 0
  for id in [-2'i32, -1, 0, 9]:
    doAssert inbox.push(id, "Hello 🌍")
    doAssert inbox.messages[inbox.first] == "Hello 🌍"
    doAssert inbox.pop() == id
