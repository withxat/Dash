import CloudflareAPI
import SwiftUI

/// Live tail console for one Worker: starts a tail session, streams events
/// over the tail WebSocket, and deletes the session on exit. Sessions expire
/// server-side after a few minutes — the view surfaces that as `.ended` with
/// a restart button instead of auto-reconnecting.
struct WorkerTailView: View {
  enum TailStatus: Equatable {
    case connecting
    case live
    case ended
    case failed(String)
  }

  static let bufferLimit = 500

  @Environment(AppModel.self) private var model
  let name: String
  @State private var status: TailStatus = .connecting
  @State private var events: [WorkerTailEvent] = []
  @State private var paused = false
  @State private var session = 0

  /// Pure so tests can pin the trim behavior: append, keep the newest `limit`.
  static func appending(
    _ event: WorkerTailEvent, to buffer: [WorkerTailEvent], limit: Int
  ) -> [WorkerTailEvent] {
    var buffer = buffer
    buffer.append(event)
    if buffer.count > limit {
      buffer.removeFirst(buffer.count - limit)
    }
    return buffer
  }

  var body: some View {
    VStack(spacing: 0) {
      statusHeader
        .padding(.horizontal, DashTheme.Spacing.screen)
        .padding(.vertical, 10)
      ScrollViewReader { proxy in
        List(events) { event in
          eventRow(event)
            .id(event.id)
            .listRowBackground(DashTheme.canvas)
            .listRowSeparatorTint(DashTheme.line)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
          if events.isEmpty, status == .live {
            DashEmptyState(
              icon: SolarAsset.bolt,
              title: "Waiting for events",
              message: "Hit the Worker to see requests stream in."
            )
          }
        }
        .onChange(of: events.last?.id) { _, id in
          guard let id, !paused else { return }
          withAnimation(DashTheme.Motion.quick) { proxy.scrollTo(id, anchor: .bottom) }
        }
      }
    }
    .background(DashTheme.canvas)
    .navigationTitle("Live tail")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: session) { await run() }
  }

  @ViewBuilder
  private var statusHeader: some View {
    switch status {
    case .connecting:
      HStack(spacing: 10) {
        DashLoadingRing()
        Text("Starting tail for \(name)…")
          .dashTextStyle(.supportingMedium)
          .foregroundStyle(DashTheme.subtle)
        Spacer(minLength: 0)
      }
    case .live:
      HStack(spacing: 8) {
        Circle().fill(paused ? DashTheme.warning : DashTheme.success)
          .frame(width: 8, height: 8)
        Text(paused ? "Paused — new events are dropped" : "Live · \(events.count) events")
          .dashTextStyle(.supportingMedium)
          .foregroundStyle(DashTheme.subtle)
        Spacer(minLength: 0)
        Button(paused ? "Resume" : "Pause") {
          paused.toggle()
        }
        .dashTextStyle(.supportingMedium)
        .foregroundStyle(DashTheme.brand)
        .buttonStyle(DashPressButtonStyle())
      }
    case .ended:
      VStack(spacing: 10) {
        DashNotice(
          kind: .warning, message: "Tail session ended — sessions expire after a few minutes.")
        DashPillButton(title: "Restart tail") { restart() }
      }
    case .failed(let message):
      VStack(spacing: 10) {
        DashNotice(kind: .error, message: message)
        DashPillButton(title: "Try again") { restart() }
      }
    }
  }

  private func eventRow(_ event: WorkerTailEvent) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 8) {
        if let timestamp = event.timestamp {
          Text(timestamp, format: .dateTime.hour().minute().second())
            .foregroundStyle(DashTheme.placeholder)
        }
        Text(event.summary)
          .foregroundStyle(outcomeColor(event.outcome))
          .lineLimit(2)
      }
      ForEach(Array(event.lines.enumerated()), id: \.offset) { _, line in
        Text(line)
          .foregroundStyle(DashTheme.subtle)
          .lineLimit(6)
      }
    }
    .font(.system(size: 12, design: .monospaced))
    .padding(.vertical, 2)
  }

  private func outcomeColor(_ outcome: String?) -> Color {
    switch outcome {
    case "ok", nil: DashTheme.text
    case "canceled": DashTheme.warning
    default: DashTheme.danger
    }
  }

  private func restart() {
    events = []
    status = .connecting
    session += 1
  }

  private func run() async {
    guard let accountID = model.activeAccountID else {
      status = .failed("No active Cloudflare account.")
      return
    }
    status = .connecting
    let tail: WorkerTail
    do {
      tail = try await startTailCleaningUpStale(accountID: accountID)
    } catch {
      status = .failed(error.dashActionableMessage)
      return
    }
    defer {
      // The .task is cancelled on pop; detach so the DELETE still lands.
      let client = model.client
      let tailID = tail.id
      Task.detached {
        try? await client.deleteWorkerTail(
          accountID: accountID, scriptName: name, tailID: tailID)
      }
    }
    guard let url = URL(string: tail.url) else {
      status = .failed("Cloudflare returned an invalid tail URL.")
      return
    }
    status = .live
    do {
      for try await event in WorkerTailStream.events(url: url) {
        guard !paused else { continue }
        events = Self.appending(event, to: events, limit: Self.bufferLimit)
      }
      if !Task.isCancelled { status = .ended }
    } catch {
      if !Task.isCancelled { status = .ended }
    }
  }

  /// Cloudflare caps concurrent tails per script; when starting fails, sweep
  /// existing sessions once and retry.
  private func startTailCleaningUpStale(accountID: String) async throws -> WorkerTail {
    do {
      return try await model.client.startWorkerTail(accountID: accountID, scriptName: name)
    } catch {
      let stale =
        (try? await model.client.listWorkerTails(
          accountID: accountID, scriptName: name)) ?? []
      guard !stale.isEmpty else { throw error }
      for tail in stale {
        try? await model.client.deleteWorkerTail(
          accountID: accountID, scriptName: name, tailID: tail.id)
      }
      return try await model.client.startWorkerTail(accountID: accountID, scriptName: name)
    }
  }
}
