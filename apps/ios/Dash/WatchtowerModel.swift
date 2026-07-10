import CloudflareAPI
import Foundation

enum WatchtowerStatus: Hashable, Sendable {
  case ok
  case warning
  case critical
}

struct WatchtowerSignal: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  let detail: String
  let status: WatchtowerStatus
  let destination: Destination?
}

struct WatchtowerSummary: Hashable, Sendable {
  var critical: Int
  var warning: Int
  var ok: Int
}

enum WatchtowerAlertsStatus: Sendable {
  case loading
  case ok
  case unavailable
  case error
}

enum WatchtowerEngine {
  private static let zoneFanoutLimit = 10
  private static let expiryWarningDays = 30
  private static let expiryCriticalDays = 7

  static func load(client: CloudflareClient, accountID: String) async -> (
    signals: [WatchtowerSignal],
    alerts: [NotificationHistoryEntry],
    alertsStatus: WatchtowerAlertsStatus,
    missingScopeChecks: [String],
    failedChecks: [String]
  ) {
    async let zonesTask = fetch { try await client.listZones(accountID: accountID).items }
    async let tunnelsTask = fetch { try await client.listTunnels(accountID: accountID) }
    async let poolsTask = fetch { try await client.listLoadBalancerPools(accountID: accountID) }
    async let registrarTask = fetch { try await client.listRegistrarDomains(accountID: accountID) }
    async let pagesTask = fetch { try await client.listPagesProjects(accountID: accountID) }
    async let alertsTask = fetch { try await client.listNotificationHistory(accountID: accountID) }

    let zonesResult = await zonesTask
    let tunnelsResult = await tunnelsTask
    let poolsResult = await poolsTask
    let registrarResult = await registrarTask
    let pagesResult = await pagesTask
    let alertsResult = await alertsTask

    let zones = zonesResult.value ?? []
    let scopedZones = Array(zones.prefix(zoneFanoutLimit))
    let zonesTruncated = zones.count > zoneFanoutLimit

    let certResults = await loadZoneScoped(client: client, zones: scopedZones) {
      try await client.listCertificatePacks(zoneID: $0.id)
    }
    let healthResults = await loadZoneScoped(client: client, zones: scopedZones) {
      try await client.listHealthchecks(zoneID: $0.id)
    }

    var signals: [WatchtowerSignal] = []
    var missingScopeChecks: [String] = []
    var failedChecks: [String] = []

    if zonesResult.failed {
      recordFailure(
        "Zones", result: zonesResult, missingScopes: &missingScopeChecks, failures: &failedChecks)
    } else if let zones = zonesResult.value {
      append(&signals, zonesSignal(zones))
    }

    if tunnelsResult.failed {
      recordFailure(
        "Tunnels", result: tunnelsResult, missingScopes: &missingScopeChecks,
        failures: &failedChecks)
    } else if let tunnels = tunnelsResult.value {
      append(&signals, tunnelsSignal(tunnels))
    }

    if poolsResult.failed {
      recordFailure(
        "LB Pools", result: poolsResult, missingScopes: &missingScopeChecks,
        failures: &failedChecks)
    } else if let pools = poolsResult.value {
      append(&signals, poolsSignal(pools))
    }

    if registrarResult.failed {
      recordFailure(
        "Registrar", result: registrarResult, missingScopes: &missingScopeChecks,
        failures: &failedChecks)
    } else if let domains = registrarResult.value {
      append(&signals, registrarSignal(domains))
    }

    if pagesResult.failed {
      recordFailure(
        "Pages", result: pagesResult, missingScopes: &missingScopeChecks,
        failures: &failedChecks)
    } else if let pages = pagesResult.value {
      append(&signals, pagesSignal(pages))
    }

    if !scopedZones.isEmpty {
      if certResults.allFailed {
        if certResults.allPermissionDenied {
          missingScopeChecks.append("SSL certificates")
        } else {
          failedChecks.append("SSL certificates")
        }
      } else {
        append(&signals, certsSignal(certResults.entries, truncated: zonesTruncated))
      }

      if healthResults.allFailed {
        if healthResults.allPermissionDenied {
          missingScopeChecks.append("Healthchecks")
        } else {
          failedChecks.append("Healthchecks")
        }
      } else {
        append(&signals, healthchecksSignal(healthResults.entries, truncated: zonesTruncated))
      }
    }

    let alertsStatus: WatchtowerAlertsStatus =
      if alertsResult.failed {
        alertsResult.isPermissionDenied ? .unavailable : .error
      } else {
        .ok
      }
    if alertsResult.failed {
      recordFailure(
        "Recent alerts", result: alertsResult, missingScopes: &missingScopeChecks,
        failures: &failedChecks)
    }

    return (
      signals: signals,
      alerts: alertsResult.value ?? [],
      alertsStatus: alertsStatus,
      missingScopeChecks: missingScopeChecks,
      failedChecks: failedChecks
    )
  }

  private struct FetchResult<Value: Sendable>: Sendable {
    let value: Value?
    let errorMessage: String?
    let isPermissionDenied: Bool

    var failed: Bool { errorMessage != nil }

    static func success(_ value: Value) -> FetchResult<Value> {
      FetchResult(value: value, errorMessage: nil, isPermissionDenied: false)
    }

    static func failure(_ error: Error) -> FetchResult<Value> {
      FetchResult(
        value: nil,
        errorMessage: error.localizedDescription,
        isPermissionDenied: (error as? CloudflareAPIError)?.isPermissionDenied == true
      )
    }
  }

  private struct ZoneScopedResult<Value> {
    let entries: [(zone: CloudflareZone, items: [Value])]
    let allFailed: Bool
    let allPermissionDenied: Bool
  }

  private static func recordFailure<Value: Sendable>(
    _ name: String,
    result: FetchResult<Value>,
    missingScopes: inout [String],
    failures: inout [String]
  ) {
    if result.isPermissionDenied {
      missingScopes.append(name)
    } else {
      failures.append(name)
    }
  }

  private static func fetch<Value: Sendable>(_ operation: () async throws -> Value) async
    -> FetchResult<Value>
  {
    do { return .success(try await operation()) } catch { return .failure(error) }
  }

  private static func loadZoneScoped<Value: Sendable>(
    client: CloudflareClient,
    zones: [CloudflareZone],
    loader: @escaping (CloudflareZone) async throws -> [Value]
  ) async -> ZoneScopedResult<Value> {
    guard !zones.isEmpty else {
      return ZoneScopedResult(entries: [], allFailed: false, allPermissionDenied: false)
    }

    var entries: [(zone: CloudflareZone, items: [Value])] = []
    var failures = 0
    var permissionFailures = 0

    for zone in zones {
      do {
        entries.append((zone, try await loader(zone)))
      } catch {
        failures += 1
        if (error as? CloudflareAPIError)?.isPermissionDenied == true {
          permissionFailures += 1
        }
      }
    }

    return ZoneScopedResult(
      entries: entries,
      allFailed: failures == zones.count,
      allPermissionDenied: permissionFailures == zones.count
    )
  }

  private static func append(_ signals: inout [WatchtowerSignal], _ signal: WatchtowerSignal?) {
    if let signal { signals.append(signal) }
  }

  private static func plural(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
  }

  private static func daysUntil(_ iso: String?) -> Int? {
    guard let iso else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    let legacy = DateFormatter()
    legacy.locale = Locale(identifier: "en_US_POSIX")
    legacy.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    guard let parsed = fractional.date(from: iso) ?? plain.date(from: iso) ?? legacy.date(from: iso)
    else { return nil }
    return Int(parsed.timeIntervalSinceNow / 86_400)
  }

  private static func worstStatus(_ statuses: [WatchtowerStatus]) -> WatchtowerStatus {
    if statuses.contains(.critical) { return .critical }
    if statuses.contains(.warning) { return .warning }
    return .ok
  }

  private static func zonesSignal(_ zones: [CloudflareZone]) -> WatchtowerSignal? {
    guard !zones.isEmpty else { return nil }
    let inactive = zones.filter { ($0.status ?? "") != "active" }
    return WatchtowerSignal(
      id: "zones",
      title: "Zones",
      detail: inactive.isEmpty
        ? "All \(plural(zones.count, "zone")) active"
        : "\(plural(inactive.count, "zone")) not active",
      status: inactive.isEmpty ? .ok : .warning,
      destination: .feature(.zones)
    )
  }

  private static func tunnelsSignal(_ tunnels: [CloudflareTunnel]) -> WatchtowerSignal? {
    guard !tunnels.isEmpty else { return nil }
    let down = tunnels.filter { $0.status == "down" }.count
    let degraded = tunnels.filter { $0.status == "degraded" }.count
    let inactive = tunnels.filter { $0.status == "inactive" }.count
    let detail: String
    let status: WatchtowerStatus
    if down > 0 {
      detail = "\(plural(down, "tunnel")) down"
      status = .critical
    } else if degraded > 0 {
      detail = "\(plural(degraded, "tunnel")) degraded"
      status = .warning
    } else if inactive > 0 {
      detail = "\(tunnels.count - inactive) healthy · \(inactive) inactive"
      status = .ok
    } else {
      detail = "All \(plural(tunnels.count, "tunnel")) healthy"
      status = .ok
    }
    return WatchtowerSignal(
      id: "tunnels", title: "Tunnels", detail: detail, status: status,
      destination: .feature(.tunnels)
    )
  }

  private static func poolsSignal(_ pools: [LoadBalancerPool]) -> WatchtowerSignal? {
    guard !pools.isEmpty else { return nil }
    let disabled = pools.filter { $0.enabled == false }.count
    return WatchtowerSignal(
      id: "lb-pools",
      title: "LB Pools",
      detail: disabled > 0
        ? "\(plural(disabled, "pool")) disabled"
        : "All \(plural(pools.count, "pool")) enabled",
      status: disabled > 0 ? .warning : .ok,
      destination: .feature(.loadBalancerPools)
    )
  }

  private static func registrarSignal(_ domains: [RegistrarDomain]) -> WatchtowerSignal? {
    guard !domains.isEmpty else { return nil }
    let expiring = domains.compactMap { domain -> (RegistrarDomain, Int)? in
      guard let days = daysUntil(domain.expiresAt) else { return nil }
      return (domain, days)
    }.sorted { $0.1 < $1.1 }
    let worst = expiring.first
    let name = worst?.0.name ?? worst?.0.id ?? "A domain"
    var status: WatchtowerStatus = .ok
    var detail = plural(domains.count, "registered domain")
    if let worst {
      if worst.1 < 0 {
        status = .critical
        detail = "\(name) has expired"
      } else if worst.1 <= expiryCriticalDays {
        status = .critical
        detail = "\(name) expires in \(plural(worst.1, "day"))"
      } else if worst.1 <= expiryWarningDays {
        status = .warning
        detail = "\(name) expires in \(plural(worst.1, "day"))"
      } else {
        detail = "Next renewal in \(plural(worst.1, "day"))"
      }
    }
    return WatchtowerSignal(
      id: "registrar", title: "Registrar", detail: detail, status: status,
      destination: .feature(.registrar)
    )
  }

  private static func pagesSignal(_ projects: [PagesProject]) -> WatchtowerSignal? {
    guard !projects.isEmpty else { return nil }
    let failed = projects.filter { $0.latestDeployment?.latestStage?.status == "failure" }
    let first = failed.first
    return WatchtowerSignal(
      id: "pages",
      title: "Pages deployments",
      detail: first.map { "\($0.name): latest deployment failed" }
        ?? "All \(plural(projects.count, "project")) deployed",
      status: failed.isEmpty ? .ok : .warning,
      destination: .feature(.workers)
    )
  }

  private static func certsSignal(
    _ entries: [(zone: CloudflareZone, items: [CertificatePack])], truncated: Bool
  ) -> WatchtowerSignal? {
    let total = entries.reduce(0) { $0 + $1.items.count }
    guard total > 0 else { return nil }
    var firstProblem: (zone: CloudflareZone, desc: String, status: WatchtowerStatus)?
    var statuses: [WatchtowerStatus] = []
    for entry in entries {
      for pack in entry.items {
        guard let problem = certPackProblem(pack) else { continue }
        statuses.append(problem.status)
        if firstProblem == nil || (problem.status == .critical && firstProblem?.status != .critical)
        {
          firstProblem = (entry.zone, problem.desc, problem.status)
        }
      }
    }
    let suffix = truncated ? " · first \(zoneFanoutLimit) zones" : ""
    return WatchtowerSignal(
      id: "certificates",
      title: "SSL certificates",
      detail: firstProblem.map { "\($0.zone.name): \($0.desc)\(suffix)" }
        ?? "\(plural(total, "certificate pack")) healthy\(suffix)",
      status: statuses.isEmpty ? .ok : worstStatus(statuses),
      destination: firstProblem.map { .zone($0.zone.id) } ?? .feature(.zones)
    )
  }

  private static func certPackProblem(_ pack: CertificatePack) -> (
    desc: String, status: WatchtowerStatus
  )? {
    let status = pack.status.lowercased()
    if status.contains("failed") || status.contains("deleted") || status.contains("timed_out") {
      return ("certificate pack failed", .critical)
    }
    if status.hasPrefix("pending") || status == "initializing" {
      return ("certificate pack pending", .warning)
    }
    if let days = daysUntil(pack.certificates?.first?.expiresOn) {
      if days < 0 { return ("certificate expired", .critical) }
      if days <= expiryCriticalDays {
        return ("certificate expires in \(plural(days, "day"))", .critical)
      }
      if days <= expiryWarningDays {
        return ("certificate expires in \(plural(days, "day"))", .warning)
      }
    }
    return nil
  }

  private static func healthchecksSignal(
    _ entries: [(zone: CloudflareZone, items: [Healthcheck])], truncated: Bool
  ) -> WatchtowerSignal? {
    let total = entries.reduce(0) { $0 + $1.items.count }
    guard total > 0 else { return nil }
    var firstProblem: (zone: CloudflareZone, check: Healthcheck, status: WatchtowerStatus)?
    var statuses: [WatchtowerStatus] = []
    for entry in entries {
      for check in entry.items {
        let status: WatchtowerStatus? =
          check.status == "unhealthy" ? .critical : check.status == "suspended" ? .warning : nil
        guard let status else { continue }
        statuses.append(status)
        if firstProblem == nil || (status == .critical && firstProblem?.status != .critical) {
          firstProblem = (entry.zone, check, status)
        }
      }
    }
    let suffix = truncated ? " · first \(zoneFanoutLimit) zones" : ""
    return WatchtowerSignal(
      id: "healthchecks",
      title: "Healthchecks",
      detail: firstProblem.map {
        "\($0.check.name ?? "A healthcheck") \($0.check.status ?? "unknown") (\($0.zone.name))"
      } ?? "All \(plural(total, "healthcheck")) healthy\(suffix)",
      status: statuses.isEmpty ? .ok : worstStatus(statuses),
      destination: firstProblem.map { .zone($0.zone.id) } ?? .feature(.zones)
    )
  }
}
