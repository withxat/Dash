enum DitherSelection {
  static func normalized(_ selectedID: String?, validIDs: some Collection<String>) -> String? {
    guard let selectedID, validIDs.contains(selectedID) else { return nil }
    return selectedID
  }
}
