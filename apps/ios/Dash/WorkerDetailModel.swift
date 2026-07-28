import CloudflareAPI
import Foundation
import OSLog

/// The read-only API surface needed to assemble Worker detail. Keeping the
/// loader behind this narrow protocol makes concurrency, cancellation, and
/// partial-failure behavior testable without constructing an `AppModel`.
protocol WorkerDetailClient: Sendable {
  func getWorkerSubdomain(accountID: String, name: String) async throws -> WorkerSubdomainStatus
  func getWorkersAccountSubdomain(accountID: String) async throws -> WorkersAccountSubdomain
  func listWorkerDeployments(accountID: String, scriptName: String) async throws
    -> [WorkerDeploymentSummary]
  func workerAnalytics(accountID: String, scriptName: String, hours: Int) async throws
    -> WorkerAnalyticsPayload
  func listWorkerDomains(accountID: String, service: String?) async throws -> [WorkerDomain]
  func listZones(accountID: String, page: Int, perPage: Int, name: String?) async throws
    -> Page<CloudflareZone>
  func listWorkerRoutes(zoneID: String) async throws -> [WorkerRoute]
}

extension CloudflareClient: WorkerDetailClient {}

/// One zone's route joined with its zone name for display. The detail loader
/// owns this domain value; the SwiftUI layer only renders it.
struct WorkerZoneRoute: Identifiable, Hashable, Sendable {
  let id: String
  let pattern: String
  let script: String?
  let zoneName: String
}

enum WorkerDetailSection<Value: Sendable>: Sendable {
  case success(Value)
  case failure(String)

  var value: Value? {
    guard case .success(let value) = self else { return nil }
    return value
  }

  var failureMessage: String? {
    guard case .failure(let message) = self else { return nil }
    return message
  }
}

struct WorkerRoutesLoad: Sendable {
  var routes: [WorkerZoneRoute]
  var isComplete: Bool
  var failureMessage: String?
}

/// A cacheable Worker detail payload. It exists only when every independent
/// request, including every zone route request, completed successfully.
///
/// Storing this value under one key makes the cache write atomic: a partial
/// response remains useful to the current view but never becomes a warm
/// snapshot for a later visit.
struct WorkerDetailSnapshot: Hashable, Sendable {
  let subdomainEnabled: Bool
  let workersDevHostname: String
  let deployments: [WorkerDeploymentSummary]
  let analytics: WorkerAnalyticsPayload
  let domains: [WorkerDomain]
  let routes: [WorkerZoneRoute]

  static func cacheKey(accountID: String, name: String) -> String {
    "workerDetail:\(accountID):\(name)"
  }

  static func primaryLoadKey(accountID: String, name: String) -> String {
    "\(cacheKey(accountID: accountID, name: name)):primary"
  }

}

/// Cache invalidation for one Worker detail. Account-wide routes are
/// deliberately not part of this operation: discovering them fans out across
/// every zone and a pull-to-refresh on one Worker must not trigger that scan.
@MainActor
enum WorkerDetailCache {
  static func invalidate(
    _ cache: FeatureDataCache,
    accountID: String,
    name: String
  ) {
    cache.remove(WorkerDetailSnapshot.cacheKey(accountID: accountID, name: name))
    cache.remove(WorkerDetailSnapshot.primaryLoadKey(accountID: accountID, name: name))
  }
}

struct WorkerDetailLoadResult: Sendable {
  let subdomain: WorkerDetailSection<Bool>
  let workersDevHostname: WorkerDetailSection<String>
  let deployments: WorkerDetailSection<[WorkerDeploymentSummary]>
  let analytics: WorkerDetailSection<WorkerAnalyticsPayload>
  let domains: WorkerDetailSection<[WorkerDomain]>

  func completeSnapshot(routes: WorkerRoutesLoad) -> WorkerDetailSnapshot? {
    guard
      let subdomainEnabled = subdomain.value,
      let workersDevHostname = workersDevHostname.value,
      let deployments = deployments.value,
      let analytics = analytics.value,
      let domains = domains.value,
      routes.isComplete
    else { return nil }

    return WorkerDetailSnapshot(
      subdomainEnabled: subdomainEnabled,
      workersDevHostname: workersDevHostname,
      deployments: deployments,
      analytics: analytics,
      domains: domains,
      routes: routes.routes)
  }
}

extension WorkerRoutesLoad {
  /// A failed refresh must not erase routes already painted from a complete
  /// warm snapshot. Cold loads can still show the useful subset they found.
  func presentedRoutes(
    for scriptName: String,
    preserving current: [WorkerZoneRoute]
  ) -> [WorkerZoneRoute] {
    let fetched = routes.filter { $0.script == scriptName }
    return isComplete || current.isEmpty ? fetched : current
  }
}

enum WorkerDetailLoader {
  static let routeConcurrencyLimit = 4
  static let zonePageSize = 50

  /// Starts every independent top-level request before awaiting any of them.
  /// Ordinary request failures are retained per section for progressive UI;
  /// cancellation always leaves the loader.
  static func load(
    client: any WorkerDetailClient,
    accountID: String,
    name: String
  ) async throws -> WorkerDetailLoadResult {
    let signpostID = DashPerformance.signposter.makeSignpostID()
    let interval = DashPerformance.signposter.beginInterval(
      "WorkerDetailLoad", id: signpostID)
    defer {
      DashPerformance.signposter.endInterval("WorkerDetailLoad", interval)
    }

    async let subdomainTask = capture {
      try await client.getWorkerSubdomain(accountID: accountID, name: name).enabled
    }
    async let hostnameTask = capture {
      try await client.getWorkersAccountSubdomain(accountID: accountID).hostname(forScript: name)
    }
    async let deploymentsTask = capture {
      try await client.listWorkerDeployments(accountID: accountID, scriptName: name)
    }
    async let analyticsTask = capture {
      try await client.workerAnalytics(accountID: accountID, scriptName: name, hours: 24)
    }
    async let domainsTask = capture {
      try await client.listWorkerDomains(accountID: accountID, service: name)
    }

    let (
      subdomain,
      workersDevHostname,
      deployments,
      analytics,
      domains
    ) = try await (
      subdomainTask,
      hostnameTask,
      deploymentsTask,
      analyticsTask,
      domainsTask
    )
    try Task.checkCancellation()

    return WorkerDetailLoadResult(
      subdomain: subdomain,
      workersDevHostname: workersDevHostname,
      deployments: deployments,
      analytics: analytics,
      domains: domains)
  }

  private static func capture<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> WorkerDetailSection<Value> {
    do {
      return .success(try await operation())
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      if Task.isCancelled { throw CancellationError() }
      return .failure(error.dashActionableMessage)
    }
  }

  static func loadRoutes(
    client: any WorkerDetailClient,
    accountID: String
  ) async throws -> WorkerRoutesLoad {
    let signpostID = DashPerformance.signposter.makeSignpostID()
    let interval = DashPerformance.signposter.beginInterval(
      "WorkerRoutesLoad", id: signpostID)
    defer {
      DashPerformance.signposter.endInterval("WorkerRoutesLoad", interval)
    }

    let zones: [CloudflareZone]
    do {
      zones = try await DashPageLoader.loadAll(pageSize: zonePageSize, id: \.id) {
        page,
        perPage in
        try await client.listZones(
          accountID: accountID, page: page, perPage: perPage, name: nil)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      if Task.isCancelled { throw CancellationError() }
      return WorkerRoutesLoad(
        routes: [], isComplete: false, failureMessage: error.dashActionableMessage)
    }

    guard !zones.isEmpty else {
      return WorkerRoutesLoad(routes: [], isComplete: true, failureMessage: nil)
    }

    var slots = [[WorkerZoneRoute]?](repeating: nil, count: zones.count)
    var failureMessages = [String?](repeating: nil, count: zones.count)

    try await withThrowingTaskGroup(of: RouteTaskResult.self) { group in
      var nextIndex = 0

      func addNext() {
        guard nextIndex < zones.count else { return }
        let index = nextIndex
        let zone = zones[index]
        nextIndex += 1
        group.addTask {
          do {
            let routes = try await client.listWorkerRoutes(zoneID: zone.id)
            return .success(
              index,
              routes.map {
                WorkerZoneRoute(
                  id: $0.id, pattern: $0.pattern, script: $0.script, zoneName: zone.name)
              })
          } catch is CancellationError {
            throw CancellationError()
          } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
          } catch {
            if Task.isCancelled { throw CancellationError() }
            return .failure(index, error.dashActionableMessage)
          }
        }
      }

      for _ in 0..<min(routeConcurrencyLimit, zones.count) { addNext() }
      while let result = try await group.next() {
        switch result {
        case .success(let index, let routes):
          slots[index] = routes
        case .failure(let index, let message):
          failureMessages[index] = message
        }
        addNext()
      }
    }

    let routes = slots.compactMap { $0 }.flatMap { $0 }.sorted {
      if $0.pattern == $1.pattern { return $0.zoneName < $1.zoneName }
      return $0.pattern < $1.pattern
    }
    let failures = failureMessages.compactMap { $0 }
    return WorkerRoutesLoad(
      routes: routes,
      isComplete: failures.isEmpty,
      failureMessage: failures.first)
  }

  private enum RouteTaskResult: Sendable {
    case success(Int, [WorkerZoneRoute])
    case failure(Int, String)
  }
}
