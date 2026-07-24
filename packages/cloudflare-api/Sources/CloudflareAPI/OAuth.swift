import CryptoKit
import Foundation

public enum CloudflareEndpoints {
  public static let api = URL(string: "https://api.cloudflare.com/client/v4")!
  public static let authorization = URL(string: "https://dash.cloudflare.com/oauth2/authorize")!
  public static let graphql = URL(string: "https://api.cloudflare.com/client/v4/graphql")!
  public static let revoke = URL(string: "https://dash.cloudflare.com/oauth2/revoke")!
  public static let token = URL(string: "https://dash.cloudflare.com/oauth2/token")!
}

public enum CloudflareScopes {
  public static let protocolScopes = ["offline_access"]
  public static let required = ["user-details.read", "account-settings.read", "offline_access"]
  public static let all: [String] = OAuthScopeCatalog.allIDs + protocolScopes
  public static let unsupportedByOAuthClient: Set<String> = [
    "ai-search.metadata_read",
    "aig.metadata_read",
    "d1.metadata_read",
    "images.metadata_read",
    "pages.metadata_read",
    "queues.metadata_read",
    "stream.metadata_read",
    "workers-kv-storage.metadata_read",
    "workers-r2.metadata_read",
    "workers_ai.metadata_read",
  ]
  public static let requestable = Set(all).subtracting(unsupportedByOAuthClient)
  public static let published = requestable.sorted()

  public static func sanitized(_ scopes: [String]) -> [String] {
    Array(Set(scopes).intersection(requestable)).sorted()
  }

  public static func invalid(in scopes: [String]) -> Set<String> {
    Set(scopes).subtracting(Set(all))
  }

  public static func unsupported(in scopes: [String]) -> Set<String> {
    Set(scopes).intersection(unsupportedByOAuthClient)
  }
}

public struct PKCEPair: Hashable, Sendable {
  public let verifier: String
  public let challenge: String

  public static func generate() -> PKCEPair {
    let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
    let verifier = Data(bytes).base64URLEncodedString()
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return PKCEPair(verifier: verifier, challenge: Data(digest).base64URLEncodedString())
  }
}

public enum OAuth {
  public static func authorizationURL(
    clientID: String, redirectURI: String, callbackState: String, pkce: PKCEPair,
    scopes: [String]
  ) -> URL {
    let scopes = CloudflareScopes.sanitized(scopes)
    var components = URLComponents(
      url: CloudflareEndpoints.authorization, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
      URLQueryItem(name: "state", value: callbackState),
      URLQueryItem(name: "code_challenge", value: pkce.challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    return components.url!
  }

  public static func exchangeCode(
    clientID: String, code: String, verifier: String, redirectURI: String,
    session: URLSession = .shared, tokenURL: URL = CloudflareEndpoints.token
  ) async throws -> TokenSet {
    try await postForm(
      [
        "client_id": clientID, "code": code, "code_verifier": verifier,
        "grant_type": "authorization_code", "redirect_uri": redirectURI,
      ], to: tokenURL, session: session)
  }

  public static func refresh(
    clientID: String, refreshToken: String, session: URLSession = .shared,
    tokenURL: URL = CloudflareEndpoints.token
  ) async throws -> TokenSet {
    try await postForm(
      [
        "client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken,
      ], to: tokenURL, session: session)
  }

  public static func revoke(
    clientID: String, token: String, session: URLSession = .shared,
    revokeURL: URL = CloudflareEndpoints.revoke
  ) async throws {
    _ = try await postFormData(
      [
        "client_id": clientID, "token": token, "token_type_hint": "access_token",
      ], to: revokeURL, session: session)
  }

  private static func postForm<T: Decodable & Sendable>(
    _ values: [String: String], to url: URL, session: URLSession
  ) async throws -> T {
    let data = try await postFormData(values, to: url, session: session)
    do { return try JSONDecoder().decode(T.self, from: data) } catch {
      throw CloudflareAPIError.oauth("Invalid OAuth response: \(error.localizedDescription)")
    }
  }

  private static func postFormData(
    _ values: [String: String], to url: URL, session: URLSession
  ) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody =
      values
      .sorted { $0.key < $1.key }
      .map { "\($0.key.percentEncoded)=\($0.value.percentEncoded)" }
      .joined(separator: "&").data(using: .utf8)
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw CloudflareAPIError.invalidResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      let payload = try? JSONDecoder().decode(OAuthFailure.self, from: data)
      // Preserve the OAuth error code so callers can distinguish a revoked /
      // expired refresh token (`invalid_grant`) from a transient token-endpoint
      // failure. Prefer the code over `error_description` for that case.
      if payload?.error == "invalid_grant" {
        throw CloudflareAPIError.oauth("invalid_grant")
      }
      throw CloudflareAPIError.oauth(
        payload?.errorDescription ?? payload?.error ?? "OAuth HTTP \(response.statusCode)")
    }
    return data
  }
}

private struct OAuthFailure: Decodable {
  let error: String?
  let errorDescription: String?

  enum CodingKeys: String, CodingKey {
    case error
    case errorDescription = "error_description"
  }
}

extension String {
  fileprivate var percentEncoded: String {
    addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self
  }
}

extension Data {
  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
