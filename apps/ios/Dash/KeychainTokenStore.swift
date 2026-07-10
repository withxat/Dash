import CloudflareAPI
import Foundation
import Security

actor KeychainTokenStore: TokenStore {
  private enum Key {
    static let access = "dash.access_token"
    static let refresh = "dash.refresh_token"
    static let expiry = "dash.expires_at"
    static let scopes = "dash.granted_scopes"
  }

  private let service = "sh.xat.dash"

  private var accessGroup: String? {
    guard
      let group = Bundle.main.object(forInfoDictionaryKey: "DashKeychainAccessGroup") as? String,
      !group.isEmpty, !group.contains("$(")
    else { return nil }
    return group
  }

  func clear() async throws {
    try delete(Key.access)
    try delete(Key.refresh)
    try delete(Key.expiry)
    try delete(Key.scopes)
  }

  func getAccessToken() async throws -> String? { try read(Key.access) }
  func getRefreshToken() async throws -> String? { try read(Key.refresh) }
  func getGrantedScopes() async throws -> Set<String>? {
    guard let value = try read(Key.scopes) else { return nil }
    return Set(value.split(separator: " ").map(String.init))
  }

  func setGrantedScopes(_ scopes: Set<String>) async throws {
    try write(scopes.sorted().joined(separator: " "), key: Key.scopes)
  }

  func setTokens(_ tokens: TokenSet) async throws {
    try write(tokens.accessToken, key: Key.access)
    if let refresh = tokens.refreshToken { try write(refresh, key: Key.refresh) }
    if let scope = tokens.scope {
      try write(
        scope.split(separator: " ").map(String.init).sorted().joined(separator: " "),
        key: Key.scopes
      )
    }
    if let expiresIn = tokens.expiresIn {
      try write(
        String(Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970),
        key: Key.expiry)
    }
  }

  private func query(_ key: String) -> [String: Any] {
    var item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key,
      kSecAttrService as String: service,
    ]
    if let accessGroup {
      item[kSecAttrAccessGroup as String] = accessGroup
    }
    return item
  }

  private func read(_ key: String) throws -> String? {
    var query = query(key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status) }
    return String(data: data, encoding: .utf8)
  }

  private func write(_ value: String, key: String) throws {
    let data = Data(value.utf8)
    let status = SecItemUpdate(
      query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = query(key)
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = SecItemAdd(item as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw KeychainError(addStatus) }
    } else if status != errSecSuccess {
      throw KeychainError(status)
    }
  }

  private func delete(_ key: String) throws {
    let status = SecItemDelete(query(key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status)
    }
  }
}

private struct KeychainError: Error, LocalizedError {
  let status: OSStatus
  init(_ status: OSStatus) { self.status = status }
  var errorDescription: String? {
    SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
  }
}
