import CloudflareAPI
import ImageIO
import SwiftUI

// MARK: - Thumbnail store

/// Session-scoped thumbnail cache for R2 rows. Downloads are deduped per
/// object, capped in width, and decoded off the main actor via ImageIO
/// downsampling so a bucket of camera originals never inflates to
/// full-resolution bitmaps.
actor R2ThumbnailStore {
  private struct SlotWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }

  private struct InFlight {
    let generation: UUID
    let task: Task<Void, Never>
    var continuations: [UUID: CheckedContinuation<UIImage?, Never>]
    var cancelledWaiters: Set<UUID>
  }

  private let cache = NSCache<NSString, UIImage>()
  private var inFlight: [String: InFlight] = [:]
  private var availableSlots = 4
  private var slotWaiters: [SlotWaiter] = []

  init() {
    cache.countLimit = 300
    cache.totalCostLimit = 48 * 1024 * 1024
  }

  func rowThumbnail(
    client: CloudflareClient, accountID: String, bucket: String, object: R2Object
  ) async -> UIImage? {
    await image(
      kind: "row", maxBytes: R2Media.thumbnailByteLimit, maxPixel: 240,
      client: client, accountID: accountID, bucket: bucket, object: object)
  }

  func clear() {
    cache.removeAllObjects()
    for entry in inFlight.values {
      entry.task.cancel()
      for continuation in entry.continuations.values {
        continuation.resume(returning: nil)
      }
    }
    inFlight.removeAll()
  }

  private func image(
    kind: String, maxBytes: Int, maxPixel: CGFloat,
    client: CloudflareClient, accountID: String, bucket: String, object: R2Object
  ) async -> UIImage? {
    guard R2Media.isImage(object), let size = object.size, size <= maxBytes else { return nil }
    let version = R2Media.versionToken(for: object)
    let key = "\(kind)|\(accountID)|\(bucket)|\(object.key)|\(version)"
    if let hit = cache.object(forKey: key as NSString) { return hit }
    let waiterID = UUID()
    let generation: UUID
    if let existing = inFlight[key] {
      generation = existing.generation
    } else {
      let newGeneration = UUID()
      generation = newGeneration
      let task = Task { [weak self] in
        guard let self else { return }
        let result = await self.fetch(
          cacheKey: key, maxPixel: maxPixel,
          client: client, accountID: accountID, bucket: bucket, objectKey: object.key)
        await self.complete(key: key, generation: newGeneration, result: result)
      }
      inFlight[key] = InFlight(
        generation: newGeneration,
        task: task,
        continuations: [:],
        cancelledWaiters: [])
    }
    return await withTaskCancellationHandler {
      await waitForResult(waiterID: waiterID, key: key, generation: generation)
    } onCancel: {
      Task {
        await self.cancelWaiter(waiterID, key: key, generation: generation)
      }
    }
  }

  private func waitForResult(
    waiterID: UUID, key: String, generation: UUID
  ) async -> UIImage? {
    await withCheckedContinuation { continuation in
      guard var entry = inFlight[key], entry.generation == generation else {
        continuation.resume(
          returning: Task.isCancelled ? nil : cache.object(forKey: key as NSString))
        return
      }
      if Task.isCancelled || entry.cancelledWaiters.remove(waiterID) != nil {
        continuation.resume(returning: nil)
        if entry.continuations.isEmpty && entry.cancelledWaiters.isEmpty {
          entry.task.cancel()
          inFlight[key] = nil
        } else {
          inFlight[key] = entry
        }
      } else {
        entry.continuations[waiterID] = continuation
        inFlight[key] = entry
      }
    }
  }

  private func cancelWaiter(_ waiterID: UUID, key: String, generation: UUID) {
    guard var entry = inFlight[key], entry.generation == generation else { return }
    if let continuation = entry.continuations.removeValue(forKey: waiterID) {
      continuation.resume(returning: nil)
      if entry.continuations.isEmpty && entry.cancelledWaiters.isEmpty {
        entry.task.cancel()
        inFlight[key] = nil
      } else {
        inFlight[key] = entry
      }
    } else {
      entry.cancelledWaiters.insert(waiterID)
      inFlight[key] = entry
    }
  }

  private func complete(
    key: String, generation: UUID, result: UIImage?
  ) {
    guard let entry = inFlight[key], entry.generation == generation else { return }
    inFlight[key] = nil
    for continuation in entry.continuations.values {
      continuation.resume(returning: result)
    }
  }

  private func fetch(
    cacheKey: String, maxPixel: CGFloat,
    client: CloudflareClient, accountID: String, bucket: String, objectKey: String
  ) async -> UIImage? {
    guard await acquireSlot() else { return nil }
    defer { releaseSlot() }
    guard !Task.isCancelled else { return nil }
    let temporaryFile = R2TemporaryFile.make(purpose: "r2-thumbnail", filename: objectKey)
    defer { temporaryFile.remove() }
    do {
      try await client.downloadR2Object(
        accountID: accountID,
        bucket: bucket,
        key: objectKey,
        to: temporaryFile.fileURL,
        maximumBytes: Int64(R2Media.thumbnailByteLimit))
    } catch {
      return nil
    }
    guard !Task.isCancelled else { return nil }
    guard let image = Self.downsample(temporaryFile.fileURL, maxPixel: maxPixel) else { return nil }
    let cost =
      image.cgImage.map { $0.bytesPerRow * $0.height }
      ?? Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    cache.setObject(image, forKey: cacheKey as NSString, cost: cost)
    return image
  }

  private static func downsample(_ fileURL: URL, maxPixel: CGFloat) -> UIImage? {
    let sourceOptions: [CFString: Any] = [
      kCGImageSourceShouldCache: false
    ]
    guard
      let source = CGImageSourceCreateWithURL(
        fileURL as CFURL,
        sourceOptions as CFDictionary)
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }
    return UIImage(cgImage: cgImage)
  }

  private func acquireSlot() async -> Bool {
    guard !Task.isCancelled else { return false }
    if availableSlots > 0 {
      availableSlots -= 1
      return true
    }
    let waiterID = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        slotWaiters.append(SlotWaiter(id: waiterID, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancelSlotWaiter(waiterID) }
    }
  }

  private func releaseSlot() {
    if slotWaiters.isEmpty {
      availableSlots += 1
    } else {
      slotWaiters.removeFirst().continuation.resume(returning: true)
    }
  }

  private func cancelSlotWaiter(_ waiterID: UUID) {
    guard let index = slotWaiters.firstIndex(where: { $0.id == waiterID }) else { return }
    slotWaiters.remove(at: index).continuation.resume(returning: false)
  }
}

// MARK: - Browser row

/// Full identity for one row thumbnail request. Keeping the account context in
/// the SwiftUI task ID makes an account switch cancel the old waiter even when
/// the other account has an identically named bucket, key, and object version.
struct R2ThumbnailRequestIdentity: Hashable, Sendable {
  let context: AccountRequestContext?
  let bucket: String
  let objectKey: String
  let version: String
}

/// Object row with a lazily fetched thumbnail; in selection mode the tap
/// toggles membership instead of opening the preview.
struct R2ObjectRow: View {
  @Environment(AppModel.self) private var model
  let bucket: String
  let object: R2Object
  let title: String
  var selecting = false
  var selected = false
  let action: () -> Void
  @State private var thumbnail: UIImage?
  @State private var thumbnailIdentity: R2ThumbnailRequestIdentity?
  @State private var activeThumbnailRequest: R2ThumbnailRequestIdentity?

  private var thumbnailRequestIdentity: R2ThumbnailRequestIdentity {
    R2ThumbnailRequestIdentity(
      context: model.accountRequestContext,
      bucket: bucket,
      objectKey: object.key,
      version: R2Media.versionToken(for: object))
  }

  var body: some View {
    Button(action: action) {
      DashListRow(
        title: title,
        subtitle: objectSubtitle,
        icon: FileTypeIcon.asset(forKey: object.key),
        iconColor: DashTheme.iconMuted,
        thumbnail: thumbnail,
        showsChevron: false
      ) {
        if selecting {
          SolarIcon(
            asset: selected ? SolarAsset.checkCircleFill : SolarAsset.circle,
            size: 22,
            color: selected ? DashTheme.brand : DashTheme.placeholder)
        }
      }
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityLabel(objectAccessibilityLabel)
    .accessibilityHint(
      selecting
        ? (selected ? "Double tap to deselect" : "Double tap to select")
        : "Double tap to preview"
    )
    .accessibilityAddTraits(selected ? .isSelected : [])
    .task(id: thumbnailRequestIdentity) {
      let request = thumbnailRequestIdentity
      activeThumbnailRequest = request
      guard let context = request.context else {
        thumbnail = nil
        thumbnailIdentity = nil
        return
      }
      if thumbnailIdentity != request {
        // Never paint another account's or another object version's image while
        // the replacement request is in flight.
        thumbnail = nil
        thumbnailIdentity = nil
      } else if thumbnail != nil {
        return
      }

      let image = await model.r2Thumbnails.rowThumbnail(
        client: model.client, accountID: context.accountID, bucket: bucket, object: object)
      guard
        !Task.isCancelled,
        model.isCurrentAccount(context),
        activeThumbnailRequest == request
      else { return }
      thumbnail = image
      thumbnailIdentity = request
    }
  }

  private var objectSubtitle: String? {
    guard let size = object.size else { return nil }
    let formattedSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    guard size > R2Media.transferSizeLimit else { return formattedSize }
    let hasMountedAccount =
      model.activeAccountID.map {
        FileProviderDomains.mirroredAccountIDs().contains($0)
      } ?? false
    let limitCopy =
      hasMountedAccount
      ? DashL10n.string("Over Dash's 100 MB preview limit — open in Files")
      : DashL10n.string("Over Dash's 100 MB preview limit")
    return "\(formattedSize) · \(limitCopy)"
  }

  private var objectAccessibilityLabel: String {
    var parts = [title]
    if let objectSubtitle {
      parts.append(objectSubtitle)
    }
    if selecting { parts.append(selected ? "Selected" : "Not selected") }
    return parts.joined(separator: ", ")
  }
}

// MARK: - Public access

/// The bucket's public exposure, cached per bucket so object trays can build
/// copyable URLs without refetching domains on every open.
struct R2DomainsSnapshot: Sendable {
  var managed: R2ManagedDomain?
  var custom: [R2CustomDomain]

  /// Preferred host for public links: a serving custom domain beats r2.dev
  /// (which Cloudflare rate-limits and recommends against for production).
  var publicHost: String? {
    let serving = custom.first {
      $0.enabled && $0.status?.ownership == "active" && $0.status?.ssl == "active"
    }
    if let serving { return serving.domain }
    if let enabled = custom.first(where: { $0.enabled && $0.status == nil }) {
      return enabled.domain
    }
    if let managed, managed.enabled { return managed.domain }
    return nil
  }

  func publicURL(forKey key: String) -> URL? {
    guard let host = publicHost else { return nil }
    return Self.url(host: host, key: key)
  }

  static func url(host: String, key: String) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = "/" + key
    return components.url
  }
}

// MARK: - Bucket settings

/// Domain management for one bucket: the r2.dev development URL toggle plus
/// custom domains (list, attach, detach). Public-URL copying everywhere else
/// keys off the snapshot this screen refreshes.
struct R2BucketSettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.destinationNavigator) private var navigator
  let bucket: String
  @State private var managed: R2ManagedDomain?
  @State private var custom: [R2CustomDomain] = []
  @State private var loading = true
  @State private var error: String?
  @State private var togglingManaged = false
  @State private var addsDomain = false
  @State private var selectedDomain: R2CustomDomain?
  @State private var deleteDomainPhase: DashActionPhase = .idle
  @State private var deleteError: String?
  @State private var showsDeleteBucket = false

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: managed != nil || !custom.isEmpty,
      retry: { Task { await load(force: true) } }
    ) {
      managedCard
      customDomainsGroup
        .dashSectionBoundary()
      if featureAllowsWrites {
        deleteBucketRow
      }
    }
    .detailHeader(
      icon: .solar(SolarAsset.Content.settings),
      title: "Bucket settings",
      tint: FeatureVisualIdentity.heroColor(for: .r2)
    )
    .refreshable { await load(force: true) }
    .task { await load() }
    .dashTray(isPresented: $addsDomain, title: "Add custom domain") {
      R2AddDomainForm(bucket: bucket) {
        await load(force: true)
      }
    }
    .dashTray(
      item: $selectedDomain,
      title: { $0.domain },
      content: { domain in
        DashDetailTray(
          fields: domain.detailFields,
          deleteMessage: featureAllowsWrites
            ? DashL10n.string(
              "Detaches \(domain.domain) from \(bucket). The domain's DNS record is removed; the zone itself is untouched."
            )
            : nil,
          deletePhase: deleteDomainPhase,
          onDeleteSuccessPresentationCompleted: completeDomainDeletionPresentation,
          deleteError: deleteError,
          onDelete: featureAllowsWrites ? { Task { await remove(domain) } } : nil
        )
      }
    )
    .dashMoreMenu(
      isPresented: $showsDeleteBucket,
      title: DashL10n.string("Delete bucket"),
      actions: [deleteBucketAction]
    )
  }

  private var deleteBucketRow: some View {
    Button {
      showsDeleteBucket = true
    } label: {
      HStack(spacing: 12) {
        SolarIcon(asset: SolarAsset.trash, size: 22, color: DashTheme.danger)
        Text(DashL10n.string("Delete bucket"))
          .dashTextStyle(.bodyMedium)
          .foregroundStyle(DashTheme.danger)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        DashTheme.dangerTint,
        in: RoundedRectangle(cornerRadius: DashTheme.Radius.button, style: .continuous))
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityLabel(DashL10n.string("Delete bucket"))
    .padding(.top, DashTheme.Spacing.section)
  }

  private var deleteBucketAction: DashDangerAction {
    DashDangerAction(
      title: DashL10n.string("Delete bucket"),
      message: DashL10n.string(
        "Permanently deletes \(bucket). The bucket must be empty. This can't be undone."
      ),
      onSuccessPresentationCompleted: completeBucketDeletionPresentation
    ) {
      try await deleteBucket()
    }
  }

  private var managedCard: some View {
    DashCard {
      Button {
        toggleManaged()
      } label: {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Public r2.dev URL")
              .dashTextStyle(.bodySemibold)
              .foregroundStyle(DashTheme.text)
            Text(managedSubtitle)
              .dashTextStyle(.footnote)
              .foregroundStyle(DashTheme.subtle)
              .lineLimit(2)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          DashSwitch(isOn: managed?.enabled ?? false)
            .opacity(togglingManaged ? 0.72 : 1)
        }
      }
      .buttonStyle(DashSurfaceButtonStyle())
      .disabled(!featureAllowsWrites || managed == nil || togglingManaged)
      .accessibilityLabel("Public r2.dev URL")
      .accessibilityValue(managed?.enabled == true ? "On" : "Off")
      .accessibilityAddTraits(.isToggle)
    }
  }

  private var managedSubtitle: String {
    guard let managed else { return "Managed URL unavailable for this bucket." }
    if managed.enabled {
      return "\(managed.domain) — rate-limited by Cloudflare; fine for testing, not production."
    }
    return "Serve this bucket at a Cloudflare-managed r2.dev URL."
  }

  @ViewBuilder
  private var customDomainsGroup: some View {
    DashListGroup(
      title: "Custom domains",
      actionTitle: featureAllowsWrites ? "Add" : nil,
      actionIcon: featureAllowsWrites ? SolarAsset.plus : nil,
      action: featureAllowsWrites ? { addsDomain = true } : nil
    ) {
      if custom.isEmpty {
        DashCard {
          Text(
            "Connect a domain from one of this account's zones to serve the bucket without r2.dev limits."
          )
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.subtle)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        dashListCard {
          dashListCardRows(items: custom) { domain in
            Button {
              deleteError = nil
              selectedDomain = domain
            } label: {
              DashListRow(
                title: domain.domain,
                subtitle: domain.statusLabel,
                icon: SolarAsset.Content.globe,
                iconColor: domain.isServing
                  ? FeatureVisualIdentity.catalogColor(for: .r2) : DashTheme.iconMuted,
                showsChevron: false
              )
            }
            .buttonStyle(DashSurfaceButtonStyle())
            .accessibilityLabel("\(domain.domain), \(domain.statusLabel)")
          }
        }
      }
    }
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.r2Domains(accountID: accountID, bucket: bucket)
    if !force, let cached: R2DomainsSnapshot = model.featureCache.get(key) {
      managed = cached.managed
      custom = cached.custom
      loading = false
      error = nil
      return
    }
    let client = model.client
    async let managedResult = Self.fetch {
      try await client.getR2ManagedDomain(accountID: accountID, bucket: bucket)
    }
    async let customResult = Self.fetch {
      try await client.listR2CustomDomains(accountID: accountID, bucket: bucket)
    }
    let (managedOutcome, customOutcome) = await (managedResult, customResult)
    switch managedOutcome {
    case .success(let domain): managed = domain
    case .failure: break
    }
    switch customOutcome {
    case .success(let domains):
      custom = domains
      error = nil
    case .failure(let failure):
      // The custom list is the screen's backbone; the managed row degrades on
      // its own. Surface the failure only when both sides came back empty.
      if managed == nil && custom.isEmpty {
        error = failure.dashActionableMessage
      }
    }
    if case .success = customOutcome {
      model.featureCache.set(key, R2DomainsSnapshot(managed: managed, custom: custom))
    }
    loading = false
  }

  private static func fetch<Value: Sendable>(_ operation: () async throws -> Value) async
    -> Result<Value, Error>
  {
    do { return .success(try await operation()) } catch { return .failure(error) }
  }

  private func toggleManaged() {
    guard let accountID = model.activeAccountID, let current = managed else { return }
    let previous = current
    let enabled = !current.enabled
    managed = R2ManagedDomain(
      bucketId: current.bucketId, domain: current.domain, enabled: enabled)
    togglingManaged = true
    Task {
      defer { togglingManaged = false }
      do {
        managed = try await model.client.setR2ManagedDomain(
          accountID: accountID, bucket: bucket, enabled: enabled)
        model.featureCache.set(
          FeatureCacheKey.r2Domains(accountID: accountID, bucket: bucket),
          R2DomainsSnapshot(managed: managed, custom: custom))
        DashDelight.celebrateSuccess()
      } catch {
        managed = previous
        model.toasts.error(error.dashActionableMessage)
      }
    }
  }

  private func remove(_ domain: R2CustomDomain) async {
    guard let accountID = model.activeAccountID else { return }
    deleteDomainPhase = .loading
    deleteError = nil
    do {
      try await model.client.deleteR2CustomDomain(
        accountID: accountID, bucket: bucket, domain: domain.domain)
      model.toasts.success(DashL10n.string("Deleted successfully."))
      await load(force: true)
      deleteDomainPhase = .succeeded
    } catch {
      deleteDomainPhase = .idle
      deleteError = error.dashActionableMessage
    }
  }

  private func completeDomainDeletionPresentation() {
    guard deleteDomainPhase == .succeeded else { return }
    selectedDomain = nil
    deleteDomainPhase = .idle
  }

  private func deleteBucket() async throws {
    guard let context = model.accountRequestContext else { throw CancellationError() }
    try await model.client.deleteR2Bucket(accountID: context.accountID, name: bucket)
    try Task.checkCancellation()
    guard model.isCurrentAccount(context) else { throw CancellationError() }
    model.featureCache.remove(FeatureCacheKey.r2Buckets(context.accountID))
    model.featureCache.remove(
      prefix: FeatureCacheKey.r2ObjectsPrefix(accountID: context.accountID, bucket: bucket))
    model.featureCache.remove(
      FeatureCacheKey.r2Domains(accountID: context.accountID, bucket: bucket))
  }

  private func completeBucketDeletionPresentation() {
    navigator?.path.removeAll { destination in
      switch destination {
      case .r2Bucket(let name, _), .r2BucketSettings(let name):
        name == bucket
      default:
        false
      }
    }
    model.toasts.success(DashL10n.string("Deleted successfully."))
  }
}

extension R2CustomDomain {
  fileprivate var isServing: Bool {
    enabled && status?.ownership == "active" && status?.ssl == "active"
  }

  /// Localized at the last render step, per the API-token convention: the raw
  /// Cloudflare words stay in `isServing`'s comparison, only the display copy
  /// goes through the catalog.
  fileprivate var statusLabel: String {
    guard enabled else { return DashL10n.string("Disabled") }
    guard let status else { return DashL10n.string("Provisioning") }
    if isServing { return DashL10n.string("Active") }
    let pending = [
      status.ownership.map { DashL10n.string("Ownership \(DashL10n.ui($0.capitalized))") },
      status.ssl.map { DashL10n.string("Certificate \(DashL10n.ui($0.capitalized))") },
    ].compactMap { $0 }
    return pending.isEmpty ? DashL10n.string("Pending") : pending.joined(separator: " · ")
  }

  fileprivate var detailFields: [DashDetailField] {
    [
      DashDetailField(label: "Domain", value: domain, mono: true),
      zoneName.map { DashDetailField(label: "Zone", value: $0) },
      DashDetailField(label: "Status", value: statusLabel),
      status?.ownership.map { DashDetailField(label: "Ownership", value: $0) },
      status?.ssl.map { DashDetailField(label: "Certificate", value: $0) },
      minTLS.map { DashDetailField(label: "Minimum TLS", value: $0) },
    ].compactMap { $0 }
  }
}

/// Attach-a-domain form: the user types a hostname and Dash infers the owning
/// zone by longest suffix match over the account's zones — the same rule
/// Cloudflare applies in its own dashboard.
private struct R2AddDomainForm: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let bucket: String
  var onAdded: () async -> Void
  @State private var hostname = ""
  @State private var zones: [CloudflareZone] = []
  @State private var zonesLoaded = false
  @State private var actionPhase: DashActionPhase = .idle
  @State private var error: String?

  private var normalizedHost: String {
    hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private var matchedZone: CloudflareZone? {
    let host = normalizedHost
    guard !host.isEmpty else { return nil }
    return
      zones
      .filter { host == $0.name || host.hasSuffix("." + $0.name) }
      .max { $0.name.count < $1.name.count }
  }

  var body: some View {
    DashFormSheet(
      saveTitle: "Add domain",
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completeSuccessPresentation,
      canSave: matchedZone != nil,
      onSave: { Task { await save() } },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          DashFormField(
            label: "Hostname",
            text: $hostname,
            keyboard: .URL,
            contentType: .URL)
          if let zone = matchedZone {
            Text("Will be attached through the \(zone.name) zone.")
              .dashTextStyle(.footnote)
              .foregroundStyle(DashTheme.subtle)
          } else if !normalizedHost.isEmpty, zonesLoaded {
            DashNotice(
              kind: .warning,
              message: "No zone in this account matches that hostname.")
          }
          if let error {
            DashNotice(kind: .error, message: error)
          }
          Text(
            "Cloudflare creates the DNS record and edge certificate automatically. The bucket serves on the domain once both are active."
          )
          .dashTextStyle(.caption)
          .foregroundStyle(DashTheme.subtle)
        }
      }
    )
    .task { await loadZones() }
  }

  private func loadZones() async {
    guard let accountID = model.activeAccountID else { return }
    if let cached: [CloudflareZone] = model.featureCache.get(FeatureCacheKey.zones(accountID)) {
      zones = cached
      zonesLoaded = true
      return
    }
    zones = (try? await model.client.listZones(accountID: accountID, perPage: 50).items) ?? []
    zonesLoaded = true
  }

  private func save() async {
    guard let accountID = model.activeAccountID, let zone = matchedZone else { return }
    actionPhase = .loading
    error = nil
    do {
      try await model.client.addR2CustomDomain(
        accountID: accountID, bucket: bucket, domain: normalizedHost, zoneID: zone.id)
      model.toasts.success(DashL10n.string("Added successfully."))
      await onAdded()
      actionPhase = .succeeded
    } catch {
      actionPhase = .idle
      self.error = error.dashActionableMessage
    }
  }

  private func completeSuccessPresentation() {
    guard actionPhase == .succeeded else { return }
    dismiss()
  }
}
