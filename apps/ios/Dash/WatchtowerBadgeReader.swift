import Foundation

/// Reads just the unread count out of the shared Watchtower snapshot.
///
/// The Notification Service Extension needs a badge number and nothing else.
/// Decoding the full `WatchtowerWidgetSnapshot` would pull its freshness rules,
/// alert models, and headline copy into an extension that has a 30-second
/// budget and no use for any of it — so this decodes one key from the same file
/// the widget reads, and treats every failure as "no badge".
///
/// Deliberately a *reader*: the count is owned by the app, which recomputes it
/// from Cloudflare's deliveries minus local ignores. An extension that
/// incremented a counter of its own would drift the moment a delivery arrived
/// while the app was open, or an alert was ignored on another screen.
enum WatchtowerBadgeReader {
  static let appGroupID = "group.sh.xat.dash.app"
  static let fileName = "watchtower-widget-snapshot.json"

  private struct UnreadOnly: Decodable {
    let unreadCount: Int?
  }

  static var containerFileURL: URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
      .appendingPathComponent(fileName)
  }

  /// The badge to show, or nil to leave whatever the payload asked for. Returns
  /// 0 as a real value — that is how a badge gets cleared.
  static func unreadCount() -> Int? {
    guard
      let url = containerFileURL,
      let data = try? Data(contentsOf: url),
      let snapshot = try? JSONDecoder().decode(UnreadOnly.self, from: data),
      let count = snapshot.unreadCount
    else {
      return nil
    }
    return max(0, count)
  }
}
