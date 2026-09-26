// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Buttons and the switch, in Nocturne's terms. Every control has a pressed state (a 0.96 scale —
// never smaller, it reads as exaggerated), a 44pt hit area, and a disabled state at 45% opacity.

import SwiftUI
import PortwayCore

/// Tactile press feedback shared by every tappable surface.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// The outlined primary: an accent edge and accent-300 label, never an accent flood.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var height: CGFloat = 50

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PW.font(15, .medium))
            .foregroundStyle(PW.accent300)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(
                RoundedRectangle(cornerRadius: PW.radius, style: .continuous)
                    .fill(configuration.isPressed ? PW.accent900 : .clear)
            )
            .overlay(RoundedRectangle(cornerRadius: PW.radius, style: .continuous).strokeBorder(PW.accent, lineWidth: 1))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(.spring(response: 0.25, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// A bordered neutral button ("Edit").
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PW.font(15, .medium))
            .foregroundStyle(PW.text)
            .padding(.horizontal, 18)
            .frame(minHeight: 50)
            .background(RoundedRectangle(cornerRadius: PW.radius, style: .continuous).fill(configuration.isPressed ? PW.surface : .clear))
            .overlay(RoundedRectangle(cornerRadius: PW.radius, style: .continuous).strokeBorder(PW.stroke, lineWidth: 1))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(.spring(response: 0.25, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// A plain text row: "Not now", "Skip — I already have a config file".
struct GhostButtonStyle: ButtonStyle {
    var color: Color = PW.muted
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PW.font(13.5))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The small outlined header action ("Add").
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PW.font(12.5, .medium))
            .foregroundStyle(PW.accent300)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: PW.radius).fill(configuration.isPressed ? PW.accent900 : .clear))
            .overlay(RoundedRectangle(cornerRadius: PW.radius).strokeBorder(PW.accent, lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// Nocturne's switch: 42×24, off is an outline with a muted knob; on is an accent pill with the
/// knob cut out in the ground colour. The knob carries a 1.5pt accent-300 ring — without it, at the
/// travelled end the "hole" merged with the track's edge and the control read as a "D".
struct PWToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.layoutDirection) private var direction

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 16) {
                configuration.label
                Spacer(minLength: 0)
                track(on: configuration.isOn)
            }
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }

    private func track(on: Bool) -> some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? PW.accent : .clear)
            Capsule().strokeBorder(on ? PW.accent : PW.dotRest, lineWidth: 1)
            Circle()
                .fill(on ? PW.ground : PW.muted)
                .overlay(Circle().strokeBorder(on ? PW.accent300 : .clear, lineWidth: 1.5))
                .frame(width: 16, height: 16)
                .padding(4)
        }
        .frame(width: 42, height: 24)
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.25), value: on)
        .frame(minHeight: 44)
    }
}

/// A 9pt state dot.
struct Dot: View {
    var color: Color
    var size: CGFloat = 9
    var body: some View {
        Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// A 32pt accent-tinted icon tile.
struct IconTile: View {
    var systemName: String
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.47, weight: .regular))
            .foregroundStyle(PW.accent400)
            .frame(width: size, height: size)
            .card(fill: PW.accent900, edge: PW.accent800, radius: PW.smallRadius)
            .accessibilityHidden(true)
    }
}

/// Header: a title left, an optional trailing view. 56pt, 22pt gutters.
struct ScreenHeader<Trailing: View>: View {
    var title: String
    var back: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let back {
                Button(action: back) {
                    Image(systemName: "arrow.backward")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(PW.text)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(L.tr("a11y_back"))
                .padding(.leading, -12)
            }
            Text(title)
                .font(PW.font(19, .medium, relativeTo: .title3))
                .tracking(PW.tracking(-0.03, size: 19))
                .foregroundStyle(PW.text)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: 56)
        .padding(.horizontal, PW.gutter)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, back: (() -> Void)? = nil) {
        self.init(title: title, back: back) { EmptyView() }
    }
}
