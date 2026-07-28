import Foundation

/// Cloudflare's service-side write ceiling, independent of Dash's smaller
/// boundary for loading an existing value into the editor.
enum KVValueLimits {
  static let writeByteLimit = 25 * 1024 * 1024

  static func isWithinWriteLimit(_ text: String) -> Bool {
    isWithinWriteLimit(byteCount: text.utf8.count)
  }

  static func isWithinWriteLimit(byteCount: Int) -> Bool {
    byteCount <= writeByteLimit
  }
}

/// Pretty-print / validate helpers for KV values shown in `CodeEditor`.
/// CodeEditor highlights text; indentation comes from Foundation before display.
enum KVJSONFormatting {
  enum DisplayValue: Equatable, Sendable {
    case text(String)
    case tooLarge
    case nonText
  }

  /// TextKit 1 lays out a `CodeEditor` value on the main thread. Bound values
  /// loaded from Cloudflare, JSON formatting, and post-save remounting. A value
  /// entered by the user can still be submitted up to the service write limit.
  static let displayByteLimit = 256 * 1024

  static func isWithinDisplayLimit(_ text: String) -> Bool {
    isWithinDisplayLimit(byteCount: text.utf8.count)
  }

  static func isWithinDisplayLimit(byteCount: Int) -> Bool {
    byteCount <= displayByteLimit
  }

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

  /// Formatting can expand compact JSON several times over. Both the source
  /// and the result must fit before the formatted copy can be mounted into the
  /// main-thread TextKit editor.
  static func prettyPrintedForDisplay(_ text: String) -> String? {
    guard isWithinDisplayLimit(text),
      let pretty = prettyPrinted(text),
      isWithinDisplayLimit(pretty)
    else { return nil }
    return pretty
  }

  /// Pretty-print when valid JSON and under the size limit; otherwise leave as-is.
  static func preparedForDisplay(_ text: String) -> String {
    guard isWithinDisplayLimit(text) else { return text }
    return prettyPrintedForDisplay(text) ?? text
  }

  static func displayValue(for data: Data) -> DisplayValue {
    guard data.count <= displayByteLimit else { return .tooLarge }
    guard let text = String(data: data, encoding: .utf8) else { return .nonText }
    return .text(preparedForDisplay(text))
  }
}
