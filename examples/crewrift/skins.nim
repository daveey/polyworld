## The authored ship skin, with atlas UV transforms baked for toon rendering.

import
  std/math,
  chroma, gltf, vmath,
  polyworld/common,
  sim

const
  ShipModelPath* = DataRoot & "/crewrift/crewRift-map1-textured.glb"
  ShipModelScale* = 12.5'f

proc loadShipSkin*(): Node =
  ## Combines static placements into one atlas batch without changing the art.
  var file: GltfFile
  try:
    file = readGltfFile(ShipModelPath)
  except GltfError, IOError:
    raise newException(
      CrewriftError,
      "Cannot load ship model: " & getCurrentExceptionMsg()
    )
  file.root.updateTransforms()
  let combined = Primitive(mode: TrianglesMode)
  for node in file.root.walkNodes():
    if not node.visible or node.mesh == nil:
      continue
    for primitive in node.mesh.primitives:
      if combined.material == nil:
        combined.material = primitive.material
      elif primitive.material.baseColor != combined.material.baseColor:
        raise newException(CrewriftError, "Ship model needs one texture atlas.")
      let
        offset = combined.points.len.uint32
        transform = primitive.material.baseColorTransform
        cosine = cos(transform.rotation)
        sine = sin(transform.rotation)
        normal = node.mat.normalMatrix()
      for i, point in primitive.points:
        combined.points.add (node.mat * point).xyz * ShipModelScale
        combined.normals.add normalize(normal * primitive.normals[i])
        let uv = primitive.uvs[i] * transform.scale
        combined.uvs.add transform.offset + vec2(
          cosine * uv.x - sine * uv.y,
          sine * uv.x + cosine * uv.y
        )
        combined.colors.add rgbx(255, 255, 255, 255)
      for index in primitive.indices16:
        combined.indices32.add offset + index.uint32
      for index in primitive.indices32:
        combined.indices32.add offset + index
      if primitive.indices16.len == 0 and primitive.indices32.len == 0:
        for i in 0 ..< primitive.points.len:
          combined.indices32.add offset + i.uint32
  if combined.material == nil:
    raise newException(CrewriftError, "Ship model has no visible geometry.")
  combined.material.baseColorTransform = TextureTransform(scale: vec2(1))
  result = Node(
    name: "Crewrift map 1", visible: true,
    rot: quat(0, 0, 0, 1), scale: vec3(1),
    mesh: Mesh(primitives: @[combined])
  )
