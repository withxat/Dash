import CloudflareAPI
import SwiftUI

struct SearchView: View {
  @Binding var search: String
  @Environment(AppModel.self) private var model
  // One lazy zones fetch per account and session; afterwards results come
  // from the shared cache that ZonesView also reads and warms.
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
      .padding(.bottom, 100)
      .animation(DashTheme.Motion.quick, value: trimmedSearch)
    }
    .dashCatalogScreen("Search")
    .task(id: trimmedSearch) { await loadZonesIfNeeded() }
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
    } else if searchResults.isEmpty, zoneResults.isEmpty {
      DashEmptyState(
        icon: SolarAsset.search,
        title: "Nothing found",
        message: "Nothing matches \(trimmedSearch). Try a service, product, or zone name."
      )
    } else {
      if !zoneResults.isEmpty {
        zoneResultsList
      }
      if !searchResults.isEmpty {
        searchResultsList
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

  private func loadZonesIfNeeded() async {
    guard trimmedSearch.count >= 2, let accountID = model.activeAccountID,
      fetchedZonesForAccount != accountID
    else { return }
    fetchedZonesForAccount = accountID
    let key = FeatureCacheKey.zones(accountID)
    let cached: [CloudflareZone]? = model.featureCache.get(key)
    guard cached == nil else { return }
    guard let page = try? await model.client.listZones(accountID: accountID) else {
      // Leave the marker unset so a later search retries the fetch.
      fetchedZonesForAccount = nil
      return
    }
    model.featureCache.set(key, page.items)
  }
}
