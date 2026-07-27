import CloudflareAPI
import Observation
import SwiftUI

@MainActor
@Observable
final class WatchtowerInboxScreenState {
  private(set) var loadedContext: AccountRequestContext?
  var contents = WatchtowerInboxContents.empty
  var ignoredIDs: Set<String> = []
  var alertsStatus: WatchtowerAlertsStatus = .loading
  var loading = true
  var hasPresentedContent = false
  private var activeLoadID: UUID?

  func reset(for context: AccountRequestContext?) {
    guard loadedContext != context else { return }
    loadedContext = context
    activeLoadID = nil
    contents = .empty
    ignoredIDs = []
    alertsStatus = .loading
    loading = context != nil
    hasPresentedContent = false
  }

  @discardableResult
  func beginLoad(for context: AccountRequestContext) -> UUID {
    reset(for: context)
    let loadID = UUID()
    activeLoadID = loadID
    loading = contents.isEmpty
    return loadID
  }

  func ownsLoad(_ loadID: UUID, context: AccountRequestContext) -> Bool {
    activeLoadID == loadID && loadedContext == context
  }
}

/// Watchtower's three distinct alert semantics: current Dash detections,
/// unread Cloudflare deliveries, and Cloudflare delivery history.
struct WatchtowerInboxView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.openURL) private var openURL

  private enum Filter: String, CaseIterable, Identifiable {
    case inbox
    case history
    case ignored

    var id: String { rawValue }

    var title: String {
      switch self {
      case .inbox: DashL10n.string("Inbox")
      case .history: DashL10n.string("History")
      case .ignored: DashL10n.string("Ignored")
      }
    }
  }

  @State private var filter: Filter = .inbox
  @State private var state = WatchtowerInboxScreenState()
  @State private var selected: InboxSelection?
  @State private var showsIgnoreAll = false
  @State private var revision = 0

  private struct InboxSelection: Identifiable, Equatable {
    struct ID: Hashable {
      let context: AccountRequestContext
      let entryID: String
    }

    let context: AccountRequestContext
    let entry: WatchtowerInboxEntry

    var id: ID {
      ID(context: context, entryID: entry.id)
    }
  }

  private var visible: [WatchtowerInboxEntry] {
    switch filter {
    case .inbox: state.contents.actionable
    case .history: state.contents.history
    case .ignored: state.contents.ignored
    }
  }

  var body: some View {
    DashFeatureList(
      isLoading: state.loading,
      error: nil,
      hasContent: state.hasPresentedContent,
      retry: { Task { await load(force: true) } },
      header: {
        DashTextTabs(
          items: Filter.allCases.map { ($0.title, $0) },
          selection: $filter
        )
        .accessibilityIdentifier("watchtower-inbox-filter")
      },
      content: {
        if state.alertsStatus == .unavailable {
          DashNotice(
            kind: .warning,
            message: DashL10n.string("Cloudflare alert history needs notifications access.")
          )
        } else if state.alertsStatus == .error {
          DashNotice(
            kind: .error,
            message: DashL10n.string("Couldn’t load Cloudflare alert history. Pull to refresh.")
          )
        }

        filteredContent
          .dashSectionBoundary(
            state.alertsStatus == .unavailable || state.alertsStatus == .error)
      }
    )
    .detailHeader(icon: .solar(SolarAsset.inbox), title: "Alerts")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if filter == .inbox, !state.contents.actionable.isEmpty {
          DashToolbarTextButton(title: "Ignore all") {
            showsIgnoreAll = true
          }
        }
      }
      .dashSeparateToolbarBackground()
    }
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) { await load() }
    .onChange(of: model.accountRequestContext) { _, context in
      state.reset(for: context)
      selected = nil
      showsIgnoreAll = false
    }
    .onChange(of: revision) { _, _ in rebuildFromCache() }
    .dashTray(
      item: $selected,
      title: { $0.entry.title },
      content: { selection in
        let entry = selection.entry
        WatchtowerInboxEntryTray(
          entry: entry,
          isIgnored:
            state.loadedContext == selection.context
            && !entry.localStateIDs.isDisjoint(with: state.ignoredIDs),
          ignore: { ignore(selection) },
          unignore: { unignore(selection) },
          openResource: entry.destination.map { destination in
            {
              openResource(destination, selection: selection)
            }
          },
          openExternal: entry.externalURL.map { url in
            {
              openExternal(url, selection: selection)
            }
          }
        )
      }
    )
    .dashTray(
      isPresented: $showsIgnoreAll,
      title: DashL10n.string("Ignore all alerts")
    ) {
      WatchtowerIgnoreAllTray(count: state.contents.actionable.count) {
        ignoreAllVisible()
        DashDelight.recoverFromIssue()
      }
    }
  }

  private var emptyTitle: String {
    switch filter {
    case .inbox: DashL10n.string("No current or unread alerts")
    case .history: DashL10n.string("No Cloudflare history")
    case .ignored: DashL10n.string("No ignored alerts")
    }
  }

  private var emptyMessage: String {
    switch filter {
    case .inbox:
      DashL10n.string(
        "The badge counts current Dash issues and unread Cloudflare notifications only.")
    case .history:
      DashL10n.string("Cloudflare deliveries you have already seen stay here.")
    case .ignored:
      DashL10n.string("Alerts you ignore stay here on this iPhone.")
    }
  }

  @ViewBuilder
  private var filteredContent: some View {
    if visible.isEmpty {
      DashEmptyState(
        icon: SolarAsset.inbox,
        title: emptyTitle,
        message: emptyMessage
      )
    } else {
      switch filter {
      case .inbox:
        if !state.contents.currentIssues.isEmpty {
          entryGroup(
            title: DashL10n.string("Current Dash issues"),
            entries: state.contents.currentIssues)
        }
        if !state.contents.unreadNotifications.isEmpty {
          entryGroup(
            title: DashL10n.string("Unread from Cloudflare"),
            entries: state.contents.unreadNotifications,
            actionTitle: DashL10n.string("Mark all read"),
            action: markAllUnreadRead
          )
          .dashSectionBoundary(!state.contents.currentIssues.isEmpty)
        }
      case .history:
        entryGroup(
          title: DashL10n.string("Cloudflare history"),
          entries: state.contents.history)
      case .ignored:
        entryGroup(
          title: DashL10n.string("Ignored on this iPhone"),
          entries: state.contents.ignored)
      }
    }
  }

  private func entryGroup(
    title: String,
    entries: [WatchtowerInboxEntry],
    actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) -> some View {
    DashListGroup(
      title: title,
      actionTitle: actionTitle,
      action: action
    ) {
      ForEach(entries) { entry in
        Button {
          select(entry)
        } label: {
          row(entry)
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityIdentifier("watchtower-inbox-\(entry.id)")
      }
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
        } else if entry.category == .unreadNotification {
          StatusBadge(text: DashL10n.string("Unread"))
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
    guard let context = model.accountRequestContext else {
      state.reset(for: nil)
      state.loading = false
      return
    }
    let loadID = state.beginLoad(for: context)
    state.ignoredIDs = WatchtowerInboxStore.ignoredIDs(accountID: context.accountID)
    if let snapshot = await model.watchtowerSnapshot(force: force) {
      guard
        !Task.isCancelled,
        state.ownsLoad(loadID, context: context),
        model.isCurrentAccount(context)
      else { return }
      state.alertsStatus = snapshot.alertsStatus
      state.contents = WatchtowerInboxStore.contents(
        accountID: context.accountID,
        alerts: snapshot.alertsStatus == .ok ? snapshot.alerts : [],
        signals: snapshot.signals
      )
    }
    guard
      !Task.isCancelled,
      state.ownsLoad(loadID, context: context),
      model.isCurrentAccount(context)
    else { return }
    state.ignoredIDs = WatchtowerInboxStore.ignoredIDs(accountID: context.accountID)
    state.loading = false
    state.hasPresentedContent = true
  }

  private func rebuildFromCache() {
    guard let context = model.accountRequestContext, state.loadedContext == context else {
      return
    }
    state.ignoredIDs = WatchtowerInboxStore.ignoredIDs(accountID: context.accountID)
    let cached: WatchtowerSnapshot? = model.featureCache.get(
      FeatureCacheKey.watchtower(context.accountID))
    guard let cached else { return }
    state.alertsStatus = cached.alertsStatus
    state.contents = WatchtowerInboxStore.contents(
      accountID: context.accountID,
      alerts: cached.alertsStatus == .ok ? cached.alerts : [],
      signals: cached.signals
    )
  }

  private func select(_ entry: WatchtowerInboxEntry) {
    guard let context = model.accountRequestContext, state.loadedContext == context else {
      return
    }
    selected = InboxSelection(context: context, entry: entry)
    guard !entry.notificationIDs.isEmpty,
      entry.category != .history
    else { return }
    WatchtowerInboxStore.markRead(
      Array(entry.notificationIDs), accountID: context.accountID)
    model.refreshWatchtowerInboxBadge()
    revision += 1
  }

  private func ignore(_ selection: InboxSelection) {
    guard owns(selection) else { return }
    WatchtowerInboxStore.ignore(
      Array(selection.entry.localStateIDs),
      accountID: selection.context.accountID)
    model.refreshWatchtowerInboxBadge()
    selected = nil
    revision += 1
  }

  private func unignore(_ selection: InboxSelection) {
    guard owns(selection) else { return }
    WatchtowerInboxStore.unignore(
      Array(selection.entry.localStateIDs),
      accountID: selection.context.accountID)
    model.refreshWatchtowerInboxBadge()
    selected = nil
    revision += 1
  }

  private func ignoreAllVisible() {
    guard let context = model.accountRequestContext, state.loadedContext == context else {
      return
    }
    let stateIDs = state.contents.actionable.flatMap { Array($0.localStateIDs) }
    WatchtowerInboxStore.ignoreAll(stateIDs, accountID: context.accountID)
    model.refreshWatchtowerInboxBadge()
    revision += 1
  }

  private func markAllUnreadRead() {
    guard let context = model.accountRequestContext, state.loadedContext == context else {
      return
    }
    let notificationIDs = state.contents.unreadNotifications.flatMap {
      Array($0.notificationIDs)
    }
    WatchtowerInboxStore.markRead(notificationIDs, accountID: context.accountID)
    model.refreshWatchtowerInboxBadge()
    revision += 1
  }

  private func owns(_ selection: InboxSelection) -> Bool {
    state.loadedContext == selection.context
      && model.isCurrentAccount(selection.context)
  }

  private func openResource(_ destination: Destination, selection: InboxSelection) {
    guard owns(selection) else {
      selected = nil
      return
    }
    selected = nil
    navigator?.push(destination)
  }

  private func openExternal(_ url: URL, selection: InboxSelection) {
    guard owns(selection) else {
      selected = nil
      return
    }
    openURL(url)
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
      // the primary verb and stays bottom-most, with the reversible ignore
      // toggle as a sub-action above it; without an open target, the ignore
      // toggle is the only button left and takes the primary slot.
      VStack(spacing: 12) {
        if let openResource {
          ignoreSubAction
          DashActionButton(title: DashL10n.string("Open resource"), action: openResource)
        } else if let openExternal {
          ignoreSubAction
          DashActionButton(
            title: DashL10n.string("Open in Cloudflare"),
            icon: SolarAsset.cloudflare,
            action: openExternal
          )
        } else {
          DashActionButton(
            title: isIgnored
              ? DashL10n.string("Stop ignoring") : DashL10n.string("Ignore"),
            action: isIgnored ? unignore : ignore
          )
        }
      }
    }
  }

  private var ignoreSubAction: some View {
    DashTrayPillButton(
      title: isIgnored
        ? DashL10n.string("Stop ignoring") : DashL10n.string("Ignore"),
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
