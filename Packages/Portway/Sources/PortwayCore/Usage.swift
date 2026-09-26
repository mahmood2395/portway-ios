// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Thirty days of "how much moved through the tunnel", one bucket per LOCAL calendar date, per
// config.
//
// Keyed by the date as yyyyMMdd, not by the instant of local midnight: instants move when the
// timezone does, and after travelling no stored key matched any midnight of the new zone, so the
// whole history drew as empty. A date means the same day in every zone.
//
// Per config (by public key) rather than Android's single global series: the detail screen is
// about one config, and a user with two providers wants to see which one ate the month.

import Foundation

public enum UsageHistory {
    public static let days = 30
    public static let fortnight = 14

    /// pubkey → [yyyyMMdd: bytes], one key per config (SharedMap).
    private static let map = SharedMap<[String: Int64]>("usage")
    private static let lock = NSLock()

    public static func record(_ bytes: UInt64, for pubkey: String, at date: Date = Date(), calendar: Calendar = .current) {
        guard bytes > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        var buckets = map[pubkey] ?? [:]
        let today = dayKey(date, calendar: calendar)
        buckets[String(today)] = (buckets[String(today)] ?? 0) &+ Int64(clamping: bytes)
        let oldest = dayKey(calendar.date(byAdding: .day, value: -(days - 1), to: date) ?? date, calendar: calendar)
        buckets = buckets.filter { (Int($0.key) ?? 0) >= oldest }
        map[pubkey] = buckets
    }

    /// The last `count` days, oldest first. Idle days are zero, not absent — a missing bar and an
    /// idle day look identical to the eye, and only one of them is true.
    public static func series(for pubkey: String, count: Int = days, now: Date = Date(), calendar: Calendar = .current) -> [UInt64] {
        let buckets = map[pubkey] ?? [:]
        return (0..<count).reversed().map { back in
            let day = calendar.date(byAdding: .day, value: -back, to: now) ?? now
            return UInt64(max(0, buckets[String(dayKey(day, calendar: calendar))] ?? 0))
        }
    }

    public static func forget(_ pubkey: String) {
        lock.lock(); defer { lock.unlock() }
        map.remove(pubkey)
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }
}

/// Turns cumulative counters into deltas for `UsageHistory`.
///
/// WireGuard's counters restart from zero every time the device is created, so a cumulative value
/// would be counted again on every reconnect. The first sample of a session counts in full (the
/// counters started at zero), and a counter that went backwards means a reset: count it in full.
public struct UsageSampler: Sendable {
    private var lastRx: UInt64?
    private var lastTx: UInt64?

    public init() {}

    public mutating func delta(rx: UInt64, tx: UInt64) -> UInt64 {
        let dRx = lastRx.map { rx >= $0 ? rx - $0 : rx } ?? rx
        let dTx = lastTx.map { tx >= $0 ? tx - $0 : tx } ?? tx
        lastRx = rx
        lastTx = tx
        return dRx &+ dTx
    }
}

/// Live rates from cumulative counters: a one-pole EMA, reseeded instead of fed when the gap
/// between samples is implausible (the app coming back from the background).
public struct ThroughputMeter: Sendable {
    private var last: (at: Date, rx: UInt64, tx: UInt64)?
    public private(set) var rxRate: Double = 0
    public private(set) var txRate: Double = 0

    private static let alpha = 0.4
    private static let maxGap: TimeInterval = 10

    public init() {}

    public mutating func add(rx: UInt64, tx: UInt64, at now: Date = Date()) {
        defer { last = (now, rx, tx) }
        guard let last else { return }
        let dt = now.timeIntervalSince(last.at)
        guard dt > 0.2, dt < Self.maxGap, rx >= last.rx, tx >= last.tx else {
            if dt >= Self.maxGap || rx < last.rx || tx < last.tx { rxRate = 0; txRate = 0 }
            return
        }
        let r = Double(rx - last.rx) / dt
        let t = Double(tx - last.tx) / dt
        rxRate = rxRate == 0 ? r : rxRate + Self.alpha * (r - rxRate)
        txRate = txRate == 0 ? t : txRate + Self.alpha * (t - txRate)
    }

    public mutating func reset() { self = ThroughputMeter() }
}
