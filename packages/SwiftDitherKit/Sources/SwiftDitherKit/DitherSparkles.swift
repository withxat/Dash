import Foundation

struct DitherSparkle: Hashable, Sendable {
  let x: Int
  let y: Int
  let phase: Int
  let color: DitherRGB
}

struct DitherSparkleField: Hashable, Sendable {
  let width: Int
  let height: Int
  let sparkles: [DitherSparkle]
  let intensity: Double

  static func empty(width: Int, height: Int) -> Self {
    Self(width: width, height: height, sparkles: [], intensity: 0)
  }

  static func cartesian(
    _ input: DitherCartesianRenderInput,
    width: Int,
    height: Int
  ) -> Self {
    guard input.kind != .bar, !input.data.isEmpty, !input.series.isEmpty,
      input.size.width > 0, input.size.height > 0, width > 0, height > 0
    else {
      return .empty(width: width, height: height)
    }

    let bands = DitherGeometry.computeBands(
      data: input.data,
      series: input.series,
      stacking: input.stacking
    )
    let scale = DitherLinearScale(
      minimum: bands.minimum,
      maximum: max(bands.maximum, input.valueCeiling ?? 0),
      height: input.size.height
    )
    let rowScale = Double(height - 1) / Double(max(input.size.height, 1))
    let glow = max(6, Int((Double(height) * 0.16).rounded()))
    let sparkleCount = max(4, Int((Double(width) / 14).rounded()))
    var sparkles: [DitherSparkle] = []
    sparkles.reserveCapacity(sparkleCount * input.series.count)

    for (seriesIndex, item) in input.series.enumerated() {
      guard let seriesBands = bands.bands[item.id] else { continue }
      let sourceTop = seriesBands.map { Double(scale.y(for: $0.upper)) * rowScale }
      let sourceFloor: [Double]
      if input.kind == .line {
        sourceFloor = sourceTop.map { min(Double(height - 1), $0 + Double(glow)) }
      } else {
        sourceFloor = seriesBands.map { Double(scale.y(for: $0.lower)) * rowScale }
      }
      let top = DitherGeometry.resample(sourceTop, count: width)
      let floor = DitherGeometry.resample(sourceFloor, count: width)
      let color = DitherPalette.fill(for: item.color)

      for index in 0..<sparkleCount {
        let seed = index * 67 + 13 + seriesIndex * 131
        let dataIndex = seed % max(input.data.count, 1)
        let x = Int(
          (Double(dataIndex) / Double(max(input.data.count - 1, 1)) * Double(width - 1))
            .rounded()
        )
        guard top.indices.contains(x), floor.indices.contains(x) else { continue }
        let depth = Double((seed * 53 + 7) % 100) / 100
        let y = Int((top[x] + depth * (floor[x] - top[x])).rounded())
        sparkles.append(
          DitherSparkle(
            x: x,
            y: y,
            phase: (seed * 41) % 360,
            color: color
          )
        )
      }
    }

    return Self(
      width: width,
      height: height,
      sparkles: sparkles,
      intensity: input.highlighted ? 1 : 0
    )
  }

  func combiningChecksum(_ seed: UInt64) -> UInt64 {
    guard !sparkles.isEmpty else { return seed }
    var checksum = seed
    let prime: UInt64 = 1_099_511_628_211

    func mix(_ value: UInt64) {
      checksum = (checksum ^ value) &* prime
    }

    mix(UInt64(width))
    mix(UInt64(height))
    mix(intensity.bitPattern)
    for sparkle in sparkles {
      mix(UInt64(bitPattern: Int64(sparkle.x)))
      mix(UInt64(bitPattern: Int64(sparkle.y)))
      mix(UInt64(sparkle.phase))
      mix(UInt64(sparkle.color.red))
      mix(UInt64(sparkle.color.green))
      mix(UInt64(sparkle.color.blue))
    }
    return checksum
  }
}

struct DitherSparkleSample: Equatable, Sendable {
  let centerAlpha: Double
  let flareAlpha: Double
  let isVisible: Bool
}

enum DitherSparkleMotion {
  static let tickInterval: TimeInterval = 0.1
  static let steadyTwinkle = 0.85
  static let minimumVisibleAlpha = 0.55

  static func tick(at date: Date) -> Int {
    max(0, Int((date.timeIntervalSinceReferenceDate / tickInterval).rounded(.down)))
  }

  static func sample(
    tick: Int,
    phase: Int,
    intensity: Double,
    reduceMotion: Bool
  ) -> DitherSparkleSample {
    let twinkle =
      reduceMotion
      ? steadyTwinkle
      : (sin(Double(tick + phase) * 0.35) + 1) / 2
    let clampedIntensity = min(1, max(0, intensity))
    let lift = twinkle * (0.7 + 0.3 * clampedIntensity)
    let flare =
      twinkle > 0.9
      ? lift * 0.6 * (twinkle - 0.9) * 10
      : 0
    return DitherSparkleSample(
      centerAlpha: lift,
      flareAlpha: flare,
      isVisible: lift >= minimumVisibleAlpha
    )
  }
}
