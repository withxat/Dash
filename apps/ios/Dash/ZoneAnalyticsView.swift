import Charts
import CloudflareAPI
import SwiftUI

/// A single normalized point for the chart, independent of whether it came
/// from the hourly or daily dataset.
struct ZoneAnalyticsChartPoint: Identifiable, Hashable {
  let date: Date
  let requests: Int
  let threats: Int
  let bytes: Int64
  let pageViews: Int

  var id: Date { date }
}

/// Pure conversion + parsing, so the date handling is unit-tested away from
/// the view. Both builders return ascending, dropping unparseable stamps.
enum ZoneAnalyticsChartModel {
  private static let dayParser: DateFormatter = {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone(identifier: "UTC")
    return parser
  }()

  static func chartAccessibilitySummary(rangeLabel: String, requests: Int, threats: Int) -> String {
    var summary =
      "Requests chart for \(rangeLabel). Total \(requests.formatted()) requests"
    if threats > 0 {
      summary += ", \(threats.formatted()) threats"
    }
    return summary + "."
  }
  static func points(fromDaily days: [ZoneAnalyticsDay]) -> [ZoneAnalyticsChartPoint] {
    days.compactMap { day in
      guard let date = dayParser.date(from: day.date) else { return nil }
      return ZoneAnalyticsChartPoint(
        date: date, requests: day.requests, threats: day.threats, bytes: day.bytes,
        pageViews: day.pageViews)
    }
    .sorted { $0.date < $1.date }
  }

  static func points(fromHourly hourly: [ZoneAnalyticsPoint]) -> [ZoneAnalyticsChartPoint] {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime]
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return hourly.compactMap { point in
      guard let date = parser.date(from: point.datetime) ?? fractional.date(from: point.datetime)
      else { return nil }
      return ZoneAnalyticsChartPoint(
        date: date, requests: point.requests, threats: point.threats, bytes: point.bytes,
        pageViews: point.pageViews)
    }
    .sorted { $0.date < $1.date }
  }
}

enum AnalyticsRange: Hashable {
  case day, week, month

  var title: String {
    switch self {
    case .day: "24h"
    case .week: "7d"
    case .month: "30d"
    }
  }
  var totalsHeading: String {
    switch self {
    case .day: "Last 24 hours"
    case .week: "Last 7 days"
    case .month: "Last 30 days"
    }
  }
}

struct ZoneAnalyticsView: View {
  @Environment(AppModel.self) private var model
  let zoneID: String
  @State private var range: AnalyticsRange = .day
  @State private var points: [ZoneAnalyticsChartPoint] = []
  @State private var error: String?
  @State private var loading = true
  @State private var showsMoreMetrics = false

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !points.isEmpty,
      retry: { Task { await load(force: true) } },
      header: {
        DashTextTabs(
          items: [("24h", AnalyticsRange.day), ("7d", .week), ("30d", .month)],
          selection: $range
        )
      }
    ) {
      if points.isEmpty {
        DashEmptyState(
          icon: SolarAsset.chart,
          title: "No traffic yet",
          message: "HTTP request analytics for this zone will appear here."
        )
      } else {
        requestsHero
        chartCard
        if showsMoreMetrics {
          totalsGroup
          if range != .day {
            perBucketGroup
          }
        } else {
          Button {
            withAnimation(DashTheme.Motion.morph) { showsMoreMetrics = true }
          } label: {
            Text("Show more metrics")
              .dashTextStyle(.supportingMedium)
              .foregroundStyle(DashTheme.brand)
              .frame(maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(DashPressButtonStyle())
        }
      }
    }
    .navigationTitle("Analytics")
    .refreshable { await load(force: true) }
    .onChange(of: range) {
      points = []
      showsMoreMetrics = false
    }
    .task(id: range) { await load() }
  }

  private var requestsHero: some View {
    DashCard {
      VStack(alignment: .leading, spacing: 4) {
        Text("Requests")
          .dashTextStyle(.footnoteSemibold)
          .foregroundStyle(DashTheme.subtle)
        Text(totalRequests.formatted())
          .dashTextStyle(.emptyTitle)
          .foregroundStyle(DashTheme.strong)
        Text(range.totalsHeading)
          .dashTextStyle(.caption)
          .foregroundStyle(DashTheme.placeholder)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var chartCard: some View {
    DashCard {
      VStack(alignment: .leading, spacing: 12) {
        Text("Requests").dashTextStyle(.footnoteSemibold).foregroundStyle(DashTheme.subtle)
        Chart(points) { point in
          AreaMark(
            x: .value("Time", point.date),
            y: .value("Requests", point.requests)
          )
          .foregroundStyle(
            .linearGradient(
              colors: [DashTheme.brand.opacity(0.28), DashTheme.brand.opacity(0.02)],
              startPoint: .top, endPoint: .bottom)
          )
          .interpolationMethod(.catmullRom)
          LineMark(
            x: .value("Time", point.date),
            y: .value("Requests", point.requests)
          )
          .foregroundStyle(DashTheme.brand)
          .interpolationMethod(.catmullRom)
          if totalThreats > 0 {
            LineMark(
              x: .value("Time", point.date),
              y: .value("Threats", point.threats),
              series: .value("Series", "Threats")
            )
            .foregroundStyle(DashTheme.warning)
            .lineStyle(StrokeStyle(lineWidth: 1))
          }
        }
        .chartYAxis {
          AxisMarks(format: IntegerFormatStyle<Int>().notation(.compactName))
        }
        .chartXAxis {
          AxisMarks(values: .automatic(desiredCount: range == .day ? 4 : 5)) { value in
            AxisGridLine()
            AxisValueLabel(format: xAxisFormat, centered: false)
          }
        }
        .frame(height: 180)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          ZoneAnalyticsChartModel.chartAccessibilitySummary(
            rangeLabel: range.totalsHeading,
            requests: totalRequests,
            threats: totalThreats
          ))
        if totalThreats > 0 {
          HStack(spacing: 12) {
            legendDot(DashTheme.brand, "Requests")
            legendDot(DashTheme.warning, "Threats")
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private func legendDot(_ color: Color, _ label: String) -> some View {
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 7, height: 7)
      Text(label).font(.caption2).foregroundStyle(DashTheme.placeholder)
    }
  }

  private var xAxisFormat: Date.FormatStyle {
    range == .day
      ? .dateTime.hour()
      : .dateTime.month(.abbreviated).day()
  }

  private var totalsGroup: some View {
    DashListGroup(title: range.totalsHeading) {
      DashValueRow(title: "Requests", value: totalRequests.formatted())
      DashValueRow(title: "Bandwidth", value: bandwidth(totalBytes))
      DashValueRow(title: "Page views", value: totalPageViews.formatted())
      DashValueRow(title: "Threats", value: totalThreats.formatted())
    }
  }

  private var perBucketGroup: some View {
    DashListGroup(title: "Daily requests") {
      let ordered = points.reversed().enumerated()
      ForEach(Array(ordered), id: \.element.id) { index, point in
        DashValueRow(
          title: point.date.formatted(.dateTime.month(.abbreviated).day()),
          value: "\(point.requests.formatted()) req",
          subtitle: bandwidth(point.bytes)
        )
      }
    }
  }

  private var totalRequests: Int { points.reduce(0) { $0 + $1.requests } }
  private var totalPageViews: Int { points.reduce(0) { $0 + $1.pageViews } }
  private var totalThreats: Int { points.reduce(0) { $0 + $1.threats } }
  private var totalBytes: Int64 { points.reduce(0) { $0 + $1.bytes } }

  private func bandwidth(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
  }

  private func load(force: Bool = false) async {
    if points.isEmpty { loading = true }
    error = nil
    do {
      switch range {
      case .day:
        let key = FeatureCacheKey.zoneAnalyticsHourly(zoneID)
        if !force, let cached: [ZoneAnalyticsPoint] = model.featureCache.get(key) {
          points = ZoneAnalyticsChartModel.points(fromHourly: cached)
          loading = false
          return
        }
        let hourly = try await model.client.zoneAnalyticsHourly(zoneID: zoneID, hours: 24)
        model.featureCache.set(key, hourly)
        points = ZoneAnalyticsChartModel.points(fromHourly: hourly)
      case .week, .month:
        let days = range == .week ? 7 : 30
        let key = FeatureCacheKey.zoneAnalytics(zoneID, days: days)
        if !force, let cached: [ZoneAnalyticsDay] = model.featureCache.get(key) {
          points = ZoneAnalyticsChartModel.points(fromDaily: cached)
          loading = false
          return
        }
        let daily = try await model.client.zoneAnalytics(zoneID: zoneID, days: days)
        model.featureCache.set(key, daily)
        points = ZoneAnalyticsChartModel.points(fromDaily: daily)
      }
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}
