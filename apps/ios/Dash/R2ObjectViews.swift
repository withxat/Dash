import CloudflareAPI
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Media detection

/// What Dash is willing to fetch and decode from a bucket, and how large a
/// body a phone-side object copy may buffer.
enum R2Media {
  /// `putR2Object` holds the body in memory and URLSession copies it again, so
  /// the ceiling here is the phone's, not Cloudflare's — a single-part PUT is
  /// good for ~5 GiB, but iOS jetsams the app long before that. Shared by
  /// upload, rename, and move, which all buffer one object at a time.
  static let transferSizeLimit = 100 * 1024 * 1024

  /// Row thumbnails skip anything above this — a grid of multi-megabyte
  /// downloads per scroll would swamp cell data for a 40pt square.
  static let thumbnailByteLimit = 8 * 1024 * 1024

  /// UIImage-decodable formats only — SVG stays a generic file row.
  private static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff",
  ]

  static func isImage(_ object: R2Object) -> Bool {
    if let type = object.contentType?.lowercased() {
      return type.hasPrefix("image/") && !type.contains("svg")
    }
    return isImageKey(object.key)
  }

  static func isImageKey(_ key: String) -> Bool {
    guard let name = key.split(separator: "/").last,
      let ext = name.split(separator: ".").last, ext.count < name.count
    else { return false }
    return imageExtensions.contains(ext.lowercased())
  }

  static func mimeType(forKey key: String) -> String? {
    let ext = key.split(separator: "/").last?.split(separator: ".").last.map(String.init)
    return ext.flatMap { UTType(filenameExtension: $0)?.preferredMIMEType }
  }
}

// MARK: - Thumbnail store

/// Session-scoped thumbnail cache for R2 rows. Downloads are deduped per
/// object, capped in width, and decoded off the main actor via ImageIO
/// downsampling so a bucket of camera originals never inflates to
/// full-resolution bitmaps.
actor R2ThumbnailStore {
  private let cache = NSCache<NSString, UIImage>()
  private var inFlight: [String: Task<UIImage?, Never>] = [:]
  private var availableSlots = 4
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init() {
    cache.countLimit = 300
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
    for task in inFlight.values { task.cancel() }
    inFlight.removeAll()
  }

  private func image(
    kind: String, maxBytes: Int, maxPixel: CGFloat,
    client: CloudflareClient, accountID: String, bucket: String, object: R2Object
  ) async -> UIImage? {
    guard R2Media.isImage(object), let size = object.size, size <= maxBytes else { return nil }
    let key = "\(kind)|\(accountID)|\(bucket)|\(object.key)|\(object.etag ?? "")"
    if let hit = cache.object(forKey: key as NSString) { return hit }
    if let existing = inFlight[key] {
      // Join the in-flight download; leaving the row cancels only this wait.
      return await existing.value
    }
    let task = Task<UIImage?, Never> {
      await self.fetch(
        cacheKey: key, maxPixel: maxPixel,
        client: client, accountID: accountID, bucket: bucket, objectKey: object.key)
    }
    inFlight[key] = task
    return await withTaskCancellationHandler {
      let result = await task.value
      self.finishInFlight(key, task: task)
      return result
    } onCancel: {
      // Row disappeared: abort the download and free its concurrency slot
      // so the next screen is not stuck behind four orphaned GETs.
      task.cancel()
      Task { await self.finishInFlight(key, task: task) }
    }
  }

  private func finishInFlight(_ key: String, task: Task<UIImage?, Never>) {
    if inFlight[key] == task { inFlight[key] = nil }
  }

  private func fetch(
    cacheKey: String, maxPixel: CGFloat,
    client: CloudflareClient, accountID: String, bucket: String, objectKey: String
  ) async -> UIImage? {
    await acquireSlot()
    defer { releaseSlot() }
    guard !Task.isCancelled else { return nil }
    guard
      let data = try? await client.getR2Object(accountID: accountID, bucket: bucket, key: objectKey)
    else { return nil }
    guard !Task.isCancelled else { return nil }
    guard let image = Self.downsample(data, maxPixel: maxPixel) else { return nil }
    cache.setObject(image, forKey: cacheKey as NSString)
    return image
  }

  private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
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

  private func acquireSlot() async {
    if availableSlots > 0 {
      availableSlots -= 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func releaseSlot() {
    if waiters.isEmpty {
      availableSlots += 1
    } else {
      waiters.removeFirst().resume()
    }
  }
}

// MARK: - Browser row

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
  @State private var thumbnailEtag: String?

  var body: some View {
    Button(action: action) {
      DashListRow(
        title: title,
        subtitle: object.size.map {
          ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        },
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
    .task(id: object.etag) {
      // Refetch when the object was overwritten (etag changed), not just on
      // first appearance.
      guard thumbnail == nil || thumbnailEtag != object.etag,
        let accountID = model.activeAccountID
      else { return }
      thumbnail = await model.r2Thumbnails.rowThumbnail(
        client: model.client, accountID: accountID, bucket: bucket, object: object)
      thumbnailEtag = object.etag
    }
  }

  private var objectAccessibilityLabel: String {
    var parts = [title]
    if let size = object.size {
      parts.append(
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
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
  @State private var deletingDomain = false
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
      icon: .solar(SolarAsset.settings),
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
          isDeleting: deletingDomain,
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
      )
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
    deletingDomain = true
    defer { deletingDomain = false }
    do {
      try await model.client.deleteR2CustomDomain(
        accountID: accountID, bucket: bucket, domain: domain.domain)
      selectedDomain = nil
      model.toasts.success(DashL10n.string("Deleted successfully."))
      await load(force: true)
    } catch {
      deleteError = error.dashActionableMessage
    }
  }

  private func deleteBucket() async throws {
    guard let accountID = model.activeAccountID else { return }
    try await model.client.deleteR2Bucket(accountID: accountID, name: bucket)
    model.featureCache.remove(FeatureCacheKey.r2Buckets(accountID))
    model.featureCache.remove(
      prefix: FeatureCacheKey.r2ObjectsPrefix(accountID: accountID, bucket: bucket))
    model.featureCache.remove(FeatureCacheKey.r2Domains(accountID: accountID, bucket: bucket))
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

  fileprivate var statusLabel: String {
    guard enabled else { return "Disabled" }
    guard let status else { return "Provisioning" }
    if isServing { return "Active" }
    let pending = [
      status.ownership.map { "ownership \($0)" },
      status.ssl.map { "certificate \($0)" },
    ].compactMap { $0 }
    return pending.isEmpty ? "Pending" : pending.joined(separator: " · ")
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
  @State private var saving = false
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
      isSaving: saving,
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
    saving = true
    defer { saving = false }
    do {
      try await model.client.addR2CustomDomain(
        accountID: accountID, bucket: bucket, domain: normalizedHost, zoneID: zone.id)
      model.toasts.success(DashL10n.string("Added successfully."))
      await onAdded()
      dismiss()
    } catch {
      self.error = error.dashActionableMessage
    }
  }
}
