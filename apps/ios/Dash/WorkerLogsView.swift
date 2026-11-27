import CloudflareAPI
import SwiftUI
import UIKit

/// The Worker Logs screen's one request is the telemetry query
/// (`POST …/workers/observability/telemetry/query`). Cloudflare accepts
/// Workers Observability **Write** for it and nothing else — it is the same
/// endpoint that runs saved queries — so reading logs needs a `.write` scope
/// and `workers-observability.read` unlocks nothing Dash calls. Kept off the
/// Workers capability so a grant that predates it still opens
/// `WorkerDetailView`; the Logs screen asks for it on its own.
enum WorkerLogsAccess {
  static let query: Set<String> = ["workers-observability.write"]
}

enum WorkerLogsTimeWindow: Int, CaseIterable, Hashable, Sendable {
  case minutes15 = 15
  case hour1 = 60
  case hours6 = 360
  case hours24 = 1440

  var title: String {
    switch self {
    case .minutes15: "15m"
    case .hour1: "1h"
    case .hours6: "6h"
    case .hours24: "24h"
    }
  }
}

/// Pure formatting for invocation rows, the detail tray, and the copied log,
/// tested independently of SwiftUI.
enum WorkerLogsFormatting {
  static func rowTitle(for record: WorkerInvocationRecord) -> String {
    let path = requestPath(from: record.url)
    if let method = record.method, let path {
      return "\(method) \(path)"
    }
    if let trigger = record.trigger?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trigger.isEmpty
    {
      return trigger
    }
    return path ?? record.id
  }

  static func requestPath(from rawURL: String?) -> String? {
    guard let rawURL = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines), !rawURL.isEmpty
    else { return nil }
    guard let components = URLComponents(string: rawURL) else { return rawURL }
    let path = components.path.isEmpty ? "/" : components.path
    if let query = components.percentEncodedQuery, !query.isEmpty {
      return "\(path)?\(query)"
    }
    return path
  }

  static func durationLabel(_ durationMs: Double?) -> String? {
    guard let durationMs, durationMs.isFinite, durationMs >= 0 else { return nil }
    if durationMs < 10 { return String(format: "%.1f ms", durationMs) }
    if durationMs < 1000 { return "\(Int(durationMs.rounded())) ms" }
    return String(format: "%.2f s", durationMs / 1000)
  }

  /// "500 · exception". An `ok` outcome adds nothing to a status code.
  static func statusSummary(for record: WorkerInvocationRecord) -> String? {
    let outcome = record.outcome.flatMap { $0.isEmpty ? nil : $0 }
    guard let code = record.statusCode else { return outcome }
    guard let outcome, outcome.lowercased() != "ok" else { return "\(code)" }
    return "\(code) · \(outcome)"
  }

  static func date(_ timestampMs: Int64) -> Date? {
    timestampMs > 0 ? Date(timeIntervalSince1970: Double(timestampMs) / 1000) : nil
  }

  /// One console line per row: local wall-clock time, level, message.
  static func consoleOutput(for record: WorkerInvocationRecord) -> String? {
    guard !record.consoleLogs.isEmpty else { return nil }
    return record.consoleLogs.map { entry in
      let time = date(entry.timestampMs).map { DashDateFormatting.timeWithSeconds($0) } ?? "—"
      return "\(time)  \(entry.level.uppercased())  \(entry.message)"
    }
    .joined(separator: "\n")
  }

  static func detailFields(for record: WorkerInvocationRecord) -> [DashDetailField] {
    var fields: [DashDetailField] = []
    if let error = record.errorMessage {
      fields.append(DashDetailField(label: "Error", value: error, mono: true))
    }
    if let method = record.method {
      fields.append(DashDetailField(label: "Method", value: method, mono: true))
    }
    if let url = record.url {
      fields.append(DashDetailField(label: "URL", value: url, mono: true))
    } else if let trigger = record.trigger {
      fields.append(DashDetailField(label: "Trigger", value: trigger, mono: true))
    }
    if let status = statusSummary(for: record) {
      fields.append(DashDetailField(label: "Status", value: status))
    }
    if let date = date(record.timestampMs) {
      fields.append(DashDetailField(label: "Time", value: DashDateFormatting.dateAndTime(date)))
    }
    if let duration = durationLabel(record.durationMs) {
      fields.append(DashDetailField(label: "Duration", value: duration))
    }
    if let cpu = durationLabel(record.cpuTimeMs) {
      fields.append(DashDetailField(label: "CPU Time", value: cpu))
    }
    if let rayID = record.rayID {
      fields.append(DashDetailField(label: "Ray ID", value: rayID, mono: true))
    }
    if let console = consoleOutput(for: record) {
      fields.append(DashDetailField(label: "Console output", value: console, mono: true))
    }
    return fields
  }

  /// Plain text for the pasteboard. Timestamps are UTC ISO 8601, not the local
  /// clock the tray shows: a pasted log is read next to other systems' logs.
  static func copyableLog(for record: WorkerInvocationRecord) -> String {
    var lines = [rowTitle(for: record)]
    if let url = record.url { lines.append("URL: \(url)") }
    if let status = statusSummary(for: record) { lines.append("Status: \(status)") }
    if let date = date(record.timestampMs) {
      lines.append("Time: \(date.formatted(.iso8601))")
    }
    if let duration = durationLabel(record.durationMs) { lines.append("Duration: \(duration)") }
    if let cpu = durationLabel(record.cpuTimeMs) { lines.append("CPU: \(cpu)") }
    if let ray = record.rayID { lines.append("Ray ID: \(ray)") }
    if let error = record.errorMessage { lines.append("Error: \(error)") }
    if !record.consoleLogs.isEmpty {
      lines.append("")
      for entry in record.consoleLogs {
        let time = date(entry.timestampMs)?.formatted(.iso8601) ?? "—"
        lines.append("[\(time)] [\(entry.level.uppercased())] \(entry.message)")
      }
    }
    return lines.joined(separator: "\n")
  }
}

/// Recent invocations of one Worker with their console output, from Workers
/// Observability. Read-only, and never cached: a log window is "the last hour
/// as of now", so a copy kept for a relaunch would repaint an old hour under a
/// current title — and console output is not something to leave on disk.
struct WorkerLogsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let name: String

  @State private var window: WorkerLogsTimeWindow = .hour1
  @State private var errorsOnly = false
  /// Nil until the current query answers; a window's rows never sit under
  /// another window's tab.
  @State private var records: [WorkerInvocationRecord]?
  @State private var loading = true
  @State private var hasPresentedContent = false
  @State private var error: String?
  @State private var selected: WorkerInvocationRecord?
  /// The query `records` answers.
  @State private var loadedQuery: Query?

  private struct Query: Hashable {
    let context: AccountRequestContext?
    let canQuery: Bool
    let window: WorkerLogsTimeWindow
    let errorsOnly: Bool
  }

  private var canQuery: Bool { model.hasScopes(WorkerLogsAccess.query) }

  private var query: Query {
    Query(
      context: model.accountRequestContext, canQuery: canQuery, window: window,
      errorsOnly: errorsOnly)
  }

  /// A failure with no rows on screen for this query. Cold, `DashFeatureList`
  /// veils the skeleton with it; after the first answer it is the group's one
  /// slice, because the list above it is this screen's only content.
  private var sectionError: String? {
    hasPresentedContent && records == nil ? error : nil
  }

  var body: some View {
    DashFeatureList(
      isLoading: canQuery && loading,
      error: sectionError == nil ? error : nil,
      hasContent: !canQuery || hasPresentedContent,
      retry: { Task { await load() } },
      header: {
        if canQuery {
          DashTextTabs(
            items: WorkerLogsTimeWindow.allCases.map { ($0.title, $0) },
            selection: $window
          )
          .accessibilityIdentifier("worker-logs-window")
        }
      },
      content: { mode in
        if canQuery {
          invocations(mode: mode)
        } else {
          FeatureWriteAccessNotice(
            message: "Grant Workers Observability access to query invocation and console logs.",
            scopes: WorkerLogsAccess.query
          )
          .dashBodySlot(reduceMotion: reduceMotion)
        }
      }
    )
    .detailHeader(
      icon: .solar(SolarAsset.Content.file),
      title: "Logs",
      tint: FeatureVisualIdentity.heroColor(for: .workers)
    )
    .refreshable { await load() }
    .task(id: query) { await load() }
    .dashTray(
      item: $selected,
      title: { WorkerLogsFormatting.rowTitle(for: $0) },
      tone: FeatureVisualIdentity.tone(for: .workers),
      content: { record in
        WorkerInvocationTray(record: record)
      }
    )
  }

  @ViewBuilder
  private func invocations(mode: DashBodyMode) -> some View {
    let sectionMode: DashBodyMode =
      mode.isPlaceholder || (records == nil && loading) ? .placeholder : .live
    let rows = records ?? []

    DashListGroupHeader(
      title: errorsOnly ? DashL10n.ui("Errors") : DashL10n.ui("Recent invocations"),
      actionTitle: errorsOnly ? DashL10n.ui("Show all") : DashL10n.ui("Errors only"),
      action: { errorsOnly.toggle() }
    )
    .dashTwoToneHeaderBand()
    .dashBodySlot(reduceMotion: reduceMotion)

    if sectionMode.isPlaceholder || !rows.isEmpty {
      dashModeListRows(
        mode: sectionMode,
        items: rows,
        placeholderRows: 5,
        reduceMotion: reduceMotion,
        frame: .twoTone
      ) { record in
        Button {
          selected = record
        } label: {
          DashListRow(
            title: WorkerLogsFormatting.rowTitle(for: record),
            subtitle: rowSubtitle(for: record),
            icon: record.isError ? SolarAsset.Content.danger : SolarAsset.Content.bolt,
            iconColor: record.isError ? DashTheme.danger : nil,
            trailing: record.statusCode.map { "\($0)" },
            showsChevron: false
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityIdentifier("worker-log-\(record.id)")
      }
    } else if let sectionError {
      DashNotice(kind: .error, message: sectionError)
        .dashTwoToneRowSlice()
        .dashBodySlot(reduceMotion: reduceMotion)
    } else {
      Text(
        errorsOnly
          ? DashL10n.string("No error invocations in this time window.")
          : DashL10n.string("No invocations recorded in this time window.")
      )
      .dashTwoToneNote()
      .dashTwoToneRowSlice()
      .dashBodySlot(reduceMotion: reduceMotion)
    }
  }

  private func rowSubtitle(for record: WorkerInvocationRecord) -> String? {
    var parts: [String] = []
    if let date = WorkerLogsFormatting.date(record.timestampMs) {
      parts.append(DashDateFormatting.abbreviatedRelativeTime(date))
    }
    if let duration = WorkerLogsFormatting.durationLabel(record.durationMs) {
      parts.append(duration)
    }
    let logCount = record.consoleLogs.count
    if logCount == 1 {
      parts.append(DashL10n.string("1 log"))
    } else if logCount > 1 {
      parts.append(DashL10n.string("\(logCount) logs"))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// Runs for `.task(id: query)` (a changed tab, filter, account, or grant) and
  /// for pull-to-refresh and Retry. Rows are dropped only when they belong to a
  /// different query; a refresh of the same one keeps them on screen.
  private func load() async {
    let query = self.query
    guard query.canQuery, let context = query.context else {
      loading = false
      return
    }
    if loadedQuery != query { records = nil }
    if records == nil { loading = true }
    error = nil
    do {
      let fetched = try await model.client.queryWorkerObservabilityLogs(
        accountID: context.accountID,
        scriptName: name,
        windowMinutes: query.window.rawValue,
        errorsOnly: query.errorsOnly)
      guard !Task.isCancelled, query == self.query, model.isCurrentAccount(context) else { return }
      records = fetched
      loadedQuery = query
      hasPresentedContent = true
      loading = false
    } catch {
      guard !error.dashIsCancellation, query == self.query, model.isCurrentAccount(context)
      else { return }
      self.error = error.dashActionableMessage
      loading = false
    }
  }
}

private struct WorkerInvocationTray: View {
  @Environment(AppModel.self) private var model
  let record: WorkerInvocationRecord

  var body: some View {
    DashDetailTray(fields: WorkerLogsFormatting.detailFields(for: record)) {
      DashActionButton(title: "Copy log") {
        UIPasteboard.general.string = WorkerLogsFormatting.copyableLog(for: record)
        DashDelight.lightImpact()
        model.toasts.success(DashL10n.string("Log copied"))
      }
    }
  }
}
