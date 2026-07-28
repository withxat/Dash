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

/// Cloudflare's notification deliveries, split by what this iPhone has read.
/// Nothing Dash detected on its own appears here — the account's notification
/// policies are the only thing that decides an alert exists.
struct WatchtowerInboxView: View {
  @Environment(AppModel.self) private var model

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
    case .inbox: state.contents.unreadNotifications
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
    .detailHeader(icon: .solar(SolarAsset.Content.inbox), title: "Alerts")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if filter == .inbox, !state.contents.unreadNotifications.isEmpty {
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
        WatchtowerInboxEntryTray(
          entry: selection.entry,
          isIgnored:
            state.loadedContext == selection.context
            && state.ignoredIDs.contains(selection.entry.id),
          ignore: { ignore(selection) },
          unignore: { unignore(selection) }
        )
      }
    )
    .dashTray(
      isPresented: $showsIgnoreAll,
      title: DashL10n.string("Ignore all alerts")
    ) {
      WatchtowerIgnoreAllTray(count: state.contents.unreadNotifications.count) {
        ignoreAllVisible()
        DashDelight.recoverFromIssue()
      }
    }
  }

  private var emptyTitle: String {
    switch filter {
    case .inbox: DashL10n.string("No unread alerts")
    case .history: DashL10n.string("No Cloudflare history")
    case .ignored: DashL10n.string("No ignored alerts")
    }
  }

  private var emptyMessage: String {
    switch filter {
    case .inbox:
      DashL10n.string(
        "Cloudflare delivers an alert here when one of your notification policies fires.")
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
        entryGroup(
          title: DashL10n.string("Unread"),
          entries: state.contents.unreadNotifications,
          actionTitle: DashL10n.string("Mark all read"),
          action: markAllUnreadRead
        )
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
      subtitle: entry.detail ?? "",
      icon: SolarAsset.cloudflare,
      iconColor: DashTheme.brand,
      trailing: entry.sentAt.map(relativeTime),
      showsChevron: false,
      accessory: {
        if entry.category == .unread {
          StatusBadge(.unread)
        }
      }
    )
  }

  private func relativeTime(_ date: Date) -> String {
    watchtowerRelativeTime(date)
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
        alerts: snapshot.alertsStatus == .ok ? snapshot.alerts : []
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
      alerts: cached.alertsStatus == .ok ? cached.alerts : []
    )
  }

  private func select(_ entry: WatchtowerInboxEntry) {
    guard let context = model.accountRequestContext, state.loadedContext == context else {
      return
    }
    selected = InboxSelection(context: context, entry: entry)
    guard entry.category != .history else { return }
    WatchtowerInboxStore.markRead([entry.id], accountID: context.accountID)
    model.refreshWatchtowerInboxBadge()
    revision += 1
  }

  private func ignore(_ selection: InboxSelection) {
    guard owns(selection) else { return }
    WatchtowerInboxStore.ignore(
      [selection.entry.id], accountID: selection.context.accountID)
    model.refreshWatchtowerInboxBadge()
    selected = nil
    revision += 1
  }

  private func unignore(_ selection: InboxSelection) {
    guard owns(selection) else { return }
    WatchtowerInboxStore.unignore(
      [selection.entry.id], accountID: selection.context.accountID)
    model.refreshWatchtowerInboxBadge()
    selected = nil
    revision += 1
  }

  private func ignoreAllVisible() {
    guard let context = model.accountRequestContext, state.loadedContext == context else {
      return
    }
    WatchtowerInboxStore.ignore(
      state.contents.unreadNotifications.map(\.id), accountID: context.accountID)
    model.refreshWatchtowerInboxBadge()
    revision += 1
  }

  private func markAllUnreadRead() {
    guard let context = model.accountRequestContext, state.loadedContext == context else {
      return
    }
    WatchtowerInboxStore.markRead(
      state.contents.unreadNotifications.map(\.id), accountID: context.accountID)
    model.refreshWatchtowerInboxBadge()
    revision += 1
  }

  private func owns(_ selection: InboxSelection) -> Bool {
    state.loadedContext == selection.context
      && model.isCurrentAccount(selection.context)
  }
}

private struct WatchtowerInboxEntryTray: View {
  let entry: WatchtowerInboxEntry
  let isIgnored: Bool
  let ignore: () -> Void
  let unignore: () -> Void

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
          Text(watchtowerRelativeTime(sentAt))
            .dashTextStyle(.caption)
            .foregroundStyle(DashTheme.subtle)
        }
      }

      // Cloudflare's history carries no link back to the resource, so the
      // reversible ignore toggle is the only action and takes the primary slot.
      DashActionButton(
        title: isIgnored
          ? DashL10n.string("Stop ignoring") : DashL10n.string("Ignore"),
        action: isIgnored ? unignore : ignore
      )
      .accessibilityIdentifier("watchtower-inbox-ignore-toggle")
    }
  }

  private var sourceLine: some View {
    HStack(spacing: 4) {
      SolarIcon(asset: SolarAsset.cloudflare, size: 12, color: DashTheme.brand)
      Text(DashL10n.string("Cloudflare"))
        .dashTextStyle(.captionSemibold)
        .foregroundStyle(DashTheme.subtle)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(DashTheme.recessed, in: Capsule(style: .continuous))
  }
}

/// Delivery ages on the inbox list and in the detail tray. `RelativeDateTimeFormatter`
/// defaults to the SYSTEM locale, so without the pin an inbox translated by
/// Settings → Language still counted the hours in English.
func watchtowerRelativeTime(_ date: Date, relativeTo now: Date = .now) -> String {
  let formatter = RelativeDateTimeFormatter()
  formatter.locale = DashL10n.activeLocale
  return formatter.localizedString(for: date, relativeTo: now)
}
