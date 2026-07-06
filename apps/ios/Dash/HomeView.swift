import SwiftUI

struct HomeView: View {
  @AppStorage("dash.home_shortcuts") private var shortcutData = "zones,workers,r2,kv"
  @AppStorage("dash.recent_items") private var recentData = ""
  @State private var editShortcuts = false

  private var shortcuts: [FeatureID] {
    shortcutData.split(separator: ",").compactMap { FeatureID(rawValue: String($0)) }
  }
  private var recent: [FeatureID] {
    recentData.split(separator: ",").compactMap { FeatureID(rawValue: String($0)) }
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        FeatureSection(title: "Shortcuts", items: shortcuts, actionTitle: "Edit") {
          editShortcuts = true
        }
        FeatureSection(
          title: "Frequently used", items: Array((recent + shortcuts).uniqued().prefix(4)))
        if !recent.isEmpty { FeatureSection(title: "Recently opened", items: recent) }
        Text("Open Items to browse every feature by category.")
          .font(.system(size: 11))
          .foregroundStyle(DashTheme.placeholder)
          .frame(maxWidth: .infinity)
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, DashTheme.Spacing.screen)
      .padding(.bottom, 100)
    }
    .background(DashTheme.canvas)
    .navigationTitle("Home").navigationBarTitleDisplayMode(.large)
    .toolbar { AccountToolbar() }
    .sheet(isPresented: $editShortcuts) {
      EditShortcutsView(
        selection: Binding(
          get: { shortcuts }, set: { shortcutData = $0.map(\.rawValue).joined(separator: ",") }))
    }
    .destinationRouting()
  }
}

struct FeatureSection: View {
  let title: String
  let items: [FeatureID]
  var actionTitle: String?
  var action: (() -> Void)?

  init(title: String, items: [FeatureID], actionTitle: String? = nil, action: (() -> Void)? = nil) {
    self.title = title
    self.items = items
    self.actionTitle = actionTitle
    self.action = action
  }

  var body: some View {
    DashListGroup(title: title, actionTitle: actionTitle, action: action) {
      ForEach(Array(items.enumerated()), id: \.element) { index, item in
        NavigationLink(value: Destination.feature(item)) { FeatureRow(feature: item) }
          .buttonStyle(DashOpacityButtonStyle())
          .simultaneousGesture(TapGesture().onEnded { record(item) })
        if index < items.count - 1 { Divider().overlay(DashTheme.hairline) }
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
  var body: some View {
    HStack(spacing: 12) {
      CatalogFeatureIcon(feature: feature)
      VStack(alignment: .leading, spacing: 2) {
        Text(feature.title)
          .font(.system(size: 14))
          .foregroundStyle(DashTheme.text)
          .lineLimit(1)
        Text(feature.subtitle)
          .font(.system(size: 12))
          .foregroundStyle(DashTheme.subtle)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Image(systemName: "chevron.right")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(DashTheme.placeholder)
    }
    .padding(.vertical, 10)
    .contentShape(Rectangle())
  }
}

private struct EditShortcutsView: View {
  @Binding var selection: [FeatureID]
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List(FeatureID.allCases) { feature in
        Button {
          if let index = selection.firstIndex(of: feature) {
            selection.remove(at: index)
          } else {
            selection.append(feature)
          }
        } label: {
          HStack {
            FeatureRow(feature: feature)
            Spacer()
            Image(systemName: selection.contains(feature) ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(DashTheme.brand)
          }
        }.foregroundStyle(.primary)
      }
      .dashGroupedList()
      .navigationTitle("Edit shortcuts").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
  }
}

extension Sequence where Element: Hashable {
  fileprivate func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}
