const
  MaxMailboxMessages* = 100
  MaxChatBytes* = 1024
  NoMailboxId* = -3

type Mailbox* = ref object
  ids*: array[MaxMailboxMessages, int32]
  messages*: array[MaxMailboxMessages, string]
  first*, count*: int
  lastId*: int32

proc newMailbox*(): Mailbox =
  ## Reserves one player's bounded inbox before the game starts.
  result = Mailbox(lastId: NoMailboxId)
  for message in result.messages.mitems:
    message = newStringOfCap(MaxChatBytes)

proc push*(mailbox: Mailbox, id: int32, text: openArray[char]): bool =
  ## Appends an ID and text, ignoring empty, oversized, or excess messages.
  if mailbox.count == MaxMailboxMessages or
    text.len == 0 or text.len > MaxChatBytes:
      return false
  let index = (mailbox.first + mailbox.count) mod MaxMailboxMessages
  mailbox.ids[index] = id
  mailbox.messages[index].setLen(text.len)
  for i in 0 ..< text.len:
    mailbox.messages[index][i] = text[i]
  inc mailbox.count
  true

proc pop*(mailbox: Mailbox): int32 =
  ## Consumes the first message after the game has read its text.
  mailbox.lastId = NoMailboxId
  if mailbox.count > 0:
    mailbox.lastId = mailbox.ids[mailbox.first]
    mailbox.first = (mailbox.first + 1) mod MaxMailboxMessages
    dec mailbox.count
  mailbox.lastId
