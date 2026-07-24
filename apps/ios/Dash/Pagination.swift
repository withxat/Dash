import CloudflareAPI
import SwiftUI

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

/// Footer for paginated lists: a "Showing X of Y" caption when the total is
/// known plus the Load more pill. Callers show it only while more remain.
struct DashLoadMoreFooter: View {
  let loaded: Int
  var total: Int?
  var noun: String = "items"
  var caption: String?
  let isLoading: Bool
  let action: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      if let text = caption ?? defaultCaption {
        Text(text)
          .font(.caption)
          .foregroundStyle(DashTheme.subtle)
      }
      DashPillButton(title: "Load more", isLoading: isLoading, action: action)
    }
    .frame(maxWidth: .infinity)
    // Feature lists keep LazyVStack spacing at 0 for virtualized rows; the
    // footer opts into the same item gap used between adjacent surfaces.
    .dashItemBoundary()
  }

  private var defaultCaption: String? {
    guard let total, total > loaded else { return nil }
    let localizedNoun = DashL10n.ui(noun)
    return DashL10n.string("Showing \(loaded) of \(total) \(localizedNoun)")
  }
}
