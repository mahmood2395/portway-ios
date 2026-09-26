// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// "A newer Portway is available", for iOS.
//
// Android installs its own APKs; iOS cannot and does not need to — the App Store or TestFlight
// installs, and iOS stops the tunnel cleanly around an update. What survives is the part that is
// about the panel, not the installer: telling the user a build exists, and refusing to carry on
// below `min_supported_build` so a client with a broken contract can actually be retired.
//
// The feed is asked for with `platform=ios` and the answer is only believed if it says
// `"platform":"ios"`. A panel that ignores the parameter would otherwise hand back Android's
// version code (500-something) and every iOS build would read as hopelessly out of date.

import Foundation

public struct AppRelease: Sendable, Equatable {
    public var build: Int
    public var version: String
    /// App Store or TestFlight link.
    public var url: URL
    public var notes: String?
    public var minSupportedBuild: Int?

    public var isRequired: Bool { (minSupportedBuild ?? 0) > PortwayEnvironment.buildNumber }
}

public enum UpdateChecker {
    private static let lastCheckKey = "update_last_check"
    private static let throttle: TimeInterval = 6 * 3600

    public static func check(force: Bool = false) async -> AppRelease? {
        guard PortwayEnvironment.sessionProtocolEnabled, let base = PortwaySettings.shared.panelURL else { return nil }
        let d = PortwayEnvironment.defaults
        if !force, Date().timeIntervalSince1970 - d.double(forKey: lastCheckKey) < throttle {
            return cached()
        }
        guard let url = URL(string: base + "/api/app/latest?platform=ios") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let response = await PanelHTTP.send(request, ceiling: 8), response.status == 200,
              let json = response.json else {
            log("Update", "feed unavailable")
            return nil
        }
        d.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        guard json.string("platform") == "ios",
              let build = json.int64("build").map(Int.init),
              let link = json.string("url").flatMap(URL.init(string:)),
              ["https", "itms-apps", "itms-beta"].contains(link.scheme?.lowercased() ?? "") else {
            d.removeObject(forKey: "update_release")
            return nil
        }
        let release = AppRelease(build: build, version: json.string("version") ?? "\(build)", url: link,
                                 notes: json.string("notes"), minSupportedBuild: json.int64("min_supported_build").map(Int.init))
        d.set(["build": build, "version": release.version, "url": link.absoluteString,
               "notes": release.notes ?? "", "min": release.minSupportedBuild ?? 0], forKey: "update_release")
        return build > PortwayEnvironment.buildNumber ? release : nil
    }

    private static func cached() -> AppRelease? {
        guard let map = PortwayEnvironment.defaults.dictionary(forKey: "update_release"),
              let build = map["build"] as? Int, build > PortwayEnvironment.buildNumber,
              let url = (map["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return AppRelease(build: build, version: map["version"] as? String ?? "\(build)", url: url,
                          notes: (map["notes"] as? String)?.nilIfEmpty, minSupportedBuild: map["min"] as? Int)
    }
}
