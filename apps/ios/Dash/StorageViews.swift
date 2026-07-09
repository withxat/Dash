import CloudflareAPI
import SwiftUI
import UniformTypeIdentifiers

struct R2BucketsView: View {
  @Environment(AppModel.self) private var model
  @State private var buckets: [R2Bucket] = []
  @State private var error: String?
  @State private var loading = true
  @State private var newName = ""
  @State private var creates = false

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      retry: { Task { await load() } }
    ) {
      if buckets.isEmpty {
        DashEmptyState(
          icon: SolarAsset.box,
          title: "No buckets yet",
          message: "Create a bucket with the add button."
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
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          creates = true
        } label: {
          DashToolbarActionIcon(asset: SolarAsset.plus)
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel("New bucket")
      }
    }
    .dashTray(isPresented: $creates, title: "New bucket") {
      DashFormSheet(
        saveTitle: "Create",
        canSave: !newName.isEmpty,
        onSave: { Task { await create() } },
        content: {
          DashFormField(label: "Bucket name", text: $newName)
        }
      )
    }
    .refreshable { await load(force: true) }
    .task { await load() }
    .onAppear { reloadIfInvalidated() }
  }

  /// A child (bucket screen) may delete a bucket and clear the cache while this
  /// list stays alive below it; refresh on return when the cache went cold.
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
    } catch { self.error = error.localizedDescription }
    loading = false
  }
  private func create() async {
    guard let id = model.activeAccountID, !newName.isEmpty else { return }
    do {
      _ = try await model.client.createR2Bucket(accountID: id, name: newName)
      newName = ""
      creates = false
      model.featureCache.remove(FeatureCacheKey.r2Buckets(id))
      await load(force: true)
    } catch { self.error = error.localizedDescription }
  }
}

struct R2BucketView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let bucket: String
  @State private var objects: [R2Object] = []
  @State private var prefix = ""
  @State private var error: String?
  // First load only — `.task(id: prefix)` reloads per keystroke, and
  // re-arming this would flash the full-screen spinner while typing.
  @State private var loading = true
  @State private var importsFile = false
  @State private var showsMore = false
  @State private var selectedObject: R2Object?
  @State private var deletingObject = false

  var body: some View {
    DashFeatureList(
      search: $prefix,
      prompt: "Filter by prefix",
      isLoading: loading,
      error: error,
      retry: { Task { await load() } }
    ) {
      if objects.isEmpty {
        DashEmptyState(
          icon: SolarAsset.box,
          title: prefix.isEmpty ? "Empty bucket" : "Nothing found",
          message: prefix.isEmpty
            ? "Upload a file to get started."
            : "No object matches \(prefix)."
        )
      } else {
        DashListCard {
          DashListCardRows(items: objects) { object in
            Button {
              selectedObject = object
            } label: {
              DashListRow(
                title: object.key,
                subtitle: object.size.map {
                  ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                },
                icon: SolarAsset.file,
                iconColor: DashTheme.text,
                showsChevron: false
              )
            }
            .buttonStyle(DashPressButtonStyle())
          }
        }
      }
    }
    .navigationTitle(bucket)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          importsFile = true
        } label: {
          DashToolbarActionIcon(asset: SolarAsset.upload)
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel("Upload file")
      }
      ToolbarItem(placement: .topBarTrailing) {
        DashMoreButton(isPresented: $showsMore)
      }
    }
    .fileImporter(isPresented: $importsFile, allowedContentTypes: [.data]) { result in
      if case .success(let url) = result { Task { await upload(url) } }
    }
    .dashMoreMenu(
      isPresented: $showsMore,
      title: bucket,
      actions: [
        DashDangerAction(
          title: "Delete bucket",
          message:
            "Permanently delete \(bucket) and everything in it. This cannot be undone."
        ) {
          await deleteBucket()
        }
      ]
    )
    .dashTray(
      item: $selectedObject,
      title: { $0.key },
      content: { object in
        DashDetailTray(
          fields: object.detailFields,
          deleteMessage: "Permanently delete \(object.key) from \(bucket).",
          isDeleting: deletingObject,
          onDelete: { Task { await delete(object) } }
        ) {
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
    .refreshable { await load(force: true) }.task(id: prefix) { await load() }
  }
  private func deleteBucket() async {
    guard let id = model.activeAccountID else { return }
    try? await model.client.deleteR2Bucket(accountID: id, name: bucket)
    model.featureCache.remove(FeatureCacheKey.r2Buckets(id))
    dismiss()
  }
  private func load(force: Bool = false) async {
    guard let id = model.activeAccountID else { return }
    let key = FeatureCacheKey.r2Objects(accountID: id, bucket: bucket, prefix: prefix)
    if !force, let cached: [R2Object] = model.featureCache.get(key) {
      objects = cached
      error = nil
      loading = false
      return
    }
    do {
      objects = try await model.client.listR2Objects(
        accountID: id, bucket: bucket, prefix: prefix.nilIfEmpty
      ).items
      model.featureCache.set(key, objects)
      error = nil
    } catch { self.error = error.localizedDescription }
    loading = false
  }
  private func upload(_ url: URL) async {
    guard let id = model.activeAccountID else { return }
    do {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let data = try Data(contentsOf: url)
      try await model.client.putR2Object(
        accountID: id, bucket: bucket, key: url.lastPathComponent, data: data,
        contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType)
      model.featureCache.remove(
        FeatureCacheKey.r2Objects(accountID: id, bucket: bucket, prefix: prefix))
      await load(force: true)
    } catch { self.error = error.localizedDescription }
  }
  private func delete(_ object: R2Object) async {
    guard let id = model.activeAccountID else { return }
    deletingObject = true
    try? await model.client.deleteR2Object(accountID: id, bucket: bucket, key: object.key)
    model.featureCache.remove(
      FeatureCacheKey.r2Objects(accountID: id, bucket: bucket, prefix: prefix))
    selectedObject = nil
    await load(force: true)
    deletingObject = false
  }
}

struct KVNamespacesView: View {
  @Environment(AppModel.self) private var model
  @State private var namespaces: [KVNamespace] = []
  @State private var error: String?
  @State private var loading = true
  @State private var creates = false
  @State private var newTitle = ""

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      retry: { Task { await load() } }
    ) {
      if namespaces.isEmpty {
        DashEmptyState(
          icon: SolarAsset.pinList,
          title: "No namespaces",
          message: "Create a namespace with the add button."
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
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          creates = true
        } label: {
          DashToolbarActionIcon(asset: SolarAsset.plus)
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel("New namespace")
      }
    }
    .dashTray(isPresented: $creates, title: "New namespace") {
      DashFormSheet(
        saveTitle: "Create",
        canSave: !newTitle.isEmpty,
        onSave: { Task { await create() } },
        content: {
          DashFormField(label: "Namespace title", text: $newTitle)
        }
      )
    }
    .refreshable { await load(force: true) }
    .task { await load() }
    .onAppear { reloadIfInvalidated() }
  }

  /// A child (namespace screen) may delete a namespace and clear the cache while
  /// this list stays alive below it; refresh on return when the cache went cold.
  private func reloadIfInvalidated() {
    guard let id = model.activeAccountID, !namespaces.isEmpty else { return }
    let cached: [KVNamespace]? = model.featureCache.get(FeatureCacheKey.kvNamespaces(id))
    if cached == nil { Task { await load(force: true) } }
  }

  private func create() async {
    guard let id = model.activeAccountID, !newTitle.isEmpty else { return }
    do {
      _ = try await model.client.mutate(
        path: "/accounts/\(id)/storage/kv/namespaces", method: "POST",
        body: ["title": .string(newTitle)])
      newTitle = ""
      creates = false
      model.featureCache.remove(FeatureCacheKey.kvNamespaces(id))
      await load(force: true)
    } catch { self.error = error.localizedDescription }
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
    } catch { self.error = error.localizedDescription }
    loading = false
  }
}

struct KVNamespaceView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismissScreen
  let namespaceID: String
  @State private var keys: [KVKey] = []
  @State private var prefix = ""
  @State private var selected: KVKey?
  @State private var error: String?
  // First load only — `.task(id: prefix)` reloads per keystroke, and
  // re-arming this would flash the full-screen spinner while typing.
  @State private var loading = true
  @State private var creates = false
  @State private var showsMore = false

  var body: some View {
    DashFeatureList(
      search: $prefix,
      prompt: "Filter by key prefix",
      isLoading: loading,
      error: error,
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
    }
    .navigationTitle("KV keys")
    .task(id: prefix) {
      await load()
    }.refreshable { await load(force: true) }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          creates = true
        } label: {
          DashToolbarActionIcon(asset: SolarAsset.plus)
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel("New key")
      }
      ToolbarItem(placement: .topBarTrailing) {
        DashMoreButton(isPresented: $showsMore)
      }
    }
    .dashTray(
      item: $selected,
      title: { $0.name },
      content: { key in
        KVValueEditor(namespaceID: namespaceID, existingKey: key.name) {
          reloadKeys()
        }
      }
    )
    .dashTray(isPresented: $creates, title: "New key") {
      KVValueEditor(namespaceID: namespaceID, existingKey: nil) {
        reloadKeys()
      }
    }
    .dashMoreMenu(
      isPresented: $showsMore,
      title: "KV namespace",
      actions: [
        DashDangerAction(
          title: "Delete namespace",
          message: "Permanently delete this namespace and every key in it."
        ) {
          await deleteNamespace()
        }
      ]
    )
  }
  private func reloadKeys() {
    guard let id = model.activeAccountID else { return }
    model.featureCache.remove(
      FeatureCacheKey.kvKeys(accountID: id, namespaceID: namespaceID, prefix: prefix))
    Task { await load(force: true) }
  }
  private func deleteNamespace() async {
    guard let id = model.activeAccountID else { return }
    _ = try? await model.client.mutate(
      path: "/accounts/\(id)/storage/kv/namespaces/\(namespaceID)", method: "DELETE")
    model.featureCache.remove(FeatureCacheKey.kvNamespaces(id))
    dismissScreen()
  }
  private func load(force: Bool = false) async {
    guard let id = model.activeAccountID else { return }
    let key = FeatureCacheKey.kvKeys(accountID: id, namespaceID: namespaceID, prefix: prefix)
    if !force, let cached: [KVKey] = model.featureCache.get(key) {
      keys = cached
      error = nil
      loading = false
      return
    }
    do {
      keys = try await model.client.listKVKeys(
        accountID: id, namespaceID: namespaceID, prefix: prefix.nilIfEmpty
      ).items
      model.featureCache.set(key, keys)
      error = nil
    } catch { self.error = error.localizedDescription }
    loading = false
  }
}

/// Edits an existing KV value (`existingKey` set) or creates a new key/value
/// pair (`existingKey` nil — adds a key-name field, skips the value fetch).
private struct KVValueEditor: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let namespaceID: String
  let existingKey: String?
  var onChanged: () -> Void = {}
  @State private var newKeyName = ""
  @State private var value = ""
  @State private var error: String?
  // Saving before the fetch lands would overwrite the stored value with "".
  @State private var loaded = false
  @State private var deleting = false

  private var keyName: String { existingKey ?? newKeyName }
  private var canSave: Bool {
    existingKey != nil ? loaded : !newKeyName.isEmpty
  }

  var body: some View {
    DashFormSheet(
      canSave: canSave,
      deleteMessage: existingKey.map { "Permanently delete \($0) from this namespace." },
      isDeleting: deleting,
      onDelete: existingKey != nil ? { Task { await delete() } } : nil,
      onSave: { Task { await save() } },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          if existingKey == nil {
            DashFormField(label: "Key", text: $newKeyName)
          }
          DashFormCodeField(label: "Value", text: $value)
          if let error {
            DashNotice(kind: .error, message: error)
          }
        }
      }
    )
    .task { if existingKey != nil { await load() } }
  }
  private func delete() async {
    guard let id = model.activeAccountID else { return }
    deleting = true
    try? await model.client.deleteKVValue(accountID: id, namespaceID: namespaceID, key: keyName)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    onChanged()
    dismiss()
  }
  private func load() async {
    guard let id = model.activeAccountID else { return }
    do {
      value = String(
        decoding: try await model.client.getKVValue(
          accountID: id, namespaceID: namespaceID, key: keyName), as: UTF8.self)
      loaded = true
    } catch { self.error = error.localizedDescription }
  }
  private func save() async {
    guard let id = model.activeAccountID else { return }
    do {
      try await model.client.putKVValue(
        accountID: id, namespaceID: namespaceID, key: keyName, data: Data(value.utf8))
      if existingKey == nil { onChanged() }
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

struct D1DatabasesView: View {
  @Environment(AppModel.self) private var model
  @State private var databases: [D1Database] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      retry: { Task { await load() } }
    ) {
      if databases.isEmpty {
        DashEmptyState(
          icon: SolarAsset.database,
          title: "No databases",
          message: "D1 databases for this account will appear here."
        )
      } else {
        DashListCard {
          DashListCardRows(items: databases) { database in
            DashListGroupLink(value: .d1Database(database.id, database.name)) {
              DashListRow(
                title: database.name,
                subtitle: database.fileSize.map {
                  ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                },
                icon: SolarAsset.database
              )
            }
          }
        }
      }
    }
    .refreshable { await load(force: true) }.task { await load() }
  }

  private func load(force: Bool = false) async {
    guard let id = model.activeAccountID else { return }
    let key = FeatureCacheKey.d1Databases(id)
    if !force, let cached: [D1Database] = model.featureCache.get(key) {
      databases = cached
      loading = false
      error = nil
      return
    }
    if databases.isEmpty { loading = true }
    do {
      databases = try await model.client.listD1Databases(accountID: id).items
      model.featureCache.set(key, databases)
      error = nil
    } catch { self.error = error.localizedDescription }
    loading = false
  }
}

struct D1ConsoleView: View {
  @Environment(AppModel.self) private var model
  let databaseID: String
  let name: String
  @State private var sql = "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name;"
  @State private var result = ""
  @State private var error: String?
  @State private var running = false
  var body: some View {
    ScrollView {
      VStack(spacing: DashTheme.Spacing.section) {
        DashCodePanel(
          title: "SQL query",
          message: "Run a read or write statement against this database.",
          text: $sql,
          minHeight: 150
        )

        DashPillButton(title: "Run query", isLoading: running) { Task { await run() } }
          .disabled(sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || running)

        if let error {
          DashNotice(kind: .error, message: error)
        } else {
          DashCodeBlock(
            title: "Result",
            text: result,
            placeholder: "Run a query to see results."
          )
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, 12)
      .padding(.bottom, 100)
      .animation(DashTheme.Motion.quick, value: error)
    }
    .dashKeyboardDismissal()
    .background(DashTheme.canvas)
    .navigationTitle(name)
  }
  private func run() async {
    guard let id = model.activeAccountID else { return }
    running = true
    defer { running = false }
    do {
      let values = try await model.client.queryD1(accountID: id, databaseID: databaseID, sql: sql)
      result = String(describing: values.flatMap { $0.results ?? [] })
      error = nil
    } catch { self.error = error.localizedDescription }
  }
}

/// Lazily downloads an R2 object into a temp file when the share sheet resolves
/// it — no separate download-then-share state machine.
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
