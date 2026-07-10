import CloudflareAPI
import SwiftUI

/// Custom rulesets and account/zone entrypoints accept rule edits; managed
/// rulesets are configured through phase entrypoint overrides instead.
func rulesetKindIsEditable(_ kind: String?) -> Bool {
  kind == "custom" || kind == "root" || kind == "zone"
}

/// Feature root: account rulesets inline, or pick a zone for its rulesets.
struct RulesetsView: View {
  private enum Tab: Hashable { case account, zones }

  @Environment(AppModel.self) private var model
  @State private var tab = Tab.account
  @State private var rulesets: [Ruleset] = []
  @State private var zones: [CloudflareZone] = []
  @State private var loading = true
  @State private var error: String?

  private var accountBasePath: String { "/accounts/\(model.activeAccountID ?? "")" }

  var body: some View {
    DashFeatureScreen(
      chrome: {
        DashTextTabs(
          items: [("Account", Tab.account), ("Zones", Tab.zones)],
          selection: $tab
        )
      },
      content: {
        DashFeatureList(
          isLoading: loading,
          error: error,
          retry: { Task { await load(force: true) } }
        ) {
          if tab == .account {
            RulesetRowsCard(rulesets: rulesets, basePath: accountBasePath)
          } else {
            zoneRows
          }
        }
      }
    )
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  @ViewBuilder
  private var zoneRows: some View {
    if zones.isEmpty {
      DashEmptyState(
        icon: SolarAsset.search,
        title: "No zones",
        message: "Cloudflare returned no zones for this account."
      )
    } else {
      DashListCard {
        DashListCardRows(items: zones) { zone in
          DashListGroupLink(
            value: .rulesetList(basePath: "/zones/\(zone.id)", title: zone.name)
          ) {
            DashListRow(
              title: zone.name,
              subtitle: zone.status ?? "unknown",
              icon: SolarAsset.globe
            )
          }
        }
      }
    }
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let rulesetsKey = FeatureCacheKey.generic(path: "\(accountBasePath)/rulesets")
    let zonesKey = FeatureCacheKey.zones(accountID)
    if !force,
      let cachedRulesets: [Ruleset] = model.featureCache.get(rulesetsKey),
      let cachedZones: [CloudflareZone] = model.featureCache.get(zonesKey)
    {
      rulesets = cachedRulesets
      zones = cachedZones
      loading = false
      return
    }
    if rulesets.isEmpty { loading = true }
    error = nil
    do {
      async let rulesetList = model.client.listRulesets(basePath: accountBasePath)
      async let zoneList = model.client.listZones(accountID: accountID)
      rulesets = try await rulesetList.sorted {
        ($0.phase ?? "", $0.name) < ($1.phase ?? "", $1.name)
      }
      zones = try await zoneList.items
      model.featureCache.set(rulesetsKey, rulesets)
      model.featureCache.set(zonesKey, zones)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}

/// Rulesets of one zone, reached from the Zones tab.
struct RulesetListView: View {
  @Environment(AppModel.self) private var model
  let basePath: String
  let title: String
  @State private var rulesets: [Ruleset] = []
  @State private var loading = true
  @State private var error: String?

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      retry: { Task { await load(force: true) } }
    ) {
      RulesetRowsCard(rulesets: rulesets, basePath: basePath)
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private func load(force: Bool = false) async {
    let key = FeatureCacheKey.generic(path: "\(basePath)/rulesets")
    if !force, let cached: [Ruleset] = model.featureCache.get(key) {
      rulesets = cached
      loading = false
      return
    }
    if rulesets.isEmpty { loading = true }
    error = nil
    do {
      rulesets = try await model.client.listRulesets(basePath: basePath).sorted {
        ($0.phase ?? "", $0.name) < ($1.phase ?? "", $1.name)
      }
      model.featureCache.set(key, rulesets)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}

private struct RulesetRowsCard: View {
  let rulesets: [Ruleset]
  let basePath: String

  var body: some View {
    if rulesets.isEmpty {
      DashEmptyState(
        icon: SolarAsset.settings,
        title: "No rulesets",
        message: "Cloudflare returned no rulesets for this scope."
      )
    } else {
      DashListCard {
        DashListCardRows(items: rulesets) { ruleset in
          DashListGroupLink(
            value: .ruleset(basePath: basePath, rulesetID: ruleset.id, name: ruleset.name)
          ) {
            DashListRow(
              title: ruleset.name,
              subtitle: ruleset.phase?.replacingOccurrences(of: "_", with: " "),
              icon: SolarAsset.settings
            )
            .overlay(alignment: .trailing) {
              if let kind = ruleset.kind {
                StatusBadge(text: kind)
                  .padding(.trailing, 28)
              }
            }
          }
        }
      }
    }
  }
}

/// One ruleset's rules, with editing for custom/root kinds.
struct RulesetDetailView: View {
  @Environment(AppModel.self) private var model
  let basePath: String
  let rulesetID: String
  let name: String
  @State private var detail: RulesetDetail?
  @State private var loading = true
  @State private var error: String?
  @State private var selectedRule: RulesetRule?
  @State private var creating = false

  private var detailPath: String { "\(basePath)/rulesets/\(rulesetID)" }
  private var editable: Bool {
    rulesetKindIsEditable(detail?.kind)
      && FeatureID.rulesets.capability.accessLevel(grantedScopes: model.grantedScopes) == .full
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      retry: { Task { await load(force: true) } }
    ) {
      if let detail {
        if !rulesetKindIsEditable(detail.kind) {
          DashNotice(
            kind: .warning,
            message:
              "This is a \(detail.kind ?? "managed") ruleset. Its rules are read-only here; overrides are managed through phase entrypoints."
          )
        }
        let rules = detail.rules ?? []
        if rules.isEmpty {
          DashEmptyState(
            icon: SolarAsset.settings,
            title: "No rules",
            message: "This ruleset has no rules yet."
          )
        } else {
          DashListCard {
            DashListCardRows(items: rules) { rule in
              Button {
                selectedRule = rule
              } label: {
                DashListRow(
                  title: ruleTitle(rule),
                  subtitle: rule.expression,
                  icon: rule.enabled == false ? SolarAsset.circle : SolarAsset.checkCircle
                )
                .overlay(alignment: .trailing) {
                  if let action = rule.action {
                    StatusBadge(text: action)
                      .padding(.trailing, 28)
                  }
                }
              }
              .buttonStyle(DashPressButtonStyle())
            }
          }
        }
      }
    }
    .navigationTitle(name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if editable {
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarIconButton(asset: SolarAsset.plus, accessibilityLabel: "Add rule") {
            creating = true
          }
        }
        .dashSeparateToolbarBackground()
      }
    }
    .dashTray(
      item: $selectedRule,
      title: { rule in
        (rule.description?.isEmpty == false ? rule.description : nil) ?? "Rule"
      }
    ) { rule in
      RulesetRuleForm(
        basePath: basePath,
        rulesetID: rulesetID,
        rule: rule,
        editable: editable,
        onChanged: { updated in
          selectedRule = nil
          creating = false
          apply(updated)
        }
      )
    }
    .dashTray(isPresented: $creating, title: "New rule") {
      RulesetRuleForm(
        basePath: basePath,
        rulesetID: rulesetID,
        rule: nil,
        editable: true,
        onChanged: { updated in
          selectedRule = nil
          creating = false
          apply(updated)
        }
      )
    }
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private func ruleTitle(_ rule: RulesetRule) -> String {
    if let description = rule.description, !description.isEmpty { return description }
    return rule.action ?? rule.id
  }

  private func apply(_ updated: RulesetDetail?) {
    if let updated {
      detail = updated
      model.featureCache.set(FeatureCacheKey.generic(path: detailPath), updated)
    } else {
      Task { await load(force: true) }
    }
  }

  private func load(force: Bool = false) async {
    let key = FeatureCacheKey.generic(path: detailPath)
    if !force, let cached: RulesetDetail = model.featureCache.get(key) {
      detail = cached
      loading = false
      return
    }
    if detail == nil { loading = true }
    error = nil
    do {
      detail = try await model.client.getRuleset(basePath: basePath, id: rulesetID)
      if let detail { model.featureCache.set(key, detail) }
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}

/// Edit or create one rule. Saving PATCHes/POSTs the full rule body; the
/// tray's header trash deletes after an inline confirm.
private struct RulesetRuleForm: View {
  @Environment(AppModel.self) private var model
  let basePath: String
  let rulesetID: String
  let rule: RulesetRule?
  let editable: Bool
  /// Called with the updated ruleset (nil when the caller should refetch).
  let onChanged: (RulesetDetail?) -> Void

  @State private var action: String
  @State private var expression: String
  @State private var descriptionText: String
  @State private var enabled: Bool
  @State private var saving = false
  @State private var deleting = false
  @State private var saveError: String?
  @State private var deleteError: String?

  private static let actions = [
    "block", "managed_challenge", "js_challenge", "challenge", "log", "skip",
  ]

  init(
    basePath: String, rulesetID: String, rule: RulesetRule?, editable: Bool,
    onChanged: @escaping (RulesetDetail?) -> Void
  ) {
    self.basePath = basePath
    self.rulesetID = rulesetID
    self.rule = rule
    self.editable = editable
    self.onChanged = onChanged
    _action = State(initialValue: rule?.action ?? "block")
    _expression = State(initialValue: rule?.expression ?? "")
    _descriptionText = State(initialValue: rule?.description ?? "")
    _enabled = State(initialValue: rule?.enabled ?? true)
  }

  private var deleteHandler: (() -> Void)? {
    guard rule != nil else { return nil }
    return { Task { await deleteRule() } }
  }

  var body: some View {
    if editable {
      DashFormSheet(
        saveTitle: rule == nil ? "Add rule" : "Save",
        isSaving: saving,
        canSave: !expression.isEmpty,
        deleteMessage: rule == nil
          ? nil
          : "Permanently delete this rule from the ruleset.",
        isDeleting: deleting,
        deleteError: deleteError,
        onDelete: deleteHandler,
        onSave: { Task { await save() } },
        content: {
          formFields
        }
      )
    } else {
      VStack(alignment: .leading, spacing: 16) {
        if let action = rule?.action {
          StatusBadge(text: action)
        }
        DashCodeBlock(title: "Expression", text: rule?.expression ?? "")
        if let description = rule?.description, !description.isEmpty {
          Text(description)
            .dashTextStyle(.supportingMedium)
            .foregroundStyle(DashTheme.subtle)
        }
      }
    }
  }

  private var formFields: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let saveError {
        DashNotice(kind: .error, message: saveError)
      }
      DashFormMenuField(label: "Action", selection: $action, options: Self.actions)
      DashCodePanel(
        title: "Expression",
        message: "Wirefilter expression, e.g. (http.host eq \"example.com\")",
        text: $expression,
        minHeight: 120
      )
      DashFormField(label: "Description", text: $descriptionText)
      DashToggleRow(title: "Enabled", isOn: $enabled)
    }
  }

  private var ruleBody: [String: JSONValue] {
    var body: [String: JSONValue] = [
      "action": .string(action),
      "expression": .string(expression),
      "enabled": .bool(enabled),
    ]
    if !descriptionText.isEmpty { body["description"] = .string(descriptionText) }
    return body
  }

  private func save() async {
    saving = true
    saveError = nil
    do {
      let updated: RulesetDetail
      if let rule {
        updated = try await model.client.patchRulesetRule(
          basePath: basePath, rulesetID: rulesetID, ruleID: rule.id, body: ruleBody)
      } else {
        updated = try await model.client.addRulesetRule(
          basePath: basePath, rulesetID: rulesetID, body: ruleBody)
      }
      onChanged(updated)
    } catch {
      saveError = error.dashActionableMessage
    }
    saving = false
  }

  private func deleteRule() async {
    guard let rule else { return }
    deleting = true
    deleteError = nil
    do {
      _ = try await model.client.mutate(
        path: "\(basePath)/rulesets/\(rulesetID)/rules/\(rule.id)", method: "DELETE")
      onChanged(nil)
    } catch {
      deleteError = error.dashActionableMessage
    }
    deleting = false
  }
}
