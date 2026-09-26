// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Parses wireguard-go's UAPI dump (WireGuardAdapter.getRuntimeConfiguration) into the three
// numbers everything else needs: newest handshake across peers, and total rx/tx.

import Foundation

public struct RuntimeStats: Equatable, Sendable {
    public var lastHandshake: Date?
    public var rxBytes: UInt64
    public var txBytes: UInt64

    public init(lastHandshake: Date? = nil, rxBytes: UInt64 = 0, txBytes: UInt64 = 0) {
        self.lastHandshake = lastHandshake
        self.rxBytes = rxBytes
        self.txBytes = txBytes
    }

    public init(uapi: String) {
        var newest: TimeInterval = 0
        var sec: TimeInterval = 0
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        for line in uapi.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq]
            let value = line[line.index(after: eq)...]
            switch key {
            case "public_key":
                sec = 0
            case "last_handshake_time_sec":
                sec = TimeInterval(value) ?? 0
            case "last_handshake_time_nsec":
                let t = sec + (TimeInterval(value) ?? 0) / 1e9
                newest = max(newest, t)
            case "rx_bytes":
                rx &+= UInt64(value) ?? 0
            case "tx_bytes":
                tx &+= UInt64(value) ?? 0
            default:
                break
            }
        }
        // 0 is WireGuard's "never".
        self.lastHandshake = newest > 0 ? Date(timeIntervalSince1970: newest) : nil
        self.rxBytes = rx
        self.txBytes = tx
    }
}
