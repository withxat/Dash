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
    zoneID: String,
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
  /// What each live occurrence currently SHOWS. Instance UUIDs follow SwiftUI
  /// structural identity — a positional list slot keeps its UUID across a
  /// re-sort while its resource changes — so a return morph verifies meaning
  /// here instead of trusting that a live frame still belongs to its resource.
  private var sourceSemanticIDs: [UUID: DashNavigationSemanticID] = [:]
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

  func registerSourceView(
    _ view: UIView,
    semanticID: DashNavigationSemanticID? = nil,
    for instanceID: UUID
  ) {
    sourceViews[instanceID] = WeakSourceView(view)
    sourceSemanticIDs[instanceID] = semanticID
  }

  func unregisterSourceView(_ view: UIView, for instanceID: UUID) {
    guard sourceViews[instanceID]?.value === view else { return }
    sourceViews[instanceID] = nil
    sourceSemanticIDs[instanceID] = nil
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

  /// The live occurrence a return flight should land on. A covered list can
  /// re-sort while a detail is up (pinning a domain from its own screen), and
  /// instance UUIDs ride SwiftUI structural identity — a positional slot keeps
  /// its UUID while its resource changes — so the captured instance can be
  /// perfectly live yet mean a different card now. The registered semantic is
  /// verified first; a moved resource is followed to the ONE occurrence inside
  /// `container` that shows it today (scoping keeps a Home row for the same
  /// zone from pulling the flight across pages). A missing occurrence and an
  /// ambiguous one both return nil — the caller falls back to flow rather than
  /// guessing which card to fly into.
  func currentSourceOrigin(
    for origin: DashNavigationOrigin,
    within container: UIView
  ) -> DashNavigationOrigin? {
    let registered = sourceSemanticIDs[origin.anchorInstanceID]
    if isLiveSource(origin.anchorInstanceID, within: container),
      registered == nil || registered == origin.semanticID
    {
      return origin
    }
    let relocated =
      sourceSemanticIDs
      .filter { $0.value == origin.semanticID && $0.key != origin.anchorInstanceID }
      .map(\.key)
      .filter { isLiveSource($0, within: container) }
    guard relocated.count == 1, let instanceID = relocated.first else { return nil }
    return DashNavigationOrigin(
      semanticID: origin.semanticID,
      anchorInstanceID: instanceID,
      hero: origin.hero)
  }

  private func isLiveSource(_ instanceID: UUID, within container: UIView) -> Bool {
    guard let source = sourceViews[instanceID]?.value, source.window != nil else {
      return false
    }
    return source.isDescendant(of: container)
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
  /// `semanticID` states what the occurrence currently SHOWS — a positional
  /// list slot keeps its instance UUID across a re-sort while its resource
  /// changes, and a return morph must be able to notice that the meaning moved.
  func dashNavigationAnchor(
    instanceID: UUID,
    semanticID: DashNavigationSemanticID? = nil,
    landing: DashNavigationSemanticID? = nil
  ) -> some View {
    modifier(
      DashNavigationAnchorModifier(
        instanceID: instanceID, semanticID: semanticID, landing: landing))
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
  var semanticID: DashNavigationSemanticID?
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
                semanticID: semanticID,
                landing: landing,
                registry: registry)
            }
        }
      }
  }
}

private struct DashNavigationAnchorProbe: UIViewRepresentable {
  let instanceID: UUID
  var semanticID: DashNavigationSemanticID?
  var landing: DashNavigationSemanticID?
  let registry: DashNavigationAnchorRegistry?

  func makeUIView(context: Context) -> DashNavigationAnchorProbeView {
    let view = DashNavigationAnchorProbeView()
    view.configure(
      instanceID: instanceID, semanticID: semanticID, landing: landing,
      registry: registry)
    return view
  }

  func updateUIView(_ uiView: DashNavigationAnchorProbeView, context: Context) {
    uiView.configure(
      instanceID: instanceID, semanticID: semanticID, landing: landing,
      registry: registry)
  }

  static func dismantleUIView(_ uiView: DashNavigationAnchorProbeView, coordinator: ()) {
    uiView.tearDown()
  }
}

private final class DashNavigationAnchorProbeView: UIView {
  private var instanceID: UUID?
  private var semanticID: DashNavigationSemanticID?
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
    semanticID: DashNavigationSemanticID?,
    landing: DashNavigationSemanticID?,
    registry: DashNavigationAnchorRegistry?
  ) {
    if self.instanceID != instanceID || self.semanticID != semanticID
      || self.landing != landing || self.registry !== registry
    {
      tearDown()
      self.instanceID = instanceID
      self.semanticID = semanticID
      self.landing = landing
      self.registry = registry
    }
    // Probe registration runs inside UIKit layout, so a landing seat is
    // resolvable synchronously after the arriving page's first layoutIfNeeded —
    // before its transition builds a proxy. The same pass re-registers a slot
    // whose resource changed under it, which is what keeps the semantic map
    // truthful across a covered list's re-sort.
    registry?.registerSourceView(self, semanticID: semanticID, for: instanceID)
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
    semanticID = nil
    landing = nil
    registry = nil
  }
}
