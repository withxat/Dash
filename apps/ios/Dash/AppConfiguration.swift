import Foundation

struct AppConfiguration: Sendable {
  let clientID: String
  let redirectURI: String
  let callbackScheme = "dash"

  var isConfigured: Bool {
    !clientID.isEmpty && !redirectURI.isEmpty && !clientID.contains("$(")
      && !redirectURI.contains("$(")
  }

  static let current = AppConfiguration(
    clientID: Bundle.main.object(forInfoDictionaryKey: "DASHClientID") as? String ?? "",
    redirectURI: Bundle.main.object(forInfoDictionaryKey: "DASHRedirectURI") as? String ?? ""
  )
}
