import CloudflareAPI
import SwiftUI

enum AppTab: Hashable { case home, features, watchtower }

enum DashTabTransitionDirection: Equatable {
  case stationary
  case backward
  case forward
}

enum DashTabTransitionRules {
  static func direction(
    from source: AppTab,
    to target: AppTab
  ) -> DashTabTransitionDirection {
    guard source != target else { return .stationary }
    guard
      let sourceIndex = AppTab.orderedCases.firstIndex(of: source),
      let targetIndex = AppTab.orderedCases.firstIndex(of: target)
    else { return .stationary }
    return targetIndex > sourceIndex ? .forward : .backward
  }

  /// Incoming start offset on the navigation axis. Forward LTR enters from the
  /// trailing edge (positive X).
  static func signedTravel(
    for direction: DashTabTransitionDirection,
    rightToLeft: Bool,
    reduceMotion: Bool
  ) -> CGFloat {
    let directionalSign: CGFloat =
      switch direction {
      case .stationary: 0
      case .backward: -1
      case .forward: 1
      }
    let layoutSign: CGFloat = rightToLeft ? -1 : 1
    let travel = reduceMotion ? 0 : DashTheme.Motion.tabStepSlide
    return travel * directionalSign * layoutSign
  }

  /// Outgoing end offset — opposite the incoming start. Forward LTR exits
  /// toward the leading edge (negative X), like a horizontal pager.
  static func outgoingEndOffset(
    for direction: DashTabTransitionDirection,
    rightToLeft: Bool,
    reduceMotion: Bool
  ) -> CGFloat {
    -signedTravel(for: direction, rightToLeft: rightToLeft, reduceMotion: reduceMotion)
  }

  /// Push drills forward (Home → Resources); Back / Close-to-parent drills
  /// backward. Page flow and tab handoff share this axis.
  static func pageStepDirection(isPush: Bool) -> DashTabTransitionDirection {
    isPush ? .forward : .backward
  }
}

/// Fills a containment child without assigning `frame`. UIKit leaves `frame`
/// undefined under a non-identity `transform`, and tab/page handoffs animate
/// translation — writing `frame` mid-flight yanks the outgoing page back toward
/// identity and reads as a reversed exit.
enum DashContainmentLayout {
  @MainActor
  static func fill(_ child: UIView, in containerBounds: CGRect) {
    child.bounds = CGRect(origin: .zero, size: containerBounds.size)
    child.center = CGPoint(x: containerBounds.midX, y: containerBounds.midY)
  }
}

enum DashNavigatorAccountScopeRules {
  static func shouldSynchronize(during signOutPhase: DashActionPhase) -> Bool {
    !signOutPhase.isActive
  }
}

enum DashRouteConsumptionRules {
  static func isBlocked(
    overlayPresented: Bool,
    coverPresented: Bool,
    awaitingAccountConfirmation: Bool,
    awaitingAccountSwitch: Bool,
    tabTransitionActive: Bool,
    pageTransitionActive: Bool
  ) -> Bool {
    overlayPresented || coverPresented || awaitingAccountConfirmation
      || awaitingAccountSwitch || tabTransitionActive || pageTransitionActive
  }
}

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
  @State private var outgoingSelection: AppTab?
  @State private var tabTransitionDirection = DashTabTransitionDirection.stationary
  @State private var tabTransitionProgress: CGFloat = 0
  @State private var tabTransitionGeneration: UInt64 = 0
  // Pages in the workspace publish their header slots instead of painting
  // them; `sharedHeaderOverlay` is the ONE bar that draws them.
  @State private var homeNavigator = DestinationNavigator(chromeHosting: .workspace)
  @State private var featuresNavigator = DestinationNavigator(chromeHosting: .workspace)
  @State private var watchtowerNavigator = DestinationNavigator(chromeHosting: .workspace)
  @State private var navigationCoordinator = DashNavigationCoordinator()
  @State private var navigationAnchorRegistry = DashNavigationAnchorRegistry()
  @State private var workspacePresentationState = DashWorkspacePresentationState()
  @State private var watchtowerCustomization = WatchtowerChartCustomizationState()
  /// The shared header owns Watchtower's editor buttons, while the screen still
  /// owns the staged editor-exit choreography. Bumping these tokens asks the
  /// mounted Watchtower root to run those existing paths.
  @State private var watchtowerCancelRequest = 0
  @State private var watchtowerCommitRequest = 0
  /// Add stays disabled until Watchtower has mounted the drag bridge after the
  /// editor morph; moving the menu into shared chrome must retain that gate.
  @State private var watchtowerEditorInteractionsReady = false
  /// Each cached root retains its own scroll snapshot. MainTabView passes only
  /// the references; the ONE wash view reads and blends old/target distances so
  /// per-frame scrolling never refreshes the cached navigation hosts.
  @State private var homeWashScroll = DashWorkspaceWashScroll()
  @State private var featuresWashScroll = DashWorkspaceWashScroll()
  @State private var watchtowerWashScroll = DashWorkspaceWashScroll()
  @State private var showsProfile = false
  @State private var profileTrayPath: [ProfileTrayPhase] = []
  @State private var showsIgnoreAllAlerts = false
  @State private var nestedTray = DashTrayPresentation()
  @State private var accountRouteConfirmation: AccountScopedRouteRequest?
  @State private var routeAfterAccountSwitch: DashRoute?
  @State private var pagePresentationStates: [AppTab: DashPagePresentationState] = [:]

  init() {}

  /// Every compact tray currently over this canvas — the pages' trays plus the
  /// account switcher (whose preference sits above our reader, so it is OR-ed in).
  private var overlayTrays: DashTrayPresentation {
    DashTrayPresentation(
      presented: showsProfile || showsIgnoreAllAlerts || nestedTray.presented
        || workspacePresentationState.trayPresented)
  }

  /// External routes wait for every presenter and account-routing transaction
  /// to finish. Resetting a cached page underneath a cover would tear down its
  /// owner, while consuming a second route during account confirmation could
  /// let the older request overwrite the newer one after the switch completes.
  private var routeConsumptionBlocked: Bool {
    DashRouteConsumptionRules.isBlocked(
      overlayPresented: overlayTrays.presented,
      coverPresented: workspacePresentationState.coverPresented,
      awaitingAccountConfirmation: accountRouteConfirmation != nil,
      awaitingAccountSwitch: routeAfterAccountSwitch != nil,
      tabTransitionActive: outgoingSelection != nil,
      pageTransitionActive: activePagePresentationState.isTransitioning)
  }

  private var workspaceWashPreset: DashWorkspaceWashPreset {
    DashWorkspaceWashPreset.resolved(stored: workspaceWashRaw)
  }

  private func workspaceWashScroll(for tab: AppTab) -> DashWorkspaceWashScroll {
    switch tab {
    case .home: homeWashScroll
    case .features: featuresWashScroll
    case .watchtower: watchtowerWashScroll
    }
  }

  private var hidesDock: Bool {
    shouldHideTabBar(
      overlays: overlayTrays,
      navigationDepth: activeNavigationDepth,
      pageTransitionActive: activePagePresentationState.isTransitioning
    ) || outgoingPageOccupiesWorkspace || watchtowerCustomization.isEditing
  }

  private var headerIsDisplaced: Bool {
    shouldDisplaceWorkspaceHeader(overlays: overlayTrays)
  }

  /// The floated Watchtower inbox is a root occupant of the shared trailing
  /// slot; a pushed page takes that slot over on its own.
  private var showsWatchtowerInboxButton: Bool {
    selection == .watchtower && model.activeAccountID != nil
  }

  /// Watchtower editing stays on the root canvas, and its actions are just
  /// another pair of occupants for the same two slots.
  private var showsWatchtowerEditorHeader: Bool {
    selection == .watchtower && watchtowerCustomization.isEditing
  }

  private var activeNavigationDepth: Int {
    activePagePresentationState.resolvedDepth(
      navigatorDepth: activeNavigator.depth)
  }

  private var activePagePresentationState: DashPagePresentationState {
    pagePresentationState(for: selection)
  }

  /// External routes can replace a tab while its pushed page is still leaving.
  /// Keep root chrome displaced until that outgoing compositor has yielded the
  /// physical workspace; a normal root-to-root tab flight leaves it visible.
  private var outgoingPageOccupiesWorkspace: Bool {
    guard let outgoingSelection else { return false }
    return pagePresentationState(for: outgoingSelection).occupiesWorkspace(
      navigatorDepth: navigator(for: outgoingSelection).depth)
  }

  private func pagePresentationState(for tab: AppTab) -> DashPagePresentationState {
    pagePresentationStates[tab]
      ?? DashPagePresentationState(
        settledDepth: navigator(for: tab).depth,
        isTransitioning: false)
  }

  private var activeNavigator: DestinationNavigator {
    navigator(for: selection)
  }

  private func navigator(for tab: AppTab) -> DestinationNavigator {
    switch tab {
    case .home: homeNavigator
    case .features: featuresNavigator
    case .watchtower: watchtowerNavigator
    }
  }

  private func synchronizeNavigatorAccountScopes() {
    navigationCoordinator.configure(
      navigators: [homeNavigator, featuresNavigator, watchtowerNavigator])
    let accountID = model.activeAccountID
    homeNavigator.setAccountScope(accountID)
    featuresNavigator.setAccountScope(accountID)
    watchtowerNavigator.setAccountScope(accountID)
  }

  /// Applies a route only after any account scope has been verified.
  private func openVerifiedRoute(_ route: DashRoute) {
    synchronizeNavigatorAccountScopes()
    switch route {
    case .watchtower:
      selectTab(.watchtower)
      watchtowerNavigator.reset()
    case .action(let action):
      // The action immediately presents its own tray. Settle Home first so the
      // tray never opens halfway through an unrelated tab-content handoff.
      selectTab(.home, animated: false)
      homeNavigator.reset()
      guard let context = model.accountRequestContext else { return }
      model.pendingHomeAction = PendingHomeAction(action: action, context: context)
    default:
      guard let destination = route.destination else { break }
      // A destination immediately starts its own page transition. Settle the
      // owning tab first so two independent content handoffs never overlap.
      selectTab(.home, animated: false)
      if destination == .settings {
        homeNavigator.reset(
          to: destination,
          presentation: .workspaceOverlay)
      } else {
        homeNavigator.reset(to: destination)
      }
    }
  }

  /// Account-scoped links never silently resolve under the active account.
  /// A different known account requires confirmation; a missing account is
  /// rejected with actionable feedback. Legacy unscoped links keep their
  /// historical current-account behavior.
  private func consume(_ route: DashRoute) {
    guard
      model.authState == .authenticated,
      DashNavigatorAccountScopeRules.shouldSynchronize(
        during: model.signOutActionPhase),
      !routeConsumptionBlocked
    else { return }
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
          DashL10n.string(
            "The Cloudflare account for this link isn't available in Dash. Check your access and try again"
          )
        )
        return
      }
      accountRouteConfirmation = AccountScopedRouteRequest(account: account, route: route)
    case .rejectUnavailable:
      model.toasts.error(
        DashL10n.string(
          "The Cloudflare account for this link isn't available in Dash. Check your access and try again"
        )
      )
    }
  }

  private func confirmAccountSwitch(_ request: AccountScopedRouteRequest) {
    accountRouteConfirmation = nil
    guard let account = model.accounts.first(where: { $0.id == request.account.id }) else {
      model.toasts.error(
        DashL10n.string(
          "That Cloudflare account is no longer available in Dash. Refresh your accounts and try again"
        )
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
      .environment(\.dashNavigationCoordinator, navigationCoordinator)
      .environment(\.dashNavigationAnchorRegistry, navigationAnchorRegistry)
      .environment(\.dashWorkspacePresentationState, workspacePresentationState)
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
        default:
          break
        }
      }
      // Warms the Watchtower badge once per account, before the tab is
      // ever visited.
      .task(id: model.activeAccountID) {
        // Sign-out intentionally keeps the Settings page and its tray alive
        // through the success presentation. The ID becomes nil while that
        // phase is still active, so this task must honor the same retention
        // gate as the onChange handler below.
        guard
          DashNavigatorAccountScopeRules.shouldSynchronize(
            during: model.signOutActionPhase)
        else { return }
        synchronizeNavigatorAccountScopes()
        // A cold-launch deep link is set before this view mounts, so onChange
        // never fires for it — drain the inbox on first appearance too.
        if let route = model.pendingRoute { consume(route) }
        await model.refreshWatchtowerIfStale()
      }
      .onChange(of: model.pendingRoute) { _, route in
        if let route { consume(route) }
      }
      .onChange(of: routeConsumptionBlocked) { _, blocked in
        guard !blocked, let route = model.pendingRoute else { return }
        consume(route)
      }
      .onChange(of: model.signOutActionPhase) { _, phase in
        guard
          DashNavigatorAccountScopeRules.shouldSynchronize(during: phase),
          let route = model.pendingRoute
        else { return }
        consume(route)
      }
      .onChange(of: model.activeAccountID) { _, _ in
        // Sign-out clears the account before remote cleanup finishes. Keep the
        // account-switcher / Settings confirmation tray mounted through its loading and
        // success phases; AppRoot swaps to sign-in after the phase returns idle.
        guard
          DashNavigatorAccountScopeRules.shouldSynchronize(
            during: model.signOutActionPhase)
        else {
          showsIgnoreAllAlerts = false
          return
        }
        synchronizeNavigatorAccountScopes()
        watchtowerCustomization.cancelEditing()
        showsProfile = false
        showsIgnoreAllAlerts = false
        if let route = routeAfterAccountSwitch {
          routeAfterAccountSwitch = nil
          openVerifiedRoute(route)
        }
      }
      .onDisappear {
        completeTabTransitionImmediately()
      }
      .dashTray(
        isPresented: $showsProfile,
        title: DashL10n.string("Switch account"),
        content: {
          ProfileTrayContent(path: $profileTrayPath)
        },
        footer: {
          ProfileTrayFooter(path: $profileTrayPath) { account in
            model.selectAccount(account)
          }
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

  /// Tabs are cached in one physical workspace rather than arranged as a
  /// horizontal strip. A switch briefly exposes only the old and target roots,
  /// each travelling a few points with direction; shared chrome never moves.
  private var tabContainer: some View {
    ZStack(alignment: .bottom) {
      tabFlow

      sharedHeaderOverlay

      // Trays and pushed routes displace the bar; tab roots keep it mounted.
      ZStack(alignment: .bottom) {
        if !hidesDock {
          DashFloatingTabBar(
            selection: selection,
            watchtowerUnreadCount: model.watchtowerUnreadAlertCount ?? 0,
            onSelect: { tab in
              guard outgoingSelection == nil else { return }
              selectTab(tab)
            },
            onReselect: {
              guard outgoingSelection == nil else { return }
              popActiveTabToRoot()
            },
            onRequestIgnoreAllAlerts: { showsIgnoreAllAlerts = true }
          )
          .frame(maxWidth: .infinity)
          // Do NOT ignoresSafeArea(bottom) here — on iOS 26 that registers as a
          // bottom bar and paints a white scroll-edge pocket under the capsule.
          // Offset sinks the bar into the home-indicator inset instead.
          .offset(y: DashDockMetrics.bottomSink)
          .transition(tabBarTransition)
        }
      }
      .animation(tabBarVisibilityAnimation, value: hidesDock)
      .allowsHitTesting(!hidesDock && outgoingSelection == nil)
      .accessibilityHidden(outgoingSelection != nil)
    }
    // The workspace canvas and its ONE top light field stay behind the flow.
    // Tab roots remain transparent, so neither old nor incoming content carries
    // a duplicate wash through the directional handoff.
    .background {
      ZStack(alignment: .top) {
        DashTheme.canvas
        if workspaceWashPreset != .none {
          DashWorkspaceTopWash(
            color: DashTheme.workspaceWash(for: workspaceWashPreset),
            selectedScroll: workspaceWashScroll(for: selection),
            outgoingScroll: outgoingSelection.map { workspaceWashScroll(for: $0) },
            transitionProgress: tabTransitionProgress,
            reduceMotion: reduceMotion
          )
        }
      }
      .ignoresSafeArea()
    }
    // No toast host here either: the canvas copy and the tray cover's copy
    // were the two that doubled. `dashToastLayer` owns the only one.
  }

  private var tabFlow: some View {
    DashTabFlowHost(
      homeNavigator: homeNavigator,
      featuresNavigator: featuresNavigator,
      watchtowerNavigator: watchtowerNavigator,
      selection: selection,
      outgoingSelection: outgoingSelection,
      transitionDirection: tabTransitionDirection,
      transitionGeneration: tabTransitionGeneration,
      canPresentPendingHomeAction: !overlayTrays.presented,
      homeWorkspaceWashScroll: homeWashScroll,
      featuresWorkspaceWashScroll: featuresWashScroll,
      watchtowerWorkspaceWashScroll: watchtowerWashScroll,
      onHomePresentationStateChange: { state in
        pagePresentationStates[.home] = state
      },
      onFeaturesPresentationStateChange: { state in
        pagePresentationStates[.features] = state
      },
      onWatchtowerPresentationStateChange: { state in
        pagePresentationStates[.watchtower] = state
      },
      onTransitionCompleted: { source, target, generation in
        guard
          tabTransitionGeneration == generation,
          selection == target,
          outgoingSelection == source
        else { return }
        settleTabTransition()
      },
      home: {
        HomeView()
      },
      features: {
        FeatureCatalogView()
      },
      watchtower: {
        WatchtowerView(
          customization: watchtowerCustomization,
          cancelRequest: $watchtowerCancelRequest,
          commitRequest: $watchtowerCommitRequest,
          editorInteractionsReady: $watchtowerEditorInteractionsReady
        )
      }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ignoresSafeArea()
    // Navigation depth belongs to the UIKit page stack. Keep those mutations
    // out of the SwiftUI tab-flow transaction.
    .animation(nil, value: homeNavigator.depth)
    .animation(nil, value: featuresNavigator.depth)
    .animation(nil, value: watchtowerNavigator.depth)
  }

  /// ONE header layer above the tab flow — leading control, title, trailing
  /// controls, for every page in the workspace. Roots seat the avatar and the
  /// Watchtower inbox in the same slots a pushed page fills with Back, its
  /// title and its actions; chart editing hands those slots to Cancel +
  /// Add/Done. The bar itself never moves, and `MainTabView` deliberately does
  /// not read page chrome here — `DashWorkspaceHeaderBar` is the store's only
  /// reader, so a page's action change cannot refresh a cached page host.
  private var sharedHeaderOverlay: some View {
    // Removed, not faded to zero: Liquid Glass is composited outside a normal
    // opacity group on iOS 26, so an opacity-zero control can still paint over
    // the presentation that displaced it.
    ZStack {
      if !headerIsDisplaced {
        headerBar
      }
    }
    // A covering presentation does not carry a SwiftUI transaction, so the
    // shared layer supplies that fade. Tab switches and editor enter/exit
    // already originate in explicit settle/morph transactions.
    .animation(tabBarVisibilityAnimation, value: headerIsDisplaced)
    // Selection changes which navigator the slots read; keep that handoff
    // independent from displacement.
    .animation(tabBarVisibilityAnimation, value: selection)
    .allowsHitTesting(
      outgoingSelection == nil && !activePagePresentationState.isTransitioning
    )
    .accessibilityHidden(headerIsDisplaced || outgoingSelection != nil)
  }

  private var headerBar: some View {
    DashWorkspaceHeaderBar(
      navigator: activeNavigator,
      glassNamespace: workspaceHeaderGlass,
      showsProfileControl: true,
      showsWatchtowerInbox: showsWatchtowerInboxButton,
      watchtowerUnreadCount: model.watchtowerUnreadAlertCount ?? 0,
      watchtowerCustomization: watchtowerCustomization,
      isEditingWatchtower: showsWatchtowerEditorHeader,
      editorInteractionsReady: watchtowerEditorInteractionsReady,
      onPrepareNavigation: synchronizeNavigatorAccountScopes,
      onProfileLongPress: {
        // The path used to live inside the freshly mounted tray body. Reset
        // before presentation so an exit never swaps its content back to
        // Accounts while the card is still animating away.
        profileTrayPath = []
        showsProfile = true
      },
      onInboxLongPress: { showsIgnoreAllAlerts = true },
      onCancelEditing: { watchtowerCancelRequest &+= 1 },
      onCommitEditing: { watchtowerCommitRequest &+= 1 }
    )
    .transition(.opacity)
  }

  /// The floating bar rides in on first appearance without animation and slides
  /// on later navigation changes — SwiftUI only animates the value that flips.
  private var tabBarVisibilityAnimation: Animation {
    reduceMotion
      ? .easeOut(duration: DashTheme.Motion.Page.reducedDuration)
      : DashTheme.Motion.settle
  }

  private var tabBarTransition: AnyTransition {
    reduceMotion
      ? .opacity
      : .move(edge: .bottom).combined(with: .opacity)
  }

  private func selectTab(_ tab: AppTab, animated: Bool = true) {
    completeTabTransitionImmediately()
    guard tab != selection else { return }
    tabTransitionGeneration &+= 1

    guard animated else {
      selection = tab
      return
    }

    let source = selection
    withAnimation(
      reduceMotion
        ? .easeOut(duration: DashTheme.Motion.Page.reducedDuration)
        : DashTheme.Motion.tabStep
    ) {
      outgoingSelection = source
      tabTransitionDirection = DashTabTransitionRules.direction(from: source, to: tab)
      tabTransitionProgress = 1
      selection = tab
    }
  }

  private func completeTabTransitionImmediately() {
    guard outgoingSelection != nil else { return }
    tabTransitionGeneration &+= 1
    settleTabTransition()
  }

  private func settleTabTransition() {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      tabTransitionProgress = 0
      outgoingSelection = nil
      tabTransitionDirection = .stationary
    }
  }

  /// Re-tapping the active tab clears its navigation path.
  private func popActiveTabToRoot() {
    activeNavigator.popToRoot()
  }
}

/// The workspace's top light field: one continuous wash from the physical top
/// edge — status bar included — falling off sideways and down into the canvas.
///
/// ONE instance, painted by `MainTabView` *behind* the tab flow. It belongs to
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
@MainActor
struct DashWorkspaceTopWash: View, @MainActor Animatable {
  let color: Color
  /// Root scroll positions are read HERE and nowhere else. They move every
  /// frame, and this view is the only thing that should re-render for them.
  let selectedScroll: DashWorkspaceWashScroll
  let outgoingScroll: DashWorkspaceWashScroll?
  var transitionProgress: CGFloat
  let reduceMotion: Bool

  var animatableData: CGFloat {
    get { transitionProgress }
    set { transitionProgress = newValue }
  }

  /// Fall-off distance from the physical top edge.
  private let depth = DashWorkspaceWashRules.depth

  private var progress: CGFloat {
    min(max(transitionProgress, 0), 1)
  }

  private var scrollDistance: CGFloat {
    guard let outgoingScroll else { return selectedScroll.distance }
    return DashWorkspaceWashRules.blendedDistance(
      from: outgoingScroll.distance,
      to: selectedScroll.distance,
      progress: progress)
  }

  private var washField: some View {
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
  }

  @ViewBuilder
  var body: some View {
    Group {
      if reduceMotion, let outgoingScroll {
        // Reduced Motion keeps both fields stationary and crossfades them. The
        // normal path moves the one field between the two content positions.
        ZStack {
          washField
            .offset(y: -DashWorkspaceWashRules.lift(for: outgoingScroll.distance))
            .opacity(1 - progress)
          washField
            .offset(y: -DashWorkspaceWashRules.lift(for: selectedScroll.distance))
            .opacity(progress)
        }
      } else {
        washField
          .offset(y: -DashWorkspaceWashRules.lift(for: scrollDistance))
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
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
  let selection: AppTab
  let watchtowerUnreadCount: Int
  let onSelect: (AppTab) -> Void
  let onReselect: () -> Void
  var onRequestIgnoreAllAlerts: () -> Void = {}

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
      onSelect(tab)
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
  navigationDepth: Int,
  pageTransitionActive: Bool = false
) -> Bool {
  navigationDepth > 0 || overlays.presented || pageTransitionActive
}

/// The ONE workspace header leaves only for a presentation that covers it.
/// Navigation depth and page-transition state deliberately stay out of this:
/// a push no longer displaces the header, it changes what the header's slots
/// hold. The dock is the surface that still leaves on a push.
func shouldDisplaceWorkspaceHeader(overlays: DashTrayPresentation) -> Bool {
  overlays.presented
}
