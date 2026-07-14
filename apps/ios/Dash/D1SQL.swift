import Foundation

/// Classifies D1 console statements so destructive SQL gets a confirm step
/// before it runs against a production database.
enum D1SQL {
  static let destructiveKeywords: Set<String> = [
    "DROP", "DELETE", "UPDATE", "ALTER", "TRUNCATE", "REPLACE",
  ]

  /// The destructive keyword the SQL would execute, or nil when every
  /// statement is read-safe. Comments are stripped, statements split on `;`,
  /// and each judged by its leading keyword. CTE (`WITH`) and `INSERT`
  /// statements get a whole-statement word scan instead — a CTE can front a
  /// DELETE and an upsert can rewrite rows — trading rare extra confirms for
  /// zero missed writes. Plain INSERT stays unconfirmed: it only adds rows.
  static func destructiveKeyword(in sql: String) -> String? {
    let cleaned = strippingComments(from: sql)
    for statement in cleaned.split(separator: ";") {
      let words = statement.uppercased()
        .components(separatedBy: Self.identifierCharacters.inverted)
        .filter { !$0.isEmpty }
      guard let first = words.first else { continue }
      if destructiveKeywords.contains(first) { return first }
      if first == "WITH" || first == "INSERT",
        let keyword = words.dropFirst().first(where: destructiveKeywords.contains)
      {
        return keyword
      }
    }
    return nil
  }

  /// Underscore included so `legacy_update` stays one token instead of
  /// producing a false UPDATE match.
  private static let identifierCharacters = CharacterSet.alphanumerics
    .union(CharacterSet(charactersIn: "_"))

  private static func strippingComments(from sql: String) -> String {
    var result = ""
    var index = sql.startIndex
    var inLineComment = false
    var inBlockComment = false
    while index < sql.endIndex {
      let character = sql[index]
      let nextIndex = sql.index(after: index)
      let next = nextIndex < sql.endIndex ? sql[nextIndex] : nil
      if inLineComment {
        if character == "\n" {
          inLineComment = false
          result.append(character)
        }
      } else if inBlockComment {
        if character == "*", next == "/" {
          inBlockComment = false
          index = nextIndex
        }
      } else if character == "-", next == "-" {
        inLineComment = true
        index = nextIndex
      } else if character == "/", next == "*" {
        inBlockComment = true
        index = nextIndex
      } else {
        result.append(character)
      }
      index = sql.index(after: index)
    }
    return result
  }
}
