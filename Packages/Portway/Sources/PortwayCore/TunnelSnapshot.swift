// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// The tunnel extension's view of itself, handed to the app and the widgets.
//
// The app asks for it with a provider message while a screen is visible (that is how it reads
// live handshake age and byte counters), and the extension also writes it to the app group on
// every watchdog pass, which is what widgets and the Live Activity read — they cannot message
// the extension.

import Foundation

public struct TunnelSnapshot: Codable, Sendable, Equatable {
    public var tunnelName: String
    /// When this session came up. Survives watchdog restarts, which do not tear the session down.
    public var connectedSince: Date?
    public var lastHandshake: Date?
    public var rxBytes: UInt64
    public var txBytes: UInt64
    /// Watchdog restarts in this session.
    public var restarts: Int
    /// Start of the current silence, if the watchdog has judged the link not handshaking.
    public var silentSince: Date?
    /// A watchdog restart is in flight; the hero reads "Reconnecting…".
    public var reconnecting: Bool
    /// The address the endpoint resolved to at the last (re)start.
    public var endpointAddress: String?
    public var transport: String?
    /// The panel said another device took over, and on-demand kept us up.
    public var superseded: Bool
    public var updatedAt: Date

    public init(tunnelName: String, connectedSince: Date? = nil, lastHandshake: Date? = nil,
                rxBytes: UInt64 = 0, txBytes: UInt64 = 0, restarts: Int = 0, silentSince: Date? = nil,
                reconnecting: Bool = false, endpointAddress: String? = nil, transport: String? = nil,
                superseded: Bool = false, updatedAt: Date = Date()) {
        self.tunnelName = tunnelName
        self.connectedSince = connectedSince
        self.lastHandshake = lastHandshake
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.restarts = restarts
        self.silentSince = silentSince
        self.reconnecting = reconnecting
        self.endpointAddress = endpointAddress
        self.transport = transport
        self.superseded = superseded
        self.updatedAt = updatedAt
    }

    public func handshakeAge(now: Date = Date()) -> TimeInterval? {
        lastHandshake.map { max(0, now.timeIntervalSince($0)) }
    }

    public func silentFor(now: Date = Date()) -> TimeInterval? {
        silentSince.map { max(0, now.timeIntervalSince($0)) }
    }

    public func upFor(now: Date = Date()) -> TimeInterval? {
        connectedSince.map { max(0, now.timeIntervalSince($0)) }
    }

    public func link(now: Date = Date()) -> LinkState {
        LinkState.judge(isUp: true, handshakeAge: handshakeAge(now: now), silentFor: silentFor(now: now), upFor: upFor(now: now))
    }

    // MARK: - App group copy, for widgets

    private static var url: URL { PortwayEnvironment.containerURL.appendingPathComponent("snapshot.json") }

    public func persist() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }

    public static func loadPersisted() -> TunnelSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TunnelSnapshot.self, from: data)
    }

    public static func clearPersisted() { try? FileManager.default.removeItem(at: url) }
}

/// Messages the app sends to the running extension.
public enum ProviderRequest: String, Codable, Sendable {
    /// Reply with a `TunnelSnapshot`.
    case snapshot
    /// Re-resolve the endpoint and re-apply the configuration now.
    case restart
}

/// Keys in `startVPNTunnel(options:)`.
public enum StartOption {
    public static let gate = "portway.gate"
}

/// Who asked for a connection, which decides what a session conflict does.
public enum SessionGate: String, Sendable {
    /// The app's own UI has already claimed (and shown the conflict dialog if there was one).
    case claimed
    /// A headless user action — Shortcut, widget, Control Center. The extension claims; a
    /// conflict refuses the connection and posts a notification offering "Use here instead".
    case headless
    /// Connect On Demand, or the "Use here instead" notification action. Claims with the given
    /// takeover flag and never refuses: blocking always-on is worse than a conflict.
    case advisory
    case takeover
}
