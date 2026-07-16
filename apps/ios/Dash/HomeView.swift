import CloudflareAPI
import SwiftUI

struct HomeView: View {
  @AppStorage("dash.home_shortcuts") private var shortcutData = FeatureCatalog.defaultShortcutData
  @AppStorage(RecentResources.key) private var recentResourceData = ""
  @Environment(\.showsEditShortcuts) private var showsEditShortcuts
  @Environment(AppModel.self) private var model

  private var shortcuts: [FeatureID] {
    shortcutData.split(separator: ",")
      .compactMap { FeatureID(rawValue: String($0)) }
  }
  private var continueResources: [RecentResource] {
    RecentResources.continueItems(
      recent: RecentResources.decode(recentResourceData),
      accountID: model.activeAccountID)
  }

  var body: some View {
    let zonesIndex = model.identityStale ? 1 : 0
    let shortcutsIndex = zonesIndex + 1
    let continueResourcesIndex = shortcutsIndex + 1

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
        HomeZonesSection()
          .dashSectionReveal(zonesIndex)
        DashListGroup(
          title: "Shortcuts", actionTitle: "Edit", actionIcon: SolarAsset.pen,
          action: { showsEditShortcuts.wrappedValue = true }
        ) {
          FeatureRows(items: shortcuts)
        }
        .dashSectionReveal(shortcutsIndex)
        if !continueResources.isEmpty {
          DashListGroup(title: "Continue") {
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
  }
}

enum HomeZonesPullDecision {
  static let threshold: CGFloat = 64

  static func progress(distance: CGFloat, threshold: CGFloat = threshold) -> CGFloat {
    guard threshold > 0 else { return 1 }
    return min(max(distance / threshold, 0), 1)
  }

  static func shouldOpen(distance: CGFloat, threshold: CGFloat = threshold) -> Bool {
    distance >= threshold
  }
}

private struct HomeZonesPullTargetPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

private struct HomeZonesSection: View {
  private static let limit = 4
  private static let scrollSpace = "home-zones-scroll"
  private static let pullTargetID = "all-zones"
  private static let pullTargetWidth: CGFloat = 72

  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(PinnedZones.key) private var pinnedZoneData = ""
  @AppStorage(PinnedZones.initializedAccountsKey) private var initializedAccounts = ""
  @State private var zones: [CloudflareZone] = []
  @State private var loading = true
  @State private var error: String?
  @State private var pullTargetMinX: CGFloat = 0
  @State private var initialPullTargetMinX: CGFloat?
  @State private var pullTriggered = false

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
    GeometryReader { proxy in
      let pullDistance = exposedPullTargetDistance(containerWidth: proxy.size.width)
      let progress = HomeZonesPullDecision.progress(distance: pullDistance)

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

          pullTarget(progress: progress)
            .frame(width: Self.pullTargetWidth, height: 112)
            .id(Self.pullTargetID)
            .background {
              GeometryReader { edgeProxy in
                Color.clear.preference(
                  key: HomeZonesPullTargetPreferenceKey.self,
                  value: edgeProxy.frame(in: .named(Self.scrollSpace)).minX)
              }
            }
        }
        .scrollTargetLayout()
      }
      .scrollTargetBehavior(.viewAligned)
      .coordinateSpace(name: Self.scrollSpace)
      .accessibilityIdentifier("home-zones-strip")
      .onPreferenceChange(HomeZonesPullTargetPreferenceKey.self) { minX in
        guard minX > 0 else { return }
        if initialPullTargetMinX == nil { initialPullTargetMinX = minX }
        pullTargetMinX = minX

        let distance = min(Self.pullTargetWidth, max(0, proxy.size.width - minX))
        if distance == 0 { pullTriggered = false }
        guard
          !pullTriggered,
          let initialPullTargetMinX,
          minX < initialPullTargetMinX - 8,
          HomeZonesPullDecision.shouldOpen(distance: distance)
        else { return }
        pullTriggered = true
        openAllZones()
      }
    }
    .frame(height: 112)
  }

  private func pullTarget(progress: CGFloat) -> some View {
    ZStack {
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
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func exposedPullTargetDistance(containerWidth: CGFloat) -> CGFloat {
    guard pullTargetMinX > 0 else { return 0 }
    return min(Self.pullTargetWidth, max(0, containerWidth - pullTargetMinX))
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
  /// Regular-width Features sidebar selection; nil keeps NavigationLink push behavior.
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

struct EditShortcutsView: View {
  @AppStorage("dash.home_shortcuts") private var shortcutData = FeatureCatalog.defaultShortcutData

  private var selection: [FeatureID] {
    shortcutData.split(separator: ",")
      .compactMap { FeatureID(rawValue: String($0)) }
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 12) {
        ForEach(FeatureCatalog.all) { feature in
          HStack(spacing: 12) {
            DashListGroupLink(value: .feature(feature)) {
              HStack(spacing: 12) {
                CatalogFeatureIcon(feature: feature, size: .shortcut)
                Text(feature.title)
                  .dashTextStyle(.bodyMedium)
                  .foregroundStyle(DashTheme.text)
                  .lineLimit(1)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            ShortcutSelectionToggle(
              isSelected: selection.contains(feature),
              action: { toggle(feature) }
            )
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(DashTheme.Sheet.shortcutItem)
          .clipShape(DashTheme.buttonShape)
        }
      }
      .padding(.top, DashTheme.Sheet.bodyVertical)
      .padding(.horizontal, DashTheme.Sheet.content)
      .padding(.bottom, DashTheme.Sheet.bodyBottom)
    }
    .safeAreaPadding(.bottom)
  }

  private func toggle(_ feature: FeatureID) {
    var items = selection
    if let index = items.firstIndex(of: feature) {
      items.remove(at: index)
    } else {
      items.append(feature)
    }
    withAnimation(DashTheme.Motion.quick) {
      shortcutData = items.map(\.rawValue).joined(separator: ",")
    }
  }
}

private struct ShortcutSelectionToggle: View {
  let isSelected: Bool
  let action: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: action) {
      ZStack {
        Image(SolarAsset.circle)
          .resizable()
          .renderingMode(.template)
          .scaledToFit()
          .foregroundStyle(DashTheme.placeholder)
          .opacity(isSelected ? 0 : 1)

        Image(SolarAsset.checkCircleFill)
          .resizable()
          .renderingMode(.template)
          .scaledToFit()
          .foregroundStyle(DashTheme.brand)
          .opacity(isSelected ? 1 : 0)
      }
      .frame(width: 22, height: 22)
      .animation(reduceMotion ? nil : DashTheme.Motion.quick, value: isSelected)
    }
    .buttonStyle(DashPressButtonStyle())
    .dashCompactHitTarget()
    .accessibilityLabel(isSelected ? "Remove from shortcuts" : "Add to shortcuts")
  }
}
