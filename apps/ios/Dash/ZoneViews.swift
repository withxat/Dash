import CloudflareAPI
import GradientAvatars
import SwiftDitherKit
import SwiftUI
import UIKit

struct ZonesView: View {
  static let pageSize = ZonesCatalogFetchRules.pageSize

  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(DomainCardColors.key) private var domainCardColorData = ""
  @AppStorage(PinnedZones.key) private var pinnedZoneData = ""
  @AppStorage(PinnedZones.initializedAccountsKey) private var pinnedZonesInitialized = ""
  @AppStorage(DomainsListPreferences.groupByStatusKey) private var groupsByStatus = false
  /// The preference is changed by the workspace Header, which is hosted
  /// outside this page. Keep the visible layout page-local so its matched
  /// cards receive the morph transaction instead of jumping to the persisted
  /// value's final arrangement.
  @State private var displayedGroupsByStatus: Bool?
  @State private var zones: [CloudflareZone] = []
  @State private var error: String?
  @State private var loading = true
  @State private var isLoadingMore = false
  @State private var loadingMoreGeneration: Int?
  /// Bumped on every fresh `load` so an in-flight `loadMore` cannot append
  /// onto a list that was just reset / replaced.
  @State private var listGeneration = 0
  @State private var showsAddDomain = false
  @State private var pageState = DashPageState()
  @Namespace private var domainGridNamespace

  /// Pin-first paint order. `zones` / cache stay in fetch order so pagination
  /// and a later unpin can still recover the API sequence.
  private var displayedZones: [CloudflareZone] {
    guard let accountID = model.activeAccountID else { return zones }
    return PinnedZones.prioritized(
      zones, pinsRaw: pinnedZoneData, accountID: accountID, id: \.id)
  }

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
    .onChange(of: groupsByStatus, initial: true) { _, next in
      updateDisplayedGroupsByStatus(to: next)
    }
    .dashPageActions(trailing: pageTrailingActions)
    .dashTray(
      isPresented: $showsAddDomain, title: "Add domain",
      tone: FeatureVisualIdentity.tone(for: .zones)
    ) {
      AddDomainSheet {
        guard let accountID = model.activeAccountID else { return }
        model.featureCache.removeZones(accountID: accountID)
        Task { await load(force: true) }
      }
    }
  }

  private var pageTrailingActions: [DashPageActionDescriptor] {
    var actions: [DashPageActionDescriptor] = [
      .icon(
        id: "domains-group-by-status",
        asset: groupsByStatus
          ? SolarAsset.listCrossMinimalistic
          : SolarAsset.listCheckMinimalistic,
        accessibilityLabel: groupsByStatus
          ? DashL10n.string("Show ungrouped")
          : DashL10n.string("Group by status"),
        accessibilityIdentifier: "domains-group-by-status"
      ) {
        toggleGroupsByStatus()
      }
    ]
    actions.append(
      .icon(
        id: "domains-add-domain",
        asset: SolarAsset.plus,
        accessibilityLabel: DashL10n.string("Add domain"),
        isEnabled: !model.isAuthenticating,
        accessibilityIdentifier: "domains-add-domain"
      ) {
        beginAddDomain()
      }
    )
    return actions
  }

  private func beginAddDomain() {
    if featureAllowsWrites {
      showsAddDomain = true
    } else {
      model.requestAccess(to: FeatureID.zones.capability.write)
    }
  }

  private func toggleGroupsByStatus() {
    groupsByStatus.toggle()
    DashDelight.selectionChanged()
  }

  private func updateDisplayedGroupsByStatus(to target: Bool) {
    guard
      let update = DomainsGroupingPresentationRules.update(
        displayed: displayedGroupsByStatus,
        target: target,
        reduceMotion: reduceMotion)
    else { return }

    if update.animates {
      withAnimation(DashTheme.Motion.morph) {
        displayedGroupsByStatus = update.groupsByStatus
      }
    } else {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        displayedGroupsByStatus = update.groupsByStatus
      }
    }
  }

  /// Same 2-up (or 1-up a11y) grid for cold and live — surplus placeholder
  /// cards recede when fewer domains land. Live cards keep zone IDs so the
  /// group-by-status toggle can morph them between the flat grid and sections.
  @ViewBuilder
  private func domainCardGrid(mode: DashBodyMode) -> some View {
    if mode.isPlaceholder {
      placeholderDomainGrid
    } else if displayedGroupsByStatus ?? groupsByStatus {
      groupedDomainGrid(displayedZones)
    } else {
      flatDomainGrid(displayedZones)
    }
  }

  private var placeholderDomainGrid: some View {
    LazyVGrid(columns: gridColumns, spacing: DashTheme.Spacing.itemGap) {
      ForEach(0..<DashBodyPlaceholderDepth.domainCards, id: \.self) { index in
        DomainCardFace(
          name: "domain.example",
          status: "Active",
          seed: "dash.placeholder.\(index)",
          fillHex: DomainCardColors.defaultPalette[
            index % DomainCardColors.defaultPalette.count]
        )
        .dashBodyPlaceholder(true)
        .dashBodySlot(reduceMotion: reduceMotion)
      }
    }
  }

  private func flatDomainGrid(_ painted: [CloudflareZone]) -> some View {
    LazyVGrid(columns: gridColumns, spacing: DashTheme.Spacing.itemGap) {
      ForEach(painted, id: \.id) { zone in
        domainCardLink(zone)
          .matchedGeometryEffect(id: zone.id, in: domainGridNamespace)
          .dashBodySlot(reduceMotion: reduceMotion)
      }
    }
  }

  @ViewBuilder
  private func groupedDomainGrid(_ painted: [CloudflareZone]) -> some View {
    let pinnedIDs =
      model.activeAccountID.map {
        PinnedZones.pinnedZoneIDs(in: pinnedZoneData, accountID: $0)
      } ?? []
    let sections = DomainStatusSections.make(from: painted, pinnedIDs: pinnedIDs)
    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
      sectionHeader(section.title, isFirst: index == 0)
      LazyVGrid(columns: gridColumns, spacing: DashTheme.Spacing.itemGap) {
        ForEach(section.zones, id: \.id) { zone in
          domainCardLink(zone)
            .matchedGeometryEffect(id: zone.id, in: domainGridNamespace)
            .dashBodySlot(reduceMotion: reduceMotion)
        }
      }
    }
  }

  @ViewBuilder
  private func sectionHeader(_ title: String, isFirst: Bool) -> some View {
    let header = DashListGroupHeader(title: title)
      .padding(.horizontal, 4)
      .padding(.bottom, 8)
    if isFirst {
      header
    } else {
      header.dashSectionBoundary()
    }
  }

  private func domainCardLink(_ zone: CloudflareZone) -> some View {
    let fillHex = cardFillHex(for: zone)
    let status = (zone.status ?? "unknown").capitalized
    let hero = DashNavigationHero.domainCard(
      accountID: model.activeAccountID ?? "",
      zoneID: zone.id,
      name: zone.name,
      status: status,
      seed: zone.name,
      fillHex: fillHex,
      plan: zone.plan?.name)
    return DashListGroupLink(value: .zone(zone.id), hero: hero) {
      DomainCardFace(
        name: zone.name,
        status: status,
        seed: zone.name,
        fillHex: fillHex,
        pinMarker: PinnedZones.isPinned(pinnedZoneData, zoneID: zone.id) ? 1 : 0
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
      seedPinsIfNeeded(from: cached, accountID: accountID)
      pageState.reset()
      loading = false
      error = nil
      if model.featureCache.zonesCatalogIsComplete(accountID: accountID) {
        return
      }
      // A de-duplicated cached array cannot reconstruct the page cursor. Keep
      // it mounted, then refresh from page one instead of guessing and silently
      // skipping a later page.
    }
    // Cold but a stale copy exists on disk: paint it now and refresh in place
    // so an offline relaunch shows last-known data instead of a skeleton. The
    // failure path below then becomes a banner over this stale data.
    if zones.isEmpty, let stale: [CloudflareZone] = model.featureCache.getStale(key) {
      zones = stale
      seedPinsIfNeeded(from: stale, accountID: accountID)
      pageState.reset()
      loading = true
    }
    if zones.isEmpty { loading = true }
    error = nil
    listGeneration += 1
    let generation = listGeneration
    isLoadingMore = false
    loadingMoreGeneration = nil
    do {
      pageState.reset()
      try await fetchPage(accountID: accountID, generation: generation, replace: true)
      loading = false
      await loadRemainingEagerly(accountID: accountID, generation: generation)
    } catch {
      guard !error.dashIsCancellation else { return }
      guard generation == listGeneration, model.activeAccountID == accountID else { return }
      loading = false
      self.error = error.dashActionableMessage
    }
  }

  /// Walks remaining pages back-to-back until the catalog ends, the eager
  /// budget is spent, or Cloudflare rate-limits us — then the scroll footer
  /// owns whatever is left.
  private func loadRemainingEagerly(accountID: String, generation: Int) async {
    while ZonesCatalogFetchRules.shouldContinueEagerly(
      pagesFetched: max(pageState.nextPage - 1, 0),
      canLoadMore: pageState.canLoadMore
    ) {
      guard generation == listGeneration, model.activeAccountID == accountID else { return }
      guard beginLoadingMore(generation: generation) else { return }
      do {
        try await fetchPage(accountID: accountID, generation: generation, replace: false)
        finishLoadingMore(generation: generation)
      } catch {
        finishLoadingMore(generation: generation)
        guard !error.dashIsCancellation else { return }
        guard generation == listGeneration, model.activeAccountID == accountID else { return }
        // Soft stop: keep the rows we have and let the footer retry later.
        if error.dashIsRateLimited { return }
        self.error = error.dashActionableMessage
        return
      }
    }
  }

  private func loadMore() async {
    guard let accountID = model.activeAccountID, !isLoadingMore, pageState.canLoadMore
    else { return }
    let generation = listGeneration
    guard beginLoadingMore(generation: generation) else { return }
    defer { finishLoadingMore(generation: generation) }
    do {
      try await fetchPage(accountID: accountID, generation: generation, replace: false)
      error = nil
    } catch {
      guard !error.dashIsCancellation else { return }
      guard generation == listGeneration, model.activeAccountID == accountID else { return }
      self.error = error.dashActionableMessage
    }
  }

  private func fetchPage(accountID: String, generation: Int, replace: Bool) async throws {
    let pageNumber = pageState.nextPage
    let page = try await model.client.listZones(
      accountID: accountID, page: pageNumber, perPage: Self.pageSize)
    guard !Task.isCancelled else { throw CancellationError() }
    guard generation == listGeneration, model.activeAccountID == accountID else {
      throw CancellationError()
    }
    var seenIDs = replace ? Set<String>() : Set(zones.map(\.id))
    let uniqueItems = page.items.filter { seenIDs.insert($0.id).inserted }
    if replace {
      zones = uniqueItems
      seedPinsIfNeeded(from: uniqueItems, accountID: accountID)
    } else {
      zones += uniqueItems
    }
    pageState.absorb(
      info: page.resultInfo,
      requestedPage: pageNumber,
      received: page.items.count,
      added: uniqueItems.count,
      loaded: zones.count,
      pageSize: Self.pageSize)
    model.featureCache.storeZones(
      zones,
      accountID: accountID,
      catalogIsComplete: !pageState.canLoadMore)
    MetricsWidgetPublisher.syncDomains(
      zones,
      accountID: accountID,
      accountName: model.accounts.first { $0.id == accountID }?.name ?? accountID,
      replacesCatalog: !pageState.canLoadMore)
  }

  /// A pagination task may finish after a force refresh has started a newer
  /// generation. Only the generation that mounted the footer spinner may
  /// clear it; otherwise the old completion re-arms the same next-page request
  /// while the new request is still in flight.
  private func beginLoadingMore(generation: Int) -> Bool {
    guard generation == listGeneration, !isLoadingMore else { return false }
    loadingMoreGeneration = generation
    isLoadingMore = true
    return true
  }

  private func finishLoadingMore(generation: Int) {
    guard loadingMoreGeneration == generation else { return }
    loadingMoreGeneration = nil
    isLoadingMore = false
  }

  /// First non-empty zone load for an account seeds up to four pins so Home
  /// and this grid have a pin-first order without requiring a manual pin.
  private func seedPinsIfNeeded(from loaded: [CloudflareZone], accountID: String) {
    guard !loaded.isEmpty else { return }
    let result = PinnedZones.bootstrapped(
      pinnedZoneData,
      initializedAccountsRaw: pinnedZonesInitialized,
      accountID: accountID,
      defaults: loaded.map {
        PinnedZone(accountID: accountID, zoneID: $0.id, name: $0.name)
      })
    pinnedZoneData = result.pins
    pinnedZonesInitialized = result.initializedAccounts
  }
}

/// List Zones pagination policy shared by the Domains screen and its tests.
enum ZonesCatalogFetchRules {
  /// Cloudflare's List Zones `per_page` max — raising past this is rejected.
  static let pageSize = 50
  /// Automatic catalog request budget. Domains hands the remainder to its
  /// infinite-scroll footer; Email Routing stops its per-zone status fan-out
  /// at the same boundary so opening either screen cannot scan without limit.
  static let eagerPageBudget = 40

  static func shouldContinueEagerly(pagesFetched: Int, canLoadMore: Bool) -> Bool {
    canLoadMore && pagesFetched < eagerPageBudget
  }
}

struct DomainsGroupingPresentationUpdate: Equatable {
  let groupsByStatus: Bool
  let animates: Bool
}

/// The persisted preference is intent; this rule decides how the page adopts
/// it visually. Initial state is seeded without an arrival animation, while a
/// later user toggle owns one interruptible regrouping morph in the page tree.
enum DomainsGroupingPresentationRules {
  static func update(
    displayed: Bool?,
    target: Bool,
    reduceMotion: Bool = false
  ) -> DomainsGroupingPresentationUpdate? {
    guard displayed != target else { return nil }
    return DomainsGroupingPresentationUpdate(
      groupsByStatus: target,
      animates: displayed != nil && !reduceMotion)
  }
}

/// Groups domains for the categorized grid: Pinned first (pin order), then
/// status buckets. A pinned domain only appears in Pinned — not again under
/// its status — so the sections stay disjoint.
enum DomainStatusSections {
  static let pinnedKey = "pinned"
  /// Preferred status order after Pinned — anything else sorts alphabetically.
  static let preferredKeys = ["active", "pending", "initializing", "moved"]

  struct Section: Identifiable, Equatable {
    let id: String
    let title: String
    let zones: [CloudflareZone]
  }

  static func make(from zones: [CloudflareZone], pinnedIDs: [String]) -> [Section] {
    let byID = Dictionary(uniqueKeysWithValues: zones.map { ($0.id, $0) })
    let pinnedSet = Set(pinnedIDs)
    var sections: [Section] = []

    let pinnedZones = pinnedIDs.compactMap { byID[$0] }
    if !pinnedZones.isEmpty {
      sections.append(
        Section(id: pinnedKey, title: DashL10n.ui("Pinned"), zones: pinnedZones))
    }

    var buckets: [(key: String, zones: [CloudflareZone])] = []
    var indexByKey: [String: Int] = [:]
    for zone in zones where !pinnedSet.contains(zone.id) {
      let key = (zone.status ?? "unknown").lowercased()
      if let index = indexByKey[key] {
        buckets[index].zones.append(zone)
      } else {
        indexByKey[key] = buckets.count
        buckets.append((key, [zone]))
      }
    }
    buckets.sort { left, right in
      let leftRank = preferredKeys.firstIndex(of: left.key) ?? Int.max
      let rightRank = preferredKeys.firstIndex(of: right.key) ?? Int.max
      if leftRank != rightRank { return leftRank < rightRank }
      return left.key < right.key
    }
    sections.append(
      contentsOf: buckets.map { bucket in
        Section(
          id: bucket.key,
          title: statusTitle(bucket.key),
          zones: bucket.zones)
      })
    return sections
  }

  /// Prefer literal catalog keys so status section titles stay extractable
  /// (`DashL10n.ui(key.capitalized)` alone leaves "Moved" looking stale).
  private static func statusTitle(_ key: String) -> String {
    switch key {
    case "active": DashL10n.ui("Active")
    case "pending": DashL10n.ui("Pending")
    case "initializing": DashL10n.ui("Initializing")
    case "moved": DashL10n.ui("Moved")
    default: DashL10n.ui(key.capitalized)
    }
  }
}

/// Collapses detail-only card copy without changing its natural layout. The
/// surrounding VStack therefore moves the shared name/status continuously as
/// a compact card becomes its detail variant.
private struct DomainCardExtraRevealLayout: Layout {
  let progress: CGFloat

  /// The child's own ideal height at a given width. Measuring with an
  /// unspecified HEIGHT is the point: the container's height must be a
  /// function of (width, progress) and nothing else. Passing the incoming
  /// proposal's height straight through made the container flexible, so
  /// SwiftUI's `.zero` / `.infinity` probes both came back scaled by an
  /// animating `progress` — the parent `VStack` then re-did its flexible-child
  /// arithmetic on every frame of the card morph, with a `lineLimit(2)`
  /// `minimumScaleFactor` name in the same stack to flip between one and two
  /// lines mid-flight.
  private func naturalSize(
    _ subview: LayoutSubview,
    width: CGFloat?
  ) -> CGSize {
    subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    guard let subview = subviews.first else { return .zero }
    let natural = naturalSize(subview, width: proposal.width)
    let resolved = min(max(progress, 0), 1)
    return CGSize(width: natural.width, height: natural.height * resolved)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    guard let subview = subviews.first else { return }
    // Measured at the width the child is actually GIVEN, not at the width it
    // was proposed: those differ whenever the parent resolves something other
    // than the proposal, and a height measured for the wrong width is the
    // wrong height to place with — wrapping copy would be cut mid-line.
    let natural = naturalSize(subview, width: bounds.width)
    subview.place(
      at: CGPoint(x: bounds.minX, y: bounds.maxY),
      anchor: .bottomLeading,
      proposal: ProposedViewSize(width: bounds.width, height: natural.height))
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

  /// Accessibility sizes keep the expanded card tall enough for a two-line
  /// domain, status, and detail metadata. The same resolver feeds every live,
  /// placeholder, and customize landing seat so a morph never hands off to a
  /// differently sized card.
  static func detailAspectRatio(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
    dynamicTypeSize.isAccessibilitySize ? gridAspectRatio : detailAspectRatio
  }

  let name: String
  let status: String
  let seed: String
  let fillHex: UInt32
  var plan: String? = nil
  var meta: String? = nil
  /// Optional low-contrast mark embedded behind the card contents. The mark is
  /// clipped to the enamel face while the card's exterior emboss stays free to
  /// paint beyond it.
  var textureAsset: String? = nil
  /// Presence of the pinned marker, 0…1. The grid states the fact (1 when the
  /// zone is pinned); the flight hero fades it inversely to `detailReveal`
  /// because the marker is grid-pose vocabulary — the detail card leaves pin
  /// state to its header action, the way `tileExtras` is detail-pose only.
  var pinMarker: CGFloat = 0
  var aspectRatio: CGFloat = DomainCardFace.gridAspectRatio
  /// Transition hosts own the animated bounds. In that context the card fills
  /// every intermediate rect and SwiftUI reflows its contents inside it.
  var fillsContainer = false
  /// Detail-only content grows into layout instead of appearing at the source
  /// endpoint or crossfading a second complete card over the first one.
  var detailReveal: CGFloat = 1

  /// One size in both poses, like the name and status above it: the taller
  /// detail card is the same components with more room between them.
  private let avatarSize: CGFloat = 28
  private let cornerRadius: CGFloat = DashTheme.Radius.button
  private var foreground: Color { DomainCardColors.foreground(fillHex) }
  private var secondaryForeground: Color { DomainCardColors.secondaryForeground(fillHex) }
  /// The card morph's spring overshoots past 1 on purpose; content reads a
  /// clamped copy, because only the hero's frame is allowed to extrapolate.
  private var reveal: CGFloat { min(max(detailReveal, 0), 1) }

  /// Active is the default and needs no per-card label; only deviating states
  /// (pending / initializing / moved…) get a status line. Every caller passes
  /// the display string, so the rule lives here once — the grid, the detail
  /// hero, the color-customize preview, and the flight morph all agree.
  private var showsStatus: Bool {
    status.caseInsensitiveCompare("Active") != .orderedSame
  }

  private var accessibilitySummary: String {
    var parts = [name]
    if showsStatus { parts.append(DashL10n.ui(status)) }
    if let plan { parts.append(DashL10n.ui(plan)) }
    if let meta { parts.append(meta) }
    if pinMarker > 0.5 { parts.append(DashL10n.string("Pinned")) }
    return parts.joined(separator: ", ")
  }

  @ViewBuilder
  var body: some View {
    if fillsContainer {
      face
    } else {
      face.aspectRatio(aspectRatio, contentMode: .fit)
    }
  }

  private var face: some View {
    VStack(alignment: .leading, spacing: 0) {
      GradientAvatar(seed: seed, size: avatarSize, pattern: .dither, contentScale: 1.5)
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
          if pinMarker > 0 {
            SolarIcon(asset: SolarAsset.pinFilled, size: 16, color: secondaryForeground)
              .opacity(min(max(pinMarker, 0), 1))
              .accessibilityHidden(true)
          }
        }
      Spacer(minLength: 12)
      Text(name)
        .dashTextStyle(.bodySemibold)
        .foregroundStyle(foreground)
        .lineLimit(2)
        .minimumScaleFactor(0.85)
      if showsStatus {
        Text(DashL10n.ui(status))
          .dashTextStyle(.footnote)
          .foregroundStyle(secondaryForeground)
          .lineLimit(1)
      }

      if plan != nil || meta != nil {
        DomainCardExtraRevealLayout(progress: detailReveal) {
          tileExtras
            .opacity(reveal)
            .offset(y: (1 - reveal) * 4)
        }
        .clipped()
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
      .overlay(alignment: .topTrailing) {
        if let textureAsset {
          SolarIcon(asset: textureAsset, size: 96, color: foreground)
            .opacity(0.1)
            .offset(x: 20, y: -22)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
    .dashEmbossed(.pigmented, cornerRadius: cornerRadius)
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
