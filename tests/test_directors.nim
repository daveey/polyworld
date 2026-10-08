import
  vmath,
  polyworld/[actioncam, directors, gameuis, player, stats]

proc subject(id: int32, x = 0.0'f, floor = 0'i32,
    idle = 12.0'f): Subject =
  ## Creates a living player-owned subject for deterministic viewer tests.
  Subject(id: id, owner: id - 1, position: vec3(x, 0, 0), floor: floor,
    radius: 1, height: 1, visible: true, alive: true,
    hp: 100, maxHp: 100, complete: true, idleScore: idle, combatScore: 100)

proc step(director: var Director, dt: float32,
    complete = false, repeating = true, manual = false) =
  ## Advances a forty-unit viewport with no simulation dependency.
  director.advance(dt, true, complete, repeating, manual, 40)

echo "Testing idle starts, expired events, and removed subjects"
block:
  var director = initDirector()
  let first = subject(1)
  director.refresh(@[first, subject(2, 3), subject(3, 100)])
  director.step(0)
  doAssert director.locked and director.subject.id == 1 and director.cut
  director.noteEvent(first, DamageEvent, 150)
  director.step(0)
  director.step(4)
  doAssert director.events.len == 0
  doAssert director.subject.id == 1
  director.refresh(@[subject(2, 3), subject(3, 100, idle = 50)])
  director.step(0)
  doAssert director.subject.id == 2 and director.cut
  director.refresh(@[])
  director.step(0)
  doAssert not director.locked and director.finalResults

echo "Testing observed changes and inactive damaged buildings"
block:
  var
    director = initDirector()
    fort = subject(1)
  fort.hp = 30
  fort.combatScore = 165
  director.observe(@[fort])
  director.refresh(@[fort])
  for i in 0 ..< 40:
    director.observe(@[fort])
    director.step(0.1)
  doAssert director.events.len == 0
  fort.hp -= 1
  director.observe(@[fort])
  director.step(0.1)
  doAssert director.events.len == 1
  doAssert director.lastMajor == director.time
  director.step(4)
  doAssert director.events.len == 0
  fort.complete = false
  director.observe(@[fort])
  fort.complete = true
  fort.hp = 100
  director.observe(@[fort])
  doAssert director.events.len == 1
  doAssert director.events[0].kind == ProgressEvent

echo "Testing idle gods ignore nearby action and non-damage events"
block:
  var
    director = initDirector()
    god = subject(1, idle = 3)
    creep = subject(2, 2, idle = 22)
  god.damageOnly = true
  god.hp = 30
  god.combatScore = 165
  creep.combatScore = 70
  director.observe(@[god, creep])
  director.refresh(@[god, creep])
  director.step(0)
  doAssert director.subject.id == creep.id
  for kind in [ProgressEvent, HealEvent, ReturnEvent]:
    director.reset()
    director.refresh(@[god, creep])
    director.noteEvent(god, kind, 165)
    director.noteEvent(creep, AttackEvent, 70)
    director.step(0)
    doAssert director.subject.id == creep.id

echo "Testing gods yield to marching creeps as soon as damage expires"
block:
  var
    director = initDirector()
    god = subject(1, idle = 3)
  let creep = subject(2, 100, idle = 22)
  god.damageOnly = true
  god.combatScore = 165
  director.observe(@[god, creep])
  director.refresh(@[god, creep])
  director.step(0)
  director.step(2)
  doAssert director.subject.id == creep.id
  god.hp -= 1
  director.observe(@[god, creep])
  director.refresh(@[god, creep])
  director.step(0.1)
  doAssert director.subject.id == god.id
  director.step(1.3)
  doAssert director.subject.id == creep.id
  director.reset()
  director.observe(@[god, creep])
  director.refresh(@[god, creep])
  director.step(0)
  doAssert director.subject.id == creep.id

echo "Testing nearby idle gods cannot replace a removed subject"
block:
  var
    director = initDirector()
    god = subject(2, 2, idle = 3)
  let
    hero = subject(1)
    creep = subject(3, 100, idle = 8)
  god.damageOnly = true
  director.refresh(@[hero, god, creep])
  director.step(0)
  doAssert director.subject.id == hero.id
  director.refresh(@[god, creep])
  director.step(0)
  doAssert director.subject.id == creep.id

echo "Testing idle gods alone do not imply the match has ended"
block:
  var
    director = initDirector()
    god = subject(1)
  god.damageOnly = true
  director.refresh(@[god])
  director.step(0)
  doAssert not director.locked
  doAssert not director.finalResults
  director.step(0, complete = true)
  doAssert director.finalResults

echo "Testing every tick survives fast playback and low frame rates"
block:
  for ticksPerFrame in [1, 2, 4, 16]:
    var
      director = initDirector()
      hero = subject(1)
    director.observe(@[hero])
    for tick in 0 ..< ticksPerFrame:
      if tick == 0:
        hero.hp = 10
      elif tick == 1:
        hero.hp = 100
      director.observe(@[hero])
    director.refresh(@[hero])
    director.step(2)
    doAssert director.events.len > 0
    doAssert director.lastMajor == director.time

echo "Testing four-second holds and ordinary distant cut limits"
block:
  var director = initDirector()
  director.refresh(@[subject(1), subject(2, 100)])
  director.step(0)
  director.refresh(@[subject(1), subject(2, 100, idle = 28)])
  director.step(3.9)
  doAssert director.subject.id == 1
  director.step(0.2)
  doAssert director.subject.id == 1
  director.step(4)
  doAssert director.subject.id == 2 and director.cut
  director.refresh(@[subject(1, idle = 50), subject(2, 100)])
  director.step(4)
  doAssert director.subject.id == 2
  director.step(4)
  doAssert director.subject.id == 1 and director.cut

echo "Testing critical interruptions, floors, and aftermath"
block:
  var director = initDirector()
  let first = subject(1)
  var other = subject(2, 2, floor = 3)
  director.refresh(@[first, other])
  director.step(0)
  director.noteEvent(other, DamageEvent, 180, lifetime = 5)
  director.step(1.9)
  doAssert director.subject.id == 1
  director.step(0.1)
  doAssert director.subject.id == 2 and director.cut
  doAssert director.subject.floor == 3
  other.floor = 4
  director.refresh(@[first, other])
  director.step(0)
  doAssert director.subject.floor == 4 and director.cut
  other.visible = false
  director.refresh(@[first, other])
  director.step(0)
  doAssert director.subject.id == 1 and director.cut

echo "Testing nearby glides and stable framing of moving subjects"
block:
  var
    director = initDirector()
    target = vec3(0)
    distance = 30.0'f
  director.lift = 0
  director.refresh(@[subject(1), subject(2, 10)])
  director.step(0)
  director.follow(target, distance, 0)
  director.refresh(@[subject(1), subject(2, 10, idle = 28)])
  director.step(4)
  doAssert director.subject.id == 2 and not director.cut
  director.follow(target, distance, 0.5)
  doAssert abs(target.x - 5) < 0.001
  director.step(0.5)
  director.follow(target, distance, 0.5)
  doAssert abs(target.x - 10) < 0.001
  director.refresh(@[subject(2, 12, idle = 28)])
  director.step(0.01)
  director.follow(target, distance, 0.01)
  doAssert target.x == 12
  doAssert target.y == 1

echo "Testing separated parties never frame an empty midpoint"
block:
  var director = initDirector()
  let heroes = @[subject(1, -100), subject(2, 100),
    subject(3, 0, floor = 1), subject(4, 0, floor = 2)]
  director.refresh(heroes)
  director.step(0)
  doAssert director.subject.position.x == -100
  doAssert director.distance == 40

echo "Testing fixed zoom through combat, glides, cuts, and floor changes"
block:
  for zoom in [13.0'f, 17.0'f]:
    var
      director = initDirector(zoom)
      target = vec3(0)
      distance = 170.0'f
    director.refresh(@[subject(1)])
    director.step(0)
    director.follow(target, distance, 0)
    doAssert distance == zoom
    for frame in 0 ..< 100:
      let hero = subject(int32(frame + 2), float32(frame * 8),
        floor = int32(frame mod 3))
      director.refresh(@[hero])
      director.noteEvent(hero, DamageEvent, 180)
      director.step(0.1)
      director.follow(target, distance, 0.1)
      doAssert distance == zoom

echo "Testing early overviews and five full viewing seconds"
block:
  for speed in [1, 2, 4, 16]:
    var director = initDirector()
    director.refresh(@[subject(1)])
    director.step(0)
    for second in 1 .. 14:
      for tick in 0 ..< speed:
        director.observe(@[subject(1)])
      director.step(1)
      doAssert not director.overview
    director.step(1)
    doAssert director.overview
    director.step(4.9)
    doAssert director.overview
    director.step(0.1)
    doAssert not director.overview
    doAssert director.lastOverview == 15
    director.step(10)
    doAssert director.overview

echo "Testing overdue priority waits for combat and its aftermath"
block:
  var director = initDirector()
  let hero = subject(1)
  director.refresh(@[hero])
  director.step(0)
  for second in 1 .. 60:
    director.noteEvent(hero, AttackEvent, 120)
    director.step(1)
    doAssert not director.overview
  doAssert director.overduePriority >= 2
  director.step(1.3)
  doAssert not director.overview
  director.step(1)
  doAssert director.overview

echo "Testing interruption retries a full overview and manual dismissal"
block:
  var director = initDirector()
  let hero = subject(1)
  director.refresh(@[hero])
  director.step(0)
  director.step(15)
  doAssert director.overview
  director.step(2)
  director.noteEvent(hero, AttackEvent, 120)
  director.step(0.1)
  doAssert not director.overview
  doAssert director.lastOverview == 0
  director.step(3.3)
  doAssert director.overview
  director.step(4.9)
  doAssert director.overview
  director.step(0.1)
  doAssert not director.overview
  director.step(30)
  doAssert director.overview
  director.dismissOverview()
  director.step(14.9)
  doAssert not director.overview
  director.step(0.1, manual = true)
  doAssert not director.overview

echo "Testing work and recruitment do not postpone an overdue overview"
block:
  var director = initDirector()
  let worker = subject(1)
  director.refresh(@[worker])
  director.step(0)
  for second in 1 .. 29:
    director.noteEvent(worker, ProgressEvent, 42)
    director.step(1)
    doAssert not director.overview
  director.noteEvent(worker, ProgressEvent, 42)
  director.step(1)
  doAssert director.overview

echo "Testing short loops preserve an already displayed final card"
block:
  var director = initDirector()
  director.refresh(@[subject(1)])
  director.step(0, complete = true)
  director.step(2, complete = true)
  director.reset(preserveFinal = true)
  director.refresh(@[subject(1)])
  director.step(0, complete = true)
  director.step(2.9, complete = true)
  doAssert director.finalResults
  director.step(0.1, complete = true)
  doAssert not director.finalResults

echo "Testing paused and seeking clocks, and explicit camera controls"
block:
  var
    cam = initActionCam(subjectMode = true)
    selectionFollow = true
    target = vec3(0)
    distance = 40.0'f
  cam.director.refresh(@[subject(1)])
  cam.direct(target, distance, 10, false, true, 1)
  let time = cam.director.time
  for frame in 0 ..< 120:
    cam.direct(target, distance, 0, false, true, 1)
  doAssert cam.director.time == time
  cam.takeManual()
  cam.direct(target, distance, 30, false, true, 1)
  doAssert not cam.director.overview
  cam.toggle(selectionFollow)
  doAssert not selectionFollow
  cam.director.refresh(@[subject(2)])
  cam.direct(target, distance, 0, false, true, 1)
  doAssert cam.lockId == 2
  cam.resetDirector()
  doAssert cam.director.events.len == 0 and not cam.locked

echo "Testing final snapshots survive loops without changing manual panels"
block:
  var
    cam = initActionCam(subjectMode = true)
    state: StatsState
    transport = initPlayer(live = false, durationTicks = 10, repeating = true)
  let
    final = StatsTable(kind: RtsStats, complete: true, tick: 10)
    start = StatsTable(kind: RtsStats)
  cam.director.refresh(@[subject(1)])
  cam.director.step(0, complete = true)
  state.syncDirector(cam, final, false)
  doAssert state.visible(false) and not state.toggled
  transport.sync(10, 10, true)
  discard transport.shouldTick(0)
  doAssert transport.automaticSeek
  cam.resetDirector(transport.automaticSeek)
  cam.director.refresh(@[subject(1)])
  cam.director.step(4.9)
  state.syncDirector(cam, start, false)
  doAssert state.displayedTable(start).tick == 10
  cam.director.step(0.1)
  state.syncDirector(cam, start, false)
  doAssert not state.visible(false)
  doAssert state.displayedTable(start).tick == 0
  state.toggle()
  cam.director.step(0, complete = true, repeating = false)
  cam.director.step(60, complete = true, repeating = false)
  state.syncDirector(cam, final, false)
  doAssert state.visible(false) and state.toggled
  doAssert cam.director.finalResults
  transport.seekTo(3)
  doAssert not transport.automaticSeek
  cam.resetDirector()
  state.syncDirector(cam, start, true)
  doAssert state.visible(false)
  doAssert not state.automaticFinal

echo "Testing readable overviews fit narrow and full-window layouts"
block:
  for width in [480.0'f, 1280.0'f]:
    let
      scale = if width < 600: 0.25'f else: 0.5'f
      layout = initGameUiLayout(vec2(width, 900) / scale, 80)
      viewport = statsViewport(layout, scale)
    var table = StatsTable(kind: GotaStats)
    for slot in 0 ..< 10:
      table.rows.add StatsRow(slot: slot, team: slot div 5)
    let slots = statsLayout(viewport, table)
    doAssert statsScale(scale) * 18 >= 13.5
    doAssert slots.panel.inside(viewport.size)
    doAssert slots.maxScroll == 0
    doAssert slots.panel.size.x * statsScale(scale) <= width

when defined(nimTypeNames):
  echo "Testing director observations reuse frame storage"
  block:
    var
      director = initDirector()
      subjects = @[subject(1), subject(2, 3)]
    for i in 0 ..< 20:
      subjects[0].hp = if i mod 2 == 0: 80 else: 100
      director.observe(subjects)
      director.refresh(subjects)
      director.step(0.1)
    let before = getMemCounters()
    for i in 0 ..< 100:
      subjects[0].hp = if i mod 2 == 0: 80 else: 100
      director.observe(subjects)
      director.refresh(subjects)
      director.step(0.1)
    let after = getMemCounters()
    doAssert after[0] == before[0], "Director frames must reuse storage."
