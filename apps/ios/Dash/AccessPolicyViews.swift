import CloudflareAPI
import SwiftUI

/// Builds the Access include-rule array from form rows. Everyone ignores the
/// value; the other kinds wrap it in their documented shape.
func accessIncludeRules(_ rows: [(kind: String, value: String)]) -> [JSONValue] {
  rows.compactMap { row in
    switch row.kind {
    case "Everyone":
      return .object(["everyone": .object([:])])
    case "Email":
      guard !row.value.isEmpty else { return nil }
      return .object(["email": .object(["email": .string(row.value)])])
    case "Email domain":
      guard !row.value.isEmpty else { return nil }
      return .object(["email_domain": .object(["domain": .string(row.value)])])
    default:
      return nil
    }
  }
}

/// Feature root: reusable account policies, or per-app policies.
struct AccessPoliciesView: View {
  private enum Tab: Hashable { case reusable, byApp }

  @Environment(AppModel.self) private var model
  @State private var tab = Tab.reusable
  @State private var policies: [AccessPolicy] = []
  @State private var apps: [AccessApp] = []
  @State private var loading = true
  @State private var error: String?
  @State private var creating = false
  @State private var selected: AccessPolicy?
  @State private var deleting = false
  @State private var deleteError: String?

  private var allowsWrites: Bool {
    FeatureID.accessPolicies.capability.accessLevel(grantedScopes: model.grantedScopes) == .full
  }

  var body: some View {
    DashFeatureScreen(
      chrome: {
        DashTextTabs(
          items: [("Reusable", Tab.reusable), ("By app", Tab.byApp)],
          selection: $tab
        )
      },
      content: {
        DashFeatureList(
          isLoading: loading,
          error: error,
          hasContent: tab == .reusable ? !policies.isEmpty : !apps.isEmpty,
          retry: { Task { await load(force: true) } }
        ) {
          if tab == .reusable {
            AccessPolicyRowsCard(policies: policies, emptyMessage: "No reusable policies yet.") {
              selected = $0
            }
          } else {
            appRows
          }
        }
      }
    )
    .toolbar {
      if allowsWrites, tab == .reusable {
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarIconButton(asset: SolarAsset.plus, accessibilityLabel: "New policy") {
            creating = true
          }
        }
        .dashSeparateToolbarBackground()
      }
    }
    .dashTray(isPresented: $creating, title: "New reusable policy") {
      AccessPolicyForm(appID: nil, existingCount: policies.count) {
        creating = false
        Task { await load(force: true) }
      }
    }
    .dashTray(item: $selected, title: { $0.name }) { policy in
      AccessPolicyDetailTray(
        policy: policy,
        deleteMessage: allowsWrites
          ? "Permanently delete the policy \(policy.name). Apps referencing it stop matching."
          : nil,
        isDeleting: deleting,
        deleteError: deleteError,
        onDelete: { Task { await deletePolicy(policy) } }
      )
    }
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  @ViewBuilder
  private var appRows: some View {
    if apps.isEmpty {
      DashEmptyState(
        icon: SolarAsset.lock,
        title: "No Access apps",
        message: "Create an Access application first; its policies appear here."
      )
    } else {
      DashListCard {
        DashListCardRows(items: apps) { app in
          DashListGroupLink(value: .accessAppPolicies(appID: app.id, appName: app.name)) {
            DashListRow(
              title: app.name,
              subtitle: app.domain ?? app.type,
              icon: SolarAsset.lock
            )
          }
        }
      }
    }
  }

  private func deletePolicy(_ policy: AccessPolicy) async {
    guard let accountID = model.activeAccountID else { return }
    deleting = true
    deleteError = nil
    do {
      _ = try await model.client.mutate(
        path: "/accounts/\(accountID)/access/policies/\(policy.id)", method: "DELETE")
      selected = nil
      await load(force: true)
    } catch {
      deleteError = error.dashActionableMessage
    }
    deleting = false
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let policiesKey = FeatureCacheKey.generic(path: "/accounts/\(accountID)/access/policies")
    let appsKey = FeatureCacheKey.generic(path: "/accounts/\(accountID)/access/apps#policies")
    if !force,
      let cachedPolicies: [AccessPolicy] = model.featureCache.get(policiesKey),
      let cachedApps: [AccessApp] = model.featureCache.get(appsKey)
    {
      policies = cachedPolicies
      apps = cachedApps
      loading = false
      return
    }
    if policies.isEmpty { loading = true }
    error = nil
    do {
      async let policyList = model.client.listAccessPolicies(accountID: accountID)
      async let appList = model.client.listAccessApps(accountID: accountID)
      policies = try await policyList
      apps = try await appList
      model.featureCache.set(policiesKey, policies)
      model.featureCache.set(appsKey, apps)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}

/// Policies attached to one Access application.
struct AccessAppPoliciesView: View {
  @Environment(AppModel.self) private var model
  let appID: String
  let appName: String
  @State private var policies: [AccessPolicy] = []
  @State private var loading = true
  @State private var error: String?
  @State private var creating = false
  @State private var selected: AccessPolicy?
  @State private var deleting = false
  @State private var deleteError: String?

  private var allowsWrites: Bool {
    FeatureID.accessPolicies.capability.accessLevel(grantedScopes: model.grantedScopes) == .full
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !policies.isEmpty,
      retry: { Task { await load(force: true) } }
    ) {
      AccessPolicyRowsCard(policies: policies, emptyMessage: "This app has no policies yet.") {
        selected = $0
      }
    }
    .navigationTitle(appName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if allowsWrites {
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarIconButton(asset: SolarAsset.plus, accessibilityLabel: "New policy") {
            creating = true
          }
        }
        .dashSeparateToolbarBackground()
      }
    }
    .dashTray(isPresented: $creating, title: "New policy") {
      AccessPolicyForm(appID: appID, existingCount: policies.count) {
        creating = false
        Task { await load(force: true) }
      }
    }
    .dashTray(item: $selected, title: { $0.name }) { policy in
      AccessPolicyDetailTray(
        policy: policy,
        deleteMessage: allowsWrites
          ? "Permanently delete the policy \(policy.name) from \(appName)."
          : nil,
        isDeleting: deleting,
        deleteError: deleteError,
        onDelete: { Task { await deletePolicy(policy) } }
      )
    }
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private func deletePolicy(_ policy: AccessPolicy) async {
    guard let accountID = model.activeAccountID else { return }
    deleting = true
    deleteError = nil
    do {
      _ = try await model.client.mutate(
        path: "/accounts/\(accountID)/access/apps/\(appID)/policies/\(policy.id)",
        method: "DELETE")
      selected = nil
      await load(force: true)
    } catch {
      deleteError = error.dashActionableMessage
    }
    deleting = false
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.generic(
      path: "/accounts/\(accountID)/access/apps/\(appID)/policies")
    if !force, let cached: [AccessPolicy] = model.featureCache.get(key) {
      policies = cached
      loading = false
      return
    }
    if policies.isEmpty { loading = true }
    error = nil
    do {
      policies = try await model.client.listAppPolicies(accountID: accountID, appID: appID)
      model.featureCache.set(key, policies)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}

private struct AccessPolicyRowsCard: View {
  let policies: [AccessPolicy]
  let emptyMessage: String
  let onSelect: (AccessPolicy) -> Void

  var body: some View {
    if policies.isEmpty {
      DashEmptyState(icon: SolarAsset.lock, title: "No policies", message: emptyMessage)
    } else {
      DashListCard {
        DashListCardRows(items: policies) { policy in
          Button {
            onSelect(policy)
          } label: {
            DashListRow(
              title: policy.name,
              subtitle: includeSummary(policy),
              icon: SolarAsset.shieldCheck
            )
            .overlay(alignment: .trailing) {
              if let decision = policy.decision {
                StatusBadge(text: decision)
                  .padding(.trailing, 28)
              }
            }
          }
          .buttonStyle(DashPressButtonStyle())
        }
      }
    }
  }

  private func includeSummary(_ policy: AccessPolicy) -> String? {
    guard let include = policy.include, !include.isEmpty else { return nil }
    let names = include.compactMap { rule -> String? in
      if case .object(let object) = rule { return object.keys.first }
      return nil
    }
    return names.isEmpty ? nil : names.joined(separator: ", ")
  }
}

private struct AccessPolicyDetailTray: View {
  let policy: AccessPolicy
  let deleteMessage: String?
  let isDeleting: Bool
  let deleteError: String?
  let onDelete: () -> Void

  var body: some View {
    DashDetailTray(
      fields: fields,
      deleteMessage: deleteMessage,
      isDeleting: isDeleting,
      deleteError: deleteError,
      onDelete: deleteMessage == nil ? nil : onDelete
    ) {
      EmptyView()
    }
  }

  private var fields: [DashDetailField] {
    var fields: [DashDetailField] = [
      DashDetailField(label: "Name", value: policy.name),
      DashDetailField(label: "Decision", value: policy.decision ?? "unknown"),
    ]
    if let include = policy.include, !include.isEmpty,
      let data = try? prettyEncoder.encode(JSONValue.array(include))
    {
      fields.append(
        DashDetailField(
          label: "Include", value: String(decoding: data, as: UTF8.self), mono: true))
    }
    if policy.reusable == true {
      fields.append(DashDetailField(label: "Reusable", value: "yes"))
    }
    return fields
  }

  private var prettyEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

/// Create form shared by reusable and per-app policies. Per-app policies get
/// precedence appended after the app's existing policies.
private struct AccessPolicyForm: View {
  @Environment(AppModel.self) private var model
  let appID: String?
  let existingCount: Int
  let onCreated: () -> Void

  private struct IncludeRow: Identifiable {
    let id = UUID()
    var kind = "Everyone"
    var value = ""
  }

  private static let kinds = ["Everyone", "Email", "Email domain"]
  private static let decisions = ["allow", "deny", "bypass"]

  @State private var name = ""
  @State private var decision = "allow"
  @State private var includeRows = [IncludeRow()]
  @State private var saving = false
  @State private var saveError: String?

  private var includeRules: [JSONValue] {
    accessIncludeRules(includeRows.map { (kind: $0.kind, value: $0.value) })
  }

  var body: some View {
    DashFormSheet(
      saveTitle: "Create",
      isSaving: saving,
      canSave: !name.isEmpty && !includeRules.isEmpty,
      onSave: { Task { await save() } },
      content: {
        VStack(alignment: .leading, spacing: 16) {
          if let saveError {
            DashNotice(kind: .error, message: saveError)
          }
          DashFormField(label: "Policy name", text: $name)
          DashFormMenuField(label: "Decision", selection: $decision, options: Self.decisions)
          ForEach($includeRows) { $row in
            HStack(alignment: .bottom, spacing: 12) {
              DashFormMenuField(label: "Include", selection: $row.kind, options: Self.kinds)
              if row.kind != "Everyone" {
                DashFormField(
                  label: row.kind == "Email" ? "Email address" : "Domain",
                  text: $row.value
                )
              }
            }
          }
          if includeRows.count < 3 {
            DashSecondaryPillButton(title: "Add include rule") {
              includeRows.append(IncludeRow())
            }
          }
        }
      }
    )
  }

  private func save() async {
    guard let accountID = model.activeAccountID else { return }
    saving = true
    saveError = nil
    var body: [String: JSONValue] = [
      "name": .string(name),
      "decision": .string(decision),
      "include": .array(includeRules),
    ]
    if appID != nil {
      body["precedence"] = .number(Double(existingCount + 1))
    }
    do {
      _ = try await model.client.createAccessPolicy(
        accountID: accountID, appID: appID, body: body)
      onCreated()
    } catch {
      saveError = error.dashActionableMessage
    }
    saving = false
  }
}
