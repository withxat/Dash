import SwiftUI

struct HomeView: View {
  @AppStorage("dash.home_shortcuts") private var shortcutData = "zones,workers,r2,kv"
  @AppStorage("dash.recent_items") private var recentData = ""
  @Environment(\.showsEditShortcuts) private var showsEditShortcuts

  private var shortcuts: [FeatureID] {
    shortcutData.split(separator: ",").compactMap { FeatureID(rawValue: String($0)) }
  }
  private var recent: [FeatureID] {
    recentData.split(separator: ",").compactMap { FeatureID(rawValue: String($0)) }
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        DashRootHeader(title: "Home")
        FeatureSection(
          title: "Shortcuts", items: shortcuts, heroOrigin: .shortcuts, actionTitle: "Edit"
        ) {
          showsEditShortcuts.wrappedValue = true
        }
        FeatureSection(
          title: "Frequently used",
          items: Array((recent + shortcuts).uniqued().prefix(4)),
          heroOrigin: .frequent
        )
        if !recent.isEmpty {
          FeatureSection(title: "Recently opened", items: recent, heroOrigin: .recent)
        }
        Text("Open Items to browse every feature by category.")
          .font(.system(size: 11))
          .foregroundStyle(DashTheme.placeholder)
          .frame(maxWidth: .infinity)
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, 12)
      .padding(.bottom, 100)
    }
    .background(DashTheme.canvas)
    .toolbar(.hidden, for: .navigationBar)
    .dashOverlayTray(isPresented: showsEditShortcuts, title: "Edit shortcuts") {
      EditShortcutsView()
    }
  }
}

struct FeatureSection: View {
  let title: String
  let items: [FeatureID]
  let heroOrigin: FeatureHeroOrigin
  var iconStyle: CatalogFeatureIcon.Style = .duotone
  var actionTitle: String?
  var action: (() -> Void)?

  init(
    title: String,
    items: [FeatureID],
    heroOrigin: FeatureHeroOrigin,
    iconStyle: CatalogFeatureIcon.Style = .duotone,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.title = title
    self.items = items
    self.heroOrigin = heroOrigin
    self.iconStyle = iconStyle
    self.actionTitle = actionTitle
    self.action = action
  }

  var body: some View {
    DashListGroup(title: title, actionTitle: actionTitle, action: action) {
      ForEach(Array(items.enumerated()), id: \.element) { index, item in
        DashListGroupLink(
          value: .feature(item), heroOrigin: heroOrigin, onNavigate: { record(item) }
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
    let key = "dash.recent_items"
    let existing = (UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").map(
      String.init)
    UserDefaults.standard.set(
      ([item.rawValue] + existing.filter { $0 != item.rawValue }).prefix(6).joined(separator: ","),
      forKey: key)
  }
}

struct FeatureRow: View {
  let feature: FeatureID
  var iconStyle: CatalogFeatureIcon.Style = .duotone

  var body: some View {
    HStack(spacing: 12) {
      CatalogFeatureIcon(feature: feature, style: iconStyle)
        .featureHeroSource(feature, part: .icon)
      VStack(alignment: .leading, spacing: 2) {
        Text(feature.title)
          .font(.body)
          .foregroundStyle(DashTheme.text)
          .lineLimit(1)
          .featureHeroSource(feature, part: .title)
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
        ForEach(FeatureID.allCases) { feature in
          HStack(spacing: 12) {
            DashListGroupLink(value: .feature(feature), heroOrigin: .editShortcuts) {
              HStack(spacing: 12) {
                CatalogFeatureIcon(feature: feature, size: .shortcut)
                  .featureHeroSource(feature, part: .icon)
                Text(feature.title)
                  .font(.system(size: 18, weight: .semibold))
                  .foregroundStyle(DashTheme.strong)
                  .lineLimit(1)
                  .featureHeroSource(feature, part: .title)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
              toggle(feature)
            } label: {
              Image(selection.contains(feature) ? SolarAsset.checkCircle : SolarAsset.circle)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(
                  selection.contains(feature) ? DashTheme.brand : DashTheme.placeholder)
            }
            .buttonStyle(DashPressButtonStyle())
            .accessibilityLabel(
              selection.contains(feature) ? "Remove from shortcuts" : "Add to shortcuts")
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(DashTheme.Sheet.shortcutItem)
          .clipShape(DashTheme.buttonShape)
        }
      }
      .padding(.horizontal, DashTheme.Sheet.content)
      .padding(.bottom, DashTheme.Sheet.bodyBottom)
    }
  }

  private func toggle(_ feature: FeatureID) {
    var items = selection
    if let index = items.firstIndex(of: feature) {
      items.remove(at: index)
    } else {
      items.append(feature)
    }
    shortcutData = items.map(\.rawValue).joined(separator: ",")
  }
}

extension Sequence where Element: Hashable {
  fileprivate func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}
