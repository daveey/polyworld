## The multiplayer game mode: three or more seats around the ring, playing
## the core's game. Every seat but the human's is played by a bot script.
import std/math
import awmsim, awmbots, awmmultiplayer
export awmmultiplayer

const
  HandSpread = 5.0'f32
    ## How wide a hand may fan: it stays between the deck and discard pads.
  BoardSpread = 6.0'f32
    ## How wide a board row may spread across its balcony.
  BoardSpacing = 1.65'f32
    ## The widest gap between neighbouring cards on a board row.

type
  MultiplayerMatch* = object
    game*: GameState
    humanSeat*: int  ## -1 when every seat is a bot and we spectate.
    bots*: seq[BotVm]  ## One per seat; nil for the human's.

template seats*(match: MultiplayerMatch): untyped =
  ## One PlayerState per seat, in seat order.
  match.game.players

proc current*(match: MultiplayerMatch): int =
  match.game.currentPlayer

proc turnNumber*(match: MultiplayerMatch): int =
  match.game.turnNumber

proc newMultiplayerMatch*(classes: openArray[HeroClass], humanSeat: int,
    seed: int64, botSources: openArray[string] = []): MultiplayerMatch =
  ## One seat per class, dealt by the core. The last seat standing wins.
  ## Every seat but the human's runs a bot script, taken from `botSources`
  ## in turn (repeating); with none, those seats don't act.
  result.game = newGame(classes, seed)
  result.humanSeat = humanSeat
  var sources = newSeq[string](classes.len)
  if botSources.len > 0:
    var next = 0
    for seat in 0 ..< classes.len:
      if seat != humanSeat:
        sources[seat] = botSources[next mod botSources.len]
        inc next
  result.bots = loadBots(sources)

proc humanTurn*(match: MultiplayerMatch): bool =
  ## The living human's turn: the dead can't act.
  match.humanSeat in 0 ..< match.game.playerCount and
    match.current == match.humanSeat and not match.game.gameOver and
    not match.game.dead(match.humanSeat)

proc humanActs*(match: MultiplayerMatch): bool =
  ## The human must act now: on their turn, or answering their own discard
  ## or trigger.
  match.humanSeat in 0 ..< match.game.playerCount and
    match.game.actingPlayer() == match.humanSeat and
    not match.game.gameOver and not match.game.dead(match.humanSeat)

proc viewedSeat*(match: MultiplayerMatch): int =
  ## The balcony in front of the camera: the human's, or whoever's turn it
  ## is when we spectate.
  if match.humanSeat >= 0: match.humanSeat else: match.current

proc turnLabel*(match: MultiplayerMatch): string =
  ## Whose turn it is, in the duel's words.
  if match.game.gameOver: "MATCH COMPLETE"
  elif match.humanTurn: "YOUR TURN"
  else: "PLAYER " & $(match.current + 1) & "'S TURN"

proc turnStatus*(match: MultiplayerMatch): string =
  if match.game.gameOver:
    if match.game.winner == match.humanSeat: "You are the last one standing."
    else: "Player " & $(match.game.winner + 1) & " is the last one standing."
  elif match.humanSeat in 0 ..< match.game.playerCount and
      match.game.dead(match.humanSeat):
    "You are dead. Watching the match..."
  elif match.humanSeat < 0: "Watching bot match..."
  elif match.humanTurn: "Your turn. Select a card to play."
  else: "Player " & $(match.current + 1) & " is thinking..."

proc endTurn*(match: var MultiplayerMatch): bool =
  ## The core's turn change: the next seat gains energy, draws, and its
  ## start-of-turn triggers fire. False when the turn can't end yet.
  let before = match.game.turnNumber
  match.game.finishTurn()
  match.game.turnNumber != before

proc skipDeadTurn*(match: var MultiplayerMatch): bool =
  ## Ends the turn of a player who died during it. True when it passed.
  if match.game.gameOver or not match.game.dead(match.current):
    return false
  match.endTurn()

when not defined(headless):
  import vmath
  import awmtable, awmplay

  proc place(balcony: PlayerBalcony, local: CardPose): CardPose =
    ## A pose on a balcony, given in its local frame.
    result = local
    result.position = balcony.toWorld(local.position)
    result.frameYaw = balcony.yaw

  proc deckPose(balcony: PlayerBalcony): CardPose =
    balcony.place(CardPose(position: balcony.deckZone +
      vec3(0, CardHeight * 0.5'f32, 0)))

  proc discardPose(balcony: PlayerBalcony): CardPose =
    balcony.place(CardPose(position: balcony.discardZone +
      vec3(0, CardHeight * 0.5'f32, 0)))

  proc boardPoses(balcony: PlayerBalcony, count: int): seq[CardPose] =
    ## A row across the balcony's board zone, facing its owner.
    if count <= 0:
      return
    let
      spacing =
        if count == 1: 0.0'f32
        else: min(BoardSpacing, BoardSpread / (count - 1).float32)
      start = -spacing * (count - 1).float32 * 0.5'f32
    for i in 0 ..< count:
      result.add balcony.place(CardPose(position: balcony.boardZone +
        vec3(start + spacing * i.float32, CardHeight * 0.5'f32, 0)))

  proc handPoses(layout: MultiplayerLayout, view: MultiplayerView,
      viewedSeat, seat, count: int): seq[CardPose] =
    ## The viewed balcony is turned to P1's place, so its near hand faces
    ## the camera from there. The others keep their tuned place, flipped
    ## over so the table sees only their backs.
    let
      balcony = layout.balconies[seat]
      camera = layout.balconies[0].toLocal(view.camera.eye)
      near = seat == viewedSeat
      hand = if near: view.nearHand else: view.farHand
      pitch =
        if near: arctan2(camera.z - hand.distance, camera.y - hand.height) +
          hand.pitch
        else: MultiplayerHandPitch + hand.pitch
      # Half a turn about each card's long axis: same place, other side up.
      roll = if near: view.handRoll else: view.handRoll + PI.float32
    for pose in fanPoses(count, vec3(hand.lateral, hand.height, hand.distance),
        pitch, 1, hand.yaw, roll, HandSpread):
      result.add balcony.place(pose)

  proc seatTable*(layout: MultiplayerLayout, view: MultiplayerView,
      viewedSeat, humanSeat: int): TableLayout =
    ## Where the shared table puts every seat's cards and hero: on its own
    ## balcony, in the ring's frame, each card facing its owner. Draw and
    ## hit-test it through stageRotation, like the balconies. Only the
    ## viewed hand is face up, and only the human's draws fly face up.
    TableLayout(
      handPoses: proc(player, count: int): seq[CardPose] =
        handPoses(layout, view, viewedSeat, player, count),
      boardPoses: proc(player, count: int): seq[CardPose] =
        layout.balconies[player].boardPoses(count),
      deckPose: proc(player: int): CardPose =
        layout.balconies[player].deckPose,
      discardPose: proc(player: int): CardPose =
        layout.balconies[player].discardPose,
      spellPose: proc(player: int): CardPose =
        ## Floating over the balcony, just past its board row.
        layout.balconies[player].place(CardPose(
          position: layout.balconies[player].boardZone +
            vec3(0, 1.6'f32, -0.9'f32))),
      heroPosition: proc(player: int): Vec3 =
        layout.balconies[player].toWorld(layout.balconies[player].heroZone),
      handVisible: proc(player: int): bool =
        player == viewedSeat,
      drawVisible: proc(player: int): bool =
        player == humanSeat,
      overBoard: proc(point: Vec3): bool =
        length(vec2(point.x, point.z)) <= layout.outerRadius)
