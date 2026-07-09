import CloudflareAPI
import SwiftUI

struct GenericFeatureView: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID
  var body: some View {
    GenericResourcesView(title: feature.title, path: path)
  }

  private var path: String {
    let account = model.activeAccountID ?? ""
    return switch feature {
    case .queues: "/accounts/\(account)/queues"
    case .vectorize: "/accounts/\(account)/vectorize/v2/indexes"
    case .secrets: "/accounts/\(account)/secrets_store/stores"
    case .turnstile: "/accounts/\(account)/challenges/widgets"
    case .accessApps: "/accounts/\(account)/access/apps"
    case .emailAddresses: "/accounts/\(account)/email/routing/addresses"
    case .registrar: "/accounts/\(account)/registrar/domains"
    case .tunnels: "/accounts/\(account)/cfd_tunnel"
    case .loadBalancerPools: "/accounts/\(account)/load_balancers/pools"
    case .images: "/accounts/\(account)/images/v1"
    case .stream: "/accounts/\(account)/stream"
    case .analytics: "/accounts/\(account)/rum/site_info/list"
    case .account: "/accounts/\(account)/members"
    default: "/accounts/\(account)"
    }
  }
}

// MARK: - Generic editability

/// One field in a generic create form; `options` renders a menu instead of text.
struct GenericCreateField {
  let key: String
  let label: String
  var options: [String]?
  var optional = false

  init(_ key: String, _ label: String, options: [String]? = nil, optional: Bool = false) {
    self.key = key
    self.label = label
    self.options = options
    self.optional = optional
  }
}

struct GenericCreateSpec {
  let title: String
  let fields: [GenericCreateField]
  /// Builds the POST body from the entered field values.
  let body: ([String: String]) -> [String: JSONValue]
}

/// A neutral, reversible write on a single row (enable/disable, lock/unlock),
/// rendered as a pill under the row's detail fields — no confirm step.
struct GenericRowUpdate: Identifiable {
  let id: String
  let title: (GenericResource) -> String
  let method: String
  /// Builds the request path from the list's base path and the row.
  let path: (String, GenericResource) -> String
  let body: (GenericResource) -> [String: JSONValue]
}

/// A high-risk action on the whole screen (header more-menu), e.g. redeploy or
/// delete-project on a Pages deployments list.
struct GenericScreenAction {
  let title: String
  var icon: String = SolarAsset.trash
  let message: String
  let method: String
  /// Builds the request path from the list's base path.
  let path: (String) -> String
  var dismissesAfter = false
}

/// What the generic resource screen can write for a given REST path. Every write
/// here rides an OAuth scope the app already requests — extend this registry as
/// more resources gain write support.
struct GenericResourceCapabilities {
  var create: GenericCreateSpec?
  /// Confirmation message for deleting a row; nil leaves the resource read-only.
  var deleteMessage: ((GenericResource) -> String)?
  var updates: [GenericRowUpdate] = []
  var screenActions: [GenericScreenAction] = []

  static func forPath(_ fullPath: String) -> GenericResourceCapabilities {
    let path = String(fullPath.split(separator: "?", maxSplits: 1)[0])
    var caps = GenericResourceCapabilities()

    if path.hasSuffix("/workers/routes") {
      caps.create = GenericCreateSpec(
        title: "New route",
        fields: [
          GenericCreateField("pattern", "Route pattern"),
          GenericCreateField("script", "Worker script"),
        ],
        body: { values in
          [
            "pattern": .string(values["pattern"] ?? ""),
            "script": .string(values["script"] ?? ""),
          ]
        })
      caps.deleteMessage = { "Permanently delete the route \($0.name)." }
    } else if path.hasSuffix("/firewall/access_rules/rules") {
      caps.create = GenericCreateSpec(
        title: "New access rule",
        fields: [
          GenericCreateField(
            "mode", "Action",
            options: ["block", "challenge", "js_challenge", "managed_challenge", "whitelist"]),
          GenericCreateField("value", "IP or CIDR"),
          GenericCreateField("notes", "Note", optional: true),
        ],
        body: { values in
          let value = values["value"] ?? ""
          var body: [String: JSONValue] = [
            "mode": .string(values["mode"] ?? "block"),
            "configuration": .object([
              "target": .string(value.contains("/") ? "ip_range" : "ip"),
              "value": .string(value),
            ]),
          ]
          if let notes = values["notes"], !notes.isEmpty { body["notes"] = .string(notes) }
          return body
        })
      caps.deleteMessage = { _ in "Permanently delete this access rule." }
    } else if path.hasSuffix("/email/routing/rules") {
      caps.create = GenericCreateSpec(
        title: "New forward rule",
        fields: [
          GenericCreateField("to", "Match address"),
          GenericCreateField("forward", "Forward to"),
        ],
        body: { values in
          let to = values["to"] ?? ""
          let forward = values["forward"] ?? ""
          return [
            "name": .string("Forward \(to)"),
            "enabled": .bool(true),
            "matchers": .array([
              .object([
                "type": .string("literal"), "field": .string("to"), "value": .string(to),
              ])
            ]),
            "actions": .array([
              .object(["type": .string("forward"), "value": .array([.string(forward)])])
            ]),
          ]
        })
      caps.deleteMessage = { "Permanently delete the rule \($0.name)." }
    } else if path.hasSuffix("/email/routing/addresses") {
      caps.create = GenericCreateSpec(
        title: "New address",
        fields: [GenericCreateField("email", "Email address")],
        body: { values in ["email": .string(values["email"] ?? "")] })
      caps.deleteMessage = { "Remove \($0.name) from destination addresses." }
    } else if path.hasSuffix("/load_balancers/pools") {
      caps.updates = [
        GenericRowUpdate(
          id: "toggle-enabled",
          title: { $0.bool("enabled") == false ? "Enable pool" : "Disable pool" },
          method: "PATCH",
          path: { "\($0)/\($1.id)" },
          body: { ["enabled": .bool(!($0.bool("enabled") ?? true))] })
      ]
      caps.deleteMessage = {
        "Permanently delete the pool \($0.name). Load balancers stop using its origins."
      }
    } else if path.hasSuffix("/pagerules") {
      caps.updates = [
        GenericRowUpdate(
          id: "toggle-status",
          title: { $0.string("status") == "active" ? "Disable rule" : "Enable rule" },
          method: "PATCH",
          path: { "\($0)/\($1.id)" },
          body: {
            ["status": .string($0.string("status") == "active" ? "disabled" : "active")]
          })
      ]
      caps.deleteMessage = { _ in "Permanently delete this page rule." }
    } else if path.hasSuffix("/registrar/domains") {
      // Registrar updates go by domain name, not id, and only accept PUT.
      caps.updates = [
        GenericRowUpdate(
          id: "toggle-auto-renew",
          title: { $0.bool("auto_renew") == true ? "Disable auto-renew" : "Enable auto-renew" },
          method: "PUT",
          path: { "\($0)/\($1.name)" },
          body: { ["auto_renew": .bool(!($0.bool("auto_renew") ?? false))] }),
        GenericRowUpdate(
          id: "toggle-locked",
          title: { $0.bool("locked") == true ? "Unlock transfers" : "Lock transfers" },
          method: "PUT",
          path: { "\($0)/\($1.name)" },
          body: { ["locked": .bool(!($0.bool("locked") ?? false))] }),
      ]
    } else if path.hasSuffix("/cfd_tunnel") {
      caps.create = GenericCreateSpec(
        title: "New tunnel",
        fields: [GenericCreateField("name", "Tunnel name")],
        body: { values in
          // config_src cloudflare = remotely managed; no tunnel secret to mint.
          ["name": .string(values["name"] ?? ""), "config_src": .string("cloudflare")]
        })
      caps.deleteMessage = {
        "Permanently delete the tunnel \($0.name). Its connectors disconnect."
      }
    } else if path.hasSuffix("/challenges/widgets") {
      caps.deleteMessage = {
        "Permanently delete the widget \($0.name). Its sitekey stops working."
      }
    } else if path.hasSuffix("/queues") {
      caps.create = GenericCreateSpec(
        title: "New queue",
        fields: [GenericCreateField("name", "Queue name")],
        body: { values in ["queue_name": .string(values["name"] ?? "")] })
      caps.deleteMessage = { "Permanently delete the queue \($0.name) and its messages." }
    } else if path.contains("/pages/projects/"), path.hasSuffix("/deployments") {
      caps.screenActions = [
        GenericScreenAction(
          title: "Redeploy latest",
          icon: SolarAsset.upload,
          message: "Start a new production deployment from the latest build.",
          method: "POST",
          path: { $0 }),
        GenericScreenAction(
          title: "Delete project",
          message: "Permanently delete this Pages project and all its deployments.",
          method: "DELETE",
          path: { String($0.dropLast("/deployments".count)) },
          dismissesAfter: true),
      ]
    }
    return caps
  }
}

extension GenericResource {
  fileprivate func bool(_ key: String) -> Bool? {
    if case .bool(let value)? = raw[key] { return value }
    return nil
  }

  fileprivate func string(_ key: String) -> String? {
    if case .string(let value)? = raw[key] { return value }
    return nil
  }
}

/// Declarative create form for a generic resource.
private struct GenericCreateSheet: View {
  let spec: GenericCreateSpec
  let onCreate: ([String: JSONValue]) async throws -> Void
  @Environment(\.dashTrayDismiss) private var dismiss
  @State private var values: [String: String] = [:]
  @State private var error: String?
  @State private var saving = false

  private var canSave: Bool {
    spec.fields.allSatisfy { field in
      field.optional || !(values[field.key] ?? "").isEmpty
    }
  }

  var body: some View {
    DashFormSheet(
      saveTitle: "Create",
      isSaving: saving,
      canSave: canSave,
      onSave: { Task { await save() } },
      content: {
        VStack(spacing: 14) {
          ForEach(spec.fields, id: \.key) { field in
            if let options = field.options {
              DashFormMenuField(
                label: field.label,
                selection: Binding(
                  get: { values[field.key] ?? options[0] },
                  set: { values[field.key] = $0 }),
                options: options)
            } else {
              DashFormField(
                label: field.label,
                text: Binding(
                  get: { values[field.key] ?? "" },
                  set: { values[field.key] = $0 }))
            }
          }
          if let error {
            DashNotice(kind: .error, message: error)
          }
        }
      }
    )
    .onAppear {
      for field in spec.fields where values[field.key] == nil {
        if let options = field.options { values[field.key] = options[0] }
      }
    }
  }

  private func save() async {
    saving = true
    error = nil
    do {
      try await onCreate(spec.body(values))
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      dismiss()
    } catch { self.error = error.localizedDescription }
    saving = false
  }
}

struct GenericResourcesView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismissScreen
  let title: String
  let path: String
  @State private var resources: [GenericResource] = []
  @State private var selected: GenericResource?
  @State private var error: String?
  @State private var loading = true
  @State private var creates = false
  @State private var deleting = false
  @State private var showsMore = false
  @State private var updatingID: String?
  @State private var updateError: String?

  private var capabilities: GenericResourceCapabilities { .forPath(path) }
  private var basePath: String { String(path.split(separator: "?", maxSplits: 1)[0]) }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      retry: { Task { await load() } }
    ) {
      if resources.isEmpty {
        DashEmptyState(
          icon: SolarAsset.inbox,
          title: "Nothing here yet",
          message: capabilities.create != nil
            ? "Create one with the add button."
            : "Cloudflare returned no resources for this account."
        )
      } else {
        DashListCard {
          DashListCardRows(items: resources) { resource in
            Button {
              updateError = nil
              selected = resource
            } label: {
              DashListRow(
                title: resource.name,
                subtitle: resource.detail,
                icon: SolarAsset.cloud,
                showsChevron: false
              )
            }
            .buttonStyle(DashPressButtonStyle())
          }
        }
      }
    }
    .navigationTitle(title)
    .toolbar {
      if let create = capabilities.create {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            creates = true
          } label: {
            DashToolbarActionIcon(asset: SolarAsset.plus)
          }
          .buttonStyle(DashPressButtonStyle())
          .accessibilityLabel(create.title)
        }
      }
      if !capabilities.screenActions.isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
          DashMoreButton(isPresented: $showsMore)
        }
      }
    }
    .dashTray(
      item: $selected,
      title: { $0.name },
      content: { resource in
        DashDetailTray(
          fields: resource.detailFields,
          deleteMessage: capabilities.deleteMessage?(resource),
          isDeleting: deleting,
          onDelete: capabilities.deleteMessage != nil
            ? { Task { await delete(resource) } }
            : nil
        ) {
          if !capabilities.updates.isEmpty {
            VStack(spacing: 10) {
              ForEach(capabilities.updates) { update in
                DashTrayPillButton(
                  title: update.title(resource),
                  isLoading: updatingID == update.id
                ) {
                  Task { await perform(update, on: resource) }
                }
              }
              if let updateError {
                DashNotice(kind: .error, message: updateError)
              }
            }
          }
        }
      }
    )
    .dashTray(isPresented: $creates, title: capabilities.create?.title ?? "New") {
      if let spec = capabilities.create {
        GenericCreateSheet(spec: spec) { body in
          _ = try await model.client.mutate(path: basePath, method: "POST", body: body)
          await invalidateAndReload()
        }
      }
    }
    .dashMoreMenu(
      isPresented: $showsMore,
      title: title,
      actions: capabilities.screenActions.map { action in
        DashDangerAction(title: action.title, icon: action.icon, message: action.message) {
          await perform(action)
        }
      }
    )
    .refreshable { await load(force: true) }.task { await load() }
  }

  private func delete(_ resource: GenericResource) async {
    deleting = true
    _ = try? await model.client.mutate(path: "\(basePath)/\(resource.id)", method: "DELETE")
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    selected = nil
    await invalidateAndReload()
    deleting = false
  }

  private func perform(_ update: GenericRowUpdate, on resource: GenericResource) async {
    updatingID = update.id
    updateError = nil
    do {
      _ = try await model.client.mutate(
        path: update.path(basePath, resource), method: update.method,
        body: update.body(resource))
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      selected = nil
      await invalidateAndReload()
    } catch { updateError = error.localizedDescription }
    updatingID = nil
  }

  private func perform(_ action: GenericScreenAction) async {
    _ = try? await model.client.mutate(path: action.path(basePath), method: action.method)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    if action.dismissesAfter {
      model.featureCache.remove(FeatureCacheKey.generic(path: path))
      dismissScreen()
    } else {
      await invalidateAndReload()
    }
  }

  private func invalidateAndReload() async {
    model.featureCache.remove(FeatureCacheKey.generic(path: path))
    await load(force: true)
  }

  private func load(force: Bool = false) async {
    let key = FeatureCacheKey.generic(path: path)
    if !force, let cached: [GenericResource] = model.featureCache.get(key) {
      resources = cached
      loading = false
      error = nil
      return
    }
    if resources.isEmpty { loading = true }
    error = nil
    do {
      let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
      var query: [String: String?] = [:]
      if parts.count == 2, let queryItems = URLComponents(string: "?\(parts[1])")?.queryItems {
        for item in queryItems { query[item.name] = item.value }
      }
      resources = try await model.client.listResources(path: parts[0], query: query).items
      model.featureCache.set(key, resources)
    } catch {
      if let apiError = error as? CloudflareAPIError, apiError.isPermissionDenied {
        self.error =
          (apiError.errorDescription ?? "Permission denied")
          + "\n\nEnable the required OAuth scope on your Cloudflare app and sign in again."
      } else {
        self.error = error.localizedDescription
      }
    }
    loading = false
  }
}
