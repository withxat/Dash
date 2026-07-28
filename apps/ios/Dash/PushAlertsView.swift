import CloudflareAPI
import SwiftUI
import UIKit

private enum PushAlertScopes {
  static let read = readScopes(for: .pushAlerts)
  static let write = writeScopes(for: .pushAlerts)
  static let all = read.union(write)
}

/// Settings card + full alerts screen for Cloudflare → APNs push.
struct PushAlertsSettingsCard: View {
  @Environment(AppModel.self) private var model
  @State private var pushEnabled = false
  @State private var pushBusy = false
  @State private var pushError: String?
  @State private var testBusy = false
  @State private var isProvisional = false
  var body: some View {
    DashListGroup(title: "Push alerts") {
      dashListCard {
        VStack(alignment: .leading, spacing: 10) {
          if !model.hasScopes(PushAlertScopes.all) {
            DashAuthorizationDisclosure()
              .padding(.horizontal, 16)
              .padding(.top, 12)
          }

          DashToggleRow(
            title: "Push alerts",
            subtitle:
              "Forward Cloudflare notification policies to this iPhone through dash.xat.sh.",
            isOn: Binding(
              get: { pushEnabled },
              set: { newValue in
                pushEnabled = newValue
                Task { await setPushEnabled(newValue) }
              }
            ),
            isEnabled: !pushBusy && model.configuration.pushBaseURL != nil,
            isLoading: pushBusy
          )
          .accessibilityIdentifier("Push alerts")

          if model.configuration.pushBaseURL == nil {
            DashNotice(
              kind: .warning,
              message: "Push is unavailable until the OAuth redirect URI is configured."
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
          }

          if let pushError {
            DashNotice(kind: .error, message: pushError)
              .padding(.horizontal, 16)
              .padding(.bottom, 12)
          }

          if pushEnabled, isProvisional {
            // iOS granted quiet delivery without a dialog. Offer the upgrade
            // here rather than firing the system prompt at toggle time.
            Button {
              Task { await promoteDelivery() }
            } label: {
              Text(DashL10n.string("Deliver alerts prominently"))
                .dashTextStyle(.bodyMedium)
                .foregroundStyle(DashTheme.brand)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
            .buttonStyle(DashPressButtonStyle())
            .accessibilityIdentifier("Deliver alerts prominently")

            DashListGroupDivider()
          }

          if pushEnabled {
            Button {
              Task { await sendTest() }
            } label: {
              Text(DashL10n.string(testBusy ? "Sending…" : "Send test alert"))
                .dashTextStyle(.bodyMedium)
                .foregroundStyle(DashTheme.brand)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
            .buttonStyle(DashPressButtonStyle())
            .disabled(testBusy)
            .accessibilityIdentifier("Send test alert")

            DashListGroupDivider()

            DashListGroupLink(value: .pushAlerts) {
              DashListRow(
                title: DashL10n.string("Alert policies"),
                subtitle: DashL10n.string("Choose which Cloudflare alerts reach this iPhone"),
                icon: SolarAsset.Content.bolt
              )
            }
          }
        }
        .dashListCardInset()
      }
    }
    .task(id: model.accountRequestContext) {
      pushBusy = false
      pushError = nil
      testBusy = false
      syncPushToggle()
      isProvisional = await WatchtowerNotifier.isProvisional()
      await reconcilePushIfNeeded()
    }
  }

  /// Shows the system prompt so quiet Notification Center delivery becomes
  /// banners and sounds. A decline leaves the provisional grant intact.
  private func promoteDelivery() async {
    _ = await WatchtowerNotifier.requestAuthorization(prominently: true)
    isProvisional = await WatchtowerNotifier.isProvisional()
    if !isProvisional {
      model.toasts.success(DashL10n.string("Alerts will now appear as banners."))
    }
  }

  private func syncPushToggle() {
    guard let accountID = model.activeAccountID else {
      pushEnabled = false
      return
    }
    pushEnabled = PushRegistrationService.isEnabled(accountID: accountID)
  }

  private func setPushEnabled(_ enabled: Bool) async {
    guard let context = model.accountRequestContext else {
      pushEnabled = false
      return
    }
    let accountID = context.accountID
    guard model.hasScopes(PushAlertScopes.all) else {
      pushEnabled = PushRegistrationService.isEnabled(accountID: accountID)
      model.requestAccess(to: PushAlertScopes.all)
      return
    }
    pushBusy = true
    pushError = nil
    defer {
      if model.isCurrentAccount(context) {
        pushBusy = false
      }
    }
    do {
      if enabled {
        let granted = await WatchtowerNotifier.requestAuthorization()
        guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
        guard granted else {
          pushError = "Notifications are turned off in Settings."
          pushEnabled = false
          return
        }
        guard let token = await PushRegistrationService.waitForDeviceToken(in: model) else {
          throw PushRegistrationError.missingDeviceToken
        }
        guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
        try await PushRegistrationService.enable(
          accountID: accountID, client: model.client,
          configuration: model.configuration, deviceToken: token)
        guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
        pushEnabled = true
        model.toasts.success(DashL10n.string("Push alerts enabled."))
      } else {
        try await PushRegistrationService.disable(accountID: accountID, client: model.client)
        guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
        pushEnabled = false
        model.toasts.success(DashL10n.string("Push alerts turned off."))
      }
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      pushError = error.dashActionableMessage
      syncPushToggle()
      DashDelight.failError()
    }
  }

  private func reconcilePushIfNeeded() async {
    guard model.hasScopes(PushAlertScopes.all),
      let context = model.accountRequestContext,
      model.isCurrentAccount(context),
      let token = model.pendingDeviceToken,
      PushRegistrationService.isEnabled(accountID: context.accountID)
    else { return }
    let accountID = context.accountID
    try? await PushRegistrationService.reconcile(
      accountID: accountID, client: model.client,
      configuration: model.configuration, deviceToken: token)
  }

  private func sendTest() async {
    guard let context = model.accountRequestContext else { return }
    let accountID = context.accountID
    testBusy = true
    defer {
      if model.isCurrentAccount(context) {
        testBusy = false
      }
    }
    do {
      guard let token = await PushRegistrationService.waitForDeviceToken(in: model) else {
        throw PushRegistrationError.missingDeviceToken
      }
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      try await PushRegistrationService.sendTestAlert(
        accountID: accountID,
        configuration: model.configuration,
        deviceToken: token
      )
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      model.toasts.success(DashL10n.string("Test alert sent. It should appear in a moment."))
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      model.toasts.error(error.dashActionableMessage)
    }
  }
}

/// Manage Cloudflare notification policies bound to the Dash webhook.
struct PushAlertsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @State private var policies: [NotificationPolicy] = []
  @State private var groups: [AvailableAlertGroup] = []
  @State private var loading = true
  @State private var error: String?
  @State private var creatingPolicy = false
  @State private var applyingPreset: String?
  @State private var detail: NotificationPolicy?
  @State private var toggling = false
  @State private var deleting = false
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
    ("pages_event_alert", "Pages builds"),
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
    ) {
      if !allowsWrites {
        FeatureWriteAccessNotice(
          message: "Read-only — grant notification write access to manage alert policies.",
          scopes: PushAlertScopes.write)
      }

      if let webhookID = storedWebhookID, showsRecommended {
        recommendedCard(webhookID: webhookID)
          .dashSectionBoundary(!allowsWrites)
      }

      if policies.isEmpty {
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
            dashListCardRows(items: policies) { policy in
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
        .dashSectionBoundary(showsRecommended || !allowsWrites)
      }
    }
    .detailHeader(icon: .solar(SolarAsset.Content.inbox), title: "Push alerts")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if allowsWrites, storedWebhookID != nil {
          DashToolbarIconButton(
            asset: SolarAsset.plus, accessibilityLabel: "Create alert policy"
          ) {
            creatingPolicy = true
          }
        }
      }
      .dashSeparateToolbarBackground()
    }
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
          isDeleting: deleting,
          deleteError: deleteError,
          onDelete: allowsWrites ? { Task { await deletePolicy(policy) } } : nil
        ) {
          if allowsWrites {
            DashActionButton(
              title: policy.enabled == false ? "Enable policy" : "Disable policy",
              isLoading: toggling
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
    detail = nil
    toggling = false
    deleting = false
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
                DashLoadingRing(color: DashTheme.brand)
                  .frame(width: 22, height: 22)
                  .padding(.trailing, 16)
              }
            }
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .dashListCardInset()
          .disabled(applyingPreset != nil)
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
      policies = fetchedPolicies
      groups = fetchedGroups
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
    }
    guard model.isCurrentAccount(context) else { return }
    loading = false
    if error == nil || !policies.isEmpty || storedWebhookID != nil {
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
    defer {
      if model.isCurrentAccount(context) {
        applyingPreset = nil
      }
    }
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
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      model.toasts.success(DashL10n.string("Created successfully."))
      await load(force: true)
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func toggle(_ policy: NotificationPolicy) async {
    guard model.hasScopes(PushAlertScopes.write) else {
      model.requestAccess(to: PushAlertScopes.write)
      return
    }
    guard let context = model.accountRequestContext else { return }
    let accountID = context.accountID
    toggling = true
    defer {
      if model.isCurrentAccount(context) {
        toggling = false
      }
    }
    do {
      let updated = try await model.client.updateNotificationPolicy(
        accountID: accountID,
        policyID: policy.id,
        input: policy.input(enabled: !(policy.enabled ?? true)))
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      detail = updated
      let enabled = updated.enabled ?? true
      model.toasts.success(
        DashL10n.string(enabled ? "Policy enabled." : "Policy disabled."))
      await load(force: true)
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      model.toasts.error(error.dashActionableMessage)
    }
  }

  private func deletePolicy(_ policy: NotificationPolicy) async {
    guard model.hasScopes(PushAlertScopes.write) else {
      model.requestAccess(to: PushAlertScopes.write)
      return
    }
    guard let context = model.accountRequestContext else { return }
    let accountID = context.accountID
    deleting = true
    deleteError = nil
    defer {
      if model.isCurrentAccount(context) {
        deleting = false
      }
    }
    do {
      try await model.client.deleteNotificationPolicy(
        accountID: accountID, policyID: policy.id)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      detail = nil
      model.toasts.success(DashL10n.string("Deleted successfully."))
      await load(force: true)
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      deleteError = error.dashActionableMessage
      DashDelight.failError()
    }
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
  @State private var saving = false
  @State private var saveError: String?

  private var alerts: [AvailableAlert] { groups.flatMap(\.alerts) }

  private var allowsWrites: Bool {
    model.hasScopes(PushAlertScopes.write)
  }

  var body: some View {
    DashFormSheet(
      saveTitle: allowsWrites
        ? "Create" : (model.isDemoSession ? "Connect your account" : "Grant access"),
      isSaving: saving,
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
          Text(
            "Delivers through your Dash webhook. Alert text is forwarded via dash.xat.sh to this iPhone."
          )
          .dashTextStyle(.supporting)
          .foregroundStyle(DashTheme.subtle)
        }
      }
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
    saving = true
    saveError = nil
    defer {
      if model.isCurrentAccount(context) {
        saving = false
      }
    }
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
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      model.toasts.success(DashL10n.string("Created successfully."))
      onCreated()
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      saveError = error.dashActionableMessage
      DashDelight.failError()
    }
  }
}
