// 情境 shaders (2026-11-18). These only draw: they never sample the view they sit
// on, so AppKit-backed lyric rows, video and other platform views keep working.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

namespace v3 {
    inline float S(float a, float b, float t) { return smoothstep(a, b, t); }
    inline float3 N13(float p) {
        float3 p3 = fract(float3(p) * float3(.1031, .11369, .13787));
        p3 += dot(p3, p3.yzx + 19.19);
        return fract(float3((p3.x + p3.y) * p3.z, (p3.x + p3.z) * p3.y, (p3.y + p3.z) * p3.x));
    }
    inline float saw(float b, float t) { return S(0., b, t) * S(1., b, t); }

    // Sliding drops with a trail of small beads (after Martijn Steinrucken's
    // "Heartfelt" drop layer, rewritten for SwiftUI's y-down coordinates).
    float2 dropLayer(float2 uv, float t) {
        float2 UV = uv;
        uv.y += t * 0.75;
        float2 a = float2(6., 1.);
        float2 grid = a * 2.;
        float2 id = floor(uv * grid);
        float colShift = N13(id.x).x;
        uv.y += colShift;
        id = floor(uv * grid);
        float3 n = N13(id.x * 35.2 + id.y * 2376.1);
        float2 st = fract(uv * grid) - float2(.5, 0);
        float x = n.x - .5;
        float y = UV.y * 20.;
        float wiggle = sin(y + sin(y));
        x += wiggle * (.5 - abs(x)) * (n.z - .5);
        x *= .7;
        float ti = fract(t + n.z);
        y = (saw(.85, ti) - .5) * .9 + .5;
        float2 p = float2(x, y);
        float d = length((st - p) * a.yx);
        float mainDrop = S(.4, .0, d);
        float r = sqrt(S(1., y, st.y));
        float cd = abs(st.x - x);
        float trail = S(.23 * r, .15 * r * r, cd);
        float trailFront = S(-.02, .02, st.y - y);
        trail *= trailFront * r * r;
        y = UV.y;
        y = fract(y * 10.) + (st.y - .5);
        float dd = length(st - float2(x, y));
        float droplets = S(.3, 0., dd);
        float m = mainDrop + droplets * r * trailFront;
        return float2(m, trail);
    }

    float staticDrops(float2 uv, float t) {
        uv *= 40.;
        float2 id = floor(uv);
        uv = fract(uv) - .5;
        float3 n = N13(id.x * 107.45 + id.y * 3543.654);
        float2 p = (n.xy - .5) * .7;
        float d = length(uv - p);
        float fade = saw(.025, fract(t + n.z));
        return S(.3, 0., d) * fract(n.z * 10.) * fade;
    }

    float2 drops(float2 uv, float t, float l0, float l1, float l2) {
        float s = staticDrops(uv, t) * l0;
        float2 m1 = dropLayer(uv, t) * l1;
        float2 m2 = dropLayer(uv * 1.85, t) * l2;
        float c = s + m1.x + m2.x;
        c = S(.3, 1., c);
        return float2(c, max(m1.y * l0, m2.y * l1));
    }
}

/// 雨滴玻璃: each drop is a lens showing the cover, bent by the drop's surface.
/// `cover` is drawn as the backdrop fills the window (aspect fill), so a drop shows
/// roughly what is behind it, slightly magnified and upside down.
[[ stitchable ]] half4 v3RainLens(float2 position, half4 color, float2 size, float time, float heavy,
                                  texture2d<half> cover) {
    float2 uv = (position - 0.5 * size) / size.y;
    uv.y = -uv.y;
    float t = time * 0.2;
    float l0 = 1.0, l1 = 0.6 + 0.4 * heavy, l2 = 0.35 + 0.65 * heavy;
    float2 c = v3::drops(uv * 1.4, t, l0, l1, l2);
    float2 e = float2(0.0012, 0.);
    float cx = v3::drops((uv + e) * 1.4, t, l0, l1, l2).x;
    float cy = v3::drops((uv + e.yx) * 1.4, t, l0, l1, l2).x;
    float2 n = float2(cx - c.x, cy - c.x);
    float mask = saturate(c.x);
    if (mask < 0.01 && c.y < 0.01) { return half4(0); }

    // Where on the cover this pixel would be under aspect fill, pushed by the drop normal.
    float2 screen = position / size;
    float aspect = size.x / size.y;
    float2 coverUV = aspect > 1 ? float2(screen.x, 0.5 + (screen.y - 0.5) / aspect)
                                : float2(0.5 + (screen.x - 0.5) * aspect, screen.y);
    float2 lens = coverUV - n * 9.0 + (0.5 - coverUV) * 0.18 * mask;
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    half3 seen = cover.sample(s, clamp(lens, 0.0, 1.0)).rgb;

    // Rim darkening, a catch-light from the upper left, and the wet trail.
    float rim = saturate(length(n) * 60.0);
    float spec = pow(saturate(dot(normalize(float3(n * 80.0, 1.0)), normalize(float3(-0.5, 0.6, 0.9)))), 24.0);
    half3 rgb = seen * half(1.0 - 0.45 * rim) + half3(spec * 0.9);
    float alpha = saturate(mask * 0.92 + c.y * 0.10);
    return half4(rgb * half(alpha), half(alpha));
}

/// 水面: animated caustic light (water turbulence), tinted, with ripples as rings.
/// `ripples` holds x, y, age triples in points and seconds.
[[ stitchable ]] half4 v3Caustics(float2 position, half4 color, float2 size, float time, half4 tint, float strength,
                                  device const float *ripples, int count) {
    const float tau = 6.28318530718;
    float2 uv = position / max(size.x, size.y) * 1.6;
    // Ripples push the pattern outwards as they pass.
    float ring = 0.0;
    for (int i = 0; i + 2 < count; i += 3) {
        float2 c = float2(ripples[i], ripples[i + 1]);
        float age = ripples[i + 2];
        float d = distance(position, c);
        float front = age * 150.0;
        float w = exp(-pow((d - front) / 18.0, 2.0)) * exp(-age * 0.9);
        ring += w;
        uv += normalize(position - c + 0.001) * w * 0.02;
    }
    float t = time * 0.5 + 23.0;
    float2 p = fmod(uv * tau, tau) - 250.0;
    float2 i = p;
    float c = 1.0;
    const float inten = 0.005;
    for (int n = 0; n < 5; n++) {
        float tt = t * (1.0 - (3.5 / float(n + 1)));
        i = p + float2(cos(tt - i.x) + sin(tt + i.y), sin(tt - i.y) + cos(tt + i.x));
        c += 1.0 / length(float2(p.x / (sin(i.x + tt) / inten), p.y / (cos(i.y + tt) / inten)));
    }
    c /= 5.0;
    c = 1.17 - pow(c, 1.4);
    float light = pow(abs(c), 8.0);
    float a = saturate(light * strength + ring * 0.35 * strength);
    return half4(tint.rgb * half(a), half(a));
}
