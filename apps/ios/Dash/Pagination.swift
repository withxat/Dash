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

/// Footer for paginated lists: a "Showing X of Y" caption when the total is
/// known plus the Load more pill. Callers show it only while more remain.
struct DashLoadMoreFooter: View {
  let loaded: Int
  var total: Int?
  var noun: String = "items"
  var caption: String?
  let phase: DashActionPhase
  var onSuccessPresentationCompleted: (@MainActor () -> Void)?
  let action: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 12) {
      if let text = caption ?? defaultCaption {
        // "Showing X of Y" — the counts roll as pages land instead of the
        // whole caption hard-swapping.
        Text(text)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(DashTheme.subtle)
          .contentTransition(
            reduceMotion ? .opacity : .numericText(value: Double(loaded)))
          .animation(
            reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morph,
            value: loaded)
      }
      DashPillButton(
        title: "Load more",
        phase: phase,
        onSuccessPresentationCompleted: onSuccessPresentationCompleted,
        action: action
      )
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
