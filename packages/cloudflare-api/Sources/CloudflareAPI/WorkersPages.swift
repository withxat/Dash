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
  /// The repository's own name, without its owner.
  public let repoName: String?
  /// The Git account or organisation that owns the repository.
  public let providerAccountName: String?
  /// `github`, `gitlab`, `gitlab_internal`, or `origin`.
  public let providerType: String?
  public let rootDirectory: String?

  /// Seven characters, the length every git UI settled on.
  public var shortCommit: String? {
    commitHash.flatMap { $0.isEmpty ? nil : String($0.prefix(7)) }
  }

  /// `owner/name`, or nil unless Cloudflare sent both halves.
  public var repository: String? {
    guard
      let owner = providerAccountName, !owner.isEmpty,
      let repo = repoName, !repo.isEmpty
    else { return nil }
    return "\(owner)/\(repo)"
  }

  /// The commit on the Git provider's site. Nil unless the provider is one
  /// whose commit URL shape is known and the owner, repository, and hash are
  /// all present — a guessed link is worse than no link. `gitlab_internal` is
  /// a self-managed host this client cannot name, so it gets none.
  public var commitURL: URL? {
    guard
      let hash = commitHash, !hash.isEmpty,
      let owner = providerAccountName, !owner.isEmpty,
      let repo = repoName, !repo.isEmpty
    else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    switch providerType?.lowercased() {
    case "github":
      components.host = "github.com"
      components.path = "/\(owner)/\(repo)/commit/\(hash)"
    case "gitlab":
      components.host = "gitlab.com"
      components.path = "/\(owner)/\(repo)/-/commit/\(hash)"
    default:
      return nil
    }
    return components.url
  }

  /// What started the build. Compare through this, never the raw string:
  /// Cloudflare documents `push`, `pull_request`, `manual`, and `api` today.
  public enum Source: Hashable, Sendable {
    case push
    case pullRequest
    case manual
    case api
    case other(String)
  }

  public var source: Source? {
    guard let raw = buildTriggerSource?.lowercased(), !raw.isEmpty else { return nil }
    switch raw {
    case "push": return .push
    case "pull_request": return .pullRequest
    case "manual": return .manual
    case "api": return .api
    default: return .other(raw)
    }
  }

  enum CodingKeys: String, CodingKey {
    case branch, author
    case commitHash = "commit_hash"
    case commitMessage = "commit_message"
    case buildCommand = "build_command"
    case deployCommand = "deploy_command"
    case buildTriggerSource = "build_trigger_source"
    case repoName = "repo_name"
    case providerAccountName = "provider_account_name"
    case providerType = "provider_type"
    case rootDirectory = "root_directory"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    branch = try container.decodeIfPresent(String.self, forKey: .branch)
    commitHash = try container.decodeIfPresent(String.self, forKey: .commitHash)
    commitMessage = try container.decodeIfPresent(String.self, forKey: .commitMessage)
    author = try container.decodeIfPresent(String.self, forKey: .author)
    buildCommand = try container.decodeIfPresent(String.self, forKey: .buildCommand)
    deployCommand = try container.decodeIfPresent(String.self, forKey: .deployCommand)
    buildTriggerSource = try container.decodeIfPresent(String.self, forKey: .buildTriggerSource)
    // Descriptive extras, decoded leniently: a field in a shape this client
    // has not seen must cost its one row on the build screen, never the build —
    // and never the whole history list this metadata is nested in.
    repoName = try? container.decodeIfPresent(String.self, forKey: .repoName)
    providerAccountName = try? container.decodeIfPresent(
      String.self, forKey: .providerAccountName)
    providerType = try? container.decodeIfPresent(String.self, forKey: .providerType)
    rootDirectory = try? container.decodeIfPresent(String.self, forKey: .rootDirectory)
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

  /// How a finished build ended.
  public enum Outcome: Equatable, Sendable {
    case success
    case failed
    case canceled
    case skipped
  }

  /// Nil while the build is in flight **and** when it stopped without
  /// Cloudflare saying how — that second case is unknown, never success.
  /// Cloudflare documents `success`, `fail`, and `skipped` plus values it does
  /// not list, so anything unrecognised reads as a failure rather than green.
  public var outcome: Outcome? {
    guard phase == .finished, let raw = buildOutcome?.lowercased() else { return nil }
    switch raw {
    case "success": return .success
    case "canceled", "cancelled": return .canceled
    case "skipped": return .skipped
    default: return .failed
    }
  }

  public var createdDate: Date? { createdOn.flatMap(PagesTimestamp.date) }
  public var stoppedDate: Date? { stoppedOn.flatMap(PagesTimestamp.date) }

  /// Queue to stop, or nil until the build has both ends.
  public var duration: TimeInterval? {
    guard let start = createdDate, let end = stoppedDate, end >= start else { return nil }
    return end.timeIntervalSince(start)
  }

  /// One stretch of a build's life, in the order Cloudflare runs them.
  public struct Step: Hashable, Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
      case queued
      case initializing
      case building
    }

    public enum State: Hashable, Sendable {
      /// Ran, and the build moved on (or finished cleanly here).
      case done
      /// Where an in-flight build is right now.
      case active
      /// Where a failed build stopped.
      case failed
      /// Where a cancelled or skipped build stopped.
      case stopped
      /// Where a build stopped without Cloudflare reporting an outcome.
      case ended
      /// An in-flight build has not reached it yet.
      case pending
      /// The build finished before reaching it.
      case notReached
    }

    public let kind: Kind
    public let state: State
    public let startedOn: Date?
    /// Nil while the step is still running, and when either end is missing.
    public let duration: TimeInterval?

    public var id: Kind { kind }
  }

  /// The three lifecycle steps with where the build is — or stopped — among
  /// them. Read from the timestamps for the same reason `phase` is: they are
  /// unambiguous and `status` is not documented.
  ///
  /// The step a finished build stopped in is the last one it *reached*, and it
  /// alone carries the outcome: a build that failed while initializing never
  /// built, so Building is `notReached`, not failed.
  public var timeline: [Step] {
    let starts: [(Step.Kind, Date?)] = [
      (.queued, createdDate),
      (.initializing, initializingOn.flatMap(PagesTimestamp.date)),
      (.building, runningOn.flatMap(PagesTimestamp.date)),
    ]
    let finished = phase == .finished
    let lastReached = starts.lastIndex { $0.1 != nil }
    let terminal: Step.State =
      switch outcome {
      case .success: .done
      case .failed: .failed
      case .canceled, .skipped: .stopped
      case nil: .ended
      }

    return starts.enumerated().map { index, entry in
      let (kind, start) = entry
      guard let start else {
        return Step(
          kind: kind, state: finished ? .notReached : .pending, startedOn: nil, duration: nil)
      }
      let isLast = index == lastReached
      // A step ends where the next one that was reached begins; the last
      // reached one ends when the build stops.
      let end =
        isLast
        ? stoppedDate
        : starts[(index + 1)...].lazy.compactMap { $0.1 }.first
      let state: Step.State = isLast ? (finished ? terminal : .active) : .done
      let duration = end.flatMap { $0 >= start ? $0.timeIntervalSince(start) : nil }
      return Step(kind: kind, state: state, startedOn: start, duration: duration)
    }
  }
}

/// One line of a Workers Builds log. Cloudflare sends each as a two-element
/// tuple, `[timestamp, text]`, not an object.
public struct WorkerBuildLogLine: Decodable, Hashable, Sendable {
  public let timestamp: Date?
  public let text: String

  public init(timestamp: Date?, text: String) {
    self.timestamp = timestamp
    self.text = text
  }

  /// Never throws on a shape it has not seen: one odd line must not cost the
  /// whole log. A bare string is taken as the text; anything else is skipped
  /// over and the line reads empty.
  public init(from decoder: any Decoder) throws {
    guard var tuple = try? decoder.unkeyedContainer() else {
      let single = try? decoder.singleValueContainer()
      timestamp = nil
      text = (try? single?.decode(String.self)) ?? ""
      return
    }
    var stamp: Date?
    var message: String?
    while !tuple.isAtEnd {
      if let number = try? tuple.decode(Double.self) {
        if stamp == nil { stamp = Self.date(fromEpoch: number) }
      } else if let string = try? tuple.decode(String.self) {
        if message == nil { message = string }
      } else if (try? tuple.decode(JSONValue.self)) == nil {
        // Could not even step over the element; stop rather than spin.
        break
      }
    }
    timestamp = stamp
    text = message ?? ""
  }

  /// Cloudflare documents the timestamp as a number without naming its unit.
  /// Epoch seconds, milliseconds, microseconds, and nanoseconds for any date
  /// this century sit three orders of magnitude apart, so the magnitude names
  /// the unit unambiguously.
  static func date(fromEpoch value: Double) -> Date? {
    guard value.isFinite, value > 0 else { return nil }
    let seconds: Double =
      switch value {
      case 1e17...: value / 1e9
      case 1e14...: value / 1e6
      case 1e11...: value / 1e3
      default: value
      }
    return Date(timeIntervalSince1970: seconds)
  }
}

/// One page of `GET /accounts/{id}/builds/builds/{build_uuid}/logs`.
public struct WorkerBuildLogs: Decodable, Hashable, Sendable {
  public let lines: [WorkerBuildLogLine]
  /// Pass back as `cursor` to read the lines after these.
  public let cursor: String?
  /// True when this page stopped short of the end of the log.
  public let truncated: Bool

  public init(lines: [WorkerBuildLogLine], cursor: String?, truncated: Bool) {
    self.lines = lines
    self.cursor = cursor
    self.truncated = truncated
  }

  enum CodingKeys: String, CodingKey {
    case lines, cursor, truncated
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    lines = try container.decodeIfPresent([WorkerBuildLogLine].self, forKey: .lines) ?? []
    cursor = try? container.decodeIfPresent(String.self, forKey: .cursor)
    truncated = (try? container.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
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

  public var startedDate: Date? { startedOn.flatMap(PagesTimestamp.date) }
  public var endedDate: Date? { endedOn.flatMap(PagesTimestamp.date) }

  /// How long the stage ran, or nil until it has both started and ended.
  public var duration: TimeInterval? {
    guard let start = startedDate, let end = endedDate, end >= start else { return nil }
    return end.timeIntervalSince(start)
  }
}

/// Pages timestamps arrive with microseconds (`2021-03-09T00:55:03.923456Z`)
/// and, on older rows, without a fraction at all.
enum PagesTimestamp {
  static func date(_ value: String) -> Date? {
    if let date = try? Date(
      value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    {
      return date
    }
    return try? Date(value, strategy: Date.ISO8601FormatStyle())
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
  /// The build settings this deployment ran with. Absent on some responses,
  /// and all-nil for a direct upload, which builds nothing.
  public let buildConfig: PagesBuildConfig?
  /// The repository the deployment was built from; nil for direct uploads.
  public let source: PagesDeploymentSource?

  enum CodingKeys: String, CodingKey {
    case id, url, environment, stages, aliases, source
    case shortID = "short_id"
    case createdOn = "created_on"
    case modifiedOn = "modified_on"
    case projectName = "project_name"
    case isSkipped = "is_skipped"
    case latestStage = "latest_stage"
    case deploymentTrigger = "deployment_trigger"
    case buildConfig = "build_config"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    shortID = try container.decodeIfPresent(String.self, forKey: .shortID)
    url = try container.decodeIfPresent(String.self, forKey: .url)
    environment = try container.decodeIfPresent(String.self, forKey: .environment)
    createdOn = try container.decodeIfPresent(String.self, forKey: .createdOn)
    modifiedOn = try container.decodeIfPresent(String.self, forKey: .modifiedOn)
    projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
    isSkipped = try container.decodeIfPresent(Bool.self, forKey: .isSkipped)
    latestStage = try container.decodeIfPresent(PagesDeploymentStage.self, forKey: .latestStage)
    stages = try container.decodeIfPresent([PagesDeploymentStage].self, forKey: .stages)
    deploymentTrigger = try container.decodeIfPresent(
      PagesDeploymentTrigger.self, forKey: .deploymentTrigger)
    aliases = try container.decodeIfPresent([String].self, forKey: .aliases)
    // Descriptive extras, decoded leniently: a build setting or source block in
    // a shape this client has not seen must cost that one section, never the
    // deployment — the status, stages, and log above are what the screen is for.
    buildConfig = try? container.decodeIfPresent(PagesBuildConfig.self, forKey: .buildConfig)
    source = try? container.decodeIfPresent(PagesDeploymentSource.self, forKey: .source)
  }

  public var statusLabel: String {
    latestStage?.status?.capitalized ?? (isSkipped == true ? "Skipped" : "Unknown")
  }

  public var branch: String? { deploymentTrigger?.metadata?.branch }
  public var commitMessage: String? { deploymentTrigger?.metadata?.commitMessage }
  public var commitHash: String? { deploymentTrigger?.metadata?.commitHash }

  /// Seven characters, the length every git UI settled on.
  public var shortCommit: String? {
    commitHash.flatMap { $0.isEmpty ? nil : String($0.prefix(7)) }
  }

  public var isInProgress: Bool { latestStage?.isInProgress == true }

  /// `owner/repo`, when the deployment came from a connected repository.
  public var repository: String? {
    guard
      let owner = source?.config?.owner, !owner.isEmpty,
      let repo = source?.config?.repoName, !repo.isEmpty
    else { return nil }
    return "\(owner)/\(repo)"
  }

  /// The commit on the Git provider's site. Nil unless the provider is one
  /// whose commit URL shape is known and the owner, repository, and hash are
  /// all present — a guessed link is worse than no link.
  public var commitURL: URL? {
    guard
      let hash = commitHash, !hash.isEmpty,
      let owner = source?.config?.owner, !owner.isEmpty,
      let repo = source?.config?.repoName, !repo.isEmpty
    else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    switch source?.type?.lowercased() {
    case "github":
      components.host = "github.com"
      components.path = "/\(owner)/\(repo)/commit/\(hash)"
    case "gitlab":
      components.host = "gitlab.com"
      components.path = "/\(owner)/\(repo)/-/commit/\(hash)"
    default:
      return nil
    }
    return components.url
  }

  /// Wall-clock seconds from the first stage starting to the last one ending.
  /// Nil while the deployment is still running or when Cloudflare sent no
  /// stage timestamps — `created_on` → `modified_on` is not a substitute, since
  /// a later rollback or alias change also moves `modified_on`.
  public var buildDuration: TimeInterval? {
    guard !isInProgress, let stages else { return nil }
    guard
      let start = stages.lazy.compactMap(\.startedDate).first,
      let end = stages.reversed().lazy.compactMap(\.endedDate).first,
      end >= start
    else { return nil }
    return end.timeIntervalSince(start)
  }
}

public struct PagesDeploymentTrigger: Codable, Hashable, Sendable {
  /// `github:push`, `ad_hoc`, or `deploy_hook` today. Compare through
  /// `PagesDeploymentTrigger.Kind`, never as a raw string at a call site.
  public let type: String?
  public let metadata: PagesDeploymentTriggerMetadata?

  public enum Kind: Equatable, Sendable {
    /// A push to the connected repository (`github:push`, `gitlab:push`).
    case gitPush
    /// Started by hand: a direct upload, a retry, or "Create deployment".
    case manual
    case deployHook
    case other(String)
  }

  public var kind: Kind? {
    guard let type = type?.lowercased(), !type.isEmpty else { return nil }
    if type.hasSuffix(":push") { return .gitPush }
    switch type {
    case "ad_hoc": return .manual
    case "deploy_hook": return .deployHook
    default: return .other(type)
    }
  }
}

public struct PagesDeploymentTriggerMetadata: Codable, Hashable, Sendable {
  public let branch: String?
  public let commitHash: String?
  public let commitMessage: String?
  /// True when the build ran with uncommitted changes (direct uploads from a
  /// dirty working tree).
  public let commitDirty: Bool?

  enum CodingKeys: String, CodingKey {
    case branch
    case commitHash = "commit_hash"
    case commitMessage = "commit_message"
    case commitDirty = "commit_dirty"
  }
}

/// Build settings a deployment ran with. Cloudflare sends empty strings, not
/// nulls, for settings a project never set, so read these through the
/// non-empty accessors.
public struct PagesBuildConfig: Codable, Hashable, Sendable {
  private let storedBuildCommand: String?
  private let storedDestinationDirectory: String?
  private let storedRootDirectory: String?
  public let buildCaching: Bool?

  public var buildCommand: String? { storedBuildCommand.nonEmpty }
  public var destinationDirectory: String? { storedDestinationDirectory.nonEmpty }
  public var rootDirectory: String? { storedRootDirectory.nonEmpty }

  enum CodingKeys: String, CodingKey {
    case storedBuildCommand = "build_command"
    case storedDestinationDirectory = "destination_dir"
    case storedRootDirectory = "root_dir"
    case buildCaching = "build_caching"
  }
}

public struct PagesDeploymentSource: Codable, Hashable, Sendable {
  /// `github` or `gitlab`.
  public let type: String?
  public let config: PagesDeploymentSourceConfig?
}

public struct PagesDeploymentSourceConfig: Codable, Hashable, Sendable {
  public let owner: String?
  public let repoName: String?
  public let productionBranch: String?

  enum CodingKeys: String, CodingKey {
    case owner
    case repoName = "repo_name"
    case productionBranch = "production_branch"
  }
}

extension Optional where Wrapped == String {
  fileprivate var nonEmpty: String? {
    guard let self, !self.isEmpty else { return nil }
    return self
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

public struct WorkerBinding: Codable, Hashable, Identifiable, Sendable {
  public var id: String { "\(type):\(name)" }
  public let name: String
  public let type: String
  public let text: String?
  public let json: JSONValue?
  public let namespaceID: String?
  public let bucketName: String?
  public let databaseID: String?
  public let service: String?
  public let environment: String?
  public let className: String?
  public let scriptName: String?
  public let queueName: String?
  public let indexName: String?
  public let dataset: String?
  public let workflowName: String?
  public let part: String?

  enum CodingKeys: String, CodingKey {
    case name, type, text, json, service, environment, dataset, part
    case namespaceID = "namespace_id"
    case bucketName = "bucket_name"
    case databaseID = "id"
    case className = "class_name"
    case scriptName = "script_name"
    case queueName = "queue_name"
    case indexName = "index_name"
    case workflowName = "workflow_name"
  }

  public init(
    name: String,
    type: String,
    text: String? = nil,
    json: JSONValue? = nil,
    namespaceID: String? = nil,
    bucketName: String? = nil,
    databaseID: String? = nil,
    service: String? = nil,
    environment: String? = nil,
    className: String? = nil,
    scriptName: String? = nil,
    queueName: String? = nil,
    indexName: String? = nil,
    dataset: String? = nil,
    workflowName: String? = nil,
    part: String? = nil
  ) {
    self.name = name
    self.type = type
    self.text = text
    self.json = json
    self.namespaceID = namespaceID
    self.bucketName = bucketName
    self.databaseID = databaseID
    self.service = service
    self.environment = environment
    self.className = className
    self.scriptName = scriptName
    self.queueName = queueName
    self.indexName = indexName
    self.dataset = dataset
    self.workflowName = workflowName
    self.part = part
  }

  /// True for write-only secrets managed separately under `/secrets`.
  public var isSecret: Bool {
    type == "secret_text" || type == "secret_key"
  }

  /// The most descriptive value or resource identifier for display / copy.
  public var summaryValue: String? {
    if let text = text.nonEmpty { return text }
    if let bucketName = bucketName.nonEmpty { return bucketName }
    if let namespaceID = namespaceID.nonEmpty { return namespaceID }
    if let databaseID = databaseID.nonEmpty { return databaseID }
    if let service = service.nonEmpty {
      if let environment = environment.nonEmpty {
        return "\(service) (\(environment))"
      }
      return service
    }
    if let className = className.nonEmpty {
      if let scriptName = scriptName.nonEmpty {
        return "\(scriptName) · \(className)"
      }
      return className
    }
    if let queueName = queueName.nonEmpty { return queueName }
    if let indexName = indexName.nonEmpty { return indexName }
    if let dataset = dataset.nonEmpty { return dataset }
    if let workflowName = workflowName.nonEmpty { return workflowName }
    if let part = part.nonEmpty { return part }
    if let json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      if let data = try? encoder.encode(json),
        let rendered = String(data: data, encoding: .utf8), !rendered.isEmpty
      {
        return rendered
      }
    }
    return nil
  }
}

/// Runtime settings and bindings for a Worker script
/// (`GET /accounts/{account_id}/workers/scripts/{script_name}/settings`).
public struct WorkerSettings: Codable, Hashable, Sendable {
  public let compatibilityDate: String?
  public let compatibilityFlags: [String]
  public let bindings: [WorkerBinding]
  public let placementMode: String?
  public let logpush: Bool?

  private struct Placement: Codable, Hashable, Sendable {
    let mode: String?
  }

  enum CodingKeys: String, CodingKey {
    case compatibilityDate = "compatibility_date"
    case compatibilityFlags = "compatibility_flags"
    case bindings
    case placement
    case logpush
  }

  public init(
    compatibilityDate: String? = nil,
    compatibilityFlags: [String] = [],
    bindings: [WorkerBinding] = [],
    placementMode: String? = nil,
    logpush: Bool? = nil
  ) {
    self.compatibilityDate = compatibilityDate
    self.compatibilityFlags = compatibilityFlags
    self.bindings = bindings
    self.placementMode = placementMode
    self.logpush = logpush
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    compatibilityDate = (try c.decodeIfPresent(String.self, forKey: .compatibilityDate)).nonEmpty
    compatibilityFlags = try c.decodeIfPresent([String].self, forKey: .compatibilityFlags) ?? []
    bindings = try c.decodeIfPresent([WorkerBinding].self, forKey: .bindings) ?? []
    placementMode = (try c.decodeIfPresent(Placement.self, forKey: .placement)?.mode).nonEmpty
    logpush = try c.decodeIfPresent(Bool.self, forKey: .logpush)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(compatibilityDate, forKey: .compatibilityDate)
    try c.encode(compatibilityFlags, forKey: .compatibilityFlags)
    try c.encode(bindings, forKey: .bindings)
    if let placementMode {
      try c.encode(Placement(mode: placementMode), forKey: .placement)
    }
    try c.encodeIfPresent(logpush, forKey: .logpush)
  }
}

/// One secret bound to a Worker script (`GET .../scripts/{name}/secrets`).
/// Cloudflare never returns secret values after they are written.
public struct WorkerSecret: Codable, Hashable, Identifiable, Sendable {
  public var id: String { name }
  public let name: String
  public let type: String

  public init(name: String, type: String = "secret_text") {
    self.name = name
    self.type = type
  }

  public var isTextSecret: Bool { type == "secret_text" }
}

/// One Cron Trigger schedule attached to a Worker script
/// (`GET/PUT .../scripts/{name}/schedules`).
public struct WorkerCronTrigger: Codable, Hashable, Identifiable, Sendable {
  public var id: String { cron }
  public let cron: String
  public let createdOn: String?
  public let modifiedOn: String?

  enum CodingKeys: String, CodingKey {
    case cron
    case createdOn = "created_on"
    case modifiedOn = "modified_on"
  }

  public init(cron: String, createdOn: String? = nil, modifiedOn: String? = nil) {
    self.cron = cron
    self.createdOn = createdOn
    self.modifiedOn = modifiedOn
  }
}

private struct WorkerSchedulesEnvelope: Decodable, Sendable {
  let schedules: [WorkerCronTrigger]
}

private struct WorkerScheduleInput: Encodable, Sendable {
  let cron: String
}

private struct WorkerSecretPutBody: Encodable, Sendable {
  let name: String
  let text: String
  let type: String
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

  /// One build by its UUID. Unlike the history list this needs no script tag,
  /// which is what lets a dashboard build link open without resolving one.
  public func getWorkerBuild(accountID: String, buildUUID: String) async throws -> WorkerBuild {
    try await request("/accounts/\(accountID)/builds/builds/\(buildUUID)")
  }

  /// One page of a build's log. Pass the previous page's `cursor` to continue.
  public func getWorkerBuildLogs(
    accountID: String, buildUUID: String, cursor: String? = nil
  ) async throws -> WorkerBuildLogs {
    try await request(
      "/accounts/\(accountID)/builds/builds/\(buildUUID)/logs",
      query: ["cursor": cursor.flatMap { $0.isEmpty ? nil : $0 }])
  }

  /// The whole log, following `cursor` while Cloudflare says a page was
  /// truncated. Bounded on purpose: `truncated` and `cursor` are the only
  /// stop signals the API gives, and a server that never clears them must not
  /// turn one screen into an unbounded download. Reports `truncated` when the
  /// bound, not the log, ended the read.
  public func getWorkerBuildLog(
    accountID: String, buildUUID: String, maxPages: Int = 10
  ) async throws -> WorkerBuildLogs {
    var lines: [WorkerBuildLogLine] = []
    var cursor: String?
    var truncated = false
    for _ in 0..<max(maxPages, 1) {
      let page = try await getWorkerBuildLogs(
        accountID: accountID, buildUUID: buildUUID, cursor: cursor)
      lines.append(contentsOf: page.lines)
      truncated = page.truncated
      // A cursor that does not move, or a page with nothing in it, would
      // re-request the same lines forever.
      guard page.truncated, let next = page.cursor, !next.isEmpty, next != cursor,
        !page.lines.isEmpty
      else { break }
      cursor = next
    }
    return WorkerBuildLogs(lines: lines, cursor: cursor, truncated: truncated)
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

  /// Runtime settings and bindings for a Worker script (`workers-scripts.read`).
  public func getWorkerSettings(accountID: String, scriptName: String) async throws
    -> WorkerSettings
  {
    let encodedName = Self.encodeWorkerPathSegment(scriptName)
    return try await request(
      "/accounts/\(accountID)/workers/scripts/\(encodedName)/settings")
  }

  /// Lists secret names bound to a Worker script (`workers-scripts.read`).
  public func listWorkerSecrets(accountID: String, scriptName: String) async throws
    -> [WorkerSecret]
  {
    let encodedName = Self.encodeWorkerPathSegment(scriptName)
    return try await request(
      "/accounts/\(accountID)/workers/scripts/\(encodedName)/secrets")
  }

  /// Adds or replaces a write-only text secret on a Worker script (`workers-scripts.write`).
  public func putWorkerSecret(
    accountID: String,
    scriptName: String,
    name: String,
    text: String
  ) async throws -> WorkerSecret {
    let encodedName = Self.encodeWorkerPathSegment(scriptName)
    return try await request(
      "/accounts/\(accountID)/workers/scripts/\(encodedName)/secrets",
      method: "PUT",
      body: WorkerSecretPutBody(name: name, text: text, type: "secret_text"))
  }

  /// Deletes a secret binding from a Worker script (`workers-scripts.write`).
  public func deleteWorkerSecret(
    accountID: String,
    scriptName: String,
    secretName: String
  ) async throws {
    let encodedScript = Self.encodeWorkerPathSegment(scriptName)
    let encodedSecret = Self.encodeWorkerPathSegment(secretName)
    let _: JSONValue = try await request(
      "/accounts/\(accountID)/workers/scripts/\(encodedScript)/secrets/\(encodedSecret)",
      method: "DELETE")
  }

  /// Lists Cron Triggers attached to a Worker script (`workers-scripts.read`).
  public func listWorkerSchedules(accountID: String, scriptName: String) async throws
    -> [WorkerCronTrigger]
  {
    let encodedName = Self.encodeWorkerPathSegment(scriptName)
    let envelope: WorkerSchedulesEnvelope = try await request(
      "/accounts/\(accountID)/workers/scripts/\(encodedName)/schedules")
    return envelope.schedules
  }

  /// Replaces the full Cron Triggers list for a Worker script (`workers-scripts.write`).
  public func updateWorkerSchedules(
    accountID: String,
    scriptName: String,
    crons: [String]
  ) async throws -> [WorkerCronTrigger] {
    let encodedName = Self.encodeWorkerPathSegment(scriptName)
    let body = crons.map(WorkerScheduleInput.init(cron:))
    let envelope: WorkerSchedulesEnvelope = try await request(
      "/accounts/\(accountID)/workers/scripts/\(encodedName)/schedules",
      method: "PUT",
      body: body)
    return envelope.schedules
  }

  private static func encodeWorkerPathSegment(_ segment: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#")
    return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
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
