import Foundation

@MainActor
protocol ICloudKeyValueStoring: AnyObject {
  func object(forKey defaultName: String) -> Any?
  func set(_ anObject: Any?, forKey defaultName: String)
  @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: ICloudKeyValueStoring {}

/// Mirrors a deliberately small preference whitelist through iCloud KVS.
///
/// `UserDefaults` remains the UI-facing source so existing `@AppStorage`
/// bindings keep their immediate local behavior. iCloud is only a sync layer:
/// disabling it never removes local values or the copy already used by another
/// device, and an unavailable iCloud account leaves every setting usable here.
@MainActor
final class ICloudPreferencesSync {
  enum Group: String, CaseIterable, Sendable {
    case homeShortcuts
    case homeActions
    case workspaceWash
    case watchtowerLayout

    var cloudKey: String { "dash.preferences.v1.\(rawValue)" }
    var modifiedAtKey: String { "dash.icloud_preferences.modified.\(rawValue)" }
    var pendingModifiedAtKey: String {
      "dash.icloud_preferences.pending_modified.\(rawValue)"
    }

    var localKeys: [String] {
      switch self {
      case .homeShortcuts:
        [HomeShortcuts.key]
      case .homeActions:
        [HomeActions.key]
      case .workspaceWash:
        [DashWorkspaceWashPreset.storageKey]
      case .watchtowerLayout:
        [
          WatchtowerAnalyticsCardLayout.orderKey,
          WatchtowerAnalyticsCardLayout.key,
          WatchtowerAnalyticsCardLayout.hiddenKey,
        ]
      }
    }
  }

  struct Value: Codable, Equatable, Sendable {
    let presentKeys: [String]
    let strings: [String: String]
  }

  struct Envelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let modifiedAt: Date
    let value: Value

    init(modifiedAt: Date, value: Value) {
      schemaVersion = Self.currentSchemaVersion
      self.modifiedAt = modifiedAt
      self.value = value
    }
  }

  static let shared = ICloudPreferencesSync()
  static let enabledKey = "dash.icloud_preferences_enabled"
  static let didApplyRemoteChanges = Notification.Name(
    "sh.xat.dash.icloud-preferences-did-apply")
  nonisolated private static let changedGroupsUserInfoKey = "changedGroups"
  /// Pre-sync local preferences seed an empty KVS with deliberately old
  /// metadata. If the first iCloud download arrives after the quiet period,
  /// that cloud value still wins; only a real edit made by this version gets a
  /// current timestamp.
  private static let legacySeedModifiedAt = Date(timeIntervalSince1970: 0)

  private enum CloudEntry {
    case missing
    case invalid
    case value(Envelope)
  }

  private let defaults: UserDefaults
  private let cloudStore: any ICloudKeyValueStoring
  private let notificationCenter: NotificationCenter
  private let now: () -> Date
  private let initialSyncDelay: Duration
  private var cloudObserver: NSObjectProtocol?
  private var initialSyncTask: Task<Void, Never>?
  private var pendingRemoteEchoValues: [Group: Value] = [:]
  private var syncEnabled: Bool
  private var isStarted = false
  private var isReadyToUpload = false

  init(
    defaults: UserDefaults = .standard,
    cloudStore: any ICloudKeyValueStoring = NSUbiquitousKeyValueStore.default,
    notificationCenter: NotificationCenter = .default,
    initialSyncDelay: Duration = .seconds(1),
    now: @escaping () -> Date = Date.init
  ) {
    self.defaults = defaults
    self.cloudStore = cloudStore
    self.notificationCenter = notificationCenter
    self.initialSyncDelay = initialSyncDelay
    self.now = now
    syncEnabled = Self.isEnabled(in: defaults)
  }

  static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: enabledKey) as? Bool ?? true
  }

  static var shouldStartForCurrentProcess: Bool {
    shouldStart(
      arguments: ProcessInfo.processInfo.arguments,
      environment: ProcessInfo.processInfo.environment)
  }

  static func shouldStart(arguments: [String], environment: [String: String]) -> Bool {
    if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
      || environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestBundlePath"] != nil
      || arguments.contains("-ui-testing")
      || arguments.contains(where: {
        $0.hasPrefix("-ui-preview") || $0.hasPrefix("-uiTest")
      })
    {
      return false
    }
    return true
  }

  nonisolated static func changedGroups(in notification: Notification) -> Set<Group> {
    let rawValues =
      notification.userInfo?[changedGroupsUserInfoKey] as? [String] ?? []
    return Set(rawValues.compactMap(Group.init(rawValue:)))
  }

  func start() {
    guard !isStarted else { return }
    isStarted = true
    cloudObserver = notificationCenter.addObserver(
      forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
      object: cloudStore,
      queue: .main
    ) { [weak self] notification in
      let reason =
        notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        ?? NSUbiquitousKeyValueStoreServerChange
      let keys =
        notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
      MainActor.assumeIsolated {
        self?.handleExternalChange(reason: reason, keys: keys)
      }
    }
    if syncEnabled {
      beginInitialReconciliation()
    }
  }

  func stop() {
    initialSyncTask?.cancel()
    initialSyncTask = nil
    if let cloudObserver {
      notificationCenter.removeObserver(cloudObserver)
      self.cloudObserver = nil
    }
    isReadyToUpload = false
    isStarted = false
  }

  func setEnabled(_ enabled: Bool) {
    if defaults.object(forKey: Self.enabledKey) as? Bool != enabled {
      defaults.set(enabled, forKey: Self.enabledKey)
    }
    guard syncEnabled != enabled else { return }
    syncEnabled = enabled
    initialSyncTask?.cancel()
    initialSyncTask = nil
    isReadyToUpload = false
    guard enabled, isStarted else { return }
    beginInitialReconciliation()
  }

  /// Called at the concrete local write boundary for one managed preference.
  /// Explicit publishing keeps the Watchtower layout's three local keys from
  /// ever being observed or uploaded halfway through its transaction.
  func publish(_ group: Group) {
    guard isStarted else { return }
    let local = localValue(for: group)
    if let remote = pendingRemoteEchoValues.removeValue(forKey: group),
      remote == local
    {
      return
    }
    guard isSemanticallyValid(local, for: group) else { return }

    let existingEntry = cloudEntry(for: group)
    // An older app must not replace an envelope written by a newer schema or
    // one containing preference tokens it cannot represent. Keep the edit
    // local without giving it a sync timestamp, so a future compatible version
    // still adopts the cloud value.
    if case .invalid = existingEntry { return }

    let modifiedAt = nextModifiedAt(for: group)
    defaults.set(modifiedAt, forKey: group.modifiedAtKey)
    defaults.set(modifiedAt, forKey: group.pendingModifiedAtKey)
    guard syncEnabled, isReadyToUpload else { return }
    upload(local, modifiedAt: modifiedAt, for: group)
  }

  /// iCloud already synchronizes automatically on lifecycle transitions. This
  /// sparse foreground hint also heals a launch where the account or entitlement
  /// was temporarily unavailable without turning the setting off.
  func refresh() {
    guard isStarted, syncEnabled else { return }
    guard cloudStore.synchronize() else {
      isReadyToUpload = false
      return
    }
    if !isReadyToUpload {
      applyAvailableCloudValues()
      scheduleInitialReconciliation()
    }
  }

  private func beginInitialReconciliation() {
    initialSyncTask?.cancel()
    initialSyncTask = nil
    isReadyToUpload = false
    guard cloudStore.synchronize() else { return }
    applyAvailableCloudValues()
    scheduleInitialReconciliation()
  }

  private func scheduleInitialReconciliation() {
    initialSyncTask?.cancel()
    initialSyncTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: initialSyncDelay)
      } catch {
        return
      }
      completeInitialReconciliation()
    }
  }

  /// Internal so the pure store tests can complete startup deterministically
  /// without waiting on a clock or a real iCloud account.
  func completeInitialReconciliation() {
    initialSyncTask?.cancel()
    initialSyncTask = nil
    guard isStarted, syncEnabled, cloudStore.synchronize() else {
      isReadyToUpload = false
      return
    }

    var applied = Set<Group>()
    for group in Group.allCases where reconcile(group, allowUpload: true) {
      applied.insert(group)
    }
    isReadyToUpload = true
    postApplied(applied)
  }

  private func reconcile(_ group: Group, allowUpload: Bool) -> Bool {
    let local = localValue(for: group)
    let localModifiedAt =
      [
        defaults.object(forKey: group.modifiedAtKey) as? Date,
        defaults.object(forKey: group.pendingModifiedAtKey) as? Date,
      ].compactMap { $0 }.max()

    switch cloudEntry(for: group) {
    case .missing:
      guard allowUpload, !local.presentKeys.isEmpty || localModifiedAt != nil else {
        return false
      }
      guard isSemanticallyValid(local, for: group) else { return false }
      let modifiedAt = localModifiedAt ?? Self.legacySeedModifiedAt
      upload(local, modifiedAt: modifiedAt, for: group)
      return false

    case .invalid:
      // A future or corrupt value must not be replaced with this device's
      // defaults. Keep operating locally until a compatible value arrives.
      return false

    case .value(let cloud):
      if let localModifiedAt, localModifiedAt > cloud.modifiedAt {
        if allowUpload {
          upload(local, modifiedAt: localModifiedAt, for: group)
        }
        return false
      }
      return apply(cloud, to: group)
    }
  }

  /// Internal test seam mirroring `didChangeExternallyNotification`.
  func handleExternalChange(reason: Int, keys: [String]?) {
    guard isStarted else { return }

    switch reason {
    case NSUbiquitousKeyValueStoreQuotaViolationChange:
      // Local preferences remain authoritative while KVS is over quota.
      initialSyncTask?.cancel()
      initialSyncTask = nil
      isReadyToUpload = false
      return
    case NSUbiquitousKeyValueStoreAccountChange:
      resetCloudAccountState()
      guard syncEnabled else { return }
      beginInitialReconciliation()
      return
    default:
      break
    }
    guard syncEnabled else { return }

    let groups = groups(forCloudKeys: keys)
    let isInitialSync =
      reason == NSUbiquitousKeyValueStoreInitialSyncChange
    if isInitialSync {
      // Apple reports this while the first download is still in progress.
      // Reads are safe, but writes must wait until the quiet-period retry.
      isReadyToUpload = false
    }

    var applied = Set<Group>()
    for group in groups {
      if reconcile(group, allowUpload: isReadyToUpload) {
        applied.insert(group)
      }
    }
    postApplied(applied)

    if isInitialSync || !isReadyToUpload {
      scheduleInitialReconciliation()
    }
  }

  private func applyAvailableCloudValues() {
    var applied = Set<Group>()
    for group in Group.allCases where reconcile(group, allowUpload: false) {
      applied.insert(group)
    }
    postApplied(applied)
  }

  private func resetCloudAccountState() {
    initialSyncTask?.cancel()
    initialSyncTask = nil
    isReadyToUpload = false
    pendingRemoteEchoValues.removeAll()
    for group in Group.allCases {
      // This baseline belongs to the previous Apple account. A separately
      // persisted pending timestamp survives only for a genuine local edit.
      defaults.removeObject(forKey: group.modifiedAtKey)
    }
  }

  private func groups(forCloudKeys keys: [String]?) -> [Group] {
    guard let keys else { return Group.allCases }
    let changed = Set(keys)
    return Group.allCases.filter { changed.contains($0.cloudKey) }
  }

  private func localValue(for group: Group) -> Value {
    let presentKeys = group.localKeys.filter { defaults.object(forKey: $0) != nil }.sorted()
    let strings = Dictionary(
      uniqueKeysWithValues: presentKeys.map { ($0, defaults.string(forKey: $0) ?? "") })
    return Value(presentKeys: presentKeys, strings: strings)
  }

  private func cloudEntry(for group: Group) -> CloudEntry {
    guard let object = cloudStore.object(forKey: group.cloudKey) else { return .missing }
    guard
      let data = object as? Data,
      let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
      envelope.schemaVersion == Envelope.currentSchemaVersion,
      isValid(envelope.value, for: group)
    else {
      return .invalid
    }
    return .value(envelope)
  }

  private func isValid(_ value: Value, for group: Group) -> Bool {
    let allowed = Set(group.localKeys)
    let present = Set(value.presentKeys)
    let strings = Set(value.strings.keys)
    return present.count == value.presentKeys.count
      && present.isSubset(of: allowed)
      && strings == present
      && isSemanticallyValid(value, for: group)
  }

  private func isSemanticallyValid(_ value: Value, for group: Group) -> Bool {
    switch group {
    case .homeShortcuts:
      guard let raw = value.strings[HomeShortcuts.key] else { return true }
      return HomeShortcuts.encode(HomeShortcuts.decode(raw)) == raw

    case .homeActions:
      guard let raw = value.strings[HomeActions.key] else { return true }
      return HomeActions.encode(HomeActions.decode(raw)) == raw

    case .workspaceWash:
      guard let raw = value.strings[DashWorkspaceWashPreset.storageKey] else {
        return true
      }
      return DashWorkspaceWashPreset(rawValue: raw) != nil

    case .watchtowerLayout:
      let allowed = Set(WatchtowerAnalyticsMetric.allCases.map(\.rawValue))
      for key in group.localKeys {
        guard let raw = value.strings[key] else { continue }
        guard let tokens = commaSeparatedTokens(raw),
          Set(tokens).count == tokens.count,
          tokens.allSatisfy(allowed.contains)
        else {
          return false
        }
      }
      return true
    }
  }

  private func commaSeparatedTokens(_ raw: String) -> [String]? {
    guard !raw.isEmpty else { return [] }
    let tokens = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    return tokens.allSatisfy { !$0.isEmpty } ? tokens : nil
  }

  private func apply(_ envelope: Envelope, to group: Group) -> Bool {
    let previous = localValue(for: group)
    pendingRemoteEchoValues[group] = envelope.value
    let present = Set(envelope.value.presentKeys)
    for key in group.localKeys {
      if present.contains(key) {
        defaults.set(envelope.value.strings[key] ?? "", forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
    }
    defaults.set(envelope.modifiedAt, forKey: group.modifiedAtKey)
    defaults.removeObject(forKey: group.pendingModifiedAtKey)
    return previous != envelope.value
  }

  private func upload(_ value: Value, modifiedAt: Date, for group: Group) {
    let envelope = Envelope(modifiedAt: modifiedAt, value: value)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(envelope) else { return }
    cloudStore.set(data, forKey: group.cloudKey)
    defaults.set(modifiedAt, forKey: group.modifiedAtKey)
    defaults.removeObject(forKey: group.pendingModifiedAtKey)
  }

  private func nextModifiedAt(for group: Group) -> Date {
    let current = now()
    let localDates = [
      defaults.object(forKey: group.modifiedAtKey) as? Date,
      defaults.object(forKey: group.pendingModifiedAtKey) as? Date,
    ].compactMap { $0 }
    let cloud: Date?
    if case .value(let envelope) = cloudEntry(for: group) {
      cloud = envelope.modifiedAt
    } else {
      cloud = nil
    }
    let baseline = (localDates + [cloud].compactMap { $0 }).max() ?? .distantPast
    return current > baseline ? current : baseline.addingTimeInterval(0.001)
  }

  private func postApplied(_ groups: Set<Group>) {
    guard !groups.isEmpty else { return }
    if groups.contains(.homeActions) {
      HomeActions.mirrorToAppGroup(
        defaults.string(forKey: HomeActions.key) ?? HomeActions.defaultValue)
    }
    notificationCenter.post(
      name: Self.didApplyRemoteChanges,
      object: self,
      userInfo: [Self.changedGroupsUserInfoKey: groups.map(\.rawValue).sorted()])
  }
}
