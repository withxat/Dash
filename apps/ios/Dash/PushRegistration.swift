import CloudflareAPI
import Foundation
import UIKit
import UserNotifications

/// Sink that receives APNs device tokens from `PushDelegate`.
@MainActor
protocol PushTokenInbox: AnyObject {
  func receiveDeviceToken(_ token: Data)
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
    return true
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
    let routeString = response.notification.request.content.userInfo["dashRoute"] as? String
    Task { @MainActor in
      if let routeString, let url = URL(string: routeString), let route = DashRoute.parse(url),
        let model = inbox as? AppModel
      {
        model.pendingRoute = route
      }
    }
    completionHandler()
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
  static func webhookIDKey(accountID: String) -> String {
    "dash.push.webhook_id.\(accountID)"
  }

  static func storedWebhookID(accountID: String) -> String? {
    UserDefaults.standard.string(forKey: webhookIDKey(accountID: accountID))
  }

  static func isEnabled(accountID: String) -> Bool {
    storedWebhookID(accountID: accountID) != nil
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
    let registration = try await registerWithRelay(baseURL: base, token: deviceToken)
    let input = NotificationWebhookInput(
      name: webhookName, url: registration.url, secret: registration.secret)

    if let existingID = storedWebhookID(accountID: accountID) {
      do {
        let updated = try await client.updateNotificationWebhook(
          accountID: accountID, webhookID: existingID, input: input)
        store(webhookID: updated.id, accountID: accountID)
        return
      } catch {
        // Stale id — fall through to adopt or create.
      }
    }

    let webhooks = try await client.listNotificationWebhooks(accountID: accountID)
    if let match = webhooks.first(where: { $0.url?.contains(deviceToken) == true }) {
      let updated = try await client.updateNotificationWebhook(
        accountID: accountID, webhookID: match.id, input: input)
      store(webhookID: updated.id, accountID: accountID)
      return
    }

    let created = try await client.createNotificationWebhook(accountID: accountID, input: input)
    store(webhookID: created.id, accountID: accountID)
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
  static func sendTestAlert(configuration: AppConfiguration, deviceToken: String) async throws {
    guard let base = configuration.pushBaseURL else {
      throw PushRegistrationError.pushNotConfigured
    }
    let registration = try await registerWithRelay(baseURL: base, token: deviceToken)
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
    where key.hasPrefix("dash.push.webhook_id.") {
      defaults.removeObject(forKey: key)
    }
  }

  private static func registerWithRelay(baseURL: URL, token: String) async throws
    -> RelayRegistration
  {
    var request = URLRequest(url: baseURL.appending(path: "push/register"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode([
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
    return try JSONDecoder().decode(RelayRegistration.self, from: data)
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
  case missingDeviceToken

  var errorDescription: String? {
    switch self {
    case .pushNotConfigured:
      return DashL10n.string("Push alerts are not configured for this build.")
    case .relayFailed(let status):
      return DashL10n.string("Could not register with the push relay (HTTP \(status)).")
    case .missingDeviceToken:
      return DashL10n.string(
        "This device has not received an APNs token yet. Try again in a moment.")
    }
  }
}
