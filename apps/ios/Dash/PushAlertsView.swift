import CloudflareAPI
import SwiftUI

private enum PushAlertScopes {
  static let read = readScopes(for: .pushAlerts)
  static let write = writeScopes(for: .pushAlerts)
  static let all = read.union(write)
}

/// Cloudflare → webhook → APNs controls. Delivery is provisioned by default;
/// Settings only exposes policy management, delivery promotion, and an
/// explicit retry when automatic setup could not finish.
struct PushAlertsSettingsRows: View {
  @Environment(AppModel.self) private var model
  @State private var pushReady = false
  @State private var setupBusy = false
  @State private var setupError: String?
  @State private var isProvisional = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !model.hasScopes(PushAlertScopes.all) {
        DashAuthorizationDisclosure()
          .padding(.bottom, 8)
      }

      if model.configuration.pushBaseURL == nil {
        DashNotice(
          kind: .warning,
          message: "Push is unavailable until the OAuth redirect URI is configured."
        )
        .padding(.bottom, 8)
      }

      if let setupError {
        DashNotice(kind: .error, message: setupError)
          .padding(.bottom, 8)
      }

      DashListGroupLink(value: .pushAlerts) {
        SettingsPlainRow(
          title: DashL10n.string("Alert policies"),
          icon: SolarAsset.bolt,
          showsChevron: true
        )
      }
      .accessibilityIdentifier("Alert policies")

      if pushReady, isProvisional {
        // iOS granted quiet delivery without a dialog. Offer the upgrade here
        // instead of firing the system prompt during automatic setup.
        Button {
          Task { await promoteDelivery() }
        } label: {
          SettingsPlainRow(
            title: DashL10n.string("Deliver alerts prominently"),
            icon: SolarAsset.inbox,
            iconColor: DashTheme.brand,
            textColor: DashTheme.brand
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityIdentifier("Deliver alerts prominently")
      }

      if !pushReady, model.configuration.pushBaseURL != nil,
        model.hasScopes(PushAlertScopes.all),
        !setupBusy,
        setupError != nil
      {
        Button {
          Task { await connectDefaultDelivery() }
        } label: {
          SettingsPlainRow(
            title: DashL10n.string("Try again"),
            icon: SolarAsset.bolt,
            iconColor: DashTheme.brand,
            textColor: DashTheme.brand
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityIdentifier("Retry alert setup")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: model.accountRequestContext) {
      setupBusy = false
      setupError = nil
      syncPushState()
      isProvisional = await DashNotificationSupport.isProvisional()
      guard PushRegistrationService.shouldAutomaticallyProvisionForCurrentProcess else { return }
      await connectDefaultDelivery()
    }
  }

  /// Shows the system prompt so quiet Notification Center delivery becomes
  /// banners and sounds. A decline leaves the provisional grant intact.
  private func promoteDelivery() async {
    let granted = await DashNotificationSupport.requestAuthorization(prominently: true)
    isProvisional = await DashNotificationSupport.isProvisional()
    if granted, !isProvisional {
      model.toasts.success(DashL10n.string("Alerts will now appear as banners."))
    } else if !granted {
      model.toasts.warning(DashL10n.string("Notifications are turned off in Settings."))
    }
  }

  private func syncPushState() {
    guard let accountID = model.activeAccountID else {
      pushReady = false
      return
    }
    pushReady = PushRegistrationService.isReady(accountID: accountID)
  }

  private func connectDefaultDelivery() async {
    guard model.hasScopes(PushAlertScopes.all),
      let context = model.accountRequestContext,
      model.isCurrentAccount(context)
    else { return }
    setupBusy = true
    setupError = nil
    defer {
      if model.isCurrentAccount(context) {
        setupBusy = false
      }
    }
    do {
      try await model.ensureDefaultPushRegistration(for: context)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      pushReady = true
      isProvisional = await DashNotificationSupport.isProvisional()
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      syncPushState()
      setupError = error.dashActionableMessage
    }
  }
}

/// Manage Cloudflare notification policies. Policies created in Dash attach
/// the current device's default webhook explicitly.
struct PushAlertsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var policies: [NotificationPolicy] = []
  @State private var groups: [AvailableAlertGroup] = []
  @State private var loading = true
  @State private var error: String?
  @State private var creatingPolicy = false
  @State private var applyingPreset: String?
  @State private var presetPhase: DashActionPhase = .idle
  @State private var detail: NotificationPolicy?
  @State private var togglePhase: DashActionPhase = .idle
  @State private var pendingPolicyUpdate: NotificationPolicy?
  @State private var deletePhase: DashActionPhase = .idle
  @State private var deleteError: String?

  /// One-tap presets. Every entry is filtered against `available_alerts` before
  /// it renders, so a type this account (or plan) does not have simply never
  /// appears — the full catalog is one screen away in the create form either
  /// way, and these only exist to make the common setup a single tap.
  private static let recommendedTypes: [(type: String, name: String)] = [
    ("http_alert_origin_error", "Origin errors"),
    ("dos_attack_l7", "L7 DDoS"),
    ("real_origin_monitoring", "Origin monitoring"),
    ("universal_ssl_event_type", "Universal SSL"),
    ("load_balancing_health_alert", "Load balancer health"),
    ("tunnel_health_event", "Tunnel health"),
    ("secondary_dns_all_primaries_failing", "Secondary DNS"),
    ("weekly_account_overview", "Weekly overview"),
  ]

  /// False until the first load settles — webhook id alone must not flip Warm
  /// and show Updating… over an empty shell.
  @State private var hasPresentedContent = false

  private var allowsWrites: Bool {
    featureAllowsWrites && model.hasScopes(PushAlertScopes.write)
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: hasPresentedContent,
      retry: { Task { await load(force: true) } }
    ) { mode in
      if !mode.isPlaceholder {
        if !allowsWrites {
          FeatureWriteAccessNotice(
            message: "Read-only — grant notification write access to manage alert policies.",
            scopes: PushAlertScopes.write)
        }

        if let webhookID = storedWebhookID, showsRecommended {
          recommendedCard(webhookID: webhookID)
            .dashSectionBoundary(!allowsWrites)
        }
      }

      if !mode.isPlaceholder, policies.isEmpty {
        DashEmptyState(
          icon: SolarAsset.Content.bolt,
          title: "No alert policies",
          message: allowsWrites
            ? "Create a policy or enable a recommended alert to reach this iPhone."
            : "Grant notification write access to create an alert policy."
        )
        .dashSectionBoundary(showsRecommended || !allowsWrites)
      } else {
        DashListGroup(title: "Policies") {
          dashListCard {
            dashModeListRows(mode: mode, items: policies, reduceMotion: reduceMotion) {
              policy in
              Button {
                deleteError = nil
                detail = policy
              } label: {
                DashListRow(
                  title: policy.title,
                  subtitle: policy.enabled == false
                    ? DashL10n.string("Disabled") : policy.alertType,
                  icon: SolarAsset.Content.bolt,
                  showsChevron: false
                )
              }
              .buttonStyle(DashSurfaceButtonStyle())
            }
          }
        }
        .dashSectionBoundary(
          !mode.isPlaceholder && (showsRecommended || !allowsWrites))
      }
    }
    .detailHeader(icon: .solar(SolarAsset.Content.inbox), title: "Alert policies")
    .dashPageActions(
      trailing: allowsWrites && storedWebhookID != nil
        ? [
          .icon(
            id: "push-alerts-create-policy",
            asset: SolarAsset.plus,
            accessibilityLabel: DashL10n.string("Create alert policy")
          ) {
            creatingPolicy = true
          }
        ] : []
    )
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) {
      resetForAccountChange()
      await load()
    }
    .dashTray(isPresented: $creatingPolicy, title: "Create alert policy") {
      if let webhookID = storedWebhookID {
        AlertPolicyCreateForm(webhookID: webhookID, groups: groups) {
          creatingPolicy = false
          Task { await load(force: true) }
        }
      }
    }
    .dashTray(
      item: $detail,
      title: { $0.title },
      content: { policy in
        DashDetailTray(
          fields: [
            DashDetailField(label: "Type", value: policy.alertType ?? "—"),
            DashDetailField(
              label: DashL10n.string("Frequency"),
              value: AlertDigestInterval(rawValue: policy.alertInterval ?? "")?.title
                ?? policy.alertInterval
                ?? AlertDigestInterval.everyOccurrence.title),
            DashDetailField(
              label: DashL10n.string("Enabled"),
              value: DashL10n.string(policy.enabled == false ? "No" : "Yes")),
          ],
          deleteMessage: allowsWrites
            ? DashL10n.string("Permanently delete the policy \(policy.title).") : nil,
          deletePhase: deletePhase,
          onDeleteSuccessPresentationCompleted: completeDeletePresentation,
          deleteError: deleteError,
          onDelete: allowsWrites ? { Task { await deletePolicy(policy) } } : nil
        ) {
          if allowsWrites {
            DashActionButton(
              title: policy.enabled == false ? "Enable policy" : "Disable policy",
              phase: togglePhase,
              onSuccessPresentationCompleted: completeTogglePresentation
            ) {
              Task { await toggle(policy) }
            }
          } else {
            FeatureWriteAccessNotice(
              message: "Read-only — grant notification write access to change this policy.",
              scopes: PushAlertScopes.write)
          }
        }
      }
    )
  }

  private var storedWebhookID: String? {
    model.activeAccountID.flatMap { PushRegistrationService.storedWebhookID(accountID: $0) }
  }

  private var available: [AvailableAlert] { groups.flatMap(\.alerts) }

  private var recommendedOptions: [(type: String, name: String)] {
    Self.recommendedTypes.filter { candidate in
      available.contains(where: { $0.type == candidate.type })
        && !policies.contains(where: { $0.alertType == candidate.type })
    }
  }

  private var showsRecommended: Bool {
    allowsWrites && storedWebhookID != nil && !recommendedOptions.isEmpty
  }

  private func resetForAccountChange() {
    policies = []
    groups = []
    loading = true
    error = nil
    creatingPolicy = false
    applyingPreset = nil
    presetPhase = .idle
    detail = nil
    togglePhase = .idle
    pendingPolicyUpdate = nil
    deletePhase = .idle
    deleteError = nil
    hasPresentedContent = false
  }

  private func recommendedCard(webhookID: String) -> some View {
    DashListGroup(title: "Recommended") {
      dashListCard {
        ForEach(Array(recommendedOptions.enumerated()), id: \.element.type) { index, option in
          if index > 0 { DashListGroupDivider() }
          Button {
            Task { await enablePreset(option.type, name: option.name, webhookID: webhookID) }
          } label: {
            HStack {
              DashListRow(
                title: DashL10n.ui(option.name),
                subtitle: option.type,
                icon: SolarAsset.Content.bolt,
                showsChevron: false
              )
              if applyingPreset == option.type {
                DashActionStatusIcon(
                  phase: presetPhase,
                  loadingColor: DashTheme.brand,
                  successColor: DashTheme.brand,
                  onSuccessPresentationCompleted: completePresetPresentation
                )
                .padding(.trailing, 16)
              }
            }
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .dashListCardInset()
          .disabled(presetPhase.isActive || loading)
        }
      }
    }
  }

  private func load(force: Bool = false) async {
    guard let context = model.accountRequestContext else {
      loading = false
      return
    }
    let accountID = context.accountID
    if !hasPresentedContent || force { loading = true }
    error = nil
    do {
      async let policiesTask = model.client.listNotificationPolicies(accountID: accountID)
      async let availableTask = model.client.listAvailableAlertGroups(accountID: accountID)
      let (fetchedPolicies, fetchedGroups) = try await (policiesTask, availableTask)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      policies = fetchedPolicies.filter {
        !PushRegistrationService.usesBuildActivityPath(alertType: $0.alertType)
      }
      groups = fetchedGroups.compactMap { group in
        let alerts = group.alerts.filter {
          !PushRegistrationService.usesBuildActivityPath(alertType: $0.type)
        }
        return alerts.isEmpty ? nil : AvailableAlertGroup(category: group.category, alerts: alerts)
      }
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
    }
    guard model.isCurrentAccount(context) else { return }
    loading = false
    // Warm only settles on a real answer: a stored webhook id alone proves
    // nothing about the policy list, and flipping it here presented a failed
    // cold load as the settled "No alert policies" empty state instead of the
    // skeleton's failure veil.
    if error == nil || !policies.isEmpty {
      hasPresentedContent = true
    }
  }

  private func enablePreset(_ type: String, name: String, webhookID: String) async {
    guard model.hasScopes(PushAlertScopes.write) else {
      model.requestAccess(to: PushAlertScopes.write)
      return
    }
    guard let context = model.accountRequestContext else { return }
    let accountID = context.accountID
    applyingPreset = type
    presetPhase = .loading
    do {
      _ = try await model.client.createNotificationPolicy(
        accountID: accountID,
        input: NotificationPolicyInput(
          name: "Dash · \(name)",
          alertType: type,
          enabled: true,
          mechanisms: NotificationMechanisms(webhooks: [
            NotificationMechanismTarget(id: webhookID)
          ])
        ))
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        presetPhase = .idle
        applyingPreset = nil
        return
      }
      model.toasts.success(DashL10n.string("Created successfully."))
      presetPhase = .succeeded
    } catch {
      presetPhase = .idle
      applyingPreset = nil
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func completePresetPresentation() {
    guard presetPhase == .succeeded else {
      presetPhase = .idle
      applyingPreset = nil
      return
    }
    presetPhase = .idle
    applyingPreset = nil
    Task { await load(force: true) }
  }

  private func toggle(_ policy: NotificationPolicy) async {
    guard model.hasScopes(PushAlertScopes.write) else {
      model.requestAccess(to: PushAlertScopes.write)
      return
    }
    guard let context = model.accountRequestContext else { return }
    let accountID = context.accountID
    togglePhase = .loading
    do {
      let updated = try await model.client.updateNotificationPolicy(
        accountID: accountID,
        policyID: policy.id,
        input: policy.input(enabled: !(policy.enabled ?? true)))
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        if model.isCurrentAccount(context) { togglePhase = .idle }
        return
      }
      pendingPolicyUpdate = updated
      let enabled = updated.enabled ?? true
      model.toasts.success(
        DashL10n.string(enabled ? "Policy enabled." : "Policy disabled."))
      togglePhase = .succeeded
    } catch {
      guard model.isCurrentAccount(context) else { return }
      togglePhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      model.toasts.error(error.dashActionableMessage)
    }
  }

  private func completeTogglePresentation() {
    guard togglePhase == .succeeded, let updated = pendingPolicyUpdate else {
      togglePhase = .idle
      return
    }
    pendingPolicyUpdate = nil
    togglePhase = .idle
    detail = updated
    Task { await load(force: true) }
  }

  private func deletePolicy(_ policy: NotificationPolicy) async {
    guard model.hasScopes(PushAlertScopes.write) else {
      model.requestAccess(to: PushAlertScopes.write)
      return
    }
    guard let context = model.accountRequestContext else { return }
    let accountID = context.accountID
    deletePhase = .loading
    deleteError = nil
    do {
      try await model.client.deleteNotificationPolicy(
        accountID: accountID, policyID: policy.id)
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        deletePhase = .idle
        return
      }
      model.toasts.success(DashL10n.string("Deleted successfully."))
      deletePhase = .succeeded
    } catch {
      deletePhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      deleteError = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func completeDeletePresentation() {
    guard deletePhase == .succeeded else { return }
    deletePhase = .idle
    detail = nil
    Task { await load(force: true) }
  }
}

/// How often one policy may fire. Cloudflare rolls repeated triggers up into a
/// single delivery per window, which is the difference between one L7 attack
/// and fourteen identical notifications.
///
/// Not every alert type accepts an interval; Cloudflare rejects the ones that
/// do not. `everyOccurrence` sends no `alert_interval` at all, so the default
/// stays exactly what it was before this control existed.
enum AlertDigestInterval: String, CaseIterable, Identifiable {
  case everyOccurrence = ""
  case fiveMinutes = "5m"
  case fifteenMinutes = "15m"
  case thirtyMinutes = "30m"
  case oneHour = "1h"

  var id: String { rawValue }

  var apiValue: String? { rawValue.isEmpty ? nil : rawValue }

  var title: String {
    switch self {
    case .everyOccurrence: DashL10n.string("Every occurrence")
    case .fiveMinutes: DashL10n.string("At most every 5 minutes")
    case .fifteenMinutes: DashL10n.string("At most every 15 minutes")
    case .thirtyMinutes: DashL10n.string("At most every 30 minutes")
    case .oneHour: DashL10n.string("At most every hour")
    }
  }
}

/// Create an alert policy bound to a specific webhook by id.
private struct AlertPolicyCreateForm: View {
  @Environment(AppModel.self) private var model
  let webhookID: String
  let groups: [AvailableAlertGroup]
  let onCreated: () -> Void

  @State private var name = ""
  @State private var selectedType = ""
  @State private var interval: AlertDigestInterval = .everyOccurrence
  @State private var actionPhase: DashActionPhase = .idle
  @State private var saveError: String?

  private var alerts: [AvailableAlert] { groups.flatMap(\.alerts) }

  private var allowsWrites: Bool {
    model.hasScopes(PushAlertScopes.write)
  }

  var body: some View {
    DashFormSheet(
      saveTitle: allowsWrites
        ? "Create" : (model.isDemoSession ? "Connect your account" : "Grant access"),
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completeCreatePresentation,
      canSave: allowsWrites ? !name.isEmpty && !selectedType.isEmpty : true,
      onSave: {
        if allowsWrites {
          Task { await create() }
        } else {
          model.requestAccess(to: PushAlertScopes.write)
        }
      },
      content: {
        VStack(alignment: .leading, spacing: 16) {
          if !allowsWrites {
            DashNotice(
              kind: .warning,
              message:
                model.isDemoSession
                ? "Connect your account when you are ready to make changes"
                : "Dash requests all permissions used by its current features in one authorization."
            )
          }
          if let saveError {
            DashNotice(kind: .error, message: saveError)
          }
          Group {
            DashFormField(label: "Policy name", text: $name)
            if alerts.isEmpty {
              DashNotice(
                kind: .warning,
                message: "No alert types were returned for this account.")
            } else {
              alertTypeMenu
              intervalMenu
            }
          }
          .disabled(!allowsWrites)
        }
      }
    )
    .dashTrayDescription(
      DashL10n.string(
        "Delivers through your Dash webhook. Alert text is forwarded via dash.xat.sh to this iPhone."
      )
    )
    .onAppear {
      if selectedType.isEmpty {
        selectedType = alerts.first?.type ?? ""
      }
    }
  }

  /// Sectioned by Cloudflare's own product grouping — a flat list of forty-odd
  /// types is unreadable, and the account may expose a very different set.
  private var alertTypeMenu: some View {
    formMenu(label: "Alert type", value: selectedLabel) {
      Picker("Alert type", selection: $selectedType) {
        ForEach(groups) { group in
          Section(DashL10n.ui(group.category)) {
            ForEach(group.alerts) { alert in
              Text(alert.title).tag(alert.type ?? "")
            }
          }
        }
      }
    }
  }

  private var intervalMenu: some View {
    formMenu(label: "Frequency", value: interval.title) {
      Picker("Frequency", selection: $interval) {
        ForEach(AlertDigestInterval.allCases) { option in
          Text(option.title).tag(option)
        }
      }
    }
  }

  private func formMenu(
    label: LocalizedStringKey,
    value: String,
    @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label)
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      Menu {
        content()
      } label: {
        HStack(spacing: 8) {
          Text(value)
            .dashTextStyle(.bodyMedium)
            .foregroundStyle(DashTheme.text)
          Spacer(minLength: 0)
          SolarIcon(
            asset: SolarAsset.chevronRight, size: DashTheme.Chevron.compact,
            color: DashTheme.placeholder
          )
          .rotationEffect(.degrees(90))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashTheme.recessed)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
      }
    }
  }

  private var selectedLabel: String {
    alerts.first { $0.type == selectedType }?.title ?? DashL10n.string("Choose an alert type")
  }

  private func create() async {
    guard allowsWrites else {
      model.requestAccess(to: PushAlertScopes.write)
      return
    }
    guard let context = model.accountRequestContext, !selectedType.isEmpty else { return }
    let accountID = context.accountID
    actionPhase = .loading
    saveError = nil
    do {
      _ = try await model.client.createNotificationPolicy(
        accountID: accountID,
        input: NotificationPolicyInput(
          name: name,
          alertType: selectedType,
          enabled: true,
          alertInterval: interval.apiValue,
          mechanisms: NotificationMechanisms(webhooks: [
            NotificationMechanismTarget(id: webhookID)
          ])
        ))
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        actionPhase = .idle
        return
      }
      model.toasts.success(DashL10n.string("Created successfully."))
      actionPhase = .succeeded
    } catch {
      actionPhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      saveError = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func completeCreatePresentation() {
    guard actionPhase == .succeeded else {
      actionPhase = .idle
      return
    }
    actionPhase = .idle
    onCreated()
  }
}
