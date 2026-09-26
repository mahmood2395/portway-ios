// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Nocturne, the Portway design system: a dark, compact, low-chroma system — a near-neutral
// blue-grey ground, Inter at two weights, 8pt radii, and the accent spent as a line, a mark or a
// glow, never as a large fill.
//
// Values are the Android app's brand_colors.xml (night and day), seeded from #6fd9b8. The accent
// is ONE role with a 300…900 ramp; move every step together on a re-seed or you get a teal ring
// with a violet glow. In the light theme the ramp is inverted — 300 is its dark end — so "accent300
// for text on accent grounds" holds in both.
//
// Shared by the app and the widgets.

import SwiftUI
import UIKit
import PortwayCore

public enum PW {
    // MARK: Colour

    private static func dynamic(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .light ? UIColor(hex: light) : UIColor(hex: dark) })
    }

    public static let ground = dynamic(0x161826, 0xF4F5FA)
    public static let surface = dynamic(0x232532, 0xFFFFFF)
    public static let rowSurface = dynamic(0x232842, 0xEDF0F9)
    public static let stroke = dynamic(0x3F424D, 0xD8DAE4)
    public static let rule = dynamic(0x292B31, 0xE2E4EC)
    public static let text = dynamic(0xE9E9ED, 0x1C1A27)
    public static let textSecondary = dynamic(0xB2B6CA, 0x484459)
    /// 6.06:1 on the ground — the lowest ink allowed for text.
    public static let muted = dynamic(0x9397AB, 0x5B5F72)
    /// Fails 4.5:1 on purpose: icons and dots only, never text.
    public static let iconMuted = dynamic(0x75798C, 0x767A8C)
    public static let dotRest = dynamic(0x595D6C, 0xA8ACBC)

    public static let accent = dynamic(0x6FD9B8, 0x006A52)
    public static let accent300 = dynamic(0xB6E8DE, 0x004434)
    public static let accent400 = dynamic(0x94E1CC, 0x005542)
    public static let accent600 = dynamic(0x5BAF98, 0x008B6D)
    public static let accent700 = dynamic(0x4A887B, 0x33AC8B)
    public static let accent800 = dynamic(0x38615D, 0x96D4BE)
    public static let accent900 = dynamic(0x2A4246, 0xD3EFE4)
    /// The ring's halo: the accent mixed 66% toward the ground — computed, not a stored alpha, so a
    /// re-seed can never leave a teal ring on a violet halo.
    public static let glow = dynamic(mix(0x6FD9B8, 0x161826, 0.66), mix(0x006A52, 0xF4F5FA, 0.66))

    public static let pingOK = dynamic(0x94E1CC, 0x005542)
    public static let fail = dynamic(0x8A5560, 0xB04250)
    public static let error = dynamic(0xFF8A8F, 0xC62A31)
    /// The design's one non-ramp colour: an overdue rekey is a warning the mono accent cannot carry.
    public static let late = dynamic(0xC8A24A, 0x856609)
    public static let decayTrack = dynamic(0x2F313C, 0xDDE0EA)
    public static let decayMark = dynamic(0x6B7183, 0x767A8C)
    public static let rowSelected = dynamic(0x22423C, 0xB4E2D0)

    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xFF) }
        func m(_ s: UInt32) -> UInt32 { UInt32((ch(a, s) * (1 - t) + ch(b, s) * t).rounded()) << s }
        return m(16) | m(8) | m(0)
    }

    // MARK: Type

    public enum Weight { case regular, medium }

    /// Inter, or Vazirmatn UI in Persian — Inter has no Arabic-script coverage, and whatever the
    /// system falls back to has different metrics from the Latin beside it. The UI cut, because the
    /// default cut grows every line box; never the Farsi-Digits cut, because these screens carry
    /// addresses, ports and keys.
    public static func font(_ size: CGFloat, _ weight: Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        let fa = L.isRTL
        let name: String
        switch (fa, weight) {
        case (false, .regular): name = "Inter-Regular"
        case (false, .medium): name = "Inter-SemiBold"
        case (true, .regular): name = "Vazirmatn-UI-Regular"
        case (true, .medium): name = "Vazirmatn-UI-SemiBold"
        }
        return .custom(name, size: size, relativeTo: style)
    }

    /// Tracking in em. Zero in Persian: spacing glyphs pulls cursive joins apart.
    public static func tracking(_ em: CGFloat, size: CGFloat) -> CGFloat {
        L.isRTL ? 0 : em * size
    }

    // MARK: Geometry

    public static let gutter: CGFloat = 22
    public static let radius: CGFloat = 8
    public static let smallRadius: CGFloat = 6
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Text roles

public extension View {
    /// 10.5pt uppercase section label: "LAST HANDSHAKE", "DOWN".
    func sectionLabel(_ color: Color = PW.muted) -> some View {
        font(PW.font(10.5, .medium, relativeTo: .caption2))
            .tracking(PW.tracking(0.14, size: 10.5))
            .textCase(L.isRTL ? nil : .uppercase)
            .foregroundStyle(color)
    }

    /// 11pt status kicker: "PROTECTED".
    func kicker(_ color: Color) -> some View {
        font(PW.font(11, .medium, relativeTo: .caption))
            .tracking(PW.tracking(0.2, size: 11))
            .textCase(L.isRTL ? nil : .uppercase)
            .foregroundStyle(color)
    }

    /// Tabular figures, for anything that ticks.
    func tabular() -> some View { monospacedDigit() }

    /// Nocturne's surface: an edge plus a flat face. No shadows — a drop shadow is invisible on a
    /// dark ground, and the Android clay shadows were retired for exactly that.
    func card(fill: Color = PW.surface, edge: Color = PW.stroke, radius: CGFloat = PW.radius) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(edge, lineWidth: 1))
    }
}

/// A 1pt rule that fades to transparent over 48pt at each end rather than stopping cleanly.
public struct FadingRule: View {
    var color: Color = PW.rule
    public init(color: Color = PW.rule) { self.color = color }
    public var body: some View {
        GeometryReader { geo in
            let fade = min(48 / max(geo.size.width, 1), 0.5)
            LinearGradient(stops: [
                .init(color: color.opacity(0), location: 0),
                .init(color: color, location: fade),
                .init(color: color, location: 1 - fade),
                .init(color: color.opacity(0), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
        .frame(height: 1)
        .accessibilityHidden(true)
    }
}
