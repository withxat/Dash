import CloudflareAPI
import Foundation
import Testing
import UserNotifications

@testable import Dash

// MARK: - Notification action routing

@Test func notificationActionRetargetsTheSameZone() {
  let delivered = DashRoute.parse(URL(string: "dash://zone/z1?account=acc-1")!)!

  let purge = DashNotificationCategory.route(
    forAction: "dash.action.purge",
    category: DashNotificationCategory.zoneOrigin.rawValue,
    notificationRoute: delivered)
  #expect(purge == DashRoute.zoneCache("z1").scoped(to: "acc-1"))

  let security = DashNotificationCategory.route(
    forAction: "dash.action.security",
    category: DashNotificationCategory.zoneAttack.rawValue,
    notificationRoute: delivered)
  #expect(security == DashRoute.zoneWAF("z1").scoped(to: "acc-1"))
}

@Test func notificationActionKeepsTheAccountScope() {
  // The account binding is the app's only defence against opening a resource
  // under whichever account happens to be active. An action must not drop it.
  let delivered = DashRoute.parse(URL(string: "dash://zone/z1?account=acc-1")!)!
  let route = DashNotificationCategory.route(
    forAction: "dash.action.purge",
    category: DashNotificationCategory.zoneOrigin.rawValue,
    notificationRoute: delivered)
  #expect(route.accountID == "acc-1")
}

@Test func plainTapKeepsTheDeliveredRoute() {
  let delivered = DashRoute.pagesDeployment(project: "docs", deploymentID: "dep-1")
  let tapped = DashNotificationCategory.route(
    forAction: UNNotificationDefaultActionIdentifier,
    category: DashNotificationCategory.pages.rawValue,
    notificationRoute: delivered)
  #expect(tapped == delivered)
}

@Test func unsatisfiableActionFallsBackToTheDeliveredRoute() {
  // A zone action on a Pages notification has no zone to retarget; opening
  // something unrelated would be worse than opening what the tap would.
  let delivered = DashRoute.pagesProject("docs")
  let route = DashNotificationCategory.route(
    forAction: "dash.action.purge",
    category: DashNotificationCategory.zoneOrigin.rawValue,
    notificationRoute: delivered)
  #expect(route == delivered)
}

@Test func pagesActionClimbsFromDeploymentToProject() {
  let delivered = DashRoute.pagesDeployment(project: "docs", deploymentID: "dep-1")
  let route = DashNotificationCategory.route(
    forAction: "dash.action.pagesProject",
    category: DashNotificationCategory.pages.rawValue,
    notificationRoute: delivered)
  #expect(route == DashRoute.pagesProject("docs"))
}

@Test func unknownCategoryOrActionIsInert() {
  let delivered = DashRoute.watchtower
  #expect(
    DashNotificationCategory.route(
      forAction: "dash.action.purge", category: "not.a.category", notificationRoute: delivered)
      == delivered)
  #expect(
    DashNotificationCategory.route(
      forAction: "dash.action.unknown",
      category: DashNotificationCategory.zoneOrigin.rawValue,
      notificationRoute: delivered) == delivered)
}

@Test func everyCategoryRegistersAtLeastOneAction() {
  // A category the relay names but the app gives no actions renders a
  // notification with buttons the user was promised and cannot see.
  for category in DashNotificationCategory.allCases {
    #expect(!category.actions.isEmpty, "\(category.rawValue) has no actions")
  }
}

// MARK: - Alert localization

@Test func localizationRewritesKnownTypesAndPassesTheRestThrough() {
  let previousLocale = DashAlertStrings.localeOverrideForTesting
  DashAlertStrings.localeOverrideForTesting = Locale(identifier: "en")
  defer { DashAlertStrings.localeOverrideForTesting = previousLocale }

  let known = AlertLocalization.rewrite(
    alertType: "http_alert_origin_error",
    subject: "example.com",
    originalBody: "Your origin returned 15 5xx errors.")
  #expect(known?.title == "Origin errors")
  #expect(known?.body.contains("example.com") == true)

  // Cloudflare adds alert types constantly; an unknown one must survive intact.
  #expect(
    AlertLocalization.rewrite(
      alertType: "some_future_alert",
      subject: "example.com",
      originalBody: "Something happened.") == nil)
  #expect(AlertLocalization.rewrite(alertType: nil, subject: nil, originalBody: "B") == nil)
}

@Test func localizationKeepsCloudflaresBodyWhenNoResourceIsNamed() {
  let previousLocale = DashAlertStrings.localeOverrideForTesting
  DashAlertStrings.localeOverrideForTesting = Locale(identifier: "en")
  defer { DashAlertStrings.localeOverrideForTesting = previousLocale }

  let rewrite = AlertLocalization.rewrite(
    alertType: "dos_attack_l7",
    subject: nil,
    originalBody: "Attack on example.com mitigated.")
  // Title localizes; the body still carries the detail we cannot restate.
  #expect(rewrite?.title == "L7 DDoS")
  #expect(rewrite?.body == "Attack on example.com mitigated.")
}

@Test func everyLocalizedAlertBodyResolvesAgainstTheCatalog() {
  // These strings go through DashAlertStrings, which check-l10n-keys does not
  // scan — a missing entry would silently ship English inside a Chinese app,
  // and only a non-English user would ever find out.
  //
  // Bodies only: several titles are product names ("L7 DDoS", "Universal SSL")
  // whose Chinese entry is legitimately identical, so they cannot be tested
  // this way.
  let previousLocale = DashAlertStrings.localeOverrideForTesting
  defer { DashAlertStrings.localeOverrideForTesting = previousLocale }

  for known in AlertLocalization.Known.allCases {
    DashAlertStrings.localeOverrideForTesting = Locale(identifier: "en")
    let english = known.body(subject: "example.com")
    DashAlertStrings.localeOverrideForTesting = Locale(identifier: "zh-Hans")
    let chinese = known.body(subject: "example.com")
    #expect(english != chinese, "\(known.rawValue) has no zh-Hans body in the catalog")
  }
}

// MARK: - Per-domain alert subscriptions

private func policy(
  id: String = "p1",
  name: String,
  alertType: String,
  enabled: Bool = true,
  zones: [String]?,
  webhookID: String? = "hook-1"
) throws -> NotificationPolicy {
  var payload: [String: Any] = [
    "id": id, "name": name, "alert_type": alertType, "enabled": enabled,
  ]
  if let zones { payload["filters"] = ["zones": zones] }
  if let webhookID { payload["mechanisms"] = ["webhooks": [["id": webhookID]]] }
  let data = try JSONSerialization.data(withJSONObject: payload)
  return try JSONDecoder().decode(NotificationPolicy.self, from: data)
}

@Test func subscriptionStateReadsTheZonesFilter() throws {
  let kind = ZoneAlertKind.all[0]
  let subscribed = try policy(
    name: ZoneAlertSubscriptions.policyName(for: kind),
    alertType: kind.alertType,
    zones: ["z1", "z2"])

  #expect(
    ZoneAlertSubscriptions.state(
      for: kind, zoneID: "z1", policies: [subscribed], webhookID: "hook-1") == .on)
  #expect(
    ZoneAlertSubscriptions.state(
      for: kind, zoneID: "z9", policies: [subscribed], webhookID: "hook-1") == .off)
  #expect(
    ZoneAlertSubscriptions.state(
      for: kind, zoneID: "z1", policies: [], webhookID: "hook-1") == .off)
}

@Test func anUnfilteredPolicyReadsAsAllDomainsNotAsOn() throws {
  // Cloudflare spells "every zone" as the *absence* of a filter. Showing that
  // as a plain on-switch would let one domain's toggle silently rewrite an
  // account-wide alert.
  let kind = ZoneAlertKind.all[0]
  let allZones = try policy(
    name: ZoneAlertSubscriptions.policyName(for: kind),
    alertType: kind.alertType,
    zones: nil)
  #expect(
    ZoneAlertSubscriptions.state(
      for: kind, zoneID: "z1", policies: [allZones], webhookID: "hook-1") == .allDomains)
  #expect(ZoneAlertSubscriptions.updatedZones(in: allZones, zoneID: "z1", subscribed: false) == nil)
}

@Test func aPolicyWithoutOurWebhookIsNotManaged() throws {
  // Subscribing through a policy that lost its webhook binding would build a
  // switch that turns on nothing.
  let kind = ZoneAlertKind.all[0]
  let orphan = try policy(
    name: ZoneAlertSubscriptions.policyName(for: kind),
    alertType: kind.alertType,
    zones: ["z1"],
    webhookID: nil)
  #expect(
    ZoneAlertSubscriptions.managedPolicy(
      for: kind, policies: [orphan], webhookID: "hook-1") == nil)
  #expect(
    ZoneAlertSubscriptions.state(
      for: kind, zoneID: "z1", policies: [orphan], webhookID: "hook-1") == .off)
}

@Test func aHandWrittenPolicyIsNeverRewrittenByADomainToggle() throws {
  let kind = ZoneAlertKind.all[0]
  let userOwned = try policy(
    name: "My own origin alert",
    alertType: kind.alertType,
    zones: ["z1"])
  #expect(
    ZoneAlertSubscriptions.managedPolicy(
      for: kind, policies: [userOwned], webhookID: "hook-1") == nil)
}

@Test func togglingEditsOnlyTheZonesFilter() throws {
  let kind = ZoneAlertKind.all[0]
  let existing = try policy(
    name: ZoneAlertSubscriptions.policyName(for: kind),
    alertType: kind.alertType,
    zones: ["z1", "z2"])

  let added = ZoneAlertSubscriptions.updatedZones(in: existing, zoneID: "z3", subscribed: true)
  #expect(added == ["z1", "z2", "z3"])
  let removed = ZoneAlertSubscriptions.updatedZones(in: existing, zoneID: "z2", subscribed: false)
  #expect(removed == ["z1"])
  // Redundant toggles are no-ops rather than needless PUTs.
  #expect(ZoneAlertSubscriptions.updatedZones(in: existing, zoneID: "z1", subscribed: true) == nil)
  #expect(ZoneAlertSubscriptions.updatedZones(in: existing, zoneID: "z9", subscribed: false) == nil)

  let input = ZoneAlertSubscriptions.input(from: existing, zones: ["z1"])
  #expect(input.filters?["zones"] == ["z1"])
  #expect(input.alertType == kind.alertType)
  #expect(input.mechanisms?.webhooks?.first?.id == "hook-1")
}

@Test func aDisabledManagedPolicyReadsAsOff() throws {
  let kind = ZoneAlertKind.all[0]
  let disabled = try policy(
    name: ZoneAlertSubscriptions.policyName(for: kind),
    alertType: kind.alertType,
    enabled: false,
    zones: ["z1"])
  #expect(
    ZoneAlertSubscriptions.state(
      for: kind, zoneID: "z1", policies: [disabled], webhookID: "hook-1") == .off)
}
