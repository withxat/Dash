import Foundation

enum FeatureID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case zones, workers, r2, kv, d1, queues, vectorize, secrets
  case hyperdrive, pipelines, aiGateway
  case workersAI, browserRendering, containers, workersObservability
  case turnstile, accessApps, accessGroups, serviceTokens, gatewayPolicies, ruleLists
  case rulesets, botManagement, apiSecurity, accessPolicies, zeroTrustConnectors
  case emailAddresses, registrar, tunnels, loadBalancerPools, dnsFirewall
  case dnsManagement, sslCertificates, cacheSettings
  case images, stream, analytics, logpush, account

  var id: String { rawValue }
  var title: String { FeatureCatalog.descriptor(for: self).title }
  var subtitle: String { FeatureCatalog.descriptor(for: self).subtitle }
  var symbol: String { FeatureCatalog.descriptor(for: self).symbol }
  var solarAssetName: String { FeatureCatalog.descriptor(for: self).solarAssetName }
  var solarOutlineAssetName: String { FeatureCatalog.descriptor(for: self).solarOutlineAssetName }
  var category: String { FeatureCatalog.descriptor(for: self).category }
  var capability: FeatureCapability { FeatureCatalog.descriptor(for: self).capability }
}

struct FeatureCapability: Hashable, Sendable {
  let read: Set<String>
  let write: Set<String>

  var all: Set<String> { read.union(write) }

  func accessLevel(grantedScopes: Set<String>?) -> FeatureAccessLevel {
    guard let grantedScopes else { return .full }
    guard read.isSubset(of: grantedScopes) else { return .locked }
    guard write.isEmpty || write.isSubset(of: grantedScopes) else { return .readOnly }
    return .full
  }
}

enum FeatureAccessLevel: Hashable, Sendable {
  case locked
  case readOnly
  case full
}

struct FeatureDescriptor: Hashable, Sendable {
  let id: FeatureID
  let title: String
  let subtitle: String
  let symbol: String
  let solarAssetName: String
  let solarOutlineAssetName: String
  let category: String
  let genericPath: String?
  let capability: FeatureCapability
}

enum Destination: Hashable {
  case profile
  case settings
  case accountDNSSettings
  case feature(FeatureID)
  case zone(String)
  case dns(String)
  case cache(String)
  case zoneAnalytics(String)
  case zoneSettings(String)
  case zoneTool(zoneID: String, title: String, path: String)
  case zonePicker(FeatureID)
  case zoneFeatureHub(feature: FeatureID, zoneID: String, zoneName: String)
  case botManagement(zoneID: String, zoneName: String)
  case cachePerformance(zoneID: String, zoneName: String)
  case rulesetList(basePath: String, title: String)
  case ruleset(basePath: String, rulesetID: String, name: String)
  case accessAppPolicies(appID: String, appName: String)
  case worker(String)
  case workerTail(String)
  case r2Bucket(String)
  case kvNamespace(String)
  case d1Database(String, String)
  case d1Table(databaseID: String, databaseName: String, table: String)
}

enum FeatureCatalog {
  static let descriptors: [FeatureDescriptor] = [
    // Domains & DNS
    feature(
      .zones, "Zones", "Domains, DNS, cache, and zone settings", "globe",
      "SolarGlobal", "SolarGlobalOutline", "Domains & DNS",
      read: ["zone.read"], write: ["zone.write"]),
    feature(
      .dnsManagement, "DNS Management", "DNS views and account-level DNS defaults",
      "server.rack", "SolarGlobus", "SolarGlobusOutline", "Domains & DNS",
      read: ["dns.read", "dns-view.read", "account-dns-settings.read", "zone-dns-settings.read"],
      write: [
        "dns.write", "dns-view.write", "account-dns-settings.write", "zone-dns-settings.write",
      ]),
    feature(
      .registrar, "Registrar", "Registered domains and renewals", "network",
      "SolarMapPoint", "SolarMapPointOutline", "Domains & DNS",
      path: "/accounts/{account}/registrar/domains",
      read: ["registrar-domains.read"], write: ["registrar-domains.admin"]),
    feature(
      .dnsFirewall, "DNS Firewall", "Upstream DNS caching and protection", "shield.slash",
      "SolarShieldNetwork", "SolarShieldNetworkOutline", "Domains & DNS",
      path: "/accounts/{account}/dns_firewall",
      read: ["dns-firewall.read"], write: ["dns-firewall.write"]),
    // Compute
    feature(
      .workers, "Workers & Pages", "Scripts, routes, deployments, and custom domains",
      "bolt.horizontal.circle", "SolarCodeSquare", "SolarCodeSquareOutline", "Compute",
      read: ["workers-scripts.read", "workers-routes.read", "page.read"],
      write: ["workers-scripts.write", "workers-routes.write", "page.write"]),
    feature(
      .containers, "Containers", "Applications, versions, rollouts, registries, and instances",
      "shippingbox", "SolarBox", "SolarBoxOutline", "Compute",
      path: "/accounts/{account}/containers/applications",
      read: ["containers.read", "cloudchamber.read"],
      write: ["containers.write", "cloudchamber.write"]),
    feature(
      .browserRendering, "Browser Rendering", "Screenshots, crawls, PDFs, and browser sessions",
      "safari", "SolarScreencast2", "SolarScreencast2Outline", "Compute",
      read: ["browser-rendering.read"], write: ["browser-rendering.write"]),
    feature(
      .workersObservability, "Workers Observability", "Telemetry queries and destinations",
      "waveform.path.ecg", "SolarHeartPulse", "SolarHeartPulseOutline", "Compute",
      read: ["workers-observability.read", "workers-tail.read"],
      write: ["workers-observability.write", "workers-observability-telemetry.write"]),
    // Storage & Data
    feature(
      .r2, "R2", "R2 object storage buckets", "externaldrive",
      "SolarCloudStorage", "SolarCloudStorageOutline", "Storage & Data",
      read: ["workers-r2.read", "workers-r2-bucket-item.read"],
      write: ["workers-r2.write", "workers-r2-bucket-item.write"]),
    feature(
      .kv, "KV", "Workers KV namespaces", "list.bullet.rectangle",
      "SolarKeyMinimalistic", "SolarKeyMinimalisticOutline", "Storage & Data",
      read: ["workers-kv-storage.read"], write: ["workers-kv-storage.write"]),
    feature(
      .d1, "D1", "Serverless SQL databases and console", "cylinder",
      "SolarDatabase", "SolarDatabaseOutline", "Storage & Data",
      read: ["d1.read"], write: ["d1.write"]),
    feature(
      .queues, "Queues", "Message queues, producers, and consumers", "tray.2",
      "SolarInbox", "SolarInboxOutline", "Storage & Data",
      path: "/accounts/{account}/queues",
      read: ["queues.read"], write: ["queues.write"]),
    feature(
      .hyperdrive, "Hyperdrive", "Accelerated connections to external databases",
      "bolt.horizontal", "SolarBolt", "SolarBoltOutline", "Storage & Data",
      path: "/accounts/{account}/hyperdrive/configs",
      read: ["query-cache.read"], write: ["query-cache.write"]),
    feature(
      .pipelines, "Pipelines", "Streaming ingestion into R2", "arrow.triangle.merge",
      "SolarRoute", "SolarRouteOutline", "Storage & Data",
      path: "/accounts/{account}/pipelines/v1/pipelines",
      read: ["pipelines.read"], write: ["pipelines.write", "pipelines.send"]),
    feature(
      .secrets, "Secrets Store", "Account-level secrets, names only", "key.horizontal",
      "SolarLockKeyhole", "SolarLockKeyholeOutline", "Storage & Data",
      path: "/accounts/{account}/secrets_store/stores",
      read: ["secrets-store.read"], write: ["secrets-store.write"]),
    // AI
    feature(
      .workersAI, "Workers AI", "Models, inference, and conversion APIs", "sparkles",
      "SolarStructure", "SolarStructureOutline", "AI",
      read: ["ai.read"], write: ["ai.write"]),
    feature(
      .vectorize, "Vectorize", "Vector indexes for AI search",
      "point.3.connected.trianglepath.dotted", "SolarInfinite", "SolarInfiniteOutline",
      "AI", path: "/accounts/{account}/vectorize/v2/indexes",
      read: ["vectorize.read"], write: ["vectorize.write"]),
    feature(
      .aiGateway, "AI Gateway", "Gateways for observing and controlling AI traffic", "brain",
      "SolarCommand", "SolarCommandOutline", "AI",
      path: "/accounts/{account}/ai-gateway/gateways",
      read: ["aig.read"], write: ["aig.write", "aig.run"]),
    // Security
    feature(
      .turnstile, "Turnstile", "CAPTCHA-free challenge widgets",
      "checkmark.shield", "SolarShieldCheck", "SolarShieldCheckOutline", "Security",
      path: "/accounts/{account}/challenges/widgets",
      read: ["challenge-widgets.read"], write: ["challenge-widgets.write"]),
    feature(
      .rulesets, "Rulesets", "Account and zone rules, transforms, redirects, and custom errors",
      "slider.horizontal.3", "SolarTuning2", "SolarTuning2Outline", "Security",
      read: ["account-rulesets.read", "transform-rules.read", "zone-transform-rules.read"],
      write: ["account-rulesets.write", "transform-rules.write", "zone-transform-rules.write"]),
    feature(
      .ruleLists, "Rule lists", "Reusable IP and redirect lists",
      "list.bullet.rectangle.portrait", "SolarInboxArchive", "SolarInboxArchiveOutline", "Security",
      path: "/accounts/{account}/rules/lists",
      read: ["account-rule-lists.read"], write: ["account-rule-lists.write"]),
    feature(
      .botManagement, "Bot Management", "Bot controls, feedback reports, and managed protection",
      "ant", "SolarBug", "SolarBugOutline", "Security",
      read: ["bot-management.read", "bot-management-feedback.read"],
      write: ["bot-management.write", "bot-management-feedback.write"]),
    feature(
      .apiSecurity, "API Security", "API Gateway, discovery, schema validation, and Page Shield",
      "lock.shield", "SolarShieldKeyhole", "SolarShieldKeyholeOutline", "Security",
      read: [
        "account-api-gateway.read", "api-gateway.read", "page-shield.read",
        "domain-page-shield.read", "request-tracer.read",
      ],
      write: ["account-api-gateway.write", "api-gateway.write"]),
    // Zero Trust
    feature(
      .accessApps, "Access apps", "Zero Trust application inventory", "lock.app.dashed",
      "SolarShieldUser", "SolarShieldUserOutline", "Zero Trust",
      path: "/accounts/{account}/access/apps",
      read: ["access-app.read"], write: ["access-app.write"]),
    feature(
      .accessGroups, "Access groups", "Reusable Zero Trust rule groups", "person.3",
      "SolarUsersGroupRounded", "SolarUsersGroupRoundedOutline", "Zero Trust",
      path: "/accounts/{account}/access/groups",
      read: ["access-group.read"], write: ["access-group.write"]),
    feature(
      .accessPolicies, "Access policies", "Application policies, tests, posture, and identity",
      "person.badge.shield.checkmark", "SolarShieldStar", "SolarShieldStarOutline",
      "Zero Trust",
      read: ["access-policy.read", "access-policy-test.read", "access-device-posture.read"],
      write: ["access-policy.write", "access-policy-test.write", "access-device-posture.write"]),
    feature(
      .serviceTokens, "Service tokens", "Machine credentials for Access", "key.viewfinder",
      "SolarKey", "SolarKeyOutline", "Zero Trust",
      path: "/accounts/{account}/access/service_tokens",
      read: ["access-service-token.read"], write: ["access-service-token.write"]),
    feature(
      .gatewayPolicies, "Gateway policies", "Zero Trust Gateway filtering rules",
      "shield.lefthalf.filled", "SolarShield", "SolarShieldOutline", "Zero Trust",
      path: "/accounts/{account}/gateway/rules",
      read: ["teams.read"], write: ["teams.write"]),
    feature(
      .zeroTrustConnectors, "Zero Trust connectors",
      "cloudflared, WARP, private networks, and connector health",
      "point.3.connected.trianglepath.dotted",
      "SolarGps", "SolarGpsOutline", "Zero Trust",
      read: [
        "teams-connectors.read", "teams-connector-cloudflared.read",
        "teams-connector-cloudflared.monitoring", "teams-connector-warp.read",
        "teams-networks.read",
      ],
      write: [
        "teams-connectors.write", "teams-connector-cloudflared.write",
        "teams-connector-warp.write", "teams-networks.write",
      ]),
    // Network
    feature(
      .tunnels, "Tunnels", "Cloudflare Tunnel health and connections",
      "arrow.left.arrow.right", "SolarRouting", "SolarRoutingOutline", "Network",
      path: "/accounts/{account}/cfd_tunnel",
      read: ["argotunnel.read"], write: ["argotunnel.write"]),
    feature(
      .loadBalancerPools, "LB Pools", "Load balancer origin pools", "scale.3d",
      "SolarBranchingPathsUp", "SolarBranchingPathsUpOutline", "Network",
      path: "/accounts/{account}/load_balancers/pools",
      read: ["load-balancing-monitors-and-pools.read"],
      write: ["load-balancing-monitors-and-pools.write"]),
    // Web & Performance
    feature(
      .sslCertificates, "SSL & Certificates", "Zone and account certificates, packs, and settings",
      "checkmark.shield", "SolarLockPassword", "SolarLockPasswordOutline", "Web & Performance",
      read: ["ssl-and-certificates.read", "account-ssl-and-certificates.read"],
      write: ["ssl-and-certificates.write", "account-ssl-and-certificates.write"]),
    feature(
      .cacheSettings, "Cache & Performance", "Cache settings, purge, compression, and versioning",
      "bolt.circle", "SolarBoltCircle", "SolarBoltCircleOutline", "Web & Performance",
      read: ["cache-settings.read", "response-compression.read", "zone-versioning.read"],
      write: [
        "cache-settings.write", "cache.purge", "response-compression.write",
        "zone-versioning.write",
      ]),
    // Email
    feature(
      .emailAddresses, "Email addresses", "Email Routing destination addresses", "envelope",
      "SolarLetter", "SolarLetterOutline", "Email",
      path: "/accounts/{account}/email/routing/addresses",
      read: ["email-routing-address.read"], write: ["email-routing-address.write"]),
    // Media
    feature(
      .images, "Images", "Cloudflare Images library", "photo.on.rectangle",
      "SolarGallery", "SolarGalleryOutline", "Media",
      read: ["images.read"], write: ["images.write"]),
    feature(
      .stream, "Stream", "Stream video library", "play.rectangle",
      "SolarVideoLibrary", "SolarVideoLibraryOutline", "Media",
      read: ["stream.read"], write: ["stream.write"]),
    // Analytics & Logs
    feature(
      .analytics, "Analytics", "Web analytics and RUM sites", "chart.xyaxis.line",
      "SolarChart2", "SolarChart2Outline", "Analytics & Logs",
      read: ["account-analytics.read"]),
    feature(
      .logpush, "Logpush", "Log delivery jobs to external storage",
      "square.and.arrow.up.on.square", "SolarExport", "SolarExportOutline", "Analytics & Logs",
      path: "/accounts/{account}/logpush/jobs",
      read: ["account-logs.read"], write: ["account-logs.write"]),
    // Account & Tools
    feature(
      .account, "Account", "Members, notifications, and audit logs", "person.2",
      "SolarUserCircle", "SolarUserCircleOutline", "Account & Tools",
      read: ["memberships.read", "notifications.read", "account-logs.read"],
      write: ["memberships.write", "notifications.write"]),
  ]

  private static let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })

  static let defaults: [FeatureID] = [.zones, .workers, .r2, .kv]

  static var all: [FeatureID] { descriptors.map(\.id) }

  static func descriptor(for id: FeatureID) -> FeatureDescriptor {
    guard let descriptor = byID[id] else {
      preconditionFailure("Feature \(id.rawValue) is missing from FeatureCatalog.descriptors")
    }
    return descriptor
  }

  static func sections(for features: [FeatureID]) -> [(String, [FeatureID])] {
    let order = catalogOrder
    return Dictionary(grouping: features, by: \.category)
      .map { category, items in
        (
          category,
          items.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
        )
      }
      .sorted { (order[$0.1.first!] ?? .max) < (order[$1.1.first!] ?? .max) }
  }

  static var grouped: [(String, [FeatureID])] {
    sections(for: all)
  }

  static var catalogOrder: [FeatureID: Int] {
    Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1, $0) })
  }

  static func sorted(_ features: [FeatureID]) -> [FeatureID] {
    let order = catalogOrder
    return features.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
  }

  static func matchesSearch(_ feature: FeatureID, query: String) -> Bool {
    let needle = query.localizedLowercase
    let fields = [
      feature.title,
      feature.subtitle,
      feature.rawValue,
    ].map { $0.localizedLowercase }
    return fields.contains { $0.contains(needle) }
  }

  private static func feature(
    _ id: FeatureID,
    _ title: String,
    _ subtitle: String,
    _ symbol: String,
    _ solarAssetName: String,
    _ solarOutlineAssetName: String,
    _ category: String,
    path: String? = nil,
    read: [String],
    write: [String] = []
  ) -> FeatureDescriptor {
    FeatureDescriptor(
      id: id,
      title: title,
      subtitle: subtitle,
      symbol: symbol,
      solarAssetName: solarAssetName,
      solarOutlineAssetName: solarOutlineAssetName,
      category: category,
      genericPath: path,
      capability: FeatureCapability(read: Set(read), write: Set(write))
    )
  }
}
