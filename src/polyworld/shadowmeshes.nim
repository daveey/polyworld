import gltf

proc shadowPrimitives*(mesh: Mesh): seq[Primitive] =
  ## Combines opaque triangles sharing a node's transform and skin palette.
  var
    opaque: seq[Primitive]
    skinned = -1
  for primitive in mesh.primitives:
    if primitive.material.alphaMode == BlendAlphaMode:
      continue
    result.add primitive
  for primitive in result:
    if primitive.material.alphaMode != OpaqueAlphaMode or
      primitive.mode != TrianglesMode:
        continue
    let format = (primitive.jointWeights.len > 0).ord
    if skinned >= 0 and skinned != format:
      return
    if format == 1 and
      (primitive.jointWeights.len != primitive.points.len or
      primitive.jointIds.len != primitive.points.len):
        return
    skinned = format
    opaque.add primitive
  if opaque.len < 2:
    return
  let
    material = Material()
    merged = Primitive(
      mode: TrianglesMode,
      material: material
    )
  material[] = opaque[0].material[]
  # Batched buffers own their textures so clearing them preserves the source.
  material.data = nil
  for primitive in opaque:
    let offset = merged.points.len.uint32
    merged.points.add primitive.points
    merged.jointIds.add primitive.jointIds
    merged.jointWeights.add primitive.jointWeights
    if primitive.indices16.len > 0:
      for index in primitive.indices16:
        merged.indices32.add offset + index.uint32
    elif primitive.indices32.len > 0:
      for index in primitive.indices32:
        merged.indices32.add offset + index
    else:
      for i in 0 ..< primitive.points.len:
        merged.indices32.add offset + i.uint32
  if merged.points.len <= uint16.high.int + 1:
    for index in merged.indices32:
      merged.indices16.add index.uint16
    merged.indices32.setLen(0)
  result.setLen(0)
  result.add merged
  for primitive in mesh.primitives:
    if primitive.material.alphaMode == MaskAlphaMode or
      (primitive.material.alphaMode == OpaqueAlphaMode and
      primitive.mode != TrianglesMode):
        result.add primitive
