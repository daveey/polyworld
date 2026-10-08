## Viewer-only subjects, observed events, shot continuity, and overviews.

import
  std/[math, tables],
  vmath

const
  ShotSeconds* = 4.0'f
  CutSeconds* = 8.0'f
  InterruptSeconds* = 2.0'f
  AftermathSeconds* = 2.0'f
  GlideSeconds* = 1.0'f
  OverviewSeconds* = 5.0'f
  OverviewInterval* = 30.0'f
  MajorScore* = 70.0'f
  CriticalScore* = 140.0'f
  EventLimit = 1024

type
  Subject* = object
    id*, owner*, floor*, participant*: int32
    position*: Vec3
    radius*, height*: float32
    visible*, alive*: bool
    hp*, maxHp*, activity*, progress*, gold*: int32
    fighting*, complete*, returned*, damageOnly*, combatOnly*: bool
    idleScore*, combatScore*: float32
  EventKind* = enum
    AttackEvent, DamageEvent, DeathEvent, HealEvent, ProgressEvent,
    ReturnEvent, FloorEvent
  DirectorEvent* = object
    subject*, participant*, floor*: int32
    position*: Vec3
    kind*: EventKind
    score*, started*, lifetime*: float32
    fresh: bool
  Visit = object
    id: int32
    time: float32
  Director* = object
    subjects*: seq[Subject]
    events*: seq[DirectorEvent]
    observed, nextObserved: Table[int32, Subject]
    visits: seq[Visit]
    time*, shotStarted*, lastCut*: float32
    lastMajor*, lastMeaningful*, sceneUntil*: float32
    subject*: Subject
    locked*, cut*: bool
    distance*, lift*: float32
    glideStart: Vec3
    glideElapsed: float32
    transitioning: bool
    overview*, finalResults*: bool
    overviewStarted*, lastOverview*, overduePriority*: float32
    finalStarted: float32
    retryOverview, completed, wasEnabled: bool

proc initDirector*(distance = 40.0'f): Director =
  ## Starts with a fresh cadence and no cached subject or event.
  Director(lastCut: -CutSeconds, lastMajor: -AftermathSeconds,
    distance: distance, lift: 0.25, wasEnabled: true)

proc reset*(director: var Director, preserveFinal = false) =
  ## Clears seek-dependent state, optionally retaining a loop's final card.
  let
    finalResults = preserveFinal and director.finalResults
    finalStarted = director.finalStarted
    time = director.time
    distance = director.distance
    lift = director.lift
  director = initDirector(distance)
  director.lift = lift
  if preserveFinal:
    director.time = time
    director.lastOverview = time
    director.finalResults = finalResults
    director.finalStarted = finalStarted

proc dismissOverview*(director: var Director) =
  ## Restarts the cadence when the user dismisses automatic coverage.
  director.overview = false
  director.finalResults = false
  director.retryOverview = false
  director.lastOverview = director.time

proc noteEvent*(director: var Director, subject: Subject,
    kind: EventKind, score: float32, lifetime = 1.2'f) =
  ## Replaces a short-lived event without accumulating stale peak scores.
  let event = DirectorEvent(
    subject: subject.id, participant: subject.participant,
    floor: subject.floor, position: subject.position, kind: kind,
    score: score, started: director.time, lifetime: lifetime, fresh: true
  )
  for old in director.events.mitems:
    if old.subject == subject.id and old.kind == kind:
      old = event
      return
  if director.events.len >= EventLimit:
    var oldest = 0
    for i in 1 ..< director.events.len:
      if director.events[i].started < director.events[oldest].started:
        oldest = i
    director.events[oldest] = event
    return
  director.events.add event

proc observe*(director: var Director, subjects: seq[Subject]) =
  ## Collects changes after each tick, independently of render frequency.
  director.nextObserved.clear()
  for subject in subjects:
    if subject.id == 0:
      continue
    director.nextObserved[subject.id] = subject
    if subject.id notin director.observed:
      if director.observed.len > 0 and subject.alive:
        director.noteEvent(subject, ProgressEvent, 38)
      continue
    let old = director.observed[subject.id]
    if not subject.visible and not old.visible:
      continue
    if old.alive and not subject.alive:
      director.noteEvent(subject, DeathEvent,
        max(subject.combatScore + 25, 90), 2)
    elif subject.alive:
      if subject.hp < old.hp:
        let danger = subject.combatScore >= 100 and
          subject.maxHp > 0 and subject.hp * 3 < subject.maxHp
        director.noteEvent(subject, DamageEvent,
          max(subject.combatScore, if danger: CriticalScore else: MajorScore))
      if subject.hp > old.hp and subject.complete and old.complete and
          subject.hp - old.hp >= max(2, subject.maxHp div 20):
        director.noteEvent(subject, HealEvent, 75)
      if subject.fighting and
          (not old.fighting or subject.activity > old.activity):
        director.noteEvent(subject, AttackEvent, subject.combatScore)
      if (subject.complete and not old.complete) or
          subject.progress != old.progress or subject.gold != old.gold:
        director.noteEvent(subject, ProgressEvent, 42)
      if subject.returned and not old.returned:
        director.noteEvent(subject, ReturnEvent, 90)
      if subject.floor != old.floor:
        director.noteEvent(subject, FloorEvent, 48)
  for id, old in director.observed:
    if id notin director.nextObserved and old.alive and old.visible:
      director.noteEvent(old, DeathEvent, max(old.combatScore + 25, 90), 2)
  swap(director.observed, director.nextObserved)

proc refresh*(director: var Director, subjects: seq[Subject]) =
  ## Replaces rendered bounds without manufacturing simulation events.
  director.subjects.setLen(subjects.len)
  for i, subject in subjects:
    director.subjects[i] = subject

proc valid(subject: Subject): bool =
  ## Accepts only visible, living objects with real entity identities.
  subject.id != 0 and subject.visible and subject.alive

proc separation(first, second: Vec3): float32 =
  ## Measures horizontal distance without averaging across floors.
  let delta = first - second
  sqrt(delta.x * delta.x + delta.z * delta.z)

proc related(event: DirectorEvent, subject: Subject): bool =
  ## Keeps events attached to participants or surviving scene neighbors.
  event.floor == subject.floor and
    (event.subject == subject.id or event.participant == subject.id or
      separation(event.position, subject.position) <= 8 + subject.radius)

proc eventScore(director: Director, event: DirectorEvent): float32 =
  ## Fades expired action promptly in viewing time at every replay speed.
  let age = max(director.time - event.started, 0)
  if age >= event.lifetime:
    return 0
  event.score * (1 - 0.35'f * age / event.lifetime)

proc eligible(director: Director, subject: Subject): bool =
  ## Requires the requested events for subjects excluded from idle shots.
  if not subject.damageOnly and not subject.combatOnly:
    return true
  for event in director.events:
    if director.eventScore(event) <= 0:
      continue
    if subject.damageOnly:
      if event.subject == subject.id and event.kind == DamageEvent:
        return true
    elif event.kind in {AttackEvent, DamageEvent, DeathEvent} and
      event.related(subject):
        return true

proc score(director: Director, subject: Subject): float32 =
  ## Scores observed events with a small, bounded preference for variety.
  result = if subject.owner >= 0: max(subject.idleScore, 1) else: 0
  for event in director.events:
    if event.related(subject):
      let weight = if event.subject == subject.id: 1.0'f else: 0.85'f
      result = max(result, director.eventScore(event) * weight)
  for visit in director.visits:
    if visit.id == subject.id and subject.id != director.subject.id:
      result *= 1 - 0.12'f * max(1 - (director.time - visit.time) / 30, 0)

proc advance*(director: var Director, dt: float32, enabled: bool,
    complete, repeating, manualPanel: bool, viewport: float32) =
  ## Advances coverage using viewing seconds and currently visible objects.
  director.cut = false
  if not enabled:
    director.overview = false
    director.finalResults = false
    director.wasEnabled = false
    return
  if not director.wasEnabled:
    let subjects = director.subjects
    director.reset()
    director.subjects = subjects
  director.wasEnabled = true
  director.time += max(dt, 0)
  for event in director.events.mitems:
    if event.fresh:
      event.started = director.time
      event.fresh = false
  var kept = 0
  for event in director.events:
    if director.eventScore(event) > 0:
      director.events[kept] = event
      inc kept
  director.events.setLen(kept)
  var
    current = -1
    best = -1
    neighbor = -1
    bestScore = -1.0'f
    neighborScore = -1.0'f
    major = false
    sceneMajor = false
    waitingForEvent = false
  for i, subject in director.subjects:
    if not subject.valid:
      continue
    if not director.eligible(subject):
      waitingForEvent = true
      continue
    let score = director.score(subject)
    if subject.id == director.subject.id:
      current = i
    if score > bestScore and (score > 0 or subject.owner >= 0):
      best = i
      bestScore = score
    if director.locked and subject.floor == director.subject.floor and
        separation(subject.position, director.subject.position) < 12:
      if score > neighborScore:
        neighbor = i
        neighborScore = score
    if score >= MajorScore:
      major = true
      if director.locked and subject.floor == director.subject.floor and
          separation(subject.position, director.subject.position) < 12:
        sceneMajor = true
    if score >= 30:
      director.lastMeaningful = director.time
  if major:
    director.lastMajor = director.time
  if sceneMajor:
    director.sceneUntil = director.time + AftermathSeconds
  let finished = complete or (best < 0 and not waitingForEvent)
  if finished and not director.completed:
    if not director.finalResults:
      director.finalStarted = director.time
    director.finalResults = true
    director.overview = false
  director.completed = finished
  if director.finalResults and repeating and
      director.time - director.finalStarted >= OverviewSeconds:
    director.finalResults = false
    director.lastOverview = director.time
  if best < 0:
    director.locked = false
    return
  if current < 0:
    if neighbor >= 0:
      best = neighbor
    director.cut = true
  else:
    let
      candidate = director.subjects[best]
      currentScore = director.score(director.subjects[current])
      age = director.time - director.shotStarted
      far = candidate.floor != director.subject.floor or
        separation(candidate.position, director.subjects[current].position) >
          viewport
      urgent = bestScore >= CriticalScore and
        bestScore > currentScore * 1.25'f and age >= InterruptSeconds
      better = bestScore > currentScore * 1.25'f + 3
      ordinary = age >= ShotSeconds and better and
        director.time >= director.sceneUntil and
        (not far or director.time - director.lastCut >= CutSeconds)
    if candidate.id == director.subject.id or dt <= 0 or
        not (urgent or ordinary):
      best = current
    else:
      director.cut = far
  let chosen = director.subjects[best]
  if not director.locked or chosen.id != director.subject.id:
    director.shotStarted = director.time
    director.transitioning = true
    director.glideElapsed = 0
    director.sceneUntil = director.time
    if director.visits.len >= 16:
      director.visits.delete(0)
    director.visits.add Visit(id: chosen.id, time: director.time)
  elif chosen.floor != director.subject.floor:
    director.cut = true
  if director.cut:
    director.lastCut = director.time
  director.subject = chosen
  director.locked = true
  let
    quiet = not major and director.time - director.lastMajor >= 2 and
      director.time >= director.sceneUntil
    sinceOverview = director.time - director.lastOverview
  director.overduePriority = max(0, (sinceOverview - OverviewInterval) / 15)
  if director.overview:
    if major or manualPanel:
      director.overview = false
      director.retryOverview = true
    elif director.time - director.overviewStarted >= OverviewSeconds:
      director.overview = false
      director.retryOverview = false
      director.lastOverview = director.overviewStarted
  elif not director.finalResults and not finished and not manualPanel and
      dt > 0 and quiet:
    let
      idle = director.time - director.lastMeaningful
      early = sinceOverview >= 15 and idle >= 5
      overdue = sinceOverview >= OverviewInterval
    if director.retryOverview or early or overdue:
      director.overview = true
      director.overviewStarted = director.time

proc follow*(director: var Director, target: var Vec3,
    distance: var float32, dt: float32) =
  ## Glides for one second, then follows the moving subject without lag.
  if not director.locked:
    return
  let
    pitch = 0.92'f
    halfFov = PI.float32 / 8
    groundSpan = director.distance * sin(pitch) *
      (1 / tan(pitch - halfFov) - 1 / tan(pitch + halfFov))
    destination = director.subject.position +
      vec3(0, director.subject.height, groundSpan * director.lift)
  if director.transitioning:
    director.glideStart = target - destination
    director.transitioning = false
  if director.cut:
    director.glideElapsed = GlideSeconds
  else:
    director.glideElapsed = min(GlideSeconds,
      director.glideElapsed + max(dt, 0))
  let
    fraction = director.glideElapsed / GlideSeconds
    remaining = 1 - fraction * fraction * (3 - 2 * fraction)
  target = destination + director.glideStart * remaining
  distance = director.distance
