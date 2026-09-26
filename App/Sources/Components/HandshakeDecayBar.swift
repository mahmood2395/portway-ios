// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// The handshake decay bar.
//
// "Latest handshake: 12 seconds ago" re-rendered every second and said nothing, because the number
// had no limit to be read against. This draws the age as a bar filling toward WireGuard's 180s
// cutoff — the whole track — with a hairline where the 118s rekey is due. One glance says how
// much room is left; a bar past the hairline is the news.
//
// - Growth animates 0.9s linear; a new handshake SNAPS back. Sliding backwards reads as the bar
//   being wrong; snapping reads as the rekey landing, which is what happened.
// - The hairline is drawn over the track, outside its rounded clip, so it reads as a mark on a
//   scale rather than a boundary between two fill segments.
// - It is a time axis with "now" at the reading end, so it mirrors in RTL (SwiftUI does that).
// - The silent state is designed, not hidden: it is the state a user most needs to see.

import SwiftUI
import PortwayCore

struct HandshakeDecayBar: View {
    /// nil = never, or down.
    var age: TimeInterval?
    var state: DecayState

    @State private var shownFraction: Double = 0

    private var ink: Color {
        switch state {
        case .fresh: return PW.accent300
        case .late: return PW.late
        case .waiting: return PW.muted
        case .silent: return PW.fail
        }
    }

    private var ageText: String {
        switch state {
        case .silent: return L.tr("handshake_age_none")
        case .waiting: return L.tr("handshake_age_waiting")
        case .fresh, .late: return age.map(L.handshakeAge) ?? L.tr("handshake_age_waiting")
        }
    }

    private var sentence: String {
        switch state {
        case .fresh: return L.tr("handshake_state_fresh")
        case .late: return L.tr("handshake_state_late")
        case .waiting: return L.tr("handshake_state_waiting")
        case .silent: return L.tr("handshake_state_silent")
        }
    }

    private var spoken: String {
        let seconds = Int(age ?? 0)
        let words = seconds < 60 ? L.tr("handshake_spoken_seconds", seconds) : L.tr("handshake_spoken_minutes", seconds / 60, seconds % 60)
        switch state {
        case .fresh: return L.tr("handshake_a11y_fresh", words)
        case .late: return L.tr("handshake_a11y_late", words)
        case .waiting: return L.tr("handshake_a11y_waiting")
        case .silent: return L.tr("handshake_a11y_silent")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L.tr("handshake_label")).sectionLabel()
                Spacer()
                Text(ageText)
                    .font(PW.font(11.5, .medium))
                    .tabular()
                    .foregroundStyle(ink)
                    .contentTransition(.numericText())
            }

            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(PW.decayTrack)
                        RoundedRectangle(cornerRadius: 3).fill(ink)
                            .frame(width: max(0, width * shownFraction))
                    }
                    .frame(height: 6)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .offset(y: 3)
                    .frame(maxHeight: .infinity, alignment: .top)

                    Rectangle()
                        .fill(PW.decayMark)
                        .frame(width: 1, height: 12)
                        .offset(x: width * Handshake.rekeyFraction)
                }
            }
            .frame(height: 12)
            .padding(.top, 14)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Text(L.tr("handshake_axis_start"))
                    Text(L.tr("handshake_axis_rekey"))
                        .fixedSize()
                        .alignmentGuide(.leading) { $0[HorizontalAlignment.center] - geo.size.width * Handshake.rekeyFraction }
                    Text(L.tr("handshake_axis_end"))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .font(PW.font(11))
            .foregroundStyle(PW.muted)
            .frame(height: 14)
            .padding(.top, 9)

            Text(sentence)
                .font(PW.font(12.5))
                .foregroundStyle(PW.muted)
                .padding(.top, 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .onAppear { shownFraction = DecayState.fill(handshakeAge: age, state: state) }
        .onChange(of: DecayState.fill(handshakeAge: age, state: state)) { _, target in
            if target >= shownFraction {
                withAnimation(.linear(duration: 0.9)) { shownFraction = target }
            } else {
                shownFraction = target   // snap: the rekey landed
            }
        }
    }
}
