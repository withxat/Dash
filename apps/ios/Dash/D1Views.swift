import CloudflareAPI
import CodeEditor
import SwiftUI
import UIKit

// Cloudflare D1, read-only and experimental.
//
// Dash asks for `d1.read` and nothing else. That one decision is the whole
// write guard: there is no statement filter on these screens, because a filter
// is a parser someone can talk their way past — the grant is not.
//
// Nothing a query returns is cached. The database list, a database's facts and
// its table names are (they are the catalog); rows are the user's data, and a
// copy kept for a relaunch would be both stale and on disk.

private enum D1ExternalURL {
  static let guide = URL(string: "https://developers.cloudflare.com/d1/")!
}

// MARK: - Result formatting

/// One row of a result set, carrying its columns so a tray can lay it out
/// without reaching back into the result it came from.
struct D1ResultRow: Identifiable, Equatable {
  let id: String
  let columns: [String]
  let values: [JSONValue]
}

/// Pure formatting for D1 result sets, tested independently of SwiftUI.
enum D1ResultFormatting {
  /// Rows a result group paints. A `SELECT *` on a large table answers with
  /// everything; the list is lazy, but a few hundred rows is already more than
  /// anyone reads on a phone.
  static let displayedRowLimit = 200

  static func text(_ value: JSONValue) -> String {
    switch value {
    case .null: return "NULL"
    case .bool(let flag): return flag ? "true" : "false"
    case .string(let text): return text
    case .number(let number):
      // SQLite integers arrive as JSON numbers; print them without the ".0"
      // a Double would add. 2^53 is where a Double stops being exact anyway.
      if number.rounded() == number, abs(number) < 9_007_199_254_740_992 {
        return String(Int64(number))
      }
      return String(number)
    case .array, .object:
      return json(value)
    }
  }

  static func rows(for result: D1QueryResult, resultIndex: Int) -> [D1ResultRow] {
    result.rows.prefix(displayedRowLimit).enumerated().map { index, values in
      D1ResultRow(id: "\(resultIndex)-\(index)", columns: result.columns, values: values)
    }
  }

  /// The first column's value: in a `SELECT *` that is the primary key or the
  /// name far more often than not.
  static func title(for row: D1ResultRow) -> String {
    guard let first = row.values.first else { return "—" }
    let text = text(first)
    return text.isEmpty ? "—" : text
  }

  /// The next three columns as `name: value`, so a row is recognisable before
  /// it is opened. Nil for a single-column result.
  static func subtitle(for row: D1ResultRow) -> String? {
    let pairs = zip(row.columns, row.values).dropFirst().prefix(3).map { column, value in
      "\(column): \(text(value))"
    }
    return pairs.isEmpty ? nil : pairs.joined(separator: " · ")
  }

  static func detailFields(for row: D1ResultRow) -> [DashDetailField] {
    zip(row.columns, row.values).map { column, value in
      // A column name is the user's schema, not Dash's copy: `status` must not
      // come back translated.
      DashDetailField(label: column, value: text(value), mono: true, verbatimLabel: true)
    }
  }

  /// The row as a JSON object with its columns in result order — which a
  /// dictionary would not keep.
  static func json(for row: D1ResultRow) -> String {
    let members = zip(row.columns, row.values).map { column, value in
      "  \(json(.string(column))): \(json(value))"
    }
    return "{\n" + members.joined(separator: ",\n") + "\n}"
  }

  /// "12 rows · 3.4 ms · 50 rows read".
  static func summary(for result: D1QueryResult) -> String {
    var parts: [String] = []
    let count = result.rows.count
    parts.append(
      count == 1 ? DashL10n.string("1 row") : DashL10n.string("\(count) rows"))
    if let duration = WorkerLogsFormatting.durationLabel(result.meta?.duration) {
      parts.append(duration)
    }
    if let rowsRead = result.meta?.rowsRead {
      parts.append(DashL10n.string("\(rowsRead) rows read"))
    }
    return parts.joined(separator: " · ")
  }

  private static func json(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8)
    else { return "null" }
    return text
  }
}

/// A statement the query screen can drop into its editor.
struct D1QueryExample: Identifiable, Equatable {
  let title: String
  let sql: String

  var id: String { sql }

  /// A computed title: the language can change while the app runs.
  static var listTables: D1QueryExample {
    D1QueryExample(
      title: DashL10n.string("List tables"),
      sql: "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name")
  }

  /// List tables, then a preview per table. Bounded: the tray lays these out
  /// eagerly, and a database may hold hundreds of tables.
  static func examples(for tables: [D1Table], limit: Int = 20) -> [D1QueryExample] {
    [listTables]
      + tables.prefix(limit).map {
        D1QueryExample(title: $0.name, sql: D1SQL.previewRows(table: $0.name))
      }
  }
}

// MARK: - List

struct D1DatabasesView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var databases: [D1Database] = []
  @State private var error: String?
  @State private var loading = true
  @State private var loadedContext: AccountRequestContext?
  @State private var searchQuery = ""

  private var isSearching: Bool {
    DashSearchMatcher.isActive(searchQuery)
  }

  private var filteredDatabases: [D1Database] {
    guard isSearching else { return databases }
    return databases.filter {
      DashSearchMatcher.matches(searchQuery, in: [$0.name, $0.id])
    }
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !databases.isEmpty,
      empty: DashFeatureEmpty(
        icon: SolarAsset.Content.database,
        title: DashL10n.string("No databases yet"),
        message: DashL10n.string("Create one in the dashboard or with Wrangler."),
        actionTitle: DashL10n.string("Open D1 docs"),
        action: { openURL(D1ExternalURL.guide) }
      ),
      retry: { Task { await load(force: true) } }
    ) { mode in
      if !mode.isPlaceholder {
        DashSearchBar(
          text: $searchQuery,
          prompt: DashL10n.string("Search databases"),
          accessibilityIdentifier: "d1-databases-search-field"
        )
        .padding(.bottom, DashTheme.Spacing.itemGap)
      }
      if !mode.isPlaceholder, isSearching, filteredDatabases.isEmpty {
        DashSearchEmptyState(query: searchQuery) {
          searchQuery = ""
        }
      } else {
        dashListCard {
          dashModeListRows(mode: mode, items: filteredDatabases, reduceMotion: reduceMotion) {
            database in
            DashListGroupLink(value: .d1Database(database.id)) {
              DashListRow(
                title: database.name,
                subtitle: database.createdAt.map {
                  DashDateFormatting.dateOnly(fromISO8601: $0)
                },
                icon: SolarAsset.Content.database
              )
              .accessibilityLabel(DashL10n.string("\(database.name), D1 database"))
            }
            .accessibilityIdentifier("d1-database-\(database.id)")
          }
        }
      }
    }
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) { await load() }
  }

  private func load(force: Bool = false) async {
    guard let context = model.accountRequestContext else {
      loadedContext = nil
      databases = []
      error = nil
      loading = false
      return
    }
    if loadedContext != context {
      loadedContext = context
      databases = []
      error = nil
      loading = true
    }
    let key = FeatureCacheKey.d1Databases(context.accountID)
    if !force, let cached: [D1Database] = model.featureCache.get(key) {
      databases = cached
      loading = false
      error = nil
      return
    }
    // Cold but a stale copy exists on disk: paint it now and refresh in place.
    if databases.isEmpty, let stale: [D1Database] = model.featureCache.getStale(key) {
      databases = stale
    }
    if databases.isEmpty { loading = true }
    error = nil
    do {
      let fetched = try await model.client.listD1Databases(accountID: context.accountID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      databases = fetched
      model.featureCache.set(key, fetched)
    } catch {
      guard !Task.isCancelled, model.isCurrentAccount(context), !error.dashIsCancellation
      else { return }
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}

// MARK: - Database

struct D1DatabaseView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let databaseID: String

  @State private var database: D1Database?
  @State private var loading = true
  @State private var error: String?
  /// Nil until the schema query answers. The tables are secondary: a database
  /// whose schema cannot be read still shows its facts and still takes a query.
  @State private var tables: [D1Table]?
  @State private var tablesError: String?
  @State private var selectedTable: D1Table?

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: database != nil,
      retry: { Task { await load(force: true) } }
    ) { mode in
      detailBody(mode: mode)
    }
    .detailHeader(icon: .feature(.d1), title: database?.name ?? "D1")
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) { await load() }
    .dashTray(
      item: $selectedTable,
      title: { $0.name },
      tone: FeatureVisualIdentity.tone(for: .d1),
      content: { table in
        D1TableTray(table: table) {
          navigator?.push(.d1Query(databaseID: databaseID, table: table.name))
        }
      }
    )
  }

  @ViewBuilder
  private func detailBody(mode: DashBodyMode) -> some View {
    DashInfoGroup(
      title: "Database", phase: mode.isPlaceholder ? .loading : .content, placeholderRows: 4
    ) {
      if let database { databaseRows(database) }
    }
    .dashBodySlot(reduceMotion: reduceMotion)

    // Above the tables on purpose: that list is unbounded, and the one action
    // this screen offers must not sit under it.
    DashTwoToneListGroup(title: "Actions") {
      DashListGroupLink(value: .d1Query(databaseID: databaseID, table: nil)) {
        DashListRow(
          title: DashL10n.string("Run a query"),
          icon: SolarAsset.code,
          showsIconPlate: false
        )
        .accessibilityLabel(DashL10n.string("Actions, Run a query"))
      }
      .accessibilityIdentifier("d1-run-query")
    }
    .dashBodyPlaceholder(mode.isPlaceholder)
    .dashSectionBoundary()
    .dashBodySlot(reduceMotion: reduceMotion)

    tablesSection(mode: mode)
  }

  @ViewBuilder
  private func databaseRows(_ database: D1Database) -> some View {
    Button {
      copyDatabaseID(database.id)
    } label: {
      DashInfoRow("Database ID", value: database.id, mono: true)
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityLabel(DashL10n.string("Database ID, \(database.id)"))
    .accessibilityAction(named: DashL10n.string("Copy database ID")) {
      copyDatabaseID(database.id)
    }
    if let created = database.createdAt {
      DashInfoRow("Created", value: DashDateFormatting.dateAndTime(fromISO8601: created))
    }
    if let size = database.fileSize {
      DashInfoRow(
        "Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
    }
    if let region = database.runningInRegion {
      DashInfoRow("Region", value: region)
    }
    if let jurisdiction = database.jurisdiction {
      DashInfoRow("Jurisdiction", value: jurisdiction.uppercased())
    }
    if let mode = database.readReplicationMode {
      DashInfoRow(
        "Read replication",
        value: mode == "auto" ? DashL10n.string("On") : DashL10n.string("Off"))
    }
  }

  private func copyDatabaseID(_ id: String) {
    UIPasteboard.general.string = id
    model.toasts.success(DashL10n.string("Database ID copied"))
  }

  @ViewBuilder
  private func tablesSection(mode: DashBodyMode) -> some View {
    let sectionMode: DashBodyMode =
      mode.isPlaceholder || (tables == nil && tablesError == nil) ? .placeholder : .live
    let rows = tables ?? []

    DashListGroupHeader(title: DashL10n.ui("Tables"))
      .dashTwoToneHeaderBand()
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)

    if sectionMode.isPlaceholder || !rows.isEmpty {
      dashModeListRows(
        mode: sectionMode,
        items: rows,
        placeholderRows: 3,
        reduceMotion: reduceMotion,
        frame: .twoTone
      ) { table in
        Button {
          selectedTable = table
        } label: {
          DashListRow(
            title: table.name,
            subtitle: table.isView ? DashL10n.string("View") : nil,
            icon: SolarAsset.Content.database,
            showsChevron: false
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityIdentifier("d1-table-\(table.name)")
      }
    } else if let tablesError {
      DashNotice(kind: .error, message: tablesError)
        .dashTwoToneRowSlice()
        .dashBodySlot(reduceMotion: reduceMotion)
    } else {
      Text("This database has no tables yet.")
        .dashTwoToneNote()
        .dashTwoToneRowSlice()
        .dashBodySlot(reduceMotion: reduceMotion)
    }
  }

  private func load(force: Bool = false) async {
    guard let context = model.accountRequestContext else {
      loading = false
      return
    }
    let accountID = context.accountID
    let databaseKey = FeatureCacheKey.d1Database(accountID: accountID, id: databaseID)
    let tablesKey = FeatureCacheKey.d1Tables(accountID: accountID, id: databaseID)
    if !force,
      let cachedDatabase: D1Database = model.featureCache.get(databaseKey),
      let cachedTables: [D1Table] = model.featureCache.get(tablesKey)
    {
      database = cachedDatabase
      tables = cachedTables
      tablesError = nil
      error = nil
      loading = false
      return
    }
    if database == nil { loading = true }
    error = nil

    let client = model.client
    let databaseID = databaseID
    async let databaseResult = Self.fetch {
      try await client.getD1Database(accountID: accountID, databaseID: databaseID)
    }
    async let tablesResult = Self.fetch {
      try await client.listD1Tables(accountID: accountID, databaseID: databaseID)
    }
    let (databaseOutcome, tablesOutcome) = await (databaseResult, tablesResult)
    guard !Task.isCancelled, model.isCurrentAccount(context) else { return }

    switch databaseOutcome {
    case .success(let fetched):
      database = fetched
      model.featureCache.set(databaseKey, fetched)
    case .failure(let failure):
      guard !failure.dashIsCancellation else { return }
      error = failure.dashActionableMessage
    }
    switch tablesOutcome {
    case .success(let fetched):
      tables = fetched
      tablesError = nil
      model.featureCache.set(tablesKey, fetched)
    case .failure(let failure):
      // A refresh that failed keeps the tables already on screen.
      if !failure.dashIsCancellation, tables == nil {
        tablesError = failure.dashActionableMessage
      }
    }
    loading = false
  }

  private static func fetch<Value: Sendable>(_ operation: () async throws -> Value) async
    -> Result<Value, Error>
  {
    do { return .success(try await operation()) } catch { return .failure(error) }
  }
}

private struct D1TableTray: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismissAfter) private var dismissAfter
  let table: D1Table
  let onPreview: () -> Void

  private var fields: [DashDetailField] {
    var fields = [
      DashDetailField(label: "Name", value: table.name, mono: true),
      DashDetailField(
        label: "Type",
        value: table.isView ? DashL10n.string("View") : DashL10n.string("Table")),
    ]
    if let sql = table.sql {
      fields.append(DashDetailField(label: "Schema", value: sql, mono: true))
    }
    return fields
  }

  var body: some View {
    DashDetailTray(fields: fields) {
      VStack(spacing: 10) {
        if let sql = table.sql {
          DashTrayPillButton(title: "Copy schema") {
            UIPasteboard.general.string = sql
            model.toasts.success(DashL10n.string("Schema copied"))
          }
        }
        DashActionButton(title: "Preview rows") {
          dismissAfter { onPreview() }
        }
      }
    }
  }
}

// MARK: - Query

struct D1QueryView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let databaseID: String
  let table: String?

  @State private var sql: String
  @State private var running = false
  /// Nil until a statement has answered; a failed run keeps the last answer.
  @State private var results: [D1QueryResult]?
  @State private var error: String?
  @State private var selectedRow: D1ResultRow?
  @State private var showsExamples = false
  @State private var tables: [D1Table] = []
  @State private var didAutoRun = false

  init(databaseID: String, table: String?) {
    self.databaseID = databaseID
    self.table = table
    _sql = State(initialValue: table.map { D1SQL.previewRows(table: $0) } ?? "")
  }

  private var statement: String {
    sql.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    DashFeatureList(hasContent: true) { _ in
      editorGroup
        .dashBodySlot(reduceMotion: reduceMotion)

      DashPillButton(
        title: "Run query",
        phase: running ? .loading : .idle,
        isEnabled: !statement.isEmpty
      ) {
        Task { await run() }
      }
      .accessibilityIdentifier("d1-query-run")
      .dashItemBoundary()

      if let error {
        DashNotice(kind: .error, message: error)
          .dashItemBoundary()
      }

      resultGroups
    }
    .detailHeader(icon: .solar(SolarAsset.Content.code), title: table ?? DashL10n.string("Query"))
    .task(id: model.accountRequestContext) {
      // Arriving from a table means "show me its rows": run the preview once.
      // The LIMIT keeps that to a handful of rows read.
      if table != nil, !didAutoRun {
        didAutoRun = true
        await run()
      }
      await loadTables()
    }
    .dashTray(
      item: $selectedRow,
      title: { D1ResultFormatting.title(for: $0) },
      tone: FeatureVisualIdentity.tone(for: .d1),
      content: { row in
        D1ResultRowTray(row: row)
      }
    )
    .dashTray(
      isPresented: $showsExamples,
      title: DashL10n.string("Examples"),
      tone: FeatureVisualIdentity.tone(for: .d1)
    ) {
      D1QueryExamplesTray(examples: D1QueryExample.examples(for: tables)) { example in
        sql = example.sql
      }
    }
  }

  private var editorGroup: some View {
    VStack(alignment: .leading, spacing: 0) {
      DashTwoToneListGroup(
        title: "SQL",
        actionTitle: "Examples",
        action: presentExamples
      ) {
        D1SQLEditor(text: $sql, editable: !running)
          .frame(maxWidth: .infinity)
          .frame(height: 148)
          .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
          .padding(.vertical, 12)
          .accessibilityIdentifier("d1-query-editor")
      }
      // What the code does, not what the server is trusted to do: the scope
      // Dash holds is `d1.read`.
      Text("Dash connects to D1 with read access only.")
        .d1Footnote()
    }
  }

  private func presentExamples() {
    showsExamples = true
  }

  @ViewBuilder
  private var resultGroups: some View {
    if let results {
      ForEach(Array(results.enumerated()), id: \.offset) { index, result in
        resultGroup(
          result, index: index,
          title: results.count > 1
            ? DashL10n.string("Result \(index + 1)") : DashL10n.string("Results"))
      }
    } else if running {
      // First run: hold the section's shape so the rows land in place.
      DashListGroupHeader(title: DashL10n.string("Results"))
        .dashTwoToneHeaderBand()
        .dashSectionBoundary()
      dashModeListRows(
        mode: .placeholder,
        items: [] as [D1ResultRow],
        placeholderRows: 5,
        reduceMotion: reduceMotion,
        frame: .twoTone
      ) { _ in EmptyView() }
    }
  }

  @ViewBuilder
  private func resultGroup(_ result: D1QueryResult, index: Int, title: String) -> some View {
    let rows = D1ResultFormatting.rows(for: result, resultIndex: index)

    DashListGroupHeader(title: title)
      .dashTwoToneHeaderBand()
      .dashSectionBoundary()

    if rows.isEmpty {
      Text("The statement returned no rows.")
        .dashTwoToneNote()
        .dashTwoToneRowSlice()
    } else {
      dashModeListRows(
        mode: .live,
        items: rows,
        reduceMotion: reduceMotion,
        frame: .twoTone
      ) { row in
        Button {
          selectedRow = row
        } label: {
          DashListRow(
            title: D1ResultFormatting.title(for: row),
            subtitle: D1ResultFormatting.subtitle(for: row),
            showsChevron: false
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityIdentifier("d1-result-row-\(row.id)")
      }
    }

    Text(
      result.rows.count > rows.count
        ? DashL10n.string(
          "Showing the first \(rows.count) rows. \(D1ResultFormatting.summary(for: result))")
        : D1ResultFormatting.summary(for: result)
    )
    .d1Footnote()
  }

  private func run() async {
    let statement = statement
    guard !statement.isEmpty, !running, let context = model.accountRequestContext else { return }
    running = true
    error = nil
    defer { running = false }
    do {
      let fetched = try await model.client.queryD1Database(
        accountID: context.accountID, databaseID: databaseID, sql: statement)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      results = fetched
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
    }
  }

  /// Table names for the Examples tray. Best effort: the database screen has
  /// usually cached them already, and Examples still offers "List tables"
  /// without them.
  private func loadTables() async {
    guard let context = model.accountRequestContext else { return }
    let key = FeatureCacheKey.d1Tables(accountID: context.accountID, id: databaseID)
    if let cached: [D1Table] = model.featureCache.get(key) {
      tables = cached
      return
    }
    guard
      let fetched = try? await model.client.listD1Tables(
        accountID: context.accountID, databaseID: databaseID),
      !Task.isCancelled, model.isCurrentAccount(context)
    else { return }
    tables = fetched
    model.featureCache.set(key, fetched)
  }
}

extension View {
  /// A line of supporting copy under a two-tone group, on the group title's
  /// 16pt inset so the two read as one column.
  fileprivate func d1Footnote() -> some View {
    dashTextStyle(.footnote)
      .foregroundStyle(DashTheme.subtle)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .dashItemBoundary()
  }
}

private struct D1ResultRowTray: View {
  @Environment(AppModel.self) private var model
  let row: D1ResultRow

  var body: some View {
    DashDetailTray(fields: D1ResultFormatting.detailFields(for: row)) {
      DashActionButton(title: "Copy as JSON") {
        UIPasteboard.general.string = D1ResultFormatting.json(for: row)
        model.toasts.success(DashL10n.string("Row copied"))
      }
    }
  }
}

private struct D1QueryExamplesTray: View {
  @Environment(\.dashTrayDismiss) private var dismiss
  let examples: [D1QueryExample]
  let onSelect: (D1QueryExample) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ForEach(examples) { example in
        Button {
          onSelect(example)
          dismiss()
        } label: {
          DashListRow(
            title: example.title,
            subtitle: example.sql,
            showsChevron: false
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
      }
    }
  }
}

/// The SQL input. Same editor library as the KV value editor, so selection,
/// the keyboard, and the theme behave the way they do there.
private struct D1SQLEditor: View {
  @Binding var text: String
  var editable: Bool
  @Environment(\.colorScheme) private var colorScheme

  private var theme: CodeEditor.ThemeName {
    colorScheme == .dark ? .atelierSavannaDark : .atelierSavannaLight
  }

  var body: some View {
    Group {
      if editable {
        CodeEditor(
          source: $text,
          language: .sql,
          theme: theme,
          flags: .defaultEditorFlags,
          indentStyle: .softTab(width: 2)
        )
      } else {
        CodeEditor(
          source: text,
          language: .sql,
          theme: theme,
          flags: .defaultViewerFlags
        )
      }
    }
    .background(DashTheme.recessed)
  }
}
