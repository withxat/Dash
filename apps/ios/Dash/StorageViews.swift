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
            .contextMenu {
              Button("Delete", role: .destructive) { Task { await delete(bucket) } }
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
    .refreshable { await load(force: true) }.task { await load() }
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
  private func delete(_ bucket: R2Bucket) async {
    guard let id = model.activeAccountID else { return }
    try? await model.client.deleteR2Bucket(accountID: id, name: bucket.name)
    model.featureCache.remove(FeatureCacheKey.r2Buckets(id))
    await load(force: true)
  }
}

struct R2BucketView: View {
  @Environment(AppModel.self) private var model
  let bucket: String
  @State private var objects: [R2Object] = []
  @State private var prefix = ""
  @State private var error: String?
  // First load only — `.task(id: prefix)` reloads per keystroke, and
  // re-arming this would flash the full-screen spinner while typing.
  @State private var loading = true
  @State private var importsFile = false

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
            DashListRow(
              title: object.key,
              subtitle: object.size.map {
                ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
              },
              icon: SolarAsset.file,
              iconColor: DashTheme.text,
              showsChevron: false
            )
            .contextMenu {
              Button("Delete", role: .destructive) { Task { await delete(object) } }
            }
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
    }
    .fileImporter(isPresented: $importsFile, allowedContentTypes: [.data]) { result in
      if case .success(let url) = result { Task { await upload(url) } }
    }
    .refreshable { await load(force: true) }.task(id: prefix) { await load() }
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
    try? await model.client.deleteR2Object(accountID: id, bucket: bucket, key: object.key)
    model.featureCache.remove(
      FeatureCacheKey.r2Objects(accountID: id, bucket: bucket, prefix: prefix))
    await load(force: true)
  }
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
      retry: { Task { await load() } }
    ) {
      if namespaces.isEmpty {
        DashEmptyState(
          icon: SolarAsset.pinList,
          title: "No namespaces",
          message: "KV namespaces for this account will appear here."
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
    .refreshable { await load(force: true) }.task { await load() }
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
  let namespaceID: String
  @State private var keys: [KVKey] = []
  @State private var prefix = ""
  @State private var selected: KVKey?
  @State private var error: String?
  // First load only — `.task(id: prefix)` reloads per keystroke, and
  // re-arming this would flash the full-screen spinner while typing.
  @State private var loading = true

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
            .contextMenu {
              Button("Delete", role: .destructive) { Task { await delete(key) } }
            }
          }
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
        KVValueEditor(namespaceID: namespaceID, keyName: key.name)
      }
    )
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
  private func delete(_ key: KVKey) async {
    guard let id = model.activeAccountID else { return }
    try? await model.client.deleteKVValue(accountID: id, namespaceID: namespaceID, key: key.name)
    model.featureCache.remove(
      FeatureCacheKey.kvKeys(accountID: id, namespaceID: namespaceID, prefix: prefix))
    await load(force: true)
  }
}

private struct KVValueEditor: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let namespaceID: String
  let keyName: String
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
          accountID: id, namespaceID: namespaceID, key: keyName), as: UTF8.self)
      loaded = true
    } catch { self.error = error.localizedDescription }
  }
  private func save() async {
    guard let id = model.activeAccountID else { return }
    do {
      try await model.client.putKVValue(
        accountID: id, namespaceID: namespaceID, key: keyName, data: Data(value.utf8))
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

extension String { fileprivate var nilIfEmpty: String? { isEmpty ? nil : self } }
