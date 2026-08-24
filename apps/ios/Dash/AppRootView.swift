import CloudflareAPI
import CoreText
import SwiftUI
import UIKit

struct AppRootView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Lags `model.authState` so auth flips can animate the surface swap.
  @State private var stage: AuthenticationState? = .loading
  /// A visible auth action owns the old surface through its success icon swap.
  @State private var pendingStage: AuthenticationState?

  var body: some View {
    ZStack {
      // Matches `UILaunchScreen` / the splash canvas: visible during bootstrap
      // and for the beat between the login exit and the catalog entrance.
      Color("LaunchBackground").ignoresSafeArea()

      switch stage {
      case .unauthenticated:
        OnboardingView()
          .zIndex(1)
          .transition(
            .asymmetric(
              insertion: .opacity.animation(.easeOut(duration: 0.28)),
              removal: .opacity.animation(.easeOut(duration: 0.2))
            ))
      case .authenticated:
        MainTabView()
          .transition(
            .asymmetric(
              insertion: .opacity.animation(.easeOut(duration: 0.2)),
              removal: .opacity.animation(.easeOut(duration: 0.2))
            ))
      case .loading, nil:
        // Keep the launch canvas visible until the authenticated catalog is
        // ready — never flash a blank intermediate frame.
        Color("LaunchBackground").ignoresSafeArea()
          .overlay {
            if let message = model.errorMessage {
              ContentUnavailableView {
                Label("Couldn’t load", systemImage: "exclamationmark.triangle")
              } description: {
                Text(message)
              } actions: {
                Button("Try again") {
                  Task { await model.bootstrap() }
                }
                .buttonStyle(.borderedProminent)
              }
            } else {
              Image(DashTheme.Asset.appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
            }
          }
      }
    }
    .onAppear {
      stage = model.authState
    }
    .onChange(of: model.authState) { _, new in
      if holdsCurrentStage(for: new) {
        pendingStage = new
      } else {
        present(new)
      }
    }
    .onChange(of: model.authenticationActionPhase) { _, phase in
      if phase == .idle {
        presentPendingStage(if: .authenticated)
      }
    }
    .onChange(of: model.signOutActionPhase) { _, phase in
      if phase == .idle {
        presentPendingStage(if: .unauthenticated)
      }
    }
  }

  private func holdsCurrentStage(for incoming: AuthenticationState) -> Bool {
    if stage == .unauthenticated, incoming == .authenticated {
      return model.authenticationActionPhase == .succeeded
    }
    if stage == .authenticated, incoming == .unauthenticated {
      return model.signOutActionPhase == .succeeded
    }
    return false
  }

  private func presentPendingStage(if expected: AuthenticationState) {
    guard pendingStage == expected else { return }
    pendingStage = nil
    present(expected)
  }

  private func present(_ new: AuthenticationState) {
    pendingStage = nil
    if reduceMotion {
      stage = new
    } else {
      withAnimation(.easeOut(duration: 0.25)) { stage = new }
    }
  }
}

enum OnboardingBrandIcon {
  static let size: CGFloat = 26
}

enum OnboardingBrandTypography {
  static let launchIconSize: CGFloat = 88
  static let launchMagnification = launchIconSize / OnboardingBrandIcon.size

  /// The splash lays the wordmark out large, then scales it onto the welcome
  /// header. SF's optical-size metrics are not linear, so a fresh 28pt layout
  /// is wider and flashes open at hand-off. Pin both copies to the splash's
  /// optical size while leaving their actual point sizes unchanged.
  static func wordmarkFont(baseSize: CGFloat, renderMagnification: CGFloat) -> UIFont {
    let pointSize = baseSize * renderMagnification
    let opticalSize = baseSize * launchMagnification
    let source = UIFont.systemFont(ofSize: pointSize, weight: .bold)
    let opticalSizeKey = UIFontDescriptor.AttributeName(
      rawValue: kCTFontOpticalSizeAttribute as String
    )
    let descriptor = source.fontDescriptor.addingAttributes([
      opticalSizeKey: NSNumber(value: Double(opticalSize))
    ])
    return UIFont(descriptor: descriptor, size: pointSize)
  }
}

/// The `[icon] Dash` brand lockup. One definition serves both the welcome
/// header and the launch splash overlay so the splash morph hands off onto
/// identical metrics — the overlay renders it magnified (icon at launch-logo
/// size) and scales it *down* while landing, keeping the wordmark crisp.
struct OnboardingBrandLockup: View {
  var icon = DashTheme.Asset.appIcon
  var magnification: CGFloat = 1
  /// Hidden while the splash holds; expanding it beside the centered icon is
  /// the first beat of the launch choreography.
  var wordmarkShown = true
  /// Extra scale on the wordmark alone: the splash shows it smaller than
  /// lockup proportion while branding, then grows it back to 1 during
  /// landing so the hand-off stays exact. Rendered as a transform (the
  /// layout keeps lockup proportions), so it animates smoothly.
  var wordmarkScale: CGFloat = 1
  /// Per-glyph reveal for the splash expansion (iOS 18+; earlier systems
  /// fade the whole word in).
  var staggersWordmark = false
  /// Only the onboarding instance publishes the landing target for the
  /// splash overlay — the overlay's own copy stays silent.
  var emitsIconAnchor = false

  var body: some View {
    HStack(spacing: 8 * magnification) {
      iconView
      wordmark
        // Leading anchor keeps the wordmark beside the icon and vertically
        // centered on it at every scale.
        .scaleEffect(wordmarkScale, anchor: .leading)
    }
  }

  @ViewBuilder
  private var wordmark: some View {
    let text = Text("Dash")
      .onboardingWordmarkFont(magnification)
      .foregroundStyle(DashTheme.strong)
      // Lay out at ideal width: the magnified overlay copy must never
      // truncate — `brandingScale` contracts the rendered group instead.
      .fixedSize()
    if staggersWordmark, #available(iOS 18.0, *) {
      text.textRenderer(OnboardingGlyphReveal(progress: wordmarkShown ? 1 : 0))
    } else {
      text
        .opacity(wordmarkShown ? 1 : 0)
        .offset(x: wordmarkShown ? 0 : -12 * magnification)
    }
  }

  /// Never read the compiled `AppIcon` through `UIImage(named:)`: on iOS 26
  /// it can resolve to an Icon Composer layer stack without a bitmap and crash
  /// with "Need an imageRef".
  @ViewBuilder
  private var iconView: some View {
    let size = OnboardingBrandIcon.size * magnification
    let image = Image(icon)
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .clipShape(
        RoundedRectangle(
          cornerRadius: size * DashTheme.Radius.appIconCornerFactor,
          style: .continuous
        )
      )
      .accessibilityHidden(true)
    if emitsIconAnchor {
      image.anchorPreference(key: DashLoginIconAnchorKey.self, value: .bounds) { $0 }
    } else {
      image
    }
  }
}

/// Per-glyph entrance for the splash wordmark: each letter fades up out of a
/// small leading offset and blur, staggered left to right.
@available(iOS 18.0, *)
private struct OnboardingGlyphReveal: TextRenderer, Animatable {
  /// 0 = hidden → 1 = every glyph landed. Clamped per glyph, so spring
  /// overshoot never over-drives the tail letters.
  var progress: Double

  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    let slices = layout.flatMap { line in line }.flatMap { run in run }
    guard !slices.isEmpty else { return }
    // Every glyph animates over the same fraction of the total progress;
    // start times spread across the remainder so the cascade reads left to
    // right and the last letter still gets a full window.
    let window = 0.6
    let spread = (1 - window) / Double(max(slices.count - 1, 1))
    for (index, slice) in slices.enumerated() {
      let t = min(max((progress - spread * Double(index)) / window, 0), 1)
      guard t > 0 else { continue }
      var glyph = context
      glyph.opacity = t
      glyph.translateBy(x: (t - 1) * slice.typographicBounds.rect.height * 0.2, y: 0)
      if t < 1 {
        glyph.addFilter(.blur(radius: (1 - t) * 3))
      }
      glyph.draw(slice)
    }
  }
}

private struct OnboardingView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashLoginIconCloaked) private var iconCloaked
  @State private var legalDocument: LegalDocument?
  /// Flips when the splash lockup hands off (the cloak lifts), so the hero
  /// lines and footer cascade in only after the morph settles.
  @State private var revealed = false
  /// Whether the lockup takes part in the entrance reveal. False when mounted
  /// under the splash overlay (any phase before hand-off): the overlay owns
  /// the lockup's entrance, and the real lockup must sit at rest so its
  /// anchor — and the swap frame — stay exact. Sign-out remounts reveal it.
  @State private var iconJoinsReveal = false
  @State private var welcomeIsVisible = true
  @State private var networkProbe = NetworkAccessProbe()
  @State private var isPreparingConnection = false
  @State private var connectionTask: Task<Void, Never>?
  @State private var authenticationActionOwner = UUID()

  var body: some View {
    ZStack {
      LoginBackground()
      onboardingLayout
    }
    .sheet(item: $legalDocument) { document in
      LegalDocumentView(document: document)
        .safeAreaInset(edge: .top, spacing: 0) {
          ZStack {
            Text(document.title)
              .dashTextStyle(.sectionTitle)
              .foregroundStyle(DashTheme.strong)
              .lineLimit(1)
              .padding(.horizontal, 64)
              .accessibilityAddTraits(.isHeader)
            HStack {
              Spacer(minLength: 0)
              Button("Done") { legalDocument = nil }
                .fontWeight(.semibold)
                .frame(minWidth: 44, minHeight: 44)
            }
          }
          .padding(.horizontal, DashTheme.Spacing.screen)
          .frame(height: DashPageChromeMetrics.reservedHeight)
          .background(.regularMaterial)
        }
    }
    .onAppear {
      // Keyed off the cloak, not dashSplashLifted: a slow bootstrap can mount
      // this view after the splash already advanced past .holding, and the
      // lockup must still hold still for the overlay hand-off.
      iconJoinsReveal = !iconCloaked
      if !iconCloaked { revealed = true }
    }
    .onChange(of: iconCloaked) { _, cloaked in
      if !cloaked { revealed = true }
    }
    .onDisappear {
      connectionTask?.cancel()
      connectionTask = nil
      isPreparingConnection = false
    }
  }

  private var onboardingLayout: some View {
    VStack(spacing: 0) {
      onboardingHeader
        .padding(.top, 44)

      Spacer(minLength: 24)
      onboardingFooter
    }
    .frame(maxWidth: 448)
    .padding(.horizontal, 24)
    // Sits the footer lower in the page: the action block rides nearer the
    // home indicator and the legal caption lower still.
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity)
  }

  private var onboardingHeader: some View {
    // Left-aligned lockup with the slogan enlarged into the page's headline:
    // brand row on top, then one line each for the product promise.
    VStack(alignment: .leading, spacing: 10) {
      OnboardingBrandLockup(emitsIconAnchor: true)
        // Laid out while cloaked so the splash lockup can land on the same
        // frame and hand off in place.
        .opacity(iconCloaked ? 0 : 1)
        // Under the splash the lockup skips stagger — the splash overlay owns
        // its entrance. Sign-out visits stagger with the rest.
        .dashReveal(0, shown: iconJoinsReveal ? revealed : true)
        .onboardingStagger(visible: welcomeIsVisible, index: 0)

      VStack(alignment: .leading, spacing: 0) {
        Text("Cloudflare,")
          .onboardingSloganFont(60)
          .dashReveal(1, shown: revealed)
          .onboardingStagger(visible: welcomeIsVisible, index: 1)
        Text("in your hand")
          .onboardingSloganFont()
          .dashReveal(2, shown: revealed)
          .onboardingStagger(visible: welcomeIsVisible, index: 2)
      }
      .foregroundStyle(DashTheme.strong)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var onboardingFooter: some View {
    VStack(spacing: 16) {
      if !model.configuration.isConfigured {
        configCard
      }

      if let error = model.errorMessage {
        Text(error)
          .dashTextStyle(.supportingMedium)
          .foregroundStyle(DashTheme.danger)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .dashReveal(3, shown: revealed)
      }

      if networkProbe.status == .restricted {
        DashTrayTextButton(title: DashL10n.string("Settings")) {
          guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
          UIApplication.shared.open(url)
        }
        .dashReveal(3, shown: revealed)
      }

      // App Review's path past the OAuth wall (and anyone's no-account tour):
      // a read-only session served from in-app fixtures by DemoBackend.
      // The demo is an alternative to signing in, not a way out of it, so the
      // two stay stacked instead of sharing a confirm row — opened up past the
      // tray-tight default so the text action reads as its own choice.
      DashTrayActionPair(axis: .vertical, verticalGap: 12) {
        DashTrayTextButton(
          title: DashL10n.string("Explore the demo"),
          isInteractionLocked: ownedAuthenticationPhase.isActive || model.isEnteringDemo,
          action: model.enterDemo
        )
        .dashReveal(3, shown: revealed)
      } primary: {
        DashPillButton(
          title: "Connect Cloudflare",
          activeTitle: "Start your engine!",
          isActiveTitlePresented: connectTitleIsActive,
          icon: SolarAsset.cloudflare,
          phase: ownedAuthenticationPhase,
          isEnabled: model.configuration.isConfigured,
          isInteractionLocked: model.isEnteringDemo,
          onSuccessPresentationCompleted: {
            model.completeAuthenticationActionPresentation(owner: authenticationActionOwner)
          },
          action: connectCloudflare
        )
        .accessibilityIdentifier("onboarding-connect")
        .dashReveal(4, shown: revealed)
      }

      legalCaption
        .dashReveal(5, shown: revealed)
    }
  }

  private var ownedAuthenticationPhase: DashActionPhase {
    if isPreparingConnection { return .loading }
    return model.authenticationActionOwner == authenticationActionOwner
      ? model.authenticationActionPhase
      : .idle
  }

  private var connectTitleIsActive: Bool {
    ownedAuthenticationPhase.isActive
      || (model.authState == .authenticated && !model.isDemoSession)
  }

  private func connectCloudflare() {
    guard
      model.configuration.isConfigured,
      !model.isEnteringDemo,
      !ownedAuthenticationPhase.isActive,
      connectionTask == nil
    else { return }

    model.errorMessage = nil
    isPreparingConnection = true
    connectionTask = Task { @MainActor in
      await networkProbe.requestAccess()
      guard !Task.isCancelled else {
        isPreparingConnection = false
        connectionTask = nil
        return
      }

      guard networkProbe.isReadyForConnect else {
        switch networkProbe.status {
        case .restricted:
          model.errorMessage = DashL10n.string(
            "Enable Wi‑Fi and cellular data in Settings to load Cloudflare resources."
          )
        case .unknown, .probing, .unavailable:
          model.errorMessage = DashL10n.string(
            "Dash couldn’t reach Cloudflare. Check your connection and try again."
          )
        case .allowed:
          break
        }
        isPreparingConnection = false
        connectionTask = nil
        return
      }

      // `signIn` synchronously claims the same loading phase before the local
      // preparation flag drops, so the title and trailing ring never flicker.
      model.signIn(presentationOwner: authenticationActionOwner)
      isPreparingConnection = false
      connectionTask = nil
    }
  }

  private var configCard: some View {
    DashCard {
      VStack(alignment: .leading, spacing: 8) {
        Text("Almost ready")
          .dashTextStyle(.bodySemibold)
        Text(
          "Add Config/Secrets.xcconfig with your OAuth client values, then rebuild Dash."
        )
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var legalCaption: some View {
    VStack(spacing: 6) {
      Text("By continuing, you agree to our")
      HStack(spacing: 4) {
        Button("Terms of Use") { legalDocument = .termsOfUse }
          .fontWeight(.medium)
          .foregroundStyle(DashTheme.text)
        Text("and")
        Button("Privacy Policy") { legalDocument = .privacyPolicy }
          .fontWeight(.medium)
          .foregroundStyle(DashTheme.text)
        Text(".")
      }
    }
    .dashTextStyle(.caption)
    .lineSpacing(5)
    .foregroundStyle(DashTheme.subtle)
    .multilineTextAlignment(.center)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity)
    .padding(.top, 24)
  }

}

extension View {
  fileprivate func onboardingStagger(visible: Bool, index: Int) -> some View {
    dashItemStagger(visible: visible, index: index)
  }

  /// Brand lockup titles (28pt base) that scale with Dynamic Type. The
  /// splash overlay passes its magnification so the enlarged wordmark keeps
  /// the lockup's exact proportions.
  fileprivate func onboardingWordmarkFont(_ magnification: CGFloat = 1) -> some View {
    modifier(OnboardingWordmarkFont(magnification: magnification))
  }

  /// Hero slogan (56pt base, relative to `.largeTitle`) — keeps the brand
  /// moment large at default sizes while tracking content-size changes.
  /// Pass a larger `base` for the lead line ("Cloudflare,") when it should
  /// sit above the tagline.
  fileprivate func onboardingSloganFont(_ base: CGFloat = 56) -> some View {
    modifier(OnboardingSloganFont(base: base))
  }
}

private struct OnboardingWordmarkFont: ViewModifier {
  var magnification: CGFloat = 1
  @ScaledMetric(relativeTo: .title) private var baseSize: CGFloat = 28

  func body(content: Content) -> some View {
    content.font(
      Font(
        OnboardingBrandTypography.wordmarkFont(
          baseSize: baseSize,
          renderMagnification: magnification
        )
      )
    )
  }
}

private struct OnboardingSloganFont: ViewModifier {
  var base: CGFloat = 56
  @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 56

  func body(content: Content) -> some View {
    // Scale the requested base with Dynamic Type using the 56pt metric as
    // the reference so lead + tagline stay in proportion.
    let scaled = size * (base / 56)
    content.font(.system(size: scaled, weight: .bold))
  }
}

// MARK: - Login background

/// Sign-in backdrop: Paper Design's animated mesh gradient
/// (`loginMeshGradient` in `LoginGrain.metal`). Reduce Motion keeps the still
/// wash — never a frozen mid-animation frame.
private struct LoginBackground: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    GeometryReader { geo in
      Group {
        if reduceMotion {
          LoginStaticGradient(dark: colorScheme == .dark)
        } else {
          LoginMeshGradient(dark: colorScheme == .dark, size: geo.size)
        }
      }
      .frame(width: geo.size.width, height: geo.size.height)
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Paper Mesh Gradient. Params match the shared demo (`distortion=0.8`,
/// `swirl=0.1`, `speed=1`, `scale=1`); colors come from
/// `DashTheme.LoginBackdrop.meshSpots`.
///
/// Time is seconds since this view appeared — Paper's `u_time` is a small
/// running clock. Feeding `timeIntervalSinceReferenceDate` (~1e9) makes
/// every `sin`/`cos` lose float32 precision, so the spots freeze into a
/// flat wash.
private struct LoginMeshGradient: View {
  let dark: Bool
  let size: CGSize
  @State private var startedAt = Date()

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
      Rectangle()
        .fill(Color.black)
        .colorEffect(
          Self.meshShader(
            time: context.date.timeIntervalSince(startedAt),
            dark: dark,
            size: size
          )
        )
    }
  }

  private static func meshShader(time: TimeInterval, dark: Bool, size: CGSize)
    -> Shader
  {
    let spots = DashTheme.LoginBackdrop.meshSpots(dark: dark)
    return ShaderLibrary.loginMeshGradient(
      .float(Float(time)),  // Paper u_time (seconds at speed=1)
      .float(0.8),  // distortion
      .float(0.1),  // swirl
      .float(0),  // grainMixer
      .float(0),  // grainOverlay
      .float(1),  // scale
      .float2(Float(size.width), Float(size.height)),
      Self.float4Argument(spots[0]),
      Self.float4Argument(spots[1]),
      Self.float4Argument(spots[2]),
      Self.float4Argument(spots[3])
    )
  }

  private static func float4Argument(_ v: SIMD4<Float>) -> Shader.Argument {
    .float4(v.x, v.y, v.z, v.w)
  }
}

/// Reduce Motion: the same warm palette as a still diagonal wash.
private struct LoginStaticGradient: View {
  let dark: Bool

  var body: some View {
    LinearGradient(
      colors: dark ? DashTheme.LoginBackdrop.stillDark : DashTheme.LoginBackdrop.stillLight,
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }
}
