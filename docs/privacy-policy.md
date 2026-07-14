# Dash for Cloudflare — Privacy Policy

_Draft — effective date to be set when published._

Dash for Cloudflare ("Dash") is an unofficial native iOS client for managing
Cloudflare accounts. It is built so that your data stays between your device
and Cloudflare, with one optional exception for push alerts (below).

## What Dash collects

**Nothing by default.** Dash contains no analytics, no crash-reporting SDKs, no
tracking, no advertising identifiers, and no third-party frameworks. The app's
privacy manifest declares zero collected data types. We do not operate a
general-purpose backend that stores your account data.

## Where your data lives

- **OAuth tokens** are issued to you by Cloudflare when you sign in and are
  stored only in your device's Keychain. They never leave your device except
  as request credentials sent directly to Cloudflare's API.
- **Account data** (zones, DNS records, Workers, storage objects, and
  everything else you browse or edit) travels directly between your device
  and `api.cloudflare.com` over HTTPS. Dash displays it and caches some of it
  in memory for the current session only; nothing is written to disk.
- **Preferences** (home-screen shortcuts, recently opened features, pinned
  zones, the selected account, Watchtower notification opt-in) are stored
  locally in the app's own settings storage on your device.

## The relay worker

Cloudflare requires an HTTPS redirect URL for sign-in, so the authorization
response passes through a small Cloudflare Worker we operate (`dash-relay` at
`dash.xat.sh`). The same worker also hosts the optional push bridge. The
worker is stateless: it does not persist authorization state, Cloudflare
credentials, or the PKCE verifier, and it does not log OAuth query parameters.
Its source code is available for inspection in the Dash repository.

## Optional push alerts

If you turn on **Push Cloudflare alerts** under Account → Alerts, Dash:

1. Registers this device's APNs token with the relay and receives a signed
   webhook URL.
2. Creates a webhook destination and notification policies **in your own
   Cloudflare account** that point at that URL.
3. When Cloudflare fires an alert, the relay receives the alert text, device
   token, and related fields long enough to deliver an Apple Push Notification,
   then discards them. It stores nothing.

This flow is opt-in. Signing out deletes the webhook from your Cloudflare
account (best-effort) and clears local push state. Watchtower's separate
"Notify on new issues" switch is local-only and does not send data through the
relay.

## Gravatar avatars

To show a profile picture, Dash requests an avatar from `gravatar.com` using
an MD5 hash of your Cloudflare account email address. Aside from the optional
push bridge above, this is the only third-party network request the app makes.
The request carries no cookies or credentials; if no Gravatar exists, Dash
falls back to your initials. Gravatar is operated by Automattic Inc. and has
its own [privacy policy](https://automattic.com/privacy/).

## What we can see

Without push enabled: nothing about your Cloudflare account, tokens, traffic,
or whether you use the app.

With push enabled: while an alert is being delivered, the relay processes the
alert text Cloudflare sends and the APNs device token needed to reach your
phone. Those values are not retained. Support still happens over email, with
only the information you choose to share.

## Data deletion

Signing out revokes the OAuth token with Cloudflare, deletes it from your
Keychain, and (if push was enabled) removes the Dash webhook from your
Cloudflare account. Deleting the app removes all locally stored preferences.
Dash holds no other server-side account data about you.

## Changes

If this policy ever changes, the change will be documented here with a new
effective date, and any new data flow will be opt-in.

## Contact

Questions about privacy: **i@xat.sh**
