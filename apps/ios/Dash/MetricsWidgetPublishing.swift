import CloudflareAPI
import Foundation
import WidgetKit

/// Projects app-owned Cloudflare analytics into the Foundation-only snapshot
/// consumed by the metrics widgets.
///
/// Values stay in their source units: rates are fractions, CPU is
/// microseconds, bandwidth is bytes, and event values are counts. Formatting
/// belongs to the widget so totals and trend points always share one unit.
@MainActor
enum MetricsWidgetPublisher {
  static func syncAccounts(
    _ accounts: [CloudflareAccount],
    activeAccountID: String?
  ) {
    updateStore(reloading: [MetricsWidgetKind.account, MetricsWidgetKind.domain]) { store in
      store.setAccounts(
        accounts.map { MetricsWidgetAccount(id: $0.id, name: $0.name) },
        activeAccountID: activeAccountID)
    }
  }

  static func syncDomains(
    _ domains: [CloudflareZone],
    accountID: String,
    accountName: String,
    replacesCatalog: Bool
  ) {
    updateStore(reloading: [MetricsWidgetKind.domain]) { store in
      guard store.account(id: accountID) != nil else { return }
      let metadata = domains.map {
        MetricsWidgetDomain(
          id: $0.id,
          name: $0.name,
          accountID: accountID,
          accountName: accountName,
          avatarSeed: $0.name)
      }
      if replacesCatalog {
        store.replaceDomains(metadata, forAccountID: accountID)
      } else {
        store.mergeDomains(metadata, forAccountID: accountID)
      }
    }
  }

  static func publishAccount(
    snapshot: AccountAnalyticsSnapshot,
    accountID: String,
    accountName: String,
    range: AnalyticsRange
  ) {
    let metrics = AccountMetricsWidgetMetric.allCases.map { widgetMetric in
      let metric = watchtowerMetric(widgetMetric)
      let sourcePoints = metric.usesHTTPSeries ? snapshot.httpPoints : snapshot.workerPoints
      let points = WatchtowerAnalyticsChartModel.chartPoints(from: sourcePoints).map {
        MetricsWidgetPoint(
          timestamp: $0.date,
          value: accountValue($0.point, metric: metric))
      }
      return MetricsWidgetMetricSnapshot(
        metricID: widgetMetric.rawValue,
        total: accountTotal(snapshot.overview, metric: metric),
        points: points)
    }

    let widgetSnapshot = AccountMetricsWidgetSnapshot(
      accountID: accountID,
      accountName: accountName,
      range: widgetRange(range),
      metrics: metrics,
      fetchedAt: snapshot.fetchedAt)

    updateStore(reloading: [MetricsWidgetKind.account]) {
      $0.upsert(accountSnapshot: widgetSnapshot)
    }
  }

  static func publishDomain(
    snapshot: ZoneAnalyticsSnapshot,
    accountID: String,
    accountName: String,
    domainID: String,
    domainName: String?,
    range: AnalyticsRange,
    fetchedAt: Date = .now
  ) {
    let metrics = DomainMetricsWidgetMetric.allCases.map { metric in
      MetricsWidgetMetricSnapshot(
        metricID: metric.rawValue,
        total: domainTotal(snapshot, metric: metric),
        points: snapshot.points.map {
          MetricsWidgetPoint(
            timestamp: $0.date,
            value: domainValue($0, metric: metric))
        })
    }
    updateStore(reloading: [MetricsWidgetKind.domain]) { store in
      guard store.account(id: accountID) != nil else { return }
      let existingDomain = store.domain(id: domainID, accountID: accountID)
      let resolvedDomainName = domainName ?? existingDomain?.name ?? domainID
      let resolvedAccountName = store.account(id: accountID)?.name ?? accountName
      let domain = MetricsWidgetDomain(
        id: domainID,
        name: resolvedDomainName,
        accountID: accountID,
        accountName: resolvedAccountName,
        avatarSeed: existingDomain?.avatarSeed ?? resolvedDomainName)
      store.mergeDomains(
        [
          domain
        ],
        forAccountID: accountID)
      store.upsert(
        domainSnapshot: DomainMetricsWidgetSnapshot(
          domainID: domainID,
          domainName: domain.name,
          accountID: accountID,
          accountName: domain.accountName,
          avatarSeed: domain.avatarSeed,
          range: widgetRange(range),
          metrics: metrics,
          fetchedAt: fetchedAt))
    }
  }

  static func clear() {
    guard let url = MetricsWidgetSnapshotStore.containerFileURL else { return }
    MetricsWidgetSnapshotStore.clear(at: url)
    reloadTimelines(for: [MetricsWidgetKind.account, MetricsWidgetKind.domain])
  }

  private static func updateStore(
    reloading kinds: [String],
    _ update: (inout MetricsWidgetSnapshotStore) -> Void
  ) {
    guard let url = MetricsWidgetSnapshotStore.containerFileURL else { return }
    var store = (try? MetricsWidgetSnapshotStore.load(from: url)) ?? .empty
    update(&store)
    guard (try? store.write(to: url)) != nil else { return }
    reloadTimelines(for: kinds)
  }

  private static func reloadTimelines(for kinds: [String]) {
    for kind in kinds {
      WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
  }

  private static func widgetRange(_ range: AnalyticsRange) -> MetricsWidgetRange {
    switch range {
    case .day: .day
    case .week: .week
    case .month: .month
    }
  }

  private static func watchtowerMetric(
    _ metric: AccountMetricsWidgetMetric
  ) -> WatchtowerAnalyticsMetric {
    switch metric {
    case .workerInvocations: .workerInvocations
    case .workerErrors: .workerErrors
    case .cpuTime: .cpuTime
    case .webTraffic: .webTraffic
    case .totalBandwidth: .totalBandwidth
    case .cacheRate: .cacheRate
    case .clientRequestErrors: .clientRequestErrors
    case .encryptedRequestsRate: .encryptedRequestsRate
    case .encryptedBandwidth: .encryptedBandwidth
    }
  }

  private static func accountTotal(
    _ overview: AccountAnalyticsOverview,
    metric: WatchtowerAnalyticsMetric
  ) -> Double {
    switch metric {
    case .workerInvocations: Double(overview.workerInvocations)
    case .workerErrors: Double(overview.workerErrors)
    case .cpuTime: overview.cpuTimeP90Us
    case .webTraffic: Double(overview.webRequests)
    case .totalBandwidth: Double(overview.bytes)
    case .cacheRate: overview.cacheRate
    case .clientRequestErrors: overview.clientErrorRate
    case .encryptedRequestsRate: overview.encryptedRequestRate
    case .encryptedBandwidth: Double(overview.encryptedBytes)
    }
  }

  private static func accountValue(
    _ point: AccountAnalyticsPoint,
    metric: WatchtowerAnalyticsMetric
  ) -> Double {
    switch metric {
    case .workerInvocations, .webTraffic: Double(point.requests)
    case .workerErrors: Double(point.errors)
    case .cpuTime: point.cpuTimeP90Us
    case .totalBandwidth: Double(point.bytes)
    case .cacheRate: point.cacheRate
    case .clientRequestErrors: point.clientErrorRate
    case .encryptedRequestsRate: point.encryptedRequestRate
    case .encryptedBandwidth: Double(point.encryptedBytes)
    }
  }

  private static func domainTotal(
    _ snapshot: ZoneAnalyticsSnapshot,
    metric: DomainMetricsWidgetMetric
  ) -> Double {
    switch metric {
    case .requests: Double(snapshot.totalRequests)
    case .bandwidth: Double(snapshot.totalBytes)
    case .cacheRate:
      guard snapshot.totalRequests > 0 else { return 0 }
      return Double(snapshot.totalCachedRequests) / Double(snapshot.totalRequests)
    case .threats: Double(snapshot.totalThreats)
    case .uniqueVisitors: Double(snapshot.peakUniques)
    }
  }

  private static func domainValue(
    _ point: ZoneAnalyticsChartPoint,
    metric: DomainMetricsWidgetMetric
  ) -> Double {
    switch metric {
    case .requests: Double(point.requests)
    case .bandwidth: Double(point.bytes)
    case .cacheRate:
      guard point.requests > 0 else { return 0 }
      return Double(point.cachedRequests) / Double(point.requests)
    case .threats: Double(point.threats)
    case .uniqueVisitors: Double(point.uniques)
    }
  }
}
