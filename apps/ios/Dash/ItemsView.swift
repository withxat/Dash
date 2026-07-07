import SwiftUI

struct ItemsView: View {
  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        ForEach(FeatureCatalog.grouped, id: \.0) { title, features in
          FeatureSection(title: title, items: features)
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.bottom, 100)
    }
    .dashCatalogScreen("Items")
  }
}
