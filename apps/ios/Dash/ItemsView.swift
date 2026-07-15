import SwiftUI

enum ItemsAccessFilter: String, CaseIterable, Hashable {
  case all
  case available
  case readOnly
  case locked

  var title: String {
    switch self {
    case .all: "All"
    case .available: "Available"
    case .readOnly: "Read-only"
    case .locked: "Locked"
    }
  }

  func matches(_ level: FeatureAccessLevel) -> Bool {
    switch self {
    case .all: true
    case .available: level == .full
    case .readOnly: level == .readOnly
    case .locked: level == .locked
    }
  }
}

enum ItemsCatalogFiltering {
  static func features(
    query: String,
    filter: ItemsAccessFilter,
    grantedScopes: Set<String>?
  ) -> [FeatureID] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return FeatureCatalog.all.filter { feature in
      let level = feature.capability.accessLevel(grantedScopes: grantedScopes)
      guard filter.matches(level) else { return false }
      guard !trimmed.isEmpty else { return true }
      return FeatureCatalog.matchesSearch(feature, query: trimmed)
    }
  }

  static func grouped(
    query: String,
    filter: ItemsAccessFilter,
    grantedScopes: Set<String>?
  ) -> [(String, [FeatureID])] {
    FeatureCatalog.sections(
      for: features(query: query, filter: filter, grantedScopes: grantedScopes))
  }
}

struct ItemsView: View {
  @Environment(AppModel.self) private var model
  @State private var query = ""
  @State private var accessFilter: ItemsAccessFilter = .all
  @State private var showsFilter = false
  /// When set (regular-width split), rows select into the detail column instead of pushing.
  var selection: Binding<FeatureID?>?

  init(selection: Binding<FeatureID?>? = nil) {
    self.selection = selection
  }

  private var grouped: [(String, [FeatureID])] {
    ItemsCatalogFiltering.grouped(
      query: query, filter: accessFilter, grantedScopes: model.grantedScopes)
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        DashInlineSearch(prompt: "Search features", text: $query)

        if accessFilter != .all {
          HStack(spacing: 8) {
            Text("Showing \(accessFilter.title.lowercased())")
              .dashTextStyle(.footnote)
              .foregroundStyle(DashTheme.subtle)
            Spacer(minLength: 0)
            Button("Clear") {
              accessFilter = .all
            }
            .dashTextStyle(.footnoteSemibold)
            .foregroundStyle(DashTheme.brand)
            .dashCompactHitTarget()
          }
          .accessibilityElement(children: .combine)
        }

        if grouped.isEmpty {
          DashEmptyState(
            icon: SolarAsset.search,
            title: emptyTitle,
            message: emptyMessage
          )
        } else {
          ForEach(grouped, id: \.0) { title, features in
            FeatureSection(title: title, items: features, selection: selection)
          }
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .dashCatalogScreen("Items")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        DashToolbarIconButton(
          asset: SolarAsset.slider,
          accessibilityLabel: "Filter by access"
        ) {
          showsFilter = true
        }
      }
      .dashSeparateToolbarBackground()
    }
    .dashTray(isPresented: $showsFilter, title: "Filter") {
      VStack(spacing: 10) {
        ForEach(ItemsAccessFilter.allCases, id: \.self) { filter in
          Button {
            accessFilter = filter
            showsFilter = false
          } label: {
            HStack(spacing: 12) {
              Text(filter.title)
                .dashTextStyle(.bodyMedium)
                .foregroundStyle(DashTheme.text)
              Spacer(minLength: 0)
              if accessFilter == filter {
                SolarIcon(asset: SolarAsset.checkCircle, size: 22, color: DashTheme.brand)
              }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DashTheme.Sheet.shortcutItem, in: DashTheme.buttonShape)
          }
          .buttonStyle(DashPressButtonStyle())
          .accessibilityAddTraits(accessFilter == filter ? .isSelected : [])
        }
      }
      .padding(.horizontal, DashTheme.Sheet.content)
    }
  }

  private var emptyTitle: String {
    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Nothing found"
    }
    return accessFilter == .all ? "No features" : "Nothing in this filter"
  }

  private var emptyMessage: String {
    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Try another search, or clear the access filter."
    }
    return accessFilter == .all
      ? "Features for this account will show up here."
      : "Nothing matches \(accessFilter.title.lowercased()) right now."
  }
}
