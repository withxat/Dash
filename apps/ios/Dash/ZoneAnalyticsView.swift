import CloudflareAPI
import SwiftUI

struct ZoneAnalyticsView: View {
  @Environment(AppModel.self) private var model
  let zoneID: String
  @State private var days: [ZoneAnalyticsDay] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !days.isEmpty,
      retry: { Task { await load(force: true) } }
    ) {
      if days.isEmpty {
        DashEmptyState(
          icon: SolarAsset.chart,
          title: "No traffic yet",
          message: "HTTP request analytics for this zone will appear here."
        )
      } else {
        DashListGroup(title: "Last 7 days") {
          DashValueRow(title: "Requests", value: totalRequests.formatted())
          DashListGroupDivider()
          DashValueRow(title: "Bandwidth", value: bandwidth(totalBytes))
          DashListGroupDivider()
          DashValueRow(title: "Page views", value: totalPageViews.formatted())
          DashListGroupDivider()
          DashValueRow(title: "Threats", value: totalThreats.formatted())
        }
        DashListGroup(title: "Daily requests") {
          ForEach(Array(days.enumerated()), id: \.element.date) { index, day in
            DashValueRow(
              title: displayDate(day.date),
              value: "\(day.requests.formatted()) req",
              subtitle: bandwidth(Int64(day.bytes))
            )
            if index < days.count - 1 { DashListGroupDivider() }
          }
        }
      }
    }
    .navigationTitle("Analytics")
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private var totalRequests: Int { days.reduce(0) { $0 + $1.requests } }
  private var totalPageViews: Int { days.reduce(0) { $0 + $1.pageViews } }
  private var totalThreats: Int { days.reduce(0) { $0 + $1.threats } }
  private var totalBytes: Int64 { days.reduce(0) { $0 + $1.bytes } }

  private func bandwidth(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
  }

  private func displayDate(_ raw: String) -> String {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.locale = Locale(identifier: "en_US_POSIX")
    guard let date = parser.date(from: raw) else { return raw }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }

  private func load(force: Bool = false) async {
    let key = FeatureCacheKey.zoneAnalytics(zoneID)
    if !force, let cached: [ZoneAnalyticsDay] = model.featureCache.get(key) {
      days = cached
      error = nil
      loading = false
      return
    }
    if days.isEmpty { loading = true }
    error = nil
    do {
      days = try await model.client.zoneAnalytics(zoneID: zoneID)
      model.featureCache.set(key, days)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}
