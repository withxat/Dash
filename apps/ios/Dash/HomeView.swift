import CloudflareAPI
import GradientAvatars
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.dashTabActive) private var isActive
  @Environment(\.dashCanPresentPendingHomeAction) private var canPresentPendingAction
  /// A deep-linked action may arrive while Profile or another tray is still
  /// leaving. Keep it queued until the app-level tray preference clears so two
  /// independent full-screen covers never compete for the one compact tray.
  @AppStorage(RecentResources.key) private var recentsRaw = ""
  @AppStorage(HomeShortcuts.key) private var shortcutsRaw = HomeShortcuts.defaultValue
  @AppStorage(HomeActions.key) private var actionsRaw = HomeActions.defaultValue
  @AppStorage(HomeEducation.dismissalsKey) private var educationDismissalsRaw = ""
  @AppStorage(DashExperimentalFeatures.tunnelsKey) private var tunnelsExperimentalEnabled =
    false
  @AppStorage(PinnedZones.key) private var pinnedZoneData = ""
  @AppStorage(PinnedZones.initializedAccountsKey) private var pinnedZonesInitialized = ""
  @State private var zones: [CloudflareZone] = []
  @State private var zonesLoading = true
  @State private var zonesError: String?
  @State private var zonesContext: AccountRequestContext?
  @State private var zonesRequestID: UUID?

  /// Pin-first order for Domains and zone pickers. Fetch/cache stay API-ordered.
  private var displayedZones: [CloudflareZone] {
    guard let accountID = model.activeAccountID else { return zones }
    return PinnedZones.prioritized(
      zones, pinsRaw: pinnedZoneData, accountID: accountID, id: \.id)
  }

  private var pinnedZoneIDs: Set<String> {
    guard let accountID = model.activeAccountID else { return [] }
    return Set(PinnedZones.pinnedZoneIDs(in: pinnedZoneData, accountID: accountID))
  }
  @State private var showsAddDomain = false
  @State private var showsR2Upload = false
  @State private var showsAddDNSRecord = false
  @State private var showsCreateKVKey = false
  @State private var showsCreateR2Bucket = false
  @State private var showsAddPagesDomain = false
  @State private var showsAddWorkerDomain = false
  @State private var showsEnableDevelopmentMode = false
  @State private var showsEnableUnderAttackMode = false
  @State private var showsEditActions = false
  @State private var showsEditShortcuts = false
  @State private var showsDemoConnect = false
  @State private var demoConnectSharedAction: DashTraySharedAction?

  private var recents: [RecentResource] {
    guard let accountID = model.activeAccountID else { return [] }
    return RecentResources.visible(in: recentsRaw, accountID: accountID)
  }

  private var shortcuts: [FeatureID] {
    HomeShortcuts.decode(shortcutsRaw).filter {
      DashExperimentalFeatures.isCatalogVisible(
        $0,
        tunnelsEnabled: tunnelsExperimentalEnabled)
    }
  }

  private var quickActions: [HomeActionID] {
    HomeActions.decode(actionsRaw)
  }

  private var educationTip: HomeEducationTip? {
    HomeEducation.recommendation(
      recentsRaw: recentsRaw,
      accountID: model.activeAccountID,
      dismissalsRaw: educationDismissalsRaw,
      isDemoSession: model.isDemoSession
    )
  }

  private var revealOffset: Int {
    model.isDemoSession ? 1 : 0
  }

  private var isAtRoot: Bool {
    navigator?.depth == 0
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        if model.identityStale {
          DashNotice(
            kind: .warning,
            message:
              "Can't reach Cloudflare — showing data from this session. Reconnect to refresh."
          )
          .dashSectionReveal()
        }

        HomeGreetingHeader()
          .dashSectionReveal(0)

        if model.isDemoSession {
          HomeDemoExperienceSection(
            connect: presentDemoConnectFromSource
          )
          .dashSectionReveal(1)
        }

        HomeQuickActionsSection(
          actions: quickActions,
          navigationDestination: { _ in nil },
          perform: perform,
          edit: { showsEditActions = true }
        )
        .dashSectionReveal(1 + revealOffset)

        HomeDomainsSection(
          zones: displayedZones,
          pinnedZoneIDs: pinnedZoneIDs,
          isLoading: zonesLoading,
          error: zonesError,
          locked: isLocked(.zones),
          showsAddDomain: $showsAddDomain,
          retry: { Task { await loadZones(force: true) } }
        )
        .dashSectionReveal(2 + revealOffset)

        HomeShortcutsSection(features: shortcuts) {
          showsEditShortcuts = true
        }
        .dashSectionReveal(3 + revealOffset)

        if let educationTip, let educationAccountID = model.activeAccountID {
          HomeEducationTipCard(tip: educationTip) {
            dismissEducationTip(educationTip, accountID: educationAccountID)
          }
          .dashSectionReveal(4 + revealOffset)
        }

        if !recents.isEmpty {
          HomeRecentsSection(recents: recents) { resource in
            recentsRaw = RecentResources.recording(resource, in: recentsRaw)
          }
          .dashSectionReveal(4 + revealOffset + (educationTip == nil ? 0 : 1))
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, DashTheme.Spacing.section)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .modifier(DashScrollEdgeEffectsHidden())
    .refreshable { await loadZones(force: true) }
    .dashSectionEntrance()
    // Transparent page: the canvas and the top light field are workspace
    // chrome now (`DashWorkspaceTopWash`, painted behind the pager in
    // `MainTabView`), shared with Resources and Watchtower. The greeting sits
    // in that glow; opaque cards (`homeCardSurface`) keep a true fill on top.
    .dashCatalogScreen()
    .task(id: model.accountRequestContext) {
      await loadZones()
      consumePendingHomeActionIfReady()
    }
    .onChange(of: model.accountRequestContext) { _, context in
      resetZones(for: context)
    }
    .dashTray(
      isPresented: $showsAddDomain, title: DashL10n.string("Add domain"),
      tone: FeatureVisualIdentity.tone(for: .zones)
    ) {
      AddDomainSheet {
        guard let accountID = model.activeAccountID else { return }
        model.featureCache.removeZones(accountID: accountID)
        Task { await loadZones(force: true) }
      }
    }
    .dashTray(
      isPresented: $showsR2Upload, title: DashL10n.string("Upload to R2"),
      tone: FeatureVisualIdentity.tone(for: .r2)
    ) {
      HomeR2UploadSheet { bucket in
        guard let accountID = model.activeAccountID else { return }
        recentsRaw = RecentResources.recording(
          RecentResource(
            accountID: accountID, kind: .r2Bucket, resourceID: bucket, title: bucket),
          in: recentsRaw)
      }
    }
    .dashTray(
      isPresented: $showsAddDNSRecord, title: DashL10n.string("Add DNS record"),
      tone: FeatureVisualIdentity.tone(for: .zones)
    ) {
      HomeDNSRecordAction(zones: displayedZones)
    }
    .dashTray(
      isPresented: $showsCreateKVKey, title: DashL10n.string("Create KV key"),
      tone: FeatureVisualIdentity.tone(for: .kv)
    ) {
      HomeCreateKVKeyAction()
    }
    .dashTray(
      isPresented: $showsCreateR2Bucket, title: DashL10n.string("Create R2 bucket"),
      tone: FeatureVisualIdentity.tone(for: .r2)
    ) {
      R2CreateBucketSheet(onCreated: {})
    }
    .dashTray(
      isPresented: $showsAddPagesDomain, title: DashL10n.string("Add Pages domain"),
      tone: FeatureVisualIdentity.tone(for: .pages)
    ) {
      HomePagesDomainAction()
    }
    .dashTray(
      isPresented: $showsAddWorkerDomain, title: DashL10n.string("Attach Worker domain"),
      tone: FeatureVisualIdentity.tone(for: .workers)
    ) {
      HomeWorkerDomainAction()
    }
    .dashTray(
      isPresented: $showsEnableDevelopmentMode, title: DashL10n.string("Development mode"),
      tone: FeatureVisualIdentity.tone(for: .zones)
    ) {
      HomeZoneModeAction(zones: displayedZones, mode: .development)
    }
    .dashTray(
      isPresented: $showsEnableUnderAttackMode, title: DashL10n.string("Under Attack mode"),
      tone: FeatureVisualIdentity.tone(for: .zones)
    ) {
      HomeZoneModeAction(zones: displayedZones, mode: .underAttack)
    }
    .dashTray(
      isPresented: $showsEditActions, title: DashL10n.string("Edit quick actions")
    ) {
      EditHomeActionsView(selectionRaw: $actionsRaw)
    }
    .dashTray(isPresented: $showsEditShortcuts, title: DashL10n.string("Edit shortcuts")) {
      EditShortcutsView(selectionRaw: $shortcutsRaw)
    }
    .dashTray(
      isPresented: $showsDemoConnect,
      title: DashL10n.string("Connect your account"),
      sharedAction: demoConnectSharedAction
    ) {
      HomeDemoConnectContent()
    } footer: {
      HomeDemoConnectFooter(connect: leaveDemoForConnection)
    }
    .onChange(of: actionsRaw) { _, newValue in
      HomeActions.mirrorToAppGroup(newValue)
    }
    .onAppear { consumePendingHomeActionIfReady() }
    .onChange(of: model.pendingHomeAction) { _, _ in
      consumePendingHomeActionIfReady()
    }
    .onChange(of: zonesLoading) { _, _ in
      consumePendingHomeActionIfReady()
    }
    .onChange(of: zonesContext) { _, _ in
      consumePendingHomeActionIfReady()
    }
    .onChange(of: isActive) { _, _ in
      consumePendingHomeActionIfReady()
    }
    .onChange(of: isAtRoot) { _, _ in
      consumePendingHomeActionIfReady()
    }
    .onChange(of: canPresentPendingAction) { _, _ in
      consumePendingHomeActionIfReady()
    }
    .onChange(of: showsDemoConnect) { _, presented in
      if !presented { demoConnectSharedAction = nil }
    }
  }

  /// Deep-linked quick actions wait for the same zone context a tile tap would
  /// already have, so purge / DNS / mode trays do not open against a stale list.
  private func consumePendingHomeActionIfReady() {
    guard let pending = model.pendingHomeAction else { return }
    guard isActive, isAtRoot, canPresentPendingAction else { return }
    guard pending.matches(model.accountRequestContext) else {
      model.pendingHomeAction = nil
      return
    }
    if pending.action.needsLoadedZones {
      guard !zonesLoading, zonesContext == model.accountRequestContext else { return }
    }
    model.pendingHomeAction = nil
    perform(pending.action)
  }

  private func perform(_ action: HomeActionID) {
    guard !model.isDemoSession else {
      // A quick action is only a launcher; it must not animate from the banner
      // action the user did not tap.
      demoConnectSharedAction = nil
      showsDemoConnect = true
      return
    }

    switch action {
    case .addDomain:
      let scopes = FeatureID.zones.capability.all
      guard model.hasScopes(scopes) else {
        model.requestAccess(to: scopes)
        return
      }
      showsAddDomain = true
    case .uploadR2:
      beginR2Upload()
    case .addDNSRecord:
      guard let context = model.accountRequestContext, zonesContext == context else { return }
      let scopes: Set<String> = ["zone.read", "dns.read", "dns.write"]
      guard model.hasScopes(scopes) else {
        model.requestAccess(to: scopes)
        return
      }
      showsAddDNSRecord = true
    case .createKVKey:
      let scopes = FeatureID.kv.capability.all
      guard model.hasScopes(scopes) else {
        model.requestAccess(to: scopes)
        return
      }
      showsCreateKVKey = true
    case .createR2Bucket:
      let scopes = FeatureID.r2.capability.all
      guard model.hasScopes(scopes) else {
        model.requestAccess(to: scopes)
        return
      }
      showsCreateR2Bucket = true
    case .addPagesDomain:
      let scopes = FeatureID.pages.capability.all
      guard model.hasScopes(scopes) else {
        model.requestAccess(to: scopes)
        return
      }
      showsAddPagesDomain = true
    case .addWorkerDomain:
      let scopes = FeatureID.workers.capability.all.union(["zone.read"])
      guard model.hasScopes(scopes) else {
        model.requestAccess(to: scopes)
        return
      }
      showsAddWorkerDomain = true
    case .enableDevelopmentMode:
      beginZoneMode(scopes: ["zone.read", "zone-settings.write"]) {
        showsEnableDevelopmentMode = true
      }
    case .enableUnderAttackMode:
      beginZoneMode(scopes: ["zone.read", "zone-settings.read", "zone-settings.write"]) {
        showsEnableUnderAttackMode = true
      }
    }
  }

  private func leaveDemoForConnection() {
    Task { await model.signOut() }
  }

  private func presentDemoConnectFromSource() {
    demoConnectSharedAction = HomeDemoConnect.sharedAction
    showsDemoConnect = true
  }

  private func dismissEducationTip(_ tip: HomeEducationTip, accountID: String) {
    guard model.activeAccountID == accountID else { return }
    educationDismissalsRaw = HomeEducation.recordingDismissal(
      tip,
      accountID: accountID,
      in: educationDismissalsRaw
    )
  }

  private func beginZoneMode(scopes: Set<String>, present: () -> Void) {
    guard let context = model.accountRequestContext, zonesContext == context else { return }
    guard model.hasScopes(scopes) else {
      model.requestAccess(to: scopes)
      return
    }
    present()
  }

  private func beginR2Upload() {
    let scopes = FeatureID.r2.capability.all
    guard model.hasScopes(scopes) else {
      model.requestAccess(to: scopes)
      return
    }
    showsR2Upload = true
  }

  private func isLocked(_ feature: FeatureID) -> Bool {
    feature.capability.accessLevel(grantedScopes: model.grantedScopes) == .locked
  }

  private func loadZones(force: Bool = false) async {
    guard let context = model.accountRequestContext else {
      resetZones(for: nil)
      zonesLoading = false
      return
    }
    resetZones(for: context)
    let requestID = UUID()
    zonesRequestID = requestID
    guard !isLocked(.zones) else {
      zones = []
      zonesLoading = false
      zonesError = nil
      return
    }

    let key = FeatureCacheKey.zones(context.accountID)
    if !force, let cached: [CloudflareZone] = model.featureCache.get(key) {
      guard isCurrentZonesRequest(requestID, context: context) else { return }
      zones = cached
      seedPinsIfNeeded(from: cached, accountID: context.accountID)
      zonesLoading = false
      zonesError = nil
      return
    }

    if zones.isEmpty { zonesLoading = true }
    zonesError = nil
    do {
      let page = try await model.client.listZones(
        accountID: context.accountID, page: 1, perPage: ZonesView.pageSize)
      guard isCurrentZonesRequest(requestID, context: context) else { return }
      zones = page.items
      seedPinsIfNeeded(from: page.items, accountID: context.accountID)
      let catalogIsComplete: Bool
      if let totalCount = page.resultInfo?.totalCount {
        catalogIsComplete = page.items.count >= totalCount
      } else {
        catalogIsComplete =
          page.items.count < (page.resultInfo?.perPage ?? ZonesView.pageSize)
      }
      model.featureCache.storeZones(
        page.items,
        accountID: context.accountID,
        catalogIsComplete: catalogIsComplete)
      MetricsWidgetPublisher.syncDomains(
        page.items,
        accountID: context.accountID,
        accountName: model.activeAccount?.name ?? context.accountID,
        replacesCatalog: catalogIsComplete)
    } catch {
      guard
        !error.dashIsCancellation,
        isCurrentZonesRequest(requestID, context: context)
      else { return }
      zonesError = error.dashActionableMessage
    }
    guard isCurrentZonesRequest(requestID, context: context) else { return }
    zonesLoading = false
  }

  private func resetZones(for context: AccountRequestContext?) {
    guard zonesContext != context else { return }
    zonesContext = context
    zonesRequestID = nil
    zones = []
    zonesLoading = context != nil
    zonesError = nil
    showsAddDomain = false
    showsR2Upload = false
    showsAddDNSRecord = false
    showsCreateKVKey = false
    showsCreateR2Bucket = false
    showsAddPagesDomain = false
    showsAddWorkerDomain = false
    showsEnableDevelopmentMode = false
    showsEnableUnderAttackMode = false
    showsDemoConnect = false
    demoConnectSharedAction = nil
  }

  private func isCurrentZonesRequest(
    _ requestID: UUID,
    context: AccountRequestContext
  ) -> Bool {
    !Task.isCancelled
      && zonesRequestID == requestID
      && zonesContext == context
      && model.isCurrentAccount(context)
  }

  /// First non-empty zone load for an account seeds up to four pins so Home
  /// Domains and the Domains grid share a pin-first order without a manual pin.
  private func seedPinsIfNeeded(from loaded: [CloudflareZone], accountID: String) {
    guard !loaded.isEmpty else { return }
    let result = PinnedZones.bootstrapped(
      pinnedZoneData,
      initializedAccountsRaw: pinnedZonesInitialized,
      accountID: accountID,
      defaults: loaded.map {
        PinnedZone(accountID: accountID, zoneID: $0.id, name: $0.name)
      })
    pinnedZoneData = result.pins
    pinnedZonesInitialized = result.initializedAccounts
  }
}

/// Home's greeting: a plain heading that sits in the top light wash.
struct HomeGreetingHeader: View {
  var body: some View {
    Text("What are we doing today?")
      .dashTextStyle(.trayTitle)
      .foregroundStyle(DashTheme.strong)
      .multilineTextAlignment(.center)
      .accessibilityAddTraits(.isHeader)
      .frame(maxWidth: .infinity)
      .padding(.top, DashTheme.Spacing.homeGreetingTop)
      .padding(.bottom, DashTheme.Spacing.homeGreetingBottom)
  }
}

// MARK: - Demo

/// The one production paired tray action. Its source and destination render
/// the same primary control with one stable identity.
private enum HomeDemoConnect {
  static let sourceID = "home-demo-connect"
  static let sharedAction = DashTraySharedAction(
    id: sourceID,
    title: "Connect your account",
    icon: SolarAsset.cloudflare
  )
}

private struct HomeDemoExperienceSection: View {
  let connect: () -> Void

  var body: some View {
    DashCard {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            Text(DashL10n.string("Demo workspace"))
              .dashTextStyle(.bodySemibold)
              .foregroundStyle(DashTheme.strong)
            Text(DashL10n.string("A safe sample account"))
              .dashTextStyle(.footnote)
              .foregroundStyle(DashTheme.subtle)
          }
          Spacer(minLength: 8)
          StatusBadge(.readOnly)
        }

        Text(
          DashL10n.string(
            "Follow one issue from the signal to the affected resource. Changes stay locked until you connect Cloudflare."
          )
        )
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
        .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 0) {
          stepButton(
            number: "01",
            title: DashL10n.string("Review the issue"),
            subtitle: DashL10n.string("Start with the pending domain signal"),
            destination: .watchtowerInbox
          )

          DashListGroupDivider()

          stepButton(
            number: "02",
            title: DashL10n.string("Inspect the resource"),
            subtitle: DashL10n.string("Open api.example.net and review its state"),
            destination: .zone("zone-api")
          )

          DashListGroupDivider()

          stepLabel(
            number: "03",
            title: DashL10n.string("Take action"),
            subtitle: DashL10n.string("Connect your account when you are ready to make changes")
          )
        }

        DashActionButton(
          title: HomeDemoConnect.sharedAction.title,
          icon: HomeDemoConnect.sharedAction.icon,
          action: connect
        )
        .accessibilityIdentifier(HomeDemoConnect.sourceID)
        .dashTraySharedSource(HomeDemoConnect.sharedAction)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("home-demo-guide")
  }

  private func stepButton(
    number: String,
    title: String,
    subtitle: String,
    destination: Destination
  ) -> some View {
    DestinationLink(destination: destination) {
      stepLabel(number: number, title: title, subtitle: subtitle, showsChevron: true)
        .contentShape(Rectangle())
    }
  }

  private func stepLabel(
    number: String,
    title: String,
    subtitle: String,
    showsChevron: Bool = false
  ) -> some View {
    HStack(spacing: 12) {
      Text(number)
        .dashTextStyle(.captionSemibold)
        .foregroundStyle(DashTheme.brand)
        .frame(width: 30, height: 30)
        .background(DashTheme.infoTint, in: Circle())

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .dashTextStyle(.bodyMedium)
          .foregroundStyle(DashTheme.text)
        Text(subtitle)
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.rowSubtitle)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if showsChevron {
        SolarIcon(
          asset: SolarAsset.chevronRight,
          size: DashTheme.Chevron.row,
          color: DashTheme.faint
        )
      }
    }
    .padding(.vertical, 10)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
  }
}

private struct HomeDemoConnectContent: View {
  var body: some View {
    Color.clear
      .frame(height: 1)
      .accessibilityHidden(true)
      .dashTrayDescription(
        DashL10n.string(
          "The demo stays read-only so sample actions cannot change real infrastructure. Return to onboarding to connect Cloudflare and make changes."
        )
      )
  }
}

private struct HomeDemoConnectFooter: View {
  @Environment(\.dashTrayDismiss) private var dismiss
  let connect: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      DashActionButton(
        title: HomeDemoConnect.sharedAction.title,
        icon: HomeDemoConnect.sharedAction.icon,
        action: connect
      )
      .dashTraySharedDestination(HomeDemoConnect.sharedAction)

      DashSecondaryPillButton(
        title: "Keep exploring",
        action: dismiss
      )
    }
  }
}

// MARK: - Quick actions

private struct HomeQuickActionsSection: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let actions: [HomeActionID]
  let navigationDestination: (HomeActionID) -> Destination?
  let perform: (HomeActionID) -> Void
  let edit: () -> Void

  /// Tighter than `itemGap` so the three cards sit as one cluster.
  private static let tileGap: CGFloat = 4

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Spacer(minLength: 0)
        Button(action: edit) {
          SolarIcon(asset: SolarAsset.pen, size: 16, color: DashTheme.brand)
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel(DashL10n.string("Edit"))
        .dashHeaderActionHitTarget()
        .accessibilityIdentifier("home-quick-edit")
      }
      .padding(.horizontal, 4)

      Group {
        if dynamicTypeSize.isAccessibilitySize {
          VStack(spacing: Self.tileGap) { tiles }
        } else {
          HStack(alignment: .top, spacing: Self.tileGap) { tiles }
        }
      }
    }
  }

  @ViewBuilder
  private var tiles: some View {
    if actions.isEmpty {
      Button(action: edit) {
        DashToolTile(
          title: DashL10n.string("Choose actions"), icon: SolarAsset.Content.addCircle)
      }
      .buttonStyle(DashPressButtonStyle())
      .accessibilityIdentifier("home-quick-empty")
      .frame(maxWidth: .infinity)
    } else {
      ForEach(actions) { action in
        if let destination = navigationDestination(action) {
          DashNavigationSource(destination: destination) { navigate in
            quickActionButton(action, action: navigate)
          }
        } else {
          quickActionButton(action) { perform(action) }
        }
      }
    }
  }

  private func quickActionButton(
    _ action: HomeActionID,
    action perform: @escaping () -> Void
  ) -> some View {
    Button(action: perform) {
      DashToolTile(title: action.title, icon: action.icon)
    }
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel(action.title)
    .accessibilityIdentifier(action.accessibilityIdentifier)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

extension HomeActionID {
  /// Zone-picker actions need the Home zones fetch to finish before the tray
  /// can list domains (same guard `perform` uses for DNS / mode trays).
  fileprivate var needsLoadedZones: Bool {
    switch self {
    case .addDNSRecord, .enableDevelopmentMode, .enableUnderAttackMode:
      true
    case .addDomain, .uploadR2, .createKVKey, .createR2Bucket, .addPagesDomain, .addWorkerDomain:
      false
    }
  }

  fileprivate var title: String {
    switch self {
    case .addDomain: DashL10n.string("Add domain")
    case .uploadR2: DashL10n.string("Upload R2")
    case .addDNSRecord: DashL10n.string("Add DNS")
    case .createKVKey: DashL10n.string("Create key")
    case .createR2Bucket: DashL10n.string("New bucket")
    case .addPagesDomain: DashL10n.string("Pages domain")
    case .addWorkerDomain: DashL10n.string("Worker domain")
    case .enableDevelopmentMode: DashL10n.string("Dev mode")
    case .enableUnderAttackMode: DashL10n.string("Under Attack")
    }
  }

  fileprivate var subtitle: String {
    switch self {
    case .addDomain: DashL10n.string("Start a new Cloudflare zone")
    case .uploadR2: DashL10n.string("Choose a file and R2 bucket")
    case .addDNSRecord: DashL10n.string("Add a record to a domain")
    case .createKVKey: DashL10n.string("Write a value to a namespace")
    case .createR2Bucket: DashL10n.string("Create object storage")
    case .addPagesDomain: DashL10n.string("Attach a hostname to Pages")
    case .addWorkerDomain: DashL10n.string("Attach a hostname to a Worker")
    case .enableDevelopmentMode: DashL10n.string("Bypass cache for three hours")
    case .enableUnderAttackMode: DashL10n.string("Challenge every visitor")
    }
  }

  fileprivate var icon: String {
    switch self {
    case .addDomain: SolarAsset.Content.addCircle
    case .uploadR2: SolarAsset.Content.upload
    case .addDNSRecord: SolarAsset.Content.globus
    case .createKVKey: SolarAsset.Content.key
    case .createR2Bucket: SolarAsset.Content.box
    case .addPagesDomain: SolarAsset.Content.codeCircle
    case .addWorkerDomain: SolarAsset.Content.code
    case .enableDevelopmentMode: SolarAsset.Content.slider
    case .enableUnderAttackMode: SolarAsset.Content.shieldCheck
    }
  }

  fileprivate var accessibilityIdentifier: String {
    switch self {
    case .addDomain: "home-quick-add-domain"
    case .uploadR2: "home-quick-upload-r2"
    case .addDNSRecord: "home-quick-add-dns"
    case .createKVKey: "home-quick-create-kv-key"
    case .createR2Bucket: "home-quick-create-r2-bucket"
    case .addPagesDomain: "home-quick-add-pages-domain"
    case .addWorkerDomain: "home-quick-add-worker-domain"
    case .enableDevelopmentMode: "home-quick-enable-development-mode"
    case .enableUnderAttackMode: "home-quick-enable-under-attack-mode"
    }
  }
}

private struct EditHomeActionsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var selectionRaw: String
  /// Draft until Done — ✕ / drag / scrim discard without writing AppStorage.
  @State private var draftRaw: String?
  @State private var didSeedDraft = false

  private var draft: String { draftRaw ?? selectionRaw }

  private var selected: [HomeActionID] {
    HomeActions.decode(draft)
  }

  private var selectedSet: Set<HomeActionID> {
    Set(selected)
  }

  /// Selected first (draft order), then the rest in catalog order — the DNS
  /// filter morph’s sibling: toggling slides a row between the two bands.
  private var orderedItems: [HomeActionID] {
    let rest = HomeActionID.allCases.filter { !selectedSet.contains($0) }
    return selected + rest
  }

  var body: some View {
    DashFormSheet(
      saveTitle: DashL10n.string("Done"),
      onSave: {
        selectionRaw = draft
        dismiss()
      }
    ) {
      HomeEditSelectionList(items: orderedItems) { action in
        let isSelected = selectedSet.contains(action)
        let canToggle = isSelected || selected.count < HomeActions.limit
        HomeEditSelectionRow(
          title: action.title,
          subtitle: action.subtitle,
          isSelected: isSelected,
          isDimmed: !canToggle
        ) {
          HomeActionEditIcon(asset: action.icon)
        } action: {
          guard canToggle else {
            model.toasts.warning(
              DashL10n.string("You can choose up to 3 quick actions"))
            return
          }
          DashDelight.selectionChanged()
          withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morph) {
            draftRaw = HomeActions.toggled(action, in: draft)
          }
        }
      }
    }
    .onAppear {
      guard !didSeedDraft else { return }
      draftRaw = selectionRaw
      didSeedDraft = true
    }
  }
}

/// Viewport metrics for `HomeEditSelectionList` — kept outside the generic
/// view because Swift forbids static stored properties on generic types.
private enum HomeEditSelectionListMetrics {
  /// Three selected slots plus a couple of candidates in view; overflow scrolls.
  static let visibleCount = 5
  /// Matches `HomeEditSelectionRow` at default Dynamic Type (36pt icon + 10pt
  /// vertical padding each side). Larger text shows fewer rows in the same seat.
  static let rowHeight: CGFloat = 56
  static var viewportHeight: CGFloat { rowHeight * CGFloat(visibleCount) }
}

/// Shared edit-tray list chrome for Home Quick actions and Shortcuts.
/// Identity-stable `ForEach`: a draft toggle only reorders the same ids, so
/// `withAnimation` slides survivors into new seats. Do NOT hang `.dashMorph`
/// here — that transition is for appear/disappear (DNS filter). On a reorder
/// its removal scale briefly inflates the measured stack inside the tray's
/// preference→frame height loop and trips AttributeGraph cycles.
///
/// Tall catalogs (nine quick actions) cap to a short viewport so the tray
/// stays compact and the finger scrolls the rest — same shape as the Domains
/// expanded list, nested inside the tray body scroll on purpose.
private struct HomeEditSelectionList<Item: Identifiable, Row: View>: View {
  let items: [Item]
  @ViewBuilder let row: (Item) -> Row

  var body: some View {
    Group {
      if items.count > HomeEditSelectionListMetrics.visibleCount {
        DashFadedScrollView(
          surface: DashTheme.Sheet.background,
          maxHeight: HomeEditSelectionListMetrics.viewportHeight,
          bounceBasedOnSize: true
        ) {
          listStack
        }
      } else {
        listStack
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var listStack: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(items) { item in
        row(item)
      }
    }
  }
}

private struct HomeEditSelectionRow<Icon: View>: View {
  let title: String
  var subtitle: String? = nil
  let isSelected: Bool
  /// Softened look for at-limit quick-action rows. Kept tappable so the caller
  /// can toast the three-slot ceiling instead of swallowing the tap.
  var isDimmed: Bool = false
  @ViewBuilder let icon: () -> Icon
  let action: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 12) {
      Button(action: action) {
        HStack(spacing: 12) {
          icon()
          VStack(alignment: .leading, spacing: 2) {
            Text(title)
              .dashTextStyle(.bodySemibold)
              .foregroundStyle(DashTheme.text)
            if let subtitle {
              Text(subtitle)
                .dashTextStyle(.supporting)
                .foregroundStyle(DashTheme.rowSubtitle)
                .lineLimit(1)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .frame(
          maxWidth: .infinity,
          minHeight: DashTheme.Layout.minimumHitTarget,
          alignment: .leading
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(DashSurfaceButtonStyle())

      // Press shrink belongs to the hollow / check pair only — the row label
      // stays a flat surface so the cue reads on the control that changes.
      Button(action: action) {
        DashSelectionMark(isSelected: isSelected)
          .frame(
            width: DashTheme.Layout.minimumHitTarget,
            height: DashTheme.Layout.minimumHitTarget
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(DashPressButtonStyle())
      .accessibilityHidden(true)
    }
    .opacity(isDimmed ? 0.48 : 1)
    .animation(reduceMotion ? nil : DashTheme.Motion.iconSwap, value: isDimmed)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityValue(
      isSelected ? DashL10n.string("Selected") : DashL10n.string("Not selected")
    )
    .accessibilityAddTraits(.isToggle)
    .accessibilityAction { action() }
  }
}

/// Matches `CatalogFeatureIcon` list tile metrics for Home action glyphs.
private struct HomeActionEditIcon: View {
  let asset: String
  @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

  private var clamp: CGFloat { min(max(scale, 1), 1.3) }

  var body: some View {
    SolarIcon(asset: asset, size: 24 * clamp, color: DashTheme.iconMuted)
      .frame(width: 36 * clamp, height: 36 * clamp)
      .background(DashTheme.iconMuted.opacity(0.1), in: Circle())
      .accessibilityHidden(true)
  }
}

// MARK: - Shortcuts

private struct HomeShortcutsSection: View {
  let features: [FeatureID]
  let edit: () -> Void

  var body: some View {
    DashTwoToneListGroup(
      title: DashL10n.string("Shortcuts"),
      actionTitle: "Edit",
      actionIcon: SolarAsset.pen,
      action: edit
    ) {
      if features.isEmpty {
        Text(DashL10n.string("Choose the Cloudflare features you use most."))
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.subtle)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 16)
      } else {
        ForEach(features) { feature in
          DashListGroupLink(value: .feature(feature)) {
            // Title only — the feature blurb stays on Resources. Height comes
            // from the two-tone card's 44pt list seat.
            FeatureRow(feature: feature, showsSubtitle: false)
          }
        }
      }
    }
  }
}

private struct EditShortcutsView: View {
  @Environment(\.dashTrayDismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var selectionRaw: String
  @AppStorage(DashExperimentalFeatures.tunnelsKey) private var tunnelsExperimentalEnabled =
    false
  /// Draft until Done — ✕ / drag / scrim discard without writing AppStorage.
  @State private var draftRaw: String?
  @State private var didSeedDraft = false

  private var draft: String { draftRaw ?? selectionRaw }

  private var selected: [FeatureID] {
    HomeShortcuts.decode(draft)
  }

  private var selectedSet: Set<FeatureID> {
    Set(selected)
  }

  private var catalogItems: [FeatureID] {
    FeatureCatalog.all.filter {
      DashExperimentalFeatures.isCatalogVisible(
        $0,
        tunnelsEnabled: tunnelsExperimentalEnabled)
    }
  }

  /// Selected first (draft order), then the rest in catalog order.
  private var orderedItems: [FeatureID] {
    let rest = catalogItems.filter { !selectedSet.contains($0) }
    return selected + rest
  }

  var body: some View {
    DashFormSheet(
      saveTitle: DashL10n.string("Done"),
      onSave: {
        selectionRaw = draft
        dismiss()
      }
    ) {
      HomeEditSelectionList(items: orderedItems) { feature in
        HomeEditSelectionRow(
          title: feature.title,
          isSelected: selectedSet.contains(feature)
        ) {
          CatalogFeatureIcon(feature: feature, style: .fill, size: .list)
        } action: {
          DashDelight.selectionChanged()
          withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morph) {
            draftRaw = HomeShortcuts.toggled(feature, in: draft)
          }
        }
      }
    }
    .onAppear {
      guard !didSeedDraft else { return }
      draftRaw = selectionRaw
      didSeedDraft = true
    }
  }
}

// MARK: - Domains

enum HomeDomainsAccess {
  static let recoveryScopes = FeatureID.zones.capability.read
}

private struct HomeDomainsSection: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var avatarTransition
  let zones: [CloudflareZone]
  let pinnedZoneIDs: Set<String>
  let isLoading: Bool
  let error: String?
  let locked: Bool
  @Binding var showsAddDomain: Bool
  let retry: () -> Void
  @State private var isExpanded = false

  private var expandable: Bool {
    !locked && (!zones.isEmpty || isLoading)
  }

  private var canAddDomain: Bool {
    model.hasScopes(FeatureID.zones.capability.write)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      Group {
        if locked {
          lockedRecovery
        } else if let error, zones.isEmpty {
          // Cold failure keeps the same row placeholders the loading state
          // paints and veils the presentation over them — the card never
          // swaps its shape for a notice block.
          failurePlaceholder(message: error)
            .dashFailureRemovalTransition()
        } else if zones.isEmpty, !isLoading {
          emptyDomains
        } else if isExpanded {
          expandedRows
        }
      }
      .padding(.horizontal, DashTheme.Spacing.rowInset)
      if let error, !zones.isEmpty {
        // Warm refresh failure: the cached domains stay, the failure says so
        // beside them instead of vanishing with the spinner.
        DashNotice(kind: .error, message: DashFailurePresentation.from(message: error).message)
          .padding(.horizontal, DashTheme.Spacing.rowInset)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    // Unstroked, like the Shortcuts and Recently used groups below it: the
    // tint fill alone marks the card off from the workspace canvas.
    .background(
      DashTheme.homeDomainsSurface,
      in: RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
    )
  }

  private var header: some View {
    Button {
      withAnimation(reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.morph) {
        isExpanded.toggle()
      }
    } label: {
      HStack(spacing: 12) {
        Text("Domains")
          .dashTextStyle(.supportingMedium)
          .foregroundStyle(DashTheme.listGroupTitle)
        Spacer(minLength: 0)
        if !isExpanded, !dynamicTypeSize.isAccessibilitySize {
          avatarStack
        }
        if expandable {
          SolarIcon(
            asset: SolarAsset.chevronRight, size: DashTheme.Chevron.row, color: DashTheme.faint
          )
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 4)
      .frame(minHeight: 32)
      .contentShape(Rectangle())
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .disabled(!expandable)
    .accessibilityIdentifier("home-domains-toggle")
    .accessibilityLabel("Domains")
    .accessibilityValue(
      expandable
        ? (isExpanded
          ? Text("Expanded")
          : Text("Collapsed, \(zones.count) domains"))
        : Text(verbatim: "")
    )
  }

  @ViewBuilder
  private var avatarStack: some View {
    if locked {
      EmptyView()
    } else if isLoading, zones.isEmpty {
      HStack(spacing: -8) {
        ForEach(0..<3, id: \.self) { _ in
          Circle()
            .fill(DashTheme.recessed)
            .frame(width: 26, height: 26)
            .overlay { Circle().stroke(DashTheme.homeDomainsSurface, lineWidth: 2) }
        }
      }
      .accessibilityHidden(true)
    } else {
      HStack(spacing: -8) {
        ForEach(zones.prefix(Self.collapsedAvatarLimit)) { zone in
          HomeZoneAvatar(seed: zone.name, size: 26)
            .matchedGeometryEffect(id: zone.id, in: avatarTransition)
        }
        if zones.count > Self.collapsedAvatarLimit {
          Circle()
            .fill(DashTheme.recessed)
            .frame(width: 26, height: 26)
            .overlay {
              Text("+\(zones.count - Self.collapsedAvatarLimit)")
                .dashTextStyle(.micro)
                .foregroundStyle(DashTheme.subtle)
                .minimumScaleFactor(0.7)
            }
        }
      }
      .accessibilityHidden(true)
    }
  }

  /// Collapsed header chips + expanded list viewport (more scroll inside).
  private static let collapsedAvatarLimit = 6
  private static let expandedVisibleCount = 6
  /// Matches `HomeDomainRow` (30pt avatar + 12pt vertical padding).
  private static let expandedRowHeight: CGFloat = 54

  /// Cold placeholder matching `HomeDomainRow` rhythm — never a ring. Shared
  /// by the loading state and the failure veil, so the failed card keeps
  /// exactly the shape a successful retry will fill.
  private var domainRowPlaceholders: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(0..<3, id: \.self) { _ in
        HStack(spacing: 12) {
          Circle()
            .fill(DashTheme.recessed)
            .frame(width: 30, height: 30)
          VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .fill(DashTheme.recessed)
              .frame(height: 13)
              .frame(maxWidth: 140)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .fill(DashTheme.recessed.opacity(0.7))
              .frame(height: 11)
              .frame(maxWidth: 90)
          }
          Spacer(minLength: 0)
        }
        .padding(.vertical, DashTheme.Spacing.listRow)
        .frame(minHeight: DashTheme.Layout.minimumHitTarget)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading")
  }

  private var expandedRows: some View {
    Group {
      if isLoading, zones.isEmpty {
        domainRowPlaceholders
      } else if zones.count > Self.expandedVisibleCount {
        HomeDomainsScrollViewport(
          zones: zones,
          pinnedZoneIDs: pinnedZoneIDs,
          avatarTransition: avatarTransition,
          rowHeight: Self.expandedRowHeight,
          visibleCount: Self.expandedVisibleCount
        )
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(zones) { zone in
            DashListGroupLink(value: .zone(zone.id)) {
              HomeDomainRow(
                zone: zone,
                isPinned: pinnedZoneIDs.contains(zone.id),
                avatarTransition: avatarTransition)
            }
          }
        }
      }
    }
  }

  private var lockedRecovery: some View {
    VStack(alignment: .leading, spacing: 10) {
      DashNotice(
        kind: .warning,
        message: DashL10n.string("Grant access to see domains here.")
      )
      DashAuthorizationDisclosure()
      DashSecondaryPillButton(title: DashFailureAction.grantAccess.title) {
        model.requestAccess(to: HomeDomainsAccess.recoveryScopes)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 16)
  }

  private func failurePlaceholder(message: String) -> some View {
    let presentation = DashFailurePresentation.from(message: message)
    // The veil's copy has one message slot; the one-authorization disclosure
    // joins it the way ErrorStateView's does.
    let fullMessage =
      presentation.action == .grantAccess && !model.isDemoSession
      ? [
        presentation.message,
        DashL10n.string(
          "Dash requests all permissions used by its current features in one authorization."
        ),
      ].joined(separator: " ")
      : presentation.message
    return
      domainRowPlaceholders
      .dashSectionFailure(
        fullMessage,
        actionTitle: presentation.action.title,
        retry: { performFailureAction(presentation.action) })
  }

  private func performFailureAction(_ action: DashFailureAction) {
    switch action {
    case .signInAgain:
      Task { await model.signOut() }
    case .grantAccess:
      model.requestAccess(to: HomeDomainsAccess.recoveryScopes)
    case .tryAgain:
      retry()
    }
  }

  private var emptyDomains: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(DashL10n.string("No domains in this account."))
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
        .frame(maxWidth: .infinity, alignment: .leading)
      if canAddDomain {
        DashSecondaryPillButton(title: DashL10n.string("Add domain")) {
          showsAddDomain = true
        }
        .accessibilityIdentifier("home-domains-add-domain")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 16)
  }
}

/// Nested Domains list: fixed-height viewport with shared edge-fade affordance.
private struct HomeDomainsScrollViewport: View {
  let zones: [CloudflareZone]
  let pinnedZoneIDs: Set<String>
  let avatarTransition: Namespace.ID
  var rowHeight: CGFloat
  var visibleCount: Int

  private var viewportHeight: CGFloat { rowHeight * CGFloat(visibleCount) }

  var body: some View {
    DashFadedScrollView(
      surface: DashTheme.homeDomainsSurface,
      maxHeight: viewportHeight,
      bounceBasedOnSize: true
    ) {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(zones) { zone in
          DashListGroupLink(value: .zone(zone.id)) {
            HomeDomainRow(
              zone: zone,
              isPinned: pinnedZoneIDs.contains(zone.id),
              avatarTransition: avatarTransition)
          }
        }
      }
    }
    .accessibilityHint(
      DashL10n.string("Scroll for more domains")
    )
  }
}

/// Stable on-device gradient generated from the domain name.
private struct HomeZoneAvatar: View {
  let seed: String
  var size: CGFloat = 26

  var body: some View {
    GradientAvatar(seed: seed, size: size, pattern: .dither, contentScale: 1.5)
      .accessibilityHidden(true)
  }
}

private struct HomeDomainRow: View {
  let zone: CloudflareZone
  let isPinned: Bool
  let avatarTransition: Namespace.ID
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var accessibilityLabel: String {
    var parts = [zone.name, DashL10n.ui((zone.status ?? "unknown").capitalized)]
    if isPinned { parts.append(DashL10n.string("Pinned")) }
    return parts.joined(separator: ", ")
  }

  private var pinBadge: some View {
    ZStack {
      Circle().fill(DashTheme.homeDomainsSurface)
      Circle().fill(DashTheme.strong).padding(2)
      SolarIcon(asset: SolarAsset.pinFilled, size: 8, color: DashTheme.inverse)
    }
    .frame(width: 15, height: 15)
    .offset(x: 2, y: 2)
    .accessibilityHidden(true)
  }

  var body: some View {
    HStack(spacing: 12) {
      // Match `DashListRow` zone avatars in Recently used (30pt disc).
      HomeZoneAvatar(seed: zone.name, size: 30)
        .matchedGeometryEffect(id: zone.id, in: avatarTransition)
        // Keep the row-only marker out of the collapsed avatar's geometry flight.
        .overlay(alignment: .bottomTrailing) {
          if isPinned { pinBadge }
        }
      VStack(alignment: .leading, spacing: 2) {
        Text(zone.name)
          .dashTextStyle(.bodyMedium)
          .foregroundStyle(DashTheme.text)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        // Matches ZoneViews' zone-detail rendering — Home used to show the raw
        // API token, so the same zone read "Active" here and 正常 one push in.
        Text(DashL10n.ui((zone.status ?? "unknown").capitalized))
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.rowSubtitle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, DashTheme.Spacing.listRow)
    .frame(minHeight: DashTheme.Layout.twoToneListRow)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }
}

// MARK: - Contextual education

private struct HomeEducationTipCard: View {
  let tip: HomeEducationTip
  let dismiss: () -> Void

  var body: some View {
    DashCard {
      HStack(alignment: .top, spacing: 12) {
        SolarIcon(asset: icon, size: 24, color: DashTheme.brand)
          .frame(width: 36, height: 36)
          .background(DashTheme.brand.opacity(0.1), in: Circle())
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .dashTextStyle(.bodySemibold)
            .foregroundStyle(DashTheme.strong)
          Text(message)
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.rowSubtitle)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        DashCloseButton(
          accessibilityLabel: DashL10n.string("Dismiss tip"),
          action: dismiss
        )
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("home-education-r2-share")
  }

  private var icon: String {
    switch tip {
    case .r2ShareExtension: SolarAsset.Content.upload
    }
  }

  private var title: String {
    switch tip {
    case .r2ShareExtension: DashL10n.string("Upload from any app")
    }
  }

  private var message: String {
    switch tip {
    case .r2ShareExtension:
      DashL10n.string(
        "From Photos or Files, tap Share and choose Dash to upload straight to R2.")
    }
  }
}

// MARK: - Recently used

/// Recent drill-downs for the active account, fed by `RecentResources`. Zone
/// rows skip morph sources: Domains expand + HomeDomainRow already own those
/// zone identities on this screen, and a second source for the same id makes
/// the animations fight. Non-zone recents still fly into their detail headers.
private struct HomeRecentsSection: View {
  let recents: [RecentResource]
  let onReopen: (RecentResource) -> Void

  var body: some View {
    DashTwoToneListGroup(title: "Recently used") {
      ForEach(recents) { resource in
        DashListGroupLink(
          value: resource.destination,
          onNavigate: { onReopen(resource) }
        ) {
          DashListRow(
            title: resource.title,
            subtitle: resource.kind.displayName,
            icon: resource.kind.listIcon,
            iconColor: FeatureVisualIdentity.catalogColor(for: resource.featureID),
            avatarSeed: resource.kind == .zone ? resource.title : nil
          )
        }
      }
    }
  }
}

struct FeatureRow: View {
  enum Presentation {
    /// Saturated card — reserved for rare hero moments.
    case vividCard
    /// Neutral catalog row: color lives on the icon tile and status only.
    case catalog
  }

  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.dashTwoToneListRows) private var inTwoToneList
  let feature: FeatureID
  var iconStyle: CatalogFeatureIcon.Style = .fill
  var presentation: Presentation = .catalog
  /// Resources keeps the feature blurb; Home Shortcuts drops it. Row height
  /// follows `dashTwoToneListRows` (60 inside eyebrow cards, 72 elsewhere).
  var showsSubtitle: Bool = true

  private var accessLevel: FeatureAccessLevel {
    feature.capability.accessLevel(grantedScopes: model.grantedScopes)
  }

  private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

  private var onCard: Color { FeatureVisualIdentity.onCardColor(for: feature) }

  var body: some View {
    Group {
      switch presentation {
      case .vividCard: vividCardBody
      case .catalog: catalogBody
      }
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  private var vividCardBody: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        CatalogFeatureIcon(
          feature: feature, style: iconStyle, emphasized: true
        )
        .opacity(accessLevel == .locked ? 0.55 : 1)
        Spacer(minLength: 0)
        accessBadge
      }
      vividLabels
    }
    .padding(.vertical, 14)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
    .dashListItemCard(fill: FeatureVisualIdentity.cardColor(for: feature))
  }

  private var catalogBody: some View {
    Group {
      if isAccessibilitySize && showsSubtitle {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 12) {
            featureChrome
            Spacer(minLength: 0)
            accessBadge
          }
          catalogSubtitle
        }
      } else {
        HStack(spacing: 12) {
          featureChrome
          accessBadge
        }
      }
    }
    .padding(.vertical, DashTheme.Spacing.listRow)
    .frame(
      minHeight: inTwoToneList
        ? DashTheme.Layout.twoToneListRow : DashTheme.Layout.subtitledListRow
    )
  }

  private var featureChrome: some View {
    HStack(spacing: 12) {
      CatalogFeatureIcon(feature: feature, style: iconStyle, size: .list)
        .opacity(accessLevel == .locked ? 0.55 : 1)
      VStack(alignment: .leading, spacing: 2) {
        Text(feature.title)
          .dashTextStyle(.bodySemibold)
          .foregroundStyle(DashTheme.text)
          .lineLimit(isAccessibilitySize ? nil : 1)
        if showsSubtitle, !isAccessibilitySize {
          catalogSubtitle
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var vividLabels: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(feature.title)
        .dashTextStyle(.bodySemibold)
        .foregroundStyle(onCard)
        .lineLimit(isAccessibilitySize ? nil : 1)
      if showsSubtitle {
        Text(feature.subtitle)
          .dashTextStyle(.supporting)
          .foregroundStyle(onCard.opacity(0.75))
          .lineLimit(isAccessibilitySize ? nil : 2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var catalogSubtitle: some View {
    Group {
      if isAccessibilitySize {
        Text(feature.subtitle)
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.rowSubtitle)
      } else {
        DashGreedyWrapText(text: feature.subtitle)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var accessBadge: some View {
    switch accessLevel {
    case .full:
      EmptyView()
    case .readOnly:
      StatusBadge(.readOnly)
    case .locked:
      StatusBadge(.locked)
    }
  }

  private var accessibilityLabel: String {
    if showsSubtitle {
      "\(feature.title), \(feature.subtitle), \(accessAccessibilityValue)"
    } else {
      "\(feature.title), \(accessAccessibilityValue)"
    }
  }

  private var accessAccessibilityValue: String {
    switch accessLevel {
    case .full: "Available"
    case .readOnly: StatusToken.readOnly.label
    case .locked: StatusToken.locked.label
    }
  }
}
