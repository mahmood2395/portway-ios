// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Build-time facts, read from Info.plist. Every target (app, tunnel, widgets) carries the same
// keys, filled from Config/*.xcconfig, so none of them hard-codes an identifier.
//
// The panel URL in particular is NEVER in the repository. It comes from Config/Local.xcconfig,
// which is git-ignored — the same rule the Android build follows with ~/.gradle/gradle.properties.

import Foundation

public enum PortwayEnvironment {
    private static func info(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unset xcconfig variable arrives as the empty string, or as the literal "$(NAME)"
        // when the plist names a variable nothing defines.
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }

    public static let appGroupID: String = info("PortwayAppGroup") ?? "group.app.portway"

    /// The app's own bundle id, also when read from inside an extension.
    public static let appBundleID: String = {
        let own = Bundle.main.bundleIdentifier ?? "app.portway"
        for suffix in [".tunnel", ".widgets"] where own.hasSuffix(suffix) {
            return String(own.dropLast(suffix.count))
        }
        return own
    }()

    public static var tunnelBundleID: String { appBundleID + ".tunnel" }

    /// The panel the build ships with. Settings can override it; a blank override falls back here.
    public static let builtInPanelURL: String? = info("PortwayPanelURL").map { $0.trimmingTrailingSlashes }

    public static let importScheme: String = info("PortwayImportScheme") ?? "portway"

    /// Resolver pinned into a full-tunnel config that names no DNS server.
    public static let fallbackDNS: String? = info("PortwayFallbackDNS")

    /// The one-device session protocol (register/claim/heartbeat/release) and the iOS update feed.
    ///
    /// Off until the panel has agreed the iOS wire shape (platform, app_version, os_version,
    /// always_on/lockdown — see PANEL.md). The panel stores what it is sent rather than rejecting
    /// it, so a guessed shape would land in the database silently. Off is safe: the protocol is
    /// fail-open by design, so the app behaves exactly as if the panel were unreachable.
    public static var sessionProtocolEnabled: Bool {
        sessionProtocolOverride ?? (info("PortwaySessionProtocol")?.uppercased() == "YES")
    }

    /// Contract tests switch the protocol on against a mock panel. Never set in the app.
    nonisolated(unsafe) static var sessionProtocolOverride: Bool?

    public static let marketingVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    public static let buildNumber: Int =
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    public static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? FileManager.default.temporaryDirectory
    }
}

extension String {
    var trimmingTrailingSlashes: String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Wraps a value in First-Strong Isolates so a Latin host or name inside a Persian sentence
    /// does not reorder the words around it. Harmless in LTR text.
    public var isolated: String { "\u{2068}\(self)\u{2069}" }
}
