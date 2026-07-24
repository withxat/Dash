import CloudflareAPI
import GradientAvatars
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.destinationNavigator) private var navigator
  @AppStorage(RecentResources.key) private var recentsRaw = ""
  @AppStorage(HomeShortcuts.key) private var shortcutsRaw = HomeShortcuts.defaultValue
  @AppStorage(HomeActions.key) private var actionsRaw = HomeActions.defaultValue
  @State private var zones: [CloudflareZone] = []
  @State private var zonesLoading = true
  @State private var zonesError: String?
  @State private var showsAddDomain = false
  @State private var showsR2Upload = false
  @State private var showsPurgeCache = false
  @State private var showsAddDNSRecord = false
  @State private var showsCreateKVKey = false
  @State private var showsCreateR2Bucket = false
  @State private var showsAddPagesDomain = false
  @State private var showsAddWorkerDomain = false
  @State private var showsEnableDevelopmentMode = false
  @State private var showsEnableUnderAttackMode = false
  @State private var showsEditActions = false
  @State private var showsEditShortcuts = false
  /// Scroll probes for `HomeTopWash`. Held in an `@Observable` store this
  /// body never reads — per-frame writes must not re-render the whole Home
  /// (or cancel an in-flight push). Only `HomeTopWash` observes the values.
  @State private var washProbes = HomeWashProbes()

  private var recents: [RecentResource] {
    guard let accountID = model.activeAccountID else { return [] }
    return RecentResources.visible(in: recentsRaw, accountID: accountID)
  }

  private var shortcuts: [FeatureID] {
    HomeShortcuts.decode(shortcutsRaw)
  }

  private var quickActions: [HomeActionID] {
    HomeActions.decode(actionsRaw)
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        if model.identityStale {
          DashNotice(
            kind: .warning,
            message:
              "Can't reach Cloudflare — showing data from this session. Reconnect to refresh."
          )
          .dashSectionReveal()
        }

        HomeGreetingHeader()
          .dashSectionReveal(0)

        HomeQuickActionsSection(
          actions: quickActions,
          perform: perform,
          edit: { showsEditActions = true }
        )
        .dashSectionReveal(1)

        HomeDomainsSection(
          zones: zones,
          isLoading: zonesLoading,
          error: zonesError,
          locked: isLocked(.zones),
          showsAddDomain: $showsAddDomain,
          retry: { Task { await loadZones(force: true) } }
        )
        .dashSectionReveal(2)

        HomeShortcutsSection(features: shortcuts) {
          showsEditShortcuts = true
        }
        .dashSectionReveal(3)

        if !recents.isEmpty {
          HomeRecentsSection(recents: recents) { resource in
            recentsRaw = RecentResources.recording(resource, in: recentsRaw)
          }
          .dashSectionReveal(4)
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, DashTheme.Spacing.section)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
      // Probe, not paint: publishes the content's live top edge. The wash
      // itself cannot ride here — the scroll clips at its top bound, so a
      // content background can never reach the band or the status bar.
      .background {
        GeometryReader { probe in
          Color.clear.preference(
            key: HomeContentTopPreferenceKey.self,
            value: probe.frame(in: .global).minY
          )
        }
      }
    }
    .modifier(DashScrollEdgeEffectsHidden())
    .refreshable { await loadZones(force: true) }
    .dashSectionEntrance()
    // Canvas + wash live on this NavigationStack root so they slide away with
    // a system push. Scroll chrome stays clear so the glow shows through the
    // greeting; opaque cards (`homeCardSurface`) keep a true fill on top.
    .dashCatalogScreen(
      background: {
        ZStack {
          DashTheme.canvas.ignoresSafeArea()
          HomeTopWash(probes: washProbes)
        }
        // Expand the plate under the status bar so the wash is in-bounds
        // (page cells clip drawing outside their frame).
        .ignoresSafeArea(edges: .top)
      },
      scrollFill: .clear,
      topBand: {
        // Rest-position probe: the zero-height hook sits exactly where the
        // content's top edge rests below the nav bar when the scroll settles.
        GeometryReader { probe in
          Color.clear.preference(
            key: HomeBandBottomPreferenceKey.self,
            value: probe.frame(in: .global).maxY
          )
        }
      }
    )
    // SwiftUI's internal hosting wrappers can shear the wash at the status bar.
    // Lift only inside Home's content VC; leave navigation-transition
    // containers outside Home untouched.
    .background { HomeWashClipLift() }
    .onPreferenceChange(HomeContentTopPreferenceKey.self) { [washProbes] value in
      MainActor.assumeIsolated { washProbes.contentTopY = value }
    }
    .onPreferenceChange(HomeBandBottomPreferenceKey.self) { [washProbes] value in
      MainActor.assumeIsolated { washProbes.bandBottomY = value }
    }
    .task(id: model.activeAccountID) { await loadZones() }
    .dashTray(isPresented: $showsAddDomain, title: DashL10n.string("Add domain")) {
      AddDomainSheet {
        guard let accountID = model.activeAccountID else { return }
        model.featureCache.remove(FeatureCacheKey.zones(accountID))
        Task { await loadZones(force: true) }
      }
    }
    .dashTray(isPresented: $showsR2Upload, title: DashL10n.string("Upload to R2")) {
      HomeR2UploadSheet { bucket in
        guard let accountID = model.activeAccountID else { return }
        recentsRaw = RecentResources.recording(
          RecentResource(
            accountID: accountID, kind: .r2Bucket, resourceID: bucket, title: bucket),
          in: recentsRaw)
      }
    }
    .dashTray(isPresented: $showsPurgeCache, title: DashL10n.string("Purge cache")) {
      HomePurgeCachePicker(zones: zones) { zone in
        navigator?.push(.cache(zone.id))
      }
    }
    .dashTray(isPresented: $showsAddDNSRecord, title: DashL10n.string("Add DNS record")) {
      HomeDNSRecordAction(zones: zones)
    }
    .dashTray(isPresented: $showsCreateKVKey, title: DashL10n.string("Create KV key")) {
      HomeCreateKVKeyAction()
    }
    .dashTray(isPresented: $showsCreateR2Bucket, title: DashL10n.string("Create R2 bucket")) {
      R2CreateBucketSheet(onCreated: {})
    }
    .dashTray(isPresented: $showsAddPagesDomain, title: DashL10n.string("Add Pages domain")) {
      HomePagesDomainAction()
    }
    .dashTray(isPresented: $showsAddWorkerDomain, title: DashL10n.string("Attach Worker domain")) {
      HomeWorkerDomainAction()
    }
    .dashTray(
      isPresented: $showsEnableDevelopmentMode, title: DashL10n.string("Development mode")
    ) {
      HomeZoneModeAction(zones: zones, mode: .development)
    }
    .dashTray(
      isPresented: $showsEnableUnderAttackMode, title: DashL10n.string("Under Attack mode")
    ) {
      HomeZoneModeAction(zones: zones, mode: .underAttack)
    }
    .dashTray(
      isPresented: $showsEditActions, title: DashL10n.string("Edit quick actions"), sizing: .large
    ) {
      EditHomeActionsView(selectionRaw: $actionsRaw)
    }
    .dashTray(isPresented: $showsEditShortcuts, title: DashL10n.string("Edit shortcuts")) {
      EditShortcutsView(selectionRaw: $shortcutsRaw)
    }
  }

  private func perform(_ action: HomeActionID) {
    switch action {
    case .addDomain:
      let scopes = FeatureID.zones.capability.all
      guard model.hasScopes(scopes) else {
        model.requestAccess(to: scopes)
        return
      }
      showsAddDomain = true
    case .uploadR2:
      beginR2Upload()
    case .addDNSRecord:
      let scopes: Set<String> = ["zone.read", "dns.read", "dns.write"]
      guard model.hasScopes(scopes) else {
        model.requestAccess(to: scopes)
        return
      }
      showsAddDNSRecord = true
    case .createKVKey:
      let scopes = FeatureID.kv.capability.all
      guard model.hasScopes(scopes) else {
        model.requestAccess(to: scopes)
        return
      }
      showsCreateKVKey = true
    case .createR2Bucket:
      let scopes = FeatureID.r2.capability.all
      guard model.hasScopes(scopes) else {
        model.requestAccess(to: scopes)
        return
      }
      showsCreateR2Bucket = true
    case .addPagesDomain:
      let scopes = FeatureID.pages.capability.all
      guard model.hasScopes(scopes) else {
        model.requestAccess(to: scopes)
        return
      }
      showsAddPagesDomain = true
    case .addWorkerDomain:
      let scopes = FeatureID.workers.capability.all.union(["zone.read"])
      guard model.hasScopes(scopes) else {
        model.requestAccess(to: scopes)
        return
      }
      showsAddWorkerDomain = true
    case .enableDevelopmentMode:
      beginZoneMode(scopes: ["zone.read", "zone-settings.write"]) {
        showsEnableDevelopmentMode = true
      }
    case .enableUnderAttackMode:
      beginZoneMode(scopes: ["zone.read", "zone-settings.read", "zone-settings.write"]) {
        showsEnableUnderAttackMode = true
      }
    case .purgeCache:
      beginPurgeCache()
    }
  }

  private func beginZoneMode(scopes: Set<String>, present: () -> Void) {
    guard model.hasScopes(scopes) else {
      model.requestAccess(to: scopes)
      return
    }
    present()
  }

  private func beginR2Upload() {
    let scopes = FeatureID.r2.capability.all
    guard model.hasScopes(scopes) else {
      model.requestAccess(to: scopes)
      return
    }
    showsR2Upload = true
  }

  private func beginPurgeCache() {
    let scopes: Set<String> = ["zone.read", "cache.purge"]
    guard model.hasScopes(scopes) else {
      model.requestAccess(to: scopes)
      return
    }
    if zones.count == 1, let zone = zones.first {
      navigator?.push(.cache(zone.id))
    } else {
      showsPurgeCache = true
    }
  }

  private func isLocked(_ feature: FeatureID) -> Bool {
    feature.capability.accessLevel(grantedScopes: model.grantedScopes) == .locked
  }

  private func loadZones(force: Bool = false) async {
    guard let accountID = model.activeAccountID else {
      zones = []
      zonesLoading = false
      zonesError = nil
      return
    }
    guard !isLocked(.zones) else {
      zones = []
      zonesLoading = false
      zonesError = nil
      return
    }

    let key = FeatureCacheKey.zones(accountID)
    if !force, let cached: [CloudflareZone] = model.featureCache.get(key) {
      zones = cached
      zonesLoading = false
      zonesError = nil
      return
    }

    if zones.isEmpty { zonesLoading = true }
    zonesError = nil
    do {
      let page = try await model.client.listZones(
        accountID: accountID, page: 1, perPage: ZonesView.pageSize)
      zones = page.items
      model.featureCache.storeZones(page.items, accountID: accountID)
    } catch {
      zonesError = error.dashActionableMessage
    }
    zonesLoading = false
  }
}

/// Per-frame wash probe values for `HomeTopWash`. Owned by `HomeView` as an
/// `@Observable` store the Home body never reads — only the wash observes —
/// so scroll updates re-render just the glow, not the whole launcher.
@MainActor
@Observable
final class HomeWashProbes {
  var contentTopY: CGFloat?
  var bandBottomY: CGFloat?
}

/// Clears `clipsToBounds` only on SwiftUI wrappers inside Home's content view
/// controller so the top wash can paint into the status-bar band. The content
/// VC itself and every navigation/page transition ancestor stay clipped.
private struct HomeWashClipLift: UIViewRepresentable {
  func makeUIView(context: Context) -> HomeWashClipLiftView {
    HomeWashClipLiftView()
  }

  func updateUIView(_ uiView: HomeWashClipLiftView, context: Context) {
    uiView.scheduleLift()
  }
}

private final class HomeWashClipLiftView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    isHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { scheduleLift() }
  }

  func scheduleLift() {
    DispatchQueue.main.async { [weak self] in
      self?.applyLift()
      // SwiftUI rebuilds often re-enable clipping; one follow-up pass catches that.
      DispatchQueue.main.async { [weak self] in
        self?.applyLift()
      }
    }
  }

  private func applyLift() {
    HomeWashClipScope.lift(from: self)
  }
}

/// Testable boundary for the UIKit mutation above. The previous implementation
/// climbed to the tab pager and also unclipped the `UINavigationController`'s
/// transition views, so Home's old content layer covered an incoming feature.
@MainActor
enum HomeWashClipScope {
  static func lift(from view: UIView) {
    guard let contentRoot = enclosingContentView(from: view) else { return }

    var node = view.superview
    while let current = node, current !== contentRoot {
      current.clipsToBounds = false
      node = current.superview
    }
  }

  private static func enclosingContentView(from view: UIView) -> UIView? {
    var responder: UIResponder? = view
    while let next = responder?.next {
      if let viewController = next as? UIViewController,
        !(viewController is UINavigationController),
        !(viewController is UITabBarController),
        !(viewController is UIPageViewController),
        let root = viewController.viewIfLoaded,
        view === root || view.isDescendant(of: root)
      {
        return root
      }
      responder = next
    }
    return nil
  }
}

/// Live global Y of the Home scroll content's top edge.
struct HomeContentTopPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat? = nil
  static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
    value = nextValue() ?? value
  }
}

/// Global Y of the content's rest position: the zero-height `topBand` hook in
/// `dashCatalogScreen`, seated right below the root's nav bar.
struct HomeBandBottomPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat? = nil
  static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
    value = nextValue() ?? value
  }
}

/// Home's top light field: one continuous wash from the physical top edge —
/// status bar included — falling off sideways and down into the canvas.
/// Painted on the Home root background (under scroll content) so opaque cards
/// keep a true fill and a system push slides the glow away with Home.
/// Translates by the live scroll displacement; rubber-band pull is clamped so
/// the field stays pinned while content stretches down.
struct HomeTopWash: View {
  let probes: HomeWashProbes

  /// Current scroll displacement of the content's top edge from rest (≤ 0).
  /// Clamped at rest: a rubber-band pull stretches the content down while the
  /// pinned field stays put, so the glow keeps filling the gap.
  private var shift: CGFloat {
    guard let top = probes.contentTopY, let band = probes.bandBottomY else { return 0 }
    return min(0, top - band)
  }

  var body: some View {
    GeometryReader { proxy in
      let topInset = max(0, proxy.frame(in: .global).minY)
      ZStack {
        LinearGradient(
          stops: [
            .init(color: DashTheme.homeWash.opacity(0.34), location: 0),
            .init(color: DashTheme.homeWash.opacity(0.2), location: 0.42),
            .init(color: DashTheme.homeWash.opacity(0), location: 1),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        RadialGradient(
          colors: [DashTheme.homeWash.opacity(0.32), DashTheme.homeWash.opacity(0)],
          center: .top,
          startRadius: 0,
          endRadius: 290
        )
      }
      // Tall enough to cover status bar + greeting after any residual top inset.
      .frame(height: 300 + topInset)
      // Scroll `shift` plus a nudge to the physical top when the plate still
      // lays out below the status bar (zero when the page is already full-bleed).
      .offset(y: shift - topInset)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .ignoresSafeArea(edges: .top)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Home's greeting: a plain heading that sits in the top light wash.
struct HomeGreetingHeader: View {
  var body: some View {
    Text("What are we doing today?")
      .dashTextStyle(.trayTitle)
      .foregroundStyle(DashTheme.strong)
      .multilineTextAlignment(.center)
      .accessibilityAddTraits(.isHeader)
      .frame(maxWidth: .infinity)
      .padding(.top, DashTheme.Spacing.homeGreetingTop)
      .padding(.bottom, DashTheme.Spacing.homeGreetingBottom)
  }
}

// MARK: - Quick actions

private struct HomeQuickActionsSection: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let actions: [HomeActionID]
  let perform: (HomeActionID) -> Void
  let edit: () -> Void

  /// Tighter than `itemGap` so the three cards sit as one cluster.
  private static let tileGap: CGFloat = 4

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Spacer(minLength: 0)
        Button(action: edit) {
          SolarIcon(asset: SolarAsset.pen, size: 16, color: DashTheme.brand)
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel(DashL10n.string("Edit"))
        .dashHeaderActionHitTarget()
        .accessibilityIdentifier("home-quick-edit")
      }
      .padding(.horizontal, 4)

      Group {
        if dynamicTypeSize.isAccessibilitySize {
          VStack(spacing: Self.tileGap) { tiles }
        } else {
          HStack(alignment: .top, spacing: Self.tileGap) { tiles }
        }
      }
    }
  }

  @ViewBuilder
  private var tiles: some View {
    if actions.isEmpty {
      Button(action: edit) {
        DashToolTile(
          title: DashL10n.string("Choose actions"), icon: SolarAsset.Content.addCircle)
      }
      .buttonStyle(DashPressButtonStyle())
      .accessibilityIdentifier("home-quick-empty")
      .frame(maxWidth: .infinity)
    } else {
      ForEach(actions) { action in
        Button {
          perform(action)
        } label: {
          DashToolTile(title: action.title, icon: action.icon)
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityIdentifier(action.accessibilityIdentifier)
        .frame(maxWidth: .infinity)
      }
    }
  }
}

extension HomeActionID {
  fileprivate var title: String {
    switch self {
    case .addDomain: DashL10n.string("Add domain")
    case .uploadR2: DashL10n.string("Upload R2")
    case .addDNSRecord: DashL10n.string("Add DNS")
    case .createKVKey: DashL10n.string("Create key")
    case .createR2Bucket: DashL10n.string("New bucket")
    case .addPagesDomain: DashL10n.string("Pages domain")
    case .addWorkerDomain: DashL10n.string("Worker domain")
    case .enableDevelopmentMode: DashL10n.string("Dev mode")
    case .enableUnderAttackMode: DashL10n.string("Under Attack")
    case .purgeCache: DashL10n.string("Purge cache")
    }
  }

  fileprivate var subtitle: String {
    switch self {
    case .addDomain: DashL10n.string("Start a new Cloudflare zone")
    case .uploadR2: DashL10n.string("Choose a file and R2 bucket")
    case .addDNSRecord: DashL10n.string("Add a record to a domain")
    case .createKVKey: DashL10n.string("Write a value to a namespace")
    case .createR2Bucket: DashL10n.string("Create object storage")
    case .addPagesDomain: DashL10n.string("Attach a hostname to Pages")
    case .addWorkerDomain: DashL10n.string("Attach a hostname to a Worker")
    case .enableDevelopmentMode: DashL10n.string("Bypass cache for three hours")
    case .enableUnderAttackMode: DashL10n.string("Challenge every visitor")
    case .purgeCache: DashL10n.string("Clear cached assets for a domain")
    }
  }

  fileprivate var icon: String {
    switch self {
    case .addDomain: SolarAsset.Content.addCircle
    case .uploadR2: SolarAsset.Content.upload
    case .addDNSRecord: SolarAsset.Content.globus
    case .createKVKey: SolarAsset.Content.key
    case .createR2Bucket: SolarAsset.Content.box
    case .addPagesDomain: SolarAsset.Content.codeCircle
    case .addWorkerDomain: SolarAsset.Content.code
    case .enableDevelopmentMode: SolarAsset.Content.slider
    case .enableUnderAttackMode: SolarAsset.Content.shieldCheck
    case .purgeCache: SolarAsset.Content.bolt
    }
  }

  fileprivate var accessibilityIdentifier: String {
    switch self {
    case .addDomain: "home-quick-add-domain"
    case .uploadR2: "home-quick-upload-r2"
    case .addDNSRecord: "home-quick-add-dns"
    case .createKVKey: "home-quick-create-kv-key"
    case .createR2Bucket: "home-quick-create-r2-bucket"
    case .addPagesDomain: "home-quick-add-pages-domain"
    case .addWorkerDomain: "home-quick-add-worker-domain"
    case .enableDevelopmentMode: "home-quick-enable-development-mode"
    case .enableUnderAttackMode: "home-quick-enable-under-attack-mode"
    case .purgeCache: "home-quick-purge-cache"
    }
  }
}

private struct EditHomeActionsView: View {
  @Environment(\.dashTrayDismiss) private var dismiss
  @Binding var selectionRaw: String

  private var selection: [HomeActionID] {
    HomeActions.decode(selectionRaw)
  }

  var body: some View {
    // `.large` tray + shared selection rows. Expandable sheet supplies the
    // same Sheet.content / bodyBottom insets as `.content` Edit shortcuts.
    DashFormSheet(saveTitle: DashL10n.string("Done"), onSave: dismiss) {
      HomeEditSelectionList(items: Array(HomeActionID.allCases)) { action in
        let isSelected = selection.contains(action)
        let canToggle = isSelected || selection.count < HomeActions.limit
        HomeEditSelectionRow(
          title: action.title,
          subtitle: action.subtitle,
          isSelected: isSelected,
          isEnabled: canToggle
        ) {
          HomeActionEditIcon(asset: action.icon)
        } action: {
          selectionRaw = HomeActions.toggled(action, in: selectionRaw)
        }
      }
    }
  }
}

/// Shared edit-tray list chrome for Home Quick actions and Shortcuts.
private struct HomeEditSelectionList<Item: Identifiable, Row: View>: View {
  let items: [Item]
  @ViewBuilder let row: (Item) -> Row

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        row(item)
        if index < items.count - 1 {
          DashListGroupDivider()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct HomeEditSelectionRow<Icon: View>: View {
  let title: String
  let subtitle: String
  let isSelected: Bool
  var isEnabled: Bool = true
  @ViewBuilder let icon: () -> Icon
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        icon()
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .dashTextStyle(.bodySemibold)
            .foregroundStyle(DashTheme.text)
          Text(subtitle)
            .dashTextStyle(.supporting)
            .foregroundStyle(DashTheme.rowSubtitle)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 21, weight: .semibold))
          .foregroundStyle(isSelected ? DashTheme.brand : DashTheme.faint)
      }
      .padding(.vertical, 10)
      .frame(minHeight: DashTheme.Layout.minimumHitTarget)
      .contentShape(Rectangle())
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.48)
    .accessibilityValue(
      isSelected ? DashL10n.string("Selected") : DashL10n.string("Not selected")
    )
    .accessibilityAddTraits(.isToggle)
  }
}

/// Matches `CatalogFeatureIcon` list tile metrics for Home action glyphs.
private struct HomeActionEditIcon: View {
  let asset: String
  @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

  private var clamp: CGFloat { min(max(scale, 1), 1.3) }

  var body: some View {
    SolarIcon(asset: asset, size: 24 * clamp, color: DashTheme.iconMuted)
      .frame(width: 36 * clamp, height: 36 * clamp)
      .background(DashTheme.iconMuted.opacity(0.1), in: Circle())
      .accessibilityHidden(true)
  }
}

// MARK: - Shortcuts

private struct HomeShortcutsSection: View {
  let features: [FeatureID]
  let edit: () -> Void

  var body: some View {
    DashBorderedListGroup(
      title: DashL10n.string("Shortcuts"),
      actionTitle: "Edit",
      actionIcon: SolarAsset.pen,
      action: edit
    ) {
      if features.isEmpty {
        Text(DashL10n.string("Choose the Cloudflare features you use most."))
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.subtle)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 16)
      } else {
        ForEach(features) { feature in
          DashListGroupLink(value: .feature(feature)) {
            FeatureRow(feature: feature)
          }
        }
      }
    }
  }
}

private struct EditShortcutsView: View {
  @Environment(\.dashTrayDismiss) private var dismiss
  @Binding var selectionRaw: String

  private var selected: Set<FeatureID> {
    Set(HomeShortcuts.decode(selectionRaw))
  }

  var body: some View {
    DashFormSheet(saveTitle: DashL10n.string("Done"), onSave: dismiss) {
      HomeEditSelectionList(items: FeatureCatalog.all) { feature in
        HomeEditSelectionRow(
          title: feature.title,
          subtitle: feature.subtitle,
          isSelected: selected.contains(feature)
        ) {
          CatalogFeatureIcon(feature: feature, style: .fill, size: .list)
        } action: {
          selectionRaw = HomeShortcuts.toggled(feature, in: selectionRaw)
        }
      }
    }
  }
}

// MARK: - Home operations

private struct HomeDNSRecordAction: View {
  @Environment(AppModel.self) private var model
  let zones: [CloudflareZone]
  @State private var selectedZoneID: String?

  init(zones: [CloudflareZone]) {
    self.zones = zones
    _selectedZoneID = State(initialValue: zones.count == 1 ? zones.first?.id : nil)
  }

  var body: some View {
    Group {
      if let selectedZoneID {
        DNSRecordEditor(zoneID: selectedZoneID, record: nil) {
          model.featureCache.remove(FeatureCacheKey.dnsRecords(selectedZoneID))
        }
      } else if zones.isEmpty {
        DashNotice(
          kind: .warning,
          message: DashL10n.string("Add a domain before creating a DNS record."))
      } else {
        VStack(alignment: .leading, spacing: 12) {
          Text("Choose the domain for the new DNS record.")
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(zones.enumerated()), id: \.element.id) { index, zone in
              Button {
                selectedZoneID = zone.id
              } label: {
                DashListRow(
                  title: zone.name,
                  subtitle: (zone.status ?? "unknown").capitalized,
                  avatarSeed: zone.name
                )
              }
              .buttonStyle(DashSurfaceButtonStyle())
              if index < zones.count - 1 {
                DashListGroupDivider()
              }
            }
          }
        }
      }
    }
  }
}

private struct HomeCreateKVKeyAction: View {
  @Environment(AppModel.self) private var model
  @State private var namespaces: [KVNamespace] = []
  @State private var selectedNamespaceID: String?
  @State private var loading = true
  @State private var error: String?

  var body: some View {
    Group {
      if let selectedNamespaceID {
        KVCreateKeySheet(namespaceID: selectedNamespaceID) {
          guard let accountID = model.activeAccountID else { return }
          model.featureCache.remove(prefix: "kvKeys:\(accountID):\(selectedNamespaceID):")
        }
      } else if loading {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text("Loading KV namespaces…")
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
      } else if let error {
        DashNotice(kind: .error, message: error)
      } else if namespaces.isEmpty {
        DashNotice(
          kind: .warning,
          message: DashL10n.string("Create a KV namespace before adding a key."))
      } else {
        VStack(alignment: .leading, spacing: 12) {
          Text("Choose the namespace for the new key.")
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(namespaces.enumerated()), id: \.element.id) { index, namespace in
              Button {
                selectedNamespaceID = namespace.id
              } label: {
                DashListRow(
                  title: namespace.title,
                  subtitle: DashL10n.string("KV namespace"),
                  icon: SolarAsset.Content.pinList
                )
              }
              .buttonStyle(DashSurfaceButtonStyle())
              if index < namespaces.count - 1 {
                DashListGroupDivider()
              }
            }
          }
        }
      }
    }
    .task { await loadNamespaces() }
  }

  private func loadNamespaces() async {
    guard let accountID = model.activeAccountID else {
      loading = false
      return
    }
    let key = FeatureCacheKey.kvNamespaces(accountID)
    if let cached: [KVNamespace] = model.featureCache.get(key) {
      apply(cached)
      return
    }
    do {
      let loaded = try await model.client.listKVNamespaces(accountID: accountID).items
      model.featureCache.set(key, loaded)
      apply(loaded)
    } catch {
      self.error = error.dashActionableMessage
      loading = false
    }
  }

  private func apply(_ loaded: [KVNamespace]) {
    namespaces = loaded
    selectedNamespaceID = loaded.count == 1 ? loaded.first?.id : nil
    loading = false
  }
}

private struct HomePagesDomainAction: View {
  @Environment(AppModel.self) private var model
  @State private var projects: [PagesProject] = []
  @State private var selectedProject: String?
  @State private var loading = true
  @State private var error: String?

  var body: some View {
    Group {
      if let selectedProject {
        PagesAddDomainForm(projectName: selectedProject, onAdded: {})
      } else {
        actionPicker
      }
    }
    .task { await load() }
  }

  @ViewBuilder private var actionPicker: some View {
    if loading {
      HomeActionLoadingRow(title: DashL10n.string("Loading Pages projects…"))
    } else if let error {
      DashNotice(kind: .error, message: error)
    } else if projects.isEmpty {
      DashNotice(
        kind: .warning,
        message: DashL10n.string("Create a Pages project before attaching a domain."))
    } else {
      VStack(alignment: .leading, spacing: 12) {
        Text("Choose the Pages project for the custom domain.")
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.subtle)
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
            Button {
              selectedProject = project.name
            } label: {
              DashListRow(
                title: project.name,
                subtitle: project.subdomain,
                icon: SolarAsset.Content.codeCircle
              )
            }
            .buttonStyle(DashSurfaceButtonStyle())
            if index < projects.count - 1 { DashListGroupDivider() }
          }
        }
      }
    }
  }

  private func load() async {
    guard let accountID = model.activeAccountID else {
      loading = false
      return
    }
    let key = FeatureCacheKey.pagesProjects(accountID)
    if let cached: [PagesProject] = model.featureCache.get(key) {
      apply(cached)
      return
    }
    do {
      let loaded = try await model.client.listPagesProjects(accountID: accountID)
      model.featureCache.set(key, loaded)
      apply(loaded)
    } catch {
      self.error = error.dashActionableMessage
      loading = false
    }
  }

  private func apply(_ loaded: [PagesProject]) {
    projects = loaded
    selectedProject = loaded.count == 1 ? loaded.first?.name : nil
    loading = false
  }
}

private struct HomeWorkerDomainAction: View {
  @Environment(AppModel.self) private var model
  @State private var workers: [WorkerScript] = []
  @State private var selectedWorker: String?
  @State private var loading = true
  @State private var error: String?

  var body: some View {
    Group {
      if let selectedWorker {
        WorkerAddDomainForm(service: selectedWorker, onAdded: {})
      } else {
        actionPicker
      }
    }
    .task { await load() }
  }

  @ViewBuilder private var actionPicker: some View {
    if loading {
      HomeActionLoadingRow(title: DashL10n.string("Loading Workers…"))
    } else if let error {
      DashNotice(kind: .error, message: error)
    } else if workers.isEmpty {
      DashNotice(
        kind: .warning,
        message: DashL10n.string("Deploy a Worker before attaching a domain."))
    } else {
      VStack(alignment: .leading, spacing: 12) {
        Text("Choose the Worker for the custom domain.")
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.subtle)
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(workers.enumerated()), id: \.element.id) { index, worker in
            Button {
              selectedWorker = worker.id
            } label: {
              DashListRow(title: worker.id, icon: SolarAsset.Content.code)
            }
            .buttonStyle(DashSurfaceButtonStyle())
            if index < workers.count - 1 { DashListGroupDivider() }
          }
        }
      }
    }
  }

  private func load() async {
    guard let accountID = model.activeAccountID else {
      loading = false
      return
    }
    let key = FeatureCacheKey.workers(accountID)
    if let cached: [WorkerScript] = model.featureCache.get(key) {
      apply(cached)
      return
    }
    do {
      let loaded = try await model.client.listWorkers(accountID: accountID)
      model.featureCache.set(key, loaded)
      apply(loaded)
    } catch {
      self.error = error.dashActionableMessage
      loading = false
    }
  }

  private func apply(_ loaded: [WorkerScript]) {
    workers = loaded
    selectedWorker = loaded.count == 1 ? loaded.first?.id : nil
    loading = false
  }
}

private struct HomeZoneModeAction: View {
  enum Mode {
    case development
    case underAttack

    var actionTitle: String {
      switch self {
      case .development: DashL10n.string("Enable dev mode")
      case .underAttack: DashL10n.string("Enable Under Attack")
      }
    }

    var warning: String {
      switch self {
      case .development:
        DashL10n.string(
          "Cloudflare will bypass cache for this domain and turn Development Mode off automatically after three hours."
        )
      case .underAttack:
        DashL10n.string(
          "Cloudflare will challenge every visitor. You can restore the previous security level from the domain's WAF screen."
        )
      }
    }
  }

  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let zones: [CloudflareZone]
  let mode: Mode
  @State private var selectedZoneID: String?
  @State private var working = false
  @State private var result: String?
  @State private var error: String?

  init(zones: [CloudflareZone], mode: Mode) {
    self.zones = zones
    self.mode = mode
    _selectedZoneID = State(initialValue: zones.count == 1 ? zones.first?.id : nil)
  }

  var body: some View {
    Group {
      if let zone = zones.first(where: { $0.id == selectedZoneID }) {
        DashFormSheet(
          saveTitle: result == nil ? mode.actionTitle : DashL10n.string("Done"),
          isSaving: working,
          onSave: {
            if result == nil {
              Task { await enable(for: zone) }
            } else {
              dismiss()
            }
          }
        ) {
          VStack(alignment: .leading, spacing: 14) {
            if let result {
              DashNotice(kind: .success, message: result)
            } else {
              DashNotice(kind: .warning, message: mode.warning)
              Text(zone.name)
                .dashTextStyle(.bodySemibold)
                .foregroundStyle(DashTheme.text)
            }
            if let error {
              DashNotice(kind: .error, message: error)
            }
          }
        }
      } else if zones.isEmpty {
        DashNotice(
          kind: .warning,
          message: DashL10n.string("Add a domain before changing this mode."))
      } else {
        VStack(alignment: .leading, spacing: 12) {
          Text("Choose the domain to update.")
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(zones.enumerated()), id: \.element.id) { index, zone in
              Button {
                selectedZoneID = zone.id
              } label: {
                DashListRow(
                  title: zone.name,
                  subtitle: (zone.status ?? "unknown").capitalized,
                  avatarSeed: zone.name
                )
              }
              .buttonStyle(DashSurfaceButtonStyle())
              if index < zones.count - 1 { DashListGroupDivider() }
            }
          }
        }
      }
    }
  }

  private func enable(for zone: CloudflareZone) async {
    working = true
    error = nil
    defer { working = false }
    do {
      switch mode {
      case .development:
        _ = try await model.client.updateZoneSetting(
          zoneID: zone.id, settingID: "development_mode", value: .string("on"))
        result = DashL10n.string("Development Mode is on for \(zone.name).")
      case .underAttack:
        let settings = try await model.client.listZoneSettings(zoneID: zone.id)
        if case .string(let current)? = settings.first(where: { $0.id == "security_level" })?
          .value
        {
          UserDefaults.standard.set(current, forKey: "dash.previous_security_level.\(zone.id)")
        }
        _ = try await model.client.updateZoneSetting(
          zoneID: zone.id, settingID: "security_level", value: .string("under_attack"))
        result = DashL10n.string("Under Attack mode is on for \(zone.name).")
      }
      model.featureCache.remove(FeatureCacheKey.zoneSettings(zone.id))
      if let result {
        model.toasts.success(result)
      }
    } catch {
      self.error = error.dashActionableMessage
      DashDelight.failError()
    }
  }
}

private struct HomeActionLoadingRow: View {
  let title: String

  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text(title)
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 12)
  }
}

/// Starts a real upload from Home instead of merely opening the R2 catalog.
/// The last-used bucket/folder is preferred, but the destination stays explicit
/// and editable so a one-tap shortcut never writes to a surprising bucket.
private struct HomeR2UploadSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let onUploaded: (String) -> Void
  @State private var buckets: [R2Bucket] = []
  @State private var selectedBucket = ""
  @State private var fileURL: URL?
  @State private var importsFile = false
  @State private var loading = true
  @State private var uploading = false
  @State private var error: String?
  @State private var uploadedMessage: String?

  private var remembered: R2ShareDestination? {
    guard let accountID = model.activeAccountID else { return nil }
    return R2ShareDestination.destination(accountID: accountID)
  }

  private var destinationPrefix: String {
    guard remembered?.bucket == selectedBucket else { return "" }
    return remembered?.prefix ?? ""
  }

  private var actionTitle: String {
    if uploadedMessage != nil { return DashL10n.string("Done") }
    if fileURL == nil { return DashL10n.string("Choose file") }
    return DashL10n.string("Upload")
  }

  var body: some View {
    DashFormSheet(
      saveTitle: actionTitle,
      isSaving: uploading,
      canSave: uploadedMessage != nil || (!loading && !selectedBucket.isEmpty),
      onSave: performPrimaryAction
    ) {
      VStack(alignment: .leading, spacing: 14) {
        if let uploadedMessage {
          DashNotice(kind: .success, message: uploadedMessage)
        } else {
          if let error {
            DashNotice(kind: .error, message: error)
          }

          if loading {
            HStack(spacing: 10) {
              ProgressView()
                .controlSize(.small)
              Text("Loading R2 buckets…")
                .dashTextStyle(.footnote)
                .foregroundStyle(DashTheme.subtle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
          } else if buckets.isEmpty {
            DashNotice(
              kind: .warning,
              message: DashL10n.string("Create an R2 bucket before uploading a file."))
          } else {
            DashFormMenuField(
              label: DashL10n.string("Bucket"),
              selection: $selectedBucket,
              options: buckets.map(\.name)
            )

            if let fileURL {
              HStack(spacing: 12) {
                SolarIcon(asset: SolarAsset.Content.cloud, size: 22, color: DashTheme.brand)
                VStack(alignment: .leading, spacing: 2) {
                  Text(fileURL.lastPathComponent)
                    .dashTextStyle(.bodyMedium)
                    .foregroundStyle(DashTheme.text)
                    .lineLimit(1)
                  Text(destinationText)
                    .dashTextStyle(.footnote)
                    .foregroundStyle(DashTheme.subtle)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(DashL10n.string("Change")) { importsFile = true }
                  .dashTextStyle(.supportingMedium)
                  .foregroundStyle(DashTheme.brand)
                  .buttonStyle(DashPressButtonStyle())
              }
              .padding(14)
              .background(
                DashTheme.recessed,
                in: RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous)
              )
            } else {
              Text(destinationText)
                .dashTextStyle(.footnote)
                .foregroundStyle(DashTheme.subtle)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
    }
    .fileImporter(isPresented: $importsFile, allowedContentTypes: [.data]) { result in
      switch result {
      case .success(let url):
        fileURL = url
        error = nil
      case .failure(let error):
        self.error = error.dashActionableMessage
      }
    }
    .task { await loadBuckets() }
  }

  private var destinationText: String {
    let folder = destinationPrefix.isEmpty ? DashL10n.string("bucket root") : destinationPrefix
    return DashL10n.string(
      "Destination: \(selectedBucket.isEmpty ? "R2" : selectedBucket) / \(folder)")
  }

  private func performPrimaryAction() {
    if uploadedMessage != nil {
      dismiss()
    } else if fileURL == nil {
      importsFile = true
    } else {
      Task { await upload() }
    }
  }

  private func loadBuckets() async {
    guard let accountID = model.activeAccountID else {
      loading = false
      return
    }
    let key = FeatureCacheKey.r2Buckets(accountID)
    if let cached: [R2Bucket] = model.featureCache.get(key) {
      applyBuckets(cached)
      return
    }
    do {
      let loaded = try await model.client.listR2Buckets(accountID: accountID)
      model.featureCache.set(key, loaded)
      applyBuckets(loaded)
    } catch {
      self.error = error.dashActionableMessage
      loading = false
    }
  }

  private func applyBuckets(_ loaded: [R2Bucket]) {
    buckets = loaded
    selectedBucket =
      loaded.first(where: { $0.name == remembered?.bucket })?.name
      ?? loaded.first?.name ?? ""
    loading = false
  }

  private func upload() async {
    guard let accountID = model.activeAccountID,
      let fileURL,
      !selectedBucket.isEmpty
    else { return }
    uploading = true
    error = nil
    defer { uploading = false }

    do {
      let access = fileURL.startAccessingSecurityScopedResource()
      defer { if access { fileURL.stopAccessingSecurityScopedResource() } }
      guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
        throw HomeR2UploadError.unreadableFile
      }
      guard size <= R2Media.transferSizeLimit else {
        throw HomeR2UploadError.fileTooLarge(fileURL.lastPathComponent, size)
      }
      let readTask = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        return try Data(contentsOf: fileURL)
      }
      let data = try await readTask.value
      let key = destinationPrefix + fileURL.lastPathComponent
      try await model.client.putR2Object(
        accountID: accountID,
        bucket: selectedBucket,
        key: key,
        data: data,
        contentType: UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
      )
      model.featureCache.remove(
        prefix: FeatureCacheKey.r2ObjectsPrefix(accountID: accountID, bucket: selectedBucket))
      let domains: R2DomainsSnapshot? = model.featureCache.get(
        FeatureCacheKey.r2Domains(accountID: accountID, bucket: selectedBucket))
      R2ShareDestination.record(
        R2ShareDestination(
          accountID: accountID,
          bucket: selectedBucket,
          prefix: destinationPrefix,
          publicHost: domains?.publicHost
            ?? (remembered?.bucket == selectedBucket ? remembered?.publicHost : nil) ?? ""
        ))
      onUploaded(selectedBucket)
      let message = DashL10n.string(
        "Uploaded \(fileURL.lastPathComponent) to \(selectedBucket).")
      uploadedMessage = message
      model.toasts.success(message)
    } catch {
      self.error = error.dashActionableMessage
      DashDelight.failError()
    }
  }
}

private enum HomeR2UploadError: LocalizedError {
  case unreadableFile
  case fileTooLarge(String, Int)

  var errorDescription: String? {
    switch self {
    case .unreadableFile:
      DashL10n.string("Can't read that file's size.")
    case .fileTooLarge(let name, let size):
      DashL10n.string(
        "\(name) is \(size.formatted(.byteCount(style: .file))). Dash uploads files up to \(R2Media.transferSizeLimit.formatted(.byteCount(style: .file)))."
      )
    }
  }
}

private struct HomePurgeCachePicker: View {
  @Environment(\.dashTrayDismiss) private var dismiss
  let zones: [CloudflareZone]
  let onSelect: (CloudflareZone) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if zones.isEmpty {
        DashNotice(
          kind: .warning,
          message: DashL10n.string("Add a domain before purging cache."))
      } else {
        Text("Choose the domain whose cache you want to clear.")
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(zones.enumerated()), id: \.element.id) { index, zone in
            Button {
              dismiss()
              onSelect(zone)
            } label: {
              DashListRow(
                title: zone.name,
                subtitle: (zone.status ?? "unknown").capitalized,
                avatarSeed: zone.name
              )
            }
            .buttonStyle(DashSurfaceButtonStyle())
            if index < zones.count - 1 {
              DashListGroupDivider()
            }
          }
        }
      }
    }
  }
}

/// Two-phase add-domain tray: the form morphs into the assigned name servers
/// once Cloudflare accepts the zone, because the registrar update is the step
/// people forget.
/// Shared with the Domains catalog empty state, which offers the same flow
/// so a zero-domain account isn't a dead end there.
struct AddDomainSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let onCreated: () -> Void
  @State private var name = ""
  @State private var creating = false
  @State private var error: String?
  @State private var created: CloudflareZone?

  var body: some View {
    DashFormSheet(
      saveTitle: created == nil ? "Add domain" : "Done",
      isSaving: creating,
      canSave: created != nil || AddDomainValidation.isPlausibleZoneName(name),
      onSave: {
        if created == nil {
          Task { await create() }
        } else {
          dismiss()
        }
      }
    ) {
      Group {
        if let created {
          successContent(created)
            .transition(reduceMotion ? .opacity : .dashMorph)
        } else {
          formContent
            .transition(reduceMotion ? .opacity : .dashMorph)
        }
      }
    }
    .dashTrayTitle(
      created == nil ? DashL10n.string("Add domain") : DashL10n.string("Domain added"))
  }

  private var formContent: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let error {
        DashNotice(kind: .error, message: error)
      }
      DashFormField(
        label: "Domain",
        text: $name,
        keyboard: .URL,
        contentType: .URL)
      Text(
        "Cloudflare assigns name servers next; the domain activates once your registrar points at them."
      )
      .dashTextStyle(.footnote)
      .foregroundStyle(DashTheme.subtle)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func successContent(_ zone: CloudflareZone) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      DashNotice(kind: .success, message: "\(zone.name) is on Cloudflare.")
      if let servers = zone.nameServers, !servers.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("Point the domain's name servers at")
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
          ForEach(servers, id: \.self) { server in
            Text(server)
              .dashTextStyle(.code)
              .foregroundStyle(DashTheme.text)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .background(
                DashTheme.recessed,
                in: RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
          }
        }
      }
      Text("It shows as Pending until the name servers update — usually within a few hours.")
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func create() async {
    guard let accountID = model.activeAccountID else { return }
    creating = true
    error = nil
    do {
      let zone = try await model.client.createZone(
        name: AddDomainValidation.normalized(name), accountID: accountID)
      model.toasts.success(DashL10n.string("Created successfully."))
      onCreated()
      withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morph) {
        created = zone
      }
    } catch {
      self.error = error.dashActionableMessage
    }
    creating = false
  }
}

// MARK: - Domains

private struct HomeDomainsSection: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var avatarTransition
  let zones: [CloudflareZone]
  let isLoading: Bool
  let error: String?
  let locked: Bool
  @Binding var showsAddDomain: Bool
  let retry: () -> Void
  @State private var isExpanded = false

  private var expandable: Bool {
    !locked && (!zones.isEmpty || isLoading)
  }

  private var canAddDomain: Bool {
    model.hasScopes(FeatureID.zones.capability.write)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      Group {
        if locked {
          lockedRecovery
        } else if let error, zones.isEmpty {
          failureRecovery(message: error)
        } else if zones.isEmpty, !isLoading {
          emptyDomains
        } else if isExpanded {
          expandedRows
        }
      }
      .padding(.horizontal, DashTheme.Spacing.rowInset)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      DashTheme.homeDomainsSurface,
      in: RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
    )
    .dashShadow(.border)
  }

  private var header: some View {
    Button {
      withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morph) {
        isExpanded.toggle()
      }
    } label: {
      HStack(spacing: 12) {
        Text("Domains")
          .dashTextStyle(.supportingMedium)
          .foregroundStyle(DashTheme.listGroupTitle)
        Spacer(minLength: 0)
        if !isExpanded, !dynamicTypeSize.isAccessibilitySize {
          avatarStack
        }
        if expandable {
          SolarIcon(
            asset: SolarAsset.chevronRight, size: DashTheme.Chevron.row, color: DashTheme.faint
          )
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 4)
      .frame(minHeight: 32)
      .contentShape(Rectangle())
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .disabled(!expandable)
    .accessibilityIdentifier("home-domains-toggle")
    .accessibilityLabel("Domains")
    .accessibilityValue(
      expandable ? (isExpanded ? "Expanded" : "Collapsed, \(zones.count) domains") : "")
  }

  @ViewBuilder
  private var avatarStack: some View {
    if locked {
      EmptyView()
    } else if isLoading, zones.isEmpty {
      HStack(spacing: -8) {
        ForEach(0..<3, id: \.self) { _ in
          Circle()
            .fill(DashTheme.recessed)
            .frame(width: 26, height: 26)
            .overlay { Circle().stroke(DashTheme.homeDomainsSurface, lineWidth: 2) }
        }
      }
      .accessibilityHidden(true)
    } else {
      HStack(spacing: -8) {
        ForEach(zones.prefix(Self.collapsedAvatarLimit)) { zone in
          HomeZoneAvatar(seed: zone.name, size: 26)
            .matchedGeometryEffect(id: zone.id, in: avatarTransition)
        }
        if zones.count > Self.collapsedAvatarLimit {
          Circle()
            .fill(DashTheme.recessed)
            .frame(width: 26, height: 26)
            .overlay {
              Text("+\(zones.count - Self.collapsedAvatarLimit)")
                .dashTextStyle(.micro)
                .foregroundStyle(DashTheme.subtle)
                .minimumScaleFactor(0.7)
            }
        }
      }
      .accessibilityHidden(true)
    }
  }

  /// Collapsed header chips + expanded list viewport (more scroll inside).
  private static let collapsedAvatarLimit = 6
  private static let expandedVisibleCount = 6
  /// Matches `HomeDomainRow` (30pt avatar + 12pt vertical padding).
  private static let expandedRowHeight: CGFloat = 54

  private var expandedRows: some View {
    Group {
      if isLoading, zones.isEmpty {
        // Cold: row placeholders matching HomeDomainRow rhythm — never a ring.
        VStack(alignment: .leading, spacing: 0) {
          ForEach(0..<3, id: \.self) { _ in
            HStack(spacing: 12) {
              Circle()
                .fill(DashTheme.recessed)
                .frame(width: 30, height: 30)
              VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                  .fill(DashTheme.recessed)
                  .frame(height: 13)
                  .frame(maxWidth: 140)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                  .fill(DashTheme.recessed.opacity(0.7))
                  .frame(height: 11)
                  .frame(maxWidth: 90)
              }
              Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .frame(minHeight: DashTheme.Layout.minimumHitTarget)
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
      } else if zones.count > Self.expandedVisibleCount {
        HomeDomainsScrollViewport(
          zones: zones,
          avatarTransition: avatarTransition,
          rowHeight: Self.expandedRowHeight,
          visibleCount: Self.expandedVisibleCount
        )
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(zones) { zone in
            DashListGroupLink(value: .zone(zone.id)) {
              HomeDomainRow(
                zone: zone,
                avatarTransition: avatarTransition)
            }
          }
        }
      }
    }
  }

  private var lockedRecovery: some View {
    VStack(alignment: .leading, spacing: 10) {
      DashNotice(
        kind: .warning,
        message: DashL10n.string("Grant access to see domains here.")
      )
      DashSecondaryPillButton(title: DashFailureAction.grantAccess.title) {
        model.requestAccess(to: FeatureID.zones.capability.all)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 16)
  }

  private func failureRecovery(message: String) -> some View {
    let presentation = DashFailurePresentation.from(message: message)
    return VStack(alignment: .leading, spacing: 10) {
      DashNotice(kind: .error, message: presentation.message)
      DashSecondaryPillButton(title: presentation.action.title) {
        performFailureAction(presentation.action)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 16)
  }

  private func performFailureAction(_ action: DashFailureAction) {
    switch action {
    case .signInAgain:
      Task { await model.signOut() }
    case .grantAccess:
      model.requestAccess(to: FeatureID.zones.capability.all)
    case .tryAgain:
      retry()
    }
  }

  private var emptyDomains: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(DashL10n.string("No domains in this account."))
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
        .frame(maxWidth: .infinity, alignment: .leading)
      if canAddDomain {
        DashSecondaryPillButton(title: DashL10n.string("Add domain")) {
          showsAddDomain = true
        }
        .accessibilityIdentifier("home-domains-add-domain")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 16)
  }
}

/// Nested Domains list: fixed-height viewport with shared edge-fade affordance.
private struct HomeDomainsScrollViewport: View {
  let zones: [CloudflareZone]
  let avatarTransition: Namespace.ID
  var rowHeight: CGFloat
  var visibleCount: Int

  private var viewportHeight: CGFloat { rowHeight * CGFloat(visibleCount) }

  var body: some View {
    DashFadedScrollView(
      surface: DashTheme.homeDomainsSurface,
      maxHeight: viewportHeight,
      bounceBasedOnSize: true
    ) {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(zones) { zone in
          DashListGroupLink(value: .zone(zone.id)) {
            HomeDomainRow(
              zone: zone,
              avatarTransition: avatarTransition)
          }
        }
      }
    }
    .accessibilityHint(
      DashL10n.string("Scroll for more domains")
    )
  }
}

/// Stable on-device gradient generated from the domain name.
private struct HomeZoneAvatar: View {
  let seed: String
  var size: CGFloat = 26

  var body: some View {
    GradientAvatar(seed: seed, size: size, pattern: .dither, contentScale: 1.5)
      .accessibilityHidden(true)
  }
}

private struct HomeDomainRow: View {
  let zone: CloudflareZone
  let avatarTransition: Namespace.ID
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    HStack(spacing: 12) {
      // Match `DashListRow` zone avatars in Recently used (30pt disc).
      HomeZoneAvatar(seed: zone.name, size: 30)
        .matchedGeometryEffect(id: zone.id, in: avatarTransition)
      VStack(alignment: .leading, spacing: 2) {
        Text(zone.name)
          .dashTextStyle(.bodyMedium)
          .foregroundStyle(DashTheme.text)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        Text((zone.status ?? "unknown").capitalized)
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.rowSubtitle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 12)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(zone.name), \(zone.status ?? "unknown")")
  }
}

// MARK: - Recently used

/// Recent drill-downs for the active account, fed by `RecentResources`. Zone
/// rows skip morph sources: Domains expand + HomeDomainRow already own those
/// zone identities on this screen, and a second source for the same id makes
/// the animations fight. Non-zone recents still fly into their detail headers.
private struct HomeRecentsSection: View {
  let recents: [RecentResource]
  let onReopen: (RecentResource) -> Void

  var body: some View {
    DashBorderedListGroup(title: "Recently used") {
      ForEach(recents) { resource in
        DashListGroupLink(
          value: resource.destination,
          onNavigate: { onReopen(resource) }
        ) {
          DashListRow(
            title: resource.title,
            subtitle: resource.kind.displayName,
            icon: resource.kind.listIcon,
            iconColor: FeatureVisualIdentity.catalogColor(for: resource.featureID),
            avatarSeed: resource.kind == .zone ? resource.title : nil
          )
        }
      }
    }
  }
}

struct FeatureRow: View {
  enum Presentation {
    /// Saturated card — reserved for rare hero moments.
    case vividCard
    /// Neutral catalog row: color lives on the icon tile and status only.
    case catalog
  }

  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let feature: FeatureID
  var iconStyle: CatalogFeatureIcon.Style = .fill
  var presentation: Presentation = .catalog

  private var accessLevel: FeatureAccessLevel {
    feature.capability.accessLevel(grantedScopes: model.grantedScopes)
  }

  private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

  private var onCard: Color { FeatureVisualIdentity.onCardColor(for: feature) }

  var body: some View {
    Group {
      switch presentation {
      case .vividCard: vividCardBody
      case .catalog: catalogBody
      }
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  private var vividCardBody: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        CatalogFeatureIcon(
          feature: feature, style: iconStyle, emphasized: true
        )
        .opacity(accessLevel == .locked ? 0.55 : 1)
        Spacer(minLength: 0)
        accessBadge
      }
      vividLabels
    }
    .padding(.vertical, 14)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
    .dashListItemCard(fill: FeatureVisualIdentity.cardColor(for: feature))
  }

  private var catalogBody: some View {
    Group {
      if isAccessibilitySize {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 12) {
            featureChrome
            Spacer(minLength: 0)
            accessBadge
          }
          catalogSubtitle
        }
      } else {
        HStack(spacing: 12) {
          featureChrome
          accessBadge
        }
      }
    }
    .padding(.vertical, 12)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
  }

  private var featureChrome: some View {
    HStack(spacing: 12) {
      CatalogFeatureIcon(feature: feature, style: iconStyle, size: .list)
        .opacity(accessLevel == .locked ? 0.55 : 1)
      VStack(alignment: .leading, spacing: 2) {
        Text(feature.title)
          .dashTextStyle(.bodySemibold)
          .foregroundStyle(DashTheme.text)
          .lineLimit(isAccessibilitySize ? nil : 1)
        if !isAccessibilitySize {
          catalogSubtitle
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var vividLabels: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(feature.title)
        .dashTextStyle(.bodySemibold)
        .foregroundStyle(onCard)
        .lineLimit(isAccessibilitySize ? nil : 1)
      Text(feature.subtitle)
        .dashTextStyle(.supporting)
        .foregroundStyle(onCard.opacity(0.75))
        .lineLimit(isAccessibilitySize ? nil : 2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var catalogSubtitle: some View {
    Group {
      if isAccessibilitySize {
        Text(feature.subtitle)
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.rowSubtitle)
      } else {
        DashGreedyWrapText(text: feature.subtitle)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var accessBadge: some View {
    switch accessLevel {
    case .full:
      EmptyView()
    case .readOnly:
      StatusBadge(text: "Read-only")
    case .locked:
      StatusBadge(text: "Locked")
    }
  }

  private var accessibilityLabel: String {
    "\(feature.title), \(feature.subtitle), \(accessAccessibilityValue)"
  }

  private var accessAccessibilityValue: String {
    switch accessLevel {
    case .full: "Available"
    case .readOnly: "Read-only"
    case .locked: "Locked"
    }
  }
}
