import CloudflareAPI
import SwiftUI

/// Workers Builds history on the Worker detail screen, and the driver for the
/// build Live Activity.
///
/// Three answers, same contract as Tunnel private routes:
///
///   * Empty builds, a Builds 403/404, no script tag, or Demo → hide the
///     section. Most Workers ship via `wrangler deploy` and are not
///     repo-connected, so an empty "No builds yet" card would be permanent
///     furniture; an account without the feature must not make the rest of
///     the screen look broken either.
///   * Any other cold failure (5xx, timeout, decode, offline) → keep the
///     Builds group mounted and veil Try again over placeholders.
///   * Warm reload failures with history already on screen → inline
///     `actionError` notice; content never vanishes over a polling error.
struct WorkerBuildsSection: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  let scriptName: String
  /// Bumped by the Worker screen's pull-to-refresh. The section owns its own
  /// task, so without this the parent's refresh would reload every other
  /// section and silently skip this one.
  var refreshID: UUID

  @State private var scriptTag: String?
  @State private var builds: [WorkerBuild] = []
  @State private var latest: WorkerBuild?
  @State private var unavailable = false
  @State private var loaded = false
  @State private var loadError: String?
  @State private var cancelPhase: DashActionPhase = .idle
  @State private var actionError: String?

  private var monitorKey: WorkerBuildMonitorKey? {
    guard let scriptTag, let context = model.accountRequestContext else { return nil }
    return WorkerBuildMonitorKey(
      accountID: context.accountID,
      accountGeneration: context.generation,
      scriptName: scriptName,
      scriptTag: scriptTag)
  }

  var body: some View {
    Group {
      if !unavailable, loaded, !builds.isEmpty {
        DashListGroup(title: "Builds") {
          DashSurfaceStack {
            if let latest, latest.isInProgress {
              inProgressCard(latest)
            }
            historyCard
          }
          if let actionError {
            DashNotice(kind: .warning, message: actionError)
              .dashItemBoundary()
          }
        }
      } else if !unavailable, loaded, loadError != nil {
        DashListGroup(title: "Builds") {
          DashCard {
            DashListRowPlaceholders(rows: 3)
              .dashSectionFailure(
                loadError,
                retry: { Task { await resolveTagAndLoad() } })
          }
        }
      }
    }
    .task(id: LoadKey(context: model.accountRequestContext, refreshID: refreshID)) {
      await resolveTagAndLoad()
    }
    .task(id: monitorKey) { await monitor() }
  }

  /// Re-runs the history load on an account switch *or* a pull-to-refresh.
  private struct LoadKey: Hashable {
    let context: AccountRequestContext?
    let refreshID: UUID
  }

  @ViewBuilder private func inProgressCard(_ build: WorkerBuild) -> some View {
    DashCard {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          DashLoadingRing(color: DashTheme.brand, size: 18, lineWidth: 2.5)
          Text(WorkerBuildActivityControllerBox.phaseLabel(build.phase))
            .dashTextStyle(.bodyMedium)
            .foregroundStyle(DashTheme.text)
          Spacer(minLength: 0)
        }
        if let subtitle = triggerSubtitle(build) {
          Text(subtitle)
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
            .lineLimit(1)
        }
        if featureAllowsWrites, let buildUUID = build.buildUUID {
          DashActionButton(
            title: "Cancel build",
            role: .destructive,
            phase: cancelPhase,
            onSuccessPresentationCompleted: completeCancelPresentation
          ) {
            Task { await cancel(buildUUID: buildUUID) }
          }
        }
      }
    }
  }

  @ViewBuilder private var historyCard: some View {
    dashListCard {
      dashListCardRows(items: builds) { build in
        DashListRow(
          title: buildTitle(build),
          subtitle: triggerSubtitle(build),
          icon: SolarAsset.Content.bolt,
          showsChevron: false
        ) {
          StatusBadge(statusToken(build))
        }
      }
    }
  }

  private func buildTitle(_ build: WorkerBuild) -> String {
    build.buildTriggerMetadata?.commitMessage?.split(separator: "\n").first.map(String.init)
      ?? DashL10n.string("Build \(build.shortID)")
  }

  private func triggerSubtitle(_ build: WorkerBuild) -> String? {
    var parts: [String] = []
    if let branch = build.buildTriggerMetadata?.branch { parts.append(branch) }
    if let commit = build.buildTriggerMetadata?.shortCommit { parts.append(commit) }
    if let created = build.createdOn.flatMap(DashDateFormatting.date(fromISO8601:)) {
      parts.append(watchtowerRelativeTime(created))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// Mapped through `StatusToken`, never a raw Cloudflare string — shape, tone,
  /// and localized label all come from the token's own exhaustive switches.
  ///
  /// A finished build with no `build_outcome` is `.unknown`, not `.success`:
  /// Cloudflare did not say how it ended, and guessing green is the failure
  /// direction that matters.
  private func statusToken(_ build: WorkerBuild) -> StatusToken {
    guard build.phase == .finished else { return .inProgress }
    switch build.buildOutcome?.lowercased() {
    case "success": return .success
    case "canceled", "cancelled": return .canceled
    case "skipped": return .skipped
    case .some: return .failed
    case nil: return .unknown
    }
  }

  /// The Builds API keys on the script's immutable tag, which the detail
  /// screen's route (a name) does not carry. The workers list already decodes
  /// it, so this reads the cache first and only fetches when it has to.
  private func resolveTagAndLoad() async {
    guard let context = model.accountRequestContext, !model.isDemoSession else {
      loaded = true
      unavailable = true
      loadError = nil
      return
    }
    let accountID = context.accountID
    var tag: String? =
      (model.featureCache.get(FeatureCacheKey.workers(accountID))
      as [WorkerScript]?)?
      .first { $0.name == scriptName }?
      .tag

    if tag == nil {
      let fetched = try? await model.client.listWorkers(accountID: accountID)
      guard model.isCurrentAccount(context) else { return }
      tag = fetched?.first { $0.name == scriptName }?.tag
    }

    guard model.isCurrentAccount(context) else { return }
    guard let tag, !tag.isEmpty else {
      // No tag means no Workers Builds for this Worker. Not an error.
      unavailable = true
      loadError = nil
      loaded = true
      return
    }
    await loadHistory(context: context, tag: tag)
    guard model.isCurrentAccount(context) else { return }
    // Published last, on purpose: it is what makes `monitorKey` non-nil and
    // starts the monitor, and the monitor decides whether to poll by looking at
    // the build history that just landed.
    scriptTag = tag
  }

  private func loadHistory(context: AccountRequestContext, tag: String) async {
    do {
      let page = try await model.client.listWorkerBuilds(
        accountID: context.accountID, scriptTag: tag, perPage: 10)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      builds = page.items
      latest = page.items.first
      loadError = nil
      unavailable = page.items.isEmpty
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      if error.dashIsResourceAbsent {
        if builds.isEmpty {
          // An account without Workers Builds answers 403/404 here. Staying
          // silent is the whole point — the Worker's own screen is unaffected.
          unavailable = true
          loadError = nil
        } else {
          actionError = error.dashActionableMessage
        }
      } else if builds.isEmpty {
        // Cold transport/server failure: keep the section and offer retry.
        // Vanishing here used to swallow 5xx/timeout as "no Builds feature".
        unavailable = false
        loadError = error.dashActionableMessage
      } else {
        // Warm re-load (a watched build finished, or pull-to-refresh): the
        // history the user is looking at stays mounted, the failure rides the
        // section's inline notice. Content on screen never vanishes over a
        // polling error.
        actionError = error.dashActionableMessage
      }
    }
    loaded = true
  }

  /// Subscribes to the shared monitor so the Live Activity and this card move
  /// together instead of polling the same endpoint twice.
  ///
  /// Only runs when the newest build is actually in flight. History alone needs
  /// no monitor, and starting one anyway would spend a `builds/latest` request
  /// re-reading what `loadHistory` just returned — on every Worker screen, for
  /// a build that finished days ago. A build started *after* this screen opened
  /// is picked up by pull-to-refresh (`refreshID`), which reloads history and
  /// re-keys this task.
  private func monitor() async {
    guard let key = monitorKey, latest?.isInProgress == true else { return }
    let client = model.client
    let stream = WorkerBuildActivityController.shared.updates(for: key, client: client)
    let initial = Task {
      await WorkerBuildActivityController.shared.refresh(key: key, client: client)
    }
    defer { initial.cancel() }

    for await event in stream {
      guard !Task.isCancelled, monitorKey == key else { return }
      switch event {
      case .build(let build):
        let wasInProgress = latest?.isInProgress == true
        latest = build
        // A build that just finished changes its own history row too.
        if wasInProgress, build?.isInProgress != true {
          await loadHistory(
            context: AccountRequestContext(
              accountID: key.accountID, generation: key.accountGeneration),
            tag: key.scriptTag)
        } else if let build, builds.first?.buildUUID != build.buildUUID {
          builds.insert(build, at: 0)
          unavailable = false
          loaded = true
        }
      case .failure(let message, let terminal):
        // The monitor only runs with the section mounted and a build card on
        // screen (`latest.isInProgress` guard above), so this is always warm:
        // keep the rendered history and say why polling stopped. `unavailable`
        // is reserved for the initial no-tag / 403 / empty answers — flipping
        // it here unmounted the exact rows the user was watching.
        if terminal { actionError = message }
      }
    }
  }

  private func cancel(buildUUID: String) async {
    guard let key = monitorKey else { return }
    let context = AccountRequestContext(
      accountID: key.accountID, generation: key.accountGeneration)
    cancelPhase = .loading
    actionError = nil
    do {
      try await model.client.cancelWorkerBuild(
        accountID: key.accountID, buildUUID: buildUUID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        cancelPhase = .idle
        return
      }
      model.toasts.success(DashL10n.string("Build cancelled"))
      cancelPhase = .succeeded
    } catch {
      cancelPhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      actionError = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func completeCancelPresentation() {
    guard cancelPhase == .succeeded, let key = monitorKey else {
      cancelPhase = .idle
      return
    }
    cancelPhase = .idle
    // Cloudflare's cancel response shape is undocumented, so the new state
    // comes from a re-read rather than from anything this call returned.
    Task {
      await WorkerBuildActivityController.shared.refresh(key: key, client: model.client)
    }
  }
}
