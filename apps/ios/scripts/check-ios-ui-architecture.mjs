#!/usr/bin/env node

import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const MAIN_TAB_PATH = join(ROOT, "apps/ios/Dash/MainTabView.swift");
const DASH_WORKSPACE_PATH = join(ROOT, "apps/ios/Dash/DashWorkspace.swift");
const DASH_TAB_FLOW_PATH = join(ROOT, "apps/ios/Dash/DashTabFlow.swift");
const DASH_ROUTE_PAGE_CHROME_PATH = join(
  ROOT,
  "apps/ios/Dash/DashRoutePageChrome.swift",
);
const WORKSPACE_HEADER_PATH = join(
  ROOT,
  "apps/ios/Dash/DashWorkspaceHeader.swift",
);
const HEADER_CHROME_PATH = join(
  ROOT,
  "apps/ios/Dash/DashHeaderScrollChrome.swift",
);
const WATCHTOWER_PATH = join(ROOT, "apps/ios/Dash/WatchtowerView.swift");
const DASH_CHROME_PATH = join(ROOT, "apps/ios/Dash/DashChrome.swift");
const DASH_TRAY_STATE_PATH = join(ROOT, "apps/ios/Dash/DashTrayState.swift");
const DASH_TRAY_FLOW_PATH = join(ROOT, "apps/ios/Dash/DashTrayFlow.swift");
const DASH_TRAY_SIZING_PATH = join(ROOT, "apps/ios/Dash/DashTraySizing.swift");
const DASH_THEME_PATH = join(ROOT, "apps/ios/Dash/DashTheme.swift");
const DASH_FEATURE_LOADING_PATH = join(
  ROOT,
  "apps/ios/Dash/DashFeatureLoading.swift",
);
const DASH_SURFACE_SKELETONS_PATH = join(
  ROOT,
  "apps/ios/Dash/DashSurfaceSkeletons.swift",
);
const DASH_SURFACES_PATH = join(ROOT, "apps/ios/Dash/DashSurfaces.swift");
const DASH_FORM_CHROME_PATH = join(ROOT, "apps/ios/Dash/DashFormChrome.swift");
const APP_ROOT_PATH = join(ROOT, "apps/ios/Dash/AppRootView.swift");
const WORKER_VIEWS_PATH = join(ROOT, "apps/ios/Dash/WorkerViews.swift");
const WORKER_BUILDS_SECTION_PATH = join(
  ROOT,
  "apps/ios/Dash/WorkerBuildsSection.swift",
);
const PAGES_VIEWS_PATH = join(ROOT, "apps/ios/Dash/PagesViews.swift");
const R2_OBJECT_VIEWS_PATH = join(ROOT, "apps/ios/Dash/R2ObjectViews.swift");
const TUNNEL_VIEWS_PATH = join(ROOT, "apps/ios/Dash/TunnelViews.swift");
const EMAIL_ROUTING_VIEWS_PATH = join(
  ROOT,
  "apps/ios/Dash/EmailRoutingViews.swift",
);
const ZONE_DETAIL_VIEWS_PATH = join(
  ROOT,
  "apps/ios/Dash/ZoneDetailViews.swift",
);
const ZONE_OPERATIONS_VIEWS_PATH = join(
  ROOT,
  "apps/ios/Dash/ZoneOperationsViews.swift",
);
const PROFILE_SETTINGS_PATH = join(
  ROOT,
  "apps/ios/Dash/ProfileSettingsViews.swift",
);
const SOLAR_ICONS_PATH = join(ROOT, "apps/ios/Dash/SolarIcons.swift");
const SOLAR_GENERATOR_PATH = join(
  ROOT,
  "apps/ios/scripts/generate-solar-icons.mjs",
);
const IOS_PROJECT_PATH = join(ROOT, "apps/ios/Dash.xcodeproj/project.pbxproj");
const GIT_COMMIT_SCRIPT_PATH = join(
  ROOT,
  "apps/ios/scripts/write-git-commit.sh",
);
const DASH_PRODUCTION_PATH = join(ROOT, "apps/ios/Dash");
const mainTab = stripSwiftComments(readFileSync(MAIN_TAB_PATH, "utf8"));
const dashWorkspace = stripSwiftComments(
  readFileSync(DASH_WORKSPACE_PATH, "utf8"),
);
const dashTabFlow = stripSwiftComments(
  readFileSync(DASH_TAB_FLOW_PATH, "utf8"),
);
const dashRoutePageChrome = stripSwiftComments(
  readFileSync(DASH_ROUTE_PAGE_CHROME_PATH, "utf8"),
);
const workspaceHeader = stripSwiftComments(
  readFileSync(WORKSPACE_HEADER_PATH, "utf8"),
);
const headerChrome = stripSwiftComments(
  readFileSync(HEADER_CHROME_PATH, "utf8"),
);
const watchtower = stripSwiftComments(readFileSync(WATCHTOWER_PATH, "utf8"));
const dashChrome = stripSwiftComments(readFileSync(DASH_CHROME_PATH, "utf8"));
const dashTrayState = stripSwiftComments(
  readFileSync(DASH_TRAY_STATE_PATH, "utf8"),
);
const dashTrayFlow = stripSwiftComments(
  readFileSync(DASH_TRAY_FLOW_PATH, "utf8"),
);
const dashTraySizing = stripSwiftComments(
  readFileSync(DASH_TRAY_SIZING_PATH, "utf8"),
);
const dashTraySources = [
  dashChrome,
  dashTrayState,
  dashTrayFlow,
  dashTraySizing,
].join("\n");
const dashTheme = stripSwiftComments(readFileSync(DASH_THEME_PATH, "utf8"));
const dashFeatureLoading = stripSwiftComments(
  readFileSync(DASH_FEATURE_LOADING_PATH, "utf8"),
);
const dashSurfaceSkeletons = stripSwiftComments(
  readFileSync(DASH_SURFACE_SKELETONS_PATH, "utf8"),
);
const dashSurfaces = stripSwiftComments(
  readFileSync(DASH_SURFACES_PATH, "utf8"),
);
const dashFormChrome = stripSwiftComments(
  readFileSync(DASH_FORM_CHROME_PATH, "utf8"),
);
const appRoot = stripSwiftComments(readFileSync(APP_ROOT_PATH, "utf8"));
const workerViews = stripSwiftComments(readFileSync(WORKER_VIEWS_PATH, "utf8"));
const workerBuildsSection = stripSwiftComments(
  readFileSync(WORKER_BUILDS_SECTION_PATH, "utf8"),
);
const pagesViews = stripSwiftComments(readFileSync(PAGES_VIEWS_PATH, "utf8"));
const r2ObjectViews = stripSwiftComments(
  readFileSync(R2_OBJECT_VIEWS_PATH, "utf8"),
);
const tunnelViews = stripSwiftComments(
  readFileSync(TUNNEL_VIEWS_PATH, "utf8"),
);
const emailRoutingViews = stripSwiftComments(
  readFileSync(EMAIL_ROUTING_VIEWS_PATH, "utf8"),
);
const zoneDetailViews = stripSwiftComments(
  readFileSync(ZONE_DETAIL_VIEWS_PATH, "utf8"),
);
const zoneOperationsViews = stripSwiftComments(
  readFileSync(ZONE_OPERATIONS_VIEWS_PATH, "utf8"),
);
const profileSettings = stripSwiftComments(
  readFileSync(PROFILE_SETTINGS_PATH, "utf8"),
);
const solarIcons = stripSwiftComments(readFileSync(SOLAR_ICONS_PATH, "utf8"));
const solarGenerator = readFileSync(SOLAR_GENERATOR_PATH, "utf8");
const iosProject = readFileSync(IOS_PROJECT_PATH, "utf8");
const gitCommitScript = readFileSync(GIT_COMMIT_SCRIPT_PATH, "utf8");
const dashProductionSwift = swiftFilesUnder(DASH_PRODUCTION_PATH)
  .map((path) => stripSwiftComments(readFileSync(path, "utf8")))
  .join("\n");
const issues = [];

const featureList = declarationBody(
  dashFeatureLoading,
  "struct DashFeatureList<Header: View, Content: View>: View",
);
const featureListBody = featureList
  ? declarationBody(featureList, "var body: some View")
  : null;
const coldOverlayCopyProperty = featureList
  ? declarationBody(
      featureList,
      "private var coldOverlayCopy: DashColdOverlayCopy?",
    )
  : null;
const coldOverlayModifier = declarationBody(
  dashSurfaceSkeletons,
  "private struct DashColdOverlayModifier: ViewModifier",
);
const coldOverlayCopyView = declarationBody(
  dashSurfaceSkeletons,
  "private struct DashColdOverlayCopyView: View",
);
const coldFailureWash = declarationBody(
  dashSurfaceSkeletons,
  "private struct DashColdFailureWash: View",
);
const sectionFailureVeil = declarationBody(
  dashSurfaces,
  "private struct DashSectionFailureVeil: View",
);
const itemStaggerModifier = declarationBody(
  dashFormChrome,
  "private struct DashItemStaggerModifier: ViewModifier",
);
const onboardingStagger = declarationBody(
  appRoot,
  "fileprivate func onboardingStagger(visible: Bool, index: Int) -> some View",
);
const workerDetailBody = declarationBody(
  workerViews,
  "private func workerDetailBody(mode: DashBodyMode) -> some View",
);
const workerDomainRouteRow = declarationBody(
  workerViews,
  "private func domainRouteRow(_ item: WorkerDomainRouteItem) -> some View",
);
const workerBuildsBody = declarationBody(
  workerBuildsSection,
  "var body: some View",
);
const pagesLogsSection = declarationBody(
  pagesViews,
  "@ViewBuilder private var logsSection: some View",
);
const pagesProjectDetailBody = declarationBody(
  pagesViews,
  "private func pagesProjectDetailBody(mode: DashBodyMode) -> some View",
);
const pagesLoadLogs = declarationBody(
  pagesViews,
  "private func loadLogs(key: PagesBuildMonitorKey, force: Bool) async",
);
const pagesPresentLogs = declarationBody(
  pagesViews,
  "private func presentLogs(_ fetched: PagesDeploymentLogs)",
);
const displayedBodyModeUpdate = featureList
  ? declarationBody(
      featureList,
      "private func updateDisplayedBodyMode(to target: DashBodyMode)",
    )
  : null;
const bodyHandoffRules = declarationBody(
  dashFeatureLoading,
  "enum DashBodyHandoffRules",
);
const bodyHandoffWrite = displayedBodyModeUpdate
  ? declarationBody(
      displayedBodyModeUpdate,
      "withAnimation(DashBodyTransition.handoff)",
    )
  : null;
const modeListRows = declarationBody(
  dashFeatureLoading,
  "func dashModeListRows",
);
const modeListPlaceholderStart =
  modeListRows?.indexOf("case .placeholder(let index):") ?? -1;
const modeListLiveStart = modeListRows?.indexOf("case .live(let item):") ?? -1;
const modeListPlaceholderBranch =
  modeListPlaceholderStart >= 0 && modeListLiveStart > modeListPlaceholderStart
    ? modeListRows?.slice(modeListPlaceholderStart, modeListLiveStart)
    : null;
const modeListLiveBranch =
  modeListLiveStart >= 0 ? modeListRows?.slice(modeListLiveStart) : null;
const r2BucketSettingsBody = declarationBody(
  r2ObjectViews,
  "private func r2BucketSettingsBody(mode: DashBodyMode) -> some View",
);
const r2CustomDomainsSection = declarationBody(
  r2ObjectViews,
  "private func customDomainsSection(mode: DashBodyMode) -> some View",
);
const tunnelDetailBody = declarationBody(
  tunnelViews,
  "private func tunnelDetailBody(mode: DashBodyMode) -> some View",
);
const tunnelConnectorsSection = declarationBody(
  tunnelViews,
  "private func connectorsSection(mode: DashBodyMode) -> some View",
);
const tunnelPublicHostnamesSection = declarationBody(
  tunnelViews,
  "private func publicHostnamesSection(mode: DashBodyMode) -> some View",
);
const tunnelIngressSection = declarationBody(
  tunnelViews,
  "private func ingressSection(mode: DashBodyMode) -> some View",
);
const tunnelPublicHostnameRows = declarationBody(
  tunnelViews,
  "private var publicHostnameRows: [TunnelHostnameRow]",
);
const tunnelHostnameRow = declarationBody(
  tunnelViews,
  "struct TunnelHostnameRow: Identifiable, Hashable, Sendable",
);
const tunnelHostnameIdentityKeyType = tunnelHostnameRow
  ? declarationBody(tunnelHostnameRow, "struct IdentityKey: Hashable, Sendable")
  : null;
const tunnelHostnameIdentityKey = tunnelHostnameRow
  ? declarationBody(
      tunnelHostnameRow,
      "static func identityKey(for rule: TunnelIngressRule) -> IdentityKey",
    )
  : null;
const emailRoutingBody = declarationBody(
  emailRoutingViews,
  "private func emailRoutingBody(mode: DashBodyMode) -> some View",
);
const emailRoutesSection = declarationBody(
  emailRoutingViews,
  "private func routesSection(mode: DashBodyMode) -> some View",
);
const emailAddressesSection = declarationBody(
  emailRoutingViews,
  "private func addressesSection(mode: DashBodyMode) -> some View",
);
const emailConfiguredContent = declarationBody(
  emailRoutingViews,
  "private func configuredContent(",
);
const zoneDetailBody = declarationBody(
  zoneDetailViews,
  "private func zoneDetailBody(mode: DashBodyMode) -> some View",
);
const zonePrimaryActions = declarationBody(
  zoneDetailViews,
  "private func primaryActions(mode: DashBodyMode) -> some View",
);
const zoneTool = declarationBody(
  zoneDetailViews,
  "private struct ZoneTool: Identifiable",
);
const wafDetailBody = declarationBody(
  zoneOperationsViews,
  "private func wafDetailBody(mode: DashBodyMode) -> some View",
);
const wafBucketGroup = declarationBody(
  zoneOperationsViews,
  "private func wafBucketGroup(",
);
const workerDeploymentsStart =
  workerDetailBody?.indexOf(
    'DashListGroupHeader(title: DashL10n.ui("Deployments"))',
  ) ?? -1;
const workerDomainsStart =
  workerDetailBody?.indexOf('title: DashL10n.ui("Domains & Routes")') ?? -1;
const workerDeploymentsSection =
  workerDeploymentsStart >= 0 && workerDomainsStart > workerDeploymentsStart
    ? workerDetailBody?.slice(workerDeploymentsStart, workerDomainsStart)
    : null;
const workerDomainsSection =
  workerDomainsStart >= 0 ? workerDetailBody?.slice(workerDomainsStart) : null;
const workerDomainsHandoffBranch = workerDomainsSection
  ? declarationBody(
      workerDomainsSection,
      "if mode.isPlaceholder || !domainRouteRows.isEmpty",
    )
  : null;
const tunnelIngressHandoffBranch = tunnelIngressSection
  ? declarationBody(
      tunnelIngressSection,
      "if mode.isPlaceholder || isRemotelyManaged",
    )
  : null;
const emailConfiguredBranch = emailRoutingBody
  ? declarationBody(emailRoutingBody, "else")
  : null;
const zoneActionsHandoffBranch = zoneDetailBody
  ? declarationBody(
      zoneDetailBody,
      "if mode.isPlaceholder || displayedZoneIsActive",
    )
  : null;
const wafRulesHandoffBranch = wafDetailBody
  ? declarationBody(wafDetailBody, "if mode.isPlaceholder || summary != nil")
  : null;
const r2CustomRowsHandoffBranch = r2CustomDomainsSection
  ? declarationBody(
      r2CustomDomainsSection,
      "if mode.isPlaceholder || !custom.isEmpty",
    )
  : null;
const tunnelConnectorRowsHandoffBranch = tunnelConnectorsSection
  ? declarationBody(
      tunnelConnectorsSection,
      "if mode.isPlaceholder || !shown.isEmpty",
    )
  : null;
const tunnelHostnameRowsHandoffBranch = tunnelPublicHostnamesSection
  ? declarationBody(
      tunnelPublicHostnamesSection,
      "if mode.isPlaceholder || !shown.isEmpty",
    )
  : null;
const emailRouteRowsHandoffBranch = emailRoutesSection
  ? declarationBody(emailRoutesSection, "if mode.isPlaceholder || !rules.isEmpty")
  : null;
const wafBucketRowsHandoffBranch = wafBucketGroup
  ? declarationBody(wafBucketGroup, "if mode.isPlaceholder || !buckets.isEmpty")
  : null;
const workerDeploymentHelperStart =
  workerDeploymentsSection?.indexOf("dashModeListRows(") ?? -1;
const workerDeploymentHelperEnd =
  workerDeploymentsSection?.indexOf(
    ") { deployment in",
    workerDeploymentHelperStart,
  ) ?? -1;
const workerDeploymentHelperCall =
  workerDeploymentHelperStart >= 0 &&
  workerDeploymentHelperEnd > workerDeploymentHelperStart
    ? workerDeploymentsSection?.slice(
        workerDeploymentHelperStart,
        workerDeploymentHelperEnd,
      )
    : null;
const pagesLoadedLogsBranch = pagesLogsSection
  ? declarationBody(pagesLogsSection, "if let logs")
  : null;
const pagesLoadedLogsOffset = pagesLoadedLogsBranch
  ? (pagesLogsSection?.indexOf(pagesLoadedLogsBranch) ?? -1)
  : -1;
const pagesLogsAfterLoaded =
  pagesLoadedLogsBranch && pagesLoadedLogsOffset >= 0
    ? pagesLogsSection?.slice(
        pagesLoadedLogsOffset + pagesLoadedLogsBranch.length,
      )
    : null;
const pagesPlaceholderLogsBranch = pagesLogsAfterLoaded
  ? declarationBody(pagesLogsAfterLoaded, "else")
  : null;
const pagesLogHandoffWrite = pagesPresentLogs
  ? declarationBody(
      pagesPresentLogs,
      "withAnimation(DashBodyTransition.handoff)",
    )
  : null;
const pagesLogReducedWrite = pagesPresentLogs
  ? declarationBody(pagesPresentLogs, "withTransaction(transaction)")
  : null;
const coldWashMaterialIndex =
  coldFailureWash?.indexOf(".fill(.ultraThinMaterial)") ?? -1;
const coldWashCanvasIndex =
  coldFailureWash?.indexOf("ramp(stops: stops, tint: DashTheme.canvas)") ?? -1;

if (
  !featureListBody?.includes(
    ".dashColdOverlay(copy: coldOverlayCopy, extent: .scrollViewport)",
  ) ||
  featureListBody?.includes("DashEmptyState(") ||
  !coldOverlayCopyProperty?.includes("guard") ||
  !coldOverlayCopyProperty?.includes("DashColdOverlayRules.intent(") ||
  !coldOverlayCopyProperty?.includes("switch intent")
) {
  issues.push(
    "Cold feature lists must keep one placeholder body mounted and derive settled empty/error copy through DashColdOverlayRules.",
  );
}
if (
  !featureListBody?.includes("failureBanner(banner)") ||
  featureListBody?.includes("DashLoadingRing(") ||
  featureListBody?.includes('Text("Updating…")') ||
  featureListBody?.includes('accessibilityLabel("Updating")')
) {
  issues.push(
    "DashFeatureList warm refreshes must keep live content in place without inserting a standalone progress row; error banners remain in shared chrome.",
  );
}
if (
  !pagesProjectDetailBody?.includes("dashModeListRows(") ||
  !pagesProjectDetailBody?.includes("items: visibleDeployments") ||
  !pagesProjectDetailBody?.includes("placeholderRows: 3") ||
  occurrences(
    pagesProjectDetailBody ?? "",
    "DashSectionListRowPlaceholders(rows: 3)",
  ) !== 1
) {
  issues.push(
    "Pages Project Deployments must share the canonical per-row handoff; grouped three-row skeletons are reserved for the empty failure veil.",
  );
}
if (
  !featureList?.includes(
    "@State private var displayedBodyMode: DashBodyMode?",
  ) ||
  !featureListBody?.includes("content(displayedBodyMode ?? bodyMode)") ||
  !featureListBody?.includes(".onChange(of: bodyMode, initial: true)") ||
  !displayedBodyModeUpdate?.includes("DashBodyHandoffRules.update(") ||
  !displayedBodyModeUpdate?.includes("reduceMotion: reduceMotion") ||
  !bodyHandoffRules?.includes("!reduceMotion") ||
  !bodyHandoffWrite?.includes("displayedBodyMode = update.mode") ||
  featureListBody?.includes("value: bodyMode")
) {
  issues.push(
    "DashFeatureList cold-to-live handoff must use a view-owned displayedBodyMode written inside explicit withAnimation, while Reduce Motion disables layout movement; tray transactions suppress modifier-attached bodyMode animations.",
  );
}
const modeListHelperNames = [
  ...dashProductionSwift.matchAll(/\bfunc\s+(dash\w*ModeListRows)\b/g),
].map((match) => match[1]);
if (
  modeListHelperNames.length !== 1 ||
  modeListHelperNames[0] !== "dashModeListRows" ||
  dashProductionSwift.includes("dashIdentifiedModeListRows") ||
  dashProductionSwift.includes("DashIdentifiedModeListSlot") ||
  dashProductionSwift.includes("DashListRowPlaceholders") ||
  occurrences(dashProductionSwift, "DashSectionListRowPlaceholders(") !== 5 ||
  !modeListRows?.includes("items.map { .live($0) }") ||
  !modeListRows?.includes("ForEach(slots)") ||
  modeListRows?.includes("ForEach(0..<count") ||
  !dashFeatureLoading.includes("case live(ItemID)") ||
  !dashFeatureLoading.includes("case live(Item)") ||
  !dashFeatureLoading.includes("case .live(let item): .live(item.id)") ||
  !modeListPlaceholderBranch?.includes(
    "DashBodyListSlotRules.placeholderRecedes(",
  ) ||
  !modeListPlaceholderBranch?.includes(
    "DashBodyTransition.content(reduceMotion)",
  ) ||
  !modeListPlaceholderBranch?.includes(".transition(transition)") ||
  occurrences(
    modeListPlaceholderBranch ?? "",
    "DashListCardInsetModifier(enabled: inset)",
  ) !== 1 ||
  !modeListLiveBranch?.includes("row(item)") ||
  occurrences(
    modeListLiveBranch ?? "",
    "DashListCardInsetModifier(enabled: inset)",
  ) !== 1 ||
  modeListLiveBranch?.includes("DashBodyTransition.content(") ||
  modeListLiveBranch?.includes(".transition(")
) {
  issues.push(
    "Primary cold lists must have one canonical dashModeListRows implementation with stable live item identity, surplus-only placeholder recession, and no helper-owned transition on later live diffs.",
  );
}
if (
  !workerDeploymentHelperCall?.includes("mode: mode") ||
  !workerDeploymentHelperCall?.includes("items: deployments") ||
  !workerDeploymentHelperCall?.includes("placeholderRows: 3") ||
  !workerDeploymentHelperCall?.includes("reduceMotion: reduceMotion") ||
  occurrences(
    workerDeploymentsSection ?? "",
    "DashSectionListRowPlaceholders(rows: 3)",
  ) !== 1 ||
  occurrences(
    workerDetailBody ?? "",
    'title: DashL10n.ui("Domains & Routes")',
  ) !== 1
) {
  issues.push(
    "Worker Deployments must use the canonical live-identity handoff, with one mode-stable Domains & Routes header riding the 3-to-N contraction below them.",
  );
}

const primaryModeListContracts = [
  {
    label: "Worker Domains & Routes",
    source: workerDomainsSection,
    items: "items: domainRouteRows",
    placeholderRows: "placeholderRows: 2",
  },
  {
    label: "R2 custom domains",
    source: r2CustomDomainsSection,
    items: "items: custom",
    placeholderRows: "placeholderRows: 2",
  },
  {
    label: "Tunnel connectors",
    source: tunnelConnectorsSection,
    items: "items: shown",
    placeholderRows: "placeholderRows: 2",
  },
  {
    label: "Tunnel public hostnames",
    source: tunnelPublicHostnamesSection,
    items: "items: shown",
    placeholderRows: "placeholderRows: 3",
  },
  {
    label: "Email Routing routes",
    source: emailRoutesSection,
    items: "items: rules",
    placeholderRows: "placeholderRows: 3",
  },
  {
    label: "Email Routing destination addresses",
    source: emailAddressesSection,
    items: "items: destinationRows",
    placeholderRows: "placeholderRows: 1",
  },
  {
    label: "Zone actions",
    source: zonePrimaryActions,
    items: "items: tools",
    placeholderRows: "placeholderRows: Self.allTools.count",
  },
  {
    label: "WAF top rules",
    source: wafBucketGroup,
    items: "items: buckets",
    placeholderRows: "placeholderRows: 3",
  },
];
for (const contract of primaryModeListContracts) {
  const call = modeListCall(contract.source, contract.items);
  if (
    occurrences(contract.source ?? "", "dashModeListRows(") !== 1 ||
    !call?.includes("mode: mode") ||
    !call?.includes(contract.placeholderRows) ||
    !call?.includes("reduceMotion: reduceMotion")
  ) {
    issues.push(
      `${contract.label} must use the one canonical dashModeListRows handoff.`,
    );
  }
}

const primaryColdOwnerChecks = [
  [
    "Worker Domains & Routes",
    workerDomainsHandoffBranch?.includes("dashModeListRows(") === true,
  ],
  [
    "R2 custom domains",
    topLevelTokenIndex(
      r2BucketSettingsBody ?? "",
      "customDomainsSection(mode: mode)",
    ) !== -1 && r2CustomRowsHandoffBranch?.includes("dashModeListRows(") === true,
  ],
  [
    "Tunnel connectors and ingress",
    topLevelTokenIndex(
      tunnelDetailBody ?? "",
      "connectorsSection(mode: mode)",
    ) !== -1 &&
      topLevelTokenIndex(
        tunnelDetailBody ?? "",
        "ingressSection(mode: mode)",
      ) !== -1 &&
      tunnelConnectorRowsHandoffBranch?.includes("dashModeListRows(") === true &&
      tunnelIngressHandoffBranch?.includes(
        "publicHostnamesSection(mode: mode)",
      ) === true &&
      tunnelHostnameRowsHandoffBranch?.includes("dashModeListRows(") === true,
  ],
  [
    "Email Routing routes and destination addresses",
    emailConfiguredBranch?.includes(
      "configuredContent(mode: mode, settings: settings)",
    ) === true &&
      topLevelTokenIndex(
        emailConfiguredContent ?? "",
        "routesSection(mode: mode)",
      ) !== -1 &&
      topLevelTokenIndex(
        emailConfiguredContent ?? "",
        "addressesSection(mode: mode)",
      ) !== -1 &&
      emailRouteRowsHandoffBranch?.includes("dashModeListRows(") === true,
  ],
  [
    "Zone actions",
    zoneActionsHandoffBranch?.includes("primaryActions(mode: mode)") === true,
  ],
  [
    "WAF top rules",
    wafRulesHandoffBranch?.includes("wafBucketGroup(") === true &&
      wafRulesHandoffBranch?.includes("mode: mode") === true &&
      wafBucketRowsHandoffBranch?.includes("dashModeListRows(") === true,
  ],
];
for (const [label, isValid] of primaryColdOwnerChecks) {
  if (!isValid) {
    issues.push(
      `${label} must route its placeholder path through the canonical mode-aware section helper.`,
    );
  }
}

if (
  !tunnelHostnameIdentityKeyType?.includes("let service: String") ||
  !tunnelHostnameRow?.includes("let occurrence: Int") ||
  !tunnelHostnameRow?.includes("Self.identityKey(for: rule)") ||
  !tunnelHostnameIdentityKey?.includes('let service = (rule.service ?? "")') ||
  !tunnelHostnameIdentityKey?.includes(
    ".trimmingCharacters(in: .whitespacesAndNewlines)",
  ) ||
  !tunnelHostnameIdentityKey?.includes("service: service") ||
  tunnelHostnameRow?.includes("self.id = \"\\(index)") ||
  !tunnelPublicHostnameRows?.includes(
    "identityOccurrences: [TunnelHostnameRow.IdentityKey: Int]",
  ) ||
  !zoneTool?.includes("enum ID: Hashable") ||
  zoneTool?.includes("var id: String { title }")
) {
  issues.push(
    "Conditional list rows must use semantic entity identity; global indices and display titles cannot key Tunnel hostnames or Zone actions.",
  );
}

const legacyGroupedPrimaryBodies = [
  ["R2 bucket settings", r2BucketSettingsBody],
  ["Tunnel detail", tunnelDetailBody],
  ["Email Routing", emailRoutingBody],
  ["Zone detail", zoneDetailBody],
  ["WAF detail", wafDetailBody],
];
for (const [label, source] of legacyGroupedPrimaryBodies) {
  if (!source || source.includes("DashSectionListRowPlaceholders(")) {
    issues.push(
      `${label} must not bypass dashModeListRows with a grouped primary-cold placeholder block.`,
    );
  }
}
if (workerDetailBody?.includes("DashSectionListRowPlaceholders(rows: 2)")) {
  issues.push(
    "Worker Domains & Routes must not keep its grouped two-row primary-cold placeholder block.",
  );
}
const sectionFailureVeilContracts = [
  {
    label: "Worker Domains & Routes failures",
    source: workerDomainRouteRow,
    token: "DashSectionListRowPlaceholders(rows: 2)",
    count: 2,
  },
  {
    label: "Worker Deployments failure",
    source: workerDeploymentsSection,
    token: "DashSectionListRowPlaceholders(rows: 3)",
    count: 1,
  },
  {
    label: "Pages Project Deployments failure",
    source: pagesProjectDetailBody,
    token: "DashSectionListRowPlaceholders(rows: 3)",
    count: 1,
  },
  {
    label: "Worker Builds section-cold failure",
    source: workerBuildsBody,
    token: "DashSectionListRowPlaceholders(rows: 3)",
    count: 1,
  },
];
for (const contract of sectionFailureVeilContracts) {
  if (
    occurrences(contract.source ?? "", contract.token) !== contract.count ||
    occurrences(contract.source ?? "", ".dashSectionFailure(") !== contract.count
  ) {
    issues.push(
      `${contract.label} must be the exact allowlisted grouped section-failure veil.`,
    );
  }
}
if (
  !pagesLoadedLogsBranch?.includes(
    ".dashBodySlot(reduceMotion: reduceMotion)",
  ) ||
  !pagesPlaceholderLogsBranch?.includes(
    ".dashBodySlot(reduceMotion: reduceMotion)",
  ) ||
  !pagesLoadLogs?.includes("presentLogs(fetched)") ||
  !pagesPresentLogs?.includes("if reduceMotion") ||
  !pagesPresentLogs?.includes("transaction.disablesAnimations = true") ||
  !pagesLogHandoffWrite?.includes("logs = fetched") ||
  !pagesLogHandoffWrite?.includes("logsError = nil") ||
  !pagesLogReducedWrite?.includes("logs = fetched") ||
  !pagesLogReducedWrite?.includes("logsError = nil")
) {
  issues.push(
    "Pages build-log section-cold replacement must transition both card states, use an explicit handoff write, and disable layout movement under Reduce Motion.",
  );
}
if (
  !itemStaggerModifier?.includes("DashItemStaggerMotion.plan(") ||
  !itemStaggerModifier?.includes("visible: visible") ||
  !itemStaggerModifier?.includes("index: index") ||
  !itemStaggerModifier?.includes("reduceMotion: reduceMotion") ||
  !itemStaggerModifier?.includes(".opacity(plan.opacity)") ||
  !itemStaggerModifier?.includes(".offset(y: plan.offsetY)") ||
  !itemStaggerModifier?.includes("animation(delay: plan.delay)") ||
  !itemStaggerModifier?.includes("accessibilityReduceMotion") ||
  !itemStaggerModifier?.includes("DashTheme.Motion.reduced") ||
  !onboardingStagger?.includes(
    "dashItemStagger(visible: visible, index: index)",
  )
) {
  issues.push(
    "Onboarding and cold prompts must render the tested item-stagger plan, including its Reduced Motion pose and delay.",
  );
}
if (
  !coldOverlayModifier?.includes("insertion: .identity") ||
  !coldOverlayModifier?.includes("DashTheme.Motion.failureDismiss") ||
  !coldOverlayModifier?.includes("DashTheme.Motion.reduced") ||
  coldOverlayModifier?.includes(".transition(.opacity)")
) {
  issues.push(
    "Cold overlay insertion must leave motion to its items while removal stays one reduced-motion-aware opacity fade.",
  );
}
const coldItemSteps = [0, 1, 2, 3].map(
  (index) =>
    coldOverlayCopyView?.indexOf(
      `.dashItemStagger(visible: revealed, index: ${index})`,
    ) ?? -1,
);
const sectionItemSteps = [0, 1, 2].map(
  (index) =>
    sectionFailureVeil?.indexOf(
      `.dashItemStagger(visible: revealed, index: ${index})`,
    ) ?? -1,
);
if (
  coldItemSteps.some((index) => index === -1) ||
  !coldItemSteps.every(
    (index, position) => position === 0 || index > coldItemSteps[position - 1],
  ) ||
  sectionItemSteps.some((index) => index === -1) ||
  !sectionItemSteps.every(
    (index, position) =>
      position === 0 || index > sectionItemSteps[position - 1],
  )
) {
  issues.push(
    "Cold empty/error prompts must reuse the onboarding item stagger in top-to-bottom visual order.",
  );
}
if (
  !coldFailureWash?.includes(
    "DashColdFailureWashRamp.stops(for: geometry.size.height)",
  ) ||
  occurrences(
    coldFailureWash ?? "",
    "DashColdFailureWashRamp.stops(for: geometry.size.height)",
  ) !== 1 ||
  !coldFailureWash?.includes("accessibilityReduceTransparency") ||
  !coldFailureWash?.includes(
    "DashColdFailureWashLayerRules.mountsBackdropMaterial(",
  ) ||
  !coldFailureWash?.includes("reduceTransparency: reduceTransparency") ||
  !coldFailureWash?.includes(".fill(.ultraThinMaterial)") ||
  occurrences(coldFailureWash ?? "", ".fill(.ultraThinMaterial)") !== 1 ||
  !coldFailureWash?.includes(".mask") ||
  !coldFailureWash?.includes("ramp(stops: stops, tint: .white)") ||
  !coldFailureWash?.includes("ramp(stops: stops, tint: DashTheme.canvas)") ||
  coldWashMaterialIndex === -1 ||
  coldWashCanvasIndex === -1 ||
  coldWashMaterialIndex > coldWashCanvasIndex ||
  !coldFailureWash?.includes("startPoint: .bottom") ||
  !coldFailureWash?.includes("endPoint: .top") ||
  coldFailureWash?.includes(".blur(") ||
  coldFailureWash?.includes("VariableBlurView(") ||
  coldFailureWash?.includes("opacity(reduceTransparency")
) {
  issues.push(
    "Cold empty/error wash must pair its tested bottom-to-top canvas ramp with a matching Reduced Transparency-aware backdrop material, never a foreground blur.",
  );
}

for (const token of [
  "DashSheetSizing",
  "DashExpandableSheet",
  "dashTrayPinsFooter",
]) {
  if (dashTraySources.includes(token)) {
    issues.push(
      `Dash tray must remain compact-only; remove legacy token ${token}.`,
    );
  }
}
for (const token of ["floatingMaxWidth", "floatingDetentFraction"]) {
  if (dashTheme.includes(token)) {
    issues.push(
      `Dash tray shell must retain its original geometry; remove ${token}.`,
    );
  }
}
const trayMotionTokens = declarationBody(dashTheme, "enum Tray");
if (
  !/\bpresentResponse: TimeInterval = 0\.21(?:\s|$)/.test(
    trayMotionTokens ?? "",
  ) ||
  !/\bpresentDampingFraction: CGFloat = 0\.8(?:\s|$)/.test(
    trayMotionTokens ?? "",
  ) ||
  trayMotionTokens?.includes("dismissResponse") ||
  trayMotionTokens?.includes("dismissDampingFraction")
) {
  issues.push(
    "Compact Tray may specialize only its 0.21 / 0.8 presentation spring; dismissal stays on Dash's established token.",
  );
}
const motionTokens = declarationBody(dashTheme, "enum Motion");
if (
  !motionTokens?.includes(
    "static let scrimPresent = Animation.easeOut(duration: 0.22)",
  ) ||
  !motionTokens?.includes(
    "static let scrimDismiss = Animation.easeIn(duration: 0.2)",
  )
) {
  issues.push(
    "Tray scrim must keep Dash's independent ease-out/ease-in opacity timing.",
  );
}

const editorControlIDs = [
  "watchtower-customize-cancel",
  "watchtower-add-chart",
  "watchtower-customize-done",
];

function occurrences(source, token) {
  return source.split(token).length - 1;
}

function swiftFilesUnder(directory) {
  const files = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      // Asset catalogs and bundled legal copy cannot contain production Swift.
      if (entry.name !== "Resources") files.push(...swiftFilesUnder(path));
    } else if (entry.isFile() && entry.name.endsWith(".swift")) {
      files.push(path);
    }
  }
  return files;
}

function modeListCall(source, itemsToken) {
  if (!source) return null;
  const itemsIndex = source.indexOf(itemsToken);
  if (itemsIndex === -1) return null;
  const callStart = source.lastIndexOf("dashModeListRows(", itemsIndex);
  const callEnd = source.indexOf(") {", itemsIndex);
  if (callStart === -1 || callEnd === -1 || callEnd < itemsIndex) return null;
  return source.slice(callStart, callEnd);
}

function stripSwiftComments(source) {
  let result = "";
  let index = 0;
  let blockDepth = 0;
  let state = "code";

  while (index < source.length) {
    const pair = source.slice(index, index + 2);
    const triple = source.slice(index, index + 3);
    const character = source[index];

    if (state === "lineComment") {
      if (character === "\n") {
        result += character;
        state = "code";
      }
      index += 1;
      continue;
    }

    if (state === "blockComment") {
      if (pair === "/*") {
        blockDepth += 1;
        index += 2;
      } else if (pair === "*/") {
        blockDepth -= 1;
        index += 2;
        if (blockDepth === 0) state = "code";
      } else {
        if (character === "\n") result += character;
        index += 1;
      }
      continue;
    }

    if (state === "string") {
      result += character;
      if (character === "\\" && index + 1 < source.length) {
        result += source[index + 1];
        index += 2;
      } else {
        index += 1;
        if (character === '"') state = "code";
      }
      continue;
    }

    if (state === "multilineString") {
      if (triple === '\"\"\"') {
        result += triple;
        index += 3;
        state = "code";
      } else {
        result += character;
        index += 1;
      }
      continue;
    }

    if (pair === "//") {
      state = "lineComment";
      index += 2;
    } else if (pair === "/*") {
      state = "blockComment";
      blockDepth = 1;
      index += 2;
    } else if (triple === '\"\"\"') {
      result += triple;
      state = "multilineString";
      index += 3;
    } else {
      result += character;
      index += 1;
      if (character === '"') state = "string";
    }
  }

  return result;
}

function declarationBody(source, declaration) {
  const declarationStart = source.indexOf(declaration);
  if (declarationStart === -1) return null;
  const bodyStart = source.indexOf("{", declarationStart + declaration.length);
  if (bodyStart === -1) return null;

  let depth = 0;
  let inString = false;
  for (let index = bodyStart; index < source.length; index += 1) {
    const character = source[index];
    if (inString) {
      if (character === "\\") {
        index += 1;
      } else if (character === '"') {
        inString = false;
      }
      continue;
    }
    if (character === '"') {
      inString = true;
    } else if (character === "{") {
      depth += 1;
    } else if (character === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(bodyStart + 1, index);
    }
  }

  return null;
}

function topLevelTokenIndex(source, token) {
  let depth = 0;
  let inString = false;
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    if (inString) {
      if (character === "\\") {
        index += 1;
      } else if (character === '"') {
        inString = false;
      }
      continue;
    }
    if (character === '"') {
      inString = true;
    } else if (character === "{") {
      depth += 1;
    } else if (character === "}") {
      depth -= 1;
    } else if (depth === 0 && source.startsWith(token, index)) {
      return index;
    }
  }
  return -1;
}

const workspaceGlowPicker = declarationBody(
  profileSettings,
  "private struct WorkspaceGlowPickerTray: View",
);
const workspaceGlowPickerMetrics = declarationBody(
  profileSettings,
  "enum WorkspaceGlowPickerMetrics",
);
const workspaceGlowPanelHero = declarationBody(
  profileSettings,
  "private struct WorkspaceGlowPanelHero",
);
const workspaceGlowCard = workspaceGlowPicker
  ? declarationBody(workspaceGlowPicker, "private func glowCard")
  : null;
const workspaceGlowCenteredAnchor = workspaceGlowPicker
  ? declarationBody(workspaceGlowPicker, "private func centeredMorphAnchor")
  : null;
const workspaceGlowSideAnchors = workspaceGlowPicker
  ? declarationBody(workspaceGlowPicker, "private func compactSideMorphAnchors")
  : null;
const workspaceGlowInspiration = workspaceGlowPicker
  ? declarationBody(workspaceGlowPicker, "private func inspiration(for")
  : null;
const scrollEdgeEffect = declarationBody(
  headerChrome,
  "struct DashScrollEdgeEffect: View",
);
const scrollEdgeBlurRules = declarationBody(
  headerChrome,
  "enum DashScrollEdgeBlurRules",
);
const fadedScrollView = declarationBody(
  headerChrome,
  "struct DashFadedScrollView<Content: View>: View",
);
if (
  !scrollEdgeEffect?.includes(
    "@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency",
  ) ||
  !scrollEdgeEffect?.includes("var style: DashScrollEdgeStyle = .fade") ||
  !scrollEdgeEffect?.includes("var strength: CGFloat = 1") ||
  !scrollEdgeEffect?.includes(
    "DashScrollEdgeBlurRules.mountsVariableBlur(",
  ) ||
  !scrollEdgeEffect?.includes("VariableBlurView(") ||
  !scrollEdgeEffect?.includes("GeometryReader") ||
  !scrollEdgeEffect?.includes(".rotationEffect(") ||
  !scrollEdgeEffect?.includes("LinearGradient(") ||
  !scrollEdgeEffect?.includes(
    ".opacity(DashScrollEdgeBlurRules.opacity(for: strength))",
  ) ||
  !scrollEdgeEffect?.includes(".clipped()") ||
  !scrollEdgeEffect?.includes(".allowsHitTesting(false)") ||
  !scrollEdgeEffect?.includes(".accessibilityHidden(true)") ||
  scrollEdgeEffect?.includes(".ultraThinMaterial") ||
  scrollEdgeEffect?.includes(".mask {") ||
  scrollEdgeEffect?.includes("@State") ||
  scrollEdgeEffect?.includes(".animation(") ||
  scrollEdgeEffect?.includes(".blur(")
) {
  issues.push(
    "Shared scroll edges must pair their surface fade with a static VariableBlur strip, fall back under Reduce Transparency, and avoid masked material or animated blur state.",
  );
}
if (
  !scrollEdgeBlurRules?.includes(
    "physicalEdge(_ edge: Edge, layoutDirection: LayoutDirection)",
  ) ||
  !scrollEdgeBlurRules?.includes("case (.leading, .rightToLeft): .trailing") ||
  !scrollEdgeBlurRules?.includes("case (.trailing, .rightToLeft): .leading") ||
  !scrollEdgeBlurRules?.includes("case .bottom: .blurredBottomClearTop") ||
  !scrollEdgeBlurRules?.includes(
    "case .top, .leading, .trailing: .blurredTopClearBottom",
  ) ||
  !scrollEdgeBlurRules?.includes("case .leading: -90") ||
  !scrollEdgeBlurRules?.includes("case .trailing: 90") ||
  !scrollEdgeBlurRules?.includes(
    "case .leading, .trailing: CGSize(width: size.height, height: size.width)",
  ) ||
  !scrollEdgeBlurRules?.includes("style == .fadeAndBlur") ||
  !scrollEdgeBlurRules?.includes("!reduceTransparency") ||
  !scrollEdgeBlurRules?.includes("opacity(for: strength) > 0")
) {
  issues.push(
    "Scroll-edge VariableBlur must map all four physical edges, mirror leading/trailing in RTL, swap the horizontal source seat, and leave the tree when hidden or Reduce Transparency is enabled.",
  );
}
if (
  !fadedScrollView ||
  occurrences(fadedScrollView, "style: .fadeAndBlur") !== 2 ||
  !fadedScrollView.includes("strength: topOpacity") ||
  !fadedScrollView.includes("strength: bottomOpacity") ||
  fadedScrollView.includes(".opacity(topOpacity)") ||
  fadedScrollView.includes(".opacity(bottomOpacity)")
) {
  issues.push(
    "DashFadedScrollView must route both dynamic vertical edges through VariableBlur and pass strength into the shared renderer so invisible filters unmount.",
  );
}
if (!workspaceGlowPicker) {
  issues.push(
    "Could not locate WorkspaceGlowPickerTray for state ownership validation.",
  );
} else {
  for (const token of [
    "@State private var centeredPresetID: String?",
    "@State private var centeredPresetPositionIsReady = false",
    "private var centeredPresetPosition: Binding<String?>",
    "morphingPreset == nil",
    "centeredPresetPositionIsReady",
    "guard !centeredPresetPositionIsReady else { return }",
    "centeredPresetID = selectedPreset.id",
    "centeredPresetPositionIsReady = true",
    "centeredPresetID = proposedID",
    ".scrollPosition(id: centeredPresetPosition",
    ".onChange(of: workspaceGlowRaw)",
    "guard centeredPresetID != externallySelected.id else {",
    "centeredPresetID = externallySelected.id",
    ".dashTrayContentTone(activeTone)",
  ]) {
    if (!workspaceGlowPicker.includes(token)) {
      issues.push(
        "WorkspaceGlowPickerTray must seed the selected target after its scroll mounts, then keep root-only ownership of centered-position writes.",
      );
      break;
    }
  }
  if (
    occurrences(workspaceGlowPicker, "DashScrollEdgeEffect(") !== 2 ||
    occurrences(workspaceGlowPicker, "style: .fadeAndBlur") !== 2 ||
    !workspaceGlowPicker.includes("private var pickerEdgeStrength: CGFloat") ||
    !workspaceGlowPicker.includes("path.isEmpty ? 1 : 0") ||
    occurrences(workspaceGlowPicker, "strength: pickerEdgeStrength") !== 2 ||
    !workspaceGlowPicker.includes("edge: .leading") ||
    !workspaceGlowPicker.includes("edge: .trailing")
  ) {
    issues.push(
      "WorkspaceGlowPickerTray must use the shared horizontal VariableBlur edges and pass route visibility as strength so retained hidden filters leave the tree.",
    );
  }
  if (
    workspaceGlowPicker.includes("_centeredPresetID = State(") ||
    workspaceGlowPicker.includes("Task.yield") ||
    workspaceGlowPicker.includes("Task.sleep")
  ) {
    issues.push(
      "WorkspaceGlowPickerTray must not preload or delay its initial scroll target; the selected ID is seeded synchronously when the horizontal scroll appears.",
    );
  }
  if (
    occurrences(
      workspaceGlowPicker,
      "SolarIcon(asset: SolarAsset.starsBold",
    ) !== 2 ||
    occurrences(workspaceGlowPicker, "color: DashTheme.strong") !== 2
  ) {
    issues.push(
      "Glow inspiration affordances must keep the bare Stars icon legible on both compact and expanded wash surfaces.",
    );
  }
  if (
    !workspaceGlowPanelHero?.includes("WorkspaceGlowPanelSurface(") ||
    !workspaceGlowPanelHero?.includes("WorkspaceGlowPanelOutline(") ||
    occurrences(workspaceGlowPicker, "WorkspaceGlowPanelHero(") !== 3 ||
    occurrences(workspaceGlowPicker, "WorkspaceGlowPanelMorphModifier(") !==
      6 ||
    occurrences(workspaceGlowPicker, "element: .panel") !== 3 ||
    occurrences(workspaceGlowPicker, "element: .label") !== 3 ||
    workspaceGlowPicker.includes("element: .outline")
  ) {
    issues.push(
      "Glow must keep panel plus outline as one matched object, with paired panel/label geometry at the compact and detail seats.",
    );
  }
  if (
    !workspaceGlowCard ||
    !workspaceGlowCenteredAnchor ||
    !workspaceGlowSideAnchors ||
    !workspaceGlowInspiration ||
    workspaceGlowSideAnchors.indexOf("element: .label") === -1 ||
    workspaceGlowSideAnchors.indexOf(".padding(.horizontal, 10)") === -1 ||
    workspaceGlowSideAnchors.indexOf("element: .label") >
      workspaceGlowSideAnchors.indexOf(".padding(.horizontal, 10)") ||
    workspaceGlowCenteredAnchor.indexOf("element: .label") === -1 ||
    workspaceGlowCenteredAnchor.indexOf(".padding(.horizontal, 10)") === -1 ||
    workspaceGlowCenteredAnchor.indexOf("element: .label") >
      workspaceGlowCenteredAnchor.indexOf(".padding(.horizontal, 10)") ||
    workspaceGlowInspiration.indexOf("element: .label") === -1 ||
    workspaceGlowInspiration.indexOf(".padding(18)") === -1 ||
    workspaceGlowInspiration.indexOf("element: .label") >
      workspaceGlowInspiration.lastIndexOf(".padding(18)")
  ) {
    issues.push(
      "Glow label morph identity must wrap the shared glyph before either route applies its distinct positioning frame or padding.",
    );
  }
  if (
    !workspaceGlowPicker.includes("@State private var morphingPreset:") ||
    !workspaceGlowPicker.includes("@State private var morphUsesCenteredAnchor") ||
    !workspaceGlowPicker.includes("@Namespace private var inspirationPanelMorph") ||
    !workspaceGlowPicker.includes(
      "@Namespace private var centeredInspirationPanelMorph",
    ) ||
    !workspaceGlowInspiration.includes("WorkspaceGlowPanelHero(") ||
    !workspaceGlowInspiration.includes(
      "showsOutline: morphingOutlinedPreset == preset",
    ) ||
    !workspaceGlowInspiration.includes("else if morphingPreset == preset {") ||
    workspaceGlowInspiration.includes(
      ".opacity(morphingPreset == preset ? 1 : 0)",
    ) ||
    workspaceGlowPicker.includes("private func inspirationHeroFollower") ||
    workspaceGlowCard.includes("WorkspaceGlowPanelMorphModifier(")
  ) {
    issues.push(
      "Glow must let the retained detail hero own the visible flight while stable centered/side anchors stay separate from the visible compact card.",
    );
  }
  if (
    !workspaceGlowPicker.includes("path: flowPath") ||
    !workspaceGlowPicker.includes("private var flowPath: Binding<") ||
    !workspaceGlowPicker.includes("completionCriteria: .removed") ||
    workspaceGlowPicker.includes(".logicallyComplete(after:") ||
    !workspaceGlowPicker.includes(
      "@State private var inspirationReturnGeneration = 0",
    ) ||
    occurrences(workspaceGlowPicker, "inspirationReturnGeneration += 1") !== 3 ||
    !workspaceGlowPicker.includes(
      "inspirationReturnGeneration == returnGeneration",
    ) ||
    !workspaceGlowPicker.includes("completeInspirationReturn()") ||
    !workspaceGlowPicker.includes("centeredMorphAnchor(for:") ||
    !workspaceGlowPicker.includes("compactSideMorphAnchors(for:") ||
    !workspaceGlowPicker.includes("private func clearInspirationMorph()") ||
    !workspaceGlowPicker.includes("DragGesture(minimumDistance: 1)") ||
    !workspaceGlowPicker.includes(".onChanged { _ in clearInspirationMorph() }") ||
    !workspaceGlowPicker.includes(
      ".allowsHitTesting(morphingPreset == nil)",
    ) ||
    !workspaceGlowPicker.includes("transaction.disablesAnimations = true") ||
    !workspaceGlowPicker.includes("morphingPreset = nil") ||
    workspaceGlowPicker.includes("pendingInspirationPreset") ||
    workspaceGlowPicker.includes("openPendingInspiration") ||
    workspaceGlowPicker.includes("ScrollViewReader") ||
    workspaceGlowPicker.includes("scrollProxy.scrollTo") ||
    workspaceGlowPicker.includes(".onChange(of: path)")
  ) {
    issues.push(
      "Glow must pre-register a stable viewport anchor, retain the visible detail hero through the rendered pop endpoint, and hand back without timing or scroll side effects.",
    );
  }
  if (
    !workspaceGlowCenteredAnchor?.includes("Color.clear") ||
    !workspaceGlowCenteredAnchor?.includes(
      "namespace: centeredInspirationPanelMorph",
    ) ||
    !workspaceGlowCenteredAnchor?.includes("centeredInspirationMorphID(for:") ||
    occurrences(workspaceGlowCenteredAnchor, "isSource: path.isEmpty") !== 2 ||
    !workspaceGlowSideAnchors?.includes("Color.clear") ||
    !workspaceGlowSideAnchors?.includes("namespace: inspirationPanelMorph") ||
    !workspaceGlowSideAnchors?.includes("sideInspirationMorphID(for:") ||
    occurrences(workspaceGlowSideAnchors, "isSource: path.isEmpty") !== 2 ||
    !workspaceGlowInspiration?.includes("WorkspaceGlowPanelHero(") ||
    occurrences(workspaceGlowInspiration, "isSource: !path.isEmpty") !== 2
  ) {
    issues.push(
      "Glow panel and label must use transparent compact anchors and a visible retained detail hero with exactly one source per active namespace.",
    );
  }
  if (
    !workspaceGlowInspiration?.includes(
      "let heroHeight = inspirationHeroHeight(for: preset)",
    ) ||
    occurrences(workspaceGlowInspiration, ".frame(height: heroHeight)") !== 2 ||
    !workspaceGlowPicker.includes(
      "private func inspirationHeroHeight(for preset:",
    ) ||
    !workspaceGlowPicker.includes(
      "!reduceMotion, path.isEmpty, morphingPreset == preset",
    )
  ) {
    issues.push(
      "Glow must animate the retained detail hero to the compact card height before the rendered pop hands ownership back to the real card.",
    );
  }
  if (
    !workspaceGlowPicker.includes(
      "let compactVisualIsVisible = reduceMotion || morphingPreset != preset",
    ) ||
    occurrences(
      workspaceGlowCard,
      "morphingPreset == preset ? nil : supportingTransitionAnimation",
    ) !== 2 ||
    !workspaceGlowPicker.includes(
      "if morphUsesCenteredAnchor, let morphingPreset",
    ) ||
    !workspaceGlowPicker.includes(
      "@State private var deferredExternalPresetID:",
    ) ||
    !workspaceGlowPicker.includes(
      "deferredExternalPresetID = externallySelected.id",
    ) ||
    !workspaceGlowPicker.includes(
      "guard path.isEmpty, morphingPreset == nil else {",
    ) ||
    !workspaceGlowPicker.includes("private func centeredInspirationMorphID(") ||
    !workspaceGlowPicker.includes("morphUsesCenteredAnchor && morphingPreset == preset") ||
    !workspaceGlowPicker.includes("private func sideInspirationMorphID(") ||
    !workspaceGlowPicker.includes("!morphUsesCenteredAnchor && morphingPreset == preset")
  ) {
    issues.push(
      "Glow must preserve its visible card under Reduce Motion, freeze the centered anchor during a morph, and defer external selection handoff until the picker returns.",
    );
  }
  if (
    !workspaceGlowPicker.includes(
      "HStack(spacing: WorkspaceGlowPickerMetrics.cardSpacing)",
    ) ||
    workspaceGlowPicker.includes(
      "LazyHStack(spacing: WorkspaceGlowPickerMetrics.cardSpacing)",
    )
  ) {
    issues.push(
      "Glow must keep its small fixed card set eager while the centred morph seat hands geometry ownership back to the carousel.",
    );
  }
  if (
    !workspaceGlowPicker.includes(
      "@State private var morphingOutlinedPreset:",
    ) ||
    !workspaceGlowCard?.includes(
      "let isCentered = centeredPresetID == preset.id",
    ) ||
    !workspaceGlowCard?.includes(
      "morphingOutlinedPreset = isCentered ? preset : nil",
    ) ||
    !workspaceGlowCard?.includes(
      "morphUsesCenteredAnchor = !reduceMotion && isCentered",
    ) ||
    !workspaceGlowInspiration?.includes(
      "showsOutline: morphingOutlinedPreset == preset",
    )
  ) {
    issues.push(
      "Glow Inspiration must show an emphasized outline only when its source card was the centred active selection.",
    );
  }
}

if (
  !workspaceGlowPickerMetrics?.includes("static let cardHeight: CGFloat = 184") ||
  !workspaceGlowPickerMetrics?.includes("static let outlineGap: CGFloat = 1")
) {
  issues.push(
    "Glow picker cards must keep their compact 184pt height and a restrained 1pt outline gap.",
  );
}

if (
  !dashTrayFlow.includes("@State private var lastHeroRoute: Route?") ||
  !dashTrayFlow.includes("retainedHeroDetailRoute(root:") ||
  !dashTrayFlow.includes(".opacity(reduceMotion ? (isActive ? 1 : 0) : 1)") ||
  dashTrayFlow.includes("if transitionStyle == .heroMorph { return .opacity }")
) {
  issues.push(
    "Hero-morph tray routes must retain both geometry seats without applying route opacity to their shared ancestor; Reduce Motion keeps the whole-route cross-fade.",
  );
}

const featureVisualTone = declarationBody(
  dashTheme,
  "enum FeatureVisualTone: Hashable, Sendable",
);
const workspaceGlowTone = declarationBody(
  dashTheme,
  "extension DashWorkspaceGlowPreset",
);
if (
  !featureVisualTone?.includes("case workspaceGlow(DashWorkspaceGlowPreset)") ||
  !featureVisualTone?.includes("DashTheme.workspaceWash(for: preset)") ||
  !featureVisualTone?.includes("DashTheme.workspaceGlowActionLabel") ||
  !workspaceGlowTone?.includes("return .workspaceGlow(self)")
) {
  issues.push(
    "Glow cards and Tray chrome must derive their pigment and action ink from the same Glow preset.",
  );
}

const settingsView = declarationBody(
  profileSettings,
  "struct SettingsView: View",
);
const settingsAboutLink = settingsView
  ? declarationBody(settingsView, "DashListGroupLink(value: .about)")
  : null;
const aboutView = declarationBody(profileSettings, "struct AboutView: View");
if (
  !settingsAboutLink ||
  !settingsAboutLink.includes("icon: SolarAsset.infoCircle") ||
  !aboutView?.includes(
    '.detailHeader(icon: .solar(SolarAsset.Content.infoCircle), title: "About")',
  ) ||
  !solarIcons.includes('static let infoCircle = "SolarInfoCircleOutline"') ||
  !solarIcons.includes('static let infoCircle = "SolarInfoCircleFill"') ||
  !solarGenerator.includes("SolarInfoCircleOutline: 'ui/Linear/InfoCircle'") ||
  !solarGenerator.includes("SolarInfoCircleFill: 'ui/Bold/InfoCircle'")
) {
  issues.push(
    "Settings' About row must use linear Info Circle while the About header keeps the filled family variant.",
  );
}

const buildMetadata = declarationBody(
  profileSettings,
  "enum DashBuildMetadata",
);
const dashTarget = declarationBody(
  iosProject,
  "A00000000000000000000002 /* Dash */ =",
);
const gitCommitPhase = declarationBody(
  iosProject,
  "D00000000000000000000036 /* Embed Git Commit */ =",
);
const embeddedExtensionsIndex =
  dashTarget?.indexOf(
    "D00000000000000000000017 /* Embed Foundation Extensions */",
  ) ?? -1;
const gitCommitPhaseIndex =
  dashTarget?.indexOf("D00000000000000000000036 /* Embed Git Commit */") ?? -1;
if (
  !aboutView?.includes('DashBuildMetadata.shortCommit(in: .main) ?? "—"') ||
  !buildMetadata?.includes("candidate.allSatisfy(\\.isHexDigit)") ||
  embeddedExtensionsIndex === -1 ||
  gitCommitPhaseIndex <= embeddedExtensionsIndex ||
  !gitCommitPhase?.includes("alwaysOutOfDate = 1") ||
  !gitCommitPhase?.includes("DashGitCommit.txt") ||
  !gitCommitPhase?.includes("$(SRCROOT)/../..") ||
  !gitCommitPhase?.includes("scripts/write-git-commit.sh") ||
  !gitCommitScript.includes("SCRIPT_OUTPUT_FILE_0") ||
  !gitCommitScript.includes("DASH_GIT_COMMIT") ||
  !gitCommitScript.includes("CI_COMMIT") ||
  !gitCommitScript.includes("GITHUB_SHA") ||
  !gitCommitScript.includes("CI_XCODEBUILD_ACTION") ||
  !gitCommitScript.includes("rev-parse --verify HEAD")
) {
  issues.push(
    "About Build must show a validated seven-character commit embedded by the Dash target's final build phase, never CFBundleVersion.",
  );
}

const watchtowerView = declarationBody(
  watchtower,
  "struct WatchtowerView: View",
);
if (!watchtowerView) {
  issues.push(
    "Could not locate WatchtowerView for toolbar ownership validation.",
  );
} else if (
  /\.toolbar\b/.test(watchtowerView) ||
  /\bToolbarItem(?:Group)?\s*\(/.test(watchtowerView)
) {
  issues.push(
    "WatchtowerView must not own navigation toolbar items; tab-root header controls belong to MainTabView's shared overlay.",
  );
}

const aboutAppDetailsIndex =
  aboutView?.indexOf('DashInfoGroup(title: "App details")') ?? -1;
const aboutCloudflareStatusIndex =
  aboutView?.indexOf("CloudflareStatusSection()") ?? -1;
if (
  !aboutView ||
  occurrences(aboutView, "CloudflareStatusSection()") !== 1 ||
  aboutAppDetailsIndex === -1 ||
  aboutCloudflareStatusIndex <= aboutAppDetailsIndex ||
  watchtowerView?.includes("CloudflareStatusState") ||
  watchtowerView?.includes("CloudflareStatusSection")
) {
  issues.push(
    "Cloudflare status must be a Settings → About item below App details, never part of the Watchtower tab lifecycle.",
  );
}

for (const identifier of editorControlIDs) {
  const watchtowerCount = occurrences(watchtower, identifier);
  const headerCount = occurrences(workspaceHeader, identifier);
  if (watchtowerCount !== 0) {
    issues.push(
      `${identifier} occurs ${watchtowerCount} time(s) in WatchtowerView; expected 0.`,
    );
  }
  if (headerCount !== 1) {
    issues.push(
      `${identifier} occurs ${headerCount} time(s) in DashWorkspaceHeader; expected exactly 1.`,
    );
  }
}

const tabContainer = declarationBody(
  mainTab,
  "private var tabContainer: some View",
);
if (!tabContainer) {
  issues.push(
    "Could not locate MainTabView.tabContainer for shared-header validation.",
  );
} else {
  const rootStack = declarationBody(tabContainer, "ZStack(alignment: .bottom)");
  const flowIndex = rootStack ? topLevelTokenIndex(rootStack, "tabFlow") : -1;
  const headerIndex = rootStack
    ? topLevelTokenIndex(rootStack, "sharedHeaderOverlay")
    : -1;
  if (
    !rootStack ||
    flowIndex === -1 ||
    headerIndex === -1 ||
    headerIndex < flowIndex
  ) {
    issues.push(
      "MainTabView.tabContainer must render sharedHeaderOverlay as a top-level sibling after the tab flow.",
    );
  } else {
    const headerTail = rootStack.slice(headerIndex, headerIndex + 160);
    if (/\.zIndex\s*\(\s*-/.test(headerTail)) {
      issues.push(
        "sharedHeaderOverlay must not be placed behind the pager with a negative zIndex.",
      );
    }
  }
}

const tabFlowSources = [
  ["MainTabView", mainTab],
  ["DashTabFlow", dashTabFlow],
];
for (const [sourceName, source] of tabFlowSources) {
  for (const legacyPagerToken of [
    "TabView(selection:",
    ".tabViewStyle(.page",
    "TabPagerScrollLock",
  ]) {
    if (source.includes(legacyPagerToken)) {
      issues.push(
        `${sourceName} must use the identity tab flow, not legacy pager token ${legacyPagerToken}.`,
      );
    }
  }
}

if (
  !mainTab.includes("homeWashScroll") ||
  !mainTab.includes("featuresWashScroll") ||
  !mainTab.includes("watchtowerWashScroll") ||
  !mainTab.includes("outgoingScroll: outgoingSelection.map") ||
  !/\\\.dashWorkspaceWashScroll,\s*hostContext\.workspaceWashScroll/.test(
    dashWorkspace,
  ) ||
  dashWorkspace.includes(
    "hostContext.isTabActive ? hostContext.workspaceWashScroll : nil",
  )
) {
  issues.push(
    "The one workspace wash must blend private root snapshots; tab activity must not drop the outgoing snapshot.",
  );
}

if (
  occurrences(mainTab, ".accessibilityHidden(outgoingSelection != nil)") < 1 ||
  !mainTab.includes(
    ".accessibilityHidden(headerIsDisplaced || outgoingSelection != nil)",
  ) ||
  !dashTabFlow.includes("source.view.isUserInteractionEnabled = false") ||
  !dashTabFlow.includes("target.view.isUserInteractionEnabled = false") ||
  !dashTabFlow.includes("source.view.accessibilityElementsHidden = true") ||
  !dashTabFlow.includes("target.view.accessibilityElementsHidden = true") ||
  !dashTabFlow.includes("view.accessibilityElementsHidden = true") ||
  !dashTabFlow.includes("enforceInteractionGate(for: transition)")
) {
  issues.push(
    "Tab handoffs must disable touch and accessibility routing in both UIKit pages and shared SwiftUI chrome until they settle.",
  );
}

const selectTab = declarationBody(mainTab, "private func selectTab");
const tabSettleIndex =
  selectTab?.indexOf("completeTabTransitionImmediately()") ?? -1;
const sameTabGuardIndex = selectTab?.indexOf("guard tab != selection") ?? -1;
if (
  !selectTab ||
  selectTab.includes("Task.sleep") ||
  selectTab.includes("Task.yield") ||
  !mainTab.includes("onTransitionCompleted:") ||
  !dashTabFlow.includes("animator.addCompletion") ||
  !dashTabFlow.includes("callback(sourceTab, targetTab, generation)") ||
  tabSettleIndex === -1 ||
  sameTabGuardIndex === -1 ||
  tabSettleIndex > sameTabGuardIndex
) {
  issues.push(
    "Tab handoff cleanup must settle before same-tab routing and follow the UIKit compositor completion, never a fixed delay.",
  );
}

if (
  !mainTab.includes("DashTabFlowHost(") ||
  !dashTabFlow.includes("final class DashTabFlowViewController") ||
  !dashTabFlow.includes("addChild(child)") ||
  !dashTabFlow.includes("child.didMove(toParent: self)") ||
  !dashTabFlow.includes("child.willMove(toParent: nil)") ||
  !dashTabFlow.includes("child.removeFromParent()") ||
  !dashTabFlow.includes("detach(transition.source)") ||
  !dashTabFlow.includes("case .deferUntilVisible:") ||
  !dashTabFlow.includes("settlePendingRequestOffscreenIfNeeded()") ||
  !dashTabFlow.includes("view.accessibilityElements = nil") ||
  !dashTabFlow.includes("view.accessibilityElementsHidden = false")
) {
  issues.push(
    "The identity tab flow must be one UIKit container that owns child containment and exposes only the settled page to accessibility.",
  );
}

if (
  !dashWorkspace.includes(
    "controller.view.backgroundColor = UIColor(DashTheme.canvas)",
  ) ||
  !dashWorkspace.includes("controller.view.isOpaque = true") ||
  !dashWorkspace.includes("destinationCanvasPlate.frame = view.bounds") ||
  !dashWorkspace.includes("prepareDestinationCanvasTransition") ||
  !dashWorkspace.includes(
    "destinationCanvasPlate.alpha = targetOwnsDestinationCanvas ? 1 : 0",
  ) ||
  !dashWorkspace.includes(
    "setDestinationCanvasVisible(!settledEntries.isEmpty)",
  )
) {
  issues.push(
    "Pushed pages must own an opaque full-window canvas plate that joins the route animator.",
  );
}

// Route hosts are already attached and laid out before the compositor builds
// its proxy. Asking UIKit for an after-screen-updates snapshot from inside
// updateUIViewController synchronously re-enters SwiftUI's AttributeGraph.
const pageStackController = declarationBody(
  dashWorkspace,
  "private final class DashPageStackViewController<Root: View>: UIViewController",
);
if (!pageStackController) {
  issues.push("Could not locate DashPageStackViewController.");
} else if (
  pageStackController.includes("afterScreenUpdates: true") ||
  !pageStackController.includes("view.layoutIfNeeded()") ||
  occurrences(pageStackController, "afterScreenUpdates: false") < 3
) {
  issues.push(
    "Page transitions must lay out their hosts once, then snapshot without after-screen updates; a synchronous refresh re-enters AttributeGraph from updateUIViewController.",
  );
}

if (
  !/case \.closeToWorkspaceRoot:\s*SolarAsset\.editClose/.test(
    dashRoutePageChrome,
  )
) {
  issues.push(
    "Workspace Close must use the fine editClose mark; the heavier close glyph is tray-only.",
  );
}

const sharedHeader = declarationBody(
  mainTab,
  "private var sharedHeaderOverlay: some View",
);
const headerBarSlot = declarationBody(
  mainTab,
  "private var headerBar: some View",
);
if (!sharedHeader || !headerBarSlot) {
  issues.push("Could not locate MainTabView.sharedHeaderOverlay.");
} else {
  if (!sharedHeader.includes("headerBar")) {
    issues.push("sharedHeaderOverlay must render the ONE shared header bar.");
  }
  if (!headerBarSlot.includes("DashWorkspaceHeaderBar(")) {
    issues.push("headerBar must be the ONE DashWorkspaceHeaderBar.");
  }
  // Liquid Glass composites outside a normal opacity group, so a displaced
  // header has to leave the tree rather than fade to zero.
  if (/\.opacity\(\s*headerIsDisplaced/.test(sharedHeader)) {
    issues.push(
      "A displaced shared header must be removed, not faded to zero opacity.",
    );
  }
  // While the bar is fading out of a tray, its removal transition is plain
  // opacity — mute hits off the mirrored displacement flag or a glass plate
  // can keep eating taps meant for the tray's own ✕.
  if (
    !sharedHeader.includes("displayedHeaderIsDisplaced") ||
    !sharedHeader.includes("allowsHitTesting(")
  ) {
    issues.push(
      "sharedHeaderOverlay must hit-mute off displayedHeaderIsDisplaced while the bar is displaced.",
    );
  }
}

const headerBar = declarationBody(
  workspaceHeader,
  "struct DashWorkspaceHeaderBar: View",
);
if (!headerBar) {
  issues.push("Could not locate DashWorkspaceHeaderBar.");
} else {
  if (!headerBar.includes("GlassEffectContainer")) {
    issues.push(
      "DashWorkspaceHeaderBar must own the Liquid Glass morph container.",
    );
  }
  // The header is the store's ONE reader: a page action change must never
  // refresh MainTabView's body while a page transition is settling.
  if (!headerBar.includes("navigator.pageChrome.chrome(")) {
    issues.push(
      "DashWorkspaceHeaderBar must resolve its slots from the page chrome store.",
    );
  }
  if (mainTab.includes("pageChrome")) {
    issues.push(
      "MainTabView must not read page chrome; the shared header is its only reader.",
    );
  }

  for (const identifier of [editorControlIDs[0], editorControlIDs[2]]) {
    if (!headerBar.includes(identifier)) {
      issues.push(
        `${identifier} must be declared inside DashWorkspaceHeaderBar.`,
      );
    }
  }
  if (!headerBar.includes(editorControlIDs[1])) {
    issues.push(
      "watchtower-add-chart must be declared inside DashWorkspaceHeaderBar.",
    );
  }

  const addIndex = headerBar.indexOf("addChartMenu");
  const doneIndex = headerBar.indexOf(editorControlIDs[2]);
  if (addIndex === -1 || doneIndex === -1 || addIndex > doneIndex) {
    issues.push("The shared trailing editor group must place Add before Done.");
  }

  // Back, Close, the avatar and a page's own leading action are ONE seat, so
  // the leading glass identity is applied once — to the slot, not per control.
  const glassIDCounts = new Map([
    [".workspaceHeaderGlassID(.leading", 1],
    [".workspaceHeaderGlassID(.trailingPrimary", 3],
    [".workspaceHeaderGlassID(.trailingSecondary", 1],
  ]);
  for (const [token, expected] of glassIDCounts) {
    const actual = occurrences(headerBar, token);
    if (actual !== expected) {
      issues.push(`${token} occurs ${actual} time(s); expected ${expected}.`);
    }
  }

  // Seat handoff hit-mute must ride the same view as `.id(slotKind)`. An inner
  // transition leaves the remount on the default opacity path, and a clear
  // slot reservation that still hit-tests swallows the dead taps.
  const leadingSlot = declarationBody(headerBar, "private func leadingSlot");
  if (!leadingSlot) {
    issues.push("Could not locate DashWorkspaceHeaderBar.leadingSlot.");
  } else if (!leadingSlot.includes(".transition(leadingTransition)")) {
    issues.push(
      "leadingSlot must apply leadingTransition on the same view as .id(slotKind).",
    );
  }
  const slotReservation = declarationBody(
    headerBar,
    "private var slotReservation: some View",
  );
  if (!slotReservation) {
    issues.push("Could not locate DashWorkspaceHeaderBar.slotReservation.");
  } else if (!slotReservation.includes(".allowsHitTesting(false)")) {
    issues.push(
      "slotReservation must set allowsHitTesting(false) so a muted occupant cannot fall through to a dead clear plate.",
    );
  }

  // Every workspace page publishes its slots instead of painting them.
  for (const token of ["DestinationNavigator(chromeHosting: .workspace)"]) {
    if (occurrences(mainTab, token) !== 3) {
      issues.push(
        "All three tab navigators must hand their page chrome to the shared header.",
      );
      break;
    }
  }
  if (!dashRoutePageChrome.includes("if let entry, chromeHosting == .page {")) {
    issues.push(
      "A workspace-hosted page must not paint its own navigation bar; only the shared header may.",
    );
  }
}

// DashRoutePageChromeHost reads a preference OUT of its content and feeds this
// inset BACK IN as a top safe area — a closed loop held shut solely by the
// inset's constant height. Measure it from the bar's own content instead and a
// taller title grows the inset, which re-lays-out the content that published
// the title: the same measure -> apply -> measure re-entry SwiftUI reports as a
// cycling geometry action.
const chromeInset = declarationBody(
  dashRoutePageChrome,
  "@ViewBuilder private var routeChromeInset: some View",
);
if (!chromeInset) {
  issues.push("Could not locate DashRoutePageChromeHost.routeChromeInset.");
} else if (
  !chromeInset.includes(".frame(height: DashPageChromeMetrics.reservedHeight)")
) {
  issues.push(
    "routeChromeInset must reserve a CONSTANT height (DashPageChromeMetrics.reservedHeight). Deriving it from the bar's content closes the preference-to-safe-area loop this host depends on staying open.",
  );
}

// Every occupant of the shared header's two seats must lay out at the same
// 44pt slot and paint glass the same way Back/Close do. `.buttonStyle(.glass)`
// is a different compositor from the toolbar's explicit `glassEffect`; a seat
// handoff between them can leave an interactive plate that eats taps after
// the morph has settled.
for (const [name, source] of [
  ["HeaderProfileButton", headerChrome],
  ["HeaderInboxButton", headerChrome],
]) {
  const control = declarationBody(source, `struct ${name}: View`);
  if (!control) {
    issues.push(`Could not locate ${name} for header slot validation.`);
    continue;
  }
  if (control.includes(".buttonStyle(.glass)")) {
    issues.push(
      `${name} must use explicit glassEffect(.regular.interactive(), in: .circle) like DashToolbarIconButton — not .buttonStyle(.glass) — so a seat morph cannot leave a dead hit target.`,
    );
  }
  if (!control.includes("AvatarHeaderMetrics.barSize")) {
    issues.push(`${name} must lock its layout to AvatarHeaderMetrics.barSize.`);
  }
  // Legacy: if a control still pulls glass in with negative padding, it owes
  // a second frame that restores the 44pt slot.
  const slotFrames = (
    control.match(
      /\.frame\(\s*width:\s*AvatarHeaderMetrics\.barSize,\s*height:\s*AvatarHeaderMetrics\.barSize\s*\)/g,
    ) ?? []
  ).length;
  if (control.includes(".padding(-7)") && slotFrames < 2) {
    issues.push(
      `${name} pulls its glass in with a negative padding, which shrinks its layout box to 30pt while the circle still draws at 44. It must lock the slot back to AvatarHeaderMetrics.barSize, or it will sit 7pt off the page controls sharing its seat.`,
    );
  }
}

const sheetCard = declarationBody(
  dashChrome,
  "private struct DashSheetCard<Header: View, Body: View, Footer: View>: View",
);
const sheetCardBody = sheetCard
  ? declarationBody(sheetCard, "var body: some View")
  : null;
const sheetCardStack = sheetCardBody
  ? declarationBody(sheetCardBody, "VStack(spacing: 0)")
  : null;
if (!sheetCardStack) {
  issues.push("Could not locate DashSheetCard's header/body/footer stack.");
} else {
  const headerIndex = topLevelTokenIndex(sheetCardStack, "header()");
  const bodyIndex = topLevelTokenIndex(sheetCardStack, "DashFadedScrollView(");
  const footerIndex = topLevelTokenIndex(sheetCardStack, "if hasFooter");
  if (
    headerIndex === -1 ||
    bodyIndex === -1 ||
    footerIndex === -1 ||
    !(headerIndex < bodyIndex && bodyIndex < footerIndex)
  ) {
    issues.push(
      "DashSheetCard must keep fixed header, scrolling body, and fixed footer as ordered top-level siblings.",
    );
  }
  if (!sheetCard.includes("maxCardHeight - headerHeight - footerHeight")) {
    issues.push(
      "DashSheetCard must reserve fixed footer height before sizing its scrolling body.",
    );
  }
  if (!sheetCard.includes("\\.dashTrayBodyMaxHeight, contentMaxHeight")) {
    issues.push(
      "DashSheetCard must publish its content height budget so a tray's action band can be pinned.",
    );
  }
}

// A tray's action band never scrolls: DashConfirmMorph — the component behind
// DashFormSheet and DashDetailTray, and so behind nearly every tray — must keep
// its body and its band on opposite sides of DashTrayScrollBoundary.
const formChrome = stripSwiftComments(
  readFileSync(join(ROOT, "apps/ios/Dash/DashFormChrome.swift"), "utf8"),
);
const confirmMorph = declarationBody(
  formChrome,
  "struct DashConfirmMorph<Content: View, Accessory: View>: View",
);
const confirmMorphBody = confirmMorph
  ? declarationBody(confirmMorph, "var body: some View")
  : null;
if (!confirmMorphBody) {
  issues.push("Could not locate DashConfirmMorph's body/action split.");
} else {
  const boundaryIndex = confirmMorphBody.indexOf("DashTrayScrollBoundary");
  const bodyIndex = confirmMorphBody.indexOf("bodyContent");
  const actionIndex = confirmMorphBody.indexOf("actionContent");
  if (
    boundaryIndex === -1 ||
    !(boundaryIndex < bodyIndex && bodyIndex < actionIndex)
  ) {
    issues.push(
      "DashConfirmMorph must hand its body and action band to DashTrayScrollBoundary, in that order.",
    );
  }
}

const scrollBoundary = declarationBody(
  dashTraySizing,
  "struct DashTrayScrollBoundary<Content: View, Action: View>: View",
);
if (!scrollBoundary) {
  issues.push("Could not locate DashTrayScrollBoundary.");
} else {
  if (!scrollBoundary.includes("DashTrayScrollBoundaryRules.bodyHeight")) {
    issues.push(
      "DashTrayScrollBoundary must size its scrolling region through DashTrayScrollBoundaryRules.",
    );
  }
  if (!scrollBoundary.includes(".frame(height: bodyHeight)")) {
    issues.push(
      "DashTrayScrollBoundary must give its scroll region an exact height — a cap resolves against a proposal the card's scroll does not make.",
    );
  }
}

const profileTrayContent = declarationBody(
  profileSettings,
  "struct ProfileTrayContent: View",
);
const profileTrayFooter = declarationBody(
  profileSettings,
  "struct ProfileTrayFooter: View",
);
if (!profileTrayContent || !profileTrayFooter) {
  issues.push("Could not locate the split Profile tray body and footer.");
} else {
  const misplacedSignOutTokens = [
    '"profile-tray-sign-out"',
    '"profile-account-sign-out"',
    "morphID: signOutMorphID",
  ].filter((token) => profileTrayContent.includes(token));
  if (misplacedSignOutTokens.length > 0) {
    issues.push(
      "ProfileTrayContent must not own the Sign out morph; both endpoints belong to the fixed ProfileTrayFooter.",
    );
  }
  if (!profileTrayFooter.includes('"profile-tray-sign-out"')) {
    issues.push(
      "ProfileTrayFooter must own the stable Sign out morph identity.",
    );
  }
  if (occurrences(profileTrayFooter, "morphID: signOutMorphID") !== 2) {
    issues.push(
      "ProfileTrayFooter must keep both Sign out morph endpoints inside the fixed footer.",
    );
  }
}

if (occurrences(mainTab, "ProfileTrayFooter(path:") !== 1) {
  issues.push(
    "MainTabView must mount ProfileTrayFooter exactly once in tray chrome.",
  );
}

// Tray context tone (P3): feature-launched trays carry their feature's tone,
// while Profile / Settings trays stay neutral. Guard one representative wiring
// on each side so a refactor cannot silently drop (or spread) the tone.
const storageViews = stripSwiftComments(
  readFileSync(join(ROOT, "apps/ios/Dash/StorageViews.swift"), "utf8"),
);
const homeView = stripSwiftComments(
  readFileSync(join(ROOT, "apps/ios/Dash/HomeView.swift"), "utf8"),
);
const homeOperations = stripSwiftComments(
  readFileSync(join(ROOT, "apps/ios/Dash/HomeOperations.swift"), "utf8"),
);
const kvViews = stripSwiftComments(
  readFileSync(join(ROOT, "apps/ios/Dash/KVViews.swift"), "utf8"),
);
if (!storageViews.includes("tone: FeatureVisualIdentity.tone(for: .r2)")) {
  issues.push(
    "StorageViews' R2 trays must pass tone: FeatureVisualIdentity.tone(for: .r2) to dashTray.",
  );
}
if (!homeView.includes("tone: FeatureVisualIdentity.tone(for:")) {
  issues.push(
    "Home quick-action trays must pass their target feature's tone to dashTray.",
  );
}
if (profileSettings.includes("tone: FeatureVisualIdentity.tone(for:")) {
  issues.push(
    "Profile / Settings trays must stay neutral — remove dashTray tone wiring.",
  );
}

// Paired tray source (P5): a source morph is legal only when the same action
// persists into the tray. Ordinary quick-action tiles are launchers, so they
// always use the standard bottom reveal. Demo Connect is the representative
// paired action and must declare both endpoints with one stable identity.
const quickActions = declarationBody(
  homeView,
  "private struct HomeQuickActionsSection: View",
);
if (!quickActions) {
  issues.push("Could not locate HomeQuickActionsSection.");
} else if (
  quickActions.includes("dashTraySource(") ||
  quickActions.includes("dashTraySharedSource(")
) {
  issues.push(
    "Ordinary Home quick-action tiles must use the standard bottom tray reveal.",
  );
}
if (/(?:sourceID|sharedAction):\s*HomeActionID\./.test(homeView)) {
  issues.push(
    "Home quick-action trays must not name a source; their tiles do not persist into the tray.",
  );
}

const demoSource = declarationBody(
  homeView,
  "private struct HomeDemoExperienceSection: View",
);
const demoDestination = declarationBody(
  homeView,
  "private struct HomeDemoConnectFooter: View",
);
if (
  !/\.dashTraySharedSource\s*\(\s*HomeDemoConnect\.sharedAction\s*\)/.test(
    demoSource ?? "",
  ) ||
  !/\.dashTraySharedDestination\s*\(\s*HomeDemoConnect\.sharedAction\s*\)/.test(
    demoDestination ?? "",
  )
) {
  issues.push(
    "Demo Connect must declare matching source and destination action endpoints.",
  );
}
const demoSourcePresenter = declarationBody(
  homeView,
  "private func presentDemoConnectFromSource()",
);
const performHomeAction = declarationBody(
  homeView,
  "private func perform(_ action: HomeActionID)",
);
if (
  !homeView.includes("sharedAction: demoConnectSharedAction") ||
  !demoSourcePresenter?.includes(
    "demoConnectSharedAction = HomeDemoConnect.sharedAction",
  ) ||
  !demoSourcePresenter?.includes("showsDemoConnect = true") ||
  occurrences(
    homeView,
    "demoConnectSharedAction = HomeDemoConnect.sharedAction",
  ) !== 1 ||
  !performHomeAction?.includes("demoConnectSharedAction = nil")
) {
  issues.push(
    "Demo Connect must carry its shared-action identity only from the real source tap into presentation.",
  );
}

const sharedReveal = declarationBody(
  dashChrome,
  "private struct DashTraySharedReveal: View",
);
if (!sharedReveal) {
  issues.push("Could not locate the paired tray shared reveal.");
} else if (sharedReveal.includes(".scaleEffect(")) {
  issues.push(
    "Paired tray reveal must expand the shell separately; never scale the card content.",
  );
}
if (
  dashTraySources.includes("DashTrayAnchorMath.Transform") ||
  /\bscale[XY]\b/.test(sharedReveal ?? "")
) {
  issues.push("Paired tray reveal must not use nonuniform whole-card scaling.");
}
if (dashTraySources.includes("DashTrayAnchorReveal")) {
  issues.push("Remove the legacy whole-card tray anchor reveal.");
}
const customSheet = declarationBody(
  dashChrome,
  "private struct DashCustomSheet<Hero: View, Content: View, Footer: View>: View",
);
const trayMotion = declarationBody(dashChrome, "private enum DashTrayMotion");
if (
  !trayMotion?.includes("static let present = DashTheme.Motion.trayPresent") ||
  !trayMotion?.includes(
    "static let scrimPresent = DashTheme.Motion.scrimPresent",
  ) ||
  !trayMotion?.includes(
    "static let scrimDismiss = DashTheme.Motion.scrimDismiss",
  ) ||
  !trayMotion?.includes("static let dismiss = DashTheme.Motion.dismiss")
) {
  issues.push(
    "Only the Tray card presentation may use the dedicated spring; scrim and dismissal keep Dash's established timing.",
  );
}
const standardTrayReveal = declarationBody(
  dashChrome,
  "private struct DashTrayCardReveal: ViewModifier, Animatable",
);
if (!standardTrayReveal) {
  issues.push("Could not locate the standard Tray card reveal.");
} else {
  if (occurrences(standardTrayReveal, ".offset(") !== 1) {
    issues.push("Standard Tray reveal must keep its one bounded Y offset.");
  }
  for (const token of [".blur(", ".delay("]) {
    if (standardTrayReveal.includes(token)) {
      issues.push(`Standard Tray reveal must not use ${token}`);
    }
  }
  if (
    occurrences(standardTrayReveal, ".opacity(") !== 2 ||
    !standardTrayReveal.includes(".opacity(progress)") ||
    !standardTrayReveal.includes(".opacity(min(1, progress * 2))") ||
    !standardTrayReveal.includes(
      ".scaleEffect(0.985 + 0.015 * progress, anchor: .bottom)",
    )
  ) {
    issues.push(
      "Standard Tray reveal must keep its original card-only fade and subtle bottom-anchored scale.",
    );
  }
}
if (
  !customSheet?.includes(
    "min(max((cardHeight > 0 ? cardHeight : 400) * 0.28, 80), 160)",
  ) ||
  customSheet?.includes("pendingStandardRevealTravel") ||
  customSheet?.includes("openingCardTravel") ||
  customSheet?.includes("closingCardTravel") ||
  customSheet?.includes("DashTrayRevealRules")
) {
  issues.push(
    "Standard Tray must keep Dash's bounded 80...160pt reveal, without the Family full-card travel machinery.",
  );
}
// The standard entrance starts one rendered frame after the cover mounts —
// the same barrier the paired path already takes — because the mount frame
// pays the hosting-controller presentation, the card's first layout, the
// scrim material's first composite, and the height-measurement cascade; a
// time-based spring started inside that long frame skips ahead and reads as
// a dropped-frame entrance. The launch travel freezes at liftoff
// (`revealOffset` is not animatable, so a mid-flight change is a jump, not a
// retarget), and the live card rect is observed only for the anchored morph
// that consumes it — an unconditional write invalidates the sheet body once
// per animated frame.
if (
  customSheet?.includes("if !sharedRevealActive { startPresentation() }") ||
  !customSheet?.includes(
    "guard !sharedRevealActive, !isClosing else { return }",
  ) ||
  !customSheet?.includes("entranceRevealOffset = revealOffset") ||
  !customSheet?.includes("entranceRevealOffset ?? revealOffset") ||
  !customSheet?.includes("entranceRevealOffset = nil") ||
  !customSheet?.includes("guard sharedAction != nil else { return }")
) {
  issues.push(
    "Standard Tray entrance must start behind the one-rendered-frame barrier with its travel frozen at liftoff, and the live card rect must be observed only for the anchored morph.",
  );
}
const trayScrim = customSheet
  ? declarationBody(customSheet, "private var trayScrim: some View")
  : null;
if (
  !trayScrim?.includes("Color.black.opacity(DashTheme.Sheet.scrimOpacity)") ||
  !trayScrim?.includes(".ultraThinMaterial") ||
  !trayScrim?.includes("DashTheme.Sheet.scrimMaterialOpacity") ||
  !customSheet?.includes(
    "@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency",
  ) ||
  trayScrim?.includes(".blur(")
) {
  issues.push(
    "Tray scrim must keep Dash's original reduced-transparency-aware material plus black veil.",
  );
}
const trayCoverPresentation = declarationBody(
  dashChrome,
  "private struct DashTrayCoverPresentation<Value>: Identifiable",
);
if (
  !trayCoverPresentation?.includes("let safeBottom: CGFloat") ||
  !customSheet?.includes("let safeBottom: CGFloat") ||
  !customSheet?.includes("safeBottom: safeBottom") ||
  customSheet?.includes("dashTrayBottomSafeInset()") ||
  occurrences(dashChrome, "safeBottom: dashTrayBottomSafeInset()") !== 2
) {
  issues.push(
    "Tray presentation must freeze the window safe inset before mounting its cover; querying UIWindow safe areas from the sheet body re-enters AttributeGraph through status-bar preferences.",
  );
}
if (
  !customSheet?.includes(
    "@State private var contentTone = DashTrayTonePreference.inherited",
  ) ||
  !customSheet?.includes(".environment(\\.dashTrayTone, resolvedTone)") ||
  !customSheet?.includes(
    ".onPreferenceChange(DashTrayTonePreferenceKey.self)",
  ) ||
  !customSheet?.includes("guard contentTone != reportedTone else { return }")
) {
  issues.push(
    "Multi-step Tray content must publish its active tone to the ancestor shell without feeding equal preference values back into Observation.",
  );
}
const shellIndex = customSheet?.indexOf("layer: .shell") ?? -1;
const cardIndex = customSheet?.indexOf("DashSheetCard(") ?? -1;
const actionIndex = customSheet?.indexOf("layer: .action") ?? -1;
if (
  !customSheet?.includes("drawsSurface: !sharedRevealActive") ||
  !customSheet?.includes(
    "sharedRevealProgress: sharedRevealActive ? progress : nil",
  ) ||
  !customSheet?.includes("active: !sharedRevealActive") ||
  shellIndex === -1 ||
  cardIndex === -1 ||
  actionIndex === -1 ||
  !(shellIndex < cardIndex && cardIndex < actionIndex)
) {
  issues.push(
    "Paired trays must layer the expanding shell behind an unscaled final-layout card and keep the standard reveal inactive.",
  );
}
if (
  !customSheet?.includes(
    "guard !presentationStarted, !isClosing else { return }",
  ) ||
  !customSheet?.includes(
    "guard !Task.isCancelled, !presentationStarted, !isClosing",
  ) ||
  !customSheet?.includes("guard sharedRevealActive, !isClosing else { return }")
) {
  issues.push(
    "Paired tray geometry and fallback tasks must not start presentation after dismissal begins.",
  );
}
if (
  profileSettings.includes("dashTraySharedSource(") ||
  profileSettings.includes("dashTraySharedDestination(") ||
  /\.dashTray\([^)]*sharedAction:/s.test(profileSettings)
) {
  issues.push(
    "Profile / Settings trays must not use paired source presentation.",
  );
}

// Result-destination flight (P6): a deliberately single-instance exploration.
// Exactly one production tray — R2 Create bucket — opts in.
const flightOptIns = occurrences(storageViews, ".dashTraySuccessFlight(");
const otherProductionTrayCallSites = [
  homeView,
  homeOperations,
  kvViews,
  profileSettings,
  mainTab,
];
const flightElsewhere = otherProductionTrayCallSites.reduce(
  (count, source) => count + occurrences(source, ".dashTraySuccessFlight("),
  0,
);
if (flightOptIns !== 1 || flightElsewhere !== 0) {
  issues.push(
    "dashTraySuccessFlight() must have exactly one production opt-in: R2CreateBucketSheet.",
  );
}

if (issues.length > 0) {
  console.error("check-ios-ui-architecture: failed");
  for (const issue of issues) console.error(`- ${issue}`);
  process.exit(1);
}

console.log(
  "check-ios-ui-architecture: shared Watchtower header, compact Tray, and Profile footer ownership are valid",
);
