// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// English and Persian — the two languages Portway is actually finished in.
//
// The strings live in this package (not the app) so the tunnel extension's notifications speak
// the user's chosen language too. The keys are the Android resource names, and the tables are
// generated from the Android strings.xml files (tools/import_android_strings.py) plus an
// iOS-only table, so the two apps say the same thing in the same words.
//
// The language is chosen in-app and applied immediately, without a relaunch: lookups go through
// the chosen .lproj rather than the process's launch language.
//
// Numerals follow the split Persian readers expect: locale digits in prose and quantities, Latin
// in raw values a user may compare against their .conf (addresses, keys, hosts, ports).

import Foundation

public enum L {
    public static var language: String {
        switch PortwaySettings.shared.language {
        case .en: return "en"
        case .fa: return "fa"
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return preferred.hasPrefix("fa") ? "fa" : "en"
        }
    }

    public static var isRTL: Bool { language == "fa" }

    public static var locale: Locale { Locale(identifier: language == "fa" ? "fa_IR" : "en_US") }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var bundles: [String: Bundle] = [:]

    private static func bundle(_ language: String) -> Bundle {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = bundles[language] { return cached }
        let found = Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.module
        bundles[language] = found
        return found
    }

    /// Looks `key` up in the chosen language, then English, then returns the key itself.
    public static func tr(_ key: String, _ args: CVarArg...) -> String {
        let lang = language
        var format = bundle(lang).localizedString(forKey: key, value: "\u{0}", table: nil)
        if format == "\u{0}" {
            format = bundle("en").localizedString(forKey: key, value: key, table: nil)
        }
        return args.isEmpty ? format : String(format: format, locale: locale, arguments: args)
    }

    // MARK: Numbers

    public static func number(_ value: Int) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func decimal(_ value: Double, fractionDigits: Int = 1) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = fractionDigits
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    /// Decimal units (1 KB = 1000 B), the unit the panel's quotas are sold in.
    public static func bytes(_ value: Int64) -> String {
        let v = Double(max(0, value))
        switch v {
        case ..<1_000: return "\(number(Int(v))) B"
        case ..<1_000_000: return "\(decimal(v / 1e3)) KB"
        case ..<1_000_000_000: return "\(decimal(v / 1e6)) MB"
        case ..<1_000_000_000_000: return "\(decimal(v / 1e9)) GB"
        default: return "\(decimal(v / 1e12)) TB"
        }
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        tr("transfer_rate", bytes(Int64(bytesPerSecond)))
    }

    /// HH:MM:SS, or MM:SS under an hour.
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let f = NumberFormatter()
        f.locale = locale
        f.minimumIntegerDigits = 2
        func two(_ n: Int) -> String { f.string(from: NSNumber(value: n)) ?? String(format: "%02d", n) }
        return s >= 3600 ? "\(two(s / 3600)):\(two(s % 3600 / 60)):\(two(s % 60))" : "\(two(s / 60)):\(two(s % 60))"
    }

    /// "12s ago" / "1m 58s ago", for the decay bar.
    public static func handshakeAge(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s < 60 ? tr("handshake_age_seconds", s) : tr("handshake_age_minutes", s / 60, s % 60)
    }

    /// "Frankfurt, DE" — never a city that was not actually resolved.
    public static func place(city: String?, country: String?) -> String? {
        switch (city, country) {
        case let (c?, cc?): return "\(c), \(cc)"
        case let (c?, nil): return c
        case let (nil, cc?): return Locale(identifier: language).localizedString(forRegionCode: cc) ?? cc
        default: return nil
        }
    }
}
