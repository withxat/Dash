import BlossomColorPickerCore
import CloudflareAPI
import GradientAvatars
import SwiftDitherKit
import SwiftUI

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
    .toolbar {
      if !model.isDemoSession {
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarIconButton(
            asset: SolarAsset.plus,
            accessibilityLabel: "Add domain"
          ) {
            beginAddDomain()
          }
          .disabled(model.isAuthenticating)
          .accessibilityIdentifier("domains-add-domain")
        }
        .dashSeparateToolbarBackground()
      }
    }
    .dashTray(isPresented: $showsAddDomain, title: "Add domain") {
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
  /// Draft fill while customizing; committed only by Done.
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
            asset: SolarAsset.editClose,
            accessibilityLabel: "Cancel",
            action: cancelCardCustomize
          )
          .disabled(isExitingCardCustomize)
          .accessibilityIdentifier("domain-card-customize-close")
        }
        .dashSeparateToolbarBackground()
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarIconButton(
            asset: SolarAsset.unread,
            accessibilityLabel: "Done",
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
        ? "Save" : (model.isDemoSession ? "Connect your account" : "Grant write access"),
      isSaving: saving,
      canSave: allowsWrites ? canSave : true,
      deleteMessage: allowsWrites
        ? record.map {
          DashL10n.string("Permanently delete the \($0.type) record for \($0.name).")
        } : nil,
      isDeleting: deleting,
      deleteError: error,
      onDelete: allowsWrites ? record.map { rec in { Task { await delete(rec) } } } : nil,
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
              message: "Read-only — grant DNS write access to edit or delete this record.")
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
    guard allowsWrites else {
      model.requestAccess(to: requiredWriteScopes)
      return
    }
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
