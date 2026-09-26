// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// The management panel (mikrotik-manager). See PANEL.md for the contract.
//
// Identity is the config's own public key — derived from the private key, so it exists however
// the config was imported — plus the interface address, which lets the panel find legacy peers.
// Possession of the private key is the credential; there are no accounts or tokens.

import Foundation

public struct PeerIdentity: Sendable, Hashable, Codable {
    public var tunnelName: String
    public var publicKey: String
    public var address: String?
    /// The endpoint host exactly as written in the config (never rewritten).
    public var endpointHost: String?

    public init(tunnelName: String, publicKey: String, address: String?, endpointHost: String?) {
        self.tunnelName = tunnelName
        self.publicKey = publicKey
        self.address = address
        self.endpointHost = endpointHost
    }
}

public struct AccountInfo: Codable, Sendable, Equatable {
    public var name: String?
    public var plan: String?
    public var expiry: String?
    public var daysLeft: Int?
    public var disabled: Bool
    public var online: Bool
    public var totalBytes: Int64?
    /// Optional on purpose: without a denominator the app shows usage alone rather than inventing
    /// a ceiling.
    public var quotaBytes: Int64?
    public var fetchedAt: Date

    public var isExpired: Bool { (daysLeft ?? 1) < 0 }

    public init(name: String?, plan: String?, expiry: String?, daysLeft: Int?, disabled: Bool, online: Bool,
                totalBytes: Int64?, quotaBytes: Int64?, fetchedAt: Date) {
        self.name = name
        self.plan = plan
        self.expiry = expiry
        self.daysLeft = daysLeft
        self.disabled = disabled
        self.online = online
        self.totalBytes = totalBytes
        self.quotaBytes = quotaBytes
        self.fetchedAt = fetchedAt
    }
}

public enum AccountResult: Sendable {
    case ok(AccountInfo)
    /// No panel URL at all.
    case notLinked
    /// Network or panel error; keep whatever is cached.
    case unavailable
    /// 404: the panel does not own this peer.
    case unknown
}

// MARK: - HTTP

enum PanelHTTP {
    struct Response {
        let status: Int
        let json: [String: Any]?
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// A request with a HARD ceiling. The claim sits between a tap and a connection, and a plain
    /// timeout on a blocking call once waited connect + read back to back — twice the budget.
    /// URLSession's async API is cancellable, so racing it against a sleep is a real ceiling.
    static func send(_ request: URLRequest, ceiling: TimeInterval) async -> Response? {
        var request = request
        request.timeoutInterval = ceiling
        return await withTaskGroup(of: Response?.self) { group in
            group.addTask {
                do {
                    let (data, response) = try await session.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    return Response(status: status, json: json)
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(ceiling * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        (self[key] as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }
    func int64(_ key: String) -> Int64? {
        if let n = self[key] as? NSNumber { return n.int64Value }
        if let s = self[key] as? String { return Int64(s) }
        return nil
    }
    func bool(_ key: String) -> Bool? {
        if let b = self[key] as? Bool { return b }
        if let n = self[key] as? NSNumber { return n.boolValue }
        return nil
    }
}

// MARK: - Account

public enum AccountStore {
    private static var d: UserDefaults { PortwayEnvironment.defaults }
    // One key per entry (SharedMap): the app and the extension both fetch and both write.
    private static let cacheMap = SharedMap<Data>("account")              // pubkey → JSON
    private static let foreignMap = SharedMap<Double>("foreign")          // pubkey → epoch seconds
    private static let hintMap = SharedMap<String>("endpoint_hint")       // host → ip
    private static let placeMap = SharedMap<String>("panel_place")        // host → "City|CC"

    /// How long a "not my peer" answer stands. Long, because asking is the thing being avoided;
    /// not forever, because an operator can add a peer after its owner installed the app.
    static let foreignRecheck: TimeInterval = 7 * 24 * 3600

    // MARK: Disowned peers

    /// Has the panel disowned this config? Answered from memory; never asks. While true the app
    /// sends that panel NOTHING about the config — handing a panel this device's id for a peer it
    /// disowned is a privacy leak.
    public static func isForeign(_ pubkey: String) -> Bool {
        guard let at = foreignMap[pubkey] else { return false }
        return Date().timeIntervalSince1970 - at < foreignRecheck
    }

    public static func markForeign(_ pubkey: String) {
        foreignMap[pubkey] = Date().timeIntervalSince1970
        // The cached account is what says "ours" to the session guard; it must go too.
        forget(pubkey)
    }

    /// Re-importing a config, or a later 200, clears the mark.
    public static func forgetForeign(_ pubkey: String) {
        if foreignMap[pubkey] != nil { foreignMap.remove(pubkey) }
    }

    // MARK: Cache

    public static func cached(_ pubkey: String) -> AccountInfo? {
        guard let data = cacheMap[pubkey] else { return nil }
        return try? JSONDecoder().decode(AccountInfo.self, from: data)
    }

    private static func store(_ info: AccountInfo, for pubkey: String) {
        cacheMap[pubkey] = try? JSONEncoder().encode(info)
    }

    public static func forget(_ pubkey: String) {
        cacheMap.remove(pubkey)
    }

    // MARK: Resolver hints and geography, learned from the panel

    /// The panel's word on what `host` resolves to, with when it said so. A hint about that
    /// hostname, never a replacement for it: the config keeps its hostname forever. Stored as
    /// "ip|epoch"; an old bare "ip" reads as infinitely old.
    public static func endpointHint(for host: String) -> (ip: String, at: Date)? {
        guard let raw = hintMap[host.lowercased()] else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        let at = parts.count > 1 ? Date(timeIntervalSince1970: Double(parts[1]) ?? 0) : .distantPast
        return (parts[0], at)
    }

    public static func setEndpointHint(host: String, ip: String, at: Date = Date()) {
        hintMap[host.lowercased()] = "\(ip)|\(Int(at.timeIntervalSince1970))"
    }

    public static func setPanelPlace(host: String, city: String?, country: String?) {
        placeMap[host.lowercased()] = "\(city ?? "")|\(country?.uppercased() ?? "")"
    }

    public static func panelPlace(for host: String) -> (city: String?, country: String?)? {
        guard let raw = placeMap[host.lowercased()] else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        return (parts.first?.nilIfEmpty, parts.count > 1 ? parts[1].nilIfEmpty : nil)
    }

    // MARK: Fetch

    public static func fetch(_ identity: PeerIdentity) async -> AccountResult {
        let settings = PortwaySettings.shared
        guard let base = settings.panelURL else { return .notLinked }
        if isForeign(identity.publicKey) { return .unknown }

        var components = URLComponents(string: base + "/api/peer/info")
        var query = [URLQueryItem(name: "pubkey", value: identity.publicKey)]
        if let address = identity.address { query.append(URLQueryItem(name: "address", value: address)) }
        components?.queryItems = query
        // URLComponents leaves "+" alone in queries; a base64 key must survive as itself.
        let encoded = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encoded
        guard let url = components?.url else { return .unavailable }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let response = await PanelHTTP.send(request, ceiling: 8) else {
            log("Account", "fetch failed: no answer")
            return .unavailable
        }
        switch response.status {
        case 200:
            guard let json = response.json else { return .unavailable }
            let info = AccountInfo(
                name: json.string("name"),
                plan: json.string("plan"),
                expiry: json.string("expiry"),
                daysLeft: json.int64("days_left").map { Int($0) },
                disabled: json.bool("disabled") ?? false,
                online: json.bool("online") ?? false,
                totalBytes: json.int64("total_bytes"),
                quotaBytes: ["quota_bytes", "plan_bytes", "limit_bytes"].lazy
                    .compactMap { json.int64($0) }.first.flatMap { $0 > 0 ? $0 : nil },
                fetchedAt: Date()
            )
            store(info, for: identity.publicKey)
            forgetForeign(identity.publicKey)
            learn(from: json, identity: identity, base: base)
            return .ok(info)
        case 404:
            markForeign(identity.publicKey)
            return .unknown
        default:
            return .unavailable
        }
    }

    private static func learn(from json: [String: Any], identity: PeerIdentity, base: String) {
        // Remote move: the panel names its authoritative URL. Persist it and every app that phones
        // home once follows the operator to a new domain.
        // HTTPS only — a move must never downgrade a TLS panel to cleartext, which would send the
        // public key and device id in the open. A LAN panel already on http may move within http.
        if let moved = json.string("panel_url")?.trimmingTrailingSlashes, moved != base,
           moved.hasPrefix("https://") || (moved.hasPrefix("http://") && base.hasPrefix("http://")) {
            log("Account", "panel moved; following")
            PortwaySettings.shared.panelURLOverride = moved
        }

        // Resolver hint. The panel answered about THIS tunnel, so its router's address is this
        // tunnel's endpoint address; a named host must agree with the config or the answer is
        // about a different server and is refused.
        let panelHost = json.string("endpoint_host")
        let configHost = identity.endpointHost
        let target: String? = {
            switch (panelHost, configHost) {
            case (nil, let c): return c
            case (let p?, nil): return p
            case (let p?, let c?): return p.caseInsensitiveCompare(c) == .orderedSame ? c : nil
            }
        }()
        if let target, let ip = json.string("endpoint_ip") {
            setEndpointHint(host: target, ip: ip)
        }

        // Geography, when the panel states it. Preferred over any device lookup: the operator
        // naming its own server involves no third party. Never invented where absent.
        if let host = panelHost ?? configHost {
            let city = json.string("city")
            let country = json.string("country_code") ?? json.string("country").flatMap { $0.count == 2 ? $0 : nil }
            if city != nil || country != nil {
                setPanelPlace(host: host, city: city, country: country)
            }
        }
    }
}
