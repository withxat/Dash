import AuthenticationServices
import BackgroundTasks
import CloudflareAPI
import Foundation
import Observation
import UIKit
import UserNotifications
import WidgetKit

enum AuthenticationState: Sendable, Equatable {
  case authenticated
  case loading
  case unauthenticated
}

@MainActor
@Observable
final class AppModel {
  let configuration: AppConfiguration
  let tokenStore: KeychainTokenStore
  let client: CloudflareClient
  let featureCache = FeatureDataCache()
  let avatars = AvatarStore()
  var accounts: [CloudflareAccount] = []
  var activeAccountID: String?
  var authState: AuthenticationState = .loading
  var errorMessage: String?
  var isAuthenticating = false
  var grantedScopes: Set<String>?
  var selectedScopes = Set(CloudflareScopes.published)
  var user: CloudflareUser?
  /// True while the session is trusted but the identity fetch failed
  /// (offline, Cloudflare outage). Cleared by the next successful retry.
  var identityStale = false
  /// Issue count from the freshest Watchtower snapshot — drives the tab
  /// badge. nil until the first check completes for the active account.
  var watchtowerIssueCount: Int?

  static let watchtowerTTL: TimeInterval = 5 * 60

  /// A deep link / App Intent target waiting to be consumed by MainTabView.
  /// Buffered here because a link can arrive before the tab view mounts
  /// (cold launch) or before the user is authenticated.
  var pendingRoute: DashRoute?

  /// APNs device token hex, buffered because the system callback can arrive
  /// before bootstrap finishes (RootWithSplash holds ~800ms).
  var pendingDeviceToken: String?

  private var authSession: ASWebAuthenticationSession?
  private var isRetryingIdentity = false
  private var watchtowerRefresh: (accountID: String, task: Task<WatchtowerSnapshot, Never>)?

  init(configuration: AppConfiguration = .current) {
    self.configuration = configuration
    let store = KeychainTokenStore()
    tokenStore = store
    client = CloudflareClient(clientID: configuration.clientID, tokenStore: store)
    activeAccountID = UserDefaults.standard.string(forKey: "dash.active_account_id")
  }

  var activeAccount: CloudflareAccount? { accounts.first { $0.id == activeAccountID } }

  /// The headline for profile surfaces: the active account's label, else the
  /// email — never the email twice. Cloudflare's per-user first/last name has
  /// no dashboard surface, so Dash treats the account name as the identity.
  var profileTitle: String {
    activeAccount?.name ?? user?.email ?? "—"
  }

  /// Renames the active account (PUT /accounts/{id}) and refreshes the account
  /// list so every surface picks up the new label.
  func renameActiveAccount(to name: String) async throws {
    guard let id = activeAccountID else { return }
    _ = try await client.mutate(
      path: "/accounts/\(id)", method: "PUT", body: ["name": .string(name)])
    accounts = try await client.listAccounts()
  }

  func bootstrap() async {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-ui-preview") {
        grantedScopes = Set(CloudflareScopes.published)
        authState = .authenticated
        return
      }
    #endif

    do {
      guard try await tokenStore.getAccessToken() != nil else {
        authState = .unauthenticated
        return
      }
    } catch {
      authState = .unauthenticated
      return
    }
    grantedScopes = try? await tokenStore.getGrantedScopes()
    do {
      try await loadIdentity()
      authState = .authenticated
    } catch {
      let outcome = Self.authOutcome(afterIdentityError: error)
      identityStale = outcome.stale
      authState = outcome.state
    }
  }

  /// Only a definitive 401 proves the session is dead. Anything else —
  /// offline, a Cloudflare outage, a failed token-endpoint POST — keeps the
  /// session alive with stale identity; the next foreground retry either
  /// heals it or hits the 401 that signs out for real.
  static func authOutcome(
    afterIdentityError error: Error
  ) -> (state: AuthenticationState, stale: Bool) {
    if let apiError = error as? CloudflareAPIError, apiError.isUnauthorized {
      return (.unauthenticated, false)
    }
    return (.authenticated, true)
  }

  func retryIdentityIfNeeded() async {
    guard identityStale, !isRetryingIdentity else { return }
    isRetryingIdentity = true
    defer { isRetryingIdentity = false }
    do {
      try await loadIdentity()
      identityStale = false
    } catch {
      if (error as? CloudflareAPIError)?.isUnauthorized == true {
        await signOut()
      }
    }
  }

  func signIn() {
    authorize(scopes: selectedScopes, preservesExistingSession: false)
  }

  func requestAccess(to scopes: Set<String>) {
    let requested = Self.incrementalScopes(granted: grantedScopes, requested: scopes)
    authorize(scopes: requested, preservesExistingSession: true)
  }

  static func incrementalScopes(
    granted: Set<String>?,
    requested: Set<String>
  ) -> Set<String> {
    (granted ?? []).union(requested).union(CloudflareScopes.required)
  }

  func hasScopes(_ scopes: Set<String>) -> Bool {
    guard let grantedScopes else { return true }
    return scopes.isSubset(of: grantedScopes)
  }

  func setScopeCategory(_ definitions: [OAuthScopeDefinition], enabled: Bool) {
    let ids = Set(definitions.map(\.id)).intersection(CloudflareScopes.requestable)
    if enabled {
      selectedScopes.formUnion(ids)
    } else {
      selectedScopes.subtract(ids)
      selectedScopes.formUnion(CloudflareScopes.required)
    }
  }

  private func authorize(scopes: Set<String>, preservesExistingSession: Bool) {
    guard configuration.isConfigured else {
      errorMessage = "Add DASH_CLIENT_ID and DASH_REDIRECT_URI to Config/Secrets.xcconfig."
      return
    }
    let requestedScopes = Set(
      CloudflareScopes.sanitized(Array(scopes.union(CloudflareScopes.required)))
    )
    let pkce = PKCEPair.generate()
    let state = UUID().uuidString
    let authorizationURL = OAuth.authorizationURL(
      clientID: configuration.clientID,
      redirectURI: configuration.redirectURI,
      callbackState: state,
      pkce: pkce,
      scopes: requestedScopes.sorted()
    )
    isAuthenticating = true
    errorMessage = nil
    let session = ASWebAuthenticationSession(
      url: authorizationURL, callbackURLScheme: configuration.callbackScheme
    ) { [weak self] url, error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
          isAuthenticating = false
          return
        }
        guard error == nil, let url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
          isAuthenticating = false
          errorMessage = error?.localizedDescription ?? "OAuth callback was invalid."
          return
        }
        let values = Dictionary(
          uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard values["state"] == state, let code = values["code"] else {
          isAuthenticating = false
          errorMessage = values["error_description"] ?? values["error"] ?? "OAuth state mismatch."
          return
        }
        let previousScopes = grantedScopes
        let previousTokens: TokenSet?
        let oldAccessToken =
          preservesExistingSession ? try? await tokenStore.getAccessToken() : nil
        if let accessToken = oldAccessToken {
          previousTokens = TokenSet(
            accessToken: accessToken,
            refreshToken: try? await tokenStore.getRefreshToken(),
            scope: previousScopes?.sorted().joined(separator: " ")
          )
        } else {
          previousTokens = nil
        }
        var replacedTokens = false
        do {
          let tokens = try await OAuth.exchangeCode(
            clientID: configuration.clientID, code: code, verifier: pkce.verifier,
            redirectURI: configuration.redirectURI
          )
          try await tokenStore.setTokens(tokens)
          replacedTokens = true
          let granted =
            tokens.scope.map { Set($0.split(separator: " ").map(String.init)) }
            ?? requestedScopes
          try await tokenStore.setGrantedScopes(granted)
          grantedScopes = granted
          selectedScopes = granted
          featureCache.clear()
          try await loadIdentity()
          // Let the browser sheet finish dismissing first, or the login →
          // catalog transition plays hidden behind it and sign-in reads as a
          // hard cut.
          try? await Task.sleep(for: .milliseconds(450))
          // isAuthenticating stays true: the ring should survive the login
          // screen's exit fade instead of vanishing mid-transition. signOut()
          // resets it for the next visit.
          authState = .authenticated
        } catch {
          isAuthenticating = false
          if replacedTokens, let previousTokens {
            try? await tokenStore.setTokens(previousTokens)
            if let previousScopes {
              try? await tokenStore.setGrantedScopes(previousScopes)
            }
            grantedScopes = previousScopes
            selectedScopes = previousScopes ?? selectedScopes
          }
          errorMessage = error.localizedDescription
          if !preservesExistingSession {
            authState = .unauthenticated
          }
        }
      }
    }
    session.presentationContextProvider = WebAuthenticationContext.shared
    session.prefersEphemeralWebBrowserSession = false
    authSession = session
    if !session.start() {
      isAuthenticating = false
      errorMessage = "Could not start the sign-in session."
    }
  }

  func signOut() async {
    isAuthenticating = false

    // Push webhooks live in the user's Cloudflare accounts — delete them
    // before revoking the token, or the client can no longer authenticate.
    let pushAccountIDs = UserDefaults.standard.dictionaryRepresentation().keys.compactMap {
      key -> String? in
      guard key.hasPrefix("dash.push.webhook_id.") else { return nil }
      return String(key.dropFirst("dash.push.webhook_id.".count))
    }
    for accountID in pushAccountIDs {
      try? await PushRegistrationService.disable(accountID: accountID, client: client)
    }
    UIApplication.shared.unregisterForRemoteNotifications()
    PushRegistrationService.clearAllStoredWebhookIDs()
    // Watchtower's local "Notify on new issues" preference is intentionally
    // kept — it has no server-side side effects.

    if let token = try? await tokenStore.getAccessToken() {
      try? await OAuth.revoke(clientID: configuration.clientID, token: token)
    }
    try? await tokenStore.clear()
    featureCache.clear()
    avatars.clear()
    accounts = []
    user = nil
    activeAccountID = nil
    grantedScopes = nil
    selectedScopes = Set(CloudflareScopes.published)
    identityStale = false
    watchtowerIssueCount = nil
    pendingRoute = nil
    pendingDeviceToken = nil
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundRefreshID)
    UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    if let url = WatchtowerWidgetSnapshot.containerFileURL {
      WatchtowerWidgetSnapshot.clear(at: url)
      WidgetCenter.shared.reloadAllTimelines()
    }
    UserDefaults.standard.removeObject(forKey: "dash.active_account_id")
    authState = .unauthenticated
  }

  func selectAccount(_ account: CloudflareAccount) {
    guard activeAccountID != account.id else { return }
    featureCache.clear()
    watchtowerIssueCount = nil
    activeAccountID = account.id
    UserDefaults.standard.set(account.id, forKey: "dash.active_account_id")
  }

  /// Single entry point for Watchtower data: serves the cached snapshot when
  /// fresh, joins an in-flight refresh for the same account instead of
  /// doubling the fan-out, and keeps the tab-badge count in sync.
  func watchtowerSnapshot(force: Bool = false) async -> WatchtowerSnapshot? {
    guard let accountID = activeAccountID else { return nil }
    let key = FeatureCacheKey.watchtower(accountID)
    if !force, let cached: WatchtowerSnapshot = featureCache.get(key) {
      watchtowerIssueCount = cached.issueCount
      return cached
    }
    if let inFlight = watchtowerRefresh, inFlight.accountID == accountID {
      return await inFlight.task.value
    }
    let client = client
    let task = Task {
      let result = await WatchtowerEngine.load(client: client, accountID: accountID)
      return WatchtowerSnapshot(
        signals: result.signals,
        alerts: result.alerts,
        alertsStatus: result.alertsStatus,
        missingScopeChecks: result.missingScopeChecks,
        failedChecks: result.failedChecks,
        fetchedAt: .now)
    }
    watchtowerRefresh = (accountID, task)
    defer {
      if watchtowerRefresh?.accountID == accountID { watchtowerRefresh = nil }
    }
    let snapshot = await task.value
    // The user may have switched accounts mid-flight; never let a stale
    // account's result touch the cache or the badge.
    guard activeAccountID == accountID else { return snapshot }
    featureCache.set(key, snapshot)
    watchtowerIssueCount = snapshot.issueCount
    publishWidgetSnapshot(snapshot)
    return snapshot
  }

  /// Writes the slim snapshot into the App Group container, refreshes the
  /// widget, and fires any due local notifications by diffing against the
  /// previously shared snapshot. A missing container (entitlement not
  /// provisioned) is a silent no-op — the widget just shows its empty state.
  private func publishWidgetSnapshot(_ snapshot: WatchtowerSnapshot) {
    guard let url = WatchtowerWidgetSnapshot.containerFileURL else { return }
    let previous = try? WatchtowerWidgetSnapshot.load(from: url)
    let widget = snapshot.widgetSnapshot(accountName: activeAccount?.name)
    try? widget.write(to: url)
    WidgetCenter.shared.reloadAllTimelines()
    Task { await WatchtowerNotifier.notifyIfNeeded(previous: previous, current: widget) }
  }

  static let backgroundRefreshID = "sh.xat.dash.watchtower.refresh"

  /// Asks iOS to wake the app to re-check Watchtower. Opportunistic — realistic
  /// delivery is a handful of runs per day; the 5-minute snapshot TTL means
  /// every granted run does real work. Idempotent: a duplicate request for the
  /// same identifier just replaces the pending one.
  func scheduleWatchtowerBackgroundRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshID)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }

  /// Runs from the BGAppRefresh handler: refresh if stale (which republishes
  /// the snapshot and notifies through the shared choke point), then reschedule.
  func performBackgroundWatchtowerRefresh() async {
    guard (try? await tokenStore.getAccessToken()) != nil else { return }
    await refreshWatchtowerIfStale()
    scheduleWatchtowerBackgroundRefresh()
  }

  /// Foreground/warm-up hook: cheap when the snapshot is younger than the
  /// TTL, otherwise re-runs the checks in the background.
  func refreshWatchtowerIfStale() async {
    guard let accountID = activeAccountID else { return }
    if let cached: WatchtowerSnapshot = featureCache.get(FeatureCacheKey.watchtower(accountID)) {
      watchtowerIssueCount = cached.issueCount
      guard cached.isStale(ttl: Self.watchtowerTTL) else { return }
    }
    _ = await watchtowerSnapshot(force: true)
  }

  func loadIdentity() async throws {
    async let fetchedUser = client.getUser()
    async let fetchedAccounts = client.listAccounts()
    user = try await fetchedUser
    accounts = try await fetchedAccounts
    if activeAccount == nil, let first = accounts.first { selectAccount(first) }
  }
}

extension AppModel: PushTokenInbox {
  func receiveDeviceToken(_ token: Data) {
    pendingDeviceToken = PushRegistration.hexToken(from: token)
  }
}

private final class WebAuthenticationContext: NSObject,
  ASWebAuthenticationPresentationContextProviding
{
  static let shared = WebAuthenticationContext()
  func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow
      ?? ASPresentationAnchor()
  }
}
