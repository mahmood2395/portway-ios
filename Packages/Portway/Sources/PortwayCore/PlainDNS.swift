// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Plain DNS (UDP port 53) straight to public resolvers, bypassing the phone's own resolver.
//
// Why this exists: the reason users "had to restart the phone" is caching. mDNSResponder and,
// much more often, the carrier's resolver keep an old A record long past its 60s TTL, so a tunnel
// restart that asks the system gets the old address back. DoH avoids every cache but is blocked
// in the country this app mostly serves. Port 53 to a public resolver usually is not — and it
// never touches the device's or the carrier's cache.
//
// Queries go to several resolvers at once and the first valid answer wins. Sent from the tunnel
// extension, the socket is outside the tunnel, so it works while the tunnel is dead.

import Foundation

public enum PlainDNS {
    public static let resolvers = ["1.1.1.1", "8.8.8.8", "9.9.9.9", "1.0.0.1"]

    /// The A records of the first resolver to answer within `timeout` (empty if none did).
    public static func resolveAll(_ host: String, resolvers: [String] = resolvers, timeout: TimeInterval = 2) async -> [String] {
        await withDeadline(timeout) {
            await offThread { query(host, resolvers: resolvers, timeout: timeout) }
        } ?? []
    }

    // MARK: Wire format

    /// A standard recursive query for `host`, type A, class IN.
    static func buildQuery(_ host: String, id: UInt16) -> [UInt8]? {
        var packet: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        // A trailing dot (fully qualified) is fine; an empty label anywhere else is not a name.
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        for label in name.split(separator: ".", omittingEmptySubsequences: false) {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count < 64 else { return nil }
            packet.append(UInt8(bytes.count))
            packet += bytes
        }
        packet += [0, 0, 1, 0, 1]
        return packet.count <= 512 ? packet : nil
    }

    /// The A records in a response to query `id`, in answer order. Follows no CNAMEs itself: a
    /// recursive resolver returns the chain's A records in the same answer section.
    static func parseA(_ r: [UInt8], id: UInt16) -> [String] {
        guard r.count >= 12, UInt16(r[0]) << 8 | UInt16(r[1]) == id,
              r[2] & 0x80 != 0,          // a response
              r[3] & 0x0F == 0 else { return [] }   // RCODE NOERROR
        let questions = Int(r[4]) << 8 | Int(r[5])
        let answers = Int(r[6]) << 8 | Int(r[7])
        var i = 12
        func skipName() -> Bool {
            while i < r.count {
                let len = Int(r[i])
                if len == 0 { i += 1; return true }
                if len & 0xC0 == 0xC0 { i += 2; return i <= r.count }   // compression pointer
                i += 1 + len
            }
            return false
        }
        for _ in 0..<questions {
            guard skipName(), i + 4 <= r.count else { return [] }
            i += 4
        }
        var found: [String] = []
        for _ in 0..<answers {
            guard skipName(), i + 10 <= r.count else { break }
            let type = Int(r[i]) << 8 | Int(r[i + 1])
            let length = Int(r[i + 8]) << 8 | Int(r[i + 9])
            i += 10
            guard i + length <= r.count else { break }
            if type == 1, length == 4 {
                found.append("\(r[i]).\(r[i + 1]).\(r[i + 2]).\(r[i + 3])")
            }
            i += length
        }
        return found
    }

    // MARK: Sockets

    private static func query(_ host: String, resolvers: [String], timeout: TimeInterval) -> [String] {
        let id = UInt16.random(in: 1...UInt16.max)
        guard let packet = buildQuery(host, id: id) else { return [] }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        // One socket, the same query to every resolver; replies are matched by id and by sender.
        var sent = Set<UInt32>()
        for resolver in resolvers {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(53).bigEndian
            guard inet_pton(AF_INET, resolver, &addr.sin_addr) == 1 else { continue }
            let n = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if n == packet.count { sent.insert(addr.sin_addr.s_addr) }
        }
        guard !sent.isEmpty else { return [] }

        let deadline = Deadline(timeout)
        var buffer = [UInt8](repeating: 0, count: 1500)
        while deadline.remaining > 0 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(max(1, deadline.remaining * 1000))) > 0 else { return [] }
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLen) }
            }
            // Only a reply from a resolver we asked: an off-path spoof must also guess the id.
            guard n > 0, sent.contains(from.sin_addr.s_addr) else { continue }
            let found = parseA(Array(buffer[0..<n]), id: id)
            if !found.isEmpty { return found }
        }
        return []
    }
}
