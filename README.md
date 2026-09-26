# Portway for iOS

The iOS port of Portway, the consumer WireGuard client built on wireguard-android
(`~/dev/wireguard-app`). Same panel, same deep link, same Nocturne design and the same English
and Persian copy. It is rebuilt natively on SwiftUI and WireGuardKit rather than forked from
wireguard-apple's UIKit app.

Also read:

- [PANEL.md](PANEL.md): what the panel must agree before the session protocol goes on.
- [APP_STORE.md](APP_STORE.md): review guidelines, and what the port changed because of them.
- [DNS.md](DNS.md): why iPhones got stuck on an old server IP, and how Portway recovers.

## Features: Android → iOS

| Android | iOS | Notes |
|---|---|---|
| Connect ring, kicker, session timer, "Not reaching the server" | ✔ same | The timer comes from the extension, so it survives watchdog restarts |
| Handshake decay bar (180 s track, 118 s rekey mark, fresh/late/waiting/silent) | ✔ same | Grows over 0.9 s, snaps back on a new handshake, mirrors in RTL |
| Configs list with geography line, ping dot, tap-to-switch | ✔ same | |
| Import: deep link, QR, file (content-based, zip), naming screen | ✔ + more | Also paste from clipboard, a QR from a screenshot in Photos, and "Open in Portway" from Files, Mail and chat apps. Multi-config zips step through one by one |
| Config detail: throughput, 14-day band, health, collapsed config | ✔ same | Plus resolved address and restart count. Tap to copy |
| Editor | ✔ text editor | The wg-quick text with the parser's errors. Face ID before a private key is shown |
| Account card, days-left chip, 30-day usage, quota rail | ✔ same | Usage is kept **per config** (Android keeps one global series) |
| One-device session guard (claim, takeover, heartbeat, release) | ✔ built, **off** | Heartbeat runs in the tunnel extension. Behind `PORTWAY_SESSION_PROTOCOL`, see PANEL.md |
| Disconnect reasons | ✔ better | Read from `NEProviderStopReason`; only `killed` is inferred |
| Handshake watchdog + silence clock | ✔ better | Runs in the extension, and "restart" re-applies the config **without tearing the tunnel down**, so no traffic slips out and it never looks like a disconnect |
| Network-change recovery | ✔ WireGuardKit | WireGuardKit already rebinds on path changes; Portway resets the watchdog backoff on a network change |
| Endpoint resolver: DoH → panel hint → system, never rewriting the host | ✔ better | Adds plain DNS to public resolvers (not blocked like DoH, no carrier cache), re-checks every 3 min and on network changes, prefers a new address after a failure. See DNS.md |
| Geo "surfaces in Frankfurt" | ✔ same rules | The panel's answer first. Device lookup only from the app, only while handshaking, only for full-tunnel configs |
| Ping: ICMP, then TCP 443, then TCP 80 | ✔ same | Every wait is `poll()` with a deadline |
| Plan-expiry warnings | ✔ better | Scheduled with the OS for the 3/2/1/0-day dates, so they arrive even if Portway never runs again |
| Always-on + lockdown (system settings only) | ✔ **in-app switches** | Kill switch = `includeAllNetworks`; Always on = Connect On Demand, with **trusted Wi-Fi** exceptions |
| Quick Settings tile, toggle shortcut | ✔ Control Center | iOS 18 control, plus home and lock-screen widgets |
| Remote-control broadcasts | ✔ Shortcuts | Connect, Disconnect, Toggle and Status App Intents, with Siri phrases |
| — | **new** Live Activity | Lock screen and Dynamic Island: timer, place, a Disconnect button |
| — | **new** app lock | Face ID or passcode when Portway goes to the background |
| Biometric gate on zip export | ✔ same | Share sheet instead of the Downloads folder |
| English and Persian with an in-app switch; Vazirmatn UI; isolates; RTL | ✔ same | Strings are generated from the Android XML (`tools/import_android_strings.py`) |
| Onboarding | ✔ + a data step | iOS adds "What Portway sends, and to whom", which guideline 5.4 requires |
| Dark / light / system theme | ✔ same | |
| In-app APK updater | ✘ → update card | App Store guideline 2.5.2. The card opens the App Store or TestFlight |
| Battery optimisation, per-app split tunnel, several tunnels at once | ✘ | No iOS equivalent (see APP_STORE.md) |

## Layout

```
project.yml              XcodeGen spec (Portway.xcodeproj is generated and git-ignored)
Config/                  Base.xcconfig (ids, flags); Local.xcconfig (git-ignored: team, panel URL)
App/                     the SwiftUI app
  Sources/Model/         TunnelStore (profiles, connect/claim, polling), GeoLookup
  Sources/Screens/       Home, Configs, Detail, Editor, Import, Scanner, Settings, Onboarding, Log
  Sources/Components/    ConnectRing, HandshakeDecayBar, readouts, buttons, switch
Tunnel/                  PacketTunnelProvider: WireGuard, watchdog, heartbeat, usage, resolver
Widgets/                 widgets, Control Center control, Live Activity UI
Shared/                  Theme (Nocturne tokens), fonts, App Intents, Live Activity model
Packages/Portway/
  PortwayCore            panel, session guard, health rules, usage, resolver, pinger, i18n
                         (no WireGuardKit dependency, so it is testable anywhere)
  PortwayKit             wg-quick parser, keychain storage, importer
Vendor/WireGuardKit/     wireguard-apple's library, vendored (see below)
tools/                   strings import, type-check, core tests
```

## Build

One-time setup:

```bash
sudo xcodebuild -license accept
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
brew install xcodegen                        # Go is already installed (the bridge needs it)
cp Config/Local.example.xcconfig Config/Local.xcconfig   # then fill in team, bundle id, panel URL
```

Then:

```bash
xcodegen generate
open Portway.xcodeproj                       # or:
xcodebuild -scheme Portway -destination 'generic/platform=iOS' build
```

The Network Extension entitlement needs a real device and a provisioning profile with the
*Network Extensions* capability. The simulator can run the UI, but it cannot bring a tunnel up.

Checks that need no Apple Developer account:

```bash
tools/typecheck.sh            # every target against the iOS SDK
tools/run-core-tests.sh       # PortwayCore: health rules, deadlines, zip, usage, and the panel
                              # contract on the wire against tools/mock_panel.py
tools/run-kit-tests.sh        # PortwayKit: parser, importer, bring-up rewriting (builds wg-go for macOS)
tools/sim.sh build            # real xcodebuild for the simulator, installs on "iPhone 17"
tools/sim.sh shot home -fa    # launches in demo mode and saves build/shots/home.png
```

**Demo mode.** The simulator cannot bring a tunnel up, so debug builds accept `-demo`: four
configs, one connected with a live handshake and throughput, usage history and an account. More
launch arguments: `-fa` / `-en`, `-light` / `-dark`, `-tab=configs|settings`, `-detail=<name>`,
`-onboarding` with `-step=N`, `-demo-silent` (the "Not reaching the server" state) and
`-open=<portway:// link>`. The same flags will produce the App Store screenshots.

After changing copy in the Android app, or in `tools/strings/*.strings`:

```bash
tools/import_android_strings.py
```

### Why WireGuardKit is vendored

Upstream wireguard-apple has not been updated since February 2023. Three changes were needed:

- `go.mod` now pins wireguard-go `v0.0.0-20260522210424`, so it builds with Go 1.26. The
  sleep-aware clock patch to the Go runtime still applies cleanly.
- `WireGuardKitC.h` includes `<sys/types.h>`. The iOS 27 SDK's stricter modules reject it without.
- The Makefile knows `iphonesimulator`, and finds Go at `/usr/local/go/bin` or Homebrew itself: Xcode launched from the Dock has no shell `PATH`.

`Package.swift` also targets iOS 17 / macOS 14 and tools version 5.9. The wg-quick parser moved
into PortwayKit, and the keychain helpers were rewritten there.

## Secrets

Never commit the panel URL or the VPN hostnames. The Android repo is public and was scrubbed of
both. They belong in `Config/Local.xcconfig`, which `.gitignore` excludes.

## Known gaps

- **Not yet run on a device.** It builds with `xcodebuild` and runs in the simulator in demo
  mode, but a tunnel needs a signed build with the Network Extension entitlement, which needs a
  paid Apple Developer account.
- **Shortcut phrases are English only.** App Intents phrases are compiled from literals; a Persian
  table needs Xcode's metadata extraction first.
- **The session protocol is off** until the panel agrees the iOS shape (PANEL.md).
