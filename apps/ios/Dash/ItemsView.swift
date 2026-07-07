import SwiftUI

struct ItemsView: View {
  @State private var search = ""

  var body: some View {
    ScrollView {
      ItemsListContent(search: search)
        .padding(.horizontal, DashTheme.Spacing.screen)
        .padding(.bottom, 100)
    }
    .dashCatalogScreen("Items")
    .dashCatalogNativeSearch(
      text: $search,
      prompt: "Features, zones…"
    )
  }
}

// `\.isSearching` only resolves below the `.searchable` view, so the
// search-dependent content lives in this child rather than in ItemsView.
private struct ItemsListContent: View {
  let search: String
  @Environment(\.isSearching) private var isSearching

  private var trimmedSearch: String {
    search.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var showsSearchResults: Bool {
    isSearching || !trimmedSearch.isEmpty
  }

  private var searchResults: [FeatureID] {
    guard trimmedSearch.count >= 2 else { return [] }
    return FeatureCatalog.sorted(
      FeatureID.allCases.filter { FeatureCatalog.matchesSearch($0, query: trimmedSearch) }
    )
  }

  var body: some View {
    LazyVStack(spacing: DashTheme.Spacing.section) {
      listContent
    }
    .animation(.easeOut(duration: 0.2), value: showsSearchResults)
    .animation(.easeOut(duration: 0.2), value: trimmedSearch)
  }

  @ViewBuilder
  private var listContent: some View {
    if showsSearchResults {
      if trimmedSearch.isEmpty {
        DashEmptyState(
          icon: SolarAsset.search,
          title: "Search features",
          message: "Enter a product or service name — DNS, Workers, R2, and more."
        )
      } else if trimmedSearch.count < 2 {
        DashEmptyState(
          icon: SolarAsset.search,
          title: "Keep typing",
          message: "Enter at least two characters to search."
        )
      } else if searchResults.isEmpty {
        DashEmptyState(
          icon: SolarAsset.search,
          title: "Nothing found",
          message: "No feature matches \(trimmedSearch). Try a service or product name."
        )
      } else {
        searchResultsList
      }
    } else {
      ForEach(FeatureCatalog.grouped, id: \.0) { title, features in
        FeatureSection(title: title, items: features)
      }
    }
  }

  private var searchResultsList: some View {
    DashListGroup(title: "Results") {
      ForEach(Array(searchResults.enumerated()), id: \.element) { index, item in
        DashListGroupLink(
          value: .feature(item), onNavigate: { record(item) }
        ) {
          FeatureRow(feature: item)
        }
        if index < searchResults.count - 1 {
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
