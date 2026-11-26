import CloudflareAPI
import SwiftUI

enum FeatureAccessFilter: String, CaseIterable, Hashable {
  case all
  case available
  case readOnly
  case locked

  var title: String {
    switch self {
    case .all: "All"
    case .available: "Available"
    case .readOnly: "Read-only"
    case .locked: "Needs authorization"
    }
  }

  func matches(_ level: FeatureAccessLevel) -> Bool {
    switch self {
    case .all: true
    case .available: level != .locked
    case .readOnly: level == .readOnly
    case .locked: level == .locked
    }
  }
}

/// Access filtering for the Resources catalog.
enum FeatureCatalogFiltering {
  static func features(
    filter: FeatureAccessFilter,
    grantedScopes: Set<String>?,
    enabled: Set<FeatureID> = Set(FeatureID.allCases)
  ) -> [FeatureID] {
    // Unknown grant fails closed — AppRoot does not mount the catalog until
    // bootstrap restores the scope mirror or its conservative fallback.
    guard grantedScopes != nil else { return [] }
    return FeatureCatalog.all.filter { feature in
      enabled.contains(feature)
        && filter.matches(feature.capability.accessLevel(grantedScopes: grantedScopes))
    }
  }

  static func enabledFeatures(
    tunnelsExperimentalEnabled: Bool
  ) -> Set<FeatureID> {
    Set(
      FeatureID.allCases.filter {
        DashExperimentalFeatures.isCatalogVisible(
          $0,
          tunnelsEnabled: tunnelsExperimentalEnabled)
      })
  }
}

struct FeatureCatalogView: View {
  /// Lists every enabled catalog feature, including locked experimental ones
  /// so Resources can show the Needs authorization badge and route into Grant
  /// access. Core features stay granted by sign-in; experimental ones opt in
  /// via Settings and authorize on demand.
  static let defaultFilter: FeatureAccessFilter = .all

  @Environment(AppModel.self) private var model
  @AppStorage(DashExperimentalFeatures.tunnelsKey) private var tunnelsExperimentalEnabled =
    false
  @State private var showsQuickJump = false

  private var visibleFeatures: [FeatureID] {
    FeatureCatalogFiltering.features(
      filter: Self.defaultFilter,
      grantedScopes: model.grantedScopes,
      enabled: FeatureCatalogFiltering.enabledFeatures(
        tunnelsExperimentalEnabled: tunnelsExperimentalEnabled))
  }

  private var grouped: [(String, [FeatureID])] {
    FeatureCatalog.sections(for: visibleFeatures)
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        QuickJumpTriggerBar(
          accessibilityIdentifier: "resources-quick-jump-trigger"
        ) {
          showsQuickJump = true
        }
        .dashSectionReveal(0)

        if visibleFeatures.isEmpty {
          DashEmptyState(
            icon: SolarAsset.Content.search,
            title: "No resources",
            message: "Resources for this account will show up here."
          )
          .dashSectionReveal(1)
        } else {
          ForEach(Array(grouped.enumerated()), id: \.element.0) { index, section in
            let (title, features) = section
            catalogSection(title: title, features: features)
              .dashSectionReveal(index + 1)
          }
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, DashTheme.Spacing.section)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .modifier(DashScrollEdgeEffectsHidden())
    .dashSectionEntrance()
    .dashCatalogScreen()
    .dashTray(
      isPresented: $showsQuickJump,
      title: DashL10n.string("Quick jump")
    ) {
      QuickJumpTray()
    }
  }

  @ViewBuilder
  private func catalogSection(title: String, features: [FeatureID]) -> some View {
    DashListGroup(title: title) {
      ForEach(features, id: \.self) { feature in
        DashListGroupLink(value: .feature(feature)) {
          FeatureRow(feature: feature)
        }
        .accessibilityIdentifier("feature-\(feature.rawValue)")
      }
    }
  }
}

// MARK: - Global Quick Jump

enum QuickJumpKind: String, CaseIterable, Hashable, Sendable {
  case zone
  case worker
  case pagesProject
  case r2Bucket
  case kvNamespace
  case tunnel

  var featureID: FeatureID {
    switch self {
    case .zone: .zones
    case .worker: .workers
    case .pagesProject: .pages
    case .r2Bucket: .r2
    case .kvNamespace: .kv
    case .tunnel: .tunnels
    }
  }

  var sectionTitle: String {
    switch self {
    case .zone: "Domains"
    case .worker: "Workers"
    case .pagesProject: "Pages"
    case .r2Bucket: "R2"
    case .kvNamespace: "KV"
    case .tunnel: "Tunnels"
    }
  }

  var kindLabel: String {
    switch self {
    case .zone: DashL10n.string("Domain")
    case .worker: DashL10n.string("Worker")
    case .pagesProject: DashL10n.string("Pages")
    case .r2Bucket: DashL10n.string("R2 bucket")
    case .kvNamespace: DashL10n.string("KV namespace")
    case .tunnel: DashL10n.string("Tunnel")
    }
  }

  var listIcon: String? {
    switch self {
    case .zone: nil
    case .worker: SolarAsset.Content.code
    case .pagesProject: SolarAsset.Content.codeCircle
    case .r2Bucket: SolarAsset.Content.box
    case .kvNamespace: SolarAsset.Content.pinList
    case .tunnel: SolarAsset.Content.routing
    }
  }
}

struct QuickJumpItem: Identifiable, Hashable, Sendable {
  let kind: QuickJumpKind
  let resourceID: String
  let title: String
  let subtitle: String?
  let searchFields: [String]
  let destination: Destination

  var id: String { "\(kind.rawValue)|\(resourceID)" }

  func recentResource(accountID: String) -> RecentResource? {
    let recentKind: RecentResource.Kind? =
      switch kind {
      case .zone: .zone
      case .worker: .worker
      case .pagesProject: .pagesProject
      case .r2Bucket: .r2Bucket
      case .kvNamespace: .kvNamespace
      case .tunnel: nil
      }
    guard let recentKind else { return nil }
    return RecentResource(
      accountID: accountID,
      kind: recentKind,
      resourceID: resourceID,
      title: title)
  }
}

struct QuickJumpGroup: Identifiable, Hashable, Sendable {
  let kind: QuickJumpKind
  let items: [QuickJumpItem]

  var id: String { kind.rawValue }
  var title: String { kind.sectionTitle }
}

/// Client-side cross-resource index built strictly from `FeatureDataCache` and
/// `RecentResources` for the active account — never initiates network requests.
enum QuickJumpIndex {
  struct Snapshot: Hashable, Sendable {
    let items: [QuickJumpItem]
    let recents: [QuickJumpItem]
  }

  @MainActor
  static func snapshot(
    accountID: String,
    cache: FeatureDataCache,
    recentsRaw: String,
    grantedScopes: Set<String>?,
    tunnelsExperimentalEnabled: Bool
  ) -> Snapshot {
    func isAllowed(_ feature: FeatureID) -> Bool {
      guard
        DashExperimentalFeatures.isCatalogVisible(
          feature,
          tunnelsEnabled: tunnelsExperimentalEnabled)
      else { return false }
      return feature.capability.accessLevel(grantedScopes: grantedScopes) != .locked
    }

    var items: [QuickJumpItem] = []
    var seenIDs: Set<String> = []

    func appendUnique(_ item: QuickJumpItem) {
      if seenIDs.insert(item.id).inserted {
        items.append(item)
      }
    }

    if isAllowed(.zones),
      let zones: [CloudflareZone] = cache.get(FeatureCacheKey.zones(accountID))
    {
      for zone in zones {
        appendUnique(
          QuickJumpItem(
            kind: .zone,
            resourceID: zone.id,
            title: zone.name,
            subtitle: zone.status.map { $0.capitalized },
            searchFields: [zone.name, zone.id],
            destination: .zone(zone.id)))
      }
    }

    if isAllowed(.workers),
      let workers: [WorkerScript] = cache.get(FeatureCacheKey.workers(accountID))
    {
      for worker in workers {
        appendUnique(
          QuickJumpItem(
            kind: .worker,
            resourceID: worker.id,
            title: worker.id,
            subtitle: nil,
            searchFields: [worker.id],
            destination: .worker(worker.id)))
      }
    }

    if isAllowed(.pages),
      let projects: [PagesProject] = cache.get(FeatureCacheKey.pagesProjects(accountID))
    {
      for project in projects {
        appendUnique(
          QuickJumpItem(
            kind: .pagesProject,
            resourceID: project.name,
            title: project.name,
            subtitle: project.subdomain,
            searchFields: [project.name, project.subdomain].compactMap { $0 },
            destination: .pagesProject(project.name)))
      }
    }

    if isAllowed(.r2),
      let buckets: [R2Bucket] = cache.get(FeatureCacheKey.r2Buckets(accountID))
    {
      for bucket in buckets {
        appendUnique(
          QuickJumpItem(
            kind: .r2Bucket,
            resourceID: bucket.name,
            title: bucket.name,
            subtitle: nil,
            searchFields: [bucket.name],
            destination: .r2Bucket(bucket.name, prefix: "")))
      }
    }

    if isAllowed(.kv),
      let namespaces: [KVNamespace] = cache.get(FeatureCacheKey.kvNamespaces(accountID))
    {
      for namespace in namespaces {
        appendUnique(
          QuickJumpItem(
            kind: .kvNamespace,
            resourceID: namespace.id,
            title: namespace.title,
            subtitle: namespace.id,
            searchFields: [namespace.title, namespace.id],
            destination: .kvNamespace(namespace.id)))
      }
    }

    if isAllowed(.tunnels),
      let tunnels: [CloudflareTunnel] = cache.get(FeatureCacheKey.tunnels(accountID))
    {
      for tunnel in tunnels {
        let title = tunnelDisplayName(tunnel)
        appendUnique(
          QuickJumpItem(
            kind: .tunnel,
            resourceID: tunnel.id,
            title: title,
            subtitle: tunnel.id,
            searchFields: [title, tunnel.id],
            destination: .tunnel(tunnel.id)))
      }
    }

    let recents = RecentResources.visible(in: recentsRaw, accountID: accountID)
      .compactMap { recent -> QuickJumpItem? in
        guard isAllowed(recent.featureID) else { return nil }
        let kind: QuickJumpKind =
          switch recent.kind {
          case .zone: .zone
          case .worker: .worker
          case .pagesProject: .pagesProject
          case .r2Bucket: .r2Bucket
          case .kvNamespace: .kvNamespace
          }
        return QuickJumpItem(
          kind: kind,
          resourceID: recent.resourceID,
          title: recent.title,
          subtitle: kind.kindLabel,
          searchFields: [recent.title, recent.resourceID],
          destination: recent.destination)
      }

    // Keep recently opened resources searchable even if their list cache has been evicted.
    for recent in recents {
      appendUnique(recent)
    }

    return Snapshot(items: items, recents: recents)
  }

  static func groupedMatches(query: String, in items: [QuickJumpItem]) -> [QuickJumpGroup] {
    guard DashSearchMatcher.isActive(query) else { return [] }
    let matched = items.filter { item in
      DashSearchMatcher.matches(query, in: item.searchFields)
    }
    let byKind = Dictionary(grouping: matched, by: \.kind)
    return QuickJumpKind.allCases.compactMap { kind in
      guard let kindItems = byKind[kind], !kindItems.isEmpty else { return nil }
      return QuickJumpGroup(kind: kind, items: kindItems)
    }
  }
}

/// Recessed search trigger surface shared by Home and Resources to open `QuickJumpTray`.
struct QuickJumpTriggerBar: View {
  let accessibilityIdentifier: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: DashTheme.Spacing.compact) {
        SolarIcon(
          asset: SolarAsset.search,
          size: 17,
          color: DashTheme.placeholder
        )
        Text(DashL10n.string("Search resources"))
          .dashTextStyle(.body)
          .foregroundStyle(DashTheme.placeholder)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .frame(minHeight: 42)
      .background(DashTheme.recessed)
      .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous)
          .strokeBorder(DashTheme.separator, lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityLabel(DashL10n.string("Quick jump"))
    .accessibilityHint(
      DashL10n.string("Search cached domains, Workers, Pages, R2, KV, and tunnels.")
    )
    .accessibilityIdentifier(accessibilityIdentifier)
  }
}

/// Cross-resource quick jumper reading only the active account's cached catalogs
/// and recent history.
struct QuickJumpTray: View {
  @Environment(AppModel.self) private var model
  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.dashTrayDismissAfter) private var dismissAfter
  @AppStorage(RecentResources.key) private var recentsRaw = ""
  @AppStorage(DashExperimentalFeatures.tunnelsKey) private var tunnelsExperimentalEnabled = false

  @State private var query = ""
  @State private var snapshot = QuickJumpIndex.Snapshot(items: [], recents: [])

  private var isSearching: Bool {
    DashSearchMatcher.isActive(query)
  }

  private var matchedGroups: [QuickJumpGroup] {
    QuickJumpIndex.groupedMatches(query: query, in: snapshot.items)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DashTheme.Spacing.itemGap) {
      DashSearchBar(
        text: $query,
        prompt: DashL10n.string("Search domains, Workers, R2…"),
        accessibilityIdentifier: "quick-jump-search-field",
        autoFocus: true
      )

      DashFadedScrollView(
        surface: DashTheme.Sheet.background,
        maxHeight: 360,
        bounceBasedOnSize: true,
        dismissesKeyboardInteractively: true
      ) {
        resultsContent
      }
    }
    .task(id: model.accountRequestContext) {
      refreshSnapshot()
    }
    .onChange(of: recentsRaw) { _, _ in
      refreshSnapshot()
    }
    .onChange(of: tunnelsExperimentalEnabled) { _, _ in
      refreshSnapshot()
    }
  }

  @ViewBuilder
  private var resultsContent: some View {
    if isSearching {
      if matchedGroups.isEmpty {
        DashSearchEmptyState(query: query) {
          query = ""
        }
      } else {
        LazyVStack(alignment: .leading, spacing: DashTheme.Spacing.itemGap) {
          ForEach(matchedGroups) { group in
            VStack(alignment: .leading, spacing: 4) {
              DashListGroupHeader(title: DashL10n.ui(group.title))
                .padding(.horizontal, 4)
              itemRows(group.items)
            }
          }
        }
      }
    } else if !snapshot.recents.isEmpty {
      LazyVStack(alignment: .leading, spacing: 4) {
        DashListGroupHeader(title: DashL10n.ui("Recently used"))
          .padding(.horizontal, 4)
        itemRows(snapshot.recents)
      }
    } else if !snapshot.items.isEmpty {
      Text(DashL10n.string("Type to jump across \(snapshot.items.count) cached resources."))
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    } else {
      DashEmptyState(
        icon: SolarAsset.Content.search,
        title: DashL10n.string("Nothing cached yet"),
        message: DashL10n.string("Open Domains, Workers, Pages, R2, or KV to search them here.")
      )
    }
  }

  @ViewBuilder
  private func itemRows(_ items: [QuickJumpItem]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        Button {
          select(item)
        } label: {
          DashListRow(
            title: item.title,
            subtitle: item.subtitle,
            icon: item.kind.listIcon,
            iconColor: FeatureVisualIdentity.catalogColor(for: item.kind.featureID),
            avatarSeed: item.kind == .zone ? item.title : nil
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityIdentifier("quick-jump-item-\(item.kind.rawValue)-\(item.resourceID)")
        if index < items.count - 1 {
          DashListGroupDivider()
        }
      }
    }
  }

  private func refreshSnapshot() {
    guard let accountID = model.activeAccountID else {
      snapshot = QuickJumpIndex.Snapshot(items: [], recents: [])
      return
    }
    snapshot = QuickJumpIndex.snapshot(
      accountID: accountID,
      cache: model.featureCache,
      recentsRaw: recentsRaw,
      grantedScopes: model.grantedScopes,
      tunnelsExperimentalEnabled: tunnelsExperimentalEnabled)
  }

  private func select(_ item: QuickJumpItem) {
    if let accountID = model.activeAccountID,
      let recent = item.recentResource(accountID: accountID)
    {
      recentsRaw = RecentResources.recording(recent, in: recentsRaw)
    }
    let destination = item.destination
    dismissAfter {
      navigator?.push(destination)
    }
  }
}
