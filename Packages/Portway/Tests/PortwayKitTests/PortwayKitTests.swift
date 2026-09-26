// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Import and bring-up rules: content decides, the stored hostname is never rewritten, and a full
// tunnel with no DNS gets one pinned only at bring-up.

import Foundation
import XCTest
@testable import PortwayKit
@testable import PortwayCore
import WireGuardKit

final class ImportTests: XCTestCase {
    func conf(dns: String? = "1.1.1.1", allowed: String = "0.0.0.0/0, ::/0", endpoint: String = "vpn.example.net:51820") -> String {
        """
        [Interface]
        PrivateKey = \(PrivateKey().base64Key)
        Address = 10.66.0.2/32
        \(dns.map { "DNS = \($0)" } ?? "")

        [Peer]
        PublicKey = \(PrivateKey().publicKey.base64Key)
        AllowedIPs = \(allowed)
        Endpoint = \(endpoint)
        PersistentKeepalive = 25
        """
    }

    func testTextFileWithAnyExtensionImports() throws {
        let result = ConfigImporter.candidates(fromFile: Data(conf().utf8), fileName: "My Office VPN.txt")
        let c = try XCTUnwrap(try? result.get().first)
        XCTAssert(c.suggestedName == "My Office VPN")
    }

    func testNotAConfigIsRejected() {
        guard case .failure(.notAConfig) = ConfigImporter.candidates(fromFile: Data("hello".utf8), fileName: "x.conf") else {
            return XCTAssert(false, "accepted junk")
        }
    }

    func testZipSkipsReadmeAndImportsEveryConfig() throws {
        let zip = Zip.write([
            Zip.Entry(name: "README.txt", data: Data("read me".utf8)),
            Zip.Entry(name: "fra.conf", data: Data(conf().utf8)),
            Zip.Entry(name: "dir/ams.conf", data: Data(conf().utf8)),
        ])
        let found = try ConfigImporter.candidates(fromFile: zip, fileName: "export.zip").get()
        XCTAssert(found.map(\.suggestedName) == ["fra", "ams"])
    }

    func testDeepLinkImport() throws {
        let b64 = Data(conf().utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let c = try ConfigImporter.candidate(fromLink: URL(string: "\(PortwayEnvironment.importScheme)://import?c=\(b64)&name=beta")!).get()
        XCTAssert(c.suggestedName == "beta")
    }

    func testSummary() throws {
        let s = try ConfigImporter.candidate(text: conf(allowed: "0.0.0.0/0"), name: "x").get().summary
        XCTAssert(s.endpointHost == "vpn.example.net" && s.endpointPort == 51820)
        XCTAssert(s.routesAll)
        XCTAssert(!s.routesEverything, "IPv4-only full tunnel must not count as routing everything")
        XCTAssert(s.address == "10.66.0.2/32")
        XCTAssert(s.publicKey.count == 44)
        let both = try ConfigImporter.candidate(text: conf(), name: "x").get().summary
        XCTAssert(both.routesEverything)
    }

    func testUniqueNames() {
        XCTAssert(ConfigImporter.uniqueName("work", existing: ["work", "work 2"]) == "work 3")
        XCTAssert(ConfigImporter.uniqueName("  ", existing: []) == "config")
        XCTAssert(ConfigImporter.uniqueName("فرانکفورت", existing: []) == "فرانکفورت")
    }
}

final class BringUpTests: XCTestCase {
    func config(_ text: String) throws -> TunnelConfiguration {
        try TunnelConfiguration(fromWgQuickConfig: text, called: "t")
    }

    /// The operator's hard constraint: resolution changes the bring-up copy, never the stored one.
    func testResolvedEndpointsLeaveTheStoredHostAlone() throws {
        let original = try config(ImportTests().conf())
        let bringUp = original.withResolvedEndpoints(["vpn.example.net": "5.9.44.12"])
        XCTAssert(bringUp.peers.first?.endpoint?.stringRepresentation == "5.9.44.12:51820")
        XCTAssert(original.peers.first?.endpoint?.stringRepresentation == "vpn.example.net:51820")
        XCTAssert(original.asWgQuickConfig().contains("vpn.example.net:51820"))
    }

    func testIPv6Resolution() throws {
        let bringUp = try config(ImportTests().conf()).withResolvedEndpoints(["vpn.example.net": "2001:db8::1"])
        XCTAssert(bringUp.peers.first?.endpoint?.stringRepresentation == "[2001:db8::1]:51820")
    }

    func testFallbackDNSOnlyForFullTunnelWithoutDNS() throws {
        let full = try config(ImportTests().conf(dns: nil)).withFallbackDNS("1.1.1.1")
        XCTAssert(full.interface.dns.map(\.stringRepresentation) == ["1.1.1.1"])
        let split = try config(ImportTests().conf(dns: nil, allowed: "10.0.0.0/8")).withFallbackDNS("1.1.1.1")
        XCTAssert(split.interface.dns.isEmpty, "a split tunnel keeps the network's resolver")
        let named = try config(ImportTests().conf(dns: "9.9.9.9")).withFallbackDNS("1.1.1.1")
        XCTAssert(named.interface.dns.map(\.stringRepresentation) == ["9.9.9.9"])
    }

    func testRoundTripThroughWgQuick() throws {
        let text = ImportTests().conf()
        let again = try config(try config(text).asWgQuickConfig())
        XCTAssert(again.peers.first?.endpoint?.stringRepresentation == "vpn.example.net:51820")
        XCTAssert(again.peers.first?.persistentKeepAlive == 25)
    }
}
