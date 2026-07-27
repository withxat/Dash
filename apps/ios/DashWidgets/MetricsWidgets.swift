import AppIntents
import Foundation
import SwiftDitherKit
import SwiftUI
import WidgetKit

// MARK: - Configuration values

extension MetricsWidgetRange: AppEnum {
  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Range")
  }

  static var caseDisplayRepresentations: [MetricsWidgetRange: DisplayRepresentation] {
    [
      .day: "24h",
      .week: "7d",
      .month: "30d",
    ]
  }
}

extension AccountMetricsWidgetMetric: AppEnum {
  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Metric")
  }

  static var caseDisplayRepresentations: [AccountMetricsWidgetMetric: DisplayRepresentation] {
    [
      .workerInvocations: "Worker Invocations",
      .workerErrors: "Workers Errors",
      .cpuTime: "CPU Time",
      .webTraffic: "Web Traffic",
      .totalBandwidth: "Total Bandwidth",
      .cacheRate: "Cache Rate",
      .clientRequestErrors: "Client Request Errors",
      .encryptedRequestsRate: "Encrypted Requests Rate",
      .encryptedBandwidth: "Encrypted Bandwidth",
    ]
  }
}

extension DomainMetricsWidgetMetric: AppEnum {
  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Metric")
  }

  static var caseDisplayRepresentations: [DomainMetricsWidgetMetric: DisplayRepresentation] {
    [
      .requests: "Requests",
      .bandwidth: "Bandwidth",
      .cacheRate: "Cache Rate",
      .threats: "Threats",
      .uniqueVisitors: "Unique visitors",
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
    DisplayRepresentation(title: "\(name)")
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
    DisplayRepresentation(title: "\(name)", subtitle: "\(accountName)")
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
  static func load() -> MetricsWidgetSnapshotStore? {
    guard let url = MetricsWidgetSnapshotStore.containerFileURL else { return nil }
    return try? MetricsWidgetSnapshotStore.load(from: url)
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
  }

  let title: String
  let scope: String
  let total: String
  let values: [Double]
  let range: MetricsWidgetRange
  let fetchedAt: Date?
  let deepLinkURL: URL?
  let color: MetricsWidgetTrendColor
  let availability: Availability

  func isStale(at date: Date) -> Bool {
    guard let fetchedAt else { return false }
    return max(0, date.timeIntervalSince(fetchedAt)) > 24 * 60 * 60
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
      values: [],
      range: range,
      fetchedAt: nil,
      deepLinkURL: deepLinkURL,
      color: color,
      availability: .missing)
  }
}

struct AccountMetricsWidgetProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> MetricsWidgetEntry {
    MetricsWidgetEntry(
      date: .now,
      presentation: MetricsWidgetPresentation(
        title: localizedTitle(AccountMetricsWidgetMetric.webTraffic),
        scope: String(localized: "Account"),
        total: MetricsWidgetValueFormatter.count(1_284_300),
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
    entry(for: configuration, now: .now)
  }

  func timeline(
    for configuration: AccountMetricsWidgetIntent,
    in context: Context
  ) async -> Timeline<MetricsWidgetEntry> {
    let now = Date.now
    return Timeline(
      entries: [entry(for: configuration, now: now)],
      policy: .after(now.addingTimeInterval(30 * 60)))
  }

  private func entry(
    for configuration: AccountMetricsWidgetIntent,
    now: Date
  ) -> MetricsWidgetEntry {
    let title = localizedTitle(configuration.metric)
    let color = MetricsWidgetTrendColor(configuration.metric)
    guard let store = MetricsWidgetStoreReader.load() else {
      return MetricsWidgetEntry(
        date: now,
        presentation: .missing(
          title: title,
          scope: configuration.account?.name ?? String(localized: "Account"),
          range: configuration.range,
          deepLinkURL: configuration.account.flatMap {
            AccountMetricsWidgetSnapshot.deepLinkURL(accountID: $0.id)
          },
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
      return MetricsWidgetEntry(
        date: now,
        presentation: .missing(
          title: title,
          scope: account?.name ?? String(localized: "Account"),
          range: configuration.range,
          deepLinkURL: account.flatMap {
            AccountMetricsWidgetSnapshot.deepLinkURL(accountID: $0.id)
          },
          color: color))
    }

    return MetricsWidgetEntry(
      date: now,
      presentation: MetricsWidgetPresentation(
        title: title,
        scope: snapshot.accountName,
        total: MetricsWidgetValueFormatter.account(metric.total, metric: configuration.metric),
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
    entry(for: configuration, now: .now)
  }

  func timeline(
    for configuration: DomainMetricsWidgetIntent,
    in context: Context
  ) async -> Timeline<MetricsWidgetEntry> {
    let now = Date.now
    return Timeline(
      entries: [entry(for: configuration, now: now)],
      policy: .after(now.addingTimeInterval(30 * 60)))
  }

  private func entry(
    for configuration: DomainMetricsWidgetIntent,
    now: Date
  ) -> MetricsWidgetEntry {
    let title = localizedTitle(configuration.metric)
    let color = MetricsWidgetTrendColor(configuration.metric)
    guard let store = MetricsWidgetStoreReader.load() else {
      return MetricsWidgetEntry(
        date: now,
        presentation: .missing(
          title: title,
          scope: configuration.domain?.name ?? String(localized: "Domain"),
          range: configuration.range,
          deepLinkURL: configuration.domain.flatMap {
            DomainMetricsWidgetSnapshot.deepLinkURL(
              accountID: $0.accountID,
              domainID: $0.domainID)
          },
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
      return MetricsWidgetEntry(
        date: now,
        presentation: .missing(
          title: title,
          scope: domain?.name ?? String(localized: "Domain"),
          range: configuration.range,
          deepLinkURL: domain.flatMap {
            DomainMetricsWidgetSnapshot.deepLinkURL(
              accountID: $0.accountID,
              domainID: $0.domainID)
          },
          color: color))
    }

    return MetricsWidgetEntry(
      date: now,
      presentation: MetricsWidgetPresentation(
        title: title,
        scope: snapshot.domainName,
        total: MetricsWidgetValueFormatter.domain(metric.total, metric: configuration.metric),
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
    .description("A dithered Watchtower trend for your account.")
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
    .description("A dithered analytics trend for one domain.")
    .supportedFamilies([.systemSmall, .systemMedium])
    .contentMarginsDisabled()
  }
}

// MARK: - Presentation

private struct MetricsWidgetView: View {
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.widgetFamily) private var family

  let entry: MetricsWidgetEntry

  var body: some View {
    Group {
      if family == .systemMedium {
        mediumLayout
      } else {
        smallLayout
      }
    }
    .padding(14)
    .accessibilityElement(children: .combine)
  }

  private var smallLayout: some View {
    VStack(alignment: .leading, spacing: 4) {
      heading
      scope
      total
      Spacer(minLength: 2)
      chart
        .frame(height: 42)
      freshness
    }
  }

  private var mediumLayout: some View {
    VStack(alignment: .leading, spacing: 7) {
      heading
      HStack(alignment: .bottom, spacing: 14) {
        VStack(alignment: .leading, spacing: 4) {
          scope
          total
          Spacer(minLength: 0)
        }
        .frame(maxWidth: 126, maxHeight: .infinity, alignment: .leading)
        chart
          .frame(maxWidth: .infinity)
          .frame(height: 72)
      }
      freshness
    }
  }

  private var heading: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(entry.presentation.title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
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

  private var scope: some View {
    Text(entry.presentation.scope)
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }

  private var total: some View {
    Text(entry.presentation.total)
      .font(.system(.title2, design: .rounded, weight: .bold))
      .monospacedDigit()
      .foregroundStyle(.primary)
      .lineLimit(1)
      .minimumScaleFactor(0.65)
  }

  @ViewBuilder
  private var chart: some View {
    if entry.presentation.availability == .available, !trendValues.isEmpty {
      DitherSparkline(
        values: trendValues,
        color: entry.presentation.color.ditherColor(
          colorScheme: colorScheme,
          increasedContrast: colorSchemeContrast == .increased),
        variant: .gradient,
        highlighted: false,
        bloom: .off,
        animate: false
      )
      .ditherRenderingMode(.immediate)
      .opacity(entry.presentation.isStale(at: entry.date) ? 0.58 : 1)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    } else {
      Text("No data in this range")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
  }

  private var freshness: some View {
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

  private var trendValues: [Double] {
    entry.presentation.values.compactMap { value in
      guard value.isFinite else { return nil }
      return max(0, value)
    }
  }

  private var freshnessText: String {
    guard entry.presentation.availability == .available else {
      return String(localized: "Open Dash to refresh.")
    }
    guard let fetchedAt = entry.presentation.fetchedAt else {
      return String(localized: "Open Dash to refresh.")
    }
    if entry.presentation.isStale(at: entry.date) {
      return String(localized: "Stale — open Dash to refresh.")
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .abbreviated
    let relative = formatter.localizedString(for: fetchedAt, relativeTo: entry.date)
    return String(localized: "Checked \(relative)")
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
