#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const MAIN_TAB_PATH = join(ROOT, "apps/ios/Dash/MainTabView.swift");
const WATCHTOWER_PATH = join(ROOT, "apps/ios/Dash/WatchtowerView.swift");
const DASH_CHROME_PATH = join(ROOT, "apps/ios/Dash/DashChrome.swift");
const DASH_THEME_PATH = join(ROOT, "apps/ios/Dash/DashTheme.swift");
const PROFILE_SETTINGS_PATH = join(
  ROOT,
  "apps/ios/Dash/ProfileSettingsViews.swift",
);
const mainTab = stripSwiftComments(readFileSync(MAIN_TAB_PATH, "utf8"));
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
  const mainTabCount = occurrences(mainTab, identifier);
  if (watchtowerCount !== 0) {
    issues.push(
      `${identifier} occurs ${watchtowerCount} time(s) in WatchtowerView; expected 0.`,
    );
  }
  if (mainTabCount !== 1) {
    issues.push(
      `${identifier} occurs ${mainTabCount} time(s) in MainTabView; expected exactly 1.`,
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
  const pagerIndex = rootStack
    ? topLevelTokenIndex(rootStack, "TabView(selection:")
    : -1;
  const headerIndex = rootStack
    ? topLevelTokenIndex(rootStack, "sharedHeaderOverlay")
    : -1;
  if (!rootStack || pagerIndex === -1 || headerIndex === -1 || headerIndex < pagerIndex) {
    issues.push(
      "MainTabView.tabContainer must render sharedHeaderOverlay as a top-level sibling after the pager.",
    );
  } else {
    const headerTail = rootStack.slice(headerIndex, headerIndex + 160);
    if (/\.zIndex\s*\(\s*-/.test(headerTail)) {
      issues.push("sharedHeaderOverlay must not be placed behind the pager with a negative zIndex.");
    }
  }
}

const sharedHeader = declarationBody(
  mainTab,
  "private var sharedHeaderOverlay: some View",
);
if (!sharedHeader) {
  issues.push("Could not locate MainTabView.sharedHeaderOverlay.");
} else {
  if (!sharedHeader.includes("GlassEffectContainer")) {
    issues.push("sharedHeaderOverlay must own the Liquid Glass morph container.");
  }
  if (!sharedHeader.includes("sharedHeaderControls")) {
    issues.push("sharedHeaderOverlay must render sharedHeaderControls.");
  }
}

const sharedControls = declarationBody(
  mainTab,
  "private var sharedHeaderControls: some View",
);
const addChartMenu = declarationBody(
  mainTab,
  "private var watchtowerAddChartMenu: some View",
);
if (!sharedControls || !addChartMenu) {
  issues.push("Could not locate the shared Watchtower editor control declarations.");
} else {
  for (const identifier of [editorControlIDs[0], editorControlIDs[2]]) {
    if (!sharedControls.includes(identifier)) {
      issues.push(`${identifier} must be declared inside sharedHeaderControls.`);
    }
  }
  if (!addChartMenu.includes(editorControlIDs[1])) {
    issues.push("watchtower-add-chart must be declared inside watchtowerAddChartMenu.");
  }

  const addIndex = sharedControls.indexOf("watchtowerAddChartMenu");
  const doneIndex = sharedControls.indexOf(editorControlIDs[2]);
  if (addIndex === -1 || doneIndex === -1 || addIndex > doneIndex) {
    issues.push("The shared trailing editor group must place Add before Done.");
  }

  const glassIDCounts = new Map([
    [".workspaceHeaderGlassID(.leading", 2],
    [".workspaceHeaderGlassID(.trailingPrimary", 2],
    [".workspaceHeaderGlassID(.trailingSecondary", 1],
  ]);
  for (const [token, expected] of glassIDCounts) {
    const actual = occurrences(sharedControls, token);
    if (actual !== expected) {
      issues.push(`${token} occurs ${actual} time(s); expected ${expected}.`);
    }
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

// Anchored tray reveal (P5): Home quick-action tiles are the tray sources —
// the tile registers its frame and the paired tray names it via sourceID.
// Add Domain is deliberately unanchored (the Domains section opens the same
// tray, so no single tile owns it).
if (!homeView.includes(".dashTraySource(id: action.accessibilityIdentifier)")) {
  issues.push(
    "Home quick-action tiles must register as tray sources via .dashTraySource(id:).",
  );
}
if (!homeView.includes("sourceID: HomeActionID.createR2Bucket.accessibilityIdentifier")) {
  issues.push(
    "Home quick-action trays must anchor to their tiles via sourceID: (see createR2Bucket).",
  );
}
// Only the argument list (everything before the tray's content brace) may not
// name a sourceID.
const addDomainArguments = homeView.match(/isPresented: \$showsAddDomain[^{]*/)?.[0] ?? "";
if (addDomainArguments === "" || addDomainArguments.includes("sourceID:")) {
  issues.push(
    "The Add Domain tray must stay unanchored — the Domains section opens it too.",
  );
}
if (profileSettings.includes("sourceID:") || profileSettings.includes("dashTraySource(")) {
  issues.push("Profile / Settings trays must not use anchored (sourceID) presentation.");
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
