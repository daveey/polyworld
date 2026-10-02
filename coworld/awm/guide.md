# Archers Warriors Mages

Two to seven BASIC heroes play a card game around a courtyard. Each hero has a
class (Archer, Warrior, or Mage), 20 life, and a 40-card class deck. The last
hero standing scores one win; everyone else, and every hero in a draw or a
timeout, scores zero.

Two players play a duel. Three to seven play a free-for-all around a ring of
balconies, in seat order. Each slot commands one hero. Platform slots are
zero-based. Classes come from the optional `classes` config (one per slot), or
are drawn from the seed. Upload a `.bas` file containing BASIC source. The game
reads the staged file directly, with no player container or network
connection.

Start with the bundled `players/base.bas`, which lists the game's values and calls.
The same source is available under `examples/awm/src/core/bots.nim`, and the
cards are in `examples/awm/src/core/baseset.nim` and `examples/awm/README.md`.

## Turns

Each turn the hero gains one energy, refills it, and draws a card (the first
player skips their first draw). Drawing from an empty deck loses. Your script
runs once per decision on your turn and may play at most one card. A decision
that plays a card is followed by another; one that plays nothing ends the
turn. Then every ready minion attacks the next living player's hero, and the
turn passes. A turn also ends after 30 cards. Discards and trigger targets are
chosen for you by the built-in bot.

The script's `enemyPlayer` is the next living player. `selfPlayer` is your
slot. Globals and arrays keep their values between decisions.

## Ticks

One tick is one game action: a card played, one minion's attack, a discard or
trigger answered, or a turn ended. `max_ticks` bounds the match; a match that
reaches it is a timeout. Replays store one action and one state hash per tick
and play back in the browser with seeking, speed, and loop controls.

## Logs and failures

BASIC `PRINT` output, compiler diagnostics, runtime errors, and VM lifecycle
messages go to the owning player's private log. Each log is limited to 10 MiB.
A runtime error, including an instruction limit, disables that VM: its hero
passes every later turn and its minions stop attacking. Other seats continue.
Invalid BASIC syntax fails the episode with a player failure diagnostic.
Public game logs and action replays contain no BASIC source or private print
output. The server exposes `/healthz`; legacy clients are static stubs.

## Mailboxes

Each player has an inbox. `sendChat(-2, text$)` reaches every player,
including the sender; `sendChat(slot, text$)` reaches one player. AWM has no
teams. `pullMailbox$()`, `mailboxId()`, `mailboxCount()`, `mailboxSelf()`, and
`mailboxPlayers()` work as in the other Polyworld games. Messages are read
when your script next runs, which is on your turn.

## BASIC numbers

BASIC uses [Bassy](https://github.com/treeform/bassy) with
[Fixxy](https://github.com/treeform/fixxy) Q16.16 decimals enabled. `/`
performs decimal division; `\` performs integer division. Hand indexes,
choice indexes, and slots require exact integers.
