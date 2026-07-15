# Dash for Cloudflare — Privacy Policy

_Draft — effective date to be set when published._

Dash for Cloudflare ("Dash") is an unofficial native iOS client for managing
Cloudflare accounts. It is built so that your data stays between your device
and Cloudflare.

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
- **Preferences** (home-screen shortcuts, recently opened resources, pinned
  zones, the selected account, experimental-feature visibility, and Watchtower notification opt-in) are stored
  locally in the app's own settings storage on your device.

## The relay worker

Cloudflare requires an HTTPS redirect URL for sign-in, so the authorization
response passes through a small Cloudflare Worker we operate (`dash-relay` at
`dash.xat.sh`). The worker redirects the callback to the app. It does not
persist authorization state, Cloudflare credentials, or the PKCE verifier, and
it does not log OAuth query parameters. Its source code is available for
inspection in the Dash repository.

Watchtower's "Notify on new issues" switch uses notifications generated locally
on your device. Dash does not register the app for remote notifications or send
Watchtower data through the relay.

## Gravatar avatars

To show a profile picture, Dash requests an avatar from `gravatar.com` using
an MD5 hash of your Cloudflare account email address. This is the only
third-party network request the app makes.
The request carries no cookies or credentials; if no Gravatar exists, Dash
falls back to your initials. Gravatar is operated by Automattic Inc. and has
its own [privacy policy](https://automattic.com/privacy/).

## What we can see

We cannot see anything about your Cloudflare account, tokens, traffic, or
whether you use the app. Support happens over email, with only the information
you choose to share.

## Data deletion

Signing out revokes the OAuth token with Cloudflare, deletes it from your
Keychain, and clears session data. Deleting the app removes all locally stored
preferences. Dash holds no server-side account data about you.

## Changes

If this policy ever changes, the change will be documented here with a new
effective date, and any new data flow will be opt-in.

## Contact

Questions about privacy: **i@xat.sh**
