#!/usr/bin/env node
// Verifies production localization keys exposed by Apple's lightweight source
// extractor after adapting Dash's custom lookup boundaries:
//   * exists in Localizable.xcstrings,
//   * is not marked stale, and
//   * resolves unambiguously when Swift's interpolation type is unavailable.
//
// Dash shares one catalog across the app and its four extensions. Scan all five
// production trees, but never tests:
// test-only copy must not keep a retired production key alive.
//
// Xcode's lightweight parser recognizes system localization APIs but not
// DashL10n.string, DashL10n.ui, or DashAlertStrings.string. Temporary rewritten
// copies expose those calls as String(localized:) so the same Apple parser can
// handle Swift syntax and interpolation. The real targets also enable compiler
// extraction because the compiler can infer the exact %@ / %lld placeholders
// accepted by the String.LocalizationValue wrappers. App Intents also rely on
// compiler-only type inference and macros that this lightweight pass cannot
// reproduce exhaustively; IntentDescription and DashIntentError are adapted
// here, while SWIFT_EMIT_LOC_STRINGS remains the source-of-truth guard for the
// rest of those native surfaces.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const CATALOG = join(ROOT, "apps/ios/Dash/Localizable.xcstrings");
const BASE_CONFIGURATION = join(ROOT, "apps/ios/Config/Base.xcconfig");
const REQUIRED_TRANSLATIONS = ["zh-Hans"];
const SOURCE_DIRECTORIES = [
  join(ROOT, "apps/ios/Dash"),
  join(ROOT, "apps/ios/DashWidgets"),
  join(ROOT, "apps/ios/DashShare"),
  join(ROOT, "apps/ios/DashNotificationService"),
  join(ROOT, "apps/ios/DashFileProvider"),
];

const CUSTOM_LOCALIZATION_CALL =
  /\b(?:(?:DashL10n\.(?:string|ui)|DashAlertStrings\.string|IntentDescription)\s*\(|DashIntentError\s*\(\s*localizedStringResource\s*:)/g;
const PRINTF_PLACEHOLDER = /%(?:\d+\$)?(?:@|lld|llu|ld|lu|d|u|lf|f|s|c|arg)/g;
const TYPED_PRINTF_PLACEHOLDER =
  /%(?:(?<position>\d+)\$)?(?<type>@|lld|llu|ld|lu|d|u|lf|f|s|c)/g;
const POSITIONAL_SOURCE_PLACEHOLDER = /%\d+\$/;

function swiftFiles(directory) {
  return readdirSync(directory)
    .sort()
    .flatMap((entry) => {
      const file = join(directory, entry);
      if (statSync(file).isDirectory()) return swiftFiles(file);
      return file.endsWith(".swift") ? [file] : [];
    });
}

/**
 * xcstringstool uses `%arg` when its lightweight parser cannot infer an
 * interpolation's type. Normalize the catalog's typed printf placeholders to
 * compare shapes without pretending to know whether an argument is String or
 * Int. Multiple catalog keys with the same shape remain an explicit ambiguity.
 */
function normalizeFormatKey(key) {
  return key.replace(PRINTF_PLACEHOLDER, "%arg");
}

function catalogIndex(catalog) {
  const normalized = new Map();
  for (const key of Object.keys(catalog)) {
    const shape = normalizeFormatKey(key);
    if (!normalized.has(shape)) normalized.set(shape, []);
    normalized.get(shape).push(key);
  }
  for (const keys of normalized.values()) keys.sort();
  return normalized;
}

function catalogKeyOrder(contents) {
  return contents
    .split("\n")
    .flatMap((line) => {
      const match = line.match(/^    (".*") : \{$/);
      return match ? [JSON.parse(match[1])] : [];
    });
}

function catalogSerializationIssues(actual, xcodeSerialized) {
  const issues = [];
  const actualKeys = catalogKeyOrder(actual);
  const xcodeKeys = catalogKeyOrder(xcodeSerialized);

  if (actualKeys.length !== xcodeKeys.length) {
    issues.push(
      `Xcode sync writes ${xcodeKeys.length} key(s), but the catalog has ${actualKeys.length}`
    );
  } else {
    const mismatch = actualKeys.findIndex((key, index) => key !== xcodeKeys[index]);
    if (mismatch !== -1) {
      issues.push(
        `key ${JSON.stringify(actualKeys[mismatch])} at index ${mismatch} ` +
          `would be reordered to ${JSON.stringify(xcodeKeys[mismatch])}`
      );
    }
  }

  if (actual.endsWith("\n") !== xcodeSerialized.endsWith("\n")) {
    issues.push("the trailing newline differs from xcstringstool output");
  }
  return issues;
}

function serializationProbeCatalog(catalogContents) {
  // Sync the intact document. Removing and restoring a key makes
  // `xcstringstool` reorder the full catalog even when an ordinary Xcode sync
  // would leave it alone, turning the probe itself into the reported drift.
  return catalogContents;
}

function addSites(target, key, sites) {
  if (!target.has(key)) target.set(key, new Set());
  for (const site of sites) target.get(key).add(site);
}

function rewriteCustomLocalizationCalls(source) {
  return source.replace(CUSTOM_LOCALIZATION_CALL, "String(localized:");
}

function collectStringUnits(value, path = [], result = []) {
  if (!value || typeof value !== "object") return result;
  if (value.stringUnit) {
    result.push({ path, stringUnit: value.stringUnit });
  }
  for (const [key, child] of Object.entries(value)) {
    if (key !== "stringUnit") collectStringUnits(child, [...path, key], result);
  }
  return result;
}

function printfTypes(value) {
  return [...value.matchAll(TYPED_PRINTF_PLACEHOLDER)].map(
    (match) => match.groups
  );
}

function translationPlaceholderIssue(sourceKey, translatedValue) {
  const source = printfTypes(sourceKey).map(({ type }) => type);
  const translated = printfTypes(translatedValue);
  if (translated.length !== source.length) {
    return `expected ${source.length} placeholder(s), found ${translated.length}`;
  }

  const usedPositions = new Set();
  let nextSequentialPosition = 0;
  for (const placeholder of translated) {
    const position = placeholder.position
      ? Number(placeholder.position) - 1
      : nextSequentialPosition++;
    if (position < 0 || position >= source.length) {
      return `placeholder position ${position + 1} is out of range`;
    }
    if (usedPositions.has(position)) {
      return `placeholder position ${position + 1} is repeated`;
    }
    usedPositions.add(position);
    if (placeholder.type !== source[position]) {
      return (
        `placeholder ${position + 1} expects %${source[position]}, ` +
        `found %${placeholder.type}`
      );
    }
  }

  if (usedPositions.size !== source.length) {
    return "not every source placeholder is used exactly once";
  }
  return undefined;
}

function auditCatalogIntegrity(catalog) {
  const emptyKeys = [];
  const positionalSourceKeys = [];
  const missingTranslations = new Map();
  const placeholderMismatches = [];

  for (const [key, entry] of Object.entries(catalog)) {
    if (!key) emptyKeys.push(key);
    if (POSITIONAL_SOURCE_PLACEHOLDER.test(key)) {
      positionalSourceKeys.push(key);
    }

    if (entry.extractionState !== "stale") {
      for (const locale of REQUIRED_TRANSLATIONS) {
        const units = collectStringUnits(entry.localizations?.[locale]);
        if (
          units.length === 0 ||
          units.some(
            ({ stringUnit }) =>
              stringUnit.state !== "translated" ||
              typeof stringUnit.value !== "string"
          )
        ) {
          if (!missingTranslations.has(key)) {
            missingTranslations.set(key, []);
          }
          missingTranslations.get(key).push(locale);
        }
      }

      for (const [locale, localization] of Object.entries(
        entry.localizations ?? {}
      )) {
        for (const { path, stringUnit } of collectStringUnits(localization)) {
          if (typeof stringUnit.value !== "string") continue;
          const issue = translationPlaceholderIssue(key, stringUnit.value);
          if (issue) {
            placeholderMismatches.push({
              issue,
              key,
              locale,
              path: path.join("."),
              value: stringUnit.value,
            });
          }
        }
      }
    }
  }

  positionalSourceKeys.sort();
  placeholderMismatches.sort((left, right) => {
    const leftID = `${left.key}\0${left.locale}\0${left.path}`;
    const rightID = `${right.key}\0${right.locale}\0${right.path}`;
    return leftID < rightID ? -1 : leftID > rightID ? 1 : 0;
  });
  return {
    emptyKeys,
    missingTranslations,
    placeholderMismatches,
    positionalSourceKeys,
  };
}

/**
 * Pure catalog audit. `extracted` maps Apple-parser keys to source locations.
 * Exact keys win before normalized matching; that preserves type information
 * if a future parser emits it rather than `%arg`.
 */
function auditCatalog(catalog, extracted) {
  const normalized = catalogIndex(catalog);
  const resolved = new Map();
  const empty = new Map();
  const missing = new Map();
  const ambiguous = new Map();

  for (const [extractedKey, sites] of extracted) {
    if (!extractedKey) {
      addSites(empty, extractedKey, sites);
      continue;
    }
    const candidates = Object.hasOwn(catalog, extractedKey)
      ? [extractedKey]
      : (normalized.get(normalizeFormatKey(extractedKey)) ?? []);

    if (candidates.length === 0) {
      addSites(missing, extractedKey, sites);
      continue;
    }
    if (candidates.length > 1) {
      ambiguous.set(extractedKey, {
        candidates: new Set(candidates),
        sites: new Set(sites),
      });
      continue;
    }
    addSites(resolved, candidates[0], sites);
  }

  const liveStale = new Map();
  for (const [key, sites] of resolved) {
    if (catalog[key].extractionState === "stale") {
      liveStale.set(key, new Set(sites));
    }
  }

  return { ambiguous, empty, liveStale, missing, resolved };
}

function effectiveBuildSetting(configuration, name) {
  let value;
  for (const sourceLine of configuration.split("\n")) {
    const line = sourceLine.replace(/\/\/.*$/, "").trim();
    const match = line.match(/^([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (match?.[1] === name) value = match[2];
  }
  return value;
}

function extractProductionKeys(catalogContents, catalog) {
  const scratch = mkdtempSync(join(tmpdir(), "dash-l10n-check-"));
  const rewrittenSources = [];
  const originalSourceByRewrite = new Map();

  try {
    for (const source of SOURCE_DIRECTORIES.flatMap(swiftFiles)) {
      const rewritten = join(
        scratch,
        relative(ROOT, source).replaceAll("/", "__")
      );
      const contents = rewriteCustomLocalizationCalls(
        readFileSync(source, "utf8")
      );
      writeFileSync(rewritten, contents);
      rewrittenSources.push(rewritten);
      originalSourceByRewrite.set(resolve(rewritten), relative(ROOT, source));
    }

    const outputDirectory = join(scratch, "stringsdata");
    try {
      execFileSync(
        "xcrun",
        [
          "xcstringstool",
          "extract",
          "--modern-localizable-strings",
          "--SwiftUI",
          "--omit-empty-stringsdata",
          "--output-directory",
          outputDirectory,
          ...rewrittenSources,
        ],
        {
          encoding: "utf8",
          maxBuffer: 10 * 1024 * 1024,
          stdio: ["ignore", "pipe", "pipe"],
        }
      );
    } catch (error) {
      const diagnostics = [error.stdout, error.stderr]
        .filter(Boolean)
        .join("\n")
        .trim();
      throw new Error(
        `xcstringstool extraction failed${diagnostics ? `:\n${diagnostics}` : ""}`
      );
    }

    const extracted = new Map();
    let serializationProbe;
    const stringsdataFiles = readdirSync(outputDirectory)
      .sort()
      .map((outputFile) => join(outputDirectory, outputFile));
    for (const outputFile of stringsdataFiles) {
      const contents = JSON.parse(
        readFileSync(outputFile, "utf8")
      );
      const original =
        originalSourceByRewrite.get(resolve(contents.source)) ??
        relative(ROOT, contents.source);
      for (const row of contents.tables.Localizable ?? []) {
        addSites(extracted, row.key, [
          `${original}:${row.location.startingLine}`,
        ]);
        if (
          !serializationProbe &&
          row.key &&
          !row.visibility &&
          Object.hasOwn(catalog, row.key) &&
          catalog[row.key].extractionState !== "manual" &&
          catalog[row.key].extractionState !== "stale"
        ) {
          serializationProbe = {
            source: contents.source,
            tables: { Localizable: [row] },
            version: contents.version,
          };
        }
      }
    }

    if (!serializationProbe) {
      throw new Error("no safe string-catalog serialization probe was extracted");
    }

    const syncedCatalog = join(scratch, "Localizable.xcstrings");
    const probeKey = serializationProbe.tables.Localizable[0].key;
    writeFileSync(syncedCatalog, serializationProbeCatalog(catalogContents));
    const probeFile = join(scratch, "serialization-probe.stringsdata");
    writeFileSync(probeFile, JSON.stringify(serializationProbe));
    try {
      execFileSync(
        "xcrun",
        [
          "xcstringstool",
          "sync",
          syncedCatalog,
          "--stringsdata",
          probeFile,
          "--skip-marking-strings-stale",
        ],
        {
          encoding: "utf8",
          maxBuffer: 10 * 1024 * 1024,
          stdio: ["ignore", "pipe", "pipe"],
        }
      );
    } catch (error) {
      const diagnostics = [error.stdout, error.stderr]
        .filter(Boolean)
        .join("\n")
        .trim();
      throw new Error(
        `xcstringstool sync failed${diagnostics ? `:\n${diagnostics}` : ""}`
      );
    }

    const xcodeSerialized = readFileSync(syncedCatalog, "utf8");
    const xcodeDocument = JSON.parse(xcodeSerialized);
    if (
      !Object.hasOwn(xcodeDocument.strings, probeKey) ||
      Object.keys(xcodeDocument.strings).length !== Object.keys(catalog).length
    ) {
      throw new Error(
        `xcstringstool serialization probe did not restore ${JSON.stringify(probeKey)}`
      );
    }

    return {
      extracted,
      serializationIssues: catalogSerializationIssues(
        catalogContents,
        xcodeSerialized
      ),
    };
  } finally {
    rmSync(scratch, { force: true, recursive: true });
  }
}

function sortedMapEntries(map) {
  return [...map].sort(([left], [right]) =>
    left < right ? -1 : left > right ? 1 : 0
  );
}

function printSites(sites) {
  for (const site of [...sites].sort()) console.error(`      ${site}`);
}

function runSelfTests() {
  assert.equal(normalizeFormatKey("Saved %@"), "Saved %arg");
  assert.equal(normalizeFormatKey("Moved %1$lld of %2$lld"), "Moved %arg of %arg");
  assert.equal(normalizeFormatKey("100%%"), "100%%");
  assert.equal(
    rewriteCustomLocalizationCalls(
      'DashIntentError(localizedStringResource: "Failed")'
    ),
    'String(localized: "Failed")'
  );
  assert.equal(
    rewriteCustomLocalizationCalls('IntentDescription("Opens Dash")'),
    'String(localized:"Opens Dash")'
  );
  assert.equal(
    translationPlaceholderIssue(
      "Moved %@ to %@ after %lld tries",
      "%2$@ 已从 %1$@ 移动（尝试 %3$lld 次）"
    ),
    undefined
  );
  assert.match(
    translationPlaceholderIssue("Value %lld", "值 %1$@"),
    /expects %lld/
  );
  assert.equal(
    effectiveBuildSetting(
      "SWIFT_EMIT_LOC_STRINGS = YES\nSWIFT_EMIT_LOC_STRINGS = NO // override",
      "SWIFT_EMIT_LOC_STRINGS"
    ),
    "NO"
  );
  assert.deepEqual(
    catalogKeyOrder(
      '{\n  "strings" : {\n    "A \\"quoted\\" key" : {\n    "Second" : {\n  }\n}'
    ),
    ['A "quoted" key', "Second"]
  );
  assert.deepEqual(
    catalogSerializationIssues(
      '{\n  "strings" : {\n    "Second" : {\n    "First" : {\n  }\n}\n',
      '{\n  "strings" : {\n    "First" : {\n    "Second" : {\n  }\n}'
    ),
    [
      'key "Second" at index 0 would be reordered to "First"',
      "the trailing newline differs from xcstringstool output",
    ]
  );
  const intactProbeCatalog =
    '{\n  "strings" : {\n    "First" : {},\n    "Second" : {}\n  }\n}\n';
  assert.equal(
    serializationProbeCatalog(intactProbeCatalog),
    intactProbeCatalog,
    "the serialization probe must not manufacture catalog changes"
  );

  const catalog = {
    Automatic: {},
    Manual: { extractionState: "manual" },
    Stale: { extractionState: "stale" },
    "Value %lld": {},
    "Collision %@": {},
    "Collision %lld": {},
  };
  const extracted = new Map([
    ["Automatic", new Set(["Automatic.swift:1"])],
    ["Manual", new Set(["Manual.swift:2"])],
    ["Stale", new Set(["Stale.swift:3"])],
    ["Value %arg", new Set(["Value.swift:4"])],
    ["Collision %arg", new Set(["Collision.swift:5"])],
    ["Missing", new Set(["Missing.swift:6"])],
    ["", new Set(["Empty.swift:7"])],
  ]);
  const result = auditCatalog(catalog, extracted);

  assert.deepEqual([...result.resolved.keys()].sort(), [
    "Automatic",
    "Manual",
    "Stale",
    "Value %lld",
  ]);
  assert.deepEqual([...result.liveStale.keys()], ["Stale"]);
  assert.deepEqual([...result.empty.keys()], [""]);
  assert.deepEqual([...result.missing.keys()], ["Missing"]);
  assert.deepEqual([...result.ambiguous.keys()], ["Collision %arg"]);
  assert.deepEqual(
    [...result.ambiguous.get("Collision %arg").candidates].sort(),
    ["Collision %@", "Collision %lld"]
  );

  const integrity = auditCatalogIntegrity({
    "": { extractionState: "stale" },
    "Good %@": {
      localizations: {
        "zh-Hans": {
          stringUnit: { state: "translated", value: "好的 %1$@" },
        },
      },
    },
    "Missing translation": {},
    "Stale untranslated": { extractionState: "stale" },
    "Stale bad %lld": {
      extractionState: "stale",
      localizations: {
        "zh-Hans": {
          stringUnit: { state: "translated", value: "失效的 %1$@" },
        },
      },
    },
    "Positional %1$@": {
      localizations: {
        "zh-Hans": {
          stringUnit: { state: "translated", value: "位置 %1$@" },
        },
      },
    },
  });
  assert.deepEqual([...integrity.missingTranslations.keys()], [
    "Missing translation",
  ]);
  assert.deepEqual(integrity.emptyKeys, [""]);
  assert.deepEqual(integrity.positionalSourceKeys, ["Positional %1$@"]);
  assert.equal(integrity.placeholderMismatches.length, 0);
}

function main() {
  runSelfTests();
  if (process.argv.includes("--self-test")) {
    console.log("check-l10n-keys: self-test passed");
    return 0;
  }

  const catalogContents = readFileSync(CATALOG, "utf8");
  const catalogDocument = JSON.parse(catalogContents);
  const catalog = catalogDocument.strings;
  const { extracted, serializationIssues } = extractProductionKeys(
    catalogContents,
    catalog
  );
  const audit = auditCatalog(catalog, extracted);
  const integrity = auditCatalogIntegrity(catalog);
  const buildSetting = effectiveBuildSetting(
    readFileSync(BASE_CONFIGURATION, "utf8"),
    "SWIFT_EMIT_LOC_STRINGS"
  );
  const buildSettingValid = buildSetting === "YES";

  if (
    buildSettingValid &&
    audit.empty.size === 0 &&
    integrity.emptyKeys.length === 0 &&
    audit.missing.size === 0 &&
    audit.liveStale.size === 0 &&
    audit.ambiguous.size === 0 &&
    integrity.missingTranslations.size === 0 &&
    integrity.positionalSourceKeys.length === 0 &&
    integrity.placeholderMismatches.length === 0 &&
    serializationIssues.length === 0
  ) {
    console.log(
      `check-l10n-keys: ${audit.resolved.size} production key(s) present and live ` +
        `(${Object.keys(catalog).length} in catalog)`
    );
    return 0;
  }

  console.error(
    "check-l10n-keys: failed " +
      `(build setting ${buildSettingValid ? "ok" : "invalid"}, ` +
      `${audit.empty.size} empty source, ${integrity.emptyKeys.length} empty catalog, ` +
      `${audit.missing.size} missing, ${audit.liveStale.size} live-stale, ` +
      `${audit.ambiguous.size} ambiguous, ` +
      `${integrity.missingTranslations.size} untranslated, ` +
      `${integrity.positionalSourceKeys.length + integrity.placeholderMismatches.length} ` +
      `placeholder issue(s), ${serializationIssues.length} serialization issue(s))\n`
  );

  if (!buildSettingValid) {
    console.error(
      "  SWIFT_EMIT_LOC_STRINGS must be YES in apps/ios/Config/Base.xcconfig " +
        `for all product targets (found ${JSON.stringify(buildSetting ?? null)}).\n`
    );
  }

  if (audit.missing.size > 0) {
    console.error("  Missing from Localizable.xcstrings:");
    for (const [key, sites] of sortedMapEntries(audit.missing)) {
      console.error(`    ${JSON.stringify(key)}`);
      printSites(sites);
    }
    console.error("");
  }

  if (audit.empty.size > 0) {
    console.error("  Empty localization keys extracted:");
    for (const sites of audit.empty.values()) printSites(sites);
    console.error("");
  }

  if (integrity.emptyKeys.length > 0) {
    console.error("  Empty keys found in Localizable.xcstrings.\n");
  }

  if (audit.liveStale.size > 0) {
    console.error("  Production keys marked stale:");
    for (const [key, sites] of sortedMapEntries(audit.liveStale)) {
      console.error(`    ${JSON.stringify(key)}`);
      printSites(sites);
    }
    console.error("");
  }

  if (audit.ambiguous.size > 0) {
    console.error("  Ambiguous interpolation shapes:");
    for (const [key, entry] of sortedMapEntries(audit.ambiguous)) {
      console.error(`    ${JSON.stringify(key)}`);
      console.error(
        `      catalog candidates: ${[...entry.candidates]
          .sort()
          .map((candidate) => JSON.stringify(candidate))
          .join(", ")}`
      );
      printSites(entry.sites);
    }
    console.error("");
  }

  if (integrity.missingTranslations.size > 0) {
    console.error("  Missing required translations:");
    for (const [key, locales] of sortedMapEntries(
      integrity.missingTranslations
    )) {
      console.error(`    ${JSON.stringify(key)}: ${locales.sort().join(", ")}`);
    }
    console.error("");
  }

  if (integrity.positionalSourceKeys.length > 0) {
    console.error("  Positional placeholders found in source keys:");
    for (const key of integrity.positionalSourceKeys) {
      console.error(`    ${JSON.stringify(key)}`);
    }
    console.error("");
  }

  if (integrity.placeholderMismatches.length > 0) {
    console.error("  Translation placeholder mismatches:");
    for (const entry of integrity.placeholderMismatches) {
      const location = entry.path ? ` (${entry.path})` : "";
      console.error(
        `    ${JSON.stringify(entry.key)} [${entry.locale}]${location}: ` +
          `${entry.issue}`
      );
      console.error(`      ${JSON.stringify(entry.value)}`);
    }
    console.error("");
  }

  if (serializationIssues.length > 0) {
    console.error("  Catalog changes during a normal Xcode sync:");
    for (const issue of serializationIssues) console.error(`    ${issue}`);
    console.error("");
  }

  console.error(
    "Use compiler-owned automatic extraction where possible. Reserve " +
      '`"extractionState": "manual"` for keys produced dynamically and make ' +
      "every ambiguous format key explicit."
  );
  return 1;
}

try {
  process.exitCode = main();
} catch (error) {
  console.error(`check-l10n-keys: ${error.stack ?? error}`);
  process.exitCode = 1;
}
