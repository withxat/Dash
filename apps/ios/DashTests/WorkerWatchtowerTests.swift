import CloudflareAPI
import Foundation
import Testing

@testable import Dash

@Test func fullPageLoaderRequestsFiftyUntilTotalOrShortPage() async throws {
  let zones = try makeZones(count: 120)
  let recorder = PageRequestRecorder()

  let loaded = try await DashPageLoader.loadAll(pageSize: 50, id: \.id) { page, perPage in
    await recorder.record(page: page, perPage: perPage)
    let start = (page - 1) * perPage
    let end = min(start + perPage, zones.count)
    let items = start < end ? Array(zones[start..<end]) : []
    return Page(
      items: items,
      resultInfo: ResultInfo(page: page, perPage: perPage, totalCount: zones.count))
  }

  #expect(loaded.map(\.id) == zones.map(\.id))
  let requestedPages = await recorder.pages
  let requestedPageSizes = await recorder.pageSizes
  #expect(requestedPages == [1, 2, 3])
  #expect(requestedPageSizes == [50, 50, 50])
}

@Test func fullPageLoaderStopsOnEmptyPage() async throws {
  let recorder = PageRequestRecorder()
  let loaded: [CloudflareZone] = try await DashPageLoader.loadAll(pageSize: 50, id: \.id) {
    page,
    perPage in
    await recorder.record(page: page, perPage: perPage)
    return Page(items: [], resultInfo: ResultInfo(page: page, perPage: perPage))
  }

  #expect(loaded.isEmpty)
  let requestedPages = await recorder.pages
  #expect(requestedPages == [1])
}

@Test func fullPageLoaderStopsOnShortPageWithoutTotal() async throws {
  let zones = try makeZones(count: 7)
  let recorder = PageRequestRecorder()
  let loaded = try await DashPageLoader.loadAll(pageSize: 50, id: \.id) { page, perPage in
    await recorder.record(page: page, perPage: perPage)
    return Page(items: zones, resultInfo: ResultInfo(page: page, perPage: perPage))
  }

  #expect(loaded.map(\.id) == zones.map(\.id))
  let requestedPages = await recorder.pages
  #expect(requestedPages == [1])
}

@Test func fullPageLoaderStopsWhenTotalIsReachedByAFullPage() async throws {
  let zones = try makeZones(count: 50)
  let recorder = PageRequestRecorder()
  let loaded = try await DashPageLoader.loadAll(pageSize: 50, id: \.id) { page, perPage in
    await recorder.record(page: page, perPage: perPage)
    return Page(
      items: zones,
      resultInfo: ResultInfo(page: page, perPage: perPage, totalCount: zones.count))
  }

  #expect(loaded.count == 50)
  let requestedPages = await recorder.pages
  #expect(requestedPages == [1])
}

@Test func fullPageLoaderDoesNotTrustARepeatedReportedPageOverNewIDs() async throws {
  let zones = try makeZones(count: 100)
  let recorder = PageRequestRecorder()
  let loaded = try await DashPageLoader.loadAll(pageSize: 50, id: \.id) { page, perPage in
    await recorder.record(page: page, perPage: perPage)
    let items = page == 1 ? Array(zones[0..<50]) : Array(zones[50..<100])
    return Page(
      items: items,
      resultInfo: ResultInfo(page: 1, perPage: perPage, totalCount: zones.count))
  }

  #expect(loaded.map(\.id) == zones.map(\.id))
  let requestedPages = await recorder.pages
  #expect(requestedPages == [1, 2])
}

@Test func fullPageLoaderUsesTheServerEffectivePageSize() async throws {
  let zones = try makeZones(count: 45)
  let recorder = PageRequestRecorder()
  let serverPageSize = 20
  let loaded = try await DashPageLoader.loadAll(pageSize: 50, id: \.id) { page, requestedSize in
    await recorder.record(page: page, perPage: requestedSize)
    let start = (page - 1) * serverPageSize
    let end = min(start + serverPageSize, zones.count)
    let items = start < end ? Array(zones[start..<end]) : []
    return Page(
      items: items,
      resultInfo: ResultInfo(
        page: page,
        perPage: serverPageSize,
        totalCount: zones.count))
  }

  #expect(loaded.map(\.id) == zones.map(\.id))
  let requestedPages = await recorder.pages
  #expect(requestedPages == [1, 2, 3])
}

@Test func fullPageLoaderStopsWhenAResponseContainsNoNewIDs() async throws {
  let zones = try makeZones(count: 50)
  let recorder = PageRequestRecorder()
  let loaded = try await DashPageLoader.loadAll(pageSize: 50, id: \.id) { page, perPage in
    await recorder.record(page: page, perPage: perPage)
    return Page(items: zones)
  }

  #expect(loaded.count == 50)
  let requestedPages = await recorder.pages
  #expect(requestedPages == [1, 2])
}

@Test func fullPageLoaderPropagatesCancellation() async throws {
  let task = Task {
    try await DashPageLoader.loadAll(pageSize: 50, id: \.id) {
      (_: Int, _: Int) async throws -> Page<CloudflareZone> in
      try await Task.sleep(for: .seconds(30))
      return Page(items: [])
    }
  }
  await Task.yield()
  task.cancel()

  do {
    _ = try await task.value
    Issue.record("Expected cancellation to leave the page loader")
  } catch is CancellationError {
    // Expected.
  }
}

@Test @MainActor func watchtowerTrafficRejectsAStaleGenerationForTheSameAccount() async throws {
  let defaultsKey = "dash.active_account_id"
  let previousAccountID = UserDefaults.standard.string(forKey: defaultsKey)
  UserDefaults.standard.removeObject(forKey: defaultsKey)
  defer {
    if let previousAccountID {
      UserDefaults.standard.set(previousAccountID, forKey: defaultsKey)
    } else {
      UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
  }

  let accounts = try JSONDecoder().decode(
    [CloudflareAccount].self,
    from: Data(
      """
      [
        {"id":"traffic-a","name":"Traffic A"},
        {"id":"traffic-b","name":"Traffic B"}
      ]
      """.utf8))
  let model = AppModel(configuration: AppConfiguration(clientID: "", redirectURI: ""))
  model.grantedScopes = []
  let state = WatchtowerTrafficState()

  model.selectAccount(accounts[0])
  await state.load(model: model)
  state.snapshots[.day] = WatchtowerAnalyticsChartModel.Snapshot(
    overview: AccountAnalyticsOverview(
      webRequests: 1,
      bytes: 1,
      cacheRate: 0,
      clientErrorRate: 0,
      encryptedRequestRate: 0,
      encryptedBytes: 0,
      workerInvocations: 0,
      workerErrors: 0,
      cpuTimeP90Us: 0,
      hours: 24),
    charts: [:],
    fetchedAt: .now)

  model.selectAccount(accounts[1])
  model.selectAccount(accounts[0])
  await state.load(model: model)

  #expect(state.snapshots.isEmpty)
  #expect(state.needsAnalyticsAccess)
}

@Test func workerDetailStartsIndependentTopLevelRequestsConcurrently() async throws {
  let topProbe = ConcurrencyProbe(delay: .milliseconds(80))
  let routeProbe = ConcurrencyProbe(delay: .zero)
  let client = WorkerDetailClientStub(
    zones: try makeZones(count: 1),
    topProbe: topProbe,
    routeProbe: routeProbe)

  let result = try await WorkerDetailLoader.load(
    client: client, accountID: "account", name: "worker")

  let maximumConcurrency = await topProbe.maximum
  #expect(maximumConcurrency == 5)
  #expect(
    result.completeSnapshot(
      routes: WorkerRoutesLoad(routes: [], isComplete: true, failureMessage: nil)) != nil)
}

@Test func workerRoutesUseASlidingWindowOfFour() async throws {
  let topProbe = ConcurrencyProbe(delay: .zero)
  let routeProbe = ConcurrencyProbe(delay: .milliseconds(40))
  let client = WorkerDetailClientStub(
    zones: try makeZones(count: 13),
    topProbe: topProbe,
    routeProbe: routeProbe)

  let result = try await WorkerDetailLoader.loadRoutes(client: client, accountID: "account")

  let maximumConcurrency = await routeProbe.maximum
  #expect(maximumConcurrency == WorkerDetailLoader.routeConcurrencyLimit)
  #expect(result.routes.count == 13)
  #expect(result.isComplete)
}

@Test func partialWorkerRoutesRemainVisibleButCannotProduceACacheSnapshot() async throws {
  let topProbe = ConcurrencyProbe(delay: .zero)
  let routeProbe = ConcurrencyProbe(delay: .milliseconds(10))
  let client = WorkerDetailClientStub(
    zones: try makeZones(count: 6),
    failingZoneIDs: ["zone-3"],
    topProbe: topProbe,
    routeProbe: routeProbe)

  let primary = try await WorkerDetailLoader.load(
    client: client, accountID: "account", name: "worker")
  let result = try await WorkerDetailLoader.loadRoutes(client: client, accountID: "account")

  #expect(result.routes.count == 5)
  #expect(!result.isComplete)
  #expect(result.failureMessage != nil)
  #expect(primary.completeSnapshot(routes: result) == nil)
}

@Test func workerDetailLoaderPropagatesCancellation() async throws {
  let client = WorkerDetailClientStub(
    zones: try makeZones(count: 2),
    topProbe: ConcurrencyProbe(delay: .seconds(30)),
    routeProbe: ConcurrencyProbe(delay: .seconds(30)))
  let task = Task {
    try await WorkerDetailLoader.load(
      client: client, accountID: "account", name: "worker")
  }
  await Task.yield()
  task.cancel()

  do {
    _ = try await task.value
    Issue.record("Expected cancellation to leave the Worker detail loader")
  } catch is CancellationError {
    // Expected.
  }
}

@Test func workerRoutesPropagateCancellation() async throws {
  let client = WorkerDetailClientStub(
    zones: try makeZones(count: 2),
    topProbe: ConcurrencyProbe(delay: .zero),
    routeProbe: ConcurrencyProbe(delay: .seconds(30)))
  let task = Task {
    try await WorkerDetailLoader.loadRoutes(client: client, accountID: "account")
  }
  await Task.yield()
  task.cancel()

  do {
    _ = try await task.value
    Issue.record("Expected cancellation to leave the Worker routes loader")
  } catch is CancellationError {
    // Expected.
  }
}

@Test func incompleteWorkerRoutesPreserveWarmContent() {
  let warm = [
    WorkerZoneRoute(
      id: "warm-route",
      pattern: "warm.example.com/*",
      script: "worker",
      zoneName: "example.com")
  ]
  let failedRefresh = WorkerRoutesLoad(
    routes: [],
    isComplete: false,
    failureMessage: "offline")

  #expect(failedRefresh.presentedRoutes(for: "worker", preserving: warm) == warm)
  #expect(failedRefresh.failureMessage == "offline")
}

private actor PageRequestRecorder {
  private(set) var pages: [Int] = []
  private(set) var pageSizes: [Int] = []

  func record(page: Int, perPage: Int) {
    pages.append(page)
    pageSizes.append(perPage)
  }
}

private actor ConcurrencyProbe {
  private let delay: Duration
  private var active = 0
  private(set) var maximum = 0
  private(set) var invocations = 0

  init(delay: Duration) {
    self.delay = delay
  }

  func run<Value: Sendable>(_ value: Value) async throws -> Value {
    invocations += 1
    active += 1
    maximum = max(maximum, active)
    defer { active -= 1 }
    if delay > .zero {
      try await Task.sleep(for: delay)
    }
    return value
  }
}

private actor WorkerDetailClientStub: WorkerDetailClient {
  private let zones: [CloudflareZone]
  private let failingZoneIDs: Set<String>
  private let topProbe: ConcurrencyProbe
  private let routeProbe: ConcurrencyProbe

  init(
    zones: [CloudflareZone],
    failingZoneIDs: Set<String> = [],
    topProbe: ConcurrencyProbe,
    routeProbe: ConcurrencyProbe
  ) {
    self.zones = zones
    self.failingZoneIDs = failingZoneIDs
    self.topProbe = topProbe
    self.routeProbe = routeProbe
  }

  func getWorkerSubdomain(accountID: String, name: String) async throws
    -> WorkerSubdomainStatus
  {
    try await topProbe.run(
      JSONDecoder().decode(
        WorkerSubdomainStatus.self, from: Data(#"{"enabled":true}"#.utf8)))
  }

  func getWorkersAccountSubdomain(accountID: String) async throws -> WorkersAccountSubdomain {
    try await topProbe.run(WorkersAccountSubdomain(subdomain: "example"))
  }

  func listWorkerDeployments(accountID: String, scriptName: String) async throws
    -> [WorkerDeploymentSummary]
  {
    try await topProbe.run([
      WorkerDeploymentSummary(
        id: "deployment", createdOn: "2026-07-24T00:00:00Z", source: "api")
    ])
  }

  func workerAnalytics(accountID: String, scriptName: String, hours: Int) async throws
    -> WorkerAnalyticsPayload
  {
    try await topProbe.run(
      WorkerAnalyticsPayload(requests: 1, errors: 0, cpuTimeP50Us: 10, points: []))
  }

  func listWorkerDomains(accountID: String, service: String?) async throws -> [WorkerDomain] {
    try await topProbe.run([
      WorkerDomain(
        id: "domain", hostname: "worker.example.com", service: service ?? "worker",
        zoneID: "zone-0", zoneName: "example.com")
    ])
  }

  func listZones(accountID: String, page: Int, perPage: Int, name: String?) async throws
    -> Page<CloudflareZone>
  {
    let start = (page - 1) * perPage
    let end = min(start + perPage, zones.count)
    let items = start < end ? Array(zones[start..<end]) : []
    return try await topProbe.run(
      Page(
        items: items,
        resultInfo: ResultInfo(
          page: page, perPage: perPage, totalCount: zones.count)))
  }

  func listWorkerRoutes(zoneID: String) async throws -> [WorkerRoute] {
    if failingZoneIDs.contains(zoneID) {
      _ = try await routeProbe.run(())
      throw WorkerDetailStubError.failedRoute
    }
    return try await routeProbe.run([
      WorkerRoute(id: "route-\(zoneID)", pattern: "\(zoneID).example.com/*", script: "worker")
    ])
  }
}

private enum WorkerDetailStubError: Error {
  case failedRoute
}

private func makeZones(count: Int) throws -> [CloudflareZone] {
  let rows = (0..<count).map { index in
    #"{"id":"zone-\#(index)","name":"zone-\#(index).example.com","status":"active"}"#
  }
  return try JSONDecoder().decode(
    [CloudflareZone].self,
    from: Data("[\(rows.joined(separator: ","))]".utf8))
}
