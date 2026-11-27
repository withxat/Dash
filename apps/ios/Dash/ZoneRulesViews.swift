import CloudflareAPI
import SwiftUI
import UIKit

// Zone rules: redirect rules and custom WAF rules, read-only except for the one
// thing a phone is asked to do — turn a rule on or off.
//
// There is no expression editor and no create or delete. A toggle goes through
// the single-rule PATCH with the rule's whole definition sent back, so it can
// neither drop a field Dash does not model nor overwrite another rule.

/// Each phase answers to the product that owns it, not to one "rulesets"
/// permission. Gated per group rather than through `readScopes(for:)`, so a
/// grant that predates these scopes still opens the screen and a missing one
/// locks only its own group.
enum ZoneRulesAccess {
  static func read(_ phase: RulesetPhase) -> Set<String> {
    switch phase {
    case .dynamicRedirect: ["dynamic-redirect.read"]
    case .customFirewall: ["zone-waf.read"]
    }
  }

  static func write(_ phase: RulesetPhase) -> Set<String> {
    switch phase {
    case .dynamicRedirect: ["dynamic-redirect.write"]
    case .customFirewall: ["zone-waf.write"]
    }
  }

  static func all(_ phase: RulesetPhase) -> Set<String> {
    read(phase).union(write(phase))
  }
}

/// Pure wording for rule rows and the detail tray, tested without SwiftUI.
enum ZoneRulePresentation {
  static func title(for rule: RulesetRule) -> String {
    rule.name ?? DashL10n.string("Untitled rule")
  }

  /// Cloudflare's action ids in the dashboard's words. An id this table does
  /// not know is shown as Cloudflare sent it rather than guessed at.
  static func actionLabel(_ action: String?) -> String {
    switch action {
    case "block": DashL10n.string("Block")
    case "challenge": DashL10n.string("Interactive Challenge")
    case "js_challenge": DashL10n.string("JS Challenge")
    case "managed_challenge": DashL10n.string("Managed Challenge")
    case "skip": DashL10n.string("Skip")
    case "log": DashL10n.string("Log")
    case "redirect": DashL10n.string("Redirect")
    case "execute": DashL10n.string("Execute ruleset")
    case .some(let other): other
    case nil: "—"
    }
  }

  /// The row's second line: what the rule does, never its expression — that
  /// can run to a paragraph and belongs in the tray.
  static func summary(for rule: RulesetRule) -> String {
    guard rule.action == "redirect", let target = rule.redirectTarget else {
      return actionLabel(rule.action)
    }
    let destination = target.isExpression ? DashL10n.string("Dynamic URL") : target.value
    guard let code = rule.redirectStatusCode else { return "→ \(destination)" }
    return "\(code) → \(destination)"
  }

  static func detailFields(for rule: RulesetRule) -> [DashDetailField] {
    var fields = [
      DashDetailField(label: "Name", value: title(for: rule)),
      DashDetailField(
        label: "Status",
        value: rule.isEnabled ? DashL10n.string("Enabled") : DashL10n.string("Disabled")),
      DashDetailField(label: "Action", value: actionLabel(rule.action)),
    ]
    if let target = rule.redirectTarget {
      fields.append(
        DashDetailField(
          label: target.isExpression ? "Target URL expression" : "Target URL",
          value: target.value, mono: true))
    }
    if let code = rule.redirectStatusCode {
      fields.append(DashDetailField(label: "Status code", value: String(code)))
    }
    if let expression = rule.expression {
      fields.append(DashDetailField(label: "Expression", value: expression, mono: true))
    }
    if let updated = rule.lastUpdated {
      fields.append(
        DashDetailField(
          label: "Last updated", value: DashDateFormatting.dateAndTime(fromISO8601: updated)))
    }
    fields.append(DashDetailField(label: "Rule ID", value: rule.id, mono: true))
    return fields
  }
}

/// What one group knows. Nil `ruleset` after a settled load means the zone has
/// no entry point for the phase — no rules, not a failure.
struct ZoneRulesGroupState: Equatable {
  var ruleset: ZoneRuleset?
  var loaded = false
  var error: String?
  /// Rules with a toggle in flight.
  var updating: Set<String> = []

  var rules: [RulesetRule] { ruleset?.rules ?? [] }

  mutating func replace(_ rule: RulesetRule) {
    guard let ruleset, let index = ruleset.rules.firstIndex(where: { $0.id == rule.id })
    else { return }
    var rules = ruleset.rules
    rules[index] = rule
    self.ruleset = ZoneRuleset(
      id: ruleset.id, name: ruleset.name, phase: ruleset.phase, version: ruleset.version,
      rules: rules)
  }

  /// Takes Cloudflare's answer to a toggle. With no other toggle in flight the
  /// whole ruleset is adopted; otherwise only the rule that was asked about,
  /// because responses can land out of order and an older one must not repaint
  /// a row whose own request is still out.
  mutating func adopt(_ response: ZoneRuleset, for ruleID: String) {
    updating.remove(ruleID)
    if updating.isEmpty {
      ruleset = response
    } else if let rule = response.rules.first(where: { $0.id == ruleID }) {
      replace(rule)
    }
  }
}

private struct ZoneRuleSelection: Identifiable, Equatable {
  let phase: RulesetPhase
  let rule: RulesetRule

  var id: String { "\(phase.rawValue)/\(rule.id)" }
}

struct ZoneRulesView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let zoneID: String

  @State private var groups: [RulesetPhase: ZoneRulesGroupState] = [:]
  @State private var loading = true
  @State private var settled = false
  @State private var selection: ZoneRuleSelection?

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      hasContent: settled,
      retry: { Task { await load(force: true) } }
    ) { mode in
      group(.dynamicRedirect, mode: mode, leadsWithBoundary: false)
      group(.customFirewall, mode: mode, leadsWithBoundary: true)
    }
    .detailHeader(icon: .solar(SolarAsset.Content.listCheckMinimalistic), title: "Rules")
    .refreshable { await load(force: true) }
    .task(id: model.grantedScopes) { await load() }
    .dashTray(
      item: $selection,
      title: { ZoneRulePresentation.title(for: $0.rule) },
      tone: FeatureVisualIdentity.tone(for: .zones),
      content: { selection in
        ZoneRuleDetailTray(rule: selection.rule)
      }
    )
  }

  // MARK: Group

  private func title(_ phase: RulesetPhase) -> String {
    switch phase {
    case .dynamicRedirect: DashL10n.string("Redirect rules")
    case .customFirewall: DashL10n.string("Custom WAF rules")
    }
  }

  private func canRead(_ phase: RulesetPhase) -> Bool {
    model.hasScopes(ZoneRulesAccess.read(phase))
  }

  private func canWrite(_ phase: RulesetPhase) -> Bool {
    model.hasScopes(ZoneRulesAccess.write(phase))
  }

  @ViewBuilder
  private func group(_ phase: RulesetPhase, mode: DashBodyMode, leadsWithBoundary: Bool)
    -> some View
  {
    let state = groups[phase] ?? ZoneRulesGroupState()

    DashListGroupHeader(title: title(phase))
      .dashTwoToneHeaderBand()
      .dashSectionBoundary(leadsWithBoundary)
      .dashBodySlot(reduceMotion: reduceMotion)

    if mode.isPlaceholder {
      dashModeListRows(
        mode: .placeholder,
        items: [] as [RulesetRule],
        placeholderRows: 2,
        reduceMotion: reduceMotion,
        frame: .twoTone
      ) { _ in EmptyView() }
    } else if !canRead(phase) {
      FeatureWriteAccessNotice(
        message: phase == .dynamicRedirect
          ? "Grant Single Redirect access to view redirect rules and turn them on or off."
          : "Grant Zone WAF access to view custom rules and turn them on or off.",
        scopes: ZoneRulesAccess.all(phase)
      )
      .dashTwoToneRowSlice()
      .dashBodySlot(reduceMotion: reduceMotion)
    } else if let error = state.error, state.rules.isEmpty {
      DashNotice(kind: .error, message: error)
        .dashTwoToneRowSlice()
        .dashBodySlot(reduceMotion: reduceMotion)
    } else if state.rules.isEmpty {
      Text(
        phase == .dynamicRedirect
          ? DashL10n.string("No redirect rules on this domain.")
          : DashL10n.string("No custom WAF rules on this domain.")
      )
      .dashTwoToneNote()
      .dashTwoToneRowSlice()
      .dashBodySlot(reduceMotion: reduceMotion)
    } else {
      dashModeListRows(
        mode: .live,
        items: state.rules,
        reduceMotion: reduceMotion,
        frame: .twoTone
      ) { rule in
        ZoneRuleRow(
          rule: rule,
          canToggle: canWrite(phase),
          isUpdating: state.updating.contains(rule.id),
          open: { selection = ZoneRuleSelection(phase: phase, rule: rule) },
          toggle: { Task { await setEnabled(!rule.isEnabled, rule: rule, phase: phase) } }
        )
      }
      if !canWrite(phase) {
        FeatureWriteAccessNotice(
          message: phase == .dynamicRedirect
            ? "Read-only — grant Single Redirect write access to turn rules on or off."
            : "Read-only — grant Zone WAF write access to turn rules on or off.",
          scopes: ZoneRulesAccess.write(phase)
        )
        .dashItemBoundary()
        .dashBodySlot(reduceMotion: reduceMotion)
      }
    }
  }

  // MARK: Loading

  private func load(force: Bool = false) async {
    if !settled { loading = true }
    async let redirects: Void = load(.dynamicRedirect, force: force)
    async let custom: Void = load(.customFirewall, force: force)
    _ = await (redirects, custom)
    loading = false
    settled = true
  }

  private func load(_ phase: RulesetPhase, force: Bool) async {
    guard canRead(phase) else {
      groups[phase] = ZoneRulesGroupState()
      return
    }
    let key = FeatureCacheKey.zoneRuleset(zoneID: zoneID, phase: phase.rawValue)
    if !force, let cached: ZoneRuleset = model.featureCache.get(key) {
      groups[phase] = ZoneRulesGroupState(ruleset: cached, loaded: true)
      return
    }
    do {
      let fetched = try await model.client.getZoneEntrypointRuleset(zoneID: zoneID, phase: phase)
      guard !Task.isCancelled else { return }
      // A refresh must not repaint a row whose toggle is still in flight.
      guard groups[phase]?.updating.isEmpty ?? true else { return }
      groups[phase] = ZoneRulesGroupState(ruleset: fetched, loaded: true)
      if let fetched {
        model.featureCache.set(key, fetched)
      } else {
        model.featureCache.remove(key)
      }
    } catch {
      guard !error.dashIsCancellation else { return }
      var state = groups[phase] ?? ZoneRulesGroupState()
      state.error = error.dashActionableMessage
      groups[phase] = state
    }
  }

  // MARK: Toggle

  /// Optimistic: the switch moves at once, locks while the request is out, and
  /// moves back with the reason if Cloudflare refuses.
  private func setEnabled(_ enabled: Bool, rule: RulesetRule, phase: RulesetPhase) async {
    guard let state = groups[phase], let ruleset = state.ruleset,
      !state.updating.contains(rule.id)
    else { return }
    let scopes = ZoneRulesAccess.write(phase)
    guard model.hasScopes(scopes) else {
      model.requestAccess(to: scopes)
      return
    }
    groups[phase]?.replace(rule.settingEnabled(enabled))
    groups[phase]?.updating.insert(rule.id)
    do {
      let updated = try await model.client.setZoneRulesetRuleEnabled(
        zoneID: zoneID, rulesetID: ruleset.id, rule: rule, enabled: enabled)
      groups[phase]?.adopt(updated, for: rule.id)
      if let current = groups[phase]?.ruleset {
        model.featureCache.set(
          FeatureCacheKey.zoneRuleset(zoneID: zoneID, phase: phase.rawValue), current)
      }
    } catch {
      groups[phase]?.replace(rule)
      groups[phase]?.updating.remove(rule.id)
      guard !error.dashIsCancellation else { return }
      model.toasts.error(error.dashActionableMessage)
    }
  }
}

/// One rule: the left of the row opens its definition, the switch on the right
/// turns it on or off. Two targets on purpose — a row that toggled wherever it
/// was touched would leave the expression with nowhere to be read.
private struct ZoneRuleRow: View {
  let rule: RulesetRule
  let canToggle: Bool
  let isUpdating: Bool
  let open: () -> Void
  let toggle: () -> Void

  private var title: String { ZoneRulePresentation.title(for: rule) }

  var body: some View {
    HStack(spacing: 12) {
      Button(action: open) {
        DashListRow(
          title: title,
          subtitle: ZoneRulePresentation.summary(for: rule),
          showsChevron: false
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(DashSurfaceButtonStyle())
      .accessibilityIdentifier("zone-rule-\(rule.id)")

      Button(action: toggle) {
        DashSwitch(isOn: rule.isEnabled)
          .opacity(isUpdating ? 0.72 : 1)
          .frame(minHeight: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(DashSurfaceButtonStyle())
      .disabled(!canToggle || isUpdating)
      .opacity(canToggle ? 1 : 0.55)
      .accessibilityLabel(title)
      .accessibilityValue(rule.isEnabled ? DashL10n.string("On") : DashL10n.string("Off"))
      .accessibilityAddTraits(.isToggle)
      .accessibilityIdentifier("zone-rule-toggle-\(rule.id)")
    }
  }
}

private struct ZoneRuleDetailTray: View {
  @Environment(AppModel.self) private var model
  let rule: RulesetRule

  var body: some View {
    DashDetailTray(fields: ZoneRulePresentation.detailFields(for: rule)) {
      if let expression = rule.expression {
        DashActionButton(title: "Copy expression") {
          UIPasteboard.general.string = expression
          model.toasts.success(DashL10n.string("Expression copied"))
        }
      }
    }
  }
}
