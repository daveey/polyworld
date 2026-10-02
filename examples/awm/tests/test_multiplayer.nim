## The multiplayer preview is a scene harness: these checks need no window.
import std/[math, random, unittest]
import vmath
import ../src/scene/courtyard, ../src/modes/multiplayer, ../src/core/sim,
  ../src/core/sessions, ../src/core/bots

const Tolerance = 0.0002'f32

proc finite(v: Vec3): bool =
  for value in [v.x, v.y, v.z]:
    if value.classify in {fcNan, fcInf, fcNegInf}: return false
  true

proc horizontalRadius(v: Vec3): float32 =
  sqrt(v.x * v.x + v.z * v.z)

proc insideBalcony(layout: MultiplayerLayout, balcony: PlayerBalcony,
    local: Vec3): bool =
  let
    world = balcony.toWorld(local)
    radial = horizontalRadius(world)
    forward = normalize(vec2(balcony.center.x, balcony.center.z))
    direction = normalize(vec2(world.x, world.z))
  radial >= layout.innerRadius - Tolerance and
    radial <= layout.outerRadius + Tolerance and
    dot(forward, direction) >= cos(layout.balconyHalfAngle) - Tolerance

proc rectangleFits(layout: MultiplayerLayout, balcony: PlayerBalcony,
    zone: Vec3, halfWidth, halfDepth: float32): bool =
  for x in [-halfWidth, halfWidth]:
    for z in [-halfDepth, halfDepth]:
      if not layout.insideBalcony(balcony, zone + vec3(x, 0, z)):
        return false
  true

proc onScreen(point: Vec3, viewProjection: Mat4): bool =
  let clip = viewProjection * vec4(point.x, point.y, point.z, 1)
  clip.w > 0 and abs(clip.x) <= clip.w and abs(clip.y) <= clip.w and
    abs(clip.z) <= clip.w

iterator handCorners(balcony: PlayerBalcony): Vec3 =
  ## Use the rendered fan's card dimensions, yaw and tilt. The complete fan
  ## must belong to the balcony even when its cards are raised off the floor.
  for slot in 0 ..< 5:
    let
      offset = slot.float32 - 2
      center = balcony.handZone + vec3(offset * 0.59,
        -abs(offset) * 0.035, abs(offset) * 0.10)
    for x in [-0.725'f32, 0.725'f32]:
      for z in [-1.025'f32, 1.025'f32]:
        let
          yawed = rotateSeat(vec3(x, 0.034, z), -offset * 0.10)
          tilted = vec3(yawed.x,
            yawed.y * cos(0.55'f32) - yawed.z * sin(0.55'f32),
            yawed.y * sin(0.55'f32) + yawed.z * cos(0.55'f32))
        yield center + tilted

suite "Multiplayer battlefield layout":
  test "the multiplayer layout rejects duel and invalid seat counts":
    for count in [-1, 0, 1, 2]:
      expect ValueError:
        discard buildMultiplayerLayout(count)

  test "every requested seat has its own separated radial balcony":
    for count in [3, 4, 5, 6, 8, 12, 24, 64]:
      let layout = buildMultiplayerLayout(count)
      check layout.playerCount == count
      check layout.balconies.len == count
      check layout.centerRadius > 0
      check layout.centerRadius < layout.innerRadius
      check layout.innerRadius < layout.outerRadius
      check layout.balconyHalfAngle > 0
      check layout.balconyHalfAngle * 2 < (2 * PI / count.float).float32
      let radius = horizontalRadius(layout.balconies[0].center)
      for index, balcony in layout.balconies:
        check balcony.playerIndex == index
        check balcony.center.finite
        check balcony.yaw.classify notin {fcNan, fcInf, fcNegInf}
        check abs(horizontalRadius(balcony.center) - radius) < Tolerance
        for other in index + 1 ..< count:
          let cosine = dot(normalize(balcony.center),
            normalize(layout.balconies[other].center))
          check cosine < cos(layout.balconyHalfAngle * 2) + Tolerance

  test "all five zones follow their balcony transform":
    for count in [3, 4, 5, 6, 8, 12, 24, 64]:
      let layout = buildMultiplayerLayout(count)
      for balcony in layout.balconies:
        let zones = [balcony.heroZone, balcony.deckZone,
          balcony.discardZone, balcony.handZone, balcony.boardZone]
        for index, zone in zones:
          let world = balcony.toWorld(zone)
          check world.finite
          check layout.insideBalcony(balcony, zone)
          check length(balcony.toLocal(world) - zone) < Tolerance
          for other in index + 1 ..< zones.len:
            check length(zone - zones[other]) > 1.0
        # A full size pile needs its entire footprint on the floor, not
        # merely an anchor that happens to fit in the stone sector.
        check layout.rectangleFits(balcony, balcony.deckZone, 0.725, 1.025)
        check layout.rectangleFits(balcony, balcony.discardZone, 0.725, 1.025)
        check layout.rectangleFits(balcony, balcony.heroZone, 0.65, 0.65)
        # Four 1.45-wide cards at 1.65-unit spacing are fully visible.
        check layout.rectangleFits(balcony, balcony.boardZone, 3.2, 1.025)
        for corner in balcony.handCorners:
          check layout.insideBalcony(balcony, corner)

  test "adding seats preserves usable radial depth":
    let reference = buildMultiplayerLayout(3)
    var previousInner = reference.innerRadius
    for count in 4 .. 24:
      let layout = buildMultiplayerLayout(count)
      check layout.innerRadius >= previousInner
      check abs((layout.outerRadius - layout.innerRadius) -
        (reference.outerRadius - reference.innerRadius)) < Tolerance
      previousInner = layout.innerRadius

suite "Multiplayer battlefield geometry and framing":
  for count in [3, 4, 6, 8]:
    let
      layout = buildMultiplayerLayout(count)
      mesh = buildMultiplayerCourtyardMesh(layout)

    test $count & " seats have complete finite textured geometry":
      check mesh.vertices.len > 0
      check mesh.vertices.len mod 3 == 0
      check mesh.commonCount + mesh.backdropCount * 2 == mesh.vertices.len
      check mesh.vertices.len < 200_000 * count
      var
        valid = true
        inside = true
        materials: set[0 .. 5]
      for vertex in mesh.vertices:
        if not vertex.position.finite or not vertex.normal.finite or
            not vertex.color.finite:
          valid = false
        for value in [vertex.uv.x, vertex.uv.y, vertex.material]:
          if value.classify in {fcNan, fcInf, fcNegInf}: valid = false
        if abs(length(vertex.normal) - 1) > 0.0001: valid = false
        if horizontalRadius(vertex.position) > layout.outerRadius + 0.9 or
            vertex.position.y < -2.8 or vertex.position.y > 3.0:
          inside = false
        if vertex.material >= 0 and vertex.material <= 5:
          materials.incl vertex.material.int
      check valid
      check inside
      # Stone, metal, vines, banners, and lantern flames all use the same
      # material categories as the original courtyard renderer.
      for material in 0 .. 4:
        check material in materials

    test $count & " seats stay fully framed in landscape and portrait":
      for aspect in [0.45'f32, 0.75'f32, 1.0'f32, 1.6'f32, 2.4'f32]:
        let
          eye = layout.cameraEye(aspect, 42.0)
          target = layout.cameraTarget()
          farPlane = max(100.0'f32, length(eye) * 3)
          view = lookAt(eye, target, vec3(0, 1, 0))
          projection = perspective(42.0'f32, aspect, 0.1'f32, farPlane)
          viewProjection = projection * view
        check eye.finite
        check target.finite
        var framed = true
        for vertex in mesh.vertices:
          if not vertex.position.onScreen(viewProjection): framed = false
        for balcony in layout.balconies:
          # Include upright hero and hand silhouettes above the floor.
          for point in [balcony.heroZone + vec3(0, 2.8, 0),
              balcony.handZone + vec3(-2.8, 1.05, 0),
              balcony.handZone + vec3(2.8, 1.05, 0)]:
            if not balcony.toWorld(point).onScreen(viewProjection):
              framed = false
          for corner in balcony.handCorners:
            if not balcony.toWorld(corner).onScreen(viewProjection):
              framed = false
        check framed

    test $count & " seats keep raised scenery out of the visible card row":
      for balcony in layout.balconies:
        var clear = true
        for vertex in mesh.vertices:
          let local = balcony.toLocal(vertex.position) - balcony.boardZone
          if abs(local.x) < 3.2 and abs(local.z) < 1.025 and
              local.y > 0.025:
            clear = false
        check clear

    test $count & " seats have upward facing stone floors":
      var
        floorTriangles = 0
        upward = true
      for offset in countup(0, mesh.vertices.high - 2, 3):
        let
          a = mesh.vertices[offset]
          b = mesh.vertices[offset + 1]
          c = mesh.vertices[offset + 2]
        if a.material == 0 and abs(a.position.y - 0.006) < 0.00001 and
            abs(b.position.y - 0.006) < 0.00001 and
            abs(c.position.y - 0.006) < 0.00001:
          inc floorTriangles
          if a.normal.y < 0.999: upward = false
      check floorTriangles > count * 30
      check upward

    test $count & " seats rebuild deterministically without changing the RNG":
      randomize(42)
      let expected = rand(1_000_000)
      randomize(42)
      let rebuilt = buildMultiplayerCourtyardMesh(count)
      check rand(1_000_000) == expected
      check rebuilt.vertices == mesh.vertices
      check rebuilt.commonCount == mesh.commonCount
      check rebuilt.backdropCount == mesh.backdropCount

  test "the fitted camera reproduces the auto-fit view as absolute values":
    for count in [3, 4, 8, 24]:
      let layout = buildMultiplayerLayout(count)
      for aspect in [0.6'f32, 1.0, 16.0 / 9.0, 3.0]:
        let
          camera = layout.fittedCamera(aspect)
          fitted = layout.cameraEye(aspect)
          forward = normalize(layout.cameraTarget - fitted)
        check length(camera.eye - fitted) < Tolerance * 10
        check length(normalize(camera.target - camera.eye) - forward) <
          Tolerance
        check camera.pitch > 0 and camera.pitch < PI.float32 / 2

  test "tuned views interpolate between the 3 and 7 seat extremes":
    let
      three = buildMultiplayerLayout(3).multiplayerView(1.6)
      seven = buildMultiplayerLayout(7).multiplayerView(1.6)
    check abs(three.camera.height - 25.72) < Tolerance
    check abs(seven.camera.distance - 29.15) < Tolerance
    var previous = three
    for count in 4 .. 7:
      let view = buildMultiplayerLayout(count).multiplayerView(1.6)
      check view.camera.lateral > previous.camera.lateral
      check view.camera.height > previous.camera.height
      check view.camera.distance > previous.camera.distance
      check view.camera.pitch < previous.camera.pitch
      check view.nearHand.height > previous.nearHand.height
      check view.nearHand.distance > previous.nearHand.distance
      # Both extremes settled on the same far hand, so it doesn't ramp.
      check view.farHand == three.farHand
      previous = view

  test "tuned views frame every balcony in a 16:10 window":
    for count in 3 .. 7:
      let
        layout = buildMultiplayerLayout(count)
        camera = layout.multiplayerView(1.6).camera
        viewProjection = perspective(42.0'f32, 1.6'f32, 0.1'f32, 200.0'f32) *
          lookAt(camera.eye, camera.target, vec3(0, 1, 0))
      var framed = true
      for balcony in layout.balconies:
        for point in [balcony.heroZone + vec3(0, 2.8, 0), balcony.deckZone,
            balcony.discardZone, balcony.boardZone]:
          if not balcony.toWorld(point).onScreen(viewProjection):
            framed = false
      check framed

  test "views above 7 seats keep fitting the camera":
    let layout = buildMultiplayerLayout(12)
    check layout.multiplayerView(1.6).camera == layout.fittedCamera(1.6)

suite "Turns and the spectator camera":
  test "a match deals every seat its class deck and an opening hand":
    let match = newMultiplayerMatch([Archer, Mage, Warrior, Mage],
      humanSeat = 0, seed = 7)
    check match.seats.len == 4
    check match.turnNumber == 1
    check match.current in 0 ..< 4
    for i, heroClass in [Archer, Mage, Warrior, Mage]:
      let seat = match.seats[i]
      check seat.heroClass == heroClass
      check seat.hand.len == StartingHandSize
      check seat.deck.len + seat.hand.len == heroClass.baseDeck().len
      check seat.discardPile.len == 0

  test "each turn after the first draws a card, then passes to the next seat":
    var match = newMultiplayerMatch([Archer, Mage, Warrior],
      humanSeat = -1, seed = 3)
    let first = match.current
    for turn in 0 ..< 5:
      let
        next = (match.current + 1) mod 3
        before = match.seats[next].hand.len
      check match.endTurn()
      check match.current == next
      check match.seats[next].hand.len == before + 1
    check match.current == (first + 5) mod 3
    check match.turnNumber == 6

  test "the human's turn waits for them; the camera stays on their seat":
    var human = newMultiplayerMatch([Archer, Mage, Warrior],
      humanSeat = 0, seed = 11)
    while not human.humanTurn:
      check human.endTurn()
    check human.viewedSeat == 0
    check human.humanTurn
    check human.endTurn()
    check human.current == 1

  test "drawing from an empty deck kills, and the last seat standing wins":
    var match = newMultiplayerMatch([Archer, Mage, Warrior],
      humanSeat = -1, seed = 5)
    var turns = 0
    while not match.game.gameOver and turns < 500:
      discard match.endTurn()
      inc turns
    check match.game.gameOver
    let winner = match.game.winner
    check not match.game.dead(winner)
    for seat in 0 ..< 3:
      if seat != winner:
        check match.game.dead(seat)
        check match.seats[seat].hand.len == 0
    # Nothing goes on after the match ends.
    check not match.endTurn()

  test "the ring turns the watched balcony to the camera the short way":
    let layout = buildMultiplayerLayout(5)
    var orbit = initSeatOrbit(layout.balconies[0].yaw)
    # Seat 4 is one step backwards from seat 0, not four steps forwards.
    orbit.aimAt(layout.balconies[4].yaw)
    orbit.advance(SeatSwitchSeconds * 0.5)
    check orbit.yaw < 0
    orbit.advance(SeatSwitchSeconds)
    let
      stage = stageRotation(orbit.yaw)
      hero = layout.balconies[4].toWorld(layout.balconies[4].heroZone)
      turned = (stage * vec4(hero.x, hero.y, hero.z, 1)).xyz
      front = layout.balconies[0].toWorld(layout.balconies[0].heroZone)
    # Seat 4's hero now stands exactly where P1's stands.
    check length(turned - front) < 0.001

  test "a settled orbit does not move":
    var orbit = initSeatOrbit(1.25)
    orbit.advance(10)
    check orbit.yaw == 1.25

  test "the stage rotation brings a balcony to P1's place":
    let layout = buildMultiplayerLayout(6)
    for balcony in layout.balconies:
      let stage = stageRotation(balcony.yaw)
      for local in [balcony.heroZone, balcony.deckZone, vec3(1, 2, 3)]:
        let
          world = balcony.toWorld(local)
          turned = (stage * vec4(world.x, world.y, world.z, 1)).xyz
        check length(turned - layout.balconies[0].toWorld(local)) < 0.001
        check length(turned - rotateSeat(world, -balcony.yaw)) < 0.001

  test "the static center island is its own range before the balconies":
    for count in [3, 5, 8]:
      let
        layout = buildMultiplayerLayout(count)
        mesh = buildMultiplayerCourtyardMesh(layout)
      check mesh.centerCount > 0
      check mesh.centerCount mod 3 == 0
      check mesh.centerCount < mesh.commonCount
      var centerInside, balconiesOutside = true
      for i in 0 ..< mesh.commonCount:
        let radius = horizontalRadius(mesh.vertices[i].position)
        if i < mesh.centerCount:
          if radius > layout.centerRadius + 0.2: centerInside = false
        elif radius < layout.innerRadius - 0.5:
          balconiesOutside = false
      check centerInside
      check balconiesOutside

  test "a turn's draw reaches the table as a visual event":
    var match = newMultiplayerMatch([Archer, Mage, Warrior],
      humanSeat = -1, seed = 9)
    # The first turn skips the draw.
    check match.game.takeVisualEvents().len == 0
    check match.endTurn()
    let events = match.game.takeVisualEvents()
    check events.len == 1
    check events[0].kind == DrawVfx
    check events[0].target == heroChoice(match.current)

  test "each seat gains one energy per turn and starts it full":
    var match = newMultiplayerMatch([Archer, Mage, Warrior],
      humanSeat = -1, seed = 13)
    let first = match.current
    check match.seats[first].totalEnergy == 1
    check match.seats[first].energy == 1
    for seat in 0 ..< 3:
      if seat != first:
        check match.seats[seat].totalEnergy == 0
    for _ in 0 ..< 3:
      check match.endTurn()
    check match.current == first
    check match.seats[first].totalEnergy == 2
    check match.seats[first].energy == 2
    for seat in match.seats:
      check seat.life == StartingLife

  test "the turn header names whose turn it is":
    var human = newMultiplayerMatch([Archer, Mage, Warrior],
      humanSeat = 0, seed = 17)
    while not human.humanTurn:
      check human.turnLabel == "PLAYER " & $(human.current + 1) & "'S TURN"
      check human.turnStatus == "Player " & $(human.current + 1) &
        " is thinking..."
      check human.endTurn()
    check human.turnLabel == "YOUR TURN"
    check human.turnStatus == "Your turn. Select a card to play."
    let spectating = newMultiplayerMatch([Archer, Mage, Warrior],
      humanSeat = -1, seed = 17)
    check spectating.turnLabel ==
      "PLAYER " & $(spectating.current + 1) & "'S TURN"
    check spectating.turnStatus == "Watching bot match..."


suite "Playing cards in a multiplayer match":
  proc humanMatch(heroClass: HeroClass): MultiplayerMatch =
    ## A match where it is the human's turn, with energy to spare.
    result = newMultiplayerMatch([heroClass, Mage, Warrior, Archer],
      humanSeat = 0, seed = 21)
    while not result.humanTurn:
      check result.endTurn()
    result.seats[0].energy = 10
    result.seats[0].totalEnergy = 10

  test "the core runs every seat's turn in order":
    var match = newMultiplayerMatch([Archer, Mage, Warrior, Archer],
      humanSeat = 0, seed = 3)
    check match.game.playerCount == 4
    let first = match.current
    for step in 1 .. 8:
      check match.endTurn()
      check match.current == (first + step) mod 4

  test "the human plays a spell at another seat's hero":
    var match = humanMatch(Archer)
    match.seats[0].hand = @[baseCardNamed("Bolt")]
    let target = heroChoice(2)
    check target in match.game.availableChoices(0)
    check match.game.playCard(0, target)
    check match.seats[2].life == StartingLife - 2
    check match.seats[0].discardPile.len == 1
    check match.seats[0].energy == 9

  test "the human's minion enters their own board":
    var match = humanMatch(Warrior)
    match.seats[0].hand = @[baseCardNamed("Bear")]
    check match.game.playCard(0)
    check match.seats[0].board.len == 1
    check match.seats[0].board[0].owner == 0
    for seat in 1 ..< match.seats.len:
      check match.seats[seat].board.len == 0

  test "a minion's target can be on any seat's board":
    var match = humanMatch(Mage)
    match.seats[3].board = @[MinionState(id: match.game.nextMinionId,
      owner: 3, card: baseCardNamed("Sniper"), currentToughness: 1)]
    inc match.game.nextMinionId
    match.seats[0].hand = @[baseCardNamed("Bouncer")]
    let
      sniper = creatureChoice(3, match.seats[3].board[0].id)
      bouncerId = match.game.playMinion(0)
    check bouncerId != 0
    check sniper in match.game.availableChoices(baseCardNamed("Bouncer"))
    check match.game.runMinionRules(baseCardNamed("Bouncer"), sniper,
      sourceId = bouncerId)
    check match.seats[3].board.len == 0
    check match.seats[3].hand[^1].name == "Sniper"

  test "a discard waits for the human, then the turn can end":
    var match = humanMatch(Mage)
    match.seats[0].hand = @[baseCardNamed("Study"), baseCardNamed("Bolt")]
    check match.game.playCard(0)
    check match.game.waitingToss
    check match.humanActs
    check not match.endTurn()  # The discard comes first.
    check match.game.resolvePendingToss(@[0])
    check match.endTurn()

suite "Opponents and defeated seats in a multiplayer match":
  proc turnOf(seat: int, classes = [Archer, Mage, Warrior, Archer]):
      MultiplayerMatch =
    ## A four-seat match on `seat`'s turn, with energy to spare.
    result = newMultiplayerMatch(classes, humanSeat = 0, seed = 21)
    while result.current != seat:
      check result.endTurn()
    result.seats[seat].energy = 10
    result.seats[seat].totalEnergy = 10

  proc addMinion(match: var MultiplayerMatch, seat: int, name: string): int =
    result = match.game.nextMinionId
    match.seats[seat].board.add MinionState(id: result, owner: seat,
      card: baseCardNamed(name),
      currentToughness: baseCardNamed(name).toughness)
    inc match.game.nextMinionId

  test "opponent's minions are every minion the player doesn't control":
    var match = turnOf(0)
    discard match.addMinion(0, "Bear")
    for seat in 1 .. 3:
      discard match.addMinion(seat, "Sniper")
    match.seats[0].hand = @[baseCardNamed("Hail of Arrows")]
    check match.game.playCard(0)
    check match.seats[0].board.len == 1  # The caster's Bear is spared.
    for seat in 1 .. 3:
      check match.seats[seat].board.len == 0

  test "each opponent draws: every living opponent does":
    var match = turnOf(1)
    let before = @[match.seats[0].hand.len, match.seats[1].hand.len,
      match.seats[2].hand.len, match.seats[3].hand.len]
    match.seats[1].hand.add Card(name: "Gift", energyCost: 0, kind: Spell,
      rules: rules(draw(1, AllOpponents)))
    check match.game.playCard(match.seats[1].hand.high)
    check match.seats[1].hand.len == before[1]  # The spell left the hand.
    for seat in [0, 2, 3]:
      check match.seats[seat].hand.len == before[seat] + 1

  test "a target's owner is the seat that controls it":
    var match = turnOf(1, [Archer, Mage, Warrior, Archer])
    let bear = match.addMinion(3, "Bear")
    match.seats[1].hand = @[baseCardNamed("Oozification")]
    check match.game.playCard(0, creatureChoice(3, bear))
    # The Bear (toughness 2) becomes two Oozes for seat 3, nobody else.
    check match.seats[3].board.len == 2
    for minion in match.seats[3].board:
      check minion.card.name == "Ooze"
    for seat in [0, 1, 2]:
      check match.seats[seat].board.len == 0

  test "a next-turn trigger waits a whole round of seats":
    var match = turnOf(2, [Archer, Mage, Mage, Warrior])
    match.seats[2].hand = @[baseCardNamed("Plan")]
    check match.game.playCard(0)
    check match.seats[2].board.len == 1
    for _ in 0 ..< 3:
      check match.endTurn()
      check match.seats[2].board.len == 1
    let handBefore = match.seats[2].hand.len
    check match.endTurn()
    check match.current == 2
    # Its turn draw, Plan's draw, and Plan is gone.
    check match.seats[2].hand.len == handBefore + 2
    check match.seats[2].board.len == 0

  test "a dead seat's hand is discarded one card at a time":
    var match = turnOf(0)
    match.seats[0].hand = @[baseCardNamed("Bolt")]
    match.seats[1].life = 2
    match.seats[1].board.add MinionState(id: match.game.nextMinionId,
      owner: 1, card: baseCardNamed("Sniper"), currentToughness: 1)
    inc match.game.nextMinionId
    let hand = match.seats[1].hand.len
    discard match.game.takeVisualEvents()
    check match.game.playCard(0, heroChoice(1))
    check match.game.dead(1)
    check not match.game.gameOver
    check match.seats[1].hand.len == 0
    check match.seats[1].discardPile.len == hand
    check match.seats[1].board.len == 1  # Its cards in play stay.
    var deaths, tosses: int
    var beats: seq[int]
    for event in match.game.takeVisualEvents():
      if event.target == heroChoice(1):
        if event.kind == HeroDeathVfx: inc deaths
        if event.kind == TossVfx:
          inc tosses
          beats.add event.beat
    check deaths == 1
    check tosses == hand
    for i in 1 ..< beats.len:
      check beats[i] > beats[i - 1]

  test "a dead seat can't act and its turn is skipped":
    var match = turnOf(0)
    match.seats[0].hand = @[baseCardNamed("Bolt")]
    match.seats[1].life = 2
    check match.game.playCard(0, heroChoice(1))
    check heroChoice(1) notin match.game.availableChoices(
      baseCardNamed("Bolt"))
    for _ in 0 ..< 6:
      check match.endTurn()
      check match.current != 1

  test "the last seat standing wins":
    var match = turnOf(0)
    match.seats[0].hand = @[baseCardNamed("Bolt"), baseCardNamed("Bolt"),
      baseCardNamed("Bolt")]
    for seat in 1 .. 3:
      match.seats[seat].life = 2
    check match.game.playCard(0, heroChoice(1))
    check match.game.playCard(0, heroChoice(2))
    check not match.game.gameOver
    check match.game.playCard(0, heroChoice(3))
    check match.game.gameOver
    check match.game.winner == 0

  test "when everyone left dies at once, the current player wins":
    var match = turnOf(1)
    match.seats[0].life = 0
    match.seats[2].life = 0
    match.seats[3].life = 0
    # Seat 1 goes down in the same resolution as everyone else.
    match.seats[1].hand = @[Card(name: "Pact", energyCost: 0, kind: Spell,
      rules: rules(damage(5, target({Hero}))))]
    match.seats[1].life = 5
    check match.game.playCard(0, heroChoice(1))
    check match.game.gameOver
    check match.game.winner == 1
    for seat in 0 .. 3:
      check match.game.dead(seat)

suite "Attacks in a multiplayer match":
  proc readyMatch(): MultiplayerMatch =
    ## Seat 0's turn, with a Bear ready to attack and a Sniper on seats 1-3.
    result = newMultiplayerMatch([Warrior, Mage, Warrior, Mage],
      humanSeat = 0, seed = 21)
    while result.current != 0:
      check result.endTurn()
    for seat in 0 .. 3:
      let name = if seat == 0: "Bear" else: "Sniper"
      result.seats[seat].board.add MinionState(id: result.game.nextMinionId,
        owner: seat, card: baseCardNamed(name),
        currentToughness: baseCardNamed(name).toughness, canAttack: true)
      inc result.game.nextMinionId

  test "an attacker can target every opponent's hero and minions":
    let match = readyMatch()
    let targets = match.game.attackTargets(match.seats[0].board[0].id)
    for seat in 1 .. 3:
      check heroChoice(seat) in targets
      check creatureChoice(seat, match.seats[seat].board[0].id) in targets
    check heroChoice(0) notin targets
    check targets.len == 6

  test "attacking a far seat's hero hits that hero":
    var match = readyMatch()
    let bear = match.seats[0].board[0].id
    check match.game.attack(bear, heroChoice(2))
    check match.seats[2].life == StartingLife - 3
    check match.seats[1].life == StartingLife
    check match.seats[3].life == StartingLife
    check not match.game.attack(bear, heroChoice(3))  # It attacked already.

  test "attacking a minion on another balcony fights it":
    var match = readyMatch()
    let footsoldier = match.game.nextMinionId
    match.seats[3].board.add MinionState(id: footsoldier, owner: 3,
      card: baseCardNamed("Footsoldier"), currentToughness: 2)
    inc match.game.nextMinionId
    let bear = match.seats[0].board[0].id
    check match.game.attack(bear, creatureChoice(3, footsoldier))
    # Both hit at once: the Bear's 3 kills the Footsoldier, which deals 1.
    check match.seats[3].board.len == 1
    check match.seats[3].discardPile[^1].name == "Footsoldier"
    check match.seats[0].board[0].currentToughness == 1

  test "a dead seat's hero can't be attacked, but its minions can":
    var match = readyMatch()
    match.seats[1].life = 0
    match.game.checkWinCondition()
    let targets = match.game.attackTargets(match.seats[0].board[0].id)
    check heroChoice(1) notin targets
    check creatureChoice(1, match.seats[1].board[0].id) in targets
    check heroChoice(2) in targets

  test "an attacked seat's own trigger answers the attack":
    var match = readyMatch()
    match.seats[3].board.add MinionState(id: match.game.nextMinionId,
      owner: 3, card: baseCardNamed("Bubble"))
    inc match.game.nextMinionId
    let bear = match.seats[0].board[0].id
    check match.game.attack(bear, heroChoice(3))
    # Bubble bounces the Bear back to its owner's hand and pops.
    check match.seats[0].board.len == 0
    check match.seats[0].hand[^1].name == "Bear"
    check match.seats[3].board.len == 1

  test "a match that hasn't started answers turn questions safely":
    # The class choice asks these before any match is dealt.
    let unstarted = MultiplayerMatch(humanSeat: 0)
    check not unstarted.humanTurn
    check not unstarted.humanActs


suite "Bots in a multiplayer match":
  const ReferenceBot = staticRead("../players/base.bas")

  proc botTurn(match: var MultiplayerMatch): tuple[plays, attacks: int] =
    ## What the table does for the current bot seat, without the table:
    ## answer waiting choices, play until it stops, attack, end the turn.
    let seat = match.current
    for _ in 0 ..< 20:
      while match.game.waitingChoice:
        check match.game.applyBotAction(match.game.nextBotAction())
      if match.game.gameOver: return
      case match.bots[seat].runDecision(match.game)
      of BotPlayedCard: inc result.plays
      of BotEndedTurn: break
      of BotFailed:
        checkpoint match.bots[seat].lastError
        fail()
        return
    while match.game.waitingChoice:
      check match.game.applyBotAction(match.game.nextBotAction())
    for attacker in match.game.eligibleAttackers():
      if match.game.attack(attacker,
          heroChoice(match.game.nextPlayer(seat))):
        inc result.attacks
      while match.game.waitingChoice:
        check match.game.applyBotAction(match.game.nextBotAction())
    discard match.endTurn()

  test "every seat but the human's gets a bot":
    let match = newMultiplayerMatch([Archer, Mage, Warrior, Mage],
      humanSeat = 0, seed = 3, botSources = [ReferenceBot])
    check match.bots.len == 4
    check match.bots[0].isNil
    for seat in 1 .. 3:
      check not match.bots[seat].isNil

  test "bots play cards, attack, and finish a match between themselves":
    for seed in [1'i64, 2, 3]:
      var match = newMultiplayerMatch([Archer, Mage, Warrior, Mage],
        humanSeat = -1, seed = seed, botSources = [ReferenceBot])
      var plays, attacks, turns = 0
      while not match.game.gameOver and turns < 400:
        let done = match.botTurn()
        plays += done.plays
        attacks += done.attacks
        inc turns
      check match.game.gameOver
      check not match.game.dead(match.game.winner)
      check plays > 20
      check attacks > 5

  test "a bot's enemy is the next living player":
    var match = newMultiplayerMatch([Archer, Archer, Archer, Archer],
      humanSeat = -1, seed = 8, botSources = [ReferenceBot])
    while match.current != 0:
      check match.endTurn()
    match.seats[1].life = 0
    match.game.checkWinCondition()
    match.seats[0].energy = 10
    match.seats[0].hand = @[baseCardNamed("Bolt")]
    check match.bots[0].runDecision(match.game) == BotPlayedCard
    check match.seats[2].life == StartingLife - 2
    check match.seats[3].life == StartingLife

  test "a bot answers its own trigger":
    var match = newMultiplayerMatch([Warrior, Warrior, Mage, Warrior],
      humanSeat = 0, seed = 4, botSources = [ReferenceBot])
    while match.current != 0:
      check match.endTurn()
    # Seat 2's Bubble answers an attack on its hero.
    match.seats[2].board.add MinionState(id: match.game.nextMinionId,
      owner: 2, card: baseCardNamed("Bubble"))
    inc match.game.nextMinionId
    let bear = match.game.nextMinionId
    match.seats[0].board.add MinionState(id: bear, owner: 0,
      card: baseCardNamed("Bear"), currentToughness: 2, canAttack: true)
    inc match.game.nextMinionId
    check match.game.attack(bear, heroChoice(2))
    while match.game.waitingChoice:
      check match.game.actingPlayer() == 2
      check match.game.applyBotAction(match.game.nextBotAction())
    check match.seats[0].hand[^1].name == "Bear"


suite "An opponent, each opponent, and turn triggers":
  proc turnOf(seat: int): MultiplayerMatch =
    result = newMultiplayerMatch([Mage, Mage, Mage, Mage], humanSeat = 0,
      seed = 21)
    while result.current != seat:
      check result.endTurn()
    result.seats[seat].energy = 10
    result.seats[seat].totalEnergy = 10

  proc spell(text: Rules): Card =
    Card(name: "Probe", energyCost: 0, kind: Spell, rules: text)

  test "the wording tells one opponent from each opponent":
    check spell(rules(draw(1, target({Opponent})))).ruleText() ==
      "An opponent draws 1 card."
    check spell(rules(toss(1, target({Opponent})))).ruleText() ==
      "An opponent discards 1 card."
    check spell(rules(summon(1, "Ooze", target({Opponent})))).ruleText() ==
      "Summon an Ooze for an opponent."
    check spell(rules(draw(1, AllOpponents))).ruleText() ==
      "Each opponent draws 1 card."
    check spell(rules(toss(1, AllOpponents))).ruleText() ==
      "Each opponent discards 1 card."
    check spell(rules(draw(1, target({Opponent})))).targetPrompt(0).choose ==
      "Choose an opponent."
    check spell(rules(damage(1, target({Hero}, Enemy)))).ruleText() ==
      "Deal 1 damage to an enemy hero."
    check Card(name: "Watch", kind: Trinket, rules: rules(
      on(attacked(AnyOpponent), draw(1)))).ruleText() ==
      "When an opponent's hero is attacked, draw 1 card."
    check Card(name: "Watch", kind: Trinket, rules: rules(
      on(nextTurn(AnyOpponent), draw(1)))).ruleText() ==
      "At the start of an opponent's next turn, draw 1 card."

  test "an opponent draws: only the one picked":
    var match = turnOf(0)
    let card = spell(rules(draw(1, target({Opponent}))))
    check card.needsChoice()
    let choices = match.game.availableChoices(card)
    check choices == @[heroChoice(1), heroChoice(2), heroChoice(3)]
    let before = @[match.seats[1].hand.len, match.seats[2].hand.len,
      match.seats[3].hand.len]
    match.seats[0].hand = @[card]
    check match.game.playCard(0, heroChoice(2))
    check match.seats[1].hand.len == before[0]
    check match.seats[2].hand.len == before[1] + 1
    check match.seats[3].hand.len == before[2]

  test "an opponent discards: the picked one chooses what":
    var match = turnOf(0)
    match.seats[0].hand = @[spell(rules(toss(1, target({Opponent}))))]
    check match.game.playCard(0, heroChoice(3))
    check match.game.waitingToss
    check match.game.pendingToss.player == 3
    check match.game.actingPlayer() == 3

  test "a canceled pick cancels the spell; you can't pick yourself or the dead":
    var match = turnOf(0)
    match.seats[2].life = 0
    match.game.checkWinCondition()
    let card = spell(rules(draw(1, target({Opponent}))))
    check match.game.availableChoices(card) ==
      @[heroChoice(1), heroChoice(3)]
    match.seats[0].hand = @[card]
    check not match.game.playCard(0, Canceled)
    check not match.game.playCard(0, heroChoice(0))
    check not match.game.playCard(0, heroChoice(2))
    check match.seats[0].hand.len == 1

  test "each opponent leaves the dead out; their minions stay enemies":
    var match = turnOf(0)
    match.seats[2].board.add MinionState(id: match.game.nextMinionId,
      owner: 2, card: baseCardNamed("Bouncer"), currentToughness: 1)
    inc match.game.nextMinionId
    match.seats[2].life = 0
    match.game.checkWinCondition()
    match.seats[0].hand = @[spell(rules(summon(1, "Ooze", AllOpponents))),
      baseCardNamed("Hail of Arrows")]
    check match.game.playCard(0)
    check match.seats[1].board.len == 1
    check match.seats[2].board.len == 1  # Only its old Bouncer.
    check match.seats[3].board.len == 1
    check match.game.playCard(0)
    for seat in 1 .. 3:
      check match.seats[seat].board.len == 0

  test "effects and triggers reject the wrong kind of opponent":
    expect AssertionDefect:
      discard draw(1, AnyOpponent)
    expect AssertionDefect:
      discard toss(1, AnyOpponent)
    expect AssertionDefect:
      discard summon(1, "Ooze", AnyOpponent)
    expect AssertionDefect:
      discard nextTurn(AllOpponents)
    expect AssertionDefect:
      discard attacked(AllOpponents)

  test "Plan fires on its owner's next turn even after a deck-out death":
    var match = turnOf(0)
    match.seats[0].hand = @[baseCardNamed("Plan")]
    check match.game.playCard(0)
    match.seats[1].deck.setLen(0)
    let hand = match.seats[0].hand.len
    while true:
      check match.endTurn()
      if match.current == 0: break
    check match.game.dead(1)
    check match.seats[0].board.len == 0
    check match.seats[0].hand.len == hand + 2  # The turn draw and Plan's.

  test "a next-turn trigger fires once":
    var match = turnOf(0)
    match.seats[0].hand = @[Card(name: "Spy", energyCost: 0, kind: Trinket,
      rules: rules(on(nextTurn(AnyOpponent), draw(1)))),
      Card(name: "Clock", energyCost: 0, kind: Trinket,
      rules: rules(on(nextTurn(You), draw(1))))]
    check match.game.playCard(0)
    check match.game.playCard(0)
    let hand = match.seats[0].hand.len
    check match.endTurn()  # The next opponent's turn: Spy fires.
    check match.seats[0].hand.len == hand + 1
    for _ in 0 ..< 3:
      check match.endTurn()
    # Seat 0's own turn: its draw, and Clock.
    check match.seats[0].hand.len == hand + 3
    for _ in 0 ..< 8:
      check match.endTurn()
    # Two more rounds: two turn draws, and neither trigger again.
    check match.seats[0].hand.len == hand + 5

  test "a bot picks its enemy for an opponent target":
    var match = turnOf(1)
    let card = spell(rules(toss(1, target({Opponent}))))
    match.seats[1].hand = @[card]
    let action = match.game.nextBotAction()
    check action.kind == PlayCardAction
    check action.choices == @[heroChoice(2)]

suite "Failing bot scripts":
  const
    ReferenceBot = staticRead("../players/base.bas")
    BrokenBot = "this is not a BASIC program ((("
    RunawayBot = "i = 0\nWHILE i < 1\n  j = j + 1\nWEND\n"

  test "a script that doesn't compile holds its seat and fails every turn":
    var match = newMultiplayerMatch([Archer, Mage, Warrior],
      humanSeat = -1, seed = 3, botSources = [BrokenBot, ReferenceBot])
    check match.bots[0].failed
    check match.bots[0].lastError.len > 0
    check not match.bots[1].failed
    while match.current != 0:
      check match.endTurn()
    check match.bots[0].runDecision(match.game) == BotFailed
    # The table passes its turn; the match goes on.
    check match.endTurn()
    check match.current == 1

  test "a script that fails mid-decision runs again next time":
    var match = newMultiplayerMatch([Archer, Mage, Warrior],
      humanSeat = -1, seed = 3, botSources = [RunawayBot])
    check not match.bots[match.current].failed
    let hand = match.seats[match.current].hand.len
    check match.bots[match.current].runDecision(match.game) == BotFailed
    check match.bots[match.current].lastError.len > 0
    check match.seats[match.current].hand.len == hand  # Nothing was played.
    check match.bots[match.current].runDecision(match.game) == BotFailed
