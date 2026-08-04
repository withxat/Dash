import CloudflareAPI
import GradientAvatars
import SwiftUI
import UIKit

// MARK: - Destination navigator

enum DashNavigationPresentation: Hashable {
  /// A conventional child page whose chrome exposes Back.
  case detail
  /// A resource/card expansion. The custom renderer may bridge source identity.
  case entityDetail
  /// A workspace-level page whose root chrome exposes Close instead of Back.
  case workspaceOverlay
}

enum DashNavigationDismissal: Hashable {
  case back
  case closeToWorkspaceRoot
}

/// Stable product identity for a transition source. This is deliberately not a
/// localized title or list index; callers should use an immutable resource key.
struct DashNavigationSemanticID: Hashable {
  let namespace: String
  let value: String
}

/// One concrete occurrence of a semantic source. The same resource can appear
/// in Home recents, a feature list, and a pinned card at the same time.
struct DashNavigationOrigin: Hashable {
  let semanticID: DashNavigationSemanticID
  let anchorInstanceID: UUID
  /// Global frame captured synchronously with the navigation intent. The live
  /// source often unmounts in the same update that reveals the destination.
  let sourceFrame: CGRect?

  init(
    semanticID: DashNavigationSemanticID,
    anchorInstanceID: UUID,
    sourceFrame: CGRect? = nil
  ) {
    self.semanticID = semanticID
    self.anchorInstanceID = anchorInstanceID
    self.sourceFrame = sourceFrame
  }
}

/// Resource-family ownership used for atomic invalidation after deletion.
enum DashNavigationOwnership: Hashable {
  case zone(String)
  case r2Bucket(String)
}

/// Why the route collection changed. The custom renderer uses this instead of
/// guessing intent from an array diff (reset, close, and resource pruning all
/// have different transition and lifecycle contracts).
enum DashNavigationMutationReason: Hashable {
  case push
  case back
  case popToRoot
  case closeToWorkspaceRoot
  case reset
  case accountScopeChanged
  case resourcePruned(DashNavigationOwnership)
}

struct DashNavigationMutation: Hashable {
  let revision: UInt64
  let reason: DashNavigationMutationReason
  let previousEntryIDs: [UUID]
  let currentEntryIDs: [UUID]
}

/// A stable page instance. Repeating the same `Destination` later in the stack
/// creates a different entry so page lifetime never depends on value equality.
struct DashNavigationEntry: Identifiable, Hashable {
  let id: UUID
  let destination: Destination
  let presentation: DashNavigationPresentation
  let origin: DashNavigationOrigin?
  let accountID: String?
  let ownership: DashNavigationOwnership?

  var dismissal: DashNavigationDismissal {
    switch presentation {
    case .detail, .entityDetail:
      .back
    case .workspaceOverlay:
      .closeToWorkspaceRoot
    }
  }

  init(
    id: UUID = UUID(),
    destination: Destination,
    presentation: DashNavigationPresentation = .detail,
    origin: DashNavigationOrigin? = nil,
    accountID: String? = nil,
    ownership: DashNavigationOwnership? = nil
  ) {
    self.id = id
    self.destination = destination
    self.presentation = presentation
    self.origin = origin
    self.accountID = accountID
    self.ownership = ownership ?? destination.dashNavigationOwnership
  }
}

extension Destination {
  fileprivate var dashDefaultNavigationPresentation: DashNavigationPresentation {
    switch self {
    case .settings:
      .workspaceOverlay
    case .feature, .zone, .registrarDomain, .chartDetail, .worker, .tunnel,
      .pagesProject, .kvNamespace:
      .entityDetail
    case .r2Bucket(_, let prefix):
      prefix.isEmpty ? .entityDetail : .detail
    default:
      .detail
    }
  }

  fileprivate var dashNavigationOwnership: DashNavigationOwnership? {
    switch self {
    case .zone(let id), .dns(let id), .cache(let id), .zoneAnalytics(let id),
      .zoneWebAnalytics(let id), .zoneWAF(let id), .zoneSettings(let id),
      .zoneEmailRouting(let id):
      .zone(id)
    case .r2Bucket(let name, _), .r2BucketSettings(let name):
      .r2Bucket(name)
    default:
      nil
    }
  }
}

/// Per-tab page-instance store consumed by Dash's custom page container.
/// Business routing mutates this contract without depending on UIKit stack
/// semantics or view-value equality.
@MainActor
@Observable
final class DestinationNavigator {
  private(set) var entries: [DashNavigationEntry] = []
  private(set) var accountID: String?
  private(set) var revision: UInt64 = 0
  private(set) var lastMutation: DashNavigationMutation?

  var path: [Destination] { entries.map(\.destination) }
  var entryIDs: [DashNavigationEntry.ID] { entries.map(\.id) }
  var depth: Int { entries.count }
  var top: Destination? { entries.last?.destination }
  var topEntry: DashNavigationEntry? { entries.last }

  init(accountID: String? = nil) {
    self.accountID = accountID
  }

  @discardableResult
  func push(
    _ destination: Destination,
    presentation: DashNavigationPresentation? = nil,
    origin: DashNavigationOrigin? = nil
  ) -> DashNavigationEntry.ID? {
    // Debounce double-activation, or a fast double-tap stacks the screen twice.
    guard entries.last?.destination != destination else { return nil }
    let entry = DashNavigationEntry(
      destination: destination,
      presentation: presentation ?? destination.dashDefaultNavigationPresentation,
      origin: origin,
      accountID: self.accountID)
    replaceEntries(entries + [entry], reason: .push)
    return entry.id
  }

  func pop() {
    guard !entries.isEmpty else { return }
    replaceEntries(Array(entries.dropLast()), reason: .back)
  }

  func dismissTop() {
    guard let dismissal = entries.last?.dismissal else { return }
    switch dismissal {
    case .back:
      pop()
    case .closeToWorkspaceRoot:
      closeToWorkspaceRoot()
    }
  }

  func popToRoot() {
    replaceEntries([], reason: .popToRoot)
  }

  func closeToWorkspaceRoot() {
    replaceEntries([], reason: .closeToWorkspaceRoot)
  }

  func reset(
    to destination: Destination? = nil,
    presentation: DashNavigationPresentation? = nil,
    origin: DashNavigationOrigin? = nil
  ) {
    if let destination {
      replaceEntries(
        [
          DashNavigationEntry(
            destination: destination,
            presentation: presentation ?? destination.dashDefaultNavigationPresentation,
            origin: origin,
            accountID: self.accountID)
        ],
        reason: .reset)
    } else {
      replaceEntries([], reason: .reset)
    }
  }

  func contains(_ destination: Destination) -> Bool {
    entries.contains { $0.destination == destination }
  }

  func contains(entryID: DashNavigationEntry.ID) -> Bool {
    entries.contains { $0.id == entryID }
  }

  /// Changing Cloudflare identity invalidates every page instance before any
  /// new-account content can render inside an old route.
  func setAccountScope(_ accountID: String?) {
    guard self.accountID != accountID else { return }
    self.accountID = accountID
    replaceEntries([], reason: .accountScopeChanged, recordsNoop: true)
  }

  /// Removes a deleted resource and every child page it owns in one mutation,
  /// preserving the stable identities of unrelated survivor pages.
  func removeAll(ownedBy ownership: DashNavigationOwnership) {
    replaceEntries(
      entries.filter { $0.ownership != ownership },
      reason: .resourcePruned(ownership))
  }

  private func replaceEntries(
    _ nextEntries: [DashNavigationEntry],
    reason: DashNavigationMutationReason,
    recordsNoop: Bool = false
  ) {
    guard recordsNoop || nextEntries != entries else { return }
    let previousEntryIDs = entryIDs
    entries = nextEntries
    revision &+= 1
    lastMutation = DashNavigationMutation(
      revision: revision,
      reason: reason,
      previousEntryIDs: previousEntryIDs,
      currentEntryIDs: entryIDs)
  }
}

/// Workspace-wide invalidation for resources that can have live routes in
/// more than one tab. Deletion must not leave a cached page (or its work) alive
/// behind an off-screen tab.
@MainActor
final class DashNavigationCoordinator {
  private var navigators: [DestinationNavigator] = []

  func configure(navigators: [DestinationNavigator]) {
    self.navigators = navigators
  }

  func register(_ navigator: DestinationNavigator) {
    guard !navigators.contains(where: { $0 === navigator }) else { return }
    navigators.append(navigator)
  }

  func removeAll(ownedBy ownership: DashNavigationOwnership) {
    for navigator in navigators {
      navigator.removeAll(ownedBy: ownership)
    }
  }
}

/// Live geometry for concrete navigation-source occurrences. Entries only keep
/// the stable token; the transition renderer resolves the current frame at the
/// moment an animation starts and falls back when the source is no longer live.
@MainActor
final class DashNavigationAnchorRegistry {
  private var frames: [UUID: CGRect] = [:]

  func replaceFrames(_ frames: [UUID: CGRect]) {
    self.frames = frames
  }

  func frame(for origin: DashNavigationOrigin) -> CGRect? {
    frames[origin.anchorInstanceID] ?? origin.sourceFrame
  }

  func captureOrigin(
    semanticID: DashNavigationSemanticID,
    anchorInstanceID: UUID
  ) -> DashNavigationOrigin {
    DashNavigationOrigin(
      semanticID: semanticID,
      anchorInstanceID: anchorInstanceID,
      sourceFrame: frames[anchorInstanceID])
  }
}

struct DashNavigationAnchorFramesKey: PreferenceKey {
  static let defaultValue: [UUID: CGRect] = [:]

  static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
  }
}

// MARK: - Environment

private struct DestinationNavigatorKey: EnvironmentKey {
  static let defaultValue: DestinationNavigator? = nil
}

private struct DashTabActiveKey: EnvironmentKey {
  static let defaultValue = true
}

private struct DashNavigationEntryIDKey: EnvironmentKey {
  static let defaultValue: DashNavigationEntry.ID? = nil
}

private struct DashNavigationCoordinatorKey: EnvironmentKey {
  static let defaultValue: DashNavigationCoordinator? = nil
}

private struct DashNavigationAnchorRegistryKey: EnvironmentKey {
  static let defaultValue: DashNavigationAnchorRegistry? = nil
}

private struct DashUsesCustomPageStackKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var destinationNavigator: DestinationNavigator? {
    get { self[DestinationNavigatorKey.self] }
    set { self[DestinationNavigatorKey.self] = newValue }
  }

  /// True when this tab is the selected page, regardless of push depth. Every
  /// page stays mounted for the pager, so heavy roots gate their network loads
  /// on this to defer work until the tab is actually shown.
  var dashTabActive: Bool {
    get { self[DashTabActiveKey.self] }
    set { self[DashTabActiveKey.self] = newValue }
  }

  /// Stable identity of the page instance currently being rendered. Screens
  /// with long-lived work use this instead of comparing `Destination` values.
  var dashNavigationEntryID: DashNavigationEntry.ID? {
    get { self[DashNavigationEntryIDKey.self] }
    set { self[DashNavigationEntryIDKey.self] = newValue }
  }

  var dashNavigationCoordinator: DashNavigationCoordinator? {
    get { self[DashNavigationCoordinatorKey.self] }
    set { self[DashNavigationCoordinatorKey.self] = newValue }
  }

  var dashNavigationAnchorRegistry: DashNavigationAnchorRegistry? {
    get { self[DashNavigationAnchorRegistryKey.self] }
    set { self[DashNavigationAnchorRegistryKey.self] = newValue }
  }

  var dashUsesCustomPageStack: Bool {
    get { self[DashUsesCustomPageStackKey.self] }
    set { self[DashUsesCustomPageStackKey.self] = newValue }
  }
}

extension View {
  /// Registers the frame for this exact source occurrence. A semantic resource
  /// ID alone is insufficient when the same resource is visible in two places.
  func dashNavigationAnchor(instanceID: UUID) -> some View {
    background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: DashNavigationAnchorFramesKey.self,
          value: [instanceID: proxy.frame(in: .global)])
      }
    }
  }
}

// MARK: - Custom page stack

@MainActor
@Observable
private final class DashPageHostContext {
  var isTabActive: Bool
  var workspaceWashScroll: DashWorkspaceWashScroll?
  var locale: Locale
  var dynamicTypeSize: DynamicTypeSize

  init(
    isTabActive: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll?,
    locale: Locale,
    dynamicTypeSize: DynamicTypeSize
  ) {
    self.isTabActive = isTabActive
    self.workspaceWashScroll = workspaceWashScroll
    self.locale = locale
    self.dynamicTypeSize = dynamicTypeSize
  }

  func update(
    isTabActive: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll?,
    locale: Locale,
    dynamicTypeSize: DynamicTypeSize
  ) {
    self.isTabActive = isTabActive
    self.workspaceWashScroll = workspaceWashScroll
    self.locale = locale
    self.dynamicTypeSize = dynamicTypeSize
  }
}

@MainActor
@Observable
private final class DashRootContentBox<Content: View> {
  var content: Content

  init(content: Content) {
    self.content = content
  }
}

private struct DashHostedRoot<Root: View>: View {
  let contentBox: DashRootContentBox<Root>
  let model: AppModel
  let navigator: DestinationNavigator
  let navigationCoordinator: DashNavigationCoordinator?
  let anchorRegistry: DashNavigationAnchorRegistry?
  let presentationState: DashWorkspacePresentationState?
  let hostContext: DashPageHostContext

  var body: some View {
    DashRoutePageChromeHost(entry: nil) {
      contentBox.content
    }
    .tint(DashTheme.brand)
    .environment(model)
    .environment(\.destinationNavigator, navigator)
    .environment(\.dashNavigationCoordinator, navigationCoordinator)
    .environment(\.dashNavigationAnchorRegistry, anchorRegistry)
    .environment(\.dashWorkspacePresentationState, presentationState)
    .environment(\.dashUsesCustomPageStack, true)
    .environment(\.dashNavigationEntryID, nil)
    .environment(\.dashTabActive, hostContext.isTabActive)
    .environment(
      \.dashWorkspaceWashScroll,
      hostContext.isTabActive ? hostContext.workspaceWashScroll : nil
    )
    .environment(\.locale, hostContext.locale)
    .environment(\.dynamicTypeSize, hostContext.dynamicTypeSize)
  }
}

private struct DashHostedDestination: View {
  let entry: DashNavigationEntry
  let model: AppModel
  let navigator: DestinationNavigator
  let navigationCoordinator: DashNavigationCoordinator?
  let anchorRegistry: DashNavigationAnchorRegistry?
  let presentationState: DashWorkspacePresentationState?
  let hostContext: DashPageHostContext

  var body: some View {
    DashRoutePageChromeHost(entry: entry) {
      DestinationRoutedContent(destination: entry.destination)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .modifier(DashScrollEdgeEffectsHidden())
    .background { DashScrollViewConfigurator(fill: .canvas) }
    .background(DashTheme.canvas.ignoresSafeArea())
    .tint(DashTheme.brand)
    .environment(model)
    .environment(\.destinationNavigator, navigator)
    .environment(\.dashNavigationCoordinator, navigationCoordinator)
    .environment(\.dashNavigationAnchorRegistry, anchorRegistry)
    .environment(\.dashWorkspacePresentationState, presentationState)
    .environment(\.dashUsesCustomPageStack, true)
    .environment(\.dashNavigationEntryID, entry.id)
    .environment(\.dashTabActive, hostContext.isTabActive)
    .environment(\.dashWorkspaceWashScroll, nil)
    .environment(\.locale, hostContext.locale)
    .environment(\.dynamicTypeSize, hostContext.dynamicTypeSize)
  }
}

private enum DashPageTransitionStyle {
  case detailPush
  case detailPop
  case workspacePresent
  case workspaceDismiss
}

private struct DashPageStackRequest {
  let entries: [DashNavigationEntry]
  let revision: UInt64
  let mutation: DashNavigationMutation?
  let accountID: String?
  let reduceMotion: Bool
  let isTabActive: Bool
}

/// A UIKit containment controller, deliberately not a `UINavigationController`.
/// It caches one immutable hosting controller per route-entry UUID, while only
/// the visible page participates in the hierarchy outside a transition.
@MainActor
private final class DashPageStackViewController<Root: View>: UIViewController,
  DashScreenContainerController
{
  private struct EntryHost {
    let entry: DashNavigationEntry
    let controller: UIHostingController<DashHostedDestination>
  }

  private struct ActiveTransition {
    let animator: UIViewPropertyAnimator
    let source: UIViewController
    let target: UIViewController
    let desiredEntries: [DashNavigationEntry]
    let revision: UInt64
    let appearanceWasBegun: Bool
  }

  private let contentBox: DashRootContentBox<Root>
  private let hostContext: DashPageHostContext
  private let model: AppModel
  private let navigator: DestinationNavigator
  private let navigationCoordinator: DashNavigationCoordinator?
  private let anchorRegistry: DashNavigationAnchorRegistry?
  private let presentationState: DashWorkspacePresentationState?
  private let rootController: UIHostingController<DashHostedRoot<Root>>

  private var entryHosts: [DashNavigationEntry.ID: EntryHost] = [:]
  private var settledEntries: [DashNavigationEntry] = []
  private var settledRevision: UInt64 = 0
  private var visibleController: UIViewController?
  private var activeTransition: ActiveTransition?
  private var pendingRequest: DashPageStackRequest?
  private var accountID: String?
  private var isContainerVisible = false
  private var parentAppearanceIsDisappearing = false
  /// The exact child whose parent-driven appearance transition was begun.
  /// Route updates are deferred until this is ended so begin/end can never
  /// land on different cached pages.
  private var parentAppearanceTransitionChild: UIViewController?

  override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }

  init(
    root: Root,
    model: AppModel,
    navigator: DestinationNavigator,
    navigationCoordinator: DashNavigationCoordinator?,
    anchorRegistry: DashNavigationAnchorRegistry?,
    presentationState: DashWorkspacePresentationState?,
    isTabActive: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll?,
    locale: Locale,
    dynamicTypeSize: DynamicTypeSize,
    accountID: String?
  ) {
    let contentBox = DashRootContentBox(content: root)
    let hostContext = DashPageHostContext(
      isTabActive: isTabActive,
      workspaceWashScroll: workspaceWashScroll,
      locale: locale,
      dynamicTypeSize: dynamicTypeSize)
    self.contentBox = contentBox
    self.hostContext = hostContext
    self.model = model
    self.navigator = navigator
    self.navigationCoordinator = navigationCoordinator
    self.anchorRegistry = anchorRegistry
    self.presentationState = presentationState
    self.accountID = accountID
    self.rootController = UIHostingController(
      rootView: DashHostedRoot(
        contentBox: contentBox,
        model: model,
        navigator: navigator,
        navigationCoordinator: navigationCoordinator,
        anchorRegistry: anchorRegistry,
        presentationState: presentationState,
        hostContext: hostContext))
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.isOpaque = false
    view.clipsToBounds = true
    rootController.view.backgroundColor = .clear
    attach(rootController, above: nil)
    visibleController = rootController
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    for child in children {
      child.view.frame = view.bounds
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    finishParentChildAppearanceTransition()
    parentAppearanceIsDisappearing = false
    if let visibleController {
      visibleController.beginAppearanceTransition(true, animated: animated)
      parentAppearanceTransitionChild = visibleController
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    finishParentChildAppearanceTransition()
    isContainerVisible = true
    reconcilePendingRequestIfNeeded()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    finishParentChildAppearanceTransition()
    isContainerVisible = false
    parentAppearanceIsDisappearing = true
    finishActiveTransitionImmediately()
    if let visibleController {
      visibleController.beginAppearanceTransition(false, animated: animated)
      parentAppearanceTransitionChild = visibleController
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    finishParentChildAppearanceTransition()
    parentAppearanceIsDisappearing = false
    super.viewDidDisappear(animated)
    reconcilePendingRequestIfNeeded()
  }

  func update(
    root: Root,
    isTabActive: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll?,
    locale: Locale,
    dynamicTypeSize: DynamicTypeSize,
    request: DashPageStackRequest
  ) {
    contentBox.content = root
    hostContext.update(
      isTabActive: isTabActive,
      workspaceWashScroll: workspaceWashScroll,
      locale: locale,
      dynamicTypeSize: dynamicTypeSize)
    loadViewIfNeeded()
    reconcile(request)
  }

  private func reconcile(_ request: DashPageStackRequest) {
    let newestKnownRevision = max(
      settledRevision,
      max(activeTransition?.revision ?? 0, pendingRequest?.revision ?? 0))
    guard request.revision >= newestKnownRevision else { return }

    if parentAppearanceTransitionChild != nil {
      pendingRequest = request
      return
    }

    if request.accountID != accountID {
      accountID = request.accountID
      pendingRequest = nil
      finishActiveTransitionImmediately()
      installImmediately(request.entries, revision: request.revision)
      return
    }

    if activeTransition != nil {
      pendingRequest = request
      return
    }

    let desiredIDs = request.entries.map(\.id)
    let settledIDs = settledEntries.map(\.id)
    guard desiredIDs != settledIDs else {
      settledEntries = request.entries
      settledRevision = max(settledRevision, request.revision)
      return
    }

    guard isContainerVisible, request.isTabActive else {
      installImmediately(request.entries, revision: request.revision)
      return
    }

    switch request.mutation?.reason {
    case .reset, .accountScopeChanged:
      installImmediately(request.entries, revision: request.revision)
      return
    default:
      break
    }

    if let reason = request.mutation?.reason,
      case .resourcePruned = reason
    {
      // The concrete resource value is irrelevant here; a middle prune whose
      // top survives should not animate or disturb the visible page.
      if desiredIDs.last == settledIDs.last {
        settledEntries = request.entries
        settledRevision = request.revision
        purgeEntryHosts(retaining: Set(desiredIDs))
        return
      }
    }

    guard let source = visibleController else {
      installImmediately(request.entries, revision: request.revision)
      return
    }
    let target = controller(for: request.entries)
    guard source !== target else {
      settledEntries = request.entries
      settledRevision = request.revision
      purgeEntryHosts(retaining: Set(desiredIDs))
      return
    }

    let style = transitionStyle(for: request)
    performTransition(
      from: source,
      to: target,
      style: style,
      request: request)
  }

  private func transitionStyle(for request: DashPageStackRequest) -> DashPageTransitionStyle {
    switch request.mutation?.reason {
    case .push:
      return request.entries.last?.presentation == .workspaceOverlay
        ? .workspacePresent : .detailPush
    case .closeToWorkspaceRoot:
      return .workspaceDismiss
    case .back, .popToRoot, .resourcePruned:
      return settledEntries.last?.presentation == .workspaceOverlay
        ? .workspaceDismiss : .detailPop
    case .reset, .accountScopeChanged, nil:
      return .detailPush
    }
  }

  private func performTransition(
    from source: UIViewController,
    to target: UIViewController,
    style: DashPageTransitionStyle,
    request: DashPageStackRequest
  ) {
    let isPush: Bool
    switch style {
    case .detailPush, .workspacePresent: isPush = true
    case .detailPop, .workspaceDismiss: isPush = false
    }
    attach(target, above: isPush ? source : nil)
    if !isPush {
      view.insertSubview(target.view, belowSubview: source.view)
    }
    view.layoutIfNeeded()
    resetTransitionState(source.view)
    resetTransitionState(target.view)
    source.view.isUserInteractionEnabled = false
    target.view.isUserInteractionEnabled = false
    applyInitialTransitionState(
      style: style,
      source: source.view,
      target: target.view,
      reduceMotion: request.reduceMotion)

    let appearanceWasBegun = isContainerVisible && !parentAppearanceIsDisappearing
    if appearanceWasBegun {
      source.beginAppearanceTransition(false, animated: true)
      target.beginAppearanceTransition(true, animated: true)
    }

    let duration = request.reduceMotion ? 0.2 : 0.42
    let animator = UIViewPropertyAnimator(
      duration: duration,
      dampingRatio: request.reduceMotion ? 1 : 0.9)
    animator.addAnimations { [weak self, weak source, weak target] in
      guard let self, let source, let target else { return }
      self.applyFinalTransitionState(
        style: style,
        source: source.view,
        target: target.view,
        reduceMotion: request.reduceMotion)
    }
    activeTransition = ActiveTransition(
      animator: animator,
      source: source,
      target: target,
      desiredEntries: request.entries,
      revision: request.revision,
      appearanceWasBegun: appearanceWasBegun)
    animator.addCompletion { [weak self, weak animator] _ in
      guard let self, let animator,
        self.activeTransition?.animator === animator
      else { return }
      self.completeActiveTransition()
    }
    animator.startAnimation()
  }

  private func applyInitialTransitionState(
    style: DashPageTransitionStyle,
    source: UIView,
    target: UIView,
    reduceMotion: Bool
  ) {
    let travel = min(max(view.bounds.width * 0.08, 22), 34)
    let direction: CGFloat =
      view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
    switch style {
    case .detailPush:
      target.alpha = 0
      if !reduceMotion {
        target.transform = CGAffineTransform(translationX: travel * direction, y: 0)
      }
    case .detailPop:
      target.alpha = reduceMotion ? 0 : 0.96
      if !reduceMotion {
        target.transform = CGAffineTransform(
          translationX: -travel * 0.35 * direction,
          y: 0)
      }
    case .workspacePresent:
      target.alpha = 0
      if !reduceMotion { target.transform = CGAffineTransform(scaleX: 0.985, y: 0.985) }
    case .workspaceDismiss:
      target.alpha = reduceMotion ? 0 : 1
    }
    source.alpha = 1
  }

  private func applyFinalTransitionState(
    style: DashPageTransitionStyle,
    source: UIView,
    target: UIView,
    reduceMotion: Bool
  ) {
    let direction: CGFloat =
      view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
    target.alpha = 1
    target.transform = .identity
    switch style {
    case .detailPush:
      if !reduceMotion {
        source.transform = CGAffineTransform(translationX: -8 * direction, y: 0)
      }
    case .detailPop:
      source.alpha = 0
      if !reduceMotion {
        source.transform = CGAffineTransform(translationX: 28 * direction, y: 0)
      }
    case .workspacePresent:
      break
    case .workspaceDismiss:
      source.alpha = 0
      if !reduceMotion { source.transform = CGAffineTransform(scaleX: 0.985, y: 0.985) }
    }
  }

  private func completeActiveTransition() {
    guard let transition = activeTransition else { return }
    resetTransitionState(transition.source.view)
    resetTransitionState(transition.target.view)
    transition.source.view.isUserInteractionEnabled = true
    transition.target.view.isUserInteractionEnabled = true
    if transition.appearanceWasBegun {
      transition.source.endAppearanceTransition()
      transition.target.endAppearanceTransition()
    }
    detach(transition.source)
    visibleController = transition.target
    settledEntries = transition.desiredEntries
    settledRevision = transition.revision
    activeTransition = nil
    purgeEntryHosts(retaining: Set(settledEntries.map(\.id)))
    let pendingChangesVisiblePage =
      pendingRequest.map {
        $0.entries.last?.id != transition.desiredEntries.last?.id
      } ?? false
    if isContainerVisible, hostContext.isTabActive, !pendingChangesVisiblePage {
      UIAccessibility.post(notification: .screenChanged, argument: transition.target.view)
    }
    if let pendingRequest {
      self.pendingRequest = nil
      reconcile(pendingRequest)
    }
  }

  private func finishActiveTransitionImmediately() {
    guard let transition = activeTransition else { return }
    transition.animator.stopAnimation(true)
    resetTransitionState(transition.source.view)
    resetTransitionState(transition.target.view)
    transition.source.view.isUserInteractionEnabled = true
    transition.target.view.isUserInteractionEnabled = true
    if transition.appearanceWasBegun {
      transition.source.endAppearanceTransition()
      transition.target.endAppearanceTransition()
    }
    detach(transition.source)
    visibleController = transition.target
    settledEntries = transition.desiredEntries
    settledRevision = transition.revision
    activeTransition = nil
    purgeEntryHosts(retaining: Set(settledEntries.map(\.id)))
  }

  private func finishParentChildAppearanceTransition() {
    parentAppearanceTransitionChild?.endAppearanceTransition()
    parentAppearanceTransitionChild = nil
  }

  private func reconcilePendingRequestIfNeeded() {
    guard let pendingRequest else { return }
    self.pendingRequest = nil
    reconcile(pendingRequest)
  }

  private func installImmediately(_ entries: [DashNavigationEntry], revision: UInt64) {
    finishActiveTransitionImmediately()
    let target = controller(for: entries)
    if visibleController !== target {
      let source = visibleController
      let forwardsAppearance = isContainerVisible && !parentAppearanceIsDisappearing
      attach(target, above: source)
      if forwardsAppearance {
        source?.beginAppearanceTransition(false, animated: false)
        target.beginAppearanceTransition(true, animated: false)
      }
      if forwardsAppearance {
        source?.endAppearanceTransition()
        target.endAppearanceTransition()
      }
      if let source { detach(source) }
      visibleController = target
      if forwardsAppearance, hostContext.isTabActive {
        UIAccessibility.post(notification: .screenChanged, argument: target.view)
      }
    }
    resetTransitionState(target.view)
    target.view.isUserInteractionEnabled = true
    settledEntries = entries
    settledRevision = revision
    purgeEntryHosts(retaining: Set(entries.map(\.id)))
  }

  private func controller(for entries: [DashNavigationEntry]) -> UIViewController {
    guard let entry = entries.last else { return rootController }
    if let cached = entryHosts[entry.id] { return cached.controller }
    let controller = UIHostingController(
      rootView: DashHostedDestination(
        entry: entry,
        model: model,
        navigator: navigator,
        navigationCoordinator: navigationCoordinator,
        anchorRegistry: anchorRegistry,
        presentationState: presentationState,
        hostContext: hostContext))
    controller.view.backgroundColor = .clear
    entryHosts[entry.id] = EntryHost(entry: entry, controller: controller)
    return controller
  }

  private func purgeEntryHosts(retaining retainedIDs: Set<DashNavigationEntry.ID>) {
    let removedIDs = entryHosts.keys.filter { !retainedIDs.contains($0) }
    for id in removedIDs {
      if let controller = entryHosts[id]?.controller,
        controller !== visibleController
      {
        detach(controller)
      }
      presentationState?.removeTrayReporters(forEntryID: id)
      entryHosts[id] = nil
    }
  }

  private func attach(_ child: UIViewController, above sibling: UIViewController?) {
    guard child.parent !== self else {
      child.view.frame = view.bounds
      if let sibling, sibling.view.superview === view {
        view.insertSubview(child.view, aboveSubview: sibling.view)
      } else {
        view.bringSubviewToFront(child.view)
      }
      return
    }
    addChild(child)
    child.view.frame = view.bounds
    child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    if let sibling, sibling.view.superview === view {
      view.insertSubview(child.view, aboveSubview: sibling.view)
    } else {
      view.addSubview(child.view)
    }
    child.didMove(toParent: self)
  }

  private func detach(_ child: UIViewController) {
    guard child.parent === self else { return }
    child.willMove(toParent: nil)
    child.view.removeFromSuperview()
    child.removeFromParent()
  }

  private func resetTransitionState(_ view: UIView) {
    view.layer.removeAllAnimations()
    view.alpha = 1
    view.transform = .identity
  }
}

private struct DashPageStackHost<Root: View>: UIViewControllerRepresentable {
  @Bindable var navigator: DestinationNavigator
  var isTabActive: Bool
  @ViewBuilder var root: () -> Root

  @Environment(AppModel.self) private var model
  @Environment(\.dashNavigationCoordinator) private var navigationCoordinator
  @Environment(\.dashNavigationAnchorRegistry) private var anchorRegistry
  @Environment(\.dashWorkspacePresentationState) private var presentationState
  @Environment(\.dashWorkspaceWashScroll) private var workspaceWashScroll
  @Environment(\.locale) private var locale
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeUIViewController(context: Context) -> DashPageStackViewController<Root> {
    DashPageStackViewController(
      root: root(),
      model: model,
      navigator: navigator,
      navigationCoordinator: navigationCoordinator,
      anchorRegistry: anchorRegistry,
      presentationState: presentationState,
      isTabActive: isTabActive,
      workspaceWashScroll: workspaceWashScroll,
      locale: locale,
      dynamicTypeSize: dynamicTypeSize,
      accountID: navigator.accountID)
  }

  func updateUIViewController(
    _ uiViewController: DashPageStackViewController<Root>,
    context: Context
  ) {
    uiViewController.update(
      root: root(),
      isTabActive: isTabActive,
      workspaceWashScroll: workspaceWashScroll,
      locale: locale,
      dynamicTypeSize: dynamicTypeSize,
      request: DashPageStackRequest(
        entries: navigator.entries,
        revision: navigator.revision,
        mutation: navigator.lastMutation,
        accountID: navigator.accountID,
        reduceMotion: reduceMotion,
        isTabActive: isTabActive))
  }
}

// MARK: - Tab stack

/// Per-tab host for Dash's own page stack. Every route is a cached SwiftUI page
/// controller inside a plain UIKit container — no `UINavigationController`,
/// system stack, or edge-pop recognizer participates.
struct DestinationStackHost<Root: View>: View {
  @Bindable var navigator: DestinationNavigator
  @Environment(\.dashNavigationCoordinator) private var navigationCoordinator
  var isTabActive: Bool
  @ViewBuilder var root: () -> Root

  var body: some View {
    DashPageStackHost(
      navigator: navigator,
      isTabActive: isTabActive,
      root: root
    )
    .onAppear {
      navigationCoordinator?.register(navigator)
    }
  }

}

// MARK: - Destination routing

struct DestinationRoutedContent: View {
  @Environment(AppModel.self) private var model
  let destination: Destination

  private var allowsWrites: Bool {
    let scopes = writeScopes(for: destination)
    return scopes.isEmpty || model.hasScopes(scopes)
  }

  var body: some View {
    Group {
      switch destination {
      case .profile: ProfileView()
      case .settings: SettingsView()
      case .settingsAccounts: SettingsAccountsView()
      case .about: AboutView()
      case .openSource: OpenSourceView()
      #if DEBUG
        case .debug: DebugView()
      #endif
      case .feature(let feature):
        FeatureRouterContent(feature: feature)
      case .zone(let id): ZoneDetailView(zoneID: id)
      case .dns(let id): DNSRecordsView(zoneID: id)
      case .cache(let id): CachePurgeView(zoneID: id)
      case .zoneAnalytics(let id): ZoneAnalyticsView(zoneID: id)
      case .zoneWebAnalytics(let id): WebAnalyticsView(zoneID: id)
      case .zoneWAF(let id): WAFEventsView(zoneID: id)
      case .zoneSettings(let id): ZoneSettingsView(zoneID: id)
      case .zoneEmailRouting(let id): EmailRoutingView(zoneID: id)
      case .auditLogs: AuditLogView()
      case .pushAlerts: PushAlertsView()
      case .watchtowerInbox: WatchtowerInboxView()
      case .cloudflareStatus: CloudflareStatusView()
      case .emailAddresses: EmailDestinationAddressesView()
      case .registrarDomain(let domain): RegistrarDomainDetailView(domain: domain)
      case .chartDetail(let detail): DashChartDetailView(detail: detail)
      case .worker(let name): WorkerDetailView(name: name)
      case .tunnel(let id): TunnelDetailView(tunnelID: id)
      case .pagesProject(let name): PagesProjectDetailView(projectName: name)
      case .pagesDeployment(let project, let deploymentID):
        PagesDeploymentDetailView(projectName: project, deploymentID: deploymentID)
      case .pagesDomains(let name): PagesDomainsView(projectName: name)
      case .r2Bucket(let name, let prefix): R2BucketView(bucket: name, folderPrefix: prefix)
      case .r2BucketSettings(let name): R2BucketSettingsView(bucket: name)
      case .kvNamespace(let id): KVNamespaceView(namespaceID: id)
      case .kvKey(let namespaceID, let key):
        KVKeyDetailView(namespaceID: namespaceID, key: key)
      }
    }
    .environment(\.featureAllowsWrites, allowsWrites)
    .environment(\.featureRequiredScopes, readScopes(for: destination))
    .environment(\.featureIdentity, featureID(for: destination))
  }
}

// MARK: - Detail header

/// The identity glyph a detail screen shows ahead of its inline title.
enum DetailIcon {
  case feature(FeatureID)
  case avatar(String)
  case solar(String)
}

struct DetailIconView: View {
  let icon: DetailIcon
  var tint: Color = DashTheme.brand

  var body: some View {
    switch icon {
    case .feature(let feature):
      CatalogFeatureIcon(feature: feature, size: .compact)
    case .avatar(let seed):
      GradientAvatar(seed: seed, size: 24, pattern: .dither, contentScale: 1.5)
    case .solar(let asset):
      SolarIcon(asset: asset, size: 20, color: tint)
    }
  }
}

struct DashPageHeaderDescriptor {
  let icon: DetailIcon
  let title: String
  let tint: Color
}

struct DashPageActionDescriptor: Identifiable {
  enum Label {
    case icon(
      asset: String,
      accessibilityLabel: String,
      variant: DashToolbarIconButton.Variant
    )
    case text(title: String)
  }

  let id: String
  let label: Label
  let isEnabled: Bool
  let disabledOpacity: Double?
  let accessibilityIdentifier: String?
  let action: () -> Void

  static func icon(
    id: String,
    asset: String,
    accessibilityLabel: String,
    variant: DashToolbarIconButton.Variant = .standard,
    isEnabled: Bool = true,
    disabledOpacity: Double? = nil,
    accessibilityIdentifier: String? = nil,
    action: @escaping () -> Void
  ) -> Self {
    Self(
      id: id,
      label: .icon(
        asset: asset,
        accessibilityLabel: accessibilityLabel,
        variant: variant),
      isEnabled: isEnabled,
      disabledOpacity: disabledOpacity,
      accessibilityIdentifier: accessibilityIdentifier,
      action: action)
  }

  static func text(
    id: String,
    title: String,
    isEnabled: Bool = true,
    disabledOpacity: Double? = nil,
    accessibilityIdentifier: String? = nil,
    action: @escaping () -> Void
  ) -> Self {
    Self(
      id: id,
      label: .text(title: title),
      isEnabled: isEnabled,
      disabledOpacity: disabledOpacity,
      accessibilityIdentifier: accessibilityIdentifier,
      action: action)
  }
}

struct DashPageChromePreference {
  var header: DashPageHeaderDescriptor? = nil
  var leadingActions: [DashPageActionDescriptor] = []
  var trailingActions: [DashPageActionDescriptor] = []
}

struct DashPageChromePreferenceKey: PreferenceKey {
  static var defaultValue: DashPageChromePreference { DashPageChromePreference() }

  static func reduce(
    value: inout DashPageChromePreference,
    nextValue: () -> DashPageChromePreference
  ) {
    let next = nextValue()
    if let header = next.header { value.header = header }
    value.leadingActions = merge(value.leadingActions, with: next.leadingActions)
    value.trailingActions = merge(value.trailingActions, with: next.trailingActions)
  }

  private static func merge(
    _ current: [DashPageActionDescriptor],
    with next: [DashPageActionDescriptor]
  ) -> [DashPageActionDescriptor] {
    var merged = current
    for action in next {
      if let index = merged.firstIndex(where: { $0.id == action.id }) {
        merged[index] = action
      } else {
        merged.append(action)
      }
    }
    return merged
  }
}

private struct DashPageActionControl: View {
  let descriptor: DashPageActionDescriptor

  @ViewBuilder private var control: some View {
    switch descriptor.label {
    case .icon(let asset, let accessibilityLabel, let variant):
      DashToolbarIconButton(
        asset: asset,
        accessibilityLabel: accessibilityLabel,
        variant: variant,
        action: descriptor.action)
    case .text(let title):
      DashToolbarTextButton(title: title, action: descriptor.action)
    }
  }

  var body: some View {
    if let identifier = descriptor.accessibilityIdentifier {
      control
        .disabled(!descriptor.isEnabled)
        .opacity(resolvedOpacity)
        .accessibilityIdentifier(identifier)
    } else {
      control
        .disabled(!descriptor.isEnabled)
        .opacity(resolvedOpacity)
    }
  }

  private var resolvedOpacity: Double {
    descriptor.isEnabled ? 1 : (descriptor.disabledOpacity ?? 1)
  }
}

private struct DashPageActionGroupView: View {
  let actions: [DashPageActionDescriptor]

  var body: some View {
    DashToolbarActionGroup {
      ForEach(actions) { action in
        DashPageActionControl(descriptor: action)
      }
    }
  }
}

enum DashPageChromeMetrics {
  static let controlSize = AvatarHeaderMetrics.barSize
  static let topInset = AvatarHeaderMetrics.chromeInset
  static let horizontalInset = AvatarHeaderMetrics.chromeInset
  static let reservedHeight = controlSize + topInset
  static let actionSpacing: CGFloat = 8
  static let maximumPrincipalWidth: CGFloat = 160
}

private struct DashPageNavigationBar: View {
  let entry: DashNavigationEntry
  let chrome: DashPageChromePreference
  let dismiss: () -> Void
  @Environment(\.layoutDirection) private var layoutDirection

  var body: some View {
    ZStack {
      if let header = chrome.header {
        HStack(spacing: 6) {
          DetailIconView(icon: header.icon, tint: header.tint)
            .layoutPriority(1)
          Text(header.title)
            .dashTextStyle(.sectionTitle)
            .foregroundStyle(DashTheme.strong)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("dash.navigation.title")
        }
        .frame(maxWidth: DashPageChromeMetrics.maximumPrincipalWidth)
      }

      HStack(spacing: DashPageChromeMetrics.actionSpacing) {
        leadingControl
        Spacer(minLength: 0)
        if !chrome.trailingActions.isEmpty {
          DashPageActionGroupView(actions: chrome.trailingActions)
        }
      }
    }
    .frame(height: DashPageChromeMetrics.controlSize)
    .padding(.horizontal, DashPageChromeMetrics.horizontalInset)
    .padding(.top, DashPageChromeMetrics.topInset)
    .frame(maxWidth: .infinity, alignment: .top)
  }

  @ViewBuilder private var leadingControl: some View {
    if !chrome.leadingActions.isEmpty {
      DashPageActionGroupView(actions: chrome.leadingActions)
    } else {
      switch entry.dismissal {
      case .back:
        DashToolbarIconButton(
          asset: layoutDirection == .rightToLeft
            ? SolarAsset.chevronRight : SolarAsset.chevronLeft,
          accessibilityLabel: DashL10n.string("Back"),
          action: dismiss
        )
        .accessibilityIdentifier("dash.navigation.back")
      case .closeToWorkspaceRoot:
        DashToolbarIconButton(
          asset: SolarAsset.close,
          accessibilityLabel: DashL10n.string("Close"),
          action: dismiss
        )
        .accessibilityIdentifier("dash.navigation.close")
      }
    }
  }
}

private struct DashPageEscapeActionModifier: ViewModifier {
  let isEnabled: Bool
  let action: () -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content.accessibilityAction(.escape, action)
    } else {
      content
    }
  }
}

/// Page-local custom chrome used by Dash's UIKit page container. It
/// deliberately lives in the same SwiftUI tree as the page so dynamic actions,
/// frost, and scroll probing retain their existing ownership.
struct DashRoutePageChromeHost<Content: View>: View {
  let entry: DashNavigationEntry?
  @ViewBuilder var content: () -> Content
  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.dashWorkspaceWashScroll) private var washScroll
  @State private var scroll = DashHeaderScrollState()

  var body: some View {
    content()
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .padding(.top, DashPageChromeMetrics.reservedHeight)
      // Frost first, navigation chrome second: controls remain crisp above it.
      .overlayPreferenceValue(DashHeaderScrimHandledKey.self) { handled in
        if !handled {
          DashHeaderScrim(scroll: scroll)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
        }
      }
      .overlayPreferenceValue(DashPageChromePreferenceKey.self, alignment: .top) { chrome in
        if let entry {
          DashPageNavigationBar(
            entry: entry,
            chrome: chrome,
            dismiss: { navigator?.dismissTop() }
          )
        }
      }
      .backgroundPreferenceValue(DashHeaderScrimHandledKey.self) { handled in
        if !handled {
          DashHeaderScrollProbe(scroll: scroll, wash: washScroll)
          DashScreenClipLift()
        }
      }
      .preference(key: DashHeaderScrimHandledKey.self, value: true)
      .modifier(
        DashPageEscapeActionModifier(
          isEnabled: entry != nil,
          action: { navigator?.dismissTop() }))
  }
}

private struct DashPageActionsModifier: ViewModifier {
  let leading: [DashPageActionDescriptor]
  let trailing: [DashPageActionDescriptor]

  func body(content: Content) -> some View {
    content
      .preference(
        key: DashPageChromePreferenceKey.self,
        value: DashPageChromePreference(
          leadingActions: leading,
          trailingActions: trailing)
      )
      // Keep the same page-owned descriptor usable in isolated previews and
      // system-presented leaf contexts. Production routes consume the
      // preference above in Dash's custom chrome.
      .toolbar {
        if !leading.isEmpty {
          ToolbarItem(placement: .topBarLeading) {
            DashPageActionGroupView(actions: leading)
          }
          .dashSeparateToolbarBackground()
        }
        if !trailing.isEmpty {
          ToolbarItem(placement: .topBarTrailing) {
            DashPageActionGroupView(actions: trailing)
          }
          .dashSeparateToolbarBackground()
        }
      }
  }
}

extension View {
  /// Page-bar identity for a pushed detail screen: the feature glyph or avatar
  /// ahead of the title. Dash's custom chrome consumes the descriptor; the
  /// native modifiers underneath keep isolated previews usable.
  ///
  /// Tint resolution: explicit `tint` → feature hero → brand.
  func detailHeader(icon: DetailIcon, title: String, tint: Color? = nil) -> some View {
    modifier(DetailHeaderModifier(icon: icon, title: title, tint: tint))
  }

  /// Page-owned navigation actions. The descriptor form is intentionally
  /// finite: it can render in both the native bridge and Dash's custom chrome
  /// without moving arbitrary SwiftUI view identity across hosting trees.
  func dashPageActions(
    leading: [DashPageActionDescriptor] = [],
    trailing: [DashPageActionDescriptor] = []
  ) -> some View {
    modifier(DashPageActionsModifier(leading: leading, trailing: trailing))
  }
}

private struct DetailHeaderModifier: ViewModifier {
  /// Leaves a stable trailing region for the widest shared toolbar group
  /// (two 44pt actions plus their gap) on a compact portrait iPhone. The
  /// toolbar can still propose less space when a text action or large Dynamic
  /// Type needs it.
  private static let maximumPrincipalWidth: CGFloat = 160

  let icon: DetailIcon
  let title: String
  var tint: Color?
  @Environment(\.featureIdentity) private var featureIdentity

  private var resolvedTint: Color {
    if let tint { return tint }
    if let feature = featureIdentity {
      return FeatureVisualIdentity.heroColor(for: feature)
    }
    return DashTheme.brand
  }

  private var displayedTitle: String { DashL10n.ui(title) }

  func body(content: Content) -> some View {
    content
      .preference(
        key: DashPageChromePreferenceKey.self,
        value: DashPageChromePreference(
          header: DashPageHeaderDescriptor(
            icon: icon,
            title: displayedTitle,
            tint: resolvedTint))
      )
      .navigationTitle(displayedTitle)
      .toolbar {
        ToolbarItem(placement: .principal) {
          HStack(spacing: 6) {
            DetailIconView(icon: icon, tint: resolvedTint)
              .layoutPriority(1)
            Text(displayedTitle)
              .dashTextStyle(.sectionTitle)
              .foregroundStyle(DashTheme.strong)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          .frame(maxWidth: Self.maximumPrincipalWidth)
        }
        // Root principals are a clear 1×1 prop (no glass). A real title + icon
        // principal gets iOS 26's shared Liquid Glass plate — a gray capsule
        // over the canvas — unless the shared background is hidden.
        .dashSeparateToolbarBackground()
      }
  }
}

// MARK: - Link helpers

/// Opens a `Destination` on the enclosing tab's custom page stack.
struct DestinationLink<Label: View>: View {
  let destination: Destination
  var onNavigate: (() -> Void)?
  @ViewBuilder var label: () -> Label

  @Environment(\.destinationNavigator) private var navigator

  var body: some View {
    Button {
      onNavigate?()
      navigator?.push(destination)
    } label: {
      label()
    }
    // A navigation row is a surface, not a button — it must not shrink on press.
    .buttonStyle(DashSurfaceButtonStyle())
  }
}
