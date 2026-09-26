// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Everything WidgetKit loads out of the extension: the Home Screen / Lock Screen status widget,
// the iOS 18 Control Center toggle, and the Live Activity's presentation.
//
// The extension cannot message the running tunnel (only the app can, and only while a screen is
// visible — see TunnelSnapshot.swift), so every view here reads two things instead: the
// NETunnelProviderManager list for who is enabled/connected right now, and the snapshot the
// extension persists to the app group on every watchdog pass for the session clock and the link
// judgement. Both reads are cheap and synchronous-ish (loadAllFromPreferences is the only await),
// which matters because a widget extension is killed for going over its memory/time budget.
//
// Nocturne here: a flat PW.ground container background, 1pt PW.stroke hairlines, and the accent
// spent only as the status dot, the kicker text and a hairline — never as a filled button, same
// rule the app's own screens follow.

import ActivityKit
import AppIntents
import NetworkExtension
import PortwayCore
import SwiftUI
import WidgetKit

// MARK: - Status widget: timeline entry

struct StatusEntry: TimelineEntry {
    let date: Date
    /// Nil only when no configuration has ever been imported — "widget_no_config".
    let tunnelName: String?
    let isActive: Bool
    /// Connecting or reasserting. Counted as "on": the toggle's next tap would disconnect, so the
    /// button must already say so, not "Connect".
    var isPending: Bool = false
    /// Up, but the watchdog has judged the link silent — draws "NOT REACHING THE SERVER".
    let isSilent: Bool
    let connectedSince: Date?

    var kickerKey: String {
        if isPending { return "hero_connecting" }
        guard isActive else { return "hero_not_protected" }
        return isSilent ? "hero_no_handshake" : "hero_protected"
    }

    var kickerColor: Color {
        guard isActive else { return PW.muted }
        return isSilent ? PW.fail : PW.accent
    }
}

// MARK: - Status widget: timeline provider

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, tunnelName: "Portway", isActive: true, isSilent: false, connectedSince: .now.addingTimeInterval(-620))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        // The gallery snapshot must not block on the network extension for long; loadAllFromPreferences
        // is local (reads NEConfiguration's own store), so this stays well inside WidgetKit's budget.
        Task { completion(await Self.currentEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        Task {
            let entry = await Self.currentEntry()
            // No push channel from the extension to the widget, so the system just polls. 15
            // minutes matches the watchdog's own patience for a dead link — tighter would not
            // show anything truer, only burn the widget's refresh budget faster.
            // While connecting, look again shortly: the app also asks WidgetKit to reload on every
            // status change, but that request is best effort.
            let next = entry.date.addingTimeInterval(entry.isPending ? 10 : 15 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    static func currentEntry(now: Date = .now) async -> StatusEntry {
        let managers = (try? await VPNControl.managers()) ?? []
        let active = managers.first { $0.connection.status.isActiveOrPending }
        let snapshot = TunnelSnapshot.loadPersisted()
        let name = active?.localizedDescription ?? VPNControl.current(in: managers)?.localizedDescription
        let isActive = active?.connection.status == .connected
        let isPending = active.map { $0.connection.status != .connected } ?? false
        // The snapshot only ever describes the LAST tunnel the extension ran; if it has moved on
        // to a different configuration since, its silence verdict is not about what is on screen.
        let describesActive = snapshot?.tunnelName == name
        let silent = (describesActive ? snapshot?.link(now: now).isSilent : nil) ?? false
        let since = describesActive ? snapshot?.connectedSince : nil
        return StatusEntry(date: now, tunnelName: name, isActive: isActive, isPending: isPending, isSilent: silent,
                           connectedSince: isActive ? since : nil)
    }
}

// MARK: - Status widget: views

struct StatusWidgetEntryView: View {
    var entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .systemMedium: MediumStatusView(entry: entry)
            case .accessoryCircular: CircularStatusView(entry: entry)
            case .accessoryRectangular: RectangularStatusView(entry: entry)
            case .accessoryInline: InlineStatusView(entry: entry)
            default: SmallStatusView(entry: entry)
            }
        }
        .containerBackground(for: .widget) {
            switch family {
            case .accessoryCircular, .accessoryRectangular, .accessoryInline: Color.clear
            default: PW.ground
            }
        }
        // The in-app language, not the system's: Persian text must also lay out right to left.
        .environment(\.layoutDirection, L.isRTL ? .rightToLeft : .leftToRight)
    }
}

private struct StatusKicker: View {
    let entry: StatusEntry
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(entry.kickerColor).frame(width: 6, height: 6)
            Text(L.tr(entry.kickerKey)).kicker(entry.kickerColor)
        }
    }
}

private struct ToggleButton: View {
    let entry: StatusEntry
    var body: some View {
        Button(intent: ToggleVPNIntent()) {
            Text(entry.isActive || entry.isPending ? L.tr("detail_disconnect") : L.tr("detail_connect"))
                .kicker(PW.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .overlay(RoundedRectangle(cornerRadius: PW.smallRadius, style: .continuous).strokeBorder(PW.stroke, lineWidth: 1))
    }
}

struct SmallStatusView: View {
    let entry: StatusEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusKicker(entry: entry)
            Text(entry.tunnelName ?? L.tr("widget_no_config"))
                .font(PW.font(15, .medium))
                .foregroundStyle(PW.text)
                .lineLimit(1)
            if let since = entry.connectedSince {
                Text(since, style: .timer)
                    .font(PW.font(13))
                    .tabular()
                    .foregroundStyle(PW.textSecondary)
            }
            Spacer(minLength: 0)
            ToggleButton(entry: entry)
        }
        .padding(14)
    }
}

struct MediumStatusView: View {
    let entry: StatusEntry
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                StatusKicker(entry: entry)
                Text(entry.tunnelName ?? L.tr("widget_no_config"))
                    .font(PW.font(17, .medium))
                    .foregroundStyle(PW.text)
                    .lineLimit(1)
                if let since = entry.connectedSince {
                    Text(since, style: .timer)
                        .font(PW.font(14))
                        .tabular()
                        .foregroundStyle(PW.textSecondary)
                }
            }
            Spacer(minLength: 8)
            ToggleButton(entry: entry).frame(width: 108)
        }
        .padding(14)
    }
}

struct CircularStatusView: View {
    let entry: StatusEntry
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: entry.isActive ? (entry.isSilent ? "shield.lefthalf.filled.slash" : "shield.fill") : "shield.slash")
                .font(.system(size: 20, weight: .semibold))
        }
        .widgetAccentable()
        .accessibilityLabel(L.tr(entry.kickerKey))
    }
}

struct RectangularStatusView: View {
    let entry: StatusEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.tunnelName ?? L.tr("widget_no_config"))
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(L.tr(entry.kickerKey))
                if let since = entry.connectedSince {
                    Text("·")
                    Text(since, style: .timer)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .widgetAccentable()
    }
}

struct InlineStatusView: View {
    let entry: StatusEntry
    var body: some View {
        Label {
            if let since = entry.connectedSince {
                Text("\(entry.tunnelName ?? L.tr("widget_no_config")) – ") + Text(since, style: .timer)
            } else {
                Text(entry.tunnelName ?? L.tr("widget_no_config"))
            }
        } icon: {
            Image(systemName: entry.isActive ? "shield.fill" : "shield.slash")
        }
    }
}

// MARK: - Status widget

struct StatusWidget: Widget {
    let kind = "app.portway.widgets.status"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatusProvider()) { entry in
            StatusWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(LocalizedStringResource(stringLiteral: L.tr("widget_status_display_name")))
        .description(LocalizedStringResource(stringLiteral: L.tr("widget_status_description")))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - iOS 18 Control Center toggle

/// The Control Center's own "set the value" intent. `SetValueIntent` is how `ControlWidgetToggle`
/// wires a tap to an action: it supplies `value` (the state the user just asked for) and nothing
/// else, so this goes through the same headless gate every other non-UI entry point uses.
@available(iOS 18.0, *)
struct SetVPNStateIntent: SetValueIntent {
    static let title = LocalizedStringResource("widget_control_display_name", table: "Intents")

    @Parameter(title: LocalizedStringResource("widget_control_value", table: "Intents"))
    var value: Bool

    func perform() async throws -> some IntentResult {
        if value {
            try await VPNControl.connect(gate: .headless)
        } else {
            await VPNControl.disconnect()
        }
        return .result()
    }
}

@available(iOS 18.0, *)
struct VPNControlValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        await VPNControl.isConnected()
    }
}

@available(iOS 18.0, *)
struct VPNControlWidget: ControlWidget {
    static let kind = "app.portway.widgets.vpn-toggle"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: VPNControlValueProvider()) { isActive in
            ControlWidgetToggle(
                LocalizedStringResource(stringLiteral: L.tr("widget_control_display_name")),
                isOn: isActive,
                action: SetVPNStateIntent()
            ) { value in
                Label(
                    value ? L.tr("tunnel_status_active") : L.tr("tunnel_status_inactive"),
                    systemImage: value ? "shield.fill" : "shield.slash"
                )
            }
        }
        .displayName(LocalizedStringResource(stringLiteral: L.tr("widget_control_display_name")))
        .description(LocalizedStringResource(stringLiteral: L.tr("widget_control_description")))
    }
}

// MARK: - Live Activity

struct PortwayLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PortwayActivityAttributes.self) { context in
            LiveActivityLockScreenView(attributes: context.attributes, state: context.state)
                .environment(\.layoutDirection, L.isRTL ? .rightToLeft : .leftToRight)
                .activityBackgroundTint(PW.ground)
                .activitySystemActionForegroundColor(PW.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.tunnelName)
                            .font(.headline)
                            .lineLimit(1)
                        if let place = context.state.place {
                            Text(place)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let since = context.state.connectedSince {
                        Text(since, style: .timer)
                            .font(.title3)
                            .tabular()
                            .multilineTextAlignment(.trailing)
                    } else {
                        Image(systemName: "shield.slash")
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: DisconnectIntent()) {
                        Text(L.tr("detail_disconnect"))
                            .frame(maxWidth: .infinity)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.reaching ? "shield.fill" : "shield.lefthalf.filled.slash")
                    .foregroundStyle(context.state.reaching ? PW.accent : PW.fail)
            } compactTrailing: {
                if let since = context.state.connectedSince {
                    Text(since, style: .timer).tabular()
                } else {
                    Text("--")
                }
            } minimal: {
                Image(systemName: context.state.reaching ? "shield.fill" : "shield.lefthalf.filled.slash")
                    .foregroundStyle(context.state.reaching ? PW.accent : PW.fail)
            }
            .keylineTint(PW.accent)
        }
    }
}

private struct LiveActivityLockScreenView: View {
    let attributes: PortwayActivityAttributes
    let state: PortwayActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: state.reaching ? "shield.fill" : "shield.lefthalf.filled.slash")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(state.reaching ? PW.accent : PW.fail)
            VStack(alignment: .leading, spacing: 3) {
                Text(attributes.tunnelName)
                    .font(PW.font(15, .medium))
                    .foregroundStyle(PW.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(L.tr(state.reaching ? "hero_protected" : "hero_no_handshake"))
                    if let place = state.place {
                        Text("·")
                        Text(place)
                    }
                }
                .font(PW.font(12))
                .foregroundStyle(PW.textSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let since = state.connectedSince {
                Text(since, style: .timer)
                    .font(PW.font(15))
                    .tabular()
                    .foregroundStyle(PW.text)
            }
            Button(intent: DisconnectIntent()) {
                Text(L.tr("detail_disconnect")).kicker(PW.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
    }
}

// MARK: - Bundle

@main
struct PortwayWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        PortwayLiveActivityWidget()
        if #available(iOS 18.0, *) {
            VPNControlWidget()
        }
    }
}
