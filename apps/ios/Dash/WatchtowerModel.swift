import CloudflareAPI
import Foundation
import OSLog

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
  /// Cloudflare dashboard URL when the app has no in-app screen for this check.
  var externalURL: URL? = nil
  /// When the check last observed this state.
  var observedAt: Date = .now
  /// Short remediation hint for the issues list.
  var suggestedAction: String? = nil
  /// Concrete resource label when the signal points at one item.
  var resourceName: String? = nil
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

/// Account-scoped Cloudflare dashboard deep links for Watchtower checks with no in-app screen.
enum WatchtowerDashboardLinks {
  /// Zero Trust / networks tunnels list in the Cloudflare One dashboard.
  static func tunnels(accountID: String) -> URL? {
    guard !accountID.isEmpty else { return nil }
    return URL(string: "https://one.dash.cloudflare.com/\(accountID)/networks/tunnels")
  }

  /// Account load-balancing pools in the classic Cloudflare dashboard.
  static func pools(accountID: String) -> URL? {
    guard !accountID.isEmpty else { return nil }
    return URL(
      string: "https://dash.cloudflare.com/\(accountID)/traffic/load-balancing/pools")
  }

  /// Account registrar / domains list in the classic Cloudflare dashboard.
  static func registrar(accountID: String) -> URL? {
    guard !accountID.isEmpty else { return nil }
    return URL(string: "https://dash.cloudflare.com/\(accountID)/domains")
  }
}

enum WatchtowerEngine {
  typealias LoadResult = (
    signals: [WatchtowerSignal],
    alerts: [NotificationHistoryEntry],
    alertsStatus: WatchtowerAlertsStatus,
    missingScopeChecks: [String],
    failedChecks: [String]
  )

  static let zoneFanoutLimit = 10
  static let zonePageSize = 50
  static let coverageSignalID = "zone-coverage"
  static var coverageSignalTitle: String { DashL10n.string("Domain coverage") }
  private static let expiryWarningDays = 30
  private static let expiryCriticalDays = 7

  /// Makes any bounded or incomplete zone fan-out visible. This is a trust
  /// signal, not an outage: it explains exactly what the latest refresh did not
  /// establish before healthy rows can read as account-wide reassurance.
  static func coverageSignal(
    totalZones: Int,
    checkedLimit: Int = zoneFanoutLimit,
    certificateChecks: ZoneScopedResult<CertificatePack>? = nil,
    healthcheckChecks: ZoneScopedResult<Healthcheck>? = nil
  ) -> WatchtowerSignal? {
    var details: [String] = []

    if totalZones > checkedLimit {
      let uncovered = totalZones - checkedLimit
      details.append(
        DashL10n.string(
          "Certificates & healthchecks checked the first \(checkedLimit) of \(totalZones) domains; \(uncovered) of \(totalZones) domains were outside this refresh"
        ))
    }
    if let certificateChecks, certificateChecks.failedCount > 0 {
      details.append(
        DashL10n.string(
          "Certificate checks completed for \(certificateChecks.checkedCount) of \(certificateChecks.attemptedCount) domains"
        ))
    }
    if let healthcheckChecks, healthcheckChecks.failedCount > 0 {
      details.append(
        DashL10n.string(
          "Healthchecks completed for \(healthcheckChecks.checkedCount) of \(healthcheckChecks.attemptedCount) domains"
        ))
    }

    guard !details.isEmpty else { return nil }
    return WatchtowerSignal(
      id: coverageSignalID,
      title: coverageSignalTitle,
      detail: details.joined(separator: " · "),
      status: .warning,
      destination: .feature(.zones),
      suggestedAction: DashL10n.string(
        "Refresh to retry incomplete checks, or open Domains to review coverage")
    )
  }

  static func zonesForFanout(_ zones: [CloudflareZone]) -> [CloudflareZone] {
    Array(zones.prefix(zoneFanoutLimit))
  }

  static func loadCancellable(client: CloudflareClient, accountID: String) async throws
    -> LoadResult
  {
    let signpostID = DashPerformance.signposter.makeSignpostID()
    let interval = DashPerformance.signposter.beginInterval(
      "WatchtowerRefresh", id: signpostID)
    defer {
      DashPerformance.signposter.endInterval("WatchtowerRefresh", interval)
    }

    async let zonesTask = fetch {
      try await DashPageLoader.loadAll(pageSize: zonePageSize, id: \.id) { page, perPage in
        try await client.listZones(accountID: accountID, page: page, perPage: perPage)
      }
    }
    async let tunnelsTask = fetch { try await client.listTunnels(accountID: accountID) }
    async let poolsTask = fetch { try await client.listLoadBalancerPools(accountID: accountID) }
    async let registrarTask = fetch { try await client.listRegistrarDomains(accountID: accountID) }
    async let pagesTask = fetch { try await client.listPagesProjects(accountID: accountID) }
    async let alertsTask = fetch { try await client.listNotificationHistory(accountID: accountID) }

    let (
      zonesResult,
      tunnelsResult,
      poolsResult,
      registrarResult,
      pagesResult,
      alertsResult
    ) = try await (
      zonesTask,
      tunnelsTask,
      poolsTask,
      registrarTask,
      pagesTask,
      alertsTask
    )

    let zones = zonesResult.value ?? []
    let scopedZones = zonesForFanout(zones)
    let zonesTruncated = zones.count > zoneFanoutLimit

    let zoneChecks = try await loadZoneChecks(
      zones: scopedZones,
      certificateLoader: { try await client.listCertificatePacks(zoneID: $0.id) },
      healthcheckLoader: { try await client.listHealthchecks(zoneID: $0.id) })
    let certResults = zoneChecks.certificates
    let healthResults = zoneChecks.healthchecks

    var signals: [WatchtowerSignal] = []
    var missingScopeChecks: [String] = []
    var failedChecks: [String] = []

    if zonesResult.failed {
      recordFailure(
        DashL10n.string("Domains"), result: zonesResult,
        missingScopes: &missingScopeChecks, failures: &failedChecks)
    } else if let zones = zonesResult.value {
      append(&signals, zonesSignal(zones))
    }

    if tunnelsResult.failed {
      recordFailure(
        DashL10n.string("Tunnels"), result: tunnelsResult, missingScopes: &missingScopeChecks,
        failures: &failedChecks)
    } else if let tunnels = tunnelsResult.value {
      append(&signals, tunnelsSignal(tunnels, accountID: accountID))
    }

    if poolsResult.failed {
      recordFailure(
        DashL10n.string("LB Pools"), result: poolsResult, missingScopes: &missingScopeChecks,
        failures: &failedChecks)
    } else if let pools = poolsResult.value {
      append(&signals, poolsSignal(pools, accountID: accountID))
    }

    if registrarResult.failed {
      recordFailure(
        DashL10n.string("Registrar"), result: registrarResult, missingScopes: &missingScopeChecks,
        failures: &failedChecks)
    } else if let domains = registrarResult.value {
      append(&signals, registrarSignal(domains, accountID: accountID))
    }

    if pagesResult.failed {
      recordFailure(
        DashL10n.string("Pages"), result: pagesResult, missingScopes: &missingScopeChecks,
        failures: &failedChecks)
    } else if let pages = pagesResult.value {
      append(&signals, pagesSignal(pages))
    }

    if !scopedZones.isEmpty {
      recordZoneFailures(
        DashL10n.string("SSL certificates"),
        result: certResults,
        missingScopes: &missingScopeChecks,
        failures: &failedChecks)
      if !certResults.allFailed {
        append(&signals, certsSignal(certResults.entries, truncated: zonesTruncated))
      }

      recordZoneFailures(
        DashL10n.string("Healthchecks"),
        result: healthResults,
        missingScopes: &missingScopeChecks,
        failures: &failedChecks)
      if !healthResults.allFailed {
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
        DashL10n.string("Recent alerts"), result: alertsResult,
        missingScopes: &missingScopeChecks,
        failures: &failedChecks)
    }

    if !zonesResult.failed {
      append(
        &signals,
        coverageSignal(
          totalZones: zones.count,
          certificateChecks: scopedZones.isEmpty ? nil : certResults,
          healthcheckChecks: scopedZones.isEmpty ? nil : healthResults))
    }
    try Task.checkCancellation()

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

  struct ZoneScopedResult<Value: Sendable>: Sendable {
    let entries: [(zone: CloudflareZone, items: [Value])]
    let attemptedCount: Int
    let failedCount: Int
    let permissionDeniedCount: Int

    var checkedCount: Int { max(0, attemptedCount - failedCount) }
    var allFailed: Bool { attemptedCount > 0 && failedCount == attemptedCount }
  }

  struct ZoneChecksLoadResult: Sendable {
    let certificates: ZoneScopedResult<CertificatePack>
    let healthchecks: ZoneScopedResult<Healthcheck>
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

  private static func recordZoneFailures<Value: Sendable>(
    _ name: String,
    result: ZoneScopedResult<Value>,
    missingScopes: inout [String],
    failures: inout [String]
  ) {
    guard result.failedCount > 0 else { return }
    if result.permissionDeniedCount > 0 {
      missingScopes.append(
        DashL10n.string(
          "\(name) (\(result.permissionDeniedCount) of \(result.attemptedCount) domains)"
        ))
    }
    let unavailableCount = result.failedCount - result.permissionDeniedCount
    if unavailableCount > 0 {
      failures.append(
        DashL10n.string(
          "\(name) (\(result.checkedCount) of \(result.attemptedCount) domains checked)"
        ))
    }
  }

  private static func fetch<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> FetchResult<Value> {
    do {
      return .success(try await operation())
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      if Task.isCancelled { throw CancellationError() }
      return .failure(error)
    }
  }

  /// One global window shared by certificate and healthcheck requests. Running
  /// two independent four-wide groups would burst eight account requests.
  static let zoneScopedConcurrency = 4

  static func loadZoneChecks(
    zones: [CloudflareZone],
    certificateLoader: @escaping @Sendable (CloudflareZone) async throws -> [CertificatePack],
    healthcheckLoader: @escaping @Sendable (CloudflareZone) async throws -> [Healthcheck]
  ) async throws -> ZoneChecksLoadResult {
    guard !zones.isEmpty else {
      return ZoneChecksLoadResult(
        certificates: ZoneScopedResult(
          entries: [], attemptedCount: 0, failedCount: 0, permissionDeniedCount: 0),
        healthchecks: ZoneScopedResult(
          entries: [], attemptedCount: 0, failedCount: 0, permissionDeniedCount: 0))
    }

    var certificateSlots: [(zone: CloudflareZone, items: [CertificatePack])?] = Array(
      repeating: nil, count: zones.count)
    var healthcheckSlots: [(zone: CloudflareZone, items: [Healthcheck])?] = Array(
      repeating: nil, count: zones.count)
    var certificateFailures = 0
    var certificatePermissionFailures = 0
    var healthcheckFailures = 0
    var healthcheckPermissionFailures = 0
    let work = zones.enumerated().flatMap { index, zone in
      [
        ZoneCheckWork.certificates(index, zone),
        ZoneCheckWork.healthchecks(index, zone),
      ]
    }

    try await withThrowingTaskGroup(of: ZoneCheckTaskResult.self) { group in
      var nextIndex = 0
      func addNext() {
        guard nextIndex < work.count else { return }
        let item = work[nextIndex]
        nextIndex += 1
        switch item {
        case .certificates(let index, let zone):
          group.addTask {
            .certificates(
              index,
              try await captureZoneScoped {
                try await certificateLoader(zone)
              })
          }
        case .healthchecks(let index, let zone):
          group.addTask {
            .healthchecks(
              index,
              try await captureZoneScoped {
                try await healthcheckLoader(zone)
              })
          }
        }
      }

      for _ in 0..<min(zoneScopedConcurrency, work.count) { addNext() }
      while let result = try await group.next() {
        switch result {
        case .certificates(let index, let result):
          switch result {
          case .success(let items):
            certificateSlots[index] = (zones[index], items)
          case .failure(let failure):
            certificateFailures += 1
            if failure.isPermissionDenied {
              certificatePermissionFailures += 1
            }
          }
        case .healthchecks(let index, let result):
          switch result {
          case .success(let items):
            healthcheckSlots[index] = (zones[index], items)
          case .failure(let failure):
            healthcheckFailures += 1
            if failure.isPermissionDenied {
              healthcheckPermissionFailures += 1
            }
          }
        }
        addNext()
      }
    }

    return ZoneChecksLoadResult(
      certificates: ZoneScopedResult(
        entries: certificateSlots.compactMap { $0 },
        attemptedCount: zones.count,
        failedCount: certificateFailures,
        permissionDeniedCount: certificatePermissionFailures),
      healthchecks: ZoneScopedResult(
        entries: healthcheckSlots.compactMap { $0 },
        attemptedCount: zones.count,
        failedCount: healthcheckFailures,
        permissionDeniedCount: healthcheckPermissionFailures)
    )
  }

  private static func captureZoneScoped<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> [Value]
  ) async throws -> Result<[Value], ZoneScopedFailure> {
    do {
      return .success(try await operation())
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      if Task.isCancelled { throw CancellationError() }
      return .failure(
        ZoneScopedFailure(
          isPermissionDenied: (error as? CloudflareAPIError)?.isPermissionDenied == true))
    }
  }

  private enum ZoneCheckWork: Sendable {
    case certificates(Int, CloudflareZone)
    case healthchecks(Int, CloudflareZone)
  }

  private enum ZoneCheckTaskResult: Sendable {
    case certificates(Int, Result<[CertificatePack], ZoneScopedFailure>)
    case healthchecks(Int, Result<[Healthcheck], ZoneScopedFailure>)
  }

  private struct ZoneScopedFailure: Error, Sendable {
    let isPermissionDenied: Bool
  }

  private static func append(_ signals: inout [WatchtowerSignal], _ signal: WatchtowerSignal?) {
    if let signal { signals.append(signal) }
  }

  private static func domainCount(_ count: Int) -> String {
    count == 1 ? DashL10n.string("1 domain") : DashL10n.string("\(count) domains")
  }

  private static func tunnelCount(_ count: Int) -> String {
    count == 1 ? DashL10n.string("1 tunnel") : DashL10n.string("\(count) tunnels")
  }

  private static func poolCount(_ count: Int) -> String {
    count == 1 ? DashL10n.string("1 pool") : DashL10n.string("\(count) pools")
  }

  private static func registeredDomainCount(_ count: Int) -> String {
    count == 1
      ? DashL10n.string("1 registered domain")
      : DashL10n.string("\(count) registered domains")
  }

  private static func dayCount(_ count: Int) -> String {
    count == 1 ? DashL10n.string("1 day") : DashL10n.string("\(count) days")
  }

  private static func projectCount(_ count: Int) -> String {
    count == 1 ? DashL10n.string("1 project") : DashL10n.string("\(count) projects")
  }

  private static func certificatePackCount(_ count: Int) -> String {
    count == 1
      ? DashL10n.string("1 certificate pack")
      : DashL10n.string("\(count) certificate packs")
  }

  private static func healthcheckCount(_ count: Int) -> String {
    count == 1
      ? DashL10n.string("1 healthcheck") : DashL10n.string("\(count) healthchecks")
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
    let first = inactive.first
    return WatchtowerSignal(
      id: "zones",
      title: DashL10n.string("Domains"),
      detail: inactive.isEmpty
        ? DashL10n.string("All \(domainCount(zones.count)) active")
        : DashL10n.string("\(domainCount(inactive.count)) not active"),
      status: inactive.isEmpty ? .ok : .warning,
      destination: first.map { .zone($0.id) } ?? .feature(.zones),
      suggestedAction: inactive.isEmpty
        ? nil : DashL10n.string("Open domain settings and confirm DNS / plan status"),
      resourceName: first?.name
    )
  }

  /// Builds the tunnels health signal. Package-visible for focused unit tests.
  static func tunnelsSignal(_ tunnels: [CloudflareTunnel], accountID: String)
    -> WatchtowerSignal?
  {
    guard !tunnels.isEmpty else { return nil }
    let problem = tunnels.first { $0.status == "down" || $0.status == "degraded" }
    let down = tunnels.filter { $0.status == "down" }.count
    let degraded = tunnels.filter { $0.status == "degraded" }.count
    let inactive = tunnels.filter { $0.status == "inactive" }.count
    let detail: String
    let status: WatchtowerStatus
    if down > 0 {
      detail = DashL10n.string("\(tunnelCount(down)) down")
      status = .critical
    } else if degraded > 0 {
      detail = DashL10n.string("\(tunnelCount(degraded)) degraded")
      status = .warning
    } else if inactive > 0 {
      detail = DashL10n.string("\(tunnels.count - inactive) healthy · \(inactive) inactive")
      status = .ok
    } else {
      detail = DashL10n.string("All \(tunnelCount(tunnels.count)) healthy")
      status = .ok
    }
    return WatchtowerSignal(
      id: "tunnels", title: DashL10n.string("Tunnels"), detail: detail, status: status,
      // No in-app tunnel screen; open Cloudflare One for the next step.
      destination: nil,
      externalURL: WatchtowerDashboardLinks.tunnels(accountID: accountID),
      suggestedAction: status == .ok
        ? nil : DashL10n.string("Check cloudflared and reconnect the tunnel"),
      resourceName: problem?.name
    )
  }

  private static func poolsSignal(_ pools: [LoadBalancerPool], accountID: String)
    -> WatchtowerSignal?
  {
    guard !pools.isEmpty else { return nil }
    let disabledPools = pools.filter { $0.enabled == false }
    let disabled = disabledPools.count
    return WatchtowerSignal(
      id: "lb-pools",
      title: DashL10n.string("LB Pools"),
      detail: disabled > 0
        ? DashL10n.string("\(poolCount(disabled)) disabled")
        : DashL10n.string("All \(poolCount(pools.count)) enabled"),
      status: disabled > 0 ? .warning : .ok,
      destination: nil,
      externalURL: WatchtowerDashboardLinks.pools(accountID: accountID),
      suggestedAction: disabled > 0
        ? DashL10n.string("Re-enable the pool or remove it from the load balancer") : nil,
      resourceName: disabledPools.first?.name
    )
  }

  private static func registrarSignal(_ domains: [RegistrarDomain], accountID: String)
    -> WatchtowerSignal?
  {
    guard !domains.isEmpty else { return nil }
    let expiring = domains.compactMap { domain -> (RegistrarDomain, Int)? in
      guard let days = daysUntil(domain.expiresAt) else { return nil }
      return (domain, days)
    }.sorted { $0.1 < $1.1 }
    let worst = expiring.first
    let name = worst?.0.name ?? worst?.0.id ?? DashL10n.string("A domain")
    var status: WatchtowerStatus = .ok
    var detail = registeredDomainCount(domains.count)
    if let worst {
      if worst.1 < 0 {
        status = .critical
        detail = DashL10n.string("\(name) has expired")
      } else if worst.1 <= expiryCriticalDays {
        status = .critical
        detail = DashL10n.string("\(name) expires in \(dayCount(worst.1))")
      } else if worst.1 <= expiryWarningDays {
        status = .warning
        detail = DashL10n.string("\(name) expires in \(dayCount(worst.1))")
      } else {
        detail = DashL10n.string("Next renewal in \(dayCount(worst.1))")
      }
    }
    return WatchtowerSignal(
      id: "registrar", title: DashL10n.string("Registrar"), detail: detail, status: status,
      destination: nil,
      externalURL: WatchtowerDashboardLinks.registrar(accountID: accountID),
      suggestedAction: status == .ok
        ? nil : DashL10n.string("Renew the domain before it expires"),
      resourceName: worst?.0.name
    )
  }

  private static func pagesSignal(_ projects: [PagesProject]) -> WatchtowerSignal? {
    guard !projects.isEmpty else { return nil }
    let failed = projects.filter { $0.latestDeployment?.latestStage?.status == "failure" }
    let first = failed.first
    return WatchtowerSignal(
      id: "pages",
      title: DashL10n.string("Pages deployments"),
      detail: first.map { DashL10n.string("\($0.name): latest deployment failed") }
        ?? DashL10n.string("All \(projectCount(projects.count)) deployed"),
      status: failed.isEmpty ? .ok : .warning,
      destination: first.map { .pagesProject($0.name) } ?? .feature(.pages),
      suggestedAction: failed.isEmpty
        ? nil : DashL10n.string("Open the project to retry or inspect the log"),
      resourceName: first?.name
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
    let suffix = truncated ? DashL10n.string(" · first \(zoneFanoutLimit) domains") : ""
    return WatchtowerSignal(
      id: "certificates",
      title: DashL10n.string("SSL certificates"),
      detail: firstProblem.map { "\($0.zone.name): \($0.desc)\(suffix)" }
        ?? DashL10n.string("\(certificatePackCount(total)) healthy\(suffix)"),
      status: statuses.isEmpty ? .ok : worstStatus(statuses),
      destination: firstProblem.map { .zone($0.zone.id) } ?? .feature(.zones),
      suggestedAction: firstProblem == nil
        ? nil : DashL10n.string("Open the domain SSL settings and renew or reissue the pack"),
      resourceName: firstProblem?.zone.name
    )
  }

  private static func certPackProblem(_ pack: CertificatePack) -> (
    desc: String, status: WatchtowerStatus
  )? {
    let status = pack.status.lowercased()
    if status.contains("failed") || status.contains("deleted") || status.contains("timed_out") {
      return (DashL10n.string("Certificate pack failed"), .critical)
    }
    if status.hasPrefix("pending") || status == "initializing" {
      return (DashL10n.string("Certificate pack pending"), .warning)
    }
    if let days = daysUntil(pack.certificates?.first?.expiresOn) {
      if days < 0 { return (DashL10n.string("Certificate expired"), .critical) }
      if days <= expiryCriticalDays {
        return (DashL10n.string("Certificate expires in \(dayCount(days))"), .critical)
      }
      if days <= expiryWarningDays {
        return (DashL10n.string("Certificate expires in \(dayCount(days))"), .warning)
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
    let suffix = truncated ? DashL10n.string(" · first \(zoneFanoutLimit) domains") : ""
    return WatchtowerSignal(
      id: "healthchecks",
      title: DashL10n.string("Healthchecks"),
      detail: firstProblem.map {
        DashL10n.string(
          "\($0.check.name ?? DashL10n.string("A healthcheck")) \($0.check.status ?? DashL10n.string("unknown")) (\($0.zone.name))"
        )
      } ?? DashL10n.string("All \(healthcheckCount(total)) healthy\(suffix)"),
      status: statuses.isEmpty ? .ok : worstStatus(statuses),
      destination: firstProblem.map { .zone($0.zone.id) } ?? .feature(.zones),
      suggestedAction: firstProblem == nil
        ? nil : DashL10n.string("Inspect the origin and resume or fix the failing healthcheck"),
      resourceName: firstProblem?.check.name ?? firstProblem?.zone.name
    )
  }
}
