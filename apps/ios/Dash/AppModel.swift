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

/// A background-task completion can arrive after a newer lease has replaced
/// it. Binding every expiration/waiter to a generation prevents an older
/// callback from ending the newer task.
@MainActor
final class DeferredDeletionBackgroundTaskLease {
  private var current: (generation: UUID, identifier: UIBackgroundTaskIdentifier)?
  private let endHandler: @MainActor (UIBackgroundTaskIdentifier) -> Void

  init(
    endHandler: @escaping @MainActor (UIBackgroundTaskIdentifier) -> Void = {
      UIApplication.shared.endBackgroundTask($0)
    }
  ) {
    self.endHandler = endHandler
  }

  @discardableResult
  func replace(
    using begin: (_ expirationHandler: @escaping @Sendable () -> Void)
      -> UIBackgroundTaskIdentifier
  ) -> UUID {
    endCurrent()
    let generation = UUID()
    let identifier = begin { [weak self] in
      Task { @MainActor in
        self?.end(generation: generation)
      }
    }
    if identifier != .invalid {
      current = (generation, identifier)
    }
    return generation
  }

  func end(generation: UUID) {
    guard current?.generation == generation else { return }
    endCurrent()
  }

  private func endCurrent() {
    guard let current else { return }
    self.current = nil
    endHandler(current.identifier)
  }
}

struct AccountRequestContext: Hashable, Sendable {
  let accountID: String
  let generation: UInt64
}

struct PendingHomeAction: Equatable, Sendable {
  let action: HomeActionID
  let context: AccountRequestContext

  func matches(_ currentContext: AccountRequestContext?) -> Bool {
    context == currentContext
  }
}

enum WatchtowerRefreshSource: Equatable, Sendable {
  case foreground
  case background
  case remoteNotification

  var allowsLocalNotifications: Bool {
    self != .remoteNotification
  }
}

@MainActor
enum WatchtowerRemoteRefreshInvalidationStore {
  private static let prefix = "dash.watchtower.remote_refresh."
  private static let generationPrefix = "\(prefix)generation."
  private static let handledPrefix = "\(prefix)handled."

  static func generationKey(accountID: String) -> String {
    "\(generationPrefix)\(accountID)"
  }

  static func handledKey(accountID: String) -> String {
    "\(handledPrefix)\(accountID)"
  }

  static func generation(
    accountID: String,
    defaults: UserDefaults = .standard
  ) -> UInt64 {
    UInt64(max(0, defaults.integer(forKey: generationKey(accountID: accountID))))
  }

  static func handledGeneration(
    accountID: String,
    defaults: UserDefaults = .standard
  ) -> UInt64 {
    UInt64(max(0, defaults.integer(forKey: handledKey(accountID: accountID))))
  }

  @discardableResult
  static func mark(
    accountID: String,
    defaults: UserDefaults = .standard
  ) -> UInt64 {
    let next =
      max(
        generation(accountID: accountID, defaults: defaults),
        handledGeneration(accountID: accountID, defaults: defaults)
      ) &+ 1
    defaults.set(Int(next), forKey: generationKey(accountID: accountID))
    return next
  }

  static func pendingGeneration(
    accountID: String,
    defaults: UserDefaults = .standard
  ) -> UInt64? {
    let current = generation(accountID: accountID, defaults: defaults)
    return current > handledGeneration(accountID: accountID, defaults: defaults)
      ? current : nil
  }

  static func contains(accountID: String, defaults: UserDefaults = .standard) -> Bool {
    pendingGeneration(accountID: accountID, defaults: defaults) != nil
  }

  static func allowsLocalNotifications(
    source: WatchtowerRefreshSource,
    accountID: String,
    defaults: UserDefaults = .standard
  ) -> Bool {
    source.allowsLocalNotifications && !contains(accountID: accountID, defaults: defaults)
  }

  static func clear(
    accountID: String,
    matching generation: UInt64? = nil,
    defaults: UserDefaults = .standard
  ) {
    let current = self.generation(accountID: accountID, defaults: defaults)
    if let generation, current != generation {
      return
    }
    defaults.set(Int(current), forKey: handledKey(accountID: accountID))
  }

  static func clearAll(defaults: UserDefaults = .standard) {
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
      defaults.removeObject(forKey: key)
    }
  }
}

@MainActor
@Observable
final class AppModel {
  static let demoGrantedScopes = DashAuthorizationScopes.initialReadOnly

  let configuration: AppConfiguration
  let tokenStore: any TokenStore
  /// Swapped for a `DemoBackend`-served client while the demo session runs;
  /// every consumer reads it per-call, so the swap takes effect everywhere.
  private(set) var client: CloudflareClient
  /// True while the read-only demo session is active (App Review's path past
  /// the OAuth wall). Sign-out becomes a lightweight demo exit.
  private(set) var isDemoSession = false
  private(set) var isEnteringDemo = false
  let featureCache = FeatureDataCache()
  let avatars = AvatarStore()
  let r2Thumbnails = R2ThumbnailStore()
  /// Top-of-screen action feedback. Prefer this over sticky inline notices for
  /// completed / failed mutations; keep `DashNotice` for persistent state.
  let toasts = DashToastCenter()
  let deferredDeletions: DeferredDeletionCoordinator
  var accounts: [CloudflareAccount] = [] {
    didSet {
      MetricsWidgetPublisher.syncAccounts(accounts, activeAccountID: activeAccountID)
      syncNotificationAccountAuthorization()
      scheduleFileProviderDomainReconciliation()
    }
  }
  // Mirrored into App Group defaults so the share extension knows which
  // account to upload into; standard defaults are invisible across processes.
  var activeAccountID: String? {
    didSet {
      R2ShareDestination.setActiveAccountID(activeAccountID)
      MetricsWidgetPublisher.syncAccounts(accounts, activeAccountID: activeAccountID)
      // Quick Actions deep links embed `?account=`; refresh so tiles target the
      // newly selected account even when the action list itself is unchanged.
      WidgetCenter.shared.reloadTimelines(ofKind: QuickActionsWidgetKind.id)
      guard oldValue != activeAccountID else { return }
      clearWatchtowerWidgetSnapshot()
    }
  }
  var authState: AuthenticationState = .loading {
    didSet {
      syncNotificationAccountAuthorization()
      if authState == .unauthenticated {
        MetricsWidgetPublisher.clear()
        clearWatchtowerWidgetSnapshot()
      } else if authState == .authenticated {
        scheduleFileProviderDomainReconciliation()
      }
    }
  }
  var errorMessage: String?
  var isAuthenticating = false
  private(set) var authenticationActionPhase: DashActionPhase = .idle
  private(set) var authenticationActionOwner: UUID?
  private(set) var signOutActionPhase: DashActionPhase = .idle
  private var grantedScopesPendingPresentation: Set<String>?
  private var authenticationPresentationFallbackTask: Task<Void, Never>?
  private var authenticationPresentationGeneration = 0
  private var signOutPresentationFallbackTask: Task<Void, Never>?
  private var signOutPresentationGeneration = 0
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
  /// Quick-action deep link waiting for Home to present the matching tray.
  /// Set by MainTabView after account scope is verified; cleared by Home once
  /// zones (when needed) are ready to drive the same path as a tile tap.
  var pendingHomeAction: PendingHomeAction?
  /// An older notification that predates account-bound routes. It stays
  /// buffered until identity proves there is exactly one possible account.
  private var pendingLegacyNotificationRoute: DashRoute?

  /// APNs device token hex, buffered because the system callback can arrive
  /// before bootstrap finishes (RootWithSplash holds ~800ms).
  var pendingDeviceToken: String?

  private var authSession: ASWebAuthenticationSession?
  private var pushReconcileTask: Task<Void, Never>?
  private var fileProviderReconcileTask: Task<Void, Never>?
  private var fileProviderReconcileGeneration: UInt64 = 0
  private var systemBadgeTask: Task<Void, Never>?
  private var systemBadgeGeneration: UInt64 = 0
  private var isRetryingIdentity = false
  private var isSigningOut = false
  private var accountGeneration: UInt64 = 0
  private let deferredDeletionBackgroundLease = DeferredDeletionBackgroundTaskLease()
  private let deferredDeletionExecutor: CloudflareDeferredDeletionExecutor
  private let authenticatedSession: URLSession

  init(
    configuration: AppConfiguration = .current,
    tokenStore: any TokenStore = KeychainTokenStore(),
    session: URLSession = DashAPISession.shared,
    deferredDeletionPersistence: UserDefaults? = .standard
  ) {
    self.configuration = configuration
    selectedScopes = DashAuthorizationScopes.core
    self.tokenStore = tokenStore
    authenticatedSession = session
    let apiClient = CloudflareClient(
      clientID: configuration.clientID, tokenStore: tokenStore, session: session)
    client = apiClient
    let deferredDeletionExecutor = CloudflareDeferredDeletionExecutor(client: apiClient)
    self.deferredDeletionExecutor = deferredDeletionExecutor
    deferredDeletions = DeferredDeletionCoordinator(
      executor: deferredDeletionExecutor,
      toasts: toasts,
      invalidateCache: { [featureCache] command in
        switch command {
        case .dnsRecord(_, let zoneID, _, _, _):
          featureCache.remove(FeatureCacheKey.dnsRecords(zoneID))
        }
      },
      persistence: deferredDeletionPersistence,
      requiresCredentialActivation: true)
    activeAccountID = UserDefaults.standard.string(forKey: DashAppGroup.activeAccountKey)
    // Property observers don't fire during init — mirror explicitly so the
    // share extension works without waiting for an account switch.
    R2ShareDestination.setActiveAccountID(activeAccountID)
    installMemoryWarningObserver()
  }

  var activeAccount: CloudflareAccount? { accounts.first { $0.id == activeAccountID } }

  func performToastAction(_ action: DashToast.Action) {
    switch action {
    case .undoDeferredDeletionBatch:
      deferredDeletions.undoCurrentBatch()
    case .retryDeferredDeletion(let operationID):
      deferredDeletions.retry(operationID)
    case .retryDeferredDeletions(let operationIDs):
      deferredDeletions.retryFailures(operationIDs)
    }
  }

  var accountRequestContext: AccountRequestContext? {
    guard let activeAccountID else { return nil }
    return AccountRequestContext(accountID: activeAccountID, generation: accountGeneration)
  }

  var canModifyFileProviderDomains: Bool {
    authState == .authenticated && !isDemoSession && !isAuthenticating && !isSigningOut
  }

  nonisolated static func shouldReconcileFileProviderDomains(
    authState: AuthenticationState,
    identityStale: Bool,
    isDemoSession: Bool,
    isSigningOut: Bool
  ) -> Bool {
    authState == .authenticated
      && !identityStale
      && !isDemoSession
      && !isSigningOut
  }

  func isCurrentAccount(_ context: AccountRequestContext) -> Bool {
    activeAccountID == context.accountID && accountGeneration == context.generation
  }

  private func syncNotificationAccountAuthorization() {
    guard authState == .authenticated, !isDemoSession, !isSigningOut else {
      NotificationAccountAuthorizationStore.clear()
      return
    }
    NotificationAccountAuthorizationStore.replace(with: Set(accounts.map(\.id)))
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
    fileProviderReconcileGeneration &+= 1
    fileProviderReconcileTask?.cancel()
    fileProviderReconcileTask = nil
    accountGeneration &+= 1
    pendingHomeAction = nil
    featureCache.clear()
    PagesBuildActivityController.shared.invalidateSession()
    WorkerBuildActivityController.shared.invalidateSession()
    watchtowerUnreadAlertCount = nil
  }

  /// Reconcile only after authenticated identity has supplied the complete
  /// account set. Mounting remains an explicit user choice; this background
  /// pass only removes domains whose account no longer exists.
  private func scheduleFileProviderDomainReconciliation() {
    guard
      Self.shouldReconcileFileProviderDomains(
        authState: authState,
        identityStale: identityStale,
        isDemoSession: isDemoSession,
        isSigningOut: isSigningOut
      )
    else { return }
    fileProviderReconcileGeneration &+= 1
    let reconciliationGeneration = fileProviderReconcileGeneration
    let accountSnapshot = accounts
    fileProviderReconcileTask?.cancel()
    fileProviderReconcileTask = Task { @MainActor [weak self] in
      do {
        guard let self else { return }
        try Task.checkCancellation()
        let mountedAccountIDs = try await FileProviderDomains.mountedAccountIDs()
        var preservedAccountIDs = Set(accountSnapshot.map(\.id))
        let missingMountedAccountIDs = mountedAccountIDs.subtracting(preservedAccountIDs)

        // Account lists decode lossily so one newly malformed row cannot take
        // a File Provider domain and its downloaded replica down with it.
        // Only a direct 403/404 proves that the current credential no longer
        // owns a mounted account; every transient or decoding failure keeps it.
        for accountID in missingMountedAccountIDs.sorted() {
          try Task.checkCancellation()
          do {
            _ = try await self.client.getAccount(accountID)
            preservedAccountIDs.insert(accountID)
          } catch is CancellationError {
            throw CancellationError()
          } catch let error as CloudflareAPIError {
            if case .request(let status, _) = error, status == 403 || status == 404 {
              continue
            }
            preservedAccountIDs.insert(accountID)
          } catch {
            preservedAccountIDs.insert(accountID)
          }
        }

        try Task.checkCancellation()
        _ = try await FileProviderDomains.reconcile(
          accounts: accountSnapshot,
          preservingAccountIDs: preservedAccountIDs)
      } catch {
        // Domain state is re-read whenever the settings page opens and on the
        // next lifecycle reconciliation. A background failure must not turn a
        // healthy authenticated session into a global app error.
      }
      guard
        let self,
        self.fileProviderReconcileGeneration == reconciliationGeneration
      else { return }
      self.fileProviderReconcileTask = nil
    }
  }

  /// Returns only after live system state proves that every local replica is
  /// gone. A failure leaves the mirror intact so the app never claims cleanup
  /// succeeded while Files still holds downloaded account data.
  private func removeAllFileProviderDomains() async -> Bool {
    for _ in 0..<2 {
      do {
        let remainingAccountIDs = try await FileProviderDomains.removeAllDomains()
        guard remainingAccountIDs.isEmpty else { continue }
        FileProviderDomains.clearMirror()
        return true
      } catch {
        if let remainingAccountIDs = try? await FileProviderDomains.mountedAccountIDs(),
          remainingAccountIDs.isEmpty
        {
          FileProviderDomains.clearMirror()
          return true
        }
      }
    }
    return false
  }

  private func clearWatchtowerWidgetSnapshot() {
    if let url = WatchtowerWidgetSnapshot.containerFileURL {
      WatchtowerWidgetSnapshot.clear(at: url)
      WidgetCenter.shared.reloadAllTimelines()
    }
    setSystemBadgeCount(0)
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
        // UI previews share the simulator's UserDefaults across launches. Seed
        // every persisted value that changes the tested Home / Watchtower shape
        // so a prior test run can never change the next launch.
        let previewDefaults = UserDefaults.standard
        let previewKeys =
          [
            PinnedZones.key, PinnedZones.initializedAccountsKey, RecentResources.key,
            WatchtowerAnalyticsCardLayout.key, WatchtowerAnalyticsCardLayout.orderKey,
            WatchtowerAnalyticsCardLayout.hiddenKey, WatchtowerInboxStore.ignoredKey,
            WatchtowerInboxStore.readKey, WatchtowerNotificationBaselineStore.key,
            WatchtowerNotifier.optInDefaultsKey, DashWorkspaceWashPreset.storageKey,
            ICloudPreferencesSync.enabledKey,
          ]
          + ICloudPreferencesSync.Group.allCases.flatMap {
            [$0.modifiedAtKey, $0.pendingModifiedAtKey]
          }
        for key in previewKeys {
          previewDefaults.removeObject(forKey: key)
        }
        previewDefaults.set(HomeActions.defaultValue, forKey: HomeActions.key)
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
              featureCache.set(
                FeatureCacheKey.zoneAnalyticsHourly(zone.id),
                AnalyticsPeriodComparison(current: traffic, previous: traffic))
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
        // history row to render. The first-page baseline is seeded explicitly;
        // the newer delivery sits after it and therefore remains unread.
        WatchtowerInboxStore.markRead(
          ["cf:ui-alert-2"], accountID: "ui-account", defaults: previewDefaults)
        let previewNow = Date.now
        let watchtowerPreview = WatchtowerSnapshot(
          alerts: [
            NotificationHistoryEntry(
              historyID: "ui-alert-1",
              name: "Tunnel health",
              alertType: "tunnel_health_event",
              alertBody: "homelab-01 disconnected from Cloudflare",
              sent: ISO8601DateFormatter().string(
                from: previewNow.addingTimeInterval(60))),
            NotificationHistoryEntry(
              historyID: "ui-alert-2",
              name: "Certificate expiring",
              alertType: "universal_ssl_event_type",
              alertBody: "api.example.net",
              sent: ISO8601DateFormatter().string(
                from: previewNow.addingTimeInterval(-86_400))),
          ],
          alertsStatus: .ok,
          fetchedAt: .now)
        featureCache.set(FeatureCacheKey.watchtower("ui-account"), watchtowerPreview)
        syncWatchtowerInboxBadge(from: watchtowerPreview, accountID: "ui-account")
        deferredDeletions.activateCredential(
          profileID: "ui-profile",
          availableAccountIDs: ["ui-account"])
        authState = .authenticated
        return
      }
    #endif

    do {
      guard try await tokenStore.getAccessToken() != nil else {
        let removedFileProviderDomains = await removeAllFileProviderDomains()
        if !removedFileProviderDomains {
          errorMessage = DashL10n.string(
            "Files couldn't remove all downloaded copies from this iPhone. Reopen Dash to try again."
          )
        }
        deferredDeletions.discardUnverifiedCredentialStatePreservingRecovery()
        authState = .unauthenticated
        return
      }
    } catch {
      deferredDeletions.discardUnverifiedCredentialStatePreservingRecovery()
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
      if outcome.state == .unauthenticated,
        !(await removeAllFileProviderDomains())
      {
        errorMessage = DashL10n.string(
          "Files couldn't remove all downloaded copies from this iPhone. Reopen Dash to try again."
        )
      }
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
      scheduleFileProviderDomainReconciliation()
    } catch {
      if (error as? CloudflareAPIError)?.isUnauthorized == true {
        await signOut()
      }
    }
  }

  func signIn(presentationOwner: UUID) {
    guard !isEnteringDemo else { return }
    authorize(
      scopes: DashAuthorizationScopes.core,
      preservesExistingSession: false,
      presentsCompletion: true,
      presentationOwner: presentationOwner
    )
  }

  func requestAccess(
    to scopes: Set<String>,
    presentsCompletion: Bool = false,
    presentationOwner: UUID? = nil
  ) {
    guard !scopes.isEmpty else { return }
    if isDemoSession {
      // The demo is intentionally read-only. A write CTA means "connect my
      // account", never "replace the demo client's token in place".
      guard Self.demoAccessRequiresConnection(scopes) else { return }
      Task { @MainActor [weak self] in
        guard let self else { return }
        await exitDemo()
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
    authorize(
      scopes: requested,
      preservesExistingSession: true,
      presentsCompletion: presentsCompletion,
      presentationOwner: presentationOwner
    )
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

  private func authorize(
    scopes: Set<String>,
    preservesExistingSession: Bool,
    presentsCompletion: Bool,
    presentationOwner: UUID?
  ) {
    guard !isAuthenticating, !isEnteringDemo else { return }
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
    cancelAuthenticationPresentationFallback()
    authenticationActionPhase = .loading
    authenticationActionOwner = presentsCompletion ? presentationOwner : nil
    grantedScopesPendingPresentation = nil
    errorMessage = nil
    let session = ASWebAuthenticationSession(
      url: authorizationURL, callbackURLScheme: configuration.callbackScheme
    ) { [weak self] url, error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
          isAuthenticating = false
          authenticationActionPhase = .idle
          authenticationActionOwner = nil
          return
        }
        guard error == nil, let url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
          isAuthenticating = false
          authenticationActionPhase = .idle
          authenticationActionOwner = nil
          errorMessage = error?.localizedDescription ?? "OAuth callback was invalid."
          return
        }
        let values = Dictionary(
          uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard values["state"] == state, let code = values["code"] else {
          isAuthenticating = false
          authenticationActionPhase = .idle
          authenticationActionOwner = nil
          errorMessage = values["error_description"] ?? values["error"] ?? "OAuth state mismatch."
          return
        }
        let previousScopes = grantedScopes
        let previousProfileID = user?.id
        let previousAccountIDs = Set(accounts.map(\.id))
        let previousTokens: TokenSet?
        do {
          if preservesExistingSession,
            let accessToken = try await tokenStore.getAccessToken()
          {
            previousTokens = TokenSet(
              accessToken: accessToken,
              refreshToken: try await tokenStore.getRefreshToken(),
              scope: previousScopes?.sorted().joined(separator: " ")
            )
          } else {
            previousTokens = nil
          }
        } catch {
          // If the old credential cannot be snapshotted completely, leave it
          // untouched instead of beginning a replacement we cannot roll back.
          isAuthenticating = false
          authenticationActionPhase = .idle
          authenticationActionOwner = nil
          errorMessage = error.localizedDescription
          return
        }
        var credentialReplacementPrepared = false
        do {
          let tokens = try await OAuth.exchangeCode(
            clientID: configuration.clientID, code: code, verifier: pkce.verifier,
            redirectURI: configuration.redirectURI, session: DashAPISession.shared
          )
          // Keep the old token installed until every already-started deletion
          // has finished or entered read-only reconciliation.
          await deferredDeletions.prepareForCredentialReplacement()
          credentialReplacementPrepared = true
          try await replaceStoredTokens(with: tokens)
          let granted =
            tokens.scope.map { Set($0.split(separator: " ").map(String.init)) }
            ?? requestedScopes
          try await tokenStore.setGrantedScopes(granted)
          if preservesExistingSession, presentsCompletion {
            // Keep the initiating permission action mounted through its success
            // swap; publishing the wider grant first removes that UI.
            grantedScopesPendingPresentation = granted
          } else {
            grantedScopes = granted
          }
          selectedScopes = granted
          resetAccountScopedWork()
          try await loadIdentity()
          if preservesExistingSession {
            // A legacy grant upgrade stays on the current screen so the user
            // can retry the action that led them to the consent sheet.
            if presentsCompletion {
              authenticationActionPhase = .succeeded
              armAuthenticationPresentationFallback()
            } else {
              isAuthenticating = false
              authenticationActionPhase = .idle
              authenticationActionOwner = nil
            }
          } else {
            // AppRoot holds the onboarding surface until the shared success
            // icon swap reports logical completion. First let the system
            // browser sheet finish dismissing so that swap remains visible.
            try? await Task.sleep(for: .milliseconds(280))
            authenticationActionPhase = .succeeded
            armAuthenticationPresentationFallback()
            authState = .authenticated
          }
        } catch {
          authenticationActionPhase = .idle
          authenticationActionOwner = nil
          grantedScopesPendingPresentation = nil
          let restoredPreviousCredential =
            await handleCredentialReplacementFailure(
              replacementPrepared: credentialReplacementPrepared,
              preservesExistingSession: preservesExistingSession,
              previousTokens: previousTokens,
              previousScopes: previousScopes,
              previousProfileID: previousProfileID,
              previousAccountIDs: previousAccountIDs)
          errorMessage = error.localizedDescription
          if !preservesExistingSession || !restoredPreviousCredential {
            if !(await removeAllFileProviderDomains()) {
              errorMessage = [
                error.localizedDescription,
                DashL10n.string(
                  "Files couldn't remove all downloaded copies from this iPhone. Reopen Dash to try again."
                ),
              ].joined(separator: "\n")
            }
            authState = .unauthenticated
          }
          isAuthenticating = false
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
        self.authenticationActionPhase = .idle
        self.authenticationActionOwner = nil
        self.errorMessage = "Could not start the sign-in session."
      }
    }
  }

  func completeAuthenticationActionPresentation(owner: UUID) {
    guard authenticationActionOwner == owner else { return }
    finalizeAuthenticationActionPresentation()
  }

  private func finalizeAuthenticationActionPresentation() {
    guard authenticationActionPhase == .succeeded else { return }
    cancelAuthenticationPresentationFallback()
    authenticationActionPhase = .idle
    authenticationActionOwner = nil
    isAuthenticating = false
    if let grantedScopesPendingPresentation {
      self.grantedScopesPendingPresentation = nil
      grantedScopes = grantedScopesPendingPresentation
    }
  }

  private func armAuthenticationPresentationFallback() {
    authenticationPresentationGeneration &+= 1
    let generation = authenticationPresentationGeneration
    authenticationPresentationFallbackTask?.cancel()
    authenticationPresentationFallbackTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: DashTheme.Motion.iconSwapFallbackDelay)
      guard
        let self,
        !Task.isCancelled,
        self.authenticationPresentationGeneration == generation,
        self.authenticationActionPhase == .succeeded
      else { return }
      self.finalizeAuthenticationActionPresentation()
    }
  }

  private func cancelAuthenticationPresentationFallback() {
    authenticationPresentationGeneration &+= 1
    authenticationPresentationFallbackTask?.cancel()
    authenticationPresentationFallbackTask = nil
  }

  private func replaceStoredTokens(with tokens: TokenSet) async throws {
    // `TokenStore.setTokens` intentionally preserves a refresh token omitted
    // by a normal refresh response. An OAuth identity replacement is
    // different: clear first so fields from two people can never be mixed.
    try await tokenStore.clear()
    try await tokenStore.setTokens(tokens)
  }

  @discardableResult
  func handleCredentialReplacementFailure(
    replacementPrepared: Bool,
    preservesExistingSession: Bool,
    previousTokens: TokenSet?,
    previousScopes: Set<String>?,
    previousProfileID: String?,
    previousAccountIDs: Set<String>
  ) async -> Bool {
    guard replacementPrepared else {
      // Code exchange failed before any token/coordinator mutation. The
      // existing session and recovery journal must remain untouched.
      return preservesExistingSession
    }
    if let previousTokens {
      return await restoreCredentialAfterFailedReplacement(
        previousTokens: previousTokens,
        previousScopes: previousScopes,
        previousProfileID: previousProfileID,
        previousAccountIDs: previousAccountIDs)
    }
    try? await tokenStore.clear()
    deferredDeletions.discardUnverifiedCredentialStatePreservingRecovery()
    return false
  }

  @discardableResult
  func restoreCredentialAfterFailedReplacement(
    previousTokens: TokenSet,
    previousScopes: Set<String>?,
    previousProfileID: String?,
    previousAccountIDs: Set<String>
  ) async -> Bool {
    do {
      try await replaceStoredTokens(with: previousTokens)
      if let previousScopes {
        try await tokenStore.setGrantedScopes(previousScopes)
      }
      grantedScopes = previousScopes
      selectedScopes = previousScopes ?? selectedScopes
      guard let previousProfileID else {
        deferredDeletions.discardUnverifiedCredentialStatePreservingRecovery()
        return false
      }
      deferredDeletions.activateCredential(
        profileID: previousProfileID,
        availableAccountIDs: previousAccountIDs)
      return true
    } catch {
      // The keychain may now contain no credential or only part of one.
      // Never bind coordinator work to a guessed identity in that state.
      try? await tokenStore.clear()
      deferredDeletions.discardUnverifiedCredentialStatePreservingRecovery()
      return false
    }
  }

  /// Enters the read-only demo session: swaps the client for one served
  /// entirely by `DemoBackend`, then runs the normal identity path so the
  /// demo exercises the same code as a real sign-in.
  func enterDemo() {
    guard
      authState == .unauthenticated,
      !isDemoSession,
      !isEnteringDemo,
      !isAuthenticating
    else { return }
    isEnteringDemo = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.isEnteringDemo = false }

      // A failed automatic credential cleanup can leave a known real-account
      // domain mounted while onboarding is visible. Demo must never coexist
      // with that replica: its in-process backend cannot serve the extension,
      // and downloaded real-account data would remain visible in Files.
      if !FileProviderDomains.mirroredAccountIDs().isEmpty,
        !(await self.removeAllFileProviderDomains())
      {
        let message = DashL10n.string(
          "Files couldn't remove all downloaded copies from this iPhone. Reopen Dash to try again."
        )
        self.errorMessage = message
        self.toasts.error(message)
        return
      }

      guard
        self.authState == .unauthenticated,
        !self.isDemoSession,
        !self.isAuthenticating
      else { return }
      self.toasts.clearAll()
      self.resetAccountScopedWork()
      self.pendingLegacyNotificationRoute = nil
      self.isDemoSession = true
      self.errorMessage = nil
      let demoClient = CloudflareClient(
        clientID: "demo", tokenStore: DemoTokenStore(), session: DemoBackend.session)
      self.client = demoClient
      self.deferredDeletionExecutor.replaceClient(demoClient)
      self.grantedScopes = Self.demoGrantedScopes

      do {
        try await self.loadIdentity()
        guard self.isDemoSession else { return }
        self.authState = .authenticated
      } catch {
        guard self.isDemoSession else { return }
        await self.exitDemo()
        self.errorMessage = error.localizedDescription
        self.toasts.error(error.localizedDescription)
      }
    }
  }

  /// Tears down the demo session: restores the real client and returns to
  /// onboarding. No keychain, push, or revocation work — the demo never
  /// touched any of it.
  private func exitDemo(setsAuthenticationState: Bool = true) async {
    let pendingFileProviderReconcile = fileProviderReconcileTask
    fileProviderReconcileTask?.cancel()
    await pendingFileProviderReconcile?.value
    _ = await removeAllFileProviderDomains()
    deferredDeletions.discardEphemeralCredentialStatePreservingRecovery()
    resetAccountScopedWork()
    isDemoSession = false
    let authenticatedClient = CloudflareClient(
      clientID: configuration.clientID, tokenStore: tokenStore, session: authenticatedSession)
    client = authenticatedClient
    deferredDeletionExecutor.replaceClient(authenticatedClient)
    avatars.clearMemory()
    Task { await r2Thumbnails.clear() }
    accounts = []
    user = nil
    activeAccountID = nil
    grantedScopes = nil
    grantedScopesPendingPresentation = nil
    selectedScopes = DashAuthorizationScopes.core
    identityStale = false
    watchtowerUnreadAlertCount = nil
    pendingRoute = nil
    pendingHomeAction = nil
    pendingLegacyNotificationRoute = nil
    WatchtowerNotificationBaselineStore.clearAll()
    MetricsWidgetPublisher.clear()
    toasts.clearAll()
    UserDefaults.standard.removeObject(forKey: DashAppGroup.activeAccountKey)
    R2ShareDestination.clear()
    if setsAuthenticationState {
      authState = .unauthenticated
    }
  }

  func signOut(presentsCompletion: Bool = false) async {
    if isDemoSession {
      cancelSignOutPresentationFallback()
      signOutActionPhase = presentsCompletion ? .loading : .idle
      await exitDemo(setsAuthenticationState: !presentsCompletion)
      await Task.yield()
      await R2TemporaryFile.removeAllFiles()
      if presentsCompletion {
        signOutActionPhase = .succeeded
        armSignOutPresentationFallback()
        authState = .unauthenticated
      }
      return
    }
    guard !isSigningOut else { return }
    cancelSignOutPresentationFallback()
    isSigningOut = true
    signOutActionPhase = presentsCompletion ? .loading : .idle
    defer { isSigningOut = false }
    isAuthenticating = false
    cancelAuthenticationPresentationFallback()
    authenticationActionPhase = .idle
    authenticationActionOwner = nil
    grantedScopesPendingPresentation = nil

    // Removing a replicated domain is the only sign-out cleanup that owns
    // downloaded account data on this device. Do it before mutating any other
    // session state so a system IPC failure leaves Dash truthfully signed in
    // and lets the user retry instead of creating a half-signed-out replica.
    fileProviderReconcileGeneration &+= 1
    let pendingFileProviderReconcile = fileProviderReconcileTask
    fileProviderReconcileTask?.cancel()
    fileProviderReconcileTask = nil
    await pendingFileProviderReconcile?.value
    guard await removeAllFileProviderDomains() else {
      signOutActionPhase = .idle
      let message = DashL10n.string(
        "Files couldn't remove all downloaded copies from this iPhone. Try signing out again."
      )
      errorMessage = message
      toasts.error(message)
      return
    }

    // This handshake runs before token revocation so an in-flight DELETE never
    // resumes under a replacement credential.
    await deferredDeletions.prepareForCredentialReplacement()
    let pushAccountIDs = Set(accounts.map(\.id))
      .union(PushRegistrationService.enabledAccountIDs())
      .union(PushRegistrationService.pendingCleanupAccountIDs())
    // Invalidate user-started enable work before it can mint/store a webhook
    // after our initial enabled-id snapshot. Each disable below then waits on
    // the same per-account lock, so revocation cannot overtake remote cleanup.
    PushRegistrationService.prepareForSignOut(accountIDs: pushAccountIDs)
    let pendingPushReconcile = pushReconcileTask
    resetAccountScopedWork()
    activeAccountID = nil
    // Close the Lock Screen disclosure boundary immediately. Remote webhook
    // cleanup is best-effort and can outlive this local sign-out.
    NotificationAccountAuthorizationStore.clear()
    MetricsWidgetPublisher.clear()
    await pendingPushReconcile?.value

    // Push webhooks live in the user's Cloudflare accounts — delete them
    // before revoking the token, or the client can no longer authenticate.
    var pushCleanupFailureCount = 0
    for accountID in pushAccountIDs.sorted() {
      do {
        try await PushRegistrationService.disable(accountID: accountID, client: client)
      } catch {
        pushCleanupFailureCount += 1
      }
    }
    UIApplication.shared.unregisterForRemoteNotifications()
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
    deferredDeletions.discardCredentialState()
    avatars.clearMemory()
    await r2Thumbnails.clear()
    accounts = []
    user = nil
    grantedScopes = nil
    selectedScopes = DashAuthorizationScopes.core
    identityStale = false
    watchtowerUnreadAlertCount = nil
    pendingRoute = nil
    pendingHomeAction = nil
    pendingLegacyNotificationRoute = nil
    pendingDeviceToken = nil
    WatchtowerNotificationBaselineStore.clearAll()
    WatchtowerRemoteRefreshInvalidationStore.clearAll()
    toasts.clearAll()
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundRefreshID)

    UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    clearWatchtowerWidgetSnapshot()
    MetricsWidgetPublisher.clear()
    UserDefaults.standard.removeObject(forKey: DashAppGroup.activeAccountKey)
    R2ShareDestination.clear()
    if presentsCompletion {
      signOutActionPhase = .succeeded
      armSignOutPresentationFallback()
    }
    authState = .unauthenticated
    var cleanupMessages: [String] = []
    if pushCleanupFailureCount > 0 {
      cleanupMessages.append(
        "\(DashL10n.string("Push alerts")): \(DashL10n.string("Cloudflare couldn’t complete this request. Try again."))"
      )
    }
    errorMessage = cleanupMessages.isEmpty ? nil : cleanupMessages.joined(separator: "\n")
    // Let SwiftUI tear down account-scoped views and cancel their transfers
    // before removing the session's temporary R2 files.
    await Task.yield()
    await R2TemporaryFile.removeAllFiles()
  }

  func completeSignOutActionPresentation() {
    guard signOutActionPhase == .succeeded else { return }
    cancelSignOutPresentationFallback()
    signOutActionPhase = .idle
  }

  private func armSignOutPresentationFallback() {
    signOutPresentationGeneration &+= 1
    let generation = signOutPresentationGeneration
    signOutPresentationFallbackTask?.cancel()
    signOutPresentationFallbackTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: DashTheme.Motion.iconSwapFallbackDelay)
      guard
        let self,
        !Task.isCancelled,
        self.signOutPresentationGeneration == generation,
        self.signOutActionPhase == .succeeded
      else { return }
      self.completeSignOutActionPresentation()
    }
  }

  private func cancelSignOutPresentationFallback() {
    signOutPresentationGeneration &+= 1
    signOutPresentationFallbackTask?.cancel()
    signOutPresentationFallbackTask = nil
  }

  func selectAccount(_ account: CloudflareAccount) {
    guard activeAccountID != account.id else { return }
    deferredDeletions.cancelPendingOperations(forAccountID: activeAccountID)
    resetAccountScopedWork()
    Task { await r2Thumbnails.clear() }
    watchtowerUnreadAlertCount = nil
    toasts.clearAll()
    activeAccountID = account.id
    UserDefaults.standard.set(account.id, forKey: DashAppGroup.activeAccountKey)
    // Domains are account-scoped, not active-account-scoped. Reconciliation
    // only subtracts accounts that no longer exist and never unmounts the
    // other authenticated accounts when this selection changes.
    scheduleFileProviderDomainReconciliation()
  }

  /// Drops caches that embed already-resolved copy so Settings → Language can
  /// rebuild Watchtower (and similar) strings without a process restart.
  func discardLocalizedCaches() {
    featureCache.remove(prefix: "watchtower:")
    deferredDeletions.refreshLocalizedPresentation()
    toasts.clearAll(preserving: .deferredDeletionBatch)
  }

  /// Single entry point for Watchtower data: serves the cached snapshot when
  /// fresh, joins an in-flight refresh for the same account instead of
  /// doubling the fan-out, and keeps the tab-badge count in sync.
  func watchtowerSnapshot(
    force: Bool = false,
    source: WatchtowerRefreshSource = .foreground
  ) async -> WatchtowerSnapshot? {
    guard let context = accountRequestContext else { return nil }
    let key = FeatureCacheKey.watchtower(context.accountID)
    let observedRemoteGeneration = WatchtowerRemoteRefreshInvalidationStore.generation(
      accountID: context.accountID)
    let pendingRemoteGeneration = WatchtowerRemoteRefreshInvalidationStore.pendingGeneration(
      accountID: context.accountID)
    if !force, pendingRemoteGeneration == nil,
      let cached: WatchtowerSnapshot = featureCache.get(key)
    {
      syncWatchtowerInboxBadge(from: cached, accountID: context.accountID)
      return cached
    }
    let effectiveSource: WatchtowerRefreshSource =
      pendingRemoteGeneration == nil ? source : .remoteNotification
    let loadKey =
      pendingRemoteGeneration.map { "\(key):remote:\($0)" }
      ?? key
    let client = client
    let snapshot: WatchtowerSnapshot
    do {
      snapshot = try await featureCache.coalescedLoad(loadKey) {
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
    let currentRemoteGeneration = WatchtowerRemoteRefreshInvalidationStore.generation(
      accountID: context.accountID)
    // A request that began before a silent push, or before a newer push, must
    // never commit its older page or clear the newer invalidation.
    guard currentRemoteGeneration == observedRemoteGeneration else {
      return featureCache.get(key)
    }
    if let committed: WatchtowerSnapshot = featureCache.get(key),
      committed.fetchedAt >= snapshot.fetchedAt
    {
      return committed
    }
    featureCache.set(key, snapshot, ttl: nil)
    syncWatchtowerInboxBadge(from: snapshot, accountID: context.accountID)
    publishWidgetSnapshot(
      snapshot,
      accountID: context.accountID,
      notifiesLocally: WatchtowerRemoteRefreshInvalidationStore.allowsLocalNotifications(
        source: effectiveSource,
        accountID: context.accountID))
    if let pendingRemoteGeneration {
      WatchtowerRemoteRefreshInvalidationStore.clear(
        accountID: context.accountID,
        matching: pendingRemoteGeneration)
    }
    return snapshot
  }

  /// Recomputes the shared tab/inbox badge from the cached snapshot + local ignores.
  func refreshWatchtowerInboxBadge() {
    guard let accountID = activeAccountID else {
      watchtowerUnreadAlertCount = nil
      setSystemBadgeCount(0)
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
    let unreadCount = WatchtowerInboxStore.unreadCount(
      accountID: accountID,
      alerts: snapshot.alertsStatus == .ok ? snapshot.alerts : []
    )
    watchtowerUnreadAlertCount = unreadCount
    setSystemBadgeCount(unreadCount)
  }

  /// SpringBoard has one badge, so the app-owned Watchtower count is its only
  /// writer. The Notification Service Extension deliberately never guesses
  /// `snapshot + 1`: visible and silent pushes can arrive in either order, and
  /// an extension may be processing a different account.
  ///
  /// Writes are chained and obsolete queued values are skipped. This prevents
  /// an older asynchronous `setBadgeCount` completion from landing after a
  /// newer read/ignore/refresh transition.
  private func setSystemBadgeCount(_ count: Int) {
    systemBadgeGeneration &+= 1
    let generation = systemBadgeGeneration
    let normalizedCount = max(0, count)
    let previous = systemBadgeTask
    systemBadgeTask = Task { @MainActor [weak self] in
      _ = await previous?.result
      guard let self, self.systemBadgeGeneration == generation else { return }
      try? await UNUserNotificationCenter.current().setBadgeCount(normalizedCount)
    }
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

  /// Ends the undo window synchronously and asks iOS for the short amount of
  /// execution time needed to finish DELETE or persist its uncertain outcome.
  func commitDeferredDeletionsForBackground() {
    let leaseGeneration = deferredDeletionBackgroundLease.replace { expirationHandler in
      UIApplication.shared.beginBackgroundTask(
        withName: "Deferred deletion",
        expirationHandler: expirationHandler)
    }
    deferredDeletions.commitPendingOperations()
    Task { @MainActor [weak self] in
      guard let self else { return }
      await deferredDeletions.waitForActiveWork()
      deferredDeletionBackgroundLease.end(generation: leaseGeneration)
    }
  }

  /// Runs from the BGAppRefresh handler: refresh if stale (which republishes
  /// the snapshot and notifies through the shared choke point), then reschedule.
  func performBackgroundWatchtowerRefresh() async {
    guard (try? await tokenStore.getAccessToken()) != nil else { return }
    await refreshWatchtowerIfStale(source: .background)
    scheduleWatchtowerBackgroundRefresh()
  }

  /// Foreground/warm-up hook: cheap when the snapshot is younger than the
  /// TTL, otherwise re-runs the checks in the background.
  func refreshWatchtowerIfStale(source: WatchtowerRefreshSource = .foreground) async {
    guard let accountID = activeAccountID else { return }
    let wasRemotelyInvalidated = WatchtowerRemoteRefreshInvalidationStore.contains(
      accountID: accountID)
    if let cached: WatchtowerSnapshot = featureCache.get(FeatureCacheKey.watchtower(accountID)) {
      syncWatchtowerInboxBadge(from: cached, accountID: accountID)
      guard wasRemotelyInvalidated || cached.isStale(ttl: Self.watchtowerTTL) else { return }
    }
    _ = await watchtowerSnapshot(
      force: true,
      source: wasRemotelyInvalidated ? .remoteNotification : source)
  }

  func loadIdentity() async throws {
    let loadGeneration = accountGeneration
    let preferredAccountID = activeAccountID
    async let fetchedUser = client.getUser()
    async let fetchedAccounts = client.listAccounts()
    var identity = try await (fetchedUser, fetchedAccounts)
    var definitivelyUnavailableAccountIDs: Set<String> = []
    if let preferredAccountID,
      !identity.1.contains(where: { $0.id == preferredAccountID })
    {
      do {
        // Page-number APIs can drift while membership changes, and the lossy
        // list decoder may skip one malformed row. Confirm the persisted
        // account directly before replacing the user's selection.
        let preferredAccount = try await client.getAccount(preferredAccountID)
        identity.1.append(preferredAccount)
      } catch let error as CloudflareAPIError {
        guard case .request(let status, _) = error, status == 403 || status == 404 else {
          throw error
        }
        definitivelyUnavailableAccountIDs.insert(preferredAccountID)
      }
    }
    var availableAccountIDs = Set(identity.1.map(\.id))
    let missingRecoveryAccountIDs =
      deferredDeletions
      .recoveryAccountIDs(forCredentialProfileID: identity.0.id)
      .subtracting(availableAccountIDs)
      .subtracting(definitivelyUnavailableAccountIDs)
    for accountID in missingRecoveryAccountIDs.sorted() {
      do {
        let recoveredAccount = try await client.getAccount(accountID)
        identity.1.append(recoveredAccount)
        availableAccountIDs.insert(accountID)
      } catch let error as CloudflareAPIError {
        if case .request(let status, _) = error, status == 403 || status == 404 {
          definitivelyUnavailableAccountIDs.insert(accountID)
        } else {
          // A transient direct lookup is not proof that membership vanished.
          // Keep recovery frozen to this identity and let read-only
          // reconciliation retry instead of deleting its journal.
          availableAccountIDs.insert(accountID)
        }
      } catch {
        availableAccountIDs.insert(accountID)
      }
    }
    try Task.checkCancellation()
    guard accountGeneration == loadGeneration, !isSigningOut else {
      throw CancellationError()
    }
    user = identity.0
    accounts = identity.1
    // Only a direct 403/404 above proves the saved account is unavailable.
    if activeAccount == nil, let first = accounts.first { selectAccount(first) }
    if isDemoSession {
      deferredDeletions.activateEphemeralCredential(
        profileID: identity.0.id,
        availableAccountIDs: availableAccountIDs)
    } else {
      deferredDeletions.activateCredential(
        profileID: identity.0.id,
        availableAccountIDs: availableAccountIDs)
    }
    resolvePendingLegacyNotificationRoute()
    await retryPendingPushCleanups(expectedGeneration: accountGeneration)
  }

  private func retryPendingPushCleanups(expectedGeneration: UInt64) async {
    guard accountGeneration == expectedGeneration, !isSigningOut else { return }
    let available = Set(accounts.map(\.id))
    let pending = PushRegistrationService.pendingCleanupAccountIDs()
      .filter(available.contains)
    guard !pending.isEmpty else { return }
    var failures = 0
    for accountID in pending {
      guard accountGeneration == expectedGeneration, !isSigningOut else { return }
      do {
        try await PushRegistrationService.disable(accountID: accountID, client: client)
      } catch {
        guard accountGeneration == expectedGeneration, !isSigningOut else { return }
        failures += 1
      }
    }
    if failures > 0, accountGeneration == expectedGeneration, !isSigningOut {
      toasts.warning(
        "\(DashL10n.string("Push alerts")): \(DashL10n.string("Cloudflare couldn’t complete this request. Try again."))"
      )
    }
  }
}

extension AppModel: PushTokenInbox {
  /// Woken by the relay's silent push. Forces a Watchtower reload — the TTL
  /// says the snapshot is fresh, but a delivery just landed, so it isn't — and
  /// suppresses the local-notification diff so the user is told once, by the
  /// alert push that arrived alongside this one.
  func performPushTriggeredRefresh(accountID: String) async -> Bool {
    guard !isDemoSession,
      NotificationAccountAuthorizationStore.contains(accountID)
    else { return false }
    WatchtowerRemoteRefreshInvalidationStore.mark(accountID: accountID)
    guard accountRequestContext?.accountID == accountID else {
      // Do not query through another account's mounted UI state. The durable
      // dirty bit forces a source-aware refresh as soon as this account opens.
      return true
    }
    return await watchtowerSnapshot(force: true, source: .remoteNotification) != nil
  }

  func receivePushRegistrationChallenge(
    _ challenge: PushRegistrationChallenge
  ) async -> Bool {
    await PushRegistrationChallengeInbox.shared.receive(challenge)
  }

  func receiveDeviceToken(_ token: Data) {
    let hex = PushRegistration.hexToken(from: token)
    pendingDeviceToken = hex
    guard !isDemoSession else { return }
    guard hasScopes(["notifications.write"]) else { return }
    let accountIDs = PushRegistrationService.reconcilableAccountIDs()
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
