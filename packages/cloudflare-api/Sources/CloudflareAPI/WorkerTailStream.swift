import Foundation

/// One parsed tail message — a request, cron, or queue invocation with its
/// console output and exceptions flattened into display lines.
public struct WorkerTailEvent: Hashable, Sendable, Identifiable {
  public let id: UUID
  public let timestamp: Date?
  public let outcome: String?
  public let summary: String
  public let lines: [String]

  public init(
    id: UUID = UUID(), timestamp: Date?, outcome: String?, summary: String, lines: [String]
  ) {
    self.id = id
    self.timestamp = timestamp
    self.outcome = outcome
    self.summary = summary
    self.lines = lines
  }
}

/// Lenient decoder for tail WebSocket payloads. The tail schema is loosely
/// versioned ({outcome, logs, exceptions, eventTimestamp, event.…}, all
/// optional), so every field is best-effort and only non-JSON input fails.
public enum WorkerTailMessage {
  public static func parse(_ data: Data) -> WorkerTailEvent? {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .object(let root) = value
    else { return nil }

    let outcome = root["outcome"].flatMap(string)

    var timestamp: Date?
    if let millis = root["eventTimestamp"].flatMap(number) {
      timestamp = Date(timeIntervalSince1970: millis / 1000)
    }

    var lines: [String] = []
    if case .array(let logs)? = root["logs"] {
      for log in logs {
        guard case .object(let entry) = log else { continue }
        let level = entry["level"].flatMap(string) ?? "log"
        let message: String
        switch entry["message"] {
        case .array(let parts)?:
          message = parts.map(display).joined(separator: " ")
        case let single?:
          message = display(single)
        case nil:
          message = ""
        }
        lines.append("[\(level)] \(message)")
      }
    }
    if case .array(let exceptions)? = root["exceptions"] {
      for exception in exceptions {
        guard case .object(let entry) = exception else { continue }
        let name = entry["name"].flatMap(string) ?? "Exception"
        let message = entry["message"].flatMap(string) ?? ""
        lines.append("[exception] \(name): \(message)")
      }
    }

    return WorkerTailEvent(
      timestamp: timestamp,
      outcome: outcome,
      summary: summary(root: root, outcome: outcome),
      lines: lines)
  }

  private static func summary(root: [String: JSONValue], outcome: String?) -> String {
    if case .object(let event)? = root["event"] {
      if case .object(let request)? = event["request"] {
        let method = request["method"].flatMap(string) ?? "?"
        let url = request["url"].flatMap(string) ?? "?"
        return outcome.map { "\(method) \(url) — \($0)" } ?? "\(method) \(url)"
      }
      if let cron = event["cron"].flatMap(string) {
        return outcome.map { "cron \(cron) — \($0)" } ?? "cron \(cron)"
      }
      if case .object(let queue)? = event["queue"] {
        let name = queue["queue"].flatMap(string) ?? "queue"
        return outcome.map { "queue \(name) — \($0)" } ?? "queue \(name)"
      }
    }
    return outcome ?? "event"
  }

  private static func string(_ value: JSONValue) -> String? {
    if case .string(let text) = value { return text }
    return nil
  }

  private static func number(_ value: JSONValue) -> Double? {
    if case .number(let number) = value { return number }
    return nil
  }

  /// Compact human form of an arbitrary log argument: strings stay bare,
  /// everything else round-trips through the JSON encoder.
  private static func display(_ value: JSONValue) -> String {
    switch value {
    case .string(let text): return text
    case .number(let number):
      return number.truncatingRemainder(dividingBy: 1) == 0
        ? String(Int(number)) : String(number)
    case .bool(let flag): return String(flag)
    case .null: return "null"
    default:
      guard let data = try? JSONEncoder().encode(value) else { return "…" }
      return String(decoding: data, as: UTF8.self)
    }
  }
}

/// Thin async wrapper over the tail WebSocket. The wss URL carries its own
/// auth token; Cloudflare refuses the connection without the `trace-v1`
/// subprotocol. A normal close ends the stream; transport errors throw.
public enum WorkerTailStream {
  public static func events(
    url: URL, session: URLSession = .shared
  ) -> AsyncThrowingStream<WorkerTailEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = session.webSocketTask(with: url, protocols: ["trace-v1"])
      let box = TaskBox(task: task)
      task.resume()
      let receiveLoop = Task {
        do {
          while true {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let payload): data = payload
            @unknown default: continue
            }
            if let event = WorkerTailMessage.parse(data) {
              continuation.yield(event)
            }
          }
        } catch {
          if task.closeCode == .normalClosure || task.closeCode == .goingAway {
            continuation.finish()
          } else {
            continuation.finish(throwing: error)
          }
        }
      }
      continuation.onTermination = { _ in
        receiveLoop.cancel()
        box.cancel()
      }
    }
  }
}

/// URLSessionWebSocketTask is thread-safe but not Sendable-annotated; the box
/// exists so the stream's termination handler can cancel it.
private final class TaskBox: @unchecked Sendable {
  private let task: URLSessionWebSocketTask
  init(task: URLSessionWebSocketTask) { self.task = task }
  func cancel() { task.cancel(with: .normalClosure, reason: nil) }
}
