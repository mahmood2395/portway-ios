// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Exchanges a one-tap import token for the config it stands for.
//
//     POST https://<host>/api/import/redeem   {"token": "…"}
//       200 {"conf": "<wg-quick text>", "name": "beta-frankfurt"}
//       410 used or expired · 404 unknown
//
// HTTPS only, to the host that issued the link. The token is single-use, so this is called once,
// when the link is opened, never on a retry loop.

import Foundation

public enum ImportRedeemer {
    public enum Failure: Error, Sendable, Equatable {
        /// Already used, or expired: ask the provider for a new link.
        case expired
        case unknown
        /// No answer, or not one we understood.
        case unavailable
    }

    /// Contract tests point this at a local mock panel. Never changed in the app.
    nonisolated(unsafe) static var testBase: String?

    public static func redeem(_ token: DeepLink.Token) async -> Result<DeepLink.Payload, Failure> {
        guard let url = URL(string: (testBase ?? "https://\(token.host)") + "/api/import/redeem") else { return .failure(.unknown) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token.token, "platform": DeviceInfo.platform])
        guard let response = await PanelHTTP.send(request, ceiling: 12) else {
            log("Import", "redeem: no answer from the link host")
            return .failure(.unavailable)
        }
        switch response.status {
        case 200:
            guard let conf = response.json?.string("conf"), conf.utf8.count <= DeepLink.maxPayload,
                  conf.range(of: "[Interface]", options: .caseInsensitive) != nil else {
                log("Import", "redeem: 200 without a config")
                return .failure(.unavailable)
            }
            return .success(DeepLink.Payload(configText: conf, suggestedName: response.json?.string("name")))
        case 410:
            return .failure(.expired)
        case 404:
            return .failure(.unknown)
        default:
            log("Import", "redeem: HTTP \(response.status)")
            return .failure(.unavailable)
        }
    }
}
