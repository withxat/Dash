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
/// Cancellation is deliberately not converted into a partial result. Callers
/// either receive the complete unique collection or an error.
enum DashPageLoader {
  static func loadAll<Item: Sendable, ID: Hashable & Sendable>(
    pageSize: Int,
    id: @escaping @Sendable (Item) -> ID,
    loadPage: @escaping @Sendable (_ page: Int, _ perPage: Int) async throws -> Page<Item>
  ) async throws -> [Item] {
    precondition(pageSize > 0)

    var requestedPage = 1
    var seenIDs = Set<ID>()
    var accumulated: [Item] = []

    while true {
      try Task.checkCancellation()
      let page = try await loadPage(requestedPage, pageSize)
      try Task.checkCancellation()

      let received = page.items.count
      guard received > 0 else { break }

      let unique = page.items.filter { seenIDs.insert(id($0)).inserted }
      guard !unique.isEmpty else { break }
      accumulated.append(contentsOf: unique)

      if let total = page.resultInfo?.totalCount, accumulated.count >= total {
        break
      }
      let effectivePageSize = page.resultInfo?.perPage ?? pageSize
      if page.resultInfo?.totalCount == nil, received < effectivePageSize {
        break
      }

      requestedPage += 1
    }

    return accumulated
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
  /// appending. A server-provided total wins over the full-page heuristic.
  mutating func absorb(info: ResultInfo?, received: Int, loaded: Int, pageSize: Int) {
    nextPage = (info?.page ?? nextPage) + 1
    if let total = info?.totalCount { totalCount = total }
    if let totalCount {
      canLoadMore = loaded < totalCount
    } else {
      canLoadMore = received > 0 && received == pageSize
    }
  }

  /// Restores bookkeeping for a cache-served array: whole pages were
  /// accumulated, so an exact multiple of the page size may have a successor.
  /// An exact-multiple total costs at most one empty fetch that flips
  /// `canLoadMore` off.
  mutating func rehydrate(loaded: Int, pageSize: Int) {
    nextPage = loaded / pageSize + 1
    totalCount = nil
    canLoadMore = loaded > 0 && loaded.isMultiple(of: pageSize)
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
