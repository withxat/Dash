import Foundation
import Observation

/// Action verb for an in-flight optimistic (or await-then-toast) mutation.
/// Loading / success copy stays generic — no resource names.
enum DashOptimisticVerb: Equatable, Sendable {
  case enabling
  case disabling
  case setting
  case updating
  case operating

  /// Same grace as DNS deferred deletion before the network write runs.
  static let gracePeriod: Duration = .seconds(5)

  var usesGraceUndo: Bool { self == .disabling }

  /// Toggle / mount direction: on → enabling (immediate API), off → disabling
  /// (grace + Undo, then API).
  static func toggle(_ enabled: Bool) -> DashOptimisticVerb {
    enabled ? .enabling : .disabling
  }

  var loadingMessage: String {
    switch self {
    case .enabling: DashL10n.string("Enabling…")
    case .disabling: DashL10n.string("Disabling…")
    case .setting: DashL10n.string("Setting…")
    case .updating: DashL10n.string("Updating…")
    case .operating: DashL10n.string("Working…")
    }
  }

  var successMessage: String {
    switch self {
    case .enabling: DashL10n.string("Enabled successfully")
    case .disabling: DashL10n.string("Disabled successfully")
    case .setting: DashL10n.string("Set successfully")
    case .updating: DashL10n.string("Updated successfully")
    case .operating: DashL10n.string("Completed successfully")
    }
  }
}

struct DashOptimisticOperationID: Hashable, Sendable {
  let raw: UUID

  init(raw: UUID = UUID()) {
    self.raw = raw
  }
}

/// Owns toast + grace timing for optimistic mutations. Call sites keep local
/// `@State` / cache invalidation; this center only presents the persistent
/// loading → success toast and the disabling Undo window.
@MainActor
@Observable
final class DashOptimisticOperationCenter {
  private enum Stage {
    /// `begin` done; `waitForCommit` not entered yet (Undo still allowed).
    case presented
    /// Sleeping the disabling grace window.
    case grace
    /// Network write in flight — Undo no longer applies.
    case committing
  }

  private struct Operation {
    var verb: DashOptimisticVerb
    var stage: Stage
    var undo: (@MainActor () -> Void)?
    var graceTask: Task<Void, Never>?
    var commitContinuation: CheckedContinuation<Void, any Error>?
  }

  private let toasts: DashToastCenter
  private let sleeper: @Sendable (Duration) async throws -> Void
  private var operations: [UUID: Operation] = [:]

  init(
    toasts: DashToastCenter,
    sleeper: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
    self.toasts = toasts
    self.sleeper = sleeper
  }

  /// Presents the loading toast. For `disabling`, Undo stays available until
  /// `waitForCommit` resumes into the committing stage.
  @discardableResult
  func begin(
    _ verb: DashOptimisticVerb,
    undo: (@MainActor () -> Void)? = nil
  ) -> DashOptimisticOperationID {
    let id = DashOptimisticOperationID()
    operations[id.raw] = Operation(
      verb: verb,
      stage: .presented,
      undo: undo)
    presentLoading(id: id, verb: verb, showsUndo: verb.usesGraceUndo)
    return id
  }

  /// Returns immediately for non-disabling verbs. For `disabling`, suspends
  /// until the grace elapses or `undo` cancels with `CancellationError`.
  func waitForCommit(_ id: DashOptimisticOperationID) async throws {
    guard var operation = operations[id.raw] else {
      throw CancellationError()
    }
    guard operation.verb.usesGraceUndo else {
      operation.stage = .committing
      operations[id.raw] = operation
      return
    }

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      guard var current = operations[id.raw], current.stage != .committing else {
        continuation.resume(throwing: CancellationError())
        return
      }
      current.stage = .grace
      current.commitContinuation = continuation
      let sleeper = self.sleeper
      current.graceTask = Task { [weak self] in
        do {
          try await sleeper(DashOptimisticVerb.gracePeriod)
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        await MainActor.run {
          self?.completeGrace(id)
        }
      }
      operations[id.raw] = current
    }
  }

  /// Morphs the toast to success and auto-dismisses after the short dwell.
  func finishSuccess(_ id: DashOptimisticOperationID) {
    guard let operation = operations.removeValue(forKey: id.raw) else { return }
    operation.graceTask?.cancel()
    let toast = DashToast(
      id: .optimistic(id.raw),
      kind: .success,
      message: operation.verb.successMessage,
      duration: DashToast.Kind.success.duration,
      actionPhase: .succeeded,
      dismissBehavior: .automatic)
    toasts.show(toast, haptic: true, announce: true)
  }

  /// Tears down the optimistic toast without a success morph. Call sites show
  /// their own error toast / revert UI.
  func finishFailure(_ id: DashOptimisticOperationID) {
    guard let operation = operations.removeValue(forKey: id.raw) else {
      toasts.dismissOptimistic(id: id.raw)
      return
    }
    operation.graceTask?.cancel()
    if operation.stage == .grace || operation.stage == .presented {
      operation.commitContinuation?.resume(throwing: CancellationError())
    }
    toasts.dismissOptimistic(id: id.raw)
  }

  /// Cancels grace (if any), runs the undo closure, dismisses the toast.
  func undo(_ id: DashOptimisticOperationID) {
    guard let operation = operations[id.raw] else { return }
    guard operation.stage == .presented || operation.stage == .grace else { return }
    operations.removeValue(forKey: id.raw)
    operation.graceTask?.cancel()
    operation.commitContinuation?.resume(throwing: CancellationError())
    operation.undo?()
    toasts.dismissOptimistic(id: id.raw)
  }

  func undo(rawID: UUID) {
    undo(DashOptimisticOperationID(raw: rawID))
  }

  /// Convenience: begin → wait → work → success/failure.
  func perform(
    _ verb: DashOptimisticVerb,
    undo: (@MainActor () -> Void)? = nil,
    work: @escaping @MainActor () async throws -> Void
  ) async {
    let id = begin(verb, undo: undo)
    do {
      try await waitForCommit(id)
    } catch {
      return
    }
    do {
      try await work()
      finishSuccess(id)
    } catch {
      finishFailure(id)
      toasts.error(error.dashActionableMessage)
    }
  }

  private func presentLoading(
    id: DashOptimisticOperationID,
    verb: DashOptimisticVerb,
    showsUndo: Bool
  ) {
    toasts.show(
      DashToast(
        id: .optimistic(id.raw),
        kind: .success,
        message: verb.loadingMessage,
        action: showsUndo ? .undoOptimistic(id.raw) : nil,
        actionTitle: showsUndo ? DashL10n.string("Undo") : nil,
        actionAccessibilityLabel: showsUndo ? DashL10n.string("Undo") : nil,
        actionPhase: .loading,
        dismissBehavior: .programmaticOnly),
      haptic: false,
      announce: true)
  }

  private func completeGrace(_ id: DashOptimisticOperationID) {
    guard var operation = operations[id.raw], operation.stage == .grace else { return }
    let continuation = operation.commitContinuation
    operation.commitContinuation = nil
    operation.graceTask = nil
    operation.stage = .committing
    operations[id.raw] = operation
    // Drop Undo once the network write starts.
    presentLoading(id: id, verb: operation.verb, showsUndo: false)
    continuation?.resume(returning: ())
  }
}
