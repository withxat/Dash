import CoreGraphics
import Testing

@testable import SwiftDitherKit

@Test func colorComponentsClampAndNonFiniteValuesBecomeZero() {
  let color = DitherColor(red: -1, green: 2, blue: .nan)
  #expect(color.red == 0)
  #expect(color.green == 1)
  #expect(color.blue == 0)

  let datum = DitherDatum(
    id: "day", label: "Day",
    values: ["finite": 4, "nan": .nan, "infinite": .infinity])
  #expect(datum["finite"] == 4)
  #expect(datum["nan"] == 0)
  #expect(datum["infinite"] == 0)
  #expect(datum["missing"] == 0)
}

@Test func percentStackingNormalizesPositiveAndNegativeBandsIndependently() throws {
  let series = [
    DitherSeries(id: "first", color: .blue),
    DitherSeries(id: "second", color: .green),
  ]
  let data = [
    DitherDatum(id: "mixed", label: "Mixed", values: ["first": 3, "second": -2])
  ]

  let result = DitherGeometry.computeBands(data: data, series: series, stacking: .percent)
  #expect(result.minimum == -1)
  #expect(result.maximum == 1)
  #expect(try #require(result.bands["first"]?.first) == DitherBand(lower: 0, upper: 1))
  #expect(try #require(result.bands["second"]?.first) == DitherBand(lower: 0, upper: -1))
}

@Test func hitTestingClampsChartEdgesAndResamplingKeepsEndpoints() {
  #expect(DitherGeometry.nearestIndex(x: -20, count: 5, width: 100) == 0)
  #expect(DitherGeometry.nearestIndex(x: 120, count: 5, width: 100) == 4)
  #expect(DitherGeometry.bandIndex(x: 100, count: 5, width: 100) == 4)

  let resampled = DitherGeometry.resample([0, 10], count: 5)
  #expect(resampled == [0, 2.5, 5, 7.5, 10])

  let square = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 10, y: 0),
    CGPoint(x: 10, y: 10),
    CGPoint(x: 0, y: 10),
  ]
  #expect(DitherGeometry.pointInPolygon(CGPoint(x: 5, y: 5), polygon: square))
  #expect(!DitherGeometry.pointInPolygon(CGPoint(x: 15, y: 5), polygon: square))
}
