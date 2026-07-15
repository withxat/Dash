import Foundation

public struct OAuthScopeDefinition: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let category: String
}

private struct OAuthScopeCatalogPayload: Decodable {
  let generatedAt: String
  let scopes: [OAuthScopeDefinition]
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
