@preconcurrency import ActivityKit
import CloudflareAPI
import Foundation

struct WorkerBuildMonitorKey: Hashable, Sendable {
  let accountID: String
  let accountGeneration: UInt64
  let scriptName: String
  let scriptTag: String
}

enum WorkerBuildMonitorEvent: Sendable {
  case build(WorkerBuild?)
  case failure(message: String, terminal: Bool)
}

/// Polls the newest Workers Build for one Worker and drives its Live Activity.
///
/// Deliberately thinner than `PagesBuildActivityController`. That one carries
/// source-aware refresh coalescing and waiter continuations because initial,
/// manual, and polling refreshes can converge on one deployment. A Worker build
/// uses one screen-driven monitor with one in-flight load.
///
/// Cloudflare's Workers build notifications ship through Queue Event
/// Subscriptions rather than notification policies, so Dash's alert bridge does
/// not cover them and this poll is the only signal the app has.
@MainActor
enum WorkerBuildActivityController {
  static let shared = WorkerBuildActivityControllerBox()
}

@MainActor
final class WorkerBuildActivityControllerBox {
  private struct Monitor {
    let key: WorkerBuildMonitorKey
    let client: CloudflareClient
    var observers: [UUID: AsyncStream<WorkerBuildMonitorEvent>.Continuation] = [:]
    var latest: WorkerBuild?
    var consecutiveFailures = 0
    var keepsAliveForActivity = false
  }

  private var monitor: Monitor?
  private var pollTask: Task<Void, Never>?
  private var loadTask: Task<Void, Never>?
  private var activityCleanupTask: Task<Void, Never>?
  private var invalidationSerial: UInt64 = 0
  private let fetchLatest:
    @Sendable (CloudflareClient, WorkerBuildMonitorKey) async throws -> WorkerBuild?

  init(
    fetchLatest:
      @escaping @Sendable (
        CloudflareClient, WorkerBuildMonitorKey
      ) async throws -> WorkerBuild? = { client, key in
        try await client.latestWorkerBuilds(
          accountID: key.accountID, scriptTags: [key.scriptTag])[key.scriptTag]
      }
  ) {
    self.fetchLatest = fetchLatest
  }

  func updates(
    for key: WorkerBuildMonitorKey,
    client: CloudflareClient
  ) -> AsyncStream<WorkerBuildMonitorEvent> {
    if monitor?.key != key {
      stopMonitor()
      monitor = Monitor(
        key: key, client: client, keepsAliveForActivity: hasActivity(for: key))
    }

    let observerID = UUID()
    let (stream, continuation) = AsyncStream.makeStream(
      of: WorkerBuildMonitorEvent.self,
      bufferingPolicy: .bufferingNewest(4))
    monitor?.observers[observerID] = continuation
    if let latest = monitor?.latest {
      continuation.yield(.build(latest))
    }
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.removeObserver(observerID, for: key)
      }
    }
    return stream
  }

  /// Fetches once. Concurrent callers for the *same* key share the in-flight
  /// load rather than opening a second request.
  func refresh(key: WorkerBuildMonitorKey, client: CloudflareClient) async {
    if monitor?.key != key {
      stopMonitor()
      // Cancel rather than join: the in-flight load belongs to the Worker we
      // just navigated away from. Awaiting it and returning would leave the new
      // Worker with no load at all until the next poll — and there is no poll
      // yet, so the section would sit empty.
      loadTask?.cancel()
      loadTask = nil
      monitor = Monitor(
        key: key, client: client, keepsAliveForActivity: hasActivity(for: key))
    }
    if let loadTask {
      await loadTask.value
      return
    }
    let serial = invalidationSerial
    // Unwrap inside the task rather than optional-chaining the call: the latter
    // makes the closure yield `Void?`, so the task types as `Task<()?, Never>`
    // and no longer matches `loadTask`.
    let task = Task { [weak self] in
      guard let self else { return }
      await self.load(key: key, client: client, serial: serial)
    }
    loadTask = task
    await task.value
    if loadTask == task { loadTask = nil }
  }

  /// Cuts every account-scoped task before `AppModel` swaps accounts, and ends
  /// any activity captured at that moment. An activity started after this call
  /// is not swept up.
  func invalidateSession() {
    invalidationSerial &+= 1
    stopMonitor()
    loadTask?.cancel()
    loadTask = nil

    let activities = Activity<WorkerBuildAttributes>.activities
    activityCleanupTask?.cancel()
    activityCleanupTask = Task {
      for activity in activities {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
    }
  }

  private func load(
    key: WorkerBuildMonitorKey,
    client: CloudflareClient,
    serial: UInt64
  ) async {
    do {
      let build = try await fetchLatest(client, key)
      try Task.checkCancellation()
      guard serial == invalidationSerial, monitor?.key == key else { return }

      let keepsActivity: Bool
      if let build, build.isInProgress {
        keepsActivity = await startOrUpdate(build: build, key: key, serial: serial)
      } else {
        keepsActivity = false
        await end(build: build, key: key, serial: serial)
      }
      guard serial == invalidationSerial, monitor?.key == key else { return }

      monitor?.latest = build
      monitor?.consecutiveFailures = 0
      monitor?.keepsAliveForActivity = keepsActivity
      broadcast(.build(build), for: key)
      updatePolling()
    } catch {
      guard !error.dashIsCancellation, serial == invalidationSerial, monitor?.key == key else {
        return
      }
      // A 403 or 404 is permanent (the
      // account has no Workers Builds, or the token cannot see them) and must
      // stop the poll instead of retrying every ten seconds forever.
      let disposition = BuildMonitorRefreshDisposition.classify(error)
      if disposition == .stop {
        await endActivity(for: key, serial: serial)
        guard serial == invalidationSerial, monitor?.key == key else { return }
        monitor?.latest = nil
        monitor?.keepsAliveForActivity = false
      } else {
        monitor?.consecutiveFailures += 1
      }
      broadcast(
        .failure(message: error.dashActionableMessage, terminal: disposition == .stop),
        for: key)
      updatePolling()
    }
  }

  private func updatePolling() {
    guard let monitor else {
      stopPolling()
      return
    }
    let needsUpdates = monitor.latest?.isInProgress == true || monitor.consecutiveFailures > 0
    let hasConsumer = !monitor.observers.isEmpty || monitor.keepsAliveForActivity
    guard needsUpdates, hasConsumer else {
      stopPolling()
      if monitor.observers.isEmpty, !monitor.keepsAliveForActivity {
        stopMonitor()
      }
      return
    }
    guard pollTask == nil else { return }

    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, let current = self.monitor else { return }
        let delay = BuildMonitorRefreshDisposition.retryDelaySeconds(
          consecutiveFailures: current.consecutiveFailures)
        do {
          try await Task.sleep(for: .seconds(Double(delay)))
        } catch {
          return
        }
        guard !Task.isCancelled, self.monitor?.key == current.key else { return }
        await self.refresh(key: current.key, client: current.client)
      }
    }
  }

  private func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

  private func stopMonitor() {
    guard let current = monitor else {
      stopPolling()
      return
    }
    stopPolling()
    monitor = nil
    for continuation in current.observers.values {
      continuation.finish()
    }
  }

  private func removeObserver(_ observerID: UUID, for key: WorkerBuildMonitorKey) {
    guard monitor?.key == key else { return }
    monitor?.observers.removeValue(forKey: observerID)
    updatePolling()
  }

  private func broadcast(_ event: WorkerBuildMonitorEvent, for key: WorkerBuildMonitorKey) {
    guard let monitor, monitor.key == key else { return }
    for continuation in monitor.observers.values {
      continuation.yield(event)
    }
  }

  private func hasActivity(for key: WorkerBuildMonitorKey) -> Bool {
    Activity<WorkerBuildAttributes>.activities.contains {
      $0.attributes.accountID == key.accountID && $0.attributes.scriptTag == key.scriptTag
    }
  }

  static func contentState(for build: WorkerBuild) -> WorkerBuildAttributes.ContentState {
    WorkerBuildAttributes.ContentState(
      phase: phaseLabel(build.phase),
      phaseToken: phaseToken(build.phase),
      branch: build.buildTriggerMetadata?.branch,
      shortCommit: build.buildTriggerMetadata?.shortCommit,
      outcome: build.buildOutcome)
  }

  /// Localized here, in the app, because the widget bundle cannot map a raw
  /// Cloudflare status onto a catalog key.
  static func phaseLabel(_ phase: WorkerBuild.Phase) -> String {
    switch phase {
    case .queued: DashL10n.string("Queued")
    case .initializing: DashL10n.string("Initializing")
    case .running: DashL10n.string("Building")
    case .finished: DashL10n.string("Finished")
    }
  }

  nonisolated static func phaseToken(_ phase: WorkerBuild.Phase) -> String {
    switch phase {
    case .queued: "queued"
    case .initializing: "initializing"
    case .running: "running"
    case .finished: "finished"
    }
  }

  private func startOrUpdate(
    build: WorkerBuild,
    key: WorkerBuildMonitorKey,
    serial: UInt64
  ) async -> Bool {
    if let activityCleanupTask {
      await activityCleanupTask.value
    }
    guard !Task.isCancelled, serial == invalidationSerial else { return false }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
    guard let buildID = build.buildUUID else { return false }

    let content = ActivityContent(
      state: WorkerBuildActivityControllerBox.contentState(for: build),
      staleDate: Date(timeIntervalSinceNow: BuildActivityPresentationRules.staleAfter))

    if let existing = Activity<WorkerBuildAttributes>.activities.first(where: {
      $0.attributes.accountID == key.accountID && $0.attributes.buildID == buildID
    }) {
      await existing.update(content)
      return !Task.isCancelled && serial == invalidationSerial
    }

    // One Worker build activity at a time; a new build supersedes the last.
    for activity in Activity<WorkerBuildAttributes>.activities {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
    guard !Task.isCancelled, serial == invalidationSerial else { return false }

    let attributes = WorkerBuildAttributes(
      accountID: key.accountID,
      scriptName: key.scriptName,
      scriptTag: key.scriptTag,
      buildID: buildID)
    // No push token: the relay only forwards Cloudflare notification policies,
    // and Workers builds do not publish through those.
    return (try? Activity.request(attributes: attributes, content: content, pushType: nil)) != nil
  }

  private func end(build: WorkerBuild?, key: WorkerBuildMonitorKey, serial: UInt64) async {
    if let activityCleanupTask {
      await activityCleanupTask.value
    }
    guard !Task.isCancelled, serial == invalidationSerial else { return }

    for activity in Activity<WorkerBuildAttributes>.activities
    where activity.attributes.scriptTag == key.scriptTag
      && (activity.attributes.accountID == key.accountID || activity.attributes.accountID == nil)
    {
      let content = build.map {
        ActivityContent(
          state: WorkerBuildActivityControllerBox.contentState(for: $0), staleDate: nil)
      }
      await activity.end(content, dismissalPolicy: .default)
    }
  }

  private func endActivity(for key: WorkerBuildMonitorKey, serial: UInt64) async {
    if let activityCleanupTask {
      await activityCleanupTask.value
    }
    guard !Task.isCancelled, serial == invalidationSerial else { return }

    for activity in Activity<WorkerBuildAttributes>.activities
    where activity.attributes.scriptTag == key.scriptTag
      && (activity.attributes.accountID == key.accountID || activity.attributes.accountID == nil)
    {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
  }
}
