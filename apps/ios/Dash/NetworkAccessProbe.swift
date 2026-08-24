import CloudflareAPI
import CoreTelephony
import Foundation

/// Probes the China-SKU “wireless data” gate and reports whether Dash can use
/// the network. There is no public request API — the system dialog appears on
/// the first network call — so this fires a lightweight HEAD and watches
/// `CTCellularData`. The probe outcome is authoritative: a response proves the
/// network path works, while `CTCellularData` reflects only per-app *cellular*
/// permission (it reads `.restricted` on working Wi‑Fi when the user picked
/// “WLAN only” or toggled cellular off for Dash). A failed request therefore
/// retries while the system prompt is open and only uses the cellular policy
/// to classify the final failure; policy state alone never claims reachability.
@MainActor
@Observable
final class NetworkAccessProbe {
  enum Status: Equatable {
    case unknown
    case probing
    case allowed
    case restricted
    case unavailable
  }

  private(set) var status: Status = .unknown

  private let cellularData = CTCellularData()
  /// Outcome of the most recent HEAD probe; `nil` until one completes.
  private var probeSucceeded: Bool?
  /// Probe the same origin that the next step opens; a generic reachability
  /// host can be blocked by VPN or enterprise policy while OAuth still works.
  private static let probeURL = CloudflareEndpoints.authorization

  init() {
    cellularData.cellularDataRestrictionDidUpdateNotifier = { [weak self] state in
      Task { @MainActor in
        self?.apply(state)
      }
    }
  }

  var isReadyForConnect: Bool { status == .allowed }

  /// Triggers the system wireless-data dialog on China SKUs (if still pending)
  /// and retries while the person responds. OAuth may start only after one
  /// request actually reaches the network.
  func requestAccess() async {
    status = .probing
    probeSucceeded = nil
    let deadline = ContinuousClock.now.advanced(
      by: NetworkAccessProbeRetryRules.authorizationWindow
    )
    var failedAttempts = 0

    while ContinuousClock.now < deadline {
      if Task.isCancelled {
        cancelProbe()
        return
      }

      let remaining = ContinuousClock.now.duration(to: deadline)
      var request = URLRequest(url: Self.probeURL)
      request.httpMethod = "HEAD"
      request.timeoutInterval = NetworkAccessProbeRetryRules.requestTimeout(
        remaining: remaining
      )
      request.cachePolicy = .reloadIgnoringLocalCacheData
      do {
        _ = try await URLSession.shared.data(for: request)
        probeSucceeded = true
        status = .allowed
        return
      } catch {
        // Leaving onboarding cancels its user-triggered preparation task;
        // leave status reopenable so the next visit can try again.
        if Task.isCancelled || error is CancellationError {
          cancelProbe()
          return
        }
        probeSucceeded = false
        failedAttempts += 1
      }

      let delay = NetworkAccessProbeRetryRules.retryDelay(
        afterFailure: failedAttempts,
        remaining: ContinuousClock.now.duration(to: deadline)
      )
      guard delay > .zero else { break }
      do {
        try await Task.sleep(for: delay)
      } catch {
        cancelProbe()
        return
      }
    }

    do {
      // The CoreTelephony notifier can trail the failed URLSession callback;
      // give a denial one final beat to become observable before classifying.
      try await Task.sleep(for: NetworkAccessProbeRetryRules.policySettleDelay)
    } catch {
      cancelProbe()
      return
    }
    status = NetworkAccessProbeRetryRules.terminalStatus(
      probeSucceeded: probeSucceeded == true,
      cellularRestricted: cellularData.restrictedState == .restricted
    )
  }

  private func apply(_ state: CTCellularDataRestrictedState) {
    switch state {
    case .restricted:
      // Cellular-only signal: it fires .restricted on working Wi‑Fi. Trust it
      // only after the complete retry window failed. During probing, a later
      // Wi-Fi response still wins even if cellular access is unavailable.
      if probeSucceeded == false, status != .probing {
        status = .restricted
      }
    case .notRestricted:
      // Cellular policy is not proof of Internet reachability. Clear a stale
      // Settings-only state, then let the next real probe establish access.
      if status == .restricted { status = .unknown }
    case .restrictedStateUnknown:
      break
    @unknown default:
      break
    }
  }

  private func cancelProbe() {
    probeSucceeded = nil
    if status == .probing { status = .unknown }
  }
}

enum NetworkAccessProbeRetryRules {
  /// Wall-clock deadline: fast-failing requests must not shorten the time a
  /// person has to read and answer the China-SKU system prompt.
  static let authorizationWindow: Duration = .seconds(25)
  static let maximumRequestTimeout: TimeInterval = 2
  static let retryInterval: Duration = .milliseconds(600)
  static let maximumRetryInterval: Duration = .seconds(4)
  static let policySettleDelay: Duration = .milliseconds(350)

  static func requestTimeout(remaining: Duration) -> TimeInterval {
    min(maximumRequestTimeout, max(0.1, remaining.timeInterval))
  }

  static func retryDelay(afterFailure attempt: Int, remaining: Duration) -> Duration {
    let backoff: Duration =
      switch max(attempt, 1) {
      case 1: retryInterval
      case 2: .milliseconds(1_200)
      case 3: .milliseconds(2_400)
      default: maximumRetryInterval
      }
    return min(backoff, max(.zero, remaining))
  }

  static func terminalStatus(
    probeSucceeded: Bool,
    cellularRestricted: Bool
  ) -> NetworkAccessProbe.Status {
    if probeSucceeded { return .allowed }
    return cellularRestricted ? .restricted : .unavailable
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let parts = components
    return TimeInterval(parts.seconds)
      + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
  }
}
