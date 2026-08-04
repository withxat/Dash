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
    // Silent — Cloudflare history remains available in Watchtower, and a later
    // launch/token callback retries the default webhook delivery path.
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

  /// Automatic setup and a Settings refresh may converge on the same account.
  /// They share one desired generation so serial execution stays idempotent;
  /// only an explicit disable/sign-out invalidates both.
  static func beginEnsureEnabled(accountID: String) -> Operation {
    if let state = states[accountID], state.wantsEnabled {
      return Operation(accountID: accountID, generation: state.generation)
    }
    return beginDesiredChange(accountID: accountID, enabled: true)
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
/// reconcile for one account cannot replace another account's nonce.
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
  private static let readyPrefix = "dash.push.ready."
  private static let cleanupPrefix = "dash.push.cleanup."
  static let requiredScopes: Set<String> = ["notifications.read", "notifications.write"]
  private static let buildActivityAlertTypes: Set<String> = ["pages_event_alert"]

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

  static func readinessKey(accountID: String) -> String {
    "\(readyPrefix)\(accountID)"
  }

  static func isReady(
    accountID: String,
    in defaults: UserDefaults = .standard
  ) -> Bool {
    guard let webhookID = defaults.string(forKey: webhookIDKey(accountID: accountID)),
      !webhookID.isEmpty
    else { return false }
    return defaults.bool(forKey: readinessKey(accountID: accountID))
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

  static var shouldAutomaticallyProvisionForCurrentProcess: Bool {
    shouldAutomaticallyProvision(
      arguments: ProcessInfo.processInfo.arguments,
      environment: ProcessInfo.processInfo.environment)
  }

  static func shouldAutomaticallyProvision(
    arguments: [String],
    environment: [String: String]
  ) -> Bool {
    if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
      || environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestBundlePath"] != nil
      || arguments.contains("-ui-testing")
      || arguments.contains(where: {
        $0.hasPrefix("-ui-preview") || $0.hasPrefix("-uiTest")
      })
    {
      return false
    }
    return true
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

  /// Mint a signed notify URL from the relay and create/update/adopt this
  /// device's Cloudflare webhook. Existing notification policies remain
  /// user-owned; Dash-created policies opt into this destination explicitly.
  /// Concurrent default-setup callers share the same desired generation.
  @MainActor
  static func ensureEnabled(
    accountID: String,
    client: CloudflareClient,
    configuration: AppConfiguration,
    deviceToken: String
  ) async throws {
    let operation = PushRegistrationOperationGate.beginEnsureEnabled(accountID: accountID)
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
    clearReady(accountID: accountID)
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

    let webhookID = try await upsertWebhook(
      accountID: accountID,
      client: client,
      deviceToken: deviceToken,
      name: deviceWebhookName,
      input: input,
      operation: operation)
    try requireCurrentEnabledOperation(operation)
    try await removeDashDeliveryFromBuildPolicies(
      webhookID: webhookID,
      accountID: accountID,
      client: client,
      relayBaseURL: base)
    try requireCurrentEnabledOperation(operation)
    markReady(accountID: accountID)
    clearCleanup(accountID: accountID)
  }

  @MainActor
  private static func upsertWebhook(
    accountID: String,
    client: CloudflareClient,
    deviceToken: String,
    name: String,
    input: NotificationWebhookInput,
    operation: PushRegistrationOperationGate.Operation
  ) async throws -> String {
    if let existingID = storedWebhookID(accountID: accountID) {
      do {
        let updated = try await client.updateNotificationWebhook(
          accountID: accountID, webhookID: existingID, input: input)
        store(webhookID: updated.id, accountID: accountID)
        try requireCurrentEnabledOperation(operation)
        return updated.id
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
      $0.name == name || $0.url?.contains(deviceToken) == true
    }) {
      let updated = try await client.updateNotificationWebhook(
        accountID: accountID, webhookID: match.id, input: input)
      store(webhookID: updated.id, accountID: accountID)
      try requireCurrentEnabledOperation(operation)
      return updated.id
    }

    try requireCurrentEnabledOperation(operation)
    let created = try await client.createNotificationWebhook(accountID: accountID, input: input)
    // Persist the remote handle before checking cancellation/desired state.
    // A queued Disable can now delete a create that finished while it waited.
    store(webhookID: created.id, accountID: accountID)
    try requireCurrentEnabledOperation(operation)
    return created.id
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
      clearReady(accountID: accountID)
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
      guard policy.mechanisms?.webhooks?.contains(where: { $0.id == webhookID }) == true
      else { continue }
      try await reconcilePolicyDeliveryRemoval(
        webhookIDs: [webhookID],
        accountID: accountID,
        policyID: policy.id,
        client: client)
    }
  }

  /// Pages and Workers share the app-driven Live Activity route. Remove every
  /// Dash relay destination from legacy Pages policies, but preserve the policy
  /// itself and all non-Dash delivery mechanisms the user owns in Cloudflare.
  private static func removeDashDeliveryFromBuildPolicies(
    webhookID: String,
    accountID: String,
    client: CloudflareClient,
    relayBaseURL: URL
  ) async throws {
    let webhooks = try await client.listNotificationWebhooks(accountID: accountID)
    var dashWebhookIDs: Set<String> = [webhookID]
    dashWebhookIDs.formUnion(
      webhooks.compactMap { webhook in
        guard let url = webhook.url,
          isValidRelayNotifyURL(url, relayBaseURL: relayBaseURL)
        else { return nil }
        return webhook.id
      })

    let policies = try await client.listNotificationPolicies(accountID: accountID)
    for policy in policies where usesBuildActivityPath(alertType: policy.alertType) {
      guard policy.mechanisms?.webhooks?.contains(where: dashWebhookIDs.contains) == true
      else { continue }
      try await reconcilePolicyDeliveryRemoval(
        webhookIDs: dashWebhookIDs,
        accountID: accountID,
        policyID: policy.id,
        client: client)
    }
  }

  /// Cloudflare exposes a per-policy GET and an update body whose fields are
  /// optional. Read immediately before each mechanisms-only removal, then
  /// verify and retry a bounded number of times. This avoids replaying stale
  /// enabled state, filters, interval, or copy over a dashboard edit.
  private static func reconcilePolicyDeliveryRemoval(
    webhookIDs: Set<String>,
    accountID: String,
    policyID: String,
    client: CloudflareClient
  ) async throws {
    guard !webhookIDs.isEmpty else { return }
    for _ in 0..<3 {
      try Task.checkCancellation()
      let policy: NotificationPolicy
      do {
        policy = try await client.getNotificationPolicy(
          accountID: accountID, policyID: policyID)
      } catch {
        if isStatus(error, 404) { return }
        throw error
      }
      guard
        let mechanisms = mechanismsRemovingDelivery(
          webhookIDs: webhookIDs,
          from: policy)
      else { return }

      _ = try await client.updateNotificationPolicyMechanisms(
        accountID: accountID,
        policyID: policyID,
        mechanisms: mechanisms)
      try Task.checkCancellation()
      do {
        let verified = try await client.getNotificationPolicy(
          accountID: accountID, policyID: policyID)
        if !containsAnyWebhook(webhookIDs, in: verified) {
          return
        }
      } catch {
        if isStatus(error, 404) { return }
        throw error
      }
    }
    throw PushRegistrationError.policyReconciliationFailed
  }

  static func usesBuildActivityPath(alertType: String?) -> Bool {
    alertType.map(buildActivityAlertTypes.contains) ?? false
  }

  /// Removes only the selected webhook destinations. Existing email,
  /// PagerDuty, and unrelated webhook targets survive.
  static func mechanismsRemovingDelivery(
    webhookIDs: Set<String>,
    from policy: NotificationPolicy
  ) -> NotificationMechanisms? {
    let webhookIDs = Set(
      webhookIDs.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty })
    guard !webhookIDs.isEmpty else { return nil }
    var mechanisms = policy.mechanisms ?? NotificationMechanisms()
    var webhooks = mechanisms.webhooks ?? []
    guard webhooks.contains(where: { webhookIDs.contains($0.id) }) else { return nil }
    webhooks.removeAll { webhookIDs.contains($0.id) }
    mechanisms.webhooks = webhooks
    return mechanisms
  }

  private static func containsAnyWebhook(
    _ webhookIDs: Set<String>,
    in policy: NotificationPolicy
  ) -> Bool {
    policy.mechanisms?.webhooks?.contains(where: { webhookIDs.contains($0.id) }) == true
  }

  private static func store(webhookID: String, accountID: String) {
    UserDefaults.standard.set(webhookID, forKey: webhookIDKey(accountID: accountID))
  }

  private static func markReady(accountID: String) {
    UserDefaults.standard.set(true, forKey: readinessKey(accountID: accountID))
  }

  private static func clearReady(accountID: String) {
    UserDefaults.standard.removeObject(forKey: readinessKey(accountID: accountID))
  }

  private static func clear(accountID: String) {
    UserDefaults.standard.removeObject(forKey: webhookIDKey(accountID: accountID))
    clearReady(accountID: accountID)
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
  case authorizationRequired
  case notificationsDisabled
  case policyReconciliationFailed
  case relayFailed(status: Int)
  case relayAccountMismatch
  case missingDeviceToken

  var errorDescription: String? {
    switch self {
    case .pushNotConfigured:
      return DashL10n.string("Push alerts are not configured for this build.")
    case .authorizationRequired:
      return DashL10n.string("Grant access")
    case .notificationsDisabled:
      return DashL10n.string("Notifications are turned off in Settings.")
    case .policyReconciliationFailed:
      return DashL10n.string("Cloudflare couldn’t complete this request. Try again.")
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
