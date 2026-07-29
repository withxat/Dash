import AppIntents
import CloudflareAPI
import SwiftDitherKit
import SwiftGlobeKit
import SwiftUI

@main
struct DashApp: App {
  @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
  @State private var model: AppModel

  init() {
    DashMetricSubscriber.shared.start()
    R2TemporaryFile.removeStaleFiles(olderThan: 60 * 60)
    // Charts and the globe both take the finger only after a hold, and both
    // announce that with a haptic. Route it through Dash's own preference so
    // one toggle still silences every buzz in the app.
    DitherHoldInteraction.onEngage = { DashDelight.gestureEngaged() }
    GlobeHoldInteraction.onEngage = { DashDelight.gestureEngaged() }
    #if DEBUG
      let model: AppModel
      if ProcessInfo.processInfo.arguments.contains("-uiTestDeferredDeletion") {
        DeferredDeletionUITestBackend.reset()
        model = AppModel(
          tokenStore: DeferredDeletionUITestTokenStore(),
          session: DeferredDeletionUITestBackend.session,
          deferredDeletionPersistence: nil)
      } else {
        model = AppModel()
      }
    #else
      let model = AppModel()
    #endif
    _model = State(initialValue: model)
    if ICloudPreferencesSync.shouldStartForCurrentProcess {
      ICloudPreferencesSync.shared.start()
    }
    // System callbacks can arrive before SwiftUI mounts a scene (notably a
    // content-available launch). Wire the delegate during app construction,
    // rather than waiting for the root view's first onAppear.
    pushDelegate.inbox = model
    // In-app App Intents run in this process; hand them the app's own model
    // so they share its client and single-flight token refresh.
    AppDependencyManager.shared.add(dependency: model)
    if UserDefaults.standard.bool(forKey: WatchtowerNotifier.optInDefaultsKey)
      || !PushRegistrationService.enabledAccountIDs().isEmpty
    {
      Task {
        await WatchtowerNotifier.migrateLegacyBadgeAuthorizationIfNeeded()
      }
    }

    let largeTitleAttributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.dashTitle(size: AvatarHeaderMetrics.titleSize, weight: .bold),
      .foregroundColor: UIColor.label,
    ]
    let inlineTitleAttributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.dashTitle(size: 17, weight: .semibold),
      .foregroundColor: UIColor.label,
    ]

    let scrollEdgeAppearance = UINavigationBarAppearance()
    scrollEdgeAppearance.configureWithTransparentBackground()
    scrollEdgeAppearance.largeTitleTextAttributes = largeTitleAttributes
    scrollEdgeAppearance.titleTextAttributes = inlineTitleAttributes
    scrollEdgeAppearance.shadowColor = .clear

    // Default background keeps the system blur material. Not for Dash's own
    // screens — those hide the toolbar background outright and paint their own
    // frost (`dashHeaderScrim`) so it can fade out instead of ending on an
    // edge. This one is for the bars Dash does not own: the QuickLook preview
    // (`R2ObjectPreview`) runs a real `UINavigationController` with no
    // appearance of its own and inherits this proxy, and its system chrome is
    // deliberately left stock. Strip the background here and that bar loses it.
    let standardAppearance = UINavigationBarAppearance()
    standardAppearance.configureWithDefaultBackground()
    standardAppearance.largeTitleTextAttributes = largeTitleAttributes
    standardAppearance.titleTextAttributes = inlineTitleAttributes
    standardAppearance.shadowColor = .clear

    // Keep the Solar back mark inside the appearance objects themselves.
    // UIKit sources an explicitly installed appearance as a whole, so setting
    // only the bar proxy can otherwise leave the system chevron in place.
    let backImage = UIImage(named: SolarAsset.chevronLeft)?.withRenderingMode(.alwaysTemplate)
    scrollEdgeAppearance.setBackIndicatorImage(backImage, transitionMaskImage: backImage)
    standardAppearance.setBackIndicatorImage(backImage, transitionMaskImage: backImage)

    UINavigationBar.appearance().scrollEdgeAppearance = scrollEdgeAppearance
    UINavigationBar.appearance().standardAppearance = standardAppearance
    UINavigationBar.appearance().compactAppearance = standardAppearance

    // No UITabBar appearance proxy: the pager is `.tabViewStyle(.page)` with
    // no system tab bar, and `DashFloatingTabBar` owns all tab styling.
  }

  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestKeyboardForm") {
          KeyboardDismissalTestHost()
            .tint(DashTheme.brand)
            .environment(model)
        } else if ProcessInfo.processInfo.arguments.contains("-uiTestDeferredDeletion") {
          DeferredDeletionTestHost()
            .tint(DashTheme.brand)
            .environment(model)
        } else {
          RootWithSplash(model: model)
            .tint(DashTheme.brand)
        }
      #else
        RootWithSplash(model: model)
          .tint(DashTheme.brand)
      #endif
    }
    .backgroundTask(.appRefresh(AppModel.backgroundRefreshID)) {
      await model.performBackgroundWatchtowerRefresh()
    }
    // Pages LA continuation — same SwiftUI registration path as Watchtower.
    // Best-effort; the controller single-flights it with any foreground refresh.
    .backgroundTask(.appRefresh(PagesBuildActivityController.backgroundRefreshID)) {
      await PagesBuildActivityController.shared.performBackgroundRefresh(
        client: model.client, context: model.accountRequestContext)
    }
  }
}

/// Bridges the static system launch screen into the first interactive frame:
/// same `LaunchBackground` + centered `LaunchLogo`, held until bootstrap
/// finishes (and a short minimum). Signed out, the "Dash" wordmark first
/// expands beside the centered icon, then the whole lockup glides and scales
/// onto the welcome header while the solid canvas fades to the login
/// backdrop; signed in, everything fades together.
private struct RootWithSplash: View {
  var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage(DashAppLanguage.storageKey) private var languageRaw = DashAppLanguage.system
    .rawValue
  @State private var phase: Phase = .holding
  /// Layout size of the magnified overlay lockup; the position/scale math
  /// needs it to keep the icon's center on target through every phase.
  @State private var lockupSize: CGSize = .zero

  private enum Phase { case holding, branding, landing, done }

  private static let minimumDuration: Duration = .milliseconds(800)
  private static let brandDuration: TimeInterval = 0.5
  /// Wordmark expansion plus a read beat before the lockup departs.
  private static let brandHold: Duration = .milliseconds(1000)
  /// While branding, the wordmark renders at this fraction of lockup
  /// proportion — smaller beside the big centered icon — and grows back to
  /// full proportion during landing.
  private static let brandWordmarkScale: CGFloat = 0.8
  private static let landDuration: TimeInterval = 0.6
  private static let holdingIconSize = OnboardingBrandTypography.launchIconSize
  /// The overlay lockup lays out at launch-logo size and scales *down* onto
  /// the welcome header — supersampled, so the wordmark stays crisp through
  /// the whole morph.
  private static let magnification = OnboardingBrandTypography.launchMagnification

  private var appLanguage: DashAppLanguage {
    DashAppLanguage.resolved(stored: languageRaw)
  }

  private var effectiveDynamicTypeSize: DynamicTypeSize {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-ui-preview-accessibility-text") {
        return .accessibility3
      }
    #endif
    return dynamicTypeSize
  }

  var body: some View {
    AppRootView()
      // Attached inside the environment overrides below, so the overlay
      // lockup resolves the same Dynamic Type and locale as the welcome
      // lockup it must pixel-match at hand-off.
      .overlayPreferenceValue(DashLoginIconAnchorKey.self) { anchor in
        if phase != .done {
          // Full-screen space: the system launch screen centers its image in
          // the whole screen, so the overlay must too or the logo jumps ~12pt
          // at handoff (the root view's frame is inset by asymmetric safe
          // areas).
          GeometryReader { proxy in
            splashOverlay(in: proxy, target: anchor.map { proxy[$0] })
          }
          .ignoresSafeArea()
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        }
      }
      .environment(model)
      .environment(\.locale, appLanguage.locale)
      .environment(\.dynamicTypeSize, effectiveDynamicTypeSize)
      .environment(\.dashSplashLifted, phase != .holding)
      .environment(\.dashLoginIconCloaked, phase != .done)
      // `DashL10n` resolves against the in-app locale; rebinding identity
      // rebuilds the tree so Settings → Language applies without relaunching.
      .id(languageRaw)
      .onOpenURL { url in
        if let route = DashRoute.parse(url) { model.pendingRoute = route }
      }
      .onAppear {
        appLanguage.applyToProcess()
        // The notification extension has its own defaults suite; the App Group
        // mirror is the only way the language choice reaches it.
        DashAlertStrings.mirrorLanguage(languageRaw)
      }
      .onChange(of: languageRaw) { _, _ in
        DashAppLanguage.resolved(stored: languageRaw).applyToProcess()
        DashAlertStrings.mirrorLanguage(languageRaw)
        model.discardLocalizedCaches()
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active {
          ICloudPreferencesSync.shared.refresh()
        }
      }
      .task {
        async let bootstrap: Void = model.bootstrap()
        try? await Task.sleep(for: Self.minimumDuration)
        await bootstrap

        if reduceMotion {
          phase = .done
          return
        }
        if model.authState == .unauthenticated {
          // Brand beat: the wordmark expands beside the still-centered icon
          // before the lockup departs for the welcome header.
          withAnimation(.spring(response: Self.brandDuration, dampingFraction: 0.85)) {
            phase = .branding
          }
          try? await Task.sleep(for: Self.brandHold)
        }
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: Self.landDuration)) {
          phase = .landing
        }
        try? await Task.sleep(for: .milliseconds(Int(Self.landDuration * 1000) + 50))
        phase = .done
      }
  }

  /// Matches `UILaunchScreen` composition while holding. `target` is the
  /// welcome lockup icon's frame when onboarding is mounted underneath.
  private func splashOverlay(in proxy: GeometryProxy, target: CGRect?) -> some View {
    let hasBackdrop = phase == .holding || phase == .branding
    let measured = lockupSize.width > 0
    let wordmarkShown = phase != .holding && target != nil
    return ZStack {
      Color("LaunchBackground")
        .ignoresSafeArea()
        .opacity(hasBackdrop ? 1 : 0)

      // Measurement fallback: identical to the launch screen for the frame(s)
      // before the lockup reports its layout size.
      if !measured {
        Image("LaunchLogo")
          .resizable()
          .scaledToFit()
          .frame(width: Self.holdingIconSize, height: Self.holdingIconSize)
          .clipShape(
            RoundedRectangle(
              cornerRadius: Self.holdingIconSize * OnboardingBrandIcon.cornerFactor,
              style: .continuous
            )
          )
          .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
      }

      OnboardingBrandLockup(
        icon: "LaunchLogo",
        magnification: Self.magnification,
        wordmarkShown: wordmarkShown,
        wordmarkScale: phase == .landing || phase == .done ? 1 : Self.brandWordmarkScale,
        staggersWordmark: true
      )
      // Belt over the phase transaction: if the landing anchor arrives late
      // (slow bootstrap), the wordmark still expands instead of popping in.
      .animation(
        .spring(response: Self.brandDuration, dampingFraction: 0.85), value: wordmarkShown
      )
      .onGeometryChange(for: CGSize.self) { proxy in
        proxy.size
      } action: { size in
        lockupSize = size
      }
      .scaleEffect(lockupScale(target: target, in: proxy), anchor: lockupIconAnchor)
      .position(lockupPosition(target: target, in: proxy))
      .opacity(measured && (hasBackdrop || target != nil) ? 1 : 0)
    }
  }

  /// Scale anchor pinned to the icon's center, so `lockupPosition` can place
  /// the icon exactly regardless of the current scale.
  private var lockupIconAnchor: UnitPoint {
    guard lockupSize.width > 0 else { return .center }
    return UnitPoint(x: Self.holdingIconSize / 2 / lockupSize.width, y: 0.5)
  }

  /// Distance from the lockup's layout center to its icon's center.
  private var iconCenterInset: CGFloat {
    lockupSize.width / 2 - Self.holdingIconSize / 2
  }

  /// What the branding lockup actually spans on screen: icon + gap + the
  /// wordmark at its reduced scale. The layout width overstates the group
  /// while `brandWordmarkScale` < 1, so centering and overflow math must use
  /// this instead of `lockupSize`.
  private var brandingVisualWidth: CGFloat {
    let gap = 8 * Self.magnification
    let textWidth = max(0, lockupSize.width - Self.holdingIconSize - gap)
    return Self.holdingIconSize + gap + textWidth * Self.brandWordmarkScale
  }

  /// Full-size unless the expanded lockup would overflow the screen (large
  /// Dynamic Type), in which case the whole group contracts to fit.
  private func brandingScale(in proxy: GeometryProxy) -> CGFloat {
    guard lockupSize.width > 0 else { return 1 }
    return min(1, (proxy.size.width - 48) / brandingVisualWidth)
  }

  private func lockupScale(target: CGRect?, in proxy: GeometryProxy) -> CGFloat {
    switch phase {
    case .holding:
      return 1
    case .branding:
      // No landing anchor means no wordmark will show — keep the icon as-is.
      return target == nil ? 1 : brandingScale(in: proxy)
    case .landing, .done:
      guard let target, target.width > 0 else { return 1 }
      return target.width / Self.holdingIconSize
    }
  }

  private func lockupPosition(target: CGRect?, in proxy: GeometryProxy) -> CGPoint {
    let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
    guard lockupSize.width > 0 else { return center }
    switch phase {
    case .holding:
      // Icon centered on screen; the hidden wordmark trails to its right.
      return CGPoint(x: center.x + iconCenterInset, y: center.y)
    case .branding:
      // The whole *visual* group centers on screen: the icon glides left
      // while the wordmark expands beside it. The icon's center sits half
      // the visual overhang (everything right of the icon) left of center.
      // Without a landing anchor the wordmark never shows (see
      // `wordmarkShown`), so the lone icon must not budge.
      guard target != nil else {
        return CGPoint(x: center.x + iconCenterInset, y: center.y)
      }
      let scale = brandingScale(in: proxy)
      let shift = (brandingVisualWidth - Self.holdingIconSize) / 2 * scale
      return CGPoint(x: center.x - shift + iconCenterInset, y: center.y)
    case .landing, .done:
      guard let target else {
        return CGPoint(x: center.x + iconCenterInset, y: center.y)
      }
      return CGPoint(x: target.midX + iconCenterInset, y: target.midY)
    }
  }
}

#if DEBUG
  private struct KeyboardDismissalTestHost: View {
    @State private var text = ""
    @State private var presentsForm = true

    var body: some View {
      Color.clear
        .dashTray(isPresented: $presentsForm, title: "Keyboard test") {
          DashFormSheet(
            onSave: {},
            content: {
              VStack(spacing: 24) {
                DashFormField(label: "Name", text: $text)
                Text("Form background")
                  .frame(maxWidth: .infinity, minHeight: 80)
              }
            }
          )
        }
    }
  }

  private struct DeferredDeletionTestHost: View {
    @Environment(AppModel.self) private var model
    @State private var ready = false

    var body: some View {
      Group {
        if ready {
          NavigationStack {
            DNSRecordsView(zoneID: "ui-zone")
              .environment(\.featureAllowsWrites, true)
          }
        } else {
          ProgressView()
        }
      }
      .dashToastHost()
      .task {
        model.activeAccountID = "ui-account"
        model.grantedScopes = DashAuthorizationScopes.core
        model.selectedScopes = DashAuthorizationScopes.core
        model.featureCache.set(
          FeatureCacheKey.dnsRecords("ui-zone"),
          Self.records,
          ttl: nil)
        model.deferredDeletions.activateCredential(
          profileID: "ui-deferred-profile",
          availableAccountIDs: ["ui-account"])
        ready = true
      }
    }

    private static var records: [DNSRecord] {
      let data = Data(DeferredDeletionUITestBackend.recordsJSON.utf8)
      return (try? JSONDecoder().decode([DNSRecord].self, from: data)) ?? []
    }
  }

  private struct DeferredDeletionUITestTokenStore: TokenStore {
    func clear() async throws {}
    func getAccessToken() async throws -> String? { "ui-test-token" }
    func getRefreshToken() async throws -> String? { nil }
    func setTokens(_: TokenSet) async throws {}
  }

  /// Deterministic URLProtocol backend for the production DNS screen used by
  /// the UI test. It prevents either the refresh callback or a slow test run
  /// from reaching Cloudflare or the simulator's persisted Keychain.
  private final class DeferredDeletionUITestBackend: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var deletedRecordIDs: Set<String> = []

    static let session: URLSession = {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [DeferredDeletionUITestBackend.self]
      return URLSession(configuration: configuration)
    }()

    static let recordJSONByID = [
      "record-1":
        """
      {
        "id": "record-1",
        "zone_id": "ui-zone",
        "type": "A",
        "name": "api.example.com",
        "content": "192.0.2.1",
        "proxied": false,
        "ttl": 1
      }
      """,
      "record-2":
        """
      {
        "id": "record-2",
        "zone_id": "ui-zone",
        "type": "CNAME",
        "name": "www.example.com",
        "content": "api.example.com",
        "proxied": true,
        "ttl": 1
      }
      """,
    ]

    static var recordsJSON: String {
      let records = lock.withLock {
        recordJSONByID.keys.sorted().compactMap { id in
          deletedRecordIDs.contains(id) ? nil : recordJSONByID[id]
        }
      }
      return "[\(records.joined(separator: ","))]"
    }

    static func reset() {
      lock.withLock { deletedRecordIDs.removeAll() }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      let reply = Self.reply(to: request)
      let response = HTTPURLResponse(
        url: request.url ?? URL(string: "https://api.cloudflare.com")!,
        statusCode: reply.status,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func reply(to request: URLRequest) -> (status: Int, body: String) {
      guard let url = request.url else { return missingResponse }
      var path = url.path
      if path.hasPrefix("/client/v4") {
        path.removeFirst("/client/v4".count)
      }
      let parts = path.split(separator: "/").map(String.init)
      guard
        parts.count >= 3,
        parts[0] == "zones",
        parts[1] == "ui-zone",
        parts[2] == "dns_records"
      else { return missingResponse }

      let method = (request.httpMethod ?? "GET").uppercased()
      if parts.count == 3, method == "GET" {
        let records = recordsJSON
        let count = lock.withLock { recordJSONByID.count - deletedRecordIDs.count }
        return (
          200,
          """
          {
            "success": true,
            "errors": [],
            "messages": [],
            "result": \(records),
            "result_info": {
              "page": 1,
              "per_page": 50,
              "count": \(count),
              "total_count": \(count),
              "total_pages": 1
            }
          }
          """
        )
      }

      guard parts.count == 4 else { return missingResponse }
      let recordID = parts[3]
      if method == "DELETE", recordJSONByID[recordID] != nil {
        lock.withLock { _ = deletedRecordIDs.insert(recordID) }
        return (
          200,
          #"{"success":true,"errors":[],"messages":[],"result":{"id":"\#(recordID)"}}"#
        )
      }
      if method == "GET",
        let record = recordJSONByID[recordID],
        lock.withLock({ !deletedRecordIDs.contains(recordID) })
      {
        return (
          200,
          #"{"success":true,"errors":[],"messages":[],"result":\#(record)}"#
        )
      }
      return missingResponse
    }

    private static var missingResponse: (status: Int, body: String) {
      (
        404,
        #"{"success":false,"errors":[{"code":81044,"message":"Record not found"}],"messages":[],"result":null}"#
      )
    }
  }
#endif
