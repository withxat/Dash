import CloudflareAPI
import SwiftUI

struct FeatureRouterView: View {
  let feature: FeatureID
  var body: some View {
    switch feature {
    case .zones: ZonesView()
    case .workers: WorkersView()
    case .r2: R2BucketsView()
    case .kv: KVNamespacesView()
    case .d1: D1DatabasesView()
    default: GenericFeatureView(feature: feature)
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
    List {
      if loading {
        LoadingStateView().listRowBackground(Color.clear)
      } else if let error {
        ErrorStateView(message: error) { Task { await load() } }.listRowBackground(Color.clear)
      } else if filtered.isEmpty {
        ContentUnavailableView.search(text: search).listRowBackground(Color.clear)
      } else {
        ForEach(filtered) { zone in
          NavigationLink(value: Destination.zone(zone.id)) {
            HStack(spacing: 12) {
              Image(systemName: "globe").foregroundStyle(DashTheme.brand).frame(width: 30)
              VStack(alignment: .leading) {
                Text(zone.name).fontWeight(.medium)
                Text(zone.status ?? "unknown").font(.caption).foregroundStyle(DashTheme.subtle)
              }
              Spacer()
              StatusBadge(text: zone.status ?? "unknown")
            }
          }
        }
      }
    }
    .dashGroupedList().navigationTitle("Zones").searchable(
      text: $search, prompt: "Search zones"
    )
    .refreshable { await load() }.task { await load() }.destinationRouting()
  }

  private func load() async {
    guard let accountID = model.activeAccountID else { return }
    loading = true
    error = nil
    do { zones = try await model.client.listZones(accountID: accountID).items } catch {
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
    ("DNS", "network", "dns"), ("Analytics", "chart.xyaxis.line", "analytics"),
    ("Cache", "bolt", "cache"), ("Settings", "slider.horizontal.3", "settings"),
    ("Security events", "shield", "security"), ("SSL/TLS", "lock.shield", "ssl"),
    ("IP access rules", "hand.raised", "firewall/access_rules/rules"),
    ("WAF", "wall", "rulesets/phases/http_request_firewall_custom/entrypoint"),
    ("Health checks", "heart.text.square", "healthchecks"),
    ("Waiting rooms", "person.3.sequence", "waiting_rooms"),
    ("Load balancers", "scale.3d", "load_balancers"),
    ("Page rules", "doc.badge.gearshape", "pagerules"),
    ("Email routing", "envelope", "email/routing/rules"),
    ("Worker routes", "arrow.triangle.branch", "workers/routes"),
  ]

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        if let zone {
          DashCard {
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Image(systemName: "globe.americas.fill").font(.title).foregroundStyle(
                  DashTheme.accent)
                VStack(alignment: .leading) {
                  Text(zone.name).font(.chill(21))
                  Text(zone.status ?? "unknown").foregroundStyle(DashTheme.subtle)
                }
                Spacer()
                StatusBadge(text: zone.status ?? "unknown")
              }
              if let servers = zone.nameServers {
                Divider()
                Text("Nameservers").font(.caption.weight(.semibold)).foregroundStyle(
                  DashTheme.subtle)
                ForEach(servers, id: \.self) { Text($0).font(.footnote.monospaced()) }
              }
            }
          }
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(tools, id: \.0) { title, symbol, endpoint in
              NavigationLink(value: destination(title: title, endpoint: endpoint)) {
                VStack(alignment: .leading, spacing: 12) {
                  Image(systemName: symbol).font(.title3).foregroundStyle(DashTheme.brand)
                  Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).frame(
                    maxWidth: .infinity, alignment: .leading)
                }
                .padding(16).frame(minHeight: 96).background(DashTheme.base)
                .clipShape(
                  RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
                )
                .overlay {
                  RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
                    .stroke(DashTheme.line, lineWidth: 0.5)
                }
                .dashCardShadow()
              }
              .buttonStyle(DashOpacityButtonStyle())
            }
          }
        } else if let error {
          ErrorStateView(message: error) { Task { await load() } }
        } else {
          LoadingStateView()
        }
      }.padding(16).padding(.bottom, 60)
    }.background(DashTheme.canvas).navigationTitle(zone?.name ?? "Zone")
      .navigationBarTitleDisplayMode(.inline)
      .refreshable { await load() }.task { await load() }.destinationRouting()
  }

  private func load() async {
    do { zone = try await model.client.getZone(zoneID) } catch {
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
    List {
      if loading {
        LoadingStateView().listRowBackground(Color.clear)
      } else if let error {
        ErrorStateView(message: error) { Task { await load() } }.listRowBackground(Color.clear)
      } else if filtered.isEmpty {
        ContentUnavailableView(
          "No DNS records", systemImage: "network",
          description: Text("Create a record with the add button.")
        ).listRowBackground(Color.clear)
      } else {
        ForEach(filtered) { record in
          Button {
            selected = record
          } label: {
            HStack {
              Text(record.type).font(.caption.bold()).foregroundStyle(DashTheme.brand).frame(
                width: 44)
              VStack(alignment: .leading) {
                Text(record.name).foregroundStyle(.primary).lineLimit(1)
                Text(record.content).font(.caption.monospaced()).foregroundStyle(DashTheme.subtle)
                  .lineLimit(1)
              }
              Spacer()
              if record.proxied == true {
                Image(systemName: "cloud.fill").foregroundStyle(DashTheme.accent)
              }
            }
          }.swipeActions { Button("Delete", role: .destructive) { Task { await delete(record) } } }
        }
      }
    }
    .dashGroupedList()
    .navigationTitle("DNS").searchable(text: $search, prompt: "Records")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          createsRecord = true
        } label: {
          Image(systemName: "plus")
        }
      }
    }
    .sheet(item: $selected) { record in
      NavigationStack { DNSRecordEditor(zoneID: zoneID, record: record) { Task { await load() } } }
    }
    .sheet(isPresented: $createsRecord) {
      NavigationStack { DNSRecordEditor(zoneID: zoneID, record: nil) { Task { await load() } } }
    }
    .refreshable { await load() }.task { await load() }
  }

  private func load() async {
    loading = true
    error = nil
    do { records = try await model.client.listDNSRecords(zoneID: zoneID).items } catch {
      self.error = error.localizedDescription
    }
    loading = false
  }
  private func delete(_ record: DNSRecord) async {
    try? await model.client.deleteDNSRecord(zoneID: zoneID, recordID: record.id)
    await load()
  }
}

private struct DNSRecordEditor: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
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
    Form {
      Section("Record") {
        Picker("Type", selection: $type) {
          ForEach(["A", "AAAA", "CNAME", "TXT", "MX", "SRV"], id: \.self) { Text($0) }
        }
        TextField("Name", text: $name).textInputAutocapitalization(.never)
        TextField("Content", text: $content, axis: .vertical).textInputAutocapitalization(.never)
        Toggle("Proxied", isOn: $proxied)
        Stepper(ttl == 1 ? "TTL: Auto" : "TTL: \(ttl)s", value: $ttl, in: 1...86400)
      }
      if let error { Section { Text(error).foregroundStyle(.red) } }
    }
    .dashGroupedList()
    .navigationTitle(record == nil ? "New DNS record" : "DNS record").navigationBarTitleDisplayMode(
      .inline
    )
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { Task { await save() } }.disabled(name.isEmpty || content.isEmpty || saving)
      }
    }
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
  @Environment(AppModel.self) private var model
  @State private var workers: [WorkerScript] = []
  @State private var pages: [PagesProject] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    List {
      if loading {
        LoadingStateView().listRowBackground(Color.clear)
      } else if let error {
        ErrorStateView(message: error) { Task { await load() } }.listRowBackground(Color.clear)
      } else {
        Section("Workers") {
          ForEach(workers) { worker in
            NavigationLink(value: Destination.worker(worker.id)) {
              Label(worker.id, systemImage: "bolt.horizontal.circle")
            }
          }
        }
        Section("Pages") {
          ForEach(pages) { project in
            NavigationLink(
              value: Destination.zoneTool(
                zoneID: "", title: project.name,
                path:
                  "/accounts/\(model.activeAccountID ?? "")/pages/projects/\(project.name)/deployments"
              )
            ) {
              VStack(alignment: .leading) {
                Text(project.name)
                Text(project.subdomain ?? "").font(.caption).foregroundStyle(DashTheme.subtle)
              }
            }
          }
        }
      }
    }.dashGroupedList().navigationTitle("Workers & Pages").refreshable { await load() }.task {
      await load()
    }
    .destinationRouting()
  }

  private func load() async {
    guard let accountID = model.activeAccountID else { return }
    loading = true
    error = nil
    do {
      async let w = model.client.listWorkers(accountID: accountID)
      async let p = model.client.listPagesProjects(accountID: accountID)
      (workers, pages) = try await (w, p)
    } catch { self.error = error.localizedDescription }
    loading = false
  }
}

struct WorkerDetailView: View {
  @Environment(AppModel.self) private var model
  let name: String
  @State private var source = ""
  @State private var error: String?
  @State private var loadedSubdomain = false
  @State private var subdomainEnabled = false

  var body: some View {
    List {
      Section("Management") {
        Toggle("workers.dev", isOn: $subdomainEnabled)
          .onChange(of: subdomainEnabled) { _, enabled in
            if loadedSubdomain { Task { await setSubdomain(enabled) } }
          }
        NavigationLink(
          value: Destination.zoneTool(
            zoneID: "", title: "Deployments",
            path:
              "/accounts/\(model.activeAccountID ?? "")/workers/services/\(name)/environments/production/deployments"
          )
        ) { Label("Deployments", systemImage: "clock.arrow.circlepath") }
        NavigationLink(
          value: Destination.zoneTool(
            zoneID: "", title: "Custom domains",
            path: "/accounts/\(model.activeAccountID ?? "")/workers/domains?service=\(name)")
        ) { Label("Custom domains", systemImage: "network") }
        NavigationLink(
          value: Destination.zoneTool(
            zoneID: "", title: "Builds",
            path: "/accounts/\(model.activeAccountID ?? "")/builds/builds?script_name=\(name)")
        ) { Label("Builds", systemImage: "hammer") }
      }
      Section("Source") {
        if let error {
          Text(error).foregroundStyle(.red)
        } else if source.isEmpty {
          ProgressView()
        } else {
          ScrollView(.horizontal) {
            Text(source).font(.caption.monospaced()).textSelection(.enabled)
          }
        }
      }
    }.dashGroupedList().navigationTitle(name).task { await load() }.destinationRouting()
  }
  private func load() async {
    guard let accountID = model.activeAccountID else { return }
    do {
      async let fetchedSource = model.client.getWorkerSource(accountID: accountID, name: name)
      async let fetchedSubdomain = model.client.getWorkerSubdomain(accountID: accountID, name: name)
      source = try await fetchedSource
      subdomainEnabled = try await fetchedSubdomain.enabled
      loadedSubdomain = true
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
    Form {
      Section("Purge by URL") {
        TextField("https://example.com/path", text: $url).textInputAutocapitalization(.never)
          .keyboardType(.URL)
        Button("Purge URL") { Task { await purge(files: [url]) } }
          .disabled(url.isEmpty || working)
      }
      Section {
        Button("Purge everything", role: .destructive) { Task { await purge(files: nil) } }
          .disabled(working)
      } header: {
        Text("Entire zone")
      } footer: {
        Text("Purging everything removes all cached assets for this zone.")
      }
      if let status {
        Section { Text(status).foregroundStyle(status == "Cache purged." ? .green : .red) }
      }
    }.dashGroupedList().navigationTitle("Cache")
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

  var body: some View {
    List {
      if let error {
        ErrorStateView(message: error) { Task { await load() } }.listRowBackground(Color.clear)
      }
      ForEach(settings) { setting in
        switch setting.value {
        case .bool(let enabled):
          Toggle(
            setting.id.replacingOccurrences(of: "_", with: " ").capitalized,
            isOn: Binding(
              get: { enabled },
              set: { value in Task { await update(setting, value: .bool(value)) } })
          )
          .disabled(setting.editable == false)
        case .string(let value):
          LabeledContent(
            setting.id.replacingOccurrences(of: "_", with: " ").capitalized, value: value)
        default:
          LabeledContent(setting.id, value: String(describing: setting.value))
        }
      }
    }.dashGroupedList().navigationTitle("Settings").refreshable { await load() }.task {
      await load()
    }
  }

  private func load() async {
    do {
      settings = try await model.client.listZoneSettings(zoneID: zoneID)
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  private func update(_ setting: ZoneSetting, value: JSONValue) async {
    do {
      _ = try await model.client.updateZoneSetting(
        zoneID: zoneID, settingID: setting.id, value: value)
      await load()
    } catch { self.error = error.localizedDescription }
  }
}
