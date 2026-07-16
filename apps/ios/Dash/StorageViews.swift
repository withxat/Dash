import CloudflareAPI
import SwiftUI
import UniformTypeIdentifiers

struct R2BucketsView: View {
  @Environment(AppModel.self) private var model
  @State private var buckets: [R2Bucket] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !buckets.isEmpty,
      retry: { Task { await load() } }
    ) {
      if buckets.isEmpty {
        DashEmptyState(
          icon: SolarAsset.box,
          title: "No buckets yet",
          message: "No R2 buckets in this account."
        )
      } else {
        DashListCard {
          DashListCardRows(items: buckets) { bucket in
            DashListGroupLink(value: .r2Bucket(bucket.name)) {
              DashListRow(
                title: bucket.name,
                subtitle: bucket.creationDate,
                icon: SolarAsset.box
              )
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

struct R2BucketView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  let bucket: String
  @State private var objects: [R2Object] = []
  @State private var folders: [String] = []
  @State private var cursor: String?
  @State private var folderPrefix = ""
  @State private var prefix = ""
  @State private var error: String?
  // First load only — `.task(id: requestPrefix)` reloads per keystroke or folder, and
  // re-arming this would flash the full-screen spinner while typing.
  @State private var loading = true
  @State private var loadingMore = false
  @State private var importsFile = false
  @State private var selectedObject: R2Object?

  private var canLoadMore: Bool { cursor?.isEmpty == false }
  private var requestPrefix: String { folderPrefix + prefix }
  private var parentPrefix: String? {
    guard !folderPrefix.isEmpty else { return nil }
    var parent = folderPrefix
    if parent.hasSuffix("/") { parent.removeLast() }
    guard let separator = parent.lastIndex(of: "/") else { return "" }
    return String(parent[...separator])
  }
  private var currentFolderName: String {
    guard !folderPrefix.isEmpty else { return bucket }
    return folderPrefix.dropLast().split(separator: "/").last.map(String.init) ?? bucket
  }

  var body: some View {
    DashFeatureList(
      search: $prefix,
      prompt: "Starts with",
      isLoading: loading,
      error: error,
      hasContent: !objects.isEmpty || !folders.isEmpty || parentPrefix != nil,
      retry: { Task { await load() } }
    ) {
      if parentPrefix != nil || !folders.isEmpty || !objects.isEmpty {
        DashListCard {
          if let parentPrefix {
            Button {
              navigate(to: parentPrefix)
            } label: {
              DashListRow(
                title: "Parent folder",
                subtitle: "Up one level",
                icon: SolarAsset.chevronLeft,
                iconColor: DashTheme.iconMuted,
                showsChevron: false
              )
            }
            .buttonStyle(DashPressButtonStyle())
          }
          ForEach(folders, id: \.self) { folder in
            Button {
              navigate(to: folder)
            } label: {
              DashListRow(
                title: folderName(folder),
                subtitle: "Virtual folder",
                icon: SolarAsset.boxMinimalistic,
                iconColor: DashTheme.iconMuted
              )
            }
            .buttonStyle(DashPressButtonStyle())
          }
          DashListCardRows(items: objects) { object in
            Button {
              selectedObject = object
            } label: {
              DashListRow(
                title: objectName(object.key),
                subtitle: object.size.map {
                  ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                },
                icon: SolarAsset.file,
                iconColor: DashTheme.iconMuted,
                showsChevron: false
              )
            }
            .buttonStyle(DashPressButtonStyle())
          }
        }
      }
      if folders.isEmpty && objects.isEmpty {
        DashEmptyState(
          icon: SolarAsset.box,
          title: prefix.isEmpty
            ? (folderPrefix.isEmpty ? "Empty bucket" : "Empty folder") : "Nothing found",
          message: prefix.isEmpty
            ? (folderPrefix.isEmpty
              ? (featureAllowsWrites
                ? "Upload a file to get started." : "This bucket has no objects.")
              : "This virtual folder has no objects.")
            : "Nothing in this folder starts with \(prefix)."
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
    .navigationTitle(currentFolderName)
    .toolbar {
      if featureAllowsWrites {
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarIconButton(asset: SolarAsset.upload, accessibilityLabel: "Upload file") {
            importsFile = true
          }
        }
        .dashSeparateToolbarBackground()
      }
    }
    .fileImporter(isPresented: $importsFile, allowedContentTypes: [.data]) { result in
      if case .success(let url) = result { Task { await upload(url) } }
    }
    .dashTray(
      item: $selectedObject,
      title: { $0.key },
      content: { object in
        DashDetailTray(fields: object.detailFields) {
          if let accountID = model.activeAccountID {
            ShareLink(
              item: R2ObjectExport(
                client: model.client, accountID: accountID, bucket: bucket, key: object.key),
              preview: SharePreview(object.key)
            ) {
              Text("Download")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(DashTheme.strong)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(DashTheme.recessed, in: DashTheme.pillShape)
                .overlay {
                  DashTheme.pillShape.stroke(DashTheme.line, lineWidth: 0.5)
                }
            }
            .buttonStyle(DashPressButtonStyle())
          }
        }
      }
    )
    .refreshable { await load(force: true) }.task(id: requestPrefix) { await load() }
  }
  private func load(force: Bool = false) async {
    guard let id = model.activeAccountID else { return }
    let key = FeatureCacheKey.r2Objects(accountID: id, bucket: bucket, prefix: requestPrefix)
    if !force, let cached: R2BrowserSnapshot = model.featureCache.get(key) {
      objects = cached.objects
      folders = cached.commonPrefixes
      cursor = cached.cursor
      error = nil
      loading = false
      return
    }
    do {
      let page = try await model.client.listR2Objects(
        accountID: id, bucket: bucket, prefix: requestPrefix.nilIfEmpty, delimiter: "/")
      objects = page.objects
      folders = page.commonPrefixes
      cursor = page.cursor
      model.featureCache.set(
        key, R2BrowserSnapshot(objects: objects, commonPrefixes: folders, cursor: cursor))
      error = nil
    } catch { self.error = error.dashActionableMessage }
    loading = false
  }

  private func loadMore() async {
    guard let id = model.activeAccountID, canLoadMore, !loadingMore else { return }
    loadingMore = true
    defer { loadingMore = false }
    do {
      let page = try await model.client.listR2Objects(
        accountID: id, bucket: bucket, cursor: cursor, prefix: requestPrefix.nilIfEmpty,
        delimiter: "/")
      objects += page.objects
      for folder in page.commonPrefixes where !folders.contains(folder) {
        folders.append(folder)
      }
      cursor = page.cursor
      model.featureCache.set(
        FeatureCacheKey.r2Objects(accountID: id, bucket: bucket, prefix: requestPrefix),
        R2BrowserSnapshot(objects: objects, commonPrefixes: folders, cursor: cursor))
      error = nil
    } catch { self.error = error.dashActionableMessage }
  }
  /// `putR2Object` holds the body in memory and URLSession copies it again, so
  /// the ceiling here is the phone's, not Cloudflare's — a single-part PUT is
  /// good for ~5 GiB, but iOS jetsams the app long before that.
  private static let uploadSizeLimit = 100 * 1024 * 1024

  private func upload(_ url: URL) async {
    guard let id = model.activeAccountID else { return }
    do {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
        error = "Can't read that file's size."
        return
      }
      guard size <= Self.uploadSizeLimit else {
        error =
          "\(url.lastPathComponent) is \(size.formatted(.byteCount(style: .file))). Dash uploads files up to \(Self.uploadSizeLimit.formatted(.byteCount(style: .file))) — use wrangler or the dashboard for this one."
        return
      }
      let data = try Data(contentsOf: url)
      try await model.client.putR2Object(
        accountID: id, bucket: bucket, key: folderPrefix + url.lastPathComponent, data: data,
        contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType)
      model.featureCache.remove(
        FeatureCacheKey.r2Objects(accountID: id, bucket: bucket, prefix: requestPrefix))
      await load(force: true)
    } catch { self.error = error.dashActionableMessage }
  }
  private func navigate(to prefix: String) {
    folderPrefix = prefix
    self.prefix = ""
    objects = []
    folders = []
    cursor = nil
    error = nil
    selectedObject = nil
    loading = true
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

private struct R2BrowserSnapshot: Sendable {
  let objects: [R2Object]
  let commonPrefixes: [String]
  let cursor: String?
}

struct KVNamespacesView: View {
  @Environment(AppModel.self) private var model
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
          icon: SolarAsset.pinList,
          title: "No namespaces",
          message: "No KV namespaces in this account."
        )
      } else {
        DashListCard {
          DashListCardRows(items: namespaces) { namespace in
            DashListGroupLink(value: .kvNamespace(namespace.id)) {
              DashListRow(title: namespace.title, icon: SolarAsset.pinList)
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
  let namespaceID: String
  @State private var keys: [KVKey] = []
  @State private var cursor: String?
  @State private var prefix = ""
  @State private var selected: KVKey?
  @State private var error: String?
  // First load only — `.task(id: prefix)` reloads per keystroke, and
  // re-arming this would flash the full-screen spinner while typing.
  @State private var loading = true
  @State private var loadingMore = false

  private var canLoadMore: Bool { cursor?.isEmpty == false }

  var body: some View {
    DashFeatureList(
      search: $prefix,
      prompt: "Filter by key prefix",
      isLoading: loading,
      error: error,
      hasContent: !keys.isEmpty,
      retry: { Task { await load() } }
    ) {
      if keys.isEmpty {
        DashEmptyState(
          icon: SolarAsset.key,
          title: prefix.isEmpty ? "No keys" : "Nothing found",
          message: prefix.isEmpty
            ? "Keys in this namespace will appear here."
            : "No key matches \(prefix)."
        )
      } else {
        DashListCard {
          DashListCardRows(items: keys) { key in
            Button {
              selected = key
            } label: {
              DashListRow(title: key.name, icon: SolarAsset.key)
            }
            .buttonStyle(DashPressButtonStyle())
          }
        }
      }
      if canLoadMore {
        DashLoadMoreFooter(loaded: keys.count, noun: "keys", isLoading: loadingMore) {
          Task { await loadMore() }
        }
      }
    }
    .navigationTitle("KV keys")
    .task(id: prefix) {
      await load()
    }.refreshable { await load(force: true) }
    .dashTray(
      item: $selected,
      title: { $0.name },
      content: { key in
        KVValueEditor(namespaceID: namespaceID, key: key.name)
      }
    )
  }
  private func load(force: Bool = false) async {
    guard let id = model.activeAccountID else { return }
    let key = FeatureCacheKey.kvKeys(accountID: id, namespaceID: namespaceID, prefix: prefix)
    if !force, let cached: CursorPageSnapshot<KVKey> = model.featureCache.get(key) {
      keys = cached.items
      cursor = cached.cursor
      error = nil
      loading = false
      return
    }
    do {
      let page = try await model.client.listKVKeys(
        accountID: id, namespaceID: namespaceID, prefix: prefix.nilIfEmpty)
      keys = page.items
      cursor = page.cursor
      model.featureCache.set(key, CursorPageSnapshot(items: keys, cursor: cursor))
      error = nil
    } catch { self.error = error.dashActionableMessage }
    loading = false
  }

  private func loadMore() async {
    guard let id = model.activeAccountID, canLoadMore, !loadingMore else { return }
    loadingMore = true
    defer { loadingMore = false }
    do {
      let page = try await model.client.listKVKeys(
        accountID: id, namespaceID: namespaceID, cursor: cursor, prefix: prefix.nilIfEmpty)
      keys += page.items
      cursor = page.cursor
      model.featureCache.set(
        FeatureCacheKey.kvKeys(accountID: id, namespaceID: namespaceID, prefix: prefix),
        CursorPageSnapshot(items: keys, cursor: cursor))
      error = nil
    } catch { self.error = error.dashActionableMessage }
  }
}

/// Edits the value of one existing KV key. Creating and deleting keys is a
/// wrangler job — this exists for the flag you need to flip from a phone.
private struct KVValueEditor: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let namespaceID: String
  let key: String
  var onChanged: () -> Void = {}
  @State private var value = ""
  @State private var error: String?
  // Saving before the fetch lands would overwrite the stored value with "".
  @State private var loaded = false

  var body: some View {
    DashFormSheet(
      canSave: loaded,
      onSave: { Task { await save() } },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          DashFormCodeField(label: "Value", text: $value)
          if let error {
            DashNotice(kind: .error, message: error)
          }
        }
      }
    )
    .task { await load() }
  }
  private func load() async {
    guard let id = model.activeAccountID else { return }
    do {
      value = String(
        decoding: try await model.client.getKVValue(
          accountID: id, namespaceID: namespaceID, key: key), as: UTF8.self)
      loaded = true
    } catch { self.error = error.dashActionableMessage }
  }
  private func save() async {
    guard let id = model.activeAccountID else { return }
    do {
      try await model.client.putKVValue(
        accountID: id, namespaceID: namespaceID, key: key, data: Data(value.utf8))
      dismiss()
    } catch { self.error = error.dashActionableMessage }
  }
}

private struct R2ObjectExport: Transferable {
  let client: CloudflareClient
  let accountID: String
  let bucket: String
  let key: String

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .data) { export in
      let data = try await export.client.getR2Object(
        accountID: export.accountID, bucket: export.bucket, key: export.key)
      let filename = export.key.split(separator: "/").last.map(String.init) ?? export.key
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
      try data.write(to: url)
      return SentTransferredFile(url)
    }
  }
}

extension String { fileprivate var nilIfEmpty: String? { isEmpty ? nil : self } }
