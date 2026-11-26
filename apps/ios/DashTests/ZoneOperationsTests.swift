import CloudflareAPI
import CoreText
import SwiftUI
import Testing
import UIKit

@testable import Dash

@Test @MainActor func emailRoutingListStatusReadsSettingsCacheBeforeSnapshot() {
  let cache = FeatureDataCache()
  let zoneID = "zone-list-status"
  let settings = EmailRoutingSettings(
    id: "email-1", name: "example.com", enabled: true, status: "ready")
  // Settings-only write must not require a full snapshot — that was how the
  // domains index waited on a detail visit before any row could badge.
  EmailRoutingStatusMapping.storeListSettings(settings, zoneID: zoneID, cache: cache)
  #expect(
    EmailRoutingStatusMapping.listSettings(zoneID: zoneID, cache: cache)
      .flatMap { EmailRoutingStatusMapping.listCardToken(for: $0) } == .ready)
  #expect(cache.get(FeatureCacheKey.emailRouting(zoneID)) as EmailRoutingSnapshot? == nil)

  let misconfigured = EmailRoutingSettings(
    id: "email-2", name: "docs.example.com", enabled: true, status: "misconfigured")
  cache.set(
    FeatureCacheKey.emailRouting(zoneID),
    EmailRoutingSnapshot(settings: misconfigured, rules: [], catchAll: nil))
  // Settings cache still wins while present — list fan-out owns that key.
  #expect(
    EmailRoutingStatusMapping.listSettings(zoneID: zoneID, cache: cache)
      .flatMap { EmailRoutingStatusMapping.listCardToken(for: $0) } == .ready)
  cache.remove(FeatureCacheKey.emailRoutingSettings(zoneID))
  #expect(
    EmailRoutingStatusMapping.listSettings(zoneID: zoneID, cache: cache)
      .flatMap { EmailRoutingStatusMapping.listCardToken(for: $0) } == .misconfigured)
  #expect(EmailRoutingStatusMapping.token(for: misconfigured) == .misconfigured)
  #expect(
    EmailRoutingStatusMapping.token(
      for: EmailRoutingSettings(
        id: "email-3", name: "off.example.com", enabled: false, status: "ready"))
      == .disabled)
}

@Test @MainActor func emailRoutingStatusBatchRejectsAStaleAccountWrite() throws {
  let model = AppModel(
    configuration: AppConfiguration(clientID: "test", redirectURI: ""),
    deferredDeletionPersistence: nil)
  model.activeAccountID = "account-a"
  let accountA = try #require(model.accountRequestContext)
  model.activeAccountID = "account-b"
  let accountB = try #require(model.accountRequestContext)
  let zoneID = "zone-account-race"
  let fresh = [
    zoneID: EmailRoutingSettings(
      id: "email-race", name: "mail.example", enabled: true, status: "ready")
  ]

  #expect(
    !EmailRoutingStatusCacheBatch.commit(
      fresh,
      context: accountA,
      loadedContext: accountA,
      model: model))
  #expect(
    EmailRoutingStatusMapping.listSettings(zoneID: zoneID, cache: model.featureCache) == nil)

  #expect(
    EmailRoutingStatusCacheBatch.commit(
      fresh,
      context: accountB,
      loadedContext: accountB,
      model: model))
  #expect(
    EmailRoutingStatusMapping.listSettings(zoneID: zoneID, cache: model.featureCache)
      == fresh[zoneID])
}

@Test func emailRoutingDomainCardsShowOnlySettingsThatAreOn() {
  func settings(enabled: Bool = true, status: String?) -> EmailRoutingSettings {
    EmailRoutingSettings(
      id: "email-\(status ?? "unknown")",
      name: "example.com",
      enabled: enabled,
      status: status)
  }

  #expect(EmailRoutingStatusMapping.listCardToken(for: settings(status: "ready")) == .ready)
  #expect(
    EmailRoutingStatusMapping.listCardToken(for: settings(status: "misconfigured"))
      == .misconfigured)
  #expect(
    EmailRoutingStatusMapping.listCardToken(for: settings(status: "misconfigured/locked"))
      == .misconfigured)
  #expect(
    EmailRoutingStatusMapping.listCardToken(for: settings(status: "unlocked")) == .unlocked)

  // `enabled` wins over a contradictory status, and Cloudflare's explicit
  // unconfigured state is the other definitive "fully off" signal.
  #expect(
    EmailRoutingStatusMapping.listCardToken(for: settings(enabled: false, status: "ready"))
      == nil)
  #expect(
    EmailRoutingStatusMapping.listCardToken(for: settings(status: "unconfigured")) == nil)

  // An enabled future status remains visible as Unknown. Hiding it would turn
  // an API evolution into the false claim that Email Routing was never on.
  #expect(EmailRoutingStatusMapping.listCardToken(for: settings(status: nil)) == .unknown)
  #expect(
    EmailRoutingStatusMapping.listCardToken(for: settings(status: "future-state")) == .unknown)
}

@Test @MainActor func emailRoutingReturnHeroResolvesConfiguredOffAndMissingCache() {
  let cache = FeatureDataCache()
  let zoneID = "zone-email-hero"
  let stale = DashNavigationHero.emailRoutingCard(
    accountID: "acc",
    zoneID: zoneID,
    name: "mail.example",
    status: "Misconfigured",
    seed: "mail.example",
    fillHex: 0xA8D8D8)

  let missing = stale.returnCacheResolution(from: cache)
  #expect(missing == .preserveCaptured)
  #expect(missing.resolvedHero(preserving: stale) == stale)

  EmailRoutingStatusMapping.storeListSettings(
    EmailRoutingSettings(
      id: "email-hero", name: "mail.example", enabled: true, status: "ready"),
    zoneID: zoneID,
    cache: cache)
  let configured = stale.returnCacheResolution(from: cache)
  let refreshed = DashNavigationHero.emailRoutingCard(
    accountID: "acc",
    zoneID: zoneID,
    name: "mail.example",
    status: "Ready",
    seed: "mail.example",
    fillHex: DomainCardColors.defaultHex(for: "mail.example"))
  #expect(configured == .replace(refreshed))
  #expect(configured.resolvedHero(preserving: stale) == refreshed)

  EmailRoutingStatusMapping.storeListSettings(
    EmailRoutingSettings(
      id: "email-hero", name: "mail.example", enabled: false, status: "ready"),
    zoneID: zoneID,
    cache: cache)
  let off = stale.returnCacheResolution(from: cache)
  #expect(off == .cardIneligible)
  #expect(off.resolvedHero(preserving: stale) == nil)

  let domain = DashNavigationHero.domainCard(
    accountID: "acc",
    zoneID: zoneID,
    name: "mail.example",
    status: "Active",
    seed: "mail.example",
    fillHex: 0xA8D8D8,
    plan: nil)
  #expect(
    domain.returnCacheResolution(from: cache).resolvedHero(preserving: domain) == domain)
}

@Test func emailRoutingHasEditableShapeAllowsWildcardLocalParts() {
  let zone = "example.com"
  func rule(
    address: String,
    actions: [EmailRoutingRuleAction] = [EmailRoutingRuleAction(type: "drop")],
    matchers: [EmailRoutingRuleMatcher]? = nil
  ) -> EmailRoutingRule {
    EmailRoutingRule(
      id: "r1",
      matchers: matchers
        ?? [EmailRoutingRuleMatcher(type: "literal", field: "to", value: address)],
      actions: actions)
  }

  #expect(EmailRoutingView.hasEditableShape(rule(address: "hi@example.com"), zoneName: zone))
  #expect(EmailRoutingView.hasEditableShape(rule(address: "*@example.com"), zoneName: zone))
  #expect(EmailRoutingView.hasEditableShape(rule(address: "sales*@example.com"), zoneName: zone))
  #expect(EmailRoutingView.hasEditableShape(rule(address: "*desk@example.com"), zoneName: zone))
  #expect(
    EmailRoutingView.hasEditableShape(
      rule(
        address: "*@example.com",
        actions: [EmailRoutingRuleAction(type: "forward", value: ["inbox@example.net"])]),
      zoneName: zone))

  #expect(!EmailRoutingView.hasEditableShape(rule(address: "@example.com"), zoneName: zone))
  #expect(!EmailRoutingView.hasEditableShape(rule(address: "hi@other.com"), zoneName: zone))
  #expect(
    !EmailRoutingView.hasEditableShape(
      rule(
        address: "hi@example.com",
        actions: [EmailRoutingRuleAction(type: "worker", value: ["mail-worker"])]),
      zoneName: zone))
  #expect(
    !EmailRoutingView.hasEditableShape(
      rule(
        address: "hi@example.com",
        actions: [
          EmailRoutingRuleAction(type: "forward", value: ["a@example.net", "b@example.net"])
        ]),
      zoneName: zone))
  #expect(
    !EmailRoutingView.hasEditableShape(
      rule(
        address: "hi@example.com",
        matchers: [
          EmailRoutingRuleMatcher(type: "literal", field: "to", value: "hi@example.com"),
          EmailRoutingRuleMatcher(type: "literal", field: "to", value: "bye@example.com"),
        ]),
      zoneName: zone))
}

@Test func zoneSettingTitlesPreserveTechnicalAcronyms() {
  #expect(zoneSettingDisplayTitle("ssl") == "SSL")
  #expect(zoneSettingDisplayTitle("always_use_https") == "Always Use HTTPS")
  #expect(zoneSettingDisplayTitle("always_online") == "Always Online")
  #expect(zoneSettingDisplayTitle("min_tls_version") == "Minimum TLS version")
  #expect(zoneSettingDisplayTitle("http3") == "HTTP/3")
  #expect(zoneSettingDisplayTitle("development_mode") == "Development Mode")
  #expect(zoneSettingDisplayTitle("cache_level") == "Cache Level")
}

@Test func zoneSettingsSuccessfulEmptyResponseUsesTheColdEmptyPhase() {
  let emptyPhase = DashListPhase.resolve(
    isLoading: false,
    error: nil,
    hasContent: ZoneSettingsPresentation.hasContent([]))
  #expect(emptyPhase == .empty)
  #expect(emptyPhase.bodyMode == .placeholder)

  let unsupportedSettings = [
    ZoneSetting(id: "future_setting", value: .string("on"), editable: true)
  ]
  #expect(!ZoneSettingsPresentation.hasContent(unsupportedSettings))

  let settings = [
    ZoneSetting(id: "ssl", value: .string("strict"), editable: true)
  ]
  let contentPhase = DashListPhase.resolve(
    isLoading: false,
    error: nil,
    hasContent: ZoneSettingsPresentation.hasContent(settings))
  #expect(contentPhase == .content(banner: nil, refreshing: false))
  #expect(contentPhase.bodyMode == .live)
}

/// The settings menu commits with a plain `updateZoneSetting`, which stashes
/// nothing — offering `under_attack` there would raise the shield behind
/// `ZoneSecurityLevelOperation`'s back and lose the level it replaced when the
/// WAF switch went off.
@Test func zoneSettingsMenuNeverOffersUnderAttack() throws {
  let securityLevels = try #require(zoneSettingOptions["security_level"])
  #expect(!securityLevels.contains("under_attack"))
  // The rest of Cloudflare's enum must survive the removal.
  #expect(securityLevels == ["off", "essentially_off", "low", "medium", "high"])
}

@Test func cacheLevelMenuMatchesCachingLevelAPI() throws {
  let levels = try #require(zoneSettingOptions["cache_level"])
  #expect(levels == ["basic", "simplified", "aggressive"])
}

@Test func addDomainAcceptsPlausibleZoneNamesOnly() {
  #expect(AddDomainValidation.isPlausibleZoneName("example.com"))
  #expect(AddDomainValidation.isPlausibleZoneName("  Sub.Example.CO.UK  "))
  #expect(AddDomainValidation.isPlausibleZoneName("xn--fiq228c.example"))
  #expect(!AddDomainValidation.isPlausibleZoneName(""))
  #expect(!AddDomainValidation.isPlausibleZoneName("example"))
  #expect(!AddDomainValidation.isPlausibleZoneName("example."))
  #expect(!AddDomainValidation.isPlausibleZoneName(".com"))
  #expect(!AddDomainValidation.isPlausibleZoneName("exa mple.com"))
  #expect(!AddDomainValidation.isPlausibleZoneName("example.c"))
  #expect(AddDomainValidation.normalized("  New.Example.COM ") == "new.example.com")
}

@Test func pinnedZonesRoundTripToggleAndAccountFiltering() {
  let a = PinnedZone(accountID: "acc1", zoneID: "z1", name: "example.com")
  let b = PinnedZone(accountID: "acc2", zoneID: "z2", name: "xat.sh")

  // Encode/decode round-trip preserves order and fields.
  let encoded = PinnedZones.encode([a, b])
  #expect(encoded == "acc1|z1|example.com,acc2|z2|xat.sh")
  #expect(PinnedZones.decode(encoded) == [a, b])

  // Toggle adds when absent, removes when present.
  let added = PinnedZones.toggled("", pin: a)
  #expect(PinnedZones.isPinned(added, zoneID: "z1"))
  let newest = PinnedZone(accountID: "acc1", zoneID: "z3", name: "new.example")
  #expect(PinnedZones.decode(PinnedZones.toggled(added, pin: newest)) == [newest, a])
  let removed = PinnedZones.toggled(encoded, pin: a)
  #expect(!PinnedZones.isPinned(removed, zoneID: "z1"))
  #expect(PinnedZones.decode(removed) == [b])

  // Malformed entries are dropped, not crashed on.
  #expect(PinnedZones.decode("garbage,acc|only-two") == [])

  // Account filtering keeps other accounts' pins invisible.
  let mine = PinnedZones.decode(encoded).filter { $0.accountID == "acc1" }
  #expect(mine == [a])
}

@Test func pinnedZonesBootstrapOnceAndPrioritizePins() {
  let defaults = (1...5).map {
    PinnedZone(accountID: "acc1", zoneID: "z\($0)", name: "zone-\($0).example")
  }
  let bootstrapped = PinnedZones.bootstrapped(
    "",
    initializedAccountsRaw: "",
    accountID: "acc1",
    defaults: defaults)

  #expect(PinnedZones.decode(bootstrapped.pins) == Array(defaults.prefix(4)))
  #expect(bootstrapped.initializedAccounts == "acc1")
  #expect(
    PinnedZones.pinnedZoneIDs(in: bootstrapped.pins, accountID: "acc1")
      == ["z1", "z2", "z3", "z4"])
  #expect(
    PinnedZones.prioritizedZoneIDs(
      ["z5", "z3", "z2", "z1", "z4"],
      pinsRaw: bootstrapped.pins,
      accountID: "acc1"
    ) == ["z1", "z2", "z3", "z4", "z5"])
  #expect(
    PinnedZones.prioritized(
      ["z5", "z3", "z2", "z1", "z4"],
      pinsRaw: bootstrapped.pins,
      accountID: "acc1",
      id: { $0 }
    ) == ["z1", "z2", "z3", "z4", "z5"])

  // Once initialized, a deliberate empty pin set stays empty.
  let afterManualClear = PinnedZones.bootstrapped(
    "",
    initializedAccountsRaw: bootstrapped.initializedAccounts,
    accountID: "acc1",
    defaults: defaults)
  #expect(afterManualClear.pins.isEmpty)

  // Another account still initializes independently.
  let other = PinnedZones.bootstrapped(
    bootstrapped.pins,
    initializedAccountsRaw: bootstrapped.initializedAccounts,
    accountID: "acc2",
    defaults: [PinnedZone(accountID: "acc2", zoneID: "other", name: "other.example")])
  #expect(other.initializedAccounts == "acc1,acc2")
  #expect(PinnedZones.decode(other.pins).first?.accountID == "acc2")
}

@Test func domainStatusSectionsLeadWithPinnedThenStatusBuckets() throws {
  func zone(_ id: String, status: String?) throws -> CloudflareZone {
    let statusJSON = status.map { "\"\($0)\"" } ?? "null"
    return try JSONDecoder().decode(
      CloudflareZone.self,
      from: Data(
        #"{"id":"\#(id)","name":"\#(id).example","status":\#(statusJSON)}"#.utf8))
  }

  let painted = try [
    zone("pin-b", status: "pending"),
    zone("pin-a", status: "active"),
    zone("active-a", status: "active"),
    zone("moved", status: "moved"),
    zone("active-b", status: "ACTIVE"),
    zone("weird", status: "deactivated"),
    zone("nil-status", status: nil),
  ]
  // Pin order is deliberate and independent of `painted` order.
  let sections = DomainStatusSections.make(
    from: painted,
    pinnedIDs: ["pin-a", "pin-b"])

  #expect(
    sections.map(\.id) == ["pinned", "active", "moved", "deactivated", "unknown"])
  #expect(sections[0].zones.map(\.id) == ["pin-a", "pin-b"])
  #expect(sections[1].zones.map(\.id) == ["active-a", "active-b"])
  #expect(sections[2].zones.map(\.id) == ["moved"])
  #expect(sections[3].zones.map(\.id) == ["weird"])
  #expect(sections[4].zones.map(\.id) == ["nil-status"])
}

@Test func domainsGroupingPresentationAnimatesOnlyAfterItsFirstFrame() {
  #expect(
    DomainsGroupingPresentationRules.update(displayed: nil, target: false)
      == DomainsGroupingPresentationUpdate(groupsByStatus: false, animates: false))
  #expect(
    DomainsGroupingPresentationRules.update(displayed: nil, target: true)
      == DomainsGroupingPresentationUpdate(groupsByStatus: true, animates: false))
  #expect(
    DomainsGroupingPresentationRules.update(displayed: false, target: true)
      == DomainsGroupingPresentationUpdate(groupsByStatus: true, animates: true))
  #expect(
    DomainsGroupingPresentationRules.update(displayed: true, target: false)
      == DomainsGroupingPresentationUpdate(groupsByStatus: false, animates: true))
  #expect(
    DomainsGroupingPresentationRules.update(
      displayed: false,
      target: true,
      reduceMotion: true
    ) == DomainsGroupingPresentationUpdate(groupsByStatus: true, animates: false))
  #expect(
    DomainsGroupingPresentationRules.update(displayed: true, target: true) == nil)
}

@Test func zoneActionsNoticeAppearsOnlyForLoadedInactiveDomains() {
  for status in ["active", "ACTIVE"] {
    #expect(!ZoneActionsNoticeRules.showsNotice(mode: .live, status: status))
  }
  let inactiveStatuses: [String?] = ["pending", "initializing", "moved", nil]
  for status in inactiveStatuses {
    #expect(ZoneActionsNoticeRules.showsNotice(mode: .live, status: status))
    #expect(!ZoneActionsNoticeRules.showsNotice(mode: .placeholder, status: status))
  }
}

@Test func domainCardColorsPersistPerAccountAndDomain() {
  let violet = DomainCardColors.parseToken("#7E22CE")!
  let orange = DomainCardColors.parseToken("#B45309")!
  let ocean = DomainCardColors.parseToken("#0369A1")!

  var raw = DomainCardColors.setting(
    violet,
    in: "",
    accountID: "acc1",
    zoneID: "zone1")
  raw = DomainCardColors.setting(
    orange,
    in: raw,
    accountID: "acc2",
    zoneID: "zone1")

  #expect(
    DomainCardColors.hex(
      in: raw, accountID: "acc1", zoneID: "zone1", seed: "example.com") == violet)
  #expect(
    DomainCardColors.hex(
      in: raw, accountID: "acc2", zoneID: "zone1", seed: "example.com") == orange)

  raw = DomainCardColors.setting(
    ocean,
    in: raw,
    accountID: "acc1",
    zoneID: "zone1")
  #expect(DomainCardColors.decode(raw).count == 2)
  #expect(
    DomainCardColors.hex(
      in: raw, accountID: "acc1", zoneID: "zone1", seed: "example.com") == ocean)
  // Morph hero: a later save must win over the push-time fill, per account.
  #expect(
    DomainCardColors.hex(
      in: raw, accountID: "acc1", zoneID: "zone1", fallback: 0xB8DDA8) == ocean)
  #expect(
    DomainCardColors.hex(
      in: raw, accountID: "acc2", zoneID: "zone1", fallback: 0xB8DDA8) == orange)
  #expect(
    DomainCardColors.hex(
      in: "", accountID: "acc1", zoneID: "zone1", fallback: 0xB8DDA8) == 0xB8DDA8)
  #expect(DomainCardColors.decode("bad,acc|zone|unknown").isEmpty)
  #expect(raw.contains("#0369A1"))
}

@Test func domainCardDefaultColorIsStable() {
  let first = DomainCardColors.defaultHex(for: "example.com")
  #expect(first == DomainCardColors.defaultHex(for: "example.com"))
  #expect(DomainCardColors.defaultPalette.contains(first))
  #expect(DomainCardColors.defaultPalette.count == 20)
  #expect(Set(DomainCardColors.defaultPalette).count == 20)
  #expect(DomainCardColors.prefersLightContent(0x1B191F))
  #expect(!DomainCardColors.prefersLightContent(0xFDFDFD))
}

private actor ZoneSecurityLevelTestLatch {
  private var isOpen = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let pending = continuations
    continuations.removeAll()
    for continuation in pending {
      continuation.resume()
    }
  }
}

@Test @MainActor func underAttackOperationsSerializeAcrossCloudflareAwaits() async throws {
  let suite = "dash.tests.under-attack-serialized.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let zoneID = "zone"
  let updateStarted = ZoneSecurityLevelTestLatch()
  let allowUpdate = ZoneSecurityLevelTestLatch()
  var remoteLevel = "high"
  var events: [String] = []

  let backend = ZoneSecurityLevelOperation.Backend(
    securityLevelValue: { _ in
      events.append("read:\(remoteLevel)")
      return .string(remoteLevel)
    },
    updateLevel: { _, level in
      events.append("write:\(level):start")
      if level == "under_attack" {
        await updateStarted.open()
        await allowUpdate.wait()
      }
      remoteLevel = level
      events.append("write:\(level):end")
    })

  let enable = Task { @MainActor in
    try await ZoneSecurityLevelOperation.setUnderAttack(
      zoneID: zoneID,
      enabled: true,
      defaults: defaults,
      backend: backend)
  }
  await updateStarted.wait()

  let disable = Task { @MainActor in
    try await ZoneSecurityLevelOperation.setUnderAttack(
      zoneID: zoneID,
      enabled: false,
      defaults: defaults,
      backend: backend)
  }
  await Task.yield()
  await Task.yield()
  #expect(events == ["read:high", "write:under_attack:start"])

  await allowUpdate.open()
  let enabled = try await enable.value
  let disabled = try await disable.value

  #expect(enabled == .init(currentLevel: "under_attack", changed: true))
  #expect(disabled == .init(currentLevel: "high", changed: true))
  #expect(remoteLevel == "high")
  #expect(defaults.string(forKey: ZoneSecurityLevelOperation.key(for: zoneID)) == nil)
  #expect(
    events == [
      "read:high",
      "write:under_attack:start",
      "write:under_attack:end",
      "read:under_attack",
      "write:high:start",
      "write:high:end",
    ])
}

@Test @MainActor func underAttackPersistedStateCanBeClearedAtCredentialBoundary() throws {
  let suite = "dash.tests.under-attack-clear.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set("high", forKey: ZoneSecurityLevelOperation.key(for: "zone-a"))
  defaults.set("keep", forKey: "unrelated")

  ZoneSecurityLevelOperation.clearPersistedState(defaults: defaults)

  #expect(defaults.object(forKey: ZoneSecurityLevelOperation.key(for: "zone-a")) == nil)
  #expect(defaults.string(forKey: "unrelated") == "keep")
}

@Test @MainActor func underAttackEnableDefinitiveFailureClearsStagedStashAndReleasesGate()
  async throws
{
  let suite = "dash.tests.under-attack-definitive-failure.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let zoneID = "zone"
  let key = ZoneSecurityLevelOperation.key(for: zoneID)
  defaults.set("stale", forKey: key)
  var shouldReject = true

  let backend = ZoneSecurityLevelOperation.Backend(
    securityLevelValue: { _ in .string("high") },
    updateLevel: { _, _ in
      if shouldReject {
        throw CloudflareAPIError.request(status: 403, errors: [])
      }
    })

  do {
    _ = try await ZoneSecurityLevelOperation.setUnderAttack(
      zoneID: zoneID,
      enabled: true,
      defaults: defaults,
      backend: backend)
    Issue.record("Expected the explicit Cloudflare rejection.")
  } catch {
    guard case .request(let status, _) = error as? CloudflareAPIError else {
      Issue.record("Expected a Cloudflare request error, got \(error).")
      return
    }
    #expect(status == 403)
  }
  #expect(defaults.string(forKey: key) == nil)

  shouldReject = false
  let retry = try await ZoneSecurityLevelOperation.setUnderAttack(
    zoneID: zoneID,
    enabled: true,
    defaults: defaults,
    backend: backend)
  #expect(retry == .init(currentLevel: "under_attack", changed: true))
  #expect(defaults.string(forKey: key) == "high")
}

@Test @MainActor func underAttackAmbiguousEnableFailuresPreserveTheStagedLevel() async throws {
  let suite = "dash.tests.under-attack-ambiguous-failure.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let failures: [(String, CloudflareAPIError)] = [
    ("transport", .transport("Connection lost")),
    ("server", .request(status: 503, errors: [])),
  ]

  for (zoneID, failure) in failures {
    let backend = ZoneSecurityLevelOperation.Backend(
      securityLevelValue: { _ in .string("high") },
      updateLevel: { _, _ in throw failure })

    do {
      _ = try await ZoneSecurityLevelOperation.setUnderAttack(
        zoneID: zoneID,
        enabled: true,
        defaults: defaults,
        backend: backend)
      Issue.record("Expected the ambiguous Cloudflare failure.")
    } catch {
      // The stash assertion is the contract under test; both failures propagate.
    }

    #expect(
      defaults.string(forKey: ZoneSecurityLevelOperation.key(for: zoneID)) == "high")
  }
}

@Test @MainActor func underAttackDisableFailurePreservesRestoreLevel() async throws {
  let suite = "dash.tests.under-attack-disable-failure.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let zoneID = "zone"
  let key = ZoneSecurityLevelOperation.key(for: zoneID)
  defaults.set("high", forKey: key)
  let backend = ZoneSecurityLevelOperation.Backend(
    securityLevelValue: { _ in .string("under_attack") },
    updateLevel: { _, _ in
      throw CloudflareAPIError.request(status: 403, errors: [])
    })

  do {
    _ = try await ZoneSecurityLevelOperation.setUnderAttack(
      zoneID: zoneID,
      enabled: false,
      defaults: defaults,
      backend: backend)
    Issue.record("Expected the restore request to fail.")
  } catch {
    // A retry still needs the exact restore level after every failed disable.
  }

  #expect(defaults.string(forKey: key) == "high")
}

@Test @MainActor func underAttackReadFailurePreservesStashAndNeverWrites() async throws {
  let suite = "dash.tests.under-attack-read-failure.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  var updateCount = 0

  for enabled in [true, false] {
    let zoneID = enabled ? "enable" : "disable"
    let key = ZoneSecurityLevelOperation.key(for: zoneID)
    defaults.set("high", forKey: key)
    let backend = ZoneSecurityLevelOperation.Backend(
      securityLevelValue: { _ in
        throw CloudflareAPIError.request(status: 403, errors: [])
      },
      updateLevel: { _, _ in updateCount += 1 })

    do {
      _ = try await ZoneSecurityLevelOperation.setUnderAttack(
        zoneID: zoneID,
        enabled: enabled,
        defaults: defaults,
        backend: backend)
      Issue.record("Expected the security-level read to fail.")
    } catch {
      // A failed GET proves nothing about the remote state, so the stash stays.
    }

    #expect(defaults.string(forKey: key) == "high")
  }
  #expect(updateCount == 0)
}

@Test @MainActor func underAttackInvalidSecurityValueFailsClosed() async throws {
  let suite = "dash.tests.under-attack-invalid-value.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let invalidValues: [JSONValue?] = [nil, .bool(true)]
  var updateCount = 0

  for (index, value) in invalidValues.enumerated() {
    let zoneID = "zone-\(index)"
    let key = ZoneSecurityLevelOperation.key(for: zoneID)
    defaults.set("stale", forKey: key)
    let backend = ZoneSecurityLevelOperation.Backend(
      securityLevelValue: { _ in value },
      updateLevel: { _, _ in updateCount += 1 })

    do {
      _ = try await ZoneSecurityLevelOperation.setUnderAttack(
        zoneID: zoneID,
        enabled: true,
        defaults: defaults,
        backend: backend)
      Issue.record("Expected a missing or non-string security level to fail.")
    } catch {
      guard case .invalidResponse = error as? CloudflareAPIError else {
        Issue.record("Expected invalidResponse, got \(error).")
        continue
      }
    }

    #expect(defaults.string(forKey: key) == "stale")
  }
  #expect(updateCount == 0)
}

@Test @MainActor func underAttackDisableWhenAlreadyOffClearsStaleStashWithoutWriting()
  async throws
{
  let suite = "dash.tests.under-attack-disable-no-op.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let zoneID = "zone"
  let key = ZoneSecurityLevelOperation.key(for: zoneID)
  defaults.set("high", forKey: key)
  var updateCount = 0
  let backend = ZoneSecurityLevelOperation.Backend(
    securityLevelValue: { _ in .string("low") },
    updateLevel: { _, _ in updateCount += 1 })

  let outcome = try await ZoneSecurityLevelOperation.setUnderAttack(
    zoneID: zoneID,
    enabled: false,
    defaults: defaults,
    backend: backend)

  #expect(outcome == .init(currentLevel: "low", changed: false))
  #expect(updateCount == 0)
  #expect(defaults.string(forKey: key) == nil)
}

@Test @MainActor func underAttackCancellationReleasesGateAndSkipsCancelledWaiter()
  async throws
{
  let suite = "dash.tests.under-attack-cancellation.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let zoneID = "zone"
  let updateStarted = ZoneSecurityLevelTestLatch()
  let allowUpdate = ZoneSecurityLevelTestLatch()
  var remoteLevel = "high"
  var readCount = 0

  let backend = ZoneSecurityLevelOperation.Backend(
    securityLevelValue: { _ in
      readCount += 1
      return .string(remoteLevel)
    },
    updateLevel: { _, level in
      await updateStarted.open()
      await allowUpdate.wait()
      remoteLevel = level
    })

  let active = Task { @MainActor in
    try await ZoneSecurityLevelOperation.setUnderAttack(
      zoneID: zoneID,
      enabled: true,
      defaults: defaults,
      backend: backend)
  }
  await updateStarted.wait()

  let cancelledWaiter = Task { @MainActor in
    try await ZoneSecurityLevelOperation.setUnderAttack(
      zoneID: zoneID,
      enabled: true,
      defaults: defaults,
      backend: backend)
  }
  await Task.yield()
  await Task.yield()
  cancelledWaiter.cancel()
  do {
    _ = try await cancelledWaiter.value
    Issue.record("Expected the queued operation to be cancelled.")
  } catch {
    #expect(error is CancellationError)
  }

  let follower = Task { @MainActor in
    try await ZoneSecurityLevelOperation.setUnderAttack(
      zoneID: zoneID,
      enabled: true,
      defaults: defaults,
      backend: backend)
  }
  active.cancel()
  await allowUpdate.open()

  do {
    _ = try await active.value
    Issue.record("Expected the active operation to observe cancellation.")
  } catch {
    #expect(error is CancellationError)
  }
  let outcome = try await follower.value

  #expect(outcome == .init(currentLevel: "under_attack", changed: false))
  #expect(remoteLevel == "under_attack")
  #expect(readCount == 2)
  #expect(
    defaults.string(forKey: ZoneSecurityLevelOperation.key(for: zoneID)) == "high")
}

@Test func cachePurgeURLParserSplitsDeduplicatesAndEnforcesBoundaries() {
  let empty = CachePurgeURLParser.parse("  \n\t\n ")
  #expect(empty.validURLs.isEmpty)
  #expect(empty.invalidLines.isEmpty)
  #expect(!empty.exceedsLimit)
  #expect(!empty.canSubmit)

  let mixed = CachePurgeURLParser.parse(
    """
      https://example.com/a.css
      http://example.com/b.js
      https://example.com/a.css
      /bare-path.css
      ftp://example.com/file
      example.com/no-scheme
    """)
  #expect(mixed.validURLs == ["https://example.com/a.css", "http://example.com/b.js"])
  #expect(
    mixed.invalidLines == ["/bare-path.css", "ftp://example.com/file", "example.com/no-scheme"])
  #expect(!mixed.exceedsLimit)
  #expect(!mixed.canSubmit)

  // Duplicates must not push 30 unique URLs over Cloudflare's 30-URL cap.
  let thirtyWithDuplicate =
    ((1...CachePurgeURLParser.maxURLs).map { "https://example.com/\($0)" }
    + ["https://example.com/1"]).joined(separator: "\n")
  let atCap = CachePurgeURLParser.parse(thirtyWithDuplicate)
  #expect(atCap.validURLs.count == CachePurgeURLParser.maxURLs)
  #expect(!atCap.exceedsLimit)
  #expect(atCap.canSubmit)

  let overCapInput = (1...(CachePurgeURLParser.maxURLs + 1))
    .map { "https://example.com/\($0)" }
    .joined(separator: "\n")
  let overCap = CachePurgeURLParser.parse(overCapInput)
  #expect(overCap.validURLs.count == CachePurgeURLParser.maxURLs + 1)
  #expect(overCap.exceedsLimit)
  #expect(!overCap.canSubmit)
}

@Test func dashSearchMatcherRequiresEveryTokenAcrossFields() {
  #expect(!DashSearchMatcher.isActive("   \n\t "))
  #expect(DashSearchMatcher.matches("   ", in: [nil, ""]))

  #expect(DashSearchMatcher.isActive("A café"))
  #expect(
    DashSearchMatcher.matches(
      "cname cafe",
      in: ["Café.example.com", "CNAME", "origin.example.net"]))
  #expect(
    !DashSearchMatcher.matches(
      "cname missing",
      in: ["Café.example.com", "CNAME", "origin.example.net"]))
  #expect(!DashSearchMatcher.matches("example", in: [nil, ""]))
}

@Test func auditLogDetailFieldsAndResultTokenCoverPopulatedAndSparseEntries() {
  #expect(StatusToken(auditResult: "success") == .success)
  #expect(StatusToken(auditResult: "TRUE") == .success)
  #expect(StatusToken(auditResult: "failure") == .failed)
  #expect(StatusToken(auditResult: "failed") == .failed)
  #expect(StatusToken(auditResult: "false") == .failed)
  #expect(StatusToken(auditResult: "pending") == nil)
  #expect(StatusToken(auditResult: nil) == nil)

  let entry = AuditLogEntry(
    logID: "evt-123",
    action: AuditLogAction(
      type: "purge",
      description: "Purged zone cache",
      result: "success",
      time: "2026-11-25T10:00:00Z"),
    actor: AuditLogActor(
      email: "ops@example.com",
      type: "user",
      ipAddress: "203.0.113.42",
      context: "api_key",
      tokenName: "deploy-bot"),
    resource: AuditLogResource(
      type: "zone",
      product: "caching",
      id: "zone-abc",
      scope: "zones"),
    occurredAt: "2026-11-25T10:00:00Z",
    zoneName: "example.com",
    interfaceName: "API",
    method: "POST",
    uri: "/client/v4/zones/zone-abc/purge_cache",
    statusCode: 200,
    rayID: "9a1b2c3d4e5f-SJC",
    oldValue: "off",
    newValue: "on")

  let byLabel = Dictionary(uniqueKeysWithValues: entry.detailFields.map { ($0.label, $0.value) })
  #expect(byLabel["Action"] == "purge")
  #expect(byLabel["Actor"] == "ops@example.com")
  #expect(byLabel["API token"] == "deploy-bot")
  #expect(byLabel["IP address"] == "203.0.113.42")
  #expect(byLabel["Resource ID"] == "zone-abc")
  #expect(byLabel["Domain"] == "example.com")
  #expect(byLabel["Request"] == "POST /client/v4/zones/zone-abc/purge_cache")
  #expect(byLabel["HTTP status"] == "200")
  #expect(byLabel["Ray ID"] == "9a1b2c3d4e5f-SJC")
  #expect(byLabel["Previous value"] == "off")
  #expect(byLabel["New value"] == "on")
  #expect(byLabel["Event ID"] == "evt-123")

  let summary = entry.copyableSummary
  #expect(summary.hasPrefix("Purged zone cache\n"))
  #expect(summary.contains("zone-abc"))
  #expect(summary.contains("9a1b2c3d4e5f-SJC"))

  let sparse = AuditLogEntry(logID: nil, action: nil, actor: nil, resource: nil)
  #expect(sparse.detailFields.isEmpty)
}

@Test func firewallSecurityEventDetailFieldsAndCopyableSummary() {
  let event = FirewallSecurityEvent(
    id: "8f9a1b2c3d4e5f01",
    datetime: "2026-11-26T04:55:10Z",
    action: "block",
    source: "rateLimit",
    ruleID: "rate-limit-login",
    clientIP: "203.0.113.42",
    clientCountryName: "US",
    clientASN: "14061",
    clientASNDescription: "DigitalOcean, LLC",
    method: "POST",
    host: "api.example.com",
    path: "/v1/login",
    query: "retry=1",
    userAgent: "curl/8.7.1",
    rayName: "8f9a1b2c3d4e5f01",
    edgeColoName: "SJC")

  #expect(event.displayTitle == "POST /v1/login?retry=1")
  #expect(event.formattedASN == "AS14061 · DigitalOcean, LLC")

  let byLabel = Dictionary(uniqueKeysWithValues: event.detailFields.map { ($0.label, $0.value) })
  #expect(byLabel["Action"] == "block")
  #expect(byLabel["Client IP"] == "203.0.113.42")
  #expect(byLabel["Country"] == "US")
  #expect(byLabel["ASN"] == "AS14061 · DigitalOcean, LLC")
  #expect(byLabel["Request"] == "POST api.example.com/v1/login?retry=1")
  #expect(byLabel["Source"] == "rateLimit")
  #expect(byLabel["Rule ID"] == "rate-limit-login")
  #expect(byLabel["User-Agent"] == "curl/8.7.1")
  #expect(byLabel["Datacenter"] == "SJC")
  #expect(byLabel["Ray ID"] == "8f9a1b2c3d4e5f01")

  let summary = event.copyableSummary
  #expect(summary.hasPrefix("POST /v1/login?retry=1\n"))
  #expect(summary.contains("203.0.113.42"))
  #expect(summary.contains("8f9a1b2c3d4e5f01"))
}

@Test func workerConfigurationRulesValidateSecretsAndCrons() {
  #expect(WorkerConfigurationRules.isValidSecretName("API_SIGNING_KEY"))
  #expect(WorkerConfigurationRules.isValidSecretName("_internal2"))
  #expect(!WorkerConfigurationRules.isValidSecretName(""))
  #expect(!WorkerConfigurationRules.isValidSecretName("9INVALID"))
  #expect(!WorkerConfigurationRules.isValidSecretName("BAD-NAME"))
  #expect(!WorkerConfigurationRules.isValidSecretName("HAS SPACE"))
  #expect(!WorkerConfigurationRules.isValidSecretName("BAD/SLASH"))

  #expect(
    WorkerConfigurationRules.normalizedCronExpression("  */15   *  * * *  ") == "*/15 * * * *")
  #expect(WorkerConfigurationRules.isValidCronExpression("*/15 * * * *"))
  #expect(WorkerConfigurationRules.isValidCronExpression("0 3 * * MON-FRI"))
  #expect(!WorkerConfigurationRules.isValidCronExpression("* * * *"))
  #expect(!WorkerConfigurationRules.isValidCronExpression("* * * * * *"))
  #expect(!WorkerConfigurationRules.isValidCronExpression("*/5 * * * ?"))

  let binding = WorkerBinding(name: "ASSETS", type: "r2_bucket", bucketName: "northwind-assets")
  #expect(!binding.isSecret)
  #expect(binding.kindTitle == "R2 bucket")
  let fields = Dictionary(uniqueKeysWithValues: binding.detailFields.map { ($0.label, $0.value) })
  #expect(fields["Name"] == "ASSETS")
  #expect(fields["Bucket"] == "northwind-assets")
}

@Test func pagesConfigurationRulesAndEnvironmentFilter() throws {
  #expect(PagesConfigurationRules.isValidVariableName("PUBLIC_API_URL"))
  #expect(PagesConfigurationRules.isValidVariableName("_flag2"))
  #expect(!PagesConfigurationRules.isValidVariableName(""))
  #expect(!PagesConfigurationRules.isValidVariableName("9BAD"))
  #expect(!PagesConfigurationRules.isValidVariableName("BAD-KEY"))
  #expect(!PagesConfigurationRules.isValidVariableName("BAD KEY"))

  let project = PagesProject(
    id: "pp-1",
    name: "web",
    deploymentConfigs: PagesDeploymentConfigs(
      production: PagesDeploymentConfig(envVars: [
        "Z_KEY": PagesEnvVar(type: "plain_text", value: "1"),
        "A_SECRET": PagesEnvVar(type: "secret_text", value: nil),
      ]),
      preview: PagesDeploymentConfig(envVars: [
        "PREVIEW_ONLY": PagesEnvVar(type: "plain_text", value: "true")
      ])
    )
  )
  #expect(
    PagesConfigurationRules.sortedVariables(from: project, environment: .production).map(\.name)
      == ["A_SECRET", "Z_KEY"])
  #expect(
    PagesConfigurationRules.sortedVariables(from: project, environment: .preview).map(\.name)
      == ["PREVIEW_ONLY"])

  let deploymentsJSON = #"""
    [
      {"id":"d-prod","short_id":"abc","environment":"production","is_skipped":false},
      {"id":"d-prev","short_id":"def","environment":"preview","is_skipped":false}
    ]
    """#
  let all = try JSONDecoder().decode([PagesDeployment].self, from: Data(deploymentsJSON.utf8))
  #expect(PagesDeploymentEnvironmentFilter.all.filter(all).map(\.id) == ["d-prod", "d-prev"])
  #expect(PagesDeploymentEnvironmentFilter.production.filter(all).map(\.id) == ["d-prod"])
  #expect(PagesDeploymentEnvironmentFilter.preview.filter(all).map(\.id) == ["d-prev"])
}

@Test func dnsRecordSubtitleAndCopyableContentSupportCommentsAndServiceBindings() {
  let https = DNSRecord(
    id: "r-https", zoneID: "z1", type: "HTTPS", name: "example.com", content: "",
    proxied: false, ttl: 300, priority: nil,
    data: DNSRecordData(priority: 1, target: ".", value: #"alpn="h3,h2""#),
    comment: "HTTP/3 hint")
  #expect(dnsRecordCopyableContent(https) == #"1 . alpn="h3,h2""#)
  #expect(dnsRecordSubtitle(https) == #"HTTPS  ·  1  ·  .  ·  alpn="h3,h2"  ·  HTTP/3 hint"#)

  let svcbAlias = DNSRecord(
    id: "r-svcb", zoneID: "z1", type: "SVCB", name: "_dns.example.com", content: "",
    proxied: false, ttl: 300, priority: nil,
    data: DNSRecordData(priority: 0, target: "resolver.example.com", value: ""),
    comment: nil)
  #expect(dnsRecordCopyableContent(svcbAlias) == "0 resolver.example.com")
  #expect(dnsRecordSubtitle(svcbAlias) == "SVCB  ·  0  ·  resolver.example.com")

  let txtWithComment = DNSRecord(
    id: "r-txt", zoneID: "z1", type: "TXT", name: "example.com",
    content: "v=spf1 ~all", proxied: false, ttl: 300, priority: nil, data: nil,
    comment: "  Mail SPF  ")
  #expect(dnsRecordCopyableContent(txtWithComment) == "v=spf1 ~all")
  #expect(dnsRecordSubtitle(txtWithComment) == "TXT  ·  v=spf1 ~all  ·  Mail SPF")
}
