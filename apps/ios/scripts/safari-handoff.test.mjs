// Runs the Safari extension's content script — the shipped file, unmodified —
// against a stand-in page, and holds it to the same fixture list the Swift
// `CloudflareDashboardLink` tests read. The script decides *whether* to hand a
// page to Dash and the Swift parser decides *where* that lands; if the two
// disagree, Safari either keeps a link Dash could have opened or opens Dash
// onto nothing.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const SCRIPT = readFileSync(
  resolve(ROOT, "apps/ios/DashSafari/Resources/content.js"),
  "utf8"
);
const FIXTURES = JSON.parse(
  readFileSync(
    resolve(
      ROOT,
      "packages/cloudflare-api/Tests/CloudflareAPITests/Fixtures/dashboard-links.json"
    ),
    "utf8"
  )
);
const MANIFEST = JSON.parse(
  readFileSync(
    resolve(ROOT, "apps/ios/DashSafari/Resources/manifest.json"),
    "utf8"
  )
);

/**
 * Loads `href` in a page and returns where the script navigated, or null when
 * it left the page alone. `storage` persists across calls that share it, the
 * way one tab's sessionStorage does.
 */
function load(href, { storage = new Map(), framed = false, storageThrows = false } = {}) {
  let navigated = null;
  const location = {
    get href() {
      return href;
    },
    set href(value) {
      navigated = value;
    },
  };
  const sessionStorage = {
    getItem(key) {
      if (storageThrows) throw new Error("SecurityError");
      return storage.has(key) ? storage.get(key) : null;
    },
    setItem(key, value) {
      if (storageThrows) throw new Error("SecurityError");
      storage.set(key, String(value));
    },
  };
  const window = {};
  window.top = framed ? {} : window;
  vm.runInNewContext(SCRIPT, {
    window,
    location,
    sessionStorage,
    URL,
    encodeURIComponent,
    decodeURIComponent,
  });
  return navigated;
}

/** What Dash receives: the page address, back out of the `dash://open` wrapper. */
function handedOver(navigated) {
  const url = new URL(navigated);
  assert.equal(url.protocol, "dash:");
  assert.equal(url.hostname, "open");
  assert.deepEqual([...url.searchParams.keys()], ["url"]);
  return url.searchParams.get("url");
}

test("hands over exactly the links the Swift parser can place", () => {
  assert.ok(FIXTURES.some((fixture) => fixture.opens));
  assert.ok(FIXTURES.some((fixture) => !fixture.opens));
  for (const { url, opens } of FIXTURES) {
    const navigated = load(url);
    if (opens) {
      assert.notEqual(navigated, null, `should hand over ${url}`);
      // Byte for byte, query and fragment included: Dash parses this string.
      assert.equal(handedOver(navigated), url);
    } else {
      assert.equal(navigated, null, `should leave ${url} in Safari`);
    }
  }
});

test("asks once per resource in a tab, not once per address", () => {
  const account = "0123456789abcdef0123456789abcdef";
  const deployment = "4fcdd3b4-e0a7-42df-b2d9-4a89a1981d9d";
  const placeholder = `https://dash.cloudflare.com/?to=/:account/pages/view/portal/${deployment}`;
  const resolved = `https://dash.cloudflare.com/${account}/pages/view/portal/${deployment}`;
  const storage = new Map();

  assert.notEqual(load(placeholder, { storage }), null);
  // A reload after "Cancel".
  assert.equal(load(placeholder, { storage }), null);
  // The dashboard's own redirect to the account's path: the same deployment.
  assert.equal(load(resolved, { storage }), null);
  // A different deployment in the same tab is a new question.
  assert.notEqual(
    load(`https://dash.cloudflare.com/${account}/pages/view/portal/aaaaaaaa`, { storage }),
    null
  );
  // Another tab starts clean.
  assert.notEqual(load(resolved), null);
});

test("stays out of frames and survives blocked storage", () => {
  const url =
    "https://dash.cloudflare.com/0123456789abcdef0123456789abcdef/pages/view/portal";
  assert.equal(load(url, { framed: true }), null);
  assert.notEqual(load(url, { storageThrows: true }), null);
});

test("the manifest runs the script only on the dashboard, with no permissions", () => {
  assert.deepEqual(MANIFEST.content_scripts, [
    {
      matches: ["https://dash.cloudflare.com/*"],
      js: ["content.js"],
      run_at: "document_start",
    },
  ]);
  assert.equal(MANIFEST.permissions, undefined);
  assert.equal(MANIFEST.host_permissions, undefined);
  assert.equal(MANIFEST.background, undefined);
  // The manifest cannot read build settings, so its version is a literal.
  const marketingVersion = readFileSync(
    resolve(ROOT, "apps/ios/Config/Base.xcconfig"),
    "utf8"
  ).match(/^MARKETING_VERSION = (.+)$/m)?.[1];
  assert.equal(MANIFEST.version, marketingVersion);
  // Every file the manifest names ships beside it.
  for (const path of [...Object.values(MANIFEST.icons), "content.js"]) {
    readFileSync(resolve(ROOT, "apps/ios/DashSafari/Resources", path));
  }
  for (const locale of ["en", "zh_CN"]) {
    const messages = JSON.parse(
      readFileSync(
        resolve(ROOT, `apps/ios/DashSafari/Resources/_locales/${locale}/messages.json`),
        "utf8"
      )
    );
    for (const key of ["extension_name", "extension_description"]) {
      assert.ok(messages[key]?.message, `${locale} is missing ${key}`);
    }
  }
});
