import CloudflareAPI
import CodeEditor
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct KVNamespacesView: View {
  static let pageSize = 100

  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(RecentResources.key) private var recentsRaw = ""
  @State private var namespaces: [KVNamespace] = []
  @State private var error: String?
  @State private var loading = true
  @State private var isLoadingMore = false
  /// Bumped on every fresh `load` so an in-flight `loadMore` cannot append
  /// onto a list that was just reset / replaced.
  @State private var listGeneration = 0
  @State private var pageState = DashPageState()
  @State private var loadedContext: AccountRequestContext?

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !namespaces.isEmpty,
      empty: DashFeatureEmpty(
        icon: SolarAsset.Content.pinList,
        title: DashL10n.string("No namespaces"),
        message: DashL10n.string(
          "Create namespaces in the Cloudflare dashboard or with Wrangler, then manage keys here."
        ),
        actionTitle: "Open KV docs",
        action: { openURL(StorageExternalURL.kvGuide) }
      ),
      retry: { Task { await load() } }
    ) { mode in
      dashListCard {
        dashModeListRows(mode: mode, items: namespaces, reduceMotion: reduceMotion) {
          namespace in
          // The namespace screen only ever sees the id, so the human title
          // has to enter the recents here, at the navigation boundary.
          DashListGroupLink(
            value: .kvNamespace(namespace.id),
            onNavigate: { recordRecent(namespace) }
          ) {
            DashListRow(title: namespace.title, icon: SolarAsset.Content.pinList)
              .accessibilityLabel(DashL10n.string("\(namespace.title), KV namespace"))
          }
        }
      }
      if !mode.isPlaceholder, pageState.canLoadMore || isLoadingMore {
        DashInfiniteScrollFooter(
          loaded: namespaces.count,
          isLoading: isLoadingMore
        ) {
          // A failed page leaves the list banner up; don't spin the same
          // request until the user retries (pull-to-refresh / Try again).
          guard error == nil else { return }
          Task { await loadMore() }
        }
      }
    }
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) {
      prepareForCurrentAccount()
      await load()
    }
    .onAppear { reloadIfInvalidated() }
  }

  /// The cache drops under this list on memory pressure while it stays alive
  /// below a child screen; refresh on return when the cache went cold.
  private func reloadIfInvalidated() {
    guard let context = loadedContext, model.isCurrentAccount(context), !namespaces.isEmpty
    else { return }
    let cached: [KVNamespace]? = model.featureCache.get(
      FeatureCacheKey.kvNamespaces(context.accountID))
    if cached == nil { Task { await load(force: true) } }
  }

  private func recordRecent(_ namespace: KVNamespace) {
    guard let context = loadedContext, model.isCurrentAccount(context) else { return }
    recentsRaw = RecentResources.recording(
      RecentResource(
        accountID: context.accountID, kind: .kvNamespace, resourceID: namespace.id,
        title: namespace.title),
      in: recentsRaw)
  }

  private func load(force: Bool = false) async {
    guard let context = model.accountRequestContext else { return }
    let key = FeatureCacheKey.kvNamespaces(context.accountID)
    if !force, let cached: [KVNamespace] = model.featureCache.get(key) {
      guard model.isCurrentAccount(context) else { return }
      namespaces = cached
      pageState.rehydrate(loaded: cached.count, pageSize: Self.pageSize)
      loading = false
      error = nil
      return
    }
    // Cold but a stale copy exists on disk: paint it now and refresh in place.
    if namespaces.isEmpty, let stale: [KVNamespace] = model.featureCache.getStale(key) {
      guard model.isCurrentAccount(context) else { return }
      namespaces = stale
      pageState.rehydrate(loaded: stale.count, pageSize: Self.pageSize)
      loading = true
    }
    if namespaces.isEmpty { loading = true }
    isLoadingMore = false
    listGeneration += 1
    let generation = listGeneration
    let client = model.client
    do {
      pageState.reset()
      let page = try await client.listKVNamespaces(
        accountID: context.accountID, page: pageState.nextPage, perPage: Self.pageSize)
      guard !Task.isCancelled, generation == listGeneration, model.isCurrentAccount(context)
      else { return }
      namespaces = page.items
      pageState.absorb(
        info: page.resultInfo, received: page.items.count, loaded: namespaces.count,
        pageSize: Self.pageSize)
      model.featureCache.set(key, namespaces)
      error = nil
    } catch {
      guard !error.dashIsCancellation, generation == listGeneration,
        model.isCurrentAccount(context)
      else { return }
      self.error = error.dashActionableMessage
    }
    if model.isCurrentAccount(context) { loading = false }
  }

  private func loadMore() async {
    guard
      let context = model.accountRequestContext,
      pageState.canLoadMore,
      !isLoadingMore
    else { return }
    let generation = listGeneration
    let pageNumber = pageState.nextPage
    let client = model.client
    isLoadingMore = true
    defer {
      if model.isCurrentAccount(context) {
        isLoadingMore = false
      }
    }
    do {
      let page = try await client.listKVNamespaces(
        accountID: context.accountID, page: pageNumber, perPage: Self.pageSize)
      guard !Task.isCancelled, generation == listGeneration, model.isCurrentAccount(context)
      else { return }
      namespaces += page.items
      pageState.absorb(
        info: page.resultInfo, received: page.items.count, loaded: namespaces.count,
        pageSize: Self.pageSize)
      model.featureCache.set(FeatureCacheKey.kvNamespaces(context.accountID), namespaces)
      error = nil
    } catch {
      guard !error.dashIsCancellation, generation == listGeneration,
        model.isCurrentAccount(context)
      else { return }
      self.error = error.dashActionableMessage
    }
  }

  private func prepareForCurrentAccount() {
    let context = model.accountRequestContext
    guard loadedContext != context else { return }
    loadedContext = context
    namespaces = []
    error = nil
    loading = context != nil
    isLoadingMore = false
    pageState.reset()
    listGeneration += 1
  }
}

struct KVNamespaceView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.openURL) private var openURL
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let namespaceID: String
  @State private var keys: [KVKey] = []
  @State private var cursor: String?
  @State private var showsCreateKey = false
  @State private var selectedKey: KVKey?
  @State private var error: String?
  @State private var loading = true
  @State private var isLoadingMore = false
  @State private var loadedContext: AccountRequestContext?
  @State private var resolvedNamespace: KVNamespace?

  private var canLoadMore: Bool { cursor?.isEmpty == false }
  private var pageActions: [DashPageActionDescriptor] {
    guard featureAllowsWrites else { return [] }
    return [
      .icon(
        id: "kv-namespace-create-key",
        asset: SolarAsset.plus,
        accessibilityLabel: DashL10n.string("Create key")
      ) {
        showsCreateKey = true
      }
    ]
  }

  /// Prefer the cached human title so list → detail morphs keep the same label;
  /// a deep link or relaunch with no list cache resolves the namespace itself
  /// (`resolveNamespaceTitle`) and the late title morphs into the header.
  private var namespaceTitle: String {
    if let accountID = model.activeAccountID,
      let namespaces: [KVNamespace] = model.featureCache.get(
        FeatureCacheKey.kvNamespaces(accountID)),
      let match = namespaces.first(where: { $0.id == namespaceID })
    {
      return match.title
    }
    if let resolved = resolvedNamespace { return resolved.title }
    return "KV keys"
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !keys.isEmpty,
      empty: DashFeatureEmpty(
        icon: SolarAsset.Content.key,
        title: "No keys",
        message: featureAllowsWrites
          ? DashL10n.string("Create a key to store a value in this namespace.")
          : DashL10n.string("Create keys in the Cloudflare dashboard or with Wrangler."),
        actionTitle: featureAllowsWrites
          ? DashL10n.string("Create key") : DashL10n.string("Open KV docs"),
        action: featureAllowsWrites
          ? { showsCreateKey = true } : { openURL(StorageExternalURL.kvGuide) }
      ),
      retry: { Task { await load() } }
    ) { mode in
      dashListCard {
        dashModeListRows(mode: mode, items: keys, reduceMotion: reduceMotion) { key in
          Button {
            selectedKey = key
          } label: {
            DashListRow(
              title: key.name,
              icon: SolarAsset.Content.key,
              showsChevron: false
            )
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityLabel(DashL10n.string("\(key.name), KV key"))
        }
      }
      if !mode.isPlaceholder, canLoadMore || isLoadingMore {
        DashInfiniteScrollFooter(
          loaded: keys.count,
          isLoading: isLoadingMore
        ) {
          guard error == nil else { return }
          Task { await loadMore() }
        }
      }
    }
    .detailHeader(
      icon: .solar(SolarAsset.Content.pinList),
      title: namespaceTitle,
      tint: FeatureVisualIdentity.heroColor(for: .kv)
    )
    .dashPageActions(trailing: pageActions)
    .task(id: model.accountRequestContext) {
      prepareForCurrentAccount()
      await load()
      await resolveNamespaceTitle()
    }
    .refreshable {
      await load(force: true)
      await resolveNamespaceTitle()
    }
    .onAppear { reloadIfKeysInvalidated() }
    // Neutral on purpose: KV's catalog tone is `.warning`, and a toned tray
    // would paint Copy (a reversible read) as an amber/danger submit pill —
    // same reason Email Routing trays stay untoned.
    .dashTray(
      item: $selectedKey,
      title: { $0.name }
    ) { key in
      KVKeyDetailTray(namespaceID: namespaceID, key: key.name) {
        invalidateKeys()
        Task { await load(force: true) }
      }
    }
    .dashTray(
      isPresented: $showsCreateKey, title: DashL10n.string("Create key"),
      tone: FeatureVisualIdentity.tone(for: .kv)
    ) {
      KVCreateKeySheet(namespaceID: namespaceID) {
        invalidateKeys()
        Task { await load(force: true) }
      }
    }
  }

  /// The header title normally rides in on the namespaces list cache; a cold
  /// launch or deep link straight to this screen never fills that list, so
  /// fetch the one namespace when it misses.
  private func resolveNamespaceTitle() async {
    guard let context = model.accountRequestContext else { return }
    if let namespaces: [KVNamespace] = model.featureCache.get(
      FeatureCacheKey.kvNamespaces(context.accountID)),
      namespaces.contains(where: { $0.id == namespaceID })
    {
      return
    }
    let key = FeatureCacheKey.kvNamespace(accountID: context.accountID, namespaceID: namespaceID)
    if let cached: KVNamespace = model.featureCache.get(key) {
      guard model.isCurrentAccount(context) else { return }
      resolvedNamespace = cached
      return
    }
    // Cold but a stale copy exists on disk: paint it now and refresh in place.
    if resolvedNamespace == nil, let stale: KVNamespace = model.featureCache.getStale(key) {
      guard model.isCurrentAccount(context) else { return }
      resolvedNamespace = stale
    }
    let client = model.client
    do {
      let namespace = try await client.getKVNamespace(
        accountID: context.accountID, namespaceID: namespaceID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      resolvedNamespace = namespace
      model.featureCache.set(key, namespace)
    } catch {
      // The keys list owns this screen's error surface; a failed title lookup
      // keeps the generic header label until the next load retries it.
    }
  }

  private func invalidateKeys() {
    guard let context = model.accountRequestContext else { return }
    invalidateKeys(context: context)
  }

  private func invalidateKeys(context: AccountRequestContext) {
    model.featureCache.remove(prefix: "kvKeys:\(context.accountID):\(namespaceID):")
  }

  /// Key detail deletes drop the cache while this list stays alive underneath;
  /// refresh on return when the entry went cold.
  private func reloadIfKeysInvalidated() {
    guard let context = loadedContext, model.isCurrentAccount(context), !keys.isEmpty
    else { return }
    let cached: CursorPageSnapshot<KVKey>? = model.featureCache.get(
      FeatureCacheKey.kvKeys(
        accountID: context.accountID, namespaceID: namespaceID, prefix: ""))
    if cached == nil { Task { await load(force: true) } }
  }

  private func load(force: Bool = false) async {
    guard let context = model.accountRequestContext else { return }
    let key = FeatureCacheKey.kvKeys(
      accountID: context.accountID, namespaceID: namespaceID, prefix: "")
    if !force, let cached: CursorPageSnapshot<KVKey> = model.featureCache.get(key) {
      guard model.isCurrentAccount(context) else { return }
      keys = cached.items
      cursor = cached.cursor
      error = nil
      loading = false
      return
    }
    isLoadingMore = false
    let client = model.client
    do {
      let page = try await client.listKVKeys(
        accountID: context.accountID, namespaceID: namespaceID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      keys = page.items
      cursor = page.cursor
      model.featureCache.set(key, CursorPageSnapshot(items: keys, cursor: cursor))
      error = nil
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
    }
    if model.isCurrentAccount(context) { loading = false }
  }

  private func loadMore() async {
    guard
      let context = model.accountRequestContext,
      canLoadMore,
      !isLoadingMore
    else { return }
    let requestedCursor = cursor
    let client = model.client
    isLoadingMore = true
    defer {
      if model.isCurrentAccount(context) {
        isLoadingMore = false
      }
    }
    do {
      let page = try await client.listKVKeys(
        accountID: context.accountID, namespaceID: namespaceID, cursor: requestedCursor)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      keys += page.items
      cursor = page.cursor
      model.featureCache.set(
        FeatureCacheKey.kvKeys(
          accountID: context.accountID, namespaceID: namespaceID, prefix: ""),
        CursorPageSnapshot(items: keys, cursor: cursor))
      error = nil
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
    }
  }

  private func prepareForCurrentAccount() {
    let context = model.accountRequestContext
    guard loadedContext != context else { return }
    loadedContext = context
    keys = []
    cursor = nil
    error = nil
    loading = context != nil
    isLoadingMore = false
    showsCreateKey = false
    selectedKey = nil
    resolvedNamespace = nil
  }
}

/// Pure validation result shared by both KV editors. Keeping byte-limit
/// decisions here makes the immediate pre-debounce state independently
/// testable from the UI controller.
struct KVJSONValidityDecision: Equatable, Sendable {
  let valueFitsDisplayLimit: Bool
  let valueFitsWriteLimit: Bool
  let canFormat: Bool

  static func limits(for value: String) -> Self {
    let byteCount = value.utf8.count
    return Self(
      valueFitsDisplayLimit: KVJSONFormatting.isWithinDisplayLimit(byteCount: byteCount),
      valueFitsWriteLimit: KVValueLimits.isWithinWriteLimit(byteCount: byteCount),
      canFormat: false
    )
  }

  static func validated(_ value: String) -> Self {
    let limits = limits(for: value)
    guard limits.valueFitsDisplayLimit else { return limits }
    return Self(
      valueFitsDisplayLimit: limits.valueFitsDisplayLimit,
      valueFitsWriteLimit: limits.valueFitsWriteLimit,
      canFormat: KVJSONFormatting.prettyPrintedForDisplay(value) != nil
    )
  }
}

/// Owns the shared 250 ms JSON-validation workflow. SwiftUI's `.task(id:)`
/// supplies cancellation when text changes; the generation guard also rejects
/// an older detached parse if a value cycles back to the same text.
@MainActor
@Observable
final class KVJSONValidityController {
  private(set) var canFormat = false
  private(set) var valueFitsDisplayLimit = true
  private(set) var valueFitsWriteLimit = true
  @ObservationIgnored private var generation: UInt64 = 0

  func reset() {
    generation &+= 1
    canFormat = false
    valueFitsDisplayLimit = true
    valueFitsWriteLimit = true
  }

  func refresh(candidate: String, enabled: Bool = true) async {
    generation &+= 1
    let refreshGeneration = generation
    canFormat = false
    guard enabled else { return }

    let immediate = KVJSONValidityDecision.limits(for: candidate)
    guard canCommit(refreshGeneration) else { return }
    apply(immediate)
    guard immediate.valueFitsDisplayLimit else { return }

    do {
      try await Task.sleep(for: .milliseconds(250))
    } catch {
      return
    }
    let validated = await Task.detached(priority: .userInitiated) {
      KVJSONValidityDecision.validated(candidate)
    }.value
    guard canCommit(refreshGeneration) else { return }
    apply(validated)
  }

  private func canCommit(_ refreshGeneration: UInt64) -> Bool {
    !Task.isCancelled && generation == refreshGeneration
  }

  private func apply(_ decision: KVJSONValidityDecision) {
    canFormat = decision.canFormat
    valueFitsDisplayLimit = decision.valueFitsDisplayLimit
    valueFitsWriteLimit = decision.valueFitsWriteLimit
  }
}

/// Creates a new KV key/value pair in the open namespace.
struct KVCreateKeySheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismissAfter) private var dismissAfter
  let namespaceID: String
  let onCreated: () -> Void
  @State private var keyName = ""
  @State private var value = ""
  @State private var actionPhase: DashActionPhase = .idle
  @State private var error: String?
  @State private var jsonValidity = KVJSONValidityController()

  var body: some View {
    DashFormSheet(
      saveTitle: DashL10n.string("Create key"),
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completeCreatePresentation,
      canSave: !keyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && jsonValidity.valueFitsWriteLimit,
      onSave: { Task { await create() } },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          if let error {
            DashNotice(kind: .error, message: error)
          }
          DashFormField(label: DashL10n.string("Key name"), text: $keyName)
          VStack(alignment: .leading, spacing: 8) {
            Text(DashL10n.string("Value"))
              .dashTextStyle(.footnoteSemibold)
              .foregroundStyle(DashTheme.subtle)
            DashKVCodeEditor(text: $value, editable: actionPhase == .idle)
              .frame(minHeight: 160)
              .clipShape(
                RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
            if !jsonValidity.valueFitsWriteLimit {
              DashNotice(
                kind: .error,
                message: DashL10n.string("KV values can be up to 25 MiB."))
            } else if !jsonValidity.valueFitsDisplayLimit {
              DashNotice(
                kind: .warning,
                message: DashL10n.string(
                  "Values over 256 KiB can be saved, but cannot be viewed or edited in Dash afterward."
                ))
            }
            Button {
              if let pretty = KVJSONFormatting.prettyPrintedForDisplay(value) {
                value = pretty
              }
            } label: {
              Text(DashL10n.string("Format"))
                .dashTextStyle(.buttonMedium)
                .foregroundStyle(jsonValidity.canFormat ? DashTheme.strong : DashTheme.placeholder)
            }
            .buttonStyle(DashPressButtonStyle())
            .disabled(!jsonValidity.canFormat)
            .accessibilityLabel(DashL10n.string("Format"))
          }
        }
        .disabled(actionPhase.isActive)
      }
    )
    .task(id: value) {
      await jsonValidity.refresh(candidate: value)
    }
  }

  private func create() async {
    guard let context = model.accountRequestContext else { return }
    let trimmed = keyName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard KVValueLimits.isWithinWriteLimit(value) else {
      error = DashL10n.string("KV values can be up to 25 MiB.")
      return
    }
    let client = model.client
    let submittedData = Data(value.utf8)
    actionPhase = .loading
    error = nil
    do {
      try await client.putKVValue(
        accountID: context.accountID, namespaceID: namespaceID, key: trimmed,
        data: submittedData)
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        actionPhase = .idle
        return
      }
      model.toasts.success(DashL10n.string("Created successfully"))
      actionPhase = .succeeded
    } catch {
      actionPhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
    }
  }

  private func completeCreatePresentation() {
    guard actionPhase == .succeeded else {
      actionPhase = .idle
      return
    }
    dismissAfter(onCreated)
  }
}

private func kvDisplayIssueMessage(_ issue: KVJSONFormatting.DisplayValue) -> String {
  switch issue {
  case .tooLarge:
    DashL10n.string(
      "This value exceeds Dash's 256 KiB viewer and editor limit. You can still copy or delete it."
    )
  case .nonText:
    DashL10n.string(
      "This value is not UTF-8 text, so it cannot be viewed or edited. You can still copy or delete it."
    )
  case .text:
    ""
  }
}

@MainActor
private func copyKVValue(_ value: String, rawValueData: Data?) {
  guard let rawValueData else {
    UIPasteboard.general.string = value
    return
  }
  if let text = String(data: rawValueData, encoding: .utf8) {
    UIPasteboard.general.string = text
  } else {
    UIPasteboard.general.setData(rawValueData, forPasteboardType: UTType.data.identifier)
  }
}

/// List → tray peek for a KV key: value fields, Copy as the primary verb,
/// optional Edit (pushes the full editor) and header Delete.
private struct KVKeyDetailTray: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.dashTrayDismiss) private var dismiss
  @Environment(\.dashTrayDismissAfter) private var dismissAfter
  let namespaceID: String
  let key: String
  var onDeleted: () -> Void

  @State private var value = ""
  @State private var rawValueData: Data?
  @State private var displayIssue: KVJSONFormatting.DisplayValue?
  @State private var loaded = false
  @State private var loadError: String?
  @State private var deletePhase: DashActionPhase = .idle
  @State private var deleteError: String?
  @State private var loadedContext: AccountRequestContext?

  private var fields: [DashDetailField] {
    var rows = [DashDetailField(label: "Key", value: key, mono: true)]
    if let displayIssue {
      rows.append(DashDetailField(label: "Value", value: kvDisplayIssueMessage(displayIssue)))
    } else if loaded {
      rows.append(DashDetailField(label: "Value", value: value, mono: true))
    } else if loadError == nil {
      rows.append(DashDetailField(label: "Value", value: DashL10n.string("Loading")))
    }
    return rows
  }

  private var canEdit: Bool {
    featureAllowsWrites && loaded && displayIssue == nil
  }

  var body: some View {
    Group {
      if let loadError, !loaded {
        VStack(alignment: .leading, spacing: 14) {
          DashNotice(kind: .error, message: loadError)
          DashTrayPillButton(title: "Try again") {
            Task { await load() }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        DashDetailTray(
          fields: fields,
          deleteMessage: featureAllowsWrites && loaded
            ? DashL10n.string("Permanently delete the key \(key).")
            : nil,
          deletePhase: deletePhase,
          onDeleteSuccessPresentationCompleted: completeDeletePresentation,
          deleteError: deleteError,
          onDelete: featureAllowsWrites && loaded
            ? { Task { await deleteKey() } }
            : nil
        ) {
          if loaded {
            VStack(spacing: 10) {
              if canEdit {
                DashNavigationSource(
                  destination: .kvKey(namespaceID: namespaceID, key: key),
                  schedule: dismissAfter
                ) { navigate in
                  DashTrayPillButton(title: "Edit", action: navigate)
                }
              }
              DashActionButton(title: "Copy") {
                copyKVValue(value, rawValueData: rawValueData)
                model.toasts.success(DashL10n.string("Value copied"))
              }
            }
          }
        }
      }
    }
    .task(id: model.accountRequestContext) {
      prepareForCurrentAccount()
      await load()
    }
  }

  private func prepareForCurrentAccount() {
    let context = model.accountRequestContext
    guard loadedContext != context else { return }
    loadedContext = context
    value = ""
    rawValueData = nil
    displayIssue = nil
    loaded = false
    loadError = nil
    deletePhase = .idle
    deleteError = nil
  }

  private func load() async {
    guard let context = model.accountRequestContext else { return }
    loadError = nil
    let client = model.client
    do {
      let data = try await client.getKVValue(
        accountID: context.accountID, namespaceID: namespaceID, key: key)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      switch KVJSONFormatting.displayValue(for: data) {
      case .text(let prepared):
        value = prepared
        displayIssue = nil
        rawValueData = nil
      case .tooLarge:
        value = ""
        displayIssue = .tooLarge
        rawValueData = data
      case .nonText:
        value = ""
        displayIssue = .nonText
        rawValueData = data
      }
      loaded = true
      loadError = nil
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      loaded = false
      loadError = error.dashActionableMessage
    }
  }

  private func deleteKey() async {
    guard featureAllowsWrites, let context = model.accountRequestContext,
      loadedContext == context
    else { return }
    deletePhase = .loading
    deleteError = nil
    do {
      try await model.client.deleteKVValue(
        accountID: context.accountID, namespaceID: namespaceID, key: key)
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        deletePhase = .idle
        return
      }
      model.featureCache.remove(prefix: "kvKeys:\(context.accountID):\(namespaceID):")
      model.toasts.success(DashL10n.string("Deleted successfully"))
      deletePhase = .succeeded
    } catch {
      deletePhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      deleteError = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func completeDeletePresentation() {
    guard deletePhase == .succeeded else { return }
    dismiss()
    onDeleted()
  }
}

/// Full-screen KV key detail: view-first CodeEditor, edit on demand.
struct KVKeyDetailView: View {
  private enum Mode {
    case viewing
    case editing
  }

  @Environment(AppModel.self) private var model
  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.dashNavigationEntryID) private var navigationEntryID
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.featureRequiredScopes) private var featureRequiredScopes
  let namespaceID: String
  let key: String

  @State private var mode: Mode = .viewing
  @State private var value = ""
  @State private var committedValue = ""
  @State private var error: String?
  @State private var loaded = false
  @State private var saving = false
  @State private var deleting = false
  @State private var actionPhase: DashActionPhase = .idle
  @State private var confirmingDelete = false
  @State private var copied = false
  @State private var loadedContext: AccountRequestContext?
  @State private var jsonValidity = KVJSONValidityController()
  @State private var displayIssue: KVJSONFormatting.DisplayValue?
  @State private var rawValueData: Data?

  private var pageActions: [DashPageActionDescriptor] {
    guard featureAllowsWrites, mode == .viewing, loaded, ownsCurrentAccount,
      !confirmingDelete
    else { return [] }
    return [
      .icon(
        id: "kv-key-delete",
        asset: SolarAsset.trash,
        accessibilityLabel: DashL10n.string("Delete")
      ) {
        withAnimation(DashTheme.Motion.morph) { confirmingDelete = true }
      }
    ]
  }

  var body: some View {
    GeometryReader { geo in
      DashConfirmMorph(
        confirming: $confirmingDelete,
        message: DashL10n.string("Permanently delete the key \(key)."),
        actionPhase: actionPhase,
        onSuccessPresentationCompleted: completeActionPresentation,
        actionTitle: footerTitle,
        confirmingActionTitle: "Delete",
        confirmingActionRole: .destructive,
        actionEnabled: footerEnabled,
        errorMessage: confirmingDelete ? error : nil,
        action: { primaryAction() },
        headerDelete: false,
        content: {
          VStack(alignment: .leading, spacing: 14) {
            Group {
              if loaded, let displayIssue {
                DashNotice(
                  kind: .warning,
                  title: DashL10n.string("Value unavailable"),
                  message: kvDisplayIssueMessage(displayIssue)
                )
              } else if loaded {
                DashKVCodeEditor(text: $value, editable: mode == .editing && !saving)
                  .frame(maxWidth: .infinity)
                  .frame(height: editorHeight(in: geo))
                  .clipShape(
                    RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
                if mode == .editing {
                  if !jsonValidity.valueFitsWriteLimit {
                    DashNotice(
                      kind: .error,
                      message: DashL10n.string("KV values can be up to 25 MiB."))
                  } else if !jsonValidity.valueFitsDisplayLimit {
                    DashNotice(
                      kind: .warning,
                      message: DashL10n.string(
                        "Values over 256 KiB can be saved, but cannot be viewed or edited in Dash afterward."
                      ))
                  }
                }
              } else if let error {
                // Cold failure keeps the editor-shaped placeholder on the
                // ground and lands the message on the wash over it — the value
                // is this screen's primary payload, so it gets the cold-list
                // contract, not a swapped-in notice.
                editorSkeleton(height: editorHeight(in: geo))
                  .dashColdFailure(
                    message: DashFailurePresentation.from(message: error).message,
                    actionTitle: DashFailurePresentation.from(message: error).action.title,
                    extent: .skeleton,
                    action: recoverFromLoadFailure
                  )
                  .dashFailureRemovalTransition()
              } else {
                // Cold load paints the shape the value lands on, not a bare
                // ring — the editor arrives without a layout shift, and a
                // failure has something to veil over.
                editorSkeleton(height: editorHeight(in: geo))
                  .accessibilityElement(children: .ignore)
                  .accessibilityLabel(DashL10n.string("Loading"))
              }
            }

            // Load failures render on the cold veil above; this notice belongs
            // to the save/format/delete operations of a loaded value.
            if let error, loaded, !confirmingDelete {
              DashNotice(kind: .error, message: error)
            }

            if loaded {
              accessoryRow
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .disabled(saving || deleting)
        }
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, DashTheme.Spacing.screen)
    .padding(.bottom, 12)
    .detailHeader(
      icon: .solar(SolarAsset.Content.key),
      title: key,
      tint: FeatureVisualIdentity.heroColor(for: .kv)
    )
    .dashPageActions(trailing: pageActions)
    .dashKeyboardDismissal()
    .task(id: model.accountRequestContext) {
      prepareForCurrentAccount()
      await load()
    }
    .task(id: value) {
      await jsonValidity.refresh(candidate: value, enabled: displayIssue == nil)
    }
  }

  @ViewBuilder private var accessoryRow: some View {
    switch mode {
    case .viewing:
      DashSecondaryPillButton(
        title: copied ? DashL10n.string("Copied") : DashL10n.string("Copy")
      ) {
        copyKVValue(value, rawValueData: rawValueData)
        withAnimation(DashTheme.Motion.morph) { copied = true }
        Task {
          try? await Task.sleep(for: .seconds(1.6))
          withAnimation(DashTheme.Motion.morph) { copied = false }
        }
      }
      .accessibilityLabel(copied ? DashL10n.string("Copied") : DashL10n.string("Copy"))
    case .editing:
      HStack(spacing: 10) {
        Button {
          withAnimation(DashTheme.Motion.morph) {
            value = committedValue
            mode = .viewing
            error = nil
          }
        } label: {
          Text(DashL10n.string("Cancel"))
            .dashTextStyle(.buttonMedium)
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel(DashL10n.string("Cancel"))

        Button {
          if let pretty = KVJSONFormatting.prettyPrintedForDisplay(value) {
            value = pretty
          }
        } label: {
          Text(DashL10n.string("Format"))
            .dashTextStyle(.buttonMedium)
            .foregroundStyle(jsonValidity.canFormat ? DashTheme.strong : DashTheme.placeholder)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(DashPressButtonStyle())
        .disabled(!jsonValidity.canFormat)
        .accessibilityLabel(DashL10n.string("Format"))
      }
    }
  }

  private var footerTitle: String? {
    if confirmingDelete { return "Delete" }
    switch mode {
    case .viewing:
      return featureAllowsWrites && loaded && displayIssue == nil
        ? DashL10n.string("Edit")
        : nil
    case .editing:
      return DashL10n.string("Save")
    }
  }

  private var footerEnabled: Bool {
    if confirmingDelete { return ownsCurrentAccount }
    switch mode {
    case .viewing:
      return featureAllowsWrites && loaded && displayIssue == nil && ownsCurrentAccount
    case .editing:
      return loaded && jsonValidity.valueFitsWriteLimit && ownsCurrentAccount
    }
  }

  private var ownsCurrentAccount: Bool {
    guard let loadedContext else { return false }
    return model.isCurrentAccount(loadedContext)
  }

  private func primaryAction() {
    if confirmingDelete {
      Task { await deleteKey() }
      return
    }
    switch mode {
    case .viewing:
      withAnimation(DashTheme.Motion.morph) { mode = .editing }
    case .editing:
      Task { await save() }
    }
  }

  private func invalidateKeys(context: AccountRequestContext) {
    model.featureCache.remove(prefix: "kvKeys:\(context.accountID):\(namespaceID):")
  }

  /// The editor's height formula, shared with the cold placeholder so the
  /// arriving value lands exactly where the skeleton stood.
  private func editorHeight(in geo: GeometryProxy) -> CGFloat {
    max(280, geo.size.height - 220)
  }

  /// The shape the value lands on: the editor's recessed frame with a few
  /// code-line bars, matching the app's skeleton language (`DashListSkeleton`).
  private func editorSkeleton(height: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous)
      .fill(DashTheme.recessed)
      .frame(maxWidth: .infinity)
      .frame(height: height)
      .overlay(alignment: .topLeading) {
        let widths: [CGFloat] = [168, 220, 132, 200, 96]
        VStack(alignment: .leading, spacing: 12) {
          ForEach(0..<5, id: \.self) { index in
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .dashSkeletonFill(index == 0 ? DashSkeletonStyle.strong : DashSkeletonStyle.soft)
              .frame(width: widths[index], height: 11)
          }
        }
        .padding(16)
      }
  }

  private func recoverFromLoadFailure() {
    switch DashFailurePresentation.from(message: error ?? "").action {
    case .signInAgain:
      Task { await model.signOut() }
    case .grantAccess:
      model.requestAccess(
        to: featureRequiredScopes.isEmpty
          ? DashAuthorizationScopes.initialReadOnly : featureRequiredScopes)
    case .tryAgain:
      withAnimation(DashTheme.Motion.content) { error = nil }
      Task { await load() }
    }
  }

  private func load() async {
    guard let context = model.accountRequestContext else { return }
    let client = model.client
    do {
      let data = try await client.getKVValue(
        accountID: context.accountID, namespaceID: namespaceID, key: key)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      switch KVJSONFormatting.displayValue(for: data) {
      case .text(let prepared):
        value = prepared
        committedValue = prepared
        displayIssue = nil
        rawValueData = nil
      case .tooLarge:
        value = ""
        committedValue = ""
        displayIssue = .tooLarge
        rawValueData = data
      case .nonText:
        value = ""
        committedValue = ""
        displayIssue = .nonText
        rawValueData = data
      }
      loaded = true
      error = nil
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
    }
  }

  private func save() async {
    guard featureAllowsWrites, let context = model.accountRequestContext,
      loadedContext == context
    else { return }
    guard KVValueLimits.isWithinWriteLimit(value) else {
      error = DashL10n.string("KV values can be up to 25 MiB.")
      return
    }
    let client = model.client
    let submittedValue = value
    let submittedData = Data(submittedValue.utf8)
    saving = true
    actionPhase = .loading
    error = nil
    do {
      try await client.putKVValue(
        accountID: context.accountID, namespaceID: namespaceID, key: key,
        data: submittedData)
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        saving = false
        actionPhase = .idle
        return
      }
      if KVJSONFormatting.isWithinDisplayLimit(byteCount: submittedData.count) {
        committedValue = submittedValue
        value = submittedValue
        displayIssue = nil
        rawValueData = nil
      } else {
        committedValue = ""
        value = ""
        displayIssue = .tooLarge
        rawValueData = submittedData
      }
      invalidateKeys(context: context)
      model.toasts.success(DashL10n.string("Saved successfully"))
      actionPhase = .succeeded
    } catch {
      saving = false
      actionPhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
    }
  }

  private func deleteKey() async {
    guard featureAllowsWrites, let context = model.accountRequestContext,
      loadedContext == context
    else { return }
    let client = model.client
    deleting = true
    actionPhase = .loading
    error = nil
    do {
      try await client.deleteKVValue(
        accountID: context.accountID, namespaceID: namespaceID, key: key)
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        deleting = false
        actionPhase = .idle
        return
      }
      invalidateKeys(context: context)
      model.toasts.success(DashL10n.string("Deleted successfully"))
      actionPhase = .succeeded
    } catch {
      deleting = false
      actionPhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
    }
  }

  private func completeActionPresentation() {
    guard actionPhase == .succeeded else {
      saving = false
      deleting = false
      actionPhase = .idle
      return
    }
    if deleting {
      deleting = false
      actionPhase = .idle
      guard let navigationEntryID else { return }
      navigator?.dismiss(entryID: navigationEntryID)
    } else {
      saving = false
      actionPhase = .idle
      withAnimation(DashTheme.Motion.morph) { mode = .viewing }
    }
  }

  private func prepareForCurrentAccount() {
    let context = model.accountRequestContext
    guard loadedContext != context else { return }
    loadedContext = context
    mode = .viewing
    value = ""
    committedValue = ""
    error = nil
    loaded = false
    saving = false
    deleting = false
    actionPhase = .idle
    confirmingDelete = false
    copied = false
    jsonValidity.reset()
    displayIssue = nil
    rawValueData = nil
  }
}

/// Shared CodeEditor surface for KV preview and edit (same library both ways).
private struct DashKVCodeEditor: View {
  @Binding var text: String
  var editable: Bool
  @Environment(\.colorScheme) private var colorScheme

  private var theme: CodeEditor.ThemeName {
    colorScheme == .dark ? .atelierSavannaDark : .atelierSavannaLight
  }

  var body: some View {
    Group {
      if editable {
        CodeEditor(
          source: $text,
          language: .json,
          theme: theme,
          flags: .defaultEditorFlags,
          indentStyle: .softTab(width: 2)
        )
      } else {
        CodeEditor(
          source: text,
          language: .json,
          theme: theme,
          flags: .defaultViewerFlags
        )
      }
    }
    .background(DashTheme.recessed)
  }
}
