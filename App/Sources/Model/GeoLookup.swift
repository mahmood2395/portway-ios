// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// "Your traffic surfaces in Frankfurt, DE" — when the panel has not said so itself.
//
// Asking a geo service over the physical network hands a third party the user's REAL address,
// the opposite of what this line claims. So the question is only asked when it is certain to ride
// the tunnel:
//   - from the app, never the extension (the extension's own traffic bypasses the tunnel);
//   - only while the tunnel is handshaking, so a dead tunnel cannot fall back to anything;
//   - only when every route is the tunnel's: both 0.0.0.0/0 and ::/0, or the kill switch. With
//     0.0.0.0/0 alone the providers' AAAA records are reached over the physical IPv6 path. A split
//     tunnel is not asked at all: the panel's answer, or the bare IP, is shown instead.
// The panel's own place (AccountStore.panelPlace) always wins, and nothing is ever invented.

import Foundation
import PortwayCore
import PortwayKit

actor GeoLookup {
    static let shared = GeoLookup()

    private static let places = SharedMap<String>("device_place")   // host → "City|CC"
    private static let timeout: TimeInterval = 6
    private static let maxAttemptsPerSession = 3
    private static let retryInterval: TimeInterval = 20

    private var attempts: [String: (count: Int, last: Date)] = [:]

    nonisolated static func cached(host: String) -> String? {
        guard let raw = places[host.lowercased()] else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        return L.place(city: parts.first?.nilIfEmpty, country: parts.count > 1 ? parts[1].nilIfEmpty : nil)
    }

    func resolveIfNeeded(summary: ConfigSummary) async {
        guard summary.routesEverything || PortwaySettings.shared.killSwitch, let host = summary.endpointHost?.lowercased() else { return }
        if AccountStore.panelPlace(for: host) != nil || Self.cached(host: host) != nil { return }
        let now = Date()
        if let a = attempts[host], a.count >= Self.maxAttemptsPerSession || now.timeIntervalSince(a.last) < Self.retryInterval { return }
        attempts[host] = ((attempts[host]?.count ?? 0) + 1, now)

        for provider in Self.providers {
            if let place = await provider() {
                Self.places[host] = "\(place.city ?? "")|\(place.country ?? "")"
                return
            }
        }
    }

    private typealias Place = (city: String?, country: String?)

    private static let providers: [@Sendable () async -> Place?] = [
        {
            guard let json = await fetchJSON("https://ipwho.is/"), json["success"] as? Bool != false else { return nil }
            return place(json["city"] as? String, json["country_code"] as? String)
        },
        {
            guard let json = await fetchJSON("https://ipapi.co/json/") else { return nil }
            return place(json["city"] as? String, json["country_code"] as? String)
        },
        {
            // Country only, but it is Cloudflare, which is rarely blocked where the others are.
            guard let text = await fetchText("https://1.1.1.1/cdn-cgi/trace"),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("loc=") }) else { return nil }
            return place(nil, String(line.dropFirst(4)))
        },
    ]

    private static func place(_ city: String?, _ country: String?) -> Place? {
        let c = city?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let cc = country.flatMap { $0.count == 2 ? $0.uppercased() : nil }
        return c == nil && cc == nil ? nil : (c, cc)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        return URLSession(configuration: config)
    }()

    private static func fetchText(_ url: String) async -> String? {
        guard let url = URL(string: url) else { return nil }
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func fetchJSON(_ url: String) async -> [String: Any]? {
        guard let text = await fetchText(url), let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
