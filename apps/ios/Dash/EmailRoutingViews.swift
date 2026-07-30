import CloudflareAPI
import SwiftDitherKit
import SwiftUI

// MARK: - Resources index

/// Catalog entry for `FeatureID.emailRouting`: every zone on the account, with
/// routing status when the settings call answers. Row push opens the existing
/// per-zone Email Routing screen.
struct EmailRoutingDomainsView: View {
  @Environment(AppModel.self) private var model
  @State private var zones: [CloudflareZone] = []
  @State private var statusByZoneID: [String: StatusToken] = [:]
  @State private var loading = true
  @State private var error: String?
  @State private var loadedContext: AccountRequestContext?

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !zones.isEmpty,
      retry: { Task { await load(force: true) } }
    ) {
      if zones.isEmpty {
        DashEmptyState(
          icon: SolarAsset.Content.inbox,
          title: "No domains yet",
          message: "Add a domain to Cloudflare first, then set up Email Routing here."
        )
      } else {
        DashListGroupHeader(title: DashL10n.string("Domains"))
          .padding(.horizontal, 4)
          .padding(.bottom, 8)
        dashListCard {
          dashListCardRows(items: zones) { zone in
            DashListGroupLink(value: .zoneEmailRouting(zone.id)) {
              DashListRow(
                title: zone.name,
                subtitle: nil,
                avatarSeed: zone.name
              ) {
                if let token = statusByZoneID[zone.id], token != .disabled {
                  StatusBadge(token)
                }
              }
            }
          }
        }
      }
    }
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) { await load() }
  }

  private func load(force: Bool = false) async {
    guard let context = model.accountRequestContext else {
      loadedContext = nil
      zones = []
      statusByZoneID = [:]
      loading = false
      error = nil
      return
    }
    if loadedContext != context {
      loadedContext = context
      zones = []
      statusByZoneID = [:]
    }
    let key = FeatureCacheKey.zones(context.accountID)
    if !force, let cached: [CloudflareZone] = model.featureCache.get(key) {
      zones = cached
      loading = false
      error = nil
      await loadStatuses(for: cached, force: force)
      return
    }
    if zones.isEmpty { loading = true }
    error = nil
    do {
      var collected: [CloudflareZone] = []
      var pageNumber = 1
      while true {
        let page = try await model.client.listZones(
          accountID: context.accountID, page: pageNumber, perPage: 50)
        collected.append(contentsOf: page.items)
        let hasMore: Bool
        if let info = page.resultInfo,
          let pageNum = info.page,
          let perPage = info.perPage,
          let total = info.totalCount
        {
          hasMore = pageNum * perPage < total
        } else {
          hasMore = page.items.count >= 50
        }
        guard hasMore else { break }
        pageNumber += 1
        if pageNumber > 40 { break }
      }
      zones = collected
      model.featureCache.storeZones(collected, accountID: context.accountID)
      await loadStatuses(for: collected, force: force)
    } catch {
      guard !error.dashIsCancellation else { return }
      self.error = error.dashActionableMessage
    }
    loading = false
  }

  private func loadStatuses(for zones: [CloudflareZone], force: Bool) async {
    let client = model.client
    let cache = model.featureCache
    var next: [String: StatusToken] = statusByZoneID
    await withTaskGroup(of: (String, StatusToken?).self) { group in
      for zone in zones {
        let zoneID = zone.id
        let key = FeatureCacheKey.emailRouting(zoneID)
        if !force, let cached: EmailRoutingSnapshot = cache.get(key) {
          next[zoneID] = EmailRoutingStatusMapping.token(for: cached.settings)
          continue
        }
        group.addTask {
          do {
            let settings = try await client.getEmailRoutingSettings(zoneID: zoneID)
            return (zoneID, EmailRoutingStatusMapping.token(for: settings))
          } catch {
            return (zoneID, nil)
          }
        }
      }
      for await (zoneID, token) in group {
        if let token { next[zoneID] = token }
      }
    }
    statusByZoneID = next
  }
}

// MARK: - Cached payload

/// The zone-scoped Email Routing payload, cached under
/// `FeatureCacheKey.emailRouting(zoneID)`.
///
/// Only successful fetches are written here, so a `nil` `catchAll` read back
/// from the cache means "Cloudflare reports no catch-all", never "the last
/// attempt threw". The screen keeps the failure in its own `catchAllError`,
/// because empty and failed are different answers.
struct EmailRoutingSnapshot: Sendable {
  var settings: EmailRoutingSettings
  var rules: [EmailRoutingRule]
  var catchAll: EmailRoutingCatchAllRule?
}

/// The sentinel the delivery pickers use for "drop the mail". Kept as a stable
/// English token, never a localized string: it is compared against, and
/// `DashMenuRow` / `DashFormMenuField` localize their options at render.
let emailRoutingDropOption = "Drop"

/// Write scopes every mutation on this screen needs. Declared once so the
/// read-only notice and the controls cannot drift apart.
let emailRoutingWriteScopes: Set<String> = [
  "zone-settings.write",
  "email-routing-rule.write",
]

// MARK: - Zone screen

/// Email Routing for one zone: status, routes, catch-all, destination-address
/// summary, plus addressing, and turn-off.
///
/// The backbone payload is `getEmailRoutingSettings`. **A throw from it is a
/// failure, never "routing is off"** — only a 200 whose `enabled` is false (or
/// whose status is `unconfigured`) may paint the not-set-up state, because that
/// state's single call to action rewrites the zone's apex MX records. Painting
/// a 404 or a 5xx as "off" would offer a destructive button in answer to an
/// error.
struct EmailRoutingView: View {
  static let rulePageSize = 50

  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  let zoneID: String

  @State private var settings: EmailRoutingSettings?
  @State private var rules: [EmailRoutingRule] = []
  @State private var catchAll: EmailRoutingCatchAllRule?
  /// `nil` means the account's destination addresses are not known — either not
  /// fetched yet or the fetch failed. Every claim keyed off this list (the
  /// Unverified route badge, the delivery pickers, the summary counts) is
  /// suppressed while it is nil, so a failed lookup never badges a healthy
  /// route or reports "0 addresses".
  @State private var addresses: [EmailDestinationAddress]?
  @State private var pageState = DashPageState()
  @State private var loading = true
  @State private var loadMorePhase: DashActionPhase = .idle
  @State private var error: String?
  @State private var rulesError: String?
  @State private var catchAllError: String?
  @State private var enableTarget: EmailRoutingEnableTarget?
  @State private var editedRule: EmailRoutingRule?
  @State private var createsRule = false
  @State private var showsTurnOff = false
  @State private var subaddressing = false
  @State private var subaddressingUpdating = false
  @State private var catchAllUpdating = false
  @State private var loadedContext: AccountRequestContext?
  @State private var analytics: EmailRoutingAnalyticsSummary?
  @State private var analyticsFailed = false

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: settings != nil,
      retry: { Task { await load(force: true) } }
    ) {
      if let settings {
        if Self.isNotSetUp(settings) {
          notSetUpState(settings)
        } else {
          configuredContent(settings)
        }
      }
    }
    .detailHeader(
      icon: .solar(SolarAsset.Content.inbox),
      title: "Email routing",
      tint: FeatureVisualIdentity.heroColor(for: .emailRouting)
    )
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) { await load() }
    .dashTray(
      item: $enableTarget,
      title: { $0.title },
      sizing: .large,
      content: { target in
        EmailRoutingEnableTray(
          zoneID: zoneID,
          zoneName: target.zoneName,
          confirmTitle: target.confirmTitle
        ) {
          await load(force: true)
        }
      }
    )
    .dashTray(isPresented: $createsRule, title: "New route") {
      EmailRoutingRuleEditor(
        zoneID: zoneID,
        zoneName: settings?.name ?? "",
        rule: nil,
        deliveryOptions: deliveryOptions,
        onOpenAddresses: openAddresses
      ) {
        await load(force: true)
      }
    }
    .dashTray(
      item: $editedRule,
      title: { _ in "Route" },
      content: { rule in
        EmailRoutingRuleEditor(
          zoneID: zoneID,
          zoneName: settings?.name ?? "",
          rule: rule,
          deliveryOptions: deliveryOptions,
          onOpenAddresses: openAddresses
        ) {
          await load(force: true)
        }
      }
    )
    .dashMoreMenu(
      isPresented: $showsTurnOff,
      title: DashL10n.string("Turn off email routing"),
      actions: [turnOffAction]
    )
  }

  // MARK: Not set up

  /// Reachable only from a 200. `unconfigured` is Cloudflare's own word for
  /// "the wizard never ran"; `enabled == false` covers a zone that was turned
  /// off again.
  private static func isNotSetUp(_ settings: EmailRoutingSettings) -> Bool {
    settings.enabled == false || settings.routingStatus == .unconfigured
  }

  @ViewBuilder
  private func notSetUpState(_ settings: EmailRoutingSettings) -> some View {
    if !featureAllowsWrites {
      FeatureWriteAccessNotice(
        message: "Read-only — grant Email Routing write access to change routes.",
        scopes: emailRoutingWriteScopes)
    }
    DashEmptyState(
      icon: SolarAsset.Content.inbox,
      title: "Email routing is off",
      message:
        "Forward mail sent to addresses at this domain to an inbox you already use. Cloudflare adds the MX and SPF records for you.",
      actionTitle: featureAllowsWrites ? "Set up email routing" : nil,
      action: featureAllowsWrites
        ? {
          enableTarget = EmailRoutingEnableTarget(
            zoneName: settings.name,
            title: "Turn on email routing",
            confirmTitle: "Turn on email routing")
        } : nil
    )
    .dashSectionBoundary(!featureAllowsWrites)
  }

  // MARK: Configured

  @ViewBuilder
  private func configuredContent(_ settings: EmailRoutingSettings) -> some View {
    if !featureAllowsWrites {
      FeatureWriteAccessNotice(
        message: "Read-only — grant Email Routing write access to change routes.",
        scopes: emailRoutingWriteScopes)
    }
    statusGroup(settings)
      .dashSectionBoundary(!featureAllowsWrites)
    if let analytics, !analytics.isEmpty {
      emailRoutingAnalyticsSection(analytics)
        .dashSectionBoundary()
    }
    routesSection
    catchAllSection
    addressesSection
    if settings.supportSubaddress != nil {
      subaddressingSection
    }
    if featureAllowsWrites {
      turnOffRow
    }
  }

  /// Volume from `emailRoutingAdaptiveGroups`. Hidden when empty or the
  /// analytics call failed (403 / plan) — same spirit as Workers Builds.
  private func emailRoutingAnalyticsSection(_ summary: EmailRoutingAnalyticsSummary) -> some View {
    let seriesData = summary.series.compactMap { point -> DitherDatum? in
      let parser = ISO8601DateFormatter()
      parser.formatOptions = [.withInternetDateTime]
      guard let date = parser.date(from: point.datetime) else { return nil }
      return DitherDatum(
        id: date.ISO8601Format(),
        label: date.formatted(.dateTime.hour().locale(DashL10n.activeLocale)),
        values: ["mail": Double(point.count)])
    }
    let collapsed = CollapsedDitherTrendSeries(values: seriesData.map { $0.values["mail"] ?? 0 })
    let sparkData = zip(seriesData, collapsed.values).map { point, value in
      DitherDatum(id: point.id, label: point.label, values: ["mail": value])
    }
    return DashSurfaceStack {
      DashGlassCard {
        VStack(alignment: .leading, spacing: 8) {
          Text("Last \(summary.hours) hours")
            .dashTextStyle(.footnoteSemibold)
            .foregroundStyle(DashTheme.subtle)
          Text(summary.total.formatted())
            .dashTextStyle(.sectionTitle)
            .foregroundStyle(DashTheme.text)
            .monospacedDigit()
          Text("Processed messages")
            .dashTextStyle(.caption)
            .foregroundStyle(DashTheme.subtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if !sparkData.isEmpty {
        DashCollapsedChartCard(
          title: "Email volume",
          summaryValue: summary.total.formatted(.number.locale(DashL10n.activeLocale)),
          data: sparkData,
          series: [
            DitherSeries(
              id: "mail",
              label: DashL10n.ui("Messages"),
              color: DashTheme.DitherChart.negative(
                colorScheme: colorScheme,
                contrast: colorSchemeContrast),
              variant: .gradient)
          ],
          valueCeiling: collapsed.valueCeiling,
          accessibilitySummary: DashL10n.string(
            "Email Routing volume over the last \(summary.hours) hours. Total \(summary.total.formatted())."
          )
        )
      }
    }
  }

  // MARK: §2 Status

  /// One view, not a tuple: `DashSurfaceStack` already supplies the item gap
  /// between the group and the repair affordance, and the caller applies a
  /// section boundary to the whole block.
  private func statusGroup(_ settings: EmailRoutingSettings) -> some View {
    DashSurfaceStack {
      DashInfoGroup(title: "Email routing", placeholderRows: 2) {
        DashInfoRow("Status") {
          StatusBadge(EmailRoutingStatusMapping.token(for: settings))
        }
        DashInfoRow("Domain", value: settings.name)
      }
      if EmailRoutingStatusMapping.needsDNSRepair(settings) {
        DashNotice(
          kind: .warning,
          message: "Some DNS records Email routing needs are missing. Mail may not be delivered."
        )
        if featureAllowsWrites {
          // Repairing re-runs the same apex MX write as first-time setup, so it
          // goes through the same preview + hold-to-confirm tray rather than
          // firing straight off a pill.
          DashPillButton(title: "Fix DNS records") {
            enableTarget = EmailRoutingEnableTarget(
              zoneName: settings.name,
              title: "Fix DNS records",
              confirmTitle: "Fix DNS records")
          }
        }
      }
    }
  }

  // MARK: §3 Routes

  /// The routes list is unbounded, so its header goes straight into
  /// `DashFeatureList`'s lazy stack and the rows follow as its sibling —
  /// `DashListGroup` owns an eager `VStack` (and its own horizontal inset), so
  /// wrapping these would both mount every route at once and double-inset them.
  @ViewBuilder
  private var routesSection: some View {
    DashListGroupHeader(
      title: DashL10n.ui("Routes"),
      actionTitle: featureAllowsWrites ? DashL10n.ui("Add") : nil,
      actionIcon: featureAllowsWrites ? SolarAsset.plus : nil,
      action: featureAllowsWrites ? { createsRule = true } : nil
    )
    .padding(.horizontal, 4)
    .dashSectionBoundary()
    .padding(.bottom, 8)

    if let rulesError, rules.isEmpty {
      // Failed, not empty: the list stays silent about how many routes exist.
      DashNotice(kind: .warning, message: rulesError)
        .dashListCardInset()
    } else if rules.isEmpty {
      DashEmptyState(
        icon: SolarAsset.Content.inbox,
        title: "No routes",
        message: "Add a custom address to start forwarding mail.")
    } else {
      dashListCardRows(items: rules) { rule in
        Button {
          editedRule = rule
        } label: {
          DashListRow(
            title: routeTitle(rule),
            subtitle: routeSubtitle(rule),
            icon: SolarAsset.Content.inbox,
            iconColor: FeatureVisualIdentity.catalogColor(for: .emailRouting),
            showsChevron: false
          ) {
            if let token = routeBadge(rule) {
              StatusBadge(token)
            }
          }
        }
        .buttonStyle(DashSurfaceButtonStyle())
      }
      if pageState.canLoadMore || loadMorePhase.isActive {
        DashLoadMoreFooter(
          loaded: rules.count,
          total: pageState.totalCount,
          noun: "routes",
          phase: loadMorePhase,
          onSuccessPresentationCompleted: { loadMorePhase = .idle },
          action: { Task { await loadMoreRules() } }
        )
      }
    }
  }

  private func routeTitle(_ rule: EmailRoutingRule) -> String {
    rule.matchedAddress ?? rule.name ?? rule.id
  }

  private func routeSubtitle(_ rule: EmailRoutingRule) -> String? {
    guard let action = rule.actions.first else { return nil }
    switch action.type {
    case "forward":
      return action.forwardTarget.map { DashL10n.string("Forwards to \($0)") }
    case "drop":
      return DashL10n.string("Drops")
    case "worker":
      guard let name = action.value?.first, !name.isEmpty else { return nil }
      return DashL10n.string("Worker · \(name)")
    default:
      return nil
    }
  }

  /// Badge precedence, decided here and nowhere else: ownership beats state,
  /// state beats deliverability.
  private func routeBadge(_ rule: EmailRoutingRule) -> StatusToken? {
    if rule.isWranglerManaged { return .managed }
    if rule.enabled == false { return .disabled }
    // Only a loaded address list may claim a route is undeliverable. While
    // `addresses` is nil the screen knows nothing about verification and says
    // nothing — a failed lookup must not badge every forwarding route.
    guard let addresses, let target = rule.actions.compactMap(\.forwardTarget).first else {
      return nil
    }
    let match = addresses.first { $0.email.caseInsensitiveCompare(target) == .orderedSame }
    return match?.isVerified == true ? nil : .unverified
  }

  // MARK: §4 Catch-all

  @ViewBuilder
  private var catchAllSection: some View {
    // Nothing at all until the lookup has settled one way or the other — an
    // empty section boundary is a gap the user has to interpret.
    if catchAll != nil || catchAllError != nil {
      DashSurfaceStack {
        if let catchAllError, catchAll == nil {
          // The catch-all lookup failed. It says so — it does not quietly
          // render as "there is no catch-all", a different answer entirely.
          DashNotice(kind: .warning, message: catchAllError)
        } else if let catchAll {
          catchAllContent(catchAll)
        }
      }
      .dashSectionBoundary()
    }
  }

  @ViewBuilder
  private func catchAllContent(_ catchAll: EmailRoutingCatchAllRule) -> some View {
    if let reason = catchAllReadOnlyReason(catchAll) {
      DashValueCard(
        title: "Catch-all",
        value: catchAllSummary(catchAll),
        caption: reason
      )
    } else {
      catchAllToggleCard(catchAll)
      if catchAll.enabled == true {
        DashMenuRow(
          title: "Delivery",
          value: catchAllDeliveryValue,
          caption: "What happens to mail sent to any other address at this domain.",
          options: deliveryOptions,
          isEnabled: featureAllowsWrites && addresses != nil,
          isLoading: catchAllUpdating
        ) { chosen in
          updateCatchAll(enabled: nil, delivery: chosen)
        }
      }
    }
  }

  @ViewBuilder
  private func catchAllToggleCard(_ rule: EmailRoutingCatchAllRule) -> some View {
    DashCard {
      Button {
        updateCatchAll(enabled: !(rule.enabled ?? false), delivery: nil)
      } label: {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Catch-all")
              .dashTextStyle(.bodySemibold)
              .foregroundStyle(DashTheme.text)
            Text("What happens to mail sent to any other address at this domain.")
              .dashTextStyle(.footnote)
              .foregroundStyle(DashTheme.subtle)
              .lineLimit(2)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          DashSwitch(isOn: rule.enabled ?? false)
            .opacity(catchAllUpdating ? 0.72 : 1)
        }
      }
      .buttonStyle(DashSurfaceButtonStyle())
      .disabled(!featureAllowsWrites || catchAllUpdating)
      .accessibilityLabel(DashL10n.string("Catch-all"))
      .accessibilityValue(rule.enabled == true ? "On" : "Off")
      .accessibilityAddTraits(.isToggle)
    }
  }

  private var catchAllDeliveryValue: String {
    guard let action = catchAll?.actions.first else { return emailRoutingDropOption }
    if action.type == "forward", let target = action.forwardTarget { return target }
    return emailRoutingDropOption
  }

  private func catchAllReadOnlyReason(_ rule: EmailRoutingCatchAllRule) -> String? {
    if rule.source == "wrangler" {
      return
        "This route is managed by a Worker's wrangler.jsonc. Changing it here would be overwritten on the next deploy."
    }
    if rule.actions.contains(where: { $0.type == "worker" }) {
      return "This route is managed by a Worker. Change it where the Worker is configured."
    }
    let supportedMatchers =
      rule.matchers.isEmpty
      || (rule.matchers.count == 1 && rule.matchers[0].type == "all")
    let supportedActions =
      rule.actions.isEmpty
      || (rule.actions.count == 1 && Self.isEditableDeliveryAction(rule.actions[0]))
    guard supportedMatchers, supportedActions else {
      return
        "This catch-all uses a configuration Dash doesn't edit yet. Change it in the Cloudflare dashboard."
    }
    return nil
  }

  private func catchAllSummary(_ rule: EmailRoutingCatchAllRule) -> String {
    guard rule.actions.count == 1, let action = rule.actions.first else {
      return DashL10n.string("Custom configuration")
    }
    switch action.type {
    case "forward":
      return action.forwardTarget ?? DashL10n.string("Custom configuration")
    case "drop":
      return DashL10n.string("Drops")
    case "worker":
      return DashL10n.string("Worker · \(action.value?.first ?? "")")
    default:
      return DashL10n.string("Custom configuration")
    }
  }

  fileprivate static func isEditableDeliveryAction(_ action: EmailRoutingRuleAction) -> Bool {
    switch action.type {
    case "drop":
      return action.value?.isEmpty != false
    case "forward":
      return action.value?.count == 1 && action.forwardTarget?.isEmpty == false
    default:
      return false
    }
  }

  /// Drop plus every **verified** address. Unverified ones are omitted: the
  /// server rejects them, and offering one would look like a working choice
  /// that silently drops mail.
  private var deliveryOptions: [String] {
    [emailRoutingDropOption] + (addresses ?? []).filter(\.isVerified).map(\.email)
  }

  // MARK: §5 Destination addresses

  /// Exactly one row, so this is a legitimate `DashListGroup` — bounded content
  /// in an eager stack, unlike Routes above.
  private var addressesSection: some View {
    DashListGroup(title: "Destination addresses") {
      // One row: `DashListGroup` supplies the horizontal inset, so the row
      // takes none of its own.
      DashListGroupLink(value: .emailAddresses) {
        DashListRow(
          title: DashL10n.string("Manage addresses"),
          subtitle: addressesSubtitle,
          icon: SolarAsset.Content.user,
          iconColor: FeatureVisualIdentity.catalogColor(for: .emailRouting)
        ) {
          if unverifiedAddressCount > 0 {
            StatusBadge(.unverified)
          }
        }
      }
    }
    .dashSectionBoundary()
  }

  private var unverifiedAddressCount: Int {
    (addresses ?? []).filter { !$0.isVerified }.count
  }

  /// Absent while the address list is unknown — a count is a claim, and a
  /// failed lookup has nothing to claim.
  private var addressesSubtitle: String? {
    guard let addresses else { return nil }
    let total = DashL10n.string("\(addresses.count) addresses")
    let unverified = unverifiedAddressCount
    guard unverified > 0 else { return total }
    return total + " · " + DashL10n.string("\(unverified) unverified")
  }

  // MARK: §6 Plus addressing

  private var subaddressingSection: some View {
    DashSurfaceStack {
      DashToggleRow(
        title: "Plus addressing",
        subtitle:
          "Deliver mail sent to user+tag@example.com through the route for user@example.com.",
        isOn: subaddressingBinding,
        isEnabled: featureAllowsWrites,
        isLoading: subaddressingUpdating)
    }
    .dashSectionBoundary()
  }

  private var subaddressingBinding: Binding<Bool> {
    Binding(
      get: { subaddressing },
      set: { enabled in
        guard featureAllowsWrites, !subaddressingUpdating else { return }
        setSubaddressing(enabled)
      })
  }

  // MARK: §7 Turn off

  private var turnOffRow: some View {
    Button {
      showsTurnOff = true
    } label: {
      HStack(spacing: 12) {
        SolarIcon(asset: SolarAsset.trash, size: 22, color: DashTheme.danger)
        Text(DashL10n.string("Turn off email routing"))
          .dashTextStyle(.bodyMedium)
          .foregroundStyle(DashTheme.danger)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        DashTheme.dangerTint,
        in: RoundedRectangle(cornerRadius: DashTheme.Radius.button, style: .continuous))
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityLabel(DashL10n.string("Turn off email routing"))
    .padding(.top, DashTheme.Spacing.section)
  }

  private var turnOffAction: DashDangerAction {
    let zoneName = settings?.name ?? zoneID
    return DashDangerAction(
      title: DashL10n.string("Turn off email routing"),
      message: DashL10n.string(
        "Removes the MX and SPF records Cloudflare added to \(zoneName). Mail sent to addresses at this domain will bounce until you point MX records at another provider. Your routes and destination addresses are kept."
      ),
      confirmTitle: DashL10n.string("Turn off")
    ) {
      try await turnOff()
    }
  }

  // MARK: Navigation

  private func openAddresses() {
    navigator?.push(.emailAddresses)
  }

  // MARK: Loading

  private func load(force: Bool = false) async {
    guard let context = model.accountRequestContext else {
      loadedContext = nil
      settings = nil
      rules = []
      catchAll = nil
      addresses = nil
      pageState.reset()
      loading = false
      return
    }
    if loadedContext != context {
      loadedContext = context
      settings = nil
      rules = []
      catchAll = nil
      addresses = nil
      analytics = nil
      analyticsFailed = false
      pageState.reset()
      loading = true
      loadMorePhase = .idle
      error = nil
      rulesError = nil
      catchAllError = nil
      enableTarget = nil
      editedRule = nil
      createsRule = false
      showsTurnOff = false
      subaddressing = false
      subaddressingUpdating = false
      catchAllUpdating = false
    }
    let key = FeatureCacheKey.emailRouting(zoneID)
    if !force, let cached: EmailRoutingSnapshot = model.featureCache.get(key) {
      apply(cached)
      loading = false
      error = nil
      await loadAddresses(force: false, context: context)
      await loadAnalytics(force: false)
      return
    }

    let client = model.client
    let zone = zoneID
    // Settings is the backbone. It is awaited on its own so a throw becomes the
    // screen's error rather than being folded into a degraded section.
    do {
      let fetched = try await client.getEmailRoutingSettings(zoneID: zone)
      guard model.isCurrentAccount(context), !Task.isCancelled else { return }
      settings = fetched
      subaddressing = fetched.supportSubaddress ?? false
      error = nil
    } catch {
      guard model.isCurrentAccount(context), !Task.isCancelled, !error.dashIsCancellation else {
        return
      }
      // A 404 lands here, not in the not-set-up state: only a 200 may offer the
      // MX rewrite as its call to action.
      self.error = error.dashActionableMessage
      loading = false
      return
    }

    guard let current = settings else {
      loading = false
      return
    }
    guard !Self.isNotSetUp(current) else {
      // Routing is off. There are no routes to show and no catch-all to read;
      // the screen renders the setup call to action and nothing else.
      rules = []
      catchAll = nil
      rulesError = nil
      catchAllError = nil
      pageState.reset()
      loading = false
      model.featureCache.set(
        key, EmailRoutingSnapshot(settings: current, rules: [], catchAll: nil))
      return
    }

    async let rulesResult = Self.fetch {
      try await client.listEmailRoutingRules(
        zoneID: zone, page: 1, perPage: Self.rulePageSize)
    }
    async let catchAllResult = Self.fetch {
      try await client.getEmailRoutingCatchAll(zoneID: zone)
    }
    async let addressesResult: Void = loadAddresses(force: force, context: context)
    let (rulesOutcome, catchAllOutcome, _) = await (
      rulesResult, catchAllResult, addressesResult
    )
    guard model.isCurrentAccount(context), !Task.isCancelled else { return }

    var fetchedRules: [EmailRoutingRule]?
    switch rulesOutcome {
    case .success(let page):
      rules = page.items
      fetchedRules = page.items
      rulesError = nil
      pageState.reset()
      pageState.absorb(
        info: page.resultInfo, received: page.items.count, loaded: page.items.count,
        pageSize: Self.rulePageSize)
    case .failure(let failure):
      guard !failure.dashIsCancellation else { return }
      rulesError = failure.dashActionableMessage
    }

    switch catchAllOutcome {
    case .success(let rule):
      catchAll = rule
      catchAllError = nil
    case .failure(let failure):
      guard !failure.dashIsCancellation else { return }
      catchAllError = failure.dashActionableMessage
    }

    // Only a complete, successful primary payload is cached. A degraded read
    // must not become the warm state a later visit trusts.
    if let fetchedRules, catchAllError == nil {
      model.featureCache.set(
        key,
        EmailRoutingSnapshot(settings: current, rules: fetchedRules, catchAll: catchAll))
    }
    await loadAnalytics(force: force)
    loading = false
  }

  private func loadAnalytics(force: Bool) async {
    let key = FeatureCacheKey.emailRoutingAnalytics(zoneID)
    if !force, let cached: EmailRoutingAnalyticsSummary = model.featureCache.get(key) {
      analytics = cached
      analyticsFailed = false
      return
    }
    do {
      let fetched = try await model.client.emailRoutingAnalytics(zoneID: zoneID, hours: 24)
      analytics = fetched.isEmpty ? nil : fetched
      analyticsFailed = false
      if !fetched.isEmpty {
        model.featureCache.set(key, fetched)
      }
    } catch {
      guard !error.dashIsCancellation else { return }
      // Hide the section; never surface analytics failure over the routes UI.
      analytics = nil
      analyticsFailed = true
    }
  }

  private func apply(_ snapshot: EmailRoutingSnapshot) {
    settings = snapshot.settings
    rules = snapshot.rules
    catchAll = snapshot.catchAll
    subaddressing = snapshot.settings.supportSubaddress ?? false
    rulesError = nil
    catchAllError = nil
    pageState.reset()
    pageState.rehydrate(loaded: snapshot.rules.count, pageSize: Self.rulePageSize)
  }

  private func loadAddresses(force: Bool, context: AccountRequestContext) async {
    guard model.isCurrentAccount(context), !Task.isCancelled else { return }
    let key = FeatureCacheKey.emailAddresses(context.accountID)
    if !force, let cached: [EmailDestinationAddress] = model.featureCache.get(key) {
      addresses = cached
      return
    }
    do {
      let fetched = try await model.client.listEmailDestinationAddresses(
        accountID: context.accountID)
      guard model.isCurrentAccount(context), !Task.isCancelled else { return }
      addresses = fetched
      model.featureCache.set(key, fetched)
    } catch {
      // Left exactly as it was: nil if it was never known (so every claim this
      // list backs stays suppressed rather than guessed), and the last good
      // answer if there was one. The dedicated screen reports the failure.
    }
  }

  private func loadMoreRules() async {
    guard let context = model.accountRequestContext, loadMorePhase == .idle else { return }
    loadMorePhase = .loading
    do {
      let page = try await model.client.listEmailRoutingRules(
        zoneID: zoneID, page: pageState.nextPage, perPage: Self.rulePageSize)
      guard model.isCurrentAccount(context), !Task.isCancelled else {
        loadMorePhase = .idle
        return
      }
      let existing = Set(rules.map(\.id))
      rules.append(contentsOf: page.items.filter { !existing.contains($0.id) })
      pageState.absorb(
        info: page.resultInfo, received: page.items.count, loaded: rules.count,
        pageSize: Self.rulePageSize)
      cacheSnapshot()
      loadMorePhase = .succeeded
    } catch {
      loadMorePhase = .idle
      guard model.isCurrentAccount(context), !Task.isCancelled, !error.dashIsCancellation else {
        return
      }
      model.toasts.error(error.dashActionableMessage)
    }
  }

  private static func fetch<Value: Sendable>(_ operation: () async throws -> Value) async
    -> Result<Value, Error>
  {
    do { return .success(try await operation()) } catch { return .failure(error) }
  }

  private func cacheSnapshot() {
    guard let settings else { return }
    model.featureCache.set(
      FeatureCacheKey.emailRouting(zoneID),
      EmailRoutingSnapshot(settings: settings, rules: rules, catchAll: catchAll))
  }

  // MARK: Mutations

  /// Optimistic: the switch flips first, the row disables while the PUT is in
  /// flight, and a failure puts the previous value back and toasts.
  ///
  /// The PUT is a full replace, so every field the editor does not expose is
  /// round-tripped from the fetched rule — `name`, `matchers`, and the action
  /// the user did not touch.
  private func updateCatchAll(enabled: Bool?, delivery: String?) {
    guard let context = model.accountRequestContext, let current = catchAll else { return }
    guard catchAllReadOnlyReason(current) == nil else { return }
    let previous = current
    let nextActions: [EmailRoutingRuleAction]
    if let delivery {
      nextActions =
        delivery == emailRoutingDropOption
        ? [EmailRoutingRuleAction(type: "drop")]
        : [EmailRoutingRuleAction(type: "forward", value: [delivery])]
    } else {
      // This is a bare Enabled flip. PUT replaces the whole rule, so even an
      // empty action list must be carried back byte-for-shape instead of being
      // normalized to a Dash-authored "drop".
      nextActions = current.actions
    }
    let nextEnabled = enabled ?? current.enabled ?? false
    catchAll = EmailRoutingCatchAllRule(
      id: current.id, tag: current.tag, name: current.name, enabled: nextEnabled,
      source: current.source, matchers: current.matchers, actions: nextActions)
    catchAllUpdating = true
    Task {
      do {
        let updated = try await model.client.updateEmailRoutingCatchAll(
          zoneID: zoneID,
          input: EmailRoutingCatchAllInput(
            matchers: current.matchers,
            actions: nextActions,
            enabled: nextEnabled,
            name: current.name))
        guard model.isCurrentAccount(context), !Task.isCancelled else { return }
        catchAll = updated
        cacheSnapshot()
        catchAllUpdating = false
      } catch {
        guard model.isCurrentAccount(context), !Task.isCancelled, !error.dashIsCancellation else {
          return
        }
        catchAll = previous
        catchAllUpdating = false
        model.toasts.error(error.dashActionableMessage)
      }
    }
  }

  private func setSubaddressing(_ enabled: Bool) {
    guard let context = model.accountRequestContext else { return }
    let previous = subaddressing
    subaddressing = enabled
    subaddressingUpdating = true
    Task {
      do {
        let updated = try await model.client.updateEmailRoutingSubaddressing(
          zoneID: zoneID, enabled: enabled)
        guard model.isCurrentAccount(context), !Task.isCancelled else { return }
        settings = updated
        subaddressing = updated.supportSubaddress ?? enabled
        cacheSnapshot()
        subaddressingUpdating = false
      } catch {
        guard model.isCurrentAccount(context), !Task.isCancelled, !error.dashIsCancellation else {
          return
        }
        subaddressing = previous
        subaddressingUpdating = false
        model.toasts.error(error.dashActionableMessage)
      }
    }
  }

  private func turnOff() async throws {
    guard let context = model.accountRequestContext else { return }
    try await model.client.disableEmailRouting(zoneID: zoneID)
    guard model.isCurrentAccount(context), !Task.isCancelled else { return }
    model.featureCache.remove(FeatureCacheKey.emailRouting(zoneID))
    model.featureCache.remove(FeatureCacheKey.emailRoutingDNS(zoneID))
    // The zone's apex MX really did change underneath the DNS screen.
    model.featureCache.remove(FeatureCacheKey.dnsRecords(zoneID))
    await load(force: true)
  }
}

/// Identifies which flavour of the enable tray is open. Carrying the zone name
/// (rather than reading it back out of `@State` inside the tray builder) means
/// the tray can never open without the apex name its conflict check compares
/// against.
private struct EmailRoutingEnableTarget: Identifiable, Equatable {
  let zoneName: String
  let title: String
  let confirmTitle: String
  var id: String { title }
}

// MARK: - Status mapping

/// Cloudflare's `status` string → a `StatusToken`, in one place.
///
/// An unrecognised status is `.unknown`, never `.ready`: the screen must not
/// promise a working mail path for a state it has never seen.
enum EmailRoutingStatusMapping {
  static func token(for settings: EmailRoutingSettings) -> StatusToken {
    switch settings.routingStatus {
    case .ready: .ready
    case .misconfigured, .misconfiguredLocked: .misconfigured
    case .unlocked: .unlocked
    case .unconfigured: .disabled
    case nil: .unknown
    }
  }

  /// Only the states Cloudflare itself calls misconfigured offer the repair
  /// action. `unknown` does not — Dash does not know what is wrong, and the
  /// repair rewrites apex MX records.
  static func needsDNSRepair(_ settings: EmailRoutingSettings) -> Bool {
    switch settings.routingStatus {
    case .misconfigured, .misconfiguredLocked: true
    default: false
    }
  }
}

// MARK: - Enable tray

/// Preview + hold-to-confirm for the one destructive control in this feature:
/// letting Cloudflare write its DNS plan onto the zone apex, replacing whatever
/// MX records are there now.
///
/// Cloudflare reports only what it considers *missing*; it never reports a
/// conflict. So Dash does the conflict detection itself, from the zone's own
/// apex MX and TXT records, and names the hosts that are about to be displaced.
///
/// **The three fetches gate the button.** The DNS plan, the MX sweep and the
/// TXT sweep must all have succeeded before the confirm control is enabled — a
/// hold-to-confirm without the preview would be a confirmation of nothing.
/// Any of them throwing puts the section in `.failed` with a Try again, and the
/// button stays disabled. "Unable to proceed" is an acceptable state here;
/// "unwarned" is not.
struct EmailRoutingEnableTray: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let zoneID: String
  let zoneName: String
  var confirmTitle: String = "Turn on email routing"
  var onEnabled: () async -> Void

  @State private var plan: EmailRoutingDNSPlan?
  @State private var conflicts = EmailRoutingDNSConflicts()
  @State private var dnsPhase: DashSectionPhase = .loading
  @State private var actionPhase: DashActionPhase = .idle
  @State private var errorMessage: String?

  private var planRows: [EmailRoutingPlanRow] {
    EmailRoutingPlanRow.rows(for: plan)
  }

  /// Successful *and* non-empty. An empty plan renders "records Cloudflare will
  /// add: (nothing)" beside an armed rewrite, and the conflict check compares
  /// against the plan, so an empty one flags either nothing or everything.
  private var canConfirm: Bool {
    dnsPhase == .content && !planRows.isEmpty && !actionPhase.isActive
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DashTheme.Spacing.itemGap) {
      if !conflicts.mxHosts.isEmpty {
        DashNotice(
          kind: .warning,
          message: DashL10n.string(
            "This domain already delivers mail through \(conflicts.mxHostList). Turning on email routing replaces those MX records — mail stops reaching that provider immediately."
          ))
      }
      if let spf = conflicts.spfRecord {
        DashNotice(
          kind: .warning,
          message: DashL10n.string(
            "An SPF record already exists on this domain and will be replaced: \(spf)"))
      }

      DashInfoGroup(
        title: "Records Cloudflare will add",
        phase: dnsPhase,
        placeholderRows: 4,
        retry: { Task { await loadPlan() } }
      ) {
        // Bounded: a DNS plan is a handful of apex records, never a list.
        ForEach(planRows) { row in
          DashInfoRow(row.type, value: row.value, mono: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.accessibilityLabel)
        }
      }

      if dnsPhase == .content, planRows.isEmpty {
        DashNotice(
          kind: .warning,
          message:
            "Cloudflare didn’t return the DNS records for this domain. Turn on email routing from the Cloudflare dashboard."
        )
      }
      if let errorMessage {
        DashNotice(kind: .error, message: errorMessage)
      }

      // Bottom-most control, per the tray rule.
      DashActionButton(
        title: confirmTitle,
        phase: actionPhase,
        holdToConfirm: true,
        onSuccessPresentationCompleted: completeEnablePresentation
      ) {
        Task { await enable() }
      }
      .disabled(!canConfirm)
      .opacity(canConfirm ? 1 : 0.45)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: model.accountRequestContext) { await loadPlan() }
  }

  private func loadPlan() async {
    guard let context = model.accountRequestContext else { return }
    plan = nil
    conflicts = EmailRoutingDNSConflicts()
    dnsPhase = .loading
    actionPhase = .idle
    errorMessage = nil
    let client = model.client
    let zone = zoneID
    do {
      // All three, or none. A degraded plan would arm a destructive confirm on
      // a preview that is missing exactly the part that makes it a warning.
      async let planFetch = client.getEmailRoutingDNSPlan(zoneID: zone)
      async let mxFetch = client.listDNSRecords(zoneID: zone, perPage: 100, type: "MX")
      async let txtFetch = client.listDNSRecords(zoneID: zone, perPage: 100, type: "TXT")
      let (fetchedPlan, mx, txt) = try await (planFetch, mxFetch, txtFetch)
      guard model.isCurrentAccount(context), !Task.isCancelled else { return }
      plan = fetchedPlan
      conflicts = EmailRoutingDNSConflicts.detect(
        plan: fetchedPlan, apex: zoneName, mx: mx.items, txt: txt.items)
      dnsPhase = .content
      model.featureCache.set(FeatureCacheKey.emailRoutingDNS(zoneID), fetchedPlan)
    } catch {
      guard model.isCurrentAccount(context), !Task.isCancelled, !error.dashIsCancellation else {
        return
      }
      plan = nil
      conflicts = EmailRoutingDNSConflicts()
      dnsPhase = .failed(error.dashActionableMessage)
    }
  }

  private func enable() async {
    guard canConfirm, let context = model.accountRequestContext else { return }
    actionPhase = .loading
    errorMessage = nil
    do {
      try await model.client.enableEmailRouting(zoneID: zoneID)
      guard model.isCurrentAccount(context), !Task.isCancelled else {
        actionPhase = .idle
        return
      }
      model.featureCache.remove(FeatureCacheKey.emailRouting(zoneID))
      model.featureCache.remove(FeatureCacheKey.emailRoutingDNS(zoneID))
      model.featureCache.remove(FeatureCacheKey.dnsRecords(zoneID))
      DashDelight.celebrateSuccess()
      await onEnabled()
      guard model.isCurrentAccount(context), !Task.isCancelled else {
        actionPhase = .idle
        return
      }
      actionPhase = .succeeded
    } catch {
      actionPhase = .idle
      guard model.isCurrentAccount(context), !Task.isCancelled, !error.dashIsCancellation else {
        return
      }
      errorMessage = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func completeEnablePresentation() {
    guard actionPhase == .succeeded else {
      actionPhase = .idle
      return
    }
    actionPhase = .idle
    dismiss()
  }
}

/// One row of the DNS plan preview.
struct EmailRoutingPlanRow: Identifiable {
  let id: String
  let type: String
  let name: String
  let content: String
  let priority: Int?
  let ttl: Double?

  /// What the trailing slot shows: priority (MX) then the record content.
  var value: String {
    guard let priority else { return content }
    return "\(priority) \(content)"
  }

  /// VoiceOver must hear what is being written to the zone, not a run of
  /// unlabelled monospace.
  var accessibilityLabel: String {
    var parts = [type, name, content]
    if let priority { parts.append(DashL10n.string("Priority \(priority)")) }
    parts.append(ttlLabel)
    return parts.joined(separator: ", ")
  }

  var ttlLabel: String {
    guard let ttl, ttl != 1 else { return DashL10n.string("Automatic") }
    return String(Int(ttl))
  }

  /// The plan's own records first, then anything Cloudflare reports missing but
  /// did not repeat in `record`. Both halves are written to the zone.
  static func rows(for plan: EmailRoutingDNSPlan?) -> [EmailRoutingPlanRow] {
    guard let plan else { return [] }
    var seen: Set<String> = []
    return (plan.records + plan.missing).compactMap { record in
      guard let type = record.type, let content = record.content else { return nil }
      let name = record.name ?? ""
      let id = "\(type)|\(name)|\(content)|\(record.priority.map(String.init) ?? "")"
      guard seen.insert(id).inserted else { return nil }
      return EmailRoutingPlanRow(
        id: id, type: type, name: name, content: content, priority: record.priority,
        ttl: record.ttl)
    }
  }
}

/// What the zone already has that the plan is about to overwrite.
///
/// Entirely client-side. `GET /email/routing/dns` reports only `missing`; it
/// never says "you already deliver mail somewhere else", which is the one thing
/// the user needs to know before confirming.
struct EmailRoutingDNSConflicts: Equatable {
  var mxHosts: [String] = []
  var spfRecord: String?

  var isEmpty: Bool { mxHosts.isEmpty && spfRecord == nil }

  var mxHostList: String {
    mxHosts.joined(separator: ", ")
  }

  static func detect(
    plan: EmailRoutingDNSPlan, apex: String, mx: [DNSRecord], txt: [DNSRecord]
  ) -> EmailRoutingDNSConflicts {
    let apexName = apex.lowercased()
    let planned = plan.records + plan.missing
    let plannedMX = Set(
      planned
        .filter { $0.type?.uppercased() == "MX" }
        .compactMap { $0.content?.lowercased() })
    let plannedSPF =
      planned
      .filter { $0.type?.uppercased() == "TXT" }
      .compactMap { $0.content?.lowercased() }
      .first { $0.contains("v=spf1") }

    var conflicts = EmailRoutingDNSConflicts()
    var seenHosts: Set<String> = []
    for record in mx where record.name.lowercased() == apexName {
      let host = record.content.lowercased()
      guard !plannedMX.contains(host), seenHosts.insert(host).inserted else { continue }
      conflicts.mxHosts.append(record.content)
    }
    for record in txt where record.name.lowercased() == apexName {
      let value = record.content.lowercased()
      guard value.hasPrefix("\"v=spf1") || value.hasPrefix("v=spf1") else { continue }
      guard value != plannedSPF else { continue }
      conflicts.spfRecord = record.content
      break
    }
    return conflicts
  }
}

// MARK: - DNS screen interaction

/// What the DNS records screen needs to know about Email Routing, so the two
/// screens cannot disagree about which records Cloudflare owns.
///
/// Two rules that look contradictory side by side and are both correct — the
/// difference is what each one costs when the plan fetch fails:
///
/// - **The badge is decoration.** A record is managed iff it matches a plan
///   record on (type, normalized name, content). A failed plan fetch renders no
///   badge at all, silently, because a zone with no Email Routing is the common
///   case and an error card on the DNS screen would be permanent furniture —
///   the same call `WorkerBuildsSection` makes. This is deliberate, and it sits
///   directly next to the opposite rule.
/// - **The gate is not decoration.** It is derived from what the DNS screen
///   already knows — routing is `enabled` *and* the record is an apex MX or a
///   `v=spf1` TXT — never from the plan fetch. Deriving the gate from the plan
///   would let one transient throw silently re-open `DNSRecordEditor` over
///   records Cloudflare has locked, where Save fails server-side with an opaque
///   message. A failed plan fetch costs a label, not the guard.
struct EmailRoutingDNSGuard: Equatable, Sendable {
  /// `GET /zones/{id}/email/routing` said `enabled == true`. False whenever the
  /// answer is unknown: a locked-record gate must be a positive claim.
  var isEnabled = false
  /// The zone apex, lowercased. Email Routing only ever writes apex records.
  var apex = ""
  /// `nil` when the plan is unknown — badge suppressed, gate unaffected.
  var plan: EmailRoutingDNSPlan?

  /// Cloudflare rejects edits and deletes on the records Email Routing owns.
  func isLocked(_ record: DNSRecord) -> Bool {
    guard isEnabled, !apex.isEmpty, record.name.lowercased() == apex else { return false }
    switch record.type.uppercased() {
    case "MX": return true
    case "TXT":
      let value = record.content.lowercased()
      return value.hasPrefix("v=spf1") || value.hasPrefix("\"v=spf1")
    default: return false
    }
  }

  func isManaged(_ record: DNSRecord) -> Bool {
    guard let plan else { return false }
    let type = record.type.uppercased()
    let name = record.name.lowercased()
    let content = record.content.lowercased()
    return (plan.records + plan.missing).contains { planned in
      planned.type?.uppercased() == type
        && (planned.name?.lowercased() ?? apex) == name
        && planned.content?.lowercased() == content
    }
  }
}

// MARK: - Rule editor

/// Create / edit one routing rule.
///
/// Two rules the server will not enforce for us:
///
/// 1. **`PUT` is a full replace.** Every save round-trips the fetched
///    `priority` verbatim. Dash deliberately does not expose ordering, so a
///    rule the user created in the dashboard with priority 5 must come back
///    with priority 5 — dropping it silently reorders their mail.
/// 2. **Rules Dash does not own open read-only.** A `source == "wrangler"`
///    rule is declared in a Worker's `wrangler.jsonc` and an edit here would be
///    undone on the next deploy; a `worker`-typed action would be detached from
///    its Worker by being overwritten with a forward.
struct EmailRoutingRuleEditor: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.dashTrayDismiss) private var dismiss
  let zoneID: String
  let zoneName: String
  let rule: EmailRoutingRule?
  let deliveryOptions: [String]
  var onOpenAddresses: () -> Void
  var onSaved: () async -> Void

  @State private var localPart = ""
  @State private var delivery = emailRoutingDropOption
  @State private var name = ""
  @State private var enabled = true
  @State private var actionPhase: DashActionPhase = .idle
  @State private var errorMessage: String?
  @State private var deleteError: String?
  @State private var loaded = false

  private var isReadOnly: Bool {
    guard let rule else { return false }
    return !featureAllowsWrites || rule.isWranglerManaged || !hasEditableShape(rule)
  }

  private func hasEditableShape(_ rule: EmailRoutingRule) -> Bool {
    guard rule.matchers.count == 1, let matcher = rule.matchers.first,
      matcher.type == "literal", matcher.field == "to", let address = matcher.value,
      rule.actions.count == 1, let action = rule.actions.first
    else {
      return false
    }
    let addressParts = address.split(separator: "@", omittingEmptySubsequences: false)
    guard addressParts.count == 2, !addressParts[0].isEmpty, !addressParts[0].contains("*"),
      String(addressParts[1]).caseInsensitiveCompare(zoneName) == .orderedSame
    else {
      return false
    }
    return EmailRoutingView.isEditableDeliveryAction(action)
  }

  private var verifiedOptions: [String] {
    deliveryOptions.filter { $0 != emailRoutingDropOption }
  }

  private var composedAddress: String {
    let local = localPart.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !local.isEmpty else { return "" }
    return "\(local)@\(zoneName)"
  }

  private var usesWildcard: Bool { localPart.contains("*") }

  private var canSave: Bool {
    featureAllowsWrites && !composedAddress.isEmpty && !usesWildcard && !actionPhase.isActive
  }

  var body: some View {
    Group {
      if let rule, isReadOnly {
        readOnlyBody(rule)
      } else {
        editorBody
      }
    }
    .onAppear { loadIfNeeded() }
  }

  // MARK: Read-only

  @ViewBuilder
  private func readOnlyBody(_ rule: EmailRoutingRule) -> some View {
    DashDetailTray(fields: readOnlyFields(rule)) {
      DashNotice(
        kind: .warning,
        message: readOnlyReason(rule))
    }
  }

  private func readOnlyReason(_ rule: EmailRoutingRule) -> String {
    if !featureAllowsWrites {
      return "Read-only — grant Email Routing write access to change routes."
    }
    if rule.isWranglerManaged {
      return
        "This route is managed by a Worker's wrangler.jsonc. Changing it here would be overwritten on the next deploy."
    }
    if rule.actions.contains(where: { $0.type == "worker" }) {
      return "This route is managed by a Worker. Change it where the Worker is configured."
    }
    return
      "This route uses a configuration Dash doesn't edit yet. Change it in the Cloudflare dashboard."
  }

  private func readOnlyFields(_ rule: EmailRoutingRule) -> [DashDetailField] {
    var fields: [DashDetailField] = []
    if let address = rule.matchedAddress {
      fields.append(DashDetailField(label: "Address", value: address, mono: true))
    }
    if let name = rule.name, !name.isEmpty {
      fields.append(DashDetailField(label: "Name", value: name))
    }
    if let action = rule.actions.first {
      let value: String
      switch action.type {
      case "forward": value = action.forwardTarget ?? action.type
      case "drop": value = DashL10n.string("Drops")
      case "worker": value = DashL10n.string("Worker · \(action.value?.first ?? "")")
      default: value = action.type
      }
      fields.append(DashDetailField(label: "Delivery", value: value))
    }
    fields.append(
      DashDetailField(
        label: "Status",
        value: rule.enabled == false
          ? DashL10n.string("Disabled") : DashL10n.string("Enabled")))
    return fields
  }

  // MARK: Editor

  @ViewBuilder
  private var editorBody: some View {
    DashFormSheet(
      saveTitle: "Save",
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completeActionPresentation,
      canSave: canSave,
      deleteMessage: rule != nil && featureAllowsWrites
        ? DashL10n.string(
          "Deletes this route. Mail sent to \(composedAddress) stops being forwarded.")
        : nil,
      deleteError: deleteError,
      onDelete: rule != nil && featureAllowsWrites ? { Task { await delete() } } : nil,
      deletionPresentation: .confirmThenExecute,
      onSave: { Task { await save() } },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          DashFormField(label: "Address", text: $localPart, keyboard: .emailAddress)
          Text(verbatim: "@\(zoneName)")
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)

          if usesWildcard {
            DashNotice(
              kind: .warning,
              message: "Use the catch-all control below the routes list for every other address.")
          }

          if verifiedOptions.isEmpty {
            DashNotice(
              kind: .info,
              message:
                "A route can only forward to a verified destination address. Add one, then open the confirmation email Cloudflare sends."
            )
            DashPillButton(title: "Add a destination address") {
              dismiss()
              onOpenAddresses()
            }
          } else {
            DashFormMenuField(
              label: "Delivery", selection: $delivery, options: deliveryOptions)
          }

          DashFormField(label: "Name", text: $name)
          DashToggleRow(title: "Enabled", isOn: $enabled, isEnabled: featureAllowsWrites)

          if let errorMessage {
            DashNotice(kind: .error, message: errorMessage)
          }
        }
      }
    )
  }

  // MARK: State

  private func loadIfNeeded() {
    guard !loaded else { return }
    loaded = true
    guard let rule else { return }
    if let address = rule.matchedAddress {
      localPart = String(address.split(separator: "@").first ?? "")
    }
    if let action = rule.actions.first, action.type == "forward",
      let target = action.forwardTarget
    {
      delivery = target
    } else {
      delivery = emailRoutingDropOption
    }
    name = rule.name ?? ""
    enabled = rule.enabled ?? true
  }

  private func save() async {
    guard canSave, let context = model.accountRequestContext else { return }
    let address = composedAddress
    let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let input = EmailRoutingRuleInput(
      matchers: [EmailRoutingRuleMatcher(type: "literal", field: "to", value: address)],
      actions: delivery == emailRoutingDropOption
        ? [EmailRoutingRuleAction(type: "drop")]
        : [EmailRoutingRuleAction(type: "forward", value: [delivery])],
      enabled: enabled,
      name: resolvedName.isEmpty ? address : resolvedName,
      // Never edited, always carried through: `PUT` replaces the whole rule.
      priority: rule?.priority)
    actionPhase = .loading
    errorMessage = nil
    do {
      if let rule {
        _ = try await model.client.updateEmailRoutingRule(
          zoneID: zoneID, ruleID: rule.id, input: input)
      } else {
        _ = try await model.client.createEmailRoutingRule(zoneID: zoneID, input: input)
      }
      guard model.isCurrentAccount(context), !Task.isCancelled else {
        actionPhase = .idle
        return
      }
      model.featureCache.remove(FeatureCacheKey.emailRouting(zoneID))
      model.toasts.success(DashL10n.string("Saved successfully."))
      await onSaved()
      guard model.isCurrentAccount(context), !Task.isCancelled else {
        actionPhase = .idle
        return
      }
      actionPhase = .succeeded
    } catch {
      actionPhase = .idle
      guard model.isCurrentAccount(context), !Task.isCancelled, !error.dashIsCancellation else {
        return
      }
      errorMessage = error.dashActionableMessage
    }
  }

  private func delete() async {
    guard let rule, let context = model.accountRequestContext else { return }
    actionPhase = .loading
    deleteError = nil
    do {
      try await model.client.deleteEmailRoutingRule(zoneID: zoneID, ruleID: rule.id)
      guard model.isCurrentAccount(context), !Task.isCancelled else {
        actionPhase = .idle
        return
      }
      model.featureCache.remove(FeatureCacheKey.emailRouting(zoneID))
      model.toasts.success(DashL10n.string("Deleted successfully."))
      await onSaved()
      guard model.isCurrentAccount(context), !Task.isCancelled else {
        actionPhase = .idle
        return
      }
      actionPhase = .succeeded
    } catch {
      actionPhase = .idle
      guard model.isCurrentAccount(context), !Task.isCancelled, !error.dashIsCancellation else {
        return
      }
      deleteError = error.dashActionableMessage
    }
  }

  private func completeActionPresentation() {
    guard actionPhase == .succeeded else {
      actionPhase = .idle
      return
    }
    actionPhase = .idle
    dismiss()
  }
}
