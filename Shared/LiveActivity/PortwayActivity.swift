// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// The Live Activity's data contract, and the app-side control surface for it.
//
// Only the containing app starts, updates and ends an Activity; the widget extension merely
// renders whatever content the system hands it (see Widgets/PortwayWidgetsBundle.swift's
// ActivityConfiguration). Both sides need the same ActivityAttributes type, which is why it lives
// in Shared/ rather than in the app or the widget extension alone.
//
// The whole file is guarded by `canImport(ActivityKit)` rather than each declaration separately:
// ActivityKit ships on every iOS 16.1+ device this app targets, but the guard keeps this file
// harmless to compile into any future non-Apple-UI target that picks up Shared/ without pulling
// the framework in.

#if canImport(ActivityKit)
import ActivityKit
import Foundation
import PortwayCore

/// What the Dynamic Island and Lock Screen presentation need to know about a session.
///
/// `tunnelName` is the "static" half ActivityKit fixes for the activity's whole lifetime; the
/// three fields in `ContentState` are what `update(_:)` is for.
public struct PortwayActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        /// When this session came up. Nil while connecting — the Dynamic Island shows a plain
        /// glyph rather than a timer counting from "now" and lying about how long it has been up.
        public var connectedSince: Date?
        /// "Frankfurt, DE" — from the panel, when it has said. Never invented.
        public var place: String?
        /// False once the watchdog has judged the link silent; drives "Not reaching the server".
        public var reaching: Bool

        public init(connectedSince: Date?, place: String?, reaching: Bool) {
            self.connectedSince = connectedSince
            self.place = place
            self.reaching = reaching
        }
    }

    public var tunnelName: String

    public init(tunnelName: String) {
        self.tunnelName = tunnelName
    }
}

/// The app's only door into this Live Activity. Everything here runs on the main actor because
/// ActivityKit's own `Activity` type is main-actor-isolated.
@MainActor
public enum LiveActivityController {
    private static var current: Activity<PortwayActivityAttributes>?

    /// An activity nobody refreshes greys out after this: if the app is not around to end it (the
    /// tunnel stopped from Settings, the app killed), it must not keep claiming "Protected".
    private static let staleAfter: TimeInterval = 15 * 60
    private static var staleDate: Date { Date().addingTimeInterval(staleAfter) }

    public static var isRunning: Bool { !Activity<PortwayActivityAttributes>.activities.isEmpty }

    /// Starts a new activity for `tunnelName`, first ending anything already running — a process
    /// killed mid-session can leave one behind, and the Dynamic Island must never show two.
    public static func start(tunnelName: String, connectedSince: Date?, place: String?) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        await end()
        let attributes = PortwayActivityAttributes(tunnelName: tunnelName)
        let state = PortwayActivityAttributes.ContentState(connectedSince: connectedSince, place: place, reaching: true)
        do {
            current = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate))
        } catch {
            log("LiveActivity", "start failed: \(error)")
        }
    }

    /// Updates the running activity, if there is one. Silently a no-op otherwise — a snapshot
    /// tick arriving after the user has disconnected (and the activity already ended) is normal.
    public static func update(connectedSince: Date?, place: String?, reaching: Bool) async {
        guard let activity = current ?? Activity<PortwayActivityAttributes>.activities.first else { return }
        current = activity
        let state = PortwayActivityAttributes.ContentState(connectedSince: connectedSince, place: place, reaching: reaching)
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    /// Ends every Portway activity this process can see — normally one, but a stale one from a
    /// killed process is cleaned up the same way.
    public static func end() async {
        for activity in Activity<PortwayActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        current = nil
    }
}
#endif
