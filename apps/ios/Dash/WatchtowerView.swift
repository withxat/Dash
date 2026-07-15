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
  var notificationsDenied = false

  var summary: WatchtowerSummary {
    WatchtowerSummary(
      critical: signals.filter { $0.status == .critical }.count,
      warning: signals.filter { $0.status == .warning }.count,
      ok: signals.filter { $0.status == .ok }.count
    )
  }

  var issues: [WatchtowerSignal] { signals.filter { $0.status != .ok } }
  var healthy: [WatchtowerSignal] { signals.filter { $0.status == .ok } }
  var issueCount: Int { summary.critical + summary.warning }
  var allClear: Bool { issueCount == 0 }

  func load(model: AppModel, force: Bool = false) async {
    guard model.activeAccountID != nil else {
      loading = false
      signals = []
      alerts = []
      return
    }
    if signals.isEmpty { loading = true }
    if let snapshot = await model.watchtowerSnapshot(force: force) {
      signals = snapshot.signals
      alerts = snapshot.alerts
      alertsStatus = snapshot.alertsStatus
      missingScopeChecks = snapshot.missingScopeChecks
      failedChecks = snapshot.failedChecks
      fetchedAt = snapshot.fetchedAt
    }
    loading = false
  }
}

struct WatchtowerView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var state = WatchtowerScreenState()
  @AppStorage(WatchtowerNotifier.optInDefaultsKey) private var notificationsEnabled = false
  /// When set (regular-width split), signal rows select a detail destination.
  var selection: Binding<Destination?>?

  init(selection: Binding<Destination?>? = nil) {
    self.selection = selection
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        summaryCard

        if state.loading, model.activeAccountID != nil {
          loadingCard
        }

        if !state.loading, !state.issues.isEmpty {
          DashListGroup(title: "Needs attention") {
            DashListCardRows(items: state.issues) { signal in
              signalRow(signal)
            }
          }
          .dashContentReveal()
        }

        if !state.loading, !state.healthy.isEmpty {
          DashListGroup(title: "All clear") {
            DashListCardRows(items: state.healthy) { signal in
              signalRow(signal)
            }
          }
          .dashContentReveal(1)
        }

        if state.alertsStatus == .ok {
          DashListGroup(title: "Recent alerts") {
            if state.alerts.isEmpty {
              Text("No notifications sent recently.")
                .dashTextStyle(.footnote)
                .foregroundStyle(DashTheme.subtle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            } else {
              DashListCardRows(items: state.alerts) { alert in
                alertRow(alert)
              }
            }
          }
        }

        if model.activeAccountID != nil {
          notificationsGroup
        }

        footerCaption
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .dashCatalogScreen("Watchtower")
    .refreshable { await state.load(model: model, force: true) }
    .task(id: model.activeAccountID) { await state.load(model: model) }
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
          }
          Spacer(minLength: 0)
        }
      }
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
      content
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
    .padding(.vertical, 10)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(signalAccessibilityLabel(signal))
  }

  private func signalCopy(_ signal: WatchtowerSignal) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(signal.title)
        .dashTextStyle(.bodyMedium)
        .foregroundStyle(DashTheme.text)
      Text(signal.detail)
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .layoutPriority(1)
  }

  private func signalAccessibilityLabel(_ signal: WatchtowerSignal) -> String {
    let statusText: String =
      switch signal.status {
      case .ok: "OK"
      case .warning: "Warning"
      case .critical: "Critical"
      }
    return "\(signal.title), \(signal.detail), \(StatusBadge.accessibilityText(for: statusText))"
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
    .padding(.vertical, 10)
  }

  private func alertCopy(_ alert: NotificationHistoryEntry) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(alert.title)
        .dashTextStyle(.supportingMedium)
        .foregroundStyle(DashTheme.text)
      if let subtitle = alert.subtitle {
        Text(subtitle)
          .dashTextStyle(.caption)
          .foregroundStyle(DashTheme.subtle)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .layoutPriority(1)
  }

  @ViewBuilder
  private var notificationsGroup: some View {
    DashListGroup(title: "Notifications") {
      DashToggleRow(title: "Notify on new issues", isOn: $notificationsEnabled)
        .onChange(of: notificationsEnabled) { _, enabled in
          guard enabled else {
            state.notificationsDenied = false
            return
          }
          Task {
            let granted = await WatchtowerNotifier.requestAuthorization()
            if !granted {
              notificationsEnabled = false
              state.notificationsDenied = true
            }
          }
        }
      if state.notificationsDenied {
        DashNotice(
          kind: .warning,
          message: "Notifications are turned off in Settings. Enable them for Dash to get alerts.")
      }
    }
  }

  @ViewBuilder
  private var footerCaption: some View {
    VStack(spacing: 12) {
      if !state.missingScopeChecks.isEmpty {
        DashNotice(
          kind: .warning,
          message:
            "Some checks need access: \(state.missingScopeChecks.joined(separator: ", ")). Grant access to watch the full account."
        )
        DashSecondaryPillButton(title: DashFailureAction.grantAccess.title) {
          model.requestAccess(to: Set(CloudflareScopes.published))
        }
      }
      if !state.failedChecks.isEmpty {
        DashNotice(
          kind: .error,
          message:
            "Temporarily unavailable: \(state.failedChecks.joined(separator: ", ")). Pull to refresh when you’re back online."
        )
      }
      if state.missingScopeChecks.isEmpty, state.failedChecks.isEmpty {
        Text(
          "Watching \(model.activeAccount?.name ?? "this account") across zones, tunnels, certificates, and deployments"
        )
        .dashTextStyle(.micro)
        .foregroundStyle(DashTheme.placeholder)
        .multilineTextAlignment(.center)
      }
      if let fetchedAt = state.fetchedAt {
        Text("Updated \(relativeDate(fetchedAt))")
          .dashTextStyle(.micro)
          .foregroundStyle(DashTheme.placeholder)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private func relativeDate(_ date: Date) -> String {
    guard Date().timeIntervalSince(date) >= 60 else { return "just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
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
