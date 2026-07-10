import { readFile } from "node:fs/promises";

const token = process.env.CLOUDFLARE_API_TOKEN;
const accountID = process.env.CLOUDFLARE_ACCOUNT_ID;
const clientID = process.env.CLOUDFLARE_OAUTH_CLIENT_ID;

if (!token || !accountID || !clientID) {
  console.error(
    "Set CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, and CLOUDFLARE_OAUTH_CLIENT_ID.",
  );
  process.exit(1);
}

const response = await fetch(
  `https://api.cloudflare.com/client/v4/accounts/${encodeURIComponent(accountID)}/oauth_clients/${encodeURIComponent(clientID)}`,
  { headers: { Authorization: `Bearer ${token}` } },
);
const payload = await response.json();
if (!response.ok || payload.success !== true) {
  console.error(
    payload.errors?.[0]?.message ?? `OAuth Client request failed with HTTP ${response.status}.`,
  );
  process.exit(1);
}

const catalog = JSON.parse(
  await readFile(
    new URL(
      "../../../packages/cloudflare-api/Sources/CloudflareAPI/Resources/OAuthScopeCatalog.json",
      import.meta.url,
    ),
    "utf8",
  ),
);
const official = new Set(catalog.scopes.map((scope) => scope.id));
const allowed = new Set(payload.result.scopes ?? []);
const protocolScopes = new Set(["offline_access", "openid"]);
const unknown = [...allowed]
  .filter((scope) => !official.has(scope) && !protocolScopes.has(scope))
  .sort();
const missing = [...official].filter((scope) => !allowed.has(scope)).sort();

console.log(`OAuth Client allowlist: ${allowed.size} scopes`);
console.log(`Official catalog: ${official.size} scopes`);
console.log(`Official scopes not allowlisted: ${missing.length}`);
for (const scope of missing) console.log(`- ${scope}`);

if (unknown.length > 0) {
  console.log(`Unknown or stale allowlist entries: ${unknown.length}`);
  for (const scope of unknown) console.log(`- ${scope}`);
}
