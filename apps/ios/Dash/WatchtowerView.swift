import CloudflareAPI
import SwiftUI

struct WatchtowerView: View {
  @Environment(AppModel.self) private var model
  @State private var signals: [WatchtowerSignal] = []
  @State private var alerts: [NotificationHistoryEntry] = []
  @State private var alertsStatus: WatchtowerAlertsStatus = .loading
  @State private var unavailableCount = 0
  @State private var loading = true

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
            ForEach(Array(issues.enumerated()), id: \.element.id) { index, signal in
              signalRow(signal)
            }
          }
        }

        if !loading, !healthy.isEmpty {
          DashListGroup(title: "All clear") {
            ForEach(Array(healthy.enumerated()), id: \.element.id) { index, signal in
              signalRow(signal)
            }
          }
        }

        if alertsStatus == .ok {
          DashListGroup(title: "Recent alerts") {
            if alerts.isEmpty {
              Text("No notifications sent recently.")
                .font(.system(size: 13))
                .foregroundStyle(DashTheme.subtle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            } else {
              ForEach(Array(alerts.enumerated()), id: \.element.id) { index, alert in
                alertRow(alert)
              }
            }
          }
        }

        footerCaption
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.bottom, 100)
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
          .font(.system(size: 14))
          .foregroundStyle(DashTheme.subtle)
      } else if loading {
        VStack(alignment: .leading, spacing: 8) {
          ProgressView().tint(DashTheme.brand)
          Text("Checking zones, tunnels, certificates…")
            .font(.system(size: 13))
            .foregroundStyle(DashTheme.subtle)
        }
      } else if signals.isEmpty {
        Text("Nothing to watch yet — no monitored resources found in this account.")
          .font(.system(size: 14))
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(spacing: 12) {
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
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(DashTheme.text)
            Text(
              "\(signals.count) check\(signals.count == 1 ? "" : "s") · \(model.activeAccount?.name ?? "account")"
            )
            .font(.system(size: 12))
            .foregroundStyle(DashTheme.subtle)
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
    let content = HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(signal.title)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(DashTheme.text)
        Text(signal.detail)
          .font(.system(size: 12))
          .foregroundStyle(DashTheme.subtle)
          .lineLimit(2)
      }
      Spacer(minLength: 8)
      signalBadge(signal.status)
      if signal.destination != nil {
        SolarIcon(asset: SolarAsset.chevronRight, size: 12, color: DashTheme.placeholder)
      }
    }
    .padding(.vertical, 10)
    .contentShape(Rectangle())

    if let destination = signal.destination {
      DashDestinationLink(destination: destination) { content }
    } else {
      content
    }
  }

  private func alertRow(_ alert: NotificationHistoryEntry) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(alert.title)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(DashTheme.text)
        if let subtitle = alert.subtitle {
          Text(subtitle)
            .font(.system(size: 12))
            .foregroundStyle(DashTheme.subtle)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 8)
      if let sent = alert.sent {
        Text(relativeTime(sent))
          .font(.system(size: 11))
          .foregroundStyle(DashTheme.placeholder)
      }
    }
    .padding(.vertical, 10)
  }

  private var footerCaption: some View {
    Text(
      unavailableCount > 0
        ? "Watching \(model.activeAccount?.name ?? "this account") · \(unavailableCount) check\(unavailableCount == 1 ? "" : "s") unavailable (missing scopes)"
        : "Watching \(model.activeAccount?.name ?? "this account") across zones, tunnels, certificates, and deployments"
    )
    .font(.system(size: 11))
    .foregroundStyle(DashTheme.placeholder)
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private func signalBadge(_ status: WatchtowerStatus) -> some View {
    switch status {
    case .ok:
      watchtowerBadge(label: "OK", foreground: DashTheme.success, background: DashTheme.successTint)
    case .warning:
      watchtowerBadge(
        label: "Warning", foreground: DashTheme.warning, background: DashTheme.warningTint)
    case .critical:
      watchtowerBadge(
        label: "Attention", foreground: DashTheme.danger, background: DashTheme.dangerTint)
    }
  }

  private func watchtowerBadge(label: String, foreground: Color, background: Color) -> some View {
    Text(label)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(foreground)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(background, in: Capsule())
  }

  private func relativeTime(_ iso: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else {
      loading = false
      signals = []
      alerts = []
      return
    }
    let key = FeatureCacheKey.watchtower(accountID)
    if !force, let cached: WatchtowerSnapshot = model.featureCache.get(key) {
      signals = cached.signals
      alerts = cached.alerts
      alertsStatus = cached.alertsStatus
      unavailableCount = cached.unavailableCount
      loading = false
      return
    }
    if signals.isEmpty { loading = true }
    let result = await WatchtowerEngine.load(client: model.client, accountID: accountID)
    signals = result.signals
    alerts = result.alerts
    alertsStatus = result.alertsStatus
    unavailableCount = result.unavailableCount
    model.featureCache.set(
      key,
      WatchtowerSnapshot(
        signals: signals,
        alerts: alerts,
        alertsStatus: alertsStatus,
        unavailableCount: unavailableCount))
    loading = false
  }
}
