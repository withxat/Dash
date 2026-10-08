import CloudflareAPI
import Foundation
import Testing

#if canImport(Dash)
  @testable import Dash
#else
  @testable import DemoHarness
#endif

private func demoClient() -> CloudflareClient {
  CloudflareClient(clientID: "demo", tokenStore: DemoTokenStore(), session: DemoBackend.session)
}

@Test func demoDNSMutationsSurviveReadsAndAreIsolatedBySession() async throws {
  let client = demoClient()
  let record = try await client.createDNSRecord(
    zoneID: "zone-example",
    input: DNSRecordInput(type: "TXT", name: "review.example.com", content: "demo", ttl: 300))
  let updated = try await client.updateDNSRecord(
    zoneID: "zone-example", recordID: record.id,
    input: DNSRecordInput(type: "TXT", name: "review.example.com", content: "edited", ttl: 600))
  #expect(updated.content == "edited")
  let records = try await client.listDNSRecords(zoneID: "zone-example")
  #expect(records.items.first(where: { $0.id == record.id })?.content == "edited")
  let clean = try await demoClient().listDNSRecords(zoneID: "zone-example")
  #expect(!clean.items.contains(where: { $0.id == record.id }))
  try await client.deleteDNSRecord(zoneID: "zone-example", recordID: record.id)
  let deleted = try await client.listDNSRecords(zoneID: "zone-example")
  #expect(!deleted.items.contains(where: { $0.id == record.id }))
  await #expect(throws: (any Error).self) {
    try await client.deleteDNSRecord(zoneID: "zone-example", recordID: record.id)
  }
}

@Test func demoZoneCreationActivationSettingsAndDeletion() async throws {
  let client = demoClient()
  let zone = try await client.createZone(name: "review.example", accountID: "demo-account-studio")
  #expect(zone.status == "active")
  try await client.triggerZoneActivationCheck(zoneID: "zone-api")
  #expect(try await client.getZone("zone-api").status == "active")
  #expect(try await client.getZone(zone.id).status == "active")
  _ = try await client.updateZoneSetting(
    zoneID: zone.id, settingID: "ssl", value: .string("strict"))
  #expect(
    try await client.listZoneSettings(zoneID: zone.id).first(where: { $0.id == "ssl" })?.value
      == .string("strict"))
  #expect(
    try await client.listZones(accountID: "demo-account", name: "review.example").items.isEmpty)
  #expect(
    try await client.listZones(accountID: "demo-account-studio", name: "review.example").items.count
      == 1)
  try await client.deleteZone(zoneID: zone.id)
  await #expect(throws: (any Error).self) { try await client.getZone(zone.id) }
}

@Test func demoKVPreservesBinaryValuesPrefixesAndDeletion() async throws {
  let client = demoClient()
  let key = "review/中文 \"key\""
  let bytes = Data([0, 255, 10, 17])
  try await client.putKVValue(
    accountID: "demo-account", namespaceID: "kv-prod", key: key, data: bytes)
  #expect(
    try await client.getKVValue(accountID: "demo-account", namespaceID: "kv-prod", key: key)
      == bytes)
  #expect(
    try await client.listKVKeys(
      accountID: "demo-account", namespaceID: "kv-prod", prefix: "review/"
    ).items.map(\.name) == [key])
  await #expect(throws: (any Error).self) {
    try await client.getKVValue(accountID: "demo-account-studio", namespaceID: "kv-prod", key: key)
  }
  try await client.deleteKVValue(accountID: "demo-account", namespaceID: "kv-prod", key: key)
  await #expect(throws: (any Error).self) {
    try await client.getKVValue(accountID: "demo-account", namespaceID: "kv-prod", key: key)
  }
}

@Test func demoR2FileUploadDownloadAndBucketLifecycle() async throws {
  let client = demoClient()
  let bucket = try await client.createR2Bucket(accountID: "demo-account", name: "review-files")
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let download = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {
    try? FileManager.default.removeItem(at: file)
    try? FileManager.default.removeItem(at: download)
  }
  let bytes = Data([0, 1, 255, 42])
  try bytes.write(to: file)
  _ = try await client.putR2Object(
    accountID: "demo-account", bucket: bucket.name, key: "folder/data.bin", fileURL: file,
    contentType: "application/octet-stream")
  #expect(
    try await client.getR2Object(
      accountID: "demo-account", bucket: bucket.name, key: "folder/data.bin") == bytes)
  _ = try await client.downloadR2Object(
    accountID: "demo-account", bucket: bucket.name, key: "folder/data.bin", to: download)
  #expect(try Data(contentsOf: download) == bytes)
  #expect(
    try await client.listR2Objects(accountID: "demo-account", bucket: bucket.name, delimiter: "/")
      .commonPrefixes == ["folder/"])
  #expect(
    try await client.listR2Objects(
      accountID: "demo-account", bucket: bucket.name, prefix: "folder/"
    ).objects.first?.size == bytes.count)
  await #expect(throws: (any Error).self) {
    try await client.deleteR2Bucket(accountID: "demo-account", name: bucket.name)
  }
  try await client.deleteR2Object(
    accountID: "demo-account", bucket: bucket.name, key: "folder/data.bin")
  await #expect(throws: (any Error).self) {
    try await client.getR2Object(
      accountID: "demo-account", bucket: bucket.name, key: "folder/data.bin")
  }
  try await client.deleteR2Bucket(accountID: "demo-account", name: bucket.name)
  #expect(
    try await client.listR2Buckets(accountID: "demo-account").allSatisfy { $0.name != bucket.name })
}

@Test func demoR2PaginationAndDomains() async throws {
  let client = demoClient()
  let first = try await client.listR2Objects(
    accountID: "demo-account", bucket: "assets", perPage: 2)
  #expect(first.objects.count == 2)
  #expect(first.isTruncated)
  let second = try await client.listR2Objects(
    accountID: "demo-account", bucket: "assets", cursor: first.cursor, perPage: 2)
  #expect(Set(first.objects.map(\.key)).isDisjoint(with: second.objects.map(\.key)))
  _ = try await client.setR2ManagedDomain(
    accountID: "demo-account", bucket: "assets", enabled: false)
  #expect(
    try await client.getR2ManagedDomain(accountID: "demo-account", bucket: "assets").enabled
      == false)
  _ = try await client.addR2CustomDomain(
    accountID: "demo-account", bucket: "assets", domain: "files.example.com", zoneID: "zone-example"
  )
  #expect(
    try await client.listR2CustomDomains(accountID: "demo-account", bucket: "assets").count == 1)
  try await client.deleteR2CustomDomain(
    accountID: "demo-account", bucket: "assets", domain: "files.example.com")
  #expect(try await client.listR2CustomDomains(accountID: "demo-account", bucket: "assets").isEmpty)
}

@Test func demoWorkerSourceUploadRollbackAndDomains() async throws {
  let client = demoClient()
  let name = try #require(try await client.listWorkers(accountID: "demo-account").first?.id)
  let source = try await client.getWorkerSource(accountID: "demo-account", name: name)
  _ = try await client.uploadWorkerScript(
    accountID: "demo-account", name: name, source: source,
    content: "export default { fetch() { return new Response('review'); } }")
  #expect(
    try await client.getWorkerSource(accountID: "demo-account", name: name).content.contains(
      "review"))
  #expect(
    try await client.listWorkerDeployments(accountID: "demo-account", scriptName: name).count == 3)
  _ = try await client.createWorkerDeployment(
    accountID: "demo-account", scriptName: name, versionID: "v-1994")
  #expect(
    try await client.getWorkerSource(accountID: "demo-account", name: name).content
      == source.content)
  _ = try await client.setWorkerSubdomain(accountID: "demo-account", name: name, enabled: false)
  #expect(
    try await client.getWorkerSubdomain(accountID: "demo-account", name: name).enabled == false)
  let domain = try await client.attachWorkerDomain(
    accountID: "demo-account", hostname: "review.example.com", service: name,
    zoneID: "zone-example", zoneName: "example.com")
  #expect(
    try await client.listWorkerDomains(accountID: "demo-account", service: name).contains {
      $0.id == domain.id
    })
  try await client.detachWorkerDomain(accountID: "demo-account", domainID: domain.id)
  #expect(
    try await client.listWorkerDomains(accountID: "demo-account", service: name).allSatisfy {
      $0.id != domain.id
    })
}

@Test func demoPagesRetryRollbackAndCustomDomains() async throws {
  let client = demoClient()
  #expect(try await client.listPagesProjects(accountID: "demo-account").count == 19)
  let retry = try await client.retryPagesDeployment(
    accountID: "demo-account", projectName: "marketing-site", deploymentID: "pd-2")
  #expect(retry.latestStage?.status == "success")
  #expect(
    try await client.getPagesProject(accountID: "demo-account", projectName: "marketing-site")
      .latestDeployment?.id == retry.id)
  _ = try await client.rollbackPagesDeployment(
    accountID: "demo-account", projectName: "marketing-site", deploymentID: "pd-1")
  #expect(
    try await client.listPagesDeployments(accountID: "demo-account", projectName: "marketing-site")
      .items.count == 5)
  _ = try await client.addPagesDomain(
    accountID: "demo-account", projectName: "marketing-site", name: "review.example.com")
  #expect(
    try await client.listPagesDomains(accountID: "demo-account", projectName: "marketing-site")
      .contains { $0.name == "review.example.com" })
  try await client.deletePagesDomain(
    accountID: "demo-account", projectName: "marketing-site", domainName: "review.example.com")
  #expect(
    try await client.listPagesDomains(accountID: "demo-account", projectName: "marketing-site")
      .allSatisfy { $0.name != "review.example.com" })
}

@Test func demoRegistrarAndAccountChangesReadBack() async throws {
  let client = demoClient()
  try await client.updateRegistrarDomain(
    accountID: "demo-account", domain: "example.com",
    settings: .init(autoRenew: false, locked: false))
  let registration = try await client.getRegistrarRegistration(
    accountID: "demo-account", domain: "example.com")
  #expect(registration.autoRenew == false)
  #expect(registration.locked == false)
  _ = try await client.updateAccount(
    accountID: "demo-account", input: .init(name: "Review workspace"))
  #expect(
    try await client.listAccounts().first(where: { $0.id == "demo-account" })?.name
      == "Review workspace")
}

@Test func demoConcurrentWritesAreNotLost() async throws {
  let client = demoClient()
  try await withThrowingTaskGroup(of: Void.self) { group in
    for index in 0..<20 {
      group.addTask {
        try await client.putKVValue(
          accountID: "demo-account", namespaceID: "kv-prod", key: "concurrent-\(index)",
          data: Data([UInt8(index)]))
      }
    }
    try await group.waitForAll()
  }
  #expect(
    try await client.listKVKeys(
      accountID: "demo-account", namespaceID: "kv-prod", prefix: "concurrent-"
    ).items.count == 20)
}

@Test func demoEmailRulesSettingsAndVerificationAreLocal() async throws {
  let client = demoClient()
  let address = try await client.createEmailDestinationAddress(
    accountID: "demo-account", email: "review@example.net")
  #expect(address.verified != nil)
  #expect(
    try await client.listEmailDestinationAddresses(accountID: "demo-account").contains {
      $0.id == address.id
    })
  var input = EmailRoutingRuleInput(
    matchers: [.init(type: "literal", field: "to", value: "review@example.com")],
    actions: [.init(type: "forward", value: [address.email])], enabled: true, name: "Review")
  let rule = try await client.createEmailRoutingRule(zoneID: "zone-example", input: input)
  input.enabled = false
  _ = try await client.updateEmailRoutingRule(zoneID: "zone-example", ruleID: rule.id, input: input)
  #expect(
    try await client.listEmailRoutingRules(zoneID: "zone-example").items.first(where: {
      $0.id == rule.id
    })?.enabled == false)
  _ = try await client.updateEmailRoutingCatchAll(
    zoneID: "zone-example",
    input: .init(actions: [.init(type: "forward", value: [address.email])], enabled: true))
  #expect(
    try await client.getEmailRoutingCatchAll(zoneID: "zone-example").actions.first?.value == [
      address.email
    ])
  _ = try await client.updateEmailRoutingSubaddressing(zoneID: "zone-example", enabled: false)
  #expect(
    try await client.getEmailRoutingSettings(zoneID: "zone-example").supportSubaddress == false)
  try await client.deleteEmailRoutingRule(zoneID: "zone-example", ruleID: rule.id)
  #expect(
    try await client.listEmailRoutingRules(zoneID: "zone-example").items.allSatisfy {
      $0.id != rule.id
    })
  _ = try await client.enableEmailRouting(zoneID: "zone-docs")
  #expect(try await client.getEmailRoutingSettings(zoneID: "zone-docs").status == "ready")
  #expect(
    try await client.listDNSRecords(zoneID: "zone-docs").items.filter { $0.type == "MX" }.count == 2
  )
  try await client.disableEmailRouting(zoneID: "zone-docs")
  #expect(try await client.getEmailRoutingSettings(zoneID: "zone-docs").enabled == false)
  #expect(try await client.listDNSRecords(zoneID: "zone-docs").items.allSatisfy { $0.type != "MX" })
}

@Test func demoRejectsUnsupportedWritesAndNeverUsesRealNetwork() async throws {
  let session = DemoBackend.session
  defer { session.invalidateAndCancel() }
  var request = URLRequest(
    url: URL(string: "https://invalid.example/client/v4/accounts/demo-account/unsupported")!)
  request.httpMethod = "POST"
  let (data, response) = try await session.data(for: request)
  #expect((response as? HTTPURLResponse)?.statusCode == 400)
  #expect(String(decoding: data, as: UTF8.self).contains("not simulated"))
}

@Test func demoR2FolderMarkersKeepTheirTrailingSlash() async throws {
  let client = demoClient()
  _ = try await client.createR2Bucket(accountID: "demo-account", name: "review-folders")
  try await client.createR2Folder(
    accountID: "demo-account", bucket: "review-folders", key: "photos/2026/")
  let objects = try await client.listR2Objects(accountID: "demo-account", bucket: "review-folders")
  #expect(Set(objects.objects.map(\.key)) == ["photos/", "photos/2026/"])
  #expect(
    try await client.listR2Objects(
      accountID: "demo-account", bucket: "review-folders", delimiter: "/"
    ).commonPrefixes == ["photos/"])
}
