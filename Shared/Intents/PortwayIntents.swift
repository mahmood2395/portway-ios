// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// App Intents: Shortcuts, Siri, the widgets' button and the iOS 18 Control Center toggle all
// drive the VPN through these four actions rather than through NetworkExtension directly, so a
// headless connect always goes through the same `SessionGate` every other non-UI entry point
// uses (see VPNControl.swift) — a Shortcut and a widget tap must not fight the app's own claim.
//
// `openAppWhenRun = false` everywhere: a Shortcut, a widget tap or a voice command that had to
// foreground the app first would defeat the point of running it from the lock screen or from the
// Shortcuts app in the background.
//
// Titles are compile-time keys into Shared/Localization/*/Intents.strings, not L.tr lookups: Xcode
// extracts App Intents metadata at build time and rejects anything it cannot read statically.
// Those tables are generated with everything else by tools/import_android_strings.py.
//
// This file lives in Shared/ and is compiled into BOTH the app and the widget extension (see
// project.yml), which is what lets the widget's own Button(intent:) and the iOS 18 control run
// the exact same intent the app donates to Siri.

import AppIntents
import NetworkExtension
import PortwayCore

struct ConnectIntent: AppIntent {
    static let title = LocalizedStringResource("intent_connect_title", table: "Intents")
    static let description = IntentDescription(LocalizedStringResource("intent_connect_description", table: "Intents"))
    static var openAppWhenRun = false

    /// Left unset, `VPNControl.connect` picks the same default Home does: whatever is up, else
    /// the last used, else the first configuration.
    @Parameter(title: LocalizedStringResource("intent_param_config", table: "Intents"))
    var configName: String?

    func perform() async throws -> some IntentResult {
        try await VPNControl.connect(named: configName, gate: .headless)
        return .result()
    }
}

/// A LiveActivityIntent runs in the app's process even when tapped on the Lock Screen or in the
/// Dynamic Island, which is what lets it end the activity it was tapped on: the widget extension
/// cannot, and an activity left running would keep saying "Protected" over a dead tunnel.
struct DisconnectIntent: LiveActivityIntent {
    static let title = LocalizedStringResource("intent_disconnect_title", table: "Intents")
    static let description = IntentDescription(LocalizedStringResource("intent_disconnect_description", table: "Intents"))
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await VPNControl.disconnect()
        #if canImport(ActivityKit)
        await LiveActivityController.end()
        #endif
        return .result()
    }
}

struct ToggleVPNIntent: AppIntent {
    static let title = LocalizedStringResource("intent_toggle_title", table: "Intents")
    static let description = IntentDescription(LocalizedStringResource("intent_toggle_description", table: "Intents"))
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try await VPNControl.toggle()
        return .result()
    }
}

/// "Connected · Frankfurt" / "Connected · Frankfurt (not reaching the server)" / "Not connected".
/// The same three-way judgement the widgets' kicker draws, so Siri, Shortcuts and the tile never
/// disagree about what "connected" means for a tunnel that is up but silent.
struct GetVPNStatusIntent: AppIntent {
    static let title = LocalizedStringResource("intent_status_title", table: "Intents")
    static let description = IntentDescription(LocalizedStringResource("intent_status_description", table: "Intents"))
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: await Self.summary())
    }

    static func summary(now: Date = Date()) async -> String {
        guard let managers = try? await VPNControl.managers(),
              let active = managers.first(where: { $0.connection.status == .connected }) else {
            return L.tr("tunnel_status_inactive")
        }
        let name = active.localizedDescription ?? L.tr("tunnel_status_active")
        if let snapshot = TunnelSnapshot.loadPersisted(), snapshot.tunnelName == name, snapshot.link(now: now).isSilent {
            return L.tr("intent_status_connected_silent", name)
        }
        return L.tr("intent_status_connected", name)
    }
}
