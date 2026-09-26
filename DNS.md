# When the server's IP changes

**The problem users hit:** the VPN server gets a new IP. The hostname in the config is updated,
but iPhones keep connecting to the old address. Toggling the VPN doesn't help; restarting the
phone does, so the user is offline until they happen to try that.

## Why it happens (stock WireGuard on iOS)

1. **WireGuardKit looks the hostname up once, when the tunnel starts,** and keeps that IP. When the
   network changes (Wi-Fi to mobile, waking up), it re-applies the same IP. It never asks DNS
   again while connected. See `didReceivePathUpdate` and `endpointUapiConfiguration` in
   `Vendor/WireGuardKit/Sources/WireGuardKit/`.
2. **The lookup goes through the system resolver.** iOS's DNS cache and, much more often, the
   carrier's resolver keep old records long past their TTL. Toggling the VPN asks again and gets
   the same stale answer. A reboot clears the phone's cache, which is why it "fixed" things.

## What Portway does instead

**It resolves the hostname itself, bypassing the caches.** It does this at every connect, at every
watchdog restart, every 3 minutes while connected, and on every network change.
`EndpointResolver` asks every source at once, under one 3.5-second budget, and takes the answers
in this order:

| # | Source | Why it's trusted in this position |
|---|---|---|
| 1 | DNS over HTTPS (1.1.1.1, 8.8.8.8) | No cache between us and the authority. Often blocked in Iran; after two failures it's probed but not waited on. |
| 2 | Plain DNS, UDP port 53, sent directly to 1.1.1.1 / 8.8.8.8 / 9.9.9.9 | Skips the phone's and the carrier's caches, and usually works where DoH is blocked. Answers in private or reserved ranges (what DNS injection hands out) are discarded. |
| 3 | The panel's `endpoint_ip`, if fetched in the last 10 minutes (refreshed during a restart) | The address the operator recorded in the panel. It is updated when the panel moves a server, not detected, so it ranks below the hostname's own DNS. It is what finds the server when both DNS paths are blocked. |
| 4 | The system resolver | Possibly stale, but better than nothing. |
| 5 | An older panel hint | Last resort. |

It also does three more things:

- **Looks for a *different* address after a failure, but never trusts a worse source for it.**
  When a name has several IPs, the one that just failed is skipped. Across sources the order above
  stays strict, so a short outage at the *right* address never sends the tunnel to an old one a
  carrier cache still holds.
- **Switches without waiting for the tunnel to fail.** The 3-minute check applies a new address as
  soon as the one in use is no longer among the answers. Checking "among" rather than "equal"
  means round-robin DNS doesn't cause restarts.
- **Detects a dead link sooner.** With a keepalive configured, if the tunnel keeps sending but
  hears nothing back and no handshake has completed for 155 seconds, it restarts. The previous
  threshold was 180 s. Restarts re-apply the configuration without tearing the tunnel down,
  retrying 5 times quickly and then backing off to at most 15 minutes. They never give up.

The hostname stored in the config is **never** rewritten. Only the address used to connect
changes.

## What users will see

These are simulated in `Packages/Portway/Tests/PortwayCoreTests/DNSRecoveryTests.swift` (run
`tools/run-core-tests.sh`):

| Situation | Before | Now |
|---|---|---|
| Server moves and DNS is updated at the same time | Offline until the phone restarts | Back within one 3-minute check (70 s in the test run) |
| DNS updated 10 minutes after the move | Same | Back within one check of DNS updating |
| Server reboots on the same IP | Recovers | Recovers, with no user action |
| User taps Connect after the move | Stale cached IP | Fresh address, first try |

## What the operator can do to make it faster

- **Keep the record's TTL at 60 s.** The public resolvers above honour it; carriers are bypassed.
- **Move servers through the panel (the migration wizard) when possible,** so `endpoint_ip` in
  `/api/peer/info` changes with the move. When DoH and plain DNS are both blocked, it is what
  finds the new address. It is recorded, not detected: an IP that changes outside the panel stays
  stale until someone updates it there.
- **Put `PersistentKeepalive = 25` in every config.** It is what lets the app spot a dead link at
  155 s instead of waiting the full 180 s window, and it keeps NAT mappings alive anyway.
- **When moving servers, keep the old address answering for a few minutes if possible.** Users
  then switch over during a check rather than after an outage.

## Diagnosing a report

Settings → Application log. Each lookup logs its winning source, for example
`Resolver: vpn.example.net → 5.9.44.99 via udp`. A detected move logs
`endpoint moved (network changed): 5.9.44.12 → 5.9.44.99`.
