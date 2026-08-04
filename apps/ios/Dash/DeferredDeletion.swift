import CloudflareAPI
import Foundation
import Observation

enum DestructiveExecutionPolicy: Equatable, Sendable {
  case deferredDeletion(gracePeriod: Duration)
  case confirmThenExecuteImmediately
  case typeResourceNameThenExecute
  case reauthenticateThenExecute

  static let dnsRecord: Self = .deferredDeletion(gracePeriod: .seconds(5))
}

enum DeferredDeletionResourceKind: Codable, Hashable, Sendable {
  case dnsRecord
}

struct DeferredDeletionResourceKey: Codable, Hashable, Sendable {
  let kind: DeferredDeletionResourceKind
  let accountID: String
  let zoneID: String?
  let resourceID: String
}

struct DeferredDeletionScope: Hashable, Sendable {
  let accountID: String
  let zoneID: String?
}

enum DeferredDeleteCommand: Codable, Hashable, Sendable {
  case dnsRecord(
    accountID: String,
    zoneID: String,
    recordID: String,
    recordType: String,
    displayName: String
  )

  var resourceKey: DeferredDeletionResourceKey {
    switch self {
    case .dnsRecord(let accountID, let zoneID, let recordID, _, _):
      DeferredDeletionResourceKey(
        kind: .dnsRecord,
        accountID: accountID,
        zoneID: zoneID,
        resourceID: recordID)
    }
  }

  var scope: DeferredDeletionScope {
    DeferredDeletionScope(
      accountID: resourceKey.accountID,
      zoneID: resourceKey.zoneID)
  }

  var displayName: String {
    switch self {
    case .dnsRecord(_, _, _, let recordType, let displayName):
      "\(recordType) · \(displayName)"
    }
  }

  var deletionSubject: String {
    switch self {
    case .dnsRecord(_, _, _, let recordType, let displayName):
      DashL10n.string("\(recordType) record \(displayName)")
    }
  }

  var executionPolicy: DestructiveExecutionPolicy {
    switch self {
    case .dnsRecord:
      .dnsRecord
    }
  }
}

struct PendingDeletion: Identifiable, Sendable {
  enum State: Equatable, Sendable {
    case pending
    case committing
    case succeeded
    case cancelled
    case failed
    case reconciling
  }

  let id: UUID
  let command: DeferredDeleteCommand
  let createdAt: Date
  var deadline: Date
  var state: State
  var batchID: UUID
  let credentialProfileID: String?
  let credentialGeneration: UInt64
  var executionAttempt: UInt64
  var reconciliationAttempt: UInt64
  var minimumDNSLoadGeneration: UInt64
  var retryEligible: Bool
}

enum DeferredDeletionReconciliationResult: Sendable {
  case resourceExists
  case resourceMissing
}

protocol DeferredDeletionExecuting: Sendable {
  func execute(_ command: DeferredDeleteCommand) async throws
  func reconcile(_ command: DeferredDeleteCommand) async throws
    -> DeferredDeletionReconciliationResult
}

final class CloudflareDeferredDeletionExecutor: DeferredDeletionExecuting, @unchecked Sendable {
  private let lock = NSLock()
  private var client: CloudflareClient

  init(client: CloudflareClient) {
    self.client = client
  }

  func replaceClient(_ client: CloudflareClient) {
    lock.lock()
    self.client = client
    lock.unlock()
  }

  func execute(_ command: DeferredDeleteCommand) async throws {
    let client = currentClient()
    switch command {
    case .dnsRecord(_, let zoneID, let recordID, _, _):
      try await client.deleteDNSRecord(zoneID: zoneID, recordID: recordID)
    }
  }

  func reconcile(_ command: DeferredDeleteCommand) async throws
    -> DeferredDeletionReconciliationResult
  {
    let client = currentClient()
    switch command {
    case .dnsRecord(_, let zoneID, let recordID, _, _):
      do {
        _ = try await client.getDNSRecord(zoneID: zoneID, recordID: recordID)
        return .resourceExists
      } catch let error as CloudflareAPIError where error.isMissingResource {
        return .resourceMissing
      }
    }
  }

  private func currentClient() -> CloudflareClient {
    lock.lock()
    defer { lock.unlock() }
    return client
  }
}

@MainActor
@Observable
final class DeferredDeletionCoordinator {
  private(set) var tombstones: Set<DeferredDeletionResourceKey> = []
  private(set) var operations: [UUID: PendingDeletion] = [:]
  private var refreshGenerations: [DeferredDeletionScope: UInt64] = [:]
  private var dnsLoadGenerations: [DeferredDeletionScope: UInt64] = [:]
  private var nextDNSLoadGeneration: UInt64 = 0

  private struct DeletionBatch: Sendable {
    let id: UUID
    let sequence: UInt64
    var operationIDs: [UUID]
    var deadline: Date
    var gracePeriod: Duration
    var deadlineGeneration: UInt64
    var resultReported = false
    var deferredNoticeReported = false
    var announcedDeadlineGeneration: UInt64?
  }

  private struct PersistedOperation: Codable {
    let id: UUID
    let batchID: UUID
    let command: DeferredDeleteCommand
    let createdAt: Date
    let executionAttempt: UInt64
  }

  private struct PersistedJournal: Codable {
    let version: Int
    let credentialProfileID: String
    let operations: [PersistedOperation]
  }

  private struct CredentialHandoffOperation: Sendable {
    let operation: PendingDeletion
  }

  private struct CredentialHandoff: Sendable {
    let credentialProfileID: String
    let operations: [CredentialHandoffOperation]
  }

  private let executor: any DeferredDeletionExecuting
  private let toasts: DashToastCenter
  private let toastOwner: DashToastCenter.DeferredDeletionOwner
  private let invalidateCache: @MainActor (DeferredDeleteCommand) -> Void
  private let now: @Sendable () -> Date
  private let sleeper: @Sendable (Duration) async throws -> Void
  private let cleanupSleeper: @Sendable (Duration) async throws -> Void
  private let persistence: UserDefaults?
  private let requiresCredentialActivation: Bool
  private var batches: [UUID: DeletionBatch] = [:]
  private var openBatchID: UUID?
  private var deadlineTask: Task<Void, Never>?
  private var commitTasks: [UUID: Task<Void, Never>] = [:]
  private var reconciliationTasks: [UUID: Task<Void, Never>] = [:]
  private var successConfirmationTasks: [UUID: Task<Void, Never>] = [:]
  private var failedCleanupTasks: [UUID: Task<Void, Never>] = [:]
  private var confirmedByRefreshedSnapshot: Set<UUID> = []
  private var resultFeedbackCompletedOperationIDs: Set<UUID> = []
  private var nextBatchSequence: UInt64 = 0
  private var credentialGeneration: UInt64 = 0
  private var activeCredentialProfileID: String?
  private var activeCredentialIsEphemeral = false
  private var availableAccountIDs: Set<String> = []
  private var acceptsScheduling: Bool
  private var restoredJournal: PersistedJournal?
  private var credentialHandoff: CredentialHandoff?
  private static let persistenceKey = "dash.deferred_deletions.reconciling"

  init(
    executor: any DeferredDeletionExecuting,
    toasts: DashToastCenter,
    invalidateCache: @escaping @MainActor (DeferredDeleteCommand) -> Void = { _ in },
    now: @escaping @Sendable () -> Date = Date.init,
    persistence: UserDefaults? = nil,
    requiresCredentialActivation: Bool = false,
    sleeper: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    },
    cleanupSleeper: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
    self.executor = executor
    self.toasts = toasts
    toastOwner = toasts.claimDeferredDeletionOwner()
    self.invalidateCache = invalidateCache
    self.now = now
    self.persistence = persistence
    self.requiresCredentialActivation = requiresCredentialActivation
    acceptsScheduling = !requiresCredentialActivation
    self.sleeper = sleeper
    self.cleanupSleeper = cleanupSleeper
    restoredJournal = loadPersistedJournal()
  }

  @discardableResult
  func schedule(_ command: DeferredDeleteCommand) -> UUID? {
    guard case .deferredDeletion(let gracePeriod) = command.executionPolicy else { return nil }
    guard acceptsScheduling else { return nil }
    if requiresCredentialActivation {
      guard activeCredentialProfileID != nil else { return nil }
      guard availableAccountIDs.contains(command.scope.accountID) else { return nil }
    }
    guard !tombstones.contains(command.resourceKey) else { return nil }

    let supersededFailures = operations.compactMap { id, operation -> UUID? in
      operation.state == .failed && operation.command.resourceKey == command.resourceKey
        ? id : nil
    }
    let discardedRetryIDs = toasts.discardDeferredDeletionResultFeedback(
      associatedWith: Set(supersededFailures),
      owner: toastOwner)
    let batchesToReReport = Set(
      discardedRetryIDs.compactMap { operations[$0]?.batchID })
    for id in supersededFailures {
      removeConfirmedOperation(id)
    }
    for batchID in batchesToReReport where batches[batchID] != nil {
      batches[batchID]?.resultReported = false
    }

    let id = UUID()
    let createdAt = now()
    let deadline = createdAt.addingTimeInterval(gracePeriod.timeInterval)
    let batchID: UUID
    if let openBatchID, hasPendingOperations(in: openBatchID) {
      batchID = openBatchID
    } else {
      batchID = UUID()
      nextBatchSequence &+= 1
      batches[batchID] = DeletionBatch(
        id: batchID,
        sequence: nextBatchSequence,
        operationIDs: [],
        deadline: deadline,
        gracePeriod: gracePeriod,
        deadlineGeneration: 0)
      openBatchID = batchID
    }

    operations[id] = PendingDeletion(
      id: id,
      command: command,
      createdAt: createdAt,
      deadline: deadline,
      state: .pending,
      batchID: batchID,
      credentialProfileID: activeCredentialProfileID,
      credentialGeneration: credentialGeneration,
      executionAttempt: 0,
      reconciliationAttempt: 0,
      minimumDNSLoadGeneration: 0,
      retryEligible: false)
    tombstones.insert(command.resourceKey)
    batches[batchID]?.operationIDs.append(id)
    resetBatchDeadline(batchID: batchID, to: deadline, gracePeriod: gracePeriod)
    return id
  }

  func isPendingDeletion(_ key: DeferredDeletionResourceKey) -> Bool {
    tombstones.contains(key)
  }

  func refreshGeneration(for scope: DeferredDeletionScope) -> UInt64 {
    refreshGenerations[scope, default: 0]
  }

  func beginDNSLoad(for scope: DeferredDeletionScope) -> UInt64 {
    nextDNSLoadGeneration &+= 1
    dnsLoadGenerations[scope] = nextDNSLoadGeneration
    return nextDNSLoadGeneration
  }

  func isCurrentDNSLoad(
    for scope: DeferredDeletionScope,
    generation: UInt64
  ) -> Bool {
    dnsLoadGenerations[scope] == generation
  }

  /// Account-list pagination and lossy decoding can temporarily omit a valid
  /// non-active account. Identity loading uses these IDs for direct checks so
  /// an omission cannot erase the only journal for an uncertain DELETE.
  func recoveryAccountIDs(forCredentialProfileID profileID: String) -> Set<String> {
    var accountIDs = Set(
      operations.values.compactMap { operation in
        operation.credentialProfileID == profileID
          ? operation.command.scope.accountID : nil
      })
    if restoredJournal?.credentialProfileID == profileID {
      accountIDs.formUnion(
        restoredJournal?.operations.map(\.command.scope.accountID) ?? [])
    }
    if credentialHandoff?.credentialProfileID == profileID {
      accountIDs.formUnion(
        credentialHandoff?.operations.map(\.operation.command.scope.accountID) ?? [])
    }
    return accountIDs
  }

  func acknowledgeRefresh(
    for scope: DeferredDeletionScope,
    generation: UInt64
  ) {
    guard refreshGenerations[scope] == generation else { return }
    refreshGenerations.removeValue(forKey: scope)
  }

  func undoCurrentBatch() {
    guard let batchID = openBatchID else { return }
    let pendingIDs = pendingOperationIDs(in: batchID)
    guard !pendingIDs.isEmpty else { return }
    deadlineTask?.cancel()
    deadlineTask = nil
    for id in pendingIDs {
      guard var operation = operations[id], operation.state == .pending else { continue }
      operation.state = .cancelled
      operations[id] = operation
      removeTombstoneIfUnowned(operation.command.resourceKey)
      removeConfirmedOperation(id)
    }
    openBatchID = nil
    toasts.success(DashL10n.string("Deletion undone."), haptic: false)
    renderToast()
  }

  func commitPendingOperations() {
    guard let batchID = openBatchID else { return }
    commitPendingBatch(batchID: batchID)
  }

  private func commitPendingBatch(
    batchID: UUID,
    expectedDeadlineGeneration: UInt64? = nil
  ) {
    guard openBatchID == batchID, let batch = batches[batchID] else { return }
    if let expectedDeadlineGeneration,
      batch.deadlineGeneration != expectedDeadlineGeneration
    {
      return
    }
    let pendingIDs = pendingOperationIDs(in: batchID)
    guard !pendingIDs.isEmpty else { return }

    deadlineTask?.cancel()
    deadlineTask = nil
    openBatchID = nil
    var committingIDs: [UUID] = []
    for id in pendingIDs {
      guard var operation = operations[id], operation.state == .pending else { continue }
      guard credentialsMatch(operation) else {
        operation.state = .cancelled
        operations[id] = operation
        removeTombstoneIfUnowned(operation.command.resourceKey)
        continue
      }
      operation.state = .committing
      operation.executionAttempt &+= 1
      operation.minimumDNSLoadGeneration =
        dnsLoadGenerations[operation.command.scope, default: 0] &+ 1
      operations[id] = operation
      committingIDs.append(id)
    }
    guard !committingIDs.isEmpty else {
      batches[batchID]?.resultReported = true
      renderToast()
      return
    }

    // The journal is written before the first DELETE. A process death after
    // this point can only restore into reconciliation; it never replays DELETE.
    persistUncertainOperations()
    renderToast()
    startCommit(batchID: batchID, ids: committingIDs)
  }

  func cancelPendingOperations(forAccountID accountID: String? = nil) {
    let ids = operations.compactMap { id, operation -> UUID? in
      guard operation.state == .pending else { return nil }
      guard accountID == nil || operation.command.scope.accountID == accountID else { return nil }
      return id
    }
    guard !ids.isEmpty else { return }
    for id in ids {
      guard var operation = operations[id] else { continue }
      operation.state = .cancelled
      operations[id] = operation
      removeTombstoneIfUnowned(operation.command.resourceKey)
      removeConfirmedOperation(id)
    }
    if let openBatchID, pendingOperationIDs(in: openBatchID).isEmpty {
      self.openBatchID = nil
      deadlineTask?.cancel()
      deadlineTask = nil
    }
    renderToast()
  }

  func retry(_ operationID: UUID) {
    retryFailures([operationID])
  }

  func retryFailures(_ operationIDs: [UUID]) {
    let retryIDs = operationIDs.filter { operationID in
      guard
        let operation = operations[operationID],
        operation.state == .failed,
        operation.retryEligible
      else {
        return false
      }
      guard credentialsMatch(operation) else { return false }
      return !operations.contains { id, candidate in
        id != operationID
          && candidate.command.resourceKey == operation.command.resourceKey
          && retainsTombstone(candidate.state)
      }
    }
    guard !retryIDs.isEmpty else { return }

    let batchID = UUID()
    nextBatchSequence &+= 1
    batches[batchID] = DeletionBatch(
      id: batchID,
      sequence: nextBatchSequence,
      operationIDs: retryIDs,
      deadline: now(),
      gracePeriod: .zero,
      deadlineGeneration: 0)

    for id in retryIDs {
      failedCleanupTasks.removeValue(forKey: id)?.cancel()
      guard var operation = operations[id] else { continue }
      if var oldBatch = batches[operation.batchID] {
        oldBatch.operationIDs.removeAll { $0 == id }
        if oldBatch.operationIDs.isEmpty {
          batches.removeValue(forKey: oldBatch.id)
        } else {
          batches[oldBatch.id] = oldBatch
        }
      }
      operation.batchID = batchID
      operation.state = .committing
      operation.retryEligible = false
      resultFeedbackCompletedOperationIDs.remove(id)
      operation.executionAttempt &+= 1
      operation.minimumDNSLoadGeneration =
        dnsLoadGenerations[operation.command.scope, default: 0] &+ 1
      operations[id] = operation
      tombstones.insert(operation.command.resourceKey)
    }

    persistUncertainOperations()
    renderToast()
    startCommit(batchID: batchID, ids: retryIDs)
  }

  func reconcileDNSRecords(
    accountID: String,
    zoneID: String,
    serverRecordIDs: Set<String>,
    isCompleteSnapshot: Bool = false,
    loadGeneration: UInt64? = nil
  ) {
    let scope = DeferredDeletionScope(accountID: accountID, zoneID: zoneID)
    if let loadGeneration,
      dnsLoadGenerations[scope] != loadGeneration
    {
      return
    }
    let snapshot = operations
    for (id, operation) in snapshot {
      guard operation.command.scope == scope else { continue }
      if let loadGeneration,
        loadGeneration < operation.minimumDNSLoadGeneration
      {
        continue
      }
      switch operation.state {
      case .succeeded:
        if serverRecordIDs.contains(operation.command.resourceKey.resourceID) {
          cancelSuccessConfirmation(id)
          confirmedByRefreshedSnapshot.remove(id)
          startSuccessConfirmation(id)
        } else if isCompleteSnapshot {
          cancelSuccessConfirmation(id)
          confirmedByRefreshedSnapshot.insert(id)
        } else {
          startSuccessConfirmation(id)
        }
      case .reconciling:
        if serverRecordIDs.contains(operation.command.resourceKey.resourceID) {
          cancelReconciliation(id)
          markFailed(id, reconciliationAttempt: operation.reconciliationAttempt)
        } else if isCompleteSnapshot {
          cancelReconciliation(id)
          markSucceeded(
            id,
            reconciliationAttempt: operation.reconciliationAttempt,
            requestsRefresh: true)
          confirmedByRefreshedSnapshot.insert(id)
        } else {
          startReconciliation(id)
        }
      default:
        break
      }
    }
    renderToast()
  }

  /// Binds restored work to the authenticated Cloudflare person. Journals from
  /// another credential profile are discarded without making a network call.
  func activateCredential(
    profileID: String,
    availableAccountIDs: Set<String>
  ) {
    activateCredential(
      profileID: profileID,
      availableAccountIDs: availableAccountIDs,
      isEphemeral: false)
  }

  /// Demo is a disposable credential context. It gets normal runtime behavior,
  /// but must never consume or overwrite a real profile's cold-start recovery.
  func activateEphemeralCredential(
    profileID: String,
    availableAccountIDs: Set<String>
  ) {
    activateCredential(
      profileID: profileID,
      availableAccountIDs: availableAccountIDs,
      isEphemeral: true)
  }

  private func activateCredential(
    profileID: String,
    availableAccountIDs: Set<String>,
    isEphemeral: Bool
  ) {
    let profileChanged =
      activeCredentialProfileID != profileID
      || activeCredentialIsEphemeral != isEphemeral
    if profileChanged {
      toasts.purgeDeferredDeletionToasts(owner: toastOwner)
      deadlineTask?.cancel()
      deadlineTask = nil
      for task in commitTasks.values { task.cancel() }
      for task in reconciliationTasks.values { task.cancel() }
      for task in successConfirmationTasks.values { task.cancel() }
      for task in failedCleanupTasks.values { task.cancel() }
      commitTasks.removeAll()
      reconciliationTasks.removeAll()
      successConfirmationTasks.removeAll()
      failedCleanupTasks.removeAll()
      confirmedByRefreshedSnapshot.removeAll()
      resultFeedbackCompletedOperationIDs.removeAll()
      operations.removeAll()
      batches.removeAll()
      tombstones.removeAll()
      refreshGenerations.removeAll()
      dnsLoadGenerations.removeAll()
      openBatchID = nil
      credentialGeneration &+= 1
    }

    activeCredentialProfileID = profileID
    activeCredentialIsEphemeral = isEphemeral
    self.availableAccountIDs = availableAccountIDs
    acceptsScheduling = true

    if !isEphemeral {
      if let handoff = credentialHandoff {
        credentialHandoff = nil
        restoredJournal = nil
        guard handoff.credentialProfileID == profileID else {
          persistence?.removeObject(forKey: Self.persistenceKey)
          renderToast()
          return
        }
        restore(handoff, availableAccountIDs: availableAccountIDs)
      } else if let journal = restoredJournal {
        restoredJournal = nil
        guard journal.version == 1, journal.credentialProfileID == profileID else {
          persistence?.removeObject(forKey: Self.persistenceKey)
          renderToast()
          return
        }
        restore(journal, availableAccountIDs: availableAccountIDs)
      }
    }

    dropOperationsForUnavailableAccounts()
    persistUncertainOperations()
    renderToast()
    resumeReconciliation()
  }

  /// Called while the old token is still installed. Pending work is cancelled;
  /// already-started work is allowed to finish or enter reconciliation before
  /// the credential is replaced.
  func prepareForCredentialReplacement() async {
    cancelPendingOperations()
    resumeReconciliation()
    acceptsScheduling = false
    await waitForActiveWork()
    // A cold-start journal has not been bound to a credential yet. Keep it
    // intact across the OAuth round trip so the eventual identity can decide
    // whether it is safe to reconcile.
    if activeCredentialProfileID != nil, !activeCredentialIsEphemeral {
      credentialHandoff = makeCredentialHandoff()
      restoredJournal = makePersistedJournal()
      persistUncertainOperations()
    }

    deadlineTask?.cancel()
    deadlineTask = nil
    for task in successConfirmationTasks.values { task.cancel() }
    for task in failedCleanupTasks.values { task.cancel() }
    successConfirmationTasks.removeAll()
    failedCleanupTasks.removeAll()
    confirmedByRefreshedSnapshot.removeAll()
    resultFeedbackCompletedOperationIDs.removeAll()
    operations.removeAll()
    batches.removeAll()
    tombstones.removeAll()
    refreshGenerations.removeAll()
    dnsLoadGenerations.removeAll()
    openBatchID = nil
    activeCredentialProfileID = nil
    activeCredentialIsEphemeral = false
    availableAccountIDs.removeAll()
    credentialGeneration &+= 1
    toasts.purgeDeferredDeletionToasts(owner: toastOwner)
  }

  func discardCredentialState() {
    acceptsScheduling = !requiresCredentialActivation
    deadlineTask?.cancel()
    deadlineTask = nil
    for task in commitTasks.values { task.cancel() }
    for task in reconciliationTasks.values { task.cancel() }
    for task in successConfirmationTasks.values { task.cancel() }
    for task in failedCleanupTasks.values { task.cancel() }
    commitTasks.removeAll()
    reconciliationTasks.removeAll()
    successConfirmationTasks.removeAll()
    failedCleanupTasks.removeAll()
    confirmedByRefreshedSnapshot.removeAll()
    resultFeedbackCompletedOperationIDs.removeAll()
    operations.removeAll()
    batches.removeAll()
    tombstones.removeAll()
    refreshGenerations.removeAll()
    dnsLoadGenerations.removeAll()
    openBatchID = nil
    activeCredentialProfileID = nil
    activeCredentialIsEphemeral = false
    availableAccountIDs.removeAll()
    restoredJournal = nil
    credentialHandoff = nil
    credentialGeneration &+= 1
    persistence?.removeObject(forKey: Self.persistenceKey)
    toasts.purgeDeferredDeletionToasts(owner: toastOwner)
  }

  /// Tears down Demo runtime state without consuming the real credential's
  /// restored journal. Demo writes are rejected by its backend and are never
  /// candidates for cross-launch recovery.
  func discardEphemeralCredentialStatePreservingRecovery() {
    guard activeCredentialIsEphemeral else { return }
    acceptsScheduling = !requiresCredentialActivation
    deadlineTask?.cancel()
    deadlineTask = nil
    for task in commitTasks.values { task.cancel() }
    for task in reconciliationTasks.values { task.cancel() }
    for task in successConfirmationTasks.values { task.cancel() }
    for task in failedCleanupTasks.values { task.cancel() }
    commitTasks.removeAll()
    reconciliationTasks.removeAll()
    successConfirmationTasks.removeAll()
    failedCleanupTasks.removeAll()
    confirmedByRefreshedSnapshot.removeAll()
    resultFeedbackCompletedOperationIDs.removeAll()
    operations.removeAll()
    batches.removeAll()
    tombstones.removeAll()
    refreshGenerations.removeAll()
    dnsLoadGenerations.removeAll()
    openBatchID = nil
    activeCredentialProfileID = nil
    activeCredentialIsEphemeral = false
    availableAccountIDs.removeAll()
    credentialGeneration &+= 1
    toasts.purgeDeferredDeletionToasts(owner: toastOwner)
  }

  /// An OAuth exchange can install a token before identity loading succeeds.
  /// At that point a cold-start journal is still unbound, so a transient
  /// identity failure must not destroy the only evidence needed to reconcile
  /// a DELETE that may already have reached Cloudflare.
  func discardUnverifiedCredentialStatePreservingRecovery() {
    if activeCredentialIsEphemeral {
      discardEphemeralCredentialStatePreservingRecovery()
      return
    }
    guard activeCredentialProfileID == nil else {
      discardCredentialState()
      return
    }
    acceptsScheduling = false
    deadlineTask?.cancel()
    deadlineTask = nil
    for task in commitTasks.values { task.cancel() }
    for task in reconciliationTasks.values { task.cancel() }
    for task in successConfirmationTasks.values { task.cancel() }
    for task in failedCleanupTasks.values { task.cancel() }
    commitTasks.removeAll()
    reconciliationTasks.removeAll()
    successConfirmationTasks.removeAll()
    failedCleanupTasks.removeAll()
    confirmedByRefreshedSnapshot.removeAll()
    resultFeedbackCompletedOperationIDs.removeAll()
    operations.removeAll()
    batches.removeAll()
    tombstones.removeAll()
    refreshGenerations.removeAll()
    dnsLoadGenerations.removeAll()
    openBatchID = nil
    activeCredentialIsEphemeral = false
    availableAccountIDs.removeAll()
    credentialGeneration &+= 1
    toasts.purgeDeferredDeletionToasts(owner: toastOwner)
  }

  func resumeReconciliation() {
    guard !requiresCredentialActivation || activeCredentialProfileID != nil else { return }
    let ids = operations.compactMap { id, operation in
      operation.state == .reconciling && credentialsMatch(operation) ? id : nil
    }
    for id in ids {
      guard let batchID = operations[id]?.batchID else { continue }
      batches[batchID]?.deferredNoticeReported = false
      startReconciliation(id)
    }
    renderToast()
  }

  func refreshLocalizedPresentation() {
    for (id, operation) in operations
    where operation.state == .failed
      && !resultFeedbackCompletedOperationIDs.contains(id)
    {
      failedCleanupTasks.removeValue(forKey: id)?.cancel()
    }
    toasts.purgeDeferredDeletionToasts(owner: toastOwner)
    for (id, batch) in batches
    where batch.operationIDs.contains(where: {
      operations[$0]?.state == .reconciling
    }) {
      batches[id]?.deferredNoticeReported = false
    }
    for (id, batch) in batches
    where isFinished(batch)
      && !Set(batch.operationIDs).isSubset(of: resultFeedbackCompletedOperationIDs)
    {
      batches[id]?.resultReported = false
    }
    renderToast()
  }

  func waitForActiveWork() async {
    while true {
      if let task = commitTasks.values.first {
        // Awaiting the operation handle itself is intentionally
        // cancellation-insensitive: credential replacement must not clear
        // state while a DELETE started under the old credential is in flight.
        await task.value
      } else if let task = reconciliationTasks.values.first {
        await task.value
      } else {
        return
      }
    }
  }

  /// Waits for one failed-operation cleanup without extending the production
  /// meaning of `waitForActiveWork`, which deliberately excludes toast dwell.
  func waitForFailedCleanup(of operationID: UUID) async {
    if let task = failedCleanupTasks[operationID] {
      await task.value
    }
  }

  private func resetBatchDeadline(
    batchID: UUID,
    to deadline: Date,
    gracePeriod: Duration
  ) {
    guard var batch = batches[batchID], openBatchID == batchID else { return }
    batch.deadline = deadline
    batch.gracePeriod = gracePeriod
    batch.deadlineGeneration &+= 1
    batches[batchID] = batch
    for id in batch.operationIDs {
      guard var operation = operations[id], operation.state == .pending else { continue }
      operation.deadline = deadline
      operations[id] = operation
    }
    deadlineTask?.cancel()
    renderToast()
    let generation = batch.deadlineGeneration
    deadlineTask = Task { [weak self, sleeper] in
      do {
        try await sleeper(gracePeriod)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.commitPendingBatch(
        batchID: batchID,
        expectedDeadlineGeneration: generation)
    }
  }

  private func startCommit(batchID: UUID, ids: [UUID]) {
    guard commitTasks[batchID] == nil else { return }
    let task = Task { [weak self] in
      guard let self else { return }
      await self.commit(batchID: batchID, ids: ids)
    }
    commitTasks[batchID] = task
  }

  private func commit(batchID: UUID, ids: [UUID]) async {
    for id in ids {
      guard let operation = operations[id], operation.state == .committing else { continue }
      let generation = operation.credentialGeneration
      let attempt = operation.executionAttempt
      do {
        try await executor.execute(operation.command)
        markSucceeded(
          id,
          credentialGeneration: generation,
          executionAttempt: attempt)
      } catch let error as CloudflareAPIError {
        if error.isMissingResource {
          markSucceeded(
            id,
            credentialGeneration: generation,
            executionAttempt: attempt)
        } else if error.hasUncertainOutcome {
          reconcileAfterUncertainFailure(
            id,
            credentialGeneration: generation,
            executionAttempt: attempt)
        } else {
          markFailed(
            id,
            credentialGeneration: generation,
            executionAttempt: attempt)
        }
      } catch {
        reconcileAfterUncertainFailure(
          id,
          credentialGeneration: generation,
          executionAttempt: attempt)
      }
    }
    commitTasks[batchID] = nil
    dropOperationsForUnavailableAccounts()
    persistUncertainOperations()
    renderToast()
  }

  private func reconcileAfterUncertainFailure(
    _ id: UUID,
    credentialGeneration: UInt64,
    executionAttempt: UInt64
  ) {
    guard var operation = operations[id],
      operation.state == .committing,
      operation.credentialGeneration == credentialGeneration,
      operation.executionAttempt == executionAttempt,
      credentialIdentityMatches(operation)
    else { return }
    operation.state = .reconciling
    operations[id] = operation
    persistUncertainOperations()
    renderToast()
    startReconciliation(id)
  }

  private func startReconciliation(_ id: UUID) {
    guard reconciliationTasks[id] == nil else { return }
    guard var operation = operations[id], operation.state == .reconciling,
      credentialsMatch(operation)
    else { return }
    operation.reconciliationAttempt &+= 1
    operations[id] = operation
    batches[operation.batchID]?.deferredNoticeReported = false
    let attempt = operation.reconciliationAttempt
    let generation = operation.credentialGeneration
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performReconciliation(
        id,
        credentialGeneration: generation,
        reconciliationAttempt: attempt)
    }
    reconciliationTasks[id] = task
    renderToast()
  }

  private func cancelReconciliation(_ id: UUID) {
    reconciliationTasks.removeValue(forKey: id)?.cancel()
  }

  private func performReconciliation(
    _ id: UUID,
    credentialGeneration: UInt64,
    reconciliationAttempt: UInt64
  ) async {
    guard let operation = operations[id], operation.state == .reconciling,
      operation.credentialGeneration == credentialGeneration,
      operation.reconciliationAttempt == reconciliationAttempt,
      credentialsMatch(operation)
    else {
      finishReconciliationTask(id, attempt: reconciliationAttempt)
      return
    }
    do {
      switch try await executor.reconcile(operation.command) {
      case .resourceMissing:
        markSucceeded(
          id,
          credentialGeneration: credentialGeneration,
          reconciliationAttempt: reconciliationAttempt)
      case .resourceExists:
        markFailed(
          id,
          credentialGeneration: credentialGeneration,
          reconciliationAttempt: reconciliationAttempt)
      }
    } catch {
      // Keep the tombstone and journal. A foreground activation or a complete
      // DNS refresh will retry the read-only reconciliation, never DELETE.
    }
    finishReconciliationTask(id, attempt: reconciliationAttempt)
  }

  /// A successful DELETE keeps its tombstone until the DNS list has refreshed.
  /// If that refreshed page is not the complete zone, this exact-ID GET proves
  /// absence without treating a partial page as authoritative.
  private func startSuccessConfirmation(_ id: UUID) {
    guard successConfirmationTasks[id] == nil else { return }
    guard var operation = operations[id], operation.state == .succeeded,
      credentialsMatch(operation)
    else { return }
    operation.reconciliationAttempt &+= 1
    operations[id] = operation
    let attempt = operation.reconciliationAttempt
    let generation = operation.credentialGeneration
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performSuccessConfirmation(
        id,
        credentialGeneration: generation,
        reconciliationAttempt: attempt)
    }
    successConfirmationTasks[id] = task
  }

  private func cancelSuccessConfirmation(_ id: UUID) {
    guard let task = successConfirmationTasks.removeValue(forKey: id) else { return }
    task.cancel()
    if var operation = operations[id], operation.state == .succeeded {
      operation.reconciliationAttempt &+= 1
      operations[id] = operation
    }
  }

  private func performSuccessConfirmation(
    _ id: UUID,
    credentialGeneration: UInt64,
    reconciliationAttempt: UInt64
  ) async {
    guard let operation = operations[id], operation.state == .succeeded,
      operation.credentialGeneration == credentialGeneration,
      operation.reconciliationAttempt == reconciliationAttempt,
      credentialsMatch(operation)
    else {
      finishSuccessConfirmation(id, attempt: reconciliationAttempt)
      return
    }
    do {
      let result = try await executor.reconcile(operation.command)
      guard let current = operations[id], current.state == .succeeded,
        current.credentialGeneration == credentialGeneration,
        current.reconciliationAttempt == reconciliationAttempt
      else {
        finishSuccessConfirmation(id, attempt: reconciliationAttempt)
        return
      }
      switch result {
      case .resourceMissing:
        confirmedByRefreshedSnapshot.insert(id)
      case .resourceExists:
        markFailedAfterSuccessConfirmation(
          id,
          credentialGeneration: credentialGeneration,
          reconciliationAttempt: reconciliationAttempt)
      }
    } catch {
      // The refreshed list is still filtered by the tombstone. A later pull
      // to refresh can retry this exact-ID confirmation.
    }
    finishSuccessConfirmation(id, attempt: reconciliationAttempt)
  }

  private func markFailedAfterSuccessConfirmation(
    _ id: UUID,
    credentialGeneration: UInt64,
    reconciliationAttempt: UInt64
  ) {
    guard var operation = operations[id],
      operation.state == .succeeded,
      operation.credentialGeneration == credentialGeneration,
      operation.reconciliationAttempt == reconciliationAttempt,
      credentialsMatch(operation)
    else { return }
    let invalidatedFeedbackIDs = toasts.discardDeferredDeletionResultFeedback(
      associatedWith: [id],
      owner: toastOwner)
    let affectedBatchIDs = Set(
      invalidatedFeedbackIDs.union([id]).compactMap {
        operations[$0]?.batchID
      })
    operation.state = .failed
    operation.retryEligible = true
    resultFeedbackCompletedOperationIDs.remove(id)
    operations[id] = operation
    confirmedByRefreshedSnapshot.remove(id)
    removeTombstoneIfUnowned(operation.command.resourceKey)
    for batchID in affectedBatchIDs where batches[batchID] != nil {
      batches[batchID]?.resultReported = false
    }
    persistUncertainOperations()
  }

  private func finishSuccessConfirmation(_ id: UUID, attempt: UInt64) {
    guard operations[id]?.reconciliationAttempt == attempt else { return }
    successConfirmationTasks[id] = nil
    renderToast()
  }

  private func finishReconciliationTask(_ id: UUID, attempt: UInt64) {
    guard operations[id]?.reconciliationAttempt == attempt else { return }
    reconciliationTasks[id] = nil
    persistUncertainOperations()
    renderToast()
  }

  private func markSucceeded(
    _ id: UUID,
    credentialGeneration: UInt64? = nil,
    executionAttempt: UInt64? = nil,
    reconciliationAttempt: UInt64? = nil,
    requestsRefresh: Bool = true
  ) {
    guard var operation = operations[id] else { return }
    if let credentialGeneration,
      operation.credentialGeneration != credentialGeneration
    {
      return
    }
    if let executionAttempt,
      operation.state != .committing || operation.executionAttempt != executionAttempt
    {
      return
    }
    if let reconciliationAttempt,
      operation.state != .reconciling
        || operation.reconciliationAttempt != reconciliationAttempt
    {
      return
    }
    guard
      executionAttempt != nil
        ? credentialIdentityMatches(operation)
        : credentialsMatch(operation)
    else { return }
    operation.state = .succeeded
    resultFeedbackCompletedOperationIDs.remove(id)
    operations[id] = operation
    if credentialsMatch(operation) {
      invalidateCache(operation.command)
    }
    if requestsRefresh, credentialsMatch(operation) {
      refreshGenerations[operation.command.scope, default: 0] &+= 1
    }
    persistUncertainOperations()
  }

  private func markFailed(
    _ id: UUID,
    credentialGeneration: UInt64? = nil,
    executionAttempt: UInt64? = nil,
    reconciliationAttempt: UInt64? = nil
  ) {
    guard var operation = operations[id] else { return }
    if let credentialGeneration,
      operation.credentialGeneration != credentialGeneration
    {
      return
    }
    if let executionAttempt,
      operation.state != .committing || operation.executionAttempt != executionAttempt
    {
      return
    }
    if let reconciliationAttempt,
      operation.state != .reconciling
        || operation.reconciliationAttempt != reconciliationAttempt
    {
      return
    }
    guard
      executionAttempt != nil
        ? credentialIdentityMatches(operation)
        : credentialsMatch(operation)
    else { return }
    operation.state = .failed
    operation.retryEligible = true
    resultFeedbackCompletedOperationIDs.remove(id)
    operations[id] = operation
    removeTombstoneIfUnowned(operation.command.resourceKey)
    persistUncertainOperations()
  }

  private func removeConfirmedOperation(_ id: UUID) {
    guard let operation = operations.removeValue(forKey: id) else { return }
    failedCleanupTasks.removeValue(forKey: id)?.cancel()
    reconciliationTasks.removeValue(forKey: id)?.cancel()
    successConfirmationTasks.removeValue(forKey: id)?.cancel()
    confirmedByRefreshedSnapshot.remove(id)
    resultFeedbackCompletedOperationIDs.remove(id)
    removeTombstoneIfUnowned(operation.command.resourceKey)
    if var batch = batches[operation.batchID] {
      batch.operationIDs.removeAll { $0 == id }
      if batch.operationIDs.isEmpty {
        batches.removeValue(forKey: batch.id)
      } else {
        batches[batch.id] = batch
      }
    }
    persistUncertainOperations()
  }

  private func removeTombstoneIfUnowned(_ resourceKey: DeferredDeletionResourceKey) {
    let hasOwner = operations.values.contains { operation in
      operation.command.resourceKey == resourceKey && retainsTombstone(operation.state)
    }
    if !hasOwner {
      tombstones.remove(resourceKey)
    }
  }

  private func retainsTombstone(_ state: PendingDeletion.State) -> Bool {
    switch state {
    case .pending, .committing, .succeeded, .reconciling:
      true
    case .cancelled, .failed:
      false
    }
  }

  /// Every async callback mutates state first and comes through this reducer.
  /// That makes a newer pending batch the display owner even when an older
  /// network request finishes later.
  private func renderToast() {
    defer {
      pruneReportedConfirmedOperations()
      toasts.promoteNextQueuedToastIfIdle()
    }
    if let openBatchID, let batch = batches[openBatchID] {
      let pendingIDs = pendingOperationIDs(in: openBatchID)
      if !pendingIDs.isEmpty {
        showPendingToast(batch: batch, operationIDs: pendingIDs)
        return
      }
    }

    let committingCount = operations.values.count { $0.state == .committing }
    if committingCount > 0 {
      showCommittingToast(count: committingCount)
      return
    }

    let hasActiveReconciliation = reconciliationTasks.keys.contains {
      operations[$0]?.state == .reconciling
    }
    if hasActiveReconciliation {
      toasts.update(
        DashToast(
          id: .deferredDeletionBatch,
          kind: .warning,
          title: "Confirming deletion",
          message: DashL10n.string("Checking whether Cloudflare completed the deletion…"),
          dismissBehavior: .programmaticOnly),
        deferredDeletionOwner: toastOwner)
      return
    }

    let idleReconciliationBatchIDs = Set(
      operations.values.compactMap { operation in
        operation.state == .reconciling ? operation.batchID : nil
      })
    let unreportedDeferredBatchIDs = idleReconciliationBatchIDs.filter {
      batches[$0]?.deferredNoticeReported == false
    }
    if !unreportedDeferredBatchIDs.isEmpty {
      for id in unreportedDeferredBatchIDs {
        batches[id]?.deferredNoticeReported = true
      }
      toasts.enqueueDeferredDeletionToast(
        DashToast(
          id: .deferredDeletionBatch,
          kind: .warning,
          title: "Deletion still being confirmed",
          message: DashL10n.string(
            "Dash could not confirm the result yet. It will check again in the foreground.")),
        owner: toastOwner)
    }

    let finishedBatches = batches.values
      .filter { !$0.resultReported && isFinished($0) }
      .sorted { $0.sequence < $1.sequence }
    if !finishedBatches.isEmpty {
      showResult(for: finishedBatches)
    }

    if toasts.current?.id == .deferredDeletionBatch,
      toasts.current?.dismissBehavior == .programmaticOnly
    {
      toasts.releaseDeferredDeletionToast(owner: toastOwner)
    }
  }

  private func pruneReportedConfirmedOperations() {
    let removable = confirmedByRefreshedSnapshot.filter { id in
      operations[id] == nil || resultFeedbackCompletedOperationIDs.contains(id)
    }
    for id in removable {
      if operations[id] == nil {
        confirmedByRefreshedSnapshot.remove(id)
      } else {
        removeConfirmedOperation(id)
      }
    }
  }

  private func showPendingToast(batch: DeletionBatch, operationIDs: [UUID]) {
    let count = operationIDs.count
    let seconds = max(1, Int(ceil(batch.deadline.timeIntervalSince(now()))))
    let message =
      count == 1
      ? (seconds == 1
        ? DashL10n.string(
          "\(operations[operationIDs[0]]?.command.deletionSubject ?? "") will be deleted in 1 second."
        )
        : DashL10n.string(
          "\(operations[operationIDs[0]]?.command.deletionSubject ?? "") will be deleted in \(seconds) seconds."
        ))
      : (seconds == 1
        ? DashL10n.string("\(count) items will be deleted in 1 second.")
        : DashL10n.string("\(count) items will be deleted in \(seconds) seconds."))
    let shouldAnnounce = batch.announcedDeadlineGeneration != batch.deadlineGeneration
    toasts.update(
      DashToast(
        id: .deferredDeletionBatch,
        kind: .warning,
        title: "Pending deletion",
        message: message,
        action: .undoDeferredDeletionBatch,
        actionTitle: count == 1 ? "Undo" : "Undo all",
        actionAccessibilityLabel: count == 1 ? "Undo deletion" : "Undo all deletions",
        accessibilityAnnouncement: count == 1
          ? "\(message) \(DashL10n.string("Undo available."))"
          : "\(message) \(DashL10n.string("Undo all available."))",
        actionPhase: .loading,
        dismissBehavior: .programmaticOnly),
      announce: shouldAnnounce,
      deferredDeletionOwner: toastOwner)
    if shouldAnnounce {
      batches[batch.id]?.announcedDeadlineGeneration = batch.deadlineGeneration
    }
  }

  private func showCommittingToast(count: Int) {
    let message = DashL10n.string(
      count == 1 ? "Deleting 1 item…" : "Deleting \(count) items…")
    toasts.update(
      DashToast(
        id: .deferredDeletionBatch,
        kind: .warning,
        title: "Deleting",
        message: message,
        actionPhase: .loading,
        dismissBehavior: .programmaticOnly),
      deferredDeletionOwner: toastOwner)
  }

  private func showResult(for finishedBatches: [DeletionBatch]) {
    let representedOperationIDs = Set(finishedBatches.flatMap(\.operationIDs))
    var succeeded: [UUID] = []
    var failed: [UUID] = []
    for batch in finishedBatches {
      for id in batch.operationIDs {
        switch operations[id]?.state {
        case .succeeded:
          succeeded.append(id)
        case .failed:
          failed.append(id)
        default:
          break
        }
      }
      batches[batch.id]?.resultReported = true
    }
    guard !succeeded.isEmpty || !failed.isEmpty else { return }

    if failed.isEmpty {
      let message =
        succeeded.count == 1
        ? DashL10n.string(
          "\(operations[succeeded[0]]?.command.displayName ?? "") deleted."
        )
        : DashL10n.string("\(succeeded.count) items deleted.")
      toasts.enqueueDeferredDeletionToast(
        DashToast(
          id: .deferredDeletionBatch,
          kind: .success,
          message: message,
          actionPhase: .succeeded),
        owner: toastOwner,
        operationIDs: representedOperationIDs,
        onDismiss: { [weak self] in
          self?.resultFeedbackDidDismiss(
            representedOperationIDs,
            failedOperationIDs: [])
        })
      return
    }

    let message =
      succeeded.isEmpty
      ? DashL10n.string(
        "Deletion failed. \(operations[failed[0]]?.command.displayName ?? "") still exists."
      )
      : DashL10n.string("\(succeeded.count) items deleted, \(failed.count) failed.")
    let toast = DashToast(
      id: .deferredDeletionBatch,
      kind: .error,
      message: message,
      action: .retryDeferredDeletions(failed),
      actionTitle: failed.count == 1 ? "Retry" : "Retry failures",
      actionAccessibilityLabel: failed.count == 1
        ? "Retry deletion" : "Retry failed deletions")
    for id in failed {
      if var operation = operations[id], operation.state == .failed {
        operation.retryEligible = true
        operations[id] = operation
      }
    }
    toasts.enqueueDeferredDeletionToast(
      toast,
      owner: toastOwner,
      operationIDs: representedOperationIDs,
      onDismiss: { [weak self] in
        self?.resultFeedbackDidDismiss(
          representedOperationIDs,
          failedOperationIDs: failed)
      })
  }

  private func resultFeedbackDidDismiss(
    _ representedOperationIDs: Set<UUID>,
    failedOperationIDs: [UUID]
  ) {
    resultFeedbackCompletedOperationIDs.formUnion(representedOperationIDs)
    failureFeedbackDidDismiss(failedOperationIDs)
    renderToast()
  }

  private func failureFeedbackDidDismiss(_ ids: [UUID]) {
    for id in ids {
      guard var operation = operations[id], operation.state == .failed else { continue }
      operation.retryEligible = false
      operations[id] = operation
    }
    scheduleFailedOperationCleanup(ids, after: 0)
  }

  private func scheduleFailedOperationCleanup(_ ids: [UUID], after duration: TimeInterval) {
    for id in ids {
      guard let operation = operations[id], operation.state == .failed else { continue }
      let executionAttempt = operation.executionAttempt
      failedCleanupTasks.removeValue(forKey: id)?.cancel()
      failedCleanupTasks[id] = Task { [weak self, cleanupSleeper] in
        try? await cleanupSleeper(.milliseconds(Int64((duration + 0.25) * 1_000)))
        guard !Task.isCancelled, let self else { return }
        failedCleanupTasks[id] = nil
        guard
          let current = operations[id],
          current.state == .failed,
          current.executionAttempt == executionAttempt
        else { return }
        removeConfirmedOperation(id)
      }
    }
  }

  private func hasPendingOperations(in batchID: UUID) -> Bool {
    !pendingOperationIDs(in: batchID).isEmpty
  }

  private func pendingOperationIDs(in batchID: UUID) -> [UUID] {
    batches[batchID]?.operationIDs.filter { operations[$0]?.state == .pending } ?? []
  }

  private func isFinished(_ batch: DeletionBatch) -> Bool {
    !batch.operationIDs.isEmpty
      && batch.operationIDs.allSatisfy {
        guard let state = operations[$0]?.state else { return true }
        return state == .succeeded || state == .failed || state == .cancelled
      }
  }

  private func credentialsMatch(_ operation: PendingDeletion) -> Bool {
    guard credentialIdentityMatches(operation) else { return false }
    if operation.credentialProfileID != nil {
      return availableAccountIDs.contains(operation.command.scope.accountID)
    }
    return true
  }

  private func credentialIdentityMatches(_ operation: PendingDeletion) -> Bool {
    guard operation.credentialGeneration == credentialGeneration else { return false }
    if let profileID = operation.credentialProfileID {
      return activeCredentialProfileID == profileID
    }
    return !requiresCredentialActivation && activeCredentialProfileID == nil
  }

  private func dropOperationsForUnavailableAccounts() {
    let ids: [UUID] = operations.compactMap { (id: UUID, operation: PendingDeletion) -> UUID? in
      guard operation.credentialProfileID != nil else { return nil }
      return availableAccountIDs.contains(operation.command.scope.accountID) ? nil : id
    }
    let removableIDs = ids.filter { id in
      guard let operation = operations[id] else { return false }
      // A DELETE that already crossed the commit boundary owns the old
      // credential until its request returns. Keep it tracked; `commit` calls
      // this method again after the batch task is removed.
      if operation.state == .committing, commitTasks[operation.batchID] != nil {
        return false
      }
      return true
    }
    let invalidatedFeedbackIDs = toasts.discardDeferredDeletionResultFeedback(
      associatedWith: Set(removableIDs),
      owner: toastOwner)
    let batchesToReReport = Set(
      invalidatedFeedbackIDs.compactMap { operations[$0]?.batchID })
    for id in removableIDs {
      removeConfirmedOperation(id)
    }
    for batchID in batchesToReReport where batches[batchID] != nil {
      batches[batchID]?.resultReported = false
    }
    dnsLoadGenerations = dnsLoadGenerations.filter {
      availableAccountIDs.contains($0.key.accountID)
    }
    if let openBatchID, pendingOperationIDs(in: openBatchID).isEmpty {
      self.openBatchID = nil
      deadlineTask?.cancel()
      deadlineTask = nil
    }
  }

  private func loadPersistedJournal() -> PersistedJournal? {
    guard
      let data = persistence?.data(forKey: Self.persistenceKey),
      let journal = try? JSONDecoder().decode(PersistedJournal.self, from: data)
    else { return nil }
    return journal
  }

  private func restore(
    _ journal: PersistedJournal,
    availableAccountIDs: Set<String>
  ) {
    let eligible = journal.operations.filter {
      availableAccountIDs.contains($0.command.scope.accountID)
    }
    let grouped = Dictionary(grouping: eligible, by: \.batchID)
    for (batchID, items) in grouped {
      nextBatchSequence &+= 1
      batches[batchID] = DeletionBatch(
        id: batchID,
        sequence: nextBatchSequence,
        operationIDs: items.map(\.id),
        deadline: items.map(\.createdAt).max() ?? now(),
        gracePeriod: .zero,
        deadlineGeneration: 0)
    }
    for item in eligible {
      operations[item.id] = PendingDeletion(
        id: item.id,
        command: item.command,
        createdAt: item.createdAt,
        deadline: item.createdAt,
        state: .reconciling,
        batchID: item.batchID,
        credentialProfileID: journal.credentialProfileID,
        credentialGeneration: credentialGeneration,
        executionAttempt: item.executionAttempt,
        reconciliationAttempt: 0,
        minimumDNSLoadGeneration:
          dnsLoadGenerations[item.command.scope, default: 0] &+ 1,
        retryEligible: false)
      tombstones.insert(item.command.resourceKey)
    }
  }

  private func restore(
    _ handoff: CredentialHandoff,
    availableAccountIDs: Set<String>
  ) {
    let eligible = handoff.operations.filter {
      availableAccountIDs.contains($0.operation.command.scope.accountID)
    }
    let grouped = Dictionary(grouping: eligible, by: \.operation.batchID)
    for (batchID, items) in grouped {
      nextBatchSequence &+= 1
      batches[batchID] = DeletionBatch(
        id: batchID,
        sequence: nextBatchSequence,
        operationIDs: items.map(\.operation.id),
        deadline: items.map(\.operation.createdAt).max() ?? now(),
        gracePeriod: .zero,
        deadlineGeneration: 0)
    }

    var succeededIDs: [UUID] = []
    for item in eligible {
      let previous = item.operation
      let state: PendingDeletion.State =
        previous.state == .succeeded ? .succeeded : .reconciling
      operations[previous.id] = PendingDeletion(
        id: previous.id,
        command: previous.command,
        createdAt: previous.createdAt,
        deadline: previous.deadline,
        state: state,
        batchID: previous.batchID,
        credentialProfileID: handoff.credentialProfileID,
        credentialGeneration: credentialGeneration,
        executionAttempt: previous.executionAttempt,
        reconciliationAttempt: previous.reconciliationAttempt,
        minimumDNSLoadGeneration:
          dnsLoadGenerations[previous.command.scope, default: 0] &+ 1,
        retryEligible: false)
      tombstones.insert(previous.command.resourceKey)
      if state == .succeeded {
        invalidateCache(previous.command)
        refreshGenerations[previous.command.scope, default: 0] &+= 1
        succeededIDs.append(previous.id)
      }
    }
    for id in succeededIDs {
      startSuccessConfirmation(id)
    }
  }

  private func makeCredentialHandoff() -> CredentialHandoff? {
    guard !activeCredentialIsEphemeral, let profileID = activeCredentialProfileID else {
      return nil
    }
    let handedOff = operations.values.compactMap {
      operation -> CredentialHandoffOperation? in
      switch operation.state {
      case .committing, .reconciling, .succeeded:
        return CredentialHandoffOperation(operation: operation)
      case .pending, .cancelled, .failed:
        return nil
      }
    }
    guard !handedOff.isEmpty else { return nil }
    return CredentialHandoff(
      credentialProfileID: profileID,
      operations: handedOff)
  }

  private func makePersistedJournal() -> PersistedJournal? {
    guard !activeCredentialIsEphemeral, let profileID = activeCredentialProfileID else {
      return nil
    }
    let persisted = operations.values.compactMap { operation -> PersistedOperation? in
      guard operation.state == .committing || operation.state == .reconciling else {
        return nil
      }
      return PersistedOperation(
        id: operation.id,
        batchID: operation.batchID,
        command: operation.command,
        createdAt: operation.createdAt,
        executionAttempt: operation.executionAttempt)
    }
    guard !persisted.isEmpty else { return nil }
    return PersistedJournal(
      version: 1,
      credentialProfileID: profileID,
      operations: persisted)
  }

  private func persistUncertainOperations() {
    guard let persistence else { return }
    guard !activeCredentialIsEphemeral else { return }
    guard let journal = makePersistedJournal() else {
      persistence.removeObject(forKey: Self.persistenceKey)
      return
    }
    if let data = try? JSONEncoder().encode(journal) {
      persistence.set(data, forKey: Self.persistenceKey)
    }
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let components = self.components
    return TimeInterval(components.seconds)
      + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
  }
}

extension CloudflareAPIError {
  fileprivate var isMissingResource: Bool {
    if case .request(let status, _) = self {
      return status == 404
    }
    return false
  }

  fileprivate var hasUncertainOutcome: Bool {
    switch self {
    case .invalidResponse, .transport:
      true
    case .request(let status, _):
      status == 408 || status >= 500
    case .oauth:
      false
    }
  }
}
