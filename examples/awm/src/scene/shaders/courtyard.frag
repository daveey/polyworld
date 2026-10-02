precision highp sampler2DShadow;
in vec3 worldPosition;
in vec3 worldNormal;
in vec3 surfaceColor;
in vec4 shadowPosition;
in vec2 surfaceUv;
flat in float surfaceMaterial;
uniform sampler2DShadow shadowMap;
uniform sampler2D stoneNormalMap;
uniform float normalStrength;
uniform float slopeBroad;
uniform float scaleBroad;
uniform float lampIntensity;
uniform vec3 firstLamp;
uniform vec3 secondLamp;
uniform int playerCount;
uniform float arenaRadius;
uniform float balconyLampRadius;
uniform float balconyLampHalfAngle;
uniform bool normalsOnly;
uniform mat4 normalView;
uniform vec3 cameraEye;
uniform float cameraSide;
uniform float time;
// The balconies' turn relative to this surface: lamps ride on the balconies.
uniform float stageYaw;
out vec4 outputColor;

vec2 stoneSlope(vec2 uv) {
    // The normal texture is linear data, with +Y green, mipmapped, repeated.
    vec3 broad = texture(stoneNormalMap, uv / max(scaleBroad, 0.01)).xyz * 2.0 - 1.0;
    return broad.xy / max(broad.z, 0.45) * slopeBroad * normalStrength;
}
vec3 stoneNormal(vec3 p, vec3 n) {
    // World-aligned triplanar slopes need no mesh tangents and keep the
    // curved ring slabs, bevels, wall faces and rotated stones consistent.
    vec3 s = mix(vec3(-1), vec3(1), greaterThanEqual(n, vec3(0)));
    vec3 weights = pow(abs(n), vec3(4));
    weights /= max(dot(weights, vec3(1)), 0.0001);
    vec2 x = stoneSlope(vec2(-s.x * p.z, p.y));
    vec2 y = stoneSlope(vec2(p.x, -s.y * p.z));
    vec2 z = stoneSlope(vec2(s.z * p.x, p.y));
    vec3 slope = vec3(0, x.y, -s.x * x.x) * weights.x +
                 vec3(y.x, 0, -s.y * y.y) * weights.y +
                 vec3(s.z * z.x, z.y, 0) * weights.z;
    return normalize(n + slope - n * dot(slope, n));
}

float hash(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}
float noise(vec3 p) {
    vec3 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(hash(i), hash(i + vec3(1,0,0)), f.x),
                   mix(hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y),
               mix(mix(hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x),
                   mix(hash(i + vec3(0,1,1)), hash(i + vec3(1,1,1)), f.x), f.y), f.z);
}
float visibility(vec3 n, vec3 light) {
    vec3 p = shadowPosition.xyz / shadowPosition.w * 0.5 + 0.5;
    if (p.z > 1.0 || p.z < 0.0 || any(lessThan(p.xy, vec2(0))) ||
        any(greaterThan(p.xy, vec2(1)))) return 1.0;
    float bias = max(0.00030, 0.0010 * (1.0 - max(0.0, dot(n, light))));
    float sum = 0.0;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++)
            sum += texture(shadowMap, vec3(p.xy + vec2(x, y) * 1.35 / 2048.0,
                                         p.z - bias));
    return sum / 9.0;
}
// Key light, ambient and lamp color mirror courtyard.nim's Courtyard*
// constants, which light the heroes the same way.
vec3 lamp(vec3 p, vec3 n, vec3 source, float phase) {
    vec3 delta = source - p;
    float d = length(delta);
    float flicker = 0.96 + 0.025 * sin(time * 5.1 + phase) +
                          0.018 * sin(time * 8.3 + phase);
    return vec3(1.0, 0.45, 0.115) * (lampIntensity / (1.0 + d * d * 1.2)) *
        (0.18 + 0.82 * max(0.0, dot(n, normalize(delta)))) * flicker;
}
void main() {
    vec3 p = worldPosition;
    vec3 n = normalize(worldNormal);
    vec3 geometricNormal = n;
    vec3 base = surfaceColor;
    float material = surfaceMaterial;
    float grain = noise(p * 37.0);
    float broad = noise(p * 2.4) * 0.64 + noise(p * 8.6) * 0.36;
    if (material < 0.5 || material > 4.5) {
        base *= 0.845 + broad * 0.28 + grain * 0.06;
        // Fine worn limestone pores, broad mineral variation, restrained moss.
        float pore = smoothstep(0.73, 0.88, noise(p * 71.0));
        base *= 1.0 - pore * 0.06;
        float edge = max(smoothstep(8.4, 10.2, abs(p.x)),
                         smoothstep(5.6, 8.5, abs(p.z)));
        if (playerCount > 2)
            edge = smoothstep(arenaRadius - 1.6, arenaRadius + 0.1, length(p.xz));
        float moss = smoothstep(0.55, 0.76, broad) * edge *
            (0.35 + 0.45 * max(n.y, 0.0));
        base = mix(base, vec3(0.20, 0.235, 0.105), moss * 0.50);
        if (material < 0.5) n = stoneNormal(p, n);
    } else if (material < 1.5) {
        base *= 0.88 + grain * 0.20;
    } else if (material < 2.5) {
        base *= 0.90 + broad * 0.18;
    } else if (material < 3.5) {
        // The same neutral compass motif on both banners; no class insignia.
        vec2 uv = surfaceUv;
        vec2 q = (uv - vec2(0.5, 0.47)) * vec2(1.0, 1.55);
        float diamond = abs(q.x) / 0.25 + abs(q.y) / 0.35;
        float frame = 1.0 - smoothstep(0.022, 0.033, abs(diamond - 1.0));
        float vertical = max(abs(q.x) / 0.055 + abs(q.y) / 0.29,
                             abs(q.x) / 0.19 + abs(q.y) / 0.075);
        float compass = 1.0 - smoothstep(0.96, 1.04, vertical);
        float hem = min(min(uv.x, 1.0 - uv.x), 1.0 - uv.y);
        float border = (1.0 - smoothstep(0.006, 0.012, abs(hem - 0.036)));
        base = mix(base, vec3(0.63, 0.48, 0.245), max(max(frame, compass), border));
        base *= 0.90 + 0.10 * sin(uv.x * 14.0 + uv.y * 2.0);
        base *= 0.97 + 0.03 * sin(uv.x * 770.0) * sin(uv.y * 900.0);
        n = normalize(cross(dFdx(p), dFdy(p)));
        if (dot(n, cameraEye - p) < 0.0) n = -n;
    }
    if (normalsOnly) {
        // Replayed with the finished scene depth: hidden slabs cannot put
        // their normals on a card or hero. Alpha marks a valid material normal.
        outputColor = vec4(normalize(mat3(normalView) * n) * 0.5 + 0.5, 1.0);
        return;
    }
    vec3 light = normalize(vec3(-0.48 * cameraSide, 0.85, 0.35 * cameraSide));
    // Shadow bias follows the actual mesh; detail normals must not cause acne.
    float sun = visibility(geometricNormal, light);
    float diffuse = max(0.0, dot(n, light));
    vec3 ambient = mix(vec3(0.33, 0.35, 0.39), vec3(0.62, 0.64, 0.68),
                       max(0.0, n.y));
    vec3 lighting = ambient + vec3(0.67, 0.53, 0.36) * diffuse * sun;
    if (playerCount > 2) {
        // Six nearest lamps keep cost fixed as more islands are added. Their
        // radial positions exactly match the reused lantern meshes, without
        // imposing a uniform-array limit on the number of player balconies.
        // Lamps are placed in the balconies' frame, turned by stageYaw.
        float c = cos(stageYaw), s = sin(stageYaw);
        vec3 lp = vec3(p.x * c - p.z * s, p.y, p.x * s + p.z * c);
        vec3 ln = vec3(n.x * c - n.z * s, n.y, n.x * s + n.z * c);
        float count = float(playerCount);
        float stepAngle = 6.28318530718 / count;
        float nearest = floor(atan(-lp.x, lp.z + 0.00001) / stepAngle + 0.5);
        for (int offset = -1; offset <= 1; offset++) {
            float seat = mod(nearest + float(offset), count);
            float yaw = seat * stepAngle;
            for (int end = -1; end <= 1; end += 2) {
                float angle = float(end) * balconyLampHalfAngle - yaw;
                vec3 source = vec3(sin(angle) * balconyLampRadius, 1.25,
                                   cos(angle) * balconyLampRadius);
                lighting += lamp(lp, ln, source, seat * 2.0 + float(end));
            }
        }
    } else {
        lighting += lamp(p, n, firstLamp, 0.0);
        lighting += lamp(p, n, secondLamp, 2.0);
    }
    vec3 result = base * lighting;
    if (material > 0.5 && material < 1.5) {
        vec3 halfVector = normalize(light + normalize(cameraEye - p));
        result += vec3(0.20, 0.15, 0.06) * pow(max(0.0, dot(n, halfVector)), 24.0) * sun;
    }
    if (material > 3.5 && material < 4.5)
        result = vec3(1.0, 0.68, 0.25) * (0.95 + 0.04 * sin(time * 6.0));
    float sceneScale = playerCount > 2 ? 11.5 / max(arenaRadius, 11.5) : 1.0;
    float depth = max(0.0, -p.z * cameraSide * sceneScale - 8.0);
    float fog = 1.0 - exp(-depth * 0.055);
    vec3 mist = vec3(0.035, 0.055, 0.10);
    result = mix(result, mist, fog);
    // Keep the floor quiet and the perimeter shaded around the original HUD.
    float edgeShade = 1.0 - smoothstep(6.8, 14.0, length(p.xz) * sceneScale) * 0.18;
    result *= edgeShade;
    outputColor = vec4(result, 1.0);
}
