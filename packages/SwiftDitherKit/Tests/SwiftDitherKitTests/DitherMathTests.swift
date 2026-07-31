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

@Test func tooltipStaysInsideAChartDrawnToItsOwnEdges() {
  // A plot with no margins of its own: nothing around it absorbs an overhang.
  let width: CGFloat = 390
  let bubble: CGFloat = 200

  let atLeftEdge = DitherGeometry.tooltipCenterX(
    markX: 0, containerWidth: width, tooltipWidth: bubble)
  #expect(atLeftEdge - bubble / 2 >= 8)
  let atRightEdge = DitherGeometry.tooltipCenterX(
    markX: width, containerWidth: width, tooltipWidth: bubble)
  #expect(atRightEdge + bubble / 2 <= width - 8)
  // Mid-plot marks are not nudged.
  #expect(
    DitherGeometry.tooltipCenterX(markX: 195, containerWidth: width, tooltipWidth: bubble) == 195)
  // Wider than its container: centered rather than hung off one edge.
  #expect(DitherGeometry.tooltipCenterX(markX: 0, containerWidth: 100, tooltipWidth: 200) == 50)
}

@Test func tooltipFlipsBelowAMarkWithNoRoomAboveIt() {
  let height: CGFloat = 280
  let bubble: CGFloat = 52

  // Room above: the bubble keeps its preferred placement, clear of the finger.
  let clearOfTheTop = DitherGeometry.tooltipCenterY(
    markY: 200, containerHeight: height, tooltipHeight: bubble)
  #expect(clearOfTheTop == 200 - 12 - bubble / 2)

  // A peak at the very top of the plot: above would overflow the chart, so the
  // bubble goes under the mark instead.
  let atTop = DitherGeometry.tooltipCenterY(
    markY: 0, containerHeight: height, tooltipHeight: bubble)
  #expect(atTop == 12 + bubble / 2)
  #expect(atTop - bubble / 2 >= 8)

  // Neither placement fits: centered instead of overflowing either end.
  #expect(DitherGeometry.tooltipCenterY(markY: 0, containerHeight: 40, tooltipHeight: 60) == 20)
}
