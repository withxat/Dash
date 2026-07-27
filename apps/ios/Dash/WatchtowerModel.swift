import CloudflareAPI
import Foundation
import OSLog

enum WatchtowerAlertsStatus: Sendable {
  case loading
  case ok
  case unavailable
  case error
}

/// Watchtower's account load: Cloudflare's own notification deliveries, and
/// nothing else.
///
/// Dash used to fold zones, tunnels, pools, registrar, Pages, certificates and
/// Health Checks into a client-side health verdict. Cloudflare publishes no
/// account-wide diagnostics to base that on, so the severity was Dash's
/// invention — a pool the user disabled on purpose, or a certificate 20 days
/// from an automatic renewal, became warnings Cloudflare never raised. The
/// account's own notification policies are the official channel for "something
/// is wrong", so that is the only thing this loads.
enum WatchtowerAlertsLoader {
  typealias LoadResult = (
    alerts: [NotificationHistoryEntry],
    alertsStatus: WatchtowerAlertsStatus
  )

  static func loadCancellable(client: CloudflareClient, accountID: String) async throws
    -> LoadResult
  {
    let signpostID = DashPerformance.signposter.makeSignpostID()
    let interval = DashPerformance.signposter.beginInterval(
      "WatchtowerRefresh", id: signpostID)
    defer {
      DashPerformance.signposter.endInterval("WatchtowerRefresh", interval)
    }

    do {
      let alerts = try await client.listNotificationHistory(accountID: accountID)
      try Task.checkCancellation()
      return (alerts, .ok)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      if Task.isCancelled { throw CancellationError() }
      let denied = (error as? CloudflareAPIError)?.isPermissionDenied == true
      return ([], denied ? .unavailable : .error)
    }
  }
}
