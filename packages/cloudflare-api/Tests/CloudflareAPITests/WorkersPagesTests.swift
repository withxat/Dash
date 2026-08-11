import Foundation
import Testing

@testable import CloudflareAPI

extension NetworkTests {
  @Test func listPagesProjectsCollectsEveryPage() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/account/pages/projects")
      let query = Dictionary(
        uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
          .queryItems ?? []).map {
            ($0.name, $0.value ?? "")
          })
      let page = query["page"] ?? "1"
      recorder.record(page)
      #expect(query["per_page"] == "10")
      if page == "1" {
        return (
          200,
          Data(
            #"""
            {"success":true,"result":[
              {"id":"project-1","name":"one"},
              {"id":"project-2","name":"two"}
            ],"result_info":{"page":1,"per_page":2,"total_pages":2}}
            """#.utf8)
        )
      }
      #expect(page == "2")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[
            {"id":"project-3","name":"three"}
          ],"result_info":{"page":2,"per_page":2,"total_pages":2}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let projects = try await client.listPagesProjects(accountID: "account")

    #expect(projects.map(\.id) == ["project-1", "project-2", "project-3"])
    #expect(recorder.paths == ["1", "2"])
  }

  @Test func multipartFormEncodesGoldenBytes() {
    var form = MultipartForm(boundary: "b0")
    form.addField(name: "requireSignedURLs", value: "true")
    form.addFile(
      name: "file", filename: "photo.jpg", contentType: "image/jpeg",
      data: Data("JPEGDATA".utf8))
    let expected =
      "--b0\r\n"
      + "Content-Disposition: form-data; name=\"requireSignedURLs\"\r\n"
      + "\r\ntrue\r\n"
      + "--b0\r\n"
      + "Content-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\n"
      + "Content-Type: image/jpeg\r\n"
      + "\r\nJPEGDATA\r\n"
      + "--b0--\r\n"
    #expect(form.contentType == "multipart/form-data; boundary=b0")
    #expect(form.encode() == Data(expected.utf8))
  }

  @Test func multipartDocumentParsesModuleDownload() {
    let body =
      "--sep\r\n"
      + "Content-Disposition: form-data; name=\"worker.js\"; filename=\"worker.js\"\r\n"
      + "Content-Type: application/javascript+module\r\n"
      + "\r\nexport default { fetch() {} }\r\n"
      + "--sep\r\n"
      + "Content-Disposition: form-data; name=\"lib.js\"; filename=\"lib.js\"\r\n"
      + "Content-Type: application/javascript+module\r\n"
      + "\r\nexport const x = 1\r\n"
      + "--sep--\r\n"
    let parts = MultipartDocument.parse(
      data: Data(body.utf8), contentType: "multipart/form-data; boundary=sep")
    #expect(parts.count == 2)
    #expect(parts.first?.filename == "worker.js")
    #expect(parts.first?.contentType == "application/javascript+module")
    #expect(
      String(decoding: parts.first?.body ?? Data(), as: UTF8.self)
        == "export default { fetch() {} }")
  }

  @Test func workerSourceBranchesOnResponseContentType() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/workers/scripts/api/content/v2") == true)
      let body =
        "--sep\r\n"
        + "Content-Disposition: form-data; name=\"index.mjs\"; filename=\"index.mjs\"\r\n"
        + "Content-Type: application/javascript+module\r\n"
        + "\r\nexport default {}\r\n"
        + "--sep--\r\n"
      return (200, Data(body.utf8))
    }
    MockURLProtocol.responseHeaders = [
      "Content-Type": "multipart/form-data; boundary=sep"
    ]
    defer { MockURLProtocol.responseHeaders = nil }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let source = try await client.getWorkerSource(accountID: "account", name: "api")
    #expect(source.mainModule == "index.mjs")
    #expect(source.moduleCount == 1)
    #expect(source.content == "export default {}")
  }

  @Test func classicWorkerSourceDecodesAsPlainScript() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      (200, Data("addEventListener('fetch', () => {})".utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let source = try await client.getWorkerSource(accountID: "account", name: "legacy")
    #expect(source.mainModule == nil)
    #expect(source.moduleCount == 0)
    #expect(source.content.hasPrefix("addEventListener"))
  }

  @Test func uploadWorkerScriptSendsMetadataAndModulePart() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "PUT")
      #expect(request.url?.path.hasSuffix("/workers/scripts/api/content") == true)
      let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
      #expect(contentType.hasPrefix("multipart/form-data; boundary="))
      return (200, Data(#"{"success":true,"result":{"id":"api"}}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let source = WorkerSource(content: "old", mainModule: "index.mjs", moduleCount: 1)
    _ = try await client.uploadWorkerScript(
      accountID: "account", name: "api", source: source, content: "export default {}")
  }

  @Test func workerTagMatchesExactScriptName() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/account/workers/scripts")
      let body = #"""
        {"success":true,"result":[
        {"id":"api-staging","tag":"e8f70fdbc8b1fb0b8ddb1af166186758"},
        {"id":"api","tag":"57eb1c68b8504f0baa4b5cc56cbc7d0f"}
        ]}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let tag = try await client.workerTag(accountID: "account", name: "api")
    #expect(tag == "57eb1c68b8504f0baa4b5cc56cbc7d0f")
  }

  @Test func listWorkerDeploymentsDecodesOperationalFields() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(
        request.url?.path
          == "/accounts/account/workers/scripts/api/deployments")
      let body = #"""
        {"success":true,"result":{"deployments":[{
          "id":"182bd5e5-6e1a-4fe4-a799-aa6d9a6ab26e",
          "created_on":"2026-07-16T03:04:05.678Z",
          "source":"api",
          "strategy":"percentage",
          "versions":[{"version_id":"version-1","percentage":100}],
          "annotations":{"workers/message":"Fix cache key","workers/triggered_by":"upload"},
          "author_email":"dev@example.com"
        }]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let deployments = try await client.listWorkerDeployments(
      accountID: "account", scriptName: "api")

    #expect(deployments.count == 1)
    #expect(deployments[0].source == "api")
    #expect(deployments[0].versions.first?.percentage == 100)
    #expect(deployments[0].versions.first?.versionID == "version-1")
    #expect(deployments[0].annotations?.message == "Fix cache key")
    #expect(deployments[0].annotations?.triggeredBy == "upload")
    #expect(deployments[0].authorEmail == "dev@example.com")
  }

  @Test func listWorkerDeploymentsSkipsMalformedEntries() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(
        request.url?.path == "/accounts/account/workers/scripts/api/deployments")
      let body = #"""
        {"success":true,"result":{"deployments":[
          {"created_on":"2026-07-16T03:04:05.678Z","source":"api"},
          {"id":"dep-2","created_on":"2026-07-16T04:00:00.000Z","source":"api"}
        ]}}
        """#
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let deployments = try await client.listWorkerDeployments(
      accountID: "account", scriptName: "api")

    #expect(deployments.count == 1)
    #expect(deployments[0].id == "dep-2")
    #expect(deployments[0].versions.isEmpty)
  }

  @Test func createWorkerDeploymentPostsWholeTrafficSwitch() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.httpMethod == "POST")
      #expect(
        request.url?.path == "/accounts/account/workers/scripts/api/deployments")
      if let body = requestBodyData(request),
        let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
      {
        #expect(payload["strategy"] as? String == "percentage")
        let versions = payload["versions"] as? [[String: Any]]
        #expect(versions?.count == 1)
        #expect(versions?.first?["version_id"] as? String == "version-old")
        #expect((versions?.first?["percentage"] as? NSNumber)?.doubleValue == 100)
        let annotations = payload["annotations"] as? [String: Any]
        #expect(annotations?["workers/message"] as? String == "Rollback")
      }
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{
            "id":"dep-new",
            "created_on":"2026-07-17T00:00:00Z",
            "source":"api",
            "strategy":"percentage",
            "versions":[{"version_id":"version-old","percentage":100}],
            "annotations":{"workers/message":"Rollback"}
          }}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let deployment = try await client.createWorkerDeployment(
      accountID: "account", scriptName: "api", versionID: "version-old", message: "Rollback")
    #expect(deployment.id == "dep-new")
    #expect(deployment.versions.first?.versionID == "version-old")
  }

  @Test func getWorkersAccountSubdomainComposesScriptHostname() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/workers/subdomain") == true)
      #expect(request.url?.path.contains("/scripts/") != true)
      return (
        200,
        Data(#"{"success":true,"result":{"subdomain":"my-team"},"errors":[],"messages":[]}"#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let account = try await client.getWorkersAccountSubdomain(accountID: "account")

    #expect(account.subdomain == "my-team")
    #expect(account.hostname(forScript: "api-worker") == "api-worker.my-team.workers.dev")
  }

  @Test func listPagesDeploymentsDecodesOperationalFields() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/pages/projects/docs/deployments") == true)
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[{
            "id":"dep-1","short_id":"dep1abcd","url":"https://dep1.docs.pages.dev",
            "environment":"production","created_on":"2026-07-17T00:00:00Z",
            "is_skipped":false,
            "latest_stage":{"name":"deploy","status":"success"},
            "stages":[{"name":"build","status":"success"}],
            "deployment_trigger":{"type":"github:push",
              "metadata":{"branch":"main","commit_message":"Ship it"}}
          }],"result_info":{"page":1,"per_page":25,"count":1,"total_count":1}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let page = try await client.listPagesDeployments(accountID: "account", projectName: "docs")
    #expect(page.items.count == 1)
    #expect(page.items[0].branch == "main")
    #expect(page.items[0].commitMessage == "Ship it")
    #expect(page.items[0].latestStage?.status == "success")
  }

  @Test func pagesDeploymentLogsDecodeLines() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      (
        200,
        Data(
          #"""
          {"success":true,"result":{"total":2,"includes_container_logs":false,
            "data":[{"line":"Cloning…","ts":"2026-07-17T00:00:00Z"},{"line":"Done","ts":"2026-07-17T00:00:01Z"}]}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let logs = try await client.getPagesDeploymentLogs(
      accountID: "account", projectName: "docs", deploymentID: "dep-1")
    #expect(logs.total == 2)
    #expect(logs.data.map(\.line) == ["Cloning…", "Done"])
  }

  @Test func listAndAttachWorkerDomains() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      recorder.record("\(request.httpMethod ?? "?") \(request.url?.path ?? "")")
      if request.httpMethod == "GET" {
        let service = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
          .queryItems?.first { $0.name == "service" }?.value
        #expect(service == "api")
        return (
          200,
          Data(
            #"""
            {"success":true,"result":[{
              "id":"dom-1","hostname":"api.example.com","service":"api",
              "zone_id":"zone-1","zone_name":"example.com","cert_id":"cert-1",
              "environment":"production"
            }]}
            """#.utf8)
        )
      }
      if let body = requestBodyData(request),
        let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
      {
        #expect(payload["hostname"] as? String == "app.example.com")
        #expect(payload["service"] as? String == "api")
        #expect(payload["zone_id"] as? String == "zone-1")
      }
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{
            "id":"dom-2","hostname":"app.example.com","service":"api",
            "zone_id":"zone-1","zone_name":"example.com"
          }}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let listed = try await client.listWorkerDomains(accountID: "account", service: "api")
    #expect(listed.map(\.hostname) == ["api.example.com"])
    let attached = try await client.attachWorkerDomain(
      accountID: "account", hostname: "app.example.com", service: "api",
      zoneID: "zone-1", zoneName: "example.com")
    #expect(attached.id == "dom-2")
    #expect(
      recorder.paths == [
        "GET /accounts/account/workers/domains",
        "PUT /accounts/account/workers/domains",
      ])
  }

  @Test func workerRoutesListDecodesDisabledRoutes() async throws {
    let recorder = RequestRecorder()
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      recorder.record("\(request.httpMethod ?? "?") \(request.url?.path ?? "")")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[
            {"id":"route-1","pattern":"example.com/*","script":"api"},
            {"id":"route-2","pattern":"disabled.example.com/*"}
          ]}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let routes = try await client.listWorkerRoutes(zoneID: "zone-1")
    #expect(routes.map(\.pattern) == ["example.com/*", "disabled.example.com/*"])
    #expect(routes.map(\.script) == ["api", nil])
    #expect(recorder.paths == ["GET /zones/zone-1/workers/routes"])
  }
}
