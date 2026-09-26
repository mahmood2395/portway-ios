// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// The panel contract, checked on the wire against tools/mock_panel.py: what is sent, what is
// left out, and what each answer does. These are the rules the Android app learned — absent is
// not zero, unknown is sent as a value, a 404 silences everything, fail-open on anything unclear.

import Foundation
import XCTest
@testable import PortwayCore

final class PanelContractTests: XCTestCase {
    static let port = 8700 + Int.random(in: 0..<200)
    static let log = FileManager.default.temporaryDirectory.appendingPathComponent("panel-\(port).jsonl")
    static var server: Process?

    static func startServer() {
        guard server == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "tools/mock_panel.py", "--port", "\(port)", "--log", log.path]
        p.standardOutput = FileHandle.nullDevice
        // Not our pipes: a server holding them open would keep a `| tail` waiting forever.
        p.standardError = FileHandle.nullDevice
        try? p.run()
        server = p
        Thread.sleep(forTimeInterval: 0.8)
        PortwaySettings.shared.panelURLOverride = "http://127.0.0.1:\(port)"
        PortwayEnvironment.sessionProtocolOverride = true
    }

    func requests(_ path: String) -> [[String: Any]] {
        guard let text = try? String(contentsOf: Self.log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.filter { $0["path"] as? String == path }
    }

    func identity(_ prefix: String) -> PeerIdentity {
        PeerIdentity(tunnelName: "t-\(prefix)-\(UUID().uuidString.prefix(6))",
                     publicKey: prefix + UUID().uuidString, address: "10.99.0.2/32", endpointHost: "vpn.example.net")
    }

    func testAccountInfoParsesAndLearnsHintAndPlace() {
        Self.startServer()
        let id = identity("OK")
        guard case .ok(let info) = wait({ await AccountStore.fetch(id) }) else { return XCTAssert(false, "no account") }
        XCTAssert(info.daysLeft == 23 && info.quotaBytes == 30_000_000_000 && info.totalBytes == 12_400_000_000)
        XCTAssert(AccountStore.endpointHint(for: "vpn.example.net")?.ip == "5.9.44.12")
        XCTAssert(AccountStore.panelPlace(for: "VPN.example.net")?.city == "Frankfurt")
        let sent = requests("/api/peer/info").last?["query"] as? [String: String]
        XCTAssert(sent?["pubkey"] == id.publicKey, "a base64 '+' must survive the query string")
        XCTAssert(sent?["address"] == "10.99.0.2/32")
    }

    func testClaimSendsDeviceFieldsAndUnknownReason() {
        Self.startServer()
        let id = identity("OK")
        _ = wait { await AccountStore.fetch(id) }   // the session guard needs a positive "ours"
        XCTAssert(wait { await SessionGuard.claim(id, takeover: false) } == .granted)
        let body = requests("/api/peer/session/claim").last?["body"] as? [String: Any] ?? [:]
        XCTAssert(body["platform"] as? String == "ios")
        XCTAssert(body["takeover"] as? Bool == false)
        XCTAssert(body["device_id"] as? String == PortwaySettings.shared.deviceID)
        XCTAssert(body["last_disconnect_reason"] as? String == "unknown", "unknown is sent as a value")
        XCTAssert(body["last_disconnect_at"] == nil, "no timestamp for unknown")
        XCTAssert(body["battery_unrestricted"] == nil, "no iOS equivalent: absent, never false")
        XCTAssert((body["os_version"] as? String)?.contains("(") == true)
    }

    func testConflictNamesTheOtherDeviceAndTakeoverIsGranted() {
        Self.startServer()
        let id = identity("CONFLICT")
        _ = wait { await AccountStore.fetch(id) }
        XCTAssert(wait { await SessionGuard.claim(id, takeover: false) } == .conflict(otherDevice: "Google Pixel 7"))
        XCTAssert(wait { await SessionGuard.claim(id, takeover: true) } == .granted)
    }

    func testHeartbeatOmitsWhatIsUnknown() {
        Self.startServer()
        let id = identity("OK")
        _ = wait { await AccountStore.fetch(id) }
        let healthy = HealthReport(link: .handshaking, handshakeAge: 12, connectedFor: 300, silentFor: 40,
                                   rxBytes: 10, txBytes: 20, restarts: 0, transport: "wifi", onDemand: nil, includeAllNetworks: nil)
        XCTAssert(wait { await SessionGuard.heartbeat(id, health: healthy) } == .active)
        var body = requests("/api/peer/session/heartbeat").last?["body"] as? [String: Any] ?? [:]
        XCTAssert(body["link_state"] as? String == "handshaking")
        XCTAssert(body["silent_for"] == nil, "silent_for only qualifies a state that is not healthy")
        XCTAssert(body["always_on"] == nil && body["lockdown"] == nil, "absent when not known")

        let never = HealthReport(link: .noHandshake, handshakeAge: nil, connectedFor: 20, silentFor: 190,
                                 rxBytes: 0, txBytes: 1628, restarts: 5, transport: "cellular", onDemand: true, includeAllNetworks: false)
        _ = wait { await SessionGuard.heartbeat(id, health: never) }
        body = requests("/api/peer/session/heartbeat").last?["body"] as? [String: Any] ?? [:]
        XCTAssert(body["link_state"] as? String == "no_handshake")
        XCTAssert(body["handshake_age"] == nil, "absent when there has never been one — not 0")
        XCTAssert(body["silent_for"] as? Int == 190)
        XCTAssert(body["always_on"] as? Bool == true && body["lockdown"] as? Bool == false)
    }

    func testSupersededHeartbeat() {
        Self.startServer()
        let id = identity("SUPERSEDE")
        _ = wait { await AccountStore.fetch(id) }
        let report = HealthReport(link: .handshaking, handshakeAge: 5, connectedFor: 60, silentFor: nil,
                                  rxBytes: 1, txBytes: 1, restarts: 0, transport: nil, onDemand: nil, includeAllNetworks: nil)
        XCTAssert(wait { await SessionGuard.heartbeat(id, health: report) } == .superseded(by: "Google Pixel 7"))
    }

    /// A disowned peer: the panel hears nothing more about it, and connecting is never blocked.
    func testDisownedPeerIsSilenced() {
        Self.startServer()
        let id = identity("GONE")
        guard case .unknown = wait({ await AccountStore.fetch(id) }) else { return XCTAssert(false, "404 not seen") }
        XCTAssert(AccountStore.isForeign(id.publicKey))
        let before = requests("/api/peer/session/claim").count
        XCTAssert(wait { await SessionGuard.claim(id, takeover: false) } == .unavailable, "fail-open")
        _ = wait { await SessionGuard.register(id) }
        XCTAssert(requests("/api/peer/session/claim").count == before, "nothing sent for a disowned peer")
        guard case .unknown = wait({ await AccountStore.fetch(id) }) else { return XCTAssert(false) }
        XCTAssert(requests("/api/peer/info").filter { ($0["query"] as? [String: String])?["pubkey"] == id.publicKey }.count == 1,
                  "the disowning is remembered; the panel is not asked again")
    }

    func testNoPanelMeansFailOpen() {
        Self.startServer()
        let id = identity("OK")
        _ = wait { await AccountStore.fetch(id) }
        PortwaySettings.shared.panelURLOverride = "http://127.0.0.1:9"   // nothing listens
        let start = Date()
        XCTAssert(wait { await SessionGuard.claim(id, takeover: false) } == .unavailable)
        XCTAssert(Date().timeIntervalSince(start) < 3.5, "the claim's ceiling is 3s")
        PortwaySettings.shared.panelURLOverride = "http://127.0.0.1:\(Self.port)"
    }

    func testIOSUpdateFeedOnlyBelievesIOS() {
        Self.startServer()
        let release = wait { await UpdateChecker.check(force: true) }
        XCTAssert(release?.version == "9.9.9" && release?.url.host == "apps.apple.com")
        XCTAssert(requests("/api/app/latest").last.flatMap { ($0["query"] as? [String: String])?["platform"] } == "ios")
    }
}

