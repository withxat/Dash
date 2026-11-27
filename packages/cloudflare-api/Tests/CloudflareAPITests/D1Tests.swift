import Foundation
import Testing

@testable import CloudflareAPI

/// Cloudflare D1, read-only.
///
/// The network tests live in `extension NetworkTests` so they inherit that
/// suite's `.serialized` trait — `MockURLProtocol` keeps its handler in
/// `nonisolated(unsafe) static` state. Every function is prefixed `d1…` so
/// `--filter d1` selects the whole set.
extension NetworkTests {

  @Test func d1ListPagesUntilTotalCountAndReadsUUIDAsID() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let recorder = RequestRecorder()
    let session = mockSession { request in
      let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
      let page = items?.first { $0.name == "page" }?.value ?? "?"
      recorder.record(page)
      #expect(request.url?.path == "/accounts/acc/d1/database")
      #expect(request.httpMethod == "GET")
      if page == "1" {
        return (
          200,
          Data(
            #"""
            {"success":true,"result":[
              {"uuid":"db-1","name":"app","created_at":"2025-09-14T09:12:00Z","version":"production"}
            ],"result_info":{"page":1,"per_page":1,"total_count":2}}
            """#.utf8)
        )
      }
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[{"uuid":"db-2","name":"events","jurisdiction":"eu"}],
           "result_info":{"page":2,"per_page":1,"total_count":2}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let databases = try await client.listD1Databases(accountID: "acc")

    #expect(recorder.paths == ["1", "2"])
    #expect(databases.map(\.id) == ["db-1", "db-2"])
    #expect(databases.map(\.name) == ["app", "events"])
    #expect(databases[0].createdAt == "2025-09-14T09:12:00Z")
    #expect(databases[1].jurisdiction == "eu")
    // The list endpoint carries none of these; they must not decode as zero.
    #expect(databases[0].fileSize == nil)
    #expect(databases[0].readReplicationMode == nil)
  }

  @Test func d1DatabaseDetailDecodesSizeRegionAndNestedReplicationMode() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acc/d1/database/db-1")
      return (
        200,
        Data(
          #"""
          {"success":true,"result":{
            "uuid":"db-1","name":"app","created_at":"2025-09-14T09:12:00Z","version":"production",
            "file_size":5000000000,"num_tables":12,"running_in_region":"WEUR",
            "read_replication":{"mode":"auto"}}}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let database = try await client.getD1Database(accountID: "acc", databaseID: "db-1")

    // Larger than Int32: a multi-gigabyte database is ordinary.
    #expect(database.fileSize == 5_000_000_000)
    #expect(database.runningInRegion == "WEUR")
    #expect(database.readReplicationMode == "auto")

    // The feature cache persists what it is handed, so the nested replication
    // object has to survive an encode and decode.
    let restored = try JSONDecoder().decode(
      D1Database.self, from: JSONEncoder().encode(database))
    #expect(restored == database)
  }

  @Test func d1QueryPostsToRawAndKeepsColumnOrderAndValueTypes() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(request.url?.path == "/accounts/acc/d1/database/db-1/raw")
      #expect(request.httpMethod == "POST")
      let body = requestBodyObject(request)
      #expect(body?["sql"] as? String == "SELECT * FROM t; SELECT 1")
      #expect(body?["params"] as? [String] == [])
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[
            {"success":true,
             "meta":{"changed_db":false,"changes":0,"duration":0.25,"rows_read":2,
                     "rows_written":0,"served_by_region":"WEUR"},
             "results":{"columns":["zeta","alpha","note"],
                        "rows":[[1,"first",null],[2.5,"second",true]]}},
            {"success":true,"meta":{"duration":0.1},"results":{"columns":["1"],"rows":[[1]]}}
          ]}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let results = try await client.queryD1Database(
      accountID: "acc", databaseID: "db-1", sql: "SELECT * FROM t; SELECT 1")

    // One result per statement, in statement order.
    #expect(results.count == 2)
    // Not alphabetical: `/raw` exists so the statement's own order survives.
    #expect(results[0].columns == ["zeta", "alpha", "note"])
    #expect(
      results[0].rows == [
        [.number(1), .string("first"), .null],
        [.number(2.5), .string("second"), .bool(true)],
      ])
    #expect(results[0].meta?.rowsRead == 2)
    #expect(results[0].meta?.duration == 0.25)
    #expect(results[0].meta?.changedDB == false)
    #expect(results[0].meta?.servedByRegion == "WEUR")
    #expect(results[1].columns == ["1"])
    #expect(results[1].meta?.rowsRead == nil)
  }

  @Test func d1QueryRejectionSurfacesCloudflaresOwnMessage() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { _ in
      (
        400,
        Data(
          #"""
          {"success":false,"result":[],"messages":[],
           "errors":[{"code":7500,"message":"no such table: missing: SQLITE_ERROR"}]}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    do {
      _ = try await client.queryD1Database(
        accountID: "acc", databaseID: "db-1", sql: "SELECT * FROM missing")
      Issue.record("A rejected statement must throw.")
    } catch let error as CloudflareAPIError {
      guard case .request(let status, let errors) = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(status == 400)
      #expect(errors.first?.code == 7500)
      #expect(error.errorDescription == "no such table: missing: SQLITE_ERROR")
    }
  }

  @Test func d1TablesComeFromTheSchemaQueryAndSkipMalformedRows() async throws {
    let store = MemoryTokenStore(access: "token", refresh: nil)
    let session = mockSession { request in
      #expect(requestBodyObject(request)?["sql"] as? String == D1SQL.listTables)
      return (
        200,
        Data(
          #"""
          {"success":true,"result":[{"success":true,"meta":{},
            "results":{"columns":["name","type","sql"],"rows":[
              ["orders","table","CREATE TABLE orders (id INTEGER PRIMARY KEY)"],
              ["paid_orders","view","CREATE VIEW paid_orders AS SELECT * FROM orders"],
              ["no_sql","table",null],
              [null,"table","CREATE TABLE ghost (id)"],
              ["short"]
            ]}}]}
          """#.utf8)
      )
    }
    let client = CloudflareClient(
      clientID: "client", tokenStore: store, apiBase: URL(string: "https://api.example.test")!,
      session: session)

    let tables = try await client.listD1Tables(accountID: "acc", databaseID: "db-1")

    #expect(tables.map(\.name) == ["orders", "paid_orders", "no_sql"])
    #expect(tables.map(\.isView) == [false, true, false])
    #expect(tables[0].sql == "CREATE TABLE orders (id INTEGER PRIMARY KEY)")
    #expect(tables[2].sql == nil)
  }
}

@Test func d1IdentifierQuotingCannotBeEscapedByATableName() {
  #expect(D1SQL.quotedIdentifier("users") == #""users""#)
  #expect(D1SQL.quotedIdentifier("order items") == #""order items""#)
  // A name with a quote in it stays one identifier instead of closing the
  // quote and starting a second statement.
  #expect(D1SQL.quotedIdentifier(#"a"; DROP TABLE b; --"#) == #""a""; DROP TABLE b; --""#)
  #expect(D1SQL.previewRows(table: "users") == #"SELECT * FROM "users" LIMIT 50"#)
  #expect(D1SQL.previewRows(table: "users", limit: 5) == #"SELECT * FROM "users" LIMIT 5"#)
  // A caller's zero or negative limit must not produce `LIMIT -1`, which
  // SQLite reads as "no limit".
  #expect(D1SQL.previewRows(table: "users", limit: 0) == #"SELECT * FROM "users" LIMIT 1"#)
  #expect(D1SQL.previewRows(table: "users", limit: -1) == #"SELECT * FROM "users" LIMIT 1"#)
}

@Test func d1SchemaQueryHidesOnlyInternalTables() {
  // `_` is a single-character wildcard in LIKE. Unescaped, the filter meant for
  // `sqlite_sequence` and `_cf_KV` would also hide `sqliteXnotes`.
  #expect(D1SQL.listTables.contains(#"NOT LIKE 'sqlite\_%' ESCAPE '\'"#))
  #expect(D1SQL.listTables.contains(#"NOT LIKE '\_cf\_%' ESCAPE '\'"#))
  #expect(D1SQL.listTables.contains("type IN ('table', 'view')"))
  #expect(!D1SQL.listTables.contains("\n"))
}
