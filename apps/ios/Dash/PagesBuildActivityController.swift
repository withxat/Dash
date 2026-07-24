@preconcurrency import ActivityKit
import BackgroundTasks
import CloudflareAPI
import Foundation
import OSLog

struct PagesBuildMonitorKey: Hashable, Sendable {
  let accountID: String
  let accountGeneration: UInt64
  let projectName: String
  let deploymentID: String
}

enum PagesBuildRefreshSource: Equatable, Sendable {
  case initial
  case poll
  case manual
  case background

  fileprivate func coalesced(with other: Self) -> Self {
    coalescingPriority >= other.coalescingPriority ? self : other
  }

  private var coalescingPriority: Int {
    switch self {
    case .manual: 3
    case .initial: 2
    case .poll: 1
    case .background: 0
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

enum PagesBuildRefreshDisposition: Equatable, Sendable {
  case cancel
  case retry
  case stop

  static func classify(_ error: any Error) -> PagesBuildRefreshDisposition {
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

/// Starts, updates, and ends the single poll-driven Pages build Live Activity.
///
/// The monitor is also the deployment detail's source of truth, so foreground
/// UI, Live Activity, pull-to-refresh, and BGAppRefresh never create competing
/// periodic loops for the same deployment.
@MainActor
enum PagesBuildActivityController {
  static let shared = PagesBuildActivityControllerBox()
  static let backgroundRefreshID = "sh.xat.dash.app.pages-build-refresh"
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
      waiters.values.reduce(.background) { current, waiter in
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
  private var pushTokenTask: Task<Void, Never>?
  private var pushTokenActivityID: String?
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

  #if DEBUG
    func debugRefreshWaiterCount(for key: PagesBuildMonitorKey) -> Int {
      refreshTasks[key]?.waiterCount ?? 0
    }

    func debugConsecutiveFailureCount(for key: PagesBuildMonitorKey) -> Int? {
      guard monitor?.key == key else { return nil }
      return monitor?.consecutiveFailures
    }
  #endif

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
    pushTokenTask?.cancel()
    pushTokenTask = nil
    pushTokenActivityID = nil
    cancelBackgroundRefresh()

    let activities = Activity<PagesBuildAttributes>.activities
    activityCleanupTask?.cancel()
    activityCleanupTask = Task {
      for activity in activities {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
    }
  }

  /// BGAppRefresh always uses the account persisted in the Activity. A legacy
  /// or mismatched activity is ended instead of being queried through the
  /// currently-selected account.
  func performBackgroundRefresh(
    client: CloudflareClient,
    context: AccountRequestContext?
  ) async {
    let serial = invalidationSerial
    if let activityCleanupTask {
      await activityCleanupTask.value
    }
    guard !Task.isCancelled, serial == invalidationSerial else { return }

    guard let activity = Activity<PagesBuildAttributes>.activities.first else {
      cancelBackgroundRefresh()
      return
    }
    guard let sourceAccountID = activity.attributes.accountID,
      let context,
      sourceAccountID == context.accountID
    else {
      await activity.end(nil, dismissalPolicy: .immediate)
      cancelBackgroundRefresh()
      return
    }

    let key = PagesBuildMonitorKey(
      accountID: sourceAccountID,
      accountGeneration: context.generation,
      projectName: activity.attributes.projectName,
      deploymentID: activity.attributes.deploymentID)
    let result = await refreshDeployment(key: key, client: client, source: .background)
    switch result {
    case .inProgress, .retry:
      scheduleBackgroundRefresh()
    case .terminal, .cancelled:
      cancelBackgroundRefresh()
    }
  }

  /// Asks iOS to wake the app to refresh an in-progress Pages LA.
  /// Opportunistic — delivery is not guaranteed; foreground polling remains authoritative.
  func scheduleBackgroundRefresh() {
    let request = BGAppRefreshTaskRequest(
      identifier: PagesBuildActivityController.backgroundRefreshID)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
    try? BGTaskScheduler.shared.submit(request)
  }

  func cancelBackgroundRefresh() {
    BGTaskScheduler.shared.cancel(
      taskRequestWithIdentifier: PagesBuildActivityController.backgroundRefreshID)
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
      if keepsActivity {
        scheduleBackgroundRefresh()
      } else {
        cancelBackgroundRefresh()
      }
      completeRefresh(key: key, loadID: loadID, result: .inProgress)
      updatePolling()
      return
    }

    cancelBackgroundRefresh()
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

    let disposition = PagesBuildRefreshDisposition.classify(error)
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
      cancelBackgroundRefresh()
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
        let delay = PagesBuildRefreshDisposition.retryDelaySeconds(
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

    if let existing = Activity<PagesBuildAttributes>.activities.first(where: {
      $0.attributes.accountID == accountID
        && $0.attributes.deploymentID == deployment.id
    }) {
      await existing.update(ActivityContent(state: state, staleDate: nil))
      guard !Task.isCancelled, serial == invalidationSerial else { return false }
      observePushToken(existing)
      return true
    }

    for activity in Activity<PagesBuildAttributes>.activities {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
    guard !Task.isCancelled, serial == invalidationSerial else { return false }

    let attributes = PagesBuildAttributes(
      accountID: accountID,
      projectName: projectName,
      deploymentID: deployment.id)
    let activity = try? Activity.request(
      attributes: attributes,
      content: ActivityContent(state: state, staleDate: nil),
      pushType: .token)
    if let activity {
      observePushToken(activity)
      return true
    }
    return false
  }

  private func observePushToken(_ activity: Activity<PagesBuildAttributes>) {
    guard pushTokenActivityID != activity.id else { return }
    pushTokenTask?.cancel()
    pushTokenActivityID = activity.id
    pushTokenTask = Task {
      for await tokenData in activity.pushTokenUpdates {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(
          hex,
          forKey: "dash.pages.live_activity_push_token.\(activity.attributes.deploymentID)")
      }
    }
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
      if pushTokenActivityID == activity.id {
        pushTokenTask?.cancel()
        pushTokenTask = nil
        pushTokenActivityID = nil
      }
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
      if pushTokenActivityID == activity.id {
        pushTokenTask?.cancel()
        pushTokenTask = nil
        pushTokenActivityID = nil
      }
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
