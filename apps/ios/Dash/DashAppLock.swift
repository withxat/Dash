import LocalAuthentication
import SwiftUI
import UIKit

/// How the device will answer an unlock: the biometry it has enrolled, or its
/// passcode when it has none. `.deviceOwnerAuthentication` falls back to the
/// passcode on its own, so every case can unlock.
enum DashAppLockMethod: Equatable, Sendable {
  case faceID
  case touchID
  case passcode

  var settingTitle: String {
    switch self {
    case .faceID: DashL10n.string("Require Face ID")
    case .touchID: DashL10n.string("Require Touch ID")
    case .passcode: DashL10n.string("Require passcode")
    }
  }

  var unlockTitle: String {
    switch self {
    case .faceID: DashL10n.string("Unlock with Face ID")
    case .touchID: DashL10n.string("Unlock with Touch ID")
    case .passcode: DashL10n.string("Unlock with passcode")
    }
  }
}

protocol DashDeviceOwnerAuthenticating: Sendable {
  /// nil when the device has no passcode, so nothing could ever unlock it.
  func availableMethod() -> DashAppLockMethod?
  /// false for a failure and for a cancel alike: either way the lock stays.
  func authenticate(reason: String) async -> Bool
}

struct DashLocalAuthentication: DashDeviceOwnerAuthenticating {
  func availableMethod() -> DashAppLockMethod? {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return nil }
    switch context.biometryType {
    case .faceID: return .faceID
    case .touchID: return .touchID
    default: return .passcode
    }
  }

  func authenticate(reason: String) async -> Bool {
    let context = LAContext()
    return
      (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason))
      ?? false
  }
}

/// Settings → General → Require Face ID. Off by default.
///
/// The lock engages when the app goes to the **background**, never on
/// inactive: the Face ID sheet, the passcode pad, Control Center, and
/// `ASWebAuthenticationSession` all pass through inactive, and locking there
/// would lock the app behind its own unlock prompt.
///
/// It covers what the app shows, not what it can do without being shown: App
/// Intents, the Share extension, widgets, and the Files mount keep working,
/// because each runs on a request the device owner already made.
@Observable @MainActor
final class DashAppLock {
  static let enabledKey = "dash.app_lock_enabled"

  private let defaults: UserDefaults
  private let authenticator: any DashDeviceOwnerAuthenticating
  private(set) var isEnabled: Bool
  private(set) var isLocked: Bool
  private(set) var isAuthenticating = false
  /// What the device offers right now; refreshed whenever the lock is about to
  /// ask, because Face ID can be enrolled or the passcode removed in between.
  private(set) var method: DashAppLockMethod?
  /// Armed when the app is covered (background, or a locked launch) so the
  /// next activation prompts exactly once. A prompt disarms it before it
  /// shows: its own sheet bounces the scene through inactive → active, and a
  /// cancelled prompt must leave the Unlock button, not ask again in a loop.
  private var promptsOnActivation: Bool
  /// The lock window's visibility, which must flip synchronously with the
  /// state so the background snapshot is taken of the cover.
  @ObservationIgnored var onLockChange: (@MainActor (Bool) -> Void)?

  init(
    defaults: UserDefaults = .standard,
    authenticator: any DashDeviceOwnerAuthenticating = DashLocalAuthentication()
  ) {
    self.defaults = defaults
    self.authenticator = authenticator
    let enabled = defaults.bool(forKey: Self.enabledKey)
    isEnabled = enabled
    isLocked = enabled
    promptsOnActivation = enabled
    method = authenticator.availableMethod()
  }

  func refreshMethod() {
    method = authenticator.availableMethod()
  }

  func didEnterBackground() {
    guard isEnabled else { return }
    promptsOnActivation = true
    setLocked(true)
  }

  func didBecomeActive() async {
    guard isLocked, promptsOnActivation else { return }
    await unlock()
  }

  func unlock() async {
    guard isLocked, !isAuthenticating else { return }
    promptsOnActivation = false
    refreshMethod()
    guard method != nil else {
      // The passcode was removed after the lock was turned on. Nothing can
      // satisfy it any more, and whoever removed it already owns the device.
      persist(enabled: false)
      setLocked(false)
      return
    }
    isAuthenticating = true
    let unlocked = await authenticator.authenticate(reason: DashL10n.string("Unlock Dash"))
    isAuthenticating = false
    if unlocked { setLocked(false) }
  }

  /// Turning the lock on asks first, so it can only be enabled on a device
  /// that can answer it, by someone who can. Turning it off does not: the app
  /// is already unlocked in front of them. Returns whether the change applied.
  func setEnabled(_ enabled: Bool) async -> Bool {
    guard enabled != isEnabled else { return true }
    guard !isAuthenticating else { return false }
    if enabled {
      refreshMethod()
      guard method != nil else { return false }
      isAuthenticating = true
      let confirmed = await authenticator.authenticate(reason: DashL10n.string("Confirm it's you"))
      isAuthenticating = false
      guard confirmed else { return false }
    }
    persist(enabled: enabled)
    return true
  }

  private func persist(enabled: Bool) {
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.enabledKey)
  }

  private func setLocked(_ locked: Bool) {
    guard isLocked != locked else { return }
    isLocked = locked
    onLockChange?(locked)
  }
}

#if DEBUG
  extension DashAppLock {
    /// UI tests drive the app on a simulator a developer may have locked by
    /// hand; their run must never start behind a Face ID prompt.
    static func disabledForUITesting() -> DashAppLock {
      let suite = "dash.ui-testing.app-lock"
      let defaults = UserDefaults(suiteName: suite) ?? .standard
      defaults.removePersistentDomain(forName: suite)
      return DashAppLock(defaults: defaults)
    }
  }
#endif

// MARK: - Cover

/// The launch screen's own ground and mark, so a locked cold launch reads as
/// one continuous screen until the unlock button arrives.
private struct DashAppLockScreen: View {
  @Environment(DashAppLock.self) private var lock

  private static let iconSize: CGFloat = 72

  var body: some View {
    ZStack {
      Color("LaunchBackground")
        .ignoresSafeArea()
      VStack(spacing: 16) {
        Image("LaunchLogo")
          .resizable()
          .scaledToFit()
          .frame(width: Self.iconSize, height: Self.iconSize)
          .clipShape(
            RoundedRectangle(
              cornerRadius: Self.iconSize * DashTheme.Radius.appIconCornerFactor,
              style: .continuous)
          )
          .accessibilityHidden(true)
        Text(DashL10n.string("Dash is locked"))
          .dashTextStyle(.sectionTitle)
          .foregroundStyle(DashTheme.strong)
          .accessibilityAddTraits(.isHeader)
      }
    }
    .safeAreaInset(edge: .bottom) {
      if let method = lock.method {
        DashPillButton(
          title: method.unlockTitle,
          phase: lock.isAuthenticating ? .loading : .idle
        ) {
          Task { await lock.unlock() }
        }
        .padding(.horizontal, DashTheme.Spacing.screen)
        .padding(.bottom, DashTheme.Spacing.section)
        .accessibilityIdentifier("app-lock-unlock")
      }
    }
  }
}

// MARK: - Window

private final class DashAppLockAnchorView: UIView {
  var onMoveToWindow: (@MainActor () -> Void)?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    onMoveToWindow?()
  }
}

/// The cover lives in its own window above everything the app presents —
/// trays are `fullScreenCover`s, QuickLook is a UIKit modal, and the toast has
/// a window of its own — none of which an overlay on the root would cover.
private struct DashAppLockInstaller: UIViewRepresentable {
  let lock: DashAppLock
  let locale: Locale
  let dynamicTypeSize: DynamicTypeSize

  struct Inputs: Equatable {
    let locale: Locale
    let dynamicTypeSize: DynamicTypeSize
  }

  private var inputs: Inputs { Inputs(locale: locale, dynamicTypeSize: dynamicTypeSize) }

  private var rootView: AnyView {
    AnyView(
      DashAppLockScreen()
        .environment(lock)
        .environment(\.locale, locale)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .tint(DashTheme.brand)
    )
  }

  func makeCoordinator() -> Coordinator { Coordinator(lock: lock) }

  func makeUIView(context: Context) -> UIView {
    let view = DashAppLockAnchorView()
    view.isUserInteractionEnabled = false
    view.backgroundColor = .clear
    view.onMoveToWindow = { [weak view, coordinator = context.coordinator] in
      coordinator.sync(scene: view?.window?.windowScene, inputs: inputs, rootView: rootView)
    }
    return view
  }

  func updateUIView(_ uiView: UIView, context: Context) {
    context.coordinator.sync(scene: uiView.window?.windowScene, inputs: inputs, rootView: rootView)
  }

  static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
    coordinator.teardown()
    coordinator.stopObserving()
  }

  @MainActor
  final class Coordinator {
    private let lock: DashAppLock
    private var window: UIWindow?
    private var host: UIHostingController<AnyView>?
    private var appliedInputs: Inputs?
    /// The app window that was key when the cover went up; it gets key back.
    private weak var coveredWindow: UIWindow?
    private var observers: [NSObjectProtocol] = []

    init(lock: DashAppLock) {
      self.lock = lock
      lock.onLockChange = { [weak self] locked in
        self?.setCovered(locked)
      }
      let center = NotificationCenter.default
      // UIKit notifications, not `scenePhase`: the cover has to be on screen
      // before the system snapshots the app for the switcher, and an
      // `onChange` lands a SwiftUI update later.
      observers.append(
        center.addObserver(
          forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.lock.didEnterBackground() }
        })
      observers.append(
        center.addObserver(
          forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.promptIfNeeded() }
        })
    }

    /// Rebuilds the root only when the locale or text size changed; the
    /// screen itself updates from observing the lock.
    func sync(scene: UIWindowScene?, inputs: Inputs, rootView: @autoclosure () -> AnyView) {
      guard let scene else { return }
      if let window, window.windowScene === scene {
        guard appliedInputs != inputs else { return }
        appliedInputs = inputs
        host?.rootView = rootView()
        return
      }
      teardown()
      appliedInputs = inputs
      let host = UIHostingController(rootView: rootView())
      let window = UIWindow(windowScene: scene)
      window.rootViewController = host
      // Above alerts and the toast layer's `.normal + 1`.
      window.windowLevel = .alert + 1
      window.isHidden = true
      self.window = window
      self.host = host
      if lock.isLocked {
        setCovered(true)
        // A locked launch may already be active by the time the window
        // exists, in which case the activation notification has come and gone.
        promptIfNeeded()
      }
    }

    private func promptIfNeeded() {
      guard UIApplication.shared.applicationState == .active else { return }
      Task { await lock.didBecomeActive() }
    }

    private func setCovered(_ covered: Bool) {
      guard let window else { return }
      if covered {
        let scene = window.windowScene
        let appWindow = scene?.keyWindow.flatMap { $0 === window ? nil : $0 }
        if let appWindow { coveredWindow = appWindow }
        // A field focused under the cover would keep its keyboard above it.
        coveredWindow?.endEditing(true)
        window.layer.removeAllAnimations()
        window.alpha = 1
        window.makeKeyAndVisible()
      } else {
        UIView.animate(
          withDuration: 0.25,
          animations: { window.alpha = 0 },
          completion: { [weak self] _ in
            guard let self, !self.lock.isLocked else { return }
            window.isHidden = true
            window.alpha = 1
            // A locked launch can cover the app before its window ever became
            // key, so there may be nothing recorded to hand key back to.
            let appWindow =
              self.coveredWindow
              ?? window.windowScene?.windows.first {
                $0 !== window && !$0.isHidden && $0.windowLevel == .normal
              }
            appWindow?.makeKey()
          })
      }
    }

    func teardown() {
      window?.isHidden = true
      window?.rootViewController = nil
      window = nil
      host = nil
      appliedInputs = nil
    }

    func stopObserving() {
      for observer in observers {
        NotificationCenter.default.removeObserver(observer)
      }
      observers = []
    }
  }
}

private struct DashAppLockModifier: ViewModifier {
  let lock: DashAppLock
  let locale: Locale
  let dynamicTypeSize: DynamicTypeSize

  func body(content: Content) -> some View {
    content.background {
      DashAppLockInstaller(lock: lock, locale: locale, dynamicTypeSize: dynamicTypeSize)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
  }
}

extension View {
  /// Installs the app lock's cover window. Call exactly once, from the app root.
  func dashAppLock(
    _ lock: DashAppLock,
    locale: Locale,
    dynamicTypeSize: DynamicTypeSize
  ) -> some View {
    modifier(DashAppLockModifier(lock: lock, locale: locale, dynamicTypeSize: dynamicTypeSize))
  }
}
