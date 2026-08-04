import CloudflareAPI
import CoreText
import SwiftUI
import UIKit
import UserNotifications

private enum OnboardingStep: Equatable {
  case welcome
  case permissions

  static var initial: Self {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-ui-preview-onboarding-permissions") {
        return .permissions
      }
    #endif
    return .welcome
  }
}

struct AppRootView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Lags `model.authState` so auth flips can animate the surface swap.
  @State private var stage: AuthenticationState? = .loading
  /// A visible auth action owns the old surface through its success icon swap.
  @State private var pendingStage: AuthenticationState?
  @State private var onboardingStep: OnboardingStep = .initial

  var body: some View {
    ZStack {
      // Matches `UILaunchScreen` / the splash canvas: visible during bootstrap
      // and for the beat between the login exit and the catalog entrance.
      Color("LaunchBackground").ignoresSafeArea()

      switch stage {
      case .unauthenticated:
        OnboardingView(step: $onboardingStep)
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
              Image("LoginAppIcon")
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
    if new == .unauthenticated {
      onboardingStep = .initial
    }
    if reduceMotion {
      stage = new
    } else {
      withAnimation(.easeOut(duration: 0.25)) { stage = new }
    }
  }
}

enum OnboardingBrandIcon {
  static let size: CGFloat = 26
  static let cornerFactor: CGFloat = 0.2237
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
  var icon = "LoginAppIcon"
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
          cornerRadius: size * OnboardingBrandIcon.cornerFactor,
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
  @Binding var step: OnboardingStep
  @Environment(AppModel.self) private var model
  @Environment(\.dashLoginIconCloaked) private var iconCloaked
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var legalDocument: LegalDocument?
  /// Flips when the splash lockup hands off (the cloak lifts), so the hero
  /// lines and footer cascade in only after the morph settles.
  @State private var revealed = false
  /// Whether the lockup takes part in the entrance reveal. False when mounted
  /// under the splash overlay (any phase before hand-off): the overlay owns
  /// the lockup's entrance, and the real lockup must sit at rest so its
  /// anchor — and the swap frame — stay exact. Sign-out remounts reveal it.
  @State private var iconJoinsReveal = false
  @State private var networkProbe = NetworkAccessProbe()
  @State private var welcomeIsVisible = OnboardingStep.initial == .welcome
  @State private var permissionsAreVisible = OnboardingStep.initial == .permissions
  @State private var isChangingStep = false
  @State private var authenticationActionOwner = UUID()

  var body: some View {
    ZStack {
      LoginBackground()
      onboardingLayout
    }
    .overlay(alignment: .topLeading) {
      if step == .permissions {
        OnboardingBackButton(action: returnToWelcome)
          .padding(.leading, 16)
          .safeAreaPadding(.top, 8)
          .opacity(permissionsAreVisible ? 1 : 0)
          .scaleEffect(permissionsAreVisible || reduceMotion ? 1 : 0.9)
          .animation(
            reduceMotion ? DashTheme.Motion.reduced : .easeOut(duration: 0.18),
            value: permissionsAreVisible
          )
          .allowsHitTesting(
            permissionsAreVisible && !isChangingStep && !ownedAuthenticationPhase.isActive
          )
      }
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
    // Network has no separate “request” dialog outside China SKUs — the first
    // probe both triggers the mainland wireless-data sheet (when needed) and
    // marks non-China devices allowed. Run it as soon as Permissions appears
    // so Connect is not gated on a manual Network tap.
    .task(id: step) {
      guard step == .permissions, networkProbe.status == .unknown else { return }
      await networkProbe.requestAccess()
    }
  }

  private var onboardingLayout: some View {
    VStack(spacing: 0) {
      if step == .welcome {
        // Welcome pins its lockup + hero slogan near the screen top; the
        // step swap happens fully faded out (`replaceStep`), so the jump
        // between this and the centered permissions layout is never seen.
        onboardingHeader
          .padding(.top, 44)
      } else {
        Spacer(minLength: 24)
        onboardingHeader
          // Offset only the heading visually so the permission cards retain
          // their existing position in the layout.
          .offset(y: permissionsHeaderOffset)
        permissionOptions
          .padding(.top, 32)
      }

      Spacer(minLength: 24)
      onboardingFooter
    }
    .frame(maxWidth: 448)
    .padding(.horizontal, 24)
    .padding(.bottom, 28)
    .frame(maxWidth: .infinity)
  }

  private var permissionsHeaderOffset: CGFloat {
    dynamicTypeSize.isAccessibilitySize ? -16 : -28
  }

  private var onboardingHeader: some View {
    Group {
      switch step {
      case .welcome:
        // Left-aligned lockup with the slogan enlarged into the page's
        // headline: brand row on top, "Cloudflare," and its tagline each on
        // their own hero line underneath.
        VStack(alignment: .leading, spacing: 10) {
          OnboardingBrandLockup(emitsIconAnchor: true)
            // Laid out while cloaked so the splash lockup can land on the
            // same frame and hand off in place.
            .opacity(iconCloaked ? 0 : 1)
            // Under the splash the lockup skips stagger — the splash overlay
            // owns its entrance. Sign-out visits stagger with the rest.
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

      case .permissions:
        VStack(spacing: 6) {
          Text(DashL10n.string("Connect safely"))
            .onboardingHeadlineFont()
            .foregroundStyle(DashTheme.strong)
            .onboardingStagger(visible: permissionsAreVisible, index: 0)
          Text(
            DashL10n.string(
              "Dash requests all permissions used by its current features in one authorization."
            )
          )
          .dashTextStyle(.supporting)
          .foregroundStyle(DashTheme.subtle)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .onboardingStagger(visible: permissionsAreVisible, index: 1)
        }
      }
    }
  }

  private var permissionOptions: some View {
    VStack(spacing: 18) {
      if let error = model.errorMessage {
        Text(error)
          .dashTextStyle(.supportingMedium)
          .foregroundStyle(DashTheme.danger)
          .multilineTextAlignment(.center)
          .onboardingStagger(visible: permissionsAreVisible, index: 2)
      }

      VStack(spacing: 20) {
        OnboardingPermissionInfoRow(
          id: "cloudflare",
          title: DashL10n.string("Cloudflare access"),
          status: DashL10n.string("Read & write"),
          subtitle: DashL10n.string(
            "Review every requested permission in Cloudflare before you authorize."
          ),
          icon: SolarAsset.cloudflare
        )
        .onboardingStagger(visible: permissionsAreVisible, index: 2)

        OnboardingPermissionRow(
          id: "network",
          title: DashL10n.string("Network"),
          subtitle: networkSubtitle,
          icon: SolarAsset.globe,
          status: networkRowStatus,
          isBusy: networkProbe.status == .probing
        ) {
          if networkProbe.status == .restricted {
            if let url = URL(string: UIApplication.openSettingsURLString) {
              UIApplication.shared.open(url)
            }
          } else {
            Task { await networkProbe.requestAccess() }
          }
        }
        .onboardingStagger(visible: permissionsAreVisible, index: 3)
      }
    }
  }

  private var onboardingFooter: some View {
    VStack(spacing: 16) {
      if !model.configuration.isConfigured {
        configCard
      }

      // App Review's path past the OAuth wall (and anyone's no-account tour):
      // a read-only session served from in-app fixtures by DemoBackend.
      // The demo is an alternative to signing in, not a way out of it, so the
      // two stay stacked instead of sharing a confirm row.
      DashTrayActionPair(axis: .vertical) {
        DashTrayTextButton(title: DashL10n.string("Explore the demo")) {
          model.enterDemo()
        }
        .disabled(ownedAuthenticationPhase.isActive || model.isEnteringDemo)
        .dashReveal(3, shown: revealed)
      } primary: {
        DashPillButton(
          title: primaryButtonTitle,
          icon: step == .permissions ? SolarAsset.cloudflare : nil,
          phase: step == .permissions ? ownedAuthenticationPhase : .idle,
          isEnabled: !model.isEnteringDemo
            && (step == .welcome
              || (model.configuration.isConfigured && networkProbe.isReadyForConnect)),
          onSuccessPresentationCompleted: {
            model.completeAuthenticationActionPresentation(owner: authenticationActionOwner)
          },
          action: primaryButtonAction
        )
        .dashReveal(4, shown: revealed)
      }

      legalCaption
        .dashReveal(5, shown: revealed)
    }
  }

  private var primaryButtonTitle: String {
    switch step {
    case .welcome: DashL10n.string("Start your engine!")
    case .permissions: DashL10n.string("Connect Cloudflare")
    }
  }

  private var ownedAuthenticationPhase: DashActionPhase {
    model.authenticationActionOwner == authenticationActionOwner
      ? model.authenticationActionPhase
      : .idle
  }

  private func primaryButtonAction() {
    guard !isChangingStep else { return }
    switch step {
    case .welcome:
      showPermissions()
    case .permissions:
      model.signIn(presentationOwner: authenticationActionOwner)
    }
  }

  private func showPermissions() {
    isChangingStep = true
    welcomeIsVisible = false

    Task { @MainActor in
      let exitDelay: Duration = reduceMotion ? .milliseconds(130) : .milliseconds(330)
      try? await Task.sleep(for: exitDelay)
      replaceStep(with: .permissions)

      try? await Task.sleep(for: .milliseconds(16))
      permissionsAreVisible = true

      let entranceDelay: Duration = reduceMotion ? .milliseconds(130) : .milliseconds(480)
      try? await Task.sleep(for: entranceDelay)
      isChangingStep = false
    }
  }

  private func returnToWelcome() {
    guard !isChangingStep else { return }
    isChangingStep = true
    permissionsAreVisible = false

    Task { @MainActor in
      let exitDelay: Duration = reduceMotion ? .milliseconds(130) : .milliseconds(390)
      try? await Task.sleep(for: exitDelay)
      replaceStep(with: .welcome)

      try? await Task.sleep(for: .milliseconds(16))
      welcomeIsVisible = true

      let entranceDelay: Duration = reduceMotion ? .milliseconds(130) : .milliseconds(430)
      try? await Task.sleep(for: entranceDelay)
      isChangingStep = false
    }
  }

  private func replaceStep(with newStep: OnboardingStep) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      step = newStep
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

  private var networkSubtitle: String {
    switch networkProbe.status {
    case .allowed:
      return DashL10n.string(
        "Use this connection to load your Cloudflare account and resource data."
      )
    case .restricted:
      return DashL10n.string(
        "Enable Wi‑Fi and cellular data in Settings to load Cloudflare resources."
      )
    case .probing:
      return DashL10n.string(
        "Checking network access for Cloudflare data…"
      )
    case .unknown:
      return DashL10n.string(
        "Connect to Cloudflare to view account information and resource status."
      )
    }
  }

  private var networkRowStatus: OnboardingPermissionRow.Status {
    switch networkProbe.status {
    case .allowed: .allowed
    case .restricted: .denied
    case .probing, .unknown: .idle
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
    .padding(.top, 20)
  }

}

private struct OnboardingStaggerModifier: ViewModifier {
  let visible: Bool
  let index: Int
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .opacity(visible ? 1 : 0)
      .offset(y: visible || reduceMotion ? 0 : 18)
      .animation(animation, value: visible)
      .allowsHitTesting(visible)
  }

  private var animation: Animation {
    if reduceMotion {
      return DashTheme.Motion.reduced
    }

    let delay = Double(index) * 0.055
    return visible
      ? .timingCurve(0.22, 1, 0.36, 1, duration: 0.3).delay(delay)
      : .timingCurve(0.4, 0, 1, 1, duration: 0.2).delay(delay)
  }
}

extension View {
  fileprivate func onboardingStagger(visible: Bool, index: Int) -> some View {
    modifier(OnboardingStaggerModifier(visible: visible, index: index))
  }

  /// Brand lockup titles (28pt base) that scale with Dynamic Type. The
  /// splash overlay passes its magnification so the enlarged wordmark keeps
  /// the lockup's exact proportions.
  fileprivate func onboardingHeadlineFont(_ magnification: CGFloat = 1) -> some View {
    modifier(OnboardingHeadlineFont(magnification: magnification))
  }

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

private struct OnboardingHeadlineFont: ViewModifier {
  var magnification: CGFloat = 1
  @ScaledMetric(relativeTo: .title) private var size: CGFloat = 28

  func body(content: Content) -> some View {
    content.font(.system(size: size * magnification, weight: .bold))
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

private struct OnboardingBackButton: View {
  let action: () -> Void
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    Group {
      if #available(iOS 26.0, *) {
        // Native circular glass button, same as the profile avatar.
        Button(action: action) { icon.padding(-7) }
          .buttonStyle(.glass)
          .buttonBorderShape(.circle)
      } else if reduceTransparency {
        styledButton
          .background(DashTheme.elevated, in: Circle())
      } else {
        styledButton
          .background(.thinMaterial, in: Circle())
          .overlay(Circle().stroke(Color.white.opacity(0.24), lineWidth: 0.5))
      }
    }
    .accessibilityLabel("Back")
    .accessibilityIdentifier("onboarding-back")
  }

  private var styledButton: some View {
    Button(action: action) { icon }
      .buttonStyle(DashPressButtonStyle())
  }

  private var icon: some View {
    SolarIcon(asset: SolarAsset.chevronLeft, size: 22, color: DashTheme.strong)
      // The chevron's visual weight sits to the right of its geometric box.
      .offset(x: -1)
      .frame(width: 44, height: 44)
      .contentShape(Circle())
  }
}

private struct OnboardingPermissionSurface: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  @ViewBuilder
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
    if reduceTransparency {
      content.background(DashTheme.elevated, in: shape)
    } else if #available(iOS 26.0, *) {
      // Non-interactive: the row is already a Button with its own press style.
      // `.interactive()` steals hits on the glass plane so only opaque subviews
      // (the icon) reach the button action.
      content.glassEffect(.regular, in: shape)
    } else {
      content
        .background(.thinMaterial, in: shape)
        .overlay(shape.stroke(Color.white.opacity(0.2), lineWidth: 0.5))
    }
  }
}

private struct OnboardingPermissionInfoRow: View {
  let id: String
  let title: String
  let status: String
  let subtitle: String
  let icon: String

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 16) {
        SolarIcon(asset: icon, size: 30, color: DashTheme.text)
          .frame(width: 38, height: 38)

        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .dashTextStyle(.bodySemibold)
            .foregroundStyle(DashTheme.text)
          Text(status)
            .dashTextStyle(.footnoteSemibold)
            .foregroundStyle(DashTheme.subtle)
            .lineLimit(1)
        }

        Spacer(minLength: 8)
        SolarIcon(asset: SolarAsset.Content.lock, size: 22, color: DashTheme.brand)
      }
      .padding(.horizontal, 18)
      .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
      .modifier(OnboardingPermissionSurface())
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("onboarding-permission-\(id)")
      .accessibilityLabel("\(title), \(status). \(subtitle)")

      Text(subtitle)
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
    }
  }
}

private struct OnboardingPermissionRow: View {
  enum Status {
    case idle
    case allowed
    case denied
  }

  /// Stable English token for UI tests / a11y identifiers (not localized).
  let id: String
  let title: String
  let subtitle: String
  let icon: String
  let status: Status
  var isBusy = false
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Button(action: action) {
        HStack(spacing: 16) {
          SolarIcon(asset: icon, size: 30, color: DashTheme.text)
            .frame(width: 38, height: 38)

          VStack(alignment: .leading, spacing: 4) {
            Text(title)
              .dashTextStyle(.bodySemibold)
              .foregroundStyle(DashTheme.text)
            Text(actionLabel)
              .dashTextStyle(.footnoteSemibold)
              .foregroundStyle(DashTheme.subtle)
              .lineLimit(1)
              .contentTransition(.opacity)
          }

          Spacer(minLength: 8)
          trailing
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .contentShape(
          RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
        )
        .modifier(OnboardingPermissionSurface())
      }
      .buttonStyle(OnboardingPermissionButtonStyle())
      .disabled(isBusy || status == .allowed)
      .accessibilityIdentifier("onboarding-permission-\(id)")
      .accessibilityLabel("\(title), \(actionLabel). \(subtitle)")

      Text(subtitle)
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
    }
  }

  private var actionLabel: String {
    if isBusy { return DashL10n.string("Requesting…") }
    switch status {
    case .allowed: return DashL10n.string("Enabled")
    case .denied: return DashL10n.string("Tap to open Settings")
    case .idle: return DashL10n.string("Tap to enable")
    }
  }

  @ViewBuilder
  private var trailing: some View {
    if isBusy || status == .allowed {
      DashActionStatusIcon(
        phase: isBusy ? .loading : .succeeded,
        loadingColor: DashTheme.strong,
        successColor: DashTheme.brand,
        size: 22
      )
    } else if status == .denied {
      SolarIcon(
        asset: SolarAsset.chevronRight,
        size: DashTheme.Chevron.row,
        color: DashTheme.placeholder
      )
    }
  }
}

private struct OnboardingPermissionButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .opacity(configuration.isPressed ? 0.82 : 1)
      .animation(
        reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.press,
        value: configuration.isPressed
      )
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
