import CloudflareAPI
import GradientAvatars
import SwiftDitherKit
import SwiftUI
import UIKit

struct ZoneDetailView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.dashNavigationCoordinator) private var navigationCoordinator
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

  /// Whether this zone has a Web Analytics site, and so whether its row exists.
  /// The lookup is account-wide and session-cached, so it costs one request per
  /// account no matter how many zones the user opens.
  @State private var webAnalytics: ZoneWebAnalyticsAvailability = .pending

  /// Every tool a zone can carry. `needsWebAnalyticsSite` marks the one entry
  /// that is conditional, declared here rather than filtered by title so the
  /// rule never rides on a localizable string.
  private static let allTools: [ZoneTool] = [
    ZoneTool(
      title: "DNS", icon: SolarAsset.globus, route: Destination.dns,
      blurb: "Records and proxy status"),
    ZoneTool(
      title: "HTTP traffic", icon: SolarAsset.chart, route: Destination.zoneAnalytics,
      blurb: "Requests, visitors, and bandwidth"),
    ZoneTool(
      title: "Web analytics", icon: SolarAsset.graph,
      route: Destination.zoneWebAnalytics,
      blurb: "Browser-reported page views and visits",
      needsWebAnalyticsSite: true),
    ZoneTool(
      title: "WAF", icon: SolarAsset.shieldCheck, route: Destination.zoneWAF,
      blurb: "Blocks, countries, Under Attack"),
    ZoneTool(
      title: "Cache", icon: SolarAsset.bolt, route: Destination.cache,
      blurb: "Development Mode, Always Online, Cache Level"),
    ZoneTool(
      title: "Settings", icon: SolarAsset.settings, route: Destination.zoneSettings,
      blurb: "Security level, SSL, and HTTPS"),
  ]

  /// The rows this zone actually gets. Web analytics joins them only once the
  /// account's site list says a site injects into this zone — see
  /// `ZoneWebAnalyticsAvailability`.
  private var tools: [ZoneTool] {
    guard !webAnalytics.showsTool else { return Self.allTools }
    return Self.allTools.filter { !$0.needsWebAnalyticsSite }
  }

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
    .dashPageActions(
      leading: showsCustomizeOverlay && isCustomizingCard
        ? [
          .icon(
            id: "domain-card-customize-close",
            asset: SolarAsset.editClose,
            accessibilityLabel: DashL10n.string("Cancel"),
            isEnabled: !isExitingCardCustomize,
            accessibilityIdentifier: "domain-card-customize-close",
            action: cancelCardCustomize)
        ]
        : [],
      trailing: showsCustomizeOverlay && isCustomizingCard
        ? [
          .icon(
            id: "domain-card-customize-save",
            asset: SolarAsset.unread,
            accessibilityLabel: DashL10n.string("Done"),
            variant: .confirmation,
            isEnabled: !isExitingCardCustomize,
            accessibilityIdentifier: "domain-card-customize-save",
            action: saveCardCustomize)
        ]
        : [
          .icon(
            id: "domain-pin-toggle",
            asset: isPinned ? SolarAsset.pinFilled : SolarAsset.pin,
            accessibilityLabel: isPinned ? "Unpin domain" : "Pin domain",
            isEnabled: displayedZone != nil && !showsCustomizeOverlay
          ) {
            togglePin()
          }
        ]
    )
    .refreshable {
      // The site list is its own request; the zone must not queue behind it,
      // and a pull is exactly how a user who just added a site asks for the row.
      async let zone: Void = load(force: true)
      async let sites: Void = resolveWebAnalytics(force: true)
      _ = await (zone, sites)
    }
    .task { await load() }
    .task { await resolveWebAnalytics() }
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

  /// Answers whether this zone has a Web Analytics site, which is what decides
  /// the tool row. The account's site list is read from the session cache
  /// *before* the first `await`, so a second zone visited in the same session
  /// resolves in the same frame as its tools and the row never inserts late.
  ///
  /// Failure of any kind settles `.indeterminate`, not `.absent`: a missing
  /// grant, a dropped request, or a signed-out moment must affect only its own
  /// feature, never quietly delete a screen the user's account may well have.
  private func resolveWebAnalytics(force: Bool = false) async {
    guard let context = model.accountRequestContext,
      model.hasScopes(DashAuthorizationScopes.webAnalytics)
    else {
      webAnalytics = .indeterminate
      return
    }
    if !force,
      let cached = WebAnalyticsSiteIndex.cached(accountID: context.accountID, model: model)
    {
      webAnalytics = .resolved(zoneID: zoneID, in: cached)
      return
    }
    do {
      let sites = try await WebAnalyticsSiteIndex.load(
        accountID: context.accountID, model: model, force: force)
      guard model.isCurrentAccount(context), !Task.isCancelled else { return }
      // Only the answer that arrives after a wait animates; the cached path
      // above lands with the rest of the page.
      withAnimation(DashTheme.Motion.content) {
        webAnalytics = .resolved(zoneID: zoneID, in: sites)
      }
    } catch {
      guard !error.dashIsCancellation, !Task.isCancelled else { return }
      withAnimation(DashTheme.Motion.content) { webAnalytics = .indeterminate }
    }
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
  /// and cached under one key that also seeds the pushed registrar detail;
  /// (3) matched
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
        domain: zone.name, relayBaseURL: model.configuration.relayBaseURL)
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
    // One stable seat spans placeholder → live so an in-flight compositor
    // claim never loses the card when cached detail data lands.
    zoneHeroLandingSeat(
      mode: mode,
      zone: mode.isPlaceholder ? nil : displayedZone
    )
    .dashBodySlot(reduceMotion: reduceMotion)

    if mode.isPlaceholder {
      identifiersGroup
        .dashBodyPlaceholder(true)
        .dashSectionBoundary()
        .dashBodySlot(reduceMotion: reduceMotion)
      DashListGroup(title: "Actions") {
        // The cold reserve is the full toolset, Web analytics included: this
        // stack over-reserves by design, and a placeholder row that recedes
        // reads better than one that inserts under the live rows.
        DashListRowPlaceholders(rows: Self.allTools.count)
      }
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)
    } else if let zone = displayedZone {
      if isActive(zone) {
        identifiersGroup
          .dashSectionBoundary()
          .dashBodySlot(reduceMotion: reduceMotion)
        if let servers = zone.nameServers, !servers.isEmpty {
          ZoneNameserversGroup(servers: servers)
            .dashSectionBoundary()
            .dashBodySlot(reduceMotion: reduceMotion)
        }
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

  @ViewBuilder
  private func zoneHeroLandingSeat(mode: DashBodyMode, zone: CloudflareZone?) -> some View {
    Group {
      if mode.isPlaceholder || zone == nil {
        zoneHeroPlaceholder
      } else if let zone {
        zoneHero(zone)
      }
    }
    .dashNavigationLanding(.zoneHero(zoneID))
    .overlay(alignment: .bottomTrailing) {
      if zone != nil, !showsCustomizeOverlay {
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
    model.toasts.success(DashL10n.string("Zone ID copied"))
  }

  private func copyAccountID(_ accountID: String) {
    UIPasteboard.general.string = accountID
    model.toasts.success(DashL10n.string("Account ID copied"))
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
    if let navigationCoordinator {
      navigationCoordinator.removeAll(ownedBy: .zone(zoneID))
    } else {
      navigator?.removeAll(ownedBy: .zone(zoneID))
    }
    model.toasts.success(DashL10n.string("Removed from account"))
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
          "Cloudflare is rechecking now — the status usually updates within a few minutes"))
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
      // First-party path only: the header action pushes registrar detail, and
      // it is the only way into that screen — Registrar is not a catalog
      // feature. A domain registered elsewhere has no `/registrar/registrations`
      // record, so an always-on control would open a screen that 404s.
      let manageDomain = registrarRegistration?.name
      if let manageDomain {
        DashNavigationSource(destination: .registrarDomain(manageDomain)) { navigate in
          registrationInfoGroup(action: navigate)
        }
      } else {
        registrationInfoGroup(action: nil)
      }
    }
  }

  private func registrationInfoGroup(action: (() -> Void)?) -> some View {
    DashInfoGroup(
      title: "Registration",
      phase: rdapPhase,
      // The four fields below, so the arriving values land on the
      // placeholder instead of growing the section.
      placeholderRows: 4,
      retry: { Task { await retryRegistration() } },
      actionTitle: action != nil ? "Manage registration" : nil,
      actionIcon: action != nil ? SolarAsset.globus : nil,
      action: action
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

/// Assigned-nameserver reference on zone detail — above Registration when the
/// domain is active, and with the activation chrome while Cloudflare still
/// needs the records pointed. Cloudflare assigns two, so this stays bounded
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

/// Translucent white chip on the detail hero card — opens the color picker.
/// Deliberately NOT Liquid Glass and NOT a blur material (2026-08-07): a plain
/// white wash to the designer's spec — display-p3 1 1 1 / 0.8, opaque under
/// Reduce Transparency — so the pill reads identically on every card pigment.
/// The ink is pinned near-black in both appearances because the chip itself
/// is always light; it must not follow the card's luminance or the app theme.
struct DomainCardCustomizeButton: View {
  let action: () -> Void
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    Button {
      DashDelight.lightImpact()
      action()
    } label: {
      Text(DashL10n.string("Customize"))
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(Color(hex: 0x0A0A0A))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Capsule(style: .continuous))
        .background(wash, in: Capsule(style: .continuous))
    }
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel(DashL10n.string("Customize"))
    .accessibilityHint(DashL10n.string("Opens the domain card color picker"))
    .accessibilityIdentifier("domain-card-customize")
  }

  private var wash: Color {
    Color(
      .displayP3, red: 1, green: 1, blue: 1,
      opacity: reduceTransparency ? 1 : 0.8)
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
          // Animated at the write site so the preview card's enamel (a plain
          // `Shape.fill` under static grain) cross-fades to the new pigment —
          // and the ink with it — instead of snapping on the tap.
          withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
            selection = hex
          }
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
  /// True for a tool the zone only has when Cloudflare says so — today just
  /// Web analytics, which needs a site added for the domain before its screen
  /// has anything at all.
  var needsWebAnalyticsSite: Bool = false
  var id: String { title }
}
