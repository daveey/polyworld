## A small gathering terrace built from the battlefield's sandstone, brass,
## cloth and lanterns. The heroes stay in the open against the same night sky.
import std/[math, random]
import vmath
import courtyard

const
  HeroSelectPositions* = [vec3(-4.2, 0.24, 0), vec3(0, 0.24, 0),
    vec3(4.2, 0.24, 0)]
  HeroSelectCameraEye* = vec3(0, 4.4, 13.8)
  HeroSelectCameraTarget* = vec3(0, 1.7, 0)
  HeroSelectLampPositions* = [vec3(-6.55, 1.42, -0.75),
    vec3(6.55, 1.42, -0.75)]
  HeroSelectBannerColors* = [vec3(0.11, 0.25, 0.17),
    vec3(0.31, 0.115, 0.105), vec3(0.20, 0.16, 0.34)]
  StageStone = vec3(0.43, 0.395, 0.33)
  StageBrass = vec3(0.43, 0.31, 0.13)
  StageIron = vec3(0.18, 0.145, 0.095)
  Metal = 1.0'f32

proc octagon(center: Vec3, halfWidth, halfDepth, chamfer: float32): seq[Vec2] =
  for p in [vec2(-halfWidth + chamfer, -halfDepth),
      vec2(halfWidth - chamfer, -halfDepth),
      vec2(halfWidth, -halfDepth + chamfer),
      vec2(halfWidth, halfDepth - chamfer),
      vec2(halfWidth - chamfer, halfDepth),
      vec2(-halfWidth + chamfer, halfDepth),
      vec2(-halfWidth, halfDepth - chamfer),
      vec2(-halfWidth, -halfDepth + chamfer)]:
    result.add p + vec2(center.x, center.z)

proc buildHeroSelectStageMesh*(): CourtyardMesh =
  var rng = initRand(20261001)
  # Each paving stone has its own bevel. Irregular end stones keep the small
  # terrace from reading as one enormous block beneath the three characters.
  for row in -2 .. 2:
    for column in -6 .. 6:
      let
        x = column.float32 * 1.12'f32 + (row mod 2).float32 * 0.32'f32
        z = row.float32 * 1.04'f32 - 0.22'f32
        endStone = abs(column) == 6
        depth = if endStone: 0.76'f32 else: 1.005'f32
      if endStone and row == 2: continue
      result.addBlock(vec3(x, -0.07, z), vec3(1.08, 0.19, depth),
        StageStone * rng.rand(0.87 .. 1.08).float32, bevel = 0.027)
  result.pavingCount = result.vertices.len

  for index, hero in HeroSelectPositions:
    # Broad, low octagonal slabs give the characters a clear, grounded stage.
    # The top is exactly the height used by the animated character placement.
    result.stoneSlab(octagon(hero, 1.58, 1.30, 0.38),
      -0.20, 0.105, StageStone * 0.82'f32, bevel = 0.065)
    result.stoneSlab(octagon(hero, 1.43, 1.16, 0.33),
      0.08, hero.y, StageStone * 1.05'f32, bevel = 0.042)
    # A slender inset frame picks up the warm lantern light around each slab.
    let
      outer = octagon(hero, 1.32, 1.05, 0.29)
      inner = octagon(hero, 1.294, 1.024, 0.29)
    for edge in 0 ..< outer.len:
      let next = (edge + 1) mod outer.len
      result.stoneSlab([outer[edge], outer[next], inner[next], inner[edge]],
        hero.y + 0.002'f32, hero.y + 0.008'f32, StageBrass,
        bevel = 0.002, material = Metal)
    # Hand-cut center joint and a small brass diamond on the front edge.
    result.addBlock(vec3(hero.x, hero.y + 0.009'f32, 0),
      vec3(0.018, 0.005, 1.84), StageStone * 0.69'f32, bevel = 0.001)
    result.addBlock(vec3(hero.x, hero.y + 0.014'f32, 0.94),
      vec3(0.12, 0.008, 0.12), StageBrass * 1.2'f32,
      yaw = PI.float32 / 4, bevel = 0.002, material = Metal)

    # The cloth is behind the body, high enough to show its stitched crest.
    # It uses the courtyard's real rippling cloth material and gold embroidery.
    let bannerTop = vec3(hero.x, 5.20, -1.72)
    for side in [-1.0'f32, 1.0'f32]:
      let post = vec3(hero.x + side * 1.10'f32, 0, -1.80)
      result.addBlock(post + vec3(0, 0.25, 0), vec3(0.49, 0.48, 0.53),
        StageStone * 0.94'f32, bevel = 0.055)
      result.addBlock(post + vec3(0, 0.51, 0), vec3(0.59, 0.10, 0.61),
        StageStone * 1.12'f32, bevel = 0.035)
      result.beam(post + vec3(0, 0.55, 0), post + vec3(0, 5.42, 0),
        0.065, StageIron)
      result.addBlock(post + vec3(0, 5.46, 0), vec3(0.12, 0.19, 0.12),
        StageBrass, yaw = PI.float32 / 4, bevel = 0.02, material = Metal)
    result.banner(bannerTop, HeroSelectBannerColors[index], scale = 1.28)

  # Lantern towers bracket the gathering. Their light positions are exported
  # for the characters as well as supplied to the shared stone shader.
  for lamp in HeroSelectLampPositions:
    result.addBlock(vec3(lamp.x, 0.29, lamp.z), vec3(0.87, 0.62, 0.82),
      StageStone * 0.9'f32, bevel = 0.07)
    result.addBlock(vec3(lamp.x, 0.70, lamp.z), vec3(0.69, 0.22, 0.68),
      StageStone * 1.03'f32, bevel = 0.035)
    result.lantern(lamp)

  # A broken low parapet and trailing ivy connect the terrace to the arena;
  # open gaps preserve the silhouetted banners and the starry background.
  for side in [-1.0'f32, 1.0'f32]:
    for column in 0 .. 2:
      let x = side * (5.0'f32 + column.float32 * 0.86'f32)
      result.addBlock(vec3(x, 0.18, -2.47), vec3(0.80, 0.46, 0.61),
        StageStone * rng.rand(0.87 .. 1.08).float32,
        yaw = rng.rand(-0.055 .. 0.055).float32, bevel = 0.052)
      if column != 1:
        result.addBlock(vec3(x + side * 0.075'f32, 0.56, -2.47),
          vec3(0.79, 0.29, 0.65), StageStone * 1.03'f32,
          yaw = rng.rand(-0.08 .. 0.08).float32, bevel = 0.044)
      result.ivy(rng, vec3(x, -0.17, -2.09),
        rng.rand(0.49 .. 0.86).float32)
    for sprig in 0 .. 3:
      result.ivy(rng, vec3(side * (6.56'f32 + sprig.float32 * 0.13'f32),
        -0.36, 0.51'f32 + sprig.float32 * 0.29'f32),
        rng.rand(0.37 .. 0.68).float32)
  result.commonCount = result.vertices.len

when not defined(headless):
  type HeroSelectStage* = CourtyardRenderer

  proc initHeroSelectStage*(): HeroSelectStage =
    result = initCourtyardRenderer(buildHeroSelectStageMesh())
    result.lamps = HeroSelectLampPositions
