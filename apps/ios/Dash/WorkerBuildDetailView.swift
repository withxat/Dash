import CloudflareAPI
import SwiftUI
import UIKit

/// Workers Builds answers under its own Cloudflare permission, **Workers CI**,
/// not the `workers-scripts.*` pair the rest of the Workers screens use.
///
/// Both ids are in `DashAuthorizationScopes.core` (`coreReadOperations` /
/// `coreWriteOperations`) rather than on the Workers capability: a Worker that
/// ships with `wrangler deploy` never touches this API, so a grant without them
/// must not turn the whole Workers feature Read-only or locked.
enum WorkerBuildsAccess {
  static let read: Set<String> = ["workers-ci.read"]
  static let write: Set<String> = ["workers-ci.write"]
}

extension StatusToken {
  /// One mapping for the history row's badge and the build screen's, so the
  /// two can never disagree about how a build ended.
  ///
  /// A finished build with no outcome is `.unknown`, not `.success`: Cloudflare
  /// did not say how it ended, and guessing green is the failure direction
  /// that matters.
  init(workerBuild build: WorkerBuild) {
    guard build.phase == .finished else {
      self = .inProgress
      return
    }
    switch build.outcome {
    case .success: self = .success
    case .failed: self = .failed
    case .canceled: self = .canceled
    case .skipped: self = .skipped
    case nil: self = .unknown
    }
  }
}

/// The commit subject when the build has one, otherwise its short id — the
/// same title on the history row and on the build's own screen.
@MainActor
func workerBuildTitle(_ build: WorkerBuild) -> String {
  build.buildTriggerMetadata?.commitMessage?
    .split(separator: "\n").first
    .map { String($0).trimmingCharacters(in: .whitespaces) }
    .flatMap { $0.isEmpty ? nil : $0 }
    ?? DashL10n.string("Build \(build.shortID)")
}

/// A build log reduced to what the screen draws: stable row ids, the time
/// already formatted, and the copyable text. Built once per fetch — the log is
/// re-read on every poll of a running build, and an unchanged one must compare
/// equal so the section does not re-lay-out under the reader.
private struct WorkerBuildLogPresentation: Equatable {
  struct Row: Identifiable, Equatable {
    let id: Int
    let time: String?
    let text: String
  }

  let rows: [Row]
  let truncated: Bool

  init(_ logs: WorkerBuildLogs) {
    rows = logs.lines.enumerated().map { index, line in
      Row(
        id: index,
        time: line.timestamp.map { DashDateFormatting.timeWithSeconds($0) },
        text: line.text)
    }
    truncated = logs.truncated
  }

  var plainText: String {
    rows.map { row in row.time.map { "\($0) \(row.text)" } ?? row.text }
      .joined(separator: "\n")
  }
}

/// One Workers Builds run: how it ended, where it spent its time, what it was
/// built from, and its log.
///
/// Reads the build by its UUID alone (`getWorkerBuild`), so it needs no script
/// tag — which is what lets a dashboard build link open here without first
/// loading the Workers list. While the build is in flight the screen re-reads
/// it on the shared `BuildMonitorRefreshDisposition` cadence and stops the
/// moment it settles; it starts no Live Activity, which stays the Worker
/// screen's monitor's job.
struct WorkerBuildDetailView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let workerName: String
  let buildID: String

  @State private var build: WorkerBuild?
  @State private var log: WorkerBuildLogPresentation?
  @State private var loading = true
  @State private var error: String?
  @State private var logError: String?
  @State private var actionError: String?
  @State private var cancelPhase: DashActionPhase = .idle
  @State private var confirmingCancel = false
  /// Bumped to restart the watch loop: a cold retry, or a manual refresh that
  /// found the build still running after the loop had given up.
  @State private var watchID = UUID()

  private struct WatchKey: Hashable {
    let context: AccountRequestContext?
    let buildID: String
    let watchID: UUID
  }

  private enum RefreshResult {
    /// The build is finished; nothing left to watch.
    case settled
    /// Still running — read it again after the normal interval.
    case live
    /// A transient failure while it was running — back off and try again.
    case retry
    /// Cancelled, superseded, or a failure another attempt will not fix.
    case stop
  }

  private var cacheKey: String? {
    model.accountRequestContext.map {
      FeatureCacheKey.workerBuild(accountID: $0.accountID, buildID: buildID)
    }
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: build != nil,
      retry: { restartWatch() }
    ) { mode in
      detailBody(mode: mode)
    }
    .detailHeader(
      icon: .solar(SolarAsset.Content.bolt),
      title: build.map(workerBuildTitle) ?? DashL10n.string("Build")
    )
    .refreshable { await refreshManually() }
    .task(id: WatchKey(context: model.accountRequestContext, buildID: buildID, watchID: watchID)) {
      await watch()
    }
  }

  /// First-paint reserve: Build + Timeline + Source. Build configuration, the
  /// Cancel pill, and the log are not reserved — a build may have none of the
  /// first two, and a section that is taken back is worse than one that
  /// arrives. The log is section-cold once the build lands.
  @ViewBuilder
  private func detailBody(mode: DashBodyMode) -> some View {
    if mode.isPlaceholder {
      DashInfoGroup(title: "Build", phase: .loading, placeholderRows: 5) { EmptyView() }
        .dashBodySlot(reduceMotion: reduceMotion)
      DashInfoGroup(title: "Timeline", phase: .loading, placeholderRows: 3) { EmptyView() }
        .dashSectionBoundary()
        .dashBodySlot(reduceMotion: reduceMotion)
      DashInfoGroup(title: "Source", phase: .loading, placeholderRows: 3) { EmptyView() }
        .dashSectionBoundary()
        .dashBodySlot(reduceMotion: reduceMotion)
    } else if let build {
      buildGroup(build)
        .dashBodySlot(reduceMotion: reduceMotion)
      timelineGroup(build)
      if let actionError {
        DashNotice(kind: .error, message: actionError)
          .dashItemBoundary()
      }
      cancelAction(build)
      sourceGroup(build)
      configurationGroup(build)
      logSection(build)
        .dashSectionBoundary()
        .dashBodySlot(reduceMotion: reduceMotion)
    }
  }

  // MARK: Sections

  /// The commit subject is the screen's `detailHeader` title, so it is not
  /// repeated here, and the status appears once — as the badge.
  private func buildGroup(_ build: WorkerBuild) -> some View {
    DashInfoGroup(title: "Build") {
      DashInfoRow("Status") { StatusBadge(StatusToken(workerBuild: build)) }
      if let source = build.buildTriggerMetadata?.source {
        DashInfoRow("Trigger", value: triggerLabel(source))
      }
      // The exact time, not "2h ago": the Worker's Builds list already carries
      // the relative one, and this is where "when did this run" lands.
      if let created = build.createdOn {
        DashInfoRow("Started", value: DashDateFormatting.dateAndTime(fromISO8601: created))
      }
      if let duration = build.duration.flatMap({ DashDateFormatting.durationText($0) }) {
        DashInfoRow("Duration", value: duration)
      }
      buildIDRow
    }
  }

  /// The id is what the API, Wrangler, and a support ticket all ask for, and a
  /// 36-character UUID is not something to retype — the row copies it.
  private var buildIDRow: some View {
    Button {
      copyBuildID()
    } label: {
      DashInfoRow("Build ID", value: buildID, mono: true)
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityLabel(DashL10n.string("Build ID, \(buildID)"))
    .accessibilityAction(named: DashL10n.string("Copy build ID")) { copyBuildID() }
  }

  /// Hidden when Cloudflare sent no timestamps at all — three hollow nodes
  /// would say "not started" about a build that may well have run.
  @ViewBuilder
  private func timelineGroup(_ build: WorkerBuild) -> some View {
    let steps = build.timeline
    if steps.contains(where: { $0.startedOn != nil }) {
      DashInfoGroup(title: "Timeline") {
        DashTimelineRows(steps: steps.map(timelineStep))
      }
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)
    }
  }

  private func timelineStep(_ step: WorkerBuild.Step) -> DashTimelineStep {
    let title: String
    let id: String
    switch step.kind {
    case .queued:
      id = "queued"
      title = WorkerBuildActivityControllerBox.phaseLabel(.queued)
    case .initializing:
      id = "initializing"
      title = WorkerBuildActivityControllerBox.phaseLabel(.initializing)
    case .building:
      id = "building"
      title = WorkerBuildActivityControllerBox.phaseLabel(.running)
    }

    let tone: DashTimelineStep.Tone
    let stateLabel: String
    switch step.state {
    case .done:
      tone = .done
      stateLabel = StatusToken.success.label
    case .active:
      tone = .active
      stateLabel = StatusToken.inProgress.label
    case .failed:
      tone = .failed
      stateLabel = StatusToken.failed.label
    case .stopped:
      tone = .stopped
      stateLabel = StatusToken.canceled.label
    case .ended:
      tone = .stopped
      stateLabel = StatusToken.unknown.label
    case .pending, .notReached:
      tone = .pending
      stateLabel = DashL10n.string("Not started")
    }

    return DashTimelineStep(
      id: id,
      title: title,
      caption: step.startedOn.map { DashDateFormatting.timeWithSeconds($0) },
      duration: step.duration.flatMap { DashDateFormatting.durationText($0) },
      runningSince: step.state == .active ? step.startedOn : nil,
      tone: tone,
      stateLabel: stateLabel)
  }

  /// Only while the build is in flight. Matches Pages deployment's Actions
  /// two-tone group and confirms before sending the irreversible cancel call.
  /// A grant without Workers CI write gets the reason and fix instead of a
  /// pill that would 403.
  @ViewBuilder
  private func cancelAction(_ build: WorkerBuild) -> some View {
    if build.isInProgress, let buildUUID = build.buildUUID {
      if featureAllowsWrites {
        DashTwoToneListGroup(title: "Actions") {
          VStack(spacing: 10) {
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
              .disabled(cancelPhase.isActive)
            }
          }
          .padding(.vertical, DashTheme.Spacing.comfortable)
        }
        .dashSectionBoundary()
        .dashBodySlot(reduceMotion: reduceMotion)
      } else {
        FeatureWriteAccessNotice(
          message: "Read-only — grant Workers Builds access to cancel a build.",
          scopes: WorkerBuildsAccess.write
        )
        .dashSectionBoundary()
        .dashBodySlot(reduceMotion: reduceMotion)
      }
    }
  }

  /// What was built. Hidden when Cloudflare sent none of it, rather than shown
  /// as a group of dashes.
  @ViewBuilder
  private func sourceGroup(_ build: WorkerBuild) -> some View {
    let metadata = build.buildTriggerMetadata
    let repository = metadata?.repository
    let branch = metadata?.branch.flatMap { $0.isEmpty ? nil : $0 }
    let commit = metadata?.shortCommit
    let author = metadata?.author.flatMap { $0.isEmpty ? nil : $0 }
    if repository != nil || branch != nil || commit != nil || author != nil {
      DashInfoGroup(title: "Source") {
        if let repository {
          DashInfoRow("Repository", value: repository)
        }
        if let branch {
          DashInfoRow("Branch", value: branch, mono: true)
        }
        if let commit {
          if let link = metadata?.commitURL {
            DashInfoRow("Commit") {
              Link(commit, destination: link)
                .dashTextStyle(.code)
                .foregroundStyle(DashTheme.brand)
            }
          } else {
            DashInfoRow("Commit", value: commit, mono: true)
          }
        }
        if let author {
          DashInfoRow("Author", value: author)
        }
      }
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)
    }
  }

  /// The commands this build ran — which can differ from the trigger's current
  /// ones, and is the first thing to check when a build that used to pass
  /// stops.
  @ViewBuilder
  private func configurationGroup(_ build: WorkerBuild) -> some View {
    let metadata = build.buildTriggerMetadata
    let buildCommand = metadata?.buildCommand.flatMap { $0.isEmpty ? nil : $0 }
    let deployCommand = metadata?.deployCommand.flatMap { $0.isEmpty ? nil : $0 }
    let rootDirectory = metadata?.rootDirectory.flatMap { $0.isEmpty ? nil : $0 }
    if buildCommand != nil || deployCommand != nil || rootDirectory != nil {
      DashInfoGroup(title: "Build configuration") {
        if let buildCommand {
          DashInfoRow("Build command", value: buildCommand, mono: true)
        }
        if let deployCommand {
          DashInfoRow("Deploy command", value: deployCommand, mono: true)
        }
        if let rootDirectory {
          DashInfoRow("Root directory", value: rootDirectory, mono: true)
        }
      }
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)
    }
  }

  /// The log sits in the same two-tone frame as the fields above it, with Copy
  /// on the header band — a failing build's log is what gets pasted into an
  /// issue, and selecting it line by line on a phone is not a way to do that.
  private func logSection(_ build: WorkerBuild) -> some View {
    let hasLines = log?.rows.isEmpty == false
    // One stack, so the call site's section boundary lands once — on the
    // group — and not again on each notice under it.
    return VStack(alignment: .leading, spacing: 0) {
      DashTwoToneListGroup(
        title: "Build log",
        actionTitle: hasLines ? "Copy" : nil,
        action: hasLines ? { copyLog() } : nil
      ) {
        if let log {
          // Both states carry the body-slot transition, as the Pages log's
          // do: the placeholder → log swap is an explicit handoff write.
          Group {
            if log.rows.isEmpty {
              Text(
                build.isInProgress
                  ? DashL10n.string("No log output yet.")
                  : DashL10n.string("This build produced no log output.")
              )
              .dashTextStyle(.supporting)
              .foregroundStyle(DashTheme.subtle)
              .frame(
                maxWidth: .infinity, minHeight: DashTheme.Layout.twoToneListRow, alignment: .leading
              )
            } else {
              DashFadedScrollView(
                surface: DashTheme.homeCardSurface,
                maxHeight: 360,
                bounceBasedOnSize: true
              ) {
                LazyVStack(alignment: .leading, spacing: 2) {
                  ForEach(log.rows) { row in
                    logLine(row)
                  }
                }
                .padding(.vertical, 12)
              }
            }
          }
          .dashBodySlot(reduceMotion: reduceMotion)
        } else {
          // The log's own shape holds the section while it loads, and a failure
          // veils over the same lines — the card never swaps to a bare notice.
          DashLogPlaceholder()
            .padding(.vertical, 14)
            .dashSectionFailure(logError, retry: retryLog)
            .dashBodySlot(reduceMotion: reduceMotion)
        }
      }
      if log != nil, let logError {
        // Warm: a re-read failed mid-build — keep the visible log and say so
        // beside it instead of tearing it down.
        DashNotice(kind: .warning, message: logError)
          .dashItemBoundary()
      }
      if log?.truncated == true {
        Text(
          DashL10n.string(
            "This log is longer than Dash loads. The rest is in the Cloudflare dashboard.")
        )
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
        .padding(.horizontal, DashTheme.Spacing.rowInset)
        .dashItemBoundary()
      }
    }
  }

  /// One attributed run per line, so the dimmed time and the text wrap as a
  /// single paragraph instead of as two columns.
  private func logLine(_ row: WorkerBuildLogPresentation.Row) -> some View {
    var line = AttributedString(row.text.isEmpty ? " " : row.text)
    line.swiftUI.foregroundColor = DashTheme.text
    if let time = row.time {
      var stamp = AttributedString("\(time) ")
      stamp.swiftUI.foregroundColor = DashTheme.faint
      line = stamp + line
    }
    return Text(line)
      .dashTextStyle(.code)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func triggerLabel(_ source: WorkerBuildTriggerMetadata.Source) -> String {
    switch source {
    case .push: DashL10n.string("Git push")
    case .pullRequest: DashL10n.string("Pull request")
    case .manual: DashL10n.string("Manual")
    case .api: DashL10n.string("API")
    // A source Cloudflare added after this build: show its own word rather
    // than hide the row.
    case .other(let raw): DashL10n.ui(raw.replacingOccurrences(of: "_", with: " ").capitalized)
    }
  }

  // MARK: Loading

  /// Reads the build, then keeps reading while it is in flight. Ends as soon as
  /// the build settles, so a finished build costs one request and its log.
  private func watch() async {
    guard let context = model.accountRequestContext else {
      loading = false
      return
    }
    if build == nil, let cacheKey,
      let cached: WorkerBuild = model.featureCache.getStale(cacheKey)
    {
      build = cached
    }
    if build == nil { loading = true }

    var failures = 0
    while !Task.isCancelled {
      switch await refresh(context: context) {
      case .settled, .stop:
        return
      case .live:
        failures = 0
      case .retry:
        failures += 1
      }
      let delay = BuildMonitorRefreshDisposition.retryDelaySeconds(consecutiveFailures: failures)
      do {
        try await Task.sleep(for: .seconds(Double(delay)))
      } catch {
        return
      }
    }
  }

  private func refresh(context: AccountRequestContext) async -> RefreshResult {
    do {
      let fetched = try await model.client.getWorkerBuild(
        accountID: context.accountID, buildUUID: buildID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return .stop }
      let wasInProgress = build?.isInProgress == true
      build = fetched
      loading = false
      error = nil
      if let cacheKey { model.featureCache.set(cacheKey, fetched) }
      // First paint, every read of a running build, and once more as it
      // finishes — the last lines are the ones that say why it failed.
      if log == nil || fetched.isInProgress || wasInProgress {
        await loadLog(context: context)
      }
      return fetched.isInProgress ? .live : .settled
    } catch {
      guard model.isCurrentAccount(context) else { return .stop }
      switch BuildMonitorRefreshDisposition.classify(error) {
      case .cancel:
        return .stop
      case .retry:
        loading = false
        self.error = error.dashActionableMessage
        // Only a build known to be running is worth re-reading unprompted; a
        // cold failure waits for Try again.
        return build?.isInProgress == true ? .retry : .stop
      case .stop:
        loading = false
        self.error = error.dashActionableMessage
        return .stop
      }
    }
  }

  private func loadLog(context: AccountRequestContext) async {
    do {
      let fetched = try await model.client.getWorkerBuildLog(
        accountID: context.accountID, buildUUID: buildID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      present(WorkerBuildLogPresentation(fetched))
    } catch {
      guard !Task.isCancelled, !error.dashIsCancellation, model.isCurrentAccount(context)
      else { return }
      logError = error.dashActionableMessage
    }
  }

  private func present(_ fetched: WorkerBuildLogPresentation) {
    guard fetched != log || logError != nil else { return }
    if reduceMotion {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        log = fetched
        logError = nil
      }
    } else {
      withAnimation(DashBodyTransition.handoff) {
        log = fetched
        logError = nil
      }
    }
  }

  private func retryLog() {
    guard let context = model.accountRequestContext else { return }
    withAnimation(DashTheme.Motion.content) { logError = nil }
    Task { await loadLog(context: context) }
  }

  private func restartWatch() {
    loading = build == nil
    error = nil
    watchID = UUID()
  }

  private func refreshManually() async {
    guard let context = model.accountRequestContext else { return }
    let result = await refresh(context: context)
    // The watch loop ends on a settled build or a hard failure. If this read
    // found the build running, make sure something is still watching it.
    if result == .live { watchID = UUID() }
  }

  // MARK: Actions

  private func copyBuildID() {
    UIPasteboard.general.string = buildID
    model.toasts.success(DashL10n.string("Build ID copied"))
  }

  private func copyLog() {
    guard let log, !log.rows.isEmpty else { return }
    UIPasteboard.general.string = log.plainText
    model.toasts.success(DashL10n.string("Build log copied"))
  }

  private func cancel(buildUUID: String) async {
    guard let context = model.accountRequestContext else { return }
    cancelPhase = .loading
    actionError = nil
    do {
      try await model.client.cancelWorkerBuild(
        accountID: context.accountID, buildUUID: buildUUID)
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
    cancelPhase = .idle
    confirmingCancel = false
    // Cloudflare's cancel response shape is undocumented, so the new state
    // comes from a re-read rather than from anything the call returned.
    restartWatch()
  }
}
