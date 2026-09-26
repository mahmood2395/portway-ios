// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// The rules the Android app learned the hard way, pinned down so the port cannot quietly lose them.

import Foundation
import XCTest
@testable import PortwayCore

final class HealthTests: XCTestCase {
    func testUpIsNotConnected() {
        // Up for 20s with no handshake yet: too early to judge.
        XCTAssert(LinkState.judge(isUp: true, handshakeAge: nil, silentFor: nil, upFor: 20) == .connecting)
        // Past the window, never handshaked: it never reached the server.
        XCTAssert(LinkState.judge(isUp: true, handshakeAge: nil, silentFor: nil, upFor: 200) == .noHandshake)
        XCTAssert(LinkState.judge(isUp: true, handshakeAge: 30, silentFor: nil, upFor: 200) == .handshaking)
        XCTAssert(LinkState.judge(isUp: true, handshakeAge: 181, silentFor: 10, upFor: 400) == .stale)
        XCTAssert(LinkState.judge(isUp: false, handshakeAge: 1, silentFor: nil, upFor: 1) == .down)
    }

    /// The bug Android shipped: watchdog restarts reset the uptime every ~30s, so a dead tunnel
    /// read "connecting" forever. The silence clock survives restarts and must win.
    func testSilenceClockBeatsResetUptime() {
        XCTAssert(LinkState.judge(isUp: true, handshakeAge: nil, silentFor: 190, upFor: 12) == .noHandshake)
        XCTAssert(DecayState.of(isUp: true, handshakeAge: nil, silentFor: 190, upFor: 12) == .silent)
    }

    func testUnknownUptimeIsTheLouderState() {
        XCTAssert(LinkState.judge(isUp: true, handshakeAge: nil, silentFor: nil, upFor: nil) == .noHandshake)
    }

    func testDecayStates() {
        XCTAssert(DecayState.of(isUp: true, handshakeAge: 10, silentFor: nil, upFor: 100) == .fresh)
        XCTAssert(DecayState.of(isUp: true, handshakeAge: 160, silentFor: nil, upFor: 300) == .late)
        XCTAssert(DecayState.of(isUp: true, handshakeAge: nil, silentFor: nil, upFor: 5) == .waiting)
        XCTAssert(DecayState.of(isUp: false, handshakeAge: 5, silentFor: nil, upFor: 5) == .silent)
        XCTAssert(abs(Handshake.rekeyFraction - 0.6556) < 0.001)
        XCTAssert(DecayState.fill(handshakeAge: 90, state: .fresh) == 0.5)
    }
}

final class DeepLinkTests: XCTestCase {
    let conf = "[Interface]\nPrivateKey = x\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = y\nAllowedIPs = 0.0.0.0/0\n"

    func link(_ payload: String, name: String? = nil) -> URL {
        var s = "portway://import?c=\(payload)"
        if let name { s += "&name=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
        return URL(string: s)!
    }

    func testBase64urlUnpadded() throws {
        let b64url = Data(conf.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let payload = try DeepLink.parse(link(b64url, name: " beta frankfurt "), scheme: "portway").get()
        XCTAssert(payload.configText == conf)
        XCTAssert(payload.suggestedName == "beta frankfurt")
    }

    func testStandardBase64PercentEncoded() throws {
        let std = Data(conf.utf8).base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssert(try DeepLink.parse(link(std), scheme: "portway").get().configText == conf)
    }

    func testRejections() {
        XCTAssert(DeepLink.parse(URL(string: "portway://other?c=abc")!, scheme: "portway") == .failure(.notAnImportLink))
        XCTAssert(DeepLink.parse(URL(string: "portway://import")!, scheme: "portway") == .failure(.missingPayload))
        XCTAssert(DeepLink.parse(link(Data("hello".utf8).base64EncodedString()), scheme: "portway") == .failure(.notAConfig))
        XCTAssert(DeepLink.parse(link(Data([0xFF, 0xFE, 0x00]).base64EncodedString()), scheme: "portway") == .failure(.notUTF8))
        XCTAssert(DeepLink.parse(link("!!!!"), scheme: "portway") == .failure(.malformedBase64))
    }
}

final class ZipTests: XCTestCase {
    func testRoundTrip() throws {
        let entries = [Zip.Entry(name: "a.conf", data: Data("[Interface]\nA".utf8)),
                       Zip.Entry(name: "فارسی.conf", data: Data("[Interface]\nB".utf8))]
        let data = Zip.write(entries)
        XCTAssert(Zip.looksLikeZip(data))
        let read = try XCTUnwrap(Zip.read(data))
        XCTAssert(read.map(\.name) == entries.map(\.name))
        XCTAssert(read.map(\.data) == entries.map(\.data))
    }

    func testCrc() {
        XCTAssert(Zip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    /// A deflated archive written by the system zip tool.
    func testReadsDeflate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = String(repeating: "[Interface]\nPrivateKey = abc\n", count: 50)
        try text.write(to: dir.appendingPathComponent("x.conf"), atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-q", "out.zip", "x.conf"]
        try p.run(); p.waitUntilExit()
        let entries = try XCTUnwrap(Zip.read(Data(contentsOf: dir.appendingPathComponent("out.zip"))))
        XCTAssert(entries.first.map { String(decoding: $0.data, as: UTF8.self) } == text)
    }
}

final class CountersTests: XCTestCase {
    func testUapi() {
        let dump = """
        private_key=aa
        public_key=bb
        last_handshake_time_sec=1700000000
        last_handshake_time_nsec=500000000
        rx_bytes=100
        tx_bytes=50
        public_key=cc
        last_handshake_time_sec=0
        last_handshake_time_nsec=0
        rx_bytes=1
        tx_bytes=2
        """
        let s = RuntimeStats(uapi: dump)
        XCTAssert(s.rxBytes == 101 && s.txBytes == 52)
        XCTAssert(s.lastHandshake == Date(timeIntervalSince1970: 1_700_000_000.5))
        XCTAssert(RuntimeStats(uapi: "public_key=x\nlast_handshake_time_sec=0\nlast_handshake_time_nsec=0\n").lastHandshake == nil)
    }

    /// First sample counts in full; a counter reset (peer replaced on restart) counts in full.
    func testUsageDeltas() {
        var s = UsageSampler()
        XCTAssert(s.delta(rx: 100, tx: 10) == 110)
        XCTAssert(s.delta(rx: 150, tx: 10) == 50)
        XCTAssert(s.delta(rx: 20, tx: 5) == 25)
    }

    func testDayKeyIsACalendarDate() {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 15; c.hour = 23
        let date = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssert(UsageHistory.dayKey(date, calendar: Calendar(identifier: .gregorian)) == 20260915)
    }

    func testThroughputDiscardsImplausibleGaps() {
        var m = ThroughputMeter()
        let t0 = Date()
        m.add(rx: 0, tx: 0, at: t0)
        m.add(rx: 1000, tx: 500, at: t0.addingTimeInterval(1))
        XCTAssert(m.rxRate == 1000 && m.txRate == 500)
        m.add(rx: 999_999, tx: 0, at: t0.addingTimeInterval(60))   // back from the background
        XCTAssert(m.rxRate == 0)
    }
}

final class MiscTests: XCTestCase {
    func testIpLiterals() {
        XCTAssert(EndpointResolver.isIPLiteral("1.2.3.4"))
        XCTAssert(EndpointResolver.isIPLiteral("[2001:db8::1]"))
        XCTAssert(!EndpointResolver.isIPLiteral("vpn.example.com"))
    }

    func testIcmpChecksum() {
        // Echo request id 0x1234 seq 1, zero payload.
        let packet: [UInt8] = [8, 0, 0, 0, 0x12, 0x34, 0, 1]
        XCTAssert(Pinger.checksum(packet) == 0xE5CA)
    }

    func testDisconnectLedgerInfersKilled() {
        let name = "test-\(UUID().uuidString)"
        DisconnectLedger.started(name)
        DisconnectLedger.started(name)   // the previous session never reported its end
        XCTAssert(DisconnectLedger.last(name).0 == .killed)
        DisconnectLedger.expect(name, .superseded)
        XCTAssert(DisconnectLedger.ended(name, observed: .user) == .superseded)
        DisconnectLedger.forget(name)
        XCTAssert(DisconnectLedger.last(name).0 == .unknown)
    }
}

final class DeadlineTests: XCTestCase {
    /// The review's H1: a "timeout" built on a task group waited for the slow side to finish. A
    /// blocking call must be abandoned at the deadline, however long it goes on blocking.
    func testDeadlineAbandonsBlockingWork() {
        let done = DispatchSemaphore(value: 0)
        var elapsed: TimeInterval = 0
        var result: Int? = 0
        Task {
            let start = Date()
            result = await withDeadline(0.3) { await offThread { sleep(3); return 1 } }
            elapsed = Date().timeIntervalSince(start)
            done.signal()
        }
        done.wait()
        XCTAssert(result == nil)
        XCTAssert(elapsed < 1, "took \(elapsed)s")
    }

    func testDeadlinePassesFastResults() {
        let done = DispatchSemaphore(value: 0)
        var result: Int?
        Task {
            result = await withDeadline(2) { 42 }
            done.signal()
        }
        done.wait()
        XCTAssert(result == 42)
    }
}

final class HostileInputTests: XCTestCase {
    /// A zip whose central directory lists the same local entry over and over: the review's zip
    /// bomb (18 KB → 695 MB before the limits). Each local entry is read at most once now.
    func testZipCentralDirectoryCannotRepeatAnEntry() throws {
        let one = Zip.write([Zip.Entry(name: "a.conf", data: Data(repeating: 0x41, count: 1000))])
        let bytes = [UInt8](one)
        // Split: [local header + data][central entry][end record]
        let eocd = bytes.count - 22
        let centralOffset = Int(bytes[eocd + 16]) | Int(bytes[eocd + 17]) << 8
        let local = Array(bytes[..<centralOffset]), central = Array(bytes[centralOffset..<eocd])
        func archive(copies: Int) -> Data {
            var out = local
            let start = out.count
            for _ in 0..<copies { out += central }
            var end = Array(bytes[eocd...])
            end[8] = UInt8(copies & 0xFF); end[9] = UInt8(copies >> 8)
            end[10] = UInt8(copies & 0xFF); end[11] = UInt8(copies >> 8)
            let size = copies * central.count
            end[12] = UInt8(size & 0xFF); end[13] = UInt8(size >> 8 & 0xFF); end[14] = UInt8(size >> 16 & 0xFF)
            end[16] = UInt8(start & 0xFF); end[17] = UInt8(start >> 8 & 0xFF)
            return Data(out + end)
        }
        XCTAssert(try XCTUnwrap(Zip.read(archive(copies: 50))).count == 1, "the same entry was inflated repeatedly")
        XCTAssert(Zip.read(archive(copies: 300)) == nil, "more entries than any config export has")
    }

    func testDeepLinkNameAndWrappedBase64() throws {
        let conf = "[Interface]\nPrivateKey = x\n"
        let wrapped = Data(conf.utf8).base64EncodedString(options: .lineLength64Characters)
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let url = URL(string: "portway://import?c=\(wrapped)&name=My+Office")!
        let payload = try DeepLink.parse(url, scheme: "portway").get()
        XCTAssert(payload.configText == conf)
        XCTAssert(payload.suggestedName == "My Office", "form-encoded + is a space, as on Android")
    }

    func testReservedRangesAreNotPublicServers() {
        for a in ["10.1.2.3", "192.168.0.1", "127.0.0.1", "169.254.1.1", "100.100.0.1", "0.0.0.0"] {
            XCTAssert(EndpointResolver.isReserved(a), a)
        }
    }
}
