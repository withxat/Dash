import CloudflareAPI
import SwiftUI
import UIKit
import UserNotifications

private enum AppTab: Hashable { case home, features, watchtower }

private struct AccountScopedRouteRequest {
  let account: CloudflareAccount
  let route: DashRoute
}

struct MainTabView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(DashWorkspaceWashPreset.storageKey) private var workspaceWashRaw =
    DashWorkspaceWashPreset.defaultPreset.rawValue
  @Namespace private var workspaceHeaderGlass
  @State private var selection: AppTab = .home
  @State private var homeNavigator = DestinationNavigator()
  @State private var featuresNavigator = DestinationNavigator()
  @State private var watchtowerNavigator = DestinationNavigator()
  @State private var watchtowerCustomization = WatchtowerChartCustomizationState()
  /// The shared header owns Watchtower's editor buttons, while the screen still
  /// owns the staged editor-exit choreography. Bumping these tokens asks the
  /// mounted Watchtower root to run those existing paths.
  @State private var watchtowerCancelRequest = 0
  @State private var watchtowerCommitRequest = 0
  /// Add stays disabled until Watchtower has mounted the drag bridge after the
  /// editor morph; moving the menu into shared chrome must retain that gate.
  @State private var watchtowerEditorInteractionsReady = false
  /// Handed down to the active page and back up to the wash — never read here.
  /// It carries a per-frame scroll position, and this body owns the navigation
  /// paths: reading it would re-apply them mid-push and cancel the transition.
  @State private var washScroll = DashWorkspaceWashScroll()
  @State private var showsProfile = false
  @State private var profileTrayPhase = ProfileTrayPhase.initial
  @State private var showsIgnoreAllAlerts = false
  @State private var nestedTray = DashTrayPresentation()
  @State private var accountRouteConfirmation: AccountScopedRouteRequest?
  @State private var routeAfterAccountSwitch: DashRoute?

  init() {}

  /// Every compact tray currently over this canvas — the pages' trays plus the
  /// account switcher (whose preference sits above our reader, so it is OR-ed in).
  private var overlayTrays: DashTrayPresentation {
    DashTrayPresentation(
      presented: showsProfile || showsIgnoreAllAlerts || nestedTray.presented)
  }

  private var workspaceWashPreset: DashWorkspaceWashPreset {
    DashWorkspaceWashPreset.resolved(stored: workspaceWashRaw)
  }

  private var hidesDock: Bool {
    shouldHideTabBar(
      overlays: overlayTrays,
      navigationDepth: activeNavigationDepth
    ) || watchtowerCustomization.isEditing
  }

  private var sharedHeaderIsDisplaced: Bool {
    shouldHideHeaderAvatar(
      overlays: overlayTrays,
      navigationDepth: activeNavigationDepth
    )
  }

  private var hidesHeaderAvatar: Bool {
    sharedHeaderIsDisplaced || watchtowerCustomization.isEditing
  }

  /// Floated Watchtower inbox — same hide rules as the avatar, Watchtower root only.
  private var showsWatchtowerInboxButton: Bool {
    selection == .watchtower
      && model.activeAccountID != nil
      && !hidesHeaderAvatar
  }

  /// Watchtower editing stays on the root canvas, so all of its header actions
  /// belong in the same floated layer as the avatar and inbox.
  private var showsWatchtowerEditorHeader: Bool {
    selection == .watchtower
      && watchtowerCustomization.isEditing
      && !sharedHeaderIsDisplaced
  }

  /// Pages swipe only between the tab roots. A pushed feature/detail owns
  /// horizontal gestures (the leading-edge back swipe must win), an open tray
  /// freezes the canvas underneath it, and a live chart tooltip owns the finger
  /// it is scrubbing with. The scrub itself already claims the pager's pan for
  /// the length of the hold (`DitherHoldInteraction`); this holds the lock
  /// across a SwiftUI rebuild that would otherwise hand it back mid-scrub.
  /// Enforced via `TabPagerScrollLock` (pan recognizer only — never
  /// `scrollDisabled` / `isScrollEnabled`).
  private var pagerLocked: Bool {
    activeNavigationDepth > 0
      || overlayTrays.presented
      || watchtowerCustomization.isEditing
      || watchtowerCustomization.isScrubbing
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

  /// Applies a route only after any account scope has been verified.
  private func openVerifiedRoute(_ route: DashRoute) {
    switch route {
    case .watchtower:
      selection = .watchtower
      watchtowerNavigator.reset()
    case .action(let action):
      selection = .home
      homeNavigator.reset()
      guard let context = model.accountRequestContext else { return }
      model.pendingHomeAction = PendingHomeAction(action: action, context: context)
    default:
      guard let destination = route.destination else { break }
      selection = .home
      homeNavigator.reset(to: destination)
    }
  }

  /// Account-scoped links never silently resolve under the active account.
  /// A different known account requires confirmation; a missing account is
  /// rejected with actionable feedback. Legacy unscoped links keep their
  /// historical current-account behavior.
  private func consume(_ route: DashRoute) {
    model.pendingRoute = nil
    let resolution = route.accountResolution(
      activeAccountID: model.activeAccountID,
      availableAccountIDs: Set(model.accounts.map(\.id)))
    switch resolution {
    case .open(let route):
      openVerifiedRoute(route)
    case .confirmSwitch(let accountID, let route):
      guard let account = model.accounts.first(where: { $0.id == accountID }) else {
        model.toasts.error(
          "The Cloudflare account for this link isn't available in Dash. Check your access and try again."
        )
        return
      }
      accountRouteConfirmation = AccountScopedRouteRequest(account: account, route: route)
    case .rejectUnavailable:
      model.toasts.error(
        "The Cloudflare account for this link isn't available in Dash. Check your access and try again."
      )
    }
  }

  private func confirmAccountSwitch(_ request: AccountScopedRouteRequest) {
    accountRouteConfirmation = nil
    guard let account = model.accounts.first(where: { $0.id == request.account.id }) else {
      model.toasts.error(
        "That Cloudflare account is no longer available in Dash. Refresh your accounts and try again."
      )
      return
    }
    guard model.activeAccountID != account.id else {
      openVerifiedRoute(request.route)
      return
    }
    routeAfterAccountSwitch = request.route
    model.selectAccount(account)
  }

  private var showsAccountRouteConfirmation: Binding<Bool> {
    Binding(
      get: { accountRouteConfirmation != nil },
      set: { presented in
        if !presented { accountRouteConfirmation = nil }
      })
  }

  var body: some View {
    tabContainer
      .onPreferenceChange(TrayPresentedPreferenceKey.self) { nestedTray = $0 }
      .onReceive(
        NotificationCenter.default.publisher(
          for: ICloudPreferencesSync.didApplyRemoteChanges)
      ) { notification in
        if ICloudPreferencesSync.changedGroups(in: notification)
          .contains(.watchtowerLayout)
        {
          watchtowerCustomization.reloadPersistedLayout()
        }
      }
      .onChange(of: scenePhase) { _, phase in
        switch phase {
        case .active:
          model.deferredDeletions.resumeReconciliation()
          Task {
            await model.retryIdentityIfNeeded()
            await model.refreshWatchtowerIfStale()
          }
        case .background:
          model.commitDeferredDeletionsForBackground()
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
        // Sign-out clears the account before remote cleanup finishes. Keep the
        // account-switcher / Settings confirmation tray mounted through its loading and
        // success phases; AppRoot swaps to sign-in after the phase returns idle.
        guard !model.signOutActionPhase.isActive else {
          showsIgnoreAllAlerts = false
          return
        }
        homeNavigator.reset()
        featuresNavigator.reset()
        watchtowerNavigator.reset()
        watchtowerCustomization.cancelEditing()
        showsProfile = false
        showsIgnoreAllAlerts = false
        if let route = routeAfterAccountSwitch {
          routeAfterAccountSwitch = nil
          openVerifiedRoute(route)
        }
      }
      .dashTray(
        isPresented: $showsProfile,
        title: DashL10n.string("Switch account"),
        content: {
          ProfileTrayContent(phase: $profileTrayPhase)
        },
        footer: {
          ProfileTrayFooter(phase: $profileTrayPhase)
        }
      )
      .dashTray(
        isPresented: $showsIgnoreAllAlerts,
        title: DashL10n.string("Ignore all alerts")
      ) {
        WatchtowerIgnoreAllTray(count: model.watchtowerUnreadAlertCount ?? 0) {
          model.ignoreAllWatchtowerAlerts()
          DashDelight.recoverFromIssue()
        }
      }
      .alert(
        "Switch Cloudflare account?",
        isPresented: showsAccountRouteConfirmation,
        presenting: accountRouteConfirmation
      ) { request in
        Button("Cancel", role: .cancel) {
          accountRouteConfirmation = nil
        }
        Button("Switch Account") {
          confirmAccountSwitch(request)
        }
      } message: { request in
        Text(
          "This link belongs to \(request.account.name). Switch accounts before opening it?"
        )
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
            HomeView(
              isActive: selection == .home,
              isAtRoot: homeNavigator.depth == 0)
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
            WatchtowerView(
              customization: watchtowerCustomization,
              cancelRequest: watchtowerCancelRequest,
              commitRequest: watchtowerCommitRequest,
              editorInteractionsReady: $watchtowerEditorInteractionsReady
            )
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

      sharedHeaderOverlay

      // Trays and pushed routes displace the bar; tab roots keep it mounted.
      ZStack(alignment: .bottom) {
        if !hidesDock {
          DashFloatingTabBar(
            selection: $selection,
            watchtowerUnreadCount: model.watchtowerUnreadAlertCount ?? 0,
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
    // The workspace canvas and its ONE top light field, painted behind the
    // pager. Every tab root is transparent (`dashCatalogScreen`), so all three
    // share this single wash instead of carrying a copy each: the glow never
    // rides a tab swipe, and it holds still while pages slide across it. It
    // does ride the active root's *vertical* scroll — see `DashWorkspaceTopWash`.
    .background {
      ZStack(alignment: .top) {
        DashTheme.canvas
        if workspaceWashPreset != .none {
          DashWorkspaceTopWash(
            color: DashTheme.workspaceWash(for: workspaceWashPreset),
            scroll: washScroll
          )
        }
      }
      .ignoresSafeArea()
    }
    .dashToastHost()
  }

  /// ONE header layer above the pager. Normal roots show avatar + Watchtower
  /// inbox; chart editing hands those exact slots to Cancel + Add/Done. Keeping
  /// every source and destination inside one Liquid Glass container lets iOS 26
  /// morph the shapes instead of compositing a second native-toolbar layer.
  private var sharedHeaderOverlay: some View {
    Group {
      if #available(iOS 26.0, *) {
        GlassEffectContainer(spacing: WorkspaceHeaderMetrics.actionSpacing) {
          sharedHeaderControls
        }
      } else {
        sharedHeaderControls
      }
    }
    // Pushes and trays do not carry a SwiftUI transaction, so the shared layer
    // supplies their fade. Tab switches and editor enter/exit already originate
    // in explicit settle/morph transactions and keep their directional timing.
    .animation(tabBarVisibilityAnimation, value: sharedHeaderIsDisplaced)
    // A finger-driven page swipe can update `selection` without the tab bar's
    // explicit transaction. Give that handoff the same settle curve without
    // keying off editor visibility, which would replace morph/morphExit.
    .animation(tabBarVisibilityAnimation, value: selection)
    .allowsHitTesting(
      !hidesHeaderAvatar
        || showsWatchtowerInboxButton
        || showsWatchtowerEditorHeader)
  }

  private var sharedHeaderControls: some View {
    ZStack {
      ZStack(alignment: .topLeading) {
        if showsWatchtowerEditorHeader {
          DashToolbarIconButton(
            asset: SolarAsset.editClose,
            accessibilityLabel: DashL10n.string("Cancel")
          ) {
            watchtowerCancelRequest &+= 1
          }
          .workspaceHeaderGlassID(.leading, in: workspaceHeaderGlass)
          .accessibilityIdentifier("watchtower-customize-cancel")
          .padding(.leading, WorkspaceHeaderMetrics.edgeInset)
          .padding(.top, WorkspaceHeaderMetrics.edgeInset)
          .transition(.opacity)
        } else if !hidesHeaderAvatar {
          HeaderProfileButton(
            action: { openOnActiveTab(.settings) },
            onLongPress: {
              // The phase used to live inside the freshly mounted tray body.
              // Reset before presentation so an exit never swaps its content
              // back to Accounts while the card is still animating away.
              profileTrayPhase = .initial
              showsProfile = true
            }
          )
          .workspaceHeaderGlassID(.leading, in: workspaceHeaderGlass)
          // Tuned against the system back control's measured slot so the
          // push crossfade reads as the avatar becoming the back button.
          .padding(.leading, WorkspaceHeaderMetrics.edgeInset)
          .padding(.top, WorkspaceHeaderMetrics.edgeInset)
          .transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      ZStack(alignment: .topTrailing) {
        if showsWatchtowerEditorHeader {
          HStack(spacing: WorkspaceHeaderMetrics.actionSpacing) {
            watchtowerAddChartMenu
              .workspaceHeaderGlassID(.trailingSecondary, in: workspaceHeaderGlass)
            DashToolbarIconButton(
              asset: SolarAsset.unread,
              accessibilityLabel: DashL10n.string("Done"),
              variant: .confirmation
            ) {
              watchtowerCommitRequest &+= 1
            }
            // Done occupies the inbox's former rightmost slot, so its glass
            // shape has a stable source while Add separates to the left.
            .workspaceHeaderGlassID(.trailingPrimary, in: workspaceHeaderGlass)
            .accessibilityIdentifier("watchtower-customize-done")
          }
          .padding(.trailing, WorkspaceHeaderMetrics.edgeInset)
          .padding(.top, WorkspaceHeaderMetrics.edgeInset)
          .transition(.opacity)
        } else if showsWatchtowerInboxButton {
          HeaderInboxButton(
            count: model.watchtowerUnreadAlertCount ?? 0,
            action: { watchtowerNavigator.push(.watchtowerInbox) },
            onLongPress: { showsIgnoreAllAlerts = true }
          )
          .workspaceHeaderGlassID(.trailingPrimary, in: workspaceHeaderGlass)
          .padding(.trailing, WorkspaceHeaderMetrics.edgeInset)
          .padding(.top, WorkspaceHeaderMetrics.edgeInset)
          .transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
  }

  private var watchtowerAddChartMenu: some View {
    Menu {
      if watchtowerCustomization.addableMetrics.isEmpty {
        Button(DashL10n.string("All charts are shown")) {}
          .disabled(true)
      } else {
        ForEach(watchtowerCustomization.addableMetrics) { metric in
          Button(DashL10n.ui(metric.title)) {
            withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
              watchtowerCustomization.add(metric)
            }
            DashDelight.selectionChanged()
          }
        }
      }
    } label: {
      WatchtowerAddChartToolbarLabel()
    }
    .buttonStyle(DashPressButtonStyle())
    .disabled(!watchtowerEditorInteractionsReady)
    .accessibilityLabel(DashL10n.string("Add chart"))
    .accessibilityIdentifier("watchtower-add-chart")
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
      // Only the visible root drives the shared glow. Off-screen pages stay
      // mounted for the pager and keep probing their own frost, but they must
      // not push their scroll position into the one wash behind all three.
      .environment(\.dashWorkspaceWashScroll, isActive ? washScroll : nil)
      .tag(tab)
      .accessibilityHidden(!isActive)
      .accessibilityElement(children: isActive ? .contain : .ignore)
  }

  /// The floating bar rides in on first appearance without animation and slides
  /// on later navigation changes — SwiftUI only animates the value that flips.
  private var tabBarVisibilityAnimation: Animation {
    DashTheme.Motion.settle
  }

  /// Re-tapping the active tab clears its navigation path, matching `TabView`.
  private func popActiveTabToRoot() {
    activeNavigator.popToRoot()
  }
}

private enum WorkspaceHeaderMetrics {
  static let edgeInset: CGFloat = AvatarHeaderMetrics.chromeInset
  static let actionSpacing: CGFloat = 8
}

private enum WorkspaceHeaderGlassID: Hashable, Sendable {
  case leading
  case trailingPrimary
  case trailingSecondary
}

extension View {
  /// Stable Liquid Glass identities for the controls that trade places inside
  /// `MainTabView.sharedHeaderOverlay`. Earlier systems keep the same aligned
  /// opacity handoff without adopting iOS 26-only material APIs.
  @MainActor
  @ViewBuilder
  fileprivate func workspaceHeaderGlassID(
    _ id: WorkspaceHeaderGlassID,
    in namespace: Namespace.ID
  ) -> some View {
    if #available(iOS 26.0, *) {
      glassEffectID(id, in: namespace)
        .glassEffectTransition(.matchedGeometry)
    } else {
      self
    }
  }
}

private struct WatchtowerAddChartToolbarLabel: View {
  var body: some View {
    if #available(iOS 26.0, *) {
      DashToolbarActionIcon(asset: SolarAsset.plus)
        .frame(
          width: AvatarHeaderMetrics.barSize,
          height: AvatarHeaderMetrics.barSize
        )
        .contentShape(Circle())
        .glassEffect(.regular.interactive(), in: .circle)
    } else {
      DashToolbarActionIcon(asset: SolarAsset.plus)
        .dashCompactHitTarget()
    }
  }
}

/// The workspace's top light field: one continuous wash from the physical top
/// edge — status bar included — falling off sideways and down into the canvas.
///
/// ONE instance, painted by `MainTabView` *behind* the tab pager. It belongs to
/// the workspace canvas, not to any page: Home, Resources and Watchtower all
/// show the same glow because they are transparent (`dashCatalogScreen`), not
/// because each renders its own. Do not move a copy into a tab root — three
/// washes would ride their pages on a swipe and read as a seam.
///
/// Behind the pages, never over them, so opaque cards keep a true fill and
/// scrolled content passes across the light instead of being tinted by it. A
/// pushed screen covers it with its own opaque canvas plate.
///
/// It is not, however, fixed to the window: the glow belongs to the top of the
/// content, so it rides the active root's scroll 1:1 and leaves with it. Only
/// the header frost stays pinned up there. Pin both and the two read as one
/// stuck slab — which is exactly what adding the frost made the glow look like.
struct DashWorkspaceTopWash: View {
  let color: Color
  /// The active root's scroll position. Read HERE and nowhere else: it moves
  /// every frame, and this view is the only thing that should re-render for it.
  let scroll: DashWorkspaceWashScroll

  /// Fall-off distance from the physical top edge.
  private let depth = DashWorkspaceWashRules.depth

  var body: some View {
    ZStack {
      LinearGradient(
        stops: [
          .init(color: color.opacity(0.34), location: 0),
          .init(color: color.opacity(0.2), location: 0.42),
          .init(color: color.opacity(0), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      RadialGradient(
        colors: [color.opacity(0.32), color.opacity(0)],
        center: .top,
        startRadius: 0,
        endRadius: 290
      )
    }
    .frame(height: depth)
    .frame(maxWidth: .infinity)
    .offset(y: -DashWorkspaceWashRules.lift(for: scroll.distance))
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Disables the page `TabView`'s horizontal paging pan while a pushed screen
/// or tray owns the canvas. Recent iOS backs the pager with a
/// `UICollectionView` (`isPagingEnabled` often false) — detect by geometry,
/// then re-apply on hierarchy changes and a short retry window (SwiftUI can
/// rebuild and re-enable the pan immediately after an update).
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

  static func dismantleUIView(
    _ uiView: TabPagerScrollLockView,
    coordinator: ()
  ) {
    uiView.tearDown()
  }
}

enum TabPagerLockRules {
  @MainActor
  static func apply(locked: Bool, to pager: UIScrollView) {
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
}

enum TabPagerLockRetrySchedule {
  static let offsetsMS: [Int64] = [0, 16, 64, 160]
}

private final class TabPagerScrollLockView: UIView {
  private var locked = false
  private var isTearingDown = false
  private var retryTask: Task<Void, Never>?
  private weak var pager: UIScrollView?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isHidden = true
    backgroundColor = .clear
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func willMove(toWindow newWindow: UIWindow?) {
    if newWindow == nil {
      tearDown()
    }
    super.willMove(toWindow: newWindow)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil else { return }
    isTearingDown = false
    resolveAndApply()
    scheduleRetries()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    resolveAndApply()
  }

  func setLocked(_ locked: Bool) {
    self.locked = locked
    resolveAndApply()
    scheduleRetries()
  }

  fileprivate func tearDown() {
    isTearingDown = true
    retryTask?.cancel()
    retryTask = nil
    if let pager {
      TabPagerLockRules.apply(locked: false, to: pager)
    }
    pager = nil
  }

  private func scheduleRetries() {
    retryTask?.cancel()
    guard window != nil, !isTearingDown else {
      retryTask = nil
      return
    }
    let expectedLocked = locked
    retryTask = Task { @MainActor [weak self] in
      var previousOffsetMS: Int64 = 0
      for offsetMS in TabPagerLockRetrySchedule.offsetsMS {
        let delayMS = offsetMS - previousOffsetMS
        previousOffsetMS = offsetMS
        if delayMS > 0 {
          do {
            try await Task.sleep(for: .milliseconds(delayMS))
          } catch {
            return
          }
        }

        guard
          !Task.isCancelled,
          let self,
          self.window != nil,
          !self.isTearingDown,
          self.locked == expectedLocked
        else {
          return
        }
        self.resolveAndApply()
      }
      self?.retryTask = nil
    }
  }

  private func resolveAndApply() {
    guard window != nil, !isTearingDown else { return }
    if let pager, pager.window !== window {
      TabPagerLockRules.apply(locked: false, to: pager)
      self.pager = nil
    }

    let resolved = pager ?? Self.findTabPager(from: self)
    guard let resolved else { return }
    pager = resolved
    TabPagerLockRules.apply(locked: locked, to: resolved)
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
  let watchtowerUnreadCount: Int
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
    let canIgnore = tab == .watchtower && watchtowerUnreadCount > 0
    let button = Button {
      select(tab, isActive: isActive)
    } label: {
      DashTabIcon(
        tab: tab,
        isActive: isActive,
        issueCount: tab == .watchtower ? watchtowerUnreadCount : 0
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
      withAnimation(reduceMotion ? nil : DashTheme.Motion.settle) {
        selection = tab
      }
    }
  }

  private func accessibilityLabel(for tab: AppTab) -> String {
    guard tab == .watchtower, watchtowerUnreadCount > 0 else { return tab.title }
    let alertSummary =
      watchtowerUnreadCount == 1
      ? DashL10n.string("1 alert")
      : DashL10n.string("\(watchtowerUnreadCount) alerts")
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
    DashTheme.Motion.pop
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
