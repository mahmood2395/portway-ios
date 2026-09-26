// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Turning something a user was sent into configs, decided by CONTENT, never by file name.
//
// Upstream refused anything not literally named *.conf or *.zip, so configs pasted into chat
// apps and saved as .txt would not import. A zip is recognised by its magic bytes; anything else
// must be UTF-8 text containing [Interface] that the parser accepts. Inside a zip, entries that do
// not look like a config (a README) are skipped silently; entries that do but fail to parse are
// reported.

import Foundation
import PortwayCore
import WireGuardKit

/// Handed from the importer to the confirmation screen on the main actor; never shared across
/// threads, which is why the non-Sendable TunnelConfiguration inside it is acceptable.
public struct ImportCandidate: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public var suggestedName: String
    public var configText: String
    public var configuration: TunnelConfiguration

    public var summary: ConfigSummary { configuration.summary }
}

public enum ImportError: Error, Sendable {
    case tooLarge
    case notAConfig
    case invalid(String)
    case link(DeepLink.Failure)
}

public enum ConfigImporter {
    static let maxFileBytes = 4 * 1024 * 1024

    public static func candidates(fromFile data: Data, fileName: String) -> Result<[ImportCandidate], ImportError> {
        guard data.count <= maxFileBytes else { return .failure(.tooLarge) }
        if Zip.looksLikeZip(data) {
            guard let entries = Zip.read(data) else { return .failure(.notAConfig) }
            var found: [ImportCandidate] = []
            var lastError: ImportError?
            for entry in entries {
                guard let text = String(data: entry.data, encoding: .utf8),
                      text.range(of: "[Interface]", options: .caseInsensitive) != nil else { continue }
                switch candidate(text: text, name: baseName(entry.name)) {
                case .success(let c): found.append(c)
                case .failure(let e): lastError = e
                }
            }
            if found.isEmpty { return .failure(lastError ?? .notAConfig) }
            return .success(found)
        }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.notAConfig) }
        return candidate(text: text, name: baseName(fileName)).map { [$0] }
    }

    public static func candidate(fromLink url: URL) -> Result<ImportCandidate, ImportError> {
        switch DeepLink.parse(url) {
        case .failure(let reason):
            log("Import", "link rejected: \(reason.rawValue)")
            return .failure(.link(reason))
        case .success(let payload):
            return candidate(text: payload.configText, name: payload.suggestedName)
        }
    }

    /// QR codes and pasted text.
    public static func candidate(text: String, name: String?) -> Result<ImportCandidate, ImportError> {
        guard text.range(of: "[Interface]", options: .caseInsensitive) != nil else { return .failure(.notAConfig) }
        do {
            let config = try TunnelConfiguration(fromWgQuickConfig: text, called: nil)
            let suggested = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "config"
            config.name = suggested
            return .success(ImportCandidate(suggestedName: suggested, configText: text, configuration: config))
        } catch {
            log("Import", "parse failed: \(String(describing: error).prefix(60))")
            return .failure(.invalid(describe(error)))
        }
    }

    /// Any extension is stripped to form the name; it decides nothing else.
    static func baseName(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        let stem = (last as NSString).deletingPathExtension
        return stem.isEmpty ? last : stem
    }

    /// A unique name among `existing`: "name", then "name 2", "name 3" …
    public static func uniqueName(_ wanted: String, existing: Set<String>) -> String {
        let base = String(wanted.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)).nilIfEmpty ?? "config"
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    public static func describe(_ error: Error) -> String {
        guard let e = error as? TunnelConfiguration.ParseError else { return L.tr("not_a_config_error") }
        switch e {
        case .invalidLine(let line): return L.tr("parse_error_line", String(line.prefix(40)))
        case .noInterface: return L.tr("bad_config_reason_missing_section") + ": [Interface]"
        case .interfaceHasNoPrivateKey: return L.tr("bad_config_reason_missing_attribute") + ": PrivateKey"
        case .interfaceHasInvalidPrivateKey: return L.tr("private_key") + ": " + L.tr("bad_config_reason_invalid_key")
        case .peerHasInvalidPublicKey, .peerHasNoPublicKey: return L.tr("public_key") + ": " + L.tr("bad_config_reason_invalid_key")
        case .interfaceHasInvalidAddress(let v): return L.tr("addresses") + ": \(v)"
        case .interfaceHasInvalidDNS(let v): return L.tr("dns_servers") + ": \(v)"
        case .peerHasInvalidEndpoint(let v): return L.tr("endpoint") + ": \(v)"
        case .peerHasInvalidAllowedIP(let v): return L.tr("allowed_ips") + ": \(v)"
        default: return L.tr("bad_config_reason_invalid_value")
        }
    }
}
