import SwiftUI

struct DitherLegendEntry: Identifiable, Hashable {
  let id: String
  let label: String
  let color: DitherColor
}

struct DitherLegend: View {
  let entries: [DitherLegendEntry]
  let selectedID: String?
  let onSelect: (String) -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      DitherLegendRow(entries: entries, selectedID: selectedID, onSelect: onSelect)
      ScrollView(.horizontal) {
        DitherLegendRow(entries: entries, selectedID: selectedID, onSelect: onSelect)
          .padding(.horizontal, 2)
      }
      .scrollIndicators(.hidden)
    }
    .frame(minHeight: 44)
  }
}

private struct DitherLegendRow: View {
  let entries: [DitherLegendEntry]
  let selectedID: String?
  let onSelect: (String) -> Void

  var body: some View {
    HStack(spacing: 8) {
      ForEach(entries) { entry in
        Button {
          onSelect(entry.id)
        } label: {
          HStack(spacing: 5) {
            DitherLegendSwatch(color: entry.color)
            Text(verbatim: entry.label)
              .lineLimit(1)
          }
          .font(.caption)
          .foregroundStyle(.primary)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(
            selectedID == nil || selectedID == entry.id
              ? Color.primary.opacity(0.07)
              : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
          )
          .opacity(selectedID == nil || selectedID == entry.id ? 1 : 0.45)
          .frame(minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(DitherLegendButtonStyle())
        .accessibilityLabel(
          Text(selectedID == entry.id ? "Deselect \(entry.label)" : "Select \(entry.label)")
        )
        .accessibilityValue(Text(selectedID == entry.id ? "Selected" : "Not selected"))
        .accessibilityAddTraits(selectedID == entry.id ? .isSelected : [])
      }
    }
    .animation(DitherMotion.feedback, value: selectedID)
  }
}

private struct DitherLegendButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .animation(reduceMotion ? nil : DitherMotion.feedback, value: configuration.isPressed)
  }
}

private struct DitherLegendSwatch: View {
  let color: DitherColor

  var body: some View {
    Canvas { context, size in
      let cell = min(size.width, size.height) / 4
      let fill = Color(dither: color)
      for y in 0..<4 {
        for x in 0..<4 {
          let opacity = DitherKernel.threshold(x: x, y: y) < 0.58 ? 1.0 : 0.28
          let rect = CGRect(
            x: CGFloat(x) * cell,
            y: CGFloat(y) * cell,
            width: ceil(cell),
            height: ceil(cell)
          )
          context.fill(Path(rect), with: .color(fill.opacity(opacity)))
        }
      }
    }
    .frame(width: 14, height: 14)
    .accessibilityHidden(true)
  }
}

struct DitherTooltipItem: Identifiable, Hashable {
  let id: String
  let label: String
  let value: Double
  let color: DitherColor
}

struct DitherTooltipSizeKey: PreferenceKey {
  static let defaultValue: CGSize = .zero
  static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
    value = nextValue()
  }
}

struct DitherTooltip: View {
  let heading: String
  let items: [DitherTooltipItem]
  let valueFormat: DitherValueFormat
  let locale: Locale

  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: heading)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .contentTransition(.opacity)
      ForEach(items) { item in
        HStack(spacing: 6) {
          Rectangle()
            .fill(Color(dither: item.color))
            .frame(width: 7, height: 7)
          Text(verbatim: item.label)
            .lineLimit(1)
          Spacer(minLength: 10)
          Text(verbatim: valueFormat.string(item.value, locale: locale))
            .monospacedDigit()
            .contentTransition(
              reduceMotion ? .opacity : .numericText(value: item.value)
            )
        }
        .font(.caption)
      }
    }
    .padding(8)
    .frame(minWidth: 156, maxWidth: 220, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .modifier(
      DitherTooltipSurface(shape: shape, reduceTransparency: reduceTransparency)
    )
    .background {
      GeometryReader { geo in
        Color.clear.preference(key: DitherTooltipSizeKey.self, value: geo.size)
      }
    }
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)
  }
}

/// Prefers Liquid Glass on platforms that ship it; keeps the upstream material
/// chrome everywhere else (and when Reduce Transparency is on).
private struct DitherTooltipSurface: ViewModifier {
  let shape: RoundedRectangle
  let reduceTransparency: Bool

  func body(content: Content) -> some View {
    if reduceTransparency {
      content.background(.regularMaterial, in: shape)
    } else {
      #if os(iOS) || os(macOS)
        if #available(iOS 26.0, macOS 26.0, *) {
          content.glassEffect(.regular, in: shape)
        } else {
          materialChrome(content)
        }
      #else
        materialChrome(content)
      #endif
    }
  }

  @ViewBuilder
  private func materialChrome(_ content: Content) -> some View {
    content
      .background(.regularMaterial, in: shape)
      .overlay {
        shape.stroke(Color.primary.opacity(0.12), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
  }
}

private struct DitherAxisTick: Identifiable {
  let id: Int
  let value: Double
}

private struct DitherXAxisDatum: Identifiable {
  let id: String
  let index: Int
  let label: String
}

struct DitherCartesianChrome: View {
  let data: [DitherDatum]
  let kind: DitherChartKind
  let scale: DitherLinearScale
  let plotRect: CGRect
  let valueFormat: DitherValueFormat
  let locale: Locale

  var body: some View {
    ZStack(alignment: .topLeading) {
      DitherGrid(dataCount: data.count, kind: kind, plotRect: plotRect)
      ForEach(axisTicks) { tick in
        Text(verbatim: valueFormat.string(tick.value, locale: locale))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .contentTransition(.numericText(value: tick.value))
          .animation(DitherMotion.update, value: tick.value)
          .frame(width: max(0, plotRect.minX - 6), alignment: .trailing)
          .position(
            x: max(0, plotRect.minX - 6) / 2,
            y: plotRect.minY + scale.y(for: tick.value)
          )
      }
      ForEach(xAxisDatums) { item in
        Text(verbatim: item.label)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .position(
            x: plotRect.minX + xPosition(for: item.index),
            y: plotRect.maxY + 12
          )
      }
    }
    .accessibilityHidden(true)
  }

  private var axisTicks: [DitherAxisTick] {
    scale.ticks().enumerated().map { index, value in
      DitherAxisTick(id: index, value: value)
    }
  }

  private var xAxisDatums: [DitherXAxisDatum] {
    guard !data.isEmpty else { return [] }
    let indices: [Int]
    if data.count <= 6 {
      indices = Array(data.indices)
    } else {
      indices = [0, data.count / 2, data.count - 1]
    }
    return indices.map { index in
      DitherXAxisDatum(id: data[index].id, index: index, label: data[index].label)
    }
  }

  private func xPosition(for index: Int) -> CGFloat {
    if kind == .bar {
      let band = DitherGeometry.barBand(index: index, count: data.count, width: plotRect.width)
      return band.x + band.width / 2
    }
    return DitherGeometry.xCenter(index: index, count: data.count, width: plotRect.width)
  }
}

private struct DitherGrid: View {
  let dataCount: Int
  let kind: DitherChartKind
  let plotRect: CGRect

  var body: some View {
    Canvas { context, _ in
      let stroke = GraphicsContext.Shading.color(Color.secondary.opacity(0.16))
      for index in 0...4 {
        let y = plotRect.minY + CGFloat(index) / 4 * plotRect.height
        var path = Path()
        path.move(to: CGPoint(x: plotRect.minX, y: y))
        path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
        context.stroke(path, with: stroke, lineWidth: 0.75)
      }
      guard dataCount > 0 else { return }
      let verticalCount = min(dataCount, 8)
      for index in 0..<verticalCount {
        let sourceIndex =
          verticalCount == 1
          ? 0
          : Int((Double(index) / Double(verticalCount - 1) * Double(dataCount - 1)).rounded())
        let x: CGFloat
        if kind == .bar {
          let band = DitherGeometry.barBand(
            index: sourceIndex,
            count: dataCount,
            width: plotRect.width
          )
          x = plotRect.minX + band.x + band.width / 2
        } else {
          x =
            plotRect.minX
            + DitherGeometry.xCenter(
              index: sourceIndex,
              count: dataCount,
              width: plotRect.width
            )
        }
        var path = Path()
        path.move(to: CGPoint(x: x, y: plotRect.minY))
        path.addLine(to: CGPoint(x: x, y: plotRect.maxY))
        context.stroke(path, with: stroke, lineWidth: 0.5)
      }
    }
  }
}

extension Color {
  public init(dither color: DitherColor) {
    self.init(
      red: color.red,
      green: color.green,
      blue: color.blue
    )
  }
}
