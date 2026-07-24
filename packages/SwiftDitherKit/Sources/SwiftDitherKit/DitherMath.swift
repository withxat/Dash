import CoreGraphics
import Foundation

struct DitherBand: Equatable, Sendable {
  let lower: Double
  let upper: Double
}

struct DitherBandResult: Equatable, Sendable {
  let bands: [String: [DitherBand]]
  let minimum: Double
  let maximum: Double
}

enum DitherGeometry {
  static func computeBands(
    data: [DitherDatum],
    series: [DitherSeries],
    stacking: DitherStacking
  ) -> DitherBandResult {
    switch stacking {
    case .overlaid:
      return overlaidBands(data: data, series: series)
    case .stacked, .percent:
      return stackedBands(data: data, series: series, normalized: stacking == .percent)
    }
  }

  static func nearestIndex(x: CGFloat, count: Int, width: CGFloat) -> Int {
    guard count > 1, width > 0 else { return 0 }
    let fraction = min(1, max(0, x / width))
    return min(count - 1, max(0, Int((fraction * CGFloat(count - 1)).rounded())))
  }

  static func bandIndex(x: CGFloat, count: Int, width: CGFloat) -> Int {
    guard count > 0, width > 0 else { return 0 }
    let fraction = min(0.999_999, max(0, x / width))
    return min(count - 1, max(0, Int(fraction * CGFloat(count))))
  }

  static func xCenter(index: Int, count: Int, width: CGFloat) -> CGFloat {
    guard count > 1 else { return width / 2 }
    return CGFloat(index) / CGFloat(count - 1) * width
  }

  static func barBand(index: Int, count: Int, width: CGFloat) -> (x: CGFloat, width: CGFloat) {
    guard count > 0, width > 0 else { return (0, 0) }
    let innerPadding: CGFloat = 0.28
    let outerPadding: CGFloat = 0.18
    let step = width / max(1, CGFloat(count) - innerPadding + outerPadding * 2)
    let bandwidth = step * (1 - innerPadding)
    let occupied = step * (CGFloat(count) - innerPadding)
    let start = (width - occupied) / 2
    return (start + CGFloat(index) * step, bandwidth)
  }

  static func barSlot(
    datumIndex: Int,
    datumCount: Int,
    seriesIndex: Int,
    seriesCount: Int,
    width: CGFloat,
    stacked: Bool
  ) -> (x: CGFloat, width: CGFloat) {
    let band = barBand(index: datumIndex, count: datumCount, width: width)
    if stacked {
      let slotWidth = band.width * 0.9
      return (band.x + (band.width - slotWidth) / 2, slotWidth)
    }
    let subdivision = band.width / CGFloat(max(seriesCount, 1))
    return (
      band.x + CGFloat(seriesIndex) * subdivision + subdivision * 0.08,
      subdivision * 0.84
    )
  }

  static func resample(_ source: [Double], count: Int) -> [Double] {
    guard count > 0 else { return [] }
    guard !source.isEmpty else { return Array(repeating: 0, count: count) }
    guard source.count > 1, count > 1 else {
      return Array(repeating: source[0], count: count)
    }

    let last = Double(source.count - 1)
    return (0..<count).map { outputIndex in
      let position = Double(outputIndex) / Double(count - 1) * last
      let lowerIndex = Int(position.rounded(.down))
      let fraction = position - Double(lowerIndex)
      let upperIndex = min(source.count - 1, lowerIndex + 1)
      return source[lowerIndex] + (source[upperIndex] - source[lowerIndex]) * fraction
    }
  }

  static func pointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
    guard polygon.count >= 3 else { return false }
    var inside = false
    var previous = polygon.count - 1
    for index in polygon.indices {
      let currentPoint = polygon[index]
      let previousPoint = polygon[previous]
      if (currentPoint.y > point.y) != (previousPoint.y > point.y) {
        let denominator = previousPoint.y - currentPoint.y
        let crossingX =
          (previousPoint.x - currentPoint.x) * (point.y - currentPoint.y)
          / (denominator == 0 ? 1 : denominator) + currentPoint.x
        if point.x < crossingX { inside.toggle() }
      }
      previous = index
    }
    return inside
  }

  static func distanceToPolygonEdge(_ point: CGPoint, polygon: [CGPoint]) -> CGFloat {
    guard polygon.count >= 2 else { return .infinity }
    var best = CGFloat.infinity
    var previous = polygon.count - 1
    for index in polygon.indices {
      let a = polygon[previous]
      let b = polygon[index]
      let dx = b.x - a.x
      let dy = b.y - a.y
      let lengthSquared = max(dx * dx + dy * dy, 1)
      let raw = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
      let t = min(1, max(0, raw))
      let edge = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
      best = min(best, hypot(edge.x - point.x, edge.y - point.y))
      previous = index
    }
    return best
  }

  static func normalizedAngle(_ angle: Double) -> Double {
    let top = -Double.pi / 2
    let turn = Double.pi * 2
    var normalized = angle
    while normalized < top { normalized += turn }
    while normalized >= top + turn { normalized -= turn }
    return normalized
  }

  private static func overlaidBands(
    data: [DitherDatum],
    series: [DitherSeries]
  ) -> DitherBandResult {
    var output: [String: [DitherBand]] = [:]
    var minimum = 0.0
    var maximum = 0.0

    for item in series {
      let values = data.map { datum in
        let value = datum[item.id]
        minimum = min(minimum, value)
        maximum = max(maximum, value)
        return DitherBand(lower: 0, upper: value)
      }
      output[item.id] = values
    }

    if minimum == 0, maximum == 0 { maximum = 1 }
    return DitherBandResult(bands: output, minimum: minimum, maximum: maximum)
  }

  private static func stackedBands(
    data: [DitherDatum],
    series: [DitherSeries],
    normalized: Bool
  ) -> DitherBandResult {
    var output: [String: [DitherBand]] = [:]
    for item in series {
      output[item.id] = []
    }
    var minimum = 0.0
    var maximum = 0.0

    for datum in data {
      let rawValues = series.map { datum[$0.id] }
      let positiveTotal = rawValues.reduce(0) { $0 + max(0, $1) }
      let negativeTotal = rawValues.reduce(0) { $0 + abs(min(0, $1)) }
      var positive = 0.0
      var negative = 0.0

      for (index, item) in series.enumerated() {
        let rawValue = rawValues[index]
        let value: Double
        if normalized, rawValue >= 0 {
          value = positiveTotal > 0 ? rawValue / positiveTotal : 0
        } else if normalized {
          value = negativeTotal > 0 ? rawValue / negativeTotal : 0
        } else {
          value = rawValue
        }

        let band: DitherBand
        if value >= 0 {
          band = DitherBand(lower: positive, upper: positive + value)
          positive += value
        } else {
          band = DitherBand(lower: negative, upper: negative + value)
          negative += value
        }
        output[item.id, default: []].append(band)
      }
      minimum = min(minimum, negative)
      maximum = max(maximum, positive)
    }

    if minimum == 0, maximum == 0 { maximum = 1 }
    return DitherBandResult(bands: output, minimum: minimum, maximum: maximum)
  }
}

enum DitherSelectionHitTester {
  static func seriesID(
    at location: CGPoint,
    kind: DitherChartKind,
    data: [DitherDatum],
    series: [DitherSeries],
    stacking: DitherStacking,
    size: CGSize
  ) -> String? {
    guard !data.isEmpty, !series.isEmpty, size.width > 0, size.height > 0,
      location.x >= 0, location.x <= size.width,
      location.y >= 0, location.y <= size.height
    else {
      return nil
    }

    let bands = DitherGeometry.computeBands(data: data, series: series, stacking: stacking)
    let scale = DitherLinearScale(
      minimum: bands.minimum,
      maximum: bands.maximum,
      height: size.height
    )

    switch kind {
    case .area, .line:
      return continuousSeriesID(
        at: location,
        dataCount: data.count,
        series: series,
        bands: bands,
        scale: scale,
        width: size.width
      )
    case .bar:
      return barSeriesID(
        at: location,
        dataCount: data.count,
        series: series,
        bands: bands,
        scale: scale,
        stacking: stacking,
        width: size.width
      )
    }
  }

  private static func continuousSeriesID(
    at location: CGPoint,
    dataCount: Int,
    series: [DitherSeries],
    bands: DitherBandResult,
    scale: DitherLinearScale,
    width: CGFloat
  ) -> String? {
    let position =
      dataCount > 1
      ? Double(min(1, max(0, location.x / width))) * Double(dataCount - 1)
      : 0
    let lowerIndex = min(dataCount - 1, max(0, Int(position.rounded(.down))))
    let upperIndex = min(dataCount - 1, lowerIndex + 1)
    let fraction = position - Double(lowerIndex)

    for item in series.reversed() {
      guard let itemBands = bands.bands[item.id],
        itemBands.indices.contains(lowerIndex), itemBands.indices.contains(upperIndex)
      else {
        continue
      }
      let lower = interpolate(
        itemBands[lowerIndex].lower,
        itemBands[upperIndex].lower,
        fraction: fraction
      )
      let upper = interpolate(
        itemBands[lowerIndex].upper,
        itemBands[upperIndex].upper,
        fraction: fraction
      )
      let firstY = scale.y(for: lower)
      let secondY = scale.y(for: upper)
      if location.y >= min(firstY, secondY), location.y <= max(firstY, secondY) {
        return item.id
      }
    }
    return nil
  }

  private static func barSeriesID(
    at location: CGPoint,
    dataCount: Int,
    series: [DitherSeries],
    bands: DitherBandResult,
    scale: DitherLinearScale,
    stacking: DitherStacking,
    width: CGFloat
  ) -> String? {
    let stacked = stacking != .overlaid
    for (seriesIndex, item) in series.enumerated().reversed() {
      guard let itemBands = bands.bands[item.id] else { continue }
      for datumIndex in 0..<min(dataCount, itemBands.count) {
        let slot = DitherGeometry.barSlot(
          datumIndex: datumIndex,
          datumCount: dataCount,
          seriesIndex: seriesIndex,
          seriesCount: series.count,
          width: width,
          stacked: stacked
        )
        guard location.x >= slot.x, location.x <= slot.x + slot.width else { continue }

        let firstY = scale.y(for: itemBands[datumIndex].lower)
        let secondY = scale.y(for: itemBands[datumIndex].upper)
        guard abs(firstY - secondY) > 0.5 else { continue }
        if location.y >= min(firstY, secondY), location.y <= max(firstY, secondY) {
          return item.id
        }
      }
    }
    return nil
  }

  private static func interpolate(_ first: Double, _ second: Double, fraction: Double) -> Double {
    first + (second - first) * fraction
  }
}

struct DitherLinearScale: Equatable, Sendable {
  let lowerBound: Double
  let upperBound: Double
  let height: CGFloat

  init(minimum: Double, maximum: Double, height: CGFloat, tickCount: Int = 4) {
    var lower = min(0, minimum)
    var upper = max(0, maximum)
    if lower == upper { upper = lower + 1 }

    let roughStep = (upper - lower) / Double(max(tickCount, 1))
    let step = Self.niceNumber(roughStep)
    lower = floor(lower / step) * step
    upper = ceil(upper / step) * step
    if lower == upper { upper = lower + step }

    self.lowerBound = lower
    self.upperBound = upper
    self.height = max(0, height)
  }

  func y(for value: Double) -> CGFloat {
    let fraction = (value - lowerBound) / (upperBound - lowerBound)
    return height * CGFloat(1 - fraction)
  }

  func ticks(count: Int = 4) -> [Double] {
    guard count > 0 else { return [lowerBound] }
    return (0...count).map { index in
      lowerBound + Double(index) / Double(count) * (upperBound - lowerBound)
    }.reversed()
  }

  private static func niceNumber(_ value: Double) -> Double {
    guard value.isFinite, value > 0 else { return 1 }
    let exponent = floor(log10(value))
    let fraction = value / pow(10, exponent)
    let niceFraction: Double
    if fraction <= 1 {
      niceFraction = 1
    } else if fraction <= 2 {
      niceFraction = 2
    } else if fraction <= 5 {
      niceFraction = 5
    } else {
      niceFraction = 10
    }
    return niceFraction * pow(10, exponent)
  }
}

struct DitherPieGeometry: Equatable, Sendable {
  struct Slice: Equatable, Sendable {
    let id: String
    let start: Double
    let end: Double
    let middle: Double
  }

  let slices: [Slice]

  init(_ input: [DitherSlice]) {
    let top = -Double.pi / 2
    let turn = Double.pi * 2
    let values = input.map { max(0, $0.value.isFinite ? $0.value : 0) }
    let total = values.reduce(0, +)
    let denominator = total > 0 ? total : 1
    var angle = top
    slices = zip(input, values).map { slice, value in
      let span = value / denominator * turn
      defer { angle += span }
      return Slice(id: slice.id, start: angle, end: angle + span, middle: angle + span / 2)
    }
  }

  func index(at angle: Double) -> Int? {
    let normalized = DitherGeometry.normalizedAngle(angle)
    return slices.firstIndex { normalized >= $0.start && normalized < $0.end }
  }
}
