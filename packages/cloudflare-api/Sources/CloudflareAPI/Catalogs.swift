import Foundation

public enum OAuthScopeRisk: String, Codable, Hashable, Sendable {
  case read
  case write
  case elevated
}

public struct OAuthScopeDefinition: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let category: String

  public var risk: OAuthScopeRisk {
    if id.localizedCaseInsensitiveContains("pii")
      || id.hasSuffix(".admin") || id.hasSuffix(".revoke") || id.hasSuffix(".run")
      || id.hasSuffix(".index") || id.hasSuffix(".evaluate") || id.hasSuffix(".send")
      || id.hasSuffix(".bind") || id.hasSuffix(".monitoring") || id.hasSuffix(".location")
      || id.hasSuffix(".shield") || id == "cache.purge"
    {
      return .elevated
    }
    if id.hasSuffix(".write") || id.hasSuffix(".edit") || id.hasSuffix(".setup")
      || id.hasSuffix(".realtime")
    {
      return .write
    }
    return .read
  }

  public var categoryTitle: String {
    category
      .split(separator: "_")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
      .replacingOccurrences(of: " And ", with: " & ")
  }
}

public struct OAuthProductDefinition: Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let category: String
  public let scopes: [OAuthScopeDefinition]

  public var categoryTitle: String { scopes.first?.categoryTitle ?? category }
  public var scopeIDs: Set<String> { Set(scopes.map(\.id)) }
  public var elevatedScopeCount: Int { scopes.filter { $0.risk == .elevated }.count }
}

public struct CloudflareEndpointDefinition: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let method: String
  public let path: String
  public let summary: String
  public let tags: [String]
  public let hasRequestBody: Bool
  public let pathParameters: [String]

  public var primaryTag: String { tags.first ?? "Other" }
  public var isMutation: Bool { method != "GET" && method != "HEAD" }
}

public enum OAuthScopeDisposition: String, Codable, Hashable, Sendable {
  case implemented
  case noPublicEndpoint
  case protocolManaged
}

public struct OAuthScopeCoverageEntry: Codable, Hashable, Identifiable, Sendable {
  public var id: String { scopeID }
  public let scopeID: String
  public let disposition: OAuthScopeDisposition
  public let reason: String?
  public let endpointCount: Int
  public let endpointIDs: [String]
}

private struct OAuthScopeCatalogPayload: Decodable {
  let generatedAt: String
  let scopes: [OAuthScopeDefinition]
}

private struct CloudflareEndpointCatalogPayload: Decodable {
  let generatedAt: String
  let source: String?
  let endpoints: [CloudflareEndpointDefinition]
}

private struct OAuthScopeCoveragePayload: Decodable {
  let generatedAt: String
  let entries: [OAuthScopeCoverageEntry]
}

public enum OAuthScopeCatalog {
  private static let payload: OAuthScopeCatalogPayload = loadCatalog(
    "OAuthScopeCatalog",
    as: OAuthScopeCatalogPayload.self
  )

  public static let generatedAt = payload.generatedAt
  public static let all = payload.scopes
  public static let allIDs = payload.scopes.map(\.id)
  public static let byID = Dictionary(uniqueKeysWithValues: payload.scopes.map { ($0.id, $0) })
  public static let categories = Dictionary(grouping: payload.scopes, by: \.category)
  public static let products: [OAuthProductDefinition] = {
    Dictionary(grouping: payload.scopes, by: productID)
      .map { id, scopes in
        let sorted = scopes.sorted { $0.name < $1.name }
        return OAuthProductDefinition(
          id: id,
          name: productName(from: sorted),
          category: sorted.first?.category ?? "other",
          scopes: sorted
        )
      }
      .sorted {
        if $0.categoryTitle == $1.categoryTitle {
          return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return $0.categoryTitle.localizedStandardCompare($1.categoryTitle) == .orderedAscending
      }
  }()

  private static func productID(for scope: OAuthScopeDefinition) -> String {
    let suffixes = [
      ".read", ".write", ".admin", ".edit", ".run", ".index", ".evaluate", ".send",
      ".setup", ".revoke", ".metadata_read", ".monitoring",
    ]
    return suffixes.first(where: scope.id.hasSuffix).map {
      String(scope.id.dropLast($0.count))
    } ?? scope.id
  }

  private static func productName(from scopes: [OAuthScopeDefinition]) -> String {
    let preferred =
      scopes.first(where: { $0.id.hasSuffix(".read") })
      ?? scopes.min(by: { $0.name.count < $1.name.count })
    guard let preferred else { return "Unknown" }
    let suffixes = [
      " Metadata Read", " Read", " Write", " Admin", " Edit", " Run", " Evaluate", " Send",
    ]
    return suffixes.first(where: preferred.name.hasSuffix).map {
      String(preferred.name.dropLast($0.count))
    } ?? preferred.name
  }
}

public enum CloudflareEndpointCatalog {
  private static let payload: CloudflareEndpointCatalogPayload = loadCatalog(
    "CloudflareEndpointCatalog",
    as: CloudflareEndpointCatalogPayload.self
  )

  public static let generatedAt = payload.generatedAt
  public static let source = payload.source
  public static let all = payload.endpoints
  public static let byTag = Dictionary(grouping: payload.endpoints, by: \.primaryTag)
}

public enum OAuthScopeCoverage {
  private static let payload: OAuthScopeCoveragePayload = loadCatalog(
    "OAuthScopeCoverage",
    as: OAuthScopeCoveragePayload.self
  )

  public static let generatedAt = payload.generatedAt
  public static let all = payload.entries
  public static let byScopeID = Dictionary(
    uniqueKeysWithValues: payload.entries.map {
      ($0.scopeID, $0)
    })
  public static let protocolManaged = [
    OAuthScopeCoverageEntry(
      scopeID: "offline_access",
      disposition: .protocolManaged,
      reason: "OAuth refresh-token protocol scope.",
      endpointCount: 0,
      endpointIDs: []
    )
  ]
}

private func loadCatalog<Value: Decodable>(_ name: String, as type: Value.Type) -> Value {
  guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
    preconditionFailure("Missing generated catalog resource \(name).json")
  }
  do {
    return try JSONDecoder().decode(type, from: Data(contentsOf: url))
  } catch {
    preconditionFailure("Could not decode \(name).json: \(error)")
  }
}
