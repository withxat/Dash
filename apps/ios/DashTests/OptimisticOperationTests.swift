import Foundation
import Testing

@testable import Dash

@Suite(.serialized)
struct OptimisticOperationTests {
  @Test @MainActor
  func enablingFinishesWithoutGrace() async {
    let toasts = DashToastCenter()
    let sleeper = OptimisticManualSleeper()
    let center = DashOptimisticOperationCenter(
      toasts: toasts,
      sleeper: { _ in try await sleeper.sleep() })

    let op = center.begin(.enabling)
    #expect(toasts.current?.id == .optimistic(op.raw))
    #expect(toasts.current?.actionPhase == .loading)
    #expect(toasts.current?.message == DashOptimisticVerb.enabling.loadingMessage)
    #expect(toasts.current?.action == nil)

    try? await center.waitForCommit(op)
    #expect(await sleeper.registrations == 0)

    center.finishSuccess(op)
    #expect(toasts.current?.actionPhase == .succeeded)
    #expect(toasts.current?.message == DashOptimisticVerb.enabling.successMessage)
    #expect(toasts.current?.dismissBehavior == .automatic)
  }

  @Test @MainActor
  func disablingUndoCancelsBeforeAPI() async {
    let toasts = DashToastCenter()
    let sleeper = OptimisticManualSleeper()
    let center = DashOptimisticOperationCenter(
      toasts: toasts,
      sleeper: { _ in try await sleeper.sleep() })

    var undone = false
    let op = center.begin(.disabling) { undone = true }
    #expect(toasts.current?.action == .undoOptimistic(op.raw))

    let waitTask = Task {
      try await center.waitForCommit(op)
    }
    await sleeper.waitForRegistration(count: 1)
    center.undo(op)
    var threwCancellation = false
    do {
      try await waitTask.value
    } catch is CancellationError {
      threwCancellation = true
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(threwCancellation)
    #expect(undone)
    #expect(toasts.current == nil)
    #expect(await sleeper.registrations == 1)

    await sleeper.fireAll()
    await Task.yield()
    #expect(toasts.current == nil)
  }

  @Test @MainActor
  func disablingTimeoutCommitsOnce() async {
    let toasts = DashToastCenter()
    let sleeper = OptimisticManualSleeper()
    let center = DashOptimisticOperationCenter(
      toasts: toasts,
      sleeper: { _ in try await sleeper.sleep() })

    var commitCount = 0
    let op = center.begin(.disabling) { Issue.record("Undo should not run") }

    let waitTask = Task {
      try await center.waitForCommit(op)
      commitCount += 1
    }
    await sleeper.waitForRegistration(count: 1)
    #expect(commitCount == 0)
    #expect(toasts.current?.action == .undoOptimistic(op.raw))

    await sleeper.fireNext()
    try? await waitTask.value
    #expect(commitCount == 1)
    #expect(toasts.current?.action == nil)
    #expect(toasts.current?.actionPhase == .loading)

    center.finishSuccess(op)
    #expect(toasts.current?.actionPhase == .succeeded)
    #expect(toasts.current?.message == DashOptimisticVerb.disabling.successMessage)
  }

  @Test @MainActor
  func secondOptimisticOpQueuesBehindProgrammaticLoading() async {
    let toasts = DashToastCenter()
    let center = DashOptimisticOperationCenter(toasts: toasts)

    let first = center.begin(.enabling)
    #expect(toasts.current?.id == .optimistic(first.raw))

    toasts.success("Queued successor.", haptic: false)
    // Programmatic optimistic toast holds the slot; automatic feedback waits.
    #expect(toasts.current?.id == .optimistic(first.raw))

    center.finishSuccess(first)
    #expect(toasts.current?.actionPhase == .succeeded)

    // Success dwell is automatic; dismiss so the queued toast can take the slot
    // (same replace path as rapid toast rules).
    if let id = toasts.current?.id {
      toasts.dismiss(id: id)
    }
    #expect(toasts.current?.message == "Queued successor.")
  }
}

private actor OptimisticManualSleeper {
  private(set) var registrations = 0
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var registrationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func sleep() async throws {
    registrations += 1
    resumeRegistrationWaiters()
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func waitForRegistration(count: Int) async {
    guard registrations < count else { return }
    await withCheckedContinuation { continuation in
      registrationWaiters.append((count, continuation))
    }
  }

  func fireNext() {
    guard !continuations.isEmpty else { return }
    continuations.removeFirst().resume()
  }

  func fireAll() {
    let pending = continuations
    continuations.removeAll()
    for continuation in pending { continuation.resume() }
  }

  private func resumeRegistrationWaiters() {
    let ready = registrationWaiters.filter { registrations >= $0.0 }
    registrationWaiters.removeAll { registrations >= $0.0 }
    for (_, continuation) in ready { continuation.resume() }
  }
}
