import CloudflareAPI
import Foundation
import Testing

@testable import Dash

@Test func pagesBuildRefreshDispositionClassifiesCancellationAndHTTPFailures() {
  #expect(PagesBuildRefreshDisposition.classify(CancellationError()) == .cancel)
  #expect(PagesBuildRefreshDisposition.classify(URLError(.cancelled)) == .cancel)
  #expect(
    PagesBuildRefreshDisposition.classify(
      CloudflareAPIError.request(status: 401, errors: [])) == .stop)
  #expect(
    PagesBuildRefreshDisposition.classify(
      CloudflareAPIError.request(status: 403, errors: [])) == .stop)
  #expect(
    PagesBuildRefreshDisposition.classify(
      CloudflareAPIError.request(status: 404, errors: [])) == .stop)
  #expect(
    PagesBuildRefreshDisposition.classify(
      CloudflareAPIError.request(status: 408, errors: [])) == .retry)
  #expect(
    PagesBuildRefreshDisposition.classify(
      CloudflareAPIError.request(status: 429, errors: [])) == .retry)
  #expect(
    PagesBuildRefreshDisposition.classify(
      CloudflareAPIError.request(status: 503, errors: [])) == .retry)
  #expect(
    PagesBuildRefreshDisposition.classify(CloudflareAPIError.transport("offline")) == .retry)
  #expect(
    PagesBuildRefreshDisposition.classify(CloudflareAPIError.oauth("invalid_grant")) == .stop)
}

@Test func pagesBuildRetryDelayIsExponentiallyBounded() {
  #expect(PagesBuildRefreshDisposition.retryDelaySeconds(consecutiveFailures: -1) == 10)
  #expect(PagesBuildRefreshDisposition.retryDelaySeconds(consecutiveFailures: 0) == 10)
  #expect(PagesBuildRefreshDisposition.retryDelaySeconds(consecutiveFailures: 1) == 20)
  #expect(PagesBuildRefreshDisposition.retryDelaySeconds(consecutiveFailures: 2) == 40)
  #expect(PagesBuildRefreshDisposition.retryDelaySeconds(consecutiveFailures: 3) == 60)
  #expect(PagesBuildRefreshDisposition.retryDelaySeconds(consecutiveFailures: 20) == 60)
}

@Test func pagesBuildLogsRefreshOnlyInitiallyManuallyOrAtTerminalTransition() {
  #expect(
    PagesBuildLogRefreshPolicy.shouldRefresh(
      hasRequestedLogs: false,
      previousWasInProgress: true,
      latestIsInProgress: true,
      source: .initial))
  #expect(
    !PagesBuildLogRefreshPolicy.shouldRefresh(
      hasRequestedLogs: true,
      previousWasInProgress: true,
      latestIsInProgress: true,
      source: .poll))
  #expect(
    PagesBuildLogRefreshPolicy.shouldRefresh(
      hasRequestedLogs: true,
      previousWasInProgress: true,
      latestIsInProgress: true,
      source: .manual))
  #expect(
    PagesBuildLogRefreshPolicy.shouldRefresh(
      hasRequestedLogs: true,
      previousWasInProgress: true,
      latestIsInProgress: false,
      source: .poll))
  #expect(
    !PagesBuildLogRefreshPolicy.shouldRefresh(
      hasRequestedLogs: true,
      previousWasInProgress: false,
      latestIsInProgress: false,
      source: .poll))
}

@Test func pagesBuildAttributesDecodeLegacyActivitiesWithoutAnAccount() throws {
  let legacy = try JSONDecoder().decode(
    PagesBuildAttributes.self,
    from: Data(
      """
      {"projectName":"site","deploymentID":"deployment-1"}
      """.utf8))
  #expect(legacy.accountID == nil)
  #expect(legacy.projectName == "site")
  #expect(legacy.deploymentID == "deployment-1")

  let current = PagesBuildAttributes(
    accountID: "account-1",
    projectName: "site",
    deploymentID: "deployment-1")
  let roundTrip = try JSONDecoder().decode(
    PagesBuildAttributes.self,
    from: JSONEncoder().encode(current))
  #expect(roundTrip.accountID == "account-1")
}

@Test func pagesBuildMonitorKeyIncludesAccountGeneration() {
  let first = PagesBuildMonitorKey(
    accountID: "account",
    accountGeneration: 1,
    projectName: "site",
    deploymentID: "deployment")
  let laterVisit = PagesBuildMonitorKey(
    accountID: "account",
    accountGeneration: 3,
    projectName: "site",
    deploymentID: "deployment")

  #expect(first != laterVisit)
}

@Test @MainActor func pagesBuildRefreshSingleFlightAppliesAndBroadcastsSuccessOnce() async throws {
  let fetchProbe = PagesBuildFetchProbe()
  let controller = PagesBuildActivityControllerBox { _, _ in
    try await fetchProbe.fetch()
  }
  let client = CloudflareClient(clientID: "test", tokenStore: DemoTokenStore())
  let key = PagesBuildMonitorKey(
    accountID: "account",
    accountGeneration: 1,
    projectName: "site",
    deploymentID: "deployment")
  let eventProbe = PagesBuildEventProbe()
  let stream = controller.updates(for: key, client: client)
  let observer = Task {
    for await event in stream {
      await eventProbe.record(event)
    }
  }
  defer {
    observer.cancel()
    controller.invalidateSession()
  }

  let background = Task { @MainActor in
    await controller.refresh(key: key, client: client, source: .background)
  }
  while await fetchProbe.startCount == 0 {
    await Task.yield()
  }
  let manual = Task { @MainActor in
    await controller.refresh(key: key, client: client, source: .manual)
  }
  while controller.debugRefreshWaiterCount(for: key) < 2 {
    await Task.yield()
  }

  await fetchProbe.complete(.success(try pagesDeploymentFixture()))
  await background.value
  await manual.value
  await waitForPagesBuildEvents(eventProbe, count: 1)
  for _ in 0..<10 { await Task.yield() }

  #expect(await fetchProbe.startCount == 1)
  let events = await eventProbe.events
  #expect(events.count == 1)
  if case .some(.deployment(let deployment, let source)) = events.first {
    #expect(deployment.id == key.deploymentID)
    #expect(source == .manual)
  } else {
    Issue.record("Expected one deployment event")
  }
}

@Test @MainActor func pagesBuildRefreshSingleFlightCountsAndBroadcastsFailureOnce() async {
  let fetchProbe = PagesBuildFetchProbe()
  let controller = PagesBuildActivityControllerBox { _, _ in
    try await fetchProbe.fetch()
  }
  let client = CloudflareClient(clientID: "test", tokenStore: DemoTokenStore())
  let key = PagesBuildMonitorKey(
    accountID: "account",
    accountGeneration: 1,
    projectName: "site",
    deploymentID: "deployment")
  let eventProbe = PagesBuildEventProbe()
  let stream = controller.updates(for: key, client: client)
  let observer = Task {
    for await event in stream {
      await eventProbe.record(event)
    }
  }
  defer {
    observer.cancel()
    controller.invalidateSession()
  }

  let poll = Task { @MainActor in
    await controller.refresh(key: key, client: client, source: .poll)
  }
  while await fetchProbe.startCount == 0 {
    await Task.yield()
  }
  let initial = Task { @MainActor in
    await controller.refresh(key: key, client: client, source: .initial)
  }
  while controller.debugRefreshWaiterCount(for: key) < 2 {
    await Task.yield()
  }

  await fetchProbe.complete(.failure(CloudflareAPIError.transport("offline")))
  await poll.value
  await initial.value
  await waitForPagesBuildEvents(eventProbe, count: 1)
  for _ in 0..<10 { await Task.yield() }

  #expect(await fetchProbe.startCount == 1)
  #expect(controller.debugConsecutiveFailureCount(for: key) == 1)
  let events = await eventProbe.events
  #expect(events.count == 1)
  if case .some(.failure(_, let terminal, let source)) = events.first {
    #expect(!terminal)
    #expect(source == .initial)
  } else {
    Issue.record("Expected one failure event")
  }
}

private actor PagesBuildFetchProbe {
  private(set) var startCount = 0
  private var continuation: CheckedContinuation<PagesDeployment, any Error>?

  func fetch() async throws -> PagesDeployment {
    startCount += 1
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func complete(_ result: Result<PagesDeployment, any Error>) {
    continuation?.resume(with: result)
    continuation = nil
  }
}

private actor PagesBuildEventProbe {
  private(set) var events: [PagesBuildMonitorEvent] = []

  func record(_ event: PagesBuildMonitorEvent) {
    events.append(event)
  }
}

private func waitForPagesBuildEvents(
  _ probe: PagesBuildEventProbe,
  count: Int
) async {
  for _ in 0..<100 {
    if await probe.events.count >= count { return }
    await Task.yield()
  }
}

private func pagesDeploymentFixture() throws -> PagesDeployment {
  try JSONDecoder().decode(
    PagesDeployment.self,
    from: Data(
      """
      {
        "id": "deployment",
        "short_id": "deploy",
        "environment": "production",
        "latest_stage": {"name": "deploy", "status": "success"}
      }
      """.utf8))
}
