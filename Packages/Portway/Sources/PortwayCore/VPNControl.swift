// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Starting and stopping tunnels without the app's UI: Shortcuts, widgets, the Control Center
// control and notification actions. The app's own screens go through TunnelStore, which adds
// the on-screen session claim and conflict dialog; these entry points pass a gate instead and let
// the extension claim.

import Foundation
import NetworkExtension

public enum VPNControl {
    public static func managers() async throws -> [NETunnelProviderManager] {
        try await NETunnelProviderManager.loadAllFromPreferences()
    }

    /// The config Home shows: whatever is up, else the last used, else the first.
    public static func current(in managers: [NETunnelProviderManager]) -> NETunnelProviderManager? {
        if let active = managers.first(where: { $0.connection.status.isActiveOrPending }) { return active }
        if let last = PortwaySettings.shared.lastUsedTunnel,
           let m = managers.first(where: { $0.localizedDescription == last }) { return m }
        return managers.sorted { ($0.localizedDescription ?? "") < ($1.localizedDescription ?? "") }.first
    }

    public static func isConnected() async -> Bool {
        guard let managers = try? await managers() else { return false }
        return managers.contains { $0.connection.status.isActiveOrPending }
    }

    public static func connect(named name: String? = nil, gate: SessionGate) async throws {
        let all = try await managers()
        guard let manager = name.flatMap({ n in all.first { $0.localizedDescription == n } }) ?? current(in: all) else {
            throw NEVPNError(.configurationInvalid)
        }
        try await start(manager, gate: gate)
    }

    /// Enables (which disables every other profile — iOS runs one VPN at a time) and starts.
    ///
    /// Connect On Demand is switched back on only AFTER the explicit start has been issued: enabled
    /// first, iOS's own on-demand start (no options, so no takeover) races ours, and a "Use here
    /// instead" would lose to it.
    public static func start(_ manager: NETunnelProviderManager, gate: SessionGate) async throws {
        let name = manager.localizedDescription ?? ""
        PortwaySettings.shared.setPaused(name, true)   // hold on-demand off across the start
        let changed = applyProtection(to: manager)
        if !manager.isEnabled || changed {
            manager.isEnabled = true
            try await save(manager)
        }
        PortwaySettings.shared.lastUsedTunnel = name
        do {
            try manager.connection.startVPNTunnel(options: [StartOption.gate: gate.rawValue as NSString])
        } catch {
            // A failed start must not leave always-on silently paused.
            PortwaySettings.shared.setPaused(name, false)
            if applyProtection(to: manager) { try? await save(manager) }
            throw error
        }
        PortwaySettings.shared.setPaused(name, false)
        guard PortwaySettings.shared.alwaysOn else { return }
        let rearm = { @Sendable in
            _ = await waitForStatus(manager.connection, .connected, timeout: 20)
            if applyProtection(to: manager) { try? await save(manager) }
        }
        if gate == .claimed {
            Task { await rearm() }   // the app stays alive; don't hold the UI
        } else {
            // A Shortcut, widget or notification action may be suspended the moment it returns:
            // finish re-arming Connect On Demand first, or it stays off while Settings says on.
            await rearm()
        }
    }

    public static func disconnect() async {
        guard let all = try? await managers() else { return }
        for manager in all where manager.connection.status.isActiveOrPending || manager.isOnDemandEnabled {
            // With Connect On Demand on, a plain stop is undone by iOS within seconds. A user who
            // asks for "off" means off: on-demand is paused on this profile until they connect again.
            PortwaySettings.shared.setPaused(manager.localizedDescription ?? "", true)
            if manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = false
                try? await save(manager)
            }
            manager.connection.stopVPNTunnel()
        }
    }

    /// Saves and reloads, and records the profile's real on-demand state for the extension.
    public static func save(_ manager: NETunnelProviderManager) async throws {
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        PortwaySettings.shared.setOnDemandLive(manager.localizedDescription ?? "", manager.isOnDemandEnabled)
    }

    /// Resolves when `connection` reaches `status`, or false after `timeout`. A start sent while a
    /// tunnel is still `.disconnecting` is silently dropped, so restarts must wait for this.
    public static func waitForStatus(_ connection: NEVPNConnection, _ status: NEVPNStatus, timeout: TimeInterval) async -> Bool {
        let deadline = Deadline(timeout)
        while deadline.remaining > 0 {
            if connection.status == status { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return connection.status == status
    }

    public static func toggle() async throws {
        if await isConnected() { await disconnect() } else { try await connect(gate: .headless) }
    }
}

extension VPNControl {
    /// Brings a profile in line with Settings → Protection. Returns whether anything changed.
    ///
    /// - Kill switch: `includeAllNetworks`, so nothing leaves the device outside the tunnel, even
    ///   while it reconnects. Local networks are let through unless the user says otherwise.
    /// - Always-on: Connect On Demand. Trusted Wi-Fi networks disconnect; everything else connects.
    @discardableResult
    public static func applyProtection(to manager: NETunnelProviderManager) -> Bool {
        let settings = PortwaySettings.shared
        var changed = false
        if let proto = manager.protocolConfiguration {
            if proto.includeAllNetworks != settings.killSwitch {
                proto.includeAllNetworks = settings.killSwitch
                changed = true
            }
            if proto.excludeLocalNetworks != settings.excludeLocalNetworks {
                proto.excludeLocalNetworks = settings.excludeLocalNetworks
                changed = true
            }
        }
        let rules = onDemandRules(trusted: settings.trustedSSIDs)
        let wanted = settings.alwaysOn && !settings.isPaused(manager.localizedDescription ?? "")
        if wanted != manager.isOnDemandEnabled || (wanted && !sameRules(manager.onDemandRules, rules)) {
            manager.onDemandRules = wanted ? rules : []
            manager.isOnDemandEnabled = wanted
            changed = true
        }
        return changed
    }

    static func onDemandRules(trusted: [String]) -> [NEOnDemandRule] {
        var rules: [NEOnDemandRule] = []
        if !trusted.isEmpty {
            let stay = NEOnDemandRuleDisconnect()
            stay.interfaceTypeMatch = .wiFi
            stay.ssidMatch = trusted
            rules.append(stay)
        }
        rules.append(NEOnDemandRuleConnect())   // any interface
        return rules
    }

    private static func sameRules(_ a: [NEOnDemandRule]?, _ b: [NEOnDemandRule]) -> Bool {
        guard let a, a.count == b.count else { return false }
        return zip(a, b).allSatisfy { type(of: $0) == type(of: $1) && $0.ssidMatch == $1.ssidMatch }
    }
}

extension NEVPNStatus {
    public var isActiveOrPending: Bool {
        switch self {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }
}
