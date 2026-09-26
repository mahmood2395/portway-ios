// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Settings, grouped Protection / Advanced / App, rows separated by 1pt rules with no icon column.
//
// Protection is where iOS beats Android: the kill switch and always-on are real in-app switches
// here (includeAllNetworks and Connect On Demand), where Android could only open system settings
// and could not even read whether they were on.

import LocalAuthentication
import SwiftUI
import PortwayCore
import PortwayKit

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(TunnelStore.self) private var store
    @State private var settings = SettingsModel()
    @State private var editingPanel = false
    @State private var editingTrusted = false
    @State private var exportURL: URL?
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: L.tr("settings"))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let account = store.account(for: store.current) {
                        AccountCard(account: account).padding(.top, 8)
                    }

                    category(L.tr("settings_category_protection"))
                    toggle(L.tr("kill_switch_title"), L.tr("kill_switch_summary"), $settings.killSwitch)
                    if settings.killSwitch {
                        toggle(L.tr("local_network_title"), L.tr("local_network_summary"), $settings.excludeLocalNetworks)
                    }
                    toggle(L.tr("always_on_title"), L.tr("always_on_summary"), $settings.alwaysOn)
                    if settings.alwaysOn {
                        valueRow(L.tr("trusted_wifi_title"), L.tr("trusted_wifi_summary"),
                                 settings.trustedSSIDs.isEmpty ? L.tr("none") : L.number(settings.trustedSSIDs.count)) { editingTrusted = true }
                    }
                    toggle(L.tr("auto_reconnect_title"), L.tr("auto_reconnect_summary"), $settings.autoReconnect)

                    category(L.tr("settings_category_advanced"))
                    valueRow(L.tr("panel_url_title"), L.tr("panel_url_summary_ios"),
                             settings.panelOverride == nil ? (PortwayEnvironment.builtInPanelURL == nil ? L.tr("not_set") : L.tr("panel_built_in")) : L.tr("panel_custom")) {
                        editingPanel = true
                    }
                    valueRow(L.tr("zip_export_title"), L.tr("zip_export_summary_ios"), nil) { Task { await export() } }

                    category(L.tr("settings_category_app"))
                    toggle(L.tr("app_lock_title"), L.tr("app_lock_summary"), $settings.appLock)
                    picker(L.tr("language_title"), selection: Binding(get: { PortwaySettings.shared.language }, set: { app.setLanguage($0) }),
                           options: [(.system, L.tr("language_follow_system")), (.en, "English"), (.fa, "فارسی")])
                    picker(L.tr("theme_mode_title"), selection: Binding(get: { PortwaySettings.shared.themeMode }, set: { app.setTheme($0) }),
                           options: [(.dark, L.tr("theme_mode_dark")), (.light, L.tr("theme_mode_light")), (.system, L.tr("theme_mode_system"))])
                    valueRow(L.tr("log_viewer_pref_title"), L.tr("log_viewer_pref_summary_ios"), nil) { showLog = true }

                    Rectangle().fill(PW.rule).frame(height: 1).padding(.top, 26)
                    Text(L.tr("settings_footer", PortwayEnvironment.marketingVersion, String(PortwayEnvironment.buildNumber)))
                        .font(PW.font(12.5)).lineSpacing(5).foregroundStyle(PW.muted)
                        .padding(.top, 14)
                }
                .padding(.horizontal, PW.gutter)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .onChange(of: settings.protectionRevision) { Task { await store.applyProtection() } }
        .sheet(isPresented: $editingPanel) { PanelURLSheet(settings: settings) }
        .sheet(isPresented: $editingTrusted) { TrustedWiFiSheet(settings: settings) }
        .sheet(isPresented: $showLog) { LogView() }
        .sheet(item: $exportURL) { url in ShareSheet(items: [url]) }
    }

    // MARK: Rows

    private func category(_ title: String) -> some View {
        Text(title).sectionLabel(PW.accent).padding(.top, 26).padding(.bottom, 4)
    }

    private func labels(_ title: String, _ summary: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(PW.font(14.5, .medium)).foregroundStyle(PW.text)
            if let summary {
                Text(summary).font(PW.font(12.5)).lineSpacing(3).foregroundStyle(PW.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ title: String, _ summary: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) { labels(title, summary) }
            .toggleStyle(PWToggleStyle())
            .padding(.vertical, 15)
            .overlay(alignment: .top) { Rectangle().fill(PW.rule).frame(height: 1) }
    }

    private func valueRow(_ title: String, _ summary: String?, _ value: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                labels(title, summary)
                if let value { Text(value).font(PW.font(13)).foregroundStyle(PW.muted) }
                Image(systemName: "chevron.forward").font(.system(size: 12, weight: .medium)).foregroundStyle(PW.iconMuted)
            }
            .padding(.vertical, 15)
            .overlay(alignment: .top) { Rectangle().fill(PW.rule).frame(height: 1) }
        }
        .buttonStyle(PressStyle(scale: 0.99))
    }

    private func picker<T: Hashable>(_ title: String, selection: Binding<T>, options: [(T, String)]) -> some View {
        HStack {
            labels(title, nil)
            Menu {
                Picker(title, selection: selection) {
                    ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(options.first { $0.0 == selection.wrappedValue }?.1 ?? "")
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                }
                .font(PW.font(13)).foregroundStyle(PW.accent300)
                .frame(minHeight: 44)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(PW.rule).frame(height: 1) }
    }

    // MARK: Export (behind Face ID: the zip holds private keys)

    private func export() async {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L.tr("export_auth_reason"))) == true else { return }
        }
        exportURL = try? store.exportZip()
    }
}

// MARK: - Model

@MainActor
@Observable
final class SettingsModel {
    private let s = PortwaySettings.shared
    /// Bumped whenever something that lives on the VPN profiles changes.
    var protectionRevision = 0

    var killSwitch: Bool { didSet { s.killSwitch = killSwitch; protectionRevision += 1 } }
    var excludeLocalNetworks: Bool { didSet { s.excludeLocalNetworks = excludeLocalNetworks; protectionRevision += 1 } }
    var alwaysOn: Bool { didSet { s.alwaysOn = alwaysOn; protectionRevision += 1 } }
    var trustedSSIDs: [String] { didSet { s.trustedSSIDs = trustedSSIDs; protectionRevision += 1 } }
    var autoReconnect: Bool { didSet { s.autoReconnect = autoReconnect } }
    var appLock: Bool { didSet { s.appLock = appLock } }
    var panelOverride: String? { didSet { s.panelURLOverride = panelOverride } }

    init() {
        killSwitch = PortwaySettings.shared.killSwitch
        excludeLocalNetworks = PortwaySettings.shared.excludeLocalNetworks
        alwaysOn = PortwaySettings.shared.alwaysOn
        trustedSSIDs = PortwaySettings.shared.trustedSSIDs
        autoReconnect = PortwaySettings.shared.autoReconnect
        appLock = PortwaySettings.shared.appLock
        panelOverride = PortwaySettings.shared.panelURLOverride
    }
}

// MARK: - Sheets

private struct PanelURLSheet: View {
    @Bindable var settings: SettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.tr("panel_url_title")).font(PW.font(19, .medium)).foregroundStyle(PW.text).padding(.top, 24)
            Text(L.tr("panel_url_explain")).font(PW.font(13.5)).foregroundStyle(PW.muted)
            TextField("", text: $text, prompt: Text("https://").foregroundStyle(PW.muted))
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(PW.font(15)).foregroundStyle(PW.text)
                .padding(.horizontal, 14).frame(height: 46).card()
                .environment(\.layoutDirection, .leftToRight)
            Button(L.tr("save")) {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                // Blank means "use the built-in panel", never "no panel".
                settings.panelOverride = trimmed.isEmpty ? nil : trimmed
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!(text.isEmpty || text.hasPrefix("http://") || text.hasPrefix("https://")))
            Spacer()
        }
        .padding(.horizontal, PW.gutter)
        .background(PW.ground.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationBackground(PW.ground)
        .onAppear { text = settings.panelOverride ?? "" }
    }
}

private struct TrustedWiFiSheet: View {
    @Bindable var settings: SettingsModel
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.tr("trusted_wifi_title")).font(PW.font(19, .medium)).foregroundStyle(PW.text).padding(.top, 24)
            Text(L.tr("trusted_wifi_explain")).font(PW.font(13.5)).foregroundStyle(PW.muted)
            HStack {
                TextField("", text: $draft, prompt: Text(L.tr("trusted_wifi_placeholder")).foregroundStyle(PW.muted))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(PW.font(15)).foregroundStyle(PW.text)
                    .padding(.horizontal, 14).frame(height: 46).card()
                Button(L.tr("add")) {
                    let name = draft.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, !settings.trustedSSIDs.contains(name) { settings.trustedSSIDs.append(name) }
                    draft = ""
                }
                .buttonStyle(ChipButtonStyle())
            }
            ForEach(settings.trustedSSIDs, id: \.self) { ssid in
                HStack {
                    Text(ssid).font(PW.font(14.5)).foregroundStyle(PW.text)
                    Spacer()
                    Button { settings.trustedSSIDs.removeAll { $0 == ssid } } label: {
                        Image(systemName: "xmark").foregroundStyle(PW.muted).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(L.tr("delete"))
                }
                .overlay(alignment: .top) { Rectangle().fill(PW.rule).frame(height: 1) }
            }
            Spacer()
        }
        .padding(.horizontal, PW.gutter)
        .background(PW.ground.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationBackground(PW.ground)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // What we share from tmp (the config zip holds every private key) is deleted once the
        // sheet is done with it, whatever the user chose.
        let files = items.compactMap { $0 as? URL }.filter { $0.path.hasPrefix(FileManager.default.temporaryDirectory.path) }
        controller.completionWithItemsHandler = { _, _, _, _ in
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
