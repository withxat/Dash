import CloudflareAPI
import Foundation
import Testing
import UIKit

@testable import Dash

extension DeferredDeletionCoordinatorCoverageTests {
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
    for _ in 0..<100 where model.isEnteringDemo {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.isEnteringDemo)
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

    // Cold-start restoration happens in AppModel.init. Keep this journal test
    // independent of bootstrap's live Widget and File Provider teardown,
    // which is a separate privacy boundary with its own coverage.
    model.authState = .unauthenticated
    #expect(defaults.data(forKey: persistenceKey) == journal)
    model.enterDemo()
    for _ in 0..<100 where model.isEnteringDemo {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.isEnteringDemo)
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
}
