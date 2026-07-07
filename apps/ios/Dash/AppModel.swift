import AuthenticationServices
import CloudflareAPI
import Foundation
import Observation
import UIKit

enum AuthenticationState: Sendable {
  case authenticated
  case loading
  case unauthenticated
}

@MainActor
@Observable
final class AppModel {
  let configuration: AppConfiguration
  let tokenStore: KeychainTokenStore
  let client: CloudflareClient
  let featureCache = FeatureDataCache()
  var accounts: [CloudflareAccount] = []
  var activeAccountID: String?
  var authState: AuthenticationState = .loading
  var errorMessage: String?
  var isAuthenticating = false
  var user: CloudflareUser?

  private var authSession: ASWebAuthenticationSession?

  init(configuration: AppConfiguration = .current) {
    self.configuration = configuration
    let store = KeychainTokenStore()
    tokenStore = store
    client = CloudflareClient(clientID: configuration.clientID, tokenStore: store)
    activeAccountID = UserDefaults.standard.string(forKey: "dash.active_account_id")
  }

  var activeAccount: CloudflareAccount? { accounts.first { $0.id == activeAccountID } }

  func bootstrap() async {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-ui-preview") {
        authState = .authenticated
        return
      }
    #endif

    do {
      guard try await tokenStore.getAccessToken() != nil else {
        authState = .unauthenticated
        return
      }
      try await loadIdentity()
      authState = .authenticated
    } catch {
      authState = .unauthenticated
    }
  }

  func signIn() {
    guard configuration.isConfigured else {
      errorMessage = "Add DASH_CLIENT_ID and DASH_REDIRECT_URI to Config/Secrets.xcconfig."
      return
    }
    let pkce = PKCEPair.generate()
    let state = UUID().uuidString
    let authorizationURL = OAuth.authorizationURL(
      clientID: configuration.clientID,
      redirectURI: configuration.redirectURI,
      callbackState: state,
      pkce: pkce
    )
    isAuthenticating = true
    errorMessage = nil
    let session = ASWebAuthenticationSession(
      url: authorizationURL, callbackURLScheme: configuration.callbackScheme
    ) { [weak self] url, error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        isAuthenticating = false
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
          return
        }
        guard error == nil, let url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
          errorMessage = error?.localizedDescription ?? "OAuth callback was invalid."
          return
        }
        let values = Dictionary(
          uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard values["state"] == state, let code = values["code"] else {
          errorMessage = values["error_description"] ?? values["error"] ?? "OAuth state mismatch."
          return
        }
        do {
          let tokens = try await OAuth.exchangeCode(
            clientID: configuration.clientID, code: code, verifier: pkce.verifier,
            redirectURI: configuration.redirectURI
          )
          try await tokenStore.setTokens(tokens)
          try await loadIdentity()
          authState = .authenticated
        } catch { errorMessage = error.localizedDescription }
      }
    }
    session.presentationContextProvider = WebAuthenticationContext.shared
    session.prefersEphemeralWebBrowserSession = false
    authSession = session
    if !session.start() {
      isAuthenticating = false
      errorMessage = "Could not start the sign-in session."
    }
  }

  func signOut() async {
    if let token = try? await tokenStore.getAccessToken() {
      try? await OAuth.revoke(clientID: configuration.clientID, token: token)
    }
    try? await tokenStore.clear()
    featureCache.clear()
    accounts = []
    user = nil
    activeAccountID = nil
    UserDefaults.standard.removeObject(forKey: "dash.active_account_id")
    authState = .unauthenticated
  }

  func selectAccount(_ account: CloudflareAccount) {
    guard activeAccountID != account.id else { return }
    featureCache.clear()
    activeAccountID = account.id
    UserDefaults.standard.set(account.id, forKey: "dash.active_account_id")
  }

  func loadIdentity() async throws {
    async let fetchedUser = client.getUser()
    async let fetchedAccounts = client.listAccounts()
    user = try await fetchedUser
    accounts = try await fetchedAccounts
    if activeAccount == nil, let first = accounts.first { selectAccount(first) }
  }
}

private final class WebAuthenticationContext: NSObject,
  ASWebAuthenticationPresentationContextProviding
{
  static let shared = WebAuthenticationContext()
  func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow
      ?? ASPresentationAnchor()
  }
}
