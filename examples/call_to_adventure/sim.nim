## Call to Adventure simulation.
##
## Planar motion uses Q16.16 tile-space bodies. Home tiles, claims, and
## replay integers stay derived from `cell(body.pos)`. This module must not
## import anything that returns a float. Graphics may sample `surfaceHeight`
## and must not write simulation state.
##
## BASIC decisions arrive through `onHeroDecision`. This module owns the
## VM type on `Game` but never runs a program.

import
  bassy, fixxy,
  polyworld/[bodies, hashes, metrics, pathing, profiles, rngs, tapes,
    visions, mailboxes],
  content,
  maps,
  replays

type
  HeroVm* = ref object
    output*: PrintProc
    ## One compiled BASIC program for a party slot. Not simulation state.
    runtime*: Runtime
    ready*: bool
    failed*: bool
    lastError*: string
    decisions*: int
    lastWork*, lastInstructions*: int64
  Game* = ref object
    ## One expedition session. World is the hashable sim; everything else
    ## is tape, map, and agents.
    world*: World
    metrics*: MatchMetrics
    history*: MetricHistory
    dungeon*: Dungeon
    log*: seq[string]
    recorder*: ReplayRecorder
    replayData*: ReplayData
    replayPlayer*: ReplayPlayer
    hashCheck*: ReplayHashCheck
    historyPlayback*: bool
    replayMode*: bool
    heroVms*: array[PartySize, HeroVm]
    inboxes*: array[PartySize, Mailbox]

const
  AggroTiles* = 9'i32
  HeroAggroTiles* = 11'i32
  MonstersPerLevel* = [0, 5, 5, 6, 6, 7]
  RespawnIntervalTicks* = 360'i32
    ## A fresh monster every 15 seconds while the party returns.
  LootPickupRange* = 1'i32
  MaxMonsters* = 90
  ActorBodyRadius = 0.22'fx
  BodyTurnRate = 0.35'fx
  PathArrive = 0.35'fx

var
  sightTerrain: array[LevelCount, seq[int16]]
  sightBlockers: array[LevelCount, seq[int16]]
  visionBlockers: array[LevelCount, seq[int16]]
  visionSkipWorld: pointer
  visionSkipKeys: seq[int32]
  visionSkipNow: seq[int32]
  pathWorld: World
  pathSlot: int32
  pathGoalTile: TileRef
  pathTiles: seq[PathTile]
  ctaWalkLayer: int
  ctaWalkDestLayer: int

proc config*(game: Game): GameConfig =
  ## Reads the match configuration owned by the live or loaded replay.
  if game.recorder != nil:
    game.recorder.data.config
  else:
    game.replayData.config

proc lightRadius*(world: World, slot: int32): int32
proc bindActorBody(actor: Actor)
proc applyActorBody(world: World, slot: int32)

## Construction

proc newWorld*(setup: Setup): World =
  ## Creates the tick-zero world. Pure: no file access, no assets, no command
  ## line. Reads the generated terrain through `maps` but never mutates it.
  result = World()
  result.stats = newCombatStats(PartySize)
  result.setup = setup
  result.outcome = RunningOutcome
  result.phase = DescendingPhase
  result.nextActorId = 1
  result.nextItemId = 1
  result.rng = initRng(setup.seed)
  result.claims = newSeq[uint16](WorldTiles)
  result.explored = newSeq[uint8](WorldTiles div 8)
  for slot in 0 ..< PartySize:
    result.visible[slot] = newSeq[uint8](WorldTiles div 8)
  result.turnStart = result.rng.below(PartySize)

proc cloneActors(actors: seq[Actor]): seq[Actor] =
  ## Copies each actor so two worlds never share a path seq.
  result.setLen(actors.len)
  for i, actor in actors:
    result[i] = Actor()
    if not actor.isNil:
      result[i][] = actor[]

proc clone*(world: World): World =
  ## Deep copy. Actors are refs and must be cloned one by one.
  result = World()
  result[] = world[]
  result.stats = world.stats.clone()
  result.actors = cloneActors(world.actors)

proc restore*(world: World, snapshot: World) =
  ## Overwrites in place, keeping the caller's ref identity.
  world[] = snapshot[]
  world.stats = snapshot.stats.clone()
  world.actors = cloneActors(snapshot.actors)

## Bit maps

proc testBit(bits: seq[uint8], index: int32): bool {.inline.} =
  (bits[index shr 3] and (1'u8 shl (index and 7))) != 0

proc setBit(bits: var seq[uint8], index: int32) {.inline.} =
  bits[index shr 3] = bits[index shr 3] or (1'u8 shl (index and 7))

proc clearBits*(bits: var seq[uint8]) {.inline.} =
  for index in 0 ..< bits.len:
    bits[index] = 0

proc explored*(world: World, tile: TileRef): bool =
  ## Party-shared memory: true once any hero has seen this tile.
  world.explored.testBit(tile.tileIndex)

proc markExplored*(world: World, tile: TileRef) =
  world.explored.setBit(tile.tileIndex)

proc visible*(world: World, slot: int32, tile: TileRef): bool =
  ## Private sight: what this one hero can see right now.
  world.visible[slot].testBit(tile.tileIndex)

proc markVisible*(world: World, slot: int32, tile: TileRef) =
  world.visible[slot].setBit(tile.tileIndex)

proc tileKnown*(world: World, slot: int32, tile: TileRef): int32 =
  ## 0 unexplored, 1 remembered by the party, 2 visible to this hero. The
  ## asymmetry is deliberate: the party remembers together but each hero only
  ## sees for itself, which is what makes scouting worth scripting.
  if world.visible(slot, tile):
    2
  elif world.explored(tile):
    1
  else:
    0

proc prepareSightTerrain() =
  ## Builds derived integer terrain and structure occlusion grids by level.
  for level in 0 ..< LevelCount:
    if sightTerrain[level].len == TilesPerLevel:
      continue
    sightTerrain[level] = newSeq[int16](TilesPerLevel)
    sightBlockers[level] = newSeq[int16](TilesPerLevel)
    let layer = layers[level]
    for z in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        let
          index = z * GridTiles + x
          tile = layer.tiles[index]
          tops = tile.tops
        sightTerrain[level][index] = int16(
          (int32(tops[0]) + int32(tops[1]) +
            int32(tops[2]) + int32(tops[3])) div 4
        )
        if tile.kind == TreeTile:
          sightBlockers[level][index] = 24

proc fillVisionKeys(world: World, dest: var seq[int32]) =
  ## Records hero homes, life, torch range, and door state.
  dest.setLen(0)
  dest.add int32(world.actors.len)
  for slot in 0 ..< min(PartySize, world.actors.len):
    let hero = world.actors[slot]
    dest.add hero.id
    dest.add int32(hero.alive)
    dest.add int32(hero.home.level)
    dest.add int32(hero.home.x)
    dest.add int32(hero.home.z)
    dest.add world.lightRadius(int32(slot))
  dest.add int32(world.doors.len)
  for door in world.doors:
    dest.add door.id
    dest.add int32(door.tile.level)
    dest.add int32(door.tile.x)
    dest.add int32(door.tile.z)
    dest.add int32(door.open)

proc fillDynamicSightBlockers(world: World, level: int) =
  ## Fills reused occluders when a level has a closed door.
  visionBlockers[level].setLen(0)
  for door in world.doors:
    if not door.open and int(door.tile.level) == level:
      if visionBlockers[level].len == 0:
        visionBlockers[level].setLen(TilesPerLevel)
        for i, value in sightBlockers[level]:
          visionBlockers[level][i] = value
      visionBlockers[level][
        int32(door.tile.z) * GridTiles + int32(door.tile.x)
      ] = 28

proc rebuildVision*(world: World) {.measure.} =
  ## Rebuilds each hero's range- and occluder-limited private sight.
  world.fillVisionKeys(visionSkipNow)
  if visionSkipWorld == cast[pointer](world) and
      sameVisionKeys(visionSkipNow, visionSkipKeys):
    return
  prepareSightTerrain()
  for level in 0 ..< LevelCount:
    world.fillDynamicSightBlockers(level)
  initVisionKernel()
  for slot in 0 ..< PartySize:
    world.visible[slot].clearBits()
    if slot >= world.actors.len:
      continue
    let hero = world.actors[slot]
    if not hero.alive:
      continue
    let
      level = int(hero.home.level)
      radius = world.lightRadius(int32(slot))
      sourceX = int32(hero.home.x)
      sourceZ = int32(hero.home.z)
      sourceY = int64(sightTerrain[level][sourceZ * GridTiles + sourceX]) + 14
      useDynamic = visionBlockers[level].len > 0
    for offset in visionCircleTiles(radius):
      let
        x = sourceX + int32(offset.dx)
        z = sourceZ + int32(offset.dz)
      if x < 0 or x >= GridTiles or z < 0 or z >= GridTiles:
        continue
      let seen =
        if useDynamic:
          offsetVisible(
            GridTiles,
            sightTerrain[level],
            visionBlockers[level],
            sourceX,
            sourceZ,
            sourceY,
            offset
          )
        else:
          offsetVisible(
            GridTiles,
            sightTerrain[level],
            sightBlockers[level],
            sourceX,
            sourceZ,
            sourceY,
            offset
          )
      if seen:
        let tile = TileRef(
          level: int8(level),
          x: uint8(x),
          z: uint8(z)
        )
        world.markVisible(int32(slot), tile)
        world.markExplored(tile)
  copyVisionKeys(visionSkipKeys, visionSkipNow)
  visionSkipWorld = cast[pointer](world)

proc actorCanSee*(world: World, slot, targetSlot: int32): bool =
  ## Returns whether one hero or monster has unobstructed sight of another.
  if slot < 0 or targetSlot < 0 or
      slot >= world.actors.len or targetSlot >= world.actors.len:
    return false
  let
    observer = world.actors[slot]
    target = world.actors[targetSlot]
  if not observer.alive or not target.alive or
      observer.home.level != target.home.level:
    return false
  if observer.kind == HeroActor:
    return world.visible(slot, target.home)
  prepareSightTerrain()
  let level = int(observer.home.level)
  world.fillDynamicSightBlockers(level)
  if visionBlockers[level].len > 0:
    lineVisible(
      GridTiles,
      GridTiles,
      sightTerrain[level],
      visionBlockers[level],
      int32(observer.home.x),
      int32(observer.home.z),
      int32(target.home.x),
      int32(target.home.z),
      SpeciesSight[observer.species],
      12
    )
  else:
    lineVisible(
      GridTiles,
      GridTiles,
      sightTerrain[level],
      sightBlockers[level],
      int32(observer.home.x),
      int32(observer.home.z),
      int32(target.home.x),
      int32(target.home.z),
      SpeciesSight[observer.species],
      12
    )

## Claims

proc claimant*(world: World, tile: TileRef): int32 =
  ## Slot holding this tile, or -1 when free.
  int32(world.claims[tile.tileIndex]) - 1

proc claimed*(world: World, tile: TileRef): bool =
  world.claims[tile.tileIndex] != 0

proc claim*(world: World, tile: TileRef, slot: int32) =
  world.claims[tile.tileIndex] = uint16(slot + 1)

proc release*(world: World, tile: TileRef) =
  world.claims[tile.tileIndex] = 0

proc rebuildClaims*(world: World) =
  ## Claims are a pure function of actor home tiles.
  for index in 0 ..< world.claims.len:
    world.claims[index] = 0
  for slot, actor in world.actors:
    if actor.id == 0:
      continue
    world.claim(actor.home, int32(slot))

## Actors

proc addActor*(world: World, actor: Actor): int32 =
  ## Places an actor in the lowest free slot and claims its tile. Returns the
  ## slot, or -1 when the tile is already taken.
  if world.claimed(actor.home):
    return -1
  var placed = actor
  placed.id = world.nextActorId
  inc world.nextActorId
  placed.next = placed.home
  result = -1
  for slot in PartySize ..< world.actors.len:
    if world.actors[slot].id == 0:
      world.actors[slot] = placed
      result = int32(slot)
      break
  if result < 0:
    world.actors.add placed
    result = int32(world.actors.len - 1)
  world.claim(placed.home, result)
  world.actors[result].bindActorBody()

proc removeActor*(world: World, slot: int32) =
  ## Frees an actor's slot and both of its tile claims.
  if world.actors[slot].id == 0:
    return
  world.release(world.actors[slot].home)
  if world.actors[slot].moving:
    world.release(world.actors[slot].next)
  world.actors[slot] = Actor()

proc actorSlot*(world: World, id: int32): int32 =
  ## Slot for an actor id, or -1. Ids are small and actors few, so a scan
  ## beats carrying a derived index that a checkpoint would have to hash.
  if id == 0:
    return -1
  for slot, actor in world.actors:
    if actor.id == id:
      return int32(slot)
  -1

proc itemIndex*(world: World, id: int32): int32 =
  if id == 0:
    return -1
  for index, item in world.items:
    if item.id == id:
      return int32(index)
  -1

proc deleteItem(world: World, index: int32) =
  ## Removes one floor or carried item by seq index.
  if index < 0 or index >= world.items.len:
    return
  world.items.del(int(index))

proc freeInventorySlot(actor: Actor): int32 =
  ## First empty item slot, or -1 when both are full.
  for index in 0 ..< InventorySlots:
    if actor.inventory[index] == 0:
      return int32(index)
  -1

proc refreshSpeed(actor: Actor) =
  ## Applies encumbrance and a short winged-boot haste.
  var scale = EncumbranceScale[actor.encumbrance(actor.carryCapacity)]
  if actor.hasteTicks > 0:
    scale = scale * 13 div 10
  actor.speed = max(actor.baseSpeed * scale div 100, 1)

proc spawnLoot(
    game: Game,
    kind: LootKind,
    tile: TileRef,
    value = 0'i32
): int32 =
  ## Places one pile or usable item on a tile and returns its id.
  result = game.world.nextItemId
  game.world.items.add Item(
    id: result,
    kind: kind,
    tile: tile,
    value:
      if value > 0: value
      else: LootValues[kind],
    weight: LootWeights[kind]
  )
  inc game.world.nextItemId

proc doorIndex*(world: World, id: int32): int32 =
  if id == 0:
    return -1
  for index, door in world.doors:
    if door.id == id:
      return int32(index)
  -1

## Party helpers

proc heroSlot*(world: World, id: int32): int32 =
  ## Like `actorSlot`, but restricted to the four party members.
  for slot in 0 ..< PartySize:
    if world.actors[slot].id == id:
      return int32(slot)
  -1

proc partyAlive*(world: World): int32 =
  for slot in 0 ..< PartySize:
    if world.actors[slot].alive:
      inc result

proc lightRadius*(world: World, slot: int32): int32 =
  ## How far this hero's torch reaches, before line of sight is applied.
  let actor = world.actors[slot]
  if actor.kind != HeroActor:
    return 0
  ClassLightRadius[actor.heroClass]

## Chat

proc say*(world: World, speaker, phrase, value: int32) =
  ## Appends to the chat ring. Simulation state, so it is hashed and replayed.
  world.chat[world.chatHead] = ChatLine(
    speaker: speaker,
    phrase: phrase,
    value: value,
    tick: world.tick
  )
  world.chatHead = (world.chatHead + 1) mod ChatLines

## Geometry

proc tileDistance*(a, b: TileRef): int32 =
  ## Chebyshev distance in tiles, or -1 when the tiles are on different
  ## levels. Integer throughout: nothing in the simulation takes a root.
  if a.level != b.level:
    return -1
  max(abs(int32(a.x) - int32(b.x)), abs(int32(a.z) - int32(b.z)))

proc neighbor*(tile: TileRef, facing: Facing): TileRef =
  ## The adjacent tile within the same level, ignoring layer links. Callers
  ## that need a cross-level step use `edgeLink` instead.
  result = tile
  case facing
  of East: result.x = uint8(int32(tile.x) + 1)
  of South: result.z = uint8(int32(tile.z) + 1)
  of West: result.x = uint8(int32(tile.x) - 1)
  of North: result.z = uint8(int32(tile.z) - 1)

proc walkable*(tile: TileRef): bool =
  ## Terrain-only test; occupancy is a separate question.
  isWalkable(int(tile.level), int(tile.x), int(tile.z))

proc planarCenter(tile: TileRef): FixedVec2 =
  ## Returns the tile-space centre of one dungeon cell.
  fixedVec2(
    fixed(int32(tile.x)) + 0.5'fx,
    fixed(int32(tile.z)) + 0.5'fx
  )

proc angleFromFacing(facing: Facing): Fixed =
  ## Maps a cardinal facing onto body radians (east is zero).
  case facing
  of East: FixedZero
  of South: FixedHalfPi
  of West: FixedPi
  of North: -FixedHalfPi

proc facingFromAngle(angle: Fixed): Facing =
  ## Snaps a body heading to the nearest cardinal.
  let dir = direction(wrapAngle(angle))
  if abs(dir.x) >= abs(dir.y):
    if dir.x >= FixedZero: East else: West
  else:
    if dir.y >= FixedZero: South else: North

proc bindActorBody(actor: Actor) =
  ## Stands a body on the actor's home tile.
  actor.body.pos = planarCenter(actor.home)
  actor.body.radius = ActorBodyRadius
  actor.body.facing = angleFromFacing(actor.facing)

proc applyActorBody(world: World, slot: int32) =
  ## Writes the body plane back onto home, facing, and the current waypoint.
  let
    actor = world.actors[slot]
    (x, z) = cell(actor.body.pos)
  actor.home.x = uint8(clamp(x, 0'i32, int32(GridTiles - 1)))
  actor.home.z = uint8(clamp(z, 0'i32, int32(GridTiles - 1)))
  actor.home.level = int8(preferLayer(
    int(actor.home.level),
    ctaWalkDestLayer,
    int(actor.home.x),
    int(actor.home.z)
  ))
  actor.facing = facingFromAngle(actor.body.facing)
  if actor.moving:
    actor.next = actor.path[actor.pathIndex].tile
  else:
    actor.next = actor.home

proc ctaTilesWalkable(pos: FixedVec2): bool {.nimcall.} =
  ## Current floor, plus the next waypoint's floor while crossing a ramp.
  let (x, z) = cell(pos)
  layersOpen(ctaWalkLayer, ctaWalkDestLayer, int(x), int(z))

proc moveSpeed(actor: Actor): Fixed =
  ## Tiles walked in one tick from the actor's phase speed.
  fixed(max(actor.speed, 1)) / fixed(PhaseUnits)

proc smoothPathLayers(tiles: seq[PathTile]): seq[PathTile] =
  ## String-pulls each same-layer run so a ramp stays an explicit waypoint.
  if tiles.len == 0:
    return
  var start = 0
  for i in 1 .. tiles.len:
    if i < tiles.len and tiles[i].layer == tiles[start].layer:
      continue
    let pulled = smoothPathTiles(tiles[start ..< i])
    if result.len > 0 and pulled.len > 0 and result[^1] == pulled[0]:
      for j in 1 ..< pulled.len:
        result.add pulled[j]
    else:
      result.add pulled
    start = i

proc stepTarget*(tile: TileRef, facing: Facing): (bool, TileRef) =
  ## Resolves one step through the engine's cross-layer edge links, which is
  ## what lets a hero walk up a ramp onto the next level with no special case.
  let link = edgeLink(int(tile.level), int(tile.x), int(tile.z), facing.ord)
  if not link.open:
    return (false, tile)
  (true, TileRef(level: int8(link.layer), x: uint8(link.x), z: uint8(link.z)))

proc stepCost*(fromTile, toTile: TileRef): int32 =
  ## What one step costs in phase units. Climbing is dearer than walking and
  ## descending is slightly cheaper, priced straight off the packed corner
  ## heights so a ramp slows the party down without any floating point.
  let
    fromTop = tileTop(int(fromTile.level), int(fromTile.x), int(fromTile.z))
    toTop = tileTop(int(toTile.level), int(toTile.x), int(toTile.z))
    rise = toTop - fromTop
  result =
    if rise > 0: PhaseUnits + rise * ClimbCostPerStep
    else: PhaseUnits + rise * DescendCostPerStep
  result = clamp(result, MinimumStepUnits, MaximumStepUnits)

proc startStep*(world: World, slot: int32, facing: Facing): bool =
  ## Begins one step. Returns false when the way is blocked, which is normal:
  ## the caller waits or re-paths rather than treating it as an error.
  if world.actors[slot].moving:
    return false
  let
    home = world.actors[slot].home
    (open, target) = home.stepTarget(facing)
  if not open:
    return false
  if world.claimed(target):
    return false
  world.claim(target, slot)
  world.actors[slot].next = target
  world.actors[slot].facing = facing
  world.actors[slot].stepUnits = stepCost(home, target)
  true

proc advanceStep*(world: World, slot: int32) =
  ## Moves one tick along the current step, releasing the tile behind once the
  ## actor has fully arrived. The leftover phase carries into the next step so
  ## speed stays exactly linear rather than drifting a little each tile.
  if not world.actors[slot].moving:
    world.actors[slot].phase = 0
    return
  world.actors[slot].phase += max(world.actors[slot].speed, 1)
  if world.actors[slot].phase >= world.actors[slot].stepUnits:
    world.release(world.actors[slot].home)
    world.actors[slot].phase -= world.actors[slot].stepUnits
    world.actors[slot].home = world.actors[slot].next
    if world.actors[slot].phase >= world.actors[slot].stepUnits:
      world.actors[slot].phase = 0

proc facingToward*(fromTile, toTile: TileRef): Facing =
  ## Which way to face to reach an adjacent tile.
  if toTile.x > fromTile.x: East
  elif toTile.x < fromTile.x: West
  elif toTile.z > fromTile.z: South
  else: North

proc clearPath*(world: World, slot: int32) =
  world.actors[slot].path.setLen(0)
  world.actors[slot].pathIndex = 0
  world.actors[slot].stuckTicks = 0

proc ctaPathWalkable(layer, x, z: int): bool {.nimcall.} =
  ## Terrain plus occupancy, except the searcher and the destination.
  let tile = TileRef(
    level: int8(layer),
    x: uint8(x),
    z: uint8(z)
  )
  if not tile.walkable:
    return false
  if tile == pathGoalTile:
    return true
  let holder = pathWorld.claimant(tile)
  holder < 0 or holder == pathSlot

proc setPath*(world: World, slot: int32, goal: TileRef,
    offset = FixedVec2Zero): bool =
  ## Asks the engine for a route around other occupants and stores it as
  ## tiles to walk. The path crosses layers wherever a ramp does.
  let actor = world.actors[slot]
  if actor.home == goal:
    world.clearPath(slot)
    if offset != FixedVec2Zero:
      actor.path.add PathStep(tile: goal, offset: offset)
    return true
  pathWorld = world
  pathSlot = slot
  pathGoalTile = goal
  discard fillTilePath(PathQuery(
    startLayer: int(actor.home.level),
    startX: int(actor.home.x),
    startZ: int(actor.home.z),
    finishLayer: int(goal.level),
    finishX: int(goal.x),
    finishZ: int(goal.z),
    walkable: ctaPathWalkable,
    partial: true
  ), pathTiles)
  if pathTiles.len < 2:
    world.clearPath(slot)
    return false
  let pulled = smoothPathLayers(pathTiles)
  if pulled.len == 0:
    world.clearPath(slot)
    return false
  let steps = min(pulled.len, MaximumPathTiles)
  actor.path.setLen(steps)
  var previous = actor.home
  for i in 0 ..< steps:
    let tile = TileRef(
      level: int8(pulled[i].layer),
      x: uint8(pulled[i].x),
      z: uint8(pulled[i].z)
    )
    actor.path[i] = PathStep(
      tile: tile,
      direction: facingToward(previous, tile)
    )
    previous = tile
  if actor.path[^1].tile == goal:
    actor.path[^1].offset = offset
  actor.pathIndex = 0
  actor.stuckTicks = 0
  true

proc pathGoal*(world: World, slot: int32): TileRef =
  let actor = world.actors[slot]
  if actor.path.len == 0:
    return actor.home
  actor.path[^1].tile

proc followPath*(world: World, slot: int32): bool =
  ## Steers toward the next pulled waypoint. Returns false once finished.
  if world.actors[slot].pathIndex >= int32(world.actors[slot].path.len):
    world.clearPath(slot)
    ctaWalkDestLayer = int(world.actors[slot].home.level)
    world.applyActorBody(slot)
    return false
  let
    step = world.actors[slot].path[world.actors[slot].pathIndex]
    waypoint = step.tile
    dest = planarCenter(waypoint) + step.offset
    radius =
      if step.offset != FixedVec2Zero:
        fixed(1, 1000)
      else:
        PathArrive
  if length(dest - world.actors[slot].body.pos) <= radius:
    world.actors[slot].home = waypoint
    inc world.actors[slot].pathIndex
    world.actors[slot].stuckTicks = 0
    return world.followPath(slot)
  let before = world.actors[slot].body.pos
  ctaWalkLayer = int(world.actors[slot].home.level)
  ctaWalkDestLayer = int(waypoint.level)
  steer(
    world.actors[slot].body,
    dest - world.actors[slot].body.pos,
    world.actors[slot].moveSpeed,
    BodyTurnRate,
    ctaTilesWalkable
  )
  world.applyActorBody(slot)
  if world.actors[slot].body.pos == before:
    inc world.actors[slot].stuckTicks
    if world.actors[slot].stuckTicks >= SidestepAfterStuckTicks:
      world.clearPath(slot)
      return false
    if world.actors[slot].stuckTicks mod RepathAfterStuckTicks == 0:
      let
        goal = world.pathGoal(slot)
        offset = world.actors[slot].path[^1].offset
        stuck = world.actors[slot].stuckTicks
      if not world.setPath(slot, goal, offset):
        world.clearPath(slot)
        return false
      world.actors[slot].stuckTicks = stuck
  else:
    world.actors[slot].stuckTicks = 0
  true

proc advancePath*(world: World, slot: int32): bool =
  ## Advances one path tick along the current pulled route.
  world.followPath(slot)

proc stepToward*(world: World, slot: int32, goal: TileRef,
    offset = FixedVec2Zero): bool =
  ## Sets or updates a walk path. Movement happens in `advancePath`.
  if world.actors[slot].path.len == 0 or
      world.actors[slot].pathIndex >= int32(world.actors[slot].path.len) or
      world.pathGoal(slot) != goal or
      world.actors[slot].path[^1].offset != offset:
    if not world.setPath(slot, goal, offset):
      return false
  true

proc wantedTile*(world: World, slot: int32): (bool, TileRef) =
  ## The tile this actor is trying to step into right now, if any.
  let actor = world.actors[slot]
  if actor.moving or actor.busy or not actor.alive:
    return (false, TileRef())
  if actor.pathIndex >= int32(actor.path.len):
    return (false, TileRef())
  actor.home.stepTarget(actor.path[actor.pathIndex].direction)

proc resolveAllySwaps*(world: World) =
  ## Lets two party members walk through each other when each wants the tile
  ## the other is standing on.
  ##
  ## Exclusive occupancy means a head-on pair deadlocks permanently: neither
  ## can move, so neither ever frees the tile the other is waiting for, and
  ## re-pathing returns the same blocked first step forever. A four-hero party
  ## in a corridor hits this constantly. Pairs are resolved in ascending slot
  ## order so the outcome does not depend on iteration accidents, and longer
  ## jams unwind over successive ticks as each pair in the chain swaps.
  for first in 0'i32 ..< PartySize:
    let (firstWants, firstTarget) = world.wantedTile(first)
    if not firstWants:
      continue
    for second in first + 1 ..< PartySize:
      let (secondWants, secondTarget) = world.wantedTile(second)
      if not secondWants:
        continue
      if not (firstTarget == world.actors[second].home):
        continue
      if not (secondTarget == world.actors[first].home):
        continue
      let
        firstHome = world.actors[first].home
        secondHome = world.actors[second].home
      world.claim(secondHome, first)
      world.claim(firstHome, second)
      world.actors[first].home = secondHome
      world.actors[first].next = secondHome
      world.actors[first].facing = facingToward(firstHome, secondHome)
      world.actors[first].phase = 0
      inc world.actors[first].pathIndex
      world.actors[first].stuckTicks = 0
      world.actors[second].home = firstHome
      world.actors[second].next = firstHome
      world.actors[second].facing = facingToward(secondHome, firstHome)
      world.actors[second].phase = 0
      inc world.actors[second].pathIndex
      world.actors[second].stuckTicks = 0
      break

proc adjacent*(a, b: TileRef): bool =
  ## True when two tiles share an edge on the same level.
  if a.level != b.level:
    return false
  let
    dx = abs(int32(a.x) - int32(b.x))
    dz = abs(int32(a.z) - int32(b.z))
  dx + dz == 1

proc inMelee*(a, b: TileRef): bool =
  ## Melee reaches the eight surrounding tiles, so a hero pinned diagonally
  ## in a doorway can still fight.
  if a.level != b.level:
    return false
  let
    dx = abs(int32(a.x) - int32(b.x))
    dz = abs(int32(a.z) - int32(b.z))
  dx <= 1 and dz <= 1 and dx + dz > 0

proc hashWorld*(world: World): uint64 =
  ## Hashes all authoritative world fields, including statistics.
  var hash = HashySeed
  for name, value in fieldPairs(world[]):
    when name != "stats":
      hash.addHashy(value)
  hash.addHashy(world.stats)
  uint64(hash)

## Spawning

proc levelSpecies*(level: int, rng: var Rng): Species =
  ## Chooses a weighted rank from the floor's color-coded family.
  assert level > SurfaceLevel and level < LevelCount
  let
    roll = rng.below(100)
    rank =
      if roll < 40: RuntRank
      elif roll < 70: RaiderRank
      elif roll < 90: CasterRank
      else: ChampionRank
  Species(FloorFamilies[level].ord * 4 + rank.ord)

proc freeTileIn(
    game: Game, level: int, room: Room, rng: var Rng
): (bool, TileRef) =
  ## Finds an unclaimed walkable tile inside a room. Occupancy is exclusive,
  ## so a spawn has to check claims, not just terrain.
  for _ in 0 ..< 40:
    let
      x = rng.between(room.x, room.x + room.width - 1)
      z = rng.between(room.z, room.z + room.depth - 1)
      tile = TileRef(level: int8(level), x: uint8(x), z: uint8(z))
    if isWalkable(level, int(x), int(z)) and not game.world.claimed(tile):
      return (true, tile)
  (false, TileRef())

proc spawnMonster*(game: Game, level: int, rng: var Rng): bool =
  ## Places one monster in a random room of a level.
  if game.world.actors.len - PartySize >= MaxMonsters:
    return false
  let rooms = game.dungeon.rooms[level]
  if rooms.len == 0:
    return false
  let room = rooms[rng.below(int32(rooms.len))]
  let (found, tile) = game.freeTileIn(level, room, rng)
  if not found:
    return false
  let species = levelSpecies(level, rng)
  # Deeper monsters are tougher, which is what makes the climb back out worse
  # than the way down. Widen to int32 before multiplying champion health.
  let
    toughness = 100'i32 + int32(level) * 10
    hp = int16(
      min(int32(SpeciesHp[species]) * toughness div 100, 30_000))
  discard game.world.addActor(Actor(
    kind: MonsterActor,
    class: uint8(species),
    home: tile,
    next: tile,
    baseSpeed: SpeciesSpeeds[species],
    speed: SpeciesSpeeds[species],
    hp: hp,
    maxHp: hp,
    state: GuardingState
  ))
  true

proc populateDungeon*(game: Game) =
  var rng = game.world.rng
  for level in 1 ..< LevelCount:
    for _ in 0 ..< MonstersPerLevel[level]:
      discard game.spawnMonster(level, rng)
  game.world.rng = rng

proc spawnParty*(game: Game) =
  ## Puts the four heroes on and around the entrance tile.
  let entrance = game.dungeon.entrance
  game.world.actors.setLen(PartySize)
  var placed = 0
  for radius in 0'i32 .. 6'i32:
    for dz in -radius .. radius:
      for dx in -radius .. radius:
        if placed >= PartySize:
          continue
        if max(abs(dx), abs(dz)) != radius:
          continue
        let tile = TileRef(
          level: entrance.level,
          x: uint8(int32(entrance.x) + dx),
          z: uint8(int32(entrance.z) + dz))
        if not isWalkable(
            int(tile.level), int(tile.x), int(tile.z)) or
            game.world.claimed(tile):
          continue
        let class = HeroClass(placed)
        game.world.actors[placed] = Actor(
          id: int32(100 + placed),
          kind: HeroActor,
          class: uint8(class),
          home: tile,
          next: tile,
          baseSpeed: ClassSpeeds[class],
          speed: ClassSpeeds[class],
          hp: ClassHp[class],
          maxHp: ClassHp[class],
          mana: ClassMana[class],
          maxMana: ClassMana[class]
        )
        game.world.claim(tile, int32(placed))
        game.world.actors[placed].bindActorBody()
        inc placed
  doAssert placed == PartySize, "the entrance has no room for the party"
  game.world.nextActorId = int32(100 + PartySize)

proc sampleMetrics*(game: Game, force = false) =
  ## Samples deterministic world counters and independent VM telemetry.
  if game.metrics == nil or game.world.stats == nil:
    return
  for slot, values in game.world.stats.values:
    for kind in MetricKind:
      game.metrics.set(slot, kind, values[kind])
    let hero = game.world.actors[slot]
    game.metrics.set(slot, GoldMetric,
      if hero.alive: hero.carriedValue else: 0)
    game.metrics.set(slot, BankedMetric, game.world.bankedGold[slot])
  game.history.capture(game.metrics, game.world.tick, force)

proc newGame*(
    seed: int32,
    maximumTicks = DefaultMaximumTicks
): Game =
  ## Generates a dungeon, verifies it can be completed, and fills it.
  result = Game(metrics: newMetrics(PartySize, TickRate))
  result.dungeon = generateMap(seed)
  result.dungeon.verifyDungeon()
  doAssert result.dungeon.descentPath(),
    "generated a dungeon the party cannot finish"
  var setup = Setup(
    seed: seed,
    mapVersion: 1,
    tickRate: uint16(TickRate),
    gridTiles: uint16(GridTiles),
    levels: uint8(LevelCount),
    decisionTicks: uint16(DecisionTicks),
    hashIntervalTicks: uint16(HashIntervalTicks),
    maximumTicks: uint32(maximumTicks)
  )
  for slot in 0 ..< PartySize:
    setup.party[slot] = PartyMember(
      id: int32(100 + slot), class: HeroClass(slot))
  setup.mapHash = result.dungeon.hash
  result.world = newWorld(setup)
  result.spawnParty()
  result.populateDungeon()
  result.world.rebuildVision()

  result.sampleMetrics(true)

## Queries

proc monstersOn*(game: Game, level: int): int32 =
  for actor in game.world.actors:
    if actor.kind == MonsterActor and actor.alive and
        int(actor.home.level) == level:
      inc result

proc partyLevel*(game: Game): int32 =
  ## The level most of the living party is standing on, which is what
  ## "the party has cleared this floor" means.
  var counts: array[LevelCount, int32]
  for slot in 0 ..< PartySize:
    if game.world.actors[slot].alive:
      inc counts[int(game.world.actors[slot].home.level)]
  var best = 0'i32
  for level in 0 ..< LevelCount:
    if counts[level] > counts[best]:
      best = int32(level)
  best

proc viewLevel*(
    game: Game,
    selected: array[PartySize, bool]
): int32 =
  ## The uppermost floor a selected living hero stands on. The cutaway
  ## draws that floor and everything under it, so a hero who has started
  ## the climb is not hidden by party members still below.
  result = int32(LevelCount)
  for slot in 0 ..< min(PartySize, game.world.actors.len):
    if not selected[slot]:
      continue
    let actor = game.world.actors[slot]
    if actor.alive and int32(actor.home.level) < result:
      result = int32(actor.home.level)
  if result < int32(LevelCount):
    return
  for slot in 0 ..< min(PartySize, game.world.actors.len):
    let actor = game.world.actors[slot]
    if actor.alive and int32(actor.home.level) < result:
      result = int32(actor.home.level)
  if result >= int32(LevelCount):
    result = 0

proc nearestEnemy*(game: Game, slot: int32, reach: int32): int32 =
  ## Nearest living opponent on the same level within reach, or -1.
  result = -1
  let
    actor = game.world.actors[slot]
    wantMonster = actor.kind == HeroActor
  var bestDistance = reach + 1
  for other in 0 ..< game.world.actors.len:
    let target = game.world.actors[other]
    if not target.alive:
      continue
    if (target.kind == MonsterActor) != wantMonster:
      continue
    if not game.world.actorCanSee(slot, int32(other)):
      continue
    let distance = tileDistance(actor.home, target.home)
    if distance < 0 or distance > reach:
      continue
    if distance < bestDistance:
      bestDistance = distance
      result = int32(other)

proc partyAnchor*(game: Game): int32 =
  ## The living hero the rest of the party orients on: the fighter while he
  ## stands, otherwise whoever is left, lowest slot first so the choice never
  ## depends on iteration order.
  for slot in 0 ..< PartySize:
    if game.world.actors[slot].alive:
      return int32(slot)
  -1

proc nearestMonsterHome*(game: Game, slot: int32): TileRef =
  ## Closest living monster on this hero's floor, even through fog of war.
  let actor = game.world.actors[slot]
  result = actor.home
  var bestDistance = int32(GridTiles * 2)
  for other in 0 ..< game.world.actors.len:
    let target = game.world.actors[other]
    if not target.alive or target.kind != MonsterActor:
      continue
    if target.home.level != actor.home.level:
      continue
    let distance = tileDistance(actor.home, target.home)
    if distance >= 0 and distance < bestDistance:
      bestDistance = distance
      result = target.home

proc nearestLoot*(game: Game, slot: int32): int32 =
  ## Index of the closest unclaimed treasure on this hero's level, or -1.
  result = -1
  let actor = game.world.actors[slot]
  var bestDistance = 30'i32
  for index, item in game.world.items:
    if item.carrier != 0:
      continue
    if item.tile.level != actor.home.level:
      continue
    if not game.world.visible(slot, item.tile):
      continue
    if item.kind.lootUsesSlot and actor.freeInventorySlot() < 0:
      continue
    let distance = tileDistance(actor.home, item.tile)
    if distance >= 0 and distance < bestDistance:
      bestDistance = distance
      result = int32(index)

## Combat

proc beginAbility(game: Game, slot: int32, ability: Ability, target: int32) =
  if game.world.actors[slot].busy:
    return
  if game.world.actors[slot].cooldowns[int(ability)] > 0:
    return
  game.world.actors[slot].action = ability
  game.world.actors[slot].actionTicks = 0
  game.world.actors[slot].target = target

proc extraLootKind(level: int, species: Species, rng: var Rng): LootKind =
  ## Picks one extra drop. Deeper floors and champions roll richer treasure.
  if rng.chance(45):
    if level >= 5 or
      (species.monsterRank == ChampionRank and rng.chance(35)):
        return Crown
    if level >= 4 or species.monsterRank == ChampionRank:
      if rng.chance(55):
        return Idol
      return Chalice
    if level >= 3:
      if rng.chance(50):
        return Chalice
      return Gemstone
    if level >= 2 and rng.chance(35):
      return Chalice
    return Gemstone
  UsableLoot[rng.below(int32(UsableLoot.len))]

proc dropLoot(game: Game, slot: int32) =
  ## A dead monster always leaves gold, and often a second floor drop.
  var rng = game.world.rng
  let
    actor = game.world.actors[slot]
    level = int(actor.home.level)
    gold = LootValues[GoldPile] + int32(level) * 8
  discard game.spawnLoot(GoldPile, actor.home, gold)
  var itemChance = 22 + level * 8
  if actor.species.monsterRank == ChampionRank:
    itemChance += 25
  if rng.chance(int32(min(itemChance, 75))):
    discard game.spawnLoot(
      extraLootKind(level, actor.species, rng),
      actor.home
    )
  game.world.rng = rng

proc killActor(game: Game, slot: int32) =
  let actor = game.world.actors[slot]
  if actor.kind == MonsterActor:
    game.dropLoot(slot)
    inc game.world.killed
    game.world.removeActor(slot)
  else:
    # A fallen hero drops gold and gear so the rest of the party can
    # still take it. Their tile frees up; the body is not simulated.
    if actor.carriedValue > 0:
      discard game.spawnLoot(GoldPile, actor.home, actor.carriedValue)
    for index in 0 ..< InventorySlots:
      let itemId = actor.inventory[index]
      if itemId == 0:
        continue
      let itemIndex = game.world.itemIndex(itemId)
      if itemIndex >= 0:
        game.world.items[itemIndex].carrier = 0
        game.world.items[itemIndex].tile = actor.home
    game.log.add "a hero has fallen on level " & $int(actor.home.level)
    game.world.removeActor(slot)

proc applyAbility(game: Game, slot: int32) =
  ## Lands an ability's effect on the windup tick, never on an animation
  ## frame: the client warps its clip to match, not the other way round.
  let
    actor = game.world.actors[slot]
    ability = actor.action
    spec = Abilities[ability]
  if ability == ChainAxe:
    let itemIndex = game.world.itemIndex(actor.target)
    if itemIndex >= 0 and game.world.items[itemIndex].carrier == 0:
      let item = game.world.items[itemIndex]
      if not item.kind.lootUsesSlot:
        game.world.actors[slot].carriedValue += item.value
        inc game.world.collected
        game.world.deleteItem(itemIndex)
      else:
        let bag = game.world.actors[slot].freeInventorySlot()
        if bag >= 0:
          game.world.actors[slot].carriedValue += item.value
          game.world.items[itemIndex].value = 0
          game.world.items[itemIndex].carrier = actor.id
          game.world.actors[slot].inventory[bag] = item.id
          game.world.actors[slot].carriedWeight += item.weight
          inc game.world.collected
          game.world.actors[slot].refreshSpeed()
    return
  if ability == HealingPotion:
    game.world.stats.add(int(slot), HealingMetric,
      min(80, int(actor.maxHp - actor.hp)))
    game.world.actors[slot].hp = min(
      actor.hp + 80,
      actor.maxHp
    )
    return
  if ability == ManaCrystal:
    game.world.actors[slot].mana = min(
      actor.mana + 50,
      actor.maxMana
    )
    return
  if ability == BattleHorn:
    for other in 0 ..< PartySize:
      if game.world.actors[other].alive and
          game.world.actors[other].home.level == actor.home.level:
        game.world.actors[other].guardTicks = 48
    return
  if ability == WingedBoot:
    game.world.actors[slot].hasteTicks = 72
    game.world.actors[slot].refreshSpeed()
    return
  if ability in {InfernoAegis, IceWall, ThornRing}:
    game.world.actors[slot].guardTicks = 64
    return
  if ability == NatureTalisman:
    game.world.stats.add(int(slot), HealingMetric,
      min(40, int(actor.maxHp - actor.hp)))
    game.world.actors[slot].hp = min(actor.hp + 40, actor.maxHp)
    game.world.actors[slot].mana = min(actor.mana + 30, actor.maxMana)
    return

  let targetSlot = game.world.actorSlot(actor.target)
  if targetSlot < 0 or not game.world.actors[targetSlot].alive:
    return
  if not game.world.actorCanSee(slot, targetSlot):
    return
  if tileDistance(actor.home, game.world.actors[targetSlot].home) >
      int32(spec.rangeTiles):
    return

  var rng = game.world.rng
  var damage = int32(spec.damage) + rng.below(int32(spec.spread) + 1)
  if actor.kind == MonsterActor:
    damage = damage * SpeciesDamage[actor.species] div 100
  elif damage > 0:
    damage = damage * ClassDamage[actor.heroClass] div 100
  if game.world.actors[targetSlot].guardTicks > 0:
    damage = damage * 40 div 100
  game.world.rng = rng

  if damage < 0:
    if actor.kind == HeroActor and
      game.world.actors[targetSlot].kind == HeroActor:
        game.world.stats.add(int(slot), HealingMetric,
          min(-damage, int32(game.world.actors[targetSlot].maxHp -
            game.world.actors[targetSlot].hp)))
    # Healing is negative damage, so one path covers both and the cleric
    # needs no special case beyond choosing an ally to aim at.
    game.world.actors[targetSlot].hp = min(
      game.world.actors[targetSlot].hp + int16(-damage),
      game.world.actors[targetSlot].maxHp)
    return

  if actor.kind == HeroActor and
    game.world.actors[targetSlot].kind == MonsterActor:
      game.world.stats.add(int(slot), DamageMetric,
        min(max(damage, 1), int32(game.world.actors[targetSlot].hp)))
      if max(damage, 1) >= game.world.actors[targetSlot].hp:
        game.world.stats.add(int(slot), KillsMetric)
  game.world.actors[targetSlot].hp -= int16(max(damage, 1))
  game.world.actors[targetSlot].sinceHitTicks = 0
  if game.world.actors[targetSlot].hp <= 0:
    game.killActor(targetSlot)

proc advanceAction(game: Game, slot: int32) =
  if game.world.actors[slot].action == NoAbility:
    return
  let spec = Abilities[game.world.actors[slot].action]
  inc game.world.actors[slot].actionTicks
  if game.world.actors[slot].actionTicks == spec.windupTicks:
    game.applyAbility(slot)
  if game.world.actors[slot].actionTicks >=
      spec.windupTicks + spec.recoverTicks:
    game.world.actors[slot].cooldowns[int(game.world.actors[slot].action)] =
      spec.cooldownTicks
    game.world.actors[slot].action = NoAbility
    game.world.actors[slot].actionTicks = 0


## Hero behaviour

proc rampTileFor(game: Game, level: int, descending: bool): TileRef =
  ## Where to walk to leave this level. Deliberately a landing on the *far*
  ## side of the ramp: aiming at the near landing parks the party on the top
  ## step forever, because arriving there satisfies the goal without ever
  ## crossing. Pathing spans layers by itself, so the far landing is enough.
  for ramp in game.dungeon.ramps:
    if descending and int(ramp.upper) == level:
      return TileRef(
        level: int8(ramp.lower),
        x: uint8(ramp.bottomX),
        z: uint8(ramp.bottomZ))
    if not descending and int(ramp.lower) == level:
      return TileRef(
        level: int8(ramp.upper), x: uint8(ramp.topX), z: uint8(ramp.topZ))
  TileRef(level: int8(level), x: 0, z: 0)

proc decideHero(game: Game, slot: int32) =
  ## One hero's whole mind, in priority order. This is the proc the scripting
  ## VM will eventually replace; nothing below it knows the difference.
  let actor = game.world.actors[slot]
  if actor.busy:
    return
  let level = int(actor.home.level)

  # The cleric patches the party up before doing anything else. Without this
  # the run is pure attrition and the party dies on the second floor with no
  # way to recover between fights.
  if actor.heroClass == ClericClass and
      actor.cooldowns[int(HealingBloom)] == 0 and
      actor.mana >= Abilities[HealingBloom].manaCost:
    var
      worst = -1'i32
      worstFraction = 70'i32
    for other in 0 ..< PartySize:
      let mate = game.world.actors[other]
      if not mate.alive or mate.home.level != actor.home.level:
        continue
      if tileDistance(actor.home, mate.home) >
          int32(Abilities[HealingBloom].rangeTiles):
        continue
      let fraction = int32(mate.hp) * 100 div int32(mate.maxHp)
      if fraction < worstFraction:
        worstFraction = fraction
        worst = int32(other)
    if worst >= 0:
      game.world.actors[slot].mana -= Abilities[HealingBloom].manaCost
      game.beginAbility(slot, HealingBloom, game.world.actors[worst].id)
      return

  # Fight whatever is in reach, and if the floor still holds monsters that
  # are further off, go and find them. Without the second half the party
  # arrives at the stairs, sees nothing within aggro range, and stands there
  # forever while the level it is supposed to clear waits across the map.
  #
  # Distant targets are chosen relative to the party's anchor rather than to
  # each hero, so the four of them converge on the same monster instead of
  # fanning out across the floor and being killed one at a time.
  var enemy = game.nearestEnemy(slot, HeroAggroTiles)
  if enemy < 0 and game.world.phase == DescendingPhase:
    let anchor = game.partyAnchor()
    enemy =
      if anchor >= 0: game.nearestEnemy(anchor, int32(GridTiles * 2))
      else: game.nearestEnemy(slot, int32(GridTiles * 2))
  # On the way out the party fights only what stands in its way. Hunting
  # across the floor while the dungeon refills behind them is how a run turns
  # into a treadmill they can never step off.
  if enemy >= 0:
    let target = game.world.actors[enemy]
    if inMelee(actor.home, target.home):
      game.world.clearPath(slot)
      game.world.actors[slot].facing = facingToward(actor.home, target.home)
      let ability =
        if actor.heroClass == FighterClass and
            actor.cooldowns[int(MoltenFist)] == 0: MoltenFist
        elif actor.heroClass == WizardClass and
            actor.cooldowns[int(MeteorStrike)] == 0 and actor.mana >= 12:
          MeteorStrike
        elif actor.heroClass == RogueClass and
            actor.cooldowns[int(VenomDagger)] == 0: VenomDagger
        elif actor.heroClass == ClericClass:
          SolarHammer
        else: FirebrandSword
      if ability == MeteorStrike:
        game.world.actors[slot].mana -= 12
      game.beginAbility(slot, ability, target.id)
      return
    discard game.world.stepToward(slot, target.home)
    return

  # Nothing hostile nearby: pick up anything lying around.
  let lootIndex = game.nearestLoot(slot)
  if lootIndex >= 0:
    let item = game.world.items[lootIndex]
    if tileDistance(actor.home, item.tile) <= LootPickupRange:
      game.world.clearPath(slot)
      game.beginAbility(slot, ChainAxe, item.id)
    else:
      discard game.world.stepToward(slot, item.tile)
    return

  # Floor is clear: take the stairs.
  if game.world.phase == DescendingPhase:
    if level >= LevelCount - 1:
      return
    if game.monstersOn(level) == 0:
      discard game.world.stepToward(
        slot, game.rampTileFor(level, true))
  else:
    if level <= 0:
      # Out, but not done: walk clear of the stairhead and wait at the
      # entrance. A hero who simply stops on arrival stands on the one tile
      # the rest of the party has to come up through, and strands them.
      if not (actor.home == game.dungeon.entrance):
        discard game.world.stepToward(slot, game.dungeon.entrance)
      return
    discard game.world.stepToward(slot, game.rampTileFor(level, false))

proc objectiveTile*(game: Game, slot: int32): TileRef =
  ## Returns the strategic destination for one idle hero.
  let
    actor = game.world.actors[slot]
    level = int(actor.home.level)
  if game.world.phase == DescendingPhase:
    if game.monstersOn(level) > 0:
      return game.nearestMonsterHome(slot)
    if level >= LevelCount - 1:
      return game.dungeon.vault
    game.rampTileFor(level, true)
  elif level <= 0:
    game.dungeon.entrance
  else:
    game.rampTileFor(level, false)

proc applyHeroAction*(
    game: Game,
    slot: int32,
    action: ReplayAction
): bool =
  ## Applies one high-level hero command through native pathfinding and combat.
  if slot < 0 or slot >= game.world.actors.len:
    return false
  let actor = game.world.actors[slot]
  if not actor.alive or actor.kind != HeroActor or actor.busy or
      actor.id != action.heroId:
    return false
  defer:
    if result:
      game.metrics.command(int(slot), game.world.tick)
  case action.kind
  of ActionWalkTo:
    if not action.offset.validTileOffset:
      return false
    if action.first < 0 or action.first >= LevelCount or
        action.second < 0 or action.second >= GridTiles or
        action.third < 0 or action.third >= GridTiles:
      return false
    let tile = TileRef(
      level: int8(action.first),
      x: uint8(action.second),
      z: uint8(action.third)
    )
    if not tile.walkable:
      return false
    game.world.stepToward(slot, tile, action.offset)
  of ActionAttackTarget:
    let targetSlot = game.world.actorSlot(action.first)
    if targetSlot < 0:
      return false
    let target = game.world.actors[targetSlot]
    if not target.alive or target.kind != MonsterActor or
        target.home.level != actor.home.level:
      return false
    if not game.world.actorCanSee(slot, targetSlot):
      return false
    if not inMelee(actor.home, target.home):
      return game.world.stepToward(slot, target.home)
    game.world.clearPath(slot)
    game.world.actors[slot].facing = facingToward(actor.home, target.home)
    let ability =
      if actor.heroClass == FighterClass and
          actor.cooldowns[int(MoltenFist)] == 0:
        MoltenFist
      elif actor.heroClass == WizardClass and
          actor.cooldowns[int(MeteorStrike)] == 0 and actor.mana >= 12:
        MeteorStrike
      elif actor.heroClass == RogueClass and
          actor.cooldowns[int(VenomDagger)] == 0:
        VenomDagger
      elif actor.heroClass == ClericClass:
        SolarHammer
      else:
        FirebrandSword
    if ability == MeteorStrike:
      game.world.actors[slot].mana -= 12
    game.beginAbility(slot, ability, target.id)
    true
  of ActionPickupTarget:
    let itemIndex = game.world.itemIndex(action.first)
    if itemIndex < 0 or game.world.items[itemIndex].carrier != 0:
      return false
    let item = game.world.items[itemIndex]
    if item.tile.level != actor.home.level:
      return false
    if not game.world.visible(slot, item.tile):
      return false
    if item.kind.lootUsesSlot:
      if actor.freeInventorySlot() < 0:
        return false
    if tileDistance(actor.home, item.tile) > LootPickupRange:
      return game.world.stepToward(slot, item.tile)
    game.world.clearPath(slot)
    game.beginAbility(slot, ChainAxe, item.id)
    true
  of ActionUseItem:
    if action.first < 0 or action.first >= InventorySlots:
      return false
    let itemId = actor.inventory[action.first]
    let itemIndex = game.world.itemIndex(itemId)
    if itemIndex < 0:
      return false
    let
      kind = game.world.items[itemIndex].kind
      ability = LootAbilities[kind]
    if ability == NoAbility or actor.cooldowns[int(ability)] != 0:
      return false
    if kind == ManaPotionLoot and actor.maxMana <= 0:
      return false
    let spec = Abilities[ability]
    var targetId = actor.id
    if spec.damage > 0:
      let prey = game.nearestEnemy(
        slot,
        max(int32(spec.rangeTiles), HeroAggroTiles)
      )
      if prey < 0:
        return false
      if not game.world.actorCanSee(slot, prey) or
          tileDistance(
            actor.home,
            game.world.actors[prey].home
          ) > int32(spec.rangeTiles):
        return game.world.stepToward(slot, game.world.actors[prey].home)
      targetId = game.world.actors[prey].id
    game.beginAbility(slot, ability, targetId)
    if LootConsumable[kind]:
      game.world.actors[slot].carriedWeight -=
        game.world.items[itemIndex].weight
      game.world.actors[slot].inventory[action.first] = 0
      game.world.deleteItem(itemIndex)
      game.world.actors[slot].refreshSpeed()
    true
  of ActionDropItem:
    if action.first < 0 or action.first >= InventorySlots:
      return false
    let itemId = actor.inventory[action.first]
    let itemIndex = game.world.itemIndex(itemId)
    if itemIndex < 0:
      return false
    game.world.items[itemIndex].carrier = 0
    game.world.items[itemIndex].tile = actor.home
    game.world.actors[slot].carriedWeight -=
      game.world.items[itemIndex].weight
    game.world.actors[slot].inventory[action.first] = 0
    game.world.actors[slot].refreshSpeed()
    true
  of ActionHealTarget:
    if actor.heroClass != ClericClass or
        actor.cooldowns[int(HealingBloom)] != 0 or
        actor.mana < Abilities[HealingBloom].manaCost:
      return false
    let targetSlot = game.world.actorSlot(action.first)
    if targetSlot < 0 or targetSlot >= PartySize:
      return false
    let target = game.world.actors[targetSlot]
    if not target.alive or target.home.level != actor.home.level or
        target.hp >= target.maxHp or
        tileDistance(actor.home, target.home) >
          int32(Abilities[HealingBloom].rangeTiles):
      return false
    game.world.actors[slot].mana -= Abilities[HealingBloom].manaCost
    game.beginAbility(slot, HealingBloom, target.id)
    true
  else:
    false


## Monster behaviour

proc decideMonster(game: Game, slot: int32) =
  let actor = game.world.actors[slot]
  if actor.busy:
    return
  let
    sight = SpeciesSight[actor.species]
    prey = game.nearestEnemy(slot, sight)
  if prey < 0:
    actor.state = GuardingState
    game.world.clearPath(slot)
    return
  let target = game.world.actors[prey]
  if inMelee(actor.home, target.home):
    actor.state = FightingState
    game.world.clearPath(slot)
    actor.facing = facingToward(actor.home, target.home)
    game.beginAbility(slot, FirebrandSword, target.id)
  else:
    actor.state = ChasingState
    discard game.world.stepToward(slot, target.home)


## The tick

proc tickWorld*(
    game: Game,
    onHeroDecision: proc(game: Game, slot: int32) {.closure.}
) {.measure.} =
  ## One authoritative simulation step.
  if game.world.phase in {EscapedPhase, WipedPhase}:
    return
  inc game.world.tick
  profileBlock "vision":
    game.world.rebuildVision()

  # Decisions run every tick, in a rotating order so no slot is permanently
  # first.
  let thinking = game.world.tick mod DecisionTicks == 0
  if thinking:
    profileBlock "decisions":
      for offset in 0 ..< game.world.actors.len:
        let slot = int32(
          (int(game.world.turnStart) + offset) mod game.world.actors.len)
        if not game.world.actors[slot].alive:
          continue
        if game.world.actors[slot].kind == HeroActor:
          onHeroDecision(game, slot)
        else:
          game.decideMonster(slot)
    game.world.turnStart =
      (game.world.turnStart + 1) mod int32(max(game.world.actors.len, 1))

  profileBlock "actions":
    for slot in 0 ..< game.world.actors.len:
      if not game.world.actors[slot].alive:
        continue
      game.advanceAction(int32(slot))

  profileBlock "movement":
    for slot in 0 ..< game.world.actors.len:
      if game.world.actors[slot].id == 0:
        continue
      if game.world.actors[slot].alive and not game.world.actors[slot].busy:
        discard game.world.advancePath(int32(slot))
    for i in 0 ..< game.world.actors.len:
      if not game.world.actors[i].alive:
        continue
      for j in i + 1 ..< game.world.actors.len:
        if not game.world.actors[j].alive:
          continue
        if game.world.actors[i].home.level != game.world.actors[j].home.level:
          continue
        ctaWalkLayer = int(game.world.actors[i].home.level)
        ctaWalkDestLayer = ctaWalkLayer
        separatePair(
          game.world.actors[i].body,
          game.world.actors[j].body,
          ctaTilesWalkable
        )
    for slot in 0 ..< game.world.actors.len:
      if game.world.actors[slot].alive:
        ctaWalkDestLayer = int(game.world.actors[slot].home.level)
        game.world.applyActorBody(int32(slot))
    game.world.rebuildClaims()
  for slot in 0 ..< game.world.actors.len:
    if game.world.actors[slot].id == 0:
      continue
    for ability in 0 ..< AbilityCount:
      if game.world.actors[slot].cooldowns[ability] > 0:
        dec game.world.actors[slot].cooldowns[ability]
    if game.world.actors[slot].sinceHitTicks < 30_000:
      inc game.world.actors[slot].sinceHitTicks
    if game.world.actors[slot].hasteTicks > 0:
      dec game.world.actors[slot].hasteTicks
      if game.world.actors[slot].hasteTicks == 0:
        game.world.actors[slot].refreshSpeed()
    if game.world.actors[slot].guardTicks > 0:
      dec game.world.actors[slot].guardTicks
    # Wounds close slowly once a fight is over, and mana comes back with
    # them, so the party can afford the walk back up.
    if game.world.actors[slot].kind == HeroActor and
        game.world.actors[slot].alive and
        game.world.actors[slot].sinceHitTicks >= RegenerationIdleTicks and
        game.world.tick mod RegenerationPeriodTicks == 0:
      let actor = game.world.actors[slot]
      actor.hp = min(
        actor.hp +
          int16(max(
            int32(actor.maxHp) * RegenerationPercent div 100,
            1
          )),
        actor.maxHp)
      actor.mana = min(
        actor.mana +
          int16(max(int32(actor.maxMana) * RegenerationPercent div 100, 1)),
        actor.maxMana)

  # Carried treasure travels with its bearer, so the renderer and the score
  # both read the same position.
  for index in 0 ..< game.world.items.len:
    let carrier = game.world.items[index].carrier
    if carrier == 0:
      continue
    let slot = game.world.actorSlot(carrier)
    if slot >= 0:
      game.world.items[index].tile = game.world.actors[slot].home

  let level = game.partyLevel()
  if level > game.world.deepest:
    game.world.deepest = level
    game.log.add "the party reaches " & Themes[level].name

  # Turn around at the bottom.
  if game.world.phase == DescendingPhase and int(level) >= LevelCount - 1 and
      game.monstersOn(LevelCount - 1) == 0:
    game.world.phase = ReturningPhase
    game.log.add "the vault is cleared; the party turns back"

  # While the party climbs out, the dungeon fills in behind them.
  if game.world.phase == ReturningPhase:
    inc game.world.respawnTicks
    if game.world.respawnTicks >= RespawnIntervalTicks:
      game.world.respawnTicks = 0
      # Reinforcements appear on the floors *above* the party, so the way out
      # is contested. Two things this must not do: spawn onto the party's own
      # floor, which piles monsters onto them where they stand, and keep
      # spawning once they are nearly out, which traps the last hero on the
      # first floor forever with the exit in sight.
      if level > 1:
        var rng = game.world.rng
        let target = rng.between(1, level - 1)
        if game.spawnMonster(int(target), rng):
          game.log.add "something stirs on " & Themes[target].name &
            " behind the party"
        game.world.rng = rng

  # Endings.
  if game.world.partyAlive() == 0:
    game.world.phase = WipedPhase
    game.log.add "the party is lost"
  elif game.world.phase == ReturningPhase:
    # Each hero banks what they personally hauled out, the moment they reach
    # the surface. Ending the run on the first one home would strand whatever
    # the stragglers are still carrying.
    var
      living = 0
      surfaced = 0
    for slot in 0 ..< PartySize:
      if not game.world.actors[slot].alive:
        continue
      inc living
      if int(game.world.actors[slot].home.level) != 0:
        continue
      inc surfaced
      game.world.returned[slot] = true
      if game.world.actors[slot].carriedValue > 0:
        game.world.banked += game.world.actors[slot].carriedValue
        game.world.bankedGold[slot] += game.world.actors[slot].carriedValue
        game.log.add HeroClass(game.world.actors[slot].class).`$` &
          " banks " & $game.world.actors[slot].carriedValue & " gold"
        game.world.actors[slot].carriedValue = 0
    if living > 0 and surfaced == living:
      game.world.phase = EscapedPhase
      game.log.add "the party escapes with " & $game.world.banked & " gold"

proc partyGold*(game: Game): int32 =
  ## Sum of gold still carried by living heroes. Each hero has a private purse.
  for slot in 0 ..< PartySize:
    if game.world.actors[slot].alive:
      result += game.world.actors[slot].carriedValue

proc stateHash*(game: Game): uint64 =
  ## The replay digest. `World` has nothing to skip.
  hashWorld(game.world)

proc scores*(world: World): seq[int] =
  ## Awards shared wins to surviving returners with the most banked gold.
  result.setLen(PartySize)
  var highest = -1'i32
  for slot in 0 ..< PartySize:
    if world.actors[slot].alive and world.returned[slot]:
      highest = max(highest, world.bankedGold[slot])
  if highest < 0:
    return
  for slot in 0 ..< PartySize:
    if world.actors[slot].alive and world.returned[slot] and
      world.bankedGold[slot] == highest:
        result[slot] = 1
