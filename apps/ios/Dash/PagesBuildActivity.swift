import ActivityKit
import Foundation

/// One target-neutral interpretation of Cloudflare's Pages deployment status.
/// Both the app and widget map these cases onto their own color tokens.
enum PagesDeploymentStatusClassification: Equatable, Sendable {
  case success
  case failure
  case cancelled
  case active
  case idle
  case unknown

  static func normalized(_ rawStatus: String?) -> String? {
    guard let rawStatus else { return nil }
    let normalized = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty ? nil : normalized
  }

  /// Pure classification seam for app and widget tests.
  static func classify(_ rawStatus: String?) -> Self {
    switch normalized(rawStatus) {
    case "success": return .success
    case "failure", "failed": return .failure
    case "canceled", "cancelled", "skipped": return .cancelled
    case "active", "building", "deploying", "queued", "initializing": return .active
    case "idle": return .idle
    default: return .unknown
    }
  }

  /// Canonical catalog key for deployment-level status copy. `idle` is still
  /// in progress when it is the latest stage; per-stage rows keep their own
  /// vocabulary because later idle stages have not started.
  var catalogKey: String {
    switch self {
    case .success: "Success"
    case .failure: "Failed"
    case .cancelled: "Canceled"
    case .active, .idle: "In progress"
    case .unknown: "Unknown"
    }
  }
}

/// Live Activity attributes for an in-progress Pages deployment. Shared with
/// the widget extension so Dynamic Island / Lock Screen UI can decode state.
/// Keep this file free of CloudflareAPI — the widget target does not link it.
struct PagesBuildAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable, Sendable {
    var stage: String
    var status: String
    var shortID: String
  }

  var accountID: String
  var projectName: String
  var deploymentID: String
}
