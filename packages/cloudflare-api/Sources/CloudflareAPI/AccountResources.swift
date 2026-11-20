import Foundation

public struct AccountUpdateInput: Encodable, Hashable, Sendable {
  public let name: String

  public init(name: String) {
    self.name = name
  }
}

extension CloudflareClient {
  @discardableResult
  public func updateAccount(accountID: String, input: AccountUpdateInput) async throws
    -> CloudflareAccount
  {
    try await request("/accounts/\(accountID)", method: "PUT", body: input)
  }
}
