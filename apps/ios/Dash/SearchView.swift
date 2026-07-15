import CloudflareAPI
import SwiftUI

enum SearchZonesPhase: Equatable {
  case idle
  case loading
  case ready
  case failed(String)
}

struct SearchView: View {
  @Binding var search: String
  @Environment(AppModel.self) private var model
  @State private var zonesPhase: SearchZonesPhase = .idle
  @State private var fetchedZonesForAccount: String?

  private var trimmedSearch: String {
    search.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var searchResults: [FeatureID] {
    guard trimmedSearch.count >= 2 else { return [] }
    return FeatureCatalog.sorted(
      FeatureCatalog.all.filter { FeatureCatalog.matchesSearch($0, query: trimmedSearch) }
    )
  }

  private var cachedZones: [CloudflareZone] {
    guard let accountID = model.activeAccountID else { return [] }
    return model.featureCache.get(FeatureCacheKey.zones(accountID)) ?? []
  }

  private var zoneResults: [CloudflareZone] {
    guard trimmedSearch.count >= 2 else { return [] }
    return Array(
      cachedZones
        .filter { $0.name.localizedCaseInsensitiveContains(trimmedSearch) }
        .prefix(6)
    )
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        listContent
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
      .animation(DashTheme.Motion.quick, value: trimmedSearch)
    }
    .dashCatalogScreen("Search")
    .task(id: "\(model.activeAccountID ?? "")|\(trimmedSearch)") {
      await loadZonesIfNeeded()
    }
  }

  @ViewBuilder
  private var listContent: some View {
    if trimmedSearch.isEmpty {
      DashEmptyState(
        icon: SolarAsset.search,
        title: "Search features",
        message: "Enter a product, service, or zone name — DNS, Workers, example.com, and more."
      )
    } else if trimmedSearch.count < 2 {
      DashEmptyState(
        icon: SolarAsset.search,
        title: "Keep typing",
        message: "Enter at least two characters to search."
      )
    } else {
      zonesSection
      if !searchResults.isEmpty {
        searchResultsList
      }
      if shouldShowNothingFound {
        DashEmptyState(
          icon: SolarAsset.search,
          title: "Nothing found",
          message: "Nothing matches \(trimmedSearch). Try a service, product, or zone name."
        )
      }
    }
  }

  private var shouldShowNothingFound: Bool {
    searchResults.isEmpty
      && zoneResults.isEmpty
      && zonesPhase == .ready
  }

  @ViewBuilder
  private var zonesSection: some View {
    switch zonesPhase {
    case .idle:
      EmptyView()
    case .loading:
      DashListGroup(title: "Zones") {
        HStack(spacing: 12) {
          DashLoadingRing(color: DashTheme.brand)
          Text("Loading zones…")
            .dashTextStyle(.supporting)
            .foregroundStyle(DashTheme.subtle)
          Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
      }
    case .failed(let message):
      DashListGroup(title: "Zones") {
        let presentation = DashFailurePresentation.from(message: message)
        VStack(alignment: .leading, spacing: 10) {
          DashNotice(kind: .error, message: presentation.message)
          DashSecondaryPillButton(title: presentation.action.title) {
            switch presentation.action {
            case .signInAgain:
              Task { await model.signOut() }
            case .grantAccess:
              model.requestAccess(to: Set(CloudflareScopes.published))
            case .tryAgain:
              Task { await loadZonesIfNeeded(force: true) }
            }
          }
        }
        .padding(.vertical, 8)
      }
    case .ready:
      if zoneResults.isEmpty {
        DashListGroup(title: "Zones") {
          Text("No matching zones")
            .dashTextStyle(.supporting)
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
        }
      } else {
        zoneResultsList
      }
    }
  }

  private var zoneResultsList: some View {
    DashListGroup(title: "Zones") {
      ForEach(Array(zoneResults.enumerated()), id: \.element.id) { index, zone in
        DashListGroupLink(value: .zone(zone.id)) {
          DashListRow(
            title: zone.name,
            subtitle: zone.status ?? "unknown",
            icon: SolarAsset.globe
          )
        }
        if index < zoneResults.count - 1 {
          DashListGroupDivider()
        }
      }
    }
  }

  private var searchResultsList: some View {
    DashListGroup(title: "Features") {
      ForEach(Array(searchResults.enumerated()), id: \.element) { index, item in
        DashListGroupLink(
          value: .feature(item), onNavigate: { RecentFeatures.record(item) }
        ) {
          FeatureRow(feature: item)
        }
        if index < searchResults.count - 1 {
          DashListGroupDivider()
        }
      }
    }
  }

  private func loadZonesIfNeeded(force: Bool = false) async {
    guard trimmedSearch.count >= 2, let accountID = model.activeAccountID else {
      zonesPhase = .idle
      return
    }
    let key = FeatureCacheKey.zones(accountID)
    if !force, let cached: [CloudflareZone] = model.featureCache.get(key) {
      fetchedZonesForAccount = accountID
      zonesPhase = .ready
      return
    }
    if !force, fetchedZonesForAccount == accountID, zonesPhase == .ready || zonesPhase == .loading {
      return
    }

    zonesPhase = .loading
    fetchedZonesForAccount = accountID
    do {
      let page = try await model.client.listZones(accountID: accountID)
      model.featureCache.set(key, page.items)
      zonesPhase = .ready
    } catch {
      fetchedZonesForAccount = nil
      zonesPhase = .failed(error.dashActionableMessage)
    }
  }
}
