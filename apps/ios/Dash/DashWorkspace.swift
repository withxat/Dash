import SwiftUI
import UIKit

// MARK: - Native NavigationStack host

struct DashPagePresentationState: Equatable {
  let settledDepth: Int
  let isTransitioning: Bool

  func resolvedDepth(navigatorDepth: Int) -> Int {
    max(navigatorDepth, settledDepth)
  }

  func occupiesWorkspace(navigatorDepth: Int) -> Bool {
    resolvedDepth(navigatorDepth: navigatorDepth) > 0 || isTransitioning
  }
}

struct DashPageStackRequest {
  let entries: [DashNavigationEntry]
  let revision: UInt64
  let mutation: DashNavigationMutation?
  let accountID: String?
  let reduceMotion: Bool
  let isTabActive: Bool
}

@MainActor
@Observable
private final class DashPageHostContext {
  var isTabActive: Bool
  var canPresentPendingHomeAction: Bool
  var splashLifted: Bool
  var workspaceWashScroll: DashWorkspaceWashScroll?
  var locale: Locale
  var dynamicTypeSize: DynamicTypeSize

  init(
    isTabActive: Bool,
    canPresentPendingHomeAction: Bool,
    splashLifted: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll?,
    locale: Locale,
    dynamicTypeSize: DynamicTypeSize
  ) {
    self.isTabActive = isTabActive
    self.canPresentPendingHomeAction = canPresentPendingHomeAction
    self.splashLifted = splashLifted
    self.workspaceWashScroll = workspaceWashScroll
    self.locale = locale
    self.dynamicTypeSize = dynamicTypeSize
  }

  func update(
    isTabActive: Bool,
    canPresentPendingHomeAction: Bool,
    splashLifted: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll?,
    locale: Locale,
    dynamicTypeSize: DynamicTypeSize
  ) {
    if self.isTabActive != isTabActive { self.isTabActive = isTabActive }
    if self.canPresentPendingHomeAction != canPresentPendingHomeAction {
      self.canPresentPendingHomeAction = canPresentPendingHomeAction
    }
    if self.splashLifted != splashLifted { self.splashLifted = splashLifted }
    if self.workspaceWashScroll !== workspaceWashScroll {
      self.workspaceWashScroll = workspaceWashScroll
    }
    if self.locale != locale { self.locale = locale }
    if self.dynamicTypeSize != dynamicTypeSize { self.dynamicTypeSize = dynamicTypeSize }
  }
}

@MainActor
private final class DashRootContentBox<Content: View> {
  let content: Content

  init(content: Content) {
    self.content = content
  }
}

/// Native SwiftUI `NavigationStack` bound directly to `DestinationNavigator`,
/// giving every tab standard iOS push/pop curves, native navigation bar
/// handoffs, and interactive left-edge swipe back.
struct DashNativeNavigationStack<Root: View>: View {
  @Bindable var navigator: DestinationNavigator
  let isTabActive: Bool
  let canPresentPendingHomeAction: Bool
  let splashLifted: Bool
  let workspaceWashScroll: DashWorkspaceWashScroll?
  let root: Root

  @Environment(\.dashNavigationCoordinator) private var navigationCoordinator

  var body: some View {
    NavigationStack(
      path: Binding(
        get: { navigator.entries },
        set: { navigator.syncFromNavigationStack($0) }
      )
    ) {
      root
        .environment(\.dashNavigationEntryID, nil)
        .environment(\.dashWorkspaceWashScroll, workspaceWashScroll)
        .navigationDestination(for: DashNavigationEntry.self) { entry in
          DashNativeDestinationView(entry: entry)
        }
    }
    .tint(DashTheme.brand)
    .environment(\.destinationNavigator, navigator)
    .environment(\.dashUsesCustomPageStack, false)
    .environment(\.dashTabActive, isTabActive)
    .environment(\.dashSplashLifted, splashLifted)
    .environment(\.dashCanPresentPendingHomeAction, canPresentPendingHomeAction)
    .onAppear {
      navigationCoordinator?.register(navigator)
    }
  }
}

private struct DashNativeDestinationView: View {
  let entry: DashNavigationEntry

  var body: some View {
    DestinationRoutedContent(destination: entry.destination)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.hidden, for: .navigationBar)
      .modifier(DashScrollEdgeEffectsHidden())
      .background { DashScrollViewConfigurator(fill: .canvas) }
      .background(DashTheme.canvas.ignoresSafeArea())
      .dashHeaderScrim()
      .environment(\.dashNavigationEntryID, entry.id)
      .environment(\.dashNavigationEntryHero, entry.origin?.hero)
      .environment(\.dashPageTransitionActive, false)
      .environment(\.dashWorkspaceWashScroll, nil)
  }
}

private struct DashHostedNavigationStack<Root: View>: View {
  let contentBox: DashRootContentBox<Root>
  let model: AppModel
  let navigator: DestinationNavigator
  let navigationCoordinator: DashNavigationCoordinator?
  let presentationState: DashWorkspacePresentationState?
  let hostContext: DashPageHostContext

  var body: some View {
    DashNativeNavigationStack(
      navigator: navigator,
      isTabActive: hostContext.isTabActive,
      canPresentPendingHomeAction: hostContext.canPresentPendingHomeAction,
      splashLifted: hostContext.splashLifted,
      workspaceWashScroll: hostContext.workspaceWashScroll,
      root: contentBox.content
    )
    .environment(model)
    .environment(\.dashNavigationCoordinator, navigationCoordinator)
    .environment(\.dashWorkspacePresentationState, presentationState)
    .environment(\.locale, hostContext.locale)
    .environment(\.dynamicTypeSize, hostContext.dynamicTypeSize)
  }
}

/// Thin hosting controller for one tab's native `NavigationStack`. Updates flow
/// through `DashPageHostContext` without reassigning `rootView`, so SwiftUI
/// navigation animations never get cancelled by parent tab-flow updates.
@MainActor
private final class DashNativeStackHostingController<Root: View>:
  UIHostingController<DashHostedNavigationStack<Root>>,
  DashScreenContainerController
{
  private let hostContext: DashPageHostContext

  init(
    root: Root,
    model: AppModel,
    navigator: DestinationNavigator,
    navigationCoordinator: DashNavigationCoordinator?,
    presentationState: DashWorkspacePresentationState?,
    isTabActive: Bool,
    canPresentPendingHomeAction: Bool,
    splashLifted: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll?,
    locale: Locale,
    dynamicTypeSize: DynamicTypeSize
  ) {
    let contentBox = DashRootContentBox(content: root)
    let hostContext = DashPageHostContext(
      isTabActive: isTabActive,
      canPresentPendingHomeAction: canPresentPendingHomeAction,
      splashLifted: splashLifted,
      workspaceWashScroll: workspaceWashScroll,
      locale: locale,
      dynamicTypeSize: dynamicTypeSize)
    self.hostContext = hostContext
    super.init(
      rootView: DashHostedNavigationStack(
        contentBox: contentBox,
        model: model,
        navigator: navigator,
        navigationCoordinator: navigationCoordinator,
        presentationState: presentationState,
        hostContext: hostContext))
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.isOpaque = false
  }

  func update(
    isTabActive: Bool,
    canPresentPendingHomeAction: Bool,
    splashLifted: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll?,
    locale: Locale,
    dynamicTypeSize: DynamicTypeSize
  ) {
    hostContext.update(
      isTabActive: isTabActive,
      canPresentPendingHomeAction: canPresentPendingHomeAction,
      splashLifted: splashLifted,
      workspaceWashScroll: workspaceWashScroll,
      locale: locale,
      dynamicTypeSize: dynamicTypeSize)
    loadViewIfNeeded()
    view.isUserInteractionEnabled = isTabActive
    view.accessibilityElementsHidden = !isTabActive
  }
}

@MainActor
func dashMakePageStackViewController<Root: View>(
  root: Root,
  model: AppModel,
  navigator: DestinationNavigator,
  navigationCoordinator: DashNavigationCoordinator?,
  presentationState: DashWorkspacePresentationState?,
  isTabActive: Bool,
  canPresentPendingHomeAction: Bool,
  splashLifted: Bool,
  workspaceWashScroll: DashWorkspaceWashScroll?,
  locale: Locale,
  dynamicTypeSize: DynamicTypeSize
) -> UIViewController {
  DashNativeStackHostingController(
    root: root,
    model: model,
    navigator: navigator,
    navigationCoordinator: navigationCoordinator,
    presentationState: presentationState,
    isTabActive: isTabActive,
    canPresentPendingHomeAction: canPresentPendingHomeAction,
    splashLifted: splashLifted,
    workspaceWashScroll: workspaceWashScroll,
    locale: locale,
    dynamicTypeSize: dynamicTypeSize)
}

@MainActor
func dashUpdatePageStackViewController<Root: View>(
  _ uiViewController: UIViewController,
  rootType _: Root.Type,
  isTabActive: Bool,
  canPresentPendingHomeAction: Bool,
  splashLifted: Bool,
  workspaceWashScroll: DashWorkspaceWashScroll?,
  locale: Locale,
  dynamicTypeSize: DynamicTypeSize
) {
  guard let controller = uiViewController as? DashNativeStackHostingController<Root> else {
    preconditionFailure("Unexpected Dash page stack controller type")
  }
  controller.update(
    isTabActive: isTabActive,
    canPresentPendingHomeAction: canPresentPendingHomeAction,
    splashLifted: splashLifted,
    workspaceWashScroll: workspaceWashScroll,
    locale: locale,
    dynamicTypeSize: dynamicTypeSize)
}
