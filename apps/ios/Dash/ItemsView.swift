import SwiftUI

struct ItemsView: View {
  @State private var search = ""
  private var filtered: [(String, [FeatureID])] {
    guard !search.isEmpty else { return FeatureCatalog.grouped }
    let needle = search.localizedLowercase
    let matches = FeatureID.allCases.filter {
      $0.title.localizedLowercase.contains(needle)
        || $0.subtitle.localizedLowercase.contains(needle)
    }
    return matches.isEmpty ? [] : [("Features", matches)]
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: 22) {
        ForEach(filtered, id: \.0) { title, features in
          FeatureSection(title: title, items: features)
        }
        if filtered.isEmpty { ContentUnavailableView.search(text: search) }
      }.padding(.horizontal, 16).padding(.bottom, 100)
    }
    .background(DashTheme.canvas)
    .navigationTitle("Items").navigationBarTitleDisplayMode(.large)
    .searchable(
      text: $search, placement: .navigationBarDrawer(displayMode: .always),
      prompt: "Features, zones…"
    )
    .toolbar { AccountToolbar() }
    .destinationRouting()
  }
}
