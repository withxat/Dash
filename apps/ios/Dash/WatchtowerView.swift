import CloudflareAPI
import Observation
import SwiftUI

/// Shared Watchtower screen state for compact stack and regular split layouts.
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
    let scored = signals.filter { $0.status == .ok || !mutedSignalIDs.contains($0.id) }
    return WatchtowerSummary(
      critical: scored.filter { $0.status == .critical }.count,
      warning: scored.filter { $0.status == .warning }.count,
      ok: scored.filter { $0.status == .ok }.count
    )
  }

  var issues: [WatchtowerSignal] {
    signals.filter { $0.status != .ok && !mutedSignalIDs.contains($0.id) }
  }
  var mutedIssues: [WatchtowerSignal] {
    signals.filter { $0.status != .ok && mutedSignalIDs.contains($0.id) }
  }
  var healthy: [WatchtowerSignal] { signals.filter { $0.status == .ok } }
  var issueCount: Int { summary.critical + summary.warning }
  var allClear: Bool { issueCount == 0 }
  var recheckBanner: String?
  var capabilityNotes: [String] = []

  func refreshMutedSignals() {
    mutedSignalIDs = WatchtowerMuteStore.mutedIDs()
  }

  func load(model: AppModel, force: Bool = false) async {
    refreshMutedSignals()
    guard model.activeAccountID != nil else {
      loading = false
      signals = []
      alerts = []
      return
    }
    let previousIssueIDs = Set(signals.filter { $0.status != .ok }.map(\.id))
    if signals.isEmpty { loading = true }
    if let snapshot = await model.watchtowerSnapshot(force: force) {
      signals = snapshot.signals
      alerts = snapshot.alerts
      alertsStatus = snapshot.alertsStatus
      missingScopeChecks = snapshot.missingScopeChecks
      failedChecks = snapshot.failedChecks
      fetchedAt = snapshot.fetchedAt
      capabilityNotes =
        snapshot.missingScopeChecks.map { "Needs permission: \($0)" }
        + snapshot.failedChecks.map { "Check failed: \($0)" }
      let currentIssueIDs = Set(snapshot.signals.filter { $0.status != .ok }.map(\.id))
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
}

/// Watchtower's status lists keep Dash's original two-tone hierarchy: a base
/// list card with a hairline seated inside an elevated group frame. This style
/// is intentionally local so feature and resource lists can use their newer
/// standalone-card treatment without changing Watchtower's denser scan rhythm.
private struct WatchtowerListGroup<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text(title)
          .dashTextStyle(.bodyMedium)
          .foregroundStyle(DashTheme.subtle)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      VStack(alignment: .leading, spacing: 0) { content() }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashTheme.base)
        .clipShape(
          RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
            .stroke(DashTheme.line, lineWidth: 0.5)
        }
        .padding(.horizontal, -0.5)
        .padding(.bottom, -0.5)
    }
    .background(DashTheme.elevated)
    .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
        .stroke(DashTheme.line, lineWidth: 0.5)
    }
  }
}

private struct WatchtowerListRows<Item: Identifiable, Row: View>: View {
  let items: [Item]
  @ViewBuilder let row: (Item) -> Row

  var body: some View {
    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
      row(item)
      if index < items.count - 1 {
        DashListGroupDivider()
      }
    }
  }
}

struct WatchtowerView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var state = WatchtowerScreenState()
  @State private var selectedSignal: WatchtowerSignal?
  /// When set (regular-width split), signal rows select a detail destination.
  var selection: Binding<Destination?>?

  init(selection: Binding<Destination?>? = nil) {
    self.selection = selection
  }

  var body: some View {
    let capabilityIndex = state.recheckBanner == nil ? 0 : 1
    let issuesIndex = capabilityIndex + (state.capabilityNotes.isEmpty ? 0 : 1)
    let mutedIndex = issuesIndex + (state.issues.isEmpty ? 0 : 1)
    let healthyIndex = mutedIndex + (state.mutedIssues.isEmpty ? 0 : 1)
    let alertsIndex = healthyIndex + (state.healthy.isEmpty ? 0 : 1)

    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        summaryCard
          .dashSectionReveal()

        if let recheckBanner = state.recheckBanner {
          DashNotice(
            kind: recheckBanner.hasPrefix("Resolved") ? .success : .warning,
            message: recheckBanner
          )
          .dashSectionContentReveal()
        }

        if !state.capabilityNotes.isEmpty {
          DashNotice(
            kind: .warning,
            message: state.capabilityNotes.prefix(3).joined(separator: "\n")
          )
          .dashSectionContentReveal(capabilityIndex)
        }

        if state.loading, model.activeAccountID != nil {
          loadingCard
            .dashSectionReveal(1)
        }

        if !state.loading, !state.issues.isEmpty {
          WatchtowerListGroup(title: "Needs attention") {
            WatchtowerListRows(items: state.issues) { signal in
              signalRow(signal)
            }
          }
          .dashSectionContentReveal(issuesIndex)
        }

        if !state.loading, !state.mutedIssues.isEmpty {
          WatchtowerListGroup(title: "Muted") {
            WatchtowerListRows(items: state.mutedIssues) { signal in
              signalRow(signal)
            }
          }
          .dashSectionContentReveal(mutedIndex)
        }

        if !state.loading, !state.healthy.isEmpty {
          WatchtowerListGroup(title: "All clear") {
            WatchtowerListRows(items: state.healthy) { signal in
              signalRow(signal)
            }
          }
          .dashSectionContentReveal(healthyIndex)
        }

        if state.alertsStatus == .ok, !state.alerts.isEmpty {
          WatchtowerListGroup(title: "Recent alerts") {
            WatchtowerListRows(items: state.alerts) { alert in
              alertRow(alert)
            }
          }
          .dashSectionContentReveal(alertsIndex)
        }

        if !state.missingScopeChecks.isEmpty || !state.failedChecks.isEmpty {
          footerNotices
            .dashSectionReveal(2)
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, DashTheme.Spacing.section)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .dashSectionEntrance()
    .dashCatalogScreen("Watchtower")
    .refreshable { await state.load(model: model, force: true) }
    .task(id: model.activeAccountID) { await state.load(model: model) }
    .dashTray(item: $selectedSignal, title: { $0.title }) { signal in
      WatchtowerSignalTray(
        signal: signal,
        isMuted: state.mutedSignalIDs.contains(signal.id),
        toggleMute: { toggleMute(signal) }
      )
    }
    .onChange(of: state.issueCount) { previous, current in
      if previous > 0, current == 0 {
        DashDelight.recoverFromIssue()
      }
    }
  }

  @ViewBuilder
  private var summaryCard: some View {
    DashCard {
      if model.activeAccountID == nil {
        Text("No Cloudflare account is available for this user.")
          .dashTextStyle(.supporting)
          .foregroundStyle(DashTheme.subtle)
      } else if state.loading {
        VStack(alignment: .leading, spacing: 8) {
          DashLoadingRing(color: DashTheme.brand)
          Text("Checking zones, tunnels, certificates…")
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
        }
      } else if state.signals.isEmpty {
        Text("Nothing to watch yet — no monitored resources found in this account.")
          .dashTextStyle(.supporting)
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
          SolarIcon(
            asset: state.allClear ? SolarAsset.shieldCheck : SolarAsset.danger,
            size: 28,
            color: state.allClear
              ? DashTheme.success
              : state.summary.critical > 0 ? DashTheme.danger : DashTheme.warning
          )
          VStack(alignment: .leading, spacing: 2) {
            Text(
              state.allClear
                ? "All systems normal"
                : "\(state.issueCount) issue\(state.issueCount == 1 ? "" : "s") need\(state.issueCount == 1 ? "s" : "") attention"
            )
            .dashTextStyle(.sectionTitle)
            .foregroundStyle(DashTheme.text)
            .fixedSize(horizontal: false, vertical: true)
            Text(
              "\(state.signals.count) check\(state.signals.count == 1 ? "" : "s") · \(model.activeAccount?.name ?? "account")"
            )
            .dashTextStyle(.caption)
            .foregroundStyle(DashTheme.subtle)
            .fixedSize(horizontal: false, vertical: true)
            if let fetchedAt = state.fetchedAt {
              HStack(spacing: 4) {
                SolarIcon(asset: SolarAsset.clock, size: 13, color: freshnessColor(fetchedAt))
                Text(WatchtowerFreshness.checkedText(fetchedAt: fetchedAt))
                  .dashTextStyle(.caption)
                  .foregroundStyle(freshnessColor(fetchedAt))
              }
              .fixedSize(horizontal: false, vertical: true)
            }
          }
          Spacer(minLength: 0)
        }
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
        .stroke(DashTheme.line, lineWidth: 0.5)
    }
  }

  private var loadingCard: some View {
    DashCard {
      VStack(spacing: 12) {
        ForEach(0..<3, id: \.self) { _ in
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(DashTheme.recessed)
            .frame(height: 40)
        }
      }
    }
  }

  @ViewBuilder
  private func signalRow(_ signal: WatchtowerSignal) -> some View {
    let content = signalRowContent(signal)

    HStack(spacing: 2) {
      Group {
        if let selection, let destination = signal.destination {
          Button {
            selection.wrappedValue = destination
          } label: {
            content
          }
          .buttonStyle(DashPressButtonStyle())
          .accessibilityAddTraits(selection.wrappedValue == destination ? .isSelected : [])
        } else if let destination = signal.destination {
          DashDestinationLink(destination: destination) { content }
        } else {
          Button {
            selectedSignal = signal
          } label: {
            content
          }
          .buttonStyle(DashPressButtonStyle())
        }
      }
      Button {
        selectedSignal = signal
      } label: {
        SolarIcon(asset: SolarAsset.menuDots, size: 18, color: DashTheme.faint)
          .dashCompactHitTarget()
      }
      .buttonStyle(DashPressButtonStyle())
      .accessibilityLabel("Actions for \(signal.title)")
      .accessibilityIdentifier("watchtower-actions-\(signal.id)")
    }
    .contextMenu {
      if signal.status != .ok {
        if state.mutedSignalIDs.contains(signal.id) {
          Button("Unmute") { toggleMute(signal) }
        } else {
          Button("Mute for 24 hours") { toggleMute(signal) }
        }
      }
    }
  }

  private func toggleMute(_ signal: WatchtowerSignal) {
    if state.mutedSignalIDs.contains(signal.id) {
      WatchtowerMuteStore.unmute(signal.id)
    } else {
      WatchtowerMuteStore.mute(signal.id, title: signal.title)
    }
    state.refreshMutedSignals()
    UISelectionFeedbackGenerator().selectionChanged()
  }

  private func freshnessColor(_ fetchedAt: Date) -> Color {
    switch WatchtowerFreshness.classify(fetchedAt: fetchedAt) {
    case .fresh: DashTheme.subtle
    case .aging: DashTheme.warning
    case .stale: DashTheme.danger
    }
  }

  @ViewBuilder
  private func signalRowContent(_ signal: WatchtowerSignal) -> some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          signalCopy(signal)
          HStack(spacing: 8) {
            signalBadge(signal.status)
            Spacer(minLength: 0)
            if signal.destination != nil {
              SolarIcon(asset: SolarAsset.chevronRight, size: 16, color: DashTheme.placeholder)
            }
          }
        }
      } else {
        HStack(spacing: 12) {
          signalCopy(signal)
          Spacer(minLength: 8)
          signalBadge(signal.status)
          if signal.destination != nil {
            SolarIcon(asset: SolarAsset.chevronRight, size: 16, color: DashTheme.placeholder)
          }
        }
      }
    }
    .padding(.vertical, 12)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(signalAccessibilityLabel(signal))
  }

  private func signalCopy(_ signal: WatchtowerSignal) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(signal.title)
        .dashTextStyle(.bodySemibold)
        .foregroundStyle(DashTheme.text)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
      Text(signalDetail(signal))
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.rowSubtitle)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
      if let action = signal.suggestedAction, signal.status != .ok {
        Text(action)
          .dashTextStyle(.caption)
          .foregroundStyle(DashTheme.brand)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .layoutPriority(1)
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

  private func signalDetail(_ signal: WatchtowerSignal) -> String {
    Self.signalDetail(signal)
  }

  private func signalAccessibilityLabel(_ signal: WatchtowerSignal) -> String {
    let statusText: String =
      switch signal.status {
      case .ok: "OK"
      case .warning: "Warning"
      case .critical: "Critical"
      }
    var label =
      "\(signal.title), \(signalDetail(signal)), \(StatusBadge.accessibilityText(for: statusText))"
    if let action = signal.suggestedAction { label += ", \(action)" }
    return label
  }

  @ViewBuilder
  private func alertRow(_ alert: NotificationHistoryEntry) -> some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 6) {
          alertCopy(alert)
          if let sent = alert.sent {
            Text(relativeTime(sent))
              .dashTextStyle(.micro)
              .foregroundStyle(DashTheme.placeholder)
          }
        }
      } else {
        HStack(alignment: .top, spacing: 12) {
          alertCopy(alert)
          Spacer(minLength: 8)
          if let sent = alert.sent {
            Text(relativeTime(sent))
              .dashTextStyle(.micro)
              .foregroundStyle(DashTheme.placeholder)
          }
        }
      }
    }
    .padding(.vertical, 12)
  }

  private func alertCopy(_ alert: NotificationHistoryEntry) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(alert.title)
        .dashTextStyle(.bodySemibold)
        .foregroundStyle(DashTheme.text)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
      if let subtitle = alert.subtitle {
        Text(subtitle)
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.rowSubtitle)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .layoutPriority(1)
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
      StatusBadge(text: "OK")
    case .warning:
      StatusBadge(text: "Warning")
    case .critical:
      StatusBadge(text: "Critical")
    }
  }

  private func relativeTime(_ iso: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

private struct WatchtowerSignalTray: View {
  let signal: WatchtowerSignal
  let isMuted: Bool
  let toggleMute: () -> Void

  private var status: String {
    switch signal.status {
    case .ok: "OK"
    case .warning: "Warning"
    case .critical: "Critical"
    }
  }

  private var fields: [DashDetailField] {
    [
      DashDetailField(label: "Status", value: status),
      signal.resourceName.map { DashDetailField(label: "Resource", value: $0) },
      DashDetailField(label: "Details", value: WatchtowerView.signalDetail(signal)),
      signal.suggestedAction.map { DashDetailField(label: "Suggested action", value: $0) },
      DashDetailField(
        label: "Observed",
        value: signal.observedAt.formatted(date: .abbreviated, time: .shortened)),
    ].compactMap { $0 }
  }

  var body: some View {
    DashDetailTray(fields: fields) {
      if signal.status != .ok {
        DashTrayPillButton(title: isMuted ? "Unmute" : "Mute for 24 hours") {
          toggleMute()
        }
      }
    }
  }
}
