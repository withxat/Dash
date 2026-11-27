import Foundation

// Cloudflare D1, read-only.
//
// Dash asks for `d1.read` and nothing else, and that is what keeps the query
// screen safe: since 2025 Cloudflare rejects a statement that would modify the
// database when the token lacks D1 Write, so the guard is the server's and not
// a SQL parser in the client that a clever statement could talk its way past.

/// One D1 database. The list endpoint answers with the first five fields only;
/// `fileSize`, `runningInRegion`, and `readReplicationMode` arrive from the
/// single-database read. `num_tables` is deliberately not modelled — Cloudflare
/// documents it as no longer accurate, and the schema query counts for real.
public struct D1Database: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let createdAt: String?
  public let version: String?
  public let jurisdiction: String?
  public let fileSize: Int64?
  public let runningInRegion: String?
  public let readReplicationMode: String?

  public init(
    id: String,
    name: String,
    createdAt: String? = nil,
    version: String? = nil,
    jurisdiction: String? = nil,
    fileSize: Int64? = nil,
    runningInRegion: String? = nil,
    readReplicationMode: String? = nil
  ) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.version = version
    self.jurisdiction = jurisdiction
    self.fileSize = fileSize
    self.runningInRegion = runningInRegion
    self.readReplicationMode = readReplicationMode
  }

  private enum CodingKeys: String, CodingKey {
    case id = "uuid"
    case name, version, jurisdiction
    case createdAt = "created_at"
    case fileSize = "file_size"
    case runningInRegion = "running_in_region"
    case readReplication = "read_replication"
  }

  private struct ReadReplication: Codable {
    let mode: String?
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
    createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
    version = try container.decodeIfPresent(String.self, forKey: .version)
    jurisdiction = try container.decodeIfPresent(String.self, forKey: .jurisdiction)
    fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
    runningInRegion = try container.decodeIfPresent(String.self, forKey: .runningInRegion)
    readReplicationMode =
      try container.decodeIfPresent(ReadReplication.self, forKey: .readReplication)?.mode
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(version, forKey: .version)
    try container.encodeIfPresent(jurisdiction, forKey: .jurisdiction)
    try container.encodeIfPresent(fileSize, forKey: .fileSize)
    try container.encodeIfPresent(runningInRegion, forKey: .runningInRegion)
    if let readReplicationMode {
      try container.encode(ReadReplication(mode: readReplicationMode), forKey: .readReplication)
    }
  }
}

/// A table or view from the database's own `sqlite_master`.
public struct D1Table: Codable, Hashable, Identifiable, Sendable {
  public let name: String
  /// `table` or `view`, as SQLite spells it.
  public let kind: String
  /// The `CREATE …` statement that defines it.
  public let sql: String?

  public var id: String { name }
  public var isView: Bool { kind == "view" }

  public init(name: String, kind: String, sql: String? = nil) {
    self.name = name
    self.kind = kind
    self.sql = sql
  }
}

public struct D1QueryMeta: Decodable, Hashable, Sendable {
  public let changedDB: Bool?
  public let changes: Int?
  /// Whole-request duration in milliseconds, network included.
  public let duration: Double?
  public let rowsRead: Int?
  public let rowsWritten: Int?
  public let servedByRegion: String?

  public init(
    changedDB: Bool? = nil,
    changes: Int? = nil,
    duration: Double? = nil,
    rowsRead: Int? = nil,
    rowsWritten: Int? = nil,
    servedByRegion: String? = nil
  ) {
    self.changedDB = changedDB
    self.changes = changes
    self.duration = duration
    self.rowsRead = rowsRead
    self.rowsWritten = rowsWritten
    self.servedByRegion = servedByRegion
  }

  private enum CodingKeys: String, CodingKey {
    case changes, duration
    case changedDB = "changed_db"
    case rowsRead = "rows_read"
    case rowsWritten = "rows_written"
    case servedByRegion = "served_by_region"
  }
}

/// One statement's answer from `/raw`: column names in the order the statement
/// produced them, and each row as an array in that same order. `/query` returns
/// rows as objects instead, which loses the column order a table needs.
public struct D1QueryResult: Decodable, Hashable, Sendable {
  public let columns: [String]
  public let rows: [[JSONValue]]
  public let meta: D1QueryMeta?

  public init(columns: [String], rows: [[JSONValue]], meta: D1QueryMeta? = nil) {
    self.columns = columns
    self.rows = rows
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case results, meta
  }

  private struct Results: Decodable {
    let columns: [String]?
    let rows: [[JSONValue]]?
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let results = try container.decodeIfPresent(Results.self, forKey: .results)
    columns = results?.columns ?? []
    rows = results?.rows ?? []
    meta = try container.decodeIfPresent(D1QueryMeta.self, forKey: .meta)
  }
}

/// The few statements Dash writes itself. Kept here so the identifier quoting
/// they depend on is covered by the package's tests.
public enum D1SQL {
  /// User tables and views. `sqlite_%` is SQLite's own bookkeeping and `_cf_%`
  /// is D1's; both are escaped because `_` is a single-character wildcard in
  /// `LIKE` and would otherwise hide a user table named `sqliteXfoo`.
  public static let listTables = """
    SELECT name, type, sql FROM sqlite_master \
    WHERE type IN ('table', 'view') \
    AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' \
    AND name NOT LIKE '\\_cf\\_%' ESCAPE '\\' \
    ORDER BY name
    """

  /// A table name as a SQLite identifier: wrapped in double quotes, with any
  /// double quote inside it doubled.
  public static func quotedIdentifier(_ name: String) -> String {
    "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  public static func previewRows(table: String, limit: Int = 50) -> String {
    "SELECT * FROM \(quotedIdentifier(table)) LIMIT \(max(1, limit))"
  }

}

private struct D1QueryRequest: Encodable, Sendable {
  let sql: String
  let params: [String]
}

extension CloudflareClient {
  /// Every D1 database on the account (`GET /accounts/{id}/d1/database`).
  public func listD1Databases(accountID: String) async throws -> [D1Database] {
    try await listAllPages("/accounts/\(accountID)/d1/database", perPage: 100)
  }

  /// One database with its size, region, and replication mode.
  public func getD1Database(accountID: String, databaseID: String) async throws -> D1Database {
    try await request("/accounts/\(accountID)/d1/database/\(databaseID)")
  }

  /// Runs SQL through `/raw` and returns one result per statement. A statement
  /// SQLite rejects — or one that would write under a read-only grant — throws
  /// with Cloudflare's own message.
  public func queryD1Database(
    accountID: String, databaseID: String, sql: String, params: [String] = []
  ) async throws -> [D1QueryResult] {
    try await request(
      "/accounts/\(accountID)/d1/database/\(databaseID)/raw",
      method: "POST",
      body: D1QueryRequest(sql: sql, params: params))
  }

  /// The database's tables and views with their `CREATE` statements.
  public func listD1Tables(accountID: String, databaseID: String) async throws -> [D1Table] {
    let results = try await queryD1Database(
      accountID: accountID, databaseID: databaseID, sql: D1SQL.listTables)
    guard let result = results.first else { return [] }
    return result.rows.compactMap { row in
      guard row.count >= 2, case .string(let name) = row[0], case .string(let kind) = row[1]
      else { return nil }
      let sql: String? = if row.count >= 3, case .string(let text) = row[2] { text } else { nil }
      return D1Table(name: name, kind: kind, sql: sql)
    }
  }
}
