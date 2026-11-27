import Foundation

/// Demo D1: fixed databases, schemas and rows, plus the one statement shape the
/// query screen needs.
///
/// This is not a SQL engine and does not pretend to be. It answers
/// `SELECT <columns | * | count(*)> FROM <table> [LIMIT n]` and the
/// `sqlite_master` read Dash issues for a schema. Anything else fails with a
/// message that says so — a `WHERE` the demo silently ignored would hand back
/// rows the statement never asked for, which is worse than no answer.
enum DemoD1 {
  enum Value: Sendable, Equatable {
    case int(Int)
    case text(String)
    case null

    var json: Any {
      switch self {
      case .int(let value): value
      case .text(let value): value
      case .null: NSNull()
      }
    }
  }

  struct Table: Sendable {
    let name: String
    /// `table` or `view`, as SQLite spells it.
    let kind: String
    let sql: String
    let columns: [String]
    let rows: [[Value]]
  }

  struct Database: Sendable {
    let id: String
    let name: String
    let createdAt: String
    let fileSize: Int
    let region: String
    let replication: String
    let tables: [Table]

    var summary: [String: Any] {
      ["uuid": id, "name": name, "created_at": createdAt, "version": "production"]
    }

    var detail: [String: Any] {
      summary.merging(
        [
          "file_size": fileSize,
          "running_in_region": region,
          "read_replication": ["mode": replication],
        ], uniquingKeysWith: { _, new in new })
    }
  }

  enum Outcome: Equatable {
    case rows(columns: [String], rows: [[Value]], rowsRead: Int)
    case failure(String)
  }

  static let readOnlyMessage =
    "The demo's databases are read-only. Dash connects to D1 with read access only."
  static let unsupportedMessage =
    "The demo answers SELECT … FROM <table> [LIMIT n] only."

  static func database(id: String) -> Database? {
    databases.first { $0.id == id }
  }

  static func run(sql rawSQL: String, in database: Database) -> Outcome {
    var sql = rawSQL.trimmingCharacters(in: .whitespacesAndNewlines)
    while sql.hasSuffix(";") {
      sql = String(sql.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let lowered = sql.lowercased()
    let keyword = lowered.prefix { $0.isLetter }
    if writeKeywords.contains(String(keyword)) { return .failure(readOnlyMessage) }
    guard keyword == "select",
      let from = lowered.range(of: #"\sfrom\s"#, options: .regularExpression),
      let source = lowered[from.upperBound...].firstMatch(of: #/^"?([a-z0-9_]+)"?/#)
    else { return .failure(unsupportedMessage) }

    let sourceName = String(source.output.1)
    let rest = String(lowered[from.upperBound...][source.range.upperBound...])
    let selection = lowered[
      lowered.index(lowered.startIndex, offsetBy: keyword.count)..<from.lowerBound
    ]
    .trimmingCharacters(in: .whitespacesAndNewlines)

    let table: Table
    if sourceName == "sqlite_master" || sourceName == "sqlite_schema" {
      // The fixtures hold user tables only, already in name order, so the
      // WHERE and ORDER BY of Dash's own schema read select every row as is.
      table = schemaTable(for: database)
    } else {
      guard let match = database.tables.first(where: { $0.name == sourceName }) else {
        return .failure("no such table: \(sourceName): SQLITE_ERROR")
      }
      // Only an optional LIMIT may follow the table name.
      guard rest.wholeMatch(of: #/\s*(limit\s+\d+)?\s*/#) != nil else {
        return .failure(unsupportedMessage)
      }
      table = match
    }

    let limit = rest.firstMatch(of: #/limit\s+(\d+)/#).flatMap { Int($0.output.1) }
    let rows = limit.map { Array(table.rows.prefix($0)) } ?? table.rows

    if selection == "*" {
      return .rows(columns: table.columns, rows: rows, rowsRead: rows.count)
    }
    if selection.replacingOccurrences(of: " ", with: "") == "count(*)" {
      return .rows(
        columns: ["count(*)"], rows: [[.int(table.rows.count)]], rowsRead: table.rows.count)
    }
    var indexes: [Int] = []
    var names: [String] = []
    for part in selection.split(separator: ",") {
      let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      guard let index = table.columns.firstIndex(of: name) else {
        return .failure("no such column: \(name): SQLITE_ERROR")
      }
      indexes.append(index)
      names.append(name)
    }
    guard !indexes.isEmpty else { return .failure(unsupportedMessage) }
    return .rows(
      columns: names, rows: rows.map { row in indexes.map { row[$0] } }, rowsRead: rows.count)
  }

  /// One `/raw` statement result, in Cloudflare's shape.
  static func rawResult(columns: [String], rows: [[Value]], rowsRead: Int) -> [String: Any] {
    [
      "success": true,
      "meta": [
        "changed_db": false, "changes": 0, "duration": 0.42, "rows_read": rowsRead,
        "rows_written": 0, "served_by_region": "WNAM",
      ],
      "results": ["columns": columns, "rows": rows.map { $0.map(\.json) }],
    ]
  }

  private static let writeKeywords: Set<String> = [
    "insert", "update", "delete", "replace", "create", "drop", "alter", "vacuum", "attach",
    "detach", "reindex",
  ]

  private static func schemaTable(for database: Database) -> Table {
    Table(
      name: "sqlite_master", kind: "table", sql: "",
      columns: ["type", "name", "tbl_name", "sql"],
      rows: database.tables.map {
        [.text($0.kind), .text($0.name), .text($0.name), .text($0.sql)]
      })
  }

  static let databases: [Database] = [
    Database(
      id: "7b2c0f4e-5a1d-4c3b-9e8f-2d6a1b0c4e11",
      name: "app-production",
      createdAt: "2025-09-14T09:12:00Z",
      fileSize: 4_812_800,
      region: "WNAM",
      replication: "auto",
      tables: [
        Table(
          name: "active_users", kind: "view",
          sql: "CREATE VIEW active_users AS SELECT id, email, plan FROM users WHERE plan != 'free'",
          columns: ["id", "email", "plan"],
          rows: [
            [.int(1), .text("ada@example.com"), .text("pro")],
            [.int(3), .text("grace@example.com"), .text("team")],
            [.int(4), .text("linus@example.com"), .text("pro")],
          ]),
        Table(
          name: "orders", kind: "table",
          sql: """
            CREATE TABLE orders (
              id INTEGER PRIMARY KEY,
              user_id INTEGER NOT NULL REFERENCES users(id),
              total_cents INTEGER NOT NULL,
              status TEXT NOT NULL DEFAULT 'pending',
              created_at TEXT NOT NULL
            )
            """,
          columns: ["id", "user_id", "total_cents", "status", "created_at"],
          rows: [
            [.int(1001), .int(1), .int(2900), .text("paid"), .text("2026-07-21T10:02:11Z")],
            [.int(1002), .int(3), .int(9900), .text("paid"), .text("2026-07-22T15:40:03Z")],
            [.int(1003), .int(4), .int(2900), .text("refunded"), .text("2026-07-24T08:17:45Z")],
            [.int(1004), .int(1), .int(2900), .text("pending"), .text("2026-07-28T19:55:30Z")],
          ]),
        Table(
          name: "users", kind: "table",
          sql: """
            CREATE TABLE users (
              id INTEGER PRIMARY KEY,
              email TEXT NOT NULL UNIQUE,
              plan TEXT NOT NULL DEFAULT 'free',
              referred_by INTEGER,
              created_at TEXT NOT NULL
            )
            """,
          columns: ["id", "email", "plan", "referred_by", "created_at"],
          rows: [
            [
              .int(1), .text("ada@example.com"), .text("pro"), .null, .text("2025-09-15T08:00:00Z"),
            ],
            [
              .int(2), .text("alan@example.com"), .text("free"), .int(1),
              .text("2025-10-02T12:30:00Z"),
            ],
            [
              .int(3), .text("grace@example.com"), .text("team"), .null,
              .text("2025-11-19T17:45:00Z"),
            ],
            [
              .int(4), .text("linus@example.com"), .text("pro"), .int(3),
              .text("2026-02-07T06:20:00Z"),
            ],
            [
              .int(5), .text("margaret@example.com"), .text("free"), .null,
              .text("2026-06-30T21:10:00Z"),
            ],
          ]),
      ]),
    Database(
      id: "c41e9a70-3f6b-4d82-a5c7-90be13f2d6a2",
      name: "analytics-events",
      createdAt: "2026-01-08T14:30:00Z",
      fileSize: 61_440_000,
      region: "WEUR",
      replication: "disabled",
      tables: [
        Table(
          name: "events", kind: "table",
          sql: """
            CREATE TABLE events (
              id INTEGER PRIMARY KEY,
              name TEXT NOT NULL,
              path TEXT,
              country TEXT,
              ts TEXT NOT NULL
            )
            """,
          columns: ["id", "name", "path", "country", "ts"],
          rows: [
            [
              .int(1), .text("page_view"), .text("/"), .text("US"), .text("2026-07-29T06:00:01Z"),
            ],
            [
              .int(2), .text("page_view"), .text("/pricing"), .text("DE"),
              .text("2026-07-29T06:00:07Z"),
            ],
            [.int(3), .text("signup"), .null, .text("JP"), .text("2026-07-29T06:01:42Z")],
            [
              .int(4), .text("page_view"), .text("/docs"), .text("BR"),
              .text("2026-07-29T06:02:15Z"),
            ],
          ])
      ]),
    Database(
      id: "0e5d7c21-8b94-4f10-b3a6-47c8f9d1e0b3",
      name: "app-staging",
      createdAt: "2026-07-01T11:00:00Z",
      fileSize: 12_288,
      region: "WNAM",
      replication: "disabled",
      tables: []),
  ]
}
