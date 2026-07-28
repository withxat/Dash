import CloudflareAPI
import SwiftUI

/// Per-domain alert switches on the zone settings screen.
///
/// This is where subscribing to an alert belongs: at the domain it is about,
/// not buried in Settings → Push alerts behind a policy form that asks for an
/// alert type id. Settings still owns the account-wide list; this owns "tell me
/// about *this* one".
struct ZoneAlertsSection: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  let zoneID: String

  @State private var policies: [NotificationPolicy] = []
  @State private var loaded = false
  @State private var busyAlertTypes: Set<String> = []
  @State private var error: String?

  private var webhookID: String? {
    model.activeAccountID.flatMap { PushRegistrationService.storedWebhookID(accountID: $0) }
  }

  private var allowsWrites: Bool {
    featureAllowsWrites && model.hasScopes(writeScopes(for: .pushAlerts))
  }

  var body: some View {
    // One `.task` on a container that is always present. Hanging it off the
    // rendered branch instead would re-fire the moment `loaded` flipped the
    // condition, costing a second fetch of the same policy list.
    Group {
      // Nothing to offer until push is on: a subscription with no destination
      // is a switch that delivers to nowhere.
      if let webhookID, loaded {
        DashListGroup(title: "Alerts") {
          DashSurfaceStack {
            ForEach(ZoneAlertKind.all) { kind in
              row(kind, webhookID: webhookID)
            }
          }
          if let error {
            DashNotice(kind: .error, message: error)
              .dashItemBoundary()
          }
        }
      }
    }
    .task(id: model.accountRequestContext) { await load() }
  }

  @ViewBuilder
  private func row(_ kind: ZoneAlertKind, webhookID: String) -> some View {
    let state = ZoneAlertSubscriptions.state(
      for: kind, zoneID: zoneID, policies: policies, webhookID: webhookID)

    switch state {
    case .allDomains:
      // Read-only on purpose: see ZoneAlertState.allDomains.
      DashValueCard(
        title: kind.title,
        value: DashL10n.string("On for all domains"))
    case .off, .on:
      DashToggleRow(
        title: kind.title,
        subtitle: kind.subtitle,
        isOn: Binding(
          get: { state == .on },
          set: { subscribed in
            Task { await apply(kind, subscribed: subscribed, webhookID: webhookID) }
          }),
        isEnabled: allowsWrites && !busyAlertTypes.contains(kind.alertType),
        isLoading: busyAlertTypes.contains(kind.alertType))
    }
  }

  private func load() async {
    guard let context = model.accountRequestContext, webhookID != nil, !model.isDemoSession,
      model.hasScopes(readScopes(for: .pushAlerts))
    else {
      loaded = true
      return
    }
    do {
      let fetched = try await model.client.listNotificationPolicies(
        accountID: context.accountID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      policies = fetched
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      // Silent: this is a secondary section on a settings screen, and a
      // notifications 403 must not make the zone's own settings look broken.
      policies = []
    }
    loaded = true
  }

  private func apply(_ kind: ZoneAlertKind, subscribed: Bool, webhookID: String) async {
    guard allowsWrites else {
      model.requestAccess(to: writeScopes(for: .pushAlerts))
      return
    }
    guard let context = model.accountRequestContext else { return }
    let accountID = context.accountID
    busyAlertTypes.insert(kind.alertType)
    error = nil
    defer {
      if model.isCurrentAccount(context) {
        busyAlertTypes.remove(kind.alertType)
      }
    }

    do {
      let existing = ZoneAlertSubscriptions.managedPolicy(
        for: kind, policies: policies, webhookID: webhookID)

      switch (existing, subscribed) {
      case (nil, true):
        _ = try await model.client.createNotificationPolicy(
          accountID: accountID,
          input: ZoneAlertSubscriptions.creationInput(
            for: kind, zoneID: zoneID, webhookID: webhookID))

      case (let policy?, _):
        guard
          let zones = ZoneAlertSubscriptions.updatedZones(
            in: policy, zoneID: zoneID, subscribed: subscribed)
        else { return }
        if zones.isEmpty {
          // The last domain left: keeping the policy with an empty filter would
          // read as "all domains" to Cloudflare — the opposite of off.
          try await model.client.deleteNotificationPolicy(
            accountID: accountID, policyID: policy.id)
        } else {
          _ = try await model.client.updateNotificationPolicy(
            accountID: accountID,
            policyID: policy.id,
            input: ZoneAlertSubscriptions.input(from: policy, zones: zones))
        }

      case (nil, false):
        return
      }

      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      await load()
      guard model.isCurrentAccount(context) else { return }
      model.toasts.success(
        DashL10n.string(subscribed ? "Alert turned on." : "Alert turned off."))
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
      DashDelight.failError()
      await load()
    }
  }
}
