import CoreGraphics
import Foundation

struct DitherCartesianRenderInput: Hashable, Sendable {
  let kind: DitherChartKind
  let data: [DitherDatum]
  let series: [DitherSeries]
  let stacking: DitherStacking
  let size: CGSize
  let selectedSeriesID: String?
  let hoverIndex: Int?
  let highlighted: Bool
  let valueCeiling: Double?

  init(
    kind: DitherChartKind,
    data: [DitherDatum],
    series: [DitherSeries],
    stacking: DitherStacking,
    size: CGSize,
    selectedSeriesID: String?,
    hoverIndex: Int?,
    highlighted: Bool,
    valueCeiling: Double? = nil
  ) {
    self.kind = kind
    self.data = data
    self.series = series
    self.stacking = stacking
    self.size = size
    self.selectedSeriesID = selectedSeriesID
    self.hoverIndex = hoverIndex
    self.highlighted = highlighted
    self.valueCeiling = valueCeiling
  }
}

struct DitherPieRenderInput: Hashable, Sendable {
  let slices: [DitherSlice]
  let size: CGSize
  let innerRadiusRatio: Double
  let selectedSliceID: String?
  let hoverIndex: Int?
  let highlighted: Bool
}

struct DitherRadarRenderInput: Hashable, Sendable {
  let data: [DitherDatum]
  let series: [DitherSeries]
  let size: CGSize
  let selectedSeriesID: String?
  let hoverAxisIndex: Int?
  let highlighted: Bool
}

enum DitherRenderer {
  static func cartesian(_ input: DitherCartesianRenderInput) -> DitherRaster {
    let backing = DitherKernel.backingSize(width: input.size.width, height: input.size.height)
    var raster = DitherRaster(width: backing.columns, height: backing.rows)
    guard !input.data.isEmpty, !input.series.isEmpty,
      input.size.width > 0, input.size.height > 0
    else {
      return raster
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

    switch input.kind {
    case .area, .line:
      paintContinuous(input, bands: bands, scale: scale, raster: &raster)
    case .bar:
      paintBars(input, bands: bands, scale: scale, raster: &raster)
    }
    return raster
  }

  static func pie(_ input: DitherPieRenderInput) -> DitherRaster {
    let backing = DitherKernel.backingSize(width: input.size.width, height: input.size.height)
    var raster = DitherRaster(width: backing.columns, height: backing.rows)
    guard !input.slices.isEmpty, input.size.width > 0, input.size.height > 0 else {
      return raster
    }

    let geometry = DitherPieGeometry(input.slices)
    let center = CGPoint(x: input.size.width / 2, y: input.size.height / 2)
    let outerRadius = min(input.size.width, input.size.height) * 0.43
    let innerRadius = outerRadius * CGFloat(min(0.9, max(0, input.innerRadiusRatio)))
    let intensity = input.highlighted ? 1.0 : 0.0

    for y in 0..<backing.rows {
      let pointY = (CGFloat(y) + 0.5) * input.size.height / CGFloat(backing.rows)
      for x in 0..<backing.columns {
        let pointX = (CGFloat(x) + 0.5) * input.size.width / CGFloat(backing.columns)
        let dx = pointX - center.x
        let dy = pointY - center.y
        let radius = hypot(dx, dy)
        guard radius >= innerRadius,
          let sliceIndex = geometry.index(at: atan2(Double(dy), Double(dx)))
        else {
          continue
        }

        let slice = input.slices[sliceIndex]
        let isActive = input.hoverIndex == sliceIndex
        let localOuter = outerRadius + (isActive ? 6 : 0)
        guard radius <= localOuter else { continue }

        let dim = input.selectedSliceID == nil || input.selectedSliceID == slice.id ? 1.0 : 0.3
        let localIntensity = intensity + (isActive ? 0.4 : 0)
        let color = DitherPalette.fill(for: slice.color)

        if localOuter - radius < (isActive ? 2.4 : 1.4) {
          raster.blend(color, alpha: dim, x: x, y: y)
          continue
        }

        let density = Double((radius - innerRadius) / max(localOuter - innerRadius, 1))
        let bias = slice.variant == .dotted ? 0.12 : 0
        if slice.variant == .hatched, ((x + y) & 3) >= 2 { continue }
        let lit =
          slice.variant == .solid
          || density > DitherKernel.threshold(x: x, y: y) - 0.1 * localIntensity - bias
        if slice.variant == .dotted, !lit { continue }
        let strength = (0.35 + density * 0.65) * (1 + 0.22 * localIntensity)
        let alpha = min(1, (lit ? strength : strength * DitherKernel.offTier) * dim)
        raster.blend(color, alpha: alpha, x: x, y: y)
      }
    }
    return raster
  }

  static func radar(_ input: DitherRadarRenderInput) -> DitherRaster {
    let backing = DitherKernel.backingSize(width: input.size.width, height: input.size.height)
    var raster = DitherRaster(width: backing.columns, height: backing.rows)
    guard input.data.count >= 3, !input.series.isEmpty,
      input.size.width > 0, input.size.height > 0
    else {
      return raster
    }

    let center = CGPoint(x: input.size.width / 2, y: input.size.height / 2)
    let outerRadius = min(input.size.width, input.size.height) * 0.39
    let maximum = max(
      1,
      input.series.flatMap { series in input.data.map { $0[series.id] } }.max() ?? 0
    )
    let polygons = input.series.map { series in
      let points = input.data.enumerated().map { index, datum -> CGPoint in
        let angle = -Double.pi / 2 + Double(index) / Double(input.data.count) * Double.pi * 2
        let radius = CGFloat(max(0, datum[series.id]) / maximum) * outerRadius
        return CGPoint(
          x: center.x + cos(angle) * radius,
          y: center.y + sin(angle) * radius
        )
      }
      return RadarPolygon(series: series, points: points)
    }
    let densityBand = max(outerRadius * 0.45, 1)
    let intensity = input.highlighted ? 1.0 : 0.0

    for y in 0..<backing.rows {
      let pointY = (CGFloat(y) + 0.5) * input.size.height / CGFloat(backing.rows)
      for x in 0..<backing.columns {
        let pointX = (CGFloat(x) + 0.5) * input.size.width / CGFloat(backing.columns)
        let point = CGPoint(x: pointX, y: pointY)
        var covered = false

        for (layerIndex, polygon) in polygons.enumerated() {
          guard DitherGeometry.pointInPolygon(point, polygon: polygon.points) else { continue }
          let dim =
            input.selectedSeriesID == nil || input.selectedSeriesID == polygon.series.id
            ? 1.0 : 0.3
          let color = DitherPalette.fill(for: polygon.series.color)
          let distance = DitherGeometry.distanceToPolygonEdge(point, polygon: polygon.points)
          if distance < 1.4 {
            raster.blend(color, alpha: dim, x: x, y: y)
            covered = true
            continue
          }

          let density = 1 - min(1, Double(distance / densityBand))
          let bias = polygon.series.variant == .dotted ? 0.12 : 0
          let sparse = Double(layerIndex) * 0.2
          if polygon.series.variant == .hatched, ((x + y) & 3) >= 2 { continue }
          let lit =
            polygon.series.variant == .solid
            || density > DitherKernel.threshold(x: x, y: y)
              - 0.1 * intensity - bias + sparse
          if !lit, polygon.series.variant == .dotted || covered { continue }
          let strength = (0.32 + density * 0.68) * (1 + 0.22 * intensity)
          let alpha = min(1, (lit ? strength : strength * DitherKernel.offTier) * dim)
          raster.blend(color, alpha: alpha, x: x, y: y)
          covered = true
        }
      }
    }

    let scaleX = CGFloat(backing.columns) / input.size.width
    let scaleY = CGFloat(backing.rows) / input.size.height
    for polygon in polygons {
      let dim =
        input.selectedSeriesID == nil || input.selectedSeriesID == polygon.series.id
        ? 1.0 : 0.3
      let color = DitherPalette.fill(for: polygon.series.color)
      for (index, point) in polygon.points.enumerated() {
        let x = Int((point.x * scaleX).rounded())
        let y = Int((point.y * scaleY).rounded())
        let markerRadius: Int = input.hoverAxisIndex == index ? 1 : 0
        for offsetY in -markerRadius...markerRadius {
          for offsetX in -markerRadius...markerRadius {
            raster.blend(color, alpha: dim, x: x + offsetX, y: y + offsetY)
          }
        }
      }
    }
    return raster
  }

  private static func paintContinuous(
    _ input: DitherCartesianRenderInput,
    bands: DitherBandResult,
    scale: DitherLinearScale,
    raster: inout DitherRaster
  ) {
    let rowScale = Double(raster.height - 1) / Double(max(input.size.height, 1))
    let glow = max(6, Int((Double(raster.height) * 0.16).rounded()))
    let stacked = input.stacking != .overlaid
    var tops: [String: [Double]] = [:]

    for (seriesIndex, item) in input.series.enumerated() {
      guard let seriesBands = bands.bands[item.id] else { continue }
      let sourceTop = seriesBands.map { Double(scale.y(for: $0.upper)) * rowScale }
      let sourceFloor: [Double]
      if input.kind == .line {
        sourceFloor = sourceTop.map { min(Double(raster.height - 1), $0 + Double(glow)) }
      } else if stacked {
        sourceFloor = seriesBands.map { Double(scale.y(for: $0.lower)) * rowScale }
      } else {
        // Overlaid areas rest on the value-axis baseline, which `scale.y(lower)`
        // maps onto the last valid raster row. `paintColumn` fills a half-open
        // range `topRow..<floorRow`, so that baseline row is dropped — harmless
        // under an axis, but on a flush (axis-less) sparkline it leaves a ~1px
        // transparent strip that shows the card surface through as a gap along
        // the bottom edge. Nudge the floor one row past the baseline so the fill
        // reaches the bottom; `raster.blend` clamps the out-of-range row.
        sourceFloor = seriesBands.map {
          min(Double(raster.height), Double(scale.y(for: $0.lower)) * rowScale + 1)
        }
      }
      let top = DitherGeometry.resample(sourceTop, count: raster.width)
      let floor = DitherGeometry.resample(sourceFloor, count: raster.width)
      tops[item.id] = top

      let dim = input.selectedSeriesID == nil || input.selectedSeriesID == item.id ? 1.0 : 0.3
      let sparse = stacked ? 0 : Double(seriesIndex) * 0.14
      let color = DitherPalette.fill(for: item.color)
      for x in 0..<raster.width {
        let a = top[x]
        let b = floor[x]
        DitherKernel.paintColumn(
          raster: &raster,
          x: x,
          top: min(a, b),
          floor: max(a, b),
          color: color,
          variant: item.variant,
          intensity: input.highlighted ? 1 : 0,
          dim: dim,
          stacked: stacked && input.kind != .line,
          sparse: sparse
        )
      }
    }

    guard let markerIndex = input.hoverIndex else { return }
    let markerX: Int
    if input.data.count > 1 {
      markerX = Int(
        (Double(markerIndex) / Double(input.data.count - 1) * Double(raster.width - 1)).rounded()
      )
    } else {
      markerX = raster.width / 2
    }

    for item in input.series {
      guard let top = tops[item.id], markerX >= 0, markerX < top.count else { continue }
      let markerY = Int(top[markerX].rounded())
      let color = DitherPalette.fill(for: item.color)
      for y in max(0, markerY)..<raster.height {
        raster.blend(color, alpha: 0.55, x: markerX, y: y)
      }
      for y in (markerY - 1)...(markerY + 1) {
        for x in (markerX - 1)...(markerX + 1) {
          raster.blend(color, alpha: 1, x: x, y: y)
        }
      }
    }
  }

  private static func paintBars(
    _ input: DitherCartesianRenderInput,
    bands: DitherBandResult,
    scale: DitherLinearScale,
    raster: inout DitherRaster
  ) {
    let rowScale = Double(raster.height - 1) / Double(max(input.size.height, 1))
    let columnScale = CGFloat(raster.width) / max(input.size.width, 1)
    let stacked = input.stacking != .overlaid

    for (seriesIndex, item) in input.series.enumerated() {
      guard let seriesBands = bands.bands[item.id] else { continue }
      let selectionDim =
        input.selectedSeriesID == nil || input.selectedSeriesID == item.id
        ? 1.0 : 0.3
      let color = DitherPalette.fill(for: item.color)

      for (datumIndex, band) in seriesBands.enumerated() {
        let top = Double(scale.y(for: band.upper)) * rowScale
        let base = Double(scale.y(for: band.lower)) * rowScale
        let slot = DitherGeometry.barSlot(
          datumIndex: datumIndex,
          datumCount: input.data.count,
          seriesIndex: seriesIndex,
          seriesCount: input.series.count,
          width: input.size.width,
          stacked: stacked
        )
        let firstColumn = Int((slot.x * columnScale).rounded())
        let lastColumn = Int(((slot.x + slot.width) * columnScale).rounded())
        let isActive = input.hoverIndex == datumIndex
        let hoverDim = input.hoverIndex == nil || isActive ? 1.0 : 0.5

        for x in firstColumn..<lastColumn {
          DitherKernel.paintColumn(
            raster: &raster,
            x: x,
            top: min(top, base),
            floor: max(top, base),
            color: color,
            variant: item.variant,
            intensity: (input.highlighted ? 1 : 0) + (isActive ? 0.4 : 0),
            dim: selectionDim * hoverDim,
            stacked: stacked
          )
        }
      }
    }
  }
}

private struct RadarPolygon {
  let series: DitherSeries
  let points: [CGPoint]
}
