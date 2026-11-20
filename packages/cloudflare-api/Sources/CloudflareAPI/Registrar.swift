import Foundation

// MARK: - Models

/// Registration state from `/registrar/registrations` (beta).
///
/// Every property except `domainName` is optional, and every one of them is
/// decoded leniently. The declaration this replaces made `status`, `autoRenew`,
/// `privacyMode` and `locked` non-optional, so a registration that simply did
/// not carry `privacy_mode` threw the whole detail screen's decode. A field
/// Cloudflare omits — or spells with a type nobody documented — must cost one
/// row, never the screen.
///
/// `status` and `privacyMode` stay raw strings. Cloudflare publishes no enum
/// for either, so an unrecognised value has to survive the wire and be resolved
/// at the last render step (the `WorkerBuild.phase` precedent).
public struct RegistrarRegistration: Codable, Hashable, Identifiable, Sendable {
  public var id: String { domainName }
  public let domainName: String
  public let status: String?
  public let createdAt: String?
  public let expiresAt: String?
  public let autoRenew: Bool?
  public let privacyMode: String?
  public let locked: Bool?

  enum CodingKeys: String, CodingKey {
    case status, locked
    case domainName = "domain_name"
    case createdAt = "created_at"
    case expiresAt = "expires_at"
    case autoRenew = "auto_renew"
    case privacyMode = "privacy_mode"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // The one strict field: a registration with no domain name has no identity
    // and no row to render, so it is a malformed element and `LossyElement`
    // should drop it rather than list a blank.
    domainName = try container.decode(String.self, forKey: .domainName)
    status = container.lenient(String.self, .status)
    createdAt = container.lenient(String.self, .createdAt)
    expiresAt = container.lenient(String.self, .expiresAt)
    autoRenew = container.lenient(Bool.self, .autoRenew)
    privacyMode = container.lenient(String.self, .privacyMode)
    locked = container.lenient(Bool.self, .locked)
  }
}

/// What a Registrar write answers with: the state of the workflow it started.
///
/// Decoded leniently and kept internal — Dash reads only whether it failed and
/// why. `state` stays a raw string so a value Cloudflare adds later falls
/// through as "still running" instead of failing the decode.
struct RegistrarWorkflowStatus: Decodable, Sendable {
  let state: String?
  let error: Failure?

  struct Failure: Decodable, Sendable {
    let message: String?

    enum CodingKeys: String, CodingKey { case message }

    init(from decoder: any Decoder) throws {
      message = try decoder.container(keyedBy: CodingKeys.self).lenient(String.self, .message)
    }
  }

  enum CodingKeys: String, CodingKey { case state, error }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    state = container.lenient(String.self, .state)
    error = container.lenient(Failure.self, .error)
  }
}

// MARK: - Endpoints

extension CloudflareClient {
  /// Every registration on the account, following the beta endpoint's cursor.
  ///
  /// Cannot reuse `listAllPages` — that helper is page-numbered and constrains
  /// `Value: Identifiable where ID == String`. The loop terminates on an empty
  /// page, an empty/absent cursor, a cursor already seen (a server echoing its
  /// own cursor must not spin), or `maxPages`.
  public func listRegistrarRegistrations(
    accountID: String, perPage: Int = 50, maxPages: Int = 20
  ) async throws -> [RegistrarRegistration] {
    let path = "/accounts/\(accountID)/registrar/registrations"
    var registrations: [RegistrarRegistration] = []
    var seenDomains: Set<String> = []
    var seenCursors: Set<String> = []
    var cursor: String?

    for _ in 0..<max(maxPages, 1) {
      let page: Page<RegistrarRegistration> = try await list(
        path,
        query: [
          "per_page": String(perPage),
          "cursor": cursor,
          "sort_by": "registry_expires_at",
          "direction": "asc",
        ])
      registrations.append(
        contentsOf: page.items.filter { seenDomains.insert($0.domainName).inserted })

      guard !page.items.isEmpty else { break }
      guard let nextCursor = page.resultInfo?.cursor, !nextCursor.isEmpty else { break }
      guard seenCursors.insert(nextCursor).inserted else { break }
      cursor = nextCursor
    }

    return registrations
  }

  /// One registration. `domain` is the FQDN — the beta endpoint keys on the
  /// name, not on an opaque id.
  public func getRegistrarRegistration(accountID: String, domain: String) async throws
    -> RegistrarRegistration
  {
    try await request("/accounts/\(accountID)/registrar/registrations/\(domain)")
  }

  /// Turns auto-renew on or off — the only field the Registrar API lets a
  /// client change. The transfer lock, privacy and contacts are read-only here;
  /// the legacy `PUT /registrar/domains/{domain}` that wrote the lock reached
  /// end of life on 2026-09-27 with no replacement.
  ///
  /// The response is a workflow, not the registration. `200` is a finished
  /// workflow and `202` one still running; either way HTTP success says only
  /// that Cloudflare accepted the request, so a `failed` workflow is read out
  /// of the body and thrown — otherwise a renewal that never happened would
  /// report success. `action_required` throws too: it waits on the user and
  /// will not finish by itself. Any other state, or a null result, is still on
  /// its way.
  public func updateRegistrarAutoRenew(
    accountID: String, domain: String, autoRenew: Bool
  ) async throws {
    let workflow: RegistrarWorkflowStatus? = try await request(
      "/accounts/\(accountID)/registrar/registrations/\(domain)", method: "PATCH",
      body: ["auto_renew": autoRenew])
    switch workflow?.state {
    case "failed":
      throw CloudflareAPIError.request(
        status: 200,
        errors: [
          APIErrorItem(
            code: 0,
            message: workflow?.error?.message
              ?? "Cloudflare could not update this registration.")
        ])
    case "action_required":
      throw CloudflareAPIError.request(
        status: 200,
        errors: [
          APIErrorItem(
            code: 0, message: "Finish this change on the Cloudflare dashboard.")
        ])
    default:
      return
    }
  }
}

// MARK: - Lenient decoding

extension KeyedDecodingContainer {
  /// Absent, null, or the wrong type on the wire all resolve to `nil`.
  ///
  /// Every Registrar property but `domainName` is optional, so "Cloudflare did
  /// not say" is already a representable answer — and a `zip` that arrives as a
  /// number must cost that one row, not the screen.
  fileprivate func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
    try? decodeIfPresent(type, forKey: key)
  }
}
