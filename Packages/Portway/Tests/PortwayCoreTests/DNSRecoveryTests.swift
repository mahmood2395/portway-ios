// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// "The server's IP changed and only restarting the phone helped." These tests pin down every
// part of the fix: sources that skip the caches, the order stale answers lose in, the preference
// for anything but the address that just failed, round-robin names, and — simulated pass by pass —
// how long a user actually waits after the server moves.

import Foundation
import XCTest
@testable import PortwayCore

final class PlainDNSTests: XCTestCase {
    /// A response with a CNAME, a compression pointer and two A records, as 8.8.8.8 sends them.
    func testParsesCNAMEChainAndEveryARecord() {
        let id: UInt16 = 0xBEEF
        let query = PlainDNS.buildQuery("vpn.example.net", id: id)!
        var r = query
        r[2] = 0x81; r[3] = 0x80            // response, recursion available, NOERROR
        r[7] = 3                            // three answers
        // CNAME vpn.example.net -> edge.example.net (name via pointer to offset 12)
        r += [0xC0, 0x0C, 0, 5, 0, 1, 0, 0, 0, 60, 0, 7, 4] + Array("edge".utf8) + [0xC0, 0x10]
        // A records for the CNAME target
        r += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 5, 9, 44, 12]
        r += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 5, 9, 44, 13]
        XCTAssert(PlainDNS.parseA(r, id: id) == ["5.9.44.12", "5.9.44.13"])
        XCTAssert(PlainDNS.parseA(r, id: id &+ 1).isEmpty, "a reply to another query is ignored")
        var nx = r; nx[3] = 0x83
        XCTAssert(PlainDNS.parseA(nx, id: id).isEmpty, "NXDOMAIN yields nothing")
        XCTAssert(PlainDNS.parseA(Array(r.prefix(20)), id: id).isEmpty, "a truncated packet cannot crash")
    }

    func testRejectsBadNames() {
        XCTAssert(PlainDNS.buildQuery("a..b", id: 1) == nil)
        XCTAssert(PlainDNS.buildQuery(String(repeating: "x", count: 64) + ".com", id: 1) == nil)
    }

    /// Real network: one.one.one.one resolves to 1.1.1.1 / 1.0.0.1 through port 53 directly.
    func testLiveQueryBypassesTheSystemResolver() {
        let found = wait { await PlainDNS.resolveAll("one.one.one.one", timeout: 3) }
        XCTAssert(found.contains("1.1.1.1") || found.contains("1.0.0.1"), "got \(found)")
    }
}

final class ResolverOrderTests: XCTestCase {
    enum Mode { case answer([String]), empty, hang }

    func source(_ mode: Mode, after delay: TimeInterval = 0.05) -> @Sendable (String) async -> [String] {
        { _ in
            switch mode {
            case .answer(let a): try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)); return a
            case .empty: try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)); return []
            case .hang: try? await Task.sleep(nanoseconds: 30_000_000_000); return []
            }
        }
    }

    func resolver(doh: Mode, udp: Mode, system: Mode, hint: (String, TimeInterval)? = nil) -> EndpointResolver {
        let h: (ip: String, at: Date)? = hint.map { ($0.0, Date().addingTimeInterval(-$0.1)) }
        return EndpointResolver(sources: .init(doh: source(doh), udp: source(udp), system: source(system), hint: { _ in h }))
    }

    let old = "5.9.44.12", new = "5.9.44.99"

    func testDoHWins() {
        let r = resolver(doh: .answer([new]), udp: .answer([old]), system: .answer([old]))
        XCTAssert(wait { await r.resolve("vpn.example.net") }?.source == .doh)
    }

    /// Iran: DoH blocked, the carrier's cache stale. Plain DNS to a public resolver has the truth.
    func testDoHBlockedPlainDNSBeatsStaleSystem() {
        // (no panel hint here)
        let r = resolver(doh: .hang, udp: .answer([new]), system: .answer([old]))
        let a = wait { await r.resolve("vpn.example.net") }
        XCTAssert(a?.address == new && a?.source == .udp, "\(String(describing: a))")
    }

    func testFreshPanelHintBeatsSystem() {
        let r = resolver(doh: .empty, udp: .empty, system: .answer([old]), hint: (new, 60))
        XCTAssert(wait { await r.resolve("vpn.example.net") }?.source == .panel)
    }

    /// The panel's endpoint_ip is the operator's recorded address, not a detected one (confirmed by
    /// the panel team): the hostname's own DNS outranks it, and it answers when DNS is blocked.
    func testPlainDNSBeatsPanelRecord() {
        let r = resolver(doh: .empty, udp: .answer([new]), system: .empty, hint: (old, 60))
        XCTAssert(wait { await r.resolve("vpn.example.net") }?.address == new)
    }

    func testPanelRecordAnswersWhenBothDNSPathsAreBlocked() {
        let r = resolver(doh: .hang, udp: .hang, system: .answer([old]), hint: (new, 60))
        XCTAssert(wait { await r.resolve("vpn.example.net") }?.source == .panel)
    }

    func testInjectedPrivateAnswerIsDiscarded() {
        let r = resolver(doh: .empty, udp: .answer(["10.10.34.35"]), system: .answer([new]))
        let a = wait { await r.resolve("vpn.example.net") }
        XCTAssert(a?.address == new && a?.source == .system, "\(String(describing: a))")
        XCTAssert(EndpointResolver.isReserved("100.64.1.1") && EndpointResolver.isReserved("172.20.0.1"))
        XCTAssert(!EndpointResolver.isReserved("5.9.44.12") && !EndpointResolver.isReserved("172.32.0.1"))
    }

    func testOldPanelHintLosesToSystem() {
        let r = resolver(doh: .empty, udp: .empty, system: .answer([new]), hint: (old, 3 * 86_400))
        let a = wait { await r.resolve("vpn.example.net") }
        XCTAssert(a?.address == new && a?.source == .system)
    }

    /// After a failure, another address from the SAME source (round robin) is preferred…
    func testAvoidingPicksAnotherAddressFromTheSameSource() {
        let r = resolver(doh: .answer([old, new]), udp: .empty, system: .empty)
        XCTAssert(wait { await r.resolve("vpn.example.net", avoiding: self.old) }?.address == new)
    }

    /// …but a lesser source never overrides a better one: a short outage at the right address
    /// must not send the tunnel to a stale one the carrier's cache still holds.
    func testOutageAtTheRightAddressDoesNotFollowAStaleCache() {
        let r = resolver(doh: .empty, udp: .answer([old]), system: .answer(["198.51.100.7"]))
        XCTAssert(wait { await r.resolve("vpn.example.net", avoiding: self.old) }?.address == old)
    }

    /// No network at all is not "DoH is blocked": once back online, DoH is still waited on.
    func testOfflineDoesNotDemoteDoH() {
        final class Net: @unchecked Sendable { var online = false }
        let net = Net()
        let new = self.new, old = self.old
        let r = EndpointResolver(sources: .init(
            doh: { _ in try? await Task.sleep(nanoseconds: 300_000_000); return net.online ? [new] : [] },
            udp: { _ in net.online ? [old] : [] },
            system: { _ in [] },
            hint: { _ in nil }))
        for _ in 0..<3 { XCTAssert(wait { await r.resolve("vpn.example.net") } == nil) }
        net.online = true
        XCTAssert(wait { await r.resolve("vpn.example.net") }?.source == .doh, "DoH was demoted by an outage")
    }

    func testEverySourceAgreesSoTheOldAddressStands() {
        let r = resolver(doh: .answer([old]), udp: .answer([old]), system: .answer([old]))
        XCTAssert(wait { await r.resolve("vpn.example.net", avoiding: self.old) }?.address == old)
    }

    /// Round robin: every address is reported, so "still among them" can be checked.
    func testRoundRobinReportsEveryAddress() {
        let r = resolver(doh: .answer([new, old]), udp: .empty, system: .empty)
        let a = wait { await r.resolve("vpn.example.net") }
        XCTAssert(a?.all.contains(old) == true, "the current address is still valid: not a move")
    }

    func testEverythingHangsStaysInsideTheBudget() {
        let r = resolver(doh: .hang, udp: .hang, system: .hang)
        let start = Date()
        XCTAssert(wait { await r.resolve("vpn.example.net") } == nil)
        XCTAssert(Date().timeIntervalSince(start) < 3.8, "took \(Date().timeIntervalSince(start))s")
    }

    /// Where DoH is blocked it stops costing time after two failures.
    func testBlockedDoHStopsBeingWaitedOn() {
        let r = resolver(doh: .hang, udp: .answer([new]), system: .empty)
        for _ in 0..<2 { _ = wait { await r.resolve("vpn.example.net") } }
        let start = Date()
        XCTAssert(wait { await r.resolve("vpn.example.net") }?.source == .udp)
        XCTAssert(Date().timeIntervalSince(start) < 0.5, "still waiting on DoH: \(Date().timeIntervalSince(start))s")
    }

    func testLiteralNeedsNoLookup() {
        let r = resolver(doh: .hang, udp: .hang, system: .hang)
        XCTAssert(wait { await r.resolve("203.0.113.9") }?.source == .literal)
    }
}

/// The whole recovery loop, simulated in 10s passes: the watchdog, the 3-minute endpoint check,
/// what DNS answers over time, and which address the server actually listens on.
final class WatchdogSimulationTests: XCTestCase {
    struct Sim {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date
        var policy: WatchdogPolicy
        var lastHandshake: Date?
        var tx: UInt64 = 0, rx: UInt64 = 0
        var restarts: [TimeInterval] = []
        var moves: [TimeInterval] = []
        /// When the link came back after being down; nil while it is still down.
        var outages: [(from: TimeInterval, to: TimeInterval?)] = []

        /// The address this tunnel is using.
        var applied = "old"
        /// What DNS answers at t.
        var dns: (TimeInterval) -> String = { _ in "old" }
        /// The address the server answers on at t (nil: the server is down).
        var server: (TimeInterval) -> String? = { _ in "old" }
        var keepalive = true
        /// The user is browsing: packets go out every pass even without a keepalive.
        var userTraffic = false
        var autoReconnect = true
        static let checkEvery: TimeInterval = 180

        init() {
            now = start
            policy = WatchdogPolicy(connectedAt: start)
            lastHandshake = start
        }

        mutating func run(until end: TimeInterval) {
            var nextCheck = Self.checkEvery
            var wasUp = true
            while now.timeIntervalSince(start) < end {
                now = now.addingTimeInterval(WatchdogPolicy.passInterval)
                let t = now.timeIntervalSince(start)
                let up = server(t) == applied
                if up != wasUp {
                    if up { outages[outages.count - 1].to = t } else { outages.append((t, nil)) }
                    wasUp = up
                }
                if keepalive || userTraffic { tx += 148 }
                if up {
                    rx += 92
                    if let last = lastHandshake, now.timeIntervalSince(last) >= 120 { lastHandshake = now }
                }
                let action = policy.evaluate(now: now, handshakeAge: lastHandshake.map { now.timeIntervalSince($0) },
                                             txBytes: tx, rxBytes: rx, keepalive: keepalive, autoReconnect: autoReconnect)
                if case .restart = action {
                    restarts.append(t)
                    applied = dns(t)   // a restart re-resolves
                    policy.countersReset()
                    policy.restartApplied(at: now)
                    if server(t) == applied { lastHandshake = now }
                }
                if t >= nextCheck {   // the periodic endpoint check
                    nextCheck += Self.checkEvery
                    if dns(t) != applied {
                        moves.append(t)
                        applied = dns(t)
                        policy.endpointMoved(at: now)
                        policy.countersReset()
                        if server(t) == applied { lastHandshake = now }
                    }
                }
            }
        }

        var longestOutage: TimeInterval {
            outages.map { ($0.to ?? now.timeIntervalSince(start)) - $0.from }.max() ?? 0
        }
    }

    /// The headline case: the operator moves the server and updates DNS at t=300. Before the fix
    /// the tunnel kept the old address until the phone happened to be rebooted.
    func testServerMovesAndDNSIsUpdated() {
        var sim = Sim()
        sim.dns = { t in t < 300 ? "old" : "new" }
        sim.server = { t in t < 300 ? "old" : "new" }
        sim.run(until: 1800)
        print("  server moved at 300s → offline for \(Int(sim.longestOutage))s (restarts \(sim.restarts.map { Int($0) }), moves \(sim.moves.map { Int($0) }))")
        XCTAssert(sim.outages.allSatisfy { $0.to != nil }, "never recovered")
        XCTAssert(sim.longestOutage <= Sim.checkEvery + 10, "offline \(sim.longestOutage)s")
    }

    /// DNS lags the move by ten minutes. Recovery follows DNS within one check, however far the
    /// watchdog's backoff has got.
    func testDNSPropagatesLate() {
        var sim = Sim()
        sim.dns = { t in t < 900 ? "old" : "new" }
        sim.server = { t in t < 300 ? "old" : "new" }
        sim.run(until: 3600)
        let recovered = sim.outages.first?.to
        print("  server moved at 300s, DNS at 900s → back at \(recovered.map { Int($0) } ?? -1)s; restarts \(sim.restarts.map { Int($0) })")
        XCTAssert(recovered != nil && recovered! <= 900 + Sim.checkEvery + 10, "back at \(String(describing: recovered))")
    }

    /// The server comes back on the SAME address after an outage (a reboot): the watchdog keeps
    /// trying with backoff and reconnects without any user action.
    func testServerRebootsOnTheSameAddress() {
        var sim = Sim()
        sim.server = { t in (300..<1500).contains(t) ? nil : "old" }
        sim.run(until: 3600)
        let back = sim.outages.first?.to
        let gaps = zip(sim.restarts.dropFirst(), sim.restarts).map { Int($0 - $1) }
        print("  server down 300–1500s → back at \(back.map { Int($0) } ?? -1)s; restart gaps \(gaps)")
        XCTAssert(back != nil)
        XCTAssert(gaps.allSatisfy { $0 <= Int(WatchdogPolicy.backoffCap) + 10 })
    }

    /// Healthy tunnel whose server initiated the last handshake: old handshake, traffic still
    /// arriving. Must not be restarted early.
    func testHealthyTunnelIsLeftAlone() {
        var sim = Sim()
        sim.run(until: 170)
        sim.lastHandshake = sim.now.addingTimeInterval(-165)
        sim.run(until: 180)
        XCTAssert(sim.restarts.isEmpty, "restarted a healthy tunnel at \(sim.restarts)")
    }

    /// Without a keepalive but with the user sending, nothing proves the peer silent early: wait
    /// the full 180s window from the last handshake.
    func testNoKeepaliveWaitsForTheFullWindow() {
        var sim = Sim()
        sim.keepalive = false
        sim.userTraffic = true
        sim.server = { t in t < 100 ? "old" : nil }
        sim.run(until: 600)
        XCTAssert(sim.restarts.first.map { $0 >= Handshake.limit } ?? false, "\(sim.restarts)")
    }

    /// Review M2: an idle split tunnel with no keepalive has an old handshake and is fine.
    func testIdleTunnelWithoutKeepaliveIsNotRestarted() {
        var sim = Sim()
        sim.keepalive = false
        sim.run(until: 3600)   // server fine, nobody sending anything
        XCTAssert(sim.restarts.isEmpty, "\(sim.restarts)")
    }

    /// Review M7: offline, nothing is judged; back online, a grace, then normal judging.
    func testOfflineIsNotJudged() {
        var p = WatchdogPolicy(connectedAt: Date(timeIntervalSince1970: 0))
        p.wentOffline()
        for t in stride(from: 30.0, through: 1200, by: 10) {
            XCTAssert(p.evaluate(now: Date(timeIntervalSince1970: t), handshakeAge: t, txBytes: UInt64(t), rxBytes: 0,
                                 keepalive: true, autoReconnect: true) == .none)
        }
        p.cameOnline(at: Date(timeIntervalSince1970: 1200))
        XCTAssert(p.evaluate(now: Date(timeIntervalSince1970: 1210), handshakeAge: 1210, txBytes: 9, rxBytes: 0,
                             keepalive: true, autoReconnect: true) == .none, "no grace after coming back")
    }

    /// Auto-reconnect off: still judged (the silence clock runs), never restarted.
    func testJudgingContinuesWithAutoReconnectOff() {
        var sim = Sim()
        sim.autoReconnect = false
        sim.server = { t in t < 60 ? "old" : nil }
        sim.run(until: 600)
        XCTAssert(sim.restarts.isEmpty)
        XCTAssert(sim.policy.silentSince != nil)
    }

    func testNetworkChangeForgivesTheBackoff() {
        var sim = Sim()
        sim.server = { _ in nil }
        sim.run(until: 1200)
        XCTAssert(sim.policy.attempts > WatchdogPolicy.quickAttempts)
        sim.policy.networkChanged()
        XCTAssert(sim.policy.attempts == 0)
    }
}

// MARK: - Helpers

extension XCTestCase {
    func wait<T>(_ work: @escaping () async -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        var result: T?
        Task { result = await work(); done.signal() }
        done.wait()
        return result!
    }
}
