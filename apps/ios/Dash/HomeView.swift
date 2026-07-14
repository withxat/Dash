import SwiftUI

struct HomeView: View {
  @AppStorage("dash.home_shortcuts") private var shortcutData = "zones,workers,r2,kv"
  @AppStorage("dash.recent_items") private var recentData = ""
  @Environment(\.showsEditShortcuts) private var showsEditShortcuts
  @Environment(AppModel.self) private var model

  private var shortcuts: [FeatureID] {
    shortcutData.split(separator: ",").compactMap { FeatureID(rawValue: String($0)) }
  }
  private var recent: [FeatureID] {
    recentData.split(separator: ",").compactMap { FeatureID(rawValue: String($0)) }
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        if model.identityStale {
          DashNotice(
            kind: .warning,
            message: "Offline — showing cached data. Reconnect to refresh your account.")
        }
        FeatureSection(
          title: "Shortcuts", items: shortcuts, actionTitle: "Edit", actionIcon: SolarAsset.pen
        ) {
          showsEditShortcuts.wrappedValue = true
        }
        FeatureSection(
          title: "Frequently used",
          items: Array((recent + shortcuts).uniqued().prefix(4))
        )
        if !recent.isEmpty {
          FeatureSection(title: "Recently opened", items: recent)
        }
        Text("Open Items to browse every feature by category.")
          .font(.system(size: 11))
          .foregroundStyle(DashTheme.placeholder)
          .frame(maxWidth: .infinity)
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.bottom, 100)
    }
    .dashCatalogScreen("Home")
  }
}

struct FeatureSection: View {
  let title: String
  let items: [FeatureID]
  var iconStyle: CatalogFeatureIcon.Style = .duotone
  var actionTitle: String?
  var actionIcon: String?
  var action: (() -> Void)?

  init(
    title: String,
    items: [FeatureID],
    iconStyle: CatalogFeatureIcon.Style = .duotone,
    actionTitle: String? = nil,
    actionIcon: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.title = title
    self.items = items
    self.iconStyle = iconStyle
    self.actionTitle = actionTitle
    self.actionIcon = actionIcon
    self.action = action
  }

  var body: some View {
    DashListGroup(title: title, actionTitle: actionTitle, actionIcon: actionIcon, action: action) {
      ForEach(Array(items.enumerated()), id: \.element) { index, item in
        DashListGroupLink(
          value: .feature(item), onNavigate: { record(item) }
        ) {
          FeatureRow(feature: item, iconStyle: iconStyle)
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
  let feature: FeatureID
  var iconStyle: CatalogFeatureIcon.Style = .duotone

  var body: some View {
    HStack(spacing: 12) {
      CatalogFeatureIcon(feature: feature, style: iconStyle)
      VStack(alignment: .leading, spacing: 2) {
        Text(feature.title)
          .font(.body)
          .foregroundStyle(DashTheme.text)
          .lineLimit(1)
        Text(feature.subtitle)
          .font(.caption)
          .foregroundStyle(DashTheme.subtle)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      SolarIcon(asset: SolarAsset.chevronRight, size: 16, color: DashTheme.placeholder)
    }
    .padding(.vertical, 12)
    .contentShape(Rectangle())
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

extension Sequence where Element: Hashable {
  fileprivate func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}
