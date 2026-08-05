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
  /// Stable route identity used by source-to-page transitions. Keep this
  /// independent of localized copy and list position: one resource can appear
  /// in several places, while the occurrence UUID distinguishes the concrete
  /// source the user actually touched.
  var dashNavigationSemanticID: DashNavigationSemanticID {
    switch self {
    case .profile: .init(namespace: "settings", value: "profile")
    case .settings: .init(namespace: "workspace", value: "settings")
    case .settingsAccounts: .init(namespace: "settings", value: "accounts")
    case .about: .init(namespace: "settings", value: "about")
    case .openSource: .init(namespace: "settings", value: "open-source")
    #if DEBUG
      case .debug: .init(namespace: "settings", value: "debug")
    #endif
    case .feature(let feature): .init(namespace: "feature", value: feature.rawValue)
    case .zone(let id): .init(namespace: "zone", value: id)
    case .dns(let id): .init(namespace: "zone-dns", value: id)
    case .cache(let id): .init(namespace: "zone-cache", value: id)
    case .zoneAnalytics(let id): .init(namespace: "zone-analytics", value: id)
    case .zoneWebAnalytics(let id): .init(namespace: "zone-web-analytics", value: id)
    case .zoneWAF(let id): .init(namespace: "zone-waf", value: id)
    case .zoneSettings(let id): .init(namespace: "zone-settings", value: id)
    case .zoneEmailRouting(let id): .init(namespace: "zone-email-routing", value: id)
    case .auditLogs: .init(namespace: "account", value: "audit-logs")
    case .pushAlerts: .init(namespace: "account", value: "push-alerts")
    case .watchtowerInbox: .init(namespace: "watchtower", value: "inbox")
    case .cloudflareStatus: .init(namespace: "watchtower", value: "cloudflare-status")
    case .emailAddresses: .init(namespace: "email-routing", value: "addresses")
    case .registrarDomain(let domain): .init(namespace: "registration", value: domain)
    case .chartDetail(let detail): .init(namespace: "chart", value: detail.title)
    case .worker(let name): .init(namespace: "worker", value: name)
    case .tunnel(let id): .init(namespace: "tunnel", value: id)
    case .pagesProject(let name): .init(namespace: "pages-project", value: name)
    case .pagesDeployment(let project, let deploymentID):
      .init(namespace: "pages-deployment", value: "\(project)/\(deploymentID)")
    case .pagesDomains(let name): .init(namespace: "pages-domains", value: name)
    case .r2Bucket(let name, let prefix):
      .init(namespace: "r2", value: "\(name)/\(prefix)")
    case .r2BucketSettings(let name): .init(namespace: "r2-settings", value: name)
    case .kvNamespace(let id): .init(namespace: "kv-namespace", value: id)
    case .kvKey(let namespaceID, let key):
      .init(namespace: "kv-key", value: "\(namespaceID)/\(key)")
    }
  }

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

  /// Dismisses only the page instance that emitted the action. A delayed or
  /// repeated Back/Escape event must never consume the page underneath it.
  func dismiss(entryID: DashNavigationEntry.ID) {
    guard topEntry?.id == entryID else { return }
    dismissTop()
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
  @MainActor
  @Observable
  final class ClaimState {
    private var claimedInstanceIDs: Set<UUID> = []

    func claim(_ instanceID: UUID) {
      claimedInstanceIDs.insert(instanceID)
    }

    func release(_ instanceID: UUID) {
      claimedInstanceIDs.remove(instanceID)
    }

    func isClaimed(_ instanceID: UUID) -> Bool {
      claimedInstanceIDs.contains(instanceID)
    }
  }

  private final class WeakSourceView {
    weak var value: UIView?

    init(_ value: UIView) {
      self.value = value
    }
  }

  struct CapturedVisual {
    let view: UIView
    /// Window-coordinate frame at the instant the action was invoked.
    let frame: CGRect
  }

  private var preferenceFrames: [UUID: CGRect] = [:]
  private var hostedFrames: [UUID: CGRect] = [:]
  private var sourceViews: [UUID: WeakSourceView] = [:]
  private var capturedVisuals: [UUID: CapturedVisual] = [:]
  let claimState = ClaimState()

  func replaceFrames(_ frames: [UUID: CGRect]) {
    preferenceFrames = frames
  }

  /// Preferences do not cross a `UIHostingController` boundary. Custom-stack
  /// pages therefore publish their source frames directly into this shared
  /// registry, while outer workspace chrome can keep using preferences.
  func setHostedFrame(_ frame: CGRect, for instanceID: UUID) {
    hostedFrames[instanceID] = frame
  }

  func removeHostedFrame(for instanceID: UUID) {
    hostedFrames[instanceID] = nil
  }

  func registerSourceView(_ view: UIView, for instanceID: UUID) {
    sourceViews[instanceID] = WeakSourceView(view)
  }

  func unregisterSourceView(_ view: UIView, for instanceID: UUID) {
    guard sourceViews[instanceID]?.value === view else { return }
    sourceViews[instanceID] = nil
  }

  func frame(for origin: DashNavigationOrigin) -> CGRect? {
    sourceWindowFrame(for: origin.anchorInstanceID)
      ?? hostedFrames[origin.anchorInstanceID]
      ?? preferenceFrames[origin.anchorInstanceID]
      ?? origin.sourceFrame
  }

  /// A return morph is valid only while the exact source occurrence still
  /// exists in a window. Captured geometry is useful for a push whose source
  /// is leaving, but it must never pull a page back into a stale list slot.
  func liveFrame(for origin: DashNavigationOrigin) -> CGRect? {
    sourceWindowFrame(for: origin.anchorInstanceID)
  }

  func claim(_ origin: DashNavigationOrigin?) {
    guard let origin else { return }
    claimState.claim(origin.anchorInstanceID)
  }

  func release(_ origin: DashNavigationOrigin?) {
    guard let origin else { return }
    claimState.release(origin.anchorInstanceID)
  }

  func captureOrigin(
    semanticID: DashNavigationSemanticID,
    anchorInstanceID: UUID
  ) -> DashNavigationOrigin {
    let frame =
      sourceWindowFrame(for: anchorInstanceID)
      ?? hostedFrames[anchorInstanceID]
      ?? preferenceFrames[anchorInstanceID]
    if let source = sourceViews[anchorInstanceID]?.value,
      let window = source.window,
      let frame,
      frame.width > 2,
      frame.height > 2,
      let snapshot = window.resizableSnapshotView(
        from: frame,
        afterScreenUpdates: false,
        withCapInsets: .zero)
    {
      capturedVisuals[anchorInstanceID] = CapturedVisual(view: snapshot, frame: frame)
    } else {
      capturedVisuals[anchorInstanceID] = nil
    }
    return DashNavigationOrigin(
      semanticID: semanticID,
      anchorInstanceID: anchorInstanceID,
      sourceFrame: frame)
  }

  func takeCapturedVisual(for origin: DashNavigationOrigin?) -> CapturedVisual? {
    guard let origin else { return nil }
    return capturedVisuals.removeValue(forKey: origin.anchorInstanceID)
  }

  func discardCapturedVisual(for origin: DashNavigationOrigin?) {
    guard let origin else { return }
    capturedVisuals[origin.anchorInstanceID] = nil
  }

  private func sourceWindowFrame(for instanceID: UUID) -> CGRect? {
    guard let source = sourceViews[instanceID]?.value, let window = source.window else {
      return nil
    }
    let frame = source.convert(source.bounds, to: window)
    guard frame.width > 0, frame.height > 0 else { return nil }
    return frame
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

private struct DashCanPresentPendingHomeActionKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  var destinationNavigator: DestinationNavigator? {
    get { self[DestinationNavigatorKey.self] }
    set { self[DestinationNavigatorKey.self] = newValue }
  }

  /// True when this tab is selected, regardless of push depth. The tab flow
  /// retains inactive page stacks as detached controllers, so heavy roots use
  /// this to defer work until their tab is actually attached and shown.
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

  var dashCanPresentPendingHomeAction: Bool {
    get { self[DashCanPresentPendingHomeActionKey.self] }
    set { self[DashCanPresentPendingHomeActionKey.self] = newValue }
  }
}

extension View {
  /// Registers the frame for this exact source occurrence. A semantic resource
  /// ID alone is insufficient when the same resource is visible in two places.
  func dashNavigationAnchor(instanceID: UUID) -> some View {
    modifier(DashNavigationAnchorModifier(instanceID: instanceID))
  }
}

private struct DashNavigationAnchorModifier: ViewModifier {
  let instanceID: UUID
  @Environment(\.dashNavigationAnchorRegistry) private var registry

  func body(content: Content) -> some View {
    let isClaimed = registry?.claimState.isClaimed(instanceID) == true
    content
      // The compositor owns this exact occurrence while its proxy is active.
      // Keep the layout/probe alive, but never render or activate a duplicate.
      .opacity(isClaimed ? 0 : 1)
      .allowsHitTesting(!isClaimed)
      .accessibilityHidden(isClaimed)
      .animation(nil, value: isClaimed)
      .background {
        GeometryReader { proxy in
          let frame = proxy.frame(in: .global)
          Color.clear
            .preference(
              key: DashNavigationAnchorFramesKey.self,
              value: [instanceID: frame]
            )
            .onAppear { registry?.setHostedFrame(frame, for: instanceID) }
            .onChange(of: frame) { _, nextFrame in
              registry?.setHostedFrame(nextFrame, for: instanceID)
            }
            .onDisappear { registry?.removeHostedFrame(for: instanceID) }
            .overlay {
              DashNavigationAnchorProbe(
                instanceID: instanceID,
                registry: registry)
            }
        }
      }
  }
}

private struct DashNavigationAnchorProbe: UIViewRepresentable {
  let instanceID: UUID
  let registry: DashNavigationAnchorRegistry?

  func makeUIView(context: Context) -> DashNavigationAnchorProbeView {
    let view = DashNavigationAnchorProbeView()
    view.configure(instanceID: instanceID, registry: registry)
    return view
  }

  func updateUIView(_ uiView: DashNavigationAnchorProbeView, context: Context) {
    uiView.configure(instanceID: instanceID, registry: registry)
  }

  static func dismantleUIView(_ uiView: DashNavigationAnchorProbeView, coordinator: ()) {
    uiView.tearDown()
  }
}

private final class DashNavigationAnchorProbeView: UIView {
  private var instanceID: UUID?
  private weak var registry: DashNavigationAnchorRegistry?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(instanceID: UUID, registry: DashNavigationAnchorRegistry?) {
    if self.instanceID != instanceID || self.registry !== registry {
      tearDown()
      self.instanceID = instanceID
      self.registry = registry
    }
    registry?.registerSourceView(self, for: instanceID)
  }

  func tearDown() {
    if let instanceID {
      registry?.unregisterSourceView(self, for: instanceID)
    }
    instanceID = nil
    registry = nil
  }
}

// MARK: - Custom page stack

struct DashPagePresentationState: Equatable {
  let settledDepth: Int
  let isTransitioning: Bool

  func resolvedDepth(navigatorDepth: Int) -> Int {
    // The navigator leads on push; the compositor leads on pop. Taking both
    // prevents root chrome from returning before either owner reaches root.
    max(navigatorDepth, settledDepth)
  }

  func occupiesWorkspace(navigatorDepth: Int) -> Bool {
    resolvedDepth(navigatorDepth: navigatorDepth) > 0 || isTransitioning
  }
}

@MainActor
@Observable
private final class DashPageHostContext {
  var isTabActive: Bool
  var canPresentPendingHomeAction: Bool
  var splashLifted: Bool
  var interactionLockedEntryID: DashNavigationEntry.ID?
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
    self.interactionLockedEntryID = nil
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
    self.isTabActive = isTabActive
    self.canPresentPendingHomeAction = canPresentPendingHomeAction
    self.splashLifted = splashLifted
    self.workspaceWashScroll = workspaceWashScroll
    self.locale = locale
    self.dynamicTypeSize = dynamicTypeSize
  }
}

@MainActor
private final class DashRootContentBox<Content: View> {
  let content: Content

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
    .environment(\.dashSplashLifted, hostContext.splashLifted)
    .environment(
      \.dashCanPresentPendingHomeAction,
      hostContext.canPresentPendingHomeAction
    )
    .environment(
      \.dashWorkspaceWashScroll,
      hostContext.workspaceWashScroll
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
    DashRoutePageChromeHost(
      entry: entry,
      allowsBodyInteraction: hostContext.interactionLockedEntryID != entry.id
    ) {
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
    .environment(\.dashSplashLifted, hostContext.splashLifted)
    .environment(
      \.dashCanPresentPendingHomeAction,
      hostContext.canPresentPendingHomeAction
    )
    .environment(\.dashWorkspaceWashScroll, nil)
    .environment(\.locale, hostContext.locale)
    .environment(\.dynamicTypeSize, hostContext.dynamicTypeSize)
  }
}

private enum DashPageTransitionStyle {
  case flowPush
  case flowPop
  case entityPush(DashNavigationEntry)
  case entityPop(DashNavigationEntry)
  case workspacePresent(DashNavigationEntry)
  case workspaceDismiss(DashNavigationEntry)

  var isPush: Bool {
    switch self {
    case .flowPush, .entityPush, .workspacePresent: true
    case .flowPop, .entityPop, .workspaceDismiss: false
    }
  }

  var entry: DashNavigationEntry? {
    switch self {
    case .entityPush(let entry), .entityPop(let entry),
      .workspacePresent(let entry), .workspaceDismiss(let entry):
      entry
    case .flowPush, .flowPop:
      nil
    }
  }

  var duration: TimeInterval {
    switch self {
    case .flowPush: DashTheme.Motion.Page.flowEnterDuration
    case .flowPop: DashTheme.Motion.Page.flowExitDuration
    case .entityPush: DashTheme.Motion.Page.entityEnterDuration
    case .entityPop: DashTheme.Motion.Page.entityExitDuration
    case .workspacePresent: DashTheme.Motion.Page.workspaceEnterDuration
    case .workspaceDismiss: DashTheme.Motion.Page.workspaceExitDuration
    }
  }
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

  /// A neutral full-screen surface separates the outgoing and arriving page
  /// timelines. Raster content stays at its natural size and only crossfades;
  /// the concrete source snapshot is the one local element carried across.
  private final class TransitionProxy {
    let overlay: UIView
    let shell: UIView?
    let outgoingContent: UIView?
    let arrivingContent: UIView?
    /// Invisible property-animation payload that gives the display-link content
    /// timeline a reversible progress source without transforming any pixels.
    let timelineDriver: UIView?
    let claimedOrigin: DashNavigationOrigin?

    init(
      overlay: UIView,
      shell: UIView?,
      outgoingContent: UIView?,
      arrivingContent: UIView?,
      timelineDriver: UIView?,
      claimedOrigin: DashNavigationOrigin?
    ) {
      self.overlay = overlay
      self.shell = shell
      self.outgoingContent = outgoingContent
      self.arrivingContent = arrivingContent
      self.timelineDriver = timelineDriver
      self.claimedOrigin = claimedOrigin
    }
  }

  private final class ActiveTransition {
    let animator: UIViewPropertyAnimator
    let source: UIViewController
    let target: UIViewController
    let style: DashPageTransitionStyle
    let proxy: TransitionProxy?
    var desiredEntries: [DashNavigationEntry]
    var revision: UInt64
    let appearanceWasBegun: Bool
    var isReversed = false

    init(
      animator: UIViewPropertyAnimator,
      source: UIViewController,
      target: UIViewController,
      style: DashPageTransitionStyle,
      proxy: TransitionProxy?,
      desiredEntries: [DashNavigationEntry],
      revision: UInt64,
      appearanceWasBegun: Bool
    ) {
      self.animator = animator
      self.source = source
      self.target = target
      self.style = style
      self.proxy = proxy
      self.desiredEntries = desiredEntries
      self.revision = revision
      self.appearanceWasBegun = appearanceWasBegun
    }
  }

  private let contentBox: DashRootContentBox<Root>
  private let hostContext: DashPageHostContext
  private let model: AppModel
  private let navigator: DestinationNavigator
  private let navigationCoordinator: DashNavigationCoordinator?
  private let anchorRegistry: DashNavigationAnchorRegistry?
  private let presentationState: DashWorkspacePresentationState?
  private let rootController: UIHostingController<DashHostedRoot<Root>>
  private let destinationCanvasPlate = UIView()
  private var onPresentationStateChange: (DashPagePresentationState) -> Void

  private var entryHosts: [DashNavigationEntry.ID: EntryHost] = [:]
  private var settledEntries: [DashNavigationEntry] = []
  private var settledRevision: UInt64 = 0
  private var visibleController: UIViewController?
  private var activeTransition: ActiveTransition?
  private var transitionContentDisplayLink: CADisplayLink?
  private var pendingRequest: DashPageStackRequest?
  private var accountID: String?
  private var isContainerVisible = false
  private var parentAppearanceIsDisappearing = false
  /// The exact child whose parent-driven appearance transition was begun.
  /// Route updates are deferred until this is ended so begin/end can never
  /// land on different cached pages.
  private var parentAppearanceTransitionChild: UIViewController?
  private var pendingPresentationReport: DashPagePresentationState?
  private var lastDeliveredPresentationState: DashPagePresentationState?

  override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }

  init(
    root: Root,
    model: AppModel,
    navigator: DestinationNavigator,
    navigationCoordinator: DashNavigationCoordinator?,
    anchorRegistry: DashNavigationAnchorRegistry?,
    presentationState: DashWorkspacePresentationState?,
    isTabActive: Bool,
    canPresentPendingHomeAction: Bool,
    splashLifted: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll?,
    locale: Locale,
    dynamicTypeSize: DynamicTypeSize,
    accountID: String?,
    onPresentationStateChange: @escaping (DashPagePresentationState) -> Void
  ) {
    let contentBox = DashRootContentBox(content: root)
    let hostContext = DashPageHostContext(
      isTabActive: isTabActive,
      canPresentPendingHomeAction: canPresentPendingHomeAction,
      splashLifted: splashLifted,
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
    self.onPresentationStateChange = onPresentationStateChange
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
    destinationCanvasPlate.frame = view.bounds
    destinationCanvasPlate.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    destinationCanvasPlate.backgroundColor = UIColor(DashTheme.canvas)
    destinationCanvasPlate.isOpaque = true
    destinationCanvasPlate.isUserInteractionEnabled = false
    destinationCanvasPlate.isAccessibilityElement = false
    destinationCanvasPlate.accessibilityElementsHidden = true
    destinationCanvasPlate.alpha = 0
    destinationCanvasPlate.isHidden = true
    view.addSubview(destinationCanvasPlate)
    rootController.view.backgroundColor = .clear
    attach(rootController, above: nil)
    visibleController = rootController
    reportPresentationState()
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
    isTabActive: Bool,
    canPresentPendingHomeAction: Bool,
    splashLifted: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll?,
    locale: Locale,
    dynamicTypeSize: DynamicTypeSize,
    onPresentationStateChange: @escaping (DashPagePresentationState) -> Void,
    request: DashPageStackRequest
  ) {
    self.onPresentationStateChange = onPresentationStateChange
    hostContext.update(
      isTabActive: isTabActive,
      canPresentPendingHomeAction: canPresentPendingHomeAction,
      splashLifted: splashLifted,
      workspaceWashScroll: workspaceWashScroll,
      locale: locale,
      dynamicTypeSize: dynamicTypeSize)
    loadViewIfNeeded()
    // SwiftUI's outer accessibility modifiers do not reliably penetrate a
    // UIViewControllerRepresentable that keeps multiple child controllers
    // cached. Enforce tab ownership at the UIKit boundary so an invisible
    // sibling can never pollute VoiceOver/XCUI visible-point resolution.
    view.isUserInteractionEnabled = isTabActive
    view.accessibilityElementsHidden = !isTabActive
    reconcile(request)
  }

  private func reportPresentationState() {
    let state = DashPagePresentationState(
      settledDepth: settledEntries.count,
      isTransitioning: activeTransition != nil)
    if lastDeliveredPresentationState == state {
      // Also cancel a queued intermediate report if the compositor returned to
      // the state SwiftUI already owns before that report could be delivered.
      pendingPresentationReport = nil
      return
    }
    guard pendingPresentationReport != state else { return }
    pendingPresentationReport = state
    // Reconciliation runs from updateUIViewController. Publish on the next
    // MainActor turn so SwiftUI never receives a state mutation mid-update.
    Task { @MainActor [weak self] in
      guard let self, self.pendingPresentationReport == state else { return }
      self.pendingPresentationReport = nil
      self.lastDeliveredPresentationState = state
      self.onPresentationStateChange(state)
    }
  }

  private func reconcile(_ request: DashPageStackRequest) {
    let newestKnownRevision = max(
      settledRevision,
      max(activeTransition?.revision ?? 0, pendingRequest?.revision ?? 0))
    guard request.revision >= newestKnownRevision else { return }

    if parentAppearanceTransitionChild != nil {
      storePendingRequest(request)
      return
    }

    if request.accountID != accountID {
      accountID = request.accountID
      discardPendingRequest()
      finishActiveTransitionImmediately()
      installImmediately(request.entries, revision: request.revision)
      return
    }

    if reverseActiveTransitionIfPossible(for: request) {
      return
    }

    if activeTransition != nil {
      storePendingRequest(request)
      return
    }

    let desiredIDs = request.entries.map(\.id)
    let settledIDs = settledEntries.map(\.id)
    guard desiredIDs != settledIDs else {
      settledEntries = request.entries
      settledRevision = max(settledRevision, request.revision)
      reportPresentationState()
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
        reportPresentationState()
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
      reportPresentationState()
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
      guard let entry = request.entries.last else { return .flowPush }
      return switch entry.presentation {
      case .detail: .flowPush
      case .entityDetail: .entityPush(entry)
      case .workspaceOverlay: .workspacePresent(entry)
      }
    case .closeToWorkspaceRoot:
      guard let entry = settledEntries.last else { return .flowPop }
      return .workspaceDismiss(entry)
    case .back, .popToRoot, .resourcePruned:
      guard let entry = settledEntries.last else { return .flowPop }
      return switch entry.presentation {
      case .detail: .flowPop
      case .entityDetail: .entityPop(entry)
      case .workspaceOverlay: .workspaceDismiss(entry)
      }
    case .reset, .accountScopeChanged, nil:
      return .flowPush
    }
  }

  private func performTransition(
    from source: UIViewController,
    to target: UIViewController,
    style requestedStyle: DashPageTransitionStyle,
    request: DashPageStackRequest
  ) {
    let targetOwnsDestinationCanvas = !request.entries.isEmpty
    prepareDestinationCanvasTransition(targetVisible: targetOwnsDestinationCanvas)
    let isPush = requestedStyle.isPush
    hostContext.interactionLockedEntryID = isPush ? request.entries.last?.id : nil
    attach(target, above: isPush ? source : nil)
    if !isPush {
      view.insertSubview(target.view, belowSubview: source.view)
    }
    view.layoutIfNeeded()
    let style = resolvedTransitionStyle(requestedStyle)
    resetTransitionState(source.view)
    resetTransitionState(target.view)
    source.view.isUserInteractionEnabled = false
    // Keep the hosting view alive for Back/Close, while DashRoutePageChromeHost
    // gates the arriving page body until the transition settles. This makes a
    // deliberate immediate reversal possible without click-through routes.
    target.view.isUserInteractionEnabled = isPush
    if request.reduceMotion || style.entry == nil {
      anchorRegistry?.discardCapturedVisual(for: request.entries.last?.origin)
    }
    let proxy =
      request.reduceMotion
      ? nil
      : makeTransitionProxy(
        style: style,
        source: source.view,
        target: target.view)
    applyInitialTransitionState(
      style: style,
      source: source.view,
      target: target.view,
      hasProxy: proxy != nil,
      reduceMotion: request.reduceMotion)

    let appearanceWasBegun = isContainerVisible && !parentAppearanceIsDisappearing
    if appearanceWasBegun {
      source.beginAppearanceTransition(false, animated: true)
      target.beginAppearanceTransition(true, animated: true)
    }

    let duration =
      request.reduceMotion
      ? DashTheme.Motion.Page.reducedDuration
      : style.duration
    let animator = UIViewPropertyAnimator(
      duration: duration,
      dampingRatio: request.reduceMotion ? 1 : DashTheme.Motion.Page.dampingRatio)
    animator.addAnimations { [weak self, weak source, weak target] in
      guard let self, let source, let target else { return }
      self.destinationCanvasPlate.alpha = targetOwnsDestinationCanvas ? 1 : 0
      self.applyFinalTransitionState(
        style: style,
        source: source.view,
        target: target.view,
        proxy: proxy,
        reduceMotion: request.reduceMotion)
    }
    activeTransition = ActiveTransition(
      animator: animator,
      source: source,
      target: target,
      style: style,
      proxy: proxy,
      desiredEntries: request.entries,
      revision: request.revision,
      appearanceWasBegun: appearanceWasBegun)
    reportPresentationState()
    startTransitionContentTimelineIfNeeded()
    animator.addCompletion { [weak self, weak animator] position in
      guard let self, let animator,
        self.activeTransition?.animator === animator
      else { return }
      self.completeActiveTransition(at: position)
    }
    animator.startAnimation()
  }

  private func applyInitialTransitionState(
    style: DashPageTransitionStyle,
    source: UIView,
    target: UIView,
    hasProxy: Bool,
    reduceMotion: Bool
  ) {
    let travel = min(max(view.bounds.width * 0.08, 22), 34)
    let direction: CGFloat =
      view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
    switch style {
    case .flowPush:
      target.alpha = 0
      if !reduceMotion {
        target.transform = CGAffineTransform(translationX: travel * direction, y: 0)
      }
    case .flowPop:
      target.alpha = reduceMotion ? 0 : 0.96
      if !reduceMotion {
        target.transform = CGAffineTransform(
          translationX: -travel * 0.35 * direction,
          y: 0)
      }
    case .entityPush:
      target.alpha = 0
      if !reduceMotion, !hasProxy {
        target.transform = CGAffineTransform(translationX: travel * direction, y: 0)
      }
    case .entityPop:
      target.alpha = hasProxy ? 1 : (reduceMotion ? 0 : 0.94)
      if !reduceMotion, !hasProxy {
        target.transform = CGAffineTransform(
          translationX: -travel * 0.35 * direction,
          y: 0)
      }
      if hasProxy { source.alpha = 0 }
    case .workspacePresent:
      target.alpha = 0
      if !reduceMotion { target.transform = CGAffineTransform(scaleX: 0.985, y: 0.985) }
    case .workspaceDismiss:
      target.alpha = reduceMotion ? 0 : 0.96
    }
    if source.alpha != 0 { source.alpha = 1 }
  }

  private func applyFinalTransitionState(
    style: DashPageTransitionStyle,
    source: UIView,
    target: UIView,
    proxy: TransitionProxy?,
    reduceMotion: Bool
  ) {
    let direction: CGFloat =
      view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
    switch style {
    case .flowPush:
      target.alpha = 1
      target.transform = .identity
      if !reduceMotion {
        source.transform = CGAffineTransform(translationX: -8 * direction, y: 0)
      }
    case .flowPop:
      target.alpha = 1
      target.transform = .identity
      source.alpha = 0
      if !reduceMotion {
        source.transform = CGAffineTransform(translationX: 28 * direction, y: 0)
      }
    case .entityPush:
      if proxy == nil {
        target.alpha = 1
        target.transform = .identity
      } else {
        // The full-size proxy is the sole owner of arriving content until the
        // completion handoff. Fading the live target here double-exposes every
        // title, card, and row underneath the expanding snapshot.
        target.alpha = 0
      }
      if !reduceMotion, proxy == nil {
        source.alpha = 0.9
        source.transform = CGAffineTransform(scaleX: 0.985, y: 0.985)
      }
      proxy?.timelineDriver?.alpha = 1
    case .entityPop:
      target.alpha = 1
      target.transform = .identity
      source.alpha = 0
      proxy?.timelineDriver?.alpha = 1
    case .workspacePresent:
      target.alpha = 1
      target.transform = .identity
      proxy?.outgoingContent?.alpha = 0
      proxy?.arrivingContent?.alpha = 1
    case .workspaceDismiss:
      target.alpha = 1
      target.transform = .identity
      source.alpha = 0
      if !reduceMotion { source.transform = CGAffineTransform(scaleX: 0.985, y: 0.985) }
      proxy?.outgoingContent?.alpha = 0
      proxy?.arrivingContent?.alpha = 1
    }
  }

  /// A push immediately followed by its own Back/Close is the one retarget that
  /// must feel direct. `UIViewPropertyAnimator` reverses from its presentation
  /// value, so there is no jump back to either endpoint before the page returns.
  private func reverseActiveTransitionIfPossible(
    for request: DashPageStackRequest
  ) -> Bool {
    guard let transition = activeTransition, transition.style.isPush,
      request.entries.map(\.id) == settledEntries.map(\.id)
    else { return false }
    switch request.mutation?.reason {
    case .back, .closeToWorkspaceRoot, .popToRoot:
      break
    default:
      return false
    }
    guard transition.animator.state == .active, !transition.isReversed else {
      return false
    }

    discardPendingRequest()
    transition.desiredEntries = request.entries
    transition.revision = request.revision
    transition.isReversed = true
    transition.target.view.isUserInteractionEnabled = false
    transition.source.view.isUserInteractionEnabled = false

    if transition.appearanceWasBegun {
      // UIKit treats an opposite begin as cancellation of the in-flight
      // appearance. One final end per child then settles source as appeared
      // and target as disappeared, without a false didDisappear/didAppear pair.
      transition.source.beginAppearanceTransition(true, animated: true)
      transition.target.beginAppearanceTransition(false, animated: true)
    }
    transition.animator.isReversed = true
    return true
  }

  private func makeTransitionProxy(
    style: DashPageTransitionStyle,
    source: UIView,
    target: UIView
  ) -> TransitionProxy? {
    let requiresLiveFrame: Bool
    if case .entityPop = style {
      requiresLiveFrame = true
    } else {
      requiresLiveFrame = false
    }
    guard let entry = style.entry,
      let sourceFrame = transitionFrame(for: entry.origin, liveOnly: requiresLiveFrame)
    else { return nil }

    let overlay = UIView(frame: view.bounds)
    overlay.backgroundColor = .clear
    overlay.isOpaque = false
    overlay.isUserInteractionEnabled = false
    overlay.isAccessibilityElement = false
    overlay.accessibilityElementsHidden = true
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]

    var shell: UIView?
    var outgoingContent: UIView?
    var arrivingContent: UIView?
    var timelineDriver: UIView?
    var claimedOrigin: DashNavigationOrigin?

    switch style {
    case .entityPush:
      let capturedFrame: CGRect
      if let captured = anchorRegistry?.takeCapturedVisual(for: entry.origin) {
        capturedFrame = frameInContainer(fromWindowFrame: captured.frame) ?? sourceFrame
        outgoingContent = captured.view
      } else {
        capturedFrame = sourceFrame
        outgoingContent = snapshotFromWindow(at: sourceFrame)
      }
      if let outgoingContent {
        outgoingContent.frame = capturedFrame
      }
      shell = makeFullScreenTransitionShell(alpha: 0)
      arrivingContent = target.snapshotView(afterScreenUpdates: true)
      arrivingContent?.frame = view.bounds
      arrivingContent?.alpha = 0
      timelineDriver = makeTransitionTimelineDriver()
    case .entityPop:
      shell = makeFullScreenTransitionShell(alpha: 1)
      outgoingContent = source.snapshotView(afterScreenUpdates: false)
      outgoingContent?.frame = view.bounds
      arrivingContent = rasterSnapshotRegion(
        from: target,
        at: sourceFrame,
        afterScreenUpdates: true)
      arrivingContent?.alpha = 0
      timelineDriver = makeTransitionTimelineDriver()
    case .workspacePresent:
      if let captured = anchorRegistry?.takeCapturedVisual(for: entry.origin) {
        outgoingContent = captured.view
        outgoingContent?.frame =
          frameInContainer(fromWindowFrame: captured.frame) ?? sourceFrame
      } else {
        outgoingContent = snapshotFromWindow(at: sourceFrame)
        outgoingContent?.frame = sourceFrame
      }
      arrivingContent = snapshotRegion(
        from: target,
        at: sourceFrame,
        afterScreenUpdates: true)
      arrivingContent?.alpha = 0
      shell = makeIdentityTransitionShell(frame: sourceFrame)
      claimedOrigin = entry.origin
    case .workspaceDismiss:
      outgoingContent = snapshotRegion(
        from: source,
        at: sourceFrame,
        afterScreenUpdates: false)
      arrivingContent = snapshotRegion(
        from: target,
        at: sourceFrame,
        afterScreenUpdates: true)
      arrivingContent?.alpha = 0
      shell = makeIdentityTransitionShell(frame: sourceFrame)
      claimedOrigin = entry.origin
    case .flowPush, .flowPop:
      return nil
    }

    guard shell != nil || outgoingContent != nil || arrivingContent != nil else {
      return nil
    }
    if let shell { overlay.addSubview(shell) }
    if let outgoingContent {
      configureTransitionSnapshot(outgoingContent)
      overlay.addSubview(outgoingContent)
    }
    if let arrivingContent {
      configureTransitionSnapshot(arrivingContent)
      overlay.addSubview(arrivingContent)
    }
    if let timelineDriver { overlay.addSubview(timelineDriver) }
    view.addSubview(overlay)
    anchorRegistry?.claim(claimedOrigin)
    return TransitionProxy(
      overlay: overlay,
      shell: shell,
      outgoingContent: outgoingContent,
      arrivingContent: arrivingContent,
      timelineDriver: timelineDriver,
      claimedOrigin: claimedOrigin)
  }

  private func resolvedTransitionStyle(
    _ style: DashPageTransitionStyle
  ) -> DashPageTransitionStyle {
    guard case .entityPop(let entry) = style,
      transitionFrame(for: entry.origin, liveOnly: true) == nil
    else { return style }
    return .flowPop
  }

  private func transitionFrame(
    for origin: DashNavigationOrigin?,
    liveOnly: Bool = false
  ) -> CGRect? {
    guard let origin,
      let globalFrame = liveOnly
        ? anchorRegistry?.liveFrame(for: origin)
        : anchorRegistry?.frame(for: origin),
      globalFrame.width.isFinite, globalFrame.height.isFinite,
      globalFrame.minX.isFinite, globalFrame.minY.isFinite
    else { return nil }
    let localFrame = view.convert(globalFrame, from: nil)
    guard localFrame.width > 2, localFrame.height > 2,
      localFrame.intersects(view.bounds.insetBy(dx: -2, dy: -2))
    else { return nil }
    return localFrame
  }

  private func makeFullScreenTransitionShell(alpha: CGFloat) -> UIView {
    let shell = UIView(frame: view.bounds)
    shell.backgroundColor = UIColor(DashTheme.canvas).resolvedColor(with: traitCollection)
    shell.isOpaque = true
    shell.isUserInteractionEnabled = false
    shell.alpha = alpha
    return shell
  }

  private func makeTransitionTimelineDriver() -> UIView {
    let driver = UIView(frame: .zero)
    driver.alpha = 0
    driver.isUserInteractionEnabled = false
    return driver
  }

  private func makeIdentityTransitionShell(frame: CGRect) -> UIView {
    let shell = UIView(frame: frame)
    shell.backgroundColor = UIColor(DashTheme.canvas).resolvedColor(with: traitCollection)
    shell.isOpaque = true
    shell.isUserInteractionEnabled = false
    shell.clipsToBounds = true
    shell.layer.cornerCurve = .continuous
    shell.layer.cornerRadius = min(frame.width, frame.height) / 2
    return shell
  }

  private func configureTransitionSnapshot(_ snapshot: UIView) {
    snapshot.isAccessibilityElement = false
    snapshot.accessibilityElementsHidden = true
    snapshot.isUserInteractionEnabled = false
    snapshot.clipsToBounds = true
    snapshot.layer.cornerCurve = .continuous
  }

  private func frameInContainer(fromWindowFrame frame: CGRect) -> CGRect? {
    guard let window = view.window else { return nil }
    return view.convert(frame, from: window)
  }

  private func snapshotFromWindow(at localFrame: CGRect) -> UIView? {
    guard let window = view.window else { return nil }
    let windowFrame = window.convert(localFrame, from: view)
    return window.resizableSnapshotView(
      from: windowFrame,
      afterScreenUpdates: false,
      withCapInsets: .zero)
  }

  private func snapshotRegion(
    from source: UIView,
    at containerFrame: CGRect,
    afterScreenUpdates: Bool
  ) -> UIView? {
    let sourceRect = source.convert(containerFrame, from: view)
      .intersection(source.bounds)
    guard !sourceRect.isNull, sourceRect.width > 2, sourceRect.height > 2 else {
      return nil
    }
    let snapshot = source.resizableSnapshotView(
      from: sourceRect,
      afterScreenUpdates: afterScreenUpdates,
      withCapInsets: .zero)
    snapshot?.frame = view.convert(sourceRect, from: source)
    return snapshot
  }

  /// A freshly reattached SwiftUI hierarchy may not have committed every text
  /// layer to the render server yet. `resizableSnapshotView` can therefore
  /// return the row background and image while omitting its labels. Drawing the
  /// already-laid-out target hierarchy into one immutable raster keeps the
  /// source row atomic during the return handoff.
  private func rasterSnapshotRegion(
    from source: UIView,
    at containerFrame: CGRect,
    afterScreenUpdates: Bool
  ) -> UIView? {
    let sourceRect = source.convert(containerFrame, from: view)
      .intersection(source.bounds)
    guard !sourceRect.isNull, sourceRect.width > 2, sourceRect.height > 2 else {
      return nil
    }

    let format = UIGraphicsImageRendererFormat()
    format.scale = view.window?.screen.scale ?? traitCollection.displayScale
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: sourceRect.size, format: format)
    let image = renderer.image { context in
      context.cgContext.translateBy(x: -sourceRect.minX, y: -sourceRect.minY)
      if !source.drawHierarchy(
        in: source.bounds,
        afterScreenUpdates: afterScreenUpdates)
      {
        source.layer.render(in: context.cgContext)
      }
    }
    let snapshot = UIImageView(image: image)
    snapshot.contentMode = .scaleToFill
    snapshot.frame = view.convert(sourceRect, from: source)
    return snapshot
  }

  private func completeReversedTransition(_ transition: ActiveTransition) {
    hostContext.interactionLockedEntryID = nil
    resetTransitionState(transition.source.view)
    transition.source.view.isUserInteractionEnabled = true
    transition.target.view.isUserInteractionEnabled = true
    if transition.appearanceWasBegun {
      transition.source.endAppearanceTransition()
      transition.target.endAppearanceTransition()
    }
    // Keep the losing page at its animated endpoint until it is out of the
    // hierarchy. Restoring alpha first can briefly put two complete pages
    // behind a nearly transparent proxy at the completion boundary.
    detach(transition.target)
    resetTransitionState(transition.target.view)
    releaseAndRemove(transition.proxy)
    visibleController = transition.source
    settledEntries = transition.desiredEntries
    settledRevision = transition.revision
    activeTransition = nil
    purgeEntryHosts(retaining: Set(settledEntries.map(\.id)))
    setDestinationCanvasVisible(!settledEntries.isEmpty)
    reportPresentationState()
    if isContainerVisible, hostContext.isTabActive {
      UIAccessibility.post(notification: .screenChanged, argument: transition.source.view)
    }
    if let pendingRequest = takePendingRequest() {
      reconcile(pendingRequest)
    }
  }

  private func completeActiveTransition(at position: UIViewAnimatingPosition) {
    guard let transition = activeTransition else { return }
    stopTransitionContentTimeline(
      settlingAt: transition.isReversed || position == .start ? 0 : 1)
    if transition.isReversed || position == .start {
      completeReversedTransition(transition)
      return
    }
    hostContext.interactionLockedEntryID = nil
    resetTransitionState(transition.target.view)
    transition.source.view.isUserInteractionEnabled = true
    transition.target.view.isUserInteractionEnabled = true
    if transition.appearanceWasBegun {
      transition.source.endAppearanceTransition()
      transition.target.endAppearanceTransition()
    }
    detach(transition.source)
    resetTransitionState(transition.source.view)
    releaseAndRemove(transition.proxy)
    visibleController = transition.target
    settledEntries = transition.desiredEntries
    settledRevision = transition.revision
    activeTransition = nil
    purgeEntryHosts(retaining: Set(settledEntries.map(\.id)))
    setDestinationCanvasVisible(!settledEntries.isEmpty)
    reportPresentationState()
    let pendingChangesVisiblePage =
      pendingRequest.map {
        $0.entries.last?.id != transition.desiredEntries.last?.id
      } ?? false
    if isContainerVisible, hostContext.isTabActive, !pendingChangesVisiblePage {
      UIAccessibility.post(notification: .screenChanged, argument: transition.target.view)
    }
    if let pendingRequest = takePendingRequest() {
      reconcile(pendingRequest)
    }
  }

  private func finishActiveTransitionImmediately() {
    guard let transition = activeTransition else { return }
    stopTransitionContentTimeline(settlingAt: transition.isReversed ? 0 : 1)
    hostContext.interactionLockedEntryID = nil
    transition.animator.stopAnimation(true)
    let winner = transition.isReversed ? transition.source : transition.target
    let loser = transition.isReversed ? transition.target : transition.source
    resetTransitionState(winner.view)
    transition.source.view.isUserInteractionEnabled = true
    transition.target.view.isUserInteractionEnabled = true
    if transition.appearanceWasBegun {
      transition.source.endAppearanceTransition()
      transition.target.endAppearanceTransition()
    }
    detach(loser)
    resetTransitionState(loser.view)
    visibleController = winner
    releaseAndRemove(transition.proxy)
    settledEntries = transition.desiredEntries
    settledRevision = transition.revision
    activeTransition = nil
    purgeEntryHosts(retaining: Set(settledEntries.map(\.id)))
    setDestinationCanvasVisible(!settledEntries.isEmpty)
    reportPresentationState()
  }

  private func finishParentChildAppearanceTransition() {
    parentAppearanceTransitionChild?.endAppearanceTransition()
    parentAppearanceTransitionChild = nil
  }

  private func reconcilePendingRequestIfNeeded() {
    guard let pendingRequest = takePendingRequest() else { return }
    reconcile(pendingRequest)
  }

  private func installImmediately(_ entries: [DashNavigationEntry], revision: UInt64) {
    hostContext.interactionLockedEntryID = nil
    anchorRegistry?.discardCapturedVisual(for: entries.last?.origin)
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
    setDestinationCanvasVisible(!entries.isEmpty)
    reportPresentationState()
  }

  private func setDestinationCanvasVisible(_ visible: Bool) {
    destinationCanvasPlate.layer.removeAllAnimations()
    destinationCanvasPlate.alpha = visible ? 1 : 0
    destinationCanvasPlate.isHidden = !visible
  }

  private func prepareDestinationCanvasTransition(targetVisible: Bool) {
    let sourceVisible = !settledEntries.isEmpty
    destinationCanvasPlate.layer.removeAllAnimations()
    destinationCanvasPlate.isHidden = !(sourceVisible || targetVisible)
    destinationCanvasPlate.alpha = sourceVisible ? 1 : 0
  }

  /// A deferred route may be replaced before its transition starts. Its source
  /// snapshot is registry-owned, so dropping the request must drop that visual
  /// too. The same concrete anchor is exempt because a newer capture replaces
  /// the old value under the same key before this method runs.
  private func storePendingRequest(_ request: DashPageStackRequest) {
    let previousOrigin = pendingRequest?.entries.last?.origin
    let nextOrigin = request.entries.last?.origin
    if previousOrigin?.anchorInstanceID != nextOrigin?.anchorInstanceID {
      anchorRegistry?.discardCapturedVisual(for: previousOrigin)
    }
    pendingRequest = request
  }

  private func discardPendingRequest() {
    anchorRegistry?.discardCapturedVisual(for: pendingRequest?.entries.last?.origin)
    pendingRequest = nil
  }

  /// Taking transfers snapshot ownership to `reconcile`; it must not discard
  /// the visual that the imminent transition is about to consume.
  private func takePendingRequest() -> DashPageStackRequest? {
    let request = pendingRequest
    pendingRequest = nil
    return request
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
    // A pushed page owns the whole physical container, including both safe-area
    // bands. UIKit's backing plate closes any gap before SwiftUI's ignored-safe-
    // area background has rendered its first frame.
    controller.view.backgroundColor = UIColor(DashTheme.canvas)
    controller.view.isOpaque = true
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
      presentationState?.removePresentationReporters(forEntryID: id)
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

  /// Entity pages fade through an opaque canvas instead of crossfading through
  /// one another. The source snapshot lingers locally while outgoing content
  /// clears, then the full-size destination arrives without masks or scaling.
  /// Reading the active animator's fraction keeps immediate Back reversible.
  private func startTransitionContentTimelineIfNeeded() {
    guard let transition = activeTransition, transition.proxy != nil else { return }
    switch transition.style {
    case .entityPush, .entityPop:
      break
    case .flowPush, .flowPop, .workspacePresent, .workspaceDismiss:
      return
    }
    stopTransitionContentTimeline()
    updateTransitionContentTimeline(transition, progress: 0)
    let displayLink = CADisplayLink(
      target: self,
      selector: #selector(displayLinkDidRefreshTransitionContent))
    displayLink.add(to: .main, forMode: .common)
    transitionContentDisplayLink = displayLink
  }

  @objc private func displayLinkDidRefreshTransitionContent() {
    guard let transition = activeTransition else {
      stopTransitionContentTimeline()
      return
    }
    updateTransitionContentTimeline(
      transition,
      progress: CGFloat(transition.animator.fractionComplete))
  }

  private func updateTransitionContentTimeline(
    _ transition: ActiveTransition,
    progress rawProgress: CGFloat
  ) {
    guard let proxy = transition.proxy else { return }
    let progress = min(max(rawProgress, 0), 1)
    UIView.performWithoutAnimation {
      switch transition.style {
      case .entityPush:
        proxy.shell?.alpha = transitionSegment(progress, from: 0, to: 0.3)
        proxy.outgoingContent?.alpha =
          1 - transitionSegment(progress, from: 0.08, to: 0.36)
        proxy.arrivingContent?.alpha =
          transitionSegment(progress, from: 0.3, to: 0.82)
      case .entityPop:
        proxy.outgoingContent?.alpha =
          1 - transitionSegment(progress, from: 0, to: 0.34)
        proxy.arrivingContent?.alpha =
          transitionSegment(progress, from: 0.38, to: 0.68)
        proxy.shell?.alpha =
          1 - transitionSegment(progress, from: 0.38, to: 0.76)
      case .flowPush, .flowPop, .workspacePresent, .workspaceDismiss:
        break
      }
    }
  }

  private func transitionSegment(
    _ progress: CGFloat,
    from start: CGFloat,
    to end: CGFloat
  ) -> CGFloat {
    guard end > start else { return progress >= end ? 1 : 0 }
    let unit = min(max((progress - start) / (end - start), 0), 1)
    return unit * unit * (3 - 2 * unit)
  }

  private func stopTransitionContentTimeline(settlingAt progress: CGFloat? = nil) {
    if let progress, let transition = activeTransition {
      updateTransitionContentTimeline(transition, progress: progress)
    }
    transitionContentDisplayLink?.invalidate()
    transitionContentDisplayLink = nil
  }

  private func releaseAndRemove(_ proxy: TransitionProxy?) {
    guard let proxy else { return }
    anchorRegistry?.release(proxy.claimedOrigin)
    proxy.overlay.removeFromSuperview()
  }
}

private struct DashTabPageUpdate {
  let isTabActive: Bool
  let canPresentPendingHomeAction: Bool
  let splashLifted: Bool
  let workspaceWashScroll: DashWorkspaceWashScroll
  let locale: Locale
  let dynamicTypeSize: DynamicTypeSize
  let onPresentationStateChange: (DashPagePresentationState) -> Void
  let request: DashPageStackRequest
}

@MainActor
private final class DashTabPageSlot {
  let controller: UIViewController
  private let updatePage: (DashTabPageUpdate) -> Void

  init(
    controller: UIViewController,
    updatePage: @escaping (DashTabPageUpdate) -> Void
  ) {
    self.controller = controller
    self.updatePage = updatePage
  }

  func update(_ update: DashTabPageUpdate) {
    updatePage(update)
  }
}

private struct DashTabFlowRequest {
  let selection: AppTab
  let outgoingSelection: AppTab?
  let direction: DashTabTransitionDirection
  let generation: UInt64
  let reduceMotion: Bool
  let rightToLeft: Bool
  let onTransitionCompleted: (AppTab, AppTab, UInt64) -> Void
}

enum DashTabFlowReconciliationDisposition: Equatable {
  case animate
  case deferUntilVisible
  case settleOffscreen
}

enum DashTabFlowContainerRules {
  static func reconciliationDisposition(
    isContainerVisible: Bool,
    parentAppearanceTransitionActive: Bool
  ) -> DashTabFlowReconciliationDisposition {
    if isContainerVisible { return .animate }
    return parentAppearanceTransitionActive ? .deferUntilVisible : .settleOffscreen
  }
}

/// Owns the three persistent page stacks as real UIKit children. At rest only
/// the selected page participates in containment; a Family-style tab handoff
/// temporarily attaches the source and target, then detaches the source without
/// releasing it. This keeps each tab's state while giving UIKit and AX one
/// unambiguous visible-controller tree.
@MainActor
final class DashTabFlowViewController: UIViewController {
  private final class ActiveTransition {
    let animator: UIViewPropertyAnimator
    let sourceTab: AppTab
    let targetTab: AppTab
    let generation: UInt64
    let source: UIViewController
    let target: UIViewController
    let appearanceWasBegun: Bool
    let onCompleted: (AppTab, AppTab, UInt64) -> Void
    var notifiesCompletion = true

    init(
      animator: UIViewPropertyAnimator,
      sourceTab: AppTab,
      targetTab: AppTab,
      generation: UInt64,
      source: UIViewController,
      target: UIViewController,
      appearanceWasBegun: Bool,
      onCompleted: @escaping (AppTab, AppTab, UInt64) -> Void
    ) {
      self.animator = animator
      self.sourceTab = sourceTab
      self.targetTab = targetTab
      self.generation = generation
      self.source = source
      self.target = target
      self.appearanceWasBegun = appearanceWasBegun
      self.onCompleted = onCompleted
    }
  }

  private let pages: [AppTab: DashTabPageSlot]
  private var currentTab: AppTab
  private var activeTransition: ActiveTransition?
  private var isContainerVisible = false
  private var parentAppearanceChild: UIViewController?
  private var pendingRequest: DashTabFlowRequest?

  override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }

  fileprivate init(pages: [AppTab: DashTabPageSlot], selection: AppTab) {
    self.pages = pages
    self.currentTab = selection
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
    view.isAccessibilityElement = false
    let selected = page(for: currentTab).controller
    attach(selected, above: nil)
    exposeOnly(selected)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    for child in children {
      child.view.frame = view.bounds
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    finishParentAppearanceTransition()
    let selected = page(for: currentTab).controller
    selected.beginAppearanceTransition(true, animated: animated)
    parentAppearanceChild = selected
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    finishParentAppearanceTransition()
    isContainerVisible = true
    reconcilePendingRequestIfNeeded()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    finishParentAppearanceTransition()
    isContainerVisible = false
    finishActiveTransition(notify: false)
    let selected = page(for: currentTab).controller
    selected.beginAppearanceTransition(false, animated: animated)
    parentAppearanceChild = selected
  }

  override func viewDidDisappear(_ animated: Bool) {
    finishParentAppearanceTransition()
    super.viewDidDisappear(animated)
    settlePendingRequestOffscreenIfNeeded()
  }

  fileprivate func updatePage(_ tab: AppTab, with update: DashTabPageUpdate) {
    page(for: tab).update(update)
  }

  fileprivate func reconcile(_ request: DashTabFlowRequest) {
    loadViewIfNeeded()

    switch DashTabFlowContainerRules.reconciliationDisposition(
      isContainerVisible: isContainerVisible,
      parentAppearanceTransitionActive: parentAppearanceChild != nil)
    {
    case .animate:
      pendingRequest = nil
    case .deferUntilVisible:
      pendingRequest = request
      return
    case .settleOffscreen:
      pendingRequest = nil
      settleOffscreen(request)
      return
    }

    if let transition = activeTransition {
      let requestMatchesTransition =
        request.selection == transition.targetTab
        && request.outgoingSelection == transition.sourceTab
        && request.generation == transition.generation
      if requestMatchesTransition {
        enforceInteractionGate(for: transition)
        return
      }
      finishActiveTransition(notify: false)
    }

    guard
      let sourceTab = request.outgoingSelection,
      sourceTab != request.selection
    else {
      showOnly(request.selection)
      return
    }

    if currentTab != sourceTab {
      showOnly(sourceTab)
    }
    startTransition(
      from: sourceTab,
      to: request.selection,
      direction: request.direction,
      generation: request.generation,
      reduceMotion: request.reduceMotion,
      rightToLeft: request.rightToLeft,
      onCompleted: request.onTransitionCompleted)
  }

  private func page(for tab: AppTab) -> DashTabPageSlot {
    guard let page = pages[tab] else {
      preconditionFailure("Missing tab page for \(tab)")
    }
    return page
  }

  private func startTransition(
    from sourceTab: AppTab,
    to targetTab: AppTab,
    direction: DashTabTransitionDirection,
    generation: UInt64,
    reduceMotion: Bool,
    rightToLeft: Bool,
    onCompleted: @escaping (AppTab, AppTab, UInt64) -> Void
  ) {
    let source = page(for: sourceTab).controller
    let target = page(for: targetTab).controller
    guard source !== target else {
      showOnly(targetTab)
      return
    }

    attach(target, above: source)
    view.layoutIfNeeded()

    let travel = DashTabTransitionRules.signedTravel(
      for: direction,
      rightToLeft: rightToLeft,
      reduceMotion: reduceMotion)
    resetVisualState(source.view)
    target.view.layer.removeAllAnimations()
    target.view.alpha = 0
    target.view.transform = CGAffineTransform(translationX: travel, y: 0)
    source.view.isUserInteractionEnabled = false
    target.view.isUserInteractionEnabled = false
    source.view.accessibilityElementsHidden = true
    target.view.accessibilityElementsHidden = true
    view.accessibilityElementsHidden = true

    let appearanceWasBegun = isContainerVisible
    if appearanceWasBegun {
      source.beginAppearanceTransition(false, animated: true)
      target.beginAppearanceTransition(true, animated: true)
    }

    let duration =
      reduceMotion
      ? DashTheme.Motion.Page.reducedDuration
      : DashTheme.Motion.tabStepDuration
    let timing =
      reduceMotion
      ? UICubicTimingParameters(animationCurve: .easeOut)
      : UICubicTimingParameters(
        controlPoint1: DashTheme.Motion.tabStepControlPoint1,
        controlPoint2: DashTheme.Motion.tabStepControlPoint2)
    let animator = UIViewPropertyAnimator(duration: duration, timingParameters: timing)
    let transition = ActiveTransition(
      animator: animator,
      sourceTab: sourceTab,
      targetTab: targetTab,
      generation: generation,
      source: source,
      target: target,
      appearanceWasBegun: appearanceWasBegun,
      onCompleted: onCompleted)
    activeTransition = transition
    animator.addAnimations {
      source.view.alpha = 0
      source.view.transform = CGAffineTransform(translationX: -travel, y: 0)
      target.view.alpha = 1
      target.view.transform = .identity
    }
    animator.addCompletion { [weak self, weak transition] _ in
      guard let self, let transition else { return }
      self.complete(transition)
    }
    animator.startAnimation()
  }

  private func enforceInteractionGate(for transition: ActiveTransition) {
    transition.source.view.isUserInteractionEnabled = false
    transition.target.view.isUserInteractionEnabled = false
    transition.source.view.accessibilityElementsHidden = true
    transition.target.view.accessibilityElementsHidden = true
    view.accessibilityElementsHidden = true
  }

  private func complete(_ transition: ActiveTransition) {
    guard activeTransition === transition else { return }
    if transition.appearanceWasBegun {
      transition.source.endAppearanceTransition()
      transition.target.endAppearanceTransition()
    }
    resetVisualState(transition.source.view)
    resetVisualState(transition.target.view)
    detach(transition.source)
    currentTab = transition.targetTab
    exposeOnly(transition.target)
    activeTransition = nil

    if isContainerVisible {
      UIAccessibility.post(notification: .screenChanged, argument: transition.target.view)
    }
    guard transition.notifiesCompletion else { return }
    let callback = transition.onCompleted
    let sourceTab = transition.sourceTab
    let targetTab = transition.targetTab
    let generation = transition.generation
    // A property animator can be completed while SwiftUI is reconciling this
    // representable. Publish ownership on the next actor turn, never mid-update.
    Task { @MainActor in
      callback(sourceTab, targetTab, generation)
    }
  }

  private func finishActiveTransition(notify: Bool) {
    guard let transition = activeTransition else { return }
    transition.notifiesCompletion = notify
    transition.animator.stopAnimation(false)
    transition.animator.finishAnimation(at: .end)
  }

  private func settleOffscreen(_ request: DashTabFlowRequest) {
    finishActiveTransition(notify: false)
    showOnly(request.selection)
    guard
      let sourceTab = request.outgoingSelection,
      sourceTab != request.selection
    else { return }
    let callback = request.onTransitionCompleted
    let targetTab = request.selection
    let generation = request.generation
    Task { @MainActor in
      callback(sourceTab, targetTab, generation)
    }
  }

  private func reconcilePendingRequestIfNeeded() {
    guard let pendingRequest else { return }
    self.pendingRequest = nil
    reconcile(pendingRequest)
  }

  private func settlePendingRequestOffscreenIfNeeded() {
    guard let pendingRequest else { return }
    self.pendingRequest = nil
    settleOffscreen(pendingRequest)
  }

  private func showOnly(_ tab: AppTab) {
    let target = page(for: tab).controller
    let source = page(for: currentTab).controller
    guard target !== source else {
      exposeOnly(target)
      return
    }

    attach(target, above: source)
    let forwardsAppearance = isContainerVisible
    if forwardsAppearance {
      source.beginAppearanceTransition(false, animated: false)
      target.beginAppearanceTransition(true, animated: false)
    }
    if forwardsAppearance {
      source.endAppearanceTransition()
      target.endAppearanceTransition()
    }
    resetVisualState(source.view)
    resetVisualState(target.view)
    detach(source)
    currentTab = tab
    exposeOnly(target)
    if isContainerVisible {
      UIAccessibility.post(notification: .screenChanged, argument: target.view)
    }
  }

  private func exposeOnly(_ controller: UIViewController) {
    controller.view.isUserInteractionEnabled = true
    controller.view.accessibilityElementsHidden = false
    // Let UIKit derive descendants from the one attached child. Publishing a
    // plain UIView through an explicit accessibilityElements array leaves its
    // SwiftUI descendants enumerable but without a valid XCUI visible point.
    view.accessibilityElements = nil
    view.accessibilityElementsHidden = false
  }

  private func attach(_ child: UIViewController, above sibling: UIViewController?) {
    if child.parent === self {
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

  private func resetVisualState(_ view: UIView) {
    view.layer.removeAllAnimations()
    view.alpha = 1
    view.transform = .identity
  }

  private func finishParentAppearanceTransition() {
    parentAppearanceChild?.endAppearanceTransition()
    parentAppearanceChild = nil
  }
}

/// One representable for the entire workspace flow. Individual page stacks are
/// cached as detached UIKit controllers instead of separate SwiftUI siblings,
/// which preserves their state without exposing invisible AX containers.
struct DashTabFlowHost<HomeRoot: View, FeaturesRoot: View, WatchtowerRoot: View>:
  UIViewControllerRepresentable
{
  @Bindable var homeNavigator: DestinationNavigator
  @Bindable var featuresNavigator: DestinationNavigator
  @Bindable var watchtowerNavigator: DestinationNavigator
  let selection: AppTab
  let outgoingSelection: AppTab?
  let transitionDirection: DashTabTransitionDirection
  let transitionGeneration: UInt64
  let canPresentPendingHomeAction: Bool
  let homeWorkspaceWashScroll: DashWorkspaceWashScroll
  let featuresWorkspaceWashScroll: DashWorkspaceWashScroll
  let watchtowerWorkspaceWashScroll: DashWorkspaceWashScroll
  let onHomePresentationStateChange: (DashPagePresentationState) -> Void
  let onFeaturesPresentationStateChange: (DashPagePresentationState) -> Void
  let onWatchtowerPresentationStateChange: (DashPagePresentationState) -> Void
  let onTransitionCompleted: (AppTab, AppTab, UInt64) -> Void
  @ViewBuilder var home: () -> HomeRoot
  @ViewBuilder var features: () -> FeaturesRoot
  @ViewBuilder var watchtower: () -> WatchtowerRoot

  @Environment(AppModel.self) private var model
  @Environment(\.dashNavigationCoordinator) private var navigationCoordinator
  @Environment(\.dashNavigationAnchorRegistry) private var anchorRegistry
  @Environment(\.dashWorkspacePresentationState) private var presentationState
  @Environment(\.locale) private var locale
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.layoutDirection) private var layoutDirection
  @Environment(\.dashSplashLifted) private var splashLifted

  func makeUIViewController(context: Context) -> DashTabFlowViewController {
    navigationCoordinator?.register(homeNavigator)
    navigationCoordinator?.register(featuresNavigator)
    navigationCoordinator?.register(watchtowerNavigator)
    let pages = [
      AppTab.home: makePage(
        root: home(),
        navigator: homeNavigator,
        isTabActive: selection == .home,
        canPresentPendingHomeAction: canPresentPendingHomeAction,
        workspaceWashScroll: homeWorkspaceWashScroll,
        onPresentationStateChange: onHomePresentationStateChange),
      AppTab.features: makePage(
        root: features(),
        navigator: featuresNavigator,
        isTabActive: selection == .features,
        canPresentPendingHomeAction: true,
        workspaceWashScroll: featuresWorkspaceWashScroll,
        onPresentationStateChange: onFeaturesPresentationStateChange),
      AppTab.watchtower: makePage(
        root: watchtower(),
        navigator: watchtowerNavigator,
        isTabActive: selection == .watchtower,
        canPresentPendingHomeAction: true,
        workspaceWashScroll: watchtowerWorkspaceWashScroll,
        onPresentationStateChange: onWatchtowerPresentationStateChange),
    ]
    return DashTabFlowViewController(pages: pages, selection: selection)
  }

  func updateUIViewController(
    _ uiViewController: DashTabFlowViewController,
    context: Context
  ) {
    navigationCoordinator?.register(homeNavigator)
    navigationCoordinator?.register(featuresNavigator)
    navigationCoordinator?.register(watchtowerNavigator)
    let participatingTabs = Set([selection, outgoingSelection].compactMap { $0 })
    uiViewController.updatePage(
      .home,
      with: pageUpdate(
        navigator: homeNavigator,
        isTabActive: participatingTabs.contains(.home),
        canPresentPendingHomeAction: canPresentPendingHomeAction,
        workspaceWashScroll: homeWorkspaceWashScroll,
        onPresentationStateChange: onHomePresentationStateChange))
    uiViewController.updatePage(
      .features,
      with: pageUpdate(
        navigator: featuresNavigator,
        isTabActive: participatingTabs.contains(.features),
        canPresentPendingHomeAction: true,
        workspaceWashScroll: featuresWorkspaceWashScroll,
        onPresentationStateChange: onFeaturesPresentationStateChange))
    uiViewController.updatePage(
      .watchtower,
      with: pageUpdate(
        navigator: watchtowerNavigator,
        isTabActive: participatingTabs.contains(.watchtower),
        canPresentPendingHomeAction: true,
        workspaceWashScroll: watchtowerWorkspaceWashScroll,
        onPresentationStateChange: onWatchtowerPresentationStateChange))
    uiViewController.reconcile(
      DashTabFlowRequest(
        selection: selection,
        outgoingSelection: outgoingSelection,
        direction: transitionDirection,
        generation: transitionGeneration,
        reduceMotion: reduceMotion,
        rightToLeft: layoutDirection == .rightToLeft,
        onTransitionCompleted: onTransitionCompleted))
  }

  private func makePage<Root: View>(
    root: Root,
    navigator: DestinationNavigator,
    isTabActive: Bool,
    canPresentPendingHomeAction: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll,
    onPresentationStateChange: @escaping (DashPagePresentationState) -> Void
  ) -> DashTabPageSlot {
    let controller = DashPageStackViewController(
      root: root,
      model: model,
      navigator: navigator,
      navigationCoordinator: navigationCoordinator,
      anchorRegistry: anchorRegistry,
      presentationState: presentationState,
      isTabActive: isTabActive,
      canPresentPendingHomeAction: canPresentPendingHomeAction,
      splashLifted: splashLifted,
      workspaceWashScroll: workspaceWashScroll,
      locale: locale,
      dynamicTypeSize: dynamicTypeSize,
      accountID: navigator.accountID,
      onPresentationStateChange: onPresentationStateChange)
    return DashTabPageSlot(controller: controller) { [weak controller] update in
      controller?.update(
        isTabActive: update.isTabActive,
        canPresentPendingHomeAction: update.canPresentPendingHomeAction,
        splashLifted: update.splashLifted,
        workspaceWashScroll: update.workspaceWashScroll,
        locale: update.locale,
        dynamicTypeSize: update.dynamicTypeSize,
        onPresentationStateChange: update.onPresentationStateChange,
        request: update.request)
    }
  }

  private func pageUpdate(
    navigator: DestinationNavigator,
    isTabActive: Bool,
    canPresentPendingHomeAction: Bool,
    workspaceWashScroll: DashWorkspaceWashScroll,
    onPresentationStateChange: @escaping (DashPagePresentationState) -> Void
  ) -> DashTabPageUpdate {
    DashTabPageUpdate(
      isTabActive: isTabActive,
      canPresentPendingHomeAction: canPresentPendingHomeAction,
      splashLifted: splashLifted,
      workspaceWashScroll: workspaceWashScroll,
      locale: locale,
      dynamicTypeSize: dynamicTypeSize,
      onPresentationStateChange: onPresentationStateChange,
      request: DashPageStackRequest(
        entries: navigator.entries,
        revision: navigator.revision,
        mutation: navigator.lastMutation,
        accountID: navigator.accountID,
        reduceMotion: reduceMotion,
        isTabActive: isTabActive))
  }
}

private struct DashPageStackHost<Root: View>: UIViewControllerRepresentable {
  @Bindable var navigator: DestinationNavigator
  var isTabActive: Bool
  var canPresentPendingHomeAction: Bool
  var onPresentationStateChange: (DashPagePresentationState) -> Void
  @ViewBuilder var root: () -> Root

  @Environment(AppModel.self) private var model
  @Environment(\.dashNavigationCoordinator) private var navigationCoordinator
  @Environment(\.dashNavigationAnchorRegistry) private var anchorRegistry
  @Environment(\.dashWorkspacePresentationState) private var presentationState
  @Environment(\.dashWorkspaceWashScroll) private var workspaceWashScroll
  @Environment(\.locale) private var locale
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dashSplashLifted) private var splashLifted

  func makeUIViewController(context: Context) -> DashPageStackViewController<Root> {
    DashPageStackViewController(
      root: root(),
      model: model,
      navigator: navigator,
      navigationCoordinator: navigationCoordinator,
      anchorRegistry: anchorRegistry,
      presentationState: presentationState,
      isTabActive: isTabActive,
      canPresentPendingHomeAction: canPresentPendingHomeAction,
      splashLifted: splashLifted,
      workspaceWashScroll: workspaceWashScroll,
      locale: locale,
      dynamicTypeSize: dynamicTypeSize,
      accountID: navigator.accountID,
      onPresentationStateChange: onPresentationStateChange)
  }

  func updateUIViewController(
    _ uiViewController: DashPageStackViewController<Root>,
    context: Context
  ) {
    uiViewController.update(
      isTabActive: isTabActive,
      canPresentPendingHomeAction: canPresentPendingHomeAction,
      splashLifted: splashLifted,
      workspaceWashScroll: workspaceWashScroll,
      locale: locale,
      dynamicTypeSize: dynamicTypeSize,
      onPresentationStateChange: onPresentationStateChange,
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
  var canPresentPendingHomeAction = true
  var onPresentationStateChange: (DashPagePresentationState) -> Void = { _ in }
  @ViewBuilder var root: () -> Root

  var body: some View {
    DashPageStackHost(
      navigator: navigator,
      isTabActive: isTabActive,
      canPresentPendingHomeAction: canPresentPendingHomeAction,
      onPresentationStateChange: onPresentationStateChange,
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
  var allowsInteraction = true

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
        .disabled(!descriptor.isEnabled || !allowsInteraction)
        .opacity(resolvedOpacity)
        .accessibilityIdentifier(identifier)
    } else {
      control
        .disabled(!descriptor.isEnabled || !allowsInteraction)
        .opacity(resolvedOpacity)
    }
  }

  private var resolvedOpacity: Double {
    descriptor.isEnabled ? 1 : (descriptor.disabledOpacity ?? 1)
  }
}

private struct DashPageActionGroupView: View {
  let actions: [DashPageActionDescriptor]
  var allowsInteraction = true

  var body: some View {
    DashToolbarActionGroup {
      ForEach(actions) { action in
        DashPageActionControl(
          descriptor: action,
          allowsInteraction: allowsInteraction)
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
  let allowsBusinessActions: Bool
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
          DashPageActionGroupView(
            actions: chrome.trailingActions,
            allowsInteraction: allowsBusinessActions)
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
      DashPageActionGroupView(
        actions: chrome.leadingActions,
        allowsInteraction: allowsBusinessActions)
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

/// The visible leading replacement owns VoiceOver Escape too. Equality ignores
/// the closure deliberately: a page action's stable ID and enabled state define
/// its lifetime, while SwiftUI's state-backed action keeps reading live values.
private struct DashPageEscapeActionPreference: Equatable {
  let id: String
  let isEnabled: Bool
  let action: () -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.isEnabled == rhs.isEnabled
  }
}

private struct DashPageEscapeActionPreferenceKey: PreferenceKey {
  static var defaultValue: DashPageEscapeActionPreference? { nil }

  static func reduce(
    value: inout DashPageEscapeActionPreference?,
    nextValue: () -> DashPageEscapeActionPreference?
  ) {
    if let next = nextValue() { value = next }
  }
}

/// Page-local custom chrome used by Dash's UIKit page container. It
/// deliberately lives in the same SwiftUI tree as the page so dynamic actions,
/// frost, and scroll probing retain their existing ownership.
struct DashRoutePageChromeHost<Content: View>: View {
  let entry: DashNavigationEntry?
  var allowsBodyInteraction = true
  @ViewBuilder var content: () -> Content
  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.dashWorkspaceWashScroll) private var washScroll
  @State private var scroll = DashHeaderScrollState()
  @State private var preferredEscapeAction: DashPageEscapeActionPreference?

  var body: some View {
    Group {
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(allowsBodyInteraction)
        .accessibilityHidden(!allowsBodyInteraction)
    }
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
          allowsBusinessActions: allowsBodyInteraction,
          dismiss: { navigator?.dismiss(entryID: entry.id) }
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
    .onPreferenceChange(DashPageEscapeActionPreferenceKey.self) { action in
      preferredEscapeAction = action
    }
    .modifier(
      DashPageEscapeActionModifier(
        isEnabled: entry != nil,
        action: {
          guard let entry else { return }
          if let preferredEscapeAction {
            guard preferredEscapeAction.isEnabled, allowsBodyInteraction else { return }
            preferredEscapeAction.action()
          } else {
            navigator?.dismiss(entryID: entry.id)
          }
        }))
  }
}

private struct DashPageActionsModifier: ViewModifier {
  let leading: [DashPageActionDescriptor]
  let trailing: [DashPageActionDescriptor]

  func body(content: Content) -> some View {
    content
      // Mutate only the action slots. Replacing the whole preference here
      // would erase an inner `detailHeader` descriptor on the same page.
      .transformPreference(DashPageChromePreferenceKey.self) { preference in
        preference.leadingActions = leading
        preference.trailingActions = trailing
      }
      .preference(
        key: DashPageEscapeActionPreferenceKey.self,
        value: leading.first.map {
          DashPageEscapeActionPreference(
            id: $0.id,
            isEnabled: $0.isEnabled,
            action: $0.action)
        }
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
      // Preserve page actions regardless of modifier order.
      .transformPreference(DashPageChromePreferenceKey.self) { preference in
        preference.header = DashPageHeaderDescriptor(
          icon: icon,
          title: displayedTitle,
          tint: resolvedTint)
      }
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

/// Supplies a navigation action whose concrete source occurrence is registered
/// with the custom page compositor. Use this for controls that need their own
/// button style; `DestinationLink` is the standard row-shaped convenience.
struct DashNavigationSource<Content: View>: View {
  let destination: Destination
  var presentation: DashNavigationPresentation?
  var onNavigate: (() -> Void)?
  /// Optional lifecycle boundary (for example a Tray's `dismissAfter`). The
  /// source geometry is captured on the tap, before the presenting surface
  /// unmounts; only the route mutation waits for the boundary to finish.
  var schedule: ((@escaping () -> Void) -> Void)?
  @ViewBuilder var content: (@escaping () -> Void) -> Content

  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.dashNavigationAnchorRegistry) private var anchorRegistry
  @Environment(\.dashNavigationEntryID) private var sourceEntryID
  @State private var anchorInstanceID = UUID()

  var body: some View {
    content(navigate)
      .dashNavigationAnchor(instanceID: anchorInstanceID)
  }

  private func navigate() {
    let origin = anchorRegistry?.captureOrigin(
      semanticID: destination.dashNavigationSemanticID,
      anchorInstanceID: anchorInstanceID)
    let expectedNavigator = navigator
    let expectedSourceEntryID = sourceEntryID
    onNavigate?()
    // `onNavigate` may legitimately synchronize this navigator's account
    // scope. The delayed-intent baseline starts after that preparation, while
    // the source visual was still captured synchronously at the tap.
    let expectedRevision = expectedNavigator?.revision
    let expectedAccountID = expectedNavigator?.accountID
    let commit: () -> Void = {
      guard let expectedNavigator, let expectedRevision,
        expectedNavigator.revision == expectedRevision,
        expectedNavigator.accountID == expectedAccountID,
        expectedSourceEntryID == nil
          || expectedNavigator.topEntry?.id == expectedSourceEntryID
      else {
        anchorRegistry?.discardCapturedVisual(for: origin)
        return
      }
      let entryID = expectedNavigator.push(
        destination,
        presentation: presentation,
        origin: origin)
      if entryID == nil {
        anchorRegistry?.discardCapturedVisual(for: origin)
      }
    }
    if let schedule {
      schedule(commit)
    } else {
      commit()
    }
  }
}

/// Opens a `Destination` on the enclosing tab's custom page stack.
struct DestinationLink<Label: View>: View {
  let destination: Destination
  var onNavigate: (() -> Void)?
  @ViewBuilder var label: () -> Label

  var body: some View {
    DashNavigationSource(destination: destination, onNavigate: onNavigate) { navigate in
      Button(action: navigate) {
        label()
      }
      // A navigation row is a surface, not a button — it must not shrink on press.
      .buttonStyle(DashSurfaceButtonStyle())
    }
  }
}
