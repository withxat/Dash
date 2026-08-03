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

float2 paperRotate(float2 uv, float th) {
    float c = cos(th);
    float s = sin(th);
    return float2x2(c, s, -s, c) * uv;
}

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
