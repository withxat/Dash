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

  private var grouped: [(String, [FeatureID])] {
    ItemsCatalogFiltering.grouped(
      query: query, filter: accessFilter, grantedScopes: model.grantedScopes)
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        DashInlineSearch(prompt: "Search features", text: $query)
        DashTextTabs(
          items: ItemsAccessFilter.allCases.map { ($0.title, $0) },
          selection: $accessFilter
        )

        if grouped.isEmpty {
          DashEmptyState(
            icon: SolarAsset.search,
            title: emptyTitle,
            message: emptyMessage
          )
        } else {
          ForEach(grouped, id: \.0) { title, features in
            FeatureSection(title: title, items: features)
          }
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .dashCatalogScreen("Items")
  }

  private var emptyTitle: String {
    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Nothing found"
    }
    return accessFilter == .all ? "No features" : "Nothing in this filter"
  }

  private var emptyMessage: String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      return "Nothing matches \(trimmed)."
    }
    switch accessFilter {
    case .all: return "The feature catalog is empty."
    case .available: return "No fully available features for the current scopes."
    case .readOnly: return "No read-only features for the current scopes."
    case .locked: return "No locked features for the current scopes."
    }
  }
}
