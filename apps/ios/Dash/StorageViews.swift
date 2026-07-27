import CloudflareAPI
import CodeEditor
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct R2BucketsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.openURL) private var openURL
  @State private var buckets: [R2Bucket] = []
  @State private var error: String?
  @State private var loading = true
  @State private var showsCreateBucket = false

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !buckets.isEmpty,
      retry: { Task { await load() } }
    ) {
      if buckets.isEmpty {
        DashEmptyState(
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
        )
      } else {
        dashListCard {
          dashListCardRows(items: buckets) { bucket in
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
  @State private var loadingMore = false
  @State private var importsFile = false
  @State private var selectedObject: R2Object?
  /// Survives folder/settings pushes (view merely disappears). Cancels in
  /// `deinit` when this screen leaves the navigation stack for good.
  @State private var work = R2BucketWork()
  @State private var uploadingFileName: String?
  @State private var selecting = false
  @State private var selectedKeys: Set<String> = []
  @State private var confirmsBatchDelete = false
  @State private var movesSelection = false
  @State private var showsBucketActions = false
  @State private var batchLabel: String?
  /// The account/bucket/prefix currently represented by the state above.
  /// This survives view-value updates so stale async tasks can be rejected.
  @State private var displayedRequestIdentity: R2BucketRequestIdentity?
  /// Public-exposure snapshot for Copy-URL actions; loaded lazily and shared
  /// with the settings screen through the feature cache.
  @State private var domains: R2DomainsSnapshot?
  /// Reference storage keeps scroll-driven geometry outside SwiftUI's
  /// observation graph. Only the two-finger recognizer reads it.
  @State private var objectFrameStore = R2ObjectFrameStore()
  /// Once a two-finger pan starts, keep adding or removing based on the first
  /// row under the fingers (UITableView multiselect behavior).
  @State private var paintAdds: Bool?

  private var canLoadMore: Bool { cursor?.isEmpty == false }
  private var hasTransferStatus: Bool {
    uploadingFileName != nil || batchLabel != nil
  }
  private var tracksObjectFrames: Bool {
    featureAllowsWrites && !objects.isEmpty && work.batch == nil
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
      hasContent: !objects.isEmpty || !folders.isEmpty,
      retry: {
        let request = requestIdentity
        Task { await load(for: request) }
      }
    ) {
      if hasTransferStatus {
        DashSurfaceStack {
          if let uploadingFileName {
            uploadProgressCard(uploadingFileName)
          }
          if let batchLabel {
            batchProgressCard(batchLabel)
          }
        }
        .padding(.bottom, DashTheme.Spacing.itemGap)
      }
      // Folders and objects are sibling LazyVStack children — never one
      // dashListCard wrapping both. A shared card would make Content a
      // TupleView, and `.dashListCardInset()` on that tuple re-eagerizes
      // every object row (thumbnail stampede).
      ForEach(folders, id: \.self) { folder in
        DashListGroupLink(value: .r2Bucket(bucket, prefix: folder)) {
          DashListRow(
            title: folderName(folder),
            subtitle: DashL10n.string("Virtual folder"),
            icon: SolarAsset.Content.folder
          )
          .accessibilityLabel("\(folderName(folder)), \(DashL10n.string("Virtual folder"))")
        }
        .dashListCardInset()
      }
      if !objects.isEmpty {
        dashListCard {
          dashListCardRows(items: objects) { object in
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
      if folders.isEmpty && objects.isEmpty {
        DashEmptyState(
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
        )
      }
      if canLoadMore {
        DashLoadMoreFooter(
          loaded: folders.count + objects.count, noun: "items", isLoading: loadingMore
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
              accessibilityLabel: "Done selecting"
            ) {
              withAnimation(DashTheme.Motion.morph) {
                selecting = false
                selectedKeys = []
              }
            }
            .disabled(work.batch != nil)
          } else {
            // Stable trailing chrome: Upload (writes) + More. Select and
            // settings live in More so load completion never inserts a third
            // button and shoves the principal title left.
            if featureAllowsWrites {
              DashToolbarIconButton(
                asset: SolarAsset.upload, accessibilityLabel: "Upload file"
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
        isEnabled: featureAllowsWrites && !objects.isEmpty && work.batch == nil,
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
        onMutated: {
          // Owner of the preview cover: close it, then reload the listing —
          // the object it showed was just renamed or deleted.
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
    .dashTray(isPresented: $movesSelection, title: "Move objects") {
      R2MoveForm(currentFolder: folderPrefix, count: selectedKeys.count) { destination in
        beginBatchMove(to: destination)
      }
    }
    // Settings may have changed the domains while this screen stayed mounted
    // below it — resync from the shared cache on return.
    .onAppear { refreshDomainsFromCache() }
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
    batchLabel = nil
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
    loadingMore = false
    importsFile = false
    selectedObject = nil
    selecting = false
    selectedKeys = []
    confirmsBatchDelete = false
    movesSelection = false
    showsBucketActions = false
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
    HStack(spacing: 10) {
      Button {
        movesSelection = true
      } label: {
        Text(
          selectedKeys.isEmpty
            ? DashL10n.string("Move") : DashL10n.string("Move \(selectedKeys.count)")
        )
        .dashTextStyle(.buttonBold)
        .foregroundStyle(DashTheme.strong)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(DashTheme.recessed, in: DashTheme.pillShape)
        .dashShadow(.border, in: DashTheme.pillShape)
      }
      .buttonStyle(DashPressButtonStyle())
      .disabled(selectedKeys.isEmpty || work.batch != nil)
      .opacity(selectedKeys.isEmpty || work.batch != nil ? 0.45 : 1)

      Button {
        confirmsBatchDelete = true
      } label: {
        Text(
          selectedKeys.isEmpty
            ? DashL10n.string("Delete") : DashL10n.string("Delete \(selectedKeys.count)")
        )
        .dashTextStyle(.button)
        .foregroundStyle(DashTheme.inverse)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(DashTheme.danger, in: DashTheme.pillShape)
      }
      .buttonStyle(DashPressButtonStyle())
      .disabled(selectedKeys.isEmpty || work.batch != nil)
      .opacity(selectedKeys.isEmpty || work.batch != nil ? 0.45 : 1)
    }
    .padding(.horizontal, DashTheme.Spacing.screen)
    .padding(.vertical, 10)
    .background(DashTheme.canvas)
  }

  @ViewBuilder private var r2BucketActionsTray: some View {
    dashListCard {
      if featureAllowsWrites {
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
            showsChevron: false
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityLabel(
          objects.isEmpty
            ? DashL10n.string("Select objects, Nothing to select in this folder")
            : DashL10n.string("Select objects, Or drag with two fingers on the list")
        )
        .disabled(objects.isEmpty || work.batch != nil)
        .opacity(objects.isEmpty || work.batch != nil ? 0.45 : 1)
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
          icon: SolarAsset.settings
        )
      }
      .buttonStyle(DashSurfaceButtonStyle())
      .accessibilityLabel(DashL10n.string("Bucket settings, Public access and custom domains"))
      .dashListCardInset()
    }
  }

  private func toggleSelection(_ object: R2Object) {
    if selectedKeys.contains(object.key) {
      selectedKeys.remove(object.key)
    } else {
      selectedKeys.insert(object.key)
    }
  }

  private func beginTwoFingerSelect() {
    guard featureAllowsWrites, !objects.isEmpty, work.batch == nil else { return }
    if !selecting {
      withAnimation(DashTheme.Motion.morph) {
        selecting = true
      }
    }
    paintAdds = nil
  }

  private func paintTwoFingerSelect(at point: CGPoint) {
    guard featureAllowsWrites, work.batch == nil else { return }
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

  private func beginBatchMove(to destination: String) {
    let request = requestIdentity
    guard work.batch == nil, request.context != nil, canCommit(request) else { return }
    let targets = objects.filter { selectedKeys.contains($0.key) }
    guard !targets.isEmpty else { return }
    work.batch = Task { await batchMove(targets, to: destination, request: request) }
  }

  /// Sequential per object on purpose: each move owns one scratch file and one
  /// network transfer at a time.
  private func batchMove(
    _ targets: [R2Object],
    to destination: String,
    request: R2BucketRequestIdentity
  ) async {
    guard let context = request.context, canCommit(request) else { return }
    let accountID = context.accountID
    defer {
      if matchesCurrentRequest(request) {
        work.batch = nil
        batchLabel = nil
      }
    }
    var moved = 0
    var skippedLarge = 0
    var skippedExisting = 0
    var failedKeys: [String] = []
    var remainingKeys = Set(targets.map(\.key))
    var wasCancelled = false
    for (index, object) in targets.enumerated() {
      if !canCommit(request) {
        wasCancelled = true
        break
      }
      batchLabel = DashL10n.string("Moving \(index + 1) of \(targets.count)…")
      let filename = object.key.split(separator: "/").last.map(String.init) ?? object.key
      // Dashboard-created folder markers end in "/" — keep them folders.
      let isFolderMarker = object.key.hasSuffix("/")
      let newKey = destination + filename + (isFolderMarker ? "/" : "")
      guard newKey != object.key else {
        selectedKeys.remove(object.key)
        remainingKeys.remove(object.key)
        continue
      }
      guard R2Media.isWithinTransferLimit(object.size) else {
        skippedLarge += 1
        continue
      }
      do {
        do {
          try await R2ObjectConsistency.requireAbsent(
            client: model.client, accountID: accountID, bucket: bucket, key: newKey)
          guard canCommit(request) else {
            wasCancelled = true
            break
          }
        } catch R2ObjectConsistencyError.destinationExists {
          skippedExisting += 1
          continue
        }
        let temporaryFile = R2TemporaryFile.make(purpose: "r2-batch-move", filename: filename)
        defer { temporaryFile.remove() }
        try await model.client.downloadR2Object(
          accountID: accountID, bucket: bucket, key: object.key,
          to: temporaryFile.fileURL, maximumBytes: R2Media.transferSizeLimitBytes)
        guard canCommit(request) else {
          wasCancelled = true
          break
        }
        try await R2ObjectConsistency.requireUnchanged(
          object, client: model.client, accountID: accountID, bucket: bucket)
        guard canCommit(request) else {
          wasCancelled = true
          break
        }
        do {
          try await R2ObjectConsistency.requireAbsent(
            client: model.client, accountID: accountID, bucket: bucket, key: newKey)
          guard canCommit(request) else {
            wasCancelled = true
            break
          }
        } catch R2ObjectConsistencyError.destinationExists {
          skippedExisting += 1
          continue
        }
        try await model.client.putR2Object(
          accountID: accountID, bucket: bucket, key: newKey, fileURL: temporaryFile.fileURL,
          contentType: object.contentType ?? R2Media.mimeType(forKey: newKey))
        guard canCommit(request) else {
          wasCancelled = true
          break
        }
        try await R2ObjectConsistency.requireUnchanged(
          object, client: model.client, accountID: accountID, bucket: bucket)
        guard canCommit(request) else {
          wasCancelled = true
          break
        }
        try await model.client.deleteR2Object(
          accountID: accountID, bucket: bucket, key: object.key)
        guard canCommit(request) else {
          wasCancelled = true
          break
        }
        moved += 1
        selectedKeys.remove(object.key)
        remainingKeys.remove(object.key)
      } catch {
        if error.dashIsCancellation || !canCommit(request) {
          wasCancelled = true
          break
        }
        failedKeys.append(object.key)
      }
    }
    if !canCommit(request) { wasCancelled = true }
    guard matchesCurrentRequest(request) else { return }
    model.featureCache.remove(
      prefix: FeatureCacheKey.r2ObjectsPrefix(accountID: accountID, bucket: bucket))
    await load(force: true, for: request)
    if !canCommit(request) { wasCancelled = true }
    guard matchesCurrentRequest(request) else { return }
    // A complete reload may prune selection. Restore skipped, failed, and
    // never-started keys so cancellation can be retried without reselecting.
    selectedKeys.formUnion(remainingKeys)
    if wasCancelled { return }
    let failed = failedKeys.count
    var parts: [String] = []
    if moved > 0 { parts.append(DashL10n.string("Moved \(moved)")) }
    if skippedLarge > 0 {
      parts.append(DashL10n.string("skipped \(skippedLarge) over the 100 MB on-device limit"))
    }
    if skippedExisting > 0 {
      parts.append(
        DashL10n.string("skipped \(skippedExisting) — an object already exists at the destination"))
    }
    if failed > 0 { parts.append(DashL10n.string("\(failed) failed")) }
    if !parts.isEmpty {
      let message = parts.joined(separator: " · ") + "."
      let clean = failed == 0 && skippedLarge == 0 && skippedExisting == 0
      if clean {
        model.toasts.success(message)
      } else if moved > 0 {
        model.toasts.warning(message)
      } else {
        model.toasts.error(message)
      }
    }
    if failed == 0 && skippedLarge == 0 && skippedExisting == 0 {
      withAnimation(DashTheme.Motion.morph) { selecting = false }
    }
  }

  private func invalidateAndReload() async {
    let request = requestIdentity
    guard let context = request.context, canCommit(request) else { return }
    model.featureCache.remove(
      prefix: FeatureCacheKey.r2ObjectsPrefix(accountID: context.accountID, bucket: bucket))
    await load(force: true, for: request)
  }

  private func loadDomains(for request: R2BucketRequestIdentity) async {
    guard
      domains == nil,
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
    async let managedTask = model.client.getR2ManagedDomain(accountID: accountID, bucket: bucket)
    async let customTask = model.client.listR2CustomDomains(accountID: accountID, bucket: bucket)
    let managed = try? await managedTask
    let custom = try? await customTask
    guard canCommit(request) else { return }
    let snapshot = R2DomainsSnapshot(managed: managed, custom: custom ?? [])
    domains = snapshot
    // A failed fetch must not poison the shared per-bucket cache for its TTL.
    if custom != nil {
      model.featureCache.set(key, snapshot)
    }
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

  private func batchProgressCard(_ label: String) -> some View {
    DashCard {
      HStack(spacing: 12) {
        DashLoadingRing(color: DashTheme.brand)
        VStack(alignment: .leading, spacing: 2) {
          Text(label)
            .dashTextStyle(.bodySemibold)
            .foregroundStyle(DashTheme.text)
            .lineLimit(1)
          Text("Keep Dash open until the move finishes.")
            .dashTextStyle(.caption)
            .foregroundStyle(DashTheme.subtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Button("Cancel") {
          work.batch?.cancel()
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
      if cursor == nil { selectedKeys.formIntersection(objects.map(\.key)) }
      error = nil
      loading = false
      return
    }
    do {
      let page = try await model.client.listR2Objects(
        accountID: id, bucket: bucket, prefix: folderPrefix.nilIfEmpty, delimiter: "/")
      guard canCommit(request) else { return }
      objects = page.objects
      folders = page.commonPrefixes
      cursor = page.cursor
      // A first-page refetch can't see selections made on later pages —
      // prune only when the listing is complete.
      if cursor == nil { selectedKeys.formIntersection(objects.map(\.key)) }
      model.featureCache.set(
        key, R2BrowserSnapshot(objects: objects, commonPrefixes: folders, cursor: cursor))
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
      !loadingMore
    else { return }
    let id = context.accountID
    let requestedCursor = cursor
    loadingMore = true
    defer {
      if matchesCurrentRequest(request) {
        loadingMore = false
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
      objects += page.objects
      for folder in page.commonPrefixes where !folders.contains(folder) {
        folders.append(folder)
      }
      cursor = page.cursor
      model.featureCache.set(
        FeatureCacheKey.r2Objects(accountID: id, bucket: bucket, prefix: listedPrefix),
        R2BrowserSnapshot(objects: objects, commonPrefixes: folders, cursor: cursor))
      error = nil
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
        error = DashL10n.string("Can't read that file's size.")
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
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let plain = ISO8601DateFormatter()
  plain.formatOptions = [.withInternetDateTime]
  guard let date = fractional.date(from: value) ?? plain.date(from: value) else { return value }
  return DashL10n.string("Created \(date.formatted(date: .abbreviated, time: .omitted))")
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
    DispatchQueue.main.async {
      coordinator.attach(from: uiView)
      DispatchQueue.main.async {
        coordinator.attach(from: uiView)
      }
    }
  }

  static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
    coordinator.detach()
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var isEnabled = false
    var onBegan: () -> Void = {}
    var onPaintAt: (CGPoint) -> Void = { _ in }
    var onEnded: () -> Void = {}
    weak var scrollView: UIScrollView?
    weak var recognizer: UIPanGestureRecognizer?
    private var originalMaxTouches: Int?

    func attach(from probe: UIView) {
      guard let scroll = Self.contentScrollView(from: probe) else { return }
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
      let root = enclosingContentView(from: view) ?? view.superview ?? view
      var found: UIScrollView?
      func walk(_ node: UIView) {
        guard found == nil else { return }
        if let scroll = node as? UIScrollView,
          !DashScrollViewConfigurator.isTabPager(scroll),
          scroll.bounds.height > 80
        {
          found = scroll
          return
        }
        for child in node.subviews { walk(child) }
      }
      walk(root)
      return found
    }

    private static func enclosingContentView(from view: UIView) -> UIView? {
      var node: UIView? = view
      while let current = node {
        var responder: UIResponder? = current
        while let next = responder {
          if let viewController = next as? UIViewController,
            !(viewController is UINavigationController),
            !(viewController is UITabBarController),
            let root = viewController.viewIfLoaded,
            current === root || current.isDescendant(of: root)
          {
            return root
          }
          responder = next.next
        }
        node = current.superview
      }
      return nil
    }
  }
}

private struct R2BrowserSnapshot: Sendable {
  let objects: [R2Object]
  let commonPrefixes: [String]
  let cursor: String?
}

/// Holds in-flight upload/batch work for one `R2BucketView`. Kept as a class so
/// NavigationStack can hide the screen under a folder push without cancelling;
/// `deinit` cancels when the screen is popped off the stack.
@Observable
private final class R2BucketWork {
  var upload: Task<Void, Never>?
  var batch: Task<Void, Never>?

  func cancelAndRelease() {
    let upload = upload
    let batch = batch
    self.upload = nil
    self.batch = nil
    upload?.cancel()
    batch?.cancel()
  }

  deinit {
    upload?.cancel()
    batch?.cancel()
  }
}

struct KVNamespacesView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @AppStorage(RecentResources.key) private var recentsRaw = ""
  @State private var namespaces: [KVNamespace] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !namespaces.isEmpty,
      retry: { Task { await load() } }
    ) {
      if namespaces.isEmpty {
        DashEmptyState(
          icon: SolarAsset.Content.pinList,
          title: DashL10n.string("No namespaces"),
          message: DashL10n.string("Create a namespace in the dashboard or with Wrangler."),
          actionTitle: "Open KV docs",
          action: { openURL(StorageExternalURL.kvGuide) }
        )
      } else {
        dashListCard {
          dashListCardRows(items: namespaces) { namespace in
            // The namespace screen only ever sees the id, so the human title
            // has to enter the recents here, at the navigation boundary.
            DashListGroupLink(
              value: .kvNamespace(namespace.id),
              onNavigate: { recordRecent(namespace) }
            ) {
              DashListRow(title: namespace.title, icon: SolarAsset.Content.pinList)
                .accessibilityLabel("\(namespace.title), KV namespace")
            }
          }
        }
      }
    }
    .refreshable { await load(force: true) }
    .task { await load() }
    .onAppear { reloadIfInvalidated() }
  }

  /// The cache drops under this list on memory pressure while it stays alive
  /// below a child screen; refresh on return when the cache went cold.
  private func reloadIfInvalidated() {
    guard let id = model.activeAccountID, !namespaces.isEmpty else { return }
    let cached: [KVNamespace]? = model.featureCache.get(FeatureCacheKey.kvNamespaces(id))
    if cached == nil { Task { await load(force: true) } }
  }

  private func recordRecent(_ namespace: KVNamespace) {
    guard let accountID = model.activeAccountID else { return }
    recentsRaw = RecentResources.recording(
      RecentResource(
        accountID: accountID, kind: .kvNamespace, resourceID: namespace.id,
        title: namespace.title),
      in: recentsRaw)
  }

  private func load(force: Bool = false) async {
    guard let id = model.activeAccountID else { return }
    let key = FeatureCacheKey.kvNamespaces(id)
    if !force, let cached: [KVNamespace] = model.featureCache.get(key) {
      namespaces = cached
      loading = false
      error = nil
      return
    }
    if namespaces.isEmpty { loading = true }
    do {
      namespaces = try await model.client.listKVNamespaces(accountID: id).items
      model.featureCache.set(key, namespaces)
      error = nil
    } catch { self.error = error.dashActionableMessage }
    loading = false
  }
}

struct KVNamespaceView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.openURL) private var openURL
  let namespaceID: String
  @State private var keys: [KVKey] = []
  @State private var cursor: String?
  @State private var showsCreateKey = false
  @State private var error: String?
  @State private var loading = true
  @State private var loadingMore = false

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
      retry: { Task { await load() } }
    ) {
      if keys.isEmpty {
        DashEmptyState(
          icon: SolarAsset.Content.key,
          title: "No keys",
          message: featureAllowsWrites
            ? DashL10n.string("Create a key to store a value in this namespace.")
            : DashL10n.string("Create keys in the Cloudflare dashboard or with Wrangler."),
          actionTitle: featureAllowsWrites
            ? DashL10n.string("Create key") : DashL10n.string("Open KV docs"),
          action: featureAllowsWrites
            ? { showsCreateKey = true } : { openURL(StorageExternalURL.kvGuide) }
        )
      } else {
        dashListCard {
          dashListCardRows(items: keys) { key in
            DashListGroupLink(value: .kvKey(namespaceID: namespaceID, key: key.name)) {
              DashListRow(title: key.name, icon: SolarAsset.Content.key)
            }
            .accessibilityLabel(key.name)
          }
        }
      }
      if canLoadMore {
        DashLoadMoreFooter(loaded: keys.count, noun: "keys", isLoading: loadingMore) {
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
    .task { await load() }
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
    guard let id = model.activeAccountID else { return }
    model.featureCache.remove(prefix: "kvKeys:\(id):\(namespaceID):")
  }

  /// Key detail deletes drop the cache while this list stays alive underneath;
  /// refresh on return when the entry went cold.
  private func reloadIfKeysInvalidated() {
    guard let id = model.activeAccountID, !keys.isEmpty else { return }
    let cached: CursorPageSnapshot<KVKey>? = model.featureCache.get(
      FeatureCacheKey.kvKeys(accountID: id, namespaceID: namespaceID, prefix: ""))
    if cached == nil { Task { await load(force: true) } }
  }

  private func load(force: Bool = false) async {
    guard let id = model.activeAccountID else { return }
    let key = FeatureCacheKey.kvKeys(accountID: id, namespaceID: namespaceID, prefix: "")
    if !force, let cached: CursorPageSnapshot<KVKey> = model.featureCache.get(key) {
      keys = cached.items
      cursor = cached.cursor
      error = nil
      loading = false
      return
    }
    do {
      let page = try await model.client.listKVKeys(accountID: id, namespaceID: namespaceID)
      keys = page.items
      cursor = page.cursor
      model.featureCache.set(key, CursorPageSnapshot(items: keys, cursor: cursor))
      error = nil
    } catch {
      if error.dashIsCancellation { return }
      self.error = error.dashActionableMessage
    }
    loading = false
  }

  private func loadMore() async {
    guard let id = model.activeAccountID, canLoadMore, !loadingMore else { return }
    loadingMore = true
    defer { loadingMore = false }
    do {
      let page = try await model.client.listKVKeys(
        accountID: id, namespaceID: namespaceID, cursor: cursor)
      keys += page.items
      cursor = page.cursor
      model.featureCache.set(
        FeatureCacheKey.kvKeys(accountID: id, namespaceID: namespaceID, prefix: ""),
        CursorPageSnapshot(items: keys, cursor: cursor))
      error = nil
    } catch {
      if error.dashIsCancellation { return }
      self.error = error.dashActionableMessage
    }
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
  @State private var creating = false
  @State private var error: String?

  var body: some View {
    DashFormSheet(
      saveTitle: DashL10n.string("Create bucket"),
      isSaving: creating,
      canSave: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      onSave: { Task { await create() } },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          if let error {
            DashNotice(kind: .error, message: error)
          }
          DashFormField(label: DashL10n.string("Bucket name"), text: $name)
          Text(DashL10n.string("Use lowercase letters, numbers, and hyphens."))
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    )
  }

  private func create() async {
    guard let accountID = model.activeAccountID else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    creating = true
    error = nil
    defer { creating = false }
    do {
      _ = try await model.client.createR2Bucket(accountID: accountID, name: trimmed)
      model.toasts.success(DashL10n.string("Created successfully."))
      onCreated()
      dismiss()
    } catch {
      self.error = error.dashActionableMessage
    }
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
  @State private var creating = false
  @State private var error: String?

  private var canFormat: Bool { KVJSONFormatting.isValidJSON(value) }

  var body: some View {
    DashFormSheet(
      saveTitle: DashL10n.string("Create key"),
      isSaving: creating,
      canSave: !keyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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
            DashKVCodeEditor(text: $value, editable: true)
              .frame(minHeight: 160)
              .clipShape(
                RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
            Button {
              if let pretty = KVJSONFormatting.prettyPrinted(value) { value = pretty }
            } label: {
              Text(DashL10n.string("Format"))
                .dashTextStyle(.buttonMedium)
                .foregroundStyle(canFormat ? DashTheme.strong : DashTheme.placeholder)
            }
            .buttonStyle(DashPressButtonStyle())
            .disabled(!canFormat)
          }
        }
      }
    )
  }

  private func create() async {
    guard let accountID = model.activeAccountID else { return }
    let trimmed = keyName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    creating = true
    error = nil
    defer { creating = false }
    do {
      try await model.client.putKVValue(
        accountID: accountID, namespaceID: namespaceID, key: trimmed, data: Data(value.utf8))
      model.toasts.success(DashL10n.string("Created successfully."))
      onCreated()
      dismiss()
    } catch {
      self.error = error.dashActionableMessage
    }
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
  let namespaceID: String
  let key: String

  @State private var mode: Mode = .viewing
  @State private var value = ""
  @State private var committedValue = ""
  @State private var error: String?
  @State private var loaded = false
  @State private var saving = false
  @State private var deleting = false
  @State private var confirmingDelete = false
  @State private var copied = false

  private var canFormat: Bool { KVJSONFormatting.isValidJSON(value) }

  var body: some View {
    GeometryReader { geo in
      DashConfirmMorph(
        confirming: $confirmingDelete,
        message: DashL10n.string("Permanently delete the key \(key)."),
        isBusy: confirmingDelete ? deleting : saving,
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
              if loaded {
                DashKVCodeEditor(text: $value, editable: mode == .editing)
                  .frame(maxWidth: .infinity)
                  .frame(height: max(280, geo.size.height - 220))
                  .clipShape(
                    RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
              } else if error == nil {
                HStack(spacing: 10) {
                  DashLoadingRing(color: DashTheme.subtle)
                  Text(DashL10n.string("Loading value…"))
                    .dashTextStyle(.supporting)
                    .foregroundStyle(DashTheme.subtle)
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
              }
            }

            if let error, !confirmingDelete {
              DashNotice(kind: .error, message: error)
            }

            if loaded {
              accessoryRow
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        if featureAllowsWrites, mode == .viewing, loaded, !confirmingDelete {
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
    .task { await load() }
  }

  @ViewBuilder private var accessoryRow: some View {
    switch mode {
    case .viewing:
      DashSecondaryPillButton(
        title: copied ? DashL10n.string("Copied") : DashL10n.string("Copy")
      ) {
        UIPasteboard.general.string = value
        withAnimation(DashTheme.Motion.morph) { copied = true }
        Task {
          try? await Task.sleep(for: .seconds(1.6))
          withAnimation(DashTheme.Motion.morph) { copied = false }
        }
      }
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

        Button {
          if let pretty = KVJSONFormatting.prettyPrinted(value) { value = pretty }
        } label: {
          Text(DashL10n.string("Format"))
            .dashTextStyle(.buttonMedium)
            .foregroundStyle(canFormat ? DashTheme.strong : DashTheme.placeholder)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(DashPressButtonStyle())
        .disabled(!canFormat)
      }
    }
  }

  private var footerTitle: String? {
    if confirmingDelete { return "Delete" }
    switch mode {
    case .viewing:
      return featureAllowsWrites && loaded ? DashL10n.string("Edit") : nil
    case .editing:
      return DashL10n.string("Save")
    }
  }

  private var footerEnabled: Bool {
    if confirmingDelete { return true }
    switch mode {
    case .viewing: return featureAllowsWrites && loaded
    case .editing: return loaded && !saving
    }
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

  private func invalidateKeys() {
    guard let id = model.activeAccountID else { return }
    model.featureCache.remove(prefix: "kvKeys:\(id):\(namespaceID):")
  }

  private func load() async {
    guard let id = model.activeAccountID else { return }
    do {
      let raw = String(
        decoding: try await model.client.getKVValue(
          accountID: id, namespaceID: namespaceID, key: key), as: UTF8.self)
      let prepared = KVJSONFormatting.preparedForDisplay(raw)
      value = prepared
      committedValue = prepared
      loaded = true
      error = nil
    } catch { self.error = error.dashActionableMessage }
  }

  private func save() async {
    guard featureAllowsWrites, let id = model.activeAccountID else { return }
    saving = true
    error = nil
    defer { saving = false }
    do {
      try await model.client.putKVValue(
        accountID: id, namespaceID: namespaceID, key: key, data: Data(value.utf8))
      committedValue = value
      invalidateKeys()
      model.toasts.success(DashL10n.string("Saved successfully."))
      withAnimation(DashTheme.Motion.morph) { mode = .viewing }
    } catch { self.error = error.dashActionableMessage }
  }

  private func deleteKey() async {
    guard featureAllowsWrites, let id = model.activeAccountID else { return }
    deleting = true
    error = nil
    defer { deleting = false }
    do {
      try await model.client.deleteKVValue(
        accountID: id, namespaceID: namespaceID, key: key)
      invalidateKeys()
      model.toasts.success(DashL10n.string("Deleted successfully."))
      navigator?.pop()
    } catch { self.error = error.dashActionableMessage }
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

/// Destination-prefix form for a batch move. The heavy lifting stays in the
/// browser (progress card, cancellation); this only normalizes the prefix.
private struct R2MoveForm: View {
  @Environment(\.dashTrayDismiss) private var dismiss
  let currentFolder: String
  let count: Int
  let onMove: (String) -> Void
  @State private var destination: String

  init(currentFolder: String, count: Int, onMove: @escaping (String) -> Void) {
    self.currentFolder = currentFolder
    self.count = count
    self.onMove = onMove
    _destination = State(initialValue: currentFolder)
  }

  private var normalized: String {
    var value = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasPrefix("/") { value.removeFirst() }
    if !value.isEmpty && !value.hasSuffix("/") { value += "/" }
    return value
  }

  var body: some View {
    DashFormSheet(
      saveTitle: DashL10n.string(
        "Move \(count) \(count == 1 ? DashL10n.string("object") : DashL10n.string("objects"))"
      ),
      canSave: normalized != currentFolder,
      onSave: {
        onMove(normalized)
        dismiss()
      },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          DashFormField(label: "Destination folder", text: $destination)
          Text(
            "Folders are key prefixes — use / to nest, leave empty for the bucket root. Files keep their names."
          )
          .dashTextStyle(.caption)
          .foregroundStyle(DashTheme.subtle)
        }
      }
    )
  }
}

extension String { fileprivate var nilIfEmpty: String? { isEmpty ? nil : self } }
