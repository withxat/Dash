import CloudflareAPI
import Foundation

/// One exact analytics request represented by a configured metrics widget.
/// Display metadata is deliberately excluded from `key`: two widgets bound to
/// the same resource and range share one network request even if one resolved
/// its entity title from an older snapshot catalog.
enum MetricsWidgetRefreshTarget: Hashable, Sendable {
  case account(
    accountID: String,
    accountName: String,
    range: MetricsWidgetRange,
    resolvesMetadata: Bool)
  case domain(
    accountID: String,
    accountName: String,
    domainID: String,
    domainName: String,
    range: MetricsWidgetRange,
    resolvesMetadata: Bool)

  enum Key: Hashable, Sendable {
    case account(accountID: String, range: MetricsWidgetRange)
    case domain(accountID: String, domainID: String, range: MetricsWidgetRange)
  }

  var key: Key {
    switch self {
    case .account(let accountID, _, let range, _):
      .account(accountID: accountID, range: range)
    case .domain(let accountID, _, let domainID, _, let range, _):
      .domain(accountID: accountID, domainID: domainID, range: range)
    }
  }

  var range: MetricsWidgetRange {
    switch self {
    case .account(_, _, let range, _), .domain(_, _, _, _, let range, _):
      range
    }
  }

  var isDemo: Bool {
    let accountID: String
    switch key {
    case .account(let id, _), .domain(let id, _, _):
      accountID = id
    }
    return accountID.hasPrefix("demo-account")
  }

  var stableJitterSeed: String {
    switch key {
    case .account(let accountID, let range):
      "account:\(accountID):\(range.rawValue)"
    case .domain(let accountID, let domainID, let range):
      "domain:\(accountID):\(domainID):\(range.rawValue)"
    }
  }

  func resolvingMetadata(from store: MetricsWidgetSnapshotStore?) -> Self {
    switch self {
    case .account(let accountID, _, let range, _):
      guard let account = store?.account(id: accountID) else { return self }
      return .account(
        accountID: accountID,
        accountName: account.name,
        range: range,
        resolvesMetadata: false)

    case .domain(
      let accountID,
      let accountName,
      let domainID,
      let domainName,
      let range,
      let resolvesMetadata):
      let account = store?.account(id: accountID)
      let domain = store?.domain(id: domainID, accountID: accountID)
      guard account != nil || domain != nil else { return self }
      return .domain(
        accountID: accountID,
        accountName: account?.name ?? accountName,
        domainID: domainID,
        domainName: domain?.name ?? domainName,
        range: range,
        resolvesMetadata: resolvesMetadata && domain == nil)
    }
  }
}

enum MetricsWidgetRefreshPayload: Hashable, Sendable {
  case account(
    account: MetricsWidgetAccount,
    snapshot: AccountMetricsWidgetSnapshot)
  case domain(
    account: MetricsWidgetAccount,
    domain: MetricsWidgetDomain,
    snapshot: DomainMetricsWidgetSnapshot)
}

enum MetricsWidgetRefreshOutcome: Equatable, Sendable {
  /// The App Group snapshot is inside the range's refresh window.
  case fresh
  /// A remote response was persisted for the same credential generation.
  case refreshed
  /// A successful Keychain read proved the shared credential is gone, or the
  /// same credential was still current after a final unauthorized response.
  /// The matching repository generation has already been invalidated.
  case credentialInvalidated
  /// The caller should render its last-good snapshot (or first-load state).
  case fallback
}

/// WidgetKit refreshes are budgeted and `.after` is an earliest date, not a
/// timer. These intervals keep fast-moving 24h charts useful without asking a
/// 30d chart to wake at the same cadence. Stable positive jitter spreads
/// widgets across the process's request window without making tests flaky.
enum MetricsWidgetRefreshPolicy {
  static func refreshInterval(for range: MetricsWidgetRange) -> TimeInterval {
    switch range {
    case .day: 30 * 60
    case .week: 60 * 60
    case .month: 3 * 60 * 60
    }
  }

  static func needsRefresh(
    fetchedAt: Date?,
    range: MetricsWidgetRange,
    now: Date
  ) -> Bool {
    guard let fetchedAt else { return true }
    let age = max(0, now.timeIntervalSince(fetchedAt))
    return age >= refreshInterval(for: range)
  }

  static func nextReloadDate(
    after now: Date,
    fetchedAt: Date? = nil,
    range: MetricsWidgetRange,
    seed: String
  ) -> Date {
    let interval = refreshInterval(for: range)
    let jitter = interval * 0.1 * stableUnitInterval(seed)
    guard let fetchedAt else {
      // First-load failures should recover promptly even for a 30d widget.
      return now.addingTimeInterval(15 * 60)
    }
    let candidate = fetchedAt.addingTimeInterval(interval + jitter)
    // An early provider call (for example while a Smart Stack is becoming
    // visible) must not restart the whole interval from that visibility event.
    // A failed overdue refresh gets a modest retry instead of a past `.after`.
    return candidate > now ? candidate : now.addingTimeInterval(15 * 60)
  }

  private static func stableUnitInterval(_ value: String) -> Double {
    // FNV-1a is stable across launches; Swift's `Hasher` intentionally is not.
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return Double(hash % 10_001) / 10_000
  }
}

extension MetricsWidgetRange {
  var accountAnalyticsGranularity: AccountAnalyticsGranularity {
    switch self {
    case .day, .week: .hour
    case .month: .day
    }
  }
}

/// Baseline captured before a remote request. The generation is persisted in a
/// sidecar that survives snapshot deletion, so a response that started before
/// sign-out cannot recreate the deleted account data.
struct MetricsWidgetRefreshBaseline: Sendable {
  var store: MetricsWidgetSnapshotStore?
  var generation: UInt64
  var mode: MetricsWidgetSessionMode = .remoteEnabled

  func fetchedAt(for target: MetricsWidgetRefreshTarget) -> Date? {
    switch target.key {
    case .account(let accountID, let range):
      store?.accountSnapshot(accountID: accountID, range: range)?.fetchedAt
    case .domain(let accountID, let domainID, let range):
      store?.domainSnapshot(
        accountID: accountID,
        domainID: domainID,
        range: range)?.fetchedAt
    }
  }
}

enum MetricsWidgetCredentialValidationError: Error, Equatable, Sendable {
  case invalidated
}

/// Keeps a Widget request tied to the credential generation it observed.
/// Transient Keychain read failures leave last-good data alone. A definitive
/// missing credential, or a final 401 while the same access token is still
/// current, conditionally invalidates only the request's captured generation.
struct MetricsWidgetCredentialValidator: Sendable {
  typealias AccessTokenReader = @Sendable () async throws -> String?
  typealias Invalidator = @Sendable (UInt64) async throws -> Void

  let readAccessToken: AccessTokenReader
  let invalidate: Invalidator

  func validatePresence(expectedGeneration: UInt64) async throws {
    guard try await readAccessToken() == nil else { return }
    try await invalidate(expectedGeneration)
    throw MetricsWidgetCredentialValidationError.invalidated
  }

  func load(
    _ target: MetricsWidgetRefreshTarget,
    expectedGeneration: UInt64,
    using loader: MetricsWidgetRemoteRefreshCoordinator.Loader
  ) async throws -> MetricsWidgetRefreshPayload {
    let observedAccessToken = try await readAccessToken()
    guard let observedAccessToken else {
      try await invalidate(expectedGeneration)
      throw MetricsWidgetCredentialValidationError.invalidated
    }

    do {
      return try await loader(target)
    } catch let requestError {
      guard (requestError as? CloudflareAPIError)?.isUnauthorized == true else {
        throw requestError
      }

      let currentAccessToken: String?
      do {
        currentAccessToken = try await readAccessToken()
      } catch {
        // A Keychain failure cannot prove the credential disappeared. Keep the
        // repository and surface the original request failure as a fallback.
        throw requestError
      }
      guard currentAccessToken == nil || currentAccessToken == observedAccessToken else {
        // OAuth or a sibling process installed a newer credential while this
        // request was running. Its session must survive the old request's 401.
        throw requestError
      }

      do {
        try await invalidate(expectedGeneration)
      } catch {
        // Generation mismatch means a newer app-owned session won the race.
        throw requestError
      }
      throw MetricsWidgetCredentialValidationError.invalidated
    }
  }
}

/// Process-wide single-flight for Widget timelines. Distinct configured scopes
/// share a two-permit pool; identical scopes share the same task. Errors are
/// intentionally collapsed to `.fallback` because a Widget has no useful
/// interactive recovery surface and must retain its last-good render.
actor MetricsWidgetRemoteRefreshCoordinator {
  typealias Loader =
    @Sendable (MetricsWidgetRefreshTarget) async throws
    -> MetricsWidgetRefreshPayload
  typealias Persister = @Sendable (MetricsWidgetRefreshPayload, UInt64) async throws -> Void
  typealias RemoteSessionValidator = @Sendable (UInt64) async throws -> Void

  private struct InFlight {
    var id: UUID
    var task: Task<Void, Error>
    var waiterIDs: Set<UUID>
  }

  private struct FlightKey: Hashable, Sendable {
    var target: MetricsWidgetRefreshTarget.Key
    var generation: UInt64
  }

  private let loader: Loader
  private let credentialValidator: MetricsWidgetCredentialValidator?
  private let remoteSessionValidator: RemoteSessionValidator?
  private let persister: Persister
  private let timeout: Duration
  private let permits: MetricsWidgetRefreshPermitPool
  private var inFlight: [FlightKey: InFlight] = [:]

  init(
    maximumConcurrentRequests: Int = 2,
    timeout: Duration = .seconds(9),
    credentialValidator: MetricsWidgetCredentialValidator? = nil,
    remoteSessionValidator: RemoteSessionValidator? = nil,
    loader: @escaping Loader,
    persister: @escaping Persister
  ) {
    self.loader = loader
    self.credentialValidator = credentialValidator
    self.remoteSessionValidator = remoteSessionValidator
    self.persister = persister
    self.timeout = timeout
    permits = MetricsWidgetRefreshPermitPool(limit: maximumConcurrentRequests)
  }

  func refreshIfNeeded(
    _ unresolvedTarget: MetricsWidgetRefreshTarget,
    baseline: MetricsWidgetRefreshBaseline,
    now: Date
  ) async -> MetricsWidgetRefreshOutcome {
    let target = unresolvedTarget.resolvingMetadata(from: baseline.store)
    guard baseline.mode == .remoteEnabled else {
      return baseline.fetchedAt(for: target) == nil ? .fallback : .fresh
    }
    // Demo analytics comes from an in-process URLProtocol owned by the main
    // app. Its render-ready fixture is safe to retain, but a Widget process
    // must never send those synthetic identifiers with a real OAuth grant.
    if target.isDemo {
      return baseline.fetchedAt(for: target) == nil ? .fallback : .fresh
    }
    let needsRefresh = MetricsWidgetRefreshPolicy.needsRefresh(
      fetchedAt: baseline.fetchedAt(for: target),
      range: target.range,
      now: now)
    if let credentialValidator {
      do {
        try await credentialValidator.validatePresence(
          expectedGeneration: baseline.generation)
      } catch MetricsWidgetCredentialValidationError.invalidated {
        return .credentialInvalidated
      } catch {
        // A transient Keychain or repository read cannot prove sign-out. Keep
        // a fresh last-good timeline; stale/missing data retries later.
        return needsRefresh ? .fallback : .fresh
      }
    }
    guard needsRefresh else {
      return .fresh
    }

    let key = FlightKey(target: target.key, generation: baseline.generation)
    let waiterID = UUID()
    if var existing = inFlight[key] {
      existing.waiterIDs.insert(waiterID)
      inFlight[key] = existing
      return await outcome(
        of: existing.task,
        key: key,
        flightID: existing.id,
        waiterID: waiterID)
    }

    let id = UUID()
    let loader = self.loader
    let credentialValidator = self.credentialValidator
    let remoteSessionValidator = self.remoteSessionValidator
    let persister = self.persister
    let timeout = self.timeout
    let permits = self.permits
    let generation = baseline.generation
    let task = Task {
      let payload = try await withMetricsWidgetTimeout(timeout) {
        try await permits.withPermit {
          // The task may have waited behind other configured widgets. Re-prove
          // its generation is still remote-enabled before it reads a
          // credential or starts network work.
          try await remoteSessionValidator?(generation)
          if let credentialValidator {
            return try await credentialValidator.load(
              target,
              expectedGeneration: generation,
              using: loader)
          } else {
            return try await loader(target)
          }
        }
      }
      try Task.checkCancellation()
      try await persister(payload, generation)
    }
    inFlight[key] = InFlight(id: id, task: task, waiterIDs: [waiterID])
    return await outcome(
      of: task,
      key: key,
      flightID: id,
      waiterID: waiterID)
  }

  private func outcome(
    of task: Task<Void, Error>,
    key: FlightKey,
    flightID: UUID,
    waiterID: UUID
  ) async -> MetricsWidgetRefreshOutcome {
    let gate = MetricsWidgetWaiterGate()
    Task {
      let outcome: MetricsWidgetRefreshOutcome
      do {
        try await task.value
        outcome = .refreshed
      } catch MetricsWidgetCredentialValidationError.invalidated {
        outcome = .credentialInvalidated
      } catch {
        outcome = .fallback
      }
      gate.resolveFromFlight(outcome)
    }
    let outcome = await withTaskCancellationHandler {
      await gate.wait()
    } onCancel: {
      gate.requestCancellation()
      Task {
        await self.cancelWaiter(
          key: key,
          flightID: flightID,
          waiterID: waiterID)
        gate.resolveCancellation()
      }
    }
    finishWaiter(key: key, flightID: flightID, waiterID: waiterID)
    return outcome
  }

  private func cancelWaiter(
    key: FlightKey,
    flightID: UUID,
    waiterID: UUID
  ) {
    guard var flight = inFlight[key], flight.id == flightID else { return }
    flight.waiterIDs.remove(waiterID)
    if flight.waiterIDs.isEmpty {
      // No visible timeline still needs this work. Cancelling here also wakes
      // a task queued behind the two-request permit pool.
      inFlight.removeValue(forKey: key)
      flight.task.cancel()
    } else {
      inFlight[key] = flight
    }
  }

  private func finishWaiter(
    key: FlightKey,
    flightID: UUID,
    waiterID: UUID
  ) {
    guard var flight = inFlight[key], flight.id == flightID else { return }
    flight.waiterIDs.remove(waiterID)
    if flight.waiterIDs.isEmpty {
      inFlight.removeValue(forKey: key)
    } else {
      inFlight[key] = flight
    }
  }
}

/// One continuation with a stored-result path for resolve-before-install.
/// Both Widget cancellation and Cloudflare completion race this gate, so every
/// transition is lock-protected and exactly one caller resumes the waiter.
private final class MetricsWidgetOneShot<Value: Sendable>: @unchecked Sendable {
  private enum State {
    case pending
    case waiting(CheckedContinuation<Value, Never>)
    case resolved(Value)
    case consumed
  }

  private let lock = NSLock()
  private var state = State.pending

  func wait() async -> Value {
    await withCheckedContinuation { continuation in
      lock.lock()
      switch state {
      case .pending:
        state = .waiting(continuation)
        lock.unlock()
      case .resolved(let value):
        state = .consumed
        lock.unlock()
        continuation.resume(returning: value)
      case .waiting, .consumed:
        lock.unlock()
        preconditionFailure("MetricsWidgetOneShot supports one waiter")
      }
    }
  }

  @discardableResult
  func resolve(_ value: Value) -> Bool {
    lock.lock()
    switch state {
    case .pending:
      state = .resolved(value)
      lock.unlock()
      return true
    case .waiting(let continuation):
      state = .consumed
      lock.unlock()
      continuation.resume(returning: value)
      return true
    case .resolved, .consumed:
      lock.unlock()
      return false
    }
  }
}

/// A cancelled joiner must return immediately without cancelling a shared
/// flight another visible Widget still awaits. Marking cancellation before the
/// actor updates its waiter count also prevents a simultaneous flight success
/// from winning after this caller has already been cancelled.
private final class MetricsWidgetWaiterGate: @unchecked Sendable {
  private let lock = NSLock()
  private let result = MetricsWidgetOneShot<MetricsWidgetRefreshOutcome>()
  private var cancellationRequested = false

  func wait() async -> MetricsWidgetRefreshOutcome {
    await result.wait()
  }

  func requestCancellation() {
    lock.lock()
    cancellationRequested = true
    lock.unlock()
  }

  func resolveFromFlight(_ outcome: MetricsWidgetRefreshOutcome) {
    lock.lock()
    guard !cancellationRequested else {
      lock.unlock()
      return
    }
    _ = result.resolve(outcome)
    lock.unlock()
  }

  func resolveCancellation() {
    _ = result.resolve(.fallback)
  }
}

private actor MetricsWidgetRefreshPermitPool {
  private struct Waiter {
    var id: UUID
    var continuation: CheckedContinuation<Bool, Never>
  }

  private let limit: Int
  private var available: Int
  private var waiters: [Waiter] = []

  init(limit: Int) {
    self.limit = max(1, limit)
    available = max(1, limit)
  }

  func withPermit<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await acquire()
    defer { release() }
    try Task.checkCancellation()
    return try await operation()
  }

  private func acquire() async throws {
    try Task.checkCancellation()
    if available > 0 {
      available -= 1
      return
    }

    let id = UUID()
    let acquired = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        waiters.append(Waiter(id: id, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
    guard acquired else { throw CancellationError() }
    do {
      try Task.checkCancellation()
    } catch {
      release()
      throw error
    }
  }

  private func cancelWaiter(_ id: UUID) {
    if let index = waiters.firstIndex(where: { $0.id == id }) {
      let waiter = waiters.remove(at: index)
      waiter.continuation.resume(returning: false)
    }
  }

  private func release() {
    if waiters.isEmpty {
      available = min(limit, available + 1)
    } else {
      let waiter = waiters.removeFirst()
      waiter.continuation.resume(returning: true)
    }
  }
}

private enum MetricsWidgetRefreshError: Error {
  case timedOut
}

private struct MetricsWidgetSendableError: Error, @unchecked Sendable {
  var underlying: any Error
}

private enum MetricsWidgetAsyncResult<Value: Sendable>: Sendable {
  case success(Value)
  case failure(MetricsWidgetSendableError)
}

private func withMetricsWidgetTimeout<Value: Sendable>(
  _ timeout: Duration,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  let result = MetricsWidgetOneShot<MetricsWidgetAsyncResult<Value>>()
  let operationTask = Task {
    do {
      result.resolve(.success(try await operation()))
    } catch {
      result.resolve(.failure(MetricsWidgetSendableError(underlying: error)))
    }
  }
  let timeoutTask = Task {
    do {
      try await Task.sleep(for: timeout)
      result.resolve(
        .failure(MetricsWidgetSendableError(underlying: MetricsWidgetRefreshError.timedOut)))
    } catch {
      // The operation won and cancelled this timer.
    }
  }
  let resolved = await withTaskCancellationHandler {
    await result.wait()
  } onCancel: {
    operationTask.cancel()
    timeoutTask.cancel()
    result.resolve(
      .failure(MetricsWidgetSendableError(underlying: CancellationError())))
  }
  operationTask.cancel()
  timeoutTask.cancel()
  switch resolved {
  case .success(let value): return value
  case .failure(let error): throw error.underlying
  }
}

// MARK: - Live Cloudflare loading

struct CloudflareMetricsWidgetLoader: Sendable {
  let client: CloudflareClient

  func load(_ target: MetricsWidgetRefreshTarget) async throws
    -> MetricsWidgetRefreshPayload
  {
    switch target {
    case .account(let accountID, let accountName, let range, let resolvesMetadata):
      if resolvesMetadata {
        async let account = client.getAccount(accountID)
        async let analytics = client.accountAnalytics(
          accountID: accountID,
          hours: range.hours,
          granularity: range.accountAnalyticsGranularity)
        return try await makeAccountPayload(
          accountID: accountID,
          accountName: account.name,
          range: range,
          analytics: analytics)
      }
      let analytics = try await client.accountAnalytics(
        accountID: accountID,
        hours: range.hours,
        granularity: range.accountAnalyticsGranularity)
      return makeAccountPayload(
        accountID: accountID,
        accountName: accountName,
        range: range,
        analytics: analytics)

    case .domain(
      let accountID,
      let accountName,
      let domainID,
      let domainName,
      let range,
      let resolvesMetadata):
      if resolvesMetadata {
        async let account = client.getAccount(accountID)
        async let zone = client.getZone(domainID)
        async let comparison = loadDomainComparison(domainID: domainID, range: range)
        return try await makeDomainPayload(
          accountID: accountID,
          accountName: account.name,
          domainID: domainID,
          domainName: zone.name,
          range: range,
          comparison: comparison)
      }
      let comparison = try await loadDomainComparison(domainID: domainID, range: range)
      return makeDomainPayload(
        accountID: accountID,
        accountName: accountName,
        domainID: domainID,
        domainName: domainName,
        range: range,
        comparison: comparison)
    }
  }

  private func loadDomainComparison(
    domainID: String,
    range: MetricsWidgetRange
  ) async throws -> MetricsWidgetDomainComparison {
    switch range {
    case .day:
      let result = try await client.zoneAnalyticsHourlyComparison(
        zoneID: domainID,
        hours: range.hours)
      return MetricsWidgetDomainComparison(
        current: result.current.compactMap(MetricsWidgetDomainPoint.init),
        previous: result.previous?.compactMap(MetricsWidgetDomainPoint.init))
    case .week, .month:
      let result = try await client.zoneAnalyticsComparison(
        zoneID: domainID,
        days: range.hours / 24)
      return MetricsWidgetDomainComparison(
        current: result.current.compactMap(MetricsWidgetDomainPoint.init),
        previous: result.previous?.compactMap(MetricsWidgetDomainPoint.init))
    }
  }
}

extension MetricsWidgetRemoteRefreshCoordinator {
  static let live: MetricsWidgetRemoteRefreshCoordinator = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 9
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpMaximumConnectionsPerHost = 2
    let session = URLSession(configuration: configuration)
    let clientID = Bundle.main.object(forInfoDictionaryKey: "DASHClientID") as? String ?? ""
    let tokenStore = KeychainTokenStore()
    let loader = CloudflareMetricsWidgetLoader(
      client: CloudflareClient(
        clientID: clientID,
        tokenStore: tokenStore,
        session: session))
    let credentialValidator = MetricsWidgetCredentialValidator(
      readAccessToken: { try await tokenStore.getAccessToken() },
      invalidate: { expectedGeneration in
        guard let url = MetricsWidgetSnapshotStore.containerFileURL else {
          throw CocoaError(.fileNoSuchFile)
        }
        _ = try MetricsWidgetSnapshotRepository.invalidateAndClear(
          at: url,
          expectedGeneration: expectedGeneration)
      })
    return MetricsWidgetRemoteRefreshCoordinator(
      credentialValidator: credentialValidator,
      remoteSessionValidator: { expectedGeneration in
        guard let url = MetricsWidgetSnapshotStore.containerFileURL else {
          throw CocoaError(.fileNoSuchFile)
        }
        let state = try MetricsWidgetSnapshotRepository.read(at: url)
        guard state.generation == expectedGeneration else {
          throw MetricsWidgetSnapshotRepository.RepositoryError.generationMismatch(
            expected: expectedGeneration,
            actual: state.generation)
        }
        guard state.mode == .remoteEnabled else {
          throw MetricsWidgetSnapshotRepository.RepositoryError.remoteRefreshDisabled
        }
      },
      loader: { try await loader.load($0) },
      persister: { payload, generation in
        try MetricsWidgetLiveSnapshotPersistence.persist(
          payload,
          expectedGeneration: generation)
      })
  }()
}

private enum MetricsWidgetLiveSnapshotPersistence {
  static func persist(
    _ payload: MetricsWidgetRefreshPayload,
    expectedGeneration: UInt64
  ) throws {
    guard let url = MetricsWidgetSnapshotStore.containerFileURL else {
      throw CocoaError(.fileNoSuchFile)
    }
    _ = try MetricsWidgetSnapshotRepository.update(
      at: url,
      expectedGeneration: expectedGeneration,
      requiresRemoteEnabled: true
    ) { store in
      switch payload {
      case .account(let account, let snapshot):
        ensure(account: account, in: &store)
        store.upsert(accountSnapshot: snapshot)
      case .domain(let account, let domain, let snapshot):
        ensure(account: account, in: &store)
        store.mergeDomains([domain], forAccountID: account.id)
        store.upsert(domainSnapshot: snapshot)
      }
    }
  }

  private static func ensure(
    account: MetricsWidgetAccount,
    in store: inout MetricsWidgetSnapshotStore
  ) {
    var accounts = store.accounts.filter { $0.id != account.id }
    accounts.append(account)
    store.setAccounts(accounts, activeAccountID: store.activeAccountID)
  }
}

// MARK: - Render-ready mapping

private func makeAccountPayload(
  accountID: String,
  accountName: String,
  range: MetricsWidgetRange,
  analytics: AccountAnalyticsSnapshot
) -> MetricsWidgetRefreshPayload {
  let httpPoints = analytics.httpPoints.compactMap { point in
    MetricsWidgetTimestampParser.parse(point.datetime).map { (timestamp: $0, point: point) }
  }
  let workerPoints = analytics.workerPoints.compactMap { point in
    MetricsWidgetTimestampParser.parse(point.datetime).map { (timestamp: $0, point: point) }
  }
  let metrics = AccountMetricsWidgetMetric.allCases.map { metric in
    let source = metric.usesHTTPSeries ? httpPoints : workerPoints
    return MetricsWidgetMetricSnapshot(
      metric: metric,
      total: metric.total(in: analytics.overview),
      previousTotal: analytics.previousOverview.map(metric.total(in:)),
      points: source.map { sample in
        MetricsWidgetPoint(
          timestamp: sample.timestamp,
          value: metric.value(in: sample.point))
      })
  }
  let account = MetricsWidgetAccount(id: accountID, name: accountName)
  return .account(
    account: account,
    snapshot: AccountMetricsWidgetSnapshot(
      accountID: accountID,
      accountName: accountName,
      range: range,
      metrics: metrics,
      fetchedAt: analytics.fetchedAt))
}

extension AccountMetricsWidgetMetric {
  fileprivate var usesHTTPSeries: Bool {
    switch self {
    case .workerInvocations, .workerErrors, .cpuTime: false
    case .webTraffic, .totalBandwidth, .cacheRate, .clientRequestErrors,
      .encryptedRequestsRate, .encryptedBandwidth:
      true
    }
  }

  fileprivate func total(in overview: AccountAnalyticsOverview) -> Double {
    switch self {
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

  fileprivate func value(in point: AccountAnalyticsPoint) -> Double {
    switch self {
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
}

private struct MetricsWidgetDomainPoint: Hashable, Sendable {
  var timestamp: Date
  var requests: Int
  var bytes: Int64
  var cachedRequests: Int
  var threats: Int
  var uniques: Int

  private init(
    timestamp: Date,
    requests: Int,
    bytes: Int64,
    cachedRequests: Int,
    threats: Int,
    uniques: Int
  ) {
    self.timestamp = timestamp
    self.requests = requests
    self.bytes = bytes
    self.cachedRequests = cachedRequests
    self.threats = threats
    self.uniques = uniques
  }

  init?(_ point: ZoneAnalyticsPoint) {
    guard let timestamp = MetricsWidgetTimestampParser.parse(point.datetime) else { return nil }
    self.init(
      timestamp: timestamp,
      requests: point.requests,
      bytes: point.bytes,
      cachedRequests: point.cachedRequests,
      threats: point.threats,
      uniques: point.uniques)
  }

  init?(_ point: ZoneAnalyticsDay) {
    guard let timestamp = MetricsWidgetTimestampParser.parseDay(point.date) else { return nil }
    self.init(
      timestamp: timestamp,
      requests: point.requests,
      bytes: point.bytes,
      cachedRequests: point.cachedRequests,
      threats: point.threats,
      uniques: point.uniques)
  }
}

private struct MetricsWidgetDomainComparison: Sendable {
  var current: [MetricsWidgetDomainPoint]
  var previous: [MetricsWidgetDomainPoint]?
}

private func makeDomainPayload(
  accountID: String,
  accountName: String,
  domainID: String,
  domainName: String,
  range: MetricsWidgetRange,
  comparison: MetricsWidgetDomainComparison,
  fetchedAt: Date = .now
) -> MetricsWidgetRefreshPayload {
  let current = comparison.current.sorted { $0.timestamp < $1.timestamp }
  let previous = comparison.previous
  let metrics = DomainMetricsWidgetMetric.allCases.map { metric in
    MetricsWidgetMetricSnapshot(
      metric: metric,
      total: metric.total(in: current),
      previousTotal: previous.flatMap { metric.previousTotal(in: $0) },
      points: current.map {
        MetricsWidgetPoint(timestamp: $0.timestamp, value: metric.value(in: $0))
      })
  }
  let account = MetricsWidgetAccount(id: accountID, name: accountName)
  let domain = MetricsWidgetDomain(
    id: domainID,
    name: domainName,
    accountID: accountID,
    accountName: accountName,
    avatarSeed: domainName)
  return .domain(
    account: account,
    domain: domain,
    snapshot: DomainMetricsWidgetSnapshot(
      domainID: domainID,
      domainName: domainName,
      accountID: accountID,
      accountName: accountName,
      avatarSeed: domain.avatarSeed,
      range: range,
      metrics: metrics,
      fetchedAt: fetchedAt))
}

extension DomainMetricsWidgetMetric {
  fileprivate func total(in points: [MetricsWidgetDomainPoint]) -> Double {
    switch self {
    case .requests: return Double(points.reduce(0) { $0 + $1.requests })
    case .bandwidth: return Double(points.reduce(Int64(0)) { $0 + $1.bytes })
    case .cacheRate:
      let requests = points.reduce(0) { $0 + $1.requests }
      guard requests > 0 else { return 0 }
      let cached = points.reduce(0) { $0 + $1.cachedRequests }
      return Double(cached) / Double(requests)
    case .threats: return Double(points.reduce(0) { $0 + $1.threats })
    case .uniqueVisitors: return Double(points.map(\.uniques).max() ?? 0)
    }
  }

  fileprivate func previousTotal(in points: [MetricsWidgetDomainPoint]) -> Double? {
    switch self {
    case .requests, .bandwidth, .uniqueVisitors:
      total(in: points)
    case .cacheRate, .threats:
      nil
    }
  }

  fileprivate func value(in point: MetricsWidgetDomainPoint) -> Double {
    switch self {
    case .requests: return Double(point.requests)
    case .bandwidth: return Double(point.bytes)
    case .cacheRate:
      guard point.requests > 0 else { return 0 }
      return Double(point.cachedRequests) / Double(point.requests)
    case .threats: return Double(point.threats)
    case .uniqueVisitors: return Double(point.uniques)
    }
  }
}

private enum MetricsWidgetTimestampParser {
  static func parse(_ value: String) -> Date? {
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    if let date = standard.date(from: value) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? parseDay(value)
  }

  static func parseDay(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value)
  }
}
