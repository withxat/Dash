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
    case .locked: "Needs authorization"
    }
  }

  func matches(_ level: FeatureAccessLevel) -> Bool {
    switch self {
    case .all: true
    case .available: level != .locked
    case .readOnly: level == .readOnly
    case .locked: level == .locked
    }
  }
}

/// Access filtering for the Resources catalog.
enum FeatureCatalogFiltering {
  static func features(
    filter: FeatureAccessFilter,
    grantedScopes: Set<String>?,
    enabled: Set<FeatureID> = Set(FeatureID.allCases)
  ) -> [FeatureID] {
    // Unknown grant fails closed — AppRoot does not mount the catalog until
    // bootstrap restores the scope mirror or its conservative fallback.
    guard grantedScopes != nil else { return [] }
    return FeatureCatalog.all.filter { feature in
      enabled.contains(feature)
        && filter.matches(feature.capability.accessLevel(grantedScopes: grantedScopes))
    }
  }

  static func enabledFeatures(
    tunnelsExperimentalEnabled: Bool
  ) -> Set<FeatureID> {
    Set(
      FeatureID.allCases.filter {
        DashExperimentalFeatures.isCatalogVisible(
          $0,
          tunnelsEnabled: tunnelsExperimentalEnabled)
      })
  }
}

struct FeatureCatalogView: View {
  /// Lists every enabled catalog feature, including locked experimental ones
  /// so Resources can show the Needs authorization badge and route into Grant
  /// access. Core features stay granted by sign-in; experimental ones opt in
  /// via Settings and authorize on demand.
  static let defaultFilter: FeatureAccessFilter = .all

  @Environment(AppModel.self) private var model
  @AppStorage(DashExperimentalFeatures.tunnelsKey) private var tunnelsExperimentalEnabled =
    false

  private var visibleFeatures: [FeatureID] {
    FeatureCatalogFiltering.features(
      filter: Self.defaultFilter,
      grantedScopes: model.grantedScopes,
      enabled: FeatureCatalogFiltering.enabledFeatures(
        tunnelsExperimentalEnabled: tunnelsExperimentalEnabled))
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
        .accessibilityIdentifier("feature-\(feature.rawValue)")
      }
    }
  }
}
