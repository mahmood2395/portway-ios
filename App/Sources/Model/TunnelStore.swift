// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// The app's view of its configs: one NETunnelProviderManager (a VPN profile in iOS Settings) per
// config, the live status iOS reports for each, and the running extension's snapshot.
//
// Connecting from a screen claims the session HERE, before the tunnel starts, because only the app
// can show the "in use on another device" dialog. Everything headless lets the extension claim.
//
// iOS runs one VPN at a time, so Android's "allow several at once" has no equivalent: enabling one
// profile disables the others, and starting it stops whichever was up.

import Foundation
import NetworkExtension
import Observation
import PortwayCore
import PortwayKit
import WidgetKit
import WireGuardKit

@MainActor
@Observable
final class TunnelStore {
    struct Item: Identifiable, Equatable {
        var id: String { name }
        let manager: NETunnelProviderManager
        var name: String
        var summary: ConfigSummary?
        var status: NEVPNStatus

        var isUp: Bool { status.isActiveOrPending }

        /// The manager's identity counts: after a reload the same config is a NEW manager object,
        /// and a view that kept the old one would act on a stale profile (VPNControl.start trusts
        /// its isEnabled).
        static func == (a: Item, b: Item) -> Bool {
            a.name == b.name && a.status == b.status && a.summary == b.summary && a.manager === b.manager
        }
    }

    enum Ping: Equatable { case probing, ms(Int), failed }

    struct Conflict: Identifiable {
        let id = UUID()
        let item: Item
        let otherDevice: String?
    }

    private(set) var items: [Item] = []
    private(set) var loaded = false
    /// Shown when iOS refused to load profiles at all (no entitlement, or a broken install).
    private(set) var loadError: String?

    private(set) var snapshot: TunnelSnapshot?
    private(set) var meter = ThroughputMeter()
    private(set) var accounts: [String: AccountInfo] = [:]
    private(set) var pings: [String: Ping] = [:]
    private(set) var release: AppRelease?
    /// Connecting while the claim is in flight: a tap must show movement at once, not after 3s.
    private(set) var claiming: String?

    var conflict: Conflict?
    var alert: String?

    private var statusObserver: NSObjectProtocol?
    /// Keychain items no profile references are swept once per launch, and never while a save is
    /// in flight: the first import's save shows the system's VPN alert, the scene goes inactive and
    /// active again, and a reload in that window would see the new item before its profile exists.
    private var sweptKeychain = false
    private var savesInFlight = 0
    /// Bumped by every save; a reload that straddled one must not sweep the keychain.
    private var saveGeneration = 0
    /// Parsed summaries by keychain reference: a reload runs on every foreground and status change,
    /// and reading + parsing every config from the keychain each time is main-thread work.
    private var summaryCache: [Data: ConfigSummary] = [:]
    private var simulatorExplained = false
    /// Simulator only: configs iOS would not save, kept for the session so they survive reloads.
    private var memoryItems: [Item] = []
    private var pollTask: Task<Void, Never>?
    private var pollers = 0

    init() {
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
            guard let connection = note.object as? NEVPNConnection else { return }
            MainActor.assumeIsolated { self?.statusChanged(connection) }
        }
    }

    // MARK: - Queries

    /// Home's config: whatever is up, else the last used, else the first.
    var current: Item? {
        if let up = items.first(where: \.isUp) { return up }
        if let last = PortwaySettings.shared.lastUsedTunnel, let item = items.first(where: { $0.name == last }) { return item }
        return items.first
    }

    func account(for item: Item?) -> AccountInfo? {
        guard let key = item?.summary?.publicKey else { return nil }
        return accounts[key] ?? AccountStore.cached(key)
    }

    /// "Frankfurt, DE" when something actually resolved it, else nil — never an invented city.
    func place(for item: Item?) -> String? {
        guard let host = item?.summary?.endpointHost else { return nil }
        if let p = AccountStore.panelPlace(for: host) { return L.place(city: p.city, country: p.country) }
        return GeoLookup.cached(host: host)
    }

    // MARK: - Loading

    func reload() async {
        if Demo.isOn { loadDemo(); return }
        let generation = saveGeneration
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let previous = items
            var refs = Set<Data>()
            var missing: [(Data, NETunnelProviderProtocol, String)] = []
            for manager in managers {
                guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol, let ref = proto.passwordReference else { continue }
                refs.insert(ref)
                if summaryCache[ref] == nil { missing.append((ref, proto, manager.localizedDescription ?? proto.tunnelName ?? "config")) }
            }
            // Only configs not seen before are read and parsed, off the main actor.
            if !missing.isEmpty {
                let parsed = await Task.detached {
                    missing.compactMap { ref, proto, name in proto.asTunnelConfiguration(called: name).map { (ref, $0.summary) } }
                }.value
                for (ref, summary) in parsed { summaryCache[ref] = summary }
            }
            summaryCache = summaryCache.filter { refs.contains($0.key) }
            items = managers.compactMap { manager in
                guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return nil }
                let name = manager.localizedDescription ?? proto.tunnelName ?? "config"
                var summary = proto.passwordReference.flatMap { summaryCache[$0] }
                summary?.name = name
                return Item(manager: manager, name: name, summary: summary, status: manager.connection.status)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            #if targetEnvironment(simulator)
            // Keep the simulated status the screen already shows, not the status as first added.
            for kept in memoryItems where !items.contains(where: { $0.name == kept.name }) {
                items.append(previous.first { $0.name == kept.name } ?? kept)
            }
            #endif
            // Not while a save is in flight, and not if one landed while profiles were loading: the
            // list above may predate the new profile, whose keychain item would be swept.
            if !sweptKeychain && savesInFlight == 0 && generation == saveGeneration {
                sweptKeychain = true
                ConfigKeychain.deleteAll(except: refs)
            }
            for manager in managers {
                PortwaySettings.shared.setOnDemandLive(manager.localizedDescription ?? "", manager.isOnDemandEnabled)
            }
            loadError = nil
            await reconcileSurfaces()
        } catch {
            loadError = error.localizedDescription
            log("Store", "loading profiles failed: \(error)")
        }
        loaded = true
    }

    private func statusChanged(_ connection: NEVPNConnection) {
        guard let index = items.firstIndex(where: { $0.manager.connection === connection }) else { return }
        let old = items[index].status
        items[index].status = connection.status
        reloadWidgets()
        let item = items[index]
        // Only a real arrival. A watchdog restart passes through .reasserting and back, which is
        // not a new session: re-running this there reset the Live Activity to "reaching" while the
        // link was silent, and pinged every 30s against a dead server.
        if connection.status == .connected, old != .connected, old != .reasserting {
            let place = place(for: item)
            Task { await LiveActivityController.start(tunnelName: item.name, connectedSince: connection.connectedDate ?? Date(), place: place) }
            Task { await refreshPings() }
        }
        if connection.status == .disconnected {
            if old.isActiveOrPending { Task { await LiveActivityController.end() } }
            if snapshot?.tunnelName == item.name { snapshot = nil; meter.reset() }
            // iOS keeps the extension's start error; surfacing it is the difference between "it
            // did nothing" and "your config is in use on another device".
            if old == .connecting {
                connection.fetchLastDisconnectError { error in
                    guard let error else { return }
                    Task { @MainActor in self.alert = error.localizedDescription }
                }
            }
        }
    }

    /// Widgets and the Live Activity cannot see status changes themselves. After every reload —
    /// including the one on return from the background, when a tunnel may have been stopped from
    /// Settings or started by a Shortcut — bring them in line with what is actually up.
    private func reconcileSurfaces() async {
        reloadWidgets()
        #if canImport(ActivityKit)
        if let up = items.first(where: { $0.status == .connected }) {
            if !LiveActivityController.isRunning {
                await LiveActivityController.start(tunnelName: up.name, connectedSince: up.manager.connection.connectedDate,
                                                   place: place(for: up))
            }
        } else if !items.contains(where: \.isUp), LiveActivityController.isRunning {
            await LiveActivityController.end()
        }
        #endif
    }

    private func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) { ControlCenter.shared.reloadAllControls() }
    }

    // MARK: - Import and editing

    func add(_ candidate: ImportCandidate, name: String) async throws -> Item {
        if Demo.isOn { return demoAdd(candidate, name: name) }
        // Before the keychain item exists, so no sweep can see it without its profile.
        savesInFlight += 1
        saveGeneration += 1
        defer { savesInFlight -= 1 }
        let unique = ConfigImporter.uniqueName(name, existing: Set(items.map(\.name)))
        let config = candidate.configuration
        config.name = unique
        guard let proto = NETunnelProviderProtocol(tunnelConfiguration: config) else { throw StoreError.keychain }
        let manager = NETunnelProviderManager()
        manager.localizedDescription = unique
        manager.protocolConfiguration = proto
        manager.isEnabled = items.isEmpty
        VPNControl.applyProtection(to: manager)
        do {
            // The first save is when iOS asks "Allow Portway to add VPN configurations?".
            try await VPNControl.save(manager)
        } catch {
            proto.destroyConfigurationReference()
            #if targetEnvironment(simulator)
            // The Simulator has no VPN support, so every save fails with "IPC failed". Keep the
            // config in memory instead, so the import, list and detail screens can still be tried
            // with a real config, and say once why nothing is saved.
            if !simulatorExplained {
                simulatorExplained = true
                alert = L.tr("simulator_no_vpn")
            }
            let kept = demoAdd(candidate, name: name)
            memoryItems.append(kept)
            return kept
            #else
            throw error
            #endif
        }
        let summary = config.summary
        // Re-importing clears a "not ours" mark: the user may have been given a config the panel
        // has since adopted.
        AccountStore.forgetForeign(summary.publicKey)
        await reload()
        Task { await SessionGuard.register(summary.identity) }
        if PortwaySettings.shared.lastUsedTunnel == nil { PortwaySettings.shared.lastUsedTunnel = unique }
        return items.first { $0.name == unique } ?? Item(manager: manager, name: unique, summary: summary, status: .disconnected)
    }

    func save(_ item: Item, text: String, name: String) async throws {
        savesInFlight += 1
        saveGeneration += 1
        defer { savesInFlight -= 1 }
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let others = Set(items.map(\.name)).subtracting([item.name])
        guard !wanted.isEmpty else { throw StoreError.emptyName }
        guard !others.contains(wanted) else { throw StoreError.nameTaken(wanted) }
        let config = try TunnelConfiguration(fromWgQuickConfig: text, called: wanted)
        let oldProto = item.manager.protocolConfiguration as? NETunnelProviderProtocol
        guard let proto = NETunnelProviderProtocol(tunnelConfiguration: config) else { throw StoreError.keychain }
        proto.includeAllNetworks = oldProto?.includeAllNetworks ?? false
        proto.excludeLocalNetworks = oldProto?.excludeLocalNetworks ?? true
        // The item the editor opened with may be minutes old; ask the connection itself.
        let wasUp = item.manager.connection.status.isActiveOrPending
        if wanted != item.name {
            // Carry the pause across the rename, or an edit re-arms on-demand.
            PortwaySettings.shared.setPaused(wanted, PortwaySettings.shared.isPaused(item.name))
        }
        item.manager.localizedDescription = wanted
        item.manager.protocolConfiguration = proto
        VPNControl.applyProtection(to: item.manager)
        do {
            try await VPNControl.save(item.manager)
        } catch {
            // The profile still points at the old item; drop the new one.
            proto.destroyConfigurationReference()
            item.manager.protocolConfiguration = oldProto
            item.manager.localizedDescription = item.name
            throw error
        }
        oldProto?.destroyConfigurationReference()
        if wanted != item.name {
            DisconnectLedger.forget(item.name)
            if PortwaySettings.shared.lastUsedTunnel == item.name { PortwaySettings.shared.lastUsedTunnel = wanted }
        }
        await reload()
        // A running tunnel keeps its old configuration until told; the extension re-reads on start.
        if wasUp, let fresh = items.first(where: { $0.name == wanted }) {
            fresh.manager.connection.stopVPNTunnel()
            // A start sent while still .disconnecting is dropped; the stop can take a few seconds
            // (usage flush, then the session release).
            _ = await VPNControl.waitForStatus(fresh.manager.connection, .disconnected, timeout: 10)
            do { try await VPNControl.start(fresh.manager, gate: .claimed) } catch { alert = Self.describe(error) }
        }
    }

    func remove(_ item: Item) async {
        // Its status notification will find no item once the profile is gone, so nothing else
        // would end the Live Activity for a config deleted while connected.
        if item.isUp { await LiveActivityController.end() }
        memoryItems.removeAll { $0.name == item.name }
        if item.isUp { item.manager.connection.stopVPNTunnel() }
        (item.manager.protocolConfiguration as? NETunnelProviderProtocol)?.destroyConfigurationReference()
        try? await item.manager.removeFromPreferences()
        if let key = item.summary?.publicKey {
            UsageHistory.forget(key)
            AccountStore.forget(key)
        }
        DisconnectLedger.forget(item.name)
        if PortwaySettings.shared.lastUsedTunnel == item.name { PortwaySettings.shared.lastUsedTunnel = nil }
        await reload()
    }

    func configText(_ item: Item) -> String? {
        (item.manager.protocolConfiguration as? NETunnelProviderProtocol)?
            .asTunnelConfiguration(called: item.name)?.asWgQuickConfig()
    }

    // MARK: - Connecting

    func toggle(_ item: Item) async {
        if item.isUp || item.status == .disconnecting { disconnect(item) } else { await connect(item) }
    }

    func connect(_ item: Item, takeover: Bool = false) async {
        if Demo.isOn { await demoSet(item, up: true); return }
        guard claiming == nil else { return }
        claiming = item.name
        defer { claiming = nil }
        if let identity = item.summary?.identity {
            // Fail-open: only a clear 409 stops us, and the claim never waits more than 3s.
            if case .conflict(let other) = await SessionGuard.claim(identity, takeover: takeover) {
                conflict = Conflict(item: item, otherDevice: other)
                return
            }
        }
        #if targetEnvironment(simulator)
        if memoryItems.contains(where: { $0.name == item.name }) {
            await demoSet(item, up: true)
            return
        }
        #endif
        do {
            try await VPNControl.start(item.manager, gate: .claimed)
        } catch {
            log("Store", "start failed: \(error)")
            alert = Self.describe(error)
        }
        await reload()
    }

    func disconnect(_ item: Item) {
        if Demo.isOn { Task { await demoSet(item, up: false) }; return }
        #if targetEnvironment(simulator)
        if memoryItems.contains(where: { $0.name == item.name }) { Task { await demoSet(item, up: false) }; return }
        #endif
        // A user who asks for "off" under Connect On Demand means off; VPNControl pauses it.
        Task {
            await VPNControl.disconnect()
            await reload()
        }
    }

    // MARK: - Live polling (only while a screen that shows it is visible)

    /// Counted, not a flag: SwiftUI can run the incoming screen's onAppear before the outgoing
    /// one's onDisappear (navigation, or a language switch re-creating the tree), and a flag let
    /// the late stop cancel the poller the new screen had just asked for.
    func startPolling() {
        pollers += 1
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollers = max(0, pollers - 1)
        guard pollers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    /// The app went to the background: pause, keeping the count of screens that want it.
    func pausePolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Back in the foreground: resume if any screen still showing asked for it.
    func resumePolling() {
        guard pollers > 0, pollTask == nil else { return }
        pollers -= 1
        startPolling()
    }

    private func poll() async {
        if Demo.isOn { demoTick(); return }
        guard let item = items.first(where: { $0.status == .connected || $0.status == .reasserting }),
              let session = item.manager.connection as? NETunnelProviderSession else {
            if snapshot != nil { snapshot = nil; meter.reset() }
            return
        }
        guard let data = await session.sendMessage(Data(ProviderRequest.snapshot.rawValue.utf8)),
              let fresh = try? JSONDecoder().decode(TunnelSnapshot.self, from: data) else { return }
        // "Reaching" means the peer is answering — handshaking — not merely "not yet judged silent".
        let wasReaching = snapshot.map { $0.link() == .handshaking }
        snapshot = fresh
        meter.add(rx: fresh.rxBytes, tx: fresh.txBytes, at: fresh.updatedAt)
        let reaching = fresh.link() == .handshaking
        if wasReaching != reaching {
            await LiveActivityController.update(connectedSince: fresh.connectedSince, place: place(for: item), reaching: reaching)
        }
        // Geography is looked up from here, never from the extension: only app traffic rides the
        // tunnel, and a geo service reached outside it would learn the user's real address.
        if fresh.link() == .handshaking, let summary = item.summary {
            await GeoLookup.shared.resolveIfNeeded(summary: summary)
        }
    }

    func restartTunnel() async {
        guard let session = items.first(where: \.isUp)?.manager.connection as? NETunnelProviderSession else { return }
        _ = await session.sendMessage(Data(ProviderRequest.restart.rawValue.utf8))
    }

    // MARK: - Panel

    func refreshAccount(_ item: Item?) async {
        if Demo.isOn { return }
        guard let identity = item?.summary?.identity else { return }
        if case .ok(let info) = await AccountStore.fetch(identity) {
            accounts[identity.publicKey] = info
            await Notices.requestPermissionIfUndecided()
            Notices.scheduleExpiry(for: identity, account: info)
        }
    }

    /// Once per launch, a little after start, for every config the panel has not disowned.
    func registerAll() async {
        if Demo.isOn { return }
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        for identity in items.compactMap({ $0.summary?.identity }) {
            await SessionGuard.register(identity)
        }
    }

    func checkForUpdate() async {
        if Demo.isOn { return }
        release = await UpdateChecker.check()
    }

    // MARK: - Ping (once per screen visit, never on a poll)

    func refreshPings() async {
        if Demo.isOn { demoPings(); return }
        await withTaskGroup(of: (String, Ping).self) { group in
            for item in items {
                guard let host = item.summary?.endpointHost else { continue }
                pings[item.name] = .probing
                group.addTask { (item.name, await Pinger.rtt(host: host).map(Ping.ms) ?? .failed) }
            }
            for await (name, result) in group { pings[name] = result }
        }
    }

    // MARK: - Protection

    /// Settings → Protection changed: bring every profile in line.
    func applyProtection() async {
        for item in items where VPNControl.applyProtection(to: item.manager) {
            try? await VPNControl.save(item.manager)
        }
        await reload()
    }

    // MARK: - Export

    func exportZip() throws -> URL {
        let entries = items.compactMap { item in
            configText(item).map { Zip.Entry(name: "\(item.name).conf", data: Data($0.utf8)) }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("portway-configs.zip")
        try Zip.write(entries).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// NetworkExtension's own errors are short and technical ("IPC failed", "permission denied");
    /// these say what happened and what to do.
    static func describe(_ error: Error) -> String {
        #if targetEnvironment(simulator)
        if (error as NSError).domain == NEVPNErrorDomain { return L.tr("simulator_no_vpn") }
        #endif
        if let vpn = error as? NEVPNError {
            switch vpn.code {
            case .configurationReadWriteFailed:
                // Most often the user tapped "Don't Allow" on the system's VPN prompt.
                return L.tr("vpn_permission_denied")
            case .configurationInvalid, .configurationDisabled:
                return L.tr("vpn_configuration_invalid")
            case .configurationStale:
                return L.tr("vpn_configuration_stale")
            case .connectionFailed:
                return L.tr("vpn_connection_failed")
            default:
                break
            }
        }
        if let store = error as? StoreError { return store.localizedDescription }
        return L.tr("error_up", error.localizedDescription)
    }

    enum StoreError: LocalizedError {
        case keychain, emptyName, nameTaken(String)
        var errorDescription: String? {
            switch self {
            case .keychain: return L.tr("config_save_error", "", L.tr("unknown_error"))
            case .emptyName: return L.tr("tunnel_error_invalid_name")
            case .nameTaken(let n): return L.tr("tunnel_error_already_exists", n.isolated)
            }
        }
    }
}

extension NETunnelProviderSession {
    func sendMessage(_ data: Data) async -> Data? {
        await withCheckedContinuation { continuation in
            do {
                try sendProviderMessage(data) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}

// MARK: - Demo mode
//
// `-demo` (debug builds only): four configs, one connected with a live-ticking handshake and
// throughput, usage history and an account, so every screen and state can be seen and
// screenshotted in the Simulator, which cannot bring a real tunnel up. Nothing is saved to iOS.

enum Demo {
    #if DEBUG
    static let isOn = ProcessInfo.processInfo.arguments.contains("-demo")
    #else
    static let isOn = false
    #endif
    /// `-demo-silent`: the connected config stops handshaking, for the "Not reaching" states.
    static let silent = ProcessInfo.processInfo.arguments.contains("-demo-silent")
}

extension TunnelStore {
    private static let demoConfigs: [(name: String, host: String, city: String, cc: String)] = [
        ("beta-frankfurt", "fra.demo.portway.app", "Frankfurt", "DE"),
        ("alpha-ams", "ams.demo.portway.app", "Amsterdam", "NL"),
        ("home-nas", "81.4.22.9", "", ""),
        ("work", "lon.demo.portway.app", "London", "GB"),
    ]

    fileprivate func loadDemo() {
        guard !loaded else { return }
        items = Self.demoConfigs.enumerated().compactMap { index, c in
            let text = """
            [Interface]
            PrivateKey = \(PrivateKey().base64Key)
            Address = 10.66.0.\(index + 2)/32
            DNS = 1.1.1.1

            [Peer]
            PublicKey = \(PrivateKey().publicKey.base64Key)
            AllowedIPs = 0.0.0.0/0, ::/0
            Endpoint = \(c.host):51820
            PersistentKeepalive = 25
            """
            guard case .success(let candidate) = ConfigImporter.candidate(text: text, name: c.name) else { return nil }
            if !c.city.isEmpty { AccountStore.setPanelPlace(host: c.host, city: c.city, country: c.cc) }
            let manager = NETunnelProviderManager()
            manager.localizedDescription = c.name
            let summary = candidate.summary
            // Thirty days of plausible usage, heavier at weekends.
            for back in 0..<30 {
                let day = Date().addingTimeInterval(-Double(back) * 86_400)
                let weekend = Calendar.current.isDateInWeekend(day)
                let base: UInt64 = index == 0 ? 420_000_000 : 60_000_000
                UsageHistory.record(UInt64.random(in: base / 3...base) * (weekend ? 2 : 1), for: summary.publicKey, at: day)
            }
            return Item(manager: manager, name: c.name, summary: summary, status: index == 0 ? .connected : .disconnected)
        }
        if let key = items.first?.summary?.publicKey {
            accounts[key] = AccountInfo(name: "Sara M.", plan: "Premium 30 GB", expiry: nil, daysLeft: 23, disabled: false,
                                        online: true, totalBytes: 12_400_000_000, quotaBytes: 30_000_000_000, fetchedAt: Date())
        }
        PortwaySettings.shared.lastUsedTunnel = items.first?.name
        snapshot = demoSnapshot(for: items.first?.name ?? "", since: Date().addingTimeInterval(-4_980))
        loaded = true
    }

    private func demoSnapshot(for name: String, since: Date) -> TunnelSnapshot {
        TunnelSnapshot(tunnelName: name, connectedSince: since,
                       lastHandshake: Demo.silent ? nil : Date().addingTimeInterval(-12),
                       rxBytes: 1_800_000_000, txBytes: 240_000_000, restarts: Demo.silent ? 4 : 0,
                       silentSince: Demo.silent ? Date().addingTimeInterval(-260) : nil,
                       endpointAddress: "5.9.44.12", transport: "wifi")
    }

    /// Advances the connected config: a rekey every two minutes, a few MB/s either way.
    fileprivate func demoTick() {
        guard var s = snapshot, items.contains(where: { $0.name == s.tunnelName && $0.status == .connected }) else { return }
        let now = Date()
        if !Demo.silent, let last = s.lastHandshake, now.timeIntervalSince(last) > 121 { s.lastHandshake = now }
        // A server answering nothing sends nothing back.
        s.rxBytes += Demo.silent ? 0 : UInt64.random(in: 2_000_000...6_500_000)
        s.txBytes += UInt64.random(in: 150_000...900_000)
        s.updatedAt = now
        snapshot = s
        meter.add(rx: s.rxBytes, tx: s.txBytes, at: now)
    }

    fileprivate func demoSet(_ item: Item, up: Bool) async {
        for i in items.indices where items[i].name != item.name && items[i].isUp { items[i].status = .disconnected }
        guard let i = items.firstIndex(where: { $0.name == item.name }) else { return }
        items[i].status = up ? .connecting : .disconnecting
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        guard let j = items.firstIndex(where: { $0.name == item.name }) else { return }
        items[j].status = up ? .connected : .disconnected
        PortwaySettings.shared.lastUsedTunnel = item.name
        meter.reset()
        snapshot = up ? demoSnapshot(for: item.name, since: Date()) : nil
        if up { snapshot?.lastHandshake = Date() }
    }

    fileprivate func demoAdd(_ candidate: ImportCandidate, name: String) -> Item {
        let unique = ConfigImporter.uniqueName(name, existing: Set(items.map(\.name)))
        let manager = NETunnelProviderManager()
        manager.localizedDescription = unique
        let item = Item(manager: manager, name: unique, summary: candidate.summary, status: .disconnected)
        items.append(item)
        return item
    }

    fileprivate func demoPings() {
        let values: [String: Ping] = ["beta-frankfurt": .ms(42), "alpha-ams": .ms(58), "home-nas": .failed, "work": .ms(91)]
        for item in items { pings[item.name] = values[item.name] ?? .ms(Int.random(in: 30...120)) }
    }
}
