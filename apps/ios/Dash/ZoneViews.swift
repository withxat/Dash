import CloudflareAPI
import GradientAvatars
import SwiftDitherKit
import SwiftUI
import UIKit

struct ZonesView: View {
  static let pageSize = 50

  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(DomainCardColors.key) private var domainCardColorData = ""
  @State private var zones: [CloudflareZone] = []
  @State private var error: String?
  @State private var loading = true
  @State private var isLoadingMore = false
  /// Bumped on every fresh `load` so an in-flight `loadMore` cannot append
  /// onto a list that was just reset / replaced.
  @State private var listGeneration = 0
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
      empty: DashFeatureEmpty(
        icon: SolarAsset.Content.globus,
        title: "No domains",
        message: featureAllowsWrites
          ? "Add your first domain to put it on Cloudflare."
          : "Cloudflare returned no domains for this account.",
        actionTitle: featureAllowsWrites ? "Add domain" : nil,
        action: featureAllowsWrites ? { showsAddDomain = true } : nil
      ),
      retry: { Task { await load() } }
    ) { mode in
      domainCardGrid(mode: mode)
      if !mode.isPlaceholder, pageState.canLoadMore || isLoadingMore {
        DashInfiniteScrollFooter(
          loaded: zones.count,
          isLoading: isLoadingMore
        ) {
          // A failed page leaves the list banner up; don't spin the same
          // request until the user retries (pull-to-refresh / Try again).
          guard error == nil else { return }
          Task { await loadMore() }
        }
      }
    }
    .refreshable { await load(force: true) }.task { await load() }
    .onAppear { reloadIfInvalidated() }
    .toolbar {
      if !model.isDemoSession {
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarIconButton(
            asset: SolarAsset.plus,
            accessibilityLabel: DashL10n.string("Add domain")
          ) {
            beginAddDomain()
          }
          .disabled(model.isAuthenticating)
          .accessibilityIdentifier("domains-add-domain")
        }
        .dashSeparateToolbarBackground()
      }
    }
    .dashTray(
      isPresented: $showsAddDomain, title: "Add domain",
      tone: FeatureVisualIdentity.tone(for: .zones)
    ) {
      AddDomainSheet {
        guard let accountID = model.activeAccountID else { return }
        model.featureCache.remove(FeatureCacheKey.zones(accountID))
        Task { await load(force: true) }
      }
    }
  }

  private func beginAddDomain() {
    if featureAllowsWrites {
      showsAddDomain = true
    } else {
      model.requestAccess(to: FeatureID.zones.capability.write)
    }
  }

  /// Same 2-up (or 1-up a11y) grid for cold and live — surplus placeholder
  /// cards recede when fewer domains land.
  @ViewBuilder
  private func domainCardGrid(mode: DashBodyMode) -> some View {
    let count =
      mode.isPlaceholder
      ? DashBodyPlaceholderDepth.domainCards
      : zones.count
    LazyVGrid(columns: gridColumns, spacing: DashTheme.Spacing.itemGap) {
      ForEach(0..<count, id: \.self) { index in
        Group {
          if mode.isPlaceholder {
            DomainCardFace(
              name: "domain.example",
              status: "Active",
              seed: "dash.placeholder.\(index)",
              fillHex: DomainCardColors.defaultPalette[
                index % DomainCardColors.defaultPalette.count]
            )
            .dashBodyPlaceholder(true)
          } else {
            domainCardLink(zones[index])
          }
        }
        .dashBodySlot(reduceMotion: reduceMotion)
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
    // Cold but a stale copy exists on disk: paint it now and refresh in place
    // so an offline relaunch shows last-known data instead of a skeleton. The
    // failure path below then becomes a banner over this stale data.
    if zones.isEmpty, let stale: [CloudflareZone] = model.featureCache.getStale(key) {
      zones = stale
      pageState.rehydrate(loaded: stale.count, pageSize: Self.pageSize)
      loading = true
    }
    if zones.isEmpty { loading = true }
    error = nil
    isLoadingMore = false
    listGeneration += 1
    let generation = listGeneration
    defer { loading = false }
    do {
      pageState.reset()
      let page = try await model.client.listZones(
        accountID: accountID, page: pageState.nextPage, perPage: Self.pageSize)
      guard generation == listGeneration, model.activeAccountID == accountID else { return }
      zones = page.items
      pageState.absorb(
        info: page.resultInfo, received: page.items.count, loaded: zones.count,
        pageSize: Self.pageSize)
      model.featureCache.storeZones(zones, accountID: accountID)
      MetricsWidgetPublisher.syncDomains(
        zones,
        accountID: accountID,
        accountName: model.accounts.first { $0.id == accountID }?.name ?? accountID,
        replacesCatalog: !pageState.canLoadMore)
    } catch {
      guard !error.dashIsCancellation else { return }
      guard generation == listGeneration, model.activeAccountID == accountID else { return }
      self.error = error.dashActionableMessage
    }
  }

  private func loadMore() async {
    guard let accountID = model.activeAccountID, !isLoadingMore, pageState.canLoadMore
    else { return }
    let generation = listGeneration
    let pageNumber = pageState.nextPage
    isLoadingMore = true
    defer { isLoadingMore = false }
    do {
      let page = try await model.client.listZones(
        accountID: accountID, page: pageNumber, perPage: Self.pageSize)
      guard !Task.isCancelled else { return }
      guard generation == listGeneration, model.activeAccountID == accountID else { return }
      zones += page.items
      pageState.absorb(
        info: page.resultInfo, received: page.items.count, loaded: zones.count,
        pageSize: Self.pageSize)
      model.featureCache.storeZones(zones, accountID: accountID)
      MetricsWidgetPublisher.syncDomains(
        zones,
        accountID: accountID,
        accountName: model.accounts.first { $0.id == accountID }?.name ?? accountID,
        replacesCatalog: !pageState.canLoadMore)
      error = nil
    } catch {
      guard !error.dashIsCancellation else { return }
      guard generation == listGeneration, model.activeAccountID == accountID else { return }
      self.error = error.dashActionableMessage
    }
  }
}

struct ZoneDetailView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
  /// Draft fill while customizing; committed only by Done.
  @State private var draftCardHex: UInt32?
  /// Non-nil while the overlay runs its settle-back exit.
  @State private var cardCustomizeExit: DomainCardCustomizeExit?
  @State private var activationCheckPhase: DashActionPhase = .idle
  @State private var showsAbandonSetup = false
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
  /// The account's own Cloudflare Registrar record for this domain, when there
  /// is one. First-party data beats RDAP: it is current, never redacted, and it
  /// is the only source that knows whether auto-renew is on.
  @State private var registrarRegistration: RegistrarDomainSummary?
  /// Starts cold, not settled: a lookup always follows the zone load, so the
  /// section paints placeholder rows from the first frame the zone is on screen
  /// instead of inserting a card under the hero when the answer arrives.
  @State private var rdapPhase: DashSectionPhase = .loading

  private let tools: [ZoneTool] = [
    ZoneTool(
      title: "DNS", icon: SolarAsset.globus, route: Destination.dns,
      blurb: "Records and proxy status"),
    ZoneTool(
      title: "HTTP traffic", icon: SolarAsset.chart, route: Destination.zoneAnalytics,
      blurb: "Requests, visitors, and bandwidth"),
    ZoneTool(
      title: "Web analytics", icon: SolarAsset.graph,
      route: Destination.zoneWebAnalytics,
      blurb: "Page views and Core Web Vitals"),
    ZoneTool(
      title: "WAF", icon: SolarAsset.shieldCheck, route: Destination.zoneWAF,
      blurb: "Blocks, countries, Under Attack"),
    ZoneTool(
      title: "Cache", icon: SolarAsset.bolt, route: Destination.cache,
      blurb: "Purge by URL or everything"),
    ZoneTool(
      title: "Settings", icon: SolarAsset.settings, route: Destination.zoneSettings,
      blurb: "Under Attack, SSL, and dev mode"),
  ]

  var body: some View {
    DashFeatureList(
      isLoading: displayedZone == nil && error == nil,
      error: error,
      hasContent: displayedZone != nil,
      retry: { Task { await load() } }
    ) { mode in
      zoneDetailBody(mode: mode)
    }
    .detailHeader(icon: .avatar(domainAvatarSeed), title: headerTitle)
    .dashMoreMenu(
      isPresented: $showsAbandonSetup,
      title: "Abandon setup",
      actions: [abandonSetupAction]
    )
    .navigationBarBackButtonHidden(showsCustomizeOverlay && isCustomizingCard)
    .toolbar {
      if showsCustomizeOverlay && isCustomizingCard {
        ToolbarItem(placement: .topBarLeading) {
          DashToolbarIconButton(
            asset: SolarAsset.editClose,
            accessibilityLabel: DashL10n.string("Cancel"),
            action: cancelCardCustomize
          )
          .disabled(isExitingCardCustomize)
          .accessibilityIdentifier("domain-card-customize-close")
        }
        .dashSeparateToolbarBackground()
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarIconButton(
            asset: SolarAsset.unread,
            accessibilityLabel: DashL10n.string("Done"),
            variant: .confirmation,
            action: saveCardCustomize
          )
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
        await loadRegistration(for: cached, force: false)
        return
      }
    } else if !force, let cached: CloudflareZone = model.featureCache.get(key) {
      zone = cached
      error = nil
      recordRecent(cached)
      await loadRegistration(for: cached, force: false)
      return
    }
    do {
      let fetched = try await model.client.getZone(zoneID)
      zone = fetched
      model.featureCache.set(key, fetched)
      error = nil
      recordRecent(fetched)
      await loadRegistration(for: fetched, force: true)
    } catch {
      guard !error.dashIsCancellation else { return }
      // The displayed zone stays on screen; a failed refresh surfaces the
      // warm banner over it.
      self.error = error.dashActionableMessage
    }
  }

  /// Registration precedence, in order: (1) no `registrar-domains.read` grant →
  /// RDAP unchanged; (2) the account's registrar index, fetched once per session
  /// and shared with `RegistrarDomainsView` through one cache key; (3) matched
  /// on the zone's own name by **exact equality** — a registrar-owned
  /// `example.com` says nothing about a `blog.example.com` zone's record;
  /// (4) a hit renders first-party and RDAP is never called; (5) a miss falls
  /// through to RDAP, unchanged; (6) a failed index falls through too, and only
  /// if RDAP *also* fails does the section go `.failed`, carrying the RDAP
  /// message since that was the last thing actually asked; (7) a 403 is treated
  /// as a miss and cached as a negative marker. A missing scope must affect only
  /// its own feature — it must never turn this card red.
  private func loadRegistration(for zone: CloudflareZone, force: Bool) async {
    if let registration = await RegistrarZoneRegistration.firstParty(
      forZoneNamed: zone.name, model: model)
    {
      settleRegistrar(registration)
      return
    }
    await loadRdap(for: zone, force: force)
  }

  private func settleRegistrar(_ registration: RegistrarDomainSummary) {
    withAnimation(DashTheme.Motion.content) {
      registrarRegistration = registration
      rdap = nil
      rdapPhase = .content
    }
  }

  private func loadRdap(for zone: CloudflareZone, force: Bool) async {
    let key = FeatureCacheKey.zoneRdap(zoneID)
    if !force, let cached: RdapRegistration = model.featureCache.get(key) {
      settleRdap(cached, phase: .content)
      return
    }
    do {
      let registration = try await RdapClient.lookup(
        domain: zone.name, relayBaseURL: model.configuration.pushBaseURL)
      // A `nil` answer is settled, not failed — privacy redaction, subdomain
      // zones, and TLDs with no RDAP/WHOIS record all land here, and the card
      // stays hidden as it always has.
      settleRdap(registration, phase: .content)
      if let registration {
        model.featureCache.set(key, registration)
      }
    } catch {
      // `.task` identity changes cancel this lookup; that is not a failure the
      // user should see veiled over the section.
      guard !error.dashIsCancellation, !Task.isCancelled else { return }
      // A thrown lookup used to be indistinguishable from an empty one: the
      // card simply never appeared and nothing said why.
      settleRdap(nil, phase: .failed(error.dashActionableMessage))
    }
  }

  private func settleRdap(_ registration: RdapRegistration?, phase: DashSectionPhase) {
    withAnimation(DashTheme.Motion.content) {
      registrarRegistration = nil
      rdap = registration
      rdapPhase = phase
    }
  }

  private func retryRegistration() async {
    guard let zone = displayedZone else { return }
    withAnimation(DashTheme.Motion.content) { rdapPhase = .loading }
    await loadRegistration(for: zone, force: true)
  }

  /// The zone's name only exists after a load, so recency is recorded here
  /// rather than on navigation.
  private func recordRecent(_ zone: CloudflareZone) {
    guard let accountID = model.activeAccountID else { return }
    recentsRaw = RecentResources.recording(
      RecentResource(accountID: accountID, kind: .zone, resourceID: zoneID, title: zone.name),
      in: recentsRaw)
  }

  /// Fuller first-paint reserve (2B): hero + identifiers + quick actions.
  /// Non-active setup chrome and registration replace/remove slots on handoff;
  /// registration itself stays section-cold after the zone lands.
  @ViewBuilder
  private func zoneDetailBody(mode: DashBodyMode) -> some View {
    if mode.isPlaceholder {
      zoneHeroPlaceholder
        .dashBodySlot(reduceMotion: reduceMotion)
      identifiersGroup
        .dashBodyPlaceholder(true)
        .dashSectionBoundary()
        .dashBodySlot(reduceMotion: reduceMotion)
      DashListGroup(title: "Actions") {
        DashListRowPlaceholders(rows: tools.count)
      }
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)
    } else if let zone = displayedZone {
      zoneHero(zone)
        .dashBodySlot(reduceMotion: reduceMotion)
      if isActive(zone) {
        identifiersGroup
          .dashSectionBoundary()
          .dashBodySlot(reduceMotion: reduceMotion)
        registrationGroup()
        primaryActions()
          .dashSectionBoundary()
          .dashBodySlot(reduceMotion: reduceMotion)
      } else {
        // Dash only serves active domains. Everything else is setup chrome:
        // nameservers + activation check while Cloudflare still needs them,
        // then abandon — no DNS / traffic / WAF / cache / settings.
        if needsActivation(zone) {
          if let servers = zone.nameServers, !servers.isEmpty {
            ZoneNameserversGroup(servers: servers)
              .dashSectionBoundary()
              .dashBodySlot(reduceMotion: reduceMotion)
          }
          activationCard(zone)
            .dashSectionBoundary()
            .dashBodySlot(reduceMotion: reduceMotion)
        }
        identifiersGroup
          .dashSectionBoundary()
          .dashBodySlot(reduceMotion: reduceMotion)
        if featureAllowsWrites {
          abandonSetupRow
            .dashSectionBoundary()
            .dashBodySlot(reduceMotion: reduceMotion)
        }
      }
    }
  }

  private var zoneHeroPlaceholder: some View {
    DomainCardFace(
      name: "domain.example",
      status: "Active",
      seed: "dash.placeholder.zone",
      fillHex: DomainCardColors.defaultPalette[0],
      aspectRatio: DomainCardFace.detailAspectRatio
    )
    .dashBodyPlaceholder(true)
  }

  /// Zone and account IDs for GraphQL / API probes. Tap a row to copy — same
  /// surface pattern as Tunnel detail's Tunnel ID row.
  private var identifiersGroup: some View {
    DashInfoGroup(title: "Identifiers") {
      zoneIDRow
      if let accountID = model.activeAccountID, !accountID.isEmpty {
        accountIDRow(accountID)
      }
    }
  }

  private var zoneIDRow: some View {
    Button(action: copyZoneID) {
      DashInfoRow("Zone ID", value: zoneID, mono: true)
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityLabel(DashL10n.string("Zone ID, \(zoneID)"))
    .accessibilityAction(named: DashL10n.string("Copy zone ID")) { copyZoneID() }
  }

  private func accountIDRow(_ accountID: String) -> some View {
    Button {
      copyAccountID(accountID)
    } label: {
      DashInfoRow("Account ID", value: accountID, mono: true)
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityLabel(DashL10n.string("Account ID, \(accountID)"))
    .accessibilityAction(named: DashL10n.string("Copy account ID")) {
      copyAccountID(accountID)
    }
  }

  private func copyZoneID() {
    UIPasteboard.general.string = zoneID
    model.toasts.success(DashL10n.string("Zone ID copied."))
  }

  private func copyAccountID(_ accountID: String) {
    UIPasteboard.general.string = accountID
    model.toasts.success(DashL10n.string("Account ID copied."))
  }

  private func zoneHero(_ zone: CloudflareZone) -> some View {
    let status = (zone.status ?? "unknown").capitalized
    let plan = zone.plan?.name
    // Nameserver count stays off the tile — the Nameservers group below owns that.
    return DomainCardFace(
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
  }

  private func primaryActions() -> some View {
    DashListGroup(title: "Actions") {
      dashListCardRows(items: tools, inset: false) { tool in
        let destination = tool.route(zoneID)
        DashListGroupLink(value: destination) {
          DashListRow(
            title: DashL10n.ui(tool.title),
            subtitle: DashL10n.ui(tool.blurb),
            icon: tool.icon,
            showsIconPlate: false)
        }
      }
    }
  }

  /// Dash tools (DNS, analytics, cache, settings) only run on active zones.
  private func isActive(_ zone: CloudflareZone) -> Bool {
    (zone.status ?? "").lowercased() == "active"
  }

  /// Statuses a name-server re-check can move forward. `moved` means
  /// Cloudflare stopped seeing its name servers; pointing them back and
  /// re-checking restores the zone. Until then the zone stays in the
  /// setup-only pose with abandon.
  private func needsActivation(_ zone: CloudflareZone) -> Bool {
    ["pending", "initializing", "moved"].contains((zone.status ?? "").lowercased())
  }

  private var canTriggerActivationCheck: Bool {
    model.hasScopes(FeatureID.zones.capability.write)
  }

  private var abandonSetupRow: some View {
    Button {
      showsAbandonSetup = true
    } label: {
      HStack(spacing: 12) {
        SolarIcon(asset: SolarAsset.trash, size: 22, color: DashTheme.danger)
        Text(DashL10n.string("Abandon setup"))
          .dashTextStyle(.bodyMedium)
          .foregroundStyle(DashTheme.danger)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        DashTheme.dangerTint,
        in: RoundedRectangle(cornerRadius: DashTheme.Radius.button, style: .continuous))
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityLabel(DashL10n.string("Abandon setup"))
  }

  private var abandonSetupAction: DashDangerAction {
    let name = displayedZone?.name ?? headerTitle
    return DashDangerAction(
      title: "Abandon setup",
      message: DashL10n.string(
        "Removes \(name) from this account. Name servers at the registrar are untouched — you can add the domain again later."
      ),
      confirmTitle: "Abandon setup",
      onSuccessPresentationCompleted: completeAbandonSetupPresentation
    ) {
      try await abandonSetup()
    }
  }

  private func abandonSetup() async throws {
    guard let context = model.accountRequestContext else { throw CancellationError() }
    try await model.client.deleteZone(zoneID: zoneID)
    try Task.checkCancellation()
    guard model.isCurrentAccount(context) else { throw CancellationError() }
    model.featureCache.remove(FeatureCacheKey.zone(zoneID))
    model.featureCache.remove(FeatureCacheKey.zones(context.accountID))
    model.featureCache.remove(FeatureCacheKey.zoneRdap(zoneID))
    model.featureCache.remove(FeatureCacheKey.zoneSettings(zoneID))
    if PinnedZones.isPinned(pinnedZoneData, zoneID: zoneID),
      let zone = displayedZone
    {
      pinnedZoneData = PinnedZones.toggled(
        pinnedZoneData,
        pin: PinnedZone(accountID: context.accountID, zoneID: zoneID, name: zone.name))
    }
    recentsRaw = RecentResources.encode(
      RecentResources.decode(recentsRaw).filter {
        !($0.kind == .zone && $0.resourceID == zoneID)
      })
  }

  private func completeAbandonSetupPresentation() {
    navigator?.path.removeAll { destination in
      switch destination {
      case .zone(let id), .dns(let id), .cache(let id), .zoneAnalytics(let id),
        .zoneWebAnalytics(let id), .zoneWAF(let id), .zoneSettings(let id),
        .zoneEmailRouting(let id):
        id == zoneID
      default:
        false
      }
    }
    model.toasts.success(DashL10n.string("Removed from account."))
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
          DashPillButton(
            title: "Check now",
            phase: activationCheckPhase,
            onSuccessPresentationCompleted: { activationCheckPhase = .idle }
          ) {
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
    activationCheckPhase = .loading
    do {
      try await model.client.triggerZoneActivationCheck(zoneID: zoneID)
      guard !Task.isCancelled else {
        activationCheckPhase = .idle
        return
      }
      model.toasts.success(
        DashL10n.string(
          "Cloudflare is rechecking now — the status usually updates within a few minutes."))
      activationCheckPhase = .succeeded
    } catch {
      activationCheckPhase = .idle
      guard !error.dashIsCancellation else { return }
      model.toasts.error(error.dashActionableMessage)
    }
  }

  /// Registration is a *secondary* fetch inside an already-loaded detail, so it
  /// carries its own phase: placeholders while the lookup runs, the fields when
  /// it answers, the failure veiled over those same placeholders when it
  /// doesn't. Only a settled-empty lookup drops the section entirely — an
  /// answer of “no public record” is not worth a permanent card.
  ///
  /// Both paths share one frame and one placeholder count, so the section never
  /// changes shape depending on which source answered.
  @ViewBuilder
  private func registrationGroup() -> some View {
    if registrarRegistration != nil || rdapPhase != .content || rdap != nil {
      // First-party path only: the header action pushes registrar detail.
      // A domain registered elsewhere has no `/registrar/registrations`
      // record, so an always-on control would open a screen that 404s.
      let manageDomain = registrarRegistration?.name
      DashInfoGroup(
        title: "Registration",
        phase: rdapPhase,
        // The four fields below, so the arriving values land on the
        // placeholder instead of growing the section.
        placeholderRows: 4,
        retry: { Task { await retryRegistration() } },
        actionTitle: manageDomain != nil ? "Manage registration" : nil,
        actionIcon: manageDomain != nil ? SolarAsset.globus : nil,
        action: manageDomain.map { domain in
          { navigator?.push(.registrarDomain(domain)) }
        }
      ) {
        if let registration = registrarRegistration {
          RegistrarRegistrationRows(summary: registration)
        } else if let registration = rdap {
          if let registrar = registration.registrar {
            DashInfoRow("Registrar", value: registrar)
          }
          if let expires = registration.expiresOn {
            DashInfoRow("Expires", value: DashDateFormatting.dateOnly(fromISO8601: expires))
          }
          if let registered = registration.registeredOn {
            DashInfoRow(
              "Registered", value: DashDateFormatting.dateOnly(fromISO8601: registered))
          }
          if let status = registration.status.first {
            DashInfoRow("Status", value: rdapStatusLabel(status))
          }
        }
      }
      .dashSectionBoundary()
    }
  }
}

/// Assigned-nameserver reference shared by zone detail (activation states only)
/// and the top of zone Settings. Cloudflare assigns two, so this stays bounded
/// and can live in `DashInfoGroup`'s eager stack.
struct ZoneNameserversGroup: View {
  let servers: [String]

  var body: some View {
    DashInfoGroup(title: "Nameservers") {
      ForEach(servers, id: \.self) { server in
        DashInfoRow(value: server, mono: true)
      }
    }
  }
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
            .foregroundStyle(DashTheme.glassActionForeground)
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
/// then the always-mounted built-in swatch grid fades up. Entrance timing uses
/// an unstructured `Task` from `onAppear` — not `.task` — so parent redraws
/// cannot cancel the sleep and leave the picker stuck hidden.
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
  @State private var scrimProgress: CGFloat = 0
  @State private var pickerRevealed = false
  @State private var isExiting = false
  @State private var didStartEntrance = false

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
        DomainCardColorPaletteGrid(selection: $fillHex)
          .padding(.horizontal, DashTheme.Spacing.screen)
          .opacity(pickerRevealed ? 1 : 0)
          .scaleEffect(pickerRevealed ? 1 : 0.96)
          .offset(y: pickerRevealed ? 0 : 12)
          .allowsHitTesting(pickerRevealed && !isExiting)
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

    withAnimation(DashTheme.Motion.morphExit) {
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

/// 4×5 built-in swatches — solid circles on a white plate, matching the
/// customize-picker reference (no freeform hue wheel).
private struct DomainCardColorPaletteGrid: View {
  @Binding var selection: UInt32

  private let columns = Array(
    repeating: GridItem(.flexible(), spacing: 14),
    count: 5
  )

  var body: some View {
    LazyVGrid(columns: columns, spacing: 18) {
      ForEach(DomainCardColors.defaultPalette, id: \.self) { hex in
        DomainCardColorSwatch(
          hex: hex,
          isSelected: selection == hex
        ) {
          guard selection != hex else { return }
          selection = hex
          DashDelight.selectionChanged()
        }
      }
    }
    .padding(20)
    .background(
      DashTheme.homeCardSurface,
      in: RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Color palette")
  }
}

private struct DomainCardColorSwatch: View {
  let hex: UInt32
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .fill(DomainCardColors.fill(hex))
        if isSelected {
          Image(systemName: "checkmark")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(DomainCardColors.foreground(hex))
        }
      }
      .aspectRatio(1, contentMode: .fit)
      .contentShape(Circle())
    }
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel(DomainCardColors.formatHex(hex))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
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
  /// Email Routing's apex MX / SPF records are locked by Cloudflare. See
  /// `EmailRoutingDNSGuard`: the Managed badge is decoration and vanishes
  /// silently on a failed plan fetch, while the edit gate remains independent
  /// of that plan.
  @State private var emailRoutingGuard = EmailRoutingDNSGuard()
  @State private var lockedRecord: DNSRecord?
  @State private var createsRecord = false
  @State private var loading = true
  @State private var isLoadingMore = false
  @State private var reloading = false
  @State private var activeRequestID: UUID?
  @State private var pageState = DashPageState()
  @State private var error: String?
  @State private var selectedSliceID: String?

  private var deferredDeletionRefreshGeneration: UInt64 {
    guard let accountID = model.activeAccountID else { return 0 }
    return model.deferredDeletions.refreshGeneration(
      for: DeferredDeletionScope(accountID: accountID, zoneID: zoneID))
  }

  var body: some View {
    let displayedRecords = displayRecords
    let buckets = DNSChartModel.buckets(displayedRecords)
    let selectedBucket = DNSChartModel.bucket(in: buckets, withID: selectedSliceID)
    let visibleRecords = visibleRecords(in: displayedRecords, buckets: buckets)
    let slices = recordTypeSlices(for: buckets)

    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !displayedRecords.isEmpty,
      empty: DashFeatureEmpty(
        icon: SolarAsset.Content.globus,
        title: "No DNS records",
        message: "Create a record with the add button."
      ),
      retry: { Task { await load(force: true) } }
    ) { mode in
      if mode.isPlaceholder {
        DashChartPanelPlaceholder(showsLegend: true)
          .padding(.bottom, DashTheme.Spacing.itemGap)
          .dashBodySlot(reduceMotion: reduceMotion)
      } else {
        recordTypesCard(
          buckets: buckets,
          slices: slices,
          selectedBucket: selectedBucket,
          displayedRecordCount: displayedRecords.count
        )
        // Bottom padding on the card, not top padding on the rows: the rows
        // are a bare lazy `ForEach` and must stay untouched (StorageViews
        // precedent).
        .padding(.bottom, DashTheme.Spacing.itemGap)
        .dashBodySlot(reduceMotion: reduceMotion)
      }
      dashListCard {
        dashModeListRows(
          mode: mode, items: visibleRecords, reduceMotion: reduceMotion
        ) { record in
          Button {
            if emailRoutingGuard.isLocked(record) {
              lockedRecord = record
            } else {
              selected = record
            }
          } label: {
            DashListRow(
              title: record.name,
              subtitle: dnsRecordSubtitle(record),
              icon: record.proxied == true
                ? SolarAsset.Content.cloud : SolarAsset.Content.globus,
              // Proxied keeps the orange cloud; unproxied inherits the
              // zones catalog green.
              iconColor: record.proxied == true ? DashTheme.accent : nil
            ) {
              if emailRoutingGuard.isManaged(record) { StatusBadge(.managed) }
            }
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityIdentifier("dns-record-\(record.id)")
          .transition(morphTransition)
        }
      }
      if !mode.isPlaceholder, pageState.canLoadMore || isLoadingMore {
        DashInfiniteScrollFooter(
          loaded: displayedRecords.count,
          isLoading: isLoadingMore
        ) {
          guard error == nil else { return }
          Task { await loadMore() }
        }
      }
    }
    .refreshable { await load(force: true) }
    .detailHeader(icon: .solar(SolarAsset.Content.globus), title: "DNS")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if featureAllowsWrites {
          DashToolbarIconButton(
            asset: SolarAsset.plus, accessibilityLabel: DashL10n.string("New DNS record")
          ) {
            createsRecord = true
          }
        }
      }
      .dashSeparateToolbarBackground()
    }
    .dashTray(
      item: $selected,
      title: { _ in "DNS record" },
      tone: FeatureVisualIdentity.tone(for: .zones),
      content: { record in
        DNSRecordEditor(zoneID: zoneID, record: record) {
          model.featureCache.remove(FeatureCacheKey.dnsRecords(zoneID))
          Task { await load(force: true) }
        }
      }
    )
    .dashTray(
      item: $lockedRecord,
      title: { _ in "DNS record" },
      tone: FeatureVisualIdentity.tone(for: .zones),
      content: { record in
        DashDetailTray(
          fields: [
            DashDetailField(label: "Type", value: record.type),
            DashDetailField(label: "Name", value: record.name, mono: true),
            DashDetailField(label: "Content", value: record.content, mono: true),
          ]
        ) {
          VStack(alignment: .leading, spacing: 12) {
            DashNotice(
              kind: .info,
              message:
                "Email routing manages this record. Editing or deleting it would stop mail delivery for this domain."
            )
            DestinationLink(
              destination: .zoneEmailRouting(zoneID),
              onNavigate: { lockedRecord = nil }
            ) {
              DashListRow(
                title: DashL10n.string("Open email routing"),
                icon: SolarAsset.Content.mailbox)
            }
          }
        }
      }
    )
    .dashTray(
      isPresented: $createsRecord, title: "New DNS record",
      tone: FeatureVisualIdentity.tone(for: .zones)
    ) {
      DNSRecordEditor(zoneID: zoneID, record: nil) {
        model.featureCache.remove(FeatureCacheKey.dnsRecords(zoneID))
        Task { await load(force: true) }
      }
    }
    .task(id: model.accountRequestContext) {
      // A failed lookup restores the pre-Email-Routing behavior: no badge and
      // an editable row. The gate becomes a positive claim only after settings
      // say routing is enabled.
      emailRoutingGuard = EmailRoutingDNSGuard()
      guard let context = model.accountRequestContext else { return }
      let key = FeatureCacheKey.emailRouting(zoneID)
      var settings: EmailRoutingSettings? =
        (model.featureCache.get(key) as EmailRoutingSnapshot?)?.settings
      if settings == nil {
        settings = try? await model.client.getEmailRoutingSettings(zoneID: zoneID)
      }
      guard model.isCurrentAccount(context), !Task.isCancelled, let settings, settings.enabled
      else { return }
      var next = EmailRoutingDNSGuard(
        isEnabled: true, apex: settings.name.lowercased(), plan: nil)
      // The edit gate needs only the positive settings answer. Arm it before
      // the decorative plan lookup so a slow or failed plan cannot briefly
      // reopen Cloudflare-managed records for editing.
      emailRoutingGuard = next
      let planKey = FeatureCacheKey.emailRoutingDNS(zoneID)
      if let cached: EmailRoutingDNSPlan = model.featureCache.get(planKey) {
        next.plan = cached
      } else if let fetched = try? await model.client.getEmailRoutingDNSPlan(zoneID: zoneID) {
        guard model.isCurrentAccount(context), !Task.isCancelled else { return }
        model.featureCache.set(planKey, fetched)
        next.plan = fetched
      }
      guard model.isCurrentAccount(context), !Task.isCancelled else { return }
      emailRoutingGuard = next
    }
    .task(id: deferredDeletionRefreshGeneration) {
      // The first mounted DNS view that wins this forced load writes the
      // shared cache. Acknowledging the generation back to zero then reruns
      // every other mounted instance against that same snapshot, so none can
      // retain a pre-deletion local row.
      let generation = deferredDeletionRefreshGeneration
      let accountID = model.activeAccountID
      let loaded = await load(force: generation > 0)
      if loaded, generation > 0, let accountID {
        model.deferredDeletions.acknowledgeRefresh(
          for: DeferredDeletionScope(accountID: accountID, zoneID: zoneID),
          generation: generation)
      }
    }
  }

  private func recordTypesCard(
    buckets: [DNSChartModel.Bucket],
    slices: [DitherSlice],
    selectedBucket: DNSChartModel.Bucket?,
    displayedRecordCount: Int
  ) -> some View {
    // Chart cards stay on the glass surface, not the info-group band — see the
    // surface split on `DashGlassCard`. No detail chevron: the donut is a filter
    // control for the records below, and its legend already names every slice,
    // so a pushed copy would only restate what the card shows.
    DashGlassCard {
      VStack(alignment: .leading, spacing: 12) {
        Text("Record types")
          .dashTextStyle(.footnoteSemibold)
          .foregroundStyle(DashTheme.subtle)
          .frame(maxWidth: .infinity, alignment: .leading)
        DashPieChart(
          slices: slices,
          innerRadiusRatio: 0.62,
          options: DashTheme.DitherChart.polarOptions(
            accessibility: DitherAccessibility(
              title: DashL10n.ui("DNS record types"),
              summary: DNSChartModel.chartAccessibilitySummary(buckets: buckets),
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
        filterStrip(
          bucket: selectedBucket,
          slices: slices,
          displayedRecordCount: displayedRecordCount)
      }
    }
  }

  @ViewBuilder
  private func filterStrip(
    bucket: DNSChartModel.Bucket?,
    slices: [DitherSlice],
    displayedRecordCount: Int
  ) -> some View {
    if let bucket {
      DashChartFilterStrip(
        label: DNSChartModel.label(for: bucket),
        countText: DashL10n.string(
          "\(bucket.count.formatted()) of \(displayedRecordCount.formatted()) records"),
        color: sliceColor(forBucketID: bucket.id, in: slices),
        clearAccessibilityLabel: DashL10n.string("Show all record types"),
        clearAccessibilityIdentifier: "dns-type-filter-clear"
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
  private var displayRecords: [DNSRecord] {
    guard let accountID = model.activeAccountID else { return records }
    return records.filter { record in
      !model.deferredDeletions.isPendingDeletion(
        DeferredDeletionResourceKey(
          kind: .dnsRecord,
          accountID: accountID,
          zoneID: zoneID,
          resourceID: record.id))
    }
  }

  private func visibleRecords(
    in displayedRecords: [DNSRecord],
    buckets: [DNSChartModel.Bucket]
  ) -> [DNSRecord] {
    DNSChartModel.records(displayedRecords, in: selectedSliceID, buckets: buckets)
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
  private func recordTypeSlices(for buckets: [DNSChartModel.Bucket]) -> [DitherSlice] {
    let palette = [
      DashTheme.DitherChart.brand(colorScheme: colorScheme, contrast: colorSchemeContrast),
      DashTheme.DitherChart.positive(colorScheme: colorScheme, contrast: colorSchemeContrast),
      DashTheme.DitherChart.accentPurple(colorScheme: colorScheme, contrast: colorSchemeContrast),
      DashTheme.DitherChart.warning(colorScheme: colorScheme, contrast: colorSchemeContrast),
      DashTheme.DitherChart.accentTeal(colorScheme: colorScheme, contrast: colorSchemeContrast),
    ]
    var nextColor = 0
    return buckets.map { bucket in
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
  private func sliceColor(forBucketID id: String, in slices: [DitherSlice]) -> DitherColor {
    slices.first { $0.id == id }?.color
      ?? DashTheme.DitherChart.neutral(colorScheme: colorScheme, contrast: colorSchemeContrast)
  }

  @discardableResult
  private func load(force: Bool = false) async -> Bool {
    let requestID = UUID()
    activeRequestID = requestID
    reloading = true
    isLoadingMore = false
    defer {
      if activeRequestID == requestID {
        reloading = false
        loading = false
      }
    }
    let key = FeatureCacheKey.dnsRecords(zoneID)
    if !force, let cached: [DNSRecord] = model.featureCache.get(key) {
      records = cached
      pageState.rehydrate(loaded: cached.count, pageSize: Self.pageSize)
      error = nil
      return true
    }
    let requestScope = model.activeAccountID.map {
      DeferredDeletionScope(accountID: $0, zoneID: zoneID)
    }
    let globalRequestGeneration = requestScope.map {
      model.deferredDeletions.beginDNSLoad(for: $0)
    }
    if records.isEmpty { loading = true }
    error = nil
    do {
      pageState.reset()
      let page = try await model.client.listDNSRecords(
        zoneID: zoneID, page: pageState.nextPage, perPage: Self.pageSize)
      guard
        activeRequestID == requestID,
        acceptsDNSResponse(
          scope: requestScope,
          generation: globalRequestGeneration)
      else { return false }
      records = page.items
      pageState.absorb(
        info: page.resultInfo, received: page.items.count, loaded: records.count,
        pageSize: Self.pageSize)
      reconcileDeferredDeletions(loadGeneration: globalRequestGeneration)
      model.featureCache.set(key, records)
      return true
    } catch {
      guard
        activeRequestID == requestID,
        acceptsDNSResponse(
          scope: requestScope,
          generation: globalRequestGeneration)
      else { return false }
      if error.dashIsCancellation { return false }
      self.error = error.dashActionableMessage
      return false
    }
  }

  private func loadMore() async {
    guard !isLoadingMore, !reloading, pageState.canLoadMore else { return }
    let requestID = UUID()
    activeRequestID = requestID
    let pageNumber = pageState.nextPage
    isLoadingMore = true
    let requestScope = model.activeAccountID.map {
      DeferredDeletionScope(accountID: $0, zoneID: zoneID)
    }
    let globalRequestGeneration = requestScope.map {
      model.deferredDeletions.beginDNSLoad(for: $0)
    }
    defer {
      if activeRequestID == requestID {
        isLoadingMore = false
      }
    }
    do {
      let page = try await model.client.listDNSRecords(
        zoneID: zoneID, page: pageNumber, perPage: Self.pageSize)
      guard
        activeRequestID == requestID,
        acceptsDNSResponse(
          scope: requestScope,
          generation: globalRequestGeneration)
      else { return }
      records += page.items
      pageState.absorb(
        info: page.resultInfo, received: page.items.count, loaded: records.count,
        pageSize: Self.pageSize)
      reconcileDeferredDeletions(loadGeneration: globalRequestGeneration)
      model.featureCache.set(FeatureCacheKey.dnsRecords(zoneID), records)
      error = nil
    } catch {
      guard
        activeRequestID == requestID,
        acceptsDNSResponse(
          scope: requestScope,
          generation: globalRequestGeneration)
      else { return }
      if error.dashIsCancellation { return }
      self.error = error.dashActionableMessage
    }
  }

  private func reconcileDeferredDeletions(loadGeneration: UInt64?) {
    guard let accountID = model.activeAccountID else { return }
    model.deferredDeletions.reconcileDNSRecords(
      accountID: accountID,
      zoneID: zoneID,
      serverRecordIDs: Set(records.map(\.id)),
      isCompleteSnapshot: !pageState.canLoadMore,
      loadGeneration: loadGeneration)
  }

  private func acceptsDNSResponse(
    scope: DeferredDeletionScope?,
    generation: UInt64?
  ) -> Bool {
    guard let scope, let generation else { return true }
    return model.activeAccountID == scope.accountID
      && model.deferredDeletions.isCurrentDNSLoad(
        for: scope,
        generation: generation)
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
    bucket(in: buckets(records), withID: bucketID)
  }

  static func bucket(in buckets: [Bucket], withID bucketID: String?) -> Bucket? {
    guard let bucketID else { return nil }
    return buckets.first { $0.id == bucketID }
  }

  /// Loaded records belonging to one donut bucket — the list-side half of
  /// slice selection. A `nil` id, or one no bucket claims, filters nothing, so
  /// a stale selection degrades to the full list rather than an empty one.
  static func records(_ records: [DNSRecord], in bucketID: String?) -> [DNSRecord] {
    Self.records(records, in: bucketID, buckets: buckets(records))
  }

  static func records(
    _ records: [DNSRecord],
    in bucketID: String?,
    buckets: [Bucket]
  ) -> [DNSRecord] {
    guard let bucketID else { return records }
    guard buckets.contains(where: { $0.id == bucketID }) else { return records }
    guard bucketID == otherBucketID else {
      return records.filter { $0.type.uppercased() == bucketID }
    }
    // Other holds the remainder by construction: whatever the named slices
    // did not claim.
    let named = Set(buckets.map(\.id)).subtracting([otherBucketID])
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
  @State private var savePhase: DashActionPhase = .idle

  private var requiredWriteScopes: Set<String> {
    writeScopes(for: .dns(zoneID))
  }

  private var allowsWrites: Bool {
    model.hasScopes(requiredWriteScopes)
  }

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
      saveTitle: allowsWrites
        ? "Save" : (model.isDemoSession ? "Connect your account" : "Grant access"),
      actionPhase: savePhase,
      onSuccessPresentationCompleted: completeSavePresentation,
      canSave: allowsWrites ? canSave : true,
      deleteMessage: allowsWrites
        ? record.map {
          DashL10n.string("Permanently delete the \($0.type) record for \($0.name).")
        } : nil,
      deleteError: error,
      onDelete: allowsWrites ? record.map { rec in { delete(rec) } } : nil,
      deletionPresentation: .deferToGlobalUndo,
      onSave: {
        if allowsWrites {
          Task { await save() }
        } else {
          model.requestAccess(to: requiredWriteScopes)
        }
      },
      content: {
        VStack(spacing: 14) {
          if !allowsWrites {
            DashNotice(
              kind: .warning,
              message:
                model.isDemoSession
                ? "Connect your account when you are ready to make changes"
                : "Dash requests all permissions used by its current features in one authorization."
            )
          }

          Group {
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
          }
          .disabled(!allowsWrites)

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
    guard allowsWrites else {
      model.requestAccess(to: requiredWriteScopes)
      return
    }
    error = nil
    let input: DNSRecordInput
    if isSRV {
      guard let priority = Int(priorityText), let weight = Int(weightText),
        let port = Int(portText)
      else {
        error = DashL10n.string("Priority, weight, and port must be numbers.")
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
        return
      }
      input = DNSRecordInput(
        type: type, name: name, content: content, proxied: false, ttl: ttl, priority: priority)
    } else if isCAA {
      guard let flags = Int(caaFlagsText), (0...255).contains(flags) else {
        error = DashL10n.string("Flags must be a number between 0 and 255.")
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
    guard let context = model.accountRequestContext else { return }
    savePhase = .loading
    do {
      let successMessage: String
      if let record {
        _ = try await model.client.updateDNSRecord(
          zoneID: zoneID, recordID: record.id, input: input)
        successMessage = DashL10n.string("DNS record updated.")
      } else {
        _ = try await model.client.createDNSRecord(zoneID: zoneID, input: input)
        successMessage = DashL10n.string("DNS record created.")
      }
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        savePhase = .idle
        return
      }
      model.toasts.success(successMessage)
      savePhase = .succeeded
    } catch {
      savePhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
    }
  }

  private func completeSavePresentation() {
    guard savePhase == .succeeded else {
      savePhase = .idle
      return
    }
    savePhase = .idle
    saved()
    dismiss()
  }

  private func delete(_ record: DNSRecord) {
    guard allowsWrites else {
      model.requestAccess(to: requiredWriteScopes)
      return
    }
    guard let accountID = model.activeAccountID else { return }
    error = nil
    guard
      model.deferredDeletions.schedule(
        .dnsRecord(
          accountID: accountID,
          zoneID: zoneID,
          recordID: record.id,
          recordType: record.type,
          displayName: record.name)) != nil
    else { return }
    dismiss()
  }
}
