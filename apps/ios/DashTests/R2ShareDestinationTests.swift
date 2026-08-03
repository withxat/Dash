import Foundation
import Testing

@testable import Dash

private func r2ShareTestDefaults() -> (defaults: UserDefaults, suite: String) {
  let suite = "R2ShareDestinationTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return (defaults, suite)
}

private func sampleDestination(
  accountID: String = "account-a",
  bucket: String = "assets",
  prefix: String = "images/",
  publicHost: String = "cdn.example.com"
) -> R2ShareDestination {
  R2ShareDestination(
    accountID: accountID,
    bucket: bucket,
    prefix: prefix,
    publicHost: publicHost)
}

@Test func r2ShareWriteAccessFailsClosedWithoutScopes() {
  #expect(!R2ShareDestination.hasWriteAccess(grantedScopes: nil))
  #expect(!R2ShareDestination.hasWriteAccess(grantedScopes: []))
}

@Test func r2ShareWriteAccessRequiresBothR2WriteScopes() {
  #expect(
    !R2ShareDestination.hasWriteAccess(
      grantedScopes: ["workers-r2.write"]))
  #expect(
    !R2ShareDestination.hasWriteAccess(
      grantedScopes: ["workers-r2-bucket-item.write"]))
  #expect(
    !R2ShareDestination.hasWriteAccess(
      grantedScopes: DashAuthorizationScopes.initialReadOnly))
  #expect(
    R2ShareDestination.hasWriteAccess(
      grantedScopes: R2ShareDestination.requiredWriteScopes))
  #expect(
    R2ShareDestination.hasWriteAccess(
      grantedScopes: DashAuthorizationScopes.core))
}

@Test func r2ShareDestinationRoundTripsThroughJSON() {
  let original = sampleDestination(
    accountID: "acct-1",
    bucket: "my-bucket",
    prefix: "nested/path/",
    publicHost: "pub.example.r2.dev")
  let encoded = R2ShareDestination.encode([original])
  let decoded = R2ShareDestination.decode(encoded)

  #expect(decoded == [original])
}

@Test func r2ShareDecodeReturnsEmptyForGarbage() {
  #expect(R2ShareDestination.decode("").isEmpty)
  #expect(R2ShareDestination.decode("not-json").isEmpty)
  #expect(R2ShareDestination.decode("{").isEmpty)
  #expect(R2ShareDestination.decode("[]").isEmpty)
  #expect(
    R2ShareDestination.decode(
      #"{"accountID":"a","bucket":"b","prefix":"","publicHost":""}"#
    ).isEmpty)
}

@Test func r2ShareRecordPersistsPerAccountAndOverwritesSameAccount() {
  let (defaults, suite) = r2ShareTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }

  let first = sampleDestination(accountID: "acct-a", bucket: "one", prefix: "a/")
  let second = sampleDestination(accountID: "acct-b", bucket: "two", prefix: "b/")
  R2ShareDestination.record(first, in: defaults)
  R2ShareDestination.record(second, in: defaults)

  #expect(R2ShareDestination.destination(accountID: "acct-a", in: defaults) == first)
  #expect(R2ShareDestination.destination(accountID: "acct-b", in: defaults) == second)

  let updated = sampleDestination(accountID: "acct-a", bucket: "one-v2", prefix: "next/")
  R2ShareDestination.record(updated, in: defaults)

  #expect(R2ShareDestination.destination(accountID: "acct-a", in: defaults) == updated)
  #expect(R2ShareDestination.destination(accountID: "acct-b", in: defaults) == second)
  #expect(
    R2ShareDestination.decode(defaults.string(forKey: R2ShareDestination.destinationsKey) ?? "")
      .count == 2)
}

@Test func r2ShareRecordEnforcesDestinationLimit() {
  let (defaults, suite) = r2ShareTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }

  for index in 0..<(R2ShareDestination.limit + 2) {
    R2ShareDestination.record(
      sampleDestination(
        accountID: "acct-\(index)",
        bucket: "bucket-\(index)",
        prefix: "p-\(index)/"),
      in: defaults)
  }

  let stored = R2ShareDestination.decode(
    defaults.string(forKey: R2ShareDestination.destinationsKey) ?? "")
  #expect(stored.count == R2ShareDestination.limit)
  #expect(stored.first?.accountID == "acct-\(R2ShareDestination.limit + 1)")
  #expect(stored.last?.accountID == "acct-2")
  #expect(!stored.contains(where: { $0.accountID == "acct-0" }))
  #expect(!stored.contains(where: { $0.accountID == "acct-1" }))
}

@Test func r2ShareActiveAccountMirrorGetSetAndClear() {
  let (defaults, suite) = r2ShareTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }

  #expect(R2ShareDestination.activeAccountID(in: defaults) == nil)
  #expect(!R2ShareDestination.isActiveAccount("acct-a", in: defaults))

  R2ShareDestination.setActiveAccountID("acct-a", in: defaults)
  #expect(R2ShareDestination.activeAccountID(in: defaults) == "acct-a")
  #expect(R2ShareDestination.isActiveAccount("acct-a", in: defaults))
  #expect(!R2ShareDestination.isActiveAccount("acct-b", in: defaults))

  R2ShareDestination.setActiveAccountID(nil, in: defaults)
  #expect(R2ShareDestination.activeAccountID(in: defaults) == nil)

  R2ShareDestination.setActiveAccountID("", in: defaults)
  #expect(R2ShareDestination.activeAccountID(in: defaults) == nil)
}

@Test func r2ShareClearRemovesDestinationsAndActiveAccount() {
  let (defaults, suite) = r2ShareTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }

  R2ShareDestination.record(sampleDestination(), in: defaults)
  R2ShareDestination.setActiveAccountID("account-a", in: defaults)

  R2ShareDestination.clear(in: defaults)

  #expect(R2ShareDestination.destination(accountID: "account-a", in: defaults) == nil)
  #expect(R2ShareDestination.activeAccountID(in: defaults) == nil)
  #expect(defaults.string(forKey: R2ShareDestination.destinationsKey) == nil)
}
