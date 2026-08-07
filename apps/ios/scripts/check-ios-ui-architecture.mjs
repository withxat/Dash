#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const MAIN_TAB_PATH = join(ROOT, "apps/ios/Dash/MainTabView.swift");
const DASH_WORKSPACE_PATH = join(ROOT, "apps/ios/Dash/DashWorkspace.swift");
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
const DASH_THEME_PATH = join(ROOT, "apps/ios/Dash/DashTheme.swift");
const PROFILE_SETTINGS_PATH = join(
  ROOT,
  "apps/ios/Dash/ProfileSettingsViews.swift",
);
const mainTab = stripSwiftComments(readFileSync(MAIN_TAB_PATH, "utf8"));
const dashWorkspace = stripSwiftComments(
  readFileSync(DASH_WORKSPACE_PATH, "utf8"),
);
const workspaceHeader = stripSwiftComments(
  readFileSync(WORKSPACE_HEADER_PATH, "utf8"),
);
const headerChrome = stripSwiftComments(
  readFileSync(HEADER_CHROME_PATH, "utf8"),
);
const watchtower = stripSwiftComments(readFileSync(WATCHTOWER_PATH, "utf8"));
const dashChrome = stripSwiftComments(readFileSync(DASH_CHROME_PATH, "utf8"));
const dashTheme = stripSwiftComments(readFileSync(DASH_THEME_PATH, "utf8"));
const profileSettings = stripSwiftComments(
  readFileSync(PROFILE_SETTINGS_PATH, "utf8"),
);
const issues = [];

for (const token of [
  "DashSheetSizing",
  "DashExpandableSheet",
  "dashTrayPinsFooter",
]) {
  if (dashChrome.includes(token)) {
    issues.push(`Dash tray must remain compact-only; remove legacy token ${token}.`);
  }
}
for (const token of ["floatingMaxWidth", "floatingDetentFraction"]) {
  if (dashTheme.includes(token)) {
    issues.push(`Dash tray shell must retain its original geometry; remove ${token}.`);
  }
}

const editorControlIDs = [
  "watchtower-customize-cancel",
  "watchtower-add-chart",
  "watchtower-customize-done",
];

function occurrences(source, token) {
  return source.split(token).length - 1;
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

const watchtowerView = declarationBody(watchtower, "struct WatchtowerView: View");
if (!watchtowerView) {
  issues.push("Could not locate WatchtowerView for toolbar ownership validation.");
} else if (
  /\.toolbar\b/.test(watchtowerView) ||
  /\bToolbarItem(?:Group)?\s*\(/.test(watchtowerView)
) {
  issues.push(
    "WatchtowerView must not own navigation toolbar items; tab-root header controls belong to MainTabView's shared overlay.",
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
  issues.push("Could not locate MainTabView.tabContainer for shared-header validation.");
} else {
  const rootStack = declarationBody(tabContainer, "ZStack(alignment: .bottom)");
  const flowIndex = rootStack
    ? topLevelTokenIndex(rootStack, "tabFlow")
    : -1;
  const headerIndex = rootStack
    ? topLevelTokenIndex(rootStack, "sharedHeaderOverlay")
    : -1;
  if (!rootStack || flowIndex === -1 || headerIndex === -1 || headerIndex < flowIndex) {
    issues.push(
      "MainTabView.tabContainer must render sharedHeaderOverlay as a top-level sibling after the tab flow.",
    );
  } else {
    const headerTail = rootStack.slice(headerIndex, headerIndex + 160);
    if (/\.zIndex\s*\(\s*-/.test(headerTail)) {
      issues.push("sharedHeaderOverlay must not be placed behind the pager with a negative zIndex.");
    }
  }
}

for (const legacyPagerToken of [
  "TabView(selection:",
  ".tabViewStyle(.page",
  "TabPagerScrollLock",
]) {
  if (mainTab.includes(legacyPagerToken)) {
    issues.push(
      `MainTabView must use the identity tab flow, not legacy pager token ${legacyPagerToken}.`,
    );
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
  !dashWorkspace.includes("source.view.isUserInteractionEnabled = false") ||
  !dashWorkspace.includes("target.view.isUserInteractionEnabled = false") ||
  !dashWorkspace.includes("source.view.accessibilityElementsHidden = true") ||
  !dashWorkspace.includes("target.view.accessibilityElementsHidden = true") ||
  !dashWorkspace.includes("view.accessibilityElementsHidden = true") ||
  !dashWorkspace.includes("enforceInteractionGate(for: transition)")
) {
  issues.push(
    "Tab handoffs must disable touch and accessibility routing in both UIKit pages and shared SwiftUI chrome until they settle.",
  );
}

const selectTab = declarationBody(mainTab, "private func selectTab");
const tabSettleIndex = selectTab?.indexOf("completeTabTransitionImmediately()") ?? -1;
const sameTabGuardIndex = selectTab?.indexOf("guard tab != selection") ?? -1;
if (
  !selectTab ||
  selectTab.includes("Task.sleep") ||
  selectTab.includes("Task.yield") ||
  !mainTab.includes("onTransitionCompleted:") ||
  !dashWorkspace.includes("animator.addCompletion") ||
  !dashWorkspace.includes("callback(sourceTab, targetTab, generation)") ||
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
  !dashWorkspace.includes("final class DashTabFlowViewController") ||
  !dashWorkspace.includes("addChild(child)") ||
  !dashWorkspace.includes("child.didMove(toParent: self)") ||
  !dashWorkspace.includes("child.willMove(toParent: nil)") ||
  !dashWorkspace.includes("child.removeFromParent()") ||
  !dashWorkspace.includes("detach(transition.source)") ||
  !dashWorkspace.includes("case .deferUntilVisible:") ||
  !dashWorkspace.includes("settlePendingRequestOffscreenIfNeeded()") ||
  !dashWorkspace.includes("view.accessibilityElements = nil") ||
  !dashWorkspace.includes("view.accessibilityElementsHidden = false")
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
  !dashWorkspace.includes("setDestinationCanvasVisible(!settledEntries.isEmpty)")
) {
  issues.push(
    "Pushed pages must own an opaque full-window canvas plate that joins the route animator.",
  );
}

if (!/case \.closeToWorkspaceRoot:\s*SolarAsset\.editClose/.test(dashWorkspace)) {
  issues.push(
    "Workspace Close must use the fine editClose mark; the heavier close glyph is tray-only.",
  );
}

const sharedHeader = declarationBody(
  mainTab,
  "private var sharedHeaderOverlay: some View",
);
const headerBarSlot = declarationBody(mainTab, "private var headerBar: some View");
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
    issues.push("A displaced shared header must be removed, not faded to zero opacity.");
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
    issues.push("DashWorkspaceHeaderBar must own the Liquid Glass morph container.");
  }
  // The header is the store's ONE reader: a page action change must never
  // refresh MainTabView's body while a page transition is settling.
  if (!headerBar.includes("navigator.pageChrome.chrome(")) {
    issues.push("DashWorkspaceHeaderBar must resolve its slots from the page chrome store.");
  }
  if (mainTab.includes("pageChrome")) {
    issues.push("MainTabView must not read page chrome; the shared header is its only reader.");
  }

  for (const identifier of [editorControlIDs[0], editorControlIDs[2]]) {
    if (!headerBar.includes(identifier)) {
      issues.push(`${identifier} must be declared inside DashWorkspaceHeaderBar.`);
    }
  }
  if (!headerBar.includes(editorControlIDs[1])) {
    issues.push("watchtower-add-chart must be declared inside DashWorkspaceHeaderBar.");
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

  // Every workspace page publishes its slots instead of painting them.
  for (const token of [
    'DestinationNavigator(chromeHosting: .workspace)',
  ]) {
    if (occurrences(mainTab, token) !== 3) {
      issues.push(
        "All three tab navigators must hand their page chrome to the shared header.",
      );
      break;
    }
  }
  if (!dashWorkspace.includes("if let entry, chromeHosting == .page {")) {
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
  dashWorkspace,
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
// 44pt slot. The glass ring on the avatar and the inbox is pulled in with a
// negative padding, which shrinks the layout BOX while the circle still draws
// at full size — leading-aligned against a 44pt Back that puts the two circles
// 7pt apart, which is a visible jump now that they share one seat.
for (const [name, source] of [
  ["HeaderProfileButton", headerChrome],
  ["HeaderInboxButton", headerChrome],
]) {
  const control = declarationBody(source, `struct ${name}: View`);
  if (!control) {
    issues.push(`Could not locate ${name} for header slot validation.`);
    continue;
  }
  // Two frames, not one: the inner frame sizes the glyph the negative padding
  // then pulls the glass in around, and a second one has to put the SLOT back
  // at 44pt afterwards. Counting is what discriminates — a check that merely
  // looks for the token is satisfied by the inner frame and can never fail.
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
  const footerIndex = topLevelTokenIndex(
    sheetCardStack,
    "if hasFooter",
  );
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
  dashChrome,
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
    issues.push("ProfileTrayFooter must own the stable Sign out morph identity.");
  }
  if (occurrences(profileTrayFooter, "morphID: signOutMorphID") !== 2) {
    issues.push(
      "ProfileTrayFooter must keep both Sign out morph endpoints inside the fixed footer.",
    );
  }
}

if (occurrences(mainTab, "ProfileTrayFooter(path:") !== 1) {
  issues.push("MainTabView must mount ProfileTrayFooter exactly once in tray chrome.");
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
  issues.push("Profile / Settings trays must stay neutral — remove dashTray tone wiring.");
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
  dashChrome.includes("DashTrayAnchorMath.Transform") ||
  /\bscale[XY]\b/.test(sharedReveal ?? "")
) {
  issues.push("Paired tray reveal must not use nonuniform whole-card scaling.");
}
if (dashChrome.includes("DashTrayAnchorReveal")) {
  issues.push("Remove the legacy whole-card tray anchor reveal.");
}
const customSheet = declarationBody(
  dashChrome,
  "private struct DashCustomSheet<Hero: View, Content: View, Footer: View>: View",
);
const shellIndex = customSheet?.indexOf("layer: .shell") ?? -1;
const cardIndex = customSheet?.indexOf("DashSheetCard(") ?? -1;
const actionIndex = customSheet?.indexOf("layer: .action") ?? -1;
if (
  !customSheet?.includes("drawsSurface: !sharedRevealActive") ||
  !customSheet?.includes("sharedRevealProgress: sharedRevealActive ? progress : nil") ||
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
  issues.push("Profile / Settings trays must not use paired source presentation.");
}

// Result-destination flight (P6): a deliberately single-instance exploration.
// Exactly one production tray — R2 Create bucket — opts in.
const flightOptIns = occurrences(storageViews, ".dashTraySuccessFlight(");
const flightElsewhere = [homeView, profileSettings, mainTab].reduce(
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
