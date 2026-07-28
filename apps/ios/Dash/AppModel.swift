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

struct AccountRequestContext: Hashable, Sendable {
  let accountID: String
  let generation: UInt64
}

@MainActor
@Observable
final class AppModel {
  static let demoGrantedScopes = DashAuthorizationScopes.initialReadOnly

  let configuration: AppConfiguration
  let tokenStore: KeychainTokenStore
  /// Swapped for a `DemoBackend`-served client while the demo session runs;
  /// every consumer reads it per-call, so the swap takes effect everywhere.
  private(set) var client: CloudflareClient
  /// True while the read-only demo session is active (App Review's path past
  /// the OAuth wall). Sign-out becomes a lightweight demo exit.
  private(set) var isDemoSession = false
  let featureCache = FeatureDataCache()
  let avatars = AvatarStore()
  let r2Thumbnails = R2ThumbnailStore()
  /// Top-of-screen action feedback. Prefer this over sticky inline notices for
  /// completed / failed mutations; keep `DashNotice` for persistent state.
  let toasts = DashToastCenter()
  var accounts: [CloudflareAccount] = [] {
    didSet {
      MetricsWidgetPublisher.syncAccounts(accounts, activeAccountID: activeAccountID)
    }
  }
  // Mirrored into App Group defaults so the share extension knows which
  // account to upload into; standard defaults are invisible across processes.
  var activeAccountID: String? {
    didSet {
      R2ShareDestination.setActiveAccountID(activeAccountID)
      MetricsWidgetPublisher.syncAccounts(accounts, activeAccountID: activeAccountID)
      guard oldValue != activeAccountID else { return }
      clearWatchtowerWidgetSnapshot()
    }
  }
  var authState: AuthenticationState = .loading {
    didSet {
      guard authState == .unauthenticated else { return }
      MetricsWidgetPublisher.clear()
    }
  }
  var errorMessage: String?
  var isAuthenticating = false
  var grantedScopes: Set<String>?
  var selectedScopes: Set<String>
  var user: CloudflareUser?
  /// True while the session is trusted but the identity fetch failed
  /// (offline, Cloudflare outage). Cleared by the next successful retry.
  var identityStale = false
  /// Unread Cloudflare deliveries, minus locally ignored rows. History never
  /// increments this shared Watchtower tab / floating inbox badge; nil until
  /// the first fetch completes for the active account.
  var watchtowerUnreadAlertCount: Int?

  static let watchtowerTTL: TimeInterval = 5 * 60

  /// A deep link / App Intent target waiting to be consumed by MainTabView.
  /// Buffered here because a link can arrive before the tab view mounts
  /// (cold launch) or before the user is authenticated.
  var pendingRoute: DashRoute?
  /// An older notification that predates account-bound routes. It stays
  /// buffered until identity proves there is exactly one possible account.
  private var pendingLegacyNotificationRoute: DashRoute?

  /// APNs device token hex, buffered because the system callback can arrive
  /// before bootstrap finishes (RootWithSplash holds ~800ms).
  var pendingDeviceToken: String?

  private var authSession: ASWebAuthenticationSession?
  private var pushReconcileTask: Task<Void, Never>?
  private var isRetryingIdentity = false
  private var accountGeneration: UInt64 = 0

  init(configuration: AppConfiguration = .current) {
    self.configuration = configuration
    selectedScopes = DashAuthorizationScopes.core
    let store = KeychainTokenStore()
    tokenStore = store
    client = CloudflareClient(
      clientID: configuration.clientID, tokenStore: store, session: DashAPISession.shared)
    activeAccountID = UserDefaults.standard.string(forKey: "dash.active_account_id")
    // Property observers don't fire during init — mirror explicitly so the
    // share extension works without waiting for an account switch.
    R2ShareDestination.setActiveAccountID(activeAccountID)
    installMemoryWarningObserver()
  }

  var activeAccount: CloudflareAccount? { accounts.first { $0.id == activeAccountID } }

  var accountRequestContext: AccountRequestContext? {
    guard let activeAccountID else { return nil }
    return AccountRequestContext(accountID: activeAccountID, generation: accountGeneration)
  }

  func isCurrentAccount(_ context: AccountRequestContext) -> Bool {
    activeAccountID == context.accountID && accountGeneration == context.generation
  }

  func receiveNotificationRoute(_ route: DashRoute) {
    switch NotificationRoutePolicy.resolve(
      route,
      availableAccountIDs: Set(accounts.map(\.id)),
      allowsLegacyAccountInference: !isDemoSession)
    {
    case .open(let route):
      pendingLegacyNotificationRoute = nil
      pendingRoute = route
    case .deferUntilAccountsLoad:
      pendingLegacyNotificationRoute = route
    case .rejectAmbiguous:
      pendingLegacyNotificationRoute = nil
      toasts.warning(
        "This older notification doesn't identify its Cloudflare account. Open Watchtower to review it safely."
      )
    }
  }

  private func resolvePendingLegacyNotificationRoute() {
    guard let route = pendingLegacyNotificationRoute else { return }
    receiveNotificationRoute(route)
  }

  private func resetAccountScopedWork() {
    pushReconcileTask?.cancel()
    pushReconcileTask = nil
    accountGeneration &+= 1
    featureCache.clear()
    PagesBuildActivityController.shared.invalidateSession()
    watchtowerUnreadAlertCount = nil
  }

  private func clearWatchtowerWidgetSnapshot() {
    guard let url = WatchtowerWidgetSnapshot.containerFileURL else { return }
    WatchtowerWidgetSnapshot.clear(at: url)
    WidgetCenter.shared.reloadAllTimelines()
  }

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
      let arguments = ProcessInfo.processInfo.arguments
      if arguments.contains("-ui-preview-onboarding")
        || arguments.contains("-ui-preview-onboarding-permissions")
      {
        authState = .unauthenticated
        return
      }

      if ProcessInfo.processInfo.arguments.contains("-ui-preview") {
        // Pin bootstrap is one-shot per account and persists in UserDefaults,
        // so stub launches must shed pins and recents from earlier runs or Home
        // layout and every test built on it becomes order-dependent.
        for key in [
          PinnedZones.key, PinnedZones.initializedAccountsKey, RecentResources.key,
        ] {
          UserDefaults.standard.removeObject(forKey: key)
        }
        grantedScopes = Set(CloudflareScopes.published)
        activeAccountID = "ui-account"
        if let zones = try? JSONDecoder().decode(
          [CloudflareZone].self,
          from: Data(
            """
            [
              {"id":"ui-zone","name":"example.com","status":"active"},
              {"id":"ui-zone-docs","name":"docs.example.com","status":"active"},
              {"id":"ui-zone-api","name":"api.example.net","status":"pending"},
              {"id":"ui-zone-shop","name":"shop.example.org","status":"active"}
            ]
            """.utf8))
        {
          let visible =
            ProcessInfo.processInfo.arguments.contains("-ui-preview-two-zones")
            ? Array(zones.prefix(2)) : zones
          featureCache.set(FeatureCacheKey.zones("ui-account"), visible)
          // Zone detail reads a per-zone key, not the list, so seed it too or
          // the screen is unreachable without a live token.
          for zone in visible {
            featureCache.set(FeatureCacheKey.zone(zone.id), zone)
          }
          if let traffic = try? JSONDecoder().decode(
            [ZoneAnalyticsPoint].self,
            from: Data(
              """
              [
                {"datetime":"2026-07-15T18:00:00Z","requests":1520,"pageViews":934,"threats":4,"bytes":18240000,"cachedRequests":1231,"cachedBytes":13315200,"uniques":212},
                {"datetime":"2026-07-15T21:00:00Z","requests":1284,"pageViews":771,"threats":2,"bytes":15390000,"cachedRequests":1040,"cachedBytes":11234700,"uniques":178},
                {"datetime":"2026-07-16T00:00:00Z","requests":986,"pageViews":608,"threats":1,"bytes":11960000,"cachedRequests":798,"cachedBytes":8730800,"uniques":141},
                {"datetime":"2026-07-16T03:00:00Z","requests":742,"pageViews":451,"threats":0,"bytes":9170000,"cachedRequests":601,"cachedBytes":6694100,"uniques":108},
                {"datetime":"2026-07-16T06:00:00Z","requests":1168,"pageViews":709,"threats":3,"bytes":14080000,"cachedRequests":946,"cachedBytes":10278400,"uniques":164},
                {"datetime":"2026-07-16T09:00:00Z","requests":1836,"pageViews":1127,"threats":5,"bytes":21640000,"cachedRequests":1487,"cachedBytes":15797200,"uniques":247},
                {"datetime":"2026-07-16T12:00:00Z","requests":2147,"pageViews":1322,"threats":6,"bytes":25270000,"cachedRequests":1739,"cachedBytes":18447100,"uniques":291},
                {"datetime":"2026-07-16T15:00:00Z","requests":1973,"pageViews":1206,"threats":3,"bytes":23410000,"cachedRequests":1598,"cachedBytes":17089300,"uniques":266}
              ]
              """.utf8))
          {
            for zone in visible {
              featureCache.set(FeatureCacheKey.zoneAnalyticsHourly(zone.id), traffic)
              featureCache.set(FeatureCacheKey.zoneRequestsHourly(zone.id), traffic)
            }
          }
        }
        // A realistic slice of the ~60 settings Cloudflare returns: the five the
        // curated panel keeps, plus ones it must drop (a plan-locked toggle, a
        // set-once choice, and the array-valued key that used to render as
        // "N values, N values").
        if let settings = try? JSONDecoder().decode(
          [ZoneSetting].self,
          from: Data(
            """
            [
              {"id":"security_level","value":"medium","editable":true},
              {"id":"development_mode","value":"off","editable":true},
              {"id":"ssl","value":"full","editable":true},
              {"id":"always_online","value":"on","editable":true},
              {"id":"always_use_https","value":"off","editable":true},
              {"id":"advanced_ddos","value":"on","editable":false},
              {"id":"min_tls_version","value":"1.2","editable":true},
              {"id":"browser_cache_ttl","value":14400,"editable":true},
              {"id":"transformations","value":[{"a":1},{"b":2}],"editable":false}
            ]
            """.utf8))
        {
          featureCache.set(FeatureCacheKey.zoneSettings("ui-zone"), settings)
        }
        if let workers = try? JSONDecoder().decode(
          [WorkerScript].self,
          from: Data(
            """
            [{"id":"api-worker","tag":"worker-tag","modified_on":"2026-07-16T03:04:05Z"}]
            """.utf8))
        {
          featureCache.set(FeatureCacheKey.workers("ui-account"), workers)
        }
        let previewWorkerDeployments = [
          WorkerDeploymentSummary(
            id: "preview-deployment",
            createdOn: ISO8601DateFormatter().string(
              from: Date().addingTimeInterval(-18 * 60)),
            source: "api",
            versions: [])
        ]
        let previewWorkerAnalytics = WorkerAnalyticsPayload(
          requests: 12_480, errors: 7, cpuTimeP50Us: 840,
          points: [])
        featureCache.set(
          FeatureCacheKey.workerSubdomain(accountID: "ui-account", name: "api-worker"), true)
        featureCache.set(
          FeatureCacheKey.workerDeployments(accountID: "ui-account", name: "api-worker"),
          previewWorkerDeployments)
        featureCache.set(
          FeatureCacheKey.workerAnalytics(accountID: "ui-account", name: "api-worker"),
          previewWorkerAnalytics)
        featureCache.set(
          WorkerDetailSnapshot.cacheKey(accountID: "ui-account", name: "api-worker"),
          WorkerDetailSnapshot(
            subdomainEnabled: true,
            workersDevHostname: "api-worker.preview.workers.dev",
            deployments: previewWorkerDeployments,
            analytics: previewWorkerAnalytics,
            domains: [],
            routes: []))
        if let buckets = try? JSONDecoder().decode(
          [R2Bucket].self,
          from: Data(#"[{"name":"assets","creation_date":"2026-01-15T12:00:00Z"}]"#.utf8))
        {
          featureCache.set(FeatureCacheKey.r2Buckets("ui-account"), buckets)
        }
        if let namespaces = try? JSONDecoder().decode(
          [KVNamespace].self,
          from: Data(#"[{"id":"kv-prod","title":"prod-kv"}]"#.utf8))
        {
          featureCache.set(FeatureCacheKey.kvNamespaces("ui-account"), namespaces)
        }
        let previewAnalyticsFormatter = ISO8601DateFormatter()
        var previewHTTPPoints: [AccountAnalyticsPoint] = []
        var previewWorkerPoints: [AccountAnalyticsPoint] = []
        for index in 0..<8 {
          let date = Date(timeIntervalSinceNow: TimeInterval(index - 7) * 10_800)
          let datetime = previewAnalyticsFormatter.string(from: date)
          previewHTTPPoints.append(
            AccountAnalyticsPoint(
              datetime: datetime,
              requests: 920 + (index * 175),
              bytes: Int64(11_800_000 + (index * 1_450_000)),
              errors: 18 + index,
              cacheRate: 0.72 + (Double(index) * 0.015),
              clientErrorRate: 0.012 + (Double(index % 3) * 0.004),
              encryptedRequestRate: 0.94,
              encryptedBytes: Int64(11_100_000 + (index * 1_360_000))))
          previewWorkerPoints.append(
            AccountAnalyticsPoint(
              datetime: datetime,
              requests: 610 + (index * 92),
              errors: 2 + (index % 3),
              cpuTimeP90Us: 860 + (Double(index) * 48)))
        }
        for hours in [24, 168, 720] {
          featureCache.set(
            FeatureCacheKey.accountAnalytics("ui-account", hours: hours),
            AccountAnalyticsSnapshot(
              overview: AccountAnalyticsOverview(
                webRequests: 12_480,
                bytes: 158_400_000,
                cacheRate: 0.78,
                clientErrorRate: 0.016,
                encryptedRequestRate: 0.94,
                encryptedBytes: 148_800_000,
                workerInvocations: 7_260,
                workerErrors: 19,
                cpuTimeP90Us: 1_180,
                hours: hours),
              httpPoints: previewHTTPPoints,
              workerPoints: previewWorkerPoints),
            ttl: nil)
        }
        // Two Cloudflare deliveries so the inbox has both an unread row and a
        // history row to render.
        let watchtowerPreview = WatchtowerSnapshot(
          alerts: [
            NotificationHistoryEntry(
              historyID: "ui-alert-1",
              name: "Tunnel health",
              alertType: "tunnel_health_event",
              alertBody: "homelab-01 disconnected from Cloudflare",
              sent: ISO8601DateFormatter().string(from: .now)),
            NotificationHistoryEntry(
              historyID: "ui-alert-2",
              name: "Certificate expiring",
              alertType: "universal_ssl_event_type",
              alertBody: "api.example.net",
              sent: ISO8601DateFormatter().string(
                from: Date(timeIntervalSinceNow: -86_400))),
          ],
          alertsStatus: .ok,
          fetchedAt: .now)
        featureCache.set(FeatureCacheKey.watchtower("ui-account"), watchtowerPreview)
        syncWatchtowerInboxBadge(from: watchtowerPreview, accountID: "ui-account")
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
    // Older installs can have a valid token without a scope mirror. Unknown is
    // not equivalent to the latest read-only profile: claiming otherwise can
    // suppress OAuth even when the server rejects a newly added read endpoint.
    grantedScopes = try? await tokenStore.getGrantedScopes()
    selectedScopes = DashAuthorizationScopes.core
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
    authorize(scopes: DashAuthorizationScopes.core, preservesExistingSession: false)
  }

  func requestAccess(to scopes: Set<String>) {
    guard !scopes.isEmpty else { return }
    if isDemoSession {
      // The demo is intentionally read-only. A write CTA means "connect my
      // account", never "replace the demo client's token in place".
      guard Self.demoAccessRequiresConnection(scopes) else { return }
      exitDemo()
      Task {
        await Task.yield()
        await R2TemporaryFile.removeAllFiles()
      }
      return
    }
    guard !isAuthenticating else { return }
    guard
      let requested = Self.accountAuthorizationRequest(
        granted: grantedScopes,
        requested: scopes)
    else { return }
    authorize(scopes: requested, preservesExistingSession: true)
  }

  static func demoAccessRequiresConnection(_ scopes: Set<String>) -> Bool {
    !scopes.isSubset(of: demoGrantedScopes)
  }

  /// Real-account authorization is intentionally one-shot for now. Existing
  /// grants still contribute any out-of-profile scopes, while every upgrade
  /// asks for the complete set used by Dash's current features.
  static func accountAccessScopes(
    granted: Set<String>?,
    requested: Set<String>
  ) -> Set<String> {
    (granted ?? [])
      .union(requested)
      .union(DashAuthorizationScopes.core)
      .union(CloudflareScopes.required)
  }

  static func accountAuthorizationRequest(
    granted: Set<String>?,
    requested: Set<String>
  ) -> Set<String>? {
    let desired = accountAccessScopes(granted: granted, requested: requested)
    if let granted, desired.isSubset(of: granted) { return nil }
    return desired
  }

  func hasScopes(_ scopes: Set<String>) -> Bool {
    guard let grantedScopes else { return false }
    return scopes.isSubset(of: grantedScopes)
  }

  private func authorize(scopes: Set<String>, preservesExistingSession: Bool) {
    guard !isAuthenticating else { return }
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
            redirectURI: configuration.redirectURI, session: DashAPISession.shared
          )
          try await tokenStore.setTokens(tokens)
          replacedTokens = true
          let granted =
            tokens.scope.map { Set($0.split(separator: " ").map(String.init)) }
            ?? requestedScopes
          try await tokenStore.setGrantedScopes(granted)
          grantedScopes = granted
          selectedScopes = granted
          resetAccountScopedWork()
          try await loadIdentity()
          if preservesExistingSession {
            // A legacy grant upgrade stays on the current screen so the user
            // can retry the action that led them to the consent sheet.
            isAuthenticating = false
          } else {
            // Let the browser sheet finish dismissing first, or the login →
            // catalog transition plays hidden behind it and sign-in reads as a
            // hard cut.
            try? await Task.sleep(for: .milliseconds(280))
            authState = .authenticated
            isAuthenticating = false
          }
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
    Task { @MainActor [weak self] in
      // start() presents the system browser sheet — heavyweight main-thread
      // work that would land mid press-pulse and eat its spring-back frames.
      // The ring is already showing (isAuthenticating), and the sheet's own
      // presentation latency hides this wait.
      try? await Task.sleep(for: DashPressButtonStyle.pulseSettle)
      guard let self, self.authSession === session else { return }
      if !session.start() {
        self.isAuthenticating = false
        self.errorMessage = "Could not start the sign-in session."
      }
    }
  }

  /// Enters the read-only demo session: swaps the client for one served
  /// entirely by `DemoBackend`, then runs the normal identity path so the
  /// demo exercises the same code as a real sign-in.
  func enterDemo() {
    guard authState == .unauthenticated, !isDemoSession else { return }
    resetAccountScopedWork()
    pendingLegacyNotificationRoute = nil
    isDemoSession = true
    errorMessage = nil
    client = CloudflareClient(
      clientID: "demo", tokenStore: DemoTokenStore(), session: DemoBackend.session)
    grantedScopes = Self.demoGrantedScopes
    Task { [weak self] in
      guard let self else { return }
      try? await loadIdentity()
      guard isDemoSession else { return }
      authState = .authenticated
    }
  }

  /// Tears down the demo session: restores the real client and returns to
  /// onboarding. No keychain, push, or revocation work — the demo never
  /// touched any of it.
  private func exitDemo() {
    resetAccountScopedWork()
    isDemoSession = false
    client = CloudflareClient(
      clientID: configuration.clientID, tokenStore: tokenStore, session: DashAPISession.shared)
    avatars.clear()
    Task { await r2Thumbnails.clear() }
    accounts = []
    user = nil
    activeAccountID = nil
    grantedScopes = nil
    selectedScopes = DashAuthorizationScopes.core
    identityStale = false
    watchtowerUnreadAlertCount = nil
    pendingRoute = nil
    pendingLegacyNotificationRoute = nil
    WatchtowerNotificationBaselineStore.clearAll()
    MetricsWidgetPublisher.clear()
    toasts.dismiss()
    UserDefaults.standard.removeObject(forKey: "dash.active_account_id")
    R2ShareDestination.clear()
    authState = .unauthenticated
  }

  func signOut() async {
    if isDemoSession {
      exitDemo()
      await Task.yield()
      await R2TemporaryFile.removeAllFiles()
      return
    }
    isAuthenticating = false
    let pendingPushReconcile = pushReconcileTask
    resetAccountScopedWork()
    activeAccountID = nil
    MetricsWidgetPublisher.clear()
    await pendingPushReconcile?.value

    // Push webhooks live in the user's Cloudflare accounts — delete them
    // before revoking the token, or the client can no longer authenticate.
    let pushAccountIDs = PushRegistrationService.enabledAccountIDs()
    for accountID in pushAccountIDs {
      try? await PushRegistrationService.disable(accountID: accountID, client: client)
    }
    UIApplication.shared.unregisterForRemoteNotifications()
    PushRegistrationService.clearAllStoredWebhookIDs()
    // Locally-scheduled domain reminders name a specific domain in a specific
    // account. Left behind, one would announce a domain the app can no longer
    // open — so unlike the preference below, these do not survive sign-out.
    await ExpiryReminders.cancelAll()
    // Watchtower's local "Notify on new issues" preference is intentionally
    // kept — it has no server-side side effects.

    if let token = try? await tokenStore.getAccessToken() {
      try? await OAuth.revoke(
        clientID: configuration.clientID, token: token, session: DashAPISession.shared)
    }
    try? await tokenStore.clear()
    avatars.clear()
    await r2Thumbnails.clear()
    accounts = []
    user = nil
    grantedScopes = nil
    selectedScopes = DashAuthorizationScopes.core
    identityStale = false
    watchtowerUnreadAlertCount = nil
    pendingRoute = nil
    pendingLegacyNotificationRoute = nil
    pendingDeviceToken = nil
    WatchtowerNotificationBaselineStore.clearAll()
    toasts.dismiss()
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundRefreshID)

    UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    clearWatchtowerWidgetSnapshot()
    MetricsWidgetPublisher.clear()
    UserDefaults.standard.removeObject(forKey: "dash.active_account_id")
    R2ShareDestination.clear()
    authState = .unauthenticated
    // Let SwiftUI tear down account-scoped views and cancel their transfers
    // before removing the session's temporary R2 files.
    await Task.yield()
    await R2TemporaryFile.removeAllFiles()
  }

  func selectAccount(_ account: CloudflareAccount) {
    guard activeAccountID != account.id else { return }
    resetAccountScopedWork()
    Task { await r2Thumbnails.clear() }
    watchtowerUnreadAlertCount = nil
    toasts.dismiss()
    activeAccountID = account.id
    UserDefaults.standard.set(account.id, forKey: "dash.active_account_id")
  }

  /// Drops caches that embed already-resolved copy so Settings → Language can
  /// rebuild Watchtower (and similar) strings without a process restart.
  func discardLocalizedCaches() {
    featureCache.remove(prefix: "watchtower:")
    toasts.dismiss()
  }

  /// Single entry point for Watchtower data: serves the cached snapshot when
  /// fresh, joins an in-flight refresh for the same account instead of
  /// doubling the fan-out, and keeps the tab-badge count in sync.
  func watchtowerSnapshot(
    force: Bool = false,
    notifiesLocally: Bool = true
  ) async -> WatchtowerSnapshot? {
    guard let context = accountRequestContext else { return nil }
    let key = FeatureCacheKey.watchtower(context.accountID)
    if !force, let cached: WatchtowerSnapshot = featureCache.get(key) {
      syncWatchtowerInboxBadge(from: cached, accountID: context.accountID)
      return cached
    }
    let client = client
    let snapshot: WatchtowerSnapshot
    do {
      snapshot = try await featureCache.coalescedLoad(key) {
        try Task.checkCancellation()
        let result = try await WatchtowerAlertsLoader.loadCancellable(
          client: client, accountID: context.accountID)
        try Task.checkCancellation()
        return WatchtowerSnapshot(
          alerts: result.alerts,
          alertsStatus: result.alertsStatus,
          fetchedAt: .now)
      }
    } catch {
      return nil
    }
    guard !Task.isCancelled, isCurrentAccount(context) else { return nil }
    if let committed: WatchtowerSnapshot = featureCache.get(key),
      committed.fetchedAt >= snapshot.fetchedAt
    {
      return committed
    }
    featureCache.set(key, snapshot, ttl: nil)
    syncWatchtowerInboxBadge(from: snapshot, accountID: context.accountID)
    publishWidgetSnapshot(
      snapshot, accountID: context.accountID, notifiesLocally: notifiesLocally)
    return snapshot
  }

  /// Recomputes the shared tab/inbox badge from the cached snapshot + local ignores.
  func refreshWatchtowerInboxBadge() {
    guard let accountID = activeAccountID else {
      watchtowerUnreadAlertCount = nil
      return
    }
    let cached: WatchtowerSnapshot? = featureCache.get(FeatureCacheKey.watchtower(accountID))
    guard let cached else { return }
    syncWatchtowerInboxBadge(from: cached, accountID: accountID)
  }

  /// Refreshes Cloudflare's deliveries for the Watchtower tab's inbox badge.
  func refreshWatchtowerAlerts(force: Bool = false) async {
    _ = await watchtowerSnapshot(force: force)
  }

  /// Ignores every unread delivery for the active account (local only).
  func ignoreAllWatchtowerAlerts() {
    guard let accountID = activeAccountID else { return }
    let cached: WatchtowerSnapshot? = featureCache.get(FeatureCacheKey.watchtower(accountID))
    guard let cached else { return }
    let unreadIDs = WatchtowerInboxStore.contents(
      accountID: accountID,
      alerts: cached.alertsStatus == .ok ? cached.alerts : []
    )
    .unreadNotifications
    .map(\.id)
    guard !unreadIDs.isEmpty else { return }
    WatchtowerInboxStore.ignore(unreadIDs, accountID: accountID)
    refreshWatchtowerInboxBadge()
  }

  private func syncWatchtowerInboxBadge(from snapshot: WatchtowerSnapshot, accountID: String) {
    watchtowerUnreadAlertCount = WatchtowerInboxStore.unreadCount(
      accountID: accountID,
      alerts: snapshot.alertsStatus == .ok ? snapshot.alerts : []
    )
  }

  /// Writes the slim snapshot into the App Group container, refreshes the
  /// widget, and fires any due local notifications by diffing against the
  /// previously shared snapshot. A missing container (entitlement not
  /// provisioned) is a silent no-op — the widget just shows its empty state.
  ///
  /// `notifiesLocally: false` still advances the baseline — the refresh was
  /// triggered by a push that already showed the user these deliveries, so
  /// re-announcing them locally would double every alert.
  private func publishWidgetSnapshot(
    _ snapshot: WatchtowerSnapshot,
    accountID: String,
    notifiesLocally: Bool = true
  ) {
    guard let url = WatchtowerWidgetSnapshot.containerFileURL else { return }
    let widget = snapshot.widgetSnapshot(
      accountID: accountID,
      accountName: activeAccount?.name
    )
    let previous = WatchtowerNotificationBaselineStore.snapshot(accountID: accountID)
    WatchtowerNotificationBaselineStore.store(widget, accountID: accountID)
    try? widget.write(to: url)
    WidgetCenter.shared.reloadAllTimelines()
    guard notifiesLocally else { return }
    Task {
      await WatchtowerNotifier.notifyIfNeeded(
        previous: previous,
        current: widget,
        accountID: accountID
      )
    }
  }

  static let backgroundRefreshID = "sh.xat.dash.app.watchtower.refresh"

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
      syncWatchtowerInboxBadge(from: cached, accountID: accountID)
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
    resolvePendingLegacyNotificationRoute()
  }
}

extension AppModel: PushTokenInbox {
  /// Woken by the relay's silent push. Forces a Watchtower reload — the TTL
  /// says the snapshot is fresh, but a delivery just landed, so it isn't — and
  /// suppresses the local-notification diff so the user is told once, by the
  /// alert push that arrived alongside this one.
  func performPushTriggeredRefresh() async {
    guard !isDemoSession, accountRequestContext != nil else { return }
    _ = await watchtowerSnapshot(force: true, notifiesLocally: false)
  }

  func receiveDeviceToken(_ token: Data) {
    let hex = PushRegistration.hexToken(from: token)
    pendingDeviceToken = hex
    guard !isDemoSession else { return }
    guard hasScopes(["notifications.write"]) else { return }
    let accountIDs = PushRegistrationService.enabledAccountIDs()
    guard !accountIDs.isEmpty else { return }
    let generation = accountGeneration
    let client = client
    let configuration = configuration
    pushReconcileTask?.cancel()
    pushReconcileTask = Task { [weak self] in
      for accountID in accountIDs {
        guard !Task.isCancelled, let self, !self.isDemoSession,
          self.accountGeneration == generation
        else { return }
        try? await PushRegistrationService.reconcile(
          accountID: accountID,
          client: client,
          configuration: configuration,
          deviceToken: hex
        )
      }
    }
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
