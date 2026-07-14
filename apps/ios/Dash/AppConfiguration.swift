import Foundation

struct AppConfiguration: Sendable {
  let clientID: String
  let redirectURI: String
  let callbackScheme = "dash"

  var isConfigured: Bool {
    !clientID.isEmpty && !redirectURI.isEmpty && !clientID.contains("$(")
      && !redirectURI.contains("$(")
  }

  /// Origin of the OAuth redirect worker, used as the push registration base.
  /// Nil when redirect URI is missing, unexpanded, or not https — push then
  /// degrades silently, same as an unavailable Keychain access group.
  var pushBaseURL: URL? {
    guard !redirectURI.isEmpty, !redirectURI.contains("$("),
      let url = URL(string: redirectURI),
      let scheme = url.scheme?.lowercased(), scheme == "https",
      let host = url.host, !host.isEmpty
    else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.port = url.port
    return components.url
  }

  static let current = AppConfiguration(
    clientID: Bundle.main.object(forInfoDictionaryKey: "DASHClientID") as? String ?? "",
    redirectURI: Bundle.main.object(forInfoDictionaryKey: "DASHRedirectURI") as? String ?? ""
  )
}
