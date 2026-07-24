import Accessibility
import Foundation
import SwiftUI

struct DitherRadarChartDescriptor: AXChartDescriptorRepresentable {
  let data: [DitherDatum]
  let series: [DitherSeries]
  let selectedSeriesID: String?
  let valueFormat: DitherValueFormat
  let accessibility: DitherAccessibility
  let locale: Locale

  func makeChartDescriptor() -> AXChartDescriptor {
    let upperBound = max(
      1,
      series.flatMap { item in data.map { max(0, $0[item.id]) } }.max() ?? 0
    )
    let categoryAxis = AXCategoricalDataAxisDescriptor(
      title: accessibility.categoryAxisLabel ?? "Axis",
      categoryOrder: data.map(\.label)
    )
    let valueAxis = AXNumericDataAxisDescriptor(
      title: accessibility.valueAxisLabel ?? "Value",
      range: 0...upperBound,
      gridlinePositions: []
    ) { value in
      valueFormat.string(value, locale: locale)
    }
    let accessibleSeries = series.map { item in
      AXDataSeriesDescriptor(
        name: item.label,
        isContinuous: true,
        dataPoints: data.map { datum in
          AXDataPoint(
            x: datum.label,
            y: max(0, datum[item.id]),
            label: datum.label
          )
        }
      )
    }
    let descriptor = AXChartDescriptor(
      title: accessibility.title ?? "Radar chart",
      summary: accessibility.summary ?? defaultSummary,
      xAxis: categoryAxis,
      yAxis: valueAxis,
      additionalAxes: [],
      series: accessibleSeries
    )
    descriptor.contentDirection = .radialClockwise
    return descriptor
  }

  private var defaultSummary: String {
    let base = "\(data.count) axes across \(series.count) series."
    guard let selectedSeriesID,
      let selected = series.first(where: { $0.id == selectedSeriesID })
    else {
      return base
    }
    return "\(base) \(selected.label) is selected."
  }
}
