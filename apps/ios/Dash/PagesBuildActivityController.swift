@preconcurrency import ActivityKit
import BackgroundTasks
import CloudflareAPI
import Foundation

/// Starts, updates, and ends a poll-driven Pages build Live Activity.
///
/// Foreground 10s polling is the source of truth while the app is active.
/// BGAppRefresh (`backgroundRefreshID`) is a best-effort continuation when
/// suspended — iOS may delay or skip wakes; do not rely on it alone.
@MainActor
enum PagesBuildActivityController {
  static let shared = PagesBuildActivityControllerBox()
  static let backgroundRefreshID = "sh.xat.dash.app.pages-build-refresh"
}

@MainActor
final class PagesBuildActivityControllerBox {
  private var pollTask: Task<Void, Never>?
  private var pushTokenTask: Task<Void, Never>?

  func sync(
    projectName: String,
    deployment: PagesDeployment?,
    client: CloudflareClient,
    accountID: String?
  ) async {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    guard let deployment, let accountID else { return }

    if deployment.isInProgress {
      await startOrUpdate(projectName: projectName, deployment: deployment)
      startPolling(
        projectName: projectName, deploymentID: deployment.id, client: client,
        accountID: accountID)
      scheduleBackgroundRefresh()
    } else {
      stopPolling()
      cancelBackgroundRefresh()
      await end(projectName: projectName, deployment: deployment)
    }
  }

  /// BGAppRefresh entry from `DashApp`. Fetches the active LA deployment and
  /// applies update/end; reschedules only while a build is still in progress.
  func performBackgroundRefresh(client: CloudflareClient, accountID: String?) async {
    guard let accountID else {
      cancelBackgroundRefresh()
      return
    }
    guard let activity = Activity<PagesBuildAttributes>.activities.first else {
      cancelBackgroundRefresh()
      return
    }

    let stillInProgress = await refreshDeployment(
      projectName: activity.attributes.projectName,
      deploymentID: activity.attributes.deploymentID,
      client: client,
      accountID: accountID)
    if stillInProgress {
      scheduleBackgroundRefresh()
    } else {
      stopPolling()
      cancelBackgroundRefresh()
    }
  }

  /// Asks iOS to wake the app to refresh an in-progress Pages LA.
  /// Opportunistic — delivery is not guaranteed; foreground poll remains authoritative.
  func scheduleBackgroundRefresh() {
    let request = BGAppRefreshTaskRequest(
      identifier: PagesBuildActivityController.backgroundRefreshID)
    // Builds often finish in minutes; keep the earliest window short so a
    // granted wake can land before the LA goes stale. Still best-effort.
    request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
    try? BGTaskScheduler.shared.submit(request)
  }

  func cancelBackgroundRefresh() {
    BGTaskScheduler.shared.cancel(
      taskRequestWithIdentifier: PagesBuildActivityController.backgroundRefreshID)
  }

  private func startOrUpdate(projectName: String, deployment: PagesDeployment) async {
    let state = PagesBuildAttributes.ContentState(
      stage: deployment.latestStage?.name ?? "build",
      status: deployment.latestStage?.status ?? "active",
      shortID: deployment.shortID ?? String(deployment.id.prefix(8)))
    let attributes = PagesBuildAttributes(
      projectName: projectName, deploymentID: deployment.id)

    if let existing = Activity<PagesBuildAttributes>.activities.first(where: {
      $0.attributes.deploymentID == deployment.id
    }) {
      await existing.update(ActivityContent(state: state, staleDate: nil))
      return
    }

    for activity in Activity<PagesBuildAttributes>.activities {
      await activity.end(nil, dismissalPolicy: .immediate)
    }

    // Optional future: a relay Live Activity push could land via this token.
    // v1 continuation is BGAppRefresh + the reliable 10s foreground poll
    // (zero-storage relay — no LA push from the edge).
    let activity = try? Activity.request(
      attributes: attributes,
      content: ActivityContent(state: state, staleDate: nil),
      pushType: .token)
    if let activity {
      observePushToken(activity)
    }
  }

  private func observePushToken(_ activity: Activity<PagesBuildAttributes>) {
    pushTokenTask?.cancel()
    pushTokenTask = Task {
      for await tokenData in activity.pushTokenUpdates {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(
          hex, forKey: "dash.pages.live_activity_push_token.\(activity.attributes.deploymentID)")
      }
    }
  }

  private func end(projectName: String, deployment: PagesDeployment) async {
    let state = PagesBuildAttributes.ContentState(
      stage: deployment.latestStage?.name ?? "deploy",
      status: deployment.latestStage?.status ?? deployment.statusLabel.lowercased(),
      shortID: deployment.shortID ?? String(deployment.id.prefix(8)))
    for activity in Activity<PagesBuildAttributes>.activities
    where activity.attributes.deploymentID == deployment.id
      || activity.attributes.projectName == projectName
    {
      await activity.end(
        ActivityContent(state: state, staleDate: nil),
        dismissalPolicy: .default)
    }
  }

  /// Shared fetch → apply path for the 10s poll and BGAppRefresh.
  /// Returns `true` when the build is still in progress (or the fetch failed
  /// and we should keep retrying); `false` after a terminal end.
  private func refreshDeployment(
    projectName: String,
    deploymentID: String,
    client: CloudflareClient,
    accountID: String
  ) async -> Bool {
    do {
      let latest = try await client.getPagesDeployment(
        accountID: accountID, projectName: projectName, deploymentID: deploymentID)
      if latest.isInProgress {
        await startOrUpdate(projectName: projectName, deployment: latest)
        return true
      }
      await end(projectName: projectName, deployment: latest)
      return false
    } catch {
      // Keep the activity up; the next tick / wake retries.
      return true
    }
  }

  private func startPolling(
    projectName: String, deploymentID: String, client: CloudflareClient, accountID: String
  ) {
    pollTask?.cancel()
    pollTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(10))
        guard !Task.isCancelled else { return }
        let stillInProgress = await refreshDeployment(
          projectName: projectName, deploymentID: deploymentID, client: client,
          accountID: accountID)
        if !stillInProgress {
          cancelBackgroundRefresh()
          return
        }
      }
    }
  }

  private func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
    pushTokenTask?.cancel()
    pushTokenTask = nil
  }
}
