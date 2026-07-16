import CloudflareAPI
import SwiftUI

struct FeatureRouterContent: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID

  var body: some View {
    let accessLevel = feature.capability.accessLevel(grantedScopes: model.grantedScopes)
    Group {
      if accessLevel != .locked {
        routedContent
          .environment(\.featureAllowsWrites, accessLevel == .full)
          .environment(\.featureRequiredScopes, feature.capability.all)
          .safeAreaInset(edge: .top, spacing: 0) {
            if accessLevel == .readOnly {
              FeatureReadOnlyBanner(feature: feature)
                .padding(.horizontal, DashTheme.Spacing.screen)
                .padding(.bottom, 8)
                .background(DashTheme.canvas)
            }
          }
      } else {
        FeatureAccessRequiredView(feature: feature)
      }
    }
  }

  /// Exhaustive on purpose — no `default:`. A new FeatureID must name its screen
  /// here or it does not build.
  @ViewBuilder
  private var routedContent: some View {
    Group {
      switch feature {
      case .zones: ZonesView()
      case .workers: WorkersView()
      case .r2: R2BucketsView()
      case .kv: KVNamespacesView()
      }
    }
  }
}

struct FeatureReadOnlyBanner: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      DashNotice(
        kind: .warning,
        message: "Read-only — grant write access to make changes.")
      DashPillButton(
        title: "Grant write access",
        isLoading: model.isAuthenticating
      ) {
        model.requestAccess(to: feature.capability.write)
      }
    }
  }
}

/// Maps a push destination to the catalog feature that owns its write scopes.
func featureID(for destination: Destination) -> FeatureID? {
  switch destination {
  case .profile, .settings: nil
  case .feature(let feature): feature
  case .zone, .dns, .cache, .zoneAnalytics, .zoneSettings:
    .zones
  case .worker, .workerTail: .workers
  case .r2Bucket: .r2
  case .kvNamespace: .kv
  }
}

/// Scopes a destination needs beyond what its FeatureID declares.
///
/// The literals matter: `dns.*` and `cache.purge` have no FeatureID of their own
/// since DNS Management and Cache & Performance left the catalog, and they are
/// not in `.zones.capability` — putting them there would lock the whole Zones
/// feature for a grant missing one of them. Deleting a case here compiles fine
/// and silently falls through to `.zones.capability.all`, which does not
/// include them. See DashAuthorizationScopes.coreOperations.
func requiredScopes(for destination: Destination) -> Set<String> {
  switch destination {
  case .profile, .settings:
    []
  case .dns:
    ["zone.read", "dns.read", "dns.write"]
  case .cache:
    ["zone.read", "cache.purge"]
  case .zoneSettings:
    ["zone.read", "zone-settings.read", "zone-settings.write"]
  case .workerTail:
    FeatureID.workers.capability.all.union(["workers-tail.read"])
  case .feature, .zone, .zoneAnalytics, .worker, .r2Bucket, .kvNamespace:
    featureID(for: destination)?.capability.all ?? []
  }
}

private struct FeatureWriteAccessKey: EnvironmentKey {
  static let defaultValue = true
}

private struct FeatureRequiredScopesKey: EnvironmentKey {
  static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
  var featureAllowsWrites: Bool {
    get { self[FeatureWriteAccessKey.self] }
    set { self[FeatureWriteAccessKey.self] = newValue }
  }

  var featureRequiredScopes: Set<String> {
    get { self[FeatureRequiredScopesKey.self] }
    set { self[FeatureRequiredScopesKey.self] = newValue }
  }
}

private struct FeatureAccessRequiredView: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID

  var body: some View {
    ScrollView {
      DashCard {
        VStack(alignment: .leading, spacing: 14) {
          SolarIcon(asset: SolarAsset.lock, size: 30, color: DashTheme.brand)
          Text("Grant access to \(feature.title)")
            .font(.title3.weight(.semibold))
            .foregroundStyle(DashTheme.strong)
          Text(
            "This module needs \(feature.capability.read.sorted().joined(separator: ", ")). You can review the request before Cloudflare opens."
          )
          .font(.subheadline)
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
          DashPillButton(
            title: "Grant access",
            isLoading: model.isAuthenticating
          ) {
            model.requestAccess(to: feature.capability.all)
          }
        }
      }
      .padding(20)
    }
    .background(DashTheme.canvas)
    .navigationTitle(feature.title)
  }
}

struct ZonesView: View {
  static let pageSize = 50

  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @State private var zones: [CloudflareZone] = []
  @State private var search = ""
  @State private var error: String?
  @State private var loading = true
  @State private var loadingMore = false
  @State private var pageState = DashPageState()

  private var filtered: [CloudflareZone] {
    search.isEmpty ? zones : zones.filter { $0.name.localizedCaseInsensitiveContains(search) }
  }

  var body: some View {
    DashFeatureList(
      search: $search,
      prompt: "Search zones",
      isLoading: loading,
      error: error,
      hasContent: !zones.isEmpty,
      retry: { Task { await load() } }
    ) {
      if filtered.isEmpty {
        DashEmptyState(
          icon: SolarAsset.search,
          title: search.isEmpty ? "No zones" : "Nothing found",
          message: search.isEmpty
            ? (featureAllowsWrites
              ? "Cloudflare returned no zones for this account."
              : "Cloudflare returned no zones for this account.")
            : "No zone matches \(search)."
        )
      } else {
        DashListCard {
          DashListCardRows(items: filtered) { zone in
            DashListGroupLink(value: .zone(zone.id)) {
              DashListRow(
                title: zone.name,
                subtitle: zonePlanSubtitle(zone),
                icon: SolarAsset.globe
              ) {
                StatusBadge(text: zone.status ?? "unknown")
              }
            }
          }
        }
      }
      if pageState.canLoadMore {
        DashLoadMoreFooter(
          loaded: zones.count,
          total: pageState.totalCount,
          noun: "zones",
          caption: search.isEmpty ? nil : "Searching \(zones.count) loaded zones",
          isLoading: loadingMore
        ) { Task { await loadMore() } }
      }
    }
    .refreshable { await load(force: true) }.task { await load() }
    .onAppear { reloadIfInvalidated() }
  }

  /// The cache drops under this list on memory pressure while it stays alive
  /// below a child screen; refresh on return when the cache went cold.
  private func reloadIfInvalidated() {
    guard let accountID = model.activeAccountID, !zones.isEmpty else { return }
    let cached: [CloudflareZone]? = model.featureCache.get(FeatureCacheKey.zones(accountID))
    if cached == nil { Task { await load(force: true) } }
  }

  private func zonePlanSubtitle(_ zone: CloudflareZone) -> String? {
    zone.plan?.name
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.zones(accountID)
    if !force, let cached: [CloudflareZone] = model.featureCache.get(key) {
      zones = cached
      pageState.rehydrate(loaded: cached.count, pageSize: Self.pageSize)
      loading = false
      error = nil
      return
    }
    if zones.isEmpty { loading = true }
    error = nil
    do {
      pageState.reset()
      let page = try await model.client.listZones(
        accountID: accountID, page: pageState.nextPage, perPage: Self.pageSize)
      zones = page.items
      pageState.absorb(
        info: page.resultInfo, received: page.items.count, loaded: zones.count,
        pageSize: Self.pageSize)
      model.featureCache.set(key, zones)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }

  private func loadMore() async {
    guard let accountID = model.activeAccountID, !loadingMore else { return }
    loadingMore = true
    defer { loadingMore = false }
    do {
      let page = try await model.client.listZones(
        accountID: accountID, page: pageState.nextPage, perPage: Self.pageSize)
      zones += page.items
      pageState.absorb(
        info: page.resultInfo, received: page.items.count, loaded: zones.count,
        pageSize: Self.pageSize)
      model.featureCache.set(FeatureCacheKey.zones(accountID), zones)
      error = nil
    } catch {
      self.error = error.dashActionableMessage
    }
  }
}

struct ZoneDetailView: View {
  @Environment(AppModel.self) private var model
  @AppStorage(PinnedZones.key) private var pinnedZoneData = ""
  let zoneID: String
  @State private var zone: CloudflareZone?
  @State private var error: String?

  private var isPinned: Bool { PinnedZones.isPinned(pinnedZoneData, zoneID: zoneID) }

  private let tools: [ZoneTool] = [
    ZoneTool(
      title: "DNS", icon: SolarAsset.globus, route: Destination.dns,
      blurb: "Records and proxy status"),
    ZoneTool(
      title: "Analytics", icon: SolarAsset.chart, route: Destination.zoneAnalytics,
      blurb: "Requests and threats"),
    ZoneTool(
      title: "Cache", icon: SolarAsset.bolt, route: Destination.cache,
      blurb: "Purge and rules"),
    ZoneTool(
      title: "Settings", icon: SolarAsset.slider, route: Destination.zoneSettings,
      blurb: "Under Attack, SSL, and dev mode"),
  ]

  var body: some View {
    DashFeatureList(
      isLoading: zone == nil && error == nil,
      error: error,
      hasContent: zone != nil,
      retry: { Task { await load() } }
    ) {
      if let zone {
        zoneHero(zone)
        primaryActions()
      }
    }
    .navigationTitle(zone?.name ?? "Zone")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        DashToolbarIconButton(
          asset: isPinned ? SolarAsset.pinFilled : SolarAsset.pin,
          accessibilityLabel: isPinned ? "Unpin zone" : "Pin zone"
        ) { togglePin() }
        .disabled(zone == nil)
      }
      .dashSeparateToolbarBackground()
    }
    .refreshable { await load(force: true) }.task { await load() }
  }

  private func togglePin() {
    guard let zone, let accountID = model.activeAccountID else { return }
    withAnimation(DashTheme.Motion.quick) {
      pinnedZoneData = PinnedZones.toggled(
        pinnedZoneData,
        pin: PinnedZone(accountID: accountID, zoneID: zoneID, name: zone.name))
    }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  private func load(force: Bool = false) async {
    let key = FeatureCacheKey.zone(zoneID)
    if !force, let cached: CloudflareZone = model.featureCache.get(key) {
      zone = cached
      error = nil
      return
    }
    do {
      let fetched = try await model.client.getZone(zoneID)
      zone = fetched
      model.featureCache.set(key, fetched)
      error = nil
    } catch {
      self.error = error.dashActionableMessage
    }
  }

  private func zoneHero(_ zone: CloudflareZone) -> some View {
    DashCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 12) {
          SolarIcon(
            asset: SolarAsset.globe, size: 28, color: FeatureVisualIdentity.heroColor(for: .zones))
          VStack(alignment: .leading, spacing: 2) {
            Text(zone.name).dashTextStyle(.sheetTitle)
            if let planName = zone.plan?.name {
              Text(planName)
                .dashTextStyle(.footnote)
                .foregroundStyle(DashTheme.placeholder)
            }
          }
          Spacer(minLength: 8)
          StatusBadge(text: zone.status ?? "unknown")
        }
        if let servers = zone.nameServers, !servers.isEmpty {
          Text("Nameservers").dashTextStyle(.footnoteSemibold).foregroundStyle(DashTheme.subtle)
          ForEach(servers, id: \.self) {
            Text($0).dashTextStyle(.code)
          }
        }
      }
    }
  }

  private func primaryActions() -> some View {
    DashListGroup(title: "Quick actions") {
      DashListCardRows(items: tools) { tool in
        DashListGroupLink(value: tool.route(zoneID)) {
          DashListRow(title: tool.title, subtitle: tool.blurb, icon: tool.icon)
        }
      }
    }
  }
}

/// One row on zone detail. Every row routes to a dedicated destination, which
/// declares its own scopes in `requiredScopes(for:)`.
private struct ZoneTool: Identifiable {
  let title: String
  let icon: String
  let route: (String) -> Destination
  var blurb: String? = nil
  var id: String { title }
}

struct DNSRecordsView: View {
  static let pageSize = 100

  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  let zoneID: String
  @State private var records: [DNSRecord] = []
  @State private var selected: DNSRecord?
  @State private var createsRecord = false
  @State private var search = ""
  @State private var loading = true
  @State private var loadingMore = false
  @State private var pageState = DashPageState()
  @State private var error: String?

  private var filtered: [DNSRecord] {
    search.isEmpty
      ? records
      : records.filter {
        $0.name.localizedCaseInsensitiveContains(search)
          || $0.content.localizedCaseInsensitiveContains(search)
      }
  }

  var body: some View {
    DashFeatureList(
      search: $search,
      prompt: "Search records",
      isLoading: loading,
      error: error,
      hasContent: !records.isEmpty,
      retry: { Task { await load() } }
    ) {
      if filtered.isEmpty {
        DashEmptyState(
          icon: SolarAsset.globus,
          title: "No DNS records",
          message: "Create a record with the add button."
        )
      } else {
        DashListCard {
          DashListCardRows(items: filtered) { record in
            Button {
              selected = record
            } label: {
              DashListRow(
                title: record.name,
                subtitle: "\(record.type)  ·  \(record.content)",
                icon: record.proxied == true ? SolarAsset.cloud : SolarAsset.globus,
                iconColor: record.proxied == true ? DashTheme.accent : DashTheme.brand
              )
            }
            .buttonStyle(DashPressButtonStyle())
          }
        }
      }
      if pageState.canLoadMore {
        DashLoadMoreFooter(
          loaded: records.count,
          total: pageState.totalCount,
          noun: "records",
          caption: search.isEmpty ? nil : "Searching \(records.count) loaded records",
          isLoading: loadingMore
        ) { Task { await loadMore() } }
      }
    }
    .refreshable { await load(force: true) }
    .navigationTitle("DNS")
    .toolbar {
      if featureAllowsWrites {
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarIconButton(asset: SolarAsset.plus, accessibilityLabel: "New DNS record") {
            createsRecord = true
          }
        }
        .dashSeparateToolbarBackground()
      }
    }
    .dashTray(
      item: $selected,
      title: { _ in "DNS record" },
      content: { record in
        DNSRecordEditor(zoneID: zoneID, record: record) {
          model.featureCache.remove(FeatureCacheKey.dnsRecords(zoneID))
          Task { await load(force: true) }
        }
      }
    )
    .dashTray(isPresented: $createsRecord, title: "New DNS record") {
      DNSRecordEditor(zoneID: zoneID, record: nil) {
        model.featureCache.remove(FeatureCacheKey.dnsRecords(zoneID))
        Task { await load(force: true) }
      }
    }
    .task { await load() }
  }

  private func load(force: Bool = false) async {
    let key = FeatureCacheKey.dnsRecords(zoneID)
    if !force, let cached: [DNSRecord] = model.featureCache.get(key) {
      records = cached
      pageState.rehydrate(loaded: cached.count, pageSize: Self.pageSize)
      loading = false
      error = nil
      return
    }
    if records.isEmpty { loading = true }
    error = nil
    do {
      pageState.reset()
      let page = try await model.client.listDNSRecords(
        zoneID: zoneID, page: pageState.nextPage, perPage: Self.pageSize)
      records = page.items
      pageState.absorb(
        info: page.resultInfo, received: page.items.count, loaded: records.count,
        pageSize: Self.pageSize)
      model.featureCache.set(key, records)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }

  private func loadMore() async {
    guard !loadingMore else { return }
    loadingMore = true
    defer { loadingMore = false }
    do {
      let page = try await model.client.listDNSRecords(
        zoneID: zoneID, page: pageState.nextPage, perPage: Self.pageSize)
      records += page.items
      pageState.absorb(
        info: page.resultInfo, received: page.items.count, loaded: records.count,
        pageSize: Self.pageSize)
      model.featureCache.set(FeatureCacheKey.dnsRecords(zoneID), records)
      error = nil
    } catch {
      self.error = error.dashActionableMessage
    }
  }
}

private struct DNSRecordEditor: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let zoneID: String
  let record: DNSRecord?
  let saved: () -> Void
  @State private var type: String
  @State private var name: String
  @State private var content: String
  @State private var proxied: Bool
  @State private var ttl: Int
  @State private var error: String?
  @State private var saving = false
  @State private var deleting = false
  @State private var confirmingDelete = false

  init(zoneID: String, record: DNSRecord?, saved: @escaping () -> Void) {
    self.zoneID = zoneID
    self.record = record
    self.saved = saved
    _type = State(initialValue: record?.type ?? "A")
    _name = State(initialValue: record?.name ?? "")
    _content = State(initialValue: record?.content ?? "")
    _proxied = State(initialValue: record?.proxied ?? false)
    _ttl = State(initialValue: record?.ttl ?? 1)
  }

  var body: some View {
    DashFormSheet(
      isSaving: saving,
      canSave: !name.isEmpty && !content.isEmpty,
      deleteMessage: record.map { "Permanently delete the \($0.type) record for \($0.name)." },
      isDeleting: deleting,
      deleteError: error,
      onDelete: record.map { rec in { Task { await delete(rec) } } },
      onSave: { Task { await save() } },
      content: {
        VStack(spacing: 14) {
          DashFormMenuField(
            label: "Type", selection: $type,
            options: ["A", "AAAA", "CNAME", "TXT", "MX", "NS", "SRV", "CAA", "PTR"])

          DashFormField(label: "Name", text: $name)
          DashFormField(label: "Content", text: $content)

          // Unproxying publishes the origin IP, and putting the record back
          // behind the proxy does not unpublish it — scanners keep the answer.
          DashToggleRow(
            title: "Proxied",
            subtitle: proxied ? nil : "Exposes the origin IP, permanently",
            isOn: $proxied)

          DashFormMenuField(
            label: "TTL", selection: ttlSelection, options: ttlOptions.map(\.label))

          if let error {
            DashNotice(kind: .error, message: error)
          }
        }
      }
    )
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
      options.append(("\(ttl)s", ttl))
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
    saving = true
    error = nil
    let input = DNSRecordInput(type: type, name: name, content: content, proxied: proxied, ttl: ttl)
    do {
      if let record {
        _ = try await model.client.updateDNSRecord(
          zoneID: zoneID, recordID: record.id, input: input)
      } else {
        _ = try await model.client.createDNSRecord(zoneID: zoneID, input: input)
      }
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      saved()
      dismiss()
    } catch { self.error = error.dashActionableMessage }
    saving = false
  }

  private func delete(_ record: DNSRecord) async {
    deleting = true
    error = nil
    do {
      try await model.client.deleteDNSRecord(zoneID: zoneID, recordID: record.id)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      saved()
      dismiss()
    } catch {
      self.error = error.dashActionableMessage
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    deleting = false
  }
}

struct WorkersView: View {
  @Environment(AppModel.self) private var model
  @State private var workers: [WorkerScript] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !workers.isEmpty,
      retry: { Task { await load() } }
    ) {
      if workers.isEmpty {
        DashEmptyState(
          icon: SolarAsset.codeCircle,
          title: "No Workers yet",
          message: "Your deployed Workers will appear here."
        )
      } else {
        DashListCard {
          DashListCardRows(items: workers) { worker in
            DashListGroupLink(value: .worker(worker.id)) {
              DashListRow(title: worker.id, icon: SolarAsset.codeCircle)
            }
          }
        }
      }
    }
    .refreshable { await load(force: true) }.task {
      await load()
    }
    .onAppear { reloadIfInvalidated() }
  }

  /// The cache drops under this list on memory pressure while it stays alive
  /// below a child screen; refresh on return when the cache went cold.
  private func reloadIfInvalidated() {
    guard let accountID = model.activeAccountID, !workers.isEmpty else { return }
    let cached: [WorkerScript]? = model.featureCache.get(FeatureCacheKey.workers(accountID))
    if cached == nil { Task { await load(force: true) } }
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.workers(accountID)
    if !force, let cached: [WorkerScript] = model.featureCache.get(key) {
      workers = cached
      loading = false
      error = nil
      return
    }
    if workers.isEmpty { loading = true }
    error = nil
    do {
      workers = try await model.client.listWorkers(accountID: accountID)
      model.featureCache.set(key, workers)
    } catch { self.error = error.dashActionableMessage }
    loading = false
  }
}

struct WorkerDetailView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  let name: String
  @State private var analytics: WorkerAnalyticsPayload?
  @State private var analyticsError: String?
  @State private var deployments: [WorkerDeploymentSummary] = []
  @State private var deploymentError: String?
  @State private var error: String?
  @State private var loading = true
  @State private var loadedSubdomain = false
  @State private var subdomainEnabled = false
  @State private var subdomainUpdating = false
  @State private var subdomainNotice: String?
  @State private var subdomainFailed = false

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: true,
      retry: { Task { await load(force: true) } }
    ) {
      if let latestDeployment = deployments.first {
        workerDeploymentCard(latestDeployment)
      } else if let deploymentError {
        DashNotice(kind: .warning, message: deploymentError)
      }
      if let analytics {
        workerMetricsCard(analytics)
      } else if let analyticsError {
        DashNotice(kind: .warning, message: analyticsError)
      }
      DashToggleRow(
        title: "workers.dev",
        subtitle: featureAllowsWrites ? nil : "Grant Workers write access to change this setting.",
        isOn: subdomainBinding,
        isEnabled: loadedSubdomain && featureAllowsWrites,
        isLoading: subdomainUpdating
      )
      if let subdomainNotice {
        DashNotice(kind: subdomainFailed ? .error : .success, message: subdomainNotice)
      }
      if model.hasScopes(["workers-tail.read"]) {
        DashListCard {
          DashListGroupLink(value: .workerTail(name)) {
            DashListRow(title: "Live tail", icon: SolarAsset.bolt)
          }
        }
      }
    }
    .navigationTitle(name).task { await load() }
    .refreshable { await load(force: true) }
  }

  private var subdomainBinding: Binding<Bool> {
    Binding(
      get: { subdomainEnabled },
      set: { enabled in
        guard loadedSubdomain, featureAllowsWrites, !subdomainUpdating else { return }
        subdomainEnabled = enabled
        Task { await setSubdomain(enabled) }
      })
  }

  private func workerDeploymentCard(_ deployment: WorkerDeploymentSummary) -> some View {
    DashCard {
      VStack(alignment: .leading, spacing: 10) {
        workerDeploymentHeader
        Text(deployment.annotations?.message ?? "Serving production traffic")
          .dashTextStyle(.bodySemibold)
          .foregroundStyle(DashTheme.text)
          .fixedSize(horizontal: false, vertical: true)
        Text(workerDeploymentAgeText(deployment.createdOn))
          .dashTextStyle(.caption)
          .foregroundStyle(DashTheme.subtle)
        Text(workerDeploymentTrafficText(deployment))
          .dashTextStyle(.caption)
          .foregroundStyle(DashTheme.rowSubtitle)
          .fixedSize(horizontal: false, vertical: true)
        if let author = deployment.authorEmail {
          Text(author)
            .dashTextStyle(.caption)
            .foregroundStyle(DashTheme.placeholder)
            .lineLimit(1)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "Latest deployment, active, \(workerDeploymentAgeText(deployment.createdOn)), \(workerDeploymentTrafficText(deployment))"
    )
  }

  @ViewBuilder private var workerDeploymentHeader: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 8) {
        workerDeploymentLabel
        StatusBadge(text: "Active")
      }
    } else {
      HStack(spacing: 10) {
        workerDeploymentLabel
        Spacer(minLength: 0)
        StatusBadge(text: "Active")
      }
    }
  }

  private var workerDeploymentLabel: some View {
    HStack(spacing: 10) {
      SolarIcon(asset: SolarAsset.cloud, size: 20, color: DashTheme.brand)
      Text("Latest deployment")
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func workerMetricsCard(_ summary: WorkerAnalyticsPayload) -> some View {
    DashCard {
      VStack(alignment: .leading, spacing: 10) {
        Text("Last 24 hours")
          .dashTextStyle(.footnoteSemibold)
          .foregroundStyle(DashTheme.subtle)
        if dynamicTypeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 12) {
            workerMetric("Requests", summary.requests.formatted())
            workerMetric("Errors", summary.errors.formatted())
            workerMetric(
              "CPU p50",
              String(format: "%.1f ms", summary.cpuTimeP50Us / 1000))
          }
        } else {
          HStack(spacing: 12) {
            workerMetric("Requests", summary.requests.formatted())
            workerMetric("Errors", summary.errors.formatted())
            workerMetric(
              "CPU p50",
              String(format: "%.1f ms", summary.cpuTimeP50Us / 1000))
          }
        }
        if summary.requests > 0 {
          let rate = Double(summary.errors) / Double(summary.requests)
          Text("Error rate \(String(format: "%.2f%%", rate * 100))")
            .dashTextStyle(.caption)
            .foregroundStyle(rate > 0.05 ? DashTheme.danger : DashTheme.subtle)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "Worker metrics. \(summary.requests) requests, \(summary.errors) errors"
    )
  }

  private func workerMetric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .dashTextStyle(.sectionTitle)
        .foregroundStyle(DashTheme.text)
        .monospacedDigit()
      Text(title)
        .dashTextStyle(.caption)
        .foregroundStyle(DashTheme.subtle)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else {
      loading = false
      return
    }
    if analytics == nil, deployments.isEmpty { loading = true }
    error = nil
    let key = FeatureCacheKey.workerSubdomain(accountID: accountID, name: name)
    if !force, let cached: Bool = model.featureCache.get(key) {
      subdomainEnabled = cached
      loadedSubdomain = true
    } else {
      do {
        subdomainEnabled = try await model.client.getWorkerSubdomain(
          accountID: accountID, name: name
        ).enabled
        loadedSubdomain = true
        model.featureCache.set(key, subdomainEnabled)
      } catch {
        self.error = error.dashActionableMessage
      }
    }
    await loadDeployments(accountID: accountID, force: force)
    await loadAnalytics(accountID: accountID, force: force)
    loading = false
  }

  private func loadDeployments(accountID: String, force: Bool) async {
    let key = FeatureCacheKey.workerDeployments(accountID: accountID, name: name)
    if !force, let cached: [WorkerDeploymentSummary] = model.featureCache.get(key) {
      deployments = cached
      deploymentError = nil
      return
    }
    do {
      deployments = try await model.client.listWorkerDeployments(
        accountID: accountID, scriptName: name)
      deploymentError = nil
      model.featureCache.set(key, deployments)
    } catch {
      deploymentError = error.dashActionableMessage
    }
  }

  private func loadAnalytics(accountID: String, force: Bool) async {
    let key = FeatureCacheKey.workerAnalytics(accountID: accountID, name: name)
    if !force, let cached: WorkerAnalyticsPayload = model.featureCache.get(key) {
      analytics = cached
      return
    }
    do {
      let summary = try await model.client.workerAnalytics(
        accountID: accountID, scriptName: name, hours: 24)
      analytics = summary
      analyticsError = nil
      model.featureCache.set(key, summary)
    } catch {
      analyticsError = error.dashActionableMessage
    }
  }

  private func setSubdomain(_ enabled: Bool) async {
    guard let accountID = model.activeAccountID else { return }
    subdomainUpdating = true
    subdomainNotice = nil
    defer { subdomainUpdating = false }
    do {
      let result = try await model.client.setWorkerSubdomain(
        accountID: accountID, name: name, enabled: enabled)
      subdomainEnabled = result.enabled
      model.featureCache.set(
        FeatureCacheKey.workerSubdomain(accountID: accountID, name: name), result.enabled)
      subdomainFailed = false
      subdomainNotice = "workers.dev \(result.enabled ? "enabled" : "disabled")."
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    } catch {
      subdomainEnabled = !enabled
      subdomainFailed = true
      subdomainNotice = error.dashActionableMessage
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
  }
}

private func workerDeploymentAgeText(_ value: String, now: Date = .now) -> String {
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let plain = ISO8601DateFormatter()
  plain.formatOptions = [.withInternetDateTime]
  guard let date = fractional.date(from: value) ?? plain.date(from: value) else {
    return "Deployed \(value)"
  }
  let formatter = RelativeDateTimeFormatter()
  formatter.unitsStyle = .abbreviated
  return "Deployed \(formatter.localizedString(for: date, relativeTo: now))"
}

private func workerDeploymentTrafficText(_ deployment: WorkerDeploymentSummary) -> String {
  guard !deployment.versions.isEmpty else { return deployment.source.capitalized }
  if deployment.versions.count == 1, let version = deployment.versions.first {
    return "Version \(version.versionID.prefix(8)) · \(version.percentage.formatted())% traffic"
  }
  return "Traffic split across \(deployment.versions.count) versions"
}

struct CachePurgeView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let zoneID: String
  @State private var url = ""
  @State private var status: String?
  @State private var failed = false
  @State private var working = false
  @State private var showsMore = false

  var body: some View {
    DashFeatureScreen {
      ScrollView {
        VStack(spacing: DashTheme.Spacing.section) {
          DashCard {
            VStack(alignment: .leading, spacing: 16) {
              VStack(alignment: .leading, spacing: 4) {
                Text("Purge by URL")
                  .dashTextStyle(.sectionTitle)
                  .foregroundStyle(DashTheme.strong)
                Text("Remove one cached asset without disturbing the rest of the zone.")
                  .dashTextStyle(.supporting)
                  .foregroundStyle(DashTheme.subtle)
              }
              DashFormField(label: "Asset URL", text: $url, keyboard: .URL)
              DashPillButton(title: "Purge URL", isLoading: working, isEnabled: !url.isEmpty) {
                Task { await purge(files: [url]) }
              }
            }
          }

          if let status {
            DashNotice(kind: failed ? .error : .success, message: status)
              .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
          }
        }
        .padding(.horizontal, DashTheme.Spacing.screen)
        .padding(.top, DashTheme.Spacing.section)
        .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
        .animation(
          reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.quick, value: status)
      }
      .dashKeyboardDismissal()
    }
    .navigationTitle("Cache")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        DashMoreButton(isPresented: $showsMore)
      }
      .dashSeparateToolbarBackground()
    }
    .dashMoreMenu(
      isPresented: $showsMore,
      title: "Purge cache",
      actions: [
        DashDangerAction(
          title: "Purge everything",
          message:
            "This removes every cached asset in this zone. Requests may temporarily reach your origin."
        ) {
          await purge(files: nil)
        }
      ]
    )
  }

  private func purge(files: [String]?) async {
    working = true
    do {
      try await model.client.purgeCache(zoneID: zoneID, files: files)
      status = "Cache purged."
      failed = false
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    } catch {
      status = error.dashActionableMessage
      failed = true
    }
    working = false
  }
}

/// Dashboard-style buckets for the flat zone-settings list.
/// The settings this screen offers, in display order.
///
/// Cloudflare returns 50-60 settings per zone; all but these are decisions you
/// make once, from a laptop, when you set the zone up. These five are the ones
/// worth reaching for away from your desk — the top two are the same pair the
/// App Intents expose.
///
/// Values whose valid range depends on the zone's plan stay out: browser_cache_ttl
/// rejects anything under two hours on Free, so a fixed menu would offer choices
/// that can only fail.
private let curatedZoneSettings: [String] = [
  "security_level",
  "development_mode",
  "ssl",
  "always_online",
  "always_use_https",
]

/// Enum-valued settings the API accepts as plain strings; everything listed here
/// renders as an editable menu instead of a read-only value row. Values come
/// from Cloudflare's OpenAPI schema (zones_*_value enums). The rest of
/// `curatedZoneSettings` is on/off.
private let zoneSettingOptions: [String: [String]] = [
  "ssl": ["off", "flexible", "full", "strict"],
  "security_level": ["off", "essentially_off", "low", "medium", "high", "under_attack"],
]

struct ZoneSettingsView: View {
  @Environment(AppModel.self) private var model
  let zoneID: String
  @State private var settings: [ZoneSetting] = []
  @State private var error: String?
  @State private var loading = true
  @State private var updatingSettingIDs: Set<String> = []

  var body: some View {
    DashFeatureList(
      isLoading: loading, error: error, hasContent: !curated.isEmpty,
      retry: { Task { await load() } }
    ) {
      ForEach(curated) { setting in
        settingRow(setting)
      }
    }
    .navigationTitle("Settings")
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  /// `curatedZoneSettings` order, not response order, and silently short when a
  /// plan omits one.
  private var curated: [ZoneSetting] {
    curatedZoneSettings.compactMap { id in settings.first { $0.id == id } }
  }

  @ViewBuilder
  private func settingRow(_ setting: ZoneSetting) -> some View {
    if setting.editable == false {
      // Some settings are readable but locked by plan. Show the value rather
      // than a control that can only fail.
      DashValueCard(title: setting.displayTitle, value: setting.value.displayText)
    } else {
      switch setting.value {
      case .string(let value):
        // The enum map wins over the on/off toggle: security_level reads "high"
        // or "off" but accepts six states.
        if let options = zoneSettingOptions[setting.id] {
          DashMenuRow(
            title: setting.displayTitle,
            value: value,
            options: options,
            isEnabled: !updatingSettingIDs.contains(setting.id),
            isLoading: updatingSettingIDs.contains(setting.id)
          ) { chosen in
            Task { await update(setting, value: .string(chosen)) }
          }
        } else if value == "on" || value == "off" {
          // Cloudflare encodes most binary zone settings as "on"/"off" strings,
          // not booleans — render them as the switches they are.
          DashToggleRow(
            title: setting.displayTitle,
            isOn: Binding(
              get: { value == "on" },
              set: { enabled in
                Task { await update(setting, value: .string(enabled ? "on" : "off")) }
              }),
            isEnabled: !updatingSettingIDs.contains(setting.id),
            isLoading: updatingSettingIDs.contains(setting.id)
          )
        } else {
          DashValueCard(title: setting.displayTitle, value: value)
        }
      case .bool(let enabled):
        DashToggleRow(
          title: setting.displayTitle,
          isOn: Binding(
            get: { enabled },
            set: { value in Task { await update(setting, value: .bool(value)) } }),
          isEnabled: !updatingSettingIDs.contains(setting.id),
          isLoading: updatingSettingIDs.contains(setting.id)
        )
      default:
        DashValueCard(title: setting.displayTitle, value: setting.value.displayText)
      }
    }
  }

  private func load(force: Bool = false) async {
    let key = FeatureCacheKey.zoneSettings(zoneID)
    if !force, let cached: [ZoneSetting] = model.featureCache.get(key) {
      settings = cached
      error = nil
      loading = false
      return
    }
    do {
      settings = try await model.client.listZoneSettings(zoneID: zoneID)
      model.featureCache.set(key, settings)
      error = nil
    } catch { self.error = error.dashActionableMessage }
    loading = false
  }

  private func update(_ setting: ZoneSetting, value: JSONValue) async {
    guard !updatingSettingIDs.contains(setting.id) else { return }
    updatingSettingIDs.insert(setting.id)
    defer { updatingSettingIDs.remove(setting.id) }
    error = nil
    do {
      let updated = try await model.client.updateZoneSetting(
        zoneID: zoneID, settingID: setting.id, value: value)
      if let index = settings.firstIndex(where: { $0.id == setting.id }) {
        settings[index] = updated
      }
      model.featureCache.set(FeatureCacheKey.zoneSettings(zoneID), settings)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    } catch {
      self.error = error.dashActionableMessage
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
  }
}

extension ZoneSetting {
  fileprivate var displayTitle: String {
    zoneSettingDisplayTitle(id)
  }
}

func zoneSettingDisplayTitle(_ id: String) -> String {
  switch id {
  case "ssl": "SSL"
  case "always_use_https": "Always Use HTTPS"
  case "min_tls_version": "Minimum TLS version"
  default: id.replacingOccurrences(of: "_", with: " ").capitalized
  }
}

extension JSONValue {
  var displayText: String {
    switch self {
    case .array(let values):
      values.isEmpty ? "None" : values.map(\.displayText).joined(separator: ", ")
    case .bool(let value): value ? "On" : "Off"
    case .null: "Not set"
    case .number(let value):
      value.rounded() == value ? String(Int(value)) : value.formatted()
    case .object(let value):
      value.isEmpty ? "None" : "\(value.count) values"
    case .string(let value): value
    }
  }
}
