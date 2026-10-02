## Prepare the linear OpenGL (+Y) rock normal map from the material source.
## nim r --out:build/render-stone-normals tools/render_stone_normals.nim
## Optional first argument overrides the destination for validation/builds.
import std/[math, os]
import pixie, vmath
import ../src/paths

const Size = 512

proc hash(x, y, period: int): float64 =
  let
    px = (x mod period + period) mod period
    py = (y mod period + period) mod period
    h = sin(px.float64 * 127.1 + py.float64 * 311.7 + 43.17) * 43758.5453
  h - floor(h)

proc periodicNoise(u, v: float64, cells: int): float64 =
  let
    x = u * cells.float64
    y = v * cells.float64
    ix = int(floor(x))
    iy = int(floor(y))
    fx = x - floor(x)
    fy = y - floor(y)
    sx = fx * fx * fx * (fx * (fx * 6 - 15) + 10)
    sy = fy * fy * fy * (fy * (fy * 6 - 15) + 10)
    a = hash(ix, iy, cells) * (1 - sx) + hash(ix + 1, iy, cells) * sx
    b = hash(ix, iy + 1, cells) * (1 - sx) + hash(ix + 1, iy + 1, cells) * sx
  a * (1 - sy) + b * sy

proc encoded(n: Vec3): ColorRGBX =
  let unit = normalize(n)
  rgbx(uint8(round((unit.x * 0.5 + 0.5) * 255)),
    uint8(round((unit.y * 0.5 + 0.5) * 255)),
    uint8(round((unit.z * 0.5 + 0.5) * 255)), 255)

proc rockNormal(): Image =
  # Normalize the original source after downsampling; do not apply sRGB.
  let source = readImage(artworkRoot() / "battlefield/source/rock-normal.png").resize(Size, Size)
  var slopes = newSeq[Vec2](Size * Size)
  for i, p in source.data:
    let n = vec3(p.r.float32, p.g.float32, p.b.float32) / 127.5'f32 - vec3(1)
    slopes[i] = vec2(n.x, n.y) / max(n.z, 0.35'f32) * 0.70'f32
  result = newImage(Size, Size)
  for y in 0 ..< Size:
    for x in 0 ..< Size:
      # Match opposing edges in a narrow smooth strip, including the corners.
      # Blend slopes before encoding so all final texels remain unit normals.
      let
        tx = clamp(1 - min(x, Size - 1 - x).float32 / 12, 0.0'f32, 1.0'f32)
        ty = clamp(1 - min(y, Size - 1 - y).float32 / 12, 0.0'f32, 1.0'f32)
        wx = tx * tx * (3 - 2 * tx) * 0.5'f32
        wy = ty * ty * (3 - 2 * ty) * 0.5'f32
        a = mix(slopes[y * Size + x], slopes[y * Size + Size - 1 - x], wx)
        b = mix(slopes[(Size - 1 - y) * Size + x],
          slopes[(Size - 1 - y) * Size + Size - 1 - x], wx)
        slope = mix(a, b, wy)
      result[x, y] = encoded(vec3(slope.x, slope.y, 1))

let destination = if paramCount() > 0: paramStr(1)
  else: artworkRoot() / "battlefield/textures"
createDir(destination)
rockNormal().writeFile(destination / "stone-slab-normal.png")

echo "Prepared the rock normal map: ", destination
