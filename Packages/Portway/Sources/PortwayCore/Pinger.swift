// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Round-trip time to a config's endpoint.
//
// RTT is a property of the peer, not a live meter — the decay bar shows liveness — so this runs
// once when a screen appears, never on a poll.
//
// The host is resolved ONCE, before timing, so DNS never pollutes the figure. Then an ICMP burst
// (three echoes on an unprivileged datagram socket, averaged over whatever answered — one echo
// reads a single lost packet as "no connectivity"), then a TCP connect to :443 and :80. Many
// networks filter ICMP. A SYN answered by an accept OR a reset costs exactly one round trip, so
// time-to-refusal is an honest RTT; other failures (unreachable) fail locally in ~0ms and must not
// be reported as latency.
//
// Every wait is a poll() with a deadline on a non-blocking socket. A probe that never returns
// once pinned an Android row at "probing" for 80 seconds; nothing here can block past its budget.
//
// With a full tunnel up, the probe rides the tunnel like all app traffic. That is the honest
// number: a dead tunnel reads "—" rather than a misleading direct-path RTT.

import Foundation

public enum Pinger {
    /// One overall budget for the whole probe, lookup included. A dead full tunnel sends DNS into
    /// the tunnel too, where getaddrinfo can block for tens of seconds; that is abandoned at 1.5s.
    public static func rtt(host: String, budget: TimeInterval = 4) async -> Int? {
        let deadline = Deadline(budget)
        guard let address = await withDeadline(min(1.5, deadline.remaining), { await offThread { resolve(host) } }) else {
            return nil
        }
        return await offThread {
            if let ms = icmp(address, count: 3, timeout: min(1.2, deadline.remaining)) { return ms }
            for port in [443, 80] {
                let slice = port == 443 ? deadline.remaining / 2 : deadline.remaining
                guard slice > 0.05 else { break }
                if let ms = tcp(address, port: port, timeout: slice) { return ms }
            }
            return nil
        }
    }

    // MARK: Resolution

    fileprivate struct Address: @unchecked Sendable {
        var storage = sockaddr_storage()
        var length: socklen_t = 0
        var family: Int32 { Int32(storage.ss_family) }
    }

    fileprivate static func resolve(_ host: String) -> Address? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard getaddrinfo(bare, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        var chosen: UnsafeMutablePointer<addrinfo>?
        while let n = node {
            if n.pointee.ai_family == AF_INET { chosen = n; break }
            if chosen == nil, n.pointee.ai_family == AF_INET6 { chosen = n }
            node = n.pointee.ai_next
        }
        guard let c = chosen, let sa = c.pointee.ai_addr else { return nil }
        var address = Address()
        address.length = c.pointee.ai_addrlen
        withUnsafeMutableBytes(of: &address.storage) { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(start: sa, count: Int(c.pointee.ai_addrlen)))
        }
        return address
    }

    private static func withSockaddr<T>(_ address: Address, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var storage = address.storage
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, address.length) }
        }
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    // MARK: ICMP

    private static func icmp(_ address: Address, count: Int, timeout: TimeInterval) -> Int? {
        let v6 = address.family == AF_INET6
        let fd = socket(address.family, SOCK_DGRAM, v6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let identifier = UInt16.random(in: 1...UInt16.max)
        var samples: [UInt64] = []
        for seq in 0..<UInt16(count) {
            var packet = [UInt8](repeating: 0, count: 16)
            packet[0] = v6 ? 128 : 8
            packet[4] = UInt8(identifier >> 8); packet[5] = UInt8(identifier & 0xFF)
            packet[6] = UInt8(seq >> 8); packet[7] = UInt8(seq & 0xFF)
            if !v6 {   // the kernel fills the ICMPv6 checksum; ICMPv4 is ours
                let sum = checksum(packet)
                packet[2] = UInt8(sum >> 8); packet[3] = UInt8(sum & 0xFF)
            }
            let sent = now()
            let n = withSockaddr(address) { sa, len in sendto(fd, packet, packet.count, 0, sa, len) }
            guard n == packet.count else { continue }
            let deadline = sent + UInt64(timeout / Double(count) * 1e9)
            if awaitReply(fd, v6: v6, identifier: identifier, seq: seq, deadline: deadline) {
                samples.append(now() - sent)
            }
        }
        guard !samples.isEmpty else { return nil }
        return Int((samples.reduce(0, +) / UInt64(samples.count)) / 1_000_000)
    }

    private static func awaitReply(_ fd: Int32, v6: Bool, identifier: UInt16, seq: UInt16, deadline: UInt64) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            let current = now()
            guard current < deadline else { return false }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ms = Int32((deadline - current) / 1_000_000)
            guard poll(&pfd, 1, max(ms, 1)) > 0 else { return false }
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { continue }
            // On Darwin an IPv4 ICMP datagram socket hands back the IP header too.
            var offset = 0
            if !v6, buffer[0] >> 4 == 4 { offset = Int(buffer[0] & 0x0F) * 4 }
            guard n >= offset + 8 else { continue }
            let type = buffer[offset]
            let id = UInt16(buffer[offset + 4]) << 8 | UInt16(buffer[offset + 5])
            let s = UInt16(buffer[offset + 6]) << 8 | UInt16(buffer[offset + 7])
            if type == (v6 ? 129 : 0), id == identifier, s == seq { return true }
        }
    }

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }

    // MARK: TCP

    private static func tcp(_ address: Address, port: Int, timeout: TimeInterval) -> Int? {
        var target = address
        let family = target.family
        withUnsafeMutableBytes(of: &target.storage) { raw in
            let p = UInt16(port).bigEndian
            if family == AF_INET {
                raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_port = p
            } else {
                raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_port = p
            }
        }
        let fd = socket(target.family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let start = now()
        let rc = withSockaddr(target) { sa, len in connect(fd, sa, len) }
        var error: Int32 = rc == 0 ? 0 : errno
        if rc != 0, error == EINPROGRESS {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return nil }
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len)
        }
        let elapsed = Int((now() - start) / 1_000_000)
        switch error {
        case 0, ECONNREFUSED: return max(elapsed, 1)
        default: return nil
        }
    }
}
