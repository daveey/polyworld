import
  vmath,
  polyworld/[occlusions, shadows]

echo "Testing local ambient occlusion"
var field = initOcclusionField(128, vec2(-8), vec2(16))
doAssert field.ambientVisibility(vec3(0)) == 1
field.addOccluder(vec3(0, 1.5, 0), vec3(1, 1.5, 1))
let
  under = field.ambientVisibility(vec3(0))
  beside = field.ambientVisibility(vec3(1.3, 0, 0))
  open = field.ambientVisibility(vec3(6, 0, 0))
doAssert under < 0.1
doAssert beside > under and beside < 0.95
doAssert open == 1
doAssert field.ambientVisibility(vec3(0, 4, 0)) == 1,
  "Contact shading must not darken surfaces above their blockers"
let pixels = bakeOcclusion(field)
doAssert pixels.len == 128 * 128 * 4
for i in 0 ..< 128 * 128:
  doAssert pixels[i * 4] >= 132
  for channel in 1 ..< 4:
    doAssert pixels[i * 4 + channel] >= pixels[i * 4 + channel - 1],
      "Ambient visibility must increase with receiver height"

echo "Testing a roof with an open garden"
field = initOcclusionField(128, vec2(-8), vec2(16))
field.addOccluder([vec3(-2, 3, -3), vec3(2, 3, -3), vec3(-2, 3, 0)])
field.addOccluder([vec3(2, 3, -3), vec3(2, 3, 0), vec3(-2, 3, 0)])
doAssert field.ambientVisibility(vec3(0, 0, -1.5)) < 0.1
doAssert field.ambientVisibility(vec3(0, 0, 2)) > 0.95
doAssert field.ambientVisibility(vec3(0, 3, -1.5)) == 1

echo "Testing a rotated daylight orbit"
applySunHour(13)
let original = sunDirection
applySunHour(13, 135, 0.72)
doAssert sunDirection.x < 0 and sunDirection.z > 0
doAssert sunDirection.y < original.y
doAssert abs(length(sunDirection) - 1) < 0.00001'f
doAssert lightLevel == 1
let
  caster = vec4(sunDirection * 10, 1)
  projected = sunLightMvp0 * caster
doAssert abs(projected.x) < 0.0001'f and abs(projected.y) < 0.0001'f,
  "Shadow maps and surface lighting must use the same rotated sun"
applySunHour(13)
doAssert length(sunDirection - original) < 0.00001'f,
  "Other games retain the shared default orbit"
applySunHour(23, 135, 0.72)
doAssert solarElevation < 0
echo "Ambient occlusion and daylight checks passed."
