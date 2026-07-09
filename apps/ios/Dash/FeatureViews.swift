import CloudflareAPI
import SwiftUI

struct FeatureRouterContent: View {
  let feature: FeatureID

  var body: some View {
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
      default: GenericFeatureView(feature: feature)
      }
    }
  }
}

struct ZonesView: View {
  @Environment(AppModel.self) private var model
  @State private var zones: [CloudflareZone] = []
  @State private var search = ""
  @State private var error: String?
  @State private var loading = true
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
      retry: { Task { await load() } }
    ) {
      if filtered.isEmpty {
        DashEmptyState(
          icon: SolarAsset.search,
          title: search.isEmpty ? "No zones" : "Nothing found",
          message: search.isEmpty
            ? "Cloudflare returned no zones for this account."
            : "No zone matches \(search)."
        )
      } else {
        DashListCard {
          DashListCardRows(items: filtered) { zone in
            DashListGroupLink(value: .zone(zone.id)) {
              DashListRow(
                title: zone.name,
                subtitle: zone.status ?? "unknown",
                icon: SolarAsset.globe
              )
              .overlay(alignment: .trailing) {
                StatusBadge(text: zone.status ?? "unknown")
                  .padding(.trailing, 28)
              }
            }
          }
        }
      }
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          creates = true
        } label: {
          DashToolbarActionIcon(asset: SolarAsset.plus)
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel("Add zone")
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
    } catch { self.error = error.localizedDescription }
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.zones(accountID)
    if !force, let cached: [CloudflareZone] = model.featureCache.get(key) {
      zones = cached
      loading = false
      error = nil
      return
    }
    if zones.isEmpty { loading = true }
    error = nil
    do {
      zones = try await model.client.listZones(accountID: accountID).items
      model.featureCache.set(key, zones)
    } catch {
      self.error = error.localizedDescription
    }
    loading = false
  }
}

struct ZoneDetailView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismissScreen
  let zoneID: String
  @State private var zone: CloudflareZone?
  @State private var error: String?
  @State private var showsMore = false

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
    ScrollView {
      VStack(spacing: DashTheme.Spacing.section) {
        if let zone {
          DashCard {
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                SolarIcon(asset: SolarAsset.globe, size: 28, color: DashTheme.accent)
                VStack(alignment: .leading) {
                  Text(zone.name).font(.dashTitle(21))
                  Text(zone.status ?? "unknown").foregroundStyle(DashTheme.subtle)
                  if let planName = zone.plan?.name {
                    Text(planName)
                      .font(.system(size: 13))
                      .foregroundStyle(DashTheme.placeholder)
                  }
                }
                Spacer()
                StatusBadge(text: zone.status ?? "unknown")
              }
              if let servers = zone.nameServers {
                Text("Nameservers").font(.system(size: 13, weight: .semibold)).foregroundStyle(
                  DashTheme.subtle)
                ForEach(servers, id: \.self) {
                  Text($0).font(.system(size: 13, design: .monospaced))
                }
              }
            }
          }
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(visibleTools(for: zone), id: \.title) { tool in
              NavigationLink(value: destination(title: tool.title, endpoint: tool.endpoint)) {
                VStack(alignment: .leading, spacing: 12) {
                  SolarIcon(asset: tool.icon, size: 22, color: DashTheme.brand)
                  Text(tool.title).font(.subheadline.weight(.semibold)).foregroundStyle(
                    DashTheme.text
                  )
                  .frame(
                    maxWidth: .infinity, alignment: .leading)
                }
                .padding(DashTheme.Spacing.card)
                .frame(minHeight: 96)
                .background(DashTheme.base)
                .clipShape(
                  RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
                )
                .overlay {
                  RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
                    .stroke(DashTheme.line, lineWidth: 0.5)
                }
              }
              .buttonStyle(DashPressButtonStyle())
            }
          }
        } else if let error {
          ErrorStateView(message: error) { Task { await load() } }
        } else {
          LoadingStateView()
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, 12)
      .padding(.bottom, 100)
    }.background(DashTheme.canvas).navigationTitle(zone?.name ?? "Zone")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          DashMoreButton(isPresented: $showsMore)
        }
      }
      .dashMoreMenu(
        isPresented: $showsMore,
        title: zone?.name ?? "Zone",
        actions: [
          DashDangerAction(
            title: "Remove zone",
            message:
              "Remove \(zone?.name ?? "this zone") from Cloudflare. DNS records stop resolving through Cloudflare."
          ) {
            await deleteZone()
          }
        ]
      )
      .refreshable { await load(force: true) }.task { await load() }
  }

  private func deleteZone() async {
    guard let accountID = model.activeAccountID else { return }
    _ = try? await model.client.mutate(path: "/zones/\(zoneID)", method: "DELETE")
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
      self.error = error.localizedDescription
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
  @Environment(AppModel.self) private var model
  let zoneID: String
  @State private var records: [DNSRecord] = []
  @State private var selected: DNSRecord?
  @State private var createsRecord = false
  @State private var search = ""
  @State private var loading = true
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
    }
    .refreshable { await load(force: true) }
    .navigationTitle("DNS")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          createsRecord = true
        } label: {
          DashToolbarActionIcon(asset: SolarAsset.plus)
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel("New DNS record")
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
      loading = false
      error = nil
      return
    }
    if records.isEmpty { loading = true }
    error = nil
    do {
      records = try await model.client.listDNSRecords(zoneID: zoneID).items
      model.featureCache.set(key, records)
    } catch {
      self.error = error.localizedDescription
    }
    loading = false
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
      onDelete: record.map { rec in { Task { await delete(rec) } } },
      onSave: { Task { await save() } },
      content: {
        VStack(spacing: 14) {
          DashFormMenuField(
            label: "Type", selection: $type,
            options: ["A", "AAAA", "CNAME", "TXT", "MX", "NS", "SRV", "CAA", "PTR"])

          DashFormField(label: "Name", text: $name)
          DashFormField(label: "Content", text: $content)

          Toggle("Proxied", isOn: $proxied)
            .font(.system(size: 15, weight: .medium))
            .tint(DashTheme.brand)
            .padding(.horizontal, 4)

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
    } catch { self.error = error.localizedDescription }
    saving = false
  }

  private func delete(_ record: DNSRecord) async {
    deleting = true
    try? await model.client.deleteDNSRecord(zoneID: zoneID, recordID: record.id)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    saved()
    dismiss()
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
    } catch { self.error = error.localizedDescription }
    loading = false
  }
}

struct WorkerDetailView: View {
  private enum Tab: Hashable { case management, source }

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismissScreen
  let name: String
  @State private var source = ""
  @State private var error: String?
  @State private var loadedSubdomain = false
  @State private var subdomainEnabled = false
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
            DashListCard {
              DashToggleRow(title: "workers.dev", isOn: $subdomainEnabled)
                .onChange(of: subdomainEnabled) { _, enabled in
                  if loadedSubdomain { Task { await setSubdomain(enabled) } }
                }
              DashListGroupDivider()
              DashListGroupLink(
                value: .zoneTool(
                  zoneID: "", title: "Deployments",
                  path:
                    "/accounts/\(model.activeAccountID ?? "")/workers/services/\(name)/environments/production/deployments"
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
              DashListGroupDivider()
              DashListGroupLink(
                value: .zoneTool(
                  zoneID: "", title: "Builds",
                  path: "/accounts/\(model.activeAccountID ?? "")/builds/builds?script_name=\(name)"
                )
              ) {
                DashListRow(title: "Builds", icon: SolarAsset.sledgehammer)
              }
            }
          } else if let error {
            ErrorStateView(message: error) { Task { await load(force: true) } }
          } else if source.isEmpty {
            LoadingStateView()
          } else {
            DashCodeBlock(text: source)
          }
        }
        .padding(.horizontal, DashTheme.Spacing.screen)
        .padding(.bottom, 100)
      }
    }
    .navigationTitle(name).task { await load() }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        DashMoreButton(isPresented: $showsMore)
      }
    }
    .dashMoreMenu(
      isPresented: $showsMore,
      title: name,
      actions: [
        DashDangerAction(
          title: "Delete Worker",
          message: "Permanently delete \(name) and its deployments. Routes stop resolving."
        ) {
          await deleteWorker()
        }
      ]
    )
  }
  private func deleteWorker() async {
    guard let accountID = model.activeAccountID else { return }
    _ = try? await model.client.mutate(
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
      subdomainEnabled = cached.subdomainEnabled
      loadedSubdomain = true
      error = nil
      return
    }
    do {
      async let fetchedSource = model.client.getWorkerSource(accountID: accountID, name: name)
      async let fetchedSubdomain = model.client.getWorkerSubdomain(accountID: accountID, name: name)
      source = try await fetchedSource
      subdomainEnabled = try await fetchedSubdomain.enabled
      loadedSubdomain = true
      model.featureCache.set(
        key, WorkerDetailSnapshot(source: source, subdomainEnabled: subdomainEnabled))
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
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
      self.error = error.localizedDescription
    }
  }
}

struct CachePurgeView: View {
  @Environment(AppModel.self) private var model
  let zoneID: String
  @State private var url = ""
  @State private var status: String?
  @State private var working = false
  @State private var showsMore = false

  var body: some View {
    ScrollView {
      VStack(spacing: DashTheme.Spacing.section) {
        DashCard {
          VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Purge by URL")
                .font(.dashTitle(20, weight: .semibold))
                .foregroundStyle(DashTheme.strong)
              Text("Remove one cached asset without disturbing the rest of the zone.")
                .font(.system(size: 15))
                .foregroundStyle(DashTheme.subtle)
            }
            DashFormField(label: "Asset URL", text: $url, keyboard: .URL)
            DashPillButton(title: "Purge URL", isLoading: working) {
              Task { await purge(files: [url]) }
            }
            .disabled(url.isEmpty || working)
            .opacity(url.isEmpty ? 0.45 : 1)
          }
        }

        if let status {
          DashNotice(kind: status == "Cache purged." ? .success : .error, message: status)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, 12)
      .padding(.bottom, 100)
      .animation(DashTheme.Motion.quick, value: status)
    }
    .dashKeyboardDismissal()
    .background(DashTheme.canvas)
    .navigationTitle("Cache")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        DashMoreButton(isPresented: $showsMore)
      }
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
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    } catch { status = error.localizedDescription }
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
/// renders as an editable menu instead of a read-only value row.
private let zoneSettingOptions: [String: [String]] = [
  "ssl": ["off", "flexible", "full", "strict"],
  "min_tls_version": ["1.0", "1.1", "1.2", "1.3"],
  "security_level": ["essentially_off", "low", "medium", "high", "under_attack"],
  "cache_level": ["aggressive", "basic", "simplified"],
  "polish": ["off", "lossless", "lossy"],
  "image_resizing": ["off", "open", "on"],
  "pseudo_ipv4": ["off", "add_header", "overwrite_header"],
]

struct ZoneSettingsView: View {
  @Environment(AppModel.self) private var model
  let zoneID: String
  @State private var settings: [ZoneSetting] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    DashFeatureList(isLoading: loading, error: error, retry: { Task { await load() } }) {
      ForEach(ZoneSettingGroup.allCases, id: \.self) { group in
        let grouped = settings.filter { ZoneSettingGroup(settingID: $0.id) == group }
        if !grouped.isEmpty {
          DashListGroup(title: group.rawValue) {
            ForEach(Array(grouped.enumerated()), id: \.element.id) { index, setting in
              settingRow(setting)
              if index < grouped.count - 1 { DashListGroupDivider() }
            }
          }
        }
      }
    }
    .navigationTitle("Settings")
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  @ViewBuilder
  private func settingRow(_ setting: ZoneSetting) -> some View {
    switch setting.value {
    case .bool(let enabled):
      DashToggleRow(
        title: setting.displayTitle,
        subtitle: setting.editable == false ? "Read only" : nil,
        isOn: Binding(
          get: { enabled },
          set: { value in Task { await update(setting, value: .bool(value)) } }),
        isEnabled: setting.editable != false
      )
    case .string(let value):
      if let options = zoneSettingOptions[setting.id], setting.editable != false {
        ZoneSettingMenuRow(
          title: setting.displayTitle,
          value: value,
          options: options
        ) { chosen in
          Task { await update(setting, value: .string(chosen)) }
        }
      } else {
        DashValueRow(title: setting.displayTitle, value: value)
      }
    default:
      DashValueRow(title: setting.displayTitle, value: setting.value.displayText)
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
    } catch { self.error = error.localizedDescription }
    loading = false
  }

  private func update(_ setting: ZoneSetting, value: JSONValue) async {
    do {
      _ = try await model.client.updateZoneSetting(
        zoneID: zoneID, settingID: setting.id, value: value)
      model.featureCache.remove(FeatureCacheKey.zoneSettings(zoneID))
      await load(force: true)
    } catch { self.error = error.localizedDescription }
  }
}

/// Value-row-shaped menu for enum zone settings: title left, current value and a
/// chevron right, options in a menu.
private struct ZoneSettingMenuRow: View {
  let title: String
  let value: String
  let options: [String]
  let onSelect: (String) -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(title)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(DashTheme.text)
      Spacer(minLength: 12)
      Menu {
        Picker(title, selection: Binding(get: { value }, set: onSelect)) {
          ForEach(options, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")) }
        }
      } label: {
        HStack(spacing: 6) {
          Text(value.replacingOccurrences(of: "_", with: " "))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(DashTheme.brand)
          SolarIcon(asset: SolarAsset.chevronRight, size: 12, color: DashTheme.brand)
            .rotationEffect(.degrees(90))
        }
      }
    }
    .padding(.vertical, 14)
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
