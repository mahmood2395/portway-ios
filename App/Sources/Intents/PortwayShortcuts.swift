// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Donates Connect / Disconnect / Status to Siri and the Shortcuts app.
//
// Only the containing app declares an AppShortcutsProvider — an extension's intents already work
// standalone from Spotlight and the Shortcuts editor without one (see Shared/Intents); this is
// what additionally lets a user just SAY "Hey Siri, connect Portway" without having built a
// Shortcut first.
//
// Phrases are plain English string literals carrying the special `\(.applicationName)`
// interpolation App Intents recognises at build time (Xcode's "Extract App Intents Metadata"
// phase lifts them into an auto-generated, separately localizable strings table). They cannot be
// routed through PortwayCore's own `L.tr`, which only resolves at runtime and would not survive
// that compile-time extraction.

import AppIntents

struct PortwayShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .teal }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectIntent(),
            phrases: [
                "Connect \(.applicationName)",
                "Turn on \(.applicationName) VPN",
                "Turn on \(.applicationName)",
            ],
            shortTitle: "Connect",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: DisconnectIntent(),
            phrases: [
                "Disconnect \(.applicationName)",
                "Turn off \(.applicationName) VPN",
                "Turn off \(.applicationName)",
            ],
            shortTitle: "Disconnect",
            systemImageName: "bolt.slash"
        )
        AppShortcut(
            intent: GetVPNStatusIntent(),
            phrases: [
                "\(.applicationName) status",
                "Is \(.applicationName) connected",
                "Check \(.applicationName)",
            ],
            shortTitle: "Status",
            systemImageName: "checkmark.shield"
        )
    }
}
