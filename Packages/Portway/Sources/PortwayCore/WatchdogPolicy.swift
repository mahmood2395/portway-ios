// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// The watchdog's decisions, with no tunnel attached: given what one pass observed, what to do.
//
// Pulled out of the extension so the timing that users actually feel — "the server moved; how
// long until it works again?" — can be simulated pass by pass in a test instead of waited for on
// a phone.

import Foundation

public struct WatchdogPolicy: Sendable {
    public static let passInterval: TimeInterval = 10
    public static let initialGrace: TimeInterval = 25
    public static let restartGrace: TimeInterval = 30
    public static let wakeGrace: TimeInterval = 20
    public static let quickAttempts = 5
    public static let backoffBase: TimeInterval = 60
    public static let backoffCap: TimeInterval = 15 * 60
    /// With a keepalive configured, WireGuard starts a rekey 120s after the last handshake and
    /// retries every 5s. Still no handshake well past that, while we keep sending and nothing at
    /// all comes back, means the peer is not answering — no need to wait for the full 180s window.
    /// "Nothing comes back" matters: when the server initiated the last handshake the age can run
    /// past this legitimately, but then its traffic is still arriving.
    public static let failingRekeyAfter: TimeInterval = 155

    public enum Action: Equatable, Sendable {
        case none
        case restart(reason: String)
    }

    public private(set) var attempts = 0
    public private(set) var lastRestart: Date?
    /// Start of the current silence. Survives restarts: it is the same silence.
    public private(set) var silentSince: Date?
    private var graceUntil: Date
    private var lastTx: UInt64?
    private var lastRx: UInt64?
    /// No usable network: nothing to judge, and a restart could only fail.
    private var offline = false

    public init(connectedAt: Date) {
        graceUntil = connectedAt.addingTimeInterval(Self.initialGrace)
    }

    /// One pass. `keepalive`: the config sends persistent keepalives, so a healthy tunnel is
    /// guaranteed to rekey on schedule and an idle one does not look dead.
    public mutating func evaluate(now: Date, handshakeAge: TimeInterval?, txBytes: UInt64, rxBytes: UInt64,
                                  keepalive: Bool, autoReconnect: Bool) -> Action {
        defer { lastTx = txBytes; lastRx = rxBytes }
        guard now >= graceUntil, !offline else { return .none }

        let sending = lastTx.map { txBytes > $0 } ?? false
        // WireGuard only handshakes when there is something to send. Without a keepalive, an idle
        // tunnel's old (or absent) handshake says nothing about the peer — restarting it forever
        // would churn a healthy split tunnel and tell the panel it was dead.
        if !keepalive && !sending { return .none }
        let receiving = lastRx.map { rxBytes > $0 } ?? true
        let healthy: Bool
        if let age = handshakeAge {
            healthy = age < Handshake.limit && !(keepalive && sending && !receiving && age >= Self.failingRekeyAfter)
        } else {
            healthy = false
        }
        if healthy {
            attempts = 0
            silentSince = nil
            return .none
        }
        if silentSince == nil { silentSince = now }
        guard autoReconnect else { return .none }
        // Back off instead of giving up: a cap left a tunnel dead forever once spent — worst when
        // the server had moved and the new address was still propagating.
        if attempts >= Self.quickAttempts, let last = lastRestart {
            let exponent = min(attempts - Self.quickAttempts, 4)
            let backoff = min(Self.backoffBase * pow(2, Double(exponent)), Self.backoffCap)
            if now.timeIntervalSince(last) < backoff { return .none }
        }
        attempts += 1
        lastRestart = now
        let why = handshakeAge.map { "no handshake for \(Int($0))s" } ?? "never handshaked"
        return .restart(reason: "\(why) (attempt \(attempts))")
    }

    /// A restart's new configuration is live: judge it after a fresh grace.
    public mutating func restartApplied(at now: Date) {
        lastRestart = now
        graceUntil = now.addingTimeInterval(Self.restartGrace)
    }

    /// Woken from sleep: the last handshake is naturally old; let WireGuard rekey first.
    public mutating func woke(at now: Date) {
        graceUntil = max(graceUntil, now.addingTimeInterval(Self.wakeGrace))
    }

    /// The network changed: the backoff exists to stop hammering a broken endpoint, not to punish
    /// a tunnel for having been on a network that went away.
    public mutating func networkChanged() {
        attempts = 0
    }

    /// The network went away: stop judging (a restart could only fail, and would burn the budget).
    public mutating func wentOffline() {
        offline = true
    }

    /// Back online: WireGuardKit resumes the backend with fresh counters. Judge it after a grace,
    /// with the backoff forgiven.
    public mutating func cameOnline(at now: Date) {
        offline = false
        attempts = 0
        lastTx = nil
        lastRx = nil
        graceUntil = now.addingTimeInterval(Self.restartGrace)
    }

    /// Counters restart from zero when the peer is replaced; forget the old baseline.
    public mutating func countersReset() {
        lastTx = nil
        lastRx = nil
    }

    /// The endpoint's address changed and was applied without a failure: not an attempt, but the
    /// new address deserves the same grace a restart gets.
    public mutating func endpointMoved(at now: Date) {
        attempts = 0
        graceUntil = now.addingTimeInterval(Self.restartGrace)
    }
}
