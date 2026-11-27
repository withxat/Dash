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
  let https = try await client.createDNSRecord(
    zoneID: "zone-example",
    input: DNSRecordInput(
      type: "HTTPS", name: "app.example.com", proxied: false, ttl: 300,
      data: DNSRecordData(priority: 1, target: ".", value: #"alpn="h3,h2""#),
      comment: "HTTP/3 endpoint"))
  #expect(https.content == #"1 . alpn="h3,h2""#)
  #expect(https.comment == "HTTP/3 endpoint")
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
  try await client.purgeCache(zoneID: zone.id)
  try await client.purgeCache(zoneID: zone.id, files: ["https://review.example/app.css"])
  await #expect(throws: (any Error).self) {
    try await client.purgeCache(zoneID: zone.id, files: [])
  }
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

  // Namespace CRUD, TTL, metadata, and bulk key deletion work in-session.
  let createdNS = try await client.createKVNamespace(
    accountID: "demo-account", title: "ephemeral-ns")
  try await client.renameKVNamespace(
    accountID: "demo-account", namespaceID: createdNS.id, title: "renamed-ns")
  #expect(
    try await client.getKVNamespace(accountID: "demo-account", namespaceID: createdNS.id).title
      == "renamed-ns")
  try await client.putKVValue(
    accountID: "demo-account", namespaceID: createdNS.id, key: "ttl-key",
    data: Data("v".utf8), expirationTTL: 3600)
  try await client.putKVValue(
    accountID: "demo-account", namespaceID: createdNS.id, key: "other-key",
    data: Data("v2".utf8))
  let listed = try await client.listKVKeys(accountID: "demo-account", namespaceID: createdNS.id)
  #expect(listed.items.first(where: { $0.name == "ttl-key" })?.expiration != nil)
  try await client.deleteKVValues(
    accountID: "demo-account", namespaceID: createdNS.id, keys: ["ttl-key", "other-key"])
  #expect(
    try await client.listKVKeys(accountID: "demo-account", namespaceID: createdNS.id).items.isEmpty)
  try await client.deleteKVNamespace(accountID: "demo-account", namespaceID: createdNS.id)
  #expect(
    try await client.listKVNamespaces(accountID: "demo-account").items.allSatisfy {
      $0.id != createdNS.id
    })

  // Metadata lookup returns seeded metadata for kv-prod keys.
  let meta = try await client.getKVMetadata(
    accountID: "demo-account", namespaceID: "kv-prod", key: "config:homepage")
  #expect(meta != nil)
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

  // Environment variable updates and deletions persist per environment; secrets never echo values.
  let withVar = try await client.updatePagesEnvironmentVariable(
    accountID: "demo-account", projectName: "marketing-site", environment: .production,
    name: "FEATURE_FLAG", value: "enabled", isSecret: false)
  #expect(
    withVar.deploymentConfigs?.production?.envVars["FEATURE_FLAG"]?.value == "enabled")
  let withSecret = try await client.updatePagesEnvironmentVariable(
    accountID: "demo-account", projectName: "marketing-site", environment: .preview,
    name: "PREVIEW_TOKEN", value: "super-secret", isSecret: true)
  #expect(withSecret.deploymentConfigs?.preview?.envVars["PREVIEW_TOKEN"]?.isSecret == true)
  #expect(withSecret.deploymentConfigs?.preview?.envVars["PREVIEW_TOKEN"]?.value == nil)
  let withoutVar = try await client.deletePagesEnvironmentVariable(
    accountID: "demo-account", projectName: "marketing-site", environment: .production,
    name: "FEATURE_FLAG")
  #expect(withoutVar.deploymentConfigs?.production?.envVars["FEATURE_FLAG"] == nil)

  // Deleting a non-canonical deployment removes it from the list.
  try await client.deletePagesDeployment(
    accountID: "demo-account", projectName: "marketing-site", deploymentID: "pd-2", force: true)
  #expect(
    try await client.listPagesDeployments(accountID: "demo-account", projectName: "marketing-site")
      .items.allSatisfy { $0.id != "pd-2" })
}

@Test func demoRegistrarAndAccountChangesReadBack() async throws {
  let client = demoClient()
  try await client.updateRegistrarAutoRenew(
    accountID: "demo-account", domain: "example.com", autoRenew: false)
  let registration = try await client.getRegistrarRegistration(
    accountID: "demo-account", domain: "example.com")
  #expect(registration.autoRenew == false)
  // The lock is read-only now; the write must not have touched it.
  #expect(registration.locked == true)
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
  // Resending verification for the seeded pending address verifies it in place without duplicating.
  let resent = try await client.createEmailDestinationAddress(
    accountID: "demo-account", email: "pending@example.net")
  #expect(resent.id == "email-address-pending")
  #expect(resent.isVerified)
  let afterResend = try await client.listEmailDestinationAddresses(accountID: "demo-account")
  #expect(afterResend.filter { $0.email == "pending@example.net" }.count == 1)

  let address = try await client.createEmailDestinationAddress(
    accountID: "demo-account", email: "review@example.net")
  #expect(address.verified != nil)
  #expect(
    try await client.listEmailDestinationAddresses(accountID: "demo-account").contains {
      $0.id == address.id
    })
  try await client.deleteEmailDestinationAddress(
    accountID: "demo-account", addressID: address.id)
  #expect(
    try await client.listEmailDestinationAddresses(accountID: "demo-account").allSatisfy {
      $0.id != address.id
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

@Test func demoIPAccessRulesCertificatePacksAndWorkerRoutesWorkLocally() async throws {
  let client = demoClient()

  // IP Access Rules list / create / delete.
  let initialRules = try await client.listIPAccessRules(zoneID: "zone-example").items
  #expect(initialRules.count == 2)
  let createdRule = try await client.createIPAccessRule(
    zoneID: "zone-example",
    input: IPAccessRuleInput(
      mode: .block, target: .ip, value: "192.0.2.99", notes: "Demo block"))
  #expect(createdRule.configuration.value == "192.0.2.99")
  #expect(createdRule.scope?.type == "zone")
  #expect(
    try await client.listIPAccessRules(zoneID: "zone-example").items.contains {
      $0.id == createdRule.id
    })
  try await client.deleteIPAccessRule(zoneID: "zone-example", ruleID: createdRule.id)
  #expect(
    try await client.listIPAccessRules(zoneID: "zone-example").items.allSatisfy {
      $0.id != createdRule.id
    })

  // Edge Certificate Packs list returns active + pending packs.
  let packs = try await client.listCertificatePacks(zoneID: "zone-example")
  #expect(packs.count == 2)
  #expect(packs.contains { $0.status == "active" && $0.earliestExpiration != nil })
  #expect(packs.contains { $0.status == "pending_validation" })

  // Worker Routes create / update / delete.
  let createdRoute = try await client.createWorkerRoute(
    zoneID: "zone-example", pattern: "example.com/hook/*", script: "api-worker")
  #expect(createdRoute.pattern == "example.com/hook/*")
  let updatedRoute = try await client.updateWorkerRoute(
    zoneID: "zone-example", routeID: createdRoute.id, pattern: "example.com/webhooks/*",
    script: "api-worker")
  #expect(updatedRoute.pattern == "example.com/webhooks/*")
  #expect(
    try await client.listWorkerRoutes(zoneID: "zone-example").contains {
      $0.id == createdRoute.id && $0.pattern == "example.com/webhooks/*"
    })
  try await client.deleteWorkerRoute(zoneID: "zone-example", routeID: createdRoute.id)
  #expect(
    try await client.listWorkerRoutes(zoneID: "zone-example").allSatisfy {
      $0.id != createdRoute.id
    })

  // Workers Observability logs query supports All and Errors filters.
  let allLogs = try await client.queryWorkerObservabilityLogs(
    accountID: "demo-account", scriptName: "api-worker", windowMinutes: 60, errorsOnly: false)
  #expect(allLogs.count >= 3)
  #expect(allLogs.contains { $0.isError })
  #expect(allLogs.contains { !$0.isError })
  let errorLogs = try await client.queryWorkerObservabilityLogs(
    accountID: "demo-account", scriptName: "api-worker", windowMinutes: 60, errorsOnly: true)
  #expect(!errorLogs.isEmpty)
  #expect(errorLogs.allSatisfy { $0.isError })
}

@Test func demoD1ListsDatabasesSchemaAndAnswersReadOnlyQueries() async throws {
  let client = demoClient()
  let account = DemoBackend.accountID
  let databases = try await client.listD1Databases(accountID: account)
  #expect(databases.map(\.name) == ["app-production", "analytics-events", "app-staging"])
  let production = try #require(databases.first)

  let detail = try await client.getD1Database(accountID: account, databaseID: production.id)
  #expect(detail.fileSize == 4_812_800)
  #expect(detail.runningInRegion == "WNAM")
  #expect(detail.readReplicationMode == "auto")

  // The schema read Dash issues itself, WHERE and ORDER BY included.
  let tables = try await client.listD1Tables(accountID: account, databaseID: production.id)
  #expect(tables.map(\.name) == ["active_users", "orders", "users"])
  #expect(tables.map(\.isView) == [true, false, false])
  #expect(tables[2].sql?.hasPrefix("CREATE TABLE users") == true)
  let staging = try #require(databases.last)
  #expect(try await client.listD1Tables(accountID: account, databaseID: staging.id).isEmpty)

  // The preview a table row opens: quoted identifier, LIMIT honoured.
  let preview = try await client.queryD1Database(
    accountID: account, databaseID: production.id,
    sql: D1SQL.previewRows(table: "users", limit: 2))
  #expect(preview.count == 1)
  #expect(preview[0].columns == ["id", "email", "plan", "referred_by", "created_at"])
  #expect(preview[0].rows.count == 2)
  #expect(preview[0].rows[0][1] == .string("ada@example.com"))
  #expect(preview[0].rows[0][3] == .null)
  #expect(preview[0].meta?.rowsRead == 2)

  // A projection keeps the statement's column order, not the table's.
  let projected = try await client.queryD1Database(
    accountID: account, databaseID: production.id, sql: "select plan, id from users;")
  #expect(projected[0].columns == ["plan", "id"])
  #expect(projected[0].rows.count == 5)
  #expect(projected[0].rows[1] == [.string("free"), .number(2)])

  let count = try await client.queryD1Database(
    accountID: account, databaseID: production.id, sql: "SELECT COUNT(*) FROM orders")
  #expect(count[0].rows == [[.number(4)]])

  // Writes are refused, and so is anything the demo would have to guess at:
  // a WHERE it ignored would return rows the statement never asked for.
  for sql in [
    "DELETE FROM users", "  drop table users", "UPDATE users SET plan = 'pro'",
    "INSERT INTO users (id) VALUES (9)", "SELECT * FROM users WHERE plan = 'pro'",
    "SELECT * FROM missing", "SELECT nope FROM users", "PRAGMA table_list",
  ] {
    await #expect(throws: CloudflareAPIError.self, "\(sql)") {
      try await client.queryD1Database(accountID: account, databaseID: production.id, sql: sql)
    }
  }
  // Nothing was written: the table still answers in full.
  let after = try await client.queryD1Database(
    accountID: account, databaseID: production.id, sql: "SELECT * FROM users")
  #expect(after[0].rows.count == 5)

  await #expect(throws: CloudflareAPIError.self) {
    try await client.getD1Database(accountID: account, databaseID: "not-a-database")
  }
}

@Test func demoZoneRulesToggleOneRuleAndKeepItsDefinition() async throws {
  let client = demoClient()
  let redirects = try #require(
    try await client.getZoneEntrypointRuleset(zoneID: "zone-example", phase: .dynamicRedirect))
  #expect(redirects.rules.map(\.name) == ["Maintenance page", "Apex to www", "Old blog paths"])
  #expect(redirects.rules.map(\.isEnabled) == [false, true, true])
  let maintenance = redirects.rules[0]

  let updated = try await client.setZoneRulesetRuleEnabled(
    zoneID: "zone-example", rulesetID: redirects.id, rule: maintenance, enabled: true)
  // Only that rule moved, and it kept everything a replacement could have lost.
  #expect(updated.rules.map(\.isEnabled) == [true, true, true])
  #expect(updated.rules[0].expression == maintenance.expression)
  #expect(updated.rules[0].redirectTarget?.value == "https://status.example.com/maintenance")
  #expect(updated.rules[0].redirectStatusCode == 302)
  #expect(updated.rules[0].name == "Maintenance page")
  #expect(updated.rules[1] == redirects.rules[1])
  #expect(updated.version != redirects.version)

  // It reads back, in this session only.
  let reread = try #require(
    try await client.getZoneEntrypointRuleset(zoneID: "zone-example", phase: .dynamicRedirect))
  #expect(reread.rules[0].isEnabled)
  let clean = try #require(
    try await demoClient().getZoneEntrypointRuleset(
      zoneID: "zone-example", phase: .dynamicRedirect))
  #expect(!clean.rules[0].isEnabled)

  // The other phase is its own ruleset and did not move.
  let custom = try #require(
    try await client.getZoneEntrypointRuleset(zoneID: "zone-example", phase: .customFirewall))
  #expect(custom.rules.map(\.isEnabled) == [true, true, false])
  #expect(custom.rules[2].name == nil)
  let off = try await client.setZoneRulesetRuleEnabled(
    zoneID: "zone-example", rulesetID: custom.id, rule: custom.rules[1], enabled: false)
  #expect(off.rules.map(\.isEnabled) == [true, false, false])
  // A field Dash never models rode along.
  #expect(off.rules[1].fields["logging"] == .object(["enabled": .bool(true)]))

  // A zone with no rules answers 404, which is "none", not an error.
  #expect(
    try await client.getZoneEntrypointRuleset(zoneID: "zone-api", phase: .dynamicRedirect) == nil)
  // A rule that is not in the ruleset cannot be toggled into existence.
  await #expect(throws: CloudflareAPIError.self) {
    try await client.setZoneRulesetRuleEnabled(
      zoneID: "zone-example", rulesetID: custom.id, rule: maintenance, enabled: false)
  }
}
