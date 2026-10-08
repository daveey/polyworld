in vec2 skyUv;
uniform mat4 inverseViewProjection;
uniform vec3 cameraEye;
uniform float time;
uniform float skyBrightness;
out vec4 outputColor;
const float PI = 3.14159265359;

vec3 hash3(vec2 p) {
    vec3 q = fract(vec3(p.x, p.y, p.x) * vec3(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yxz + 33.33);
    return fract((q.xxy + q.yzz) * q.zyx);
}
float cloudHash(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}
float cloudNoise(vec3 p) {
    vec3 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(cloudHash(i), cloudHash(i + vec3(1,0,0)), f.x),
                   mix(cloudHash(i + vec3(0,1,0)), cloudHash(i + vec3(1,1,0)), f.x), f.y),
               mix(mix(cloudHash(i + vec3(0,0,1)), cloudHash(i + vec3(1,0,1)), f.x),
                   mix(cloudHash(i + vec3(0,1,1)), cloudHash(i + vec3(1,1,1)), f.x), f.y), f.z);
}
float cloudLayers(vec3 p) {
    // Sample a sphere in 3D, so the nebula has no longitude seam.
    float result = 0.0, weight = 0.5333;
    for (int i = 0; i < 4; i++) {
        result += cloudNoise(p) * weight;
        p = p * 2.03 + vec3(13.1, 7.7, 19.3);
        weight *= 0.5;
    }
    return result;
}
vec3 stars(vec2 uv, float cells, float fill, float brightness, float layer) {
    vec2 wave = vec2(sin(time * 0.12 + layer), cos(time * 0.095 + layer * 1.7));
    uv += wave * (0.00065 + layer * 0.00030);
    uv += time * vec2(0.00030, 0.000035) * (1.0 + layer * 0.65);
    // Different shell distances give camera-relative parallax, even during
    // a small camera adjustment; the slow wave is visible at a fixed camera.
    uv += cameraEye.xz * (0.000006 + layer * 0.000010);
    vec2 grid = uv * cells;
    vec2 cell = floor(grid), local = fract(grid);
    float pixel = max(length(fwidth(grid)), 0.005);
    vec3 result = vec3(0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 neighbor = vec2(x, y);
            vec2 id = cell + neighbor;
            id.x = mod(id.x, cells); // Longitude wraps without a seam.
            vec3 rnd = hash3(id + layer * 79.1);
            if (rnd.z > fill) continue;
            vec2 delta = neighbor + 0.15 + rnd.xy * 0.70 - local;
            // Half-sized cores, with a separately sized diffuse glow. Keep
            // subpixel filtering so distant stars do not flicker when moving.
            float radius = 1.5 * (0.030 + pow(rnd.x, 10.0) * 0.054);
            float effective = max(radius, pixel * 0.48);
            float d2 = dot(delta, delta);
            float core = exp(-d2 / (effective * effective));
            float energy = min(1.0, radius * radius / (pixel * pixel * 0.13));
            float haloRadius = max(radius * 7.0, pixel * 0.9);
            float halo = exp(-d2 / (haloRadius * haloRadius)) * 0.075;
            // Compact support fits the neighbor search, so scrolling cannot
            // reveal a suddenly appearing glow at the edge of a star cell.
            halo *= 1.0 - smoothstep(0.70, 1.0, sqrt(d2));
            float twinkle = 0.72 + 0.22 * sin(time * (0.65 + rnd.y * 0.80) + rnd.x * 71.0)
                                + 0.06 * sin(time * 0.37 + rnd.y * 34.0);
            float glint = 0.0;
            if (rnd.x > 0.985) {
                vec2 a = abs(delta) / effective;
                glint = (exp(-a.x * a.x * 42.0 - a.y * a.y * 0.45) +
                         exp(-a.y * a.y * 42.0 - a.x * a.x * 0.45)) * 0.16;
            }
            vec3 tint = mix(vec3(0.72, 0.80, 1.0), vec3(1.0, 0.91, 0.85), rnd.y);
            result += tint * (core + halo + glint) * energy * brightness * 3.0 * twinkle;
        }
    }
    return result;
}
void main() {
    vec4 farPoint = inverseViewProjection * vec4(skyUv * 2.0 - 1.0, 1.0, 1.0);
    vec3 ray = normalize(farPoint.xyz / farPoint.w - cameraEye);
    vec2 uv = vec2(atan(ray.z, ray.x) / (2.0 * PI) + 0.5,
                   asin(clamp(ray.y, -1.0, 1.0)) / PI + 0.5);
    vec3 drift = time * vec3(-0.012, 0.004, 0.006);
    drift += vec3(sin(time * 0.045), cos(time * 0.038), sin(time * 0.031)) * 0.12;
    vec3 p = ray * 6.0 + drift + cameraEye * 0.0015;
    vec3 warp = vec3(cloudNoise(p * 0.65), cloudNoise(p * 0.65 + 17.3),
                     cloudNoise(p * 0.65 - 9.1));
    float dust = cloudLayers(p + warp * 2.2);
    float wisps = cloudLayers(p * 2.4 - drift * 0.7 + warp);
    float belt = exp(-pow((uv.y - 0.29 + 0.07 * sin(uv.x * 4.0 * PI + time * 0.012)) * 5.5, 2.0));
    float density = smoothstep(0.24, 0.78, dust) * belt;
    float rose = smoothstep(0.32, 0.76, cloudNoise(p * 0.7 + vec3(4, 9, 2)));
    float filaments = smoothstep(0.43, 0.80, wisps) * density;
    float breath = 0.94 + 0.06 * sin(time * 0.18 + dust * 8.0);
    vec3 sky = vec3(0.012, 0.019, 0.049);
    sky += vec3(0.065, 0.10, 0.23) * (0.30 + dust * 0.70) * belt;
    sky += mix(vec3(0.11, 0.12, 0.31), vec3(0.36, 0.16, 0.32), rose) * density * breath;
    sky += mix(vec3(0.17, 0.22, 0.40), vec3(0.52, 0.29, 0.40), rose) * filaments;
    sky += stars(uv, 420.0, 0.32, 0.68, 0.0);
    sky += stars(uv, 210.0, 0.22, 1.00, 1.0);
    sky += stars(uv, 85.0, 0.15, 1.45, 2.0);
    outputColor = vec4(sky * skyBrightness, 1.0);
}
