import SwiftUI

struct SearchView: View {
  @State private var search = ""

  private var trimmedSearch: String {
    search.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var searchResults: [FeatureID] {
    guard trimmedSearch.count >= 2 else { return [] }
    return FeatureCatalog.sorted(
      FeatureID.allCases.filter { FeatureCatalog.matchesSearch($0, query: trimmedSearch) }
    )
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        listContent
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.bottom, 100)
      .animation(DashTheme.Motion.quick, value: trimmedSearch)
    }
    .dashCatalogScreen("Search")
    // Plain .searchable only: inside the search-role tab, iOS 26 morphs the
    // detached tab-bar button into a bottom search field. No isPresented
    // binding and no toolbar placement overrides — both break on device.
    .searchable(text: $search, prompt: "Features, zones…")
  }

  @ViewBuilder
  private var listContent: some View {
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
