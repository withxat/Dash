import Foundation

enum MetricsWidgetKind {
  static let account = "AccountMetricsWidget"
  static let domain = "DomainMetricsWidget"
}

enum MetricsWidgetRange: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
  case day
  case week
  case month

  var id: String { rawValue }

  var hours: Int {
    switch self {
    case .day: 24
    case .week: 168
    case .month: 720
    }
  }

  var title: String {
    switch self {
    case .day: "24h"
    case .week: "7d"
    case .month: "30d"
    }
  }

  fileprivate var sortOrder: Int {
    switch self {
    case .day: 0
    case .week: 1
    case .month: 2
    }
  }
}

enum AccountMetricsWidgetMetric: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
  case workerInvocations
  case workerErrors
  case cpuTime
  case webTraffic
  case totalBandwidth
  case cacheRate
  case clientRequestErrors
  case encryptedRequestsRate
  case encryptedBandwidth

  var id: String { rawValue }

  var title: String {
    switch self {
    case .workerInvocations: "Worker Invocations"
    case .workerErrors: "Workers Errors"
    case .cpuTime: "CPU Time"
    case .webTraffic: "Web Traffic"
    case .totalBandwidth: "Total Bandwidth"
    case .cacheRate: "Cache Rate"
    case .clientRequestErrors: "Client Request Errors"
    case .encryptedRequestsRate: "Encrypted Requests Rate"
    case .encryptedBandwidth: "Encrypted Bandwidth"
    }
  }
}

enum DomainMetricsWidgetMetric: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
  case requests
  case bandwidth
  case cacheRate
  case threats
  case uniqueVisitors

  var id: String { rawValue }

  var title: String {
    switch self {
    case .requests: "Requests"
    case .bandwidth: "Bandwidth"
    case .cacheRate: "Cache Rate"
    case .threats: "Threats"
    case .uniqueVisitors: "Unique visitors"
    }
  }
}

struct MetricsWidgetPoint: Codable, Hashable, Sendable {
  var timestamp: Date
  var value: Double
}

/// One metric's total and chronological series. Values use the API's canonical
/// units: ratios are `0...1`, CPU time is microseconds, bandwidth is bytes,
/// and counts are unscaled.
struct MetricsWidgetMetricSnapshot: Codable, Hashable, Sendable {
  var metricID: String
  var total: Double
  /// Prior-period total in the same units as `total`, when the publisher had a
  /// comparable window. Absent on older snapshots and metrics without a prior.
  var previousTotal: Double?
  var points: [MetricsWidgetPoint]

  init(
    metricID: String,
    total: Double,
    previousTotal: Double? = nil,
    points: [MetricsWidgetPoint]
  ) {
    self.metricID = metricID
    self.total = total
    self.previousTotal = previousTotal
    self.points = points
  }

  init(
    metric: AccountMetricsWidgetMetric,
    total: Double,
    previousTotal: Double? = nil,
    points: [MetricsWidgetPoint]
  ) {
    self.init(
      metricID: metric.rawValue,
      total: total,
      previousTotal: previousTotal,
      points: points)
  }

  init(
    metric: DomainMetricsWidgetMetric,
    total: Double,
    previousTotal: Double? = nil,
    points: [MetricsWidgetPoint]
  ) {
    self.init(
      metricID: metric.rawValue,
      total: total,
      previousTotal: previousTotal,
      points: points)
  }
}

/// Plot metrics shared by the app and widget **axis-less** system-chart
/// renderers (collapsed cards, widgets). Expanded Swift Charts with axes must
/// not apply this as `chartPlotStyle` padding — that shifts marks off the
/// axis frame.
enum CollapsedSystemChartPlotMetrics {
  /// Swift Charts centers vector strokes on the value coordinate. Keep the
  /// stroke and its antialiasing inside a clipped sparkline without changing
  /// the data domain or the Dither renderer's edge-to-edge scale.
  static let minimumTopInset: CGFloat = 4

  static func topInset(existingTop: CGFloat) -> CGFloat {
    max(existingTop, minimumTopInset)
  }

  /// `chartPlotStyle` top padding for the system renderer. Axes-on charts
  /// return 0 so marks stay registered to the axis frame; sparklines keep the
  /// stroke headroom from `topInset(existingTop:)`.
  static func plotStyleTopInset(showsAxes: Bool, existingTop: CGFloat) -> CGFloat {
    showsAxes ? 0 : topInset(existingTop: existingTop)
  }
}

/// Render-ready values that mirror the collapsed Watchtower sparkline: zero
/// samples keep a short 10% band, while an all-zero series uses a synthetic
/// ceiling so that band does not scale up to the full chart height.
struct CollapsedDitherTrendSeries: Hashable, Sendable {
  let values: [Double]
  let valueCeiling: Double?

  init(values: [Double]) {
    let sanitized = values.compactMap { value -> Double? in
      guard value.isFinite else { return nil }
      return max(0, value)
    }
    let peak = sanitized.max() ?? 0
    if peak > 0 {
      let floor = peak * 0.1
      self.values = sanitized.map { max($0, floor) }
      valueCeiling = nil
    } else {
      self.values = sanitized.map { _ in 0.1 }
      valueCeiling = 1
    }
  }
}

struct MetricsWidgetAccount: Codable, Hashable, Identifiable, Sendable {
  var id: String
  var name: String
}

struct MetricsWidgetDomain: Codable, Hashable, Identifiable, Sendable {
  var id: String
  var name: String
  var accountID: String
  var accountName: String
  var avatarSeed: String

  init(
    id: String,
    name: String,
    accountID: String,
    accountName: String,
    avatarSeed: String
  ) {
    self.id = id
    self.name = name
    self.accountID = accountID
    self.accountName = accountName
    self.avatarSeed = avatarSeed
  }

  /// Stable configuration identity even if a future backend can expose the
  /// same domain id under more than one account.
  var scopedID: String {
    Self.scopedID(accountID: accountID, domainID: id)
  }

  static func scopedID(accountID: String, domainID: String) -> String {
    "\(accountID):\(domainID)"
  }
}

struct AccountMetricsWidgetSnapshot: Codable, Hashable, Sendable {
  var accountID: String
  var accountName: String
  var range: MetricsWidgetRange
  var metrics: [MetricsWidgetMetricSnapshot]
  var fetchedAt: Date

  init(
    accountID: String,
    accountName: String,
    range: MetricsWidgetRange,
    metrics: [MetricsWidgetMetricSnapshot],
    fetchedAt: Date
  ) {
    self.accountID = accountID
    self.accountName = accountName
    self.range = range
    self.metrics = metrics
    self.fetchedAt = fetchedAt
  }

  func metric(_ metric: AccountMetricsWidgetMetric) -> MetricsWidgetMetricSnapshot? {
    metrics.first { $0.metricID == metric.rawValue }
  }

  var deepLinkURL: URL? {
    Self.deepLinkURL(accountID: accountID)
  }

  static func deepLinkURL(accountID: String) -> URL? {
    metricsWidgetDeepLink(host: "watchtower", accountID: accountID)
  }
}

struct DomainMetricsWidgetSnapshot: Codable, Hashable, Sendable {
  var domainID: String
  var domainName: String
  var accountID: String
  var accountName: String
  var avatarSeed: String
  var range: MetricsWidgetRange
  var metrics: [MetricsWidgetMetricSnapshot]
  var fetchedAt: Date

  init(
    domainID: String,
    domainName: String,
    accountID: String,
    accountName: String,
    avatarSeed: String,
    range: MetricsWidgetRange,
    metrics: [MetricsWidgetMetricSnapshot],
    fetchedAt: Date
  ) {
    self.domainID = domainID
    self.domainName = domainName
    self.accountID = accountID
    self.accountName = accountName
    self.avatarSeed = avatarSeed
    self.range = range
    self.metrics = metrics
    self.fetchedAt = fetchedAt
  }

  func metric(_ metric: DomainMetricsWidgetMetric) -> MetricsWidgetMetricSnapshot? {
    metrics.first { $0.metricID == metric.rawValue }
  }

  var deepLinkURL: URL? {
    Self.deepLinkURL(accountID: accountID, domainID: domainID)
  }

  static func deepLinkURL(accountID: String, domainID: String) -> URL? {
    metricsWidgetDeepLink(
      host: "zone",
      pathComponents: [domainID, "analytics"],
      accountID: accountID)
  }
}

/// Versioned, bounded state shared by the app and both configurable metrics
/// widgets. The store remains Foundation-only so the widget target can compile
/// this file without importing CloudflareAPI, AppIntents, or SwiftUI.
struct MetricsWidgetSnapshotStore: Codable, Hashable, Sendable {
  static let currentSchemaVersion = 1
  static let maximumDomainScopes = 32
  static let appGroupID = "group.sh.xat.dash.app"
  static let filename = "metrics-widget-snapshots.json"
  static let fileName = filename

  var schemaVersion: Int
  var activeAccountID: String?
  var accounts: [MetricsWidgetAccount]
  var domains: [MetricsWidgetDomain]
  var accountSnapshots: [AccountMetricsWidgetSnapshot]
  var domainSnapshots: [DomainMetricsWidgetSnapshot]

  init(
    schemaVersion: Int = Self.currentSchemaVersion,
    activeAccountID: String? = nil,
    accounts: [MetricsWidgetAccount] = [],
    domains: [MetricsWidgetDomain] = [],
    accountSnapshots: [AccountMetricsWidgetSnapshot] = [],
    domainSnapshots: [DomainMetricsWidgetSnapshot] = []
  ) {
    self.schemaVersion = schemaVersion
    self.activeAccountID = activeAccountID
    self.accounts = accounts
    self.domains = domains
    self.accountSnapshots = accountSnapshots
    self.domainSnapshots = domainSnapshots
    normalize()
  }

  static var empty: MetricsWidgetSnapshotStore {
    MetricsWidgetSnapshotStore()
  }

  static var containerFileURL: URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
      .appendingPathComponent(filename)
  }

  func account(id: String) -> MetricsWidgetAccount? {
    accounts.first { $0.id == id }
  }

  func domain(id: String, accountID: String) -> MetricsWidgetDomain? {
    domains.first { $0.id == id && $0.accountID == accountID }
  }

  func domains(forAccountID accountID: String) -> [MetricsWidgetDomain] {
    domains.filter { $0.accountID == accountID }
  }

  func accountSnapshot(
    accountID: String,
    range: MetricsWidgetRange
  ) -> AccountMetricsWidgetSnapshot? {
    accountSnapshots.first {
      $0.accountID == accountID && $0.range == range
    }
  }

  func domainSnapshot(
    accountID: String,
    domainID: String,
    range: MetricsWidgetRange
  ) -> DomainMetricsWidgetSnapshot? {
    domainSnapshots.first {
      $0.accountID == accountID && $0.domainID == domainID && $0.range == range
    }
  }

  mutating func setAccounts(
    _ accounts: [MetricsWidgetAccount],
    activeAccountID: String?
  ) {
    self.accounts = accounts
    let availableIDs = Set(accounts.map(\.id))
    self.activeAccountID = activeAccountID.flatMap { availableIDs.contains($0) ? $0 : nil }
    domains.removeAll { !availableIDs.contains($0.accountID) }
    accountSnapshots.removeAll { !availableIDs.contains($0.accountID) }
    domainSnapshots.removeAll { !availableIDs.contains($0.accountID) }

    let names = Dictionary(
      accounts.map { ($0.id, $0.name) },
      uniquingKeysWith: { _, latest in latest })
    domains = domains.map { domain in
      var domain = domain
      domain.accountName = names[domain.accountID] ?? domain.accountName
      return domain
    }
    accountSnapshots = accountSnapshots.map { snapshot in
      var snapshot = snapshot
      snapshot.accountName = names[snapshot.accountID] ?? snapshot.accountName
      return snapshot
    }
    domainSnapshots = domainSnapshots.map { snapshot in
      var snapshot = snapshot
      snapshot.accountName = names[snapshot.accountID] ?? snapshot.accountName
      return snapshot
    }
    normalize()
  }

  mutating func mergeDomains(
    _ domains: [MetricsWidgetDomain],
    forAccountID accountID: String
  ) {
    guard account(id: accountID) != nil else { return }
    let replacements = normalizedDomainMetadata(domains, accountID: accountID)

    // Zone lists are paginated. Merge every loaded page into the configuration
    // catalog so a later first-page refresh cannot orphan a widget configured
    // for a domain from a subsequent page.
    let replacementIDs = Set(replacements.map(\.scopedID))
    self.domains.removeAll { replacementIDs.contains($0.scopedID) }
    self.domains.append(contentsOf: replacements)

    let metadata = Dictionary(
      replacements.map { ($0.id, $0) },
      uniquingKeysWith: { _, latest in latest })
    domainSnapshots = domainSnapshots.map { snapshot in
      guard snapshot.accountID == accountID, let domain = metadata[snapshot.domainID] else {
        return snapshot
      }
      var snapshot = snapshot
      snapshot.domainName = domain.name
      snapshot.accountName = domain.accountName
      snapshot.avatarSeed = domain.avatarSeed
      return snapshot
    }
    normalize()
  }

  /// Replaces one account's configuration catalog after the app has proven it
  /// loaded the complete zone list. Unlike a page merge, this is authoritative:
  /// domains removed in Cloudflare no longer remain selectable in Widget setup.
  mutating func replaceDomains(
    _ domains: [MetricsWidgetDomain],
    forAccountID accountID: String
  ) {
    guard account(id: accountID) != nil else { return }
    let replacements = normalizedDomainMetadata(domains, accountID: accountID)
    let availableDomainIDs = Set(replacements.map(\.id))

    self.domains.removeAll { $0.accountID == accountID }
    self.domains.append(contentsOf: replacements)
    domainSnapshots.removeAll {
      $0.accountID == accountID && !availableDomainIDs.contains($0.domainID)
    }

    let metadata = Dictionary(
      replacements.map { ($0.id, $0) },
      uniquingKeysWith: { _, latest in latest })
    domainSnapshots = domainSnapshots.map { snapshot in
      guard snapshot.accountID == accountID, let domain = metadata[snapshot.domainID] else {
        return snapshot
      }
      var snapshot = snapshot
      snapshot.domainName = domain.name
      snapshot.accountName = domain.accountName
      snapshot.avatarSeed = domain.avatarSeed
      return snapshot
    }
    normalize()
  }

  mutating func upsert(accountSnapshot: AccountMetricsWidgetSnapshot) {
    if let existing = self.accountSnapshot(
      accountID: accountSnapshot.accountID,
      range: accountSnapshot.range
    ), existing.fetchedAt >= accountSnapshot.fetchedAt {
      return
    }
    accountSnapshots.removeAll {
      $0.accountID == accountSnapshot.accountID && $0.range == accountSnapshot.range
    }
    accountSnapshots.append(accountSnapshot)
    normalize()
  }

  mutating func upsert(domainSnapshot: DomainMetricsWidgetSnapshot) {
    if let existing = self.domainSnapshot(
      accountID: domainSnapshot.accountID,
      domainID: domainSnapshot.domainID,
      range: domainSnapshot.range
    ), existing.fetchedAt >= domainSnapshot.fetchedAt {
      return
    }
    domainSnapshots.removeAll {
      $0.accountID == domainSnapshot.accountID
        && $0.domainID == domainSnapshot.domainID
        && $0.range == domainSnapshot.range
    }
    domainSnapshots.append(domainSnapshot)
    normalize()
  }

  static func load(from url: URL) throws -> MetricsWidgetSnapshotStore {
    guard let store = try MetricsWidgetSnapshotRepository.read(at: url).store else {
      throw CocoaError(
        .fileReadNoSuchFile,
        userInfo: [NSFilePathErrorKey: url.path])
    }
    return store
  }

  func write(to url: URL) throws {
    _ = try MetricsWidgetSnapshotRepository.replace(at: url, with: self)
  }

  @discardableResult
  static func clear(at url: URL, expectedGeneration: UInt64? = nil) -> Bool {
    (try? MetricsWidgetSnapshotRepository.invalidateAndClear(
      at: url,
      expectedGeneration: expectedGeneration)) != nil
  }

  fileprivate static func loadUncoordinated(from url: URL) throws
    -> MetricsWidgetSnapshotStore
  {
    var store = try JSONDecoder().decode(
      MetricsWidgetSnapshotStore.self,
      from: Data(contentsOf: url))
    store.normalize()
    return store
  }

  fileprivate func writeUncoordinated(to url: URL) throws {
    var store = self
    store.normalize()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(store).write(to: url, options: .atomic)
  }

  fileprivate mutating func preserveNewerSnapshots(
    from existing: MetricsWidgetSnapshotStore
  ) {
    accountSnapshots.append(contentsOf: existing.accountSnapshots)
    domainSnapshots.append(contentsOf: existing.domainSnapshots)
    normalize()
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case activeAccountID
    case accounts
    case domains
    case accountSnapshots
    case domainSnapshots
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion =
      try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
      ?? Self.currentSchemaVersion
    activeAccountID = try container.decodeIfPresent(String.self, forKey: .activeAccountID)
    accounts =
      try container.decodeIfPresent([MetricsWidgetAccount].self, forKey: .accounts)
      ?? []
    domains =
      try container.decodeIfPresent([MetricsWidgetDomain].self, forKey: .domains)
      ?? []
    accountSnapshots =
      try container.decodeIfPresent(
        [AccountMetricsWidgetSnapshot].self,
        forKey: .accountSnapshots)
      ?? []
    domainSnapshots =
      try container.decodeIfPresent(
        [DomainMetricsWidgetSnapshot].self,
        forKey: .domainSnapshots)
      ?? []
    normalize()
  }

  private mutating func normalize() {
    accounts = deduplicated(accounts, keyedBy: \.id)
      .sorted(by: accountSort)

    let accountIDs = Set(accounts.map(\.id))
    if let activeAccountID, !accountIDs.contains(activeAccountID) {
      self.activeAccountID = nil
    }

    domains = deduplicated(domains, keyedBy: \.scopedID)
      .filter { accountIDs.contains($0.accountID) }
      .sorted(by: domainSort)
    accountSnapshots = deduplicatedAccountSnapshots(accountSnapshots)
      .filter { accountIDs.contains($0.accountID) }
    domainSnapshots = deduplicatedDomainSnapshots(domainSnapshots)
      .filter { accountIDs.contains($0.accountID) }
    retainNewestDomainScopes()
  }

  private func normalizedDomainMetadata(
    _ domains: [MetricsWidgetDomain],
    accountID: String
  ) -> [MetricsWidgetDomain] {
    let accountName = account(id: accountID)?.name ?? accountID
    return deduplicated(
      domains.map { domain in
        var domain = domain
        domain.accountID = accountID
        domain.accountName = accountName
        return domain
      },
      keyedBy: \.scopedID)
  }

  private mutating func retainNewestDomainScopes() {
    let newestByScope = Dictionary(
      grouping: domainSnapshots,
      by: { MetricsWidgetDomain.scopedID(accountID: $0.accountID, domainID: $0.domainID) }
    )
    .map { scopeID, snapshots in
      (scopeID: scopeID, fetchedAt: snapshots.map(\.fetchedAt).max() ?? .distantPast)
    }
    .sorted {
      if $0.fetchedAt != $1.fetchedAt { return $0.fetchedAt > $1.fetchedAt }
      return $0.scopeID < $1.scopeID
    }

    let retainedScopeIDs = Set(
      newestByScope.prefix(Self.maximumDomainScopes).map(\.scopeID))
    domainSnapshots.removeAll {
      !retainedScopeIDs.contains(
        MetricsWidgetDomain.scopedID(accountID: $0.accountID, domainID: $0.domainID))
    }
    domainSnapshots.sort(by: domainSnapshotSort)
  }
}

enum MetricsWidgetSessionMode: String, Codable, Hashable, Sendable {
  case remoteEnabled
  case localOnly
  case invalidated
}

/// Cross-process repository shared by the containing app and Widget extension.
///
/// A persistent sidecar file owns a BSD `flock`; opportunistic reads and
/// refresh writes fail fast while session transitions make a bounded series of
/// short attempts. Writers only read the JSON after obtaining that lock, then
/// atomically replace it. A separate session sidecar survives snapshot deletion
/// so a request that started before sign-out cannot recreate account data after
/// sign-out.
struct MetricsWidgetSnapshotRepository {
  struct State: Sendable {
    var store: MetricsWidgetSnapshotStore?
    var generation: UInt64
    var mode: MetricsWidgetSessionMode
  }

  enum RepositoryError: Error, Equatable, Sendable {
    case lockUnavailable
    case invalidSessionState
    case generationMismatch(expected: UInt64, actual: UInt64)
    case sessionInvalidated
    case remoteRefreshDisabled
    case invalidActivationMode
  }

  private struct SessionRecord: Codable, Equatable, Sendable {
    var generation: UInt64
    var mode: MetricsWidgetSessionMode
  }

  private struct LoadedSession {
    var record: SessionRecord
    var needsMigration: Bool
  }

  static func read(at url: URL) throws -> State {
    try withFileLock(at: url, operation: LOCK_SH) {
      let session = try loadSession(at: url).record
      return State(
        store: session.mode == .invalidated ? nil : try loadStoreIfPresent(at: url),
        generation: session.generation,
        mode: session.mode)
    }
  }

  static func sessionGeneration(at url: URL) throws -> UInt64 {
    try withFileLock(at: url, operation: LOCK_SH) {
      try loadSession(at: url).record.generation
    }
  }

  /// Replaces metadata while preserving any on-disk snapshot newer than the
  /// candidate. This keeps direct serialization callers from regressing a
  /// range that another process refreshed first.
  @discardableResult
  static func replace(
    at url: URL,
    with candidate: MetricsWidgetSnapshotStore,
    expectedGeneration: UInt64? = nil,
    requiresRemoteEnabled: Bool = false
  ) throws -> Bool {
    try withFileLock(at: url, operation: LOCK_EX) {
      let session = try loadSession(at: url)
      try validate(expectedGeneration: expectedGeneration, actual: session.record.generation)
      try validateWrite(
        mode: session.record.mode,
        requiresRemoteEnabled: requiresRemoteEnabled)
      let original = try loadStoreIfPresent(at: url)
      var merged = candidate
      if let original {
        merged.preserveNewerSnapshots(from: original)
      }
      let changed = merged != original
      if changed {
        try merged.writeUncoordinated(to: url)
      }
      if session.needsMigration {
        try writeSession(session.record, at: url)
      }
      return changed
    }
  }

  /// Performs one coordinated read-modify-write. A missing file is the only
  /// state that starts from `.empty`; malformed JSON is surfaced to the caller
  /// and left untouched.
  @discardableResult
  static func update(
    at url: URL,
    expectedGeneration: UInt64? = nil,
    requiresRemoteEnabled: Bool = false,
    _ update: (inout MetricsWidgetSnapshotStore) -> Void
  ) throws -> Bool {
    try withFileLock(at: url, operation: LOCK_EX) {
      let session = try loadSession(at: url)
      try validate(expectedGeneration: expectedGeneration, actual: session.record.generation)
      try validateWrite(
        mode: session.record.mode,
        requiresRemoteEnabled: requiresRemoteEnabled)
      let original = try loadStoreIfPresent(at: url) ?? .empty
      var store = original
      update(&store)
      let changed = store != original
      if changed {
        try store.writeUncoordinated(to: url)
      }
      if session.needsMigration {
        try writeSession(session.record, at: url)
      }
      return changed
    }
  }

  /// Starts a verified app-owned session with a fresh configuration catalog.
  /// A tombstone is persisted before replacing the JSON and the active mode is
  /// written last, so a process death at any intermediate point remains
  /// fail-closed.
  @discardableResult
  static func activate(
    at url: URL,
    mode: MetricsWidgetSessionMode,
    store: MetricsWidgetSnapshotStore
  ) throws -> State {
    guard mode != .invalidated else { throw RepositoryError.invalidActivationMode }
    return try withFileLock(
      at: url,
      operation: LOCK_EX,
      maximumAttempts: sessionTransitionLockAttempts
    ) {
      let currentSession: SessionRecord?
      var currentSessionNeedsMigration = false
      do {
        let loadedSession = try loadSession(at: url)
        currentSession = loadedSession.record
        currentSessionNeedsMigration = loadedSession.needsMigration
      } catch RepositoryError.invalidSessionState {
        // Only a verified activation may repair a malformed session sidecar.
        currentSession = nil
      }

      if let currentSession, currentSession.mode == mode,
        let existingStore = try? loadStoreIfPresent(at: url)
      {
        var mergedStore = existingStore
        mergedStore.setAccounts(
          store.accounts,
          activeAccountID: store.activeAccountID)
        if mergedStore != existingStore {
          try mergedStore.writeUncoordinated(to: url)
        }
        if currentSessionNeedsMigration {
          try writeSession(currentSession, at: url)
        }
        return State(
          store: mergedStore,
          generation: currentSession.generation,
          mode: mode)
      }

      let generation: UInt64
      if let currentSession {
        generation =
          currentSession.mode == .invalidated
          ? currentSession.generation
          : currentSession.generation &+ 1
      } else {
        generation = UInt64.random(in: 1...UInt64.max)
      }
      let tombstone = SessionRecord(generation: generation, mode: .invalidated)
      try writeSession(tombstone, at: url)
      try quarantineMalformedStoreIfNeeded(at: url)
      try store.writeUncoordinated(to: url)
      let activeSession = SessionRecord(generation: generation, mode: mode)
      try writeSession(activeSession, at: url)
      return State(store: store, generation: generation, mode: mode)
    }
  }

  /// Invalidates requests already in flight before deleting the snapshot. The
  /// tombstone write intentionally happens first so even a deletion failure
  /// cannot let an older network response become current again. An existing
  /// tombstone is idempotent and only retries cleanup.
  @discardableResult
  static func invalidateAndClear(
    at url: URL,
    expectedGeneration: UInt64? = nil
  ) throws -> UInt64 {
    try withFileLock(
      at: url,
      operation: LOCK_EX,
      maximumAttempts: sessionTransitionLockAttempts
    ) {
      let currentSession = try loadSession(at: url).record
      try validate(
        expectedGeneration: expectedGeneration,
        actual: currentSession.generation)
      let invalidatedSession: SessionRecord
      if currentSession.mode == .invalidated {
        invalidatedSession = currentSession
      } else {
        invalidatedSession = SessionRecord(
          generation: currentSession.generation &+ 1,
          mode: .invalidated)
        try writeSession(invalidatedSession, at: url)
      }
      try removeSnapshotAndQuarantine(at: url)
      return invalidatedSession.generation
    }
  }

  static func lockFileURL(for url: URL) -> URL {
    url.appendingPathExtension("lock")
  }

  static func generationFileURL(for url: URL) -> URL {
    url.appendingPathExtension("generation")
  }

  static func corruptSnapshotFileURL(for url: URL) -> URL {
    url.appendingPathExtension("corrupt")
  }

  private static func loadStoreIfPresent(
    at url: URL
  ) throws -> MetricsWidgetSnapshotStore? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try MetricsWidgetSnapshotStore.loadUncoordinated(from: url)
  }

  private static func loadSession(at url: URL) throws -> LoadedSession {
    let sessionURL = generationFileURL(for: url)
    guard FileManager.default.fileExists(atPath: sessionURL.path) else {
      return LoadedSession(
        record: SessionRecord(generation: 0, mode: .remoteEnabled),
        needsMigration: true)
    }
    let data = try Data(contentsOf: sessionURL)
    if let rawValue = String(data: data, encoding: .utf8),
      let legacyGeneration = UInt64(
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      return LoadedSession(
        record: SessionRecord(
          generation: legacyGeneration,
          mode: .remoteEnabled),
        needsMigration: true)
    }
    guard
      let record = try? JSONDecoder().decode(SessionRecord.self, from: data)
    else {
      throw RepositoryError.invalidSessionState
    }
    return LoadedSession(record: record, needsMigration: false)
  }

  private static func writeSession(_ session: SessionRecord, at url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(session)
      .write(to: generationFileURL(for: url), options: .atomic)
  }

  private static func quarantineMalformedStoreIfNeeded(at url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      _ = try MetricsWidgetSnapshotStore.loadUncoordinated(from: url)
    } catch {
      try Data(contentsOf: url)
        .write(to: corruptSnapshotFileURL(for: url), options: .atomic)
    }
  }

  private static func removeSnapshotAndQuarantine(at url: URL) throws {
    for candidate in [url, corruptSnapshotFileURL(for: url)]
    where FileManager.default.fileExists(atPath: candidate.path) {
      try FileManager.default.removeItem(at: candidate)
    }
  }

  private static func validate(
    expectedGeneration: UInt64?,
    actual: UInt64
  ) throws {
    guard let expectedGeneration, expectedGeneration != actual else { return }
    throw RepositoryError.generationMismatch(
      expected: expectedGeneration,
      actual: actual)
  }

  private static func validateWrite(
    mode: MetricsWidgetSessionMode,
    requiresRemoteEnabled: Bool
  ) throws {
    guard mode != .invalidated else { throw RepositoryError.sessionInvalidated }
    guard !requiresRemoteEnabled || mode == .remoteEnabled else {
      throw RepositoryError.remoteRefreshDisabled
    }
  }

  private static let sessionTransitionLockAttempts = 11
  private static let lockRetryDelayMicroseconds: useconds_t = 25_000

  private static func withFileLock<Result>(
    at url: URL,
    operation: Int32,
    maximumAttempts: Int = 3,
    _ body: () throws -> Result
  ) throws -> Result {
    let lockURL = lockFileURL(for: url)
    let descriptor = lockURL.path.withCString {
      open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { _ = close(descriptor) }

    var attempt = 1
    while flock(descriptor, operation | LOCK_NB) != 0 {
      let code = errno
      guard code == EWOULDBLOCK || code == EAGAIN else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
      }
      guard attempt < maximumAttempts else { throw RepositoryError.lockUnavailable }
      attempt += 1
      usleep(lockRetryDelayMicroseconds)
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try body()
  }
}

private func metricsWidgetDeepLink(
  host: String,
  pathComponents: [String] = [],
  accountID: String
) -> URL? {
  let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !accountID.isEmpty else { return nil }
  let pathComponents = pathComponents.map {
    $0.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  guard pathComponents.allSatisfy({ !$0.isEmpty }) else { return nil }

  var components = URLComponents()
  components.scheme = "dash"
  components.host = host
  if !pathComponents.isEmpty {
    components.path = "/" + pathComponents.joined(separator: "/")
  }
  components.queryItems = [URLQueryItem(name: "account", value: accountID)]
  return components.url
}

private func deduplicated<Element, Key: Hashable>(
  _ values: [Element],
  keyedBy keyPath: KeyPath<Element, Key>
) -> [Element] {
  var seen = Set<Key>()
  return values.reversed().filter { seen.insert($0[keyPath: keyPath]).inserted }.reversed()
}

private func normalizedMetrics(
  _ metrics: [MetricsWidgetMetricSnapshot]
) -> [MetricsWidgetMetricSnapshot] {
  deduplicated(metrics, keyedBy: \.metricID)
    .map { metric in
      var metric = metric
      metric.points.sort {
        if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
        return $0.value < $1.value
      }
      return metric
    }
    .sorted { $0.metricID < $1.metricID }
}

private func deduplicatedAccountSnapshots(
  _ snapshots: [AccountMetricsWidgetSnapshot]
) -> [AccountMetricsWidgetSnapshot] {
  let grouped = Dictionary(grouping: snapshots) {
    "\($0.accountID):\($0.range.rawValue)"
  }
  return grouped.values.compactMap { candidates in
    candidates.enumerated().max {
      if $0.element.fetchedAt != $1.element.fetchedAt {
        return $0.element.fetchedAt < $1.element.fetchedAt
      }
      return $0.offset < $1.offset
    }?.element
  }
  .map { snapshot in
    var snapshot = snapshot
    snapshot.metrics = normalizedMetrics(snapshot.metrics)
    return snapshot
  }
  .sorted(by: accountSnapshotSort)
}

private func deduplicatedDomainSnapshots(
  _ snapshots: [DomainMetricsWidgetSnapshot]
) -> [DomainMetricsWidgetSnapshot] {
  let grouped = Dictionary(grouping: snapshots) {
    "\($0.accountID):\($0.domainID):\($0.range.rawValue)"
  }
  return grouped.values.compactMap { candidates in
    candidates.enumerated().max {
      if $0.element.fetchedAt != $1.element.fetchedAt {
        return $0.element.fetchedAt < $1.element.fetchedAt
      }
      return $0.offset < $1.offset
    }?.element
  }
  .map { snapshot in
    var snapshot = snapshot
    snapshot.metrics = normalizedMetrics(snapshot.metrics)
    return snapshot
  }
  .sorted(by: domainSnapshotSort)
}

private func accountSort(
  _ lhs: MetricsWidgetAccount,
  _ rhs: MetricsWidgetAccount
) -> Bool {
  let leftName = lhs.name.folding(
    options: [.caseInsensitive, .diacriticInsensitive],
    locale: Locale(identifier: "en_US_POSIX"))
  let rightName = rhs.name.folding(
    options: [.caseInsensitive, .diacriticInsensitive],
    locale: Locale(identifier: "en_US_POSIX"))
  if leftName != rightName { return leftName < rightName }
  return lhs.id < rhs.id
}

private func domainSort(
  _ lhs: MetricsWidgetDomain,
  _ rhs: MetricsWidgetDomain
) -> Bool {
  if lhs.accountID != rhs.accountID { return lhs.accountID < rhs.accountID }
  let leftName = lhs.name.folding(
    options: [.caseInsensitive, .diacriticInsensitive],
    locale: Locale(identifier: "en_US_POSIX"))
  let rightName = rhs.name.folding(
    options: [.caseInsensitive, .diacriticInsensitive],
    locale: Locale(identifier: "en_US_POSIX"))
  if leftName != rightName { return leftName < rightName }
  return lhs.id < rhs.id
}

private func accountSnapshotSort(
  _ lhs: AccountMetricsWidgetSnapshot,
  _ rhs: AccountMetricsWidgetSnapshot
) -> Bool {
  if lhs.accountID != rhs.accountID { return lhs.accountID < rhs.accountID }
  return lhs.range.sortOrder < rhs.range.sortOrder
}

private func domainSnapshotSort(
  _ lhs: DomainMetricsWidgetSnapshot,
  _ rhs: DomainMetricsWidgetSnapshot
) -> Bool {
  if lhs.accountID != rhs.accountID { return lhs.accountID < rhs.accountID }
  if lhs.domainID != rhs.domainID { return lhs.domainID < rhs.domainID }
  return lhs.range.sortOrder < rhs.range.sortOrder
}
