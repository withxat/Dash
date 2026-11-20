import CloudflareAPI
import SwiftUI

// MARK: - Access

/// The one place the Registrar scope ids are written.
///
/// Registrar is not a catalog `FeatureID`, so these are literals rather than a
/// capability lookup — the same shape `readScopes(for:)` already uses for
/// `dns.*`. `readScopes` / `writeScopes` for
/// `.registrarDomain` read them from here, so the pushed screen and the OAuth
/// audit can never disagree about what it needs.
enum RegistrarAccess {
  /// In `DashAuthorizationScopes.coreReadOperations`, and it has to be: the
  /// only thing that asks for it is the zone screen's Registration lookup,
  /// which has no button to request it on demand.
  static let read: Set<String> = ["registrar-domains.read"]

  /// `.admin`, not `.write`. `registrar-domains.write` does not exist in
  /// Cloudflare's scope catalog, and `CloudflareScopes.sanitized()` drops
  /// unknown ids silently — the guess produces a successful consent flow that
  /// grants nothing, and a read-only screen with no error to explain it.
  ///
  /// In `DashAuthorizationScopes.coreWriteOperations`: auto-renew is what the
  /// detail screen is for. The screen still carries a
  /// `FeatureWriteAccessNotice` for grants that predate that.
  static let write: Set<String> = ["registrar-domains.admin"]
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

/// One domain in the account's Cloudflare Registrar index, from the
/// `/registrar/registrations` list. Anything Cloudflare did not say stays `nil`
/// and costs one row.
struct RegistrarDomainSummary: Identifiable, Hashable, Sendable {
  var id: String { name }
  let name: String
  let status: String?
  let expiresAt: String?
  let createdAt: String?
  let autoRenew: Bool?
  let locked: Bool?
  let privacyMode: String?

  init(
    name: String,
    status: String? = nil,
    expiresAt: String? = nil,
    createdAt: String? = nil,
    autoRenew: Bool? = nil,
    locked: Bool? = nil,
    privacyMode: String? = nil
  ) {
    self.name = name
    self.status = status
    self.expiresAt = expiresAt
    self.createdAt = createdAt
    self.autoRenew = autoRenew
    self.locked = locked
    self.privacyMode = privacyMode
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
      privacyMode: primary.privacyMode ?? secondary.privacyMode)
  }

  var statusToken: StatusToken? {
    guard let status, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return StatusToken(registrarStatus: status)
  }
}

/// The account's registrar index, plus what the list endpoint actually said.
///
/// `/registrar/registrations` is the only list left: the page-numbered
/// `/registrar/domains` it used to be merged with reached end of life on
/// 2026-09-27. A zone whose name is missing from it simply falls through to
/// RDAP, so the endpoint's silence is never reported as an answer.
struct RegistrarAccountIndex: Sendable {
  let domains: [RegistrarDomainSummary]
  let registrations: RegistrarFetch<[RegistrarDomainSummary]>

  func domain(named name: String) -> RegistrarDomainSummary? {
    let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return nil }
    // Exact equality only. A registrar-owned `example.com` says nothing about a
    // `blog.example.com` zone's own registration record, so suffix matching
    // would attach one domain's expiry date and auto-renew state to another's.
    return domains.first { $0.name.lowercased() == needle }
  }

  /// A half-torn-down load is not a result. Caching one would freeze a partial
  /// answer for the cache's whole lifetime.
  var isCacheable: Bool {
    !registrations.isCancelled
  }
}

enum RegistrarIndexLoader {
  /// Never throws: the endpoint's outcome is carried in the index so the
  /// caller can tell "denied" from "not there" from "said nothing".
  static func load(client: CloudflareClient, accountID: String) async
    -> RegistrarAccountIndex
  {
    let registrations = await RegistrarFetch<[RegistrarDomainSummary]>.perform {
      try await client.listRegistrarRegistrations(accountID: accountID)
        .map(RegistrarDomainSummary.init(registration:))
    }
    return RegistrarAccountIndex(
      // By name, not by expiry: a list the user scans by hostname must not
      // reorder itself the day a renewal lands.
      domains: (registrations.payload ?? []).sorted { $0.name < $1.name },
      registrations: registrations)
  }
}

/// The zone screen's half of the registrar lookup.
///
/// The account index is cached under one key and seeds
/// `RegistrarDomainDetailView`, so opening a zone and then its registration
/// never fetches the list twice in a session.
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
    // it every zone visit in the session re-asks an endpoint that already said
    // no.
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
      DashInfoRow("Expires", value: DashDateFormatting.dateOnly(fromISO8601: expires))
    }
    if let created = summary.createdAt {
      DashInfoRow("Registered", value: DashDateFormatting.dateOnly(fromISO8601: created))
    }
    // Read-only: the Registrar API returns the lock but cannot change it. The
    // legacy endpoint that could reached end of life on 2026-09-27.
    if let locked = summary.locked {
      DashInfoRow(
        "Transfer lock", value: locked ? DashL10n.string("On") : DashL10n.string("Off"))
    }
    // Read-only too: the API has no privacy write. Surface the status and
    // point privacy changes at the Cloudflare dashboard.
    if let privacy = summary.privacyLabel {
      DashInfoRow("WHOIS privacy", value: privacy)
      DashInfoRow("Privacy settings", value: DashL10n.string("Cloudflare dashboard"))
    }
  }
}

// MARK: - Domain detail

/// One Cloudflare Registrar domain: what Cloudflare says about it, and the one
/// setting its API lets Dash change.
///
/// There is no Renew, no Transfer and no Delete, and the transfer lock is a
/// read-only fact: the Registrar API exposes none of those writes, and a
/// disabled button that explains itself is still furniture.
struct RegistrarDomainDetailView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let domain: String

  /// Seeded from the account index a zone visit already filled, so the facts
  /// and the switch paint on the first frame.
  @State private var seed: RegistrarDomainSummary?
  @State private var registration: RegistrarFetch<RegistrarRegistration>?
  /// Optimistic override. Cleared back to `nil` on failure, which restores
  /// whatever Cloudflare last said rather than a second guess.
  @State private var autoRenewOverride: Bool?
  @State private var isSavingAutoRenew = false
  @State private var loadedContext: AccountRequestContext?

  private var allowsWrites: Bool {
    model.hasScopes(RegistrarAccess.write)
  }

  /// Everything known about the domain right now: the registration once it has
  /// landed, the seed for anything it did not say.
  private var summary: RegistrarDomainSummary? {
    let fetched = registration?.payload.map(RegistrarDomainSummary.init(registration:))
    guard let seed else { return fetched }
    return fetched.map { RegistrarDomainSummary.merged($0, seed) } ?? seed
  }

  private var autoRenewValue: Bool? { autoRenewOverride ?? summary?.autoRenew }

  private var isCold: Bool {
    seed == nil && registration == nil
  }

  /// The lookup settled and Cloudflare does not know this domain: it is not a
  /// Cloudflare registration, or it belongs to another account.
  private var screenError: String? {
    guard summary == nil, let registration, !registration.isCancelled else { return nil }
    if let message = registration.failureMessage { return message }
    return DashL10n.string("Cloudflare has no registration for this domain.")
  }

  private var factsPhase: DashSectionPhase {
    if summary != nil { return .content }
    if let message = registration?.failureMessage { return .failed(message) }
    return .loading
  }

  var body: some View {
    DashFeatureList(
      isLoading: isCold,
      error: screenError,
      hasContent: summary != nil,
      retry: { Task { await load(force: true) } }
    ) { mode in
      registrarDomainDetailBody(mode: mode)
    }
    // Tinted by hand: with no catalog feature behind it there is no
    // `featureIdentity` to resolve, and the brand-orange fallback would read as
    // a Workers screen. Teal was this screen's mark while Registrar was in the
    // catalog and is still unclaimed by any surviving feature.
    .detailHeader(
      icon: .solar(SolarAsset.Content.globus), title: domain,
      tint: FeatureVisualTone.teal.vivid
    )
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) { await load() }
  }

  /// First-paint reserve: the registration facts and the auto-renew switch.
  @ViewBuilder
  private func registrarDomainDetailBody(mode: DashBodyMode) -> some View {
    if mode.isPlaceholder {
      DashInfoGroup(title: "Registration", phase: .loading, placeholderRows: 4) {
        EmptyView()
      }
      .dashBodySlot(reduceMotion: reduceMotion)
      DashListGroupHeader(title: DashL10n.string("Settings"))
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
        .dashSectionBoundary()
      DashSurfaceStack {
        DashToggleRowPlaceholder()
      }
      .dashBodySlot(reduceMotion: reduceMotion)
    } else {
      registrationGroup
        .dashBodySlot(reduceMotion: reduceMotion)
      settingsGroup
    }
  }

  @ViewBuilder
  private var registrationGroup: some View {
    DashInfoGroup(
      title: "Registration",
      phase: factsPhase,
      // Status, Expires, Registered, Transfer lock — so the arriving values
      // land on the placeholders instead of growing the section.
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
  private var settingsGroup: some View {
    // Only when Cloudflare actually returned the current value, rather than a
    // switch that starts on a guess.
    if let autoRenew = autoRenewValue {
      Group {
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
          DashToggleRow(
            title: "Auto-renew",
            subtitle: autoRenew
              ? "Cloudflare renews this domain before it expires."
              : "Renew it yourself or you lose the domain.",
            isOn: Binding(get: { autoRenew }, set: { updateAutoRenew(to: $0) }),
            isEnabled: allowsWrites && !isSavingAutoRenew,
            isLoading: isSavingAutoRenew)
        }
        Text(
          DashL10n.string(
            "Renewals, transfers, the transfer lock, and contacts are managed on the Cloudflare dashboard."
          )
        )
        .dashTextStyle(.caption)
        .foregroundStyle(DashTheme.subtle)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .dashItemBoundary()
      }
      .dashBodySlot(reduceMotion: reduceMotion)
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
    if !force, let cached: RegistrarFetch<RegistrarRegistration> = model.featureCache.get(key) {
      apply(cached)
      return
    }
    if force {
      registration = nil
    }
    // Hoisted so the child task does not capture `self`.
    let client = model.client
    let domain = domain
    async let fetch = RegistrarFetch<RegistrarRegistration>.perform {
      try await client.getRegistrarRegistration(accountID: accountID, domain: domain)
    }
    let fetched = await fetch
    // A torn-down load is not an answer: caching one would freeze it.
    guard !Task.isCancelled, model.isCurrentAccount(context), !fetched.isCancelled else {
      return
    }
    model.featureCache.set(key, fetched)
    apply(fetched)
  }

  private func reset(for context: AccountRequestContext?) {
    loadedContext = context
    seed = nil
    registration = nil
    autoRenewOverride = nil
    isSavingAutoRenew = false
  }

  private func apply(_ fetched: RegistrarFetch<RegistrarRegistration>) {
    withAnimation(DashTheme.Motion.content) {
      registration = fetched
      autoRenewOverride = nil
    }
  }

  /// Flips the switch immediately and puts the old value back if Cloudflare
  /// refuses.
  private func updateAutoRenew(to value: Bool) {
    guard allowsWrites else {
      model.requestAccess(to: RegistrarAccess.write)
      return
    }
    guard !isSavingAutoRenew, let context = model.accountRequestContext else { return }
    let previous = autoRenewOverride
    autoRenewOverride = value
    isSavingAutoRenew = true
    let op = model.optimistic.begin(.toggle(value)) {
      autoRenewOverride = previous
      isSavingAutoRenew = false
    }
    Task {
      defer {
        if !Task.isCancelled, model.isCurrentAccount(context) {
          isSavingAutoRenew = false
        }
      }
      do {
        try await model.optimistic.waitForCommit(op)
        try await model.client.updateRegistrarAutoRenew(
          accountID: context.accountID, domain: domain, autoRenew: value)
        guard !Task.isCancelled, model.isCurrentAccount(context) else {
          model.optimistic.finishFailure(op)
          return
        }
        // This screen and the zone card read these two keys; leaving either
        // behind would show the old answer one screen away.
        model.featureCache.remove(FeatureCacheKey.registrarDomains(context.accountID))
        model.featureCache.remove(
          FeatureCacheKey.registrarDomain(accountID: context.accountID, domain: domain))
        model.optimistic.finishSuccess(op)
      } catch is CancellationError {
        // Undo during grace already reverted local state.
      } catch {
        guard
          !Task.isCancelled,
          !error.dashIsCancellation,
          model.isCurrentAccount(context)
        else {
          model.optimistic.finishFailure(op)
          return
        }
        autoRenewOverride = previous
        model.optimistic.finishFailure(op)
        model.toasts.error(error.dashActionableMessage)
      }
    }
  }
}

extension RegistrarDomainSummary {
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

// MARK: - Formatting

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
