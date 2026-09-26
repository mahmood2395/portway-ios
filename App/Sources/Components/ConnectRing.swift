// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// The hero: one ring whose stroke carries the whole state.
//
//   idle        no stroke, no glow
//   busy        a 22% dash spinning once every 1.1s, glow at 0.6
//   connected   the ring closes, the spin stops, the glow breathes 0.35 ↔ 0.8 over 3.4s
//
// The whole 236pt square is one Button: tapping anywhere toggles. Its accessibility label says
// what the tap will DO ("Disconnect beta-frankfurt"), since the control's meaning inverts with state.

import SwiftUI
import PortwayCore

enum HeroPhase: Equatable {
    case idle, connecting, disconnecting, reconnecting, connected, silent

    var isBusy: Bool { self == .connecting || self == .disconnecting || self == .reconnecting }
}

struct ConnectRing<Center: View>: View {
    var phase: HeroPhase
    var action: () -> Void
    var accessibilityLabel: String
    @ViewBuilder var center: Center

    @State private var spin = false
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let size: CGFloat = 236
    private let radius: CGFloat = 106

    private var trim: CGFloat {
        switch phase {
        case .idle: return 0
        case .connecting, .disconnecting, .reconnecting: return 0.22
        case .connected, .silent: return 1
        }
    }

    private var strokeColor: Color {
        phase == .silent ? PW.error : PW.accent
    }

    private var glowOpacity: Double {
        switch phase {
        case .idle, .silent: return 0
        case .connecting, .disconnecting, .reconnecting: return 0.6
        case .connected: return breathe ? 0.8 : 0.35
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // The halo: a radial field from the ground-mixed accent to transparent at 68%.
                Circle()
                    .fill(RadialGradient(colors: [PW.glow, PW.glow.opacity(0)], center: .center,
                                         startRadius: 0, endRadius: (size - 40) / 2 / 0.68 * 0.68))
                    .padding(20)
                    .opacity(glowOpacity)
                    .animation(.easeInOut(duration: phase == .connected ? 3.4 : 0.5), value: glowOpacity)

                Circle()
                    .stroke(PW.rule, lineWidth: 1.5)
                    .frame(width: radius * 2, height: radius * 2)

                Circle()
                    .trim(from: 0, to: trim)
                    .stroke(strokeColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: radius * 2, height: radius * 2)
                    .rotationEffect(.degrees(-90))
                    .rotationEffect(.degrees(phase.isBusy && spin ? 360 : 0))
                    .animation(phase.isBusy && !reduceMotion
                               ? .linear(duration: 1.1).repeatForever(autoreverses: false) : .easeOut(duration: 0.4),
                               value: spin)
                    .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6), value: trim)
                    .animation(.easeInOut(duration: 0.4), value: phase)

                center
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .accessibilityLabel(accessibilityLabel)
        .onAppear { sync() }
        .onChange(of: phase) { sync() }
    }

    private func sync() {
        spin = phase.isBusy
        if phase == .connected, !reduceMotion {
            withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) { breathe = true }
        } else {
            breathe = false
        }
    }
}
