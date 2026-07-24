import CloudflareAPI
import SwiftUI

/// Unified Watchtower notification inbox: Cloudflare delivery history + Dash
/// worsen events, with local Pending / Ignored filtering.
struct WatchtowerInboxView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.openURL) private var openURL

  private enum Filter: String, CaseIterable, Identifiable {
    case active
    case ignored

    var id: String { rawValue }

    var title: String {
      switch self {
      // Avoid reusing "Active" (zones/deployments → 正常 / 当前).
      case .active: DashL10n.string("Pending")
      case .ignored: DashL10n.string("Ignored")
      }
    }
  }

  @State private var filter: Filter = .active
  @State private var entries: [WatchtowerInboxEntry] = []
  @State private var ignoredIDs: Set<String> = []
  @State private var alertsStatus: WatchtowerAlertsStatus = .loading
  @State private var loading = true
  @State private var hasPresentedContent = false
  @State private var selected: WatchtowerInboxEntry?
  @State private var showsIgnoreAll = false
  @State private var revision = 0

  private var visible: [WatchtowerInboxEntry] {
    entries.filter { entry in
      switch filter {
      case .active: !ignoredIDs.contains(entry.id)
      case .ignored: ignoredIDs.contains(entry.id)
      }
    }
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: nil,
      hasContent: hasPresentedContent,
      retry: { Task { await load(force: true) } },
      header: {
        DashTextTabs(
          items: Filter.allCases.map { ($0.title, $0) },
          selection: $filter
        )
        .accessibilityIdentifier("watchtower-inbox-filter")
      },
      content: {
        if alertsStatus == .unavailable {
          DashNotice(
            kind: .warning,
            message: DashL10n.string("Cloudflare alert history needs notifications access.")
          )
        } else if alertsStatus == .error {
          DashNotice(
            kind: .error,
            message: DashL10n.string("Couldn’t load Cloudflare alert history. Pull to refresh.")
          )
        }

        if visible.isEmpty {
          DashEmptyState(
            icon: SolarAsset.inbox,
            title: emptyTitle,
            message: emptyMessage
          )
          .dashSectionBoundary(alertsStatus == .unavailable || alertsStatus == .error)
        } else {
          dashListCard {
            dashListCardRows(items: visible) { entry in
              Button {
                selected = entry
              } label: {
                row(entry)
              }
              .buttonStyle(DashSurfaceButtonStyle())
              .accessibilityIdentifier("watchtower-inbox-\(entry.id)")
            }
          }
          .dashSectionBoundary(alertsStatus == .unavailable || alertsStatus == .error)
        }
      }
    )
    .detailHeader(icon: .solar(SolarAsset.inbox), title: "Alerts")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if filter == .active, !visible.isEmpty {
          DashToolbarTextButton(title: "Ignore all") {
            showsIgnoreAll = true
          }
        }
      }
      .dashSeparateToolbarBackground()
    }
    .refreshable { await load(force: true) }
    .task(id: model.activeAccountID) { await load() }
    .onChange(of: revision) { _, _ in rebuildFromCache() }
    .dashTray(
      item: $selected,
      title: { $0.title },
      content: { entry in
        WatchtowerInboxEntryTray(
          entry: entry,
          isIgnored: ignoredIDs.contains(entry.id),
          ignore: { ignore(entry) },
          unignore: { unignore(entry) },
          openResource: entry.destination.map { destination in
            {
              selected = nil
              navigator?.push(destination)
            }
          },
          openExternal: entry.externalURL.map { url in
            {
              openURL(url)
            }
          }
        )
      }
    )
    .dashTray(
      isPresented: $showsIgnoreAll,
      title: DashL10n.string("Ignore all alerts")
    ) {
      WatchtowerIgnoreAllTray(count: visible.count) {
        ignoreAllVisible()
        DashDelight.recoverFromIssue()
      }
    }
  }

  private var emptyTitle: String {
    switch filter {
    case .active: DashL10n.string("No pending alerts")
    case .ignored: DashL10n.string("No ignored alerts")
    }
  }

  private var emptyMessage: String {
    switch filter {
    case .active:
      DashL10n.string("Cloudflare deliveries and Dash detections show up here.")
    case .ignored:
      DashL10n.string("Alerts you ignore stay here on this iPhone.")
    }
  }

  private func row(_ entry: WatchtowerInboxEntry) -> some View {
    DashListRow(
      title: entry.title,
      subtitle: rowSubtitle(entry),
      icon: entry.primarySource.listIcon,
      iconColor: entry.primarySource == .dash ? DashTheme.warning : DashTheme.brand,
      trailing: entry.sentAt.map(relativeTime),
      showsChevron: false,
      accessory: {
        if let status = entry.status, status != .ok {
          signalBadge(status)
        }
      }
    )
  }

  private func rowSubtitle(_ entry: WatchtowerInboxEntry) -> String {
    var parts: [String] = []
    let sourceLabel = entry.sources.sorted { $0.rawValue < $1.rawValue }
      .map(\.label)
      .joined(separator: " · ")
    if !sourceLabel.isEmpty { parts.append(sourceLabel) }
    if let detail = entry.detail, !detail.isEmpty { parts.append(detail) }
    return parts.joined(separator: " — ")
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

  private func relativeTime(_ date: Date) -> String {
    RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else {
      entries = []
      ignoredIDs = []
      loading = false
      return
    }
    loading = entries.isEmpty
    ignoredIDs = WatchtowerInboxStore.ignoredIDs(accountID: accountID)
    if let snapshot = await model.watchtowerSnapshot(force: force) {
      alertsStatus = snapshot.alertsStatus
      entries = WatchtowerInboxStore.build(
        accountID: accountID,
        alerts: snapshot.alertsStatus == .ok ? snapshot.alerts : [],
        signals: snapshot.signals
      )
    }
    ignoredIDs = WatchtowerInboxStore.ignoredIDs(accountID: accountID)
    loading = false
    hasPresentedContent = true
  }

  private func rebuildFromCache() {
    guard let accountID = model.activeAccountID else { return }
    ignoredIDs = WatchtowerInboxStore.ignoredIDs(accountID: accountID)
    let cached: WatchtowerSnapshot? = model.featureCache.get(
      FeatureCacheKey.watchtower(accountID))
    guard let cached else { return }
    alertsStatus = cached.alertsStatus
    entries = WatchtowerInboxStore.build(
      accountID: accountID,
      alerts: cached.alertsStatus == .ok ? cached.alerts : [],
      signals: cached.signals
    )
  }

  private func ignore(_ entry: WatchtowerInboxEntry) {
    guard let accountID = model.activeAccountID else { return }
    WatchtowerInboxStore.ignore([entry.id], accountID: accountID)
    model.refreshWatchtowerInboxBadge()
    selected = nil
    revision += 1
  }

  private func unignore(_ entry: WatchtowerInboxEntry) {
    guard let accountID = model.activeAccountID else { return }
    WatchtowerInboxStore.unignore(entry.id, accountID: accountID)
    model.refreshWatchtowerInboxBadge()
    selected = nil
    revision += 1
  }

  private func ignoreAllVisible() {
    guard let accountID = model.activeAccountID else { return }
    WatchtowerInboxStore.ignoreAll(visible.map(\.id), accountID: accountID)
    model.refreshWatchtowerInboxBadge()
    revision += 1
  }
}

private struct WatchtowerInboxEntryTray: View {
  let entry: WatchtowerInboxEntry
  let isIgnored: Bool
  let ignore: () -> Void
  let unignore: () -> Void
  var openResource: (() -> Void)?
  var openExternal: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: DashTheme.Spacing.section) {
      VStack(alignment: .leading, spacing: 6) {
        sourceLine
        if let detail = entry.detail {
          Text(detail)
            .dashTextStyle(.supporting)
            .foregroundStyle(DashTheme.subtle)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let sentAt = entry.sentAt {
          Text(RelativeDateTimeFormatter().localizedString(for: sentAt, relativeTo: .now))
            .dashTextStyle(.caption)
            .foregroundStyle(DashTheme.subtle)
        }
      }

      // Same footer cascade as the Watchtower signal tray: the open action is
      // the primary verb with the ignore toggle as a sub-action; without one,
      // the ignore toggle is the only button left and takes the primary slot.
      VStack(spacing: 12) {
        if let openResource {
          DashActionButton(title: DashL10n.string("Open resource"), action: openResource)
          ignoreSubAction
        } else if let openExternal {
          DashActionButton(
            title: DashL10n.string("Open in Cloudflare"),
            icon: SolarAsset.cloudflare,
            action: openExternal
          )
          ignoreSubAction
        } else {
          DashActionButton(
            title: isIgnored
              ? DashL10n.string("Move to Pending") : DashL10n.string("Ignore"),
            action: isIgnored ? unignore : ignore
          )
        }
      }
    }
  }

  private var ignoreSubAction: some View {
    DashTrayPillButton(
      title: isIgnored
        ? DashL10n.string("Move to Pending") : DashL10n.string("Ignore"),
      action: isIgnored ? unignore : ignore
    )
  }

  private var sourceLine: some View {
    HStack(spacing: 6) {
      ForEach(entry.sources.sorted { $0.rawValue < $1.rawValue }, id: \.self) { source in
        HStack(spacing: 4) {
          SolarIcon(
            asset: source.listIcon,
            size: 12,
            color: source == .dash ? DashTheme.warning : DashTheme.brand
          )
          Text(source.label)
            .dashTextStyle(.captionSemibold)
            .foregroundStyle(source == .dash ? DashTheme.warning : DashTheme.subtle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          source == .dash ? DashTheme.warningTint : DashTheme.recessed,
          in: Capsule(style: .continuous)
        )
      }
      Spacer(minLength: 0)
    }
  }
}
