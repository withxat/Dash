import CloudflareAPI
import SwiftUI

struct HomeView: View {
  @AppStorage("dash.home_shortcuts") private var shortcutData = "zones,workers,r2,kv"
  @AppStorage(RecentResources.key) private var recentResourceData = ""
  @AppStorage(PinnedZones.key) private var pinnedZoneData = ""
  @Environment(\.showsEditShortcuts) private var showsEditShortcuts
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(AppModel.self) private var model

  private var shortcuts: [FeatureID] {
    shortcutData.split(separator: ",")
      .compactMap { FeatureID(rawValue: String($0)) }
      .filter { !DashAuthorizationScopes.experimentalFeatures.contains($0) }
  }
  private var pinnedZones: [PinnedZone] {
    PinnedZones.decode(pinnedZoneData).filter { $0.accountID == model.activeAccountID }
  }
  private var continueResources: [RecentResource] {
    RecentResources.continueItems(
      recent: RecentResources.decode(recentResourceData),
      accountID: model.activeAccountID)
  }
  private var shortcutColumns: [GridItem] {
    let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
    return Array(
      repeating: GridItem(.flexible(), spacing: DashTheme.Spacing.itemGap), count: count)
  }

  var body: some View {
    let summaryIndex = model.identityStale ? 1 : 0
    let shortcutsIndex = summaryIndex + 1
    let pinnedIndex = shortcutsIndex + 1
    let continueResourcesIndex = pinnedIndex + (pinnedZones.isEmpty ? 0 : 1)
    let footerIndex = continueResourcesIndex + (continueResources.isEmpty ? 0 : 1)

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
        HomeWatchtowerSummaryCard()
          .dashSectionReveal(summaryIndex)
        DashListGroup(
          title: "Shortcuts", actionTitle: "Edit", actionIcon: SolarAsset.pen,
          action: { showsEditShortcuts.wrappedValue = true }
        ) {
          LazyVGrid(columns: shortcutColumns, spacing: DashTheme.Spacing.itemGap) {
            ForEach(shortcuts, id: \.self) { feature in
              DashListGroupLink(value: .feature(feature)) {
                ShortcutTile(feature: feature)
              }
            }
          }
        }
        .dashSectionReveal(shortcutsIndex)
        if !pinnedZones.isEmpty {
          DashListGroup(title: "Pinned zones") {
            ForEach(Array(pinnedZones.enumerated()), id: \.element) { _, pin in
              DashListGroupLink(value: .zone(pin.zoneID)) {
                DashListRow(title: pin.name, icon: SolarAsset.pin)
              }
            }
          }
          .dashSectionReveal(pinnedIndex)
        }
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
        Text("Browse tools in Features, or use Search to find a resource.")
          .dashTextStyle(.micro)
          .foregroundStyle(DashTheme.placeholder)
          .frame(maxWidth: .infinity)
          .dashSectionReveal(footerIndex)
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .dashSectionEntrance()
    .dashCatalogScreen("Home")
  }
}

private struct HomeWatchtowerSummaryCard: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var snapshot: WatchtowerSnapshot? {
    guard let accountID = model.activeAccountID else { return nil }
    return model.featureCache.get(FeatureCacheKey.watchtower(accountID))
  }

  private var issueCount: Int? { model.watchtowerIssueCount }

  private var isLoading: Bool {
    model.activeAccountID != nil && issueCount == nil
  }

  var body: some View {
    Button {
      model.pendingRoute = .watchtower
    } label: {
      DashCard {
        if model.activeAccountID == nil {
          Text("No Cloudflare account is available for this user.")
            .dashTextStyle(.supporting)
            .foregroundStyle(DashTheme.subtle)
        } else {
          ZStack(alignment: .leading) {
            skeletonBody
              .opacity(isLoading ? 1 : 0)
              .blur(radius: reduceMotion || isLoading ? 0 : 4)
            readyBody
              .opacity(isLoading ? 0 : 1)
              .blur(radius: reduceMotion || !isLoading ? 0 : 4)
              .accessibilityHidden(isLoading)
          }
          .animation(reduceMotion ? nil : DashTheme.Motion.content, value: isLoading)
        }
      }
    }
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel(isLoading ? "Checking account health" : "Open Watchtower")
  }

  /// Stays mounted beneath `readyBody` so their shared ZStack reserves the
  /// larger geometry before data lands.
  private var skeletonBody: some View {
    HStack(alignment: .center, spacing: 12) {
      HomeSkeletonBone(width: 28, height: 28, cornerRadius: DashTheme.Radius.small)
      VStack(alignment: .leading, spacing: 6) {
        HomeSkeletonBone(width: 168, height: 16)
        HomeSkeletonBone(width: 128, height: 11)
      }
      Spacer(minLength: 0)
      HomeSkeletonBone(width: 10, height: 14, cornerRadius: 3)
    }
    .accessibilityHidden(true)
  }

  private var readyBody: some View {
    let issues = issueCount ?? 0
    let allClear = issues == 0
    return HStack(alignment: .center, spacing: 12) {
      SolarIcon(
        asset: allClear ? SolarAsset.shieldCheck : SolarAsset.danger,
        size: 28,
        color: allClear
          ? DashTheme.success
          : (snapshot?.signals.contains { $0.status == .critical } == true
            ? DashTheme.danger : DashTheme.warning)
      )
      VStack(alignment: .leading, spacing: 2) {
        Text(
          allClear
            ? "All systems normal"
            : "\(issues) issue\(issues == 1 ? "" : "s") need\(issues == 1 ? "s" : "") attention"
        )
        .dashTextStyle(.sectionTitle)
        .foregroundStyle(DashTheme.text)
        .lineLimit(
          dynamicTypeSize.isAccessibilitySize ? 2 : 1,
          reservesSpace: dynamicTypeSize.isAccessibilitySize
        )
        Text(
          "\(snapshot?.signals.count ?? 0) check\((snapshot?.signals.count ?? 0) == 1 ? "" : "s") · \(model.activeAccount?.name ?? "account")"
        )
        .dashTextStyle(.caption)
        .foregroundStyle(DashTheme.subtle)
        .lineLimit(
          dynamicTypeSize.isAccessibilitySize ? 2 : 1,
          reservesSpace: dynamicTypeSize.isAccessibilitySize
        )
      }
      Spacer(minLength: 0)
      SolarIcon(asset: SolarAsset.chevronRight, size: 16, color: DashTheme.placeholder)
    }
  }
}

/// Soft pulsing bone for Home card skeletons — keeps layout stable while data loads.
private struct HomeSkeletonBone: View {
  var width: CGFloat
  var height: CGFloat
  var cornerRadius: CGFloat = 4
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulsed = false

  var body: some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(DashTheme.fill.opacity(pulsed ? 0.72 : 0.42))
      .frame(width: width, height: height)
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
          pulsed = true
        }
      }
  }
}

struct ShortcutTile: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID

  private var accessLevel: FeatureAccessLevel {
    feature.capability.accessLevel(grantedScopes: model.grantedScopes)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        CatalogFeatureIcon(feature: feature, size: .shortcut)
          .opacity(accessLevel == .locked ? 0.55 : 1)
        Spacer(minLength: 0)
        if accessLevel != .full {
          StatusBadge(text: accessLevel == .readOnly ? "Read-only" : "Locked")
        }
      }
      Text(feature.title)
        .dashTextStyle(.bodySemibold)
        .foregroundStyle(DashTheme.text)
        .lineLimit(2, reservesSpace: true)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(
      DashTheme.recessed,
      in: RoundedRectangle(cornerRadius: DashTheme.Radius.button, style: .continuous)
    )
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(feature.title), \(accessAccessibilityValue)")
    .dashFeatureTransitionSource(
      feature,
      background: DashTheme.recessed,
      cornerRadius: DashTheme.Radius.button
    )
  }

  private var accessAccessibilityValue: String {
    switch accessLevel {
    case .full: "Available"
    case .readOnly: "Read-only"
    case .locked: "Locked"
    }
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
        SolarIcon(asset: SolarAsset.chevronRight, size: 16, color: onCard.opacity(0.6))
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
        // labelStack's greedy frame fills the row and pushes the trailing
        // badge/chevron to the edge; no Spacer needed.
        HStack(spacing: 12) {
          leadingIcon
          catalogLabels
          accessBadge
          SolarIcon(asset: SolarAsset.chevronRight, size: 16, color: DashTheme.placeholder)
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
  @AppStorage("dash.home_shortcuts") private var shortcutData = "zones,workers,r2,kv"

  private var selection: [FeatureID] {
    shortcutData.split(separator: ",")
      .compactMap { FeatureID(rawValue: String($0)) }
      .filter { !DashAuthorizationScopes.experimentalFeatures.contains($0) }
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 12) {
        ForEach(
          FeatureCatalog.all.filter {
            !DashAuthorizationScopes.experimentalFeatures.contains($0)
          }
        ) { feature in
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
