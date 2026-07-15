import SwiftUI

struct HomeView: View {
  @AppStorage("dash.home_shortcuts") private var shortcutData = "zones,workers,r2,kv"
  @AppStorage("dash.recent_items") private var recentData = ""
  @AppStorage(PinnedZones.key) private var pinnedZoneData = ""
  @Environment(\.showsEditShortcuts) private var showsEditShortcuts
  @Environment(AppModel.self) private var model

  private var shortcuts: [FeatureID] {
    shortcutData.split(separator: ",").compactMap { FeatureID(rawValue: String($0)) }
  }
  private var recent: [FeatureID] {
    recentData.split(separator: ",").compactMap { FeatureID(rawValue: String($0)) }
  }
  private var pinnedZones: [PinnedZone] {
    PinnedZones.decode(pinnedZoneData).filter { $0.accountID == model.activeAccountID }
  }
  private var continueItems: [FeatureID] {
    RecentFeatures.continueItems(recent: recent, shortcuts: shortcuts)
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        if model.identityStale {
          DashNotice(
            kind: .warning,
            message: "Offline — showing cached data. Reconnect to refresh your account.")
        }
        HomeWatchtowerSummaryCard()
        FeatureSection(
          title: "Shortcuts", items: shortcuts, actionTitle: "Edit", actionIcon: SolarAsset.pen
        ) {
          showsEditShortcuts.wrappedValue = true
        }
        if !pinnedZones.isEmpty {
          DashListGroup(title: "Pinned zones") {
            ForEach(Array(pinnedZones.enumerated()), id: \.element) { index, pin in
              DashListGroupLink(value: .zone(pin.zoneID)) {
                DashListRow(title: pin.name, icon: SolarAsset.pin)
              }
              if index < pinnedZones.count - 1 {
                DashListGroupDivider()
              }
            }
          }
        }
        if !continueItems.isEmpty {
          FeatureSection(title: "Continue", items: continueItems)
        }
        Text("Open Items to browse every feature by category.")
          .dashTextStyle(.micro)
          .foregroundStyle(DashTheme.placeholder)
          .frame(maxWidth: .infinity)
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .dashCatalogScreen("Home")
  }
}

private struct HomeWatchtowerSummaryCard: View {
  @Environment(AppModel.self) private var model

  private var snapshot: WatchtowerSnapshot? {
    guard let accountID = model.activeAccountID else { return nil }
    return model.featureCache.get(FeatureCacheKey.watchtower(accountID))
  }

  private var issueCount: Int? { model.watchtowerIssueCount }

  var body: some View {
    Button {
      model.pendingRoute = .watchtower
    } label: {
      DashCard {
        if model.activeAccountID == nil {
          Text("No Cloudflare account is available for this user.")
            .dashTextStyle(.supporting)
            .foregroundStyle(DashTheme.subtle)
        } else if issueCount == nil {
          HStack(spacing: 12) {
            DashLoadingRing(color: DashTheme.brand)
            Text("Checking account health…")
              .dashTextStyle(.footnote)
              .foregroundStyle(DashTheme.subtle)
            Spacer(minLength: 0)
          }
        } else {
          let issues = issueCount ?? 0
          let allClear = issues == 0
          HStack(alignment: .center, spacing: 12) {
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
              .fixedSize(horizontal: false, vertical: true)
              Text(
                "\(snapshot?.signals.count ?? 0) check\((snapshot?.signals.count ?? 0) == 1 ? "" : "s") · \(model.activeAccount?.name ?? "account")"
              )
              .dashTextStyle(.caption)
              .foregroundStyle(DashTheme.subtle)
              .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            SolarIcon(asset: SolarAsset.chevronRight, size: 16, color: DashTheme.placeholder)
          }
        }
      }
    }
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel("Open Watchtower")
  }
}

struct FeatureSection: View {
  let title: String
  let items: [FeatureID]
  var iconStyle: CatalogFeatureIcon.Style = .duotone
  var actionTitle: String?
  var actionIcon: String?
  var action: (() -> Void)?
  /// Regular-width Items sidebar selection; nil keeps NavigationLink push behavior.
  var selection: Binding<FeatureID?>?

  init(
    title: String,
    items: [FeatureID],
    iconStyle: CatalogFeatureIcon.Style = .duotone,
    actionTitle: String? = nil,
    actionIcon: String? = nil,
    action: (() -> Void)? = nil,
    selection: Binding<FeatureID?>? = nil
  ) {
    self.title = title
    self.items = items
    self.iconStyle = iconStyle
    self.actionTitle = actionTitle
    self.actionIcon = actionIcon
    self.action = action
    self.selection = selection
  }

  var body: some View {
    DashListGroup(title: title, actionTitle: actionTitle, actionIcon: actionIcon, action: action) {
      ForEach(Array(items.enumerated()), id: \.element) { index, item in
        if let selection {
          Button {
            selection.wrappedValue = item
            record(item)
          } label: {
            FeatureRow(feature: item, iconStyle: iconStyle)
              .padding(.horizontal, 4)
              .background(
                selection.wrappedValue == item
                  ? DashTheme.brand.opacity(0.08)
                  : Color.clear,
                in: RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous)
              )
          }
          .buttonStyle(DashPressButtonStyle())
          .accessibilityAddTraits(selection.wrappedValue == item ? .isSelected : [])
        } else {
          DashListGroupLink(
            value: .feature(item), onNavigate: { record(item) }
          ) {
            FeatureRow(feature: item, iconStyle: iconStyle)
          }
        }
        if index < items.count - 1 {
          DashListGroupDivider()
        }
      }
    }
  }

  private func record(_ item: FeatureID) {
    RecentFeatures.record(item)
  }
}

struct FeatureRow: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let feature: FeatureID
  var iconStyle: CatalogFeatureIcon.Style = .duotone

  private var accessLevel: FeatureAccessLevel {
    feature.capability.accessLevel(grantedScopes: model.grantedScopes)
  }

  private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

  var body: some View {
    Group {
      if isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 12) {
            CatalogFeatureIcon(
              feature: feature, style: iconStyle, enablesNavigationTransition: true
            )
            .opacity(accessLevel == .locked ? 0.55 : 1)
            labels
          }
          HStack {
            accessBadge
            Spacer(minLength: 0)
            SolarIcon(asset: SolarAsset.chevronRight, size: 16, color: DashTheme.placeholder)
          }
        }
      } else {
        HStack(spacing: 12) {
          CatalogFeatureIcon(feature: feature, style: iconStyle, enablesNavigationTransition: true)
            .opacity(accessLevel == .locked ? 0.55 : 1)
          labels
          Spacer(minLength: 8)
          accessBadge
          SolarIcon(asset: SolarAsset.chevronRight, size: 16, color: DashTheme.placeholder)
        }
      }
    }
    .padding(.vertical, 12)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  private var labels: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(feature.title)
        .dashTextStyle(.bodyMedium)
        .foregroundStyle(DashTheme.text)
        .lineLimit(isAccessibilitySize ? nil : 1)
      Text(feature.subtitle)
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
        .lineLimit(isAccessibilitySize ? nil : 1)
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
    shortcutData.split(separator: ",").compactMap { FeatureID(rawValue: String($0)) }
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

        Image(SolarAsset.checkCircle)
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
    .accessibilityLabel(isSelected ? "Remove from shortcuts" : "Add to shortcuts")
  }
}
