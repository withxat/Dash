import Accessibility
import Foundation
import SwiftUI

struct DitherPieChartDescriptor: AXChartDescriptorRepresentable {
  let slices: [DitherSlice]
  let selectedSliceID: String?
  let valueFormat: DitherValueFormat
  let accessibility: DitherAccessibility
  let locale: Locale

  func makeChartDescriptor() -> AXChartDescriptor {
    let upperBound = max(1, slices.map { max(0, $0.value) }.max() ?? 0)
    let categoryAxis = AXCategoricalDataAxisDescriptor(
      title: accessibility.categoryAxisLabel ?? "Slice",
      categoryOrder: slices.map(\.label)
    )
    let valueAxis = AXNumericDataAxisDescriptor(
      title: accessibility.valueAxisLabel ?? "Value",
      range: 0...upperBound,
      gridlinePositions: []
    ) { value in
      valueFormat.string(value, locale: locale)
    }
    let dataPoints = slices.map { slice in
      AXDataPoint(
        x: slice.label,
        y: max(0, slice.value),
        label: slice.label
      )
    }
    let series = AXDataSeriesDescriptor(
      name: accessibility.title ?? "Slices",
      isContinuous: false,
      dataPoints: dataPoints
    )
    let descriptor = AXChartDescriptor(
      title: accessibility.title ?? "Pie chart",
      summary: accessibility.summary ?? defaultSummary,
      xAxis: categoryAxis,
      yAxis: valueAxis,
      additionalAxes: [],
      series: [series]
    )
    descriptor.contentDirection = .radialClockwise
    return descriptor
  }

  private var defaultSummary: String {
    let base = "\(slices.count) slices."
    guard let selectedSliceID,
      let selected = slices.first(where: { $0.id == selectedSliceID })
    else {
      return base
    }
    return "\(base) \(selected.label) is selected."
  }
}
