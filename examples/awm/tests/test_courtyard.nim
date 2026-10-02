## Geometry checks run without a window or graphics driver.
import std/[math, random, unittest]
import vmath
import ../src/scene/courtyard

suite "Old Crossroads battlefield":
  let mesh = buildCourtyardMesh()

  test "complete triangles and bounded mesh cost":
    check mesh.commonCount > 0
    check mesh.backdropCount > 0
    check mesh.commonCount mod 3 == 0
    check mesh.backdropCount mod 3 == 0
    check mesh.vertices.len == mesh.commonCount + mesh.backdropCount * 2
    check mesh.vertices.len < 400_000

  test "finite vertices and unit face normals":
    var valid = true
    for v in mesh.vertices:
      for value in [v.position.x, v.position.y, v.position.z,
          v.normal.x, v.normal.y, v.normal.z, v.color.x, v.color.y,
          v.color.z, v.uv.x, v.uv.y]:
        if value.classify in {fcNan, fcInf, fcNegInf}: valid = false
      if abs(length(v.normal) - 1) > 0.0001: valid = false
    check valid

  test "outer paving stops at the tower walls":
    var inside = true
    check mesh.pavingCount > 0
    for i in 0 ..< mesh.pavingCount:
      let p = mesh.vertices[i].position
      if abs(p.x) > PavingHalfWidth + 0.0001 or
          abs(p.z) > PavingHalfDepth + 0.0001: inside = false
    check inside

  test "background scenery no longer covers the sky beyond the enclosure":
    var inside = true
    for v in mesh.vertices:
      if abs(v.position.z) > 8.0 or abs(v.position.x) > 10.8: inside = false
    check inside

  test "no raised scenery intersects either row of cards":
    var clear = true
    for i in 0 ..< mesh.commonCount:
      let p = mesh.vertices[i].position
      if abs(p.x) < 5.8 and abs(p.z) < 2.5 and p.y >= 0.12:
        clear = false
    check clear

  test "both card piles fit above their stone recesses":
    var clear = true
    for i in 0 ..< mesh.commonCount:
      let p = mesh.vertices[i].position
      if abs(abs(p.x) - 7.25) < 0.73 and abs(abs(p.z) - 3.7) < 1.03:
        if p.y >= 0.12: clear = false
    check clear

  test "the reverse seat has exactly rotated background geometry":
    var matches = true
    for i in 0 ..< mesh.backdropCount:
      let
        a = mesh.vertices[mesh.commonCount + i]
        b = mesh.vertices[mesh.commonCount + mesh.backdropCount + i]
      if b.position != vec3(-a.position.x, a.position.y, -a.position.z) or
          b.normal != vec3(-a.normal.x, a.normal.y, -a.normal.z) or
          b.color != a.color or b.uv != a.uv or b.material != a.material:
        matches = false
    check matches

  test "rebuilding is deterministic and does not consume the global RNG":
    randomize(42)
    let expected = rand(1_000_000)
    randomize(42)
    let rebuilt = buildCourtyardMesh()
    check rand(1_000_000) == expected
    check rebuilt.vertices == mesh.vertices
