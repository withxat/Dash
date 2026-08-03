import CloudflareAPI
import Foundation
import Testing
import UIKit

@testable import Dash

@Suite(.serialized)
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
    await Task.yield()
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
    await Task.yield()
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

  @Test @MainActor
  func journalPersistsOnlyStartedWorkAndRestoresByCredentialProfile() async throws {
    let sourceDefaults = testDefaults()
    defer { clearTestDefaults(sourceDefaults) }
    let sourceExecutor = DeferredDeletionScenarioExecutor()
    await sourceExecutor.setExecutionOutcome(.uncertain, for: "persisted")
    await sourceExecutor.setReconciliationOutcome(.failure, for: "persisted")
    let source = DeferredDeletionCoordinator(
      executor: sourceExecutor,
      toasts: DashToastCenter(),
      persistence: sourceDefaults,
      requiresCredentialActivation: true)
    source.activateCredential(profileID: "person-1", availableAccountIDs: ["account-1"])
    let command = deletionCommand(recordID: "persisted")

    source.schedule(command)
    #expect(sourceDefaults.data(forKey: persistenceKey) == nil)
    source.commitPendingOperations()
    await source.waitForActiveWork()

    let journal = try #require(sourceDefaults.data(forKey: persistenceKey))

    let matchingDefaults = testDefaults()
    defer { clearTestDefaults(matchingDefaults) }
    matchingDefaults.set(journal, forKey: persistenceKey)
    let matchingExecutor = DeferredDeletionScenarioExecutor()
    let matching = DeferredDeletionCoordinator(
      executor: matchingExecutor,
      toasts: DashToastCenter(),
      persistence: matchingDefaults,
      requiresCredentialActivation: true)
    matching.activateCredential(profileID: "person-1", availableAccountIDs: ["account-1"])
    await matchingExecutor.waitForReconciliationCount(1)
    await matching.waitForActiveWork()

    #expect(await matchingExecutor.executionCount == 0)
    #expect(await matchingExecutor.reconciliationCount == 1)
    #expect(matching.operations.values.first?.state == .succeeded)
    #expect(matchingDefaults.data(forKey: persistenceKey) == nil)

    let mismatchDefaults = testDefaults()
    defer { clearTestDefaults(mismatchDefaults) }
    mismatchDefaults.set(journal, forKey: persistenceKey)
    let mismatchExecutor = DeferredDeletionScenarioExecutor()
    let mismatch = DeferredDeletionCoordinator(
      executor: mismatchExecutor,
      toasts: DashToastCenter(),
      persistence: mismatchDefaults,
      requiresCredentialActivation: true)
    mismatch.activateCredential(profileID: "person-2", availableAccountIDs: ["account-1"])
    await Task.yield()

    #expect(await mismatchExecutor.executionCount == 0)
    #expect(await mismatchExecutor.reconciliationCount == 0)
    #expect(mismatch.tombstones.isEmpty)
    #expect(mismatchDefaults.data(forKey: persistenceKey) == nil)
  }

  @Test @MainActor
  func coldStartJournalSurvivesReauthenticationBeforeIdentityLoads() async throws {
    let defaults = testDefaults()
    defer { clearTestDefaults(defaults) }
    let sourceExecutor = DeferredDeletionScenarioExecutor()
    await sourceExecutor.setExecutionOutcome(.uncertain, for: "cold-reauth")
    await sourceExecutor.setReconciliationOutcome(.failure, for: "cold-reauth")
    let source = DeferredDeletionCoordinator(
      executor: sourceExecutor,
      toasts: DashToastCenter(),
      persistence: defaults,
      requiresCredentialActivation: true)
    source.activateCredential(profileID: "person-1", availableAccountIDs: ["account-1"])
    source.schedule(deletionCommand(recordID: "cold-reauth"))
    source.commitPendingOperations()
    await source.waitForActiveWork()
    #expect(defaults.data(forKey: persistenceKey) != nil)

    let restoredExecutor = DeferredDeletionScenarioExecutor()
    let restored = DeferredDeletionCoordinator(
      executor: restoredExecutor,
      toasts: DashToastCenter(),
      persistence: defaults,
      requiresCredentialActivation: true)

    await restored.prepareForCredentialReplacement()
    #expect(defaults.data(forKey: persistenceKey) != nil)
    restored.discardUnverifiedCredentialStatePreservingRecovery()
    #expect(defaults.data(forKey: persistenceKey) != nil)

    restored.activateCredential(
      profileID: "person-1",
      availableAccountIDs: ["account-1"])
    await restoredExecutor.waitForReconciliationCount(1)
    await restored.waitForActiveWork()

    #expect(await restoredExecutor.executionCount == 0)
    #expect(await restoredExecutor.reconciliationCount == 1)
    #expect(restored.operations.values.first?.state == .succeeded)
  }

  @Test @MainActor
  func coldStartJournalSurvivesUnauthenticatedBootstrap() async {
    let defaults = testDefaults()
    defer { clearTestDefaults(defaults) }
    let sourceExecutor = DeferredDeletionScenarioExecutor()
    await sourceExecutor.setExecutionOutcome(.uncertain, for: "cold-bootstrap")
    await sourceExecutor.setReconciliationOutcome(.failure, for: "cold-bootstrap")
    let source = DeferredDeletionCoordinator(
      executor: sourceExecutor,
      toasts: DashToastCenter(),
      persistence: defaults,
      requiresCredentialActivation: true)
    source.activateCredential(profileID: "person-1", availableAccountIDs: ["account-1"])
    source.schedule(deletionCommand(recordID: "cold-bootstrap"))
    source.commitPendingOperations()
    await source.waitForActiveWork()
    #expect(defaults.data(forKey: persistenceKey) != nil)

    let restoredExecutor = DeferredDeletionScenarioExecutor()
    let restored = DeferredDeletionCoordinator(
      executor: restoredExecutor,
      toasts: DashToastCenter(),
      persistence: defaults,
      requiresCredentialActivation: true)
    restored.discardUnverifiedCredentialStatePreservingRecovery()
    #expect(defaults.data(forKey: persistenceKey) != nil)

    restored.activateCredential(
      profileID: "person-1",
      availableAccountIDs: ["account-1"])
    await restoredExecutor.waitForReconciliationCount(1)
    await restored.waitForActiveWork()

    #expect(await restoredExecutor.executionCount == 0)
    #expect(await restoredExecutor.reconciliationCount == 1)
    #expect(restored.operations.values.first?.state == .succeeded)
  }

  @Test @MainActor
  func identityDirectlyRecoversAnAccountOmittedFromTheListBeforeReconcilingItsJournal()
    async throws
  {
    let defaults = testDefaults()
    defer { clearTestDefaults(defaults) }
    let sourceExecutor = DeferredDeletionScenarioExecutor()
    await sourceExecutor.setExecutionOutcome(.uncertain, for: "omitted-account")
    await sourceExecutor.setReconciliationOutcome(.failure, for: "omitted-account")
    let source = DeferredDeletionCoordinator(
      executor: sourceExecutor,
      toasts: DashToastCenter(),
      persistence: defaults,
      requiresCredentialActivation: true)
    source.activateCredential(profileID: "person-1", availableAccountIDs: ["account-1"])
    source.schedule(deletionCommand(recordID: "omitted-account"))
    source.commitPendingOperations()
    await source.waitForActiveWork()
    #expect(defaults.data(forKey: persistenceKey) != nil)

    let savedActiveAccountID = UserDefaults.standard.object(forKey: "dash.active_account_id")
    UserDefaults.standard.set("account-2", forKey: "dash.active_account_id")
    defer {
      if let savedActiveAccountID {
        UserDefaults.standard.set(savedActiveAccountID, forKey: "dash.active_account_id")
      } else {
        UserDefaults.standard.removeObject(forKey: "dash.active_account_id")
      }
    }
    let requests = DeferredDeletionRequestRecorder()
    let session = deferredDeletionMockSession { request in
      requests.record(request)
      let path = request.url?.path ?? ""
      if path.hasSuffix("/user") {
        return (
          200,
          Data(
            #"""
            {"success":true,"errors":[],"result":{"id":"person-1","email":"person@example.com"}}
            """#.utf8)
        )
      }
      if path.hasSuffix("/accounts/account-1") {
        return (
          200,
          Data(
            #"""
            {"success":true,"errors":[],"result":{"id":"account-1","name":"Recovered"}}
            """#.utf8)
        )
      }
      if path.hasSuffix("/accounts") {
        return (
          200,
          Data(
            #"""
            {"success":true,"errors":[],"result":[{"id":"account-2","name":"Listed"}],"result_info":{"page":1,"per_page":50,"total_count":1}}
            """#.utf8)
        )
      }
      if path.hasSuffix("/zones/zone-1/dns_records/omitted-account") {
        return (
          404,
          Data(#"{"success":false,"errors":[],"result":null}"#.utf8)
        )
      }
      return (500, Data(#"{"success":false,"errors":[],"result":null}"#.utf8))
    }
    let model = AppModel(
      configuration: AppConfiguration(clientID: "test", redirectURI: "dash://oauth/callback"),
      tokenStore: DemoTokenStore(),
      session: session,
      deferredDeletionPersistence: defaults)

    try await model.loadIdentity()
    await model.deferredDeletions.waitForActiveWork()

    #expect(Set(model.accounts.map(\.id)) == ["account-1", "account-2"])
    #expect(
      model.deferredDeletions.operations.values.first?.state == .succeeded)
    #expect(requests.methods.allSatisfy { $0 != "DELETE" })
  }

  @Test @MainActor
  func failedCredentialRollbackKeepsRecoveryFrozenAndNeverExecutesIt() async {
    let defaults = testDefaults()
    defer { clearTestDefaults(defaults) }
    let sourceExecutor = DeferredDeletionScenarioExecutor()
    await sourceExecutor.setExecutionOutcome(.uncertain, for: "rollback-failure")
    await sourceExecutor.setReconciliationOutcome(.failure, for: "rollback-failure")
    let source = DeferredDeletionCoordinator(
      executor: sourceExecutor,
      toasts: DashToastCenter(),
      persistence: defaults,
      requiresCredentialActivation: true)
    source.activateCredential(profileID: "person-1", availableAccountIDs: ["account-1"])
    source.schedule(deletionCommand(recordID: "rollback-failure"))
    source.commitPendingOperations()
    await source.waitForActiveWork()
    let journal = defaults.data(forKey: persistenceKey)
    #expect(journal != nil)

    let model = AppModel(
      configuration: AppConfiguration(clientID: "test", redirectURI: "dash://oauth/callback"),
      tokenStore: FailingReplacementTokenStore(),
      deferredDeletionPersistence: defaults)
    let restored = await model.restoreCredentialAfterFailedReplacement(
      previousTokens: TokenSet(accessToken: "old", refreshToken: "old-refresh"),
      previousScopes: ["dns.read", "dns.write"],
      previousProfileID: "person-1",
      previousAccountIDs: ["account-1"])

    #expect(!restored)
    #expect(defaults.data(forKey: persistenceKey) == journal)
    #expect(
      model.deferredDeletions.recoveryAccountIDs(forCredentialProfileID: "person-1")
        == ["account-1"])
    #expect(model.deferredDeletions.schedule(deletionCommand(recordID: "must-not-run")) == nil)
  }

  @Test @MainActor
  func exchangeFailureBeforeReplacementLeavesCredentialAndDeletionStateUntouched() async {
    let tokenStore = CredentialMutationTrackingTokenStore(
      accessToken: "old",
      refreshToken: "old-refresh")
    let model = AppModel(
      configuration: AppConfiguration(clientID: "test", redirectURI: "dash://oauth/callback"),
      tokenStore: tokenStore,
      deferredDeletionPersistence: nil)
    model.deferredDeletions.activateCredential(
      profileID: "person-1",
      availableAccountIDs: ["account-1"])
    let firstCommand = deletionCommand(recordID: "pending-before-exchange")
    let firstID = model.deferredDeletions.schedule(firstCommand)!

    let preserved = await model.handleCredentialReplacementFailure(
      replacementPrepared: false,
      preservesExistingSession: true,
      previousTokens: TokenSet(accessToken: "old", refreshToken: "old-refresh"),
      previousScopes: ["dns.read", "dns.write"],
      previousProfileID: "person-1",
      previousAccountIDs: ["account-1"])

    #expect(preserved)
    #expect(await tokenStore.mutationCounts == .init(clear: 0, set: 0))
    #expect(model.deferredDeletions.operations[firstID]?.state == .pending)
    #expect(model.deferredDeletions.isPendingDeletion(firstCommand.resourceKey))
    #expect(
      model.deferredDeletions.schedule(deletionCommand(recordID: "still-schedulable")) != nil)
    model.deferredDeletions.undoCurrentBatch()
  }

  @Test @MainActor
  func demoDeferredDeletionUsesTheDemoBackendInsteadOfTheRealCredentialClient() async throws {
    let savedActiveAccountID = UserDefaults.standard.object(forKey: "dash.active_account_id")
    UserDefaults.standard.removeObject(forKey: "dash.active_account_id")
    defer {
      if let savedActiveAccountID {
        UserDefaults.standard.set(savedActiveAccountID, forKey: "dash.active_account_id")
      } else {
        UserDefaults.standard.removeObject(forKey: "dash.active_account_id")
      }
    }
    let realRequests = DeferredDeletionRequestRecorder()
    let realSession = deferredDeletionMockSession { request in
      realRequests.record(request)
      return (500, Data(#"{"success":false,"errors":[],"result":null}"#.utf8))
    }
    let model = AppModel(
      configuration: AppConfiguration(clientID: "test", redirectURI: "dash://oauth/callback"),
      tokenStore: DemoTokenStore(),
      session: realSession,
      deferredDeletionPersistence: nil)
    model.authState = .unauthenticated

    model.enterDemo()
    for _ in 0..<100 where model.authState != .authenticated {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.authState == .authenticated)

    let operationID = model.deferredDeletions.schedule(
      deletionCommand(recordID: "demo-write", accountID: DemoBackend.accountID))
    let id = try #require(operationID)
    model.deferredDeletions.commitPendingOperations()
    await model.deferredDeletions.waitForActiveWork()

    #expect(model.deferredDeletions.operations[id]?.state == .failed)
    #expect(realRequests.methods.isEmpty)
  }

  @Test @MainActor
  func coldStartJournalSurvivesDemoAndReconcilesAfterReturningToOriginalProfile() async throws {
    let defaults = testDefaults()
    defer { clearTestDefaults(defaults) }
    let sourceExecutor = DeferredDeletionScenarioExecutor()
    await sourceExecutor.setExecutionOutcome(.uncertain, for: "demo-recovery")
    await sourceExecutor.setReconciliationOutcome(.failure, for: "demo-recovery")
    let source = DeferredDeletionCoordinator(
      executor: sourceExecutor,
      toasts: DashToastCenter(),
      persistence: defaults,
      requiresCredentialActivation: true)
    source.activateCredential(profileID: "person-1", availableAccountIDs: ["account-1"])
    source.schedule(deletionCommand(recordID: "demo-recovery"))
    source.commitPendingOperations()
    await source.waitForActiveWork()
    let journal = try #require(defaults.data(forKey: persistenceKey))

    let savedActiveAccountID = UserDefaults.standard.object(forKey: "dash.active_account_id")
    UserDefaults.standard.removeObject(forKey: "dash.active_account_id")
    defer {
      if let savedActiveAccountID {
        UserDefaults.standard.set(savedActiveAccountID, forKey: "dash.active_account_id")
      } else {
        UserDefaults.standard.removeObject(forKey: "dash.active_account_id")
      }
    }
    let realRequests = DeferredDeletionRequestRecorder()
    let realSession = deferredDeletionMockSession { request in
      realRequests.record(request)
      let path = request.url?.path ?? ""
      if path.hasSuffix("/user") {
        return (
          200,
          Data(
            #"""
            {"success":true,"errors":[],"result":{"id":"person-1","email":"person@example.com"}}
            """#.utf8)
        )
      }
      if path.hasSuffix("/accounts") {
        return (
          200,
          Data(
            #"""
            {"success":true,"errors":[],"result":[{"id":"account-1","name":"Recovered"}],"result_info":{"page":1,"per_page":50,"total_count":1}}
            """#.utf8)
        )
      }
      if path.hasSuffix("/zones/zone-1/dns_records/demo-recovery") {
        return (
          404,
          Data(#"{"success":false,"errors":[],"result":null}"#.utf8)
        )
      }
      return (500, Data(#"{"success":false,"errors":[],"result":null}"#.utf8))
    }
    let tokenStore = CredentialMutationTrackingTokenStore(
      accessToken: nil,
      refreshToken: nil)
    let model = AppModel(
      configuration: AppConfiguration(clientID: "test", redirectURI: "dash://oauth/callback"),
      tokenStore: tokenStore,
      session: realSession,
      deferredDeletionPersistence: defaults)

    await model.bootstrap()
    #expect(model.authState == .unauthenticated)
    #expect(defaults.data(forKey: persistenceKey) == journal)
    model.enterDemo()
    for _ in 0..<100 where model.authState != .authenticated {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.authState == .authenticated)
    #expect(defaults.data(forKey: persistenceKey) == journal)

    let demoOperationID = try #require(
      model.deferredDeletions.schedule(
        deletionCommand(recordID: "demo-write", accountID: DemoBackend.accountID)))
    model.deferredDeletions.commitPendingOperations()
    await model.deferredDeletions.waitForActiveWork()
    #expect(model.deferredDeletions.operations[demoOperationID]?.state == .failed)
    #expect(defaults.data(forKey: persistenceKey) == journal)
    #expect(realRequests.methods.isEmpty)

    await model.signOut()
    #expect(defaults.data(forKey: persistenceKey) == journal)

    await tokenStore.setTokens(
      TokenSet(accessToken: "real", refreshToken: "real-refresh"))
    try await model.loadIdentity()
    await model.deferredDeletions.waitForActiveWork()

    #expect(model.deferredDeletions.operations.values.first?.state == .succeeded)
    #expect(defaults.data(forKey: persistenceKey) == nil)
    #expect(realRequests.methods.allSatisfy { $0 == "GET" })
    #expect(
      realRequests.paths.contains {
        $0.hasSuffix("/zones/zone-1/dns_records/demo-recovery")
      })
  }

  @Test @MainActor
  func successfulDeleteKeepsItsTombstoneAcrossSameProfileCredentialReplacement() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.setReconciliationOutcome(.failure, for: "success-handoff")
    let toasts = DashToastCenter()
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: toasts,
      requiresCredentialActivation: true)
    coordinator.activateCredential(profileID: "person-1", availableAccountIDs: ["account-1"])
    let command = deletionCommand(recordID: "success-handoff")

    coordinator.schedule(command)
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)
    await coordinator.waitForActiveWork()
    #expect(coordinator.operations.values.first?.state == .succeeded)
    #expect(coordinator.isPendingDeletion(command.resourceKey))

    await coordinator.prepareForCredentialReplacement()
    #expect(coordinator.operations.isEmpty)

    coordinator.activateCredential(
      profileID: "person-1",
      availableAccountIDs: ["account-1"])
    await executor.waitForReconciliationCount(1)
    await Task.yield()

    #expect(await executor.executionCount == 1)
    #expect(coordinator.operations.values.first?.state == .succeeded)
    #expect(coordinator.isPendingDeletion(command.resourceKey))
    #expect(
      coordinator.refreshGeneration(
        for: DeferredDeletionScope(accountID: "account-1", zoneID: "zone-1")) > 0)

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
  func credentialReplacementWaitsForStartedDeleteBeforeClearingItsState() async {
    let executor = DeferredDeletionScenarioExecutor()
    await executor.suspendExecution(for: "in-flight")
    let coordinator = DeferredDeletionCoordinator(
      executor: executor,
      toasts: DashToastCenter(),
      requiresCredentialActivation: true)
    coordinator.activateCredential(profileID: "person-1", availableAccountIDs: ["account-1"])
    let command = deletionCommand(recordID: "in-flight")

    coordinator.schedule(command)
    coordinator.commitPendingOperations()
    await executor.waitForExecutionCount(1)

    var replacementFinished = false
    let replacement = Task { @MainActor in
      await coordinator.prepareForCredentialReplacement()
      replacementFinished = true
    }
    await Task.yield()
    replacement.cancel()
    await Task.yield()

    #expect(!replacementFinished)
    #expect(coordinator.isPendingDeletion(command.resourceKey))

    await executor.resumeExecution(for: "in-flight")
    await replacement.value

    #expect(replacementFinished)
    #expect(await executor.executionCount == 1)
    #expect(coordinator.operations.isEmpty)
    #expect(coordinator.tombstones.isEmpty)
  }

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
    await Task.yield()

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

private let persistenceKey = "dash.deferred_deletions.reconciling"

private final class DeferredDeletionDateBox: @unchecked Sendable {
  var value: Date

  init(_ value: Date) {
    self.value = value
  }
}

private func deletionCommand(
  recordID: String = "record-1",
  accountID: String = "account-1"
) -> DeferredDeleteCommand {
  .dnsRecord(
    accountID: accountID,
    zoneID: "zone-1",
    recordID: recordID,
    recordType: "A",
    displayName: "api.example.com")
}

private enum DeferredDeletionScenarioError: Error {
  case reconciliationFailed
}

private actor DeferredDeletionScenarioExecutor: DeferredDeletionExecuting {
  enum ExecutionOutcome: Sendable {
    case success
    case failure
    case missing
    case uncertain
    case serverFailure
  }

  enum ReconciliationOutcome: Sendable {
    case resourceExists
    case resourceMissing
    case failure
  }

  private var executionOutcomes: [String: ExecutionOutcome] = [:]
  private var reconciliationOutcomes: [String: ReconciliationOutcome] = [:]
  private var suspendedExecutions: Set<String> = []
  private var suspendedReconciliations: Set<String> = []
  private var executionContinuations: [String: CheckedContinuation<Void, Never>] = [:]
  private var reconciliationContinuations: [String: CheckedContinuation<Void, Never>] = [:]
  private var executionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var reconciliationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private(set) var executed: [DeferredDeleteCommand] = []
  private(set) var reconciled: [DeferredDeleteCommand] = []

  var executionCount: Int { executed.count }
  var reconciliationCount: Int { reconciled.count }

  func setExecutionOutcome(_ outcome: ExecutionOutcome, for recordID: String) {
    executionOutcomes[recordID] = outcome
  }

  func setReconciliationOutcome(_ outcome: ReconciliationOutcome, for recordID: String) {
    reconciliationOutcomes[recordID] = outcome
  }

  func suspendExecution(for recordID: String) {
    suspendedExecutions.insert(recordID)
  }

  func suspendReconciliation(for recordID: String) {
    suspendedReconciliations.insert(recordID)
  }

  func resumeExecution(for recordID: String) {
    suspendedExecutions.remove(recordID)
    executionContinuations.removeValue(forKey: recordID)?.resume()
  }

  func resumeReconciliation(for recordID: String) {
    suspendedReconciliations.remove(recordID)
    reconciliationContinuations.removeValue(forKey: recordID)?.resume()
  }

  func waitForExecutionCount(_ count: Int) async {
    guard executionCount < count else { return }
    await withCheckedContinuation { continuation in
      executionWaiters.append((count, continuation))
    }
  }

  func waitForReconciliationCount(_ count: Int) async {
    guard reconciliationCount < count else { return }
    await withCheckedContinuation { continuation in
      reconciliationWaiters.append((count, continuation))
    }
  }

  func execute(_ command: DeferredDeleteCommand) async throws {
    let recordID = command.resourceKey.resourceID
    executed.append(command)
    resumeSatisfiedExecutionWaiters()
    if suspendedExecutions.contains(recordID) {
      await withCheckedContinuation { continuation in
        executionContinuations[recordID] = continuation
      }
    }
    switch executionOutcomes[recordID] ?? .success {
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
    case .serverFailure:
      throw CloudflareAPIError.request(status: 503, errors: [])
    }
  }

  func reconcile(_ command: DeferredDeleteCommand) async throws
    -> DeferredDeletionReconciliationResult
  {
    let recordID = command.resourceKey.resourceID
    reconciled.append(command)
    resumeSatisfiedReconciliationWaiters()
    if suspendedReconciliations.contains(recordID) {
      await withCheckedContinuation { continuation in
        reconciliationContinuations[recordID] = continuation
      }
    }
    switch reconciliationOutcomes[recordID] ?? .resourceMissing {
    case .resourceExists:
      return .resourceExists
    case .resourceMissing:
      return .resourceMissing
    case .failure:
      throw DeferredDeletionScenarioError.reconciliationFailed
    }
  }

  private func resumeSatisfiedExecutionWaiters() {
    let ready = executionWaiters.filter { executionCount >= $0.0 }
    executionWaiters.removeAll { executionCount >= $0.0 }
    for (_, continuation) in ready { continuation.resume() }
  }

  private func resumeSatisfiedReconciliationWaiters() {
    let ready = reconciliationWaiters.filter { reconciliationCount >= $0.0 }
    reconciliationWaiters.removeAll { reconciliationCount >= $0.0 }
    for (_, continuation) in ready { continuation.resume() }
  }
}

private actor DeferredDeletionManualSleeper {
  private var registrations = 0
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

private func testDefaults() -> UserDefaults {
  let suiteName = "DeferredDeletionTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defaults.removePersistentDomain(forName: suiteName)
  return defaults
}

private func clearTestDefaults(_ defaults: UserDefaults) {
  for key in defaults.dictionaryRepresentation().keys {
    defaults.removeObject(forKey: key)
  }
}

private actor FailingReplacementTokenStore: TokenStore {
  enum Failure: Error {
    case cannotWrite
  }

  func clear() {}
  func getAccessToken() -> String? { nil }
  func getRefreshToken() -> String? { nil }
  func setTokens(_: TokenSet) throws { throw Failure.cannotWrite }
}

private actor CredentialMutationTrackingTokenStore: TokenStore {
  struct MutationCounts: Equatable {
    let clear: Int
    let set: Int
  }

  private var accessToken: String?
  private var refreshToken: String?
  private var clearCount = 0
  private var setCount = 0

  init(accessToken: String?, refreshToken: String?) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
  }

  var mutationCounts: MutationCounts {
    MutationCounts(clear: clearCount, set: setCount)
  }

  func clear() {
    clearCount += 1
    accessToken = nil
    refreshToken = nil
  }

  func getAccessToken() -> String? { accessToken }
  func getRefreshToken() -> String? { refreshToken }

  func setTokens(_ tokens: TokenSet) {
    setCount += 1
    accessToken = tokens.accessToken
    refreshToken = tokens.refreshToken
  }
}

private final class DeferredDeletionRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedMethods: [String] = []
  private var recordedPaths: [String] = []

  var methods: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recordedMethods
  }

  var paths: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recordedPaths
  }

  func record(_ request: URLRequest) {
    lock.lock()
    recordedMethods.append(request.httpMethod ?? "GET")
    recordedPaths.append(request.url?.path ?? "")
    lock.unlock()
  }
}

private final class DeferredDeletionURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let (status, data) = try Self.handler?(request) ?? (500, Data())
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: nil,
        headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private func deferredDeletionMockSession(
  handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)
) -> URLSession {
  DeferredDeletionURLProtocol.handler = handler
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [DeferredDeletionURLProtocol.self]
  return URLSession(configuration: configuration)
}
