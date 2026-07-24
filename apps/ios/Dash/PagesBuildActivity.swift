import ActivityKit
import Foundation

/// Live Activity attributes for an in-progress Pages deployment. Shared with
/// the widget extension so Dynamic Island / Lock Screen UI can decode state.
/// Keep this file free of CloudflareAPI — the widget target does not link it.
struct PagesBuildAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable, Sendable {
    var stage: String
    var status: String
    var shortID: String
  }

  /// Source account for the deployment. Optional so activities created by an
  /// older app build still decode; legacy activities are ended instead of being
  /// refreshed against whichever account happens to be active now.
  var accountID: String? = nil
  var projectName: String
  var deploymentID: String
}
