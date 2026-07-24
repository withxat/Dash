import Foundation

/// Pretty-print / validate helpers for KV values shown in `CodeEditor`.
/// CodeEditor highlights text; indentation comes from Foundation before display.
enum KVJSONFormatting {
  /// Skip automatic pretty-print above this size to keep the tray responsive.
  static let prettyPrintByteLimit = 256 * 1024

  static func isValidJSON(_ text: String) -> Bool {
    guard let data = text.data(using: .utf8) else { return false }
    return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
  }

  /// Returns pretty-printed JSON when `text` parses; otherwise `nil`.
  static func prettyPrinted(_ text: String) -> String? {
    guard let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
      let pretty = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .fragmentsAllowed]),
      let string = String(data: pretty, encoding: .utf8)
    else { return nil }
    return string
  }

  /// Pretty-print when valid JSON and under the size limit; otherwise leave as-is.
  static func preparedForDisplay(_ text: String) -> String {
    guard text.utf8.count <= prettyPrintByteLimit else { return text }
    return prettyPrinted(text) ?? text
  }
}
