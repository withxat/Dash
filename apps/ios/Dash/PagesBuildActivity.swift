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

  var projectName: String
  var deploymentID: String
}
