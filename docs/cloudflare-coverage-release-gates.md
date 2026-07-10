# Cloudflare coverage release gates

The generated catalogs are the release source of truth:

- `OAuthScopeCatalog.json` must contain every scope returned by `GET /oauth/scopes`.
- `CloudflareEndpointCatalog.json` must contain every operation in the pinned OpenAPI snapshot.
- `OAuthScopeCoverage.json` must classify every official scope as `implemented` or
  `noPublicEndpoint` with a reason. `offline_access` is classified as `protocolManaged`.
- `FeatureCatalog.descriptors` must contain every `FeatureID`, and every feature scope must exist
  in the official scope catalog.
- `CloudflareScopes.unsupportedByOAuthClient` must match `pnpm ios:oauth-audit`. The current
  client excludes ten product `metadata_read` scopes even though they appear in `/oauth/scopes`.

Before each product wave ships:

1. Regenerate the catalogs with `apps/ios/scripts/generate-cloudflare-catalogs.rb`. Supply the
   OAuth token through `CLOUDFLARE_API_TOKEN`; the script never prints it.
2. Run `pnpm lint:fix`, `pnpm lint`, `pnpm typecheck`, and `pnpm ios:test`.
3. Verify destructive OpenAPI operations still require confirmation and large responses remain
   capped in the on-screen API Explorer.
4. Test a real OAuth client with the default permission set, a reduced read-only set, in-module
   incremental authorization, cancellation, an account without entitlement, and an expired token.
5. Revoke the temporary catalog token and confirm no credential appears in the worktree or logs.

The real OAuth checks require a configured Cloudflare OAuth client and cannot be replaced by
simulator tests.
