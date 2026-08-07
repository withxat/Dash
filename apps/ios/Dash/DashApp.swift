import AppIntents
import CloudflareAPI
import SwiftDitherKit
import SwiftGlobeKit
import SwiftUI

@main
struct DashApp: App {
  @State private var model: AppModel

  init() {
    DashMetricSubscriber.shared.start()
    R2TemporaryFile.removeStaleFiles(olderThan: 60 * 60)
    // Charts and the globe both take the finger only after a hold, and both
    // announce that with a haptic. Route it through Dash's own preference so
    // one toggle still silences every buzz in the app.
    DitherHoldInteraction.onEngage = { DashDelight.gestureEngaged() }
    GlobeHoldInteraction.onEngage = { DashDelight.gestureEngaged() }
    let model = AppModel(featureCachePersistence: FeatureCachePersistence())
    _model = State(initialValue: model)
    if ICloudPreferencesSync.shouldStartForCurrentProcess {
      ICloudPreferencesSync.shared.start()
    }
    // In-app App Intents run in this process; hand them the app's own model
    // so they share its client and single-flight token refresh.
    AppDependencyManager.shared.add(dependency: model)
    LegacyWatchtowerNotificationSettings.clear()
    LegacyPagesBuildPushTokenStore.clear()
    Task { @MainActor in
      await PagesBuildActivityController.addStaleDatesToLegacyActivities()
      await DashNotificationSupport.removeLegacyGeneratedNotifications()
      await DashNotificationSupport.migrateLegacyBadgeAuthorizationIfNeeded()
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
      RootWithSplash(model: model)
        .tint(DashTheme.brand)
    }
  }
}

/// Bridges the static system launch screen into the first interactive frame:
/// same `LaunchBackground` + centered `LaunchLogo`, held until bootstrap
/// finishes (and a short minimum). Signed out, the centered icon first springs
/// down from launch-logo size to brand size, then the "Dash" wordmark expands
/// beside it, then the whole lockup glides and scales onto the welcome header
/// while the solid canvas fades to the login backdrop; signed in, everything
/// fades together.
private struct RootWithSplash: View {
  var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage(DashAppLanguage.storageKey) private var languageRaw = DashAppLanguage.system
    .rawValue
  @State private var phase: Phase = .holding
  /// Shared with the toast layer's window and with every tray that schedules a
  /// success-check flight into it.
  @State private var toastLayerState = DashToastLayerState()

  enum Phase {
    case holding, shrinking, branding, landing, done

    /// The icon is alone and centered until the shrink settles; the wordmark
    /// belongs to every phase after it.
    var showsWordmark: Bool { self != .holding && self != .shrinking }
  }

  private static let minimumDuration: Duration = .milliseconds(800)
  /// Icon shrink: under-damped on purpose, so the launch logo lands on brand
  /// size with a small overshoot instead of easing flatly into it.
  private static let shrinkDuration: TimeInterval = 0.45
  private static let shrinkDamping: Double = 0.62
  /// Lets the shrink's bounce read before the wordmark opens beside it.
  private static let shrinkHold: Duration = .milliseconds(360)
  fileprivate static let brandDuration: TimeInterval = 0.5
  /// Wordmark expansion plus a read beat before the lockup departs.
  private static let brandHold: Duration = .milliseconds(880)
  /// While branding, the wordmark renders at this fraction of lockup
  /// proportion — smaller beside the icon — and grows back to full proportion
  /// during landing.
  fileprivate static let brandWordmarkScale: CGFloat = 0.8
  private static let landDuration: TimeInterval = 0.6
  fileprivate static let holdingIconSize = OnboardingBrandTypography.launchIconSize
  /// Size the icon springs down to before the wordmark joins it. The lockup's
  /// own proportion sets the wordmark off the icon, so at launch-logo size the
  /// word "Dash" arrives near 76pt and overpowers the beat it introduces;
  /// shrinking first keeps the brand row in proportion at ~48pt.
  private static let brandIconSize: CGFloat = 56
  fileprivate static let brandScale = brandIconSize / holdingIconSize
  /// The overlay lockup lays out at launch-logo size and scales *down* onto
  /// the welcome header — supersampled, so the wordmark stays crisp through
  /// the whole morph.
  fileprivate static let magnification = OnboardingBrandTypography.launchMagnification

  private var appLanguage: DashAppLanguage {
    DashAppLanguage.resolved(stored: languageRaw)
  }

  private var effectiveDynamicTypeSize: DynamicTypeSize {
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
            SplashOverlay(
              phase: phase,
              target: anchor.map { proxy[$0] },
              containerSize: proxy.size)
          }
          .ignoresSafeArea()
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        }
      }
      .environment(model)
      .environment(\.locale, appLanguage.locale)
      .environment(\.dynamicTypeSize, effectiveDynamicTypeSize)
      .environment(\.dashToastLayerState, toastLayerState)
      .environment(\.dashSplashLifted, phase != .holding)
      .environment(\.dashLoginIconCloaked, phase != .done)
      // `DashL10n` and absolute date/time formatting resolve against the
      // in-app locale; rebinding identity applies a language change without
      // relaunching.
      .id(languageRaw)
      // Outside that identity on purpose: a language change must refresh the
      // layer's root view, not tear its window down and raise a new one under
      // a toast that is already on screen.
      .dashToastLayer(
        toastLayerState,
        model: model,
        locale: appLanguage.locale,
        dynamicTypeSize: effectiveDynamicTypeSize
      )
      .onOpenURL { url in
        if let route = DashRoute.parse(url) { model.pendingRoute = route }
      }
      .onAppear {
        appLanguage.applyToProcess()
        // The notification extension has its own defaults suite; the App Group
        // mirror is the only way the language choice reaches it.
        DashChartStylePreference.mirrorToWidgets()
        HomeActions.mirrorToAppGroup(
          UserDefaults.standard.string(forKey: HomeActions.key) ?? HomeActions.defaultValue)
      }
      .onChange(of: languageRaw) { _, _ in
        DashAppLanguage.resolved(stored: languageRaw).applyToProcess()
        DashWidgetBridges.reloadMetricsWidgets()
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
          // Shrink beat: the centered icon springs down from launch-logo size
          // to brand size, alone, before anything joins it.
          withAnimation(
            .spring(response: Self.shrinkDuration, dampingFraction: Self.shrinkDamping)
          ) {
            phase = .shrinking
          }
          try? await Task.sleep(for: Self.shrinkHold)
          // Brand beat: the wordmark expands beside the shrunken icon before
          // the lockup departs for the welcome header.
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

}

/// The launch lockup that glides onto the welcome header.
///
/// It owns `lockupSize` — the geometry action that measures it must NOT live on
/// the view that hosts `AppRootView` and reads the landing anchor. It did, and
/// every measurement re-ran the whole app tree AND re-resolved the anchor
/// preference, which moved the very lockup being measured: SwiftUI reported the
/// re-entry as "Geometry action is cycling between duplicate values". Scoping
/// the state to this leaf is the same rule the workspace wash and the header
/// scroll probe already follow — a geometry value gets exactly one reader.
private struct SplashOverlay: View {
  let phase: RootWithSplash.Phase
  /// The welcome lockup icon's frame, once onboarding is mounted underneath.
  let target: CGRect?
  let containerSize: CGSize
  /// Layout size of the magnified overlay lockup; the position/scale math
  /// needs it to keep the icon's center on target through every phase.
  @State private var lockupSize: CGSize = .zero

  var body: some View {
    let hasBackdrop = phase == .holding || phase == .shrinking || phase == .branding
    let measured = lockupSize.width > 0
    let wordmarkShown = phase.showsWordmark && target != nil
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
          .frame(width: RootWithSplash.holdingIconSize, height: RootWithSplash.holdingIconSize)
          .clipShape(
            RoundedRectangle(
              cornerRadius: RootWithSplash.holdingIconSize * OnboardingBrandIcon.cornerFactor,
              style: .continuous
            )
          )
          .position(x: containerSize.width / 2, y: containerSize.height / 2)
      }

      OnboardingBrandLockup(
        icon: "LaunchLogo",
        magnification: RootWithSplash.magnification,
        wordmarkShown: wordmarkShown,
        wordmarkScale: phase == .landing || phase == .done ? 1 : RootWithSplash.brandWordmarkScale,
        staggersWordmark: true
      )
      // Belt over the phase transaction: if the landing anchor arrives late
      // (slow bootstrap), the wordmark still expands instead of popping in.
      .animation(
        .spring(response: RootWithSplash.brandDuration, dampingFraction: 0.85), value: wordmarkShown
      )
      // `proxy` here is the LOCKUP's own geometry, not the container's — the
      // two are different proxies and the position math needs this one.
      //
      // Deadbanded like the tray's measured heights (`DashTrayMeasuredHeight`):
      // this measures a view that is ANIMATING — the wordmark springs open
      // beside the icon — and re-proposals inside a single frame hand the
      // action two values that differ by a fraction of a point, which SwiftUI
      // reports as a cycling geometry action. Real size changes here are tens
      // of points, so a sub-point gate cannot swallow one.
      .onGeometryChange(for: CGSize.self) { proxy in
        proxy.size
      } action: { size in
        guard
          DashTrayMeasuredHeight.shouldCommit(lockupSize.width, size.width)
            || DashTrayMeasuredHeight.shouldCommit(lockupSize.height, size.height)
        else { return }
        lockupSize = size
      }
      .scaleEffect(lockupScale, anchor: lockupIconAnchor)
      .position(lockupPosition)
      .opacity(measured && (hasBackdrop || target != nil) ? 1 : 0)
    }
  }

  /// Scale anchor pinned to the icon's center, so `lockupPosition` can place
  /// the icon exactly regardless of the current scale.
  private var lockupIconAnchor: UnitPoint {
    guard lockupSize.width > 0 else { return .center }
    return UnitPoint(x: RootWithSplash.holdingIconSize / 2 / lockupSize.width, y: 0.5)
  }

  /// Distance from the lockup's layout center to its icon's center.
  private var iconCenterInset: CGFloat {
    lockupSize.width / 2 - RootWithSplash.holdingIconSize / 2
  }

  /// What the branding lockup actually spans on screen: icon + gap + the
  /// wordmark at its reduced scale. The layout width overstates the group
  /// while `brandWordmarkScale` < 1, so centering and overflow math must use
  /// this instead of `lockupSize`.
  private var brandingVisualWidth: CGFloat {
    let gap = 8 * RootWithSplash.magnification
    let textWidth = max(0, lockupSize.width - RootWithSplash.holdingIconSize - gap)
    return RootWithSplash.holdingIconSize + gap + textWidth * RootWithSplash.brandWordmarkScale
  }

  /// Brand size unless the expanded lockup would still overflow the screen
  /// (large Dynamic Type), in which case the whole group contracts further to
  /// fit. Shared with the shrink phase so the icon settles on the size the
  /// wordmark then opens beside — one size change, not two.
  private var brandingScale: CGFloat {
    guard lockupSize.width > 0 else { return RootWithSplash.brandScale }
    return min(RootWithSplash.brandScale, (containerSize.width - 48) / brandingVisualWidth)
  }

  private var lockupScale: CGFloat {
    switch phase {
    case .holding:
      return 1
    case .shrinking, .branding:
      // Deliberately not gated on the landing anchor: the shrink is the
      // splash's own beat, and gating it would make a late anchor snap the
      // icon down with no animation to carry it.
      return brandingScale
    case .landing, .done:
      guard let target, target.width > 0 else { return 1 }
      return target.width / RootWithSplash.holdingIconSize
    }
  }

  private var lockupPosition: CGPoint {
    let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
    guard lockupSize.width > 0 else { return center }
    switch phase {
    case .holding, .shrinking:
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
      let scale = brandingScale
      let shift = (brandingVisualWidth - RootWithSplash.holdingIconSize) / 2 * scale
      return CGPoint(x: center.x - shift + iconCenterInset, y: center.y)
    case .landing, .done:
      guard let target else {
        return CGPoint(x: center.x + iconCenterInset, y: center.y)
      }
      return CGPoint(x: target.midX + iconCenterInset, y: target.midY)
    }
  }
}
