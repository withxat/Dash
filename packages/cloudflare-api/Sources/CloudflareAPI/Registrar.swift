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

/// A domain from the page-numbered `/registrar/domains` endpoint.
///
/// Deliberately **not** `Identifiable`: the documented example `id` is opaque
/// hex and the object carries no name anywhere else, so making it a list
/// identity invites a screen that renders `ea95132c…` as a row title.
public struct RegistrarDomain: Codable, Hashable, Sendable {
  public let identifier: String?
  public let available: Bool?
  public let canRegister: Bool?
  public let createdAt: String?
  public let currentRegistrar: String?
  public let expiresAt: String?
  public let locked: Bool?
  public let updatedAt: String?
  /// Comma-joined EPP codes as Cloudflare sends them. Read through
  /// `registryStatusList`.
  public let registryStatuses: String?
  public let supportedTLD: Bool?
  public let registrantContact: RegistrarContact?
  public let transferIn: RegistrarTransferIn?

  /// The EPP codes as a list. Cloudflare joins them with commas and pads them
  /// inconsistently, so split, trim and drop the empties.
  public var registryStatusList: [String] {
    (registryStatuses ?? "")
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  enum CodingKeys: String, CodingKey {
    case available, locked
    case identifier = "id"
    case canRegister = "can_register"
    case createdAt = "created_at"
    case currentRegistrar = "current_registrar"
    case expiresAt = "expires_at"
    case updatedAt = "updated_at"
    case registryStatuses = "registry_statuses"
    case supportedTLD = "supported_tld"
    case registrantContact = "registrant_contact"
    case transferIn = "transfer_in"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    identifier = container.lenient(String.self, .identifier)
    available = container.lenient(Bool.self, .available)
    canRegister = container.lenient(Bool.self, .canRegister)
    createdAt = container.lenient(String.self, .createdAt)
    currentRegistrar = container.lenient(String.self, .currentRegistrar)
    expiresAt = container.lenient(String.self, .expiresAt)
    locked = container.lenient(Bool.self, .locked)
    updatedAt = container.lenient(String.self, .updatedAt)
    registryStatuses = container.lenient(String.self, .registryStatuses)
    supportedTLD = container.lenient(Bool.self, .supportedTLD)
    registrantContact = container.lenient(RegistrarContact.self, .registrantContact)
    transferIn = container.lenient(RegistrarTransferIn.self, .transferIn)
  }
}

/// Registrant contact. Nine of these are documented required and every one of
/// them is optional here on purpose: WHOIS redaction and contacts Cloudflare
/// does not manage both come back partial, and one missing key must not fail
/// the detail screen's decode.
public struct RegistrarContact: Codable, Hashable, Sendable {
  public let id: String?
  public let firstName: String?
  public let lastName: String?
  public let organization: String?
  public let address: String?
  public let address2: String?
  public let city: String?
  public let state: String?
  public let zip: String?
  public let country: String?
  public let phone: String?
  public let email: String?
  public let fax: String?

  enum CodingKeys: String, CodingKey {
    case id, organization, address, address2, city, state, zip, country, phone, email, fax
    case firstName = "first_name"
    case lastName = "last_name"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = container.lenient(String.self, .id)
    firstName = container.lenient(String.self, .firstName)
    lastName = container.lenient(String.self, .lastName)
    organization = container.lenient(String.self, .organization)
    address = container.lenient(String.self, .address)
    address2 = container.lenient(String.self, .address2)
    city = container.lenient(String.self, .city)
    state = container.lenient(String.self, .state)
    zip = container.lenient(String.self, .zip)
    country = container.lenient(String.self, .country)
    phone = container.lenient(String.self, .phone)
    email = container.lenient(String.self, .email)
    fax = container.lenient(String.self, .fax)
  }
}

/// Transfer-in progress. Cloudflare documents a small vocabulary for each of
/// these (`needed`, `ok`, `pending`, …) and publishes no enum, so they stay raw
/// strings: an unmodelled value has to reach the render step intact.
public struct RegistrarTransferIn: Codable, Hashable, Sendable {
  public let acceptFoa: String?
  public let approveTransfer: String?
  public let canCancelTransfer: Bool?
  public let disablePrivacy: String?
  public let enterAuthCode: String?
  public let unlockDomain: String?

  enum CodingKeys: String, CodingKey {
    case acceptFoa = "accept_foa"
    case approveTransfer = "approve_transfer"
    case canCancelTransfer = "can_cancel_transfer"
    case disablePrivacy = "disable_privacy"
    case enterAuthCode = "enter_auth_code"
    case unlockDomain = "unlock_domain"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    acceptFoa = container.lenient(String.self, .acceptFoa)
    approveTransfer = container.lenient(String.self, .approveTransfer)
    canCancelTransfer = container.lenient(Bool.self, .canCancelTransfer)
    disablePrivacy = container.lenient(String.self, .disablePrivacy)
    enterAuthCode = container.lenient(String.self, .enterAuthCode)
    unlockDomain = container.lenient(String.self, .unlockDomain)
  }
}

/// The write side of `/registrar/domains/{domain}`, expressed as a delta.
///
/// Not `Codable`: it is encoded field by field so only the flags the user
/// actually changed reach the wire. Re-asserting two settings read off a
/// possibly-stale screen is how a transfer lock gets silently flipped back.
public struct RegistrarDomainSettings: Hashable, Sendable {
  public var autoRenew: Bool?
  public var locked: Bool?
  public var privacy: Bool?

  public init(autoRenew: Bool? = nil, locked: Bool? = nil, privacy: Bool? = nil) {
    self.autoRenew = autoRenew
    self.locked = locked
    self.privacy = privacy
  }

  /// The PUT body, carrying only the flags that changed. Empty when nothing did.
  var wireBody: [String: Bool] {
    var body: [String: Bool] = [:]
    if let autoRenew { body["auto_renew"] = autoRenew }
    if let locked { body["locked"] = locked }
    if let privacy { body["privacy"] = privacy }
    return body
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

  /// One domain from the page-numbered endpoint — the source for registry
  /// statuses, the registrant contact and the current registrar.
  public func getRegistrarDomain(accountID: String, domain: String) async throws -> RegistrarDomain
  {
    try await request("/accounts/\(accountID)/registrar/domains/\(domain)")
  }

  /// Writes **only** the flags present in `settings`.
  ///
  /// The endpoint documents `result: unknown` and returns null in practice, so
  /// the response is decoded as `JSONValue` — which resolves null to `.null`
  /// instead of throwing. A settings delta with nothing in it sends no request:
  /// an empty body would re-assert nothing and Cloudflare has no reason to
  /// accept it.
  public func updateRegistrarDomain(
    accountID: String, domain: String, settings: RegistrarDomainSettings
  ) async throws {
    let body = settings.wireBody
    guard !body.isEmpty else { return }
    let _: JSONValue = try await request(
      "/accounts/\(accountID)/registrar/domains/\(domain)", method: "PUT", body: body)
  }

  /// The page-numbered `/registrar/domains` list.
  ///
  /// Rows whose `id` carries no dot are dropped: the identifier is the only
  /// name on the object, and an opaque hex id renders as an unlabelled row.
  /// Filtering happens after the pagination bookkeeping so a page full of
  /// hex ids cannot be mistaken for a short final page.
  public func listRegistrarDomainsLegacy(accountID: String, perPage: Int = 50) async throws
    -> [RegistrarDomain]
  {
    let path = "/accounts/\(accountID)/registrar/domains"
    var domains: [RegistrarDomain] = []
    var seenIdentifiers: Set<String> = []
    var pageNumber = 1

    while pageNumber <= Self.registrarLegacyPageLimit {
      let page: Page<RegistrarDomain> = try await list(
        path, query: ["page": String(pageNumber), "per_page": String(perPage)])
      domains.append(
        contentsOf: page.items.filter { domain in
          guard let identifier = domain.identifier else { return true }
          return seenIdentifiers.insert(identifier).inserted
        })

      if let totalCount = page.resultInfo?.totalCount, domains.count >= totalCount { break }
      if let totalPages = page.resultInfo?.totalPages, pageNumber >= totalPages { break }
      guard !page.items.isEmpty else { break }
      if page.resultInfo?.totalCount == nil, page.resultInfo?.totalPages == nil {
        let reportedPageSize = page.resultInfo?.perPage ?? perPage
        guard page.items.count >= reportedPageSize else { break }
      }
      pageNumber += 1
    }

    return domains.filter { ($0.identifier ?? "").contains(".") }
  }

  /// Hard bound on the legacy loop. The endpoint reports `total_pages`, so this
  /// only ever fires for a server that stops reporting it and keeps answering
  /// full pages.
  static let registrarLegacyPageLimit = 40
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
