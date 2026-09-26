// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// The facts about a config the screens and the panel need, pulled out of WireGuardKit's types
// once, so nothing above this file has to know them.

import Foundation
import Network
import PortwayCore
import WireGuardKit

public struct ConfigSummary: Sendable, Equatable {
    public var name: String
    public var publicKey: String
    public var address: String?
    public var addresses: [String]
    public var dns: [String]
    public var endpointHost: String?
    public var endpointPort: UInt16?
    public var peerCount: Int
    /// A default route (0.0.0.0/0 or ::/0) — "routing all traffic", as the screens say it.
    public var routesAll: Bool
    /// BOTH default routes. Only this guarantees an app request cannot leave outside the tunnel:
    /// with 0.0.0.0/0 alone, a host with an AAAA record is reached over the physical IPv6 path.
    public var routesEverything: Bool
    public var routeCount: Int
    public var allowedIPs: [String]
    public var keepalive: UInt16?
    public var mtu: UInt16?

    public var identity: PeerIdentity {
        PeerIdentity(tunnelName: name, publicKey: publicKey, address: address, endpointHost: endpointHost)
    }

    public var endpointDisplay: String? {
        guard let host = endpointHost else { return nil }
        let bracketed = host.contains(":") ? "[\(host)]" : host
        return endpointPort.map { "\(bracketed):\($0)" } ?? bracketed
    }
}

extension TunnelConfiguration {
    public var summary: ConfigSummary {
        let allowed = peers.flatMap(\.allowedIPs)
        let endpoint = peers.first?.endpoint
        let host: String? = endpoint.map { endpoint in
            switch endpoint.host {
            case .name(let name, _): return name
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a): return "\(a)"
            @unknown default: return "\(endpoint.host)"
            }
        }
        return ConfigSummary(
            name: name ?? "",
            publicKey: interface.privateKey.publicKey.base64Key,
            address: interface.addresses.first?.stringRepresentation,
            addresses: interface.addresses.map(\.stringRepresentation),
            dns: interface.dns.map(\.stringRepresentation) + interface.dnsSearch,
            endpointHost: host,
            endpointPort: endpoint?.port.rawValue,
            peerCount: peers.count,
            routesAll: allowed.contains { $0.networkPrefixLength == 0 },
            routesEverything: allowed.contains { $0.networkPrefixLength == 0 && $0.address is IPv4Address }
                && allowed.contains { $0.networkPrefixLength == 0 && $0.address is IPv6Address },
            routeCount: allowed.count,
            allowedIPs: allowed.map(\.stringRepresentation),
            keepalive: peers.first?.persistentKeepAlive,
            mtu: interface.mtu
        )
    }

    /// A copy with every endpoint hostname swapped for an address resolved by
    /// `EndpointResolver`. Used only for bring-up; the stored config keeps its hostnames.
    public func withResolvedEndpoints(_ resolved: [String: String]) -> TunnelConfiguration {
        let peers = self.peers.map { peer -> PeerConfiguration in
            var copy = peer
            if let endpoint = peer.endpoint, case .name(let host, _) = endpoint.host,
               let address = resolved[host], let literal = Endpoint(from: address.contains(":") ? "[\(address)]:\(endpoint.port)" : "\(address):\(endpoint.port)") {
                copy.endpoint = literal
            }
            return copy
        }
        return TunnelConfiguration(name: name, interface: interface, peers: peers)
    }

    /// A full-tunnel config that names no DNS server gets one pinned, so lookups do not fall back
    /// to the local network's resolver — unreachable from inside the tunnel, or leaking outside it.
    /// Deliberately narrow: in a split tunnel "no DNS" means "use the network's", and overriding
    /// that would break resolution.
    public func withFallbackDNS(_ server: String?) -> TunnelConfiguration {
        guard let server, interface.dns.isEmpty,
              peers.flatMap(\.allowedIPs).contains(where: { $0.networkPrefixLength == 0 }),
              let dns = DNSServer(from: server) else { return self }
        var iface = interface
        iface.dns = [dns]
        return TunnelConfiguration(name: name, interface: iface, peers: peers)
    }
}
