import CloudflareAPI
import Foundation
import UIKit
import UserNotifications

enum NotificationRouteResolution: Equatable, Sendable {
  case open(DashRoute)
  case deferUntilAccountsLoad
  case rejectAmbiguous
}

enum NotificationRoutePolicy {
  /// Old delivered notifications may not contain an account. Preserve their
  /// destination only when exactly one account can own it; otherwise never
  /// reinterpret the resource under whichever account is currently active.
  static func resolve(
    _ route: DashRoute,
    availableAccountIDs: Set<String>,
    allowsLegacyAccountInference: Bool = true
  ) -> NotificationRouteResolution {
    if route.accountID != nil { return .open(route) }
    guard allowsLegacyAccountInference else { return .rejectAmbiguous }
    guard !availableAccountIDs.isEmpty else { return .deferUntilAccountsLoad }
    guard availableAccountIDs.count == 1, let accountID = availableAccountIDs.first else {
      return .rejectAmbiguous
    }
    return .open(route.scoped(to: accountID))
  }
}

/// Sink that receives APNs device tokens and silent wake-ups from `PushDelegate`.
@MainActor
protocol PushTokenInbox: AnyObject {
  func receiveDeviceToken(_ token: Data)
  /// A `content-available` push arrived: refresh Watchtower and the widget.
  func performPushTriggeredRefresh() async
}

/// UIApplicationDelegate that forwards device tokens into an explicit sink.
/// Prefer this over resolving App Intents' `AppDependencyManager` from the
/// delegate — that dependency surface is for intents, not system callbacks.
@MainActor
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  weak var inbox: (any PushTokenInbox)?

  nonisolated func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    DashNotificationCategory.registerAll()
    return true
  }

  /// Silent companion push from the relay. Refreshes Watchtower so the widget,
  /// the tab dot, and the badge are already right when the user looks — the
  /// alert they can see was delivered by its own push.
  nonisolated func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any]
  ) async -> UIBackgroundFetchResult {
    guard let inbox = await self.inbox else { return .noData }
    await inbox.performPushTriggeredRefresh()
    return .newData
  }

  nonisolated func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Task { @MainActor in
      inbox?.receiveDeviceToken(deviceToken)
    }
  }

  nonisolated func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    // Silent — push degrades; Watchtower local notifications still work.
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let content = response.notification.request.content
    let routeString = content.userInfo["dashRoute"] as? String
    let categoryIdentifier = content.categoryIdentifier
    let actionIdentifier = response.actionIdentifier
    Task { @MainActor in
      if let routeString, let url = URL(string: routeString), let route = DashRoute.parse(url),
        let model = inbox as? AppModel
      {
        // An action button retargets the same notification's route; the plain
        // tap keeps it. Either way the account scope rides along and is
        // re-checked before anything opens.
        model.receiveNotificationRoute(
          DashNotificationCategory.route(
            forAction: actionIdentifier,
            category: categoryIdentifier,
            notificationRoute: route))
      }
    }
    completionHandler()
  }

  /// Shows Cloudflare alerts even while Dash is open — the user is usually on a
  /// different screen than the one the alert is about.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }
}

enum PushRegistration {
  /// Hex device token for the relay's `/push/register` body.
  static func hexToken(from data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  #if DEBUG
    static let apnsEnvironment = "sandbox"
  #else
    static let apnsEnvironment = "production"
  #endif
}

/// Creates and maintains the Cloudflare webhook that forwards alerts to Dash's
/// APNs bridge. Server-side state lives in the user's own Cloudflare account;
/// Dash only remembers the webhook id per account in UserDefaults.
enum PushRegistrationService {
  private static let webhookIDPrefix = "dash.push.webhook_id."

  static func webhookIDKey(accountID: String) -> String {
    "\(webhookIDPrefix)\(accountID)"
  }

  static func storedWebhookID(accountID: String) -> String? {
    UserDefaults.standard.string(forKey: webhookIDKey(accountID: accountID))
  }

  static func isEnabled(accountID: String) -> Bool {
    storedWebhookID(accountID: accountID) != nil
  }

  static func enabledAccountIDs(in defaults: UserDefaults = .standard) -> [String] {
    Set(
      defaults.dictionaryRepresentation().keys.compactMap { key in
        guard key.hasPrefix(webhookIDPrefix) else { return nil }
        guard let webhookID = defaults.string(forKey: key), !webhookID.isEmpty else { return nil }
        let accountID = String(key.dropFirst(webhookIDPrefix.count))
        return accountID.isEmpty ? nil : accountID
      }
    ).sorted()
  }

  struct RelayRegistration: Decodable, Sendable {
    let url: String
    let secret: String
  }

  private static let webhookName = "Dash"

  /// Mint a signed notify URL from the relay, then create/update/adopt the
  /// Cloudflare webhook for this account.
  @MainActor
  static func enable(
    accountID: String,
    client: CloudflareClient,
    configuration: AppConfiguration,
    deviceToken: String
  ) async throws {
    guard let base = configuration.pushBaseURL else {
      throw PushRegistrationError.pushNotConfigured
    }
    let registration = try await registerWithRelay(
      baseURL: base,
      token: deviceToken,
      accountID: accountID
    )
    try Task.checkCancellation()
    let input = NotificationWebhookInput(
      name: webhookName, url: registration.url, secret: registration.secret)

    if let existingID = storedWebhookID(accountID: accountID) {
      do {
        let updated = try await client.updateNotificationWebhook(
          accountID: accountID, webhookID: existingID, input: input)
        store(webhookID: updated.id, accountID: accountID)
        try Task.checkCancellation()
        return
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try Task.checkCancellation()
        // Stale id — fall through to adopt or create.
      }
    }

    let webhooks = try await client.listNotificationWebhooks(accountID: accountID)
    try Task.checkCancellation()
    if let match = webhooks.first(where: { $0.url?.contains(deviceToken) == true }) {
      let updated = try await client.updateNotificationWebhook(
        accountID: accountID, webhookID: match.id, input: input)
      store(webhookID: updated.id, accountID: accountID)
      try Task.checkCancellation()
      return
    }

    try Task.checkCancellation()
    let created = try await client.createNotificationWebhook(accountID: accountID, input: input)
    store(webhookID: created.id, accountID: accountID)
    try Task.checkCancellation()
  }

  /// Delete the webhook (unbinding policies first if Cloudflare rejects the
  /// delete) and clear the local id.
  @MainActor
  static func disable(accountID: String, client: CloudflareClient) async throws {
    guard let webhookID = storedWebhookID(accountID: accountID) else { return }
    do {
      try await client.deleteNotificationWebhook(accountID: accountID, webhookID: webhookID)
    } catch {
      if isBadRequest(error) {
        try await unbind(webhookID: webhookID, accountID: accountID, client: client)
        try await client.deleteNotificationWebhook(accountID: accountID, webhookID: webhookID)
      } else {
        throw error
      }
    }
    clear(accountID: accountID)
  }

  /// Refresh the webhook URL when the device token rotates, if push is on.
  @MainActor
  static func reconcile(
    accountID: String,
    client: CloudflareClient,
    configuration: AppConfiguration,
    deviceToken: String
  ) async throws {
    guard isEnabled(accountID: accountID) else { return }
    try await enable(
      accountID: accountID, client: client, configuration: configuration,
      deviceToken: deviceToken)
  }

  /// Wait briefly for the system to deliver a device token after registration.
  @MainActor
  static func waitForDeviceToken(in model: AppModel, attempts: Int = 30) async -> String? {
    if let token = model.pendingDeviceToken { return token }
    UIApplication.shared.registerForRemoteNotifications()
    for _ in 0..<attempts {
      try? await Task.sleep(for: .milliseconds(100))
      if let token = model.pendingDeviceToken { return token }
    }
    return model.pendingDeviceToken
  }

  /// Mint a notify URL for the current token and POST a synthetic Cloudflare
  /// alert payload so the user can verify APNs end-to-end.
  @MainActor
  static func sendTestAlert(
    accountID: String,
    configuration: AppConfiguration,
    deviceToken: String
  ) async throws {
    guard let base = configuration.pushBaseURL else {
      throw PushRegistrationError.pushNotConfigured
    }
    let registration = try await registerWithRelay(
      baseURL: base,
      token: deviceToken,
      accountID: accountID
    )
    guard let notifyURL = URL(string: registration.url) else {
      throw PushRegistrationError.relayFailed(status: -1)
    }
    var request = URLRequest(url: notifyURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(registration.secret, forHTTPHeaderField: "cf-webhook-auth")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "name": "Dash test alert",
      "text": "Push is working. Cloudflare alerts will appear like this.",
      "alert_type": "dash_test",
    ])
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw PushRegistrationError.relayFailed(status: -1)
    }
    guard (200..<300).contains(http.statusCode) else {
      throw PushRegistrationError.relayFailed(status: http.statusCode)
    }
  }

  /// Clear every per-account webhook id (used on sign-out).
  static func clearAllStoredWebhookIDs() {
    let defaults = UserDefaults.standard
    for key in defaults.dictionaryRepresentation().keys
    where key.hasPrefix(webhookIDPrefix) {
      defaults.removeObject(forKey: key)
    }
  }

  private static func registerWithRelay(
    baseURL: URL,
    token: String,
    accountID: String
  ) async throws
    -> RelayRegistration
  {
    var request = URLRequest(url: baseURL.appending(path: "push/register"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode([
      "accountID": accountID,
      "token": token,
      "environment": PushRegistration.apnsEnvironment,
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw PushRegistrationError.relayFailed(status: -1)
    }
    guard (200..<300).contains(http.statusCode) else {
      throw PushRegistrationError.relayFailed(status: http.statusCode)
    }
    let registration = try JSONDecoder().decode(RelayRegistration.self, from: data)
    guard
      isAccountBoundNotifyURL(
        registration.url,
        accountID: accountID,
        relayBaseURL: baseURL)
    else {
      throw PushRegistrationError.relayAccountMismatch
    }
    return registration
  }

  static func isAccountBoundNotifyURL(
    _ rawURL: String,
    accountID: String,
    relayBaseURL: URL? = nil
  ) -> Bool {
    guard let url = URL(string: rawURL), let component = url.pathComponents.last else {
      return false
    }
    if let relayBaseURL {
      guard
        url.scheme == relayBaseURL.scheme,
        url.host == relayBaseURL.host,
        url.port == relayBaseURL.port
      else {
        return false
      }
    }
    guard url.query == nil, url.fragment == nil,
      url.path.hasPrefix("/push/notify/")
    else {
      return false
    }
    let fields = component.split(separator: ".", omittingEmptySubsequences: false)
    guard fields.count == 4,
      fields[0] == "sandbox" || fields[0] == "production",
      (64...200).contains(fields[1].count),
      fields[2] == accountID,
      fields[3].count == 64
    else {
      return false
    }
    return fields[1].allSatisfy(\.isHexDigit) && fields[3].allSatisfy(\.isHexDigit)
  }

  private static func unbind(
    webhookID: String, accountID: String, client: CloudflareClient
  ) async throws {
    let policies = try await client.listNotificationPolicies(accountID: accountID)
    for policy in policies {
      guard var mechanisms = policy.mechanisms,
        let hooks = mechanisms.webhooks,
        hooks.contains(where: { $0.id == webhookID })
      else { continue }
      mechanisms.webhooks = hooks.filter { $0.id != webhookID }
      var input = policy.input()
      input.mechanisms = mechanisms
      _ = try await client.updateNotificationPolicy(
        accountID: accountID, policyID: policy.id, input: input)
    }
  }

  private static func store(webhookID: String, accountID: String) {
    UserDefaults.standard.set(webhookID, forKey: webhookIDKey(accountID: accountID))
  }

  private static func clear(accountID: String) {
    UserDefaults.standard.removeObject(forKey: webhookIDKey(accountID: accountID))
  }

  private static func isBadRequest(_ error: Error) -> Bool {
    if case .request(let status, _) = error as? CloudflareAPIError { return status == 400 }
    return false
  }
}

enum PushRegistrationError: Error, LocalizedError {
  case pushNotConfigured
  case relayFailed(status: Int)
  case relayAccountMismatch
  case missingDeviceToken

  var errorDescription: String? {
    switch self {
    case .pushNotConfigured:
      return DashL10n.string("Push alerts are not configured for this build.")
    case .relayFailed(let status):
      return DashL10n.string("Could not register with the push relay (HTTP \(status)).")
    case .relayAccountMismatch:
      return DashL10n.string(
        "The push relay did not bind this notification to the selected Cloudflare account.")
    case .missingDeviceToken:
      return DashL10n.string(
        "This device has not received an APNs token yet. Try again in a moment.")
    }
  }
}
