import AppIntents
import SwiftUI

@main
struct DashApp: App {
  @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
  @State private var model: AppModel

  init() {
    DashMetricSubscriber.shared.start()
    R2TemporaryFile.removeStaleFiles(olderThan: 60 * 60)
    let model = AppModel()
    _model = State(initialValue: model)
    // In-app App Intents run in this process; hand them the app's own model
    // so they share its client and single-flight token refresh.
    AppDependencyManager.shared.add(dependency: model)

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

    // Default background keeps the system blur material, so scrolled content
    // frosts through the inline-title bar instead of hitting a flat canvas.
    let standardAppearance = UINavigationBarAppearance()
    standardAppearance.configureWithDefaultBackground()
    standardAppearance.largeTitleTextAttributes = largeTitleAttributes
    standardAppearance.titleTextAttributes = inlineTitleAttributes
    standardAppearance.shadowColor = .clear

    UINavigationBar.appearance().scrollEdgeAppearance = scrollEdgeAppearance
    UINavigationBar.appearance().standardAppearance = standardAppearance
    UINavigationBar.appearance().compactAppearance = standardAppearance

    // Minimal back chevron — same leading slot as the tab-root profile avatar.
    let backImage = UIImage(named: SolarAsset.chevronLeft)?.withRenderingMode(.alwaysTemplate)
    UINavigationBar.appearance().backIndicatorImage = backImage
    UINavigationBar.appearance().backIndicatorTransitionMaskImage = backImage

    // No UITabBar appearance proxy: the pager is `.tabViewStyle(.page)` with
    // no system tab bar, and `DashFloatingTabBar` owns all tab styling.
  }

  var body: some Scene {
    WindowGroup {
      if ProcessInfo.processInfo.arguments.contains("-uiTestKeyboardForm") {
        KeyboardDismissalTestHost()
          .tint(DashTheme.brand)
          .environment(model)
      } else {
        RootWithSplash(model: model)
          .tint(DashTheme.brand)
          .onAppear { pushDelegate.inbox = model }
      }
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
  private static let holdingIconSize: CGFloat = 88
  /// The overlay lockup lays out at launch-logo size and scales *down* onto
  /// the welcome header — supersampled, so the wordmark stays crisp through
  /// the whole morph.
  private static let magnification = holdingIconSize / OnboardingBrandIcon.size

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
      .onAppear { appLanguage.applyToProcess() }
      .onChange(of: languageRaw) { _, _ in
        DashAppLanguage.resolved(stored: languageRaw).applyToProcess()
        model.discardLocalizedCaches()
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
