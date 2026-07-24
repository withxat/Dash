import BlossomColorPickerCore
import CloudflareAPI
import GradientAvatars
import SwiftDitherKit
import SwiftUI

struct FeatureRouterContent: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID

  var body: some View {
    let accessLevel = feature.capability.accessLevel(grantedScopes: model.grantedScopes)
    Group {
      if accessLevel != .locked {
        routedContent
          .environment(\.featureAllowsWrites, accessLevel == .full)
          .environment(\.featureRequiredScopes, feature.capability.all)
          .safeAreaInset(edge: .top, spacing: 0) {
            if accessLevel == .readOnly {
              FeatureReadOnlyBanner(feature: feature)
                .padding(.horizontal, DashTheme.Spacing.screen)
                .padding(.bottom, 8)
                .background(DashTheme.canvas)
            }
          }
      } else {
        FeatureAccessRequiredView(feature: feature)
      }
    }
    .detailHeader(icon: .feature(feature), title: feature.title)
  }

  /// Exhaustive on purpose — no `default:`. A new FeatureID must name its screen
  /// here or it does not build.
  @ViewBuilder
  private var routedContent: some View {
    Group {
      switch feature {
      case .zones: ZonesView()
      case .workers: WorkersView()
      case .pages: PagesProjectsView()
      case .r2: R2BucketsView()
      case .kv: KVNamespacesView()
      }
    }
  }
}

struct FeatureReadOnlyBanner: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      DashNotice(
        kind: .warning,
        message: "Read-only — grant write access to make changes.")
      DashPillButton(
        title: "Grant write access",
        isLoading: model.isAuthenticating
      ) {
        model.requestAccess(to: feature.capability.write)
      }
    }
  }
}

/// Maps a push destination to the catalog feature that owns its write scopes.
func featureID(for destination: Destination) -> FeatureID? {
  switch destination {
  case .profile, .settings, .about, .openSource, .auditLogs, .pushAlerts, .watchtowerInbox: nil
  #if DEBUG
    case .debug: nil
  #endif
  case .feature(let feature): feature
  case .zone, .dns, .cache, .zoneAnalytics, .zoneWebAnalytics, .zoneWAF, .zoneSettings:
    .zones
  case .worker: .workers
  case .pagesProject, .pagesDeployment, .pagesDomains: .pages
  case .r2Bucket, .r2BucketSettings: .r2
  case .kvNamespace, .kvKey: .kv
  }
}

/// Scopes a destination needs beyond what its FeatureID declares.
///
/// The literals matter: `dns.*` and `cache.purge` have no FeatureID of their own
/// since DNS Management and Cache & Performance left the catalog, and they are
/// not in `.zones.capability` — putting them there would lock the whole Zones
/// feature for a grant missing one of them. Deleting a case here compiles fine
/// and silently falls through to `.zones.capability.all`, which does not
/// include them. See DashAuthorizationScopes.coreOperations.
func requiredScopes(for destination: Destination) -> Set<String> {
  switch destination {
  case .profile, .settings, .about, .openSource, .watchtowerInbox:
    []
  #if DEBUG
    case .debug:
      []
  #endif
  case .auditLogs:
    ["account-settings.read"]
  case .pushAlerts:
    ["notifications.read", "notifications.write"]
  case .dns:
    ["zone.read", "dns.read", "dns.write"]
  case .cache:
    ["zone.read", "cache.purge"]
  case .zoneSettings:
    ["zone.read", "zone-settings.read", "zone-settings.write"]
  case .zoneAnalytics, .zoneWAF:
    DashAuthorizationScopes.zoneAnalytics
  case .zoneWebAnalytics:
    DashAuthorizationScopes.webAnalytics
  case .feature, .zone, .worker, .pagesProject, .pagesDeployment, .pagesDomains, .r2Bucket,
    .r2BucketSettings, .kvNamespace, .kvKey:
    featureID(for: destination)?.capability.all ?? []
  }
}

private struct FeatureWriteAccessKey: EnvironmentKey {
  static let defaultValue = true
}

private struct FeatureRequiredScopesKey: EnvironmentKey {
  static let defaultValue: Set<String> = []
}

private struct FeatureIdentityKey: EnvironmentKey {
  static let defaultValue: FeatureID? = nil
}

extension EnvironmentValues {
  var featureAllowsWrites: Bool {
    get { self[FeatureWriteAccessKey.self] }
    set { self[FeatureWriteAccessKey.self] = newValue }
  }

  var featureRequiredScopes: Set<String> {
    get { self[FeatureRequiredScopesKey.self] }
    set { self[FeatureRequiredScopesKey.self] = newValue }
  }

  /// Catalog feature that owns the current workspace destination, when any.
  /// List icons and chrome read this so a feature keeps one accent color.
  var featureIdentity: FeatureID? {
    get { self[FeatureIdentityKey.self] }
    set { self[FeatureIdentityKey.self] = newValue }
  }
}

private struct FeatureAccessRequiredView: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID

  var body: some View {
    ScrollView {
      DashCard {
        VStack(alignment: .leading, spacing: DashTheme.Spacing.comfortable) {
          SolarIcon(
            asset: SolarAsset.Content.lock, size: 30,
            color: FeatureVisualIdentity.heroColor(for: feature))
          Text("Grant access to \(feature.title)")
            .dashTextStyle(.sectionTitle)
            .foregroundStyle(DashTheme.strong)
          Text(
            "This module needs \(feature.capability.read.sorted().joined(separator: ", ")). You can review the request before Cloudflare opens."
          )
          .dashTextStyle(.supporting)
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
          DashPillButton(
            title: "Grant access",
            isLoading: model.isAuthenticating
          ) {
            model.requestAccess(to: feature.capability.all)
          }
        }
      }
      .padding(DashTheme.Spacing.section)
    }
    .background(DashTheme.canvas)
  }
}

struct ZonesView: View {
  static let pageSize = 50

  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @AppStorage(DomainCardColors.key) private var domainCardColorData = ""
  @State private var zones: [CloudflareZone] = []
  @State private var error: String?
  @State private var loading = true
  @State private var loadingMore = false
  @State private var showsAddDomain = false
  @State private var pageState = DashPageState()

  private var gridColumns: [GridItem] {
    let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
    return Array(
      repeating: GridItem(.flexible(), spacing: DashTheme.Spacing.itemGap),
      count: count)
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !zones.isEmpty,
      retry: { Task { await load() } }
    ) {
      if zones.isEmpty {
        DashEmptyState(
          icon: SolarAsset.Content.globus,
          title: "No domains",
          message: featureAllowsWrites
            ? "Add your first domain to put it on Cloudflare."
            : "Cloudflare returned no domains for this account.",
          actionTitle: featureAllowsWrites ? "Add domain" : nil,
          action: featureAllowsWrites ? { showsAddDomain = true } : nil
        )
      } else {
        LazyVGrid(columns: gridColumns, spacing: DashTheme.Spacing.itemGap) {
          ForEach(zones) { zone in
            domainCardLink(zone)
          }
        }
      }
      if pageState.canLoadMore {
        DashLoadMoreFooter(
          loaded: zones.count,
          total: pageState.totalCount,
          noun: "domains",
          isLoading: loadingMore
        ) { Task { await loadMore() } }
      }
    }
    .refreshable { await load(force: true) }.task { await load() }
    .onAppear { reloadIfInvalidated() }
    .dashTray(isPresented: $showsAddDomain, title: "Add domain") {
      AddDomainSheet {
        guard let accountID = model.activeAccountID else { return }
        model.featureCache.remove(FeatureCacheKey.zones(accountID))
        Task { await load(force: true) }
      }
    }
  }

  private func domainCardLink(_ zone: CloudflareZone) -> some View {
    let fillHex = cardFillHex(for: zone)
    let status = (zone.status ?? "unknown").capitalized
    return DashListGroupLink(value: .zone(zone.id)) {
      DomainCardFace(
        name: zone.name,
        status: status,
        seed: zone.name,
        fillHex: fillHex
      )
    }
  }

  private func cardFillHex(for zone: CloudflareZone) -> UInt32 {
    guard let accountID = model.activeAccountID else {
      return DomainCardColors.defaultHex(for: zone.name)
    }
    return DomainCardColors.hex(
      in: domainCardColorData,
      accountID: accountID,
      zoneID: zone.id,
      seed: zone.name)
  }

  /// The cache drops under this list on memory pressure while it stays alive
  /// below a child screen; refresh on return when the cache went cold.
  private func reloadIfInvalidated() {
    guard let accountID = model.activeAccountID, !zones.isEmpty else { return }
    let cached: [CloudflareZone]? = model.featureCache.get(FeatureCacheKey.zones(accountID))
    if cached == nil { Task { await load(force: true) } }
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.zones(accountID)
    if !force, let cached: [CloudflareZone] = model.featureCache.get(key) {
      zones = cached
      pageState.rehydrate(loaded: cached.count, pageSize: Self.pageSize)
      loading = false
      error = nil
      return
    }
    if zones.isEmpty { loading = true }
    error = nil
    do {
      pageState.reset()
      let page = try await model.client.listZones(
        accountID: accountID, page: pageState.nextPage, perPage: Self.pageSize)
      zones = page.items
      pageState.absorb(
        info: page.resultInfo, received: page.items.count, loaded: zones.count,
        pageSize: Self.pageSize)
      model.featureCache.storeZones(zones, accountID: accountID)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }

  private func loadMore() async {
    guard let accountID = model.activeAccountID, !loadingMore else { return }
    loadingMore = true
    defer { loadingMore = false }
    do {
      let page = try await model.client.listZones(
        accountID: accountID, page: pageState.nextPage, perPage: Self.pageSize)
      zones += page.items
      pageState.absorb(
        info: page.resultInfo, received: page.items.count, loaded: zones.count,
        pageSize: Self.pageSize)
      model.featureCache.storeZones(zones, accountID: accountID)
      error = nil
    } catch {
      self.error = error.dashActionableMessage
    }
  }
}

struct ZoneDetailView: View {
  @Environment(AppModel.self) private var model
  @AppStorage(PinnedZones.key) private var pinnedZoneData = ""
  @AppStorage(DomainCardColors.key) private var domainCardColorData = ""
  @AppStorage(RecentResources.key) private var recentsRaw = ""
  let zoneID: String
  @State private var zone: CloudflareZone?
  @State private var error: String?
  /// True while the hero owns the matched-geometry destination (lifted seat).
  @State private var isCustomizingCard = false
  /// Keeps the overlay mounted through the return morph after `isCustomizingCard` flips.
  @State private var showsCustomizeOverlay = false
  /// Draft fill while customizing; committed only by the checkmark.
  @State private var draftCardHex: UInt32?
  /// Non-nil while the overlay runs its settle-back exit.
  @State private var cardCustomizeExit: DomainCardCustomizeExit?
  @State private var activationChecking = false
  @Namespace private var cardCustomizeNamespace

  private var isExitingCardCustomize: Bool { cardCustomizeExit != nil }
  private static let cardMorphID = "zone-detail-domain-card"

  private var isPinned: Bool { PinnedZones.isPinned(pinnedZoneData, zoneID: zoneID) }

  /// Live preview hex while the editor is open; otherwise the saved card color.
  private var displayedCardFillHex: UInt32 {
    draftCardHex ?? cardFillHex
  }

  /// Zone already on-device (detail entry, account list, or just-fetched).
  private var displayedZone: CloudflareZone? {
    zone ?? model.featureCache.cachedZone(id: zoneID, accountID: model.activeAccountID)
  }

  /// Header never flashes the generic "Domain" when Home/list/pins/recents
  /// already know the hostname — network refresh can replace it later.
  private var headerTitle: String {
    if let name = displayedZone?.name, !name.isEmpty { return name }
    if let hint = localNameHint, !hint.isEmpty { return hint }
    return DashL10n.string("Domain")
  }

  /// Same dither seed as Home / Domains list rows (domain name when known).
  private var domainAvatarSeed: String {
    if let name = displayedZone?.name, !name.isEmpty { return name }
    if let hint = localNameHint, !hint.isEmpty { return hint }
    return zoneID
  }

  private var localNameHint: String? {
    if let pin = PinnedZones.decode(pinnedZoneData).first(where: { $0.zoneID == zoneID }),
      !pin.name.isEmpty
    {
      return pin.name
    }
    guard let accountID = model.activeAccountID else { return nil }
    return RecentResources.visible(in: recentsRaw, accountID: accountID)
      .first { $0.kind == .zone && $0.resourceID == zoneID }?
      .title
  }

  private var cardFillHex: UInt32 {
    let seed = domainAvatarSeed
    guard let accountID = model.activeAccountID else {
      return DomainCardColors.defaultHex(for: seed)
    }
    return DomainCardColors.hex(
      in: domainCardColorData,
      accountID: accountID,
      zoneID: zoneID,
      seed: seed)
  }

  @State private var rdap: RdapRegistration?

  private let tools: [ZoneTool] = [
    ZoneTool(
      title: "DNS", icon: SolarAsset.Content.globus, route: Destination.dns,
      blurb: "Records and proxy status"),
    ZoneTool(
      title: "HTTP traffic", icon: SolarAsset.Content.chart, route: Destination.zoneAnalytics,
      blurb: "Requests, visitors, and bandwidth"),
    ZoneTool(
      title: "Web analytics", icon: SolarAsset.Content.graph,
      route: Destination.zoneWebAnalytics,
      blurb: "Page views reported by real browsers"),
    ZoneTool(
      title: "WAF", icon: SolarAsset.Content.shieldCheck, route: Destination.zoneWAF,
      blurb: "Blocks, countries, Under Attack"),
    ZoneTool(
      title: "Cache", icon: SolarAsset.Content.bolt, route: Destination.cache,
      blurb: "Purge by URL or everything"),
    ZoneTool(
      title: "Settings", icon: SolarAsset.Content.settings, route: Destination.zoneSettings,
      blurb: "Under Attack, SSL, and dev mode"),
  ]

  var body: some View {
    DashFeatureList(
      isLoading: displayedZone == nil && error == nil,
      error: error,
      hasContent: displayedZone != nil,
      retry: { Task { await load() } }
    ) {
      if let zone = displayedZone {
        zoneHero(zone)
        if needsActivation(zone) {
          activationCard(zone)
            .dashSectionBoundary()
        }
        if let rdap {
          rdapCard(rdap)
            .dashSectionBoundary()
        }
        primaryActions()
          .dashSectionBoundary()
      }
    }
    .detailHeader(icon: .avatar(domainAvatarSeed), title: headerTitle)
    .navigationBarBackButtonHidden(showsCustomizeOverlay && isCustomizingCard)
    .toolbar {
      if showsCustomizeOverlay && isCustomizingCard {
        ToolbarItem(placement: .topBarLeading) {
          DashToolbarIconButton(
            asset: SolarAsset.close,
            accessibilityLabel: "Close"
          ) { cancelCardCustomize() }
          .disabled(isExitingCardCustomize)
          .accessibilityIdentifier("domain-card-customize-close")
        }
        .dashSeparateToolbarBackground()
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarIconButton(
            asset: SolarAsset.checkCircle,
            accessibilityLabel: "Save"
          ) { saveCardCustomize() }
          .disabled(isExitingCardCustomize)
          .accessibilityIdentifier("domain-card-customize-save")
        }
        .dashSeparateToolbarBackground()
      } else {
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarIconButton(
            asset: isPinned ? SolarAsset.pinFilled : SolarAsset.pin,
            accessibilityLabel: isPinned ? "Unpin domain" : "Pin domain"
          ) { togglePin() }
          .disabled(displayedZone == nil || showsCustomizeOverlay)
        }
        .dashSeparateToolbarBackground()
      }
    }
    .refreshable { await load(force: true) }.task { await load() }
    .overlay {
      if showsCustomizeOverlay {
        DomainCardColorCustomizeOverlay(
          domainName: headerTitle,
          status: (displayedZone?.status ?? "unknown").capitalized,
          seed: domainAvatarSeed,
          plan: displayedZone?.plan?.name,
          morphNamespace: cardCustomizeNamespace,
          morphID: Self.cardMorphID,
          isMorphSource: isCustomizingCard,
          fillHex: Binding(
            get: { displayedCardFillHex },
            set: { draftCardHex = $0 }
          ),
          exitRequest: $cardCustomizeExit,
          onExitFinished: finishCardCustomizeExit
        )
      }
    }
  }

  private func beginCardCustomize() {
    cardCustomizeExit = nil
    draftCardHex = cardFillHex
    showsCustomizeOverlay = true
    withAnimation(DashTheme.Motion.morph) {
      isCustomizingCard = true
    }
    DashDelight.lightImpact()
  }

  private func cancelCardCustomize() {
    guard !isExitingCardCustomize else { return }
    // Snap the floating card back to the saved color while it settles.
    draftCardHex = nil
    cardCustomizeExit = .cancel
    DashDelight.lightImpact()
  }

  private func saveCardCustomize() {
    guard !isExitingCardCustomize else { return }
    guard let accountID = model.activeAccountID, let hex = draftCardHex else {
      cancelCardCustomize()
      return
    }
    domainCardColorData = DomainCardColors.setting(
      hex,
      in: domainCardColorData,
      accountID: accountID,
      zoneID: zoneID)
    draftCardHex = nil
    cardCustomizeExit = .save
    DashDelight.lightImpact()
  }

  private func finishCardCustomizeExit() {
    cardCustomizeExit = nil
    // Morph the floating card back into the detail hero, then drop the overlay.
    withAnimation(DashTheme.Motion.morph) {
      isCustomizingCard = false
    }
    Task { @MainActor in
      try? await Task.sleep(
        for: .milliseconds(UIAccessibility.isReduceMotionEnabled ? 40 : 320))
      showsCustomizeOverlay = false
      draftCardHex = nil
    }
  }

  private func togglePin() {
    guard let zone = displayedZone, let accountID = model.activeAccountID else { return }
    withAnimation(DashTheme.Motion.quick) {
      pinnedZoneData = PinnedZones.toggled(
        pinnedZoneData,
        pin: PinnedZone(accountID: accountID, zoneID: zoneID, name: zone.name))
    }
    DashDelight.lightImpact()
  }

  private func load(force: Bool = false) async {
    let key = FeatureCacheKey.zone(zoneID)
    // Paint from session cache first so the nav title never waits on network.
    if zone == nil,
      let cached = model.featureCache.cachedZone(id: zoneID, accountID: model.activeAccountID)
    {
      zone = cached
      error = nil
      recordRecent(cached)
      if !force {
        await loadRdap(for: cached, force: false)
        return
      }
    } else if !force, let cached: CloudflareZone = model.featureCache.get(key) {
      zone = cached
      error = nil
      recordRecent(cached)
      await loadRdap(for: cached, force: false)
      return
    }
    do {
      let fetched = try await model.client.getZone(zoneID)
      zone = fetched
      model.featureCache.set(key, fetched)
      error = nil
      recordRecent(fetched)
      await loadRdap(for: fetched, force: true)
    } catch {
      // Keep the locally resolved zone on screen; only surface the error when
      // we have nothing to show.
      if zone == nil, displayedZone == nil {
        self.error = error.dashActionableMessage
      }
    }
  }

  private func loadRdap(for zone: CloudflareZone, force: Bool) async {
    let key = FeatureCacheKey.zoneRdap(zoneID)
    if !force, let cached: RdapRegistration = model.featureCache.get(key) {
      rdap = cached
      return
    }
    do {
      if let registration = try await RdapClient.lookup(
        domain: zone.name, relayBaseURL: model.configuration.pushBaseURL
      ) {
        rdap = registration
        model.featureCache.set(key, registration)
      } else {
        rdap = nil
      }
    } catch {
      rdap = nil
    }
  }

  /// The zone's name only exists after a load, so recency is recorded here
  /// rather than on navigation.
  private func recordRecent(_ zone: CloudflareZone) {
    guard let accountID = model.activeAccountID else { return }
    recentsRaw = RecentResources.recording(
      RecentResource(accountID: accountID, kind: .zone, resourceID: zoneID, title: zone.name),
      in: recentsRaw)
  }

  private func zoneHero(_ zone: CloudflareZone) -> some View {
    let status = (zone.status ?? "unknown").capitalized
    let plan = zone.plan?.name
    // Nameserver count stays off the tile — the nameserver plate below owns that.
    return VStack(alignment: .leading, spacing: 12) {
      DomainCardFace(
        name: zone.name,
        status: status,
        seed: zone.name,
        fillHex: displayedCardFillHex,
        plan: plan,
        aspectRatio: DomainCardFace.detailAspectRatio
      )
      .overlay(alignment: .bottomTrailing) {
        if !showsCustomizeOverlay {
          DomainCardCustomizeButton {
            beginCardCustomize()
          }
          .accessibilityValue(DomainCardColors.formatHex(cardFillHex))
          .padding(12)
        }
      }
      .matchedGeometryEffect(
        id: Self.cardMorphID,
        in: cardCustomizeNamespace,
        properties: .frame,
        isSource: !isCustomizingCard
      )
      .opacity(isCustomizingCard ? 0 : 1)
      .allowsHitTesting(!showsCustomizeOverlay)
      .frame(maxWidth: .infinity)
      .accessibilityHidden(showsCustomizeOverlay)

      if let servers = zone.nameServers, !servers.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("Nameservers")
            .dashTextStyle(.footnoteSemibold)
            .foregroundStyle(DashTheme.subtle)
          ForEach(servers, id: \.self) {
            Text($0).dashTextStyle(.code)
          }
        }
        .padding(DashTheme.Spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          DashTheme.recessed,
          in: RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
        )
        .dashShadow(.border)
      }
    }
  }

  private func primaryActions() -> some View {
    DashListGroup(title: "Quick actions") {
      dashListCardRows(items: tools, inset: false) { tool in
        let destination = tool.route(zoneID)
        DashListGroupLink(value: destination) {
          DashListRow(
            title: DashL10n.ui(tool.title), subtitle: DashL10n.ui(tool.blurb), icon: tool.icon)
        }
      }
    }
  }

  /// Statuses a name-server re-check can move forward. `moved` means
  /// Cloudflare stopped seeing its name servers; pointing them back and
  /// re-checking restores the zone.
  private func needsActivation(_ zone: CloudflareZone) -> Bool {
    ["pending", "initializing", "moved"].contains((zone.status ?? "").lowercased())
  }

  private var canTriggerActivationCheck: Bool {
    model.hasScopes(FeatureID.zones.capability.write)
  }

  private func activationBlurb(_ zone: CloudflareZone) -> String {
    if (zone.status ?? "").lowercased() == "moved" {
      return DashL10n.string(
        "Cloudflare no longer sees its name servers at the registrar. Point them back, then ask Cloudflare to check."
      )
    }
    return DashL10n.string(
      "Waiting for the registrar to point at the name servers above. Already updated them? Ask Cloudflare to check now instead of on the hourly sweep."
    )
  }

  private func activationCard(_ zone: CloudflareZone) -> some View {
    DashCard {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Activation")
            .dashTextStyle(.footnoteSemibold)
            .foregroundStyle(DashTheme.subtle)
          Text(activationBlurb(zone))
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.text)
            .fixedSize(horizontal: false, vertical: true)
        }
        if canTriggerActivationCheck {
          DashPillButton(title: "Check now", isLoading: activationChecking) {
            Task { await triggerActivationCheck() }
          }
        } else {
          Text("Grant domain write access to trigger a check from here.")
            .dashTextStyle(.caption)
            .foregroundStyle(DashTheme.subtle)
        }
      }
    }
  }

  private func triggerActivationCheck() async {
    activationChecking = true
    do {
      try await model.client.triggerZoneActivationCheck(zoneID: zoneID)
      model.toasts.success(
        DashL10n.string(
          "Cloudflare is rechecking now — the status usually updates within a few minutes."))
    } catch {
      model.toasts.error(error.dashActionableMessage)
    }
    activationChecking = false
  }

  private func rdapCard(_ registration: RdapRegistration) -> some View {
    DashCard {
      VStack(alignment: .leading, spacing: 10) {
        Text("Registration")
          .dashTextStyle(.footnoteSemibold)
          .foregroundStyle(DashTheme.subtle)
        if let registrar = registration.registrar {
          rdapRow("Registrar", registrar)
        }
        if let expires = registration.expiresOn {
          rdapRow("Expires", rdapDateLabel(expires))
        }
        if let registered = registration.registeredOn {
          rdapRow("Registered", rdapDateLabel(registered))
        }
        if let status = registration.status.first {
          rdapRow("Status", rdapStatusLabel(status))
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Registration info from RDAP")
  }

  private func rdapRow(_ label: LocalizedStringKey, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .dashTextStyle(.caption)
        .foregroundStyle(DashTheme.subtle)
        .frame(width: 88, alignment: .leading)
      Text(value)
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
  }
}

private func rdapDateLabel(_ value: String) -> String {
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let plain = ISO8601DateFormatter()
  plain.formatOptions = [.withInternetDateTime]
  let day = DateFormatter()
  day.dateStyle = .medium
  day.timeStyle = .none
  day.locale = DashL10n.activeLocale
  if let date = fractional.date(from: value) ?? plain.date(from: value) {
    return day.string(from: date)
  }
  return String(value.prefix(10))
}

/// RDAP sends spaced statuses ("client transfer prohibited"); the WHOIS
/// fallback sends EPP camelCase ("clientTransferProhibited"). Fold both into
/// one English source form so a single catalog key localizes them.
private func rdapStatusLabel(_ raw: String) -> String {
  var spaced = raw.replacingOccurrences(of: "_", with: " ")
  if !spaced.contains(" ") {
    var split = ""
    for character in spaced {
      if character.isUppercase, !split.isEmpty { split.append(" ") }
      split.append(character)
    }
    spaced = split
  }
  return DashL10n.ui(spaced.lowercased().capitalized)
}

/// Native glass control on the detail hero card — opens the color picker.
private struct DomainCardCustomizeButton: View {
  let action: () -> Void
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    Group {
      if #available(iOS 26.0, *) {
        Button {
          DashDelight.lightImpact()
          action()
        } label: {
          Text(DashL10n.string("Customize"))
            .dashTextStyle(.footnoteSemibold)
        }
        .buttonStyle(.glass)
      } else if reduceTransparency {
        Button {
          DashDelight.lightImpact()
          action()
        } label: {
          label
            .background(DashTheme.elevated, in: Capsule(style: .continuous))
            .overlay {
              Capsule(style: .continuous).stroke(DashTheme.line, lineWidth: 0.5)
            }
        }
        .buttonStyle(DashPressButtonStyle())
      } else {
        Button {
          DashDelight.lightImpact()
          action()
        } label: {
          label
            .background(.thinMaterial, in: Capsule(style: .continuous))
            .overlay {
              Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.24), lineWidth: 0.5)
            }
        }
        .buttonStyle(DashPressButtonStyle())
      }
    }
    .accessibilityLabel(DashL10n.string("Customize"))
    .accessibilityHint(DashL10n.string("Opens the domain card color picker"))
    .accessibilityIdentifier("domain-card-customize")
  }

  private var label: some View {
    Text(DashL10n.string("Customize"))
      .dashTextStyle(.footnoteSemibold)
      .foregroundStyle(DashTheme.strong)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .contentShape(Capsule(style: .continuous))
  }
}

/// Colored domain card shared by the Domains grid, detail hero, and color picker.
///
/// Width fills the offered slot; height scales with `aspectRatio`.
/// Domains grid stays 5:4; zone detail and the color preview use 5:3.
struct DomainCardFace: View {
  /// Domains 2-up grid tile.
  static let gridAspectRatio: CGFloat = 5.0 / 4.0
  /// Zone detail hero and color-customize preview.
  static let detailAspectRatio: CGFloat = 5.0 / 3.0

  let name: String
  let status: String
  let seed: String
  let fillHex: UInt32
  var plan: String? = nil
  var meta: String? = nil
  var aspectRatio: CGFloat = DomainCardFace.gridAspectRatio

  private let avatarSize: CGFloat = 28
  private let cornerRadius: CGFloat = DashTheme.Radius.button
  private var foreground: Color { DomainCardColors.foreground(fillHex) }
  private var secondaryForeground: Color { DomainCardColors.secondaryForeground(fillHex) }

  private var accessibilitySummary: String {
    var parts = [name, DashL10n.ui(status)]
    if let plan { parts.append(DashL10n.ui(plan)) }
    if let meta { parts.append(meta) }
    return parts.joined(separator: ", ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      GradientAvatar(seed: seed, size: avatarSize, pattern: .dither, contentScale: 1.5)
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Spacer(minLength: 12)
      Text(name)
        .dashTextStyle(.bodySemibold)
        .foregroundStyle(foreground)
        .lineLimit(2)
        .minimumScaleFactor(0.85)
      Text(DashL10n.ui(status))
        .dashTextStyle(.footnote)
        .foregroundStyle(secondaryForeground)
        .lineLimit(1)

      if plan != nil || meta != nil {
        tileExtras
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(DashTheme.Spacing.card)
    .background {
      DashGrainSurface(
        color: DomainCardColors.fill(fillHex),
        cornerRadius: cornerRadius,
        // Slightly toothier than chrome grain so the enamel face reads as
        // a painted tile rather than a flat fill.
        intensity: 0.055
      )
    }
    .dashEmbossed(.pigmented, cornerRadius: cornerRadius)
    .aspectRatio(aspectRatio, contentMode: .fit)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilitySummary)
  }

  @ViewBuilder
  private var tileExtras: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let plan {
        Text(DashL10n.ui(plan))
          .dashTextStyle(.footnote)
          .foregroundStyle(secondaryForeground)
          .lineLimit(1)
      }
      if let meta {
        Text(meta)
          .dashTextStyle(.caption)
          .foregroundStyle(secondaryForeground.opacity(0.9))
          .lineLimit(1)
      }
    }
    .padding(.top, 8)
  }
}

private enum DomainCardCustomizeExit: Equatable {
  case cancel
  case save
}

/// In-place color editor over zone detail.
///
/// The detail hero morphs here via `matchedGeometryEffect`, the scrim blurs in,
/// then the always-mounted Blossom picker fades up. Entrance timing uses an
/// unstructured `Task` from `onAppear` — not `.task` — so parent redraws cannot
/// cancel the sleep and leave the picker stuck hidden.
private struct DomainCardColorCustomizeOverlay: View {
  let domainName: String
  let status: String
  let seed: String
  var plan: String? = nil
  let morphNamespace: Namespace.ID
  let morphID: String
  /// When true, this floating card is the matched-geometry source (lifted seat).
  let isMorphSource: Bool
  @Binding var fillHex: UInt32
  @Binding var exitRequest: DomainCardCustomizeExit?
  let onExitFinished: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @State private var model: BlossomColorPickerModel
  @State private var scrimProgress: CGFloat = 0
  @State private var pickerRevealed = false
  @State private var isExiting = false
  @State private var didStartEntrance = false

  private let layout = PetalLayout(
    innerRadius: 44,
    outerRadius: 80
  )
  private let style = BlossomStyle(
    petalSize: 40,
    innerPetalSize: 40,
    centerCircleSize: 40,
    sliderWidth: 14
  )

  init(
    domainName: String,
    status: String,
    seed: String,
    plan: String? = nil,
    morphNamespace: Namespace.ID,
    morphID: String,
    isMorphSource: Bool,
    fillHex: Binding<UInt32>,
    exitRequest: Binding<DomainCardCustomizeExit?>,
    onExitFinished: @escaping () -> Void
  ) {
    self.domainName = domainName
    self.status = status
    self.seed = seed
    self.plan = plan
    self.morphNamespace = morphNamespace
    self.morphID = morphID
    self.isMorphSource = isMorphSource
    _fillHex = fillHex
    _exitRequest = exitRequest
    self.onExitFinished = onExitFinished
    _model = State(
      wrappedValue: BlossomColorPickerModel(
        initialColor: DomainCardColors.fill(fillHex.wrappedValue)))
  }

  private var blossomSize: CGFloat {
    ExpandedBlossomView.totalSize(layout: layout, style: style)
  }

  var body: some View {
    ZStack {
      scrim
        .opacity(scrimProgress)
        .ignoresSafeArea()
        .allowsHitTesting(scrimProgress > 0.01 && !isExiting)

      VStack(spacing: DashTheme.Spacing.section) {
        DomainCardFace(
          name: domainName,
          status: status,
          seed: seed,
          fillHex: fillHex,
          plan: plan,
          aspectRatio: DomainCardFace.detailAspectRatio
        )
        .matchedGeometryEffect(
          id: morphID,
          in: morphNamespace,
          properties: .frame,
          isSource: isMorphSource
        )
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DashTheme.Spacing.screen)
        .accessibilityLabel("\(domainName), \(DashL10n.ui(status)), card preview")
        .allowsHitTesting(false)

        // Always mounted: conditional insert + `.task` cancellation was the
        // intermittent "picker never appears" failure mode.
        ExpandedBlossomView(model: model, layout: layout)
          .blossomStyle(style)
          .frame(width: blossomSize, height: blossomSize)
          .frame(maxWidth: .infinity)
          .opacity(pickerRevealed ? 1 : 0)
          .scaleEffect(pickerRevealed ? 1 : 0.92)
          .offset(y: pickerRevealed ? 0 : 12)
          .allowsHitTesting(pickerRevealed && !isExiting)
          .accessibilityElement(children: .contain)
          .accessibilityLabel("Color palette")
          .accessibilityHidden(!pickerRevealed)

        Spacer(minLength: 16)
          .allowsHitTesting(false)
      }
      // Top inset seats the preview below the nav chrome and lower than the
      // detail hero — the matched-geometry morph animates into this seat.
      .padding(.top, 108)
      .padding(.bottom, DashTheme.Spacing.section)
    }
    .allowsHitTesting(!isExiting)
    .onAppear { startEntranceIfNeeded() }
    .onChange(of: exitRequest) { _, request in
      guard request != nil, !isExiting else { return }
      Task { @MainActor in
        await runExit()
      }
    }
    .onChange(of: model.selectedColor) { _, color in
      guard !isExiting else { return }
      let hex = DomainCardColors.hex(from: color)
      guard hex != fillHex else { return }
      fillHex = hex
    }
    .onChange(of: model.isExpanded) { _, isExpanded in
      // Center-tap collapse is a Blossom affordance — keep the disc open here
      // so Close / Save stay the only exits.
      if !isExpanded, !isExiting { model.expand() }
    }
  }

  @ViewBuilder
  private var scrim: some View {
    if reduceMotion || reduceTransparency {
      Color.black.opacity(0.45)
    } else {
      Rectangle().fill(.ultraThinMaterial)
    }
  }

  private func startEntranceIfNeeded() {
    guard !didStartEntrance else { return }
    didStartEntrance = true
    // Expand while still invisible so the first reveal is a fully bloomed disc.
    model.expand()
    Task { @MainActor in
      await runEntrance()
    }
  }

  @MainActor
  private func runEntrance() async {
    if reduceMotion {
      scrimProgress = 1
      pickerRevealed = true
      return
    }

    withAnimation(.easeOut(duration: 0.32)) {
      scrimProgress = 1
    }
    try? await Task.sleep(for: .milliseconds(220))
    // Unstructured Task — do not bail on cancellation the way `.task` would.
    withAnimation(DashTheme.Motion.morph) {
      pickerRevealed = true
    }
  }

  @MainActor
  private func runExit() async {
    isExiting = true
    if reduceMotion {
      pickerRevealed = false
      scrimProgress = 0
      onExitFinished()
      return
    }

    withAnimation(DashTheme.Motion.morph) {
      pickerRevealed = false
    }
    try? await Task.sleep(for: .milliseconds(140))
    withAnimation(.easeOut(duration: 0.28)) {
      scrimProgress = 0
    }
    try? await Task.sleep(for: .milliseconds(220))
    onExitFinished()
  }
}

/// One row on zone detail. Every row routes to a dedicated destination, which
/// declares its own scopes in `requiredScopes(for:)`.
private struct ZoneTool: Identifiable {
  let title: String
  let icon: String
  let route: (String) -> Destination
  var blurb: String? = nil
  var id: String { title }
}

struct DNSRecordsView: View {
  static let pageSize = 100

  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let zoneID: String
  @State private var records: [DNSRecord] = []
  @State private var selected: DNSRecord?
  @State private var createsRecord = false
  @State private var loading = true
  @State private var loadingMore = false
  @State private var pageState = DashPageState()
  @State private var error: String?
  @State private var selectedSliceID: String?

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !records.isEmpty,
      retry: { Task { await load(force: true) } }
    ) {
      if records.isEmpty {
        DashEmptyState(
          icon: SolarAsset.Content.globus,
          title: "No DNS records",
          message: "Create a record with the add button."
        )
      } else {
        recordTypesCard
          // Bottom padding on the card, not top padding on the rows: the rows
          // are a bare lazy `ForEach` and must stay untouched (StorageViews
          // precedent).
          .padding(.bottom, DashTheme.Spacing.itemGap)
        dashListCard {
          dashListCardRows(items: visibleRecords) { record in
            Button {
              selected = record
            } label: {
              DashListRow(
                title: record.name,
                subtitle: dnsRecordSubtitle(record),
                icon: record.proxied == true
                  ? SolarAsset.Content.cloud : SolarAsset.Content.globus,
                // Proxied keeps the orange cloud; unproxied inherits the
                // zones catalog green.
                iconColor: record.proxied == true ? DashTheme.accent : nil
              )
            }
            .buttonStyle(DashSurfaceButtonStyle())
            .transition(morphTransition)
          }
        }
      }
      if pageState.canLoadMore {
        DashLoadMoreFooter(
          loaded: records.count,
          total: pageState.totalCount,
          noun: "records",
          caption: filterCaption,
          isLoading: loadingMore
        ) { Task { await loadMore() } }
      }
    }
    .refreshable { await load(force: true) }
    .detailHeader(icon: .solar(SolarAsset.Content.globus), title: "DNS")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if featureAllowsWrites {
          DashToolbarIconButton(asset: SolarAsset.plus, accessibilityLabel: "New DNS record") {
            createsRecord = true
          }
        }
      }
      .dashSeparateToolbarBackground()
    }
    .dashTray(
      item: $selected,
      title: { _ in "DNS record" },
      content: { record in
        DNSRecordEditor(zoneID: zoneID, record: record) {
          model.featureCache.remove(FeatureCacheKey.dnsRecords(zoneID))
          Task { await load(force: true) }
        }
      }
    )
    .dashTray(isPresented: $createsRecord, title: "New DNS record") {
      DNSRecordEditor(zoneID: zoneID, record: nil) {
        model.featureCache.remove(FeatureCacheKey.dnsRecords(zoneID))
        Task { await load(force: true) }
      }
    }
    .task { await load() }
  }

  private var recordTypesCard: some View {
    DashCard {
      VStack(alignment: .leading, spacing: 12) {
        Text("Record types")
          .dashTextStyle(.footnoteSemibold)
          .foregroundStyle(DashTheme.subtle)
        DitherPieChart(
          slices: recordTypeSlices,
          innerRadiusRatio: 0.62,
          options: DashTheme.DitherChart.polarOptions(
            accessibility: DitherAccessibility(
              title: DashL10n.ui("DNS record types"),
              summary: DNSChartModel.chartAccessibilitySummary(
                buckets: DNSChartModel.buckets(records)),
              categoryAxisLabel: DashL10n.ui("Record type"),
              valueAxisLabel: DashL10n.ui("Records"))),
          // Slice and legend taps land here, so the write is what morphs the
          // rows below: an animated binding puts the whole update — donut
          // highlight, filter strip, and the list diff — in one transaction.
          selection: $selectedSliceID.animation(DashTheme.Motion.morph)
        )
        .frame(
          height: DashTheme.DitherChart.height(
            dynamicTypeSize: dynamicTypeSize,
            showsLegend: true))
        // Under the legend, not beside the card title: engaging a filter grows
        // the card downward, so the donut the user just tapped stays put and
        // only the list below — which is re-flowing anyway — moves.
        filterStrip
      }
    }
  }

  @ViewBuilder
  private var filterStrip: some View {
    if let bucket = selectedBucket {
      DNSRecordTypeFilterStrip(
        label: DNSChartModel.label(for: bucket),
        count: bucket.count,
        total: records.count,
        color: sliceColor(forBucketID: bucket.id)
      ) {
        withAnimation(DashTheme.Motion.morph) { selectedSliceID = nil }
      }
      .transition(morphTransition)
    }
  }

  /// Rows the donut selection leaves standing. Nothing is selected on a cold
  /// screen, so the common path is the full list. `DitherPieChart` clears a
  /// selection that stops naming a slice, which is why Load more can widen the
  /// data without the view resetting the filter itself.
  private var visibleRecords: [DNSRecord] {
    DNSChartModel.records(records, in: selectedSliceID)
  }

  private var selectedBucket: DNSChartModel.Bucket? {
    DNSChartModel.bucket(records, withID: selectedSliceID)
  }

  /// A filtered list would make the footer's default "Showing X of Y" caption
  /// describe rows that are not on screen. Name the narrowed subset instead —
  /// Load more still fetches whole pages, not more of the selected type.
  private var filterCaption: String? {
    guard selectedBucket != nil else { return nil }
    return DashL10n.string(
      "Filtered to \(visibleRecords.count) of \(records.count) loaded records")
  }

  /// Filtered-out rows dissolve with the same blur the tray morph uses, so the
  /// list reads as collapsing rather than blinking; survivors glide into their
  /// new slots on the shared transaction. Only onscreen rows are realized in
  /// the lazy stack, so the morph costs the same on a 2,000-record zone.
  private var morphTransition: AnyTransition {
    reduceMotion ? .opacity : .dashMorph
  }

  /// Named buckets take the categorical palette positionally; the folded
  /// Other bucket always renders neutral grey.
  private var recordTypeSlices: [DitherSlice] {
    let palette = [
      DashTheme.DitherChart.brand(colorScheme: colorScheme, contrast: colorSchemeContrast),
      DashTheme.DitherChart.positive(colorScheme: colorScheme, contrast: colorSchemeContrast),
      DashTheme.DitherChart.accentPurple(colorScheme: colorScheme, contrast: colorSchemeContrast),
      DashTheme.DitherChart.warning(colorScheme: colorScheme, contrast: colorSchemeContrast),
      DashTheme.DitherChart.accentTeal(colorScheme: colorScheme, contrast: colorSchemeContrast),
    ]
    var nextColor = 0
    return DNSChartModel.buckets(records).map { bucket in
      let color: DitherColor
      if bucket.id == DNSChartModel.otherBucketID {
        color = DashTheme.DitherChart.neutral(
          colorScheme: colorScheme, contrast: colorSchemeContrast)
      } else {
        color = palette[nextColor % palette.count]
        nextColor += 1
      }
      return DitherSlice(
        id: bucket.id,
        label: DNSChartModel.label(for: bucket),
        value: Double(bucket.count),
        color: color)
    }
  }

  /// The filter strip borrows its dot from the slice it stands for, so the
  /// palette stays assigned in exactly one place.
  private func sliceColor(forBucketID id: String) -> DitherColor {
    recordTypeSlices.first { $0.id == id }?.color
      ?? DashTheme.DitherChart.neutral(colorScheme: colorScheme, contrast: colorSchemeContrast)
  }

  private func load(force: Bool = false) async {
    let key = FeatureCacheKey.dnsRecords(zoneID)
    if !force, let cached: [DNSRecord] = model.featureCache.get(key) {
      records = cached
      pageState.rehydrate(loaded: cached.count, pageSize: Self.pageSize)
      loading = false
      error = nil
      return
    }
    if records.isEmpty { loading = true }
    error = nil
    do {
      pageState.reset()
      let page = try await model.client.listDNSRecords(
        zoneID: zoneID, page: pageState.nextPage, perPage: Self.pageSize)
      records = page.items
      pageState.absorb(
        info: page.resultInfo, received: page.items.count, loaded: records.count,
        pageSize: Self.pageSize)
      model.featureCache.set(key, records)
    } catch {
      if error.dashIsCancellation { return }
      self.error = error.dashActionableMessage
    }
    loading = false
  }

  private func loadMore() async {
    guard !loadingMore else { return }
    loadingMore = true
    defer { loadingMore = false }
    do {
      let page = try await model.client.listDNSRecords(
        zoneID: zoneID, page: pageState.nextPage, perPage: Self.pageSize)
      records += page.items
      pageState.absorb(
        info: page.resultInfo, received: page.items.count, loaded: records.count,
        pageSize: Self.pageSize)
      model.featureCache.set(FeatureCacheKey.dnsRecords(zoneID), records)
      error = nil
    } catch {
      if error.dashIsCancellation { return }
      self.error = error.dashActionableMessage
    }
  }
}

/// States the active record-type filter under the donut legend. The legend chip
/// toggles the same selection, but a chip only reads as selected next to its
/// neighbours; this line names the narrowing in words and carries the escape
/// hatch. Only Show all is a button — the line itself is a caption, not a row.
private struct DNSRecordTypeFilterStrip: View {
  let label: String
  let count: Int
  let total: Int
  let color: DitherColor
  let clear: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(Color(red: color.red, green: color.green, blue: color.blue))
        .frame(width: 8, height: 8)
      // Record types are protocol names (A, CNAME, …) and stay verbatim.
      Text(verbatim: label)
        .dashTextStyle(.captionSemibold)
        .foregroundStyle(DashTheme.strong)
      Text(DashL10n.string("\(count.formatted()) of \(total.formatted()) records"))
        .dashTextStyle(.caption)
        .monospacedDigit()
        .foregroundStyle(DashTheme.subtle)
      Spacer(minLength: 8)
      Button(DashL10n.string("Show all"), action: clear)
        .dashTextStyle(.captionSemibold)
        .foregroundStyle(DashTheme.brand)
        .buttonStyle(DashPressButtonStyle())
        .frame(minHeight: DashTheme.Layout.minimumHitTarget)
        .dashHeaderActionHitTarget()
        .accessibilityLabel(DashL10n.string("Show all record types"))
        .accessibilityIdentifier("dns-type-filter-clear")
    }
    .lineLimit(1)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
  }
}

/// Pure conversion for the DNS record-type distribution donut, so bucketing
/// and accessibility strings are unit-tested away from the view. Counts cover
/// loaded pages only — the records list paginates.
enum DNSChartModel {
  /// The donut legend stays readable with at most five named types; every
  /// remaining type folds into one neutral Other slice.
  static let namedTypeLimit = 5
  /// Lowercase on purpose: record-type bucket ids are uppercased, so the
  /// Other bucket can never collide with a real type.
  static let otherBucketID = "other"

  struct Bucket: Hashable, Identifiable {
    /// Uppercased record type, or ``otherBucketID`` for the folded remainder.
    let id: String
    let count: Int
  }

  /// Buckets ordered by count descending; ties break alphabetically by type
  /// so the layout is deterministic across reloads. Other, when present, is
  /// always last.
  static func buckets(_ records: [DNSRecord]) -> [Bucket] {
    var counts: [String: Int] = [:]
    for record in records {
      counts[record.type.uppercased(), default: 0] += 1
    }
    let ordered = counts.sorted {
      $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
    }
    var buckets = ordered.prefix(namedTypeLimit).map { Bucket(id: $0.key, count: $0.value) }
    let otherCount = ordered.dropFirst(namedTypeLimit).reduce(0) { $0 + $1.value }
    if otherCount > 0 {
      buckets.append(Bucket(id: otherBucketID, count: otherCount))
    }
    return buckets
  }

  /// Raw record types are protocol names (A, CNAME, …) and stay verbatim;
  /// only the folded bucket label localizes.
  static func label(for bucket: Bucket) -> String {
    bucket.id == otherBucketID ? DashL10n.string("Other") : bucket.id
  }

  /// The bucket a donut selection names, or `nil` when nothing is selected.
  /// A selection can outlive the data it was made against (Load more can fold
  /// a named type into Other), so callers resolve against the current buckets
  /// instead of trusting the stored id.
  static func bucket(_ records: [DNSRecord], withID bucketID: String?) -> Bucket? {
    guard let bucketID else { return nil }
    return buckets(records).first { $0.id == bucketID }
  }

  /// Loaded records belonging to one donut bucket — the list-side half of
  /// slice selection. A `nil` id, or one no bucket claims, filters nothing, so
  /// a stale selection degrades to the full list rather than an empty one.
  static func records(_ records: [DNSRecord], in bucketID: String?) -> [DNSRecord] {
    guard let bucketID else { return records }
    let all = buckets(records)
    guard all.contains(where: { $0.id == bucketID }) else { return records }
    guard bucketID == otherBucketID else {
      return records.filter { $0.type.uppercased() == bucketID }
    }
    // Other holds the remainder by construction: whatever the named slices
    // did not claim.
    let named = Set(all.map(\.id)).subtracting([otherBucketID])
    return records.filter { !named.contains($0.type.uppercased()) }
  }

  /// Describes the LOADED records only — the list paginates, so counts do not
  /// cover pages that have not been fetched yet.
  static func chartAccessibilitySummary(buckets: [Bucket]) -> String {
    let total = buckets.reduce(0) { $0 + $1.count }
    guard total > 0 else {
      return DashL10n.string("Record types chart. No DNS records loaded.")
    }
    let parts = buckets.map { bucket in
      "\(label(for: bucket)) \(bucket.count.formatted())"
    }
    let list = parts.formatted(
      .list(type: .and, width: .standard).locale(DashL10n.activeLocale))
    return DashL10n.string(
      "Record types chart. \(total.formatted()) loaded records: \(list)."
    )
  }
}

private func dnsRecordSubtitle(_ record: DNSRecord) -> String {
  if record.type == "MX", let priority = record.priority {
    return "MX  ·  \(priority)  ·  \(record.content)"
  }
  if record.type == "SRV" {
    let priority = record.data?.priority ?? record.priority
    let weight = record.data?.weight
    let port = record.data?.port
    let target = record.data?.target ?? record.content
    var parts = ["SRV"]
    if let priority { parts.append("\(priority)") }
    if let weight { parts.append("\(weight)") }
    if let port { parts.append(":\(port)") }
    parts.append(target)
    return parts.joined(separator: "  ·  ")
  }
  return "\(record.type)  ·  \(record.content)"
}

struct DNSRecordEditor: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let zoneID: String
  let record: DNSRecord?
  let saved: () -> Void
  @State private var type: String
  @State private var name: String
  @State private var content: String
  @State private var priorityText: String
  @State private var weightText: String
  @State private var portText: String
  @State private var target: String
  @State private var caaFlagsText: String
  @State private var caaTag: String
  @State private var caaValue: String
  @State private var proxied: Bool
  @State private var ttl: Int
  @State private var error: String?
  @State private var saving = false
  @State private var deleting = false

  private var isSRV: Bool { type == "SRV" }
  private var isMX: Bool { type == "MX" }
  private var isCAA: Bool { type == "CAA" }
  private var supportsProxy: Bool { ["A", "AAAA", "CNAME"].contains(type) }

  private var canSave: Bool {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    if isSRV {
      return Int(priorityText) != nil
        && Int(weightText) != nil
        && Int(portText) != nil
        && !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if isMX {
      return Int(priorityText) != nil
        && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if isCAA {
      return Int(caaFlagsText).map { (0...255).contains($0) } == true
        && !caaValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  init(zoneID: String, record: DNSRecord?, saved: @escaping () -> Void) {
    self.zoneID = zoneID
    self.record = record
    self.saved = saved
    let initialType = record?.type ?? "A"
    _type = State(initialValue: initialType)
    _name = State(initialValue: record?.name ?? "")
    _content = State(initialValue: record?.content ?? "")
    _priorityText = State(
      initialValue: record.flatMap { $0.data?.priority ?? $0.priority }.map(String.init) ?? "10")
    _weightText = State(initialValue: record?.data?.weight.map(String.init) ?? "0")
    _portText = State(initialValue: record?.data?.port.map(String.init) ?? "")
    _target = State(initialValue: record?.data?.target ?? "")
    _caaFlagsText = State(initialValue: record?.data?.flags.map(String.init) ?? "0")
    _caaTag = State(initialValue: record?.data?.tag ?? "issue")
    _caaValue = State(initialValue: record?.data?.value ?? "")
    _proxied = State(initialValue: record?.proxied ?? false)
    _ttl = State(initialValue: record?.ttl ?? 1)
  }

  var body: some View {
    DashFormSheet(
      isSaving: saving,
      canSave: canSave,
      deleteMessage: record.map {
        DashL10n.string("Permanently delete the \($0.type) record for \($0.name).")
      },
      isDeleting: deleting,
      deleteError: error,
      onDelete: record.map { rec in { Task { await delete(rec) } } },
      onSave: { Task { await save() } },
      content: {
        VStack(spacing: 14) {
          DashFormMenuField(
            label: "Type", selection: $type,
            options: ["A", "AAAA", "CNAME", "TXT", "MX", "NS", "SRV", "CAA", "PTR"])

          DashFormField(label: "Name", text: $name)

          if isSRV {
            DashFormField(label: "Priority", text: $priorityText, keyboard: .numberPad)
            DashFormField(label: "Weight", text: $weightText, keyboard: .numberPad)
            DashFormField(label: "Port", text: $portText, keyboard: .numberPad)
            DashFormField(label: "Target", text: $target)
          } else if isCAA {
            DashFormField(label: "Flags", text: $caaFlagsText, keyboard: .numberPad)
            DashFormMenuField(label: "Tag", selection: $caaTag, options: caaTagOptions)
            DashFormField(label: "Value", text: $caaValue)
          } else {
            if isMX {
              DashFormField(label: "Priority", text: $priorityText, keyboard: .numberPad)
            }
            DashFormField(
              label: isMX ? "Mail server" : "Content",
              text: $content)
          }

          if supportsProxy {
            // Unproxying publishes the origin IP, and putting the record back
            // behind the proxy does not unpublish it — scanners keep the answer.
            DashToggleRow(
              title: "Proxied",
              subtitle: proxied ? nil : "Exposes the origin IP, permanently",
              isOn: $proxied)
          }

          DashFormMenuField(
            label: "TTL", selection: ttlSelection, options: ttlOptions.map(\.label))

          if let error {
            DashNotice(kind: .error, message: error)
          }
        }
      }
    )
  }

  /// The RFC 8659 tags, plus whatever the record already carries so an edit
  /// of an extension tag (contactemail, …) round-trips instead of rewriting it.
  private var caaTagOptions: [String] {
    var options = ["issue", "issuewild", "iodef"]
    if let existing = record?.data?.tag, !options.contains(existing) {
      options.append(existing)
    }
    return options
  }

  /// The TTLs worth offering, plus whatever the record already has. Cloudflare
  /// pins proxied records to 300s and ignores the field, so this only matters
  /// for DNS-only records — the TXT verification, the MX, the unproxied CNAME.
  /// A record set elsewhere to a value not on this list keeps it rather than
  /// being silently rewritten to Auto on the next save.
  private var ttlOptions: [(label: String, seconds: Int)] {
    var options: [(label: String, seconds: Int)] = [
      ("Auto", 1), ("1 min", 60), ("5 min", 300), ("30 min", 1800),
      ("1 hour", 3600), ("12 hours", 43200), ("1 day", 86400),
    ]
    if !options.contains(where: { $0.seconds == ttl }) {
      options.append((DashL10n.string("\(ttl)s"), ttl))
      options.sort { $0.seconds < $1.seconds }
    }
    return options
  }

  private var ttlSelection: Binding<String> {
    Binding(
      get: { ttlOptions.first { $0.seconds == ttl }?.label ?? "Auto" },
      set: { label in ttl = ttlOptions.first { $0.label == label }?.seconds ?? ttl }
    )
  }

  private func save() async {
    saving = true
    error = nil
    let input: DNSRecordInput
    if isSRV {
      guard let priority = Int(priorityText), let weight = Int(weightText),
        let port = Int(portText)
      else {
        error = DashL10n.string("Priority, weight, and port must be numbers.")
        saving = false
        return
      }
      input = DNSRecordInput(
        type: type, name: name, proxied: false, ttl: ttl, priority: priority,
        data: DNSRecordData(
          priority: priority, weight: weight, port: port,
          target: target.trimmingCharacters(in: .whitespacesAndNewlines)))
    } else if isMX {
      guard let priority = Int(priorityText) else {
        error = DashL10n.string("Priority must be a number.")
        saving = false
        return
      }
      input = DNSRecordInput(
        type: type, name: name, content: content, proxied: false, ttl: ttl, priority: priority)
    } else if isCAA {
      guard let flags = Int(caaFlagsText), (0...255).contains(flags) else {
        error = DashL10n.string("Flags must be a number between 0 and 255.")
        saving = false
        return
      }
      input = DNSRecordInput(
        type: type, name: name, proxied: false, ttl: ttl,
        data: DNSRecordData(
          flags: flags, tag: caaTag,
          value: caaValue.trimmingCharacters(in: .whitespacesAndNewlines)))
    } else {
      input = DNSRecordInput(
        type: type, name: name, content: content,
        proxied: supportsProxy ? proxied : false, ttl: ttl)
    }
    do {
      if let record {
        _ = try await model.client.updateDNSRecord(
          zoneID: zoneID, recordID: record.id, input: input)
        model.toasts.success(DashL10n.string("DNS record updated."))
      } else {
        _ = try await model.client.createDNSRecord(zoneID: zoneID, input: input)
        model.toasts.success(DashL10n.string("DNS record created."))
      }
      saved()
      dismiss()
    } catch { self.error = error.dashActionableMessage }
    saving = false
  }

  private func delete(_ record: DNSRecord) async {
    deleting = true
    error = nil
    do {
      try await model.client.deleteDNSRecord(zoneID: zoneID, recordID: record.id)
      model.toasts.success(DashL10n.string("DNS record deleted."))
      saved()
      dismiss()
    } catch {
      self.error = error.dashActionableMessage
      DashDelight.failError()
    }
    deleting = false
  }
}

struct WorkersView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @State private var workers: [WorkerScript] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !workers.isEmpty,
      retry: { Task { await load() } }
    ) {
      if workers.isEmpty {
        DashEmptyState(
          icon: SolarAsset.Content.code,
          title: DashL10n.string("No Workers yet"),
          message: DashL10n.string(
            "Deploy with Wrangler or the dashboard — manage cut-over, domains, and analytics here."
          ),
          actionTitle: "Open Workers docs",
          action: { openURL(FeatureExternalURL.workersGuide) }
        )
      } else {
        dashListCard {
          dashListCardRows(items: workers) { worker in
            DashListGroupLink(value: .worker(worker.id)) {
              DashListRow(title: worker.id, icon: SolarAsset.Content.code)
                .accessibilityLabel(worker.id)
            }
          }
        }
      }
    }
    .refreshable { await load(force: true) }.task {
      await load()
    }
    .onAppear { reloadIfInvalidated() }
  }

  /// The cache drops under this list on memory pressure while it stays alive
  /// below a child screen; refresh on return when the cache went cold.
  private func reloadIfInvalidated() {
    guard let accountID = model.activeAccountID, !workers.isEmpty else { return }
    let cached: [WorkerScript]? = model.featureCache.get(FeatureCacheKey.workers(accountID))
    if cached == nil { Task { await load(force: true) } }
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.workers(accountID)
    if !force, let cached: [WorkerScript] = model.featureCache.get(key) {
      workers = cached
      loading = false
      error = nil
      return
    }
    if workers.isEmpty { loading = true }
    error = nil
    do {
      workers = try await model.client.listWorkers(accountID: accountID)
      model.featureCache.set(key, workers)
    } catch { self.error = error.dashActionableMessage }
    loading = false
  }
}

/// One zone's route joined with its zone name for display. The worker detail
/// screen filters the account-wide cached list down to `script == name`.
struct WorkerZoneRoute: Identifiable, Hashable, Sendable {
  let id: String
  let pattern: String
  let script: String?
  let zoneName: String
}

/// A single normalized point for the worker metrics charts. CPU arrives from
/// the API in microseconds and is stored here in milliseconds.
struct WorkerAnalyticsChartPoint: Identifiable, Hashable {
  let date: Date
  let requests: Int
  let errors: Int
  let cpuTimeP50Ms: Double

  var id: Date { date }
}

/// Which chart the worker metrics card shows below the stat tiles.
private enum WorkerMetricsTab: Hashable { case requests, cpu }

/// Pure conversion + accessibility strings, so date parsing and the µs → ms
/// conversion are unit-tested away from the view. `points(from:)` returns
/// ascending, dropping unparseable stamps.
enum WorkerAnalyticsChartModel {
  static func points(from buckets: [WorkerAnalyticsBucket]) -> [WorkerAnalyticsChartPoint] {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime]
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return buckets.compactMap { bucket in
      guard
        let date = parser.date(from: bucket.datetime) ?? fractional.date(from: bucket.datetime)
      else { return nil }
      return WorkerAnalyticsChartPoint(
        date: date,
        requests: bucket.requests,
        errors: bucket.errors,
        cpuTimeP50Ms: bucket.cpuTimeP50Us / 1000)
    }
    .sorted { $0.date < $1.date }
  }

  static func requestsAccessibilitySummary(requests: Int, errors: Int) -> String {
    if errors > 0 {
      return DashL10n.string(
        "Invocations chart for the last 24 hours. Total \(requests.formatted()) requests, \(errors.formatted()) errors."
      )
    }
    return DashL10n.string(
      "Invocations chart for the last 24 hours. Total \(requests.formatted()) requests.")
  }

  static func cpuAccessibilitySummary(points: [WorkerAnalyticsChartPoint]) -> String {
    let peak = points.map(\.cpuTimeP50Ms).max() ?? 0
    return DashL10n.string(
      "CPU time chart for the last 24 hours. Peak median \(String(format: "%.1f", peak)) milliseconds."
    )
  }
}

struct WorkerDetailView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @AppStorage(RecentResources.key) private var recentsRaw = ""
  let name: String
  @State private var analytics: WorkerAnalyticsPayload?
  @State private var analyticsError: String?
  @State private var metricsTab: WorkerMetricsTab = .requests
  @State private var selectedMetricSeriesID: String?
  @State private var deployments: [WorkerDeploymentSummary] = []
  @State private var deploymentError: String?
  @State private var selectedDeployment: WorkerDeploymentSummary?
  @State private var confirmingActivation = false
  @State private var activatingDeployment = false
  @State private var activationError: String?
  @State private var domains: [WorkerDomain] = []
  @State private var domainsError: String?
  @State private var selectedDomain: WorkerDomain?
  @State private var routes: [WorkerZoneRoute] = []
  @State private var routesError: String?
  @State private var selectedRoute: WorkerZoneRoute?
  @State private var addsDomain = false
  @State private var deletingDomain = false
  @State private var deleteDomainError: String?
  @State private var error: String?
  @State private var loading = true
  @State private var loadedSubdomain = false
  @State private var subdomainEnabled = false
  @State private var subdomainUpdating = false
  /// Composed `{script}.{account}.workers.dev` when the account subdomain is known.
  @State private var workersDevHostname: String?
  /// False until the first load settles — keeps Cold skeleton even when cache
  /// fills subdomain/deployments mid-flight (avoids a premature Updating… strip).
  @State private var hasPresentedContent = false

  private var hasPrimaryContent: Bool {
    !deployments.isEmpty || loadedSubdomain || analytics != nil
  }

  private var workersDevSubtitle: String? {
    if let workersDevHostname { return workersDevHostname }
    if !featureAllowsWrites {
      return "Grant Workers write access to change this setting."
    }
    return nil
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: hasPresentedContent,
      retry: { Task { await load(force: true) } }
    ) {
      if let analytics {
        workerMetricsCard(analytics)
      } else if let analyticsError {
        DashNotice(kind: .warning, message: analyticsError)
      }
      deploymentsGroup
        .dashSectionBoundary(analytics != nil || analyticsError != nil)
      DashToggleRow(
        title: "workers.dev",
        subtitle: workersDevSubtitle,
        isOn: subdomainBinding,
        isEnabled: loadedSubdomain && featureAllowsWrites,
        isLoading: subdomainUpdating
      )
      .dashSectionBoundary()
      domainsGroup
        .dashSectionBoundary()
    }
    .detailHeader(
      icon: .solar(SolarAsset.Content.code),
      title: name,
      tint: FeatureVisualIdentity.heroColor(for: .workers)
    )
    .task {
      if let accountID = model.activeAccountID {
        recentsRaw = RecentResources.recording(
          RecentResource(accountID: accountID, kind: .worker, resourceID: name, title: name),
          in: recentsRaw)
      }
      await load()
    }
    .refreshable { await load(force: true) }
    .dashTray(
      item: $selectedDeployment,
      title: { workerDeploymentTitle($0) },
      content: { deployment in
        workerDeploymentTray(deployment)
      }
    )
    .dashTray(isPresented: $addsDomain, title: "Add custom domain") {
      WorkerAddDomainForm(service: name) {
        await loadDomains(force: true)
      }
    }
    .dashTray(
      item: $selectedRoute,
      title: { $0.pattern },
      content: { route in
        DashDetailTray(
          fields: [
            DashDetailField(label: "Pattern", value: route.pattern, mono: true),
            DashDetailField(label: "Zone", value: route.zoneName),
            DashDetailField(label: "Managed by", value: "wrangler or the zone's Workers Routes"),
          ]
        )
      }
    )
    .dashTray(
      item: $selectedDomain,
      title: { $0.hostname },
      content: { domain in
        DashDetailTray(
          fields: [
            DashDetailField(label: "Hostname", value: domain.hostname),
            DashDetailField(label: "Zone", value: domain.zoneName),
            DashDetailField(label: "Environment", value: domain.environment ?? "production"),
          ],
          deleteMessage: featureAllowsWrites
            ? DashL10n.string(
              "Detaches \(domain.hostname) from \(name). DNS for the hostname is left in place."
            )
            : nil,
          isDeleting: deletingDomain,
          deleteError: deleteDomainError,
          onDelete: featureAllowsWrites ? { Task { await detachDomain(domain) } } : nil
        )
      }
    )
  }

  private var subdomainBinding: Binding<Bool> {
    Binding(
      get: { subdomainEnabled },
      set: { enabled in
        guard loadedSubdomain, featureAllowsWrites, !subdomainUpdating else { return }
        subdomainEnabled = enabled
        Task { await setSubdomain(enabled) }
      })
  }

  @ViewBuilder private var deploymentsGroup: some View {
    DashListGroup(title: "Deployments") {
      if deployments.isEmpty {
        DashCard {
          if let deploymentError {
            DashNotice(kind: .warning, message: deploymentError)
          } else {
            Text("No deployments yet.")
              .dashTextStyle(.footnote)
              .foregroundStyle(DashTheme.subtle)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      } else {
        dashListCard {
          dashListCardRows(items: deployments) { deployment in
            let isActive = deployment.id == deployments.first?.id
            Button {
              activationError = nil
              confirmingActivation = false
              selectedDeployment = deployment
            } label: {
              DashListRow(
                title: workerDeploymentTitle(deployment),
                subtitle: workerDeploymentRowSubtitle(deployment, isActive: isActive),
                icon: SolarAsset.Content.code,
                iconColor: isActive
                  ? FeatureVisualIdentity.catalogColor(for: .workers) : DashTheme.iconMuted,
                showsChevron: false
              ) {
                if isActive { StatusBadge(text: "Active") }
              }
            }
            .buttonStyle(DashSurfaceButtonStyle())
            .accessibilityLabel(
              workerDeploymentAccessibilityLabel(deployment, isActive: isActive))
          }
        }
      }
    }
  }

  @ViewBuilder private var domainsGroup: some View {
    DashListGroup(
      title: "Domains & Routes",
      actionTitle: featureAllowsWrites ? "Add" : nil,
      actionIcon: featureAllowsWrites ? SolarAsset.plus : nil,
      action: featureAllowsWrites ? { addsDomain = true } : nil
    ) {
      if let domainsError, domains.isEmpty {
        DashNotice(kind: .warning, message: domainsError)
      } else if domains.isEmpty, routes.isEmpty, routesError == nil {
        DashCard {
          Text("Route a hostname from one of this account's zones to this Worker.")
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      // Sibling cards — one ForEach each — so inset stays on ForEach, not a
      // TupleView that would re-eagerize both lists inside LazyVStack.
      if !domains.isEmpty {
        dashListCard {
          dashListCardRows(items: domains) { domain in
            Button {
              deleteDomainError = nil
              selectedDomain = domain
            } label: {
              DashListRow(
                title: domain.hostname,
                subtitle: workerDomainSubtitle(domain),
                icon: SolarAsset.Content.globe,
                iconColor: FeatureVisualIdentity.catalogColor(for: .workers),
                showsChevron: false
              )
            }
            .buttonStyle(DashSurfaceButtonStyle())
            .accessibilityLabel("\(domain.hostname), \(workerDomainSubtitle(domain))")
          }
        }
      }
      if !routes.isEmpty {
        dashListCard {
          dashListCardRows(items: routes) { route in
            Button {
              selectedRoute = route
            } label: {
              DashListRow(
                title: route.pattern,
                subtitle: route.zoneName,
                icon: SolarAsset.Content.globe,
                iconColor: DashTheme.iconMuted,
                showsChevron: false
              ) {
                StatusBadge(text: "Route")
              }
            }
            .buttonStyle(DashSurfaceButtonStyle())
            .accessibilityLabel("\(route.pattern), \(route.zoneName), Route")
          }
        }
      }
      if let routesError, routes.isEmpty {
        DashNotice(kind: .warning, message: routesError)
      }
    }
  }

  @ViewBuilder private func workerDeploymentTray(_ deployment: WorkerDeploymentSummary) -> some View
  {
    let isActive = deployment.id == deployments.first?.id
    let versionID = workerPrimaryVersionID(deployment)
    let canActivate = featureAllowsWrites && !isActive && versionID != nil
    DashConfirmMorph(
      confirming: $confirmingActivation,
      message: versionID.map {
        DashL10n.string(
          "Switch all traffic to version \($0.prefix(8)). Gradual rollouts are not supported.")
      },
      isBusy: activatingDeployment,
      actionTitle: canActivate ? "Make active" : nil,
      confirmingActionTitle: "Switch traffic",
      confirmingActionRole: .destructive,
      errorMessage: activationError,
      action: {
        if confirmingActivation {
          Task { await activate(deployment) }
        } else {
          confirmingActivation = true
        }
      },
      content: {
        VStack(alignment: .leading, spacing: 12) {
          Text(workerDeploymentTitle(deployment))
            .dashTextStyle(.bodySemibold)
            .foregroundStyle(DashTheme.text)
          Text(workerDeploymentAgeText(deployment.createdOn))
            .dashTextStyle(.caption)
            .foregroundStyle(DashTheme.subtle)
          Text(workerDeploymentTrafficText(deployment))
            .dashTextStyle(.caption)
            .foregroundStyle(DashTheme.rowSubtitle)
          if let author = deployment.authorEmail {
            Text(author)
              .dashTextStyle(.caption)
              .foregroundStyle(DashTheme.placeholder)
          }
          if isActive {
            StatusBadge(text: "Active")
          } else if !featureAllowsWrites {
            DashNotice(kind: .warning, message: "Grant Workers write access to switch deployments.")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    )
  }

  private func workerMetricsCard(_ summary: WorkerAnalyticsPayload) -> some View {
    let chartPoints = WorkerAnalyticsChartModel.points(from: summary.points)
    return DashGlassCard {
      VStack(alignment: .leading, spacing: 10) {
        // Tiles combine into one accessibility element; the charts below stay
        // their own elements so DitherAccessibility keeps working.
        VStack(alignment: .leading, spacing: 10) {
          Text("Last 24 hours")
            .dashTextStyle(.footnoteSemibold)
            .foregroundStyle(DashTheme.subtle)
          if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
              workerMetric("Requests", summary.requests.formatted())
              workerMetric("Errors", summary.errors.formatted())
              workerMetric(
                "CPU p50",
                String(format: "%.1f ms", summary.cpuTimeP50Us / 1000))
            }
          } else {
            HStack(spacing: 12) {
              workerMetric("Requests", summary.requests.formatted())
              workerMetric("Errors", summary.errors.formatted())
              workerMetric(
                "CPU p50",
                String(format: "%.1f ms", summary.cpuTimeP50Us / 1000))
            }
          }
          if summary.requests > 0 {
            let rate = Double(summary.errors) / Double(summary.requests)
            Text("Error rate \(String(format: "%.2f%%", rate * 100))")
              .dashTextStyle(.caption)
              .foregroundStyle(rate > 0.05 ? DashTheme.danger : DashTheme.subtle)
          }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          DashL10n.string("Worker metrics. \(summary.requests) requests, \(summary.errors) errors")
        )
        if !chartPoints.isEmpty {
          DashTextTabs(
            items: [("Requests", WorkerMetricsTab.requests), ("CPU", .cpu)],
            selection: $metricsTab)
          switch metricsTab {
          case .requests:
            workerRequestsChart(summary, points: chartPoints)
          case .cpu:
            workerCPUChart(chartPoints)
          }
        }
      }
    }
    .onChange(of: metricsTab) { selectedMetricSeriesID = nil }
    .onChange(of: analytics) { selectedMetricSeriesID = nil }
  }

  private func workerRequestsChart(
    _ summary: WorkerAnalyticsPayload, points: [WorkerAnalyticsChartPoint]
  ) -> some View {
    let showsErrors = summary.errors > 0
    var series = [
      DitherSeries(
        id: "requests",
        label: DashL10n.ui("Requests"),
        color: DashTheme.DitherChart.brand(
          colorScheme: colorScheme,
          contrast: colorSchemeContrast),
        variant: .gradient)
    ]
    if showsErrors {
      series.append(
        DitherSeries(
          id: "errors",
          label: DashL10n.ui("Errors"),
          color: DashTheme.DitherChart.warning(
            colorScheme: colorScheme,
            contrast: colorSchemeContrast),
          variant: .hatched))
    }
    return DitherAreaChart(
      data: workerDitherData(points),
      series: series,
      options: DashTheme.DitherChart.options(
        showsLegend: showsErrors,
        accessibility: DitherAccessibility(
          title: DashL10n.ui("Worker requests"),
          summary: WorkerAnalyticsChartModel.requestsAccessibilitySummary(
            requests: summary.requests,
            errors: summary.errors),
          categoryAxisLabel: DashL10n.ui("Time"),
          valueAxisLabel: DashL10n.ui("Events"))),
      highlighted: selectedMetricSeriesID != nil,
      selection: $selectedMetricSeriesID
    )
    .frame(
      height: DashTheme.DitherChart.height(
        dynamicTypeSize: dynamicTypeSize,
        showsLegend: showsErrors))
  }

  private func workerCPUChart(_ points: [WorkerAnalyticsChartPoint]) -> some View {
    DitherLineChart(
      data: workerDitherData(points),
      series: [
        DitherSeries(
          id: "cpu",
          label: DashL10n.ui("CPU p50"),
          color: DashTheme.DitherChart.accentPurple(
            colorScheme: colorScheme,
            contrast: colorSchemeContrast),
          variant: .gradient)
      ],
      options: DashTheme.DitherChart.options(
        showsLegend: false,
        accessibility: DitherAccessibility(
          title: DashL10n.ui("Worker CPU time"),
          summary: WorkerAnalyticsChartModel.cpuAccessibilitySummary(points: points),
          categoryAxisLabel: DashL10n.ui("Time"),
          valueAxisLabel: DashL10n.ui("Milliseconds"))),
      highlighted: selectedMetricSeriesID != nil,
      selection: $selectedMetricSeriesID
    )
    .frame(
      height: DashTheme.DitherChart.height(
        dynamicTypeSize: dynamicTypeSize,
        showsLegend: false))
  }

  private func workerDitherData(_ points: [WorkerAnalyticsChartPoint]) -> [DitherDatum] {
    points.map { point in
      DitherDatum(
        id: point.date.ISO8601Format(),
        label: point.date.formatted(workerChartAxisFormat),
        values: [
          "requests": Double(point.requests),
          "errors": Double(point.errors),
          "cpu": point.cpuTimeP50Ms,
        ])
    }
  }

  private var workerChartAxisFormat: Date.FormatStyle {
    Date.FormatStyle.dateTime.hour().minute().locale(DashL10n.activeLocale)
  }

  private func workerMetric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .dashTextStyle(.sectionTitle)
        .foregroundStyle(DashTheme.text)
        .monospacedDigit()
      Text(DashL10n.ui(title))
        .dashTextStyle(.caption)
        .foregroundStyle(DashTheme.subtle)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else {
      loading = false
      return
    }
    if !hasPresentedContent || force { loading = true }
    error = nil
    let key = FeatureCacheKey.workerSubdomain(accountID: accountID, name: name)
    if !force, let cached: Bool = model.featureCache.get(key) {
      subdomainEnabled = cached
      loadedSubdomain = true
    } else {
      do {
        subdomainEnabled = try await model.client.getWorkerSubdomain(
          accountID: accountID, name: name
        ).enabled
        loadedSubdomain = true
        model.featureCache.set(key, subdomainEnabled)
      } catch {
        self.error = error.dashActionableMessage
      }
    }
    await loadWorkersDevHostname(accountID: accountID, force: force)
    await loadDeployments(accountID: accountID, force: force)
    await loadAnalytics(accountID: accountID, force: force)
    await loadDomains(accountID: accountID, force: force)
    await loadRoutes(accountID: accountID, force: force)
    loading = false
    // Promote to Warm only after the first settle — not when fragments arrive.
    if hasPrimaryContent || error == nil {
      hasPresentedContent = true
    }
  }

  /// Soft-fails: the toggle still works without the composed hostname.
  private func loadWorkersDevHostname(accountID: String, force: Bool) async {
    let key = FeatureCacheKey.workersAccountSubdomain(accountID)
    if !force, let cached: String = model.featureCache.get(key) {
      workersDevHostname = WorkersAccountSubdomain(subdomain: cached).hostname(forScript: name)
      return
    }
    do {
      let account = try await model.client.getWorkersAccountSubdomain(accountID: accountID)
      model.featureCache.set(key, account.subdomain)
      workersDevHostname = account.hostname(forScript: name)
    } catch {
      // Keep any previously shown hostname; otherwise leave the caption empty.
    }
  }

  private func loadDeployments(accountID: String, force: Bool) async {
    let key = FeatureCacheKey.workerDeployments(accountID: accountID, name: name)
    if !force, let cached: [WorkerDeploymentSummary] = model.featureCache.get(key) {
      deployments = cached
      deploymentError = nil
      return
    }
    do {
      deployments = try await model.client.listWorkerDeployments(
        accountID: accountID, scriptName: name)
      deploymentError = nil
      model.featureCache.set(key, deployments)
    } catch {
      deploymentError = error.dashActionableMessage
    }
  }

  private func loadAnalytics(accountID: String, force: Bool) async {
    let key = FeatureCacheKey.workerAnalytics(accountID: accountID, name: name)
    if !force, let cached: WorkerAnalyticsPayload = model.featureCache.get(key) {
      analytics = cached
      return
    }
    do {
      let summary = try await model.client.workerAnalytics(
        accountID: accountID, scriptName: name, hours: 24)
      analytics = summary
      analyticsError = nil
      model.featureCache.set(key, summary)
    } catch {
      analyticsError = error.dashActionableMessage
    }
  }

  private func loadDomains(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    await loadDomains(accountID: accountID, force: force)
  }

  private func loadDomains(accountID: String, force: Bool) async {
    let key = FeatureCacheKey.workerDomains(accountID: accountID, name: name)
    if !force, let cached: [WorkerDomain] = model.featureCache.get(key) {
      domains = cached
      domainsError = nil
      return
    }
    do {
      domains = try await model.client.listWorkerDomains(accountID: accountID, service: name)
      domainsError = nil
      model.featureCache.set(key, domains)
    } catch {
      domainsError = error.dashActionableMessage
    }
  }

  /// Routes live per zone, so discovery fans out across the account's zones
  /// once per session and the combined list is cached account-wide. Partial
  /// zone failures keep whatever was found; only a total wipe-out surfaces.
  private func loadRoutes(accountID: String, force: Bool) async {
    let key = FeatureCacheKey.workerRoutes(accountID)
    if !force, let cached: [WorkerZoneRoute] = model.featureCache.get(key) {
      routes = cached.filter { $0.script == name }
      routesError = nil
      return
    }
    let zones: [CloudflareZone]
    if let cachedZones: [CloudflareZone] = model.featureCache.get(FeatureCacheKey.zones(accountID))
    {
      zones = cachedZones
    } else {
      do {
        zones = try await model.client.listZones(accountID: accountID, perPage: 50).items
      } catch {
        routesError = error.dashActionableMessage
        return
      }
    }
    let client = model.client
    var collected: [WorkerZoneRoute] = []
    var firstFailure: (any Error)?
    var failureCount = 0
    await withTaskGroup(of: Result<[WorkerZoneRoute], any Error>.self) { group in
      for zone in zones {
        group.addTask {
          do {
            let zoneRoutes = try await client.listWorkerRoutes(zoneID: zone.id)
            return .success(
              zoneRoutes.map {
                WorkerZoneRoute(
                  id: $0.id, pattern: $0.pattern, script: $0.script, zoneName: zone.name)
              })
          } catch {
            return .failure(error)
          }
        }
      }
      for await result in group {
        switch result {
        case .success(let zoneRoutes): collected.append(contentsOf: zoneRoutes)
        case .failure(let error):
          failureCount += 1
          if firstFailure == nil { firstFailure = error }
        }
      }
    }
    if let firstFailure, failureCount == zones.count, !zones.isEmpty {
      routesError = firstFailure.dashActionableMessage
      return
    }
    collected.sort { $0.pattern < $1.pattern }
    routes = collected.filter { $0.script == name }
    routesError = nil
    model.featureCache.set(key, collected)
  }

  private func activate(_ deployment: WorkerDeploymentSummary) async {
    guard let accountID = model.activeAccountID,
      let versionID = workerPrimaryVersionID(deployment)
    else { return }
    activatingDeployment = true
    activationError = nil
    defer { activatingDeployment = false }
    do {
      _ = try await model.client.createWorkerDeployment(
        accountID: accountID, scriptName: name, versionID: versionID,
        message: "Activated from Dash")
      model.featureCache.remove(
        FeatureCacheKey.workerDeployments(accountID: accountID, name: name))
      await loadDeployments(accountID: accountID, force: true)
      confirmingActivation = false
      selectedDeployment = nil
      model.toasts.success(DashL10n.string("Deployment activated."))
    } catch {
      activationError = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func detachDomain(_ domain: WorkerDomain) async {
    guard let accountID = model.activeAccountID else { return }
    deletingDomain = true
    deleteDomainError = nil
    defer { deletingDomain = false }
    do {
      try await model.client.detachWorkerDomain(accountID: accountID, domainID: domain.id)
      model.featureCache.remove(FeatureCacheKey.workerDomains(accountID: accountID, name: name))
      selectedDomain = nil
      model.toasts.success(DashL10n.string("Deleted successfully."))
      await loadDomains(accountID: accountID, force: true)
    } catch {
      deleteDomainError = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func setSubdomain(_ enabled: Bool) async {
    guard let accountID = model.activeAccountID else { return }
    subdomainUpdating = true
    defer { subdomainUpdating = false }
    do {
      let result = try await model.client.setWorkerSubdomain(
        accountID: accountID, name: name, enabled: enabled)
      subdomainEnabled = result.enabled
      model.featureCache.set(
        FeatureCacheKey.workerSubdomain(accountID: accountID, name: name), result.enabled)
      DashDelight.celebrateSuccess()
    } catch {
      subdomainEnabled = !enabled
      model.toasts.error(error.dashActionableMessage)
    }
  }
}

private func workerPrimaryVersionID(_ deployment: WorkerDeploymentSummary) -> String? {
  if let full = deployment.versions.first(where: { $0.percentage >= 100 }) {
    return full.versionID
  }
  return deployment.versions.first?.versionID
}

private func workerDeploymentAccessibilityLabel(
  _ deployment: WorkerDeploymentSummary, isActive: Bool
) -> String {
  let title = workerDeploymentTitle(deployment)
  return "\(title), \(workerDeploymentRowSubtitle(deployment, isActive: isActive))"
}

private func workerDeploymentTitle(_ deployment: WorkerDeploymentSummary) -> String {
  if let message = deployment.annotations?.message, !message.isEmpty { return message }
  switch deployment.source.lowercased() {
  case "api": return DashL10n.string("API deployment")
  case "wrangler": return DashL10n.string("Wrangler deployment")
  default: return DashL10n.string("Deployment")
  }
}

private func workerDomainSubtitle(_ domain: WorkerDomain) -> String {
  domain.hostname.caseInsensitiveCompare(domain.zoneName) == .orderedSame
    ? DashL10n.string("Custom domain") : domain.zoneName
}

private func workerDeploymentRowSubtitle(
  _ deployment: WorkerDeploymentSummary, isActive: Bool
) -> String {
  let age = workerDeploymentAgeText(deployment.createdOn)
  if let version = workerPrimaryVersionID(deployment) {
    let mark = isActive ? "Active · " : ""
    return "\(mark)\(age) · \(version.prefix(8))"
  }
  return age
}

struct WorkerAddDomainForm: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let service: String
  let onAdded: () async -> Void
  @State private var hostname = ""
  @State private var zones: [CloudflareZone] = []
  @State private var zonesLoaded = false
  @State private var saving = false
  @State private var error: String?

  private var normalizedHost: String {
    hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private var matchedZone: CloudflareZone? {
    let host = normalizedHost
    guard !host.isEmpty else { return nil }
    return
      zones
      .filter { host == $0.name || host.hasSuffix("." + $0.name) }
      .max { $0.name.count < $1.name.count }
  }

  var body: some View {
    DashFormSheet(
      saveTitle: "Add domain",
      isSaving: saving,
      canSave: matchedZone != nil,
      onSave: { Task { await save() } },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          DashFormField(
            label: "Hostname",
            text: $hostname,
            keyboard: .URL,
            contentType: .URL)
          if let zone = matchedZone {
            Text("Will route through the \(zone.name) zone.")
              .dashTextStyle(.footnote)
              .foregroundStyle(DashTheme.subtle)
          } else if !normalizedHost.isEmpty, zonesLoaded {
            DashNotice(
              kind: .warning,
              message: "No zone in this account matches that hostname.")
          }
          if let error {
            DashNotice(kind: .error, message: error)
          }
          Text(
            "Cloudflare provisions the edge certificate. DNS for the hostname must already point at this account."
          )
          .dashTextStyle(.caption)
          .foregroundStyle(DashTheme.subtle)
        }
      }
    )
    .task { await loadZones() }
  }

  private func loadZones() async {
    guard let accountID = model.activeAccountID else { return }
    if let cached: [CloudflareZone] = model.featureCache.get(FeatureCacheKey.zones(accountID)) {
      zones = cached
      zonesLoaded = true
      return
    }
    zones = (try? await model.client.listZones(accountID: accountID, perPage: 50).items) ?? []
    zonesLoaded = true
  }

  private func save() async {
    guard let accountID = model.activeAccountID, let zone = matchedZone else { return }
    saving = true
    defer { saving = false }
    do {
      try await model.client.attachWorkerDomain(
        accountID: accountID, hostname: normalizedHost, service: service,
        zoneID: zone.id, zoneName: zone.name)
      model.featureCache.remove(
        FeatureCacheKey.workerDomains(accountID: accountID, name: service))
      model.toasts.success(DashL10n.string("Added successfully."))
      await onAdded()
      dismiss()
    } catch {
      self.error = error.dashActionableMessage
    }
  }
}

private func workerDeploymentAgeText(_ value: String, now: Date = .now) -> String {
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let plain = ISO8601DateFormatter()
  plain.formatOptions = [.withInternetDateTime]
  guard let date = fractional.date(from: value) ?? plain.date(from: value) else {
    return "Deployed \(value)"
  }
  let formatter = RelativeDateTimeFormatter()
  formatter.unitsStyle = .abbreviated
  return "Deployed \(formatter.localizedString(for: date, relativeTo: now))"
}

private func workerDeploymentTrafficText(_ deployment: WorkerDeploymentSummary) -> String {
  guard !deployment.versions.isEmpty else { return deployment.source.capitalized }
  if deployment.versions.count == 1, let version = deployment.versions.first {
    return "Version \(version.versionID.prefix(8)) · \(version.percentage.formatted())% traffic"
  }
  return "Traffic split across \(deployment.versions.count) versions"
}

struct CachePurgeView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let zoneID: String
  @State private var url = ""
  @State private var status: String?
  @State private var failed = false
  @State private var working = false
  @State private var showsMore = false

  var body: some View {
    DashFeatureScreen {
      ScrollView {
        VStack(spacing: DashTheme.Spacing.section) {
          DashCard {
            VStack(alignment: .leading, spacing: 16) {
              VStack(alignment: .leading, spacing: 4) {
                Text("Purge by URL")
                  .dashTextStyle(.sectionTitle)
                  .foregroundStyle(DashTheme.strong)
                Text("Remove one cached asset without disturbing the rest of the domain.")
                  .dashTextStyle(.supporting)
                  .foregroundStyle(DashTheme.subtle)
              }
              DashFormField(
                label: "Asset URL",
                text: $url,
                keyboard: .URL,
                contentType: .URL)
              DashPillButton(title: "Purge URL", isLoading: working, isEnabled: !url.isEmpty) {
                Task { await purge(files: [url]) }
              }
            }
          }

          if let status {
            DashNotice(kind: failed ? .error : .success, message: status)
              .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
          }
        }
        .padding(.horizontal, DashTheme.Spacing.screen)
        .padding(.top, DashTheme.Spacing.section)
        .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
        .animation(
          reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.quick, value: status)
      }
      .dashKeyboardDismissal()
    }
    .detailHeader(icon: .solar(SolarAsset.Content.bolt), title: "Cache")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        DashMoreButton(isPresented: $showsMore)
      }
      .dashSeparateToolbarBackground()
    }
    .dashMoreMenu(
      isPresented: $showsMore,
      title: "Purge cache",
      actions: [
        DashDangerAction(
          title: "Purge everything",
          message:
            "This removes every cached asset in this domain. Requests may temporarily reach your origin.",
          confirmTitle: "Purge everything"
        ) {
          await purge(files: nil)
        }
      ]
    )
  }

  private func purge(files: [String]?) async {
    working = true
    do {
      try await model.client.purgeCache(zoneID: zoneID, files: files)
      status = DashL10n.string("Cache purged.")
      failed = false
      model.toasts.success(DashL10n.string("Cache purged."))
    } catch {
      status = error.dashActionableMessage
      failed = true
    }
    working = false
  }
}

/// Dashboard-style buckets for the flat zone-settings list.
/// The settings this screen offers, in display order.
///
/// Cloudflare returns 50-60 settings per zone; all but these are decisions you
/// make once, from a laptop, when you set the zone up. These five are the ones
/// worth reaching for away from your desk — the top two are the same pair the
/// App Intents expose.
///
/// Values whose valid range depends on the zone's plan stay out: browser_cache_ttl
/// rejects anything under two hours on Free, so a fixed menu would offer choices
/// that can only fail.
private let curatedZoneSettings: [String] = [
  "security_level",
  "development_mode",
  "ssl",
  "always_online",
  "always_use_https",
]

/// Enum-valued settings the API accepts as plain strings; everything listed here
/// renders as an editable menu instead of a read-only value row. Values come
/// from Cloudflare's OpenAPI schema (zones_*_value enums). The rest of
/// `curatedZoneSettings` is on/off.
private let zoneSettingOptions: [String: [String]] = [
  "ssl": ["off", "flexible", "full", "strict"],
  "security_level": ["off", "essentially_off", "low", "medium", "high", "under_attack"],
]

struct ZoneSettingsView: View {
  @Environment(AppModel.self) private var model
  let zoneID: String
  @State private var settings: [ZoneSetting] = []
  @State private var error: String?
  @State private var loading = true
  @State private var updatingSettingIDs: Set<String> = []

  var body: some View {
    DashFeatureList(
      isLoading: loading, error: error, hasContent: !curated.isEmpty,
      retry: { Task { await load() } }
    ) {
      DashCard {
        Text(
          DashL10n.string(
            "Removing a domain isn't available in Dash. Use the Cloudflare dashboard."
          )
        )
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      DashSurfaceStack {
        ForEach(curated) { setting in
          settingRow(setting)
        }
      }
      .dashSectionBoundary()
    }
    .detailHeader(icon: .solar(SolarAsset.Content.settings), title: "Settings")
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  /// `curatedZoneSettings` order, not response order, and silently short when a
  /// plan omits one.
  private var curated: [ZoneSetting] {
    curatedZoneSettings.compactMap { id in settings.first { $0.id == id } }
  }

  @ViewBuilder
  private func settingRow(_ setting: ZoneSetting) -> some View {
    if setting.editable == false {
      // Some settings are readable but locked by plan. Show the value rather
      // than a control that can only fail.
      DashValueCard(title: setting.displayTitle, value: setting.value.displayText)
    } else {
      switch setting.value {
      case .string(let value):
        // The enum map wins over the on/off toggle: security_level reads "high"
        // or "off" but accepts six states.
        if let options = zoneSettingOptions[setting.id] {
          DashMenuRow(
            title: setting.displayTitle,
            value: value,
            options: options,
            isEnabled: !updatingSettingIDs.contains(setting.id),
            isLoading: updatingSettingIDs.contains(setting.id)
          ) { chosen in
            scheduleUpdate(setting, value: .string(chosen))
          }
        } else if value == "on" || value == "off" {
          // Cloudflare encodes most binary zone settings as "on"/"off" strings,
          // not booleans — render them as the switches they are.
          DashToggleRow(
            title: setting.displayTitle,
            isOn: Binding(
              get: { value == "on" },
              set: { enabled in
                scheduleUpdate(setting, value: .string(enabled ? "on" : "off"))
              }),
            isEnabled: !updatingSettingIDs.contains(setting.id),
            isLoading: updatingSettingIDs.contains(setting.id)
          )
        } else {
          DashValueCard(title: setting.displayTitle, value: DashL10n.ui(value))
        }
      case .bool(let enabled):
        DashToggleRow(
          title: setting.displayTitle,
          isOn: Binding(
            get: { enabled },
            set: { value in scheduleUpdate(setting, value: .bool(value)) }),
          isEnabled: !updatingSettingIDs.contains(setting.id),
          isLoading: updatingSettingIDs.contains(setting.id)
        )
      default:
        DashValueCard(title: setting.displayTitle, value: setting.value.displayText)
      }
    }
  }

  private func load(force: Bool = false) async {
    let key = FeatureCacheKey.zoneSettings(zoneID)
    if !force, let cached: [ZoneSetting] = model.featureCache.get(key) {
      settings = cached
      error = nil
      loading = false
      return
    }
    do {
      settings = try await model.client.listZoneSettings(zoneID: zoneID)
      model.featureCache.set(key, settings)
      error = nil
    } catch { self.error = error.dashActionableMessage }
    loading = false
  }

  /// Flips local state immediately, then commits over the network.
  private func scheduleUpdate(_ setting: ZoneSetting, value: JSONValue) {
    guard !updatingSettingIDs.contains(setting.id) else { return }
    guard let index = settings.firstIndex(where: { $0.id == setting.id }) else { return }
    let previous = settings[index]
    settings[index] = previous.withValue(value)
    updatingSettingIDs.insert(setting.id)
    error = nil
    Task { await commitUpdate(settingID: setting.id, value: value, previous: previous) }
  }

  private func commitUpdate(settingID: String, value: JSONValue, previous: ZoneSetting) async {
    do {
      let updated = try await model.client.updateZoneSetting(
        zoneID: zoneID, settingID: settingID, value: value)
      if let latest = settings.firstIndex(where: { $0.id == settingID }) {
        settings[latest] = updated
      }
      model.featureCache.set(FeatureCacheKey.zoneSettings(zoneID), settings)
      DashDelight.celebrateSuccess()
    } catch {
      if let latest = settings.firstIndex(where: { $0.id == settingID }) {
        settings[latest] = previous
      }
      model.toasts.error(error.dashActionableMessage)
    }
    updatingSettingIDs.remove(settingID)
  }
}

extension ZoneSetting {
  fileprivate var displayTitle: String {
    zoneSettingDisplayTitle(id)
  }
}

func zoneSettingDisplayTitle(_ id: String) -> String {
  switch id {
  case "ssl": "SSL"
  case "always_use_https": "Always Use HTTPS"
  case "min_tls_version": "Minimum TLS version"
  default: id.replacingOccurrences(of: "_", with: " ").capitalized
  }
}

extension JSONValue {
  var displayText: String {
    switch self {
    case .array(let values):
      values.isEmpty
        ? DashL10n.string("None") : values.map(\.displayText).joined(separator: ", ")
    case .bool(let value): value ? DashL10n.string("On") : DashL10n.string("Off")
    case .null: DashL10n.string("Not set")
    case .number(let value):
      value.rounded() == value ? String(Int(value)) : value.formatted()
    case .object(let value):
      value.isEmpty ? DashL10n.string("None") : DashL10n.string("\(value.count) values")
    case .string(let value): value
    }
  }
}

struct AuditLogView: View {
  @Environment(AppModel.self) private var model
  @State private var entries: [AuditLogEntry] = []
  @State private var loading = true
  @State private var error: String?

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !entries.isEmpty,
      retry: { Task { await load(force: true) } }
    ) {
      if entries.isEmpty {
        DashEmptyState(
          icon: SolarAsset.Content.shieldCheck,
          title: "No audit events",
          message: "Account activity from the last seven days will show up here."
        )
      } else {
        dashListCard {
          dashListCardRows(items: entries) { entry in
            DashListRow(
              title: DashL10n.ui(entry.title),
              subtitle: auditSubtitle(entry),
              icon: SolarAsset.Content.shieldCheck,
              showsChevron: false
            )
          }
        }
      }
    }
    .detailHeader(icon: .solar(SolarAsset.Content.shieldCheck), title: "Audit log")
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  /// Mirrors `AuditLogEntry.subtitle`, but renders the ISO 8601 "when" stamp
  /// as a localized date instead of the raw API string.
  private func auditSubtitle(_ entry: AuditLogEntry) -> String? {
    var parts: [String] = []
    if let who = entry.actor?.email ?? entry.actor?.type { parts.append(who) }
    if let what = entry.resource?.product ?? entry.resource?.type { parts.append(what) }
    if let when = entry.occurredAt { parts.append(auditDateLabel(when)) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.auditLogs(accountID)
    if !force, let cached: [AuditLogEntry] = model.featureCache.get(key) {
      entries = cached
      loading = false
      error = nil
      return
    }
    if entries.isEmpty { loading = true }
    error = nil
    do {
      entries = try await model.client.listAuditLogs(accountID: accountID, perPage: 50)
      model.featureCache.set(key, entries)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}

/// Audit "when" stamps are ISO 8601 with or without fractional seconds; show a
/// localized date + time, falling back to the raw day prefix.
private func auditDateLabel(_ value: String) -> String {
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let plain = ISO8601DateFormatter()
  plain.formatOptions = [.withInternetDateTime]
  guard let date = fractional.date(from: value) ?? plain.date(from: value) else {
    return String(value.prefix(10))
  }
  let label = DateFormatter()
  label.dateStyle = .medium
  label.timeStyle = .short
  label.locale = DashL10n.activeLocale
  return label.string(from: date)
}

/// Pure conversion for the WAF top-countries bar chart, so the capping and
/// accessibility strings are unit-tested away from the view.
enum WAFChartModel {
  /// The bar chart renders every category label only while there are at most
  /// six bars, so the countries list is capped to the top entries by count.
  static let countryLimit = 6

  static func topCountries(
    _ buckets: [FirewallEventsBucket], limit: Int = countryLimit
  ) -> [FirewallEventsBucket] {
    Array(buckets.sorted { $0.count > $1.count }.prefix(limit))
  }

  static func data(from buckets: [FirewallEventsBucket]) -> [DitherDatum] {
    buckets.map { bucket in
      DitherDatum(
        id: bucket.label,
        label: bucket.label,
        values: ["blocks": Double(bucket.count)])
    }
  }

  static func countriesAccessibilitySummary(buckets: [FirewallEventsBucket]) -> String {
    let total = buckets.reduce(0) { $0 + $1.count }
    guard let top = buckets.max(by: { $0.count < $1.count }) else {
      return DashL10n.string("No blocked events in this window.")
    }
    let name =
      top.label.count == 2
      ? DashL10n.activeLocale.localizedString(forRegionCode: top.label) ?? top.label
      : top.label
    return DashL10n.string(
      "Blocked requests by country. \(name) leads with \(top.count.formatted()) of \(total.formatted()) blocks."
    )
  }
}

struct WAFEventsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let zoneID: String
  @State private var selectedSeriesID: String?
  @State private var summary: FirewallEventsSummary?
  @State private var loading = true
  @State private var error: String?
  @State private var underAttack = false
  @State private var securityLoaded = false
  @State private var securityUpdating = false

  private var canToggleSecurity: Bool {
    model.hasScopes(["zone-settings.write"])
  }

  private var underAttackBinding: Binding<Bool> {
    Binding(
      get: { underAttack },
      set: { enabled in
        guard securityLoaded, canToggleSecurity, !securityUpdating else { return }
        underAttack = enabled
        Task { await setUnderAttack(enabled) }
      })
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: summary != nil || securityLoaded,
      retry: { Task { await load(force: true) } }
    ) {
      if let summary {
        DashCard {
          VStack(alignment: .leading, spacing: 8) {
            Text("Last \(summary.hours) hours")
              .dashTextStyle(.footnoteSemibold)
              .foregroundStyle(DashTheme.subtle)
            Text(summary.blocked.formatted())
              .dashTextStyle(.sectionTitle)
              .foregroundStyle(DashTheme.text)
              .monospacedDigit()
            Text("Blocked requests")
              .dashTextStyle(.caption)
              .foregroundStyle(DashTheme.subtle)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      DashToggleRow(
        title: "Under Attack mode",
        subtitle: canToggleSecurity
          ? "Challenges every visitor. Restores the previous security level when turned off."
          : "Grant zone settings write access to change this.",
        isOn: underAttackBinding,
        isEnabled: securityLoaded && canToggleSecurity,
        isLoading: securityUpdating
      )
      .dashSectionBoundary(summary != nil)
      if let summary {
        if summary.countries.isEmpty {
          wafBucketGroup(
            title: "Top countries", buckets: summary.countries, labelsAreRegionCodes: true
          )
          .dashSectionBoundary()
        } else {
          countriesChartGroup(summary.countries)
            .dashSectionBoundary()
        }
        wafBucketGroup(title: "Top rules", buckets: summary.rules)
          .dashSectionBoundary()
      }
    }
    .detailHeader(icon: .solar(SolarAsset.Content.shieldCheck), title: "WAF")
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  /// The GraphQL country dimension is an ISO 3166 alpha-2 code — show the
  /// localized region name when we can resolve one.
  private func regionName(_ code: String) -> String {
    guard code.count == 2 else { return code }
    return DashL10n.activeLocale.localizedString(forRegionCode: code) ?? code
  }

  @ViewBuilder
  private func countriesChartGroup(_ countries: [FirewallEventsBucket]) -> some View {
    let top = WAFChartModel.topCountries(countries)
    DashListGroup(title: "Top countries") {
      DashCard {
        VStack(alignment: .leading, spacing: 12) {
          Text("Blocks by country")
            .dashTextStyle(.footnoteSemibold)
            .foregroundStyle(DashTheme.subtle)
          DitherBarChart(
            data: WAFChartModel.data(from: top),
            series: [
              DitherSeries(
                id: "blocks",
                label: DashL10n.ui("Blocks"),
                color: DashTheme.DitherChart.warning(
                  colorScheme: colorScheme,
                  contrast: colorSchemeContrast),
                variant: .gradient)
            ],
            options: DashTheme.DitherChart.options(
              showsLegend: false,
              accessibility: DitherAccessibility(
                title: DashL10n.ui("Top countries by blocked requests"),
                summary: WAFChartModel.countriesAccessibilitySummary(buckets: top),
                categoryAxisLabel: DashL10n.ui("Country"),
                valueAxisLabel: DashL10n.ui("Blocks"))),
            highlighted: selectedSeriesID != nil,
            selection: $selectedSeriesID
          )
          .frame(
            height: DashTheme.DitherChart.height(
              dynamicTypeSize: dynamicTypeSize,
              showsLegend: false))
        }
      }
    }
  }

  @ViewBuilder
  private func wafBucketGroup(
    title: String, buckets: [FirewallEventsBucket], labelsAreRegionCodes: Bool = false
  ) -> some View {
    DashListGroup(title: title) {
      if buckets.isEmpty {
        DashCard {
          Text("No blocked events in this window.")
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        dashListCard {
          dashListCardRows(items: buckets) { bucket in
            DashListRow(
              title: labelsAreRegionCodes ? regionName(bucket.label) : bucket.label,
              subtitle: DashL10n.string("\(bucket.count.formatted()) blocks"),
              icon: SolarAsset.Content.shieldCheck,
              showsChevron: false
            )
          }
        }
      }
    }
  }

  private func load(force: Bool = false) async {
    if summary == nil { loading = true }
    error = nil
    await loadSummary(force: force)
    await loadSecurityLevel(force: force)
    loading = false
  }

  private func loadSummary(force: Bool) async {
    let key = FeatureCacheKey.zoneWAF(zoneID)
    if !force, let cached: FirewallEventsSummary = model.featureCache.get(key) {
      summary = cached
      return
    }
    do {
      let fetched = try await model.client.firewallEventsSummary(zoneID: zoneID, hours: 24)
      if fetched.countries != summary?.countries { selectedSeriesID = nil }
      summary = fetched
      model.featureCache.set(key, fetched)
    } catch {
      self.error = error.dashActionableMessage
    }
  }

  private func loadSecurityLevel(force: Bool) async {
    let key = FeatureCacheKey.zoneSettings(zoneID)
    if !force, let cached: [ZoneSetting] = model.featureCache.get(key) {
      applySecurity(cached)
      return
    }
    do {
      let settings = try await model.client.listZoneSettings(zoneID: zoneID)
      model.featureCache.set(key, settings)
      applySecurity(settings)
    } catch {
      securityLoaded = false
    }
  }

  private func applySecurity(_ settings: [ZoneSetting]) {
    if case .string(let value)? = settings.first(where: { $0.id == "security_level" })?.value {
      underAttack = value == "under_attack"
      securityLoaded = true
    }
  }

  private func setUnderAttack(_ enabled: Bool) async {
    securityUpdating = true
    defer { securityUpdating = false }
    let defaults = UserDefaults.standard
    let stashKey = "dash.previous_security_level.\(zoneID)"
    do {
      if enabled {
        let settings = try await model.client.listZoneSettings(zoneID: zoneID)
        if case .string(let current)? = settings.first(where: { $0.id == "security_level" })?
          .value, current != "under_attack"
        {
          defaults.set(current, forKey: stashKey)
        }
        _ = try await model.client.updateZoneSetting(
          zoneID: zoneID, settingID: "security_level", value: .string("under_attack"))
        underAttack = true
      } else {
        let level = SetUnderAttackIntent.restoreLevel(stashed: defaults.string(forKey: stashKey))
        defaults.removeObject(forKey: stashKey)
        _ = try await model.client.updateZoneSetting(
          zoneID: zoneID, settingID: "security_level", value: .string(level))
        underAttack = false
      }
      model.featureCache.remove(FeatureCacheKey.zoneSettings(zoneID))
      DashDelight.celebrateSuccess()
    } catch {
      underAttack = !enabled
      model.toasts.error(error.dashActionableMessage)
    }
  }
}

private enum FeatureExternalURL {
  static let workersGuide = URL(
    string: "https://developers.cloudflare.com/workers/get-started/guide/")!
}
