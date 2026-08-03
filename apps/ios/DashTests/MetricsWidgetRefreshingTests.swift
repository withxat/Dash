import CloudflareAPI
import Foundation
import Testing

@testable import Dash

@Test func metricsWidgetRefreshPolicyUsesAdaptiveStableJitter() {
  #expect(MetricsWidgetRefreshPolicy.refreshInterval(for: .day) == 30 * 60)
  #expect(MetricsWidgetRefreshPolicy.refreshInterval(for: .week) == 60 * 60)
  #expect(MetricsWidgetRefreshPolicy.refreshInterval(for: .month) == 3 * 60 * 60)
  #expect(MetricsWidgetRange.day.accountAnalyticsGranularity == .hour)
  #expect(MetricsWidgetRange.week.accountAnalyticsGranularity == .hour)
  #expect(MetricsWidgetRange.month.accountAnalyticsGranularity == .day)

  let now = Date(timeIntervalSince1970: 10_000)
  let first = MetricsWidgetRefreshPolicy.nextReloadDate(
    after: now,
    fetchedAt: now,
    range: .day,
    seed: "account:a:day")
  let second = MetricsWidgetRefreshPolicy.nextReloadDate(
    after: now,
    fetchedAt: now,
    range: .day,
    seed: "account:a:day")
  let delay = first.timeIntervalSince(now)
  #expect(first == second)
  #expect(delay >= 30 * 60)
  #expect(delay <= 33 * 60)

  let earlyVisibility = MetricsWidgetRefreshPolicy.nextReloadDate(
    after: now.addingTimeInterval(10 * 60),
    fetchedAt: now,
    range: .day,
    seed: "account:a:day")
  #expect(earlyVisibility == first)

  let overdueRetry = MetricsWidgetRefreshPolicy.nextReloadDate(
    after: now,
    fetchedAt: now.addingTimeInterval(-60 * 60),
    range: .day,
    seed: "account:a:day")
  #expect(overdueRetry == now.addingTimeInterval(15 * 60))

  let firstLoadRetry = MetricsWidgetRefreshPolicy.nextReloadDate(
    after: now,
    range: .month,
    seed: "account:a:month")
  #expect(firstLoadRetry == now.addingTimeInterval(15 * 60))
}

@Test func metricsWidgetRefreshPolicySkipsFreshAndRefreshesMissingOrExpired() {
  let now = Date(timeIntervalSince1970: 10_000)
  #expect(
    !MetricsWidgetRefreshPolicy.needsRefresh(
      fetchedAt: now.addingTimeInterval(-(30 * 60 - 1)),
      range: .day,
      now: now))
  #expect(
    MetricsWidgetRefreshPolicy.needsRefresh(
      fetchedAt: now.addingTimeInterval(-30 * 60),
      range: .day,
      now: now))
  #expect(
    !MetricsWidgetRefreshPolicy.needsRefresh(
      fetchedAt: now.addingTimeInterval(60),
      range: .day,
      now: now))
  #expect(
    MetricsWidgetRefreshPolicy.needsRefresh(
      fetchedAt: nil,
      range: .month,
      now: now))
}

@Test func metricsWidgetRefreshCoordinatorDoesNotLoadFreshSnapshot() async {
  let probe = MetricsWidgetRefreshProbe()
  let account = MetricsWidgetAccount(id: "account", name: "Account")
  let now = Date(timeIntervalSince1970: 10_000)
  let snapshot = makeRemoteAccountWidgetSnapshot(
    account: account,
    range: .day,
    fetchedAt: now.addingTimeInterval(-60))
  let store = MetricsWidgetSnapshotStore(
    accounts: [account],
    accountSnapshots: [snapshot])
  let coordinator = MetricsWidgetRemoteRefreshCoordinator(
    loader: { target in
      await probe.begin()
      await probe.end()
      return makeRemoteAccountPayload(for: target)
    },
    persister: { _, _ in })

  let outcome = await coordinator.refreshIfNeeded(
    .account(
      accountID: account.id,
      accountName: account.name,
      range: .day,
      resolvesMetadata: false),
    baseline: MetricsWidgetRefreshBaseline(store: store, generation: 7),
    now: now)

  #expect(outcome == .fresh)
  #expect(await probe.started == 0)
}

@Test func metricsWidgetRefreshCoordinatorNeverSendsDemoIDsToCloudflare() async {
  let probe = MetricsWidgetRefreshProbe()
  let coordinator = MetricsWidgetRemoteRefreshCoordinator(
    loader: { target in
      await probe.begin()
      await probe.end()
      return makeRemoteAccountPayload(for: target)
    },
    persister: { _, _ in })

  let outcome = await coordinator.refreshIfNeeded(
    .account(
      accountID: "demo-account-studio",
      accountName: "Foxglove Studio",
      range: .day,
      resolvesMetadata: false),
    baseline: MetricsWidgetRefreshBaseline(store: nil, generation: 0),
    now: .now)

  #expect(outcome == .fallback)
  #expect(await probe.started == 0)
}

@Test func metricsWidgetRefreshCoordinatorSingleFlightsIdenticalScopes() async {
  let probe = MetricsWidgetRefreshProbe()
  let target = MetricsWidgetRefreshTarget.account(
    accountID: "account",
    accountName: "Account",
    range: .day,
    resolvesMetadata: false)
  let coordinator = MetricsWidgetRemoteRefreshCoordinator(
    loader: { target in
      await probe.begin()
      do {
        try await Task.sleep(for: .milliseconds(60))
        await probe.end()
        return makeRemoteAccountPayload(for: target)
      } catch {
        await probe.end()
        throw error
      }
    },
    persister: { _, _ in })

  let outcomes = await withTaskGroup(
    of: MetricsWidgetRefreshOutcome.self,
    returning: [MetricsWidgetRefreshOutcome].self
  ) { group in
    for _ in 0..<4 {
      group.addTask {
        await coordinator.refreshIfNeeded(
          target,
          baseline: MetricsWidgetRefreshBaseline(store: nil, generation: 3),
          now: .now)
      }
    }
    return await group.reduce(into: []) { $0.append($1) }
  }

  #expect(outcomes.count == 4)
  #expect(outcomes.allSatisfy { $0 == .refreshed })
  #expect(await probe.started == 1)
  #expect(await probe.maximumActive == 1)
}

@Test func cancellingOneSingleFlightJoinerKeepsActiveJoinerRunning() async {
  let probe = MetricsWidgetRefreshProbe()
  let target = MetricsWidgetRefreshTarget.account(
    accountID: "account",
    accountName: "Account",
    range: .day,
    resolvesMetadata: false)
  let coordinator = MetricsWidgetRemoteRefreshCoordinator(
    loader: { target in
      await probe.begin()
      do {
        try await Task.sleep(for: .milliseconds(200))
        await probe.end()
        return makeRemoteAccountPayload(for: target)
      } catch {
        await probe.end()
        throw error
      }
    },
    persister: { _, _ in })
  let baseline = MetricsWidgetRefreshBaseline(store: nil, generation: 3)
  let active = Task {
    await coordinator.refreshIfNeeded(target, baseline: baseline, now: .now)
  }
  #expect(await probe.waitUntilStarted(1))
  let cancelled = Task {
    await coordinator.refreshIfNeeded(target, baseline: baseline, now: .now)
  }
  try? await Task.sleep(for: .milliseconds(10))
  let clock = ContinuousClock()
  let cancelledAt = clock.now
  cancelled.cancel()

  #expect(await cancelled.value == .fallback)
  #expect(cancelledAt.duration(to: clock.now) < .milliseconds(100))
  #expect(await probe.active == 1)
  #expect(await active.value == .refreshed)
  #expect(await probe.started == 1)
}

@Test func metricsWidgetRefreshCoordinatorCapsDistinctScopesAtTwo() async {
  let probe = MetricsWidgetRefreshProbe()
  let coordinator = MetricsWidgetRemoteRefreshCoordinator(
    maximumConcurrentRequests: 2,
    loader: { target in
      await probe.begin()
      do {
        try await Task.sleep(for: .milliseconds(60))
        await probe.end()
        return makeRemoteAccountPayload(for: target)
      } catch {
        await probe.end()
        throw error
      }
    },
    persister: { _, _ in })

  let outcomes = await withTaskGroup(
    of: MetricsWidgetRefreshOutcome.self,
    returning: [MetricsWidgetRefreshOutcome].self
  ) { group in
    for index in 0..<5 {
      group.addTask {
        await coordinator.refreshIfNeeded(
          .account(
            accountID: "account-\(index)",
            accountName: "Account \(index)",
            range: .day,
            resolvesMetadata: false),
          baseline: MetricsWidgetRefreshBaseline(store: nil, generation: 4),
          now: .now)
      }
    }
    return await group.reduce(into: []) { $0.append($1) }
  }

  #expect(outcomes.allSatisfy { $0 == .refreshed })
  #expect(await probe.started == 5)
  #expect(await probe.maximumActive == 2)
}

@Test func cancellingLastWaiterLetsSameScopeStartANewFlightImmediately() async {
  let probe = MetricsWidgetRefreshProbe()
  let coordinator = MetricsWidgetRemoteRefreshCoordinator(
    maximumConcurrentRequests: 1,
    loader: { target in
      await probe.begin()
      do {
        try await Task.sleep(for: .milliseconds(100))
        await probe.end()
        return makeRemoteAccountPayload(for: target)
      } catch {
        await probe.end()
        throw error
      }
    },
    persister: { _, _ in })

  let target = MetricsWidgetRefreshTarget.account(
    accountID: "account", accountName: "Account", range: .day, resolvesMetadata: false)
  let baseline = MetricsWidgetRefreshBaseline(store: nil, generation: 1)
  let cancelled = Task {
    await coordinator.refreshIfNeeded(target, baseline: baseline, now: .now)
  }
  #expect(await probe.waitUntilStarted(1))
  cancelled.cancel()
  #expect(await cancelled.value == .fallback)

  let replacement = Task {
    await coordinator.refreshIfNeeded(target, baseline: baseline, now: .now)
  }
  #expect(await replacement.value == .refreshed)
  #expect(await probe.started == 2)
}

@Test func metricsWidgetRefreshDoesNotJoinAFlightFromAnotherGeneration() async {
  let probe = MetricsWidgetRefreshProbe()
  let generations = MetricsWidgetGenerationRecorder()
  let target = MetricsWidgetRefreshTarget.account(
    accountID: "account", accountName: "Account", range: .day, resolvesMetadata: false)
  let coordinator = MetricsWidgetRemoteRefreshCoordinator(
    maximumConcurrentRequests: 2,
    loader: { target in
      await probe.begin()
      do {
        try await Task.sleep(for: .milliseconds(60))
        await probe.end()
        return makeRemoteAccountPayload(for: target)
      } catch {
        await probe.end()
        throw error
      }
    },
    persister: { _, generation in await generations.record(generation) })

  async let oldSession = coordinator.refreshIfNeeded(
    target,
    baseline: MetricsWidgetRefreshBaseline(store: nil, generation: 1),
    now: .now)
  async let newSession = coordinator.refreshIfNeeded(
    target,
    baseline: MetricsWidgetRefreshBaseline(store: nil, generation: 2),
    now: .now)
  let outcomes = await [oldSession, newSession]

  #expect(outcomes.allSatisfy { $0 == .refreshed })
  #expect(await probe.started == 2)
  #expect(await probe.maximumActive == 2)
  #expect(await generations.values.sorted() == [1, 2])
}

@Test func metricsWidgetRefreshCoordinatorPersistsCapturedGeneration() async {
  let generations = MetricsWidgetGenerationRecorder()
  let coordinator = MetricsWidgetRemoteRefreshCoordinator(
    loader: { makeRemoteAccountPayload(for: $0) },
    persister: { _, generation in await generations.record(generation) })

  let outcome = await coordinator.refreshIfNeeded(
    .account(
      accountID: "account",
      accountName: "Account",
      range: .week,
      resolvesMetadata: false),
    baseline: MetricsWidgetRefreshBaseline(store: nil, generation: 42),
    now: .now)

  #expect(outcome == .refreshed)
  #expect(await generations.values == [42])
}

@Test func metricsWidgetRefreshCoordinatorFallsBackOnTimeoutAndPersistenceFailure() async {
  let timeoutPersistence = MetricsWidgetGenerationRecorder()
  let timeoutCoordinator = MetricsWidgetRemoteRefreshCoordinator(
    timeout: .milliseconds(20),
    loader: { target in
      await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) {
          continuation.resume()
        }
      }
      return makeRemoteAccountPayload(for: target)
    },
    persister: { _, generation in await timeoutPersistence.record(generation) })
  let target = MetricsWidgetRefreshTarget.account(
    accountID: "account",
    accountName: "Account",
    range: .day,
    resolvesMetadata: false)

  let clock = ContinuousClock()
  let startedAt = clock.now
  let timedOut = await timeoutCoordinator.refreshIfNeeded(
    target,
    baseline: MetricsWidgetRefreshBaseline(store: nil, generation: 1),
    now: .now)
  #expect(timedOut == .fallback)
  #expect(startedAt.duration(to: clock.now) < .milliseconds(100))
  #expect(await timeoutPersistence.values.isEmpty)
  try? await Task.sleep(for: .milliseconds(250))
  #expect(await timeoutPersistence.values.isEmpty)

  let persistenceCoordinator = MetricsWidgetRemoteRefreshCoordinator(
    loader: { makeRemoteAccountPayload(for: $0) },
    persister: { _, _ in throw MetricsWidgetRefreshingTestError.persistence })
  let persistenceFailed = await persistenceCoordinator.refreshIfNeeded(
    target,
    baseline: MetricsWidgetRefreshBaseline(store: nil, generation: 1),
    now: .now)
  #expect(persistenceFailed == .fallback)
}

@Test func metricsWidgetRefreshCoordinatorFallsBackOnGenerationMismatch() async {
  let target = MetricsWidgetRefreshTarget.account(
    accountID: "account",
    accountName: "Account",
    range: .day,
    resolvesMetadata: false)
  let coordinator = MetricsWidgetRemoteRefreshCoordinator(
    loader: { makeRemoteAccountPayload(for: $0) },
    persister: { _, expected in
      throw MetricsWidgetSnapshotRepository.RepositoryError.generationMismatch(
        expected: expected,
        actual: expected + 1)
    })

  let outcome = await coordinator.refreshIfNeeded(
    target,
    baseline: MetricsWidgetRefreshBaseline(store: nil, generation: 9),
    now: .now)

  #expect(outcome == .fallback)
}

@Test func metricsWidgetRefreshCoordinatorNeverNetworksOutsideRemoteSession() async {
  let probe = MetricsWidgetRefreshProbe()
  let coordinator = MetricsWidgetRemoteRefreshCoordinator(
    loader: { target in
      await probe.begin()
      await probe.end()
      return makeRemoteAccountPayload(for: target)
    },
    persister: { _, _ in })
  let target = MetricsWidgetRefreshTarget.account(
    accountID: "account",
    accountName: "Account",
    range: .day,
    resolvesMetadata: false)

  let localOnly = await coordinator.refreshIfNeeded(
    target,
    baseline: MetricsWidgetRefreshBaseline(
      store: nil,
      generation: 10,
      mode: .localOnly),
    now: .now)
  let invalidated = await coordinator.refreshIfNeeded(
    target,
    baseline: MetricsWidgetRefreshBaseline(
      store: nil,
      generation: 11,
      mode: .invalidated),
    now: .now)

  #expect(localOnly == .fallback)
  #expect(invalidated == .fallback)
  #expect(await probe.started == 0)
}

@Test func missingWidgetCredentialInvalidatesCapturedGenerationBeforeLoading() async {
  let reader = MetricsWidgetTokenReader([.token(nil)])
  let generations = MetricsWidgetGenerationRecorder()
  let probe = MetricsWidgetRefreshProbe()
  let validator = MetricsWidgetCredentialValidator(
    readAccessToken: { try await reader.read() },
    invalidate: { generation in await generations.record(generation) })
  let coordinator = MetricsWidgetRemoteRefreshCoordinator(
    credentialValidator: validator,
    loader: { target in
      await probe.begin()
      await probe.end()
      return makeRemoteAccountPayload(for: target)
    },
    persister: { _, _ in })

  let outcome = await coordinator.refreshIfNeeded(
    .account(
      accountID: "account",
      accountName: "Account",
      range: .day,
      resolvesMetadata: false),
    baseline: MetricsWidgetRefreshBaseline(store: nil, generation: 13),
    now: .now)

  #expect(outcome == .credentialInvalidated)
  #expect(await generations.values == [13])
  #expect(await probe.started == 0)
}

@Test func missingWidgetCredentialInvalidatesEvenWhenSnapshotIsFresh() async {
  let reader = MetricsWidgetTokenReader([.token(nil)])
  let generations = MetricsWidgetGenerationRecorder()
  let probe = MetricsWidgetRefreshProbe()
  let account = MetricsWidgetAccount(id: "account", name: "Account")
  let now = Date.now
  let store = MetricsWidgetSnapshotStore(
    accounts: [account],
    accountSnapshots: [
      makeRemoteAccountWidgetSnapshot(
        account: account,
        range: .day,
        fetchedAt: now)
    ])
  let coordinator = MetricsWidgetRemoteRefreshCoordinator(
    credentialValidator: MetricsWidgetCredentialValidator(
      readAccessToken: { try await reader.read() },
      invalidate: { generation in await generations.record(generation) }),
    loader: { target in
      await probe.begin()
      await probe.end()
      return makeRemoteAccountPayload(for: target)
    },
    persister: { _, _ in })

  let outcome = await coordinator.refreshIfNeeded(
    .account(
      accountID: account.id,
      accountName: account.name,
      range: .day,
      resolvesMetadata: false),
    baseline: MetricsWidgetRefreshBaseline(store: store, generation: 14),
    now: now)

  #expect(outcome == .credentialInvalidated)
  #expect(await generations.values == [14])
  #expect(await probe.started == 0)
}

@Test func finalUnauthorizedInvalidatesOnlyAnUnchangedWidgetCredential() async {
  let unchangedReader = MetricsWidgetTokenReader([
    .token("old"), .token("old"), .token("old"),
  ])
  let unchangedGenerations = MetricsWidgetGenerationRecorder()
  let unchanged = MetricsWidgetRemoteRefreshCoordinator(
    credentialValidator: MetricsWidgetCredentialValidator(
      readAccessToken: { try await unchangedReader.read() },
      invalidate: { generation in await unchangedGenerations.record(generation) }),
    loader: { _ in
      throw CloudflareAPIError.request(status: 401, errors: [])
    },
    persister: { _, _ in })
  let target = MetricsWidgetRefreshTarget.account(
    accountID: "account",
    accountName: "Account",
    range: .day,
    resolvesMetadata: false)

  let unchangedOutcome = await unchanged.refreshIfNeeded(
    target,
    baseline: MetricsWidgetRefreshBaseline(store: nil, generation: 21),
    now: .now)

  let replacedReader = MetricsWidgetTokenReader([
    .token("old"), .token("old"), .token("new"),
  ])
  let replacedGenerations = MetricsWidgetGenerationRecorder()
  let replaced = MetricsWidgetRemoteRefreshCoordinator(
    credentialValidator: MetricsWidgetCredentialValidator(
      readAccessToken: { try await replacedReader.read() },
      invalidate: { generation in await replacedGenerations.record(generation) }),
    loader: { _ in
      throw CloudflareAPIError.request(status: 401, errors: [])
    },
    persister: { _, _ in })
  let replacedOutcome = await replaced.refreshIfNeeded(
    target,
    baseline: MetricsWidgetRefreshBaseline(store: nil, generation: 22),
    now: .now)

  #expect(unchangedOutcome == .credentialInvalidated)
  #expect(await unchangedGenerations.values == [21])
  #expect(replacedOutcome == .fallback)
  #expect(await replacedGenerations.values.isEmpty)
}

@Test func transientWidgetKeychainFailureKeepsLastGoodSession() async {
  let reader = MetricsWidgetTokenReader([.token("old"), .token("old"), .failure])
  let generations = MetricsWidgetGenerationRecorder()
  let coordinator = MetricsWidgetRemoteRefreshCoordinator(
    credentialValidator: MetricsWidgetCredentialValidator(
      readAccessToken: { try await reader.read() },
      invalidate: { generation in await generations.record(generation) }),
    loader: { _ in
      throw CloudflareAPIError.request(status: 401, errors: [])
    },
    persister: { _, _ in })

  let outcome = await coordinator.refreshIfNeeded(
    .account(
      accountID: "account",
      accountName: "Account",
      range: .day,
      resolvesMetadata: false),
    baseline: MetricsWidgetRefreshBaseline(store: nil, generation: 31),
    now: .now)

  #expect(outcome == .fallback)
  #expect(await generations.values.isEmpty)
}

@Test func queuedWidgetRefreshRevalidatesRemoteSessionBeforeNetworking() async {
  let session = MetricsWidgetRemoteSessionVerifier()
  let probe = MetricsWidgetRefreshProbe()
  let coordinator = MetricsWidgetRemoteRefreshCoordinator(
    maximumConcurrentRequests: 1,
    remoteSessionValidator: { generation in
      try await session.validate(generation)
    },
    loader: { target in
      await probe.begin()
      do {
        try await Task.sleep(for: .milliseconds(80))
        await probe.end()
        return makeRemoteAccountPayload(for: target)
      } catch {
        await probe.end()
        throw error
      }
    },
    persister: { _, _ in })
  let baseline = MetricsWidgetRefreshBaseline(store: nil, generation: 41)
  let first = Task {
    await coordinator.refreshIfNeeded(
      .account(
        accountID: "first",
        accountName: "First",
        range: .day,
        resolvesMetadata: false),
      baseline: baseline,
      now: .now)
  }
  #expect(await probe.waitUntilStarted(1))
  let queued = Task {
    await coordinator.refreshIfNeeded(
      .account(
        accountID: "queued",
        accountName: "Queued",
        range: .day,
        resolvesMetadata: false),
      baseline: baseline,
      now: .now)
  }
  await session.invalidate()

  #expect(await first.value == .refreshed)
  #expect(await queued.value == .fallback)
  #expect(await probe.started == 1)
}

private enum MetricsWidgetRefreshingTestError: Error {
  case persistence
  case remoteSessionInvalidated
  case tokenRead
  case unexpectedTarget
}

private actor MetricsWidgetRemoteSessionVerifier {
  private var isRemoteEnabled = true

  func validate(_: UInt64) throws {
    guard isRemoteEnabled else {
      throw MetricsWidgetRefreshingTestError.remoteSessionInvalidated
    }
  }

  func invalidate() {
    isRemoteEnabled = false
  }
}

private actor MetricsWidgetTokenReader {
  enum Step: Sendable {
    case token(String?)
    case failure
  }

  private var steps: [Step]

  init(_ steps: [Step]) {
    self.steps = steps
  }

  func read() throws -> String? {
    guard !steps.isEmpty else {
      throw MetricsWidgetRefreshingTestError.tokenRead
    }
    switch steps.removeFirst() {
    case .token(let token): return token
    case .failure: throw MetricsWidgetRefreshingTestError.tokenRead
    }
  }
}

private actor MetricsWidgetRefreshProbe {
  private(set) var started = 0
  private(set) var active = 0
  private(set) var maximumActive = 0

  func begin() {
    started += 1
    active += 1
    maximumActive = max(maximumActive, active)
  }

  func end() {
    active -= 1
  }

  func waitUntilStarted(_ count: Int) async -> Bool {
    for _ in 0..<1_000 {
      if started >= count { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }
}

private actor MetricsWidgetGenerationRecorder {
  private(set) var values: [UInt64] = []

  func record(_ generation: UInt64) {
    values.append(generation)
  }
}

private func makeRemoteAccountPayload(
  for target: MetricsWidgetRefreshTarget
) -> MetricsWidgetRefreshPayload {
  guard case .account(let accountID, let accountName, let range, _) = target else {
    let account = MetricsWidgetAccount(id: "unexpected", name: "Unexpected")
    return .account(
      account: account,
      snapshot: makeRemoteAccountWidgetSnapshot(
        account: account,
        range: .day,
        fetchedAt: .now))
  }
  let account = MetricsWidgetAccount(id: accountID, name: accountName)
  return .account(
    account: account,
    snapshot: makeRemoteAccountWidgetSnapshot(
      account: account,
      range: range,
      fetchedAt: .now))
}

private func makeRemoteAccountWidgetSnapshot(
  account: MetricsWidgetAccount,
  range: MetricsWidgetRange,
  fetchedAt: Date
) -> AccountMetricsWidgetSnapshot {
  AccountMetricsWidgetSnapshot(
    accountID: account.id,
    accountName: account.name,
    range: range,
    metrics: [
      MetricsWidgetMetricSnapshot(
        metric: .webTraffic,
        total: 42,
        points: [MetricsWidgetPoint(timestamp: fetchedAt, value: 42)])
    ],
    fetchedAt: fetchedAt)
}
