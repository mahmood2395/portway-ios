// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// What "connected" actually means, in one place.
//
// A tunnel is UP the moment the interface exists. That is the app asking for a connection, not
// the server answering one. Every judgement below — the decay bar, the hero kicker, the Configs
// row, the watchdog and the heartbeat's link_state — is made from the same three numbers against
// the same WireGuard constants, so the screen, the restarts and the report cannot disagree.
//
// The trap this file exists to avoid: judging on uptime. Against a dead server the watchdog
// restarts the tunnel every ~30s, so uptime never grows and every uptime rule reads "connecting"
// forever. The silence clock (`silentFor`) starts at the watchdog's first "not handshaking"
// verdict and survives restarts; it is what says how long something has been broken.

import Foundation

public enum Handshake {
    /// WireGuard's cutoff: the peer counts as gone. The full width of the decay bar.
    public static let limit: TimeInterval = 180
    /// The nominal rekey. The hairline on the bar.
    public static let rekeyDue: TimeInterval = 118
    /// Past this a connected tunnel's bar turns amber.
    public static let lateAfter: TimeInterval = 150
    public static var rekeyFraction: Double { rekeyDue / limit }
}

/// The vocabulary the panel sees. Only `handshaking` means traffic is passing.
public enum LinkState: String, Codable, Sendable {
    case connecting
    case handshaking
    case stale
    case noHandshake = "no_handshake"
    /// Never sent. A tunnel found down between the check and the send is skipped.
    case down

    /// - Parameters:
    ///   - handshakeAge: nil when there has never been a handshake — which is what separates
    ///     `noHandshake` from `stale`.
    ///   - silentFor: the silence clock; nil while healthy or unjudged.
    ///   - upFor: seconds since the tunnel came up; nil when unknown (adopted at launch).
    public static func judge(isUp: Bool, handshakeAge: TimeInterval?, silentFor: TimeInterval?, upFor: TimeInterval?) -> LinkState {
        guard isUp else { return .down }
        if let age = handshakeAge {
            return age < Handshake.limit ? .handshaking : .stale
        }
        if let silentFor, silentFor >= Handshake.limit { return .noHandshake }
        // An unknown up-time is judged as the older, louder state: guessing "connecting" there
        // would hide a dead tunnel for as long as the screen stayed open.
        guard let upFor, upFor < Handshake.limit else { return .noHandshake }
        return .connecting
    }

    /// Up, but the server is not answering. Drives "Not reaching the server".
    public var isSilent: Bool { self == .stale || self == .noHandshake }
}

/// The four states the handshake decay bar draws.
public enum DecayState: Sendable, Equatable {
    /// Connected, handshake inside the last 150s.
    case fresh
    /// Connected, rekey overdue but inside the 180s window.
    case late
    /// Up for less than the window, no handshake yet. Without this every connect flashed red.
    case waiting
    /// Down, or past the window with nothing from the peer.
    case silent

    public static func of(isUp: Bool, handshakeAge: TimeInterval?, silentFor: TimeInterval?, upFor: TimeInterval?) -> DecayState {
        guard isUp else { return .silent }
        if let age = handshakeAge {
            if age >= Handshake.limit { return .silent }
            return age > Handshake.lateAfter ? .late : .fresh
        }
        if let silentFor, silentFor >= Handshake.limit { return .silent }
        if let upFor, upFor < Handshake.limit { return .waiting }
        return .silent
    }

    /// 0…1 of the track the fill covers.
    public static func fill(handshakeAge: TimeInterval?, state: DecayState) -> Double {
        switch state {
        case .silent: return 1
        case .waiting: return 0
        case .fresh, .late: return min(1, max(0, (handshakeAge ?? 0) / Handshake.limit))
        }
    }
}
