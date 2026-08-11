import CloudflareAPI
import Foundation
import Testing
import UIKit

@testable import Dash

struct DeferredDeletionCoordinatorCoverageTests {
  @Test @MainActor
  func newerDNSLoadSupersedesAnOlderResponseAcrossViewInstances() {
    let coordinator = DeferredDeletionCoordinator(
      executor: DeferredDeletionScenarioExecutor(),
      toasts: DashToastCenter())
    let scope = DeferredDeletionScope(accountID: "account-1", zoneID: "zone-1")

    let older = coordinator.beginDNSLoad(for: scope)
    let newer = coordinator.beginDNSLoad(for: scope)

    #expect(!coordinator.isCurrentDNSLoad(for: scope, generation: older))
    #expect(coordinator.isCurrentDNSLoad(for: scope, generation: newer))
  }

  @Test @MainActor
  func dnsLoadGenerationIsNotReusedAcrossCredentialReplacement() async {
    let coordinator = DeferredDeletionCoordinator(
      executor: DeferredDeletionScenarioExecutor(),
      toasts: DashToastCenter(),
      requiresCredentialActivation: true)
    let scope = DeferredDeletionScope(accountID: "account-1", zoneID: "zone-1")
    coordinator.activateCredential(profileID: "person-1", availableAccountIDs: ["account-1"])
    let oldGeneration = coordinator.beginDNSLoad(for: scope)

    await coordinator.prepareForCredentialReplacement()
    coordinator.activateCredential(profileID: "person-1", availableAccountIDs: ["account-1"])
    let replacementGeneration = coordinator.beginDNSLoad(for: scope)

    #expect(oldGeneration != replacementGeneration)
    #expect(!coordinator.isCurrentDNSLoad(for: scope, generation: oldGeneration))
    #expect(coordinator.isCurrentDNSLoad(for: scope, generation: replacementGeneration))
  }

  @Test @MainActor
  func staleBackgroundLeaseCompletionCannotEndTheReplacementLease() {
    let firstIdentifier = UIBackgroundTaskIdentifier(rawValue: 1)
    let secondIdentifier = UIBackgroundTaskIdentifier(rawValue: 2)
    var ended: [UIBackgroundTaskIdentifier] = []
    let lease = DeferredDeletionBackgroundTaskLease {
      ended.append($0)
    }

    let firstGeneration = lease.replace { _ in firstIdentifier }
    let secondGeneration = lease.replace { _ in secondIdentifier }

    #expect(ended == [firstIdentifier])

    lease.end(generation: firstGeneration)
    #expect(ended == [firstIdentifier])

    lease.end(generation: secondGeneration)
    #expect(ended == [firstIdentifier, secondIdentifier])
  }

  @Test @MainActor
  func deadlineWaitsThenExecutesExactlyOnce() async {
    let executor = DeferredDeletionScenarioExecutor()
    let sleeper = DeferredDeletionManualSleeper()
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: DashToastCenter(),
      sleeper: { _ in try await sleeper.sleep() })
    let command = deletionCommand()

    coordinator.schedule(command)
    await sleeper.waitForRegistration(count: 1)

    #expect(await executor.executionCount == 0)
    #expect(coordinator.isPendingDeletion(command.resourceKey))

    await sleeper.fireNext()
    await executor.waitForExecutionCount(1)
    await coordinator.waitForActiveWork()
    await sleeper.fireAll()

    #expect(await executor.executionCount == 1)
    #expect(coordinator.operations.values.first?.state == .succeeded)
    #expect(coordinator.isPendingDeletion(command.resourceKey))
  }

  @Test @MainActor
  func rollingBatchInvalidatesOldDeadlineAndUsesOneUndoToast() async {
    let executor = DeferredDeletionScenarioExecutor()
    let sleeper = DeferredDeletionManualSleeper()
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: toasts,
      sleeper: { _ in try await sleeper.sleep() })
    let first = deletionCommand(recordID: "record-1")
    let second = deletionCommand(recordID: "record-2")

    coordinator.schedule(first)
    await sleeper.waitForRegistration(count: 1)
    coordinator.schedule(second)
    await sleeper.waitForRegistration(count: 2)

    #expect(toasts.current?.id == .deferredDeletionBatch)
    #expect(toasts.current?.action == .undoDeferredDeletionBatch)
    #expect(toasts.current?.actionTitle == "Undo all")

    await sleeper.fireNext()
    await Task.yield()
    await Task.yield()
    #expect(await executor.executionCount == 0)

    await sleeper.fireNext()
    await executor.waitForExecutionCount(2)
    await coordinator.waitForActiveWork()

    #expect(await executor.executionCount == 2)
  }

  @Test @MainActor
  func undoAndDeadlineAreMutuallyExclusive() async {
    let undoExecutor = DeferredDeletionScenarioExecutor()
    let undoSleeper = DeferredDeletionManualSleeper()
    let undoCoordinator = DeferredDeletionCoordinator(
      executor: undoExecutor,
      toasts: DashToastCenter(),
      sleeper: { _ in try await undoSleeper.sleep() })
    let undone = deletionCommand(recordID: "undo-first")

    undoCoordinator.schedule(undone)
    await undoSleeper.waitForRegistration(count: 1)
    undoCoordinator.undoCurrentBatch()
    await undoSleeper.fireAll()
    await Task.yield()

    #expect(await undoExecutor.executionCount == 0)
    #expect(!undoCoordinator.isPendingDeletion(undone.resourceKey))
    #expect(undoCoordinator.operations.isEmpty)

    let commitExecutor = DeferredDeletionScenarioExecutor()
    await commitExecutor.suspendExecution(for: "commit-first")
    let commitSleeper = DeferredDeletionManualSleeper()
    let commitCoordinator = DeferredDeletionCoordinator(
      executor: commitExecutor,
      toasts: DashToastCenter(),
      sleeper: { _ in try await commitSleeper.sleep() })
    let committed = deletionCommand(recordID: "commit-first")

    commitCoordinator.schedule(committed)
    await commitSleeper.waitForRegistration(count: 1)
    await commitSleeper.fireNext()
    await commitExecutor.waitForExecutionCount(1)
    commitCoordinator.undoCurrentBatch()
    await commitExecutor.resumeExecution(for: "commit-first")
    await commitCoordinator.waitForActiveWork()

    #expect(await commitExecutor.executionCount == 1)
    #expect(commitCoordinator.operations.values.first?.state == .succeeded)
    #expect(commitCoordinator.isPendingDeletion(committed.resourceKey))
  }

  @Test @MainActor
  func olderCommitCannotReplaceNewerBatchUndo() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.suspendExecution(for: "older")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(executor: executor, toasts: toasts)
    let older = deletionCommand(recordID: "older")
    let newer = deletionCommand(recordID: "newer")

    coordinator.schedule(older)
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)
    coordinator.schedule(newer)

    #expect(toasts.current?.action == .undoDeferredDeletionBatch)
    #expect(coordinator.isPendingDeletion(newer.resourceKey))

    await executor.resumeExecution(for: "older")
    await coordinator.waitForActiveWork()

    #expect(toasts.current?.action == .undoDeferredDeletionBatch)
    #expect(coordinator.isPendingDeletion(older.resourceKey))
    #expect(coordinator.isPendingDeletion(newer.resourceKey))

    coordinator.undoCurrentBatch()

    #expect(coordinator.isPendingDeletion(older.resourceKey))
    #expect(!coordinator.isPendingDeletion(newer.resourceKey))
  }

  @Test @MainActor
  func pendingToastRerenderUsesTheAbsoluteDeadlineWithoutReannouncingTheFullWindow() {
    let clock = DeferredDeletionDateBox(Date(timeIntervalSince1970: 1_000))
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(
      executor: DeferredDeletionScenarioExecutor(),
      toasts: toasts,
      now: { clock.value })

    coordinator.schedule(deletionCommand())
    #expect(toasts.current?.message.contains("5 seconds") == true)
    #expect(toasts.current?.message.contains("A record api.example.com") == true)
    #expect(
      toasts.current?.accessibilityAnnouncement?.contains(
        "A record api.example.com will be deleted in 5 seconds. Undo available.") == true)

    clock.value = clock.value.addingTimeInterval(4.2)
    coordinator.refreshLocalizedPresentation()

    #expect(toasts.current?.message.contains("1 second.") == true)
    #expect(toasts.current?.action == .undoDeferredDeletionBatch)
  }

  @Test @MainActor
  func partialFailureRestoresOnlyFailedResourceAndRetriesIt() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.failure, for: "failed")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(executor: executor, toasts: toasts)
    let first = deletionCommand(recordID: "success-1")
    let second = deletionCommand(recordID: "failed")
    let third = deletionCommand(recordID: "success-2")

    coordinator.schedule(first)
    coordinator.schedule(second)
    coordinator.schedule(third)
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(3)
    await coordinator.waitForActiveWork()

    #expect(coordinator.isPendingDeletion(first.resourceKey))
    #expect(!coordinator.isPendingDeletion(second.resourceKey))
    #expect(coordinator.isPendingDeletion(third.resourceKey))
    #expect(toasts.current?.kind == .error)
    #expect(toasts.current?.actionTitle == "Retry")

    await executor.setExecutionOutcome(.success, for: "failed")
    if let action = toasts.current?.action {
      #expect(
        action
          == .retryDeferredDeletions(
            Array(
              coordinator.operations.compactMap {
                $0.value.state == .failed ? $0.key : nil
              })))
      if case .retryDeferredDeletions(let ids) = action {
        coordinator.retryFailures(ids)
      }
    }
    await executor.waitForExecutionCount(4)
    await coordinator.waitForActiveWork()

    #expect(coordinator.isPendingDeletion(second.resourceKey))
    #expect(coordinator.operations.values.allSatisfy { $0.state != .failed })
  }

  @Test @MainActor
  func retriedSuccessNeedsItsOwnFeedbackDismissalBeforeConfirmedStateIsPruned() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.failure, for: "retry-success")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(executor: executor, toasts: toasts)
    let command = deletionCommand(recordID: "retry-success")
    let operationID = coordinator.schedule(command)!

    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)
    await coordinator.waitForActiveWork()
    #expect(toasts.current?.action == .retryDeferredDeletions([operationID]))

    await executor.setExecutionOutcome(.success, for: "retry-success")
    coordinator.retry(operationID)
    await executor.waitForExecutionCount(2)
    await coordinator.waitForActiveWork()
    #expect(coordinator.operations[operationID]?.state == .succeeded)
    #expect(toasts.current?.kind == .success)

    coordinator.reconcileDNSRecords(
      accountID: "account-1",
      zoneID: "zone-1",
      serverRecordIDs: [],
      isCompleteSnapshot: true)

    #expect(coordinator.operations[operationID]?.state == .succeeded)
    #expect(coordinator.isPendingDeletion(command.resourceKey))

    toasts.dismiss(id: .deferredDeletionBatch)
    #expect(coordinator.operations[operationID] == nil)
    #expect(!coordinator.isPendingDeletion(command.resourceKey))
  }

  @Test @MainActor
  func dismissedFailureCannotRetryBeforeCleanupCompletes() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.failure, for: "dismissed-retry")
    let cleanupSleeper = DeferredDeletionManualSleeper()
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: toasts,
      cleanupSleeper: { _ in try await cleanupSleeper.sleep() })
    let command = deletionCommand(recordID: "dismissed-retry")
    let operationID = coordinator.schedule(command)!

    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)
    await coordinator.waitForActiveWork()
    toasts.dismiss(id: .deferredDeletionBatch)
    await cleanupSleeper.waitForRegistration(count: 1)

    coordinator.retry(operationID)
    await Task.yield()
    #expect(await executor.executionCount == 1)
    #expect(coordinator.operations[operationID]?.state == .failed)

    await cleanupSleeper.fireNext()
    await coordinator.waitForFailedCleanup(of: operationID)
    #expect(coordinator.operations[operationID] == nil)
  }

  @Test @MainActor
  func queuedFailureKeepsRetryStateUntilItsToastIsDismissed() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.failure, for: "queued-failure")
    let cleanupSleeper = DeferredDeletionManualSleeper()
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: toasts,
      cleanupSleeper: { _ in try await cleanupSleeper.sleep() })
    let command = deletionCommand(recordID: "queued-failure")
    let operationID = coordinator.schedule(command)!

    toasts.success("Earlier feedback.", haptic: false)
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)
    await coordinator.waitForActiveWork()

    #expect(toasts.current?.message == "Earlier feedback.")
    #expect(coordinator.operations[operationID]?.state == .failed)

    if let earlierID = toasts.current?.id {
      toasts.dismiss(id: earlierID)
    }
    #expect(toasts.current?.action == .retryDeferredDeletions([operationID]))
    #expect(coordinator.operations[operationID]?.state == .failed)

    toasts.dismiss(id: .deferredDeletionBatch)
    await cleanupSleeper.waitForRegistration(count: 1)
    #expect(coordinator.operations[operationID]?.state == .failed)

    await cleanupSleeper.fireNext()
    await coordinator.waitForFailedCleanup(of: operationID)
    #expect(coordinator.operations[operationID] == nil)
  }

  @Test @MainActor
  func newIntentSupersedesAnOlderFailureAndMakesItsRetryStale() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.failure, for: "same-resource")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: toasts)
    let command = deletionCommand(recordID: "same-resource")
    let firstID = coordinator.schedule(command)!

    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)
    await coordinator.waitForActiveWork()
    #expect(coordinator.operations[firstID]?.state == .failed)

    let secondID = coordinator.schedule(command)!
    #expect(coordinator.operations[firstID] == nil)
    #expect(coordinator.operations[secondID]?.state == .pending)
    #expect(coordinator.isPendingDeletion(command.resourceKey))

    coordinator.retry(firstID)
    await Task.yield()
    #expect(await executor.executionCount == 1)
    #expect(coordinator.operations[secondID]?.state == .pending)
    #expect(coordinator.isPendingDeletion(command.resourceKey))

    coordinator.undoCurrentBatch()
  }

  @Test @MainActor
  func newIntentDiscardsQueuedRetryFeedbackForItsSupersededFailure() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.failure, for: "queued-same-resource")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(executor: executor, toasts: toasts)
    let command = deletionCommand(recordID: "queued-same-resource")
    let firstID = coordinator.schedule(command)!

    toasts.success("Unrelated feedback.", haptic: false)
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)
    await coordinator.waitForActiveWork()
    #expect(toasts.current?.message == "Unrelated feedback.")

    let secondID = coordinator.schedule(command)!
    #expect(coordinator.operations[firstID] == nil)
    #expect(coordinator.operations[secondID]?.state == .pending)
    // A new destructive grace period must expose Undo immediately instead of
    // waiting behind unrelated finite feedback.
    #expect(toasts.current?.action == .undoDeferredDeletionBatch)

    await executor.setExecutionOutcome(.success, for: "queued-same-resource")
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(2)
    await coordinator.waitForActiveWork()

    #expect(toasts.current?.kind == .success)
    #expect(toasts.current?.action == nil)
    #expect(await executor.executionCount == 2)
  }

  @Test @MainActor
  func supersedingCurrentRetryDoesNotLoseTheNextQueuedRetry() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.uncertain, for: "queued-second")
    await executor.setReconciliationOutcome(.failure, for: "queued-second")
    await executor.setExecutionOutcome(.failure, for: "current-first")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(executor: executor, toasts: toasts)
    let secondCommand = deletionCommand(recordID: "queued-second")
    let firstCommand = deletionCommand(recordID: "current-first")

    let secondID = coordinator.schedule(secondCommand)!
    coordinator.commitPendingOperations()
    await executor.waitForReconciliationCount(1)
    await coordinator.waitForActiveWork()
    #expect(coordinator.operations[secondID]?.state == .reconciling)

    let firstID = coordinator.schedule(firstCommand)!
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(2)
    await coordinator.waitForActiveWork()
    #expect(toasts.current?.action == .retryDeferredDeletions([firstID]))

    coordinator.reconcileDNSRecords(
      accountID: "account-1",
      zoneID: "zone-1",
      serverRecordIDs: ["queued-second"])
    #expect(coordinator.operations[secondID]?.state == .failed)
    #expect(toasts.current?.action == .retryDeferredDeletions([firstID]))

    let replacementID = coordinator.schedule(firstCommand)!
    #expect(coordinator.operations[firstID] == nil)
    #expect(coordinator.operations[replacementID]?.state == .pending)
    #expect(toasts.current?.action == .undoDeferredDeletionBatch)

    coordinator.undoCurrentBatch()
    #expect(toasts.current?.action == .retryDeferredDeletions([secondID]))
    #expect(coordinator.operations[secondID]?.state == .failed)
    #expect(await executor.executionCount == 2)
  }

  @Test @MainActor
  func supersedingFailureInMixedResultReReportsStillValidSuccess() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.suspendExecution(for: "aggregate-success")
    await executor.suspendExecution(for: "aggregate-failure")
    await executor.setExecutionOutcome(.failure, for: "aggregate-failure")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(executor: executor, toasts: toasts)
    let successfulCommand = deletionCommand(recordID: "aggregate-success")
    let failedCommand = deletionCommand(recordID: "aggregate-failure")

    let successfulID = coordinator.schedule(successfulCommand)!
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)
    let failedID = coordinator.schedule(failedCommand)!
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(2)

    await executor.resumeExecution(for: "aggregate-success")
    for _ in 0..<50 where coordinator.operations[successfulID]?.state != .succeeded {
      await Task.yield()
    }
    await executor.resumeExecution(for: "aggregate-failure")
    await coordinator.waitForActiveWork()

    #expect(coordinator.operations[successfulID]?.state == .succeeded)
    #expect(coordinator.operations[failedID]?.state == .failed)
    #expect(toasts.current?.kind == .error)
    #expect(toasts.current?.message.contains("1 items deleted, 1 failed") == true)

    await executor.setExecutionOutcome(.success, for: "aggregate-failure")
    let replacementID = coordinator.schedule(failedCommand)!
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(3)
    await coordinator.waitForActiveWork()

    #expect(coordinator.operations[failedID] == nil)
    #expect(coordinator.operations[replacementID]?.state == .succeeded)
    #expect(toasts.current?.kind == .success)
    #expect(toasts.current?.message.contains("2 items deleted") == true)
  }

  @Test @MainActor
  func queuedMixedResultKeepsConfirmedSuccessUntilReplacementFeedbackCanReportIt() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.suspendExecution(for: "queued-success")
    await executor.suspendExecution(for: "queued-failure")
    await executor.setExecutionOutcome(.failure, for: "queued-failure")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(executor: executor, toasts: toasts)
    let successfulCommand = deletionCommand(recordID: "queued-success")
    let failedCommand = deletionCommand(recordID: "queued-failure")

    let successfulID = coordinator.schedule(successfulCommand)!
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)
    let failedID = coordinator.schedule(failedCommand)!
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(2)
    toasts.success("Unrelated feedback.", haptic: false)

    await executor.resumeExecution(for: "queued-success")
    await executor.resumeExecution(for: "queued-failure")
    await coordinator.waitForActiveWork()

    #expect(toasts.current?.message == "Unrelated feedback.")
    coordinator.reconcileDNSRecords(
      accountID: "account-1",
      zoneID: "zone-1",
      serverRecordIDs: ["queued-failure"],
      isCompleteSnapshot: true)
    #expect(coordinator.operations[successfulID]?.state == .succeeded)

    if let unrelatedID = toasts.current?.id {
      toasts.dismiss(id: unrelatedID)
    }
    #expect(toasts.current?.message.contains("1 items deleted, 1 failed") == true)

    let replacementID = coordinator.schedule(failedCommand)!
    #expect(coordinator.operations[failedID] == nil)
    #expect(coordinator.operations[replacementID]?.state == .pending)
    coordinator.undoCurrentBatch()

    #expect(coordinator.operations[successfulID]?.state == .succeeded)
    #expect(toasts.current?.kind == .success)
    #expect(toasts.current?.message == "Deletion undone.")
    if let undoneID = toasts.current?.id {
      toasts.dismiss(id: undoneID)
    }
    #expect(toasts.current?.message.contains("deleted") == true)
  }

  @Test @MainActor
  func idleReconciliationNoticeQueuesAFinishedBatchResult() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.uncertain, for: "uncertain")
    await executor.setReconciliationOutcome(.failure, for: "uncertain")
    await executor.suspendReconciliation(for: "uncertain")
    await executor.suspendExecution(for: "finished")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(executor: executor, toasts: toasts)

    coordinator.schedule(deletionCommand(recordID: "uncertain"))
    coordinator.commitPendingOperations()
    await executor.waitForReconciliationCount(1)

    coordinator.schedule(deletionCommand(recordID: "finished"))
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(2)

    await executor.resumeReconciliation(for: "uncertain")
    await Task.yield()
    await executor.resumeExecution(for: "finished")
    await coordinator.waitForActiveWork()

    #expect(toasts.current?.message.contains("could not confirm") == true)
    toasts.dismiss(id: .deferredDeletionBatch)
    #expect(toasts.current?.message.contains("deleted") == true)
  }

  @Test @MainActor
  func removingAccountCancelsActiveReconciliationWithoutLeakingWork() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.uncertain, for: "reconciling")
    await executor.suspendReconciliation(for: "reconciling")
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: DashToastCenter(),
      requiresCredentialActivation: true)
    coordinator.activateCredential(profileID: "person-1", availableAccountIDs: ["account-1"])
    let command = deletionCommand(recordID: "reconciling")

    coordinator.schedule(command)
    coordinator.commitPendingOperations()
    await executor.waitForReconciliationCount(1)

    coordinator.activateCredential(profileID: "person-1", availableAccountIDs: [])
    await coordinator.waitForActiveWork()

    #expect(coordinator.operations.isEmpty)
    #expect(!coordinator.isPendingDeletion(command.resourceKey))
    await executor.resumeReconciliation(for: "reconciling")
  }

  @Test @MainActor
  func removingAccountWaitsForStartedDeleteBeforeDroppingState() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.suspendExecution(for: "committing")
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: DashToastCenter(),
      requiresCredentialActivation: true)
    coordinator.activateCredential(profileID: "person-1", availableAccountIDs: ["account-1"])
    let command = deletionCommand(recordID: "committing")

    coordinator.schedule(command)
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)

    coordinator.activateCredential(profileID: "person-1", availableAccountIDs: [])
    #expect(coordinator.operations.values.first?.state == .committing)

    await executor.resumeExecution(for: "committing")
    await coordinator.waitForActiveWork()

    #expect(coordinator.operations.isEmpty)
    #expect(!coordinator.isPendingDeletion(command.resourceKey))
  }

  @Test @MainActor
  func uncertainOutcomeDefersWithoutLockingToastThenResumesSingleFlight() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.uncertain, for: "uncertain")
    await executor.setReconciliationOutcome(.failure, for: "uncertain")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(executor: executor, toasts: toasts)
    let command = deletionCommand(recordID: "uncertain")

    coordinator.schedule(command)
    coordinator.commitPendingOperations()
    await executor.waitForReconciliationCount(1)
    await coordinator.waitForActiveWork()

    #expect(coordinator.operations.values.first?.state == .reconciling)
    #expect(coordinator.isPendingDeletion(command.resourceKey))
    #expect(toasts.current?.dismissBehavior == .automatic)

    await executor.setReconciliationOutcome(.resourceMissing, for: "uncertain")
    await executor.suspendReconciliation(for: "uncertain")
    coordinator.resumeReconciliation()
    coordinator.resumeReconciliation()
    coordinator.resumeReconciliation()
    await executor.waitForReconciliationCount(2)

    #expect(await executor.reconciliationCount == 2)

    await executor.resumeReconciliation(for: "uncertain")
    await coordinator.waitForActiveWork()

    #expect(coordinator.operations.values.first?.state == .succeeded)
    #expect(await executor.reconciliationCount == 2)
  }

  @Test @MainActor
  func refreshedSnapshotSupersedesAStalledReconciliation() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.uncertain, for: "stalled")
    await executor.suspendReconciliation(for: "stalled")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(executor: executor, toasts: toasts)
    let command = deletionCommand(recordID: "stalled")

    coordinator.schedule(command)
    coordinator.commitPendingOperations()
    await executor.waitForReconciliationCount(1)

    coordinator.reconcileDNSRecords(
      accountID: "account-1",
      zoneID: "zone-1",
      serverRecordIDs: ["stalled"],
      isCompleteSnapshot: false)
    await coordinator.waitForActiveWork()

    #expect(coordinator.operations.values.first?.state == .failed)
    #expect(!coordinator.isPendingDeletion(command.resourceKey))
    #expect(toasts.current?.dismissBehavior == .automatic)

    await executor.resumeReconciliation(for: "stalled")
    await Task.yield()

    #expect(coordinator.operations.values.first?.state == .failed)
    #expect(!coordinator.isPendingDeletion(command.resourceKey))
  }

  @Test @MainActor
  func listStartedBeforeDeleteCannotResolveItsUncertainOutcome() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.uncertain, for: "pre-delete-list")
    await executor.suspendReconciliation(for: "pre-delete-list")
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: DashToastCenter())
    let command = deletionCommand(recordID: "pre-delete-list")
    let scope = DeferredDeletionScope(accountID: "account-1", zoneID: "zone-1")
    let staleLoadGeneration = coordinator.beginDNSLoad(for: scope)

    coordinator.schedule(command)
    coordinator.commitPendingOperations()
    await executor.waitForReconciliationCount(1)

    coordinator.reconcileDNSRecords(
      accountID: "account-1",
      zoneID: "zone-1",
      serverRecordIDs: ["pre-delete-list"],
      isCompleteSnapshot: true,
      loadGeneration: staleLoadGeneration)

    #expect(coordinator.operations.values.first?.state == .reconciling)
    #expect(coordinator.isPendingDeletion(command.resourceKey))

    await executor.resumeReconciliation(for: "pre-delete-list")
    await coordinator.waitForActiveWork()

    #expect(coordinator.operations.values.first?.state == .succeeded)
    #expect(coordinator.isPendingDeletion(command.resourceKey))
  }

  @Test @MainActor
  func completeSnapshotResolutionRequestsRefreshForOtherMountedDNSViews() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.uncertain, for: "cross-view-refresh")
    await executor.suspendReconciliation(for: "cross-view-refresh")
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: DashToastCenter())
    let command = deletionCommand(recordID: "cross-view-refresh")
    let scope = DeferredDeletionScope(accountID: "account-1", zoneID: "zone-1")

    coordinator.schedule(command)
    coordinator.commitPendingOperations()
    await executor.waitForReconciliationCount(1)
    let loadGeneration = coordinator.beginDNSLoad(for: scope)

    coordinator.reconcileDNSRecords(
      accountID: "account-1",
      zoneID: "zone-1",
      serverRecordIDs: [],
      isCompleteSnapshot: true,
      loadGeneration: loadGeneration)

    #expect(coordinator.operations.values.first?.state == .succeeded)
    #expect(coordinator.refreshGeneration(for: scope) > 0)

    await executor.resumeReconciliation(for: "cross-view-refresh")
    await coordinator.waitForActiveWork()
  }

  @Test @MainActor
  func reconciliationThatFindsResourceRestoresIt() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.uncertain, for: "exists")
    await executor.setReconciliationOutcome(.resourceExists, for: "exists")
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: DashToastCenter())
    let command = deletionCommand(recordID: "exists")

    coordinator.schedule(command)
    coordinator.commitPendingOperations()
    await coordinator.waitForActiveWork()

    #expect(coordinator.operations.values.first?.state == .failed)
    #expect(!coordinator.isPendingDeletion(command.resourceKey))
  }

  @Test @MainActor
  func missingDeleteResponseIsSuccessAndCompleteRefreshClearsTheTombstone() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.missing, for: "missing")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: toasts)
    let command = deletionCommand(recordID: "missing")

    coordinator.schedule(command)
    coordinator.reconcileDNSRecords(
      accountID: "account-1",
      zoneID: "zone-1",
      serverRecordIDs: ["missing"],
      isCompleteSnapshot: true)

    #expect(coordinator.isPendingDeletion(command.resourceKey))
    #expect(await executor.executionCount == 0)

    coordinator.commitPendingOperations()
    await coordinator.waitForActiveWork()

    #expect(coordinator.operations.values.first?.state == .succeeded)
    #expect(coordinator.isPendingDeletion(command.resourceKey))

    coordinator.reconcileDNSRecords(
      accountID: "account-1",
      zoneID: "zone-1",
      serverRecordIDs: [],
      isCompleteSnapshot: true)

    #expect(coordinator.operations.values.first?.state == .succeeded)
    toasts.dismiss(id: .deferredDeletionBatch)
    #expect(coordinator.operations.isEmpty)
    #expect(!coordinator.isPendingDeletion(command.resourceKey))
  }

  @Test @MainActor
  func successfulDeleteThatStillExistsAfterRefreshRestoresTheResource() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setReconciliationOutcome(.resourceExists, for: "still-exists")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: toasts)
    let command = deletionCommand(recordID: "still-exists")

    coordinator.schedule(command)
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)
    await coordinator.waitForActiveWork()
    #expect(coordinator.operations.values.first?.state == .succeeded)

    coordinator.reconcileDNSRecords(
      accountID: "account-1",
      zoneID: "zone-1",
      serverRecordIDs: ["still-exists"],
      isCompleteSnapshot: true)
    await executor.waitForReconciliationCount(1)
    for _ in 0..<50 where coordinator.operations.values.first?.state != .failed {
      await Task.yield()
    }

    #expect(coordinator.operations.values.first?.state == .failed)
    #expect(!coordinator.isPendingDeletion(command.resourceKey))
    #expect(toasts.current?.kind == .error)
    #expect(
      toasts.current?.action
        == .retryDeferredDeletions(Array(coordinator.operations.keys)))
  }

  @Test @MainActor
  func dismissedSuccessThatIsCorrectedToFailureGetsFreshRetryFeedback() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setReconciliationOutcome(.resourceExists, for: "late-failure")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(executor: executor, toasts: toasts)
    let command = deletionCommand(recordID: "late-failure")
    let operationID = coordinator.schedule(command)!

    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)
    await coordinator.waitForActiveWork()
    #expect(toasts.current?.kind == .success)
    toasts.dismiss(id: .deferredDeletionBatch)

    coordinator.reconcileDNSRecords(
      accountID: "account-1",
      zoneID: "zone-1",
      serverRecordIDs: ["late-failure"],
      isCompleteSnapshot: true)
    await executor.waitForReconciliationCount(1)
    for _ in 0..<50 where coordinator.operations[operationID]?.state != .failed {
      await Task.yield()
    }

    #expect(coordinator.operations[operationID]?.state == .failed)
    #expect(toasts.current?.action == .retryDeferredDeletions([operationID]))

    coordinator.refreshLocalizedPresentation()
    #expect(toasts.current?.action == .retryDeferredDeletions([operationID]))
  }

  @Test @MainActor
  func serverFailureUsesReadOnlyReconciliationBeforeDecidingTheOutcome() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setExecutionOutcome(.serverFailure, for: "server-error")
    await executor.setReconciliationOutcome(.resourceMissing, for: "server-error")
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: DashToastCenter())
    let command = deletionCommand(recordID: "server-error")

    coordinator.schedule(command)
    coordinator.commitPendingOperations()
    await coordinator.waitForActiveWork()

    #expect(await executor.executionCount == 1)
    #expect(await executor.reconciliationCount == 1)
    #expect(coordinator.operations.values.first?.state == .succeeded)
    #expect(coordinator.isPendingDeletion(command.resourceKey))
  }

}
