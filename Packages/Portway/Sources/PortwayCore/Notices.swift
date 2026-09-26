// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Local notifications: plan expiry, and the one-device takeover/superseded notices.
//
// Expiry is better on iOS than on Android. Android needed its own twice-daily alarm to notice a
// plan running out; here, whenever the account is fetched (by the app, or by the extension on its
// hourly refresh) the upcoming warnings are simply SCHEDULED for 10:00 on the 3-, 2-, 1- and
// 0-days-left dates. iOS delivers them whether or not Portway ever runs again, and a renewal
// clears them on the next fetch. One set per config: a single global marker once caused repeated
// or missing warnings.

import Foundation
#if canImport(UserNotifications)
import UserNotifications

public enum Notices {
    public static let takeoverCategory = "portway.takeover"
    public static let takeoverAction = "portway.takeover.use-here"
    public static let tunnelKey = "tunnel"

    static let warnAtDays = 3

    public static func registerCategories() {
        let useHere = UNNotificationAction(identifier: takeoverAction, title: L.tr("session_use_here"), options: [])
        let category = UNNotificationCategory(identifier: takeoverCategory, actions: [useHere], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Asked the first time an account actually loads, not at first launch: before there is
    /// anything to notify about the prompt is noise, and a denial is sticky.
    public static func requestPermissionIfUndecided() async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: Expiry

    public static func scheduleExpiry(for identity: PeerIdentity, account: AccountInfo, calendar: Calendar = .current) {
        let center = UNUserNotificationCenter.current()
        let prefix = "expiry.\(identity.publicKey)."
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })

            let label = (account.name ?? identity.tunnelName).isolated
            if account.disabled {
                deliverOnce(id: prefix + "suspended", marker: "\(identity.publicKey):suspended",
                            title: L.tr("expiry_suspended_title"), body: L.tr("expiry_suspended_text", label))
                return
            }
            clearMarker("\(identity.publicKey):suspended")
            guard let daysLeft = account.daysLeft else { return }
            if daysLeft > warnAtDays { clearMarkers(for: identity.publicKey); return }

            // Today, if inside the window and not already said for this count.
            if daysLeft >= 0 {
                deliverOnce(id: prefix + "now", marker: "\(identity.publicKey):\(daysLeft)",
                            title: title(daysLeft), body: body(daysLeft, label))
            }
            // The remaining counts, at 10:00 local on their dates.
            let today = calendar.startOfDay(for: Date())
            for remaining in stride(from: daysLeft - 1, through: 0, by: -1) {
                guard let day = calendar.date(byAdding: .day, value: daysLeft - remaining, to: today) else { continue }
                var components = calendar.dateComponents([.year, .month, .day], from: day)
                components.hour = 10
                let content = UNMutableNotificationContent()
                content.title = title(remaining)
                content.body = body(remaining, label)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                center.add(UNNotificationRequest(identifier: prefix + "\(remaining)", content: content, trigger: trigger))
            }
        }
    }

    private static func title(_ days: Int) -> String {
        switch days {
        case 0: return L.tr("expiry_today_title")
        case 1: return L.tr("expiry_soon_title_one")
        default: return L.tr("expiry_soon_title_other", days)
        }
    }

    private static func body(_ days: Int, _ label: String) -> String {
        days == 0 ? L.tr("expiry_today_text", label) : L.tr("expiry_soon_text", label)
    }

    // MARK: Session

    /// "Your config is in use on <device>" — with "Use here instead".
    public static func sessionConflict(tunnel: String, otherDevice: String?) {
        let content = UNMutableNotificationContent()
        content.title = L.tr("session_conflict_title")
        content.body = L.tr("session_conflict_text", tunnel.isolated, (otherDevice ?? L.tr("session_other_device_unknown")).isolated)
        content.categoryIdentifier = takeoverCategory
        content.userInfo = [tunnelKey: tunnel]
        post(id: "session.\(tunnel)", content)
    }

    public static func superseded(tunnel: String, by device: String?, stayedUp: Bool) {
        let content = UNMutableNotificationContent()
        content.title = L.tr(stayedUp ? "session_superseded_title_stayed" : "session_superseded_title")
        content.body = L.tr("session_superseded_text", tunnel.isolated, (device ?? L.tr("session_other_device_unknown")).isolated)
            + (stayedUp ? " " + L.tr("session_superseded_stayed") : "")
        content.categoryIdentifier = takeoverCategory
        content.userInfo = [tunnelKey: tunnel]
        post(id: "session.\(tunnel)", content)
    }

    // MARK: Plumbing

    private static func post(id: String, _ content: UNNotificationContent) {
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// "<pubkey>:<days>" / "<pubkey>:suspended" → said already. One key each (SharedMap).
    private static let markers = SharedMap<Bool>("notice_marker")

    private static func deliverOnce(id: String, marker: String, title: String, body: String) {
        guard markers[marker] != true else { return }
        markers[marker] = true
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        post(id: id, content)
    }

    private static func clearMarker(_ marker: String) {
        markers.remove(marker)
    }

    /// A renewal pushes the count above the window; the next expiry warns from scratch.
    private static func clearMarkers(for pubkey: String) {
        markers.removeAll { $0.hasPrefix(pubkey + ":") && !$0.hasSuffix(":suspended") }
    }
}
#endif
