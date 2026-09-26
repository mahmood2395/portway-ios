// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// "<name> is ready". Every import path — link, QR, file, paste — lands here, and nothing is written
// until the user saves: a link can never silently install a tunnel.
//
// The first save is also when iOS asks "Allow Portway to add VPN configurations?", so the screen
// says so before the button is pressed. The system dialog cannot be skipped or faked.

import SwiftUI
import PortwayCore
import PortwayKit

struct ImportConfirmView: View {
    let candidates: [ImportCandidate]
    @Environment(AppState.self) private var app
    @Environment(TunnelStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var index = 0
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(candidates: [ImportCandidate]) {
        self.candidates = candidates
        _name = State(initialValue: candidates.first?.suggestedName ?? "")
    }

    private var candidate: ImportCandidate? { candidates.indices.contains(index) ? candidates[index] : nil }

    var body: some View {
        ScrollView {
            if let candidate {
                content(candidate.summary)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PW.ground.ignoresSafeArea())
        .presentationBackground(PW.ground)
        .interactiveDismissDisabled(saving)
    }

    private func content(_ summary: ConfigSummary) -> some View {
        let place = summary.endpointHost.flatMap { host in
            AccountStore.panelPlace(for: host).flatMap { L.place(city: $0.city, country: $0.country) } ?? GeoLookup.cached(host: host)
        }
        let peers = summary.peerCount == 1 ? L.tr("confirm_peers_one") : L.tr("confirm_peers_other", summary.peerCount)
        let subtitle: String = switch (summary.routesAll, place) {
        case (true, let p?): L.tr("confirm_subtitle_all_geo", peers, p.isolated)
        case (false, let p?): L.tr("confirm_subtitle_split_geo", peers, p.isolated)
        case (true, nil): L.tr("confirm_subtitle_all", peers)
        case (false, nil): L.tr("confirm_subtitle_split", peers)
        }

        return VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(PW.stroke).frame(width: 36, height: 4).frame(maxWidth: .infinity).padding(.top, 8)

            IconTile(systemName: "checkmark", size: 38).padding(.top, 28)

            Text(L.tr("confirm_ready", (name.isEmpty ? summary.name : name).isolated))
                .font(PW.font(32, .medium, relativeTo: .largeTitle))
                .tracking(PW.tracking(-0.03, size: 32))
                .foregroundStyle(PW.text)
                .padding(.top, 18)

            Text(subtitle)
                .font(PW.font(14.5))
                .lineSpacing(5)
                .foregroundStyle(PW.textSecondary)
                .padding(.top, 10)

            TextField("", text: $name, prompt: Text(L.tr("name")).foregroundStyle(PW.muted))
                .font(PW.font(15))
                .foregroundStyle(PW.text)
                .focused($nameFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .card(edge: nameFocused ? PW.accent : PW.stroke)
                .padding(.top, 22)

            VStack(spacing: 0) {
                row(L.tr("endpoint"), summary.endpointDisplay ?? "—")
                row(L.tr("confirm_routes"), summary.routesAll ? L.tr("confirm_routes_all") : L.tr("confirm_routes_some", summary.routeCount))
                row(L.tr("dns_servers"), summary.dns.isEmpty ? "—" : summary.dns.joined(separator: ", "))
                if candidates.count > 1 {
                    row(L.tr("import_batch"), L.tr("import_batch_value", index + 1, candidates.count), last: true)
                }
            }
            .padding(.horizontal, 14)
            .card()
            .padding(.top, 14)

            if store.items.isEmpty {
                Text(L.tr("confirm_system_prompt_note"))
                    .font(PW.font(12.5))
                    .foregroundStyle(PW.muted)
                    .padding(.top, 14)
            }
            if let error {
                Text(error).font(PW.font(12.5)).foregroundStyle(PW.error).padding(.top, 10)
            }

            Button {
                Task { await save(connect: true) }
            } label: {
                if saving { ProgressView().tint(PW.accent300) } else { Text(L.tr("confirm_save_connect")) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.top, 24)

            Button(L.tr("confirm_save")) { Task { await save(connect: false) } }
                .buttonStyle(GhostButtonStyle(color: PW.accent300))
                .disabled(saving)
            Button(L.tr("confirm_not_now")) { next() }
                .buttonStyle(GhostButtonStyle())
                .disabled(saving)
        }
        .padding(.horizontal, PW.gutter)
        .padding(.bottom, 24)
    }

    private func row(_ label: String, _ value: String, last: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(PW.font(13)).foregroundStyle(PW.muted)
            Spacer(minLength: 12)
            // Raw values keep Latin digits and their own direction: the user compares them against
            // the .conf file.
            Text(value).font(PW.font(13)).foregroundStyle(PW.text).multilineTextAlignment(.trailing)
                .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(PW.rule).frame(height: 1) } }
    }

    private func save(connect: Bool) async {
        guard let candidate else { return }
        saving = true
        error = nil
        do {
            let item = try await store.add(candidate, name: name)
            if connect { await store.connect(item) }
            next()
            if connect {
                app.path = []
                app.tab = .home
            }
        } catch {
            self.error = TunnelStore.describe(error)
        }
        saving = false
    }

    private func next() {
        if index + 1 < candidates.count {
            index += 1
            name = candidates[index].suggestedName
        } else {
            dismiss()
            app.pendingImport = nil
        }
    }
}
