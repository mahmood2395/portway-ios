// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// One config, one device at a time. See SESSION.md in the Android repo for the full story.
//
// A config is one private key, which is ONE peer on the router. Connect it on two devices and
// both claim the same interface address: the router answers whichever spoke last, both flap, and
// the operator gets a ticket that looks like a server fault. Each install carries a random device
// id and CLAIMS the session; the panel refuses only when a different device holds a session the
// router confirms is still handshaking. The panel owns that rule and its timings. Trust the 409.
//
// Operator decisions that shape everything below:
//  - FAIL-OPEN. No panel, a timeout, a 5xx, a 429: connect anyway. A panel outage must never
//    become a VPN outage.
//  - TAKEOVER, not a hard block. "Use here instead" re-claims with takeover=true; the other device
//    learns it was superseded on its next heartbeat.
//
// Where it runs on iOS: claims for on-screen connects happen in the app (it has to show the
// dialog); everything else — heartbeat, release, headless and on-demand claims — runs in the
// tunnel extension, which lives exactly as long as the VPN does. The app is suspended in the
// background, which is why Android's in-process heartbeat could not simply be ported.

import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

public enum ClaimResult: Sendable, Equatable {
    case granted
    /// Another device holds a live session.
    case conflict(otherDevice: String?)
    /// Fail-open: anything that is not a clear answer.
    case unavailable
}

public enum BeatResult: Sendable, Equatable {
    case active
    case superseded(by: String?)
    case unavailable
}

/// What a heartbeat reports about the link. Absent fields are omitted, never sent as 0 or null.
public struct HealthReport: Sendable {
    public var link: LinkState
    public var handshakeAge: Int?
    public var connectedFor: Int?
    public var silentFor: Int?
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public var restarts: Int
    public var transport: String?
    /// Connect On Demand is on. Sent only once the panel agrees the mapping (PANEL.md).
    public var onDemand: Bool?
    /// includeAllNetworks is on.
    public var includeAllNetworks: Bool?

    public init(link: LinkState, handshakeAge: Int?, connectedFor: Int?, silentFor: Int?,
                rxBytes: UInt64, txBytes: UInt64, restarts: Int, transport: String?,
                onDemand: Bool?, includeAllNetworks: Bool?) {
        self.link = link
        self.handshakeAge = handshakeAge
        self.connectedFor = connectedFor
        self.silentFor = silentFor
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.restarts = restarts
        self.transport = transport
        self.onDemand = onDemand
        self.includeAllNetworks = includeAllNetworks
    }
}

public enum SessionGuard {
    static let claimCeiling: TimeInterval = 3
    static let backgroundCeiling: TimeInterval = 8
    public static let heartbeatInterval: TimeInterval = 60

    /// Nothing is sent unless the protocol is switched on for this build, there is a panel, and the
    /// panel has POSITIVELY claimed the config — an account answer is cached for it. "Not known to be
    /// foreign" is not enough: once a disowning ages out, the first thing sent would be a claim
    /// carrying this device's id rather than the device-free /api/peer/info recheck.
    static func enabled(for identity: PeerIdentity) -> Bool {
        PortwayEnvironment.sessionProtocolEnabled
            && PortwaySettings.shared.panelURL != nil
            && !AccountStore.isForeign(identity.publicKey)
            && AccountStore.cached(identity.publicKey) != nil
    }

    // MARK: Endpoints

    public static func register(_ identity: PeerIdentity) async {
        guard enabled(for: identity) else { return }
        var body = await deviceFields()
        addLastDisconnect(identity, to: &body)
        let response = await post(identity, "/api/peer/device/register", body, ceiling: backgroundCeiling)
        disownIfUnknown(identity, response)
    }

    /// The 3s ceiling covers the whole claim, the permission read included — it sits between a tap
    /// and a connection.
    public static func claim(_ identity: PeerIdentity, takeover: Bool) async -> ClaimResult {
        guard enabled(for: identity) else { return .unavailable }
        return await withDeadline(claimCeiling) { await claimNow(identity, takeover: takeover) } ?? .unavailable
    }

    private static func claimNow(_ identity: PeerIdentity, takeover: Bool) async -> ClaimResult {
        var body = await deviceFields()
        body["takeover"] = takeover
        addLastDisconnect(identity, to: &body)
        guard let response = await post(identity, "/api/peer/session/claim", body, ceiling: claimCeiling) else {
            log("Session", "claim gave no answer; connecting anyway")
            return .unavailable
        }
        switch response.status {
        case 200:
            return response.json?.bool("granted") == false ? .unavailable : .granted
        case 409:
            return .conflict(otherDevice: response.json?.string("other_device_name"))
        case 404:
            AccountStore.markForeign(identity.publicKey)
            return .unavailable
        default:
            return .unavailable
        }
    }

    public static func heartbeat(_ identity: PeerIdentity, health: HealthReport) async -> BeatResult {
        guard enabled(for: identity), health.link != .down else { return .unavailable }
        var body: [String: Any] = [
            "device_name": DeviceInfo.name,
            "app_version": PortwayEnvironment.buildNumber,
            "platform": DeviceInfo.platform,
            "link_state": health.link.rawValue,
            "rx_bytes": health.rxBytes,
            "tx_bytes": health.txBytes,
            "restarts": health.restarts,
        ]
        body["notifications"] = await notificationsAllowed()
        if let v = health.handshakeAge { body["handshake_age"] = v }
        if let v = health.connectedFor { body["connected_for"] = v }
        // Only qualifies a state that is not healthy.
        if let v = health.silentFor, health.link != .handshaking { body["silent_for"] = v }
        if let v = health.transport { body["transport"] = v }
        if let v = health.onDemand { body["always_on"] = v }
        if let v = health.includeAllNetworks { body["lockdown"] = v }
        let response = await post(identity, "/api/peer/session/heartbeat", body, ceiling: backgroundCeiling)
        disownIfUnknown(identity, response)
        guard let response, response.status == 200, let json = response.json else { return .unavailable }
        if json.bool("active") == false {
            return .superseded(by: json.string("superseded_by_device_name"))
        }
        return .active
    }

    public static func release(_ identity: PeerIdentity, reason: DisconnectReason, restarts: Int) async {
        guard enabled(for: identity) else { return }
        let body: [String: Any] = ["reason": reason.rawValue, "restarts": restarts]
        disownIfUnknown(identity, await post(identity, "/api/peer/session/release", body, ceiling: 3))
    }

    /// A 404 from any session endpoint is the panel disowning the peer mid-session. From then on it
    /// hears nothing more about this config: no heartbeat carrying this device's id every minute.
    private static func disownIfUnknown(_ identity: PeerIdentity, _ response: PanelHTTP.Response?) {
        if response?.status == 404 { AccountStore.markForeign(identity.publicKey) }
    }

    // MARK: Plumbing

    private static func deviceFields() async -> [String: Any] {
        [
            "device_name": DeviceInfo.name,
            "app_version": PortwayEnvironment.buildNumber,
            "os_version": DeviceInfo.osVersion,
            "platform": DeviceInfo.platform,
            "notifications": await notificationsAllowed(),
        ]
    }

    /// `unknown` is sent as a value: a teardown the app could not attribute is information too.
    private static func addLastDisconnect(_ identity: PeerIdentity, to body: inout [String: Any]) {
        let (reason, at) = DisconnectLedger.last(identity.tunnelName)
        body["last_disconnect_reason"] = reason.rawValue
        if reason != .unknown, let at { body["last_disconnect_at"] = at }
    }

    private static func post(_ identity: PeerIdentity, _ path: String, _ extra: [String: Any], ceiling: TimeInterval) async -> PanelHTTP.Response? {
        guard let base = PortwaySettings.shared.panelURL, let url = URL(string: base + path) else { return nil }
        var body = extra
        body["pubkey"] = identity.publicKey
        if let address = identity.address { body["address"] = address }
        body["device_id"] = PortwaySettings.shared.deviceID
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        sign(&request)
        let response = await PanelHTTP.send(request, ceiling: ceiling)
        if let status = response?.status, status == 429 || status >= 500 {
            log("Session", "\(path) → \(status); treating as allow")
        }
        return response
    }

    /// The hook for proof of key possession (HMAC over X25519(peer_private, panel_public)); a
    /// no-op until the panel publishes a key. See SESSION.md "Security".
    private static func sign(_ request: inout URLRequest) {}

    /// Permitted RIGHT NOW, not ever granted: with notifications off the user never sees a
    /// takeover or superseded notice, and support needs to know that.
    static func notificationsAllowed() async -> Bool {
        #if canImport(UserNotifications)
        // UNUserNotificationCenter needs an app bundle; in a bare process (tests) it never answers.
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        #else
        return false
        #endif
    }
}

public enum DeviceInfo {
    public static let platform = "ios"

    /// "18.2 (22C152)": release (build) — the same shape as Android's "13 (33)".
    public static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var release = "\(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 { release += ".\(v.patchVersion)" }
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        guard size > 0 else { return release }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        return "\(release) (\(String(cString: buffer)))"
    }()

    /// "Apple iPhone 15 Pro". iOS no longer gives apps the user-chosen device name, and it would
    /// often be a person's name anyway; the model is what support needs.
    public static let name: String = "Apple " + (marketingNames[modelIdentifier] ?? modelIdentifier)

    public static let modelIdentifier: String = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()

    /// Models new enough to run this app. Anything newer falls back to its identifier
    /// ("Apple iPhone18,1"), which the panel can still read.
    private static let marketingNames: [String: String] = [
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,5": "iPhone 16e",
    ]
}
