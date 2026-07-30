import CloudflareAPI
import SwiftUI
import UIKit

// Cloudflare Tunnel (Zero Trust), read-only.
//
// Two rules on these screens look contradictory side by side, and both are
// correct — so they are written down together:
//
//   * The tunnel, its connectors, and a remotely-managed tunnel's configuration
//     are the primary payload. Any failure there — including 403/404 — uses the
//     standard screen error.
//   * The private-routes section is secondary. Empty and 403/404 both drop that
//     section: a public-hostname-only tunnel has no routes, and Zero Trust
//     private networking may not be provisioned on the account.
//   * Every other routes failure — 5xx, timeout, decode, offline — keeps its
//     section and veils a Try again over the placeholders
//     (`DashSectionPhase.failed`).
//
// Empty and forbidden collapse into "there is nothing here". Broken never does.
// (`WorkerBuildsSection` currently swallows all three into one `unavailable`
// flag, so a transient 500 makes its card vanish. That is a latent bug in the
// precedent, not a pattern to copy here.)

private enum TunnelExternalURL {
  static let guide = URL(
    string: "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/")!
}

// MARK: - List

struct TunnelsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @State private var tunnels: [CloudflareTunnel] = []
  @State private var error: String?
  @State private var loading = true
  @State private var loadedContext: AccountRequestContext?

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !tunnels.isEmpty,
      retry: { Task { await load(force: true) } }
    ) {
      if tunnels.isEmpty {
        // The whole first-run explanation of what a tunnel *is* lives here and
        // nowhere else — no explainer card on the detail screen, none in
        // Settings, none in Watchtower.
        DashEmptyState(
          icon: SolarAsset.Content.routing,
          title: DashL10n.string("No tunnels yet"),
          message: DashL10n.string(
            "A Cloudflare Tunnel connects a machine on your own network to Cloudflare without opening a port. Create one with cloudflared or the Zero Trust dashboard — Dash shows its health, hostnames, and routes here."
          ),
          actionTitle: DashL10n.string("Open Tunnel docs"),
          action: { openURL(TunnelExternalURL.guide) }
        )
      } else {
        dashListCard {
          dashListCardRows(items: tunnels) { tunnel in
            DashListGroupLink(value: .tunnel(tunnel.id)) {
              DashListRow(
                title: tunnelDisplayName(tunnel),
                subtitle: tunnelListSubtitle(tunnel),
                icon: SolarAsset.Content.routing
              ) {
                StatusBadge(StatusToken(tunnelStatus: tunnel.statusRaw))
              }
              .accessibilityLabel(tunnelRowAccessibilityLabel(tunnel))
            }
            .accessibilityIdentifier("tunnel-\(tunnel.id)")
          }
        }
      }
    }
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) { await load() }
    .onAppear { reloadIfInvalidated() }
  }

  /// The cache drops under this list on memory pressure while it stays alive
  /// below a child screen; refresh on return when the cache went cold.
  private func reloadIfInvalidated() {
    guard
      let context = model.accountRequestContext,
      loadedContext == context,
      !tunnels.isEmpty
    else { return }
    let cached: [CloudflareTunnel]? = model.featureCache.get(
      FeatureCacheKey.tunnels(context.accountID))
    if cached == nil { Task { await load(force: true) } }
  }

  private func load(force: Bool = false) async {
    guard let context = model.accountRequestContext else {
      loadedContext = nil
      tunnels = []
      error = nil
      loading = false
      return
    }
    if loadedContext != context {
      loadedContext = context
      tunnels = []
      error = nil
      loading = true
    }
    let accountID = context.accountID
    let key = FeatureCacheKey.tunnels(accountID)
    guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
    if !force, let cached: [CloudflareTunnel] = model.featureCache.get(key) {
      tunnels = cached
      loading = false
      error = nil
      return
    }
    if tunnels.isEmpty { loading = true }
    error = nil
    do {
      let fetched = try await model.client.listTunnels(accountID: accountID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      let visible = TunnelListRules.visible(fetched)
      tunnels = visible
      model.featureCache.set(key, visible)
    } catch {
      guard
        !Task.isCancelled,
        model.isCurrentAccount(context),
        !error.dashIsCancellation
      else { return }
      // Zero Trust is not turned on for most Cloudflare accounts, and that
      // answers 403/404 right here. The honest screen for it is the first-run
      // empty state above — not a red "grant access" banner for a scope the
      // user already granted.
      if error.dashIsResourceAbsent {
        tunnels = []
      } else {
        self.error = error.dashActionableMessage
      }
    }
    guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
    loading = false
  }
}

enum TunnelListRules {
  /// `GET /cfd_tunnel` also answers for Magic WAN objects (`magic`, `ip_sec`,
  /// `gre`, `cni`) and WARP Connectors, none of which Dash models — their
  /// connectors and ingress rules would not mean what this screen says they
  /// mean, so they are dropped rather than mislabelled.
  static let cloudflaredType = "cfd_tunnel"

  /// Only a positive `cfd_tunnel` claim belongs in this product. An absent or
  /// unknown type is not silently reinterpreted as a cloudflared tunnel.
  static func visible(_ tunnels: [CloudflareTunnel]) -> [CloudflareTunnel] {
    tunnels.filter {
      $0.deletedAt == nil && $0.tunTypeRaw == cloudflaredType
    }
  }
}

// MARK: - Detail

struct TunnelDetailView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  let tunnelID: String

  @State private var tunnel: CloudflareTunnel?
  @State private var connectors: [TunnelConnector] = []
  @State private var configuration: TunnelConfiguration?
  @State private var error: String?
  @State private var loading = true
  @State private var loadedContext: AccountRequestContext?
  /// False until the primary payload settles once, so a warm refresh never
  /// drops back to the cold skeleton and a section never pops in late.
  @State private var hasPresentedContent = false

  @State private var routes: [TunnelRoute] = []
  /// Starts cold, not settled: the routes lookup always follows the primary
  /// load, so the section paints placeholders from the first frame instead of
  /// shoving the screen down when the answer arrives.
  @State private var routesPhase: DashSectionPhase = .loading
  @State private var virtualNetworks: [TunnelVirtualNetwork] = []
  /// Hostnames Access is known to cover. Empty is the honest default: the badge
  /// is a **positive claim only**, so an absent, forbidden or failed Access
  /// lookup simply shows no badge. Dash cannot see Gateway, WAF, mTLS or
  /// origin-side auth, so it never asserts the negative.
  @State private var accessHosts: Set<String> = []
  @State private var selectedHostname: TunnelHostnameRow?

  /// Both `DashListGroup` and `DashInfoGroup` own eager stacks, so every list on
  /// this screen is bounded by construction. A Zero Trust account can advertise
  /// hundreds of routes.
  private static let sectionRowCap = 20

  /// Tunnel already on-device (list push, or a cached detail entry), so the
  /// header never flashes a placeholder on a warm revisit.
  private var displayedTunnel: CloudflareTunnel? { tunnel ?? cachedTunnel }

  private var cachedTunnel: CloudflareTunnel? {
    guard let accountID = model.activeAccountID else { return nil }
    if let entry: CloudflareTunnel = model.featureCache.get(
      FeatureCacheKey.tunnel(accountID: accountID, tunnelID: tunnelID))
    {
      return entry
    }
    let list: [CloudflareTunnel]? = model.featureCache.get(FeatureCacheKey.tunnels(accountID))
    return list?.first { $0.id == tunnelID }
  }

  private var headerTitle: String {
    let name = displayedTunnel?.name ?? ""
    return name.isEmpty ? DashL10n.string("Tunnel") : name
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: hasPresentedContent,
      retry: { Task { await load(force: true) } },
      skeleton: { tunnelDetailSkeleton }
    ) {
      if let tunnel = displayedTunnel {
        tunnelGroup(tunnel)
        connectorsGroup()
        ingressSection()
        privateNetworksGroup()
      }
    }
    .detailHeader(icon: .solar(SolarAsset.Content.routing), title: headerTitle)
    .task(id: model.accountRequestContext) { await load() }
    .refreshable { await load(force: true) }
    .dashTray(
      item: $selectedHostname,
      title: { $0.trayTitle },
      content: { row in hostnameTray(row) }
    )
  }

  // MARK: Section 1 — Tunnel

  /// The Tunnel info group is the screen's first paint; connectors and ingress
  /// follow once the payload arrives.
  private var tunnelDetailSkeleton: some View {
    DashInfoGroup(title: "Tunnel", phase: .loading, placeholderRows: 5) {
      EmptyView()
    }
  }

  @ViewBuilder private func tunnelGroup(_ tunnel: CloudflareTunnel) -> some View {
    let health = tunnel.health
    DashInfoGroup(title: "Tunnel", placeholderRows: 5) {
      DashInfoRow("Status") {
        StatusBadge(StatusToken(tunnelStatus: tunnel.statusRaw))
      }
      DashInfoRow("Connectors", value: connectors.count.formatted())
      // Connected since **or** Disconnected, never both: a tunnel that is
      // serving traffic has no interesting disconnect stamp, and one that is
      // down has no honest "connected since".
      if health == .healthy || health == .degraded {
        if let since = tunnel.connsActiveAt.flatMap(ExpiryReminders.date(fromISO8601:)) {
          DashInfoRow("Connected since", value: DashDateFormatting.dateAndTime(since))
        }
      } else if let last = tunnel.connsInactiveAt.flatMap(ExpiryReminders.date(fromISO8601:)) {
        DashInfoRow("Disconnected", value: DashDateFormatting.dateAndTime(last))
      }
      if let created = tunnel.createdAt.flatMap(ExpiryReminders.date(fromISO8601:)) {
        DashInfoRow("Created", value: DashDateFormatting.dateAndTime(created))
      }
      tunnelIDRow
    }
  }

  /// A row, so it is a surface and must not shrink on press. VoiceOver gets an
  /// explicit label plus a named action — without them the element reads as a
  /// bare 36-character UUID with no way to know it is copyable.
  private var tunnelIDRow: some View {
    Button(action: copyTunnelID) {
      DashInfoRow("Tunnel ID", value: tunnelID, mono: true)
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityLabel(DashL10n.string("Tunnel ID, \(tunnelID)"))
    .accessibilityAction(named: DashL10n.string("Copy tunnel ID")) { copyTunnelID() }
  }

  private func copyTunnelID() {
    UIPasteboard.general.string = tunnelID
    model.toasts.success(DashL10n.string("Tunnel ID copied."))
  }

  // MARK: Section 2 — Connectors

  @ViewBuilder private func connectorsGroup() -> some View {
    if !connectors.isEmpty {
      let shown = Array(connectors.prefix(Self.sectionRowCap))
      DashListGroup(title: "Connectors") {
        dashListCardRows(items: shown, inset: false) { connector in
          DashListRow(
            title: connectorTitle(connector),
            subtitle: connectorSubtitle(connector),
            icon: SolarAsset.Content.cloud,
            trailing: tunnelColoSummary(connector.conns ?? []),
            showsChevron: false
          )
          .accessibilityElement(children: .combine)
          .accessibilityLabel(connectorAccessibilityLabel(connector))
        }
        if connectors.count > shown.count {
          overflowRow(shown: shown.count, total: connectors.count)
        }
      }
      .dashSectionBoundary()
    }
  }

  // MARK: Sections 3a / 3b — ingress

  /// The make-or-break distinction on this screen. A tunnel configured by a
  /// `config.yml` on the origin machine — roughly half of all real tunnels —
  /// answers `GET /configurations` with `{"source":"local","config":null}`.
  /// Rendering that as an empty "Public hostnames" list reads as a broken
  /// screen; saying where the rules actually live reads as an honest one.
  @ViewBuilder private func ingressSection() -> some View {
    if isRemotelyManaged {
      publicHostnamesGroup()
    } else if isLocallyManaged {
      locallyManagedGroup()
    }
  }

  /// Cloudflare states the answer twice — on the tunnel object (`config_src` /
  /// `remote_config`) and on the configuration document (`source`) — and both
  /// have to agree before Dash renders hostnames.
  private var isRemotelyManaged: Bool {
    guard let tunnel = displayedTunnel, tunnel.configSource == .cloudflare else { return false }
    guard let configuration else { return false }
    return configuration.configSource == .cloudflare && configuration.config != nil
  }

  /// Belt and braces: a tunnel the object already calls local, **and** one the
  /// object calls remote whose document then answers `source: "local"` or
  /// `config: null`. The honest card is a far better answer than an empty
  /// hostname list.
  private var isLocallyManaged: Bool {
    guard let tunnel = displayedTunnel else { return false }
    if tunnel.configSource == .local { return true }
    guard let configuration else { return false }
    return configuration.configSource == .local || configuration.config == nil
  }

  @ViewBuilder private func publicHostnamesGroup() -> some View {
    let rows = publicHostnameRows
    // A tunnel whose only ingress rule is cloudflared's mandatory catch-all
    // publishes no public hostname at all, so the section goes away rather than
    // showing a lone "Everything else".
    if !rows.isEmpty {
      let shown = Array(rows.prefix(Self.sectionRowCap))
      DashListGroup(title: "Public hostnames") {
        dashListCardRows(items: shown, inset: false) { row in
          // The catch-all is a fallback, not a destination: it takes the muted
          // glyph while a real hostname keeps the feature accent.
          let iconColor: Color? = row.isCatchAll ? DashTheme.iconMuted : nil
          Button {
            selectedHostname = row
          } label: {
            DashListRow(
              title: row.title,
              subtitle: row.service,
              icon: SolarAsset.Content.globe,
              iconColor: iconColor,
              showsChevron: false
            ) {
              if row.isProtected { StatusBadge(.protected) }
            }
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityLabel(row.accessibilityLabel)
        }
        if rows.count > shown.count {
          overflowRow(shown: shown.count, total: rows.count)
        }
      }
      .dashSectionBoundary()
    }
  }

  private var publicHostnameRows: [TunnelHostnameRow] {
    guard let ingress = configuration?.config?.ingress, !ingress.isEmpty else { return [] }
    let tunnelRequiresAccess = configuration?.config?.originRequest?.access?.required == true
    var hostnames: [TunnelHostnameRow] = []
    var catchAll: TunnelHostnameRow?
    for (index, rule) in ingress.enumerated() {
      let row = TunnelHostnameRow(
        rule: rule,
        index: index,
        tunnelRequiresAccess: tunnelRequiresAccess,
        accessHosts: accessHosts)
      if row.isCatchAll {
        catchAll = row
      } else {
        hostnames.append(row)
      }
    }
    guard !hostnames.isEmpty else { return [] }
    // The catch-all rides at the bottom, dimmed: it is the "everything else"
    // fallback cloudflared requires, not a hostname anyone can visit.
    if let catchAll { hostnames.append(catchAll) }
    return hostnames
  }

  @ViewBuilder private func locallyManagedGroup() -> some View {
    VStack(alignment: .leading, spacing: 0) {
      DashInfoGroup(title: "Configuration", placeholderRows: 2) {
        DashInfoRow("Managed on", value: DashL10n.string("The origin machine"))
        DashInfoRow("Configuration file", value: "config.yml", mono: true)
      }
      Text(
        "This tunnel’s ingress rules live in cloudflared’s local configuration file. Cloudflare does not store them, so they cannot be shown here."
      )
      .dashTextStyle(.footnote)
      .foregroundStyle(DashTheme.subtle)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, DashTheme.Spacing.rowInset)
      .dashItemBoundary()
      DashSecondaryPillButton(title: "Open Tunnel docs") {
        openURL(TunnelExternalURL.guide)
      }
      .dashItemBoundary()
    }
    .dashSectionBoundary()
  }

  @ViewBuilder private func hostnameTray(_ row: TunnelHostnameRow) -> some View {
    DashDetailTray(fields: row.detailFields) {
      // Reversible pills above; the primary verb stays bottom-most.
      VStack(spacing: 10) {
        if let service = row.service {
          DashTrayPillButton(title: "Copy service") {
            UIPasteboard.general.string = service
            model.toasts.success(DashL10n.string("Service copied."))
          }
        }
        if let url = row.browsableURL {
          DashTrayPillButton(title: "Open in Safari") {
            openURL(url)
          }
        }
        if !row.isCatchAll {
          DashActionButton(title: "Copy hostname") {
            UIPasteboard.general.string = row.hostname
            model.toasts.success(DashL10n.string("Hostname copied."))
          }
        }
      }
    }
  }

  // MARK: Section 4 — Private networks

  @ViewBuilder private func privateNetworksGroup() -> some View {
    // Settled-empty drops the section; a failure keeps it and says so. See the
    // file header for why those two are not the same answer.
    if routesPhase != .content || !routes.isEmpty {
      let shown = Array(routes.prefix(Self.sectionRowCap))
      DashInfoGroup(
        title: "Private networks",
        phase: routesPhase,
        placeholderRows: 2,
        retry: { Task { await reloadRoutes() } },
        content: {
          ForEach(shown) { route in
            DashInfoRow(value: route.network ?? "", mono: true) {
              if let detail = routeDetail(route) {
                Text(detail)
                  .dashTextStyle(.caption)
                  .foregroundStyle(DashTheme.subtle)
                  .lineLimit(1)
              }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(routeAccessibilityLabel(route))
          }
          if routes.count > shown.count {
            overflowRow(shown: shown.count, total: routes.count)
          }
        }
      )
      .dashSectionBoundary()
    }
  }

  /// The route's own comment, else its virtual network — and the VNET only when
  /// the account has more than one, since "default" beside every row is noise.
  private func routeDetail(_ route: TunnelRoute) -> String? {
    let comment = route.comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !comment.isEmpty { return comment }
    guard virtualNetworks.count > 1, let networkID = route.virtualNetworkID else { return nil }
    let name = virtualNetworks.first { $0.id == networkID }?.name ?? ""
    return name.isEmpty ? nil : name
  }

  private func routeAccessibilityLabel(_ route: TunnelRoute) -> String {
    var parts = [DashL10n.string("Private network"), route.network ?? ""]
    if let detail = routeDetail(route) { parts.append(detail) }
    return parts.filter { !$0.isEmpty }.joined(separator: ", ")
  }

  // MARK: Shared row chrome

  private func overflowRow(shown: Int, total: Int) -> some View {
    Text(DashL10n.string("Showing \(shown) of \(total)."))
      .dashTextStyle(.footnote)
      .foregroundStyle(DashTheme.subtle)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(minHeight: DashTheme.Layout.minimumHitTarget)
  }

  private func connectorTitle(_ connector: TunnelConnector) -> String {
    let version = connector.version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return version.isEmpty ? "cloudflared" : "cloudflared \(version)"
  }

  private func connectorSubtitle(_ connector: TunnelConnector) -> String? {
    var parts: [String] = []
    if let arch = connector.arch, !arch.isEmpty { parts.append(arch) }
    if let origin = connector.conns?.compactMap(\.originIP).first(where: { !$0.isEmpty }) {
      parts.append(origin)
    }
    if let started = connector.runAt.flatMap(ExpiryReminders.date(fromISO8601:)) {
      parts.append(DashL10n.string("Started \(watchtowerRelativeTime(started))"))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func connectorAccessibilityLabel(_ connector: TunnelConnector) -> String {
    var parts = [connectorTitle(connector)]
    if let subtitle = connectorSubtitle(connector) { parts.append(subtitle) }
    if let colos = tunnelColoSummary(connector.conns ?? []) { parts.append(colos) }
    return parts.joined(separator: ", ")
  }

  // MARK: Loading

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
    if !force, applyCached(accountID: accountID) {
      loading = false
      error = nil
      await loadSecondary(context: context, force: false)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      return
    }
    if !hasPresentedContent { loading = true }
    error = nil
    do {
      async let connectorFetch = model.client.listTunnelConnectors(
        accountID: accountID, tunnelID: tunnelID)
      let fetchedTunnel = try await resolveTunnel(accountID: accountID, force: force)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      let fetchedConnectors = try await connectorFetch
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }

      var fetchedConfiguration: TunnelConfiguration?
      if fetchedTunnel.configSource == .cloudflare {
        fetchedConfiguration = try await model.client.getTunnelConfiguration(
          accountID: accountID, tunnelID: tunnelID)
        guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      }
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }

      tunnel = fetchedTunnel
      connectors = fetchedConnectors
      configuration = fetchedConfiguration
      hasPresentedContent = true
      cache(
        tunnel: fetchedTunnel, connectors: fetchedConnectors, configuration: fetchedConfiguration,
        accountID: accountID)
    } catch {
      guard
        !Task.isCancelled,
        model.isCurrentAccount(context),
        !error.dashIsCancellation
      else { return }
      // `DashFeatureList` presents this full-screen when cold and as a banner
      // over warm content. Primary failures are never silently discarded.
      self.error = error.dashActionableMessage
      loading = false
      return
    }
    guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
    loading = false
    await loadSecondary(context: context, force: force)
    guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
  }

  private func reset(for context: AccountRequestContext?) {
    loadedContext = context
    tunnel = nil
    connectors = []
    configuration = nil
    error = nil
    loading = context != nil
    hasPresentedContent = false
    routes = []
    routesPhase = .loading
    virtualNetworks = []
    accessHosts = []
    selectedHostname = nil
  }

  /// True when every primary value came out of the session cache, so a warm
  /// revisit paints without a request.
  private func applyCached(accountID: String) -> Bool {
    guard
      let cachedTunnel: CloudflareTunnel = model.featureCache.get(
        FeatureCacheKey.tunnel(accountID: accountID, tunnelID: tunnelID)),
      let cachedConnectors: [TunnelConnector] = model.featureCache.get(
        FeatureCacheKey.tunnelConnectors(accountID: accountID, tunnelID: tunnelID))
    else { return false }
    let cachedConfiguration: TunnelConfiguration? = model.featureCache.get(
      FeatureCacheKey.tunnelConfiguration(accountID: accountID, tunnelID: tunnelID))
    guard cachedTunnel.configSource == .local || cachedConfiguration != nil else { return false }
    tunnel = cachedTunnel
    connectors = cachedConnectors
    configuration = cachedConfiguration
    hasPresentedContent = true
    return true
  }

  private func cache(
    tunnel: CloudflareTunnel,
    connectors: [TunnelConnector],
    configuration: TunnelConfiguration?,
    accountID: String
  ) {
    model.featureCache.set(
      FeatureCacheKey.tunnel(accountID: accountID, tunnelID: tunnelID), tunnel)
    model.featureCache.set(
      FeatureCacheKey.tunnelConnectors(accountID: accountID, tunnelID: tunnelID), connectors)
    let configurationKey = FeatureCacheKey.tunnelConfiguration(
      accountID: accountID, tunnelID: tunnelID)
    if let configuration {
      model.featureCache.set(configurationKey, configuration)
    } else {
      model.featureCache.remove(configurationKey)
    }
  }

  /// The list entry already carries everything this screen reads, so a push
  /// from the list costs no extra request. `getTunnel` is for a deep link, or a
  /// cache the memory-pressure purge has since dropped.
  private func resolveTunnel(accountID: String, force: Bool) async throws -> CloudflareTunnel {
    if !force {
      if let entry: CloudflareTunnel = model.featureCache.get(
        FeatureCacheKey.tunnel(accountID: accountID, tunnelID: tunnelID))
      {
        return entry
      }
      let list: [CloudflareTunnel]? = model.featureCache.get(FeatureCacheKey.tunnels(accountID))
      if let entry = list?.first(where: { $0.id == tunnelID }) { return entry }
    }
    return try await model.client.getTunnel(accountID: accountID, tunnelID: tunnelID)
  }

  private func loadSecondary(context: AccountRequestContext, force: Bool) async {
    guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
    // D5 — the ONLY network source of the `Protected` badge. If `access.read`
    // cannot be proven, delete exactly the two statements below: `accessHosts`
    // then stays empty forever, the badge falls back to the tunnel's own
    // `originRequest.access.required` signal, and nothing else on this screen
    // moves. (`accessApplications(accountID:force:)` and
    // `TunnelHostMatching.hosts(in:)` become unreferenced and can go with them.)
    let apps = await accessApplications(context: context, force: force)
    guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
    accessHosts = TunnelHostMatching.hosts(in: apps)
    await loadRoutes(context: context, force: force)
    guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
  }

  private func accessApplications(
    context: AccountRequestContext,
    force: Bool
  ) async -> [AccessApplication] {
    guard !Task.isCancelled, model.isCurrentAccount(context) else { return [] }
    let key = FeatureCacheKey.accessApplications(context.accountID)
    if !force, let cached: [AccessApplication] = model.featureCache.get(key) { return cached }
    // `try?` on purpose: an account without Access, or a grant without
    // `access.read`, costs a badge and nothing else.
    guard
      let fetched = try? await model.client.listAccessApplications(accountID: context.accountID),
      !Task.isCancelled,
      model.isCurrentAccount(context)
    else {
      return []
    }
    model.featureCache.set(key, fetched)
    return fetched
  }

  private func loadRoutes(context: AccountRequestContext, force: Bool) async {
    guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
    let accountID = context.accountID
    let key = FeatureCacheKey.tunnelRoutes(accountID: accountID, tunnelID: tunnelID)
    if !force, let cached: [TunnelRoute] = model.featureCache.get(key) {
      settleRoutes(cached, phase: .content)
      let cachedNetworks: [TunnelVirtualNetwork]? = model.featureCache.get(
        FeatureCacheKey.tunnelVirtualNetworks(accountID))
      virtualNetworks = cachedNetworks ?? []
      return
    }
    do {
      let fetched = try await model.client.listTunnelRoutes(
        accountID: accountID, tunnelID: tunnelID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      let usable = fetched.filter { $0.deletedAt == nil && !($0.network ?? "").isEmpty }
      model.featureCache.set(key, usable)
      settleRoutes(usable, phase: .content)
      if !usable.isEmpty {
        await loadVirtualNetworks(context: context, force: force)
        guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      }
    } catch {
      guard
        !Task.isCancelled,
        model.isCurrentAccount(context),
        !error.dashIsCancellation
      else { return }
      if error.dashIsResourceAbsent {
        // Zero Trust private networking is not provisioned. Structural absence
        // reads the same as "this tunnel advertises none": drop the section.
        settleRoutes([], phase: .content)
      } else {
        settleRoutes([], phase: .failed(error.dashActionableMessage))
      }
    }
  }

  /// Names a route's virtual network, and only when the account has more than
  /// one. A failure costs a subtitle, never the section — hence `try?`.
  private func loadVirtualNetworks(context: AccountRequestContext, force: Bool) async {
    guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
    let key = FeatureCacheKey.tunnelVirtualNetworks(context.accountID)
    if !force, let cached: [TunnelVirtualNetwork] = model.featureCache.get(key) {
      virtualNetworks = cached
      return
    }
    guard
      let fetched = try? await model.client.listTunnelVirtualNetworks(accountID: context.accountID),
      !Task.isCancelled,
      model.isCurrentAccount(context)
    else { return }
    model.featureCache.set(key, fetched)
    virtualNetworks = fetched
  }

  private func reloadRoutes() async {
    guard let context = model.accountRequestContext else { return }
    guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
    withAnimation(DashTheme.Motion.content) { routesPhase = .loading }
    await loadRoutes(context: context, force: true)
    guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
  }

  private func settleRoutes(_ values: [TunnelRoute], phase: DashSectionPhase) {
    withAnimation(DashTheme.Motion.content) {
      routes = values
      routesPhase = phase
    }
  }
}

// MARK: - Hostname rows

/// One public-hostname ingress rule, flattened for a row and its tray.
struct TunnelHostnameRow: Identifiable, Hashable, Sendable {
  let id: String
  let hostname: String
  let path: String?
  let service: String?
  let isCatchAll: Bool
  /// Dash makes the **positive claim only**. No badge means "no Access coverage
  /// Dash can see" — never "unprotected". Dash cannot see Gateway, WAF, mTLS or
  /// origin-side auth, and asserting the negative would be exactly the invented
  /// verdict the Watchtower Diagnostics trim removed.
  let isProtected: Bool

  init(
    rule: TunnelIngressRule,
    index: Int,
    tunnelRequiresAccess: Bool,
    accessHosts: Set<String>
  ) {
    let host = (rule.hostname ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let rulePath = (rule.path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let ruleService = (rule.service ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    self.id = "\(index)|\(host)|\(rulePath)"
    self.hostname = host
    self.path = rulePath.isEmpty ? nil : rulePath
    self.service = ruleService.isEmpty ? nil : ruleService
    self.isCatchAll = rule.isCatchAll
    // A rule's own `originRequest` overrides the tunnel-level default; where it
    // says nothing, the default is inherited. Either source alone is enough,
    // which is what keeps the Access lookup a two-line cut.
    let inherited = rule.originRequest?.access?.required ?? tunnelRequiresAccess
    let matched = TunnelHostMatching.normalizedHost(host).map(accessHosts.contains) ?? false
    self.isProtected = !host.isEmpty && (inherited || matched)
  }

  var displayHostname: String {
    guard let path else { return hostname }
    return hostname + path
  }

  var title: String {
    isCatchAll ? DashL10n.string("Everything else") : displayHostname
  }

  var trayTitle: String { isCatchAll ? title : hostname }

  /// Only a concrete host is browsable; a wildcard rule (`*.example.com`) has
  /// no single address to open.
  var browsableURL: URL? {
    guard !isCatchAll, !hostname.contains("*"), !hostname.isEmpty else { return nil }
    return URL(string: "https://\(displayHostname)")
  }

  var detailFields: [DashDetailField] {
    var fields: [DashDetailField] = []
    if !isCatchAll {
      fields.append(DashDetailField(label: "Hostname", value: hostname))
    }
    if let path {
      fields.append(DashDetailField(label: "Path", value: path, mono: true))
    }
    if let service {
      fields.append(DashDetailField(label: "Service", value: service, mono: true))
    }
    if isProtected {
      fields.append(
        DashDetailField(label: "Access", value: DashL10n.string("Protected")))
    }
    return fields
  }

  var accessibilityLabel: String {
    var parts = [title]
    if let service { parts.append(service) }
    if isProtected { parts.append(DashL10n.string("Protected")) }
    return parts.joined(separator: ", ")
  }
}

// MARK: - Access matching

enum TunnelHostMatching {
  /// Every hostname the account's Access applications cover, normalized for a
  /// literal comparison. No wildcard-subdomain matching in v1 — a missed match
  /// costs a badge, which is the safe direction for a positive-only claim.
  static func hosts(in applications: [AccessApplication]) -> Set<String> {
    var hosts: Set<String> = []
    for application in applications {
      if let host = normalizedHost(application.domain) { hosts.insert(host) }
      for destination in application.destinations ?? [] {
        if let host = normalizedHost(destination.uri) { hosts.insert(host) }
      }
    }
    return hosts
  }

  /// Access spells a hostname several ways — `app.example.com`,
  /// `app.example.com/admin`, `https://app.example.com:8443/`. Reduce all of
  /// them to the bare host so one comparison serves.
  static func normalizedHost(_ raw: String?) -> String? {
    var value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !value.isEmpty else { return nil }
    if let schemeRange = value.range(of: "://") {
      value = String(value[schemeRange.upperBound...])
    }
    if let slash = value.firstIndex(of: "/") {
      value = String(value[..<slash])
    }
    if let at = value.lastIndex(of: "@") {
      value = String(value[value.index(after: at)...])
    }
    // Strip a port, but never an IPv6 literal's colons.
    if !value.hasPrefix("["), let colon = value.lastIndex(of: ":"),
      value[value.index(after: colon)...].allSatisfy(\.isNumber)
    {
      value = String(value[..<colon])
    }
    while value.hasSuffix(".") { value.removeLast() }
    return value.isEmpty ? nil : value
  }
}

// MARK: - Shared formatting

func tunnelDisplayName(_ tunnel: CloudflareTunnel) -> String {
  let name = tunnel.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  return name.isEmpty ? String(tunnel.id.prefix(8)) : name
}

/// Distinct `cloudflared` processes behind a tunnel. One process opens four
/// connections, so counting `connections` would report "8 connectors" for two
/// machines — `client_id` is the process.
func tunnelConnectorCount(_ tunnel: CloudflareTunnel) -> Int {
  let connections = tunnel.connections ?? []
  let clientIDs = connections.compactMap { $0.clientID }.filter { !$0.isEmpty }
  return clientIDs.isEmpty ? connections.count : Set(clientIDs).count
}

func tunnelColoSummary(_ connections: [TunnelConnection]) -> String? {
  var seen: Set<String> = []
  var ordered: [String] = []
  for name in connections.compactMap(\.coloName) where !name.isEmpty {
    if seen.insert(name).inserted { ordered.append(name) }
  }
  guard !ordered.isEmpty else { return nil }
  return ordered.formatted(
    .list(type: .and, width: .narrow).locale(DashL10n.activeLocale))
}

func tunnelListSubtitle(_ tunnel: CloudflareTunnel) -> String? {
  switch tunnel.health {
  case .healthy, .degraded:
    let count = tunnelConnectorCount(tunnel)
    guard count > 0 else { return nil }
    let connectors =
      count == 1
      ? DashL10n.string("1 connector")
      : DashL10n.string("\(count) connectors")
    guard let colos = tunnelColoSummary(tunnel.connections ?? []) else { return connectors }
    return "\(connectors) · \(colos)"
  case .down, .inactive:
    guard let last = tunnel.connsInactiveAt.flatMap(ExpiryReminders.date(fromISO8601:)) else {
      return nil
    }
    return DashL10n.string("Last connected \(watchtowerRelativeTime(last))")
  case .unknown:
    return nil
  }
}

func tunnelRowAccessibilityLabel(_ tunnel: CloudflareTunnel) -> String {
  var parts = [tunnelDisplayName(tunnel)]
  if let subtitle = tunnelListSubtitle(tunnel) { parts.append(subtitle) }
  parts.append(StatusToken(tunnelStatus: tunnel.statusRaw).label)
  return parts.joined(separator: ", ")
}

/// Medium date, in the in-app language rather than the system one.
