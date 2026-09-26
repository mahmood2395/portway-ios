// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// The editor: a name and the wg-quick text, validated by the same parser that imports.
//
// A text editor rather than upstream's field-per-attribute form: the people who edit configs are
// the technical ones, and they think in the .conf file. Opening an existing config shows its
// private key, so it asks for Face ID first; creating one starts from a freshly generated key.

import LocalAuthentication
import SwiftUI
import PortwayCore
import PortwayKit
import WireGuardKit

struct EditorView: View {
    let item: TunnelStore.Item?
    var onRenamed: (String) -> Void = { _ in }
    @Environment(TunnelStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    @State private var unlocked = false
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(L.tr("cancel")) { dismiss() }.buttonStyle(GhostButtonStyle()).fixedSize()
                Spacer()
                Text(item == nil ? L.tr("create_activity_title") : L.tr("edit"))
                    .font(PW.font(16, .medium)).foregroundStyle(PW.text)
                Spacer()
                Button(L.tr("save")) { Task { await save() } }
                    .buttonStyle(GhostButtonStyle(color: PW.accent300)).fixedSize()
                    .disabled(!unlocked || saving)
            }
            .padding(.horizontal, PW.gutter)
            .frame(height: 56)

            if unlocked {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("", text: $name, prompt: Text(L.tr("name")).foregroundStyle(PW.muted))
                        .font(PW.font(15)).foregroundStyle(PW.text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(.horizontal, 14).frame(height: 46).card()
                    TextEditor(text: $text)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(PW.text)
                        .scrollContentBackground(.hidden)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .card()
                        .environment(\.layoutDirection, .leftToRight)
                    if let error {
                        Text(error).font(PW.font(12.5)).foregroundStyle(PW.error)
                    }
                }
                .padding(.horizontal, PW.gutter)
                .padding(.bottom, 16)
            } else {
                Spacer()
                Button(L.tr("editor_unlock")) { Task { await unlock() } }
                    .buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 60)
                Spacer()
            }
        }
        .background(PW.ground.ignoresSafeArea())
        .presentationBackground(PW.ground)
        .task { await prepare() }
    }

    private func prepare() async {
        if let item {
            name = item.name
            await unlock()
        } else {
            let key = PrivateKey()
            text = "[Interface]\nPrivateKey = \(key.base64Key)\nAddress = \nDNS = \n\n[Peer]\nPublicKey = \nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = \n"
            unlocked = true
        }
    }

    private func unlock() async {
        guard let item else { return }
        let context = LAContext()
        var policyError: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) {
            guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L.tr("editor_auth_reason"))) == true else { return }
        }
        text = store.configText(item) ?? ""
        unlocked = true
    }

    private func save() async {
        saving = true
        defer { saving = false }
        error = nil
        do {
            if let item {
                try await store.save(item, text: text, name: name)
                let saved = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if saved != item.name { onRenamed(saved) }
            } else {
                let candidate = try ConfigImporter.candidate(text: text, name: name).get()
                _ = try await store.add(candidate, name: name)
            }
            dismiss()
        } catch let e as ImportError {
            error = AppState.describe(e)
        } catch let e as TunnelConfiguration.ParseError {
            error = ConfigImporter.describe(e)
        } catch {
            self.error = TunnelStore.describe(error)
        }
    }
}
