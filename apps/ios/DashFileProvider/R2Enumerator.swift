import CloudflareAPI
import FileProvider
import Foundation

enum R2EnumeratorContainer: Sendable {
  case root
  case prefix(bucket: String, prefix: String)
  case workingSet
}

final class R2Enumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
  private static let maximumPageBytes = 500
  private static let noChangeAnchor = NSFileProviderSyncAnchor(
    Data("dash-r2-no-change-feed-v1".utf8))

  private let container: R2EnumeratorContainer
  private let accountID: String
  private let client: CloudflareClient
  private let tokenStore: KeychainTokenStore
  private let operations = FileProviderOperationRegistry()
  private let pageStateStore = R2EnumeratorPageStateStore()

  init(
    container: R2EnumeratorContainer,
    accountID: String,
    client: CloudflareClient,
    tokenStore: KeychainTokenStore
  ) {
    self.container = container
    self.accountID = accountID
    self.client = client
    self.tokenStore = tokenStore
    super.init()
  }

  func invalidate() {
    operations.cancelAll()
    pageStateStore.removeAll()
  }

  func enumerateItems(
    for observer: any NSFileProviderEnumerationObserver,
    startingAt page: NSFileProviderPage
  ) {
    let observer = FileProviderSendableBox(observer)
    operations.start { [self] in
      do {
        try Task.checkCancellation()
        let credentials = try await FileProviderCredentialState.load(from: tokenStore)

        switch container {
        case .workingSet:
          observer.value.didEnumerate([])
          observer.value.finishEnumerating(upTo: nil)
        case .root:
          try await enumerateBuckets(
            for: observer.value,
            startingAt: page,
            allowsWriting: credentials.allowsWriting)
        case .prefix(let bucket, let prefix):
          try await enumerateObjects(
            bucket: bucket,
            prefix: prefix,
            for: observer.value,
            startingAt: page,
            allowsWriting: credentials.allowsWriting)
        }
      } catch {
        observer.value.finishEnumeratingWithError(
          FileProviderErrorMapping.map(error, operation: .enumeration))
      }
    }
  }

  func enumerateChanges(
    for observer: any NSFileProviderChangeObserver,
    from syncAnchor: NSFileProviderSyncAnchor
  ) {
    // R2's REST API has no change feed. A constant anchor and zero changes
    // avoid syncAnchorExpired, which would make the system repeatedly discard
    // and rebuild the replica against the account-wide R2 rate limit.
    observer.didUpdate([])
    observer.didDeleteItems(withIdentifiers: [])
    observer.finishEnumeratingChanges(upTo: Self.noChangeAnchor, moreComing: false)
  }

  func currentSyncAnchor(
    completionHandler: @escaping @Sendable (NSFileProviderSyncAnchor?) -> Void
  ) {
    completionHandler(Self.noChangeAnchor)
  }

  private func enumerateBuckets(
    for observer: any NSFileProviderEnumerationObserver,
    startingAt page: NSFileProviderPage,
    allowsWriting: Bool
  ) async throws {
    let pageState = try pageState(from: page)
    guard pageState.startAfter == nil else {
      throw CloudflareAPIError.invalidResponse
    }
    let result = try await client.listR2BucketsPage(
      accountID: accountID,
      cursor: pageState.cursor,
      perPage: R2Limits.listMaximumPerPage)
    try Task.checkCancellation()

    let items = result.items.map {
      R2FileProviderItem.bucket(
        name: $0.name,
        creationDate: $0.creationDate,
        allowsWriting: allowsWriting)
    }
    observer.didEnumerate(items)
    observer.finishEnumerating(
      upTo: try nextBucketPage(cursor: result.cursor, after: pageState))
  }

  private func enumerateObjects(
    bucket: String,
    prefix: String,
    for observer: any NSFileProviderEnumerationObserver,
    startingAt page: NSFileProviderPage,
    allowsWriting: Bool
  ) async throws {
    let pageState = try pageState(from: page)
    let result = try await client.listR2Objects(
      accountID: accountID,
      bucket: bucket,
      cursor: pageState.cursor,
      prefix: prefix,
      delimiter: "/",
      startAfter: pageState.startAfter,
      perPage: R2Limits.listMaximumPerPage)
    try Task.checkCancellation()
    let boundaryFileKeyToHide = try await boundaryFileKeyToHide(
      in: result,
      bucket: bucket)

    var seenIdentifiers = Set<NSFileProviderItemIdentifier>()
    var seenFilenames = Set<String>()
    var items: [R2FileProviderItem] = []

    for value in result.commonPrefixes {
      guard value.hasPrefix(prefix), value != prefix else { continue }
      let directoryKey = value.hasSuffix("/") ? value : "\(value)/"
      let path = R2ObjectPath(bucket: bucket, key: directoryKey)
      guard path.isFileProviderRepresentable else { continue }
      let item = R2FileProviderItem.directory(path: path, allowsWriting: allowsWriting)
      if seenIdentifiers.insert(item.itemIdentifier).inserted,
        seenFilenames.insert(item.filename).inserted
      {
        items.append(item)
      }
    }

    // Directory markers are gathered before files so an object-store
    // namespace collision (`reports` and `reports/...`) never hands Files two
    // sibling items with the same filename. The folder remains navigable; the
    // colliding object stays available in Dash's native R2 browser.
    for object in result.objects where object.key.hasSuffix("/") {
      // The marker for the folder currently being enumerated is metadata for
      // that folder, not one of its children.
      guard object.key != prefix else { continue }
      let path = R2ObjectPath(bucket: bucket, key: object.key)
      guard path.isFileProviderRepresentable else { continue }
      let item = R2FileProviderItem.directory(path: path, allowsWriting: allowsWriting)
      if seenIdentifiers.insert(item.itemIdentifier).inserted,
        seenFilenames.insert(item.filename).inserted
      {
        items.append(item)
      }
    }

    for object in result.objects where !object.key.hasSuffix("/") {
      guard object.key != prefix else { continue }
      if let boundaryFileKeyToHide,
        r2KeysHaveIdenticalBytes(object.key, boundaryFileKeyToHide)
      {
        continue
      }
      let path = R2ObjectPath(bucket: bucket, key: object.key)
      guard path.isFileProviderRepresentable else { continue }
      let item = R2FileProviderItem.object(
        path: path,
        metadata: object,
        allowsWriting: allowsWriting)
      if seenIdentifiers.insert(item.itemIdentifier).inserted,
        seenFilenames.insert(item.filename).inserted
      {
        items.append(item)
      }
    }

    observer.didEnumerate(items)
    observer.finishEnumerating(
      upTo: try nextObjectPage(result: result, after: pageState))
  }

  /// An exact object key sorts immediately before its child prefix, so the
  /// pair can straddle a 1,000-item API page boundary. Probe only the final
  /// logical entry of a truncated page and let the directory on the next page
  /// win, matching the same-page collision policy without an extra request
  /// per object.
  private func boundaryFileKeyToHide(
    in result: R2ObjectPage,
    bucket: String
  ) async throws -> String? {
    guard result.isTruncated else { return nil }
    let lastValue = lastR2PageValue(in: result)
    guard
      let lastValue,
      result.objects.contains(where: {
        !$0.key.hasSuffix("/") && r2KeysHaveIdenticalBytes($0.key, lastValue)
      }),
      R2ObjectPath(bucket: bucket, key: lastValue).isFileProviderRepresentable
    else { return nil }

    let children = try await client.listR2Objects(
      accountID: accountID,
      bucket: bucket,
      prefix: "\(lastValue)/",
      delimiter: "/",
      perPage: 1)
    try Task.checkCancellation()
    return children.objects.isEmpty
      && children.commonPrefixes.isEmpty
      && !children.isTruncated
      ? nil
      : lastValue
  }

  private func pageState(from page: NSFileProviderPage) throws -> R2EnumeratorPageState {
    let rawValue = page.rawValue
    if rawValue == NSFileProviderPage.initialPageSortedByName as Data
      || rawValue == NSFileProviderPage.initialPageSortedByDate as Data
    {
      pageStateStore.removeAll()
      return .initial
    }
    guard rawValue.count <= Self.maximumPageBytes,
      let token = String(data: rawValue, encoding: .utf8)
    else {
      throw CloudflareAPIError.invalidResponse
    }
    if token.hasPrefix("c:") {
      let cursor = String(token.dropFirst(2))
      guard !cursor.isEmpty else { throw CloudflareAPIError.invalidResponse }
      return .cursor(cursor)
    }
    if token.hasPrefix("s:") {
      let startAfter = String(token.dropFirst(2))
      guard !startAfter.isEmpty else { throw CloudflareAPIError.invalidResponse }
      return .startAfter(startAfter)
    }
    if token.hasPrefix("m:") {
      let identifier = String(token.dropFirst(2))
      guard !identifier.isEmpty, let state = pageStateStore.state(for: identifier) else {
        throw CloudflareAPIError.invalidResponse
      }
      return state
    }
    throw CloudflareAPIError.invalidResponse
  }

  private func nextBucketPage(
    cursor: String?,
    after pageState: R2EnumeratorPageState
  ) throws -> NSFileProviderPage? {
    guard let cursor, !cursor.isEmpty else { return nil }
    guard cursor != pageState.cursor else {
      throw CloudflareAPIError.invalidResponse
    }
    return encodedPage(kind: "c:", value: cursor)
  }

  private func nextObjectPage(
    result: R2ObjectPage,
    after pageState: R2EnumeratorPageState
  ) throws -> NSFileProviderPage? {
    guard result.isTruncated else { return nil }

    if let cursor = result.cursor,
      !cursor.isEmpty,
      cursor != pageState.cursor
    {
      return encodedPage(kind: "c:", value: cursor)
    }

    // File Provider caps a page token at 500 bytes, while Cloudflare cursors
    // are opaque and unbounded. Fall back to the last returned key/prefix,
    // which R2's `start_after` accepts without replaying the current page.
    let lastValue = lastR2PageValue(in: result)
    guard let lastValue,
      !lastValue.isEmpty,
      pageState.startAfter.map({ !r2KeysHaveIdenticalBytes(lastValue, $0) }) ?? true
    else {
      throw CloudflareAPIError.invalidResponse
    }
    return encodedPage(kind: "s:", value: lastValue)
  }

  private func encodedPage(
    kind: String,
    value: String
  ) -> NSFileProviderPage {
    let data = Data("\(kind)\(value)".utf8)
    if data.count <= Self.maximumPageBytes {
      return NSFileProviderPage(data)
    }

    // R2 keys can be 1,024 bytes and cursors are opaque. Keep an oversized
    // continuation in the enumerator instance and return a short indirection
    // token; File Provider calls every page on this same enumerator.
    let state: R2EnumeratorPageState =
      kind == "c:" ? .cursor(value) : .startAfter(value)
    return pageStateStore.page(for: state)
  }
}

/// R2 orders object keys lexicographically by their UTF-8 bytes. Swift String
/// comparison uses Unicode canonical equivalence, which can choose a different
/// page boundary for precomposed and decomposed spellings of the same glyph.
private func lastR2PageValue(in result: R2ObjectPage) -> String? {
  (result.objects.map(\.key) + result.commonPrefixes).max {
    $0.utf8.lexicographicallyPrecedes($1.utf8)
  }
}

private func r2KeysHaveIdenticalBytes(_ lhs: String, _ rhs: String) -> Bool {
  lhs.utf8.elementsEqual(rhs.utf8)
}

private enum R2EnumeratorPageState: Sendable {
  case initial
  case cursor(String)
  case startAfter(String)

  var cursor: String? {
    guard case .cursor(let value) = self else { return nil }
    return value
  }

  var startAfter: String? {
    guard case .startAfter(let value) = self else { return nil }
    return value
  }
}

private final class R2EnumeratorPageStateStore: @unchecked Sendable {
  private let lock = NSLock()
  private var states: [String: R2EnumeratorPageState] = [:]
  private var insertionOrder: [String] = []
  private let capacity = 16

  func page(for state: R2EnumeratorPageState) -> NSFileProviderPage {
    let identifier = UUID().uuidString
    lock.withLock {
      states[identifier] = state
      insertionOrder.append(identifier)
      while insertionOrder.count > capacity {
        states.removeValue(forKey: insertionOrder.removeFirst())
      }
    }
    return NSFileProviderPage(Data("m:\(identifier)".utf8))
  }

  func state(for identifier: String) -> R2EnumeratorPageState? {
    lock.withLock { states[identifier] }
  }

  func removeAll() {
    lock.withLock {
      states.removeAll()
      insertionOrder.removeAll()
    }
  }
}
