import CloudflareAPI
import GradientAvatars
import SwiftDitherKit
import SwiftUI
import UIKit

/// Captures the managed-record Tray row before the Tray leaves, then commits
/// the page route only after its exit choreography has completed.
private struct DNSLockedRecordEmailRoutingButton: View {
  @Environment(\.dashTrayDismissAfter) private var dismissAfter
  let zoneID: String

  var body: some View {
    DashNavigationSource(
      destination: .zoneEmailRouting(zoneID),
      schedule: dismissAfter
    ) { navigate in
      Button(action: navigate) {
        DashListRow(
          title: DashL10n.string("Open email routing"),
          icon: SolarAsset.Content.mailbox)
      }
      .buttonStyle(DashSurfaceButtonStyle())
    }
  }
}

struct DNSRecordsView: View {
  static let pageSize = 100

  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let zoneID: String
  @State private var records: [DNSRecord] = []
  @State private var selected: DNSRecord?
  /// Email Routing's apex MX / SPF records are locked by Cloudflare. See
  /// `EmailRoutingDNSGuard`: the Managed badge is decoration and vanishes
  /// silently on a failed plan fetch, while the edit gate remains independent
  /// of that plan.
  @State private var emailRoutingGuard = EmailRoutingDNSGuard()
  @State private var lockedRecord: DNSRecord?
  @State private var createsRecord = false
  @State private var loading = true
  @State private var isLoadingMore = false
  @State private var reloading = false
  @State private var activeRequestID: UUID?
  @State private var pageState = DashPageState()
  @State private var error: String?
  @State private var selectedSliceID: String?

  private var deferredDeletionRefreshGeneration: UInt64 {
    guard let accountID = model.activeAccountID else { return 0 }
    return model.deferredDeletions.refreshGeneration(
      for: DeferredDeletionScope(accountID: accountID, zoneID: zoneID))
  }

  var body: some View {
    let displayedRecords = displayRecords
    let buckets = DNSChartModel.buckets(displayedRecords)
    let selectedBucket = DNSChartModel.bucket(in: buckets, withID: selectedSliceID)
    let visibleRecords = visibleRecords(in: displayedRecords, buckets: buckets)
    let slices = recordTypeSlices(for: buckets)

    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !displayedRecords.isEmpty,
      empty: DashFeatureEmpty(
        icon: SolarAsset.Content.globus,
        title: "No DNS records",
        message: "Create a record with the add button."
      ),
      retry: { Task { await load(force: true) } }
    ) { mode in
      if mode.isPlaceholder {
        DashChartPanelPlaceholder(showsLegend: true)
          .padding(.bottom, DashTheme.Spacing.itemGap)
          .dashBodySlot(reduceMotion: reduceMotion)
      } else {
        recordTypesCard(
          buckets: buckets,
          slices: slices,
          selectedBucket: selectedBucket,
          displayedRecordCount: displayedRecords.count
        )
        // Bottom padding on the card, not top padding on the rows: the rows
        // are a bare lazy `ForEach` and must stay untouched (StorageViews
        // precedent).
        .padding(.bottom, DashTheme.Spacing.itemGap)
        .dashBodySlot(reduceMotion: reduceMotion)
      }
      dashListCard {
        dashModeListRows(
          mode: mode, items: visibleRecords, reduceMotion: reduceMotion
        ) { record in
          Button {
            if emailRoutingGuard.isLocked(record) {
              lockedRecord = record
            } else {
              selected = record
            }
          } label: {
            DashListRow(
              title: record.name,
              subtitle: dnsRecordSubtitle(record),
              icon: record.proxied == true
                ? SolarAsset.Content.cloud : SolarAsset.Content.globus,
              // Proxied keeps the orange cloud; unproxied inherits the
              // zones catalog green.
              iconColor: record.proxied == true ? DashTheme.accent : nil
            ) {
              if emailRoutingGuard.isManaged(record) { StatusBadge(.managed) }
            }
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityIdentifier("dns-record-\(record.id)")
          .transition(morphTransition)
        }
      }
      if !mode.isPlaceholder, pageState.canLoadMore || isLoadingMore {
        DashInfiniteScrollFooter(
          loaded: displayedRecords.count,
          isLoading: isLoadingMore
        ) {
          guard error == nil else { return }
          Task { await loadMore() }
        }
      }
    }
    .refreshable { await load(force: true) }
    .detailHeader(icon: .solar(SolarAsset.Content.globus), title: "DNS")
    .dashPageActions(
      trailing: featureAllowsWrites
        ? [
          .icon(
            id: "dns-create-record",
            asset: SolarAsset.plus,
            accessibilityLabel: DashL10n.string("New DNS record")
          ) {
            createsRecord = true
          }
        ]
        : []
    )
    .dashTray(
      item: $selected,
      title: { _ in "DNS record" },
      tone: FeatureVisualIdentity.tone(for: .zones),
      content: { record in
        DNSRecordEditor(zoneID: zoneID, record: record) {
          model.featureCache.remove(FeatureCacheKey.dnsRecords(zoneID))
          Task { await load(force: true) }
        }
      }
    )
    .dashTray(
      item: $lockedRecord,
      title: { _ in "DNS record" },
      tone: FeatureVisualIdentity.tone(for: .zones),
      content: { record in
        DashDetailTray(
          fields: [
            DashDetailField(label: "Type", value: record.type),
            DashDetailField(label: "Name", value: record.name, mono: true),
            DashDetailField(label: "Content", value: record.content, mono: true),
          ]
        ) {
          VStack(alignment: .leading, spacing: 12) {
            DashNotice(
              kind: .info,
              message:
                "Email routing manages this record. Editing or deleting it would stop mail delivery for this domain."
            )
            DNSLockedRecordEmailRoutingButton(zoneID: zoneID)
          }
        }
      }
    )
    .dashTray(
      isPresented: $createsRecord, title: "New DNS record",
      tone: FeatureVisualIdentity.tone(for: .zones)
    ) {
      DNSRecordEditor(zoneID: zoneID, record: nil) {
        model.featureCache.remove(FeatureCacheKey.dnsRecords(zoneID))
        Task { await load(force: true) }
      }
    }
    .task(id: model.accountRequestContext) {
      // A failed lookup restores the pre-Email-Routing behavior: no badge and
      // an editable row. The gate becomes a positive claim only after settings
      // say routing is enabled.
      emailRoutingGuard = EmailRoutingDNSGuard()
      guard let context = model.accountRequestContext else { return }
      let key = FeatureCacheKey.emailRouting(zoneID)
      var settings: EmailRoutingSettings? =
        (model.featureCache.get(key) as EmailRoutingSnapshot?)?.settings
      if settings == nil {
        settings = try? await model.client.getEmailRoutingSettings(zoneID: zoneID)
      }
      guard model.isCurrentAccount(context), !Task.isCancelled, let settings, settings.enabled
      else { return }
      var next = EmailRoutingDNSGuard(
        isEnabled: true, apex: settings.name.lowercased(), plan: nil)
      // The edit gate needs only the positive settings answer. Arm it before
      // the decorative plan lookup so a slow or failed plan cannot briefly
      // reopen Cloudflare-managed records for editing.
      emailRoutingGuard = next
      let planKey = FeatureCacheKey.emailRoutingDNS(zoneID)
      if let cached: EmailRoutingDNSPlan = model.featureCache.get(planKey) {
        next.plan = cached
      } else if let fetched = try? await model.client.getEmailRoutingDNSPlan(zoneID: zoneID) {
        guard model.isCurrentAccount(context), !Task.isCancelled else { return }
        model.featureCache.set(planKey, fetched)
        next.plan = fetched
      }
      guard model.isCurrentAccount(context), !Task.isCancelled else { return }
      emailRoutingGuard = next
    }
    .task(id: deferredDeletionRefreshGeneration) {
      // The first mounted DNS view that wins this forced load writes the
      // shared cache. Acknowledging the generation back to zero then reruns
      // every other mounted instance against that same snapshot, so none can
      // retain a pre-deletion local row.
      let generation = deferredDeletionRefreshGeneration
      let accountID = model.activeAccountID
      let loaded = await load(force: generation > 0)
      if loaded, generation > 0, let accountID {
        model.deferredDeletions.acknowledgeRefresh(
          for: DeferredDeletionScope(accountID: accountID, zoneID: zoneID),
          generation: generation)
      }
    }
  }

  private func recordTypesCard(
    buckets: [DNSChartModel.Bucket],
    slices: [DitherSlice],
    selectedBucket: DNSChartModel.Bucket?,
    displayedRecordCount: Int
  ) -> some View {
    // Chart cards stay on the glass surface, not the info-group band — see the
    // surface split on `DashGlassCard`. No detail chevron: the donut is a filter
    // control for the records below, and its legend already names every slice,
    // so a pushed copy would only restate what the card shows.
    DashGlassCard {
      VStack(alignment: .leading, spacing: 12) {
        Text("Record types")
          .dashTextStyle(.footnoteSemibold)
          .foregroundStyle(DashTheme.subtle)
          .frame(maxWidth: .infinity, alignment: .leading)
        DashPieChart(
          slices: slices,
          innerRadiusRatio: 0.62,
          options: DashTheme.DitherChart.polarOptions(
            accessibility: DitherAccessibility(
              title: DashL10n.ui("DNS record types"),
              summary: DNSChartModel.chartAccessibilitySummary(buckets: buckets),
              categoryAxisLabel: DashL10n.ui("Record type"),
              valueAxisLabel: DashL10n.ui("Records"))),
          // Slice and legend taps land here, so the write is what morphs the
          // rows below: an animated binding puts the whole update — donut
          // highlight, filter strip, and the list diff — in one transaction.
          selection: $selectedSliceID.animation(DashTheme.Motion.morph)
        )
        .frame(
          height: DashTheme.DitherChart.height(
            dynamicTypeSize: dynamicTypeSize,
            showsLegend: true))
        // Under the legend, not beside the card title: engaging a filter grows
        // the card downward, so the donut the user just tapped stays put and
        // only the list below — which is re-flowing anyway — moves.
        filterStrip(
          bucket: selectedBucket,
          slices: slices,
          displayedRecordCount: displayedRecordCount)
      }
    }
  }

  @ViewBuilder
  private func filterStrip(
    bucket: DNSChartModel.Bucket?,
    slices: [DitherSlice],
    displayedRecordCount: Int
  ) -> some View {
    if let bucket {
      DashChartFilterStrip(
        label: DNSChartModel.label(for: bucket),
        countText: DashL10n.string(
          "\(bucket.count.formatted()) of \(displayedRecordCount.formatted()) records"),
        color: sliceColor(forBucketID: bucket.id, in: slices),
        clearAccessibilityLabel: DashL10n.string("Show all record types"),
        clearAccessibilityIdentifier: "dns-type-filter-clear"
      ) {
        withAnimation(DashTheme.Motion.morph) { selectedSliceID = nil }
      }
      .transition(morphTransition)
    }
  }

  /// Rows the donut selection leaves standing. Nothing is selected on a cold
  /// screen, so the common path is the full list. `DitherPieChart` clears a
  /// selection that stops naming a slice, which is why Load more can widen the
  /// data without the view resetting the filter itself.
  private var displayRecords: [DNSRecord] {
    guard let accountID = model.activeAccountID else { return records }
    return records.filter { record in
      !model.deferredDeletions.isPendingDeletion(
        DeferredDeletionResourceKey(
          kind: .dnsRecord,
          accountID: accountID,
          zoneID: zoneID,
          resourceID: record.id))
    }
  }

  private func visibleRecords(
    in displayedRecords: [DNSRecord],
    buckets: [DNSChartModel.Bucket]
  ) -> [DNSRecord] {
    DNSChartModel.records(displayedRecords, in: selectedSliceID, buckets: buckets)
  }

  /// Filtered-out rows dissolve with the same blur the tray morph uses, so the
  /// list reads as collapsing rather than blinking; survivors glide into their
  /// new slots on the shared transaction. Only onscreen rows are realized in
  /// the lazy stack, so the morph costs the same on a 2,000-record zone.
  private var morphTransition: AnyTransition {
    reduceMotion ? .opacity : .dashMorph
  }

  /// Named buckets take the categorical palette positionally; the folded
  /// Other bucket always renders neutral grey.
  private func recordTypeSlices(for buckets: [DNSChartModel.Bucket]) -> [DitherSlice] {
    let palette = [
      DashTheme.DitherChart.brand(colorScheme: colorScheme, contrast: colorSchemeContrast),
      DashTheme.DitherChart.positive(colorScheme: colorScheme, contrast: colorSchemeContrast),
      DashTheme.DitherChart.accentPurple(colorScheme: colorScheme, contrast: colorSchemeContrast),
      DashTheme.DitherChart.warning(colorScheme: colorScheme, contrast: colorSchemeContrast),
      DashTheme.DitherChart.accentTeal(colorScheme: colorScheme, contrast: colorSchemeContrast),
    ]
    var nextColor = 0
    return buckets.map { bucket in
      let color: DitherColor
      if bucket.id == DNSChartModel.otherBucketID {
        color = DashTheme.DitherChart.neutral(
          colorScheme: colorScheme, contrast: colorSchemeContrast)
      } else {
        color = palette[nextColor % palette.count]
        nextColor += 1
      }
      return DitherSlice(
        id: bucket.id,
        label: DNSChartModel.label(for: bucket),
        value: Double(bucket.count),
        color: color)
    }
  }

  /// The filter strip borrows its dot from the slice it stands for, so the
  /// palette stays assigned in exactly one place.
  private func sliceColor(forBucketID id: String, in slices: [DitherSlice]) -> DitherColor {
    slices.first { $0.id == id }?.color
      ?? DashTheme.DitherChart.neutral(colorScheme: colorScheme, contrast: colorSchemeContrast)
  }

  @discardableResult
  private func load(force: Bool = false) async -> Bool {
    let requestID = UUID()
    activeRequestID = requestID
    reloading = true
    isLoadingMore = false
    defer {
      if activeRequestID == requestID {
        reloading = false
        loading = false
      }
    }
    let key = FeatureCacheKey.dnsRecords(zoneID)
    if !force, let cached: [DNSRecord] = model.featureCache.get(key) {
      records = cached
      pageState.rehydrate(loaded: cached.count, pageSize: Self.pageSize)
      error = nil
      return true
    }
    let requestScope = model.activeAccountID.map {
      DeferredDeletionScope(accountID: $0, zoneID: zoneID)
    }
    let globalRequestGeneration = requestScope.map {
      model.deferredDeletions.beginDNSLoad(for: $0)
    }
    if records.isEmpty { loading = true }
    error = nil
    do {
      pageState.reset()
      let pageNumber = pageState.nextPage
      let page = try await model.client.listDNSRecords(
        zoneID: zoneID, page: pageNumber, perPage: Self.pageSize)
      guard
        activeRequestID == requestID,
        acceptsDNSResponse(
          scope: requestScope,
          generation: globalRequestGeneration)
      else { return false }
      records = page.items
      pageState.absorb(
        info: page.resultInfo,
        requestedPage: pageNumber,
        received: page.items.count,
        added: page.items.count,
        loaded: records.count,
        pageSize: Self.pageSize)
      reconcileDeferredDeletions(loadGeneration: globalRequestGeneration)
      model.featureCache.set(key, records)
      return true
    } catch {
      guard
        activeRequestID == requestID,
        acceptsDNSResponse(
          scope: requestScope,
          generation: globalRequestGeneration)
      else { return false }
      if error.dashIsCancellation { return false }
      self.error = error.dashActionableMessage
      return false
    }
  }

  private func loadMore() async {
    guard !isLoadingMore, !reloading, pageState.canLoadMore else { return }
    let requestID = UUID()
    activeRequestID = requestID
    let pageNumber = pageState.nextPage
    isLoadingMore = true
    let requestScope = model.activeAccountID.map {
      DeferredDeletionScope(accountID: $0, zoneID: zoneID)
    }
    let globalRequestGeneration = requestScope.map {
      model.deferredDeletions.beginDNSLoad(for: $0)
    }
    defer {
      if activeRequestID == requestID {
        isLoadingMore = false
      }
    }
    do {
      let page = try await model.client.listDNSRecords(
        zoneID: zoneID, page: pageNumber, perPage: Self.pageSize)
      guard
        activeRequestID == requestID,
        acceptsDNSResponse(
          scope: requestScope,
          generation: globalRequestGeneration)
      else { return }
      var existingIDs = Set(records.map(\.id))
      let uniqueItems = page.items.filter { existingIDs.insert($0.id).inserted }
      records += uniqueItems
      pageState.absorb(
        info: page.resultInfo,
        requestedPage: pageNumber,
        received: page.items.count,
        added: uniqueItems.count,
        loaded: records.count,
        pageSize: Self.pageSize)
      reconcileDeferredDeletions(loadGeneration: globalRequestGeneration)
      model.featureCache.set(FeatureCacheKey.dnsRecords(zoneID), records)
      error = nil
    } catch {
      guard
        activeRequestID == requestID,
        acceptsDNSResponse(
          scope: requestScope,
          generation: globalRequestGeneration)
      else { return }
      if error.dashIsCancellation { return }
      self.error = error.dashActionableMessage
    }
  }

  private func reconcileDeferredDeletions(loadGeneration: UInt64?) {
    guard let accountID = model.activeAccountID else { return }
    model.deferredDeletions.reconcileDNSRecords(
      accountID: accountID,
      zoneID: zoneID,
      serverRecordIDs: Set(records.map(\.id)),
      isCompleteSnapshot: !pageState.canLoadMore,
      loadGeneration: loadGeneration)
  }

  private func acceptsDNSResponse(
    scope: DeferredDeletionScope?,
    generation: UInt64?
  ) -> Bool {
    guard let scope, let generation else { return true }
    return model.activeAccountID == scope.accountID
      && model.deferredDeletions.isCurrentDNSLoad(
        for: scope,
        generation: generation)
  }
}

/// Pure conversion for the DNS record-type distribution donut, so bucketing
/// and accessibility strings are unit-tested away from the view. Counts cover
/// loaded pages only — the records list paginates.
enum DNSChartModel {
  /// The donut legend stays readable with at most five named types; every
  /// remaining type folds into one neutral Other slice.
  static let namedTypeLimit = 5
  /// Lowercase on purpose: record-type bucket ids are uppercased, so the
  /// Other bucket can never collide with a real type.
  static let otherBucketID = "other"

  struct Bucket: Hashable, Identifiable {
    /// Uppercased record type, or ``otherBucketID`` for the folded remainder.
    let id: String
    let count: Int
  }

  /// Buckets ordered by count descending; ties break alphabetically by type
  /// so the layout is deterministic across reloads. Other, when present, is
  /// always last.
  static func buckets(_ records: [DNSRecord]) -> [Bucket] {
    var counts: [String: Int] = [:]
    for record in records {
      counts[record.type.uppercased(), default: 0] += 1
    }
    let ordered = counts.sorted {
      $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
    }
    var buckets = ordered.prefix(namedTypeLimit).map { Bucket(id: $0.key, count: $0.value) }
    let otherCount = ordered.dropFirst(namedTypeLimit).reduce(0) { $0 + $1.value }
    if otherCount > 0 {
      buckets.append(Bucket(id: otherBucketID, count: otherCount))
    }
    return buckets
  }

  /// Raw record types are protocol names (A, CNAME, …) and stay verbatim;
  /// only the folded bucket label localizes.
  static func label(for bucket: Bucket) -> String {
    bucket.id == otherBucketID ? DashL10n.string("Other") : bucket.id
  }

  /// The bucket a donut selection names, or `nil` when nothing is selected.
  /// A selection can outlive the data it was made against (Load more can fold
  /// a named type into Other), so callers resolve against the current buckets
  /// instead of trusting the stored id.
  static func bucket(_ records: [DNSRecord], withID bucketID: String?) -> Bucket? {
    bucket(in: buckets(records), withID: bucketID)
  }

  static func bucket(in buckets: [Bucket], withID bucketID: String?) -> Bucket? {
    guard let bucketID else { return nil }
    return buckets.first { $0.id == bucketID }
  }

  /// Loaded records belonging to one donut bucket — the list-side half of
  /// slice selection. A `nil` id, or one no bucket claims, filters nothing, so
  /// a stale selection degrades to the full list rather than an empty one.
  static func records(_ records: [DNSRecord], in bucketID: String?) -> [DNSRecord] {
    Self.records(records, in: bucketID, buckets: buckets(records))
  }

  static func records(
    _ records: [DNSRecord],
    in bucketID: String?,
    buckets: [Bucket]
  ) -> [DNSRecord] {
    guard let bucketID else { return records }
    guard buckets.contains(where: { $0.id == bucketID }) else { return records }
    guard bucketID == otherBucketID else {
      return records.filter { $0.type.uppercased() == bucketID }
    }
    // Other holds the remainder by construction: whatever the named slices
    // did not claim.
    let named = Set(buckets.map(\.id)).subtracting([otherBucketID])
    return records.filter { !named.contains($0.type.uppercased()) }
  }

  /// Describes the LOADED records only — the list paginates, so counts do not
  /// cover pages that have not been fetched yet.
  static func chartAccessibilitySummary(buckets: [Bucket]) -> String {
    let total = buckets.reduce(0) { $0 + $1.count }
    guard total > 0 else {
      return DashL10n.string("Record types chart. No DNS records loaded.")
    }
    let parts = buckets.map { bucket in
      "\(label(for: bucket)) \(bucket.count.formatted())"
    }
    let list = parts.formatted(
      .list(type: .and, width: .standard).locale(DashL10n.activeLocale))
    return DashL10n.string(
      "Record types chart. \(total.formatted()) loaded records: \(list)."
    )
  }
}

private func dnsRecordSubtitle(_ record: DNSRecord) -> String {
  if record.type == "MX", let priority = record.priority {
    return "MX  ·  \(priority)  ·  \(record.content)"
  }
  if record.type == "SRV" {
    let priority = record.data?.priority ?? record.priority
    let weight = record.data?.weight
    let port = record.data?.port
    let target = record.data?.target ?? record.content
    var parts = ["SRV"]
    if let priority { parts.append("\(priority)") }
    if let weight { parts.append("\(weight)") }
    if let port { parts.append(":\(port)") }
    parts.append(target)
    return parts.joined(separator: "  ·  ")
  }
  return "\(record.type)  ·  \(record.content)"
}

struct DNSRecordEditor: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let zoneID: String
  let record: DNSRecord?
  let saved: () -> Void
  @State private var type: String
  @State private var name: String
  @State private var content: String
  @State private var priorityText: String
  @State private var weightText: String
  @State private var portText: String
  @State private var target: String
  @State private var caaFlagsText: String
  @State private var caaTag: String
  @State private var caaValue: String
  @State private var proxied: Bool
  @State private var ttl: Int
  @State private var error: String?
  @State private var savePhase: DashActionPhase = .idle

  private var requiredWriteScopes: Set<String> {
    writeScopes(for: .dns(zoneID))
  }

  private var allowsWrites: Bool {
    model.hasScopes(requiredWriteScopes)
  }

  private var isSRV: Bool { type == "SRV" }
  private var isMX: Bool { type == "MX" }
  private var isCAA: Bool { type == "CAA" }
  private var supportsProxy: Bool { ["A", "AAAA", "CNAME"].contains(type) }

  private var canSave: Bool {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    if isSRV {
      return Int(priorityText) != nil
        && Int(weightText) != nil
        && Int(portText) != nil
        && !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if isMX {
      return Int(priorityText) != nil
        && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if isCAA {
      return Int(caaFlagsText).map { (0...255).contains($0) } == true
        && !caaValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  init(zoneID: String, record: DNSRecord?, saved: @escaping () -> Void) {
    self.zoneID = zoneID
    self.record = record
    self.saved = saved
    let initialType = record?.type ?? "A"
    _type = State(initialValue: initialType)
    _name = State(initialValue: record?.name ?? "")
    _content = State(initialValue: record?.content ?? "")
    _priorityText = State(
      initialValue: record.flatMap { $0.data?.priority ?? $0.priority }.map(String.init) ?? "10")
    _weightText = State(initialValue: record?.data?.weight.map(String.init) ?? "0")
    _portText = State(initialValue: record?.data?.port.map(String.init) ?? "")
    _target = State(initialValue: record?.data?.target ?? "")
    _caaFlagsText = State(initialValue: record?.data?.flags.map(String.init) ?? "0")
    _caaTag = State(initialValue: record?.data?.tag ?? "issue")
    _caaValue = State(initialValue: record?.data?.value ?? "")
    _proxied = State(initialValue: record?.proxied ?? false)
    _ttl = State(initialValue: record?.ttl ?? 1)
  }

  var body: some View {
    DashFormSheet(
      saveTitle: allowsWrites
        ? "Save" : (model.isDemoSession ? "Connect your account" : "Grant access"),
      actionPhase: savePhase,
      onSuccessPresentationCompleted: completeSavePresentation,
      canSave: allowsWrites ? canSave : true,
      deleteMessage: allowsWrites
        ? record.map {
          DashL10n.string("Permanently delete the \($0.type) record for \($0.name).")
        } : nil,
      deleteError: error,
      onDelete: allowsWrites ? record.map { rec in { delete(rec) } } : nil,
      deletionPresentation: .deferToGlobalUndo,
      onSave: {
        if allowsWrites {
          Task { await save() }
        } else {
          model.requestAccess(to: requiredWriteScopes)
        }
      },
      content: {
        VStack(spacing: 14) {
          if !allowsWrites {
            DashNotice(
              kind: .warning,
              message:
                model.isDemoSession
                ? "Connect your account when you are ready to make changes"
                : "Dash requests all permissions used by its current features in one authorization."
            )
          }

          Group {
            DashFormMenuField(
              label: "Type", selection: $type,
              options: ["A", "AAAA", "CNAME", "TXT", "MX", "NS", "SRV", "CAA", "PTR"])

            DashFormField(label: "Name", text: $name)

            if isSRV {
              DashFormField(label: "Priority", text: $priorityText, keyboard: .numberPad)
              DashFormField(label: "Weight", text: $weightText, keyboard: .numberPad)
              DashFormField(label: "Port", text: $portText, keyboard: .numberPad)
              DashFormField(label: "Target", text: $target)
            } else if isCAA {
              DashFormField(label: "Flags", text: $caaFlagsText, keyboard: .numberPad)
              DashFormMenuField(label: "Tag", selection: $caaTag, options: caaTagOptions)
              DashFormField(label: "Value", text: $caaValue)
            } else {
              if isMX {
                DashFormField(label: "Priority", text: $priorityText, keyboard: .numberPad)
              }
              DashFormField(
                label: isMX ? "Mail server" : "Content",
                text: $content)
            }

            if supportsProxy {
              // Unproxying publishes the origin IP, and putting the record back
              // behind the proxy does not unpublish it — scanners keep the answer.
              DashToggleRow(
                title: "Proxied",
                subtitle: proxied ? nil : "Exposes the origin IP, permanently",
                isOn: $proxied)
            }

            DashFormMenuField(
              label: "TTL", selection: ttlSelection, options: ttlOptions.map(\.label))
          }
          .disabled(!allowsWrites)

          if let error {
            DashNotice(kind: .error, message: error)
          }
        }
      }
    )
  }

  /// The RFC 8659 tags, plus whatever the record already carries so an edit
  /// of an extension tag (contactemail, …) round-trips instead of rewriting it.
  private var caaTagOptions: [String] {
    var options = ["issue", "issuewild", "iodef"]
    if let existing = record?.data?.tag, !options.contains(existing) {
      options.append(existing)
    }
    return options
  }

  /// The TTLs worth offering, plus whatever the record already has. Cloudflare
  /// pins proxied records to 300s and ignores the field, so this only matters
  /// for DNS-only records — the TXT verification, the MX, the unproxied CNAME.
  /// A record set elsewhere to a value not on this list keeps it rather than
  /// being silently rewritten to Auto on the next save.
  private var ttlOptions: [(label: String, seconds: Int)] {
    var options: [(label: String, seconds: Int)] = [
      ("Auto", 1), ("1 min", 60), ("5 min", 300), ("30 min", 1800),
      ("1 hour", 3600), ("12 hours", 43200), ("1 day", 86400),
    ]
    if !options.contains(where: { $0.seconds == ttl }) {
      options.append((DashL10n.string("\(ttl)s"), ttl))
      options.sort { $0.seconds < $1.seconds }
    }
    return options
  }

  private var ttlSelection: Binding<String> {
    Binding(
      get: { ttlOptions.first { $0.seconds == ttl }?.label ?? "Auto" },
      set: { label in ttl = ttlOptions.first { $0.label == label }?.seconds ?? ttl }
    )
  }

  private func save() async {
    guard allowsWrites else {
      model.requestAccess(to: requiredWriteScopes)
      return
    }
    error = nil
    let input: DNSRecordInput
    if isSRV {
      guard let priority = Int(priorityText), let weight = Int(weightText),
        let port = Int(portText)
      else {
        error = DashL10n.string("Priority, weight, and port must be numbers.")
        return
      }
      input = DNSRecordInput(
        type: type, name: name, proxied: false, ttl: ttl, priority: priority,
        data: DNSRecordData(
          priority: priority, weight: weight, port: port,
          target: target.trimmingCharacters(in: .whitespacesAndNewlines)))
    } else if isMX {
      guard let priority = Int(priorityText) else {
        error = DashL10n.string("Priority must be a number.")
        return
      }
      input = DNSRecordInput(
        type: type, name: name, content: content, proxied: false, ttl: ttl, priority: priority)
    } else if isCAA {
      guard let flags = Int(caaFlagsText), (0...255).contains(flags) else {
        error = DashL10n.string("Flags must be a number between 0 and 255.")
        return
      }
      input = DNSRecordInput(
        type: type, name: name, proxied: false, ttl: ttl,
        data: DNSRecordData(
          flags: flags, tag: caaTag,
          value: caaValue.trimmingCharacters(in: .whitespacesAndNewlines)))
    } else {
      input = DNSRecordInput(
        type: type, name: name, content: content,
        proxied: supportsProxy ? proxied : false, ttl: ttl)
    }
    guard let context = model.accountRequestContext else { return }
    savePhase = .loading
    do {
      let successMessage: String
      if let record {
        _ = try await model.client.updateDNSRecord(
          zoneID: zoneID, recordID: record.id, input: input)
        successMessage = DashL10n.string("DNS record updated")
      } else {
        _ = try await model.client.createDNSRecord(zoneID: zoneID, input: input)
        successMessage = DashL10n.string("DNS record created")
      }
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        savePhase = .idle
        return
      }
      model.toasts.success(successMessage)
      savePhase = .succeeded
    } catch {
      savePhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
    }
  }

  private func completeSavePresentation() {
    guard savePhase == .succeeded else {
      savePhase = .idle
      return
    }
    savePhase = .idle
    saved()
    dismiss()
  }

  private func delete(_ record: DNSRecord) {
    guard allowsWrites else {
      model.requestAccess(to: requiredWriteScopes)
      return
    }
    guard let accountID = model.activeAccountID else { return }
    error = nil
    guard
      model.deferredDeletions.schedule(
        .dnsRecord(
          accountID: accountID,
          zoneID: zoneID,
          recordID: record.id,
          recordType: record.type,
          displayName: record.name)) != nil
    else { return }
    dismiss()
  }
}
