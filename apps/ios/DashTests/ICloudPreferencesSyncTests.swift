import Foundation
import Testing

@testable import Dash

@Test @MainActor func iCloudPreferenceSyncDefaultsToEnabledWithoutPersistingTheDefault() {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }

  #expect(ICloudPreferencesSync.isEnabled(in: defaults))
  #expect(defaults.object(forKey: ICloudPreferencesSync.enabledKey) == nil)
}

@Test @MainActor func productionICloudSyncDoesNotStartInsideTestOrPreviewProcesses() {
  #expect(
    !ICloudPreferencesSync.shouldStart(
      arguments: ["Dash"],
      environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]))
  #expect(
    !ICloudPreferencesSync.shouldStart(
      arguments: ["Dash"],
      environment: ["XCTestBundlePath": "/tmp/DashTests.xctest"]))
  #expect(
    !ICloudPreferencesSync.shouldStart(
      arguments: ["Dash", "-ui-testing"],
      environment: [:]))
  #expect(
    !ICloudPreferencesSync.shouldStart(
      arguments: ["Dash"],
      environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"]))
  #expect(ICloudPreferencesSync.shouldStart(arguments: ["Dash"], environment: [:]))
}

@Test @MainActor func iCloudPreferenceSyncAdoptsAnExistingCloudValueOnFirstUse() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(HomeActions.encode([.enableUnderAttackMode]), forKey: HomeActions.key)

  let cloud = FakeICloudKeyValueStore()
  let cloudValue = HomeActions.encode([.uploadR2, .addDomain])
  cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] = try encodedEnvelope(
    values: [HomeActions.key: cloudValue],
    modifiedAt: Date(timeIntervalSince1970: 100))

  let sync = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60))
  defer { sync.stop() }
  sync.start()

  #expect(defaults.string(forKey: HomeActions.key) == cloudValue)
}

@Test @MainActor func iCloudPreferenceSyncSeedsOnlyExplicitLocalPreferences() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  let shortcuts = HomeShortcuts.encode([.workers, .kv])
  defaults.set(shortcuts, forKey: HomeShortcuts.key)

  let cloud = FakeICloudKeyValueStore()
  let sync = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60),
    now: { Date(timeIntervalSince1970: 200) })
  defer { sync.stop() }
  sync.start()
  sync.completeInitialReconciliation()

  let envelope = try decodedEnvelope(
    cloud.values[ICloudPreferencesSync.Group.homeShortcuts.cloudKey])
  #expect(envelope.value.presentKeys == [HomeShortcuts.key])
  #expect(envelope.value.strings[HomeShortcuts.key] == shortcuts)
  #expect(cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] == nil)
  #expect(cloud.values[ICloudPreferencesSync.Group.workspaceWash.cloudKey] == nil)
  #expect(cloud.values[ICloudPreferencesSync.Group.watchtowerLayout.cloudKey] == nil)
}

@Test @MainActor func disabledICloudPreferenceSyncBlocksBothDirectionsAndReenableMerges() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(false, forKey: ICloudPreferencesSync.enabledKey)
  let localValue = HomeActions.encode([.enableUnderAttackMode])
  defaults.set(localValue, forKey: HomeActions.key)

  let cloud = FakeICloudKeyValueStore()
  let cloudValue = HomeActions.encode([.uploadR2])
  cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] = try encodedEnvelope(
    values: [HomeActions.key: cloudValue],
    modifiedAt: Date(timeIntervalSince1970: 100))

  let sync = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60),
    now: { Date(timeIntervalSince1970: 300) })
  defer { sync.stop() }
  sync.start()
  sync.handleExternalChange(
    reason: NSUbiquitousKeyValueStoreServerChange,
    keys: [ICloudPreferencesSync.Group.homeActions.cloudKey])
  #expect(defaults.string(forKey: HomeActions.key) == localValue)

  let newerLocalValue = HomeActions.encode([.addDomain, .enableUnderAttackMode])
  defaults.set(newerLocalValue, forKey: HomeActions.key)
  sync.publish(.homeActions)
  #expect(
    try decodedEnvelope(cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey])
      .value.strings[HomeActions.key] == cloudValue)

  sync.setEnabled(true)
  sync.completeInitialReconciliation()
  let merged = try decodedEnvelope(
    cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey])
  #expect(merged.value.strings[HomeActions.key] == newerLocalValue)
}

@Test @MainActor func disabledLocalEditSurvivesCoordinatorRestartBeforeReenable() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(false, forKey: ICloudPreferencesSync.enabledKey)

  let cloud = FakeICloudKeyValueStore()
  cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] = try encodedEnvelope(
    values: [HomeActions.key: HomeActions.encode([.uploadR2])],
    modifiedAt: Date(timeIntervalSince1970: 100))

  let first = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60),
    now: { Date(timeIntervalSince1970: 300) })
  first.start()
  let localValue = HomeActions.encode([.addDomain, .enableUnderAttackMode])
  defaults.set(localValue, forKey: HomeActions.key)
  first.publish(.homeActions)
  first.stop()

  let second = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60),
    now: { Date(timeIntervalSince1970: 400) })
  defer { second.stop() }
  second.start()
  #expect(defaults.string(forKey: HomeActions.key) == localValue)

  second.setEnabled(true)
  second.completeInitialReconciliation()
  let merged = try decodedEnvelope(
    cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey])
  #expect(merged.value.strings[HomeActions.key] == localValue)
}

@Test @MainActor func disabledEditBackToCloudValueStaysPendingAcrossRestart() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(false, forKey: ICloudPreferencesSync.enabledKey)

  let cloud = FakeICloudKeyValueStore()
  let originalCloudValue = HomeActions.encode([.uploadR2])
  cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] = try encodedEnvelope(
    values: [HomeActions.key: originalCloudValue],
    modifiedAt: Date(timeIntervalSince1970: 100))

  let first = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60),
    now: { Date(timeIntervalSince1970: 300) })
  first.start()
  defaults.set(HomeActions.encode([.enableUnderAttackMode]), forKey: HomeActions.key)
  first.publish(.homeActions)
  first.stop()

  let second = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60),
    now: { Date(timeIntervalSince1970: 400) })
  defer { second.stop() }
  second.start()
  defaults.set(originalCloudValue, forKey: HomeActions.key)
  second.publish(.homeActions)

  let laterRemoteValue = HomeActions.encode([.createKVKey])
  cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] = try encodedEnvelope(
    values: [HomeActions.key: laterRemoteValue],
    modifiedAt: Date(timeIntervalSince1970: 200))
  second.setEnabled(true)
  second.completeInitialReconciliation()

  #expect(defaults.string(forKey: HomeActions.key) == originalCloudValue)
  let merged = try decodedEnvelope(
    cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey])
  #expect(merged.value.strings[HomeActions.key] == originalCloudValue)
  #expect(merged.modifiedAt == Date(timeIntervalSince1970: 400))
}

@Test @MainActor func disabledEditBackToAppliedValueIsNotMistakenForRemoteEcho() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }

  let cloud = FakeICloudKeyValueStore()
  let appliedValue = HomeActions.encode([.uploadR2])
  cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] = try encodedEnvelope(
    values: [HomeActions.key: appliedValue],
    modifiedAt: Date(timeIntervalSince1970: 100))
  let sync = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60),
    now: { Date(timeIntervalSince1970: 300) })
  defer { sync.stop() }
  sync.start()
  sync.setEnabled(false)

  defaults.set(HomeActions.encode([.enableUnderAttackMode]), forKey: HomeActions.key)
  sync.publish(.homeActions)
  defaults.set(appliedValue, forKey: HomeActions.key)
  sync.publish(.homeActions)

  let remoteValue = HomeActions.encode([.createKVKey])
  cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] = try encodedEnvelope(
    values: [HomeActions.key: remoteValue],
    modifiedAt: Date(timeIntervalSince1970: 300.0005))
  sync.setEnabled(true)
  sync.completeInitialReconciliation()

  #expect(defaults.string(forKey: HomeActions.key) == appliedValue)
  let merged = try decodedEnvelope(
    cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey])
  #expect(merged.value.strings[HomeActions.key] == appliedValue)
  #expect(merged.modifiedAt > Date(timeIntervalSince1970: 300.0005))
}

@Test @MainActor func disabledLocalEditSurvivesICloudAccountChangeBeforeReenable() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(false, forKey: ICloudPreferencesSync.enabledKey)

  let cloud = FakeICloudKeyValueStore()
  let sync = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60),
    now: { Date(timeIntervalSince1970: 300) })
  defer { sync.stop() }
  sync.start()

  let localValue = HomeActions.encode([.addDomain, .enableUnderAttackMode])
  defaults.set(localValue, forKey: HomeActions.key)
  sync.publish(.homeActions)

  let otherAccountValue = HomeActions.encode([.uploadR2])
  cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] = try encodedEnvelope(
    values: [HomeActions.key: otherAccountValue],
    modifiedAt: Date(timeIntervalSince1970: 100))
  sync.handleExternalChange(
    reason: NSUbiquitousKeyValueStoreAccountChange,
    keys: nil)

  sync.setEnabled(true)
  sync.completeInitialReconciliation()

  #expect(defaults.string(forKey: HomeActions.key) == localValue)
  let merged = try decodedEnvelope(
    cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey])
  #expect(merged.value.strings[HomeActions.key] == localValue)
}

@Test @MainActor func iCloudAccountChangeDoesNotCarryOldCloudBaselineIntoNewAccount() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }

  let cloud = FakeICloudKeyValueStore()
  let oldAccountValue = HomeActions.encode([.enableUnderAttackMode])
  cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] = try encodedEnvelope(
    values: [HomeActions.key: oldAccountValue],
    modifiedAt: Date(timeIntervalSince1970: 500))
  let sync = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60))
  defer { sync.stop() }
  sync.start()
  #expect(defaults.string(forKey: HomeActions.key) == oldAccountValue)

  sync.setEnabled(false)
  let newAccountValue = HomeActions.encode([.uploadR2])
  cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] = try encodedEnvelope(
    values: [HomeActions.key: newAccountValue],
    modifiedAt: Date(timeIntervalSince1970: 100))
  let writesBeforeAccountChange = cloud.setKeys.count
  sync.handleExternalChange(
    reason: NSUbiquitousKeyValueStoreAccountChange,
    keys: nil)

  sync.setEnabled(true)
  sync.completeInitialReconciliation()

  #expect(defaults.string(forKey: HomeActions.key) == newAccountValue)
  #expect(cloud.setKeys.count == writesBeforeAccountChange)
}

@Test @MainActor func initialICloudDownloadDoesNotOverwriteANewerPendingLocalEdit() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  let localValue = HomeActions.encode([.addDomain, .enableUnderAttackMode])
  defaults.set(localValue, forKey: HomeActions.key)
  defaults.set(
    Date(timeIntervalSince1970: 200),
    forKey: ICloudPreferencesSync.Group.homeActions.pendingModifiedAtKey)

  let cloud = FakeICloudKeyValueStore()
  let cloudValue = HomeActions.encode([.uploadR2])
  cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] = try encodedEnvelope(
    values: [HomeActions.key: cloudValue],
    modifiedAt: Date(timeIntervalSince1970: 100))

  let sync = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60))
  defer { sync.stop() }
  sync.start()
  sync.handleExternalChange(
    reason: NSUbiquitousKeyValueStoreInitialSyncChange,
    keys: [ICloudPreferencesSync.Group.homeActions.cloudKey])

  #expect(defaults.string(forKey: HomeActions.key) == localValue)
  #expect(cloud.setKeys.isEmpty)

  sync.completeInitialReconciliation()
  let merged = try decodedEnvelope(
    cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey])
  #expect(merged.value.strings[HomeActions.key] == localValue)
}

@Test @MainActor func lateInitialCloudValueWinsOverALegacyLocalSeed() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(HomeActions.encode([.enableUnderAttackMode]), forKey: HomeActions.key)

  let cloud = FakeICloudKeyValueStore()
  let sync = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60))
  defer { sync.stop() }
  sync.start()
  sync.completeInitialReconciliation()

  let incoming = HomeActions.encode([.uploadR2, .addDomain])
  cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] = try encodedEnvelope(
    values: [HomeActions.key: incoming],
    modifiedAt: Date(timeIntervalSince1970: 100))
  sync.handleExternalChange(
    reason: NSUbiquitousKeyValueStoreInitialSyncChange,
    keys: [ICloudPreferencesSync.Group.homeActions.cloudKey])

  #expect(defaults.string(forKey: HomeActions.key) == incoming)
}

@Test @MainActor func unavailableICloudStoreKeepsPreferencesLocalUntilRefreshSucceeds() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  let cloud = FakeICloudKeyValueStore()
  cloud.synchronizeResult = false

  let sync = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60),
    now: { Date(timeIntervalSince1970: 300) })
  defer { sync.stop() }
  sync.start()

  let localValue = HomeShortcuts.encode([.workers, .r2])
  defaults.set(localValue, forKey: HomeShortcuts.key)
  sync.publish(.homeShortcuts)
  #expect(defaults.string(forKey: HomeShortcuts.key) == localValue)
  #expect(cloud.setKeys.isEmpty)

  cloud.synchronizeResult = true
  sync.refresh()
  sync.completeInitialReconciliation()
  let uploaded = try decodedEnvelope(
    cloud.values[ICloudPreferencesSync.Group.homeShortcuts.cloudKey])
  #expect(uploaded.value.strings[HomeShortcuts.key] == localValue)
}

@Test @MainActor func applyingAnExternalPreferenceDoesNotEchoItBackToICloud() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }

  let cloud = FakeICloudKeyValueStore()
  let initial = HomeActions.encode([.enableUnderAttackMode])
  cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] = try encodedEnvelope(
    values: [HomeActions.key: initial],
    modifiedAt: Date(timeIntervalSince1970: 100))
  let sync = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60))
  defer { sync.stop() }
  sync.start()

  let incoming = HomeActions.encode([.uploadR2, .createKVKey])
  cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] = try encodedEnvelope(
    values: [HomeActions.key: incoming],
    modifiedAt: Date(timeIntervalSince1970: 200))
  let writesBeforeChange = cloud.setKeys.count
  sync.handleExternalChange(
    reason: NSUbiquitousKeyValueStoreServerChange,
    keys: [ICloudPreferencesSync.Group.homeActions.cloudKey])
  sync.publish(.homeActions)

  #expect(defaults.string(forKey: HomeActions.key) == incoming)
  #expect(cloud.setKeys.count == writesBeforeChange)
}

@Test @MainActor func olderExternalValueCannotOverwriteANewerUploadedPreference() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }

  let cloud = FakeICloudKeyValueStore()
  cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] = try encodedEnvelope(
    values: [HomeActions.key: HomeActions.encode([.enableUnderAttackMode])],
    modifiedAt: Date(timeIntervalSince1970: 100))
  let sync = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60),
    now: { Date(timeIntervalSince1970: 300) })
  defer { sync.stop() }
  sync.start()
  sync.completeInitialReconciliation()

  let newerLocalValue = HomeActions.encode([.uploadR2])
  defaults.set(newerLocalValue, forKey: HomeActions.key)
  sync.publish(.homeActions)

  let olderRemoteValue = HomeActions.encode([.createKVKey])
  cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey] = try encodedEnvelope(
    values: [HomeActions.key: olderRemoteValue],
    modifiedAt: Date(timeIntervalSince1970: 200))
  sync.handleExternalChange(
    reason: NSUbiquitousKeyValueStoreServerChange,
    keys: [ICloudPreferencesSync.Group.homeActions.cloudKey])

  #expect(defaults.string(forKey: HomeActions.key) == newerLocalValue)
  let restored = try decodedEnvelope(
    cloud.values[ICloudPreferencesSync.Group.homeActions.cloudKey])
  #expect(restored.value.strings[HomeActions.key] == newerLocalValue)
  #expect(restored.modifiedAt == Date(timeIntervalSince1970: 300))
}

@Test @MainActor func externalStoreNotificationAppliesAndPublishesItsChangedGroup() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  let cloud = FakeICloudKeyValueStore()
  let center = NotificationCenter()
  let sync = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: center,
    initialSyncDelay: .seconds(60))
  defer { sync.stop() }
  sync.start()
  sync.completeInitialReconciliation()

  let recorder = ICloudNotificationRecorder()
  let observer = center.addObserver(
    forName: ICloudPreferencesSync.didApplyRemoteChanges,
    object: sync,
    queue: .main
  ) { notification in
    let groups = ICloudPreferencesSync.changedGroups(in: notification)
    MainActor.assumeIsolated {
      recorder.record(groups)
    }
  }
  defer { center.removeObserver(observer) }

  cloud.values[ICloudPreferencesSync.Group.workspaceWash.cloudKey] = try encodedEnvelope(
    values: [DashWorkspaceWashPreset.storageKey: DashWorkspaceWashPreset.teal.rawValue],
    modifiedAt: Date(timeIntervalSince1970: 100))
  center.post(
    name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
    object: cloud,
    userInfo: [
      NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreServerChange,
      NSUbiquitousKeyValueStoreChangedKeysKey: [
        ICloudPreferencesSync.Group.workspaceWash.cloudKey
      ],
    ])

  #expect(
    defaults.string(forKey: DashWorkspaceWashPreset.storageKey)
      == DashWorkspaceWashPreset.teal.rawValue)
  #expect(recorder.groups == [.workspaceWash])
}

@Test @MainActor func watchtowerLayoutSyncsAsOneValueAndReloadsAfterEditing() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set("cpuTime,webTraffic", forKey: WatchtowerAnalyticsCardLayout.orderKey)
  defaults.set("cpuTime", forKey: WatchtowerAnalyticsCardLayout.key)
  defaults.set("", forKey: WatchtowerAnalyticsCardLayout.hiddenKey)

  let cloud = FakeICloudKeyValueStore()
  let sync = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60))
  defer { sync.stop() }
  sync.start()
  sync.completeInitialReconciliation()

  let envelope = try decodedEnvelope(
    cloud.values[ICloudPreferencesSync.Group.watchtowerLayout.cloudKey])
  #expect(
    envelope.value.presentKeys
      == [
        WatchtowerAnalyticsCardLayout.key,
        WatchtowerAnalyticsCardLayout.hiddenKey,
        WatchtowerAnalyticsCardLayout.orderKey,
      ].sorted())
  #expect(envelope.value.strings[WatchtowerAnalyticsCardLayout.hiddenKey] == "")

  let state = WatchtowerChartCustomizationState(defaults: defaults)
  state.beginEditing()
  defaults.set("webTraffic,cpuTime", forKey: WatchtowerAnalyticsCardLayout.orderKey)
  defaults.set("", forKey: WatchtowerAnalyticsCardLayout.key)
  defaults.set("cpuTime", forKey: WatchtowerAnalyticsCardLayout.hiddenKey)
  state.reloadPersistedLayout()
  state.cancelEditing()

  #expect(state.order.first == .webTraffic)
  #expect(state.hidden == [.cpuTime])
}

@Test @MainActor func unknownPreferenceTokenNeverOverwritesOrGetsRewritten() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  let local = HomeShortcuts.encode([.workers, .r2])
  defaults.set(local, forKey: HomeShortcuts.key)

  let cloud = FakeICloudKeyValueStore()
  cloud.values[ICloudPreferencesSync.Group.homeShortcuts.cloudKey] = try encodedEnvelope(
    values: [HomeShortcuts.key: "\(FeatureID.zones.rawValue),future-feature"],
    modifiedAt: Date(timeIntervalSince1970: 100))
  let sync = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60))
  defer { sync.stop() }
  sync.start()
  sync.completeInitialReconciliation()

  #expect(defaults.string(forKey: HomeShortcuts.key) == local)
  defaults.set(HomeShortcuts.encode([.r2, .zones]), forKey: HomeShortcuts.key)
  sync.publish(.homeShortcuts)
  #expect(cloud.setKeys.isEmpty)
}

@Test @MainActor func unknownICloudPreferenceSchemaNeverOverwritesLocalState() throws {
  let (defaults, suite) = iCloudTestDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  let local = HomeShortcuts.encode([.zones, .r2])
  defaults.set(local, forKey: HomeShortcuts.key)

  var json = try #require(
    JSONSerialization.jsonObject(
      with: encodedEnvelope(
        values: [HomeShortcuts.key: HomeShortcuts.encode([.workers])],
        modifiedAt: Date(timeIntervalSince1970: 100))
    ) as? [String: Any])
  json["schemaVersion"] = 99

  let cloud = FakeICloudKeyValueStore()
  cloud.values[ICloudPreferencesSync.Group.homeShortcuts.cloudKey] =
    try JSONSerialization.data(withJSONObject: json)
  let sync = ICloudPreferencesSync(
    defaults: defaults,
    cloudStore: cloud,
    notificationCenter: NotificationCenter(),
    initialSyncDelay: .seconds(60))
  defer { sync.stop() }
  sync.start()

  #expect(defaults.string(forKey: HomeShortcuts.key) == local)
  #expect(cloud.setKeys.isEmpty)

  sync.completeInitialReconciliation()
  defaults.set(HomeShortcuts.encode([.r2, .workers]), forKey: HomeShortcuts.key)
  sync.publish(.homeShortcuts)
  #expect(cloud.setKeys.isEmpty)
}

@MainActor
private final class FakeICloudKeyValueStore: ICloudKeyValueStoring {
  var values: [String: Any] = [:]
  var synchronizeResult = true
  private(set) var setKeys: [String] = []
  private(set) var synchronizeCount = 0

  func object(forKey defaultName: String) -> Any? {
    values[defaultName]
  }

  func set(_ anObject: Any?, forKey defaultName: String) {
    setKeys.append(defaultName)
    if let anObject {
      values[defaultName] = anObject
    } else {
      values.removeValue(forKey: defaultName)
    }
  }

  func synchronize() -> Bool {
    synchronizeCount += 1
    return synchronizeResult
  }
}

@MainActor
private final class ICloudNotificationRecorder {
  private(set) var groups = Set<ICloudPreferencesSync.Group>()

  func record(_ changedGroups: Set<ICloudPreferencesSync.Group>) {
    groups.formUnion(changedGroups)
  }
}

@MainActor
private func iCloudTestDefaults() -> (defaults: UserDefaults, suite: String) {
  let suite = "ICloudPreferencesSyncTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return (defaults, suite)
}

@MainActor
private func encodedEnvelope(
  values: [String: String],
  modifiedAt: Date
) throws -> Data {
  let value = ICloudPreferencesSync.Value(
    presentKeys: values.keys.sorted(),
    strings: values)
  return try JSONEncoder().encode(
    ICloudPreferencesSync.Envelope(modifiedAt: modifiedAt, value: value))
}

@MainActor
private func decodedEnvelope(_ object: Any?) throws -> ICloudPreferencesSync.Envelope {
  let data = try #require(object as? Data)
  return try JSONDecoder().decode(ICloudPreferencesSync.Envelope.self, from: data)
}
