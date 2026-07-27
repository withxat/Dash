// Rendering structure and spherical-Fibonacci globe treatment are inspired by
// COBE by Shu Ding (MIT): https://github.com/shuding/cobe
//
// This is an independent Metal Shading Language implementation for
// SwiftGlobeKit. It does not embed COBE's JavaScript, GLSLX build output, or
// world-map texture.

#include <metal_stdlib>
using namespace metal;

namespace swift_globe {

constant float kPi = 3.14159265358979323846;
constant float kTau = 6.28318530717958647692;
constant float kSqrtFive = 2.23606797749978969640;
constant float kGoldenRatio = 1.61803398874989484820;
constant float kGlobeRadius = 0.8;

struct GlobeUniforms {
  // xy: drawable resolution, zw: phi and theta
  float4 resolutionRotation;
  // x: map samples, y: scale, zw: drawable-pixel offset
  float4 samplesScaleOffset;
  // xyz: base color, w: map brightness
  float4 baseColorBrightness;
  // xyz: glow color, w: map base brightness
  float4 glowColorBaseBrightness;
  // x: diffuse, y: darkness, z: opacity, w: reserved
  float4 renderParameters;
};

struct MarkerUniforms {
  // xy: drawable resolution, zw: phi and theta
  float4 resolutionRotation;
  // x: scale, y: marker elevation, zw: drawable-pixel offset
  float4 scaleElevationOffset;
  // xyz: default marker color
  float4 defaultColor;
};

struct ArcUniforms {
  // xy: drawable resolution, zw: phi and theta
  float4 resolutionRotation;
  // x: scale, y: marker elevation, zw: drawable-pixel offset
  float4 scaleElevationOffset;
  // xyz: default arc color
  float4 defaultColor;
};

struct MarkerInstance {
  // xyz: unit-sphere position, w: marker size
  float4 positionSize;
  // xyz: optional custom color, w: 1 when the custom color is present
  float4 colorAndFlag;
};

struct ArcInstance {
  // xyz: unit-sphere endpoints
  float4 from;
  float4 to;
  // xyz: optional custom color, w: 1 when the custom color is present
  float4 colorAndFlag;
  // x: width, y: height
  float4 dimensions;
};

struct GlobeVertexOutput {
  float4 position [[position]];
};

struct MarkerVertexOutput {
  float4 position [[position]];
  float2 unitPosition;
  float3 color;
};

struct ArcVertexOutput {
  float4 position [[position]];
  float3 color;
  float depth;
  float radialDistance;
  float edgeCoordinate;
};

float3 rotateWorldToView(float3 point, float phi, float theta) {
  const float cx = cos(theta);
  const float sx = sin(theta);
  const float cy = cos(phi);
  const float sy = sin(phi);

  return float3(
    cy * point.x + sy * point.z,
    sy * sx * point.x + cx * point.y - cy * sx * point.z,
    -sy * cx * point.x + sx * point.y + cy * cx * point.z
  );
}

float3 rotateViewToWorld(float3 point, float phi, float theta) {
  const float cx = cos(theta);
  const float sx = sin(theta);
  const float cy = cos(phi);
  const float sy = sin(phi);

  return float3(
    cy * point.x + sy * sx * point.y - sy * cx * point.z,
    cx * point.y + sx * point.z,
    sy * point.x - cy * sx * point.y + cy * cx * point.z
  );
}

float3 nearestFibonacciLattice(float3 inputPoint, float dots, thread float& distanceToPoint) {
  const float safeDots = max(dots, 2.0);
  const float3 point = inputPoint.xzy;
  const float latitudeFactor = max(1.0 - point.z * point.z, 1e-6);
  const float k = max(
    2.0,
    floor(log2(kSqrtFive * safeDots * kPi * latitudeFactor) * 0.72021)
  );

  const float2 fibonacci = floor(
    pow(kGoldenRatio, k) / kSqrtFive * float2(1.0, kGoldenRatio) + 0.5
  );
  const float2 basisOne =
    fract((fibonacci + 1.0) * (kGoldenRatio - 1.0)) * kTau - 3.883222;
  const float2 basisTwo = -2.0 * fibonacci;
  const float2 sphericalPoint = float2(atan2(point.y, point.x), point.z - 1.0);
  const float determinant =
    basisOne.x * basisTwo.y - basisTwo.x * basisOne.y;
  const float2 cell = floor(
    float2(
      basisTwo.y * sphericalPoint.x -
        basisOne.y * (sphericalPoint.y * safeDots + 1.0),
      -basisTwo.x * sphericalPoint.x +
        basisOne.x * (sphericalPoint.y * safeDots + 1.0)
    ) / determinant
  );

  float minimumDistance = kPi;
  float3 minimumPoint = float3(0.0, 1.0, 0.0);

  for (uint sampleIndex = 0; sampleIndex < 4; sampleIndex += 1) {
    const float2 sampleOffset = float2(
      float(sampleIndex % 2),
      floor(float(sampleIndex) * 0.5)
    );
    const float index = dot(fibonacci, cell + sampleOffset);
    if (index < 0.0 || index > safeDots) {
      continue;
    }

    float reducedIndex = index;
    float goldenFraction = 0.0;
    if (reducedIndex >= 32768.0) {
      reducedIndex -= 32768.0;
      goldenFraction += 0.737743;
    }
    if (reducedIndex >= 16384.0) {
      reducedIndex -= 16384.0;
      goldenFraction += 0.868872;
    }
    if (reducedIndex >= 8192.0) {
      reducedIndex -= 8192.0;
      goldenFraction += 0.934436;
    }
    if (reducedIndex >= 4096.0) {
      reducedIndex -= 4096.0;
      goldenFraction += 0.467218;
    }
    if (reducedIndex >= 2048.0) {
      reducedIndex -= 2048.0;
      goldenFraction += 0.733609;
    }
    if (reducedIndex >= 1024.0) {
      reducedIndex -= 1024.0;
      goldenFraction += 0.866804;
    }
    if (reducedIndex >= 512.0) {
      reducedIndex -= 512.0;
      goldenFraction += 0.433402;
    }
    if (reducedIndex >= 256.0) {
      reducedIndex -= 256.0;
      goldenFraction += 0.216701;
    }
    if (reducedIndex >= 128.0) {
      reducedIndex -= 128.0;
      goldenFraction += 0.108351;
    }
    if (reducedIndex >= 64.0) {
      reducedIndex -= 64.0;
      goldenFraction += 0.554175;
    }
    if (reducedIndex >= 32.0) {
      reducedIndex -= 32.0;
      goldenFraction += 0.777088;
    }
    if (reducedIndex >= 16.0) {
      reducedIndex -= 16.0;
      goldenFraction += 0.888544;
    }
    if (reducedIndex >= 8.0) {
      reducedIndex -= 8.0;
      goldenFraction += 0.944272;
    }
    if (reducedIndex >= 4.0) {
      reducedIndex -= 4.0;
      goldenFraction += 0.472136;
    }
    if (reducedIndex >= 2.0) {
      reducedIndex -= 2.0;
      goldenFraction += 0.236068;
    }
    if (reducedIndex >= 1.0) {
      goldenFraction += 0.618034;
    }

    const float azimuth = fract(goldenFraction) * kTau;
    const float cosineLatitude = 1.0 - 2.0 * index / safeDots;
    const float sineLatitude = sqrt(max(1.0 - cosineLatitude * cosineLatitude, 0.0));
    const float3 candidate = float3(
      cos(azimuth) * sineLatitude,
      sin(azimuth) * sineLatitude,
      cosineLatitude
    );
    const float candidateDistance = distance(point, candidate);

    if (candidateDistance < minimumDistance) {
      minimumDistance = candidateDistance;
      minimumPoint = candidate;
    }
  }

  distanceToPoint = minimumDistance;
  return minimumPoint.xzy;
}

vertex GlobeVertexOutput swiftGlobeVertex(uint vertexID [[vertex_id]]) {
  constexpr float2 positions[6] = {
    float2(-1.0, -1.0),
    float2(1.0, -1.0),
    float2(-1.0, 1.0),
    float2(-1.0, 1.0),
    float2(1.0, -1.0),
    float2(1.0, 1.0),
  };

  GlobeVertexOutput output;
  output.position = float4(positions[vertexID], 0.0, 1.0);
  return output;
}

fragment float4 swiftGlobeFragment(
  GlobeVertexOutput input [[stage_in]],
  constant GlobeUniforms& uniforms [[buffer(0)]],
  texture2d<float> landMask [[texture(0)]],
  sampler landSampler [[sampler(0)]]
) {
  const float2 resolution = max(uniforms.resolutionRotation.xy, float2(1.0));
  const float phi = uniforms.resolutionRotation.z;
  const float theta = uniforms.resolutionRotation.w;
  const float mapSamples = max(uniforms.samplesScaleOffset.x, 2.0);
  const float scale = max(uniforms.samplesScaleOffset.y, 1e-4);
  const float2 offset = uniforms.samplesScaleOffset.zw;

  // Metal fragment positions use a top-left origin. Flip y into the
  // globe's conventional positive-up coordinate system.
  float2 uv = input.position.xy / resolution * 2.0 - 1.0;
  uv.y = -uv.y;
  uv = uv / scale - offset * float2(1.0, -1.0) / resolution;
  uv.x *= resolution.x / resolution.y;

  const float radiusSquared = kGlobeRadius * kGlobeRadius;
  const float squaredLength = dot(uv, uv);
  const float opacity = clamp(uniforms.renderParameters.z, 0.0, 1.0);
  float3 outputColor = float3(0.0);
  float outputAlpha = 0.0;
  float glowFactor = 0.0;

  if (squaredLength <= radiusSquared) {
    const float surfaceZ = sqrt(max(radiusSquared - squaredLength, 0.0));
    const float3 viewPoint = normalize(float3(uv, surfaceZ));
    const float3 globePoint = rotateViewToWorld(viewPoint, phi, theta);
    const float normalLighting = max(viewPoint.z, 0.0);

    float latticeDistance = 0.0;
    const float3 latticePoint =
      nearestFibonacciLattice(globePoint, mapSamples, latticeDistance);
    const float latitude = asin(clamp(latticePoint.y, -1.0, 1.0));
    const float longitude = atan2(latticePoint.x, latticePoint.z);

    const float2 mapCoordinates = float2(
      longitude / kTau + 0.5,
      0.5 - latitude / kPi
    );
    const float mapValue = max(
      landMask.sample(landSampler, mapCoordinates).r,
      uniforms.glowColorBaseBrightness.w
    );
    const float dotCoverage =
      1.0 - smoothstep(0.0, 0.008, latticeDistance);
    const float illuminatedSample =
      mapValue *
      dotCoverage *
      pow(normalLighting, max(uniforms.renderParameters.x, 0.0)) *
      uniforms.baseColorBrightness.w;
    const float darkness = clamp(uniforms.renderParameters.y, 0.0, 1.0);
    const float colorFactor = mix(
      (1.0 - illuminatedSample) * pow(normalLighting, 0.4),
      illuminatedSample,
      darkness
    ) + 0.1;
    const float rim = pow(1.0 - normalLighting, 4.0);

    outputColor =
      uniforms.baseColorBrightness.xyz * colorFactor +
      uniforms.glowColorBaseBrightness.xyz * rim;
    outputAlpha = opacity;
  } else {
    const float outsideDistance = max(squaredLength - radiusSquared, 1e-5);
    const float glowDistance = sqrt(0.2 / outsideDistance);
    glowFactor = smoothstep(
      0.5,
      1.0,
      glowDistance / (glowDistance + 1.0)
    );
  }

  outputColor += glowFactor * uniforms.glowColorBaseBrightness.xyz;
  outputAlpha = clamp(outputAlpha + glowFactor * opacity, 0.0, 1.0);
  return float4(outputColor, outputAlpha);
}

vertex ArcVertexOutput swiftGlobeArcVertex(
  uint vertexID [[vertex_id]],
  uint instanceID [[instance_id]],
  constant ArcInstance* instances [[buffer(0)]],
  constant ArcUniforms& uniforms [[buffer(1)]]
) {
  const ArcInstance instance = instances[instanceID];
  const uint segment = vertexID / 2;
  const float t = float(segment) / 32.0;
  const float side = (vertexID & 1) == 0 ? -1.0 : 1.0;
  const float2 resolution = max(uniforms.resolutionRotation.xy, float2(1.0));
  const float phi = uniforms.resolutionRotation.z;
  const float theta = uniforms.resolutionRotation.w;
  const float scale = max(uniforms.scaleElevationOffset.x, 1e-4);
  const float markerElevation = uniforms.scaleElevationOffset.y;
  const float2 offset = uniforms.scaleElevationOffset.zw;

  const float endpointRadius = kGlobeRadius + markerElevation;
  const float3 from = instance.from.xyz * endpointRadius;
  const float3 to = instance.to.xyz * endpointRadius;
  const float3 midpointSum = instance.from.xyz + instance.to.xyz;
  const float midpointLength = length(midpointSum);
  const float3 midpointDirection = midpointLength > 0.001
    ? midpointSum / midpointLength
    : float3(0.0, 1.0, 0.0);
  const float3 midpoint = midpointDirection *
    (kGlobeRadius + markerElevation + instance.dimensions.y);

  const float inverseT = 1.0 - t;
  const float3 arcPoint =
    inverseT * inverseT * from +
    2.0 * inverseT * t * midpoint +
    t * t * to;
  const float3 tangent =
    2.0 * inverseT * (midpoint - from) +
    2.0 * t * (to - midpoint);
  const float3 rotatedPoint = rotateWorldToView(arcPoint, phi, theta);
  const float3 rotatedTangent = rotateWorldToView(tangent, phi, theta);
  const float tangentLength = length(rotatedTangent.xy);
  const float2 perpendicular = tangentLength > 0.001
    ? float2(-rotatedTangent.y, rotatedTangent.x) / tangentLength
    : float2(1.0, 0.0);

  const float aspect = resolution.x / resolution.y;
  const float2 basePosition =
    rotatedPoint.xy * float2(1.0 / aspect, 1.0) * scale +
    offset * float2(1.0, -1.0) * scale / resolution;
  const float ribbonWidth = instance.dimensions.x * 0.005;
  const float2 ribbonOffset =
    perpendicular *
    float2(1.0 / aspect, 1.0) *
    ribbonWidth *
    side *
    scale;
  const float2 screenPosition =
    basePosition + ribbonOffset;

  ArcVertexOutput output;
  output.position = float4(screenPosition, 0.0, 1.0);
  output.color = instance.colorAndFlag.w > 0.5
    ? instance.colorAndFlag.xyz
    : uniforms.defaultColor.xyz;
  output.depth = rotatedPoint.z;
  output.radialDistance = length(rotatedPoint.xy);
  output.edgeCoordinate = side;
  return output;
}

fragment float4 swiftGlobeArcFragment(ArcVertexOutput input [[stage_in]]) {
  if (input.depth < 0.0 && input.radialDistance < kGlobeRadius) {
    discard_fragment();
  }

  const float edgeWidth = max(fwidth(input.edgeCoordinate), 1e-3);
  const float coverage =
    1.0 - smoothstep(1.0 - edgeWidth, 1.0, abs(input.edgeCoordinate));
  return float4(input.color, coverage);
}

vertex MarkerVertexOutput swiftGlobeMarkerVertex(
  uint vertexID [[vertex_id]],
  uint instanceID [[instance_id]],
  constant MarkerInstance* instances [[buffer(0)]],
  constant MarkerUniforms& uniforms [[buffer(1)]]
) {
  constexpr float2 positions[6] = {
    float2(-1.0, -1.0),
    float2(1.0, -1.0),
    float2(-1.0, 1.0),
    float2(-1.0, 1.0),
    float2(1.0, -1.0),
    float2(1.0, 1.0),
  };

  const MarkerInstance instance = instances[instanceID];
  const float2 resolution = max(uniforms.resolutionRotation.xy, float2(1.0));
  const float phi = uniforms.resolutionRotation.z;
  const float theta = uniforms.resolutionRotation.w;
  const float scale = max(uniforms.scaleElevationOffset.x, 1e-4);
  const float markerElevation = uniforms.scaleElevationOffset.y;
  const float2 offset = uniforms.scaleElevationOffset.zw;
  const float2 unitPosition = positions[vertexID];

  const float3 globePosition =
    instance.positionSize.xyz * (kGlobeRadius + markerElevation);
  const float3 rotatedPosition =
    rotateWorldToView(globePosition, phi, theta);

  MarkerVertexOutput output;
  if (
    rotatedPosition.z < 0.0 &&
    length(rotatedPosition.xy) < kGlobeRadius
  ) {
    output.position = float4(2.0, 2.0, 0.0, 1.0);
  } else {
    const float inverseAspect = resolution.y / resolution.x;
    const float2 screenPosition =
      (rotatedPosition.xy +
        unitPosition * instance.positionSize.w * 2.0) *
        float2(inverseAspect, 1.0) *
        scale +
      offset * float2(1.0, -1.0) * scale / resolution;
    output.position = float4(screenPosition, 0.0, 1.0);
  }
  output.unitPosition = unitPosition;
  output.color = instance.colorAndFlag.w > 0.5
    ? instance.colorAndFlag.xyz
    : uniforms.defaultColor.xyz;
  return output;
}

fragment float4 swiftGlobeMarkerFragment(
  MarkerVertexOutput input [[stage_in]]
) {
  const float radialDistance = length(input.unitPosition);
  const float edgeWidth = max(fwidth(radialDistance), 1e-3);
  const float coverage =
    1.0 - smoothstep(0.25 - edgeWidth, 0.25, radialDistance);
  if (coverage <= 0.0) {
    discard_fragment();
  }
  return float4(input.color, coverage);
}

} // namespace swift_globe
