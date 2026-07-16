import CloudflareAPI
import SwiftUI

struct HomeView: View {
  @AppStorage(RecentResources.key) private var recentResourceData = ""
  @Environment(AppModel.self) private var model
  @State private var watchtowerSnapshot: WatchtowerSnapshot?
  @State private var watchtowerLoading = true

  private var continueResources: [RecentResource] {
    RecentResources.continueItems(
      recent: RecentResources.decode(recentResourceData),
      accountID: model.activeAccountID)
  }

  var body: some View {
    let zonesIndex = model.identityStale ? 1 : 0
    let watchtowerIndex = zonesIndex
    let pinnedZonesIndex = watchtowerIndex + 1
    let continueResourcesIndex = pinnedZonesIndex + 1

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
        DashListGroup(title: "Account status") {
          Button {
            model.pendingRoute = .watchtower
          } label: {
            HomeWatchtowerSummary(
              snapshot: watchtowerSnapshot,
              isLoading: watchtowerLoading
            )
          }
          .buttonStyle(DashPressButtonStyle())
          .accessibilityIdentifier("home-watchtower-summary")
        }
        .dashSectionReveal(watchtowerIndex)
        HomeZonesSection()
          .dashSectionReveal(pinnedZonesIndex)
        if !continueResources.isEmpty {
          DashListGroup(title: "Recent") {
            ForEach(continueResources) { resource in
              DashListGroupLink(
                value: resource.destination,
                onNavigate: { RecentResources.record(resource) }
              ) {
                DashListRow(
                  title: resource.title,
                  subtitle: resource.kind.displayName,
                  icon: resource.featureID.solarOutlineAssetName,
                  iconColor: FeatureVisualIdentity.catalogColor(for: resource.featureID)
                )
              }
            }
          }
          .dashSectionReveal(continueResourcesIndex)
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, DashTheme.Spacing.section)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .dashSectionEntrance()
    .dashCatalogScreen("Home")
    .task(id: model.activeAccountID) { await loadWatchtowerSummary() }
  }

  private func loadWatchtowerSummary() async {
    let accountID = model.activeAccountID
    watchtowerSnapshot = nil
    watchtowerLoading = true
    let snapshot = await model.watchtowerSnapshot()
    guard !Task.isCancelled, model.activeAccountID == accountID else { return }
    watchtowerSnapshot = snapshot
    watchtowerLoading = false
  }
}

func homeWatchtowerCheckedText(fetchedAt: Date?, now: Date = .now) -> String {
  guard let fetchedAt else { return "Open Watchtower to check this account" }
  let age = max(0, now.timeIntervalSince(fetchedAt))
  if age < 60 { return "Checked just now" }
  if age < 3_600 { return "Checked \(Int(age / 60)) min ago" }
  if age < 86_400 { return "Checked \(Int(age / 3_600)) hr ago" }
  let days = Int(age / 86_400)
  return "Checked \(days) day\(days == 1 ? "" : "s") ago"
}

private struct HomeWatchtowerSummary: View {
  let snapshot: WatchtowerSnapshot?
  let isLoading: Bool

  private var criticalCount: Int {
    snapshot?.signals.count { $0.status == .critical } ?? 0
  }

  private var warningCount: Int {
    snapshot?.signals.count { $0.status == .warning } ?? 0
  }

  private var title: String {
    guard let snapshot else { return isLoading ? "Checking account" : "Watchtower" }
    if snapshot.issueCount == 0 { return "All systems normal" }
    return "\(snapshot.issueCount) issue\(snapshot.issueCount == 1 ? "" : "s") need attention"
  }

  private var icon: String {
    criticalCount > 0 || warningCount > 0 ? SolarAsset.danger : SolarAsset.shieldCheck
  }

  private var color: Color {
    if criticalCount > 0 { return DashTheme.danger }
    if warningCount > 0 { return DashTheme.warning }
    return DashTheme.success
  }

  private var subtitle: String {
    if isLoading, snapshot == nil { return "Running account checks…" }
    return homeWatchtowerCheckedText(fetchedAt: snapshot?.fetchedAt)
  }

  var body: some View {
    HStack(spacing: 12) {
      SolarIcon(asset: icon, size: 22, color: color)
        .frame(width: 40, height: 40)
        .background(color.opacity(0.12), in: DashTheme.buttonShape)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .dashTextStyle(.bodySemibold)
          .foregroundStyle(DashTheme.text)
        Text(subtitle)
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.rowSubtitle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if isLoading, snapshot == nil {
        DashLoadingRing(color: DashTheme.brand, size: 18, lineWidth: 2.5)
      } else {
        SolarIcon(asset: SolarAsset.chevronRight, size: 16, color: DashTheme.placeholder)
      }
    }
    .padding(.vertical, 10)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityHint("Opens Watchtower")
  }
}

enum HomeZonesPullDecision {
  static let threshold: CGFloat = 64

  /// Rubber-band distance past the trailing edge of the strip. Zero while the
  /// content still has room to scroll, and always zero for a strip too short
  /// to scroll at all, so it can never trigger.
  static func overscroll(
    contentOffsetX: CGFloat, containerWidth: CGFloat, contentWidth: CGFloat
  ) -> CGFloat {
    guard contentWidth > containerWidth else { return 0 }
    return max(0, contentOffsetX + containerWidth - contentWidth)
  }

  static func progress(distance: CGFloat, threshold: CGFloat = threshold) -> CGFloat {
    guard threshold > 0 else { return 1 }
    return min(max(distance / threshold, 0), 1)
  }

  static func shouldOpen(distance: CGFloat, threshold: CGFloat = threshold) -> Bool {
    distance >= threshold
  }
}

private struct HomeZonesSection: View {
  private static let limit = 4

  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @AppStorage(PinnedZones.key) private var pinnedZoneData = ""
  @AppStorage(PinnedZones.initializedAccountsKey) private var initializedAccounts = ""
  @State private var zones: [CloudflareZone] = []
  @State private var loading = true
  @State private var error: String?

  private var displayedZones: [CloudflareZone] {
    guard let accountID = model.activeAccountID else { return [] }
    let zoneByID = Dictionary(uniqueKeysWithValues: zones.map { ($0.id, $0) })
    let pinnedIDs = PinnedZones.pinnedZoneIDs(in: pinnedZoneData, accountID: accountID)
    return pinnedIDs.compactMap { zoneByID[$0] }.prefix(Self.limit).map { $0 }
  }

  var body: some View {
    DashListGroup(
      title: "Your Zones",
      actionTitle: "View all",
      actionIcon: SolarAsset.chevronRight,
      action: openAllZones
    ) {
      Group {
        if loading, zones.isEmpty {
          loadingTiles
        } else if let error, zones.isEmpty {
          DashNotice(kind: .error, message: error)
        } else if displayedZones.isEmpty {
          Text(zones.isEmpty ? "No zones in this account." : "Pin a zone to keep it here.")
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16)
        } else if dynamicTypeSize.isAccessibilitySize {
          accessibleZoneList
        } else {
          zoneStrip
        }
      }
    }
    .task(id: model.activeAccountID) { await load() }
  }

  private var loadingTiles: some View {
    HStack(spacing: DashTheme.Spacing.itemGap) {
      ForEach(0..<2, id: \.self) { _ in
        RoundedRectangle(cornerRadius: DashTheme.Radius.button, style: .continuous)
          .fill(DashTheme.recessed)
          .frame(maxWidth: .infinity)
          .frame(height: 112)
      }
    }
    .accessibilityHidden(true)
  }

  private var zoneStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: DashTheme.Spacing.itemGap) {
        ForEach(displayedZones) { zone in
          DashListGroupLink(value: .zone(zone.id)) {
            HomeZoneTile(zone: zone)
          }
          .containerRelativeFrame(
            .horizontal,
            count: 2,
            span: 1,
            spacing: DashTheme.Spacing.itemGap
          )
          .id(zone.id)
        }
      }
      .scrollTargetLayout()
    }
    .scrollTargetBehavior(.viewAligned)
    .frame(height: 112)
    .accessibilityIdentifier("home-zones-strip")
    .dashHomeZonesPullToOpen(perform: openAllZones)
  }

  private var accessibleZoneList: some View {
    VStack(spacing: 0) {
      ForEach(Array(displayedZones.enumerated()), id: \.element.id) { index, zone in
        DashListGroupLink(value: .zone(zone.id)) {
          DashListRow(
            title: zone.name,
            subtitle: (zone.status ?? "unknown").capitalized,
            icon: SolarAsset.globus,
            iconColor: DashTheme.success
          )
        }
        if index < displayedZones.count - 1 {
          DashListGroupDivider()
        }
      }
    }
  }

  private func openAllZones() {
    model.pendingRoute = .feature(.zones)
  }

  private func load() async {
    guard let accountID = model.activeAccountID else {
      zones = []
      loading = false
      error = nil
      return
    }

    zones = []
    loading = true
    error = nil
    let key = FeatureCacheKey.zones(accountID)
    if let cached: [CloudflareZone] = model.featureCache.get(key) {
      accept(cached, accountID: accountID)
      loading = false
      return
    }

    do {
      let page = try await model.client.listZones(
        accountID: accountID,
        page: 1,
        perPage: ZonesView.pageSize)
      accept(page.items, accountID: accountID)
      model.featureCache.set(key, page.items)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }

  private func accept(_ loadedZones: [CloudflareZone], accountID: String) {
    zones = loadedZones
    let defaults = loadedZones.prefix(Self.limit).map {
      PinnedZone(accountID: accountID, zoneID: $0.id, name: $0.name)
    }
    let bootstrapped = PinnedZones.bootstrapped(
      pinnedZoneData,
      initializedAccountsRaw: initializedAccounts,
      accountID: accountID,
      defaults: Array(defaults),
      limit: Self.limit)
    pinnedZoneData = bootstrapped.pins
    initializedAccounts = bootstrapped.initializedAccounts
  }
}

extension View {
  /// Trailing overscroll-to-open for the zones strip. Scroll geometry APIs
  /// need iOS 18; on iOS 17 the header's View all button stays the only way in.
  @ViewBuilder
  fileprivate func dashHomeZonesPullToOpen(perform action: @escaping () -> Void) -> some View {
    if #available(iOS 18.0, *) {
      modifier(HomeZonesPullToOpenModifier(onPull: action))
    } else {
      self
    }
  }
}

@available(iOS 18.0, *)
private struct HomeZonesPullToOpenModifier: ViewModifier {
  let onPull: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var overscroll: CGFloat = 0
  @State private var dragging = false
  @State private var triggered = false

  func body(content: Content) -> some View {
    content
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        HomeZonesPullDecision.overscroll(
          contentOffsetX: geometry.contentOffset.x,
          containerWidth: geometry.containerSize.width,
          contentWidth: geometry.contentSize.width)
      } action: { _, distance in
        overscroll = distance
        if distance == 0 {
          triggered = false
          return
        }
        // Only a live drag opens the list; a fling that bounces off the end
        // stays a scroll.
        guard !triggered, dragging, HomeZonesPullDecision.shouldOpen(distance: distance) else {
          return
        }
        triggered = true
        onPull()
      }
      .onScrollPhaseChange { _, newPhase in
        dragging = newPhase == .interacting
      }
      .overlay(alignment: .trailing) { indicator }
      .sensoryFeedback(.impact(weight: .medium), trigger: triggered) { _, isTriggered in
        isTriggered
      }
  }

  private var indicator: some View {
    let progress = HomeZonesPullDecision.progress(distance: overscroll)
    return ZStack {
      Circle()
        .fill(progress >= 1 ? DashTheme.infoTint : DashTheme.recessed)
      SolarIcon(
        asset: SolarAsset.chevronRight,
        size: 18,
        color: progress >= 1 ? DashTheme.brand : DashTheme.subtle)
    }
    .frame(width: 44, height: 44)
    .scaleEffect(reduceMotion ? 1 : 0.72 + 0.28 * progress)
    .opacity(progress)
    .offset(x: reduceMotion ? 0 : 16 * (1 - progress))
    .padding(.trailing, 6)
    .animation(reduceMotion ? nil : DashTheme.Motion.quick, value: progress >= 1)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct HomeZoneTile: View {
  let zone: CloudflareZone

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SolarIcon(asset: SolarAsset.globus, size: 28, color: DashTheme.success)
        .frame(maxWidth: .infinity, alignment: .leading)
      Spacer(minLength: 6)
      VStack(alignment: .leading, spacing: 2) {
        Text(zone.name)
          .dashTextStyle(.bodySemibold)
          .foregroundStyle(DashTheme.text)
          .lineLimit(2)
          .minimumScaleFactor(0.82)
        Text((zone.status ?? "unknown").capitalized)
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.rowSubtitle)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88, alignment: .topLeading)
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(DashTheme.recessed, in: DashTheme.buttonShape)
    .contentShape(DashTheme.buttonShape)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(zone.name), \(zone.status ?? "unknown"), pinned")
  }
}

struct FeatureSection: View {
  let title: String
  let items: [FeatureID]
  var iconStyle: CatalogFeatureIcon.Style = .duotone
  var presentation: FeatureRow.Presentation = .catalog
  var actionTitle: String?
  var actionIcon: String?
  var action: (() -> Void)?
  /// Regular-width Resources sidebar selection; nil keeps NavigationLink push behavior.
  var selection: Binding<FeatureID?>?

  init(
    title: String,
    items: [FeatureID],
    iconStyle: CatalogFeatureIcon.Style = .duotone,
    presentation: FeatureRow.Presentation = .catalog,
    actionTitle: String? = nil,
    actionIcon: String? = nil,
    action: (() -> Void)? = nil,
    selection: Binding<FeatureID?>? = nil
  ) {
    self.title = title
    self.items = items
    self.iconStyle = iconStyle
    self.presentation = presentation
    self.actionTitle = actionTitle
    self.actionIcon = actionIcon
    self.action = action
    self.selection = selection
  }

  var body: some View {
    DashListGroup(title: title, actionTitle: actionTitle, actionIcon: actionIcon, action: action) {
      FeatureRows(
        items: items,
        iconStyle: iconStyle,
        presentation: presentation,
        selection: selection
      )
    }
  }
}

/// Shared feature navigation rows. Grouped catalogs seat these inside a
/// `DashListGroup`; alternate orders use them in a title-free `DashListCard`.
struct FeatureRows: View {
  let items: [FeatureID]
  var iconStyle: CatalogFeatureIcon.Style = .duotone
  var presentation: FeatureRow.Presentation = .catalog
  var selection: Binding<FeatureID?>?

  var body: some View {
    ForEach(items, id: \.self) { item in
      if let selection {
        Button {
          selection.wrappedValue = item
        } label: {
          FeatureRow(feature: item, iconStyle: iconStyle, presentation: presentation)
            .overlay {
              RoundedRectangle(cornerRadius: DashTheme.Radius.button, style: .continuous)
                .stroke(DashTheme.brand, lineWidth: 2)
                .opacity(selection.wrappedValue == item ? 1 : 0)
            }
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityAddTraits(selection.wrappedValue == item ? .isSelected : [])
      } else {
        DashListGroupLink(value: .feature(item)) {
          FeatureRow(feature: item, iconStyle: iconStyle, presentation: presentation)
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
  var iconStyle: CatalogFeatureIcon.Style = .duotone
  var presentation: Presentation = .catalog

  private var accessLevel: FeatureAccessLevel {
    feature.capability.accessLevel(grantedScopes: model.grantedScopes)
  }

  private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

  private var onCard: Color { FeatureVisualIdentity.onCardColor(for: feature) }

  private var transitionBackground: Color {
    switch presentation {
    case .vividCard: FeatureVisualIdentity.cardColor(for: feature)
    case .catalog: DashTheme.canvas
    }
  }

  private var transitionCornerRadius: CGFloat {
    switch presentation {
    case .vividCard: DashTheme.Radius.button
    case .catalog: DashTheme.Radius.medium
    }
  }

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
    .dashFeatureTransitionSource(
      feature,
      background: transitionBackground,
      cornerRadius: transitionCornerRadius
    )
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
            leadingIcon
            Spacer(minLength: 0)
            accessBadge
          }
          catalogLabels
        }
      } else {
        // labelStack's greedy frame fills the row and pushes the trailing badge
        // to the edge; no Spacer needed.
        HStack(spacing: 12) {
          leadingIcon
          catalogLabels
          accessBadge
        }
      }
    }
    .padding(.vertical, 12)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
  }

  private var leadingIcon: some View {
    CatalogFeatureIcon(feature: feature, style: iconStyle, size: .list)
      .opacity(accessLevel == .locked ? 0.55 : 1)
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

  private var catalogLabels: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(feature.title)
        .dashTextStyle(.bodySemibold)
        .foregroundStyle(DashTheme.text)
        .lineLimit(isAccessibilitySize ? nil : 1)
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
