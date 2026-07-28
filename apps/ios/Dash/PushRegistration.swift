import CloudflareAPI
import CryptoKit
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
  /// Completes only a registration request this process already started.
  func receivePushRegistrationChallenge(_ challenge: PushRegistrationChallenge) async -> Bool
  /// A `content-available` push arrived: refresh only the account it names.
  func performPushTriggeredRefresh(accountID: String) async -> Bool
}

struct PushRegistrationChallenge: Equatable, Sendable {
  let requestID: String
  let ticket: String
  let nonce: String
}

enum PushRemoteNotificationPayload {
  private static func nonEmptyString(
    _ key: String,
    in userInfo: [AnyHashable: Any]
  ) -> String? {
    guard let value = userInfo[key] as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func registrationChallenge(
    from userInfo: [AnyHashable: Any]
  ) -> PushRegistrationChallenge? {
    guard nonEmptyString("dashKind", in: userInfo) == "registration-challenge",
      let requestID = nonEmptyString("requestID", in: userInfo),
      let ticket = nonEmptyString("ticket", in: userInfo),
      let nonce = nonEmptyString("nonce", in: userInfo)
    else { return nil }
    return PushRegistrationChallenge(requestID: requestID, ticket: ticket, nonce: nonce)
  }

  static func accountID(from userInfo: [AnyHashable: Any]) -> String? {
    nonEmptyString("dashAccountID", in: userInfo)
  }
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
  /// Stays main-actor isolated, unlike its siblings: every line of the body is
  /// `@MainActor` work through `PushTokenInbox`, so opting out would only defer
  /// the hop, and it would force the non-Sendable `userInfo` across an
  /// isolation boundary to get there.
  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any]
  ) async -> UIBackgroundFetchResult {
    guard let inbox else { return .noData }
    if let challenge = PushRemoteNotificationPayload.registrationChallenge(from: userInfo) {
      return await inbox.receivePushRegistrationChallenge(challenge) ? .newData : .noData
    }
    guard let accountID = PushRemoteNotificationPayload.accountID(from: userInfo) else {
      return .noData
    }
    return await inbox.performPushTriggeredRefresh(accountID: accountID) ? .newData : .noData
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
    [.banner, .list, .sound, .badge]
  }
}

enum PushRegistration {
  /// Hex device token for the relay's `/push/register/start` body.
  static func hexToken(from data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  #if DEBUG
    static let apnsEnvironment = "sandbox"
  #else
    static let apnsEnvironment = "production"
  #endif
}

actor PushRegistrationChallengeInbox {
  static let shared = PushRegistrationChallengeInbox()

  private enum Pending {
    case prepared
    case delivered(PushRegistrationChallenge)
    case waiting(CheckedContinuation<PushRegistrationChallenge, any Error>)
  }

  private var pending: [String: Pending] = [:]

  func prepare(requestID: String) {
    pending[requestID] = .prepared
  }

  /// Returns false for unsolicited/replayed challenges. APNs possession alone
  /// is not enough: the request id must have been minted by this process.
  func receive(_ challenge: PushRegistrationChallenge) -> Bool {
    guard let state = pending[challenge.requestID] else { return false }
    switch state {
    case .prepared:
      pending[challenge.requestID] = .delivered(challenge)
    case .delivered:
      return false
    case .waiting(let continuation):
      pending.removeValue(forKey: challenge.requestID)
      continuation.resume(returning: challenge)
    }
    return true
  }

  func wait(
    for requestID: String,
    timeout: Duration = .seconds(20)
  ) async throws -> PushRegistrationChallenge {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<PushRegistrationChallenge, any Error>) in
        guard let state = pending[requestID] else {
          continuation.resume(throwing: CancellationError())
          return
        }
        switch state {
        case .prepared:
          pending[requestID] = .waiting(continuation)
          Task {
            try? await Task.sleep(for: timeout)
            self.expire(requestID: requestID)
          }
        case .delivered(let challenge):
          pending.removeValue(forKey: requestID)
          continuation.resume(returning: challenge)
        case .waiting:
          continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      Task { await self.cancel(requestID: requestID) }
    }
  }

  func cancel(requestID: String) {
    guard let state = pending.removeValue(forKey: requestID) else { return }
    if case .waiting(let continuation) = state {
      continuation.resume(throwing: CancellationError())
    }
  }

  private func expire(requestID: String) {
    guard let state = pending.removeValue(forKey: requestID) else { return }
    if case .waiting(let continuation) = state {
      continuation.resume(throwing: PushRegistrationError.relayFailed(status: -1))
    }
  }
}

@MainActor
enum PushRegistrationOperationGate {
  struct Operation: Equatable, Sendable {
    let accountID: String
    let generation: UInt64
  }

  private struct State {
    var generation: UInt64
    var wantsEnabled: Bool
  }

  private static var states: [String: State] = [:]

  static func beginDesiredChange(accountID: String, enabled: Bool) -> Operation {
    var state = states[accountID] ?? State(generation: 0, wantsEnabled: enabled)
    state.generation &+= 1
    state.wantsEnabled = enabled
    states[accountID] = state
    return Operation(accountID: accountID, generation: state.generation)
  }

  static func beginReconcile(
    accountID: String,
    isCurrentlyEnabled: Bool
  ) -> Operation? {
    var state =
      states[accountID]
      ?? State(generation: 0, wantsEnabled: isCurrentlyEnabled)
    guard state.wantsEnabled, isCurrentlyEnabled else { return nil }
    state.generation &+= 1
    states[accountID] = state
    return Operation(accountID: accountID, generation: state.generation)
  }

  static func isCurrent(_ operation: Operation, enabled: Bool) -> Bool {
    guard let state = states[operation.accountID] else { return false }
    return state.generation == operation.generation && state.wantsEnabled == enabled
  }
}

private actor PushRegistrationMutationLock {
  static let shared = PushRegistrationMutationLock()

  private var lockedAccounts: Set<String> = []
  private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

  func acquire(accountID: String) async {
    guard lockedAccounts.contains(accountID) else {
      lockedAccounts.insert(accountID)
      return
    }
    await withCheckedContinuation { continuation in
      waiters[accountID, default: []].append(continuation)
    }
  }

  func release(accountID: String) {
    guard var accountWaiters = waiters[accountID], !accountWaiters.isEmpty else {
      waiters.removeValue(forKey: accountID)
      lockedAccounts.remove(accountID)
      return
    }
    let next = accountWaiters.removeFirst()
    waiters[accountID] = accountWaiters.isEmpty ? nil : accountWaiters
    next.resume()
  }
}

/// APNs collapses registration challenges for one device to a single pending
/// delivery. Serialize challenge exchanges for that token so an automatic
/// reconcile and "Send test alert" cannot replace each other's nonce.
private actor PushRegistrationChallengeLock {
  static let shared = PushRegistrationChallengeLock()

  private var lockedTokens: Set<String> = []
  private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

  func acquire(deviceToken: String) async {
    guard lockedTokens.contains(deviceToken) else {
      lockedTokens.insert(deviceToken)
      return
    }
    await withCheckedContinuation { continuation in
      waiters[deviceToken, default: []].append(continuation)
    }
  }

  func release(deviceToken: String) {
    guard var tokenWaiters = waiters[deviceToken], !tokenWaiters.isEmpty else {
      waiters.removeValue(forKey: deviceToken)
      lockedTokens.remove(deviceToken)
      return
    }
    let next = tokenWaiters.removeFirst()
    waiters[deviceToken] = tokenWaiters.isEmpty ? nil : tokenWaiters
    next.resume()
  }
}

/// Creates and maintains the Cloudflare webhook that forwards alerts to Dash's
/// APNs bridge. Server-side state lives in the user's own Cloudflare account;
/// Dash remembers the webhook id plus any pending cleanup retry in UserDefaults.
enum PushRegistrationService {
  private static let webhookIDPrefix = "dash.push.webhook_id."
  private static let cleanupPrefix = "dash.push.cleanup."

  struct CleanupTombstone: Codable, Equatable, Sendable {
    let webhookID: String
    var attempts: Int
    var lastAttemptAt: Date
  }

  static func webhookIDKey(accountID: String) -> String {
    "\(webhookIDPrefix)\(accountID)"
  }

  static func storedWebhookID(accountID: String) -> String? {
    UserDefaults.standard.string(forKey: webhookIDKey(accountID: accountID))
  }

  static func cleanupKey(accountID: String) -> String {
    "\(cleanupPrefix)\(accountID)"
  }

  static func cleanupTombstone(
    accountID: String,
    in defaults: UserDefaults = .standard
  ) -> CleanupTombstone? {
    guard let data = defaults.data(forKey: cleanupKey(accountID: accountID)) else { return nil }
    return try? JSONDecoder().decode(CleanupTombstone.self, from: data)
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

  static func pendingCleanupAccountIDs(in defaults: UserDefaults = .standard) -> [String] {
    Set(
      defaults.dictionaryRepresentation().keys.compactMap { key in
        guard key.hasPrefix(cleanupPrefix) else { return nil }
        let accountID = String(key.dropFirst(cleanupPrefix.count))
        return accountID.isEmpty ? nil : accountID
      }
    ).sorted()
  }

  static func reconcilableAccountIDs(in defaults: UserDefaults = .standard) -> [String] {
    let cleanup = Set(pendingCleanupAccountIDs(in: defaults))
    return enabledAccountIDs(in: defaults).filter { !cleanup.contains($0) }
  }

  /// Invalidates every in-flight enable/reconcile before sign-out starts
  /// waiting on the per-account mutation locks. This includes an enable that
  /// has not created (and therefore has not stored) its webhook yet.
  @MainActor
  static func prepareForSignOut(accountIDs: some Sequence<String>) {
    for accountID in Set(accountIDs) {
      _ = PushRegistrationOperationGate.beginDesiredChange(
        accountID: accountID, enabled: false)
    }
  }

  struct RelayRegistration: Decodable, Sendable {
    let url: String
    let secret: String
  }

  /// Mint a signed notify URL from the relay, then create/update/adopt the
  /// Cloudflare webhook for this account.
  @MainActor
  static func enable(
    accountID: String,
    client: CloudflareClient,
    configuration: AppConfiguration,
    deviceToken: String
  ) async throws {
    let operation = PushRegistrationOperationGate.beginDesiredChange(
      accountID: accountID, enabled: true)
    try await withMutationLock(accountID: accountID) {
      try await enable(
        accountID: accountID,
        client: client,
        configuration: configuration,
        deviceToken: deviceToken,
        operation: operation)
    }
  }

  @MainActor
  private static func enable(
    accountID: String,
    client: CloudflareClient,
    configuration: AppConfiguration,
    deviceToken: String,
    operation: PushRegistrationOperationGate.Operation
  ) async throws {
    try requireCurrentEnabledOperation(operation)
    guard let base = configuration.pushBaseURL else {
      throw PushRegistrationError.pushNotConfigured
    }
    let registration = try await registerWithRelay(
      baseURL: base,
      token: deviceToken,
      accountID: accountID
    )
    try requireCurrentEnabledOperation(operation)
    let deviceWebhookName = webhookName(deviceToken: deviceToken)
    let input = NotificationWebhookInput(
      name: deviceWebhookName, url: registration.url, secret: registration.secret)

    if let existingID = storedWebhookID(accountID: accountID) {
      do {
        let updated = try await client.updateNotificationWebhook(
          accountID: accountID, webhookID: existingID, input: input)
        store(webhookID: updated.id, accountID: accountID)
        try requireCurrentEnabledOperation(operation)
        clearCleanup(accountID: accountID)
        return
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try requireCurrentEnabledOperation(operation)
        guard isStatus(error, 404) else { throw error }
        clear(accountID: accountID)
      }
    }

    let webhooks = try await client.listNotificationWebhooks(accountID: accountID)
    try requireCurrentEnabledOperation(operation)
    if let match = webhooks.first(where: {
      $0.name == deviceWebhookName || $0.url?.contains(deviceToken) == true
    }) {
      let updated = try await client.updateNotificationWebhook(
        accountID: accountID, webhookID: match.id, input: input)
      store(webhookID: updated.id, accountID: accountID)
      try requireCurrentEnabledOperation(operation)
      clearCleanup(accountID: accountID)
      return
    }

    try requireCurrentEnabledOperation(operation)
    let created = try await client.createNotificationWebhook(accountID: accountID, input: input)
    // Persist the remote handle before checking cancellation/desired state.
    // A queued Disable can now delete a create that finished while it waited.
    store(webhookID: created.id, accountID: accountID)
    try requireCurrentEnabledOperation(operation)
    clearCleanup(accountID: accountID)
  }

  /// Delete the webhook (unbinding policies first if Cloudflare rejects the
  /// delete) and clear the local id.
  @MainActor
  static func disable(accountID: String, client: CloudflareClient) async throws {
    _ = PushRegistrationOperationGate.beginDesiredChange(
      accountID: accountID, enabled: false)
    try await withMutationLock(accountID: accountID) {
      try await disableLocked(accountID: accountID, client: client)
    }
  }

  @MainActor
  private static func disableLocked(
    accountID: String,
    client: CloudflareClient
  ) async throws {
    guard
      let webhookID =
        storedWebhookID(accountID: accountID)
        ?? cleanupTombstone(accountID: accountID)?.webhookID
    else {
      clearCleanup(accountID: accountID)
      return
    }
    // Persist the user's disable intent before the first remote mutation.
    // If the process dies after DELETE succeeds but before local cleanup, the
    // next launch retries DELETE (404 is success) instead of reconciling and
    // recreating the webhook.
    recordCleanupAttempt(webhookID: webhookID, accountID: accountID)
    do {
      try await client.deleteNotificationWebhook(accountID: accountID, webhookID: webhookID)
    } catch {
      if isStatus(error, 404) {
        clear(accountID: accountID)
        clearCleanup(accountID: accountID)
        return
      }
      guard isStatus(error, 400) else { throw error }
      try await unbind(webhookID: webhookID, accountID: accountID, client: client)
      do {
        try await client.deleteNotificationWebhook(
          accountID: accountID, webhookID: webhookID)
      } catch {
        guard isStatus(error, 404) else { throw error }
      }
    }
    clear(accountID: accountID)
    clearCleanup(accountID: accountID)
  }

  /// Refresh the webhook URL when the device token rotates, if push is on.
  @MainActor
  static func reconcile(
    accountID: String,
    client: CloudflareClient,
    configuration: AppConfiguration,
    deviceToken: String
  ) async throws {
    guard isEnabled(accountID: accountID),
      cleanupTombstone(accountID: accountID) == nil
    else { return }
    guard
      let operation = PushRegistrationOperationGate.beginReconcile(
        accountID: accountID,
        isCurrentlyEnabled: true)
    else { return }
    try await withMutationLock(accountID: accountID) {
      try await enable(
        accountID: accountID,
        client: client,
        configuration: configuration,
        deviceToken: deviceToken,
        operation: operation)
    }
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

  private static func registerWithRelay(
    baseURL: URL,
    token: String,
    accountID: String
  ) async throws
    -> RelayRegistration
  {
    let lockToken = token.lowercased()
    await PushRegistrationChallengeLock.shared.acquire(deviceToken: lockToken)
    do {
      let registration = try await registerWithRelayLocked(
        baseURL: baseURL,
        token: token,
        accountID: accountID)
      await PushRegistrationChallengeLock.shared.release(deviceToken: lockToken)
      return registration
    } catch {
      await PushRegistrationChallengeLock.shared.release(deviceToken: lockToken)
      throw error
    }
  }

  private static func registerWithRelayLocked(
    baseURL: URL,
    token: String,
    accountID: String
  ) async throws -> RelayRegistration {
    try Task.checkCancellation()
    let requestID = UUID().uuidString
    await PushRegistrationChallengeInbox.shared.prepare(requestID: requestID)
    do {
      var start = URLRequest(url: baseURL.appending(path: "push/register/start"))
      start.httpMethod = "POST"
      start.setValue("application/json", forHTTPHeaderField: "Content-Type")
      start.httpBody = try JSONEncoder().encode([
        "requestID": requestID,
        "accountID": accountID,
        "token": token,
        "environment": PushRegistration.apnsEnvironment,
      ])
      let (_, startResponse) = try await URLSession.shared.data(for: start)
      guard let startHTTP = startResponse as? HTTPURLResponse else {
        throw PushRegistrationError.relayFailed(status: -1)
      }
      guard startHTTP.statusCode == 202 else {
        throw PushRegistrationError.relayFailed(status: startHTTP.statusCode)
      }

      let challenge = try await PushRegistrationChallengeInbox.shared.wait(for: requestID)
      var complete = URLRequest(url: baseURL.appending(path: "push/register/complete"))
      complete.httpMethod = "POST"
      complete.setValue("application/json", forHTTPHeaderField: "Content-Type")
      complete.httpBody = try JSONEncoder().encode([
        "ticket": challenge.ticket,
        "nonce": challenge.nonce,
      ])
      let (data, response) = try await URLSession.shared.data(for: complete)
      guard let http = response as? HTTPURLResponse else {
        throw PushRegistrationError.relayFailed(status: -1)
      }
      guard http.statusCode == 200 else {
        throw PushRegistrationError.relayFailed(status: http.statusCode)
      }
      let registration = try JSONDecoder().decode(RelayRegistration.self, from: data)
      guard
        isValidRelayNotifyURL(
          registration.url,
          relayBaseURL: baseURL)
      else {
        throw PushRegistrationError.relayAccountMismatch
      }
      return registration
    } catch {
      await PushRegistrationChallengeInbox.shared.cancel(requestID: requestID)
      throw error
    }
  }

  static func isValidRelayNotifyURL(
    _ rawURL: String,
    relayBaseURL: URL
  ) -> Bool {
    guard let components = URLComponents(string: rawURL),
      let url = components.url,
      components.user == nil,
      components.password == nil
    else {
      return false
    }
    guard
      url.scheme == relayBaseURL.scheme,
      url.host == relayBaseURL.host,
      url.port == relayBaseURL.port
    else {
      return false
    }
    let prefix = "/push/notify/"
    guard components.query == nil, components.fragment == nil,
      components.percentEncodedPath.hasPrefix(prefix)
    else {
      return false
    }
    let component = components.percentEncodedPath.dropFirst(prefix.count)
    guard (64...2048).contains(component.count),
      !component.contains("/")
    else {
      return false
    }
    return component.allSatisfy {
      $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
    }
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

  static func webhookName(deviceToken: String) -> String {
    let digest = SHA256.hash(data: Data(deviceToken.lowercased().utf8))
    let suffix = digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    return "Dash \(suffix)"
  }

  static func recordCleanupAttempt(
    webhookID: String,
    accountID: String,
    defaults: UserDefaults = .standard,
    now: Date = .now
  ) {
    var tombstone =
      cleanupTombstone(accountID: accountID, in: defaults)
      ?? CleanupTombstone(webhookID: webhookID, attempts: 0, lastAttemptAt: now)
    tombstone = CleanupTombstone(
      webhookID: webhookID,
      attempts: tombstone.attempts + 1,
      lastAttemptAt: now)
    if let data = try? JSONEncoder().encode(tombstone) {
      defaults.set(data, forKey: cleanupKey(accountID: accountID))
    }
  }

  static func clearCleanup(
    accountID: String,
    defaults: UserDefaults = .standard
  ) {
    defaults.removeObject(forKey: cleanupKey(accountID: accountID))
  }

  @MainActor
  private static func requireCurrentEnabledOperation(
    _ operation: PushRegistrationOperationGate.Operation
  ) throws {
    try Task.checkCancellation()
    guard PushRegistrationOperationGate.isCurrent(operation, enabled: true) else {
      throw CancellationError()
    }
  }

  @MainActor
  private static func withMutationLock<T>(
    accountID: String,
    operation: () async throws -> T
  ) async throws -> T {
    await PushRegistrationMutationLock.shared.acquire(accountID: accountID)
    do {
      let result = try await operation()
      await PushRegistrationMutationLock.shared.release(accountID: accountID)
      return result
    } catch {
      await PushRegistrationMutationLock.shared.release(accountID: accountID)
      throw error
    }
  }

  private static func isStatus(_ error: Error, _ expected: Int) -> Bool {
    if case .request(let status, _) = error as? CloudflareAPIError {
      return status == expected
    }
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
