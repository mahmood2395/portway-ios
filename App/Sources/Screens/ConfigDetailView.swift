// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// One config: status, session timer, throughput, the decay bar, fourteen days of usage, health,
// and — collapsed, because a consumer never needs it and a technical user needs it once — the
// configuration itself. The private key is never shown here; export is behind Face ID.

import SwiftUI
import PortwayCore
import PortwayKit

struct ConfigDetailView: View {
    let name: String
    @Environment(TunnelStore.self) private var store
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var configOpen = false
    @State private var editing = false
    @State private var removing = false
    @State private var copied: String?

    private var item: TunnelStore.Item? { store.items.first { $0.name == name } }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: name, back: { dismiss() })
            if let item {
                ScrollView { content(item).padding(.horizontal, PW.gutter).padding(.bottom, 32) }
                    .scrollIndicators(.hidden)
            } else {
                Spacer()
            }
        }
        .background(PW.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { store.startPolling() }
        .onDisappear { store.stopPolling() }
        .sheet(isPresented: $editing) {
            if let item {
                // A rename changes the name this screen is keyed by: follow it, or it goes blank.
                EditorView(item: item) { renamed in
                    if let i = app.path.lastIndex(of: name) { app.path[i] = renamed }
                }
            }
        }
        .confirmationDialog(L.tr("detail_remove_confirm", name.isolated), isPresented: $removing, titleVisibility: .visible) {
            Button(L.tr("delete"), role: .destructive) {
                Task {
                    if let item { await store.remove(item) }
                    dismiss()
                }
            }
        } message: { Text(L.tr("detail_remove_detail")) }
        .overlay(alignment: .bottom) {
            if let copied {
                Text(L.tr("copied_to_clipboard", copied))
                    .font(PW.font(13)).foregroundStyle(PW.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .card()
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: copied)
    }

    @ViewBuilder
    private func content(_ item: TunnelStore.Item) -> some View {
        let phase = store.phase(for: item)
        let live = item.status == .connected && store.snapshot?.tunnelName == item.name
        VStack(alignment: .leading, spacing: 0) {
            Text(kicker(phase)).kicker(phase == .connected ? PW.accent : phase == .silent ? PW.error : PW.muted)
                .padding(.top, 8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(timer(item, now: context.date))
                    .font(PW.font(34, .medium, relativeTo: .largeTitle))
                    .tracking(PW.tracking(-0.035, size: 34))
                    .tabular()
                    .foregroundStyle(PW.text)
                    .contentTransition(.numericText())
            }
            .padding(.top, 6)
            Text(sentence(item, phase))
                .font(PW.font(13.5)).foregroundStyle(PW.muted)
                .padding(.top, 6)

            HStack(spacing: 12) {
                StatTile(label: L.tr("connect_download"), value: live ? L.rate(store.meter.rxRate) : L.tr("ping_none"),
                         footnote: live ? L.tr("detail_session_total", L.bytes(Int64(store.snapshot?.rxBytes ?? 0))) : nil)
                StatTile(label: L.tr("connect_upload"), value: live ? L.rate(store.meter.txRate) : L.tr("ping_none"),
                         footnote: live ? L.tr("detail_session_total", L.bytes(Int64(store.snapshot?.txBytes ?? 0))) : nil)
            }
            .padding(.top, 20)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let decay = store.decay(for: item)
                HandshakeDecayBar(age: decay.age, state: decay.state)
            }
            .padding(.top, 28)

            if let key = item.summary?.publicKey {
                let series = UsageHistory.series(for: key, count: UsageHistory.fortnight)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L.tr("detail_usage_label")).sectionLabel()
                        Spacer()
                        Text(L.tr("month_used", L.bytes(Int64(clamping: series.reduce(0, +)))))
                            .font(PW.font(12.5)).tabular().foregroundStyle(PW.textSecondary)
                    }
                    UsageBand(series: series, height: 96, gap: 6, topRadius: 2)
                    HStack {
                        Text(Date.now.addingTimeInterval(-13 * 86400), format: .dateTime.day().month(.abbreviated).locale(L.locale))
                        Spacer()
                        Text(Date.now, format: .dateTime.day().month(.abbreviated).locale(L.locale))
                    }
                    .font(PW.font(11)).foregroundStyle(PW.muted)
                }
                .padding(.top, 28)
            }

            Text(L.tr("detail_health_label")).sectionLabel().padding(.top, 28).padding(.bottom, 4)
            health(item)

            disclosure(item).padding(.top, 22)

            HStack(spacing: 12) {
                // From the phase, not isUp: while disconnecting or claiming, a tap would do nothing
                // useful, and the label must not promise one.
                let busy = phase == .disconnecting || store.claiming == item.name
                Button(busy ? L.tr(phase == .disconnecting ? "hero_disconnecting" : "hero_connecting")
                            : (item.isUp ? L.tr("detail_disconnect") : L.tr("detail_connect"))) {
                    Task { await store.toggle(item) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy)
                Button(L.tr("edit")) { editing = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 28)

            Button(L.tr("detail_remove")) { removing = true }
                .buttonStyle(GhostButtonStyle(color: PW.muted))
                .padding(.top, 8)
        }
    }

    // MARK: Health

    private func health(_ item: TunnelStore.Item) -> some View {
        let ping = store.pings[item.name]
        let pingText: String = switch ping {
        case .ms(let ms)?: L.tr("ping_ms", ms)
        case .failed?: L.tr("ping_timeout")
        default: L.tr("ping_none")
        }
        return VStack(spacing: 0) {
            healthRow(dot: item.isUp ? PW.accent400 : (ping == .failed ? PW.fail : PW.dotRest), L.tr("connect_ping_label"), pingText)
            healthRow(dot: PW.dotRest, L.tr("endpoint"), item.summary?.endpointDisplay ?? "—")
            if let resolved = store.snapshot?.endpointAddress, store.snapshot?.tunnelName == item.name,
               resolved != item.summary?.endpointHost {
                healthRow(dot: PW.dotRest, L.tr("detail_resolved_address"), resolved)
            }
            healthRow(dot: PW.dotRest, L.tr("detail_resolved_location"), store.place(for: item) ?? "—")
            if let restarts = store.snapshot?.restarts, restarts > 0, store.snapshot?.tunnelName == item.name {
                healthRow(dot: PW.late, L.tr("detail_restarts"), L.number(restarts))
            }
        }
    }

    private func healthRow(dot: Color, _ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Dot(color: dot, size: 7)
            Text(label).font(PW.font(13.5)).foregroundStyle(PW.muted)
            Spacer()
            Text(value).font(PW.font(13.5)).tabular().foregroundStyle(PW.text).lineLimit(1)
                .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(PW.rule).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    // MARK: Configuration disclosure

    private func disclosure(_ item: TunnelStore.Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.3)) { configOpen.toggle() }
            } label: {
                HStack {
                    Text(L.tr("detail_configuration")).font(PW.font(13.5, .medium)).foregroundStyle(PW.text)
                    Spacer()
                    Text(configOpen ? L.tr("detail_hide") : L.tr("detail_show")).font(PW.font(12.5)).foregroundStyle(PW.muted)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(PressStyle(scale: 0.99))
            .overlay(alignment: .top) { Rectangle().fill(PW.rule).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(PW.rule).frame(height: 1) }
            .accessibilityValue(configOpen ? L.tr("detail_hide") : L.tr("detail_show"))

            if configOpen, let s = item.summary {
                VStack(alignment: .leading, spacing: 0) {
                    pair(L.tr("public_key"), s.publicKey)
                    pair(L.tr("addresses"), s.addresses.joined(separator: ", "))
                    pair(L.tr("dns_servers"), s.dns.isEmpty ? "—" : s.dns.joined(separator: ", "))
                    pair(L.tr("allowed_ips"), s.allowedIPs.joined(separator: ", "))
                    pair(L.tr("persistent_keepalive"), s.keepalive.map { L.tr("detail_keepalive_seconds", Int($0)) } ?? L.tr("detail_keepalive_off"))
                    pair(L.tr("mtu"), s.mtu.map { "\($0)" } ?? L.tr("hint_automatic"))
                }
                .transition(.opacity.combined(with: .offset(y: 16)))
            }
        }
    }

    /// Tap to copy, as upstream does.
    private func pair(_ label: String, _ value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copied = label
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = nil }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(PW.font(11.5)).foregroundStyle(PW.muted)
                Text(value).font(PW.font(13.5)).foregroundStyle(PW.text)
                    .multilineTextAlignment(.leading)
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(PW.rule).frame(height: 1) }
        }
        .buttonStyle(PressStyle(scale: 0.99))
        .accessibilityHint(L.tr("a11y_copy"))
    }

    // MARK: Text

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

    private func timer(_ item: TunnelStore.Item, now: Date) -> String {
        guard item.status == .connected || item.status == .reasserting else { return L.tr("hero_off_figure") }
        let since = (store.snapshot?.tunnelName == item.name ? store.snapshot?.connectedSince : nil) ?? item.manager.connection.connectedDate
        return since.map { L.duration(now.timeIntervalSince($0)) } ?? L.tr("hero_connected_figure")
    }

    private func sentence(_ item: TunnelStore.Item, _ phase: HeroPhase) -> String {
        switch phase {
        case .connected:
            if let place = store.place(for: item) { return L.tr("detail_sentence_connected_geo", item.name.isolated, place.isolated) }
            return L.tr("detail_sentence_connected", item.name.isolated)
        case .silent: return L.tr("hero_sub_no_handshake")
        default: return L.tr("detail_sentence_down")
        }
    }
}
