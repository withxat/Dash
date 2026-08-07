@preconcurrency import ActivityKit
import CloudflareAPI
import Foundation

struct PagesBuildMonitorKey: Hashable, Sendable {
  let accountID: String
  let accountGeneration: UInt64
  let projectName: String
  let deploymentID: String
}

enum LegacyPagesBuildPushTokenStore {
  static let keyPrefix = "dash.pages.live_activity_push_token."

  static func clear(defaults: UserDefaults = .standard) {
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
      defaults.removeObject(forKey: key)
    }
  }
}

enum PagesBuildRefreshSource: Equatable, Sendable {
  case initial
  case poll
  case manual

  fileprivate func coalesced(with other: Self) -> Self {
    coalescingPriority >= other.coalescingPriority ? self : other
  }

  private var coalescingPriority: Int {
    switch self {
    case .manual: 3
    case .initial: 2
    case .poll: 1
    }
  }
}

enum PagesBuildMonitorEvent: Sendable {
  case deployment(PagesDeployment, source: PagesBuildRefreshSource)
  case failure(message: String, terminal: Bool, source: PagesBuildRefreshSource)
}

enum PagesBuildLogRefreshPolicy {
  static func shouldRefresh(
    hasRequestedLogs: Bool,
    previousWasInProgress: Bool,
    latestIsInProgress: Bool,
    source: PagesBuildRefreshSource
  ) -> Bool {
    !hasRequestedLogs
      || source == .manual
      || (previousWasInProgress && !latestIsInProgress)
  }
}

enum BuildMonitorRefreshDisposition: Equatable, Sendable {
  case cancel
  case retry
  case stop

  static func classify(_ error: any Error) -> BuildMonitorRefreshDisposition {
    if error.dashIsCancellation {
      return .cancel
    }
    guard let error = error as? CloudflareAPIError else {
      return .retry
    }
    switch error {
    case .request(let status, _):
      if status == 408 || status == 429 || status >= 500 {
        return .retry
      }
      return .stop
    case .oauth(let message):
      return message == "invalid_grant" ? .stop : .retry
    case .invalidResponse, .transport:
      return .retry
    }
  }

  static func retryDelaySeconds(consecutiveFailures: Int) -> Int {
    let delays = [10, 20, 40, 60]
    return delays[min(max(consecutiveFailures, 0), delays.count - 1)]
  }
}

enum BuildActivityPresentationRules {
  /// Pages and Workers share one Lock Screen freshness contract.
  static let staleAfter: TimeInterval = 3 * 60
}

/// Starts, updates, and ends the single poll-driven Pages build Live Activity.
///
/// The monitor is also the deployment detail's source of truth, so foreground
/// UI, Live Activity, and pull-to-refresh never create competing periodic loops
/// for the same deployment.
@MainActor
enum PagesBuildActivityController {
  static let shared = PagesBuildActivityControllerBox()

  /// Activities created by older releases had no stale date because Pages used
  /// a background task and requested an unused push token. Constrain those
  /// survivors on upgrade so removing both mechanisms cannot leave an eternal
  /// "Building…" state on the Lock Screen.
  static func addStaleDatesToLegacyActivities() async {
    for activity in Activity<PagesBuildAttributes>.activities
    where activity.content.staleDate == nil {
      await activity.update(
        ActivityContent(
          state: activity.content.state,
          staleDate: Date(timeIntervalSinceNow: BuildActivityPresentationRules.staleAfter)))
    }
  }
}

@MainActor
final class PagesBuildActivityControllerBox {
  private struct Monitor {
    let key: PagesBuildMonitorKey
    let client: CloudflareClient
    var continuations: [UUID: AsyncStream<PagesBuildMonitorEvent>.Continuation] = [:]
    var latest: PagesDeployment?
    var consecutiveFailures = 0
    var retryPending = false
    var keepsAliveForActivity = false
  }

  private final class RefreshTask {
    private struct Waiter {
      let source: PagesBuildRefreshSource
      let continuation: CheckedContinuation<RefreshResult, Never>
    }

    let id: UUID
    var task: Task<Void, Never>?
    fileprivate var waiterCount: Int { waiters.count }
    private var waiters: [UUID: Waiter] = [:]

    init(id: UUID = UUID()) {
      self.id = id
    }

    var source: PagesBuildRefreshSource {
      waiters.values.reduce(.poll) { current, waiter in
        current.coalesced(with: waiter.source)
      }
    }

    func addWaiter(
      id: UUID,
      source: PagesBuildRefreshSource,
      continuation: CheckedContinuation<RefreshResult, Never>
    ) {
      waiters[id] = Waiter(source: source, continuation: continuation)
    }

    func removeWaiter(id: UUID) -> CheckedContinuation<RefreshResult, Never>? {
      waiters.removeValue(forKey: id)?.continuation
    }

    func drainWaiters() -> [CheckedContinuation<RefreshResult, Never>] {
      let continuations = waiters.values.map(\.continuation)
      waiters.removeAll()
      return continuations
    }

    func cancel() {
      task?.cancel()
      task = nil
      for continuation in drainWaiters() {
        continuation.resume(returning: .cancelled)
      }
    }
  }

  private enum RefreshResult: Sendable {
    case inProgress
    case terminal
    case retry
    case cancelled
  }

  private var monitor: Monitor?
  private var pollTask: Task<Void, Never>?
  private var pollID: UUID?
  private var refreshTasks: [PagesBuildMonitorKey: RefreshTask] = [:]
  private var activityCleanupTask: Task<Void, Never>?
  private var invalidationSerial: UInt64 = 0
  private let fetchDeployment:
    @Sendable (CloudflareClient, PagesBuildMonitorKey) async throws -> PagesDeployment

  init(
    fetchDeployment:
      @escaping @Sendable (
        CloudflareClient, PagesBuildMonitorKey
      ) async throws -> PagesDeployment = { client, key in
        try await client.getPagesDeployment(
          accountID: key.accountID,
          projectName: key.projectName,
          deploymentID: key.deploymentID)
      }
  ) {
    self.fetchDeployment = fetchDeployment
  }

  func updates(
    for key: PagesBuildMonitorKey,
    client: CloudflareClient
  ) -> AsyncStream<PagesBuildMonitorEvent> {
    if monitor?.key != key {
      stopMonitor(cancelRefresh: true)
      monitor = Monitor(
        key: key,
        client: client,
        keepsAliveForActivity: hasActivity(for: key))
    }

    let observerID = UUID()
    let (stream, continuation) = AsyncStream.makeStream(
      of: PagesBuildMonitorEvent.self,
      bufferingPolicy: .bufferingNewest(4))
    monitor?.continuations[observerID] = continuation
    if let latest = monitor?.latest {
      continuation.yield(.deployment(latest, source: .initial))
    }
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.removeObserver(observerID, for: key)
      }
    }
    return stream
  }

  func refresh(
    key: PagesBuildMonitorKey,
    client: CloudflareClient,
    source: PagesBuildRefreshSource
  ) async {
    _ = await refreshDeployment(key: key, client: client, source: source)
  }

  /// Adopts a build Dash itself just started, using the deployment the create
  /// call already returned.
  ///
  /// Without this the Live Activity waits a full request for the re-keyed
  /// screen's initial refresh to discover what we were just told. Builds started
  /// outside Dash keep that discovery path — it is the only thing that can find
  /// them — but a build triggered from this app should not have to be
  /// rediscovered.
  ///
  /// A finished deployment is ignored: `retryPagesDeployment` can hand back
  /// something already terminal, and raising a Live Activity for it would put a
  /// build that is over on the Lock Screen.
  func adopt(
    deployment: PagesDeployment,
    key: PagesBuildMonitorKey,
    client: CloudflareClient
  ) async {
    guard deployment.isInProgress else { return }
    let serial = invalidationSerial
    let keepsActivity = await startOrUpdate(
      projectName: key.projectName,
      deployment: deployment,
      accountID: key.accountID,
      serial: serial)
    guard !Task.isCancelled, serial == invalidationSerial else { return }

    if monitor?.key != key {
      stopMonitor(cancelRefresh: true)
      monitor = Monitor(key: key, client: client, keepsAliveForActivity: keepsActivity)
    } else {
      monitor?.keepsAliveForActivity = keepsActivity
    }
    monitor?.latest = deployment
    monitor?.consecutiveFailures = 0
    monitor?.retryPending = false
    broadcast(.deployment(deployment, source: .initial), for: key)
    updatePolling()
  }

  /// Synchronously cuts every account-scoped task off before AppModel swaps
  /// account or client state. Captured Activity values are ended asynchronously;
  /// a newly-created activity cannot be swept up by this cleanup.
  func invalidateSession() {
    invalidationSerial &+= 1
    stopMonitor(cancelRefresh: true)
    let tasks = Array(refreshTasks.values)
    refreshTasks.removeAll()
    for task in tasks {
      task.cancel()
    }

    let activities = Activity<PagesBuildAttributes>.activities
    activityCleanupTask?.cancel()
    activityCleanupTask = Task {
      for activity in activities {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
    }
  }

  private func refreshDeployment(
    key: PagesBuildMonitorKey,
    client: CloudflareClient,
    source: PagesBuildRefreshSource
  ) async -> RefreshResult {
    let waiterID = UUID()
    let cancellation = PagesRefreshWaiterCancellationState()
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<RefreshResult, Never>) in
        let refresh: RefreshTask
        if let existing = refreshTasks[key] {
          refresh = existing
        } else {
          refresh = RefreshTask()
          refreshTasks[key] = refresh
        }

        guard cancellation.bind(loadID: refresh.id) else {
          if refresh.waiterCount == 0, refreshTasks[key]?.id == refresh.id {
            refreshTasks.removeValue(forKey: key)
          }
          continuation.resume(returning: .cancelled)
          return
        }

        refresh.addWaiter(id: waiterID, source: source, continuation: continuation)
        guard refresh.task == nil else { return }
        let loadID = refresh.id
        let serial = invalidationSerial
        refresh.task = Task { [self] in
          await runRefresh(
            key: key,
            client: client,
            loadID: loadID,
            serial: serial)
        }
      }
    } onCancel: { [weak self] in
      guard let loadID = cancellation.cancel() else { return }
      Task { @MainActor [weak self] in
        self?.cancelRefreshWaiter(key: key, loadID: loadID, waiterID: waiterID)
      }
    }
    return Task.isCancelled ? .cancelled : result
  }

  private func cancelRefreshWaiter(
    key: PagesBuildMonitorKey,
    loadID: UUID,
    waiterID: UUID
  ) {
    guard let refresh = refreshTasks[key], refresh.id == loadID,
      let continuation = refresh.removeWaiter(id: waiterID)
    else { return }
    continuation.resume(returning: .cancelled)
    if refresh.waiterCount == 0 {
      refreshTasks.removeValue(forKey: key)
      refresh.task?.cancel()
      refresh.task = nil
    }
  }

  private func completeRefresh(
    key: PagesBuildMonitorKey,
    loadID: UUID,
    result: RefreshResult
  ) {
    guard let refresh = refreshTasks[key], refresh.id == loadID else { return }
    refreshTasks.removeValue(forKey: key)
    refresh.task = nil
    for continuation in refresh.drainWaiters() {
      continuation.resume(returning: result)
    }
  }

  private func runRefresh(
    key: PagesBuildMonitorKey,
    client: CloudflareClient,
    loadID: UUID,
    serial: UInt64
  ) async {
    do {
      let interval = DashPerformance.signposter.beginInterval("PagesBuild.Fetch")
      defer {
        DashPerformance.signposter.endInterval("PagesBuild.Fetch", interval)
      }
      try Task.checkCancellation()
      let latest = try await fetchDeployment(client, key)
      try Task.checkCancellation()
      guard serial == invalidationSerial, refreshTasks[key]?.id == loadID else {
        completeRefresh(key: key, loadID: loadID, result: .cancelled)
        return
      }
      await applyAndComplete(latest, key: key, loadID: loadID, serial: serial)
    } catch {
      await applyFailureAndComplete(
        error, key: key, loadID: loadID, serial: serial)
    }
  }

  private func applyAndComplete(
    _ deployment: PagesDeployment,
    key: PagesBuildMonitorKey,
    loadID: UUID,
    serial: UInt64
  ) async {
    guard !Task.isCancelled, serial == invalidationSerial,
      refreshTasks[key]?.id == loadID
    else {
      completeRefresh(key: key, loadID: loadID, result: .cancelled)
      return
    }

    let keepsActivity: Bool
    if deployment.isInProgress {
      keepsActivity = await startOrUpdate(
        projectName: key.projectName,
        deployment: deployment,
        accountID: key.accountID,
        serial: serial)
    } else {
      keepsActivity = false
      await end(
        deployment: deployment,
        accountID: key.accountID,
        serial: serial)
    }
    guard !Task.isCancelled, serial == invalidationSerial,
      let refresh = refreshTasks[key], refresh.id == loadID
    else {
      completeRefresh(key: key, loadID: loadID, result: .cancelled)
      return
    }
    let source = refresh.source

    if monitor?.key == key {
      monitor?.latest = deployment
      monitor?.consecutiveFailures = 0
      monitor?.retryPending = false
      monitor?.keepsAliveForActivity = keepsActivity
      broadcast(.deployment(deployment, source: source), for: key)
    }

    if deployment.isInProgress {
      completeRefresh(key: key, loadID: loadID, result: .inProgress)
      updatePolling()
      return
    }

    completeRefresh(key: key, loadID: loadID, result: .terminal)
    updatePolling()
  }

  private func applyFailureAndComplete(
    _ error: any Error,
    key: PagesBuildMonitorKey,
    loadID: UUID,
    serial: UInt64
  ) async {
    guard !Task.isCancelled, serial == invalidationSerial,
      refreshTasks[key]?.id == loadID
    else {
      completeRefresh(key: key, loadID: loadID, result: .cancelled)
      return
    }

    let disposition = BuildMonitorRefreshDisposition.classify(error)
    guard disposition != .cancel else {
      completeRefresh(key: key, loadID: loadID, result: .cancelled)
      return
    }

    if disposition == .stop {
      await endActivity(for: key, serial: serial)
      guard !Task.isCancelled, serial == invalidationSerial,
        refreshTasks[key]?.id == loadID
      else {
        completeRefresh(key: key, loadID: loadID, result: .cancelled)
        return
      }
    }

    guard let refresh = refreshTasks[key], refresh.id == loadID else { return }
    let source = refresh.source
    if monitor?.key == key {
      monitor?.retryPending = disposition == .retry
      if disposition == .retry {
        monitor?.consecutiveFailures += 1
      } else {
        monitor?.latest = nil
        monitor?.keepsAliveForActivity = false
      }
      broadcast(
        .failure(
          message: error.dashActionableMessage,
          terminal: disposition == .stop,
          source: source),
        for: key)
    }

    switch disposition {
    case .cancel:
      completeRefresh(key: key, loadID: loadID, result: .cancelled)
    case .retry:
      completeRefresh(key: key, loadID: loadID, result: .retry)
      if monitor?.key == key {
        updatePolling()
      }
    case .stop:
      completeRefresh(key: key, loadID: loadID, result: .terminal)
      if monitor?.key == key {
        updatePolling()
      }
    }
  }

  private func updatePolling() {
    guard let monitor else {
      stopPolling()
      return
    }
    let needsUpdates = monitor.latest?.isInProgress == true || monitor.retryPending
    let hasConsumer = !monitor.continuations.isEmpty || monitor.keepsAliveForActivity
    guard needsUpdates, hasConsumer else {
      stopPolling()
      if monitor.continuations.isEmpty, !monitor.keepsAliveForActivity {
        stopMonitor(cancelRefresh: true)
      }
      return
    }
    guard pollTask == nil else { return }

    let id = UUID()
    pollID = id
    pollTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if pollID == id {
          pollTask = nil
          pollID = nil
        }
      }
      while !Task.isCancelled {
        guard let current = self.monitor else { return }
        let delay = BuildMonitorRefreshDisposition.retryDelaySeconds(
          consecutiveFailures: current.consecutiveFailures)
        do {
          try await Task.sleep(for: .seconds(Double(delay)))
        } catch {
          return
        }
        guard !Task.isCancelled, self.monitor?.key == current.key else { return }
        _ = await refreshDeployment(
          key: current.key,
          client: current.client,
          source: .poll)
      }
    }
  }

  private func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
    pollID = nil
  }

  private func stopMonitor(cancelRefresh: Bool) {
    guard let current = monitor else {
      stopPolling()
      return
    }
    stopPolling()
    monitor = nil
    for continuation in current.continuations.values {
      continuation.finish()
    }
    if cancelRefresh {
      refreshTasks.removeValue(forKey: current.key)?.cancel()
    }
  }

  private func removeObserver(_ observerID: UUID, for key: PagesBuildMonitorKey) {
    guard monitor?.key == key else { return }
    monitor?.continuations.removeValue(forKey: observerID)
    updatePolling()
  }

  private func broadcast(_ event: PagesBuildMonitorEvent, for key: PagesBuildMonitorKey) {
    guard let monitor, monitor.key == key else { return }
    for continuation in monitor.continuations.values {
      continuation.yield(event)
    }
  }

  private func hasActivity(for key: PagesBuildMonitorKey) -> Bool {
    Activity<PagesBuildAttributes>.activities.contains {
      $0.attributes.accountID == key.accountID
        && $0.attributes.deploymentID == key.deploymentID
    }
  }

  private func startOrUpdate(
    projectName: String,
    deployment: PagesDeployment,
    accountID: String,
    serial: UInt64
  ) async -> Bool {
    if let activityCleanupTask {
      await activityCleanupTask.value
    }
    guard !Task.isCancelled, serial == invalidationSerial else { return false }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
    let state = PagesBuildAttributes.ContentState(
      stage: deployment.latestStage?.name ?? "build",
      status: deployment.latestStage?.status ?? "active",
      shortID: deployment.shortID ?? String(deployment.id.prefix(8)))
    let content = ActivityContent(
      state: state,
      staleDate: Date(timeIntervalSinceNow: BuildActivityPresentationRules.staleAfter))

    if let existing = Activity<PagesBuildAttributes>.activities.first(where: {
      $0.attributes.accountID == accountID
        && $0.attributes.deploymentID == deployment.id
    }) {
      await existing.update(content)
      return !Task.isCancelled && serial == invalidationSerial
    }

    for activity in Activity<PagesBuildAttributes>.activities {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
    guard !Task.isCancelled, serial == invalidationSerial else { return false }

    let attributes = PagesBuildAttributes(
      accountID: accountID,
      projectName: projectName,
      deploymentID: deployment.id)
    return (try? Activity.request(attributes: attributes, content: content, pushType: nil)) != nil
  }

  private func end(
    deployment: PagesDeployment,
    accountID: String,
    serial: UInt64
  ) async {
    if let activityCleanupTask {
      await activityCleanupTask.value
    }
    guard !Task.isCancelled, serial == invalidationSerial else { return }

    for activity in Activity<PagesBuildAttributes>.activities
    where activity.attributes.deploymentID == deployment.id
      && (activity.attributes.accountID == accountID || activity.attributes.accountID == nil)
    {
      await activity.end(
        ActivityContent(
          state: PagesBuildAttributes.ContentState(
            stage: deployment.latestStage?.name ?? "deploy",
            status: deployment.latestStage?.status ?? deployment.statusLabel.lowercased(),
            shortID: deployment.shortID ?? String(deployment.id.prefix(8))),
          staleDate: nil),
        dismissalPolicy: .default)
    }
  }

  private func endActivity(for key: PagesBuildMonitorKey, serial: UInt64) async {
    if let activityCleanupTask {
      await activityCleanupTask.value
    }
    guard !Task.isCancelled, serial == invalidationSerial else { return }

    for activity in Activity<PagesBuildAttributes>.activities
    where activity.attributes.deploymentID == key.deploymentID
      && (activity.attributes.accountID == key.accountID || activity.attributes.accountID == nil)
    {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
  }
}

private final class PagesRefreshWaiterCancellationState: @unchecked Sendable {
  private let lock = NSLock()
  private var loadID: UUID?
  private var isCancelled = false

  func bind(loadID: UUID) -> Bool {
    lock.withLock {
      self.loadID = loadID
      return !isCancelled
    }
  }

  func cancel() -> UUID? {
    lock.withLock {
      guard !isCancelled else { return nil }
      isCancelled = true
      return loadID
    }
  }
}
