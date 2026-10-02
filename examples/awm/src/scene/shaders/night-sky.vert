out vec2 skyUv;
void main() {
    skyUv = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    gl_Position = vec4(skyUv * 2.0 - 1.0, 1.0, 1.0);
}
