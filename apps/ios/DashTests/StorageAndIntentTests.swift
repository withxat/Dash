import CloudflareAPI
import CoreText
import SwiftUI
import Testing
import UIKit

@testable import Dash

@Test func r2DelayedAttachmentGateRejectsStaleAndDismantledCallbacks() {
  var gate = R2DelayedAttachmentGate()
  let first = gate.schedule()
  #expect(gate.accepts(first))
  let second = gate.schedule()
  #expect(!gate.accepts(first))
  #expect(gate.accepts(second))
  gate.invalidate()
  #expect(!gate.accepts(second))
}

@Test func r2BucketIntentEntityIdentifierIncludesAccount() throws {
  let first = R2BucketEntity(
    accountID: "account-a", accountName: "Personal", name: "assets")
  let second = R2BucketEntity(
    accountID: "account-b", accountName: "Work", name: "assets")

  #expect(first.id != second.id)
  #expect(first.displayRepresentation != second.displayRepresentation)

  let decoded = try #require(R2BucketEntity.decodeIdentifier(first.id))
  #expect(decoded.accountID == "account-a")
  #expect(decoded.bucketName == "assets")
  #expect(R2BucketEntity.decodeIdentifier("assets") == nil)
}

@Test func zoneEntityMapsFromCloudflareZone() throws {
  let zone = try JSONDecoder().decode(
    CloudflareZone.self,
    from: Data(#"{"id":"z1","name":"example.com","status":"active"}"#.utf8))
  let entity = ZoneEntity(zone: zone)
  #expect(entity.id == "z1")
  #expect(entity.name == "example.com")
}

@Test func r2MediaDetectsImagesByExtensionAndContentType() throws {
  #expect(R2Media.isImageKey("photos/cover.JPG"))
  #expect(R2Media.isImageKey("a/b/c.webp"))
  #expect(!R2Media.isImageKey("archive.zip"))
  #expect(!R2Media.isImageKey("Makefile"))
  #expect(!R2Media.isImageKey("photos/"))
  #expect(!R2Media.isImageKey("diagram.svg"))

  let decoder = JSONDecoder()
  let typed = try decoder.decode(
    R2Object.self,
    from: Data(#"{"key":"blob","http_metadata":{"contentType":"image/png"}}"#.utf8))
  #expect(R2Media.isImage(typed))
  let svg = try decoder.decode(
    R2Object.self,
    from: Data(#"{"key":"pic.png","http_metadata":{"contentType":"image/svg+xml"}}"#.utf8))
  #expect(!R2Media.isImage(svg))
  #expect(R2Media.mimeType(forKey: "photos/cover.jpg") == "image/jpeg")
}

@Test func r2DomainsSnapshotPrefersServingCustomDomainOverR2Dev() {
  let managed = R2ManagedDomain(bucketId: "b", domain: "pub-b.r2.dev", enabled: true)
  let decoder = JSONDecoder()
  let serving = try? decoder.decode(
    R2CustomDomain.self,
    from: Data(
      #"{"domain":"img.example.com","enabled":true,"status":{"ownership":"active","ssl":"active"}}"#
        .utf8))
  let pending = try? decoder.decode(
    R2CustomDomain.self,
    from: Data(
      #"{"domain":"cdn.example.net","enabled":true,"status":{"ownership":"pending","ssl":"pending"}}"#
        .utf8))

  let full = R2DomainsSnapshot(managed: managed, custom: [pending, serving].compactMap { $0 })
  #expect(full.publicHost == "img.example.com")

  let pendingOnly = R2DomainsSnapshot(managed: managed, custom: [pending].compactMap { $0 })
  #expect(pendingOnly.publicHost == "pub-b.r2.dev")

  let disabled = R2ManagedDomain(bucketId: "b", domain: "pub-b.r2.dev", enabled: false)
  let dark = R2DomainsSnapshot(managed: disabled, custom: [])
  #expect(dark.publicHost == nil)
}

@Test func r2PublicURLEncodesKeyPathSegments() {
  let snapshot = R2DomainsSnapshot(
    managed: R2ManagedDomain(bucketId: "b", domain: "img.example.com", enabled: true), custom: [])
  let url = snapshot.publicURL(forKey: "photos/2026/日本 trip #1.png")
  #expect(url?.host() == "img.example.com")
  #expect(url?.path(percentEncoded: false) == "/photos/2026/日本 trip #1.png")
  #expect(url?.absoluteString.contains("#") == false)
}

@Test func uploadIntentNormalizesFolderPrefixes() {
  #expect(UploadToR2Intent.normalizedPrefix("") == "")
  #expect(UploadToR2Intent.normalizedPrefix("  ") == "")
  #expect(UploadToR2Intent.normalizedPrefix("/a/b") == "a/b/")
  #expect(UploadToR2Intent.normalizedPrefix("a/b/") == "a/b/")
  #expect(UploadToR2Intent.normalizedPrefix("a") == "a/")
}

@Test func kvJSONFormattingPrettyPrintsAndRejectsPlainText() {
  #expect(KVJSONFormatting.isValidJSON(#"{"a":1}"#))
  #expect(KVJSONFormatting.isValidJSON(#""hello""#))
  #expect(!KVJSONFormatting.isValidJSON("not-json"))
  #expect(KVJSONFormatting.prettyPrinted("not-json") == nil)

  let pretty = KVJSONFormatting.prettyPrinted(#"{"title":"Dash","n":2}"#)
  #expect(pretty?.contains("\n") == true)
  #expect(pretty?.contains("\"title\"") == true)

  #expect(KVJSONFormatting.preparedForDisplay("plain") == "plain")
  #expect(KVJSONFormatting.preparedForDisplay(#"{"x":1}"#).contains("\n"))
  let compactExpandingJSON =
    "[" + Array(repeating: "0", count: 70_000).joined(separator: ",") + "]"
  #expect(KVJSONFormatting.isWithinDisplayLimit(compactExpandingJSON))
  #expect(KVJSONFormatting.prettyPrinted(compactExpandingJSON) != nil)
  #expect(KVJSONFormatting.prettyPrintedForDisplay(compactExpandingJSON) == nil)
  #expect(KVJSONFormatting.preparedForDisplay(compactExpandingJSON) == compactExpandingJSON)

  let aboveDisplayLimit = KVJSONFormatting.displayByteLimit + 1
  #expect(!KVJSONFormatting.isWithinDisplayLimit(byteCount: aboveDisplayLimit))
  #expect(KVValueLimits.writeByteLimit == 25 * 1024 * 1024)
  #expect(KVValueLimits.isWithinWriteLimit(byteCount: aboveDisplayLimit))
  #expect(KVValueLimits.isWithinWriteLimit(byteCount: KVValueLimits.writeByteLimit))
  #expect(!KVValueLimits.isWithinWriteLimit(byteCount: KVValueLimits.writeByteLimit + 1))

  let oversized = Data(repeating: 0x61, count: KVJSONFormatting.displayByteLimit + 1)
  #expect(KVJSONFormatting.displayValue(for: oversized) == .tooLarge)
  #expect(KVJSONFormatting.displayValue(for: Data([0xFF, 0xFE])) == .nonText)
  #expect(
    KVJSONFormatting.displayValue(for: Data(#"{"x":1}"#.utf8))
      == .text("{\n  \"x\" : 1\n}"))
}

@Test func kvJSONValidityDecisionTracksDisplayByteBoundaries() {
  let limit = KVJSONFormatting.displayByteLimit

  let below = KVJSONValidityDecision.limits(for: String(repeating: "a", count: limit - 1))
  let exact = KVJSONValidityDecision.limits(for: String(repeating: "a", count: limit))
  let above = KVJSONValidityDecision.limits(for: String(repeating: "a", count: limit + 1))

  #expect(below.valueFitsDisplayLimit)
  #expect(exact.valueFitsDisplayLimit)
  #expect(!above.valueFitsDisplayLimit)
  #expect(below.valueFitsWriteLimit)
  #expect(exact.valueFitsWriteLimit)
  #expect(above.valueFitsWriteLimit)
}

@Test func kvJSONValidityDecisionTracksWriteByteBoundaries() {
  let limit = KVValueLimits.writeByteLimit

  let below = KVJSONValidityDecision.limits(for: String(repeating: "a", count: limit - 1))
  let exact = KVJSONValidityDecision.limits(for: String(repeating: "a", count: limit))
  let above = KVJSONValidityDecision.limits(for: String(repeating: "a", count: limit + 1))

  #expect(below.valueFitsWriteLimit)
  #expect(exact.valueFitsWriteLimit)
  #expect(!above.valueFitsWriteLimit)
  #expect(!below.valueFitsDisplayLimit)
  #expect(!exact.valueFitsDisplayLimit)
  #expect(!above.valueFitsDisplayLimit)
}

@Test func kvJSONValidityDecisionFormatsOnlyValidDisplaySizedJSON() {
  let valid = KVJSONValidityDecision.validated(#"{"enabled":true}"#)
  let invalid = KVJSONValidityDecision.validated(#"{"enabled":}"#)
  let oversizedValidJSON =
    "["
    + String(repeating: " ", count: KVJSONFormatting.displayByteLimit)
    + "0]"
  let oversized = KVJSONValidityDecision.validated(oversizedValidJSON)

  #expect(valid.canFormat)
  #expect(!invalid.canFormat)
  #expect(valid.valueFitsDisplayLimit)
  #expect(invalid.valueFitsDisplayLimit)
  #expect(!oversized.valueFitsDisplayLimit)
  #expect(!oversized.canFormat)
}

@Test func demoKVKeysDecodeAsValidJSON() async throws {
  let client = CloudflareClient(
    clientID: "demo", tokenStore: DemoTokenStore(), session: DemoBackend.session)
  let page = try await client.listKVKeys(accountID: DemoBackend.accountID, namespaceID: "kv-prod")
  #expect(page.items.count == 99)
  #expect(page.items.contains(where: { $0.name == "bulk:item-001" }))
  #expect(page.items.contains(where: { $0.name == "bulk:item-096" }))

  let cache = try await client.listKVKeys(accountID: DemoBackend.accountID, namespaceID: "kv-cache")
  #expect(cache.items.count == 50)
  #expect(cache.items.contains(where: { $0.name == "cache:page-001" }))

  // Value body must stay valid JSON too (raw-string `"#` can steal a closing quote).
  let session = try await client.getKVValue(
    accountID: DemoBackend.accountID, namespaceID: "kv-prod", key: "session:8f3a2c")
  #expect(throws: Never.self) {
    try JSONSerialization.jsonObject(with: session)
  }
}
