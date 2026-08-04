import CloudflareAPI
import GradientAvatars
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.destinationNavigator) private var navigator
  let isActive: Bool
  let isAtRoot: Bool
  /// A deep-linked action may arrive while Profile or another tray is still
  /// leaving. Keep it queued until the app-level tray preference clears so two
  /// independent full-screen covers never compete for the one compact tray.
  let canPresentPendingAction: Bool
  @AppStorage(RecentResources.key) private var recentsRaw = ""
  @AppStorage(HomeShortcuts.key) private var shortcutsRaw = HomeShortcuts.defaultValue
  @AppStorage(HomeActions.key) private var actionsRaw = HomeActions.defaultValue
  @AppStorage(HomeEducation.dismissalsKey) private var educationDismissalsRaw = ""
  @AppStorage(DashExperimentalFeatures.tunnelsKey) private var tunnelsExperimentalEnabled =
    false
  @State private var zones: [CloudflareZone] = []
  @State private var zonesLoading = true
  @State private var zonesError: String?
  @State private var zonesContext: AccountRequestContext?
  @State private var zonesRequestID: UUID?
  @State private var showsAddDomain = false
  @State private var showsR2Upload = false
  @State private var showsPurgeCache = false
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

  private var recents: [RecentResource] {
    guard let accountID = model.activeAccountID else { return [] }
    return RecentResources.visible(in: recentsRaw, accountID: accountID)
  }

  private var shortcuts: [FeatureID] {
    HomeShortcuts.decode(shortcutsRaw).filter {
      DashExperimentalFeatures.isCatalogVisible(
        $0, tunnelsEnabled: tunnelsExperimentalEnabled)
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
            openIssue: { navigator?.push(.watchtowerInbox) },
            openResource: { navigator?.push(.zone("zone-api")) },
            connect: { showsDemoConnect = true }
          )
          .dashSectionReveal(1)
        }

        HomeQuickActionsSection(
          actions: quickActions,
          perform: perform,
          edit: { showsEditActions = true }
        )
        .dashSectionReveal(1 + revealOffset)

        HomeDomainsSection(
          zones: zones,
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
        model.featureCache.remove(FeatureCacheKey.zones(accountID))
        Task { await loadZones(force: true) }
      }
    }
    // Quick-action trays grow out of their tiles (`sourceID` pairs with the
    // tile's `.dashTraySource`). Add Domain stays unanchored: the Domains
    // section opens the same tray, so it has no single source of truth.
    .dashTray(
      isPresented: $showsR2Upload, title: DashL10n.string("Upload to R2"),
      tone: FeatureVisualIdentity.tone(for: .r2),
      sourceID: HomeActionID.uploadR2.accessibilityIdentifier
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
      isPresented: $showsPurgeCache, title: DashL10n.string("Purge cache"),
      tone: FeatureVisualIdentity.tone(for: .zones),
      sourceID: HomeActionID.purgeCache.accessibilityIdentifier
    ) {
      HomePurgeCachePicker(zones: zones) { zone in
        guard zonesContext == model.accountRequestContext else {
          showsPurgeCache = false
          return
        }
        navigator?.push(.cache(zone.id))
      }
    }
    .dashTray(
      isPresented: $showsAddDNSRecord, title: DashL10n.string("Add DNS record"),
      tone: FeatureVisualIdentity.tone(for: .zones),
      sourceID: HomeActionID.addDNSRecord.accessibilityIdentifier
    ) {
      HomeDNSRecordAction(zones: zones)
    }
    .dashTray(
      isPresented: $showsCreateKVKey, title: DashL10n.string("Create KV key"),
      tone: FeatureVisualIdentity.tone(for: .kv),
      sourceID: HomeActionID.createKVKey.accessibilityIdentifier
    ) {
      HomeCreateKVKeyAction()
    }
    .dashTray(
      isPresented: $showsCreateR2Bucket, title: DashL10n.string("Create R2 bucket"),
      tone: FeatureVisualIdentity.tone(for: .r2),
      sourceID: HomeActionID.createR2Bucket.accessibilityIdentifier
    ) {
      R2CreateBucketSheet(onCreated: {})
    }
    .dashTray(
      isPresented: $showsAddPagesDomain, title: DashL10n.string("Add Pages domain"),
      tone: FeatureVisualIdentity.tone(for: .pages),
      sourceID: HomeActionID.addPagesDomain.accessibilityIdentifier
    ) {
      HomePagesDomainAction()
    }
    .dashTray(
      isPresented: $showsAddWorkerDomain, title: DashL10n.string("Attach Worker domain"),
      tone: FeatureVisualIdentity.tone(for: .workers),
      sourceID: HomeActionID.addWorkerDomain.accessibilityIdentifier
    ) {
      HomeWorkerDomainAction()
    }
    .dashTray(
      isPresented: $showsEnableDevelopmentMode, title: DashL10n.string("Development mode"),
      tone: FeatureVisualIdentity.tone(for: .zones),
      sourceID: HomeActionID.enableDevelopmentMode.accessibilityIdentifier
    ) {
      HomeZoneModeAction(zones: zones, mode: .development)
    }
    .dashTray(
      isPresented: $showsEnableUnderAttackMode, title: DashL10n.string("Under Attack mode"),
      tone: FeatureVisualIdentity.tone(for: .zones),
      sourceID: HomeActionID.enableUnderAttackMode.accessibilityIdentifier
    ) {
      HomeZoneModeAction(zones: zones, mode: .underAttack)
    }
    .dashTray(
      isPresented: $showsEditActions, title: DashL10n.string("Edit quick actions")
    ) {
      EditHomeActionsView(selectionRaw: $actionsRaw)
    }
    .dashTray(isPresented: $showsEditShortcuts, title: DashL10n.string("Edit shortcuts")) {
      EditShortcutsView(selectionRaw: $shortcutsRaw)
    }
    .dashTray(isPresented: $showsDemoConnect, title: DashL10n.string("Connect your account")) {
      HomeDemoConnectContent(connect: leaveDemoForConnection)
    }
    .onChange(of: actionsRaw) { _, newValue in
      ICloudPreferencesSync.shared.publish(.homeActions)
      HomeActions.mirrorToAppGroup(newValue)
    }
    .onChange(of: shortcutsRaw) { _, _ in
      ICloudPreferencesSync.shared.publish(.homeShortcuts)
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
    case .purgeCache:
      beginPurgeCache()
    }
  }

  private func leaveDemoForConnection() {
    Task { await model.signOut() }
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

  private func beginPurgeCache() {
    guard let context = model.accountRequestContext, zonesContext == context else { return }
    let scopes: Set<String> = ["zone.read", "cache.purge"]
    guard model.hasScopes(scopes) else {
      model.requestAccess(to: scopes)
      return
    }
    if zones.count == 1, let zone = zones.first {
      navigator?.push(.cache(zone.id))
    } else {
      showsPurgeCache = true
    }
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
      model.featureCache.storeZones(page.items, accountID: context.accountID)
      let catalogIsComplete: Bool
      if let totalCount = page.resultInfo?.totalCount {
        catalogIsComplete = page.items.count >= totalCount
      } else {
        catalogIsComplete =
          page.items.count < (page.resultInfo?.perPage ?? ZonesView.pageSize)
      }
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
    showsPurgeCache = false
    showsAddDNSRecord = false
    showsCreateKVKey = false
    showsCreateR2Bucket = false
    showsAddPagesDomain = false
    showsAddWorkerDomain = false
    showsEnableDevelopmentMode = false
    showsEnableUnderAttackMode = false
    showsDemoConnect = false
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

private struct HomeDemoExperienceSection: View {
  let openIssue: () -> Void
  let openResource: () -> Void
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
            action: openIssue
          )

          DashListGroupDivider()

          stepButton(
            number: "02",
            title: DashL10n.string("Inspect the resource"),
            subtitle: DashL10n.string("Open api.example.net and review its state"),
            action: openResource
          )

          DashListGroupDivider()

          stepLabel(
            number: "03",
            title: DashL10n.string("Take action"),
            subtitle: DashL10n.string("Connect your account when you are ready to make changes")
          )
        }

        DashPillButton(
          title: "Connect your account",
          icon: SolarAsset.cloudflare,
          action: connect
        )
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("home-demo-guide")
  }

  private func stepButton(
    number: String,
    title: String,
    subtitle: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      stepLabel(number: number, title: title, subtitle: subtitle, showsChevron: true)
        .contentShape(Rectangle())
    }
    .buttonStyle(DashSurfaceButtonStyle())
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
  @Environment(\.dashTrayDismiss) private var dismiss
  let connect: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      DashPillButton(
        title: "Return to connect",
        icon: SolarAsset.cloudflare,
        action: connect
      )

      DashSecondaryPillButton(
        title: "Keep exploring",
        action: dismiss
      )
    }
    .dashTrayDescription(
      DashL10n.string(
        "The demo stays read-only so sample actions cannot change real infrastructure. Return to onboarding to connect Cloudflare and make changes."
      )
    )
  }
}

// MARK: - Quick actions

private struct HomeQuickActionsSection: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let actions: [HomeActionID]
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
        Button {
          perform(action)
        } label: {
          DashToolTile(title: action.title, icon: action.icon)
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel(action.title)
        .accessibilityIdentifier(action.accessibilityIdentifier)
        .frame(maxWidth: .infinity)
        // Anchor for the tray's grow-out-of-the-tile reveal; the tray pairs
        // with this tile through the same stable identifier.
        .dashTraySource(id: action.accessibilityIdentifier)
      }
    }
  }
}

extension HomeActionID {
  /// Zone-picker actions need the Home zones fetch to finish before the tray
  /// can list domains (same guard `perform` uses for DNS / mode / purge).
  fileprivate var needsLoadedZones: Bool {
    switch self {
    case .addDNSRecord, .enableDevelopmentMode, .enableUnderAttackMode, .purgeCache:
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
    case .purgeCache: DashL10n.string("Purge cache")
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
    case .purgeCache: DashL10n.string("Clear cached assets for a domain")
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
    case .purgeCache: SolarAsset.Content.bolt
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
    case .purgeCache: "home-quick-purge-cache"
    }
  }
}

private struct EditHomeActionsView: View {
  @Environment(\.dashTrayDismiss) private var dismiss
  @Binding var selectionRaw: String

  private var selection: [HomeActionID] {
    HomeActions.decode(selectionRaw)
  }

  var body: some View {
    // Quick actions and shortcuts share the same compact tray and selection rows.
    DashFormSheet(saveTitle: DashL10n.string("Done"), onSave: dismiss) {
      HomeEditSelectionList(items: Array(HomeActionID.allCases)) { action in
        let isSelected = selection.contains(action)
        let canToggle = isSelected || selection.count < HomeActions.limit
        HomeEditSelectionRow(
          title: action.title,
          subtitle: action.subtitle,
          isSelected: isSelected,
          isEnabled: canToggle
        ) {
          HomeActionEditIcon(asset: action.icon)
        } action: {
          selectionRaw = HomeActions.toggled(action, in: selectionRaw)
        }
      }
    }
  }
}

/// Shared edit-tray list chrome for Home Quick actions and Shortcuts.
private struct HomeEditSelectionList<Item: Identifiable, Row: View>: View {
  let items: [Item]
  @ViewBuilder let row: (Item) -> Row

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        row(item)
        if index < items.count - 1 {
          DashListGroupDivider()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct HomeEditSelectionRow<Icon: View>: View {
  let title: String
  let subtitle: String
  let isSelected: Bool
  var isEnabled: Bool = true
  @ViewBuilder let icon: () -> Icon
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        icon()
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .dashTextStyle(.bodySemibold)
            .foregroundStyle(DashTheme.text)
          Text(subtitle)
            .dashTextStyle(.supporting)
            .foregroundStyle(DashTheme.rowSubtitle)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 21, weight: .semibold))
          .foregroundStyle(isSelected ? DashTheme.brand : DashTheme.faint)
      }
      .padding(.vertical, 10)
      .frame(minHeight: DashTheme.Layout.minimumHitTarget)
      .contentShape(Rectangle())
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.48)
    .accessibilityValue(
      isSelected ? DashL10n.string("Selected") : DashL10n.string("Not selected")
    )
    .accessibilityAddTraits(.isToggle)
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
            FeatureRow(feature: feature)
          }
        }
      }
    }
  }
}

private struct EditShortcutsView: View {
  @Environment(\.dashTrayDismiss) private var dismiss
  @Binding var selectionRaw: String
  @AppStorage(DashExperimentalFeatures.tunnelsKey) private var tunnelsExperimentalEnabled =
    false

  private var selected: Set<FeatureID> {
    Set(HomeShortcuts.decode(selectionRaw))
  }

  private var catalogItems: [FeatureID] {
    FeatureCatalog.all.filter {
      DashExperimentalFeatures.isCatalogVisible(
        $0, tunnelsEnabled: tunnelsExperimentalEnabled)
    }
  }

  var body: some View {
    DashFormSheet(saveTitle: DashL10n.string("Done"), onSave: dismiss) {
      HomeEditSelectionList(items: catalogItems) { feature in
        HomeEditSelectionRow(
          title: feature.title,
          subtitle: feature.subtitle,
          isSelected: selected.contains(feature)
        ) {
          CatalogFeatureIcon(feature: feature, style: .fill, size: .list)
        } action: {
          selectionRaw = HomeShortcuts.toggled(feature, in: selectionRaw)
        }
      }
    }
  }
}

// MARK: - Home operations

private struct HomeDNSRecordAction: View {
  @Environment(AppModel.self) private var model
  let zones: [CloudflareZone]
  @State private var selectedZoneID: String?

  init(zones: [CloudflareZone]) {
    self.zones = zones
    _selectedZoneID = State(initialValue: zones.count == 1 ? zones.first?.id : nil)
  }

  var body: some View {
    Group {
      if let selectedZoneID {
        DNSRecordEditor(zoneID: selectedZoneID, record: nil) {
          model.featureCache.remove(FeatureCacheKey.dnsRecords(selectedZoneID))
        }
      } else if zones.isEmpty {
        DashNotice(
          kind: .warning,
          message: DashL10n.string("Add a domain before creating a DNS record."))
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(zones.enumerated()), id: \.element.id) { index, zone in
            Button {
              selectedZoneID = zone.id
            } label: {
              DashListRow(
                title: zone.name,
                subtitle: (zone.status ?? "unknown").capitalized,
                avatarSeed: zone.name
              )
            }
            .buttonStyle(DashSurfaceButtonStyle())
            if index < zones.count - 1 {
              DashListGroupDivider()
            }
          }
        }
        .dashTrayDescription(DashL10n.string("Choose the domain for the new DNS record."))
      }
    }
  }
}

private struct HomeCreateKVKeyAction: View {
  @Environment(AppModel.self) private var model
  @State private var namespaces: [KVNamespace] = []
  @State private var selectedNamespaceID: String?
  @State private var loading = true
  @State private var error: String?
  @State private var loadedContext: AccountRequestContext?

  var body: some View {
    Group {
      if loadedContext != model.accountRequestContext {
        HomeActionLoadingRow(title: DashL10n.string("Loading KV namespaces…"))
      } else if let selectedNamespaceID {
        KVCreateKeySheet(namespaceID: selectedNamespaceID) {
          guard let context = loadedContext, model.isCurrentAccount(context) else { return }
          model.featureCache.remove(
            prefix: "kvKeys:\(context.accountID):\(selectedNamespaceID):")
        }
      } else if loading {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text("Loading KV namespaces…")
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
      } else if let error {
        DashNotice(kind: .error, message: error)
      } else if namespaces.isEmpty {
        DashNotice(
          kind: .warning,
          message: DashL10n.string("Create a KV namespace before adding a key."))
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(namespaces.enumerated()), id: \.element.id) { index, namespace in
            Button {
              selectedNamespaceID = namespace.id
            } label: {
              DashListRow(
                title: namespace.title,
                subtitle: DashL10n.string("KV namespace"),
                icon: SolarAsset.Content.pinList
              )
            }
            .buttonStyle(DashSurfaceButtonStyle())
            if index < namespaces.count - 1 {
              DashListGroupDivider()
            }
          }
        }
        .dashTrayDescription(DashL10n.string("Choose the namespace for the new key."))
      }
    }
    .task(id: model.accountRequestContext) {
      prepareForCurrentAccount()
      await loadNamespaces()
    }
  }

  private func loadNamespaces() async {
    guard let context = model.accountRequestContext else {
      loading = false
      return
    }
    let key = FeatureCacheKey.kvNamespaces(context.accountID)
    if let cached: [KVNamespace] = model.featureCache.get(key) {
      guard model.isCurrentAccount(context) else { return }
      apply(cached, context: context)
      return
    }
    let client = model.client
    do {
      let loaded = try await client.listKVNamespaces(accountID: context.accountID).items
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      model.featureCache.set(key, loaded)
      apply(loaded, context: context)
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
      loading = false
    }
  }

  private func apply(_ loaded: [KVNamespace], context: AccountRequestContext) {
    guard model.isCurrentAccount(context), loadedContext == context else { return }
    namespaces = loaded
    selectedNamespaceID = loaded.count == 1 ? loaded.first?.id : nil
    loading = false
  }

  private func prepareForCurrentAccount() {
    let context = model.accountRequestContext
    guard loadedContext != context else { return }
    loadedContext = context
    namespaces = []
    selectedNamespaceID = nil
    loading = context != nil
    error = nil
  }
}

private struct HomePagesDomainAction: View {
  @Environment(AppModel.self) private var model
  @State private var projects: [PagesProject] = []
  @State private var selectedProject: String?
  @State private var loading = true
  @State private var error: String?
  @State private var loadedContext: AccountRequestContext?

  var body: some View {
    Group {
      if loadedContext != model.accountRequestContext {
        HomeActionLoadingRow(title: DashL10n.string("Loading Pages projects…"))
      } else if let selectedProject {
        PagesAddDomainForm(projectName: selectedProject, onAdded: {})
      } else {
        actionPicker
      }
    }
    .task(id: model.accountRequestContext) {
      prepareForCurrentAccount()
      await load()
    }
  }

  @ViewBuilder private var actionPicker: some View {
    if loading {
      HomeActionLoadingRow(title: DashL10n.string("Loading Pages projects…"))
    } else if let error {
      DashNotice(kind: .error, message: error)
    } else if projects.isEmpty {
      DashNotice(
        kind: .warning,
        message: DashL10n.string("Create a Pages project before attaching a domain."))
    } else {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
          Button {
            selectedProject = project.name
          } label: {
            DashListRow(
              title: project.name,
              subtitle: project.subdomain,
              icon: SolarAsset.Content.codeCircle
            )
          }
          .buttonStyle(DashSurfaceButtonStyle())
          if index < projects.count - 1 { DashListGroupDivider() }
        }
      }
      .dashTrayDescription(DashL10n.string("Choose the Pages project for the custom domain."))
    }
  }

  private func load() async {
    guard let context = model.accountRequestContext else {
      loading = false
      return
    }
    let key = FeatureCacheKey.pagesProjects(context.accountID)
    if let cached: [PagesProject] = model.featureCache.get(key) {
      apply(cached, context: context)
      return
    }
    let client = model.client
    do {
      let loaded = try await client.listPagesProjects(accountID: context.accountID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      model.featureCache.set(key, loaded)
      apply(loaded, context: context)
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
      loading = false
    }
  }

  private func apply(_ loaded: [PagesProject], context: AccountRequestContext) {
    guard model.isCurrentAccount(context), loadedContext == context else { return }
    projects = loaded
    selectedProject = loaded.count == 1 ? loaded.first?.name : nil
    loading = false
  }

  private func prepareForCurrentAccount() {
    let context = model.accountRequestContext
    guard loadedContext != context else { return }
    loadedContext = context
    projects = []
    selectedProject = nil
    loading = context != nil
    error = nil
  }
}

private struct HomeWorkerDomainAction: View {
  @Environment(AppModel.self) private var model
  @State private var workers: [WorkerScript] = []
  @State private var selectedWorker: String?
  @State private var loading = true
  @State private var error: String?
  @State private var loadedContext: AccountRequestContext?

  var body: some View {
    Group {
      if loadedContext != model.accountRequestContext {
        HomeActionLoadingRow(title: DashL10n.string("Loading Workers…"))
      } else if let selectedWorker {
        WorkerAddDomainForm(service: selectedWorker, onAdded: {})
      } else {
        actionPicker
      }
    }
    .task(id: model.accountRequestContext) {
      prepareForCurrentAccount()
      await load()
    }
  }

  @ViewBuilder private var actionPicker: some View {
    if loading {
      HomeActionLoadingRow(title: DashL10n.string("Loading Workers…"))
    } else if let error {
      DashNotice(kind: .error, message: error)
    } else if workers.isEmpty {
      DashNotice(
        kind: .warning,
        message: DashL10n.string("Deploy a Worker before attaching a domain."))
    } else {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(workers.enumerated()), id: \.element.id) { index, worker in
          Button {
            selectedWorker = worker.id
          } label: {
            DashListRow(title: worker.id, icon: SolarAsset.Content.code)
          }
          .buttonStyle(DashSurfaceButtonStyle())
          if index < workers.count - 1 { DashListGroupDivider() }
        }
      }
      .dashTrayDescription(DashL10n.string("Choose the Worker for the custom domain."))
    }
  }

  private func load() async {
    guard let context = model.accountRequestContext else {
      loading = false
      return
    }
    let key = FeatureCacheKey.workers(context.accountID)
    if let cached: [WorkerScript] = model.featureCache.get(key) {
      apply(cached, context: context)
      return
    }
    let client = model.client
    do {
      let loaded = try await client.listWorkers(accountID: context.accountID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      model.featureCache.set(key, loaded)
      apply(loaded, context: context)
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
      loading = false
    }
  }

  private func apply(_ loaded: [WorkerScript], context: AccountRequestContext) {
    guard model.isCurrentAccount(context), loadedContext == context else { return }
    workers = loaded
    selectedWorker = loaded.count == 1 ? loaded.first?.id : nil
    loading = false
  }

  private func prepareForCurrentAccount() {
    let context = model.accountRequestContext
    guard loadedContext != context else { return }
    loadedContext = context
    workers = []
    selectedWorker = nil
    loading = context != nil
    error = nil
  }
}

private struct HomeZoneModeAction: View {
  enum Mode {
    case development
    case underAttack

    var actionTitle: String {
      switch self {
      case .development: DashL10n.string("Enable dev mode")
      case .underAttack: DashL10n.string("Enable Under Attack")
      }
    }

    var warning: String {
      switch self {
      case .development:
        DashL10n.string(
          "Cloudflare will bypass cache for this domain and turn Development Mode off automatically after three hours."
        )
      case .underAttack:
        DashL10n.string(
          "Cloudflare will challenge every visitor. You can restore the previous security level from the domain's WAF screen."
        )
      }
    }
  }

  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let zones: [CloudflareZone]
  let mode: Mode
  @State private var selectedZoneID: String?
  @State private var actionPhase: DashActionPhase = .idle
  @State private var result: String?
  @State private var pendingResult: String?
  @State private var error: String?

  init(zones: [CloudflareZone], mode: Mode) {
    self.zones = zones
    self.mode = mode
    _selectedZoneID = State(initialValue: zones.count == 1 ? zones.first?.id : nil)
  }

  var body: some View {
    Group {
      if let zone = zones.first(where: { $0.id == selectedZoneID }) {
        DashFormSheet(
          saveTitle: result == nil ? mode.actionTitle : DashL10n.string("Done"),
          actionPhase: actionPhase,
          onSuccessPresentationCompleted: completeSuccessPresentation,
          onSave: {
            if result == nil {
              Task { await enable(for: zone) }
            } else {
              dismiss()
            }
          }
        ) {
          VStack(alignment: .leading, spacing: 14) {
            if let result {
              DashNotice(kind: .success, message: result)
            } else {
              DashNotice(kind: .warning, message: mode.warning)
              Text(zone.name)
                .dashTextStyle(.bodySemibold)
                .foregroundStyle(DashTheme.text)
            }
            if let error {
              DashNotice(kind: .error, message: error)
            }
          }
        }
      } else if zones.isEmpty {
        DashNotice(
          kind: .warning,
          message: DashL10n.string("Add a domain before changing this mode."))
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(zones.enumerated()), id: \.element.id) { index, zone in
            Button {
              selectedZoneID = zone.id
            } label: {
              DashListRow(
                title: zone.name,
                subtitle: (zone.status ?? "unknown").capitalized,
                avatarSeed: zone.name
              )
            }
            .buttonStyle(DashSurfaceButtonStyle())
            if index < zones.count - 1 { DashListGroupDivider() }
          }
        }
        .dashTrayDescription(DashL10n.string("Choose the domain to update."))
      }
    }
  }

  private func enable(for zone: CloudflareZone) async {
    guard let context = model.accountRequestContext else { return }
    let client = model.client
    actionPhase = .loading
    error = nil
    let op = model.optimistic.begin(.enabling)
    do {
      try await model.optimistic.waitForCommit(op)
      let successMessage: String
      switch mode {
      case .development:
        _ = try await client.updateZoneSetting(
          zoneID: zone.id, settingID: "development_mode", value: .string("on"))
        guard !Task.isCancelled, model.isCurrentAccount(context) else {
          actionPhase = .idle
          model.optimistic.finishFailure(op)
          return
        }
        successMessage = DashL10n.string("Development Mode is on for \(zone.name).")
      case .underAttack:
        _ = try await ZoneSecurityLevelOperation.setUnderAttack(
          zoneID: zone.id,
          enabled: true,
          client: client,
          isCurrent: { model.isCurrentAccount(context) })
        guard !Task.isCancelled, model.isCurrentAccount(context) else {
          actionPhase = .idle
          model.optimistic.finishFailure(op)
          return
        }
        successMessage = DashL10n.string("Under Attack mode is on for \(zone.name).")
      }
      model.featureCache.remove(FeatureCacheKey.zoneSettings(zone.id))
      pendingResult = successMessage
      model.optimistic.finishSuccess(op)
      actionPhase = .succeeded
    } catch is CancellationError {
      actionPhase = .idle
    } catch {
      actionPhase = .idle
      model.optimistic.finishFailure(op)
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func completeSuccessPresentation() {
    guard actionPhase == .succeeded, let pendingResult else { return }
    result = pendingResult
    self.pendingResult = nil
    actionPhase = .idle
  }
}

private struct HomeActionLoadingRow: View {
  let title: String

  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text(title)
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 12)
  }
}

/// Starts a real upload from Home instead of merely opening the R2 catalog.
/// The last-used bucket/folder is preferred, but the destination stays explicit
/// and editable so a one-tap shortcut never writes to a surprising bucket.
private struct HomeR2UploadRequest: Sendable {
  let context: AccountRequestContext
  let bucket: String
  let prefix: String
  let fileURL: URL
  let destination: R2ShareDestination

  var key: String { prefix + fileURL.lastPathComponent }
}

private struct HomeR2UploadSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let onUploaded: (String) -> Void
  @State private var buckets: [R2Bucket] = []
  @State private var selectedBucket = ""
  /// Chosen destination folder as a key prefix (trailing `/`), `""` at the
  /// bucket root. Seeded from the last-used destination, then owned by the
  /// picker — Home writes wherever the user points it, not only to the root.
  @State private var folderPrefix = ""
  /// Folders directly inside `folderPrefix`, so the picker can go deeper.
  @State private var childFolders: [String] = []
  /// A folder listing that threw. Empty and failed are different answers: a
  /// bucket with no folders offers only the root, a lookup that failed says so
  /// and leaves the chosen destination alone.
  @State private var folderListingFailed = false
  @State private var fileURL: URL?
  @State private var importsFile = false
  @State private var loading = true
  @State private var uploading = false
  @State private var actionPhase: DashActionPhase = .idle
  @State private var error: String?
  @State private var uploadedMessage: String?
  @State private var pendingUploadedMessage: String?
  @State private var uploadTask: Task<Void, Never>?
  @State private var uploadGeneration: UInt64 = 0

  /// Identity of one folder listing. The account generation is part of it, so a
  /// response can only ever land on the account, bucket, and folder that asked
  /// for it.
  private struct FolderListingRequest: Hashable {
    let context: AccountRequestContext
    let bucket: String
    let prefix: String
  }

  private var remembered: R2ShareDestination? {
    guard let accountID = model.activeAccountID else { return nil }
    return R2ShareDestination.destination(accountID: accountID)
  }

  private var folderListingRequest: FolderListingRequest? {
    guard let context = model.accountRequestContext, !selectedBucket.isEmpty else { return nil }
    return FolderListingRequest(
      context: context, bucket: selectedBucket, prefix: folderPrefix)
  }

  private var actionTitle: String {
    if uploadedMessage != nil { return DashL10n.string("Done") }
    if fileURL == nil { return DashL10n.string("Choose file") }
    return DashL10n.string("Upload")
  }

  var body: some View {
    DashFormSheet(
      saveTitle: actionTitle,
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completeUploadPresentation,
      canSave: uploadedMessage != nil || (!loading && !selectedBucket.isEmpty),
      onSave: performPrimaryAction
    ) {
      VStack(alignment: .leading, spacing: 14) {
        if let uploadedMessage {
          DashNotice(kind: .success, message: uploadedMessage)
        } else {
          if let error {
            DashNotice(kind: .error, message: error)
          }

          if loading {
            HStack(spacing: 10) {
              ProgressView()
                .controlSize(.small)
              Text("Loading R2 buckets…")
                .dashTextStyle(.footnote)
                .foregroundStyle(DashTheme.subtle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
          } else if buckets.isEmpty {
            DashNotice(
              kind: .warning,
              message: DashL10n.string("Create an R2 bucket before uploading a file."))
          } else {
            DashFormMenuField(
              label: DashL10n.string("Bucket"),
              selection: $selectedBucket,
              options: buckets.map(\.name)
            )

            HomeR2FolderField(prefix: $folderPrefix, childFolders: childFolders)

            if folderListingFailed {
              DashNotice(
                kind: .warning,
                message: DashL10n.string(
                  "Can't list this bucket's folders. The upload still goes to the folder shown above."
                ))
            }

            if let fileURL {
              HStack(spacing: 12) {
                SolarIcon(asset: SolarAsset.Content.cloud, size: 22, color: DashTheme.brand)
                VStack(alignment: .leading, spacing: 2) {
                  Text(fileURL.lastPathComponent)
                    .dashTextStyle(.bodyMedium)
                    .foregroundStyle(DashTheme.text)
                    .lineLimit(1)
                  // Where the file lands, spelled out: bucket, chosen folder,
                  // and the key the upload will write.
                  Text(selectedBucket + "/" + folderPrefix + fileURL.lastPathComponent)
                    .dashTextStyle(.footnote)
                    .foregroundStyle(DashTheme.subtle)
                    .lineLimit(1)
                    .truncationMode(.head)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(DashL10n.string("Change")) { importsFile = true }
                  .dashTextStyle(.supportingMedium)
                  .foregroundStyle(DashTheme.brand)
                  .buttonStyle(DashPressButtonStyle())
              }
              .padding(14)
              .background(
                DashTheme.recessed,
                in: RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous)
              )
            }
          }
        }
      }
      .disabled(uploading)
    }
    .fileImporter(isPresented: $importsFile, allowedContentTypes: [.data]) { result in
      guard !uploading else { return }
      switch result {
      case .success(let url):
        fileURL = url
        error = nil
      case .failure(let error):
        self.error = error.dashActionableMessage
      }
    }
    .task { await loadBuckets() }
    // Restarts on every bucket or folder hop, and cancels the one it replaces.
    .task(id: folderListingRequest) { await loadChildFolders() }
    .onChange(of: selectedBucket) { _, bucket in
      folderPrefix = rememberedPrefix(inBucket: bucket)
    }
    .onDisappear { cancelUpload() }
  }

  private func performPrimaryAction() {
    if uploadedMessage != nil {
      dismiss()
    } else if fileURL == nil {
      importsFile = true
    } else {
      startUpload()
    }
  }

  private func loadBuckets() async {
    guard let context = model.accountRequestContext else {
      loading = false
      return
    }
    let key = FeatureCacheKey.r2Buckets(context.accountID)
    if let cached: [R2Bucket] = model.featureCache.get(key) {
      guard model.isCurrentAccount(context) else { return }
      applyBuckets(cached)
      return
    }
    do {
      let loaded = try await model.client.listR2Buckets(accountID: context.accountID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      model.featureCache.set(key, loaded)
      applyBuckets(loaded)
    } catch {
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
      loading = false
    }
  }

  private func applyBuckets(_ loaded: [R2Bucket]) {
    buckets = loaded
    selectedBucket =
      loaded.first(where: { $0.name == remembered?.bucket })?.name
      ?? loaded.first?.name ?? ""
    folderPrefix = rememberedPrefix(inBucket: selectedBucket)
    loading = false
  }

  /// The last-used folder counts only inside the bucket it was used in; every
  /// other bucket starts at its root.
  private func rememberedPrefix(inBucket bucket: String) -> String {
    guard let remembered, remembered.bucket == bucket else { return "" }
    return R2FolderPath.normalized(remembered.prefix)
  }

  /// Lists the folders one level under the chosen destination. Reads and writes
  /// the same per-prefix listing cache as the R2 browser, so hopping between
  /// Home and a bucket screen does not re-fetch what the other just loaded.
  private func loadChildFolders() async {
    guard let request = folderListingRequest else {
      childFolders = []
      folderListingFailed = false
      return
    }
    let key = FeatureCacheKey.r2Objects(
      accountID: request.context.accountID, bucket: request.bucket, prefix: request.prefix)
    if let cached: R2BrowserSnapshot = model.featureCache.get(key) {
      childFolders = cached.commonPrefixes
      folderListingFailed = false
      return
    }
    childFolders = []
    folderListingFailed = false
    do {
      let page = try await model.client.listR2Objects(
        accountID: request.context.accountID,
        bucket: request.bucket,
        prefix: request.prefix.isEmpty ? nil : request.prefix,
        delimiter: "/")
      guard !Task.isCancelled, folderListingRequest == request else { return }
      childFolders = page.commonPrefixes
      let objects = page.objects.filter { !R2FolderMarker.isMarker(key: $0.key) }
      let hasFolderMarker =
        !request.prefix.isEmpty && page.objects.contains { $0.key == request.prefix }
      model.featureCache.set(
        key,
        R2BrowserSnapshot(
          objects: objects, commonPrefixes: page.commonPrefixes, cursor: page.cursor,
          hasFolderMarker: hasFolderMarker))
    } catch {
      guard !Task.isCancelled, !error.dashIsCancellation, folderListingRequest == request
      else { return }
      folderListingFailed = true
    }
  }

  private func startUpload() {
    guard let context = model.accountRequestContext,
      let fileURL,
      !selectedBucket.isEmpty
    else { return }
    let bucket = selectedBucket
    let prefix = folderPrefix
    let rememberedDestination = R2ShareDestination.destination(accountID: context.accountID)
    let destination = R2ShareDestination(
      accountID: context.accountID,
      bucket: bucket,
      prefix: prefix,
      publicHost: rememberedDestination?.bucket == bucket
        ? rememberedDestination?.publicHost ?? ""
        : ""
    )
    let request = HomeR2UploadRequest(
      context: context,
      bucket: bucket,
      prefix: prefix,
      fileURL: fileURL,
      destination: destination)

    uploadTask?.cancel()
    uploadGeneration &+= 1
    let generation = uploadGeneration
    uploading = true
    actionPhase = .loading
    error = nil
    pendingUploadedMessage = nil
    uploadTask = Task { await upload(request, generation: generation) }
  }

  private func upload(_ request: HomeR2UploadRequest, generation: UInt64) async {
    defer { finishUpload(generation: generation) }
    do {
      guard isCurrentUpload(generation, context: request.context) else { return }
      let access = request.fileURL.startAccessingSecurityScopedResource()
      defer {
        if access {
          request.fileURL.stopAccessingSecurityScopedResource()
        }
      }
      guard
        let size = try? request.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
      else {
        throw HomeR2UploadError.unreadableFile
      }
      guard size <= R2Media.transferSizeLimit else {
        throw HomeR2UploadError.fileTooLarge(request.fileURL.lastPathComponent, size)
      }
      try Task.checkCancellation()
      try await model.client.putR2Object(
        accountID: request.context.accountID,
        bucket: request.bucket,
        key: request.key,
        fileURL: request.fileURL,
        contentType: UTType(filenameExtension: request.fileURL.pathExtension)?.preferredMIMEType
      )
      guard isCurrentUpload(generation, context: request.context) else { return }
      model.featureCache.remove(
        prefix: FeatureCacheKey.r2ObjectsPrefix(
          accountID: request.context.accountID,
          bucket: request.bucket))
      let domains: R2DomainsSnapshot? = model.featureCache.get(
        FeatureCacheKey.r2Domains(
          accountID: request.context.accountID,
          bucket: request.bucket))
      var destination = request.destination
      destination.publicHost = domains?.publicHost ?? destination.publicHost
      R2ShareDestination.record(destination)
      onUploaded(request.bucket)
      let message = DashL10n.string(
        "Uploaded \(request.fileURL.lastPathComponent) to \(request.bucket).")
      pendingUploadedMessage = message
      model.toasts.success(message)
      actionPhase = .succeeded
    } catch {
      guard isCurrentUpload(generation, context: request.context) else { return }
      actionPhase = .idle
      self.error = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func isCurrentUpload(
    _ generation: UInt64,
    context: AccountRequestContext
  ) -> Bool {
    !Task.isCancelled
      && uploadGeneration == generation
      && model.isCurrentAccount(context)
  }

  private func finishUpload(generation: UInt64) {
    guard uploadGeneration == generation else { return }
    uploadTask = nil
    if actionPhase != .succeeded {
      uploading = false
      actionPhase = .idle
    }
  }

  private func completeUploadPresentation() {
    guard actionPhase == .succeeded, let pendingUploadedMessage else { return }
    uploadedMessage = pendingUploadedMessage
    self.pendingUploadedMessage = nil
    uploading = false
    actionPhase = .idle
  }

  private func cancelUpload() {
    uploadGeneration &+= 1
    uploadTask?.cancel()
    uploadTask = nil
    uploading = false
    pendingUploadedMessage = nil
    actionPhase = .idle
  }
}

/// Destination-folder chooser for an R2 upload. Wears `DashFormMenuField`'s
/// chrome, but folder names are bucket data — they render verbatim instead of
/// going through `DashL10n.ui`, which would translate a folder that happens to
/// share a catalog key. One menu reaches any depth: it lists the bucket root,
/// the path down to the current choice, and the folders inside it, so choosing
/// a folder both selects it and offers its children on the next open. There is
/// no ring while the next level loads — a menu value is never replaced by
/// progress; the list simply grows when the listing lands.
private struct HomeR2FolderField: View {
  @Binding var prefix: String
  let childFolders: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Folder")
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      Menu {
        Picker("Folder", selection: $prefix) {
          Text("Bucket root").tag("")
          ForEach(
            R2FolderPath.destinations(prefix: prefix, children: childFolders), id: \.self
          ) { folder in
            Text(R2FolderPath.label(for: folder)).tag(folder)
          }
        }
      } label: {
        HStack(spacing: 8) {
          Group {
            if prefix.isEmpty {
              Text("Bucket root")
            } else {
              Text(R2FolderPath.label(for: prefix))
            }
          }
          .dashTextStyle(.bodyMedium)
          .foregroundStyle(DashTheme.text)
          .lineLimit(1)
          // A deep path matters at its tail — keep the chosen folder visible.
          .truncationMode(.head)
          Spacer(minLength: 0)
          SolarIcon(
            asset: SolarAsset.chevronRight, size: DashTheme.Chevron.compact,
            color: DashTheme.placeholder
          )
          .rotationEffect(.degrees(90))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashTheme.recessed)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
      }
    }
  }
}

private enum HomeR2UploadError: LocalizedError {
  case unreadableFile
  case fileTooLarge(String, Int)

  var errorDescription: String? {
    switch self {
    case .unreadableFile:
      DashL10n.string("Can't read that file's size.")
    case .fileTooLarge(let name, let size):
      DashL10n.string(
        "\(name) is \(size.formatted(.byteCount(style: .file))). Dash uploads files up to \(R2Media.transferSizeLimit.formatted(.byteCount(style: .file)))."
      )
    }
  }
}

private struct HomePurgeCachePicker: View {
  @Environment(\.dashTrayDismissAfter) private var dismissAfter
  let zones: [CloudflareZone]
  let onSelect: (CloudflareZone) -> Void

  var body: some View {
    Group {
      if zones.isEmpty {
        DashNotice(
          kind: .warning,
          message: DashL10n.string("Add a domain before purging cache."))
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(zones.enumerated()), id: \.element.id) { index, zone in
            Button {
              dismissAfter { onSelect(zone) }
            } label: {
              DashListRow(
                title: zone.name,
                subtitle: (zone.status ?? "unknown").capitalized,
                avatarSeed: zone.name
              )
            }
            .buttonStyle(DashSurfaceButtonStyle())
            if index < zones.count - 1 {
              DashListGroupDivider()
            }
          }
        }
        .dashTrayDescription(DashL10n.string("Choose the domain whose cache you want to clear."))
      }
    }
  }
}

/// Two-phase add-domain tray: the form morphs into the assigned name servers
/// once Cloudflare accepts the zone, because the registrar update is the step
/// people forget.
/// Shared with the Domains catalog empty state, which offers the same flow
/// so a zero-domain account isn't a dead end there.
struct AddDomainSheet: View {
  private enum Route: Hashable, Sendable {
    case form
    case created(String)
  }

  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let onCreated: () -> Void
  @State private var name = ""
  @State private var actionPhase: DashActionPhase = .idle
  @State private var error: String?
  @State private var created: CloudflareZone?
  @State private var pendingCreated: CloudflareZone?

  private var route: Route {
    created.map { .created($0.id) } ?? .form
  }

  var body: some View {
    DashFormSheet(
      saveTitle: created == nil ? "Add domain" : "Done",
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completeCreatePresentation,
      canSave: created != nil || AddDomainValidation.isPlausibleZoneName(name),
      onSave: {
        if created == nil {
          Task { await create() }
        } else {
          dismiss()
        }
      }
    ) {
      DashTrayFlow(
        route: route,
        role: created == nil ? .root : .detail
      ) { _ in
        if let created {
          successContent(created)
        } else {
          formContent
        }
      }
    }
    .dashTrayTitle(
      created == nil ? DashL10n.string("Add domain") : DashL10n.string("Domain added")
    )
    // Step two answers the question itself, in the success content.
    .dashTrayDescription(
      created == nil
        ? DashL10n.string(
          "Cloudflare assigns name servers next; the domain activates once your registrar points at them."
        )
        : nil)
  }

  private var formContent: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let error {
        DashNotice(kind: .error, message: error)
      }
      DashFormField(
        label: "Domain",
        text: $name,
        keyboard: .URL,
        contentType: .URL)
    }
  }

  private func successContent(_ zone: CloudflareZone) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      // Localize WITH the argument, not after it: DashNotice runs `message`
      // through DashL10n.ui, and by then the zone name is already spliced in, so
      // the catalog's "%@ is on Cloudflare." could never match.
      DashNotice(kind: .success, message: DashL10n.string("\(zone.name) is on Cloudflare."))
      if let servers = zone.nameServers, !servers.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("Point the domain's name servers at")
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
          ForEach(servers, id: \.self) { server in
            Text(server)
              .dashTextStyle(.code)
              .foregroundStyle(DashTheme.text)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .background(
                DashTheme.recessed,
                in: RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
          }
        }
      }
      Text("It shows as Pending until the name servers update — usually within a few hours.")
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func create() async {
    guard let context = model.accountRequestContext else { return }
    let client = model.client
    let normalizedName = AddDomainValidation.normalized(name)
    actionPhase = .loading
    error = nil
    do {
      let zone = try await client.createZone(
        name: normalizedName, accountID: context.accountID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        actionPhase = .idle
        return
      }
      model.toasts.success(DashL10n.string("Created successfully."))
      onCreated()
      pendingCreated = zone
      actionPhase = .succeeded
    } catch {
      actionPhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
    }
  }

  private func completeCreatePresentation() {
    guard actionPhase == .succeeded, let pendingCreated else { return }
    created = pendingCreated
    self.pendingCreated = nil
    actionPhase = .idle
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
        .padding(.vertical, 12)
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
  let avatarTransition: Namespace.ID
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    HStack(spacing: 12) {
      // Match `DashListRow` zone avatars in Recently used (30pt disc).
      HomeZoneAvatar(seed: zone.name, size: 30)
        .matchedGeometryEffect(id: zone.id, in: avatarTransition)
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
    .padding(.vertical, 12)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(zone.name), \(DashL10n.ui((zone.status ?? "unknown").capitalized))")
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
  let feature: FeatureID
  var iconStyle: CatalogFeatureIcon.Style = .fill
  var presentation: Presentation = .catalog

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
      if isAccessibilitySize {
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
    .padding(.vertical, 12)
    .frame(minHeight: DashTheme.Layout.minimumHitTarget)
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
        if !isAccessibilitySize {
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
      Text(feature.subtitle)
        .dashTextStyle(.supporting)
        .foregroundStyle(onCard.opacity(0.75))
        .lineLimit(isAccessibilitySize ? nil : 2)
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
    "\(feature.title), \(feature.subtitle), \(accessAccessibilityValue)"
  }

  private var accessAccessibilityValue: String {
    switch accessLevel {
    case .full: "Available"
    case .readOnly: StatusToken.readOnly.label
    case .locked: StatusToken.locked.label
    }
  }
}
