import CloudflareAPI
import Foundation

/// An alert type Dash offers to subscribe per domain.
///
/// Deliberately short. Cloudflare accepts a `zones` filter on many more alert
/// types, but a per-domain switch is only honest for alerts that are *about* one
/// domain — a per-domain toggle for an account-wide alert would filter nothing
/// and quietly notify about everything.
struct ZoneAlertKind: Identifiable, Hashable, Sendable {
  let alertType: String
  let title: String
  let subtitle: String

  var id: String { alertType }

  static let all: [ZoneAlertKind] = [
    ZoneAlertKind(
      alertType: "http_alert_origin_error",
      title: DashL10n.string("Origin errors"),
      subtitle: DashL10n.string("Your server starts returning 5xx")),
    ZoneAlertKind(
      alertType: "dos_attack_l7",
      title: DashL10n.string("L7 DDoS"),
      subtitle: DashL10n.string("Cloudflare mitigates an attack on this domain")),
  ]
}

/// Whether one domain is covered by a Dash-managed policy for one alert type.
enum ZoneAlertState: Equatable, Sendable {
  case off
  case on
  /// A managed policy exists with no zone filter, so it already covers this
  /// domain — and every other one.
  ///
  /// This is not a toggle. Cloudflare expresses "all zones" as the *absence* of
  /// a filter, so switching it off for one domain would mean inventing an
  /// explicit list of every remaining zone, and switching it on would silently
  /// widen an alert the user scoped somewhere else. Dash shows the state and
  /// leaves the edit to the policy screen.
  case allDomains
}

/// Per-domain alert subscriptions expressed as Cloudflare notification policy
/// filters.
///
/// Dash keeps **one policy per alert type** and moves zone ids in and out of its
/// `zones` filter, rather than creating a policy per domain. Cloudflare's
/// policy list is shared with the dashboard and has no folder structure; fifty
/// domains would otherwise mean fifty near-identical rows there.
enum ZoneAlertSubscriptions {
  static let zonesFilterKey = "zones"

  /// Marks the policies this screen owns. A policy the user made by hand keeps
  /// its own name and is never rewritten by a per-domain toggle.
  static func policyName(for kind: ZoneAlertKind) -> String {
    "Dash · \(kind.title)"
  }

  /// The Dash-managed policy for an alert type: ours by name, and actually
  /// wired to this device's webhook. A policy that lost its webhook binding is
  /// not treated as managed — subscribing through it would create a switch that
  /// turns on nothing.
  static func managedPolicy(
    for kind: ZoneAlertKind,
    policies: [NotificationPolicy],
    webhookID: String
  ) -> NotificationPolicy? {
    policies.first { policy in
      policy.alertType == kind.alertType
        && policy.name == policyName(for: kind)
        && policy.mechanisms?.webhooks?.contains(where: { $0.id == webhookID }) == true
    }
  }

  static func state(
    for kind: ZoneAlertKind,
    zoneID: String,
    policies: [NotificationPolicy],
    webhookID: String
  ) -> ZoneAlertState {
    guard
      let policy = managedPolicy(for: kind, policies: policies, webhookID: webhookID),
      policy.enabled != false
    else {
      return .off
    }
    guard let zones = policy.filters?[zonesFilterKey], !zones.isEmpty else {
      return .allDomains
    }
    return zones.contains(zoneID) ? .on : .off
  }

  /// The zone list a policy should carry after a toggle. Returns nil when the
  /// change is not expressible — an all-domains policy, or an unsubscribe that
  /// changes nothing.
  static func updatedZones(
    in policy: NotificationPolicy,
    zoneID: String,
    subscribed: Bool
  ) -> [String]? {
    let current = policy.filters?[zonesFilterKey] ?? []
    if current.isEmpty { return nil }
    if subscribed {
      guard !current.contains(zoneID) else { return nil }
      return current + [zoneID]
    }
    guard current.contains(zoneID) else { return nil }
    return current.filter { $0 != zoneID }
  }

  /// Read-modify-write input that swaps only the zones filter, preserving the
  /// interval, description, and mechanisms Cloudflare returned.
  static func input(
    from policy: NotificationPolicy,
    zones: [String]
  ) -> NotificationPolicyInput {
    var input = policy.input()
    var filters = policy.filters ?? [:]
    filters[zonesFilterKey] = zones
    input.filters = filters
    return input
  }

  /// A fresh single-domain policy bound to this device's webhook.
  static func creationInput(
    for kind: ZoneAlertKind,
    zoneID: String,
    webhookID: String
  ) -> NotificationPolicyInput {
    NotificationPolicyInput(
      name: policyName(for: kind),
      alertType: kind.alertType,
      enabled: true,
      filters: [zonesFilterKey: [zoneID]],
      mechanisms: NotificationMechanisms(webhooks: [
        NotificationMechanismTarget(id: webhookID)
      ])
    )
  }
}
