import
  std/math,
  vmath,
  polyworld/occlusions,
  layouts, obstacles

proc villageOcclusion*(
  seed: int32, roof: openArray[array[3, Vec3]]
): OcclusionField =
  ## Approximates static banks, crowns and timber for local contact shading.
  result = initOcclusionField(512, vec2(-40, -46), vec2(80, 96))
  for slot, house in TownHouses:
    let
      turn = HouseTurns[slot]
      anchor = houseAnchor(slot)
    for triangle in roof:
      var transformed: array[3, Vec3]
      for i, point in triangle:
        transformed[i] = vec3(
          anchor.x.float32 / 1000 + 0.5'f +
            (turn[0].float32 * point.x - turn[1].float32 * point.z) / 1000,
          point.y,
          anchor.z.float32 / 1000 + 0.5'f +
            (turn[1].float32 * point.x + turn[0].float32 * point.z) / 1000
        )
      result.addOccluder(transformed)
  for plant in groundPlants(seed):
    let center = vec3(plant.x.float32 / 1000 + 0.5'f, 0,
      plant.z.float32 / 1000 + 0.5'f)
    if plant.variant in 3 .. 5:
      result.addOccluder(center + vec3(0, 0.3, 0),
        vec3(1.1, plant.height * 0.95'f, 1.1) * plant.size)
    else:
      result.addOccluder(center + vec3(0, 0.6, 0),
        vec3(plant.radius.float32 / 1000, 1.4, plant.radius.float32 / 1000))
      result.addOccluder(center + vec3(0, 3.4'f * plant.size * plant.height, 0),
        vec3(3.0, 2.0'f * plant.height, 3.0) * plant.size)
  for obstacle in villageObstacles(seed):
    if obstacle.kind != FenceObstacle:
      continue
    let
      first = vec2(obstacle.ax.float32, obstacle.az.float32) / 1000 + vec2(0.5)
      last = vec2(obstacle.bx.float32, obstacle.bz.float32) / 1000 + vec2(0.5)
      steps = max(1, int(ceil(length(last - first) / 0.2'f)))
    for i in 0 .. steps:
      let point = mix(first, last, i.float32 / steps.float32)
      result.addOccluder(vec3(point.x, 0.35, point.y), vec3(0.2, 0.7, 0.2))
  result.addOccluder(vec3(TownWell.x + 0.5'f, 1, TownWell.y + 0.5'f),
    vec3(1.2, 2.6, 1.2))
