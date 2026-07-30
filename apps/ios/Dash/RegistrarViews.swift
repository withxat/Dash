import CloudflareAPI
import SwiftUI

// MARK: - Access

/// The one place the Registrar scope ids are read from.
///
/// Registrar is a catalog `FeatureID` (`Resources → Registered domains`), so
/// the read scope lives in `FeatureCatalog.descriptors` like every other
/// feature's and is mirrored here for the two screens that gate on it. The
/// write scope stays out of that capability on purpose — see below.
enum RegistrarAccess {
  static let read: Set<String> = FeatureID.registrar.capability.read

  /// `.admin`, not `.write`. `registrar-domains.write` does not exist in
  /// Cloudflare's scope catalog, and `CloudflareScopes.sanitized()` drops
  /// unknown ids silently — the guess produces a successful consent flow that
  /// grants nothing, and a read-only screen with no error to explain it.
  ///
  /// Kept off `FeatureID.registrar.capability.write` because only the per-domain
  /// screen mutates: as a feature write scope it would hang
  /// `FeatureReadOnlyBanner` over the index, which has no controls to gate, and
  /// duplicate the notice this screen already shows.
  static let write: Set<String> = ["registrar-domains.admin"]
}

/// Account-scoped deep link to one registrar domain, for locally-scheduled
/// expiry reminders. `WatchtowerNotifier.route(host:path:accountID:)` is private
/// to its own file, so the shape is rebuilt here rather than reached for.
enum RegistrarRoute {
  static func deepLink(domain: String, accountID: String) -> String? {
    let domain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !domain.isEmpty, !accountID.isEmpty else { return nil }
    var components = URLComponents()
    components.scheme = "dash"
    components.host = "registrar"
    components.path = "/\(domain)"
    components.queryItems = [URLQueryItem(name: "account", value: accountID)]
    return components.url?.absoluteString
  }
}

// MARK: - Fetch outcomes

/// What one registrar endpoint answered.
///
/// Four outcomes, not two, because three of them must render differently:
/// `absent` is a 404 — the endpoint does not know this resource, which is
/// structural absence and never a fault (the `WorkerBuildsSection` rule);
/// `denied` is a 403, which is a missing grant and must offer to fix itself;
/// `failed` is everything else and stays on screen saying so. `cancelled` is a
/// `.task` teardown and is not an answer at all — it must never be cached, and
/// it must never settle a section, or a screen the user swiped away from comes
/// back claiming the lookup returned nothing.
enum RegistrarFetch<Value: Sendable>: Sendable {
  case value(Value)
  case absent
  case denied(String)
  case failed(String)
  case cancelled

  /// The answer, when there was one. Named `payload` rather than `value` so
  /// the instance member never has to be read against the `value` case.
  var payload: Value? {
    if case .value(let payload) = self { return payload }
    return nil
  }

  /// The message to show, when this outcome has one. `absent` never does.
  var failureMessage: String? {
    switch self {
    case .denied(let message), .failed(let message): message
    case .value, .absent, .cancelled: nil
    }
  }

  var isCancelled: Bool {
    if case .cancelled = self { return true }
    return false
  }

  /// True only for an answer Cloudflare actually gave.
  var isSettledAnswer: Bool {
    switch self {
    case .value, .absent: true
    case .denied, .failed, .cancelled: false
    }
  }

  static func perform(_ operation: () async throws -> Value) async -> RegistrarFetch<Value> {
    do {
      return .value(try await operation())
    } catch let error as CloudflareAPIError where error.isNotFound {
      return .absent
    } catch let error as CloudflareAPIError where error.isPermissionDenied {
      return .denied(error.dashActionableMessage)
    } catch {
      if error.dashIsCancellation || Task.isCancelled { return .cancelled }
      return .failed(error.dashActionableMessage)
    }
  }
}

// MARK: - Account index

/// One domain in the account's Cloudflare Registrar index, merged from
/// whichever of the two list endpoints answered for it.
///
/// The two endpoints carry different halves of the same domain: the beta
/// `/registrar/registrations` list is the only source of `status`, `auto_renew`
/// and `privacy_mode`, and the page-numbered `/registrar/domains` list is the
/// only source of `current_registrar`, the registry statuses and the registrant
/// contact. Anything Cloudflare did not say stays `nil` and costs one row.
struct RegistrarDomainSummary: Identifiable, Hashable, Sendable {
  var id: String { name }
  let name: String
  let status: String?
  let expiresAt: String?
  let createdAt: String?
  let autoRenew: Bool?
  let locked: Bool?
  let privacyMode: String?
  let currentRegistrar: String?

  init(
    name: String,
    status: String? = nil,
    expiresAt: String? = nil,
    createdAt: String? = nil,
    autoRenew: Bool? = nil,
    locked: Bool? = nil,
    privacyMode: String? = nil,
    currentRegistrar: String? = nil
  ) {
    self.name = name
    self.status = status
    self.expiresAt = expiresAt
    self.createdAt = createdAt
    self.autoRenew = autoRenew
    self.locked = locked
    self.privacyMode = privacyMode
    self.currentRegistrar = currentRegistrar
  }

  init(registration: RegistrarRegistration) {
    self.init(
      name: registration.domainName,
      status: registration.status,
      expiresAt: registration.expiresAt,
      createdAt: registration.createdAt,
      autoRenew: registration.autoRenew,
      locked: registration.locked,
      privacyMode: registration.privacyMode)
  }

  /// `RegistrarDomain` is deliberately not `Identifiable`: its `id` is the only
  /// name on the object and the documented example is opaque hex. Rows without
  /// a dot in that field are already dropped by the package; this drops the
  /// rest of the nameless ones rather than titling a row with a hex string.
  init?(legacy: RegistrarDomain) {
    let name = (legacy.identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    self.init(
      name: name,
      expiresAt: legacy.expiresAt,
      createdAt: legacy.createdAt,
      locked: legacy.locked,
      currentRegistrar: legacy.currentRegistrar)
  }

  /// Field-by-field union, `primary` winning every field it has an answer for.
  static func merged(
    _ primary: RegistrarDomainSummary,
    _ secondary: RegistrarDomainSummary
  ) -> RegistrarDomainSummary {
    RegistrarDomainSummary(
      name: primary.name,
      status: primary.status ?? secondary.status,
      expiresAt: primary.expiresAt ?? secondary.expiresAt,
      createdAt: primary.createdAt ?? secondary.createdAt,
      autoRenew: primary.autoRenew ?? secondary.autoRenew,
      locked: primary.locked ?? secondary.locked,
      privacyMode: primary.privacyMode ?? secondary.privacyMode,
      currentRegistrar: primary.currentRegistrar ?? secondary.currentRegistrar)
  }

  var statusToken: StatusToken? {
    guard let status, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return StatusToken(registrarStatus: status)
  }

  var expiresOn: Date? {
    expiresAt.flatMap(ExpiryReminders.date(fromISO8601:))
  }

  /// The renewal policy this registration implies, read through
  /// `ExpiryReminders.renewal` so the reminder and the screen can never
  /// disagree about whether a deadline exists.
  var renewal: ExpiryReminders.Renewal {
    ExpiryReminders.renewal(registrarStatus: status, autoRenew: autoRenew)
  }
}

/// The account's registrar index, plus what each of the two list endpoints
/// actually said.
///
/// **Decision D1 is unresolved**: nobody has confirmed whether the beta
/// `/registrar/registrations` list returns domains bought through the
/// Cloudflare dashboard or only ones created through the beta API itself. So
/// the legacy page-numbered list is a first-class source here, not a rescue —
/// both are called on every load and merged — and the screen is allowed to say
/// "you own no domains" only when a source that answered `200` said so.
/// "This endpoint doesn't know about your domains" renders as a failure with a
/// retry, never as the empty state.
struct RegistrarAccountIndex: Sendable {
  let domains: [RegistrarDomainSummary]
  let registrations: RegistrarFetch<[RegistrarDomainSummary]>
  let legacy: RegistrarFetch<[RegistrarDomainSummary]>

  func domain(named name: String) -> RegistrarDomainSummary? {
    let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return nil }
    // Exact equality only. A registrar-owned `example.com` says nothing about a
    // `blog.example.com` zone's own registration record, so suffix matching
    // would attach one domain's expiry date and auto-renew state to another's.
    return domains.first { $0.name.lowercased() == needle }
  }

  /// Why the screen may not render the empty state.
  ///
  /// Only consulted when the merged list is empty. The page-numbered list is
  /// the authority on "this account owns nothing" — it predates the beta and is
  /// the one endpoint known to carry dashboard-bought domains. A `404` from it
  /// means the endpoint itself is gone, in which case a `200` from the beta
  /// list is the best answer available and is believed. Anything else (a 403, a
  /// 5xx, a timeout, a decode failure) leaves the question unanswered, and an
  /// unanswered question is not "none".
  var unresolvedFailure: String? {
    guard domains.isEmpty else { return nil }
    if case .value = legacy { return nil }
    if case .absent = legacy, case .value = registrations { return nil }
    return legacy.failureMessage
      ?? registrations.failureMessage
      ?? DashL10n.string("Cloudflare didn’t return this account’s registered domains.")
  }

  /// A source is down while the other one carried rows: the list works, but it
  /// may be short. Permission failures stay silent here — the rows on screen
  /// already prove the grant covers the list, and a second grant prompt over a
  /// working screen is furniture.
  var partialFailure: String? {
    guard !domains.isEmpty else { return nil }
    for outcome in [registrations, legacy] {
      if case .failed(let message) = outcome { return message }
    }
    return nil
  }

  /// A half-torn-down load is not a result. Caching one would freeze a partial
  /// answer for the cache's whole lifetime.
  var isCacheable: Bool {
    !registrations.isCancelled && !legacy.isCancelled
  }
}

enum RegistrarIndexLoader {
  /// Both list endpoints, concurrently, merged by domain name.
  ///
  /// Never throws: each source's outcome is carried in the index so the caller
  /// can tell "denied" from "not there" from "said nothing" — the distinction
  /// the whole D1 handling rests on.
  static func load(client: CloudflareClient, accountID: String) async
    -> RegistrarAccountIndex
  {
    async let registrationsFetch = RegistrarFetch<[RegistrarDomainSummary]>.perform {
      try await client.listRegistrarRegistrations(accountID: accountID)
        .map(RegistrarDomainSummary.init(registration:))
    }
    async let legacyFetch = RegistrarFetch<[RegistrarDomainSummary]>.perform {
      try await client.listRegistrarDomainsLegacy(accountID: accountID)
        .compactMap(RegistrarDomainSummary.init(legacy:))
    }
    let (registrations, legacy) = await (registrationsFetch, legacyFetch)

    var merged: [String: RegistrarDomainSummary] = [:]
    for summary in (registrations.payload ?? []) + (legacy.payload ?? []) {
      let key = summary.name.lowercased()
      if let existing = merged[key] {
        merged[key] = RegistrarDomainSummary.merged(existing, summary)
      } else {
        merged[key] = summary
      }
    }

    return RegistrarAccountIndex(
      // By name, not by expiry: a list the user scans by hostname must not
      // reorder itself the day a renewal lands.
      domains: merged.values.sorted { $0.name < $1.name },
      registrations: registrations,
      legacy: legacy)
  }
}

/// The zone screen's half of the registrar lookup.
///
/// The account index is shared with `RegistrarDomainsView` through one cache
/// key, so opening a zone and opening the registrar list never fetch the same
/// two endpoints twice in a session.
@MainActor
enum RegistrarZoneRegistration {
  /// The first-party registration for a zone, or `nil` when the zone's domain
  /// is registered elsewhere, the grant does not cover Registrar, or the
  /// lookup could not be completed. Every `nil` means the same thing to the
  /// caller: run the RDAP path, unchanged.
  ///
  /// A missing scope must affect only its own feature — it must never turn the
  /// zone screen's Registration card red.
  static func firstParty(forZoneNamed name: String, model: AppModel)
    async -> RegistrarDomainSummary?
  {
    guard model.hasScopes(RegistrarAccess.read) else { return nil }
    guard let context = model.accountRequestContext else { return nil }
    let key = FeatureCacheKey.registrarDomains(context.accountID)
    if let cached: RegistrarAccountIndex = model.featureCache.get(key) {
      return cached.domain(named: name)
    }
    let index = await RegistrarIndexLoader.load(
      client: model.client, accountID: context.accountID)
    guard !Task.isCancelled, model.isCurrentAccount(context) else { return nil }
    // A denied or failed index is cached too, negative marker and all: without
    // it every zone visit in the session re-asks two endpoints that already
    // said no.
    if index.isCacheable {
      model.featureCache.set(key, index)
    }
    return index.domain(named: name)
  }
}

// MARK: - Shared rows

/// The Registration fields for a domain this account registered with
/// Cloudflare. Shared by the zone screen's card and the registrar detail
/// screen, so one lookup renders identically in both places.
struct RegistrarRegistrationRows: View {
  let summary: RegistrarDomainSummary

  var body: some View {
    if let token = summary.statusToken {
      // Never text beside a capsule: one token, one rendering.
      DashInfoRow("Status") { StatusBadge(token) }
    }
    if let expires = summary.expiresAt {
      DashInfoRow("Expires", value: registrarDateLabel(expires))
    }
    if let created = summary.createdAt {
      DashInfoRow("Registered", value: registrarDateLabel(created))
    }
    // Omitted when Cloudflare did not say. Substituting a Dash-authored
    // "Cloudflare" here would state something no endpoint returned.
    if let registrar = summary.currentRegistrar, !registrar.isEmpty {
      DashInfoRow("Registrar", value: registrar)
    }
    // Read-only by decision D2: nobody has confirmed what `privacy_mode`
    // returns when WHOIS privacy is off, and a switch whose value silently
    // reverts on reload is worse than no switch.
    if let privacy = summary.privacyLabel {
      DashInfoRow("WHOIS privacy", value: privacy)
    }
  }
}

/// The zone screen's link into the registrar detail.
///
/// Rendered **only** on the first-party path. A domain registered at another
/// registrar has no `/registrar/registrations` record, so a link that is always
/// there would push a screen that 404s — the `WorkerBuildsSection`
/// permanent-furniture mistake in a new place.
struct RegistrarManageLink: View {
  let domain: String

  var body: some View {
    dashListCard {
      DashListGroupLink(value: .registrarDomain(domain)) {
        DashListRow(
          title: DashL10n.string("Manage registration"),
          subtitle: DashL10n.string("Auto-renew, transfer lock, WHOIS privacy"),
          icon: SolarAsset.Content.globus
        )
        .dashListCardInset()
      }
    }
  }
}

// MARK: - Domains list

struct RegistrarDomainsView: View {
  @Environment(AppModel.self) private var model
  @State private var index: RegistrarAccountIndex?
  @State private var loading = true
  @State private var error: String?
  @State private var loadedContext: AccountRequestContext?

  private var domains: [RegistrarDomainSummary] { index?.domains ?? [] }

  private var allowsWrites: Bool {
    model.hasScopes(RegistrarAccess.write) && !model.isDemoSession
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !domains.isEmpty,
      retry: { Task { await load(force: true) } }
    ) {
      if domains.isEmpty {
        // Reached only when a source that answered 200 said zero. A 403, a beta
        // 404 or a decode failure takes the `fullScreenError` branch instead —
        // most accounts legitimately own no registrar domains, which makes this
        // state perfect camouflage for a failure.
        DashEmptyState(
          icon: SolarAsset.Content.globus,
          title: "No registered domains",
          message:
            "Domains you buy from Cloudflare Registrar appear here. Registration itself happens on the Cloudflare dashboard."
        )
      } else {
        if !allowsWrites {
          FeatureWriteAccessNotice(
            message: "Read-only — grant Registrar access to change these settings.",
            scopes: RegistrarAccess.write)
        }
        DashListGroupHeader(title: DashL10n.string("Registrar"))
          .padding(.horizontal, 4)
          .padding(.bottom, 8)
          .dashSectionBoundary(!allowsWrites)
        // Header and rows are siblings in the outer lazy stack — a
        // `DashListGroup` wrapper owns an eager `VStack` and would mount every
        // row of a long registrar list at once.
        dashListCard {
          dashListCardRows(items: domains) { domain in
            DashListGroupLink(value: .registrarDomain(domain.name)) {
              DashListRow(
                title: domain.name,
                subtitle: domain.expiresSubtitle,
                avatarSeed: domain.name
              ) {
                // Positive states carry no capsule: the row is the domain, and
                // "Registered" on every row is noise.
                if let token = domain.statusToken, token != .registered {
                  StatusBadge(token)
                }
              }
            }
          }
        }
      }
    }
    // No `detailHeader` here: this is `Destination.feature(.registrar)`, and
    // `FeatureRouterContent` already installs the catalog icon and title. A
    // second one would add a second principal toolbar item.
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) { await load() }
  }

  private func load(force: Bool = false) async {
    guard let context = model.accountRequestContext else {
      loadedContext = nil
      index = nil
      loading = false
      error = nil
      return
    }
    if loadedContext != context {
      loadedContext = context
      index = nil
      loading = true
      error = nil
    }
    let key = FeatureCacheKey.registrarDomains(context.accountID)
    if !force, let cached: RegistrarAccountIndex = model.featureCache.get(key) {
      settle(cached)
      return
    }
    if domains.isEmpty { loading = true }
    error = nil
    let loaded = await RegistrarIndexLoader.load(
      client: model.client, accountID: context.accountID)
    guard
      !Task.isCancelled,
      model.isCurrentAccount(context),
      loaded.isCacheable
    else { return }
    model.featureCache.set(key, loaded)
    settle(loaded)
  }

  private func settle(_ loaded: RegistrarAccountIndex) {
    index = loaded
    // An empty index that cannot be trusted is a failure, not an empty state.
    error = loaded.unresolvedFailure ?? loaded.partialFailure
    loading = false
  }
}

// MARK: - Domain detail

/// One Cloudflare Registrar domain: what the registry says about it, and the
/// two settings Cloudflare's API actually lets Dash change.
///
/// There is no Renew, no Transfer and no Delete. The API exposes none of them,
/// and a disabled button that explains itself is still furniture.
struct RegistrarDomainDetailView: View {
  @Environment(AppModel.self) private var model
  let domain: String

  /// Seeded from the account index the list screen (or a zone visit) already
  /// filled, so the facts and the switches paint on the first frame and only
  /// the registry-side sections wait on a request.
  @State private var seed: RegistrarDomainSummary?
  @State private var registration: RegistrarFetch<RegistrarRegistration>?
  @State private var legacy: RegistrarFetch<RegistrarDomain>?
  /// Optimistic overrides. Cleared back to `nil` on failure, which restores
  /// whatever Cloudflare last said rather than a second guess.
  @State private var autoRenewOverride: Bool?
  @State private var lockedOverride: Bool?
  @State private var inFlight: RegistrarSetting?
  @State private var loadedContext: AccountRequestContext?

  private enum RegistrarSetting: Hashable {
    case autoRenew
    case transferLock
  }

  private var allowsWrites: Bool {
    model.hasScopes(RegistrarAccess.write) && !model.isDemoSession
  }

  /// Everything known about the domain right now, from whichever of the three
  /// sources have landed.
  private var summary: RegistrarDomainSummary? {
    var resolved: RegistrarDomainSummary?
    if let registration = registration?.payload {
      resolved = RegistrarDomainSummary(registration: registration)
    }
    if let legacy = legacy?.payload, let fromLegacy = RegistrarDomainSummary(legacy: legacy) {
      resolved = resolved.map { RegistrarDomainSummary.merged($0, fromLegacy) } ?? fromLegacy
    }
    if let seed {
      resolved = resolved.map { RegistrarDomainSummary.merged($0, seed) } ?? seed
    }
    return resolved
  }

  private var autoRenewValue: Bool? { autoRenewOverride ?? summary?.autoRenew }
  private var lockedValue: Bool? { lockedOverride ?? summary?.locked }

  private var isCold: Bool {
    seed == nil && registration == nil && legacy == nil
  }

  /// Both lookups settled and neither knows this domain: it is not a Cloudflare
  /// registration, or it belongs to another account.
  private var screenError: String? {
    guard summary == nil, !isCold else { return nil }
    guard registration?.isCancelled != true, legacy?.isCancelled != true else { return nil }
    if let message = registration?.failureMessage ?? legacy?.failureMessage { return message }
    guard registration?.isSettledAnswer == true, legacy?.isSettledAnswer == true else {
      return nil
    }
    return DashL10n.string("Cloudflare has no registration for this domain.")
  }

  private var factsPhase: DashSectionPhase {
    if summary != nil { return .content }
    if let message = registration?.failureMessage ?? legacy?.failureMessage {
      return .failed(message)
    }
    return .loading
  }

  /// Registry statuses and the registrant contact both come from the
  /// page-numbered GET, so they share one phase and one retry.
  private var registryPhase: DashSectionPhase {
    switch legacy {
    case nil, .some(.cancelled): .loading
    case .some(.value), .some(.absent): .content
    case .some(.denied(let message)), .some(.failed(let message)): .failed(message)
    }
  }

  private var registryStatuses: [String] {
    // Bounded by the EPP vocabulary, but bounded here too: an info group owns
    // an eager stack and must never take an unbounded `ForEach`.
    Array((legacy?.payload?.registryStatusList ?? []).prefix(12))
  }

  private var registrant: RegistrarContact? {
    legacy?.payload?.registrantContact
  }

  var body: some View {
    DashFeatureList(
      isLoading: isCold,
      error: screenError,
      hasContent: summary != nil,
      retry: { Task { await load(force: true) } }
    ) {
      registrationGroup
      registryStatusGroup
      settingsGroup
      registrantGroup
    }
    .detailHeader(icon: .solar(SolarAsset.Content.globus), title: domain)
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) { await load() }
  }

  @ViewBuilder
  private var registrationGroup: some View {
    DashInfoGroup(
      title: "Registration",
      phase: factsPhase,
      // Status, Expires, Registered, Registrar — so the arriving values land on
      // the placeholders instead of growing the section.
      placeholderRows: 4,
      retry: { Task { await load(force: true) } },
      content: {
        if let summary {
          RegistrarRegistrationRows(summary: summary)
        }
      }
    )
  }

  @ViewBuilder
  private var registryStatusGroup: some View {
    // An empty status list is a settled answer and drops the section; a thrown
    // lookup keeps it and says so. Those are different answers.
    if registryPhase != .content || !registryStatuses.isEmpty {
      DashInfoGroup(
        title: "Registry status",
        phase: registryPhase,
        placeholderRows: 2,
        retry: { Task { await load(force: true) } },
        content: {
          ForEach(registryStatuses, id: \.self) { status in
            DashInfoRow(value: rdapStatusLabel(status))
          }
        }
      )
      .dashSectionBoundary()
    }
  }

  @ViewBuilder
  private var settingsGroup: some View {
    // Only the switches whose current value Cloudflare actually returned. The
    // beta registrations endpoint is the sole source of `auto_renew`, so a
    // domain it does not know keeps its transfer lock and simply has no
    // auto-renew row — rather than a switch that starts on a guess.
    if autoRenewValue != nil || lockedValue != nil {
      DashListGroupHeader(title: DashL10n.string("Settings"))
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
        .dashSectionBoundary()
      if !allowsWrites {
        FeatureWriteAccessNotice(
          message: "Read-only — grant Registrar access to change these settings.",
          scopes: RegistrarAccess.write
        )
        .padding(.bottom, DashTheme.Spacing.itemGap)
      }
      DashSurfaceStack {
        if let autoRenew = autoRenewValue {
          DashToggleRow(
            title: "Auto-renew",
            subtitle: autoRenew
              ? "Cloudflare renews this domain before it expires."
              : "Renew it yourself or you lose the domain.",
            isOn: Binding(get: { autoRenew }, set: { update(.autoRenew, to: $0) }),
            isEnabled: allowsWrites && inFlight == nil,
            isLoading: inFlight == .autoRenew)
        }
        if let locked = lockedValue {
          DashToggleRow(
            title: "Transfer lock",
            subtitle: locked
              ? "Another registrar can’t start a transfer."
              : "Another registrar can start a transfer.",
            isOn: Binding(get: { locked }, set: { update(.transferLock, to: $0) }),
            isEnabled: allowsWrites && inFlight == nil,
            isLoading: inFlight == .transferLock)
        }
      }
      Text(
        DashL10n.string(
          "Renewals, transfers, and contact changes happen on the Cloudflare dashboard.")
      )
      .dashTextStyle(.caption)
      .foregroundStyle(DashTheme.subtle)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .dashItemBoundary()
    }
  }

  @ViewBuilder
  private var registrantGroup: some View {
    // A settled-absent contact is dropped. Loading and failure keep the frame
    // so the section cannot silently disappear when the shared legacy request
    // throws.
    if registryPhase != .content || registrant != nil {
      DashInfoGroup(
        title: "Registrant",
        phase: registryPhase,
        placeholderRows: 3,
        retry: { Task { await load(force: true) } },
        content: {
          if let registrant {
            if let organization = registrant.organization, !organization.isEmpty {
              DashInfoRow("Organization", value: organization)
            }
            if let contact = registrant.displayName {
              DashInfoRow("Contact", value: contact)
            }
            if let email = registrant.email, !email.isEmpty {
              DashInfoRow("Email", value: email)
            }
            if let location = registrant.displayLocation {
              DashInfoRow("Location", value: location)
            }
          }
        }
      )
      .dashSectionBoundary()
    }
  }

  private func load(force: Bool = false) async {
    guard let context = model.accountRequestContext else {
      reset(for: nil)
      return
    }
    if loadedContext != context {
      reset(for: context)
    }
    let accountID = context.accountID
    guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
    if seed == nil,
      let index: RegistrarAccountIndex = model.featureCache.get(
        FeatureCacheKey.registrarDomains(accountID))
    {
      seed = index.domain(named: domain)
    }
    let key = FeatureCacheKey.registrarDomain(accountID: accountID, domain: domain)
    if !force, let cached: RegistrarDomainDetail = model.featureCache.get(key) {
      await apply(cached, accountID: accountID)
      return
    }
    if force {
      registration = nil
      legacy = nil
    }
    // Hoisted before the child tasks so neither closure captures `self`.
    let client = model.client
    let domain = domain
    async let registrationFetch = RegistrarFetch<RegistrarRegistration>.perform {
      try await client.getRegistrarRegistration(accountID: accountID, domain: domain)
    }
    async let legacyFetch = RegistrarFetch<RegistrarDomain>.perform {
      try await client.getRegistrarDomain(accountID: accountID, domain: domain)
    }
    let detail = RegistrarDomainDetail(
      registration: await registrationFetch, legacy: await legacyFetch)
    guard
      !Task.isCancelled,
      model.isCurrentAccount(context),
      detail.isCacheable
    else { return }
    model.featureCache.set(key, detail)
    await apply(detail, accountID: accountID)
  }

  private func reset(for context: AccountRequestContext?) {
    loadedContext = context
    seed = nil
    registration = nil
    legacy = nil
    autoRenewOverride = nil
    lockedOverride = nil
    inFlight = nil
  }

  private func apply(_ detail: RegistrarDomainDetail, accountID: String) async {
    withAnimation(DashTheme.Motion.content) {
      registration = detail.registration
      legacy = detail.legacy
      autoRenewOverride = nil
      lockedOverride = nil
    }
    await scheduleExpiryReminder(accountID: accountID)
  }

  /// Flips the control immediately, sends only the flag that changed, and puts
  /// the old value back if Cloudflare refuses.
  private func update(_ setting: RegistrarSetting, to value: Bool) {
    guard allowsWrites else {
      model.requestAccess(to: RegistrarAccess.write)
      return
    }
    guard inFlight == nil, let context = model.accountRequestContext else { return }
    let previousAutoRenew = autoRenewOverride
    let previousLocked = lockedOverride
    switch setting {
    case .autoRenew: autoRenewOverride = value
    case .transferLock: lockedOverride = value
    }
    inFlight = setting
    // Only the changed flag reaches the wire: re-asserting the other one from a
    // possibly-stale screen is how a transfer lock gets silently flipped back.
    let settings =
      switch setting {
      case .autoRenew: RegistrarDomainSettings(autoRenew: value)
      case .transferLock: RegistrarDomainSettings(locked: value)
      }
    Task {
      defer {
        if !Task.isCancelled, model.isCurrentAccount(context) {
          inFlight = nil
        }
      }
      do {
        try await model.client.updateRegistrarDomain(
          accountID: context.accountID, domain: domain, settings: settings)
        guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
        // List, detail and the zone card all read these two keys; leaving
        // either behind would show the old answer one screen away.
        model.featureCache.remove(FeatureCacheKey.registrarDomains(context.accountID))
        model.featureCache.remove(
          FeatureCacheKey.registrarDomain(accountID: context.accountID, domain: domain))
        DashDelight.celebrateSuccess()
        // The toggle is the moment the reminder's premise changes: auto-renew
        // going on means there is no longer a deadline to count down to.
        await scheduleExpiryReminder(accountID: context.accountID)
      } catch {
        guard
          !Task.isCancelled,
          !error.dashIsCancellation,
          model.isCurrentAccount(context)
        else { return }
        autoRenewOverride = previousAutoRenew
        lockedOverride = previousLocked
        model.toasts.error(error.dashActionableMessage)
      }
    }
  }

  /// Applies (or withdraws) this domain's expiry reminders from whatever is
  /// currently on screen. A Cloudflare registration that renews itself gets no
  /// countdown — and any countdown left from before is removed.
  private func scheduleExpiryReminder(accountID: String) async {
    guard !model.isDemoSession, let summary else { return }
    let renewal = ExpiryReminders.renewal(
      registrarStatus: summary.status, autoRenew: autoRenewValue)
    let expiresOn = summary.expiresOn
    let route = RegistrarRoute.deepLink(domain: summary.name, accountID: accountID)
    await ExpiryReminders.applyDomainReminder(
      domain: summary.name,
      accountID: accountID,
      expiresOn: expiresOn,
      renewal: renewal,
      route: route)
  }
}

/// Both halves of one registrar domain, cached together so a revisit paints
/// without re-asking either endpoint.
struct RegistrarDomainDetail: Sendable {
  let registration: RegistrarFetch<RegistrarRegistration>
  let legacy: RegistrarFetch<RegistrarDomain>

  var isCacheable: Bool {
    !registration.isCancelled && !legacy.isCancelled
  }
}

extension RegistrarDomainSummary {
  fileprivate var expiresSubtitle: String? {
    guard let expiresAt else { return nil }
    return DashL10n.string("Expires \(registrarDateLabel(expiresAt))")
  }

  /// Cloudflare documents exactly one value for `privacy_mode` (`redaction`)
  /// and publishes no enum, so an unrecognised one survives the wire and is
  /// localized at the last render step rather than dropped.
  fileprivate var privacyLabel: String? {
    let raw = (privacyMode ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }
    if raw.lowercased() == "redaction" { return DashL10n.string("Redacted") }
    let label: String = DashL10n.ui(
      raw.replacingOccurrences(of: "_", with: " ").capitalized)
    return label
  }
}

extension RegistrarContact {
  fileprivate var displayName: String? {
    let parts = [firstName, lastName]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  fileprivate var displayLocation: String? {
    let parts = [city, state, country]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }
}

// MARK: - Formatting

/// Registrar and RDAP both send ISO 8601 stamps; show a localized day.
func registrarDateLabel(_ value: String) -> String {
  guard let date = ExpiryReminders.date(fromISO8601: value) else {
    return String(value.prefix(10))
  }
  let day = DateFormatter()
  day.dateStyle = .medium
  day.timeStyle = .none
  day.locale = DashL10n.activeLocale
  return day.string(from: date)
}

/// The EPP / RDAP status vocabulary, keyed by a code with its case and every
/// separator dropped.
///
/// The same code reaches Dash spelled three ways: RDAP sends it lowercased and
/// spaced ("client transfer prohibited"), the WHOIS backstop sends EPP camelCase
/// ("clientTransferProhibited"), and Cloudflare's Registrar API sends it
/// lowercased and run together ("clienttransferprohibited"). Only the first two
/// carry a boundary a splitter can find, which is why the third used to reach
/// the screen as "Clienttransferprohibited" — one unreadable word, and a key no
/// catalog can hold, so it stayed English on a Chinese screen.
///
/// Matching on letters alone folds every spelling onto the one English source
/// form `Localizable.xcstrings` does hold. The vocabulary is closed (RFC 5731
/// plus ICANN's grace periods), so a table is the honest shape here; anything
/// outside it falls back to `rdapStatusLabel`'s shape heuristic and keeps
/// Cloudflare's own wording.
enum RegistryStatusVocabulary {
  /// A status code reduced to its letters and digits, so case and every
  /// separator (space, `_`, `-`, the ICANN URL's `#`) stop mattering.
  static func key(_ raw: String) -> String {
    raw.lowercased().filter { $0.isLetter || $0.isNumber }
  }

  static let labels: [String: String] = [
    "ok": "OK",
    "active": "Active",
    "inactive": "Inactive",
    "linked": "Linked",
    "clientdeleteprohibited": "Client Delete Prohibited",
    "clienthold": "Client Hold",
    "clientrenewprohibited": "Client Renew Prohibited",
    "clienttransferprohibited": "Client Transfer Prohibited",
    "clientupdateprohibited": "Client Update Prohibited",
    "serverdeleteprohibited": "Server Delete Prohibited",
    "serverhold": "Server Hold",
    "serverrenewprohibited": "Server Renew Prohibited",
    "servertransferprohibited": "Server Transfer Prohibited",
    "serverupdateprohibited": "Server Update Prohibited",
    "pendingcreate": "Pending Create",
    "pendingdelete": "Pending Delete",
    "pendingrenew": "Pending Renew",
    "pendingrestore": "Pending Restore",
    "pendingtransfer": "Pending Transfer",
    "pendingupdate": "Pending Update",
    "addperiod": "Add Period",
    "autorenewperiod": "Auto Renew Period",
    "redemptionperiod": "Redemption Period",
    "renewperiod": "Renew Period",
    "transferperiod": "Transfer Period",
  ]
}

/// One English source form per status code, whatever spelling it arrived in, so
/// a single catalog key localizes it — and so the zone screen's Registration
/// card and the registrar screen's Registry status never spell the same code two
/// ways.
func rdapStatusLabel(_ raw: String) -> String {
  if let known = RegistryStatusVocabulary.labels[RegistryStatusVocabulary.key(raw)] {
    return DashL10n.ui(known)
  }
  // Unrecognized code: split what has a boundary and keep Cloudflare's wording
  // rather than inventing words a lowercase run does not contain.
  var spaced =
    raw
    .replacingOccurrences(of: "_", with: " ")
    .replacingOccurrences(of: "-", with: " ")
  if !spaced.contains(" ") {
    var split = ""
    for character in spaced {
      if character.isUppercase, !split.isEmpty { split.append(" ") }
      split.append(character)
    }
    spaced = split
  }
  return DashL10n.ui(spaced.lowercased().capitalized)
}
