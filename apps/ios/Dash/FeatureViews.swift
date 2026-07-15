import CloudflareAPI
import SwiftUI

struct FeatureRouterContent: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID

  var body: some View {
    let accessLevel = feature.capability.accessLevel(grantedScopes: model.grantedScopes)
    if accessLevel != .locked {
      routedContent
        .environment(\.featureAllowsWrites, accessLevel == .full)
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

  @ViewBuilder
  private var routedContent: some View {
    Group {
      switch feature {
      case .zones: ZonesView()
      case .workers: WorkersView()
      case .r2: R2BucketsView()
      case .kv: KVNamespacesView()
      case .d1: D1DatabasesView()
      case .images: ImagesView()
      case .stream: StreamView()
      case .analytics: AnalyticsView()
      case .account: AccountView()
      case .apiExplorer: APIExplorerView()
      case .workersAI: WorkersAIView()
      case .browserRendering: BrowserRenderingView()
      case .aiSearch:
        EndpointProductView(feature: feature, matching: ["ai-search", "autorag", "/rag/"])
      case .calls, .zeroTrustConnectors, .workersObservability:
        FeatureHubView(feature: feature)
      case .rulesets: RulesetsView()
      case .botManagement, .cacheSettings:
        FeatureZonePickerView(feature: feature)
      case .zaraz:
        EndpointProductView(feature: feature, matching: ["zaraz"])
      case .accessPolicies: AccessPoliciesView()
      case .magicNetworking:
        EndpointProductView(
          feature: feature,
          matching: [
            "magic-wan", "magic-transit", "magic-firewall", "ip-prefix", "address-map", "pcap",
          ]
        )
      case .dnsManagement:
        FeatureHubView(feature: feature)
      case .sslCertificates, .apiSecurity:
        FeatureZonePickerView(feature: feature)
      case .radarIntel:
        EndpointProductView(feature: feature, matching: ["/radar/", "/intel/"])
      default: GenericFeatureView(feature: feature)
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
  case .profile, .accountDNSSettings: nil
  case .feature(let feature), .zonePicker(let feature), .zoneFeatureHub(let feature, _, _):
    feature
  case .zone, .dns, .cache, .zoneAnalytics, .zoneSettings, .zoneTool:
    .zones
  case .botManagement: .botManagement
  case .cachePerformance: .cacheSettings
  case .rulesetList, .ruleset: .rulesets
  case .accessAppPolicies: .accessPolicies
  case .worker, .workerTail: .workers
  case .r2Bucket: .r2
  case .kvNamespace: .kv
  case .d1Database, .d1Table: .d1
  }
}

/// Editing is safe only for classic scripts (0 module parts) or single-module
/// workers; multi-module uploads through /content would drop sibling modules.
func workerSourceIsEditable(moduleCount: Int, hasWriteScope: Bool) -> Bool {
  hasWriteScope && moduleCount <= 1
}

private struct FeatureWriteAccessKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  var featureAllowsWrites: Bool {
    get { self[FeatureWriteAccessKey.self] }
    set { self[FeatureWriteAccessKey.self] = newValue }
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
  @State private var creates = false
  @State private var newName = ""

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
    .toolbar {
      if featureAllowsWrites {
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarIconButton(asset: SolarAsset.plus, accessibilityLabel: "Add zone") {
            creates = true
          }
        }
        .dashSeparateToolbarBackground()
      }
    }
    .dashTray(isPresented: $creates, title: "Add zone") {
      DashFormSheet(
        saveTitle: "Add",
        canSave: !newName.isEmpty,
        onSave: { Task { await create() } },
        content: {
          DashFormField(label: "Domain name", text: $newName)
        }
      )
    }
    .refreshable { await load(force: true) }.task { await load() }
    .onAppear { reloadIfInvalidated() }
  }

  /// A child (zone screen) may delete a zone and clear the cache while this
  /// list stays alive below it; refresh on return when the cache went cold.
  private func reloadIfInvalidated() {
    guard let accountID = model.activeAccountID, !zones.isEmpty else { return }
    let cached: [CloudflareZone]? = model.featureCache.get(FeatureCacheKey.zones(accountID))
    if cached == nil { Task { await load(force: true) } }
  }

  private func zonePlanSubtitle(_ zone: CloudflareZone) -> String? {
    zone.plan?.name
  }

  private func create() async {
    guard let accountID = model.activeAccountID, !newName.isEmpty else { return }
    do {
      _ = try await model.client.mutate(
        path: "/zones", method: "POST",
        body: [
          "name": .string(newName),
          "account": .object(["id": .string(accountID)]),
        ])
      newName = ""
      creates = false
      model.featureCache.remove(FeatureCacheKey.zones(accountID))
      await load(force: true)
    } catch { self.error = error.dashActionableMessage }
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
  @Environment(\.dismiss) private var dismissScreen
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @AppStorage(PinnedZones.key) private var pinnedZoneData = ""
  let zoneID: String
  @State private var zone: CloudflareZone?
  @State private var error: String?
  @State private var showsMore = false

  private var isPinned: Bool { PinnedZones.isPinned(pinnedZoneData, zoneID: zoneID) }

  private let tools: [ZoneTool] = [
    ZoneTool(title: "DNS", icon: SolarAsset.globus, endpoint: "dns"),
    ZoneTool(title: "Analytics", icon: SolarAsset.chart, endpoint: "analytics"),
    ZoneTool(title: "Cache", icon: SolarAsset.bolt, endpoint: "cache"),
    ZoneTool(title: "Settings", icon: SolarAsset.slider, endpoint: "settings"),
    ZoneTool(title: "SSL/TLS", icon: SolarAsset.lock, endpoint: "ssl/certificate_packs?status=all"),
    ZoneTool(
      title: "IP access rules", icon: "SolarShieldUserOutline",
      endpoint: "firewall/access_rules/rules"),
    ZoneTool(title: "WAF rulesets", icon: SolarAsset.shield, endpoint: "rulesets"),
    ZoneTool(
      title: "Health checks", icon: SolarAsset.heartPulse, endpoint: "healthchecks",
      minTier: .pro),
    ZoneTool(
      title: "Waiting rooms", icon: SolarAsset.users, endpoint: "waiting_rooms",
      minTier: .business),
    ZoneTool(title: "Load balancers", icon: SolarAsset.branching, endpoint: "load_balancers"),
    ZoneTool(title: "Page rules", icon: SolarAsset.file, endpoint: "pagerules"),
    ZoneTool(title: "Email routing", icon: SolarAsset.letter, endpoint: "email/routing/rules"),
    ZoneTool(title: "Worker routes", icon: SolarAsset.routing, endpoint: "workers/routes"),
    ZoneTool(title: "Snippets", icon: SolarAsset.code, endpoint: "snippets"),
    ZoneTool(title: "Web3 gateways", icon: SolarAsset.globus, endpoint: "web3/hostnames"),
    ZoneTool(title: "Page Shield", icon: SolarAsset.shield, endpoint: "page_shield/scripts"),
  ]

  private func visibleTools(for zone: CloudflareZone) -> [ZoneTool] {
    // Fail open when the plan is missing from the response.
    guard let plan = zone.plan else { return tools }
    let tier = ZonePlanTier(plan: plan)
    return tools.filter { tier >= $0.minTier }
  }

  var body: some View {
    DashFeatureList(
      isLoading: zone == nil && error == nil,
      error: error,
      hasContent: zone != nil,
      retry: { Task { await load() } }
    ) {
      if let zone {
        DashCard {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              SolarIcon(asset: SolarAsset.globe, size: 28, color: DashTheme.accent)
              VStack(alignment: .leading) {
                Text(zone.name).dashTextStyle(.sheetTitle)
                Text(zone.status ?? "unknown").foregroundStyle(DashTheme.subtle)
                if let planName = zone.plan?.name {
                  Text(planName)
                    .font(.footnote)
                    .foregroundStyle(DashTheme.placeholder)
                }
              }
              Spacer()
              StatusBadge(text: zone.status ?? "unknown")
            }
            if let servers = zone.nameServers {
              Text("Nameservers").dashTextStyle(.footnoteSemibold).foregroundStyle(
                DashTheme.subtle)
              ForEach(servers, id: \.self) {
                Text($0).dashTextStyle(.code)
              }
            }
          }
        }
        DashTileGrid {
          ForEach(visibleTools(for: zone), id: \.title) { tool in
            NavigationLink(value: destination(title: tool.title, endpoint: tool.endpoint)) {
              DashToolTile(title: tool.title, icon: tool.icon)
            }
            .buttonStyle(DashPressButtonStyle())
          }
        }
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
      if featureAllowsWrites {
        ToolbarItem(placement: .topBarTrailing) {
          DashMoreButton(isPresented: $showsMore)
        }
        .dashSeparateToolbarBackground()
      }
    }
    .dashMoreMenu(
      isPresented: $showsMore,
      title: zone?.name ?? "Zone",
      actions: featureAllowsWrites
        ? [
          DashDangerAction(
            title: "Remove zone",
            message:
              "Remove \(zone?.name ?? "this zone") from Cloudflare. DNS records stop resolving through Cloudflare.",
            confirmationText: zone?.name
          ) {
            try await deleteZone()
          }
        ] : []
    )
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

  private func deleteZone() async throws {
    guard let accountID = model.activeAccountID else { return }
    _ = try await model.client.mutate(path: "/zones/\(zoneID)", method: "DELETE")
    model.featureCache.remove(FeatureCacheKey.zones(accountID))
    dismissScreen()
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

  private func destination(title: String, endpoint: String) -> Destination {
    switch endpoint {
    case "dns": .dns(zoneID)
    case "analytics": .zoneAnalytics(zoneID)
    case "cache": .cache(zoneID)
    case "settings": .zoneSettings(zoneID)
    default:
      .zoneTool(zoneID: zoneID, title: title, path: "/zones/{zone}/\(endpoint)")
    }
  }
}

private struct ZoneTool {
  let title: String
  let icon: String
  let endpoint: String
  var minTier: ZonePlanTier = .free
}

enum ZonePlanTier: Int, Comparable {
  case free = 0
  case pro, business, enterprise

  init(plan: ZonePlan) {
    let id = plan.legacyId ?? plan.name?.lowercased() ?? ""
    if id.contains("enterprise") {
      self = .enterprise
    } else if id.contains("business") {
      self = .business
    } else if id.contains("pro") {
      self = .pro
    } else {
      self = .free
    }
  }

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
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

          DashToggleRow(title: "Proxied", isOn: $proxied)

          Stepper(ttl == 1 ? "TTL: Auto" : "TTL: \(ttl)s", value: $ttl, in: 1...86400)
            .font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 4)

          if let error {
            DashNotice(kind: .error, message: error)
          }
        }
      }
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
  private enum Tab: Hashable { case workers, pages }

  @Environment(AppModel.self) private var model
  @State private var workers: [WorkerScript] = []
  @State private var pages: [PagesProject] = []
  @State private var error: String?
  @State private var loading = true
  @State private var selectedTab: Tab = .workers

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: selectedTab == .workers ? !workers.isEmpty : !pages.isEmpty,
      retry: { Task { await load() } },
      header: {
        DashTextTabs(
          items: [("Workers", Tab.workers), ("Pages", Tab.pages)],
          selection: $selectedTab
        )
      }
    ) {
      if selectedTab == .workers, workers.isEmpty {
        DashEmptyState(
          icon: SolarAsset.codeCircle,
          title: "No Workers yet",
          message: "Your deployed Workers will appear here."
        )
      } else if selectedTab == .pages, pages.isEmpty {
        DashEmptyState(
          icon: SolarAsset.code,
          title: "No Pages projects yet",
          message: "Your Pages projects will appear here."
        )
      } else if selectedTab == .workers {
        DashListCard {
          DashListCardRows(items: workers) { worker in
            DashListGroupLink(value: .worker(worker.id)) {
              DashListRow(title: worker.id, icon: SolarAsset.codeCircle)
            }
          }
        }
      } else {
        DashListCard {
          DashListCardRows(items: pages) { project in
            DashListGroupLink(
              value: .zoneTool(
                zoneID: "", title: project.name,
                path:
                  "/accounts/\(model.activeAccountID ?? "")/pages/projects/\(project.name)/deployments"
              )
            ) {
              DashListRow(
                title: project.name,
                subtitle: project.subdomain,
                icon: SolarAsset.code
              )
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

  /// A child (worker screen) may delete a worker and clear the cache while this
  /// list stays alive below it; refresh on return when the cache went cold.
  private func reloadIfInvalidated() {
    guard let accountID = model.activeAccountID, !workers.isEmpty else { return }
    let cached: [WorkerScript]? = model.featureCache.get(FeatureCacheKey.workers(accountID))
    if cached == nil { Task { await load(force: true) } }
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let workersKey = FeatureCacheKey.workers(accountID)
    let pagesKey = FeatureCacheKey.pages(accountID)
    if !force,
      let cachedWorkers: [WorkerScript] = model.featureCache.get(workersKey),
      let cachedPages: [PagesProject] = model.featureCache.get(pagesKey)
    {
      workers = cachedWorkers
      pages = cachedPages
      loading = false
      error = nil
      return
    }
    if workers.isEmpty && pages.isEmpty { loading = true }
    error = nil
    do {
      async let w = model.client.listWorkers(accountID: accountID)
      async let p = model.client.listPagesProjects(accountID: accountID)
      (workers, pages) = try await (w, p)
      model.featureCache.set(workersKey, workers)
      model.featureCache.set(pagesKey, pages)
    } catch { self.error = error.dashActionableMessage }
    loading = false
  }
}

struct WorkerDetailView: View {
  private enum Tab: Hashable { case management, source }

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismissScreen
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let name: String
  @State private var source: WorkerSource?
  @State private var draft = ""
  @State private var deploying = false
  @State private var deployError: String?
  @State private var confirmsDeploy = false
  @State private var error: String?
  @State private var loadedSubdomain = false
  @State private var subdomainEnabled = false
  @State private var workerTag: String?
  @State private var selectedTab: Tab = .management
  @State private var showsMore = false

  var body: some View {
    DashFeatureScreen(chrome: {
      DashTextTabs(
        items: [("Management", Tab.management), ("Source", Tab.source)],
        selection: $selectedTab
      )
    }) {
      ScrollView {
        LazyVStack(spacing: DashTheme.Spacing.section) {
          if selectedTab == .management {
            DashToggleRow(title: "workers.dev", isOn: $subdomainEnabled)
              .onChange(of: subdomainEnabled) { _, enabled in
                if loadedSubdomain { Task { await setSubdomain(enabled) } }
              }
            DashListCard {
              DashListGroupLink(
                value: .zoneTool(
                  zoneID: "", title: "Deployments",
                  path:
                    "/accounts/\(model.activeAccountID ?? "")/workers/scripts/\(name)/deployments"
                )
              ) {
                DashListRow(title: "Deployments", icon: SolarAsset.clock)
              }
              DashListGroupDivider()
              DashListGroupLink(
                value: .zoneTool(
                  zoneID: "", title: "Custom domains",
                  path: "/accounts/\(model.activeAccountID ?? "")/workers/domains?service=\(name)")
              ) {
                DashListRow(title: "Custom domains", icon: SolarAsset.globus)
              }
              // Builds APIs key on the immutable script tag, so the row waits
              // for the tag to resolve.
              if let workerTag {
                DashListGroupDivider()
                DashListGroupLink(
                  value: .zoneTool(
                    zoneID: "", title: "Builds",
                    path:
                      "/accounts/\(model.activeAccountID ?? "")/builds/workers/\(workerTag)/builds"
                  )
                ) {
                  DashListRow(title: "Builds", icon: SolarAsset.sledgehammer)
                }
              }
              if model.hasScopes(["workers-tail.read"]) {
                DashListGroupDivider()
                DashListGroupLink(value: .workerTail(name)) {
                  DashListRow(title: "Live tail", icon: SolarAsset.bolt)
                }
              }
            }
          } else if let error {
            ErrorStateView(message: error) { Task { await load(force: true) } }
          } else if let source {
            if workerSourceIsEditable(
              moduleCount: source.moduleCount, hasWriteScope: hasWriteScope)
            {
              if let deployError {
                DashNotice(kind: .error, message: deployError)
              }
              DashCodePanel(
                title: source.mainModule ?? "Script",
                message: "Deploying replaces the live script content immediately.",
                text: $draft,
                minHeight: 260
              )
              DashPillButton(
                title: "Deploy",
                isLoading: deploying,
                isEnabled: !draft.isEmpty && draft != source.content
              ) {
                confirmsDeploy = true
              }
              .confirmationDialog(
                "Deploy \(name)?", isPresented: $confirmsDeploy, titleVisibility: .visible
              ) {
                Button("Deploy to production", role: .destructive) {
                  Task { await deploy() }
                }
              } message: {
                Text("The new content serves on all routes as soon as Cloudflare accepts it.")
              }
            } else {
              if source.moduleCount > 1 {
                DashNotice(
                  kind: .warning,
                  message:
                    "This Worker has \(source.moduleCount) modules; editing multi-module Workers needs wrangler. Showing the main module read-only."
                )
              }
              DashCodeBlock(text: source.content)
            }
          } else {
            LoadingStateView()
          }
        }
        .padding(.horizontal, DashTheme.Spacing.screen)
        .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
        .animation(
          reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.quick, value: workerTag)
      }
    }
    .navigationTitle(name).task { await load() }
    .toolbar {
      if featureAllowsWrites {
        ToolbarItem(placement: .topBarTrailing) {
          DashMoreButton(isPresented: $showsMore)
        }
        .dashSeparateToolbarBackground()
      }
    }
    .dashMoreMenu(
      isPresented: $showsMore,
      title: name,
      actions: featureAllowsWrites
        ? [
          DashDangerAction(
            title: "Delete Worker",
            message: "Permanently delete \(name) and its deployments. Routes stop resolving."
          ) {
            try await deleteWorker()
          }
        ] : []
    )
  }
  private var hasWriteScope: Bool {
    featureAllowsWrites && model.hasScopes(["workers-scripts.write"])
  }

  private func deploy() async {
    guard let accountID = model.activeAccountID, let source else { return }
    deploying = true
    deployError = nil
    do {
      _ = try await model.client.uploadWorkerScript(
        accountID: accountID, name: name, source: source, content: draft)
      model.featureCache.remove(FeatureCacheKey.workerSource(accountID: accountID, name: name))
      await load(force: true)
    } catch {
      deployError = error.dashActionableMessage
    }
    deploying = false
  }

  private func deleteWorker() async throws {
    guard let accountID = model.activeAccountID else { return }
    _ = try await model.client.mutate(
      path: "/accounts/\(accountID)/workers/scripts/\(name)", method: "DELETE")
    model.featureCache.remove(FeatureCacheKey.workers(accountID))
    model.featureCache.remove(FeatureCacheKey.workerSource(accountID: accountID, name: name))
    dismissScreen()
  }
  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.workerSource(accountID: accountID, name: name)
    if !force, let cached: WorkerDetailSnapshot = model.featureCache.get(key) {
      source = cached.source
      draft = cached.source.content
      subdomainEnabled = cached.subdomainEnabled
      workerTag = cached.tag
      loadedSubdomain = true
      error = nil
      return
    }
    do {
      async let fetchedSource = model.client.getWorkerSource(accountID: accountID, name: name)
      async let fetchedSubdomain = model.client.getWorkerSubdomain(accountID: accountID, name: name)
      async let fetchedTag = resolveTag(accountID: accountID)
      source = try await fetchedSource
      draft = source?.content ?? ""
      subdomainEnabled = try await fetchedSubdomain.enabled
      loadedSubdomain = true
      do {
        workerTag = try await fetchedTag
        if let source {
          model.featureCache.set(
            key,
            WorkerDetailSnapshot(
              source: source, subdomainEnabled: subdomainEnabled, tag: workerTag))
        }
      } catch {
        // A failed lookup hides the Builds row for this visit only — skip
        // caching the snapshot so the next visit retries the tag.
        workerTag = nil
      }
      error = nil
    } catch {
      self.error = error.dashActionableMessage
    }
  }

  /// The workers list usually sits in the session cache already; only a deep
  /// link pays for the extra request.
  private func resolveTag(accountID: String) async throws -> String? {
    let cached: [WorkerScript]? = model.featureCache.get(FeatureCacheKey.workers(accountID))
    if let tag = cached?.first(where: { $0.id == name })?.tag { return tag }
    return try await model.client.workerTag(accountID: accountID, name: name)
  }

  private func setSubdomain(_ enabled: Bool) async {
    guard let accountID = model.activeAccountID else { return }
    do {
      let result = try await model.client.setWorkerSubdomain(
        accountID: accountID, name: name, enabled: enabled)
      subdomainEnabled = result.enabled
      model.featureCache.remove(FeatureCacheKey.workerSource(accountID: accountID, name: name))
    } catch {
      subdomainEnabled.toggle()
      self.error = error.dashActionableMessage
    }
  }
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
private enum ZoneSettingGroup: String, CaseIterable {
  case ssl = "SSL/TLS"
  case speed = "Speed"
  case caching = "Caching"
  case security = "Security"
  case network = "Network"
  case other = "Other"

  init(settingID: String) {
    self =
      switch settingID {
      case "ssl", "always_use_https", "min_tls_version", "tls_1_3",
        "automatic_https_rewrites", "opportunistic_encryption", "tls_client_auth",
        "security_header", "ciphers":
        .ssl
      case "brotli", "early_hints", "rocket_loader", "mirage", "polish", "webp",
        "image_resizing", "minify", "prefetch_preload", "speed_brain", "fonts":
        .speed
      case "cache_level", "browser_cache_ttl", "always_online", "development_mode",
        "sort_query_string_for_cache", "crawler_hints":
        .caching
      case "security_level", "challenge_ttl", "browser_check", "hotlink_protection",
        "email_obfuscation", "server_side_exclude", "waf", "privacy_pass",
        "replace_insecure_js":
        .security
      case "http2", "http3", "0rtt", "ipv6", "websockets", "ip_geolocation",
        "max_upload", "response_buffering", "true_client_ip_header", "pseudo_ipv4",
        "opportunistic_onion", "network_error_logging", "h2_prioritization":
        .network
      default:
        .other
      }
  }
}

/// Enum-valued settings the API accepts as plain strings; everything listed here
/// renders as an editable menu instead of a read-only value row. Values come
/// from Cloudflare's OpenAPI schema (zones_*_value enums).
private let zoneSettingOptions: [String: [String]] = [
  "ssl": ["off", "flexible", "full", "strict"],
  "min_tls_version": ["1.0", "1.1", "1.2", "1.3"],
  "security_level": ["off", "essentially_off", "low", "medium", "high", "under_attack"],
  "cache_level": ["aggressive", "basic", "simplified"],
  "polish": ["off", "lossless", "lossy"],
  "image_resizing": ["off", "open", "on"],
  "pseudo_ipv4": ["off", "add_header", "overwrite_header"],
  "tls_1_3": ["on", "off", "zrt"],
  "h2_prioritization": ["on", "off", "custom"],
  "cname_flattening": ["flatten_at_root", "flatten_all"],
  "origin_max_http_version": ["2", "1"],
]

/// Enumerated numeric settings; the menu writes the chosen number back.
private let zoneSettingNumberOptions: [String: [Int]] = [
  "challenge_ttl": [
    300, 900, 1800, 2700, 3600, 7200, 10800, 14400, 28800, 57600, 86400,
    604_800, 2_592_000, 31_536_000,
  ],
  "edge_cache_ttl": [
    30, 60, 300, 1200, 1800, 3600, 7200, 10800, 14400, 18000, 28800, 43200,
    57600, 72000, 86400, 172_800, 259_200, 345_600, 432_000, 518_400, 604_800,
  ],
  "max_upload": [
    100, 125, 150, 175, 200, 225, 250, 275, 300, 325, 350, 375, 400, 425, 450,
    475, 500, 1000,
  ],
]

/// Readable in the settings collection but absent from the PATCH bodies
/// (transformations) or declared uneditable (advanced_ddos) — never render a
/// control that can only fail.
private let readOnlyZoneSettings: Set<String> = [
  "transformations", "transformations_allowed_origins", "advanced_ddos",
]

struct ZoneSettingsView: View {
  @Environment(AppModel.self) private var model
  let zoneID: String
  @State private var settings: [ZoneSetting] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    DashFeatureList(
      isLoading: loading, error: error, hasContent: !settings.isEmpty,
      retry: { Task { await load() } }
    ) {
      let readOnly = settings.filter(isReadOnly)
      if !readOnly.isEmpty {
        DashReadOnlySettingsCard(
          rows: readOnly.map { ($0.displayTitle, $0.value.displayText) })
      }
      ForEach(ZoneSettingGroup.allCases, id: \.self) { group in
        let grouped = settings.filter {
          ZoneSettingGroup(settingID: $0.id) == group && !isReadOnly($0)
        }
        if !grouped.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            Text(group.rawValue)
              .dashTextStyle(.bodyMedium)
              .foregroundStyle(DashTheme.subtle)
              .padding(.horizontal, 16)
            ForEach(grouped) { setting in
              settingRow(setting)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .navigationTitle("Settings")
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  /// Settings that can't be edited here: flagged uneditable by the API,
  /// lacking a write path, or of a shape the page has no control for.
  private func isReadOnly(_ setting: ZoneSetting) -> Bool {
    if readOnlyZoneSettings.contains(setting.id) || setting.editable == false { return true }
    switch setting.value {
    case .bool: return false
    case .string(let value):
      return zoneSettingOptions[setting.id] == nil && value != "on" && value != "off"
    case .number: return zoneSettingNumberOptions[setting.id] == nil
    default: return true
    }
  }

  /// Renders one editable setting; read-only ones are filtered into the
  /// top card by `isReadOnly` before reaching here.
  @ViewBuilder
  private func settingRow(_ setting: ZoneSetting) -> some View {
    switch setting.value {
    case .bool(let enabled):
      DashToggleRow(
        title: setting.displayTitle,
        isOn: Binding(
          get: { enabled },
          set: { value in Task { await update(setting, value: .bool(value)) } })
      )
    case .string(let value):
      // The enum map wins over the on/off toggle: settings like polish read
      // "off" today but accept more than two states.
      if let options = zoneSettingOptions[setting.id] {
        DashMenuRow(
          title: setting.displayTitle,
          value: value,
          options: options
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
            })
        )
      } else {
        DashValueCard(title: setting.displayTitle, value: value)
      }
    case .number(let number):
      if let options = zoneSettingNumberOptions[setting.id] {
        DashMenuRow(
          title: setting.displayTitle,
          value: JSONValue.number(number).displayText,
          options: options.map(String.init)
        ) { chosen in
          guard let value = Double(chosen) else { return }
          Task { await update(setting, value: .number(value)) }
        }
      } else {
        DashValueCard(title: setting.displayTitle, value: setting.value.displayText)
      }
    default:
      DashValueCard(title: setting.displayTitle, value: setting.value.displayText)
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
    do {
      _ = try await model.client.updateZoneSetting(
        zoneID: zoneID, settingID: setting.id, value: value)
      model.featureCache.remove(FeatureCacheKey.zoneSettings(zoneID))
      await load(force: true)
    } catch { self.error = error.dashActionableMessage }
  }
}

extension ZoneSetting {
  fileprivate var displayTitle: String {
    id.replacingOccurrences(of: "_", with: " ").capitalized
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
