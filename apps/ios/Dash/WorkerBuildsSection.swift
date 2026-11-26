import CloudflareAPI
import SwiftUI

/// Workers Builds history on the Worker detail screen, and the driver for the
/// build Live Activity.
///
/// Three answers, same contract as Tunnel private routes:
///
///   * Empty builds, a Builds 403/404, or no script tag → hide the
///     section. Most Workers ship via `wrangler deploy` and are not
///     repo-connected, so an empty "No builds yet" card would be permanent
///     furniture; an account without the feature must not make the rest of
///     the screen look broken either.
///   * The one 403 that is *not* an answer: the grant has no Workers CI read
///     (`WorkerBuildsAccess`). Cloudflare refused to say whether this Worker
///     has builds, so hiding would be reporting "none" on no evidence — the
///     section says what is missing and offers Grant access instead. Grants
///     issued before Dash requested the scope are all in this state.
///   * Any other cold failure (5xx, timeout, decode, offline) → keep the
///     Builds group mounted and veil Try again over placeholders.
///   * Warm reload failures with history already on screen → inline
///     `actionError` notice; content never vanishes over a polling error.
struct WorkerBuildsSection: View {
  static let pageSize = 10

  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  let scriptName: String
  /// Bumped by the Worker screen's pull-to-refresh. The section owns its own
  /// task, so without this the parent's refresh would reload every other
  /// section and silently skip this one.
  var refreshID: UUID
  /// Whether a section boundary opens the group once it has something to show.
  /// The section spaces itself: its host below is always mounted, so a
  /// caller's boundary would pad a Worker that has no builds at all.
  var leadsWithBoundary = true

  @State private var scriptTag: String?
  @State private var builds: [WorkerBuild] = []
  @State private var latest: WorkerBuild?
  @State private var pageState = DashPageState()
  @State private var isLoadingMore = false
  @State private var historyGeneration = 0
  @State private var unavailable = false
  /// A 403 under a grant known to lack Workers CI read. Never set from a 404,
  /// and never while the grant is unknown.
  @State private var needsAccess = false
  @State private var loaded = false
  @State private var loadError: String?
  @State private var cancelPhase: DashActionPhase = .idle
  @State private var confirmingCancel = false
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
    // Always one view, empty or not. The load below needs a host that exists
    // *before* there is anything to show: on a `Group` whose branches all start
    // false there is no view for `.task` to attach to, so the history was never
    // requested and the section could never leave its empty state.
    VStack(alignment: .leading, spacing: 0) {
      if !unavailable, loaded, !builds.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          // Bounded per request (`pageSize`), with explicit Load more below so
          // scrolling past Builds toward Deployments does not auto-fetch pages.
          DashTwoToneListGroup(title: "Builds") {
            if let latest, latest.isInProgress {
              inProgressBlock(latest)
            }
            dashListCardRows(items: builds, inset: false) { build in
              // A build Cloudflare sent without a UUID has no screen to open —
              // the row stays, as plain text.
              if let buildUUID = build.buildUUID {
                DashListGroupLink(value: .workerBuild(worker: scriptName, buildID: buildUUID)) {
                  historyRow(build, showsChevron: true)
                }
              } else {
                historyRow(build, showsChevron: false)
              }
            }
          }
          if pageState.canLoadMore || isLoadingMore {
            Group {
              if isLoadingMore {
                DashLoadingRing(color: DashTheme.brand, size: 16, lineWidth: 2.5)
                  .accessibilityLabel("Loading")
              } else {
                DashSecondaryPillButton(title: DashL10n.string("Load more")) {
                  Task { await loadMore() }
                }
                .accessibilityIdentifier("worker-builds-load-more")
              }
            }
            .frame(maxWidth: .infinity)
            .dashItemBoundary()
          }
          if let actionError {
            DashNotice(kind: .warning, message: actionError)
              .dashItemBoundary()
          }
        }
        .dashSectionBoundary(leadsWithBoundary)
      } else if !unavailable, loaded, loadError != nil {
        DashTwoToneListGroup(title: "Builds") {
          DashSectionListRowPlaceholders(rows: 3)
            .dashSectionFailure(
              loadError,
              retry: { Task { await resolveTagAndLoad() } })
        }
        .dashSectionBoundary(leadsWithBoundary)
      } else if loaded, needsAccess {
        DashTwoToneListGroup(title: "Builds") {
          FeatureWriteAccessNotice(
            message: "Dash needs Workers Builds access to show this Worker’s builds.",
            scopes: WorkerBuildsAccess.read.union(WorkerBuildsAccess.write)
          )
          .padding(.vertical, DashTheme.Spacing.comfortable)
        }
        .dashSectionBoundary(leadsWithBoundary)
      }
    }
    .task(
      id: LoadKey(
        context: model.accountRequestContext,
        refreshID: refreshID,
        hasBuildsAccess: model.hasScopes(WorkerBuildsAccess.read))
    ) {
      await resolveTagAndLoad()
    }
    .task(id: monitorKey) { await monitor() }
  }

  /// Re-runs the history load on an account switch, a pull-to-refresh, *or*
  /// the grant gaining Workers CI read — the moment Grant access succeeds is
  /// the moment the section it was offered from should fill in.
  private struct LoadKey: Hashable {
    let context: AccountRequestContext?
    let refreshID: UUID
    let hasBuildsAccess: Bool
  }

  /// The build in flight, as the group's first block: phase, what triggered
  /// it, and Cancel. Its history row follows like any other build's.
  private func inProgressBlock(_ build: WorkerBuild) -> some View {
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
      // Cancel is a Workers CI write; the Worker screen's own write scope
      // (`workers-scripts.write`) neither grants it nor implies it.
      if featureAllowsWrites, model.hasScopes(WorkerBuildsAccess.write),
        let buildUUID = build.buildUUID
      {
        if confirmingCancel {
          Text(DashL10n.string("Stops this build immediately. It cannot be resumed."))
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        DashActionButton(
          title: confirmingCancel ? "Stop build" : "Cancel build",
          role: .destructive,
          phase: cancelPhase,
          onSuccessPresentationCompleted: completeCancelPresentation
        ) {
          if confirmingCancel {
            Task { await cancel(buildUUID: buildUUID) }
          } else {
            withAnimation(DashTheme.Motion.morph) { confirmingCancel = true }
          }
        }
        if confirmingCancel {
          Button(DashL10n.string("Keep running")) {
            withAnimation(DashTheme.Motion.morph) { confirmingCancel = false }
          }
          .dashTextStyle(.buttonMedium)
          .foregroundStyle(DashTheme.subtle)
          .frame(maxWidth: .infinity)
          .disabled(cancelPhase.isActive)
        }
      }
    }
    .padding(.vertical, DashTheme.Spacing.comfortable)
  }

  private func historyRow(_ build: WorkerBuild, showsChevron: Bool) -> some View {
    DashListRow(
      title: workerBuildTitle(build),
      subtitle: triggerSubtitle(build),
      icon: SolarAsset.Content.bolt,
      showsChevron: showsChevron
    ) {
      StatusBadge(StatusToken(workerBuild: build))
    }
  }

  private func triggerSubtitle(_ build: WorkerBuild) -> String? {
    var parts: [String] = []
    if let branch = build.buildTriggerMetadata?.branch { parts.append(branch) }
    if let commit = build.buildTriggerMetadata?.shortCommit { parts.append(commit) }
    if let created = build.createdOn.flatMap(DashDateFormatting.date(fromISO8601:)) {
      parts.append(DashDateFormatting.fullRelativeTime(created))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// The Builds API keys on the script's immutable tag, which the detail
  /// screen's route (a name) does not carry. The workers list already decodes
  /// it, so this reads the cache first and only fetches when it has to.
  private func resolveTagAndLoad() async {
    // Demo runs the same path: `DemoBackend` serves a finished build history
    // for its one repo-connected Worker and an empty one for the rest, so no
    // demo build is ever in flight and the monitor below never starts.
    guard let context = model.accountRequestContext else {
      loaded = true
      unavailable = true
      needsAccess = false
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
      needsAccess = false
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
    historyGeneration += 1
    let generation = historyGeneration
    isLoadingMore = false
    pageState.reset()
    do {
      let page = try await model.client.listWorkerBuilds(
        accountID: context.accountID, scriptTag: tag, page: 1, perPage: Self.pageSize)
      guard !Task.isCancelled, generation == historyGeneration, model.isCurrentAccount(context)
      else { return }
      builds = page.items
      latest = page.items.first
      pageState.absorb(
        info: page.resultInfo,
        requestedPage: 1,
        received: page.items.count,
        added: page.items.count,
        loaded: builds.count,
        pageSize: Self.pageSize)
      loadError = nil
      needsAccess = false
      unavailable = page.items.isEmpty
    } catch {
      guard !error.dashIsCancellation, generation == historyGeneration,
        model.isCurrentAccount(context)
      else { return }
      if error.dashIsResourceAbsent {
        if builds.isEmpty {
          // An account without Workers Builds answers 403/404 here. Staying
          // silent is the whole point — the Worker's own screen is unaffected.
          unavailable = true
          loadError = nil
          // Unless the 403 is Dash's own doing: the request went out without
          // the scope the endpoint answers under. Decided from the grant, and
          // only when the grant is known — an unknown grant stays silent.
          needsAccess =
            (error as? CloudflareAPIError)?.isForbidden == true
            && model.grantedScopes != nil
            && !model.hasScopes(WorkerBuildsAccess.read)
        } else {
          actionError = error.dashActionableMessage
        }
      } else if builds.isEmpty {
        // Cold transport/server failure: keep the section and offer retry.
        // Vanishing here used to swallow 5xx/timeout as "no Builds feature".
        unavailable = false
        needsAccess = false
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

  private func loadMore() async {
    guard
      let context = model.accountRequestContext,
      let tag = scriptTag,
      !isLoadingMore,
      pageState.canLoadMore
    else { return }
    let generation = historyGeneration
    let pageNumber = pageState.nextPage
    isLoadingMore = true
    defer {
      if generation == historyGeneration, model.isCurrentAccount(context) {
        isLoadingMore = false
      }
    }
    do {
      let page = try await model.client.listWorkerBuilds(
        accountID: context.accountID,
        scriptTag: tag,
        page: pageNumber,
        perPage: Self.pageSize)
      guard !Task.isCancelled, generation == historyGeneration, model.isCurrentAccount(context)
      else { return }
      var seenIDs = Set(builds.map(\.id))
      let unique = page.items.filter { seenIDs.insert($0.id).inserted }
      builds += unique
      pageState.absorb(
        info: page.resultInfo,
        requestedPage: pageNumber,
        received: page.items.count,
        added: unique.count,
        loaded: builds.count,
        pageSize: Self.pageSize)
      actionError = nil
    } catch {
      guard !error.dashIsCancellation, generation == historyGeneration,
        model.isCurrentAccount(context)
      else { return }
      actionError = error.dashActionableMessage
    }
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
    confirmingCancel = false
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
