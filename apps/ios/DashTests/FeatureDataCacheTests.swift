import CloudflareAPI
import Foundation
import Testing

@testable import Dash

@Test @MainActor func featureDataCachePreservesTheSourceFetchDate() throws {
  let cache = FeatureDataCache()
  let fetchedAt = Date.now.addingTimeInterval(-30)
  cache.set("dated", 42, fetchedAt: fetchedAt)

  let cached: (value: Int, fetchedAt: Date) = try #require(
    cache.getWithFetchedAt("dated"))

  #expect(cached.value == 42)
  #expect(cached.fetchedAt == fetchedAt)
}

@Test @MainActor func featureDataCacheJoinsConcurrentLoadsForOneKey() async throws {
  let cache = FeatureDataCache()
  let probe = FeatureLoadProbe()

  let first = Task { @MainActor in
    try await cache.coalescedLoad("shared") {
      try await probe.suspendedValue()
    }
  }
  while await probe.startCount == 0 {
    await Task.yield()
  }

  let second = Task { @MainActor in
    try await cache.coalescedLoad("shared") {
      try await probe.suspendedValue()
    }
  }
  for _ in 0..<20 {
    await Task.yield()
  }
  await probe.releaseAll()

  let firstValue = try await first.value
  let secondValue = try await second.value
  let startCount = await probe.startCount
  #expect(firstValue == 42)
  #expect(secondValue == 42)
  #expect(startCount == 1)
}

@Test @MainActor func featureDataCacheCancelsTheOnlyWaiterAndUnderlyingLoadPromptly() async {
  let cache = FeatureDataCache()
  let probe = FeatureLoadProbe()
  let completion = FeatureLoadCompletionProbe()
  let load = Task { @MainActor in
    do {
      let _: Int = try await cache.coalescedLoad("only-waiter") {
        try await probe.longRunningValue()
      }
      await completion.finish(cancelled: false)
    } catch is CancellationError {
      await completion.finish(cancelled: true)
    } catch {
      await completion.finish(cancelled: false)
    }
  }
  while await probe.startCount == 0 {
    await Task.yield()
  }

  load.cancel()
  for _ in 0..<50 {
    if await completion.isFinished { break }
    try? await Task.sleep(for: .milliseconds(10))
  }

  #expect(await completion.isFinished)
  #expect(await completion.wasCancelled)
  #expect(await probe.cancellationCount == 1)
  _ = await load.result
}

@Test @MainActor func featureDataCacheKeepsSharedLoadAliveWhenOneWaiterCancels() async throws {
  let cache = FeatureDataCache()
  let probe = FeatureLoadProbe()
  let firstCompletion = FeatureLoadCompletionProbe()
  let first = Task { @MainActor in
    do {
      let _: Int = try await cache.coalescedLoad("two-waiters") {
        try await probe.suspendedValue()
      }
      await firstCompletion.finish(cancelled: false)
    } catch is CancellationError {
      await firstCompletion.finish(cancelled: true)
    } catch {
      await firstCompletion.finish(cancelled: false)
    }
  }
  while await probe.startCount == 0 {
    await Task.yield()
  }
  let second = Task { @MainActor in
    try await cache.coalescedLoad("two-waiters") {
      try await probe.suspendedValue()
    }
  }
  for _ in 0..<10 { await Task.yield() }

  first.cancel()
  for _ in 0..<50 {
    if await firstCompletion.isFinished { break }
    try? await Task.sleep(for: .milliseconds(10))
  }

  #expect(await firstCompletion.wasCancelled)
  #expect(await probe.cancellationCount == 0)
  #expect(await probe.startCount == 1)

  await probe.releaseAll()
  #expect(try await second.value == 42)
  _ = await first.result
}

@Test @MainActor func featureDataCacheRetriesAfterFailure() async throws {
  let cache = FeatureDataCache()

  do {
    let _: Int = try await cache.coalescedLoad("retry") {
      throw FeatureLoadTestError.expected
    }
    Issue.record("Expected the first load to fail")
  } catch is FeatureLoadTestError {
    // Expected.
  }

  let value: Int = try await cache.coalescedLoad("retry") { 7 }
  #expect(value == 7)
}

@Test @MainActor func featureDataCacheClearCancelsInFlightWork() async {
  let cache = FeatureDataCache()
  let probe = FeatureLoadProbe()
  let load = Task { @MainActor in
    try await cache.coalescedLoad("cancelled") {
      try await probe.longRunningValue()
    }
  }
  while await probe.startCount == 0 {
    await Task.yield()
  }

  cache.clear()
  do {
    _ = try await load.value
    Issue.record("Expected clear() to cancel the in-flight load")
  } catch is CancellationError {
    // Expected.
  } catch {
    Issue.record("Expected CancellationError, got \(error)")
  }
}

@Test @MainActor func accountGenerationRejectsAnOlderVisitToTheSameAccount() throws {
  let defaultsKey = "dash.active_account_id"
  let previousAccountID = UserDefaults.standard.string(forKey: defaultsKey)
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
        {"id":"generation-a","name":"Account A"},
        {"id":"generation-b","name":"Account B"}
      ]
      """.utf8))
  let model = AppModel(configuration: AppConfiguration(clientID: "", redirectURI: ""))

  model.selectAccount(accounts[0])
  let firstA = try #require(model.accountRequestContext)
  model.selectAccount(accounts[1])
  model.selectAccount(accounts[0])
  let secondA = try #require(model.accountRequestContext)

  #expect(firstA.accountID == secondA.accountID)
  #expect(firstA.generation != secondA.generation)
  #expect(!model.isCurrentAccount(firstA))
  #expect(model.isCurrentAccount(secondA))
}

@Test @MainActor func persistenceRoundTripsAcrossRelaunch() async throws {
  let dir = dashPersistenceTempDir("roundtrip")
  defer { try? FileManager.default.removeItem(at: dir) }

  let persistence = FeatureCachePersistence(directory: dir)
  let cache = FeatureDataCache(persistence: persistence)
  cache.setPersistenceAccount("acc-a")
  cache.set("sample", 42)
  await dashPersistenceSettle()
  await persistence.flushNow()

  // Simulate a relaunch: a fresh cache + fresh actor reading the same directory.
  let relaunched = FeatureDataCache(
    persistence: FeatureCachePersistence(directory: dir))
  relaunched.setPersistenceAccount("acc-a")
  await dashPersistenceSettle()
  let value: Int? = relaunched.get("sample")
  #expect(value == 42)
}

@Test @MainActor func persistenceIsolationBetweenAccounts() async throws {
  let dir = dashPersistenceTempDir("isolation")
  defer { try? FileManager.default.removeItem(at: dir) }

  let persistence = FeatureCachePersistence(directory: dir)
  let cache = FeatureDataCache(persistence: persistence)
  cache.setPersistenceAccount("acc-a")
  cache.set("sample", 1)
  cache.clear()
  cache.setPersistenceAccount("acc-b")
  cache.set("sample", 2)
  cache.clear()
  await dashPersistenceSettle()
  await persistence.flushNow()

  cache.setPersistenceAccount("acc-a")
  await dashPersistenceSettle()
  let a: Int? = cache.get("sample")
  #expect(a == 1)

  cache.setPersistenceAccount("acc-b")
  await dashPersistenceSettle()
  let b: Int? = cache.get("sample")
  #expect(b == 2)
}

@Test @MainActor func persistenceStaleFallbackReturnsExpiredValue() async throws {
  let dir = dashPersistenceTempDir("stale")
  defer { try? FileManager.default.removeItem(at: dir) }

  let persistence = FeatureCachePersistence(directory: dir)
  let cache = FeatureDataCache(persistence: persistence)
  cache.setPersistenceAccount("acc-a")
  cache.set("sample", 42, ttl: 0)
  await dashPersistenceSettle()

  // Expired: the fresh read refuses it…
  let fresh: Int? = cache.get("sample")
  #expect(fresh == nil)
  // …but the offline fallback still returns the last-known value.
  let stale: Int? = cache.getStale("sample")
  #expect(stale == 42)
}

@Test @MainActor func persistenceSkipsNonCodableValues() async throws {
  struct NonCodable: Sendable { let x: Int }
  let dir = dashPersistenceTempDir("noncodable")
  defer { try? FileManager.default.removeItem(at: dir) }

  let persistence = FeatureCachePersistence(directory: dir)
  let cache = FeatureDataCache(persistence: persistence)
  cache.setPersistenceAccount("acc-a")
  cache.set("noncodable", NonCodable(x: 1))
  await dashPersistenceSettle()
  await persistence.flushNow()

  // A relaunch never sees the value: it was never writable to disk.
  let relaunched = FeatureDataCache(
    persistence: FeatureCachePersistence(directory: dir))
  relaunched.setPersistenceAccount("acc-a")
  await dashPersistenceSettle()
  let stale: NonCodable? = relaunched.getStale("noncodable")
  #expect(stale == nil)
}

@Test @MainActor func clearAllPersistenceDeletesEveryAccountFile() async throws {
  let dir = dashPersistenceTempDir("clearall")
  defer { try? FileManager.default.removeItem(at: dir) }

  let persistence = FeatureCachePersistence(directory: dir)
  let cache = FeatureDataCache(persistence: persistence)
  cache.setPersistenceAccount("acc-a")
  cache.set("sample", 1)
  cache.clear()
  cache.setPersistenceAccount("acc-b")
  cache.set("sample", 2)
  await dashPersistenceSettle()
  await persistence.flushNow()

  cache.clearAllPersistence()
  await dashPersistenceSettle()
  await persistence.flushNow()

  let relaunched = FeatureDataCache(
    persistence: FeatureCachePersistence(directory: dir))
  relaunched.setPersistenceAccount("acc-a")
  await dashPersistenceSettle()
  let a: Int? = relaunched.get("sample")
  #expect(a == nil)
}

private func dashPersistenceTempDir(_ label: String) -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "DashFeatureCacheTests-\(label)-\(UUID().uuidString)",
    isDirectory: true
  )
}

/// `FeatureDataCache` deliberately hands disk work to unstructured tasks so UI
/// writes stay synchronous. Yield the main actor long enough for those tasks to
/// enqueue on `FeatureCachePersistence` before a test flushes or reads it.
@MainActor private func dashPersistenceSettle() async {
  for _ in 0..<20 { await Task.yield() }
}

private enum FeatureLoadTestError: Error {
  case expected
}

private actor FeatureLoadProbe {
  private(set) var startCount = 0
  private(set) var cancellationCount = 0
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func suspendedValue() async throws -> Int {
    startCount += 1
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
    try Task.checkCancellation()
    return 42
  }

  func longRunningValue() async throws -> Int {
    startCount += 1
    do {
      try await Task.sleep(for: .seconds(30))
    } catch {
      cancellationCount += 1
      throw error
    }
    return 42
  }

  func releaseAll() {
    let pending = continuations
    continuations.removeAll()
    for continuation in pending {
      continuation.resume()
    }
  }
}

private actor FeatureLoadCompletionProbe {
  private(set) var isFinished = false
  private(set) var wasCancelled = false

  func finish(cancelled: Bool) {
    isFinished = true
    wasCancelled = cancelled
  }
}
