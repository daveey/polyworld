import
  std/os,
  ../examples/light_vs_dark/[content, game, graphics, maps, sim]

proc clearing(): tuple[x, y: int32] =
  ## Finds room for both complete rosters without moving existing units.
  for y in 12'i32 ..< run.world.map.side - 22:
    for x in 12'i32 ..< run.world.map.side - 28:
      var clear = true
      for dy in 0'i32 .. 10:
        for dx in 0'i32 .. 20:
          let tile = tile2(x + dx, y + dy)
          if not run.world.tileOpen(tile) or
            run.world.occupancy[run.world.map.tileIndex(tile)] != NoEntity:
              clear = false
      if clear:
        return (x + 3, y + 3)
  raise newException(ValueError, "No clearing for the LvD roster review.")

let origin = clearing()
for player in 0'i32 ..< FactionCount:
  for kind in UnitKind:
    let id = run.world.spawnUnit(
      player,
      kind,
      tile2(origin.x + kind.ord.int32 * 2, origin.y + player * 4)
    )
    selectedIds.add id
    if player == LightPlayer and kind == CatapultUnit:
      primaryId = id

putEnv("CAM_X", $(origin.x + 7))
putEnv("CAM_Z", $(origin.y + 2))
putEnv("CAM_DIST", "18")
options.playerSlot = 1
runGraphics()
