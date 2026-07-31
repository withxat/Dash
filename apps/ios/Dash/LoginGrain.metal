#include <metal_stdlib>
using namespace metal;

// Static white-noise film grain for SwiftUI surfaces. `position` arrives in
// view points; scaling before hashing keeps grain cells finer than one point
// on 2x/3x screens.
[[ stitchable ]] half4 surfaceGrain(float2 position, half4 color, float intensity) {
    float2 cell = floor(position * 2.0);
    float noise = fract(sin(dot(cell, float2(12.9898, 78.233))) * 43758.5453);
    half grain = (half(noise) - 0.5h) * half(intensity);
    return half4(color.rgb + grain, color.a);
}

// -----------------------------------------------------------------------------
// Login paper texture — Metal port of Paper Design's Paper Texture shader
// (https://github.com/paper-design/shaders), Apache License 2.0.
//
// Paper Shaders
// Copyright 2026 Paper
// Powered by Paper Shaders: https://shaders.paper.design
//
// Dash changes: stitchable colorEffect (no image filter path); lighting
// modulates the underlying SwiftUI color so the login mesh/gradient palette
// shows through. Noise LUT is Paper's bundled 128×128 texture (PaperNoise).
// -----------------------------------------------------------------------------

constant float kPaperTwoPi = 6.28318530718;

constexpr sampler paperNoiseSampler(address::repeat, filter::linear);

float2 paperRotate(float2 uv, float th) {
    float c = cos(th);
    float s = sin(th);
    return float2x2(c, s, -s, c) * uv;
}

float paperRandomR(float2 p, texture2d<half> noiseTexture) {
    float2 uv = floor(p) / 100.0 + 0.5;
    return float(noiseTexture.sample(paperNoiseSampler, fract(uv)).r);
}

float paperRandomG(float2 p, texture2d<half> noiseTexture) {
    float2 uv = floor(p) / 50.0 + 0.5;
    return float(noiseTexture.sample(paperNoiseSampler, fract(uv)).g);
}

float2 paperRandomGB(float2 p, texture2d<half> noiseTexture) {
    float2 uv = floor(p) / 50.0 + 0.5;
    half4 sample = noiseTexture.sample(paperNoiseSampler, fract(uv));
    return float2(sample.g, sample.b);
}

float paperValueNoise(float2 st, texture2d<half> noiseTexture) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = paperRandomR(i, noiseTexture);
    float b = paperRandomR(i + float2(1.0, 0.0), noiseTexture);
    float c = paperRandomR(i + float2(0.0, 1.0), noiseTexture);
    float d = paperRandomR(i + float2(1.0, 1.0), noiseTexture);
    float2 u = f * f * (3.0 - 2.0 * f);
    float x1 = mix(a, b, u.x);
    float x2 = mix(c, d, u.x);
    return mix(x1, x2, u.y);
}

float paperFbm(float2 n, texture2d<half> noiseTexture) {
    float total = 0.0;
    float amplitude = 0.4;
    for (int i = 0; i < 3; i++) {
        total += paperValueNoise(n, noiseTexture) * amplitude;
        n *= 1.99;
        amplitude *= 0.65;
    }
    return total;
}

float paperRoughness(float2 p, texture2d<half> noiseTexture) {
    p *= 0.1;
    float o = 0.0;
    for (float i = 0.0; ++i < 4.0; p *= 2.1) {
        float4 w = float4(floor(p), ceil(p));
        float2 f = fract(p);
        o += mix(
            mix(paperRandomG(w.xy, noiseTexture), paperRandomG(w.xw, noiseTexture), f.y),
            mix(paperRandomG(w.zy, noiseTexture), paperRandomG(w.zw, noiseTexture), f.y),
            f.x);
        o += 0.2 / exp(2.0 * abs(sin(0.2 * p.x + 0.5 * p.y)));
    }
    return o / 3.0;
}

float paperFiberRandom(float2 p, texture2d<half> noiseTexture) {
    float2 uv = floor(p) / 100.0;
    return float(noiseTexture.sample(paperNoiseSampler, fract(uv)).b);
}

float paperFiberValueNoise(float2 st, texture2d<half> noiseTexture) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = paperFiberRandom(i, noiseTexture);
    float b = paperFiberRandom(i + float2(1.0, 0.0), noiseTexture);
    float c = paperFiberRandom(i + float2(0.0, 1.0), noiseTexture);
    float d = paperFiberRandom(i + float2(1.0, 1.0), noiseTexture);
    float2 u = f * f * (3.0 - 2.0 * f);
    float x1 = mix(a, b, u.x);
    float x2 = mix(c, d, u.x);
    return mix(x1, x2, u.y);
}

float paperFiberNoiseFbm(float2 n, float2 seedOffset, texture2d<half> noiseTexture) {
    float total = 0.0;
    float amplitude = 1.0;
    for (int i = 0; i < 4; i++) {
        n = paperRotate(n, 0.7);
        total += paperFiberValueNoise(n + seedOffset, noiseTexture) * amplitude;
        n *= 2.0;
        amplitude *= 0.6;
    }
    return total;
}

float paperFiberNoise(float2 uv, float2 seedOffset, texture2d<half> noiseTexture) {
    float epsilon = 0.001;
    float n1 = paperFiberNoiseFbm(uv + float2(epsilon, 0.0), seedOffset, noiseTexture);
    float n2 = paperFiberNoiseFbm(uv - float2(epsilon, 0.0), seedOffset, noiseTexture);
    float n3 = paperFiberNoiseFbm(uv + float2(0.0, epsilon), seedOffset, noiseTexture);
    float n4 = paperFiberNoiseFbm(uv - float2(0.0, epsilon), seedOffset, noiseTexture);
    return length(float2(n1 - n2, n3 - n4)) / (2.0 * epsilon);
}

float paperCrumpledNoise(float2 t, float pw, texture2d<half> noiseTexture) {
    float2 p = floor(t);
    float wsum = 0.0;
    float cl = 0.0;
    for (int y = -1; y < 2; y += 1) {
        for (int x = -1; x < 2; x += 1) {
            float2 b = float2(float(x), float(y));
            float2 q = b + p;
            float2 q2 = q - floor(q / 8.0) * 8.0;
            float2 c = q + paperRandomGB(q2, noiseTexture);
            float2 r = c - t;
            float w = pow(smoothstep(0.0, 1.0, 1.0 - abs(r.x)), pw)
                * pow(smoothstep(0.0, 1.0, 1.0 - abs(r.y)), pw);
            cl += (0.5 + 0.5 * sin((q2.x + q2.y * 5.0) * 8.0)) * w;
            wsum += w;
        }
    }
    return pow(wsum != 0.0 ? cl / wsum : 0.0, 0.5) * 2.0;
}

float paperCrumplesShape(float2 uv, texture2d<half> noiseTexture) {
    return paperCrumpledNoise(uv * 0.25, 16.0, noiseTexture)
        * paperCrumpledNoise(uv * 0.5, 2.0, noiseTexture);
}

float2 paperFolds(float2 uv, float foldCount, float seed, texture2d<half> noiseTexture) {
    float3 pp = float3(0.0);
    float l = 9.0;
    for (float i = 0.0; i < 15.0; i++) {
        if (i >= foldCount) break;
        float2 rand = paperRandomGB(float2(i, i * seed), noiseTexture);
        float an = rand.x * kPaperTwoPi;
        float2 p = float2(cos(an), sin(an)) * rand.y;
        float dist = distance(uv, p);
        l = min(l, dist);
        if (l == dist) {
            pp.xy = uv - p.xy;
            pp.z = dist;
        }
    }
    return mix(pp.xy, float2(0.0), pow(pp.z, 0.25));
}

float paperDrops(float2 uv, float seed, texture2d<half> noiseTexture) {
    float2 iDropsUV = floor(uv);
    float2 fDropsUV = fract(uv);
    float dropsMinDist = 1.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 neighbor = float2(float(i), float(j));
            float2 offset = paperRandomGB(iDropsUV + neighbor, noiseTexture);
            offset = 0.5 + 0.5 * sin(10.0 * seed + kPaperTwoPi * offset);
            float2 pos = neighbor + offset - fDropsUV;
            float dist = length(pos);
            dropsMinDist = min(dropsMinDist, dropsMinDist * dist);
        }
    }
    return 1.0 - smoothstep(0.05, 0.09, pow(dropsMinDist, 0.5));
}

[[ stitchable ]] half4 loginPaperTexture(
    float2 position,
    half4 color,
    texture2d<half> noiseTexture,
    float contrast,
    float roughnessAmt,
    float fiber,
    float fiberSize,
    float crumples,
    float crumpleSize,
    float foldsAmt,
    float foldCount,
    float dropsAmt,
    float fade,
    float seed,
    float scale,
    float2 size
) {
    float safeScale = max(scale, 0.01);
    float2 safeSize = max(size, float2(1.0));
    float aspect = safeSize.x / safeSize.y;

    float2 uv = position / safeSize;
    float2 patternUV = (uv - 0.5) * float2(aspect, 1.0);
    patternUV = (5.0 / safeScale) * patternUV;

    float2 roughnessUv = 1.5 * (position - 0.5 * safeSize);
    float roughness = paperRoughness(roughnessUv + float2(1.0, 0.0), noiseTexture)
        - paperRoughness(roughnessUv - float2(1.0, 0.0), noiseTexture);
    roughness *= roughnessAmt;

    float crumpleSafe = max(crumpleSize, 0.01);
    float2 crumplesUV = fract(patternUV * 0.02 / crumpleSafe - seed) * 32.0;
    float crumple = crumples
        * (paperCrumplesShape(crumplesUV + float2(0.05, 0.0), noiseTexture)
            - paperCrumplesShape(crumplesUV, noiseTexture));

    float fiberSafe = max(fiberSize, 0.01);
    float2 fiberUV = (2.0 / fiberSafe) * patternUV;
    float fiberN = paperFiberNoise(fiberUV, float2(0.0), noiseTexture);
    fiberN = 0.5 * fiber * (fiberN - 1.0);

    float2 foldsUV = patternUV * 0.12;
    foldsUV = paperRotate(foldsUV, 4.0 * seed);
    float2 w = paperFolds(foldsUV, foldCount, seed, noiseTexture);
    foldsUV = paperRotate(foldsUV + 0.007 * cos(seed), 0.01 * sin(seed));
    float2 w2 = paperFolds(foldsUV, foldCount, seed, noiseTexture);

    float drops = dropsAmt * paperDrops(patternUV * 2.0, seed, noiseTexture);

    float fadeMask = fade * paperFbm(0.17 * patternUV + 10.0 * seed, noiseTexture);
    fadeMask = clamp(8.0 * fadeMask * fadeMask * fadeMask, 0.0, 1.0);

    w = mix(w, float2(0.0), fadeMask);
    w2 = mix(w2, float2(0.0), fadeMask);
    crumple = mix(crumple, 0.0, fadeMask);
    drops = mix(drops, 0.0, fadeMask);
    fiberN *= mix(1.0, 0.5, fadeMask);
    roughness *= mix(1.0, 0.5, fadeMask);

    float2 normal = float2(0.0);
    normal += foldsAmt * min(5.0 * contrast, 1.0) * 4.0 * max(float2(0.0), w + w2);
    normal += crumple;
    normal += 3.0 * drops;
    normal += 1.5 * roughness;
    normal += fiberN;

    float3 lightPos = float3(1.0, 2.0, 1.0);
    float res = dot(
        normalize(float3(normal, 9.5 - 9.0 * pow(contrast, 0.1))),
        normalize(lightPos));

    float3 rgb = float3(color.rgb);
    rgb += 0.6 * pow(contrast, 0.4) * (res - 0.7);
    rgb -= 0.007 * drops;
    rgb = clamp(rgb, 0.0, 1.0);

    return half4(half3(rgb), color.a);
}

// -----------------------------------------------------------------------------
// Login mesh gradient — Metal port of Paper Design's Mesh Gradient shader
// (https://github.com/paper-design/shaders), Apache License 2.0.
//
// Paper Shaders
// Copyright 2026 Paper
// Powered by Paper Shaders: https://shaders.paper.design
//
// Dash changes: stitchable colorEffect; four color spots from LoginBackdrop;
// object UV derived from view position (scale / fill). Incoming `color` is
// ignored — the mesh paints the backdrop.
// -----------------------------------------------------------------------------

float meshHash21(float2 p) {
    p = fract(p * float2(0.3183099, 0.3678794)) + 0.1;
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}

float meshValueNoise(float2 st) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = meshHash21(i);
    float b = meshHash21(i + float2(1.0, 0.0));
    float c = meshHash21(i + float2(0.0, 1.0));
    float d = meshHash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    float x1 = mix(a, b, u.x);
    float x2 = mix(c, d, u.x);
    return mix(x1, x2, u.y);
}

float2 meshGetPosition(int i, float t) {
    float a = float(i) * 0.37;
    float b = 0.6 + fract(float(i) / 3.0) * 0.9;
    float c = 0.8 + fract(float(i + 1) / 4.0);
    float x = sin(t * b + a);
    float y = cos(t * c + a * 1.5);
    return 0.5 + 0.5 * float2(x, y);
}

[[ stitchable ]] half4 loginMeshGradient(
    float2 position,
    half4 color,
    float time,
    float distortion,
    float swirl,
    float grainMixer,
    float grainOverlay,
    float scale,
    float2 size,
    float4 color0,
    float4 color1,
    float4 color2,
    float4 color3
) {
    float2 safeSize = max(size, float2(1.0));
    float safeScale = max(scale, 0.01);

    // Paper object UV: clip-space * 0.5 → roughly −0.5…0.5, then / scale.
    float2 uv = ((position / safeSize) - 0.5) / safeScale;
    uv += 0.5;

    float2 grainUV = uv * 1000.0;
    float grain = meshValueNoise(grainUV);
    float mixerGrain = 0.4 * grainMixer * (grain - 0.5);

    const float firstFrameOffset = 41.5;
    float t = 0.5 * (time + firstFrameOffset);

    float radius = smoothstep(0.0, 1.0, length(uv - 0.5));
    float center = 1.0 - radius;
    for (float i = 1.0; i <= 2.0; i++) {
        uv.x += distortion * center / i
            * sin(t + i * 0.4 * smoothstep(0.0, 1.0, uv.y))
            * cos(0.2 * t + i * 2.4 * smoothstep(0.0, 1.0, uv.y));
        uv.y += distortion * center / i
            * cos(t + i * 2.0 * smoothstep(0.0, 1.0, uv.x));
    }

    float2 uvRotated = uv;
    uvRotated -= float2(0.5);
    float angle = 3.0 * swirl * radius;
    uvRotated = paperRotate(uvRotated, -angle);
    uvRotated += float2(0.5);

    float4 spots[4] = { color0, color1, color2, color3 };
    float3 outColor = float3(0.0);
    float opacity = 0.0;
    float totalWeight = 0.0;

    for (int i = 0; i < 4; i++) {
        float2 pos = meshGetPosition(i, t) + mixerGrain;
        float3 colorFraction = spots[i].rgb * spots[i].a;
        float opacityFraction = spots[i].a;
        float dist = length(uvRotated - pos);
        dist = pow(dist, 3.5);
        float weight = 1.0 / (dist + 1e-3);
        outColor += colorFraction * weight;
        opacity += opacityFraction * weight;
        totalWeight += weight;
    }

    outColor /= max(1e-4, totalWeight);
    opacity /= max(1e-4, totalWeight);

    float grainOverlayN = meshValueNoise(paperRotate(grainUV, 1.0) + float2(3.0));
    grainOverlayN = mix(
        grainOverlayN,
        meshValueNoise(paperRotate(grainUV, 2.0) + float2(-1.0)),
        0.5);
    grainOverlayN = pow(grainOverlayN, 1.3);

    float grainOverlayV = grainOverlayN * 2.0 - 1.0;
    float3 grainOverlayColor = float3(step(0.0, grainOverlayV));
    float grainOverlayStrength = grainOverlay * abs(grainOverlayV);
    grainOverlayStrength = pow(grainOverlayStrength, 0.8);
    outColor = mix(outColor, grainOverlayColor, 0.35 * grainOverlayStrength);

    opacity += 0.5 * grainOverlayStrength;
    opacity = clamp(opacity, 0.0, 1.0);

    return half4(half3(outColor), half(opacity));
}
