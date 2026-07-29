import CloudflareAPI
import FileProvider
import Foundation

enum FileProviderOperationKind: Sendable {
  case metadata
  case enumeration
  case download
  case upload
}

enum FileProviderCredentialFailure: Error, Sendable {
  case noToken
  case keychainUnavailable
}

struct FileProviderCredentialState: Sendable {
  let allowsWriting: Bool

  static func load(from tokenStore: KeychainTokenStore) async throws
    -> FileProviderCredentialState
  {
    let accessToken: String?
    do {
      accessToken = try await tokenStore.getAccessToken()
    } catch {
      // Protected Keychain data can be unavailable before the first unlock.
      throw FileProviderCredentialFailure.keychainUnavailable
    }

    guard let accessToken, !accessToken.isEmpty else {
      throw FileProviderCredentialFailure.noToken
    }

    let grantedScopes: Set<String>?
    do {
      grantedScopes = try await tokenStore.getGrantedScopes()
    } catch {
      throw FileProviderCredentialFailure.keychainUnavailable
    }

    return FileProviderCredentialState(
      allowsWriting: grantedScopes?.contains("workers-r2-bucket-item.write") == true)
  }
}

enum FileProviderErrorMapping {
  static func map(
    _ error: any Error,
    operation: FileProviderOperationKind
  ) -> NSError {
    if error is CancellationError {
      return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
    }

    if let credentialFailure = error as? FileProviderCredentialFailure {
      switch credentialFailure {
      case .noToken:
        return fileProviderError(.notAuthenticated)
      case .keychainUnavailable:
        return fileProviderError(.serverUnreachable)
      }
    }

    if error is CloudflareTransferError {
      switch operation {
      case .upload:
        return fileProviderError(.excludedFromSync)
      case .download:
        return fileProviderError(.cannotSynchronize)
      case .metadata, .enumeration:
        return fileProviderError(.serverUnreachable)
      }
    }

    if let apiError = error as? CloudflareAPIError {
      if apiError.isNotFound {
        return fileProviderError(.noSuchItem)
      }
      if apiError.isUnauthorized || apiError.isInvalidGrant {
        return fileProviderError(.notAuthenticated)
      }
      if apiError.isForbidden {
        // This is intentionally scoped to the item. Returning a provider-wide
        // authentication failure would make every bucket disappear.
        return NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
      }
      if apiError.isRateLimited || apiError.isTransport {
        // ServerUnreachable tells File Provider to back off instead of
        // retrying immediately into R2's account-wide REST request budget.
        return fileProviderError(.serverUnreachable)
      }
      return fileProviderError(.serverUnreachable)
    }

    if error is URLError {
      return fileProviderError(.serverUnreachable)
    }

    let cocoaError = error as NSError
    if cocoaError.domain == NSFileProviderErrorDomain
      || cocoaError.domain == NSCocoaErrorDomain
    {
      return cocoaError
    }

    // Unknown transport and decoding failures must also back off. File
    // Provider treats an unclassified error as immediately retryable.
    return fileProviderError(.serverUnreachable)
  }

  static var noSuchItem: NSError {
    fileProviderError(.noSuchItem)
  }

  static var filenameCollision: NSError {
    fileProviderError(.filenameCollision)
  }

  static var featureUnsupported: NSError {
    NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
  }

  static var writePermissionDenied: NSError {
    NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
  }

  private static func fileProviderError(_ code: NSFileProviderError.Code) -> NSError {
    NSFileProviderError(code) as NSError
  }
}

final class FileProviderSendableBox<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}

final class FileProviderOperationRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var finishedBeforeRegistration: Set<UUID> = []
  private var isInvalidated = false

  @discardableResult
  func start(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    let identifier = UUID()
    let task = Task { [weak self] in
      await operation()
      self?.finish(identifier)
    }

    let shouldCancel = lock.withLock {
      if isInvalidated {
        return true
      }
      if finishedBeforeRegistration.remove(identifier) == nil {
        tasks[identifier] = task
      }
      return false
    }
    if shouldCancel {
      task.cancel()
    }
    return task
  }

  func cancelAll() {
    let runningTasks = lock.withLock {
      isInvalidated = true
      let runningTasks = Array(tasks.values)
      tasks.removeAll()
      finishedBeforeRegistration.removeAll()
      return runningTasks
    }
    for task in runningTasks {
      task.cancel()
    }
  }

  private func finish(_ identifier: UUID) {
    lock.withLock {
      if tasks.removeValue(forKey: identifier) == nil, !isInvalidated {
        finishedBeforeRegistration.insert(identifier)
      }
    }
  }
}
