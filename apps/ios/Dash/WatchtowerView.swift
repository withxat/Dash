import CloudflareAPI
import Observation
import SwiftUI

/// Shared Watchtower screen state for the phone stack.
@MainActor
@Observable
final class WatchtowerScreenState {
  var signals: [WatchtowerSignal] = []
  var alerts: [NotificationHistoryEntry] = []
  var alertsStatus: WatchtowerAlertsStatus = .loading
  var missingScopeChecks: [String] = []
  var failedChecks: [String] = []
  var fetchedAt: Date?
  var loading = true
  var mutedSignalIDs: Set<String> = []

  var summary: WatchtowerSummary {
    let scored = operationalSignals.filter {
      $0.status == .ok || !mutedSignalIDs.contains($0.id)
    }
    return WatchtowerSummary(
      critical: scored.filter { $0.status == .critical }.count,
      warning: scored.filter { $0.status == .warning }.count,
      ok: scored.filter { $0.status == .ok }.count
    )
  }

  var issues: [WatchtowerSignal] {
    operationalSignals.filter { $0.status != .ok && !mutedSignalIDs.contains($0.id) }
  }
  var mutedIssues: [WatchtowerSignal] {
    operationalSignals.filter { $0.status != .ok && mutedSignalIDs.contains($0.id) }
  }
  var healthy: [WatchtowerSignal] { operationalSignals.filter { $0.status == .ok } }
  var coverageLimits: [WatchtowerSignal] {
    signals.filter { $0.id == WatchtowerEngine.coverageSignalID }
  }
  private var operationalSignals: [WatchtowerSignal] {
    signals.filter { $0.id != WatchtowerEngine.coverageSignalID }
  }
  var issueCount: Int { summary.critical + summary.warning }
  var recheckBanner: String?
  var capabilityNotes: [String] = []

  func refreshMutedSignals() {
    mutedSignalIDs = WatchtowerMuteStore.mutedIDs()
  }

  func load(model: AppModel, force: Bool = false) async {
    refreshMutedSignals()
    guard let accountID = model.activeAccountID else {
      loading = false
      signals = []
      alerts = []
      return
    }
    let cached: WatchtowerSnapshot? = model.featureCache.get(
      FeatureCacheKey.watchtower(accountID))
    // Warm tab re-entry: paint from the session snapshot without an
    // Updating… strip or network fan-out. Pull-to-refresh still forces.
    if !force, let cached, !cached.isStale(ttl: AppModel.watchtowerTTL) {
      apply(cached)
      loading = false
      return
    }
    let previousIssueIDs = Set(
      signals.filter {
        $0.status != .ok && $0.id != WatchtowerEngine.coverageSignalID
      }.map(\.id))
    // Cold skeleton when empty; Warm Updating… when we already have rows.
    loading = true
    // Snapshot cache uses ttl:nil, so a stale hit must force the fan-out.
    if let snapshot = await model.watchtowerSnapshot(force: force || cached != nil) {
      apply(snapshot)
      let currentIssueIDs = Set(
        snapshot.signals.filter {
          $0.status != .ok && $0.id != WatchtowerEngine.coverageSignalID
        }.map(\.id))
      if force, !previousIssueIDs.isEmpty {
        let resolved = previousIssueIDs.subtracting(currentIssueIDs)
        if currentIssueIDs.isEmpty {
          recheckBanner = "Resolved — all clear"
        } else if !resolved.isEmpty {
          recheckBanner =
            "\(resolved.count) recovered · \(currentIssueIDs.count) still failing"
        } else {
          recheckBanner = "Still failing"
        }
      }
    }
    loading = false
  }

  private func apply(_ snapshot: WatchtowerSnapshot) {
    signals = snapshot.signals
    alerts = snapshot.alerts
    alertsStatus = snapshot.alertsStatus
    missingScopeChecks = snapshot.missingScopeChecks
    failedChecks = snapshot.failedChecks
    fetchedAt = snapshot.fetchedAt
    capabilityNotes =
      snapshot.missingScopeChecks.map { "Needs permission: \($0)" }
      + snapshot.failedChecks.map { "Check failed: \($0)" }
  }
}

/// Watchtower's status lists keep Dash's original two-tone hierarchy: a base
/// list card with a hairline seated inside an elevated group frame. This style
/// is intentionally local so feature and resource lists can use their newer
/// standalone-card treatment without changing Watchtower's denser scan rhythm.
struct WatchtowerView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.destinationNavigator) private var navigator
  /// The pager keeps every tab mounted, so defer the (analytics-heavy) load
  /// until this tab is actually shown. The badge is warmed separately by
  /// `MainTabView`, so nothing here is needed for cold-launch status.
  @Environment(\.dashTabActive) private var tabActive
  let customization: WatchtowerChartCustomizationState
  @State private var state = WatchtowerScreenState()
  @State private var trafficState = WatchtowerTrafficState()
  @State private var selectedSignal: WatchtowerSignal?
  @Namespace private var analyticsMorph

  /// Re-keys the load task on both account and activation so the deferred load
  /// fires the moment the tab is first swiped or tapped into view.
  private struct LoadKey: Equatable {
    let accountID: String?
    let active: Bool
  }

  var body: some View {
    ZStack {
      if customization.isEditing {
        customizationContent
          .transition(.opacity)
          .zIndex(1)
      } else {
        standardContent
          .transition(.opacity)
      }
    }
    .dashSectionEntrance()
    .dashCatalogScreen()
    .task(id: LoadKey(accountID: model.activeAccountID, active: tabActive)) {
      guard tabActive else { return }
      await load()
    }
    .onChange(of: model.grantedScopes) {
      guard tabActive else { return }
      Task {
        await trafficState.load(model: model, force: true)
      }
    }
    .dashTray(item: $selectedSignal, title: { $0.title }) { signal in
      WatchtowerSignalTray(
        signal: signal,
        isMuted: state.mutedSignalIDs.contains(signal.id),
        toggleMute: { toggleMute(signal) },
        openResource: signal.destination.map { destination in
          { openResource(destination) }
        }
      )
    }
    .onChange(of: state.issueCount) { previous, current in
      if previous > 0, current == 0 {
        DashDelight.recoverFromIssue()
      }
    }
  }

  private var standardContent: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        if model.activeAccountID == nil {
          accountUnavailableCard
            .dashSectionReveal()
        } else {
          diagnosticsSection
            .dashSectionReveal()
          chartsSection
            .dashSectionContentReveal()
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, DashTheme.Spacing.compact)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .modifier(DashScrollEdgeEffectsHidden())
    .refreshable { await load(force: true) }
  }

  private var customizationContent: some View {
    ScrollView {
      WatchtowerTrafficView(
        state: trafficState,
        customization: customization,
        isEditing: true,
        morphNamespace: analyticsMorph
      )
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, DashTheme.Spacing.compact)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .modifier(DashScrollEdgeEffectsHidden())
    .background(DashTheme.canvas)
  }

  private var chartsSection: some View {
    VStack(alignment: .leading, spacing: DashTheme.Spacing.itemGap) {
      DashSectionHeader(DashL10n.string("Charts"))
      WatchtowerTrafficView(
        state: trafficState,
        customization: customization,
        isEditing: false,
        morphNamespace: analyticsMorph
      )
    }
  }

  private var diagnosticsSection: some View {
    VStack(alignment: .leading, spacing: DashTheme.Spacing.itemGap) {
      DashSectionHeader(DashL10n.string("Diagnostics"))
      diagnosticsContent
    }
  }

  @ViewBuilder
  private var diagnosticsContent: some View {
    if state.loading, state.signals.isEmpty {
      // Health checks have their own cold state. Account charts can paint or
      // load independently above it.
      DashListSkeleton(rows: 4)
    } else {
      if state.loading {
        updatingStrip
      }

      freshnessCard

      if let recheckBanner = state.recheckBanner {
        DashNotice(
          kind: recheckBanner.hasPrefix("Resolved") ? .success : .warning,
          message: recheckBanner
        )
      }

      if state.signals.isEmpty {
        DashEmptyState(
          icon: SolarAsset.Content.shieldCheck,
          title: DashL10n.string("Nothing to watch yet"),
          message: DashL10n.string("No monitored resources found in this account.")
        )
      }

      if !state.capabilityNotes.isEmpty {
        DashNotice(
          kind: .warning,
          message: state.capabilityNotes.prefix(3).joined(separator: "\n")
        )
      }

      if !state.coverageLimits.isEmpty {
        DashListGroup(title: "Coverage limits") {
          ForEach(state.coverageLimits) { signal in
            signalRow(signal)
          }
        }
      }

      if !state.issues.isEmpty {
        DashListGroup(title: "Needs attention") {
          ForEach(state.issues) { signal in
            signalRow(signal)
          }
        }
      }

      if !state.mutedIssues.isEmpty {
        DashListGroup(title: "Muted") {
          ForEach(state.mutedIssues) { signal in
            signalRow(signal)
          }
        }
      }

      if !state.healthy.isEmpty {
        DashListGroup(title: "All clear") {
          ForEach(state.healthy) { signal in
            signalRow(signal)
          }
        }
      }

      if !state.missingScopeChecks.isEmpty || !state.failedChecks.isEmpty {
        footerNotices
      }
    }
  }

  private func load(force: Bool = false) async {
    async let health: Void = state.load(model: model, force: force)
    async let traffic: Void = trafficState.load(model: model, force: force)
    _ = await (health, traffic)
  }

  private var updatingStrip: some View {
    HStack(spacing: DashTheme.Spacing.compact) {
      DashLoadingRing(color: DashTheme.brand, size: 16, lineWidth: 2.5)
      Text("Updating…")
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Updating")
  }

  private var freshnessCard: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let freshness = state.fetchedAt.map {
        WatchtowerFreshness.classify(fetchedAt: $0, now: context.date)
      }
      DashCard {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text(DashL10n.string("Account checks"))
              .dashTextStyle(.bodySemibold)
              .foregroundStyle(DashTheme.strong)
            Text(
              WatchtowerFreshness.checkedText(
                fetchedAt: state.fetchedAt,
                now: context.date)
            )
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
            .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 12)
          Text(freshnessLabel(freshness))
            .dashTextStyle(.captionSemibold)
            .foregroundStyle(freshnessColor(freshness))
        }
      }
    }
  }

  private func freshnessLabel(_ freshness: WatchtowerFreshness?) -> String {
    switch freshness {
    case .fresh: DashL10n.string("Current")
    case .aging: DashL10n.string("Aging")
    case .stale: DashL10n.string("Stale")
    case nil: DashL10n.string("Not checked")
    }
  }

  private func freshnessColor(_ freshness: WatchtowerFreshness?) -> Color {
    switch freshness {
    case .fresh: DashTheme.success
    case .aging: DashTheme.warning
    case .stale: DashTheme.danger
    case nil: DashTheme.subtle
    }
  }

  private var accountUnavailableCard: some View {
    DashCard {
      Text("No Cloudflare account is available for this user.")
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
    }
  }

  @ViewBuilder
  private func signalRow(_ signal: WatchtowerSignal) -> some View {
    // The full row opens one detail tray. Muting and resource navigation live
    // there, so a duplicate dots target does not compete with the row tap.
    Button {
      selectedSignal = signal
    } label: {
      signalListRow(signal)
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityIdentifier("watchtower-signal-\(signal.id)")
  }

  private func signalListRow(_ signal: WatchtowerSignal) -> some View {
    DashListRow(
      title: signal.title,
      subtitle: signalSubtitle(signal),
      showsChevron: false,
      accessory: { signalBadge(signal.status) }
    )
    .accessibilityLabel(signalAccessibilityLabel(signal))
  }

  private func signalSubtitle(_ signal: WatchtowerSignal) -> String {
    var parts = [Self.signalDetail(signal)]
    if signal.destination == nil, signal.externalURL != nil, signal.status != .ok {
      parts.append(DashL10n.string("Opens Cloudflare"))
    }
    return parts.joined(separator: " · ")
  }

  /// Dismisses the tray and pushes the signal's resource onto the tab stack.
  private func openResource(_ destination: Destination) {
    selectedSignal = nil
    navigator?.push(destination)
  }

  private func toggleMute(_ signal: WatchtowerSignal) {
    if state.mutedSignalIDs.contains(signal.id) {
      WatchtowerMuteStore.unmute(signal.id)
    } else {
      WatchtowerMuteStore.mute(signal.id, title: signal.title)
    }
    state.refreshMutedSignals()
    DashDelight.selectionChanged()
  }

  /// Names the offending resource on the row. Signals that no longer push a
  /// screen — tunnels, Pages — are the whole answer or they are not an answer:
  /// "1 tunnel down" with no name and nowhere to tap is a dead end.
  static func signalDetail(_ signal: WatchtowerSignal) -> String {
    guard let resource = signal.resourceName, signal.status != .ok,
      !signal.detail.contains(resource)
    else { return signal.detail }
    return "\(signal.detail) · \(resource)"
  }

  private func signalAccessibilityLabel(_ signal: WatchtowerSignal) -> String {
    let statusText: String =
      switch signal.status {
      case .ok: DashL10n.string("OK")
      case .warning: DashL10n.string("Warning")
      case .critical: DashL10n.string("Critical")
      }
    var label =
      "\(signal.title), \(Self.signalDetail(signal)), \(StatusBadge.accessibilityText(for: statusText))"
    if let action = signal.suggestedAction { label += ", \(action)" }
    if signal.destination == nil, signal.externalURL != nil, signal.status != .ok {
      label += ", \(DashL10n.string("Opens Cloudflare"))"
    }
    return label
  }

  @ViewBuilder
  private var footerNotices: some View {
    VStack(spacing: 12) {
      if !state.missingScopeChecks.isEmpty {
        DashNotice(
          kind: .warning,
          message:
            "Some checks need access: \(state.missingScopeChecks.joined(separator: ", ")). Grant access to watch the full account."
        )
        DashSecondaryPillButton(title: DashFailureAction.grantAccess.title) {
          model.requestAccess(to: DashAuthorizationScopes.watchtower)
        }
      }
      if !state.failedChecks.isEmpty {
        DashNotice(
          kind: .error,
          message:
            "Temporarily unavailable: \(state.failedChecks.joined(separator: ", ")). Pull to refresh when you’re back online."
        )
      }
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private func signalBadge(_ status: WatchtowerStatus) -> some View {
    switch status {
    case .ok:
      StatusBadge(text: DashL10n.string("OK"))
    case .warning:
      StatusBadge(text: DashL10n.string("Warning"))
    case .critical:
      StatusBadge(text: DashL10n.string("Critical"))
    }
  }

}

private struct WatchtowerSignalTray: View {
  let signal: WatchtowerSignal
  let isMuted: Bool
  let toggleMute: () -> Void
  /// Present when the signal points at a resource screen; pushes it and closes
  /// the tray. Navigation lives here, not on the row, so the list stays a scan.
  var openResource: (() -> Void)?
  @Environment(\.openURL) private var openURL

  private var openTitle: String {
    signal.resourceName.map { DashL10n.string("Open \($0)") }
      ?? DashL10n.string("Open resource")
  }

  private var status: String {
    switch signal.status {
    case .ok: DashL10n.string("OK")
    case .warning: DashL10n.string("Warning")
    case .critical: DashL10n.string("Critical")
    }
  }

  private var fields: [DashDetailField] {
    [
      DashDetailField(label: DashL10n.string("Status"), value: status),
      signal.resourceName.map { DashDetailField(label: DashL10n.string("Resource"), value: $0) },
      DashDetailField(
        label: DashL10n.string("Details"), value: WatchtowerView.signalDetail(signal)),
      signal.suggestedAction.map {
        DashDetailField(label: DashL10n.string("Suggested action"), value: $0)
      },
      DashDetailField(
        label: DashL10n.string("Observed"),
        value: signal.observedAt.formatted(date: .abbreviated, time: .shortened)),
    ].compactMap { $0 }
  }

  var body: some View {
    DashDetailTray(fields: fields) {
      // Primary action pill stays bottom-most; the reversible mute sub-action
      // sits above it.
      VStack(spacing: 12) {
        if let openResource {
          if signal.status != .ok, signal.id != WatchtowerEngine.coverageSignalID {
            muteSubAction
          }
          DashActionButton(title: openTitle, action: openResource)
        } else if let externalURL = signal.externalURL {
          if signal.status != .ok, signal.id != WatchtowerEngine.coverageSignalID {
            muteSubAction
          }
          DashActionButton(
            title: DashL10n.string("Open in Cloudflare"),
            icon: SolarAsset.cloudflare
          ) {
            openURL(externalURL)
          }
        } else if signal.status != .ok, signal.id != WatchtowerEngine.coverageSignalID {
          DashActionButton(
            title: isMuted
              ? DashL10n.string("Unmute") : DashL10n.string("Mute for 24 hours"),
            action: toggleMute
          )
        }
      }
    }
  }

  private var muteSubAction: some View {
    DashTrayPillButton(
      title: isMuted
        ? DashL10n.string("Unmute") : DashL10n.string("Mute for 24 hours"),
      action: toggleMute
    )
  }
}
