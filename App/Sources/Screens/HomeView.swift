// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Home: one config — whatever is up, else the last used, else the first — with its live state.
//
// "Protected" is said only once the peer has answered. A tunnel is up the moment the interface
// exists; past the window with nothing from the peer the kicker reads "Not reaching the server"
// in the error ink, and the geography line is suppressed, because the city it would have surfaced
// in is not the news.

import SwiftUI
import PortwayCore
import PortwayKit

extension TunnelStore {
    func phase(for item: Item?) -> HeroPhase {
        guard let item else { return .idle }
        if claiming == item.name { return .connecting }
        switch item.status {
        case .connecting: return .connecting
        case .disconnecting: return .disconnecting
        case .reasserting: return .reconnecting
        case .connected:
            guard let snapshot, snapshot.tunnelName == item.name else { return .connecting }
            if snapshot.reconnecting { return .reconnecting }
            switch snapshot.link() {
            case .handshaking: return .connected
            case .stale, .noHandshake: return .silent
            case .connecting, .down: return .connecting
            }
        default: return .idle
        }
    }

    func decay(for item: Item?) -> (age: TimeInterval?, state: DecayState) {
        guard let item, item.status == .connected || item.status == .reasserting,
              let snapshot, snapshot.tunnelName == item.name else { return (nil, .silent) }
        let now = Date()
        return (snapshot.handshakeAge(now: now),
                DecayState.of(isUp: true, handshakeAge: snapshot.handshakeAge(now: now),
                              silentFor: snapshot.silentFor(now: now), upFor: snapshot.upFor(now: now)))
    }
}

struct HomeView: View {
    @Environment(AppState.self) private var app
    @Environment(TunnelStore.self) private var store
    @State private var showAdd = false

    var body: some View {
        let item = store.current
        VStack(spacing: 0) {
            header(item)
            ScrollView {
                VStack(spacing: 0) {
                    if let release = store.release { UpdateCard(release: release).padding(.bottom, 16) }
                    if store.loaded && store.items.isEmpty {
                        empty
                    } else {
                        hero(item)
                        details(item)
                    }
                }
                .padding(.horizontal, PW.gutter)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showAdd) { AddConfigSheet() }
        .onAppear {
            store.startPolling()
            Task { await store.refreshPings() }
        }
        .onDisappear { store.stopPolling() }
        .task(id: item?.name) {
            // Account figures: on arrival and every minute while Home is visible.
            while !Task.isCancelled {
                await store.refreshAccount(item)
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    // MARK: Header

    private func header(_ item: TunnelStore.Item?) -> some View {
        HStack {
            Text(L.tr("wordmark"))
                .font(.custom("Inter-SemiBold", size: 19))
                .tracking(-0.03 * 19)
                .foregroundStyle(PW.text)
                .environment(\.layoutDirection, .leftToRight)
            Spacer()
            if let days = store.account(for: item)?.daysLeft, days >= 0 {
                Button { app.tab = .settings } label: {
                    Text(L.tr("days_left_chip", days))
                        .font(PW.font(11.5, .medium))
                        .tabular()
                        .foregroundStyle(days <= 3 ? PW.late : PW.accent300)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 9)
                        .overlay(Capsule().strokeBorder(days <= 3 ? PW.late : PW.accent800, lineWidth: 1))
                        .frame(minHeight: 44)
                }
                .buttonStyle(PressStyle())
            }
        }
        .frame(height: 56)
        .padding(.horizontal, PW.gutter)
    }

    // MARK: Hero

    private func hero(_ item: TunnelStore.Item?) -> some View {
        let phase = store.phase(for: item)
        return VStack(spacing: 16) {
            ConnectRing(phase: phase, action: { if let item { Task { await store.toggle(item) } } },
                        accessibilityLabel: ringLabel(phase, item)) {
                VStack(spacing: 6) {
                    Text(kicker(phase)).kicker(kickerColor(phase))
                        .accessibilityHidden(true)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(figure(phase, item, now: context.date))
                            .font(PW.font(40, .medium, relativeTo: .largeTitle))
                            .tracking(PW.tracking(-0.035, size: 40))
                            .tabular()
                            .foregroundStyle(PW.text)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    Text(caption(phase, item))
                        .font(PW.font(12.5))
                        .tabular()
                        .foregroundStyle(PW.muted)
                        .lineLimit(1)
                }
                .padding(.horizontal, 36)
                .accessibilityElement(children: .combine)
            }
            .padding(.top, 8)

            Text(sentence(phase, item))
                .font(PW.font(13.5))
                .foregroundStyle(PW.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .frame(maxWidth: .infinity)
    }

    private func kicker(_ phase: HeroPhase) -> String {
        switch phase {
        case .idle: return L.tr("hero_not_protected")
        case .connecting: return L.tr("hero_connecting")
        case .disconnecting: return L.tr("hero_disconnecting")
        case .reconnecting: return L.tr("connect_reconnecting")
        case .connected: return L.tr("hero_protected")
        case .silent: return L.tr("hero_no_handshake")
        }
    }

    private func kickerColor(_ phase: HeroPhase) -> Color {
        switch phase {
        case .connected: return PW.accent
        case .silent: return PW.error
        default: return PW.muted
        }
    }

    private func figure(_ phase: HeroPhase, _ item: TunnelStore.Item?, now: Date) -> String {
        switch phase {
        case .idle: return L.tr("hero_off_figure")
        case .connecting, .disconnecting, .reconnecting: return L.tr("hero_busy_figure")
        case .connected, .silent:
            // The session start is the extension's, which survives watchdog restarts.
            guard let since = store.snapshot?.connectedSince ?? item?.manager.connection.connectedDate else {
                return L.tr("hero_connected_figure")
            }
            return L.duration(now.timeIntervalSince(since))
        }
    }

    private func caption(_ phase: HeroPhase, _ item: TunnelStore.Item?) -> String {
        switch phase {
        case .idle: return L.tr("ring_caption_idle")
        case .connecting, .reconnecting: return L.tr("ring_caption_connecting")
        case .disconnecting: return ""
        case .connected, .silent:
            var parts: [String] = []
            if phase == .connected, let place = store.place(for: item) { parts.append(place) }
            if case .ms(let ms)? = item.flatMap({ store.pings[$0.name] }) { parts.append(L.tr("ping_ms", ms)) }
            return parts.joined(separator: " · ")
        }
    }

    private func sentence(_ phase: HeroPhase, _ item: TunnelStore.Item?) -> String {
        switch phase {
        case .idle: return L.tr("hero_sub_idle")
        case .connecting, .reconnecting: return L.tr("hero_sub_connecting")
        case .disconnecting: return L.tr("hero_sub_disconnecting")
        case .silent: return L.tr("hero_sub_no_handshake")
        case .connected:
            if let place = store.place(for: item) { return L.tr("hero_sub_connected_geo", place.isolated) }
            return L.tr("hero_sub_connected")
        }
    }

    private func ringLabel(_ phase: HeroPhase, _ item: TunnelStore.Item?) -> String {
        let name = (item?.name ?? "").isolated
        switch phase {
        case .idle: return L.tr("a11y_connect", name)
        case .connecting, .reconnecting: return L.tr("a11y_connecting")
        case .disconnecting: return L.tr("a11y_disconnecting")
        case .connected, .silent: return L.tr("a11y_disconnect", name)
        }
    }

    // MARK: Below the hero

    @ViewBuilder
    private func details(_ item: TunnelStore.Item?) -> some View {
        FadingRule().padding(.vertical, 22)

        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let decay = store.decay(for: item)
            HandshakeDecayBar(age: decay.age, state: decay.state)
        }

        if let item {
            Button { app.tab = .configs } label: { ConfigCard(item: item, place: store.place(for: item)) }
                .buttonStyle(PressStyle(scale: 0.98))
                .padding(.top, 22)
        }

        let live = item?.status == .connected
        HStack(spacing: 12) {
            StatTile(label: L.tr("connect_download"), value: live ? L.rate(store.meter.rxRate) : L.tr("ping_none"))
            StatTile(label: L.tr("connect_upload"), value: live ? L.rate(store.meter.txRate) : L.tr("ping_none"))
        }
        .padding(.top, 12)

        if let key = item?.summary?.publicKey {
            MonthUsage(pubkey: key, account: store.account(for: item)).padding(.top, 26)
        }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            ArchMark().frame(width: 40, height: 40)
                .frame(width: 88, height: 88)
                .background(Circle().fill(PW.accent900))
                .overlay(Circle().strokeBorder(PW.accent800, lineWidth: 1))
                .padding(.top, 60)
            Text(L.tr("tunnel_list_empty_title"))
                .font(PW.font(24, .medium))
                .foregroundStyle(PW.text)
            Text(L.tr("hero_sub_no_tunnels"))
                .font(PW.font(14.5))
                .foregroundStyle(PW.muted)
                .multilineTextAlignment(.center)
            Button(L.tr("connect_add_tunnel")) { showAdd = true }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 12)
        }
    }
}

/// The current config: arch tile, name over "Frankfurt, DE · from 5.9.44.12", chevron.
struct ConfigCard: View {
    var item: TunnelStore.Item
    var place: String?

    var body: some View {
        HStack(spacing: 13) {
            IconTile(systemName: "mappin")
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(PW.font(14.5, .medium)).foregroundStyle(PW.text).lineLimit(1)
                Text(meta).font(PW.font(12)).foregroundStyle(PW.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PW.iconMuted)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .card()
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        let host = item.summary?.endpointHost.map { $0.isolated }
        switch (place, host) {
        case let (p?, h?): return L.tr("location_geo_from", p, h)
        case let (nil, h?): return L.tr("location_from", h)
        case let (p?, nil): return p
        default: return L.tr("tunnel_status_inactive")
        }
    }
}

/// "LAST 30 DAYS" band, with the plan's allowance when the panel states one.
struct MonthUsage: View {
    var pubkey: String
    var account: AccountInfo?

    var body: some View {
        let series = UsageHistory.series(for: pubkey, count: UsageHistory.days)
        let local = Int64(clamping: series.reduce(0, +))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L.tr("month_label")).sectionLabel()
                Spacer()
                Group {
                    if let quota = account?.quotaBytes, let used = account?.totalBytes {
                        Text(L.tr("month_of", L.bytes(used), L.bytes(quota)))
                    } else {
                        Text(L.tr("month_used", L.bytes(local)))
                    }
                }
                .font(PW.font(12.5)).tabular().foregroundStyle(PW.textSecondary)
            }
            UsageBand(series: series)
            HStack {
                Text(Date.now.addingTimeInterval(-29 * 86400), format: .dateTime.day().month(.abbreviated).locale(L.locale))
                Spacer()
                Text(L.tr("month_axis_today"))
            }
            .font(PW.font(11)).foregroundStyle(PW.muted)
            if let quota = account?.quotaBytes, let used = account?.totalBytes {
                Rail(fraction: Double(used) / Double(quota)).padding(.top, 4)
                Text(L.tr("quota_remaining", L.bytes(max(0, quota - used))))
                    .font(PW.font(12)).tabular().foregroundStyle(PW.muted)
            }
        }
    }
}

/// "Version 1.2 is available", from the panel's iOS feed. Below the supported floor it cannot be
/// dismissed: the Later button is removed rather than disabled.
struct UpdateCard: View {
    var release: AppRelease
    @State private var dismissed = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !dismissed || release.isRequired {
            VStack(alignment: .leading, spacing: 10) {
                Text(release.isRequired ? L.tr("update_required") : L.tr("update_available", release.version))
                    .font(PW.font(14.5, .medium)).foregroundStyle(PW.text)
                if let notes = release.notes {
                    Text(notes).font(PW.font(12.5)).foregroundStyle(PW.muted)
                }
                HStack(spacing: 12) {
                    Button(L.tr("update_action")) { openURL(release.url) }
                        .buttonStyle(PrimaryButtonStyle(height: 44))
                    if !release.isRequired {
                        Button(L.tr("update_later")) { dismissed = true }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            .padding(16)
            .card(fill: PW.accent900, edge: PW.accent800)
        }
    }
}
