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

  @Test func getPagesDeploymentDecodesSourceBuildAndTimings() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path.hasSuffix("/pages/projects/docs/deployments/dep-1") == true)
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{
            "id":"dep-1","short_id":"dep1abcd","url":"https://dep1.docs.pages.dev",
            "environment":"preview","created_on":"2021-03-09T00:55:00.000000Z",
            "modified_on":"2021-03-09T09:00:00.000000Z",
            "aliases":["https://feature.docs.pages.dev"],
            "build_config":{"build_command":"npm run build","destination_dir":"dist",
              "root_dir":"","build_caching":true,"web_analytics_tag":null},
            "source":{"type":"github","config":{"owner":"acme","repo_name":"docs",
              "production_branch":"main","pr_comments_enabled":true}},
            "deployment_trigger":{"type":"github:push","metadata":{"branch":"feature",
              "commit_hash":"ad9ccd918a81025731e10e40267e11273a263421",
              "commit_message":"Update index.html","commit_dirty":false}},
            "latest_stage":{"name":"deploy","status":"success",
              "started_on":"2021-03-09T00:56:10.5Z","ended_on":"2021-03-09T00:56:15.923456Z"},
            "stages":[
              {"name":"queued","status":"success",
               "started_on":"2021-03-09T00:55:03.923456Z","ended_on":"2021-03-09T00:55:04.923456Z"},
              {"name":"build","status":"success",
               "started_on":"2021-03-09T00:55:10Z","ended_on":"2021-03-09T00:56:10Z"},
              {"name":"deploy","status":"success",
               "started_on":"2021-03-09T00:56:10.5Z","ended_on":"2021-03-09T00:56:15.923456Z"}
            ]
          }}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)
    let deployment = try await client.getPagesDeployment(
      accountID: "account", projectName: "docs", deploymentID: "dep-1")

    #expect(deployment.shortCommit == "ad9ccd9")
    #expect(deployment.deploymentTrigger?.kind == .gitPush)
    #expect(deployment.deploymentTrigger?.metadata?.commitDirty == false)
    #expect(deployment.repository == "acme/docs")
    #expect(
      deployment.commitURL?.absoluteString
        == "https://github.com/acme/docs/commit/ad9ccd918a81025731e10e40267e11273a263421")
    #expect(deployment.buildConfig?.buildCommand == "npm run build")
    #expect(deployment.buildConfig?.destinationDirectory == "dist")
    // An unset setting arrives as "", which is not a directory to display.
    #expect(deployment.buildConfig?.rootDirectory == nil)
    #expect(deployment.buildConfig?.buildCaching == true)
    // Fractional and whole-second timestamps both parse.
    #expect(deployment.stages?[1].duration == 60)
    #expect(deployment.stages?[0].duration == 1)
    // First stage start → last stage end (72s), not created → modified (8h).
    #expect(deployment.buildDuration == 72)
  }

  @Test func pagesDeploymentSurvivesUnexpectedSourceAndRunningStages() throws {
    // A direct upload: no repository, and `source` in a shape the typed model
    // does not expect. The deployment must still decode.
    let running = try JSONDecoder().decode(
      PagesDeployment.self,
      from: Data(
        #"""
        {"id":"dep-2","environment":"production",
         "source":"none","build_config":{"build_command":"","destination_dir":""},
         "deployment_trigger":{"type":"ad_hoc","metadata":{"branch":"main",
           "commit_hash":"","commit_message":""}},
         "latest_stage":{"name":"build","status":"active",
           "started_on":"2021-03-09T00:55:10Z","ended_on":null},
         "stages":[
           {"name":"queued","status":"success",
            "started_on":"2021-03-09T00:55:03Z","ended_on":"2021-03-09T00:55:04Z"},
           {"name":"build","status":"active","started_on":"2021-03-09T00:55:10Z","ended_on":null},
           {"name":"deploy","status":"idle","started_on":null,"ended_on":null}
         ]}
        """#.utf8))

    #expect(running.source == nil)
    #expect(running.repository == nil)
    #expect(running.commitURL == nil)
    #expect(running.shortCommit == nil)
    #expect(running.deploymentTrigger?.kind == .manual)
    #expect(running.buildConfig?.buildCommand == nil)
    // Still building: a finished stage's end is not the deployment's duration.
    #expect(running.buildDuration == nil)
    #expect(running.stages?[1].duration == nil)

    // A provider whose commit URL shape is unknown gets no link.
    let other = try JSONDecoder().decode(
      PagesDeployment.self,
      from: Data(
        #"""
        {"id":"dep-3","source":{"type":"bitbucket","config":{"owner":"acme","repo_name":"docs"}},
         "deployment_trigger":{"type":"deploy_hook","metadata":{"commit_hash":"abc1234def"}}}
        """#.utf8))
    #expect(other.repository == "acme/docs")
    #expect(other.commitURL == nil)
    #expect(other.deploymentTrigger?.kind == .deployHook)
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

  @Test func workerSettingsSecretsAndSchedulesRoundTrip() async throws {
    let recorder = RequestRecorder()
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let method = request.httpMethod ?? "?"
      let path = request.url?.path ?? ""
      recorder.record("\(method) \(path)")
      if method == "GET", path.hasSuffix("/settings") {
        return (
          200,
          Data(
            #"""
            {"success":true,"result":{
              "compatibility_date":"2026-03-01",
              "compatibility_flags":["nodejs_compat"],
              "placement":{"mode":"smart"},
              "logpush":true,
              "bindings":[
                {"name":"API_BASE","type":"plain_text","text":"https://api.example.com"},
                {"name":"ASSETS","type":"r2_bucket","bucket_name":"media-prod"},
                {"name":"CACHE","type":"kv_namespace","namespace_id":"kv-123"},
                {"name":"DB","type":"d1","id":"d1-456"},
                {"name":"AUTH","type":"service","service":"auth-worker","environment":"production"},
                {"name":"API_KEY","type":"secret_text"},
                {"name":"CONFIG","type":"json","json":{"retries":3}}
              ]
            }}
            """#.utf8)
        )
      }
      if method == "GET", path.hasSuffix("/secrets") {
        return (
          200,
          Data(
            #"""
            {"success":true,"result":[
              {"name":"API_KEY","type":"secret_text"},
              {"name":"SIGNING_KEY","type":"secret_key"}
            ]}
            """#.utf8)
        )
      }
      if method == "PUT", path.hasSuffix("/secrets") {
        let body = try #require(requestBodyData(request))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["name"] as? String == "NEW_SECRET")
        #expect(payload["text"] as? String == "s3cr3t")
        #expect(payload["type"] as? String == "secret_text")
        return (
          200,
          Data(#"{"success":true,"result":{"name":"NEW_SECRET","type":"secret_text"}}"#.utf8)
        )
      }
      if method == "DELETE", path.hasSuffix("/secrets/API_KEY") {
        return (200, Data(#"{"success":true,"result":null}"#.utf8))
      }
      if method == "GET", path.hasSuffix("/schedules") {
        return (
          200,
          Data(
            #"""
            {"success":true,"result":{"schedules":[
              {"cron":"*/15 * * * *","created_on":"2026-01-01T00:00:00Z","modified_on":"2026-02-01T00:00:00Z"}
            ]}}
            """#.utf8)
        )
      }
      if method == "PUT", path.hasSuffix("/schedules") {
        let body = try #require(requestBodyData(request))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        #expect(payload.map { $0["cron"] as? String } == ["*/15 * * * *", "0 3 * * *"])
        return (
          200,
          Data(
            #"""
            {"success":true,"result":{"schedules":[
              {"cron":"*/15 * * * *","created_on":"2026-01-01T00:00:00Z","modified_on":"2026-02-01T00:00:00Z"},
              {"cron":"0 3 * * *","created_on":"2026-11-26T00:00:00Z","modified_on":"2026-11-26T00:00:00Z"}
            ]}}
            """#.utf8)
        )
      }
      return (404, Data(#"{"success":false,"errors":[{"code":404,"message":"not found"}]}"#.utf8))
    }

    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let settings = try await client.getWorkerSettings(accountID: "acct", scriptName: "api-worker")
    #expect(settings.compatibilityDate == "2026-03-01")
    #expect(settings.compatibilityFlags == ["nodejs_compat"])
    #expect(settings.placementMode == "smart")
    #expect(settings.logpush == true)
    #expect(settings.bindings.count == 7)
    #expect(
      settings.bindings.first { $0.name == "API_BASE" }?.summaryValue == "https://api.example.com")
    #expect(settings.bindings.first { $0.name == "ASSETS" }?.summaryValue == "media-prod")
    #expect(
      settings.bindings.first { $0.name == "AUTH" }?.summaryValue == "auth-worker (production)")
    #expect(settings.bindings.first { $0.name == "API_KEY" }?.isSecret == true)
    #expect(settings.bindings.first { $0.name == "CONFIG" }?.summaryValue == #"{"retries":3}"#)

    let secrets = try await client.listWorkerSecrets(accountID: "acct", scriptName: "api-worker")
    #expect(secrets.map(\.name) == ["API_KEY", "SIGNING_KEY"])
    #expect(secrets[0].isTextSecret)
    #expect(!secrets[1].isTextSecret)

    let added = try await client.putWorkerSecret(
      accountID: "acct", scriptName: "api-worker", name: "NEW_SECRET", text: "s3cr3t")
    #expect(added.name == "NEW_SECRET")

    try await client.deleteWorkerSecret(
      accountID: "acct", scriptName: "api-worker", secretName: "API_KEY")

    let initialCrons = try await client.listWorkerSchedules(
      accountID: "acct", scriptName: "api-worker")
    #expect(initialCrons.map(\.cron) == ["*/15 * * * *"])

    let updatedCrons = try await client.updateWorkerSchedules(
      accountID: "acct", scriptName: "api-worker", crons: ["*/15 * * * *", "0 3 * * *"])
    #expect(updatedCrons.map(\.cron) == ["*/15 * * * *", "0 3 * * *"])

    #expect(
      recorder.paths == [
        "GET /accounts/acct/workers/scripts/api-worker/settings",
        "GET /accounts/acct/workers/scripts/api-worker/secrets",
        "PUT /accounts/acct/workers/scripts/api-worker/secrets",
        "DELETE /accounts/acct/workers/scripts/api-worker/secrets/API_KEY",
        "GET /accounts/acct/workers/scripts/api-worker/schedules",
        "PUT /accounts/acct/workers/scripts/api-worker/schedules",
      ])
  }

  @Test func pagesProjectConfigEnvVarsPatchAndDeleteDeployment() async throws {
    let recorder = RequestRecorder()
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let method = request.httpMethod ?? "?"
      let path = request.url?.path ?? ""
      let query = request.url?.query ?? ""
      recorder.record("\(method) \(path)\(query.isEmpty ? "" : "?\(query)")")
      if method == "GET", path.hasSuffix("/pages/projects/web") {
        return (
          200,
          Data(
            #"""
            {"success":true,"result":{
              "id":"pp-web","name":"web","subdomain":"web.pages.dev",
              "production_branch":"main",
              "source":{"type":"github","config":{"owner":"acme","repo_name":"web","production_branch":"main"}},
              "build_config":{"build_command":"pnpm build","destination_dir":"dist","root_dir":"apps/web"},
              "deployment_configs":{
                "production":{
                  "compatibility_date":"2026-03-01",
                  "compatibility_flags":["nodejs_compat"],
                  "env_vars":{
                    "PUBLIC_API":{"type":"plain_text","value":"https://api.example.com"},
                    "API_SECRET":{"type":"secret_text"},
                    "REMOVED":null
                  }
                },
                "preview":{
                  "env_vars":{
                    "PUBLIC_API":{"type":"plain_text","value":"https://staging.example.com"}
                  }
                }
              }
            }}
            """#.utf8)
        )
      }
      if method == "PATCH", path.hasSuffix("/pages/projects/web") {
        let body = try #require(requestBodyData(request))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let configs = try #require(payload["deployment_configs"] as? [String: Any])
        if let prod = configs["production"] as? [String: Any],
          let vars = prod["env_vars"] as? [String: Any]
        {
          if let entry = vars["NEW_FLAG"] as? [String: Any] {
            #expect(entry["type"] as? String == "plain_text")
            #expect(entry["value"] as? String == "true")
          } else {
            #expect(vars["PUBLIC_API"] is NSNull)
          }
        }
        return (
          200,
          Data(
            #"""
            {"success":true,"result":{"id":"pp-web","name":"web","subdomain":"web.pages.dev"}}
            """#.utf8)
        )
      }
      if method == "DELETE", path.hasSuffix("/pages/projects/web/deployments/dep-old") {
        return (200, Data(#"{"success":true,"result":null}"#.utf8))
      }
      return (404, Data(#"{"success":false,"errors":[{"code":404,"message":"not found"}]}"#.utf8))
    }

    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let project = try await client.getPagesProject(accountID: "acct", projectName: "web")
    #expect(project.productionBranch == "main")
    #expect(project.source?.config?.owner == "acme")
    #expect(project.buildConfig?.buildCommand == "pnpm build")
    let prodConfig = try #require(project.deploymentConfigs?.config(for: .production))
    #expect(prodConfig.compatibilityDate == "2026-03-01")
    #expect(prodConfig.compatibilityFlags == ["nodejs_compat"])
    #expect(prodConfig.envVars["PUBLIC_API"]?.value == "https://api.example.com")
    #expect(prodConfig.envVars["API_SECRET"]?.isSecret == true)
    #expect(prodConfig.envVars["REMOVED"] == nil)

    _ = try await client.updatePagesEnvironmentVariable(
      accountID: "acct", projectName: "web", environment: .production,
      name: "NEW_FLAG", value: "true", isSecret: false)
    _ = try await client.deletePagesEnvironmentVariable(
      accountID: "acct", projectName: "web", environment: .production, name: "PUBLIC_API")
    try await client.deletePagesDeployment(
      accountID: "acct", projectName: "web", deploymentID: "dep-old", force: true)

    #expect(
      recorder.paths == [
        "GET /accounts/acct/pages/projects/web",
        "PATCH /accounts/acct/pages/projects/web",
        "PATCH /accounts/acct/pages/projects/web",
        "DELETE /accounts/acct/pages/projects/web/deployments/dep-old?force=true",
      ])
  }

  @Test func workerRouteCreateUpdateAndDeleteRoundTrip() async throws {
    let recorder = RequestRecorder()
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      let method = request.httpMethod ?? "?"
      let path = request.url?.path ?? ""
      recorder.record("\(method) \(path)")
      if method == "POST", path == "/zones/zone-1/workers/routes" {
        let body = try #require(requestBodyData(request))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["pattern"] as? String == "example.com/api/*")
        #expect(payload["script"] as? String == "api-worker")
        return (
          200,
          Data(
            #"{"success":true,"result":{"id":"route-1","pattern":"example.com/api/*","script":"api-worker"}}"#
              .utf8)
        )
      }
      if method == "PUT", path == "/zones/zone-1/workers/routes/route-1" {
        let body = try #require(requestBodyData(request))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["pattern"] as? String == "example.com/v2/*")
        #expect(payload["script"] as? String == "api-worker")
        return (
          200,
          Data(
            #"{"success":true,"result":{"id":"route-1","pattern":"example.com/v2/*","script":"api-worker"}}"#
              .utf8)
        )
      }
      if method == "DELETE", path == "/zones/zone-1/workers/routes/route-1" {
        return (200, Data(#"{"success":true,"result":{"id":"route-1"}}"#.utf8))
      }
      return (404, Data(#"{"success":false,"errors":[{"code":404,"message":"not found"}]}"#.utf8))
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let created = try await client.createWorkerRoute(
      zoneID: "zone-1", pattern: "example.com/api/*", script: "api-worker")
    #expect(created.id == "route-1")
    let updated = try await client.updateWorkerRoute(
      zoneID: "zone-1", routeID: "route-1", pattern: "example.com/v2/*", script: "api-worker")
    #expect(updated.pattern == "example.com/v2/*")
    try await client.deleteWorkerRoute(zoneID: "zone-1", routeID: "route-1")

    #expect(
      recorder.paths == [
        "POST /zones/zone-1/workers/routes",
        "PUT /zones/zone-1/workers/routes/route-1",
        "DELETE /zones/zone-1/workers/routes/route-1",
      ])
  }

  @Test func queryWorkerObservabilityLogsSendsFiltersAndNormalizesInvocations() async throws {
    let recorder = RequestRecorder()
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)
    let session = mockSession { request in
      let method = request.httpMethod ?? "?"
      let path = request.url?.path ?? ""
      recorder.record("\(method) \(path)")
      guard method == "POST", path == "/accounts/acct-1/workers/observability/telemetry/query"
      else {
        return (404, Data(#"{"success":false,"errors":[{"code":404,"message":"not found"}]}"#.utf8))
      }
      let body = try #require(requestBodyData(request))
      let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
      #expect(payload["dry"] as? Bool == true)
      #expect(payload["view"] as? String == "invocations")
      let timeframe = try #require(payload["timeframe"] as? [String: Any])
      let fromMs = try #require(timeframe["from"] as? Int64)
      let toMs = try #require(timeframe["to"] as? Int64)
      #expect(toMs - fromMs == 15 * 60 * 1000)
      let parameters = try #require(payload["parameters"] as? [String: Any])
      let filters = try #require(parameters["filters"] as? [[String: Any]])
      #expect(filters.count == 2)
      #expect(filters[0]["key"] as? String == "$metadata.service")
      #expect(filters[0]["value"] as? String == "api-worker")
      #expect(filters[1]["kind"] as? String == "group")
      #expect(filters[1]["filterCombination"] as? String == "or")

      return (
        200,
        Data(
          #"""
          {
            "success": true,
            "result": {
              "invocations": {
                "req-err": [
                  {
                    "$metadata": {
                      "id": "ev-2",
                      "requestId": "req-err",
                      "level": "error",
                      "message": "TypeError: Cannot read properties of undefined",
                      "error": "TypeError: Cannot read properties of undefined"
                    },
                    "timestamp": 1759999900200,
                    "source": {"stack": "at checkout (index.js:42)"}
                  },
                  {
                    "$metadata": {
                      "id": "ev-1",
                      "requestId": "req-err",
                      "type": "cf-worker-event",
                      "trigger": "POST /v1/checkout",
                      "url": "https://api.example.com/v1/checkout",
                      "statusCode": 500,
                      "duration": 18.4,
                      "rayId": "9a1b2c3d"
                    },
                    "timestamp": 1759999900000,
                    "$workers": {
                      "eventType": "fetch",
                      "scriptName": "api-worker",
                      "outcome": "exception",
                      "cpuTimeMs": 4.2,
                      "wallTimeMs": 18.4,
                      "event": {
                        "request": { "method": "POST", "url": "https://api.example.com/v1/checkout" },
                        "response": { "status": 500 }
                      }
                    }
                  },
                  {
                    "$metadata": {
                      "id": "ev-1b",
                      "requestId": "req-err",
                      "level": "info",
                      "message": "Starting checkout"
                    },
                    "timestamp": 1759999900050,
                    "source": "Starting checkout"
                  }
                ],
                "req-ok": [
                  {
                    "$metadata": {
                      "id": "ev-ok",
                      "requestId": "req-ok",
                      "type": "cf-worker-event",
                      "trigger": "GET /health",
                      "url": "https://api.example.com/health",
                      "statusCode": 200,
                      "duration": 1.5
                    },
                    "timestamp": 1759999800000,
                    "$workers": {
                      "eventType": "fetch",
                      "scriptName": "api-worker",
                      "outcome": "ok",
                      "cpuTimeMs": 0.4
                    }
                  }
                ]
              }
            }
          }
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let records = try await client.queryWorkerObservabilityLogs(
      accountID: "acct-1",
      scriptName: "api-worker",
      windowMinutes: 15,
      errorsOnly: true,
      limit: 25,
      now: fixedNow)

    #expect(recorder.paths == ["POST /accounts/acct-1/workers/observability/telemetry/query"])
    #expect(records.count == 2)
    // Newest first.
    #expect(records[0].id == "req-err")
    #expect(records[0].method == "POST")
    #expect(records[0].statusCode == 500)
    #expect(records[0].outcome == "exception")
    #expect(records[0].rayID == "9a1b2c3d")
    #expect(records[0].isError == true)
    // Console logs sorted chronologically.
    #expect(
      records[0].consoleLogs.map(\.message) == [
        "Starting checkout",
        "TypeError: Cannot read properties of undefined",
      ])
    #expect(records[1].id == "req-ok")
    #expect(records[1].method == "GET")
    #expect(records[1].isError == false)
    #expect(records[1].consoleLogs.isEmpty)
  }

  @Test func workerObservabilityResponseFallsBackToFlatEventsGrouping() throws {
    let json = #"""
      {
        "events": {
          "count": 2,
          "events": [
            {
              "$metadata": {
                "id": "e1",
                "requestId": "r-flat",
                "type": "cf-worker-event",
                "trigger": "GET /items",
                "statusCode": 200
              },
              "timestamp": 1000,
              "$workers": { "outcome": "ok" }
            },
            {
              "$metadata": {
                "id": "e2",
                "requestId": "r-flat",
                "level": "log",
                "message": "loaded 3 items"
              },
              "timestamp": 1010
            }
          ]
        }
      }
      """#
    let decoded = try JSONDecoder().decode(
      WorkerObservabilityQueryResponse.self, from: Data(json.utf8))
    let records = decoded.invocationsList()
    #expect(records.count == 1)
    #expect(records[0].id == "r-flat")
    #expect(records[0].method == "GET")
    #expect(records[0].consoleLogs.map(\.message) == ["loaded 3 items"])
  }
}
