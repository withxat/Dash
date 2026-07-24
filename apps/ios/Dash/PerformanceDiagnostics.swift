import Foundation
import MetricKit
import OSLog

/// Shared performance instrumentation. Keep interval names stable so they can
/// be compared across Instruments runs and MetricKit regressions.
enum DashPerformance {
  static let signposter = OSSignposter(
    subsystem: Bundle.main.bundleIdentifier ?? "sh.xat.dash.app",
    category: "Performance")
}

/// Registers once per process and receives Apple's aggregated launch, hang,
/// memory, CPU, disk, and diagnostic payloads. Payload contents stay on-device;
/// only receipt counts are written to the unified log.
final class DashMetricSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
  static let shared = DashMetricSubscriber()

  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "sh.xat.dash.app",
    category: "MetricKit")
  private let lock = NSLock()
  private var isStarted = false

  private override init() {
    super.init()
  }

  func start() {
    lock.lock()
    defer { lock.unlock() }
    guard !isStarted else { return }
    isStarted = true
    MXMetricManager.shared.add(self)
  }

  func didReceive(_ payloads: [MXMetricPayload]) {
    logger.info("Received \(payloads.count, privacy: .public) MetricKit metric payload(s)")
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    logger.info("Received \(payloads.count, privacy: .public) MetricKit diagnostic payload(s)")
  }
}
