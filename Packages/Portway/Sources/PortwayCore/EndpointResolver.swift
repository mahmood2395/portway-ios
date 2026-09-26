// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Finding the server after it moves.
//
// WireGuard freezes the endpoint's resolved address at bring-up, and device and carrier resolvers
// routinely over-cache and ignore a 60s TTL — which is why "reboot the phone" used to be the fix.
// So every (re)start resolves the endpoint here, from several sources queried CONCURRENTLY but
// consumed in PREFERENCE order, not arrival order: a carrier resolver holding a stale record
// answers in milliseconds while the source that knows the truth takes longer. Fast and wrong must
// lose to slow and right.
//
//   1. DNS over HTTPS, 1.1.1.1 and 8.8.8.8 by IP literal (no bootstrap lookup), in parallel.
//   2. The panel's endpoint_ip hint for this hostname, if recent.
//   3. Plain DNS to public resolvers (PlainDNS): no device or carrier cache, not blocked like DoH.
//   4. The system resolver.
//   5. An old panel hint.
//
// This is the iOS fix for "the server's IP changed and only restarting the phone helped":
// WireGuardKit resolves once, at start, through the system resolver, and never again — on a
// network change it re-applies the address it already has. Portway resolves here instead, at
// every start and restart, periodically while connected, and on every network change.
//
// Where DoH is blocked — the case in the country this is deployed to — waiting on it would tax
// every reconnect. After two consecutive failures it is still probed but no longer waited on, and
// one success restores it.
//
// HARD CONSTRAINT: the hostname in the config is never rewritten. Only the lookup changes. An IP
// written into the config would make it depend on the panel forever.
//
// Runs in the tunnel extension, whose own traffic bypasses the tunnel — so it works while the
// tunnel is dead, which is exactly when it is needed.

import Foundation

public actor EndpointResolver {
    public static let shared = EndpointResolver()

    static let budget: TimeInterval = 3.5
    /// A panel hint younger than this counts as current; older ones are a last resort.
    static let hintFreshness: TimeInterval = 10 * 60

    public enum Source: String, Sendable { case doh, udp, panel, system, stalePanel = "stale-panel", literal }

    /// The lookups, injectable so the ordering can be tested without a network.
    /// Each returns every address it found (empty = no answer). All of them, not just the first:
    /// a round-robin name rotates its records, and "the first one changed" is not a move.
    public struct Sources: Sendable {
        public var doh: @Sendable (String) async -> [String]
        public var udp: @Sendable (String) async -> [String]
        public var system: @Sendable (String) async -> [String]
        public var hint: @Sendable (String) -> (ip: String, at: Date)?

        public init(doh: @escaping @Sendable (String) async -> [String], udp: @escaping @Sendable (String) async -> [String],
                    system: @escaping @Sendable (String) async -> [String], hint: @escaping @Sendable (String) -> (ip: String, at: Date)?) {
            self.doh = doh
            self.udp = udp
            self.system = system
            self.hint = hint
        }

        public static let live = Sources(
            doh: { await EndpointResolver.doh($0) },
            udp: { await PlainDNS.resolveAll($0, timeout: EndpointResolver.budget) },
            system: { host in await offThread { EndpointResolver.system(host) } },
            hint: { AccountStore.endpointHint(for: $0) }
        )
    }

    public struct Answer: Sendable, Equatable {
        public var address: String
        public var source: Source
        /// Every address the winning source gave: the current one still being among them means
        /// the server has not moved.
        public var all: [String]
    }

    private let sources: Sources
    private var dohFailures = 0

    public init(sources: Sources = .live) { self.sources = sources }

    /// Resolves `host` to an address, or nil when nothing answered within the budget.
    ///
    /// Every source starts at once under ONE 3.5s deadline, and the answers are then taken in a
    /// strict order of trust — fast and wrong must lose to slow and right:
    ///
    ///   1. DoH (1.1.1.1, 8.8.8.8): authenticated, and no cache between us and the authority.
    ///   2. The panel's hint, if recent (`refreshPanel` asks again, in parallel): authenticated,
    ///      and the operator's own word on where the server is.
    ///   3. Plain DNS to public resolvers: skips the phone's and the carrier's caches — the caches
    ///      that made "restart your phone" the only fix — and works where DoH is blocked. Not
    ///      authenticated, so answers in private or reserved ranges (what injectors hand out for
    ///      filtered names) are discarded, and it ranks below the panel.
    ///   4. The system resolver: may be stale, but better than nothing.
    ///   5. An old panel hint.
    ///
    /// `avoiding`: the address that has just stopped answering. Within one source's answer set
    /// (a round-robin name), another address is preferred. Across sources the order stays strict:
    /// a short outage at the RIGHT address must not send the tunnel to a stale one just because a
    /// lesser source disagrees.
    public func resolve(_ host: String, avoiding: String? = nil,
                        refreshPanel: (@Sendable () async -> Void)? = nil) async -> Answer? {
        if Self.isIPLiteral(host) { return Answer(address: host, source: .literal, all: [host]) }
        let deadline = Deadline(Self.budget)
        let s = sources

        let doh = Task { await s.doh(host) }
        let udp = Task { await s.udp(host).filter { !Self.isReserved($0) } }
        let system = Task { await s.system(host) }
        let panel = Task { await refreshPanel?() }

        func answer(_ addresses: [String], _ source: Source) -> Answer? {
            guard let first = addresses.first else { return nil }
            return Answer(address: addresses.first(where: { $0 != avoiding }) ?? first, source: source, all: addresses)
        }

        var dohFailed = false
        if dohFailures < 2 {
            let found = await withDeadline(max(0, deadline.remaining - 1.5), { await doh.value }) ?? []
            if found.isEmpty { dohFailed = true } else { dohFailures = 0 }
            if let hit = answer(found, .doh) { return hit }
        } else {
            // Probed, not waited on; one success restores waiting next time.
            Task { [weak self] in if await !doh.value.isEmpty { await self?.dohRecovered() } }
        }

        // The rest of the answers decide whether a DoH failure means "DoH is blocked" or merely
        // "there is no network" — only the first should demote it.
        defer { if dohFailed { dohFailures += 1 } }

        _ = await withDeadline(max(0, deadline.remaining - 1), { await panel.value; return true })
        let hint = s.hint(host)
        if let hint, Date().timeIntervalSince(hint.at) < Self.hintFreshness, let hit = answer([hint.ip], .panel) { return hit }

        if let hit = answer(await withDeadline(max(0, deadline.remaining - 0.5), { await udp.value }) ?? [], .udp) { return hit }
        if let hit = answer(await withDeadline(deadline.remaining, { await system.value }) ?? [], .system) { return hit }
        if let hint, let hit = answer([hint.ip], .stalePanel) { return hit }
        dohFailed = false   // nothing answered at all: offline, not blocked
        return nil
    }

    /// Private, shared, loopback, link-local and unspecified IPv4 ranges: never a public server's
    /// address, and exactly what DNS injection hands out.
    static func isReserved(_ address: String) -> Bool {
        let p = address.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        switch (p[0], p[1]) {
        case (10, _), (127, _), (0, _): return true
        case (172, 16...31), (192, 168), (169, 254): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    private func dohRecovered() { dohFailures = 0 }

    // MARK: Sources

    static func doh(_ host: String) async -> [String] {
        let encoded = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
        let urls = [
            "https://1.1.1.1/dns-query?name=\(encoded)&type=A",
            "https://8.8.8.8/resolve?name=\(encoded)&type=A",
        ].compactMap(URL.init(string:))
        return await withTaskGroup(of: [String].self) { group in
            for url in urls {
                group.addTask {
                    var request = URLRequest(url: url, timeoutInterval: budget)
                    request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
                    guard let (data, _) = try? await PanelHTTP.session.data(for: request),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let answers = json["Answer"] as? [[String: Any]] else { return [] }
                    // type 1 = A. CNAME chains come first; keep every address.
                    return answers.filter { ($0["type"] as? Int) == 1 }.compactMap { $0["data"] as? String }
                }
            }
            for await answer in group where !answer.isEmpty {
                group.cancelAll()
                return answer
            }
            return []
        }
    }

    static func system(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }
        // IPv4 first: the configs this app carries are IPv4 endpoints, and NAT64 synthesis happens
        // later, in WireGuardKit, from the literal.
        var v4: [String] = [], v6: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let n = node {
            if let s = numericHost(n.pointee.ai_addr, n.pointee.ai_addrlen) {
                if n.pointee.ai_family == AF_INET { if !v4.contains(s) { v4.append(s) } } else if !v6.contains(s) { v6.append(s) }
            }
            node = n.pointee.ai_next
        }
        return v4 + v6
    }

    static func numericHost(_ addr: UnsafeMutablePointer<sockaddr>?, _ len: socklen_t) -> String? {
        guard let addr else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, len, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buffer)
    }

    public static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return inet_pton(AF_INET, bare, &v4) == 1 || inet_pton(AF_INET6, bare, &v6) == 1
    }
}
