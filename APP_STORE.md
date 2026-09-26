# App Store review — what applies to Portway, and what was changed because of it

Portway is a VPN client, which puts it under the strictest part of the App Review Guidelines
(§5.4). This file lists every guideline that touches the app, what the code does about it, and
what only you can do. **Read the "You must" section before the first submission.**

## You must

1. **Enroll the Apple Developer account as an organization (§5.4).** "Apps offering VPN services
   … may only be offered by developers enrolled as an organization." An individual account will be
   rejected. You need a legal entity and a D-U-N-S number.
2. **Give App Review a working config (§2.1, §4.2).** The app does nothing without one. Add a
   `portway://import?c=…` link or the `.conf` text to *App Review Information → Notes*, pointing
   at a server that stays up during review. Expect them to test connect and disconnect.
3. **Publish a privacy policy URL (§5.1.1, §5.4).** It must say what is collected (see the data
   list below) and **commit to never selling it or disclosing it to third parties**. §5.4 requires
   that commitment in so many words.
4. **Fill in the App Privacy "nutrition label" to match `App/Resources/PrivacyInfo.xcprivacy`:**
   Device ID, Other Diagnostic Data and Other Data Types, all *linked to the user*, *not used for
   tracking*, purpose *App Functionality*. With the session protocol off (see PANEL.md), only the
   account lookup (public key and address) is sent.
5. **Answer export compliance (encryption).** WireGuard is not "exempt" encryption, so
   `ITSAppUsesNonExemptEncryption` is `true`. It uses standard algorithms in a mass-market product,
   which normally qualifies for the EAR 5A992 / 740.17(b)(1) self-classification route: upload the
   self-classification report in App Store Connect, and file the annual BIS report. France may
   require a separate declaration. Get this confirmed by whoever handles legal.
6. **Choose storefronts deliberately.** Some countries require a government licence to distribute
   VPN apps (China notably; §5.4: "VPN apps may not violate local laws"). Exclude them in
   *Pricing and Availability*. The App Store does not operate in Iran; users there use accounts
   from other storefronts. Nothing in the app needs to change for that, but plan distribution
   (App Store, TestFlight public link, or unlisted distribution) with it in mind.

## Changed or dropped in the port because of the guidelines

| Android feature | Guideline | What iOS does instead |
|---|---|---|
| In-app updater: downloads and installs APKs from the panel | §2.5.2: apps may not download or install executable code | Dropped. The panel's iOS feed only produces a card that opens the App Store or TestFlight. Below `min_supported_build` it cannot be dismissed. |
| Expiry notice: "Renew to stay connected" | §3.1.1 / §3.1.3(f): a free companion to a paid service may not call users to buy outside the app | Neutral wording: "Your provider can extend it." There is no renewal link, price or button anywhere in the app. Keep it that way. |
| "Allow remote control apps" broadcast intents | §2.5.1 public APIs; no iOS equivalent | App Intents and Shortcuts: Connect, Disconnect, Toggle and Status, through the system's own automation. |
| Battery-optimisation exemption request | No iOS equivalent | Dropped. |
| Per-app split tunnelling | Not available to App Store VPN apps (per-app VPN is MDM only) | Dropped. AllowedIPs-based splitting still works. |
| Several tunnels at once | iOS runs one VPN at a time | Dropped. Starting one config stops the other. |

## Added because of the guidelines

- **Data disclosure before use (§5.4).** "VPN apps must … clearly declare what user data will be
  collected and how it will be used on an app screen prior to any user action to purchase or
  otherwise use the service." Onboarding step 3, "What Portway sends, and to whom", lists every
  field the panel receives, who receives it, that it is never sold, and that the private key and
  traffic never leave the tunnel.
- **Privacy manifests** (`PrivacyInfo.xcprivacy`) for the app, the tunnel and the widgets. They
  declare the UserDefaults app-group reason (1C8F.1) and the timing API reason (35F9.1). These are
  required since May 2024; without them the upload is rejected.
- **Purpose strings** for the camera (QR only, nothing recorded) and Face ID.
- **The system VPN consent dialog is never imitated** (§5.4, §2.3.1). Onboarding and the import
  screen explain that iOS will ask; the prompt itself is the system's.

## Things that are fine as they are, and why

- **NEVPNManager / NETunnelProviderManager** is the required API (§5.4). ✔
- **Third-party calls.** DNS-over-HTTPS to 1.1.1.1 and 8.8.8.8 resolves the *server's* hostname,
  from the extension. The geo lookup (ipwho.is, ipapi.co, Cloudflare trace) runs only through the
  tunnel, so it sees the server, not the user. Both are mentioned in the in-app disclosure; mention
  them in the privacy policy too.
- **Background modes.** `fetch` is only used for `BGAppRefreshTask` (twice-daily account refresh
  for expiry warnings), which is its intended use.
- **Account deletion (§5.1.1(v)).** There are no accounts in the app, so nothing to delete.
  Removing a config deletes its key and cached data from the device.
- **Kill switch** (`includeAllNetworks`) and **Connect On Demand** are public, documented APIs.
- **Panel URL field in Settings.** A user- or operator-configured endpoint, not hidden
  functionality (§2.3.1). The session protocol flag is build-time and documented, not a remote
  kill switch for features.

## Before each release

- Run `tools/typecheck.sh`, `tools/run-core-tests.sh` and a device build.
- Check that the review notes still point at a live config.
- If a new field is sent to the panel, update the privacy manifest, the nutrition label, the
  onboarding disclosure (`onboard_body_ios_data` in both languages) and the privacy policy
  together.
