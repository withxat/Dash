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
    List {
      if loading {
        LoadingStateView().listRowBackground(Color.clear)
      } else if let error {
        ErrorStateView(message: error) { Task { await load() } }.listRowBackground(Color.clear)
      } else {
        ForEach(buckets) { bucket in
          NavigationLink(value: Destination.r2Bucket(bucket.name)) {
            Label {
              VStack(alignment: .leading) {
                Text(bucket.name)
                Text(bucket.creationDate ?? "").font(.caption).foregroundStyle(DashTheme.subtle)
              }
            } icon: {
              Image(systemName: "externaldrive").foregroundStyle(DashTheme.brand)
            }
          }.swipeActions { Button("Delete", role: .destructive) { Task { await delete(bucket) } } }
        }
      }
    }
    .navigationTitle("R2").toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          creates = true
        } label: {
          Image(systemName: "plus")
        }
      }
    }
    .alert("New bucket", isPresented: $creates) {
      TextField("Bucket name", text: $newName)
      Button("Create") { Task { await create() } }
      Button("Cancel", role: .cancel) {}
    }
    .refreshable { await load() }.task { await load() }.destinationRouting()
  }
  private func load() async {
    guard let id = model.activeAccountID else { return }
    loading = true
    do {
      buckets = try await model.client.listR2Buckets(accountID: id)
      error = nil
    } catch { self.error = error.localizedDescription }
    loading = false
  }
  private func create() async {
    guard let id = model.activeAccountID, !newName.isEmpty else { return }
    do {
      _ = try await model.client.createR2Bucket(accountID: id, name: newName)
      newName = ""
      await load()
    } catch { self.error = error.localizedDescription }
  }
  private func delete(_ bucket: R2Bucket) async {
    guard let id = model.activeAccountID else { return }
    try? await model.client.deleteR2Bucket(accountID: id, name: bucket.name)
    await load()
  }
}

struct R2BucketView: View {
  @Environment(AppModel.self) private var model
  let bucket: String
  @State private var objects: [R2Object] = []
  @State private var prefix = ""
  @State private var error: String?
  @State private var importsFile = false

  var body: some View {
    List {
      if let error {
        ErrorStateView(message: error) { Task { await load() } }.listRowBackground(Color.clear)
      } else if objects.isEmpty {
        ContentUnavailableView(
          "Empty bucket", systemImage: "externaldrive",
          description: Text("Upload a file to get started.")
        ).listRowBackground(Color.clear)
      } else {
        ForEach(objects) { object in
          HStack {
            Image(systemName: "doc")
            VStack(alignment: .leading) {
              Text(object.key)
              if let size = object.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(
                  .caption
                ).foregroundStyle(DashTheme.subtle)
              }
            }
          }.swipeActions { Button("Delete", role: .destructive) { Task { await delete(object) } } }
        }
      }
    }.navigationTitle(bucket).searchable(text: $prefix, prompt: "Prefix")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            importsFile = true
          } label: {
            Image(systemName: "square.and.arrow.up")
          }
        }
      }
      .fileImporter(isPresented: $importsFile, allowedContentTypes: [.data]) { result in
        if case .success(let url) = result { Task { await upload(url) } }
      }
      .refreshable { await load() }.task(id: prefix) { await load() }
  }
  private func load() async {
    guard let id = model.activeAccountID else { return }
    do {
      objects = try await model.client.listR2Objects(
        accountID: id, bucket: bucket, prefix: prefix.nilIfEmpty
      ).items
      error = nil
    } catch { self.error = error.localizedDescription }
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
      await load()
    } catch { self.error = error.localizedDescription }
  }
  private func delete(_ object: R2Object) async {
    guard let id = model.activeAccountID else { return }
    try? await model.client.deleteR2Object(accountID: id, bucket: bucket, key: object.key)
    await load()
  }
}

struct KVNamespacesView: View {
  @Environment(AppModel.self) private var model
  @State private var namespaces: [KVNamespace] = []
  @State private var error: String?
  var body: some View {
    List {
      if let error {
        ErrorStateView(message: error) { Task { await load() } }.listRowBackground(Color.clear)
      } else if namespaces.isEmpty {
        LoadingStateView().listRowBackground(Color.clear)
      } else {
        ForEach(namespaces) { namespace in
          NavigationLink(value: Destination.kvNamespace(namespace.id)) {
            Label(namespace.title, systemImage: "list.bullet.rectangle")
          }
        }
      }
    }.navigationTitle("KV").refreshable { await load() }.task { await load() }.destinationRouting()
  }
  private func load() async {
    guard let id = model.activeAccountID else { return }
    do {
      namespaces = try await model.client.listKVNamespaces(accountID: id).items
      error = nil
    } catch { self.error = error.localizedDescription }
  }
}

struct KVNamespaceView: View {
  @Environment(AppModel.self) private var model
  let namespaceID: String
  @State private var keys: [KVKey] = []
  @State private var prefix = ""
  @State private var selected: KVKey?
  @State private var error: String?

  var body: some View {
    List {
      if let error {
        ErrorStateView(message: error) { Task { await load() } }.listRowBackground(Color.clear)
      } else {
        ForEach(keys) { key in
          Button {
            selected = key
          } label: {
            Label(key.name, systemImage: "key")
          }.foregroundStyle(.primary).swipeActions {
            Button("Delete", role: .destructive) { Task { await delete(key) } }
          }
        }
      }
    }.navigationTitle("KV keys").searchable(text: $prefix, prompt: "Key prefix").task(id: prefix) {
      await load()
    }.refreshable { await load() }
      .sheet(item: $selected) { key in
        NavigationStack { KVValueEditor(namespaceID: namespaceID, keyName: key.name) }
      }
  }
  private func load() async {
    guard let id = model.activeAccountID else { return }
    do {
      keys = try await model.client.listKVKeys(
        accountID: id, namespaceID: namespaceID, prefix: prefix.nilIfEmpty
      ).items
      error = nil
    } catch { self.error = error.localizedDescription }
  }
  private func delete(_ key: KVKey) async {
    guard let id = model.activeAccountID else { return }
    try? await model.client.deleteKVValue(accountID: id, namespaceID: namespaceID, key: key.name)
    await load()
  }
}

private struct KVValueEditor: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let namespaceID: String
  let keyName: String
  @State private var value = ""
  @State private var error: String?
  var body: some View {
    Form {
      Section(keyName) { TextEditor(text: $value).font(.body.monospaced()).frame(minHeight: 260) }
      if let error { Text(error).foregroundStyle(.red) }
    }
    .navigationTitle("KV entry").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } } }
    }
    .task { await load() }
  }
  private func load() async {
    guard let id = model.activeAccountID else { return }
    do {
      value = String(
        decoding: try await model.client.getKVValue(
          accountID: id, namespaceID: namespaceID, key: keyName), as: UTF8.self)
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
  var body: some View {
    List {
      if let error {
        ErrorStateView(message: error) { Task { await load() } }.listRowBackground(Color.clear)
      } else if databases.isEmpty {
        LoadingStateView().listRowBackground(Color.clear)
      } else {
        ForEach(databases) { database in
          NavigationLink(value: Destination.d1Database(database.id, database.name)) {
            Label {
              VStack(alignment: .leading) {
                Text(database.name)
                if let size = database.fileSize {
                  Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption).foregroundStyle(DashTheme.subtle)
                }
              }
            } icon: {
              Image(systemName: "cylinder")
            }
          }
        }
      }
    }
    .navigationTitle("D1").refreshable { await load() }.task { await load() }.destinationRouting()
  }
  private func load() async {
    guard let id = model.activeAccountID else { return }
    do {
      databases = try await model.client.listD1Databases(accountID: id).items
      error = nil
    } catch { self.error = error.localizedDescription }
  }
}

struct D1ConsoleView: View {
  @Environment(AppModel.self) private var model
  let databaseID: String
  let name: String
  @State private var sql = "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name;"
  @State private var result = ""
  @State private var error: String?
  var body: some View {
    Form {
      Section("SQL") {
        TextEditor(text: $sql).font(.body.monospaced()).frame(minHeight: 140)
        Button("Run query") { Task { await run() } }.buttonStyle(.borderedProminent)
      }
      Section("Result") {
        if let error {
          Text(error).foregroundStyle(.red)
        } else {
          ScrollView(.horizontal) {
            Text(result.isEmpty ? "Run a query to see results." : result).font(
              .caption.monospaced()
            ).textSelection(.enabled)
          }
        }
      }
    }.navigationTitle(name)
  }
  private func run() async {
    guard let id = model.activeAccountID else { return }
    do {
      let values = try await model.client.queryD1(accountID: id, databaseID: databaseID, sql: sql)
      result = String(describing: values.flatMap { $0.results ?? [] })
      error = nil
    } catch { self.error = error.localizedDescription }
  }
}

extension String { fileprivate var nilIfEmpty: String? { isEmpty ? nil : self } }
