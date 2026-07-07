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
    .refreshable { await load(force: true) }.task { await load() }
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
  let zoneID: String
  @State private var zone: CloudflareZone?
  @State private var error: String?

  private let tools: [(String, String, String)] = [
    ("DNS", SolarAsset.globus, "dns"), ("Analytics", SolarAsset.chart, "analytics"),
    ("Cache", SolarAsset.bolt, "cache"), ("Settings", SolarAsset.slider, "settings"),
    ("Security events", SolarAsset.shield, "security"), ("SSL/TLS", SolarAsset.lock, "ssl"),
    ("IP access rules", "SolarShieldUserOutline", "firewall/access_rules/rules"),
    ("WAF", SolarAsset.shield, "rulesets/phases/http_request_firewall_custom/entrypoint"),
    ("Health checks", SolarAsset.heartPulse, "healthchecks"),
    ("Waiting rooms", SolarAsset.users, "waiting_rooms"),
    ("Load balancers", SolarAsset.branching, "load_balancers"),
    ("Page rules", SolarAsset.file, "pagerules"),
    ("Email routing", SolarAsset.letter, "email/routing/rules"),
    ("Worker routes", SolarAsset.routing, "workers/routes"),
  ]

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
            ForEach(tools, id: \.0) { title, symbol, endpoint in
              NavigationLink(value: destination(title: title, endpoint: endpoint)) {
                VStack(alignment: .leading, spacing: 12) {
                  SolarIcon(asset: symbol, size: 22, color: DashTheme.brand)
                  Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(DashTheme.text)
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
                .dashCardShadow()
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
      .refreshable { await load(force: true) }.task { await load() }
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
    case "cache": .cache(zoneID)
    case "settings": .zoneSettings(zoneID)
    default:
      .zoneTool(zoneID: zoneID, title: title, path: "/zones/{zone}/\(endpoint)")
    }
  }
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
            .contextMenu {
              Button("Delete", role: .destructive) { Task { await delete(record) } }
            }
          }
        }
      }
    }
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
    .refreshable { await load(force: true) }.task { await load() }
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
  private func delete(_ record: DNSRecord) async {
    try? await model.client.deleteDNSRecord(zoneID: zoneID, recordID: record.id)
    model.featureCache.remove(FeatureCacheKey.dnsRecords(zoneID))
    await load(force: true)
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
      onSave: { Task { await save() } },
      content: {
        VStack(spacing: 14) {
          Picker("Type", selection: $type) {
            ForEach(["A", "AAAA", "CNAME", "TXT", "MX", "SRV"], id: \.self) { Text($0) }
          }
          .pickerStyle(.segmented)

          DashFormField(label: "Name", text: $name)
          DashFormField(label: "Content", text: $content, axis: .vertical)

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
  let name: String
  @State private var source = ""
  @State private var error: String?
  @State private var loadedSubdomain = false
  @State private var subdomainEnabled = false
  @State private var selectedTab: Tab = .management

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

        DashCard {
          VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Entire zone")
                .font(.dashTitle(20, weight: .semibold))
                .foregroundStyle(DashTheme.strong)
              Text("This removes every cached asset. Requests may temporarily reach your origin.")
                .font(.system(size: 15))
                .foregroundStyle(DashTheme.subtle)
            }
            DashActionRow(
              title: "Purge everything",
              icon: SolarAsset.trash,
              role: .destructive
            ) {
              Task { await purge(files: nil) }
            }
            .disabled(working)
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
    .background(DashTheme.canvas)
    .navigationTitle("Cache")
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

struct ZoneSettingsView: View {
  @Environment(AppModel.self) private var model
  let zoneID: String
  @State private var settings: [ZoneSetting] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    DashFeatureList(isLoading: loading, error: error, retry: { Task { await load() } }) {
      DashListGroup(title: "Zone configuration") {
        ForEach(Array(settings.enumerated()), id: \.element.id) { index, setting in
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
            DashValueRow(title: setting.displayTitle, value: value)
          default:
            DashValueRow(title: setting.displayTitle, value: setting.value.displayText)
          }
          if index < settings.count - 1 { DashListGroupDivider() }
        }
      }
    }
    .navigationTitle("Settings")
    .refreshable { await load(force: true) }
    .task { await load() }
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

extension ZoneSetting {
  fileprivate var displayTitle: String {
    id.replacingOccurrences(of: "_", with: " ").capitalized
  }
}

extension JSONValue {
  fileprivate var displayText: String {
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
