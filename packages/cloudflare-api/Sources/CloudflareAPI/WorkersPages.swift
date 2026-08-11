import Foundation

/// Custom hostname routed to a Worker via `/accounts/.../workers/domains`.
/// OpenAPI `x-api-token-group` is Workers Scripts Read/Write — same scopes as
/// script management, not `workers-routes.*`.
public struct WorkerDomain: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let hostname: String
  public let service: String
  public let zoneID: String
  public let zoneName: String
  public let certID: String?
  public let environment: String?

  enum CodingKeys: String, CodingKey {
    case id, hostname, service, environment
    case zoneID = "zone_id"
    case zoneName = "zone_name"
    case certID = "cert_id"
  }

  public init(
    id: String, hostname: String, service: String, zoneID: String, zoneName: String,
    certID: String? = nil, environment: String? = nil
  ) {
    self.id = id
    self.hostname = hostname
    self.service = service
    self.zoneID = zoneID
    self.zoneName = zoneName
    self.certID = certID
    self.environment = environment
  }
}

/// Zone-scoped route pattern mapped to a Worker via `/zones/.../workers/routes`.
/// The second way a hostname reaches a Worker besides `WorkerDomain`; wrangler
/// `routes` entries without `custom_domain = true` land here. OpenAPI
/// `x-api-token-group` is Workers Routes — `workers-routes.*`, not the
/// script-management scopes. `script` is nil when the route is disabled.
public struct WorkerRoute: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let pattern: String
  public let script: String?

  public init(id: String, pattern: String, script: String? = nil) {
    self.id = id
    self.pattern = pattern
    self.script = script
  }
}

public struct WorkerScript: CloudflareResource, Hashable {
  public let id: String
  public var name: String { id }
  /// Immutable script tag — the `external_script_id` the Builds APIs key on.
  public let tag: String?
  public let modifiedOn: String?
  public let createdOn: String?

  enum CodingKeys: String, CodingKey {
    case id, tag
    case modifiedOn = "modified_on"
    case createdOn = "created_on"
  }
}

/// What a Workers Build was built from — branch, commit, and the commands the
/// trigger ran.
public struct WorkerBuildTriggerMetadata: Codable, Hashable, Sendable {
  public let branch: String?
  public let commitHash: String?
  public let commitMessage: String?
  public let author: String?
  public let buildCommand: String?
  public let deployCommand: String?
  public let buildTriggerSource: String?

  /// Seven characters, the length every git UI settled on.
  public var shortCommit: String? {
    commitHash.map { String($0.prefix(7)) }
  }

  enum CodingKeys: String, CodingKey {
    case branch, author
    case commitHash = "commit_hash"
    case commitMessage = "commit_message"
    case buildCommand = "build_command"
    case deployCommand = "deploy_command"
    case buildTriggerSource = "build_trigger_source"
  }
}

/// One build from Workers Builds
/// (`GET /accounts/{id}/builds/workers/{external_script_id}/builds`).
///
/// Every field is optional because Cloudflare's schema marks every field
/// optional — including `status` and `build_uuid`. Nothing here may assume a
/// field arrived.
public struct WorkerBuild: Codable, Hashable, Identifiable, Sendable {
  public let buildUUID: String?
  /// Cloudflare documents no enum for this. Read it through `phase`, never by
  /// comparing raw strings at a call site.
  public let status: String?
  public let buildOutcome: String?
  public let createdOn: String?
  public let initializingOn: String?
  public let runningOn: String?
  public let stoppedOn: String?
  public let modifiedOn: String?
  public let buildTriggerMetadata: WorkerBuildTriggerMetadata?

  public var id: String { buildUUID ?? createdOn ?? UUID().uuidString }

  public var shortID: String {
    buildUUID.map { String($0.prefix(8)) } ?? "—"
  }

  enum CodingKeys: String, CodingKey {
    case status
    case buildUUID = "build_uuid"
    case buildOutcome = "build_outcome"
    case createdOn = "created_on"
    case initializingOn = "initializing_on"
    case runningOn = "running_on"
    case stoppedOn = "stopped_on"
    case modifiedOn = "modified_on"
    case buildTriggerMetadata = "build_trigger_metadata"
  }
}

extension WorkerBuild {
  /// Where a build sits in its lifecycle.
  public enum Phase: Equatable, Sendable {
    case queued
    case initializing
    case running
    case finished
  }

  /// Cloudflare publishes no enum for `status`, so this reads the lifecycle from
  /// the *timestamps*, which are unambiguous, and uses `status` only to spot a
  /// queued build that has no timestamp yet.
  ///
  /// The bias is deliberate: anything not positively recognised as in-flight
  /// counts as `finished`. A Live Activity that fails to start is a missing
  /// nicety; one pinned to the Lock Screen by an unrecognised status is a bug
  /// the user can only clear by force-quitting the app.
  public var phase: Phase {
    if stoppedOn != nil || buildOutcome != nil { return .finished }
    if runningOn != nil { return .running }
    if initializingOn != nil { return .initializing }
    guard let status = status?.lowercased() else { return .finished }
    // Only these two are known-live without a timestamp to prove it.
    return status == "queued" || status == "pending" ? .queued : .finished
  }

  public var isInProgress: Bool { phase != .finished }

  /// True only when Cloudflare said the build failed. An absent outcome is
  /// unknown, not success — a build can stop without one.
  public var didFail: Bool {
    guard let outcome = buildOutcome?.lowercased() else { return false }
    return outcome != "success"
  }
}

/// `GET /accounts/{id}/builds/builds/latest?external_script_ids=…` returns the
/// newest build per script, keyed by script tag.
public struct WorkerLatestBuilds: Codable, Sendable {
  public let builds: [String: WorkerBuild]?
}

public struct WorkerSubdomainStatus: Codable, Hashable, Sendable {
  public let enabled: Bool
  public let previewsEnabled: Bool?

  enum CodingKeys: String, CodingKey {
    case enabled
    case previewsEnabled = "previews_enabled"
  }
}

/// Account-wide `workers.dev` label from
/// `GET /accounts/{account_id}/workers/subdomain`. Script URLs are composed as
/// `{scriptName}.{subdomain}.workers.dev` — Cloudflare never returns the full
/// hostname for a Worker.
public struct WorkersAccountSubdomain: Codable, Hashable, Sendable {
  public let subdomain: String

  public init(subdomain: String) {
    self.subdomain = subdomain
  }

  public func hostname(forScript name: String) -> String {
    "\(name).\(subdomain).workers.dev"
  }
}

public struct WorkerDeploymentVersion: Codable, Hashable, Sendable {
  public let versionID: String
  public let percentage: Double

  enum CodingKeys: String, CodingKey {
    case percentage
    case versionID = "version_id"
  }
}

public struct WorkerDeploymentAnnotations: Codable, Hashable, Sendable {
  public let message: String?
  public let triggeredBy: String?

  enum CodingKeys: String, CodingKey {
    case message = "workers/message"
    case triggeredBy = "workers/triggered_by"
  }
}

/// Typed deployment data for the operational Worker detail surface. The API
/// returns newest first, with the first deployment actively serving traffic.
public struct WorkerDeploymentSummary: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let createdOn: String
  public let source: String
  public let strategy: String?
  private let storedVersions: [WorkerDeploymentVersion]?
  public let annotations: WorkerDeploymentAnnotations?
  public let authorEmail: String?

  public var versions: [WorkerDeploymentVersion] { storedVersions ?? [] }

  enum CodingKeys: String, CodingKey {
    case id, source, strategy, annotations
    case storedVersions = "versions"
    case createdOn = "created_on"
    case authorEmail = "author_email"
  }

  public init(
    id: String, createdOn: String, source: String, strategy: String? = nil,
    versions: [WorkerDeploymentVersion] = [], annotations: WorkerDeploymentAnnotations? = nil,
    authorEmail: String? = nil
  ) {
    self.id = id
    self.createdOn = createdOn
    self.source = source
    self.strategy = strategy
    self.storedVersions = versions.isEmpty ? nil : versions
    self.annotations = annotations
    self.authorEmail = authorEmail
  }
}

public struct WorkerDeploymentListResult: Decodable, Sendable {
  public let deployments: [WorkerDeploymentSummary]

  enum CodingKeys: String, CodingKey {
    case deployments
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let lossy = try container.decode(
      [LossyElement<WorkerDeploymentSummary>].self, forKey: .deployments)
    deployments = lossy.compactMap(\.value)
  }
}

public struct PagesProject: CloudflareResource, Hashable {
  public let id: String
  public let name: String
  public let subdomain: String?
  public let createdOn: String?
  public let latestDeployment: PagesDeploymentSummary?

  enum CodingKeys: String, CodingKey {
    case id, name, subdomain
    case createdOn = "created_on"
    case latestDeployment = "latest_deployment"
  }
}

/// Compact deployment embedded on a project list row. Full history uses
/// `PagesDeployment`.
public struct PagesDeploymentSummary: Codable, Hashable, Sendable {
  public let id: String?
  public let url: String?
  public let environment: String?
  public let createdOn: String?
  public let latestStage: PagesDeploymentStage?

  enum CodingKeys: String, CodingKey {
    case id, url, environment
    case createdOn = "created_on"
    case latestStage = "latest_stage"
  }
}

public struct PagesDeploymentStage: Codable, Hashable, Sendable {
  public let name: String?
  public let status: String?
  public let startedOn: String?
  public let endedOn: String?

  enum CodingKeys: String, CodingKey {
    case name, status
    case startedOn = "started_on"
    case endedOn = "ended_on"
  }

  public init(
    name: String? = nil, status: String? = nil, startedOn: String? = nil, endedOn: String? = nil
  ) {
    self.name = name
    self.status = status
    self.startedOn = startedOn
    self.endedOn = endedOn
  }

  /// True while Cloudflare is still working this deployment.
  public var isInProgress: Bool {
    switch status?.lowercased() {
    case "active", "idle": true
    default: false
    }
  }
}

public struct PagesDeployment: Decodable, Hashable, Identifiable, Sendable {
  public let id: String
  public let shortID: String?
  public let url: String?
  public let environment: String?
  public let createdOn: String?
  public let modifiedOn: String?
  public let projectName: String?
  public let isSkipped: Bool?
  public let latestStage: PagesDeploymentStage?
  public let stages: [PagesDeploymentStage]?
  public let deploymentTrigger: PagesDeploymentTrigger?
  public let aliases: [String]?

  enum CodingKeys: String, CodingKey {
    case id, url, environment, stages, aliases
    case shortID = "short_id"
    case createdOn = "created_on"
    case modifiedOn = "modified_on"
    case projectName = "project_name"
    case isSkipped = "is_skipped"
    case latestStage = "latest_stage"
    case deploymentTrigger = "deployment_trigger"
  }

  public var statusLabel: String {
    latestStage?.status?.capitalized ?? (isSkipped == true ? "Skipped" : "Unknown")
  }

  public var branch: String? { deploymentTrigger?.metadata?.branch }
  public var commitMessage: String? { deploymentTrigger?.metadata?.commitMessage }

  public var isInProgress: Bool { latestStage?.isInProgress == true }
}

public struct PagesDeploymentTrigger: Codable, Hashable, Sendable {
  public let type: String?
  public let metadata: PagesDeploymentTriggerMetadata?
}

public struct PagesDeploymentTriggerMetadata: Codable, Hashable, Sendable {
  public let branch: String?
  public let commitHash: String?
  public let commitMessage: String?

  enum CodingKeys: String, CodingKey {
    case branch
    case commitHash = "commit_hash"
    case commitMessage = "commit_message"
  }
}

public struct PagesDeploymentLogs: Decodable, Hashable, Sendable {
  public let total: Int
  public let includesContainerLogs: Bool?
  public let data: [PagesDeploymentLogLine]

  enum CodingKeys: String, CodingKey {
    case total, data
    case includesContainerLogs = "includes_container_logs"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
    includesContainerLogs = try container.decodeIfPresent(Bool.self, forKey: .includesContainerLogs)
    data = try container.decodeIfPresent([PagesDeploymentLogLine].self, forKey: .data) ?? []
  }
}

public struct PagesDeploymentLogLine: Codable, Hashable, Identifiable, Sendable {
  public var id: String { "\(ts ?? "")|\(line)" }
  public let line: String
  public let ts: String?

  public init(line: String, ts: String? = nil) {
    self.line = line
    self.ts = ts
  }
}

/// Custom hostname attached to a Pages project. OpenAPI token group is
/// Pages Read / Pages Write (`page.read` / `page.write`).
public struct PagesDomain: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let status: String?
  public let createdOn: String?
  public let zoneTag: String?

  enum CodingKeys: String, CodingKey {
    case id, name, status
    case createdOn = "created_on"
    case zoneTag = "zone_tag"
  }
}

public struct WorkerAnalyticsPayload: Hashable, Sendable {
  public var requests: Int
  public var errors: Int
  public var cpuTimeP50Us: Double
  public var points: [WorkerAnalyticsBucket]
  public var previousRequests: Int?
  public var previousErrors: Int?
  public var previousCPUTimeP50Us: Double?

  public init(
    requests: Int,
    errors: Int,
    cpuTimeP50Us: Double,
    points: [WorkerAnalyticsBucket],
    previousRequests: Int? = nil,
    previousErrors: Int? = nil,
    previousCPUTimeP50Us: Double? = nil
  ) {
    self.requests = requests
    self.errors = errors
    self.cpuTimeP50Us = cpuTimeP50Us
    self.points = points
    self.previousRequests = previousRequests
    self.previousErrors = previousErrors
    self.previousCPUTimeP50Us = previousCPUTimeP50Us
  }
}

public struct WorkerAnalyticsBucket: Hashable, Sendable, Identifiable {
  public var id: String { datetime }
  public var datetime: String
  public var requests: Int
  public var errors: Int
  public var cpuTimeP50Us: Double

  public init(datetime: String, requests: Int, errors: Int, cpuTimeP50Us: Double = 0) {
    self.datetime = datetime
    self.requests = requests
    self.errors = errors
    self.cpuTimeP50Us = cpuTimeP50Us
  }
}

private struct WorkerAnalyticsData: Decodable, Sendable {
  let viewer: Viewer

  struct Viewer: Decodable, Sendable { let accounts: [Account] }
  struct Account: Decodable, Sendable {
    let currentTotals: [Totals]?
    let previousTotals: [Totals]?
    let workersInvocationsAdaptive: [Row]
  }
  struct Sum: Decodable, Sendable {
    let requests: Int
    let errors: Int
  }
  struct Quantiles: Decodable, Sendable {
    let cpuTimeP50: Double?
  }
  struct Totals: Decodable, Sendable {
    let sum: Sum
    let quantiles: Quantiles?
  }
  struct Row: Decodable, Sendable {
    let sum: Sum
    let quantiles: Quantiles?
    let dimensions: Dimensions

    struct Dimensions: Decodable, Sendable {
      let datetimeFiveMinutes: String?
      let datetime: String?
      let status: String?
    }
  }
}

extension CloudflareClient {
  public func listWorkers(accountID: String) async throws -> [WorkerScript] {
    try await list("/accounts/\(accountID)/workers/scripts").items
  }
  public func listWorkerDeployments(accountID: String, scriptName: String) async throws
    -> [WorkerDeploymentSummary]
  {
    let result: WorkerDeploymentListResult = try await request(
      "/accounts/\(accountID)/workers/scripts/\(scriptName)/deployments")
    return result.deployments
  }

  /// Creates a whole-traffic deployment for one version (100%). Use this to
  /// roll back or promote — Dash does not expose gradual/canary splits.
  @discardableResult
  public func createWorkerDeployment(
    accountID: String, scriptName: String, versionID: String, message: String? = nil
  ) async throws -> WorkerDeploymentSummary {
    var body: [String: JSONValue] = [
      "strategy": .string("percentage"),
      "versions": .array([
        .object([
          "percentage": .number(100),
          "version_id": .string(versionID),
        ])
      ]),
    ]
    if let message {
      let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        body["annotations"] = .object(["workers/message": .string(trimmed)])
      }
    }
    return try await request(
      "/accounts/\(accountID)/workers/scripts/\(scriptName)/deployments",
      method: "POST",
      body: body)
  }

  // MARK: Workers Builds
  //
  // These endpoints live under `/accounts/{id}/builds/…`, not under
  // `/workers/…`, and they key on the script's immutable **tag**
  // (`external_script_id`), never its name. `WorkerScript.tag` carries it.
  //
  // Cloudflare documents these as requiring a user-scoped API token and
  // rejecting account-scoped ones. Dash's OAuth tokens are user-scoped, so this
  // should hold — but it is the first thing to check if every call here 403s
  // while the rest of the Workers screens work.

  /// Recent builds for one Worker, newest first.
  public func listWorkerBuilds(
    accountID: String,
    scriptTag: String,
    page: Int = 1,
    perPage: Int = 20
  ) async throws -> Page<WorkerBuild> {
    try await list(
      "/accounts/\(accountID)/builds/workers/\(scriptTag)/builds",
      query: ["page": String(page), "per_page": String(perPage)])
  }

  /// Newest build per script tag, for showing build state across a list of
  /// Workers in one request. Cloudflare caps the batch at 20 tags.
  public func latestWorkerBuilds(
    accountID: String,
    scriptTags: [String]
  ) async throws -> [String: WorkerBuild] {
    let tags = Array(scriptTags.prefix(20))
    guard !tags.isEmpty else { return [:] }
    let result: WorkerLatestBuilds = try await request(
      "/accounts/\(accountID)/builds/builds/latest",
      query: ["external_script_ids": tags.joined(separator: ",")])
    return result.builds ?? [:]
  }

  /// Stops an in-flight build. The response body is intentionally discarded and
  /// decoded as an opaque value: Cloudflare does not document its shape, and a
  /// cancel that worked must not surface as a decode failure.
  public func cancelWorkerBuild(accountID: String, buildUUID: String) async throws {
    let _: JSONValue = try await request(
      "/accounts/\(accountID)/builds/builds/\(buildUUID)/cancel", method: "PUT")
  }

  public func listWorkerDomains(accountID: String, service: String? = nil) async throws
    -> [WorkerDomain]
  {
    try await list(
      "/accounts/\(accountID)/workers/domains",
      query: ["service": service.flatMap { $0.isEmpty ? nil : $0 }]
    ).items
  }

  /// Attaches a hostname from an existing zone so requests route to `service`.
  @discardableResult
  public func attachWorkerDomain(
    accountID: String, hostname: String, service: String, zoneID: String, zoneName: String
  ) async throws -> WorkerDomain {
    try await request(
      "/accounts/\(accountID)/workers/domains",
      method: "PUT",
      body: [
        "hostname": JSONValue.string(hostname),
        "service": .string(service),
        "zone_id": .string(zoneID),
        "zone_name": .string(zoneName),
      ])
  }

  public func detachWorkerDomain(accountID: String, domainID: String) async throws {
    let _: JSONValue = try await request(
      "/accounts/\(accountID)/workers/domains/\(domainID)", method: "DELETE")
  }

  /// Zone-scoped route patterns. Routes are the dashboard's other half of
  /// "Domains & Routes" — a worker bound only through routes has no
  /// `WorkerDomain` records at all.
  public func listWorkerRoutes(zoneID: String) async throws -> [WorkerRoute] {
    try await list("/zones/\(zoneID)/workers/routes").items
  }
  /// Downloads script content. Classic scripts come back as raw JS; module
  /// workers come back as multipart/form-data with one part per module, the
  /// boundary living in the response Content-Type header.
  public func getWorkerSource(accountID: String, name: String) async throws -> WorkerSource {
    let (data, response) = try await rawResponse(
      url: requestURL(
        path: "/accounts/\(accountID)/workers/scripts/\(name)/content/v2"),
      method: "GET", data: nil, contentType: nil)
    let responseType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
    guard responseType.lowercased().contains("multipart/") else {
      return WorkerSource(
        content: String(decoding: data, as: UTF8.self), mainModule: nil, moduleCount: 0)
    }
    let parts = MultipartDocument.parse(data: data, contentType: responseType)
    guard let main = parts.first else {
      return WorkerSource(
        content: String(decoding: data, as: UTF8.self), mainModule: nil, moduleCount: 0)
    }
    return WorkerSource(
      content: String(decoding: main.body, as: UTF8.self),
      mainModule: main.filename ?? main.name ?? "worker.js",
      moduleCount: parts.count)
  }

  /// Re-uploads script content, preserving settings and bindings. Module
  /// workers re-declare their main module; classic scripts use body_part.
  @discardableResult
  public func uploadWorkerScript(
    accountID: String, name: String, source: WorkerSource, content: String
  ) async throws -> JSONValue {
    var form = MultipartForm()
    if let mainModule = source.mainModule {
      form.addFile(
        name: "metadata", filename: "metadata.json", contentType: "application/json",
        data: try JSONEncoder().encode(["main_module": mainModule]))
      form.addFile(
        name: mainModule, filename: mainModule,
        contentType: "application/javascript+module", data: Data(content.utf8))
    } else {
      form.addFile(
        name: "metadata", filename: "metadata.json", contentType: "application/json",
        data: try JSONEncoder().encode(["body_part": "script"]))
      form.addFile(
        name: "script", filename: "script.js",
        contentType: "application/javascript", data: Data(content.utf8))
    }
    let data = try await raw(
      "/accounts/\(accountID)/workers/scripts/\(name)/content",
      method: "PUT", data: form.encode(), contentType: form.contentType)
    let envelope = try JSONDecoder().decode(APIEnvelope<JSONValue>.self, from: data)
    guard envelope.success else {
      throw CloudflareAPIError.request(status: 200, errors: envelope.errors ?? [])
    }
    return envelope.result
  }
  public func getWorkersAccountSubdomain(accountID: String) async throws
    -> WorkersAccountSubdomain
  {
    try await request("/accounts/\(accountID)/workers/subdomain")
  }

  public func getWorkerSubdomain(accountID: String, name: String) async throws
    -> WorkerSubdomainStatus
  {
    try await request("/accounts/\(accountID)/workers/scripts/\(name)/subdomain")
  }
  public func setWorkerSubdomain(accountID: String, name: String, enabled: Bool) async throws
    -> WorkerSubdomainStatus
  {
    try await request(
      "/accounts/\(accountID)/workers/scripts/\(name)/subdomain",
      method: "POST", body: ["enabled": enabled])
  }
  /// The immutable script tag (`external_script_id`) the Builds APIs key on,
  /// resolved from the documented scripts list.
  public func workerTag(accountID: String, name: String) async throws -> String? {
    try await listWorkers(accountID: accountID).first { $0.id == name }?.tag
  }
  /// Pages returns 8000024 ("Invalid list options… Review the `page` or
  /// `per_page` parameter") for oversized pages. `50` fails on real accounts;
  /// `10` matches wrangler and the OpenAPI example.
  public func listPagesProjects(accountID: String) async throws -> [PagesProject] {
    try await listAllPages("/accounts/\(accountID)/pages/projects", perPage: 10)
  }

  public func getPagesProject(accountID: String, projectName: String) async throws -> PagesProject {
    try await request("/accounts/\(accountID)/pages/projects/\(projectName)")
  }

  /// Deployments cap `per_page` at 25 (same 8000024 above that).
  public func listPagesDeployments(
    accountID: String, projectName: String, page: Int = 1, perPage: Int = 25
  ) async throws -> Page<PagesDeployment> {
    try await list(
      "/accounts/\(accountID)/pages/projects/\(projectName)/deployments",
      query: ["page": String(page), "per_page": String(min(max(perPage, 1), 25))])
  }

  public func getPagesDeployment(
    accountID: String, projectName: String, deploymentID: String
  ) async throws -> PagesDeployment {
    try await request(
      "/accounts/\(accountID)/pages/projects/\(projectName)/deployments/\(deploymentID)")
  }

  public func getPagesDeploymentLogs(
    accountID: String, projectName: String, deploymentID: String
  ) async throws -> PagesDeploymentLogs {
    try await request(
      "/accounts/\(accountID)/pages/projects/\(projectName)/deployments/\(deploymentID)/history/logs"
    )
  }

  @discardableResult
  public func retryPagesDeployment(
    accountID: String, projectName: String, deploymentID: String
  ) async throws -> PagesDeployment {
    try await request(
      "/accounts/\(accountID)/pages/projects/\(projectName)/deployments/\(deploymentID)/retry",
      method: "POST")
  }

  @discardableResult
  public func rollbackPagesDeployment(
    accountID: String, projectName: String, deploymentID: String
  ) async throws -> PagesDeployment {
    try await request(
      "/accounts/\(accountID)/pages/projects/\(projectName)/deployments/\(deploymentID)/rollback",
      method: "POST")
  }

  public func listPagesDomains(accountID: String, projectName: String) async throws -> [PagesDomain]
  {
    try await list("/accounts/\(accountID)/pages/projects/\(projectName)/domains").items
  }

  @discardableResult
  public func addPagesDomain(accountID: String, projectName: String, name: String) async throws
    -> PagesDomain
  {
    try await request(
      "/accounts/\(accountID)/pages/projects/\(projectName)/domains",
      method: "POST",
      body: ["name": name])
  }

  public func deletePagesDomain(accountID: String, projectName: String, domainName: String)
    async throws
  {
    let _: JSONValue = try await request(
      "/accounts/\(accountID)/pages/projects/\(projectName)/domains/\(domainName)",
      method: "DELETE")
  }

  /// Worker invocation totals for the last `hours` via GraphQL Analytics.
  public func workerAnalytics(accountID: String, scriptName: String, hours: Int = 24)
    async throws -> WorkerAnalyticsPayload
  {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    let until = Date()
    let window = max(hours, 1)
    let since = until.addingTimeInterval(-TimeInterval(window) * 3600)
    let previousSince = since.addingTimeInterval(-TimeInterval(window) * 3600)
    let untilStamp = formatter.string(from: until)
    let sinceStamp = formatter.string(from: since)
    let previousSinceStamp = formatter.string(from: previousSince)
    let escaped = scriptName.replacingOccurrences(of: "\"", with: "\\\"")
    let query = """
      { viewer { accounts(filter: {accountTag: "\(accountID)"}) { \
      currentTotals: workersInvocationsAdaptive(limit: 1, filter: { \
      scriptName: "\(escaped)", \
      datetime_geq: "\(sinceStamp)", \
      datetime_lt: "\(untilStamp)" \
      }) { sum { requests errors } quantiles { cpuTimeP50 } } \
      previousTotals: workersInvocationsAdaptive(limit: 1, filter: { \
      scriptName: "\(escaped)", \
      datetime_geq: "\(previousSinceStamp)", \
      datetime_lt: "\(sinceStamp)" \
      }) { sum { requests errors } quantiles { cpuTimeP50 } } \
      workersInvocationsAdaptive(limit: 2500, orderBy: [datetimeFiveMinutes_ASC], filter: { \
      scriptName: "\(escaped)", \
      datetime_geq: "\(sinceStamp)", \
      datetime_lt: "\(untilStamp)" \
      }) { sum { requests errors } quantiles { cpuTimeP50 } \
      dimensions { datetimeFiveMinutes status } } } } }
      """
    let payload = try JSONEncoder().encode(["query": query])
    let response = try await graphQLRaw(payload)
    let envelope = try JSONDecoder().decode(
      GraphQLEnvelope<WorkerAnalyticsData>.self, from: response)
    if let error = envelope.errors?.first {
      throw CloudflareAPIError.request(
        status: error.semanticStatusCode,
        errors: [APIErrorItem(code: 0, message: error.message)])
    }
    let account = envelope.data?.viewer.accounts.first
    let rows = account?.workersInvocationsAdaptive ?? []
    var aggregatedRequests = 0
    var aggregatedErrors = 0
    var cpuSamples: [Double] = []
    var byBucket:
      [String: (
        requests: Int, errors: Int, cpuWeighted: Double, cpuWeight: Double, cpuSum: Double,
        cpuCount: Int
      )] = [:]
    for row in rows {
      let req = row.sum.requests
      let err = row.sum.errors
      aggregatedRequests += req
      aggregatedErrors += err
      if let cpu = row.quantiles?.cpuTimeP50 { cpuSamples.append(cpu) }
      let key = row.dimensions.datetimeFiveMinutes ?? row.dimensions.datetime ?? "unknown"
      var bucket = byBucket[key] ?? (0, 0, 0, 0, 0, 0)
      bucket.requests += req
      bucket.errors += err
      if let cpu = row.quantiles?.cpuTimeP50 {
        bucket.cpuWeighted += cpu * Double(req)
        bucket.cpuWeight += Double(req)
        bucket.cpuSum += cpu
        bucket.cpuCount += 1
      }
      byBucket[key] = bucket
    }
    let points = byBucket.keys.sorted().map { key in
      let bucket = byBucket[key]!
      let cpu: Double
      if bucket.cpuWeight > 0 {
        cpu = bucket.cpuWeighted / bucket.cpuWeight
      } else if bucket.cpuCount > 0 {
        cpu = bucket.cpuSum / Double(bucket.cpuCount)
      } else {
        cpu = 0
      }
      return WorkerAnalyticsBucket(
        datetime: key, requests: bucket.requests, errors: bucket.errors, cpuTimeP50Us: cpu)
    }
    let fallbackCPU =
      cpuSamples.isEmpty ? 0 : cpuSamples.reduce(0, +) / Double(cpuSamples.count)
    let requests: Int
    let errors: Int
    let cpuTimeP50Us: Double
    if let currentTotals = account?.currentTotals {
      requests = currentTotals.first?.sum.requests ?? 0
      errors = currentTotals.first?.sum.errors ?? 0
      cpuTimeP50Us = currentTotals.first?.quantiles?.cpuTimeP50 ?? 0
    } else {
      requests = aggregatedRequests
      errors = aggregatedErrors
      cpuTimeP50Us = fallbackCPU
    }
    let previousRequests: Int?
    let previousErrors: Int?
    let previousCPUTimeP50Us: Double?
    if let previousTotals = account?.previousTotals {
      previousRequests = previousTotals.first?.sum.requests ?? 0
      previousErrors = previousTotals.first?.sum.errors ?? 0
      previousCPUTimeP50Us = previousTotals.first?.quantiles?.cpuTimeP50 ?? 0
    } else {
      previousRequests = nil
      previousErrors = nil
      previousCPUTimeP50Us = nil
    }
    return WorkerAnalyticsPayload(
      requests: requests,
      errors: errors,
      cpuTimeP50Us: cpuTimeP50Us,
      points: points,
      previousRequests: previousRequests,
      previousErrors: previousErrors,
      previousCPUTimeP50Us: previousCPUTimeP50Us
    )
  }
}
