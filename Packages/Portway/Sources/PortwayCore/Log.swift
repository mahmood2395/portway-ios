// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Logging that support can actually get hold of.
//
// os.Logger alone is invisible to a user: reading it needs a Mac and Console. So every line also
// lands in a small file in the app group — one file per process, because the app and the tunnel
// extension write concurrently and appending to one file from two processes interleaves torn
// lines. The in-app log viewer merges them by timestamp.
//
// Never log a config, a key or a full import URL. Hosts and reasons only.

import Foundation
import os

public enum LogSource: String, CaseIterable, Sendable {
    case app, tunnel, widgets
}

public final class PortwayLog: @unchecked Sendable {
    public static let shared = PortwayLog()

    /// Keep each file under this; on overflow the older half is dropped.
    private static let maxBytes = 256 * 1024

    private let queue = DispatchQueue(label: "app.portway.log")
    private let source: LogSource
    private let formatter: ISO8601DateFormatter

    private init() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if id.hasSuffix(".tunnel") { source = .tunnel }
        else if id.hasSuffix(".widgets") { source = .widgets }
        else { source = .app }
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public static func fileURL(for source: LogSource) -> URL {
        PortwayEnvironment.containerURL.appendingPathComponent("log-\(source.rawValue).txt")
    }

    public func write(_ tag: String, _ message: String, level: OSLogType = .default) {
        Logger(subsystem: "app.portway", category: tag).log(level: level, "\(message, privacy: .public)")
        let line = "\(formatter.string(from: Date())) [\(source.rawValue)] \(tag): \(message)\n"
        queue.async { [source] in
            let url = Self.fileURL(for: source)
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                if size > UInt64(Self.maxBytes) {
                    try? handle.close()
                    Self.truncateHalf(url)
                    if let h = try? FileHandle(forWritingTo: url) {
                        _ = try? h.seekToEnd()
                        try? h.write(contentsOf: data)
                        try? h.close()
                    }
                    return
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func truncateHalf(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(data.count / 2)
        // Start on a whole line.
        if let newline = tail.firstIndex(of: 0x0A) { tail = tail[(newline + 1)...] }
        try? Data(tail).write(to: url, options: .atomic)
    }

    /// Every process's log, merged into one timeline, for the viewer and for sharing.
    public static func merged() -> String {
        let lines = LogSource.allCases.flatMap { source -> [Substring] in
            guard let text = try? String(contentsOf: fileURL(for: source), encoding: .utf8) else { return [] }
            return text.split(separator: "\n", omittingEmptySubsequences: true)
        }
        // ISO-8601 with a fixed format sorts lexically.
        return lines.sorted().joined(separator: "\n")
    }

    public static func clear() {
        for source in LogSource.allCases { try? FileManager.default.removeItem(at: fileURL(for: source)) }
    }
}

/// `log("Watchdog", "restarting …")`
public func log(_ tag: String, _ message: String) {
    PortwayLog.shared.write(tag, message)
}
