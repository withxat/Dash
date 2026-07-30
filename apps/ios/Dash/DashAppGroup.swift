import Foundation

/// Cross-process identifiers shared by the app and its extensions. Keep this
/// file Foundation-only and compile it into every target that reads App Group
/// defaults so account-scoped links cannot drift onto a different key.
enum DashAppGroup {
  static let id = "group.sh.xat.dash.app"
  static let activeAccountKey = "dash.active_account_id"
}
