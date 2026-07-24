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
