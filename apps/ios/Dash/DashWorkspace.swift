import CloudflareAPI
import GradientAvatars
import SwiftUI
import UIKit

// MARK: - Destination navigator

enum DashNavigationPresentation: Hashable {
  /// A conventional child page whose chrome exposes Back. Whether it morphs out
  /// of its source or hands off horizontally is decided by the source, not by
  /// the route: only a card that publishes a hero earns the expansion.
  case detail
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

extension DashNavigationSemanticID {
  static func zoneHero(_ zoneID: String) -> DashNavigationSemanticID {
    DashNavigationSemanticID(namespace: "zone-hero", value: zoneID)
  }
}

/// Semantic content a card transition can redraw at every intermediate size.
/// Keeping this data with the route origin lets the compositor re-layout a
/// real SwiftUI surface instead of stretching captured pixels.
enum DashNavigationHero: Hashable {
  case domainCard(
    name: String,
    status: String,
    seed: String,
    fillHex: UInt32,
    plan: String?)
}

/// One concrete occurrence of a semantic source. The same resource can appear
/// in Home recents, a feature list, and a pinned card at the same time.
struct DashNavigationOrigin: Hashable {
  let semanticID: DashNavigationSemanticID
  let anchorInstanceID: UUID
  /// Global frame captured synchronously with the navigation intent. The live
  /// source often unmounts in the same update that reveals the destination.
  let sourceFrame: CGRect?
  let hero: DashNavigationHero?

  init(
    semanticID: DashNavigationSemanticID,
    anchorInstanceID: UUID,
    sourceFrame: CGRect? = nil,
    hero: DashNavigationHero? = nil
  ) {
    self.semanticID = semanticID
    self.anchorInstanceID = anchorInstanceID
    self.sourceFrame = sourceFrame
    self.hero = hero
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
  /// The page this mutation is about — the one arriving on a push, the one
  /// leaving on every dismissal. It carries the presentation and origin, which
  /// is what lets shared chrome resolve the SAME transition role the page
  /// compositor picked instead of guessing one from the reason alone.
  let entry: DashNavigationEntry?
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
    case .detail:
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

  /// Settings is the only route that leaves the page stack's own language — it
  /// is the workspace train. Everything else is a `detail` drill: Resources
  /// into a feature, a feature into a resource, a resource into its settings.
  /// A route never claims the card expansion for itself; the concrete source
  /// does, by publishing a hero (`DashNavigationHero`).
  fileprivate var dashDefaultNavigationPresentation: DashNavigationPresentation {
    switch self {
    case .settings:
      .workspaceOverlay
    default:
      .detail
    }
  }

  /// The in-page landmark a workspace present flies its source visual onto.
  /// Only pages that visibly re-seat their source element publish one; every
  /// other destination keeps the in-place identity crossfade.
  var dashNavigationLandingSemanticID: DashNavigationSemanticID? {
    switch self {
    case .zone(let id): .zoneHero(id)
    default: nil
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

  /// Where this stack's pages publish their header slots. Deliberately a stored
  /// `let` on the navigator rather than one more value threaded through the tab
  /// flow: every page already reads the navigator from the environment, and so
  /// does the shared header.
  let pageChrome = DashPageChromeStore()
  /// Who paints those slots. `.workspace` is the product path — one bar above
  /// the pager. `.page` keeps a stack hosted outside `MainTabView` (previews,
  /// UI-test harnesses) drawing its own bar, so it never loses Back.
  let chromeHosting: DashPageChromeHosting

  var path: [Destination] { entries.map(\.destination) }
  var entryIDs: [DashNavigationEntry.ID] { entries.map(\.id) }
  var depth: Int { entries.count }
  var top: Destination? { entries.last?.destination }
  var topEntry: DashNavigationEntry? { entries.last }

  init(
    accountID: String? = nil,
    chromeHosting: DashPageChromeHosting = .page
  ) {
    self.accountID = accountID
    self.chromeHosting = chromeHosting
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
    // The page the mutation is about, resolved before the swap: a push is
    // about the page arriving, every dismissal is about the page leaving —
    // the same two entries the compositor picks its style from.
    let mutatedEntry: DashNavigationEntry? =
      switch reason {
      case .push: nextEntries.last
      case .back, .popToRoot, .closeToWorkspaceRoot, .resourcePruned: entries.last
      case .reset, .accountScopeChanged: nil
      }
    entries = nextEntries
    // Slots leave with their page. Pruning here — the one mutation funnel —
    // means a re-push of the same route can never inherit the last instance's
    // title or actions while its own body is still resolving.
    pageChrome.prune(keeping: Set(entryIDs))
    revision &+= 1
    lastMutation = DashNavigationMutation(
      revision: revision,
      reason: reason,
      previousEntryIDs: previousEntryIDs,
      currentEntryIDs: entryIDs,
      entry: mutatedEntry)
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
  private final class WeakClaim {
    weak var value: DashNavigationAnchorClaim?

    init(_ value: DashNavigationAnchorClaim) {
      self.value = value
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

  private var hostedFrames: [UUID: CGRect] = [:]
  private var sourceViews: [UUID: WeakSourceView] = [:]
  private var capturedVisuals: [UUID: CapturedVisual] = [:]
  /// Landing seats published by destination pages. Keyed by semantic identity
  /// because the transition renderer has no way to learn a fresh page's private
  /// anchor UUID; the concrete occurrence re-registers under the same key on
  /// every page instance.
  private var landingInstanceIDs: [DashNavigationSemanticID: UUID] = [:]
  /// Which occurrences the compositor currently owns. Plain storage, and the
  /// source of truth across a remount — the observable half is per anchor.
  private var claimedInstanceIDs: Set<UUID> = []
  /// One observable box per mounted anchor. This is deliberately NOT one
  /// shared observable set: `@Observable` tracks per PROPERTY, so a single
  /// `Set<UUID>` read by every anchor's body meant claiming ONE occurrence
  /// invalidated EVERY anchor in the app — all sixty Domains cards, every Home
  /// row — and a card morph claims twice on the frame it starts and releases
  /// twice on the frame it lands. That is four whole-app relayouts landing
  /// exactly where the morph needs its frame budget.
  private var claims: [UUID: WeakClaim] = [:]

  /// Preferences do not cross a `UIHostingController` boundary, and every route
  /// is one — a preference-published frame could therefore only ever describe
  /// the outer workspace chrome, which the live probe and this store already
  /// cover. Pages publish here directly.
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

  func registerLanding(instanceID: UUID, for semanticID: DashNavigationSemanticID) {
    landingInstanceIDs[semanticID] = instanceID
  }

  /// A purged page may tear down after its successor registered the same seat;
  /// only the current occupant may vacate the key.
  func unregisterLanding(instanceID: UUID, for semanticID: DashNavigationSemanticID) {
    guard landingInstanceIDs[semanticID] == instanceID else { return }
    landingInstanceIDs[semanticID] = nil
  }

  /// Live occurrence of a destination-page landing seat. Valid only while that
  /// page's probe is mounted in a window, so the caller resolves it after the
  /// arriving page has laid out — never from a captured fallback frame.
  func landingOrigin(for semanticID: DashNavigationSemanticID) -> DashNavigationOrigin? {
    guard let instanceID = landingInstanceIDs[semanticID] else { return nil }
    return DashNavigationOrigin(semanticID: semanticID, anchorInstanceID: instanceID)
  }

  func frame(for origin: DashNavigationOrigin) -> CGRect? {
    sourceWindowFrame(for: origin.anchorInstanceID)
      ?? hostedFrames[origin.anchorInstanceID]
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
    claimedInstanceIDs.insert(origin.anchorInstanceID)
    claims[origin.anchorInstanceID]?.value?.isClaimed = true
  }

  func release(_ origin: DashNavigationOrigin?) {
    guard let origin else { return }
    claimedInstanceIDs.remove(origin.anchorInstanceID)
    claims[origin.anchorInstanceID]?.value?.isClaimed = false
  }

  /// A claimed occurrence can remount mid-flight (a page host reattaching, a
  /// lazy row scrolling back in), so the box re-arms from the plain set rather
  /// than defaulting to visible and double-rendering the element in flight.
  func registerClaim(_ claim: DashNavigationAnchorClaim, for instanceID: UUID) {
    claims[instanceID] = WeakClaim(claim)
    claim.isClaimed = claimedInstanceIDs.contains(instanceID)
  }

  func unregisterClaim(_ claim: DashNavigationAnchorClaim, for instanceID: UUID) {
    guard claims[instanceID]?.value === claim else { return }
    claims[instanceID] = nil
  }

  func captureOrigin(
    semanticID: DashNavigationSemanticID,
    anchorInstanceID: UUID,
    hero: DashNavigationHero? = nil
  ) -> DashNavigationOrigin {
    let frame =
      sourceWindowFrame(for: anchorInstanceID)
      ?? hostedFrames[anchorInstanceID]
    if hero == nil,
      let source = sourceViews[anchorInstanceID]?.value,
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
      sourceFrame: frame,
      hero: hero)
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

/// When set, an inner control (the header avatar circle) registers the
/// navigation source anchor instead of the outer `DashNavigationSource` wrapper
/// — so a transition captures the face, not the glass chrome around it.
private struct DashNavigationEmbeddedAnchorIDKey: EnvironmentKey {
  static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
  var destinationNavigator: DestinationNavigator? {
    get { self[DestinationNavigatorKey.self] }
    set { self[DestinationNavigatorKey.self] = newValue }
  }

  var dashNavigationEmbeddedAnchorID: UUID? {
    get { self[DashNavigationEmbeddedAnchorIDKey.self] }
    set { self[DashNavigationEmbeddedAnchorIDKey.self] = newValue }
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
  func dashNavigationAnchor(
    instanceID: UUID,
    landing: DashNavigationSemanticID? = nil
  ) -> some View {
    modifier(DashNavigationAnchorModifier(instanceID: instanceID, landing: landing))
  }

  /// Publishes this view as a destination-page landing seat: the spot a card
  /// morph grows its source onto. The claim mechanism hides the live view
  /// while the flight proxy owns its identity, exactly like a navigation
  /// source. Today only the zone hero publishes one.
  func dashNavigationLanding(_ semanticID: DashNavigationSemanticID) -> some View {
    modifier(DashNavigationLandingModifier(semanticID: semanticID))
  }
}

private struct DashNavigationLandingModifier: ViewModifier {
  let semanticID: DashNavigationSemanticID
  @State private var instanceID = UUID()

  func body(content: Content) -> some View {
    content.dashNavigationAnchor(instanceID: instanceID, landing: semanticID)
  }
}

/// One anchor's "the compositor owns me right now" flag. Per occurrence on
/// purpose: an anchor's body observes ONLY its own box, so claiming one source
/// cannot invalidate every other anchor on screen.
@MainActor
@Observable
final class DashNavigationAnchorClaim {
  var isClaimed = false
}

private struct DashNavigationAnchorModifier: ViewModifier {
  let instanceID: UUID
  var landing: DashNavigationSemanticID?
  @Environment(\.dashNavigationAnchorRegistry) private var registry
  @State private var claim = DashNavigationAnchorClaim()

  func body(content: Content) -> some View {
    let isClaimed = claim.isClaimed
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
            .onAppear {
              registry?.setHostedFrame(frame, for: instanceID)
              registry?.registerClaim(claim, for: instanceID)
            }
            .onChange(of: frame) { _, nextFrame in
              registry?.setHostedFrame(nextFrame, for: instanceID)
            }
            .onDisappear {
              registry?.removeHostedFrame(for: instanceID)
              registry?.unregisterClaim(claim, for: instanceID)
            }
            .overlay {
              DashNavigationAnchorProbe(
                instanceID: instanceID,
                landing: landing,
                registry: registry)
            }
        }
      }
  }
}

private struct DashNavigationAnchorProbe: UIViewRepresentable {
  let instanceID: UUID
  var landing: DashNavigationSemanticID?
  let registry: DashNavigationAnchorRegistry?

  func makeUIView(context: Context) -> DashNavigationAnchorProbeView {
    let view = DashNavigationAnchorProbeView()
    view.configure(instanceID: instanceID, landing: landing, registry: registry)
    return view
  }

  func updateUIView(_ uiView: DashNavigationAnchorProbeView, context: Context) {
    uiView.configure(instanceID: instanceID, landing: landing, registry: registry)
  }

  static func dismantleUIView(_ uiView: DashNavigationAnchorProbeView, coordinator: ()) {
    uiView.tearDown()
  }
}

private final class DashNavigationAnchorProbeView: UIView {
  private var instanceID: UUID?
  private var landing: DashNavigationSemanticID?
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

  func configure(
    instanceID: UUID,
    landing: DashNavigationSemanticID?,
    registry: DashNavigationAnchorRegistry?
  ) {
    if self.instanceID != instanceID || self.landing != landing
      || self.registry !== registry
    {
      tearDown()
      self.instanceID = instanceID
      self.landing = landing
      self.registry = registry
    }
    // Probe registration runs inside UIKit layout, so a landing seat is
    // resolvable synchronously after the arriving page's first layoutIfNeeded —
    // before its transition builds a proxy.
    registry?.registerSourceView(self, for: instanceID)
    if let landing {
      registry?.registerLanding(instanceID: instanceID, for: landing)
    }
  }

  func tearDown() {
    if let instanceID {
      registry?.unregisterSourceView(self, for: instanceID)
      if let landing {
        registry?.unregisterLanding(instanceID: instanceID, for: landing)
      }
    }
    instanceID = nil
    landing = nil
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

/// The card is the only moving spatial identity. Both pages stay fixed while
/// the source context softens and the destination content resolves behind it.
enum DashCardMorphRules {
  static let movesPages = false

  /// Distance the invisible timeline driver's position travels for progress
  /// 0 → 1. Any value works — larger buys sampling resolution; the driver is
  /// zero-sized and never seen.
  static let timelineTravel: CGFloat = 320

  /// One duration for every flight makes speed proportional to distance: a
  /// bottom-row card covers three times the ground of a top-row card in the
  /// same window and reads as lunging. Flights at or under `referenceTravel`
  /// (the top rows) keep the base pace; longer ones stretch linearly up to
  /// `maxFlightStretch` at `farTravel`, so every card GROWS at roughly the
  /// same felt rate. Applies to pops too — a far card rushing home is the
  /// same lunge backwards.
  static let referenceTravel: CGFloat = 220
  static let farTravel: CGFloat = 640
  static let maxFlightStretch: Double = 1.3

  static func flightDuration(
    base: TimeInterval,
    from source: CGRect,
    to landing: CGRect
  ) -> TimeInterval {
    let travel = hypot(landing.midX - source.midX, landing.midY - source.midY)
    guard travel > referenceTravel else { return base }
    let unit = Double(
      min((travel - referenceTravel) / (farTravel - referenceTravel), 1))
    return base * (1 + (maxFlightStretch - 1) * unit)
  }

  /// Floor-clamped only. The enter spring is slightly underdamped and its
  /// overshoot past 1 extrapolates the flight a few points past the landing
  /// seat before settling back — that extrapolation IS the bounce. Every
  /// non-spatial curve (`smoothSegment` consumers) clamps internally, so the
  /// hero frame is the one place the overshoot lands.
  static func heroFrame(
    from source: CGRect,
    to landing: CGRect,
    detailProgress: CGFloat
  ) -> CGRect {
    let progress = max(detailProgress, 0)
    return CGRect(
      x: source.minX + (landing.minX - source.minX) * progress,
      y: source.minY + (landing.minY - source.minY) * progress,
      width: source.width + (landing.width - source.width) * progress,
      height: source.height + (landing.height - source.height) * progress)
  }

  static func detailPageOpacity(at detailProgress: CGFloat) -> CGFloat {
    smoothSegment(detailProgress, from: 0.2, to: 0.88)
  }

  static func departingDetailPageOpacity(at detailProgress: CGFloat) -> CGFloat {
    smoothSegment(detailProgress, from: 0.44, to: 0.94)
  }

  /// The veil only ever grows. It used to pulse — rise, then fade back off —
  /// and a full-screen blur that both arrives and leaves inside one 380ms
  /// flight reads as a blink no matter how wide the ramps are. Riding *under*
  /// the arriving page instead, it is retired by being covered: the opaque
  /// destination resolves on top of it (`detailPageOpacity`) and the veil
  /// never has to travel back down while anyone can see it. A reversed push
  /// runs this same curve backwards, continuously, under the finger.
  static func backdropOpacity(at detailProgress: CGFloat) -> CGFloat {
    smoothSegment(detailProgress, from: 0, to: 0.6)
  }

  static func detailAccessoryOpacity(at detailProgress: CGFloat) -> CGFloat {
    smoothSegment(detailProgress, from: 0.62, to: 0.9)
  }

  static func isUsableEndpoint(_ frame: CGRect, in bounds: CGRect) -> Bool {
    frame.width > 2 && frame.height > 2
      && frame.width.isFinite && frame.height.isFinite
      && frame.minX.isFinite && frame.minY.isFinite
      && frame.intersects(bounds.insetBy(dx: -2, dy: -2))
  }

  private static func smoothSegment(
    _ progress: CGFloat,
    from start: CGFloat,
    to end: CGFloat
  ) -> CGFloat {
    guard end > start else { return progress >= end ? 1 : 0 }
    let unit = min(max((progress - start) / (end - start), 0), 1)
    return unit * unit * (3 - 2 * unit)
  }
}

private struct DashNavigationHeroView: View {
  let hero: DashNavigationHero
  let detailProgress: CGFloat
  let locale: Locale
  let dynamicTypeSize: DynamicTypeSize

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .environment(\.locale, locale)
      .environment(\.dynamicTypeSize, dynamicTypeSize)
  }

  @ViewBuilder
  private var content: some View {
    switch hero {
    case .domainCard(let name, let status, let seed, let fillHex, let plan):
      DomainCardFace(
        name: name,
        status: status,
        seed: seed,
        fillHex: fillHex,
        plan: plan,
        fillsContainer: true,
        detailReveal: detailProgress
      )
      .overlay(alignment: .bottomTrailing) {
        DomainCardCustomizeButton {}
          .opacity(DashCardMorphRules.detailAccessoryOpacity(at: detailProgress))
          .padding(12)
      }
    }
  }
}

/// The three page languages Dash speaks, and nothing else. `flow` is the
/// horizontal handoff every drill-down uses — the outgoing page leaves while
/// the arriving one enters, the same step a tab change makes. `card` is the
/// Family-style expansion, reserved for a source that hands over a concrete
/// card (Domains → zone detail). `workspace` is the Settings train.
enum DashPageTransitionRole: Hashable {
  case flow
  case card
  case workspace
}

enum DashPageTransitionRules {
  /// The source decides between flow and card, never the destination: the same
  /// zone opened from a Home row or a recent is a plain drill, and only the
  /// domain card that publishes a hero morphs.
  static func role(
    presentation: DashNavigationPresentation,
    hasHero: Bool
  ) -> DashPageTransitionRole {
    switch presentation {
    case .workspaceOverlay: .workspace
    case .detail: hasHero ? .card : .flow
    }
  }

  /// ONE pace table. The page compositor animates in UIKit and the shared
  /// header in SwiftUI, but they are two halves of the same step — read the
  /// timing from here in both, or Close outlives the train it left with.
  static func duration(for role: DashPageTransitionRole, isPush: Bool) -> TimeInterval {
    switch role {
    case .flow:
      isPush
        ? DashTheme.Motion.Page.flowEnterDuration
        : DashTheme.Motion.Page.flowExitDuration
    case .card:
      isPush
        ? DashTheme.Motion.Page.cardEnterDuration
        : DashTheme.Motion.Page.cardExitDuration
    case .workspace:
      isPush
        ? DashTheme.Motion.Page.workspaceEnterDuration
        : DashTheme.Motion.Page.workspaceExitDuration
    }
  }

  static func dampingRatio(for role: DashPageTransitionRole, isPush: Bool) -> CGFloat {
    switch role {
    case .flow: DashTheme.Motion.Page.flowDampingRatio
    case .card:
      isPush
        ? DashTheme.Motion.Page.cardEnterDampingRatio
        : DashTheme.Motion.Page.cardExitDampingRatio
    case .workspace:
      isPush
        ? DashTheme.Motion.Page.workspaceEnterDampingRatio
        : DashTheme.Motion.Page.workspaceExitDampingRatio
    }
  }
}

private enum DashPageTransitionStyle {
  case flowPush
  case flowPop
  case cardPush(DashNavigationEntry)
  case cardPop(DashNavigationEntry)
  case workspacePresent(DashNavigationEntry)
  case workspaceDismiss(DashNavigationEntry)

  var isPush: Bool {
    switch self {
    case .flowPush, .cardPush, .workspacePresent: true
    case .flowPop, .cardPop, .workspaceDismiss: false
    }
  }

  var entry: DashNavigationEntry? {
    switch self {
    case .cardPush(let entry), .cardPop(let entry),
      .workspacePresent(let entry), .workspaceDismiss(let entry):
      entry
    case .flowPush, .flowPop:
      nil
    }
  }

  var role: DashPageTransitionRole {
    switch self {
    case .flowPush, .flowPop: .flow
    case .cardPush, .cardPop: .card
    case .workspacePresent, .workspaceDismiss: .workspace
    }
  }

  var duration: TimeInterval {
    DashPageTransitionRules.duration(for: role, isPush: isPush)
  }

  var dampingRatio: CGFloat {
    DashPageTransitionRules.dampingRatio(for: role, isPush: isPush)
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
    /// Sits between the stationary pages for a card transition: it softens the
    /// old context while the sharp destination resolves above it.
    let backgroundEffect: UIView?
    let outgoingContent: UIView?
    let arrivingContent: UIView?
    /// Retains the live SwiftUI card renderer for the transition and handoff beat.
    let heroController: UIHostingController<DashNavigationHeroView>?
    /// Invisible property-animation payload that gives the display-link content
    /// timeline a reversible progress source without transforming any pixels.
    let timelineDriver: UIView?
    let claimedOrigin: DashNavigationOrigin?
    /// Second claim for a destination-page landing seat, held for the same
    /// span as `claimedOrigin` so the live seat never doubles the flight.
    let claimedLanding: DashNavigationOrigin?
    /// Fixed end of a card morph's flight — the settled hero seat.
    let morphTargetFrame: CGRect?
    /// Fixed start of a morph flight, captured before the page train moves.
    let morphStartFrame: CGRect?

    init(
      overlay: UIView,
      shell: UIView?,
      backgroundEffect: UIView? = nil,
      outgoingContent: UIView?,
      arrivingContent: UIView?,
      heroController: UIHostingController<DashNavigationHeroView>? = nil,
      timelineDriver: UIView?,
      claimedOrigin: DashNavigationOrigin?,
      claimedLanding: DashNavigationOrigin? = nil,
      morphTargetFrame: CGRect? = nil,
      morphStartFrame: CGRect? = nil
    ) {
      self.overlay = overlay
      self.shell = shell
      self.backgroundEffect = backgroundEffect
      self.outgoingContent = outgoingContent
      self.arrivingContent = arrivingContent
      self.heroController = heroController
      self.timelineDriver = timelineDriver
      self.claimedOrigin = claimedOrigin
      self.claimedLanding = claimedLanding
      self.morphTargetFrame = morphTargetFrame
      self.morphStartFrame = morphStartFrame
    }

    var isCardMorph: Bool { heroController != nil }
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
  /// Landed morph overlays outliving their transition by one handoff beat.
  /// The live element underneath is revealed on a later SwiftUI commit; these
  /// must be swept before any new transition composes over them.
  private var lingeringProxies: [TransitionProxy] = []
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
      DashContainmentLayout.fill(child.view, in: view.bounds)
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
      return switch role(for: entry) {
      case .flow: .flowPush
      case .card: .cardPush(entry)
      case .workspace: .workspacePresent(entry)
      }
    case .closeToWorkspaceRoot:
      guard let entry = settledEntries.last else { return .flowPop }
      return .workspaceDismiss(entry)
    case .back, .popToRoot, .resourcePruned:
      guard let entry = settledEntries.last else { return .flowPop }
      return switch role(for: entry) {
      case .flow: .flowPop
      case .card: .cardPop(entry)
      case .workspace: .workspaceDismiss(entry)
      }
    case .reset, .accountScopeChanged, nil:
      return .flowPush
    }
  }

  private func role(for entry: DashNavigationEntry) -> DashPageTransitionRole {
    DashPageTransitionRules.role(
      presentation: entry.presentation,
      hasHero: entry.origin?.hero != nil)
  }

  private func performTransition(
    from source: UIViewController,
    to target: UIViewController,
    style requestedStyle: DashPageTransitionStyle,
    request: DashPageStackRequest
  ) {
    removeLingeringProxyOverlays()
    let targetOwnsDestinationCanvas = !request.entries.isEmpty
    prepareDestinationCanvasTransition(targetVisible: targetOwnsDestinationCanvas)
    let isPush = requestedStyle.isPush
    hostContext.interactionLockedEntryID = isPush ? request.entries.last?.id : nil

    // A newly attached hosting controller may commit its first SwiftUI frame
    // during containment/layout. Put it in a non-visible push pose before it
    // enters the hierarchy so that frame can never flash above the safe area.
    resetTransitionState(source.view)
    resetTransitionState(target.view)
    if isPush { target.view.alpha = 0 }

    attach(target, above: isPush ? source : nil)
    if !isPush {
      view.insertSubview(target.view, belowSubview: source.view)
    }
    view.layoutIfNeeded()
    let style = resolvedTransitionStyle(
      requestedStyle,
      source: source.view,
      target: target.view)
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
      reduceMotion: request.reduceMotion)

    let appearanceWasBegun = isContainerVisible && !parentAppearanceIsDisappearing
    if appearanceWasBegun {
      source.beginAppearanceTransition(false, animated: true)
      target.beginAppearanceTransition(true, animated: true)
    }

    var duration =
      request.reduceMotion
      ? DashTheme.Motion.Page.reducedDuration
      : style.duration
    // A card flight paces itself to the ground it covers; see the rule.
    if !request.reduceMotion, let proxy, proxy.isCardMorph,
      let start = proxy.morphStartFrame, let landing = proxy.morphTargetFrame
    {
      duration = DashCardMorphRules.flightDuration(
        base: duration,
        from: start,
        to: landing)
    }
    let animator = UIViewPropertyAnimator(
      duration: duration,
      dampingRatio: request.reduceMotion ? 1 : style.dampingRatio)
    animator.scrubsLinearly = false
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
    reduceMotion: Bool
  ) {
    let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
    switch style {
    case .flowPush, .flowPop:
      applyTabStepInitial(
        isPush: style.isPush,
        source: source,
        target: target,
        rightToLeft: rightToLeft,
        reduceMotion: reduceMotion)
    case .cardPush:
      target.alpha = 0
    case .cardPop:
      // Root already sits behind the detail. The display-link timeline fades
      // only the detail page, so neither page acquires spatial travel.
      target.alpha = 1
    case .workspacePresent:
      // Vertical train: the workspace descends off the bottom while settings
      // rides in from above, edge to edge in the same animator, so the two
      // pages read as one connected surface.
      if reduceMotion {
        target.alpha = 0
      } else {
        target.alpha = 1
        target.transform = CGAffineTransform(translationX: 0, y: -view.bounds.height)
      }
    case .workspaceDismiss:
      if reduceMotion {
        target.alpha = 0
      } else {
        target.alpha = 1
        target.transform = CGAffineTransform(translationX: 0, y: view.bounds.height)
      }
    }
    if source.alpha != 0 { source.alpha = 1 }
  }

  /// Flow pages use the same short directional handoff as tab changes. Card
  /// pushes stay stationary and keep their independent semantic hero timeline.
  private func applyTabStepInitial(
    isPush: Bool,
    source: UIView,
    target: UIView,
    rightToLeft: Bool,
    reduceMotion: Bool
  ) {
    let direction = DashTabTransitionRules.pageStepDirection(isPush: isPush)
    let travel = DashTabTransitionRules.signedTravel(
      for: direction,
      rightToLeft: rightToLeft,
      reduceMotion: reduceMotion)
    source.alpha = 1
    source.transform = .identity
    target.alpha = 0
    target.transform =
      reduceMotion ? .identity : CGAffineTransform(translationX: travel, y: 0)
  }

  private func applyTabStepFinal(
    isPush: Bool,
    source: UIView,
    target: UIView,
    rightToLeft: Bool,
    reduceMotion: Bool
  ) {
    let direction = DashTabTransitionRules.pageStepDirection(isPush: isPush)
    let outgoingTravel = DashTabTransitionRules.outgoingEndOffset(
      for: direction,
      rightToLeft: rightToLeft,
      reduceMotion: reduceMotion)
    target.alpha = 1
    target.transform = .identity
    source.alpha = 0
    source.transform =
      reduceMotion ? .identity : CGAffineTransform(translationX: outgoingTravel, y: 0)
  }

  private func applyFinalTransitionState(
    style: DashPageTransitionStyle,
    source: UIView,
    target: UIView,
    proxy: TransitionProxy?,
    reduceMotion: Bool
  ) {
    let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
    switch style {
    case .flowPush, .flowPop:
      applyTabStepFinal(
        isPush: style.isPush,
        source: source,
        target: target,
        rightToLeft: rightToLeft,
        reduceMotion: reduceMotion)
    case .cardPush, .cardPop:
      if let proxy {
        // The card timeline rides POSITION, not opacity: a slightly
        // underdamped enter spring overshoots its end value, and a layer's
        // presentation opacity clamps at 1 — sampling it would flatten the
        // bounce into a dead stop at the seat. Position reports the raw
        // spring, so progress can pass 1 and come back.
        proxy.timelineDriver?.center = CGPoint(
          x: DashCardMorphRules.timelineTravel,
          y: 0)
      } else {
        // Reduce Motion and invalid-endpoint fallback keep a short crossfade.
        target.alpha = 1
        source.alpha = 0
      }
    case .workspacePresent:
      target.alpha = 1
      target.transform = .identity
      if !reduceMotion {
        source.transform = CGAffineTransform(translationX: 0, y: view.bounds.height)
      }
      // Morph frames are driven by the display-link timeline so they can track
      // the seat through the page train. Alphas still settle here so a morph
      // and the in-place identity crossfade share one fade curve.
      proxy?.outgoingContent?.alpha = 0
      proxy?.arrivingContent?.alpha = 1
    case .workspaceDismiss:
      target.alpha = 1
      target.transform = .identity
      if reduceMotion {
        source.alpha = 0
      } else {
        source.transform = CGAffineTransform(translationX: 0, y: -view.bounds.height)
      }
      proxy?.outgoingContent?.alpha = 0
      proxy?.arrivingContent?.alpha = 1
    }
  }

  /// The semantic card is laid out at every intermediate size. Updating bounds
  /// and center preserves the SwiftUI hierarchy's typography and avatar shape;
  /// no bitmap is ever non-uniformly scaled between the two aspect ratios.
  private func applyCardHeroFrame(_ proxy: TransitionProxy, at frame: CGRect) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for hero in [proxy.outgoingContent, proxy.arrivingContent] {
      guard let hero else { continue }
      hero.bounds = CGRect(origin: .zero, size: frame.size)
      hero.center = CGPoint(x: frame.midX, y: frame.midY)
      hero.setNeedsLayout()
      hero.layoutIfNeeded()
    }
    CATransaction.commit()
  }

  private func updateCardHeroContent(
    _ proxy: TransitionProxy,
    detailProgress: CGFloat
  ) {
    guard let controller = proxy.heroController else { return }
    let root = controller.rootView
    controller.rootView = DashNavigationHeroView(
      hero: root.hero,
      detailProgress: detailProgress,
      locale: root.locale,
      dynamicTypeSize: root.dynamicTypeSize)
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
    if case .cardPop = style {
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
    var backgroundEffect: UIView?
    var outgoingContent: UIView?
    var arrivingContent: UIView?
    var heroController: UIHostingController<DashNavigationHeroView>?
    var timelineDriver: UIView?
    var claimedOrigin: DashNavigationOrigin?
    var claimedLanding: DashNavigationOrigin?
    var morphTargetFrame: CGRect?
    var morphStartFrame: CGRect?

    switch style {
    case .cardPush, .cardPop:
      guard let hero = entry.origin?.hero else { return nil }
      let landingPage = style.isPush ? target : source
      guard let landing = resolvedLandingOrigin(for: entry, in: landingPage),
        let landingFrame = anchorFrameInContainer(for: landing, liveOnly: true)
      else { return nil }

      let liveHero = makeNavigationHeroController(
        hero,
        detailProgress: style.isPush ? 0 : 1)
      outgoingContent = liveHero.view
      heroController = liveHero
      // Push only. Returning, the veil would have to clear before the sharp
      // list it is covering *is* the destination — the same blink, backwards.
      // The card flies home over a list that was never softened.
      if style.isPush {
        backgroundEffect = makeCardMorphBackgroundEffect()
      }
      morphStartFrame = sourceFrame
      morphTargetFrame = landingFrame
      claimedOrigin = entry.origin
      claimedLanding = landing
      timelineDriver = makeTransitionTimelineDriver()
      anchorRegistry?.discardCapturedVisual(for: entry.origin)
    case .workspacePresent:
      if let captured = anchorRegistry?.takeCapturedVisual(for: entry.origin) {
        outgoingContent = captured.view
        outgoingContent?.frame =
          frameInContainer(fromWindowFrame: captured.frame) ?? sourceFrame
      } else {
        outgoingContent = snapshotFromWindow(at: sourceFrame)
        outgoingContent?.frame = sourceFrame
      }
      shell = makeIdentityTransitionShell(frame: sourceFrame)
      // The avatar stays put and crossfades into whatever the arriving page
      // puts in that slot. It used to fly onto a landing seat on the Settings
      // profile row; that flight is gone — see `DashNavigationSemanticID`.
      arrivingContent = snapshotRegion(
        from: target,
        at: sourceFrame,
        afterScreenUpdates: true)
      arrivingContent?.alpha = 0
      // The source is captured as a SQUARE window snapshot that carries the
      // canvas behind it, so the crossfade drew it raw over the arriving page
      // — a warm square with hard corners around a round control. The shell
      // already commits to the source's circle; its content has to agree.
      configureMorphFlightLayer(outgoingContent, departingFrom: sourceFrame)
      configureMorphFlightLayer(arrivingContent, departingFrom: sourceFrame)
      claimedOrigin = entry.origin
    case .workspaceDismiss:
      // The mirror of present: an in-place crossfade in the header slot, no
      // flight home.
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
      // Same reason as present: square snapshots of a round control must wear
      // the shell's circle.
      configureMorphFlightLayer(outgoingContent, departingFrom: sourceFrame)
      configureMorphFlightLayer(arrivingContent, departingFrom: sourceFrame)
      claimedOrigin = entry.origin
    case .flowPush, .flowPop:
      return nil
    }

    guard shell != nil || outgoingContent != nil || arrivingContent != nil else {
      return nil
    }
    // Between the pages, not in the proxy overlay above them: the veil has to
    // be something the arriving page can cover, or it can only leave by fading
    // in full view. Every teardown path removes it from its own superview.
    if let backgroundEffect {
      view.insertSubview(backgroundEffect, belowSubview: target)
    }
    if let shell { overlay.addSubview(shell) }
    if let outgoingContent {
      if heroController == nil {
        configureTransitionSnapshot(outgoingContent)
      } else {
        configureNavigationHeroLayer(outgoingContent)
      }
      overlay.addSubview(outgoingContent)
    }
    if let arrivingContent {
      if heroController == nil {
        configureTransitionSnapshot(arrivingContent)
      } else {
        configureNavigationHeroLayer(arrivingContent)
      }
      overlay.addSubview(arrivingContent)
    }
    if let timelineDriver { overlay.addSubview(timelineDriver) }
    view.addSubview(overlay)
    anchorRegistry?.claim(claimedOrigin)
    anchorRegistry?.claim(claimedLanding)
    return TransitionProxy(
      overlay: overlay,
      shell: shell,
      backgroundEffect: backgroundEffect,
      outgoingContent: outgoingContent,
      arrivingContent: arrivingContent,
      heroController: heroController,
      timelineDriver: timelineDriver,
      claimedOrigin: claimedOrigin,
      claimedLanding: claimedLanding,
      morphTargetFrame: morphTargetFrame,
      morphStartFrame: morphStartFrame)
  }

  /// A flight layer travels over both moving pages, so its baked-in corner
  /// pixels no longer match what is behind it; clipping every layer to the
  /// avatar's own circle keeps the trip clean end to end.
  private func configureMorphFlightLayer(
    _ layerView: UIView?,
    departingFrom frame: CGRect
  ) {
    guard let layerView else { return }
    layerView.frame = frame
    layerView.layer.cornerRadius = min(frame.width, frame.height) / 2
    layerView.layer.masksToBounds = true
  }

  private func makeNavigationHeroController(
    _ hero: DashNavigationHero,
    detailProgress: CGFloat
  ) -> UIHostingController<DashNavigationHeroView> {
    let controller = UIHostingController(
      rootView: DashNavigationHeroView(
        hero: hero,
        detailProgress: detailProgress,
        locale: hostContext.locale,
        dynamicTypeSize: hostContext.dynamicTypeSize))
    controller.loadViewIfNeeded()
    controller.view.backgroundColor = .clear
    controller.view.isOpaque = false
    return controller
  }

  private func configureNavigationHeroLayer(_ hero: UIView) {
    hero.backgroundColor = .clear
    hero.isOpaque = false
    hero.isAccessibilityElement = false
    hero.accessibilityElementsHidden = true
    hero.isUserInteractionEnabled = false
    hero.clipsToBounds = false
    hero.layer.masksToBounds = false
  }

  private func makeCardMorphBackgroundEffect() -> UIView {
    let background: UIView
    if UIAccessibility.isReduceTransparencyEnabled {
      let veil = UIView()
      veil.backgroundColor = UIColor(DashTheme.canvas).resolvedColor(
        with: traitCollection
      ).withAlphaComponent(0.9)
      background = veil
    } else {
      let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
      blur.backgroundColor = UIColor(DashTheme.canvas).resolvedColor(
        with: traitCollection
      ).withAlphaComponent(0.12)
      background = blur
    }
    background.frame = view.bounds
    background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    background.alpha = 0
    background.isUserInteractionEnabled = false
    background.isAccessibilityElement = false
    background.accessibilityElementsHidden = true
    return background
  }

  /// The landing seat the entry's destination publishes, if any. Resolved per
  /// transition because every page instance registers its own occurrence.
  private func landingOrigin(for entry: DashNavigationEntry) -> DashNavigationOrigin? {
    guard let semanticID = entry.destination.dashNavigationLandingSemanticID else {
      return nil
    }
    return anchorRegistry?.landingOrigin(for: semanticID)
  }

  /// Freshly attached SwiftUI pages sometimes register their landing probe one
  /// layout pass late. One synchronous retry covers the settings avatar seat
  /// without waiting a runloop, which would let the page train start unmorphed.
  private func resolvedLandingOrigin(
    for entry: DashNavigationEntry,
    in page: UIView
  ) -> DashNavigationOrigin? {
    if let landing = landingOrigin(for: entry),
      anchorFrameInContainer(for: landing, liveOnly: true) != nil
    {
      return landing
    }
    page.setNeedsLayout()
    page.layoutIfNeeded()
    return landingOrigin(for: entry)
  }

  /// Container-space frame for a morph endpoint. Unlike `transitionFrame`, this
  /// keeps off-screen seats — the settings avatar starts above the canvas on
  /// present and leaves above it on dismiss, and the flight still needs them.
  private func anchorFrameInContainer(
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
    guard localFrame.width > 2, localFrame.height > 2 else { return nil }
    return localFrame
  }

  private func resolvedTransitionStyle(
    _ style: DashPageTransitionStyle,
    source: UIView,
    target: UIView
  ) -> DashPageTransitionStyle {
    switch style {
    case .cardPush(let entry), .cardPop(let entry):
      let isPush = style.isPush
      let landingPage = isPush ? target : source
      guard entry.origin?.hero != nil,
        let sourceFrame = transitionFrame(for: entry.origin, liveOnly: !isPush),
        let landing = resolvedLandingOrigin(for: entry, in: landingPage),
        let landingFrame = anchorFrameInContainer(for: landing, liveOnly: true),
        DashCardMorphRules.isUsableEndpoint(sourceFrame, in: view.bounds),
        DashCardMorphRules.isUsableEndpoint(landingFrame, in: view.bounds)
      else {
        // No usable pair of seats: fall back to the same handoff every other
        // drill uses rather than inventing a third language for the failure.
        return isPush ? .flowPush : .flowPop
      }
      return style
    default:
      return style
    }
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
    releaseAndRemoveAfterHandoff(transition.proxy)
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
    releaseAndRemoveAfterHandoff(transition.proxy)
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
    removeLingeringProxyOverlays()
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
    let preparation = DashDestinationCanvasRules.preparation(
      sourceShowsDestinationCanvas: sourceVisible,
      targetShowsDestinationCanvas: targetVisible)
    destinationCanvasPlate.layer.removeAllAnimations()
    destinationCanvasPlate.isHidden = preparation.isHidden
    destinationCanvasPlate.alpha = preparation.alpha
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
      DashContainmentLayout.fill(child.view, in: view.bounds)
      if let sibling, sibling.view.superview === view {
        view.insertSubview(child.view, aboveSubview: sibling.view)
      } else {
        view.bringSubviewToFront(child.view)
      }
      return
    }
    addChild(child)
    // Bounds/center remain valid while the page owns a transition transform.
    child.view.autoresizingMask = []
    DashContainmentLayout.fill(child.view, in: view.bounds)
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

  /// The card morph's only timeline: its hero is re-laid-out per frame between
  /// two live seats. Every other style settles inside the property animator —
  /// workspace routes are a plain crossfade in a fixed slot and need no link.
  private func startTransitionContentTimelineIfNeeded() {
    guard let transition = activeTransition, transition.proxy != nil else { return }
    switch transition.style {
    case .cardPush, .cardPop:
      break
    case .workspacePresent, .workspaceDismiss, .flowPush, .flowPop:
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
    let progress: CGFloat
    if transition.proxy?.isCardMorph == true,
      let driver = transition.proxy?.timelineDriver,
      let presentation = driver.layer.presentation()
    {
      // Deliberately unclamped: the enter spring's overshoot past 1 IS the
      // bounce, and only the hero frame consumes it — every opacity curve
      // clamps internally.
      progress = presentation.position.x / DashCardMorphRules.timelineTravel
    } else {
      progress = CGFloat(transition.animator.fractionComplete)
    }
    updateTransitionContentTimeline(transition, progress: progress)
  }

  private func updateTransitionContentTimeline(
    _ transition: ActiveTransition,
    progress rawProgress: CGFloat
  ) {
    guard let proxy = transition.proxy else { return }
    let progress = min(max(rawProgress, 0), 1)
    UIView.performWithoutAnimation {
      switch transition.style {
      case .cardPush, .cardPop:
        // Push keeps the raw value so the enter spring's overshoot reaches the
        // hero frame. Pop is critically damped and reads the clamped copy —
        // a collapse must never extrapolate ahead of the seat it returns to.
        let detailProgress =
          transition.style.isPush ? max(rawProgress, 0) : 1 - progress
        if transition.style.isPush {
          transition.source.view.alpha = 1
          transition.target.view.alpha =
            DashCardMorphRules.detailPageOpacity(at: detailProgress)
        } else {
          transition.source.view.alpha =
            DashCardMorphRules.departingDetailPageOpacity(at: detailProgress)
          transition.target.view.alpha = 1
        }
        proxy.backgroundEffect?.alpha =
          DashCardMorphRules.backdropOpacity(at: detailProgress)
        updateCardHeroContent(proxy, detailProgress: detailProgress)
        proxy.outgoingContent?.alpha = 1
        // SwiftUI can finish propagating the destination's safe-area inset one
        // layout pass after the controller is attached. Track both concrete
        // seats while they are live instead of freezing that provisional first
        // frame and jumping when the proxy hands back to the real card.
        if let sourceFrame = transitionFrame(
          for: proxy.claimedOrigin,
          liveOnly: true) ?? proxy.morphStartFrame,
          let landingFrame = anchorFrameInContainer(
            for: proxy.claimedLanding,
            liveOnly: true) ?? proxy.morphTargetFrame
        {
          applyCardHeroFrame(
            proxy,
            at: DashCardMorphRules.heroFrame(
              from: sourceFrame,
              to: landingFrame,
              detailProgress: detailProgress))
        }
      case .workspacePresent, .workspaceDismiss, .flowPush, .flowPop:
        break
      }
    }
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
    anchorRegistry?.release(proxy.claimedLanding)
    proxy.backgroundEffect?.removeFromSuperview()
    proxy.overlay.removeFromSuperview()
  }

  /// Completion variant for landed morph flights. Claims are released now so
  /// the live element re-renders beneath the pixel-matching proxy, but the
  /// overlay leaves only after that reveal has had a SwiftUI commit — the
  /// header avatar additionally waits on the asynchronous presentation-state
  /// publish. Removing it in the same runloop blinks the element the eye just
  /// tracked to its seat.
  private func releaseAndRemoveAfterHandoff(_ proxy: TransitionProxy?) {
    guard let proxy else { return }
    guard proxy.morphTargetFrame != nil else {
      releaseAndRemove(proxy)
      return
    }
    anchorRegistry?.release(proxy.claimedOrigin)
    anchorRegistry?.release(proxy.claimedLanding)
    proxy.backgroundEffect?.removeFromSuperview()
    lingeringProxies.append(proxy)
    let handoffDelay: Int64 = proxy.isCardMorph ? 100 : 140
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(handoffDelay))
      proxy.overlay.removeFromSuperview()
      self?.lingeringProxies.removeAll { $0 === proxy }
    }
  }

  private func removeLingeringProxyOverlays() {
    guard !lingeringProxies.isEmpty else { return }
    for proxy in lingeringProxies {
      proxy.backgroundEffect?.removeFromSuperview()
      proxy.overlay.removeFromSuperview()
    }
    lingeringProxies.removeAll()
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
    /// The longest timeline (the incoming settle); it owns the completion.
    let animator: UIViewPropertyAnimator
    /// Shorter concurrent timelines (fades, outgoing glide). They always end
    /// before `animator` does naturally; a forced finish jumps them first.
    let auxiliaryAnimators: [UIViewPropertyAnimator]
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
      auxiliaryAnimators: [UIViewPropertyAnimator],
      sourceTab: AppTab,
      targetTab: AppTab,
      generation: UInt64,
      source: UIViewController,
      target: UIViewController,
      appearanceWasBegun: Bool,
      onCompleted: @escaping (AppTab, AppTab, UInt64) -> Void
    ) {
      self.animator = animator
      self.auxiliaryAnimators = auxiliaryAnimators
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
      DashContainmentLayout.fill(child.view, in: view.bounds)
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

    let transition: ActiveTransition
    if reduceMotion {
      // Stationary complementary crossfade; `travel` is already zero here.
      let animator = UIViewPropertyAnimator(
        duration: DashTheme.Motion.Page.reducedDuration,
        timingParameters: UICubicTimingParameters(animationCurve: .easeOut))
      animator.addAnimations {
        source.view.alpha = 0
        source.view.transform = .identity
        target.view.alpha = 1
        target.view.transform = .identity
      }
      transition = ActiveTransition(
        animator: animator,
        auxiliaryAnimators: [],
        sourceTab: sourceTab,
        targetTab: targetTab,
        generation: generation,
        source: source,
        target: target,
        appearanceWasBegun: appearanceWasBegun,
        onCompleted: onCompleted)
    } else {
      // The outgoing page clears first: a front-loaded fade over a constant-
      // speed glide that is still travelling when its opacity reaches zero.
      let outgoingFade = UIViewPropertyAnimator(
        duration: DashTheme.Motion.tabStepOutgoingFadeDuration,
        timingParameters: UICubicTimingParameters(
          controlPoint1: DashTheme.Motion.tabStepOutgoingFadeControlPoint1,
          controlPoint2: DashTheme.Motion.tabStepOutgoingFadeControlPoint2))
      outgoingFade.addAnimations {
        source.view.alpha = 0
      }
      let outgoingSlide = UIViewPropertyAnimator(
        duration: DashTheme.Motion.tabStepOutgoingSlideDuration,
        timingParameters: UICubicTimingParameters(animationCurve: .linear))
      outgoingSlide.addAnimations {
        source.view.transform = CGAffineTransform(translationX: -travel, y: 0)
      }
      // The incoming page lands just after it: the S-curve's slow first frames
      // are the lag that keeps both opacities near 30% at the crossover.
      let incomingFade = UIViewPropertyAnimator(
        duration: DashTheme.Motion.tabStepIncomingFadeDuration,
        timingParameters: UICubicTimingParameters(animationCurve: .easeInOut))
      incomingFade.addAnimations {
        target.view.alpha = 1
      }
      // Soft spring settle; the fade is complete well before the ~1pt
      // overshoot, so only fully opaque content ever bounces. Longest
      // timeline, so it owns the completion.
      let settle = UIViewPropertyAnimator(
        duration: DashTheme.Motion.tabStepSettleDuration,
        timingParameters: UISpringTimingParameters(
          dampingRatio: DashTheme.Motion.tabStepSettleDampingRatio,
          initialVelocity: .zero))
      settle.addAnimations {
        target.view.transform = .identity
      }
      transition = ActiveTransition(
        animator: settle,
        auxiliaryAnimators: [outgoingFade, outgoingSlide, incomingFade],
        sourceTab: sourceTab,
        targetTab: targetTab,
        generation: generation,
        source: source,
        target: target,
        appearanceWasBegun: appearanceWasBegun,
        onCompleted: onCompleted)
    }
    activeTransition = transition
    transition.animator.addCompletion { [weak self, weak transition] _ in
      guard let self, let transition else { return }
      self.complete(transition)
    }
    for animator in transition.auxiliaryAnimators {
      animator.startAnimation()
    }
    transition.animator.startAnimation()
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
    // Auxiliary timelines may already have run out naturally; only a still-
    // active one can be stopped and jumped to its end values.
    for animator in transition.auxiliaryAnimators where animator.state == .active {
      animator.stopAnimation(false)
      if animator.state == .stopped {
        animator.finishAnimation(at: .end)
      }
    }
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
      DashContainmentLayout.fill(child.view, in: view.bounds)
      if let sibling, sibling.view.superview === view {
        view.insertSubview(child.view, aboveSubview: sibling.view)
      } else {
        view.bringSubviewToFront(child.view)
      }
      return
    }
    addChild(child)
    // Bounds/center keep the tab handoff translation defined during layout.
    child.view.autoresizingMask = []
    DashContainmentLayout.fill(child.view, in: view.bounds)
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
      case .feature(let feature):
        FeatureRouterContent(feature: feature)
      case .zone(let id): ZoneDetailView(zoneID: id)
      case .dns(let id): DNSRecordsView(zoneID: id)
      case .cache(let id): ZoneCacheView(zoneID: id)
      case .zoneAnalytics(let id): ZoneAnalyticsView(zoneID: id)
      case .zoneWebAnalytics(let id): WebAnalyticsView(zoneID: id)
      case .zoneWAF(let id): WAFEventsView(zoneID: id)
      case .zoneSettings(let id): ZoneSettingsView(zoneID: id)
      case .zoneEmailRouting(let id): EmailRoutingView(zoneID: id)
      case .auditLogs: AuditLogView()
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
/// `Hashable` because the shared header keys the glyph's morph on it: the icon
/// and the title change as two independent parts, not one block.
enum DetailIcon: Hashable {
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

struct DashPageHeaderDescriptor: Equatable {
  let icon: DetailIcon
  let title: String
  let tint: Color
}

struct DashPageActionDescriptor: Identifiable {
  enum Label: Equatable {
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

/// Equality ignores action closures: chrome identity is id / label / enabled
/// state, matching `DashPageEscapeActionPreference`.
extension DashPageActionDescriptor: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
      && lhs.label == rhs.label
      && lhs.isEnabled == rhs.isEnabled
      && lhs.disabledOpacity == rhs.disabledOpacity
      && lhs.accessibilityIdentifier == rhs.accessibilityIdentifier
  }
}

struct DashPageChromePreference: Equatable {
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

/// Who paints a page's header slots.
enum DashPageChromeHosting: Hashable {
  /// The page draws its own bar — previews and UI-test harnesses that host a
  /// stack outside `MainTabView`.
  case page
  /// The page only publishes; the ONE workspace header draws the slots.
  case workspace
}

/// The one channel page chrome travels out of a page on.
///
/// SwiftUI preferences do not cross a `UIHostingController`, and every route is
/// its own hosting controller, so the shared header cannot read a page's
/// `detailHeader` / `dashPageActions` the way a page-local bar could. Each page
/// publishes its resolved descriptor here under its entry id instead.
///
/// Like `DashHeaderScrollState` and `DashWorkspaceWashScroll`, this store has
/// exactly ONE reader — `DashWorkspaceHeaderBar`. Nothing in `MainTabView`'s
/// body may read it: a trailing-action change (an R2 selection, a Save becoming
/// enabled) would otherwise refresh every cached page host mid-transition.
@MainActor
@Observable
final class DashPageChromeStore {
  private(set) var pages: [DashNavigationEntry.ID: DashPageChromePreference] = [:]

  func publish(_ chrome: DashPageChromePreference, for id: DashNavigationEntry.ID) {
    guard pages[id] != chrome else { return }
    pages[id] = chrome
  }

  func prune(keeping ids: Set<DashNavigationEntry.ID>) {
    guard !pages.isEmpty else { return }
    pages = pages.filter { ids.contains($0.key) }
  }

  func chrome(for id: DashNavigationEntry.ID?) -> DashPageChromePreference? {
    guard let id else { return nil }
    return pages[id]
  }
}

struct DashPageActionControl: View {
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

struct DashPageActionGroupView: View {
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
  /// Same gutter as catalog / feature scrolls (`DashTheme.Spacing.screen`) so
  /// the floated Back / avatar / inbox line up with the content column — not
  /// the tighter top chrome inset, which only owns the status-bar gap.
  static let horizontalInset = DashTheme.Spacing.screen
  static let reservedHeight = controlSize + topInset
  static let actionSpacing: CGFloat = 8
  static let maximumPrincipalWidth: CGFloat = 160
}

enum DashPageChromeAssetRules {
  static func leadingAsset(
    for dismissal: DashNavigationDismissal,
    rightToLeft: Bool
  ) -> String {
    switch dismissal {
    case .back:
      rightToLeft ? SolarAsset.chevronRight : SolarAsset.chevronLeft
    case .closeToWorkspaceRoot:
      // Page chrome uses the finer 2pt mark; the heavier close glyph is tray-only.
      SolarAsset.editClose
    }
  }
}

/// The opaque destination plate must already cover the workspace wash before
/// a root push exposes its first attached page frame.
enum DashDestinationCanvasRules {
  struct Preparation: Equatable {
    let isHidden: Bool
    let alpha: CGFloat
  }

  static func preparation(
    sourceShowsDestinationCanvas: Bool,
    targetShowsDestinationCanvas: Bool
  ) -> Preparation {
    let shows = sourceShowsDestinationCanvas || targetShowsDestinationCanvas
    return Preparation(isHidden: !shows, alpha: shows ? 1 : 0)
  }
}

/// The centred identity of a page bar — glyph plus inline title. Shared so the
/// page-local fallback bar and the workspace header cannot drift apart in
/// glyph size, spacing, truncation, or the identifier UI tests query.
///
/// The title deliberately does NOT animate its own change. It briefly did — a
/// keyed glyph morph beside a `contentTransition` text dissolve — and the
/// animated blur ran per-frame main-thread work in the same window where the
/// page compositor's display link is already re-laying-out a live hero, which
/// dropped frames. A title change now lands whole; the header's seats keep
/// their animations, which are render-server work, not per-frame CPU.
struct DashPageChromeTitleView: View {
  let header: DashPageHeaderDescriptor

  var body: some View {
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
        DashPageChromeTitleView(header: header)
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
          asset: DashPageChromeAssetRules.leadingAsset(
            for: .back,
            rightToLeft: layoutDirection == .rightToLeft),
          accessibilityLabel: DashL10n.string("Back"),
          action: dismiss
        )
        .accessibilityIdentifier("dash.navigation.back")
      case .closeToWorkspaceRoot:
        DashToolbarIconButton(
          asset: DashPageChromeAssetRules.leadingAsset(
            for: .closeToWorkspaceRoot,
            rightToLeft: layoutDirection == .rightToLeft),
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
  @State private var pageChrome = DashPageChromePreference()
  @State private var preferredEscapeAction: DashPageEscapeActionPreference?

  var body: some View {
    Group {
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(allowsBodyInteraction)
        .accessibilityHidden(!allowsBodyInteraction)
    }
    // Frost sits on the content, under the inset chrome — same z-order as under
    // UINavigationBar. The inset expands safeAreaInsets.top so content and
    // landing anchors share the physical screen's safe coordinate space.
    .overlayPreferenceValue(DashHeaderScrimHandledKey.self) { handled in
      if !handled {
        DashHeaderScrim(scroll: scroll)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .allowsHitTesting(false)
      }
    }
    .backgroundPreferenceValue(DashHeaderScrimHandledKey.self) { handled in
      if !handled {
        DashHeaderScrollProbe(scroll: scroll, wash: washScroll)
        DashScreenClipLift()
      }
    }
    .onPreferenceChange(DashPageChromePreferenceKey.self) { [$pageChrome] chrome in
      $pageChrome.wrappedValue = chrome
    }
    // The slots leave the page here — and deliberately NOT with `initial:
    // true`. The first body evaluation runs before the page's preferences have
    // propagated, so an initial publish speaks with the DEFAULT-EMPTY voice:
    // it blanks the shared title slot on the very frame the push lands, the
    // header's holdover never sees a "has not spoken" window, and every title
    // change degrades from a content morph into remove → gap → insert. The
    // store only ever hears chrome the page actually resolved; until then the
    // header holds the previous page's title.
    .onChange(of: pageChrome) { _, chrome in
      publishChrome(chrome)
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      routeChromeInset
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

  /// Fixed-height top chrome so roots and destinations share one safe-area
  /// reservation. The reservation is the invariant and never moves; only the
  /// painting does. Under `.workspace` hosting the slot stays clear on every
  /// page, because the ONE header above the pager draws it.
  ///
  /// The constant height is also what keeps this host acyclic. The chrome
  /// preference is read OUT of the content and this inset is fed BACK IN as a
  /// top safe area — a closed loop by construction. It stays shut only because
  /// the inset's height is a compile-time constant: measure it from the bar's
  /// own content and a taller title would grow the inset, which re-lays-out
  /// the content that published the title. `check-ios-ui-architecture` asserts
  /// the constant for exactly this reason.
  @ViewBuilder private var routeChromeInset: some View {
    Group {
      if let entry, chromeHosting == .page {
        DashPageNavigationBar(
          entry: entry,
          chrome: pageChrome,
          allowsBusinessActions: allowsBodyInteraction,
          dismiss: { navigator?.dismiss(entryID: entry.id) }
        )
      } else {
        Color.clear
      }
    }
    .frame(height: DashPageChromeMetrics.reservedHeight)
    .frame(maxWidth: .infinity, alignment: .top)
  }

  /// A stored `let` on the navigator, so reading it registers no observation.
  private var chromeHosting: DashPageChromeHosting {
    navigator?.chromeHosting ?? .page
  }

  /// Published, never withdrawn on disappear: the page container detaches a
  /// covered page's view, and a page that came back would have no second
  /// `initial` change to republish from — it would return under a titleless
  /// bar. `DestinationNavigator` prunes the store when the entry itself goes.
  private func publishChrome(_ chrome: DashPageChromePreference) {
    guard chromeHosting == .workspace, let entry else { return }
    navigator?.pageChrome.publish(chrome, for: entry.id)
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
  var hero: DashNavigationHero? = nil
  var onNavigate: (() -> Void)?
  /// Optional lifecycle boundary (for example a Tray's `dismissAfter`). The
  /// source geometry is captured on the tap, before the presenting surface
  /// unmounts; only the route mutation waits for the boundary to finish.
  var schedule: ((@escaping () -> Void) -> Void)?
  /// When true, the source anchor is published through the environment so an
  /// inner view (the header avatar circle) can register it. The outer wrapper
  /// stays unanchored — otherwise the morph would capture glass chrome.
  var embedsAnchor: Bool = false
  @ViewBuilder var content: (@escaping () -> Void) -> Content

  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.dashNavigationAnchorRegistry) private var anchorRegistry
  @Environment(\.dashNavigationEntryID) private var sourceEntryID
  @State private var anchorInstanceID = UUID()

  var body: some View {
    if embedsAnchor {
      content(navigate)
        .environment(\.dashNavigationEmbeddedAnchorID, anchorInstanceID)
    } else {
      content(navigate)
        .dashNavigationAnchor(instanceID: anchorInstanceID)
    }
  }

  private func navigate() {
    let origin = anchorRegistry?.captureOrigin(
      semanticID: destination.dashNavigationSemanticID,
      anchorInstanceID: anchorInstanceID,
      hero: hero)
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
  var hero: DashNavigationHero? = nil
  var onNavigate: (() -> Void)?
  @ViewBuilder var label: () -> Label

  var body: some View {
    DashNavigationSource(
      destination: destination,
      hero: hero,
      onNavigate: onNavigate
    ) { navigate in
      Button(action: navigate) {
        label()
      }
      // A navigation row is a surface, not a button — it must not shrink on press.
      .buttonStyle(DashSurfaceButtonStyle())
    }
  }
}
