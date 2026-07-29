#!/usr/bin/env node
// Fails when a literal handed to DashL10n has no entry in Localizable.xcstrings.
//
// `DashL10n.ui` returns an unknown key unchanged, which is right for data
// (zone names, object keys, RDAP tokens) and invisible for everything else: a
// key that was never spliced just renders English, and only a non-en user ever
// sees it. This catches the half that can be checked statically — literals, the
// one case where a miss is always a bug.
//
// Scope and limits, on purpose:
//   * The app plus DashFileProvider. Both compile user-facing literals and
//     carry Localizable.xcstrings; the other extensions keep their existing
//     runtime-focused localization coverage.
//   * Only non-interpolated literals. `DashL10n.string("Saved \(name)")` keys on
//     "Saved %@", and inferring the right format specifier per interpolation is
//     guesswork — those stay the runtime `strictLookup` assertion's job.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = new URL("../../..", import.meta.url).pathname;
const SOURCE_DIRS = [
  join(ROOT, "apps/ios/Dash"),
  join(ROOT, "apps/ios/DashFileProvider"),
];
const CATALOG = join(ROOT, "apps/ios/Dash/Localizable.xcstrings");

/**
 * Two surfaces where a plain literal must resolve against the catalog:
 *   - `DashL10n.string("…")` / `DashL10n.ui("…")` — the explicit lookup.
 *   - `Text("…")` — SwiftUI treats a literal as a LocalizedStringKey and looks
 *     it up automatically, so a missing entry is just as silent.
 * Both allow swift-format's line wrapping.
 */
const CALLS = [
  /DashL10n\.(?:string|ui)\(\s*"((?:[^"\\]|\\.)*)"\s*\)/g,
  /\bText\(\s*"((?:[^"\\]|\\.)*)"\s*\)/g,
];

function swiftFiles(dir) {
  return readdirSync(dir).flatMap((entry) => {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) return swiftFiles(path);
    return path.endsWith(".swift") ? [path] : [];
  });
}

/** Undo Swift's escaping so the key matches the catalog's decoded JSON string. */
function unescape(literal) {
  return literal.replace(/\\(["\\nt0])/g, (_, ch) => {
    return { '"': '"', "\\": "\\", n: "\n", t: "\t", 0: "\0" }[ch];
  });
}

const catalogKeys = new Set(Object.keys(JSON.parse(readFileSync(CATALOG, "utf8")).strings));
const missing = new Map();

for (const file of SOURCE_DIRS.flatMap(swiftFiles)) {
  const source = readFileSync(file, "utf8");
  for (const call of CALLS) {
    for (const match of source.matchAll(call)) {
      const key = unescape(match[1]);
      // Interpolations reach us already collapsed by the literal regex failing to
      // match them; an empty key is a runtime guard, not copy.
      if (!key || key.includes("\\(") || catalogKeys.has(key)) continue;
      const line = source.slice(0, match.index).split("\n").length;
      if (!missing.has(key)) missing.set(key, []);
      missing.get(key).push(`${relative(ROOT, file)}:${line}`);
    }
  }
}

if (missing.size === 0) {
  console.log(`check-l10n-keys: all literal keys present (${catalogKeys.size} in catalog)`);
  process.exit(0);
}

console.error(`check-l10n-keys: ${missing.size} literal key(s) missing from Localizable.xcstrings\n`);
for (const [key, sites] of [...missing].sort(([a], [b]) => a.localeCompare(b))) {
  console.error(`  ${JSON.stringify(key)}`);
  for (const site of sites) console.error(`      ${site}`);
}
console.error("\nSplice each key into apps/ios/Dash/Localizable.xcstrings with a zh-Hans value.");
process.exit(1);
