// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
//     portway://import?c=<base64url of the whole .conf>[&name=<url-encoded name>]
//
// The contract with the panel's peer page (DEEPLINK.md in the Android repo), unchanged, so one
// button serves both platforms. The link never installs anything by itself: it opens the same
// confirmation screen as a QR scan, and nothing is written until the user saves.
//
// The private key travels in the URL. Failures are logged by reason only — never the payload.

import Foundation

public enum DeepLink {
    public static let maxPayload = 64 * 1024

    public enum Failure: String, Error, Sendable {
        case notAnImportLink, missingPayload, payloadTooLarge, malformedBase64, notUTF8, notAConfig
    }

    public struct Payload: Sendable, Equatable {
        public var configText: String
        public var suggestedName: String?

        public init(configText: String, suggestedName: String?) {
            self.configText = configText
            self.suggestedName = suggestedName
        }
    }

    public static func parse(_ url: URL, scheme: String = PortwayEnvironment.importScheme) -> Result<Payload, Failure> {
        guard url.scheme?.lowercased() == scheme.lowercased(),
              url.host?.lowercased() == "import",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.notAnImportLink)
        }
        let items = components.queryItems ?? []
        guard let raw = items.first(where: { $0.name == "c" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return .failure(.missingPayload) }
        guard raw.count <= maxPayload * 4 / 3 + 4 else { return .failure(.payloadTooLarge) }

        // base64url or standard, padded or not: a page may percent-encode a standard string.
        var b64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: " ", with: "+")   // a "+" that was decoded as a space
        b64.removeAll { $0 == "\n" || $0 == "\r" || $0 == "\t" }   // line-wrapped base64
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return .failure(.malformedBase64) }
        guard data.count <= maxPayload else { return .failure(.payloadTooLarge) }
        // Strict UTF-8: a wrong payload must fail loudly rather than import mojibake as a key.
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.notUTF8) }
        guard text.range(of: "[Interface]", options: .caseInsensitive) != nil else { return .failure(.notAConfig) }

        // Form encoding writes a space as "+"; read it the way Android's getQueryParameter does.
        let name = items.first(where: { $0.name == "name" })?.value?.replacingOccurrences(of: "+", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return .success(Payload(configText: text, suggestedName: name))
    }
}
