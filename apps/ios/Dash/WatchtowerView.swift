import CloudflareAPI
import SwiftUI

struct WatchtowerView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var signals: [WatchtowerSignal] = []
  @State private var alerts: [NotificationHistoryEntry] = []
  @State private var alertsStatus: WatchtowerAlertsStatus = .loading
  @State private var missingScopeChecks: [String] = []
  @State private var failedChecks: [String] = []
  @State private var fetchedAt: Date?
  @State private var loading = true
  @AppStorage(WatchtowerNotifier.optInDefaultsKey) private var notificationsEnabled = false
  @State private var notificationsDenied = false

  private var summary: WatchtowerSummary {
    WatchtowerSummary(
      critical: signals.filter { $0.status == .critical }.count,
      warning: signals.filter { $0.status == .warning }.count,
      ok: signals.filter { $0.status == .ok }.count
    )
  }

  private var issues: [WatchtowerSignal] { signals.filter { $0.status != .ok } }
  private var healthy: [WatchtowerSignal] { signals.filter { $0.status == .ok } }
  private var issueCount: Int { summary.critical + summary.warning }
  private var allClear: Bool { issueCount == 0 }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        summaryCard

        if loading, model.activeAccountID != nil {
          loadingCard
        }

        if !loading, !issues.isEmpty {
          DashListGroup(title: "Needs attention") {
            DashListCardRows(items: issues) { signal in
              signalRow(signal)
            }
          }
          .dashContentReveal()
        }

        if !loading, !healthy.isEmpty {
          DashListGroup(title: "All clear") {
            DashListCardRows(items: healthy) { signal in
              signalRow(signal)
            }
          }
          .dashContentReveal(1)
        }

        if alertsStatus == .ok {
          DashListGroup(title: "Recent alerts") {
            if alerts.isEmpty {
              Text("No notifications sent recently.")
                .font(.footnote)
                .foregroundStyle(DashTheme.subtle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            } else {
              DashListCardRows(items: alerts) { alert in
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
    .refreshable { await load(force: true) }
    .task(id: model.activeAccountID) { await load() }
  }

  @ViewBuilder
  private var summaryCard: some View {
    DashCard {
      if model.activeAccountID == nil {
        Text("No Cloudflare account is available for this user.")
          .font(.subheadline)
          .foregroundStyle(DashTheme.subtle)
      } else if loading {
        VStack(alignment: .leading, spacing: 8) {
          DashLoadingRing(color: DashTheme.brand)
          Text("Checking zones, tunnels, certificates…")
            .font(.footnote)
            .foregroundStyle(DashTheme.subtle)
        }
      } else if signals.isEmpty {
        Text("Nothing to watch yet — no monitored resources found in this account.")
          .font(.subheadline)
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
          SolarIcon(
            asset: allClear ? SolarAsset.shieldCheck : SolarAsset.danger,
            size: 28,
            color: allClear
              ? DashTheme.success
              : summary.critical > 0 ? DashTheme.danger : DashTheme.warning
          )
          VStack(alignment: .leading, spacing: 2) {
            Text(
              allClear
                ? "All systems normal"
                : "\(issueCount) issue\(issueCount == 1 ? "" : "s") need\(issueCount == 1 ? "s" : "") attention"
            )
            .font(.headline)
            .foregroundStyle(DashTheme.text)
            .fixedSize(horizontal: false, vertical: true)
            Text(
              "\(signals.count) check\(signals.count == 1 ? "" : "s") · \(model.activeAccount?.name ?? "account")"
            )
            .font(.caption)
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

    if let destination = signal.destination {
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
              .font(.caption2)
              .foregroundStyle(DashTheme.placeholder)
          }
        }
      } else {
        HStack(alignment: .top, spacing: 12) {
          alertCopy(alert)
          Spacer(minLength: 8)
          if let sent = alert.sent {
            Text(relativeTime(sent))
              .font(.caption2)
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
        .font(.subheadline.weight(.medium))
        .foregroundStyle(DashTheme.text)
      if let subtitle = alert.subtitle {
        Text(subtitle)
          .font(.caption)
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
            notificationsDenied = false
            return
          }
          Task {
            let granted = await WatchtowerNotifier.requestAuthorization()
            if !granted {
              notificationsEnabled = false
              notificationsDenied = true
            }
          }
        }
      if notificationsDenied {
        DashNotice(
          kind: .warning,
          message: "Notifications are turned off in Settings. Enable them for Dash to get alerts.")
      }
    }
  }

  @ViewBuilder
  private var footerCaption: some View {
    VStack(spacing: 4) {
      if !missingScopeChecks.isEmpty {
        Text("Access needed: \(missingScopeChecks.joined(separator: ", "))")
          .foregroundStyle(DashTheme.warning)
      }
      if !failedChecks.isEmpty {
        Text("Temporarily unavailable: \(failedChecks.joined(separator: ", "))")
          .foregroundStyle(DashTheme.placeholder)
      }
      if missingScopeChecks.isEmpty, failedChecks.isEmpty {
        Text(
          "Watching \(model.activeAccount?.name ?? "this account") across zones, tunnels, certificates, and deployments"
        )
        .foregroundStyle(DashTheme.placeholder)
      }
      if let fetchedAt {
        Text("Updated \(relativeDate(fetchedAt))")
          .foregroundStyle(DashTheme.placeholder)
      }
    }
    .font(.caption2)
    .multilineTextAlignment(.center)
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

  private func load(force: Bool = false) async {
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
