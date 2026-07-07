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
  public static let all: [String] = [
    "user-details.read", "account-settings.read", "zone.read", "dns.read", "dns.write",
    "cache.purge", "zone-settings.read", "zone-settings.write", "workers-scripts.read",
    "workers-scripts.write", "workers-routes.read", "workers-routes.write",
    "workers-kv-storage.read", "workers-kv-storage.write", "workers-r2.read",
    "workers-r2.write", "workers-r2-bucket-item.read", "workers-r2-bucket-item.write",
    "d1.read", "queues.read", "queues.write", "page.read", "page.write", "analytics.read",
    "account-analytics.read", "firewall-services.read", "firewall-services.write", "zone-waf.read",
    "zone-waf.write", "ssl-and-certificates.read", "healthcheck.read", "waiting-rooms.read",
    "load-balancers.read", "load-balancing-monitors-and-pools.read", "page-rules.read",
    "email-routing-address.read", "email-routing-address.write", "email-routing-rule.read",
    "email-routing-rule.write", "registrar-domains.read", "argotunnel.read", "access-app.read",
    "images.read", "stream.read", "challenge-widgets.read", "challenge-widgets.write",
    "workers-observability.read", "workers-ci.read",
    "secrets-store.read", "vectorize.read", "notifications.read", "offline_access",
  ]
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
    scopes: [String] = CloudflareScopes.all
  ) -> URL {
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
