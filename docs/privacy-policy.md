# Dash for Cloudflare — Privacy Policy

_Draft — effective date to be set when published._

Dash for Cloudflare ("Dash") is an unofficial native iOS client for managing
Cloudflare accounts. It is built so that your data stays between your device
and Cloudflare.

## What Dash collects

**Nothing.** Dash contains no analytics, no crash-reporting SDKs, no tracking,
no advertising identifiers, and no third-party frameworks. The app's privacy
manifest declares zero collected data types, and we have no servers that
receive, store, or process your account data.

## Where your data lives

- **OAuth tokens** are issued to you by Cloudflare when you sign in and are
  stored only in your device's Keychain. They never leave your device except
  as request credentials sent directly to Cloudflare's API.
- **Account data** (zones, DNS records, Workers, storage objects, and
  everything else you browse or edit) travels directly between your device
  and `api.cloudflare.com` over HTTPS. Dash displays it and caches some of it
  in memory for the current session only; nothing is written to disk.
- **Preferences** (home-screen shortcuts, recently opened features, pinned
  zones, the selected account) are stored locally in the app's own settings
  storage on your device.

## The OAuth relay

Cloudflare requires an HTTPS redirect URL for sign-in, so the authorization
response passes through a small Cloudflare Worker we operate (`dash-relay`)
whose only job is to redirect your browser back into the app. The relay is
stateless: it does not log query parameters, does not persist anything, and
never sees your tokens or the PKCE verifier. Its source code is available for
inspection in the Dash repository.

## Gravatar avatars

To show a profile picture, Dash requests an avatar from `gravatar.com` using
an MD5 hash of your Cloudflare account email address. This is the only
third-party network request the app makes. The request carries no cookies or
credentials; if no Gravatar exists, Dash falls back to your initials. Gravatar
is operated by Automattic Inc. and has its own
[privacy policy](https://automattic.com/privacy/).

## What we can see

Nothing. We cannot see your Cloudflare account, your tokens, your traffic, or
even whether you use the app. Support happens over email, with only the
information you choose to share.

## Data deletion

Signing out revokes the OAuth token with Cloudflare and deletes it from your
Keychain. Deleting the app removes all locally stored preferences. Dash holds
no server-side data about you, so there is nothing further to delete.

## Changes

If this policy ever changes — for example, if an optional push-notification
service is added — the change will be documented here with a new effective
date, and any new data flow will be opt-in.

## Contact

Questions about privacy: **i@xat.sh**
