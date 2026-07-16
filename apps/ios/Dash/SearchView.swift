import CloudflareAPI
import SwiftUI

enum SearchResourcesPhase: Equatable {
  case idle
  case loading
  case ready
  case failed(String)
}

enum SearchResourceFiltering {
  static let debounceNanoseconds: UInt64 = 120_000_000
  static let resultLimit = 6

  static func matches(_ name: String, query: String) -> Bool {
    name.localizedCaseInsensitiveContains(query)
  }
}

struct SearchView: View {
  @Binding var search: String
  var selection: Binding<Destination?>?
  @AppStorage(RecentResources.key) private var recentResourceData = ""
  @Environment(AppModel.self) private var model
  @State private var debouncedQuery = ""
  @State private var resourcesPhase: SearchResourcesPhase = .idle
  @State private var fetchedAccountID: String?

  init(search: Binding<String>, selection: Binding<Destination?>? = nil) {
    _search = search
    self.selection = selection
  }

  private var trimmedSearch: String {
    search.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var activeQuery: String {
    debouncedQuery
  }

  private var recentResources: [RecentResource] {
    RecentResources.continueItems(
      recent: RecentResources.decode(recentResourceData),
      accountID: model.activeAccountID
    )
  }

  private var featureResults: [FeatureID] {
    guard trimmedSearch.count >= 2 else { return [] }
    return FeatureCatalog.sorted(
      FeatureCatalog.all.filter {
        FeatureCatalog.matchesSearch($0, query: trimmedSearch)
      }
    )
  }

  private var zoneResults: [CloudflareZone] {
    guard activeQuery.count >= 2, let accountID = model.activeAccountID else { return [] }
    let zones: [CloudflareZone] = model.featureCache.get(FeatureCacheKey.zones(accountID)) ?? []
    return Array(
      zones.filter { SearchResourceFiltering.matches($0.name, query: activeQuery) }
        .prefix(SearchResourceFiltering.resultLimit)
    )
  }

  private var workerResults: [WorkerScript] {
    guard activeQuery.count >= 2, let accountID = model.activeAccountID else { return [] }
    let workers: [WorkerScript] = model.featureCache.get(FeatureCacheKey.workers(accountID)) ?? []
    return Array(
      workers.filter { SearchResourceFiltering.matches($0.name, query: activeQuery) }
        .prefix(SearchResourceFiltering.resultLimit)
    )
  }

  private var bucketResults: [R2Bucket] {
    guard activeQuery.count >= 2, let accountID = model.activeAccountID else { return [] }
    let buckets: [R2Bucket] = model.featureCache.get(FeatureCacheKey.r2Buckets(accountID)) ?? []
    return Array(
      buckets.filter { SearchResourceFiltering.matches($0.name, query: activeQuery) }
        .prefix(SearchResourceFiltering.resultLimit)
    )
  }

  private var kvResults: [KVNamespace] {
    guard activeQuery.count >= 2, let accountID = model.activeAccountID else { return [] }
    let namespaces: [KVNamespace] =
      model.featureCache.get(FeatureCacheKey.kvNamespaces(accountID)) ?? []
    return Array(
      namespaces.filter { SearchResourceFiltering.matches($0.name, query: activeQuery) }
        .prefix(SearchResourceFiltering.resultLimit)
    )
  }

  private var hasResourceHits: Bool {
    !zoneResults.isEmpty || !workerResults.isEmpty || !bucketResults.isEmpty
      || !kvResults.isEmpty
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        listContent
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, DashTheme.Spacing.section)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
      .animation(DashTheme.Motion.quick, value: trimmedSearch)
    }
    .dashCatalogScreen("Search")
    .task(id: trimmedSearch) {
      await debounceQuery()
    }
    .task(id: "\(model.activeAccountID ?? "")|\(debouncedQuery)") {
      await loadResourcesIfNeeded()
    }
  }

  @ViewBuilder
  private var listContent: some View {
    if trimmedSearch.isEmpty {
      if recentResources.isEmpty {
        DashEmptyState(
          icon: SolarAsset.search,
          title: "Search",
          message:
            "Find a resource type, zone, Worker, R2 bucket, or KV namespace."
        )
      } else {
        DashListGroup(title: "Recent") {
          ForEach(recentResources) { resource in
            resourceLink(resource, subtitle: resource.kind.displayName)
          }
        }
      }
    } else if trimmedSearch.count < 2 {
      DashEmptyState(
        icon: SolarAsset.search,
        title: "Keep typing",
        message: "Enter at least two characters to search."
      )
    } else {
      if !featureResults.isEmpty {
        featureResultsList
      }
      resourcesSection
      if shouldShowNothingFound {
        DashEmptyState(
          icon: SolarAsset.search,
          title: "Nothing found",
          message:
            "Nothing matches \(trimmedSearch). Try a resource type, zone, Worker, or bucket name."
        )
      }
    }
  }

  private var shouldShowNothingFound: Bool {
    featureResults.isEmpty
      && !hasResourceHits
      && resourcesPhase == .ready
  }

  private var featureResultsList: some View {
    DashListGroup(title: "Resource types") {
      ForEach(Array(featureResults.enumerated()), id: \.element) { _, item in
        resultLink(value: .feature(item)) {
          FeatureRow(feature: item, presentation: .catalog)
        }
      }
    }
  }

  @ViewBuilder
  private var resourcesSection: some View {
    switch resourcesPhase {
    case .idle:
      EmptyView()
    case .loading where !hasResourceHits:
      DashListGroup(title: "Resources") {
        HStack(spacing: 12) {
          DashLoadingRing(color: DashTheme.brand)
          Text("Loading resources…")
            .dashTextStyle(.supporting)
            .foregroundStyle(DashTheme.subtle)
          Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
      }
    case .failed(let message) where !hasResourceHits:
      DashListGroup(title: "Resources") {
        let presentation = DashFailurePresentation.from(message: message)
        VStack(alignment: .leading, spacing: 10) {
          DashNotice(kind: .error, message: presentation.message)
          DashSecondaryPillButton(title: presentation.action.title) {
            switch presentation.action {
            case .signInAgain:
              Task { await model.signOut() }
            case .grantAccess:
              model.requestAccess(to: DashAuthorizationScopes.searchResources)
            case .tryAgain:
              Task { await loadResourcesIfNeeded(force: true) }
            }
          }
        }
        .padding(.vertical, 8)
      }
    default:
      if !zoneResults.isEmpty {
        resourceGroup(title: "Zones") {
          ForEach(zoneResults, id: \.id) { zone in
            resourceLink(
              .zone(accountID: model.activeAccountID ?? "", id: zone.id, title: zone.name),
              subtitle: zone.status ?? "zone"
            )
          }
        }
      }
      if !workerResults.isEmpty {
        resourceGroup(title: "Workers") {
          ForEach(workerResults, id: \.id) { worker in
            resourceLink(
              .worker(accountID: model.activeAccountID ?? "", name: worker.name),
              subtitle: "Worker"
            )
          }
        }
      }
      if !bucketResults.isEmpty {
        resourceGroup(title: "R2 buckets") {
          ForEach(bucketResults, id: \.id) { bucket in
            resourceLink(
              .r2(accountID: model.activeAccountID ?? "", name: bucket.name),
              subtitle: "R2"
            )
          }
        }
      }
      if !kvResults.isEmpty {
        resourceGroup(title: "KV namespaces") {
          ForEach(kvResults, id: \.id) { namespace in
            resourceLink(
              .kv(
                accountID: model.activeAccountID ?? "", id: namespace.id, title: namespace.name),
              subtitle: "KV"
            )
          }
        }
      }
    }
  }

  private func resourceGroup<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    DashListGroup(title: title) {
      content()
    }
  }

  private func resourceLink(_ resource: RecentResource, subtitle: String) -> some View {
    resultLink(
      value: resource.destination,
      onNavigate: { RecentResources.record(resource) },
      label: {
        DashListRow(
          title: resource.title,
          subtitle: subtitle,
          icon: resource.featureID.solarOutlineAssetName,
          iconColor: FeatureVisualIdentity.catalogColor(for: resource.featureID)
        )
      }
    )
  }

  @ViewBuilder
  private func resultLink<Label: View>(
    value: Destination,
    onNavigate: @escaping () -> Void = {},
    @ViewBuilder label: @escaping () -> Label
  ) -> some View {
    if let selection {
      Button {
        onNavigate()
        selection.wrappedValue = value
      } label: {
        label()
      }
      .buttonStyle(DashPressButtonStyle())
      .accessibilityAddTraits(selection.wrappedValue == value ? .isSelected : [])
    } else {
      DashListGroupLink(value: value, onNavigate: onNavigate, label: label)
    }
  }

  private func debounceQuery() async {
    guard trimmedSearch.count >= 2 else {
      debouncedQuery = ""
      resourcesPhase = .idle
      return
    }
    do {
      try await Task.sleep(for: .milliseconds(120))
    } catch {
      return
    }
    guard !Task.isCancelled else { return }
    debouncedQuery = trimmedSearch
  }

  private func loadResourcesIfNeeded(force: Bool = false) async {
    guard activeQuery.count >= 2, let accountID = model.activeAccountID else {
      if activeQuery.isEmpty { resourcesPhase = .idle }
      return
    }

    let hasCache =
      model.featureCache.get(FeatureCacheKey.zones(accountID)) as [CloudflareZone]? != nil
      || model.featureCache.get(FeatureCacheKey.workers(accountID)) as [WorkerScript]? != nil
      || model.featureCache.get(FeatureCacheKey.r2Buckets(accountID)) as [R2Bucket]? != nil
      || model.featureCache.get(FeatureCacheKey.kvNamespaces(accountID)) as [KVNamespace]? != nil

    if !force, hasCache, fetchedAccountID == accountID {
      resourcesPhase = .ready
      // Still refresh in the background when cache is partial.
    }

    if !force, !hasCache {
      resourcesPhase = .loading
    }
    fetchedAccountID = accountID

    do {
      try await fetchMissingResources(accountID: accountID, force: force)
      resourcesPhase = .ready
    } catch {
      if error.dashIsCancellation || Task.isCancelled { return }
      if !hasResourceHits {
        fetchedAccountID = nil
        resourcesPhase = .failed(error.dashActionableMessage)
      } else {
        resourcesPhase = .ready
      }
    }
  }

  private func fetchMissingResources(accountID: String, force: Bool) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      if force
        || model.featureCache.get(FeatureCacheKey.zones(accountID)) as [CloudflareZone]? == nil
      {
        group.addTask {
          let page = try await model.client.listZones(accountID: accountID)
          await MainActor.run {
            model.featureCache.set(FeatureCacheKey.zones(accountID), page.items)
          }
        }
      }
      if force
        || model.featureCache.get(FeatureCacheKey.workers(accountID)) as [WorkerScript]? == nil
      {
        group.addTask {
          let workers = try await model.client.listWorkers(accountID: accountID)
          await MainActor.run {
            model.featureCache.set(FeatureCacheKey.workers(accountID), workers)
          }
        }
      }
      if force || model.featureCache.get(FeatureCacheKey.r2Buckets(accountID)) as [R2Bucket]? == nil
      {
        group.addTask {
          let buckets = try await model.client.listR2Buckets(accountID: accountID)
          await MainActor.run {
            model.featureCache.set(FeatureCacheKey.r2Buckets(accountID), buckets)
          }
        }
      }
      if force
        || model.featureCache.get(FeatureCacheKey.kvNamespaces(accountID)) as [KVNamespace]? == nil
      {
        group.addTask {
          let page = try await model.client.listKVNamespaces(accountID: accountID)
          await MainActor.run {
            model.featureCache.set(FeatureCacheKey.kvNamespaces(accountID), page.items)
          }
        }
      }
      try await group.waitForAll()
    }
  }
}

extension RecentResource {
  static func zone(accountID: String, id: String, title: String) -> RecentResource {
    RecentResource(kind: .zone, accountID: accountID, resourceID: id, title: title)
  }

  static func worker(accountID: String, name: String) -> RecentResource {
    RecentResource(kind: .worker, accountID: accountID, resourceID: name, title: name)
  }

  static func r2(accountID: String, name: String) -> RecentResource {
    RecentResource(kind: .r2, accountID: accountID, resourceID: name, title: name)
  }

  static func kv(accountID: String, id: String, title: String) -> RecentResource {
    RecentResource(kind: .kv, accountID: accountID, resourceID: id, title: title)
  }

}
