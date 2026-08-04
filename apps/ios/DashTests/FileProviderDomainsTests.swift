import CloudflareAPI
import FileProvider
import Testing

@testable import Dash

@Test func fileProviderReconciliationRemovesOnlyOrphanedDomains() {
  let installed: Set<String> = ["account-mounted", "account-orphaned"]
  let valid: Set<String> = ["account-mounted", "account-not-mounted"]

  let orphaned = FileProviderDomains.orphanedAccountIDs(
    installed: installed,
    validAccountIDs: valid
  )

  #expect(orphaned == ["account-orphaned"])
  #expect(!orphaned.contains("account-not-mounted"))
}

@Test func fileProviderReconciliationMountsEveryAuthenticatedAccount() {
  let unmounted = FileProviderDomains.unmountedAccountIDs(
    installed: ["account-mounted", "account-orphaned"],
    validAccountIDs: ["account-mounted", "account-new"]
  )

  #expect(unmounted == ["account-new"])
  #expect(!unmounted.contains("account-orphaned"))
}

@Test func fileProviderReconciliationPreservesUnverifiedMissingAccounts() {
  let orphaned = FileProviderDomains.orphanedAccountIDs(
    installed: ["account-returned", "account-lossy-row", "account-gone"],
    validAccountIDs: ["account-returned"],
    preservingAccountIDs: ["account-lossy-row"]
  )

  #expect(orphaned == ["account-gone"])
}

@Test func fileProviderReconciliationWaitsForFreshAuthenticatedIdentity() {
  #expect(
    AppModel.shouldReconcileFileProviderDomains(
      authState: .authenticated,
      identityStale: false,
      isDemoSession: false,
      isSigningOut: false
    ))
  #expect(
    !AppModel.shouldReconcileFileProviderDomains(
      authState: .authenticated,
      identityStale: true,
      isDemoSession: false,
      isSigningOut: false
    ))
  #expect(
    !AppModel.shouldReconcileFileProviderDomains(
      authState: .loading,
      identityStale: false,
      isDemoSession: false,
      isSigningOut: false
    ))
  #expect(
    !AppModel.shouldReconcileFileProviderDomains(
      authState: .authenticated,
      identityStale: false,
      isDemoSession: true,
      isSigningOut: false
    ))
  #expect(
    !AppModel.shouldReconcileFileProviderDomains(
      authState: .authenticated,
      identityStale: false,
      isDemoSession: false,
      isSigningOut: true
    ))
}

@Test func fileProviderItemIdentifiersRoundTripWithoutChangingObjectKeys() {
  let identifiers: [R2ItemIdentifier] = [
    .root,
    .bucket("assets"),
    .object(R2ObjectPath(bucket: "assets", key: "reports:2026/final:copy.pdf")),
    .object(R2ObjectPath(bucket: "assets", key: "reports:2026/")),
  ]

  for identifier in identifiers {
    #expect(R2ItemIdentifier(identifier.fileProviderIdentifier) == identifier)
  }

  let object = R2ItemIdentifier.object(
    R2ObjectPath(bucket: "assets", key: "reports:2026/final:copy.pdf"))
  #expect(object.fileProviderIdentifier.rawValue == "o:assets:reports:2026/final:copy.pdf")
  #expect(
    object.parentFileProviderIdentifier
      == NSFileProviderItemIdentifier("o:assets:reports:2026/"))
}
