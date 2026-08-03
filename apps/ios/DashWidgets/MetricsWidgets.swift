import AppIntents
import Charts
import Foundation
import SwiftDitherKit
import SwiftUI
import WidgetKit

/// AppEntity titles are account/domain data, not catalog keys. Constructing the
/// resource at runtime prevents the compiler from inventing a universal `%@`
/// localization entry for values that must be shown verbatim.
private func widgetIntentVerbatim(_ value: String) -> LocalizedStringResource {
  LocalizedStringResource(stringLiteral: value)
}

// MARK: - Configuration values

extension MetricsWidgetRange: AppEnum {
  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: LocalizedStringResource("Range"))
  }

  static var caseDisplayRepresentations: [MetricsWidgetRange: DisplayRepresentation] {
    [
      .day: DisplayRepresentation(title: LocalizedStringResource("24h")),
      .week: DisplayRepresentation(title: LocalizedStringResource("7d")),
      .month: DisplayRepresentation(title: LocalizedStringResource("30d")),
    ]
  }
}

extension AccountMetricsWidgetMetric: AppEnum {
  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: LocalizedStringResource("Metric"))
  }

  static var caseDisplayRepresentations: [AccountMetricsWidgetMetric: DisplayRepresentation] {
    [
      .workerInvocations: DisplayRepresentation(
        title: LocalizedStringResource("Worker Invocations")),
      .workerErrors: DisplayRepresentation(title: LocalizedStringResource("Workers Errors")),
      .cpuTime: DisplayRepresentation(title: LocalizedStringResource("CPU Time")),
      .webTraffic: DisplayRepresentation(title: LocalizedStringResource("Web Traffic")),
      .totalBandwidth: DisplayRepresentation(title: LocalizedStringResource("Total Bandwidth")),
      .cacheRate: DisplayRepresentation(title: LocalizedStringResource("Cache Rate")),
      .clientRequestErrors: DisplayRepresentation(
        title: LocalizedStringResource("Client Request Errors")),
      .encryptedRequestsRate: DisplayRepresentation(
        title: LocalizedStringResource("Encrypted Requests Rate")),
      .encryptedBandwidth: DisplayRepresentation(
        title: LocalizedStringResource("Encrypted Bandwidth")),
    ]
  }
}

extension DomainMetricsWidgetMetric: AppEnum {
  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: LocalizedStringResource("Metric"))
  }

  static var caseDisplayRepresentations: [DomainMetricsWidgetMetric: DisplayRepresentation] {
    [
      .requests: DisplayRepresentation(title: LocalizedStringResource("Requests")),
      .bandwidth: DisplayRepresentation(title: LocalizedStringResource("Bandwidth")),
      .cacheRate: DisplayRepresentation(title: LocalizedStringResource("Cache Rate")),
      .threats: DisplayRepresentation(title: LocalizedStringResource("Threats")),
      .uniqueVisitors: DisplayRepresentation(title: LocalizedStringResource("Unique visitors")),
    ]
  }
}

struct MetricsWidgetAccountEntity: AppEntity, Identifiable {
  let id: String
  let name: String

  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Account")
  }

  static let defaultQuery = MetricsWidgetAccountEntityQuery()

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: widgetIntentVerbatim(name))
  }

  init(id: String, name: String) {
    self.id = id
    self.name = name
  }

  init(_ account: MetricsWidgetAccount) {
    self.init(id: account.id, name: account.name)
  }
}

struct MetricsWidgetDomainEntity: AppEntity, Identifiable {
  let accountID: String
  let accountName: String
  let domainID: String
  let name: String
  let avatarSeed: String

  var id: String {
    Self.identifier(accountID: accountID, domainID: domainID)
  }

  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Domain")
  }

  static let defaultQuery = MetricsWidgetDomainEntityQuery()

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: widgetIntentVerbatim(name),
      subtitle: widgetIntentVerbatim(accountName)
    )
  }

  init(
    accountID: String,
    accountName: String,
    domainID: String,
    name: String,
    avatarSeed: String
  ) {
    self.accountID = accountID
    self.accountName = accountName
    self.domainID = domainID
    self.name = name
    self.avatarSeed = avatarSeed
  }

  init(_ domain: MetricsWidgetDomain) {
    self.init(
      accountID: domain.accountID,
      accountName: domain.accountName,
      domainID: domain.id,
      name: domain.name,
      avatarSeed: domain.avatarSeed)
  }

  static func identifier(accountID: String, domainID: String) -> String {
    MetricsWidgetDomain.scopedID(accountID: accountID, domainID: domainID)
  }

  static func decodeIdentifier(_ identifier: String) -> (accountID: String, domainID: String)? {
    let parts = identifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return (String(parts[0]), String(parts[1]))
  }
}

private enum MetricsWidgetStoreReader {
  static func baseline() -> MetricsWidgetRefreshBaseline? {
    guard let url = MetricsWidgetSnapshotStore.containerFileURL,
      let state = try? MetricsWidgetSnapshotRepository.read(at: url)
    else { return nil }
    return MetricsWidgetRefreshBaseline(
      store: state.store,
      generation: state.generation,
      mode: state.mode)
  }

  static func load() -> MetricsWidgetSnapshotStore? {
    baseline()?.store
  }

  static func refreshBaseline() async -> MetricsWidgetRefreshBaseline? {
    guard let url = MetricsWidgetSnapshotStore.containerFileURL else { return nil }
    for attempt in 0..<4 {
      do {
        let state = try MetricsWidgetSnapshotRepository.read(at: url)
        return MetricsWidgetRefreshBaseline(
          store: state.store,
          generation: state.generation,
          mode: state.mode)
      } catch MetricsWidgetSnapshotRepository.RepositoryError.lockUnavailable {
        guard attempt < 3 else { return nil }
        try? await Task.sleep(for: .milliseconds(10))
      } catch {
        return nil
      }
    }
    return nil
  }
}

struct MetricsWidgetAccountEntityQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [MetricsWidgetAccountEntity] {
    let store = MetricsWidgetStoreReader.load()
    return identifiers.map { identifier in
      if let account = store?.accounts.first(where: { $0.id == identifier }) {
        return MetricsWidgetAccountEntity(account)
      }
      // Preserve the configured account binding if its metadata disappears.
      // Returning no entity would turn the optional parameter into nil, which
      // could silently retarget an existing widget to the active account.
      return MetricsWidgetAccountEntity(
        id: identifier,
        name: String(localized: "Unavailable account"))
    }
  }

  func entities(matching string: String) async throws -> [MetricsWidgetAccountEntity] {
    guard let store = MetricsWidgetStoreReader.load() else { return [] }
    return orderedAccounts(in: store)
      .filter { $0.name.localizedCaseInsensitiveContains(string) }
      .map(MetricsWidgetAccountEntity.init)
  }

  func suggestedEntities() async throws -> [MetricsWidgetAccountEntity] {
    guard let store = MetricsWidgetStoreReader.load() else { return [] }
    return orderedAccounts(in: store).map(MetricsWidgetAccountEntity.init)
  }

  func defaultResult() async -> MetricsWidgetAccountEntity? {
    guard
      let store = MetricsWidgetStoreReader.load(),
      let activeAccountID = store.activeAccountID,
      let account = store.accounts.first(where: { $0.id == activeAccountID })
    else {
      return nil
    }
    return MetricsWidgetAccountEntity(account)
  }

  private func orderedAccounts(in store: MetricsWidgetSnapshotStore) -> [MetricsWidgetAccount] {
    store.accounts.sorted { lhs, rhs in
      let lhsIsActive = lhs.id == store.activeAccountID
      let rhsIsActive = rhs.id == store.activeAccountID
      if lhsIsActive != rhsIsActive { return lhsIsActive }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }
}

struct MetricsWidgetDomainEntityQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [MetricsWidgetDomainEntity] {
    let store = MetricsWidgetStoreReader.load()
    return identifiers.compactMap { identifier in
      if let domain = store?.domains.first(where: { $0.scopedID == identifier }) {
        return MetricsWidgetDomainEntity(domain)
      }
      guard let decoded = MetricsWidgetDomainEntity.decodeIdentifier(identifier) else {
        return nil
      }
      // As with accounts, keep the original account + domain identity instead
      // of falling through to a domain owned by the newly active account.
      return MetricsWidgetDomainEntity(
        accountID: decoded.accountID,
        accountName: String(localized: "Unavailable account"),
        domainID: decoded.domainID,
        name: String(localized: "Unavailable domain"),
        avatarSeed: "")
    }
  }

  func entities(matching string: String) async throws -> [MetricsWidgetDomainEntity] {
    guard let store = MetricsWidgetStoreReader.load() else { return [] }
    return orderedDomains(in: store)
      .filter {
        $0.name.localizedCaseInsensitiveContains(string)
          || $0.accountName.localizedCaseInsensitiveContains(string)
      }
      .map(MetricsWidgetDomainEntity.init)
  }

  func suggestedEntities() async throws -> [MetricsWidgetDomainEntity] {
    guard let store = MetricsWidgetStoreReader.load() else { return [] }
    return orderedDomains(in: store).map(MetricsWidgetDomainEntity.init)
  }

  func defaultResult() async -> MetricsWidgetDomainEntity? {
    guard
      let store = MetricsWidgetStoreReader.load(),
      let activeAccountID = store.activeAccountID,
      let domain = store.domains.first(where: { $0.accountID == activeAccountID })
    else {
      return nil
    }
    return MetricsWidgetDomainEntity(domain)
  }

  private func orderedDomains(in store: MetricsWidgetSnapshotStore) -> [MetricsWidgetDomain] {
    store.domains.sorted { lhs, rhs in
      let lhsIsActive = lhs.accountID == store.activeAccountID
      let rhsIsActive = rhs.accountID == store.activeAccountID
      if lhsIsActive != rhsIsActive { return lhsIsActive }
      if lhs.accountName != rhs.accountName {
        return lhs.accountName.localizedStandardCompare(rhs.accountName) == .orderedAscending
      }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }
}

struct AccountMetricsWidgetIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Account Metric"
  static let description = IntentDescription(
    "Show one dithered Watchtower metric for a Cloudflare account.")

  @Parameter(title: "Account")
  var account: MetricsWidgetAccountEntity?

  @Parameter(title: "Metric", default: .webTraffic)
  var metric: AccountMetricsWidgetMetric

  @Parameter(title: "Range", default: .day)
  var range: MetricsWidgetRange
}

struct DomainMetricsWidgetIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Domain Metric"
  static let description = IntentDescription(
    "Show one dithered analytics metric for a Cloudflare domain.")

  @Parameter(title: "Domain")
  var domain: MetricsWidgetDomainEntity?

  @Parameter(title: "Metric", default: .requests)
  var metric: DomainMetricsWidgetMetric

  @Parameter(title: "Range", default: .day)
  var range: MetricsWidgetRange
}

// MARK: - Timeline providers

struct MetricsWidgetEntry: TimelineEntry {
  let date: Date
  let presentation: MetricsWidgetPresentation
}

struct MetricsWidgetPresentation {
  enum Availability {
    case available
    case missing
    case requiresApp
  }

  let title: String
  /// Account name (Watchtower) or zone hostname (domain analytics).
  let scope: String
  let total: String
  /// Period-over-period label such as `+12%`, when a prior total exists.
  let trendText: String?
  let trendDirection: DashChartTrendDirection?
  let values: [Double]
  let range: MetricsWidgetRange
  let fetchedAt: Date?
  let deepLinkURL: URL?
  let color: MetricsWidgetTrendColor
  let availability: Availability

  func isStale(at date: Date) -> Bool {
    MetricsWidgetRefreshPolicy.needsRefresh(
      fetchedAt: fetchedAt,
      range: range,
      now: date)
  }

  static func missing(
    title: String,
    scope: String,
    range: MetricsWidgetRange,
    deepLinkURL: URL?,
    color: MetricsWidgetTrendColor
  ) -> MetricsWidgetPresentation {
    MetricsWidgetPresentation(
      title: title,
      scope: scope,
      total: "—",
      trendText: nil,
      trendDirection: nil,
      values: [],
      range: range,
      fetchedAt: nil,
      deepLinkURL: deepLinkURL,
      color: color,
      availability: .missing)
  }

  static func requiresApp(
    title: String,
    scope: String,
    range: MetricsWidgetRange,
    color: MetricsWidgetTrendColor
  ) -> MetricsWidgetPresentation {
    MetricsWidgetPresentation(
      title: title,
      scope: scope,
      total: "—",
      trendText: nil,
      trendDirection: nil,
      values: [],
      range: range,
      fetchedAt: nil,
      deepLinkURL: nil,
      color: color,
      availability: .requiresApp)
  }
}

private func reloadMetricsWidgetTimelinesAfterCredentialInvalidation() {
  WidgetCenter.shared.reloadTimelines(ofKind: MetricsWidgetKind.account)
  WidgetCenter.shared.reloadTimelines(ofKind: MetricsWidgetKind.domain)
}

private func metricsWidgetTimelinePolicy(
  for entry: MetricsWidgetEntry,
  range: MetricsWidgetRange,
  seed: String
) -> TimelineReloadPolicy {
  guard entry.presentation.availability != .requiresApp else {
    // App activation explicitly reloads both kinds. Spending WidgetKit budget
    // polling a signed-out/local-only empty session cannot discover new data.
    return .never
  }
  return .after(
    MetricsWidgetRefreshPolicy.nextReloadDate(
      after: entry.date,
      fetchedAt: entry.presentation.fetchedAt,
      range: range,
      seed: seed))
}

struct AccountMetricsWidgetProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> MetricsWidgetEntry {
    MetricsWidgetEntry(
      date: .now,
      presentation: MetricsWidgetPresentation(
        title: localizedTitle(AccountMetricsWidgetMetric.webTraffic),
        scope: String(localized: "Account"),
        total: MetricsWidgetValueFormatter.count(1_284_300),
        trendText: "+12%",
        trendDirection: .up,
        values: [18, 24, 21, 36, 31, 46, 42, 58, 51, 67, 62, 74],
        range: .day,
        fetchedAt: .now,
        deepLinkURL: nil,
        color: .blue,
        availability: .available))
  }

  func snapshot(
    for configuration: AccountMetricsWidgetIntent,
    in context: Context
  ) async -> MetricsWidgetEntry {
    entry(
      for: configuration,
      now: .now,
      baseline: await MetricsWidgetStoreReader.refreshBaseline())
  }

  func timeline(
    for configuration: AccountMetricsWidgetIntent,
    in context: Context
  ) async -> Timeline<MetricsWidgetEntry> {
    let startedAt = Date.now
    let baseline = await MetricsWidgetStoreReader.refreshBaseline()
    let target = refreshTarget(for: configuration, store: baseline?.store)
    var outcome = MetricsWidgetRefreshOutcome.fallback
    if let target, let baseline {
      outcome = await MetricsWidgetRemoteRefreshCoordinator.live.refreshIfNeeded(
        target,
        baseline: baseline,
        now: startedAt)
    }
    if outcome == .credentialInvalidated {
      reloadMetricsWidgetTimelinesAfterCredentialInvalidation()
    }
    // Never turn a pre-network in-memory snapshot into a new Timeline unless a
    // post-network read proves its generation and mode are still current. If
    // that proof is temporarily unavailable, a generic retrying entry is safer
    // than either old account data or a synthetic `.never` tombstone that could
    // race a newly activated session's reload.
    let displayBaseline = await MetricsWidgetStoreReader.refreshBaseline()
    let now = Date.now
    let currentEntry = entry(
      for: configuration,
      now: now,
      baseline: displayBaseline)
    return Timeline(
      entries: [currentEntry],
      policy: metricsWidgetTimelinePolicy(
        for: currentEntry,
        range: configuration.range,
        seed: target?.stableJitterSeed ?? "account:\(configuration.range.rawValue)"))
  }

  private func refreshTarget(
    for configuration: AccountMetricsWidgetIntent,
    store: MetricsWidgetSnapshotStore?
  ) -> MetricsWidgetRefreshTarget? {
    let account =
      configuration.account
      ?? store?.activeAccountID.flatMap { activeAccountID in
        store?.account(id: activeAccountID).map(MetricsWidgetAccountEntity.init)
      }
    guard let account else { return nil }
    let metadata = store?.account(id: account.id)
    return .account(
      accountID: account.id,
      accountName: metadata?.name ?? account.name,
      range: configuration.range,
      resolvesMetadata: metadata == nil)
  }

  private func entry(
    for configuration: AccountMetricsWidgetIntent,
    now: Date,
    baseline: MetricsWidgetRefreshBaseline?
  ) -> MetricsWidgetEntry {
    let title = localizedTitle(configuration.metric)
    let color = MetricsWidgetTrendColor(configuration.metric)
    guard let baseline else {
      return MetricsWidgetEntry(
        date: now,
        presentation: .missing(
          title: title,
          scope: String(localized: "Account"),
          range: configuration.range,
          deepLinkURL: nil,
          color: color))
    }
    if baseline.mode == .invalidated {
      return MetricsWidgetEntry(
        date: now,
        presentation: .requiresApp(
          title: title,
          scope: String(localized: "Account"),
          range: configuration.range,
          color: color))
    }
    guard let store = baseline.store else {
      return MetricsWidgetEntry(
        date: now,
        presentation:
          baseline.mode == .localOnly
          ? .requiresApp(
            title: title,
            scope: String(localized: "Account"),
            range: configuration.range,
            color: color)
          : .missing(
            title: title,
            scope: String(localized: "Account"),
            range: configuration.range,
            deepLinkURL: nil,
            color: color))
    }

    let account =
      configuration.account
      ?? store.activeAccountID.flatMap { activeAccountID in
        store.accounts.first(where: { $0.id == activeAccountID })
          .map(MetricsWidgetAccountEntity.init)
      }
    guard
      let account,
      let snapshot = store.accountSnapshot(accountID: account.id, range: configuration.range),
      let metric = snapshot.metric(configuration.metric)
    else {
      let currentAccount = account.flatMap { store.account(id: $0.id) }
      return MetricsWidgetEntry(
        date: now,
        presentation: .missing(
          title: title,
          scope: currentAccount?.name ?? String(localized: "Account"),
          range: configuration.range,
          deepLinkURL: currentAccount.flatMap {
            AccountMetricsWidgetSnapshot.deepLinkURL(accountID: $0.id)
          },
          color: color))
    }

    let trend = MetricsWidgetTrendFormatter.trend(
      current: metric.total,
      previous: metric.previousTotal)
    return MetricsWidgetEntry(
      date: now,
      presentation: MetricsWidgetPresentation(
        title: title,
        scope: snapshot.accountName,
        total: MetricsWidgetValueFormatter.account(metric.total, metric: configuration.metric),
        trendText: trend.text,
        trendDirection: trend.direction,
        values: metric.points.map(\.value),
        range: configuration.range,
        fetchedAt: snapshot.fetchedAt,
        deepLinkURL: snapshot.deepLinkURL,
        color: color,
        availability: .available))
  }
}

struct DomainMetricsWidgetProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> MetricsWidgetEntry {
    MetricsWidgetEntry(
      date: .now,
      presentation: MetricsWidgetPresentation(
        title: localizedTitle(DomainMetricsWidgetMetric.requests),
        scope: "example.com",
        total: MetricsWidgetValueFormatter.count(428_900),
        trendText: "+8%",
        trendDirection: .up,
        values: [12, 19, 17, 28, 25, 39, 34, 48, 45, 57, 53, 64],
        range: .day,
        fetchedAt: .now,
        deepLinkURL: nil,
        color: .blue,
        availability: .available))
  }

  func snapshot(
    for configuration: DomainMetricsWidgetIntent,
    in context: Context
  ) async -> MetricsWidgetEntry {
    entry(
      for: configuration,
      now: .now,
      baseline: await MetricsWidgetStoreReader.refreshBaseline())
  }

  func timeline(
    for configuration: DomainMetricsWidgetIntent,
    in context: Context
  ) async -> Timeline<MetricsWidgetEntry> {
    let startedAt = Date.now
    let baseline = await MetricsWidgetStoreReader.refreshBaseline()
    let target = refreshTarget(for: configuration, store: baseline?.store)
    var outcome = MetricsWidgetRefreshOutcome.fallback
    if let target, let baseline {
      outcome = await MetricsWidgetRemoteRefreshCoordinator.live.refreshIfNeeded(
        target,
        baseline: baseline,
        now: startedAt)
    }
    if outcome == .credentialInvalidated {
      reloadMetricsWidgetTimelinesAfterCredentialInvalidation()
    }
    let displayBaseline = await MetricsWidgetStoreReader.refreshBaseline()
    let now = Date.now
    let currentEntry = entry(
      for: configuration,
      now: now,
      baseline: displayBaseline)
    return Timeline(
      entries: [currentEntry],
      policy: metricsWidgetTimelinePolicy(
        for: currentEntry,
        range: configuration.range,
        seed: target?.stableJitterSeed ?? "domain:\(configuration.range.rawValue)"))
  }

  private func refreshTarget(
    for configuration: DomainMetricsWidgetIntent,
    store: MetricsWidgetSnapshotStore?
  ) -> MetricsWidgetRefreshTarget? {
    let domain =
      configuration.domain
      ?? store?.activeAccountID.flatMap { activeAccountID in
        store?.domains.first(where: { $0.accountID == activeAccountID })
          .map(MetricsWidgetDomainEntity.init)
      }
    guard let domain else { return nil }
    let accountMetadata = store?.account(id: domain.accountID)
    let domainMetadata = store?.domain(id: domain.domainID, accountID: domain.accountID)
    return .domain(
      accountID: domain.accountID,
      accountName: accountMetadata?.name ?? domain.accountName,
      domainID: domain.domainID,
      domainName: domainMetadata?.name ?? domain.name,
      range: configuration.range,
      resolvesMetadata: accountMetadata == nil || domainMetadata == nil)
  }

  private func entry(
    for configuration: DomainMetricsWidgetIntent,
    now: Date,
    baseline: MetricsWidgetRefreshBaseline?
  ) -> MetricsWidgetEntry {
    let title = localizedTitle(configuration.metric)
    let color = MetricsWidgetTrendColor(configuration.metric)
    guard let baseline else {
      return MetricsWidgetEntry(
        date: now,
        presentation: .missing(
          title: title,
          scope: String(localized: "Domain"),
          range: configuration.range,
          deepLinkURL: nil,
          color: color))
    }
    if baseline.mode == .invalidated {
      return MetricsWidgetEntry(
        date: now,
        presentation: .requiresApp(
          title: title,
          scope: String(localized: "Domain"),
          range: configuration.range,
          color: color))
    }
    guard let store = baseline.store else {
      return MetricsWidgetEntry(
        date: now,
        presentation:
          baseline.mode == .localOnly
          ? .requiresApp(
            title: title,
            scope: String(localized: "Domain"),
            range: configuration.range,
            color: color)
          : .missing(
            title: title,
            scope: String(localized: "Domain"),
            range: configuration.range,
            deepLinkURL: nil,
            color: color))
    }

    let domain =
      configuration.domain
      ?? store.activeAccountID.flatMap { activeAccountID in
        store.domains.first(where: { $0.accountID == activeAccountID })
          .map(MetricsWidgetDomainEntity.init)
      }
    guard
      let domain,
      let snapshot = store.domainSnapshot(
        accountID: domain.accountID,
        domainID: domain.domainID,
        range: configuration.range),
      let metric = snapshot.metric(configuration.metric)
    else {
      let currentDomain = domain.flatMap {
        store.domain(id: $0.domainID, accountID: $0.accountID)
      }
      return MetricsWidgetEntry(
        date: now,
        presentation: .missing(
          title: title,
          scope: currentDomain?.name ?? String(localized: "Domain"),
          range: configuration.range,
          deepLinkURL: currentDomain.flatMap {
            DomainMetricsWidgetSnapshot.deepLinkURL(
              accountID: $0.accountID,
              domainID: $0.id)
          },
          color: color))
    }

    let trend = MetricsWidgetTrendFormatter.trend(
      current: metric.total,
      previous: metric.previousTotal)
    return MetricsWidgetEntry(
      date: now,
      presentation: MetricsWidgetPresentation(
        title: title,
        scope: snapshot.domainName,
        total: MetricsWidgetValueFormatter.domain(metric.total, metric: configuration.metric),
        trendText: trend.text,
        trendDirection: trend.direction,
        values: metric.points.map(\.value),
        range: configuration.range,
        fetchedAt: snapshot.fetchedAt,
        deepLinkURL: snapshot.deepLinkURL,
        color: color,
        availability: .available))
  }
}

// MARK: - Widgets

struct AccountMetricsWidget: Widget {
  static let kind = MetricsWidgetKind.account

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: Self.kind,
      intent: AccountMetricsWidgetIntent.self,
      provider: AccountMetricsWidgetProvider()
    ) { entry in
      MetricsWidgetView(entry: entry)
        .containerBackground(.background, for: .widget)
        .widgetURL(entry.presentation.deepLinkURL)
    }
    .configurationDisplayName("Account Metrics")
    .description("A Watchtower trend for your account.")
    .supportedFamilies([.systemSmall, .systemMedium])
    .contentMarginsDisabled()
  }
}

struct DomainMetricsWidget: Widget {
  static let kind = MetricsWidgetKind.domain

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: Self.kind,
      intent: DomainMetricsWidgetIntent.self,
      provider: DomainMetricsWidgetProvider()
    ) { entry in
      MetricsWidgetView(entry: entry)
        .containerBackground(.background, for: .widget)
        .widgetURL(entry.presentation.deepLinkURL)
    }
    .configurationDisplayName("Domain Metrics")
    .description("An analytics trend for one domain.")
    .supportedFamilies([.systemSmall, .systemMedium])
    .contentMarginsDisabled()
  }
}

// MARK: - Presentation

private struct MetricsWidgetView: View {
  private static let chartSeriesID = "value"
  /// Floor for the plot so a dither band still reads at accessibility text
  /// sizes, where the header claims most of a widget that cannot grow.
  private static let minimumPlotHeight: CGFloat = 44

  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.colorScheme) private var colorScheme

  /// Mirrors `DashTextStyle.emptyTitle`, the collapsed card's total: 24pt bold
  /// in the default design, scaled from `.title2`. Not `.title2` rounded — SF
  /// Rounded's bold reads about a weight lighter than SF Pro's, which is what
  /// made the widget's main metric look like body weight next to the app's.
  @ScaledMetric(relativeTo: .title2) private var totalFontSize: CGFloat = 24

  let entry: MetricsWidgetEntry

  /// Matches collapsed Watchtower / Worker cards: scope + range above the
  /// metric chrome, then title → total (+ trend) → sparkline flush to the
  /// bottom edge.
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
      // The plot claims every point the header leaves instead of taking a fixed
      // height under a spacer. Fixed heights cannot fit both families: 52pt on
      // the small one left `CollapsedDitherTrendSeries`' 10% floor lift about
      // five points tall, too short for the dither gradient to read as a band
      // at all, while 88pt plus a two-line title overflowed the medium family
      // and squeezed the header instead.
      chart
        .frame(maxWidth: .infinity)
        .frame(minHeight: Self.minimumPlotHeight, maxHeight: .infinity)
        .clipShape(
          UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 20,
            bottomTrailingRadius: 20,
            topTrailingRadius: 0,
            style: .continuous)
        )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .combine)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      scopeAndRange
      Text(entry.presentation.title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        // One line in both families. Watchtower reserves two so paired cards
        // share a height; a widget has no pair, and the medium family is wide
        // enough for every metric title — the second line only shortened the
        // plot.
        .lineLimit(1, reservesSpace: true)
        .minimumScaleFactor(0.85)
      HStack(alignment: .center, spacing: 6) {
        Text(entry.presentation.total)
          .font(.system(size: totalFontSize, weight: .bold))
          .monospacedDigit()
          .foregroundStyle(.primary)
          .lineLimit(1)
          .allowsTightening(true)
          .layoutPriority(1)
        if entry.presentation.trendText != nil,
          let direction = entry.presentation.trendDirection
        {
          trendIcon(direction)
        }
        Spacer(minLength: 4)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(metricAccessibilityLabel)
      if showsFreshness {
        Text(freshnessText)
          .font(.caption2)
          .foregroundStyle(
            entry.presentation.isStale(at: entry.date)
              ? Color.orange
              : Color.secondary.opacity(0.7)
          )
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    }
  }

  /// Widget-only band above the collapsed-chart chrome: who/where the series
  /// belongs to, and which window it covers.
  private var scopeAndRange: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(entry.presentation.scope)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      Spacer(minLength: 0)
      Text(localizedTitle(entry.presentation.range))
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
  }

  private var showsFreshness: Bool {
    entry.presentation.availability == .available
      && entry.presentation.isStale(at: entry.date)
  }

  private var metricAccessibilityLabel: String {
    guard let trendText = entry.presentation.trendText else {
      return entry.presentation.total
    }
    return
      "\(entry.presentation.total), \(String(localized: "Change")): \(trendText)"
  }

  @ViewBuilder
  private func trendIcon(_ direction: DashChartTrendDirection) -> some View {
    switch direction {
    case .up:
      trendImage("SolarArrowRightUpBold", direction: direction)
    case .down:
      trendImage("SolarArrowRightDownBold", direction: direction)
    case .flat:
      EmptyView()
    }
  }

  private func trendImage(
    _ asset: String,
    direction: DashChartTrendDirection
  ) -> some View {
    Image(asset)
      .resizable()
      .renderingMode(.template)
      .scaledToFit()
      .frame(width: 16, height: 16)
      .foregroundStyle(
        MetricsWidgetTrendPalette.color(
          direction: direction,
          convention: DashChartTrendColorConvention.resolved(
            locale: DashWidgetBridges.mirroredLocale()),
          colorScheme: colorScheme,
          increasedContrast: colorSchemeContrast == .increased)
      )
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private var chart: some View {
    let trend = CollapsedDitherTrendSeries(values: entry.presentation.values)
    if entry.presentation.availability == .available, !trend.values.isEmpty {
      let ditherColor = entry.presentation.color.ditherColor(
        colorScheme: colorScheme,
        increasedContrast: colorSchemeContrast == .increased)
      Group {
        if DashWidgetBridges.mirroredChartStyleIsSystem {
          MetricsWidgetSystemSparkline(
            values: trend.values,
            valueCeiling: trend.valueCeiling,
            color: ditherColor)
        } else {
          DitherAreaChart(
            data: trend.values.enumerated().map { index, value in
              DitherDatum(
                id: "sample-\(index)",
                label: "\(index + 1)",
                values: [Self.chartSeriesID: value])
            },
            series: [
              DitherSeries(
                id: Self.chartSeriesID,
                label: entry.presentation.title,
                color: ditherColor,
                variant: .gradient)
            ],
            options: DitherCartesianOptions(
              stacking: .overlaid,
              margins: .sparkline,
              bloom: .off,
              animate: false,
              interactive: false,
              showsAxes: false,
              showsLegend: false,
              showsTooltip: false,
              valueFormat: .compact,
              valueCeiling: trend.valueCeiling),
            highlighted: false,
            selection: nil
          )
          .ditherRenderingMode(.immediate)
        }
      }
      .opacity(entry.presentation.isStale(at: entry.date) ? 0.58 : 1)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    } else if entry.presentation.availability == .missing {
      Text("Refreshing")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else if entry.presentation.availability == .requiresApp {
      Text("Open Dash")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      Text("No data in this range")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var freshnessText: String {
    guard let fetchedAt = entry.presentation.fetchedAt else { return "" }
    let relative: String
    if entry.date.timeIntervalSince(fetchedAt) < 1 {
      relative = String(localized: "just now")
    } else {
      let formatter = RelativeDateTimeFormatter()
      formatter.locale = DashWidgetBridges.mirroredLocale()
      formatter.unitsStyle = .abbreviated
      relative = formatter.localizedString(for: fetchedAt, relativeTo: entry.date)
    }
    return String(localized: "Updated \(relative)")
  }
}

private enum MetricsWidgetTrendFormatter {
  static func trend(
    current: Double,
    previous: Double?
  ) -> (text: String?, direction: DashChartTrendDirection?) {
    guard let trend = DashChartTrendComparison(current: current, previous: previous) else {
      return (nil, nil)
    }
    let text = trend.formattedPercentage(locale: DashWidgetBridges.mirroredLocale())
    return (text, text == nil ? nil : trend.direction)
  }
}

private enum MetricsWidgetTrendPalette {
  static func color(
    direction: DashChartTrendDirection,
    convention: DashChartTrendColorConvention,
    colorScheme: ColorScheme,
    increasedContrast: Bool
  ) -> Color {
    guard direction != .flat else { return .secondary }

    let usesRed: Bool
    switch (convention, direction) {
    case (.redUpGreenDown, .up), (.greenUpRedDown, .down):
      usesRed = true
    case (.redUpGreenDown, .down), (.greenUpRedDown, .up):
      usesRed = false
    case (_, .flat):
      return .secondary
    }

    let isDark: Bool
    switch colorScheme {
    case .light:
      isDark = false
    case .dark:
      isDark = true
    @unknown default:
      return .secondary
    }
    let token = usesRed ? DashChartTrendColorTokens.red : DashChartTrendColorTokens.green
    let hex = token.hex(isDark: isDark, increasedContrast: increasedContrast)
    return Color(metricsWidgetHex: hex)
  }
}

extension Color {
  fileprivate init(metricsWidgetHex hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}

private enum MetricsWidgetValueFormatter {
  static func account(_ value: Double, metric: AccountMetricsWidgetMetric) -> String {
    switch metric {
    case .workerInvocations, .workerErrors, .webTraffic:
      count(value)
    case .cpuTime:
      cpuTime(value)
    case .totalBandwidth, .encryptedBandwidth:
      bytes(value)
    case .cacheRate, .clientRequestErrors, .encryptedRequestsRate:
      percent(value)
    }
  }

  static func domain(_ value: Double, metric: DomainMetricsWidgetMetric) -> String {
    switch metric {
    case .requests, .threats, .uniqueVisitors:
      count(value)
    case .bandwidth:
      bytes(value)
    case .cacheRate:
      percent(value)
    }
  }

  static func count(_ value: Double) -> String {
    value.formatted(
      .number
        .notation(.compactName)
        .precision(.fractionLength(0...1)))
  }

  private static func bytes(_ value: Double) -> String {
    Int64(max(0, value).rounded()).formatted(.byteCount(style: .binary))
  }

  private static func percent(_ value: Double) -> String {
    value.formatted(.percent.precision(.fractionLength(1)))
  }

  private static func cpuTime(_ microseconds: Double) -> String {
    Measurement(value: microseconds / 1_000, unit: UnitDuration.milliseconds)
      .formatted(
        .measurement(
          width: .abbreviated,
          usage: .asProvided,
          numberFormatStyle: .number.precision(.fractionLength(0...2))))
  }
}

/// Widget-local Swift Charts sparkline matching the band a collapsed chart card
/// paints in the app. Lives here so DashWidgets does not compile the full
/// DashCharts module.
private struct MetricsWidgetSystemSparkline: View {
  let values: [Double]
  let valueCeiling: Double?
  let color: DitherColor

  private var points: [(index: Int, value: Double)] {
    values.enumerated().map { ($0.offset, $0.element.isFinite ? $0.element : 0) }
  }

  var body: some View {
    Chart(points, id: \.index) { point in
      AreaMark(
        x: .value("Index", point.index),
        y: .value("Value", point.value)
      )
      .foregroundStyle(
        LinearGradient(
          colors: [
            Color(dither: color).opacity(0.4),
            Color(dither: color).opacity(0.05),
          ],
          startPoint: .top,
          endPoint: .bottom)
      )
      .interpolationMethod(.catmullRom)
      LineMark(
        x: .value("Index", point.index),
        y: .value("Value", point.value)
      )
      .foregroundStyle(Color(dither: color))
      .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
      .interpolationMethod(.catmullRom)
    }
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartLegend(.hidden)
    .chartPlotStyle { plotArea in
      plotArea.padding(
        .top,
        CollapsedSystemChartPlotMetrics.topInset(existingTop: 0))
    }
    .chartXScale(domain: 0...max(0, values.count - 1))
    .metricsWidgetYScale(ceiling: valueCeiling)
  }
}

extension View {
  @ViewBuilder
  fileprivate func metricsWidgetYScale(ceiling: Double?) -> some View {
    if let ceiling, ceiling > 0 {
      chartYScale(domain: 0...ceiling)
    } else {
      self
    }
  }
}

enum MetricsWidgetTrendColor {
  case blue
  case green
  case purple
  case red
  case teal

  init(_ metric: AccountMetricsWidgetMetric) {
    switch metric {
    case .workerErrors, .clientRequestErrors:
      self = .red
    case .totalBandwidth, .encryptedBandwidth:
      self = .teal
    case .cacheRate, .encryptedRequestsRate:
      self = .green
    case .cpuTime:
      self = .purple
    case .workerInvocations, .webTraffic:
      self = .blue
    }
  }

  init(_ metric: DomainMetricsWidgetMetric) {
    switch metric {
    case .threats:
      self = .red
    case .bandwidth:
      self = .teal
    case .cacheRate:
      self = .green
    case .uniqueVisitors:
      self = .purple
    case .requests:
      self = .blue
    }
  }

  func ditherColor(
    colorScheme: ColorScheme,
    increasedContrast: Bool
  ) -> DitherColor {
    switch (self, colorScheme, increasedContrast) {
    case (.blue, .light, false): DitherColor(hex: 0x056DFF)
    case (.blue, .dark, false): DitherColor(hex: 0x045EDE)
    case (.blue, .light, true): DitherColor(hex: 0x1447E6)
    case (.blue, .dark, true): DitherColor(hex: 0x51A2FF)
    case (.green, .light, false): DitherColor(hex: 0x00A63E)
    case (.green, .dark, false): DitherColor(hex: 0x00C950)
    case (.green, .light, true): DitherColor(hex: 0x008236)
    case (.green, .dark, true): DitherColor(hex: 0x7BF1A8)
    case (.purple, .light, false), (.purple, .dark, false):
      DitherColor(hex: 0x8E51FF)
    case (.purple, .light, true): DitherColor(hex: 0x6E11B0)
    case (.purple, .dark, true): DitherColor(hex: 0xC4B4FF)
    case (.red, .light, false): DitherColor(hex: 0xE7000B)
    case (.red, .dark, false): DitherColor(hex: 0xFF6467)
    case (.red, .light, true): DitherColor(hex: 0xC10007)
    case (.red, .dark, true): DitherColor(hex: 0xFFA2A2)
    case (.teal, .light, false): DitherColor(hex: 0x009689)
    case (.teal, .dark, false): DitherColor(hex: 0x00BBA7)
    case (.teal, .light, true): DitherColor(hex: 0x00786F)
    case (.teal, .dark, true): DitherColor(hex: 0x46ECD5)
    @unknown default:
      DitherColor.blue
    }
  }
}

private func localizedTitle(_ range: MetricsWidgetRange) -> String {
  String(localized: LocalizedStringResource(stringLiteral: range.title))
}

private func localizedTitle(_ metric: AccountMetricsWidgetMetric) -> String {
  switch metric {
  case .workerInvocations: String(localized: "Worker Invocations")
  case .workerErrors: String(localized: "Workers Errors")
  case .cpuTime: String(localized: "CPU Time")
  case .webTraffic: String(localized: "Web Traffic")
  case .totalBandwidth: String(localized: "Total Bandwidth")
  case .cacheRate: String(localized: "Cache Rate")
  case .clientRequestErrors: String(localized: "Client Request Errors")
  case .encryptedRequestsRate: String(localized: "Encrypted Requests Rate")
  case .encryptedBandwidth: String(localized: "Encrypted Bandwidth")
  }
}

private func localizedTitle(_ metric: DomainMetricsWidgetMetric) -> String {
  switch metric {
  case .requests: String(localized: "Requests")
  case .bandwidth: String(localized: "Bandwidth")
  case .cacheRate: String(localized: "Cache Rate")
  case .threats: String(localized: "Threats")
  case .uniqueVisitors: String(localized: "Unique visitors")
  }
}
