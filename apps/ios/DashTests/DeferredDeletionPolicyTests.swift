import CloudflareAPI
import Foundation
import Testing
import UIKit

@testable import Dash

extension DeferredDeletionCoordinatorCoverageTests {
  @Test @MainActor
  func backgroundCommitRemovesUndoSynchronously() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.suspendExecution(for: "background")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(executor: executor, toasts: toasts)
    let command = deletionCommand(recordID: "background")

    coordinator.schedule(command)
    #expect(toasts.current?.action == .undoDeferredDeletionBatch)

    coordinator.commitPendingOperations()

    #expect(toasts.current?.action == nil)
    #expect(coordinator.operations.values.first?.state == .committing)

    await executor.resumeExecution(for: "background")
    await coordinator.waitForActiveWork()
  }

  @Test @MainActor
  func credentialSwitchCancelsPendingWithoutExecutingOldCommand() async {
    let executor = DeferredDeletionScenarioExecutor()
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: DashToastCenter(),
      requiresCredentialActivation: true)
    coordinator.activateCredential(profileID: "person-1", availableAccountIDs: ["account-1"])
    let command = deletionCommand()

    coordinator.schedule(command)
    coordinator.activateCredential(profileID: "person-2", availableAccountIDs: ["account-2"])
    await Task.yield()

    #expect(!coordinator.isPendingDeletion(command.resourceKey))
    #expect(await executor.executionCount == 0)
  }

  @Test @MainActor
  func credentialSwitchPurgesQueuedDeletionResultsButKeepsUnrelatedFeedback() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.failure, for: "old-account")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: toasts,
      requiresCredentialActivation: true)
    coordinator.activateCredential(profileID: "person-1", availableAccountIDs: ["account-1"])

    coordinator.schedule(deletionCommand(recordID: "old-account"))
    toasts.success("Unrelated feedback.", haptic: false)
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)
    await coordinator.waitForActiveWork()

    #expect(toasts.current?.message == "Unrelated feedback.")

    coordinator.activateCredential(profileID: "person-2", availableAccountIDs: ["account-2"])
    #expect(toasts.current?.message == "Unrelated feedback.")
    #expect(coordinator.operations.isEmpty)

    if let currentID = toasts.current?.id {
      toasts.dismiss(id: currentID)
    }
    #expect(toasts.current == nil)
  }

  @Test @MainActor
  func removingAccountFromSameProfilePurgesItsVisibleRetry() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.failure, for: "removed-account")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: toasts,
      requiresCredentialActivation: true)
    coordinator.activateCredential(
      profileID: "person-1",
      availableAccountIDs: ["account-1", "account-2"])
    let operationID = coordinator.schedule(
      deletionCommand(recordID: "removed-account", accountID: "account-1"))!

    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)
    await coordinator.waitForActiveWork()
    #expect(toasts.current?.action == .retryDeferredDeletions([operationID]))

    coordinator.activateCredential(
      profileID: "person-1",
      availableAccountIDs: ["account-2"])

    #expect(coordinator.operations[operationID] == nil)
    #expect(toasts.current == nil)
  }

  @Test @MainActor
  func languageRefreshRebuildsAQueuedFailureAndPromotesItAfterClearingTransients() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.failure, for: "localized-failure")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(executor: executor, toasts: toasts)
    let command = deletionCommand(recordID: "localized-failure")
    let operationID = coordinator.schedule(command)!

    toasts.success("Old-language transient.", haptic: false)
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)
    await coordinator.waitForActiveWork()

    coordinator.refreshLocalizedPresentation()
    toasts.clearAll(preserving: .deferredDeletionBatch)

    #expect(toasts.current?.action == .retryDeferredDeletions([operationID]))
    #expect(coordinator.operations[operationID]?.state == .failed)
  }

  @Test @MainActor
  func languageRefreshDoesNotResurrectDismissedFailure() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.failure, for: "refresh-cleanup")
    let cleanupSleeper = DeferredDeletionManualSleeper()
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: toasts,
      cleanupSleeper: { _ in try await cleanupSleeper.sleep() })
    let operationID = coordinator.schedule(deletionCommand(recordID: "refresh-cleanup"))!

    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)
    await coordinator.waitForActiveWork()
    toasts.dismiss(id: .deferredDeletionBatch)
    await cleanupSleeper.waitForRegistration(count: 1)

    coordinator.refreshLocalizedPresentation()
    await cleanupSleeper.fireNext()
    await coordinator.waitForFailedCleanup(of: operationID)

    #expect(coordinator.operations[operationID] == nil)
    #expect(toasts.current == nil)
  }

  @Test @MainActor
  func protectedToastRequiresItsOpaqueOwnerToDismiss() {
    let toasts = DashToastCenter()
    let owner = toasts.claimDeferredDeletionOwner()
    toasts.show(
      DashToast(
        id: .deferredDeletionBatch,
        kind: .warning,
        message: "Pending",
        action: .undoDeferredDeletionBatch,
        actionTitle: "Undo",
        dismissBehavior: .programmaticOnly),
      haptic: false,
      deferredDeletionOwner: owner)

    toasts.dismiss()
    #expect(toasts.current?.id == .deferredDeletionBatch)

    toasts.dismiss(id: .deferredDeletionBatch)
    #expect(toasts.current?.id == .deferredDeletionBatch)

    toasts.releaseDeferredDeletionToast(owner: owner)
    #expect(toasts.current == nil)
  }

  @Test @MainActor
  func undoPreservesQueuedFeedbackOrder() {
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(
      executor: DeferredDeletionScenarioExecutor(),
      toasts: toasts)

    coordinator.schedule(deletionCommand())
    toasts.success("Earlier feedback.", haptic: false)
    coordinator.undoCurrentBatch()

    #expect(toasts.current?.message == "Earlier feedback.")
    let earlierID = toasts.current?.id
    if let earlierID {
      toasts.dismiss(id: earlierID)
    }
    #expect(toasts.current?.message == "Deletion undone.")
  }

  @Test @MainActor
  func clearAllDropsCurrentAndQueuedFeedbackAcrossSessions() {
    let toasts = DashToastCenter()
    let owner = toasts.claimDeferredDeletionOwner()
    toasts.show(
      DashToast(
        id: .deferredDeletionBatch,
        kind: .warning,
        message: "Old account deletion",
        dismissBehavior: .programmaticOnly),
      haptic: false,
      deferredDeletionOwner: owner)
    toasts.success("Old account feedback.", haptic: false)

    toasts.clearAll()
    #expect(toasts.current == nil)

    toasts.success("New account feedback.", haptic: false)
    #expect(toasts.current?.message == "New account feedback.")
    if let id = toasts.current?.id {
      toasts.dismiss(id: id)
    }
    #expect(toasts.current == nil)
  }

  @Test
  func cloudflareExecutorReconcilesByStableRecordID() async throws {
    let session = deferredDeletionMockSession { request in
      let recordID = request.url!.lastPathComponent
      if recordID == "missing" {
        return (
          404,
          Data(
            """
            {"success":false,"result":null,"errors":[]}
            """.utf8)
        )
      }
      let body =
        """
        {
          "success": true,
          "result": {
            "id": "\(recordID)",
            "zone_id": "zone-1",
            "type": "A",
            "name": "renamed.example.com",
            "content": "192.0.2.1",
            "ttl": 1
          },
          "errors": []
        }
        """
      return (200, Data(body.utf8))
    }
    let client = CloudflareClient(
      clientID: "test",
      tokenStore: DemoTokenStore(),
      session: session)
    let executor = CloudflareDeferredDeletionExecutor(client: client)

    let existing = try await executor.reconcile(deletionCommand(recordID: "target"))
    let missing = try await executor.reconcile(deletionCommand(recordID: "missing"))

    switch existing {
    case .resourceExists:
      break
    case .resourceMissing:
      Issue.record("Expected the renamed record to be found by immutable ID")
    }
    switch missing {
    case .resourceMissing:
      break
    case .resourceExists:
      Issue.record("Expected a structured 404 to prove the record is absent")
    }
  }
}

@Test @MainActor func deferredDeletionUndoPreemptsAutomaticWithoutRevivingQueuedUndo() {
  let toasts = DashToastCenter()
  let owner = toasts.claimDeferredDeletionOwner()
  let optimisticID = DashToast.ID.optimistic(UUID())
  toasts.show(
    DashToast(
      id: optimisticID,
      kind: .warning,
      message: "Saving settings…",
      dismissBehavior: .programmaticOnly),
    haptic: false,
    announce: false)

  let later = DashToast(kind: .success, message: "Later feedback.")
  toasts.show(later, haptic: false, announce: false)
  toasts.show(
    DashToast(
      id: .deferredDeletionBatch,
      kind: .warning,
      message: "First deletion deadline.",
      action: .undoDeferredDeletionBatch,
      dismissBehavior: .programmaticOnly),
    haptic: false,
    announce: false,
    deferredDeletionOwner: owner)
  #expect(toasts.current?.id == optimisticID)

  toasts.update(
    DashToast(id: optimisticID, kind: .success, message: "Settings saved."),
    haptic: false,
    announce: false)
  toasts.update(
    DashToast(
      id: .deferredDeletionBatch,
      kind: .warning,
      message: "Latest deletion deadline.",
      action: .undoDeferredDeletionBatch,
      dismissBehavior: .programmaticOnly),
    haptic: false,
    announce: false,
    deferredDeletionOwner: owner)
  #expect(toasts.current?.message == "Latest deletion deadline.")

  toasts.releaseDeferredDeletionToast(owner: owner)
  #expect(toasts.current?.id == later.id)
  toasts.dismiss(id: later.id)
  #expect(toasts.current == nil)
}

private actor DeferredDeletionTestExecutor: DeferredDeletionExecuting {
  enum Result: Sendable {
    case success
    case failure
    case missing
    case uncertain
  }

  private(set) var executed: [DeferredDeleteCommand] = []
  var result: Result = .success
  var reconciliation: DeferredDeletionReconciliationResult = .resourceMissing

  func execute(_ command: DeferredDeleteCommand) async throws {
    executed.append(command)
    switch result {
    case .success:
      return
    case .failure:
      throw CloudflareAPIError.request(
        status: 403,
        errors: [APIErrorItem(code: 10000, message: "Forbidden")])
    case .missing:
      throw CloudflareAPIError.request(status: 404, errors: [])
    case .uncertain:
      throw CloudflareAPIError.transport("Connection lost")
    }
  }

  func reconcile(_ command: DeferredDeleteCommand) async throws
    -> DeferredDeletionReconciliationResult
  {
    reconciliation
  }

  func executionCount() -> Int {
    executed.count
  }

  func setResultForTesting(_ result: Result) {
    self.result = result
  }

  func setReconciliationForTesting(_ result: DeferredDeletionReconciliationResult) {
    reconciliation = result
  }
}

private actor DeferredDeletionTestSleeper {
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func sleep() async {
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func fire() {
    let pending = continuations
    continuations.removeAll()
    for continuation in pending {
      continuation.resume()
    }
  }
}

private func testDNSDeletion(
  recordID: String = "record-1",
  displayName: String = "api.example.com"
) -> DeferredDeleteCommand {
  .dnsRecord(
    accountID: "account-1",
    zoneID: "zone-1",
    recordID: recordID,
    recordType: "A",
    displayName: displayName)
}

@Test @MainActor func deferredDeletionWaitsForDeadlineBeforeExecuting() async {
  let executor = DeferredDeletionTestExecutor()
  let sleeper = DeferredDeletionTestSleeper()
  let toasts = DashToastCenter()
  let coordinator = DeferredDeletionCoordinator(
    executor: executor,
    toasts: toasts,
    sleeper: { _ in await sleeper.sleep() })
  let command = testDNSDeletion()

  coordinator.schedule(command)

  #expect(coordinator.isPendingDeletion(command.resourceKey))
  #expect(await executor.executionCount() == 0)
  #expect(toasts.current?.id == .deferredDeletionBatch)
  #expect(toasts.current?.action == .undoDeferredDeletionBatch)

  coordinator.commitPendingOperations()
  await coordinator.waitForActiveWork()

  #expect(await executor.executionCount() == 1)
  #expect(coordinator.isPendingDeletion(command.resourceKey))
}

@Test @MainActor func deferredDeletionUndoRemovesTombstoneAndNeverExecutes() async {
  let executor = DeferredDeletionTestExecutor()
  let sleeper = DeferredDeletionTestSleeper()
  let coordinator = DeferredDeletionCoordinator(
    executor: executor,
    toasts: DashToastCenter(),
    sleeper: { _ in await sleeper.sleep() })
  let command = testDNSDeletion()

  coordinator.schedule(command)
  coordinator.undoCurrentBatch()
  await sleeper.fire()
  await Task.yield()

  #expect(!coordinator.isPendingDeletion(command.resourceKey))
  #expect(await executor.executionCount() == 0)
}

@Test @MainActor func deferredDeletionBatchUsesOneToastAndUndoesEveryItem() async {
  let executor = DeferredDeletionTestExecutor()
  let sleeper = DeferredDeletionTestSleeper()
  let toasts = DashToastCenter()
  let coordinator = DeferredDeletionCoordinator(
    executor: executor,
    toasts: toasts,
    sleeper: { _ in await sleeper.sleep() })
  let first = testDNSDeletion()
  let second = testDNSDeletion(recordID: "record-2", displayName: "www.example.com")

  coordinator.schedule(first)
  coordinator.schedule(second)

  #expect(toasts.current?.id == .deferredDeletionBatch)
  #expect(toasts.current?.actionTitle == "Undo all")
  #expect(coordinator.isPendingDeletion(first.resourceKey))
  #expect(coordinator.isPendingDeletion(second.resourceKey))

  coordinator.undoCurrentBatch()

  #expect(!coordinator.isPendingDeletion(first.resourceKey))
  #expect(!coordinator.isPendingDeletion(second.resourceKey))
  #expect(await executor.executionCount() == 0)
}

@Test @MainActor func deferredDeletionFailureRestoresResource() async {
  let executor = DeferredDeletionTestExecutor()
  await executor.setResultForTesting(.failure)
  let coordinator = DeferredDeletionCoordinator(
    executor: executor,
    toasts: DashToastCenter())
  let command = testDNSDeletion()

  coordinator.schedule(command)
  coordinator.commitPendingOperations()
  await coordinator.waitForActiveWork()

  #expect(!coordinator.isPendingDeletion(command.resourceKey))
  #expect(await executor.executionCount() == 1)
}

@Test @MainActor func deferredDeletionTreatsMissingResourceAsSuccess() async {
  let executor = DeferredDeletionTestExecutor()
  await executor.setResultForTesting(.missing)
  let coordinator = DeferredDeletionCoordinator(
    executor: executor,
    toasts: DashToastCenter())
  let command = testDNSDeletion()

  coordinator.schedule(command)
  coordinator.commitPendingOperations()
  await Task.yield()
  await Task.yield()

  #expect(coordinator.isPendingDeletion(command.resourceKey))
  #expect(await executor.executionCount() == 1)
}

@Test @MainActor func uncertainDeletionReconcilesBeforeRestoringResource() async {
  let executor = DeferredDeletionTestExecutor()
  await executor.setResultForTesting(.uncertain)
  await executor.setReconciliationForTesting(.resourceExists)
  let coordinator = DeferredDeletionCoordinator(
    executor: executor,
    toasts: DashToastCenter())
  let command = testDNSDeletion()

  coordinator.schedule(command)
  coordinator.commitPendingOperations()
  await coordinator.waitForActiveWork()

  #expect(!coordinator.isPendingDeletion(command.resourceKey))
  #expect(await executor.executionCount() == 1)
}

@Test @MainActor func accountSwitchCancelsOnlyPendingOperations() async {
  let executor = DeferredDeletionTestExecutor()
  let coordinator = DeferredDeletionCoordinator(
    executor: executor,
    toasts: DashToastCenter())
  let command = testDNSDeletion()

  coordinator.schedule(command)
  coordinator.cancelPendingOperations(forAccountID: "account-1")

  #expect(!coordinator.isPendingDeletion(command.resourceKey))
  #expect(await executor.executionCount() == 0)
}

@Test @MainActor func toastQueuesFeedbackBehindProgrammaticDeletionToast() {
  let toasts = DashToastCenter()
  let owner = toasts.claimDeferredDeletionOwner()
  toasts.show(
    DashToast(
      id: .deferredDeletionBatch,
      kind: .warning,
      message: "Pending",
      dismissBehavior: .programmaticOnly),
    haptic: false,
    deferredDeletionOwner: owner)

  toasts.success("Saved.", haptic: false)

  #expect(toasts.current?.id == .deferredDeletionBatch)
  toasts.releaseDeferredDeletionToast(owner: owner)
  #expect(toasts.current?.message == "Saved.")
}
