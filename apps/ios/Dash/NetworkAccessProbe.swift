import CoreTelephony
import Foundation

/// Probes the China-SKU “wireless data” gate and reports whether Dash can use
/// the network. There is no public request API — the system dialog appears on
/// the first network call — so this fires a lightweight HEAD and watches
/// `CTCellularData`. The probe outcome is authoritative: a response proves the
/// network path works, while `CTCellularData` reflects only per-app *cellular*
/// permission (it reads `.restricted` on working Wi‑Fi when the user picked
/// “WLAN only” or toggled cellular off for Dash), so it may only downgrade the
/// status after a probe has actually failed. Non-China devices / simulators
/// never show the dialog and are treated as allowed once the probe finishes.
@MainActor
@Observable
final class NetworkAccessProbe {
  enum Status: Equatable {
    case unknown
    case probing
    case allowed
    case restricted
  }

  private(set) var status: Status = .unknown

  private let cellularData = CTCellularData()
  /// Outcome of the most recent HEAD probe; `nil` until one completes.
  private var probeSucceeded: Bool?
  private static let probeURL = URL(string: "https://1.1.1.1")!

  init() {
    cellularData.cellularDataRestrictionDidUpdateNotifier = { [weak self] state in
      Task { @MainActor in
        self?.apply(state)
      }
    }
  }

  var isReadyForConnect: Bool { status == .allowed }

  /// Triggers the system wireless-data dialog on China SKUs (if still pending)
  /// and updates `status` from the probe outcome, falling back to cellular
  /// restriction only when the probe failed.
  func requestAccess() async {
    status = .probing

    var request = URLRequest(url: Self.probeURL)
    request.httpMethod = "HEAD"
    request.timeoutInterval = 8
    request.cachePolicy = .reloadIgnoringLocalCacheData
    do {
      _ = try await URLSession.shared.data(for: request)
      probeSucceeded = true
    } catch {
      // Permissions ↔ welcome step swaps cancel the auto-probe `.task`; leave
      // status reopenable so the next visit can try again.
      if Task.isCancelled || error is CancellationError {
        if status == .probing { status = .unknown }
        return
      }
      probeSucceeded = false
    }

    // Notifier may land slightly after the request returns.
    try? await Task.sleep(for: .milliseconds(350))
    if Task.isCancelled {
      if status == .probing { status = .unknown }
      return
    }
    resolveAfterProbe()
  }

  private func apply(_ state: CTCellularDataRestrictedState) {
    switch state {
    case .restricted:
      // Cellular-only signal: it fires .restricted on working Wi‑Fi. Trust it
      // only once a probe has failed — before any probe it would dead-end
      // onboarding, because the restricted row's only action opens Settings.
      if probeSucceeded == false {
        status = .restricted
      }
    case .notRestricted:
      status = .allowed
    case .restrictedStateUnknown:
      break
    @unknown default:
      break
    }
  }

  private func resolveAfterProbe() {
    // A response proves the network path works no matter what CTCellularData
    // says (WLAN-only choice, per-app cellular toggled off, Wi‑Fi).
    if probeSucceeded == true {
      status = .allowed
      return
    }

    switch cellularData.restrictedState {
    case .restricted:
      status = .restricted
    case .notRestricted:
      status = .allowed
    case .restrictedStateUnknown:
      // Non-China devices stay unknown forever; after an explicit probe treat
      // as allowed so Connect is not blocked outside mainland SKUs.
      if status == .probing || status == .unknown {
        status = .allowed
      }
    @unknown default:
      if status == .probing || status == .unknown {
        status = .allowed
      }
    }
  }
}
