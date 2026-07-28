import Foundation

/// Public registration snapshot for the zone detail card. Produced by the
/// dash-relay `/api/registration/:domain` endpoint (RDAP, then WHOIS) or by
/// parsing a raw RDAP document in tests. Privacy redaction and unsupported
/// TLDs surface as `nil` so the UI can hide the card quietly.
public struct RdapRegistration: Hashable, Sendable, Codable {
  public let domain: String
  public let status: [String]
  public let registrar: String?
  public let registeredOn: String?
  public let expiresOn: String?
  public let updatedOn: String?
  public let nameservers: [String]

  public init(
    domain: String, status: [String] = [], registrar: String? = nil,
    registeredOn: String? = nil, expiresOn: String? = nil, updatedOn: String? = nil,
    nameservers: [String] = []
  ) {
    self.domain = domain
    self.status = status
    self.registrar = registrar
    self.registeredOn = registeredOn
    self.expiresOn = expiresOn
    self.updatedOn = updatedOn
    self.nameservers = nameservers
  }
}

public enum RdapClient: Sendable {
  public enum LookupError: Error, Sendable {
    case invalidDomain
    case httpStatus(Int)
  }

  /// Looks up `domain` via `relayBaseURL/api/registration/{name}` when a relay
  /// origin is configured (RDAP + WHOIS on the worker). Falls back to the
  /// public `rdap.org` bootstrap when `relayBaseURL` is nil (tests / misconfig).
  public static func lookup(
    domain: String,
    relayBaseURL: URL? = nil,
    session: URLSession = .shared
  ) async throws -> RdapRegistration? {
    let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty, trimmed.contains("."), !trimmed.contains("/") else {
      throw LookupError.invalidDomain
    }

    if let relayBaseURL {
      let url =
        relayBaseURL
        .appending(path: "api")
        .appending(path: "registration")
        .appending(path: trimmed)
      var request = URLRequest(url: url)
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { return nil }
      if http.statusCode == 404 || http.statusCode == 204 { return nil }
      guard (200..<300).contains(http.statusCode) else {
        throw LookupError.httpStatus(http.statusCode)
      }
      return decodeSnapshot(data)
    }

    guard
      let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "https://rdap.org/domain/\(encoded)")
    else {
      throw LookupError.invalidDomain
    }
    var request = URLRequest(url: url)
    request.setValue("application/rdap+json, application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { return nil }
    if http.statusCode == 404 || http.statusCode == 204 { return nil }
    guard (200..<300).contains(http.statusCode) else {
      throw LookupError.httpStatus(http.statusCode)
    }
    return parse(data, fallbackDomain: trimmed)
  }

  static func parse(_ data: Data, fallbackDomain: String) -> RdapRegistration? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    let domain =
      (root["ldhName"] as? String) ?? (root["unicodeName"] as? String) ?? fallbackDomain
    let status = (root["status"] as? [String]) ?? []
    let events = (root["events"] as? [[String: Any]]) ?? []
    func eventDate(_ action: String) -> String? {
      events.first {
        ($0["eventAction"] as? String)?.caseInsensitiveCompare(action) == .orderedSame
      }?["eventDate"] as? String
    }
    let nameservers =
      ((root["nameservers"] as? [[String: Any]]) ?? []).compactMap {
        ($0["ldhName"] as? String) ?? ($0["unicodeName"] as? String)
      }.map(strippingRootDot)
    let registrar = registrarName(from: root["entities"] as? [[String: Any]] ?? [])
    let registration = RdapRegistration(
      domain: domain,
      status: status,
      registrar: registrar,
      registeredOn: eventDate("registration"),
      expiresOn: eventDate("expiration"),
      updatedOn: eventDate("last changed") ?? eventDate("last update of RDAP database"),
      nameservers: nameservers)
    return usefulOrNil(registration)
  }

  /// Some RDAP servers return the fully-qualified form (`ns1.example.com.`).
  /// The relay's WHOIS leg strips the root dot, so strip it here too — otherwise
  /// the zone card renders the field differently depending on which leg answered.
  private static func strippingRootDot(_ host: String) -> String {
    host.hasSuffix(".") ? String(host.dropLast()) : host
  }

  private static func decodeSnapshot(_ data: Data) -> RdapRegistration? {
    guard let registration = try? JSONDecoder().decode(RdapRegistration.self, from: data) else {
      return nil
    }
    return usefulOrNil(registration)
  }

  private static func usefulOrNil(_ registration: RdapRegistration) -> RdapRegistration? {
    if registration.registrar == nil, registration.expiresOn == nil,
      registration.registeredOn == nil, registration.status.isEmpty,
      registration.nameservers.isEmpty
    {
      return nil
    }
    return registration
  }

  private static func registrarName(from entities: [[String: Any]]) -> String? {
    for entity in entities {
      let roles = (entity["roles"] as? [String]) ?? []
      guard roles.contains(where: { $0.caseInsensitiveCompare("registrar") == .orderedSame })
      else { continue }
      if let handle = entity["handle"] as? String, !handle.isEmpty { return handle }
      if let vcard = entity["vcardArray"] as? [Any],
        let rows = vcard.last as? [[Any]]
      {
        for row in rows {
          guard let key = row.first as? String, key == "fn",
            let value = row.last as? String, !value.isEmpty
          else { continue }
          return value
        }
      }
    }
    return nil
  }
}
