import CloudflareAPI
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
            Image("LoginAppIcon")
              .resizable()
              .scaledToFit()
              .frame(width: 96, height: 96)
          }
      }
    }
    .onAppear {
      stage = model.authState
    }
    .onChange(of: model.authState) { _, new in
      // The step only resets on the sign-out edge: after sign-in the fading
      // login surface keeps rendering the permissions step (with its loading
      // ring) through the exit, and OnboardingView re-initializes its
      // visibility state on the next mount anyway.
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
}

enum OnboardingBrandIcon {
  static let size: CGFloat = 26
  static let cornerFactor: CGFloat = 0.2237
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
      .onboardingHeadlineFont(magnification)
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
  @State private var notificationsGranted = false
  @State private var notificationsDenied = false
  @State private var requestingNotifications = false
  @State private var welcomeIsVisible = OnboardingStep.initial == .welcome
  @State private var permissionsAreVisible = OnboardingStep.initial == .permissions
  @State private var isChangingStep = false
  @AppStorage(WatchtowerNotifier.optInDefaultsKey) private var watchtowerNotifications = false

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
          .allowsHitTesting(permissionsAreVisible && !isChangingStep)
      }
    }
    .sheet(item: $legalDocument) { document in
      NavigationStack {
        LegalDocumentView(document: document)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Done") { legalDocument = nil }
            }
          }
      }
    }
    .onAppear {
      // Keyed off the cloak, not dashSplashLifted: a slow bootstrap can mount
      // this view after the splash already advanced past .holding, and the
      // lockup must still hold still for the overlay hand-off.
      iconJoinsReveal = !iconCloaked
      if !iconCloaked { revealed = true }
      Task { notificationsGranted = await WatchtowerNotifier.isAuthorized() }
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
          Text(DashL10n.string("Permissions"))
            .onboardingHeadlineFont()
            .foregroundStyle(DashTheme.strong)
            .onboardingStagger(visible: permissionsAreVisible, index: 0)
          Text(
            DashL10n.string(
              "Allow network and alerts so Dash can talk to Cloudflare and keep Watchtower honest."
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
        .onboardingStagger(visible: permissionsAreVisible, index: 2)

        OnboardingPermissionRow(
          id: "notifications",
          title: DashL10n.string("Notifications"),
          subtitle: notificationsSubtitle,
          icon: SolarAsset.inbox,
          status: notificationsRowStatus,
          isBusy: requestingNotifications
        ) {
          if notificationsDenied {
            if let url = URL(string: UIApplication.openSettingsURLString) {
              UIApplication.shared.open(url)
            }
          } else {
            Task { await requestNotifications() }
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
      Button {
        model.enterDemo()
      } label: {
        Text("Explore the demo")
          .dashTextStyle(.supportingMedium)
          .foregroundStyle(DashTheme.subtle)
      }
      .buttonStyle(DashPressButtonStyle())
      .dashReveal(3, shown: revealed)

      DashPillButton(
        title: primaryButtonTitle,
        icon: step == .permissions ? SolarAsset.cloudflare : nil,
        isLoading: step == .permissions && model.isAuthenticating,
        isEnabled: step == .welcome
          || (model.configuration.isConfigured && networkProbe.isReadyForConnect),
        action: primaryButtonAction
      )
      .dashReveal(4, shown: revealed)

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

  private func primaryButtonAction() {
    guard !isChangingStep else { return }
    switch step {
    case .welcome:
      showPermissions()
    case .permissions:
      model.signIn()
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
        "View account information and manage domains, Workers, storage, and security settings."
      )
    case .restricted:
      return DashL10n.string(
        "Enable Wi‑Fi and cellular data in Settings to access and manage Cloudflare resources."
      )
    case .probing:
      return DashL10n.string(
        "Checking network access for Cloudflare data and management operations…"
      )
    case .unknown:
      return DashL10n.string(
        "Connect to Cloudflare to view account information and manage domains, Workers, storage, and security settings."
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

  private var notificationsSubtitle: String {
    if notificationsGranted {
      return DashL10n.string(
        "Build and deployment updates, security alerts, account health changes, and other important activity can appear as notifications."
      )
    }
    if notificationsDenied {
      return DashL10n.string(
        "Enable notifications in Settings to receive build updates, security alerts, and important account activity."
      )
    }
    return DashL10n.string(
      "Receive build and deployment updates, security alerts, account health changes, and other important activity."
    )
  }

  private var notificationsRowStatus: OnboardingPermissionRow.Status {
    if notificationsGranted { return .allowed }
    if notificationsDenied { return .denied }
    return .idle
  }

  private func requestNotifications() async {
    requestingNotifications = true
    let granted = await WatchtowerNotifier.requestAuthorization()
    notificationsGranted = granted
    if granted {
      watchtowerNotifications = true
      notificationsDenied = false
    } else {
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      notificationsDenied = settings.authorizationStatus == .denied
    }
    requestingNotifications = false
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

  /// Hero slogan (56pt base, relative to `.largeTitle`) — keeps the brand
  /// moment large at default sizes while tracking content-size changes.
  /// Pass a larger `base` for the lead line ("Cloudflare,") when it should
  /// sit above the tagline.
  fileprivate func onboardingSloganFont(_ base: CGFloat = 56) -> some View {
    modifier(OnboardingSloganFont(base: base))
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
    if isBusy {
      DashLoadingRing(color: DashTheme.strong)
    } else {
      switch status {
      case .allowed:
        SolarIcon(asset: SolarAsset.checkCircle, size: 22, color: DashTheme.brand)
      case .denied:
        SolarIcon(
          asset: SolarAsset.chevronRight, size: DashTheme.Chevron.row, color: DashTheme.placeholder)
      case .idle:
        EmptyView()
      }
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

/// Sign-in backdrop: a drifting warm mesh gradient (iOS 18+) under a static
/// Metal film grain (`LoginGrain.metal`). iOS 17 and Reduce Motion get the
/// still gradient with the same grain — never a frozen mid-animation frame.
private struct LoginBackground: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if #available(iOS 18.0, *), !reduceMotion {
        LoginMeshGradient(dark: colorScheme == .dark)
      } else {
        LoginStaticGradient(dark: colorScheme == .dark)
      }
    }
    .colorEffect(ShaderLibrary.surfaceGrain(.float(0.12)))
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

@available(iOS 18.0, *)
private struct LoginMeshGradient: View {
  let dark: Bool

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
      mesh(at: context.date.timeIntervalSinceReferenceDate)
    }
  }

  private func mesh(at t: TimeInterval) -> MeshGradient {
    MeshGradient(
      width: 3, height: 3,
      points: Self.points(at: t),
      colors: Self.colors(at: t, dark: dark)
    )
  }

  /// Every vertex breathes between the airy and deep keyframe palettes on its
  /// own phase, so somewhere on the canvas is always mid-shift — the color
  /// change reads even when a single vertex happens to rest.
  private static func colors(at t: TimeInterval, dark: Bool) -> [Color] {
    DashTheme.LoginBackdrop.meshColors(dark: dark) { index in
      0.5 + 0.5 * sin(t * 0.8 + Double(index) * 1.9)
    }
  }

  /// Edge points keep their pinned axis so the mesh always covers the canvas;
  /// the free axes and the center drift on slow, unsynchronized waves.
  private static func points(at t: TimeInterval) -> [SIMD2<Float>] {
    func wave(_ speed: Double, _ phase: Double, _ amplitude: Double) -> Float {
      Float(0.5 + amplitude * sin(t * speed + phase))
    }
    return [
      [0, 0], [wave(0.85, 0.0, 0.34), 0], [1, 0],
      [0, wave(0.70, 1.3, 0.32)],
      [wave(0.95, 2.1, 0.38), wave(0.60, 4.2, 0.36)],
      [1, wave(0.65, 5.1, 0.32)],
      [0, 1], [wave(0.80, 3.4, 0.34), 1], [1, 1],
    ]
  }

}

/// iOS 17 fallback: the same warm palette as a still diagonal wash.
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

private enum AppTab: Hashable { case home, features, watchtower }

private struct MainTabView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selection: AppTab = .home
  @State private var homeNavigator = DestinationNavigator()
  @State private var featuresNavigator = DestinationNavigator()
  @State private var watchtowerNavigator = DestinationNavigator()
  @State private var watchtowerCustomization = WatchtowerChartCustomizationState()
  @State private var showsProfile = false
  @State private var showsIgnoreAllAlerts = false
  @State private var nestedTray = DashTrayPresentation()

  /// Every tray style currently over this canvas — the pages' trays plus the
  /// profile tray (whose preference sits above our reader, so it's OR-ed in).
  private var overlayTrays: DashTrayPresentation {
    DashTrayPresentation(
      content: showsProfile || showsIgnoreAllAlerts || nestedTray.content,
      large: nestedTray.large)
  }

  private var hidesDock: Bool {
    shouldHideTabBar(
      overlays: overlayTrays,
      navigationDepth: activeNavigationDepth
    ) || watchtowerCustomization.isEditing
  }

  private var hidesHeaderAvatar: Bool {
    shouldHideHeaderAvatar(
      overlays: overlayTrays,
      navigationDepth: activeNavigationDepth
    ) || watchtowerCustomization.isEditing
  }

  /// Floated Watchtower inbox — same hide rules as the avatar, Watchtower root only.
  private var showsWatchtowerInboxButton: Bool {
    selection == .watchtower
      && model.activeAccountID != nil
      && !hidesHeaderAvatar
  }

  private var showsWatchtowerCustomizeButton: Bool {
    showsWatchtowerInboxButton && !watchtowerCustomization.isEditing
  }

  private var showsWatchtowerEditHeader: Bool {
    selection == .watchtower
      && watchtowerCustomization.isEditing
      && activeNavigationDepth == 0
      && !overlayTrays.presented
  }

  /// Pages swipe only between the tab roots. A pushed feature/detail owns
  /// horizontal gestures (the leading-edge back swipe must win), and an open
  /// tray freezes the canvas underneath it. Enforced via `TabPagerScrollLock`
  /// (pan recognizer only — never `scrollDisabled` / `isScrollEnabled`).
  private var pagerLocked: Bool {
    activeNavigationDepth > 0 || overlayTrays.presented || watchtowerCustomization.isEditing
  }

  private var activeNavigationDepth: Int {
    switch selection {
    case .home: homeNavigator.depth
    case .features: featuresNavigator.depth
    case .watchtower: watchtowerNavigator.depth
    }
  }

  private var activeNavigator: DestinationNavigator {
    switch selection {
    case .home: homeNavigator
    case .features: featuresNavigator
    case .watchtower: watchtowerNavigator
    }
  }

  private func openOnActiveTab(_ destination: Destination) {
    activeNavigator.push(destination)
  }

  private func beginWatchtowerCustomization() {
    withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
      watchtowerCustomization.beginEditing()
    }
  }

  private func cancelWatchtowerCustomization() {
    withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
      watchtowerCustomization.cancelEditing()
    }
  }

  private func commitWatchtowerCustomization() {
    withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
      watchtowerCustomization.commitEditing()
    }
    DashDelight.selectionChanged()
  }

  /// Profile-tray Debug row. Nil in Release so the menu omits it.
  private var openDebugFromProfileTray: (() -> Void)? {
    #if DEBUG
      {
        showsProfile = false
        openOnActiveTab(.debug)
      }
    #else
      nil
    #endif
  }

  /// Applies a buffered deep link: bare tab switch for Watchtower, else jump
  /// to Home and open the destination on a fresh navigation stack.
  private func consume(_ route: DashRoute) {
    switch route {
    case .watchtower:
      selection = .watchtower
      watchtowerNavigator.reset()
    default:
      guard let destination = route.destination else { break }
      selection = .home
      homeNavigator.reset(to: destination)
    }
    model.pendingRoute = nil
  }

  var body: some View {
    tabContainer
      .onPreferenceChange(TrayPresentedPreferenceKey.self) { nestedTray = $0 }
      .onChange(of: scenePhase) { _, phase in
        switch phase {
        case .active:
          Task {
            await model.retryIdentityIfNeeded()
            await model.refreshWatchtowerIfStale()
          }
        case .background:
          model.scheduleWatchtowerBackgroundRefresh()
        default:
          break
        }
      }
      // Warms the Watchtower badge once per account, before the tab is
      // ever visited.
      .task(id: model.activeAccountID) {
        // A cold-launch deep link is set before this view mounts, so onChange
        // never fires for it — drain the inbox on first appearance too.
        if let route = model.pendingRoute { consume(route) }
        await model.refreshWatchtowerIfStale()
      }
      .onChange(of: model.pendingRoute) { _, route in
        if let route { consume(route) }
      }
      .onChange(of: model.activeAccountID) { _, _ in
        homeNavigator.reset()
        featuresNavigator.reset()
        watchtowerNavigator.reset()
        watchtowerCustomization.cancelEditing()
        showsProfile = false
        showsIgnoreAllAlerts = false
      }
      .dashTray(isPresented: $showsProfile, title: DashL10n.string("Profile")) {
        ProfileTrayContent(
          openProfile: {
            showsProfile = false
            openOnActiveTab(.profile)
          },
          openSettings: {
            showsProfile = false
            openOnActiveTab(.settings)
          },
          openDebug: openDebugFromProfileTray
        )
      }
      .dashTray(
        isPresented: $showsIgnoreAllAlerts,
        title: DashL10n.string("Ignore all alerts")
      ) {
        WatchtowerIgnoreAllTray(count: model.watchtowerIssueCount ?? 0) {
          model.ignoreAllWatchtowerAlerts()
          DashDelight.recoverFromIssue()
        }
      }
  }

  /// The three tab canvases ride in a paging `TabView`, so a horizontal drag
  /// on any root slides between them with the finger. Every page stays mounted
  /// (paging needs neighbors renderable mid-drag), which also keeps state and
  /// in-flight loads alive across switches. A custom floating bar floats over
  /// the content — sliding away when a pushed route or overlay wants the space.
  private var tabContainer: some View {
    // Chrome animations stay on avatar/dock subtrees only. A ZStack-wide
    // `.animation(value:)` lands in the same transaction as `NavigationStack`
    // path updates and retargets the UIKit push onto a SwiftUI fade.
    ZStack(alignment: .bottom) {
      TabView(selection: $selection) {
        tabPage(.home) {
          DestinationStackHost(
            navigator: homeNavigator,
            isTabActive: selection == .home
          ) {
            HomeView()
          }
        }
        tabPage(.features) {
          DestinationStackHost(
            navigator: featuresNavigator,
            isTabActive: selection == .features
          ) {
            FeatureCatalogView()
          }
        }
        tabPage(.watchtower) {
          DestinationStackHost(
            navigator: watchtowerNavigator,
            isTabActive: selection == .watchtower
          ) {
            WatchtowerView(customization: watchtowerCustomization)
          }
        }
      }
      .tabViewStyle(.page(indexDisplayMode: .never))
      // Full-bleed pages: top so Home's in-page wash can cover the status bar
      // (a behind-pager wash can't ride the push; a clipped page can't paint
      // the status bar), bottom so the home-indicator band isn't a white
      // scroll-edge pocket. Content still lays out in the safe area; only the
      // page chrome extends. The floating dock sits on top.
      .ignoresSafeArea(edges: [.top, .bottom])
      // Lock ONLY the pager's pan recognizer. Do NOT use SwiftUI
      // `scrollDisabled` here and do NOT flip `isScrollEnabled` on the
      // UICollectionView — both freeze nested feature-list scrolling while a
      // detail is pushed (environment leak / parent scroll-view hit testing).
      .background { TabPagerScrollLock(locked: pagerLocked) }
      // Depth flips with every push/pop; keep those updates off SwiftUI's
      // animation system so UIKit owns the slide.
      .animation(nil, value: homeNavigator.depth)
      .animation(nil, value: featuresNavigator.depth)
      .animation(nil, value: watchtowerNavigator.depth)

      // ONE shared avatar above the pager (so it doesn't slide on tab swipes,
      // and stays a true circle — toolbar items get height-clamped). It sits
      // over the leading slot of the roots' titleless nav bars and fades on
      // push exactly where the system back control fades in. Watchtower's
      // inbox mirror sits on the trailing edge with the same metrics.
      ZStack {
        ZStack(alignment: .topLeading) {
          if showsWatchtowerEditHeader {
            DashToolbarTextButton(
              title: DashL10n.string("Cancel"),
              action: cancelWatchtowerCustomization
            )
            .accessibilityIdentifier("watchtower-customize-cancel")
            .padding(.leading, 10)
            .padding(.top, 10)
            .transition(.opacity)
          } else if !hidesHeaderAvatar {
            HeaderProfileButton { showsProfile = true }
              // Tuned against the system back control's measured slot so the
              // push crossfade reads as the avatar becoming the back button.
              .padding(.leading, 10)
              .padding(.top, 10)
              .transition(.opacity)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        ZStack(alignment: .topTrailing) {
          if showsWatchtowerEditHeader {
            DashToolbarTextButton(
              title: DashL10n.string("Done"),
              action: commitWatchtowerCustomization
            )
            .accessibilityIdentifier("watchtower-customize-done")
            .padding(.trailing, 10)
            .padding(.top, 10)
            .transition(.opacity)
          } else if showsWatchtowerInboxButton {
            HStack(spacing: 8) {
              if showsWatchtowerCustomizeButton {
                HeaderWatchtowerCustomizeButton(action: beginWatchtowerCustomization)
              }
              HeaderInboxButton(
                count: model.watchtowerIssueCount ?? 0,
                action: { watchtowerNavigator.push(.watchtowerInbox) },
                onLongPress: { showsIgnoreAllAlerts = true }
              )
            }
            .padding(.trailing, 10)
            .padding(.top, 10)
            .transition(.opacity)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      }
      .animation(tabBarVisibilityAnimation, value: hidesHeaderAvatar)
      .animation(tabBarVisibilityAnimation, value: showsWatchtowerInboxButton)
      .animation(tabBarVisibilityAnimation, value: showsWatchtowerEditHeader)
      .allowsHitTesting(
        !hidesHeaderAvatar || showsWatchtowerInboxButton || showsWatchtowerEditHeader)

      // Trays and pushed routes displace the bar; tab roots keep it mounted.
      ZStack(alignment: .bottom) {
        if !hidesDock {
          DashFloatingTabBar(
            selection: $selection,
            watchtowerIssueCount: model.watchtowerIssueCount ?? 0,
            onReselect: popActiveTabToRoot,
            onRequestIgnoreAllAlerts: { showsIgnoreAllAlerts = true }
          )
          .frame(maxWidth: .infinity)
          // Do NOT ignoresSafeArea(bottom) here — on iOS 26 that registers as a
          // bottom bar and paints a white scroll-edge pocket under the capsule.
          // Offset sinks the bar into the home-indicator inset instead.
          .offset(y: DashDockMetrics.bottomSink)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(tabBarVisibilityAnimation, value: hidesDock)
      .allowsHitTesting(!hidesDock)
    }
    .background(DashTheme.canvas.ignoresSafeArea())
    .dashToastHost()
  }

  /// One page of the tab pager. Off-screen pages stay mounted for the
  /// mid-drag preview and hide from the accessibility tree — inactive tabs
  /// stay off VoiceOver and, mostly, off XCTest queries (the tests still
  /// guard against duplicate labels).
  private func tabPage<Content: View>(
    _ tab: AppTab,
    @ViewBuilder content: () -> Content
  ) -> some View {
    let isActive = selection == tab
    return content()
      .tag(tab)
      .accessibilityHidden(!isActive)
      .accessibilityElement(children: isActive ? .contain : .ignore)
  }

  /// The floating bar rides in on first appearance without animation and slides
  /// on later navigation changes — SwiftUI only animates the value that flips.
  private var tabBarVisibilityAnimation: Animation {
    reduceMotion ? DashTheme.Motion.reduced : .spring(response: 0.3, dampingFraction: 0.88)
  }

  /// Re-tapping the active tab clears its navigation path, matching `TabView`.
  private func popActiveTabToRoot() {
    activeNavigator.popToRoot()
  }
}

/// Disables the page `TabView`'s horizontal paging pan while a pushed screen
/// or tray owns the canvas. Recent iOS backs the pager with a
/// `UICollectionView` (`isPagingEnabled` often false) — detect by geometry,
/// and keep re-applying while locked (SwiftUI rebuilds re-enable the pan).
///
/// Only the pan recognizer is toggled. Flipping `isScrollEnabled` (or using
/// SwiftUI `scrollDisabled` on the `TabView`) freezes nested feature lists
/// inside the page cells.
private struct TabPagerScrollLock: UIViewRepresentable {
  var locked: Bool

  func makeUIView(context: Context) -> TabPagerScrollLockView {
    TabPagerScrollLockView()
  }

  func updateUIView(_ uiView: TabPagerScrollLockView, context: Context) {
    uiView.setLocked(locked)
  }
}

private final class TabPagerScrollLockView: UIView {
  nonisolated(unsafe) private var displayLink: CADisplayLink?
  private let linkProxy = DisplayLinkProxy()
  private var locked = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isHidden = true
    backgroundColor = .clear
    linkProxy.owner = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)
    if newWindow == nil {
      stopLink()
    }
  }

  func setLocked(_ locked: Bool) {
    self.locked = locked
    apply()
    if locked {
      startLink()
    } else {
      // One more pass after unlock so a rebuilt pager isn't left disabled.
      DispatchQueue.main.async { [weak self] in
        self?.apply()
        self?.stopLink()
      }
    }
  }

  fileprivate func handleTick() {
    apply()
    if !locked {
      stopLink()
    }
  }

  private func startLink() {
    guard displayLink == nil else { return }
    let link = CADisplayLink(target: linkProxy, selector: #selector(DisplayLinkProxy.tick))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func stopLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  private func apply() {
    guard let pager = Self.findTabPager(from: self) else { return }
    // Keep scrolling enabled so nested lists inside page cells still receive
    // vertical pans; only the pager's own pan recognizer is gated.
    if !pager.isScrollEnabled {
      pager.isScrollEnabled = true
    }
    if let collection = pager as? UICollectionView, collection.alwaysBounceVertical {
      collection.alwaysBounceVertical = false
    }
    let panEnabled = !locked
    if pager.panGestureRecognizer.isEnabled != panEnabled {
      pager.panGestureRecognizer.isEnabled = panEnabled
    }
  }

  /// Walk ancestors and shallow children for the three-tab pager. Do not deep-
  /// search page content — feature screens can host their own horizontal
  /// scrolls.
  private static func findTabPager(from view: UIView) -> UIScrollView? {
    var node: UIView? = view
    while let current = node {
      if let scroll = current as? UIScrollView, isTabPager(scroll) {
        return scroll
      }
      for child in current.subviews {
        if let scroll = child as? UIScrollView, isTabPager(scroll) {
          return scroll
        }
        for grand in child.subviews {
          if let scroll = grand as? UIScrollView, isTabPager(scroll) {
            return scroll
          }
        }
      }
      node = current.superview
    }
    return nil
  }

  private static func isTabPager(_ scroll: UIScrollView) -> Bool {
    DashScrollViewConfigurator.isTabPager(scroll)
  }

  // `@MainActor`: the link is added to the `.main` run loop, so `tick` always
  // fires on the main thread — declare it so `handleTick()` is callable.
  @MainActor
  private final class DisplayLinkProxy: NSObject {
    weak var owner: TabPagerScrollLockView?
    @objc func tick() { owner?.handleTick() }
  }
}

extension AppTab {
  /// Fixed left-to-right order of the primary tabs.
  static let orderedCases: [AppTab] = [.home, .features, .watchtower]

  /// Doubles as the VoiceOver label and the UI-test accessibility identifier.
  var title: String {
    switch self {
    case .home: DashL10n.string("Home")
    case .features: DashL10n.string("Resources")
    case .watchtower: DashL10n.string("Watchtower")
    }
  }

  /// Solar glyph asset name; the filled variant marks the active tab.
  func asset(filled: Bool) -> String {
    switch self {
    case .home: filled ? "SolarTabHomeFill" : "SolarTabHomeLine"
    case .features: filled ? "SolarTabFeaturesFill" : "SolarTabFeaturesLine"
    case .watchtower: filled ? "SolarTabWatchtowerFill" : "SolarTabWatchtowerLine"
    }
  }
}

/// A floating tab bar. Selection is icon-only (fill + brand tint). Geometry
/// lives in `DashDockMetrics`. Watchtower with an active inbox long-presses into
/// the shared Ignore-all confirmation tray.
private struct DashFloatingTabBar: View {
  @Binding var selection: AppTab
  let watchtowerIssueCount: Int
  let onReselect: () -> Void
  var onRequestIgnoreAllAlerts: () -> Void = {}
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var tabs: [AppTab] { AppTab.orderedCases }
  private var barWidth: CGFloat { DashDockMetrics.cell * CGFloat(tabs.count) }

  var body: some View {
    ZStack {
      trayBackground
      row
    }
    .frame(width: barWidth, height: DashDockMetrics.height)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(DashL10n.string("Tabs"))
  }

  private var trayBackground: some View {
    Capsule(style: .continuous)
      .fill(DashTheme.tabBarSurface)
      .frame(width: barWidth, height: DashDockMetrics.height)
      .compositingGroup()
      .dashShadow(.raised, in: Capsule(style: .continuous))
      .allowsHitTesting(false)
  }

  private var row: some View {
    HStack(spacing: 0) {
      ForEach(tabs, id: \.self) { tab in
        tabButton(tab)
      }
    }
    .frame(width: barWidth, height: DashDockMetrics.height)
  }

  @ViewBuilder
  private func tabButton(_ tab: AppTab) -> some View {
    let isActive = selection == tab
    let canIgnore = tab == .watchtower && watchtowerIssueCount > 0
    let button = Button {
      select(tab, isActive: isActive)
    } label: {
      DashTabIcon(
        tab: tab,
        isActive: isActive,
        issueCount: tab == .watchtower ? watchtowerIssueCount : 0
      )
      .frame(width: DashDockMetrics.cell, height: DashDockMetrics.height)
      .contentShape(Rectangle())
    }
    .buttonStyle(DashTabPressButtonStyle())
    .accessibilityIdentifier(tab.title)
    .accessibilityLabel(accessibilityLabel(for: tab))
    .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)

    if canIgnore {
      button
        .simultaneousGesture(
          LongPressGesture(minimumDuration: 0.35).onEnded { _ in
            DashDelight.lightImpact()
            onRequestIgnoreAllAlerts()
          }
        )
        .accessibilityHint(DashL10n.string("Long press to ignore all alerts"))
        .accessibilityAction(named: DashL10n.string("Ignore all alerts")) {
          onRequestIgnoreAllAlerts()
        }
    } else {
      button
    }
  }

  private func select(_ tab: AppTab, isActive: Bool) {
    if isActive {
      onReselect()
    } else {
      withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88)) {
        selection = tab
      }
    }
  }

  private func accessibilityLabel(for tab: AppTab) -> String {
    guard tab == .watchtower, watchtowerIssueCount > 0 else { return tab.title }
    let alertSummary =
      watchtowerIssueCount == 1
      ? DashL10n.string("1 alert")
      : DashL10n.string("\(watchtowerIssueCount) alerts")
    return "\(tab.title), \(alertSummary)"
  }
}

/// Tab-bar press — same 0.97 shrink + light haptic as `DashPressButtonStyle`;
/// active tint lives on `DashTabIcon` (Line↔Fill crossfade + subtle selected scale).
private struct DashTabPressButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .animation(
        reduceMotion ? nil : DashTheme.Motion.press,
        value: configuration.isPressed
      )
      .onChange(of: configuration.isPressed) { _, pressed in
        if pressed { DashDelight.lightImpact() }
      }
  }
}

/// One tab glyph: a Line↔Fill crossfade tinted brand when active, with a
/// Watchtower presence dot (count lives on the floating inbox control).
private struct DashTabIcon: View {
  let tab: AppTab
  let isActive: Bool
  let issueCount: Int

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var iconAnimation: Animation {
    reduceMotion
      ? DashTheme.Motion.reduced
      : .spring(response: 0.3, dampingFraction: 0.58)
  }

  var body: some View {
    ZStack {
      glyph(filled: false).opacity(isActive ? 0 : 1)
      glyph(filled: true).opacity(isActive ? 1 : 0)
    }
    .foregroundStyle(isActive ? DashTheme.brand : DashTheme.iconMuted)
    .scaleEffect(isActive && !reduceMotion ? 1.02 : 1)
    .animation(iconAnimation, value: isActive)
    .overlay(alignment: .topTrailing) { badge }
  }

  private func glyph(filled: Bool) -> some View {
    Image(tab.asset(filled: filled))
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .frame(width: 26, height: 26)
  }

  @ViewBuilder
  private var badge: some View {
    if issueCount > 0 {
      Circle()
        .fill(DashTheme.danger)
        .frame(width: 8, height: 8)
        .offset(x: 3, y: -2)
        .accessibilityHidden(true)
    }
  }
}

/// Workspace routes and any open tray hide the floating tab bar so the card
/// can slide up from the bottom without fighting the dock.
func shouldHideTabBar(
  overlays: DashTrayPresentation,
  navigationDepth: Int
) -> Bool {
  navigationDepth > 0 || overlays.presented
}

/// The floating header avatar clears out for any overlay or pushed route.
func shouldHideHeaderAvatar(
  overlays: DashTrayPresentation,
  navigationDepth: Int
) -> Bool {
  navigationDepth > 0 || overlays.presented
}

struct ProfileTrayContent: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Dismisses the tray and pushes the Profile page onto the active tab.
  let openProfile: () -> Void
  let openSettings: () -> Void
  /// DEBUG-only: dismisses the tray and pushes the Debug playground.
  var openDebug: (() -> Void)? = nil
  @State private var phase: ProfileTrayPhase = .menu
  @State private var isSigningOut = false

  private var morphAnimation: Animation {
    reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morph
  }

  var body: some View {
    ZStack {
      switch phase {
      case .menu:
        menu
          .transition(reduceMotion ? .opacity : .dashMorph)
      case .accounts:
        accountList
          .transition(reduceMotion ? .opacity : .dashMorph)
      case .switchAccount(let account):
        accountSwitchConfirmation(account)
          .transition(reduceMotion ? .opacity : .dashMorph)
      case .signOut:
        signOutConfirmation
          .transition(reduceMotion ? .opacity : .dashMorph)
      }
    }
    .dashTrayTitle(phase.title)
  }

  private var menu: some View {
    VStack(spacing: 20) {
      HStack(spacing: 16) {
        UserAvatar(email: model.user?.email ?? "", size: 56)
        VStack(alignment: .leading, spacing: 4) {
          Text(model.profileTitle)
            .dashTextStyle(.bodySemibold)
          if let email = model.user?.email, email != model.profileTitle {
            Text(email)
              .dashTextStyle(.supporting)
              .foregroundStyle(DashTheme.subtle)
          }
          if let account = model.activeAccount, account.name != model.profileTitle {
            Text(account.name)
              .dashTextStyle(.footnote)
              .foregroundStyle(DashTheme.placeholder)
          }
        }
        Spacer(minLength: 0)
      }

      VStack(spacing: 10) {
        menuRow(
          title: DashL10n.string("Profile"), icon: SolarAsset.user, action: openProfile)
        menuRow(
          title: DashL10n.string("Settings"), icon: SolarAsset.settings, action: openSettings)
        #if DEBUG
          if let openDebug {
            menuRow(title: "Debug", icon: SolarAsset.code, action: openDebug)
          }
        #endif
        if model.accounts.count > 1 {
          menuRow(title: DashL10n.string("Switch account"), icon: SolarAsset.users) {
            withAnimation(morphAnimation) { phase = .accounts }
          }
        }

        menuRow(
          title: DashL10n.string("Sign out"), icon: SolarAsset.danger, tint: DashTheme.danger
        ) {
          withAnimation(morphAnimation) { phase = .signOut }
        }
      }
    }
  }

  private var accountList: some View {
    VStack(spacing: 16) {
      VStack(spacing: 10) {
        ForEach(model.accounts) { account in
          Button {
            if account.id == model.activeAccountID {
              dismiss()
              return
            }
            withAnimation(morphAnimation) { phase = .switchAccount(account) }
          } label: {
            HStack(spacing: 12) {
              Text(account.name)
                .dashTextStyle(.bodyMedium)
                .foregroundStyle(DashTheme.text)
                .lineLimit(1)
              Spacer(minLength: 0)
              SolarIcon(
                asset: account.id == model.activeAccountID
                  ? SolarAsset.checkCircleFill : SolarAsset.circle,
                size: 22,
                color: account.id == model.activeAccountID
                  ? DashTheme.brand : DashTheme.placeholder)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DashTheme.Sheet.shortcutItem, in: DashTheme.buttonShape)
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityAddTraits(account.id == model.activeAccountID ? .isSelected : [])
        }
      }

      Button {
        withAnimation(morphAnimation) { phase = .menu }
      } label: {
        Text(DashL10n.string("Back"))
          .dashTextStyle(.buttonMedium)
          .foregroundStyle(DashTheme.subtle)
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(DashPressButtonStyle())
    }
  }

  private func accountSwitchConfirmation(_ account: CloudflareAccount) -> some View {
    VStack(spacing: 16) {
      Text(
        DashL10n.string(
          "Switch to \(account.name)? Cached data and open screens for the current account will reset."
        )
      )
      .dashTextStyle(.supporting)
      .foregroundStyle(DashTheme.subtle)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity)
      .padding(.top, 4)

      VStack(spacing: 4) {
        Button {
          withAnimation(morphAnimation) { phase = .accounts }
        } label: {
          Text(DashL10n.string("Cancel"))
            .dashTextStyle(.buttonMedium)
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(DashPressButtonStyle())

        DashActionButton(title: DashL10n.string("Switch account")) {
          model.selectAccount(account)
          dismiss()
        }
      }
    }
  }

  private var signOutConfirmation: some View {
    VStack(spacing: 16) {
      Text(DashL10n.string("You'll need to reconnect your Cloudflare account to use Dash again."))
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)

      VStack(spacing: 4) {
        Button {
          withAnimation(morphAnimation) { phase = .menu }
        } label: {
          Text(DashL10n.string("Cancel"))
            .dashTextStyle(.buttonMedium)
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(DashPressButtonStyle())
        .disabled(isSigningOut)

        DashActionButton(
          title: DashL10n.string("Sign out"),
          role: .destructive,
          isLoading: isSigningOut
        ) {
          Task {
            isSigningOut = true
            await model.signOut()
            isSigningOut = false
            dismiss()
          }
        }
      }
    }
  }

  private func menuRow(
    title: String, icon: String, tint: Color = DashTheme.iconMuted,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        SolarIcon(asset: icon, size: 22, color: tint)
        Text(title)
          .dashTextStyle(.bodyMedium)
          .foregroundStyle(tint == DashTheme.danger ? DashTheme.danger : DashTheme.text)
          .lineLimit(1)
        Spacer(minLength: 0)
        SolarIcon(
          asset: SolarAsset.chevronRight, size: DashTheme.Chevron.row, color: DashTheme.placeholder)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(DashTheme.Sheet.shortcutItem, in: DashTheme.buttonShape)
    }
    .buttonStyle(DashSurfaceButtonStyle())
  }
}

enum ProfileTrayPhase: Equatable, Sendable {
  case menu
  case accounts
  case switchAccount(CloudflareAccount)
  case signOut

  var title: String {
    switch self {
    case .menu: DashL10n.string("Profile")
    case .accounts, .switchAccount: DashL10n.string("Switch account")
    case .signOut: DashL10n.string("Sign out")
    }
  }
}

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @AppStorage(WatchtowerNotifier.optInDefaultsKey) private var watchtowerNotifications = false
  @AppStorage(DashAppLanguage.storageKey) private var languageRaw = DashAppLanguage.system.rawValue
  @AppStorage(DashInteractionPreferences.hapticsKey) private var hapticsEnabled = true
  @AppStorage(DashInteractionPreferences.holdToConfirmKey) private var holdToConfirmEnabled =
    true
  @State private var watchtowerNotificationsDenied = false
  @State private var showsLanguagePicker = false

  private var selectedLanguage: DashAppLanguage {
    DashAppLanguage.resolved(stored: languageRaw)
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        DashListGroup(title: "General") {
          dashListCard {
            Button {
              showsLanguagePicker = true
            } label: {
              DashListRow(
                title: DashL10n.string("Language"),
                subtitle: DashL10n.string("App display language"),
                icon: SolarAsset.Content.globus,
                trailing: selectedLanguage.displayName
              )
            }
            .buttonStyle(DashSurfaceButtonStyle())
            .accessibilityHint(DashL10n.string("Choose English, Simplified Chinese, or System"))
            .dashListCardInset()
          }

          DashToggleRow(
            title: DashL10n.string("Haptic feedback"),
            subtitle: DashL10n.string("Vibrate on button presses, selections, and confirmations."),
            isOn: $hapticsEnabled
          )
          .onChange(of: hapticsEnabled) { _, enabled in
            if enabled { DashDelight.lightImpact() }
          }

          DashToggleRow(
            title: DashL10n.string("Hold to confirm"),
            subtitle: DashL10n.string(
              "Require a long press to confirm deletes and other irreversible actions."
            ),
            isOn: $holdToConfirmEnabled
          )
        }

        DashListGroup(title: "Watchtower") {
          DashToggleRow(
            title: DashL10n.string("Notify after background checks"),
            subtitle: DashL10n.string(
              "Dash checks opportunistically when iOS allows background refresh. Alerts are local and only fire for newly detected issues."
            ),
            isOn: $watchtowerNotifications
          )
          .onChange(of: watchtowerNotifications) { _, enabled in
            guard enabled else {
              watchtowerNotificationsDenied = false
              return
            }
            Task {
              let granted = await WatchtowerNotifier.requestAuthorization()
              if !granted {
                watchtowerNotifications = false
                watchtowerNotificationsDenied = true
                model.toasts.warning(
                  DashL10n.string(
                    "Notifications are turned off in iOS Settings. Enable them for Dash to get alerts."
                  ))
              }
            }
          }
          if watchtowerNotificationsDenied {
            DashNotice(
              kind: .warning,
              message: DashL10n.string(
                "Notifications are turned off in iOS Settings. Enable them for Dash to get alerts."
              ))
          }
        }

        PushAlertsSettingsCard()

        DashListGroup(title: "Shortcuts") {
          dashListCard {
            DashListRow(
              title: DashL10n.string("Siri & Shortcuts"),
              subtitle: DashL10n.string(
                "Purge Cache, Under Attack, Development Mode, Upload to R2, and Open Watchtower."
              ),
              icon: SolarAsset.Content.bolt
            )
            .dashListCardInset()
            .accessibilityHint(
              DashL10n.string("Available in the Shortcuts app when Dash is signed in"))
          }
        }

        DashListGroup(title: "About") {
          dashListCard {
            DashListGroupLink(value: .about) {
              DashListRow(
                title: DashL10n.string("About Dash"),
                subtitle: DashL10n.string("Version and app details"),
                icon: SolarAsset.Content.cloud
              )
            }
            .dashListCardInset()
          }

          dashListCard {
            DashListGroupLink(value: .openSource) {
              DashListRow(
                title: DashL10n.string("Open source"),
                subtitle: DashL10n.string("Libraries and icons that power Dash"),
                icon: SolarAsset.Content.code
              )
            }
            .dashListCardInset()
          }
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.vertical, DashTheme.Spacing.section)
    }
    .background(DashTheme.canvas)
    .detailHeader(icon: .solar(SolarAsset.settings), title: "Settings")
    .dashTray(
      isPresented: $showsLanguagePicker,
      title: DashL10n.string("Language")
    ) {
      LanguagePickerTray(languageRaw: $languageRaw)
    }
  }
}

private struct LanguagePickerTray: View {
  @Binding var languageRaw: String
  @Environment(\.dashTrayDismiss) private var dismiss

  var body: some View {
    VStack(spacing: 12) {
      ForEach(DashAppLanguage.allCases) { language in
        let isSelected = languageRaw == language.rawValue
        Button {
          guard languageRaw != language.rawValue else {
            dismiss()
            return
          }
          language.applyToProcess()
          languageRaw = language.rawValue
          DashDelight.selectionChanged()
          dismiss()
        } label: {
          HStack(spacing: 12) {
            Text(language.displayName)
              .dashTextStyle(.bodyMedium)
              .foregroundStyle(DashTheme.text)
              .lineLimit(1)
            Spacer(minLength: 0)
            SolarIcon(
              asset: isSelected ? SolarAsset.checkCircleFill : SolarAsset.circle,
              size: 22,
              color: isSelected ? DashTheme.brand : DashTheme.placeholder
            )
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .frame(minHeight: DashTheme.Layout.minimumHitTarget)
          .background(DashTheme.Sheet.shortcutItem)
          .clipShape(DashTheme.buttonShape)
          .contentShape(Rectangle())
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }

      Text(
        DashL10n.string(
          "System follows the iPhone language, including Settings → Dash → Language.")
      )
      .dashTextStyle(.footnote)
      .foregroundStyle(DashTheme.subtle)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }
}

/// About screen (Settings → About): the app icon over the app name, tagline,
/// and version.
struct AboutView: View {
  private var versionText: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "—"
    let build = info?["CFBundleVersion"] as? String ?? "—"
    return "\(version) (\(build))"
  }

  var body: some View {
    ScrollView {
      VStack(spacing: DashTheme.Spacing.section) {
        VStack(spacing: 16) {
          Image("LoginAppIcon")
            .resizable()
            .scaledToFit()
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 96 * 0.2237, style: .continuous))
            // The warm halo that used to lift the icon's spot off the canvas.
            .background {
              RadialGradient(
                colors: [DashTheme.homeWash.opacity(0.55), DashTheme.homeWash.opacity(0)],
                center: .center,
                startRadius: 8,
                endRadius: 300
              )
              .frame(width: 600, height: 600)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
            }
            .accessibilityHidden(true)

          VStack(spacing: 4) {
            Text("Dash")
              .dashTextStyle(.sheetTitle)
              .foregroundStyle(DashTheme.strong)
            Text("A native Cloudflare client for iPhone")
              .dashTextStyle(.supporting)
              .foregroundStyle(DashTheme.subtle)
              .multilineTextAlignment(.center)
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)

        DashCard {
          VStack(alignment: .leading, spacing: 4) {
            Text("Version")
              .dashTextStyle(.footnoteSemibold)
              .foregroundStyle(DashTheme.subtle)
            Text(versionText)
              .dashTextStyle(.supporting)
              .foregroundStyle(DashTheme.text)
              .textSelection(.enabled)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 12)
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.vertical, DashTheme.Spacing.section)
    }
    .background(DashTheme.canvas)
    .detailHeader(icon: .solar(SolarAsset.Content.cloud), title: "About")
  }
}

/// One credited open-source project: a name, a short purpose, its author, the
/// SPDX-style license, and a repository link. Names, authors, and license IDs
/// are proper nouns and render raw; only the `purpose` is localized.
private struct OpenSourceCredit: Identifiable {
  let name: String
  /// Localizable one-liner describing what Dash uses the project for.
  let purpose: String
  let author: String
  let license: String
  let url: URL

  var id: String { name }

  /// Swift packages that ship in the app binary (direct and transitive).
  static let libraries: [OpenSourceCredit] = [
    OpenSourceCredit(
      name: "MarkdownUI", purpose: "Markdown rendering", author: "Guille Gonzalez",
      license: "MIT", url: URL(string: "https://github.com/gonzalezreal/swift-markdown-ui")!),
    OpenSourceCredit(
      name: "CodeEditor", purpose: "Code and JSON editing", author: "ZeeZide",
      license: "MIT", url: URL(string: "https://github.com/ZeeZide/CodeEditor")!),
    OpenSourceCredit(
      name: "Highlightr", purpose: "Syntax highlighting", author: "Juan Pablo Illanes",
      license: "MIT", url: URL(string: "https://github.com/raspu/Highlightr")!),
    OpenSourceCredit(
      name: "NetworkImage", purpose: "Async image loading", author: "Guille Gonzalez",
      license: "MIT", url: URL(string: "https://github.com/gonzalezreal/NetworkImage")!),
    OpenSourceCredit(
      name: "swift-cmark", purpose: "CommonMark parser", author: "Swift project",
      license: "BSD-2-Clause", url: URL(string: "https://github.com/swiftlang/swift-cmark")!),
  ]

  /// Icon artwork Dash renders. Solar ships under CC BY 4.0, which requires
  /// this attribution — not merely a courtesy.
  static let icons: [OpenSourceCredit] = [
    OpenSourceCredit(
      name: "Solar Icons", purpose: "Interface icons", author: "480 Design",
      license: "CC BY 4.0", url: URL(string: "https://github.com/480-Design/Solar-Icon-Set")!),
    OpenSourceCredit(
      name: "Hugeicons", purpose: "File-type icons", author: "Hugeicons",
      license: "MIT", url: URL(string: "https://github.com/hugeicons/hugeicons")!),
  ]
}

/// A small neutral capsule carrying a license identifier (MIT, CC BY 4.0…).
private struct OpenSourceLicenseBadge: View {
  let license: String

  var body: some View {
    Text(license)
      .dashTextStyle(.captionSemibold)
      .foregroundStyle(DashTheme.subtle)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(DashTheme.Sheet.shortcutItem, in: Capsule())
      .fixedSize()
  }
}

/// One tappable credit row: name + "purpose · author", a license badge, and a
/// chevron. Tapping opens the repository in the browser.
private struct OpenSourceCreditRow: View {
  let credit: OpenSourceCredit
  @Environment(\.openURL) private var openURL

  var body: some View {
    Button {
      openURL(credit.url)
    } label: {
      DashListRow(
        title: credit.name,
        subtitle: "\(DashL10n.ui(credit.purpose)) · \(credit.author)"
      ) {
        OpenSourceLicenseBadge(license: credit.license)
      }
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityHint(DashL10n.string("Opens the project repository in your browser"))
    .dashListCardInset()
  }
}

/// Open-source acknowledgements (Settings → Open source): the third-party
/// libraries and icon sets Dash ships, each linking to its repository.
struct OpenSourceView: View {
  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        Text(
          DashL10n.string(
            "Dash is built with these open-source projects. Thank you to their authors and maintainers."
          )
        )
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)

        DashListGroup(title: "Libraries") {
          dashListCard {
            ForEach(OpenSourceCredit.libraries) { credit in
              OpenSourceCreditRow(credit: credit)
            }
          }
        }

        DashListGroup(title: "Icons") {
          dashListCard {
            ForEach(OpenSourceCredit.icons) { credit in
              OpenSourceCreditRow(credit: credit)
            }
          }
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.vertical, DashTheme.Spacing.section)
    }
    .background(DashTheme.canvas)
    .detailHeader(icon: .solar(SolarAsset.Content.code), title: "Open source")
  }
}

/// The standalone Profile page, pushed from the avatar tray's Profile row:
/// identity, user id and registration date, and the active account's details.
/// Switching accounts and signing out stay on the tray menu.
struct ProfileView: View {
  @Environment(AppModel.self) private var model
  @State private var showsRename = false
  @State private var renameText = ""
  @State private var renaming = false
  @State private var renameError: String?

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        VStack(spacing: 12) {
          UserAvatar(email: model.user?.email ?? "", size: 80)
          VStack(spacing: 2) {
            Text(model.profileTitle)
              .dashTextStyle(.sheetTitle)
              .foregroundStyle(DashTheme.strong)
            if let email = model.user?.email, email != model.profileTitle {
              Text(email)
                .dashTextStyle(.supporting)
                .foregroundStyle(DashTheme.subtle)
            }
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)

        DashCard {
          VStack(alignment: .leading, spacing: 0) {
            profileField(
              label: DashL10n.string("User ID"), value: model.user?.id ?? "—", mono: true)
            DashListGroupDivider()
            profileField(
              label: DashL10n.string("Registered"),
              value: formattedDate(model.user?.createdOn) ?? "—")
          }
        }

        if let account = model.activeAccount {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
              Text(DashL10n.string("Active account"))
                .dashTextStyle(.footnoteSemibold)
                .foregroundStyle(DashTheme.subtle)
              Spacer(minLength: 0)
              Button {
                renameError = nil
                renameText = account.name
                showsRename = true
              } label: {
                SolarIcon(asset: SolarAsset.pen, size: 18, color: DashTheme.brand)
                  .dashCompactHitTarget()
              }
              .buttonStyle(DashPressButtonStyle())
              .accessibilityLabel(DashL10n.string("Rename account"))
            }
            DashCard {
              VStack(alignment: .leading, spacing: 0) {
                profileField(label: DashL10n.string("Name"), value: account.name)
                DashListGroupDivider()
                profileField(label: DashL10n.string("Account ID"), value: account.id, mono: true)
                if let created = formattedDate(account.createdOn) {
                  DashListGroupDivider()
                  profileField(label: DashL10n.string("Created"), value: created)
                }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        DashListGroup(title: "Account") {
          dashListCard {
            DashListGroupLink(value: .auditLogs) {
              DashListRow(
                title: DashL10n.string("Audit log"),
                subtitle: DashL10n.string("Recent account activity"),
                icon: SolarAsset.Content.shieldCheck
              )
            }
            .dashListCardInset()
          }
        }

      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.vertical, DashTheme.Spacing.section)
    }
    .background(DashTheme.canvas)
    .detailHeader(icon: .solar(SolarAsset.userFill), title: "Profile")
    .dashTray(isPresented: $showsRename, title: DashL10n.string("Rename account")) {
      DashFormSheet(
        isSaving: renaming,
        canSave: !renameText.trimmingCharacters(in: .whitespaces).isEmpty,
        onSave: { Task { await renameAccount() } }
      ) {
        VStack(spacing: 14) {
          if let renameError {
            DashNotice(kind: .error, message: renameError)
          }
          DashFormField(label: DashL10n.string("Name"), text: $renameText)
        }
      }
    }
  }

  private func renameAccount() async {
    renaming = true
    renameError = nil
    do {
      try await model.renameActiveAccount(
        to: renameText.trimmingCharacters(in: .whitespaces))
      showsRename = false
    } catch {
      renameError = error.dashActionableMessage
    }
    renaming = false
  }

  private func profileField(label: String, value: String, mono: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      Text(value)
        .dashTextStyle(mono ? .codeBody : .supporting)
        .foregroundStyle(DashTheme.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Cloudflare timestamps arrive as ISO 8601, with or without fractional
  /// seconds; render them as a plain date.
  private func formattedDate(_ iso: String?) -> String? {
    guard let iso else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    guard let date = fractional.date(from: iso) ?? plain.date(from: iso) else { return iso }
    return date.formatted(date: .abbreviated, time: .omitted)
  }
}
