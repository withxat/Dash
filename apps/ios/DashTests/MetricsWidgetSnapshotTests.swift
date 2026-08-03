import Foundation
import Testing

@testable import Dash

@Test func metricsWidgetMetricSnapshotDecodesWithoutPreviousTotal() throws {
  let legacy = """
    {"metricID":"webTraffic","total":42,"points":[]}
    """.data(using: .utf8)!
  let decoded = try JSONDecoder().decode(MetricsWidgetMetricSnapshot.self, from: legacy)
  #expect(decoded.metricID == "webTraffic")
  #expect(decoded.total == 42)
  #expect(decoded.previousTotal == nil)
  #expect(decoded.points.isEmpty)

  let withPrevious = MetricsWidgetMetricSnapshot(
    metric: .webTraffic,
    total: 50,
    previousTotal: 40,
    points: [])
  let roundTrip = try JSONDecoder().decode(
    MetricsWidgetMetricSnapshot.self,
    from: JSONEncoder().encode(withPrevious))
  #expect(roundTrip.previousTotal == 40)
}

@Test func metricsWidgetTrendMatchesChartDirectionAndPercentageRules() throws {
  let up = try #require(DashChartTrendComparison(current: 125, previous: 100))
  #expect(up.direction == .up)
  #expect(up.percentChange == 0.25)
  #expect(up.formattedPercentage(locale: Locale(identifier: "en_US")) == "+25%")

  let down = try #require(DashChartTrendComparison(current: 75, previous: 100))
  #expect(down.direction == .down)
  #expect(down.percentChange == -0.25)
  #expect(down.formattedPercentage(locale: Locale(identifier: "en_US")) == "−25%")

  let flat = try #require(DashChartTrendComparison(current: 100, previous: 100))
  #expect(flat.direction == .flat)
  #expect(flat.percentChange == 0)
  #expect(flat.formattedPercentage(locale: Locale(identifier: "en_US")) == "0%")

  let zeroBaseline = try #require(DashChartTrendComparison(current: 1, previous: 0))
  #expect(zeroBaseline.direction == .up)
  #expect(zeroBaseline.percentChange == nil)
  #expect(zeroBaseline.formattedPercentage(locale: Locale(identifier: "en_US")) == nil)

  #expect(DashChartTrendComparison(current: 1, previous: nil) == nil)
  #expect(DashChartTrendComparison(current: .infinity, previous: 1) == nil)
}

@Test func metricsWidgetTrendColorsFollowMirroredLanguageConvention() {
  #expect(
    DashChartTrendColorConvention.resolved(locale: Locale(identifier: "zh-Hans"))
      == .redUpGreenDown)
  #expect(
    DashChartTrendColorConvention.resolved(locale: Locale(identifier: "zh-Hant"))
      == .redUpGreenDown)
  #expect(
    DashChartTrendColorConvention.resolved(locale: Locale(identifier: "en"))
      == .greenUpRedDown)
}

@Test func metricsWidgetTrendMatchesCollapsedWatchtowerZeroFloor() {
  let mixed = CollapsedDitherTrendSeries(values: [0, 50, 0, 100])
  let collapsedMixed = WatchtowerAnalyticsChartModel.collapsedSeriesValues([0, 50, 0, 100])
  #expect(mixed.values == [10, 50, 10, 100])
  #expect(mixed.valueCeiling == nil)
  #expect(mixed.values == collapsedMixed.values)
  #expect(mixed.valueCeiling == collapsedMixed.valueCeiling)

  let quiet = CollapsedDitherTrendSeries(values: [0, 0, 0])
  let collapsedQuiet = WatchtowerAnalyticsChartModel.collapsedSeriesValues([0, 0, 0])
  #expect(quiet.values == [0.1, 0.1, 0.1])
  #expect(quiet.valueCeiling == 1)
  #expect(quiet.values == collapsedQuiet.values)
  #expect(quiet.valueCeiling == collapsedQuiet.valueCeiling)

  let empty = CollapsedDitherTrendSeries(values: [])
  #expect(empty.values.isEmpty)
  #expect(empty.valueCeiling == 1)
}

@Test func collapsedSystemChartsReservePeakHeadroom() {
  #expect(CollapsedSystemChartPlotMetrics.topInset(existingTop: 0) == 4)
  #expect(CollapsedSystemChartPlotMetrics.topInset(existingTop: 8) == 8)
  // Axes-on (expanded detail / Watchtower cards): no plot-style padding —
  // otherwise Swift Charts shifts marks below the X axis.
  #expect(
    CollapsedSystemChartPlotMetrics.plotStyleTopInset(showsAxes: true, existingTop: 8) == 0)
  #expect(
    CollapsedSystemChartPlotMetrics.plotStyleTopInset(showsAxes: false, existingTop: 0) == 4)
}

@Test func metricsWidgetStoreScopesLookupsAndDeepLinksByAccount() throws {
  let accountA = MetricsWidgetAccount(id: "account-a", name: "Account A")
  let accountB = MetricsWidgetAccount(id: "account-b", name: "Account B")
  let accountSnapshotA = makeAccountSnapshot(
    account: accountA,
    range: .day,
    total: 11)
  let accountSnapshotB = makeAccountSnapshot(
    account: accountB,
    range: .day,
    total: 22)
  let domainSnapshotA = makeDomainSnapshot(
    account: accountA,
    domainID: "shared-zone",
    range: .day,
    total: 101)
  let domainSnapshotB = makeDomainSnapshot(
    account: accountB,
    domainID: "shared-zone",
    range: .day,
    total: 202)

  let store = MetricsWidgetSnapshotStore(
    activeAccountID: accountA.id,
    accounts: [accountA, accountB],
    domains: [
      makeDomain(account: accountA, id: "shared-zone"),
      makeDomain(account: accountB, id: "shared-zone"),
    ],
    accountSnapshots: [accountSnapshotA, accountSnapshotB],
    domainSnapshots: [domainSnapshotA, domainSnapshotB])

  let resolvedAccountA = try #require(
    store.accountSnapshot(accountID: accountA.id, range: .day))
  let resolvedAccountB = try #require(
    store.accountSnapshot(accountID: accountB.id, range: .day))
  #expect(resolvedAccountA.metric(.webTraffic)?.total == 11)
  #expect(resolvedAccountB.metric(.webTraffic)?.total == 22)
  #expect(store.accountSnapshot(accountID: "missing", range: .day) == nil)
  #expect(store.accountSnapshot(accountID: accountA.id, range: .week) == nil)

  let resolvedDomainA = try #require(
    store.domainSnapshot(
      accountID: accountA.id,
      domainID: "shared-zone",
      range: .day))
  let resolvedDomainB = try #require(
    store.domainSnapshot(
      accountID: accountB.id,
      domainID: "shared-zone",
      range: .day))
  #expect(resolvedDomainA.metric(.requests)?.total == 101)
  #expect(resolvedDomainB.metric(.requests)?.total == 202)
  #expect(
    store.domainSnapshot(
      accountID: "missing",
      domainID: "shared-zone",
      range: .day) == nil)

  let resolvedAccountURL = try #require(resolvedAccountB.deepLinkURL)
  let accountLink = try #require(
    URLComponents(url: resolvedAccountURL, resolvingAgainstBaseURL: false))
  #expect(accountLink.scheme == "dash")
  #expect(accountLink.host == "watchtower")
  #expect(accountLink.path.isEmpty)
  #expect(accountLink.queryItems == [URLQueryItem(name: "account", value: accountB.id)])

  let resolvedDomainURL = try #require(resolvedDomainA.deepLinkURL)
  let domainLink = try #require(
    URLComponents(url: resolvedDomainURL, resolvingAgainstBaseURL: false))
  #expect(domainLink.scheme == "dash")
  #expect(domainLink.host == "zone")
  #expect(domainLink.path == "/shared-zone/analytics")
  #expect(domainLink.queryItems == [URLQueryItem(name: "account", value: accountA.id)])

  let missingAccountURL = try #require(
    AccountMetricsWidgetSnapshot.deepLinkURL(accountID: accountB.id))
  let missingAccountLink = try #require(
    URLComponents(url: missingAccountURL, resolvingAgainstBaseURL: false))
  #expect(missingAccountLink.host == "watchtower")
  #expect(missingAccountLink.queryItems == [URLQueryItem(name: "account", value: accountB.id)])

  let missingDomainURL = try #require(
    DomainMetricsWidgetSnapshot.deepLinkURL(
      accountID: accountA.id,
      domainID: "shared-zone"))
  let missingDomainLink = try #require(
    URLComponents(url: missingDomainURL, resolvingAgainstBaseURL: false))
  #expect(missingDomainLink.host == "zone")
  #expect(missingDomainLink.path == "/shared-zone/analytics")
  #expect(missingDomainLink.queryItems == [URLQueryItem(name: "account", value: accountA.id)])
}

@Test func metricsWidgetStoreMergesPaginatedDomainsWithoutDroppingLaterPages() throws {
  let account = MetricsWidgetAccount(id: "account-a", name: "Account A")
  var store = MetricsWidgetSnapshotStore(accounts: [account])

  store.mergeDomains(
    [
      makeDomain(account: account, id: "zone-1", name: "One"),
      makeDomain(account: account, id: "zone-2", name: "Two"),
    ],
    forAccountID: account.id)
  store.mergeDomains(
    [
      makeDomain(account: account, id: "zone-3", name: "Three"),
      makeDomain(account: account, id: "zone-4", name: "Four"),
    ],
    forAccountID: account.id)
  store.upsert(
    domainSnapshot: makeDomainSnapshot(
      account: account,
      domainID: "zone-4",
      domainName: "Four",
      range: .week,
      total: 404))

  store.mergeDomains(
    [makeDomain(account: account, id: "zone-1", name: "One updated")],
    forAccountID: account.id)

  #expect(
    store.domains(forAccountID: account.id).map(\.id)
      == ["zone-4", "zone-1", "zone-3", "zone-2"])
  #expect(store.domain(id: "zone-1", accountID: account.id)?.name == "One updated")
  #expect(store.domain(id: "zone-4", accountID: account.id)?.name == "Four")
  #expect(
    store.domainSnapshot(
      accountID: account.id,
      domainID: "zone-4",
      range: .week)?
      .metric(.requests)?.total == 404)
}

@Test func metricsWidgetStorePrunesRemovedDomainsAfterAuthoritativeReplace() {
  let account = MetricsWidgetAccount(id: "account-a", name: "Account A")
  var store = MetricsWidgetSnapshotStore(
    accounts: [account],
    domains: [
      makeDomain(account: account, id: "zone-kept"),
      makeDomain(account: account, id: "zone-removed"),
    ],
    domainSnapshots: [
      makeDomainSnapshot(
        account: account,
        domainID: "zone-kept",
        range: .day),
      makeDomainSnapshot(
        account: account,
        domainID: "zone-removed",
        range: .day),
    ])

  store.replaceDomains(
    [makeDomain(account: account, id: "zone-kept", name: "Kept")],
    forAccountID: account.id)

  #expect(store.domains(forAccountID: account.id).map(\.id) == ["zone-kept"])
  #expect(
    store.domainSnapshot(
      accountID: account.id,
      domainID: "zone-removed",
      range: .day) == nil)
}

@Test func metricsWidgetStoreDeduplicatesPagesAndRejectsUnknownAccounts() {
  let account = MetricsWidgetAccount(id: "account-a", name: "Account A")
  let unknown = MetricsWidgetAccount(id: "account-missing", name: "Missing")
  var store = MetricsWidgetSnapshotStore(accounts: [account])

  store.mergeDomains(
    [
      makeDomain(account: account, id: "zone-1", name: "Old name"),
      makeDomain(account: account, id: "zone-1", name: "Latest name"),
    ],
    forAccountID: account.id)
  store.mergeDomains(
    [makeDomain(account: unknown, id: "orphan")],
    forAccountID: unknown.id)

  #expect(store.domains.count == 1)
  #expect(store.domain(id: "zone-1", accountID: account.id)?.name == "Latest name")
  #expect(store.domains(forAccountID: unknown.id).isEmpty)
}

@Test func metricsWidgetStoreJSONRoundTripPreservesNormalizedOrder() throws {
  let accountA = MetricsWidgetAccount(id: "account-a", name: "Alpha")
  let accountB = MetricsWidgetAccount(id: "account-b", name: "beta")
  let firstDate = Date(timeIntervalSince1970: 10)
  let secondDate = Date(timeIntervalSince1970: 20)
  let unsortedMetric = MetricsWidgetMetricSnapshot(
    metricID: DomainMetricsWidgetMetric.requests.rawValue,
    total: 30,
    points: [
      MetricsWidgetPoint(timestamp: secondDate, value: 20),
      MetricsWidgetPoint(timestamp: firstDate, value: 10),
      MetricsWidgetPoint(timestamp: secondDate, value: 15),
    ])
  let store = MetricsWidgetSnapshotStore(
    activeAccountID: accountB.id,
    accounts: [accountB, accountA],
    domains: [
      makeDomain(account: accountB, id: "zone-b", name: "Beta"),
      makeDomain(account: accountA, id: "zone-z", name: "Zulu"),
      makeDomain(account: accountA, id: "zone-a", name: "alpha"),
    ],
    accountSnapshots: [
      makeAccountSnapshot(account: accountB, range: .week, total: 2),
      makeAccountSnapshot(account: accountA, range: .month, total: 3),
      makeAccountSnapshot(account: accountA, range: .day, total: 1),
    ],
    domainSnapshots: [
      makeDomainSnapshot(
        account: accountA,
        domainID: "zone-z",
        range: .month,
        metrics: [unsortedMetric]),
      makeDomainSnapshot(
        account: accountA,
        domainID: "zone-a",
        range: .week,
        total: 7),
    ])

  #expect(store.accounts.map(\.id) == [accountA.id, accountB.id])
  #expect(
    store.domains.map(\.scopedID)
      == [
        "account-a:zone-a",
        "account-a:zone-z",
        "account-b:zone-b",
      ])
  #expect(
    store.accountSnapshots.map { "\($0.accountID):\($0.range.rawValue)" }
      == [
        "account-a:day",
        "account-a:month",
        "account-b:week",
      ])
  let normalizedMetric = try #require(
    store.domainSnapshot(
      accountID: accountA.id,
      domainID: "zone-z",
      range: .month)?
      .metric(.requests))
  #expect(normalizedMetric.points.map(\.timestamp) == [firstDate, secondDate, secondDate])
  #expect(normalizedMetric.points.map(\.value) == [10, 15, 20])

  let directory = FileManager.default.temporaryDirectory
    .appending(
      path: "dash-metrics-widget-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory)
  let fileURL = directory.appending(path: MetricsWidgetSnapshotStore.filename)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true)

  try store.write(to: fileURL)
  let decoded = try MetricsWidgetSnapshotStore.load(from: fileURL)

  #expect(decoded == store)
  #expect(decoded.schemaVersion == MetricsWidgetSnapshotStore.currentSchemaVersion)
  #expect(decoded.activeAccountID == accountB.id)
}

@Test @MainActor func metricsWidgetPublisherSkipsIdenticalWritesAndTimelineReloads() throws {
  let account = MetricsWidgetAccount(id: "account-a", name: "Account A")
  let directory = FileManager.default.temporaryDirectory
    .appending(
      path: "dash-metrics-widget-publisher-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory)
  let fileURL = directory.appending(path: MetricsWidgetSnapshotStore.filename)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true)

  let initialStore = MetricsWidgetSnapshotStore(
    activeAccountID: account.id,
    accounts: [account])
  try initialStore.write(to: fileURL)
  let sentinelModificationDate = Date(timeIntervalSince1970: 10)
  try FileManager.default.setAttributes(
    [.modificationDate: sentinelModificationDate],
    ofItemAtPath: fileURL.path)
  let initialData = try Data(contentsOf: fileURL)
  var reloads: [[String]] = []

  let identicalChanged = MetricsWidgetPublisher.updateStore(
    at: fileURL,
    reloading: ["AccountMetricsWidget"],
    reload: { reloads.append($0) },
    update: {
      $0.setAccounts([account], activeAccountID: account.id)
    })

  #expect(!identicalChanged)
  #expect(reloads.isEmpty)
  #expect(try Data(contentsOf: fileURL) == initialData)
  let unchangedAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
  #expect(unchangedAttributes[.modificationDate] as? Date == sentinelModificationDate)

  let changed = MetricsWidgetPublisher.updateStore(
    at: fileURL,
    reloading: ["AccountMetricsWidget"],
    reload: { reloads.append($0) },
    update: {
      $0.setAccounts(
        [MetricsWidgetAccount(id: account.id, name: "Renamed")],
        activeAccountID: account.id)
    })

  #expect(changed)
  #expect(reloads == [["AccountMetricsWidget"]])
  #expect(
    try MetricsWidgetSnapshotStore.load(from: fileURL)
      .account(id: account.id)?.name == "Renamed")
}

@Test @MainActor func metricsWidgetPublisherKeepsNewerSnapshotFromAnotherProcess() throws {
  let account = MetricsWidgetAccount(id: "account-a", name: "Account A")
  let directory = FileManager.default.temporaryDirectory
    .appending(
      path: "dash-metrics-widget-newest-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory)
  let fileURL = directory.appending(path: MetricsWidgetSnapshotStore.filename)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true)

  let newSnapshot = makeAccountSnapshot(
    account: account,
    range: .day,
    total: 200,
    fetchedAt: Date(timeIntervalSince1970: 200))
  try MetricsWidgetSnapshotStore(
    accounts: [account],
    accountSnapshots: [newSnapshot]
  ).write(to: fileURL)
  var reloads: [[String]] = []

  let changed = MetricsWidgetPublisher.updateStore(
    at: fileURL,
    reloading: [MetricsWidgetKind.account],
    reload: { reloads.append($0) },
    update: {
      $0.upsert(
        accountSnapshot: makeAccountSnapshot(
          account: account,
          range: .day,
          total: 100,
          fetchedAt: Date(timeIntervalSince1970: 100)))
    })

  #expect(!changed)
  #expect(reloads.isEmpty)
  #expect(
    try MetricsWidgetSnapshotStore.load(from: fileURL)
      .accountSnapshot(accountID: account.id, range: .day)?
      .metric(.webTraffic)?.total == 200)
}

@Test @MainActor func metricsWidgetPublisherDoesNotReplaceMalformedStore() throws {
  let directory = FileManager.default.temporaryDirectory
    .appending(
      path: "dash-metrics-widget-corrupt-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory)
  let fileURL = directory.appending(path: MetricsWidgetSnapshotStore.filename)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true)
  let malformedData = Data("{not-json".utf8)
  try malformedData.write(to: fileURL, options: .atomic)
  var reloads: [[String]] = []

  let changed = MetricsWidgetPublisher.updateStore(
    at: fileURL,
    reloading: [MetricsWidgetKind.account],
    reload: { reloads.append($0) },
    update: {
      $0.setAccounts(
        [MetricsWidgetAccount(id: "account-a", name: "Account A")],
        activeAccountID: "account-a")
    })

  #expect(!changed)
  #expect(reloads.isEmpty)
  #expect(try Data(contentsOf: fileURL) == malformedData)
}

@Test @MainActor func metricsWidgetRepositoryDoesNotWaitForCompetingProcessLock() throws {
  let account = MetricsWidgetAccount(id: "account-a", name: "Account A")
  let directory = FileManager.default.temporaryDirectory
    .appending(
      path: "dash-metrics-widget-lock-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory)
  let fileURL = directory.appending(path: MetricsWidgetSnapshotStore.filename)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true)
  try MetricsWidgetSnapshotStore(accounts: [account]).write(to: fileURL)
  let originalData = try Data(contentsOf: fileURL)

  let lockURL = MetricsWidgetSnapshotRepository.lockFileURL(for: fileURL)
  let descriptor = lockURL.path.withCString {
    open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
  }
  #expect(descriptor >= 0)
  guard descriptor >= 0 else { return }
  defer { _ = close(descriptor) }
  #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
  defer { _ = flock(descriptor, LOCK_UN) }

  let changed = MetricsWidgetPublisher.updateStore(
    at: fileURL,
    reloading: [MetricsWidgetKind.account],
    reload: { _ in Issue.record("A failed update must not reload timelines") },
    update: {
      $0.setAccounts(
        [MetricsWidgetAccount(id: account.id, name: "Renamed")],
        activeAccountID: account.id)
    })

  #expect(!changed)
  expectMetricsWidgetRepositoryError(.lockUnavailable) {
    _ = try MetricsWidgetSnapshotRepository.invalidateAndClear(at: fileURL)
  }
  #expect(try Data(contentsOf: fileURL) == originalData)
}

@Test func metricsWidgetRepositoryMigratesLegacyNumericSessionState() throws {
  let account = MetricsWidgetAccount(id: "account-a", name: "Account A")
  let directory = FileManager.default.temporaryDirectory
    .appending(
      path: "dash-metrics-widget-legacy-session-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory)
  let fileURL = directory.appending(path: MetricsWidgetSnapshotStore.filename)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true)
  try MetricsWidgetSnapshotStore(accounts: [account]).write(to: fileURL)
  try Data("41\n".utf8).write(
    to: MetricsWidgetSnapshotRepository.generationFileURL(for: fileURL),
    options: .atomic)

  let legacy = try MetricsWidgetSnapshotRepository.read(at: fileURL)
  #expect(legacy.generation == 41)
  #expect(legacy.mode == .remoteEnabled)
  #expect(legacy.store?.accounts == [account])

  let changed = try MetricsWidgetSnapshotRepository.update(at: fileURL) { _ in }
  #expect(!changed)
  let migratedData = try Data(
    contentsOf: MetricsWidgetSnapshotRepository.generationFileURL(for: fileURL))
  #expect(String(decoding: migratedData, as: UTF8.self).hasPrefix("{"))
  let migrated = try MetricsWidgetSnapshotRepository.read(at: fileURL)
  #expect(migrated.generation == 41)
  #expect(migrated.mode == .remoteEnabled)
}

@Test func metricsWidgetRepositoryInvalidationHidesStoreAndIsIdempotent() throws {
  let account = MetricsWidgetAccount(id: "account-a", name: "Account A")
  let directory = FileManager.default.temporaryDirectory
    .appending(
      path: "dash-metrics-widget-generation-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory)
  let fileURL = directory.appending(path: MetricsWidgetSnapshotStore.filename)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true)
  try MetricsWidgetSnapshotStore(accounts: [account]).write(to: fileURL)

  let capturedGeneration = try MetricsWidgetSnapshotRepository.sessionGeneration(at: fileURL)
  let currentGeneration = try MetricsWidgetSnapshotRepository.invalidateAndClear(at: fileURL)
  #expect(currentGeneration == capturedGeneration + 1)
  #expect(!FileManager.default.fileExists(atPath: fileURL.path))

  do {
    _ = try MetricsWidgetSnapshotRepository.update(
      at: fileURL,
      expectedGeneration: capturedGeneration
    ) {
      $0.setAccounts([account], activeAccountID: account.id)
    }
    Issue.record("A response from the invalidated session must not recreate the store")
  } catch let error as MetricsWidgetSnapshotRepository.RepositoryError {
    #expect(
      error
        == .generationMismatch(
          expected: capturedGeneration,
          actual: currentGeneration))
  }
  #expect(!FileManager.default.fileExists(atPath: fileURL.path))

  // Even if deletion had failed after the tombstone write, readers must not
  // disclose the physical JSON and ordinary writes must not revive it.
  try JSONEncoder().encode(MetricsWidgetSnapshotStore(accounts: [account]))
    .write(to: fileURL, options: .atomic)
  let hidden = try MetricsWidgetSnapshotRepository.read(at: fileURL)
  #expect(hidden.mode == .invalidated)
  #expect(hidden.generation == currentGeneration)
  #expect(hidden.store == nil)
  expectMetricsWidgetRepositoryError(.sessionInvalidated) {
    _ = try MetricsWidgetSnapshotRepository.update(
      at: fileURL,
      expectedGeneration: currentGeneration
    ) {
      $0.setAccounts([account], activeAccountID: account.id)
    }
  }

  let repeatedGeneration = try MetricsWidgetSnapshotRepository.invalidateAndClear(at: fileURL)
  #expect(repeatedGeneration == currentGeneration)
  #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test func metricsWidgetRepositoryOldGenerationCannotDisableNewSession() throws {
  let firstAccount = MetricsWidgetAccount(id: "account-a", name: "Account A")
  let nextAccount = MetricsWidgetAccount(id: "account-b", name: "Account B")
  let directory = FileManager.default.temporaryDirectory
    .appending(
      path: "dash-metrics-widget-stale-clear-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory)
  let fileURL = directory.appending(path: MetricsWidgetSnapshotStore.filename)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true)

  let firstSession = try MetricsWidgetSnapshotRepository.activate(
    at: fileURL,
    mode: .remoteEnabled,
    store: MetricsWidgetSnapshotStore(accounts: [firstAccount]))
  _ = try MetricsWidgetSnapshotRepository.invalidateAndClear(
    at: fileURL,
    expectedGeneration: firstSession.generation)
  let nextSession = try MetricsWidgetSnapshotRepository.activate(
    at: fileURL,
    mode: .remoteEnabled,
    store: MetricsWidgetSnapshotStore(accounts: [nextAccount]))

  expectMetricsWidgetRepositoryError(
    .generationMismatch(
      expected: firstSession.generation,
      actual: nextSession.generation)
  ) {
    _ = try MetricsWidgetSnapshotRepository.invalidateAndClear(
      at: fileURL,
      expectedGeneration: firstSession.generation)
  }

  let current = try MetricsWidgetSnapshotRepository.read(at: fileURL)
  #expect(current.mode == .remoteEnabled)
  #expect(current.generation == nextSession.generation)
  #expect(current.store?.accounts == [nextAccount])
}

@Test func metricsWidgetRepositoryRepeatedActivationPreservesGenerationAndSnapshots() throws {
  let account = MetricsWidgetAccount(id: "account-a", name: "Account A")
  let directory = FileManager.default.temporaryDirectory
    .appending(
      path: "dash-metrics-widget-repeat-activation-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory)
  let fileURL = directory.appending(path: MetricsWidgetSnapshotStore.filename)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true)

  let first = try MetricsWidgetSnapshotRepository.activate(
    at: fileURL,
    mode: .remoteEnabled,
    store: MetricsWidgetSnapshotStore(
      activeAccountID: account.id,
      accounts: [account]))
  _ = try MetricsWidgetSnapshotRepository.update(
    at: fileURL,
    expectedGeneration: first.generation
  ) {
    $0.upsert(
      accountSnapshot: makeAccountSnapshot(
        account: account,
        range: .day,
        total: 99))
  }

  let renamed = MetricsWidgetAccount(id: account.id, name: "Renamed")
  let repeated = try MetricsWidgetSnapshotRepository.activate(
    at: fileURL,
    mode: .remoteEnabled,
    store: MetricsWidgetSnapshotStore(
      activeAccountID: renamed.id,
      accounts: [renamed]))

  #expect(repeated.generation == first.generation)
  #expect(repeated.mode == .remoteEnabled)
  #expect(repeated.store?.account(id: account.id)?.name == "Renamed")
  #expect(
    repeated.store?
      .accountSnapshot(accountID: account.id, range: .day)?
      .metric(.webTraffic)?.total == 99)
  #expect(
    repeated.store?
      .accountSnapshot(accountID: account.id, range: .day)?
      .accountName == "Renamed")
}

@Test func metricsWidgetRepositoryLocalOnlyAllowsAppWritesButRejectsRemoteWrites() throws {
  let account = MetricsWidgetAccount(id: "account-a", name: "Account A")
  let directory = FileManager.default.temporaryDirectory
    .appending(
      path: "dash-metrics-widget-local-session-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory)
  let fileURL = directory.appending(path: MetricsWidgetSnapshotStore.filename)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true)

  let session = try MetricsWidgetSnapshotRepository.activate(
    at: fileURL,
    mode: .localOnly,
    store: MetricsWidgetSnapshotStore(accounts: [account]))
  let appChanged = try MetricsWidgetSnapshotRepository.update(
    at: fileURL,
    expectedGeneration: session.generation
  ) {
    $0.setAccounts(
      [MetricsWidgetAccount(id: account.id, name: "Local update")],
      activeAccountID: account.id)
  }
  #expect(appChanged)

  expectMetricsWidgetRepositoryError(.remoteRefreshDisabled) {
    _ = try MetricsWidgetSnapshotRepository.update(
      at: fileURL,
      expectedGeneration: session.generation,
      requiresRemoteEnabled: true
    ) {
      $0.setAccounts(
        [MetricsWidgetAccount(id: account.id, name: "Remote update")],
        activeAccountID: account.id)
    }
  }
  let current = try MetricsWidgetSnapshotRepository.read(at: fileURL)
  #expect(current.mode == .localOnly)
  #expect(current.store?.account(id: account.id)?.name == "Local update")
}

@Test func metricsWidgetRepositoryActivationQuarantinesMalformedSnapshot() throws {
  let account = MetricsWidgetAccount(id: "account-a", name: "Account A")
  let directory = FileManager.default.temporaryDirectory
    .appending(
      path: "dash-metrics-widget-quarantine-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory)
  let fileURL = directory.appending(path: MetricsWidgetSnapshotStore.filename)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true)
  let malformedData = Data("{not-json".utf8)
  try malformedData.write(to: fileURL, options: .atomic)

  let activated = try MetricsWidgetSnapshotRepository.activate(
    at: fileURL,
    mode: .localOnly,
    store: MetricsWidgetSnapshotStore(
      activeAccountID: account.id,
      accounts: [account]))

  #expect(activated.mode == .localOnly)
  #expect(activated.store?.activeAccountID == account.id)
  #expect(
    try Data(
      contentsOf: MetricsWidgetSnapshotRepository.corruptSnapshotFileURL(for: fileURL))
      == malformedData)
  #expect(try MetricsWidgetSnapshotStore.load(from: fileURL).accounts == [account])
}

@Test func metricsWidgetRepositoryOnlyVerifiedActivationRepairsMalformedSession() throws {
  let account = MetricsWidgetAccount(id: "account-a", name: "Account A")
  let directory = FileManager.default.temporaryDirectory
    .appending(
      path: "dash-metrics-widget-malformed-session-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory)
  let fileURL = directory.appending(path: MetricsWidgetSnapshotStore.filename)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true)
  try JSONEncoder().encode(MetricsWidgetSnapshotStore(accounts: [account]))
    .write(to: fileURL, options: .atomic)
  try Data("{bad-session".utf8).write(
    to: MetricsWidgetSnapshotRepository.generationFileURL(for: fileURL),
    options: .atomic)

  expectMetricsWidgetRepositoryError(.invalidSessionState) {
    _ = try MetricsWidgetSnapshotRepository.read(at: fileURL)
  }
  expectMetricsWidgetRepositoryError(.invalidSessionState) {
    _ = try MetricsWidgetSnapshotRepository.update(at: fileURL) { _ in }
  }
  expectMetricsWidgetRepositoryError(.invalidSessionState) {
    _ = try MetricsWidgetSnapshotRepository.invalidateAndClear(at: fileURL)
  }

  let activated = try MetricsWidgetSnapshotRepository.activate(
    at: fileURL,
    mode: .remoteEnabled,
    store: MetricsWidgetSnapshotStore(
      activeAccountID: account.id,
      accounts: [account]))
  #expect(activated.mode == .remoteEnabled)
  #expect(activated.generation != 0)
  let repaired = try MetricsWidgetSnapshotRepository.read(at: fileURL)
  #expect(repaired.mode == .remoteEnabled)
  #expect(repaired.generation == activated.generation)
  #expect(repaired.store?.accounts == [account])
}

@Test func metricsWidgetStoreKeepsNewestThirtyTwoDomainScopesAndAllTheirRanges() {
  let account = MetricsWidgetAccount(id: "account-a", name: "Account A")
  var snapshots = (0..<35).map { index in
    makeDomainSnapshot(
      account: account,
      domainID: String(format: "zone-%02d", index),
      range: .day,
      total: Double(index),
      fetchedAt: Date(timeIntervalSince1970: TimeInterval(index)))
  }
  snapshots.append(
    makeDomainSnapshot(
      account: account,
      domainID: "zone-34",
      range: .week,
      total: 340,
      fetchedAt: Date(timeIntervalSince1970: 34.5)))

  let store = MetricsWidgetSnapshotStore(
    accounts: [account],
    domainSnapshots: snapshots)
  let retainedScopeIDs = Set(
    store.domainSnapshots.map {
      MetricsWidgetDomain.scopedID(
        accountID: $0.accountID,
        domainID: $0.domainID)
    })

  #expect(retainedScopeIDs.count == MetricsWidgetSnapshotStore.maximumDomainScopes)
  #expect(store.domainSnapshots.count == MetricsWidgetSnapshotStore.maximumDomainScopes + 1)
  #expect(!retainedScopeIDs.contains("account-a:zone-00"))
  #expect(!retainedScopeIDs.contains("account-a:zone-01"))
  #expect(!retainedScopeIDs.contains("account-a:zone-02"))
  #expect(retainedScopeIDs.contains("account-a:zone-03"))
  #expect(retainedScopeIDs.contains("account-a:zone-34"))
  #expect(
    store.domainSnapshots
      .filter { $0.domainID == "zone-34" }
      .map(\.range) == [.day, .week])
}

private func makeAccountSnapshot(
  account: MetricsWidgetAccount,
  range: MetricsWidgetRange,
  total: Double,
  fetchedAt: Date = Date(timeIntervalSince1970: 100)
) -> AccountMetricsWidgetSnapshot {
  AccountMetricsWidgetSnapshot(
    accountID: account.id,
    accountName: account.name,
    range: range,
    metrics: [
      MetricsWidgetMetricSnapshot(
        metric: .webTraffic,
        total: total,
        points: [])
    ],
    fetchedAt: fetchedAt)
}

private func expectMetricsWidgetRepositoryError(
  _ expected: MetricsWidgetSnapshotRepository.RepositoryError,
  performing operation: () throws -> Void
) {
  do {
    try operation()
    Issue.record("Expected repository error \(expected)")
  } catch let error as MetricsWidgetSnapshotRepository.RepositoryError {
    #expect(error == expected)
  } catch {
    Issue.record("Expected repository error \(expected), got \(error)")
  }
}

private func makeDomain(
  account: MetricsWidgetAccount,
  id: String,
  name: String? = nil
) -> MetricsWidgetDomain {
  MetricsWidgetDomain(
    id: id,
    name: name ?? id,
    accountID: account.id,
    accountName: account.name,
    avatarSeed: id)
}

private func makeDomainSnapshot(
  account: MetricsWidgetAccount,
  domainID: String,
  domainName: String? = nil,
  range: MetricsWidgetRange,
  total: Double = 0,
  metrics: [MetricsWidgetMetricSnapshot]? = nil,
  fetchedAt: Date = Date(timeIntervalSince1970: 100)
) -> DomainMetricsWidgetSnapshot {
  DomainMetricsWidgetSnapshot(
    domainID: domainID,
    domainName: domainName ?? domainID,
    accountID: account.id,
    accountName: account.name,
    avatarSeed: domainID,
    range: range,
    metrics: metrics ?? [
      MetricsWidgetMetricSnapshot(
        metric: .requests,
        total: total,
        points: [])
    ],
    fetchedAt: fetchedAt)
}
