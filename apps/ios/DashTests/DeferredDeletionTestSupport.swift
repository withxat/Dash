import CloudflareAPI
import Foundation
import Testing
import UIKit

@testable import Dash

let persistenceKey = "dash.deferred_deletions.reconciling"

final class DeferredDeletionDateBox: @unchecked Sendable {
  var value: Date

  init(_ value: Date) {
    self.value = value
  }
}

func deletionCommand(
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

enum DeferredDeletionScenarioError: Error {
  case reconciliationFailed
}

actor DeferredDeletionScenarioExecutor: DeferredDeletionExecuting {
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

actor DeferredDeletionManualSleeper {
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

func testDefaults() -> UserDefaults {
  let suiteName = "DeferredDeletionTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defaults.removePersistentDomain(forName: suiteName)
  return defaults
}

func clearTestDefaults(_ defaults: UserDefaults) {
  for key in defaults.dictionaryRepresentation().keys {
    defaults.removeObject(forKey: key)
  }
}

actor FailingReplacementTokenStore: TokenStore {
  enum Failure: Error {
    case cannotWrite
  }

  func clear() {}
  func getAccessToken() -> String? { nil }
  func getRefreshToken() -> String? { nil }
  func setTokens(_: TokenSet) throws { throw Failure.cannotWrite }
}

actor CredentialMutationTrackingTokenStore: TokenStore {
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

final class DeferredDeletionRequestRecorder: @unchecked Sendable {
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

final class DeferredDeletionURLProtocol: URLProtocol, @unchecked Sendable {
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

func deferredDeletionMockSession(
  handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)
) -> URLSession {
  DeferredDeletionURLProtocol.handler = handler
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [DeferredDeletionURLProtocol.self]
  return URLSession(configuration: configuration)
}
