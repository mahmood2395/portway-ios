// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// The packet-tunnel extension: WireGuard itself, plus everything Portway adds that has to keep
// running while the app is suspended.
//
// On Android all of this lived in the app process, which Android keeps alive while a VpnService
// runs. iOS suspends the app in the background, but this extension lives exactly as long as the
// VPN does — so the watchdog, the silence clock, usage sampling, the session heartbeat and the
// release all run here. Its own traffic bypasses the tunnel, which is what lets it reach the
// panel and DoH while the tunnel is dead. That same property is why geography is NEVER looked up
// from here: a geo service asked over the physical network learns the user's real address.
//
// Memory: network extensions are capped (~50 MB). Nothing here holds more than a few structs.

import Foundation
import Network
import NetworkExtension
import PortwayCore
import PortwayKit
@preconcurrency import WireGuardKit

// @unchecked: every mutable property below is confined to `queue`. Closures that capture self hop
// back onto it before touching state; `adapter` is created in init, before anything can race it.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private var adapter: WireGuardAdapter!

    private let queue = DispatchQueue(label: "app.portway.tunnel")

    // MARK: Lifecycle state

    private enum Phase {
        case idle
        /// Claiming and resolving before the adapter starts. A stop can arrive here.
        case starting
        case running
        case stopping
    }

    private var phase = Phase.idle
    /// A stop that arrived while starting: the start path finishes it at its next checkpoint.
    private var pendingStop: (reason: NEProviderStopReason, completion: () -> Void)?

    private var name = ""
    private var configuration: TunnelConfiguration?
    private var identity: PeerIdentity?
    /// Started with no options: Connect On Demand did it.
    private var startedByOnDemand = false
    private var snapshot = TunnelSnapshot(tunnelName: "")

    // MARK: Usage

    private var sampler = UsageSampler()
    /// Bumped at every restart. A stats read that began before the restart must not be counted
    /// against the sampler after it (the update zeroes the counters in between).
    private var statsGeneration = 0

    // MARK: Watchdog

    private var policy = WatchdogPolicy(connectedAt: .distantPast)
    private var restartInFlight = false
    /// The address each endpoint hostname is currently applied as, for spotting a move.
    private var appliedEndpoints: [String: String] = [:]
    private var pathChangeWork: DispatchWorkItem?
    private var pathSatisfied = true
    private var heartbeatTask: Task<Void, Never>?

    private var timers: [DispatchSourceTimer] = []
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?

    /// How often a connected tunnel re-asks where its server is. The fix for servers whose address
    /// changes: noticed within minutes, applied without waiting for the link to fail.
    private static let endpointCheckInterval: TimeInterval = 180

    override init() {
        super.init()
        adapter = WireGuardAdapter(with: self) { level, message in
            // wireguard-go is chatty at verbose level; keep errors and the handful of state lines.
            if level == .error || message.contains("Interface state") || message.contains("Handshake did not complete") {
                log("WireGuard", message)
            }
        }
    }

    // MARK: - Start

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let name = proto.tunnelName,
              let config = proto.asTunnelConfiguration(called: name) else {
            // Connect On Demand right after a reboot: the keychain opens at the first unlock, and
            // iOS retries on-demand after it. That is not a broken config.
            if ConfigKeychain.lastStatus == errSecInteractionNotAllowed {
                log("Tunnel", "start deferred: device not unlocked since boot")
                completionHandler(PacketTunnelProviderError.lockedSinceBoot)
            } else {
                log("Tunnel", "start refused: saved configuration is invalid")
                completionHandler(PacketTunnelProviderError.invalidConfiguration)
            }
            return
        }
        let identity = config.summary.identity
        // No options = Connect On Demand started us; that must never be refused.
        let gate = (options?[StartOption.gate] as? String).flatMap(SessionGate.init(rawValue:)) ?? .advisory
        let byOnDemand = options?[StartOption.gate] == nil
        log("Tunnel", "starting \(name) (gate: \(gate.rawValue))")

        queue.async {
            self.phase = .starting
            self.name = name
            self.identity = identity
            self.startedByOnDemand = byOnDemand
            DisconnectLedger.started(name)

            Task {
                if case .refused = await self.claim(identity, gate: gate) {
                    self.queue.async {
                        DisconnectLedger.abandoned(name)
                        self.finishAbortedStart(completionHandler, error: PacketTunnelProviderError.sessionInUse, release: false)
                    }
                    return
                }
                guard await self.continueStart(completionHandler) else { return }
                let (bringUp, applied) = await self.resolved(config, identity: identity)
                guard await self.continueStart(completionHandler) else { return }

                self.adapter.start(tunnelConfiguration: bringUp) { error in
                    self.queue.async {
                        if let error {
                            log("Tunnel", "start failed: \(error)")
                            DisconnectLedger.abandoned(name)
                            // A granted claim must be released, or the user's other device reads
                            // "in use" for minutes over a tunnel that never came up.
                            self.finishAbortedStart(completionHandler, error: PacketTunnelProviderError.backend(String(describing: error)), release: true)
                            return
                        }
                        self.configuration = config
                        self.snapshot = TunnelSnapshot(tunnelName: name, connectedSince: Date(),
                                                       endpointAddress: bringUp.peers.first?.endpoint.map { "\($0.host)" })
                        self.sampler = UsageSampler()
                        self.policy = WatchdogPolicy(connectedAt: Date())
                        self.appliedEndpoints = applied
                        self.phase = .running
                        completionHandler(nil)
                        if let stop = self.pendingStop {
                            // Stopped while the adapter was starting: come up, then go straight down.
                            self.pendingStop = nil
                            self.stop(reason: stop.reason, completion: stop.completion)
                            return
                        }
                        self.startTimers()
                        self.startPathMonitor()
                        self.snapshot.persist()
                    }
                }
            }
        }
    }

    /// A start checkpoint: false (and the start is wound up) if a stop arrived meanwhile.
    private func continueStart(_ completion: @escaping (Error?) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.pendingStop != nil else {
                    continuation.resume(returning: true)
                    return
                }
                DisconnectLedger.abandoned(self.name)
                self.finishAbortedStart(completion, error: PacketTunnelProviderError.cancelled, release: true)
                continuation.resume(returning: false)
            }
        }
    }

    /// On `queue`. Fails the start, releases if asked, and completes a stop that was waiting on it.
    private func finishAbortedStart(_ completion: @escaping (Error?) -> Void, error: Error, release: Bool) {
        phase = .idle
        let identity = self.identity
        let stop = pendingStop
        pendingStop = nil
        Task {
            if release, let identity { await SessionGuard.release(identity, reason: .system, restarts: 0) }
            completion(error)
            stop?.completion()
        }
    }

    // MARK: - Stop

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            switch self.phase {
            case .starting:
                // The start path owns the teardown; it finishes this at its next checkpoint.
                self.pendingStop = (reason, completionHandler)
            case .running:
                self.stop(reason: reason, completion: completionHandler)
            case .idle, .stopping:
                completionHandler()
            }
        }
    }

    /// On `queue`, from `.running`.
    private func stop(reason: NEProviderStopReason, completion: @escaping () -> Void) {
        phase = .stopping
        stopTimers()
        // A heartbeat still in flight could land after the release and mark the session live again.
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        let name = self.name
        let identity = self.identity
        let restarts = snapshot.restarts
        adapter.getRuntimeConfiguration { uapi in
            self.queue.async {
                // Flush before the counters die with the device.
                if let uapi, !self.restartInFlight { self.recordUsage(RuntimeStats(uapi: uapi)) }
                let cause = DisconnectLedger.ended(name, observed: Self.reason(for: reason))
                log("Tunnel", "stopping \(name): \(cause.rawValue) (system: \(reason.rawValue))")
                TunnelSnapshot.clearPersisted()
                self.configuration = nil
                Task {
                    // Release on EVERY teardown, not only the user's: a session left claimed tells
                    // the user's other device "in use" for minutes.
                    if let identity { await SessionGuard.release(identity, reason: cause, restarts: restarts) }
                    self.adapter.stop { _ in
                        self.queue.async { self.phase = .idle }
                        completion()
                    }
                }
            }
        }
    }

    // MARK: - App messages and sleep

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let request = String(data: messageData, encoding: .utf8).flatMap(ProviderRequest.init(rawValue:))
        queue.async {
            guard self.phase == .running else {
                completionHandler?(nil)
                return
            }
            switch request {
            case .snapshot:
                self.refreshStats { snapshot in completionHandler?(try? JSONEncoder().encode(snapshot)) }
            case .restart:
                self.policy.networkChanged()
                self.restart(reason: "requested by the app", avoiding: true)
                completionHandler?(nil)
            case nil:
                completionHandler?(nil)
            }
        }
    }

    /// Just after waking, the latest handshake is naturally older than 180s; WireGuard rekeys on
    /// the first packet. Judging at once would restart a healthy tunnel after every sleep and
    /// inflate the restart count the panel sees, so give it a moment first.
    override func wake() {
        queue.async {
            guard self.phase == .running else { return }
            self.policy.woke(at: Date())
            self.refreshStats { _ in self.snapshot.persist() }
            // Asleep for a while: the server may have moved meanwhile.
            self.checkEndpoints(reason: "woke")
        }
    }

    // MARK: - Session claim

    private enum ClaimOutcome { case proceed, refused }

    private func claim(_ identity: PeerIdentity, gate: SessionGate) async -> ClaimOutcome {
        switch gate {
        case .claimed:
            return .proceed   // the app claimed on screen and showed its own dialog
        case .headless, .advisory, .takeover:
            let result = await SessionGuard.claim(identity, takeover: gate == .takeover)
            guard case .conflict(let other) = result else { return .proceed }
            Notices.sessionConflict(tunnel: identity.tunnelName, otherDevice: other)
            // Blocking Connect On Demand is worse than a conflict: advisory only notifies.
            return gate == .headless ? .refused : .proceed
        }
    }

    // MARK: - Endpoint resolution

    /// The config to bring up — endpoint hostnames resolved through EndpointResolver (DoH, public
    /// DNS, the panel's hint, then the system, under one bounded budget), and a DNS server pinned
    /// for a full tunnel that names none — plus the host → address map that was applied. The stored
    /// config is never rewritten.
    ///
    /// `avoiding`: after a failure, the addresses that just stopped answering, so a source offering
    /// a new one wins over one repeating the old.
    private func resolved(_ config: TunnelConfiguration, identity: PeerIdentity?,
                          avoiding: [String: String] = [:]) async -> (TunnelConfiguration, [String: String]) {
        var answers: [String: String] = [:]
        // Ask the panel again at the same time, so its endpoint hint is current when it is needed.
        let refresh: (@Sendable () async -> Void)? = identity.map { id in { _ = await AccountStore.fetch(id) } }
        for peer in config.peers {
            guard let endpoint = peer.endpoint, case .name(let host, _) = endpoint.host else { continue }
            if let answer = await EndpointResolver.shared.resolve(host, avoiding: avoiding[host], refreshPanel: refresh) {
                answers[host] = answer.address
                log("Resolver", "\(host) → \(answer.address) via \(answer.source.rawValue)")
            } else {
                log("Resolver", "\(host): no source answered in time; leaving it to WireGuardKit")
            }
        }
        return (config.withResolvedEndpoints(answers).withFallbackDNS(PortwayEnvironment.fallbackDNS), answers)
    }

    /// While connected: has any endpoint's address changed? If so, apply it now, before the link
    /// even notices — the whole point is that users stop needing to restart anything.
    ///
    /// "Changed" means the address in use is no longer among the answers: a round-robin name
    /// rotates its records, and chasing the first one would restart a healthy tunnel every check.
    private func checkEndpoints(reason: String) {
        guard phase == .running, !restartInFlight, pathSatisfied, !appliedEndpoints.isEmpty else { return }
        Task {
            var answers: [String: EndpointResolver.Answer] = [:]
            for host in await self.currentApplied().keys {
                if let answer = await EndpointResolver.shared.resolve(host) { answers[host] = answer }
            }
            self.queue.async {
                // Re-judged against what is applied NOW: a watchdog restart may have landed the new
                // address while this was resolving, and a second update would throw away the
                // handshake it just completed.
                guard self.phase == .running, !self.restartInFlight else { return }
                let moved = answers.compactMap { host, answer -> String? in
                    guard let current = self.appliedEndpoints[host], !answer.all.contains(current) else { return nil }
                    return "\(host): \(current) → \(answer.address) (\(answer.source.rawValue))"
                }
                guard !moved.isEmpty else { return }
                log("Resolver", "endpoint moved (\(reason)): \(moved.joined(separator: ", "))")
                if self.restart(reason: "endpoint moved", avoiding: false, counts: false) {
                    self.policy.endpointMoved(at: Date())
                }
            }
        }
    }

    private func isRunning() async -> Bool {
        await withCheckedContinuation { c in queue.async { c.resume(returning: self.phase == .running) } }
    }

    private func currentApplied() async -> [String: String] {
        await withCheckedContinuation { c in queue.async { c.resume(returning: self.appliedEndpoints) } }
    }

    // MARK: - Timers

    private func startTimers() {
        stopTimers()
        timers = [
            timer(every: WatchdogPolicy.passInterval) { [weak self] in self?.watchdogPass() },
            timer(every: Self.endpointCheckInterval, leeway: 20) { [weak self] in self?.checkEndpoints(reason: "periodic") },
            timer(every: SessionGuard.heartbeatInterval) { [weak self] in self?.heartbeat() },
            timer(every: 60) { [weak self] in self?.refreshStats { _ in } },
            // Keeps the expiry warnings current for a user who never opens the app.
            timer(every: 3600, leeway: 300, now: true) { [weak self] in self?.refreshAccount() },
        ]
    }

    private func timer(every interval: TimeInterval, leeway: TimeInterval = 2, now: Bool = false,
                       _ body: @escaping () -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: now ? .now() + 5 : .now() + interval, repeating: interval, leeway: .milliseconds(Int(leeway * 1000)))
        t.setEventHandler(handler: body)
        t.resume()
        return t
    }

    private func stopTimers() {
        timers.forEach { $0.cancel() }
        timers = []
    }

    // MARK: - Stats and usage

    /// On `queue`. Reads the device, updates the snapshot and usage, and hands the snapshot back
    /// on `queue`.
    private func refreshStats(_ done: @escaping (TunnelSnapshot) -> Void) {
        let generation = statsGeneration
        adapter.getRuntimeConfiguration { uapi in
            self.queue.async {
                if let uapi {
                    let stats = RuntimeStats(uapi: uapi)
                    // A read that straddled a restart describes counters that no longer exist.
                    if generation == self.statsGeneration, !self.restartInFlight {
                        self.recordUsage(stats)
                    }
                    self.snapshot.lastHandshake = stats.lastHandshake
                    self.snapshot.rxBytes = stats.rxBytes
                    self.snapshot.txBytes = stats.txBytes
                }
                self.snapshot.updatedAt = Date()
                done(self.snapshot)
            }
        }
    }

    private func recordUsage(_ stats: RuntimeStats) {
        guard let pubkey = identity?.publicKey else { return }
        UsageHistory.record(sampler.delta(rx: stats.rxBytes, tx: stats.txBytes), for: pubkey)
    }

    // MARK: - Watchdog

    /// One health check. Judging always happens — the silence clock is what the app, the widgets
    /// and the panel read — and only the restart is auto-reconnect's to refuse. The decisions are
    /// WatchdogPolicy's, which the tests drive through a simulated server move.
    private func watchdogPass() {
        guard phase == .running, !restartInFlight else { return }
        let keepalive = configuration?.peers.contains { ($0.persistentKeepAlive ?? 0) > 0 } ?? false
        refreshStats { snapshot in
            defer { self.snapshot.persist() }
            guard self.phase == .running, !self.restartInFlight else { return }
            let now = Date()
            let action = self.policy.evaluate(now: now, handshakeAge: snapshot.handshakeAge(now: now),
                                              txBytes: snapshot.txBytes, rxBytes: snapshot.rxBytes,
                                              keepalive: keepalive, autoReconnect: PortwaySettings.shared.autoReconnect)
            self.snapshot.silentSince = self.policy.silentSince
            if case .restart(let reason) = action { self.restart(reason: reason, avoiding: true) }
        }
    }

    /// On `queue`. Re-resolve the endpoint and re-apply the configuration. Unlike Android there is
    /// no DOWN/UP: `WireGuardAdapter.update` keeps the interface and the routes, so a restart never
    /// lets traffic out around the tunnel and never looks like a disconnect.
    ///
    /// - avoiding: the link failed, so the addresses in use are suspect; prefer any other answer.
    /// - counts: a watchdog restart; an endpoint that merely moved is not a failure.
    @discardableResult
    private func restart(reason: String, avoiding: Bool, counts: Bool = true) -> Bool {
        guard phase == .running, let config = configuration, !restartInFlight else { return false }
        restartInFlight = true
        if counts { snapshot.restarts += 1 }
        snapshot.reconnecting = true
        snapshot.persist()
        log("Watchdog", "restarting \(name): \(reason)")
        let suspect = avoiding ? appliedEndpoints : [:]
        let identity = self.identity

        // Flush the sample first: the update replaces the peer and zeroes its counters.
        adapter.getRuntimeConfiguration { uapi in
            self.queue.async {
                if let uapi { self.recordUsage(RuntimeStats(uapi: uapi)) }
                self.statsGeneration += 1
                Task {
                    let (bringUp, applied) = await self.resolved(config, identity: identity, avoiding: suspect)
                    // Stopped while resolving: updating a tunnel that is going down would only
                    // delay the stop, and the snapshot it writes would outlive the session.
                    guard await self.isRunning() else {
                        self.queue.async { self.restartInFlight = false }
                        return
                    }
                    self.adapter.update(tunnelConfiguration: bringUp) { error in
                        self.queue.async {
                            guard self.phase == .running else { self.restartInFlight = false; return }
                            if let error { log("Watchdog", "update failed: \(error)") }
                            for (host, address) in applied where self.appliedEndpoints[host] != address {
                                log("Resolver", "\(host) now \(address) (was \(self.appliedEndpoints[host] ?? "unresolved"))")
                            }
                            self.appliedEndpoints.merge(applied) { _, new in new }
                            // Fresh counters: the first sample after this counts in full.
                            self.sampler = UsageSampler()
                            self.policy.countersReset()
                            self.policy.restartApplied(at: Date())
                            self.restartInFlight = false
                            self.snapshot.reconnecting = false
                            self.snapshot.endpointAddress = bringUp.peers.first?.endpoint.map { "\($0.host)" }
                            self.snapshot.persist()
                        }
                    }
                }
            }
        }
        return true
    }

    // MARK: - Network changes

    /// WireGuardKit follows path changes itself — it re-binds its sockets and re-applies the
    /// address it already has, but never asks DNS again. So on a new network this looks the
    /// endpoint up afresh (checkEndpoints), labels the transport for the heartbeat, pauses judging
    /// while offline, and forgives the watchdog's backoff: the backoff exists to stop hammering a
    /// broken endpoint, not to punish a tunnel for having been on a network that went away.
    private func startPathMonitor() {
        let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other])
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let transport: String
            if path.status != .satisfied { transport = "none" }
            else if path.usesInterfaceType(.wifi) { transport = "wifi" }
            else if path.usesInterfaceType(.cellular) { transport = "cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { transport = "ethernet" }
            else { transport = "other" }
            let satisfied = path.status == .satisfied
            if satisfied != self.pathSatisfied {
                self.pathSatisfied = satisfied
                if satisfied {
                    // WireGuardKit resumes its backend with fresh counters: new baselines, a grace.
                    self.policy.cameOnline(at: Date())
                    self.sampler = UsageSampler()
                } else {
                    self.policy.wentOffline()
                }
            }
            let signature = transport + path.availableInterfaces.map(\.name).joined()
            if signature != self.lastPathSignature {
                if self.lastPathSignature != nil, path.status == .satisfied {
                    self.policy.networkChanged()
                    // A new network is exactly when a stale cached address would have stranded
                    // the user. One handover emits a burst of updates, hence the debounce.
                    self.pathChangeWork?.cancel()
                    let work = DispatchWorkItem { [weak self] in self?.checkEndpoints(reason: "network changed") }
                    self.pathChangeWork = work
                    self.queue.asyncAfter(deadline: .now() + 1.5, execute: work)
                }
                self.lastPathSignature = signature
            }
            self.snapshot.transport = transport
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    // MARK: - Heartbeat

    /// Connect On Demand is on for this profile. Fails safe: a start with no options was on-demand
    /// by definition, and the app records each profile's real state — the user can flip it per
    /// profile in iOS Settings, where the app's own setting cannot see it.
    private var onDemand: Bool {
        startedByOnDemand || PortwaySettings.shared.onDemandLive(name) || PortwaySettings.shared.alwaysOn
    }

    private func heartbeat() {
        guard phase == .running, let identity else { return }
        refreshStats { snapshot in
            let now = Date()
            let report = HealthReport(
                link: snapshot.link(now: now),
                handshakeAge: snapshot.handshakeAge(now: now).map { Int($0) },
                connectedFor: snapshot.upFor(now: now).map { Int($0) },
                silentFor: snapshot.silentFor(now: now).map { Int($0) },
                rxBytes: snapshot.rxBytes, txBytes: snapshot.txBytes,
                restarts: snapshot.restarts, transport: snapshot.transport,
                onDemand: self.onDemand,
                includeAllNetworks: self.protocolConfiguration.includeAllNetworks
            )
            self.heartbeatTask = Task {
                let beat = await SessionGuard.heartbeat(identity, health: report)
                guard !Task.isCancelled else { return }
                self.queue.async {
                    switch beat {
                    case .superseded(let other): self.superseded(by: other)
                    case .active: self.snapshot.superseded = false   // taken back; a new takeover warns again
                    case .unavailable: break
                    }
                }
            }
        }
    }

    /// Another device took this config over. Disconnect and say why — except under Connect On
    /// Demand, where iOS would bring the tunnel straight back and we would drop it again, a loop
    /// that with the kill switch on cuts the user's internet on every bounce. There, only notify.
    private func superseded(by other: String?) {
        guard phase == .running else { return }
        if onDemand {
            if !snapshot.superseded {
                snapshot.superseded = true
                Notices.superseded(tunnel: name, by: other, stayedUp: true)
            }
            return
        }
        log("Session", "\(name) superseded; disconnecting")
        DisconnectLedger.expect(name, .superseded)
        Notices.superseded(tunnel: name, by: other, stayedUp: false)
        cancelTunnelWithError(nil)
    }

    // MARK: - Account

    private func refreshAccount() {
        guard let identity else { return }
        Task {
            if case .ok(let info) = await AccountStore.fetch(identity) {
                Notices.scheduleExpiry(for: identity, account: info)
            }
        }
    }

    // MARK: - Stop reasons

    private static func reason(for reason: NEProviderStopReason) -> DisconnectReason {
        switch reason {
        case .userInitiated, .configurationRemoved: return .user
        case .superceded, .configurationDisabled: return .replaced
        case .appUpdate: return .update
        default: return .system
        }
    }
}

enum PacketTunnelProviderError: LocalizedError {
    case invalidConfiguration
    case lockedSinceBoot
    case sessionInUse
    case cancelled
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return L.tr("no_config_error")
        case .lockedSinceBoot: return L.tr("locked_since_boot")
        case .sessionInUse: return L.tr("session_conflict_title")
        case .cancelled: return L.tr("tunnel_status_inactive")
        case .backend(let detail): return L.tr("error_up", detail)
        }
    }
}
