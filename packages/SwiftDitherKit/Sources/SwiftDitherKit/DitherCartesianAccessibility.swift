import Accessibility
import Foundation
import SwiftUI

struct DitherCartesianChartDescriptor: AXChartDescriptorRepresentable {
  let kind: DitherChartKind
  let data: [DitherDatum]
  let series: [DitherSeries]
  let stacking: DitherStacking
  let selectedSeriesID: String?
  let valueFormat: DitherValueFormat
  let accessibility: DitherAccessibility
  let locale: Locale

  func makeChartDescriptor() -> AXChartDescriptor {
    let bands = DitherGeometry.computeBands(data: data, series: series, stacking: stacking)
    let scale = DitherLinearScale(minimum: bands.minimum, maximum: bands.maximum, height: 1)
    let categoryAxis = AXCategoricalDataAxisDescriptor(
      title: accessibility.categoryAxisLabel ?? "Category",
      categoryOrder: data.map(\.label)
    )
    let valueAxis = AXNumericDataAxisDescriptor(
      title: accessibility.valueAxisLabel ?? "Value",
      range: scale.lowerBound...scale.upperBound,
      gridlinePositions: scale.ticks()
    ) { value in
      valueFormat.string(value, locale: locale)
    }
    let accessibleSeries = series.map { item in
      AXDataSeriesDescriptor(
        name: item.label,
        isContinuous: kind != .bar,
        dataPoints: data.map { datum in
          AXDataPoint(
            x: datum.label,
            y: datum[item.id],
            label: datum.label
          )
        }
      )
    }
    let descriptor = AXChartDescriptor(
      title: accessibility.title ?? defaultTitle,
      summary: accessibility.summary ?? defaultSummary,
      xAxis: categoryAxis,
      yAxis: valueAxis,
      additionalAxes: [],
      series: accessibleSeries
    )
    descriptor.contentDirection = .leftToRight
    return descriptor
  }

  private var defaultTitle: String {
    switch kind {
    case .area: "Area chart"
    case .line: "Line chart"
    case .bar: "Bar chart"
    }
  }

  private var defaultSummary: String {
    let base = "\(data.count) categories across \(series.count) series."
    guard let selectedSeriesID,
      let selected = series.first(where: { $0.id == selectedSeriesID })
    else {
      return base
    }
    return "\(base) \(selected.label) is selected."
  }
}
