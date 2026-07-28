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

struct CloudflareDeferredDeletionExecutor: DeferredDeletionExecuting {
  let client: CloudflareClient

  func execute(_ command: DeferredDeleteCommand) async throws {
    switch command {
    case .dnsRecord(_, let zoneID, let recordID, _, _):
      try await client.deleteDNSRecord(zoneID: zoneID, recordID: recordID)
    }
  }

  func reconcile(_ command: DeferredDeleteCommand) async throws
    -> DeferredDeletionReconciliationResult
  {
    switch command {
    case .dnsRecord(_, let zoneID, let recordID, _, let displayName):
      let page = try await client.listDNSRecords(
        zoneID: zoneID,
        page: 1,
        perPage: 100,
        search: displayName)
      return page.items.contains { $0.id == recordID } ? .resourceExists : .resourceMissing
    }
  }
}

@MainActor
@Observable
final class DeferredDeletionCoordinator {
  private(set) var tombstones: Set<DeferredDeletionResourceKey> = []
  private(set) var operations: [UUID: PendingDeletion] = [:]

  private let executor: any DeferredDeletionExecuting
  private let toasts: DashToastCenter
  private let invalidateCache: @MainActor (DeferredDeleteCommand) -> Void
  private let now: @Sendable () -> Date
  private let sleeper: @Sendable (Duration) async throws -> Void
  private let persistence: UserDefaults?
  private var batchIDs: [UUID] = []
  private var deadlineTask: Task<Void, Never>?
  private static let persistenceKey = "dash.deferred_deletions.reconciling"

  init(
    executor: any DeferredDeletionExecuting,
    toasts: DashToastCenter,
    invalidateCache: @escaping @MainActor (DeferredDeleteCommand) -> Void = { _ in },
    now: @escaping @Sendable () -> Date = Date.init,
    persistence: UserDefaults? = nil,
    sleeper: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
    self.executor = executor
    self.toasts = toasts
    self.invalidateCache = invalidateCache
    self.now = now
    self.persistence = persistence
    self.sleeper = sleeper
    restoreUncertainOperations()
  }

  func schedule(_ command: DeferredDeleteCommand) {
    guard case .deferredDeletion(let gracePeriod) = command.executionPolicy else { return }
    guard !tombstones.contains(command.resourceKey) else { return }
    let id = UUID()
    let createdAt = now()
    let deadline = createdAt.addingTimeInterval(gracePeriod.timeInterval)
    operations[id] = PendingDeletion(
      id: id,
      command: command,
      createdAt: createdAt,
      deadline: deadline,
      state: .pending)
    tombstones.insert(command.resourceKey)
    batchIDs.append(id)
    resetBatchDeadline(to: deadline, gracePeriod: gracePeriod)
  }

  func isPendingDeletion(_ key: DeferredDeletionResourceKey) -> Bool {
    tombstones.contains(key)
  }

  func undoCurrentBatch() {
    let pendingIDs = batchIDs.filter { operations[$0]?.state == .pending }
    guard !pendingIDs.isEmpty else { return }
    deadlineTask?.cancel()
    deadlineTask = nil
    for id in pendingIDs {
      guard var operation = operations[id], operation.state == .pending else { continue }
      operation.state = .cancelled
      operations[id] = operation
      tombstones.remove(operation.command.resourceKey)
    }
    batchIDs.removeAll()
    toasts.dismiss(id: .deferredDeletionBatch)
    toasts.success(DashL10n.string("Deletion undone."), haptic: false)
  }

  func commitPendingOperations() {
    let pendingIDs = batchIDs.filter { operations[$0]?.state == .pending }
    guard !pendingIDs.isEmpty else { return }
    deadlineTask?.cancel()
    deadlineTask = nil
    batchIDs.removeAll()
    for id in pendingIDs {
      guard var operation = operations[id], operation.state == .pending else { continue }
      operation.state = .committing
      operations[id] = operation
    }
    persistUncertainOperations()
    showCommittingToast(count: pendingIDs.count)
    Task { await commit(ids: pendingIDs) }
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
      tombstones.remove(operation.command.resourceKey)
      batchIDs.removeAll { $0 == id }
    }
    if batchIDs.isEmpty {
      deadlineTask?.cancel()
      deadlineTask = nil
      toasts.dismiss(id: .deferredDeletionBatch)
    } else {
      showPendingToast()
    }
  }

  func retry(_ operationID: UUID) {
    guard var operation = operations[operationID], operation.state == .failed else { return }
    operation.state = .committing
    operations[operationID] = operation
    tombstones.insert(operation.command.resourceKey)
    showCommittingToast(count: 1, retrying: true)
    Task { await commit(ids: [operationID]) }
  }

  func reconcileDNSRecords(
    accountID: String,
    zoneID: String,
    serverRecordIDs: Set<String>
  ) {
    let snapshot = operations
    for (id, operation) in snapshot {
      guard
        operation.command.scope
          == DeferredDeletionScope(accountID: accountID, zoneID: zoneID)
      else { continue }
      switch operation.state {
      case .succeeded where !serverRecordIDs.contains(operation.command.resourceKey.resourceID):
        tombstones.remove(operation.command.resourceKey)
        operations.removeValue(forKey: id)
        persistUncertainOperations()
      case .reconciling:
        Task { await reconcile(id: id) }
      default:
        break
      }
    }
  }

  private func resetBatchDeadline(to deadline: Date, gracePeriod: Duration) {
    for id in batchIDs {
      guard var operation = operations[id], operation.state == .pending else { continue }
      operation.deadline = deadline
      operations[id] = operation
    }
    deadlineTask?.cancel()
    showPendingToast()
    deadlineTask = Task { [weak self, sleeper] in
      do {
        try await sleeper(gracePeriod)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.commitPendingOperations()
    }
  }

  private func showPendingToast() {
    let count = batchIDs.count
    guard count > 0 else { return }
    let message =
      count == 1
      ? DashL10n.string(
        "\(operations[batchIDs[0]]?.command.displayName ?? "") will be deleted in 5 seconds.")
      : DashL10n.string("\(count) items will be deleted in 5 seconds.")
    toasts.update(
      DashToast(
        id: .deferredDeletionBatch,
        kind: .warning,
        title: "Pending deletion",
        message: message,
        action: .undoDeferredDeletionBatch,
        actionTitle: count == 1 ? "Undo" : "Undo all",
        actionAccessibilityLabel: count == 1 ? "Undo deletion" : "Undo all deletions",
        dismissBehavior: .programmaticOnly))
  }

  private func showCommittingToast(count: Int, retrying: Bool = false) {
    let message =
      retrying
      ? DashL10n.string("Retrying deletion…")
      : DashL10n.string(
        count == 1 ? "Deleting 1 item…" : "Deleting \(count) items…")
    toasts.update(
      DashToast(
        id: .deferredDeletionBatch,
        kind: .warning,
        title: "Deleting",
        message: message,
        dismissBehavior: .programmaticOnly))
  }

  private func commit(ids: [UUID]) async {
    var succeeded = 0
    var failed: [UUID] = []
    for id in ids {
      guard let operation = operations[id], operation.state == .committing else { continue }
      do {
        try await executor.execute(operation.command)
        markSucceeded(id)
        succeeded += 1
      } catch let error as CloudflareAPIError {
        if error.isMissingResource {
          markSucceeded(id)
          succeeded += 1
        } else if error.hasUncertainOutcome {
          if await reconcileAfterUncertainFailure(id) {
            succeeded += 1
          } else if operations[id]?.state == .failed {
            failed.append(id)
          }
        } else {
          markFailed(id)
          failed.append(id)
        }
      } catch {
        if await reconcileAfterUncertainFailure(id) {
          succeeded += 1
        } else if operations[id]?.state == .failed {
          failed.append(id)
        }
      }
    }
    let reconciling = ids.filter { operations[$0]?.state == .reconciling }.count
    showResult(succeeded: succeeded, failed: failed, reconciling: reconciling)
  }

  private func reconcileAfterUncertainFailure(_ id: UUID) async -> Bool {
    guard var operation = operations[id], operation.state == .committing else { return false }
    operation.state = .reconciling
    operations[id] = operation
    persistUncertainOperations()
    return await reconcile(id: id)
  }

  @discardableResult
  private func reconcile(id: UUID) async -> Bool {
    guard let operation = operations[id], operation.state == .reconciling else { return false }
    do {
      switch try await executor.reconcile(operation.command) {
      case .resourceMissing:
        markSucceeded(id)
        return true
      case .resourceExists:
        markFailed(id)
        return false
      }
    } catch {
      return false
    }
  }

  private func markSucceeded(_ id: UUID) {
    guard var operation = operations[id] else { return }
    operation.state = .succeeded
    operations[id] = operation
    invalidateCache(operation.command)
    persistUncertainOperations()
  }

  private func markFailed(_ id: UUID) {
    guard var operation = operations[id] else { return }
    operation.state = .failed
    operations[id] = operation
    tombstones.remove(operation.command.resourceKey)
    persistUncertainOperations()
  }

  private func showResult(succeeded: Int, failed: [UUID], reconciling: Int) {
    if reconciling > 0 {
      toasts.update(
        DashToast(
          id: .deferredDeletionBatch,
          kind: .warning,
          title: "Confirming deletion",
          message: DashL10n.string("Checking whether Cloudflare completed the deletion…"),
          dismissBehavior: .programmaticOnly))
      return
    }
    if failed.isEmpty {
      let message =
        succeeded == 1
        ? DashL10n.string("DNS record deleted.")
        : DashL10n.string("\(succeeded) items deleted.")
      toasts.show(
        DashToast(
          id: .deferredDeletionBatch,
          kind: .success,
          message: message))
      return
    }

    let message =
      succeeded == 0
      ? DashL10n.string("Deletion failed. The item still exists.")
      : DashL10n.string("\(succeeded) items deleted, \(failed.count) failed.")
    let retryID = failed.count == 1 ? failed[0] : nil
    toasts.show(
      DashToast(
        id: .deferredDeletionBatch,
        kind: .error,
        message: message,
        action: retryID.map(DashToast.Action.retryDeferredDeletion),
        actionTitle: retryID == nil ? nil : "Retry",
        actionAccessibilityLabel: retryID == nil ? nil : "Retry deletion"))
  }

  private struct PersistedOperation: Codable {
    let id: UUID
    let command: DeferredDeleteCommand
    let createdAt: Date
  }

  private func restoreUncertainOperations() {
    guard
      let data = persistence?.data(forKey: Self.persistenceKey),
      let persisted = try? JSONDecoder().decode([PersistedOperation].self, from: data)
    else { return }
    for item in persisted {
      operations[item.id] = PendingDeletion(
        id: item.id,
        command: item.command,
        createdAt: item.createdAt,
        deadline: item.createdAt,
        state: .reconciling)
      tombstones.insert(item.command.resourceKey)
    }
  }

  private func persistUncertainOperations() {
    guard let persistence else { return }
    let persisted = operations.values.compactMap { operation -> PersistedOperation? in
      guard operation.state == .committing || operation.state == .reconciling else {
        return nil
      }
      return PersistedOperation(
        id: operation.id,
        command: operation.command,
        createdAt: operation.createdAt)
    }
    guard !persisted.isEmpty else {
      persistence.removeObject(forKey: Self.persistenceKey)
      return
    }
    if let data = try? JSONEncoder().encode(persisted) {
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
    case .oauth, .request:
      false
    }
  }
}
