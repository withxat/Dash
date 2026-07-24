import CloudflareAPI
import SwiftUI
import UIKit

/// Settings card + full alerts screen for Cloudflare → APNs push.
struct PushAlertsSettingsCard: View {
  @Environment(AppModel.self) private var model
  @State private var pushEnabled = false
  @State private var pushBusy = false
  @State private var pushError: String?
  @State private var testBusy = false
  private static let requiredScopes: Set<String> = [
    "notifications.read", "notifications.write",
  ]

  var body: some View {
    DashListGroup(title: "Push alerts") {
      dashListCard {
        VStack(alignment: .leading, spacing: 10) {
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
    .task(id: model.activeAccountID) {
      syncPushToggle()
      await reconcilePushIfNeeded()
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
    guard let accountID = model.activeAccountID else {
      pushEnabled = false
      return
    }
    guard model.hasScopes(Self.requiredScopes) else {
      pushEnabled = PushRegistrationService.isEnabled(accountID: accountID)
      model.requestAccess(to: Self.requiredScopes)
      return
    }
    pushBusy = true
    pushError = nil
    do {
      if enabled {
        let granted = await WatchtowerNotifier.requestAuthorization()
        guard granted else {
          pushError = "Notifications are turned off in Settings."
          pushEnabled = false
          pushBusy = false
          return
        }
        guard let token = await PushRegistrationService.waitForDeviceToken(in: model) else {
          throw PushRegistrationError.missingDeviceToken
        }
        try await PushRegistrationService.enable(
          accountID: accountID, client: model.client,
          configuration: model.configuration, deviceToken: token)
        pushEnabled = true
        model.toasts.success(DashL10n.string("Push alerts enabled."))
      } else {
        try await PushRegistrationService.disable(accountID: accountID, client: model.client)
        pushEnabled = false
        model.toasts.success(DashL10n.string("Push alerts turned off."))
      }
    } catch {
      pushError = error.dashActionableMessage
      syncPushToggle()
      DashDelight.failError()
    }
    pushBusy = false
  }

  private func reconcilePushIfNeeded() async {
    guard let accountID = model.activeAccountID,
      PushRegistrationService.isEnabled(accountID: accountID),
      let token = model.pendingDeviceToken
    else { return }
    try? await PushRegistrationService.reconcile(
      accountID: accountID, client: model.client,
      configuration: model.configuration, deviceToken: token)
  }

  private func sendTest() async {
    testBusy = true
    defer { testBusy = false }
    do {
      guard let token = await PushRegistrationService.waitForDeviceToken(in: model) else {
        throw PushRegistrationError.missingDeviceToken
      }
      try await PushRegistrationService.sendTestAlert(
        configuration: model.configuration,
        deviceToken: token)
      model.toasts.success(DashL10n.string("Test alert sent. It should appear in a moment."))
    } catch {
      model.toasts.error(error.dashActionableMessage)
    }
  }
}

/// Manage Cloudflare notification policies bound to the Dash webhook.
struct PushAlertsView: View {
  @Environment(AppModel.self) private var model
  @State private var policies: [NotificationPolicy] = []
  @State private var available: [AvailableAlert] = []
  @State private var loading = true
  @State private var error: String?
  @State private var creatingPolicy = false
  @State private var applyingPreset: String?
  @State private var detail: NotificationPolicy?
  @State private var toggling = false
  @State private var deleting = false
  @State private var deleteError: String?

  private static let recommendedTypes: [(type: String, name: String)] = [
    ("http_alert_origin_error", "Origin errors"),
    ("dos_attack_l7", "L7 DDoS"),
    ("real_origin_monitoring", "Origin monitoring"),
    ("universal_ssl_event_type", "Universal SSL"),
  ]

  /// False until the first load settles — webhook id alone must not flip Warm
  /// and show Updating… over an empty shell.
  @State private var hasPresentedContent = false

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: hasPresentedContent,
      retry: { Task { await load(force: true) } }
    ) {
      if let webhookID = storedWebhookID, showsRecommended {
        recommendedCard(webhookID: webhookID)
      }

      if policies.isEmpty {
        DashEmptyState(
          icon: SolarAsset.Content.bolt,
          title: "No alert policies",
          message: "Create a policy or enable a recommended alert to reach this iPhone."
        )
        .dashSectionBoundary(showsRecommended)
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
        .dashSectionBoundary(showsRecommended)
      }
    }
    .detailHeader(icon: .solar(SolarAsset.inbox), title: "Push alerts")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if storedWebhookID != nil {
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
    .task(id: model.activeAccountID) { await load() }
    .dashTray(isPresented: $creatingPolicy, title: "Create alert policy") {
      if let webhookID = storedWebhookID {
        AlertPolicyCreateForm(webhookID: webhookID, alerts: available) {
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
            DashDetailField(label: DashL10n.string("Type"), value: policy.alertType ?? "—"),
            DashDetailField(
              label: DashL10n.string("Enabled"),
              value: DashL10n.string(policy.enabled == false ? "No" : "Yes")),
          ],
          deleteMessage: DashL10n.string("Permanently delete the policy \(policy.title)."),
          isDeleting: deleting,
          deleteError: deleteError,
          onDelete: { Task { await deletePolicy(policy) } }
        ) {
          DashActionButton(
            title: policy.enabled == false ? "Enable policy" : "Disable policy",
            isLoading: toggling
          ) {
            Task { await toggle(policy) }
          }
        }
      }
    )
  }

  private var storedWebhookID: String? {
    model.activeAccountID.flatMap { PushRegistrationService.storedWebhookID(accountID: $0) }
  }

  private var recommendedOptions: [(type: String, name: String)] {
    Self.recommendedTypes.filter { candidate in
      available.contains(where: { $0.type == candidate.type })
        && !policies.contains(where: { $0.alertType == candidate.type })
    }
  }

  private var showsRecommended: Bool {
    storedWebhookID != nil && !recommendedOptions.isEmpty
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
    guard let accountID = model.activeAccountID else {
      loading = false
      return
    }
    if !hasPresentedContent || force { loading = true }
    error = nil
    do {
      async let policiesTask = model.client.listNotificationPolicies(accountID: accountID)
      async let availableTask = model.client.listAvailableAlerts(accountID: accountID)
      policies = try await policiesTask
      available = try await availableTask
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
    if error == nil || !policies.isEmpty || storedWebhookID != nil {
      hasPresentedContent = true
    }
  }

  private func enablePreset(_ type: String, name: String, webhookID: String) async {
    guard let accountID = model.activeAccountID else { return }
    applyingPreset = type
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
      model.toasts.success(DashL10n.string("Created successfully."))
      await load(force: true)
    } catch {
      self.error = error.dashActionableMessage
      DashDelight.failError()
    }
    applyingPreset = nil
  }

  private func toggle(_ policy: NotificationPolicy) async {
    guard let accountID = model.activeAccountID else { return }
    toggling = true
    do {
      let updated = try await model.client.updateNotificationPolicy(
        accountID: accountID,
        policyID: policy.id,
        input: policy.input(enabled: !(policy.enabled ?? true)))
      detail = updated
      let enabled = updated.enabled ?? true
      model.toasts.success(
        DashL10n.string(enabled ? "Policy enabled." : "Policy disabled."))
      await load(force: true)
    } catch {
      model.toasts.error(error.dashActionableMessage)
    }
    toggling = false
  }

  private func deletePolicy(_ policy: NotificationPolicy) async {
    guard let accountID = model.activeAccountID else { return }
    deleting = true
    deleteError = nil
    do {
      try await model.client.deleteNotificationPolicy(
        accountID: accountID, policyID: policy.id)
      detail = nil
      model.toasts.success(DashL10n.string("Deleted successfully."))
      await load(force: true)
    } catch {
      deleteError = error.dashActionableMessage
      DashDelight.failError()
    }
    deleting = false
  }
}

/// Create an alert policy bound to a specific webhook by id.
private struct AlertPolicyCreateForm: View {
  @Environment(AppModel.self) private var model
  let webhookID: String
  let alerts: [AvailableAlert]
  let onCreated: () -> Void

  @State private var name = ""
  @State private var selectedType = ""
  @State private var saving = false
  @State private var saveError: String?

  var body: some View {
    DashFormSheet(
      saveTitle: "Create",
      isSaving: saving,
      canSave: !name.isEmpty && !selectedType.isEmpty,
      onSave: { Task { await create() } },
      content: {
        VStack(alignment: .leading, spacing: 16) {
          if let saveError {
            DashNotice(kind: .error, message: saveError)
          }
          DashFormField(label: "Policy name", text: $name)
          if alerts.isEmpty {
            DashNotice(
              kind: .warning,
              message: "No alert types were returned for this account.")
          } else {
            alertTypeMenu
          }
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

  private var alertTypeMenu: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Alert type")
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      Menu {
        Picker("Alert type", selection: $selectedType) {
          ForEach(alerts) { alert in
            Text(alert.title).tag(alert.type ?? "")
          }
        }
      } label: {
        HStack(spacing: 8) {
          Text(selectedLabel)
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
    guard let accountID = model.activeAccountID, !selectedType.isEmpty else { return }
    saving = true
    saveError = nil
    do {
      _ = try await model.client.createNotificationPolicy(
        accountID: accountID,
        input: NotificationPolicyInput(
          name: name,
          alertType: selectedType,
          enabled: true,
          mechanisms: NotificationMechanisms(webhooks: [
            NotificationMechanismTarget(id: webhookID)
          ])
        ))
      model.toasts.success(DashL10n.string("Created successfully."))
      onCreated()
    } catch {
      saveError = error.dashActionableMessage
      DashDelight.failError()
    }
    saving = false
  }
}
