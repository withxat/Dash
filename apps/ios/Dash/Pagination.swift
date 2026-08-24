import CloudflareAPI
import SwiftUI

/// Fetches every page of an ID-addressable resource without trusting any one
/// pagination signal on its own.
///
/// Cloudflare endpoints are not perfectly consistent about `result_info`, so
/// completion accepts all of the safe terminal signals:
///
/// - an empty page,
/// - a page shorter than the server's effective page size,
/// - the accumulated unique count reaching `total_count`, or
/// - a page containing no new IDs.
///
/// `result_info.page` is advisory. Some endpoints repeat or omit it even while
/// honoring the requested page, so data identity — not metadata — is the loop
/// guard.
///
/// Cancellation is deliberately not converted into a partial result. The
/// unbounded `loadAll` API either receives the complete collection or throws;
/// bounded callers get an explicit `isComplete` result.
struct DashPageLoadResult<Item: Sendable>: Sendable {
  let items: [Item]
  let isComplete: Bool
}

enum DashPageLoader {
  static func loadAll<Item: Sendable, ID: Hashable & Sendable>(
    pageSize: Int,
    id: @escaping @Sendable (Item) -> ID,
    loadPage: @escaping @Sendable (_ page: Int, _ perPage: Int) async throws -> Page<Item>
  ) async throws -> [Item] {
    try await load(
      pageSize: pageSize,
      maximumPages: nil,
      id: id,
      loadPage: loadPage
    ).items
  }

  /// Loads a unique catalog with an optional request budget. Terminal API
  /// signals mark the result complete; exhausting the budget does not.
  static func load<Item: Sendable, ID: Hashable & Sendable>(
    pageSize: Int,
    maximumPages: Int?,
    id: @escaping @Sendable (Item) -> ID,
    loadPage: @escaping @Sendable (_ page: Int, _ perPage: Int) async throws -> Page<Item>
  ) async throws -> DashPageLoadResult<Item> {
    precondition(pageSize > 0)
    precondition(maximumPages.map { $0 > 0 } ?? true)

    var requestedPage = 1
    var seenIDs = Set<ID>()
    var accumulated: [Item] = []

    while true {
      try Task.checkCancellation()
      let page = try await loadPage(requestedPage, pageSize)
      try Task.checkCancellation()

      let received = page.items.count
      guard received > 0 else {
        return DashPageLoadResult(items: accumulated, isComplete: true)
      }

      let unique = page.items.filter { seenIDs.insert(id($0)).inserted }
      guard !unique.isEmpty else {
        return DashPageLoadResult(items: accumulated, isComplete: true)
      }
      accumulated.append(contentsOf: unique)

      if let total = page.resultInfo?.totalCount, accumulated.count >= total {
        return DashPageLoadResult(items: accumulated, isComplete: true)
      }
      let effectivePageSize = page.resultInfo?.perPage ?? pageSize
      if page.resultInfo?.totalCount == nil, received < effectivePageSize {
        return DashPageLoadResult(items: accumulated, isComplete: true)
      }
      if let maximumPages, requestedPage >= maximumPages {
        return DashPageLoadResult(items: accumulated, isComplete: false)
      }

      requestedPage += 1
    }
  }
}

/// Settled outcomes for a zone picker. A failed lookup is deliberately not an
/// empty loaded result: callers use that distinction to avoid claiming that no
/// zone matches when the account's zones are merely unavailable.
enum DashZonePickerLoadResult: Equatable, Sendable {
  case loaded([CloudflareZone])
  case failed(String)
  case cancelled
}

/// Binds a zone-picker submission to the account generation that supplied its
/// matched zone. The same decision is checked before the request and after
/// every suspension point so an account switch cannot apply stale effects.
enum DashZonePickerSubmissionGuard {
  static func submissionContext(
    zonesContext: AccountRequestContext?,
    currentContext: AccountRequestContext?
  ) -> AccountRequestContext? {
    guard let zonesContext, zonesContext == currentContext else { return nil }
    return zonesContext
  }

  static func allowsEffects(
    for submissionContext: AccountRequestContext,
    zonesContext: AccountRequestContext?,
    currentContext: AccountRequestContext?,
    isCancelled: Bool
  ) -> Bool {
    !isCancelled
      && zonesContext == submissionContext
      && currentContext == submissionContext
  }
}

/// Cache-first loading shared by forms that infer an owning zone from a typed
/// hostname. Prefers the Domains catalog cache (which fills eagerly); on a
/// miss it walks the complete unique catalog so a zone beyond Domains' eager
/// paint budget can still own a submitted hostname.
@MainActor
enum DashZonePickerLoader {
  static func load(
    model: AppModel,
    context: AccountRequestContext
  ) async -> DashZonePickerLoadResult {
    if model.featureCache.zonesCatalogIsComplete(accountID: context.accountID),
      let cached: [CloudflareZone] = model.featureCache.get(
        FeatureCacheKey.zones(context.accountID))
    {
      guard model.isCurrentAccount(context) else { return .cancelled }
      return .loaded(cached)
    }

    let client = model.client
    do {
      let collected = try await DashPageLoader.loadAll(
        pageSize: ZonesCatalogFetchRules.pageSize,
        id: \.id
      ) { page, perPage in
        try await client.listZones(
          accountID: context.accountID,
          page: page,
          perPage: perPage)
      }
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        return .cancelled
      }
      model.featureCache.storeZones(
        collected,
        accountID: context.accountID,
        catalogIsComplete: true)
      return .loaded(collected)
    } catch {
      guard !Task.isCancelled, !error.dashIsCancellation, model.isCurrentAccount(context) else {
        return .cancelled
      }
      return .failed(error.dashActionableMessage)
    }
  }
}

/// Page-number pagination bookkeeping for lists that fetch a first page
/// eagerly and append further pages on demand. `nextPage` is always the page
/// to request next; call `reset()` before a fresh load, `absorb` after every
/// fetch, and `rehydrate` when an accumulated array is restored from cache.
struct DashPageState: Equatable {
  private(set) var nextPage = 1
  private(set) var totalCount: Int?
  private(set) var canLoadMore = false

  mutating func reset() {
    nextPage = 1
    totalCount = nil
    canLoadMore = false
  }

  /// Folds a fetched page into the state. `loaded` is the row count after
  /// appending and `added` is the number of new identities. The requested page
  /// is authoritative: some endpoints repeat stale `result_info.page` values,
  /// which must not make the caller request and append the same page forever.
  /// A server-provided total wins over the full-page heuristic.
  mutating func absorb(
    info: ResultInfo?,
    requestedPage: Int,
    received: Int,
    added: Int,
    loaded: Int,
    pageSize: Int
  ) {
    nextPage = requestedPage + 1
    if let total = info?.totalCount { totalCount = total }
    if received > 0, added == 0 {
      canLoadMore = false
    } else if let totalCount {
      canLoadMore = loaded < totalCount
    } else {
      canLoadMore = received > 0 && received == (info?.perPage ?? pageSize)
    }
  }
}

/// Footer for lists that append the next page as the user scrolls near the
/// end. A centered loading ring while a page is in flight; otherwise a 1pt
/// sentinel so LazyVStack still materializes the trigger.
///
/// Identity tracks `loaded` so a page that lands while this footer is still
/// on-screen re-arms `onAppear` and keeps fetching until the catalog ends or
/// the footer scrolls out of view. Callers must no-op when a fetch is already
/// running (and should skip while a load-more error is still showing).
struct DashInfiniteScrollFooter: View {
  let loaded: Int
  var isLoading: Bool
  let onNeedMore: () -> Void

  var body: some View {
    Group {
      if isLoading {
        DashLoadingRing(color: DashTheme.brand, size: 16, lineWidth: 2.5)
          .accessibilityLabel("Loading")
      } else {
        Color.clear.frame(height: 1)
      }
    }
    .frame(maxWidth: .infinity)
    .dashItemBoundary()
    // Re-identity after each append so a still-visible footer can request the
    // next page without waiting for the user to scroll away and back.
    .id(loaded)
    .onAppear {
      guard !isLoading else { return }
      onNeedMore()
    }
  }
}
