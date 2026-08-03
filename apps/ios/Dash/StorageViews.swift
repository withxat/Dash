import CloudflareAPI
import CodeEditor
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct R2BucketsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.openURL) private var openURL
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var buckets: [R2Bucket] = []
  @State private var error: String?
  @State private var loading = true
  @State private var showsCreateBucket = false

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !buckets.isEmpty,
      empty: DashFeatureEmpty(
        icon: SolarAsset.Content.box,
        title: DashL10n.string("No buckets yet"),
        message: featureAllowsWrites
          ? DashL10n.string("Create a bucket to store objects in R2.")
          : DashL10n.string("Create buckets in the Cloudflare dashboard or with Wrangler."),
        actionTitle: featureAllowsWrites
          ? DashL10n.string("Create bucket")
          : DashL10n.string("Open R2 docs"),
        action: featureAllowsWrites
          ? { showsCreateBucket = true }
          : { openURL(StorageExternalURL.r2BucketsGuide) }
      ),
      retry: { Task { await load() } }
    ) { mode in
      dashListCard {
        dashModeListRows(mode: mode, items: buckets, reduceMotion: reduceMotion) { bucket in
          DashListGroupLink(value: .r2Bucket(bucket.name, prefix: "")) {
            DashListRow(
              title: bucket.name,
              subtitle: r2BucketCreationText(bucket.creationDate),
              icon: SolarAsset.Content.box
            )
            .accessibilityLabel(r2BucketAccessibilityLabel(bucket))
          }
        }
      }
    }
    .refreshable { await load(force: true) }
    .task { await load() }
    .onAppear { reloadIfInvalidated() }
    .dashTray(isPresented: $showsCreateBucket, title: DashL10n.string("Create bucket")) {
      R2CreateBucketSheet {
        guard let id = model.activeAccountID else { return }
        model.featureCache.remove(FeatureCacheKey.r2Buckets(id))
        Task { await load(force: true) }
      }
    }
  }

  /// The cache drops under this list on memory pressure while it stays alive
  /// below a child screen; refresh on return when the cache went cold.
  private func reloadIfInvalidated() {
    guard let id = model.activeAccountID, !buckets.isEmpty else { return }
    let cached: [R2Bucket]? = model.featureCache.get(FeatureCacheKey.r2Buckets(id))
    if cached == nil { Task { await load(force: true) } }
  }
  private func load(force: Bool = false) async {
    guard let id = model.activeAccountID else { return }
    let key = FeatureCacheKey.r2Buckets(id)
    if !force, let cached: [R2Bucket] = model.featureCache.get(key) {
      buckets = cached
      loading = false
      error = nil
      return
    }
    // Cold but a stale copy exists on disk: paint it now and refresh in place.
    if buckets.isEmpty, let stale: [R2Bucket] = model.featureCache.getStale(key) {
      buckets = stale
      loading = true
    }
    if buckets.isEmpty { loading = true }
    do {
      buckets = try await model.client.listR2Buckets(accountID: id)
      model.featureCache.set(key, buckets)
      error = nil
    } catch { self.error = error.dashActionableMessage }
    loading = false
  }
}

/// Everything that makes one mounted R2 browser request account-specific.
/// The generation changes even when an account is signed out and back into,
/// so a surviving NavigationStack destination cannot commit an older result.
struct R2BucketRequestIdentity: Hashable, Sendable {
  let context: AccountRequestContext?
  let bucket: String
  let folderPrefix: String
}

private enum R2BucketActionsStep: Hashable, Sendable {
  case menu
  case createFolder
  case deleteFolder

  var trayRole: DashTrayStepRole {
    self == .menu ? .root : .detail
  }

  var title: String {
    switch self {
    case .menu: "Actions"
    case .createFolder: "Create folder"
    case .deleteFolder: "Delete folder"
    }
  }
}

struct R2BucketView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.destinationNavigator) private var navigator
  @AppStorage(RecentResources.key) private var recentsRaw = ""
  let bucket: String
  /// S3-style folder key for this screen (trailing `/`), or `""` at the bucket root.
  /// Folder hops push another `Destination.r2Bucket` — the nav back button is the
  /// only "up" control (no in-list parent row).
  let folderPrefix: String
  @State private var objects: [R2Object] = []
  @State private var folders: [String] = []
  @State private var cursor: String?
  @State private var error: String?
  @State private var loading = true
  @State private var loadMorePhase: DashActionPhase = .idle
  @State private var importsFile = false
  @State private var selectedObject: R2Object?
  /// Survives folder/settings pushes (view merely disappears). Cancels in
  /// `deinit` when this screen leaves the navigation stack for good.
  @State private var work = R2BucketWork()
  @State private var uploadingFileName: String?
  @State private var selecting = false
  @State private var selectedKeys: Set<String> = []
  @State private var confirmsBatchDelete = false
  @State private var showsBucketActions = false
  /// Steps of the Actions tray. A second `dashTray` on this screen would have to
  /// present while the first is still animating out, so the create form and the
  /// folder-delete confirmation morph inside the tray that is already open.
  @State private var bucketActionsStep = R2BucketActionsStep.menu
  /// Whether this prefix has its own zero-byte `…/` marker object. It is the
  /// only thing "delete this empty folder" can remove — a folder that exists
  /// purely because objects sit under it disappears on its own once they go.
  @State private var hasFolderMarker = false
  /// The account/bucket/prefix currently represented by the state above.
  /// This survives view-value updates so stale async tasks can be rejected.
  @State private var displayedRequestIdentity: R2BucketRequestIdentity?
  /// Public-exposure snapshot for Copy-URL actions; loaded lazily and shared
  /// with the settings screen through the feature cache.
  @State private var domains: R2DomainsSnapshot?
  /// Collapses the `.task` and `onAppear` retry paths into one fetch — both
  /// fire on first mount, and `domains == nil` alone would let them race.
  @State private var domainsLoadInFlight = false
  /// Reference storage keeps scroll-driven geometry outside SwiftUI's
  /// observation graph. Only the two-finger recognizer reads it.
  @State private var objectFrameStore = R2ObjectFrameStore()
  /// Once a two-finger pan starts, keep adding or removing based on the first
  /// row under the fingers (UITableView multiselect behavior).
  @State private var paintAdds: Bool?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var canLoadMore: Bool { cursor?.isEmpty == false }
  /// Deleting a folder here removes exactly one zero-byte marker, so it is
  /// offered only once the listing proves there is nothing else under the
  /// prefix. No recursive delete hides behind this.
  private var canDeleteFolder: Bool {
    featureAllowsWrites && !folderPrefix.isEmpty && hasFolderMarker
      && folders.isEmpty && objects.isEmpty && !canLoadMore && !loading && error == nil
  }
  private var tracksObjectFrames: Bool {
    featureAllowsWrites && !objects.isEmpty
  }
  private var currentDestination: Destination {
    .r2Bucket(bucket, prefix: folderPrefix)
  }
  private var requestIdentity: R2BucketRequestIdentity {
    R2BucketRequestIdentity(
      context: model.accountRequestContext,
      bucket: bucket,
      folderPrefix: folderPrefix)
  }
  private var currentFolderName: String {
    guard !folderPrefix.isEmpty else { return bucket }
    return folderPrefix.dropLast().split(separator: "/").last.map(String.init) ?? bucket
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      // An in-flight upload keeps the content phase so its progress card is not
      // buried under the empty wash.
      hasContent: !objects.isEmpty || !folders.isEmpty || uploadingFileName != nil,
      empty: DashFeatureEmpty(
        icon: folderPrefix.isEmpty ? SolarAsset.Content.box : SolarAsset.Content.folder,
        title: folderPrefix.isEmpty ? "Empty bucket" : "Empty folder",
        message: folderPrefix.isEmpty
          ? (featureAllowsWrites
            ? DashL10n.string("Upload a file to get started.")
            : DashL10n.string("This bucket has no objects."))
          : (featureAllowsWrites
            ? DashL10n.string("Upload a file into this folder.")
            : DashL10n.string("This virtual folder has no objects.")),
        actionTitle: featureAllowsWrites ? DashL10n.string("Upload file") : nil,
        action: featureAllowsWrites ? { importsFile = true } : nil
      ),
      retry: {
        let request = requestIdentity
        Task { await load(for: request) }
      }
    ) { mode in
      if !mode.isPlaceholder, let uploadingFileName {
        DashSurfaceStack {
          uploadProgressCard(uploadingFileName)
        }
        .padding(.bottom, DashTheme.Spacing.itemGap)
      }
      // Folders and objects are sibling LazyVStack children — never one
      // dashListCard wrapping both. A shared card would make Content a
      // TupleView, and `.dashListCardInset()` on that tuple re-eagerizes
      // every object row (thumbnail stampede).
      if !mode.isPlaceholder {
        ForEach(folders, id: \.self) { folder in
          DashListGroupLink(value: .r2Bucket(bucket, prefix: folder)) {
            DashListRow(
              title: folderName(folder),
              icon: SolarAsset.Content.folder
            )
          }
          .dashListCardInset()
          .dashBodySlot(reduceMotion: reduceMotion)
        }
      }
      if mode.isPlaceholder || !objects.isEmpty {
        dashListCard {
          dashModeListRows(mode: mode, items: objects, reduceMotion: reduceMotion) { object in
            R2ObjectRow(
              bucket: bucket,
              object: object,
              title: objectName(object.key),
              selecting: selecting,
              selected: selectedKeys.contains(object.key)
            ) {
              if selecting {
                toggleSelection(object)
              } else {
                selectedObject = object
              }
            }
            .background {
              if tracksObjectFrames {
                GeometryReader { geo in
                  Color.clear.preference(
                    key: R2ObjectFrameKey.self,
                    value: [object.key: geo.frame(in: .global)]
                  )
                }
              }
            }
          }
        }
      }
      if !mode.isPlaceholder, canLoadMore || loadMorePhase.isActive {
        DashLoadMoreFooter(
          loaded: folders.count + objects.count,
          noun: "items",
          phase: loadMorePhase,
          onSuccessPresentationCompleted: { loadMorePhase = .idle }
        ) {
          Task { await loadMore() }
        }
      }
    }
    .detailHeader(
      icon: .solar(folderPrefix.isEmpty ? SolarAsset.Content.box : SolarAsset.Content.folder),
      title: currentFolderName,
      tint: FeatureVisualIdentity.heroColor(for: .r2)
    )
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        DashToolbarActionGroup {
          if selecting {
            DashToolbarIconButton(
              asset: SolarAsset.close,
              accessibilityLabel: DashL10n.string("Done selecting")
            ) {
              withAnimation(DashTheme.Motion.morph) {
                selecting = false
                selectedKeys = []
              }
            }
          } else {
            // Stable trailing chrome: Upload (writes) + More. Select and
            // settings live in More so load completion never inserts a third
            // button and shoves the principal title left.
            if featureAllowsWrites {
              DashToolbarIconButton(
                asset: SolarAsset.upload, accessibilityLabel: DashL10n.string("Upload file")
              ) {
                importsFile = true
              }
              .disabled(work.upload != nil)
              .opacity(work.upload == nil ? 1 : 0.45)
            }
            DashMoreButton(isPresented: $showsBucketActions)
          }
        }
      }
      .dashSeparateToolbarBackground()
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if selecting {
        selectionBar
      }
    }
    .background {
      R2TwoFingerSelectInstaller(
        isEnabled: featureAllowsWrites && !objects.isEmpty,
        onBegan: beginTwoFingerSelect,
        onPaintAt: paintTwoFingerSelect,
        onEnded: { paintAdds = nil }
      )
    }
    .onPreferenceChange(R2ObjectFrameKey.self) { objectFrameStore.replace(with: $0) }
    .onChange(of: tracksObjectFrames) { _, enabled in
      if !enabled { objectFrameStore.clear() }
    }
    .fileImporter(isPresented: $importsFile, allowedContentTypes: [.data]) { result in
      if case .success(let url) = result { beginUpload(url) }
    }
    .refreshable {
      let request = requestIdentity
      await load(force: true, for: request)
    }
    .task(id: requestIdentity) {
      let request = requestIdentity
      prepareForRequest(request)
      guard request.context != nil else { return }
      recordRecentBucket(for: request)
      async let objectLoad: Void = load(for: request)
      async let domainLoad: Void = loadDomains(for: request)
      _ = await (objectLoad, domainLoad)
    }
    .fullScreenCover(item: $selectedObject) { object in
      R2ObjectPreview(
        bucket: bucket,
        object: object,
        publicURL: domains?.publicURL(forKey: object.key),
        allowsWrites: featureAllowsWrites,
        onDeleted: {
          // Owner of the preview cover: close it, then reload the listing —
          // the object it showed was just deleted.
          selectedObject = nil
          await invalidateAndReload()
        }
      )
    }
    .dashMoreMenu(
      isPresented: $confirmsBatchDelete,
      title: "Delete objects",
      actions: [batchDeleteAction]
    )
    .dashTray(isPresented: $showsBucketActions, title: "Actions") {
      r2BucketActionsTray
    }
    // `isPresented` flips only after the tray's exit animation, so resetting the
    // step here never morphs the content back while it is still on screen.
    .onChange(of: showsBucketActions) { _, presented in
      guard !presented else { return }
      bucketActionsStep = .menu
    }
    // Settings may have changed the domains while this screen stayed mounted
    // below it — resync from the shared cache on return. A visit that finds
    // nothing (the last lookup failed and left `domains` nil) retries the
    // fetch instead: the `.task` identity hasn't changed, so this is the only
    // retry that screen re-entry can provide.
    .onAppear {
      refreshDomainsFromCache()
      if domains == nil {
        let request = requestIdentity
        Task { await loadDomains(for: request) }
      }
      reloadIfInvalidated()
    }
    .onChange(of: navigator?.path) { _, path in
      if path?.contains(currentDestination) != true {
        cancelOutstandingWork()
      }
    }
    .onChange(of: model.accountRequestContext) { _, newContext in
      prepareForRequest(
        R2BucketRequestIdentity(
          context: newContext,
          bucket: bucket,
          folderPrefix: folderPrefix))
    }
    .onDisappear {
      // Folder/settings pushes keep this destination in the path. A pop does
      // not, so release Task references immediately instead of waiting for
      // SwiftUI to destroy a self-retaining view/task cycle.
      if navigator?.path.contains(currentDestination) != true {
        cancelOutstandingWork()
      }
    }
  }

  private func cancelOutstandingWork() {
    work.cancelAndRelease()
    uploadingFileName = nil
  }

  /// Synchronously drops every account-scoped value before a new request can
  /// paint. The request task then reloads the listing and domain snapshot.
  private func prepareForRequest(_ request: R2BucketRequestIdentity) {
    guard displayedRequestIdentity != request else { return }
    cancelOutstandingWork()
    objects = []
    folders = []
    cursor = nil
    error = nil
    loading = request.context != nil
    loadMorePhase = .idle
    importsFile = false
    selectedObject = nil
    selecting = false
    selectedKeys = []
    confirmsBatchDelete = false
    showsBucketActions = false
    bucketActionsStep = .menu
    hasFolderMarker = false
    domains = nil
    objectFrameStore.clear()
    paintAdds = nil
    displayedRequestIdentity = request
  }

  private func matchesCurrentRequest(_ request: R2BucketRequestIdentity) -> Bool {
    guard
      displayedRequestIdentity == request,
      requestIdentity == request,
      let context = request.context
    else { return false }
    return model.isCurrentAccount(context)
  }

  private func canCommit(_ request: R2BucketRequestIdentity) -> Bool {
    !Task.isCancelled && matchesCurrentRequest(request)
  }

  private func recordRecentBucket(for request: R2BucketRequestIdentity) {
    guard let context = request.context, matchesCurrentRequest(request) else { return }
    recentsRaw = RecentResources.recording(
      RecentResource(
        accountID: context.accountID,
        kind: .r2Bucket,
        resourceID: bucket,
        title: bucket),
      in: recentsRaw)
  }

  private var selectionBar: some View {
    Button {
      confirmsBatchDelete = true
    } label: {
      Text(
        selectedKeys.isEmpty
          ? DashL10n.string("Delete") : DashL10n.string("Delete \(selectedKeys.count)")
      )
      .dashTextStyle(.button)
      .foregroundStyle(DashTheme.inverse)
      .frame(maxWidth: .infinity)
      .frame(height: DashTheme.Layout.actionPillHeight)
      .background(DashTheme.danger, in: DashTheme.pillShape)
    }
    .buttonStyle(DashPressButtonStyle())
    .disabled(selectedKeys.isEmpty)
    .opacity(selectedKeys.isEmpty ? 0.45 : 1)
    .padding(.horizontal, DashTheme.Spacing.screen)
    .padding(.vertical, 10)
    .background(DashTheme.canvas)
  }

  /// One tray, three steps: the action menu, the create-folder form, and the
  /// folder-delete confirmation. Each step transitions in place, the way
  /// `AddDomainSheet` morphs its form into the name-server step.
  @ViewBuilder private var r2BucketActionsTray: some View {
    DashTrayFlow(route: bucketActionsStep, role: bucketActionsStep.trayRole) { step in
      switch step {
      case .createFolder:
        R2CreateFolderSheet(
          bucket: bucket,
          folderPrefix: folderPrefix,
          siblingFolders: folders,
          siblingObjectKeys: objects.map(\.key),
          onCreated: { await invalidateAndReload() }
        )
      case .deleteFolder:
        DashConfirmableActions(actions: [deleteFolderAction])
      case .menu:
        r2BucketActionsMenu
      }
    }
    .dashTrayTitle(bucketActionsStep.title)
  }

  @ViewBuilder private var r2BucketActionsMenu: some View {
    dashListCard {
      if featureAllowsWrites {
        Button {
          bucketActionsStep = .createFolder
        } label: {
          DashListRow(
            title: DashL10n.string("Create folder"),
            subtitle: DashL10n.string("Groups objects under a key prefix"),
            icon: SolarAsset.Content.folder,
            showsChevron: false,
            showsIconPlate: false
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityLabel(
          DashL10n.string("Create folder, Groups objects under a key prefix")
        )
        .dashListCardInset()

        DashListGroupDivider()

        Button {
          showsBucketActions = false
          withAnimation(DashTheme.Motion.morph) {
            selecting = true
            selectedKeys = []
          }
        } label: {
          DashListRow(
            title: DashL10n.string("Select objects"),
            subtitle: objects.isEmpty
              ? DashL10n.string("Nothing to select in this folder")
              : DashL10n.string("Or drag with two fingers on the list"),
            icon: SolarAsset.checkCircle,
            showsChevron: false,
            showsIconPlate: false
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityLabel(
          objects.isEmpty
            ? DashL10n.string("Select objects, Nothing to select in this folder")
            : DashL10n.string("Select objects, Or drag with two fingers on the list")
        )
        .disabled(objects.isEmpty)
        .opacity(objects.isEmpty ? 0.45 : 1)
        .dashListCardInset()

        DashListGroupDivider()
      }

      Button {
        showsBucketActions = false
        navigator?.push(.r2BucketSettings(bucket))
      } label: {
        DashListRow(
          title: DashL10n.string("Bucket settings"),
          subtitle: DashL10n.string("Public access and custom domains"),
          icon: SolarAsset.settings,
          showsIconPlate: false
        )
      }
      .buttonStyle(DashSurfaceButtonStyle())
      .accessibilityLabel(DashL10n.string("Bucket settings, Public access and custom domains"))
      .dashListCardInset()

      if canDeleteFolder {
        DashListGroupDivider()

        Button {
          bucketActionsStep = .deleteFolder
        } label: {
          DashListRow(
            title: DashL10n.string("Delete folder"),
            subtitle: DashL10n.string("This folder is empty"),
            icon: SolarAsset.trash,
            iconColor: DashTheme.danger,
            showsChevron: false,
            showsIconPlate: false
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityLabel(DashL10n.string("Delete folder, This folder is empty"))
        .dashListCardInset()
      }
    }
  }

  /// Removes the folder's own marker. Cloudflare keeps no folder to empty first —
  /// `canDeleteFolder` already proved the prefix holds nothing else.
  private var deleteFolderAction: DashDangerAction {
    DashDangerAction(
      id: "delete-folder",
      title: DashL10n.string("Delete folder"),
      message: DashL10n.string(
        "Deletes the empty \(currentFolderName) folder from \(bucket). This can't be undone."),
      onSuccessPresentationCompleted: {
        bucketActionsStep = .menu
        // The parent listing is stale by exactly this folder; its own
        // `reloadIfInvalidated` refetches when the cache comes back cold.
        navigator?.pop()
      },
      perform: { try await deleteFolder() }
    )
  }

  private func deleteFolder() async throws {
    let request = requestIdentity
    guard let context = request.context, canCommit(request), canDeleteFolder else {
      throw CancellationError()
    }
    try await model.client.deleteR2Object(
      accountID: context.accountID, bucket: bucket, key: folderPrefix)
    guard matchesCurrentRequest(request) else { return }
    model.featureCache.remove(
      prefix: FeatureCacheKey.r2ObjectsPrefix(accountID: context.accountID, bucket: bucket))
    hasFolderMarker = false
    model.toasts.success(DashL10n.string("Deleted \(currentFolderName)."))
  }

  private func toggleSelection(_ object: R2Object) {
    if selectedKeys.contains(object.key) {
      selectedKeys.remove(object.key)
    } else {
      selectedKeys.insert(object.key)
    }
  }

  private func beginTwoFingerSelect() {
    guard featureAllowsWrites, !objects.isEmpty else { return }
    if !selecting {
      withAnimation(DashTheme.Motion.morph) {
        selecting = true
      }
    }
    paintAdds = nil
  }

  private func paintTwoFingerSelect(at point: CGPoint) {
    guard featureAllowsWrites else { return }
    if !selecting {
      withAnimation(DashTheme.Motion.morph) { selecting = true }
    }
    guard let key = objectFrameStore.key(at: point, verticalHitSlop: 2) else { return }
    if paintAdds == nil {
      paintAdds = !selectedKeys.contains(key)
    }
    let shouldSelect = paintAdds ?? true
    if shouldSelect {
      guard !selectedKeys.contains(key) else { return }
      selectedKeys.insert(key)
      DashDelight.selectionChanged()
    } else {
      guard selectedKeys.contains(key) else { return }
      selectedKeys.remove(key)
      DashDelight.selectionChanged()
    }
  }

  private var batchDeleteAction: DashDangerAction {
    let count = selectedKeys.count
    let noun = DashL10n.string(count == 1 ? "object" : "objects")
    return DashDangerAction(
      id: "batch-delete",
      title: DashL10n.string("Delete \(count) \(noun)"),
      message: DashL10n.string(
        "Permanently deletes \(count) \(noun) from \(bucket). This can't be undone."),
      perform: { try await batchDelete() }
    )
  }

  /// Deletes the selection four at a time. A partial failure throws so the
  /// confirm stays open with the message while succeeded rows leave the
  /// selection; Confirm again retries only what's left.
  private func batchDelete() async throws {
    let request = requestIdentity
    guard let context = request.context, canCommit(request) else {
      throw CancellationError()
    }
    let accountID = context.accountID
    let client = model.client
    let bucket = bucket
    // From the selection itself, not `objects` — after a Load more, selected
    // keys can live on pages a first-page refetch no longer shows.
    let visible = objects.map(\.key).filter(selectedKeys.contains)
    let keys = visible + selectedKeys.subtracting(visible).sorted()
    var failures: [String] = []
    var firstError: String?
    for chunkStart in stride(from: 0, to: keys.count, by: 4) {
      try Task.checkCancellation()
      guard matchesCurrentRequest(request) else { throw CancellationError() }
      let chunk = keys[chunkStart..<min(chunkStart + 4, keys.count)]
      var chunkResults: [(String, String?)] = []
      await withTaskGroup(of: (String, String?).self) { group in
        for key in chunk {
          group.addTask {
            do {
              try await client.deleteR2Object(accountID: accountID, bucket: bucket, key: key)
              return (key, nil)
            } catch {
              return (key, error.dashActionableMessage)
            }
          }
        }
        for await result in group { chunkResults.append(result) }
      }
      guard canCommit(request) else { throw CancellationError() }
      for (key, failure) in chunkResults {
        if let failure {
          failures.append(key)
          if firstError == nil { firstError = failure }
        } else {
          selectedKeys.remove(key)
        }
      }
    }
    guard canCommit(request) else { throw CancellationError() }
    model.featureCache.remove(
      prefix: FeatureCacheKey.r2ObjectsPrefix(accountID: accountID, bucket: bucket))
    await load(force: true, for: request)
    guard canCommit(request) else { throw CancellationError() }
    if failures.isEmpty {
      model.toasts.success(
        DashL10n.string(
          "Deleted \(keys.count) \(keys.count == 1 ? DashL10n.string("object") : DashL10n.string("objects"))."
        ))
      withAnimation(DashTheme.Motion.morph) { selecting = false }
    } else {
      // Keep the failed keys selected past the reload so Confirm retries them.
      selectedKeys.formUnion(failures)
      DashDelight.failError()
      throw R2BatchFailure(
        message: DashL10n.string(
          "Deleted \(keys.count - failures.count) of \(keys.count). \(firstError ?? DashL10n.string("Some deletions failed."))"
        )
      )
    }
  }

  private func invalidateAndReload() async {
    let request = requestIdentity
    guard let context = request.context, canCommit(request) else { return }
    model.featureCache.remove(
      prefix: FeatureCacheKey.r2ObjectsPrefix(accountID: context.accountID, bucket: bucket))
    await load(force: true, for: request)
  }

  /// A folder created or deleted on a screen pushed above this one drops the
  /// cache for the whole bucket while this listing stays alive underneath;
  /// refresh on return when this prefix went cold. Same contract as the bucket
  /// list one screen up.
  private func reloadIfInvalidated() {
    let request = requestIdentity
    guard
      let context = request.context,
      matchesCurrentRequest(request),
      !objects.isEmpty || !folders.isEmpty
    else { return }
    let cached: R2BrowserSnapshot? = model.featureCache.get(
      FeatureCacheKey.r2Objects(accountID: context.accountID, bucket: bucket, prefix: folderPrefix))
    if cached == nil { Task { await load(force: true, for: request) } }
  }

  private func loadDomains(for request: R2BucketRequestIdentity) async {
    guard
      domains == nil,
      !domainsLoadInFlight,
      let context = request.context,
      canCommit(request)
    else { return }
    let accountID = context.accountID
    let key = FeatureCacheKey.r2Domains(accountID: accountID, bucket: bucket)
    if let cached: R2DomainsSnapshot = model.featureCache.get(key) {
      guard canCommit(request) else { return }
      domains = cached
      return
    }
    domainsLoadInFlight = true
    defer { domainsLoadInFlight = false }
    async let managedTask = model.client.getR2ManagedDomain(accountID: accountID, bucket: bucket)
    async let customTask = model.client.listR2CustomDomains(accountID: accountID, bucket: bucket)
    // A snapshot must never be materialized from a thrown fetch: managed nil +
    // custom [] is exactly what "no public access" looks like, so a transport
    // error would impersonate that settled answer and silently drop Copy
    // public URL. Failed and empty are different answers — on failure `domains`
    // stays nil and the next visit retries.
    guard
      let managed = try? await managedTask,
      let custom = try? await customTask,
      canCommit(request)
    else { return }
    let snapshot = R2DomainsSnapshot(managed: managed, custom: custom)
    domains = snapshot
    model.featureCache.set(key, snapshot)
  }

  private func refreshDomainsFromCache() {
    let request = requestIdentity
    guard let context = request.context,
      matchesCurrentRequest(request),
      let cached: R2DomainsSnapshot = model.featureCache.get(
        FeatureCacheKey.r2Domains(accountID: context.accountID, bucket: bucket))
    else { return }
    domains = cached
  }

  private func uploadProgressCard(_ fileName: String) -> some View {
    DashCard {
      HStack(spacing: 12) {
        DashLoadingRing(color: DashTheme.brand)
        VStack(alignment: .leading, spacing: 2) {
          Text("Uploading \(fileName)")
            .dashTextStyle(.bodySemibold)
            .foregroundStyle(DashTheme.text)
            .lineLimit(1)
          Text("Keep Dash open until the upload finishes.")
            .dashTextStyle(.caption)
            .foregroundStyle(DashTheme.subtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Button("Cancel") {
          work.upload?.cancel()
        }
        .dashTextStyle(.supportingSemibold)
        .foregroundStyle(DashTheme.danger)
        .buttonStyle(DashPressButtonStyle())
        .dashCompactHitTarget()
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func load(
    force: Bool = false,
    for request: R2BucketRequestIdentity
  ) async {
    guard let context = request.context, canCommit(request) else { return }
    let id = context.accountID
    let key = FeatureCacheKey.r2Objects(accountID: id, bucket: bucket, prefix: folderPrefix)
    if !force, let cached: R2BrowserSnapshot = model.featureCache.get(key) {
      guard canCommit(request) else { return }
      objects = cached.objects
      folders = cached.commonPrefixes
      cursor = cached.cursor
      hasFolderMarker = cached.hasFolderMarker
      if cursor == nil { selectedKeys.formIntersection(objects.map(\.key)) }
      error = nil
      loading = false
      return
    }
    do {
      let page = try await model.client.listR2Objects(
        accountID: id, bucket: bucket, prefix: folderPrefix.nilIfEmpty, delimiter: "/")
      guard canCommit(request) else { return }
      // A folder's own `…/` marker comes back as an object of the folder it
      // names, where it has no name left to show. It is this screen's own
      // identity, not a row in it — and both Dash and the Cloudflare dashboard
      // write one for every folder they create.
      objects = page.objects.filter { !R2FolderMarker.isMarker(key: $0.key) }
      folders = page.commonPrefixes
      cursor = page.cursor
      hasFolderMarker = !folderPrefix.isEmpty && page.objects.contains { $0.key == folderPrefix }
      // A first-page refetch can't see selections made on later pages —
      // prune only when the listing is complete.
      if cursor == nil { selectedKeys.formIntersection(objects.map(\.key)) }
      model.featureCache.set(
        key,
        R2BrowserSnapshot(
          objects: objects, commonPrefixes: folders, cursor: cursor,
          hasFolderMarker: hasFolderMarker))
      error = nil
    } catch {
      guard canCommit(request), !error.dashIsCancellation else { return }
      self.error = error.dashActionableMessage
    }
    if canCommit(request) { loading = false }
  }

  private func loadMore() async {
    let request = requestIdentity
    guard
      let context = request.context,
      canCommit(request),
      canLoadMore,
      loadMorePhase == .idle
    else { return }
    let id = context.accountID
    let requestedCursor = cursor
    loadMorePhase = .loading
    defer {
      if matchesCurrentRequest(request), loadMorePhase == .loading {
        loadMorePhase = .idle
      }
    }
    // The user can hop folders while this request flies; appending the old
    // listing's page into the new one would cache a chimera.
    let listedPrefix = folderPrefix
    do {
      let page = try await model.client.listR2Objects(
        accountID: id, bucket: bucket, cursor: requestedCursor, prefix: listedPrefix.nilIfEmpty,
        delimiter: "/")
      guard canCommit(request), listedPrefix == folderPrefix else { return }
      objects += page.objects.filter { !R2FolderMarker.isMarker(key: $0.key) }
      for folder in page.commonPrefixes where !folders.contains(folder) {
        folders.append(folder)
      }
      cursor = page.cursor
      if !listedPrefix.isEmpty, page.objects.contains(where: { $0.key == listedPrefix }) {
        hasFolderMarker = true
      }
      model.featureCache.set(
        FeatureCacheKey.r2Objects(accountID: id, bucket: bucket, prefix: listedPrefix),
        R2BrowserSnapshot(
          objects: objects, commonPrefixes: folders, cursor: cursor,
          hasFolderMarker: hasFolderMarker))
      error = nil
      loadMorePhase = .succeeded
    } catch {
      guard canCommit(request), !error.dashIsCancellation else { return }
      self.error = error.dashActionableMessage
    }
  }
  private func beginUpload(_ url: URL) {
    let request = requestIdentity
    guard work.upload == nil, request.context != nil, canCommit(request) else { return }
    uploadingFileName = url.lastPathComponent
    work.upload = Task { await upload(url, request: request) }
  }

  private func upload(_ url: URL, request: R2BucketRequestIdentity) async {
    guard let context = request.context, canCommit(request) else { return }
    let id = context.accountID
    defer {
      if matchesCurrentRequest(request) {
        work.upload = nil
        uploadingFileName = nil
      }
    }
    do {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
        guard canCommit(request) else { return }
        // Operation feedback, not a listing failure: the screen's `error`
        // channel belongs to load()/loadMore(), like the oversize branch below.
        model.toasts.error(DashL10n.string("Can't read that file's size."))
        return
      }
      guard size <= R2Media.transferSizeLimit else {
        guard canCommit(request) else { return }
        model.toasts.error(
          "\(url.lastPathComponent) is \(size.formatted(.byteCount(style: .file))). Dash uploads files up to \(R2Media.transferSizeLimit.formatted(.byteCount(style: .file))). Use wrangler or the dashboard for this one."
        )
        return
      }
      try await model.client.putR2Object(
        accountID: id, bucket: bucket, key: folderPrefix + url.lastPathComponent, fileURL: url,
        contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType)
      guard canCommit(request) else { return }
      model.featureCache.remove(
        prefix: FeatureCacheKey.r2ObjectsPrefix(accountID: id, bucket: bucket))
      await load(force: true, for: request)
      guard canCommit(request) else { return }
      R2ShareDestination.record(
        R2ShareDestination(
          accountID: id, bucket: bucket, prefix: folderPrefix,
          publicHost: domains?.publicHost ?? ""))
      model.toasts.success(DashL10n.string("Uploaded \(url.lastPathComponent)."))
    } catch {
      guard matchesCurrentRequest(request) else { return }
      if error.dashIsCancellation || Task.isCancelled {
        model.toasts.warning(DashL10n.string("Upload cancelled."))
        return
      }
      model.toasts.error(error.dashActionableMessage)
    }
  }
  private func folderName(_ prefix: String) -> String {
    let relative =
      prefix.hasPrefix(folderPrefix) ? String(prefix.dropFirst(folderPrefix.count)) : prefix
    let name = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return name.isEmpty ? prefix : name
  }

  private func objectName(_ key: String) -> String {
    guard key.hasPrefix(folderPrefix) else { return key }
    let relative = String(key.dropFirst(folderPrefix.count))
    return relative.isEmpty ? key : relative
  }
}

private func r2BucketAccessibilityLabel(_ bucket: R2Bucket) -> String {
  if let created = r2BucketCreationText(bucket.creationDate) {
    return "\(bucket.name), \(created)"
  }
  return bucket.name
}

private func r2BucketCreationText(_ value: String?) -> String? {
  guard let value, !value.isEmpty else { return nil }
  guard ExpiryReminders.date(fromISO8601: value) != nil else { return value }
  return DashL10n.string(
    "Created \(DashDateFormatting.dateOnly(fromISO8601: value))")
}

/// Global frames for R2 object rows, used by the two-finger paint-select pan.
private struct R2ObjectFrameKey: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

@MainActor
private final class R2ObjectFrameStore {
  private var frames: [String: CGRect] = [:]

  func replace(with frames: [String: CGRect]) {
    self.frames = frames
  }

  func clear() {
    frames.removeAll(keepingCapacity: true)
  }

  func key(at point: CGPoint, verticalHitSlop: CGFloat) -> String? {
    frames.first { _, frame in
      frame.insetBy(dx: 0, dy: -verticalHitSlop).contains(point)
    }?.key
  }
}

/// UITableView-style multiselect: a two-finger pan on the bucket's scroll view
/// enters selection mode and paints rows under the fingers. One-finger scroll
/// stays exclusive (`maximumNumberOfTouches = 1` while attached).
struct R2DelayedAttachmentGate {
  private(set) var generation = 0
  private(set) var isMounted = true

  mutating func schedule() -> Int {
    isMounted = true
    generation &+= 1
    return generation
  }

  mutating func invalidate() {
    isMounted = false
    generation &+= 1
  }

  func accepts(_ candidate: Int) -> Bool {
    isMounted && generation == candidate
  }
}

private struct R2TwoFingerSelectInstaller: UIViewRepresentable {
  var isEnabled: Bool
  var onBegan: () -> Void
  var onPaintAt: (CGPoint) -> Void
  var onEnded: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    view.backgroundColor = .clear
    view.isOpaque = false
    return view
  }

  func updateUIView(_ uiView: UIView, context: Context) {
    let coordinator = context.coordinator
    coordinator.isEnabled = isEnabled
    coordinator.onBegan = onBegan
    coordinator.onPaintAt = onPaintAt
    coordinator.onEnded = onEnded
    coordinator.recognizer?.isEnabled = isEnabled
    let generation = coordinator.scheduleAttachment()
    DispatchQueue.main.async {
      coordinator.attach(from: uiView, generation: generation)
      DispatchQueue.main.async {
        coordinator.attach(from: uiView, generation: generation)
      }
    }
  }

  static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
    coordinator.invalidate()
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var isEnabled = false
    var onBegan: () -> Void = {}
    var onPaintAt: (CGPoint) -> Void = { _ in }
    var onEnded: () -> Void = {}
    weak var scrollView: UIScrollView?
    weak var recognizer: UIPanGestureRecognizer?
    private var originalMaxTouches: Int?
    private var attachmentGate = R2DelayedAttachmentGate()

    func scheduleAttachment() -> Int {
      attachmentGate.schedule()
    }

    func attach(from probe: UIView, generation: Int) {
      guard attachmentGate.accepts(generation), probe.window != nil,
        let scroll = Self.contentScrollView(from: probe),
        scroll.window === probe.window
      else { return }
      if scrollView === scroll, recognizer != nil {
        recognizer?.isEnabled = isEnabled
        return
      }
      detach()
      scrollView = scroll
      originalMaxTouches = scroll.panGestureRecognizer.maximumNumberOfTouches
      // Keep ordinary scrolling one-finger so our two-finger pan never fights it.
      scroll.panGestureRecognizer.maximumNumberOfTouches = 1
      let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
      pan.minimumNumberOfTouches = 2
      pan.maximumNumberOfTouches = 2
      pan.delegate = self
      pan.isEnabled = isEnabled
      scroll.addGestureRecognizer(pan)
      recognizer = pan
    }

    func invalidate() {
      attachmentGate.invalidate()
      onBegan = {}
      onPaintAt = { _ in }
      onEnded = {}
      detach()
    }

    func detach() {
      if let scroll = scrollView {
        if let originalMaxTouches {
          scroll.panGestureRecognizer.maximumNumberOfTouches = originalMaxTouches
        }
        if let recognizer {
          scroll.removeGestureRecognizer(recognizer)
        }
      }
      scrollView = nil
      recognizer = nil
      originalMaxTouches = nil
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
      guard isEnabled else { return }
      let point = gesture.location(in: nil)
      switch gesture.state {
      case .began:
        onBegan()
        onPaintAt(point)
      case .changed:
        onPaintAt(point)
      case .ended, .cancelled, .failed:
        onEnded()
      default:
        break
      }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      isEnabled
    }

    private static func contentScrollView(from view: UIView) -> UIScrollView? {
      DashScreenScrollLocator.contentScrollView(from: view)
    }
  }
}

/// One cached page of a bucket listing, keyed per account/bucket/prefix. Shared
/// with Home's upload destination picker: it needs the same `commonPrefixes` to
/// offer folders, so a listing either screen fetches warms the other.
struct R2BrowserSnapshot: Sendable {
  let objects: [R2Object]
  let commonPrefixes: [String]
  let cursor: String?
  /// Whether the listed prefix carries its own zero-byte marker object. Cached
  /// with the page because "this folder is empty" and "this folder can be
  /// deleted" are different answers, and only the listing knows the difference.
  let hasFolderMarker: Bool
}

/// Holds in-flight upload work for one `R2BucketView`. Kept as a class so
/// NavigationStack can hide the screen under a folder push without cancelling;
/// `deinit` cancels when the screen is popped off the stack.
@Observable
private final class R2BucketWork {
  var upload: Task<Void, Never>?

  func cancelAndRelease() {
    let upload = upload
    self.upload = nil
    upload?.cancel()
  }

  deinit {
    upload?.cancel()
  }
}

struct KVNamespacesView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(RecentResources.key) private var recentsRaw = ""
  @State private var namespaces: [KVNamespace] = []
  @State private var error: String?
  @State private var loading = true
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
      loading = false
      error = nil
      return
    }
    // Cold but a stale copy exists on disk: paint it now and refresh in place.
    if namespaces.isEmpty, let stale: [KVNamespace] = model.featureCache.getStale(key) {
      guard model.isCurrentAccount(context) else { return }
      namespaces = stale
      loading = true
    }
    if namespaces.isEmpty { loading = true }
    let client = model.client
    do {
      let fetched = try await client.listKVNamespaces(accountID: context.accountID).items
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      namespaces = fetched
      model.featureCache.set(key, fetched)
      error = nil
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
    }
    if model.isCurrentAccount(context) { loading = false }
  }

  private func prepareForCurrentAccount() {
    let context = model.accountRequestContext
    guard loadedContext != context else { return }
    loadedContext = context
    namespaces = []
    error = nil
    loading = context != nil
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
  @State private var error: String?
  @State private var loading = true
  @State private var loadMorePhase: DashActionPhase = .idle
  @State private var loadedContext: AccountRequestContext?

  private var canLoadMore: Bool { cursor?.isEmpty == false }

  /// Prefer the cached human title so list → detail morphs keep the same label.
  private var namespaceTitle: String {
    guard let accountID = model.activeAccountID,
      let namespaces: [KVNamespace] = model.featureCache.get(
        FeatureCacheKey.kvNamespaces(accountID)),
      let match = namespaces.first(where: { $0.id == namespaceID })
    else { return "KV keys" }
    return match.title
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
          DashListGroupLink(value: .kvKey(namespaceID: namespaceID, key: key.name)) {
            DashListRow(title: key.name, icon: SolarAsset.Content.key)
          }
          .accessibilityLabel(DashL10n.string("\(key.name), KV key"))
        }
      }
      if !mode.isPlaceholder, canLoadMore || loadMorePhase.isActive {
        DashLoadMoreFooter(
          loaded: keys.count,
          noun: "keys",
          phase: loadMorePhase,
          onSuccessPresentationCompleted: { loadMorePhase = .idle }
        ) {
          Task { await loadMore() }
        }
      }
    }
    .detailHeader(
      icon: .solar(SolarAsset.Content.pinList),
      title: namespaceTitle,
      tint: FeatureVisualIdentity.heroColor(for: .kv)
    )
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if featureAllowsWrites {
          DashToolbarIconButton(
            asset: SolarAsset.plus, accessibilityLabel: DashL10n.string("Create key")
          ) {
            showsCreateKey = true
          }
        }
      }
      .dashSeparateToolbarBackground()
    }
    .task(id: model.accountRequestContext) {
      prepareForCurrentAccount()
      await load()
    }
    .refreshable { await load(force: true) }
    .onAppear { reloadIfKeysInvalidated() }
    .dashTray(isPresented: $showsCreateKey, title: DashL10n.string("Create key")) {
      KVCreateKeySheet(namespaceID: namespaceID) {
        invalidateKeys()
        Task { await load(force: true) }
      }
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
      loadMorePhase == .idle
    else { return }
    let requestedCursor = cursor
    let client = model.client
    loadMorePhase = .loading
    defer {
      if model.isCurrentAccount(context), loadMorePhase == .loading {
        loadMorePhase = .idle
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
      loadMorePhase = .succeeded
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
    loadMorePhase = .idle
    showsCreateKey = false
  }
}

private enum StorageExternalURL {
  static let r2BucketsGuide = URL(
    string: "https://developers.cloudflare.com/r2/buckets/create-buckets/")!
  static let kvGuide = URL(string: "https://developers.cloudflare.com/kv/get-started/")!
}

struct R2CreateBucketSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let onCreated: () -> Void
  @State private var name = ""
  @State private var actionPhase: DashActionPhase = .idle
  @State private var error: String?

  var body: some View {
    DashFormSheet(
      saveTitle: DashL10n.string("Create bucket"),
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completeCreatePresentation,
      canSave: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      onSave: { Task { await create() } },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          if let error {
            DashNotice(kind: .error, message: error)
          }
          DashFormField(label: DashL10n.string("Bucket name"), text: $name)
        }
      }
    )
    .dashTrayDescription(DashL10n.string("Use lowercase letters, numbers, and hyphens."))
  }

  private func create() async {
    guard let context = model.accountRequestContext else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    actionPhase = .loading
    error = nil
    do {
      _ = try await model.client.createR2Bucket(accountID: context.accountID, name: trimmed)
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        actionPhase = .idle
        return
      }
      model.toasts.success(DashL10n.string("Created successfully."))
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
    actionPhase = .idle
    onCreated()
    dismiss()
  }
}

/// Creates a folder by writing the zero-byte `…/` marker object Cloudflare's own
/// dashboard writes for its Create folder action, so a folder made in Dash is
/// the same folder the web UI — or rclone, or Cyberduck — would have made.
///
/// Name collisions are checked against the listing already on screen instead of
/// with another request. R2's PUT is idempotent, so re-creating an existing
/// folder would answer with a silent success; and a folder that takes an
/// object's name would hide that object in the Files mount, where a file and a
/// directory cannot share one filename.
struct R2CreateFolderSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let bucket: String
  /// The prefix this tray creates into — `""` at the bucket root.
  let folderPrefix: String
  let siblingFolders: [String]
  let siblingObjectKeys: [String]
  var onCreated: () async -> Void
  @State private var name = ""
  @State private var actionPhase: DashActionPhase = .idle
  @State private var error: String?

  private var markerKey: String? {
    R2FolderMarker.markerKey(parentPrefix: folderPrefix, name: name)
  }
  /// The name as a row will read it: the path below this screen's own prefix.
  private var displayName: String? {
    markerKey.map { String($0.dropFirst(folderPrefix.count).dropLast()) }
  }
  private var collisionMessage: String? {
    guard let markerKey, let displayName else { return nil }
    if siblingFolders.contains(markerKey) {
      return DashL10n.string("A folder named \(displayName) is already here.")
    }
    // Nested names only collide with this listing's first component — deeper
    // segments live under prefixes this screen has not fetched.
    if let first = displayName.split(separator: "/").first.map(String.init) {
      let firstObjectKey = folderPrefix + first
      if siblingObjectKeys.contains(firstObjectKey) {
        return DashL10n.string("An object named \(first) is already here.")
      }
    }
    if siblingObjectKeys.contains(String(markerKey.dropLast())) {
      return DashL10n.string("An object named \(displayName) is already here.")
    }
    return nil
  }
  /// An untouched field is not a mistake — Create folder simply stays disabled.
  private var notice: String? {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    if let problem = R2FolderMarker.nameProblem(parentPrefix: folderPrefix, name: name) {
      return message(for: problem)
    }
    return collisionMessage
  }
  private var canSave: Bool { markerKey != nil && collisionMessage == nil }

  var body: some View {
    DashFormSheet(
      saveTitle: DashL10n.string("Create folder"),
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completeCreatePresentation,
      canSave: canSave,
      onSave: { Task { await create() } },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          if let error {
            DashNotice(kind: .error, message: error)
          } else if let notice {
            DashNotice(kind: .warning, message: notice)
          }
          DashFormField(label: DashL10n.string("Folder name"), text: $name)
          Text(
            DashL10n.string(
              "R2 stores key prefixes, not folders — use / to nest. Dash writes a zero-byte placeholder so the folder stays visible while it is empty."
            )
          )
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(actionPhase.isActive)
      }
    )
    .dashTrayTitle(DashL10n.string("Create folder"))
  }

  private func message(for problem: R2FolderNameProblem) -> String {
    switch problem {
    case .empty:
      DashL10n.string("Enter a folder name.")
    case .emptyPathComponent:
      DashL10n.string("Every part between slashes needs a name.")
    case .relativePathComponent:
      DashL10n.string("A folder can't be named . or ..")
    case .controlCharacters:
      DashL10n.string("Remove the line breaks from the name.")
    case .keyTooLong:
      DashL10n.string("That path is too long — an R2 key holds 1,024 bytes.")
    }
  }

  private func create() async {
    guard let context = model.accountRequestContext, let markerKey, canSave else { return }
    actionPhase = .loading
    error = nil
    do {
      try await model.client.createR2Folder(
        accountID: context.accountID, bucket: bucket, key: markerKey)
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        actionPhase = .idle
        return
      }
      model.toasts.success(DashL10n.string("Created successfully."))
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
    actionPhase = .idle
    dismiss()
    Task { await onCreated() }
  }
}

/// Creates a new KV key/value pair in the open namespace.
struct KVCreateKeySheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let namespaceID: String
  let onCreated: () -> Void
  @State private var keyName = ""
  @State private var value = ""
  @State private var actionPhase: DashActionPhase = .idle
  @State private var error: String?
  @State private var canFormat = false
  @State private var valueFitsDisplayLimit = true
  @State private var valueFitsWriteLimit = true

  var body: some View {
    DashFormSheet(
      saveTitle: DashL10n.string("Create key"),
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completeCreatePresentation,
      canSave: !keyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && valueFitsWriteLimit,
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
            if !valueFitsWriteLimit {
              DashNotice(
                kind: .error,
                message: DashL10n.string("KV values can be up to 25 MiB."))
            } else if !valueFitsDisplayLimit {
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
                .foregroundStyle(canFormat ? DashTheme.strong : DashTheme.placeholder)
            }
            .buttonStyle(DashPressButtonStyle())
            .disabled(!canFormat)
            .accessibilityLabel(DashL10n.string("Format"))
          }
        }
        .disabled(actionPhase.isActive)
      }
    )
    .task(id: value) {
      await refreshJSONValidity()
    }
  }

  private func refreshJSONValidity() async {
    canFormat = false
    let candidate = value
    let byteCount = candidate.utf8.count
    let fitsDisplayLimit = KVJSONFormatting.isWithinDisplayLimit(byteCount: byteCount)
    let fitsWriteLimit = KVValueLimits.isWithinWriteLimit(byteCount: byteCount)
    guard !Task.isCancelled, value == candidate else { return }
    valueFitsDisplayLimit = fitsDisplayLimit
    valueFitsWriteLimit = fitsWriteLimit
    guard fitsDisplayLimit else { return }
    do {
      try await Task.sleep(for: .milliseconds(250))
    } catch {
      return
    }
    let canPrettyPrint = await Task.detached(priority: .userInitiated) {
      KVJSONFormatting.prettyPrintedForDisplay(candidate) != nil
    }.value
    guard !Task.isCancelled, value == candidate else { return }
    canFormat = canPrettyPrint
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
      model.toasts.success(DashL10n.string("Created successfully."))
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
    actionPhase = .idle
    onCreated()
    dismiss()
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
  @State private var canFormat = false
  @State private var valueFitsDisplayLimit = true
  @State private var valueFitsWriteLimit = true
  @State private var displayIssue: KVJSONFormatting.DisplayValue?
  @State private var rawValueData: Data?

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
                  message: displayIssueMessage(displayIssue)
                )
              } else if loaded {
                DashKVCodeEditor(text: $value, editable: mode == .editing && !saving)
                  .frame(maxWidth: .infinity)
                  .frame(height: editorHeight(in: geo))
                  .clipShape(
                    RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
                if mode == .editing {
                  if !valueFitsWriteLimit {
                    DashNotice(
                      kind: .error,
                      message: DashL10n.string("KV values can be up to 25 MiB."))
                  } else if !valueFitsDisplayLimit {
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
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if featureAllowsWrites, mode == .viewing, loaded, ownsCurrentAccount,
          !confirmingDelete
        {
          DashToolbarIconButton(
            asset: SolarAsset.trash,
            accessibilityLabel: DashL10n.string("Delete")
          ) {
            withAnimation(DashTheme.Motion.morph) { confirmingDelete = true }
          }
        }
      }
      .dashSeparateToolbarBackground()
    }
    .dashKeyboardDismissal()
    .task(id: model.accountRequestContext) {
      prepareForCurrentAccount()
      await load()
    }
    .task(id: value) {
      await refreshJSONValidity()
    }
  }

  @ViewBuilder private var accessoryRow: some View {
    switch mode {
    case .viewing:
      DashSecondaryPillButton(
        title: copied ? DashL10n.string("Copied") : DashL10n.string("Copy")
      ) {
        copyValue()
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
            .foregroundStyle(canFormat ? DashTheme.strong : DashTheme.placeholder)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(DashPressButtonStyle())
        .disabled(!canFormat)
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
      return loaded && valueFitsWriteLimit && ownsCurrentAccount
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
      model.toasts.success(DashL10n.string("Saved successfully."))
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
      model.toasts.success(DashL10n.string("Deleted successfully."))
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
      navigator?.pop()
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
    canFormat = false
    valueFitsDisplayLimit = true
    valueFitsWriteLimit = true
    displayIssue = nil
    rawValueData = nil
  }

  private func displayIssueMessage(_ issue: KVJSONFormatting.DisplayValue) -> String {
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

  private func copyValue() {
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

  private func refreshJSONValidity() async {
    canFormat = false
    guard displayIssue == nil else {
      return
    }
    let candidate = value
    let byteCount = candidate.utf8.count
    let fitsDisplayLimit = KVJSONFormatting.isWithinDisplayLimit(byteCount: byteCount)
    let fitsWriteLimit = KVValueLimits.isWithinWriteLimit(byteCount: byteCount)
    guard !Task.isCancelled, value == candidate else { return }
    valueFitsDisplayLimit = fitsDisplayLimit
    valueFitsWriteLimit = fitsWriteLimit
    guard fitsDisplayLimit else { return }
    do {
      try await Task.sleep(for: .milliseconds(250))
    } catch {
      return
    }
    let canPrettyPrint = await Task.detached(priority: .userInitiated) {
      KVJSONFormatting.prettyPrintedForDisplay(candidate) != nil
    }.value
    guard !Task.isCancelled, value == candidate else { return }
    canFormat = canPrettyPrint
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

private struct R2BatchFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

extension String { fileprivate var nilIfEmpty: String? { isEmpty ? nil : self } }
