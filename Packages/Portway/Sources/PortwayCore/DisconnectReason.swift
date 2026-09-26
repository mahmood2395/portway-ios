// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// How each config's last session ended, for register and claim, and the reason on release.
//
// Easier than on Android: NEProviderStopReason names most causes as they happen. Two still need
// help. When Portway itself ends a session (the panel said another device took over), it records
// the cause before cancelling, and that declaration wins over the generic stop reason. And a
// process the system kills writes nothing, so `killed` is inferred at the next start from a
// "running" marker that only a clean stop removes.

import Foundation

public enum DisconnectReason: String, Codable, Sendable {
    case user, replaced
    case handshakeTimeout = "handshake_timeout"
    case superseded, update, system, killed, unknown
}

public enum DisconnectLedger {
    // One key per tunnel: the app and the extension both write here.
    private static let lastMap = SharedMap<String>("disconnect_last")        // "reason:millis"
    private static let expected = SharedMap<String>("disconnect_expected")   // reason
    private static let running = SharedMap<Double>("disconnect_running")     // millis at start

    /// Declare the cause of a teardown Portway is about to perform.
    public static func expect(_ tunnel: String, _ reason: DisconnectReason) {
        expected[tunnel] = reason.rawValue
    }

    /// The session ended. `observed` is what the system said; a prior `expect` overrides it.
    @discardableResult
    public static func ended(_ tunnel: String, observed: DisconnectReason) -> DisconnectReason {
        let reason = expected[tunnel].flatMap(DisconnectReason.init(rawValue:)) ?? observed
        expected.remove(tunnel)
        record(tunnel, reason)
        running.remove(tunnel)
        return reason
    }

    /// A session is starting. If the previous one never reported its end, it was killed.
    public static func started(_ tunnel: String) {
        if running[tunnel] != nil { record(tunnel, .killed) }
        running[tunnel] = Date().timeIntervalSince1970 * 1000
    }

    /// A start that never came up (refused claim, backend failure): not a session, so nothing is
    /// recorded — only the running marker is withdrawn, or the next start would infer `killed`.
    public static func abandoned(_ tunnel: String) {
        running.remove(tunnel)
    }

    /// (reason, epoch millis). Millis, not seconds: seconds would land silently in 1970.
    public static func last(_ tunnel: String) -> (DisconnectReason, Int64?) {
        guard let entry = lastMap[tunnel], let colon = entry.lastIndex(of: ":"),
              let reason = DisconnectReason(rawValue: String(entry[..<colon])) else { return (.unknown, nil) }
        return (reason, Int64(entry[entry.index(after: colon)...]))
    }

    private static func record(_ tunnel: String, _ reason: DisconnectReason) {
        lastMap[tunnel] = "\(reason.rawValue):\(Int64(Date().timeIntervalSince1970 * 1000))"
    }

    /// A config was renamed or deleted.
    public static func forget(_ tunnel: String) {
        lastMap.remove(tunnel)
        expected.remove(tunnel)
        running.remove(tunnel)
    }
}
