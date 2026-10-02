import ../src/core/sim

var game = newGame(Archer, Archer, 20260910)
echo "starting life p0: ", game.players[0].life
echo "starting life p1: ", game.players[1].life
echo "currentPlayer: ", game.currentPlayer

# Play bolts until someone dies
var steps = 0
while not game.gameOver and steps < 200:
  let player = game.currentPlayer
  let p = game.players[player]
  var played = false
  for i in 0 ..< p.hand.len:
    if game.canPlay(i):
      discard game.playCard(i, heroChoice((player + 1) mod 2))
      played = true
      break
  if not played:
    game.finishTurn()
  inc steps

echo "steps: ", steps
echo "gameOver: ", game.gameOver
echo "winner: ", game.winner
echo "life p0: ", game.players[0].life
echo "life p1: ", game.players[1].life
echo "turn: ", game.turnNumber
