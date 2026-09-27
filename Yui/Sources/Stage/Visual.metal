// The visual's shaders (YUI-124 step 2, spec yuigui/spec/VISUAL.md): Metal ports
// of yuigui site/lib/visual/shaders.mjs, same uniforms, same math, same look.
// Each is cheap on purpose: 4-octave noise at most, no loops over the screen,
// drawn at half resolution (grain three quarters) by StageVisual.swift.
//
// `frag` is in drawable pixels with y up from the bottom, like gl_FragCoord.
// Each look returns its color and writes a mask `m` (0..1): how much of the
// colors shows at that pixel. `finish` does the rest: dim, ground, scrim.

#include <metal_stdlib>
using namespace metal;

struct VisualUniforms {
    float2 res;
    float time;   // seconds, already scaled by the look's pace
    float level;  // 0..1, the sound after the look's envelope
    float dim;    // 1 alone, less behind words
    float scrim;  // the ground laid over the words' zone
    float2 zone;  // the zone's bottom and top edge, fractions of the height from the bottom
    float3 a, b, c, ground;
};

struct VisualVertex {
    float4 position [[position]];
};

// One triangle that covers the screen.
vertex VisualVertex visualVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VisualVertex out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

// GLSL's smoothstep, spelled out: Metal leaves edge0 >= edge1 undefined and the looks use it reversed.
static float sstep(float e0, float e1, float x) {
    float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

static float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

static float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1.0, 0.0)), u.x), mix(hash(i + float2(0.0, 1.0)), hash(i + float2(1.0, 1.0)), u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * noise(p); p *= 2.02; a *= 0.5; }
    return v;
}

// Centered, aspect kept: y runs -0.5..0.5 over the height.
static float2 centered(float2 frag, constant VisualUniforms &u) { return (frag - 0.5 * u.res) / u.res.y; }

static float2 fragOf(float4 pos, constant VisualUniforms &u) { return float2(pos.x, u.res.y - pos.y); }

static float4 finish(float3 col, float m, float2 frag, constant VisualUniforms &u) {
    float3 c = mix(u.ground, col, clamp(m, 0.0, 1.0) * u.dim);
    float zone = 1.0 - sstep(u.zone.x, u.zone.y, frag.y / u.res.y);
    return float4(mix(c, u.ground, u.scrim * zone), 1.0);
}

// A soft ball of light that swells when someone speaks, a little above the middle.
fragment float4 visualOrb(VisualVertex in [[stage_in]], constant VisualUniforms &u [[buffer(0)]]) {
    float2 frag = fragOf(in.position, u);
    float2 p = centered(frag, u) - float2(0.0, 0.06);
    float r = length(p);
    float2 dir = p / max(r, 0.0001);
    float R = 0.2 + 0.09 * u.level + 0.012 * sin(u.time * 1.3);
    R += (0.035 + 0.05 * u.level) * (noise(dir * 1.7 + float2(7.0 + u.time * 0.45, 3.0 - u.time * 0.3)) - 0.5) * 2.0;
    float body = sstep(R, R - 0.1, r);
    float glow = exp(-max(r - R, 0.0) * (9.0 - 3.0 * u.level)) * (0.35 + 0.45 * u.level);
    float swirl = fbm(p * 3.2 + float2(u.time * 0.18, -u.time * 0.12));
    float3 inside = mix(u.b, u.a, sstep(0.0, R, r));
    inside = mix(inside, u.c, sstep(0.45, 0.8, swirl) * 0.6);
    float m = max(body, glow);
    return finish(mix(u.a, inside, body), m, frag, u);
}

// Slow ribbons of color across the top, with fine curtains in them.
fragment float4 visualAurora(VisualVertex in [[stage_in]], constant VisualUniforms &u [[buffer(0)]]) {
    float2 frag = fragOf(in.position, u);
    float2 uv = frag / u.res;
    float3 col = float3(0.0);
    float m = 0.0;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float yc = 0.74 - fi * 0.11 + 0.06 * sin(uv.x * 2.6 + u.time * 0.25 + fi * 1.7)
                 + 0.12 * (fbm(float2(uv.x * 1.8 + u.time * 0.07, fi * 3.1)) - 0.5);
        float w = 0.05 + 0.025 * u.level + 0.02 * fi;
        float q = (uv.y - yc) / w;
        float band = exp(-q * q);  // pow() of a negative base is NaN in Metal
        float curtain = 0.55 + 0.45 * noise(float2(uv.x * 38.0 + fi * 11.0, u.time * 0.35));
        float k = band * curtain * (0.55 + 0.6 * u.level);
        float3 tint = i == 0 ? u.a : (i == 1 ? u.b : u.c);
        col += tint * k;
        m += k;
    }
    m = clamp(m, 0.0, 1.0) * sstep(0.05, 0.45, uv.y);
    return finish(col / max(m, 0.001) * sstep(0.05, 0.45, uv.y), m, frag, u);
}

// Layered lines that ripple with the sound, low on the screen.
fragment float4 visualWaves(VisualVertex in [[stage_in]], constant VisualUniforms &u [[buffer(0)]]) {
    float2 frag = fragOf(in.position, u);
    float2 uv = frag / u.res;
    float3 col = u.a;
    float m = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float amp = (0.018 + 0.075 * u.level) * (1.0 - fi * 0.13);
        float y = 0.2 + fi * 0.075 + amp * sin(uv.x * (5.0 + fi * 1.7) + u.time * (0.9 + fi * 0.25)) * sin(uv.x * 2.3 - u.time * 0.6 + fi);
        float d = abs(uv.y - y) * u.res.y;
        float line = sstep(2.4, 0.4, d) + exp(-d * 0.09) * 0.28;
        float3 tint = mix(u.a, u.c, fi / 4.0);
        tint = mix(tint, u.b, 0.35 * sin(uv.x * 3.0 + fi + u.time * 0.3) + 0.2);
        float k = line * (1.0 - fi * 0.12);
        col = mix(col, tint, clamp(k / max(m + k, 0.001), 0.0, 1.0));
        m = max(m, k);
    }
    return finish(col, m, frag, u);
}

// A soft gradient of three slow lights, with film grain. It barely moves.
fragment float4 visualGrain(VisualVertex in [[stage_in]], constant VisualUniforms &u [[buffer(0)]]) {
    float2 frag = fragOf(in.position, u);
    float2 p = centered(frag, u);
    float t = u.time * 0.06;
    float2 p1 = float2(0.28 * sin(t * 1.1), 0.25 + 0.12 * cos(t * 0.9));
    float2 p2 = float2(-0.3 + 0.1 * cos(t * 0.7), -0.2 + 0.1 * sin(t * 1.3));
    float2 p3 = float2(0.25 * cos(t * 0.5 + 2.0), -0.05 + 0.2 * sin(t * 0.8));
    float w1 = 1.0 / (dot(p - p1, p - p1) + 0.04);
    float w2 = 1.0 / (dot(p - p2, p - p2) + 0.04);
    float w3 = 1.0 / (dot(p - p3, p - p3) + 0.04);
    float3 col = (u.a * w1 + u.b * w2 + u.c * w3) / (w1 + w2 + w3);
    float g = hash(floor(frag) + fract(u.time * 7.0) * 97.0) - 0.5;
    col += g * 0.07;
    return finish(col, 0.78 + 0.12 * u.level, frag, u);
}

// Petals of light that open on the beat.
fragment float4 visualBloom(VisualVertex in [[stage_in]], constant VisualUniforms &u [[buffer(0)]]) {
    float2 frag = fragOf(in.position, u);
    float2 p = centered(frag, u) - float2(0.0, 0.04);
    float r = length(p), a = atan2(p.y, p.x);
    float open = 0.17 + 0.17 * u.level + 0.015 * sin(u.time * 0.9);
    float petal = open * pow(0.5 + 0.5 * cos(6.0 * a + u.time * 0.22), 1.4);
    float inner = open * 0.62 * pow(0.5 + 0.5 * cos(6.0 * a - u.time * 0.3 + 0.52), 1.6);
    float outer = sstep(petal + 0.02, petal - 0.03, r);
    float mid = sstep(inner + 0.02, inner - 0.03, r);
    float heart = sstep(0.05 + 0.02 * u.level, 0.0, r);
    float glow = exp(-r * 6.0) * (0.25 + 0.5 * u.level);
    float3 col = mix(u.a, u.c, mid);
    col = mix(col, u.b, heart);
    float m = max(max(outer, mid), max(heart, glow));
    return finish(mix(u.a, col, max(max(outer, mid), heart)), m, frag, u);
}
