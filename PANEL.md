# Panel contract — what the iOS app needs from mikrotik-manager

**Status: proposal, not yet agreed.** Written for the panel's owner (mikrotik-manager). The iOS app
talks to the same endpoints as Android (see the Android repo's `SESSION.md`), and a handful of
fields differ by platform.

The panel **stores what it is sent** rather than rejecting unknown shapes. A guessed field would
land in the database silently, and silent field drops have already happened twice in panel handlers.
So everything below that writes session data is behind a build flag, `PORTWAY_SESSION_PROTOCOL`,
which is **off**. With it off, the app behaves exactly as it does when the panel is unreachable:
the protocol is fail-open by design.

What works today, with the flag off:

- `GET /api/peer/info`: account card, days left, expiry warnings, the `panel_url` move, the
  `endpoint_ip` resolver hint, and `city` / `country_code`. It is read-only and identical to Android.
- Nothing else is sent.

## 1. Platform and version numbering

Android's `app_version` is its `versionCode` (533 today), and the fleet page and update feed key on
it. iOS build numbers start at 1 and would collide with it.

**Proposal:** every register, claim and heartbeat carries `"platform": "ios"`. Android sends no
`platform`, which the panel reads as `"android"`. `app_version` stays an integer, but it is the iOS
`CFBundleVersion` and is only comparable within a platform. The fleet page shows
`platform + app_version`.

## 2. `os_version`

Android sends `"13 (33)"`, meaning release (API level). **Proposal:** iOS sends the same shape,
`"18.2 (22C152)"`, meaning release (build). If the panel parses the number inside the parentheses
as an API level, it needs a platform branch.

## 3. `device_name`

iOS no longer gives apps the name the user chose for the device (and it would often be a person's
name). The app sends `"Apple iPhone 15 Pro"`, the maker plus the model. Models newer than the app's
table go out as `"Apple iPhone18,1"`.

## 4. `device_id`

A random UUID stored in the app group. **A reinstall is a new device**, which matches Android
deliberately. A keychain-stored ID would survive reinstalls on iOS only, and the fleet page would
then count devices differently per platform.

## 5. `always_on` / `lockdown`

Android sends these only where it can read them (a running VpnService, Android 10+), and absent
never means false. iOS **can** read its equivalents, but they are not quite the same thing:

| Field | iOS source | Difference from Android |
|---|---|---|
| `always_on` | Connect On Demand with an "always connect" rule (Settings → Always on) | Trusted Wi-Fi networks can make it stand down |
| `lockdown` | `includeAllNetworks` (Settings → Kill switch) | Per profile, not system-wide; local network may be allowed |

**Question for the panel:** keep these field names with the iOS meaning, or add `on_demand` /
`include_all_networks` instead? Until this is answered they are sent under the Android names, and
only with the flag on.

`battery_unrestricted` has no iOS equivalent and is **omitted** (absent ≠ false).

## 6. Heartbeat link fields

The link fields are the same as Android's and follow the same rules: `link_state` ∈
`handshaking | connecting | stale | no_handshake`; `handshake_age` and `silent_for` are absent when
unknown; `rx_bytes`, `tx_bytes`, `restarts`, `connected_for` and `transport`.

On iOS the heartbeat runs in the packet-tunnel extension every 60 s for as long as the VPN is up,
including while the app is suspended. Android relied on its process staying alive.

## 7. `last_disconnect_reason`

Same vocabulary. iOS maps the system's own stop reasons:

| iOS `NEProviderStopReason` | Sent as |
|---|---|
| userInitiated, configurationRemoved | `user` |
| superceded, configurationDisabled (another profile started) | `replaced` |
| appUpdate | `update` |
| panel said another device took over | `superseded` |
| no stop recorded before the next start (jetsam) | `killed` |
| everything else | `system` |

## 8. Update feed

Android's `/api/app/latest` describes an APK. **Proposal:** `GET /api/app/latest?platform=ios` answers:

```json
{ "platform": "ios", "build": 12, "version": "1.2.0",
  "url": "https://apps.apple.com/app/id0000000000",
  "notes": "optional", "min_supported_build": 8 }
```

The app **only believes an answer that says `"platform": "ios"`**, so a panel that ignores the
parameter and returns the Android manifest does nothing. `url` must be `https`, `itms-apps` or
`itms-beta` (App Store or TestFlight). There is no sha256 and no same-origin rule: iOS installs,
not the app. Below `min_supported_build` the card cannot be dismissed.

## 9. Deep link

No change. `portway://import?c=<base64url>&name=…` is handled identically, so the peer page's
existing button works on iPhone too. iOS additionally opens `.conf` and `.zip` files shared from
Files, Mail or a chat app.

## Turning it on

Once the panel confirms the **stored row** (not just a 200 response) for a register, claim,
heartbeat and release sent by an iOS build, set `PORTWAY_SESSION_PROTOCOL = YES` in
`Config/Local.xcconfig` and ship.

## 10. One-tap import link (proposed, with the Android session in agreement)

Today's button, `portway://import?c=<whole .conf>`, has two problems:

- Chat apps (Telegram, WhatsApp) often don't make custom schemes tappable.
- The private key sits in the URL, so it ends up in chat and browser history.

Proposal:

1. **The panel mints a token** per peer: 128-bit random, single-use, expires in 24 h.
   The link is `https://<link host>/i/<token>`.
2. **`GET /i/<token>` is an ordinary web page and must not consume the token,** because chat
   previews fetch it. It shows:
   - "Open in Portway" → `portway://import?t=<token>&h=<link host>` (the `c=` form still works)
   - the QR code and the `.conf` download
   - App Store / TestFlight and APK links
3. **The app redeems it:** `POST https://<link host>/api/import/redeem {"token": "…", "platform": "ios"}`
   → `200 {"conf": "<wg-quick>", "name": "…"}` · `410` used or expired · `404` unknown. Only this
   call consumes the token.
4. **Universal Links and App Links:** `https://<link host>/.well-known/apple-app-site-association`
   (appID `<TEAMID>.<bundle id>`, path `/i/*`) and `/.well-known/assetlinks.json`. With those,
   tapping the https link in a chat opens the app directly, one tap to the confirmation screen.
   The link host goes in the build's `PORTWAY_LINK_HOST` (git-ignored `Local.xcconfig`), never in
   this public repo.
5. **A stable link host, separate from the panel, is preferred.** Universal and App Links are
   fixed in the installed build, while `panel_url` can move.

**iOS status:** both link forms are parsed, and redeeming is implemented and tested against
`tools/mock_panel.py`. The Associated Domains entitlement is added once the link host is agreed,
because it needs a paid developer account and the final host.
