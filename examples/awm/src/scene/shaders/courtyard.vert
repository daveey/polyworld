layout(location=0) in vec3 position;
layout(location=1) in vec3 normal;
layout(location=2) in vec3 color;
layout(location=3) in float material;
layout(location=4) in vec2 uv;
uniform mat4 viewProjection;
uniform mat4 lightMatrix;
uniform float time;
out vec3 worldPosition;
out vec3 worldNormal;
out vec3 surfaceColor;
out vec4 shadowPosition;
out vec2 surfaceUv;
flat out float surfaceMaterial;

void main() {
    vec3 p = position;
    if (material > 2.5 && material < 3.5) {
        float wave = sin(p.x * 4.3 + time * 1.35 + uv.y * 3.0);
        p.z += wave * 0.075 * uv.y * uv.y;
        p.x += sin(time * 0.85 + uv.y * 4.2) * 0.025 * uv.y;
    }
    worldPosition = p;
    worldNormal = normal;
    surfaceColor = color;
    surfaceMaterial = material;
    surfaceUv = uv;
    shadowPosition = lightMatrix * vec4(p, 1.0);
    gl_Position = viewProjection * vec4(p, 1.0);
}
