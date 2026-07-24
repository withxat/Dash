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
  var accounts: [CloudflareAccount] = []
  // Mirrored into App Group defaults so the share extension knows which
  // account to upload into; standard defaults are invisible across processes.
  var activeAccountID: String? {
    didSet { R2ShareDestination.setActiveAccountID(activeAccountID) }
  }
  var authState: AuthenticationState = .loading
  var errorMessage: String?
  var isAuthenticating = false
  var grantedScopes: Set<String>?
  var selectedScopes: Set<String>
  var user: CloudflareUser?
  /// True while the session is trusted but the identity fetch failed
  /// (offline, Cloudflare outage). Cleared by the next successful retry.
  var identityStale = false
  /// Pending inbox count (Cloudflare alerts + Dash detections, minus ignored)
  /// — drives the Watchtower tab badge and floating inbox badge together.
  /// nil until the first check completes for the active account.
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
        featureCache.set(
          FeatureCacheKey.workerSubdomain(accountID: "ui-account", name: "api-worker"), true)
        featureCache.set(
          FeatureCacheKey.workerDeployments(accountID: "ui-account", name: "api-worker"),
          [
            WorkerDeploymentSummary(
              id: "preview-deployment",
              createdOn: ISO8601DateFormatter().string(
                from: Date().addingTimeInterval(-18 * 60)),
              source: "api",
              versions: [])
          ])
        featureCache.set(
          FeatureCacheKey.workerAnalytics(accountID: "ui-account", name: "api-worker"),
          WorkerAnalyticsPayload(
            requests: 12_480, errors: 7, cpuTimeP50Us: 840,
            points: []))
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
        // One signal of each routing shape: in-app destination, Open in
        // Cloudflare (externalURL), and Pages project push.
        let watchtowerPreview = WatchtowerSnapshot(
          signals: [
            WatchtowerSignal(
              id: "zones", title: "Domains", detail: "1 domain pending",
              status: .warning, destination: .feature(.zones),
              suggestedAction: "Finish the nameserver move",
              resourceName: "api.example.net"),
            WatchtowerSignal(
              id: "tunnels", title: "Tunnels", detail: "1 tunnel down",
              status: .critical, destination: nil,
              externalURL: URL(
                string: "https://one.dash.cloudflare.com/ui-account/networks/tunnels"),
              suggestedAction: "Check cloudflared and reconnect the tunnel",
              resourceName: "homelab-01"),
            WatchtowerSignal(
              id: "pages", title: "Pages deployments",
              detail: "site: latest deployment failed",
              status: .warning, destination: .pagesProject("site"),
              suggestedAction: "Open the project to retry or inspect the log",
              resourceName: "site"),
          ],
          alerts: [], alertsStatus: .ok, missingScopeChecks: [],
          failedChecks: [], fetchedAt: .now)
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
          featureCache.clear()
          try await loadIdentity()
          // Let the browser sheet finish dismissing first, or the login →
          // catalog transition plays hidden behind it and sign-in reads as a
          // hard cut.
          try? await Task.sleep(for: .milliseconds(280))
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
    isDemoSession = true
    errorMessage = nil
    client = CloudflareClient(
      clientID: "demo", tokenStore: DemoTokenStore(), session: DemoBackend.session)
    grantedScopes = Set(CloudflareScopes.published)
    Task {
      try? await loadIdentity()
      authState = .authenticated
    }
  }

  /// Tears down the demo session: restores the real client and returns to
  /// onboarding. No keychain, push, or revocation work — the demo never
  /// touched any of it.
  private func exitDemo() {
    isDemoSession = false
    client = CloudflareClient(
      clientID: configuration.clientID, tokenStore: tokenStore, session: DashAPISession.shared)
    featureCache.clear()
    avatars.clear()
    Task { await r2Thumbnails.clear() }
    accounts = []
    user = nil
    activeAccountID = nil
    grantedScopes = nil
    selectedScopes = DashAuthorizationScopes.core
    identityStale = false
    watchtowerIssueCount = nil
    pendingRoute = nil
    toasts.dismiss()
    UserDefaults.standard.removeObject(forKey: "dash.active_account_id")
    R2ShareDestination.clear()
    authState = .unauthenticated
  }

  func signOut() async {
    if isDemoSession {
      exitDemo()
      return
    }
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
      try? await OAuth.revoke(
        clientID: configuration.clientID, token: token, session: DashAPISession.shared)
    }
    try? await tokenStore.clear()
    featureCache.clear()
    avatars.clear()
    await r2Thumbnails.clear()
    accounts = []
    user = nil
    activeAccountID = nil
    grantedScopes = nil
    selectedScopes = DashAuthorizationScopes.core
    identityStale = false
    watchtowerIssueCount = nil
    pendingRoute = nil
    pendingDeviceToken = nil
    toasts.dismiss()
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundRefreshID)
    PagesBuildActivityController.shared.cancelBackgroundRefresh()

    UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    if let url = WatchtowerWidgetSnapshot.containerFileURL {
      WatchtowerWidgetSnapshot.clear(at: url)
      WidgetCenter.shared.reloadAllTimelines()
    }
    UserDefaults.standard.removeObject(forKey: "dash.active_account_id")
    R2ShareDestination.clear()
    authState = .unauthenticated
  }

  func selectAccount(_ account: CloudflareAccount) {
    guard activeAccountID != account.id else { return }
    featureCache.clear()
    Task { await r2Thumbnails.clear() }
    watchtowerIssueCount = nil
    toasts.dismiss()
    activeAccountID = account.id
    UserDefaults.standard.set(account.id, forKey: "dash.active_account_id")
  }

  /// Drops caches that embed already-resolved copy so Settings → Language can
  /// rebuild Watchtower (and similar) strings without a process restart.
  func discardLocalizedCaches() {
    featureCache.remove(prefix: "watchtower:")
    watchtowerRefresh?.task.cancel()
    watchtowerRefresh = nil
    toasts.dismiss()
  }

  /// Single entry point for Watchtower data: serves the cached snapshot when
  /// fresh, joins an in-flight refresh for the same account instead of
  /// doubling the fan-out, and keeps the tab-badge count in sync.
  func watchtowerSnapshot(force: Bool = false) async -> WatchtowerSnapshot? {
    guard let accountID = activeAccountID else { return nil }
    let key = FeatureCacheKey.watchtower(accountID)
    if !force, let cached: WatchtowerSnapshot = featureCache.get(key) {
      syncWatchtowerInboxBadge(from: cached, accountID: accountID)
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
    featureCache.set(key, snapshot, ttl: nil)
    syncWatchtowerInboxBadge(from: snapshot, accountID: accountID)
    publishWidgetSnapshot(snapshot)
    return snapshot
  }

  /// Recomputes the shared tab/inbox badge from the cached snapshot + local ignores.
  func refreshWatchtowerInboxBadge() {
    guard let accountID = activeAccountID else {
      watchtowerIssueCount = nil
      return
    }
    let cached: WatchtowerSnapshot? = featureCache.get(FeatureCacheKey.watchtower(accountID))
    guard let cached else { return }
    syncWatchtowerInboxBadge(from: cached, accountID: accountID)
  }

  /// Clears every Pending inbox row for the current account (local ignore only).
  func ignoreAllWatchtowerAlerts() {
    guard let accountID = activeAccountID else { return }
    let cached: WatchtowerSnapshot? = featureCache.get(FeatureCacheKey.watchtower(accountID))
    guard let cached else { return }
    let ignored = WatchtowerInboxStore.ignoredIDs(accountID: accountID)
    let activeIDs = WatchtowerInboxStore.build(
      accountID: accountID,
      alerts: cached.alertsStatus == .ok ? cached.alerts : [],
      signals: cached.signals
    )
    .filter { !ignored.contains($0.id) }
    .map(\.id)
    guard !activeIDs.isEmpty else { return }
    WatchtowerInboxStore.ignoreAll(activeIDs, accountID: accountID)
    refreshWatchtowerInboxBadge()
  }

  private func syncWatchtowerInboxBadge(from snapshot: WatchtowerSnapshot, accountID: String) {
    watchtowerIssueCount = WatchtowerInboxStore.activeCount(
      accountID: accountID,
      alerts: snapshot.alertsStatus == .ok ? snapshot.alerts : [],
      signals: snapshot.signals
    )
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
  }
}

extension AppModel: PushTokenInbox {
  func receiveDeviceToken(_ token: Data) {
    let hex = PushRegistration.hexToken(from: token)
    pendingDeviceToken = hex
    guard let accountID = activeAccountID,
      PushRegistrationService.isEnabled(accountID: accountID)
    else { return }
    Task {
      try? await PushRegistrationService.reconcile(
        accountID: accountID, client: client,
        configuration: configuration, deviceToken: hex)
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
