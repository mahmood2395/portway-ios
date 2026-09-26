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
//
// The token form (proposed to the panel, see PANEL.md → "One-tap import") keeps the key out of
// the link entirely and is an https URL, which chat apps make tappable where a custom scheme is not:
//
//     https://<link host>/i/<token>              (Universal Link: opens the app directly)
//     portway://import?t=<token>&h=<link host>   (the page's "Open in Portway" button)
//
// The app redeems the token over HTTPS for the config text. Only that POST consumes it; a chat
// app's link preview fetching the page does not.

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

    public struct Token: Sendable, Equatable {
        public var token: String
        /// Where to redeem it: the host that issued the link.
        public var host: String
    }

    /// A token link in either form, or nil if `url` is not one.
    public static func token(in url: URL, scheme: String = PortwayEnvironment.importScheme) -> Token? {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch url.scheme?.lowercased() {
        case scheme.lowercased():
            guard url.host?.lowercased() == "import",
                  let t = parts?.queryItems?.first(where: { $0.name == "t" })?.value,
                  let h = parts?.queryItems?.first(where: { $0.name == "h" })?.value else { return nil }
            return validated(t, h)
        case "https":
            let path = url.pathComponents   // ["/", "i", "<token>"]
            guard path.count == 3, path[1] == "i", let host = url.host else { return nil }
            return validated(path[2], host)
        default:
            return nil
        }
    }

    private static func validated(_ token: String, _ host: String) -> Token? {
        let tokenOK = (16...128).contains(token.count)
            && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        // A bare host name: no scheme, port, path or credentials can be smuggled in.
        let hostOK = (1...253).contains(host.count)
            && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
            && !host.hasPrefix(".") && !host.hasSuffix(".") && host.contains(".")
        return tokenOK && hostOK ? Token(token: token, host: host.lowercased()) : nil
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
