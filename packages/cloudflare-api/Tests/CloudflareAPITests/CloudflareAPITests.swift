import CryptoKit
import Foundation
import Testing

@testable import CloudflareAPI

@Test func pkceUsesURLSafeSHA256Challenge() {
  let pair = PKCEPair.generate()
  #expect(pair.verifier.count >= 43)
  #expect(!pair.challenge.contains("+"))
  #expect(!pair.challenge.contains("/"))
  #expect(!pair.challenge.contains("="))
  let expected = Data(SHA256.hash(data: Data(pair.verifier.utf8))).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
  #expect(pair.challenge == expected)
}

@Test func authorizationURLContainsRequiredOAuthParameters() throws {
  let url = OAuth.authorizationURL(
    clientID: "client", redirectURI: "https://relay.example/oauth/callback", callbackState: "state",
    pkce: PKCEPair(verifier: "verifier", challenge: "challenge"), scopes: ["zone.read"]
  )
  let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
  let values = Dictionary(
    uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
  #expect(values["client_id"] == "client")
  #expect(values["state"] == "state")
  #expect(values["code_challenge_method"] == "S256")
  #expect(values["scope"] == "zone.read")
}

@Test func decodesPaginatedZoneEnvelope() throws {
  let data = Data(
    #"{"success":true,"result":[{"id":"zone","name":"example.com","status":"active"}],"result_info":{"page":1,"per_page":50,"total_count":1}}"#
      .utf8)
  let envelope = try JSONDecoder().decode(APIEnvelope<[CloudflareZone]>.self, from: data)
  #expect(envelope.result.first?.name == "example.com")
  #expect(envelope.resultInfo?.totalCount == 1)
}
