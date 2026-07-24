import SwiftUI

enum FeatureAccessFilter: String, CaseIterable, Hashable {
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

/// Access filtering for the Resources catalog.
enum FeatureCatalogFiltering {
  static func features(
    filter: FeatureAccessFilter,
    grantedScopes: Set<String>?
  ) -> [FeatureID] {
    FeatureCatalog.all.filter { feature in
      filter.matches(feature.capability.accessLevel(grantedScopes: grantedScopes))
    }
  }
}

struct FeatureCatalogView: View {
  /// The catalog lists what this account can actually use, and nothing else —
  /// a row that opens a permission wall is a broken promise. Scopes unknown
  /// (`grantedScopes == nil`) resolves to `.full`, so a cold launch lists
  /// everything rather than flashing an empty catalog.
  ///
  /// Not user-adjustable: with four features and no locked ones, a filter tray
  /// would be a control with nothing to control.
  static let defaultFilter: FeatureAccessFilter = .available

  @Environment(AppModel.self) private var model

  private var visibleFeatures: [FeatureID] {
    FeatureCatalogFiltering.features(
      filter: Self.defaultFilter,
      grantedScopes: model.grantedScopes)
  }

  private var grouped: [(String, [FeatureID])] {
    FeatureCatalog.sections(for: visibleFeatures)
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        if visibleFeatures.isEmpty {
          DashEmptyState(
            icon: SolarAsset.Content.search,
            title: "No resources",
            message: "Resources for this account will show up here."
          )
          .dashSectionReveal()
        } else {
          ForEach(Array(grouped.enumerated()), id: \.element.0) { index, section in
            let (title, features) = section
            catalogSection(title: title, features: features)
              .dashSectionReveal(index)
          }
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, DashTheme.Spacing.section)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .modifier(DashScrollEdgeEffectsHidden())
    .dashSectionEntrance()
    .dashCatalogScreen()
  }

  @ViewBuilder
  private func catalogSection(title: String, features: [FeatureID]) -> some View {
    DashListGroup(title: title) {
      ForEach(features, id: \.self) { feature in
        DashListGroupLink(value: .feature(feature)) {
          FeatureRow(feature: feature)
        }
      }
    }
  }
}
