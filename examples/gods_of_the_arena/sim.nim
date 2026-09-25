## Gods of the Arena simulation: objects, vision, combat, and the tick.
##
## Planar unit motion uses Q16.16 tile-space bodies. Height, combat ranges,
## and replay integers stay on `WorldPoint`. This module must not import
## anything that returns a float. Graphics may sample `surfaceHeight` and
## must not write simulation state.
##
## BASIC decisions arrive through `onHeroTurn`. This module owns the
## VM type on `Game` but never runs a program.

import
  std/algorithm,
  bassy, fixxy,
  polyworld/[bodies, hashes, metrics, noises, pathing, profiles, rngs, tapes,
    visions, mailboxes],
  content, events, motions,
  maps,
  replays

export events

## Deterministic animation slots shared by every backend.

const
  runClip* = 0
  idleClip* = 1
  deathClip* = 2
  victoryClip* = 3
  attackClips* = [4, 5]
  heroRunClip* = 0
  heroIdleClip* = 1
  heroDeathClip* = 2
  heroAttackClips* = [3, 4]

var
  lanePathPoints*: array[3, seq[PathPoint]]
  lanePathTiles: array[3, seq[PathTile]]
  laneWorldLayers: array[3, seq[int32]]
  visionBlockers: seq[int16]
  visionSources: seq[VisionSource]
  visionSkipNow: seq[int32]
  heroPathPoints: seq[PathPoint]
  heroPathTiles: seq[PathTile]
  gotaWalkLayer: int
  gotaWalkDestLayer: int
  gotaWalkOrigin: FixedVec2

## Simulation

type
  Team* = enum RedTeam, BlueTeam
  MatchPhase* = enum Playing, Drafting
  FootmanState* = enum Marching, Fighting, Dying
  CampState* = enum RestingCamp, FightingCamp, ReturningCamp, EmptyCamp
  TowerTier* = enum OuterTower, InnerTower, GateTower
  BuildingKind* = enum TowerBuilding, BarracksBuilding
  WorldPoint* = object
    x*, y*, z*: int32
  Heading* = object
    x*, z*: int32
  Camp* = object
    center*: WorldPoint
    tier*, count*, appearance*: int
    state*: CampState
    targetId*, respawnTick*, lastSeenTick*: int32
    started*: bool

  HeroVm* = ref object
    output*: PrintProc
    runtime*: Runtime
    limits*: Limits
    ready*: bool
    failed*: bool
    lastError*: string
    decisions*: int
    lastWork*, lastInstructions*: int64

  Footman* = object
    id*: int32
    kind*: CreepKind
    camp*: int
      ## Zero for lane creeps, otherwise the one-based camp index.
    campTier*, appearance*: int
    leader*: bool
    home*: WorldPoint
    team*: Team
      ## For neutrals this is only the mirrored navigation orientation.
    lane*: int
    position*: WorldPoint
    facing*: Heading
    velocity*: Heading
    body*: Body
    hp*: int32
    state*: FootmanState
    waypointIndex*: int
    movePath*: seq[PathTile]
    movePathIndex*: int
    moveGoal*: WorldPoint
    moveRevision*: int32
    nextPathTick*: int32
    stuckTicks*: int32
    targetId*: int32
    targetHeroId*: int32
    targetBuildingId*: int32
    attackingFort*: bool
    swingClip*: int
    swingTicks*: int32
    damageLanded*: bool
    animClip*: int
    animTicks*: int32
    deathTicks*: int32
    surfaceHint*: int32
    navLayer*: int32
    controls*: array[ControlEffect, ControlTimer]

  Hero* = ref object
    id*: int32
    team*: Team
    slot*: int
    lane*: int
    class*: HeroClass
    drafted*: bool
    position*: WorldPoint
    spawnPosition*: WorldPoint
    facing*: Heading
    velocity*: Heading
    body*: Body
    hp*: int32
    maxHp*: int32
    mana*: int32
    maxMana*: int32
    level*: int
    xp*: int
    totalXp*: int
    creepXpRemainder*: int
      ## Carries fractional shared creep XP between deaths.
    gold*: int
    deaths*: int32
    state*: FootmanState
    waypointIndex*: int
    targetFootmanId*: int32
    targetHeroId*: int32
    targetBuildingId*: int32
    attackingFort*: bool
    swingClip*: int
    swingTicks*: int32
    damageLanded*: bool
    attacksLanded*: int32
    animClip*: int
    animTicks*: int32
    deathTicks*: int32
    surfaceHint*: int32
    navLayer*: int32
    attackObjectId*: int32
    attackMoving*: bool
    movePath*: seq[WorldPoint]
    movePathLayers*: seq[int32]
    movePathIndex*: int
    moveTileX*: int
    moveTileY*: int
    moveOffset*: FixedVec2
    hasMoveTarget*: bool
    moveRevision*: int32
    stuckTicks*: int32
    inventory*: array[InventorySlots, Item]
    itemCounts*: array[InventorySlots, int32]
    abilityLevels*: array[HeroAbilitySlot, int32]
    cooldowns*: array[HeroAbilitySlot, int32]
    charges*: array[HeroAbilitySlot, int32]
    recharges*: array[HeroAbilitySlot, int32]
    spellsReady*: bool
    potionCooldownEnds*: array[RecoveryKind, int32]
    recoveryItems*: array[RecoveryKind, Item]
    recoveryStarted*, recoveryApplied*: array[RecoveryKind, int32]
    portalEnds*, portalCooldownEnds*, portalTowerId*: int32
    portalDestination*: WorldPoint
    controls*: array[ControlEffect, ControlTimer]
    lastActionError*: ActionError

  Fort* = object
    id*: int32
    team*: Team
    center*: WorldPoint
    hp*: int32

  Building* = object
    kind*: BuildingKind
    guardsGod*: bool
    spawn*: WorldPoint
    footprint*: seq[PathTile]
    occupied*: bool
    knownAlive*: array[Team, bool]
    id*: int32
    team*: Team
    lane*: int
    tier*: TowerTier
    position*: WorldPoint
    facing*: Heading
    hp*: int32
    maxHp*: int32
    targetId*: int32
    attackTicks*: int32

  WorldObject* = object
    id*: int32
    kind*: int32
    class*: int32
    team*: Team
    position*: WorldPoint
    hp*: int32
    maxHp*: int32
    alive*: bool
    level*, mana*: int32
    inventory*: array[InventorySlots, Item]
    itemCounts*: array[InventorySlots, int32]
    facing*, velocity*: Heading
    targetId*: int32
    controlTicks*: array[ControlEffect, int32]
    camp*: int
    leader*, returning*: bool

  NavTile* = object
    layer*: int
    x*: int
    z*: int

  SpellCast* = object
    ability*: Ability
    level*: int32
    heroId*: int32
    targetId*: int32
    origin*: WorldPoint
    position*: WorldPoint
    direction*: Heading
    started*: int32
    impact*: int32
    ends*: int32
    resolved*: bool

  TowerShot* = object
    sourceId*, targetId*, damage*: int32
    team*: Team
    previous*, position*: WorldPoint
    started*, impact*: int32

  HitKind = enum UnitHit, StructureHit, GodHit
  HitKey = tuple[kind, class, x, y, z, spawnX, spawnY, spawnZ: int32]
  CombatHit = object
    kind: HitKind
    target, source, damage: int32
    cause: EventCause
    detail: int32
    priority: uint32
    sourceKey: HitKey
  DeathReward = object
    target, source: int32
  CollisionUnit = object
    body: Body
    index: int
    layer: int32
    team: Team
    hero, fixed: bool

  World* = ref object
    when defined(replayEvents):
      events*: seq[GameEvent]
      eventTick: int32
    heroSpawns*: array[2, WorldPoint]
    casts*: seq[SpellCast]
    towerShots*: seq[TowerShot]
    stats*: CombatStats
    ## One match. A ref so `a = b` aliases and a second world is `clone()`.
    footmen*: seq[Footman]
    camps*: seq[Camp]
    heroes*: seq[Hero]
    forts*: array[2, Fort]
    buildings*: seq[Building]
    occupancy*: seq[seq[int16]]
    navigationRevision*: int32
    spawnIntervalTicks*: int32
    spawnTimerTicks*: int32
    gameOver*: bool
    draw*: bool
    winner*: Team
    collectingHits, resolvingHits: bool
    hits: seq[CombatHit]
    rewards: seq[DeathReward]
    rewardAlive: seq[bool]
    rng*: Rng
    matchSeed*: int32
    nextFootmanId*: int32
    tick*: int32
    phase*: MatchPhase
    drafting*: bool
      ## Preserves the initial setup when capturing a replay after drafting.
    draftOrder*: seq[int]
    draftTurn*: int
    draftTicks*: int32
    draftTurnTicks*: int32
    heroTurnTicks*: int32
    heroTurnStart*: int
    teamHeroKills*: array[2, int]
    teamHeroDeaths*: array[2, int]
    teamVisible*: array[2, seq[uint8]]
    teamExplored*: array[2, seq[uint8]]
    visionCache: array[2, VisionCache]
    visionSkipKeys: seq[int32]
    scriptObjects: seq[WorldObject]
    scriptObjectCount: int
    scriptObjectsHeroId: int32
    scriptObjectsTick: int32
    observationsFrozen: bool
    observedObjects: seq[WorldObject]
    observedSpells: array[Team, seq[SpellCast]]
  Game* = ref object
    ## One match session. World is the hashable sim; everything else is
    ## tape, map, and agents.
    world*: World
    metrics*: MatchMetrics
    history*: MetricHistory
    map*: MapData
    recorder*: ReplayRecorder
    replayData*: ReplayData
    replayPlayer*: ReplayPlayer
    hashCheck*: ReplayHashCheck
    historyPlayback*: bool
    replayMode*: bool
    recordingError*: string
    heroVms*: seq[HeroVm]
    inboxes*: seq[Mailbox]
    nextFootmen: seq[Footman]
    nextHeroes: seq[Hero]
    collisionUnits: seq[CollisionUnit]
    collisionOrder: seq[int]
    collisionOffsets: seq[FixedVec2]

var
  navigationWorld: World
  gotaWalkTeam: Team

const
  WorldScale* = 60_000'i32
  FirstTowerId = 10'i32
  FirstBarracksId = 40'i32
  WaypointRadius* = 6 * WorldScale
  WaypointSpacing = 10 * WorldScale
  PathPointRadius = WorldScale div 3
  ChasePathTicks = 6'i32
  FailedPathTicks = TickRate
  TowerHitPoints*: array[TowerTier, int32] = [1_900'i32, 2_600, 3_900]
  TowerDamages*: array[TowerTier, int32] = [36'i32, 48, 60]
  BarracksHitPoints* = 950'i32
  TowerAttackRanges*: array[TowerTier, int32] = [
    540_000'i32,
    570_000,
    600_000
  ]
  TowerAttackTicks* = TickRate
  TowerShotStep* = 18 * WorldScale div TickRate
  TowerImpactTicks* = TickRate div 2
  TowerSiegeRange* = 105_000'i32

proc config*(game: Game): GotaConfig =
  ## Reads the match configuration owned by the live or loaded replay.
  if game.recorder != nil:
    game.recorder.data.config
  else:
    game.replayData.config

proc worldPoint(point: PathPoint): WorldPoint =
  ## Converts one exact 1/32-tile path point into integer world units.
  const PathUnit = WorldScale div PathUnitsPerTile
  WorldPoint(
    x: point.x * PathUnit,
    y: point.y * PathUnit,
    z: point.z * PathUnit
  )

proc heading*(x, z: int32): Heading =
  ## Creates an integer heading from a non-normalized planar direction.
  Heading(x: x, z: z)

proc `-`(first, second: WorldPoint): WorldPoint =
  ## Subtracts two authoritative world positions.
  WorldPoint(
    x: first.x - second.x,
    y: first.y - second.y,
    z: first.z - second.z
  )

proc `+`(first, second: WorldPoint): WorldPoint =
  ## Adds two authoritative world offsets.
  WorldPoint(
    x: first.x + second.x,
    y: first.y + second.y,
    z: first.z + second.z
  )

proc distanceSquared(first, second: WorldPoint): int64 =
  ## Returns squared planar distance without floating-point arithmetic.
  let
    x = int64(first.x) - int64(second.x)
    z = int64(first.z) - int64(second.z)
  x * x + z * z

proc within*(first, second: WorldPoint, distance: int32): bool =
  ## Tests a planar range using squared authoritative integer units.
  distanceSquared(first, second) <= int64(distance) * int64(distance)

proc scaledPlanar(direction: WorldPoint, distance: int32): WorldPoint =
  ## Scales an integer direction to an exact signed planar distance.
  let length = integerSqrt(
    int64(direction.x) * int64(direction.x) +
    int64(direction.z) * int64(direction.z)
  )
  if length == 0:
    return
  WorldPoint(
    x: int32(roundDivision(int64(direction.x) * distance, length)),
    z: int32(roundDivision(int64(direction.z) * distance, length))
  )

proc targetBefore(position: WorldPoint, id: int32,
    previous: WorldPoint, previousId: int32, team: Team): bool =
  ## Breaks equal-distance target ties by team-relative position and identity.
  if previousId == 0:
    return true
  let direction = if team == RedTeam: 1'i32 else: -1'i32
  (direction * position.z, direction * position.x, position.y, id) <
    (direction * previous.z, direction * previous.x, previous.y, previousId)

proc floorWorldTile(value: int32): int =
  ## Floors a signed fixed-point coordinate to its whole world tile.
  if value >= 0:
    int(value div WorldScale)
  else:
    -int(((-int64(value)) + int64(WorldScale) - 1) div
      int64(WorldScale))

proc floorWorldTile(value: int32, team: Team): int =
  ## Resolves exact cell-edge ties in the unit's rotated coordinate frame.
  floorWorldTile(value) - int(team == BlueTeam and value mod WorldScale == 0)

proc fixedSurfaceHeight(position: WorldPoint, team = RedTeam): int32
proc fixedSurfaceHeightNear(
    position: WorldPoint,
    referenceY: int32,
    team = RedTeam
): int32

proc initTowers(world: World, map: MapData) =
  ## Creates towers at the courts selected by this map's layout.
  for lane in 0 .. 2:
    for team in Team:
      for tier in TowerTier:
        let
          hitPoints = TowerHitPoints[tier]
          site = map.layout.towers[lane][team.ord][tier.ord]
          facing = heading(
            site.facing.x - site.position.x,
            site.facing.z - site.position.z
          )
        var position = worldPoint(site.position)
        position.y = fixedSurfaceHeight(position, team)
        world.buildings.add Building(
          id: FirstTowerId + world.buildings.len.int32,
          team: team,
          lane: lane,
          tier: tier,
          position: position,
          facing: facing,
          hp: hitPoints,
          maxHp: hitPoints
        )

const
  FootmanHp* = 60'i32
  FootmanDamage* = 12'i32
  FootmanMovePerTick* = 5_500'i32
  FootmanBodyRadius = 0.22'fx
  HeroBodyRadius = 0.28'fx
  BodyTurnRate = 0.35'fx
  FootmanSightRadius* = 5 * WorldScale
  FootmanTowerSightRadius = 7 * WorldScale
  FootmanMeleeRange* = 54_000'i32
  FootmanRangedRange* = 4 * WorldScale
  CreepXpRange* = 6 * WorldScale
  CreepNearbyXp* = 15
  CreepLastHitPercent = 15
  CreepXpScale = 6000
    ## Keeps percentage splits exact for teams of up to five heroes.
  FortRange = 255_000'i32
  FortSightRadius = 14'i32
  HeroMeleeIdleRange* = 150_000'i32
    ## Standing melee heroes auto-attack enemies this close.
  HeroMeleeAttackMoveRange* = 480_000'i32
    ## Attack-move melee chase radius, much larger than idle aggro.
  HeroLanes = [0, 0, 1, 2, 2]
  HeroRespawnTicks = 8 * TickRate
  HeroRespawnGrowthTicks = 5 * TickRate
  HeroMaxRespawnTicks = 60 * TickRate
  HeroBuybackGold = 100'i32
  HeroMaxLevel* = 20
  FootmanGoldReward = 15
  HeroXpReward = 150
  HeroGoldReward = 100
  TowerXpReward = 200
  TowerGoldReward = 75
  GodXpReward* = 1000
  DecisionTicks = 1'i32
    ## Ticks between hero VM decisions. One decision per simulation tick.
  FortObjectKind = 1'i32
  HeroObjectKind = 2'i32
  FootmanObjectKind = 3'i32
  TowerObjectKind = 4'i32
  BarracksObjectKind = 5'i32
  NeutralObjectKind* = 6'i32
  NeutralAggroTiles* = 2'i32
  NeutralLeash* = 12 * WorldScale
  CampRespawnRadius* = 10 * WorldScale
  CampRespawnTicks* = 60 * TickRate
  NeutralHealth* = [100'i32, 180, 300]
  NeutralDamage* = [8'i32, 14, 20]
  NeutralXp* = [20, 35, 50]
  NeutralGold* = [10, 20, 30]
  RedFortId = 1'i32
  BlueFortId = 2'i32
  FirstHeroId* = 100'i32
  FirstFootmanId = 1000'i32
  UnitCap = 120 * CreepsPerBarracks
  CorpseLingerTicks = 60'i32
  FootmanDeathTicks* = 24'i32
  HeroDeathTicks* = 24'i32
  FortHp* = 400'i32

proc faction*(unit: Footman): int32 =
  ## Returns a playable team or the independent neutral faction, two.
  if unit.camp > 0:
    2
  else:
    unit.team.ord.int32

proc faction*(value: WorldObject): int32 =
  ## Keeps neutral observations separate from their navigation orientation.
  if value.kind == NeutralObjectKind:
    2
  else:
    value.team.ord.int32

proc unitMaxHp*(unit: Footman): int32 =
  ## Returns a lane creep's health or the camp tier and leader health.
  if unit.camp == 0:
    return FootmanHp
  NeutralHealth[unit.campTier - 1] * (if unit.leader: 2 else: 1)

proc unitDamage*(unit: Footman): int32 =
  ## Returns the melee damage for a lane creep or neutral camp member.
  if unit.camp == 0:
    return FootmanDamage
  NeutralDamage[unit.campTier - 1] * (if unit.leader: 3 else: 2) div 2

proc returning*(world: World, unit: Footman): bool =
  ## Returning camp members cannot be damaged or interrupted.
  unit.camp > 0 and world.camps[unit.camp - 1].state == ReturningCamp

proc hostile*(world: World, unit: Footman, team: Team,
    engageResting = false): bool =
  ## Allows deliberate camp attacks but keeps resting camps out of idle scans.
  if unit.hp <= 0 or unit.state == Dying:
    return false
  if unit.camp == 0:
    return unit.team != team
  let state = world.camps[unit.camp - 1].state
  state == FightingCamp or (engageResting and state == RestingCamp)

proc startingForts(map: MapData): array[2, Fort] =
  ## Places both gods at the selected layout's fort centers.
  for team in Team:
    result[team.ord] = Fort(
      id: (if team == RedTeam: RedFortId else: BlueFortId),
      team: team,
      hp: FortHp,
      center: worldPoint(map.layout.forts[team.ord])
    )

proc cloneHeroes(heroes: seq[Hero]): seq[Hero] =
  ## Copies each hero so two worlds never share a path seq.
  result.setLen(heroes.len)
  for i, hero in heroes:
    result[i] = Hero()
    result[i][] = hero[]

proc clone*(w: World): World =
  ## Deep copy. Heroes are refs and must be cloned one by one.
  result = World()
  result[] = w[]
  result.stats = w.stats.clone()
  result.heroes = cloneHeroes(w.heroes)
  when defined(replayEvents):
    result.events = @[]

proc restore*(w: World, snapshot: World) =
  ## Overwrites in place, keeping the caller's ref identity.
  w[] = snapshot[]
  w.stats = snapshot.stats.clone()
  w.heroes = cloneHeroes(snapshot.heroes)
  when defined(replayEvents):
    w.events = @[]
    w.eventTick = w.tick
  navigationWorld = w

proc buildSightTerrain(): tuple[
    terrainHeights,
    blockerHeights: seq[int16]
] =
  ## Builds one integer occlusion grid from terrain and forest tiles.
  let cellCount = mapTiles() * mapTiles()
  result.terrainHeights = newSeq[int16](cellCount)
  result.blockerHeights = newSeq[int16](cellCount)
  for value in result.terrainHeights.mitems:
    value = int16.low
  for layer in layers:
    if layer.water:
      continue
    for z in 0 ..< layer.depth:
      for x in 0 ..< layer.width:
        let
          tile = layer.tiles[z * layer.width + x]
          mapX = layer.originX + x - mapOrigin()
          mapZ = layer.originZ + z - mapOrigin()
        if not tile.exists or mapX < 0 or mapX >= mapTiles() or
            mapZ < 0 or mapZ >= mapTiles():
          continue
        let
          index = mapZ * mapTiles() + mapX
          mean = int16(
            (int32(tile.tops[0]) + int32(tile.tops[1]) +
              int32(tile.tops[2]) + int32(tile.tops[3])) div 4
          )
        result.terrainHeights[index] = max(
          result.terrainHeights[index],
          mean
        )
  let ground = layers[GroundLayer]
  for z in 0 ..< ground.depth:
    for x in 0 ..< ground.width:
      let index = z * ground.width + x
      if ground.tiles[index].kind == TreeTile or
        ground.tiles[index].kind == ArenaRockKind:
          result.blockerHeights[
            z * ground.width + x
          ] = 24
  for value in result.terrainHeights.mitems:
    if value == int16.low:
      value = 0

var sightTerrain: tuple[terrainHeights, blockerHeights: seq[int16]]

proc sightBounds(position: WorldPoint): array[4, int32] =
  ## Includes both cells at exact borders so half turns preserve coverage.
  let
    x = int32(floorWorldTile(position.x) + mapTiles() div 2)
    z = int32(floorWorldTile(position.z) + mapTiles() div 2)
  [x - int32(position.x mod WorldScale == 0),
    z - int32(position.z mod WorldScale == 0), x, z]

iterator sightTiles(position: WorldPoint): tuple[x, z: int32] =
  ## Yields each in-bounds visibility cell touched by one world position.
  let bounds = sightBounds(position)
  for z in max(0'i32, bounds[1]) .. min(mapTiles().int32 - 1, bounds[3]):
    for x in max(0'i32, bounds[0]) .. min(mapTiles().int32 - 1, bounds[2]):
      yield (x, z)

proc addVisionSource(position: WorldPoint, radius: int32, eyeHeight: int16) =
  ## Adds each cell touched by an observer, including exact tile boundaries.
  for tile in sightTiles(position):
    visionSources.add VisionSource(
      x: tile.x, z: tile.z, radius: radius, eyeHeight: eyeHeight
    )

proc addVisionBlocker(position: WorldPoint, height: int16) =
  ## Raises the occluder height in each cell touched by a structure's center.
  for tile in sightTiles(position):
    let index = tile.z * mapTiles() + tile.x
    visionBlockers[index] = max(visionBlockers[index], height)

proc fillVisionKeys(world: World, dest: var seq[int32]) =
  ## Records living observers and the towers or forts that occlude them.
  dest.setLen(0)
  dest.add int32(world.heroes.len)
  for i in 0 ..< world.heroes.len:
    let hero = world.heroes[i]
    dest.add hero.id
    dest.add int32(hero.team.ord)
    dest.add int32(hero.state != Dying and hero.hp > 0)
    dest.add sightBounds(hero.position)
  dest.add int32(world.footmen.len)
  for footman in world.footmen:
    if footman.camp > 0:
      continue
    dest.add footman.id
    dest.add int32(footman.team.ord)
    dest.add int32(footman.state != Dying and footman.hp > 0)
    dest.add sightBounds(footman.position)
  dest.add int32(world.buildings.len)
  for tower in world.buildings:
    dest.add tower.id
    dest.add int32(tower.team.ord)
    dest.add int32(tower.hp > 0)
    dest.add sightBounds(tower.position)
  dest.add int32(world.forts.len)
  for fort in world.forts:
    dest.add fort.id
    dest.add int32(fort.team.ord)
    dest.add int32(fort.hp > 0)
    dest.add sightBounds(fort.center)

proc rebuildVision*(world: World) {.measure.} =
  ## Rebuilds both teams' limited, terrain-occluded visibility maps.
  world.fillVisionKeys(visionSkipNow)
  if sameVisionKeys(visionSkipNow, world.visionSkipKeys):
    return
  visionBlockers.setLen(sightTerrain.blockerHeights.len)
  for i, value in sightTerrain.blockerHeights:
    visionBlockers[i] = value
  for tower in world.buildings:
    if tower.hp > 0:
      addVisionBlocker(tower.position, 28)
  for fort in world.forts:
    if fort.hp > 0:
      addVisionBlocker(fort.center, 32)
  for team in Team:
    visionSources.setLen(0)
    for i in 0 ..< world.heroes.len:
      let hero = world.heroes[i]
      if hero.team == team and hero.state != Dying and hero.hp > 0:
        addVisionSource(hero.position, 10, 14)
    for footman in world.footmen:
      if footman.camp == 0 and footman.team == team and
        footman.state != Dying and footman.hp > 0:
        addVisionSource(footman.position, FootmanSightRadius div WorldScale, 12)
    for tower in world.buildings:
      if tower.team == team and tower.hp > 0:
        let range = TowerAttackRanges[tower.tier]
        for tile in sightTiles(tower.position):
          visionSources.add VisionSource(
            x: tile.x, z: tile.z,
            radius: (range + WorldScale - 1) div WorldScale + 1,
            eyeHeight: 24, units: WorldScale, range: range,
            offsetX: tower.position.x -
              (tile.x - mapTiles().int32 div 2) * WorldScale - WorldScale div 2,
            offsetZ: tower.position.z -
              (tile.z - mapTiles().int32 div 2) * WorldScale - WorldScale div 2
          )
    for fort in world.forts:
      if fort.team == team and fort.hp > 0:
        addVisionSource(fort.center, FortSightRadius, 28)
    revealVisionCached(
      world.visionCache[team.ord],
      world.teamVisible[team.ord],
      mapTiles().int32,
      mapTiles().int32,
      sightTerrain.terrainHeights,
      visionBlockers,
      visionSources
    )
    for i, value in world.teamVisible[team.ord]:
      if value != 0:
        world.teamExplored[team.ord][i] = 255
  copyVisionKeys(world.visionSkipKeys, visionSkipNow)

proc visible*(world: World, team: Team, position: WorldPoint): bool =
  ## Returns whether a position is currently visible to one team.
  if world.teamVisible[team.ord].len != mapTiles() * mapTiles():
    return false
  for tile in sightTiles(position):
    if world.teamVisible[team.ord][tile.z * mapTiles() + tile.x] != 0:
      return true

proc enemyFort(team: Team): int =
  ## Returns the opposing fort index for a team.
  if team == RedTeam: 1 else: 0

proc footmanIndex(world: World, id: int32): int =
  ## Returns the footman slot for one id, or -1.
  if id == 0:
    return -1
  for i, footman in world.footmen:
    if footman.id == id:
      return i
  -1

proc heroIndex*(world: World, id: int32): int =
  ## Returns the hero slot for one id, or -1.
  if id == 0:
    return -1
  for i in 0 ..< world.heroes.len:
    if world.heroes[i].id == id:
      return i
  -1

proc buildingIndex*(world: World, id: int32): int =
  ## Returns the tower slot for one id, or -1.
  if id == 0:
    return -1
  for i, tower in world.buildings:
    if tower.id == id:
      return i
  -1

when defined(replayEvents):
  proc eventEntity(world: World, id: int32): EventEntity =
    ## Retains entity identity even after removal from the world.
    result = EventEntity(id: id, team: -1, class: -1, player: -1)
    var position: WorldPoint
    let hero = world.heroIndex(id)
    if hero >= 0:
      let value = world.heroes[hero]
      result.kind = HeroObjectKind
      result.team = value.team.ord.int32
      result.class = value.class.ord.int32
      result.player = hero.int32
      position = value.position
    else:
      let creep = world.footmanIndex(id)
      let building = world.buildingIndex(id)
      if creep >= 0:
        let value = world.footmen[creep]
        result.kind = if value.camp > 0: NeutralObjectKind else: FootmanObjectKind
        result.class = if value.camp > 0: value.campTier.int32 else: value.kind.ord.int32
        result.team = value.faction
        position = value.position
      elif building >= 0:
        let value = world.buildings[building]
        result.kind =
          if value.kind == TowerBuilding: TowerObjectKind
          else: BarracksObjectKind
        result.team = value.team.ord.int32
        position = value.position
      else:
        for value in world.forts:
          if id != 0 and value.id == id:
            result.kind = FortObjectKind
            result.team = value.team.ord.int32
            position = value.center
    result.x = position.x
    result.y = position.y
    result.z = position.z

  proc emit(world: World, event: GameEvent) =
    ## Appends one value record to the current tick's reusable buffer.
    var value = event
    value.tick = world.eventTick
    world.events.add value

  proc deathEvent(world: World, id: int32): int32 =
    ## Finds the lethal event that precedes this tick's kill reward.
    for i in countdown(world.events.high, 0):
      if world.events[i].kind == Death and world.events[i].target.id == id:
        return i.int32
    -1

  proc damageEvent(
      world: World,
      source, target, requested, before, after: int32,
      cause: EventCause,
      detail: int32
  ) =
    ## Records effective damage, the lethal hit, and existing assist credit.
    if requested <= 0 or after == before:
      return
    let
      actor = world.eventEntity(source)
      victim = world.eventEntity(target)
      hit = world.events.len.int32
    world.emit GameEvent(
      kind: Damage, actor: actor, target: victim, cause: cause,
      detail: detail, requested: requested,
      amount: max(before, 0) - max(after, 0),
      before: before, after: after, related: -1
    )
    if before > 0 and after <= 0:
      let death = world.events.len.int32
      world.emit GameEvent(
        kind: Death, actor: actor, target: victim, cause: cause,
        detail: detail, related: hit
      )
      if victim.kind == HeroObjectKind and world.stats != nil:
        let count = world.stats.values.len
        for slot in 0 ..< count:
          let lastHit = world.stats.hits[victim.player.int * count + slot]
          if slot != actor.player and lastHit >= 0 and
            world.tick - lastHit <= TickRate * 10 and
            world.stats.teams[slot] != victim.team:
              world.emit GameEvent(
                kind: Assist, actor: world.eventEntity(world.heroes[slot].id),
                target: victim, cause: KillReward, related: death, amount: 1
              )
      if victim.kind in [TowerObjectKind, BarracksObjectKind]:
        world.emit GameEvent(
          kind: EntityRemoved, actor: actor, target: victim,
          cause: cause, related: death
        )

  proc valueEvent(
      world: World,
      kind: EventKind,
      source, target: int32,
      cause: EventCause,
      detail: int32,
      before, after, requested: int64,
      related = -1'i32
  ) =
    ## Records a resource mutation without formatting or heap payloads.
    if before != after:
      world.emit GameEvent(
        kind: kind, actor: world.eventEntity(source),
        target: world.eventEntity(target), cause: cause, detail: detail,
        before: before, after: after, amount: after - before,
        requested: requested, related: related
      )

  proc lifecycleEvent(
      world: World,
      kind: EventKind,
      source, target: int32,
      cause: EventCause
  ) =
    ## Captures the identity of one initialized, spawned, or removed entity.
    world.emit GameEvent(
      kind: kind, actor: world.eventEntity(source),
      target: world.eventEntity(target), cause: cause, related: -1
    )

proc interruptPortal(world: World, hero: Hero)

proc gainCreepRewards(world: World, creep: Footman, source: int32)
  ## Awards nearby XP and the killing hero's bonus once per creep death.

proc rewardDeath(world: World, target, source: int32)
  ## Defers kill rewards until all damage for this tick has landed.

proc hitKey(world: World, id: int32): HitKey =
  ## Identifies an actor by role and team-relative geometry for equal hit ties.
  var
    position, spawn: WorldPoint
    team: Team
  let hero = world.heroIndex(id)
  if hero >= 0:
    let actor = world.heroes[hero]
    result.kind = HeroObjectKind
    result.class = actor.class.ord.int32
    position = actor.position
    spawn = actor.spawnPosition
    team = actor.team
  else:
    let creep = world.footmanIndex(id)
    if creep >= 0:
      let actor = world.footmen[creep]
      result.kind = if actor.camp > 0: NeutralObjectKind else: FootmanObjectKind
      result.class = if actor.camp > 0: actor.campTier.int32 else: actor.kind.ord.int32
      position = actor.position
      spawn = position
      team = actor.team
    else:
      let building = world.buildingIndex(id)
      if building >= 0:
        let actor = world.buildings[building]
        result.kind = TowerObjectKind
        result.class = actor.kind.ord.int32 * 3 + actor.tier.ord.int32
        position = actor.position
        spawn = position
        team = actor.team
      else:
        for actor in world.forts:
          if actor.id == id:
            result.kind = FortObjectKind
            position = actor.center
            spawn = position
            team = actor.team
            break
  let direction = if team == RedTeam: 1'i32 else: -1'i32
  result.x = direction * position.x
  result.y = position.y
  result.z = direction * position.z
  result.spawnX = direction * spawn.x
  result.spawnY = spawn.y
  result.spawnZ = direction * spawn.z

proc hitTarget(
    world: World, kind: HitKind, target, damage, source: int32,
    cause = BasicAttack, detail = 0'i32
)
  ## Collects a hit during the tick or resolves an isolated command directly.

proc applyDamage[T: Hero | Footman](
    world: World,
    target: var T,
    amount, source: int32,
    cause = BasicAttack,
    detail = 0'i32
) =
  ## Applies a unit hit and records its actual health change.
  when T is Footman or defined(replayEvents):
    let before = target.hp
  target.hp -= amount
  when T is Hero:
    if amount > 0:
      for kind in RecoveryKind:
        let item = target.recoveryItems[kind]
        if item != NoItem:
          target.recoveryItems[kind] = NoItem
          target.recoveryStarted[kind] = 0
          target.recoveryApplied[kind] = 0
          when defined(replayEvents):
            world.emit GameEvent(
              kind: RecoveryInterrupted, actor: world.eventEntity(source),
              target: world.eventEntity(target.id), cause: ItemEffect,
              detail: item.ord.int32, related: -1
            )
    if target.hp <= 0:
      world.interruptPortal(target)
  when defined(replayEvents):
    world.damageEvent(source, target.id, amount, before, target.hp, cause, detail)
  when T is Footman:
    if before > 0 and target.hp <= 0:
      world.rewardDeath(target.id, source)

proc healHero(
    world: World,
    target: Hero,
    amount, source: int32,
    cause: EventCause,
    detail: int32
) =
  ## Restores health up to the hero's maximum and records the effective heal.
  when defined(replayEvents):
    let before = target.hp
  target.hp = min(target.maxHp, target.hp + amount)
  when defined(replayEvents):
    world.valueEvent(Healing, source, target.id, cause, detail,
      before, target.hp, amount)

proc restoreMana(
    world: World,
    target: Hero,
    amount, source: int32,
    cause: EventCause,
    detail: int32
) =
  ## Restores mana up to the hero's maximum and records the resource change.
  when defined(replayEvents):
    let before = target.mana
  target.mana = min(target.maxMana, target.mana + amount)
  when defined(replayEvents):
    world.valueEvent(ManaChanged, source, target.id, cause, detail,
      before, target.mana, amount)

proc finishAction(
    world: World,
    heroId: int32,
    action: uint8,
    slot, first, second: int32,
    error: ActionError,
    offset = FixedVec2Zero
): bool =
  ## Updates only the submitting hero's diagnostic and records failed commands.
  let index = world.heroIndex(heroId)
  if index >= 0:
    world.heroes[index].lastActionError = error
  when defined(replayEvents):
    if error != NoActionError:
      world.emit GameEvent(
        kind: ActionRejected, actor: world.eventEntity(heroId),
        target: world.eventEntity(0), cause: Command, related: -1,
        action: action, slot: slot, first: first, second: second, error: error,
        offsetX: int32(offset.x), offsetY: int32(offset.y)
      )
  error == NoActionError

proc buildingById*(world: World, id: int32): Building =
  ## Reads one tower by its script-visible object ID.
  let index = buildingIndex(world, id)
  if index >= 0:
    result = world.buildings[index]

proc laneCleared(world: World, team: Team): bool =
  ## Returns whether attackers have destroyed every tower in any one lane.
  for lane in 0 .. 2:
    var standing = false
    for tower in world.buildings:
      if tower.kind == TowerBuilding and not tower.guardsGod and
          tower.team == team and tower.lane == lane and tower.hp > 0:
        standing = true
        break
    if not standing:
      return true
  false

proc buildingExposed*(world: World, tower: Building): bool =
  ## Exposes lane structures in order and god guards after any lane falls.
  if tower.id == 0 or tower.hp <= 0:
    return false
  if tower.guardsGod:
    return world.laneCleared(tower.team)
  for other in world.buildings:
    if other.kind == TowerBuilding and not other.guardsGod and
        other.team == tower.team and
        other.lane == tower.lane and other.hp > 0 and
        (tower.kind == BarracksBuilding or other.tier.ord < tower.tier.ord):
      return false
  true

proc nextEnemyBuilding(
    world: World, team: Team, lane: int, position: WorldPoint
): Building =
  ## Finds lane towers, then barracks, then the nearest exposed god guard.
  let enemy = if team == RedTeam: BlueTeam else: RedTeam
  for tier in TowerTier:
    for tower in world.buildings:
      if tower.kind == TowerBuilding and not tower.guardsGod and
          tower.team == enemy and
          tower.lane == lane and tower.tier == tier and tower.hp > 0:
        return tower

  var nearest = int64.high
  for building in world.buildings:
    if building.kind == BarracksBuilding and building.team == enemy and
        building.lane == lane and building.hp > 0:
      let distance = distanceSquared(position, building.position)
      if distance < nearest or (distance == nearest and
        targetBefore(building.position, building.id,
          result.position, result.id, team)):
          nearest = distance
          result = building
  if result.id != 0:
    return
  for building in world.buildings:
    if building.guardsGod and building.team == enemy and
        world.buildingExposed(building):
      let distance = distanceSquared(position, building.position)
      if distance < nearest or (distance == nearest and
        targetBefore(building.position, building.id,
          result.position, result.id, team)):
          nearest = distance
          result = building

proc fortExposed*(world: World, team: Team): bool =
  ## Keeps a god invulnerable until both of its own guard towers are dead.
  for tower in world.buildings:
    if tower.guardsGod and tower.team == team and tower.hp > 0:
      return false
  true

proc damageFort(
    world: World, index: int, damage, source: int32,
    cause = BasicAttack, detail = 0'i32
) =
  ## Applies damage only after the god's two guards have been destroyed.
  if damage > 0 and world.fortExposed(world.forts[index].team):
    when defined(replayEvents):
      let before = world.forts[index].hp
    world.forts[index].hp = max(0'i32, world.forts[index].hp - damage)
    when defined(replayEvents):
      world.damageEvent(source, world.forts[index].id, damage,
        before, world.forts[index].hp, cause, detail)

proc xpForNextLevel*(level: int): int =
  ## Returns the XP needed to advance from the given hero level.
  100 + (level - 1) * 75

proc recordHeroKill(world: World, team: Team, victimTeam: Team) =
  ## Records one hero kill and the opposing hero's death.
  inc world.teamHeroKills[team.ord]
  inc world.teamHeroDeaths[victimTeam.ord]

proc heroItemBonus(hero: Hero): tuple[
    maxHp, maxMana, damage, movePerTick: int32
] =
  ## Sums passive bonuses from every item the hero is holding.
  for slot in 0 ..< InventorySlots:
    if hero.inventory[slot] == NoItem:
      continue
    let spec = hero.inventory[slot].itemSpec
    result.maxHp += spec.maxHp
    result.maxMana += spec.maxMana
    result.damage += spec.damage
    result.movePerTick += spec.movePerTick

proc refreshHeroStats*(
    hero: Hero,
    world: World = nil,
    cause = Initialization,
    detail = 0'i32
) =
  ## Rebuilds maximums and records live level or equipment adjustments.
  when defined(replayEvents):
    let
      beforeHp = hero.hp
      beforeMana = hero.mana
  let
    previousMaxHp = hero.maxHp
    previousMaxMana = hero.maxMana
    bonus = hero.heroItemBonus()
  hero.maxHp = heroMaxHp(hero.class, hero.level) + bonus.maxHp
  hero.maxMana = heroMaxMana(hero.class, hero.level) + bonus.maxMana
  if previousMaxHp == 0 or (hero.hp > 0 and hero.state != Dying):
    hero.hp += hero.maxHp - previousMaxHp
  hero.mana += hero.maxMana - previousMaxMana
  if hero.hp > hero.maxHp:
    hero.hp = hero.maxHp
  if hero.mana > hero.maxMana:
    hero.mana = hero.maxMana
  when defined(replayEvents):
    if world != nil:
      world.valueEvent(ManaChanged, hero.id, hero.id, cause, detail,
        beforeMana, hero.mana, 0)
      world.valueEvent(HealthAdjusted, hero.id, hero.id, cause, detail,
        beforeHp, hero.hp, 0)

proc heroAttackDamage*(hero: Hero): int32 =
  ## Returns basic-attack damage including held equipment.
  heroDamage(hero.class, hero.level) + hero.heroItemBonus().damage

proc abilityPoints*(hero: Hero): int32 =
  ## Returns banked points, including the first point granted at hero level one.
  result = int32(clamp(hero.level, 0, HeroMaxLevel))
  for rank in hero.abilityLevels:
    result -= rank
  result = max(0'i32, result)

proc abilityLevelError*(hero: Hero, slot: HeroAbilitySlot): ActionError =
  ## Checks an upgrade without spending points or changing action feedback.
  if hero.hp <= 0 or hero.state == Dying:
    return ActionNotAlive
  let rank = hero.abilityLevels[slot]
  if rank >= slot.abilityMaxLevel:
    return ActionAbilityMaxLevel
  if hero.abilityPoints == 0:
    return ActionNoAbilityPoints
  if hero.level < slot.abilityRequiredLevel(rank + 1):
    return ActionHeroLevelRequired
  NoActionError

proc applyLevelAbility*(world: World, heroId, slotId: int32): bool =
  ## Spends one point to unlock or upgrade a slot after validating all gates.
  if world.phase == Drafting:
    return world.finishAction(
      heroId, ActionLevelAbility, slotId, 0, 0, ActionDrafting
    )
  let index = world.heroIndex(heroId)
  var error = NoActionError
  if index < 0:
    error = ActionNotAlive
  elif slotId < 0 or slotId > HeroAbilitySlot.high.ord:
    error = ActionInvalidSlot
  else:
    let
      hero = world.heroes[index]
      slot = HeroAbilitySlot(slotId)
    error = hero.abilityLevelError(slot)
    if error == NoActionError:
      inc hero.abilityLevels[slot]
      if hero.abilityLevels[slot] == 1:
        hero.charges[slot] = heroAbility(hero.class, slot).abilitySpec.charges
      when defined(replayEvents):
        world.valueEvent(
          AbilityLeveled, hero.id, hero.id, Command,
          heroAbility(hero.class, slot).ord.int32,
          hero.abilityLevels[slot] - 1, hero.abilityLevels[slot], 1
        )
  world.finishAction(heroId, ActionLevelAbility, slotId, 0, 0, error)

proc heroAttackTicks*(world: World, hero: Hero): int32 =
  ## Returns the hero class's current basic-attack cadence.
  heroAttackTicks(hero.class)

proc heroHitTicks*(world: World, hero: Hero): int32 =
  ## Returns the basic-attack impact tick shared with its visual animation.
  world.heroAttackTicks(hero) * 45 div 100

proc heroAttackCooldown*(world: World, hero: Hero): int32 =
  ## Returns ticks until the next basic hit, assuming uninterrupted range.
  if hero.hp <= 0 or hero.state == Dying:
    return 0
  let
    duration = world.heroAttackTicks(hero)
    windup = world.heroHitTicks(hero)
  if hero.swingTicks < 0:
    return windup
  if not hero.damageLanded:
    return max(0, windup - hero.swingTicks)
  max(0, duration - hero.swingTicks) + windup

proc heroMoveSpeed*(hero: Hero): int32 =
  ## Returns movement distance including held equipment.
  heroMovePerTick(hero.class, hero.level) +
    hero.heroItemBonus().movePerTick

proc gainRewards(
    world: World, hero: Hero, xp, gold: int, victim: int32,
    cause = KillReward
) =
  ## Grants rewards and links them to their lethal event.
  when defined(replayEvents):
    let related = world.deathEvent(victim)
    world.valueEvent(XpGained, victim, hero.id, cause, 0,
      hero.totalXp, hero.totalXp + xp, xp, related)
    world.valueEvent(GoldGained, victim, hero.id, cause, 0,
      hero.gold, hero.gold + gold, gold, related)
  hero.xp += xp
  hero.totalXp += xp
  hero.gold += gold
  while hero.level < HeroMaxLevel and
      hero.xp >= xpForNextLevel(hero.level):
    hero.xp -= xpForNextLevel(hero.level)
    when defined(replayEvents):
      let beforeLevel = hero.level
    inc hero.level
    when defined(replayEvents):
      world.valueEvent(LevelChanged, hero.id, hero.id, LevelUp, 0,
        beforeLevel, hero.level, 1)
    hero.refreshHeroStats(world, LevelUp)

proc gainCreepRewards(world: World, creep: Footman, source: int32) =
  ## Shares one XP pool, reserving 15 percent for an eligible last hitter.
  var
    nearby: seq[int]
    lastHit = false
    killerTeam = -1'i32
  let killerHero = world.heroIndex(source)
  if killerHero >= 0:
    killerTeam = world.heroes[killerHero].team.ord.int32
  else:
    let killerCreep = world.footmanIndex(source)
    if killerCreep >= 0:
      killerTeam = world.footmen[killerCreep].faction
    else:
      let killerBuilding = world.buildingIndex(source)
      if killerBuilding >= 0:
        killerTeam = world.buildings[killerBuilding].team.ord.int32
  let
    xpReward = if creep.camp > 0:
      NeutralXp[creep.campTier - 1] * (if creep.leader: 2 else: 1)
      else: CreepNearbyXp
    goldReward = if creep.camp > 0:
      NeutralGold[creep.campTier - 1] * (if creep.leader: 2 else: 1)
      else: FootmanGoldReward
  for i, hero in world.heroes:
    let alive =
      if world.rewardAlive.len == world.heroes.len:
        world.rewardAlive[i]
      else:
        hero.hp > 0 and hero.state != Dying
    let eligible = if creep.camp > 0: hero.team.ord.int32 == killerTeam
      else: hero.team != creep.team
    if eligible and alive and
      hero.navLayer == creep.navLayer and
      within(hero.position, creep.position, CreepXpRange):
        nearby.add(i)
        if hero.id == source:
          lastHit = true
  if nearby.len > 0:
    let
      pool = xpReward * CreepXpScale
      bonus =
        if lastHit:
          pool * CreepLastHitPercent div 100
        else:
          0
      share = (pool - bonus) div nearby.len
    for i in nearby:
      let hero = world.heroes[i]
      hero.creepXpRemainder += share
      var cause = NearbyKill
      if hero.id == source:
        hero.creepXpRemainder += bonus
        cause = KillReward
      let xp = hero.creepXpRemainder div CreepXpScale
      hero.creepXpRemainder = hero.creepXpRemainder mod CreepXpScale
      world.gainRewards(hero, xp, 0, creep.id, cause)
  let killer = world.heroIndex(source)
  if killer >= 0 and (creep.camp > 0 or world.heroes[killer].team != creep.team):
    world.gainRewards(
      world.heroes[killer], 0, goldReward, creep.id
    )
    world.stats.add(killer, GoldMetric, goldReward)

proc layerFixedHeight(
    layerIndex: int,
    position: WorldPoint,
    height: var int32,
    team = RedTeam
): bool =
  ## Samples one packed tile surface using only fixed-point arithmetic.
  let
    layer = layers[layerIndex]
    worldTileX = floorWorldTile(position.x, team) + GridTiles div 2
    worldTileZ = floorWorldTile(position.z, team) + GridTiles div 2
    tileX = worldTileX - layer.originX
    tileZ = worldTileZ - layer.originZ
  if tileX < 0 or tileX >= layer.width or
      tileZ < 0 or tileZ >= layer.depth:
    return false
  let tile = layer.tiles[tileZ * layer.width + tileX]
  if not tile.exists:
    return false
  let
    floorX = int64(floorWorldTile(position.x, team)) * int64(WorldScale)
    floorZ = int64(floorWorldTile(position.z, team)) * int64(WorldScale)
    offsetX = int64(position.x) - floorX
    offsetZ = int64(position.z) - floorZ
    inverseX = int64(WorldScale) - offsetX
    inverseZ = int64(WorldScale) - offsetZ
    north = int64(tile.tops[0]) * inverseX +
      int64(tile.tops[1]) * offsetX
    south = int64(tile.tops[2]) * inverseX +
      int64(tile.tops[3]) * offsetX
    numerator = north * inverseZ + south * offsetZ
    denominator = int64(WorldScale) * 8
  height = int32(roundDivision(numerator, denominator))
  true

proc fixedSurfaceHeight(position: WorldPoint, team: Team): int32 =
  ## Returns the highest packed solid surface at an integer world position.
  var found = false
  for layerIndex, layer in layers:
    if layer.water:
      continue
    var height: int32
    if layerFixedHeight(layerIndex, position, height, team) and
        (not found or height > result):
      result = height
      found = true

proc fixedSurfaceHeightNear(
    position: WorldPoint,
    referenceY: int32,
    team: Team
): int32 =
  ## Returns the packed solid surface nearest an integer reference height.
  var
    found = false
    bestDistance = int64.high
  for layerIndex, layer in layers:
    if layer.water:
      continue
    var height: int32
    if layerFixedHeight(layerIndex, position, height, team):
      let distance = abs(int64(height) - int64(referenceY))
      if not found or distance < bestDistance or
          (distance == bestDistance and height > result):
        result = height
        bestDistance = distance
        found = true

proc canStand(x, z: int32, team: Team): bool =
  ## Keeps units out of forests, blocked fort tiles, and the map rim.
  const Margin = 18_000'i32
  let halfGridUnits = mapTiles().int32 div 2 * WorldScale
  if x < -halfGridUnits + Margin or x > halfGridUnits - Margin or
      z < -halfGridUnits + Margin or z > halfGridUnits - Margin:
    return false
  let
    tileX = floorWorldTile(x, team) + GridTiles div 2 -
      layers[GroundLayer].originX
    tileZ = floorWorldTile(z, team) + GridTiles div 2 -
      layers[GroundLayer].originZ
  isWalkable(GroundLayer, tileX, tileZ)

proc navTileAt(position: WorldPoint, value: var NavTile,
  team = RedTeam): bool

proc walkWorldCell(pos: FixedVec2): tuple[x, z: int] =
  ## Converts a tile-space body into a world tile index.
  (
    floorWorldTile(tilesToWorld(pos.x, WorldScale), gotaWalkTeam) +
      GridTiles div 2,
    floorWorldTile(tilesToWorld(pos.y, WorldScale), gotaWalkTeam) +
      GridTiles div 2
  )

proc inWalkMargin(pos: FixedVec2): bool =
  ## Keeps units off the map rim.
  const Margin = 18_000'i32
  let halfGridUnits = mapTiles().int32 div 2 * WorldScale
  let
    x = tilesToWorld(pos.x, WorldScale)
    z = tilesToWorld(pos.y, WorldScale)
  x >= -halfGridUnits + Margin and x <= halfGridUnits - Margin and
    z >= -halfGridUnits + Margin and z <= halfGridUnits - Margin

proc navigationOpen*(layer, x, z: int): bool

proc navigationLineClear(
    a, b: WorldPoint, firstLayer, lastLayer: int32, team = RedTeam
): bool =
  ## Checks exact positions against the same tile edges and building occupancy.
  const Origin = int64(GridTiles div 2) * WorldScale
  let
    first = layers[firstLayer]
    last = layers[lastLayer]
  lineClear(
    PathTile(
      layer: firstLayer,
      x: int32(floorWorldTile(a.x, team) + GridTiles div 2 - first.originX),
      z: int32(floorWorldTile(a.z, team) + GridTiles div 2 - first.originZ)
    ),
    PathTile(
      layer: lastLayer,
      x: int32(floorWorldTile(b.x, team) + GridTiles div 2 - last.originX),
      z: int32(floorWorldTile(b.z, team) + GridTiles div 2 - last.originZ)
    ),
    (int64(a.x) + Origin, int64(a.z) + Origin),
    (int64(b.x) + Origin, int64(b.z) + Origin),
    WorldScale,
    navigationOpen
  )

proc tilesWalkable(pos: FixedVec2): bool =
  ## Applies the same tile rule to walking, sliding, and unit separation.
  if not inWalkMargin(pos):
    return false
  let
    (x, z) = walkWorldCell(pos)
    destLayer = worldPreferLayer(gotaWalkLayer, gotaWalkDestLayer, x, z)
  navigationLineClear(
    WorldPoint(x: tilesToWorld(gotaWalkOrigin.x, WorldScale),
      z: tilesToWorld(gotaWalkOrigin.y, WorldScale)),
    WorldPoint(x: tilesToWorld(pos.x, WorldScale),
      z: tilesToWorld(pos.y, WorldScale)),
    gotaWalkLayer.int32,
    destLayer.int32,
    gotaWalkTeam
  )

proc bindNavLayer(position: WorldPoint, team = RedTeam): int32 =
  ## Picks the packed layer under a spawn or teleport.
  var tile: NavTile
  if navTileAt(position, tile, team):
    int32(tile.layer)
  else:
    int32(GroundLayer)

proc navigationOpen*(layer, x, z: int): bool =
  ## Combines static terrain with the active world's living buildings.
  if not isWalkable(layer, x, z):
    return false
  navigationWorld == nil or navigationWorld.occupancy.len == 0 or
    navigationWorld.occupancy[layer][z * layers[layer].width + x] == 0

proc buildingFootprint(building: Building): seq[PathTile] =
  ## Rasterizes shared, fixed-point foundation sizes onto the occupied layer.
  const TowerRadii = [63_000'i32, 75_000'i32, 99_000'i32]
  let
    layer = int(bindNavLayer(building.position, building.team))
    floor = layers[layer]
    forward = scaledPlanar(WorldPoint(
      x: building.facing.x, z: building.facing.z), WorldScale)
    halfX = 39_000'i64
    halfZ = 50_400'i64
    halfTile = int64(WorldScale div 2)
  for z in floorWorldTile(building.position.z) - 3 ..
      floorWorldTile(building.position.z) + 3:
    for x in floorWorldTile(building.position.x) - 3 ..
        floorWorldTile(building.position.x) + 3:
      let
        localX = x + GridTiles div 2 - floor.originX
        localZ = z + GridTiles div 2 - floor.originZ
      if localX < 0 or localZ < 0 or localX >= floor.width or localZ >= floor.depth:
        continue
      let
        dx = int64(x) * WorldScale + halfTile - building.position.x
        dz = int64(z) * WorldScale + halfTile - building.position.z
      var touches: bool
      if building.kind == TowerBuilding:
        let radius = int64(TowerRadii[building.tier.ord])
        touches = dx * dx + dz * dz <= radius * radius
      else:
        let
          fx = int64(forward.x)
          fz = int64(forward.z)
          projectedTile = halfTile * (abs(fx) + abs(fz))
        touches =
          abs(dx) * WorldScale < halfX * abs(fz) + halfZ * abs(fx) +
            halfTile * WorldScale and
          abs(dz) * WorldScale < halfX * abs(fx) + halfZ * abs(fz) +
            halfTile * WorldScale and
          abs(dx * fz - dz * fx) < halfX * WorldScale + projectedTile and
          abs(dx * fx + dz * fz) < halfZ * WorldScale + projectedTile
      if touches:
        result.add PathTile(layer: layer.int32, x: localX.int32, z: localZ.int32)

proc syncBuildings*(world: World) =
  ## Releases destroyed footprints and invalidates paths and stale targets.
  navigationWorld = world
  for building in world.buildings.mitems:
    let alive = building.hp > 0
    if alive == building.occupied:
      continue
    for tile in building.footprint:
      world.occupancy[tile.layer][int(tile.z) * layers[tile.layer].width +
        int(tile.x)] += (if alive: 1'i16 else: -1'i16)
    building.occupied = alive
    inc world.navigationRevision
    if not alive:
      building.targetId = 0
      for hero in world.heroes:
        if hero.attackObjectId == building.id:
          hero.attackObjectId = 0
          hero.hasMoveTarget = false
          hero.movePath.setLen(0)
        if hero.targetBuildingId == building.id:
          hero.targetBuildingId = 0
      for footman in world.footmen.mitems:
        if footman.targetBuildingId == building.id:
          footman.targetBuildingId = 0

proc initOccupancy(world: World) =
  ## Initializes independent occupancy and known building state for one match.
  navigationWorld = nil
  world.occupancy.setLen(layers.len)
  for i, layer in layers:
    world.occupancy[i] = newSeq[int16](layer.width * layer.depth)
  for building in world.buildings.mitems:
    building.footprint = buildingFootprint(building)
    building.knownAlive = [true, true]
  world.syncBuildings()

proc updateKnownBuildings(world: World) =
  ## Remembers enemy destruction only when the team's vision confirms it.
  for building in world.buildings.mitems:
    for team in Team:
      if building.team == team or world.visible(team, building.position):
        building.knownAlive[team] = building.hp > 0

proc knownWalkable*(world: World, team: Team, layer, x, z: int): bool =
  ## Reports static terrain and remembered occupancy without fog information leaks.
  if not isWalkable(layer, x, z):
    return false
  for building in world.buildings:
    if not building.knownAlive[team]:
      continue
    for tile in building.footprint:
      if tile.layer == layer and tile.x == x and tile.z == z:
        return false
  true

proc buildingAim*(building: Building, fromPoint: WorldPoint): WorldPoint =
  ## Finds the nearest point on occupied tiles for siege range and approach.
  result = building.position
  var best = int64.high
  for tile in building.footprint:
    let
      center = worldPoint(pathPoint(int(tile.layer), int(tile.x), int(tile.z)))
      point = WorldPoint(
        x: clamp(fromPoint.x, center.x - WorldScale div 2,
          center.x + WorldScale div 2),
        y: center.y,
        z: clamp(fromPoint.z, center.z - WorldScale div 2,
          center.z + WorldScale div 2))
      distance = distanceSquared(fromPoint, point)
    if distance < best or (distance == best and
      targetBefore(point, building.id, result, building.id, building.team)):
        best = distance
        result = point

proc damageBuilding(
    world: World, index: int, damage, source: int32,
    cause = BasicAttack, detail = 0'i32
) =
  ## Applies building damage and releases occupied tiles on the killing hit.
  when defined(replayEvents):
    let before = world.buildings[index].hp
  world.buildings[index].hp -= damage
  when defined(replayEvents):
    world.damageEvent(source, world.buildings[index].id, damage,
      before, world.buildings[index].hp, cause, detail)
  if world.buildings[index].hp <= 0:
    world.syncBuildings()

proc settleOnLayer(position: var WorldPoint, layer: int32, team: Team) =
  ## Writes this layer's packed height onto a world point.
  var height: int32
  if layerFixedHeight(int(layer), position, height, team):
    position.y = height

proc finishMove(navLayer: var int32, pos: FixedVec2) =
  ## Keeps the unit on its layer until the current cell leaves it.
  let (x, z) = walkWorldCell(pos)
  navLayer = int32(worldPreferLayer(
    int(navLayer), gotaWalkDestLayer, x, z
  ))

proc toPlanar(point: WorldPoint): FixedVec2 =
  ## Reads the xz plane of a world point in tile-space.
  fixedVec2(
    worldToTiles(point.x, WorldScale),
    worldToTiles(point.z, WorldScale)
  )

proc bindBody(position: WorldPoint, facing: Heading, radius: Fixed): Body =
  ## Builds a body from an integer spawn pose.
  result.pos = toPlanar(position)
  result.radius = radius
  if facing.x != 0 or facing.z != 0:
    result.facing = motions.angle(fixedVec2(
      worldToTiles(facing.x, WorldScale),
      worldToTiles(facing.z, WorldScale)
    ))

proc applyBody(position: var WorldPoint, facing: var Heading, body: Body) =
  ## Writes the body plane back onto the integer pose used by combat.
  position.x = tilesToWorld(body.pos.x, WorldScale)
  position.z = tilesToWorld(body.pos.y, WorldScale)
  let dir = motions.direction(body.facing)
  facing = heading(
    tilesToWorld(dir.x, WorldScale),
    tilesToWorld(dir.y, WorldScale)
  )

proc applyBody(footman: var Footman) =
  ## Syncs one footman's integer pose from its body.
  applyBody(footman.position, footman.facing, footman.body)

proc applyBody(hero: Hero) =
  ## Syncs one hero's integer pose from its body.
  applyBody(hero.position, hero.facing, hero.body)

proc place*(footman: var Footman, at: WorldPoint) =
  ## Teleports a footman and keeps its body on the same plane.
  footman.position = at
  footman.velocity = Heading()
  footman.body.pos = toPlanar(at)
  footman.navLayer = bindNavLayer(at, footman.team)

proc place*(hero: Hero, at: WorldPoint) =
  ## Teleports a hero and keeps its body on the same plane.
  hero.position = at
  hero.velocity = Heading()
  hero.body.pos = toPlanar(at)
  hero.navLayer = bindNavLayer(at, hero.team)

proc snapFacing(body: var Body, facing: var Heading, offset: WorldPoint) =
  ## Turns toward a world-space offset the short way.
  if offset.x == 0 and offset.z == 0:
    return
  turnToward(
    body.facing,
    motions.angle(toPlanar(offset)),
    FixedPi
  )
  let dir = motions.direction(body.facing)
  facing = heading(
    tilesToWorld(dir.x, WorldScale),
    tilesToWorld(dir.y, WorldScale)
  )

proc tryMove(
    footman: var Footman,
    direction: WorldPoint,
    destLayer = -1'i32
) =
  ## Turns toward the offset, then walks along facing with wall-slide.
  gotaWalkLayer = int(footman.navLayer)
  gotaWalkTeam = footman.team
  gotaWalkOrigin = footman.body.pos
  gotaWalkDestLayer =
    if destLayer < 0: gotaWalkLayer else: int(destLayer)
  motions.steer(
    footman.body,
    toPlanar(direction),
    worldToTiles(FootmanMovePerTick, WorldScale),
    BodyTurnRate,
    tilesWalkable
  )
  applyBody(footman)
  finishMove(footman.navLayer, footman.body.pos)
  settleOnLayer(footman.position, footman.navLayer, footman.team)
  footman.surfaceHint = footman.position.y

proc tryMove(hero: Hero, direction: WorldPoint, destLayer = -1'i32) =
  ## Turns and walks a hero at its level-scaled tile-space speed.
  gotaWalkLayer = int(hero.navLayer)
  gotaWalkTeam = hero.team
  gotaWalkOrigin = hero.body.pos
  gotaWalkDestLayer =
    if destLayer < 0: gotaWalkLayer else: int(destLayer)
  motions.steer(
    hero.body,
    toPlanar(direction),
    worldToTiles(hero.heroMoveSpeed, WorldScale),
    BodyTurnRate,
    tilesWalkable
  )
  applyBody(hero)
  finishMove(hero.navLayer, hero.body.pos)
  settleOnLayer(hero.position, hero.navLayer, hero.team)
  hero.surfaceHint = hero.position.y

var laneWorldPaths: array[3, seq[WorldPoint]]

proc waypointAt(footman: Footman, index: int): WorldPoint =
  ## Reads one lane waypoint in the team's march order.
  if footman.team == RedTeam:
    laneWorldPaths[footman.lane][index]
  else:
    laneWorldPaths[footman.lane][
      laneWorldPaths[footman.lane].len - 1 - index
    ]

proc currentWaypoint(footman: Footman): WorldPoint =
  ## Red walks the lane forward, blue walks it backward.
  footman.waypointAt(footman.waypointIndex)

proc currentWaypointLayer(footman: Footman): int32 =
  ## Layer of the waypoint this footman is walking toward.
  let route = laneWorldLayers[footman.lane]
  if route.len == 0:
    return footman.navLayer
  let index =
    if footman.team == RedTeam:
      footman.waypointIndex
    else:
      route.len - 1 - footman.waypointIndex
  if index < 0 or index >= route.len:
    footman.navLayer
  else:
    route[index]

proc advanceWaypoints*(footman: var Footman) =
  ## Clears reached lane goals even while pursuing an enemy.
  let route = laneWorldPaths[footman.lane]
  while footman.waypointIndex < route.len and
      within(footman.position, footman.currentWaypoint, WaypointRadius):
    inc footman.waypointIndex

proc creepWaypoints*(footman: Footman): seq[WorldPoint] =
  ## Returns the lane goals in this creep's marching order for the viewer.
  for i in 0 ..< laneWorldPaths[footman.lane].len:
    result.add footman.waypointAt(i)

proc liveHeroSetup(total: int): seq[ReplayHero] =
  ## Assigns the ten live bot slots evenly across both teams.
  let redCount = (total + 1) div 2
  for i in 0 ..< total:
    let
      team =
        if i < redCount: RedTeam
        else: BlueTeam
      slot =
        if team == RedTeam: i
        else: i - redCount
      lane = HeroLanes[slot mod HeroLanes.len]
    result.add ReplayHero(
      id: FirstHeroId + int32(i),
      team: uint8(team.ord),
      slot: uint8(slot),
      lane: uint8(lane),
      class: uint8(heroClassForTeam(team.ord, slot).ord)
    )

proc spawnHeroes(world: World, setup: openArray[ReplayHero]) =
  ## Creates the persistent heroes described by a live or replay setup.
  const SlotOffsets = [
    -48_000'i32,
    48_000'i32,
    0'i32,
    -48_000'i32,
    48_000'i32
  ]
  for heroSetup in setup:
    let
      team = Team(heroSetup.team)
      slot = int(heroSetup.slot)
      lane = int(heroSetup.lane)
      class = HeroClass(heroSetup.class)
      path = lanePathPoints[lane]
      start = world.heroSpawns[team.ord]
      inner =
        if team == RedTeam:
          worldPoint(path[min(3, path.len - 1)])
        else:
          worldPoint(path[max(path.len - 4, 0)])
      direction = inner - start
      side = WorldPoint(x: -direction.z, z: direction.x)
      group = slot div HeroLanes.len
    var fixedPosition = start +
      scaledPlanar(side, SlotOffsets[slot mod SlotOffsets.len]) +
      scaledPlanar(direction, int32(group * 75_000))
    if not canStand(fixedPosition.x, fixedPosition.z, team):
      fixedPosition = start
    fixedPosition.y = fixedSurfaceHeight(fixedPosition, team)
    let
      maxHp = heroMaxHp(class, 1)
      maxMana = heroMaxMana(class, 1)
    world.heroes.add Hero(
      id: heroSetup.id,
      team: team,
      slot: slot,
      lane: lane,
      class: class,
      position: fixedPosition,
      spawnPosition: fixedPosition,
      facing: heading(direction.x, direction.z),
      body: bindBody(
        fixedPosition,
        heading(direction.x, direction.z),
        HeroBodyRadius
      ),
      hp: maxHp,
      maxHp: maxHp,
      mana: maxMana,
      maxMana: maxMana,
      level: 1,
      gold: 150,
      state: Marching,
      swingTicks: -1,
      animClip: heroRunClip,
      surfaceHint: fixedPosition.y,
      navLayer: bindNavLayer(fixedPosition, team)
    )

proc seededHeroTurnStart(world: World): int =
  ## Chooses the first VM from the order stream.
  int(world.rng.below(int32(world.heroes.len)))

proc currentSetup*(game: Game, maximumTicks: uint32): Setup =
  ## Captures the deterministic arena setup without any bot implementation.
  result = Setup(
    mapSeed: game.map.seed,
    mapHash: game.map.hash,
    tickRate: uint16(TickRate),
    gridTiles: uint16(game.map.resolution),
    spawnIntervalTicks: uint32(game.world.spawnIntervalTicks),
    maximumTicks: maximumTicks,
    drafting: game.world.drafting
  )
  for hero in game.world.heroes:
    result.heroes.add ReplayHero(
      id: hero.id,
      team: uint8(hero.team.ord),
      slot: uint8(hero.slot),
      lane: uint8(hero.lane),
      class: uint8(
        if game.world.drafting:
          heroClassForTeam(hero.team.ord, hero.slot).ord
        else:
          hero.class.ord
      )
    )

proc validateReplayWorld(game: Game) =
  ## Confirms that the replay setup matches this game simulation build.
  let
    actual = game.replayData.header.setup
    expected = currentSetup(game, actual.maximumTicks)
  if actual != expected:
    raise newException(
      ReplayError,
      "the replay setup does not match this Gods of the Arena build"
    )

proc nearestNavTile(
    mapX, mapY: int, referenceY: int32, value: var NavTile,
    excluded: seq[PathTile] = @[], reverseSearch = false
): bool

proc spawnWave(world: World) {.measure.} =
  ## Spawns three melee creeps and one caster per surviving barracks.
  var count = 0
  for building in world.buildings:
    if building.kind == BarracksBuilding and building.hp > 0:
      count += CreepsPerBarracks
  for unit in world.footmen:
    if unit.camp == 0:
      inc count
  if count > UnitCap:
    return
  var occupied: seq[PathTile]
  for footman in world.footmen:
    if footman.hp <= 0:
      continue
    var tile: NavTile
    if navTileAt(footman.position, tile, footman.team):
      occupied.add PathTile(
        layer: tile.layer.int32, x: tile.x.int32, z: tile.z.int32)
  for building in world.buildings:
    if building.kind != BarracksBuilding or building.hp <= 0:
      continue
    for unit in 0 ..< CreepsPerBarracks:
      let start = building.spawn + scaledPlanar(
        WorldPoint(x: building.facing.z, z: -building.facing.x),
        int32(unit - CreepsPerBarracks div 2) * WorldScale
      )
      var tile: NavTile
      if not nearestNavTile(
        floorWorldTile(start.x, building.team) + mapTiles() div 2,
        floorWorldTile(start.z, building.team) + mapTiles() div 2,
        start.y, tile, occupied,
        reverseSearch = building.team == RedTeam
      ):
        continue
      occupied.add PathTile(
        layer: tile.layer.int32, x: tile.x.int32, z: tile.z.int32)
      let placed = worldPoint(pathPoint(tile.layer, tile.x, tile.z))
      var footman = Footman(
        id: world.nextFootmanId,
        kind: (if unit < MeleeCreepsPerBarracks: MeleeCreep else: RangedCreep),
        team: building.team, lane: building.lane,
        position: placed, facing: building.facing,
        body: bindBody(placed, building.facing, FootmanBodyRadius),
        hp: FootmanHp, state: Marching, animClip: runClip,
        animTicks: world.rng.below(TickRate),
        surfaceHint: placed.y, navLayer: tile.layer.int32)
      inc world.nextFootmanId
      footman.advanceWaypoints()
      world.footmen.add footman
      when defined(replayEvents):
        world.lifecycleEvent(EntitySpawned, building.id, footman.id, Wave)

proc mapCoordinate*(value: int32): int32 =
  ## Converts one world coordinate to a clamped script map coordinate.
  int32(clamp(
    floorWorldTile(value) + mapTiles() div 2,
    0,
    mapTiles() - 1
  ))

proc mapCoordinate*(value: int32, observer: Team): int32 =
  ## Chooses mirrored cells at shared tile edges for opposite observers.
  int32(clamp(floorWorldTile(value, observer) + mapTiles() div 2,
    0, mapTiles() - 1))

proc heroBaseArea(hero: Hero): BaseArea =
  ## Reads the room beneath a hero without extending it beyond the map.
  if hero.navLayer != GroundLayer:
    return OutsideBase
  baseArea(
    floorWorldTile(hero.position.x, hero.team) + mapTiles() div 2,
    floorWorldTile(hero.position.z, hero.team) + mapTiles() div 2
  )

proc inOwnSpawn*(hero: Hero): bool =
  ## Checks whether a living hero is inside its team's spawn room.
  hero.hp > 0 and hero.state != Dying and hero.heroBaseArea ==
    (if hero.team == RedTeam: RedSpawn else: BlueSpawn)

proc canShop*(hero: Hero): bool =
  ## Allows purchases only on the living hero's own keep or spawn floor.
  if hero.hp <= 0 or hero.state == Dying:
    return false
  let area = hero.heroBaseArea
  if hero.team == RedTeam:
    area in {RedKeep, RedSpawn}
  else:
    area in {BlueKeep, BlueSpawn}

proc consumableCooldown(hero: Hero, item: Item, tick: int32): int32 =
  ## Reads the resource-family cooldown shared by all stacks of a potion.
  let spec = item.itemSpec
  if item == PortalScroll:
    max(0'i32, hero.portalCooldownEnds - tick)
  elif spec.heal > 0:
    max(0'i32, hero.potionCooldownEnds[HealthRecovery] - tick)
  elif spec.restore > 0:
    max(0'i32, hero.potionCooldownEnds[ManaRecovery] - tick)
  else:
    0

proc itemCooldown*(hero: Hero, slot: int, tick: int32): int32 =
  ## Reads the remaining cooldown for an inventory slot, or zero if invalid.
  if slot >= 0 and slot < InventorySlots:
    hero.consumableCooldown(hero.inventory[slot], tick)
  else:
    0

proc itemCooldowns*(hero: Hero, tick: int32): array[InventorySlots, int32] =
  ## Captures all inventory cooldowns for the HUD.
  for slot in 0 ..< InventorySlots:
    result[slot] = hero.itemCooldown(slot, tick)

proc rawWorldObjectCount(world: World): int =
  ## Returns the total number of stable script-addressable objects.
  world.forts.len + world.buildings.len + world.heroes.len + world.footmen.len

proc rawWorldObjectAt(world: World, index: int, value: var WorldObject): bool =
  ## Reads one object from the complete stable world enumeration.
  if index < 0:
    return false
  if index < world.forts.len:
    let fort = world.forts[index]
    value = WorldObject(
      id: fort.id,
      kind: FortObjectKind,
      class: -1,
      team: fort.team,
      position: fort.center,
      hp: fort.hp,
      maxHp: FortHp,
      alive: fort.hp > 0 and fortExposed(world, fort.team)
    )
    return true
  let buildingIndex = index - world.forts.len
  if buildingIndex < world.buildings.len:
    let tower = world.buildings[buildingIndex]
    value = WorldObject(
      id: tower.id,
      kind: (if tower.kind == TowerBuilding: TowerObjectKind
        else: BarracksObjectKind),
      class: -1,
      team: tower.team,
      position: tower.position,
      hp: tower.hp,
      maxHp: tower.maxHp,
      alive: buildingExposed(world, tower),
      facing: tower.facing,
      targetId: (if tower.hp > 0: tower.targetId else: 0)
    )
    return true
  let heroIndex = buildingIndex - world.buildings.len
  if heroIndex < world.heroes.len:
    let hero = world.heroes[heroIndex]
    value = WorldObject(
      id: hero.id,
      kind: HeroObjectKind,
      class: int32(hero.class.ord),
      team: hero.team,
      position: hero.position,
      hp: hero.hp,
      maxHp: hero.maxHp,
      alive: hero.state != Dying and hero.hp > 0,
      level: int32(hero.level),
      mana: hero.mana,
      inventory: hero.inventory,
      itemCounts: hero.itemCounts,
      facing: hero.facing,
      velocity: hero.velocity,
      targetId:
        if hero.hp > 0 and hero.state != Dying: hero.attackObjectId
        else: 0
    )
    if value.alive:
      for effect in ControlEffect:
        value.controlTicks[effect] =
          max(0'i32, hero.controls[effect].ends - world.tick)
    return true
  let footmanIndex = heroIndex - world.heroes.len
  if footmanIndex < world.footmen.len:
    let footman = world.footmen[footmanIndex]
    value = WorldObject(
      id: footman.id,
      kind: (if footman.camp > 0: NeutralObjectKind else: FootmanObjectKind),
      class: (if footman.camp > 0: footman.campTier.int32 else: footman.kind.ord.int32),
      camp: footman.camp, leader: footman.leader,
      returning: world.returning(footman),
      team: footman.team,
      position: footman.position,
      hp: footman.hp,
      maxHp: footman.unitMaxHp,
      alive: footman.state != Dying and footman.hp > 0,
      facing: footman.facing,
      velocity: footman.velocity,
      targetId:
        if footman.hp <= 0 or footman.state == Dying: 0
        elif footman.targetId != 0: footman.targetId
        elif footman.targetHeroId != 0: footman.targetHeroId
        elif footman.targetBuildingId != 0: footman.targetBuildingId
        elif footman.attackingFort: world.forts[enemyFort(footman.team)].id
        else: 0
    )
    if value.alive:
      for effect in ControlEffect:
        value.controlTicks[effect] =
          max(0'i32, footman.controls[effect].ends - world.tick)
    return true
  false

proc spellObservationKey(world: World, spell: SpellCast, team: Team):
    tuple[impact: int32, allied: bool, z, x: int32, ability: int,
      caster, target, started, ends, level: int32] =
  ## Orders warnings by urgency and team-relative geometry, independent of scans.
  let
    caster = world.heroIndex(spell.heroId)
    allied = caster >= 0 and world.heroes[caster].team == team
    direction = if team == RedTeam: 1'i32 else: -1'i32
  (spell.impact, allied, direction * spell.position.z,
    direction * spell.position.x, spell.ability.ord, spell.heroId,
    spell.targetId, spell.started, spell.ends, spell.level)

proc freezeObservations*(world: World): bool =
  ## Captures one common observation frame and reports ownership to the caller.
  if world.observationsFrozen:
    return false
  world.observedObjects.setLen(rawWorldObjectCount(world))
  for i in 0 ..< world.observedObjects.len:
    discard rawWorldObjectAt(world, i, world.observedObjects[i])
  for team in Team:
    world.observedSpells[team] = world.casts
    world.observedSpells[team].sort(proc(first, second: SpellCast): int =
      ## Keeps the bounded warning scan identical in corresponding situations.
      cmp(world.spellObservationKey(first, team),
        world.spellObservationKey(second, team))
    )
  world.scriptObjectsTick = -1
  world.observationsFrozen = true
  true

proc thawObservations*(world: World) =
  ## Releases the temporary frame after every actor has made its decision.
  world.observationsFrozen = false
  world.observedObjects.setLen(0)
  for spells in world.observedSpells.mitems:
    spells.setLen(0)
  world.scriptObjectsTick = -1

iterator observedCasts*(world: World, team: Team): SpellCast =
  ## Reads the common decision frame, or live casts outside that phase.
  if world.observationsFrozen:
    for spell in world.observedSpells[team]:
      yield spell
  else:
    for spell in world.casts:
      yield spell

proc objectVisibleTo(world: World, team: Team, value: WorldObject): bool =
  ## Returns whether one object is visible to a querying hero's team.
  value.faction == team.ord.int32 or visible(world, team, value.position)

proc scriptObjectKey(value: WorldObject, observer: Team):
    tuple[group, enemy: int, z, x, id: int32] =
  ## Keeps bounded scans stable under rotation and changes to storage order.
  let
    group =
      case value.kind
      of FortObjectKind: 0
      of TowerObjectKind, BarracksObjectKind: 1
      of HeroObjectKind: 2
      else: 3
    direction = if observer == RedTeam: 1'i32 else: -1'i32
  (group, int(value.faction != observer.ord.int32), direction * value.position.z,
    direction * value.position.x, value.id)

proc ensureScriptObjects(world: World, heroId: int32) =
  ## Rebuilds the visible object list once per hero decision tick.
  if world.scriptObjectsHeroId == heroId and
      world.scriptObjectsTick == world.tick:
    return
  world.scriptObjectCount = 0
  let observer = heroIndex(world, heroId)
  if observer >= 0:
    let team = world.heroes[observer].team
    var value: WorldObject
    let count =
      if world.observationsFrozen: world.observedObjects.len
      else: rawWorldObjectCount(world)
    for i in 0 ..< count:
      if world.observationsFrozen:
        value = world.observedObjects[i]
      elif not rawWorldObjectAt(world, i, value):
        continue
      if not objectVisibleTo(world, team, value) or
          (value.kind in [TowerObjectKind, BarracksObjectKind] and value.hp <= 0):
        continue
      if world.scriptObjectCount == world.scriptObjects.len:
        world.scriptObjects.add value
      else:
        world.scriptObjects[world.scriptObjectCount] = value
      inc world.scriptObjectCount
    world.scriptObjects.setLen(world.scriptObjectCount)
    world.scriptObjects.sort(proc(first, second: WorldObject): int =
      ## Orders observed identities in the querying team's coordinate frame.
      cmp(first.scriptObjectKey(team), second.scriptObjectKey(team))
    )
  world.scriptObjectsHeroId = heroId
  world.scriptObjectsTick = world.tick

proc worldObjectCount*(world: World, heroId: int32): int =
  ## Returns the number of objects visible to one hero script.
  world.ensureScriptObjects(heroId)
  world.scriptObjectCount

proc worldObjectAt*(
    world: World,
    heroId: int32,
    index: int,
    value: var WorldObject
): bool =
  ## Reads one object from a hero's stable visibility-filtered enumeration.
  world.ensureScriptObjects(heroId)
  if index < 0 or index >= world.scriptObjectCount:
    return false
  value = world.scriptObjects[index]
  true

proc worldObjectById*(
    world: World,
    heroId,
    id: int32,
    value: var WorldObject
): bool =
  ## Finds an identity in the decision frame, or live state outside decisions.
  let observer = world.heroIndex(heroId)
  if observer < 0:
    return false
  let
    team = world.heroes[observer].team
    count =
      if world.observationsFrozen: world.observedObjects.len
      else: rawWorldObjectCount(world)
  for i in 0 ..< count:
    var candidate: WorldObject
    if world.observationsFrozen:
      candidate = world.observedObjects[i]
    elif not rawWorldObjectAt(world, i, candidate):
      continue
    if candidate.id == id and world.objectVisibleTo(team, candidate):
      value = candidate
      return true
  false

proc heroById*(world: World, id: int32): Hero =
  ## Reads one hero by its script-visible object ID.
  let index = heroIndex(world, id)
  if index >= 0:
    result = world.heroes[index]
  else:
    result = Hero()

proc footmanById*(world: World, id: int32): Footman =
  ## Reads one footman by its script-visible object ID.
  let index = footmanIndex(world, id)
  if index >= 0:
    result = world.footmen[index]

proc navTileAt(position: WorldPoint, value: var NavTile, team: Team): bool =
  ## Finds the walkable layer tile closest to a world-space position.
  let
    worldX = floorWorldTile(position.x, team) + GridTiles div 2
    worldZ = floorWorldTile(position.z, team) + GridTiles div 2
  var bestHeight = int64.high
  for layerIndex, layer in layers:
    if layer.water:
      continue
    let
      x = worldX - layer.originX
      z = worldZ - layer.originZ
    if not isWalkable(layerIndex, x, z):
      continue
    let height = abs(
      int64(worldPoint(pathPoint(layerIndex, x, z)).y) -
      int64(position.y)
    )
    if not result or height < bestHeight:
      value = NavTile(layer: layerIndex, x: x, z: z)
      bestHeight = height
      result = true

proc nearestNavTile(
    mapX,
    mapY: int,
    referenceY: int32,
    value: var NavTile,
    excluded: seq[PathTile],
    reverseSearch: bool
): bool =
  ## Finds the closest open cell, breaking ties in the team's orientation.
  let direction = if reverseSearch: -1 else: 1
  var bestScore = int64.high
  for dz in -8 .. 8:
    for dx in -8 .. 8:
      let
        worldX = mapX + dx * direction
        worldZ = mapY + dz * direction
      if worldX < 0 or worldX >= mapTiles() or
          worldZ < 0 or worldZ >= mapTiles():
        continue
      for layerIndex, layer in layers:
        if layer.water:
          continue
        let
          x = worldX + mapOrigin() - layer.originX
          z = worldZ + mapOrigin() - layer.originZ
        if not navigationOpen(layerIndex, x, z):
          continue
        if PathTile(layer: layerIndex.int32, x: x.int32, z: z.int32) in excluded:
          continue
        let
          centerY = worldPoint(pathPoint(layerIndex, x, z)).y
          planar = int64(dx * dx + dz * dz)
          score = planar * int64(WorldScale) * 100 +
            abs(int64(centerY) - int64(referenceY))
        if score < bestScore:
          value = NavTile(layer: layerIndex, x: x, z: z)
          bestScore = score
          result = true

proc movementPath(tiles: seq[PathTile], start: WorldPoint,
    team: Team): seq[PathTile] =
  ## Keeps the farthest clear shortcut from each turn, starting at the unit.
  if tiles.len == 0:
    return
  result.add tiles[0]
  var
    anchor = 0
    position = start
  while anchor < tiles.high:
    var
      last = anchor
      reach = -1
      destination: WorldPoint
    while last < tiles.high and tiles[last + 1].layer == tiles[anchor].layer:
      inc last
    last = max(last, anchor + 1)
    for i in countdown(last, anchor + 1):
      let point = worldPoint(pathPoint(
        int(tiles[i].layer), int(tiles[i].x), int(tiles[i].z)))
      if navigationLineClear(position, point,
        tiles[anchor].layer, tiles[i].layer, team):
        reach = i
        destination = point
        break
    if reach < 0:
      return @[]
    result.add tiles[reach]
    position = destination
    anchor = reach

proc followCreepPath(world: World, footman: var Footman, goal: WorldPoint) =
  ## Follows a cached route and throttles changed chase goals and failed searches.
  if footman.controls[RootControl].ends > world.tick:
    return
  let
    changed = floorWorldTile(goal.x, footman.team) !=
      floorWorldTile(footman.moveGoal.x, footman.team) or
      floorWorldTile(goal.z, footman.team) !=
      floorWorldTile(footman.moveGoal.z, footman.team) or
      goal.y != footman.moveGoal.y
    invalid = footman.moveRevision != world.navigationRevision
    finished = footman.movePathIndex >= footman.movePath.len
  if invalid or ((changed or finished) and world.tick >= footman.nextPathTick):
    footman.moveGoal = goal
    footman.moveRevision = world.navigationRevision
    footman.movePathIndex = 0
    footman.movePath.setLen(0)
    footman.nextPathTick = world.tick + FailedPathTicks
    var first, last: NavTile
    if navTileAt(footman.position, first, footman.team) and nearestNavTile(
      int(mapCoordinate(goal.x, footman.team)),
      int(mapCoordinate(goal.z, footman.team)), goal.y, last,
      reverseSearch = footman.team == RedTeam
    ):
      let route = findTilePath(PathQuery(
        startLayer: first.layer, startX: first.x, startZ: first.z,
        finishLayer: last.layer, finishX: last.x, finishZ: last.z,
        tieOrder: (if footman.team == RedTeam: ReverseTies else: ForwardTies),
        walkable: navigationOpen)).tiles
      footman.movePath = movementPath(route, footman.position, footman.team)
      # The first tile is the search origin, not a movement destination.
      if footman.movePath.len > 1:
        footman.movePathIndex = 1
      if footman.movePath.len > 0:
        footman.nextPathTick = world.tick + ChasePathTicks
  while footman.movePathIndex < footman.movePath.len:
    let
      tile = footman.movePath[footman.movePathIndex]
      point = worldPoint(pathPoint(int(tile.layer), int(tile.x), int(tile.z)))
    if not navigationOpen(int(tile.layer), int(tile.x), int(tile.z)):
      footman.moveRevision = -1
      return
    var reached = within(footman.position, point, PathPointRadius)
    if reached and footman.movePathIndex < footman.movePath.high:
      let
        next = footman.movePath[footman.movePathIndex + 1]
        nextPoint = worldPoint(pathPoint(int(next.layer), int(next.x), int(next.z)))
      reached = navigationLineClear(
        footman.position, nextPoint, footman.navLayer, next.layer, footman.team)
    if reached:
      inc footman.movePathIndex
    else:
      let before = footman.position
      footman.tryMove(point - footman.position, tile.layer)
      if within(before, footman.position, 100):
        inc footman.stuckTicks
        if footman.stuckTicks >= TickRate:
          footman.moveRevision = -1
          footman.stuckTicks = 0
      else:
        footman.stuckTicks = 0
      return

proc setHeroDestination(
    hero: Hero,
    mapX,
    mapY: int,
    referenceY: int32,
    offset = FixedVec2Zero
): bool =
  ## Computes and stores a server-side path for one hero destination.
  let
    targetX = clamp(mapX, 0, mapTiles() - 1)
    targetY = clamp(mapY, 0, mapTiles() - 1)
  if hero.moveRevision == navigationWorld.navigationRevision and
      hero.hasMoveTarget and hero.moveTileX == targetX and
      hero.moveTileY == targetY and hero.moveOffset == offset and
      hero.movePathIndex < hero.movePath.len:
    return true
  var
    startTile: NavTile
    finishTile: NavTile
  if not navTileAt(hero.position, startTile, hero.team) or
      not nearestNavTile(targetX, targetY, referenceY, finishTile,
        reverseSearch = hero.team == RedTeam):
    return false
  discard fillTilePath(PathQuery(
    startLayer: startTile.layer,
    startX: startTile.x,
    startZ: startTile.z,
    finishLayer: finishTile.layer,
    finishX: finishTile.x,
    finishZ: finishTile.z,
    tieOrder: (if hero.team == RedTeam: ReverseTies else: ForwardTies),
    walkable: navigationOpen
  ), heroPathTiles)
  if heroPathTiles.len == 0:
    return false
  let pulled = movementPath(heroPathTiles, hero.position, hero.team)
  if pulled.len == 0:
    return false
  hero.movePath.setLen(pulled.len)
  hero.movePathLayers.setLen(pulled.len)
  for i, tile in pulled:
    hero.movePath[i] = worldPoint(pathPoint(
      int(tile.layer),
      int(tile.x),
      int(tile.z)
    ))
    hero.movePathLayers[i] = tile.layer
  if offset != FixedVec2Zero:
    let center = hero.movePath[^1]
    if mapCoordinate(center.x) == targetX and mapCoordinate(center.z) == targetY:
      var target = center
      target.x += tilesToWorld(offset.x, WorldScale)
      target.z += tilesToWorld(offset.y, WorldScale)
      target.y = fixedSurfaceHeightNear(target, referenceY, hero.team)
      let layer = hero.movePathLayers[^1]
      if not navigationLineClear(center, target, layer, layer, hero.team):
        return false
      hero.movePath.add target
      hero.movePathLayers.add layer
  hero.moveOffset = offset
  hero.moveRevision = navigationWorld.navigationRevision
  # Replanning must not send the hero back to its starting tile's center.
  hero.movePathIndex = if pulled.len > 1: 1 else: 0
  hero.moveTileX = targetX
  hero.moveTileY = targetY
  hero.hasMoveTarget = true
  true

proc stopHeroPath(hero: Hero) =
  ## Drops the finished chase so a hero can acquire nearby creeps again.
  hero.hasMoveTarget = false
  hero.movePath.setLen(0)
  hero.movePathLayers.setLen(0)
  hero.movePathIndex = 0

proc followHeroPath(hero: Hero): bool =
  ## Advances a hero along its current server-generated path.
  if hero.controls[RootControl].ends > navigationWorld.tick:
    return false
  if hero.hasMoveTarget and hero.moveRevision != navigationWorld.navigationRevision:
    if not hero.setHeroDestination(
        hero.moveTileX, hero.moveTileY, hero.position.y, hero.moveOffset):
      hero.movePath.setLen(0)
      return false
  while hero.movePathIndex < hero.movePath.len:
    let waypoint = hero.movePath[hero.movePathIndex]
    let offset = WorldPoint(
      x: waypoint.x - hero.position.x,
      z: waypoint.z - hero.position.z
    )
    let radius =
      if hero.movePathIndex == hero.movePath.high and
          hero.moveOffset != FixedVec2Zero:
        100'i32
      else:
        PathPointRadius
    var reached = within(hero.position, waypoint, radius)
    if reached and hero.movePathIndex < hero.movePath.high:
      let
        next = hero.movePathIndex + 1
        layer =
          if next < hero.movePathLayers.len: hero.movePathLayers[next]
          else: hero.navLayer
      reached = navigationLineClear(
        hero.position, hero.movePath[next], hero.navLayer, layer, hero.team)
    if not reached:
      let destLayer =
        if hero.movePathIndex < hero.movePathLayers.len:
          hero.movePathLayers[hero.movePathIndex]
        else:
          hero.navLayer
      let before = hero.position
      hero.tryMove(offset, destLayer)
      if within(before, hero.position, 100):
        inc hero.stuckTicks
        if hero.stuckTicks >= TickRate:
          hero.moveRevision = -1
          hero.stuckTicks = 0
      else:
        hero.stuckTicks = 0
      return true
    inc hero.movePathIndex
  hero.hasMoveTarget = false
  false

proc interruptPortal(world: World, hero: Hero) =
  ## Ends a spent scroll's channel and starts its shared cooldown.
  if hero.portalEnds == 0:
    return
  hero.portalEnds = 0
  hero.portalCooldownEnds = world.tick + PortalCooldownTicks
  when defined(replayEvents):
    world.lifecycleEvent(PortalInterrupted, hero.id, hero.portalTowerId,
      ItemEffect)
  hero.portalTowerId = 0

proc applyControl*(
    world: World,
    targetId: int32,
    effect: ControlEffect,
    duration: int32,
    source = 0'i32,
    ability = -1'i32
) =
  ## Applies control to living units, keeping the later expiration on refresh.
  if effect == NoControl or duration <= 0:
    return
  template affect(unit: untyped) =
    ## Applies the same timer and event rules to either unit representation.
    if unit.hp <= 0 or unit.state == Dying:
      return
    let before = unit.controls[effect].ends
    if world.tick + duration <= before:
      return
    unit.controls[effect] = ControlTimer(
      started: world.tick, ends: world.tick + duration)
    if effect == StunControl:
      unit.swingTicks = -1
    when defined(replayEvents):
      let kind = case effect
        of StunControl: Stunned
        of SilenceControl: Silenced
        of RootControl: Rooted
        of NoControl: Stunned
      world.emit GameEvent(
        kind: kind, actor: world.eventEntity(source),
        target: world.eventEntity(targetId), cause: AbilityEffect,
        detail: ability, requested: duration, amount: duration,
        before: before, after: unit.controls[effect].ends, related: -1
      )
  let hero = world.heroById(targetId)
  if hero.id != 0:
    affect(hero)
    if effect in {StunControl, RootControl}:
      world.interruptPortal(hero)
    return
  let creep = world.footmanIndex(targetId)
  if creep >= 0 and not world.returning(world.footmen[creep]):
    affect(world.footmen[creep])

proc heroActionError(world: World, hero: Hero, movement = false): ActionError =
  ## Rejects commands that a channel or active control effect prevents.
  if hero.hp <= 0 or hero.state == Dying:
    return ActionNotAlive
  if hero.portalEnds > 0:
    return ActionChanneling
  if hero.controls[StunControl].ends > world.tick:
    return ActionStunned
  if movement and hero.controls[RootControl].ends > world.tick:
    return ActionRooted

proc portalLanding*(
  world: World,
  team: Team,
  aim: WorldPoint,
  destination: var WorldPoint,
  towerId: var int32,
  anchorId = 0'i32
): bool =
  ## Finds the closest visible, open landing within an allied tower's range.
  navigationWorld = world
  let orientation = if team == RedTeam: -1'i64 else: 1'i64
  var best = (int64.high, int64.high, int64.high,
    int64.high, int64.high, int64.high)
  for tower in world.buildings:
    if tower.kind != TowerBuilding or tower.team != team or tower.hp <= 0 or
      (anchorId != 0 and tower.id != anchorId):
        continue
    let
      range = TowerAttackRanges[tower.tier]
      radius = int((range + WorldScale - 1) div WorldScale)
      centerX = floorWorldTile(tower.position.x, team) + GridTiles div 2
      centerZ = floorWorldTile(tower.position.z, team) + GridTiles div 2
    for layerIndex, layer in layers:
      if layer.water:
        continue
      for z in max(0, centerZ - layer.originZ - radius) ..
        min(layer.depth - 1, centerZ - layer.originZ + radius):
          for x in max(0, centerX - layer.originX - radius) ..
            min(layer.width - 1, centerX - layer.originX + radius):
              if not navigationOpen(layerIndex, x, z):
                continue
              var point = worldPoint(pathPoint(layerIndex, x, z))
              if floorWorldTile(point.x, team) == floorWorldTile(aim.x, team) and
                floorWorldTile(point.z, team) == floorWorldTile(aim.z, team):
                  point.x = aim.x
                  point.z = aim.z
                  discard layerFixedHeight(layerIndex, point, point.y, team)
              if not within(point, tower.position, range) or
                not world.visible(team, point) or not inWalkMargin(toPlanar(point)):
                  continue
              let rank = (
                distanceSquared(point, aim),
                int64(point.z) * orientation,
                int64(point.x) * orientation,
                int64(point.y),
                int64(tower.position.z) * orientation,
                int64(tower.position.x) * orientation
              )
              if rank < best:
                destination = point
                towerId = tower.id
                best = rank
                result = true

proc applyWalkTo*(world: World, heroId, mapX, mapY: int32,
    offset = FixedVec2Zero
): bool =
  ## Applies one hero walk command using server-side pathfinding.
  if world.phase == Drafting:
    return world.finishAction(
      heroId, ActionWalkTo, 0, mapX, mapY, ActionDrafting, offset
    )
  if not offset.validTileOffset:
    return false
  navigationWorld = world
  let index = heroIndex(world, heroId)
  if index < 0 or world.heroes[index].state == Dying:
    return world.finishAction(
      heroId,
      ActionWalkTo,
      0,
      mapX,
      mapY,
      ActionNotAlive,
      offset
    )
  let error = world.heroActionError(world.heroes[index], movement = true)
  if error != NoActionError:
    return world.finishAction(heroId, ActionWalkTo, 0, mapX, mapY, error, offset)
  world.heroes[index].attackObjectId = 0
  world.heroes[index].attackMoving = false
  world.heroes[index].targetFootmanId = 0
  world.heroes[index].targetHeroId = 0
  world.heroes[index].targetBuildingId = 0
  world.heroes[index].attackingFort = false
  let accepted = setHeroDestination(
    world.heroes[index],
    int(mapX),
    int(mapY),
    world.heroes[index].position.y,
    offset
  )
  world.finishAction(
    heroId,
    ActionWalkTo,
    0,
    mapX,
    mapY,
    (if accepted: NoActionError else: ActionNoRoute),
    offset
  )

proc applyAttackMove*(world: World, heroId, mapX, mapY: int32,
    offset = FixedVec2Zero
): bool =
  ## Walks toward a map tile and attacks enemies found along the way.
  if world.phase == Drafting:
    return world.finishAction(
      heroId, ActionAttackMove, 0, mapX, mapY, ActionDrafting, offset
    )
  if not offset.validTileOffset:
    return false
  navigationWorld = world
  let index = heroIndex(world, heroId)
  if index < 0 or world.heroes[index].state == Dying:
    return world.finishAction(
      heroId,
      ActionAttackMove,
      0,
      mapX,
      mapY,
      ActionNotAlive,
      offset
    )
  let error = world.heroActionError(world.heroes[index], movement = true)
  if error != NoActionError:
    return world.finishAction(
      heroId, ActionAttackMove, 0, mapX, mapY, error, offset
    )
  world.heroes[index].attackObjectId = 0
  world.heroes[index].attackMoving = true
  world.heroes[index].targetFootmanId = 0
  world.heroes[index].targetHeroId = 0
  world.heroes[index].targetBuildingId = 0
  world.heroes[index].attackingFort = false
  let accepted = setHeroDestination(
    world.heroes[index],
    int(mapX),
    int(mapY),
    world.heroes[index].position.y,
    offset
  )
  world.finishAction(
    heroId,
    ActionAttackMove,
    0,
    mapX,
    mapY,
    (if accepted: NoActionError else: ActionNoRoute),
    offset
  )

proc isEnemyTarget(world: World, hero: Hero, targetId: int32): bool =
  ## Returns whether `targetId` is a living enemy the hero can chase.
  if targetId == 0:
    return false
  let footman = footmanIndex(world, targetId)
  if footman >= 0:
    let other = world.footmen[footman]
    return world.hostile(other, hero.team, engageResting = true)
  let otherHero = heroIndex(world, targetId)
  if otherHero >= 0:
    let other = world.heroes[otherHero]
    return other.team != hero.team and other.hp > 0 and other.state != Dying
  let tower = buildingIndex(world, targetId)
  if tower >= 0:
    let other = world.buildings[tower]
    return other.team != hero.team and other.hp > 0
  for fort in world.forts:
    if fort.id == targetId:
      return fort.team != hero.team and fort.hp > 0
  false

proc applyAttackTarget*(world: World, heroId, targetId: int32): bool =
  ## Applies one hero attack command after validating its target.
  if world.phase == Drafting:
    return world.finishAction(
      heroId, ActionAttackTarget, 0, targetId, 0, ActionDrafting
    )
  navigationWorld = world
  let index = heroIndex(world, heroId)
  if index < 0 or world.heroes[index].state == Dying:
    return world.finishAction(
      heroId,
      ActionAttackTarget,
      0,
      targetId,
      0,
      ActionNotAlive
    )
  let error = world.heroActionError(world.heroes[index])
  if error != NoActionError:
    return world.finishAction(heroId, ActionAttackTarget, 0, targetId, 0, error)
  if targetId == 0:
    world.heroes[index].attackObjectId = 0
    world.heroes[index].attackMoving = false
    return world.finishAction(
      heroId,
      ActionAttackTarget,
      0,
      targetId,
      0,
      NoActionError
    )
  if not world.isEnemyTarget(world.heroes[index], targetId):
    return world.finishAction(
      heroId,
      ActionAttackTarget,
      0,
      targetId,
      0,
      ActionTargetUnavailable
    )
  world.heroes[index].attackMoving = false
  if world.heroes[index].attackObjectId != targetId:
    world.heroes[index].hasMoveTarget = false
  world.heroes[index].attackObjectId = targetId
  world.finishAction(heroId, ActionAttackTarget, 0, targetId, 0, NoActionError)

proc purchaseError(world: World, heroId, itemId: int32): ActionError =
  ## Returns the first failing purchase check without allocating a string.
  if world.phase == Drafting:
    return ActionDrafting
  let index = heroIndex(world, heroId)
  if index < 0 or world.heroes[index].state == Dying:
    return ActionNotAlive
  if world.heroes[index].hp <= 0:
    return ActionNotAlive
  let item = itemFromId(itemId)
  if item == NoItem:
    return ActionUnknownItem
  if not world.heroes[index].canShop:
    return ActionOutsideKeep
  let spec = item.itemSpec
  if world.heroes[index].gold < spec.cost:
    return ActionInsufficientGold
  var empty = false
  for slot in 0 ..< InventorySlots:
    if world.heroes[index].inventory[slot] == NoItem:
      empty = true
    elif world.heroes[index].inventory[slot] == item:
      if spec.kind == Equipment:
        return ActionAlreadyEquipped
      if world.heroes[index].itemCounts[slot] >= MaxItemStack:
        return ActionStackFull
      return NoActionError
  if not empty:
    return ActionInventoryFull
  NoActionError

proc purchaseReason*(world: World, heroId, itemId: int32): string =
  ## Formats the same purchase validator for the shop UI.
  world.purchaseError(heroId, itemId).actionErrorMessage()

proc respawnTicks*(hero: Hero): int32 =
  ## Returns the remaining respawn ticks, including the death animation.
  if hero.state != Dying:
    return 0
  max(
    0'i32,
    min(
      HeroMaxRespawnTicks,
      HeroDeathTicks + HeroRespawnTicks +
        max(0'i32, hero.deaths - 1) * HeroRespawnGrowthTicks
    ) - hero.deathTicks
  )

proc buybackPrice*(world: World, heroId: int32): int32 =
  ## Returns this dead hero's gold price, or zero when buyback is unavailable.
  if world.phase == Drafting:
    return 0
  let index = world.heroIndex(heroId)
  if index < 0 or world.heroes[index].state != Dying or world.gameOver:
    return 0
  max(1'i32, world.heroes[index].deaths) * HeroBuybackGold

proc buybackError(world: World, heroId: int32): ActionError =
  ## Validates a buyback without changing the hero or spending gold.
  if world.phase == Drafting:
    return ActionDrafting
  let index = world.heroIndex(heroId)
  if index < 0:
    return ActionTargetUnavailable
  if world.gameOver:
    return ActionMatchEnded
  if world.heroes[index].state != Dying:
    return ActionNotDead
  if world.heroes[index].gold < world.buybackPrice(heroId):
    return ActionInsufficientGold
  NoActionError

proc buybackReason*(world: World, heroId: int32): string =
  ## Formats the shared buyback validator for the HUD.
  world.buybackError(heroId).actionErrorMessage()

proc applyBuyItem*(world: World, heroId, itemId: int32): bool =
  ## Spends gold to put one validated shop item into a hero inventory.
  let error = world.purchaseError(heroId, itemId)
  if error != NoActionError:
    return world.finishAction(heroId, ActionBuyItem, 0, itemId, 0, error)
  let
    hero = world.heroes[world.heroIndex(heroId)]
    item = itemFromId(itemId)
    spec = item.itemSpec
  var
    stackSlot = -1
    emptySlot = -1
  for slot in 0 ..< InventorySlots:
    if hero.inventory[slot] == item:
      stackSlot = slot
    elif hero.inventory[slot] == NoItem and emptySlot < 0:
      emptySlot = slot
  if spec.kind == Consumable and stackSlot >= 0:
    if hero.itemCounts[stackSlot] >= MaxItemStack:
      return world.finishAction(heroId, ActionBuyItem, 0, itemId, 0,
        ActionStackFull)
  elif spec.kind == Equipment and stackSlot >= 0:
    return world.finishAction(heroId, ActionBuyItem, 0, itemId, 0,
      ActionAlreadyEquipped)
  elif emptySlot < 0:
    return world.finishAction(heroId, ActionBuyItem, 0, itemId, 0,
      ActionInventoryFull)
  let slot = if stackSlot >= 0: stackSlot else: emptySlot
  when defined(replayEvents):
    let beforeCount = hero.itemCounts[slot]
  hero.inventory[slot] = item
  if stackSlot >= 0:
    inc hero.itemCounts[slot]
  else:
    hero.itemCounts[slot] = 1
  when defined(replayEvents):
    world.valueEvent(ItemPurchased, heroId, heroId, EquipmentChange, itemId,
      beforeCount, hero.itemCounts[slot], 1)
    let beforeGold = hero.gold
  hero.gold -= spec.cost
  when defined(replayEvents):
    world.valueEvent(GoldSpent, heroId, heroId, EquipmentChange, itemId,
      beforeGold, hero.gold, -spec.cost)
  hero.refreshHeroStats(world, EquipmentChange, itemId)
  world.finishAction(heroId, ActionBuyItem, 0, itemId, 0, NoActionError)

proc footmanAttackTicks*(clip: int): int32 =
  ## Returns the deterministic footman attack duration in ticks.
  discard clip
  32

proc footmanAttackRange*(kind: CreepKind): int32 =
  ## Returns the reach of a creep's sword or staff attack.
  case kind
  of MeleeCreep:
    FootmanMeleeRange
  of RangedCreep:
    FootmanRangedRange

proc footmanHitTicks*(clip: int): int32 =
  ## Returns the impact tick shared by creep combat and its visual swing.
  footmanAttackTicks(clip) * 45 div 100

proc startSwing(world: World, footman: var Footman) =
  ## Begins a randomly selected attack animation and damage cycle.
  footman.swingClip = attackClips[world.rng.below(2)]
  footman.swingTicks = 0
  footman.damageLanded = false

proc startSwing(world: World, hero: Hero) =
  ## Begins a randomly selected hero melee animation and damage cycle.
  hero.swingClip = heroAttackClips[world.rng.below(2)]
  hero.swingTicks = 0
  hero.damageLanded = false

proc updateTower*(world: World, tower: var Building) =
  ## Reloads independently of acquisition and fires a homing shot when ready.
  if tower.kind == BarracksBuilding or tower.hp <= 0:
    tower.targetId = 0
    tower.attackTicks = 0
    return
  tower.attackTicks = min(TowerAttackTicks, tower.attackTicks + 1)
  let attackRange = TowerAttackRanges[tower.tier]
  var
    targetFootman = footmanIndex(world, tower.targetId)
    targetHero = heroIndex(world, tower.targetId)
  if targetFootman >= 0:
    let footman = world.footmen[targetFootman]
    if not world.hostile(footman, tower.team) or
        footman.state == Dying or footman.hp <= 0 or
        not within(tower.position, footman.position, attackRange) or
        not visible(world, tower.team, footman.position):
      targetFootman = -1
  if targetHero >= 0:
    let hero = world.heroes[targetHero]
    if hero.team == tower.team or hero.state == Dying or
        hero.hp <= 0 or
        not within(tower.position, hero.position, attackRange) or
        not visible(world, tower.team, hero.position):
      targetHero = -1
  if targetFootman < 0 and targetHero < 0:
    var
      bestSquared = int64(attackRange) * attackRange
      bestId = 0'i32
      bestPosition: WorldPoint
    for i, footman in world.footmen:
      if not world.hostile(footman, tower.team) or footman.state == Dying or
          footman.hp <= 0 or
          not visible(world, tower.team, footman.position):
        continue
      let distance = distanceSquared(tower.position, footman.position)
      if distance < bestSquared or
          (distance == bestSquared and targetBefore(footman.position,
            footman.id, bestPosition, bestId, tower.team)):
          bestSquared = distance
          bestId = footman.id
          bestPosition = footman.position
          targetFootman = i
    if targetFootman < 0:
      bestSquared = int64(attackRange) * attackRange
      bestId = 0
      for i in 0 ..< world.heroes.len:
        let hero = world.heroes[i]
        if hero.team == tower.team or hero.state == Dying or hero.hp <= 0:
          continue
        if not visible(world, tower.team, hero.position):
          continue
        let distance = distanceSquared(tower.position, hero.position)
        if distance < bestSquared or
            (distance == bestSquared and targetBefore(hero.position,
              hero.id, bestPosition, bestId, tower.team)):
            bestSquared = distance
            bestId = hero.id
            bestPosition = hero.position
            targetHero = i
  let targetId =
    if targetFootman >= 0: world.footmen[targetFootman].id
    elif targetHero >= 0: world.heroes[targetHero].id
    else: 0'i32
  tower.targetId = targetId
  if targetId == 0 or tower.attackTicks < TowerAttackTicks:
    return
  tower.attackTicks = 0
  var origin = tower.position
  origin.y += 2 * WorldScale
  world.towerShots.add TowerShot(
    sourceId: tower.id, targetId: targetId, team: tower.team,
    damage: TowerDamages[tower.tier], previous: origin, position: origin,
    started: world.tick
  )

proc advanceTowerShots*(world: World) =
  ## Tracks the original living target, ignoring range and vision after firing.
  var write = 0
  for original in world.towerShots:
    var shot = original
    if shot.impact > 0:
      if world.tick - shot.impact >= TowerImpactTicks:
        continue
    elif shot.started < world.tick:
      var target: WorldPoint
      let
        hero = world.heroIndex(shot.targetId)
        creep = world.footmanIndex(shot.targetId)
      if hero >= 0:
        if world.heroes[hero].hp <= 0 or world.heroes[hero].state == Dying:
          continue
        target = world.heroes[hero].position
      elif creep >= 0:
        if world.footmen[creep].hp <= 0 or world.footmen[creep].state == Dying:
          continue
        target = world.footmen[creep].position
      else:
        continue
      target.y += WorldScale
      shot.previous = shot.position
      if within(shot.position, target, TowerShotStep):
        shot.position = target
        shot.impact = world.tick
        world.hitTarget(UnitHit, shot.targetId, shot.damage, shot.sourceId)
      else:
        let
          offset = target - shot.position
          distance = integerSqrt(distanceSquared(shot.position, target))
        shot.position.x += int32(int64(offset.x) * TowerShotStep div distance)
        shot.position.y += int32(int64(offset.y) * TowerShotStep div distance)
        shot.position.z += int32(int64(offset.z) * TowerShotStep div distance)
    world.towerShots[write] = shot
    inc write
  world.towerShots.setLen(write)

proc spellTarget*(world: World, id: int32, value: var WorldObject): bool
  ## Resolves one live unit or structure for spells and camp leashes.

proc initCamps(world: World, map: MapData) =
  ## Assigns three low, two medium, and two high pairs from the map seed.
  var
    pairs: seq[tuple[distance: int64, index: int]]
    rng = initRng(map.preset.seed.int32)
  world.camps.setLen(map.layout.camps.len)
  for i, point in map.layout.camps:
    world.camps[i].center = worldPoint(point)
    if i mod 2 == 0:
      let center = world.camps[i].center
      pairs.add (min(distanceSquared(center, world.forts[0].center),
        distanceSquared(center, world.forts[1].center)), i)
  pairs.sort()
  for rank, pair in pairs:
    let
      tier = if rank < 3: 1 elif rank < 5: 2 else: 3
      count = tier + rng.below(if tier == 3: 3 else: 2)
      appearance = (tier - 1) * 2 + rng.below(2)
    for index in pair.index .. min(pair.index + 1, world.camps.high):
      world.camps[index].tier = tier
      world.camps[index].count = count
      world.camps[index].appearance = appearance

proc spawnCamp(world: World, index: int) =
  ## Places a mirrored group on open camp tiles with fresh lifetime IDs.
  let
    camp = world.camps[index]
    team =
      if camp.center.x < 0 or (camp.center.x == 0 and camp.center.z < 0):
        BlueTeam
      else:
        RedTeam
    direction = if team == BlueTeam: 1'i32 else: -1'i32
    offsets = [(0'i32, 0'i32), (1'i32, 0'i32), (-1'i32, 0'i32),
      (0'i32, 1'i32), (0'i32, -1'i32)]
  var
    occupied: seq[PathTile]
    group: seq[Footman]
  for unit in world.footmen:
    if unit.hp > 0:
      var tile: NavTile
      if navTileAt(unit.position, tile, unit.team):
        occupied.add PathTile(layer: tile.layer.int32,
          x: tile.x.int32, z: tile.z.int32)
  for slot in 0 ..< camp.count:
    let desired = camp.center + WorldPoint(
      x: offsets[slot][0] * WorldScale * direction,
      z: offsets[slot][1] * WorldScale * direction)
    var tile: NavTile
    if not nearestNavTile(
      floorWorldTile(desired.x, team) + mapTiles() div 2,
      floorWorldTile(desired.z, team) + mapTiles() div 2,
      camp.center.y, tile, occupied, reverseSearch = team == RedTeam
    ):
      return
    let point = worldPoint(pathPoint(tile.layer, tile.x, tile.z))
    if not within(point, camp.center, 3 * WorldScale):
      return
    occupied.add PathTile(layer: tile.layer.int32,
      x: tile.x.int32, z: tile.z.int32)
    let leader = slot == 0 and camp.count > 1
    var unit = Footman(
      id: world.nextFootmanId + slot.int32,
      camp: index + 1, campTier: camp.tier, appearance: camp.appearance,
      leader: leader, team: team, kind: MeleeCreep,
      position: point, home: point, navLayer: tile.layer.int32,
      surfaceHint: point.y, state: Marching, animClip: idleClip,
      swingTicks: -1, moveRevision: -1,
      facing: heading(0, direction * WorldScale),
      body: bindBody(point, heading(0, direction * WorldScale),
        if leader: 0.3'fx else: FootmanBodyRadius))
    unit.hp = unit.unitMaxHp
    group.add unit
  world.nextFootmanId += camp.count.int32
  world.footmen.add group
  world.camps[index].started = true
  world.camps[index].state = RestingCamp
  world.camps[index].targetId = 0
  world.camps[index].respawnTick = 0
  when defined(replayEvents):
    for unit in group:
      world.lifecycleEvent(EntitySpawned, 0, unit.id,
        if camp.started: Respawn else: Initialization)

proc campCanSee(unit: Footman, point: WorldPoint, radius: int32): bool =
  ## Tests the mob's own terrain-occluded sight without granting team vision.
  # Exact world range is checked before allowing for rounded tile centers.
  within(unit.position, point, radius * WorldScale) and lineVisible(
    mapTiles().int32, mapTiles().int32,
    sightTerrain.terrainHeights, visionBlockers,
    mapCoordinate(unit.position.x, unit.team),
    mapCoordinate(unit.position.z, unit.team),
    mapCoordinate(point.x, unit.team), mapCoordinate(point.z, unit.team),
    radius + 2, 12
  )

proc returnCamp(world: World, index: int) =
  ## Clears combat and control effects before the survivors walk home.
  world.camps[index].state = ReturningCamp
  world.camps[index].targetId = 0
  for unit in world.footmen.mitems:
    if unit.camp == index + 1 and unit.hp > 0:
      unit.targetId = 0
      unit.targetHeroId = 0
      unit.swingTicks = -1
      unit.damageLanded = false
      unit.controls = default(typeof(unit.controls))
      unit.moveRevision = -1
  when defined(replayEvents):
    world.emit GameEvent(kind: CampReturning, detail: index.int32,
      cause: CampReset, related: -1)

proc provokeCamp(world: World, index: int) =
  ## Starts group combat when a visible hero or lane creep gets too close.
  let camp = world.camps[index]
  var
    targetId, memberId: int32
    targetPoint, memberPoint: WorldPoint
    best = int64.high
  template consider(candidateId: int32, point: WorldPoint) =
    ## Finds the closest visible intruder to any living camp member.
    if within(point, camp.center, NeutralLeash):
      for unit in world.footmen:
        if unit.camp != index + 1 or unit.hp <= 0 or unit.state == Dying:
          continue
        let distance = distanceSquared(unit.position, point)
        if distance > best or
          not unit.campCanSee(point, NeutralAggroTiles):
            continue
        if distance < best or
          targetBefore(point, candidateId, targetPoint, targetId, unit.team) or
          (candidateId == targetId and targetBefore(unit.position, unit.id,
            memberPoint, memberId, unit.team)):
              best = distance
              targetId = candidateId
              targetPoint = point
              memberId = unit.id
              memberPoint = unit.position
  for hero in world.heroes:
    if hero.hp > 0 and hero.state != Dying:
      consider(hero.id, hero.position)
  for unit in world.footmen:
    if unit.camp == 0 and unit.hp > 0 and unit.state != Dying:
      consider(unit.id, unit.position)
  if targetId != 0:
    world.camps[index].state = FightingCamp
    world.camps[index].targetId = targetId
    world.camps[index].lastSeenTick = world.tick
    when defined(replayEvents):
      world.emit GameEvent(kind: CampEngaged,
        actor: world.eventEntity(targetId),
        target: world.eventEntity(memberId), detail: index.int32,
        cause: Proximity, related: -1)

proc updateCamps(world: World) =
  ## Handles whole-group leashes, full resets, and delayed full-camp respawns.
  var activity = newSeq[tuple[alive: int, away, outside: bool]](
    world.camps.len)
  for unit in world.footmen:
    if unit.camp == 0 or unit.hp <= 0:
      continue
    let index = unit.camp - 1
    inc activity[index].alive
    activity[index].away = activity[index].away or
      not within(unit.position, unit.home, WorldScale div 2)
    activity[index].outside = activity[index].outside or
      not within(unit.position, world.camps[index].center, NeutralLeash)
  for index in 0 ..< world.camps.len:
    let camp = world.camps[index]
    if not camp.started:
      if world.tick >= camp.respawnTick:
        world.camps[index].respawnTick = world.tick + TickRate
        world.spawnCamp(index)
      continue
    let
      alive = activity[index].alive
      home = not activity[index].away
      outside = activity[index].outside
    if alive == 0:
      if camp.state != EmptyCamp:
        world.camps[index].state = EmptyCamp
        world.camps[index].targetId = 0
        world.camps[index].respawnTick = world.tick + CampRespawnTicks
      elif world.tick >= camp.respawnTick:
        var blocked = false
        for hero in world.heroes:
          if hero.hp > 0 and hero.state != Dying and
            within(hero.position, camp.center, CampRespawnRadius):
              blocked = true
              break
        if not blocked:
          world.camps[index].respawnTick = world.tick + TickRate
          world.spawnCamp(index)
    elif camp.state == ReturningCamp and home:
      for unit in world.footmen.mitems:
        if unit.camp == index + 1 and unit.hp > 0:
          when defined(replayEvents):
            world.valueEvent(Healing, unit.id, unit.id, CampReset, 0,
              unit.hp, unit.unitMaxHp, unit.unitMaxHp - unit.hp)
          unit.hp = unit.unitMaxHp
          unit.movePath.setLen(0)
          unit.state = Marching
          unit.animClip = idleClip
      world.camps[index].state = RestingCamp
    elif camp.state == FightingCamp:
      var target: WorldObject
      if outside or not world.spellTarget(camp.targetId, target) or
        not target.alive or target.faction == 2 or
        not within(target.position, camp.center, NeutralLeash):
          world.returnCamp(index)
      else:
        var seen = false
        for unit in world.footmen:
          if unit.camp == index + 1 and unit.hp > 0 and
            unit.campCanSee(target.position, 12):
              seen = true
              break
        if seen:
          world.camps[index].lastSeenTick = world.tick
        elif world.tick - camp.lastSeenTick >= 3 * TickRate:
          world.returnCamp(index)
    elif camp.state == RestingCamp:
      world.provokeCamp(index)

proc updateNeutral(world: World, unit: var Footman) =
  ## Runs camp melee combat or the ordinary cached path back home.
  let camp = world.camps[unit.camp - 1]
  unit.targetId = 0
  unit.targetHeroId = 0
  unit.animClip = idleClip
  inc unit.animTicks
  if camp.state == ReturningCamp:
    unit.state = Marching
    if not within(unit.position, unit.home, WorldScale div 2):
      unit.animClip = runClip
      world.followCreepPath(unit, unit.home)
    return
  if camp.state != FightingCamp:
    unit.state = Marching
    unit.swingTicks = -1
    return
  var
    targetId = 0'i32
    point: WorldPoint
    best = int64.high
  template consider(id: int32, at: WorldPoint) =
    ## Chooses the nearest visible hero or lane creep while defending a camp.
    let radius = if id == camp.targetId: 12'i32 else: 5'i32
    if within(at, camp.center, NeutralLeash) and unit.campCanSee(at, radius):
      let distance = distanceSquared(unit.position, at)
      if distance < best or (distance == best and
        targetBefore(at, id, point, targetId, unit.team)):
          targetId = id
          point = at
          best = distance
  for hero in world.heroes:
    if hero.hp > 0 and hero.state != Dying:
      consider(hero.id, hero.position)
  for other in world.footmen:
    if other.camp == 0 and other.hp > 0 and other.state != Dying:
      consider(other.id, other.position)
  if targetId == 0:
    return
  unit.state = Fighting
  if world.heroIndex(targetId) >= 0:
    unit.targetHeroId = targetId
  else:
    unit.targetId = targetId
  if not within(unit.position, point, FootmanMeleeRange):
    unit.swingTicks = -1
    unit.animClip = runClip
    world.followCreepPath(unit, point)
    return
  snapFacing(unit.body, unit.facing, point - unit.position)
  if unit.swingTicks < 0:
    world.startSwing(unit)
  inc unit.swingTicks
  if not unit.damageLanded and unit.swingTicks >= footmanHitTicks(unit.swingClip):
    unit.damageLanded = true
    world.hitTarget(UnitHit, targetId, unit.unitDamage, unit.id)
  if unit.swingTicks >= footmanAttackTicks(unit.swingClip):
    world.startSwing(unit)
  unit.animClip = unit.swingClip
  unit.animTicks = max(unit.swingTicks, 0)

proc updateFootman(world: World, footman: var Footman) =
  ## Advances one footman's movement, target selection, combat, and animation.
  footman.velocity = Heading()
  if footman.state == Dying:
    inc footman.deathTicks
    footman.animClip = deathClip
    footman.animTicks = min(footman.deathTicks, FootmanDeathTicks)
    return

  if footman.hp <= 0:
    footman.state = Dying
    footman.controls = default(typeof(footman.controls))
    footman.deathTicks = 0
    return

  if footman.camp == 0:
    footman.advanceWaypoints()
  if footman.controls[StunControl].ends > world.tick:
    footman.animClip = idleClip
    inc footman.animTicks
    return
  let start = footman.position
  defer:
    footman.velocity = heading(
      footman.position.x - start.x,
      footman.position.z - start.z
    )

  if footman.camp > 0:
    world.updateNeutral(footman)
    return

  # Acquire: keep a live target while it stays in extended range, otherwise
  # take the nearest visible enemy; with none, batter the fort when close.
  var
    targetFootman = footmanIndex(world, footman.targetId)
    targetHero = heroIndex(world, footman.targetHeroId)
    targetBuilding = buildingIndex(world, footman.targetBuildingId)
  if targetFootman >= 0:
    let other = world.footmen[targetFootman]
    if not world.hostile(other, footman.team) or
        not visible(world, footman.team, other.position) or
        not within(
          footman.position,
          other.position,
          FootmanSightRadius * 8 div 5
        ):
      targetFootman = -1
  if targetHero >= 0:
    let hero = world.heroes[targetHero]
    if hero.state == Dying or hero.hp <= 0 or
        not visible(world, footman.team, hero.position) or
        not within(
          footman.position,
          hero.position,
          FootmanSightRadius * 8 div 5
        ):
      targetHero = -1
  if targetBuilding >= 0:
    let tower = world.buildings[targetBuilding]
    if not buildingExposed(world, tower) or
        not visible(world, footman.team, tower.position) or
        not within(
          footman.position,
          tower.position,
          FootmanTowerSightRadius * 8 div 5
        ):
      targetBuilding = -1
  if targetFootman < 0 and targetHero < 0 and targetBuilding < 0:
    var
      bestSquared = int64(FootmanSightRadius) * FootmanSightRadius
      bestId = 0'i32
      bestPosition: WorldPoint
    for i, other in world.footmen:
      if not world.hostile(other, footman.team):
        continue
      if not visible(world, footman.team, other.position):
        continue
      let distance = distanceSquared(footman.position, other.position)
      if distance < bestSquared or (distance == bestSquared and bestId != 0 and
        targetBefore(other.position, other.id,
          bestPosition, bestId, footman.team)):
          bestSquared = distance
          bestId = other.id
          bestPosition = other.position
          targetFootman = i
    for i in 0 ..< world.heroes.len:
      let hero = world.heroes[i]
      if hero.team == footman.team or hero.state == Dying or hero.hp <= 0:
        continue
      if not visible(world, footman.team, hero.position):
        continue
      let distance = distanceSquared(footman.position, hero.position)
      if distance < bestSquared or (distance == bestSquared and
        targetFootman < 0 and bestId != 0 and targetBefore(hero.position,
          hero.id, bestPosition, bestId, footman.team)):
          bestSquared = distance
          bestId = hero.id
          bestPosition = hero.position
          targetFootman = -1
          targetHero = i
  if targetFootman < 0 and targetHero < 0 and targetBuilding < 0:
    let tower = nextEnemyBuilding(world, footman.team, footman.lane, footman.position)
    if tower.id != 0 and within(
        footman.position,
        tower.position,
        FootmanTowerSightRadius
    ) and visible(world, footman.team, tower.position):
      targetBuilding = buildingIndex(world, tower.id)
  footman.targetId =
    if targetFootman >= 0: world.footmen[targetFootman].id else: 0
  footman.targetHeroId =
    if targetHero >= 0: world.heroes[targetHero].id else: 0
  footman.targetBuildingId =
    if targetBuilding >= 0: world.buildings[targetBuilding].id else: 0
  let fortIndex = enemyFort(footman.team)
  footman.attackingFort = targetFootman < 0 and targetHero < 0 and
    targetBuilding < 0 and
    fortExposed(world, world.forts[fortIndex].team) and
    visible(world, footman.team, world.forts[fortIndex].center) and
    within(footman.position, world.forts[fortIndex].center, FortRange)

  if targetFootman >= 0 or targetHero >= 0 or
      targetBuilding >= 0 or footman.attackingFort:
    footman.state = Fighting
    let targetPosition =
      if targetFootman >= 0: world.footmen[targetFootman].position
      elif targetHero >= 0: world.heroes[targetHero].position
      elif targetBuilding >= 0:
        buildingAim(world.buildings[targetBuilding], footman.position)
      else: world.forts[fortIndex].center
    footman.surfaceHint = targetPosition.y
    let
      offset = targetPosition - footman.position
      # Fort walls sit well inside FortRange: close enough already counts
      # as being at arm's length of the enemy god's walls.
      inRange =
        if targetFootman >= 0 or targetHero >= 0:
          within(
            footman.position,
            targetPosition,
            footman.kind.footmanAttackRange
          )
        elif targetBuilding >= 0:
          within(
            footman.position,
            targetPosition,
            max(TowerSiegeRange, footman.kind.footmanAttackRange)
          )
        else: true
    if not inRange:
      footman.swingTicks = -1
      footman.animClip = runClip
      inc footman.animTicks
      world.followCreepPath(footman, targetPosition)
    else:
      snapFacing(footman.body, footman.facing, offset)
      if footman.swingTicks < 0:
        startSwing(world, footman)
      let duration = footmanAttackTicks(footman.swingClip)
      inc footman.swingTicks
      if not footman.damageLanded and
          footman.swingTicks >= footmanHitTicks(footman.swingClip):
        footman.damageLanded = true
        if targetFootman >= 0:
          world.hitTarget(UnitHit, world.footmen[targetFootman].id,
            FootmanDamage, footman.id)
        elif targetHero >= 0:
          world.hitTarget(UnitHit, world.heroes[targetHero].id,
            FootmanDamage, footman.id)
        elif targetBuilding >= 0:
          world.hitTarget(StructureHit, world.buildings[targetBuilding].id,
            FootmanDamage, footman.id)
        else:
          world.hitTarget(GodHit, world.forts[fortIndex].id,
            FootmanDamage, footman.id)
      if footman.swingTicks >= duration:
        startSwing(world, footman)
      footman.animClip = footman.swingClip
      footman.animTicks = max(footman.swingTicks, 0)
    return

  footman.state = Marching
  footman.swingTicks = -1
  footman.animClip = runClip
  inc footman.animTicks
  var goal = world.forts[enemyFort(footman.team)].center
  if footman.waypointIndex < laneWorldPaths[footman.lane].len:
    goal = footman.currentWaypoint
  else:
    let objective = world.nextEnemyBuilding(
      footman.team, footman.lane, footman.position
    )
    if objective.id != 0:
      goal = buildingAim(objective, footman.position)
  world.followCreepPath(footman, goal)

proc respawn(world: World, hero: Hero) =
  ## Restores a fallen hero and records the new life's resource adjustments.
  when defined(replayEvents):
    let
      beforeHp = hero.hp
      beforeMana = hero.mana
  hero.place(hero.spawnPosition)
  hero.applyBody()
  hero.hp = hero.maxHp
  hero.mana = hero.maxMana
  hero.state = Marching
  hero.waypointIndex = 0
  hero.targetFootmanId = 0
  hero.targetHeroId = 0
  hero.targetBuildingId = 0
  hero.attackingFort = false
  hero.attackObjectId = 0
  hero.attackMoving = false
  hero.hasMoveTarget = false
  hero.movePath.setLen(0)
  hero.movePathIndex = 0
  hero.swingTicks = -1
  hero.animClip = heroRunClip
  hero.animTicks = 0
  hero.deathTicks = 0
  hero.surfaceHint = hero.spawnPosition.y
  hero.portalEnds = 0
  hero.portalTowerId = 0
  hero.controls = default(typeof(hero.controls))
  hero.recoveryItems = default(typeof(hero.recoveryItems))
  hero.recoveryStarted = default(typeof(hero.recoveryStarted))
  hero.recoveryApplied = default(typeof(hero.recoveryApplied))
  hero.navLayer = bindNavLayer(hero.spawnPosition, hero.team)
  for slot in HeroAbilitySlot:
    hero.cooldowns[slot] = 0
  hero.spellsReady = false
  when defined(replayEvents):
    world.valueEvent(ManaChanged, hero.id, hero.id, Respawn, 0,
      beforeMana, hero.mana, 0)
    world.valueEvent(HealthAdjusted, hero.id, hero.id, Respawn, 0,
      beforeHp, hero.hp, 0)
    world.lifecycleEvent(EntityRespawned, 0, hero.id, Respawn)

proc initHeroCharges(hero: Hero) =
  ## Starts a new life with every learned ability fully charged.
  for slot in HeroAbilitySlot:
    hero.charges[slot] = heroAbility(hero.class, slot).abilitySpec(
      hero.abilityLevels[slot]
    ).charges
    hero.recharges[slot] = 0
  hero.spellsReady = true

proc applyBuyback*(world: World, heroId: int32): bool =
  ## Spends a fallen hero's gold and immediately restores them at spawn.
  let error = world.buybackError(heroId)
  if error != NoActionError:
    return world.finishAction(heroId, ActionBuyback, 0, 0, 0, error)
  let
    hero = world.heroes[world.heroIndex(heroId)]
    price = world.buybackPrice(heroId)
  when defined(replayEvents):
    let beforeGold = hero.gold
  hero.gold -= price
  when defined(replayEvents):
    world.valueEvent(
      GoldSpent,
      heroId,
      heroId,
      Buyback,
      0,
      beforeGold,
      hero.gold,
      -price
    )
  world.respawn(hero)
  hero.initHeroCharges()
  world.finishAction(heroId, ActionBuyback, 0, 0, 0, NoActionError)

proc battleTick*(world: World): int32 {.raises: [].} =
  ## Excludes drafting from the elapsed battle clock.
  world.tick - world.draftTicks

proc finished*(game: Game): bool =
  ## Ends a battle on victory or after its full configured battle duration.
  game.world.gameOver or (game.world.phase == Playing and
    game.world.battleTick() >= game.config.maxTicks)

proc outcome*(world: World): string =
  ## Distinguishes a victorious side, simultaneous god deaths, and a timeout.
  if world.draw:
    "draw"
  elif world.gameOver:
    $world.winner
  else:
    "time_limit"

proc durationTicks*(game: Game): int32 =
  ## Includes the remaining pick deadlines before the full battle budget.
  if game.replayMode:
    return game.replayData.hashes.len.int32
  let world = game.world
  result = game.config.maxTicks + world.draftTicks
  if world.phase == Drafting:
    result += (world.draftOrder.len - world.draftTurn).int32 *
      DraftPickTicks - world.draftTurnTicks

proc draftTicksLeft*(world: World): int32 =
  ## Returns the active pick's remaining time, or zero during battle.
  if world.phase == Drafting:
    return max(DraftPickTicks - world.draftTurnTicks, 0)

proc draftHeroId*(world: World): int32 =
  ## Returns the player currently picking, or zero after drafting.
  if world.phase == Drafting and world.draftTurn < world.draftOrder.len:
    return world.heroes[world.draftOrder[world.draftTurn]].id

proc draftedClass*(world: World, heroId: int32): int32 =
  ## Reads a public pick by player ID, or minus one before their pick.
  let index = world.heroIndex(heroId)
  if index < 0 or not world.heroes[index].drafted:
    return -1
  world.heroes[index].class.ord.int32

proc heroAvailable*(world: World, classId: int32): bool =
  ## Checks the shared hero pool without exposing any hidden world state.
  if classId < 0 or classId > HeroClass.high.ord:
    return false
  for hero in world.heroes:
    if hero.drafted and hero.class.ord == classId:
      return false
  true

proc initDraft(world: World) =
  ## Alternates teams, preserving each team's original spawn order.
  world.drafting = true
  world.phase = Drafting
  var
    team = Team(world.rng.below(2))
    next: array[Team, int]
  while world.draftOrder.len < world.heroes.len:
    while next[team] < world.heroes.len:
      let index = next[team]
      inc next[team]
      if world.heroes[index].team == team:
        world.draftOrder.add(index)
        break
    team = Team(1 - team.ord)
  for hero in world.heroes:
    hero.drafted = false
    hero.animClip = heroIdleClip
  if world.draftOrder.len == 0:
    world.phase = Playing

proc applyDraft*(
    world: World, heroId, classId: int32, cause = Command
): bool =
  ## Locks a unique hero for the active player and advances the draft.
  let error =
    if world.phase != Drafting: ActionNotDrafting
    elif world.draftHeroId() != heroId: ActionNotDraftTurn
    elif classId < 0 or classId > HeroClass.high.ord: ActionUnknownHero
    elif not world.heroAvailable(classId): ActionHeroTaken
    else: NoActionError
  if error != NoActionError:
    return world.finishAction(heroId, ActionDraft, 0, classId, 0, error)
  let hero = world.heroes[world.heroIndex(heroId)]
  hero.class = HeroClass(classId)
  hero.drafted = true
  hero.maxHp = heroMaxHp(hero.class, hero.level)
  hero.hp = hero.maxHp
  hero.maxMana = heroMaxMana(hero.class, hero.level)
  hero.mana = hero.maxMana
  hero.initHeroCharges()
  world.scriptObjectsTick = -1
  inc world.draftTurn
  world.draftTurnTicks = 0
  if world.draftTurn == world.draftOrder.len:
    world.phase = Playing
    world.heroTurnTicks = 0
  when defined(replayEvents):
    world.emit GameEvent(
      kind: HeroDrafted, cause: cause, actor: world.eventEntity(heroId),
      target: world.eventEntity(heroId), detail: classId, related: -1
    )
  world.finishAction(heroId, ActionDraft, 0, classId, 0, NoActionError)

proc tickHeroCooldowns(world: World, hero: Hero) =
  ## Advances spell cooldowns and restores spent charges one at a time.
  if not hero.spellsReady:
    hero.initHeroCharges()
  for slot in HeroAbilitySlot:
    if hero.cooldowns[slot] > 0:
      dec hero.cooldowns[slot]
    if hero.recharges[slot] > 0:
      dec hero.recharges[slot]
      if hero.recharges[slot] == 0:
        let spec = heroAbility(hero.class, slot).abilitySpec(
          hero.abilityLevels[slot]
        )
        hero.charges[slot] = min(hero.charges[slot] + 1, spec.charges)
        if hero.charges[slot] < spec.charges:
          hero.recharges[slot] = spec.rechargeTicks

proc regenHeroMana(world: World, hero: Hero, tick: int32) =
  ## Restores a small amount of mana on a stable cadence.
  if tick mod 6 == 0 and hero.mana < hero.maxMana:
    world.restoreMana(hero, 1, hero.id, Regeneration, 0)

proc recoverPotion(world: World, hero: Hero, kind: RecoveryKind) =
  ## Applies each earned point once, including when replacing an expiring dose.
  let item = hero.recoveryItems[kind]
  if item == NoItem:
    return
  let
    spec = item.itemSpec
    elapsed = clamp(world.tick - hero.recoveryStarted[kind],
      0'i32, spec.recoveryTicks)
    total = if kind == HealthRecovery: spec.heal else: spec.restore
    earned = total * elapsed div spec.recoveryTicks
    amount = earned - hero.recoveryApplied[kind]
  hero.recoveryApplied[kind] = earned
  if amount > 0:
    if kind == HealthRecovery:
      world.healHero(hero, amount, hero.id, ItemEffect, item.ord.int32)
    else:
      world.restoreMana(hero, amount, hero.id, ItemEffect, item.ord.int32)
  if elapsed == spec.recoveryTicks:
    hero.recoveryItems[kind] = NoItem
    hero.recoveryStarted[kind] = 0
    hero.recoveryApplied[kind] = 0
    when defined(replayEvents):
      world.emit GameEvent(
        kind: RecoveryCompleted, actor: world.eventEntity(hero.id),
        target: world.eventEntity(hero.id), cause: ItemEffect,
        detail: item.ord.int32, related: -1
      )

proc recoverHero(world: World, hero: Hero) =
  ## Applies potion regeneration and fast recovery on the own spawn floor.
  for kind in RecoveryKind:
    world.recoverPotion(hero, kind)
  if hero.inOwnSpawn:
    const Duration = SpawnRecoverySeconds * TickRate
    let
      phase = world.tick mod Duration
      health = hero.maxHp * (phase + 1) div Duration -
        hero.maxHp * phase div Duration
      mana = hero.maxMana * (phase + 1) div Duration -
        hero.maxMana * phase div Duration
    world.healHero(hero, health, hero.id, Regeneration, 0)
    world.restoreMana(hero, mana, hero.id, Regeneration, 0)

proc rewardDeath(world: World, target, source: int32) =
  ## Pays one victim's rewards after simultaneous damage has finished.
  if world.resolvingHits:
    world.rewards.add DeathReward(target: target, source: source)
    return
  let creep = world.footmanIndex(target)
  if creep >= 0:
    world.gainCreepRewards(world.footmen[creep], source)
    return
  let killer = world.heroIndex(source)
  if killer < 0:
    return
  let
    victim = world.heroIndex(target)
    xp = if victim >= 0: HeroXpReward else: TowerXpReward
    gold = if victim >= 0: HeroGoldReward else: TowerGoldReward
  world.gainRewards(world.heroes[killer], xp, gold, target)
  world.stats.add(killer, GoldMetric, gold)

proc hitTarget(
    world: World, kind: HitKind, target, damage, source: int32,
    cause = BasicAttack, detail = 0'i32
) =
  ## Collects damage without removing another unit's turn in this tick.
  if damage <= 0:
    return
  if world.collectingHits:
    let
      sourceKey = world.hitKey(source)
      targetKey = world.hitKey(target)
    var priority = HashySeed
    priority.addHashy(world.matchSeed)
    priority.addHashy(world.tick)
    for value in targetKey.fields:
      priority.addHashy(value)
    for value in sourceKey.fields:
      priority.addHashy(value)
    # Corresponding fights use equal inputs even with different actor IDs.
    priority = (priority xor (priority shr 16)) * 0x85ebca6b'u32
    priority = (priority xor (priority shr 13)) * 0xc2b2ae35'u32
    priority = priority xor (priority shr 16)
    world.hits.add CombatHit(kind: kind, target: target, source: source,
      damage: damage, cause: cause, detail: detail, priority: priority,
      sourceKey: sourceKey)
    return
  case kind
  of UnitHit:
    let creep = world.footmanIndex(target)
    if creep >= 0:
      if world.footmen[creep].hp > 0 and not world.returning(world.footmen[creep]):
        let camp = world.footmen[creep].camp
        if camp > 0:
          if world.camps[camp - 1].state == RestingCamp:
            when defined(replayEvents):
              world.emit GameEvent(kind: CampEngaged,
                actor: world.eventEntity(source),
                target: world.eventEntity(target),
                detail: (camp - 1).int32, cause: cause, related: -1)
          world.camps[camp - 1].state = FightingCamp
          world.camps[camp - 1].targetId = source
          world.camps[camp - 1].lastSeenTick = world.tick
        world.applyDamage(world.footmen[creep], damage, source, cause, detail)
        if cause == AbilityEffect:
          let spec = BaseAbilitySpecs[Ability(detail)]
          world.applyControl(target, spec.control, spec.controlTicks,
            source, detail)
      return
    let victim = world.heroIndex(target)
    if victim < 0 or world.heroes[victim].hp <= 0:
      return
    let killer = world.heroIndex(source)
    world.applyDamage(world.heroes[victim], damage, source, cause, detail)
    if cause == AbilityEffect:
      let spec = BaseAbilitySpecs[Ability(detail)]
      world.applyControl(target, spec.control, spec.controlTicks, source, detail)
    let killed = world.heroes[victim].hp <= 0
    world.stats.hitHero(killer, victim, world.tick, TickRate, killed)
    if killed:
      # Every accepted hit is hostile, including tower and creep hits.
      let victimTeam = world.heroes[victim].team
      let sourceCreep = world.footmanIndex(source)
      if sourceCreep >= 0 and world.footmen[sourceCreep].camp > 0:
        inc world.teamHeroDeaths[victimTeam.ord]
      else:
        world.recordHeroKill(Team(1 - victimTeam.ord), victimTeam)
      if killer >= 0:
        world.rewardDeath(target, source)
  of StructureHit:
    let building = world.buildingIndex(target)
    if building >= 0 and world.buildings[building].hp > 0:
      world.damageBuilding(building, damage, source, cause, detail)
      if world.buildings[building].hp <= 0:
        world.rewardDeath(target, source)
  of GodHit:
    for i, fort in world.forts:
      if fort.id == target and fort.hp > 0:
        world.damageFort(i, damage, source, cause, detail)
        break

proc applyHeroHit(
    world: World,
    hero: Hero,
    damage: int32,
    targetFootman, targetHero, targetBuilding, fortIndex: int,
    cause = BasicAttack, detail = 0'i32
) =
  ## Submits one hero impact through the shared combat phase.
  if targetFootman >= 0:
    world.hitTarget(UnitHit, world.footmen[targetFootman].id,
      damage, hero.id, cause, detail)
  elif targetHero >= 0:
    world.hitTarget(UnitHit, world.heroes[targetHero].id,
      damage, hero.id, cause, detail)
  elif targetBuilding >= 0:
    world.hitTarget(StructureHit, world.buildings[targetBuilding].id,
      damage, hero.id, cause, detail)
  elif fortIndex >= 0:
    world.hitTarget(GodHit, world.forts[fortIndex].id,
      damage, hero.id, cause, detail)

proc die(world: World, hero: Hero) =
  ## Starts a hero's death once after every attack has been collected.
  world.interruptPortal(hero)
  hero.state = Dying
  hero.controls = default(typeof(hero.controls))
  inc hero.deaths
  hero.deathTicks = 0
  hero.targetFootmanId = 0
  hero.targetHeroId = 0
  hero.targetBuildingId = 0
  hero.attackingFort = false
  hero.attackObjectId = 0
  hero.attackMoving = false
  hero.hasMoveTarget = false

proc resolveCombat(world: World) =
  ## Resolves hits, then deaths, then rewards without cancelling collected hits.
  world.collectingHits = false
  world.resolvingHits = true
  world.rewardAlive.setLen(world.heroes.len)
  for i, hero in world.heroes:
    world.rewardAlive[i] = hero.hp > 0 and hero.state != Dying
  # Same-tick credit uses a tick-varying priority, never container order.
  world.hits.sort(proc(first, second: CombatHit): int =
    ## Gives simultaneous hit attribution a reproducible total ordering.
    cmp((first.target, first.priority, first.sourceKey, first.source,
      first.cause, first.detail, first.damage),
      (second.target, second.priority, second.sourceKey, second.source,
      second.cause, second.detail, second.damage))
  )
  # All same-tick contributors count for assists, even after a lethal hit.
  for hit in world.hits:
    let
      victim = world.heroIndex(hit.target)
      killer = world.heroIndex(hit.source)
    if victim >= 0 and killer >= 0:
      world.stats.hitHero(killer, victim, world.tick, TickRate, false)
  for hit in world.hits:
    world.hitTarget(hit.kind, hit.target, hit.damage, hit.source,
      hit.cause, hit.detail)
  world.hits.setLen(0)
  world.resolvingHits = false
  for creep in world.footmen.mitems:
    if creep.hp <= 0 and creep.state != Dying:
      creep.state = Dying
      creep.controls = default(typeof(creep.controls))
      creep.deathTicks = 0
  for hero in world.heroes:
    if hero.hp <= 0 and hero.state != Dying:
      world.die(hero)
    elif hero.attackObjectId != 0 and
      not world.isEnemyTarget(hero, hero.attackObjectId):
        hero.attackObjectId = 0
        hero.targetFootmanId = 0
        hero.targetHeroId = 0
        hero.targetBuildingId = 0
        hero.attackingFort = false
        if not hero.attackMoving:
          hero.stopHeroPath()
  for reward in world.rewards:
    world.rewardDeath(reward.target, reward.source)
  world.rewards.setLen(0)
  world.rewardAlive.setLen(0)

proc consumeItem(world: World, hero: Hero, slot: int) =
  ## Removes one charge and records consumption before an empty stack is lost.
  when defined(replayEvents):
    let
      item = hero.inventory[slot]
      before = hero.itemCounts[slot]
  dec hero.itemCounts[slot]
  if hero.itemCounts[slot] <= 0:
    hero.inventory[slot] = NoItem
    hero.itemCounts[slot] = 0
  when defined(replayEvents):
    world.valueEvent(ItemConsumed, hero.id, hero.id, ItemEffect,
      item.ord.int32, before, hero.itemCounts[slot], -1)

proc canHitTarget(
    world: World,
    hero: Hero,
    targetFootman, targetHero, targetBuilding, fortIndex: int,
    range: int32
): bool =
  ## Requires a living, visible, exposed enemy within the strike's range.
  var position: WorldPoint
  if targetFootman >= 0:
    let target = world.footmen[targetFootman]
    if not world.hostile(target, hero.team, engageResting = true):
      return false
    position = target.position
  elif targetHero >= 0:
    let target = world.heroes[targetHero]
    if target.team == hero.team or target.hp <= 0 or target.state == Dying:
      return false
    position = target.position
  elif targetBuilding >= 0:
    let target = world.buildings[targetBuilding]
    if target.team == hero.team or not world.buildingExposed(target):
      return false
    position = target.position
  elif fortIndex >= 0:
    let target = world.forts[fortIndex]
    if target.team == hero.team or target.hp <= 0 or
      not world.fortExposed(target.team):
        return false
    position = target.center
  else:
    return false
  let aim =
    if targetBuilding >= 0: buildingAim(world.buildings[targetBuilding], hero.position)
    else: position
  within(hero.position, aim, range) and world.visible(hero.team, position)

proc applyUseItem*(world: World, heroId, slotId: int32): bool =
  ## Spends one consumable for a heal, mana restore, or poison strike.
  if world.phase == Drafting:
    return world.finishAction(
      heroId, ActionUseItem, slotId, slotId, 0, ActionDrafting
    )
  let
    index = heroIndex(world, heroId)
    slot = int(slotId)
  if index < 0 or world.heroes[index].state == Dying:
    return world.finishAction(
      heroId,
      ActionUseItem,
      slotId,
      slotId,
      0,
      ActionNotAlive
    )
  let error = world.heroActionError(world.heroes[index])
  if error != NoActionError:
    return world.finishAction(
      heroId,
      ActionUseItem,
      slotId,
      slotId,
      0,
      error
    )
  if slot < 0 or slot >= InventorySlots:
    return world.finishAction(
      heroId,
      ActionUseItem,
      slotId,
      slotId,
      0,
      ActionInvalidSlot
    )
  let item = world.heroes[index].inventory[slot]
  if item == NoItem:
    return world.finishAction(
      heroId,
      ActionUseItem,
      slotId,
      slotId,
      0,
      ActionEmptySlot
    )
  let spec = item.itemSpec
  if item == PortalScroll:
    return world.finishAction(
      heroId, ActionUseItem, slotId, slotId, 0, ActionInvalidPoint
    )
  if spec.kind != Consumable:
    return world.finishAction(
      heroId,
      ActionUseItem,
      slotId,
      slotId,
      0,
      ActionNotConsumable
    )
  let hero = world.heroes[index]
  if hero.consumableCooldown(item, world.tick) > 0:
    return world.finishAction(
      heroId, ActionUseItem, slotId, slotId, 0, ActionCooldown
    )
  if spec.heal > 0:
    if world.heroes[index].hp >= world.heroes[index].maxHp:
      return world.finishAction(
        heroId,
        ActionUseItem,
        slotId,
        slotId,
        0,
        ActionFullHealth
      )
    if spec.recoveryTicks == 0:
      world.healHero(hero, spec.heal, heroId, ItemEffect, item.ord.int32)
  elif spec.restore > 0:
    if world.heroes[index].mana >= world.heroes[index].maxMana:
      return world.finishAction(
        heroId,
        ActionUseItem,
        slotId,
        slotId,
        0,
        ActionFullMana
      )
    if spec.recoveryTicks == 0:
      world.restoreMana(hero, spec.restore, heroId, ItemEffect, item.ord.int32)
  elif spec.strike > 0:
    let targetId = world.heroes[index].attackObjectId
    if targetId == 0:
      return world.finishAction(
        heroId,
        ActionUseItem,
        slotId,
        slotId,
        0,
        ActionTargetUnavailable
      )
    var
      targetFootman = footmanIndex(world, targetId)
      targetHero = heroIndex(world, targetId)
      targetBuilding = buildingIndex(world, targetId)
      fortIndex = -1
    if targetFootman < 0 and targetHero < 0 and targetBuilding < 0:
      for i, fort in world.forts:
        if fort.id == targetId:
          fortIndex = i
          break
    if targetFootman < 0 and targetHero < 0 and
        targetBuilding < 0 and fortIndex < 0:
      return world.finishAction(
        heroId,
        ActionUseItem,
        slotId,
        slotId,
        0,
        ActionTargetUnavailable
      )
    if not world.canHitTarget(
      world.heroes[index],
      targetFootman,
      targetHero,
      targetBuilding,
      fortIndex,
      heroAttackRange(world.heroes[index].class)
    ):
      return world.finishAction(
        heroId,
        ActionUseItem,
        slotId,
        slotId,
        0,
        ActionTargetUnavailable
      )
    applyHeroHit(
      world,
      world.heroes[index],
      spec.strike,
      targetFootman,
      targetHero,
      targetBuilding,
      fortIndex,
      ItemEffect,
      item.ord.int32
    )
  else:
    return world.finishAction(
      heroId,
      ActionUseItem,
      slotId,
      slotId,
      0,
      ActionNotConsumable
    )
  if spec.heal > 0 or spec.restore > 0:
    let kind = if spec.heal > 0: HealthRecovery else: ManaRecovery
    world.recoverPotion(hero, kind)
    hero.potionCooldownEnds[kind] = world.tick + spec.cooldownTicks
    if spec.recoveryTicks > 0:
      hero.recoveryItems[kind] = item
      hero.recoveryStarted[kind] = world.tick
      hero.recoveryApplied[kind] = 0
      when defined(replayEvents):
        world.emit GameEvent(
          kind: RecoveryStarted, actor: world.eventEntity(heroId),
          target: world.eventEntity(heroId), cause: ItemEffect,
          detail: item.ord.int32, related: -1
        )
  world.consumeItem(hero, slot)
  world.finishAction(heroId, ActionUseItem, slotId, slotId, 0, NoActionError)

proc applyUseItemAt*(
    world: World,
    heroId, slotId, mapX, mapY: int32,
    offset = FixedVec2Zero
): bool =
  ## Spends a scroll and channels toward an open allied tower landing.
  if world.phase == Drafting:
    return world.finishAction(
      heroId, ActionUseItemAt, slotId, mapX, mapY, ActionDrafting, offset
    )
  let hero = world.heroById(heroId)
  var error = world.heroActionError(hero, movement = true)
  if hero.id == 0:
    error = ActionNotAlive
  if error == NoActionError:
    if slotId < 0 or slotId >= InventorySlots:
      error = ActionInvalidSlot
    elif hero.inventory[slotId] == NoItem:
      error = ActionEmptySlot
    elif hero.inventory[slotId] != PortalScroll:
      error = ActionNotConsumable
    elif hero.portalCooldownEnds > world.tick:
      error = ActionCooldown
    elif mapX < 0 or mapX >= mapTiles() or mapY < 0 or
      mapY >= mapTiles() or not offset.validTileOffset:
        error = ActionInvalidPoint
  var
    destination: WorldPoint
    towerId: int32
  if error == NoActionError:
    let aim = WorldPoint(
      x: (mapX - mapTiles().int32 div 2) * WorldScale + WorldScale div 2 +
        tilesToWorld(offset.x, WorldScale),
      z: (mapY - mapTiles().int32 div 2) * WorldScale + WorldScale div 2 +
        tilesToWorld(offset.y, WorldScale)
    )
    if not world.portalLanding(hero.team, aim, destination, towerId):
      error = ActionTargetUnavailable
  if error != NoActionError:
    return world.finishAction(
      heroId, ActionUseItemAt, slotId, mapX, mapY, error, offset
    )
  world.consumeItem(hero, slotId.int)
  hero.stopHeroPath()
  hero.attackObjectId = 0
  hero.attackMoving = false
  hero.targetFootmanId = 0
  hero.targetHeroId = 0
  hero.targetBuildingId = 0
  hero.attackingFort = false
  hero.swingTicks = -1
  hero.state = Marching
  hero.animClip = heroIdleClip
  hero.animTicks = 0
  hero.portalEnds = world.tick + PortalChannelTicks
  hero.portalDestination = destination
  hero.portalTowerId = towerId
  when defined(replayEvents):
    world.lifecycleEvent(PortalStarted, hero.id, towerId, ItemEffect)
  world.finishAction(
    heroId, ActionUseItemAt, slotId, mapX, mapY, NoActionError, offset
  )

proc spellTarget*(world: World, id: int32, value: var WorldObject): bool =
  ## Resolves an existing object without depending on the script query cache.
  let hero = heroIndex(world, id)
  if hero >= 0:
    let target = world.heroes[hero]
    value = WorldObject(id: id, team: target.team, position: target.position,
      hp: target.hp, alive: target.hp > 0 and target.state != Dying)
    return true
  let footman = footmanIndex(world, id)
  if footman >= 0:
    let target = world.footmen[footman]
    value = WorldObject(id: id,
      kind: (if target.camp > 0: NeutralObjectKind else: FootmanObjectKind),
      team: target.team, position: target.position, hp: target.hp,
      alive: target.hp > 0 and target.state != Dying and
        not world.returning(target))
    return true
  let tower = buildingIndex(world, id)
  if tower >= 0:
    let target = world.buildings[tower]
    value = WorldObject(id: id, team: target.team, position: target.position,
      hp: target.hp, alive: world.buildingExposed(target))
    return true
  for fort in world.forts:
    if fort.id == id:
      value = WorldObject(id: id, team: fort.team, position: fort.center,
        hp: fort.hp, alive: fort.hp > 0 and world.fortExposed(fort.team))
      return true
  false

proc hitSpellTarget(world: World, spell: SpellCast, id: int32) =
  ## Applies one effect, checking living targets and structure protection again.
  let
    caster = heroIndex(world, spell.heroId)
    spec = spell.ability.abilitySpec(spell.level)
  var target: WorldObject
  if caster < 0 or not world.spellTarget(id, target) or not target.alive:
    return
  let hero = world.heroes[caster]
  if spec.kind == Strike:
    if target.faction == hero.team.ord.int32:
      return
    var fortIndex = -1
    for i, fort in world.forts:
      if fort.id == id:
        fortIndex = i
    world.applyHeroHit(
      hero, spec.damage, world.footmanIndex(id), world.heroIndex(id),
      world.buildingIndex(id), fortIndex, AbilityEffect, spell.ability.ord.int32
    )
  elif target.faction == hero.team.ord.int32:
    let index = world.heroIndex(id)
    if index >= 0:
      let ally = world.heroes[index]
      world.healHero(ally, spec.heal, hero.id, AbilityEffect,
        spell.ability.ord.int32)
      world.restoreMana(ally, spec.restore, hero.id, AbilityEffect,
        spell.ability.ord.int32)

proc spellContains*(spell: SpellCast, area: FxArea, point: WorldPoint): bool =
  ## Transforms a target into the spell's fixed local frame before hit testing.
  let
    offset = point - spell.position
    x = int32((int64(offset.x) * spell.direction.z -
      int64(offset.z) * spell.direction.x) div WorldScale)
    z = int32((int64(offset.x) * spell.direction.x +
      int64(offset.z) * spell.direction.z) div WorldScale)
  area.contains(x, z, offset.y)

proc resolveSpell(world: World, spell: var SpellCast) =
  ## Resolves one area or single-target impact exactly once.
  spell.resolved = true
  let spec = spell.ability.abilitySpec(spell.level)
  if spec.casting == SelfCast:
    world.hitSpellTarget(spell, spell.heroId)
    return
  if spec.casting != AreaCast and spell.targetId != 0:
    world.hitSpellTarget(spell, spell.targetId)
    return
  var
    footprint = spec.area
    frame = spell
    nearest = int64.high
    nearestId = 0'i32
    nearestPosition: WorldPoint
  if spec.casting != AreaCast:
    footprint = FxArea(
      shape: CapsuleFootprint, width: 30_000, height: 120_000,
      length: max(30_000'i32, int32(integerSqrt(
        distanceSquared(spell.origin, spell.position))))
    )
    frame.position = spell.origin
  template affect(id: int32, position: WorldPoint) =
    if frame.spellContains(footprint, position):
      if spec.casting == AreaCast:
        world.hitSpellTarget(spell, id)
      else:
        var target: WorldObject
        let caster = world.heroIndex(spell.heroId)
        if caster >= 0 and world.spellTarget(id, target) and target.alive and
          target.faction != world.heroes[caster].team.ord.int32:
            let distance = distanceSquared(spell.origin, position)
            if distance < nearest or (distance == nearest and
              targetBefore(position, id, nearestPosition, nearestId,
                world.heroes[caster].team)):
                nearest = distance
                nearestId = id
                nearestPosition = position
  for hero in world.heroes:
    affect(hero.id, hero.position)
  if spec.kind == Strike:
    for footman in world.footmen:
      affect(footman.id, footman.position)
    for tower in world.buildings:
      affect(tower.id, tower.position)
    for fort in world.forts:
      affect(fort.id, fort.center)
  if nearestId != 0:
    world.hitSpellTarget(spell, nearestId)

proc advanceGroundShot(world: World, spell: var SpellCast) =
  ## Sweeps one tick of projectile travel and stops at the first enemy.
  let
    spec = spell.ability.abilitySpec(spell.level)
    start = spell.started + spec.castTicks
    duration = max(1'i32, spell.impact - start)
    elapsed = clamp(world.tick - start, 0'i32, duration)
    previous = max(0'i32, elapsed - 1)
    caster = world.heroIndex(spell.heroId)
    origin = spell.origin
    destination = spell.position
  if elapsed == 0 or caster < 0:
    return
  proc travel(ticks: int32): WorldPoint =
    ## Interpolates one authoritative projectile position with integers.
    result.x = origin.x + int32(
      int64(destination.x - origin.x) * ticks div duration
    )
    result.y = origin.y + int32(
      int64(destination.y - origin.y) * ticks div duration
    )
    result.z = origin.z + int32(
      int64(destination.z - origin.z) * ticks div duration
    )
  let
    first = travel(previous)
    last = travel(elapsed)
    distance = int32(integerSqrt(distanceSquared(first, last)))
    radius = 15_000'i32
    footprint = FxArea(
      shape: CapsuleFootprint,
      width: radius * 2,
      length: distance + radius * 2,
      height: 120_000
    )
  var
    frame = spell
    nearest = int64.high
    nearestId = 0'i32
    nearestPosition: WorldPoint
  frame.position = first - scaledPlanar(
    WorldPoint(x: spell.direction.x, z: spell.direction.z), radius
  )
  template consider(id: int32, position: WorldPoint) =
    if frame.spellContains(footprint, position):
      var target: WorldObject
      if world.spellTarget(id, target) and target.alive and
        target.faction != world.heroes[caster].team.ord.int32:
          let distance = distanceSquared(first, position)
          if distance < nearest or (distance == nearest and
            targetBefore(position, id, nearestPosition, nearestId,
              world.heroes[caster].team)):
              nearest = distance
              nearestId = id
              nearestPosition = position
  for hero in world.heroes:
    consider(hero.id, hero.position)
  for footman in world.footmen:
    consider(footman.id, footman.position)
  for tower in world.buildings:
    consider(tower.id, tower.position)
  for fort in world.forts:
    consider(fort.id, fort.center)
  if nearestId != 0:
    world.hitSpellTarget(spell, nearestId)
    spell.resolved = true
    spell.position = last
    spell.impact = world.tick
    spell.ends = world.tick + 12
  elif world.tick >= spell.impact:
    spell.resolved = true

proc advanceSpells(world: World) =
  ## Resolves due effects and bounds the retained impact presentation state.
  var write = 0
  for read in 0 ..< world.casts.len:
    var spell = world.casts[read]
    if not spell.resolved:
      if spell.ability.abilitySpec.casting == ProjectileCast and
        spell.targetId == 0:
          world.advanceGroundShot(spell)
      elif world.tick >= spell.impact:
        world.resolveSpell(spell)
    if world.tick < spell.ends:
      world.casts[write] = spell
      inc write
  world.casts.setLen(write)

proc castAbility(
    world: World,
    hero: Hero,
    slot: HeroAbilitySlot,
    targetId: int32,
    aim: WorldPoint
): ActionError =
  ## Releases an object or ground spell after atomically checking its costs.
  let error = world.heroActionError(hero)
  if error != NoActionError:
    return error
  if hero.controls[SilenceControl].ends > world.tick:
    return ActionSilenced
  if hero.abilityLevels[slot] == 0:
    return ActionAbilityLocked
  if world.casts.len >= 512:
    return ActionSpellLimit
  if not hero.spellsReady:
    hero.initHeroCharges()
  let
    ability = heroAbility(hero.class, slot)
    spec = ability.abilitySpec(hero.abilityLevels[slot])
  if hero.cooldowns[slot] > 0:
    return ActionCooldown
  if hero.charges[slot] <= 0:
    return ActionNoCharges
  if hero.mana < spec.manaCost:
    return ActionInsufficientMana
  var
    point = aim
    selected = targetId
  if spec.casting == SelfCast:
    point = hero.position
    selected = hero.id
    if spec.kind == Heal and hero.hp >= hero.maxHp:
      return ActionFullHealth
    if spec.kind == Restore and hero.mana >= hero.maxMana:
      return ActionFullMana
  else:
    if selected != 0:
      var target: WorldObject
      if not world.spellTarget(selected, target) or not target.alive or
        not world.visible(hero.team, target.position):
          return ActionTargetUnavailable
      if (spec.kind == Strike and target.faction == hero.team.ord.int32) or
        (spec.kind != Strike and target.faction != hero.team.ord.int32):
          return ActionTargetUnavailable
      point = target.position
      if not within(hero.position, point, spec.range):
        return ActionOutOfRange
    elif not within(hero.position, point, spec.range):
      point = hero.position + scaledPlanar(point - hero.position, spec.range)
      point.y = fixedSurfaceHeightNear(point, aim.y, hero.team)
    if not world.visible(hero.team, point):
      return ActionTargetUnavailable
  var direction = scaledPlanar(point - hero.position, WorldScale)
  if direction.x == 0 and direction.z == 0:
    direction = scaledPlanar(
      WorldPoint(x: hero.facing.x, z: hero.facing.z), WorldScale
    )
  if direction.x == 0 and direction.z == 0:
    direction.z = WorldScale
  var spell = SpellCast(
    ability: ability, level: hero.abilityLevels[slot],
    heroId: hero.id, targetId: selected,
    origin: hero.position, position: point,
    direction: heading(direction.x, direction.z),
    started: world.tick, impact: world.tick + spec.castTicks
  )
  if spec.casting == AreaCast:
    spell.targetId = 0
    if spec.fromCaster:
      spell.position = hero.position
    elif selected != 0 and spec.area.innerRadius > 0:
      spell.position = point - scaledPlanar(
        direction, (spec.area.innerRadius + spec.area.radius) div 2
      )
  if spec.casting == ProjectileCast:
    spell.impact += max(1'i32, int32((integerSqrt(
      distanceSquared(spell.origin, point)) + spec.projectileSpeed - 1) div
      max(spec.projectileSpeed, 1)))
  spell.ends = spell.impact + 12
  when defined(replayEvents):
    world.emit GameEvent(
      kind: SpellReleased, actor: world.eventEntity(hero.id),
      target: world.eventEntity(selected), cause: AbilityEffect,
      detail: ability.ord.int32, slot: slot.ord.int32, related: -1
    )
    let beforeMana = hero.mana
  hero.mana -= spec.manaCost
  when defined(replayEvents):
    world.valueEvent(ManaChanged, hero.id, hero.id, AbilityEffect,
      ability.ord.int32, beforeMana, hero.mana, -spec.manaCost)
  dec hero.charges[slot]
  hero.cooldowns[slot] = spec.cooldownTicks
  if hero.recharges[slot] == 0:
    hero.recharges[slot] = spec.rechargeTicks
  hero.facing = spell.direction
  if spell.impact <= world.tick and not world.collectingHits:
    world.resolveSpell(spell)
  world.casts.add spell
  NoActionError

proc applyCastTarget*(world: World, heroId, slotId, targetId: int32): bool =
  ## Records the first failure of an explicit object-targeted spell.
  if world.phase == Drafting:
    return world.finishAction(
      heroId, ActionCastTarget, slotId, targetId, 0, ActionDrafting
    )
  let index = world.heroIndex(heroId)
  if index < 0:
    return world.finishAction(
      heroId,
      ActionCastTarget,
      slotId,
      targetId,
      0,
      ActionNotAlive
    )
  if slotId < 0 or slotId > HeroAbilitySlot.high.ord:
    return world.finishAction(
      heroId,
      ActionCastTarget,
      slotId,
      targetId,
      0,
      ActionInvalidSlot
    )
  let hero = world.heroes[index]
  world.finishAction(
    heroId,
    ActionCastTarget,
    slotId,
    targetId,
    0,
    world.castAbility(hero, HeroAbilitySlot(slotId), targetId, hero.position)
  )

proc applyCastPoint*(
    world: World,
    heroId, slotId, mapX, mapY: int32,
    offset = FixedVec2Zero
): bool =
  ## Records explicit ground casts while preserving the raw input arguments.
  if world.phase == Drafting:
    return world.finishAction(
      heroId, ActionCastPoint, slotId, mapX, mapY, ActionDrafting, offset
    )
  let index = world.heroIndex(heroId)
  if index < 0:
    return world.finishAction(
      heroId,
      ActionCastPoint,
      slotId,
      mapX,
      mapY,
      ActionNotAlive,
      offset
    )
  if slotId < 0 or slotId > HeroAbilitySlot.high.ord:
    return world.finishAction(
      heroId,
      ActionCastPoint,
      slotId,
      mapX,
      mapY,
      ActionInvalidSlot,
      offset
    )
  if mapX < 0 or mapX >= mapTiles() or mapY < 0 or mapY >= mapTiles() or
      not offset.validTileOffset:
    return world.finishAction(
      heroId,
      ActionCastPoint,
      slotId,
      mapX,
      mapY,
      ActionInvalidPoint,
      offset
    )
  let hero = world.heroes[index]
  var point = WorldPoint(
    x: (mapX - mapTiles().int32 div 2) * WorldScale + WorldScale div 2,
    z: (mapY - mapTiles().int32 div 2) * WorldScale + WorldScale div 2
  )
  point.x += tilesToWorld(offset.x, WorldScale)
  point.z += tilesToWorld(offset.y, WorldScale)
  point.y = fixedSurfaceHeightNear(point, hero.position.y, hero.team)
  world.finishAction(
    heroId,
    ActionCastPoint,
    slotId,
    mapX,
    mapY,
    world.castAbility(hero, HeroAbilitySlot(slotId), 0, point),
    offset
  )

proc applyReplayAction(world: World, action: ReplayAction): bool {.discardable.} =
  ## Applies one recorded bot command without requiring its private VM.
  case action.kind
  of ActionWalkTo:
    applyWalkTo(world, action.heroId, action.first, action.second, action.offset)
  of ActionAttackMove:
    applyAttackMove(
      world, action.heroId, action.first, action.second, action.offset
    )
  of ActionAttackTarget:
    applyAttackTarget(world, action.heroId, action.first)
  of ActionBuyItem:
    applyBuyItem(world, action.heroId, action.first)
  of ActionBuyback:
    applyBuyback(world, action.heroId)
  of ActionUseItem:
    applyUseItem(world, action.heroId, action.first)
  of ActionUseItemAt:
    applyUseItemAt(world, action.heroId, action.slot,
      action.first, action.second, action.offset)
  of ActionCastTarget:
    applyCastTarget(world, action.heroId,
      action.slot, action.first)
  of ActionCastPoint:
    applyCastPoint(world, action.heroId,
      action.slot, action.first, action.second, action.offset)
  of ActionLevelAbility:
    applyLevelAbility(world, action.heroId, action.slot)
  of ActionDraft:
    applyDraft(world, action.heroId, action.first)
  else:
    raise newException(ReplayError, "replay action kind is invalid")

proc nearestEnemy(
    world: World, hero: Hero, radius: int32
): int32 =
  ## Returns the closest visible, attackable enemy within the radius.
  var
    bestSquared = int64(radius) * int64(radius)
    bestPosition: WorldPoint
  for footman in world.footmen:
    if not world.hostile(footman, hero.team, engageResting = hero.attackMoving) or
        footman.state == Dying or
        footman.hp <= 0 or
        not visible(world, hero.team, footman.position):
      continue
    let squared = distanceSquared(hero.position, footman.position)
    if squared < bestSquared or (squared == bestSquared and
      targetBefore(footman.position, footman.id,
        bestPosition, result, hero.team)):
        bestSquared = squared
        bestPosition = footman.position
        result = footman.id
  for other in world.heroes:
    if other.id == hero.id or
        other.team == hero.team or
        other.state == Dying or
        other.hp <= 0 or
        not visible(world, hero.team, other.position):
      continue
    let squared = distanceSquared(hero.position, other.position)
    if squared < bestSquared or (squared == bestSquared and
      targetBefore(other.position, other.id, bestPosition, result, hero.team)):
        bestSquared = squared
        bestPosition = other.position
        result = other.id
  for tower in world.buildings:
    if tower.team == hero.team or
        tower.hp <= 0 or
        not buildingExposed(world, tower) or
        not visible(world, hero.team, tower.position):
      continue
    let squared = distanceSquared(hero.position, tower.position)
    if squared < bestSquared or (squared == bestSquared and
      targetBefore(tower.position, tower.id, bestPosition, result, hero.team)):
        bestSquared = squared
        bestPosition = tower.position
        result = tower.id
  for fort in world.forts:
    if fort.team == hero.team or
        fort.hp <= 0 or
        not fortExposed(world, fort.team) or
        not visible(world, hero.team, fort.center):
      continue
    let squared = distanceSquared(hero.position, fort.center)
    if squared < bestSquared or (squared == bestSquared and
      targetBefore(fort.center, fort.id, bestPosition, result, hero.team)):
        bestSquared = squared
        bestPosition = fort.center
        result = fort.id

proc acquireRadius(world: World, hero: Hero): int32 =
  ## Returns the search radius for idle or attack-move acquisition.
  if hero.attackMoving:
    if hero.class.heroSpec.attackStyle == MeleeAttack:
      return HeroMeleeAttackMoveRange
    return heroAttackRange(hero.class)
  if not hero.hasMoveTarget:
    if hero.class.heroAttackCasting == MeleeCast:
      return HeroMeleeIdleRange
    return heroAttackRange(hero.class)
  0

proc updateHero(world: World, hero: Hero) =
  ## Applies scripted navigation, combat, rewards, death, and respawn.
  hero.velocity = Heading()
  if hero.state == Dying:
    inc hero.deathTicks
    hero.animClip = heroDeathClip
    hero.animTicks = min(hero.deathTicks, HeroDeathTicks)
    if hero.respawnTicks() == 0:
      world.respawn(hero)
    return

  if hero.hp <= 0:
    world.die(hero)
    return

  world.recoverHero(hero)
  if hero.portalEnds > 0:
    hero.animClip = heroIdleClip
    inc hero.animTicks
    world.regenHeroMana(hero, world.tick)
    if hero.controls[StunControl].ends > world.tick or
      hero.controls[RootControl].ends > world.tick:
        world.interruptPortal(hero)
    elif world.tick >= hero.portalEnds:
      var
        destination: WorldPoint
        towerId: int32
      if world.portalLanding(hero.team, hero.portalDestination,
          destination, towerId, hero.portalTowerId):
        hero.place(destination)
        hero.portalEnds = 0
        hero.portalCooldownEnds = world.tick + PortalCooldownTicks
        hero.portalTowerId = 0
        when defined(replayEvents):
          world.lifecycleEvent(PortalCompleted, hero.id, hero.id, ItemEffect)
      else:
        world.interruptPortal(hero)
    return
  if hero.controls[StunControl].ends > world.tick:
    hero.animClip = heroIdleClip
    inc hero.animTicks
    world.regenHeroMana(hero, world.tick)
    return

  let start = hero.position
  defer:
    hero.velocity = heading(
      hero.position.x - start.x,
      hero.position.z - start.z
    )

  hero.targetFootmanId = 0
  hero.targetHeroId = 0
  hero.targetBuildingId = 0
  hero.attackingFort = false
  var
    targetFootman = -1
    targetHero = -1
    targetBuilding = -1
    fortIndex = -1
  if hero.attackObjectId != 0:
    targetFootman = footmanIndex(world, hero.attackObjectId)
    if targetFootman >= 0:
      let footman = world.footmen[targetFootman]
      if not world.hostile(footman, hero.team, engageResting = true) or
          not visible(world, hero.team, footman.position):
        targetFootman = -1
    if targetFootman < 0:
      targetHero = heroIndex(world, hero.attackObjectId)
      if targetHero >= 0:
        let other = world.heroes[targetHero]
        if other.team == hero.team or other.state == Dying or
            other.hp <= 0 or not visible(world, hero.team, other.position):
          targetHero = -1
    if targetFootman < 0 and targetHero < 0:
      targetBuilding = buildingIndex(world, hero.attackObjectId)
      if targetBuilding >= 0:
        let tower = world.buildings[targetBuilding]
        if tower.team == hero.team or not buildingExposed(world, tower) or
            not visible(world, hero.team, tower.position):
          targetBuilding = -1
    if targetFootman < 0 and targetHero < 0 and targetBuilding < 0:
      for i, fort in world.forts:
        if fort.id == hero.attackObjectId and fort.team != hero.team and
            fort.hp > 0 and fortExposed(world, fort.team):
          if not visible(world, hero.team, fort.center):
            continue
          fortIndex = i
          hero.attackingFort = true
          break
    if targetFootman < 0 and targetHero < 0 and targetBuilding < 0 and
        not hero.attackingFort:
      hero.attackObjectId = 0
      if not hero.attackMoving:
        hero.stopHeroPath()
  if hero.attackObjectId == 0:
    let radius = world.acquireRadius(hero)
    if radius > 0:
      hero.attackObjectId = world.nearestEnemy(hero, radius)
      if hero.attackObjectId != 0:
        targetFootman = footmanIndex(world, hero.attackObjectId)
        if targetFootman >= 0:
          let footman = world.footmen[targetFootman]
          if not world.hostile(footman, hero.team, engageResting = true):
            targetFootman = -1
        if targetFootman < 0:
          targetHero = heroIndex(world, hero.attackObjectId)
          if targetHero >= 0:
            let other = world.heroes[targetHero]
            if other.team == hero.team or other.state == Dying or
                other.hp <= 0:
              targetHero = -1
        if targetFootman < 0 and targetHero < 0:
          targetBuilding = buildingIndex(world, hero.attackObjectId)
          if targetBuilding >= 0:
            let tower = world.buildings[targetBuilding]
            if tower.team == hero.team or not buildingExposed(world, tower):
              targetBuilding = -1
        if targetFootman < 0 and targetHero < 0 and targetBuilding < 0:
          for i, fort in world.forts:
            if fort.id == hero.attackObjectId:
              fortIndex = i
              hero.attackingFort = true
              break
  hero.targetFootmanId =
    if targetFootman >= 0: world.footmen[targetFootman].id else: 0
  hero.targetHeroId =
    if targetHero >= 0: world.heroes[targetHero].id else: 0
  hero.targetBuildingId =
    if targetBuilding >= 0: world.buildings[targetBuilding].id else: 0

  world.regenHeroMana(hero, world.tick)

  if not world.isEnemyTarget(hero, hero.attackObjectId):
    if hero.attackObjectId != 0 and not hero.attackMoving:
      hero.stopHeroPath()
    targetFootman = -1
    targetHero = -1
    targetBuilding = -1
    fortIndex = -1
    hero.attackObjectId = 0
    hero.targetFootmanId = 0
    hero.targetHeroId = 0
    hero.targetBuildingId = 0
    hero.attackingFort = false

  if targetFootman >= 0 or targetHero >= 0 or
      targetBuilding >= 0 or hero.attackingFort:
    hero.state = Fighting
    let targetPosition =
      if targetFootman >= 0: world.footmen[targetFootman].position
      elif targetHero >= 0: world.heroes[targetHero].position
      elif targetBuilding >= 0:
        buildingAim(world.buildings[targetBuilding], hero.position)
      else: world.forts[fortIndex].center
    hero.surfaceHint = targetPosition.y
    let
      offset = targetPosition - hero.position
      inRange =
        if targetFootman >= 0 or targetHero >= 0:
          within(
            hero.position,
            targetPosition,
            heroAttackRange(hero.class)
          )
        elif targetBuilding >= 0:
          within(
            hero.position,
            targetPosition,
            max(heroAttackRange(hero.class), TowerSiegeRange)
          )
        else:
          within(hero.position, targetPosition, FortRange)
    if not inRange:
      hero.swingTicks = -1
      hero.animClip = heroRunClip
      inc hero.animTicks
      let
        targetX = int(mapCoordinate(targetPosition.x, hero.team))
        targetY = int(mapCoordinate(targetPosition.z, hero.team))
      if hero.setHeroDestination(
        targetX,
        targetY,
        targetPosition.y
      ):
        discard hero.followHeroPath()
      else:
        hero.stopHeroPath()
    else:
      snapFacing(hero.body, hero.facing, offset)
      if hero.swingTicks < 0:
        startSwing(world, hero)
      let duration = world.heroAttackTicks(hero)
      inc hero.swingTicks
      if not hero.damageLanded and
          hero.swingTicks >= world.heroHitTicks(hero):
        hero.damageLanded = true
        let damage = hero.heroAttackDamage
        if damage > 0:
          inc hero.attacksLanded
        applyHeroHit(
          world,
          hero,
          damage,
          targetFootman,
          targetHero,
          targetBuilding,
          fortIndex
        )
      if hero.swingTicks >= duration:
        startSwing(world, hero)
      hero.animClip = hero.swingClip
      hero.animTicks = max(hero.swingTicks, 0)
    return

  let moving = hero.followHeroPath()
  hero.state = Marching
  hero.swingTicks = -1
  hero.animClip = if moving: heroRunClip else: heroIdleClip
  inc hero.animTicks

proc immobile(world: World, hero: Hero): bool =
  ## Keeps channeling or controlled heroes in place during separation.
  hero.portalEnds > 0 or hero.controls[StunControl].ends > world.tick or
    hero.controls[RootControl].ends > world.tick

proc separateUnits(game: Game) =
  ## Accumulates collision corrections before moving any participant.
  let world = game.world
  var maximumRadius = FixedZero
  game.collisionUnits.setLen(0)
  for i, footman in world.footmen:
    if footman.state != Dying:
      game.collisionUnits.add CollisionUnit(body: footman.body, index: i,
        layer: footman.navLayer, team: footman.team,
        fixed: footman.controls[StunControl].ends > world.tick or
          footman.controls[RootControl].ends > world.tick)
      maximumRadius = max(maximumRadius, footman.body.radius)
  for i, hero in world.heroes:
    if hero.state != Dying:
      game.collisionUnits.add CollisionUnit(body: hero.body, index: i,
        layer: hero.navLayer, team: hero.team,
        hero: true, fixed: world.immobile(hero))
      maximumRadius = max(maximumRadius, hero.body.radius)
  let count = game.collisionUnits.len
  game.collisionOrder.setLen(count)
  game.collisionOffsets.setLen(count)
  for i in 0 ..< count:
    game.collisionOrder[i] = i
  for iteration in 0 ..< 4:
    for offset in game.collisionOffsets.mitems:
      offset = FixedVec2Zero
    game.collisionOrder.sort(proc(first, second: int): int =
      ## Restricts pair checks to bodies close enough along the X axis.
      cmp(game.collisionUnits[first].body.pos.x,
        game.collisionUnits[second].body.pos.x)
    )
    var overlap = false
    for first in 0 ..< count:
      let
        i = game.collisionOrder[first]
        a = game.collisionUnits[i]
      for second in first + 1 ..< count:
        let
          j = game.collisionOrder[second]
          b = game.collisionUnits[j]
        if b.body.pos.x - a.body.pos.x > a.body.radius + maximumRadius:
          break
        if a.layer != b.layer or (a.fixed and b.fixed) or
          not needsSeparation(a.body, b.body):
            continue
        let
          firstPoint = WorldPoint(x: tilesToWorld(a.body.pos.x, WorldScale),
            z: tilesToWorld(a.body.pos.y, WorldScale))
          secondPoint = WorldPoint(x: tilesToWorld(b.body.pos.x, WorldScale),
            z: tilesToWorld(b.body.pos.y, WorldScale))
        if not inWalkMargin(a.body.pos) or not inWalkMargin(b.body.pos) or
          not navigationLineClear(firstPoint, secondPoint,
            a.layer, b.layer, a.team) or
          not navigationLineClear(secondPoint, firstPoint,
            b.layer, a.layer, b.team):
              continue
        let push = motions.separation(a.body, b.body, a.fixed, b.fixed)
        if not a.fixed:
          game.collisionOffsets[i] -= push
        if not b.fixed:
          game.collisionOffsets[j] += push
        overlap = true
    if not overlap:
      break
    for i, unit in game.collisionUnits.mpairs:
      if unit.fixed or game.collisionOffsets[i] == FixedVec2Zero:
        continue
      gotaWalkLayer = unit.layer.int
      gotaWalkDestLayer = unit.layer.int
      gotaWalkTeam = unit.team
      gotaWalkOrigin = unit.body.pos
      let
        previous = unit.body.pos
        limit = max(unit.body.radius, FootmanBodyRadius)
      unit.body.pos += motions.step(game.collisionOffsets[i], limit)
      clampWalkable(unit.body.pos, previous, tilesWalkable)
  for unit in game.collisionUnits:
    if unit.hero:
      world.heroes[unit.index].body = unit.body
    else:
      world.footmen[unit.index].body = unit.body

proc addHashy(hash: var uint32, value: WorldPoint) =
  ## Mixes one authoritative integer world position.
  hash.addHashy(value.x)
  hash.addHashy(value.y)
  hash.addHashy(value.z)

proc addHashy(hash: var uint32, value: Heading) =
  ## Mixes one authoritative integer heading.
  hash.addHashy(value.x)
  hash.addHashy(value.z)

proc stateHash*(game: Game): uint64 =
  ## Hashes replay-authoritative state after actions for one tick are applied.
  let world = game.world
  var hash = HashySeed
  hash.addHashy(game.map.hash)
  hash.addHashy(world.tick)
  hash.addHashy(world.phase.ord)
  hash.addHashy(world.drafting)
  hash.addHashy(world.draftTurn)
  hash.addHashy(world.draftTicks)
  hash.addHashy(world.draftTurnTicks)
  hash.addHashy(world.draftOrder.len)
  for index in world.draftOrder:
    hash.addHashy(index)
  hash.addHashy(world.spawnTimerTicks)
  hash.addHashy(world.heroTurnTicks)
  hash.addHashy(world.heroTurnStart)
  hash.addHashy(world.rng)
  hash.addHashy(world.matchSeed)
  hash.addHashy(world.nextFootmanId)
  hash.addHashy(world.gameOver)
  hash.addHashy(world.draw)
  hash.addHashy(world.winner.ord)
  for value in world.teamHeroKills:
    hash.addHashy(value)
  for value in world.teamHeroDeaths:
    hash.addHashy(value)
  hash.addHashy(world.forts.len)
  for fort in world.forts:
    hash.addHashy(fort.id)
    hash.addHashy(fort.team.ord)
    hash.addHashy(fort.center)
    hash.addHashy(fort.hp)
  hash.addHashy(world.navigationRevision)
  hash.addHashy(world.buildings.len)
  for tower in world.buildings:
    hash.addHashy(tower.kind.ord)
    hash.addHashy(tower.guardsGod)
    hash.addHashy(tower.knownAlive)
    hash.addHashy(tower.id)
    hash.addHashy(tower.team.ord)
    hash.addHashy(tower.lane)
    hash.addHashy(tower.tier.ord)
    hash.addHashy(tower.position)
    hash.addHashy(tower.facing)
    hash.addHashy(tower.hp)
    hash.addHashy(tower.maxHp)
    hash.addHashy(tower.targetId)
    hash.addHashy(tower.attackTicks)
  hash.addHashy(world.heroes.len)
  for i in 0 ..< world.heroes.len:
    let hero = world.heroes[i]
    hash.addHashy(hero.id)
    hash.addHashy(hero.team.ord)
    hash.addHashy(hero.slot)
    hash.addHashy(hero.lane)
    hash.addHashy(hero.class.ord)
    hash.addHashy(hero.drafted)
    hash.addHashy(hero.position)
    hash.addHashy(hero.spawnPosition)
    hash.addHashy(hero.facing)
    hash.addHashy(hero.velocity)
    hash.addHashy(hero.body)
    hash.addHashy(hero.hp)
    hash.addHashy(hero.maxHp)
    hash.addHashy(hero.mana)
    hash.addHashy(hero.maxMana)
    hash.addHashy(hero.level)
    hash.addHashy(hero.xp)
    hash.addHashy(hero.totalXp)
    hash.addHashy(hero.creepXpRemainder)
    hash.addHashy(hero.gold)
    hash.addHashy(hero.deaths)
    hash.addHashy(hero.state.ord)
    hash.addHashy(hero.waypointIndex)
    hash.addHashy(hero.targetFootmanId)
    hash.addHashy(hero.targetHeroId)
    hash.addHashy(hero.targetBuildingId)
    hash.addHashy(hero.attackingFort)
    hash.addHashy(hero.swingClip)
    hash.addHashy(hero.swingTicks)
    hash.addHashy(hero.damageLanded)
    hash.addHashy(hero.attacksLanded)
    hash.addHashy(hero.animClip)
    hash.addHashy(hero.animTicks)
    hash.addHashy(hero.deathTicks)
    hash.addHashy(hero.surfaceHint)
    hash.addHashy(hero.navLayer)
    hash.addHashy(hero.attackObjectId)
    hash.addHashy(hero.attackMoving)
    hash.addHashy(hero.movePath.len)
    for waypoint in hero.movePath:
      hash.addHashy(waypoint)
    hash.addHashy(hero.movePathIndex)
    hash.addHashy(hero.moveRevision)
    hash.addHashy(hero.stuckTicks)
    hash.addHashy(hero.moveTileX)
    hash.addHashy(hero.moveTileY)
    hash.addHashy(int32(hero.moveOffset.x))
    hash.addHashy(int32(hero.moveOffset.y))
    hash.addHashy(hero.hasMoveTarget)
    for slot in 0 ..< InventorySlots:
      hash.addHashy(hero.inventory[slot].ord)
      hash.addHashy(hero.itemCounts[slot])
    for slot in HeroAbilitySlot:
      hash.addHashy(hero.cooldowns[slot])
      hash.addHashy(hero.charges[slot])
      hash.addHashy(hero.recharges[slot])
    hash.addHashy(hero.spellsReady)
    for rank in hero.abilityLevels:
      hash.addHashy(rank)
    hash.addHashy(hero.lastActionError.ord)
    for kind in RecoveryKind:
      hash.addHashy(hero.potionCooldownEnds[kind])
      hash.addHashy(hero.recoveryItems[kind].ord)
      hash.addHashy(hero.recoveryStarted[kind])
      hash.addHashy(hero.recoveryApplied[kind])
    hash.addHashy(hero.portalEnds)
    hash.addHashy(hero.portalCooldownEnds)
    hash.addHashy(hero.portalTowerId)
    hash.addHashy(hero.portalDestination)
    for timer in hero.controls:
      hash.addHashy(timer.started)
      hash.addHashy(timer.ends)
  hash.addHashy(world.camps.len)
  for camp in world.camps:
    hash.addHashy(camp.center)
    hash.addHashy(camp.tier)
    hash.addHashy(camp.count)
    hash.addHashy(camp.appearance)
    hash.addHashy(camp.state.ord)
    hash.addHashy(camp.targetId)
    hash.addHashy(camp.respawnTick)
    hash.addHashy(camp.lastSeenTick)
    hash.addHashy(camp.started)
  hash.addHashy(world.footmen.len)
  for footman in world.footmen:
    hash.addHashy(footman.id)
    hash.addHashy(footman.kind.ord)
    hash.addHashy(footman.camp)
    hash.addHashy(footman.campTier)
    hash.addHashy(footman.appearance)
    hash.addHashy(footman.leader)
    hash.addHashy(footman.home)
    hash.addHashy(footman.team.ord)
    hash.addHashy(footman.lane)
    hash.addHashy(footman.position)
    hash.addHashy(footman.facing)
    hash.addHashy(footman.velocity)
    hash.addHashy(footman.body)
    hash.addHashy(footman.hp)
    hash.addHashy(footman.state.ord)
    hash.addHashy(footman.waypointIndex)
    hash.addHashy(footman.movePath)
    hash.addHashy(footman.movePathIndex)
    hash.addHashy(footman.moveGoal)
    hash.addHashy(footman.moveRevision)
    hash.addHashy(footman.nextPathTick)
    hash.addHashy(footman.stuckTicks)
    hash.addHashy(footman.targetId)
    hash.addHashy(footman.targetHeroId)
    hash.addHashy(footman.targetBuildingId)
    hash.addHashy(footman.attackingFort)
    hash.addHashy(footman.swingClip)
    hash.addHashy(footman.swingTicks)
    hash.addHashy(footman.damageLanded)
    hash.addHashy(footman.animClip)
    hash.addHashy(footman.animTicks)
    hash.addHashy(footman.deathTicks)
    hash.addHashy(footman.surfaceHint)
    hash.addHashy(footman.navLayer)
    for timer in footman.controls:
      hash.addHashy(timer.started)
      hash.addHashy(timer.ends)
  hash.addHashy(world.casts.len)
  for spell in world.casts:
    hash.addHashy(spell.ability.ord)
    hash.addHashy(spell.level)
    hash.addHashy(spell.heroId)
    hash.addHashy(spell.targetId)
    hash.addHashy(spell.origin)
    hash.addHashy(spell.position)
    hash.addHashy(spell.direction)
    hash.addHashy(spell.started)
    hash.addHashy(spell.impact)
    hash.addHashy(spell.ends)
    hash.addHashy(spell.resolved)
  hash.addHashy(world.towerShots.len)
  for shot in world.towerShots:
    hash.addHashy(shot.sourceId)
    hash.addHashy(shot.targetId)
    hash.addHashy(shot.damage)
    hash.addHashy(shot.team.ord)
    hash.addHashy(shot.previous)
    hash.addHashy(shot.position)
    hash.addHashy(shot.started)
    hash.addHashy(shot.impact)
  hash.addHashy(world.stats)
  uint64(hash)

proc settleSurface(position: var WorldPoint, surfaceHint: int32) =
  ## Quantizes terrain geometry back into authoritative integer height.
  position.y = fixedSurfaceHeightNear(position, surfaceHint)

proc checkReplayHash(game: Game, hash: uint64) =
  ## Reports each divergent replay tick once while allowing playback to run.
  if not game.historyPlayback or game.world.tick <= 0:
    return
  let hashes =
    if game.recorder != nil: game.recorder.data.hashes
    else: game.replayPlayer.data.hashes
  hashes.checkReplayHash(uint32(game.world.tick), hash, game.hashCheck)

proc finishTick(game: Game) =
  ## Records or validates the authoritative hash for either match phase.
  let world = game.world
  if game.historyPlayback:
    checkReplayHash(game, stateHash(game))
  elif game.recorder != nil and game.recordingError.len == 0 and
      game.recorder.data.hashes.len < world.tick:
    try:
      game.recorder.recordHash(stateHash(game))
    except ReplayError as error:
      game.recordingError = error.msg

proc tickWorld*(game: Game, onHeroTurn: proc() {.closure.}) {.measure.} =
  ## Advances exactly one authoritative integer simulation tick.
  let world = game.world
  when defined(replayEvents):
    world.events.setLen(0)
    world.eventTick = world.tick + 1
  world.syncBuildings()
  if game.finished():
    return
  if game.replayMode and
      world.tick >= game.replayData.hashes.len:
    return

  if world.phase == Drafting:
    inc world.tick
    inc world.draftTicks
    inc world.draftTurnTicks
    dec world.heroTurnTicks
    let decide = world.heroTurnTicks <= 0
    if decide:
      world.heroTurnTicks = TickRate div 2
    if game.historyPlayback:
      if game.recorder != nil:
        game.replayPlayer.data = game.recorder.data
      var action: ReplayAction
      while game.replayPlayer.takeActionAt(uint32(world.tick), action):
        if world.applyReplayAction(action):
          game.metrics.command(world.heroIndex(action.heroId), world.tick)
    elif decide and onHeroTurn != nil:
      onHeroTurn()
    if world.phase == Drafting and world.draftTicksLeft() == 0:
      var available: seq[HeroClass]
      for class in HeroClass:
        if world.heroAvailable(class.ord.int32):
          available.add(class)
      let class = available[world.rng.below(available.len.int32)]
      discard world.applyDraft(world.draftHeroId(), class.ord.int32, TimeLimit)
    game.finishTick()
    return

  dec world.spawnTimerTicks
  if world.spawnTimerTicks <= 0:
    world.spawnTimerTicks += world.spawnIntervalTicks
    profileBlock "spawnWave":
      spawnWave(world)

  world.tick = world.tick +% 1
  world.collectingHits = true
  for hero in world.heroes:
    if hero.hp > 0 and hero.state != Dying:
      world.tickHeroCooldowns(hero)
  profileBlock "vision":
    rebuildVision(world)
    world.updateKnownBuildings()
  block:
    discard world.freezeObservations()
    defer:
      world.thawObservations()
    if game.historyPlayback:
      if game.recorder != nil:
        game.replayPlayer.data = game.recorder.data
      var action: ReplayAction
      while game.replayPlayer.takeActionAt(uint32(world.tick), action):
        if applyReplayAction(world, action):
          game.metrics.command(heroIndex(world, action.heroId), world.tick)
    dec world.heroTurnTicks
    if world.heroTurnTicks <= 0:
      world.heroTurnTicks += DecisionTicks
      if game.historyPlayback:
        world.heroTurnStart = (world.heroTurnStart + 1) mod world.heroes.len
      else:
        profileBlock "decisions":
          if onHeroTurn != nil:
            onHeroTurn()

  world.updateCamps()

  # Plan every unit against the same actor state, then publish together.
  game.nextFootmen.setLen(world.footmen.len)
  for i, footman in world.footmen:
    game.nextFootmen[i] = footman
  game.nextHeroes.setLen(world.heroes.len)
  for i, hero in world.heroes:
    if game.nextHeroes[i] == nil:
      game.nextHeroes[i] = Hero()
    game.nextHeroes[i][] = hero[]
  profileBlock "footmen":
    for offset in 0 ..< world.footmen.len:
      let index = (world.tick.int + offset) mod world.footmen.len
      updateFootman(world, game.nextFootmen[index])
  profileBlock "towers":
    for offset in 0 ..< world.buildings.len:
      let index = (world.tick.int + offset) mod world.buildings.len
      updateTower(world, world.buildings[index])
  profileBlock "heroes":
    for offset in 0 ..< world.heroes.len:
      let index = (world.tick.int + offset) mod world.heroes.len
      updateHero(world, game.nextHeroes[index])

  swap(world.footmen, game.nextFootmen)
  for i, hero in game.nextHeroes:
    world.heroes[i][] = hero[]

  world.advanceSpells()
  world.advanceTowerShots()
  world.resolveCombat()
  world.updateCamps()

  var write = 0
  for read in 0 ..< world.footmen.len:
    if world.footmen[read].state != Dying or
        world.footmen[read].deathTicks < FootmanDeathTicks + CorpseLingerTicks:
      if write != read:
        world.footmen[write] = world.footmen[read]
      inc write
    else:
      when defined(replayEvents):
        world.lifecycleEvent(EntityRemoved, 0, world.footmen[read].id,
          CorpseExpired)
  world.footmen.setLen(write)

  profileBlock "separate":
    game.separateUnits()

  profileBlock "applyBody":
    for footman in world.footmen.mitems:
      let before = footman.position
      applyBody(footman)
      if footman.state != Dying:
        footman.velocity.x += footman.position.x - before.x
        footman.velocity.z += footman.position.z - before.z
      settleOnLayer(footman.position, footman.navLayer, footman.team)
    for hero in world.heroes:
      let before = hero.position
      applyBody(hero)
      if hero.state != Dying:
        hero.velocity.x += hero.position.x - before.x
        hero.velocity.z += hero.position.z - before.z
      settleOnLayer(hero.position, hero.navLayer, hero.team)

  let
    redDead = world.forts[RedTeam.ord].hp <= 0
    blueDead = world.forts[BlueTeam.ord].hp <= 0
  if redDead or blueDead:
    world.gameOver = true
    world.draw = redDead and blueDead
    world.winner = if redDead: BlueTeam else: RedTeam
    for footman in world.footmen.mitems:
      if footman.state == Dying:
        continue
      footman.animClip =
        if footman.camp == 0 and not world.draw and footman.team == world.winner:
          victoryClip
        else:
          idleClip
      footman.animTicks = 0
    for hero in world.heroes:
      let enemyGod = world.forts[1 - hero.team.ord]
      if enemyGod.hp <= 0:
        world.gainRewards(hero, GodXpReward, 0, enemyGod.id, GodDestroyed)
      if hero.state == Dying:
        continue
      hero.animClip =
        if world.draw or hero.team == world.winner:
          heroIdleClip
        else:
          heroDeathClip
      hero.animTicks = 0

  when defined(replayEvents):
    if world.gameOver:
      world.emit GameEvent(
        kind: MatchEnded, cause: GodDestroyed,
        amount: (if world.draw: -1 else: world.winner.ord),
        actor: world.eventEntity(0), target: world.eventEntity(0), related: -1
      )
    elif world.battleTick() == game.config.maxTicks:
      world.emit GameEvent(
        kind: MatchEnded, cause: TimeLimit, amount: -1,
        actor: world.eventEntity(0), target: world.eventEntity(0), related: -1
      )

  game.finishTick()

proc initLanePaths(map: MapData) =
  ## Samples symmetric lane goals without baking live buildings into roads.
  proc gate(lane: int, team: Team): ArenaStop =
    ## Places a lane endpoint between its two barracks at the fort exit.
    var midpoint: WorldPoint
    var count = 0
    for site in map.layout.barracks:
      if site.lane == lane and site.team == team.ord:
        midpoint = midpoint + worldPoint(site.position)
        inc count
    doAssert count == 2
    (
      GroundLayer,
      int(mapCoordinate(midpoint.x div count.int32)),
      int(mapCoordinate(midpoint.z div count.int32))
    )

  proc nearestStop(route: seq[ArenaStop], stop: ArenaStop): int =
    ## Finds the generated road sample nearest a fort exit during map setup.
    var best = int.high
    for i, candidate in route:
      let distance = (candidate.x - stop.x) * (candidate.x - stop.x) +
        (candidate.z - stop.z) * (candidate.z - stop.z)
      if distance < best:
        best = distance
        result = i

  for lane in [0, 1]:
    let
      source = map.layout.lanes[lane]
      first = gate(lane, RedTeam)
      last = gate(lane, BlueTeam)
      firstIndex = source.nearestStop(first)
      lastIndex = source.nearestStop(last)
    doAssert firstIndex < lastIndex
    var route = @[first]
    for i in firstIndex + 1 ..< lastIndex:
      route.add source[i]
    route.add last
    if lane == 1:
      route.setLen(route.len div 2 + route.len mod 2)
    lanePathPoints[lane].setLen(0)
    lanePathTiles[lane].setLen(0)
    if route.len == 0:
      continue
    var distance = 0'i64
    for i, stop in route:
      let point = pathPoint(stop.layer, stop.x, stop.z)
      if i > 0:
        let previous = route[i - 1]
        distance += integerSqrt(distanceSquared(
          worldPoint(point),
          worldPoint(pathPoint(previous.layer, previous.x, previous.z))
        ))
      let crossing = i > 0 and stop.layer != route[i - 1].layer
      var bend = false
      if i > 0 and i < route.high:
        let
          back = route[max(0, i - 5)]
          ahead = route[min(route.high, i + 5)]
          dx = int64(stop.x - back.x)
          dz = int64(stop.z - back.z)
          ex = int64(ahead.x - stop.x)
          ez = int64(ahead.z - stop.z)
        bend = distance >= WaypointSpacing div 2 and
          abs(dx * ez - dz * ex) > abs(dx * ex + dz * ez)
      if i == 0 or i == route.high or crossing or bend or
          distance >= WaypointSpacing:
        lanePathPoints[lane].add point
        lanePathTiles[lane].add PathTile(
          layer: stop.layer.int32, x: stop.x.int32, z: stop.z.int32)
        distance = 0

  proc mirrored(tile: PathTile): PathTile =
    ## Rotates a goal by 180 degrees on the same symmetric arena layer.
    PathTile(layer: tile.layer,
      x: int32(layers[tile.layer].width - 1) - tile.x,
      z: int32(layers[tile.layer].depth - 1) - tile.z)
  lanePathTiles[2].setLen(0)
  for i in countdown(lanePathTiles[0].high, 0):
    lanePathTiles[2].add mirrored(lanePathTiles[0][i])
  let middle = lanePathTiles[1]
  for i in countdown(middle.high, 0):
    let tile = mirrored(middle[i])
    if lanePathTiles[1][^1] != tile:
      lanePathTiles[1].add tile
  for lane in 0 .. 2:
    lanePathPoints[lane].setLen(0)
    for tile in lanePathTiles[lane]:
      lanePathPoints[lane].add pathPoint(int(tile.layer), int(tile.x), int(tile.z))

proc sampleMetrics*(game: Game, force = false) =
  ## Samples deterministic world counters and independent VM telemetry.
  if game.metrics == nil or game.world.stats == nil:
    return
  for slot, values in game.world.stats.values:
    for kind in MetricKind:
      game.metrics.set(slot, kind, values[kind])
    game.metrics.set(slot, LevelMetric, game.world.heroes[slot].level)
  game.history.capture(game.metrics, game.world.tick, force)

proc newGame*(
    map: MapData,
    spawnInterval: int32,
    botCount: int,
    replayMode: bool,
    replayData: ReplayData,
    drafting = true
): Game =
  ## Builds one match session: world, lane paths, towers, and heroes.
  result = Game(
    world: World(
      forts: startingForts(map),
      nextFootmanId: FirstFootmanId,
      winner: RedTeam,
      scriptObjects: newSeqOfCap[WorldObject](256),
      scriptObjectsTick: -1
    ),
    map: map,
    replayMode: replayMode,
    replayData: replayData
  )
  let world = result.world
  world.spawnIntervalTicks = spawnInterval
  world.rng = initRng(map.seed)
  world.matchSeed = map.seed
  initTowers(world, map)
  initLanePaths(map)
  for team in Team:
    var point = worldPoint(map.layout.spawns[team.ord])
    point.y = fixedSurfaceHeight(point, team)
    world.heroSpawns[team.ord] = point
  for i, site in map.layout.barracks:
    var
      position = worldPoint(site.position)
      spawn = worldPoint(site.spawn)
    position.y = fixedSurfaceHeight(position, Team(site.team))
    spawn.y = fixedSurfaceHeight(spawn, Team(site.team))
    world.buildings.add Building(
      kind: BarracksBuilding,
      id: FirstBarracksId + int32(i),
      team: Team(site.team), lane: site.lane,
      position: position, spawn: spawn,
      facing: heading(site.facing.x - site.position.x,
        site.facing.z - site.position.z),
      hp: BarracksHitPoints, maxHp: BarracksHitPoints
    )
  for team in Team:
    for i, site in map.layout.guards[team.ord]:
      var position = worldPoint(site.position)
      position.y = fixedSurfaceHeight(position, team)
      world.buildings.add Building(
        id: FirstTowerId + 18 + int32(team.ord * 2 + i),
        kind: TowerBuilding,
        guardsGod: true,
        team: team,
        lane: -1,
        tier: GateTower,
        position: position,
        facing: heading(
          site.facing.x - site.position.x,
          site.facing.z - site.position.z
        ),
        hp: TowerHitPoints[GateTower],
        maxHp: TowerHitPoints[GateTower]
      )
  world.initOccupancy()
  world.initCamps(map)
  sightTerrain = buildSightTerrain()
  let visionCells = mapTiles() * mapTiles()
  for team in Team:
    world.teamVisible[team.ord] = newSeq[uint8](visionCells)
    world.teamExplored[team.ord] = newSeq[uint8](visionCells)
  for lane in 0 .. 2:
    laneWorldPaths[lane].setLen(0)
    laneWorldLayers[lane].setLen(0)
    for tile in lanePathTiles[lane]:
      laneWorldPaths[lane].add worldPoint(pathPoint(
        int(tile.layer),
        int(tile.x),
        int(tile.z)
      ))
      laneWorldLayers[lane].add tile.layer
  for fort in world.forts.mitems:
    fort.center.y = fixedSurfaceHeight(fort.center, fort.team)
  let heroSetup =
    if replayMode:
      replayData.header.setup.heroes
    else:
      liveHeroSetup(botCount)
  spawnHeroes(world, heroSetup)
  for hero in world.heroes:
    hero.drafted = true
    hero.initHeroCharges()
  world.stats = newCombatStats(world.heroes.len)
  result.metrics = newMetrics(world.heroes.len, TickRate)
  for slot, hero in world.heroes:
    world.stats.teams[slot] = hero.team.ord
  doAssert world.heroes.len == heroSetup.len, "every configured hero must spawn"
  rebuildVision(world)
  world.updateKnownBuildings()
  world.heroTurnStart = seededHeroTurnStart(world)
  if (if replayMode: replayData.header.setup.drafting else: drafting):
    world.initDraft()
  if replayMode:
    validateReplayWorld(result)
  result.sampleMetrics(true)
  when defined(replayEvents):
    for fort in world.forts:
      world.lifecycleEvent(EntitySpawned, 0, fort.id, Initialization)
    for building in world.buildings:
      world.lifecycleEvent(EntitySpawned, 0, building.id, Initialization)
    for hero in world.heroes:
      world.lifecycleEvent(EntitySpawned, 0, hero.id, Initialization)

proc scores*(world: World): seq[int] =
  ## Awards every hero on the victorious team one win.
  result.setLen(world.heroes.len)
  if world.gameOver and not world.draw:
    for slot, hero in world.heroes:
      if hero.team == world.winner:
        result[slot] = 1

proc totalXp*(world: World): seq[int] =
  ## Returns lifetime hero XP in platform seat order.
  for hero in world.heroes:
    result.add hero.totalXp
