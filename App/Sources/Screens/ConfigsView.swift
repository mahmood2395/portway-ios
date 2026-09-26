// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Configs: the set a user was handed. Portway has no server list, so rows are quiet — the eye
// should go to the one that is connected. Tapping a row switches to it; the chevron opens detail.

import SwiftUI
import PortwayCore
import PortwayKit

struct ConfigsView: View {
    @Environment(TunnelStore.self) private var store
    @State private var showAdd = false
    @State private var removing: TunnelStore.Item?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: L.tr("nav_configs")) {
                Button(L.tr("add")) { showAdd = true }.buttonStyle(ChipButtonStyle())
            }
            if store.loaded && store.items.isEmpty {
                empty
            } else {
                List {
                    ForEach(store.items) { item in
                        ConfigRow(item: item, meta: meta(item), dot: dot(item), ping: store.pings[item.name])
                            .listRowInsets(EdgeInsets(top: 0, leading: PW.gutter, bottom: 0, trailing: PW.gutter))
                            .listRowBackground(PW.ground)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button(L.tr("delete")) { removing = item }.tint(PW.fail)
                            }
                    }
                    Rectangle().fill(PW.rule).frame(height: 1)
                        .listRowInsets(EdgeInsets(top: 0, leading: PW.gutter, bottom: 0, trailing: PW.gutter))
                        .listRowBackground(PW.ground)
                        .listRowSeparator(.hidden)
                    Text(L.tr("configs_footnote_ios"))
                        .font(PW.font(13))
                        .lineSpacing(4)
                        .foregroundStyle(PW.muted)
                        .listRowInsets(EdgeInsets(top: 18, leading: PW.gutter, bottom: 24, trailing: PW.gutter))
                        .listRowBackground(PW.ground)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await store.refreshPings() }
            }
        }
        .sheet(isPresented: $showAdd) { AddConfigSheet() }
        .task { await store.refreshPings() }
        .onAppear { store.startPolling() }
        .onDisappear { store.stopPolling() }
        .confirmationDialog(L.tr("detail_remove_confirm", (removing?.name ?? "").isolated),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { item in
            Button(L.tr("delete"), role: .destructive) { Task { await store.remove(item) } }
        } message: { _ in Text(L.tr("detail_remove_detail")) }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Spacer()
            ArchMark().frame(width: 36, height: 36)
                .frame(width: 80, height: 80)
                .background(Circle().fill(PW.accent900))
                .overlay(Circle().strokeBorder(PW.accent800, lineWidth: 1))
            Text(L.tr("tunnel_list_empty_title")).font(PW.font(24, .medium)).foregroundStyle(PW.text)
            Text(L.tr("tunnel_list_placeholder"))
                .font(PW.font(14.5)).foregroundStyle(PW.muted).multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }

    /// The one sentence under a config's name. First match wins; never a city that was not
    /// resolved.
    private func meta(_ item: TunnelStore.Item) -> String {
        let host = item.summary?.endpointHost?.isolated
        let place = store.place(for: item)
        let silent = item.status == .connected && store.snapshot?.tunnelName == item.name && store.snapshot?.link().isSilent == true
        func join(_ a: String, _ b: String?) -> String { b.map { "\(a) · \($0)" } ?? a }
        if silent { return join(L.tr("peer_no_handshake"), host) }
        if item.isUp { return join(L.tr("tunnel_status_active"), place) }
        if store.pings[item.name] == .failed { return join(L.tr("peer_no_route"), host) }
        if let place { return join(place, host) }
        return host ?? L.tr("tunnel_status_inactive")
    }

    private func dot(_ item: TunnelStore.Item) -> Color {
        if item.isUp { return PW.accent }
        if store.pings[item.name] == .failed { return PW.fail }
        return PW.dotRest
    }
}

private struct ConfigRow: View {
    @Environment(TunnelStore.self) private var store
    @Environment(AppState.self) private var app
    var item: TunnelStore.Item
    var meta: String
    var dot: Color
    var ping: TunnelStore.Ping?

    var body: some View {
        HStack(spacing: 13) {
            Button {
                Task { if !item.isUp { await store.connect(item) } }
            } label: {
                HStack(spacing: 13) {
                    ZStack {
                        Dot(color: dot)
                        if ping == .probing { ProbingDot() }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(PW.font(15, .medium)).foregroundStyle(PW.text).lineLimit(1)
                        Text(meta).font(PW.font(12.5)).foregroundStyle(PW.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(pingText).font(PW.font(12.5)).tabular().foregroundStyle(PW.textSecondary)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(PressStyle(scale: 0.98))
            .accessibilityHint(item.isUp ? "" : L.tr("a11y_connect", item.name))

            // A plain button pushing onto the stack's path: a NavigationLink inside a List draws
            // its own disclosure arrow as well, which doubled the chevron and squeezed the row.
            Button { if app.path.last != item.name { app.path.append(item.name) } } label: {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PW.iconMuted)
                    .frame(width: 32, height: 44)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(L.tr("a11y_open_details"))
        }
        .padding(.vertical, 15)
        .overlay(alignment: .top) { Rectangle().fill(PW.rule).frame(height: 1) }
    }

    private var pingText: String {
        switch ping {
        case .ms(let ms): return L.tr("ping_ms", ms)
        case .failed: return L.tr("ping_none")
        default: return ""
        }
    }
}

/// A probe in flight: the dot flashes until it answers or gives up.
private struct ProbingDot: View {
    @State private var on = false
    var body: some View {
        Dot(color: PW.muted)
            .opacity(on ? 1 : 0.2)
            .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { on = true } }
    }
}

// MARK: - Add

struct AddConfigSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var picking = false
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(PW.stroke).frame(width: 36, height: 4).frame(maxWidth: .infinity).padding(.top, 8)
            Text(L.tr("add_tunnel_sheet_title"))
                .font(PW.font(19, .medium)).foregroundStyle(PW.text)
                .padding(.top, 18).padding(.bottom, 10)
            option("qrcode.viewfinder", L.tr("create_from_qr_code")) { scanning = true }
            option("doc", L.tr("create_from_file")) { picking = true }
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in
                    dismiss()
                    app.importText(text)
                }
            }
            .buttonBorderShape(.roundedRectangle(radius: PW.radius))
            .tint(PW.accent800)
            .padding(.vertical, 8)
            option("square.and.pencil", L.tr("create_empty")) { creating = true }
            Spacer()
        }
        .padding(.horizontal, PW.gutter)
        .background(PW.ground.ignoresSafeArea())
        .presentationDetents([.height(360)])
        .presentationBackground(PW.ground)
        .fullScreenCover(isPresented: $scanning) {
            ScannerView { text in
                scanning = false
                dismiss()
                app.importText(text)
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                dismiss()
                app.importFile(url)
            }
        }
        .sheet(isPresented: $creating) { EditorView(item: nil) }
    }

    private func option(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                IconTile(systemName: icon)
                Text(title).font(PW.font(15, .medium)).foregroundStyle(PW.text)
                Spacer()
            }
            .frame(minHeight: 52)
            .overlay(alignment: .bottom) { Rectangle().fill(PW.rule).frame(height: 1) }
        }
        .buttonStyle(PressStyle(scale: 0.98))
    }
}
