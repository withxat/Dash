# Dash for Cloudflare — Privacy Policy

Effective August 4, 2026.

Dash for Cloudflare ("Dash") is an unofficial native iOS client for managing
Cloudflare accounts. Core account API requests go directly from your device to
Cloudflare. The limited on-device and relay processing used by specific
features is described below.

## What Dash collects

Dash contains no product analytics, third-party crash-reporting SDKs,
advertising identifiers, or tracking SDKs. We do not use data to track you
across apps or websites, or for advertising. The app's privacy manifest
declares tracking disabled. Temporary files and the narrowly scoped relay
processing below support app functionality; they are not used for analytics,
advertising, or tracking.

## Where your data lives

- **OAuth tokens** are issued to you by Cloudflare when you sign in and are
  stored only in your device's Keychain. They never leave your device except
  as request credentials sent directly to Cloudflare's API.
- **Account data** (zones, DNS records, Workers, storage objects, and
  everything else you browse or edit) normally travels directly between your
  device and `api.cloudflare.com` over HTTPS. Dash caches resource metadata in
  memory for the current session.
- **R2 temporary files** are used for previews, thumbnails, uploads, downloads,
  exports, renames, and moves without loading an entire object into memory.
  Operation files are removed when the operation completes, fails, or is
  cancelled. An exported file can remain for about 10 minutes so the receiving
  app has time to copy it. If Dash is force-quit or crashes, R2 temporary files
  older than one hour are removed the next time Dash launches. Signing out
  explicitly removes Dash's R2 temporary-file directory.
- **Share extension staging** copies selected images into the extension's
  temporary directory while preparing and uploading them. The directory is
  removed on completion, cancellation, or failure; abandoned staging
  directories older than one hour are removed the next time the share
  extension opens.
- **Preferences** (home-screen shortcuts, recently opened resources, pinned
  zones, and the selected account) are stored
  locally in the app's own settings storage on your device.

## The relay worker

Cloudflare requires an HTTPS redirect URL for sign-in, so the authorization
response passes through a small Cloudflare Worker we operate (`dash-relay` at
`dash.xat.sh`). The worker redirects the callback to the app. It does not
persist authorization state, Cloudflare credentials, or the PKCE verifier, and
it does not log OAuth query parameters. Its source code is available for
inspection in the Dash repository.

When you open a domain detail screen, Dash sends that domain name without an
OAuth token to `dash.xat.sh` for a public registration lookup. The relay queries
RDAP and, when necessary, WHOIS. It caches a successful public registration
snapshot for up to 12 hours, or a missing-result response for up to one hour,
using Cloudflare's Cache API. For abuse protection, it uses the connecting IP
address only as the key for an hourly request counter, also cached for at most
one hour. These values are not used for analytics, advertising, or tracking.

For a signed-in real account, Dash requests quiet notification delivery from
iOS, registers this device with Apple Push Notification service, and creates a
per-device webhook destination in your own Cloudflare account. Dash does not
attach that destination to your existing ordinary notification policies
automatically; policies created or managed in Dash attach it explicitly. Legacy
Dash webhook bindings are removed from Pages build policies while their email,
PagerDuty, and unrelated webhook destinations are preserved. Dash does not
create new alert policies automatically or derive or schedule notifications
from fetched account or resource data. Pages and Workers build monitoring
instead uses app-driven Live Activities and does not pass through this webhook.
When an eligible policy fires, Cloudflare posts the alert to `dash.xat.sh`,
which forwards a push to this iPhone. The relay does not store
device tokens, alert payloads, or notify URLs; those live in the signed webhook
URL and your Cloudflare account.

Other than the bounded registration and rate-limit Cache API entries described
above, the relay has no KV, Durable Object, or database storage.

## Gravatar avatars

To show a profile picture, Dash requests an avatar from `gravatar.com` using
an MD5 hash of your Cloudflare account email address. The request carries no
Cloudflare credentials or cookies; if no Gravatar exists, Dash falls back to
your initials. Gravatar is operated by Automattic Inc. and has its own
[privacy policy](https://automattic.com/privacy/).

## What we can see

We do not receive your OAuth tokens or Cloudflare traffic. The relay necessarily
processes the OAuth callback, registration lookup, and push-alert
requests described above, but the app code does not use those requests for
product analytics or tracking. Support happens over email, with only the
information you choose to share.

## Data deletion

Signing out revokes the OAuth token with Cloudflare, deletes it from your
Keychain, attempts to remove this device's webhook from your Cloudflare
notification policies and delete that webhook, clears in-memory session data,
and removes Dash's R2 temporary files.
Deleting the app removes locally stored preferences and extension staging
files. Registration snapshots and IP-based rate-limit counters expire
automatically within the periods described above. Dash holds no persistent
server-side copy of your Cloudflare account data.

Deleting Dash without signing out prevents the app from removing the webhook
destination from your Cloudflare account. You can remove a leftover destination
and its policy bindings from the Cloudflare dashboard.

## Changes

If this policy ever changes, the change will be documented here with a new
effective date. Material data flows remain controllable through Cloudflare or
iOS settings where applicable.

## Contact

Questions about privacy: **i@xat.sh**
