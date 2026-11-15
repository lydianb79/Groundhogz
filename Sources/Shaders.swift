// Metal shader source, compiled at runtime so the build only needs swiftc.
//
// Frame structure:
//   1. scene pass (HDR, rgba16f): procedural sky/parallax background, terrain shader, world sprites
//   2. bloom: bright-pass downsample + separable blur
//   3. composite to the drawable: water refraction/reflection, dynamic lights, bloom, weather, grading
//   4. UI sprites + vector font on top

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Vtx { float2 pos; float2 uv; float4 color; };
struct VOut { float4 pos [[position]]; float2 uv; float4 color; };
struct Globals {
    float2 screen; float time; float camX;
    float4 skyTop; float4 skyBottom; float4 hillA; float4 hillB;
    float4 params;      // x theme, y night, z snow, w unused
    float2 origin; float2 worldSize;
    float4 ambient;     // rgb ambient light, a vignette
    float4 waterColor;
    float4 counts;      // x waters, y lights, z weather kind, w weather amount
    float4 dirtA; float4 dirtB; float4 grass;
};
struct Light { float4 posRad; float4 color; };

float hash21(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }

float vnoise(float2 p) {
    float2 i = floor(p); float2 f = fract(p);
    float a = hash21(i), b = hash21(i + float2(1, 0)), c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * vnoise(p); p = p * 2.03 + float2(1.7, 9.2); a *= 0.5; }
    return v;
}

// ---------------------------------------------------------------- sprites

vertex VOut spriteVS(uint vid [[vertex_id]], const device Vtx* v [[buffer(0)]], constant Globals& g [[buffer(1)]]) {
    VOut o;
    float2 p = v[vid].pos;
    o.pos = float4(p.x / g.screen.x * 2.0 - 1.0, 1.0 - p.y / g.screen.y * 2.0, 0.0, 1.0);
    o.uv = v[vid].uv;
    o.color = v[vid].color;
    return o;
}

fragment float4 spriteFS(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    float4 c = tex.sample(s, in.uv) * in.color;
    if (c.a < 0.002) discard_fragment();
    return c;
}

vertex VOut fullVS(uint vid [[vertex_id]], constant Globals& g [[buffer(1)]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y) * g.screen;
    o.color = float4(p.x, 1.0 - p.y, 0.0, 0.0);
    return o;
}

// ---------------------------------------------------------------- background

float ridge(float x, float seed, float amp, float freq) {
    return amp * (0.55 * sin(x * freq + seed) + 0.3 * sin(x * freq * 2.31 + seed * 1.7) + 0.15 * sin(x * freq * 5.13 + seed * 3.1));
}

// returns tree coverage for a row of trees standing on a ridge line
float trees(float x, float y, float cell, float seed, float amp, float freq, float base, float size, int kind, float tm, thread float& lit) {
    float c = floor(x / cell);
    float h = hash21(float2(c, seed));
    lit = 0.0;
    if (h < 0.35) return 0.0;
    float cx = (c + 0.3 + 0.4 * hash21(float2(c, seed + 3.0))) * cell;
    float gy = base + ridge(cx, seed, amp, freq);
    float th = size * (0.7 + 0.6 * hash21(float2(c, seed + 7.0)));
    float bend = sin(tm * 0.9 + h * 17.0) * 0.6 + sin(tm * 2.3 + h * 5.0) * 0.25;
    float dx = x - cx - bend * th * 0.06 * clamp((gy - y) / th, 0.0, 1.0);
    if (kind == 0) {          // round deciduous tree
        float trunk = step(abs(dx), th * 0.07) * step(gy - th * 0.45, y) * step(y, gy + 2.0);
        float2 q = float2(dx, y - (gy - th * 0.62));
        float r = th * 0.36;
        float blob = length(q / float2(1.0, 0.92)) - r * (1.0 + 0.12 * sin(atan2(q.y, q.x) * 5.0 + h * 9.0));
        lit = clamp(-(q.x + q.y) / r * 0.5, -1.0, 1.0);
        return max(trunk, step(blob, 0.0));
    } else {                  // pine
        float top = gy - th;
        float hw = (y - top) * 0.33 * (0.85 + 0.15 * sin((y - top) * 1.3));
        lit = -dx / max(hw, 0.5);
        float trunk = step(abs(dx), th * 0.05) * step(gy - th * 0.15, y) * step(y, gy + 2.0);
        return max(trunk, step(top, y) * step(y, gy - th * 0.12) * step(abs(dx), hw));
    }
}

fragment float4 bgFS(VOut in [[stage_in]], constant Globals& g [[buffer(1)]]) {
    float2 sp = in.uv;
    float2 p = float2(sp.x, sp.y - g.origin.y);       // world-aligned
    bool night = g.params.y > 0.5;
    bool snow = g.params.z > 0.5;
    int theme = int(g.params.x + 0.5);
    float t = clamp(sp.y / (300.0 + g.origin.y), 0.0, 1.0);
    float3 sky = mix(g.skyTop.rgb, g.skyBottom.rgb, smoothstep(0.0, 1.0, t));
    float3 col = sky;

    if (night) {
        for (int l = 0; l < 2; l++) {
            float cs = l == 0 ? 3.0 : 7.0;
            float2 q = floor((p + float2(g.camX * (0.02 + 0.02 * float(l)), 0.0)) / cs);
            float h = hash21(q + float(l) * 19.0);
            if (h > (l == 0 ? 0.985 : 0.992)) {
                float2 f = fract((p + float2(g.camX * (0.02 + 0.02 * float(l)), 0.0)) / cs) - 0.5;
                float tw = 0.55 + 0.45 * sin(g.time * (2.0 + h * 3.0) + h * 80.0);
                col += float3(0.9, 0.92, 1.0) * tw * (1.0 - t) * smoothstep(0.5, 0.0, length(f)) * (l == 0 ? 0.8 : 1.4);
            }
        }
        float band = exp(-pow((p.y + p.x * 0.25 - 120.0) / 60.0, 2.0)) * fbm(p * 0.02 + float2(g.camX * 0.0005, 0.0));
        col += float3(0.18, 0.16, 0.3) * band * 0.6;
    }

    // sun / moon
    float2 sunPos = float2(g.screen.x * 0.79 - g.camX * 0.03, 56.0 + g.params.w);
    float d = length(p - sunPos);
    if (night) {
        col += float3(0.5, 0.55, 0.8) * 0.25 * exp(-d * 0.02);
        float moon = smoothstep(20.5, 19.0, d);
        float crater = fbm((p - sunPos) * 0.25) * 0.35;
        float3 mc = float3(0.93, 0.93, 0.86) * (0.8 + crater);
        col = mix(col, mc, moon);
    } else {
        float ang = atan2(p.y - sunPos.y, p.x - sunPos.x);
        float rays = pow(0.5 + 0.5 * sin(ang * 13.0 + g.time * 0.12), 8.0) + pow(0.5 + 0.5 * sin(ang * 7.0 - g.time * 0.08), 10.0);
        col += float3(1.0, 0.92, 0.7) * rays * 0.10 * exp(-d * 0.005) * (1.0 - t * 0.7);
        col += float3(1.0, 0.9, 0.6) * 0.35 * exp(-d * 0.028);
        float3 sunCol = theme == 2 ? float3(1.0, 0.82, 0.45) : float3(1.0, 0.95, 0.62);
        float disc = smoothstep(22.0, 20.5, d);
        float2 q = p - sunPos;
        float3 sc = sunCol * (1.0 + 0.08 * (-q.y / 21.0));
        float lens = (smoothstep(5.5, 4.5, length((q - float2(7.0, -2.0)) / float2(1.0, 0.75))) +
                      smoothstep(5.5, 4.5, length((q - float2(-7.0, -2.0)) / float2(1.0, 0.75))));
        float bridge = step(abs(q.y + 3.0), 0.8) * step(abs(q.x), 2.5);
        sc = mix(sc, float3(0.1, 0.08, 0.14), clamp(lens + bridge, 0.0, 1.0));
        float glint = smoothstep(1.4, 0.4, length(q - float2(5.0, -4.0))) + smoothstep(1.4, 0.4, length(q - float2(-9.0, -4.0)));
        sc = mix(sc, float3(1.0), glint * 0.8);
        float smile = smoothstep(1.2, 0.4, abs(length(q - float2(0.0, 1.0)) - 9.5)) * step(6.0, q.y);
        sc = mix(sc, float3(0.8, 0.45, 0.15), smile);
        col = mix(col, sc, disc);
    }

    // clouds
    for (int l = 0; l < 2; l++) {
        float fl = float(l);
        float sc = l == 0 ? 0.007 : 0.012;
        float par = l == 0 ? 0.05 : 0.11;
        float yb = l == 0 ? 45.0 : 105.0;
        float2 cp = float2(p.x + g.camX * par + g.time * (2.5 + fl * 3.0), p.y * 1.7);
        float n = fbm(cp * sc + float2(fl * 13.0, 0.0));
        float bandY = exp(-pow((p.y - yb) / 42.0, 2.0));
        float m = smoothstep(0.52, 0.6, n * (0.55 + 0.65 * bandY));
        float n2 = fbm((cp + float2(-7.0, -9.0)) * sc + float2(fl * 13.0, 0.0));
        float shade = clamp((n - n2) * 5.0 + 0.65, 0.35, 1.1);
        float3 cc = night ? float3(0.2, 0.22, 0.36) * (0.8 + 0.4 * shade)
                          : mix(float3(0.72, 0.76, 0.88), float3(1.0, 0.99, 0.97), shade);
        if (theme == 2 && !night) cc *= float3(1.05, 0.9, 0.82);
        col = mix(col, cc, m * (0.9 - fl * 0.1));
    }

    // birds
    if (!night && !snow) {
        for (int b = 0; b < 3; b++) {
            float fb = float(b);
            float bx = fmod(g.time * (14.0 + fb * 5.0) + fb * 230.0 - g.camX * 0.1, g.screen.x + 200.0) - 100.0;
            float by = 70.0 + fb * 22.0 + sin(g.time * 0.5 + fb) * 8.0;
            float2 q = p - float2(bx, by);
            float flap = sin(g.time * 9.0 + fb * 2.0) * 1.6;
            float wing = abs(q.y + abs(q.x) * 0.55 - flap * (abs(q.x) / 4.0)) ;
            if (abs(q.x) < 4.0 && wing < 0.55) col = mix(col, float3(0.15, 0.15, 0.2), 0.8);
        }
    }

    // distant mountains
    float mx = p.x + g.camX * 0.1;
    float s0 = sin(mx * 0.011 + 0.4), s1 = sin((mx + 1.0) * 0.011 + 0.4);
    float mh = 165.0 + ridge(mx, 1.0, 38.0, 0.0065) + 18.0 * sqrt(s0 * s0 + 0.03);
    float slope = (ridge(mx + 1.0, 1.0, 38.0, 0.0065) + 18.0 * sqrt(s1 * s1 + 0.03)) - (mh - 165.0);
    if (p.y > mh) {
        float3 mc = mix(g.hillA.rgb * 0.8, sky, 0.5);
        mc *= 1.0 - clamp(slope * 0.12, -0.08, 0.08);
        float capH = smoothstep(168.0, 140.0, mh) * (9.0 + 6.0 * vnoise(float2(mx * 0.08, 0.0)));
        if ((snow || theme == 0) && p.y < mh + capH)
            mc = mix(mc, float3(0.97, 0.98, 1.0), 0.85) * (1.0 - clamp(slope * 0.15, -0.1, 0.1));
        col = mix(mc, sky, smoothstep(mh, mh + 140.0, p.y) * 0.35);
    }

    int treeKind = (theme == 1 || theme == 3) ? 1 : 0;
    float3 leafMid = theme == 2 ? float3(0.85, 0.42, 0.16) : (theme == 1 ? float3(0.36, 0.5, 0.46) : g.hillA.rgb * 0.82);

    // mid hills + trees
    float hx = p.x + g.camX * 0.28;
    float hh = 212.0 + ridge(hx, 4.0, 22.0, 0.012);
    float lit;
    float tm = trees(hx, p.y, 26.0, 4.0, 22.0, 0.012, 212.0, 26.0, treeKind, g.time, lit);
    if (tm > 0.5) {
        float3 tc = mix(leafMid, sky, 0.28) * (1.0 + lit * 0.12);
        if (snow && treeKind == 1 && fract((p.y + hx * 0.3) * 0.18) < 0.3) tc = mix(tc, float3(0.95), 0.7);
        col = tc;
    }
    if (p.y > hh) col = mix(g.hillA.rgb, sky, 0.22) * (1.0 - 0.15 * smoothstep(hh, hh + 50.0, p.y));

    // near hills + trees
    float nx = p.x + g.camX * 0.5;
    float nh = 248.0 + ridge(nx, 9.0, 15.0, 0.019);
    float tm2 = trees(nx, p.y, 44.0, 9.0, 15.0, 0.019, 248.0, 40.0, treeKind, g.time * 1.2, lit);
    if (tm2 > 0.5) {
        float3 tc = (theme == 2 ? float3(0.78, 0.3, 0.12) : g.hillB.rgb * 0.8) * (1.0 + lit * 0.18);
        if (snow && treeKind == 1 && fract((p.y + nx * 0.4) * 0.15) < 0.32) tc = mix(tc, float3(0.96), 0.75);
        col = tc;
    }
    if (p.y > nh) col = g.hillB.rgb * (1.0 - 0.28 * smoothstep(nh, nh + 60.0, p.y));

    // drifting ground mist between the hill layers
    float mn = fbm(float2(p.x * 0.008 + g.camX * 0.0007 + g.time * 0.015, p.y * 0.035));
    float mist = smoothstep(0.38, 0.72, mn) * exp(-pow((p.y - 238.0) / 34.0, 2.0));
    float3 mistCol = night ? float3(0.25, 0.28, 0.45) : mix(g.skyBottom.rgb, float3(1.0), 0.45);
    col = mix(col, mistCol, mist * (night ? 0.35 : 0.5));

    return float4(col, 1.0);
}

// ---------------------------------------------------------------- terrain

float3 dirtColor(float2 wp, float depth, constant Globals& g) {
    float n1 = fbm(wp * 0.035);
    float strata = sin(wp.y * 0.21 + n1 * 7.0 + sin(wp.x * 0.012) * 2.0);
    float3 base = mix(g.dirtA.rgb, g.dirtB.rgb, smoothstep(-0.3, 0.5, strata));
    float grain = vnoise(wp * 0.9) * 0.6 + vnoise(wp * 2.3) * 0.4;
    base *= 0.84 + 0.3 * grain;
    float2 c = floor(wp / 6.0);
    float2 f = fract(wp / 6.0);
    float h = hash21(c);
    if (h > 0.72 && depth > 7.0) {
        float2 pc = float2(0.3 + 0.4 * hash21(c + 3.1), 0.3 + 0.4 * hash21(c + 7.7));
        float2 dd = (f - pc) * 6.0;
        float pr = 0.8 + 1.3 * hash21(c + 1.3);
        float pd = length(dd * float2(1.0, 1.35));
        float3 stone = mix(float3(0.5, 0.46, 0.42), float3(0.7, 0.66, 0.6), hash21(c + 9.0));
        float sl = clamp(0.95 - dd.y * 0.28 - dd.x * 0.16, 0.55, 1.3);
        base = mix(base, stone * sl, smoothstep(pr + 0.35, pr - 0.25, pd));
    }
    if (depth > 4.0 && depth < 26.0) {
        float rv = abs(sin(wp.x * 0.11 + fbm(wp * 0.07) * 9.0 + wp.y * 0.05));
        if (rv < 0.05 && hash21(floor(wp / 14.0)) > 0.45) base *= 0.62;
    }
    float gd = 3.0 + 2.2 * vnoise(float2(wp.x * 0.25, 1.0));
    if (depth < gd) {
        float streak = vnoise(float2(wp.x * 1.7, wp.y * 0.4));
        return g.grass.rgb * (0.82 + 0.3 * streak) * mix(1.12, 0.82, depth / gd);
    }
    if (depth < gd + 3.5) base *= 0.7 + 0.08 * (depth - gd);
    base *= mix(1.0, 0.84, smoothstep(10.0, 220.0, depth));
    return base;
}

float3 steelColor(float2 wp) {
    float lx = fmod(wp.x, 16.0), ly = fmod(wp.y, 12.0);
    float3 base = float3(0.55, 0.59, 0.66) * (0.9 + 0.12 * vnoise(float2(wp.x * 0.08, wp.y * 2.5)));
    if (lx < 1.0 || ly < 1.0) base *= 1.38;
    else if (lx > 15.0 || ly > 11.0) base *= 0.58;
    float2 rv = float2(lx < 8.0 ? 3.0 : 13.0, ly < 6.0 ? 3.0 : 9.0);
    float rd = length(float2(lx, ly) - rv);
    if (rd < 1.15) base = mix(float3(0.92, 0.94, 0.98), float3(0.38, 0.4, 0.45), clamp((lx - rv.x + ly - rv.y) * 0.45 + 0.5, 0.0, 1.0));
    base += pow(max(0.0, sin((wp.x + wp.y) * 0.045)), 14.0) * 0.22;
    return base;
}

float3 carrotColor(float2 wp, float code) {
    float idx = floor(code / 36.0 + 0.05);
    float lower = fmod(code, 36.0) > 9.0 ? 1.0 : 0.0;
    float3 c = float3(1.0, 0.56, 0.14) * (0.9 + 0.12 * sin(wp.x * 2.6));
    if (lower > 0.5) c *= 0.72;
    if (idx > 4.5 && lower < 0.5) c = float3(0.32, 0.72, 0.24) * (0.9 + 0.2 * sin(wp.x * 4.0));
    return c;
}

float4 decor(float2 wp, texture2d<float> tex, sampler ns, float2 inv, constant Globals& g) {
    float2 base = floor(wp) + 0.5;
    float hgt = -1.0;
    float4 S = float4(0.0);
    for (int k = 1; k <= 5; k++) {
        float4 s = tex.sample(ns, (base + float2(0.0, float(k))) * inv);
        if (s.r > 0.5) { hgt = (floor(wp.y) + float(k)) - wp.y; S = s; break; }
    }
    if (hgt < 0.0) return float4(0.0);
    if (S.g > 0.47 || S.b * 255.0 > 2.5) return float4(0.0);
    if (g.params.z > 0.5) {
        float cap = 1.2 + 1.0 * vnoise(float2(wp.x * 0.35, 2.0));
        if (hgt < cap) return float4(float3(0.93, 0.96, 1.0) * mix(1.04, 0.86, hgt / cap), smoothstep(cap, cap - 0.4, hgt));
        return float4(0.0);
    }
    float sway = sin(g.time * 1.7 + wp.x * 0.09) * 0.6 * (hgt / 4.0);
    float bx = floor((wp.x - sway) * 2.0);
    float hb = hash21(float2(bx, 7.0));
    if (hb < 0.2) return float4(0.0);
    float bh = 1.0 + 3.3 * hash21(float2(bx, 3.0));
    if (hgt > bh) return float4(0.0);
    float3 c = g.grass.rgb * mix(0.6, 1.18, hgt / bh);
    float fh = hash21(float2(bx, 11.0));
    if (fh > 0.972 && bh > 2.6 && hgt > bh - 1.0) {
        float k = hash21(float2(bx, 13.0));
        c = k < 0.3 ? float3(1.0, 1.0, 0.95) : (k < 0.55 ? float3(1.0, 0.85, 0.2) : (k < 0.8 ? float3(1.0, 0.5, 0.7) : float3(0.7, 0.5, 1.0)));
    }
    return float4(c, 1.0);
}

fragment float4 terrainFS(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                          sampler ls [[sampler(0)]], sampler ns [[sampler(1)]], constant Globals& g [[buffer(1)]]) {
    float2 wp = in.uv;
    float2 inv = 1.0 / g.worldSize;
    float4 L = tex.sample(ls, wp * inv);
    if (in.color.r > 0.5) {     // flat mode for minimaps
        if (L.r < 0.5) discard_fragment();
        float mv = L.g / max(L.r, 0.001);
        float dep = L.b / max(L.r, 0.001) * 255.0;
        float3 c = mv < 0.47 ? (dep < 4.0 ? g.grass.rgb : g.dirtA.rgb) : (mv < 0.78 ? float3(0.6, 0.64, 0.7) : float3(1.0, 0.56, 0.14));
        return float4(c, in.color.a);
    }
    float m = L.r;
    float4 deco = m < 0.75 ? decor(wp, tex, ns, inv, g) : float4(0.0);
    float cov = smoothstep(0.42, 0.58, m);
    if (cov < 1.0) {
        float sh = tex.sample(ls, (wp + float2(-1.8, -2.4)) * inv).r * 0.5
                 + tex.sample(ls, (wp + float2(-3.4, -4.6)) * inv).r * 0.3
                 + tex.sample(ls, (wp + float2(-5.2, -7.0)) * inv).r * 0.2;
        float4 shadow = float4(0.02, 0.01, 0.03, sh * 0.34);
        float a = deco.a + shadow.a * (1.0 - deco.a);
        deco = a > 0.0 ? float4((deco.rgb * deco.a + shadow.rgb * shadow.a * (1.0 - deco.a)) / a, a) : float4(0.0);
    }
    if (cov <= 0.0) {
        if (deco.a <= 0.003) discard_fragment();
        return deco;
    }
    float r = max(L.r, 0.001);
    float mv = L.g / r;
    float info = L.b / r * 255.0;
    float e = 1.3;
    float gx = tex.sample(ls, (wp + float2(e, 0.0)) * inv).r - tex.sample(ls, (wp - float2(e, 0.0)) * inv).r;
    float gy = tex.sample(ls, (wp + float2(0.0, e)) * inv).r - tex.sample(ls, (wp - float2(0.0, e)) * inv).r;
    float b = 0.0;
    for (int i = 0; i < 8; i++) {
        float a = float(i) * 0.785398;
        float2 o = float2(cos(a), sin(a));
        b += tex.sample(ls, (wp + o * 2.5) * inv).r + tex.sample(ls, (wp + o * 5.5) * inv).r;
    }
    b /= 16.0;
    float edge = 1.0 - smoothstep(0.6, 0.98, b);
    float3 n = normalize(float3(-gx * 1.6, -gy * 1.6, 0.9));
    float3 Ld = normalize(float3(-0.55, -0.75, 0.55));
    float diff = dot(n, Ld);
    float3 col;
    if (mv < 0.47) col = dirtColor(wp, info, g);
    else if (mv < 0.78) col = steelColor(wp);
    else col = carrotColor(wp, info);
    col *= 1.0 + edge * (diff - 0.55) * 0.95;
    col += smoothstep(0.05, 0.4, gy) * edge * 0.07;
    col *= 1.0 - smoothstep(0.05, 0.5, -gy) * edge * 0.25;
    float outA = cov + deco.a * (1.0 - cov);
    float3 outC = (col * cov + deco.rgb * deco.a * (1.0 - cov)) / max(outA, 0.0001);
    return float4(outC, outA);
}

// ---------------------------------------------------------------- post

fragment float4 brightFS(VOut in [[stage_in]], texture2d<float> scene [[texture(0)]], sampler ls [[sampler(0)]]) {
    float2 uv = in.color.xy;
    float2 px = 1.0 / float2(scene.get_width(), scene.get_height());
    float3 c = (scene.sample(ls, uv + px * float2(-1, -1)).rgb + scene.sample(ls, uv + px * float2(1, -1)).rgb +
                scene.sample(ls, uv + px * float2(-1, 1)).rgb + scene.sample(ls, uv + px * float2(1, 1)).rgb) * 0.25;
    float l = max(c.r, max(c.g, c.b));
    return float4(c * smoothstep(0.8, 1.3, l), 1.0);
}

fragment float4 blurFS(VOut in [[stage_in]], texture2d<float> src [[texture(0)]], sampler ls [[sampler(0)]],
                       constant float2& dir [[buffer(0)]]) {
    float2 uv = in.color.xy;
    float w[5] = { 0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216 };
    float3 c = src.sample(ls, uv).rgb * w[0];
    for (int i = 1; i < 5; i++) {
        c += src.sample(ls, uv + dir * float(i) * 1.5).rgb * w[i];
        c += src.sample(ls, uv - dir * float(i) * 1.5).rgb * w[i];
    }
    return float4(c, 1.0);
}

fragment float4 shaftsFS(VOut in [[stage_in]], texture2d<float> bright [[texture(0)]], sampler ls [[sampler(0)]],
                         constant Globals& g [[buffer(1)]]) {
    float2 uv = in.color.xy;
    float2 sun = float2(g.screen.x * 0.79 - g.camX * 0.03, 56.0 + g.params.w + g.origin.y) / g.screen;
    float2 d = (uv - sun) * (0.92 / 36.0);
    float2 p = uv;
    float3 acc = float3(0.0);
    float w = 1.0;
    for (int i = 0; i < 36; i++) {
        p -= d;
        acc += bright.sample(ls, p).rgb * w;
        w *= 0.955;
    }
    acc /= 18.0;
    float2 q = (uv - sun) * float2(g.screen.x / g.screen.y, 1.0);
    return float4(acc * exp(-length(q) * 1.3), 1.0);
}

float caustic(float2 p, float t) {
    float v = sin(p.x * 1.7 + sin(p.y * 1.3 + t)) * sin(p.y * 1.9 + sin(p.x * 1.1 - t * 1.3));
    return pow(abs(v), 5.0);
}

float3 weather(float3 c, float2 lp, constant Globals& g) {
    int kind = int(g.counts.z + 0.5);
    float amt = g.counts.w;
    if (kind == 0) return c;
    for (int layer = 0; layer < 3; layer++) {
        float fl = float(layer);
        float sc = 14.0 + fl * 11.0;
        float par = 0.6 + fl * 0.45;
        float speed = kind == 1 ? (16.0 + fl * 14.0) : (kind == 4 ? 0.0 : 10.0 + fl * 9.0);
        float2 q = float2(lp.x + g.camX * par, lp.y - g.time * speed);
        q.x += sin(g.time * 0.7 + q.y * 0.03 + fl) * 9.0;
        float2 cell = floor(q / sc);
        float2 f = fract(q / sc);
        float h = hash21(cell + fl * 31.0);
        if (h > amt) continue;
        float spread = kind == 4 ? 0.3 : 0.6;
        float2 o = float2(0.5 - spread * 0.5 + spread * hash21(cell + 5.0), 0.5 - spread * 0.5 + spread * hash21(cell + 9.0));
        float2 d = (f - o) * sc;
        if (kind == 1) {
            float rr = 0.55 + fl * 0.55;
            c = mix(c, float3(1.0), smoothstep(rr + 0.6, rr - 0.25, length(d)) * (0.7 + 0.1 * fl));
        } else if (kind == 2 || kind == 3) {
            float a = g.time * (1.0 + h * 2.0) + h * 6.28;
            float2 rd = float2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a));
            float sz = 1.1 + fl * 0.7;
            float el = length(rd / float2(sz * 1.6, sz * 0.75 * abs(sin(a * 1.3)) + 0.3));
            float3 lc = kind == 2 ? mix(float3(0.9, 0.33, 0.08), float3(0.97, 0.75, 0.2), hash21(cell + 2.0))
                                  : mix(float3(1.0, 0.72, 0.84), float3(1.0, 0.95, 0.97), hash21(cell + 2.0));
            c = mix(c, lc, smoothstep(1.0, 0.65, el));
        } else if (kind == 4) {
            float2 wob = float2(sin(g.time * (0.7 + h) + h * 10.0), cos(g.time * (0.9 + h) + h * 7.0)) * sc * 0.1;
            float dd = length(d - wob);
            float blink = smoothstep(0.2, 1.0, sin(g.time * (1.3 + h * 2.0) + h * 20.0));
            float halo = smoothstep(sc * 0.2, 0.0, dd);
            c += float3(0.75, 1.0, 0.35) * blink * (exp(-dd * 1.3) * 0.9 + halo * halo * 0.15);
        }
    }
    return c;
}

fragment float4 compositeFS(VOut in [[stage_in]], texture2d<float> scene [[texture(0)]], texture2d<float> bloom [[texture(1)]],
                            texture2d<float> shafts [[texture(2)]],
                            sampler ls [[sampler(0)]], constant Globals& g [[buffer(1)]],
                            constant Light* lights [[buffer(2)]], constant float4* waters [[buffer(3)]]) {
    float2 lp = in.uv;
    float2 uv = in.color.xy;
    float2 wp = float2(lp.x + g.camX, lp.y - g.origin.y);
    float wdepth = -1.0, wtop = 0.0;
    int wc = int(g.counts.x + 0.5);
    for (int i = 0; i < wc; i++) {
        float4 w = waters[i];
        if (wp.x >= w.x && wp.x < w.y && wp.y < 300.0) {
            float top = w.z + sin(wp.x * 0.13 + g.time * 2.1) * 1.1 + sin(wp.x * 0.37 - g.time * 3.3) * 0.5;
            if (wp.y >= top) { wdepth = wp.y - top; wtop = top; }
        }
    }
    float2 off = float2(0.0);
    if (wdepth >= 0.0) off = float2(sin(wp.y * 0.35 + g.time * 3.0) * 1.3, sin(wp.x * 0.27 + g.time * 2.3) * 0.9) / g.screen;
    float3 c = scene.sample(ls, uv + off).rgb;
    if (wdepth >= 0.0) {
        float ry = (wtop + g.origin.y) * 2.0 - lp.y;
        float3 refl = scene.sample(ls, float2(uv.x + off.x * 2.0, ry / g.screen.y)).rgb;
        float fres = exp(-wdepth * 0.07);
        c = mix(c, g.waterColor.rgb * (0.95 - min(wdepth, 60.0) * 0.006), clamp(0.35 + wdepth * 0.012, 0.0, 0.88));
        c = mix(c, refl, 0.3 * fres);
        c += float3(0.6, 0.85, 1.0) * caustic(wp * 0.13, g.time * 1.4) * 0.25 * exp(-wdepth * 0.04);
        c = mix(c, float3(0.86, 0.96, 1.0), smoothstep(1.5, 0.2, wdepth) * 0.85);
        float glint = hash21(float2(floor(wp.x * 0.7), floor(g.time * 5.0 + wp.x * 0.13)));
        if (glint > 0.94 && wdepth < 5.0) c += float3(1.0, 1.0, 0.95) * (1.0 - wdepth / 5.0) * (glint - 0.94) * 14.0;
    }
    c += bloom.sample(ls, uv).rgb * 0.7;
    bool nightT = g.params.y > 0.5;
    c += shafts.sample(ls, uv).rgb * (nightT ? float3(0.35, 0.4, 0.6) : float3(0.75, 0.68, 0.5));
    if (lp.y < g.origin.y + 300.0) {
        float3 li = g.ambient.rgb;
        int lc = int(g.counts.y + 0.5);
        for (int i = 0; i < lc; i++) {
            float2 d = lp - lights[i].posRad.xy;
            float a = clamp(1.0 - length(d) / lights[i].posRad.z, 0.0, 1.0);
            li += lights[i].color.rgb * lights[i].color.a * a * a;
        }
        c *= li;
        c = weather(c, lp, g);
    }
    float luma = dot(c, float3(0.299, 0.587, 0.114));
    c = mix(float3(luma), c, 1.12);
    c = (c - 0.5) * 1.04 + 0.5;
    float2 q = uv - 0.5;
    c *= 1.0 - g.ambient.a * dot(q, q) * 1.6;
    c = max(c, 0.0);
    c = c / (1.0 + max(c - 0.85, 0.0));
    return float4(c, 1.0);
}
"""
