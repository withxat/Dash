import ActivityKit
import Foundation

/// Live Activity attributes for an in-progress Workers Build. Shared with the
/// widget extension, so keep this file free of CloudflareAPI — the widget target
/// does not link it.
///
/// Separate from `PagesBuildAttributes` rather than a shared generic type: a
/// Pages deploy and a Worker build are genuinely two different things and can
/// legitimately run at once, and merging them would have changed the attributes
/// type of every activity already on a Lock Screen.
struct WorkerBuildAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable, Sendable {
    /// Localized lifecycle label ("Building…"), not a raw Cloudflare status —
    /// the widget bundle resolves its own catalog and cannot re-map one.
    var phase: String
    /// `queued` / `initializing` / `running` / `finished`. The widget switches
    /// on this for colour, so it stays machine-readable.
    var phaseToken: String
    var branch: String?
    var shortCommit: String?
    /// Set only once Cloudflare reports one; nil while the build is in flight.
    var outcome: String?
  }

  var accountID: String?
  var scriptName: String
  var scriptTag: String
  var buildID: String
}
