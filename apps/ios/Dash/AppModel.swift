import AuthenticationServices
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

private enum MetricsWidgetSessionLifecycleError: Error, LocalizedError, Sendable {
  case transitionFailed

  var errorDescription: String? {
    DashL10n.string("Cloudflare couldn’t complete this request. Try again.")
  }
}

private enum OAuthCredentialReplacement: Sendable {
  case keychain(KeychainCredentialReplacement)
  /// Non-Keychain stores are process-local test/demo implementations. Their
  /// protocol fallback can safely use the pre-mutation snapshot.
  case protocolStore(previousCredential: TokenSet?)
}

/// Once sign-out atomically removes the shared Keychain credential, remote
/// webhook cleanup still gets one best-effort chance. This detached store can
/// rotate the captured refresh token without ever republishing it to Widget,
/// Share, Files, or the app's normal client.
private actor SignOutCleanupTokenStore: TokenStore {
  private var accessToken: String?
  private var refreshToken: String?
  private var scopes: Set<String>?

  init(accessToken: String?, refreshToken: String?, scopes: Set<String>?) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.scopes = scopes
  }

  func clear() {
    accessToken = nil
    refreshToken = nil
    scopes = nil
  }

  func getAccessToken() -> String? { accessToken }
  func getRefreshToken() -> String? { refreshToken }
  func getGrantedScopes() -> Set<String>? { scopes }
  func setGrantedScopes(_ scopes: Set<String>) { self.scopes = scopes }

  func setTokens(_ tokens: TokenSet) {
    if let refreshToken = tokens.refreshToken { self.refreshToken = refreshToken }
    if let scope = tokens.scope {
      scopes = Set(scope.split(separator: " ").map(String.init))
    }
    accessToken = tokens.accessToken
  }

  func replaceTokens(
    _ tokens: TokenSet,
    ifCurrentAccessToken expectedAccessToken: String?,
    refreshToken expectedRefreshToken: String?
  ) -> Bool {
    guard
      accessToken == expectedAccessToken,
      refreshToken == expectedRefreshToken
    else { return false }
    setTokens(tokens)
    return true
  }

  func clearTokens(
    ifCurrentAccessToken expectedAccessToken: String?,
    refreshToken expectedRefreshToken: String?
  ) -> Bool {
    guard
      accessToken == expectedAccessToken,
      refreshToken == expectedRefreshToken
    else { return false }
    clear()
    return true
  }
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
  /// Demo keeps every core surface browsable, plus experimental feature reads
  /// so opting into one can explore its DemoBackend data without a fake
  /// "Connect your account" wall.
  static let demoGrantedScopes: Set<String> = {
    let experimentalReads = DashAuthorizationScopes.experimentalFeatures.reduce(
      into: Set<String>()
    ) {
      $0.formUnion(DashAuthorizationScopes.authorizationScopes(for: $1))
    }
    return DashAuthorizationScopes.initialReadOnly.union(experimentalReads)
  }()

  let configuration: AppConfiguration
  let tokenStore: any TokenStore
  /// Swapped for a `DemoBackend`-served client while the demo session runs;
  /// every consumer reads it per-call, so the swap takes effect everywhere.
  private(set) var client: CloudflareClient
  /// True while the read-only demo session is active (App Review's path past
  /// the OAuth wall). Sign-out becomes a lightweight demo exit.
  private(set) var isDemoSession = false
  private(set) var isEnteringDemo = false
  let featureCache: FeatureDataCache
  let avatars = AvatarStore()
  let r2Thumbnails = R2ThumbnailStore()
  /// Top-of-screen action feedback. Prefer this over sticky inline notices for
  /// completed / failed mutations; keep `DashNotice` for persistent state.
  let toasts = DashToastCenter()
  let optimistic: DashOptimisticOperationCenter
  let deferredDeletions: DeferredDeletionCoordinator
  var accounts: [CloudflareAccount] = [] {
    didSet {
      MetricsWidgetPublisher.syncAccounts(accounts, activeAccountID: activeAccountID)
      syncNotificationAccountAuthorization()
      scheduleFileProviderDomainReconciliation()
      scheduleDefaultPushRegistration()
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
      featureCache.setPersistenceAccount(activeAccountID)
    }
  }
  var authState: AuthenticationState = .loading {
    didSet {
      syncNotificationAccountAuthorization()
      if authState == .unauthenticated {
        clearWatchtowerWidgetSnapshot()
      } else if authState == .authenticated {
        scheduleFileProviderDomainReconciliation()
        scheduleDefaultPushRegistration()
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
  var grantedScopes: Set<String>? {
    didSet {
      // Permission upgrades publish their wider grant only after the success
      // presentation completes. Reconcile then as well as on account/auth
      // changes, otherwise a legacy read-only session never reaches default
      // webhook setup without revisiting Settings.
      scheduleDefaultPushRegistration()
    }
  }
  var selectedScopes: Set<String>
  var user: CloudflareUser?
  /// True while the session is trusted but the identity fetch failed
  /// (offline, Cloudflare outage). Cleared by the next successful retry.
  var identityStale = false {
    didSet {
      // A successful in-place identity retry keeps `authState` authenticated,
      // so no auth-state observer fires to resume deferred webhook setup.
      if !identityStale {
        scheduleDefaultPushRegistration()
      }
    }
  }
  /// Set only when an OAuth replacement could neither restore the prior
  /// credential nor conclusively clear the new one. Until Cloudflare identity
  /// succeeds, the in-memory account catalog must not be paired with that
  /// unverified shared credential.
  private var requiresVerifiedIdentityBeforeAuthentication = false
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
  /// Every OAuth browser hand-off owns one generation. Signing out advances
  /// it before waiting for the callback, so a late code exchange can never
  /// reinstall a credential after the local sign-out commit.
  private var authenticationAttemptGeneration: UInt64 = 0
  /// The callback task cannot be cancelled reliably once URLSession or
  /// Keychain work is in flight. Sign-out therefore invalidates its generation
  /// and waits for it to cross the next guarded suspension point before
  /// clearing the shared credential.
  private var activeAuthenticationCallbackGeneration: UInt64?
  private var authenticationCallbackOwnsCredentialMutation = false
  private var authenticationCallbackWaiters: [CheckedContinuation<Void, Never>] = []
  private var pushReconcileTask: Task<Void, Never>?
  private var pushReconcileGeneration: UInt64 = 0
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
    deferredDeletionPersistence: UserDefaults? = .standard,
    featureCachePersistence: FeatureCachePersistence? = nil
  ) {
    self.configuration = configuration
    featureCache = FeatureDataCache(persistence: featureCachePersistence)
    selectedScopes = DashAuthorizationScopes.core
    self.tokenStore = tokenStore
    authenticatedSession = session
    optimistic = DashOptimisticOperationCenter(toasts: toasts)
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
    featureCache.setPersistenceAccount(activeAccountID)
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
    case .undoOptimistic(let operationID):
      optimistic.undo(rawID: operationID)
    }
  }

  var accountRequestContext: AccountRequestContext? {
    guard let activeAccountID else { return nil }
    return AccountRequestContext(accountID: activeAccountID, generation: accountGeneration)
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
    pushReconcileGeneration &+= 1
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
  /// account set. Every authenticated account is mounted in Files, so this
  /// background pass both adds the missing domains and removes the ones whose
  /// account no longer exists — running it on a partial account list would
  /// unmount a live account and drop its downloaded replica.
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

  /// Cloudflare notifications have one delivery path: a per-device webhook in
  /// each real account. Provisioning is asynchronous and best-effort so sign-in
  /// never waits on APNs, plan eligibility, or an account's policy catalog.
  private func scheduleDefaultPushRegistration(onlyUnready: Bool = false) {
    pushReconcileGeneration &+= 1
    let generation = pushReconcileGeneration
    pushReconcileTask?.cancel()
    pushReconcileTask = nil
    guard PushRegistrationService.shouldAutomaticallyProvisionForCurrentProcess,
      authState == .authenticated,
      !identityStale,
      !isDemoSession,
      !isSigningOut,
      configuration.pushBaseURL != nil,
      hasScopes(PushRegistrationService.requiredScopes),
      !accounts.isEmpty
    else { return }

    // A cleanup tombstone represents an older webhook that still needs remote
    // deletion. Never recreate delivery for that account until teardown has
    // settled; `loadIdentity` schedules again immediately after a successful
    // cleanup pass.
    let pendingCleanup = Set(PushRegistrationService.pendingCleanupAccountIDs())
    let accountIDs = accounts.map(\.id).filter { accountID in
      !pendingCleanup.contains(accountID)
        && (!onlyUnready || !PushRegistrationService.isReady(accountID: accountID))
    }
    guard !accountIDs.isEmpty else { return }

    let expectedAccountGeneration = accountGeneration
    pushReconcileTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.pushReconcileGeneration == generation {
          self.pushReconcileTask = nil
        }
      }
      guard await DashNotificationSupport.requestAuthorization() else { return }
      guard !Task.isCancelled, self.pushReconcileGeneration == generation,
        self.accountGeneration == expectedAccountGeneration,
        let token = await PushRegistrationService.waitForDeviceToken(in: self)
      else { return }

      for accountID in accountIDs {
        guard !Task.isCancelled, self.pushReconcileGeneration == generation,
          self.accountGeneration == expectedAccountGeneration,
          !self.isDemoSession,
          !self.isSigningOut
        else { return }
        do {
          try await PushRegistrationService.ensureEnabled(
            accountID: accountID,
            client: self.client,
            configuration: self.configuration,
            deviceToken: token)
        } catch is CancellationError {
          return
        } catch {
          // Some accounts cannot create notification webhooks on their current
          // plan. Keep the inbox available and retry on a later identity/token
          // reconciliation without turning setup into a sign-in failure.
        }
      }
    }
  }

  /// Foreground re-entry retries only accounts whose automatic destination
  /// setup has not completed. A ready account does not exchange another relay
  /// challenge merely because the user briefly backgrounded the app.
  func retryDefaultPushRegistrationIfNeeded() {
    guard
      accounts.contains(where: {
        !PushRegistrationService.isReady(accountID: $0.id)
      })
    else { return }
    scheduleDefaultPushRegistration(onlyUnready: true)
  }

  /// Settings uses the same idempotent path to await setup for the active
  /// account and surface an actionable error instead of owning another toggle.
  func ensureDefaultPushRegistration(for context: AccountRequestContext) async throws {
    guard !isDemoSession, !isSigningOut, isCurrentAccount(context) else {
      throw CancellationError()
    }
    guard configuration.pushBaseURL != nil else {
      throw PushRegistrationError.pushNotConfigured
    }
    guard hasScopes(PushRegistrationService.requiredScopes) else {
      throw PushRegistrationError.authorizationRequired
    }
    guard await DashNotificationSupport.requestAuthorization() else {
      throw PushRegistrationError.notificationsDisabled
    }
    guard let token = await PushRegistrationService.waitForDeviceToken(in: self) else {
      throw PushRegistrationError.missingDeviceToken
    }
    guard !Task.isCancelled, isCurrentAccount(context), !isSigningOut else {
      throw CancellationError()
    }
    try await PushRegistrationService.ensureEnabled(
      accountID: context.accountID,
      client: client,
      configuration: configuration,
      deviceToken: token)
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
            WatchtowerInboxStore.readKey, LegacyWatchtowerNotificationSettings.baselinesKey,
            LegacyWatchtowerNotificationSettings.optInKey, DashWorkspaceWashPreset.storageKey,
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
        if let previewAccounts = try? JSONDecoder().decode(
          [CloudflareAccount].self,
          from: Data(
            """
            [
              {"id":"ui-account","name":"Demo Workspace","type":"standard"},
              {"id":"demo-account-studio","name":"Foxglove Studio","type":"standard"},
              {"id":"demo-account-side","name":"Side Projects","type":"standard"}
            ]
            """.utf8))
        {
          accounts = previewAccounts
        }
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
        // Registrar has no URLProtocol preview backend. Seed the merged index
        // itself so its UI test never falls through to a simulator credential
        // or a live Cloudflare request.
        let previewRegistrarDomain = RegistrarDomainSummary(
          name: "example.com",
          status: "active",
          expiresAt: "2027-07-16T00:00:00Z",
          createdAt: "2024-07-16T00:00:00Z",
          autoRenew: true,
          locked: true,
          privacyMode: "redacted",
          currentRegistrar: "Cloudflare")
        featureCache.set(
          FeatureCacheKey.registrarDomains("ui-account"),
          RegistrarAccountIndex(
            domains: [previewRegistrarDomain],
            registrations: .value([previewRegistrarDomain]),
            legacy: .value([previewRegistrarDomain])))
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
              {"id":"http3","value":"on","editable":true},
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

    // A retry from the launch failure surface re-enters the complete boundary
    // check; never carry the previous attempt's diagnostic into a success.
    errorMessage = nil
    do {
      guard try await tokenStore.getAccessToken() != nil else {
        // A successful Keychain read with no access token is a definitive
        // credential boundary. Invalidate any Widget request that started for
        // the previous session before onboarding is shown.
        guard await prepareForUnauthenticatedPresentation() else { return }
        requiresVerifiedIdentityBeforeAuthentication = false
        authState = .unauthenticated
        return
      }
    } catch {
      // A Keychain read error is not proof that no shared credential exists.
      // Keep the launch boundary closed and let the user retry.
      appendErrorMessage(error.localizedDescription)
      return
    }
    // Older installs can have a valid token without a scope mirror. Unknown is
    // not equivalent to the latest read-only profile: claiming otherwise can
    // suppress OAuth even when the server rejects a newly added read endpoint.
    grantedScopes = try? await tokenStore.getGrantedScopes()
    selectedScopes = DashAuthorizationScopes.core
    do {
      try await loadIdentity()
      identityStale = false
      requiresVerifiedIdentityBeforeAuthentication = false
      activateRemoteMetricsWidgetSession()
      authState = .authenticated
    } catch {
      let outcome = Self.authOutcome(afterIdentityError: error)
      identityStale = outcome.stale
      if outcome.state == .authenticated,
        requiresVerifiedIdentityBeforeAuthentication
      {
        appendErrorMessage(error.localizedDescription)
        authState = .loading
        return
      }
      if outcome.state == .unauthenticated {
        // Only a 401 reaches this branch. Transient Keychain, network, and
        // service failures deliberately retain the Widget's last-good data.
        guard await prepareForUnauthenticatedPresentation() else {
          authState = .loading
          return
        }
        requiresVerifiedIdentityBeforeAuthentication = false
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
      activateRemoteMetricsWidgetSession()
      identityStale = false
      requiresVerifiedIdentityBeforeAuthentication = false
      scheduleFileProviderDomainReconciliation()
    } catch {
      if (error as? CloudflareAPIError)?.isUnauthorized == true {
        do {
          try invalidateMetricsWidgetSession()
        } catch {
          errorMessage = error.localizedDescription
          toasts.error(error.localizedDescription)
          return
        }
        await signOut(metricsWidgetSessionAlreadyInvalidated: true)
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
        guard await exitDemo() else { return }
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

  /// Real-account authorization is one-shot: every OAuth request asks for the
  /// complete set used by Dash's current features. Any already-granted scopes
  /// outside that set are kept so a reauthorization never narrows the token.
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

  private func beginAuthenticationAttempt() -> UInt64 {
    authenticationAttemptGeneration &+= 1
    return authenticationAttemptGeneration
  }

  private func isCurrentAuthenticationAttempt(_ generation: UInt64) -> Bool {
    authenticationAttemptGeneration == generation && isAuthenticating && !isSigningOut
  }

  private func beginAuthenticationCallback(_ generation: UInt64) -> Bool {
    guard isCurrentAuthenticationAttempt(generation) else { return false }
    guard activeAuthenticationCallbackGeneration == nil else { return false }
    activeAuthenticationCallbackGeneration = generation
    authenticationCallbackOwnsCredentialMutation = false
    return true
  }

  private func finishAuthenticationCallback(_ generation: UInt64) {
    guard activeAuthenticationCallbackGeneration == generation else { return }
    activeAuthenticationCallbackGeneration = nil
    authenticationCallbackOwnsCredentialMutation = false
    let waiters = authenticationCallbackWaiters
    authenticationCallbackWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func waitForAuthenticationCallbackToFinish() async {
    while activeAuthenticationCallbackGeneration != nil,
      authenticationCallbackOwnsCredentialMutation
    {
      await withCheckedContinuation { continuation in
        authenticationCallbackWaiters.append(continuation)
      }
    }
  }

  private func invalidateAuthenticationAttempt(cancelSession: Bool = true) {
    authenticationAttemptGeneration &+= 1
    if cancelSession { authSession?.cancel() }
    authSession = nil
    isAuthenticating = false
    cancelAuthenticationPresentationFallback()
    authenticationActionPhase = .idle
    authenticationActionOwner = nil
    grantedScopesPendingPresentation = nil
  }

  private func finishAuthenticationAttempt(_ generation: UInt64) {
    guard authenticationAttemptGeneration == generation else { return }
    invalidateAuthenticationAttempt(cancelSession: false)
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
    guard !isAuthenticating, !isEnteringDemo, !isSigningOut else { return }
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
    let authenticationAttempt = beginAuthenticationAttempt()
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
        guard
          let self,
          self.beginAuthenticationCallback(authenticationAttempt)
        else { return }
        defer { self.finishAuthenticationCallback(authenticationAttempt) }
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
          finishAuthenticationAttempt(authenticationAttempt)
          return
        }
        guard error == nil, let url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
          finishAuthenticationAttempt(authenticationAttempt)
          errorMessage = error?.localizedDescription ?? "OAuth callback was invalid."
          return
        }
        let values = Dictionary(
          uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard values["state"] == state, let code = values["code"] else {
          finishAuthenticationAttempt(authenticationAttempt)
          errorMessage = values["error_description"] ?? values["error"] ?? "OAuth state mismatch."
          return
        }
        let previousScopes = grantedScopes
        let previousProfileID = user?.id
        let previousAccounts = accounts
        let previousAccountIDs = Set(accounts.map(\.id))
        let previousActiveAccountID = activeAccountID
        let previousTokens: TokenSet?
        do {
          if preservesExistingSession, !(tokenStore is KeychainTokenStore) {
            let accessToken = try await tokenStore.getAccessToken()
            guard isCurrentAuthenticationAttempt(authenticationAttempt) else { return }
            if let accessToken {
              let refreshToken = try await tokenStore.getRefreshToken()
              guard isCurrentAuthenticationAttempt(authenticationAttempt) else { return }
              previousTokens = TokenSet(
                accessToken: accessToken,
                refreshToken: refreshToken,
                scope: previousScopes?.sorted().joined(separator: " ")
              )
            } else {
              previousTokens = nil
            }
          } else {
            previousTokens = nil
          }
        } catch {
          guard isCurrentAuthenticationAttempt(authenticationAttempt) else { return }
          // If the old credential cannot be snapshotted completely, leave it
          // untouched instead of beginning a replacement we cannot roll back.
          finishAuthenticationAttempt(authenticationAttempt)
          errorMessage = error.localizedDescription
          return
        }
        var credentialReplacementPrepared = false
        var credentialReplacement: OAuthCredentialReplacement?
        do {
          let tokens = try await OAuth.exchangeCode(
            clientID: configuration.clientID, code: code, verifier: pkce.verifier,
            redirectURI: configuration.redirectURI, session: DashAPISession.shared
          )
          guard isCurrentAuthenticationAttempt(authenticationAttempt) else { return }
          authenticationCallbackOwnsCredentialMutation = true
          let granted =
            tokens.scope.map { Set($0.split(separator: " ").map(String.init)) }
            ?? requestedScopes
          // Keep the old token installed until every already-started deletion
          // has finished or entered read-only reconciliation.
          await deferredDeletions.prepareForCredentialReplacement()
          guard isCurrentAuthenticationAttempt(authenticationAttempt) else { return }
          credentialReplacementPrepared = true
          // Every OAuth result is a new credential generation, including a
          // permission upgrade that happens to keep the same profile. Persist
          // the Widget tombstone before replacing Keychain values so a late
          // response from the prior generation can never repopulate cache.
          try invalidateMetricsWidgetSession()
          if !(tokenStore is KeychainTokenStore) {
            credentialReplacement = .protocolStore(previousCredential: previousTokens)
          }
          credentialReplacement = try await replaceStoredTokens(
            with: tokens,
            grantedScopes: granted,
            previousProtocolCredential: previousTokens)
          guard isCurrentAuthenticationAttempt(authenticationAttempt) else { return }
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
          guard isCurrentAuthenticationAttempt(authenticationAttempt) else { return }
          identityStale = false
          requiresVerifiedIdentityBeforeAuthentication = false
          activateRemoteMetricsWidgetSession()
          if preservesExistingSession {
            // A legacy grant upgrade stays on the current screen so the user
            // can retry the action that led them to the consent sheet.
            if presentsCompletion {
              authenticationActionPhase = .succeeded
              armAuthenticationPresentationFallback()
            } else {
              finishAuthenticationAttempt(authenticationAttempt)
            }
          } else {
            // AppRoot holds the onboarding surface until the shared success
            // icon swap reports logical completion. First let the system
            // browser sheet finish dismissing so that swap remains visible.
            try? await Task.sleep(for: .milliseconds(280))
            guard isCurrentAuthenticationAttempt(authenticationAttempt) else { return }
            authenticationActionPhase = .succeeded
            armAuthenticationPresentationFallback()
            authState = .authenticated
          }
        } catch {
          guard isCurrentAuthenticationAttempt(authenticationAttempt) else { return }
          authenticationCallbackOwnsCredentialMutation = true
          authenticationActionPhase = .idle
          authenticationActionOwner = nil
          grantedScopesPendingPresentation = nil
          let restoredPreviousCredential =
            await handleOAuthCredentialReplacementFailure(
              replacementPrepared: credentialReplacementPrepared,
              replacement: credentialReplacement,
              replacementFailure: error,
              preservesExistingSession: preservesExistingSession,
              previousScopes: previousScopes,
              previousProfileID: previousProfileID,
              previousAccountIDs: previousAccountIDs,
              previousAccounts: previousAccounts,
              previousActiveAccountID: previousActiveAccountID)
          guard isCurrentAuthenticationAttempt(authenticationAttempt) else { return }
          if errorMessage == nil {
            errorMessage = error.localizedDescription
          }
          if !preservesExistingSession || !restoredPreviousCredential {
            let boundaryReady = await prepareForUnauthenticatedPresentation()
            guard isCurrentAuthenticationAttempt(authenticationAttempt) else { return }
            if boundaryReady {
              requiresVerifiedIdentityBeforeAuthentication = false
              authState = .unauthenticated
            } else {
              // The UI identity and the surviving shared credential can no
              // longer be proven to describe the same Cloudflare profile.
              // Close both the old catalog and onboarding until retry reaches
              // a conclusive credential boundary.
              requiresVerifiedIdentityBeforeAuthentication = true
              authState = .loading
            }
          }
          finishAuthenticationAttempt(authenticationAttempt)
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
      guard
        let self,
        self.isCurrentAuthenticationAttempt(authenticationAttempt),
        self.authSession === session
      else { return }
      if !session.start() {
        self.finishAuthenticationAttempt(authenticationAttempt)
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
    let pendingScopes = grantedScopesPendingPresentation
    invalidateAuthenticationAttempt(cancelSession: false)
    if let pendingScopes {
      grantedScopes = pendingScopes
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

  private func replaceStoredTokens(
    with tokens: TokenSet,
    grantedScopes: Set<String>,
    previousProtocolCredential: TokenSet?
  ) async throws -> OAuthCredentialReplacement {
    // `TokenStore.setTokens` intentionally preserves a refresh token omitted
    // by a normal refresh response. An OAuth identity replacement is
    // different: the real Keychain store clears and installs under one flock
    // so a Widget refresh cannot interleave fields from two identities. Test
    // stores retain the protocol-level fallback.
    if let keychainStore = tokenStore as? KeychainTokenStore {
      return .keychain(
        try await keychainStore.replaceCredential(
          with: tokens,
          grantedScopes: grantedScopes))
    } else {
      try await tokenStore.clear()
      try await tokenStore.setTokens(tokens)
      try await tokenStore.setGrantedScopes(grantedScopes)
      return .protocolStore(previousCredential: previousProtocolCredential)
    }
  }

  private func removeStoredCredentialForSignOut() async throws
    -> KeychainStoredCredentialSnapshot?
  {
    if let keychainStore = tokenStore as? KeychainTokenStore {
      return try await keychainStore.removeCredential()
    }
    // Protocol stores used by tests are process-local, so no sibling can
    // rotate between these reads and the clear.
    let accessToken = try await tokenStore.getAccessToken()
    let refreshToken = try await tokenStore.getRefreshToken()
    let scopes = try await tokenStore.getGrantedScopes()
    try await tokenStore.clear()
    guard let accessToken else { return nil }
    return KeychainStoredCredentialSnapshot(
      accessToken: accessToken,
      refreshToken: refreshToken,
      rawExpirationTimestamp: nil,
      rawGrantedScopes: scopes?.sorted().joined(separator: " "))
  }

  private func invalidateMetricsWidgetSession() throws {
    guard MetricsWidgetPublisher.clear() else {
      throw MetricsWidgetSessionLifecycleError.transitionFailed
    }
  }

  /// Onboarding is a disclosure boundary, not merely a navigation state. It
  /// may become visible only after both shared consumers have been cut off:
  /// Widget metadata is tombstoned and every Keychain capability is gone.
  /// Files follows the same rule because a mounted domain can retain
  /// downloaded account data even after the app itself forgets the identity.
  private func prepareForUnauthenticatedPresentation() async -> Bool {
    do {
      try invalidateMetricsWidgetSession()
    } catch {
      appendErrorMessage(error.localizedDescription)
      return false
    }
    do {
      try await tokenStore.clear()
    } catch {
      appendErrorMessage(error.localizedDescription)
      return false
    }
    guard await removeAllFileProviderDomains() else {
      appendErrorMessage(
        DashL10n.string(
          "Files couldn't remove all downloaded copies from this iPhone. Reopen Dash to try again."
        ))
      return false
    }
    deferredDeletions.discardUnverifiedCredentialStatePreservingRecovery()
    return true
  }

  private func appendErrorMessage(_ message: String) {
    guard errorMessage?.contains(message) != true else { return }
    errorMessage = [errorMessage, message]
      .compactMap { $0 }
      .joined(separator: "\n")
  }

  @discardableResult
  private func activateRemoteMetricsWidgetSession() -> Bool {
    activateRemoteMetricsWidgetSession(
      accounts: accounts,
      activeAccountID: activeAccountID)
  }

  @discardableResult
  private func activateRemoteMetricsWidgetSession(
    accounts: [CloudflareAccount],
    activeAccountID: String?,
    reportsFailure: Bool = true
  ) -> Bool {
    let activated = MetricsWidgetPublisher.activateRemote(
      accounts: accounts,
      activeAccountID: activeAccountID)
    if !activated, reportsFailure {
      reportMetricsWidgetSessionActivationFailure()
    }
    return activated
  }

  @discardableResult
  private func activateLocalMetricsWidgetSession() -> Bool {
    let activated = MetricsWidgetPublisher.activateLocalOnly(
      accounts: accounts,
      activeAccountID: activeAccountID)
    if !activated {
      reportMetricsWidgetSessionActivationFailure()
    }
    return activated
  }

  private func reportMetricsWidgetSessionActivationFailure() {
    let message = MetricsWidgetSessionLifecycleError.transitionFailed.localizedDescription
    errorMessage = message
    toasts.error(message)
  }

  @discardableResult
  private func handleOAuthCredentialReplacementFailure(
    replacementPrepared: Bool,
    replacement: OAuthCredentialReplacement?,
    replacementFailure: Error,
    preservesExistingSession: Bool,
    previousScopes: Set<String>?,
    previousProfileID: String?,
    previousAccountIDs: Set<String>,
    previousAccounts: [CloudflareAccount],
    previousActiveAccountID: String?
  ) async -> Bool {
    guard replacementPrepared else {
      // Code exchange failed before the coordinator, Widget session, or
      // credential changed.
      return preservesExistingSession
    }

    switch replacement {
    case .keychain(let receipt):
      guard let keychainStore = tokenStore as? KeychainTokenStore else { return false }
      do {
        guard try await keychainStore.restoreCredential(from: receipt) else {
          deferredDeletions.discardUnverifiedCredentialStatePreservingRecovery()
          return false
        }
        guard !isSigningOut else { return false }
        return bindRestoredCredentialState(
          previousScopes: previousScopes,
          previousProfileID: previousProfileID,
          previousAccountIDs: previousAccountIDs,
          previousAccounts: previousAccounts,
          previousActiveAccountID: previousActiveAccountID)
      } catch {
        appendErrorMessage(error.localizedDescription)
        toasts.error(error.localizedDescription)
        deferredDeletions.discardUnverifiedCredentialStatePreservingRecovery()
        return false
      }

    case .protocolStore(let previousCredential):
      return await handleCredentialReplacementFailure(
        replacementPrepared: true,
        preservesExistingSession: preservesExistingSession,
        previousTokens: previousCredential,
        previousScopes: previousScopes,
        previousProfileID: previousProfileID,
        previousAccountIDs: previousAccountIDs,
        previousAccounts: previousAccounts,
        previousActiveAccountID: previousActiveAccountID)

    case nil:
      // `replaceCredential` either never began or restored its exact pre-call
      // snapshot before throwing. Only `credentialStateUncertain` means that
      // invariant itself failed and forbids rebinding work to the old profile.
      if tokenStore is KeychainTokenStore {
        if let coordinationError = replacementFailure
          as? KeychainCredentialCoordinationError,
          case .credentialStateUncertain = coordinationError
        {
          deferredDeletions.discardUnverifiedCredentialStatePreservingRecovery()
          return false
        }
        guard preservesExistingSession, !isSigningOut else {
          deferredDeletions.discardUnverifiedCredentialStatePreservingRecovery()
          return false
        }
        return bindRestoredCredentialState(
          previousScopes: previousScopes,
          previousProfileID: previousProfileID,
          previousAccountIDs: previousAccountIDs,
          previousAccounts: previousAccounts,
          previousActiveAccountID: previousActiveAccountID)
      }
      return await handleCredentialReplacementFailure(
        replacementPrepared: true,
        preservesExistingSession: preservesExistingSession,
        previousTokens: nil,
        previousScopes: previousScopes,
        previousProfileID: previousProfileID,
        previousAccountIDs: previousAccountIDs,
        previousAccounts: previousAccounts,
        previousActiveAccountID: previousActiveAccountID)
    }
  }

  @discardableResult
  private func bindRestoredCredentialState(
    previousScopes: Set<String>?,
    previousProfileID: String?,
    previousAccountIDs: Set<String>,
    previousAccounts: [CloudflareAccount],
    previousActiveAccountID: String?
  ) -> Bool {
    guard let previousProfileID else {
      deferredDeletions.discardUnverifiedCredentialStatePreservingRecovery()
      return false
    }
    grantedScopes = previousScopes
    selectedScopes = previousScopes ?? selectedScopes
    requiresVerifiedIdentityBeforeAuthentication = false
    deferredDeletions.activateCredential(
      profileID: previousProfileID,
      availableAccountIDs: previousAccountIDs)
    activateRemoteMetricsWidgetSession(
      accounts: previousAccounts,
      activeAccountID: previousActiveAccountID)
    return true
  }

  @discardableResult
  func handleCredentialReplacementFailure(
    replacementPrepared: Bool,
    preservesExistingSession: Bool,
    previousTokens: TokenSet?,
    previousScopes: Set<String>?,
    previousProfileID: String?,
    previousAccountIDs: Set<String>,
    previousAccounts: [CloudflareAccount]? = nil,
    previousActiveAccountID: String? = nil
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
        previousAccountIDs: previousAccountIDs,
        previousAccounts: previousAccounts,
        previousActiveAccountID: previousActiveAccountID)
    }
    do {
      try await tokenStore.clear()
    } catch {
      errorMessage = error.localizedDescription
      toasts.error(error.localizedDescription)
    }
    deferredDeletions.discardUnverifiedCredentialStatePreservingRecovery()
    return false
  }

  @discardableResult
  func restoreCredentialAfterFailedReplacement(
    previousTokens: TokenSet,
    previousScopes: Set<String>?,
    previousProfileID: String?,
    previousAccountIDs: Set<String>,
    previousAccounts: [CloudflareAccount]? = nil,
    previousActiveAccountID: String? = nil
  ) async -> Bool {
    // The real shared store must restore only from its lock-issued receipt;
    // accepting a caller-supplied TokenSet here would reintroduce the stale
    // refresh-token rollback this path exists to prevent.
    guard !(tokenStore is KeychainTokenStore) else {
      deferredDeletions.discardUnverifiedCredentialStatePreservingRecovery()
      return false
    }
    do {
      try await tokenStore.clear()
      try await tokenStore.setTokens(previousTokens)
      if let previousScopes {
        try await tokenStore.setGrantedScopes(previousScopes)
      }
      grantedScopes = previousScopes
      selectedScopes = previousScopes ?? selectedScopes
      guard let previousProfileID else {
        do {
          try await tokenStore.clear()
        } catch {
          errorMessage = error.localizedDescription
          toasts.error(error.localizedDescription)
        }
        deferredDeletions.discardUnverifiedCredentialStatePreservingRecovery()
        return false
      }
      deferredDeletions.activateCredential(
        profileID: previousProfileID,
        availableAccountIDs: previousAccountIDs)
      if let previousAccounts {
        activateRemoteMetricsWidgetSession(
          accounts: previousAccounts,
          activeAccountID: previousActiveAccountID)
      } else {
        activateRemoteMetricsWidgetSession()
      }
      return true
    } catch let restorationError {
      // The keychain may now contain no credential or only part of one.
      // Never bind coordinator work to a guessed identity in that state.
      do {
        try await tokenStore.clear()
      } catch {
        errorMessage = error.localizedDescription
        toasts.error(error.localizedDescription)
      }
      if errorMessage == nil {
        errorMessage = restorationError.localizedDescription
      }
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
      // Demo account identifiers must never coexist with retained real-account
      // Widget metadata or an in-flight real-account refresh.
      do {
        try self.invalidateMetricsWidgetSession()
      } catch {
        self.errorMessage = error.localizedDescription
        self.toasts.error(error.localizedDescription)
        return
      }
      self.resetAccountScopedWork()
      self.featureCache.clearAllPersistence()
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
        self.identityStale = false
        self.requiresVerifiedIdentityBeforeAuthentication = false
        self.activateLocalMetricsWidgetSession()
        self.authState = .authenticated
      } catch {
        guard self.isDemoSession else { return }
        let identityErrorMessage = error.localizedDescription
        let exited = await self.exitDemo()
        let message =
          exited
          ? identityErrorMessage
          : [identityErrorMessage, self.errorMessage]
            .compactMap { $0 }
            .joined(separator: "\n")
        self.errorMessage = message
        self.toasts.error(message)
      }
    }
  }

  /// Tears down the demo session: restores the real client and returns to
  /// onboarding. No keychain, push, or revocation work — the demo never
  /// touched any of it.
  @discardableResult
  private func exitDemo(setsAuthenticationState: Bool = true) async -> Bool {
    do {
      try invalidateMetricsWidgetSession()
    } catch {
      errorMessage = error.localizedDescription
      toasts.error(error.localizedDescription)
      return false
    }
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
    requiresVerifiedIdentityBeforeAuthentication = false
    watchtowerUnreadAlertCount = nil
    pendingRoute = nil
    pendingHomeAction = nil
    pendingLegacyNotificationRoute = nil
    LegacyWatchtowerNotificationSettings.clear()
    toasts.clearAll()
    UserDefaults.standard.removeObject(forKey: DashAppGroup.activeAccountKey)
    R2ShareDestination.clear()
    if setsAuthenticationState {
      authState = .unauthenticated
    }
    return true
  }

  func signOut(
    presentsCompletion: Bool = false,
    metricsWidgetSessionAlreadyInvalidated: Bool = false
  ) async {
    if isDemoSession {
      cancelSignOutPresentationFallback()
      signOutActionPhase = presentsCompletion ? .loading : .idle
      guard await exitDemo(setsAuthenticationState: !presentsCompletion) else {
        signOutActionPhase = .idle
        return
      }
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
    defer {
      isSigningOut = false
      syncNotificationAccountAuthorization()
      scheduleFileProviderDomainReconciliation()
    }
    invalidateAuthenticationAttempt()
    await waitForAuthenticationCallbackToFinish()

    let retainedAccounts = accounts
    let retainedActiveAccountID = activeAccountID
    let retainedProfileID = user?.id
    if !metricsWidgetSessionAlreadyInvalidated {
      do {
        // Stop new Widget requests before any long-running cleanup. The
        // generation tombstone also rejects a response already in flight.
        try invalidateMetricsWidgetSession()
      } catch {
        signOutActionPhase = .idle
        errorMessage = error.localizedDescription
        toasts.error(error.localizedDescription)
        return
      }
    }

    let pushAccountIDs = Set(accounts.map(\.id))
      .union(PushRegistrationService.enabledAccountIDs())
      .union(PushRegistrationService.pendingCleanupAccountIDs())

    // Freeze deferred work before the local commit. Nothing below this await
    // has removed Files data, disabled a webhook, or changed notification
    // authorization, so a Keychain lock failure can still preserve the whole
    // signed-in experience.
    await deferredDeletions.prepareForCredentialReplacement()
    let removedCredential: KeychainStoredCredentialSnapshot?
    do {
      // This lock-held capture + clear is the local sign-out commit. No shared
      // process can rotate the token between the snapshot and its removal.
      removedCredential = try await removeStoredCredentialForSignOut()
    } catch {
      var messages = [error.localizedDescription]
      if metricsWidgetSessionAlreadyInvalidated {
        // A terminal 401 already proved this credential dead. Keep recovery
        // frozen and the Widget tombstoned; never resurrect either from the
        // failed cleanup attempt.
        deferredDeletions.discardUnverifiedCredentialStatePreservingRecovery()
      } else {
        if let retainedProfileID {
          deferredDeletions.activateCredential(
            profileID: retainedProfileID,
            availableAccountIDs: Set(retainedAccounts.map(\.id)))
        } else {
          deferredDeletions.discardUnverifiedCredentialStatePreservingRecovery()
        }
        let restored = activateRemoteMetricsWidgetSession(
          accounts: retainedAccounts,
          activeAccountID: retainedActiveAccountID,
          reportsFailure: false)
        if !restored {
          messages.append(
            MetricsWidgetSessionLifecycleError.transitionFailed.localizedDescription)
        }
      }
      let message = messages.joined(separator: "\n")
      signOutActionPhase = .idle
      errorMessage = message
      toasts.error(message)
      return
    }

    // From this point onward the shared credential is conclusively gone. A
    // cleanup failure is reported but can no longer roll the app back to an
    // authenticated state. The detached store may rotate only its private
    // copy while finishing remote teardown.
    let cleanupStore = SignOutCleanupTokenStore(
      accessToken: removedCredential?.accessToken,
      refreshToken: removedCredential?.refreshToken,
      scopes: removedCredential?.grantedScopes)
    let cleanupClient = CloudflareClient(
      clientID: configuration.clientID,
      tokenStore: cleanupStore,
      session: authenticatedSession)
    var cleanupMessages: [String] = []

    fileProviderReconcileGeneration &+= 1
    let pendingFileProviderReconcile = fileProviderReconcileTask
    fileProviderReconcileTask?.cancel()
    fileProviderReconcileTask = nil
    await pendingFileProviderReconcile?.value
    if !(await removeAllFileProviderDomains()) {
      cleanupMessages.append(
        DashL10n.string(
          "Files couldn't remove all downloaded copies from this iPhone. Reopen Dash to try again."
        ))
    }

    // Invalidate user-started enable work before waiting on each account's
    // mutation lock. If an enable crossed the Keychain commit, disable sees
    // its persisted webhook or leaves a durable cleanup tombstone.
    PushRegistrationService.prepareForSignOut(accountIDs: pushAccountIDs)
    let pendingPushReconcile = pushReconcileTask
    pushReconcileTask?.cancel()
    pushReconcileTask = nil
    NotificationAccountAuthorizationStore.clear()
    await pendingPushReconcile?.value

    var pushCleanupFailureCount = 0
    for accountID in pushAccountIDs.sorted() {
      do {
        try await PushRegistrationService.disable(
          accountID: accountID,
          client: cleanupClient)
      } catch {
        pushCleanupFailureCount += 1
      }
    }
    if pushCleanupFailureCount > 0 {
      cleanupMessages.append(
        "\(DashL10n.string("Alert policies")): \(DashL10n.string("Cloudflare couldn’t complete this request. Try again."))"
      )
    }

    // Push cleanup can refresh and rotate the detached credential. Revoke the
    // latest access token it actually used, never the pre-cleanup snapshot.
    if let cleanupAccessToken = await cleanupStore.getAccessToken() {
      try? await OAuth.revoke(
        clientID: configuration.clientID, token: cleanupAccessToken,
        session: DashAPISession.shared)
    }
    resetAccountScopedWork()
    activeAccountID = nil
    // The active credential is conclusively gone; drop every account's disk
    // cache so a relaunch cannot resurrect a signed-out account's data.
    featureCache.clearAllPersistence()
    UIApplication.shared.unregisterForRemoteNotifications()
    deferredDeletions.discardCredentialState()
    avatars.clearMemory()
    await r2Thumbnails.clear()
    accounts = []
    user = nil
    grantedScopes = nil
    selectedScopes = DashAuthorizationScopes.core
    identityStale = false
    requiresVerifiedIdentityBeforeAuthentication = false
    watchtowerUnreadAlertCount = nil
    pendingRoute = nil
    pendingHomeAction = nil
    pendingLegacyNotificationRoute = nil
    pendingDeviceToken = nil
    LegacyWatchtowerNotificationSettings.clear()
    WatchtowerRemoteRefreshInvalidationStore.clearAll()
    toasts.clearAll()
    UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    clearWatchtowerWidgetSnapshot()
    UserDefaults.standard.removeObject(forKey: DashAppGroup.activeAccountKey)
    R2ShareDestination.clear()
    if presentsCompletion {
      signOutActionPhase = .succeeded
      armSignOutPresentationFallback()
    }
    authState = .unauthenticated
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
    // Domains are account-scoped, not active-account-scoped: every
    // authenticated account keeps its Files location, so switching the
    // selection neither mounts nor unmounts anything on its own.
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
  func watchtowerSnapshot(force: Bool = false) async -> WatchtowerSnapshot? {
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
    publishWidgetSnapshot(snapshot, accountID: context.accountID)
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

  /// Writes the slim snapshot into the App Group container and refreshes the
  /// widget. Cloudflare webhook delivery is the only Watchtower notification
  /// source; a history refresh never schedules a second local alert.
  private func publishWidgetSnapshot(
    _ snapshot: WatchtowerSnapshot,
    accountID: String
  ) {
    guard let url = WatchtowerWidgetSnapshot.containerFileURL else { return }
    let widget = snapshot.widgetSnapshot(
      accountID: accountID,
      accountName: activeAccount?.name
    )
    try? widget.write(to: url)
    WidgetCenter.shared.reloadAllTimelines()
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

  /// Foreground/warm-up hook: cheap when the snapshot is younger than the
  /// TTL, otherwise re-runs the checks in the background.
  func refreshWatchtowerIfStale() async {
    guard let accountID = activeAccountID else { return }
    let wasRemotelyInvalidated = WatchtowerRemoteRefreshInvalidationStore.contains(
      accountID: accountID)
    if let cached: WatchtowerSnapshot = featureCache.get(FeatureCacheKey.watchtower(accountID)) {
      syncWatchtowerInboxBadge(from: cached, accountID: accountID)
      guard wasRemotelyInvalidated || cached.isStale(ttl: Self.watchtowerTTL) else { return }
    }
    _ = await watchtowerSnapshot(force: true)
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
    scheduleDefaultPushRegistration()
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
        "\(DashL10n.string("Alert policies")): \(DashL10n.string("Cloudflare couldn’t complete this request. Try again."))"
      )
    }
  }
}

extension AppModel: PushTokenInbox {
  /// Woken by the relay's silent push. Forces a Watchtower reload — the TTL
  /// says the snapshot is fresh, but a delivery just landed, so it isn't.
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
    return await watchtowerSnapshot(force: true) != nil
  }

  func receivePushRegistrationChallenge(
    _ challenge: PushRegistrationChallenge
  ) async -> Bool {
    await PushRegistrationChallengeInbox.shared.receive(challenge)
  }

  func receiveDeviceToken(_ token: Data) {
    let hex = PushRegistration.hexToken(from: token)
    pendingDeviceToken = hex
    scheduleDefaultPushRegistration()
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
