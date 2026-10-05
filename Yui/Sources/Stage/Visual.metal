// The visual's shaders (YUI-124 step 2, spec yuigui/spec/VISUAL.md): Metal ports
// of yuigui site/lib/visual/shaders.mjs, same uniforms, same math, same look.
// Each is cheap on purpose: 4-octave noise at most, no loops over the screen,
// drawn at half resolution (grain three quarters) by StageVisual.swift.
//
// The sound (YUI-125): `level` is the whole of it, `bands` its lows, mids and highs,
// each 0..1 after the look's envelope. Each look says what it does with them, on
// top of what the level already does (VisualPlan.listens has the same words):
//   orb     the shader blob (YUI-232): its shape says what the agent is doing;
//           it pulses with the lows, ripples with the mids, glows with the highs.
//           It sits where the stage's layout puts it (`orb`) and tucks away behind words
//   aurora  widens with the lows, shimmers with the mids, glows with the highs
//   waves   swell with the lows, ripple with the mids, glow with the highs
//   grain   spreads with the lows, sparkles with the highs
//   bloom   opens with the lows, flutters with the mids, its heart glows with the highs
// With the bands at 0 every look is the same picture as the web's.
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
    float3 bands; // lows, mids, highs
    float4 act;   // the blob's state weights (YUI-232): thinking, reading, running, searching
    float4 act2;  // talking, done, seconds since the state changed, unused
    float4 orb;   // the blob's place: center x and y (fractions of the view from its top left), radius (a fraction of the height), presence 0..1
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

static float2 rot(float2 p, float a) { float c = cos(a), s = sin(a); return float2(c * p.x - s * p.y, s * p.x + c * p.y); }

// A lens on its side: half as long as l, half as wide as w (w < l).
static float football(float2 p, float l, float w) {
    float r = 0.5 * (l * l / w + w), d = r - w;
    p = abs(p.yx);
    float b = sqrt(r * r - d * d);
    return ((p.y - b) * d > p.x * b) ? length(p - float2(0.0, b)) : length(p - float2(-d, 0.0)) - r;
}

static float roundBox(float2 p, float h, float k) {
    float2 q = abs(p) - float2(h - k);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - k;
}

// The shader blob (YUI-232, yuigui site/lib/visual/actionshader.mjs, spec/SHADER.md): one
// blob whose SHAPE says what the agent is doing. Each state is a distance to its edge; the
// weights (eased by StageVisual.swift) blend them, so it morphs:
//   idle a perfect circle that breathes     thinking a soft flower of five lobes, turning
//   reading a football on its side          running a rounded square, a quarter turn a beat
//   searching a drop whose point sweeps     talking a tall pill that stretches with the voice
//   done the circle, one pop and one ring
// The voice is `level` (after the look's envelope): it swells the blob and the pill.
//
// Drawn clean (Chris, Oct 4: "the shaders are ok but I think they could be cleaner"): a crisp
// edge one pixel wide instead of a blur, a body of solid color lit from the upper left like a
// bead of glass (a glint, a thin bright rim), a halo that falls off smoothly, and no film grain.
// It is a citizen of the layout: `orb` says where it sits and how big, so it is the agent's face
// on the home and the hero while it works, and with words on the stage its presence goes to 0
// and only a soft wash of the agent's color is left behind them. Nothing sits under the text.
fragment float4 visualOrb(VisualVertex in [[stage_in]], constant VisualUniforms &u [[buffer(0)]]) {
    float2 frag = fragOf(in.position, u);
    float aspect = u.res.x / u.res.y;
    float2 uv = frag / u.res;
    float2 p = centered(frag, u) - float2((u.orb.x - 0.5) * aspect, 0.5 - u.orb.y);
    float t = u.time, v = u.level, here = clamp(u.orb.w, 0.0, 1.0);
    float think = u.act.x, read = u.act.y, run = u.act.z, search = u.act.w, talk = u.act2.x, done = u.act2.y, since = u.act2.z;
    float idle = clamp(1.0 - think - read - run - search - talk - done, 0.0, 1.0);
    float R = max(u.orb.z, 0.0005) * (1.0 + 0.08 * v + 0.10 * u.bands.x);

    // Searching leans the whole blob toward where its point looks.
    float look = t * 1.3 + 0.6 * sin(t * 0.65);
    float2 q = p - float2(cos(look), sin(look)) * 0.22 * R * search;
    float a = atan2(q.y, q.x), r = length(q);

    float dIdle = r - R * (1.0 + 0.025 * sin(t * 1.3));
    // Five round lobes, no cusps between them: a crisp edge would show every one.
    float dThink = r - R * (0.90 + 0.14 * (0.5 + 0.5 * cos(5.0 * (a - t * 0.35))));
    float dRead = football(rot(q, -0.18 + 0.08 * sin(t * 0.7)), 1.36 * R, 0.66 * R) - 0.06 * R;
    float beat = t * 0.85;
    float turn = (floor(beat) + sstep(0.0, 0.3, fract(beat))) * 1.5707963;
    float squeeze = 1.0 - 0.06 * exp(-fract(beat) * 7.0);
    float dRun = roundBox(rot(q, turn) / squeeze, 0.86 * R, 0.34 * R) * squeeze;
    float dSearch = r - R * (0.86 + 0.58 * pow(max(cos(a - look), 0.0), 9.0));
    // The pill breathes with the voice, slowly: no ripple chasing every syllable.
    float dTalk = length(q / float2(0.80 - 0.06 * v, 1.14 + 0.20 * v)) - R;
    dTalk -= 0.022 * R * v * sin(a * 2.0 + t * 2.2);
    float pop = 1.0 + 0.14 * exp(-since * 4.0) * cos(since * 13.0);
    float dDone = r - R * pop;
    float d = idle * dIdle + think * dThink + read * dRead + run * dRun + search * dSearch + talk * dTalk + done * dDone;

    // A living edge, kept slow and small so the shape reads; the circle stays perfect.
    // Noise by direction, not angle: the angle wraps at the left and would leave a seam.
    float2 qd = q / max(r, 0.0001);
    float wob = 0.035 * (1.0 - idle - done) + 0.03 * v;
    d -= R * wob * (noise(qd * 1.4 + float2(7.0 + t * 0.4, 3.0 - t * 0.27)) - 0.5) * 2.0;
    d -= R * 0.05 * u.bands.y * (noise(qd * 2.6 + float2(t * 1.1, -t * 0.8)) - 0.5) * 2.0;

    // The edge: about a pixel and a half wide, whatever the size.
    float w = max(fwidth(d), 0.5 / u.res.y) * 0.9;
    float body = 1.0 - sstep(-w, w, d);
    float depth = clamp(-d / R, 0.0, 1.0);
    float2 n = q / R;

    // Inside: the three colors run across it along the light, bent by a slow flow of two
    // soft waves (no fine octaves: detail in there read as clouds on a planet, not as light).
    // The deep color is pulled more than halfway back to the tone, so the hues stay neighbors.
    // Thinking turns the flow over faster.
    float ts = t * (0.10 + 0.22 * think);
    float2 bend = float2(noise(n * 0.9 + float2(ts, -0.6 * ts)), noise(n * 1.1 + float2(5.2 - 0.5 * ts, 1.7 + 0.8 * ts)));
    float flow = 0.62 * noise(n * 0.7 + 1.2 * bend + float2(0.3 * ts, 0.2 * ts))
               + 0.38 * noise(n * 1.3 - 0.8 * bend + float2(4.1 - 0.2 * ts, 2.7 + 0.25 * ts));
    float lit = clamp(0.5 + 0.5 * dot(n, float2(-0.55, 0.83)), 0.0, 1.0);
    float g = clamp(lit * 0.9 + (flow - 0.5) * 0.55 + 0.04, 0.0, 1.0);
    float3 deep = mix(u.c, u.a, 0.55);
    float3 inside = mix(deep, u.a, sstep(0.0, 0.5, g));
    inside = mix(inside, u.b, sstep(0.45, 1.0, g) * 0.9);
    // Glass: a soft glint where the light lands, a thin bright rim just inside the edge,
    // a little shade on the far side.
    float2 gp = n - float2(-0.34, 0.40);
    float glint = exp(-dot(gp, gp) * 7.0) * 0.20;
    float rim = exp(-depth * 16.0) * 0.20 * (0.55 + 0.45 * lit);
    inside *= 1.0 - 0.16 * sstep(0.35, 1.0, 1.0 - lit) * (1.0 - 0.5 * depth);
    inside += (glint + rim) * mix(float3(1.0), u.b, 0.35);
    inside += 0.07 * v;

    // Reading: a soft bar of light reads across the football, left to right.
    float bx = -1.4 * R + fract(t * 0.5) * 2.8 * R;
    float bq = (q.x - bx) / (0.24 * R);
    inside = mix(inside, u.b + 0.16, exp(-bq * bq) * 0.5 * read);

    // Done: one bright ring leaves it, then it settles.
    float rq = (length(p) - R * (1.0 + since * 3.4)) / (0.14 * R);
    float ring = exp(-rq * rq) * exp(-since * 2.6) * done;

    // Around it: a halo with a near and a far falloff, lifted by the voice and the highs.
    float away = max(d, 0.0) / R;
    float strength = clamp(u.dim, 0.0, 1.0);
    float halo = (0.42 * exp(-away * 3.6) + 0.14 * exp(-away * 1.1)) * (0.5 + 0.35 * v + 0.35 * u.bands.z) * (0.4 + 0.6 * strength);

    // Behind everything, always: a soft wash of the agent's color from the top of the stage.
    float2 tp = float2((uv.x - 0.5) * aspect, 1.0 - uv.y);
    float lum = dot(u.ground, float3(0.2126, 0.7152, 0.0722));
    float wash = exp(-dot(tp, tp) / 0.20) * mix(0.13, 0.08, sstep(0.2, 0.6, lum));

    float3 col = mix(u.ground, u.a, wash);
    col = mix(col, mix(u.a, u.b, 0.35), clamp(halo, 0.0, 1.0) * here);
    col = mix(col, u.b, clamp(ring, 0.0, 1.0) * 0.85 * here);
    col = mix(col, inside, body * here);
    // No grain: one still level of dither, so the soft gradients never band.
    col += (hash(floor(frag)) - 0.5) * (1.0 / 255.0);
    return float4(col, 1.0);
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
        float w = 0.05 + 0.025 * u.level + 0.02 * u.bands.x + 0.02 * fi;
        float q = (uv.y - yc) / w;
        float band = exp(-q * q);  // pow() of a negative base is NaN in Metal
        float curtain = 0.55 + 0.45 * noise(float2(uv.x * 38.0 + fi * 11.0, u.time * 0.35));
        curtain = mix(curtain, noise(float2(uv.x * 90.0 + fi * 7.0, u.time * 1.4)), 0.5 * u.bands.y);
        float k = band * curtain * (0.55 + 0.6 * u.level + 0.3 * u.bands.z);
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
        float amp = (0.018 + 0.075 * u.level + 0.03 * u.bands.x) * (1.0 - fi * 0.13);
        float y = 0.2 + fi * 0.075 + amp * sin(uv.x * (5.0 + fi * 1.7) + u.time * (0.9 + fi * 0.25)) * sin(uv.x * 2.3 - u.time * 0.6 + fi);
        y += 0.012 * u.bands.y * sin(uv.x * (21.0 + fi * 4.0) - u.time * 2.2 + fi);
        float d = abs(uv.y - y) * u.res.y;
        float line = sstep(2.4, 0.4, d) + exp(-d * 0.09) * (0.28 + 0.3 * u.bands.z);
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
    float spread = 0.04 + 0.05 * u.bands.x;
    float w1 = 1.0 / (dot(p - p1, p - p1) + spread);
    float w2 = 1.0 / (dot(p - p2, p - p2) + spread);
    float w3 = 1.0 / (dot(p - p3, p - p3) + spread);
    float3 col = (u.a * w1 + u.b * w2 + u.c * w3) / (w1 + w2 + w3);
    float g = hash(floor(frag) + fract(u.time * 7.0) * 97.0) - 0.5;
    col += g * (0.07 + 0.07 * u.bands.z);
    return finish(col, 0.78 + 0.12 * u.level, frag, u);
}

// Petals of light that open on the beat.
fragment float4 visualBloom(VisualVertex in [[stage_in]], constant VisualUniforms &u [[buffer(0)]]) {
    float2 frag = fragOf(in.position, u);
    float2 p = centered(frag, u) - float2(0.0, 0.04);
    float r = length(p), a = atan2(p.y, p.x);
    float open = 0.17 + 0.17 * u.level + 0.06 * u.bands.x + 0.015 * sin(u.time * 0.9);
    float flutter = 0.35 * u.bands.y * sin(r * 40.0 - u.time * 3.0);
    float petal = open * pow(0.5 + 0.5 * cos(6.0 * a + u.time * 0.22 + flutter), 1.4);
    float inner = open * 0.62 * pow(0.5 + 0.5 * cos(6.0 * a - u.time * 0.3 + 0.52), 1.6);
    float outer = sstep(petal + 0.02, petal - 0.03, r);
    float mid = sstep(inner + 0.02, inner - 0.03, r);
    float heart = sstep(0.05 + 0.02 * u.level, 0.0, r);
    float glow = exp(-r * 6.0) * (0.25 + 0.5 * u.level + 0.35 * u.bands.z);
    float3 col = mix(u.a, u.c, mid);
    col = mix(col, u.b, heart);
    float m = max(max(outer, mid), max(heart, glow));
    return finish(mix(u.a, col, max(max(outer, mid), heart)), m, frag, u);
}
