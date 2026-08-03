import CloudflareAPI
import Testing

@testable import Dash

@Test func keychainCredentialSnapshotPreservesEveryStoredField() throws {
  let snapshot = KeychainStoredCredentialSnapshot(
    accessToken: "old-access",
    refreshToken: "old-refresh",
    rawExpirationTimestamp: "1900000000.125",
    rawGrantedScopes: "account.read dns.read zone.read")

  #expect(snapshot.accessToken == "old-access")
  #expect(snapshot.refreshToken == "old-refresh")
  #expect(snapshot.rawExpirationTimestamp == "1900000000.125")
  #expect(snapshot.rawGrantedScopes == "account.read dns.read zone.read")
  #expect(snapshot.grantedScopes == ["account.read", "dns.read", "zone.read"])

  let tokens = try #require(snapshot.tokenSet)
  #expect(tokens.accessToken == "old-access")
  #expect(tokens.refreshToken == "old-refresh")
  #expect(tokens.scope == "account.read dns.read zone.read")
  // The absolute Keychain timestamp must never be converted into a fresh TTL.
  #expect(tokens.expiresIn == nil)
}

@Test func keychainReplacementReceiptRestoresOnlyItsExactInstalledSnapshot() {
  let previous = KeychainStoredCredentialSnapshot(
    accessToken: "old-access",
    refreshToken: "old-refresh",
    rawExpirationTimestamp: "1800000000",
    rawGrantedScopes: "zone.read")
  let installed = KeychainStoredCredentialSnapshot(
    accessToken: "new-access",
    refreshToken: "new-refresh",
    rawExpirationTimestamp: "1900000000",
    rawGrantedScopes: "account.read zone.read")
  let replacement = KeychainCredentialReplacement(
    previousCredential: previous,
    installedCredential: installed)

  #expect(replacement.previousCredential == previous)
  #expect(replacement.permitsRestoration(over: installed))

  let rotatedByWidget = KeychainStoredCredentialSnapshot(
    accessToken: "rotated-access",
    refreshToken: "rotated-refresh",
    rawExpirationTimestamp: "1900003600",
    rawGrantedScopes: installed.rawGrantedScopes)
  #expect(!replacement.permitsRestoration(over: rotatedByWidget))

  let replacedByLaterOAuth = KeychainStoredCredentialSnapshot(
    accessToken: "later-access",
    refreshToken: "later-refresh",
    rawExpirationTimestamp: installed.rawExpirationTimestamp,
    rawGrantedScopes: installed.rawGrantedScopes)
  #expect(!replacement.permitsRestoration(over: replacedByLaterOAuth))
}

@Test func keychainReplacementReceiptIncludesMetadataInItsCompareAndSwap() {
  let installed = KeychainStoredCredentialSnapshot(
    accessToken: "access",
    refreshToken: "refresh",
    rawExpirationTimestamp: "1900000000",
    rawGrantedScopes: "zone.read")
  let replacement = KeychainCredentialReplacement(
    previousCredential: .empty,
    installedCredential: installed)

  let scopeMutation = KeychainStoredCredentialSnapshot(
    accessToken: installed.accessToken,
    refreshToken: installed.refreshToken,
    rawExpirationTimestamp: installed.rawExpirationTimestamp,
    rawGrantedScopes: "account.read zone.read")
  #expect(!replacement.permitsRestoration(over: scopeMutation))

  let expiryMutation = KeychainStoredCredentialSnapshot(
    accessToken: installed.accessToken,
    refreshToken: installed.refreshToken,
    rawExpirationTimestamp: "1900003600",
    rawGrantedScopes: installed.rawGrantedScopes)
  #expect(!replacement.permitsRestoration(over: expiryMutation))
}

@Test func keychainSnapshotWithoutAccessTokenCannotCreateCleanupClientTokens() {
  let orphanedFields = KeychainStoredCredentialSnapshot(
    accessToken: nil,
    refreshToken: "orphaned-refresh",
    rawExpirationTimestamp: "1900000000",
    rawGrantedScopes: "zone.read")

  #expect(orphanedFields.tokenSet == nil)
  #expect(orphanedFields != .empty)
}
