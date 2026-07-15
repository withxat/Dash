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

/// Access and product-visibility filtering. Text search is rendered by the
/// tab-bar Search role (`FeatureCatalog.matchesSearch`), not in the catalog list.
enum FeatureCatalogFiltering {
  static func features(
    filter: FeatureAccessFilter,
    grantedScopes: Set<String>?,
    experimentalEnabled: Bool
  ) -> [FeatureID] {
    FeatureCatalog.all.filter { feature in
      DashAuthorizationScopes.isVisible(
        feature, experimentalEnabled: experimentalEnabled)
        && filter.matches(feature.capability.accessLevel(grantedScopes: grantedScopes))
    }
  }

  static func grouped(
    filter: FeatureAccessFilter,
    grantedScopes: Set<String>?,
    experimentalEnabled: Bool
  ) -> [(String, [FeatureID])] {
    FeatureCatalog.sections(
      for: features(
        filter: filter,
        grantedScopes: grantedScopes,
        experimentalEnabled: experimentalEnabled))
  }
}

struct FeatureCatalogView: View {
  /// What the tab opens on: the features this account can actually use. Scopes
  /// unknown (`grantedScopes == nil`) resolves to `.full`, so a cold launch
  /// still lists everything rather than flashing an empty catalog.
  static let defaultFilter: FeatureAccessFilter = .available

  @Environment(AppModel.self) private var model
  @State private var accessFilter: FeatureAccessFilter = FeatureCatalogView.defaultFilter
  @State private var showsFilter = false
  /// When set (regular-width split), rows select into the detail column instead of pushing.
  var selection: Binding<FeatureID?>?

  init(selection: Binding<FeatureID?>? = nil) {
    self.selection = selection
  }

  private var grouped: [(String, [FeatureID])] {
    FeatureCatalogFiltering.grouped(
      filter: accessFilter,
      grantedScopes: model.grantedScopes,
      experimentalEnabled: model.experimentalFeaturesEnabled)
  }

  var body: some View {
    let sectionOffset = accessFilter == Self.defaultFilter ? 0 : 1

    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        // Only once the filter leaves its default — the default view is the
        // plain catalog and shouldn't carry a permanent banner.
        if accessFilter != Self.defaultFilter {
          HStack(spacing: 8) {
            Text("Showing \(accessFilter.title.lowercased())")
              .dashTextStyle(.footnote)
              .foregroundStyle(DashTheme.subtle)
            Spacer(minLength: 0)
            Button("Clear") {
              accessFilter = Self.defaultFilter
            }
            .dashTextStyle(.footnoteSemibold)
            .foregroundStyle(DashTheme.brand)
            .dashCompactHitTarget()
          }
          .accessibilityElement(children: .combine)
          .dashSectionReveal()
        }

        if grouped.isEmpty {
          DashEmptyState(
            icon: SolarAsset.search,
            title: emptyTitle,
            message: emptyMessage
          )
          .dashSectionReveal(sectionOffset)
        } else {
          ForEach(Array(grouped.enumerated()), id: \.element.0) { index, section in
            let (title, features) = section
            FeatureSection(title: title, items: features, selection: selection)
              .dashSectionReveal(index + sectionOffset)
          }
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .dashSectionEntrance()
    .dashCatalogScreen("Features")
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
        ForEach(FeatureAccessFilter.allCases, id: \.self) { filter in
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
                SolarIcon(asset: SolarAsset.checkCircleFill, size: 22, color: DashTheme.brand)
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
    accessFilter == .all ? "No features" : "Nothing in this filter"
  }

  private var emptyMessage: String {
    accessFilter == .all
      ? "Features for this account will show up here."
      : "Nothing matches \(accessFilter.title.lowercased()) right now."
  }
}
