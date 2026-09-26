// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Preferences shared by the app, the tunnel extension and the widgets, in the app group's
// UserDefaults. The extension reads auto-reconnect and the panel URL on every pass, so these must
// not live in the app's private defaults.

import Foundation

public enum ThemeMode: String, CaseIterable, Sendable {
    case dark, light, system
}

public enum AppLanguage: String, CaseIterable, Sendable {
    case system, en, fa
}

public final class PortwaySettings: @unchecked Sendable {
    public static let shared = PortwaySettings()

    private var d: UserDefaults { PortwayEnvironment.defaults }

    private enum Key {
        static let panelURL = "panel_url"
        static let autoReconnect = "auto_reconnect"
        static let killSwitch = "kill_switch"
        static let alwaysOn = "always_on"
        static let trustedSSIDs = "trusted_ssids"
        static let appLock = "app_lock"
        static let themeMode = "theme_mode"
        static let language = "app_language"
        static let onboardingDone = "onboarding_done"
        static let lastUsedTunnel = "last_used_tunnel"
        static let deviceID = "device_id"
        static let excludeLocalNetworks = "exclude_local_networks"
        static let pausedProfiles = "on_demand_paused"
        static let onDemandLive = "on_demand_live"
    }

    /// Profiles whose Connect On Demand the user paused by switching the VPN off. Only an explicit
    /// connect un-pauses; any other save (a setting, an edit) must leave them off, or iOS brings the
    /// tunnel straight back seconds after the user said "off".
    /// One key per profile (SharedMap): the app, a widget and a Shortcut can all write here.
    public func isPaused(_ profile: String) -> Bool {
        SharedMap<Bool>(Key.pausedProfiles)[profile] ?? false
    }

    public func setPaused(_ profile: String, _ paused: Bool) {
        if paused { SharedMap<Bool>(Key.pausedProfiles)[profile] = true } else { SharedMap<Bool>(Key.pausedProfiles).remove(profile) }
    }

    /// The real `isOnDemandEnabled` of each profile, written by the app on every save. The extension
    /// cannot load profiles, and the user can flip on-demand per profile in iOS Settings, so the app
    /// setting alone is not the truth.
    public func onDemandLive(_ profile: String) -> Bool {
        SharedMap<Bool>(Key.onDemandLive)[profile] ?? false
    }

    public func setOnDemandLive(_ profile: String, _ on: Bool) {
        SharedMap<Bool>(Key.onDemandLive)[profile] = on
    }

    /// The stored override, if any. Blank means "not set", never "disabled".
    public var panelURLOverride: String? {
        get { d.string(forKey: Key.panelURL)?.trimmingCharacters(in: .whitespaces).nilIfEmpty }
        set { d.set(newValue?.trimmingCharacters(in: .whitespaces).trimmingTrailingSlashes.nilIfEmpty, forKey: Key.panelURL) }
    }

    /// Where panel calls go: the override, else the built-in URL. Clearing the override falls back
    /// to the built-in panel — an empty field used to disable the panel on Android, which cut
    /// users off from account info and the update feed without telling them.
    public var panelURL: String? {
        panelURLOverride ?? PortwayEnvironment.builtInPanelURL
    }

    /// Restart a tunnel that is up but not handshaking. Judging continues when this is off; only
    /// the restart is the setting's to refuse.
    public var autoReconnect: Bool {
        get { d.object(forKey: Key.autoReconnect) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.autoReconnect) }
    }

    /// `includeAllNetworks`: nothing leaves the device outside the tunnel, including while it is
    /// reconnecting. A real in-app kill switch, which Android can only point at system settings for.
    public var killSwitch: Bool {
        get { d.bool(forKey: Key.killSwitch) }
        set { d.set(newValue, forKey: Key.killSwitch) }
    }

    /// With the kill switch on, still let AirDrop, printers and the router's admin page through.
    public var excludeLocalNetworks: Bool {
        get { d.object(forKey: Key.excludeLocalNetworks) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.excludeLocalNetworks) }
    }

    /// Connect On Demand with an "always connect" rule: iOS brings the tunnel up after a reboot and
    /// whenever it drops. The iOS form of Android's always-on + restore-on-boot.
    public var alwaysOn: Bool {
        get { d.bool(forKey: Key.alwaysOn) }
        set { d.set(newValue, forKey: Key.alwaysOn) }
    }

    /// Wi-Fi networks on which Always-on stands down (home, office).
    public var trustedSSIDs: [String] {
        get { d.stringArray(forKey: Key.trustedSSIDs) ?? [] }
        set { d.set(newValue, forKey: Key.trustedSSIDs) }
    }

    public var appLock: Bool {
        get { d.bool(forKey: Key.appLock) }
        set { d.set(newValue, forKey: Key.appLock) }
    }

    /// Dark is the designed-for theme and the written default, not an inferred one.
    public var themeMode: ThemeMode {
        get { ThemeMode(rawValue: d.string(forKey: Key.themeMode) ?? "") ?? .dark }
        set { d.set(newValue.rawValue, forKey: Key.themeMode) }
    }

    public var language: AppLanguage {
        get { AppLanguage(rawValue: d.string(forKey: Key.language) ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: Key.language) }
    }

    public var onboardingDone: Bool {
        get { d.bool(forKey: Key.onboardingDone) }
        set { d.set(newValue, forKey: Key.onboardingDone) }
    }

    public var lastUsedTunnel: String? {
        get { d.string(forKey: Key.lastUsedTunnel) }
        set { d.set(newValue, forKey: Key.lastUsedTunnel) }
    }

    /// A random id for this install. In the app group, so a reinstall is a new device — the same
    /// semantics as Android, deliberately: a keychain id would survive the reinstall and make the
    /// panel's fleet page disagree between platforms.
    public var deviceID: String {
        if let existing = d.string(forKey: Key.deviceID) { return existing }
        let fresh = UUID().uuidString.lowercased()
        d.set(fresh, forKey: Key.deviceID)
        return fresh
    }
}

extension String {
    public var nilIfEmpty: String? { isEmpty ? nil : self }
}
