# Cloudflare OAuth release gates

The official scope catalog is the authorization source of truth:

- `OAuthScopeCatalog.json` must contain every scope returned by `GET /oauth/scopes`.
- `FeatureCatalog.descriptors` must contain every `FeatureID`, and every declared scope must exist
  in the official scope catalog.
- `DashAuthorizationScopes.initialReadOnly` is the reviewed Demo profile. It must keep every
  catalog feature browsable without containing a mutation scope.
- `DashAuthorizationScopes.core` is the audited union of every currently shipped read and write
  capability, and the default real-account OAuth request.
- `CloudflareScopes.unsupportedByOAuthClient` must match `pnpm ios:oauth-audit`. The current
  client excludes ten product `metadata_read` scopes even though they appear in `/oauth/scopes`.

Before a release that changes authorization:

1. Regenerate `OAuthScopeCatalog.json` with
   `ruby apps/ios/scripts/generate-cloudflare-scopes.rb`. Supply the OAuth token through
   `CLOUDFLARE_API_TOKEN`; the script never prints it.
2. Run `pnpm ios:oauth-audit`, `pnpm lint:fix`, `pnpm lint`, `pnpm typecheck`, and
   `pnpm ios:test`.
3. Test a real OAuth client with the full `core` grant, cancellation, upgrade from a legacy
   read-only grant, an account without entitlement, and an expired token. Confirm the audited
   full-capability set matches the scopes used by current features.
4. Confirm a previously authenticated broad-scope session remains valid and is not silently
   rewritten.
5. Revoke the temporary catalog token and confirm no credential appears in the worktree or logs.

The real OAuth checks require a configured Cloudflare OAuth client and cannot be replaced by
simulator tests.
