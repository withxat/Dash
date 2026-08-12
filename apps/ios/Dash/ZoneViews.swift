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
  @AppStorage(PinnedZones.key) private var pinnedZoneData = ""
  @AppStorage(PinnedZones.initializedAccountsKey) private var pinnedZonesInitialized = ""
  @State private var zones: [CloudflareZone] = []
  @State private var error: String?
  @State private var loading = true
  @State private var isLoadingMore = false
  /// Bumped on every fresh `load` so an in-flight `loadMore` cannot append
  /// onto a list that was just reset / replaced.
  @State private var listGeneration = 0
  @State private var showsAddDomain = false
  @State private var pageState = DashPageState()

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
    .dashPageActions(
      trailing: model.isDemoSession
        ? []
        : [
          .icon(
            id: "domains-add-domain",
            asset: SolarAsset.plus,
            accessibilityLabel: DashL10n.string("Add domain"),
            isEnabled: !model.isAuthenticating,
            accessibilityIdentifier: "domains-add-domain"
          ) {
            beginAddDomain()
          }
        ]
    )
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
    let painted = displayedZones
    let count =
      mode.isPlaceholder
      ? DashBodyPlaceholderDepth.domainCards
      : painted.count
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
            domainCardLink(painted[index])
          }
        }
        .dashBodySlot(reduceMotion: reduceMotion)
      }
    }
  }

  private func domainCardLink(_ zone: CloudflareZone) -> some View {
    let fillHex = cardFillHex(for: zone)
    let status = (zone.status ?? "unknown").capitalized
    let hero = DashNavigationHero.domainCard(
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
      seedPinsIfNeeded(from: stale, accountID: accountID)
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
      seedPinsIfNeeded(from: page.items, accountID: accountID)
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

  let name: String
  let status: String
  let seed: String
  let fillHex: UInt32
  var plan: String? = nil
  var meta: String? = nil
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
